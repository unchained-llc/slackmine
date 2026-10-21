# frozen_string_literal: true
require_relative 'message_shortcuts_test'
require_relative '../app/jobs/slackmine_thread_connection_job'

class ThreadConnectionsTest < Minitest::Test
  CONNECTIONS = Slackmine::ThreadConnections

  def setup
    @integration = { 'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'test-secret' }
    @settings = { 'slack' => { 'bot_token' => 'token', 'events' => @integration } }
    @viewer = OpenStruct.new(id: 3)
    @issue = OpenStruct.new(id: 7, subject: 'Example issue', project: OpenStruct.new(active?: true, identifier: 'example'))
    @issue.define_singleton_method(:is_private?) { false }
    @issue.define_singleton_method(:visible?) { |*| true }
    @issue.define_singleton_method(:notes_addable?) { |*| true }
    @calls = []
    @cache = SlashCommandsCacheTest::Cache.new
    @saved = []
    @queued = []
    @member = @bot_member = true
    @payload = { 'type' => 'message_action', 'callback_id' => CONNECTIONS::CALLBACK,
      'user' => { 'id' => 'U123' }, 'channel' => { 'id' => 'C123' }, 'trigger_id' => 'fresh',
      'message' => { 'ts' => '1791001000.000002', 'thread_ts' => '1791001000.000001' } }
    @source = { 'channel' => 'C123', 'ts' => '1791001000.000001', 'slack_user' => 'U123',
      'user_id' => 3, 'nonce' => 'a' * 32, 'issue_id' => 7, 'cutoff' => '1791001000.000010' }
    @messages = [
      { 'ts' => '1791001000.000001', 'user' => 'U123', 'text' => 'Parent message' },
      { 'ts' => '1791001000.000002', 'user' => 'U456', 'text' => 'Reply message' },
      { 'ts' => '1791001000.000003', 'user' => 'U123', 'bot_id' => 'B123', 'text' => 'Bot feedback' }
    ]
    @api = lambda do |method, body, *|
      @calls << [method, body]
      case method
      when 'views.open' then { 'view' => { 'id' => 'V123' } }
      when 'conversations.info' then { 'channel' => { 'id' => 'C123', 'name' => 'discussion', 'is_member' => @bot_member } }
      when 'conversations.members' then { 'members' => @member ? ['U123'] : [] }
      when 'conversations.replies' then { 'messages' => @messages, 'has_more' => !!@incomplete }
      when 'users.info' then { 'user' => { 'id' => body['user'], 'profile' => { 'display_name' => body['user'] == 'U123' ? 'Alice' : 'Bob' } } }
      when 'chat.postMessage'
        ts = CONNECTIONS.timestamp_now
        @messages << body.merge('ts' => ts, 'bot_id' => 'B123', 'app_id' => 'ATEST')
        { 'ts' => ts }
      else {}
      end
    end
  end

  def context(issue_lookup: @issue)
    Slackmine.stub(:config, @settings) do
      Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
        Slackmine::WorkObjects.stub(:integration_for, @integration) do
          Issue.stub(:find_by, issue_lookup) do
            enqueue = ->(*args) { @reject_enqueue ? false : (@queued << args; Object.new) }
            configured = Object.new
            configured.define_singleton_method(:perform_later) { |*args| enqueue.call(*args) }
            SlackmineThreadConnectionJob.stub(:perform_later, enqueue) do
              SlackmineThreadConnectionJob.stub(:set, ->(wait:) { assert_equal 1, wait; configured }) do
              Slackmine.stub(:slack_api, @api) do
                Slackmine::ThreadComments.stub(:persist_reply, ->(*args, **opts) { @saved << [args, opts]; :saved }) do
                  Slackmine::ThreadComments.stub(:feedback, ->(*) {}) do
                    Rails.stub(:cache, @cache) { yield }
                  end
                end
              end
              end
            end
          end
        end
      end
    end
  end

  def submitted(view, values)
    { 'type' => 'view_submission', 'user' => { 'id' => 'U123' }, 'view' => view.merge('id' => 'V123', 'state' => { 'values' => values }) }
  end

  def preview(history: true)
    CONNECTIONS.prepare_preview('ATEST', 'TTEST', @source.merge('history' => history), 'V123')
    @calls.last[1]['view']
  end

  def drain_jobs
    SlackmineThreadConnectionJob.new.perform(*@queued.shift) until @queued.empty?
  end

  def confirmation(view, selected: [0, 1])
    values = { 'issue' => { 'issue' => { 'value' => '7' } } }
    selected.each { |i| values["post_#{i}"] = { "post_#{i}" => { 'selected_options' => [{ 'value' => i.to_s }] } } }
    CONNECTIONS.save('ATEST', 'TTEST', @viewer, submitted(view, values))
  end

  def test_default_true_and_project_override_false
    context do
      assert CONNECTIONS.enabled?
      @settings['projects'] = { 'example' => { 'slack' => { 'thread_connections' => false } } }
      refute CONNECTIONS.enabled?(@issue.project)
      @settings['slack']['thread_connections'] = false
      assert_equal({}, CONNECTIONS.interaction('ATEST', 'TTEST', @payload))
      assert_empty @calls
    end
  end

  def test_global_messages_customize_the_initial_dialog
    @settings['messages'] = { 'thread_connections' => {
      'title' => 'Connect a thread', 'close' => 'Cancel', 'loading_picker' => 'Checking connection' } }
    context { CONNECTIONS.interaction('ATEST', 'TTEST', @payload) }
    view = @calls.find { |method, _| method == 'views.open' }.last['view']
    assert_equal 'Connect a thread', view.dig('title', 'text')
    assert_equal 'Cancel', view.dig('close', 'text')
    assert_equal 'Checking connection', view.dig('blocks', 0, 'text', 'text')
  end

  def test_project_messages_customize_preview_controls_content_and_feedback
    @settings['messages'] = { 'thread_connections' => { 'title' => 'Global title' } }
    @settings['projects'] = { 'example' => { 'messages' => { 'thread_connections' => {
      'title' => 'Review thread', 'close' => 'Dismiss', 'connect' => 'Connect',
      'preview_hint' => 'Issue %{id}: %{subject}', 'destination_number' => 'Destination',
      'post_preview' => '%{author}: %{text} (%{count} files)', 'save_post' => 'Keep this post',
      'import' => 'Selection', 'connected' => 'Connected successfully', 'preview_failed' => 'Cannot review' } } } }
    context do
      view = preview
      assert_equal 'Review thread', view.dig('title', 'text')
      assert_equal 'Dismiss', view.dig('close', 'text')
      assert_equal 'Connect', view.dig('submit', 'text')
      assert_equal 'Issue 7: Example issue', view.dig('blocks', 0, 'text', 'text')
      assert_equal 'Destination', view.dig('blocks', 1, 'label', 'text')
      assert_equal 'Alice: Parent message (0 files)', view.dig('blocks', 2, 'text', 'text')
      assert_equal 'Keep this post', view.dig('blocks', 3, 'element', 'options', 0, 'text', 'text')
      assert_equal 'Selection', view.dig('blocks', 3, 'label', 'text')
      CONNECTIONS.post_marker('ATEST', 'TTEST', @source, active: true)
      assert_includes @calls.last.last['text'], 'Connected successfully'
      CONNECTIONS.preview_error('V123', StandardError.new, project: @issue.project)
      assert_equal 'Cannot review', @calls.last.last.dig('view', 'blocks', 0, 'text', 'text')
      @settings['projects']['example']['messages']['thread_connections']['preview_hint'] = '%{missing}'
      assert_includes CONNECTIONS.message('preview_hint', project: @issue.project, id: 7, subject: 'Example'), '#7 Example'
    end
  end

  def test_shortcut_prepares_picker_directly_before_ack
    context do
      assert_equal({}, CONNECTIONS.interaction('ATEST', 'TTEST', @payload))
      assert_equal 'views.open', @calls.first.first
      drain_jobs
      assert_equal 'views.update', @calls.last.first
      assert @calls.any? { |method, _| method == 'conversations.replies' }
      picker = @calls.last[1]['view']
      assert_equal CONNECTIONS::PICK_CALLBACK, picker['callback_id']
      assert_equal 'history', picker['blocks'].last['element']['initial_options'].first['value']
    end
  end

  def test_preview_has_separate_authors_and_selected_posts_reach_one_import
    context do
      view = preview
      assert_includes view.to_json, 'Parent message'
      assert_includes view.to_json, 'Reply message'
      assert_includes view.to_json, 'Alice'
      assert_includes view.to_json, 'Bob'
      refute_includes view.to_json, 'Bot feedback'
      assert_equal({}, confirmation(view, selected: [1]))
      assert_empty @saved
      drain_jobs
      assert_equal 1, @saved.size
      opts = @saved.first.last
      assert_equal @viewer, opts[:import_viewer]
      assert_equal ['U456'], opts[:events].map { |e| e['user'] }
      assert_equal ['Bob'], opts[:history_cards].map { |e| e['card']['author'] }
      assert_equal Slackmine::ThreadComments.posted_at(@source['cutoff']), opts[:import_timestamp]
      assert CONNECTIONS.connection('ATEST', 'TTEST', @source, @messages)['active']
    end
  end

  def test_future_only_preview_does_not_fetch_history
    context do
      assert_equal CONNECTIONS::SAVE_CALLBACK, preview(history: false)['callback_id']
      refute @calls.any? { |method, _| method == 'conversations.replies' }
      assert @calls.any? { |method, _| method == 'conversations.members' }
    end
  end

  def test_pick_returns_completed_preview_without_an_api_update_race
    request_thread = Thread.current
    context do
      CONNECTIONS.interaction('ATEST', 'TTEST', @payload)
      drain_jobs
      picker = @calls.last[1]['view']
      @calls.clear
      result = CONNECTIONS.interaction('ATEST', 'TTEST', submitted(picker, {
        'issue' => { 'issue' => { 'value' => '7' } },
        'history' => { 'history' => { 'selected_options' => [{ 'value' => 'history' }] } }
      }))
      assert_same request_thread, Thread.current
      assert_equal 'update', result['response_action']
      assert_equal CONNECTIONS::SAVE_CALLBACK, result['view']['callback_id']
      assert_includes result['view'].to_json, 'Parent message'
      refute @calls.any? { |method, _| method == 'views.update' }
      assert_empty @queued
    end
  end

  def test_pick_falls_back_to_worker_when_direct_preview_exceeds_budget
    context do
      CONNECTIONS.interaction('ATEST', 'TTEST', @payload)
      drain_jobs
      picker = @calls.last[1]['view']
      @calls.clear
      result = nil
      CONNECTIONS.stub(:prepare_preview, ->(*) { raise CONNECTIONS::PreviewDeadline }) do
        result = CONNECTIONS.interaction('ATEST', 'TTEST', submitted(picker, {
          'issue' => { 'issue' => { 'value' => '7' } },
          'history' => { 'history' => { 'selected_options' => [{ 'value' => 'history' }] } }
        }))
      end
      assert_equal 'update', result['response_action']
      refute result['view'].key?('callback_id')
      assert_equal 1, @queued.size
      refute @calls.any? { |method, _| method == 'views.update' }
      drain_jobs
      assert_equal CONNECTIONS::SAVE_CALLBACK, @calls.last.last['view']['callback_id']
    end
  end

  def test_pick_accepts_numbers_and_local_issue_urls
    url = Slackmine::Formatter.url('/issues/7')
    ['7', '#7', " #{url} ", "#{url}#note-3", "#{url}?tab=history#note-3"].each do |value|
      found = []
      @source['nonce'] = SecureRandom.hex(16)
      context(issue_lookup: ->(id:) { found << id; id.to_s == '7' ? @issue : nil }) do
        view = CONNECTIONS.modal([], app: 'ATEST', team: 'TTEST', source: @source, callback: CONNECTIONS::PICK_CALLBACK)
        result = CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(view, {
          'issue' => { 'issue' => { 'value' => value } }
        }))
        assert_equal 'update', result['response_action'], value
        assert_equal CONNECTIONS::SAVE_CALLBACK, result['view']['callback_id'], value
        assert_equal 7, CONNECTIONS.source_for('ATEST', 'TTEST', @viewer, submitted(result['view'], {}))['issue_id']
        assert_includes found.map(&:to_s), '7'
        # Slack retains the original value for an unchanged block/action ID,
        # even when the updated view supplies a numeric initial_value.
        saved = CONNECTIONS.save('ATEST', 'TTEST', @viewer, submitted(result['view'], {
          'issue' => { 'issue' => { 'value' => value } }
        }))
        assert_equal({}, saved, value)
        assert_equal 1, @queued.size, value
        drain_jobs
      end
    end
  end

  def test_pick_rejects_foreign_urls_and_malformed_issue_references_without_lookup
    url = Slackmine::Formatter.url('/issues/7')
    ['https://other.invalid/issues/7', "#{url}/edit", "#{url}8oops", '0', '#0', 'text 7', ''].each do |value|
      context(issue_lookup: ->(*) { flunk "Unexpected lookup for #{value}" }) do
        view = CONNECTIONS.modal([], app: 'ATEST', team: 'TTEST', source: @source, callback: CONNECTIONS::PICK_CALLBACK)
        result = CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(view, {
          'issue' => { 'issue' => { 'value' => value } }
        }))
        assert_equal 'errors', result['response_action'], value
      end
    end
  end

  def test_pick_checks_permissions_for_issue_urls
    @issue.define_singleton_method(:notes_addable?) { |*| false }
    context do
      view = CONNECTIONS.modal([], app: 'ATEST', team: 'TTEST', source: @source, callback: CONNECTIONS::PICK_CALLBACK)
      result = CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(view, {
        'issue' => { 'issue' => { 'value' => Slackmine::Formatter.url('/issues/7') } }
      }))
      assert_equal 'errors', result['response_action']
      assert_empty @queued
    end
  end

  def test_save_rejects_changed_or_foreign_issue_urls
    url = Slackmine::Formatter.url('/issues/8')
    [url, "#{url}#note-3", 'https://other.invalid/issues/7', '7oops'].each do |value|
      context do
        view = preview
        result = CONNECTIONS.save('ATEST', 'TTEST', @viewer, submitted(view, {
          'issue' => { 'issue' => { 'value' => value } }
        }))
        assert_equal 'errors', result['response_action'], value
        assert_equal CONNECTIONS.message('destination_changed', project: @issue.project), result['errors']['issue']
        assert_empty @queued
      end
    end
  end

  def test_confirmation_redelivery_does_not_repeat_import_or_connection_marker
    context do
      view = preview
      assert_equal({}, confirmation(view))
      assert_equal 'errors', confirmation(view)['response_action']
      assert_equal 1, @queued.size
      drain_jobs
      assert_equal({}, confirmation(view))
      assert_equal 1, @saved.size
      assert_equal 1, @calls.count { |method, _| method == 'chat.postMessage' }
    end
  end

  def test_confirmation_accepts_hash_prefixed_issue_number
    context do
      view = preview
      values = { 'issue' => { 'issue' => { 'value' => ' #7 ' } } }
      assert_equal({}, CONNECTIONS.save('ATEST', 'TTEST', @viewer, submitted(view, values)))
      assert_equal 1, @queued.size
      drain_jobs
      assert_equal 1, @calls.count { |method, _| method == 'chat.postMessage' }
    end
  end

  def test_failed_save_enqueue_reopens_confirmation_without_claiming_a_write
    context do
      view = preview
      @reject_enqueue = true
      assert_equal 'errors', confirmation(view)['response_action']
      @reject_enqueue = false
      assert_empty @queued
      assert_equal({}, confirmation(view))
      assert_equal 1, @queued.size
    end
  end

  def test_confirmation_redelivery_while_in_progress_does_not_repeat_finish
    context do
      view = preview
      assert_equal({}, confirmation(view))
      assert_equal 'errors', confirmation(view)['response_action']
      assert_equal 1, @queued.size
    end
  end

  def test_confirmation_failure_returns_errors_and_requires_result_check_on_retry
    context do
      view = preview
      calls = 0
      CONNECTIONS.stub(:finish, lambda { |*|
        calls += 1
        raise 'Unknown save outcome'
      }) do
        assert_equal({}, confirmation(view))
        drain_jobs
        assert_equal 'errors', confirmation(view)['response_action']
      end
      assert_equal 1, calls
    end
  end

  def test_preview_denies_nonmembers_and_incomplete_history
    context do
      [-> { @member = false }, -> { @bot_member = false }, -> { @incomplete = true }].each do |deny|
        @member = @bot_member = true
        @incomplete = nil
        deny.call
        refute preview.key?('submit')
      end
    end
  end

  def test_signed_modal_is_bound_to_human_and_thread_and_cannot_be_modified
    context do
      view = preview
      payload = submitted(view, {})
      @viewer.id = 4
      assert_nil CONNECTIONS.source_for('ATEST', 'TTEST', @viewer, payload)
      @viewer.id = 3
      envelope = JSON.parse(view['private_metadata'])
      source = JSON.parse(Base64.strict_decode64(envelope['data']))
      source['channel'] = 'COTHER'
      envelope['data'] = Base64.strict_encode64(source.to_json)
      payload['view']['private_metadata'] = envelope.to_json
      assert_nil CONNECTIONS.source_for('ATEST', 'TTEST', @viewer, payload)
      assert_equal 'errors', CONNECTIONS.save('ATEST', 'TTEST', @viewer, payload)['response_action']
    end
  end

  def test_marker_rejects_human_copies_wrong_app_wrong_thread_and_modified_target
    context do
      CONNECTIONS.post_marker('ATEST', 'TTEST', @source, active: true)
      marker = @messages.last
      assert_equal 7, CONNECTIONS.connection('ATEST', 'TTEST', @source, [marker])['issue_id']
      assert_nil CONNECTIONS.connection('ATEST', 'TTEST', @source, [marker.reject { |k, _| k == 'bot_id' }])
      assert_nil CONNECTIONS.connection('ATEST', 'TTEST', @source.merge('channel' => 'COTHER'), [marker])
      assert_nil CONNECTIONS.connection('ATEST', 'TTEST', @source, [marker.merge('app_id' => 'OTHER')])
      forged = Marshal.load(Marshal.dump(marker))
      block = forged['blocks'].first
      block['block_id'] = block['block_id'].sub('slackmine_connection:', 'slackmine_connection:AAAA')
      assert_nil CONNECTIONS.connection('ATEST', 'TTEST', @source, [forged])
    end
  end

  def test_first_connection_wins_and_stale_disconnect_cannot_close_new_connection
    context do
      CONNECTIONS.post_marker('ATEST', 'TTEST', @source, active: true)
      competing = @source.merge('nonce' => 'b' * 32)
      CONNECTIONS.post_marker('ATEST', 'TTEST', competing, active: true)
      assert_equal 'a' * 32, CONNECTIONS.connection('ATEST', 'TTEST', @source, @messages)['nonce']
      CONNECTIONS.post_marker('ATEST', 'TTEST', @source, active: false)
      refute CONNECTIONS.connection('ATEST', 'TTEST', @source, @messages)['active']
      CONNECTIONS.post_marker('ATEST', 'TTEST', competing, active: true)
      CONNECTIONS.post_marker('ATEST', 'TTEST', @source, active: false)
      state = CONNECTIONS.connection('ATEST', 'TTEST', @source, @messages)
      assert state['active']
      assert_equal 'b' * 32, state['nonce']
    end
  end

  def test_changed_selected_history_is_rejected_before_connecting
    context do
      view = preview
      @messages.first['text'] = 'Edited after preview'
      assert_equal({}, confirmation(view))
      drain_jobs
      assert_empty @saved
      assert_nil CONNECTIONS.connection('ATEST', 'TTEST', @source, @messages)
    end
  end

  def test_reply_routing_ignores_old_posts_and_disconnected_state
    context do
      current = @source.merge('active' => true)
      event = @messages.first.merge('type' => 'message', 'channel' => 'C123', 'thread_ts' => @source['ts'])
      assert_equal :ignored, CONNECTIONS.process_reply(current, 'ATEST', 'TTEST', event)
      event['ts'] = '1791001000.000011'
      assert_equal :saved, CONNECTIONS.process_reply(current, 'ATEST', 'TTEST', event)
      assert_equal :ignored, CONNECTIONS.process_reply(current.merge('active' => false), 'ATEST', 'TTEST', event)
      assert_equal 1, @saved.size
    end
  end

  def test_delayed_connect_job_cannot_resurrect_a_closed_request
    context do
      source = @source.merge('posts' => [], 'ready' => true)
      CONNECTIONS.post_marker('ATEST', 'TTEST', source, active: true)
      CONNECTIONS.post_marker('ATEST', 'TTEST', source, active: false)
      other = source.merge('nonce' => 'b' * 32)
      CONNECTIONS.post_marker('ATEST', 'TTEST', other, active: true)
      CONNECTIONS.post_marker('ATEST', 'TTEST', other, active: false)
      @calls.clear
      CONNECTIONS.finish('ATEST', 'TTEST', source)
      refute @calls.any? { |method, _| method == 'chat.postMessage' }
      assert_empty @saved
      refute CONNECTIONS.connection('ATEST', 'TTEST', source, @messages)['active']
    end
  end

  def test_reply_worker_uses_signed_slack_state_and_stops_after_closure
    context do
      CONNECTIONS.post_marker('ATEST', 'TTEST', @source, active: true)
      event = @messages.first.merge('type' => 'message', 'channel' => 'C123', 'thread_ts' => @source['ts'], 'ts' => '1791001000.000011')
      assert Slackmine::ThreadComments.accepted_reply?('ATEST', 'TTEST', event)
      assert_equal :saved, Slackmine::ThreadComments.process('ATEST', 'TTEST', event)
      CONNECTIONS.post_marker('ATEST', 'TTEST', @source, active: false)
      assert_equal :ignored, Slackmine::ThreadComments.process('ATEST', 'TTEST', event)
      assert_equal 1, @saved.size
    end
  end

  def test_project_token_override_is_rejected_even_inside_project_context
    context do
      @settings['projects'] = { 'example' => { 'slack' => { 'bot_token' => 'other-token' } } }
      refute CONNECTIONS.allowed?(@issue, @viewer, 'ATEST', 'TTEST')
      Slackmine.with_project(@issue.project) { refute CONNECTIONS.allowed?(@issue, @viewer, 'ATEST', 'TTEST') }
    end
  end

  def test_more_than_twenty_human_posts_are_not_silently_truncated
    context do
      @messages = 21.times.map { |i| { 'ts' => "1791001000.#{format('%06d', i + 1)}", 'user' => 'U123', 'text' => "Post #{i}" } }
      @source['cutoff'] = '1791001000.000100'
      refute preview.key?('submit')
    end
  end

  def test_signed_shortcut_without_app_id_routes_and_unsigned_does_not
    @payload['team'] = { 'id' => 'TTEST' }
    body = URI.encode_www_form('payload' => @payload.to_json)
    timestamp = Time.now.to_i.to_s
    signature = 'v0=' + OpenSSL::HMAC.hexdigest('SHA256', 'test-secret', "v0:#{timestamp}:#{body}")
    controller = SlackmineEventsController.new
    controller.request = OpenStruct.new(content_length: body.bytesize, raw_post: body, headers: {
      'X-Slack-Request-Timestamp' => timestamp, 'X-Slack-Signature' => signature })
    calls = []
    context do
      CONNECTIONS.stub(:interaction, ->(*args) { calls << args; {} }) do
        controller.receive
        assert_equal :ok, controller.status
        assert_equal 'ATEST', calls.first.first
        controller.request.headers['X-Slack-Signature'] = 'invalid'
        controller.receive
        assert_equal :unauthorized, controller.status
        assert_equal 1, calls.size
      end
    end
  end
end
