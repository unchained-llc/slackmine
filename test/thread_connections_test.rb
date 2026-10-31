# frozen_string_literal: true
require_relative 'message_shortcuts_test'
require_relative '../app/jobs/slackmine_thread_connection_job'

class Issue
  def self.visible(*)
    scope = Object.new
    %i[where order limit].each { |method| scope.define_singleton_method(method) { |*| self } }
    scope.define_singleton_method(:to_a) { [] }
    scope
  end unless respond_to?(:visible)
end

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
      assert_equal 'Alice: Parent message (0 files)', view.dig('blocks', 1, 'text', 'text')
      assert_equal 'Keep this post', view.dig('blocks', 2, 'elements', 0, 'options', 0, 'text', 'text')
      assert_equal 'actions', view.dig('blocks', 2, 'type')
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
      assert_equal CONNECTIONS::SEARCH_CALLBACK, picker['callback_id']
      assert_equal ['search_issue'], picker['blocks'].map { |block| block['block_id'] }.compact
    end
  end

  def test_individual_mode_reviews_and_imports_only_selected_posts
    context do
      CONNECTIONS.prepare_picker('ATEST', 'TTEST', @source, 'V123')
      values = { 'search_issue' => { 'search_issue' => { 'selected_option' => { 'value' => '7' } } } }
      result = CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(@calls.last.last['view'], values))
      assert_includes result['view'].to_json, 'Parent message'
      selection = result['view']['blocks'].find { |block| block['block_id'] == 'post_1' }
      assert_equal 'actions', selection['type']
      refute selection.key?('optional')
      action = submitted(result['view'], {}).merge('type' => 'block_actions', 'actions' => [{ 'action_id' => 'post_1' }])
      assert CONNECTIONS.handles?(action)
      assert_equal({}, CONNECTIONS.interaction('ATEST', 'TTEST', action))
      assert_empty @queued
      state = { 'post_1' => { 'post_1' => { 'selected_options' => [{ 'value' => '1' }] } } }
      assert_equal({}, CONNECTIONS.save('ATEST', 'TTEST', @viewer, submitted(result['view'], state)))
      drain_jobs
      assert_equal ['U456'], @saved.first.last[:events].map { |event| event['user'] }
    end
  end

  def test_individual_mode_selects_across_groups_of_100
    context do
      @messages = 101.times.map { |index| { 'ts' => format('1791001%03d.000001', index), 'user' => 'U123', 'text' => "Post #{index}" } }
      CONNECTIONS.prepare_picker('ATEST', 'TTEST', @source, 'V123')
      values = { 'search_issue' => { 'search_issue' => { 'selected_option' => { 'value' => '7' } } } }
      result = CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(@calls.last.last['view'], values))
      groups = result['view']['blocks'].select { |block| block['block_id'].to_s.start_with?('history_group_') }
      assert_equal [100, 1], groups.map { |block| block['accessory']['options'].size }
      state = { 'history_group_0' => { 'history_group_0' => { 'selected_options' => [{ 'value' => '0' }] } },
        'history_group_1' => { 'history_group_1' => { 'selected_options' => [{ 'value' => '100' }] } } }
      assert_equal({}, CONNECTIONS.save('ATEST', 'TTEST', @viewer, submitted(result['view'], state)))
      drain_jobs
      assert_equal ['Post 0', 'Post 100'], @saved.first.last[:events].map { |event| event['text'] }
    end
  end

  def test_individual_mode_at_thread_limit_keeps_signed_metadata_and_request_bounded
    context do
      @messages = 999.times.map { |index| { 'ts' => format('179100%04d.000001', index), 'user' => 'U123', 'text' => 'x' * 60 } }
      source = @source.merge('bulk_history' => true, 'individual_history' => true, 'history' => true, 'cutoff' => CONNECTIONS.timestamp_now)
      view = CONNECTIONS.prepare_preview('ATEST', 'TTEST', source)
      assert_equal CONNECTIONS::SAVE_CALLBACK, view['callback_id']
      groups = view['blocks'].select { |block| block['block_id'].to_s.start_with?('history_group_') }
      assert_equal 10, groups.size
      assert_operator view['private_metadata'].bytesize, :<, 3000
      values = groups.to_h { |group| [group['block_id'], { group['block_id'] => { 'selected_options' => group['accessory']['initial_options'] } }] }
      payload = submitted(view, values).merge('api_app_id' => 'ATEST', 'team' => { 'id' => 'TTEST' })
      body = URI.encode_www_form('payload' => JSON.generate(payload))
      assert_operator body.bytesize, :>, 65_536
      assert_operator body.bytesize, :<, 1_048_576
      assert_equal({}, CONNECTIONS.save('ATEST', 'TTEST', @viewer, submitted(view, values)))
      assert_operator @queued.last[2]['selection_bits'].bytesize, :<, 200
    end
  end

  def test_bulk_import_handles_100_posts_and_rejects_text_over_limit
    context do
      @messages = 100.times.map { |index| { 'ts' => format('1791001%03d.000001', index), 'user' => 'U123', 'text' => "Post #{index}" } }
      CONNECTIONS.prepare_picker('ATEST', 'TTEST', @source, 'V123')
      values = { 'search_issue' => { 'search_issue' => { 'selected_option' => { 'value' => '7' } } },
        'history' => { 'history' => { 'selected_options' => [{ 'value' => 'history' }] } } }
      result = CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(@calls.last.last['view'], values))
      assert_equal CONNECTIONS::SAVE_CALLBACK, result.dig('view', 'callback_id')
      assert_includes result['view'].to_json, '100 past posts'
      refute result['view']['blocks'].any? { |block| block['block_id'].to_s.start_with?('post_') }
      options = result['view']['blocks'].find { |block| block['block_id'] == 'history_group_0' }.dig('accessory', 'initial_options')
      all_selected = { 'history_group_0' => { 'history_group_0' => { 'selected_options' => options } } }
      assert_equal({}, CONNECTIONS.save('ATEST', 'TTEST', @viewer, submitted(result['view'], all_selected)))
      drain_jobs
      assert_equal 100, @saved.first.last[:history_cards].size

      @source['nonce'] = SecureRandom.hex(16)
      @messages = [{ 'ts' => '1791001000.000001', 'user' => 'U123', 'text' => 'x' * 100_001 }]
      CONNECTIONS.prepare_picker('ATEST', 'TTEST', @source, 'V123')
      result = CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(@calls.last.last['view'], values))
      refute result['view'].key?('submit')
      assert_includes result['view'].to_json, CONNECTIONS.message('bulk_history_text_limit')
    end
  end

  def test_bulk_preview_rejects_too_many_files_and_a_long_post
    context do
      source = @source.merge('bulk_history' => true, 'history' => true, 'cutoff' => CONNECTIONS.timestamp_now)
      @messages = [{ 'ts' => '1791001000.000001', 'user' => 'U123', 'text' => 'x' * 10_001 }]
      view = CONNECTIONS.prepare_preview('ATEST', 'TTEST', source)
      refute view.key?('submit')
      assert_includes view.to_json, CONNECTIONS.message('bulk_history_post_limit')
      @messages = [{ 'ts' => '1791001000.000001', 'user' => 'U123', 'text' => 'files',
        'files' => 11.times.map { |index| { 'id' => "F#{index}" } } }]
      view = CONNECTIONS.prepare_preview('ATEST', 'TTEST', source)
      refute view.key?('submit')
      assert_includes view.to_json, CONNECTIONS.message('bulk_history_files_limit')
    end
  end

  def test_bulk_history_changed_after_review_is_rejected_before_connection
    context do
      source = @source.merge('bulk_history' => true, 'history' => true, 'cutoff' => CONNECTIONS.timestamp_now)
      view = CONNECTIONS.prepare_preview('ATEST', 'TTEST', source)
      saved_source = CONNECTIONS.source_for('ATEST', 'TTEST', @viewer, submitted(view, {}))
      @messages.first['text'] = 'Edited after review'
      assert_raises(RuntimeError) { CONNECTIONS.finish('ATEST', 'TTEST', saved_source) }
      refute @calls.any? { |method, _| method == 'chat.postMessage' }
    end
  end

  def test_full_thread_returns_capacity_error_before_connecting
    context do
      messages = 1000.times.map { |index| { 'ts' => format('1791001%03d.000001', index), 'user' => 'U123', 'text' => 'Post' } }
      CONNECTIONS.stub(:history, messages) { CONNECTIONS.prepare_picker('ATEST', 'TTEST', @source, 'V123') }
      view = @calls.last.last['view']
      refute view.key?('submit')
      assert_includes view.to_json, CONNECTIONS.message('bulk_thread_limit')
      refute @calls.any? { |method, _| method == 'chat.postMessage' }
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

  def test_recent_issue_can_be_selected_and_permissions_are_rechecked
    scope = Object.new
    %i[order limit].each { |method| scope.define_singleton_method(method) { |*| self } }
    scope.define_singleton_method(:to_a) { [@candidate] }
    scope.instance_variable_set(:@candidate, @issue)
    context do
      Issue.stub(:visible, scope) do
        CONNECTIONS.prepare_picker('ATEST', 'TTEST', @source, 'V123')
      end
      picker = @calls.last.last['view']
      assert_equal 'external_select', picker.dig('blocks', 1, 'element', 'type')
      suggestion = submitted(picker, {}).merge('type' => 'block_suggestion', 'action_id' => 'search_issue', 'value' => '')
      options = Issue.stub(:visible, scope) { CONNECTIONS.interaction('ATEST', 'TTEST', suggestion)['options'] }
      assert_equal ['7'], options.map { |option| option['value'] }
      values = { 'search_issue' => { 'search_issue' => { 'selected_option' => { 'value' => '7' } } } }
      result = CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(picker, values))
      assert_equal CONNECTIONS::SAVE_CALLBACK, result.dig('view', 'callback_id')
      refute result['view']['blocks'].any? { |block| %w[issue destination].include?(block['block_id']) }
      assert_equal({}, CONNECTIONS.save('ATEST', 'TTEST', @viewer, submitted(result['view'], {})))
      @issue.define_singleton_method(:notes_addable?) { |*| false }
      assert_equal 'errors', CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(picker, values))['response_action']
    end
  end

  def test_suggestions_search_titles_and_references_and_check_source
    added_sanitize = !Issue.respond_to?(:sanitize_sql_like)
    Issue.define_singleton_method(:sanitize_sql_like) { |value| value } if added_sanitize
    scope = Object.new
    scope.define_singleton_method(:where) { |*args| raise 'bad query' unless args.last == '%example%'; self }
    %i[order limit].each { |method| scope.define_singleton_method(method) { |*| self } }
    scope.define_singleton_method(:to_a) { [@candidate] }
    scope.instance_variable_set(:@candidate, @issue)
    context do
      view = CONNECTIONS.modal([], app: 'ATEST', team: 'TTEST', source: @source, callback: CONNECTIONS::SEARCH_CALLBACK)
      payload = submitted(view, {}).merge('type' => 'block_suggestion', 'action_id' => 'search_issue', 'value' => 'Example')
      options = Issue.stub(:visible, scope) { CONNECTIONS.interaction('ATEST', 'TTEST', payload)['options'] }
      assert_equal ['7'], options.map { |option| option['value'] }
      ['#7', Slackmine::Formatter.url('/issues/7')].each do |query|
        assert_equal ['7'], CONNECTIONS.interaction('ATEST', 'TTEST', payload.merge('value' => query))['options'].map { |option| option['value'] }
      end
      payload['view']['private_metadata'] = 'invalid'
      assert_empty CONNECTIONS.interaction('ATEST', 'TTEST', payload)['options']
    end
  ensure
    Issue.singleton_class.remove_method(:sanitize_sql_like) if added_sanitize
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
        'search_issue' => { 'search_issue' => { 'selected_option' => { 'value' => '7' } } },
        'history' => { 'history' => { 'selected_options' => [{ 'value' => 'history' }] } }
      }))
      assert_same request_thread, Thread.current
      assert_equal 'update', result['response_action']
      assert_equal CONNECTIONS::SAVE_CALLBACK, result['view']['callback_id']
      assert_includes result['view'].to_json, '2 past posts'
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
          'search_issue' => { 'search_issue' => { 'selected_option' => { 'value' => '7' } } },
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
        empty_scope = Object.new
        %i[where order limit].each { |method| empty_scope.define_singleton_method(method) { |*| self } }
        empty_scope.define_singleton_method(:to_a) { [] }
        result = Issue.stub(:visible, empty_scope) do
          CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(view, {
            'issue' => { 'issue' => { 'value' => value } }
          }))
        end
        assert_equal 'errors', result['response_action'], value
      end
    end
  end

  def test_title_search_selects_only_allowed_issues_and_preserves_history
    added_sanitize = !Issue.respond_to?(:sanitize_sql_like)
    Issue.define_singleton_method(:sanitize_sql_like) { |value| value } if added_sanitize
    denied = @issue.dup
    denied.id = 8
    denied.define_singleton_method(:is_private?) { false }
    denied.define_singleton_method(:visible?) { |*| true }
    denied.define_singleton_method(:notes_addable?) { |*| false }
    scope = Object.new
    scope.define_singleton_method(:where) { |*args| raise 'unescaped query' unless args.last == '%example%'; self }
    %i[order limit].each { |method| scope.define_singleton_method(method) { |*| self } }
    scope.define_singleton_method(:to_a) { [@allowed, @denied] }
    scope.instance_variable_set(:@allowed, @issue)
    scope.instance_variable_set(:@denied, denied)
    context do
      view = CONNECTIONS.modal([], app: 'ATEST', team: 'TTEST', source: @source, callback: CONNECTIONS::PICK_CALLBACK)
      result = Issue.stub(:visible, scope) do
        Issue.stub(:sanitize_sql_like, ->(value) { value }) do
          CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(view, {
            'issue' => { 'issue' => { 'value' => 'Example' } },
            'history' => { 'history' => { 'selected_options' => [{ 'value' => 'history' }] } }
          }))
        end
      end
      picker = result['view']
      assert_equal CONNECTIONS::SELECT_CALLBACK, picker['callback_id']
      assert_equal ['7'], picker.dig('blocks', 1, 'element', 'options').map { |option| option['value'] }
      result = CONNECTIONS.pick('ATEST', 'TTEST', @viewer, submitted(picker, {
        'choice' => { 'choice' => { 'selected_option' => { 'value' => '7' } } }
      }))
      assert_equal CONNECTIONS::SAVE_CALLBACK, result.dig('view', 'callback_id')
      assert_includes result['view'].to_json, 'Parent message'
    end
  ensure
    Issue.singleton_class.remove_method(:sanitize_sql_like) if added_sanitize
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
        source = CONNECTIONS.source_for('ATEST', 'TTEST', @viewer, submitted(view, {}))
        source.delete('fixed_destination')
        view['private_metadata'] = CONNECTIONS.signed_source('ATEST', 'TTEST', source)
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
      assert_equal 'update', confirmation(view)['response_action']
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
      assert_equal 'update', confirmation(view)['response_action']
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
      assert_equal 'update', confirmation(view)['response_action']
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
        assert_equal 'update', confirmation(view)['response_action']
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
