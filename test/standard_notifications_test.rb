# frozen_string_literal: true
require_relative 'mail_preference_test'

class StandardNotificationsTest < Minitest::Test
  def setup
    @project = OpenStruct.new(id: 9, name: 'Example project', identifier: 'example', active?: true)
    @actor = OpenStruct.new(name: 'Example user')
    @deliveries = []
  end

  def test_every_operation_header_keeps_actor_when_metadata_is_hidden
    Slackmine.stub(:config, { 'slack' => { 'metadata' => false } }) do
      Slackmine.with_project(@project) do
        Slackmine::Formatter::EVENT_NOUN_KEYS.each do |noun, key|
          Slackmine::Formatter::DEFAULT_MESSAGES.fetch('events').fetch(key).each_key do |action|
            heading = Slackmine::Formatter.notification_heading(noun, action, @actor,
              project: @project, subject: 'Subject', id: 12)
            assert_includes heading, @actor.name, "#{noun} #{action}"
            assert_includes heading, Slackmine::Formatter.event_label(noun, action), "#{noun} #{action}"
          end
        end
      end
    end
  end

  def test_notification_header_variables_project_overrides_and_safe_fallback
    settings = { 'messages' => { 'work_objects' => { 'product_name' => 'Global' } },
      'projects' => { 'example' => { 'messages' => {
        'work_objects' => { 'product_name' => 'Example Tracker & Co' },
        'notification_headers' => { 'comment' => '%{actor} · %{project} · %{subject} · %{id} · %{product_name} · %{event} · %{noun} · %{action}' }
      } } } }
    actor = OpenStruct.new(name: 'A <B>')
    Slackmine.stub(:config, settings) do
      Slackmine.with_project(@project) do
        heading = Slackmine::Formatter.notification_heading('Comment', 'added', actor,
          project: @project, subject: 'A & B', id: 12)
        assert_equal 'A &lt;B&gt; · Example project · A &amp; B · 12 · Example Tracker &amp; Co · Comment added · Comment · added', heading
        settings['projects']['example']['messages']['notification_headers']['comment'] = '%{missing}'
        heading = Slackmine::Formatter.notification_heading('Comment', 'added', nil,
          project: @project, subject: 'Subject', id: 12)
        assert_includes heading, Slackmine::Formatter.message('values', 'unknown_user')
        refute_includes heading, '%{'
      end
    end
  end

  def test_product_name_expands_across_message_groups_without_consuming_other_variables
    settings = { 'projects' => { 'example' => { 'messages' => {
      'work_objects' => { 'product_name' => 'Example Tracker' }
    } } } }
    Slackmine.stub(:config, settings) do
      Slackmine.with_project(@project) do
        assert_equal 'Open the full form in Example Tracker', Slackmine::SlashCommands.message('full_form')
        assert_equal 'Open in Example Tracker', Slackmine::AppHome.message('open')
        assert_equal '✅ Comment added to Example Tracker #%{id}.', Slackmine::Formatter.message('thread_comments', 'saved')
        assert_equal 'Example Tracker', Slackmine::Formatter.message('work_objects', 'product_name')
      end
    end
  end

  def capture
    Slackmine.stub(:config, {}) do
      Slackmine.stub(:enqueue, ->(payload, **options) { @deliveries << [payload, options] }) { yield }
    end
  end

  def container(kind)
    klass = Class.new(OpenStruct)
    klass.define_singleton_method(:name) { kind }
    klass.new(id: 12, identifier: 'example', project: @project)
  end

  def file(parent)
    object = OpenStruct.new(id: 19, filename: 'example.pdf', author: @actor, container: parent, saved_change_to_container_id?: true, container_id_before_last_save: nil)
    object.extend(Slackmine::AttachmentPatch)
    object
  end

  def test_every_notification_event_has_a_working_yaml_switch_and_project_override
    example = YAML.safe_load(File.read(File.expand_path('../config/slackmine.yml.example', __dir__)))
    Slackmine::EVENT_PATHS.each do |event, path|
      assert_includes [true, false], example.fetch('events').dig(*path), event
      disabled = path.reverse.inject(false) { |value, key| { key => value } }
      enabled = path.reverse.inject(true) { |value, key| { key => value } }
      Slackmine.stub(:config, { 'events' => disabled }) do
        refute Slackmine.event_enabled?(@project, event), event
      end
      Slackmine.stub(:config, { 'events' => disabled, 'projects' => { 'example' => { 'events' => enabled } } }) do
        assert Slackmine.event_enabled?(@project, event), event
      end
    end
  end

  def test_all_formatter_nouns_have_customizable_labels_icons_and_example_metadata
    example = YAML.safe_load(File.read(File.expand_path('../config/slackmine.yml.example', __dir__)))
    message_example = YAML.safe_load(File.read(File.expand_path('../config/slackmine.messages.yml.example', __dir__)))
    Slackmine::Formatter::EVENT_NOUN_KEYS.each do |noun, key|
      next if key == 'comment' # Issue comments share Issue metadata.
      assert example.dig('slack', 'metadata', key).is_a?(Hash), key
      Slackmine::Formatter::DEFAULT_MESSAGES.fetch('events').fetch(key).each_key do |action|
        assert message_example.dig('messages', 'events', key, action), "#{key}.#{action} label"
        assert message_example.dig('messages', 'icons', key, action), "#{key}.#{action} icon"
        settings = { 'projects' => { 'example' => { 'messages' => {
          'events' => { key => { action => 'Custom event' } },
          'icons' => { key => { action => 'ICON' } }
        } } } }
        Slackmine.stub(:config, settings) do
          Slackmine.with_project(@project) do
            assert_equal 'Custom event', Slackmine::Formatter.event_label(noun, action)
            assert_equal 'ICON', Slackmine::Formatter.event_icon(action, noun: noun)
          end
        end
      end
    end
  end

  def test_default_messages_are_english_and_match_example_keys
    defaults = Slackmine::Formatter::DEFAULT_MESSAGES
    example = YAML.safe_load(File.read(File.expand_path('../config/slackmine.messages.yml.example', __dir__))).fetch('messages')
    japanese = YAML.safe_load(File.read(File.expand_path('../config/slackmine.messages.ja.yml.example', __dir__))).fetch('messages')
    operations = YAML.safe_load(File.read(File.expand_path('../config/slackmine.yml.example', __dir__)))
    refute operations.key?('messages')
    flatten = ->(entries, prefix = '') do
      entries.flat_map do |key, value|
        value.is_a?(Hash) ? flatten.call(value, "#{prefix}#{key}.").to_a : [["#{prefix}#{key}", value]]
      end.to_h
    end
    default_values = flatten.call(defaults)
    assert_equal default_values.keys.sort, flatten.call(example).keys.sort
    japanese_values = flatten.call(japanese)
    assert_equal default_values.keys.sort, japanese_values.keys.sort
    default_values.each do |key, value|
      assert_equal value.to_s.scan(/%\{[^}]+\}/).sort,
                   japanese_values.fetch(key).to_s.scan(/%\{[^}]+\}/).sort, key
    end
    assert_equal 'Redmine', japanese.dig('work_objects', 'product_name')
    assert_empty default_values.select { |_, value| value.to_s.match?(/[\u3041-\u3093\u30a1-\u30f6\u4e00-\u9fa0]/) }
  end

  def test_message_file_prefers_redmine_config_path
    require 'tmpdir'
    Dir.mktmpdir do |directory|
      redmine_path = File.join(directory, 'redmine.yml')
      plugin_path = File.join(directory, 'plugin.yml')
      File.write(redmine_path, YAML.dump('messages' => { 'app_home' => { 'title' => 'Redmine file' } }))
      File.write(plugin_path, YAML.dump('messages' => { 'app_home' => { 'title' => 'Plugin file' } }))
      previous = Slackmine.instance_variable_get(:@messages_config)
      Slackmine.instance_variable_set(:@messages_config, nil)
      Slackmine.stub(:messages_config_paths, [redmine_path, plugin_path]) do
        assert_equal 'Redmine file', Slackmine.messages_config.dig('messages', 'app_home', 'title')
      end
    ensure
      Slackmine.instance_variable_set(:@messages_config, previous)
    end
  end

  def test_unknown_event_and_relation_labels_use_configurable_yaml_templates
    formatter = Slackmine::Formatter
    Slackmine.stub(:config, {}) do
      assert_equal 'Novel archived', formatter.event_label('Novel', 'archived')
      assert_equal '🔧', formatter.event_icon('archived', noun: 'Novel')
      assert_equal 'unlisted', formatter.relation_type_label('unlisted')
    end
    settings = { 'messages' => { 'templates' => {
      'event_fallback' => '%{action}: %{noun}', 'relation_fallback' => 'Relation %{type}',
      'icon_fallback' => 'ICON'
    } } }
    Slackmine.stub(:config, settings) do
      assert_equal 'archived: Novel', formatter.event_label('Novel', 'archived')
      assert_equal 'ICON', formatter.event_icon('archived', noun: 'Novel')
      assert_equal 'Relation unlisted', formatter.relation_type_label('unlisted')
    end
  end

  def test_separate_message_settings_override_legacy_without_losing_project_priority
    legacy = { 'messages' => { 'app_home' => { 'title' => 'Legacy global' } },
      'projects' => { 'example' => { 'messages' => { 'app_home' => { 'title' => 'Legacy project' } } } } }
    separate = { 'messages' => { 'app_home' => { 'title' => 'New global', 'refresh' => 'Reload' } },
      'projects' => { 'example' => { 'messages' => { 'app_home' => { 'title' => 'New project' } } } } }
    Slackmine.stub(:config, legacy) do
      Slackmine.stub(:messages_config, separate) do
        assert_equal 'New global', Slackmine::Formatter.message('app_home', 'title', project: nil)
        assert_equal 'New project', Slackmine::Formatter.message('app_home', 'title', project: @project)
        assert_equal 'Reload', Slackmine::Formatter.message('app_home', 'refresh', project: @project)
      end
    end
  end

  def test_all_body_diff_types_are_documented_and_can_be_disabled_independently
    example = YAML.safe_load(File.read(File.expand_path('../config/slackmine.yml.example', __dir__)))
    Slackmine::BODY_DIFF_PATHS.each do |kind, path|
      assert_equal true, example.fetch('slack').fetch('body_diff').dig(*path), kind
      disabled = path.reverse.inject(false) { |value, key| { key => value } }
      Slackmine.stub(:config, { 'slack' => { 'body_diff' => disabled } }) do
        Slackmine::BODY_DIFF_PATHS.each_key do |other|
          assert_equal other != kind, Slackmine.body_diff_enabled?(other), "#{kind}/#{other}"
        end
      end
    end
  end

  def test_file_routes_and_mail_policy_agree
    %w[Project Version Document].each do |kind|
      parent = container(kind)
      # Project attachments belong directly to the project itself.
      expected_project = kind == 'Project' ? parent : @project
      capture { file(parent).send(:notify_slack_file_added) }
      _, options = @deliveries.last
      assert_equal expected_project, options[:project]
      assert_equal(kind == 'Document' ? 'document_file_added' : 'file_added', options[:event])
      project, events = Slackmine::MailPreference.notification(:attachments_added, [file(parent)], nil)
      assert_equal expected_project, project
      assert_equal [options[:event]], events
    end
  end

  def test_issue_and_message_attachments_do_not_send_duplicate_notifications
    %w[Issue Message].each do |kind|
      capture { file(container(kind)).send(:notify_slack_file_added) }
      assert_empty @deliveries
      assert_nil Slackmine::MailPreference.notification(:attachments_added, [file(container(kind))], nil)
    end
  end

  def test_file_deletion_links_to_container_and_uses_current_actor
    %w[Project Version Document].each do |kind|
      capture { file(container(kind)).send(:notify_slack_file_deleted) }
      payload, options = @deliveries.last
      assert_equal(kind == 'Document' ? 'document_file_deleted' : 'file_deleted', options[:event])
      assert_includes payload.to_s, kind == 'Document' ? '/documents/12' : '/projects/example/files'
      refute_includes payload.to_s, '/attachments/19'
    end
  end

  def test_issue_attachment_deletion_does_not_send_duplicate_file_notification
    capture { file(container('Issue')).send(:notify_slack_file_deleted) }
    assert_empty @deliveries
  end

  def test_file_deletion_switches_default_off_and_accept_project_override
    Slackmine.stub(:config, {}) { refute Slackmine.event_enabled?(@project, 'file_deleted') }
    settings = { 'projects' => { 'example' => { 'events' => { 'file' => { 'deleted' => true } } } } }
    Slackmine.stub(:config, settings) { assert Slackmine.event_enabled?(@project, 'file_deleted') }
    settings['messages'] = { 'events' => { 'file' => { 'deleted' => 'Removed file' } },
                             'icons' => { 'file' => { 'deleted' => 'REMOVE' } } }
    Slackmine.stub(:config, settings) do
      assert_equal 'Removed file', Slackmine::Formatter.event_label('File', 'deleted')
      assert_equal 'REMOVE', Slackmine::Formatter.event_icon('deleted', noun: 'File')
    end
  end

  def test_renaming_or_moving_an_existing_file_does_not_notify
    object = file(container('Project'))
    object[:saved_change_to_container_id?] = false
    capture { object.send(:notify_slack_file_added) }
    assert_empty @deliveries
    object[:saved_change_to_container_id?] = true
    object.container_id_before_last_save = 7
    capture { object.send(:notify_slack_file_added) }
    assert_empty @deliveries
  end

  def test_document_notification
    document = OpenStruct.new(id: 12, title: 'Example document', description: 'Document text', project: @project)
    document.extend(Slackmine::DocumentPatch)
    capture { document.send(:notify_slack_document_created) }
    payload, options = @deliveries.last
    assert_equal 'document_created', options[:event]
    assert_includes payload.to_s, '/documents/12'
  end

  def test_forum_topic_and_reply_notification
    [nil, 17].each do |parent_id|
      post = OpenStruct.new(id: 18, board_id: 2, parent_id: parent_id, subject: 'Example topic',
                            content: 'Message text', project: @project, author: @actor)
      post.extend(Slackmine::MessagePatch)
      capture { post.send(:notify_slack_message_posted) }
      payload, options = @deliveries.last
      assert_equal 'message_posted', options[:event]
      assert_includes payload.to_s, "/boards/2/topics/#{parent_id || 18}?r=18#message-18"
      assert_includes payload.to_s, 'Message text'
    end
  end

  def test_new_notification_labels_and_icons_use_yaml_and_project_overrides
    settings = {
      'messages' => {
        'events' => { 'document' => { 'created' => 'New document' }, 'file' => { 'added' => 'New file' },
                      'message' => { 'posted' => 'New forum post' } },
        'icons' => { 'document' => { 'created' => 'DOC' }, 'file' => { 'added' => 'FILE' },
                     'message' => { 'posted' => 'FORUM' } }
      },
      'projects' => { 'example' => { 'messages' => { 'events' => { 'message' => { 'posted' => 'Project forum post' } } } } }
    }
    Slackmine.stub(:config, settings) do
      [['Document', 'created', 'New document', 'DOC'], ['File', 'added', 'New file', 'FILE'],
       ['Message', 'posted', 'New forum post', 'FORUM']].each do |noun, action, label, icon|
        assert_equal label, Slackmine::Formatter.event_label(noun, action)
        assert_equal icon, Slackmine::Formatter.event_icon(action, noun: noun)
      end
      Slackmine.with_project(@project) do
        assert_equal 'Project forum post', Slackmine::Formatter.event_label('Message', 'posted')
      end
    end
  end

  def test_document_update_and_delete_with_content_change_guards
    document = OpenStruct.new(id: 12, title: 'Example', description: 'New text', project: @project,
                              previous_changes: { 'description' => ['Old text', 'New text'] })
    document.extend(Slackmine::DocumentPatch)
    capture { document.send(:notify_slack_document_updated) }
    assert_equal 'document_updated', @deliveries.last.last[:event]
    assert_includes @deliveries.last.first.to_s, 'Old text'
    document.previous_changes = { 'updated_on' => [1, 2] }
    capture { document.send(:notify_slack_document_updated) }
    assert_equal 1, @deliveries.size
    capture { document.send(:notify_slack_document_deleted) }
    assert_equal 'document_deleted', @deliveries.last.last[:event]
    assert_includes @deliveries.last.first.to_s, '/projects/example/documents'
  end

  def test_file_edit_notifies_and_internal_bookkeeping_does_not
    object = file(container('Document'))
    object.container_id = 12
    object[:saved_change_to_container_id?] = false
    object.previous_changes = { 'description' => ['Old', 'New'] }
    capture { object.send(:notify_slack_file_updated) }
    assert_equal 'document_file_updated', @deliveries.last.last[:event]
    assert_includes @deliveries.last.first.to_s, '/attachments/19'
    object.previous_changes = { 'downloads' => [1, 2] }
    capture { object.send(:notify_slack_file_updated) }
    assert_equal 1, @deliveries.size
  end

  def test_forum_update_delete_and_reply_counter_changes
    post = OpenStruct.new(id: 18, board_id: 2, parent_id: nil, subject: 'Example', content: 'New text',
                          project: @project, previous_changes: { 'content' => ['Old text', 'New text'] })
    post.extend(Slackmine::MessagePatch)
    capture { post.send(:notify_slack_message_updated) }
    assert_equal 'message_updated', @deliveries.last.last[:event]
    assert_includes @deliveries.last.first.to_s, 'Old text'
    post.previous_changes = { 'replies_count' => [0, 1] }
    capture { post.send(:notify_slack_message_updated) }
    assert_equal 1, @deliveries.size
    capture { post.send(:notify_slack_message_deleted) }
    assert_equal 'message_deleted', @deliveries.last.last[:event]
    assert_includes @deliveries.last.first.to_s, '/projects/example/boards/2'
  end

  def test_callbacks_are_registered_after_commit
    [Slackmine::DocumentPatch, Slackmine::AttachmentPatch, Slackmine::MessagePatch].each do |patch|
      base = Class.new
      callbacks = []
      base.define_singleton_method(:after_create_commit) { |method| callbacks << [:create, method] }
      base.define_singleton_method(:after_save_commit) { |method| callbacks << [:save, method] }
      base.define_singleton_method(:after_update_commit) { |method| callbacks << [:update, method] }
      base.define_singleton_method(:after_destroy_commit) { |method| callbacks << [:destroy, method] }
      base.include(patch)
      assert_equal 3, callbacks.length
      assert_equal(patch == Slackmine::AttachmentPatch ? :save : :create, callbacks.first.first)
    end
  end
end
