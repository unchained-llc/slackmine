# frozen_string_literal: true

require 'openssl'
require 'date'

module Slackmine
  module WorkObjects
    module_function

    def integrations
      scopes = [Slackmine.config]
      projects = Slackmine.config['projects']
      if projects.is_a?(Hash)
        projects.each_value do |override|
          scopes << Slackmine.merge_config(scopes.first, override) if override.is_a?(Hash)
        end
      end
      scopes.map do |scope|
        slack = scope['slack']
        next unless slack.is_a?(Hash)

        events = slack['events']
        next unless events.is_a?(Hash)

        secret = events['signing_secret'].to_s.strip
        secret = ENV['SLACK_SIGNING_SECRET'].to_s.strip if secret.empty?
        next if secret.empty? || events['app_id'].to_s.empty? || events['team_id'].to_s.empty?

        events.merge('signing_secret' => secret)
      end.compact.uniq
    end

    def verified_integration(body, timestamp, signature, now: Time.now.to_i, app_id: nil, team_id: nil)
      return unless timestamp.to_s.match?(/\A\d+\z/) && (now - timestamp.to_i).abs <= 300
      return unless signature.to_s.match?(/\Av0=[0-9a-f]{64}\z/)

      integrations.find do |integration|
        next false if app_id && integration['app_id'] != app_id
        next false if team_id && integration['team_id'] != team_id
        digest = OpenSSL::HMAC.hexdigest('SHA256', integration.fetch('signing_secret'), "v0:#{timestamp}:#{body}")
        # Fixed-size, constant-time comparison (also supports older OpenSSL gems).
        "v0=#{digest}".bytes.zip(signature.bytes).reduce(0) { |difference, (left, right)| difference | (left ^ right) }.zero?
      end
    end

    def integration_for(app_id, team_id, project: nil)
      if project
        slack = Slackmine.effective_config(project)['slack']
        events = slack['events'] if slack.is_a?(Hash)
        return unless events.is_a?(Hash) && events['app_id'] == app_id && events['team_id'] == team_id
      end
      integrations.find { |integration| integration['app_id'] == app_id && integration['team_id'] == team_id }
    end

    def issue_for(event)
      value = event['entity_url'].to_s
      match = value.match(%r{/issues/([1-9]\d*)\z})
      return unless match && value == Formatter.url("/issues/#{match[1]}")
      reference = event['external_ref']
      return unless reference.is_a?(Hash) && reference['type'] == 'slackmine_issue' &&
                    reference['id'] == Digest::SHA256.hexdigest(value)

      Issue.find_by(id: match[1].to_i)
    end

    def issue_from_link(url)
      value = url.to_s
      match = value.match(%r{/issues/([1-9]\d*)\z})
      return unless match && value == Formatter.url("/issues/#{match[1]}")

      Issue.find_by(id: match[1].to_i)
    end

    def actions_enabled?(issue)
      Slackmine.effective_config(issue.project).dig('slack', 'work_object_actions') == true
    end

    BUTTON_IDS = {
      'add_comment' => 'slackmine_add_comment', 'reply' => 'slackmine_reply', 'edit_issue' => 'slackmine_edit_issue',
      'open_issue' => 'slackmine_open_issue', 'change_assignee' => 'slackmine_edit_assignee',
      'assign_to_me' => 'slackmine_assign_to_me', 'start_work' => 'slackmine_start_work',
      'complete_work' => 'slackmine_complete_work',
      'log_time' => 'slackmine_log_time', 'watch' => 'slackmine_watch', 'unwatch' => 'slackmine_unwatch'
    }.freeze

    def button_keys(issue, detail: false)
      settings = Slackmine.effective_config(issue.project).dig('slack', 'work_object_buttons')
      return detail ? %w[edit_issue assign_to_me] : %w[add_comment open_issue] unless settings.is_a?(Hash)

      project = Slackmine.project_config(issue.project).dig('slack', 'work_object_buttons')
      keys = (project.is_a?(Hash) ? project.keys : []) + settings.keys
      keys.uniq.select { |key| BUTTON_IDS.key?(key) && key != 'unwatch' && settings[key] == true }
    end

    def action_status_id(issue, key)
      setting = key == 'complete_work' ? 'work_object_complete_status_id' : 'work_object_start_status_id'
      value = Slackmine.effective_config(issue.project).dig('slack', setting)
      value.to_s.match?(/\A[1-9]\d*\z/) ? value.to_i : nil
    end

    def button_available?(key, issue, viewer)
      case key
      when 'start_work', 'complete_work'
        return false if issue.closed? || issue.status_id == action_status_id(issue, 'complete_work')
        target = action_status_id(issue, key)
        return false unless target && issue.status_id != target
        if key == 'complete_work' && button_keys(issue).include?('start_work')
          return false unless issue.status_id == action_status_id(issue, 'start_work')
        end
        return true unless viewer
        issue.attributes_editable?(viewer) && issue.safe_attribute?('status_id', viewer) &&
          issue.new_statuses_allowed_to(viewer).any? { |status| status.id == target }
      when 'add_comment', 'reply'
        !viewer || issue.notes_addable?(viewer)
      when 'edit_issue'
        !viewer || !!edit_modal(issue, viewer, {})
      when 'change_assignee', 'assign_to_me'
        return true unless viewer
        issue.attributes_editable?(viewer) && issue.safe_attribute?('assigned_to_id', viewer) &&
          (key == 'change_assignee' ? !!assignee_options(issue) :
            issue.assigned_to_id != viewer.id && issue.assignable_users.include?(viewer))
      when 'watch', 'unwatch'
        return true unless viewer
        key == 'watch' ? !issue.watched_by?(viewer) && issue.valid_watcher?(viewer) : issue.watched_by?(viewer)
      when 'log_time'
        !viewer || viewer.allowed_to?(:log_time, issue.project)
      else
        true
      end
    end

    def configured_actions(issue, viewer: nil)
      keys = button_keys(issue, detail: !viewer.nil?).map { |key| key == 'watch' && viewer && issue.watched_by?(viewer) ? 'unwatch' : key }
      actions = keys.select { |key| button_available?(key, issue, viewer) }.map do |key|
        label = work_object_message(key == 'watch' && !viewer ? 'watch_settings' : key, product_name: Formatter.message('work_objects', 'product_name'))
        button = { 'text' => label, 'action_id' => BUTTON_IDS.fetch(key), 'value' => "slackmine_issue:#{issue.id}" }
        button['url'] = Formatter.url("/issues/#{issue.id}") if key == 'open_issue'
        button['url'] = Formatter.url("/issues/#{issue.id}/time_entries/new") if key == 'log_time'
        button
      end
      Rails.logger&.warn('Slackmine: only the first 7 Work Object buttons can be displayed') if actions.length > 7
      result = { 'primary_actions' => actions.first(2) }
      result['overflow_actions'] = actions.drop(2).first(5) if actions.length > 2
      result
    end

    def watch_modal(issue, viewer, source)
      watching = issue.watched_by?(viewer)
      return unless watching || issue.valid_watcher?(viewer)
      context = source.slice('entity_url', 'external_ref', 'channel_id', 'message_ts', 'is_ephemeral')
      context['watching'] = !watching
      { 'type' => 'modal', 'callback_id' => 'slackmine_watch_settings',
        'title' => { 'type' => 'plain_text', 'text' => work_object_message('watch_settings') },
        'submit' => { 'type' => 'plain_text', 'text' => work_object_message(watching ? 'unwatch' : 'watch') },
        'close' => { 'type' => 'plain_text', 'text' => work_object_message('cancel') },
        'private_metadata' => JSON.generate(context),
        'blocks' => [{ 'type' => 'section', 'text' => { 'type' => 'plain_text',
          'text' => work_object_message(watching ? 'watching' : 'not_watching') } }] }
    end

    def update_watch(issue, viewer, watching)
      issue.with_lock do
        return :restricted unless actions_enabled?(issue) && issue.project.active? && !issue.is_private? && issue.visible?(viewer)
        return :unchanged if issue.watched_by?(viewer) == watching
        return :restricted if watching && !issue.valid_watcher?(viewer)
        issue.set_watcher(viewer, watching)
        issue.watched_by?(viewer) == watching ? :saved : :restricted
      end
    rescue ActiveRecord::RecordInvalid
      :restricted
    end

    def editable_metadata(issue, viewer)
      metadata = Formatter.issue_work_object_details(issue)
      return metadata unless actions_enabled?(issue)

      fields = metadata.fetch('entity_payload').fetch('fields')
      if issue.attributes_editable?(viewer) && issue.safe_attribute?('description', viewer) && issue.description.to_s.length <= 3000
        # Use the full raw text, not the shortened/stripped display value.
        fields['description'] = { 'value' => issue.description.to_s, 'format' => 'markdown',
          'edit' => { 'enabled' => true, 'optional' => true, 'text' => { 'max_length' => 3000 } } }
      end
      if issue.attributes_editable?(viewer) && issue.safe_attribute?('assigned_to_id', viewer)
        options = assignee_options(issue)
        if options
          selected_id = (issue.assigned_to_id || 'none').to_s
          # Slack user fields use a workspace-wide picker instead of static options.
          fields['assignee'] = {
            'type' => 'string',
            'value' => options.find { |option| option['value'] == selected_id }.dig('text', 'text'),
            'edit' => {
              'enabled' => true,
              'select' => { 'current_value' => selected_id, 'static_options' => options }
            }
          }
        end
      end
      if issue.attributes_editable?(viewer) && issue.safe_attribute?('status_id', viewer)
        statuses = issue.new_statuses_allowed_to(viewer)
        if statuses.any? { |status| status.id == issue.status_id }
          fields['status']['edit'] = {
            'enabled' => true,
            'select' => {
              'current_value' => issue.status_id.to_s,
              'static_options' => statuses.map { |status| {
                'value' => status.id.to_s,
                'text' => { 'type' => 'plain_text', 'text' => status.name.to_s }
              } }
            }
          }
        end
      end
      if issue.attributes_editable?(viewer) && issue.safe_attribute?('priority_id', viewer) && fields['priority']
        priorities = IssuePriority.active.to_a
        if priorities.any? { |priority| priority.id == issue.priority_id }
          fields['priority']['edit'] = {
            'enabled' => true,
            'select' => { 'current_value' => issue.priority_id.to_s,
                          'static_options' => select_options(priorities) }
          }
        end
      end
      if issue.attributes_editable?(viewer) && issue.safe_attribute?('due_date', viewer) && fields['due_date']
        fields['due_date']['edit'] = { 'enabled' => true, 'optional' => true }
      end
      if issue.notes_addable?(viewer)
        metadata.fetch('entity_payload').fetch('custom_fields') << {
          'key' => 'new_comment', 'label' => Formatter.message('work_objects', 'add_comment'), 'type' => 'string', 'value' => '',
          'edit' => { 'enabled' => true, 'optional' => true,
                      'text' => { 'max_length' => 3000 },
                      'placeholder' => { 'type' => 'plain_text', 'text' => Formatter.message('work_objects', 'comment_placeholder') } }
        }
      end
      metadata.fetch('entity_payload')['actions'] = configured_actions(issue, viewer: viewer)
      metadata
    end

    def work_object_message(key, **values)
      Formatter.interpolate(Formatter.message('work_objects', key), values,
                            fallback: Formatter::DEFAULT_MESSAGES.dig('work_objects', key))
    end

    def select_options(records)
      records.map { |record| { 'value' => record.id.to_s,
                                'text' => { 'type' => 'plain_text', 'text' => record.name.to_s } } }
    end

    def assignee_options(issue)
      users = issue.assignable_users.to_a
      return unless users.length <= 99 && (issue.assigned_to_id.nil? || users.any? { |user| user.id == issue.assigned_to_id })

      [{ 'value' => 'none', 'text' => { 'type' => 'plain_text', 'text' => Formatter.message('values', 'unassigned') } }] + select_options(users)
    end

    def edit_modal(issue, viewer, source, assignee_only: false, comment_only: false, reply: false)
      comment_only ||= reply
      return unless comment_only ? issue.notes_addable?(viewer) : issue.attributes_editable?(viewer)

      blocks = []
      blocks << Formatter.section_text(work_object_message('reply_hint')) if reply
      if !comment_only && !assignee_only && issue.safe_attribute?('subject', viewer)
        blocks << { 'type' => 'input', 'block_id' => 'subject',
                    'label' => { 'type' => 'plain_text', 'text' => Formatter.field_label('subject') },
                    'element' => { 'type' => 'plain_text_input', 'action_id' => 'subject',
                                   'initial_value' => issue.subject.to_s, 'max_length' => 255 } }
      end
      if !comment_only && !assignee_only && issue.safe_attribute?('description', viewer)
        if issue.description.to_s.length <= 3000
          element = { 'type' => 'plain_text_input', 'action_id' => 'description', 'multiline' => true, 'max_length' => 3000 }
          element['initial_value'] = issue.description.to_s unless issue.description.to_s.empty?
          blocks << { 'type' => 'input', 'block_id' => 'description', 'optional' => true,
                      'label' => { 'type' => 'plain_text', 'text' => Formatter.field_label('description') }, 'element' => element }
        else
          blocks << Formatter.section_text("<#{Formatter.url("/issues/#{issue.id}/edit")}|#{SlashCommands.message('full_form')}>")
        end
      end
      if !comment_only && issue.safe_attribute?('status_id', viewer)
        statuses = issue.new_statuses_allowed_to(viewer)
        blocks << select_input('status', Formatter.field_label('status'), statuses, issue.status_id) if statuses.any? { |status| status.id == issue.status_id }
      end
      if !comment_only && issue.safe_attribute?('priority_id', viewer)
        priorities = IssuePriority.active.to_a
        blocks << select_input('priority', Formatter.field_label('priority'), priorities, issue.priority_id) if priorities.any? { |priority| priority.id == issue.priority_id }
      end
      if !comment_only && issue.safe_attribute?('assigned_to_id', viewer)
        options = assignee_options(issue)
        if options
          blocks << { 'type' => 'input', 'block_id' => 'assignee',
                      'label' => { 'type' => 'plain_text', 'text' => Formatter.field_label('assignee') },
                      'element' => { 'type' => 'static_select', 'action_id' => 'assignee',
                                     'options' => options,
                                     'initial_option' => options.find { |option| option['value'] == (issue.assigned_to_id || 'none').to_s } } }
        end
      end
      if !comment_only && issue.safe_attribute?('due_date', viewer)
        element = { 'type' => 'datepicker', 'action_id' => 'due_date' }
        element['initial_date'] = issue.due_date.iso8601 if issue.due_date
        blocks << { 'type' => 'input', 'block_id' => 'due_date', 'optional' => true,
                    'label' => { 'type' => 'plain_text', 'text' => Formatter.field_label('due_date') }, 'element' => element }
      end
      if issue.notes_addable?(viewer)
        blocks << { 'type' => 'input', 'block_id' => 'new_comment', 'optional' => !comment_only,
                    'label' => { 'type' => 'plain_text', 'text' => Formatter.message('work_objects', 'add_comment') },
                    'element' => { 'type' => 'plain_text_input', 'action_id' => 'new_comment', 'multiline' => true,
                                   'max_length' => 3000 } }
      end
      blocks.select! { |block| block['block_id'] == 'assignee' } if assignee_only
      return if blocks.empty?

      context = source.slice('entity_url', 'external_ref', 'channel_id', 'message_ts', 'is_ephemeral', 'app_home')
      callback = reply ? 'slackmine_reply' : (comment_only ? 'slackmine_add_comment' : 'slackmine_edit_issue')
      title = reply ? work_object_message('reply') : (comment_only ? Formatter.message('work_objects', 'add_comment') : work_object_message('edit_title', id: issue.id))
      { 'type' => 'modal', 'callback_id' => callback,
        'title' => { 'type' => 'plain_text', 'text' => title },
        'submit' => { 'type' => 'plain_text', 'text' => Formatter.message('work_objects', 'save') },
        'close' => { 'type' => 'plain_text', 'text' => Formatter.message('work_objects', 'cancel') },
        'private_metadata' => JSON.generate(context), 'blocks' => blocks }
    end

    def select_input(key, label, records, selected_id)
      options = select_options(records)
      { 'type' => 'input', 'block_id' => key,
        'label' => { 'type' => 'plain_text', 'text' => label },
        'element' => { 'type' => 'static_select', 'action_id' => key,
                       'options' => options,
                       'initial_option' => options.find { |option| option['value'] == selected_id.to_s } } }
    end

    # Explicit mappings take priority. Optional email matching never uses
    # display names to authorize access to Redmine data.
    def viewer_for(slack_id)
      return unless slack_id.to_s.match?(/\A[UW][A-Z0-9]+\z/)

      mapping = Slackmine.user_mapping
      explicit_keys = mapping.select { |_key, value| value == slack_id }.keys
      unless explicit_keys.empty?
        users = explicit_keys.map do |key|
          User.find_by(login: key.to_s) || User.find_by(mail: key.to_s)
        end.compact.uniq { |user| user.id }
        return users.first if users.length == 1 && users.first.active?
        return nil
      end
      viewer_by_email(slack_id, mapping)
    end

    def viewer_by_email(slack_id, mapping)
      settings = Slackmine.effective_config
      return unless settings.dig('slack', 'auto_map_users_by_email') == true
      token = Slackmine.bot_token
      return if token.to_s.empty?

      # Fetch fresh identity data for each authorization; do not persist emails
      # or cache permissions in Redis, files, or process memory.
      response = Slackmine.slack_api('users.info', { 'user' => slack_id }, token,
        form: true, open_timeout: 2, read_timeout: 3)
      member = response['user']
      return unless member.is_a?(Hash) && member['id'] == slack_id
      return if member['deleted'] || member['is_bot'] || member['is_app_user'] || member['is_stranger']
      team_id = settings.dig('slack', 'events', 'team_id').to_s
      return if !team_id.empty? && (member['team_id'] || member['team']) != team_id
      email = member.dig('profile', 'email').to_s.strip.downcase
      return if email.empty?

      users = User.active.joins(:email_addresses).where('LOWER(email_addresses.address) = ?', email).distinct.limit(2).to_a
      return unless users.length == 1
      viewer = users.first
      # A manual mapping of this Redmine identity to another Slack user wins.
      assigned = [mapping[viewer.login.to_s], mapping[viewer.mail.to_s]].select do |value|
        value.is_a?(String) && value.match?(/\A[UW][A-Z0-9]+\z/)
      end
      return if assigned.any? { |value| value != slack_id }

      viewer if viewer.active?
    rescue StandardError => e
      Rails.logger&.warn("Slackmine: email user matching failed: #{e.class}")
      nil
    end

    def present_details(app_id, team_id, event)
      return unless event.is_a?(Hash) && event['type'] == 'entity_details_requested'
      return if event['trigger_id'].to_s.empty?
      issue = issue_for(event)
      return unless issue && integration_for(app_id, team_id, project: issue.project)

      Slackmine.with_project(issue.project) do
        token = Slackmine.bot_token(issue.project)
        return if token.to_s.empty?

        viewer = viewer_for(event['user'])
        allowed = Slackmine.effective_config.dig('slack', 'work_object_previews') == true &&
                  issue.project.active? && !issue.is_private? && viewer && issue.visible?(viewer)
        request = { 'trigger_id' => event['trigger_id'] }
        if allowed
          request['metadata'] = editable_metadata(issue, viewer)
        else
          request['error'] = { 'status' => 'restricted' }
        end
        Slackmine.slack_api('entity.presentDetails', request, token, form: true)
      end
    end

    def unfurl_links(app_id, team_id, event)
      return unless event.is_a?(Hash) && event['type'] == 'link_shared'
      return unless event['links'].is_a?(Array) && event['user'].is_a?(String)

      target = if %w[composer conversations_history].include?(event['source']) && event['unfurl_id'].to_s != ''
                 { 'unfurl_id' => event['unfurl_id'], 'source' => event['source'] }
               elsif event['channel'].to_s.match?(/\A[CDG][A-Z0-9]+\z/) &&
                     event['message_ts'].to_s.match?(/\A\d+\.\d+\z/)
                 { 'channel' => event['channel'], 'ts' => event['message_ts'] }
               end
      return unless target

      entities = []
      token = nil
      event['links'].first(10).map { |link| link.is_a?(Hash) ? link['url'] : nil }.uniq.each do |url|
        issue = issue_from_link(url)
        next unless issue && issue.project.active? && !issue.is_private?

        Slackmine.with_project(issue.project) do
          next unless integration_for(app_id, team_id, project: issue.project) &&
                      Slackmine.effective_config.dig('slack', 'work_object_previews') == true
          viewer = viewer_for(event['user'])
          next unless viewer && issue.visible?(viewer)

          issue_token = Slackmine.bot_token(issue.project)
          next if issue_token.to_s.empty? || (token && issue_token != token)

          entity = Formatter.issue_payload(issue, actor: nil, action: 'updated').dig('metadata', 'entities', 0)
          next unless entity

          entity['app_unfurl_url'] = url
          entities << entity
          token ||= issue_token
        end
      end
      return if entities.empty?

      Slackmine.slack_api('chat.unfurl', target.merge('metadata' => { 'entities' => entities }),
                                        token, form: true)
    end

    def process_interaction(app_id, team_id, payload)
      return unless payload.is_a?(Hash) && %w[block_actions view_submission].include?(payload['type'])
      source = payload['type'] == 'block_actions' ? payload['container'] : payload['view']
      return unless source.is_a?(Hash)
      modal = source['type'] == 'modal' && %w[slackmine_edit_issue slackmine_add_comment slackmine_reply slackmine_watch_settings].include?(source['callback_id'])
      return unless modal || source['type'] == 'entity_detail' || source['type'] == 'message_attachment'
      # Slack omits entity identity on ephemeral Work Object button payloads.
      # Resolve our explicit button value, then apply the same object authorization.
      if payload['type'] == 'block_actions' && source['type'] == 'message_attachment' && source['is_ephemeral'] == true &&
         !source.key?('entity_url') && !source.key?('external_ref')
        actions = payload['actions']
        return unless actions.is_a?(Array) && actions.one? && actions.first.is_a?(Hash)
        match = actions.first['value'].to_s.match(/\Aslackmine_issue:([1-9]\d*)\z/)
        return unless match
        url = Formatter.url("/issues/#{match[1]}")
        source = source.merge('entity_url' => url,
                              'external_ref' => { 'type' => 'slackmine_issue', 'id' => Digest::SHA256.hexdigest(url) })
      end
      context = modal ? JSON.parse(source['private_metadata'].to_s) : source
      return unless context.is_a?(Hash)
      event = { 'entity_url' => context['entity_url'], 'external_ref' => context['external_ref'] }
      issue = issue_for(event)
      return unless issue && integration_for(app_id, team_id, project: issue.project)

      Slackmine.with_project(issue.project) do
        return unless Slackmine.effective_config.dig('slack', 'work_object_previews') == true &&
                      actions_enabled?(issue) && issue.project.active? && !issue.is_private?
        viewer = viewer_for(payload.dig('user', 'id'))
        return unless viewer && issue.visible?(viewer)

        if payload['type'] == 'block_actions'
          actions = payload['actions']
          return unless actions.is_a?(Array) && actions.length == 1
          action = actions.first
          return unless action.is_a?(Hash)
          key = BUTTON_IDS.key(action['action_id'])
          return unless key
          configured = Slackmine.effective_config(issue.project).dig('slack', 'work_object_buttons')
          return if configured.is_a?(Hash) && !button_keys(issue, detail: source['type'] == 'entity_detail').include?(key == 'unwatch' ? 'watch' : key)
          # Detail panels can retain stale watch/unwatch buttons after a save.
          # Always resolve the current personal state before choosing an action.
          if %w[watch unwatch].include?(key) && %w[message_attachment entity_detail].include?(source['type'])
            form = watch_modal(issue, viewer, source)
            return unless form && payload['trigger_id'].to_s != ''
            return Slackmine.slack_api('views.open', {
              'trigger_id' => payload['trigger_id'], 'view' => form
            }, Slackmine.bot_token(issue.project), form: true)
          end
          if %w[slackmine_edit_issue slackmine_edit_assignee slackmine_add_comment slackmine_reply].include?(action['action_id']) && %w[message_attachment entity_detail].include?(source['type'])
            form = edit_modal(issue, viewer, source, assignee_only: action['action_id'] == 'slackmine_edit_assignee',
                              comment_only: action['action_id'] == 'slackmine_add_comment', reply: key == 'reply')
            return unless form && payload['trigger_id'].to_s != ''
            return Slackmine.slack_api('views.open', {
              'trigger_id' => payload['trigger_id'], 'view' => form
            }, Slackmine.bot_token(issue.project), form: true)
          end
          outcome = case key
                    when 'assign_to_me'
                      update_issue(issue, viewer, assigned_to_id: viewer.id)
                    when 'start_work', 'complete_work'
                      target = action_status_id(issue, key)
                      target && button_available?(key, issue, viewer) ? update_issue(issue, viewer, status_id: target) : :restricted
                    when 'watch', 'unwatch'
                      update_watch(issue, viewer, key == 'watch')
                    else
                      return
                    end
        elsif modal && source['callback_id'] == 'slackmine_watch_settings'
          return unless button_keys(issue).include?('watch') && [true, false].include?(context['watching'])
          outcome = update_watch(issue, viewer, context['watching'])
        else
          if modal && Slackmine.effective_config(issue.project).dig('slack', 'work_object_buttons').is_a?(Hash)
            requested = case source['callback_id']
                        when 'slackmine_add_comment' then ['add_comment']
                        when 'slackmine_reply' then ['reply']
                        else %w[edit_issue change_assignee]
                        end
            return if (button_keys(issue, detail: true) & requested).empty?
          end
          values = source.dig('state', 'values')
          return unless values.is_a?(Hash)
          status = values.dig('status', modal ? 'status' : 'status.input', 'selected_option', 'value')
          priority = values.dig('priority', modal ? 'priority' : 'priority.input', 'selected_option', 'value')
          assignee = values.dig('assignee', modal ? 'assignee' : 'assignee.input', 'selected_option', 'value')
          due_date = values.dig('due_date', modal ? 'due_date' : 'due_date.input', 'selected_date')
          due_date = '' if values.key?('due_date') && due_date.nil?
          comment = values.dig('new_comment', modal ? 'new_comment' : 'new_comment.input', 'value')
          subject_input = values.dig('subject', 'subject') if modal
          subject = if subject_input.is_a?(Hash) && subject_input.key?('value')
                      subject_input['value'].nil? ? '' : subject_input['value']
                    end
          description_input = values.dig('description', modal ? 'description' : 'description.input')
          # Only an explicitly submitted value may clear the description.
          # A block without the expected input is not a request to erase it.
          description = if description_input.is_a?(Hash) && description_input.key?('value')
                          description_input['value'].nil? ? '' : description_input['value']
                        end
          return unless status.nil? || status.to_s.match?(/\A[1-9]\d*\z/)
          return unless priority.nil? || priority.to_s.match?(/\A[1-9]\d*\z/)
          return unless assignee.nil? || assignee == 'none' || assignee.to_s.match?(/\A[1-9]\d*\z/)
          return unless due_date.nil? || due_date == '' || valid_date?(due_date)
          return unless comment.nil? || (comment.is_a?(String) && comment.length <= 3000)
          return unless description.nil? || (description.is_a?(String) && description.length <= 3000)
          reply = modal && source['callback_id'] == 'slackmine_reply'
          if modal && %w[slackmine_add_comment slackmine_reply].include?(source['callback_id'])
            return if comment.to_s.strip.empty?
            status = priority = assignee = due_date = nil
            description = nil
            subject = nil
          end
          outcome = update_issue(issue, viewer, assigned_to_id: assignee, status_id: status,
                                 priority_id: priority, due_date: due_date, comment: comment, description: description, subject: subject, reply: reply)
        end
        Rails.logger&.info("Slackmine: Work Object interaction issue=#{issue.id} result=#{outcome}")
        if modal || source['type'] == 'message_attachment'
          enqueue_refresh(app_id, team_id, issue.id, payload.dig('user', 'id'), context, outcome, true)
          return
        end
        if payload['deferred'] == true
          enqueue_refresh(app_id, team_id, issue.id, payload.dig('user', 'id'), context, outcome, false)
          notice = %i[saved unchanged].include?(outcome) ? Formatter.message('commands', 'background_saved') :
            work_object_message('edit_failed', id: issue.id)
          Slackmine.slack_api('chat.postMessage', { 'channel' => payload.dig('user', 'id'), 'text' => notice }, Slackmine.bot_token(issue.project))
          return
        end
        trigger = payload['trigger_id'].to_s
        return if trigger.empty?
        token = Slackmine.bot_token(issue.project)
        return if token.to_s.empty?
        request = { 'trigger_id' => trigger }
        if outcome == :saved || outcome == :unchanged
          issue.reload
          request['metadata'] = editable_metadata(issue, viewer)
        else
          request['error'] = { 'status' => 'edit_error', 'custom_message' => Formatter.message('work_objects', 'operation_failed') }
        end
        Slackmine.slack_api('entity.presentDetails', request, token, form: true)
        enqueue_refresh(app_id, team_id, issue.id, payload.dig('user', 'id'), context, outcome, false)
      end
    rescue JSON::ParserError
      nil
    end

    def enqueue_refresh(app, team, issue_id, slack_user, context, outcome, modal)
      fields = context.slice('channel_id', 'message_ts', 'is_ephemeral', 'app_home')
      job = SlackmineWorkObjectRefreshJob.perform_later(app, team, issue_id, slack_user, fields, outcome.to_s, modal)
      Rails.logger&.warn("Slackmine: Work Object refresh enqueue failed issue=#{issue_id}") unless job
    rescue StandardError => e
      # The Issue may already be saved. Never re-run the incoming interaction.
      Rails.logger&.warn("Slackmine: Work Object refresh enqueue failed issue=#{issue_id} #{e.class}")
    end

    def refresh_after_interaction(app, team, issue_id, slack_user, context, outcome, modal)
      issue = Issue.find_by(id: issue_id)
      return unless issue && integration_for(app, team, project: issue.project)
      Slackmine.with_project(issue.project) do
        viewer = viewer_for(slack_user)
        return unless viewer && issue.visible?(viewer)
        success = %w[saved unchanged].include?(outcome)
        if modal && AppHome::FILTERS.include?(context['app_home'])
          begin
            notice = work_object_message('edit_failed', id: issue.id) unless success
            AppHome.publish(app, team, slack_user, context['app_home'], notice: notice)
          rescue StandardError => e
            Rails.logger&.warn("Slackmine: App Home refresh failed issue=#{issue.id} #{e.class}")
          end
        end
        if success && !issue.is_private? && context['is_ephemeral'] != true &&
           context['channel_id'].to_s.match?(/\A[CDG][A-Z0-9]+\z/) &&
           context['message_ts'].to_s.match?(/\A\d+\.\d+\z/)
          begin
            token = Slackmine.bot_token(issue.project)
            original = Slackmine.slack_api('conversations.replies', {
              'channel' => context['channel_id'], 'ts' => context['message_ts'], 'limit' => 1
            }, token, form: true).fetch('messages').first
            raise 'Original message text unavailable' unless original && original['ts'] == context['message_ts'] && original['text'].to_s != ''
            update = { 'channel' => context['channel_id'], 'ts' => context['message_ts'],
                       'text' => original['text'], 'metadata' => Formatter.issue_payload(issue, actor: viewer, action: 'updated')['metadata'] }
            update['blocks'] = original['blocks'] if original['blocks'].is_a?(Array) && original['blocks'].any?
            Slackmine.slack_api('chat.update', update, token, form: true)
          rescue StandardError => e
            Rails.logger&.warn("Slackmine: card refresh failed issue=#{issue.id} #{e.class}")
          end
        end
        if modal && !success && context['channel_id'].to_s.match?(/\A[CDG][A-Z0-9]+\z/)
          Slackmine.slack_api('chat.postEphemeral', {
            'channel' => context['channel_id'], 'user' => slack_user,
            'text' => work_object_message('edit_failed', id: issue.id)
          }, Slackmine.bot_token(issue.project))
        end
      end
    end

    def valid_date?(value)
      value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value).iso8601 == value
    rescue ArgumentError
      false
    end

    def previous_assignee_id(issue)
      # Ignore clears and the current assignee; use the most recent former owner.
      value = issue.journals.joins(:details)
        .where(journal_details: { property: 'attr', prop_key: 'assigned_to_id' })
        .where.not(journal_details: { old_value: [nil, '', issue.assigned_to_id.to_s] })
        .order('journals.created_on DESC, journals.id DESC, journal_details.id DESC')
        .limit(1).pluck('journal_details.old_value').first
      value.to_s.match?(/\A[1-9]\d*\z/) ? value.to_i : nil
    end

    def reply_assignee_id(issue, viewer)
      return unless issue.attributes_editable?(viewer) && issue.safe_attribute?('assigned_to_id', viewer)

      id = previous_assignee_id(issue)
      target = issue.assignable_users.find { |user| user.id == id } if id
      target.id if target && target.active?
    end

    def update_issue(issue, viewer, assigned_to_id: nil, status_id: nil, priority_id: nil, due_date: nil, comment: nil, description: nil, subject: nil, reply: false)
      previous_user = User.current
      User.current = viewer
      issue.with_lock do
        next :restricted unless issue.project.active? && !issue.is_private? && issue.visible?(viewer) &&
                                actions_enabled?(issue)
        if reply
          next :restricted if comment.to_s.strip.empty? || !issue.notes_addable?(viewer)
          assigned_to_id = reply_assignee_id(issue, viewer)
        end
        attrs = {}
        unless subject.nil?
          next :restricted unless subject.is_a?(String) && subject.length.between?(1, 255) && !subject.strip.empty? &&
                                  issue.attributes_editable?(viewer) && issue.safe_attribute?('subject', viewer)
          attrs['subject'] = subject unless issue.subject.to_s == subject
        end
        unless description.nil?
          next :restricted unless description.is_a?(String) && description.length <= 3000 && issue.description.to_s.length <= 3000 &&
                                  issue.attributes_editable?(viewer) && issue.safe_attribute?('description', viewer)
          attrs['description'] = description unless issue.description.to_s == description
        end
        unless assigned_to_id.nil?
          next :restricted unless issue.attributes_editable?(viewer) && issue.safe_attribute?('assigned_to_id', viewer) &&
                                  (assigned_to_id.to_s == 'none' ||
                                   issue.assignable_users.any? { |user| user.id.to_s == assigned_to_id.to_s })
          new_assignee = assigned_to_id.to_s == 'none' ? nil : assigned_to_id.to_i
          attrs['assigned_to_id'] = new_assignee&.to_s || '' unless issue.assigned_to_id == new_assignee
        end
        if status_id
          next :restricted unless issue.attributes_editable?(viewer) && issue.safe_attribute?('status_id', viewer) &&
                                  issue.new_statuses_allowed_to(viewer).any? { |status| status.id.to_s == status_id.to_s }
          attrs['status_id'] = status_id.to_s unless issue.status_id.to_s == status_id.to_s
        end
        unless priority_id.nil?
          next :restricted unless issue.attributes_editable?(viewer) && issue.safe_attribute?('priority_id', viewer) &&
                                  IssuePriority.active.any? { |priority| priority.id.to_s == priority_id.to_s }
          attrs['priority_id'] = priority_id.to_s unless issue.priority_id.to_s == priority_id.to_s
        end
        unless due_date.nil?
          next :restricted unless issue.attributes_editable?(viewer) && issue.safe_attribute?('due_date', viewer) &&
                                  (due_date == '' || valid_date?(due_date))
          new_date = due_date == '' ? nil : Date.iso8601(due_date)
          attrs['due_date'] = due_date unless issue.due_date == new_date
        end
        note = comment.to_s.strip
        next :restricted if !note.empty? && !issue.notes_addable?(viewer)
        next :unchanged if attrs.empty? && note.empty?
        issue.init_journal(viewer, note)
        issue.send(:safe_attributes=, attrs, viewer) unless attrs.empty?
        issue.save! ? :saved : :restricted
      end
    rescue ActiveRecord::RecordInvalid
      :restricted
    ensure
      User.current = previous_user
    end
  end
end
