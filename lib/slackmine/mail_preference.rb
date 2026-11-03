# frozen_string_literal: true
require_relative 'mail_inline_icon'
require_relative 'mail_inline_avatar'

module Slackmine
  module UserPreferencePatch
    def slack_suppress_mail
      self[:slack_suppress_mail] == true || self[:slack_suppress_mail] == '1'
    end

    def slack_suppress_mail=(value)
      self[:slack_suppress_mail] = value
    end
  end

  module MailerPatch
    def mail(*args, **kwargs, &block)
      message = super
      parts = [message] + (message.respond_to?(:all_parts) ? message.all_parts : [])
      parts.each do |part|
        next unless part.respond_to?(:mime_type) && part.mime_type == 'text/plain'
        content = part.body.decoded
        next unless content.include?('[slack-quote:')
        part.body = LinkQuotes.plain_source(content)
      end
      MailInlineIcon.embed(message)
      MailInlineAvatar.embed(message)
      # Adding CID resources can negotiate a transfer encoding before Roadie
      # rewrites the HTML on delivery. Roadie assigns decoded HTML, so a stale
      # base64 header would make Mail decode that HTML as base64 instead.
      ([message] + message.all_parts).each do |part|
        next unless part.mime_type == 'text/html'

        part.body # Materialize any encoded source before removing its header.
        part.content_transfer_encoding = nil
      end
      message
    end

    # Returning without calling mail lets ActionMailer use its normal NullMail.
    # Account and security mail actions deliberately do not participate.
    %i[issue_add issue_edit news_added news_comment_added wiki_content_added wiki_content_updated document_added attachments_added message_posted].each do |action|
      define_method(action) do |user, object, *args|
        return if MailPreference.suppress?(user, action, object)

        super(user, object, *args)
      end
    end
  end

  module MailPreference
    module_function

    def suppress?(user, action, object)
      return false unless user.pref.slack_suppress_mail
      return false if Thread.current[:slackmine_thread_comment]

      project, events = notification(action, object, user)
      return false unless project && events && !events.empty?
      return false unless project.active?
      return false unless events.all? { |event| Slackmine.event_enabled?(project, event) }

      Slackmine.with_project(project) do
        token = Slackmine.bot_token(project)
        channel = Slackmine.channel_id(project)
        return false if token.to_s.empty? || !channel.to_s.match?(/\A[CG][A-Z0-9]+\z/)

        slack_id = recipient_id(user, token)
        return false unless slack_id

        member?(channel, slack_id, token)
      end
    rescue StandardError => error
      # Never include tokens, identities, API response bodies, or content here.
      Rails.logger&.warn("[slackmine] Mail retained: #{error.class}")
      false
    end

    def recipient_id(user, token)
      mapping = Slackmine.user_mapping
      key = [user.login.to_s, user.mail.to_s].find { |candidate| mapping.key?(candidate) }
      if key
        id = mapping[key].to_s.strip
        return id if id.match?(/\A[UW][A-Z0-9]+\z/)

        return nil
      end

      # Reuse outgoing name matching, then verify ownership against a fresh
      # Slack profile before suppressing mail. Do not cache identity evidence.
      id = Slackmine.slack_user_id_for_name(user.login)
      return unless id.to_s.match?(/\A[UW][A-Z0-9]+\z/)

      response = Slackmine.slack_api('users.info', { 'user' => id }, token,
                                                   form: true, open_timeout: 2, read_timeout: 3)
      member = response['user']
      return unless member.is_a?(Hash) && member['id'] == id
      return if member['deleted'] || member['is_bot'] || member['is_app_user'] || member['is_stranger']

      team = Slackmine.effective_config.dig('slack', 'events', 'team_id').to_s
      return if !team.empty? && (member['team_id'] || member['team']) != team

      email = member.dig('profile', 'email').to_s.strip.downcase
      return if email.empty? || email != user.mail.to_s.strip.downcase

      id
    end

    def notification(action, object, user)
      case action
      when :issue_add
        return if object.is_private?

        [object.project, ['issue_created']]
      when :issue_edit
        issue = object.journalized
        return unless issue.is_a?(Issue)
        return if issue.is_private? || object.private_notes?

        events = issue_mail_events(object, user)
        [issue.project, events.uniq]
      when :document_added
        [object.project, ['document_created']]
      when :message_posted
        [object.project, ['message_posted']]
      when :attachments_added
        files = Array(object)
        return if files.empty?
        container = files.first.container
        return unless files.all? { |file| file.container == container }
        case container.class.name
        when 'Project'
          [container, ['file_added']]
        when 'Version'
          [container.project, ['file_added']]
        when 'Document'
          [container.project, ['document_file_added']]
        end
      when :news_added
        [object.project, ['news_created']]
      when :news_comment_added
        return unless object.commented.is_a?(News)
        return if object.comments.to_s.strip.empty?

        [object.commented.project, ['news_comment_added']]
      when :wiki_content_added, :wiki_content_updated
        [object.page.wiki.project, [action == :wiki_content_added ? 'wiki_created' : 'wiki_updated']]
      end
    end

    # Mirror Journal#send_notification: disabled mail triggers must not
    # prevent suppression of another enabled trigger in the same update.
    def issue_mail_events(journal, user)
      enabled = Setting.notified_events
      details = journal.visible_details(user)
      if enabled.include?('issue_updated')
        events = details.map { |detail| journal.send(:slack_event_for_detail, detail) }
        events << 'comment_added' unless journal.notes.to_s.empty?
        return events.uniq
      end

      events = []
      events << 'comment_added' if enabled.include?('issue_note_added') && !journal.notes.to_s.empty?
      triggers = {
        'status_id' => ['issue_status_updated', 'status_changed'],
        'assigned_to_id' => ['issue_assigned_to_updated', 'assignee_changed'],
        'priority_id' => ['issue_priority_updated', 'priority_changed'],
        'fixed_version_id' => ['issue_fixed_version_updated', 'version_changed']
      }
      details.each do |detail|
        if detail.property == 'attachment'
          events << 'attachment_added' if enabled.include?('issue_attachment_added') && detail.value
        elsif detail.property == 'attr'
          trigger, event = triggers[detail.prop_key.to_s]
          next unless trigger && enabled.include?(trigger)
          next if %w[status_id priority_id].include?(detail.prop_key.to_s) && detail.value.to_s.empty?
          events << event
        end
      end
      events.uniq
    end

    def member?(channel, slack_id, token)
      cursor = nil
      seen = {}
      # Bound synchronous work; incomplete or failed lookups retain email.
      10.times do
        params = { 'channel' => channel, 'limit' => 200 }
        params['cursor'] = cursor if cursor
        response = Slackmine.slack_api('conversations.members', params, token,
                                                     form: true, open_timeout: 2, read_timeout: 3)
        return false unless response['members'].is_a?(Array)
        return true if response['members'].include?(slack_id)

        cursor = response.dig('response_metadata', 'next_cursor').to_s.strip
        return false if cursor.empty? || seen[cursor]

        seen[cursor] = true
      end
      false
    end
  end

  if defined?(Redmine::Hook::ViewListener)
    class MailPreferenceHook < Redmine::Hook::ViewListener
      render_on :view_layouts_base_html_head, partial: 'slackmine/mail_preference_assets'
      render_on :view_my_account_preferences, partial: 'slackmine/mail_preference'
      render_on :view_users_form_preferences, partial: 'slackmine/mail_preference'
    end
  end
end
