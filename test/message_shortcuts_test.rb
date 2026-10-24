# frozen_string_literal: true
require_relative 'slash_commands_cache_test'

class Project
  STATUS_ACTIVE = 1 unless const_defined?(:STATUS_ACTIVE)
  def self.allowed_to(*)
  end unless respond_to?(:allowed_to)
end

class MessageShortcutsTest < Minitest::Test
  SHORTCUTS = Slackmine::MessageShortcuts
  COMMANDS = Slackmine::SlashCommands

  def setup
    @settings = { 'slack' => { 'slash_command' => '/slackmine', 'bot_token' => 'token',
      'events' => { 'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'test-secret' } } }
    @viewer = OpenStruct.new(id: 3)
    @allowed = true
    @viewer.define_singleton_method(:allowed_to?) { |*| true }
    @project = OpenStruct.new(id: 1, name: 'Example', identifier: 'example', active?: true)
    @projects = [@project]
    @scope = Object.new
    @scope.define_singleton_method(:where) { |*| self }
    @scope.define_singleton_method(:order) { |*| self }
    @scope.define_singleton_method(:to_a) { @rows.dup }
    @cache = SlashCommandsCacheTest::Cache.new
    @calls = []
    @permalink = 'https://example.slack.com/archives/C123/p1234567890000001?thread_ts=1234567800.000001&cid=C123'
    @payload = { 'type' => 'message_action', 'callback_id' => SHORTCUTS::CALLBACK,
      'api_app_id' => 'ATEST', 'team' => { 'id' => 'TTEST' }, 'user' => { 'id' => 'U123' },
      'trigger_id' => 'fresh-trigger', 'channel' => { 'id' => 'C123' },
      'message' => { 'ts' => '1234567890.000001', 'text' => "First line\nDetails", 'thread_ts' => '1234567800.000001' } }
  end

  def with_context
    @scope.instance_variable_set(:@rows, @projects)
    Slackmine.stub(:config, @settings) do
      Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
        COMMANDS.stub(:authorized_project?, ->(*) { @allowed }) do
          Project.stub(:allowed_to, @scope) do
            Project.stub(:find_by, ->(id:) { id.to_s == '1' ? @project : nil }) do
              Rails.stub(:cache, @cache) do
                Slackmine.stub(:channel_id, 'C123') do
                  Slackmine.stub(:slack_api, ->(*args) { raise Timeout::Error if @timeout; @calls << args; { 'permalink' => @permalink } }) { yield }
                end
              end
            end
          end
        end
      end
    end
  end

  def open_picker
    assert_equal({}, SHORTCUTS.interaction('ATEST', 'TTEST', @payload))
    @calls.last[1]['view']
  end

  def selection(view)
    { 'type' => 'view_submission', 'user' => { 'id' => 'U123' }, 'view' => view.merge(
      'id' => 'V123', 'state' => { 'values' => { 'project' => { 'project' => { 'selected_option' => { 'value' => '1' } } } } }) }
  end

  def creation_view(picker)
    issue = OpenStruct.new(allowed_target_trackers: [OpenStruct.new(id: 2, name: 'Task')])
    issue.define_singleton_method(:allowed_target_trackers) { |*| [OpenStruct.new(id: 2, name: 'Task')] }
    Issue.stub(:new, issue) do
      Slackmine::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
        SHORTCUTS.interaction('ATEST', 'TTEST', selection(picker))
      end
    end
  end

  def test_shortcut_opens_picker_then_prefills_existing_create_form_without_saving
    with_context do
      picker = open_picker
      assert_equal 'views.open', @calls.first[0]
      assert_equal SHORTCUTS::PROJECT_CALLBACK, picker['callback_id']
      refute_includes picker.to_json, 'Details'
      result = creation_view(picker)
      assert_equal 'update', result['response_action']
      view = result['view']
      assert_equal 'slackmine_command_create', view['callback_id']
      assert_equal '1', view['private_metadata']
      fields = view['blocks'].select { |b| b['type'] == 'input' }.to_h { |b| [b['block_id'], b['element']] }
      assert_equal 'First line', fields['subject']['initial_value']
      assert_includes fields['description']['initial_value'], "First line\nDetails"
      assert_includes fields['description']['initial_value'], @permalink
      assert_equal '1234567890.000001', @calls.last[1]['message_ts']
      assert_equal 'chat.getPermalink', @calls.last[0]
      assert SHORTCUTS.handles?(@payload)
      assert SHORTCUTS.handles?(selection(picker))
      assert COMMANDS.handles?('view' => view)
    end
  end

  def test_unknown_users_disabled_commands_and_wrong_integration_cannot_open_creation
    with_context do
      @settings['slack'].delete('slash_command')
      assert_equal({}, SHORTCUTS.interaction('ATEST', 'TTEST', @payload))
      assert_empty @calls
      @settings['slack']['slash_command'] = '/slackmine'
      assert_equal({}, SHORTCUTS.interaction('OTHER', 'TTEST', @payload))
      assert_empty @calls
      @viewer = nil
    end
    with_context do
      view = open_picker
      refute view.key?('submit')
      assert_includes view.to_json, 'Not available'
    end
  end

  def test_source_context_is_bound_to_identity_and_expires_without_cache
    with_context do
      picker = open_picker
      @viewer.id = 4
      assert_equal 'errors', creation_view(picker)['response_action']
      @viewer.id = 3
      @cache.delete(SHORTCUTS.context_key('ATEST', 'TTEST', @viewer, picker['private_metadata']))
      assert_includes creation_view(picker).to_json, 'expired'
      refute @calls.any? { |c| c[0] == 'chat.getPermalink' }
    end
  end

  def test_permission_revocation_and_forged_project_are_rejected_before_permalink
    with_context do
      picker = open_picker
      @allowed = false
      assert_equal 'errors', creation_view(picker)['response_action']
      @allowed = true
      @viewer.define_singleton_method(:allowed_to?) { |*| false }
      assert_equal 'errors', creation_view(picker)['response_action']
      @viewer.define_singleton_method(:allowed_to?) { |*| true }
      payload = selection(picker)
      payload['view']['state']['values']['project']['project']['selected_option']['value'] = '999'
      assert_equal 'errors', SHORTCUTS.interaction('ATEST', 'TTEST', payload)['response_action']
      refute @calls.any? { |c| c[0] == 'chat.getPermalink' }
    end
  end

  def test_long_multibyte_message_preserves_source_link_within_input_limit
    @payload['message']['text'] = "\u3042" * 4000
    with_context do
      view = creation_view(open_picker)['view']
      description = view['blocks'].find { |b| b['block_id'] == 'description' }.dig('element', 'initial_value')
      assert_equal 3000, description.length
      assert description.end_with?(@permalink)
      assert_equal 255, view['blocks'].find { |b| b['block_id'] == 'subject' }.dig('element', 'initial_value').length
    end
  end

  def test_invalid_or_empty_source_and_empty_project_list_offer_no_submit
    with_context do
      @payload['message']['text'] = ''
      refute open_picker.key?('submit')
      @payload['message']['text'] = 'Task'
      @payload['message']['ts'] = 'invalid'
      refute open_picker.key?('submit')
      @payload['message']['ts'] = '123.456'
      @projects.clear
    end
    with_context { refute open_picker.key?('submit') }
  end

  def test_unsigned_shortcuts_never_reach_handler_and_signed_payload_routes
    # Actual message shortcuts omit api_app_id, unlike modal/button payloads.
    @payload.delete('api_app_id')
    calls = []
    body = URI.encode_www_form('payload' => JSON.generate(@payload))
    timestamp = Time.now.to_i.to_s
    signature = 'v0=' + OpenSSL::HMAC.hexdigest('SHA256', 'test-secret', "v0:#{timestamp}:#{body}")
    controller = SlackmineEventsController.new
    controller.request = OpenStruct.new(content_length: body.bytesize, raw_post: body, headers: {
      'X-Slack-Request-Timestamp' => timestamp, 'X-Slack-Signature' => signature })
    with_context do
      SHORTCUTS.stub(:interaction, ->(*args) { calls << args; {} }) do
        controller.receive
        assert_equal :ok, controller.status
        assert_equal ['ATEST', 'TTEST', @payload], calls.first
        controller.request.headers['X-Slack-Signature'] = 'v0=' + '0' * 64
        controller.receive
        assert_equal :unauthorized, controller.status
        assert_equal 1, calls.length
        controller.request.headers['X-Slack-Signature'] = signature
        @payload['team']['id'] = 'TOTHER'
        other_body = URI.encode_www_form('payload' => JSON.generate(@payload))
        controller.request.raw_post = other_body
        controller.request.content_length = other_body.bytesize
        controller.request.headers['X-Slack-Signature'] = 'v0=' + OpenSSL::HMAC.hexdigest('SHA256', 'test-secret', "v0:#{timestamp}:#{other_body}")
        controller.receive
        assert_equal :unauthorized, controller.status
        assert_equal 1, calls.length
      end
    end
  end

  def test_prefilled_form_saves_once_through_existing_creation_and_rechecks_permissions
    with_context do
      view = creation_view(open_picker)['view']
      values = {}
      view['blocks'].each do |block|
        next unless %w[subject description].include?(block['block_id'])
        key = block['block_id']
        values[key] = { key => { 'value' => block['element']['initial_value'] } }
      end
      values['tracker'] = { 'tracker' => { 'selected_option' => { 'value' => '2' } } }
      view.merge!('id' => 'V123', 'state' => { 'values' => values })
      submitted = { 'type' => 'view_submission', 'user' => { 'id' => 'U123' }, 'view' => view }
      count = 0
      attributes = nil
      issue = Object.new
      issue.define_singleton_method(:allowed_target_trackers) { |*| [OpenStruct.new(id: 2)] }
      issue.define_singleton_method(:safe_attributes=) { |attrs, _user| attributes = attrs }
      issue.define_singleton_method(:save) { count += 1; true }
      Issue.stub(:new, issue) do
        @allowed = false
        assert_equal 'errors', COMMANDS.interaction('ATEST', 'TTEST', submitted)['response_action']
        assert_equal 0, count
        @allowed = true
        queued = []
        SlackmineCommandFormJob.stub(:perform_later, ->(*args) { queued << args; Object.new }) do
          assert_equal({}, COMMANDS.interaction('ATEST', 'TTEST', submitted))
          assert_equal 'errors', COMMANDS.interaction('ATEST', 'TTEST', submitted)['response_action']
        end
        assert_equal 1, queued.size
        assert_equal 0, count
        SlackmineCommandFormJob.new.perform(*queued.first)
        assert_equal({}, COMMANDS.interaction('ATEST', 'TTEST', submitted))
        assert_equal 1, count
        assert_equal 'First line', attributes['subject']
        assert_includes attributes['description'], @permalink
      end
    end
  end

  def test_permalink_failure_keeps_picker_open_for_retry
    with_context do
      picker = open_picker
      @permalink = 'https://example.invalid/untrusted'
      assert_equal 'errors', creation_view(picker)['response_action']
      @permalink = 'https://example.slack.com/archives/C123/p1234567890000001'
      @timeout = true
      assert_includes creation_view(picker).to_json, 'Please retry'
      @timeout = false
      assert_equal 'update', creation_view(picker)['response_action']
    end
  end

  def test_only_permitted_projects_appear_and_unknown_shortcuts_are_not_handled
    with_context do
      @allowed = false
      refute open_picker.key?('submit')
      refute SHORTCUTS.handles?(@payload.merge('callback_id' => 'other_shortcut'))
      refute SHORTCUTS.handles?(@payload.merge('type' => 'shortcut'))
    end
  end

  def test_attachment_only_notification_opens_and_prefills_creation_form
    @payload['message']['text'] = ''
    @payload['message']['attachments'] = [{ 'title' => 'Service alert', 'text' => 'Connection failed',
      'fields' => [{ 'title' => 'Reason', 'value' => 'Timeout' }], 'fallback' => 'Duplicated fallback' }]
    with_context do
      view = creation_view(open_picker)['view']
      assert_equal 'slackmine_command_create', view['callback_id']
      assert_equal 'Service alert', view['blocks'].find { |b| b['block_id'] == 'subject' }.dig('element', 'initial_value')
      description = view['blocks'].find { |b| b['block_id'] == 'description' }.dig('element', 'initial_value')
      assert_includes description, "Service alert\nConnection failed\nReason: Timeout"
      assert_includes description, @permalink
      refute_includes description, 'Duplicated fallback'
    end
  end

  def test_block_only_text_and_fallback_are_extracted_without_button_values
    assert_equal "Notice\nDetails\nField\nContext", SHORTCUTS.message_text('blocks' => [
      { 'type' => 'header', 'text' => { 'text' => 'Notice' } },
      { 'type' => 'section', 'text' => { 'text' => 'Details' }, 'fields' => [{ 'text' => 'Field' }] },
      { 'type' => 'context', 'elements' => [{ 'type' => 'mrkdwn', 'text' => 'Context' }] },
      { 'type' => 'actions', 'elements' => [{ 'type' => 'button', 'value' => 'secret-action' }] }])
    assert_equal 'Fallback', SHORTCUTS.message_text('attachments' => [{ 'fallback' => 'Fallback' }])
    assert_equal 'Normal text', SHORTCUTS.message_text('text' => 'Normal text', 'attachments' => [{ 'text' => 'Extra' }])
    assert_equal 'Hello <@U123>', SHORTCUTS.message_text('blocks' => [{ 'type' => 'rich_text', 'elements' => [
      { 'type' => 'rich_text_section', 'elements' => [{ 'type' => 'text', 'text' => 'Hello ' }, { 'type' => 'user', 'user_id' => 'U123' }] }] }])
  end
end
