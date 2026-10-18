# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'yaml'
require 'digest'

module Slackmine
  EVENT_PATHS = {
    'issue_created' => %w[issue created],
    'issue_updated' => %w[issue updated other_changed],
    'issue_deleted' => %w[issue deleted],
    'comment_added' => %w[issue comment added],
    'comment_updated' => %w[issue comment updated],
    'comment_deleted' => %w[issue comment deleted],
    'relation_added' => %w[issue updated relation added],
    'relation_removed' => %w[issue updated relation removed],
    'status_changed' => %w[issue updated status_changed],
    'assignee_changed' => %w[issue updated assignee_changed],
    'priority_changed' => %w[issue updated priority_changed],
    'category_changed' => %w[issue updated category_changed],
    'due_date_changed' => %w[issue updated due_date_changed],
    'start_date_changed' => %w[issue updated start_date_changed],
    'version_changed' => %w[issue updated version_changed],
    'subject_changed' => %w[issue updated subject_changed],
    'description_changed' => %w[issue updated description_changed],
    'custom_field_changed' => %w[issue updated custom_field_changed],
    'attachment_added' => %w[issue updated attachment added],
    'attachment_removed' => %w[issue updated attachment removed],
    'parent_changed' => %w[issue updated parent_changed],
    'child_added' => %w[issue updated child added],
    'child_removed' => %w[issue updated child removed],
    'wiki_created' => %w[wiki created],
    'wiki_updated' => %w[wiki updated],
    'wiki_deleted' => %w[wiki deleted],
    'news_created' => %w[news created],
    'news_updated' => %w[news updated],
    'news_deleted' => %w[news deleted],
    'news_comment_added' => %w[news comment added],
    'news_comment_updated' => %w[news comment updated],
    'news_comment_deleted' => %w[news comment deleted],
    'time_entry_created' => %w[time_entry created],
    'time_entry_updated' => %w[time_entry updated],
    'time_entry_deleted' => %w[time_entry deleted],
    'version_created' => %w[version created],
    'version_updated' => %w[version updated],
    'version_deleted' => %w[version deleted],
    'document_created' => %w[document created],
    'document_file_added' => %w[document file added],
    'document_file_deleted' => %w[document file deleted],
    'file_added' => %w[file added],
    'file_deleted' => %w[file deleted],
    'message_posted' => %w[message posted],
    'document_updated' => %w[document updated],
    'document_deleted' => %w[document deleted],
    'document_file_updated' => %w[document file updated],
    'file_updated' => %w[file updated],
    'message_updated' => %w[message updated],
    'message_deleted' => %w[message deleted],
    'project_updated' => %w[project updated]
  }.transform_values(&:freeze).freeze
  EVENT_KEYS = EVENT_PATHS.keys.freeze
  ISSUE_DETAIL_EVENTS = EVENT_PATHS.select do |key, path|
    key != 'issue_updated' && path.first(2) == %w[issue updated]
  end.keys.freeze
  ISSUE_UPDATE_PARENT_PATH = %w[issue updated enabled].freeze
  DEFAULT_DISABLED_EVENTS = %w[wiki_deleted news_deleted time_entry_deleted version_deleted file_deleted document_file_deleted document_deleted message_deleted].freeze
  BODY_DIFF_PATHS = {
    issue_description: %w[issue description], issue_comment: %w[issue comment],
    document_description: %w[document description], message_body: %w[message body],
    wiki_body: %w[wiki body], news_description: %w[news description], news_comment: %w[news comment]
  }.freeze

  class SlackApiError < StandardError
    attr_reader :code

    def initialize(method, status, result)
      @code = result['error']
      details = Array(result.dig('response_metadata', 'messages')).join('; ')
      super("Slack #{method} returned #{status}: #{@code || 'unknown error'}#{details.empty? ? '' : " (#{details})"}")
    end

    def unready_image_file?
      %w[invalid_blocks invalid_attachments].include?(code) && message.match?(/invalid (?:slack file|file type)/)
    end
  end

  module_function

  def config
    @config ||= begin
      path = config_paths.find { |candidate| File.exist?(candidate) }
      unless path
        Rails.logger&.warn("Slackmine: config file not found: #{config_paths.join(', ')}")
        {}
      else
        YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      end
    rescue StandardError => e
      Rails.logger&.error("Slackmine: cannot load #{path}: #{e.class}: #{e.message}")
      {}
    end
  end

  def config_paths
    [
      (Rails.root.join('config', 'slackmine.yml') if Rails.respond_to?(:root)),
      File.expand_path('../config/slackmine.yml', __dir__)
    ].compact
  end

  def config_path
    config_paths.first
  end

  def messages_config
    @messages_config ||= begin
      path = messages_config_paths.find { |candidate| File.exist?(candidate) }
      path ? (YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}) : {}
    rescue StandardError => e
      Rails.logger&.error("Slackmine: cannot load #{path}: #{e.class}: #{e.message}")
      {}
    end
  end

  def messages_config_paths
    [
      (Rails.root.join('config', 'slackmine.messages.yml') if Rails.respond_to?(:root)),
      File.expand_path('../config/slackmine.messages.yml', __dir__)
    ].compact
  end

  def message_settings(project = Thread.current[:slackmine_project])
    separate = messages_config
    global = merge_config(message_hash(effective_config(nil)['messages']), message_hash(separate['messages']))
    return global unless project

    legacy_project = message_hash(project_config(project)['messages'])
    separate_projects = separate['projects']
    separate_project = separate_projects[project.identifier.to_s] if separate_projects.is_a?(Hash)
    separate_project = message_hash(separate_project['messages']) if separate_project.is_a?(Hash)
    merge_config(global, merge_config(legacy_project, message_hash(separate_project)))
  end

  def message_hash(value)
    value.is_a?(Hash) ? value : {}
  end

  def project_config(project)
    return {} unless project

    projects = config['projects']
    settings = projects[project.identifier.to_s] if projects.is_a?(Hash)
    settings.is_a?(Hash) ? settings : {}
  end

  def merge_config(base, overrides)
    return overrides unless base.is_a?(Hash) && overrides.is_a?(Hash)

    base.merge(overrides) do |_key, original, replacement|
      merge_config(original, replacement)
    end
  end

  def with_project(project)
    previous = Thread.current[:slackmine_project]
    Thread.current[:slackmine_project] = project
    yield
  ensure
    Thread.current[:slackmine_project] = previous
  end

  def effective_config(project = Thread.current[:slackmine_project])
    project ? merge_config(config, project_config(project)) : config
  end

  def files_transfer_restricted?(project = Thread.current[:slackmine_project])
    return true if config.dig('slack', 'files', 'force_restrict_transfer') == true

    effective_config(project).dig('slack', 'files', 'restrict_transfer') == true
  end

  def bot_token(project = Thread.current[:slackmine_project])
    project_slack = project_config(project)['slack']
    project_token = project_slack['bot_token'] if project_slack.is_a?(Hash)
    project_token.to_s.strip.presence || ENV['SLACK_BOT_TOKEN'].to_s.strip.presence ||
      config.dig('slack', 'bot_token').to_s.strip
  end

  def body_diff_enabled?(kind = nil)
    setting = effective_config.dig('slack', 'body_diff')
    return setting != false unless setting.is_a?(Hash)
    return true unless kind

    path = BODY_DIFF_PATHS.fetch(kind)
    path.each do |key|
      return false if setting == false
      return true unless setting.is_a?(Hash) && setting.key?(key)

      setting = setting[key]
    end
    setting != false
  end

  def channel_id(project)
    return '' unless project

    current = project
    seen = {}
    automatic = effective_config(project).dig('slack', 'auto_map_channels_by_name') == true
    while current && !seen[current.identifier]
      seen[current.identifier] = true
      settings = project_config(current)
      project_slack = settings['slack']
      project_channel = project_slack['default_channel_id'].to_s.strip.presence if project_slack.is_a?(Hash)
      project_channel ||= settings['channel_id'].to_s.strip.presence
      return project_channel if project_channel
      channel = ChannelMatching.channel_for(current) if automatic
      return channel if channel

      current = current.respond_to?(:parent) ? current.parent : nil
    end
    config.dig('slack', 'default_channel_id').to_s.strip
  end

  def user_mapping
    mapping = effective_config['users']
    mapping.is_a?(Hash) ? mapping : {}
  end

  def slack_user_id_for(user, by_email: true)
    match = slack_user_match_for(user, by_email: by_email)
    match[:id] if match
  end

  def slack_user_match_for(user, by_email: true)
    return unless user.is_a?(User)

    mapping = user_mapping
    id = mapping[user.login.to_s] || mapping[user.mail.to_s]
    method = mapping[user.login.to_s] ? :explicit_login : :explicit_email
    unless id == false || id.to_s.strip.empty?
      id = id.to_s.strip
      return { id: id, method: method } if id.match?(/\A[UW][A-Z0-9]+\z/)
      return nil
    end

    automatic_user_matching_order.each do |candidate|
      next if candidate == :email && !by_email

      id = candidate == :name ? slack_user_id_for_name(user.login) : slack_user_id_for_email(user.mail)
      id = id.to_s.strip
      return { id: id, method: candidate } if id.match?(/\A[UW][A-Z0-9]+\z/)
    end
    nil
  end

  def automatic_user_matching_order
    keys = %w[auto_map_users_by_name auto_map_users_by_email]
    settings = effective_config['slack']
    configured = settings.is_a?(Hash) ? settings.keys & keys : []
    # Hash#merge keeps the original key positions. When a project specifies
    # both switches, use their order in that project's YAML instead.
    project_settings = project_config(Thread.current[:slackmine_project])['slack']
    project_keys = project_settings.is_a?(Hash) ? project_settings.keys & keys : []
    configured = project_keys if project_keys.length == 2
    (configured + keys).uniq.map { |key| key == 'auto_map_users_by_name' ? :name : :email }
  end

  # Display/outgoing identity only: authorization still fetches fresh users.info.
  # Cache hashed email keys and Slack IDs, never raw emails or Slack profiles.
  def slack_user_id_for_email(email)
    return unless effective_config.dig('slack', 'auto_map_users_by_email') == true

    email = email.to_s.strip.downcase
    token = bot_token
    return if email.empty? || token.to_s.empty?

    token_key = Digest::SHA256.hexdigest(token)
    failure_key = "slackmine/outgoing-email-failure/#{token_key}"
    return if Rails.cache&.read(failure_key)

    team_id = effective_config.dig('slack', 'events', 'team_id').to_s
    cache_key = "slackmine/email-users/#{token_key}/#{Digest::SHA256.hexdigest(team_id)}"
    directory = if Rails.cache
                  Rails.cache.fetch(cache_key, expires_in: 600) { fetch_slack_email_directory(token, team_id) }
                else
                  fetch_slack_email_directory(token, team_id)
                end
    ids = directory[Digest::SHA256.hexdigest(email)]
    ids.first if ids && ids.length == 1
  rescue StandardError => e
    Rails.cache&.write(failure_key, true, expires_in: 60) if failure_key
    code = if e.is_a?(SlackApiError)
             e.code.to_s.match?(/\A[a-z0-9_]+\z/) ? e.code : 'unknown_error'
           end
    Rails.logger&.warn("Slackmine: outgoing email user matching failed: #{e.class}#{code ? " code=#{code}" : ''} (retry in 60s)")
    nil
  end

  def fetch_slack_email_directory(token, team_id)
    directory = Hash.new { |hash, email_key| hash[email_key] = [] }
    cursor = nil
    seen = {}
    10.times do
      params = { 'limit' => 200 }
      params['cursor'] = cursor if cursor
      response = slack_api('users.list', params, token, form: true, open_timeout: 2, read_timeout: 3)
      raise 'Invalid Slack users.list members' unless response['members'].is_a?(Array)

      response['members'].each do |member|
        next unless member.is_a?(Hash) && member['id'].to_s.match?(/\A[UW][A-Z0-9]+\z/)
        next if member['deleted'] || member['is_bot'] || member['is_app_user'] || member['is_stranger']
        next unless team_id.empty? || (member['team_id'] || member['team']) == team_id
        next unless member['profile'].is_a?(Hash)

        email = member['profile']['email'].to_s.strip.downcase
        next if email.empty?

        ids = directory[Digest::SHA256.hexdigest(email)]
        ids << member['id'] unless ids.include?(member['id'])
      end
      cursor = response.dig('response_metadata', 'next_cursor').to_s.strip
      return directory.each_with_object({}) { |(key, ids), result| result[key] = ids } if cursor.empty?
      raise 'Repeated Slack users.list cursor' if seen[cursor]

      seen[cursor] = true
    end
    raise 'Slack users.list exceeded 10 pages'
  end

  def due_reminder_settings(project = nil)
    settings = effective_config(project)['due_reminders']
    settings = {} unless settings.is_a?(Hash)
    days = Integer(settings.fetch('days', 3), exception: false)
    { enabled: settings['enabled'] != false, days: days && days.between?(0, 365) ? days : 3 }
  end

  def due_reminder_max_days
    projects = config['projects']
    project_days = projects.is_a?(Hash) ? projects.values.each_with_object([]) do |settings, days_list|
      next unless settings.is_a?(Hash) && settings['due_reminders'].is_a?(Hash)

      days = Integer(settings['due_reminders']['days'], exception: false)
      days_list << days if days && days.between?(0, 365)
    end : []
    ([due_reminder_settings[:days]] + project_days).max
  end

  def due_reminder_filter_scope(scope, options)
    scope = scope.where(project_id: options['project_id']) if options.key?('project_id')
    scope = scope.where(tracker_id: options['tracker_id']) if options.key?('tracker_id')
    scope = scope.where(fixed_version_id: options['version_ids']) if options.key?('version_ids')
    scope
  end

  def slack_user_id_for_name(name)
    return nil unless effective_config.dig('slack', 'auto_map_users_by_name') == true

    key = name.to_s.strip.downcase
    return nil if key.empty?

    ids = slack_user_directory[key]
    ids.first if ids&.length == 1
  end

  def slack_user_directory
    token = bot_token
    return {} if token.empty?

    cache_key = "slackmine/users/#{Digest::SHA256.hexdigest(token)}"
    Rails.cache.fetch(cache_key, expires_in: 600) do
      fetch_slack_user_directory(token)
    rescue StandardError => e
      Rails.logger.warn("Slackmine: could not load Slack users: #{e.class}: #{e.message}")
      {}
    end
  end

  def fetch_slack_user_directory(token)
    directory = Hash.new { |hash, name| hash[name] = [] }
    cursor = nil
    seen_cursors = {}
    loop do
      params = { 'limit' => 200 }
      params['cursor'] = cursor if cursor
      response = slack_api('users.list', params, token, form: true, open_timeout: 2, read_timeout: 3)
      Array(response['members']).each do |member|
        next unless member.is_a?(Hash) && member['id'].to_s != ''
        next if member['deleted'] || member['is_bot'] || member['is_app_user'] || member['is_stranger']

        profile = member['profile'].is_a?(Hash) ? member['profile'] : {}
        [profile['display_name'], member['name']].each do |value|
          name = value.to_s.strip.downcase
          directory[name] << member['id'] unless name.empty? || directory[name].include?(member['id'])
        end
      end
      cursor = response.dig('response_metadata', 'next_cursor').to_s
      break if cursor.empty?

      raise 'Slack users.list returned a repeated cursor' if seen_cursors[cursor]

      seen_cursors[cursor] = true
    end
    directory.each_with_object({}) { |(name, ids), result| result[name] = ids }
  end

  def configured?(project)
    bot_token(project).present? && channel_id(project).present?
  end

  def event_enabled?(project, event)
    key = event.to_s
    raise ArgumentError, "Unknown Slack notification event: #{key}" unless EVENT_KEYS.include?(key)

    projects = config['projects']
    project_config = projects[project.identifier.to_s] if projects.is_a?(Hash) && project
    project_events = project_config['events'] if project_config.is_a?(Hash)
    events = config['events']
    if key == 'issue_updated' || ISSUE_DETAIL_EVENTS.include?(key)
      return false unless configured_event_enabled?(project_events, events, ISSUE_UPDATE_PARENT_PATH,
                                                    legacy_key: 'issue_updated', default: true)
    end

    configured_event_enabled?(project_events, events, EVENT_PATHS.fetch(key),
                              legacy_key: key == 'issue_updated' ? nil : key,
                              default: !DEFAULT_DISABLED_EVENTS.include?(key))
  end

  def configured_event_enabled?(project_events, events, path, legacy_key:, default:)
    [project_events, events].each do |scope|
      next unless scope.is_a?(Hash)

      found, value = nested_event_value(scope, path)
      return value != false if found
      return scope[legacy_key] != false if legacy_key && scope.key?(legacy_key)
    end

    default
  end

  def nested_event_value(scope, path)
    path.each do |part|
      return [false, nil] unless scope.is_a?(Hash) && scope.key?(part)

      scope = scope[part]
    end
    [true, scope]
  end

  def enqueue(payload, project:, event: nil, image_names: [], journal_id: nil, issue_id: nil, source: nil)
    return unless project
    return if event && !event_enabled?(project, event)
    context = NotificationSafety.context(project, event, issue_id, journal_id, source: source)
    return unless context
    payload = payload.merge('_slackmine_delivery_context' => context)

    # Keep the four-argument job contract for workers still running the
    # previous release. Journal IDs are positive; a negative ID identifies
    # an Issue whose attachments belong to its creation notification.
    image_source_id = issue_id ? -issue_id : journal_id
    SlackmineNotificationJob.perform_later(payload, project.id, image_names, image_source_id)
  end

  def notify(payload, project: nil, image_names: [], journal_id: nil, issue_id: nil)
    with_project(project) do
      token = bot_token(project)
      channel = channel_id(project)
      unless token.present? && channel.present?
        Rails.logger.warn("Slackmine: Slack API is not configured for project #{project&.identifier || '(none)'} (token/channel missing)")
        return
      end

      payload = payload.dup
      context = payload.delete('_slackmine_delivery_context')
      return if context && !NotificationSafety.allowed?(context, project)
      actor_id = payload.delete('_slackmine_actor_id')
      notification_actor_id = actor_id
      avatar_parts = payload.delete('_slackmine_avatar_parts')
      comment_issue_id = payload.delete('_slackmine_comment_issue_id')
      thread_payload = payload.delete('_slackmine_thread_comment_payload')
      if comment_issue_id && NotificationCoalescing.window_seconds.zero? &&
         effective_config.dig('slack', 'comment_notifications_in_threads') == true
        thread_ts = CommentThreads.latest_thread(comment_issue_id, channel, token)
        if thread_ts
          payload = thread_payload if thread_payload.is_a?(Hash)
          actor_id = nil if thread_payload.is_a?(Hash)
          avatar_parts = nil if thread_payload.is_a?(Hash)
          payload = payload.merge('thread_ts' => thread_ts)
        end
      end
      payload = with_notification_avatar(payload, actor_id, token, heading_parts: avatar_parts) if actor_id
      add_images(payload, image_names, journal_id, token, issue_id: issue_id) if image_names.present? && (journal_id || issue_id)
      # Profile/file API calls can take time; recheck after them as well.
      return if context && !NotificationSafety.allowed?(context, project)
      notification_parts = NotificationCoalescing.extract_parts!(payload)
      NotificationCoalescing.deliver(payload, project: project, context: context,
                                     actor_id: notification_actor_id, channel: channel, token: token,
                                     parts: notification_parts)
    end
  rescue StandardError => e
    Rails.logger.error("Slackmine: #{e.class}: #{e.message}")
    raise
  end

  def with_notification_avatar(payload, actor_id, token, heading_parts: nil)
    heading = payload.dig('attachments', 0, 'blocks', 0)
    return payload unless heading && heading['type'] == 'section' && heading.dig('text', 'type') == 'mrkdwn'
    return payload if heading['accessory']
    return payload unless heading_parts && heading_parts.length.between?(2, 5)

    actor = User.find_by(id: actor_id)
    slack_id = slack_user_id_for(actor)
    return payload unless slack_id

    cache_key = "slackmine/notification-avatar-inline/#{Digest::SHA256.hexdigest(token)}/#{slack_id}"
    avatar = Rails.cache.fetch(cache_key, expires_in: 600) do
      response = slack_api('users.info', { 'user' => slack_id }, token, form: true, open_timeout: 2, read_timeout: 3)
      profile = response.dig('user', 'profile') || {}
      candidate = %w[image_48 image_32 image_24].map { |key| profile[key] }.find { |value| !value.to_s.empty? }
      uri = URI.parse(candidate.to_s)
      uri.scheme == 'https' && uri.host && !uri.userinfo ? uri.to_s : ''
    rescue SlackApiError, URI::InvalidURIError, Timeout::Error, IOError, SystemCallError
      ''
    end
    return payload if avatar.to_s.empty?

    image = { 'type' => 'image', 'image_url' => avatar, 'alt_text' => actor.name.to_s.truncate(2000) }
    elements = []
    heading_parts.each_with_index do |part, index|
      elements << image.dup if index.positive?
      elements << heading['text'].merge('text' => part.strip) unless part.strip.empty?
    end
    blocks = payload.dig('attachments', 0, 'blocks').dup
    blocks[0] = { 'type' => 'context', 'elements' => elements }
    blocks[0]['_slackmine_part'] = heading['_slackmine_part'] if heading.key?('_slackmine_part')
    attachments = payload['attachments'].dup
    attachments[0] = attachments[0].merge('blocks' => blocks)
    payload.merge('attachments' => attachments)
  rescue StandardError => e
    # An optional profile lookup must never prevent the notification delivery.
    Rails.logger.warn("Slackmine: notification avatar unavailable: #{e.class}")
    payload
  end

  def post_message(payload, channel, token, ts: nil)
    image_ids = Array(payload['attachments']).flat_map { |attachment| Array(attachment['blocks']) }.each_with_object([]) do |block, ids|
      ids << block.dig('slack_file', 'id') if block['type'] == 'image'
    end.compact.uniq
    request = payload.merge('channel' => channel)
    if ts
      request.delete('thread_ts') # chat.update identifies replies by their own ts.
      request.merge!('ts' => ts, 'text' => payload.fetch('text', ''),
                     'blocks' => payload.fetch('blocks', []), 'metadata' => payload.fetch('metadata', {}))
    end
    request.merge!('unfurl_links' => false, 'unfurl_media' => false) if files_transfer_restricted?
    if image_ids.any?
      summary = payload['text'].to_s
      summary = payload.dig('attachments', 0, 'fallback').to_s if summary.strip.empty?
      request['text'] = summary
      # A private Slack file becomes available to the channel when referenced
      # in a top-level image element. Keep the colored attachment from the
      # first post, then remove these temporary small previews.
      request['blocks'] = image_ids.map do |file_id|
        {
          'type' => 'section',
          'text' => { 'type' => 'plain_text', 'text' => summary[0, 3000] },
          'accessory' => { 'type' => 'image', 'slack_file' => { 'id' => file_id }, 'alt_text' => Formatter.message('images', 'alt') }
        }
      end
    end

    posted = post_with_image_retry(request, token, method: ts ? 'chat.update' : 'chat.postMessage')
    return posted if image_ids.empty?

    begin
      update = {
        'channel' => channel,
        'ts' => posted.fetch('ts'),
        'text' => '',
        'blocks' => [],
        'attachments' => payload.fetch('attachments')
      }
      if payload.key?('metadata')
        update['metadata'] = payload['metadata']
        update['text'] = payload['text']
      end
      post_with_image_retry(update, token, method: 'chat.update')
    rescue StandardError => e
      # The initial message already contains the complete colored card. Do
      # not retry the job and post a second notification if cleanup fails.
      Rails.logger.error("Slackmine: could not remove temporary image previews from #{channel}/#{posted['ts']}: #{e.class}: #{e.message}")
    end
    posted
  end

  def post_with_image_retry(request, token, method: 'chat.postMessage')
    retries = 0
    begin
      # Match Slack's Work Object documentation and official SDK transport:
      # entity metadata is JSON-serialized inside a URL-encoded form.
      work_object = request.dig('metadata', 'entities').is_a?(Array)
      result = work_object ? slack_api(method, request, token, form: true) : slack_api(method, request, token)
      if work_object
        message = result['message'].is_a?(Hash) ? result['message'] : {}
        metadata = message['metadata'].is_a?(Hash) ? message['metadata'] : {}
        summary = {
          method: method, ts: result['ts'], metadata_keys: metadata.keys,
          returned_entity_count: Array(metadata['entities']).length,
          attachment_count: Array(message['attachments']).length,
          warnings: Array(result.dig('response_metadata', 'warnings')),
          messages: Array(result.dig('response_metadata', 'messages'))
        }
        Rails.logger&.info("Slackmine: Work Object response #{JSON.generate(summary)}")
      end
      result
    rescue SlackApiError => e
      image_message = Array(request['blocks']).any? { |block| block['type'] == 'image' || block.dig('accessory', 'slack_file', 'id') } ||
        Array(request['attachments']).any? { |attachment| Array(attachment['blocks']).any? { |block| block['type'] == 'image' } }
      raise unless image_message && e.unready_image_file? && retries < 3

      sleep([1, 2, 4][retries])
      retries += 1
      retry
    end
  end

  def add_images(payload, image_names, journal_id, token, issue_id: nil)
    journal = Journal.find_by(id: journal_id) if journal_id
    issue = journal ? journal.journalized : Issue.find_by(id: issue_id)
    return unless issue.is_a?(Issue) && !issue.is_private?
    return if journal&.private_notes?

    source_attachments = journal ? journal.attachments : issue.attachments
    attachments = source_attachments.each_with_object({}) { |attachment, indexed| indexed[attachment.filename.downcase] = attachment }
    blocks = payload['blocks'] || payload.dig('attachments', 0, 'blocks')
    return unless blocks

    eligible_names = image_names.to_h { |name| [name.downcase, name] }
    upload_results = {}
    ordered_blocks = blocks.flat_map do |block|
      markdown_block = block['type'] == 'markdown'
      content = markdown_block ? block['text'] : block.dig('text', 'text')
      next [block] unless content.is_a?(String)
      next [block] if content.match?(/\A\*{1,2}[^\n]+\*{1,2}\n\n?`{3,}(?:diff)?\n/)

      with_text = lambda do |value|
        markdown_block ? block.merge('text' => value) : block.merge('text' => block['text'].merge('text' => value))
      end

      pieces = []
      current_text = +''
      cursor = 0
      found_eligible = false
      content.to_enum(:scan, /!\[[^\]\n]*\]\(([^)\n]+)\)/i).each do
        match = Regexp.last_match
        current_text << content[cursor...match.begin(0)]
        name = eligible_names[match[1].downcase]
        if name
          found_eligible = true
          attachment = attachments[name.downcase]
          file_id = upload_results.fetch(name) { upload_results[name] = upload_image(attachment, token) if attachment } unless files_transfer_restricted?
          if file_id
            text_before = current_text.strip
            pieces << with_text.call(text_before) unless text_before.empty?
            pieces << { 'type' => 'image', 'slack_file' => { 'id' => file_id }, 'alt_text' => name[0, 2000] }
            current_text = +''
          else
            path = attachment ? "/attachments/#{attachment.id}" : "/issues/#{issue.id}"
            if markdown_block
              label = name.gsub(/[\\\[\]]/) { |character| "\\#{character}" }
              image_label = Formatter.interpolate(Formatter.message('images', 'link_label'), { name: label },
                                                  fallback: Formatter::DEFAULT_MESSAGES.dig('images', 'link_label'))
              current_text << "[#{image_label}](#{Formatter.url(path)})"
            else
              image_label = Formatter.interpolate(Formatter.message('images', 'link_label'), { name: Formatter.text(name) },
                                                  fallback: Formatter::DEFAULT_MESSAGES.dig('images', 'link_label'))
              current_text << "<#{Formatter.url(path)}|#{image_label}>"
            end
          end
        else
          current_text << match[0]
        end
        cursor = match.end(0)
      end
      next [block] unless found_eligible

      current_text << content[cursor..]
      final_text = current_text.strip
      pieces << with_text.call(final_text) unless final_text.empty?
      pieces.empty? ? [block] : pieces
    end
    blocks.replace(ordered_blocks)
  end

  def upload_image(attachment, token)
    return if files_transfer_restricted?
    return unless attachment.filename.match?(/\.(?:png|jpe?g|gif)\z/i)

    path = attachment.diskfile
    size = File.size(path)
    return if size.zero? || size > 20 * 1024 * 1024

    ticket = slack_api('files.getUploadURLExternal', { 'filename' => attachment.filename, 'length' => size }, token, form: true)
    upload_uri = URI(ticket.fetch('upload_url'))
    raise 'Unexpected Slack upload URL' unless upload_uri.is_a?(URI::HTTPS) && upload_uri.host == 'files.slack.com'

    File.open(path, 'rb') do |file|
      request = Net::HTTP::Post.new(upload_uri.request_uri)
      request['Content-Type'] = 'application/octet-stream'
      request.body_stream = file
      request.content_length = size
      Net::HTTP.start(upload_uri.host, upload_uri.port, use_ssl: true, open_timeout: 3, read_timeout: 30) do |http|
        response = http.request(request)
        raise "Slack upload returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      end
    end

    file_id = ticket.fetch('file_id')
    slack_api('files.completeUploadExternal', { 'files' => [{ 'id' => file_id, 'title' => attachment.filename }] }, token, form: true)
    file_id
  rescue StandardError => e
    Rails.logger.warn("Slackmine: image upload failed for attachment #{attachment.id}: #{e.class}: #{e.message}")
    nil
  end

  def slack_api(method, body, token, form: false, open_timeout: 3, read_timeout: 10)
    uri = URI("https://slack.com/api/#{method}")
    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    if form
      request.set_form_data(body.transform_values { |value| value.is_a?(Array) || value.is_a?(Hash) ? value.to_json : value.to_s })
    else
      request['Content-Type'] = 'application/json; charset=utf-8'
      request.body = body.to_json
    end
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: open_timeout, read_timeout: read_timeout) do |http|
      response = http.request(request)
      result = JSON.parse(response.body)
      unless response.is_a?(Net::HTTPSuccess) && result['ok']
        raise SlackApiError.new(method, response.code, result)
      end

      result
    end
  end
end

require_relative 'slackmine/issue_patch'
require_relative 'slackmine/journal_patch'
require_relative 'slackmine/wiki_content_patch'
require_relative 'slackmine/generic_patches'
require_relative 'slackmine/work_objects'
require_relative 'slackmine/thread_files'
require_relative 'slackmine/thread_comments'
require_relative 'slackmine/thread_comment_batch'
require_relative 'slackmine/slash_commands'
require_relative 'slackmine/message_shortcuts'
require_relative 'slackmine/thread_connections'
require_relative 'slackmine/app_home'
require_relative 'slackmine/comment_threads'
require_relative 'slackmine/channel_matching'
require_relative 'slackmine/admin_overview'
require_relative 'slackmine/job_monitor'
require_relative 'slackmine/notification_safety'
require_relative 'slackmine/notification_coalescing'
require_relative 'slackmine/mail_preference'


module Slackmine
  module_function

  def install_patches
    ApplicationJob.include Slackmine::JobTracking if defined?(ApplicationJob) && !(ApplicationJob < Slackmine::JobTracking)
    if defined?(ApplicationHelper) && !(ApplicationHelper < Slackmine::LinkCardsHelper)
      ApplicationHelper.prepend Slackmine::LinkCardsHelper
    end
    if defined?(UserPreference) && !(UserPreference < Slackmine::UserPreferencePatch)
      UserPreference.include Slackmine::UserPreferencePatch
      UserPreference.safe_attributes 'slack_suppress_mail'
    end
    Mailer.prepend Slackmine::MailerPatch if defined?(Mailer) && !(Mailer < Slackmine::MailerPatch)

    Issue.include Slackmine::IssuePatch if defined?(Issue) && !(Issue < Slackmine::IssuePatch)
    Journal.include Slackmine::JournalPatch if defined?(Journal) && !(Journal < Slackmine::JournalPatch)
    WikiContent.include Slackmine::WikiContentPatch if defined?(WikiContent) && !(WikiContent < Slackmine::WikiContentPatch)
    WikiPage.include Slackmine::WikiPagePatch if defined?(WikiPage) && !(WikiPage < Slackmine::WikiPagePatch)
    News.include Slackmine::NewsPatch if defined?(News) && !(News < Slackmine::NewsPatch)
    TimeEntry.include Slackmine::TimeEntryPatch if defined?(TimeEntry) && !(TimeEntry < Slackmine::TimeEntryPatch)
    Version.include Slackmine::VersionPatch if defined?(Version) && !(Version < Slackmine::VersionPatch)
    Project.include Slackmine::ProjectPatch if defined?(Project) && !(Project < Slackmine::ProjectPatch)
    Document.include Slackmine::DocumentPatch if defined?(Document) && !(Document < Slackmine::DocumentPatch)
    Attachment.include Slackmine::AttachmentPatch if defined?(Attachment) && !(Attachment < Slackmine::AttachmentPatch)
    Message.include Slackmine::MessagePatch if defined?(Message) && !(Message < Slackmine::MessagePatch)
    Comment.include Slackmine::CommentPatch if defined?(Comment) && !(Comment < Slackmine::CommentPatch)
  end
end

Rails.application.config.to_prepare { Slackmine.install_patches }
Rails.application.config.after_initialize { Slackmine.install_patches }

require_relative 'slackmine/link_cards'
require_relative 'slackmine/link_cards_helper'
require_relative 'slackmine/link_quotes'
