# frozen_string_literal: true

module Slackmine
  module SlashCommands
    module_function

    PREFIX = 'slackmine_command_'

    def message(key)
      value = Formatter.message('commands', key)
      return value unless key == 'help'

      command = Slackmine.effective_config.dig('slack', 'slash_command').to_s
      value.gsub('%{command}') { Formatter.text(command.empty? ? '/slackmine' : command) }
    end

    def integration?(app, team)
      events = Slackmine.effective_config.dig('slack', 'events') || {}
      events['app_id'] == app && events['team_id'] == team && WorkObjects.integration_for(app, team)
    end

    def enabled?(project = nil)
      Slackmine.effective_config(project).dig('slack', 'slash_command').to_s.start_with?('/')
    end

    def authorized_project?(project, app, team)
      project.active? && enabled?(project) && WorkObjects.integration_for(app, team, project: project)
    end

    def button(label, command)
      { 'type' => 'button', 'text' => { 'type' => 'plain_text', 'text' => label },
        'action_id' => PREFIX + 'run_' + Digest::SHA256.hexdigest(command), 'value' => command }
    end

    def section(text)
      Formatter.section_text(text)
    end

    def issue_blocks(issue, actions: true)
      blocks = [section("<#{Formatter.url("/issues/#{issue.id}")}|##{issue.id} #{Formatter.text(issue.subject)}>\n#{Formatter.text(issue.status.name)}")]
      if actions
        blocks << { 'type' => 'actions', 'elements' => [button(message('comment'), "comment #{issue.id}")] }
      end
      blocks
    end

    def run(app, team, user_id, channel, text)
      viewer = WorkObjects.viewer_for(user_id)
      return [section(message('denied'))] unless viewer
      command, argument = text.to_s.strip.split(/\s+/, 2)
      if command && !%w[help new my due search status assign comment reminders].include?(command) &&
         !command.match?(/\A#?[1-9]\d*\z/)
        command, argument = 'search', text.to_s.strip
      end
      case command
      when nil, '', 'help'
        [section(message('help')), { 'type' => 'actions', 'elements' => %w[my due reminders new].map { |key| button(message(key), key) } }]
      when 'new'
        projects = Project.allowed_to(viewer, :add_issues).where(status: Project::STATUS_ACTIVE).order(:name).to_a
        projects.select! { |project| authorized_project?(project, app, team) }
        projects.select! { |project| project.identifier == argument } if argument && !argument.empty?
        return [section(message('empty'))] if projects.empty?
        # Prefer the current channel's project without excluding other choices.
        projects.sort_by! { |project| Slackmine.channel_id(project) == channel ? 0 : 1 }
        [section(message('choose_project'))] + projects.first(20).map do |project|
          { 'type' => 'section', 'text' => { 'type' => 'plain_text', 'text' => project.name.to_s[0, 200] },
            'accessory' => button(message('new'), "create #{project.id}") }
        end
      when 'my', 'due', 'search'
        return [section(message('help'))] if command == 'search' && argument.to_s.strip.empty?
        scope = Issue.visible(viewer)
        if command == 'search'
          scope = scope.where('LOWER(issues.subject) LIKE ?', "%#{Issue.sanitize_sql_like(argument.downcase)}%")
        else
          scope = scope.open.where(assigned_to_id: viewer.id)
          scope = scope.where('issues.due_date <= ?', Date.current + 3).order(:due_date) if command == 'due'
        end
        rows = scope.order(updated_on: :desc).limit(100).to_a.select do |issue|
          issue.visible?(viewer) && authorized_project?(issue.project, app, team)
        end.first(10)
        return yield(rows.first) if rows.one? && block_given?
        rows.empty? ? [section(message('empty'))] : issue_list_payload(rows, command)
      when 'status', 'assign'
        id = argument.to_s.sub(/\A#/, '')
        return [section(message('help'))] unless id.match?(/\A[1-9]\d*\z/)
        issue = editable_issue(id, viewer, app, team, command)
        return [section(message('denied'))] unless issue

        issue_blocks(issue, actions: false) +
          [{ 'type' => 'actions', 'elements' => [button(message(command), "#{command} #{id}")] }]
      else
        id = command.to_s.sub(/\A#/, '')
        return [section(message('help'))] unless id.match?(/\A[1-9]\d*\z/)
        issue = Issue.find_by(id: id)
        return [section(message('denied'))] unless issue && issue.visible?(viewer) && authorized_project?(issue.project, app, team)
        block_given? ? yield(issue) : issue_blocks(issue)
      end
    end

    def issue_list_payload(issues, command)
      { 'text' => message('results'),
        'blocks' => [section("📋 *#{Formatter.text(message('results'))}*")],
        'attachments' => [Formatter.due_digest_attachment(message(command), issues, Date.current,
                                                         Formatter.due_reminder_color('upcoming'))] }
    end

    def deliver(app, team, payload)
      return unless enabled? && integration?(app, team)
      text = payload['text'].to_s
      return deliver_reminders(app, team, payload) if text.strip == 'reminders'
      # Modal commands first show a button to obtain a fresh trigger_id.
      result = if (arguments = direct_arguments(text))
                 direct_edit(app, team, payload, *arguments)
               elsif text.match?(/\Acomment\s+#?[1-9]\d*\s*\z/)
                 [{ 'type' => 'actions', 'elements' => [button(message('comment'), text.strip)] }]
               else
                 run(app, team, payload['user_id'], payload['channel_id'], text) { |issue| single_issue_payload(issue) }
               end
      result = { 'text' => message('results'), 'blocks' => result } if result.is_a?(Array)
      respond(payload, result)
    end

    def response_uri(url)
      return unless url.is_a?(String) && url.bytesize <= 2048

      uri = URI.parse(url)
      return unless uri.is_a?(URI::HTTPS) && %w[hooks.slack.com hooks.slack-gov.com].include?(uri.host) &&
                    uri.port == 443 && !uri.userinfo && !uri.query && !uri.fragment &&
                    uri.path.match?(%r{\A/commands/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+\z})

      uri
    rescue URI::InvalidURIError
      nil
    end

    def respond(payload, result)
      uri = response_uri(payload['response_url'])
      unless uri
        return Slackmine.slack_api('chat.postEphemeral', result.merge(
          'channel' => payload['channel_id'], 'user' => payload['user_id']
        ), Slackmine.bot_token)
      end

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json; charset=utf-8'
      request.body = result.merge('response_type' => 'ephemeral', 'replace_original' => false).to_json
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 10) do |http|
        response = http.request(request)
        # Slack webhooks return plain "ok", unlike Web API's JSON envelope.
        unless response.is_a?(Net::HTTPSuccess) && response.body.to_s.strip == 'ok'
          raise Slackmine::SlackApiError.new('response_url', response.code, { 'error' => 'response_failed' })
        end
      end
    end

    def direct_arguments(text)
      text.to_s.strip.match(/\A(status|assign)\s+#?([1-9]\d*)\s+(.+)\z/m)&.captures
    end

    def direct_target(issue, viewer, kind, query)
      query = query.strip
      if kind == 'assign'
        unassigned = Formatter.message('values', 'unassigned')
        return ['none', unassigned] if query.casecmp?('none') || query.casecmp?(unassigned)
        query = viewer.id.to_s if query.casecmp?('me')
      end
      candidates = kind == 'assign' ? issue.assignable_users : issue.new_statuses_allowed_to(viewer)
      matches = candidates.select do |candidate|
        if query.match?(/\A[1-9]\d*\z/)
          candidate.id.to_s == query
        else
          candidate.name.to_s.casecmp?(query) ||
            (kind == 'assign' && candidate.respond_to?(:login) && candidate.login.to_s.casecmp?(query))
        end
      end.uniq { |candidate| candidate.id }
      return unless matches.one?

      [matches.first.id.to_s, matches.first.name.to_s]
    end

    def direct_edit(app, team, payload, kind, id, query)
      previous = User.current
      viewer = WorkObjects.viewer_for(payload['user_id'])
      return [section(message('denied'))] unless viewer
      User.current = viewer
      issue = editable_issue(id, viewer, app, team, kind)
      request_key = payload['request_key']
      return [section(message('denied'))] unless issue && request_key.is_a?(String) && request_key.match?(/\A[0-9a-f]{64}\z/)

      key = "slackmine:direct:#{Digest::SHA256.hexdigest([app, team, viewer.id, request_key].join(':'))}"
      cache = Rails.cache
      cached = cache.read(key)
      return cached['result'] if cached.is_a?(Hash) && cached.key?('result')
      unless cache.write(key, 'pending', unless_exist: true, expires_in: 300)
        return [section(message('processing'))]
      end
      target = direct_target(issue, viewer, kind, query)
      unless target
        cache.delete(key)
        return [section(message('no_match')), { 'type' => 'actions', 'elements' => [button(message(kind), "#{kind} #{id}")] }]
      end
      attribute = kind == 'assign' ? :assigned_to_id : :status_id
      outcome = WorkObjects.update_issue(issue, viewer, **{ attribute => target.first })
      unless %i[saved unchanged].include?(outcome)
        cache.delete(key)
        return [section(message('denied'))]
      end
      issue.reload
      card = single_issue_payload(issue)
      result = if card['metadata']
                 card.merge('text' => "#{message(outcome == :saved ? 'updated' : 'unchanged')}\n#{card['text']}")
               else
                 [section(message(outcome == :saved ? 'updated' : 'unchanged')),
                  section("<#{Formatter.url("/issues/#{issue.id}")}|##{issue.id} #{Formatter.text(issue.subject)}>\n#{Formatter.text(Formatter.field_label(attribute_key(kind)))}: #{Formatter.text(target.last)}")]
               end
      # Save the result before Slack delivery: a delivery retry must not repeat the write.
      cache.write(key, { 'result' => result }, expires_in: 86_400)
      result
    ensure
      User.current = previous
    end

    def single_issue_payload(issue)
      fallback = { 'text' => message('results'), 'blocks' => issue_blocks(issue) }
      global_token = Slackmine.bot_token
      Slackmine.with_project(issue.project) do
        return fallback unless Slackmine.effective_config.dig('slack', 'work_object_previews') == true
        return fallback if issue.is_private? || Slackmine.bot_token(issue.project) != global_token

        card = Formatter.with_issue_work_object({}, issue, actor: nil, action: 'updated')
        return fallback unless card.dig('metadata', 'entities')&.any?
        { 'text' => "##{issue.id} #{issue.subject}", 'metadata' => card['metadata'] }
      end
    end

    def deliver_reminders(app, team, payload)
      viewer = WorkObjects.viewer_for(payload['user_id'])
      token = Slackmine.bot_token
      unless viewer
        return respond(payload, { 'text' => message('denied') })
      end

      today = Date.current
      groups = SlackmineDueDigestJob.new.due_issues_for(viewer, today)
      issues = groups.fetch([token, payload['user_id']], []).select do |issue|
        authorized_project?(issue.project, app, team)
      end.sort_by { |issue| [issue.due_date, issue.project.name, issue.id] }
      if issues.empty?
        return respond(payload, { 'text' => message('reminders_empty') })
      end

      size = SlackmineDueDigestJob::MAX_ISSUES_PER_MESSAGE
      issues.each_slice(size).with_index do |batch, index|
        sleep(1) if index.positive?
        digest = Slackmine.with_project(batch.first.project) do
          Formatter.due_digest_payload(batch, today: today, part: index + 1,
                                      total_parts: (issues.size + size - 1) / size)
        end
        respond(payload, digest)
      end
    end

    def handles?(payload)
      payload.dig('view', 'callback_id').to_s.start_with?(PREFIX) ||
        Array(payload['actions']).any? { |action| action.is_a?(Hash) && action['action_id'].to_s.start_with?(PREFIX) }
    end

    def input(key, label, element, optional: false)
      { 'type' => 'input', 'block_id' => key, 'optional' => optional,
        'label' => { 'type' => 'plain_text', 'text' => label }, 'element' => element.merge('action_id' => key) }
    end

    def field(key, multiline: false)
      input(key, message(key), { 'type' => 'plain_text_input', 'multiline' => multiline,
                                'max_length' => multiline ? 3000 : 255 }, optional: key == 'description')
    end

    def modal(kind, id, viewer)
      return attribute_modal(kind, id, viewer) if %w[status assign].include?(kind)

      blocks = if kind == 'create'
                 project = Project.find_by(id: id)
                 trackers = Issue.new(project: project, author: viewer).allowed_target_trackers(viewer).to_a
                 return if trackers.empty? || trackers.length > 100
                 options = trackers.map { |t| { 'text' => { 'type' => 'plain_text', 'text' => t.name.to_s[0, 75] }, 'value' => t.id.to_s } }
                 [section("<#{Formatter.url("/projects/#{project.identifier}/issues/new")}|#{Formatter.text(message('full_form'))}>"), input('tracker', message('tracker'), { 'type' => 'static_select', 'options' => options }), field('subject'), field('description', multiline: true)]
               else
                 [field('comment', multiline: true)]
               end
      { 'type' => 'modal', 'callback_id' => PREFIX + kind, 'private_metadata' => id.to_s,
        'title' => { 'type' => 'plain_text', 'text' => message(kind == 'create' ? 'new' : 'comment') },
        'submit' => { 'type' => 'plain_text', 'text' => message('save') },
        'close' => { 'type' => 'plain_text', 'text' => message('cancel') }, 'blocks' => blocks }
    end

    def attribute_key(kind)
      kind == 'assign' ? 'assignee' : 'status'
    end

    def error_key(kind)
      return attribute_key(kind) if %w[status assign].include?(kind)

      kind == 'create' ? 'subject' : 'comment'
    end

    def editable_issue(id, viewer, app, team, kind)
      issue = Issue.find_by(id: id)
      attribute = kind == 'assign' ? 'assigned_to_id' : 'status_id'
      return unless issue && authorized_project?(issue.project, app, team) &&
                    !issue.is_private? && issue.visible?(viewer) && WorkObjects.actions_enabled?(issue) &&
                    issue.attributes_editable?(viewer) && issue.safe_attribute?(attribute, viewer)

      issue
    end

    def attribute_modal(kind, id, viewer)
      issue = Issue.find_by(id: id)
      return unless issue

      key = attribute_key(kind)
      options = if kind == 'assign'
                  WorkObjects.assignee_options(issue)
                else
                  WorkObjects.select_options(issue.new_statuses_allowed_to(viewer))
                end
      return unless options && options.length.between?(1, 100)

      selected = kind == 'assign' ? (issue.assigned_to_id || 'none').to_s : issue.status_id.to_s
      element = { 'type' => 'static_select', 'options' => options }
      initial = options.find { |option| option['value'] == selected }
      element['initial_option'] = initial if initial
      { 'type' => 'modal', 'callback_id' => PREFIX + kind, 'private_metadata' => id.to_s,
        'title' => { 'type' => 'plain_text', 'text' => message(kind) },
        'submit' => { 'type' => 'plain_text', 'text' => message('save') },
        'close' => { 'type' => 'plain_text', 'text' => message('cancel') },
        'blocks' => issue_blocks(issue, actions: false) + [input(key, Formatter.field_label(key), element)] }
    end

    def interaction(app, team, payload)
      previous = User.current
      return {} unless enabled? && integration?(app, team)
      viewer = WorkObjects.viewer_for(payload.dig('user', 'id'))
      unless viewer
        key = error_key(payload.dig('view', 'callback_id').to_s.delete_prefix(PREFIX))
        return payload['type'] == 'view_submission' ? { 'response_action' => 'errors', 'errors' => { key => message('denied') } } : {}
      end
      if payload['type'] == 'block_actions'
        command = Array(payload['actions']).first&.fetch('value', '').to_s
        kind, id = command.split(/\s+/, 2)
        id = id.to_s.sub(/\A#/, '')
        if %w[create comment status assign].include?(kind) && id.match?(/\A[1-9]\d*\z/)
          object = kind == 'create' ? Project.find_by(id: id) : Issue.find_by(id: id)
          project = kind == 'create' ? object : object&.project
          allowed = if %w[status assign].include?(kind)
                      editable_issue(id, viewer, app, team, kind)
                    else
                      object && project && authorized_project?(project, app, team) &&
                        (kind == 'create' ? viewer.allowed_to?(:add_issues, project) : object.visible?(viewer) && object.notes_addable?(viewer) && !object.is_private?)
                    end
          return {} unless allowed
          view = modal(kind, id, viewer)
          return {} unless view && !payload['trigger_id'].to_s.empty?
          Slackmine.slack_api('views.open', { 'trigger_id' => payload['trigger_id'], 'view' => view }, Slackmine.bot_token)
        else
          SlackmineCommandJob.perform_later(app, team, { 'user_id' => payload.dig('user', 'id'),
            'channel_id' => payload.dig('channel', 'id'), 'text' => command })
        end
        return {}
      end
      return {} unless payload['type'] == 'view_submission'
      view = payload.fetch('view')
      kind = view['callback_id'].delete_prefix(PREFIX)
      return {} unless %w[create comment status assign].include?(kind)
      id = view['private_metadata'].to_s
      return {} unless id.match?(/\A[1-9]\d*\z/)
      values = view.dig('state', 'values') || {}
      error_key = error_key(kind)
      User.current = viewer
      return { 'response_action' => 'errors', 'errors' => { error_key => message('denied') } } if view['id'].to_s.empty?
      key = "slackmine:submission:#{Digest::SHA256.hexdigest([app, team, viewer.id, view['id']].join(':'))}"
      cache = Rails.cache
      return {} if cache.read(key) == 'done'
      unless cache.write(key, 'pending', unless_exist: true, expires_in: 86_400)
        return { 'response_action' => 'errors', 'errors' => { error_key => message('processing') } }
      end
      text = kind == 'create' ? values.dig('description', 'description', 'value') : values.dig('comment', 'comment', 'value')
      if %w[create comment].include?(kind) && text.to_s.match?(%r{\.slack\.com/archives/}i) &&
         background_form_valid?(kind, values) && background_form_allowed?(kind, id, viewer, app, team)
        fields = kind == 'create' ? values.slice('subject', 'description', 'tracker') : values.slice('comment')
        job = SlackmineCommandFormJob.perform_later(app, team, payload.dig('user', 'id'), kind, id, fields, viewer.id, view['id'])
        return {} if job
        cache.delete(key)
        return { 'response_action' => 'errors', 'errors' => { error_key => message('denied') } }
      end
      result = save_form(kind, id, values, viewer, app, team, error_key)
      if result.empty?
        cache.write(key, 'done', expires_in: 86_400)
      else
        cache.delete(key)
      end
      result
    ensure
      User.current = previous
    end

    def background_form_valid?(kind, values)
      if kind == 'create'
        subject = values.dig('subject', 'subject', 'value')
        description = values.dig('description', 'description', 'value').to_s
        subject.is_a?(String) && subject.length.between?(1, 255) && description.length <= 3000
      else
        note = values.dig('comment', 'comment', 'value').to_s.strip
        !note.empty? && note.length <= 3000
      end
    end

    def background_form_allowed?(kind, id, viewer, app, team)
      if kind == 'create'
        project = Project.find_by(id: id)
        project && authorized_project?(project, app, team) && viewer.allowed_to?(:add_issues, project)
      else
        issue = Issue.find_by(id: id)
        issue && authorized_project?(issue.project, app, team) && issue.visible?(viewer) &&
          issue.notes_addable?(viewer) && !issue.is_private?
      end
    end

    def complete_form(app, team, slack_user, kind, id, values, user_id, view_id)
      key = "slackmine:submission:#{Digest::SHA256.hexdigest([app, team, user_id, view_id].join(':'))}"
      return if Rails.cache.read(key) == 'done'
      viewer = WorkObjects.viewer_for(slack_user)
      unless viewer && viewer.id == user_id && enabled? && integration?(app, team)
        Rails.cache.delete(key)
        notify_background_form(slack_user, 'background_failed')
        return
      end
      previous = User.current
      User.current = viewer
      assigned_current = true
      result = save_form(kind, id, values, viewer, app, team, error_key(kind))
      saved = result.empty?
      Rails.cache.write(key, 'done', expires_in: 86_400) if saved
      Rails.cache.delete(key) unless saved
      notify_background_form(slack_user, saved ? 'background_saved' : 'background_failed')
    rescue StandardError => e
      # A failed or uncertain save must not be retried into a duplicate Issue.
      Rails.logger&.error("Slackmine: command form save failed: #{e.class}")
      notify_background_form(slack_user, 'background_failed') unless saved
    ensure
      User.current = previous if assigned_current
    end

    def notify_background_form(slack_user, key)
      Slackmine.slack_api('chat.postMessage', { 'channel' => slack_user, 'text' => message(key) }, Slackmine.bot_token)
    rescue StandardError => e
      Rails.logger&.error("Slackmine: command form notice failed: #{e.class}")
    end

    def save_form(kind, id, values, viewer, app, team, error_key)
      if kind == 'create'
        project = Project.find_by(id: id)
        if project && authorized_project?(project, app, team) && viewer.allowed_to?(:add_issues, project)
          issue = Issue.new(project: project, author: viewer)
          attrs = { 'subject' => values.dig('subject', 'subject', 'value'),
                    'description' => values.dig('description', 'description', 'value'),
                    'tracker_id' => values.dig('tracker', 'tracker', 'selected_option', 'value') }
          return { 'response_action' => 'errors', 'errors' => { error_key => message('denied') } } unless attrs['subject'].is_a?(String) && attrs['subject'].length.between?(1, 255) && attrs['description'].to_s.length <= 3000
          if issue.allowed_target_trackers(viewer).any? { |tracker| tracker.id.to_s == attrs['tracker_id'] }
            issue.send(:safe_attributes=, attrs, viewer)
            return {} if issue.save
            return { 'response_action' => 'errors', 'errors' => { error_key => issue.errors.full_messages.join('; ')[0, 1500] } }
          end
        end
      elsif %w[status assign].include?(kind)
        issue = editable_issue(id, viewer, app, team, kind)
        key = attribute_key(kind)
        value = values.dig(key, key, 'selected_option', 'value')
        valid = value.is_a?(String) && (value.match?(/\A[1-9]\d*\z/) || (kind == 'assign' && value == 'none'))
        if issue && valid
          attribute = kind == 'assign' ? :assigned_to_id : :status_id
          outcome = WorkObjects.update_issue(issue, viewer, **{ attribute => value })
          return {} if %i[saved unchanged].include?(outcome)
        end
      elsif kind == 'comment'
        issue = Issue.find_by(id: id)
        note = values.dig('comment', 'comment', 'value').to_s.strip
        if issue && authorized_project?(issue.project, app, team) && !note.empty? && note.length <= 3000
          outcome = WorkObjects.update_issue(issue, viewer, comment: note)
          return {} if outcome == :saved
        end
      end
      { 'response_action' => 'errors', 'errors' => { error_key => message('denied') } }
    end
  end
end
