# frozen_string_literal: true

require 'securerandom'

module Slackmine
  module MessageShortcuts
    module_function

    CALLBACK = 'slackmine_message_create'
    PROJECT_CALLBACK = 'slackmine_message_project'

    def handles?(payload)
      (payload['type'] == 'message_action' && payload['callback_id'] == CALLBACK) ||
        (payload['type'] == 'view_submission' && payload.dig('view', 'callback_id') == PROJECT_CALLBACK)
    end

    def context_key(app, team, viewer, nonce)
      "slackmine:message:#{Digest::SHA256.hexdigest([app, team, viewer.id, nonce].join(':'))}"
    end

    def error(text)
      { 'response_action' => 'errors', 'errors' => { 'project' => text } }
    end

    def block_text(blocks)
      Array(blocks).flat_map do |block|
        next [] unless block.is_a?(Hash)
        case block['type']
        when 'section', 'header'
          [block.dig('text', 'text')] + Array(block['fields']).map { |field| field['text'] if field.is_a?(Hash) }.compact
        when 'context'
          Array(block['elements']).map { |element| element['text'] if element.is_a?(Hash) && %w[plain_text mrkdwn].include?(element['type']) }.compact
        when 'rich_text'
          Array(block['elements']).map { |element| rich_text(element) }
        else
          []
        end
      end
    end

    def rich_text(element)
      return '' unless element.is_a?(Hash)
      case element['type']
      when 'text' then element['text'].to_s
      when 'link' then element['text'].to_s.empty? ? element['url'].to_s : "#{element['text']} (#{element['url']})"
      when 'user' then "<@#{element['user_id']}>"
      when 'channel' then "<##{element['channel_id']}>"
      when 'emoji' then ":#{element['name']}:"
      else
        separator = element['type'] == 'rich_text_list' ? "\n" : ''
        Array(element['elements']).map { |child| rich_text(child) }.join(separator)
      end
    end

    def message_text(message)
      return '' unless message.is_a?(Hash)
      text = message['text']
      return text if text.is_a?(String) && !text.strip.empty?

      parts = block_text(message['blocks'])
      Array(message['attachments']).each do |attachment|
        next unless attachment.is_a?(Hash)
        content = %w[pretext title text].map { |key| attachment[key] }
        Array(attachment['fields']).each do |field|
          content << [field['title'], field['value']].select { |value| value.is_a?(String) && !value.empty? }.join(': ') if field.is_a?(Hash)
        end
        content.concat(block_text(attachment['blocks']))
        content << attachment['fallback'] unless content.any? { |value| value.is_a?(String) && !value.strip.empty? }
        parts.concat(content)
      end
      parts.select { |value| value.is_a?(String) && !value.strip.empty? }.uniq.join("\n")
    end

    def readable_text(text, subject: false)
      CGI.unescapeHTML(text.to_s.gsub(/<(https?:\/\/[^>|]+)(?:\|([^>]*))?>/) do
        url, label = Regexp.last_match(1), Regexp.last_match(2)
        label.to_s.empty? || label == url ? url : (subject ? label : "#{label} (#{url})")
      end)
    end

    # Only the explicitly selected, signed Slack payload is retained. This does
    # not grant access to DM history or other messages in the conversation.
    def description_with_quote(text, nonce, project, viewer, app, team)
      source = Rails.cache.read(context_key(app, team, viewer, nonce))
      return unless source.is_a?(Hash) && source['project_id'] == project.id.to_s && source['url']
      return text unless LinkCards.enabled?(project) && LinkCards.referenced?(text, LinkCards.parse(source['url']))
      message = source['message']
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      call = lambda do |method, body|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout::Error if remaining <= 0
        Slackmine.slack_api(method, body, Slackmine.bot_token(project), form: true,
          open_timeout: [0.5, remaining].min, read_timeout: [1, remaining].min)
      end
      card = LinkCards.message_card(message, call).merge('channel' => source['channel_name'])
      text.to_s.rstrip + "\n\n" + LinkQuotes.encode(card, source['url'], project: project)
    end

    def interaction(app, team, payload)
      commands = SlashCommands
      return {} unless commands.enabled? && commands.integration?(app, team)
      viewer = WorkObjects.viewer_for(payload.dig('user', 'id'))
      if payload['type'] == 'view_submission'
        return error(commands.message('denied')) unless viewer
        return select_project(app, team, viewer, payload)
      end
      return {} if payload['trigger_id'].to_s.empty?
      projects = viewer ? Project.allowed_to(viewer, :add_issues).where(status: Project::STATUS_ACTIVE).order(:name).to_a : []
      projects.select! { |project| commands.authorized_project?(project, app, team) }
      channel = payload.dig('channel', 'id').to_s
      ts = payload.dig('message', 'ts').to_s
      text = message_text(payload['message'])
      valid = viewer && channel.match?(/\A[CDG][A-Z0-9]+\z/) && ts.match?(/\A\d+\.\d+\z/) && text.is_a?(String) && !text.strip.empty?
      if !valid || projects.empty?
        view = { 'type' => 'modal', 'title' => { 'type' => 'plain_text', 'text' => commands.message('new') },
                 'close' => { 'type' => 'plain_text', 'text' => commands.message('cancel') },
                 'blocks' => [commands.section(commands.message('denied'))] }
      else
        # Store source content server-side rather than in Slack private_metadata.
        # The cache key binds it to the initiating user and authenticated app/team.
        nonce = SecureRandom.hex(16)
        message = payload['message'].slice('user', 'username', 'bot_id', 'bot_profile', 'ts')
        message['text'] = text[0, 6000]
        Rails.cache.write(context_key(app, team, viewer, nonce),
                          { 'text' => text[0, 6000], 'message' => message,
                            'channel_name' => payload.dig('channel', 'name').to_s.empty? ? channel : payload['channel']['name'],
                            'channel' => channel, 'ts' => ts }, expires_in: 1800)
        projects.sort_by! { |project| Slackmine.channel_id(project) == channel ? 0 : 1 }
        options = projects.first(100).map do |project|
          { 'text' => { 'type' => 'plain_text', 'text' => project.name.to_s[0, 75] }, 'value' => project.id.to_s }
        end
        view = { 'type' => 'modal', 'callback_id' => PROJECT_CALLBACK, 'private_metadata' => nonce,
                 'title' => { 'type' => 'plain_text', 'text' => commands.message('new') },
                 'submit' => { 'type' => 'plain_text', 'text' => commands.message('continue') },
                 'close' => { 'type' => 'plain_text', 'text' => commands.message('cancel') },
                 'blocks' => [commands.section(commands.message('message_project')),
                              commands.input('project', commands.message('project'), { 'type' => 'static_select', 'options' => options })] }
      end
      Slackmine.slack_api('views.open', { 'trigger_id' => payload['trigger_id'], 'view' => view }, Slackmine.bot_token)
      {}
    end

    def select_project(app, team, viewer, payload)
      commands = SlashCommands
      nonce = payload.dig('view', 'private_metadata').to_s
      return error(commands.message('denied')) unless nonce.match?(/\A[0-9a-f]{32}\z/)
      source = Rails.cache.read(context_key(app, team, viewer, nonce))
      return error(commands.message('message_expired')) unless source.is_a?(Hash)
      id = payload.dig('view', 'state', 'values', 'project', 'project', 'selected_option', 'value').to_s
      project = id.match?(/\A[1-9]\d*\z/) ? Project.find_by(id: id) : nil
      unless project && commands.authorized_project?(project, app, team) && viewer.allowed_to?(:add_issues, project)
        return error(commands.message('denied'))
      end
      view = commands.modal('create', id, viewer)
      return error(commands.message('denied')) unless view
      # Fetch only a permalink, never other messages or thread history. Tight
      # timeouts keep this modal update within Slack's acknowledgement window.
      result = Slackmine.slack_api('chat.getPermalink',
        { 'channel' => source['channel'], 'message_ts' => source['ts'] }, Slackmine.bot_token,
        form: true, open_timeout: 0.5, read_timeout: 1)
      link = result['permalink'].to_s
      return error(commands.message('denied')) unless link.match?(%r{\Ahttps://[a-z0-9.-]+\.slack\.com/archives/[CDG][A-Z0-9]+/p\d+(?:\?[^\s]*)?\z}i)
      target = LinkCards.parse(link)
      return error(commands.message('denied')) unless target && target['channel'] == source['channel'] && target['ts'] == source['ts']
      source = source.merge('project_id' => project.id.to_s, 'url' => link)
      Rails.cache.write(context_key(app, team, viewer, nonce), source, expires_in: 1800)
      view['private_metadata'] = "#{id}:#{nonce}"
      suffix = "\n\n#{commands.message('source_message')}: #{link}"
      description = readable_text(source['text'])[0, [3000 - suffix.length, 0].max] + suffix
      subject = readable_text(source['text'], subject: true).lines.find { |line| !line.strip.empty? }.to_s.strip[0, 255]
      view['blocks'].each do |block|
        next unless %w[subject description].include?(block['block_id'])
        block['element']['initial_value'] = block['block_id'] == 'subject' ? subject : description
      end
      { 'response_action' => 'update', 'view' => view }
    rescue Slackmine::SlackApiError, Timeout::Error, IOError, SystemCallError
      error(commands.message('message_retry'))
    end
  end
end
