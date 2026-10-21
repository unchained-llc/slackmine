# frozen_string_literal: true

require 'securerandom'
require 'base64'
require 'timeout'

module Slackmine
  # Slack is the durable connection store. A signed block_id on our Bot's
  # connection/closure messages binds the state to this exact app/team/thread.
  # No plugin table, DB migration, or preview cache is required.
  module ThreadConnections
    module_function

    CALLBACK = 'slackmine_thread_connect'
    PICK_CALLBACK = 'slackmine_thread_connect_pick'
    SAVE_CALLBACK = 'slackmine_thread_connect_save'
    MARKER_PREFIX = 'slackmine_connection:'
    MAX_HISTORY = 20
    MAX_SCAN = 1000
    PREVIEW_DIRECT_SECONDS = 2
    # Keep this outside StandardError so prepare_preview's error-view rescue
    # cannot consume the deadline before pick can queue its fallback.
    class PreviewDeadline < Exception; end

    def enabled?(project = nil)
      Slackmine.effective_config(project).dig('slack', 'thread_connections') != false
    end

    def receives?(app, team)
      events = Slackmine.effective_config(nil).dig('slack', 'events') || {}
      enabled? && events['app_id'] == app && events['team_id'] == team &&
        WorkObjects.integration_for(app, team) && !Slackmine.bot_token(nil).to_s.empty?
    end

    def handles?(payload)
      (payload['type'] == 'message_action' && payload['callback_id'] == CALLBACK) ||
        (payload['type'] == 'view_submission' && [PICK_CALLBACK, SAVE_CALLBACK].include?(payload.dig('view', 'callback_id')))
    end

    def scope?(issue, app, team)
      issue && issue.project.active? && !issue.is_private? && enabled?(issue.project) &&
        WorkObjects.integration_for(app, team, project: issue.project) &&
        !Slackmine.bot_token(nil).to_s.empty? && Slackmine.bot_token(issue.project) == Slackmine.bot_token(nil)
    end

    def allowed?(issue, viewer, app, team)
      scope?(issue, app, team) && viewer && issue.visible?(viewer) && issue.notes_addable?(viewer)
    end

    def secret(app, team)
      WorkObjects.integration_for(app, team)&.fetch('signing_secret', nil).to_s
    end

    def signature(app, team, channel, ts, data)
      key = secret(app, team)
      raise 'Slack signing secret is required' if key.empty?
      OpenSSL::HMAC.hexdigest('SHA256', key, JSON.generate([app, team, channel, ts, data]))
    end

    def signed_source(app, team, source)
      encoded = Base64.strict_encode64(JSON.generate(source))
      JSON.generate('data' => encoded, 'signature' => signature(app, team, source['channel'], source['ts'], encoded))
    end

    def source_for(app, team, viewer, payload)
      return unless viewer
      metadata = payload.dig('view', 'private_metadata').to_s
      return if metadata.bytesize > 3000
      envelope = JSON.parse(metadata)
      source = JSON.parse(Base64.strict_decode64(envelope.fetch('data')))
      expected = signature(app, team, source['channel'], source['ts'], envelope['data'])
      return unless secure_equal?(expected, envelope['signature']) && source['user_id'] == viewer.id
      source
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError
      nil
    end

    def secure_equal?(left, right)
      right.is_a?(String) && left.bytesize == right.bytesize &&
        left.bytes.zip(right.bytes).reduce(0) { |n, (a, b)| n | (a ^ b) }.zero?
    end

    def message(key, project: nil, **values)
      Formatter.interpolate(Formatter.message('thread_connections', key, project: project), values,
                            fallback: Formatter::DEFAULT_MESSAGES.dig('thread_connections', key))
    end

    def section(text)
      { 'type' => 'section', 'text' => { 'type' => 'plain_text', 'text' => text[0, 3000] } }
    end

    def input(id, label, element, optional: false)
      { 'type' => 'input', 'block_id' => id, 'optional' => optional,
        'label' => { 'type' => 'plain_text', 'text' => label }, 'element' => element.merge('action_id' => id) }
    end

    def modal(blocks, project: nil, app: nil, team: nil, source: nil, callback: nil, submit: nil)
      view = { 'type' => 'modal', 'title' => { 'type' => 'plain_text', 'text' => message('title', project: project) },
               'close' => { 'type' => 'plain_text', 'text' => message('close', project: project) }, 'blocks' => blocks }
      if source
        view['private_metadata'] = signed_source(app, team, source)
        raise 'Preview metadata exceeds Slack limit' if view['private_metadata'].bytesize > 3000
      end
      view['callback_id'] = callback if callback
      view['submit'] = { 'type' => 'plain_text', 'text' => submit } if submit
      view
    end

    def state(payload, id)
      payload.dig('view', 'state', 'values', id, id) || {}
    end

    def error(text)
      { 'response_action' => 'errors', 'errors' => { 'issue' => text } }
    end

    def timestamp_now
      time = Time.now.utc
      format('%d.%06d', time.to_i, time.usec)
    end

    def interaction(app, team, payload)
      return {} unless receives?(app, team)
      viewer = WorkObjects.viewer_for(payload.dig('user', 'id'))
      if payload['type'] == 'message_action'
        open_picker(app, team, viewer, payload)
      elsif payload.dig('view', 'callback_id') == PICK_CALLBACK
        pick(app, team, viewer, payload)
      else
        save(app, team, viewer, payload)
      end
    end

    def open_picker(app, team, viewer, payload)
      return {} if payload['trigger_id'].to_s.empty?
      channel = payload.dig('channel', 'id').to_s
      ts = (payload.dig('message', 'thread_ts') || payload.dig('message', 'ts')).to_s
      valid = viewer && channel.match?(/\A[CG][A-Z0-9]+\z/) && ThreadComments.posted_at(ts)
      if valid
        source = { 'channel' => channel, 'ts' => ts, 'slack_user' => payload.dig('user', 'id'),
                   'user_id' => viewer.id, 'nonce' => SecureRandom.hex(16) }
        loading = modal([section(message('loading_picker'))])
        result = Slackmine.slack_api('views.open', { 'trigger_id' => payload['trigger_id'], 'view' => loading }, Slackmine.bot_token(nil))
        begin
          job = SlackmineThreadConnectionJob.perform_later(app, team, source, result.dig('view', 'id'), 'picker')
          preview_error(result.dig('view', 'id'), StandardError.new('Enqueue failed')) unless job
        rescue StandardError => e
          preview_error(result.dig('view', 'id'), e)
        end
      else
        Slackmine.slack_api('views.open', { 'trigger_id' => payload['trigger_id'], 'view' => modal([section(message('unsupported_source'))]) }, Slackmine.bot_token(nil))
      end
      {}
    end

    def verify_channel!(channel, user, token)
      info = Slackmine.slack_api('conversations.info', { 'channel' => channel }, token, form: true)['channel']
      raise 'Bot is not a channel member' unless info.is_a?(Hash) && info['id'] == channel && info['is_member'] == true && !info['is_im'] && !info['is_mpim']
      cursor = nil
      20.times do
        body = { 'channel' => channel, 'limit' => 200 }
        body['cursor'] = cursor if cursor
        response = Slackmine.slack_api('conversations.members', body, token, form: true)
        return info if Array(response['members']).include?(user)
        cursor = response.dig('response_metadata', 'next_cursor').to_s
        break if cursor.empty?
      end
      raise 'Initiator is not a verified channel member'
    end

    def history(source, token = Slackmine.bot_token(nil))
      messages = []
      cursor = nil
      10.times do
        body = { 'channel' => source['channel'], 'ts' => source['ts'], 'limit' => 100 }
        body['cursor'] = cursor if cursor
        response = Slackmine.slack_api('conversations.replies', body, token, form: true)
        messages.concat(Array(response['messages']))
        raise 'Thread exceeds 1000 messages' if messages.size > MAX_SCAN
        cursor = response.dig('response_metadata', 'next_cursor').to_s
        if cursor.empty?
          raise 'Incomplete Slack thread history' if response['has_more']
          return messages.select { |m| m.is_a?(Hash) && ThreadComments.posted_at(m['ts']) }
                         .uniq { |m| m['ts'] }.sort_by { |m| ThreadComments.posted_at(m['ts']) }
        end
      end
      raise 'Incomplete Slack thread history'
    end

    def marker(app, team, source, message)
      return unless message['bot_id'] && (message['app_id'] || message.dig('bot_profile', 'app_id')) == app
      block = Array(message['blocks']).find { |b| b.is_a?(Hash) && b['block_id'].to_s.start_with?(MARKER_PREFIX) }
      return unless block
      encoded, digest = block['block_id'].delete_prefix(MARKER_PREFIX).split(':', 2)
      return unless encoded && secure_equal?(signature(app, team, source['channel'], source['ts'], encoded), digest)
      data = JSON.parse(Base64.strict_decode64(encoded))
      return unless data.is_a?(Array) && data.size == 4 && data[0].is_a?(Integer) && data[0] > 0 &&
                    ThreadComments.posted_at(data[1]) && data[2].to_s.match?(/\A[0-9a-f]{32}\z/) && [true, false].include?(data[3])
      { 'issue_id' => data[0], 'cutoff' => data[1], 'nonce' => data[2], 'active' => data[3], 'marker_ts' => message['ts'] }
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end

    def connection(app, team, source, messages)
      current = nil
      messages.each do |message|
        item = marker(app, team, source, message)
        next unless item
        # First connection wins until a closure for that exact nonce. A late
        # retry or stale closure cannot replace/disconnect a later connection.
        if item['active']
          current = item unless current && current['active']
        elsif current && current['active'] && current['nonce'] == item['nonce']
          current = item
        end
      end
      current
    end

    def human_message?(message)
      message.is_a?(Hash) && !message['bot_id'] && !message['app_id'] &&
        [nil, '', 'thread_broadcast', 'file_share'].include?(message['subtype']) &&
        message['user'].to_s.match?(/\A[UW][A-Z0-9]+\z/) &&
        (!MessageShortcuts.message_text(message).strip.empty? || Array(message['files']).any?)
    end

    def snapshot(message)
      { 'type' => 'message', 'ts' => message['ts'], 'user' => message['user'],
        'text' => MessageShortcuts.message_text(message),
        'files' => Array(message['files']).map { |f| f.is_a?(Hash) ? f.slice('id') : {} } }
    end

    def fingerprint(message)
      # Shorten only the identity digest, never the quoted body.
      Digest::SHA256.hexdigest(JSON.generate(snapshot(message)))[0, 32]
    end

    def prepare_picker(app, team, source, view_id)
      viewer = WorkObjects.viewer_for(source['slack_user'])
      raise 'Unknown user' unless viewer && viewer.id == source['user_id'] && enabled?
      verify_channel!(source['channel'], source['slack_user'], Slackmine.bot_token(nil))
      current = connection(app, team, source, history(source))
      if current && current['active']
        issue = Issue.find_by(id: current['issue_id'])
        raise 'Permission denied' unless allowed?(issue, viewer, app, team)
        source = source.merge(current).merge('disconnect' => true)
        view = modal([section(message('current_connection', project: issue.project, id: issue.id)),
          input('issue', message('destination', project: issue&.project), { 'type' => 'plain_text_input', 'initial_value' => issue.id.to_s })],
          project: issue&.project, app: app, team: team, source: source, callback: SAVE_CALLBACK, submit: message('disconnect', project: issue&.project))
      else
        option = { 'text' => { 'type' => 'plain_text', 'text' => message('save_history', project: issue&.project) }, 'value' => 'history' }
        view = modal([section(message('picker_hint', project: issue&.project)),
          input('issue', message('issue_number', project: issue&.project), { 'type' => 'plain_text_input' }),
          input('history', message('history', project: issue&.project), { 'type' => 'checkboxes', 'options' => [option], 'initial_options' => [option] }, optional: true)],
          project: issue&.project, app: app, team: team, source: source, callback: PICK_CALLBACK, submit: message('review', project: issue&.project))
      end
      update_view(view_id, view)
    rescue StandardError => e
      preview_error(view_id, e, project: issue&.project)
    end

    def issue_reference_id(value)
      value = value.to_s.strip.sub(/\A#/, '')
      return value if value.match?(/\A[1-9]\d*\z/)

      url = value.sub(/[?#].*\z/, '')
      match = url.match(%r{/issues/([1-9]\d*)\z})
      match[1] if match && url == Formatter.url("/issues/#{match[1]}")
    end

    def pick(app, team, viewer, payload)
      source = source_for(app, team, viewer, payload)
      return error(message('invalid_review')) unless source
      id = issue_reference_id(state(payload, 'issue')['value'])
      issue = Issue.find_by(id: id) if id
      return error(message('issue_denied', project: issue&.project)) unless allowed?(issue, viewer, app, team)
      source = source.merge('issue_id' => issue.id, 'history' => Array(state(payload, 'history')['selected_options']).any? { |o| o['value'] == 'history' }, 'cutoff' => timestamp_now)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        view = Timeout.timeout(PREVIEW_DIRECT_SECONDS, PreviewDeadline) { prepare_preview(app, team, source) }
        Rails.logger&.info("Slackmine: connection preview direct duration_ms=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round}")
        return { 'response_action' => 'update', 'view' => view }
      rescue PreviewDeadline
        Rails.logger&.info("Slackmine: connection preview deferred after #{PREVIEW_DIRECT_SECONDS}s")
      end
      # A slow read falls back to the worker. Install the loading view before
      # its views.update runs, so the acknowledgement cannot overwrite it.
      job = SlackmineThreadConnectionJob.set(wait: 1).perform_later(app, team, source, payload.dig('view', 'id'), 'preview')
      return error(message('submission_failed', project: issue.project)) unless job
      { 'response_action' => 'update', 'view' => modal([section(message('loading_preview', project: issue.project))], project: issue.project) }
    rescue StandardError => e
      Rails.logger&.error("Slackmine: connection preview enqueue failed: #{e.class}")
      error(message('submission_failed', project: issue&.project))
    end

    def prepare_preview(app, team, source, view_id = nil)
      issue = Issue.find_by(id: source['issue_id'])
      viewer = WorkObjects.viewer_for(source['slack_user'])
      raise 'Permission denied' unless viewer && viewer.id == source['user_id'] && allowed?(issue, viewer, app, team)
      channel_info = verify_channel!(source['channel'], source['slack_user'], Slackmine.bot_token(nil))
      messages = source['history'] ? history(source) : []
      mention_cache = {}
      messages.select! do |m|
        human_message?(m) && ThreadComments.posted_at(m['ts']) <= ThreadComments.posted_at(source['cutoff']) &&
          !ThreadComments.addressed_to_bot?(m, issue.project, cache: mention_cache)
      end
      raise 'Past conversation exceeds 20 human posts' if messages.size > MAX_HISTORY
      cache = {}
      call = lambda { |method, body| cache[[method, body]] ||= Slackmine.slack_api(method, body, Slackmine.bot_token(nil), form: true) }
      blocks = [section(message('preview_hint', project: issue.project, id: issue.id, subject: issue.subject)),
                input('issue', message('destination_number', project: issue&.project), { 'type' => 'plain_text_input', 'initial_value' => issue.id.to_s })]
      source = source.merge('posts' => messages.map { |m| [m['ts'], fingerprint(m)] }, 'ready' => true)
      messages.each_with_index do |m, index|
        card = LinkCards.message_card(m, call)
        text = MessageShortcuts.message_text(m)
        raise 'A post exceeds 10000 characters' if text.length > 10_000
        preview = message('post_preview', project: issue.project, author: card['author'], timestamp: card['timestamp'], text: text, count: Array(m['files']).size)
        preview.scan(/.{1,2900}/m).each { |part| blocks << section(part) }
        option = { 'text' => { 'type' => 'plain_text', 'text' => message('save_post', project: issue&.project) }, 'value' => index.to_s }
        blocks << input("post_#{index}", message('import', project: issue&.project), { 'type' => 'checkboxes', 'options' => [option], 'initial_options' => [option] }, optional: true)
      end
      raise 'Preview exceeds Slack block limit' if blocks.size > 100
      view = modal(blocks, project: issue.project, app: app, team: team, source: source, callback: SAVE_CALLBACK, submit: message('connect', project: issue&.project))
      view_id ? update_view(view_id, view) : view
    rescue StandardError => e
      preview_error(view_id, e, project: issue&.project)
    end

    def update_view(view_id, view)
      Slackmine.slack_api('views.update', { 'view_id' => view_id, 'view' => view }, Slackmine.bot_token(nil))
    end

    def preview_error(view_id, error, project: nil)
      reason = error.message == 'Past conversation exceeds 20 human posts' ? 'history_limit' : error.class.to_s
      Rails.logger&.warn("Slackmine: connection preview failed: #{reason}")
      view = modal([section(message('preview_failed', project: project))], project: project)
      view_id ? update_view(view_id, view) : view
    end

    def save(app, team, viewer, payload)
      source = source_for(app, team, viewer, payload)
      return error(message('invalid_review')) unless source
      issue = Issue.find_by(id: source['issue_id'])
      return error(message('denied', project: issue&.project)) unless allowed?(issue, viewer, app, team)
      entered_id = issue_reference_id(state(payload, 'issue')['value'])
      return error(message('destination_changed', project: issue&.project)) unless entered_id == issue.id.to_s
      return error(message('review_incomplete', project: issue&.project)) unless source['disconnect'] || source['ready']
      selected = Array(source['posts']).each_with_index.select do |_, index|
        Array(state(payload, "post_#{index}")['selected_options']).any? { |o| o['value'] == index.to_s }
      end.map(&:first)
      # Claim the signed confirmation before Slack writes or history imports.
      # Keep an uncertain outcome claimed, so a redelivery cannot repeat it.
      key = submission_key(app, team, viewer.id, source)
      cache = Rails.cache
      return {} if cache.read(key) == 'done'
      return error(message('submission_pending', project: issue&.project)) unless cache.write(key, 'pending', unless_exist: true, expires_in: 86_400)
      job = SlackmineThreadConnectionJob.perform_later(app, team, source.merge('posts' => selected), nil, 'save')
      unless job
        cache.delete(key)
        return error(message('submission_failed', project: issue&.project))
      end
      {}
    rescue StandardError => e
      Rails.logger&.error("Slackmine: connection submission failed: #{e.class}")
      error(message('submission_failed', project: issue&.project))
    end

    def submission_key(app, team, user_id, source)
      "slackmine:thread_connection:#{Digest::SHA256.hexdigest([app, team, user_id, source['nonce'], source['disconnect'] == true].join(':'))}"
    end

    def complete_submission(app, team, source)
      key = submission_key(app, team, source['user_id'], source)
      return if Rails.cache.read(key) == 'done'
      finish(app, team, source)
      Rails.cache.write(key, 'done', expires_in: 86_400)
    end

    def post_marker(app, team, source, active:)
      issue = Issue.find_by(id: source['issue_id'])
      raise 'Invalid integration' unless scope?(issue, app, team)
      encoded = Base64.strict_encode64(JSON.generate([issue.id, source['cutoff'], source['nonce'], active]))
      block_id = MARKER_PREFIX + encoded + ':' + signature(app, team, source['channel'], source['ts'], encoded)
      raise 'Marker exceeds Slack limit' if block_id.length > 255
      text = "<#{Formatter.url("/issues/#{issue.id}")}|##{issue.id}> " +
             (active ? message('connected', project: issue&.project) : message('disconnected', project: issue&.project))
      Slackmine.slack_api('chat.postMessage', { 'channel' => source['channel'], 'thread_ts' => source['ts'], 'text' => text,
        'blocks' => [{ 'type' => 'section', 'block_id' => block_id, 'text' => { 'type' => 'mrkdwn', 'text' => text } }],
        'unfurl_links' => false, 'unfurl_media' => false }, Slackmine.bot_token(nil))
    end

    def finish(app, team, source)
      issue = Issue.find_by(id: source['issue_id'])
      viewer = WorkObjects.viewer_for(source['slack_user'])
      raise 'Permission denied' unless viewer && viewer.id == source['user_id'] && allowed?(issue, viewer, app, team)
      channel_info = verify_channel!(source['channel'], source['slack_user'], Slackmine.bot_token(nil))
      messages = history(source)
      current = connection(app, team, source, messages)
      if source['disconnect']
        return unless current && current['active'] && current['nonce'] == source['nonce']
        post_marker(app, team, source, active: false)
        return
      end
      # A cancelled/closed request is never resurrected by a delayed retry,
      # including after a different connection has also been closed.
      closed = messages.any? do |m|
        item = marker(app, team, source, m)
        item && !item['active'] && item['nonce'] == source['nonce']
      end
      return if closed
      if current && current['active'] && current['nonce'] != source['nonce']
        return failure_notice(source, message('already_connected', project: issue&.project))
      end
      selected = Array(source['posts']).map do |ts, digest|
        message = messages.find { |m| m['ts'] == ts }
        raise 'The selected conversation changed; preview again' unless message && human_message?(message) && fingerprint(message) == digest
        message
      end
      raise 'Selected text exceeds 10000 characters' if selected.map { |m| MessageShortcuts.message_text(m) }.join("\n\n").length > 10_000
      unless current && current['active']
        posted = post_marker(app, team, source, active: true)
        messages = history(source)
        current = connection(app, team, source, messages)
        unless current && current['active'] && current['nonce'] == source['nonce']
          # Only remove the losing confirmation created by this request.
          Slackmine.slack_api('chat.delete', { 'channel' => source['channel'], 'ts' => posted['ts'] }, Slackmine.bot_token(nil)) if ThreadComments.posted_at(posted['ts'])
          return failure_notice(source, message('connection_conflict', project: issue&.project))
        end
      end
      cache = {}
      call = lambda { |method, body| cache[[method, body]] ||= Slackmine.slack_api(method, body, Slackmine.bot_token(nil), form: true) }
      entries = selected.map do |m|
        card = LinkCards.message_card(m, call).merge('channel' => channel_info['name'] || source['channel'],
          'text' => MessageShortcuts.message_text(m), 'thread_connection_nonce' => source['nonce'])
        card['text'] = message('attachment_only', project: issue&.project) if card['text'].empty?
        { 'event' => snapshot(m).merge('channel' => source['channel'], 'thread_ts' => source['ts']), 'card' => card }
      end
      Slackmine.with_project(issue.project) do
        if entries.any?
          result = ThreadComments.persist_reply(issue, entries.first['event'], team, events: entries.map { |e| e['event'] },
            connected: true, import_viewer: viewer, history_cards: entries, import_timestamp: ThreadComments.posted_at(source['cutoff']))
          raise "History import failed: #{result}" unless [:saved, :duplicate].include?(result)
        end
        # Events accepted while the modal was open can precede the connection
        # marker. Replay those replies; existing Journal identity deduplicates them.
        messages.each do |m|
          next unless human_message?(m) && ThreadComments.posted_at(m['ts']) > ThreadComments.posted_at(source['cutoff'])
          process_reply(current, app, team, snapshot(m).merge('channel' => source['channel'], 'thread_ts' => source['ts']))
        end
      end
    rescue StandardError => e
      Rails.logger&.error("Slackmine: connection operation failed: #{e.class}")
      failure_notice(source, message('operation_failed', project: issue&.project))
      raise
    end

    def process_reply(current, app, team, event)
      return :ignored unless current['active'] && enabled?
      return :ignored unless ThreadComments.posted_at(event['ts']) > ThreadComments.posted_at(current['cutoff'])
      issue = Issue.find_by(id: current['issue_id'])
      return :ignored unless scope?(issue, app, team)
      Slackmine.with_project(issue.project) do
        return :ignored if ThreadComments.addressed_to_bot?(event, issue.project)
        result = ThreadComments.persist_reply(issue, event, team, connected: true)
        ThreadComments.feedback(issue, event, result) unless result == :duplicate
        result
      end
    end

    def failure_notice(source, text)
      Slackmine.slack_api('chat.postEphemeral', { 'channel' => source['channel'], 'user' => source['slack_user'], 'text' => text }, Slackmine.bot_token(nil))
    rescue StandardError => e
      Rails.logger&.warn("Slackmine: connection feedback failed: #{e.class}")
    end
  end
end
