# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'
require 'date'
require 'rake'

class String
  def present?
    !strip.empty?
  end

  def presence
    present? ? self : nil
  end

  def truncate(length)
    self[0, length]
  end
end

class Array
  def present?
    !empty?
  end
end

class NilClass
  def presence
    nil
  end
end

module Rails
  def self.application
    @application ||= OpenStruct.new(config: OpenStruct.new(to_prepare: nil, after_initialize: nil))
  end

  def self.cache
    @cache
  end

  def self.logger
    @logger
  end
end

class Issue
  attr_reader :id
  attr_accessor :project

  def initialize(id, private_issue: false)
    @id = id
    @private_issue = private_issue
  end

  def is_private?
    @private_issue
  end

  def self.find_by(id:)
    nil
  end

  def self.joins(*)
    nil
  end
end

class IssuePriority
  def self.active
    [OpenStruct.new(id: 4, name: 'No Priority'), OpenStruct.new(id: 5, name: 'Important')]
  end
end

module ActiveRecord
  class RecordInvalid < StandardError; end
end

class CustomField
  def self.find_by(id:)
    OpenStruct.new(name: '顧客分類')
  end
end

class ApplicationController
  def self.helpers
    nil
  end
end

class Version
  def self.find_by(id:)
    OpenStruct.new(name: '旧版')
  end

  def self.named(_name)
    nil
  end
end

class PresenceValue < String
  def present?
    !empty?
  end

  def presence
    present? ? self : nil
  end
end

class ApplicationJob
  def self.around_perform(*)
  end
  def self.queue_as(*)
  end

  def self.perform_later(*)
  end

  def self.set(**)
    self
  end
end

class Project
  def self.find_by(id:)
    nil
  end

  def self.find(_value)
    nil
  end
end

class Tracker
  def self.exists?(id:)
    false
  end
end

require_relative '../app/jobs/slackmine_notification_job'
require_relative '../app/jobs/slackmine_work_object_refresh_job'

class User
  attr_accessor :login, :mail, :name

  def self.find_by(id:)
    nil
  end

  def self.exists?(id:)
    false
  end

  def blank?
    false
  end

  def self.current
    @current ||= OpenStruct.new(name: 'Alice')
  end

  def self.current=(user)
    @current = user
  end
end

class Journal
  def self.find_by(id:)
    nil
  end
end

class News < OpenStruct
end

require_relative '../lib/slackmine'
Slackmine.instance_variable_set(:@config, {})
Slackmine.instance_variable_set(:@messages_config, {})

class AutomaticUserMappingTest < Minitest::Test
  class MemoryCache
    def initialize
      @entries = {}
    end

    def fetch(key, expires_in:)
      @entries[key] ||= yield
    end
  end

  def test_disabled_mapping_does_not_fetch_users
    Slackmine.stub(:config, { 'slack' => { 'auto_map_users_by_name' => false } }) do
      Slackmine.stub(:slack_user_directory, -> { flunk 'users.list was called' }) do
        assert_nil Slackmine.slack_user_id_for_name('alice')
      end
    end
  end

  def test_matches_only_a_unique_name_without_case_sensitivity
    directory = { 'alice' => ['U123'], 'jun' => %w[U456 U789] }
    Slackmine.stub(:config, { 'slack' => { 'auto_map_users_by_name' => true } }) do
      Slackmine.stub(:slack_user_directory, directory) do
        assert_equal 'U123', Slackmine.slack_user_id_for_name(' Alice ')
        assert_nil Slackmine.slack_user_id_for_name('jun')
        assert_nil Slackmine.slack_user_id_for_name('missing')
      end
    end
  end

  def test_explicit_mapping_takes_precedence_over_automatic_lookup
    user = User.new
    user.login = 'alice'
    user.mail = 'alice@example.com'
    user.name = 'Alice'
    Slackmine.stub(:user_mapping, { 'alice' => PresenceValue.new('U123') }) do
      Slackmine.stub(:slack_user_id_for_name, ->(*) { flunk 'automatic lookup ran' }) do
        assert_equal '<@U123>', Slackmine::Formatter.user_mention(user)
      end
    end
  end

  def test_unmapped_user_uses_automatic_lookup
    user = User.new
    user.login = 'alice'
    user.mail = 'alice@example.com'
    user.name = 'Alice'
    Slackmine.stub(:user_mapping, {}) do
      Slackmine.stub(:slack_user_id_for_name, PresenceValue.new('U123')) do
        assert_equal '<@U123>', Slackmine::Formatter.user_mention(user)
      end
    end
  end

  def test_null_mappings_show_plain_name_with_automatic_name_matching_disabled
    user = User.new
    user.login = 'alice'
    user.mail = 'alice@example.com'
    user.name = 'Alice'
    settings = { 'users' => { 'alice' => nil, 'alice@example.com' => nil },
                 'slack' => { 'auto_map_users_by_name' => false,
                              'auto_map_users_by_email' => true, 'auto_map_channels_by_name' => true } }
    Slackmine.stub(:config, settings) do
      Slackmine.stub(:slack_user_directory, -> { flunk 'Null mapping performed automatic name lookup' }) do
        assert_equal 'Alice', Slackmine::Formatter.user_mention(user)
        settings['users']['alice@example.com'] = 'U123'
        assert_equal '<@U123>', Slackmine::Formatter.user_mention(user)
      end
    end
  end

  def test_user_directory_paginates_and_ignores_non_human_accounts
    calls = []
    responses = [
      { 'members' => [
          { 'id' => 'U123', 'name' => 'alice', 'profile' => { 'display_name' => 'Alice' } },
          { 'id' => 'B123', 'name' => 'bot', 'is_bot' => true },
          { 'id' => 'U456', 'name' => 'former', 'deleted' => true }
        ], 'response_metadata' => { 'next_cursor' => 'next' } },
      { 'members' => [
          { 'id' => 'U789', 'name' => 'jun', 'profile' => { 'display_name' => 'Alice' } },
          { 'id' => 'U999', 'name' => 'outsider', 'is_stranger' => true }
        ], 'response_metadata' => { 'next_cursor' => '' } }
    ]
    api = lambda do |method, params, token, **options|
      calls << [method, params, token, options]
      responses.shift
    end

    Slackmine.stub(:slack_api, api) do
      directory = Slackmine.fetch_slack_user_directory('token')
      assert_equal %w[U123 U789], directory['alice']
      assert_equal ['U789'], directory['jun']
      refute directory.key?('bot')
      refute directory.key?('former')
      refute directory.key?('outsider')
    end
    assert_equal [{ 'limit' => 200 }, { 'limit' => 200, 'cursor' => 'next' }], calls.map { |call| call[1] }
    assert calls.all? { |call| call[0] == 'users.list' && call[2] == 'token' && call[3][:form] }
  end

  def test_directory_is_cached_and_api_failure_falls_back_to_plain_name
    cache = MemoryCache.new
    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| warnings << message }
    attempts = 0
    api = lambda do |*|
      attempts += 1
      raise 'missing_scope'
    end

    Rails.stub(:cache, cache) do
      Rails.stub(:logger, logger) do
        Slackmine.stub(:bot_token, 'token') do
          Slackmine.stub(:slack_api, api) do
            assert_equal({}, Slackmine.slack_user_directory)
            assert_equal({}, Slackmine.slack_user_directory)
          end
        end
      end
    end
    assert_equal 1, attempts
    assert_equal 1, warnings.length
    assert_includes warnings.first, 'missing_scope'
  end
end

class NotificationAvatarTest < Minitest::Test
  def setup
    @actor = User.new
    @actor.login = 'kota'
    @actor.mail = 'kota@example.com'
    @actor.name = 'Kota'
    @actor.define_singleton_method(:id) { 7 }
    @project = OpenStruct.new(identifier: 'agentic', name: 'Agentic')
    @settings = { 'slack' => { 'bot_token' => 'token', 'default_channel_id' => 'C123' },
                  'users' => { 'kota' => 'U123' } }
    @cache = AutomaticUserMappingTest::MemoryCache.new
    @avatar = 'https://avatars.slack-edge.com/kota_48.jpg'
  end

  def card
    Slackmine::Formatter.payload('Kota updated', actor: @actor, blocks: [
      Slackmine::Formatter.section_text("🔄 Kota#{Slackmine::Formatter::AVATAR_MARKER} *Issue updated*"),
      Slackmine::Formatter.section_text('*Changes*\nOpen → Closed')
    ])
  end

  def deliver(source, api)
    result = nil
    Slackmine.stub(:config, @settings) do
      Rails.stub(:cache, @cache) do
        Rails.stub(:logger, OpenStruct.new) do
          User.stub(:find_by, ->(id:) { assert_equal 7, id; @actor }) do
            Slackmine.stub(:slack_api, api) do
              Slackmine.stub(:post_message, ->(payload, channel, token) {
                assert_equal 'C123', channel
                assert_equal @settings.dig('slack', 'bot_token'), token
                result = payload
              }) { Slackmine.notify(source, project: @project) }
            end
          end
        end
      end
    end
    result
  end

  def configured_card(template)
    @settings['messages'] = { 'notification_headers' => { 'issue' => template } }
    Slackmine.stub(:config, @settings) do
      Slackmine::Formatter.generic_payload(noun: 'Issue', action: 'updated', subject: 'Subject',
        url: 'https://redmine.example/issues/42', project: @project, actor: @actor)
    end
  end

  def test_yaml_avatar_placeholder_controls_inline_order_after_job_serialization
    {
      '%{icon}%{actor} %{avatar} *%{event}*' => ['🔄Kota', '<avatar>', '*Issue updated*'],
      '%{icon} %{avatar} %{actor} *%{event}*' => ['🔄', '<avatar>', 'Kota *Issue updated*'],
      '%{avatar} %{icon} %{actor} *%{event}*' => ['<avatar>', '🔄 Kota *Issue updated*'],
      '%{icon} %{actor} *%{event}* %{avatar}' => ['🔄 Kota *Issue updated*', '<avatar>'],
      '%{avatar}' => ['<avatar>']
    }.each do |template, expected|
      source = JSON.parse(JSON.generate(configured_card(template)))
      refute_includes JSON.generate(source['attachments']), 'slackmine_avatar'
      result = deliver(source, ->(*) { { 'user' => { 'profile' => { 'image_48' => @avatar } } } })
      heading = result.dig('attachments', 0, 'blocks', 0)
      assert_equal 'context', heading['type']
      assert_equal expected, heading['elements'].map { |item| item['type'] == 'image' ? '<avatar>' : item['text'] }
      assert_equal @avatar, heading['elements'].find { |item| item['type'] == 'image' }['image_url']
      refute heading.key?('accessory')
      refute result.key?('_slackmine_avatar_parts')
      refute_includes JSON.generate(result), 'slackmine_avatar'
    end
  end

  def test_yaml_avatar_placeholder_is_removed_when_image_or_actor_is_unavailable
    template = '%{icon} %{avatar} %{actor} *%{event}*'
    source = configured_card(template)
    result = deliver(source, ->(*) { raise IOError })
    assert_equal '🔄 Kota *Issue updated*', result.dig('attachments', 0, 'blocks', 0, 'text', 'text')
    refute result.key?('_slackmine_avatar_parts')
    refute_includes JSON.generate(result), 'slackmine_avatar'
    @actor = nil
    source = configured_card(template)
    refute source.key?('_slackmine_avatar_parts')
    refute_includes JSON.generate(source), 'slackmine_avatar'
  end

  def test_omitting_avatar_placeholder_keeps_section_and_does_not_load_a_profile
    source = configured_card('%{icon} %{actor} *%{event}*')
    result = deliver(source, ->(*) { flunk 'Avatar lookup for a template without avatar' })
    heading = result.dig('attachments', 0, 'blocks', 0)
    assert_equal 'section', heading['type']
    assert_equal '🔄 Kota *Issue updated*', heading.dig('text', 'text')
    assert_equal source['attachments'], result['attachments']
    refute heading.key?('elements')
    refute heading.key?('accessory')
    refute result.key?('_slackmine_actor_id')
    refute result.key?('_slackmine_avatar_parts')
  end

  def test_default_headers_do_not_enable_avatar_lookup
    Slackmine::Formatter::DEFAULT_MESSAGES.fetch('notification_headers').each_value do |template|
      refute_includes template, '%{avatar}'
    end
    source = Slackmine.stub(:config, @settings) do
      Slackmine::Formatter.generic_payload(noun: 'Issue', action: 'updated', subject: 'Subject',
        url: 'https://redmine.example/issues/42', project: @project, actor: @actor)
    end
    refute source.key?('_slackmine_avatar_parts')
    result = deliver(source, ->(*) { flunk 'Avatar lookup for a default header' })
    assert_equal 'section', result.dig('attachments', 0, 'blocks', 0, 'type')
    assert_equal '🔄 Kota *Issue updated*', result.dig('attachments', 0, 'blocks', 0, 'text', 'text')
  end

  def test_project_header_override_controls_inline_avatar_position
    @settings['projects'] = { 'agentic' => { 'messages' => {
      'notification_headers' => { 'issue' => '%{avatar} %{actor} %{event}' }
    } } }
    source = configured_card('%{icon} %{actor} %{event} %{avatar}')
    result = deliver(source, ->(*) { { 'user' => { 'profile' => { 'image_48' => @avatar } } } })
    assert_equal 'context', result.dig('attachments', 0, 'blocks', 0, 'type')
    assert_equal 'Kota Issue updated', result.dig('attachments', 0, 'blocks', 0, 'elements', 1, 'text')
    assert_equal @avatar, result.dig('attachments', 0, 'blocks', 0, 'elements', 0, 'image_url')
  end

  def test_avatar_is_added_at_delivery_and_queued_payload_remains_unchanged
    calls = 0
    api = ->(method, body, token, **options) {
      calls += 1
      assert_equal 'users.info', method
      assert_equal({ 'user' => 'U123' }, body)
      assert_equal 'token', token
      assert_equal({ form: true, open_timeout: 2, read_timeout: 3 }, options)
      { 'user' => { 'profile' => { 'image_48' => @avatar } } }
    }
    source = card
    original = Marshal.dump(source)
    2.times do
      result = deliver(source, api)
      heading = result.dig('attachments', 0, 'blocks', 0)
      assert_equal 'context', heading['type']
      assert_equal({ 'type' => 'mrkdwn', 'text' => '🔄 Kota' }, heading['elements'][0])
      assert_equal({ 'type' => 'image', 'image_url' => @avatar, 'alt_text' => 'Kota' }, heading['elements'][1])
      assert_equal({ 'type' => 'mrkdwn', 'text' => '*Issue updated*' }, heading['elements'][2])
      assert_equal source.dig('attachments', 0, 'blocks', 1), result.dig('attachments', 0, 'blocks', 1)
      refute result.key?('_slackmine_actor_id')
      assert_equal original, Marshal.dump(source)
    end
    assert_equal 1, calls
  end

  def test_custom_heading_formats_are_preserved_with_inline_avatar
    ['🔄 *Kota* %{avatar} updated', 'Updated by Kota %{avatar}', 'Kota %{avatar} updated', '🔄 %{avatar} Issue updated'].each do |template|
      source = configured_card(template)
      text = source.dig('attachments', 0, 'blocks', 0, 'text', 'text')
      result = deliver(source, ->(*) { { 'user' => { 'profile' => { 'image_48' => @avatar } } } })
      heading = result.dig('attachments', 0, 'blocks', 0)
      assert_equal 'context', heading['type']
      assert_equal text, heading['elements'].reject { |item| item['type'] == 'image' }.map { |item| item['text'] }.join(' ')
      assert_equal @avatar, heading['elements'].find { |item| item['type'] == 'image' }['image_url']
    end
  end

  def test_unmapped_or_deleted_redmine_actor_keeps_heading_without_api_call
    @settings['users'] = {}
    source = card
    result = deliver(source, ->(*) { flunk 'Unmapped user lookup' })
    assert_equal source['attachments'], result['attachments']
    @actor = nil
    result = deliver(source, ->(*) { flunk 'Deleted user lookup' })
    assert_equal source['attachments'], result['attachments']
    refute result.key?('_slackmine_actor_id')
  end

  def test_missing_invalid_or_unavailable_images_do_not_block_delivery
    [nil, 'http://example.com/avatar.jpg', 'not a URL', 'https://user:password@example.com/avatar.jpg'].each do |image|
      @cache = AutomaticUserMappingTest::MemoryCache.new
      source = card
      result = deliver(source, ->(*) { { 'user' => { 'profile' => { 'image_48' => image } } } })
      assert_equal source['attachments'], result['attachments']
    end
    [Slackmine::SlackApiError.new('users.info', 200, { 'error' => 'missing_scope' }),
     Timeout::Error.new, IOError.new].each do |error|
      @cache = AutomaticUserMappingTest::MemoryCache.new
      source = card
      result = deliver(source, ->(*) { raise error })
      assert_equal source['attachments'], result['attachments']
      refute result.key?('_slackmine_actor_id')
    end
  end

  def test_profile_cache_is_scoped_to_bot_token_and_project_user_mapping
    calls = []
    api = ->(method, body, token, **_options) {
      calls << [method, body, token]
      { 'user' => { 'profile' => { 'image_48' => @avatar } } }
    }
    deliver(card, api)
    @settings['slack']['bot_token'] = 'other-token'
    deliver(card, api)
    @settings['projects'] = { 'agentic' => { 'users' => { 'kota' => 'U456' } } }
    deliver(card, api)
    assert_equal ['token', 'other-token', 'other-token'], calls.map(&:last)
    assert_equal %w[U123 U123 U456], calls.map { |call| call[1]['user'] }
  end

  def test_compact_thread_comment_body_does_not_receive_an_actor_avatar
    @settings['slack']['comment_notifications_in_threads'] = true
    source = card.merge('_slackmine_comment_issue_id' => 42,
                        '_slackmine_thread_comment_payload' => {
                          'text' => 'Kota · Comment', 'attachments' => [{ 'blocks' => [
                            Slackmine::Formatter.section_text('Comment body')
                          ] }]
                        })
    Slackmine::CommentThreads.stub(:latest_thread, '1000.000001') do
      result = deliver(source, ->(*) { flunk 'Compact thread avatar lookup' })
      assert_equal 'Comment body', result.dig('attachments', 0, 'blocks', 0, 'text', 'text')
      assert_equal '1000.000001', result['thread_ts']
      refute result.key?('_slackmine_actor_id')
    end
  end

  def test_all_event_builders_queue_actor_id_without_loading_a_slack_profile
    issue = OpenStruct.new(id: 42, subject: 'Subject', description: '', project: @project,
                           tracker: OpenStruct.new(name: 'Task'))
    wiki = OpenStruct.new(page: OpenStruct.new(title: 'Page'), comments: '')
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    Slackmine.stub(:slack_api, ->(*) { flunk 'Profile lookup inside formatter' }) do
      Slackmine::Formatter.stub(:change_fields, empty_changes) do
        cards = [Slackmine::Formatter.issue_payload(issue, actor: @actor, action: 'updated'),
                 Slackmine::Formatter.journal_payload(issue, actor: @actor, notes: 'Comment'),
                 Slackmine::Formatter.wiki_payload(wiki, @project, actor: @actor, action: 'updated'),
                 Slackmine::Formatter.generic_payload(noun: 'News', action: 'created', subject: 'News',
                   url: 'https://redmine.example/news/1', project: @project, actor: @actor)]
        assert_equal [7, 7, 7, 7], cards.map { |payload| payload['_slackmine_actor_id'] }
      end
    end
  end
end

class ProjectConfigurationTest < Minitest::Test
  def project(identifier = 'agentic')
    OpenStruct.new(id: 7, identifier: identifier, name: identifier)
  end

  def settings
    {
      'slack' => {
        'bot_token' => 'global-token', 'default_channel_id' => 'C_GLOBAL',
        'attachment_color' => '#6D5DFB', 'auto_map_users_by_name' => false,
        'body_diff' => { 'issue' => { 'description' => true, 'comment' => true } },
        'metadata' => { 'issue' => { 'project' => true, 'tracker' => true } },
        'issue_changes_when_hidden' => true
      },
      'messages' => { 'events' => { 'issue' => { 'created' => 'Global issue created' } } },
      'users' => { 'alice' => 'U_GLOBAL', 'bob' => 'U_BOB' },
      'projects' => {
        'agentic' => {
          'slack' => {
            'bot_token' => 'project-token', 'default_channel_id' => 'C_PROJECT',
            'attachment_color' => '#123456', 'auto_map_users_by_name' => true,
            'body_diff' => { 'issue' => { 'comment' => false } },
            'metadata' => { 'issue' => { 'project' => false } },
            'issue_changes_when_hidden' => false
          },
          'messages' => {
            'events' => { 'issue' => { 'created' => 'Project issue created' } },
            'sections' => { 'comment' => 'Project comment' }
          },
          'users' => { 'alice' => 'U_PROJECT' }
        }
      }
    }
  end

  def test_project_overrides_all_config_sections_without_losing_global_siblings
    Slackmine.stub(:config, settings) do
      ENV.stub(:[], ->(key) { key == 'SLACK_BOT_TOKEN' ? 'environment-token' : nil }) do
        assert_equal 'project-token', Slackmine.bot_token(project)
        assert_equal 'environment-token', Slackmine.bot_token(project('other'))
      end
      assert_equal 'C_PROJECT', Slackmine.channel_id(project)
      assert_equal 'C_GLOBAL', Slackmine.channel_id(project('other'))

      Slackmine.with_project(project) do
        assert_equal 'Project issue created', Slackmine::Formatter.message('events', 'issue', 'created')
        assert_equal 'Issue updated', Slackmine::Formatter.message('events', 'issue', 'updated')
        assert_equal '#123456', Slackmine::Formatter.attachment_color
        assert Slackmine.body_diff_enabled?(:issue_description)
        refute Slackmine.body_diff_enabled?(:issue_comment)
        assert_equal false, Slackmine.effective_config.dig('slack', 'issue_changes_when_hidden')
        assert_equal({ 'alice' => 'U_PROJECT', 'bob' => 'U_BOB' }, Slackmine.user_mapping)
        user = User.new
        user.login = 'alice'
        user.mail = 'alice@example.com'
        user.name = 'Alice'
        assert_equal '<@U_PROJECT>', Slackmine::Formatter.user_mention(user)
        Slackmine.stub(:slack_user_directory, { 'charlie' => ['U_CHARLIE'] }) do
          assert_equal 'U_CHARLIE', Slackmine.slack_user_id_for_name('charlie')
        end
      end
      assert_equal 'Global issue created', Slackmine::Formatter.message('events', 'issue', 'created')
      assert_equal '#6D5DFB', Slackmine::Formatter.attachment_color
      assert Slackmine.body_diff_enabled?(:issue_comment)
      Slackmine.with_project(project('other')) do
        assert_nil Slackmine.slack_user_id_for_name('charlie')
      end
    end
  end

  def test_payload_and_delivery_use_the_same_project_overrides
    issue = OpenStruct.new(id: 42, subject: 'Example', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    other_issue = OpenStruct.new(id: 43, subject: 'Other', description: '', project: project('other'),
                                 tracker: OpenStruct.new(name: 'Task'))
    deliveries = []

    Slackmine.stub(:config, settings) do
      card = Slackmine::Formatter.issue_payload(issue, actor: nil, action: 'created')
      other_card = Slackmine::Formatter.issue_payload(other_issue, actor: nil, action: 'created')
      assert_equal '#123456', card.dig('attachments', 0, 'color')
      assert_includes card.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'Project issue created'
      fields = card.dig('attachments', 0, 'blocks').flat_map { |block| block.fetch('fields', []) }
      refute fields.any? { |field| field.fetch('text').start_with?('*Project*') }
      assert fields.any? { |field| field.fetch('text').start_with?('*Tracker*') }
      assert_equal '#6D5DFB', other_card.dig('attachments', 0, 'color')
      assert_includes other_card.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'Global issue created'

      ENV.stub(:[], ->(_key) { nil }) do
        Slackmine.stub(:post_message, ->(payload, channel, token) { deliveries << [payload, channel, token] }) do
          Slackmine.notify(card, project: project)
          Slackmine.notify(other_card, project: project('other'))
        end
      end
    end
    assert_equal ['C_PROJECT', 'project-token'], deliveries[0].last(2)
    assert_equal ['C_GLOBAL', 'global-token'], deliveries[1].last(2)
  end

  def test_nested_project_context_restores_previous_project_even_after_error
    Slackmine.stub(:config, settings) do
      Slackmine.with_project(project) do
        assert_raises(RuntimeError) do
          Slackmine.with_project(project('other')) { raise 'stop' }
        end
        assert_equal 'Project issue created', Slackmine::Formatter.message('events', 'issue', 'created')
      end
      assert_equal 'Global issue created', Slackmine::Formatter.message('events', 'issue', 'created')
    end
  end

  def test_news_comment_diff_heading_uses_project_message
    Slackmine.stub(:config, settings) do
      card = Slackmine::Formatter.generic_payload(
        noun: 'News comment', action: 'updated', subject: 'Title', url: 'https://example.com/news/1',
        project: project, actor: nil, body_diff: ['before', 'after'], body_diff_label: :comment
      )
      diff = card.dig('attachments', 0, 'blocks').find { |block| block['type'] == 'markdown' }
      assert_includes diff['text'], 'Project comment diff'

      other_card = Slackmine::Formatter.generic_payload(
        noun: 'News comment', action: 'updated', subject: 'Title', url: 'https://example.com/news/1',
        project: project('other'), actor: nil, body_diff: ['before', 'after'], body_diff_label: :comment
      )
      other_diff = other_card.dig('attachments', 0, 'blocks').find { |block| block['type'] == 'markdown' }
      assert_includes other_diff['text'], 'Comment diff'
    end
  end
end

class NotificationColorTest < Minitest::Test
  def test_notification_builders_select_the_same_event_as_the_icon
    colors = Slackmine::Formatter::DEFAULT_MESSAGES['icons'].transform_values do |actions|
      actions.transform_values { '#123456' }
    end
    colors['issue']['updated'] = '#654321'
    settings = { 'messages' => { 'colors' => colors } }
    project = OpenStruct.new(name: 'Example', identifier: 'example')
    issue = OpenStruct.new(id: 42, subject: 'Example', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    content = OpenStruct.new(page: OpenStruct.new(title: 'Example'), comments: '')
    Slackmine.stub(:effective_config, settings) do
      Slackmine::Formatter.stub(:metadata_fields, []) do
        Slackmine::Formatter.stub(:change_fields, []) do
          assert_equal '#123456', Slackmine::Formatter.build_issue_payload(issue, actor: nil, action: 'created').dig('attachments', 0, 'color')
          assert_equal '#123456', Slackmine::Formatter.build_journal_payload(issue, actor: nil, notes: '').dig('attachments', 0, 'color')
          combined = Slackmine::Formatter.build_journal_payload(issue, actor: nil, notes: '',
            details: [OpenStruct.new(property: 'attr', prop_key: 'subject')])
          assert_equal '#654321', combined.dig('attachments', 0, 'color')
          assert_equal '#123456', Slackmine::Formatter.build_wiki_payload(content, project, actor: nil, action: 'created').dig('attachments', 0, 'color')
          %w[Document File Message News].zip(%w[created added posted created]).each do |noun, action|
            card = Slackmine::Formatter.build_generic_payload(noun: noun, action: action, subject: 'Example',
              url: 'https://example.com/record', project: project, actor: nil)
            assert_equal '#123456', card.dig('attachments', 0, 'color'), noun
          end
        end
      end
    end
  end

  def test_every_icon_type_and_action_accepts_a_color_without_changing_blocks
    Slackmine::Formatter::DEFAULT_MESSAGES['icons'].each do |key, actions|
      noun = Slackmine::Formatter::EVENT_NOUN_KEYS.key(key)
      actions.each_key do |action|
        settings = { 'messages' => { 'colors' => { key => { action => '#123AbC' } } } }
        blocks = [Slackmine::Formatter.section_text('Event')]
        Slackmine.stub(:effective_config, settings) do
          card = Slackmine::Formatter.payload('Fallback', blocks: blocks, noun: noun, action: action)
          assert_equal '#123AbC', card.dig('attachments', 0, 'color'), "#{key}.#{action}"
          assert_equal blocks, card.dig('attachments', 0, 'blocks')
        end
      end
    end
  end

  def test_missing_invalid_and_malformed_event_colors_use_the_existing_default
    [nil, false, '#123', 'red', '', {}, 123].each do |color|
      settings = { 'slack' => { 'attachment_color' => '#654321' },
                   'messages' => { 'colors' => { 'comment' => { 'added' => color } } } }
      Slackmine.stub(:effective_config, settings) do
        assert_equal '#654321', Slackmine::Formatter.event_color('Comment', 'added')
        assert_equal '#654321', Slackmine::Formatter.event_color('Comment', 'deleted')
      end
    end
    [nil, false, 'invalid', { 'colors' => false }, { 'colors' => { 'comment' => false } }].each do |messages|
      Slackmine.stub(:effective_config, { 'messages' => messages }) do
        assert_equal '#6D5DFB', Slackmine::Formatter.event_color('Comment', 'added')
      end
    end
  end

  def test_project_event_color_overrides_do_not_leak_to_other_projects
    settings = {
      'messages' => { 'colors' => { 'comment' => { 'added' => '#111111', 'deleted' => '#222222' } } },
      'projects' => { 'example' => { 'messages' => { 'colors' => { 'comment' => { 'added' => '#333333' } } } } }
    }
    Slackmine.stub(:config, settings) do
      Slackmine.with_project(OpenStruct.new(identifier: 'example')) do
        assert_equal '#333333', Slackmine::Formatter.event_color('Comment', 'added')
        assert_equal '#222222', Slackmine::Formatter.event_color('Comment', 'deleted')
      end
      Slackmine.with_project(OpenStruct.new(identifier: 'other')) do
        assert_equal '#111111', Slackmine::Formatter.event_color('Comment', 'added')
      end
    end
  end
end

class EventConfigurationTest < Minitest::Test
  class TestJournal < Journal
    attr_accessor :journalized, :notes, :details, :user, :id, :updated_by, :previous_notes, :previous_private_notes

    def private_notes?
      false
    end

    def self.before_validation(*); end

    def self.after_create_commit(*)
    end

    def self.after_update_commit(*)
    end

    def saved_change_to_notes?
      previous_notes != notes
    end

    def notes_before_last_save
      previous_notes
    end

    def attribute_before_last_save(name)
      previous_private_notes if name == 'private_notes'
    end

    include Slackmine::JournalPatch
  end

  def project
    OpenStruct.new(id: 7, identifier: 'agentic')
  end

  def journal
    issue = Issue.new(7098)
    issue.project = project
    item = TestJournal.new
    item.journalized = issue
    item.notes = 'Comment ![](screenshot.png)'
    item.details = [:changed]
    item.user = OpenStruct.new(name: 'Alice')
    item.id = 12
    item
  end

  def test_events_default_to_enabled_and_project_overrides_global_setting
    settings = {
      'events' => { 'comment_added' => false, 'issue_updated' => true },
      'projects' => { 'agentic' => { 'events' => { 'comment_added' => true, 'issue_updated' => false } } }
    }
    Slackmine.stub(:config, settings) do
      assert Slackmine.event_enabled?(project, 'comment_added')
      refute Slackmine.event_enabled?(project, 'issue_updated')
      assert Slackmine.event_enabled?(project, 'wiki_created')
      refute Slackmine.event_enabled?(OpenStruct.new(identifier: 'other'), 'comment_added')
    end
  end

  def test_issue_updated_disables_relation_events_even_when_explicitly_enabled
    Slackmine.stub(:config, { 'events' => { 'issue_updated' => false } }) do
      refute Slackmine.event_enabled?(project, 'relation_added')
      refute Slackmine.event_enabled?(project, 'relation_removed')
    end
    Slackmine.stub(:config, { 'events' => { 'issue_updated' => false, 'relation_added' => true } }) do
      refute Slackmine.event_enabled?(project, 'relation_added')
    end
  end

  def test_example_yaml_lists_every_supported_event
    example = YAML.safe_load(File.read(File.expand_path('../config/slackmine.yml.example', __dir__)))
    events = example.fetch('events')
    assert_equal true, events.dig('issue', 'updated', 'enabled')
    assert_equal Slackmine::EVENT_KEYS.sort, Slackmine::EVENT_PATHS.keys.sort
    assert_equal Slackmine::EVENT_PATHS.length,
                 Slackmine::EVENT_PATHS.values.uniq.length
    Slackmine::EVENT_PATHS.each do |event, path|
      value = events.dig(*path)
      assert_includes [true, false], value, "Missing nested YAML setting for #{event}: #{path.join('.')}"
    end
    disabled = Slackmine::EVENT_PATHS.select { |_key, path| events.dig(*path) == false }.keys
    assert_equal Slackmine::DEFAULT_DISABLED_EVENTS.sort, disabled.sort
  end

  def test_nested_issue_parent_and_detail_switches
    settings = {
      'events' => {
        'issue' => {
          'updated' => { 'enabled' => false, 'status_changed' => true },
          'comment' => { 'added' => true, 'deleted' => true }
        }
      }
    }
    Slackmine.stub(:config, settings) do
      refute Slackmine.event_enabled?(project, 'status_changed')
      refute Slackmine.event_enabled?(project, 'issue_updated')
      assert Slackmine.event_enabled?(project, 'comment_added')
      assert Slackmine.event_enabled?(project, 'comment_deleted')
    end

    settings['events']['issue']['updated'] = { 'enabled' => true, 'status_changed' => false, 'other_changed' => false }
    Slackmine.stub(:config, settings) do
      refute Slackmine.event_enabled?(project, 'status_changed')
      refute Slackmine.event_enabled?(project, 'issue_updated')
      assert Slackmine.event_enabled?(project, 'assignee_changed')
    end
  end

  def test_nested_project_override_and_legacy_flat_fallback_for_all_event_families
    settings = {
      'events' => {
        'issue_updated' => false,
        'news_updated' => false,
        'wiki_deleted' => true,
        'time_entry' => { 'created' => false },
        'version' => { 'deleted' => true },
        'project' => { 'updated' => false }
      },
      'projects' => {
        'agentic' => { 'events' => {
          'issue' => { 'updated' => { 'enabled' => true, 'attachment' => { 'added' => false } } },
          'news' => { 'updated' => true, 'comment' => { 'added' => false } },
          'wiki' => { 'deleted' => false }
        } }
      }
    }
    Slackmine.stub(:config, settings) do
      assert Slackmine.event_enabled?(project, 'status_changed')
      refute Slackmine.event_enabled?(project, 'attachment_added')
      assert Slackmine.event_enabled?(project, 'news_updated')
      refute Slackmine.event_enabled?(project, 'news_comment_added')
      refute Slackmine.event_enabled?(project, 'wiki_deleted')
      refute Slackmine.event_enabled?(project, 'time_entry_created')
      assert Slackmine.event_enabled?(project, 'version_deleted')
      refute Slackmine.event_enabled?(project, 'project_updated')
    end
  end

  def test_news_comment_is_independent_of_news_update
    settings = { 'events' => { 'news' => { 'updated' => false, 'comment' => { 'added' => true, 'updated' => true } } } }
    Slackmine.stub(:config, settings) do
      refute Slackmine.event_enabled?(project, 'news_updated')
      assert Slackmine.event_enabled?(project, 'news_comment_added')
      assert Slackmine.event_enabled?(project, 'news_comment_updated')
    end
  end

  def test_comment_edit_and_removal_default_to_enabled
    Slackmine.stub(:config, {}) do
      %w[comment_updated comment_deleted news_comment_updated news_comment_deleted].each do |event|
        assert Slackmine.event_enabled?(project, event), event
      end
    end
  end

  def test_nested_setting_wins_over_flat_setting_in_the_same_scope
    settings = { 'events' => { 'status_changed' => false,
                                'issue' => { 'updated' => { 'enabled' => true, 'status_changed' => true } } } }
    Slackmine.stub(:config, settings) do
      assert Slackmine.event_enabled?(project, 'status_changed')
    end
  end

  def test_project_flat_setting_can_override_nested_global_leaf_and_parent
    settings = {
      'events' => { 'issue' => { 'updated' => { 'enabled' => false, 'status_changed' => false } } },
      'projects' => { 'agentic' => { 'events' => { 'issue_updated' => true, 'status_changed' => true } } }
    }
    Slackmine.stub(:config, settings) do
      assert Slackmine.event_enabled?(project, 'status_changed')
      refute Slackmine.event_enabled?(OpenStruct.new(identifier: 'other'), 'status_changed')
    end
  end

  def test_every_nested_event_leaf_can_disable_its_notification
    Slackmine::EVENT_PATHS.each do |event, path|
      events = { 'issue' => { 'updated' => { 'enabled' => true } } }
      target = events
      path[0...-1].each { |part| target = target[part] ||= {} }
      target[path.last] = false
      Slackmine.stub(:config, { 'events' => events }) do
        refute Slackmine.event_enabled?(project, event), path.join('.')
      end
    end
  end

  def test_every_nested_event_leaf_can_be_overridden_for_a_project
    Slackmine::EVENT_PATHS.each do |event, path|
      [[false, true], [true, false]].each do |global_value, project_value|
        global_events = {}
        project_events = {}
        [[global_events, global_value], [project_events, project_value]].each do |events, value|
          target = events
          path[0...-1].each { |part| target = target[part] ||= {} }
          target[path.last] = value
        end
        settings = { 'events' => global_events,
                     'projects' => { 'agentic' => { 'events' => project_events } } }
        Slackmine.stub(:config, settings) do
          assert_equal project_value, Slackmine.event_enabled?(project, event),
                       "Project override failed for #{path.join('.')}"
          assert_equal global_value,
                       Slackmine.event_enabled?(OpenStruct.new(identifier: 'other'), event),
                       "Global value changed for #{path.join('.')}"
        end
      end
    end
  end

  def test_project_can_override_issue_update_parent_and_detail_together
    settings = {
      'events' => { 'issue' => { 'updated' => { 'enabled' => false, 'status_changed' => false } } },
      'projects' => { 'agentic' => { 'events' => {
        'issue' => { 'updated' => { 'enabled' => true, 'status_changed' => true } }
      } } }
    }
    Slackmine.stub(:config, settings) do
      assert Slackmine.event_enabled?(project, 'status_changed')
      refute Slackmine.event_enabled?(OpenStruct.new(identifier: 'other'), 'status_changed')
    end
  end

  def test_all_flat_event_keys_remain_supported
    Slackmine::EVENT_KEYS.each do |event|
      Slackmine.stub(:config, { 'events' => { event => false } }) do
        refute Slackmine.event_enabled?(project, event), event
      end
    end
  end

  def test_new_deletion_events_default_to_disabled_and_can_be_overridden
    Slackmine.stub(:config, {}) do
      Slackmine::DEFAULT_DISABLED_EVENTS.each do |event|
        refute Slackmine.event_enabled?(project, event)
      end
    end
    Slackmine.stub(:config, { 'projects' => { 'agentic' => { 'events' => { 'wiki_deleted' => true } } } }) do
      assert Slackmine.event_enabled?(project, 'wiki_deleted')
    end
  end

  def test_issue_updated_is_the_parent_switch_for_every_issue_detail
    details = Slackmine::ISSUE_DETAIL_EVENTS.to_h { |event| [event, true] }
    Slackmine.stub(:config, { 'events' => details.merge('issue_updated' => false) }) do
      Slackmine::ISSUE_DETAIL_EVENTS.each do |event|
        refute Slackmine.event_enabled?(project, event), event
      end
    end
  end

  def test_project_can_enable_issue_updates_while_honoring_a_global_detail_switch
    settings = {
      'events' => { 'issue_updated' => false, 'assignee_changed' => false },
      'projects' => { 'agentic' => { 'events' => { 'issue_updated' => true, 'status_changed' => true } } }
    }
    Slackmine.stub(:config, settings) do
      assert Slackmine.event_enabled?(project, 'status_changed')
      refute Slackmine.event_enabled?(project, 'assignee_changed')
    end
  end

  def test_project_issue_update_parent_disables_global_detail
    settings = {
      'events' => { 'status_changed' => true },
      'projects' => { 'agentic' => { 'events' => { 'issue_updated' => false } } }
    }
    Slackmine.stub(:config, settings) do
      refute Slackmine.event_enabled?(project, 'status_changed')
    end
  end

  def test_each_journal_detail_maps_to_an_independent_event
    examples = {
      'attr' => {
        'status_id' => 'status_changed', 'assigned_to_id' => 'assignee_changed',
        'priority_id' => 'priority_changed', 'due_date' => 'due_date_changed',
        'start_date' => 'start_date_changed', 'fixed_version_id' => 'version_changed',
        'subject' => 'subject_changed', 'description' => 'description_changed',
        'parent_id' => 'parent_changed', 'category_id' => 'category_changed'
      },
      'cf' => { '42' => 'custom_field_changed' }
    }
    item = journal
    examples.each do |property, fields|
      fields.each do |key, event|
        assert_equal event, item.send(:slack_event_for_detail, OpenStruct.new(property: property, prop_key: key, value: 'new'))
      end
    end
    assert_equal 'attachment_added', item.send(:slack_event_for_detail, OpenStruct.new(property: 'attachment', value: 'new.png'))
    assert_equal 'attachment_removed', item.send(:slack_event_for_detail, OpenStruct.new(property: 'attachment', value: nil))
    assert_equal 'child_added', item.send(:slack_event_for_detail, OpenStruct.new(property: 'attr', prop_key: 'child_id', value: 7))
    assert_equal 'child_removed', item.send(:slack_event_for_detail, OpenStruct.new(property: 'attr', prop_key: 'child_id', value: nil))
  end

  def test_disabled_detail_does_not_hide_enabled_detail
    status = OpenStruct.new(property: 'attr', prop_key: 'status_id', value: 2)
    due_date = OpenStruct.new(property: 'attr', prop_key: 'due_date', value: '2026-10-01')
    assert_journal_notification(
      { 'status_changed' => false }, details: [status, due_date], notes: '',
      expected_payload: :update, expected_details: [due_date],
      expected_event: 'due_date_changed', expected_images: [], expected_journal_id: nil
    )
  end

  def test_nested_issue_settings_filter_one_journal_without_losing_enabled_content
    status = OpenStruct.new(property: 'attr', prop_key: 'status_id', value: 2)
    due_date = OpenStruct.new(property: 'attr', prop_key: 'due_date', value: '2026-10-01')
    assert_journal_notification(
      { 'issue' => { 'updated' => { 'enabled' => true, 'status_changed' => false, 'due_date_changed' => true },
                     'comment' => { 'added' => true } } },
      details: [status, due_date], expected_payload: :comment, expected_details: [due_date],
      expected_event: 'due_date_changed', expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_category_change_has_its_own_switch
    category = OpenStruct.new(property: 'attr', prop_key: 'category_id', value: 3)
    status = OpenStruct.new(property: 'attr', prop_key: 'status_id', value: 2)
    assert_journal_notification(
      { 'issue' => { 'updated' => { 'enabled' => true, 'other_changed' => true, 'category_changed' => false } } },
      details: [category, status], notes: '', expected_payload: :update, expected_details: [status],
      expected_event: 'status_changed', expected_images: [], expected_journal_id: nil
    )
    Slackmine.stub(:config, {
      'events' => { 'issue' => { 'updated' => { 'enabled' => true, 'other_changed' => false, 'category_changed' => true } } }
    }) do
      assert Slackmine.event_enabled?(project, 'category_changed')
      refute Slackmine.event_enabled?(project, 'issue_updated')
    end
  end

  def test_issue_comment_edit_and_removal_have_separate_events
    item = journal
    item.previous_notes = 'Previous public comment'
    item.updated_by = OpenStruct.new(name: 'Editor')
    calls = []
    formatter = ->(_issue, **kwargs) { calls << [:payload, kwargs]; :message }
    enqueue = ->(message, **kwargs) { calls << [:enqueue, message, kwargs] }

    Slackmine.stub(:config, {}) do
      Slackmine::Formatter.stub(:journal_payload, formatter) do
        Slackmine.stub(:enqueue, enqueue) do
          item.notes = 'Edited comment ![](screenshot.png)'
          item.send(:notify_slack_journal_comment_changed)
          item.notes = ''
          item.send(:notify_slack_journal_comment_changed)
        end
      end
    end

    assert_equal %w[updated deleted], calls.select { |call| call[0] == :payload }.map { |call| call[1][:comment_action] }
    assert_equal %w[comment_updated comment_deleted], calls.select { |call| call[0] == :enqueue }.map { |call| call[2][:event] }
    assert_equal 'Editor', calls[0][1][:actor].name
    assert_equal 'Previous public comment', calls[0][1][:previous_notes]
    assert_equal 'Previous public comment', calls[2][1][:previous_notes]
    assert_equal ['screenshot.png'], calls[1][2][:image_names]
    assert_equal 12, calls[1][2][:journal_id]
    assert_empty calls[3][2][:image_names]
    assert_nil calls[3][2][:journal_id]
  end

  def test_issue_comment_removal_respects_setting_and_privacy
    item = journal
    item.previous_notes = 'Previous public comment'
    item.notes = ''
    settings = { 'events' => { 'issue' => { 'comment' => { 'deleted' => false } } } }
    Slackmine.stub(:config, settings) do
      Slackmine.stub(:enqueue, ->(*) { flunk 'disabled removal was enqueued' }) do
        item.send(:notify_slack_journal_comment_changed)
      end
    end

    item.previous_private_notes = true
    Slackmine.stub(:enqueue, ->(*) { flunk 'private removal was enqueued' }) do
      item.send(:notify_slack_journal_comment_changed)
    end
  end

  def test_disabled_event_is_not_enqueued
    Slackmine.stub(:config, { 'events' => { 'issue_created' => false } }) do
      SlackmineNotificationJob.stub(:perform_later, ->(*) { flunk 'disabled event was enqueued' }) do
        Slackmine.enqueue({ 'text' => 'issue' }, project: project, event: 'issue_created')
      end
    end
  end

  def test_comment_only_event_omits_issue_changes
    assert_journal_notification(
      { 'issue_updated' => false },
      expected_payload: :comment, expected_details: [], expected_event: 'comment_added',
      expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_issue_update_only_event_omits_comment_and_image
    assert_journal_notification(
      { 'comment_added' => false },
      expected_payload: :update, expected_details: [:changed], expected_event: 'issue_updated',
      expected_images: [], expected_journal_id: nil
    )
  end

  def test_both_enabled_keep_combined_notification
    assert_journal_notification(
      {}, expected_payload: :comment, expected_details: [:changed],
      expected_event: 'issue_updated', expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_relation_addition_can_be_disabled_without_hiding_issue_changes
    relation = OpenStruct.new(property: 'relation', value: 7011)
    assert_journal_notification(
      { 'relation_added' => false }, details: [:changed, relation],
      expected_payload: :comment, expected_details: [:changed],
      expected_event: 'issue_updated', expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_relation_addition_is_blocked_by_issue_updated_but_comment_remains
    relation = OpenStruct.new(property: 'relation', value: 7011)
    assert_journal_notification(
      { 'issue_updated' => false, 'relation_added' => true }, details: [:changed, relation],
      expected_payload: :comment, expected_details: [],
      expected_event: 'comment_added', expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_relation_removal_can_be_disabled_independently
    relation = OpenStruct.new(property: 'relation', value: nil, old_value: 7011)
    assert_journal_notification(
      { 'relation_removed' => false }, details: [:changed, relation],
      expected_payload: :comment, expected_details: [:changed],
      expected_event: 'issue_updated', expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_relation_only_journal_uses_relation_event
    relation = OpenStruct.new(property: 'relation', value: nil, old_value: 7011)
    assert_journal_notification(
      { 'issue_updated' => true, 'relation_removed' => true }, details: [relation], notes: '',
      expected_payload: :update, expected_details: [relation],
      expected_event: 'relation_removed', expected_images: [], expected_journal_id: nil
    )
  end

  def test_relation_only_journal_is_suppressed_by_issue_updated
    item = journal
    item.notes = ''
    item.details = [OpenStruct.new(property: 'relation', value: 7011)]
    Slackmine.stub(:config, { 'events' => { 'issue_updated' => false, 'relation_added' => true } }) do
      Slackmine.stub(:enqueue, ->(*) { flunk 'disabled Issue update was enqueued' }) do
        item.send(:notify_slack_journal_created)
      end
    end
  end

  def test_disabled_relation_only_journal_sends_nothing
    item = journal
    item.notes = ''
    item.details = [OpenStruct.new(property: 'relation', value: 7011)]
    Slackmine.stub(:config, { 'events' => { 'relation_added' => false } }) do
      Slackmine.stub(:enqueue, ->(*) { flunk 'disabled relation was enqueued' }) do
        item.send(:notify_slack_journal_created)
      end
    end
  end

  def test_thread_routing_hint_is_only_added_to_comment_only_updates
    captured = []
    settings = { 'slack' => { 'comment_notifications_in_threads' => true } }
    Slackmine.stub(:config, settings) do
      Slackmine::Formatter.stub(:journal_payload, ->(*) { { 'text' => 'Comment' } }) do
        Slackmine.stub(:enqueue, ->(payload, **_options) { captured << payload }) do
          item = journal
          item.details = []
          item.send(:notify_slack_journal_created)
          item.details = [OpenStruct.new(property: 'attr', prop_key: 'status_id', value: 2)]
          item.send(:notify_slack_journal_created)
        end
      end
    end
    assert captured[0].key?('_slackmine_comment_issue_id')
    refute captured[1].key?('_slackmine_comment_issue_id')
  end

  def test_imported_thread_comment_notification_suppression_is_configurable
    previous = Thread.current[:slackmine_thread_comment]
    Thread.current[:slackmine_thread_comment] = true
    [nil, true, false].each do |value|
      captured = []
      settings = { 'slack' => {} }
      settings['slack']['suppress_thread_comment_notifications'] = value unless value.nil?
      Slackmine.stub(:config, settings) do
        Slackmine::Formatter.stub(:journal_payload, ->(*) { { 'text' => 'Comment' } }) do
          Slackmine.stub(:enqueue, ->(payload, **_options) { captured << payload }) do
            item = journal
            item.details = []
            item.send(:notify_slack_journal_created)
          end
        end
      end
      assert_equal(value == false ? 1 : 0, captured.size)
    end
    Slackmine.stub(:config, { 'slack' => { 'suppress_thread_comment_notifications' => false },
                             'events' => { 'comment_added' => false } }) do
      Slackmine.stub(:enqueue, ->(*) { flunk 'Disabled comment event was enqueued' }) do
        item = journal
        item.details = []
        item.send(:notify_slack_journal_created)
      end
    end
  ensure
    Thread.current[:slackmine_thread_comment] = previous
  end

  def test_both_disabled_send_nothing
    Slackmine.stub(:config, { 'events' => { 'comment_added' => false, 'issue_updated' => false } }) do
      Slackmine.stub(:enqueue, ->(*) { flunk 'disabled journal was enqueued' }) do
        journal.send(:notify_slack_journal_created)
      end
    end
  end

  private

  def assert_journal_notification(settings, expected_payload:, expected_details:, expected_event:, expected_images:, expected_journal_id:, details: [:changed], notes: 'Comment ![](screenshot.png)')
    calls = []
    comment_payload = ->(_issue, actor:, notes:, details:) { calls << [:comment, details, notes]; :comment }
    update_payload = ->(_issue, actor:, action:, details:) { calls << [:update, details, action]; :update }
    enqueue = ->(payload, **options) { calls << [:enqueue, payload, options] }
    Slackmine.stub(:config, { 'events' => settings }) do
      Slackmine::Formatter.stub(:journal_payload, comment_payload) do
        Slackmine::Formatter.stub(:issue_payload, update_payload) do
          Slackmine.stub(:enqueue, enqueue) do
            item = journal
            item.details = details
            item.notes = notes
            item.send(:notify_slack_journal_created)
          end
        end
      end
    end
    assert_equal expected_payload, calls[0][0]
    assert_equal expected_details, calls[0][1]
    assert_equal expected_payload, calls[1][1]
    assert_equal expected_event, calls[1][2][:event]
    assert_equal expected_images, calls[1][2][:image_names]
    if expected_journal_id.nil?
      assert_nil calls[1][2][:journal_id]
    else
      assert_equal expected_journal_id, calls[1][2][:journal_id]
    end
  end
end

class NewsCommentDeletionTest < Minitest::Test
  def test_news_comment_edit_sends_diff_using_its_own_event
    news = News.new(id: 17, title: 'Release', project: OpenStruct.new(id: 7, identifier: 'agentic'))
    comment = OpenStruct.new(commented: news, content: 'after')
    comment.define_singleton_method(:saved_change_to_content?) { true }
    comment.define_singleton_method(:content_before_last_save) { 'before' }
    comment.extend(Slackmine::CommentPatch)
    captured = []
    formatter = ->(**kwargs) { captured << [:payload, kwargs]; :message }
    enqueue = ->(message, **kwargs) { captured << [:enqueue, message, kwargs] }

    Slackmine::Formatter.stub(:generic_payload, formatter) do
      Slackmine.stub(:enqueue, enqueue) do
        comment.send(:notify_slack_news_comment_updated)
      end
    end

    assert_equal 'News comment', captured[0][1][:noun]
    assert_equal 'updated', captured[0][1][:action]
    assert_equal ['before', 'after'], captured[0][1][:body_diff]
    assert_equal :comment, captured[0][1][:body_diff_label]
    assert_equal :updated_comment, captured[0][1][:body_full_label]
    assert_equal 'news_comment_updated', captured[1][2][:event]
  end

  def test_news_comment_update_without_content_change_is_ignored
    comment = OpenStruct.new
    comment.define_singleton_method(:saved_change_to_content?) { false }
    comment.extend(Slackmine::CommentPatch)
    Slackmine.stub(:enqueue, ->(*) { flunk 'unchanged comment was enqueued' }) do
      comment.send(:notify_slack_news_comment_updated)
    end
  end

  def test_news_comment_removal_sends_removed_text_as_a_diff
    news = News.new(id: 17, title: 'Release', project: OpenStruct.new(id: 7, identifier: 'agentic'))
    comment = OpenStruct.new(commented: news, content: 'Removed comment')
    comment.extend(Slackmine::CommentPatch)
    captured = []
    formatter = ->(**kwargs) { captured << [:payload, kwargs]; :message }
    enqueue = ->(message, **kwargs) { captured << [:enqueue, message, kwargs] }

    Slackmine::Formatter.stub(:generic_payload, formatter) do
      Slackmine.stub(:enqueue, enqueue) do
        comment.send(:notify_slack_news_comment_deleted)
      end
    end

    assert_equal 'News comment', captured[0][1][:noun]
    assert_equal 'deleted', captured[0][1][:action]
    refute captured[0][1].key?(:notes)
    assert_equal ['Removed comment', ''], captured[0][1][:body_diff]
    assert_equal :comment, captured[0][1][:body_diff_label]
    assert_equal 'news_comment_deleted', captured[1][2][:event]
  end
end

class DeletionNotificationTest < Minitest::Test
  def project
    OpenStruct.new(id: 7, identifier: 'agentic', name: 'Agentic')
  end

  def test_deleted_records_have_independent_events_and_project_links
    cases = [
      [Slackmine::NewsPatch, 'news_deleted', { title: 'News', id: 1, description: 'Body' }, 'News', '/news'],
      [Slackmine::TimeEntryPatch, 'time_entry_deleted', { id: 2, hours: 1, spent_on: '2026-09-28', comments: '' }, 'Time entry', '/time_entries'],
      [Slackmine::VersionPatch, 'version_deleted', { id: 3, name: 'v1', status: 'open', effective_date: nil, description: '' }, 'Version', '/versions']
    ]
    cases.each do |patch, event, attributes, noun, path|
      record = OpenStruct.new(attributes.merge(project: project))
      record.extend(patch)
      assert_deleted_event(record, :notify_slack_generic, [noun, 'deleted'], event, path)
    end
    page = OpenStruct.new(project: project, title: 'Home')
    page.extend(Slackmine::WikiPagePatch)
    assert_deleted_event(page, :notify_slack_wiki_deleted, [], 'wiki_deleted', '/wiki')
  end

  private

  def assert_deleted_event(record, method, args, event, path)
    captured = []
    payload = ->(**kwargs) { captured << [:payload, kwargs]; :message }
    enqueue = ->(message, **kwargs) { captured << [:enqueue, message, kwargs] }
    Slackmine::Formatter.stub(:generic_payload, payload) do
      Slackmine.stub(:enqueue, enqueue) do
        record.send(method, *args)
      end
    end
    assert_equal 'deleted', captured[0][1][:action]
    assert_includes captured[0][1][:url], path
    assert_equal event, captured[1][2][:event]
    assert_equal :message, captured[1][1]
  end
end

module Setting
  def self.protocol
    'https'
  end

  def self.host_name
    'redmine.example.com'
  end
end

class ImageNotificationTest < Minitest::Test
  def test_restrict_transfer_inherits_global_setting_and_supports_project_overrides
    project = OpenStruct.new(identifier: 'example')
    [nil, false, true].each do |enabled|
      settings = { 'slack' => { 'files' => { 'restrict_transfer' => enabled } },
                   'projects' => { 'example' => { 'slack' => { 'files' => { 'restrict_transfer' => !enabled } } } } }
      Slackmine.stub(:config, settings) do
        assert_equal enabled == true, Slackmine.files_transfer_restricted?
        Slackmine.with_project(project) { assert_equal !enabled, Slackmine.files_transfer_restricted? }
        assert_equal !enabled, Slackmine.files_transfer_restricted?(project)
        assert_equal enabled == true, Slackmine.files_transfer_restricted?(OpenStruct.new(identifier: 'other'))
      end
    end
    Slackmine.stub(:config, {}) { refute Slackmine.files_transfer_restricted? }
  end

  def test_global_force_wins_over_global_and_project_transfer_settings
    project = OpenStruct.new(identifier: 'example')
    settings = { 'slack' => { 'files' => { 'restrict_transfer' => false, 'force_restrict_transfer' => true } },
                 'projects' => { 'example' => { 'slack' => { 'files' => {
                   'restrict_transfer' => false, 'force_restrict_transfer' => false } } } } }
    Slackmine.stub(:config, settings) do
      assert Slackmine.files_transfer_restricted?
      assert Slackmine.files_transfer_restricted?(project)
      Slackmine.with_project(project) { assert Slackmine.files_transfer_restricted? }
    end
  end

  def test_project_force_cannot_enable_global_enforcement
    settings = { 'slack' => { 'files' => { 'force_restrict_transfer' => false } },
                 'projects' => { 'example' => { 'slack' => { 'files' => {
                   'restrict_transfer' => false, 'force_restrict_transfer' => true } } } } }
    Slackmine.stub(:config, settings) do
      refute Slackmine.files_transfer_restricted?(OpenStruct.new(identifier: 'example'))
    end
  end

  def test_restrict_transfer_replaces_images_with_links_without_calling_upload
    attachment = OpenStruct.new(id: 42, filename: 'screenshot.png')
    messages = [
      { 'blocks' => [{ 'type' => 'markdown', 'text' => "Before\n\n![](screenshot.png)\n\nAfter" }] },
      { 'blocks' => [{ 'type' => 'section', 'text' => { 'type' => 'mrkdwn', 'text' => 'Before ![](screenshot.png) After' } }] }
    ]
    Slackmine.stub(:config, { 'slack' => { 'files' => { 'restrict_transfer' => true } } }) do
      Journal.stub(:find_by, journal(attachments: [attachment])) do
        Slackmine.stub(:upload_image, ->(*) { flunk 'Link-only uploaded a file' }) do
          messages.each do |message|
            Slackmine.add_images(message, [attachment.filename], 1, 'token')
            assert_equal 1, message['blocks'].size
            text = message['blocks'][0]['text']
            text = text['text'] if text.is_a?(Hash)
            assert_includes text, 'https://redmine.example.com/attachments/42'
            assert_includes text, 'screenshot.png'
            assert_includes text, 'Before'
            assert_includes text, 'After'
            refute_includes text, '![]('
          end
        end
      end
      Slackmine.stub(:slack_api, ->(*) { flunk 'Link-only called file API' }) do
        assert_nil Slackmine.upload_image(attachment, 'token')
      end
    end
  end

  def test_delivery_uses_project_file_policy_at_execution_time
    attachment = OpenStruct.new(id: 42, filename: 'clipboard-202609281254-s6trp@2x.png')
    project = OpenStruct.new(identifier: 'example')
    [[false, true, false, true], [true, false, false, false],
     [false, false, true, true], [true, false, true, true]].each do |global, override, force, restricted|
      settings = { 'slack' => { 'files' => { 'restrict_transfer' => global, 'force_restrict_transfer' => force } },
                   'projects' => { 'example' => { 'slack' => { 'files' => { 'restrict_transfer' => override } } } } }
      delivered = nil
      uploads = 0
      Slackmine.stub(:config, settings) do
        Slackmine.stub(:bot_token, 'test-token') do
          Slackmine.stub(:channel_id, 'C123') do
            Journal.stub(:find_by, journal(attachments: [attachment])) do
              Slackmine.stub(:upload_image, ->(*) { uploads += 1; 'F123' }) do
                Slackmine.stub(:post_message, ->(message, *) { delivered = message }) do
                  Slackmine.notify(payload, project: project, image_names: [attachment.filename], journal_id: 1)
                end
              end
            end
          end
        end
      end
      assert_equal restricted ? 0 : 1, uploads
      blocks = delivered.dig('attachments', 0, 'blocks')
      assert_equal !restricted, blocks.any? { |block| block['type'] == 'image' }
      assert_includes blocks.first.dig('text', 'text'), '/attachments/42' if restricted
    end
  end

  def payload
    { 'attachments' => [{ 'fallback' => 'Example Tracker notification', 'blocks' => [{ 'type' => 'section', 'text' => { 'type' => 'mrkdwn', 'text' => '*追加コメント*\n> ![](clipboard-202609281254-s6trp@2x.png)' } }] }] }
  end

  def test_restrict_transfer_disables_automatic_link_and_media_previews
    request = nil
    message = { 'text' => 'https://redmine.example.com/attachments/42',
                'unfurl_links' => true, 'unfurl_media' => true }
    Slackmine.stub(:config, { 'slack' => { 'files' => { 'restrict_transfer' => true } } }) do
      Slackmine.stub(:slack_api, ->(method, body, *) {
        assert_equal 'chat.postMessage', method
        request = body
        { 'ts' => '1791001000.000002' }
      }) { Slackmine.post_message(message, 'C123', 'token') }
    end
    assert_equal false, request['unfurl_links']
    assert_equal false, request['unfurl_media']
    assert_equal true, message['unfurl_links']
  end

  def journal(private_note: false, attachments: [])
    OpenStruct.new(journalized: Issue.new(7097), private_notes?: private_note, attachments: attachments)
  end

  def test_extracts_local_image_reference
    assert_equal ['clipboard-202609281254-s6trp@2x.png'],
                 Slackmine::Formatter.image_references('![](clipboard-202609281254-s6trp@2x.png)')
    assert_empty Slackmine::Formatter.image_references('![](https://example.com/image.png)')
    assert_equal '![English](english.png)', Slackmine::Formatter.mrkdwn('![English](english.png)')
  end

  def test_four_argument_job_keeps_non_image_notifications_compatible_with_old_workers
    project = OpenStruct.new(id: 6)
    queued = nil
    Slackmine.stub(:event_enabled?, true) do
      SlackmineNotificationJob.stub(:perform_later, ->(*args) { queued = args }) do
        Slackmine.enqueue({ 'text' => 'Issue deleted' }, project: project, event: 'issue_deleted')
      end
    end

    assert_equal [{ 'text' => 'Issue deleted' }, 6, [], nil], queued
  end

  def test_job_accepts_four_argument_issue_images_and_existing_five_argument_jobs
    project = OpenStruct.new(id: 6)
    calls = []
    Project.stub(:find_by, project) do
      Slackmine.stub(:notify, ->(payload, **options) { calls << [payload, options] }) do
        SlackmineNotificationJob.new.perform({ 'text' => 'created' }, 6, ['image.png'], -7105)
        SlackmineNotificationJob.new.perform({ 'text' => 'created' }, 6, ['image.png'], nil, 7105)
        SlackmineNotificationJob.new.perform({ 'text' => 'comment' }, 6, ['image.png'], 99)
      end
    end

    assert_equal 3, calls.length
    calls.first(2).each do |_payload, options|
      assert_equal 7105, options[:issue_id]
      assert_nil options[:journal_id]
    end
    assert_equal 99, calls.last[1][:journal_id]
    assert_nil calls.last[1][:issue_id]
  end

  def test_new_issue_embeds_its_attached_image_in_the_colored_notification
    name = 'F0C57KUNXCH-__________2026-09-29_12.01.19.png'
    issue = Issue.new(7105)
    issue.project = OpenStruct.new(id: 7)
    issue.define_singleton_method(:description) { "Report\n\n![Attached image](#{name})" }
    issue.define_singleton_method(:author) { OpenStruct.new(name: 'Example Bot') }
    issue.define_singleton_method(:attachments) { [OpenStruct.new(id: 88, filename: name)] }
    payload = Slackmine::Formatter.payload('Issue created', blocks: [
      Slackmine::Formatter.mrkdwn_sections('Content', issue.description).first
    ])
    queued = nil
    posted = nil

    Slackmine::Formatter.stub(:issue_payload, payload) do
      Slackmine.stub(:event_enabled?, true) do
        SlackmineNotificationJob.stub(:perform_later, ->(*args) { queued = args }) do
          issue.extend(Slackmine::IssuePatch)
          issue.send(:notify_slack_issue_created)
        end
      end
    end

    assert_equal [name], queued[2]
    assert_equal 4, queued.length
    assert_equal(-7105, queued[3])

    Issue.stub(:find_by, issue) do
      Slackmine.stub(:bot_token, 'token') do
        Slackmine.stub(:channel_id, 'C123') do
          Slackmine.stub(:upload_image, 'F123') do
            Slackmine.stub(:post_message, ->(message, _channel, _token) { posted = message }) do
              Slackmine.notify(queued[0], project: issue.project, image_names: queued[2],
                                              issue_id: -queued[3])
            end
          end
        end
      end
    end

    assert_equal '#6D5DFB', posted.dig('attachments', 0, 'color')
    blocks = posted.dig('attachments', 0, 'blocks')
    assert_equal ['section', 'image'], blocks.map { |block| block['type'] }
    assert_equal 'F123', blocks.last.dig('slack_file', 'id')
    refute_includes blocks.first.dig('text', 'text'), name
  end

  def test_ordered_lists_use_markdown_inside_the_colored_attachment
    notes = "1. first\n1. second\n1. third\n\n![](screenshot.png)\n\nDone"
    blocks = Slackmine::Formatter.mrkdwn_sections('追加コメント', notes)
    message = Slackmine::Formatter.payload('Example Tracker notification', blocks: blocks)

    assert_equal '#6D5DFB', message.dig('attachments', 0, 'color')
    assert_equal [{ 'type' => 'markdown', 'text' => "**追加コメント**\n\n#{notes}" }], message.dig('attachments', 0, 'blocks')
    assert_nil message['blocks']
  end

  def test_change_fields_are_split_to_fit_slack_section_limit
    changes = 12.times.map { |index| ["項目#{index}", '変更'] }
    blocks = Slackmine::Formatter.change_field_blocks(changes)
    assert_equal [10, 2], blocks.map { |block| block.fetch('fields').length }
    assert_includes blocks.last.fetch('fields').last.fetch('text'), '項目11'
  end

  def test_deleted_labels_are_distinct_from_updates
    assert_equal 'News created', Slackmine::Formatter.event_label('News', 'created')
    assert_equal 'Time entry created', Slackmine::Formatter.event_label('Time entry', 'created')
    assert_equal 'Version created', Slackmine::Formatter.event_label('Version', 'created')
    assert_equal 'News comment added', Slackmine::Formatter.event_label('News comment', 'added')
    assert_equal 'News deleted', Slackmine::Formatter.event_label('News', 'deleted')
    assert_equal '🗑️', Slackmine::Formatter.event_icon('deleted', noun: 'Wiki page')
  end

  def test_attachment_parent_version_and_custom_field_changes_have_readable_details
    value = ->(text) { PresenceValue.new(text) }
    details = [
      OpenStruct.new(property: 'attachment', prop_key: '1', old_value: value.call(''), value: value.call('one.png')),
      OpenStruct.new(property: 'attachment', prop_key: '2', old_value: value.call(''), value: value.call('two.png')),
      OpenStruct.new(property: 'attr', prop_key: 'parent_id', old_value: value.call(''), value: value.call('7011')),
      OpenStruct.new(property: 'attr', prop_key: 'fixed_version_id', old_value: value.call('1'), value: value.call('2')),
      OpenStruct.new(property: 'cf', prop_key: '42', old_value: value.call('A'), value: value.call('B'))
    ]
    issue = OpenStruct.new(fixed_version: OpenStruct.new(name: '新版'))
    changes = Slackmine::Formatter.change_fields(issue, details)
    assert_equal ['Attachment', 'Attachment', 'Parent issue', 'Target version', '顧客分類'], changes.map(&:first)
    assert_equal ['Added: one.png', 'Added: two.png'], changes.first(2).map(&:last)
    assert_equal 'None → <https://redmine.example.com/issues/7011|#7011>', changes[2][1]
    assert_equal '旧版 → 新版', changes[3][1]
    assert_equal 'A → B', changes[4][1]
  end

  def test_long_ordered_list_keeps_the_existing_section_format
    notes = "1. first\n" + ('x' * 12_000)
    assert_equal 'section', Slackmine::Formatter.mrkdwn_sections('追加コメント', notes).first['type']
  end

  def test_uploaded_image_stays_between_markdown_text_blocks
    name = 'screenshot.png'
    attachment = OpenStruct.new(id: 42, filename: name)
    notes = "1. first\n1. second\n\n![](#{name})\n\nDone"
    message = Slackmine::Formatter.payload('Example Tracker notification', blocks: Slackmine::Formatter.mrkdwn_sections('追加コメント', notes))
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      Slackmine.stub(:upload_image, 'F123') do
        Slackmine.add_images(message, [name], 1, 'token')
      end
    end

    assert_equal '#6D5DFB', message.dig('attachments', 0, 'color')
    assert_equal ['markdown', 'image', 'markdown'], message.dig('attachments', 0, 'blocks').map { |block| block['type'] }
    assert_equal "**追加コメント**\n\n1. first\n1. second", message.dig('attachments', 0, 'blocks', 0, 'text')
    assert_equal 'F123', message.dig('attachments', 0, 'blocks', 1, 'slack_file', 'id')
    assert_equal 'Done', message.dig('attachments', 0, 'blocks', 2, 'text')
  end

  def test_image_reference_inside_body_diff_remains_literal
    name = 'screenshot.png'
    attachment = OpenStruct.new(id: 42, filename: name)
    diff = Slackmine::Formatter.body_diff_blocks('説明', '', "![](#{name})").first
    comment_diff = Slackmine::Formatter.body_diff_blocks('コメント', '', "![](#{name})").first
    comment = Slackmine::Formatter.mrkdwn_sections('追加コメント', "1. See image\n![](#{name})").first
    message = Slackmine::Formatter.payload('Example Tracker notification', blocks: [diff, comment_diff, comment])

    Journal.stub(:find_by, journal(attachments: [attachment])) do
      Slackmine.stub(:upload_image, 'F123') do
        Slackmine.add_images(message, [name], 1, 'token')
      end
    end

    blocks = message.dig('attachments', 0, 'blocks')
    assert_includes blocks.first['text'], "![](#{name})"
    assert_includes blocks[1]['text'], "![](#{name})"
    assert_equal 1, blocks.count { |block| block['type'] == 'image' }
  end

  def test_edited_comment_embeds_image_with_full_text_or_diff
    name = 'screenshot.png'
    attachment = OpenStruct.new(id: 42, filename: name)
    issue = OpenStruct.new(id: 7098, subject: 'Title', project: OpenStruct.new(name: 'Agentic'),
                           tracker: OpenStruct.new(name: 'Task'))
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }

    [false, true].each do |show_diff|
      message = nil
      Slackmine.stub(:config, { 'slack' => { 'body_diff' => show_diff } }) do
        Slackmine::Formatter.stub(:change_fields, empty_changes) do
          message = Slackmine::Formatter.journal_payload(
            issue, actor: OpenStruct.new(name: 'Editor'),
            notes: "![](#{name})\ntest", previous_notes: "![](#{name})",
            comment_action: 'updated'
          )
        end
      end
      Journal.stub(:find_by, journal(attachments: [attachment])) do
        Slackmine.stub(:upload_image, 'F123') do
          Slackmine.add_images(message, [name], 1, 'token')
        end
      end

      blocks = message.dig('attachments', 0, 'blocks')
      assert_equal '#6D5DFB', message.dig('attachments', 0, 'color')
      assert_equal 1, blocks.count { |block| block['type'] == 'image' }
      assert_equal 'F123', blocks.find { |block| block['type'] == 'image' }.dig('slack_file', 'id')
      if show_diff
        assert_includes blocks.find { |block| block['type'] == 'markdown' }['text'], "![](#{name})"
      else
        refute blocks.any? { |block| block['type'] == 'markdown' }
      end
    end
  end

  def test_failed_markdown_image_upload_keeps_a_slackmine_link
    attachment = OpenStruct.new(id: 42, filename: 'screenshot.png')
    notes = "1. first\n\n![](screenshot.png)"
    message = Slackmine::Formatter.payload('Example Tracker notification', blocks: Slackmine::Formatter.mrkdwn_sections('追加コメント', notes))
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      Slackmine.stub(:upload_image, nil) do
        Slackmine.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_includes message.dig('attachments', 0, 'blocks', 0, 'text'), '[Image: screenshot.png](https://redmine.example.com/attachments/42)'
  end

  def test_embeds_uploaded_image_and_links_to_redmine
    attachment = OpenStruct.new(id: 42, filename: 'clipboard-202609281254-s6trp@2x.png')
    message = payload
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      Slackmine.stub(:upload_image, 'F123') do
        Slackmine.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_equal 'Example Tracker notification', message.dig('attachments', 0, 'fallback')
    blocks = message.dig('attachments', 0, 'blocks')
    assert_equal 2, blocks.length
    refute_includes blocks.first.dig('text', 'text'), 'Image:'
    refute_includes blocks.first.dig('text', 'text'), 'clipboard-202609281254-s6trp@2x.png'
    assert_equal({ 'id' => 'F123' }, blocks.last['slack_file'])
  end

  def test_failed_upload_keeps_attachment_link
    attachment = OpenStruct.new(id: 42, filename: 'clipboard-202609281254-s6trp@2x.png')
    message = payload
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      Slackmine.stub(:upload_image, nil) do
        Slackmine.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_equal 1, message.dig('attachments', 0, 'blocks').length
    assert_includes message.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'https://redmine.example.com/attachments/42'
  end

  def test_multiple_images_follow_their_markdown_positions
    names = %w[english.png japanese.png chinese.png]
    attachments = names.each_with_index.map { |name, index| OpenStruct.new(id: index + 1, filename: name) }
    message = {
      'attachments' => [{ 'fallback' => 'Example Tracker notification', 'blocks' => [
        { 'type' => 'section', 'text' => { 'type' => 'mrkdwn', 'text' => "*追加コメント*\nEN\n![English](english.png)\n\nJA\n![](japanese.png)\n\nZH\n![](chinese.png)" } },
        { 'type' => 'divider' }
      ] }]
    }
    file_ids = { 'english.png' => 'FEN', 'japanese.png' => 'FJA', 'chinese.png' => 'FZH' }
    Journal.stub(:find_by, journal(attachments: attachments)) do
      Slackmine.stub(:upload_image, ->(attachment, _token) { file_ids.fetch(attachment.filename) }) do
        Slackmine.add_images(message, names, 1, 'token')
      end
    end

    assert_equal [
      ['section', "*追加コメント*\nEN"],
      ['image', 'FEN'],
      ['section', 'JA'],
      ['image', 'FJA'],
      ['section', 'ZH'],
      ['image', 'FZH'],
      ['divider', nil]
    ], message.dig('attachments', 0, 'blocks').map { |block| [block['type'], block['type'] == 'image' ? block.dig('slack_file', 'id') : block.dig('text', 'text')] }
  end

  def test_missing_attachment_links_to_issue_without_upload
    message = payload
    Journal.stub(:find_by, journal) do
      Slackmine.stub(:upload_image, ->(*) { flunk 'missing image was uploaded' }) do
        Slackmine.add_images(message, ['clipboard-202609281254-s6trp@2x.png'], 1, 'token')
      end
    end

    assert_includes message.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'https://redmine.example.com/issues/7097'
  end

  def test_private_note_is_not_uploaded
    message = payload
    Journal.stub(:find_by, journal(private_note: true)) do
      Slackmine.stub(:upload_image, ->(*) { flunk 'private image was uploaded' }) do
        Slackmine.add_images(message, ['clipboard-202609281254-s6trp@2x.png'], 1, 'token')
      end
    end

    assert_equal payload, message
  end

  def test_upload_api_sends_filename_and_length_as_form_data
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, '{"ok":true}')
    captured_request = nil
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured_request = request
      response
    end

    Net::HTTP.stub(:start, ->(*, &block) { block.call(http) }) do
      Slackmine.slack_api(
        'files.getUploadURLExternal',
        { 'filename' => 'clipboard.png', 'length' => 42 },
        'token',
        form: true
      )
    end

    assert_equal 'application/x-www-form-urlencoded', captured_request.content_type
    assert_equal({ 'filename' => 'clipboard.png', 'length' => '42' }, URI.decode_www_form(captured_request.body).to_h)
  end

  def test_retries_image_processing_without_changing_file_id
    message = { 'blocks' => [{ 'type' => 'image', 'slack_file' => { 'id' => 'F123' }, 'alt_text' => 'image' }] }
    attempts = []
    delays = []
    error = Slackmine::SlackApiError.new(
      'chat.postMessage', '200',
      { 'error' => 'invalid_blocks', 'response_metadata' => { 'messages' => ['[ERROR] invalid file type'] } }
    )
    api = lambda do |_method, body, _token|
      attempts << body.dig('blocks', 0, 'slack_file', 'id')
      raise error if attempts.length < 3

      { 'ok' => true }
    end

    Slackmine.stub(:slack_api, api) do
      Slackmine.stub(:sleep, ->(seconds) { delays << seconds }) do
        assert_equal({ 'ok' => true }, Slackmine.post_message(message, 'C123', 'token'))
      end
    end

    assert_equal ['F123', 'F123', 'F123'], attempts
    assert_equal [1, 2], delays
  end

  def test_image_message_keeps_the_colored_card_after_file_sharing
    message = Slackmine::Formatter.payload('Example Tracker notification', blocks: [
      { 'type' => 'markdown', 'text' => "**追加コメント**\n\n1. first" },
      { 'type' => 'image', 'slack_file' => { 'id' => 'F123' }, 'alt_text' => 'screenshot' },
      { 'type' => 'markdown', 'text' => 'after image' }
    ])
    calls = []
    api = lambda do |method, body, _token|
      calls << [method, body]
      method == 'chat.postMessage' ? { 'ok' => true, 'ts' => '123.456' } : { 'ok' => true }
    end

    Slackmine.stub(:slack_api, api) do
      assert_equal({ 'ok' => true, 'ts' => '123.456' }, Slackmine.post_message(message, 'C123', 'token'))
    end

    assert_equal %w[chat.postMessage chat.update], calls.map(&:first)
    initial = calls[0][1]
    final = calls[1][1]
    assert_equal '#6D5DFB', initial.dig('attachments', 0, 'color')
    assert_equal 'Example Tracker notification', initial['text']
    assert_equal initial['text'], initial.dig('blocks', 0, 'text', 'text')
    assert_equal 'F123', initial.dig('blocks', 0, 'accessory', 'slack_file', 'id')
    assert_equal %w[markdown image markdown], initial.dig('attachments', 0, 'blocks').map { |block| block['type'] }
    assert_equal '123.456', final['ts']
    assert_equal '', final['text']
    assert_equal [], final['blocks']
    assert_equal initial['attachments'], final['attachments']
    assert_nil message['blocks']
  end

  def test_image_notification_preserves_explicit_text_and_limits_preview_text
    message = Slackmine::Formatter.payload('Attachment fallback', blocks: [
      { 'type' => 'image', 'slack_file' => { 'id' => 'F123' }, 'alt_text' => 'screenshot' }
    ])
    message['text'] = 'Notification summary ' * 200
    calls = []
    Slackmine.stub(:slack_api, ->(method, body, _token) { calls << [method, body]; { 'ok' => true, 'ts' => '1.2' } }) do
      Slackmine.post_message(message, 'C123', 'token')
    end
    assert_equal message['text'], calls.first[1]['text']
    assert_equal message['text'][0, 3000], calls.first[1].dig('blocks', 0, 'text', 'text')
  end

  def test_message_without_images_keeps_attachment_fallback_without_top_level_text
    message = Slackmine::Formatter.payload('Notification summary', blocks: [
      { 'type' => 'markdown', 'text' => 'Comment' }
    ])
    calls = []
    Slackmine.stub(:slack_api, ->(method, body, _token) { calls << [method, body]; { 'ok' => true } }) do
      Slackmine.post_message(message, 'C123', 'token')
    end
    assert_equal [['chat.postMessage', message.merge('channel' => 'C123')]], calls
    refute calls.first[1].key?('text')
  end

  def test_retries_attachment_until_new_image_is_ready
    message = Slackmine::Formatter.payload('Example Tracker notification', blocks: [
      { 'type' => 'image', 'slack_file' => { 'id' => 'F123' }, 'alt_text' => 'screenshot' }
    ])
    methods = []
    error = Slackmine::SlackApiError.new(
      'chat.postMessage', '200',
      { 'error' => 'invalid_attachments', 'response_metadata' => { 'messages' => ['[ERROR] invalid slack file'] } }
    )
    api = lambda do |method, _body, _token|
      methods << method
      raise error if methods.length == 1

      method == 'chat.postMessage' ? { 'ok' => true, 'ts' => '123.456' } : { 'ok' => true }
    end

    Slackmine.stub(:slack_api, api) do
      Slackmine.stub(:sleep, ->(*) {}) do
        Slackmine.post_message(message, 'C123', 'token')
      end
    end

    assert_equal %w[chat.postMessage chat.postMessage chat.update], methods
  end
end

class WorkObjectNotificationTest < Minitest::Test
  def setup
    @project = OpenStruct.new(identifier: 'agentic', name: 'Agentic')
    @actor = OpenStruct.new(name: 'Alice')
    @issue = OpenStruct.new(id: 7, subject: 'Fix A & B', description: 'Issue body', project: @project,
                            tracker: OpenStruct.new(name: 'Task'), status: OpenStruct.new(name: 'In progress'),
                            priority: OpenStruct.new(name: 'High'), assigned_to: OpenStruct.new(name: 'Alice'),
                            author: @actor, due_date: Date.new(2026, 10, 5), is_private?: false)
    @settings = { 'slack' => { 'work_object_previews' => true, 'work_object_fields' => { 'status' => true, 'assignee' => true, 'priority' => true, 'due_date' => true, 'author' => true, 'category' => true, 'done_ratio' => true }, 'metadata' => { 'issue' => {
      'status' => true, 'assignee' => true, 'due_date' => true, 'author' => true
    } } } }
  end

  def issue_payload(action = 'created')
    Slackmine::Formatter.issue_payload(@issue, actor: @actor, action: action)
  end

  def test_preview_is_opt_in_and_removes_duplicate_fields_only_when_enabled
    [nil, false, 'true'].each do |value|
      Slackmine.stub(:config, { 'slack' => { 'work_object_previews' => value } }) do
        refute issue_payload.key?('metadata')
        refute issue_payload.key?('text')
      end
    end
    original = Slackmine.stub(:config, @settings.merge('slack' => @settings['slack'].merge('work_object_previews' => false))) { issue_payload }
    enabled = Slackmine.stub(:config, @settings) { issue_payload }
    assert_equal original.dig('attachments', 0, 'fallback'), enabled.dig('attachments', 0, 'fallback')
    assert_equal '', enabled['text']
    refute_includes enabled['attachments'].to_json, '*Status*'
    refute_includes enabled['attachments'].to_json, '|#7 Fix A'
    assert_includes enabled['attachments'].to_json, 'Issue body'
  end

  def test_thread_parent_resolves_own_work_object_unfurl_without_subject
    parent = { 'ts' => '1000.000001', 'bot_id' => 'B123', 'app_id' => 'ATEST',
               'attachments' => [{ 'is_app_unfurl' => true, 'bot_id' => 'B123', 'app_id' => 'ATEST',
                                   'from_url' => 'https://redmine.example.com/issues/7',
                                   'title_link' => 'https://redmine.example.com/issues/7' }] }
    resolver = Slackmine::ThreadComments
    Issue.stub(:find_by, @issue) do
      assert_equal @issue, resolver.issue_from_parent(parent, 'ATEST', parent['ts'])
      assert_nil resolver.issue_from_parent(parent, 'AOTHER', parent['ts'])
      assert_nil resolver.issue_from_parent(parent, 'ATEST', '1000.999999')
      %w[app_id bot_id from_url title_link].each do |key|
        original = parent['attachments'][0][key]
        parent['attachments'][0][key] = 'invalid'
        assert_nil resolver.issue_from_parent(parent, 'ATEST', parent['ts'])
        parent['attachments'][0][key] = original
      end
      parent.delete('bot_id')
      assert_nil resolver.issue_from_parent(parent, 'ATEST', parent['ts'])
    end
  end

  def reduced_history_parent
    { 'ts' => '1000.000001', 'bot_id' => 'B123', 'app_id' => 'ATEST',
      'attachments' => [
        { 'blocks' => [{ 'type' => 'section', 'text' => { 'type' => 'mrkdwn', 'text' => 'Comment body' } }],
          'fallback' => '[Example] Example User Comment added Task #7: Example issue' },
        { 'from_url' => 'https://redmine.example.com/issues/7', 'id' => 2 }
      ] }
  end

  def test_thread_parent_resolves_reduced_history_card
    parent = reduced_history_parent
    Issue.stub(:find_by, ->(id:) { id == 7 ? @issue : nil }) do
      assert_equal @issue, Slackmine::ThreadComments.issue_from_parent(parent, 'ATEST', parent['ts'])
      parent.delete('app_id')
      parent['bot_profile'] = { 'app_id' => 'ATEST' }
      assert_equal @issue, Slackmine::ThreadComments.issue_from_parent(parent, 'ATEST', parent['ts'])
    end
  end

  def test_reduced_history_card_rejects_untrusted_parent_and_wrong_url
    resolver = Slackmine::ThreadComments
    parent = reduced_history_parent
    Issue.stub(:find_by, ->(**) { flunk 'Untrusted parent must not resolve an Issue' }) do
      assert_nil resolver.issue_from_parent(parent, 'AOTHER', parent['ts'])
      assert_nil resolver.issue_from_parent(parent, 'ATEST', '1001.000001')
      parent.delete('bot_id')
      assert_nil resolver.issue_from_parent(parent, 'ATEST', parent['ts'])
      parent = reduced_history_parent
      parent['attachments'][1]['from_url'] = 'https://other.example.com/issues/7'
      assert_nil resolver.issue_from_parent(parent, 'ATEST', parent['ts'])
    end
  end

  def test_reduced_history_card_rejects_ambiguous_or_conflicting_references
    resolver = Slackmine::ThreadComments
    Issue.stub(:find_by, ->(**) { flunk 'Ambiguous parent must not resolve an Issue' }) do
      parent = reduced_history_parent
      parent['attachments'] << { 'from_url' => 'https://redmine.example.com/issues/8', 'id' => 3 }
      assert_nil resolver.issue_from_parent(parent, 'ATEST', parent['ts'])
      parent = reduced_history_parent
      parent['attachments'][0]['fallback'] = '[Example] Comment added Task #8: mentions #7: in subject'
      assert_nil resolver.issue_from_parent(parent, 'ATEST', parent['ts'])
      parent = reduced_history_parent
      parent['attachments'][0].delete('fallback')
      parent['attachments'][0]['blocks'][0]['text']['text'] = 'Comment mentions #7: an issue'
      assert_nil resolver.issue_from_parent(parent, 'ATEST', parent['ts'])
    end
  end

  def test_reduced_history_reply_saves_then_posts_feedback_in_same_thread
    resolver = Slackmine::ThreadComments
    parent = reduced_history_parent
    event = { 'type' => 'message', 'user' => 'U123', 'channel' => 'C123',
              'thread_ts' => parent['ts'], 'ts' => '1001.000002', 'text' => 'Example reply' }
    calls = []
    saved = []
    Issue.stub(:find_by, @issue) do
      resolver.stub(:contexts, [nil]) do
        resolver.stub(:enabled?, true) do
          resolver.stub(:persist_reply, ->(issue, reply, team) { saved << [issue, reply, team]; :saved }) do
            Slackmine.stub(:bot_token, 'test-token') do
              Slackmine.stub(:channel_id, 'C123') do
                Slackmine::WorkObjects.stub(:integration_for, true) do
                  Slackmine.stub(:slack_api, ->(method, body, _token, **_options) {
                    calls << [method, body]
                    method == 'conversations.history' ? { 'messages' => [parent] } : { 'ok' => true }
                  }) do
                    Slackmine::ThreadCommentBatch.stub(:timing, [0, 60]) { resolver.process('ATEST', 'T123', event) }
                  end
                end
              end
            end
          end
        end
      end
    end
    assert_equal [[@issue, event, 'T123']], saved
    assert_equal %w[conversations.history chat.postMessage], calls.map(&:first)
    feedback = calls.last[1]
    assert_equal event['channel'], feedback['channel']
    assert_equal event['thread_ts'], feedback['thread_ts']
    assert_includes feedback['text'], '/issues/7'
  end

  def test_compaction_preserves_changes_and_nonduplicated_metadata
    formatter = Slackmine::Formatter
    blocks = [
      { 'type' => 'section', 'fields' => [{ 'text' => "*Status*\nOpen → Closed" }] },
      formatter.section_text('*Metadata*'),
      { 'type' => 'section', 'fields' => [{ 'text' => "*Status*\nClosed" }, { 'text' => "*Start date*\n2026-10-01" }] }
    ]
    Slackmine.stub(:config, @settings) do
      result = formatter.compact_work_object_notification({ 'attachments' => [{ 'blocks' => blocks }] }, @issue, { 'status' => {} }, [])
      output = result.to_json
      assert_includes output, 'Open → Closed'
      assert_includes output, '2026-10-01'
      refute_includes output, '*Status*\\nClosed'
      journal = formatter.journal_payload(@issue, actor: @actor, notes: 'Comment remains')
      assert_includes journal['attachments'].to_json, 'Comment remains'
      refute_includes journal['attachments'].to_json, '|#7 Fix A'
    end
  end

  def test_example_documents_all_message_defaults
    example = YAML.safe_load(File.read(File.expand_path('../config/slackmine.messages.yml.example', __dir__)))
    Slackmine::Formatter::DEFAULT_MESSAGES.each do |group, entries|
      entries.each do |key, value|
        if value.is_a?(Hash)
          value.each_key { |nested| assert example.dig('messages', group, key).key?(nested), "#{group}.#{key}.#{nested}" }
        else
          assert example.dig('messages', group).key?(key), "#{group}.#{key}"
        end
      end
    end
  end

  def test_work_object_type_label_is_independent_of_tracker
    @issue.tracker.name = 'Support'
    Slackmine.stub(:config, @settings) do
      assert_equal 'Issue', issue_payload.dig('metadata', 'entities', 0, 'entity_payload', 'attributes', 'display_type')
      assert_equal 'Issue', Slackmine::Formatter.issue_work_object_details(@issue).dig('entity_payload', 'attributes', 'display_type')
      @settings['messages'] = { 'work_objects' => { 'display_type' => 'Ticket' } }
      assert_equal 'Ticket', issue_payload.dig('metadata', 'entities', 0, 'entity_payload', 'attributes', 'display_type')
    end
  end

  def test_product_name_is_configurable_for_previews_and_details_with_project_override
    @settings['messages'] = { 'work_objects' => { 'product_name' => 'Example Tracker' } }
    @settings['projects'] = { 'agentic' => { 'messages' => { 'work_objects' => { 'product_name' => 'W.A.C' } } } }
    Slackmine.stub(:config, @settings) do
      assert_equal 'W.A.C', issue_payload.dig('metadata', 'entities', 0, 'entity_payload', 'attributes', 'product_name')
      Slackmine.with_project(@project) do
        details = Slackmine::Formatter.issue_work_object_details(@issue)
        assert_equal 'W.A.C', details.dig('entity_payload', 'attributes', 'product_name')
      end
      @settings.delete('projects')
      assert_equal 'Example Tracker', issue_payload.dig('metadata', 'entities', 0, 'entity_payload', 'attributes', 'product_name')
      @settings['messages']['work_objects']['product_name'] = ''
      assert_equal 'Redmine', issue_payload.dig('metadata', 'entities', 0, 'entity_payload', 'attributes', 'product_name')
    end
  end

  def test_thread_comment_body_omits_issue_card_and_headings_but_keeps_formatting
    @settings['slack']['comment_notifications_in_threads'] = true
    Slackmine.stub(:config, @settings) do
      result = Slackmine::Formatter.journal_payload(@issue, actor: @actor, notes: 'Hello **team**')
      compact = result.fetch('_slackmine_thread_comment_payload')
      assert_equal 'Alice · Redmine <https://redmine.example.com/issues/7|#7>: New comment', compact['text']
      assert_equal 'Hello *team*', compact.dig('attachments', 0, 'blocks', 0, 'text', 'text')
      refute compact.key?('metadata')
      refute compact.dig('attachments', 0).key?('color')
      edited = Slackmine::Formatter.journal_payload(@issue, actor: @actor, notes: 'New',
        previous_notes: 'Old', comment_action: 'updated')
      assert edited.fetch('_slackmine_thread_comment_payload').dig('attachments', 0, 'blocks').any?
      assert_equal 'Alice · Redmine <https://redmine.example.com/issues/7|#7>: Comment updated', edited.fetch('_slackmine_thread_comment_payload')['text']
      deleted = Slackmine::Formatter.journal_payload(@issue, actor: @actor, notes: '',
        previous_notes: 'Old', comment_action: 'deleted')
      assert_equal 'Alice · Redmine <https://redmine.example.com/issues/7|#7>: Comment deleted', deleted.fetch('_slackmine_thread_comment_payload')['text']
      assert deleted.fetch('_slackmine_thread_comment_payload').dig('attachments', 0, 'blocks').any?
      assert result.key?('metadata'), 'Fallback retains the full notification'
    end
  end

  def test_thread_notification_heading_supports_project_templates_and_safe_fallback
    @settings['slack']['comment_notifications_in_threads'] = true
    @settings['messages'] = { 'work_objects' => { 'product_name' => 'Example Tracker' } }
    @settings['projects'] = { 'agentic' => { 'messages' => { 'thread_notifications' => {
      'added_header' => '%{product_name} #%{id} の新規コメント · %{actor}: %{subject}'
    } } } }
    Slackmine.stub(:config, @settings) do
      result = Slackmine::Formatter.journal_payload(@issue, actor: @actor, notes: 'Body')
      assert_equal 'Example Tracker <https://redmine.example.com/issues/7|#7> の新規コメント · Alice: Fix A &amp; B', result.dig('_slackmine_thread_comment_payload', 'text')
      @settings['projects']['agentic']['messages']['thread_notifications']['added_header'] = '%{unknown}'
      result = Slackmine::Formatter.journal_payload(@issue, actor: @actor, notes: 'Body')
      assert_equal 'Alice · Example Tracker <https://redmine.example.com/issues/7|#7>: New comment', result.dig('_slackmine_thread_comment_payload', 'text')
    end
  end

  def test_task_schema_and_identity_are_shared_by_creation_updates_and_comments
    Slackmine.stub(:config, @settings) do
      created = issue_payload
      updated = issue_payload('updated')
      comment = Slackmine::Formatter.journal_payload(@issue, actor: @actor, notes: 'A comment')
      entities = [created, updated, comment].map { |message| message.dig('metadata', 'entities', 0) }
      entities.each do |entity|
        assert_equal 'slack#/entities/task', entity['entity_type']
        assert_equal 'https://redmine.example.com/issues/7', entity['url']
        assert_equal({ 'id' => Digest::SHA256.hexdigest(entity['url']), 'type' => 'slackmine_issue' }, entity['external_ref'])
        assert_match(/\A[0-9a-zA-Z\-_:!\/=]+\z/, entity.dig('external_ref', 'id'))
        assert_equal 'Fix A & B', entity.dig('entity_payload', 'attributes', 'title', 'text')
        assert_equal '#7', entity.dig('entity_payload', 'attributes', 'display_id')
        assert_equal 'In progress', entity.dig('entity_payload', 'fields', 'status', 'value')
        assert_equal 'Alice', entity.dig('entity_payload', 'fields', 'assignee', 'user', 'text')
        assert_equal({ 'value' => '2026-10-05', 'type' => 'slack#/types/date' }, entity.dig('entity_payload', 'fields', 'due_date'))
        refute entity.dig('entity_payload', 'fields').key?('description')
        refute entity.key?('app_unfurl_url')
      end
      assert_equal entities[0]['external_ref'], entities[2]['external_ref']
    end
  end

  def test_enabled_actions_show_fields_and_actions_on_main_card_despite_hidden_default_metadata
    @settings['slack']['metadata'] = { 'issue' => { 'status' => false, 'priority' => false,
                                                    'due_date' => false, 'assignee' => false } }
    @settings['slack']['work_object_actions'] = true
    @issue.updated_on = Time.utc(2026, 10, 4, 3, 0)
    Slackmine.stub(:config, @settings) do
      entity = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
      assert_equal @issue.updated_on.to_i, entity.dig('attributes', 'metadata_last_modified')
      assert_equal 'In progress', entity.dig('fields', 'status', 'value')
      assert_equal 'High', entity.dig('fields', 'priority', 'value')
      assert_equal '2026-10-05', entity.dig('fields', 'due_date', 'value')
      assert_equal 'Alice', entity.dig('fields', 'assignee', 'user', 'text')
      assert_equal %w[slackmine_add_comment slackmine_open_issue], entity.dig('actions', 'primary_actions').map { |action| action['action_id'] }
      assert_equal 'https://redmine.example.com/issues/7', entity.dig('actions', 'primary_actions', 1, 'url')
      assert_equal 'Open Redmine', entity.dig('actions', 'primary_actions', 1, 'text')
      @settings['slack']['work_object_actions'] = false
      hidden = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
      refute_empty hidden['fields']
      refute hidden.key?('actions')
    end
  end

  def test_global_actions_apply_to_other_issues_and_allow_project_opt_out
    @issue.id = 8
    @settings['slack']['metadata'] = { 'issue' => { 'status' => false, 'priority' => false,
                                                    'due_date' => false, 'assignee' => false } }
    @settings['slack']['work_object_actions'] = true
    Slackmine.stub(:config, @settings) do
      entity = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
      assert_equal 'Alice', entity.dig('fields', 'assignee', 'user', 'text')
      assert_equal 'In progress', entity.dig('fields', 'status', 'value')
      assert_equal %w[slackmine_add_comment slackmine_open_issue], entity.dig('actions', 'primary_actions').map { |action| action['action_id'] }

      @settings['projects'] = { 'agentic' => { 'slack' => { 'work_object_actions' => false } } }
      hidden = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
      refute_empty hidden['fields']
      refute hidden.key?('actions')
    end
  end

  def test_action_card_shows_category_when_set_even_if_notification_metadata_is_hidden
    @settings['slack']['work_object_actions'] = true
    @settings['slack']['metadata'] = { 'issue' => { 'category' => false } }
    @issue.category = OpenStruct.new(name: 'Support')
    Slackmine.stub(:config, @settings) do
      entity = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
      assert_equal 'Support', entity['custom_fields'].find { |field| field['key'] == 'category' }['value']
      assert_includes entity['display_order'], 'category'
      @issue.category = nil
      entity = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
      refute Array(entity['custom_fields']).any? { |field| field['key'] == 'category' }
    end
  end

  def test_work_object_field_switches_override_actions_and_project_defaults
    @settings['slack']['work_object_actions'] = true
    @settings['slack']['work_object_fields'] = {}
    @issue.fixed_version = OpenStruct.new(name: 'Release 1')
    @issue.start_date = Date.new(2026, 10, 1)
    @issue.estimated_hours = 8
    @issue.category = OpenStruct.new(name: 'Support')
    @issue.done_ratio = 65
    Slackmine.stub(:config, @settings) do
      entity = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
      assert_empty entity['fields']
      assert_nil entity['custom_fields']
      refute_empty entity.dig('actions', 'primary_actions')
      %w[status priority due_date assignee author project tracker category updater target_version start_date estimated_hours done_ratio description].each do |key|
        @settings['slack']['work_object_fields'] = { key => true }
        entity = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
        keys = entity['fields'].keys + Array(entity['custom_fields']).map { |field| field['key'] }
        expected_key = key == 'author' ? 'created_by' : key
        assert_equal [expected_key], keys, key
        assert_includes entity['display_order'], expected_key
        @settings['slack']['work_object_fields'][key] = false
        hidden = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
        assert_empty hidden['fields']
        assert_nil hidden['custom_fields']
      end
      @settings['slack']['work_object_fields'] = { 'category' => true }
      @settings['projects'] = { 'agentic' => { 'slack' => { 'work_object_fields' => { 'category' => false, 'done_ratio' => true } } } }
      entity = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
      assert_equal ['done_ratio'], entity['custom_fields'].map { |field| field['key'] }
      assert_equal ['done_ratio'], entity['display_order']
    end
  end

  def test_last_comment_excludes_private_and_empty_notes_and_compacts_only_full_duplicate
    relation = Class.new(Array) do
      def where(filters = nil)
        filters ? self.class.new(select { |row| filters.all? { |key, value| row.public_send(key) == value } }) : self
      end
      def not(filters)
        self.class.new(reject { |row| filters.any? { |key, values| values.include?(row.public_send(key)) } })
      end
      def order(**columns)
        raise 'Unexpected order' unless columns == { created_on: :desc, id: :desc }
        self.class.new(sort_by { |row| [row.created_on, row.id] }.reverse)
      end
    end
    stamp = Time.utc(2026, 10, 4, 5)
    public_note = OpenStruct.new(id: 1, private_notes: false, notes: 'Public update', user: @actor, created_on: stamp)
    @issue.journals = relation.new([
      public_note,
      OpenStruct.new(id: 2, private_notes: true, notes: 'Secret', user: @actor, created_on: stamp + 1),
      OpenStruct.new(id: 3, private_notes: false, notes: '  ', user: @actor, created_on: stamp + 2)
    ])
    @settings['slack']['work_object_fields'] = { 'last_comment' => true }
    formatter = Slackmine::Formatter
    Slackmine.stub(:config, @settings) do
      payload = formatter.journal_payload(@issue, actor: @actor, notes: 'Public update')
      comment = payload.dig('metadata', 'entities', 0, 'entity_payload', 'custom_fields').find { |field| field['key'] == 'last_comment' }
      assert_equal "Alice · 2026-10-04T05:00:00Z\nPublic update", comment['value']
      refute_includes payload.to_json, 'Secret'
      refute_includes payload['attachments'].to_json, 'Public update'
      payload = formatter.journal_payload(@issue, actor: @actor, notes: 'Different notification')
      assert_includes payload['attachments'].to_json, 'Different notification'
      public_note.notes = 'a' * 1001
      payload = formatter.journal_payload(@issue, actor: @actor, notes: public_note.notes)
      comment = payload.dig('metadata', 'entities', 0, 'entity_payload', 'custom_fields').find { |field| field['key'] == 'last_comment' }
      assert comment['value'].end_with?('a' * 1000 + '…')
      assert_includes payload['attachments'].to_json, 'a' * 1001
      public_note.private_notes = true
      payload = issue_payload
      refute Array(payload.dig('metadata', 'entities', 0, 'entity_payload', 'custom_fields')).any? { |field| field['key'] == 'last_comment' }
      @settings['slack']['work_object_fields']['last_comment'] = false
      @issue.journals = nil
      issue_payload
    end
  end

  def test_card_fields_follow_yaml_order_with_or_without_actions
    @settings['slack']['work_object_fields'] = {
      'description' => true, 'last_comment' => true, 'category' => true, 'done_ratio' => true, 'status' => true
    }
    @issue.category = OpenStruct.new(name: 'Support')
    @issue.done_ratio = 65
    journal = OpenStruct.new(notes: 'Latest note', user: @actor, created_on: Time.utc(2026, 10, 4))
    Slackmine.stub(:config, @settings) do
      Slackmine::Formatter.stub(:last_public_comment, journal) do
        [true, false].each do |actions|
          @settings['slack']['work_object_actions'] = actions
          entity = issue_payload.dig('metadata', 'entities', 0, 'entity_payload')
          assert_equal %w[description last_comment category done_ratio status], entity['display_order']
          @settings['slack']['work_object_fields']['description'] = false
          entity = issue_payload.dig('metadata', 'entities', 0, 'entity_payload')
          assert_equal %w[last_comment category done_ratio status], entity['display_order']
          @settings['slack']['work_object_fields']['description'] = true
        end
      end
    end
  end

  def test_project_card_order_precedes_inherited_fields_and_maps_author
    @settings['slack']['work_object_fields'] = { 'status' => true, 'author' => true, 'priority' => true }
    @settings['projects'] = { 'agentic' => { 'slack' => { 'work_object_fields' => {
      'priority' => true, 'author' => true, 'description' => true, 'category' => false
    } } } }
    Slackmine.stub(:config, @settings) do
      entity = issue_payload.dig('metadata', 'entities', 0, 'entity_payload')
      assert_equal %w[priority created_by description status], entity['display_order']
    end
  end

  def test_card_description_is_optional_and_truncated
    @settings['slack']['work_object_fields'] = { 'description' => true }
    Slackmine.stub(:config, @settings) do
      @issue.description = 'x' * 1001
      field = issue_payload.dig('metadata', 'entities', 0, 'entity_payload', 'fields', 'description')
      assert_equal 'x' * 1000 + '…', field['value']
      assert_equal true, field['long']
      @issue.description = '  '
      refute issue_payload.dig('metadata', 'entities', 0, 'entity_payload', 'fields').key?('description')
    end
  end

  def test_work_object_progress_displays_exact_percentage
    @settings['slack']['work_object_actions'] = true
    Slackmine.stub(:config, @settings) do
      { 0 => '0%', 65 => '65%', 100 => '100%' }.each do |percent, meter|
        @issue.done_ratio = percent
        entity = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload')
        assert_equal meter, entity['custom_fields'].find { |field| field['key'] == 'done_ratio' }['value']
        assert_includes entity['display_order'], 'done_ratio'
      end
    end
  end

  def test_action_card_shows_unassigned_assignee
    @issue.assigned_to = nil
    @settings['slack']['work_object_actions'] = true
    Slackmine.stub(:config, @settings) do
      fields = issue_payload('updated').dig('metadata', 'entities', 0, 'entity_payload', 'fields')
      assert_equal({ 'text' => 'Unassigned' }, fields.dig('assignee', 'user'))
    end
  end

  def test_work_object_uses_mapped_slack_user_id_for_assignee_and_creator
    user = User.new
    user.login = 'alice'
    user.mail = 'alice@example.com'
    user.name = 'Alice'
    @issue.assigned_to = user
    @issue.author = user
    @settings['users'] = { 'alice' => 'U123ABC456' }

    Slackmine.stub(:config, @settings) do
      preview = issue_payload.dig('metadata', 'entities', 0, 'entity_payload', 'fields')
      details = Slackmine::Formatter.issue_work_object_details(@issue).dig('entity_payload', 'fields')
      [preview, details].each do |fields|
        %w[assignee created_by].each do |key|
          assert_equal({ 'user_id' => 'U123ABC456' }, fields.dig(key, 'user'))
        end
      end

      @settings['users'].clear
      fallback = Slackmine::Formatter.issue_work_object_details(@issue).dig('entity_payload', 'fields')
      assert_equal({ 'text' => 'Alice' }, fallback.dig('assignee', 'user'))
    end
  end

  def test_work_object_id_distinguishes_slackmine_hosts_and_issues
    Slackmine.stub(:config, @settings) do
      original = issue_payload.dig('metadata', 'entities', 0, 'external_ref', 'id')
      Setting.stub(:host_name, 'another.example.com/slackmine') do
        other_host = issue_payload.dig('metadata', 'entities', 0, 'external_ref', 'id')
        refute_equal original, other_host
        assert_match(/\A[0-9a-zA-Z\-_:!\/=]+\z/, other_host)
      end
      @issue.id = 8
      refute_equal original, issue_payload.dig('metadata', 'entities', 0, 'external_ref', 'id')
    end
  end

  def test_project_switch_overrides_global_in_both_directions
    [true, false].each do |value|
      settings = { 'slack' => { 'work_object_previews' => !value }, 'projects' => {
        'agentic' => { 'slack' => { 'work_object_previews' => value } }
      } }
      Slackmine.stub(:config, settings) do
        assert_equal value, issue_payload.key?('metadata')
      end
    end
  end

  def test_omitted_card_fields_are_hidden_even_with_notification_metadata
    @settings['slack'].delete('work_object_fields')
    Slackmine.stub(:config, @settings) do
      entity = issue_payload.dig('metadata', 'entities', 0, 'entity_payload')
      assert_empty entity['fields']
      refute entity.key?('custom_fields')
    end
  end

  def test_project_field_override_is_applied
    @settings['projects'] = { 'agentic' => { 'slack' => { 'work_object_fields' => {
      'status' => false, 'project' => false, 'priority' => false
    } } } }
    Slackmine.stub(:config, @settings) do
      entity = issue_payload.dig('metadata', 'entities', 0, 'entity_payload')
      refute entity['fields'].key?('status')
      refute entity['fields'].key?('priority')
      refute Array(entity['custom_fields']).any? { |field| field['key'] == 'project' }
      assert entity['fields'].key?('assignee')
    end
  end

  def test_deleted_and_private_issues_have_no_work_object
    Slackmine.stub(:config, @settings) do
      refute issue_payload('deleted').key?('metadata')
      @issue.define_singleton_method(:is_private?) { true }
      refute issue_payload.key?('metadata')
      comment = Slackmine::Formatter.journal_payload(@issue, actor: @actor, notes: 'Private')
      refute comment.key?('metadata')
    end
  end

  def test_preview_reaches_slack_and_survives_image_cleanup
    message = Slackmine.stub(:config, @settings) { issue_payload }
    message['attachments'][0]['blocks'] << { 'type' => 'image', 'slack_file' => { 'id' => 'F123' }, 'alt_text' => 'image' }
    calls = []
    api = lambda do |method, body, _token, **options|
      assert_equal true, options[:form]
      calls << [method, body]
      { 'ok' => true, 'ts' => '123.456' }
    end
    Slackmine.stub(:slack_api, api) { Slackmine.post_message(message, 'C123', 'token') }
    assert_equal %w[chat.postMessage chat.update], calls.map(&:first)
    calls.each do |_method, body|
      assert_equal message['metadata'], body['metadata']
      assert_equal 'C123', body['channel']
    end
    assert_equal message.dig('attachments', 0, 'fallback'), calls.first[1]['text']
    assert_equal message['text'], calls.last[1]['text']
  end

  def test_non_issue_notifications_remain_unchanged
    Slackmine.stub(:config, @settings) do
      message = Slackmine::Formatter.generic_payload(project: @project, noun: 'News', action: 'created',
                                                                   subject: 'News', url: 'https://redmine.example.com/news/1', actor: @actor)
      refute message.key?('metadata')
    end
  end

  def test_work_object_is_sent_as_a_json_encoded_form_without_losing_attachments
    message = Slackmine.stub(:config, @settings) { issue_payload }
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.define_singleton_method(:body) { '{"ok":true,"ts":"123.456"}' }
    http = Object.new
    captured = nil
    http.define_singleton_method(:request) do |request|
      captured = request
      response
    end
    Net::HTTP.stub(:start, ->(*, &block) { block.call(http) }) do
      Slackmine.post_message(message, 'C123', 'token')
    end
    assert_equal 'application/x-www-form-urlencoded', captured['Content-Type']
    form = URI.decode_www_form(captured.body).to_h
    assert_equal message['metadata'], JSON.parse(form.fetch('metadata'))
    assert_equal message['attachments'], JSON.parse(form.fetch('attachments'))
    assert_equal 'C123', form['channel']
    assert_equal message['text'], form['text']
  end
end

class WorkObjectDetailsTest < Minitest::Test
  WORK = Slackmine::WorkObjects

  def setup
    @project = OpenStruct.new(identifier: 'agentic', name: 'Agentic', active?: true)
    @user = OpenStruct.new(id: 3, name: 'Alice', active?: true)
    @issue = OpenStruct.new(id: 7, subject: 'Current title', description: 'Current description',
                            project: @project, tracker: OpenStruct.new(name: 'Task'),
                            status: OpenStruct.new(name: 'In progress'), assigned_to: @user,
                            due_date: Date.new(2026, 10, 10), is_private?: false)
    @issue.define_singleton_method(:visible?) { |user| user.id == 3 }
    @settings = { 'slack' => { 'work_object_previews' => true, 'bot_token' => 'test-token',
                              'events' => { 'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'test-secret' } },
                  'users' => { 'alice' => 'U123' } }
    @url = 'https://redmine.example.com/issues/7'
    @event = { 'type' => 'entity_details_requested', 'trigger_id' => 'trigger', 'user' => 'U123',
               'entity_url' => @url, 'external_ref' => { 'id' => Digest::SHA256.hexdigest(@url), 'type' => 'slackmine_issue' } }
  end

  def test_signature_requires_unmodified_body_and_fresh_timestamp
    body = '{"type":"url_verification","challenge":"test"}'
    timestamp = '1000'
    signature = 'v0=' + OpenSSL::HMAC.hexdigest('SHA256', 'test-secret', "v0:#{timestamp}:#{body}")
    Slackmine.stub(:config, @settings) do
      assert WORK.verified_integration(body, timestamp, signature, now: 1000)
      refute WORK.verified_integration(body + ' ', timestamp, signature, now: 1000)
      refute WORK.verified_integration(body, timestamp, signature, now: 1301)
      refute WORK.verified_integration(body, timestamp, signature, now: 699)
      refute WORK.verified_integration(body, timestamp, 'v0=bad', now: 1000)
      refute WORK.verified_integration(body, timestamp, signature, now: 1000, app_id: 'AOTHER')
      refute WORK.verified_integration(body, timestamp, signature, now: 1000, team_id: 'TOTHER')
    end
  end

  def test_project_integrations_with_same_secret_are_routed_to_the_correct_app
    @settings['projects'] = { 'agentic' => { 'slack' => { 'events' => { 'app_id' => 'ASECOND' } } } }
    signature = 'v0=' + OpenSSL::HMAC.hexdigest('SHA256', 'test-secret', 'v0:1000:body')
    Slackmine.stub(:config, @settings) do
      assert_equal 'ASECOND', WORK.verified_integration('body', '1000', signature, now: 1000, app_id: 'ASECOND')['app_id']
    end
  end

  def test_missing_event_configuration_and_invalid_project_overrides_are_ignored
    Slackmine.stub(:config, { 'projects' => { 'invalid' => false } }) do
      assert_empty WORK.integrations
    end
    @settings['projects'] = { 'invalid' => false }
    Slackmine.stub(:config, @settings) do
      assert_equal 1, WORK.integrations.length
    end
  end

  def test_environment_signing_secret_fallback
    previous = ENV['SLACK_SIGNING_SECRET']
    ENV['SLACK_SIGNING_SECRET'] = 'environment-test-secret'
    @settings['slack']['events'].delete('signing_secret')
    Slackmine.stub(:config, @settings) do
      assert_equal 'environment-test-secret', WORK.integrations.first['signing_secret']
    end
  ensure
    ENV['SLACK_SIGNING_SECRET'] = previous
  end

  def capture_details
    calls = []
    Slackmine.stub(:config, @settings) do
      Issue.stub(:find_by, @issue) do
        User.stub(:find_by, @user) do
          Slackmine.stub(:slack_api, ->(method, body, token, **options) {
            calls << [method, body, token, options]
            { 'ok' => true }
          }) { WORK.present_details('ATEST', 'TTEST', @event) }
        end
      end
    end
    calls
  end

  def test_authorized_viewer_receives_current_details_with_single_entity_schema
    calls = capture_details
    assert_equal 1, calls.length
    method, body, token, options = calls.first
    assert_equal 'entity.presentDetails', method
    assert_equal 'test-token', token
    assert_equal true, options[:form]
    assert_equal 'trigger', body['trigger_id']
    metadata = body.fetch('metadata')
    refute metadata.key?('entities')
    assert_equal @event['external_ref'], metadata['external_ref']
    assert_equal 'Current title', metadata.dig('entity_payload', 'attributes', 'title', 'text')
    assert_equal 'Current description', metadata.dig('entity_payload', 'fields', 'description', 'value')
    assert_equal 'In progress', metadata.dig('entity_payload', 'fields', 'status', 'value')
    assert_equal '2026-10-10', metadata.dig('entity_payload', 'fields', 'due_date', 'value')
  end

  def test_link_refresh_unfurls_current_issue_for_authorized_viewer
    @settings['slack']['work_object_actions'] = true
    event = { 'type' => 'link_shared', 'is_unfurl_refresh' => true, 'user' => 'U123',
              'source' => 'conversations_history', 'unfurl_id' => 'refresh-id',
              'links' => [{ 'url' => @url }, { 'url' => @url },
                          { 'url' => 'https://other.example.com/issues/7' }] }
    calls = []
    Slackmine.stub(:config, @settings) do
      Issue.stub(:find_by, @issue) do
        User.stub(:find_by, @user) do
          Slackmine.stub(:slack_api, ->(*args, **options) {
            calls << [*args, options]
            { 'ok' => true }
          }) { WORK.unfurl_links('ATEST', 'TTEST', event) }
        end
      end
    end
    assert_equal 1, calls.length
    method, body, token, options = calls.first
    assert_equal 'chat.unfurl', method
    assert_equal({ 'unfurl_id' => 'refresh-id', 'source' => 'conversations_history' }, body.reject { |key, _| key == 'metadata' })
    assert_equal 'test-token', token
    assert_equal true, options[:form]
    entities = body.dig('metadata', 'entities')
    assert_equal 1, entities.length
    assert_equal @url, entities.first['app_unfurl_url']
    assert_equal 'Current title', entities.first.dig('entity_payload', 'attributes', 'title', 'text')
    assert_equal %w[slackmine_add_comment slackmine_open_issue], entities.first.dig('entity_payload', 'actions', 'primary_actions').map { |action| action['action_id'] }
  end

  def test_link_unfurl_uses_message_target_and_rejects_inaccessible_issues
    event = { 'type' => 'link_shared', 'user' => 'U123', 'channel' => 'C123',
              'message_ts' => '123.456', 'links' => [{ 'url' => @url }] }
    calls = []
    Slackmine.stub(:config, @settings) do
      Issue.stub(:find_by, @issue) do
        User.stub(:find_by, @user) do
          Slackmine.stub(:slack_api, ->(*args, **options) {
            calls << [*args, options]
            { 'ok' => true }
          }) do
            WORK.unfurl_links('ATEST', 'TTEST', event)
            assert_equal({ 'channel' => 'C123', 'ts' => '123.456' }, calls.first[1].reject { |key, _| key == 'metadata' })
            calls.clear
            @issue.define_singleton_method(:visible?) { |_viewer| false }
            WORK.unfurl_links('ATEST', 'TTEST', event)
            assert_empty calls
            @issue.define_singleton_method(:visible?) { |_viewer| true }
            @issue.define_singleton_method(:is_private?) { true }
            WORK.unfurl_links('ATEST', 'TTEST', event)
            assert_empty calls
            @issue.define_singleton_method(:is_private?) { false }
            WORK.unfurl_links('AOTHER', 'TTEST', event)
            assert_empty calls
          end
        end
      end
    end
  end

  def test_unmapped_and_locked_users_receive_only_restricted_error
    @event['user'] = 'U999'
    body = capture_details.first[1]
    assert_equal({ 'status' => 'restricted' }, body['error'])
    refute body.key?('metadata')
    @event['user'] = 'U123'
    @user.define_singleton_method(:active?) { false }
    refute capture_details.first[1].key?('metadata')
  end

  def test_description_limit_and_details_independent_of_notification_visibility
    @issue.description = 'x' * 10_001
    @settings['slack']['metadata'] = { 'issue' => { 'status' => false } }
    fields = capture_details.first[1].dig('metadata', 'entity_payload', 'fields')
    assert_equal 10_000, fields.dig('description', 'value').length
    assert_equal 'In progress', fields.dig('status', 'value')
  end

  def test_invisible_private_disabled_and_archived_issues_are_restricted
    @issue.define_singleton_method(:visible?) { |_user| false }
    refute capture_details.first[1].key?('metadata')
    @issue.define_singleton_method(:visible?) { |_user| true }
    @issue.define_singleton_method(:is_private?) { true }
    refute capture_details.first[1].key?('metadata')
    @issue.define_singleton_method(:is_private?) { false }
    @settings['slack']['work_object_previews'] = false
    refute capture_details.first[1].key?('metadata')
    @settings['slack']['work_object_previews'] = true
    @project.define_singleton_method(:active?) { false }
    refute capture_details.first[1].key?('metadata')
  end

  def test_foreign_urls_and_mismatched_references_never_call_slack
    @event['entity_url'] = 'https://evil.example/issues/7'
    assert_empty capture_details
    @event['entity_url'] = @url + '?redirect=evil'
    assert_empty capture_details
    @event['entity_url'] = @url
    @event['external_ref']['id'] = 'another-id'
    assert_empty capture_details
    @event['external_ref']['id'] = Digest::SHA256.hexdigest(@url)
    @event['external_ref']['type'] = 'other'
    assert_empty capture_details
  end

  def test_wrong_app_never_uses_project_bot_token
    @settings['slack']['events']['app_id'] = 'AOTHER'
    assert_empty capture_details
  end

  def test_deleted_issue_does_not_raise_or_send_content
    Slackmine.stub(:config, @settings) do
      Issue.stub(:find_by, nil) do
        Slackmine.stub(:slack_api, ->(*) { flunk 'Unexpected Slack request' }) do
          assert_nil WORK.present_details('ATEST', 'TTEST', @event)
        end
      end
    end
  end

  def test_missing_and_ambiguous_slackmine_user_mappings_are_denied
    Slackmine.stub(:config, @settings) do
      User.stub(:find_by, nil) { assert_nil WORK.viewer_for('U123') }
    end
    @settings['users']['another'] = 'U123'
    Slackmine.stub(:config, @settings) do
      User.stub(:find_by, ->(**keys) { keys[:login] == 'alice' ? @user : OpenStruct.new(id: 4, active?: true) }) do
        assert_nil WORK.viewer_for('U123')
      end
    end
  end

  def test_actions_require_enabled_setting_and_viewer_permissions
    @settings['slack']['work_object_actions'] = true
    @issue.status_id = 2
    @issue.priority_id = 4
    @issue.priority = OpenStruct.new(name: 'No Priority')
    @issue.assigned_to_id = 4
    @issue.define_singleton_method(:attributes_editable?) { |_viewer| true }
    @issue.define_singleton_method(:safe_attribute?) { |_attribute, _viewer| true }
    @issue.define_singleton_method(:notes_addable?) { |_viewer| true }
    @issue.define_singleton_method(:assignable_users) { [@test_user] }
    @issue.instance_variable_set(:@test_user, @user)
    @issue.define_singleton_method(:new_statuses_allowed_to) do |_viewer|
      [OpenStruct.new(id: 2, name: 'In progress'), OpenStruct.new(id: 3, name: 'Done')]
    end
    @issue.define_singleton_method(:status) { OpenStruct.new(name: status_id == 3 ? 'Done' : 'In progress') }
    fields = capture_details.first[1].dig('metadata', 'entity_payload', 'fields')
    assert_equal '2', fields.dig('status', 'edit', 'select', 'current_value')
    assert_equal '3', fields.dig('status', 'edit', 'select', 'static_options', 1, 'value')
    assert_equal '4', fields.dig('priority', 'edit', 'select', 'current_value')
    assert_equal true, fields.dig('due_date', 'edit', 'enabled')
    metadata = capture_details.first[1]['metadata']
    assert_equal %w[slackmine_edit_issue slackmine_assign_to_me], metadata.dig('entity_payload', 'actions', 'primary_actions').map { |action| action['action_id'] }
    assert_equal 'new_comment', metadata.dig('entity_payload', 'custom_fields', 1, 'key')
    @settings['slack']['work_object_actions'] = false
    refute capture_details.first[1]['metadata'].dig('entity_payload', 'actions')
  end

  def test_global_actions_enable_details_for_another_issue
    @settings['slack']['work_object_actions'] = true
    @issue.id = 8
    Slackmine.stub(:config, @settings) do
      assert WORK.actions_enabled?(@issue)
    end
  end

  def prepare_action_issue
    @settings['slack']['work_object_actions'] = true
    @issue.status_id = 2
    @issue.priority_id = 4
    @issue.priority = OpenStruct.new(name: 'No Priority')
    @issue.assigned_to_id = 4
    @issue.define_singleton_method(:attributes_editable?) { |_viewer| true }
    @issue.define_singleton_method(:safe_attribute?) { |_attribute, _viewer| true }
    @issue.define_singleton_method(:notes_addable?) { |_viewer| true }
    @issue.define_singleton_method(:assignable_users) { [@test_user] }
    @issue.instance_variable_set(:@test_user, @user)
    @issue.define_singleton_method(:new_statuses_allowed_to) do |_viewer|
      [OpenStruct.new(id: 2, name: 'In progress'), OpenStruct.new(id: 3, name: 'Done')]
    end
    @issue.define_singleton_method(:status) { OpenStruct.new(name: status_id == 3 ? 'Done' : 'In progress') }
    @issue.define_singleton_method(:with_lock) { |&block| block.call }
    @issue.define_singleton_method(:safe_attributes=) do |attrs, _viewer|
      (@events ||= []) << :attributes
      self.assigned_to_id = attrs['assigned_to_id'].empty? ? nil : attrs['assigned_to_id'].to_i if attrs.key?('assigned_to_id')
      self.status_id = attrs['status_id'].to_i if attrs['status_id']
      self.priority_id = attrs['priority_id'].to_i if attrs['priority_id']
      self.priority = IssuePriority.active.find { |priority| priority.id == priority_id } if attrs['priority_id']
      self.due_date = attrs['due_date'].empty? ? nil : Date.iso8601(attrs['due_date']) if attrs.key?('due_date')
      self.description = attrs['description'] if attrs.key?('description')
    end
    @issue.define_singleton_method(:init_journal) do |_viewer, note|
      (@events ||= []) << :journal
      (@notes ||= []) << note
    end
    @issue.define_singleton_method(:notes) { @notes || [] }
    @issue.define_singleton_method(:events) { @events || [] }
    @issue.define_singleton_method(:save!) { true }
    @issue.define_singleton_method(:reload) { self }
  end

  def action_payload(type, source, extras = {})
    { 'type' => type, 'api_app_id' => 'ATEST', 'team' => { 'id' => 'TTEST' },
      'user' => { 'id' => 'U123' }, 'trigger_id' => 'trigger', source => {
        'type' => 'entity_detail', 'entity_url' => @url, 'external_ref' => @event['external_ref']
      } }.merge(extras)
  end

  def capture_interaction(payload, drain: true)
    calls = []
    @refresh_jobs = []
    Slackmine.stub(:config, @settings) do
      Issue.stub(:find_by, @issue) do
        User.stub(:find_by, @user) do
          Slackmine.stub(:slack_api, ->(method, body, token, **options) {
            calls << [method, body, token, options]
            method == 'conversations.replies' ? { 'messages' => [{ 'ts' => '123.456', 'text' => 'Original notification' }] } : { 'ok' => true }
          }) do
            SlackmineWorkObjectRefreshJob.stub(:perform_later, ->(*args) { @refresh_jobs << args }) do
              WORK.process_interaction('ATEST', 'TTEST', payload)
              @refresh_jobs.each { |args| WORK.refresh_after_interaction(*args) } if drain
            end
          end
        end
      end
    end
    calls
  end

  def test_assign_status_and_comment_update_requires_enabled_actions
    prepare_action_issue
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_assign_to_me' }])
    calls = capture_interaction(button)
    assert_equal 3, @issue.assigned_to_id
    assert_equal [:journal, :attributes], @issue.events
    assert_equal 'entity.presentDetails', calls.first[0]

    edit = action_payload('view_submission', 'view')
    edit['view']['state'] = { 'values' => {
      'status' => { 'status.input' => { 'selected_option' => { 'value' => '3' } } },
      'new_comment' => { 'new_comment.input' => { 'value' => 'Test note' } }
    } }
    calls = capture_interaction(edit)
    assert_equal 3, @issue.status_id
    assert_equal 'Test note', @issue.notes.last
    assert_equal 'Done', calls.first[1].dig('metadata', 'entity_payload', 'fields', 'status', 'value')

    @settings['slack']['work_object_actions'] = false
    assert_empty capture_interaction(button)
  end

  def test_work_object_ui_labels_can_be_overridden_in_yaml
    prepare_action_issue
    @settings['messages'] = {
      'work_objects' => { 'edit_issue' => '課題を編集', 'add_comment' => 'コメント追加',
        'edit_title' => '編集 #%{id}', 'save' => '保存', 'cancel' => '戻る', 'comment_placeholder' => '入力してください' },
      'fields' => { 'status' => '状態', 'priority' => '優先度' },
      'values' => { 'unassigned' => '未割当' }
    }
    metadata = capture_details.first[1]['metadata']
    assert_equal '課題を編集', metadata.dig('entity_payload', 'actions', 'primary_actions', 0, 'text')
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_edit_issue' }])
    modal = capture_interaction(button).first[1]['view']
    assert_equal '編集 #7', modal.dig('title', 'text')
    assert_equal '保存', modal.dig('submit', 'text')
    assert_equal '戻る', modal.dig('close', 'text')
    assert_equal '状態', modal['blocks'].find { |block| block['block_id'] == 'status' }.dig('label', 'text')
    @settings['messages']['work_objects']['edit_title'] = '%{missing}'
    assert_equal 'Edit issue #7', capture_interaction(button).first[1].dig('view', 'title', 'text')
  end

  def test_card_comment_action_requires_only_comment_permission_and_saves_only_notes
    prepare_action_issue
    @issue.define_singleton_method(:attributes_editable?) { |_viewer| false }
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_add_comment' }])
    button['container']['type'] = 'message_attachment'
    view = capture_interaction(button).first[1]['view']
    assert_equal 'slackmine_add_comment', view['callback_id']
    assert_equal ['new_comment'], view['blocks'].map { |block| block['block_id'] }
    assert_equal false, view['blocks'].first['optional']
    edit = action_payload('view_submission', 'view')
    edit['view'] = view.merge('state' => { 'values' => {
      'new_comment' => { 'new_comment' => { 'value' => 'Comment from card' } },
      'status' => { 'status' => { 'selected_option' => { 'value' => '3' } } }
    } })
    capture_interaction(edit)
    assert_equal ['Comment from card'], @issue.notes
    assert_equal 2, @issue.status_id
    @issue.define_singleton_method(:notes_addable?) { |_viewer| false }
    assert_empty capture_interaction(button)
    capture_interaction(edit)
    assert_equal ['Comment from card'], @issue.notes
  end

  def test_reply_button_opens_comment_modal_and_reassigns_with_the_comment
    prepare_action_issue
    @settings['slack']['work_object_buttons'] = { 'reply' => true }
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_reply' }])
    button['container']['type'] = 'message_attachment'
    view = capture_interaction(button).first[1]['view']
    assert_equal 'slackmine_reply', view['callback_id']
    assert_equal ['new_comment'], view['blocks'].select { |b| b['type'] == 'input' }.map { |b| b['block_id'] }
    assert_equal false, view['blocks'].last['optional']
    assert_empty @issue.notes
    edit = action_payload('view_submission', 'view')
    edit['view'] = view.merge('state' => { 'values' => {
      'new_comment' => { 'new_comment' => { 'value' => 'Reply from card' } },
      'assignee' => { 'assignee' => { 'selected_option' => { 'value' => '999' } } },
      'status' => { 'status' => { 'selected_option' => { 'value' => '3' } } }
    } })
    WORK.stub(:previous_assignee_id, @user.id) { capture_interaction(edit) }
    assert_equal @user.id, @issue.assigned_to_id
    assert_equal ['Reply from card'], @issue.notes
    assert_equal [:journal, :attributes], @issue.events
    assert_equal 2, @issue.status_id
    @settings['slack']['work_object_buttons']['reply'] = false
    assert_empty capture_interaction(edit)
    assert_equal ['Reply from card'], @issue.notes
  end

  def test_reply_without_assignment_permission_saves_only_the_comment
    prepare_action_issue
    @issue.define_singleton_method(:attributes_editable?) { |_| false }
    previous = User.current
    Slackmine.stub(:config, @settings) do
      WORK.stub(:previous_assignee_id, ->(*) { raise 'History should not be queried' }) do
        assert_equal :saved, WORK.update_issue(@issue, @user, reply: true, comment: 'Reply')
      end
    end
    assert_equal 4, @issue.assigned_to_id
    assert_equal ['Reply'], @issue.notes
    assert_same previous, User.current
  end

  def test_reply_without_an_assignable_active_previous_owner_saves_only_the_comment
    [nil, 999, @user.id].each do |previous_id|
      prepare_action_issue
      @issue.instance_variable_set(:@notes, [])
      @issue.define_singleton_method(:assignable_users) { [OpenStruct.new(id: 3, active?: false)] }
      Slackmine.stub(:config, @settings) do
        WORK.stub(:previous_assignee_id, previous_id) do
          assert_equal :saved, WORK.update_issue(@issue, @user, reply: true, comment: 'Reply')
        end
      end
      assert_equal 4, @issue.assigned_to_id
      assert_equal ['Reply'], @issue.notes
    end
  end

  def test_reply_without_comment_permission_or_text_cannot_reassign
    prepare_action_issue
    Slackmine.stub(:config, @settings) do
      assert_equal :restricted, WORK.update_issue(@issue, @user, reply: true, comment: '  ')
      @issue.define_singleton_method(:notes_addable?) { |_| false }
      assert_equal :restricted, WORK.update_issue(@issue, @user, reply: true, comment: 'Reply')
    end
    assert_equal 4, @issue.assigned_to_id
    assert_empty @issue.notes
  end

  def test_reply_history_uses_the_latest_former_assignee_and_excludes_current_and_empty_values
    prepare_action_issue
    query = Minitest::Mock.new
    chain = Minitest::Mock.new
    journals = Minitest::Mock.new
    journals.expect(:joins, query, [:details])
    query.expect(:where, query, [{ journal_details: { property: 'attr', prop_key: 'assigned_to_id' } }])
    query.expect(:where, chain)
    chain.expect(:not, query, [{ journal_details: { old_value: [nil, '', '4'] } }])
    query.expect(:order, query, ['journals.created_on DESC, journals.id DESC, journal_details.id DESC'])
    query.expect(:limit, query, [1])
    query.expect(:pluck, ['3'], ['journal_details.old_value'])
    @issue.journals = journals
    assert_equal 3, WORK.previous_assignee_id(@issue)
    [journals, chain, query].each(&:verify)
  end

  def test_configured_buttons_follow_order_and_use_overflow
    prepare_action_issue
    @settings['slack']['work_object_buttons'] = {
      'open_issue' => true, 'add_comment' => true, 'edit_issue' => true,
      'change_assignee' => true, 'assign_to_me' => true, 'log_time' => true, 'start_work' => true, 'watch' => false
    }
    @settings['slack']['work_object_start_status_id'] = 3
    Slackmine.stub(:config, @settings) do
      actions = WORK.configured_actions(@issue)
      assert_equal %w[slackmine_open_issue slackmine_add_comment], actions['primary_actions'].map { |a| a['action_id'] }
      assert_equal %w[slackmine_edit_issue slackmine_edit_assignee slackmine_assign_to_me slackmine_log_time slackmine_start_work], actions['overflow_actions'].map { |a| a['action_id'] }
      assert_equal @url + '/time_entries/new', actions['overflow_actions'][3]['url']
      @settings['projects'] = { 'agentic' => { 'slack' => { 'work_object_buttons' => { 'add_comment' => true, 'open_issue' => false } } } }
      assert_equal 'slackmine_add_comment', WORK.configured_actions(@issue)['primary_actions'].first['action_id']
    end
  end

  def test_start_work_rechecks_status_and_disabled_buttons
    prepare_action_issue
    @settings['slack']['work_object_buttons'] = { 'start_work' => true }
    @settings['slack']['work_object_start_status_id'] = 3
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_start_work' }])
    capture_interaction(button)
    assert_equal 3, @issue.status_id
    refute capture_details.first[1].dig('metadata', 'entity_payload', 'actions', 'primary_actions').any?
    previous_events = @issue.events.dup
    capture_interaction(button)
    assert_equal previous_events, @issue.events
    @settings['slack']['work_object_start_status_id'] = 999
    capture_interaction(button)
    assert_equal 3, @issue.status_id
    @settings['slack']['work_object_buttons']['start_work'] = false
    assert_empty capture_interaction(button)
  end

  def test_complete_work_rechecks_status_and_disabled_buttons
    prepare_action_issue
    @settings['slack']['work_object_buttons'] = { 'complete_work' => true }
    refute capture_details.first[1].dig('metadata', 'entity_payload', 'actions', 'primary_actions').any?
    @settings['slack']['work_object_complete_status_id'] = 3
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_complete_work' }])
    capture_interaction(button)
    assert_equal 3, @issue.status_id
    refute capture_details.first[1].dig('metadata', 'entity_payload', 'actions', 'primary_actions').any?
    previous_events = @issue.events.dup
    capture_interaction(button)
    assert_equal previous_events, @issue.events
    @settings['slack']['work_object_complete_status_id'] = 999
    capture_interaction(button)
    assert_equal 3, @issue.status_id
    @settings['slack']['work_object_buttons']['complete_work'] = false
    assert_empty capture_interaction(button)
  end

  def test_work_buttons_are_mutually_exclusive_when_both_enabled
    prepare_action_issue
    @settings['slack']['work_object_buttons'] = { 'complete_work' => true, 'start_work' => true }
    @settings['slack']['work_object_start_status_id'] = 3
    @settings['slack']['work_object_complete_status_id'] = 5
    Slackmine.stub(:config, @settings) do
      [[1, 'slackmine_start_work'], [3, 'slackmine_complete_work'], [5, nil]].each do |status, expected|
        @issue.status_id = status
        actions = WORK.configured_actions(@issue)
        assert_equal [expected].compact, actions.fetch('primary_actions').map { |action| action['action_id'] }
        refute actions.key?('overflow_actions')
      end
      @issue.status_id = 9
      @issue.define_singleton_method(:closed?) { true }
      assert_empty WORK.configured_actions(@issue).fetch('primary_actions')
      @settings['slack'].delete('work_object_start_status_id')
      assert_empty WORK.configured_actions(@issue).fetch('primary_actions')
    end
  end

  def test_watch_and_unwatch_are_idempotent_and_authorized
    prepare_action_issue
    @settings['slack']['work_object_buttons'] = { 'watch' => true }
    @issue.define_singleton_method(:watched_by?) { |_viewer| @watching == true }
    @issue.define_singleton_method(:valid_watcher?) { |_viewer| true }
    @issue.define_singleton_method(:set_watcher) { |_viewer, enabled| @watching = enabled }
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_watch' }])
    Slackmine.stub(:config, @settings) { assert_equal :saved, WORK.update_watch(@issue, @user, true) }
    assert @issue.watched_by?(@user)
    actions = capture_details.first[1].dig('metadata', 'entity_payload', 'actions', 'primary_actions')
    assert_equal ['slackmine_unwatch'], actions.map { |a| a['action_id'] }
    Slackmine.stub(:config, @settings) { assert_equal :unchanged, WORK.update_watch(@issue, @user, true) }
    assert @issue.watched_by?(@user)
    Slackmine.stub(:config, @settings) { assert_equal :saved, WORK.update_watch(@issue, @user, false) }
    refute @issue.watched_by?(@user)
    @issue.define_singleton_method(:valid_watcher?) { |_viewer| false }
    Slackmine.stub(:config, @settings) { assert_equal :restricted, WORK.update_watch(@issue, @user, true) }
    refute @issue.watched_by?(@user)
    @issue.define_singleton_method(:visible?) { |_viewer| false }
    assert_empty capture_interaction(button)
  end

  def test_shared_watch_settings_use_personal_state_and_recheck_configuration
    prepare_action_issue
    @settings['slack']['work_object_buttons'] = { 'watch' => true }
    @issue.define_singleton_method(:watched_by?) { |_viewer| @watching == true }
    @issue.define_singleton_method(:valid_watcher?) { |_viewer| true }
    @issue.define_singleton_method(:set_watcher) { |_viewer, enabled| @watching = enabled }
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_watch' }])
    button['container']['type'] = 'message_attachment'
    calls = capture_interaction(button)
    assert_equal 'views.open', calls.first[0]
    form = calls.first[1]['view']
    assert_equal 'Watch', form.dig('submit', 'text')
    refute @issue.watched_by?(@user)
    submit = action_payload('view_submission', 'view')
    submit['view'] = form
    capture_interaction(submit)
    assert @issue.watched_by?(@user)
    capture_interaction(submit)
    assert @issue.watched_by?(@user), 'Repeated submission must not toggle the state'
    form = capture_interaction(button).first[1]['view']
    assert_equal 'Unwatch', form.dig('submit', 'text')
    submit['view'] = form
    @settings['slack']['work_object_buttons']['watch'] = false
    assert_empty capture_interaction(submit)
    assert @issue.watched_by?(@user)
    @settings['slack']['work_object_buttons']['watch'] = true
    capture_interaction(submit)
    refute @issue.watched_by?(@user)
  end

  def test_stale_detail_watch_buttons_open_current_personal_settings_without_writing
    prepare_action_issue
    @settings['slack']['work_object_buttons'] = { 'watch' => true }
    @issue.define_singleton_method(:watched_by?) { |_viewer| @watching == true }
    @issue.define_singleton_method(:valid_watcher?) { |_viewer| true }
    @issue.define_singleton_method(:set_watcher) { |_viewer, enabled| @watching = enabled }
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_watch' }])
    @issue.instance_variable_set(:@watching, true)
    form = capture_interaction(button).first[1]['view']
    assert_equal 'Unwatch', form.dig('submit', 'text')
    assert @issue.watched_by?(@user)
    submit = action_payload('view_submission', 'view')
    submit['view'] = form
    capture_interaction(submit)
    refute @issue.watched_by?(@user)
    button['actions'][0]['action_id'] = 'slackmine_unwatch'
    form = capture_interaction(button).first[1]['view']
    assert_equal 'Watch', form.dig('submit', 'text')
    refute @issue.watched_by?(@user)
    @issue.define_singleton_method(:valid_watcher?) { |_viewer| false }
    assert_empty capture_interaction(button)
  end

  def test_description_edit_preserves_raw_text_and_saves_with_journal
    prepare_action_issue
    @issue.description = "  # Heading\n\nOriginal body\n "
    field = capture_details.first[1].dig('metadata', 'entity_payload', 'fields', 'description')
    assert_equal @issue.description, field['value']
    assert_equal true, field.dig('edit', 'enabled')
    modal = WORK.edit_modal(@issue, @user, {})
    assert_equal @issue.description, modal['blocks'].find { |block| block['block_id'] == 'description' }.dig('element', 'initial_value')
    submission = action_payload('view_submission', 'view')
    submission['view']['state'] = { 'values' => { 'description' => { 'description.input' => { 'value' => "Changed\n本文" } } } }
    capture_interaction(submission)
    assert_equal "Changed\n本文", @issue.description
    assert_equal [:journal, :attributes], @issue.events
    count = @issue.events.length
    capture_interaction(submission)
    assert_equal count, @issue.events.length
    submission['view']['state']['values']['description']['description.input']['value'] = nil
    capture_interaction(submission)
    assert_equal '', @issue.description
    field = capture_details.first[1].dig('metadata', 'entity_payload', 'fields', 'description')
    assert_equal '', field['value']
    assert_equal true, field.dig('edit', 'enabled')
  end

  def test_description_edit_preserves_body_when_expected_input_value_is_missing
    prepare_action_issue
    @issue.description = 'Original description'
    native = action_payload('view_submission', 'view')
    modal = action_payload('view_submission', 'view')
    modal['view'] = WORK.edit_modal(@issue, @user, native['view'])
    [[native, 'description.input'], [modal, 'description']].each do |submission, action_id|
      [{}, { 'unexpected.input' => { 'value' => 'Other input' } }, { action_id => {} }].each do |block|
        submission['view']['state'] = { 'values' => { 'description' => block } }
        capture_interaction(submission)
        assert_equal 'Original description', @issue.description
        assert_empty @issue.events
      end
      submission['view']['state']['values']['description'] = { action_id => { 'value' => nil } }
      capture_interaction(submission)
      assert_equal '', @issue.description
      @issue.description = 'Original description'
      @issue.instance_variable_set(:@events, [])
    end
    native['view']['state'] = { 'values' => {
      'description' => {},
      'status' => { 'status.input' => { 'selected_option' => { 'value' => '3' } } }
    } }
    capture_interaction(native)
    assert_equal 3, @issue.status_id
    assert_equal 'Original description', @issue.description
    assert_equal [:journal, :attributes], @issue.events
  end

  def test_description_edit_rechecks_permission_and_never_saves_a_truncated_long_body
    prepare_action_issue
    @issue.description = 'Original'
    @issue.define_singleton_method(:safe_attribute?) { |attribute, _viewer| attribute != 'description' }
    refute capture_details.first[1].dig('metadata', 'entity_payload', 'fields', 'description').key?('edit')
    Slackmine.stub(:config, @settings) { assert_equal :restricted, WORK.update_issue(@issue, @user, description: 'Forbidden') }
    assert_equal 'Original', @issue.description
    @issue.define_singleton_method(:safe_attribute?) { |*| true }
    @issue.description = 'あ' * 3001
    refute capture_details.first[1].dig('metadata', 'entity_payload', 'fields', 'description').key?('edit')
    refute WORK.edit_modal(@issue, @user, {})['blocks'].any? { |block| block['block_id'] == 'description' }
    Slackmine.stub(:config, @settings) { assert_equal :restricted, WORK.update_issue(@issue, @user, description: 'Shortened') }
    assert_equal 3001, @issue.description.length
    assert_empty @issue.events
    @issue.description = 'Original'
    Slackmine.stub(:config, @settings) { assert_equal :restricted, WORK.update_issue(@issue, @user, description: 'a' * 3001) }
    assert_equal 'Original', @issue.description
  end

  def test_description_modal_submission_and_comment_form_isolation
    prepare_action_issue
    @issue.description = 'Original'
    form = WORK.edit_modal(@issue, @user, action_payload('block_actions', 'container')['container'])
    form['state'] = { 'values' => { 'description' => { 'description' => { 'value' => 'Modal update' } } } }
    submission = action_payload('view_submission', 'view')
    submission['view'] = form
    capture_interaction(submission)
    assert_equal 'Modal update', @issue.description
    form['callback_id'] = 'slackmine_add_comment'
    form['state']['values'] = { 'description' => { 'description' => { 'value' => 'Must not change' } },
                              'new_comment' => { 'new_comment' => { 'value' => 'Only a comment' } } }
    capture_interaction(submission)
    assert_equal 'Modal update', @issue.description
    assert_equal 'Only a comment', @issue.notes.last
  end

  def test_detail_edit_action_opens_the_issue_modal
    prepare_action_issue
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_edit_issue' }])
    calls = capture_interaction(button)
    assert_equal 'views.open', calls.first[0]
    assert_equal 'slackmine_edit_issue', calls.first[1].dig('view', 'callback_id')
    refute_empty calls.first[1].dig('view', 'blocks')
    @issue.define_singleton_method(:attributes_editable?) { |_viewer| false }
    assert_empty capture_interaction(button)
  end

  def test_assign_to_me_is_hidden_when_already_assigned_to_viewer
    prepare_action_issue
    @issue.assigned_to_id = @user.id
    metadata = capture_details.first[1]['metadata']
    assert_equal ['slackmine_edit_issue'], metadata.dig('entity_payload', 'actions', 'primary_actions').map { |action| action['action_id'] }
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_assign_to_me' }])
    capture_interaction(button)
    assert_empty @issue.events
    assert_equal @user.id, @issue.assigned_to_id

    @issue.assigned_to_id = nil
    metadata = capture_details.first[1]['metadata']
    assert_equal %w[slackmine_edit_issue slackmine_assign_to_me], metadata.dig('entity_payload', 'actions', 'primary_actions').map { |action| action['action_id'] }
  end

  def test_assignee_picker_and_details_allow_unassignment_and_recheck_permissions
    prepare_action_issue
    @issue.assigned_to_id = @user.id
    fields = capture_details.first[1].dig('metadata', 'entity_payload', 'fields')
    assert_equal 'string', fields.dig('assignee', 'type')
    refute fields['assignee'].key?('user')
    assert_equal @user.id.to_s, fields.dig('assignee', 'edit', 'select', 'current_value')
    assert_equal ['none', @user.id.to_s], fields.dig('assignee', 'edit', 'select', 'static_options').map { |o| o['value'] }
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_edit_assignee' }])
    button['container'].merge!('type' => 'message_attachment', 'channel_id' => 'C123', 'message_ts' => '123.456')
    calls = capture_interaction(button)
    assert_equal 'views.open', calls.first[0]
    assert_equal ['assignee'], calls.first[1].dig('view', 'blocks').map { |b| b['block_id'] }
    edit = action_payload('view_submission', 'view')
    edit['view']['state'] = { 'values' => { 'assignee' => { 'assignee.input' => { 'selected_option' => { 'value' => 'none' } } } } }
    capture_interaction(edit)
    assert_nil @issue.assigned_to_id
    fields = capture_details.first[1].dig('metadata', 'entity_payload', 'fields')
    assert_equal 'Unassigned', fields.dig('assignee', 'value')
    selection = edit['view']['state']['values']['assignee']['assignee.input']['selected_option']
    selection['value'] = @user.id.to_s
    capture_interaction(edit)
    assert_equal @user.id, @issue.assigned_to_id
    selection['value'] = '999'
    calls = capture_interaction(edit)
    assert_equal @user.id, @issue.assigned_to_id
    assert_equal 'edit_error', calls.first[1].dig('error', 'status')
    @issue.define_singleton_method(:safe_attribute?) { |attribute, _viewer| attribute != 'assigned_to_id' }
    assert_empty capture_interaction(button)
    refute capture_details.first[1].dig('metadata', 'entity_payload', 'fields', 'assignee', 'edit')
  end

  def test_disallowed_status_and_unmapped_user_cannot_edit
    prepare_action_issue
    edit = action_payload('view_submission', 'view')
    edit['view']['state'] = { 'values' => {
      'status' => { 'status.input' => { 'selected_option' => { 'value' => '999' } } },
      'new_comment' => { 'new_comment.input' => { 'value' => 'Must not save' } }
    } }
    calls = capture_interaction(edit)
    assert_equal 2, @issue.status_id
    assert_empty @issue.notes
    assert_equal 'edit_error', calls.first[1].dig('error', 'status')
    edit['user']['id'] = 'U999'
    assert_empty capture_interaction(edit)
  end

  def test_main_card_opens_modal_and_saves_priority_due_date_and_status
    @settings['slack']['work_object_fields'] = { 'priority' => true }
    prepare_action_issue
    click = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_edit_issue' }])
    click['container'].merge!('type' => 'message_attachment', 'channel_id' => 'C123', 'message_ts' => '123.456')
    calls = capture_interaction(click)
    assert_equal 'views.open', calls.first[0]
    modal = calls.first[1]['view']
    assert_equal 'slackmine_edit_issue', modal['callback_id']
    assert_equal '2026-10-10', modal['blocks'].find { |block| block['block_id'] == 'due_date' }.dig('element', 'initial_date')
    assert_equal '4', modal['blocks'].find { |block| block['block_id'] == 'priority' }.dig('element', 'initial_option', 'value')

    edit = action_payload('view_submission', 'view')
    edit['view'] = { 'type' => 'modal', 'callback_id' => 'slackmine_edit_issue',
                     'private_metadata' => modal['private_metadata'], 'state' => { 'values' => {
                       'status' => { 'status' => { 'selected_option' => { 'value' => '3' } } },
                       'priority' => { 'priority' => { 'selected_option' => { 'value' => '5' } } },
                       'due_date' => { 'due_date' => { 'selected_date' => '2026-10-12' } },
                       'new_comment' => { 'new_comment' => { 'value' => 'Changed from card' } }
                     } } }
    calls = capture_interaction(edit)
    assert_equal 3, @issue.status_id
    assert_equal 5, @issue.priority_id
    assert_equal Date.new(2026, 10, 12), @issue.due_date
    assert_equal 'Changed from card', @issue.notes.last
    assert_equal %w[conversations.replies chat.update], calls.map(&:first)
    assert_equal 'C123', calls.last[1]['channel']
    assert_equal 'Original notification', calls.last[1]['text']
    assert_equal 'Important', calls.last[1].dig('metadata', 'entities', 0, 'entity_payload', 'fields', 'priority', 'value')
  end

  def test_ephemeral_card_without_entity_identity_opens_edit_and_saves_without_history_refresh
    prepare_action_issue
    @issue.assigned_to_id = @user.id
    click = action_payload('block_actions', 'container', 'actions' => [
      { 'action_id' => 'slackmine_edit_issue', 'value' => 'slackmine_issue:7' }
    ])
    click['container'] = { 'type' => 'message_attachment', 'is_ephemeral' => true,
                           'channel_id' => 'D123', 'message_ts' => '123.456' }
    calls = capture_interaction(click)
    assert_equal ['views.open'], calls.map(&:first)
    modal = calls.first[1]['view']
    assert_equal %w[description status priority assignee due_date new_comment], modal['blocks'].map { |block| block['block_id'] }
    context = JSON.parse(modal['private_metadata'])
    assert_equal @url, context['entity_url']
    assert_equal @event['external_ref'], context['external_ref']
    assert_equal true, context['is_ephemeral']
    edit = action_payload('view_submission', 'view')
    edit['view'] = modal.merge('state' => { 'values' => {
      'status' => { 'status' => { 'selected_option' => { 'value' => '3' } } },
      'new_comment' => { 'new_comment' => { 'value' => 'Edited from private result' } }
    } })
    assert_empty capture_interaction(edit)
    assert_equal 3, @issue.status_id
    assert_equal ['Edited from private result'], @issue.notes
  end

  def test_ephemeral_button_identity_requires_valid_value_and_existing_authorization
    prepare_action_issue
    click = action_payload('block_actions', 'container', 'actions' => [
      { 'action_id' => 'slackmine_edit_issue', 'value' => 'slackmine_issue:7' }
    ])
    click['container'] = { 'type' => 'message_attachment', 'is_ephemeral' => true }
    click['actions'].first['value'] = 'slackmine_issue:7 trailing'
    assert_empty capture_interaction(click)
    click['actions'].first['value'] = 'slackmine_issue:7'
    click['container']['is_ephemeral'] = false
    assert_empty capture_interaction(click)
    click['container']['is_ephemeral'] = true
    click['user']['id'] = 'U999'
    assert_empty capture_interaction(click)
    click['user']['id'] = 'U123'
    @settings['slack']['work_object_actions'] = false
    assert_empty capture_interaction(click)
    @settings['slack']['work_object_actions'] = true
    @issue.define_singleton_method(:visible?) { |_| false }
    assert_empty capture_interaction(click)
    assert_empty @issue.notes
  end

  def test_work_object_buttons_carry_identity_for_ephemeral_interactions
    prepare_action_issue
    Slackmine.stub(:config, @settings) do
      actions = WORK.configured_actions(@issue)['primary_actions']
      assert_equal ['slackmine_issue:7'], actions.map { |action| action['value'] }.uniq
    end
  end

  def test_main_card_modal_can_assign_and_clear_assignee
    prepare_action_issue
    @issue.assigned_to_id = nil
    @issue.assigned_to = nil
    click = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_edit_issue' }])
    click['container'].merge!('type' => 'message_attachment', 'channel_id' => 'C123', 'message_ts' => '123.456')
    modal = capture_interaction(click).first[1]['view']
    assignee = modal['blocks'].find { |block| block['block_id'] == 'assignee' }
    assert_equal %w[none 3], assignee.dig('element', 'options').map { |option| option['value'] }
    assert_equal 'none', assignee.dig('element', 'initial_option', 'value')

    edit = action_payload('view_submission', 'view')
    edit['view'] = { 'type' => 'modal', 'callback_id' => 'slackmine_edit_issue',
                     'private_metadata' => modal['private_metadata'],
                     'state' => { 'values' => { 'assignee' => { 'assignee' => {
                       'selected_option' => { 'value' => '3' }
                     } } } } }
    calls = capture_interaction(edit)
    assert_equal 3, @issue.assigned_to_id
    assert_equal 'chat.update', calls.last[0]
    edit['view']['state']['values']['assignee']['assignee']['selected_option']['value'] = 'none'
    capture_interaction(edit)
    assert_nil @issue.assigned_to_id
  end

  def test_main_card_assignment_refreshes_card_without_opening_detail_pane
    prepare_action_issue
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_assign_to_me' }])
    button['container'].merge!('type' => 'message_attachment', 'channel_id' => 'C123', 'message_ts' => '123.456')
    calls = capture_interaction(button)
    assert_equal 3, @issue.assigned_to_id
    assert_equal %w[conversations.replies chat.update], calls.map(&:first)
  end

  def test_card_update_is_queued_after_saving
    prepare_action_issue
    button = action_payload('block_actions', 'container', 'actions' => [{ 'action_id' => 'slackmine_assign_to_me' }])
    button['container'].merge!('type' => 'message_attachment', 'channel_id' => 'C123', 'message_ts' => '123.456')
    calls = capture_interaction(button, drain: false)
    assert_equal 3, @issue.assigned_to_id
    assert_empty calls
    assert_equal 1, @refresh_jobs.size
    assert_equal 'saved', @refresh_jobs.first[-2]
  end

  def test_deferred_detail_edit_sends_result_without_expired_detail_trigger
    prepare_action_issue
    edit = action_payload('view_submission', 'view')
    edit['view']['state'] = { 'values' => { 'new_comment' => { 'new_comment.input' => { 'value' => 'Example note' } } } }
    edit['deferred'] = true
    calls = capture_interaction(edit)
    assert_equal 'Example note', @issue.notes.last
    assert_equal ['chat.postMessage'], calls.map(&:first)
    assert_equal 'U123', calls.first[1]['channel']
  end

  def test_failed_card_refresh_does_not_retry_saved_comment
    prepare_action_issue
    edit = action_payload('view_submission', 'view')
    edit['view'] = { 'type' => 'modal', 'callback_id' => 'slackmine_edit_issue',
                     'private_metadata' => JSON.generate(@event.slice('entity_url', 'external_ref').merge(
                       'channel_id' => 'C123', 'message_ts' => '123.456')),
                     'state' => { 'values' => { 'new_comment' => { 'new_comment' => { 'value' => 'Once' } } } } }
    Slackmine.stub(:config, @settings) do
      Issue.stub(:find_by, @issue) do
        User.stub(:find_by, @user) do
          Slackmine.stub(:slack_api, ->(method, *) {
            method == 'conversations.replies' ? { 'messages' => [{ 'ts' => '123.456', 'text' => 'Original notification' }] } : raise(StandardError, 'refresh failed')
          }) do
            WORK.process_interaction('ATEST', 'TTEST', edit)
          end
        end
      end
    end
    assert_equal ['Once'], @issue.notes
  end

  def test_invalid_priority_and_date_do_not_write
    prepare_action_issue
    Slackmine.stub(:config, @settings) do
      assert_equal :restricted, WORK.update_issue(@issue, @user, priority_id: '999')
      assert_equal :restricted, WORK.update_issue(@issue, @user, due_date: '2026-02-30')
      assert_equal 4, @issue.priority_id
      assert_equal Date.new(2026, 10, 10), @issue.due_date
      assert_empty @issue.events
      assert_equal :saved, WORK.update_issue(@issue, @user, due_date: '')
      assert_nil @issue.due_date
    end
  end
end

class NotificationDisplaySettingsTest < Minitest::Test
  def with_custom_change_format(issue, resolved)
    view = Object.new
    view.define_singleton_method(:format_object) do |value, html:|
      raise 'HTML must be disabled' if html
      render = ->(item) { item == true ? 'Yes' : item == false ? 'No' : item.to_s }
      value.is_a?(Array) ? value.map(&render).join(', ') : render.call(value)
    end
    format = Object.new
    custom_field = OpenStruct.new(id: 42, name: '顧客ID', format: format)
    format.define_singleton_method(:formatted_value) do |helper, field, raw, customized, html|
      raise 'Wrong display context' unless helper.equal?(view) && field.equal?(custom_field) &&
                                          customized.equal?(issue) && html == false
      resolved.fetch(raw)
    end
    CustomField.stub(:find_by, custom_field) do
      ApplicationController.stub(:helpers, view) { yield }
    end
  end

  def test_custom_field_change_values_resolve_add_update_remove_multiple_and_boolean
    issue = OpenStruct.new
    cases = [
      [nil, '19', 'None → TELESIGHT[019]'],
      ['18', '19', 'Previous &amp; customer → TELESIGHT[019]'],
      ['19', '', 'TELESIGHT[019] → None'],
      [['18', '19'], ['19'], 'Previous &amp; customer, TELESIGHT[019] → TELESIGHT[019]'],
      ['0', '1', 'No → Yes'],
      ['', '0', 'None → No'],
      ['7', '8', '7 → 8']
    ]
    resolved = { '18' => 'Previous & customer', '19' => 'TELESIGHT[019]',
                 ['18', '19'] => ['Previous & customer', 'TELESIGHT[019]'],
                 ['19'] => ['TELESIGHT[019]'], '0' => false, '1' => true, '7' => 7, '8' => 8 }
    with_custom_change_format(issue, resolved) do
      cases.each do |old_value, value, expected|
        detail = OpenStruct.new(property: 'cf', prop_key: '42', old_value: old_value, value: value)
        assert_equal [['顧客ID', expected]], Slackmine::Formatter.change_fields(issue, [detail])
      end
    end
  end

  def test_custom_field_changes_use_journal_values_in_issue_and_comment_notifications
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '',
                           project: OpenStruct.new(name: 'Agentic'), tracker: OpenStruct.new(name: 'Task'))
    # The issue may have changed again since this journal was recorded.
    issue.visible_custom_field_values = [OpenStruct.new(custom_field: nil, value: '20')]
    detail = OpenStruct.new(property: 'cf', prop_key: '42', old_value: nil, value: '19')
    with_custom_change_format(issue, { '19' => 'TELESIGHT[019]' }) do
      payloads = [Slackmine::Formatter.issue_payload(issue, actor: nil, action: 'updated', details: [detail]),
                  Slackmine::Formatter.journal_payload(issue, actor: nil, notes: 'Comment', details: [detail])]
      payloads.each do |payload|
        fields = payload.dig('attachments', 0, 'blocks').flat_map { |block| block.fetch('fields', []) }
        assert_includes fields.map { |field| field['text'] }, "*顧客ID*\nNone → TELESIGHT[019]"
      end
    end
  end

  def test_deleted_custom_fields_keep_raw_change_values
    detail = OpenStruct.new(property: 'cf', prop_key: '42', old_value: '18', value: '19')
    CustomField.stub(:find_by, nil) do
      assert_equal [['42', '18 → 19']], Slackmine::Formatter.change_fields(OpenStruct.new, [detail])
    end
  end

  def test_custom_metadata_resolves_records_and_booleans_without_html
    view = Object.new
    view.define_singleton_method(:format_object) do |value, html:|
      raise 'HTML must be disabled' if html
      render = ->(item) { item == true ? 'Yes' : item == false ? 'No' : item.to_s }
      value.is_a?(Array) ? value.map(&render).join(', ') : render.call(value)
    end
    record = Struct.new(:name) { def to_s; name; end }
    cases = [
      ['33', record.new('Payment option')],
      ['57', record.new('Bank & account')],
      [['33', '57'], [record.new('Payment option'), record.new('Bank & account')]],
      ['0', false], ['1', true], ['1', 1], ['text', 'text']
    ]
    expected = ['Payment option', 'Bank & account', 'Payment option, Bank & account', 'No', 'Yes', '1', 'text']
    cases.zip(expected).each do |(raw, resolved), label|
      format = Object.new
      format.define_singleton_method(:formatted_custom_value) do |helper, custom_value, html|
        raise 'Wrong display context' unless helper.equal?(view) && custom_value.value == raw && html == false
        resolved
      end
      value = OpenStruct.new(custom_field: OpenStruct.new(format: format), value: raw)
      assert_equal label, Slackmine::Formatter.custom_field_value_text(value, view: view)
    end
    # Unset fields must not become false/No or invoke a record lookup.
    value = OpenStruct.new(custom_field: nil, value: '')
    assert_equal '', Slackmine::Formatter.custom_field_value_text(value, view: view)
  end

  def test_optional_issue_metadata_includes_selected_version_relation_and_custom_field
    project = OpenStruct.new(name: 'Agentic')
    related = OpenStruct.new(id: 12, subject: 'Related & visible')
    private_issue = OpenStruct.new(id: 13, subject: 'Private')
    private_issue.define_singleton_method(:is_private?) { true }
    relation = OpenStruct.new
    relation.define_singleton_method(:other_issue) { |_issue| related }
    relation.define_singleton_method(:relation_type_for) { |_issue| 'relates' }
    values = [
      OpenStruct.new(custom_field: OpenStruct.new(id: 42, name: 'Customer'), value: 'Acme'),
      OpenStruct.new(custom_field: OpenStruct.new(id: 43, name: 'Internal'), value: 'Hidden')
    ]
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'),
                           fixed_version: OpenStruct.new(name: 'Release 2'),
                           relations: [relation], children: [private_issue])
    issue.define_singleton_method(:visible_custom_field_values) { values }
    no_changes = []
    no_changes.define_singleton_method(:present?) { false }
    settings = { 'slack' => { 'metadata' => { 'issue' => {
      'target_version' => true, 'relations' => true, 'children' => true,
      'custom_fields' => { 'default' => false, '42' => true }
    } } } }

    Slackmine.stub(:config, settings) do
      Slackmine::Formatter.stub(:change_fields, no_changes) do
        blocks = Slackmine::Formatter.issue_payload(issue, actor: OpenStruct.new(name: 'Alice'), action: 'created')
                                            .dig('attachments', 0, 'blocks')
        fields = blocks.flat_map { |block| block.fetch('fields', []) }.map { |entry| entry.fetch('text') }
        assert fields.any? { |value| value == "*Target version*\nRelease 2" }
        assert fields.any? { |value| value.include?('Related &amp; visible') }
        assert fields.any? { |value| value == "*Customer*\nAcme" }
        refute fields.any? { |value| value.include?('Internal') || value.include?('Private') }
      end
    end
  end

  def test_additional_issue_metadata_is_opt_in_by_default
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '',
                           project: OpenStruct.new(name: 'Agentic'), tracker: OpenStruct.new(name: 'Task'),
                           fixed_version: OpenStruct.new(name: 'Release 2'))
    no_changes = []
    no_changes.define_singleton_method(:present?) { false }

    Slackmine.stub(:config, {}) do
      Slackmine::Formatter.stub(:change_fields, no_changes) do
        fields = Slackmine::Formatter.issue_payload(
          issue, actor: OpenStruct.new(name: 'Alice'), action: 'created'
        ).dig('attachments', 0, 'blocks').flat_map { |block| block.fetch('fields', []) }
        assert_equal 5, fields.length
        refute fields.any? { |entry| entry.fetch('text').include?('Release 2') }
      end
    end
  end

  def test_updated_issue_metadata_shows_enabled_unset_and_custom_fields
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '', status: nil, fixed_version: nil,
                           project: OpenStruct.new(name: 'Agentic'), tracker: OpenStruct.new(name: 'Task'))
    issue.define_singleton_method(:visible_custom_field_values) do
      [OpenStruct.new(custom_field: OpenStruct.new(id: 42, name: 'Customer'), value: '')]
    end
    settings = { 'slack' => { 'metadata' => { 'issue' => {
      'project' => false, 'updater' => false, 'tracker' => false, 'category' => false, 'priority' => false,
      'status' => true, 'target_version' => true,
      'custom_fields' => { 'default' => false, '42' => true }
    } } } }

    Slackmine.stub(:config, settings) do
      %w[created updated].each do |action|
        fields = Slackmine::Formatter.issue_payload(
          issue, actor: nil, action: action
        ).dig('attachments', 0, 'blocks').flat_map { |block| block.fetch('fields', []) }
        assert_equal ["*Status*\nNot set", "*Target version*\nNot set", "*Customer*\nNot set"],
                     fields.map { |entry| entry['text'] }, action
      end
    end
  end

  def test_updated_issue_metadata_shows_current_values_independent_of_changed_fields
    value = ->(string) { PresenceValue.new(string) }
    details = [
      OpenStruct.new(property: 'attr', prop_key: 'fixed_version_id', old_value: value.call('1'), value: value.call('2')),
      OpenStruct.new(property: 'attr', prop_key: 'description', old_value: value.call('before'), value: value.call('after'))
    ]
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: 'after',
                           project: OpenStruct.new(name: 'Agentic'), tracker: OpenStruct.new(name: 'Task'),
                           status: OpenStruct.new(name: 'In progress'),
                           fixed_version: OpenStruct.new(name: 'Release 2'))
    settings = { 'slack' => { 'metadata' => { 'issue' => {
      'project' => false, 'status' => true, 'target_version' => true
    } } } }

    Slackmine.stub(:config, settings) do
      heading = ->(block) { block['text']['text'] if block['text'].is_a?(Hash) }
      payload = Slackmine::Formatter.issue_payload(
        issue, actor: OpenStruct.new(name: 'Alice'), action: 'updated', details: details
      )
      blocks = payload.dig('attachments', 0, 'blocks')
      fields = blocks.flat_map { |block| block.fetch('fields', []) }.map { |entry| entry.fetch('text') }
      assert fields.any? { |field| field == "*Status*\nIn progress" }
      assert fields.any? { |field| field == "*Target version*\nRelease 2" }
      assert fields.any? { |field| field.include?('旧版 → Release 2') || field.include?('旧版 → 新版') }
      refute fields.any? { |field| field.start_with?('*Project*') }
      assert blocks.any? { |block| heading.call(block) == '*Metadata*' }
      assert blocks.any? { |block| heading.call(block) == '*Changes*' }

      combined = Slackmine::Formatter.journal_payload(
        issue, actor: OpenStruct.new(name: 'Alice'), notes: 'Comment', details: details
      ).dig('attachments', 0, 'blocks')
      assert combined.any? { |block| heading.call(block) == '*Metadata*' }
      assert combined.any? { |block| heading.call(block) == '*Changes*' }
    end
  end

  def test_legacy_issue_metadata_action_maps_remain_readable
    settings = { 'slack' => { 'metadata' => { 'issue' => {
      'created' => { 'project' => true, 'status' => false },
      'updated' => { 'project' => false, 'status' => true }
    } } } }
    Slackmine.stub(:config, settings) do
      assert Slackmine::Formatter.metadata_enabled?('issue', 'project', action: 'created')
      refute Slackmine::Formatter.metadata_enabled?('issue', 'project', action: 'updated')
      assert Slackmine::Formatter.metadata_enabled?('issue', 'status', action: 'updated')
    end
  end

  def test_hidden_issue_changes_switch_keeps_visible_changes_and_description_diff
    value = ->(string) { PresenceValue.new(string) }
    details = [
      OpenStruct.new(property: 'attr', prop_key: 'description', old_value: value.call('before'), value: value.call('after')),
      OpenStruct.new(property: 'attr', prop_key: 'fixed_version_id', old_value: value.call('1'), value: value.call('2')),
      OpenStruct.new(property: 'attr', prop_key: 'status_id', old_value: value.call('1'), value: value.call('2'))
    ]
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: 'after',
                           project: OpenStruct.new(name: 'Agentic'), tracker: OpenStruct.new(name: 'Task'),
                           fixed_version: OpenStruct.new(name: 'Release 2'), status: OpenStruct.new(name: 'Closed'))
    settings = { 'slack' => { 'issue_changes_when_hidden' => false,
                              'metadata' => { 'issue' => { 'target_version' => true, 'status' => false } } } }

    Slackmine.stub(:config, settings) do
      heading = ->(block) { block['text']['text'] if block['text'].is_a?(Hash) }
      [Slackmine::Formatter.issue_payload(issue, actor: nil, action: 'updated', details: details),
       Slackmine::Formatter.journal_payload(issue, actor: nil, notes: 'Comment', details: details)].each do |payload|
        blocks = payload.dig('attachments', 0, 'blocks')
        assert blocks.flat_map { |block| block.fetch('fields', []) }
                     .any? { |field| field['text'] == "*Target version*\nRelease 2" }
        assert blocks.any? { |block| heading.call(block) == '*Changes*' }
        assert blocks.any? { |block| block['type'] == 'markdown' && block['text'].include?('diff') }
        change_fields = blocks.flat_map { |block| block.fetch('fields', []) }.map { |field| field['text'] }
        assert change_fields.any? { |field| field.start_with?('*Target version*') && field.include?('→') }
        refute change_fields.any? { |field| field.start_with?('*Status*') }
      end
      combined_blocks = Slackmine::Formatter.journal_payload(
        issue, actor: nil, notes: 'Comment', details: details
      ).dig('attachments', 0, 'blocks')
      assert combined_blocks.any? { |block| heading.call(block).to_s.include?('Comment') }
    end
  end

  def test_metadata_fields_can_be_hidden_independently_for_every_notification_type
    settings = { 'slack' => { 'metadata' => {
      'issue' => { 'project' => false }, 'wiki' => { 'location' => false },
      'news' => { 'updater' => false }, 'news_comment' => { 'project' => false },
      'time_entry' => { 'hours' => false }, 'version' => { 'due_date' => false },
      'project' => { 'updater' => false }
    } } }
    project = OpenStruct.new(name: 'Agentic', identifier: 'agentic')
    actor = OpenStruct.new(name: 'Alice')
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    no_changes = []
    no_changes.define_singleton_method(:present?) { false }
    metadata = lambda do |payload|
      payload.dig('attachments', 0, 'blocks').flat_map { |block| block.fetch('fields', []) }
             .map { |entry| entry.fetch('text') }
    end

    Slackmine.stub(:config, settings) do
      Slackmine::Formatter.stub(:change_fields, no_changes) do
        fields = metadata.call(Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'created'))
        refute fields.any? { |value| value.start_with?('*Project*') }
        assert fields.any? { |value| value.start_with?('*Tracker*') }
      end

      wiki = OpenStruct.new(page: OpenStruct.new(title: 'Home'), comments: '')
      fields = metadata.call(Slackmine::Formatter.wiki_payload(wiki, project, actor: actor, action: 'updated'))
      refute fields.any? { |value| value.start_with?('*Changed location*') }
      assert fields.any? { |value| value.start_with?('*Project*') }

      cases = {
        'News' => { hidden: '*Updated by*', visible: '*Project*' },
        'News comment' => { hidden: '*Project*', visible: '*Updated by*' },
        'Time entry' => { hidden: '*Hours*', visible: '*Spent on*', fields: [['hours', '2h'], ['spent_on', '2026-09-29']] },
        'Version' => { hidden: '*Due date*', visible: '*Status*', fields: [['status', 'open'], ['due_date', '2026-10-01']] },
        'Project' => { hidden: '*Updated by*', visible: '*Project*' }
      }
      cases.each do |noun, checks|
        fields = metadata.call(Slackmine::Formatter.generic_payload(
          noun: noun, action: 'updated', subject: noun, url: 'https://example.com',
          project: project, actor: actor, fields: checks.fetch(:fields, [])
        ))
        refute fields.any? { |value| value.start_with?(checks[:hidden]) }, noun
        assert fields.any? { |value| value.start_with?(checks[:visible]) }, noun
      end
    end
  end

  def test_metadata_section_disappears_when_its_group_or_all_fields_are_disabled
    project = OpenStruct.new(name: 'Agentic')
    actor = OpenStruct.new(name: 'Alice')
    settings = { 'slack' => { 'metadata' => {
      'news' => false, 'project' => { 'project' => false, 'updater' => false }
    } } }

    Slackmine.stub(:config, settings) do
      %w[News Project].each do |noun|
        blocks = Slackmine::Formatter.generic_payload(
          noun: noun, action: 'updated', subject: noun, url: 'https://example.com',
          project: project, actor: actor
        ).dig('attachments', 0, 'blocks')
        refute blocks.any? { |block| block.dig('text', 'text') == '*Metadata*' }, noun
        refute blocks.any? { |block| block['type'] == 'divider' }, noun
      end
    end
  end

  def test_issue_update_heading_shows_actor_in_both_notification_paths
    project = OpenStruct.new(name: 'Agentic')
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    actor = OpenStruct.new(name: 'Alice')
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }

    Slackmine::Formatter.stub(:change_fields, empty_changes) do
      updated = Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'updated')
      created = Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'created')
      combined = Slackmine::Formatter.journal_payload(
        issue, actor: actor, notes: '', details: [OpenStruct.new(property: 'attr', prop_key: 'status_id')]
      )
      assert_equal '🔄 Alice *Issue updated*', updated.dig('attachments', 0, 'blocks', 0, 'text', 'text')
      assert_equal '🔄 Alice *Issue updated*', combined.dig('attachments', 0, 'blocks', 0, 'text', 'text')
      assert_equal '🆕 Alice *Issue created*', created.dig('attachments', 0, 'blocks', 0, 'text', 'text')
    end

    Slackmine.stub(:config, { 'messages' => { 'templates' => {
      'issue_updated_header' => '*%{event}* by %{actor}'
    } } }) do
      Slackmine::Formatter.stub(:change_fields, empty_changes) do
        customized = Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'updated')
        assert_equal '🔄 *Issue updated* by Alice', customized.dig('attachments', 0, 'blocks', 0, 'text', 'text')
      end
    end
  end

  def test_issue_metadata_is_shown_on_creation_and_updates_but_not_comments
    project = OpenStruct.new(name: 'Agentic')
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    actor = OpenStruct.new(name: 'Alice')
    changes = [[Slackmine::Formatter.field_label('status'), 'Open → Closed']]
    changes.define_singleton_method(:present?) { true }
    no_changes = []
    no_changes.define_singleton_method(:present?) { false }

    Slackmine::Formatter.stub(:change_fields, no_changes) do
      created = Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'created')
      removed = Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'deleted')
      comment_only = Slackmine::Formatter.journal_payload(issue, actor: actor, notes: 'Comment')
      assert created.dig('attachments', 0, 'blocks').any? { |block| block.dig('text', 'text') == '*Metadata*' }
      [removed, comment_only].each do |message|
        refute message.dig('attachments', 0, 'blocks').any? { |block| block.dig('text', 'text') == '*Metadata*' }
      end
    end

    Slackmine::Formatter.stub(:change_fields, changes) do
      updated = Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'updated')
      commented = Slackmine::Formatter.journal_payload(
        issue, actor: actor, notes: 'Comment', details: [OpenStruct.new(property: 'attr', prop_key: 'status_id')]
      )
      [updated, commented].each do |message|
        blocks = message.dig('attachments', 0, 'blocks')
        assert blocks.any? { |block| block.dig('text', 'text') == '*Metadata*' }
        assert blocks.any? { |block| block.dig('text', 'text') == '*Changes*' }
      end
    end
  end

  def test_color_and_message_overrides_apply_to_the_colored_card
    settings = {
      'slack' => { 'attachment_color' => '#12Ab34' },
      'messages' => {
        'events' => { 'news' => { 'updated' => 'News changed' } },
        'icons' => { 'news' => { 'updated' => '🔔' } },
        'sections' => { 'summary' => 'Summary', 'metadata' => 'Details' },
        'fields' => { 'project' => 'Workspace', 'updater' => 'Changed by' },
        'templates' => { 'generic_fallback' => '%{event}: %{subject}' }
      }
    }
    project = OpenStruct.new(name: 'Agentic')
    Slackmine.stub(:config, settings) do
      payload = Slackmine::Formatter.generic_payload(
        noun: 'News', action: 'updated', subject: 'Headline', url: 'https://example.com/news/1',
        project: project, actor: OpenStruct.new(name: 'Alice'), summary: 'Changed text'
      )
      card = payload.fetch('attachments').first
      assert_equal '#12Ab34', card['color']
      assert_equal 'News changed: Headline', card['fallback']
      assert_includes card.dig('blocks', 0, 'text', 'text'), '🔔 Alice *News changed*'
      assert card['blocks'].any? { |block| block.dig('text', 'text').to_s.include?('*Summary*') }
      assert card['blocks'].any? { |block| block.dig('text', 'text').to_s == '*Details*' }
      fields = card['blocks'].flat_map { |block| block.fetch('fields', []) }.map { |field| field['text'] }
      assert fields.any? { |field| field.include?('*Workspace*') }
      assert fields.any? { |field| field.include?('*Changed by*') }
    end
  end

  def test_invalid_color_and_incomplete_templates_use_safe_defaults
    Slackmine.stub(:config, { 'slack' => { 'attachment_color' => 'blue' },
                                          'messages' => { 'templates' => { 'generic_fallback' => '%{missing}' } } }) do
      payload = Slackmine::Formatter.generic_payload(
        noun: 'Project', action: 'updated', subject: 'Agentic', url: 'https://example.com/projects/agentic',
        project: OpenStruct.new(name: 'Agentic'), actor: OpenStruct.new(name: 'Alice')
      )
      assert_equal '#6D5DFB', payload.dig('attachments', 0, 'color')
      assert_equal 'Project updated - Agentic', payload.dig('attachments', 0, 'fallback')
    end
  end

  def test_custom_diff_heading_still_keeps_source_image_reference_literal
    settings = { 'messages' => { 'diff' => { 'heading' => 'Changes in %{label}' },
                                 'sections' => { 'comment' => 'Note' },
                                 'images' => { 'link_label' => 'Picture: %{name}' } } }
    attachment = OpenStruct.new(id: 42, filename: 'screenshot.png')
    Slackmine.stub(:config, settings) do
      block = Slackmine::Formatter.body_diff_blocks('Note', '', '![](screenshot.png)').first
      payload = Slackmine::Formatter.payload('fallback', blocks: [block])
      Journal.stub(:find_by, OpenStruct.new(journalized: Issue.new(1), private_notes?: false, attachments: [attachment])) do
        Slackmine.stub(:upload_image, ->(*) { flunk 'diff image was uploaded' }) do
          Slackmine.add_images(payload, ['screenshot.png'], 1, 'token')
        end
      end
      assert_includes payload.dig('attachments', 0, 'blocks', 0, 'text'), '**Changes in Note**'

      image_payload = Slackmine::Formatter.payload('fallback', blocks: [Slackmine::Formatter.section_text('![](screenshot.png)')])
      Journal.stub(:find_by, OpenStruct.new(journalized: Issue.new(1), private_notes?: false, attachments: [attachment])) do
        Slackmine.stub(:upload_image, nil) do
          Slackmine.add_images(image_payload, ['screenshot.png'], 1, 'token')
        end
      end
      assert_includes image_payload.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'Picture: screenshot.png'
    end
  end

  def test_issue_comment_wiki_and_image_preview_use_custom_wording
    settings = { 'messages' => {
      'events' => { 'issue' => { 'created' => 'Ticket opened' }, 'comment' => { 'deleted' => 'Note removed' },
                    'wiki' => { 'updated' => 'Page revised' } },
      'sections' => { 'comment' => 'Note', 'metadata' => 'Properties' },
      'diff' => { 'heading' => '%{label} changes' },
      'images' => { 'alt' => 'Picture' }
    } }
    project = OpenStruct.new(name: 'Agentic', identifier: 'agentic')
    issue = OpenStruct.new(id: 7, subject: 'Subject', project: project, tracker: OpenStruct.new(name: 'Task'))
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    Slackmine.stub(:config, settings) do
      assert_equal 'Ticket opened', Slackmine::Formatter.event_label('Issue', 'created')
      Slackmine::Formatter.stub(:change_fields, empty_changes) do
        card = Slackmine::Formatter.journal_payload(
          issue, actor: OpenStruct.new(name: 'Editor'), notes: '', comment_action: 'deleted', previous_notes: 'old note'
        ).dig('attachments', 0)
        assert_includes card.dig('blocks', 0, 'text', 'text'), 'Note removed'
        assert card['blocks'].any? { |block| block['type'] == 'markdown' && block['text'].include?('Note changes') }
        refute card['blocks'].any? { |block| block['type'] == 'section' && block.dig('text', 'text') == '*Properties*' }
      end
      wiki = OpenStruct.new(page: OpenStruct.new(title: 'Home'), comments: '')
      wiki_card = Slackmine::Formatter.wiki_payload(wiki, project, actor: OpenStruct.new(name: 'Editor'), action: 'updated').dig('attachments', 0)
      assert_includes wiki_card.dig('blocks', 0, 'text', 'text'), 'Page revised'

      image_payload = Slackmine::Formatter.payload('fallback', blocks: [
        { 'type' => 'image', 'slack_file' => { 'id' => 'F1' }, 'alt_text' => 'Screenshot' }
      ])
      calls = []
      Slackmine.stub(:slack_api, ->(method, body, _token) { calls << [method, body]; { 'ok' => true, 'ts' => '1.2' } }) do
        Slackmine.post_message(image_payload, 'C1', 'token')
      end
      assert_equal 'fallback', calls.first[1]['text']
      assert_equal 'fallback', calls.first[1].dig('blocks', 0, 'text', 'text')
      assert_equal 'Picture', calls.first[1].dig('blocks', 0, 'accessory', 'alt_text')
    end
  end
end

class BodyDiffNotificationTest < Minitest::Test
  def project
    OpenStruct.new(id: 7, identifier: 'agentic', name: 'Agentic')
  end

  def test_yaml_body_diff_setting_defaults_to_true_and_false_disables_it
    Slackmine.stub(:config, {}) do
      assert Slackmine.body_diff_enabled?
    end
    Slackmine.stub(:config, { 'slack' => { 'body_diff' => false } }) do
      refute Slackmine.body_diff_enabled?
      refute Slackmine.body_diff_enabled?(:issue_comment)
      refute Slackmine.body_diff_enabled?(:news_description)
    end
  end

  def test_body_diff_settings_can_be_selected_per_content_type
    settings = { 'slack' => { 'body_diff' => {
      'issue' => { 'description' => true, 'comment' => false },
      'wiki' => { 'body' => false },
      'news' => { 'description' => false, 'comment' => true }
    } } }
    Slackmine.stub(:config, settings) do
      assert Slackmine.body_diff_enabled?(:issue_description)
      refute Slackmine.body_diff_enabled?(:issue_comment)
      refute Slackmine.body_diff_enabled?(:wiki_body)
      refute Slackmine.body_diff_enabled?(:news_description)
      assert Slackmine.body_diff_enabled?(:news_comment)
    end
    Slackmine.stub(:config, { 'slack' => { 'body_diff' => { 'news' => false } } }) do
      refute Slackmine.body_diff_enabled?(:news_description)
      refute Slackmine.body_diff_enabled?(:news_comment)
      assert Slackmine.body_diff_enabled?(:issue_comment)
    end
  end

  def test_document_and_forum_diffs_respect_independent_project_settings
    settings = { 'slack' => { 'body_diff' => { 'document' => { 'description' => true },
                                             'message' => { 'body' => false } } },
                 'projects' => { project.identifier => { 'slack' => { 'body_diff' => {
                   'document' => { 'description' => false }, 'message' => { 'body' => true }
                 } } } } }
    common = { action: 'updated', subject: 'Example', url: 'https://example.com/records/1',
               project: project, actor: OpenStruct.new(name: 'Editor'), body_diff: ['old body', 'new body'] }
    Slackmine.stub(:config, settings) do
      document = Slackmine::Formatter.generic_payload(noun: 'Document', **common).dig('attachments', 0, 'blocks')
      forum = Slackmine::Formatter.generic_payload(noun: 'Message', notes: 'new body', **common).dig('attachments', 0, 'blocks')
      refute document.any? { |block| block['type'] == 'markdown' }
      assert document.any? { |block| block.dig('text', 'text').to_s.include?("*Summary*\nnew body") }
      assert_equal 1, forum.count { |block| block['type'] == 'markdown' && block['text'].include?('+ new body') }
      refute forum.any? { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?('new body') }
    end
    Slackmine.stub(:config, { 'slack' => { 'body_diff' => { 'document' => false, 'message' => false } } }) do
      refute Slackmine.body_diff_enabled?(:document_description)
      refute Slackmine.body_diff_enabled?(:message_body)
      forum = Slackmine::Formatter.generic_payload(noun: 'Message', notes: 'new body', **common).dig('attachments', 0, 'blocks')
      refute forum.any? { |block| block['type'] == 'markdown' }
      assert_equal 1, forum.count { |block| block.dig('text', 'text').to_s.include?('new body') }
      added = Slackmine::Formatter.generic_payload(noun: 'Message', **common.merge(action: 'posted', body_diff: nil, notes: 'new body')).dig('attachments', 0, 'blocks')
      assert_equal 1, added.count { |block| block.dig('text', 'text').to_s.include?('new body') }
    end
    Slackmine.stub(:config, {}) do
      assert Slackmine.body_diff_enabled?(:document_description)
      assert Slackmine.body_diff_enabled?(:message_body)
    end
  end

  def test_mixed_issue_update_uses_separate_comment_and_description_settings
    issue = OpenStruct.new(id: 7098, subject: 'Title', project: project, tracker: OpenStruct.new(name: 'Task'))
    detail = OpenStruct.new(property: 'attr', prop_key: 'description', old_value: 'old body', value: 'new body')
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    settings = { 'slack' => { 'body_diff' => { 'issue' => { 'description' => true, 'comment' => false } } } }
    Slackmine.stub(:config, settings) do
      Slackmine::Formatter.stub(:change_fields, empty_changes) do
        blocks = Slackmine::Formatter.journal_payload(
          issue, actor: OpenStruct.new(name: 'Editor'), notes: 'new note ![](screenshot.png)',
          details: [detail], comment_action: 'updated', previous_notes: 'old note'
        ).dig('attachments', 0, 'blocks')
        assert blocks.any? { |block| block['type'] == 'markdown' && block['text'].include?('+ new body') }
        assert blocks.any? { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?('new note ![](screenshot.png)') }
        assert_equal 1, blocks.count { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?('![](screenshot.png)') }
      end
    end
  end

  def test_wiki_news_body_and_news_comment_use_their_own_settings
    settings = { 'slack' => { 'body_diff' => { 'wiki' => { 'body' => false },
                                             'news' => { 'description' => false, 'comment' => true } } } }
    Slackmine.stub(:config, settings) do
      wiki = OpenStruct.new(page: OpenStruct.new(title: 'Home'), comments: '')
      wiki_blocks = Slackmine::Formatter.wiki_payload(
        wiki, project, actor: OpenStruct.new(name: 'Editor'), action: 'updated', body_diff: ['old', 'new']
      ).dig('attachments', 0, 'blocks')
      assert wiki_blocks.any? { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?("*Body*\nnew") }
      refute wiki_blocks.any? { |block| block['type'] == 'markdown' }

      common = { action: 'updated', subject: 'Headline', url: 'https://example.com/news/1',
                 project: project, actor: OpenStruct.new(name: 'Editor'), body_diff: ['old', 'new'] }
      news_blocks = Slackmine::Formatter.generic_payload(noun: 'News', **common).dig('attachments', 0, 'blocks')
      comment_blocks = Slackmine::Formatter.generic_payload(noun: 'News comment', **common).dig('attachments', 0, 'blocks')
      assert news_blocks.any? { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?("*Summary*\nnew") }
      assert comment_blocks.any? { |block| block['type'] == 'markdown' && block['text'].include?('+ new') }
    end
  end

  def test_full_body_setting_shows_updated_text_for_description_wiki_and_comment
    Slackmine.stub(:config, { 'slack' => { 'body_diff' => false } }) do
      formatter = Slackmine::Formatter
      {
        '説明' => '概要',
        '本文' => '本文',
        'コメント' => '変更後のコメント'
      }.each do |label, heading|
        blocks = formatter.updated_body_blocks(label, 'before', 'after', full_heading: heading)
        assert_equal 'section', blocks.first['type']
        assert_includes blocks.first.dig('text', 'text'), "*#{heading}*\nafter"
        refute_includes blocks.first.dig('text', 'text'), '```diff'
      end
      assert_equal "*本文*\n(empty)", formatter.updated_body_blocks('本文', 'before', '').first.dig('text', 'text')
    end
  end

  def test_body_diff_uses_markdown_diff_fence_and_only_nearby_context
    before = (1..20).map { |number| "unchanged #{number}" }
    after = before.dup
    after[9] = '**new value**'
    block = Slackmine::Formatter.body_diff_blocks('説明', before.join("\n"), after.join("\n")).first

    assert_equal 'markdown', block['type']
    assert_includes block['text'], '```diff'
    assert_includes block['text'], '- unchanged 10'
    assert_includes block['text'], '+ **new value**'
    refute_includes block['text'], "unchanged 1\n"
    assert_includes block['text'], '  …'
    assert_equal '#6D5DFB', Slackmine::Formatter.payload('fallback', blocks: [block]).dig('attachments', 0, 'color')
  end

  def test_edited_issue_comment_renders_only_its_diff
    issue = OpenStruct.new(id: 7098, subject: 'Title', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    message = nil
    Slackmine.stub(:config, {}) do
      Slackmine::Formatter.stub(:change_fields, empty_changes) do
        message = Slackmine::Formatter.journal_payload(
          issue, actor: OpenStruct.new(name: 'Editor'), notes: 'new text',
          comment_action: 'updated', previous_notes: 'old text'
        )
      end
    end

    blocks = message.dig('attachments', 0, 'blocks')
    diff = blocks.find { |block| block['type'] == 'markdown' }
    assert_equal '#6D5DFB', message.dig('attachments', 0, 'color')
    assert_includes diff.fetch('text'), '- old text'
    assert_includes diff.fetch('text'), '+ new text'
    refute blocks.any? { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?('変更後のコメント') }
  end

  def test_edited_issue_comment_can_show_updated_text_instead_of_diff
    issue = OpenStruct.new(id: 7098, subject: 'Title', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    message = nil
    Slackmine.stub(:config, { 'slack' => { 'body_diff' => false } }) do
      Slackmine::Formatter.stub(:change_fields, empty_changes) do
        message = Slackmine::Formatter.journal_payload(
          issue, actor: OpenStruct.new(name: 'Editor'), notes: '1. new text',
          comment_action: 'updated', previous_notes: '1. old text'
        )
      end
    end

    blocks = message.dig('attachments', 0, 'blocks')
    comment = blocks.find { |block| block['type'] == 'markdown' }
    assert_includes comment.fetch('text'), '**Updated comment**'
    assert_includes comment.fetch('text'), '1. new text'
    refute_includes comment.fetch('text'), '- 1. old text'
  end

  def test_deleted_issue_comment_always_shows_removed_lines_even_when_body_diff_is_disabled
    issue = OpenStruct.new(id: 7098, subject: 'Title', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    message = nil
    Slackmine.stub(:config, { 'slack' => { 'body_diff' => false } }) do
      Slackmine::Formatter.stub(:change_fields, empty_changes) do
        message = Slackmine::Formatter.journal_payload(
          issue, actor: OpenStruct.new(name: 'Editor'), notes: '',
          comment_action: 'deleted', previous_notes: "removed text\n![](old.png)"
        )
      end
    end

    blocks = message.dig('attachments', 0, 'blocks')
    diff = blocks.find { |block| block['type'] == 'markdown' }
    assert_includes diff.fetch('text'), '- removed text'
    assert_includes diff.fetch('text'), '- ![](old.png)'
    refute blocks.any? { |block| block['type'] == 'image' }
  end

  def test_body_diff_handles_code_fences_and_slack_markdown_budget
    block = Slackmine::Formatter.body_diff_blocks('本文', '```old', '```new').first
    assert_includes block['text'], '````diff'

    existing = [{ 'type' => 'markdown', 'text' => 'x' * 11_800 }]
    fallback = Slackmine::Formatter.body_diff_blocks('本文', 'old', 'new', blocks: existing).first
    assert_equal 'section', fallback['type']
    assert_operator fallback.dig('text', 'text').length, :<, 3_000
  end

  def test_body_diff_handles_empty_and_normalized_line_endings
    formatter = Slackmine::Formatter
    assert_empty formatter.body_diff_blocks('本文', "same\r\nline", "same\nline")
    removed = formatter.body_diff_blocks('本文', "old\ntext", '').first['text']
    assert_includes removed, '- old'
    assert_includes removed, '- text'
    refute_includes removed, '+ old'
  end

  def test_body_diff_truncates_large_changes_without_exceeding_limit
    before = (1..600).map { |number| "old #{number}" }.join("\n")
    after = (1..600).map { |number| "new #{number}" }.join("\n")
    block = Slackmine::Formatter.body_diff_blocks('本文', before, after).first
    assert_operator block['text'].length, :<, 6_000
    assert_includes block['text'], 'Diff truncated.'
  end

  def test_news_description_change_passes_old_and_new_body
    news = News.new(id: 17, title: 'Release', description: 'new body', project: project)
    news.define_singleton_method(:saved_change_to_description?) { true }
    news.define_singleton_method(:description_before_last_save) { 'old body' }
    news.extend(Slackmine::NewsPatch)
    captured = nil
    formatter = ->(**kwargs) { captured = kwargs; :message }
    Slackmine::Formatter.stub(:generic_payload, formatter) do
      Slackmine.stub(:enqueue, ->(*) {}) do
        news.send(:notify_slack_generic, 'News', 'updated')
      end
    end
    assert_equal ['old body', 'new body'], captured[:body_diff]
  end

  def test_wiki_text_change_passes_old_and_new_body
    content = OpenStruct.new(page: OpenStruct.new(title: 'Home', wiki: OpenStruct.new(project: project)),
                             text: 'new body', comments: '')
    content.define_singleton_method(:saved_change_to_text?) { true }
    content.define_singleton_method(:text_before_last_save) { 'old body' }
    content.extend(Slackmine::WikiContentPatch)
    captured = nil
    formatter = ->(*_args, **kwargs) { captured = kwargs; :message }
    Slackmine::Formatter.stub(:wiki_payload, formatter) do
      Slackmine.stub(:enqueue, ->(*) {}) do
        content.send(:notify_slack_wiki_updated)
      end
    end
    assert_equal ['old body', 'new body'], captured[:body_diff]
  end
end

require_relative '../app/jobs/slackmine_due_digest_job'
require_relative '../app/jobs/slackmine_due_reminder_job'

class DueReminderTest < Minitest::Test
  def setup
    @date_current = Date.method(:current) if Date.respond_to?(:current)
    Date.singleton_class.define_method(:current) { Date.new(2026, 9, 30) }
  end

  def teardown
    if @date_current
      Date.singleton_class.define_method(:current, @date_current)
    else
      Date.singleton_class.remove_method(:current)
    end
  end

  def test_settings_and_project_override
    project = OpenStruct.new(identifier: 'example')
    config = { 'due_reminders' => { 'days' => 3 },
               'projects' => { 'example' => { 'due_reminders' => { 'days' => 7, 'enabled' => false } } } }
    Slackmine.stub(:config, config) do
      assert_equal({ enabled: false, days: 7 }, Slackmine.due_reminder_settings(project))
      assert_equal 7, Slackmine.due_reminder_max_days
    end
  end

  def test_digest_groups_overdue_today_and_upcoming_with_overdue_color
    project = OpenStruct.new(name: 'Example')
    issues = [
      OpenStruct.new(id: 42, subject: 'Fix <problem>', due_date: Date.new(2026, 9, 28), project: project),
      OpenStruct.new(id: 43, subject: 'Due today', due_date: Date.current, project: project),
      OpenStruct.new(id: 44, subject: 'Due soon', due_date: Date.current + 2, project: project)
    ]
    Slackmine::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
      digest = Slackmine::Formatter.due_digest_payload(issues, today: Date.current)
      assert_includes digest.dig('blocks', 0, 'text', 'text'), 'Due reminders: 3'
      assert_equal 3, digest['attachments'].size
      assert_equal ['#D92D20', '#F79009', Slackmine::Formatter.attachment_color],
                   digest['attachments'].map { |attachment| attachment['color'] }
      overdue, current, upcoming = digest['attachments'].map do |attachment|
        attachment['blocks'].map { |block| block.dig('text', 'text') }.join("\n")
      end
      assert_includes overdue, 'Overdue (1)'
      assert_includes overdue, 'Fix &lt;problem&gt;'
      assert_includes overdue, '2d overdue'
      refute_includes overdue, '2026-09-28'
      refute_includes overdue, 'Due today'
      assert_includes current, 'Due today (1)'
      assert_includes current, 'Due today'
      refute_includes current, '2026-09-30'
      refute_includes current, 'Fix &lt;problem&gt;'
      assert_includes upcoming, 'Due soon (1)'
      assert_includes upcoming, 'Due soon'
      assert_includes upcoming, '2d left'
      refute_includes upcoming, '2026-10-02'
    end
  end

  def test_digest_colors_use_yaml_and_project_override
    project = OpenStruct.new(identifier: 'example', name: 'Example')
    issues = [-1, 0, 1].each_with_index.map do |offset, index|
      OpenStruct.new(id: index + 1, subject: "Issue #{index + 1}", due_date: Date.current + offset,
                     project: project)
    end
    config = {
      'slack' => { 'attachment_color' => '#112233' },
      'due_reminders' => { 'colors' => { 'overdue' => '#AABBCC', 'today' => 'orange' } },
      'projects' => { 'example' => { 'due_reminders' => {
        'colors' => { 'today' => '#445566', 'upcoming' => '#778899' }
      } } }
    }
    Slackmine.stub(:config, config) do
      Slackmine::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
        global = Slackmine::Formatter.due_digest_payload(issues, today: Date.current)
        assert_equal ['#AABBCC', '#F79009', '#112233'], global['attachments'].map { |a| a['color'] }

        Slackmine.with_project(project) do
          digest = Slackmine::Formatter.due_digest_payload(issues, today: Date.current)
          assert_equal ['#AABBCC', '#445566', '#778899'], digest['attachments'].map { |a| a['color'] }
        end
      end
    end
  end

  def test_digest_wording_uses_yaml_messages_and_project_override
    project = OpenStruct.new(identifier: 'example', name: 'Example')
    issues = [
      OpenStruct.new(id: 42, subject: 'Late', due_date: Date.current - 2, project: project),
      OpenStruct.new(id: 43, subject: 'Soon', due_date: Date.current + 2, project: project)
    ]
    config = {
      'messages' => { 'due_reminders' => {
        'title' => '*Global %{count} %{suffix}*',
        'part_suffix' => '[%{part}/%{total_parts}]',
        'upcoming_label' => 'Upcoming',
        'upcoming_timing' => '%{days} days left',
        'issue_line' => '<%{url}|#%{id} %{subject}> in %{project}%{timing}',
        'timing_suffix' => ' (%{timing})'
      } },
      'projects' => { 'example' => { 'messages' => { 'due_reminders' => {
        'title' => '*Project %{count} %{suffix}*',
        'fallback' => 'Summary %{count}: %{overdue_count} late, %{today_count} today %{suffix}',
        'overdue_label' => 'Late',
        'group_heading' => '%{label}: %{count}',
        'overdue_timing' => '%{days} days late'
      } } } }
    }
    Slackmine.stub(:config, config) do
      Slackmine::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
        Slackmine.with_project(project) do
          digest = Slackmine::Formatter.due_digest_payload(issues, today: Date.current,
                                                                           part: 2, total_parts: 3)
          assert_equal 'Summary 2: 1 late, 0 today [2/3]', digest['text']
          assert_equal '*Project 2 [2/3]*', digest.dig('blocks', 0, 'text', 'text')
          assert_equal ['Late: 1', 'Upcoming: 1'], digest['attachments'].map { |a| a.dig('blocks', 0, 'text', 'text').lines.first.strip }
          assert_includes digest.dig('attachments', 0, 'blocks', 0, 'text', 'text'),
                          '<https://redmine.example/issues/42|#42 Late> in Example (2 days late)'
          assert_includes digest.dig('attachments', 1, 'blocks', 0, 'text', 'text'),
                          '<https://redmine.example/issues/43|#43 Soon> in Example (2 days left)'
        end
      end
    end
  end

  def test_digest_invalid_message_placeholder_uses_default
    project = OpenStruct.new(name: 'Example')
    issue = OpenStruct.new(id: 42, subject: 'Late', due_date: Date.current - 1, project: project)
    config = { 'messages' => { 'due_reminders' => { 'title' => '%{unknown}' } } }
    Slackmine.stub(:config, config) do
      Slackmine::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
        digest = Slackmine::Formatter.due_digest_payload([issue], today: Date.current)
        assert_equal '📋 *Due reminders: 1*', digest.dig('blocks', 0, 'text', 'text')
      end
    end
  end

  def test_bot_recipient_is_skipped_and_next_group_is_delivered
    user = OpenStruct.new(id: 7, active?: true)
    job = SlackmineDueDigestJob.new
    issue = OpenStruct.new(id: 1, due_date: Date.current, project: OpenStruct.new(name: 'Example'))
    groups = { ['bot-token', 'UBOT'] => [issue], ['human-token', 'UHUMAN'] => [issue] }
    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| warnings << message }
    opened = []
    posts = []
    api = lambda do |_method, body, _token|
      opened << body['users']
      raise Slackmine::SlackApiError.new('conversations.open', '200', { 'error' => 'cannot_dm_bot' }) if body['users'] == 'UBOT'

      { 'channel' => { 'id' => 'D123' } }
    end
    User.stub(:find_by, user) do
      Rails.stub(:logger, logger) do
        job.stub(:due_issues_for, groups) do
          Slackmine.stub(:slack_api, api) do
            Slackmine::Formatter.stub(:due_digest_payload, { 'text' => 'Digest' }) do
              Slackmine.stub(:post_message, ->(*args) { posts << args }) do
                job.perform(7, Date.current.iso8601)
              end
            end
          end
        end
      end
    end
    assert_equal %w[UBOT UHUMAN], opened
    assert_equal [[{ 'text' => 'Digest' }, 'D123', 'human-token']], posts
    assert_equal 1, warnings.size
    assert_includes warnings.first, 'Redmine user #7'
    assert_includes warnings.first, 'UBOT: cannot_dm_bot'
  end

  def test_other_slack_api_errors_still_fail
    user = OpenStruct.new(id: 7, active?: true)
    job = SlackmineDueDigestJob.new
    error = Slackmine::SlackApiError.new('conversations.open', '200', { 'error' => 'missing_scope' })
    User.stub(:find_by, user) do
      job.stub(:due_issues_for, { ['token', 'U123'] => [] }) do
        Slackmine.stub(:slack_api, ->(*) { raise error }) do
          assert_same error, assert_raises(Slackmine::SlackApiError) { job.perform(7, Date.current.iso8601) }
        end
      end
    end
  end

  def test_job_sends_eleven_issues_in_one_dm_on_every_run
    assignee = User.new
    assignee.define_singleton_method(:id) { 7 }
    assignee.define_singleton_method(:active?) { true }
    project = OpenStruct.new(id: 2, identifier: 'example', name: 'Example')
    issues = (1..11).map do |id|
      OpenStruct.new(id: id, subject: "Issue #{id}", due_date: Date.current, project: project)
    end
    posts = []
    api = ->(method, body, _token) do
      assert_equal 'conversations.open', method
      assert_equal({ 'users' => 'U123' }, body)
      { 'channel' => { 'id' => 'D123' } }
    end
    config = { 'slack' => { 'bot_token' => 'token' } }
    Slackmine.stub(:config, config) do
      User.stub(:find_by, assignee) do
        Slackmine.stub(:slack_api, api) do
          Slackmine.stub(:post_message, ->(payload, channel, token) { posts << [payload, channel, token] }) do
            Slackmine::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
              job = SlackmineDueDigestJob.new
              job.stub(:due_issues_for, { ['token', 'U123'] => issues }) do
                job.perform(7, '2026-09-29')
                assert_empty posts
                job.perform(7, '2026-09-30')
                job.perform(7, '2026-09-30')
              end
              assert_equal 2, posts.size
              assert_equal 'D123', posts.first[1]
              assert_equal 'token', posts.first[2]
              assert_equal '#F79009', posts.first[0].dig('attachments', 0, 'color')
              assert_includes posts.first[0].dig('blocks', 0, 'text', 'text'), 'Due reminders: 11'
              body = posts.first[0].dig('attachments', 0, 'blocks').map { |block| block.dig('text', 'text') }.join("\n")
              assert_includes body, '#11 Issue 11'
            end
          end
        end
      end
    end
  end
end

Rake.application = Rake::Application.new
Rake::Task.define_task(:environment)
load File.expand_path('../lib/tasks/slackmine_due_reminders.rake', __dir__)

class DueReminderTaskTest < Minitest::Test
  class Scope
    attr_reader :filters

    def initialize
      @filters = {}
    end

    def where(condition = nil, *, **keywords)
      condition ||= keywords
      @filters.merge!(condition) if condition.is_a?(Hash)
      self
    end

    def not(*)
      self
    end

    def includes(*)
      self
    end

    def find_each
      [
        [3, 10, 2, 100, 0], [5, 10, 2, 100, 5], [7, 11, 3, 101, 0],
        [3, 10, 3, 100, 0]
      ].each_with_index do |(user_id, project_id, tracker_id, version_id, due_in), index|
        values = { assigned_to_id: user_id, project_id: project_id, tracker_id: tracker_id,
                   fixed_version_id: version_id }
        next unless @filters.all? do |key, expected|
          !values.key?(key) || Array(expected).include?(values[key])
        end

        project = OpenStruct.new(id: project_id, name: "Project #{project_id}")
        project.define_singleton_method(:active?) { true }
        issue = OpenStruct.new(id: index + 1, **values, due_date: Date.current + due_in, project: project)
        issue.define_singleton_method(:visible?) { |_user| true }
        yield issue
      end
    end
  end

  def setup
    @original_filters = ['users', 'users'.upcase, 'USER_ID', 'days', 'tracker', 'project', 'version']
                        .to_h { |name| [name, ENV[name]] }
    @original_filters.each_key { |name| ENV.delete(name) }
    @date_current = Date.method(:current) if Date.respond_to?(:current)
    Date.singleton_class.define_method(:current) { Date.new(2026, 9, 30) }
  end

  def teardown
    @original_filters.each do |name, value|
      value ? ENV[name] = value : ENV.delete(name)
    end
    if @date_current
      Date.singleton_class.define_method(:current, @date_current)
    else
      Date.singleton_class.remove_method(:current)
    end
  end

  def with_task
    scope = Scope.new
    queued = []
    logger = Object.new.tap { |item| item.define_singleton_method(:info) { |_message| } }
    Slackmine.stub(:due_reminder_max_days, 3) do
      Slackmine.stub(:due_reminder_settings, { enabled: true, days: 3 }) do
        Issue.stub(:joins, scope) do
          User.stub(:exists?, ->(options) { [3, 5, 7].include?(options[:id]) }) do
            Tracker.stub(:exists?, ->(options) { options[:id] == 2 }) do
              Project.stub(:find, ->(value) { OpenStruct.new(id: 10) if %w[10 example].include?(value) }) do
                Version.stub(:named, ->(name) {
                  Object.new.tap { |item| item.define_singleton_method(:pluck) { |_column| name == '1.0' ? [100] : [] } }
                }) do
                  Rails.stub(:logger, logger) do
                    SlackmineDueDigestJob.stub(:perform_later, ->(*args) { queued << args }) do
                      Rake::Task['slackmine:due_reminders'].reenable
                      yield scope, queued
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

  def test_users_filters_multiple_assignees_before_queuing
    ENV['users'] = '3, 5,3'
    with_task do |scope, queued|
      capture_io { Rake::Task['slackmine:due_reminders'].invoke }
      assert_equal [3, 5], scope.filters[:assigned_to_id]
      assert_equal [[3, '2026-09-30', {}]], queued
    end
  end

  def test_all_slackmine_filters_are_passed_to_the_worker
    ENV.update('days' => '7', 'tracker' => '2', 'project' => 'example',
               'users' => '3,5', 'version' => '1.0')
    with_task do |scope, queued|
      capture_io { Rake::Task['slackmine:due_reminders'].invoke }
      filters = { 'days' => 7, 'tracker_id' => 2, 'project_id' => 10, 'version_ids' => [100] }
      assert_equal({ assigned_to_id: [3, 5], project_id: 10, tracker_id: 2,
                     fixed_version_id: [100] }, scope.filters.reject { |key, _value| key == :issue_statuses })
      assert_equal [[3, '2026-09-30', filters], [5, '2026-09-30', filters]], queued
    end
  end

  def test_invalid_or_missing_user_stops_before_queuing
    ['3,,5', '3,99', ''].each do |value|
      ENV['users'] = value
      with_task do |_scope, queued|
        assert_raises(SystemExit) { capture_io { Rake::Task['slackmine:due_reminders'].invoke } }
        assert_empty queued
      end
    end
  end

  def test_removed_user_id_is_rejected_before_queuing
    ENV['USER_ID'] = '3'
    with_task do |_scope, queued|
      assert_raises(SystemExit) { capture_io { Rake::Task['slackmine:due_reminders'].invoke } }
      assert_empty queued
    end
  end

  def test_noncanonical_users_name_is_rejected_before_queuing
    ENV['users'.upcase] = '3'
    with_task do |_scope, queued|
      assert_raises(SystemExit) { capture_io { Rake::Task['slackmine:due_reminders'].invoke } }
      assert_empty queued
    end
  end

  def test_invalid_slackmine_filters_stop_before_queuing
    [{ 'days' => '-1' }, { 'days' => 'soon' }, { 'tracker' => '99' },
     { 'version' => 'missing' }].each do |values|
      ENV.update(values)
      with_task do |_scope, queued|
        assert_raises(SystemExit) { capture_io { Rake::Task['slackmine:due_reminders'].invoke } }
        assert_empty queued
      end
      values.each_key { |name| ENV.delete(name) }
    end
  end

  def test_worker_reapplies_task_filters_and_command_line_days
    filters = { 'days' => 7, 'project_id' => 10, 'tracker_id' => 2, 'version_ids' => [100] }
    user = OpenStruct.new(id: 5)
    scope = Scope.new
    job = SlackmineDueDigestJob.new
    Slackmine.stub(:due_reminder_settings, { enabled: true, days: 3 }) do
      Slackmine.stub(:bot_token, 'token') do
        Slackmine.stub(:slack_user_id_for, 'U123') do
          Issue.stub(:joins, scope) do
            groups = job.send(:due_issues_for, user, Date.current, filters)
            assert_equal({ assigned_to_id: 5, project_id: 10, tracker_id: 2,
                           fixed_version_id: [100] }, scope.filters.reject { |key, _value| key == :issue_statuses })
            assert_equal [2], groups[['token', 'U123']].map(&:id)
          end
        end
      end
    end
  end
end

class CommentThreadDeliveryTest < Minitest::Test
  def setup
    @project = OpenStruct.new(identifier: 'agentic')
    @settings = { 'slack' => { 'bot_token' => 'token', 'default_channel_id' => 'C123',
      'comment_notifications_in_threads' => true, 'events' => { 'app_id' => 'ATEST' } } }
    @root = { 'ts' => '1000.000001', 'bot_id' => 'B123', 'app_id' => 'ATEST', 'attachments' => [
      { 'blocks' => [{}, { 'text' => { 'text' => '*<https://redmine.example.com/issues/7|Subject>*' } }] }
    ] }
    @payload = { 'text' => 'Comment', '_slackmine_comment_issue_id' => 7 }
  end

  def deliver(api)
    posts = []
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, api) do
        Slackmine.stub(:post_message, ->(payload, channel, token) { posts << [payload, channel, token] }) do
          Slackmine.notify(@payload, project: @project)
        end
      end
    end
    posts.first.first
  end

  def test_latest_root_is_used_and_internal_hint_is_not_sent
    api = ->(method, request, token, **options) do
      assert_equal 'conversations.history', method
      assert_equal 'C123', request['channel']
      assert_equal 'token', token
      assert options[:form]
      { 'messages' => [@root, @root.merge('ts' => '999.000001')] }
    end
    result = deliver(api)
    assert_equal '1000.000001', result['thread_ts']
    refute result.key?('_slackmine_comment_issue_id')
    refute @payload.key?('thread_ts')
  end

  def test_compact_payload_is_used_only_when_a_thread_is_found
    @payload['_slackmine_thread_comment_payload'] = { 'text' => 'Just the comment' }
    result = deliver(->(*) { { 'messages' => [@root] } })
    assert_equal({ 'text' => 'Just the comment', 'thread_ts' => @root['ts'] }, result)
    result = deliver(->(*) { { 'messages' => [] } })
    assert_equal({ 'text' => 'Comment' }, result)
    assert @payload.key?('_slackmine_thread_comment_payload'), 'Queued source remains unchanged'
  end

  def test_disabled_switch_and_non_comment_notifications_do_not_fetch_history
    [false, nil, 'true'].each do |value|
      @settings['slack']['comment_notifications_in_threads'] = value
      result = deliver(->(*) { flunk 'Disabled lookup' })
      refute result.key?('thread_ts')
      refute result.key?('_slackmine_comment_issue_id')
    end
    @settings['slack']['comment_notifications_in_threads'] = true
    @payload.delete('_slackmine_comment_issue_id')
    refute deliver(->(*) { flunk 'Not a comment' }).key?('thread_ts')
  end

  def test_project_override_disables_lookup
    @settings['projects'] = { 'agentic' => { 'slack' => { 'comment_notifications_in_threads' => false } } }
    refute deliver(->(*) { flunk 'Disabled project lookup' }).key?('thread_ts')
  end

  def test_missing_app_configuration_and_lookup_failure_fall_back_to_channel_post
    @settings['slack'].delete('events')
    refute deliver(->(*) { flunk 'Missing app ID' }).key?('thread_ts')
    @settings['slack']['events'] = { 'app_id' => 'ATEST' }
    refute deliver(->(*) { raise IOError, 'History unavailable' }).key?('thread_ts')
  end

  def test_pagination_finds_an_older_matching_root
    requests = []
    api = ->(_method, request, _token, **_options) do
      requests << request
      requests.length == 1 ? { 'messages' => [], 'response_metadata' => { 'next_cursor' => 'page2' } } : { 'messages' => [@root] }
    end
    assert_equal '1000.000001', deliver(api)['thread_ts']
    assert_equal 'page2', requests[1]['cursor']
    assert_equal 100, requests[1]['limit']
  end

  def test_no_match_search_stops_after_three_pages
    calls = 0
    api = ->(*) { calls += 1; { 'messages' => [], 'response_metadata' => { 'next_cursor' => "page#{calls}" } } }
    refute deliver(api).key?('thread_ts')
    assert_equal 3, calls
  end

  def test_untrusted_links_other_apps_and_broadcast_replies_are_ignored
    checker = Slackmine::CommentThreads
    assert checker.notification_for_issue?(@root, 7, 'ATEST')
    [@root.merge('app_id' => 'AOTHER'), @root.merge('bot_id' => nil),
     @root.merge('thread_ts' => '999.000001'), @root.merge('ts' => 'invalid')].each do |message|
      refute checker.notification_for_issue?(message, 7, 'ATEST')
    end
    refute checker.notification_for_issue?(@root, 8, 'ATEST')
    @root['attachments'][0]['blocks'][1]['text']['text'] = '*<https://evil.example/issues/7|Subject>*'
    refute checker.notification_for_issue?(@root, 7, 'ATEST')
  end
end

class AutomaticChannelMatchingTest < Minitest::Test
  MATCHING = Slackmine::ChannelMatching

  def setup
    MATCHING.instance_variable_set(:@cache, {})
    @project = OpenStruct.new(identifier: 'support', name: 'Customer Support')
    @settings = { 'slack' => { 'auto_map_channels_by_name' => true,
      'bot_token' => 'channel-test-token', 'default_channel_id' => 'CDEFAULT' } }
  end

  def resolve(api)
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, api) { Slackmine.channel_id(@project) }
    end
  end

  def channel(id = 'CMATCH', name = 'support')
    { 'id' => id, 'name' => name }
  end

  def test_identifier_matches_case_and_spaces_independently_of_display_name
    api = ->(method, request, token, **options) do
      assert_equal 'users.conversations', method
      assert_equal 'public_channel,private_channel', request['types']
      assert request['exclude_archived']
      assert options[:form]
      assert_equal 'channel-test-token', token
      { 'channels' => [channel] }
    end
    assert_equal 'CMATCH', resolve(api)
    @project.identifier = ' SUPPORT '
    assert_equal 'CMATCH', resolve(->(*) { flunk 'Directory should be cached' })
    @project.name = 'Renamed display name'
    assert_equal 'CMATCH', resolve(->(*) { flunk 'Directory should be cached' })
    @project.identifier = 'different-identifier'
    assert_equal 'CDEFAULT', resolve(->(*) { flunk 'Directory should be cached' })
  end

  def test_display_name_alone_does_not_match
    assert_equal 'CDEFAULT', resolve(->(*) { { 'channels' => [channel('CNAME', 'customer-support')] } })
  end

  def test_unconfigured_child_inherits_nearest_explicit_ancestor_channel
    root = OpenStruct.new(identifier: 'root', parent: nil)
    parent = OpenStruct.new(identifier: 'parent', parent: root)
    @project.parent = parent
    @settings['projects'] = { 'root' => { 'channel_id' => 'CROOT' },
                             'parent' => { 'slack' => { 'default_channel_id' => 'CPARENT' } } }
    assert_equal 'CPARENT', resolve(->(*) { { 'channels' => [] } })
    @settings['projects']['parent']['slack']['default_channel_id'] = '  '
    assert_equal 'CROOT', resolve(->(*) { flunk 'Skip blank ancestor setting' })
    @settings['projects']['parent']['channel_id'] = 'CLEGACY'
    assert_equal 'CLEGACY', resolve(->(*) { flunk 'Use ancestor legacy setting' })
    @settings['projects']['support'] = { 'channel_id' => 'CCHILD' }
    assert_equal 'CCHILD', resolve(->(*) { flunk 'Child setting takes priority' })
  end

  def test_parent_channel_does_not_inherit_other_project_settings
    @project.parent = OpenStruct.new(identifier: 'parent', parent: nil)
    @settings['projects'] = { 'parent' => { 'channel_id' => 'CPARENT',
      'slack' => { 'bot_token' => 'parent-token', 'work_object_actions' => true },
      'events' => { 'issue' => { 'created' => false } } } }
    @settings['slack']['auto_map_channels_by_name'] = false
    Slackmine.stub(:config, @settings) do
      assert_equal 'CPARENT', Slackmine.channel_id(@project)
      assert_equal 'channel-test-token', Slackmine.bot_token(@project)
      refute Slackmine.effective_config(@project).dig('slack', 'work_object_actions')
      refute Slackmine.effective_config(@project).key?('events')
    end
  end

  def test_unconfigured_ancestors_keep_child_identifier_match_and_global_fallback
    @project.parent = OpenStruct.new(identifier: 'parent', name: 'Different name', parent: nil)
    assert_equal 'CMATCH', resolve(->(*) { { 'channels' => [channel] } })
    MATCHING.instance_variable_set(:@cache, {})
    assert_equal 'CDEFAULT', resolve(->(*) { { 'channels' => [] } })
  end

  def test_child_without_matching_channel_uses_existing_parent_identifier_channel
    @project.parent = OpenStruct.new(identifier: 'parent', name: 'Parent Project', parent: nil)
    calls = 0
    api = ->(*) { calls += 1; { 'channels' => [channel('CPARENT', 'parent')] } }
    assert_equal 'CPARENT', resolve(api)
    assert_equal 1, calls
    @project.parent.parent = OpenStruct.new(identifier: 'root', name: 'Root Project', parent: nil)
    MATCHING.instance_variable_set(:@cache, {})
    assert_equal 'CROOT', resolve(->(*) { { 'channels' => [channel('CROOT', 'root')] } })
  end

  def test_child_identifier_match_wins_over_parent_identifier_match
    @project.parent = OpenStruct.new(identifier: 'parent', name: 'Parent Project', parent: nil)
    assert_equal 'CMATCH', resolve(->(*) { { 'channels' => [channel, channel('CPARENT', 'parent')] } })
  end

  def test_child_identifier_match_wins_over_explicit_parent_and_nearest_parent_match_wins_over_root
    root = OpenStruct.new(identifier: 'root', name: 'Root Project', parent: nil)
    @project.parent = OpenStruct.new(identifier: 'parent', name: 'Parent Project', parent: root)
    @settings['projects'] = { 'parent' => { 'channel_id' => 'CPARENT' }, 'root' => { 'channel_id' => 'CROOT' } }
    assert_equal 'CMATCH', resolve(->(*) { { 'channels' => [channel] } })
    MATCHING.instance_variable_set(:@cache, {})
    @settings['projects'].delete('parent')
    assert_equal 'CPARENT', resolve(->(*) { { 'channels' => [channel('CPARENT', 'parent')] } })
  end

  def test_child_can_disable_ancestor_identifier_matching
    @project.parent = OpenStruct.new(identifier: 'parent', name: 'Parent Project', parent: nil)
    @settings['projects'] = { 'support' => { 'slack' => { 'auto_map_channels_by_name' => false } } }
    assert_equal 'CDEFAULT', resolve(->(*) { flunk 'Disabled child must not look up ancestor channels' })
  end

  def test_explicit_project_channel_ids_take_priority_and_do_not_fetch
    @settings['projects'] = { 'support' => { 'slack' => { 'default_channel_id' => 'CEXPLICIT' }, 'channel_id' => 'CLEGACY' } }
    assert_equal 'CEXPLICIT', resolve(->(*) { flunk 'Explicit channel lookup' })
    @settings['projects']['support']['slack'].delete('default_channel_id')
    assert_equal 'CLEGACY', resolve(->(*) { flunk 'Explicit legacy channel lookup' })
  end

  def test_disabled_project_override_and_non_boolean_settings_preserve_default
    [false, nil, 'true'].each do |value|
      @settings['projects'] = { 'support' => { 'slack' => { 'auto_map_channels_by_name' => value } } }
      assert_equal 'CDEFAULT', resolve(->(*) { flunk 'Disabled matching' })
    end
  end

  def test_ambiguous_or_unavailable_channels_fall_back
    api = ->(*) { { 'channels' => [channel, channel('CSECOND')] } }
    assert_equal 'CDEFAULT', resolve(api)
    MATCHING.instance_variable_set(:@cache, {})
    invalid = [channel.merge('is_archived' => true), channel.merge('is_member' => false),
      channel.merge('is_im' => true), channel.merge('is_mpim' => true)]
    assert_equal 'CDEFAULT', resolve(->(*) { { 'channels' => invalid } })
    @settings['slack'].delete('default_channel_id')
    assert_equal '', resolve(->(*) { flunk 'Directory should be cached' })
  end

  def test_pagination_and_token_specific_cache
    calls = []
    api = ->(_method, request, token, **_options) do
      calls << [request, token]
      request['cursor'] ? { 'channels' => [channel] } : { 'channels' => [], 'response_metadata' => { 'next_cursor' => 'next' } }
    end
    assert_equal 'CMATCH', resolve(api)
    assert_equal 'next', calls[1][0]['cursor']
    assert_equal 'CMATCH', resolve(->(*) { flunk 'Cached directory' })
    @settings['projects'] = { 'support' => { 'slack' => { 'bot_token' => 'other-token' } } }
    assert_equal 'CMATCH', resolve(api)
    assert_equal 'other-token', calls.last[1]
  end

  def test_api_failures_and_incomplete_lists_do_not_route_to_partial_matches
    assert_equal 'CDEFAULT', resolve(->(*) { raise IOError, 'API failure' })
    MATCHING.instance_variable_set(:@cache, {})
    calls = 0
    api = ->(*) { calls += 1; { 'channels' => [channel], 'response_metadata' => { 'next_cursor' => 'repeated' } } }
    assert_equal 'CDEFAULT', resolve(api)
    assert_equal 2, calls
  end

  def test_expired_memory_cache_is_refreshed
    key = Digest::SHA256.hexdigest('channel-test-token')
    MATCHING.instance_variable_set(:@cache, { key => { expires_at: 0, channels: { 'support' => ['COLD'] } } })
    assert_equal 'CMATCH', resolve(->(*) { { 'channels' => [channel] } })
  end
end

class IssueReferenceLinksTest < Minitest::Test
  def test_links_plain_references_without_nesting_existing_links_or_matching_other_ids
    formatter = Slackmine::Formatter
    link = '<https://redmine.example.com/issues/7|#7>'
    assert_equal "#{link} #{link} #70", formatter.link_issue_reference("#7 #{link} #70", 7)
    assert_equal '<@U123> ' + link, formatter.link_issue_reference('<@U123> #7', 7)
  end

  def test_missing_related_issue_still_has_a_link_without_an_invented_subject
    Issue.stub(:find_by, nil) do
      assert_equal '<https://redmine.example.com/issues/7|#7>', Slackmine::Formatter.relation_issue_link(7)
    end
  end
end
