# frozen_string_literal: true

require 'securerandom'
require 'base64'
require 'timeout'

module Slackmine
  # Connection state is shared with thread import deduplication in Redis.
  module ThreadConnections
    module_function

    CALLBACK = 'slackmine_thread_connect'
    PICK_CALLBACK = 'slackmine_thread_connect_pick'
    SELECT_CALLBACK = 'slackmine_thread_connect_select'
    SEARCH_CALLBACK = 'slackmine_thread_connect_search'
    SAVE_CALLBACK = 'slackmine_thread_connect_save'
    MAX_HISTORY = 20
    MAX_SCAN = 1000
    MAX_HISTORY_TEXT = 100_000
    MAX_RECENT = 25
    SELECTION_GROUP_SIZE = 100 # Compatibility with already-open grouped selection dialogs.
    SELECTION_PAGE_SIZE = 40
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
        (payload['type'] == 'block_suggestion' && payload['action_id'] == 'search_issue' && payload.dig('view', 'callback_id') == SEARCH_CALLBACK) ||
        selection_action?(payload) ||
        (payload['type'] == 'view_submission' && [PICK_CALLBACK, SELECT_CALLBACK, SEARCH_CALLBACK, SAVE_CALLBACK].include?(payload.dig('view', 'callback_id')))
    end

    def selection_action?(payload)
      payload['type'] == 'block_actions' && payload.dig('view', 'callback_id') == SAVE_CALLBACK &&
        Array(payload['actions']).any? { |action| action.is_a?(Hash) && action['action_id'].to_s.match?(/\A(?:post|history_group|history_page)_\d+\z/) }
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
      elsif selection_action?(payload)
        if Array(payload['actions']).any? { |action| action['action_id'].to_s.start_with?('history_page_') }
          change_history_page(app, team, viewer, payload)
        else
          {}
        end
      elsif payload['type'] == 'block_suggestion'
        suggestions(app, team, viewer, payload)
      elsif [PICK_CALLBACK, SELECT_CALLBACK, SEARCH_CALLBACK].include?(payload.dig('view', 'callback_id'))
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
      raise 'Thread exceeds 1000 messages'
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
      current = ThreadState.connection(app, team, source)
      if current && current['active']
        issue = Issue.find_by(id: current['issue_id'])
        raise 'Permission denied' unless allowed?(issue, viewer, app, team)
        source = source.merge(current).merge('disconnect' => true)
        view = modal([section(message('current_connection', project: issue.project, id: issue.id)),
          input('issue', message('destination', project: issue&.project), { 'type' => 'plain_text_input', 'initial_value' => issue.id.to_s })],
          project: issue&.project, app: app, team: team, source: source, callback: SAVE_CALLBACK, submit: message('disconnect', project: issue&.project))
      else
        history(source)
        blocks = [section(message('unified_picker_hint'))]
        blocks << input('search_issue', message('issue_search'), { 'type' => 'external_select', 'min_query_length' => 0,
          'placeholder' => { 'type' => 'plain_text', 'text' => message('search_placeholder') } })
        view = modal(blocks,
          project: issue&.project, app: app, team: team, source: source, callback: SEARCH_CALLBACK, submit: message('review', project: issue&.project))
      end
      update_view(view_id, view)
    rescue StandardError => e
      preview_error(view_id, e, project: issue&.project)
    end

    def issue_options(rows)
      rows.map do |candidate|
        { 'text' => { 'type' => 'plain_text', 'text' => "##{candidate.id} #{candidate.subject}"[0, 75] }, 'value' => candidate.id.to_s }
      end
    end

    def suggestions(app, team, viewer, payload)
      return { 'options' => [] } unless source_for(app, team, viewer, payload)
      query = payload['value'].to_s.strip
      return { 'options' => [] } if query.length > 500
      if query.empty?
        rows = Issue.visible(viewer).order(updated_on: :desc).limit(100).to_a
      elsif (id = issue_reference_id(query))
        rows = [Issue.find_by(id: id)].compact
      else
        rows = Issue.visible(viewer).where('LOWER(issues.subject) LIKE ?', "%#{Issue.sanitize_sql_like(query.downcase)}%")
                    .order(updated_on: :desc).limit(100).to_a
      end
      { 'options' => issue_options(rows.select { |candidate| allowed?(candidate, viewer, app, team) }.first(MAX_RECENT)) }
    rescue StandardError => e
      Rails.logger&.error("Slackmine: connection suggestions failed: #{e.class}")
      { 'options' => [] }
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
      selecting = payload.dig('view', 'callback_id') == SELECT_CALLBACK
      searching = payload.dig('view', 'callback_id') == SEARCH_CALLBACK
      value = state(payload, 'issue')['value'].to_s.strip
      id = if searching
             state(payload, 'search_issue').dig('selected_option', 'value')
           elsif selecting
             state(payload, 'choice').dig('selected_option', 'value')
           elsif value.empty?
             state(payload, 'recent').dig('selected_option', 'value')
           else
             issue_reference_id(value)
           end
      if !selecting && !searching && !id && !value.empty?
        rows = Issue.visible(viewer).where('LOWER(issues.subject) LIKE ?', "%#{Issue.sanitize_sql_like(value.downcase)}%")
                    .order(updated_on: :desc).limit(100).to_a.select { |candidate| allowed?(candidate, viewer, app, team) }.first(100)
        return error(message('issue_denied')) if rows.empty?
        options = issue_options(rows)
        source = source.merge('history' => Array(state(payload, 'history')['selected_options']).any? { |o| o['value'] == 'history' })
        view = modal([section(message('choose_search_result')),
          input('choice', message('search_result'), { 'type' => 'static_select', 'options' => options })],
          app: app, team: team, source: source, callback: SELECT_CALLBACK, submit: message('review'))
        return { 'response_action' => 'update', 'view' => view }
      end
      id = nil unless id.to_s.match?(/\A[1-9]\d*\z/)
      issue = Issue.find_by(id: id) if id
      unless allowed?(issue, viewer, app, team)
        field = searching ? 'search_issue' : (selecting ? 'choice' : 'issue')
        return { 'response_action' => 'errors', 'errors' => { field => message('issue_denied', project: issue&.project) } }
      end
      has_history_control = payload.dig('view', 'blocks').to_a.any? { |block| block['block_id'] == 'history' }
      history_selected = if selecting
                           source['history']
                         elsif searching && !has_history_control
                           true
                         else
                           Array(state(payload, 'history')['selected_options']).any? { |o| o['value'] == 'history' }
                         end
      individual = searching && history_selected && (!has_history_control || Array(state(payload, 'history_mode')['selected_options']).any? { |o| o['value'] == 'individual' })
      source = source.merge('issue_id' => issue.id, 'history' => history_selected, 'cutoff' => timestamp_now,
                            'bulk_history' => searching, 'individual_history' => individual,
                            'recent_selected' => searching || (!selecting && value.empty?))
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
      if source['bulk_history']
        raise 'History text exceeds limit' if history_text_length(messages) > MAX_HISTORY_TEXT
        raise 'History post exceeds limit' if messages.any? { |m| MessageShortcuts.message_text(m).length > 10_000 }
        if !Slackmine.files_transfer_restricted?(issue.project) && messages.flat_map { |m| Array(m['files']).map { |f| f['id'] } }.compact.uniq.size > ThreadFiles::MAX_FILES
          raise 'History files exceed limit'
        end
        digest = history_digest(messages)
        raise 'The conversation changed; preview again' if source['history_digest'] && source['history_digest'] != digest
        source = source.merge('history_digest' => digest, 'history_count' => messages.size, 'ready' => true, 'fixed_destination' => true)
        key = source['individual_history'] ? 'individual_preview' : (source['history'] ? 'bulk_preview_history' : 'bulk_preview_future')
        blocks = [section(message(key, project: issue.project, id: issue.id, subject: issue.subject, count: messages.size))]
        if source['individual_history']
          source = source.merge('selection_layout' => 'paged_checkboxes', 'selection_page' => source.fetch('selection_page', 0))
          bits = selection_bytes(source)
          source = source.merge('selection_bits' => Base64.strict_encode64(bits.pack('C*')))
          page = source['selection_page']
          pages = [(messages.size.to_f / SELECTION_PAGE_SIZE).ceil, 1].max
          raise 'Invalid selection page' unless page.is_a?(Integer) && page.between?(0, pages - 1)
          offset = page * SELECTION_PAGE_SIZE
          if pages > 1
            blocks << section(message('history_page', project: issue.project, page: page + 1, pages: pages,
              first: offset + 1, last: [offset + SELECTION_PAGE_SIZE, messages.size].min, count: messages.size))
          end
          cache = {}
          call = lambda { |method, body| cache[[method, body]] ||= Slackmine.slack_api(method, body, Slackmine.bot_token(nil), form: true) }
          messages.slice(offset, SELECTION_PAGE_SIZE).to_a.each_with_index do |item, local_index|
            index = offset + local_index
            card = LinkCards.message_card(item, call)
            text = MessageShortcuts.message_text(item)
            # A separate section keeps the body readable, rather than squeezing it
            # into Slack's 75-character option labels.
            shown = text.length > 2500 ? text[0, 2500] + '…' : text
            preview = message('post_preview', project: issue.project, author: card['author'], timestamp: card['timestamp'], text: shown, count: Array(item['files']).size)
            blocks << section(preview)
            option = { 'text' => { 'type' => 'plain_text', 'text' => message('save_post', project: issue.project) }, 'value' => index.to_s }
            element = { 'type' => 'checkboxes', 'action_id' => "post_#{index}", 'options' => [option] }
            element['initial_options'] = [option] if (bits[index / 8] & (1 << (index % 8))) != 0
            blocks << { 'type' => 'actions', 'block_id' => "post_#{index}", 'elements' => [element] }
          end
          if pages > 1
            buttons = []
            [[page - 1, 'previous_page'], [page + 1, 'next_page']].each do |target, key|
              next unless target.between?(0, pages - 1)
              buttons << { 'type' => 'button', 'action_id' => "history_page_#{target}",
                'text' => { 'type' => 'plain_text', 'text' => message(key, project: issue.project) } }
            end
            blocks << { 'type' => 'actions', 'block_id' => 'history_navigation', 'elements' => buttons }
          end
        end
        view = modal(blocks,
          project: issue.project, app: app, team: team, source: source, callback: SAVE_CALLBACK, submit: message('connect', project: issue.project))
        return view_id ? update_view(view_id, view) : view
      end
      history_over_limit = messages.size > MAX_HISTORY
      raise 'Past conversation exceeds 20 human posts' if history_over_limit
      cache = {}
      call = lambda { |method, body| cache[[method, body]] ||= Slackmine.slack_api(method, body, Slackmine.bot_token(nil), form: true) }
      blocks = [section(message('preview_hint', project: issue.project, id: issue.id, subject: issue.subject))]
      source = source.merge('posts' => messages.map { |m| [m['ts'], fingerprint(m)] }, 'ready' => true, 'fixed_destination' => true)
      messages.each_with_index do |m, index|
        card = LinkCards.message_card(m, call)
        text = MessageShortcuts.message_text(m)
        raise 'A post exceeds 10000 characters' if text.length > 10_000
        preview = message('post_preview', project: issue.project, author: card['author'], timestamp: card['timestamp'], text: text, count: Array(m['files']).size)
        preview.scan(/.{1,2900}/m).each { |part| blocks << section(part) }
        option = { 'text' => { 'type' => 'plain_text', 'text' => message('save_post', project: issue&.project) }, 'value' => index.to_s }
        blocks << { 'type' => 'actions', 'block_id' => "post_#{index}", 'elements' => [
          { 'type' => 'checkboxes', 'action_id' => "post_#{index}", 'options' => [option], 'initial_options' => [option] }] }
      end
      raise 'Preview exceeds Slack block limit' if blocks.size > 100
      view = modal(blocks, project: issue.project, app: app, team: team, source: source, callback: SAVE_CALLBACK, submit: message('connect', project: issue&.project))
      view_id ? update_view(view_id, view) : view
    rescue StandardError => e
      preview_error(view_id, e, project: issue&.project)
    end

    # The signed metadata carries one bit per post, so 1,000 selections fit
    # comfortably within Slack's private_metadata limit across page changes.
    def selection_bytes(source)
      count = source.fetch('history_count')
      raise 'Invalid selection count' unless count.is_a?(Integer) && count.between?(0, MAX_SCAN)
      return Array.new((count + 7) / 8, 255) unless source.key?('selection_bits')
      bits = Base64.strict_decode64(source['selection_bits']).bytes
      raise 'Invalid selection' unless bits.size == (count + 7) / 8
      bits
    end

    def page_selection(source, payload)
      bits = selection_bytes(source)
      page = source.fetch('selection_page')
      count = source.fetch('history_count')
      pages = [(count.to_f / SELECTION_PAGE_SIZE).ceil, 1].max
      raise 'Invalid selection page' unless page.is_a?(Integer) && page.between?(0, pages - 1)
      first = page * SELECTION_PAGE_SIZE
      (first...[first + SELECTION_PAGE_SIZE, count].min).each do |index|
        options = state(payload, "post_#{index}")['selected_options']
        # Missing state is not the same as an explicitly unchecked checkbox.
        raise 'Incomplete selection state' unless options.is_a?(Array)
        raise 'Invalid selection' unless options.empty? || (options.size == 1 && options.first['value'] == index.to_s)
        bits[index / 8] &= ~(1 << (index % 8))
        bits[index / 8] |= (1 << (index % 8)) unless options.empty?
      end
      Base64.strict_encode64(bits.pack('C*'))
    end

    def change_history_page(app, team, viewer, payload)
      source = source_for(app, team, viewer, payload)
      return {} unless source && source['selection_layout'] == 'paged_checkboxes'
      issue = Issue.find_by(id: source['issue_id'])
      return {} unless allowed?(issue, viewer, app, team)
      action = Array(payload['actions']).find { |item| item['action_id'].to_s.match?(/\Ahistory_page_\d+\z/) }
      return {} unless action
      target = action['action_id'].delete_prefix('history_page_').to_i
      pages = [(source['history_count'].to_f / SELECTION_PAGE_SIZE).ceil, 1].max
      return {} unless target.between?(0, pages - 1) && (target - source['selection_page']).abs == 1
      source = source.merge('selection_bits' => page_selection(source, payload), 'selection_page' => target)
      # Replace the controls while loading so a later selection cannot be lost
      # to an outstanding page request. Slack's hash rejects duplicate clicks.
      loading = modal([section(message('loading_preview', project: issue.project))], project: issue.project)
      update_view(payload.dig('view', 'id'), loading, hash: payload.dig('view', 'hash'))
      loading_installed = true
      job = SlackmineThreadConnectionJob.perform_later(app, team, source, payload.dig('view', 'id'), 'preview')
      preview_error(payload.dig('view', 'id'), StandardError.new('Enqueue failed'), project: issue.project) unless job
      {}
    rescue StandardError => e
      Rails.logger&.warn("Slackmine: history page failed: #{e.class}")
      preview_error(payload.dig('view', 'id'), e, project: issue&.project) if loading_installed
      {}
    end

    def history_text_length(messages)
      messages.map { |m| MessageShortcuts.message_text(m) }.join("\n\n").length
    end

    def history_digest(messages)
      Digest::SHA256.hexdigest(JSON.generate(messages.map { |m| [m['ts'], fingerprint(m)] }))
    end

    def update_view(view_id, view, hash: nil)
      body = { 'view_id' => view_id, 'view' => view }
      body['hash'] = hash if hash
      Slackmine.slack_api('views.update', body, Slackmine.bot_token(nil))
    end

    def preview_error(view_id, error, project: nil)
      reason = error.message == 'Past conversation exceeds 20 human posts' ? 'history_limit' : error.class.to_s
      Rails.logger&.warn("Slackmine: connection preview failed: #{reason}")
      key = case error.message
            when 'Past conversation exceeds 20 human posts' then 'individual_history_limit'
            when 'History text exceeds limit' then 'bulk_history_text_limit'
            when 'History post exceeds limit' then 'bulk_history_post_limit'
            when 'History files exceed limit' then 'bulk_history_files_limit'
            when 'Thread exceeds 1000 messages', 'Thread exceeds connection capacity' then 'bulk_thread_limit'
            else 'preview_failed'
            end
      view = modal([section(message(key, project: project))], project: project)
      view_id ? update_view(view_id, view) : view
    end

    def save(app, team, viewer, payload)
      source = source_for(app, team, viewer, payload)
      return error(message('invalid_review')) unless source
      issue = Issue.find_by(id: source['issue_id'])
      return save_error(source, message('denied', project: issue&.project), issue&.project) unless allowed?(issue, viewer, app, team)
      unless source['fixed_destination']
        destination_id = source['recent_selected'] ? 'destination' : 'issue'
        entered_id = issue_reference_id(state(payload, destination_id)['value'])
        return { 'response_action' => 'errors', 'errors' => { destination_id => message('destination_changed', project: issue&.project) } } unless entered_id == issue.id.to_s
      end
      return save_error(source, message('review_incomplete', project: issue&.project), issue&.project) unless source['disconnect'] || source['ready']
      selected = Array(source['posts']).each_with_index.select do |_, index|
        Array(state(payload, "post_#{index}")['selected_options']).any? { |o| o['value'] == index.to_s }
      end.map(&:first)
      if source['individual_history'] && source['selection_layout'] == 'paged_checkboxes'
        source = source.merge('selection_bits' => page_selection(source, payload))
      elsif source['individual_history']
        count = source['history_count'].to_i
        return save_error(source, message('invalid_review'), issue&.project) unless count.between?(0, MAX_SCAN)
        selected_indices = if source['selection_layout'] == 'checkboxes'
          (0...count).select { |index| Array(state(payload, "post_#{index}")['selected_options']).any? { |option| option['value'] == index.to_s } }.map(&:to_s)
        else
          (0...((count + SELECTION_GROUP_SIZE - 1) / SELECTION_GROUP_SIZE)).flat_map do |group|
          Array(state(payload, "history_group_#{group}")['selected_options']).map do |option|
            value = option['value'].to_s
            raise ArgumentError, 'Invalid selection group' unless value.match?(/\A(?:0|[1-9]\d*)\z/) && value.to_i / SELECTION_GROUP_SIZE == group
            value
          end
          end
        end
        valid = selected_indices.all? { |value| value.match?(/\A(?:0|[1-9]\d*)\z/) && value.to_i < count } && selected_indices.uniq.size == selected_indices.size
        return save_error(source, message('invalid_review'), issue&.project) unless valid
        bits = Array.new((count + 7) / 8, 0)
        selected_indices.each { |index| i = index.to_i; bits[i / 8] |= (1 << (i % 8)) }
        source = source.merge('selection_bits' => Base64.strict_encode64(bits.pack('C*')))
      end
      claim = ThreadState.claim_submission(app, team, source)
      return {} if claim == 'done'
      return save_error(source, message('submission_pending', project: issue&.project), issue&.project) unless claim == 'claimed'
      job = SlackmineThreadConnectionJob.perform_later(app, team, source.merge('posts' => selected), nil, 'save')
      unless job
        ThreadState.release_submission(app, team, source)
        return save_error(source, message('submission_failed', project: issue&.project), issue&.project)
      end
      {}
    rescue StandardError => e
      Rails.logger&.error("Slackmine: connection submission failed: #{e.class}")
      save_error(source, message('submission_failed', project: issue&.project), issue&.project)
    end

    def save_error(source, text, project = nil)
      return error(text) unless source && source['fixed_destination']
      { 'response_action' => 'update', 'view' => modal([section(text)], project: project) }
    end

    def complete_submission(app, team, source)
      finish(app, team, source)
      ThreadState.finish_submission(app, team, source)
    end

    def connection_feedback(source, active:)
      issue = Issue.find_by(id: source['issue_id'])
      text = "<#{Formatter.url("/issues/#{issue.id}")}|##{issue.id}> " +
             (active ? message('connected', project: issue&.project) : message('disconnected', project: issue&.project))
      ThreadFeedback.post(issue.project, source['channel'], source['ts'], text, 'connection')
    rescue StandardError => e
      Rails.logger&.warn("Slackmine: connection feedback failed: #{e.class}")
    end

    def finish(app, team, source)
      issue = Issue.find_by(id: source['issue_id'])
      viewer = WorkObjects.viewer_for(source['slack_user'])
      raise 'Permission denied' unless viewer && viewer.id == source['user_id'] && allowed?(issue, viewer, app, team)
      channel_info = verify_channel!(source['channel'], source['slack_user'], Slackmine.bot_token(nil))
      messages = history(source)
      current = ThreadState.connection(app, team, source)
      if source['disconnect']
        return unless current && current['active'] && current['nonce'] == source['nonce']
        connection_feedback(source, active: false) if ThreadState.disconnect(app, team, source)
        return
      end
      if current && current['active'] && current['nonce'] != source['nonce']
        return failure_notice(source, message('already_connected', project: issue&.project))
      end
      if source['bulk_history']
        mention_cache = {}
        selected = source['history'] ? messages.select { |m| human_message?(m) && ThreadComments.posted_at(m['ts']) <= ThreadComments.posted_at(source['cutoff']) && !ThreadComments.addressed_to_bot?(m, issue.project, cache: mention_cache) } : []
        raise 'The conversation changed; preview again' unless history_digest(selected) == source['history_digest'] && selected.size == source['history_count']
        if source['individual_history']
          bits = Base64.strict_decode64(source.fetch('selection_bits')).bytes
          raise 'Invalid selection' unless bits.size == (selected.size + 7) / 8
          selected = selected.each_with_index.select { |_, index| (bits[index / 8] & (1 << (index % 8))) != 0 }.map(&:first)
        end
        raise 'History text exceeds limit' if history_text_length(selected) > MAX_HISTORY_TEXT
        raise 'History post exceeds limit' if selected.any? { |m| MessageShortcuts.message_text(m).length > 10_000 }
        if !Slackmine.files_transfer_restricted?(issue.project) && selected.flat_map { |m| Array(m['files']).map { |f| f['id'] } }.compact.uniq.size > ThreadFiles::MAX_FILES
          raise 'History files exceed limit'
        end
      else
        selected = Array(source['posts']).map do |ts, digest|
          message = messages.find { |m| m['ts'] == ts }
          raise 'The selected conversation changed; preview again' unless message && human_message?(message) && fingerprint(message) == digest
          message
        end
        raise 'Selected text exceeds 10000 characters' if history_text_length(selected) > 10_000
      end
      state = ThreadState.connect(app, team, source)
      return if state == 'closed'
      return failure_notice(source, message('connection_conflict', project: issue&.project)) if state == 'conflict'
      current = ThreadState.connection(app, team, source)
      # Re-read after publishing the connection: replies that arrived between
      # the first read and the state write may have been handled before it.
      messages = history(source)
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
        # Replay replies accepted before the connection was recorded; the
        # shared Redis ledger suppresses overlap with live reply events.
        messages.each do |m|
          next unless human_message?(m) && ThreadComments.posted_at(m['ts']) > ThreadComments.posted_at(source['cutoff'])
          process_reply(current, app, team, snapshot(m).merge('channel' => source['channel'], 'thread_ts' => source['ts']))
        end
      end
      connection_feedback(source, active: true) if state == 'connected'
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
