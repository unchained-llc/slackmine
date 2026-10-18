# frozen_string_literal: true

module Slackmine
  module AdminOverview
    module_function

    # Code defaults, not the recommended values in slackmine.yml.example.
    # Context-dependent defaults are kept separate from unset values.
    DEFAULT_VALUES = {
      'slack.files.restrict_transfer' => false, 'slack.files.force_restrict_transfer' => false,
      'slack.link_cards.enabled' => true, 'slack.link_cards.redmine_enabled' => true,
      'slack.link_cards.mail_enabled' => true, 'slack.link_cards.color' => '#6D5DFB',
      'slack.slash_command' => nil, 'slack.bot_token' => nil, 'slack.default_channel_id' => nil,
      'slack.auto_map_users_by_name' => false, 'slack.auto_map_users_by_email' => false,
      'slack.auto_map_channels_by_name' => false, 'slack.work_object_previews' => false,
      'slack.work_object_actions' => false, 'slack.work_object_start_status_id' => nil,
      'slack.work_object_complete_status_id' => nil, 'slack.thread_comments' => false,
      'slack.thread_connections' => true, 'slack.suppress_thread_comment_notifications' => true,
      'slack.thread_comment_batch.wait_seconds' => 0, 'slack.thread_comment_batch.max_wait_seconds' => 300,
      'slack.thread_comment_feedback_cleanup_seconds' => -1, 'slack.app_home' => false,
      'slack.notification_coalescing.enabled' => false, 'slack.notification_coalescing.seconds' => 300,
      'slack.comment_notifications_in_threads' => false, 'slack.events.app_id' => nil,
      'slack.events.team_id' => nil, 'slack.events.signing_secret' => nil,
      'slack.body_diff' => true, 'slack.attachment_color' => '#6D5DFB',
      'slack.issue_changes_when_hidden' => true, 'due_reminders.enabled' => true,
      'due_reminders.days' => 3, 'due_reminders.colors.overdue' => '#D92D20',
      'due_reminders.colors.today' => '#F79009', 'due_reminders.colors.upcoming' => :conditional,
      'channel_id' => nil
    }.freeze

    def default_value(key)
      return DEFAULT_VALUES[key] if DEFAULT_VALUES.key?(key)

      parts = key.split('.')
      case key
      when /\Amessages\./
        defaults = Formatter::DEFAULT_MESSAGES
        parts.drop(1).each do |part|
          return :unknown unless defaults.is_a?(Hash) && defaults.key?(part)
          defaults = defaults[part]
        end
        defaults
      when /\Aevents\./
        return true if key == 'events.issue.updated.enabled'
        event = Slackmine::EVENT_PATHS.find { |_, path| path == parts.drop(1) }&.first
        event ? !Slackmine::DEFAULT_DISABLED_EVENTS.include?(event) : :unknown
      when /\Aslack\.work_object_fields\./ then false
      when /\Aslack\.work_object_buttons\./
        %w[add_comment open_issue edit_issue assign_to_me].include?(parts.last) ? :conditional : false
      when /\Aslack\.body_diff\./ then true
      when /\Aslack\.metadata\./
        return :conditional if parts.include?('custom_fields') && parts.length > 4
        return :conditional if parts.include?('created') || parts.include?('updated')
        parts[2] != 'issue' || !Formatter::ISSUE_OPTIONAL_METADATA_KEYS.include?(parts[3])
      when /\Ausers\./ then nil
      else :unknown
      end
    end

    def comparison(settings)
      settings = settings.dup
      if settings['messages'].is_a?(Hash) && settings['messages']['colors'].is_a?(Hash)
        settings['messages.colors'] = settings['messages']['colors']
        settings['messages'] = settings['messages'].reject { |key, _| key == 'colors' }
      end
      settings.to_h do |group, values|
        entries = rows({ group => values }).map do |key, value|
          default = default_value(key)
          if key.start_with?('messages.colors.')
            default = settings.dig('slack', 'attachment_color')
            default = '#6D5DFB' unless color?(default)
          end
          comparable = !%i[unknown conditional].include?(default)
          changed = comparable && value != default && !(default.nil? && value.to_s.empty?)
          { key: key, value: value, default: default, changed: changed }
        end
        [group, entries]
      end
    end

    def conditional_default(key, &translate)
      help = ->(name, **options) { translate.call("slackmine_admin_help.defaults.#{name}", **options) }
      case key
      when /\Aslack\.work_object_buttons\./
        notification = %w[add_comment open_issue].include?(key.split('.').last)
        help.call('button', notification: notification.to_s, detail: (!notification).to_s)
      when 'due_reminders.colors.upcoming'
        help.call('upcoming')
      when /\.custom_fields\./
        help.call('custom_field')
      when /\Aslack\.metadata\.issue\.(created|updated)\./
        parts = key.split('.')
        value = parts[3] == 'created' && !Formatter::ISSUE_OPTIONAL_METADATA_KEYS.include?(parts[4])
        help.call('legacy_metadata', value: value.to_s)
      else
        translate.call('label_slackmine_admin_default_conditional')
      end
    end

    def default_rule(key, &translate)
      rule = case key
             when /\Aslack\.work_object_buttons\./ then 'button'
             when /\Aslack\.metadata\..*\.custom_fields\./ then 'custom_field'
             when /\Aslack\.metadata\.issue\.(created|updated)\./ then 'legacy_metadata'
             end
      translate.call("slackmine_admin_help.default_rules.#{rule}") if rule
    end

    EXPLAINED_SETTINGS = %w[
      slack.files.restrict_transfer slack.files.force_restrict_transfer
      slack.link_cards.enabled slack.link_cards.redmine_enabled slack.link_cards.mail_enabled
      slack.link_cards.color slack.link_cards.link_text slack.slash_command slack.bot_token
      slack.default_channel_id slack.auto_map_users_by_name slack.auto_map_users_by_email
      slack.auto_map_channels_by_name slack.work_object_previews slack.work_object_actions
      slack.work_object_start_status_id slack.work_object_complete_status_id
      slack.thread_comments slack.thread_connections slack.suppress_thread_comment_notifications
      slack.thread_comment_batch.wait_seconds slack.thread_comment_batch.max_wait_seconds
      slack.thread_comment_feedback_cleanup_seconds slack.app_home slack.comment_notifications_in_threads
      slack.notification_coalescing.enabled slack.notification_coalescing.seconds
      slack.events.app_id slack.events.team_id slack.events.signing_secret
      slack.body_diff slack.attachment_color slack.issue_changes_when_hidden
      due_reminders.enabled due_reminders.days due_reminders.colors.overdue
      due_reminders.colors.today due_reminders.colors.upcoming channel_id
      messages.work_objects.product_name messages.work_objects.display_type
      events.issue.updated.enabled
    ].freeze

    # The view supplies Redmine's translator so descriptions follow the UI locale,
    # independently of the Slack notification wording configured by an operator.
    def description(key, &translate)
      help = ->(name, **options) { translate.call("slackmine_admin_help.#{name}", **options) }
      return help.call(key.tr('.', '_')) if EXPLAINED_SETTINGS.include?(key)

      parts = key.split('.')
      field = ->(name) { help.call("fields.#{name}") }
      target = ->(name) { help.call("targets.#{name}") }
      case key
      when /\Aslack\.work_object_buttons\./
        help.call('button', action: help.call("buttons.#{parts.last}"))
      when /\Aslack\.work_object_fields\./
        help.call('card_field', field: field.call(parts.last))
      when /\Aslack\.metadata\./
        field_index = %w[created updated].include?(parts[3]) ? 4 : 3
        name = parts[field_index] == 'custom_fields' ? help.call('custom_field', id: parts[field_index + 1]) : field.call(parts[field_index])
        help.call('metadata', target: target.call(parts[2]), field: name)
      when /\Aslack\.body_diff\./
        help.call('body_diff', target: target.call(parts[2]), field: field.call(parts[3]))
      when /\Aevents\./
        event = Slackmine::EVENT_PATHS.find { |_, path| path == parts.drop(1) }&.first
        if event
          help.call(parts[1] == 'issue' && parts[2] == 'updated' ? 'issue_event' : 'event',
                    event: help.call("events.#{event}"))
        else
          help.call('unknown')
        end
      when /\Ausers\./
        help.call('user', user: parts.drop(1).join('.'))
      when /\Amessages\.colors\./
        help.call('event_color', target: target.call(parts[2]), action: help.call("actions.#{parts[3]}"))
      when /\Amessages\.icons\./
        help.call('icon', target: target.call(parts[2]))
      when /\Amessages\./
        help.call('message', context: help.call("message_groups.#{parts[1]}"))
      else
        help.call('unknown')
      end
    end

    def missing_configuration
      files = { 'slackmine.yml' => Slackmine.config_paths,
                'slackmine.messages.yml' => Slackmine.messages_config_paths }
      files.each_with_object([]) do |(name, paths), missing|
        missing << name unless paths.any? { |path| File.file?(path) }
      end
    end

    # Mask credentials before handing any configuration to a view.
    def redact(value)
      case value
      when Hash
        value.to_h do |key, child|
          [key, key.to_s.match?(/token|secret|password|credential|authorization|api[_-]?key/i) ?
            (child.to_s.empty? ? '' : '[FILTERED]') : redact(child)]
        end
      when Array
        value.map { |child| redact(child) }
      else
        value
      end
    end

    def settings(project)
      settings = Slackmine.effective_config(project).reject { |key, _| key == 'projects' }
      settings = Slackmine.merge_config(settings, 'slack' => { 'bot_token' => Slackmine.bot_token(project) })
      settings['messages'] = Slackmine.merge_config(Slackmine::Formatter::DEFAULT_MESSAGES, Slackmine.message_settings(project))
      fallback = settings.dig('slack', 'attachment_color')
      fallback = '#6D5DFB' unless color?(fallback)
      colors = Formatter::DEFAULT_MESSAGES.fetch('icons').to_h do |target, actions|
        [target, actions.to_h { |action, _| [action, fallback] }]
      end
      configured_colors = settings['messages']['colors']
      if configured_colors.is_a?(Hash)
        rows(configured_colors).each do |path, value|
          target, action = path.split('.')
          colors[target][action] = value if colors[target].is_a?(Hash) && color?(value)
        end
      end
      settings['messages'] = settings['messages'].merge('colors' => colors)
      redact(settings)
    end

    def color?(value)
      value.is_a?(String) && value.match?(/\A#[0-9a-fA-F]{6}\z/)
    end

    def rows(value, prefix = '')
      value.flat_map do |key, child|
        path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
        child.is_a?(Hash) && !child.empty? ? rows(child, path) : [[path, child]]
      end
    end

    def display(value)
      value.nil? ? 'null' : value.is_a?(String) ? value : value.inspect
    end
  end
end
