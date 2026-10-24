# frozen_string_literal: true

require_relative 'image_notification_test'

class AdminOverviewTest < Minitest::Test
  OVERVIEW = Slackmine::AdminOverview

  def test_event_colors_include_effective_fallback_and_project_overrides
    project = OpenStruct.new(identifier: 'example')
    config = {'slack' => {'attachment_color' => '#123456'},
              'projects' => {'example' => {'messages' => {'colors' => {'issue' => {'created' => '#ABCDEF'}}}}}}
    Slackmine.stub(:config, config) do
      Slackmine.stub(:messages_config, {'messages' => {'colors' => {'issue' => {'deleted' => 'invalid'}}}}) do
        settings = OVERVIEW.settings(project)
        assert_equal '#ABCDEF', settings.dig('messages', 'colors', 'issue', 'created')
        assert_equal '#123456', settings.dig('messages', 'colors', 'issue', 'updated')
        assert_equal '#123456', settings.dig('messages', 'colors', 'issue', 'deleted')
        colors = OVERVIEW.comparison(settings).fetch('messages.colors')
        assert colors.find { |entry| entry[:key] == 'messages.colors.issue.created' }[:changed]
        refute colors.find { |entry| entry[:key] == 'messages.colors.issue.updated' }[:changed]
      end
    end
    refute OVERVIEW.color?('#fff; background: red')
  end

  def test_defaults_use_code_defaults_instead_of_example_values
    assert_equal false, OVERVIEW.default_value('slack.work_object_actions')
    assert_equal 0, OVERVIEW.default_value('slack.thread_comment_batch.wait_seconds')
    assert_equal false, OVERVIEW.default_value('events.wiki.deleted')
    assert_equal true, OVERVIEW.default_value('events.issue.created')
    assert_equal true, OVERVIEW.default_value('slack.metadata.issue.project')
    assert_equal false, OVERVIEW.default_value('slack.metadata.issue.assignee')
    assert_equal :conditional, OVERVIEW.default_value('slack.work_object_buttons.edit_issue')
    assert_equal :conditional, OVERVIEW.default_value('slack.metadata.issue.custom_fields.42')
    assert_equal 'My issues', OVERVIEW.default_value('messages.app_home.title')
  end

  def test_comparison_distinguishes_false_nil_and_redacted_credentials
    entries = OVERVIEW.comparison('slack' => { 'work_object_actions' => true, 'thread_comments' => false,
                                             'bot_token' => '[FILTERED]', 'default_channel_id' => '' })['slack']
    assert_equal [true, false, true, false], entries.map { |entry| entry[:changed] }
    assert_equal [false, false, nil, nil], entries.map { |entry| entry[:default] }
    refute OVERVIEW.comparison('slack' => {'custom_key' => 'custom'})['slack'].first[:changed]
  end

  def test_all_example_keys_and_default_message_keys_have_descriptions_in_both_languages
    config = YAML.safe_load(File.read(File.expand_path('../config/slackmine.yml.example', __dir__)))
    config.delete('projects')
    config['messages'] = Slackmine::Formatter::DEFAULT_MESSAGES
    %w[ja en].each do |locale|
      labels = YAML.safe_load(File.read(File.expand_path("../config/locales/slackmine_admin.#{locale}.yml", __dir__))).fetch(locale)
      translator = lambda do |key, **options|
        value = labels.dig(*key.split('.'))
        assert_kind_of String, value, "#{locale}: #{key}"
        options.empty? ? value : value % options
      end
      OVERVIEW.rows(config).each do |key, _|
        description = OVERVIEW.description(key, &translator)
        refute_equal labels.dig('slackmine_admin_help', 'unknown'), description, "#{locale}: #{key}"
        refute_empty description, "#{locale}: #{key}"
      end
    end
  end

  def test_conditional_defaults_follow_card_and_metadata_contexts
    %w[ja en].each do |locale|
      labels = YAML.safe_load(File.read(File.expand_path("../config/locales/slackmine_admin.#{locale}.yml", __dir__))).fetch(locale)
      translator = ->(key, **options) { labels.dig(*key.split('.')) % options }
      assert_includes OVERVIEW.conditional_default('slack.metadata.issue.created.project', &translator), 'true'
      assert_includes OVERVIEW.conditional_default('slack.metadata.issue.updated.project', &translator), 'false'
      assert_includes OVERVIEW.conditional_default('slack.metadata.issue.created.assignee', &translator), 'false'
      assert_includes OVERVIEW.conditional_default('due_reminders.colors.upcoming', &translator), 'slack.attachment_color'
      refute_empty OVERVIEW.description('slack.metadata.issue.created.custom_fields.42', &translator)
    end
  end

  def test_missing_configuration_detects_actual_files_not_examples
    require 'tmpdir'
    Dir.mktmpdir do |directory|
      config_path = File.join(directory, 'slackmine.yml')
      messages_path = File.join(directory, 'slackmine.messages.yml')
      File.write(config_path + '.example', '{}')
      Slackmine.stub(:config_paths, [config_path]) do
        Slackmine.stub(:messages_config_paths, [messages_path]) do
          assert_equal %w[slackmine.yml slackmine.messages.yml], OVERVIEW.missing_configuration
          File.write(config_path, '{}')
          File.write(messages_path, '{}')
          assert_empty OVERVIEW.missing_configuration
        end
      end
    end
  end

  def test_project_settings_merge_and_mask_credentials_without_mutating_configuration
    original = {
      'slack' => { 'bot_token' => 'shared-secret', 'events' => { 'signing_secret' => 'signing-secret' },
                   'work_object_actions' => true },
      'projects' => { 'example' => { 'slack' => { 'bot_token' => 'project-secret', 'work_object_actions' => false } } },
      'users' => { 'alice' => 'U123' }
    }
    project = OpenStruct.new(identifier: 'example')
    Slackmine.stub(:config, original) do
      Slackmine.stub(:messages_config, {}) do
        result = OVERVIEW.settings(project)
        assert_equal '[FILTERED]', result.dig('slack', 'bot_token')
        assert_equal '[FILTERED]', result.dig('slack', 'events', 'signing_secret')
        assert_equal false, result.dig('slack', 'work_object_actions')
        assert_equal 'U123', result.dig('users', 'alice')
        refute result.key?('projects')
        refute_match(/shared-secret|signing-secret|project-secret/, result.inspect)
      end
    end
    assert_equal 'project-secret', original.dig('projects', 'example', 'slack', 'bot_token')
    assert_equal true, original.dig('slack', 'work_object_actions')
  end

  def test_environment_token_is_reported_as_configured_without_exposure
    previous = ENV['SLACK_BOT_TOKEN']
    ENV['SLACK_BOT_TOKEN'] = 'environment-secret'
    Slackmine.stub(:config, {}) do
      Slackmine.stub(:messages_config, {}) do
        result = OVERVIEW.settings(nil)
        assert_equal '[FILTERED]', result.dig('slack', 'bot_token')
        refute_includes result.inspect, 'environment-secret'
      end
    end
  ensure
    ENV['SLACK_BOT_TOKEN'] = previous
  end

  def test_separate_message_file_and_project_overrides_take_precedence
    project = OpenStruct.new(identifier: 'example')
    legacy = { 'messages' => { 'app_home' => { 'title' => 'Legacy' } } }
    separate = { 'messages' => { 'app_home' => { 'title' => 'Global' } },
                 'projects' => { 'example' => { 'messages' => { 'app_home' => { 'title' => 'Project' } } } } }
    Slackmine.stub(:config, legacy) do
      Slackmine.stub(:messages_config, separate) do
        assert_equal 'Global', OVERVIEW.settings(nil).dig('messages', 'app_home', 'title')
        result = OVERVIEW.settings(project)
        assert_equal 'Project', result.dig('messages', 'app_home', 'title')
        assert_equal Slackmine::Formatter::DEFAULT_MESSAGES.dig('work_objects', 'product_name'), result.dig('messages', 'work_objects', 'product_name')
      end
    end
  end

  def test_nested_arrays_and_custom_credentials_are_masked
    result = OVERVIEW.redact('extras' => [{ 'API_KEY' => 'key', 'password' => 'password',
                                          'authorization' => 'bearer', 'id' => 'C123' }])
    assert_equal [{ 'API_KEY' => '[FILTERED]', 'password' => '[FILTERED]',
                    'authorization' => '[FILTERED]', 'id' => 'C123' }], result['extras']
  end

  def test_flattening_keeps_false_null_empty_maps_and_unicode_strings
    result = OVERVIEW.rows('slack' => { 'enabled' => false, 'empty' => {}, 'unset' => nil, 'name' => 'Notification' })
    assert_equal [['slack.enabled', false], ['slack.empty', {}], ['slack.unset', nil], ['slack.name', 'Notification']], result
    assert_equal 'null', OVERVIEW.display(nil)
    assert_equal 'false', OVERVIEW.display(false)
    assert_equal 'Notification', OVERVIEW.display('Notification')
  end
end
