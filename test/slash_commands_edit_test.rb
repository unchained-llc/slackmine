# frozen_string_literal: true
require_relative 'slash_commands_cache_test'

class SlashCommandsEditTest < Minitest::Test
  COMMANDS = Slackmine::SlashCommands
  WORK = Slackmine::WorkObjects

  def setup
    @settings = { 'slack' => { 'slash_command' => '/slackmine', 'bot_token' => 'token',
      'work_object_actions' => true, 'events' => { 'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'test-secret' } } }
    @viewer = OpenStruct.new(id: 3, name: 'Example User')
    @project = OpenStruct.new(active?: true, identifier: 'example')
    @issue = OpenStruct.new(id: 7, subject: 'Example issue', project: @project,
      status_id: 2, assigned_to_id: 3, is_private?: false, can_view: true, can_edit: true,
      writable: %w[status_id assigned_to_id], journals: [], lock_count: 0,
      statuses: [OpenStruct.new(id: 2, name: 'Open'), OpenStruct.new(id: 5, name: 'Done')],
      assignees: [@viewer, OpenStruct.new(id: 4, name: 'Another User')])
    @issue.define_singleton_method(:status) { statuses.find { |item| item.id == status_id } }
    @issue.define_singleton_method(:visible?) { |_user| can_view }
    @issue.define_singleton_method(:attributes_editable?) { |_user| can_edit }
    @issue.define_singleton_method(:safe_attribute?) { |key, _user| writable.include?(key) }
    @issue.define_singleton_method(:new_statuses_allowed_to) { |_user| statuses }
    @issue.define_singleton_method(:assignable_users) { assignees }
    @issue.define_singleton_method(:with_lock) { |&block| self.lock_count += 1; block.call }
    @issue.define_singleton_method(:init_journal) { |user, note| journals << [user.id, note] }
    @issue.define_singleton_method(:safe_attributes=) do |attrs, _user|
      self.status_id = attrs['status_id'].to_i if attrs.key?('status_id')
      self.assigned_to_id = attrs['assigned_to_id'].empty? ? nil : attrs['assigned_to_id'].to_i if attrs.key?('assigned_to_id')
    end
    @issue.define_singleton_method(:save!) { true }
    @issue.define_singleton_method(:reload) { self }
    @issue.define_singleton_method(:assigned_to) { assignees.find { |user| user.id == assigned_to_id } }
    @cache = SlashCommandsCacheTest::Cache.new
    @calls = []
    @delivery_failure = false
    @authorized = true
  end

  def with_edits(viewer: @viewer)
    Slackmine.stub(:config, @settings) do
      WORK.stub(:viewer_for, viewer) do
        COMMANDS.stub(:authorized_project?, ->(project, *) { @authorized && project.active? }) do
          Issue.stub(:find_by, ->(id:) { id.to_s == '7' ? @issue : nil }) do
            Slackmine::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
              Slackmine.stub(:slack_api, ->(*args) { raise 'Delivery unavailable' if @delivery_failure; @calls << args }) do
                Rails.stub(:cache, @cache) { yield }
              end
            end
          end
        end
      end
    end
  end

  def button_payload(kind)
    { 'type' => 'block_actions', 'user' => { 'id' => 'U123' }, 'trigger_id' => 'fresh-trigger',
      'actions' => [COMMANDS.button('Edit', "#{kind} 7")] }
  end

  def submission(kind, value)
    key = kind == 'assign' ? 'assignee' : 'status'
    { 'type' => 'view_submission', 'user' => { 'id' => 'U123' }, 'view' => {
      'id' => "V#{kind}", 'callback_id' => "slackmine_command_#{kind}", 'private_metadata' => '7',
      'state' => { 'values' => { key => { key => { 'selected_option' => { 'value' => value } } } } } } }
  end

  def test_commands_return_private_edit_buttons_without_changing_the_issue
    with_edits do
      %w[status assign].each do |kind|
        COMMANDS.deliver('ATEST', 'TTEST', { 'text' => "#{kind} #7", 'user_id' => 'U123', 'channel_id' => 'C123' })
        method, result = @calls.last
        assert_equal 'chat.postEphemeral', method
        assert_equal 'U123', result['user']
        assert_equal "#{kind} 7", result.dig('blocks', -1, 'elements', 0, 'value')
        assert_includes result.to_json, '#7 Example issue'
      end
    end
    assert_empty @issue.journals
    assert_equal 0, @issue.lock_count
  end

  def test_hidden_private_inactive_disabled_and_uneditable_issues_are_not_disclosed
    changes = [-> { @issue.can_view = false }, -> { @issue[:is_private?] = true },
      -> { @project[:active?] = false }, -> { @settings['slack']['work_object_actions'] = false },
      -> { @issue.can_edit = false }, -> { @issue.writable = [] }, -> { @authorized = false }]
    changes.each do |change|
      setup
      change.call
      with_edits do
        %w[status assign].each do |kind|
          result = COMMANDS.run('ATEST', 'TTEST', 'U123', 'C123', "#{kind} 7").to_json
          assert_includes result, 'Not available'
          refute_includes result, 'Example issue'
        end
      end
    end
  end

  def test_missing_identity_and_invalid_command_arguments_cannot_open_an_editor
    with_edits(viewer: nil) do
      assert_includes COMMANDS.run('ATEST', 'TTEST', 'U123', 'C123', 'status 7').to_json, 'Not available'
    end
    with_edits do
      ['status', 'assign 0', 'status 7 Done', 'assign 7 4'].each do |text|
        result = COMMANDS.run('ATEST', 'TTEST', 'U123', 'C123', text).to_json
        assert_includes result, 'Issue commands'
        refute_includes result, 'Example issue'
      end
    end
  end

  def test_button_opens_only_the_requested_picker_with_a_fresh_trigger
    with_edits do
      %w[status assign].each do |kind|
        assert_equal({}, COMMANDS.interaction('ATEST', 'TTEST', button_payload(kind)))
        method, result = @calls.last
        assert_equal 'views.open', method
        assert_equal 'fresh-trigger', result['trigger_id']
        view = result['view']
        assert_equal "slackmine_command_#{kind}", view['callback_id']
        assert_equal '7', view['private_metadata']
        fields = view['blocks'].select { |block| block['type'] == 'input' }
        assert_equal [kind == 'assign' ? 'assignee' : 'status'], fields.map { |field| field['block_id'] }
        assert_equal(kind == 'assign' ? %w[none 3 4] : %w[2 5], fields.first.dig('element', 'options').map { |option| option['value'] })
        assert_includes view.to_json, '#7 Example issue'
      end
      @calls.clear
      @issue.can_edit = false
      COMMANDS.interaction('ATEST', 'TTEST', button_payload('status'))
      @issue.can_edit = true
      COMMANDS.interaction('ATEST', 'TTEST', button_payload('assign').merge('trigger_id' => ''))
      assert_empty @calls
    end
    assert_empty @issue.journals
  end

  def test_picker_respects_slack_option_limits_and_unassigned_initial_value
    with_edits do
      @issue.assigned_to_id = nil
      assert_equal 'none', COMMANDS.modal('assign', '7', @viewer).dig('blocks', -1, 'element', 'initial_option', 'value')
      @issue.assignees = (1..100).map { |id| OpenStruct.new(id: id, name: "User #{id}") }
      assert_nil COMMANDS.modal('assign', '7', @viewer)
      @issue.statuses = (1..101).map { |id| OpenStruct.new(id: id, name: "Status #{id}") }
      assert_nil COMMANDS.modal('status', '7', @viewer)
      @issue.statuses = []
      assert_nil COMMANDS.modal('status', '7', @viewer)
    end
  end

  def test_status_and_assignee_submissions_use_locked_permission_checked_writes
    previous = User.current
    with_edits do
      status = submission('status', '5')
      # Fields unrelated to this command must never be applied.
      status['view']['state']['values']['assignee'] = submission('assign', '4').dig('view', 'state', 'values', 'assignee')
      assert_equal({}, COMMANDS.interaction('ATEST', 'TTEST', status))
      assert_equal 5, @issue.status_id
      assert_equal 3, @issue.assigned_to_id
      assert_equal({}, COMMANDS.interaction('ATEST', 'TTEST', submission('assign', '4')))
      assert_equal 4, @issue.assigned_to_id
      assert_equal 2, @issue.journals.size
      assert_equal 2, @issue.lock_count
    end
    assert_same previous, User.current
  end

  def test_unassignment_and_unchanged_values_are_supported
    with_edits do
      assert_equal({}, COMMANDS.interaction('ATEST', 'TTEST', submission('status', '2')))
      assert_empty @issue.journals
      assert_equal({}, COMMANDS.interaction('ATEST', 'TTEST', submission('assign', 'none')))
      assert_nil @issue.assigned_to_id
      assert_equal [[3, '']], @issue.journals
    end
  end

  def test_forged_values_and_changed_workflow_or_assignable_users_are_rejected
    with_edits do
      [['status', '999'], ['assign', '999'], ['status', 'none'], ['assign', '4 extra'], ['status', nil]].each do |kind, value|
        key = kind == 'assign' ? 'assignee' : 'status'
        result = COMMANDS.interaction('ATEST', 'TTEST', submission(kind, value))
        assert_equal 'errors', result['response_action']
        assert result['errors'].key?(key)
      end
      @issue.statuses = [OpenStruct.new(id: 2, name: 'Open')]
      assert_equal 'errors', COMMANDS.interaction('ATEST', 'TTEST', submission('status', '5'))['response_action']
      @issue.assignees = [@viewer]
      assert_equal 'errors', COMMANDS.interaction('ATEST', 'TTEST', submission('assign', '4'))['response_action']
    end
    assert_empty @issue.journals
  end

  def test_submission_rechecks_permissions_integration_and_identity
    [-> { @issue.can_edit = false }, -> { @authorized = false },
     -> { @settings['slack']['work_object_actions'] = false }, -> { @issue[:is_private?] = true }].each do |change|
      setup
      change.call
      with_edits do
        assert_equal 'errors', COMMANDS.interaction('ATEST', 'TTEST', submission('status', '5'))['response_action']
      end
      assert_empty @issue.journals
    end
    with_edits(viewer: nil) do
      result = COMMANDS.interaction('ATEST', 'TTEST', submission('assign', '4'))
      assert_equal 'errors', result['response_action']
      assert result['errors'].key?('assignee')
    end
  end

  def test_retried_attribute_submission_does_not_repeat_the_write
    with_edits do
      2.times { assert_equal({}, COMMANDS.interaction('ATEST', 'TTEST', submission('status', '5'))) }
    end
    assert_equal 1, @issue.journals.size
    assert_equal 1, @issue.lock_count
  end

  def test_corrected_attribute_submission_can_retry_after_validation_failure
    with_edits do
      assert_equal 'errors', COMMANDS.interaction('ATEST', 'TTEST', submission('status', '999'))['response_action']
      assert_equal({}, COMMANDS.interaction('ATEST', 'TTEST', submission('status', '5')))
      assert_equal 5, @issue.status_id
      assert_equal 1, @issue.journals.size
    end
  end

  def test_help_and_button_labels_are_configurable
    with_edits do
      assert_includes COMMANDS.message('help'), '/slackmine status 123'
      assert_includes COMMANDS.message('help'), '/slackmine assign 123'
      @settings['messages'] = { 'commands' => { 'status' => 'Change workflow status', 'assign' => 'Pick assignee' } }
      assert_equal 'Change workflow status', COMMANDS.run('ATEST', 'TTEST', 'U123', 'C123', 'status 7').last.dig('elements', 0, 'text', 'text')
      assert_equal 'Pick assignee', COMMANDS.modal('assign', '7', @viewer).dig('title', 'text')
    end
  end

  def deliver_direct(text, request_key: Digest::SHA256.hexdigest(text))
    COMMANDS.deliver('ATEST', 'TTEST', { 'text' => text, 'user_id' => 'U123',
      'channel_id' => 'C123', 'request_key' => request_key })
    @calls.last[1]
  end

  def test_direct_status_name_including_japanese_updates_and_replies_privately
    @issue.statuses.last.name = 'Closed'
    previous = User.current
    with_edits do
      result = deliver_direct('status #7 Closed')
      assert_equal 5, @issue.status_id
      assert_equal 1, @issue.journals.size
      assert_equal 'chat.postEphemeral', @calls.last[0]
      assert_equal 'U123', result['user']
      assert_includes result.to_json, 'Issue updated.'
      assert_includes result.to_json, 'Closed'
      refute_includes result.to_json, 'views.open'
    end
    assert_same previous, User.current
  end

  def test_direct_status_supports_ids_and_exact_names_containing_spaces
    with_edits do
      @issue.statuses.last.name = 'Ready for review'
      deliver_direct('status 7 ready for review')
      assert_equal 5, @issue.status_id
      deliver_direct('status 7 2')
      assert_equal 2, @issue.status_id
      assert_equal 2, @issue.journals.size
    end
  end

  def test_direct_update_returns_latest_work_object_card_with_existing_fields_and_buttons
    @settings['slack']['work_object_previews'] = true
    @settings['slack']['work_object_fields'] = { 'status' => true, 'assignee' => true, 'due_date' => true }
    @settings['slack']['work_object_buttons'] = { 'edit_issue' => true }
    @issue.due_date = Date.new(2026, 10, 10)
    reloads = 0
    @issue.define_singleton_method(:reload) { reloads += 1; self }
    with_edits do
      result = deliver_direct('status 7 Done')
      entity = result.dig('metadata', 'entities', 0)
      assert_equal 'slack#/entities/task', entity['entity_type']
      assert_equal 'Done', entity.dig('entity_payload', 'fields', 'status', 'value')
      assert_equal @viewer.name, entity.dig('entity_payload', 'fields', 'assignee', 'user', 'text')
      assert_equal '2026-10-10', entity.dig('entity_payload', 'fields', 'due_date', 'value')
      assert_equal 'slackmine_edit_issue', entity.dig('entity_payload', 'actions', 'primary_actions', 0, 'action_id')
      assert_equal 'slackmine_issue:7', entity.dig('entity_payload', 'actions', 'primary_actions', 0, 'value')
      assert_includes result['text'], 'Issue updated.'
      refute result.key?('blocks')
      assert_equal 1, reloads
      assert_equal result, deliver_direct('status 7 Done')
      assert_equal 1, reloads
      result = deliver_direct('assign 7 4')
      assert_equal 'Another User', result.dig('metadata', 'entities', 0, 'entity_payload', 'fields', 'assignee', 'user', 'text')
      result = deliver_direct('assign 7 Another User')
      assert_includes result['text'], 'already has that value'
      assert result.key?('metadata')
    end
  end

  def test_direct_assignee_accepts_login_name_id_me_and_unassignment
    @issue.assignees.last[:login] = 'example-two'
    with_edits do
      deliver_direct('assign 7 EXAMPLE-TWO')
      assert_equal 4, @issue.assigned_to_id
      deliver_direct('assign 7 me')
      assert_equal 3, @issue.assigned_to_id
      deliver_direct('assign 7 Another User')
      assert_equal 4, @issue.assigned_to_id
      deliver_direct('assign 7 3')
      assert_equal 3, @issue.assigned_to_id
      deliver_direct('assign 7 Unassigned')
      assert_nil @issue.assigned_to_id
      result = deliver_direct('assign 7 none')
      assert_nil @issue.assigned_to_id
      assert_includes result.to_json, 'already has that value'
      assert_equal 5, @issue.journals.size
    end
  end

  def test_unknown_and_ambiguous_names_do_not_write_and_offer_a_picker
    with_edits do
      result = deliver_direct('status 7 Missing')
      assert_includes result.to_json, 'No unique permitted match'
      assert_equal 'status 7', result.dig('blocks', -1, 'elements', 0, 'value')
      @issue.statuses << OpenStruct.new(id: 9, name: 'Done')
      assert_includes deliver_direct('status 7 Done').to_json, 'No unique permitted match'
      @issue.assignees << OpenStruct.new(id: 9, name: 'Another User')
      assert_includes deliver_direct('assign 7 Another User').to_json, 'No unique permitted match'
    end
    assert_empty @issue.journals
  end

  def test_direct_write_rechecks_workflow_and_permissions_inside_the_lock
    @issue.define_singleton_method(:with_lock) do |&block|
      self.lock_count += 1
      self.statuses = [OpenStruct.new(id: 2, name: 'Open')]
      block.call
    end
    with_edits do
      assert_includes deliver_direct('status 7 Done').to_json, 'Not available'
      @issue.define_singleton_method(:with_lock) do |&block|
        self.lock_count += 1
        self.can_edit = false
        block.call
      end
      assert_includes deliver_direct('assign 7 4').to_json, 'Not available'
    end
    assert_empty @issue.journals
  end

  def test_duplicate_direct_delivery_cannot_reapply_a_change_after_a_later_edit
    with_edits do
      first = deliver_direct('status 7 Done')
      @issue.status_id = 2 # A subsequent independent Redmine edit.
      assert_equal first, deliver_direct('status 7 Done')
      assert_equal 2, @issue.status_id
      assert_equal 1, @issue.journals.size
      assert_equal 1, @issue.lock_count
    end
  end

  def test_slack_delivery_retry_reuses_saved_result_without_another_write
    with_edits do
      @delivery_failure = true
      assert_raises(RuntimeError) { deliver_direct('status 7 Done') }
      @delivery_failure = false
      @issue.status_id = 2
      assert_includes deliver_direct('status 7 Done').to_json, 'Issue updated.'
      assert_equal 2, @issue.status_id
      assert_equal 1, @issue.journals.size
    end
  end

  def test_uncertain_direct_write_is_not_retried_immediately
    with_edits do
      WORK.stub(:update_issue, ->(*) { raise 'Uncertain save outcome' }) do
        assert_raises(RuntimeError) { deliver_direct('status 7 Done') }
      end
      WORK.stub(:update_issue, ->(*) { flunk 'Repeated an uncertain write' }) do
        assert_includes deliver_direct('status 7 Done').to_json, 'still processing'
      end
    end
  end

  def test_direct_denial_missing_retry_key_and_identity_never_write
    with_edits do
      assert_includes deliver_direct('status 7 Done', request_key: nil).to_json, 'Not available'
      @issue[:is_private?] = true
      assert_includes deliver_direct('status 7 Done').to_json, 'Not available'
      @issue[:is_private?] = false
      @authorized = false
      assert_includes deliver_direct('assign 7 4').to_json, 'Not available'
    end
    with_edits(viewer: nil) do
      assert_includes deliver_direct('status 7 Done').to_json, 'Not available'
    end
    assert_empty @issue.journals
  end

  def test_denied_direct_request_can_retry_after_permissions_or_choices_change
    with_edits do
      assert_includes deliver_direct('status 7 Ready').to_json, 'No unique permitted match'
      @issue.statuses.last.name = 'Ready'
      assert_includes deliver_direct('status 7 Ready').to_json, 'Issue updated.'
      assert_equal 5, @issue.status_id
      assert_equal 1, @issue.journals.size
    end
  end
end
