# frozen_string_literal: true

require 'logger'
require_relative 'image_notification_test'

class NotificationCoalescingTest < Minitest::Test
  class Cache
    attr_reader :entries
    def initialize
      @entries = {}
    end
    def read(key)
      value = @entries[key]
      Marshal.load(Marshal.dump(value)) if value
    end
    def write(key, value, unless_exist: false, expires_in:)
      return false if unless_exist && @entries.key?(key)
      @entries[key] = Marshal.load(Marshal.dump(value))
      true
    end
    def delete(key)
      @entries.delete(key)
    end
    def fetch(key, expires_in:)
      read(key) || begin
        value = yield
        write(key, value, expires_in: expires_in)
        value
      end
    end
  end

  def setup
    @cache = Cache.new
    @project = OpenStruct.new(id: 9, identifier: 'example')
    @settings = { 'slack' => { 'bot_token' => 'secret', 'default_channel_id' => 'C123',
                              'notification_coalescing' => { 'enabled' => true, 'seconds' => 30 } } }
    @calls = []
    @clock = Time.at(1000)
    @allowed = ->(*) { true }
    @api = lambda do |method, body, *_args, **_options|
      @calls << [method, Marshal.load(Marshal.dump(body))]
      raise @failure if method == 'chat.update' && @failure
      { 'ok' => true, 'ts' => body['ts'] || "#{1000 + @calls.length}.000001" }
    end
  end

  def context(revision)
    { 'version' => 1, 'issue_id' => 42, 'journal_id' => revision,
      'issue_revision' => revision.to_s, 'journal_revision' => revision.to_s,
      'event' => 'status_changed' }
  end

  def payload(revision, actor: 7, **extra)
    { 'text' => "Update #{revision}", '_slackmine_actor_id' => actor,
      '_slackmine_delivery_context' => context(revision),
      'attachments' => [{ 'fallback' => "Update #{revision}", 'blocks' => [
        { 'type' => 'section', 'text' => { 'type' => 'mrkdwn', 'text' => "Change #{revision}" } }
      ] }] }.merge(extra.transform_keys(&:to_s))
  end

  def run_delivery
    Slackmine.stub(:config, @settings) do
      Rails.stub(:cache, @cache) do
        Rails.stub(:logger, Logger.new(File::NULL)) do
          Time.stub(:now, -> { @clock }) do
            Slackmine::NotificationSafety.stub(:allowed?, ->(*args) { @allowed.call(*args) }) do
              Slackmine.stub(:slack_api, @api) { yield }
            end
          end
        end
      end
    end
  end

  def send_notification(revision, **extra)
    Slackmine.notify(payload(revision, **extra), project: @project)
  end

  def test_first_post_is_immediate_and_later_edits_preserve_cards_and_latest_metadata
    run_delivery do
      send_notification(1, metadata: { 'entities' => [{ 'id' => 'old' }] })
      assert_equal ['chat.postMessage'], @calls.map(&:first)
      @clock += 10
      send_notification(2, metadata: { 'entities' => [{ 'id' => 'new' }] })
      @clock += 10
      send_notification(3)
    end
    assert_equal %w[chat.postMessage chat.update chat.update], @calls.map(&:first)
    assert_equal @calls.first[1]['channel'], @calls.last[1]['channel']
    assert_equal '1001.000001', @calls.last[1]['ts']
    assert_equal %w[old new], [@calls[0][1], @calls[1][1]].map { |p| p.dig('metadata', 'entities', 0, 'id') }
    assert_equal({}, @calls.last[1]['metadata'])
    assert_equal ['Change 1', 'Change 2', 'Change 3'], @calls.last[1]['attachments'].map { |a| a.dig('blocks', 0, 'text', 'text') }
    refute_includes JSON.generate(@calls), '_slackmine_'
    refute_includes JSON.generate(@cache.entries), 'secret'
  end

  def test_window_is_fixed_and_different_actors_keep_editing_the_same_post
    run_delivery do
      send_notification(1)
      @clock += 29
      send_notification(2)
      @clock += 1
      send_notification(3)
      send_notification(4, actor: 8)
      send_notification(5, actor: 7)
    end
    assert_equal %w[chat.postMessage chat.update chat.postMessage chat.update chat.update], @calls.map(&:first)
    assert_equal @calls[3][1]['ts'], @calls.last[1]['ts']
  end

  def test_enabled_without_seconds_uses_a_fixed_five_minute_window
    @settings['slack']['notification_coalescing'] = { 'enabled' => true }
    run_delivery do
      send_notification(1)
      @clock += 299
      send_notification(2)
      @clock += 1
      send_notification(3)
    end
    assert_equal %w[chat.postMessage chat.update chat.postMessage], @calls.map(&:first)
  end

  def test_only_boolean_true_enables_coalescing_even_with_seconds_configured
    [false, nil, 'true', 1].each do |enabled|
      @cache = Cache.new
      @calls.clear
      @settings['slack']['notification_coalescing'] = { 'enabled' => enabled, 'seconds' => 300 }
      actor, issue = formatted_fixture
      run_delivery do
        send_formatted(1, actor, issue, 'Closed', 'Assigned')
        send_formatted(2, actor, issue, 'Assigned', 'In progress')
      end
      assert_equal ['chat.postMessage'] * 2, @calls.map(&:first), enabled.inspect
      assert_empty @cache.entries
      refute_includes JSON.generate(@calls), '_slackmine_'
    end
  end

  def test_project_can_disable_globally_enabled_coalescing
    @settings['projects'] = { 'example' => { 'slack' => { 'notification_coalescing' => { 'enabled' => false } } } }
    run_delivery do
      send_notification(1)
      send_notification(2)
    end
    assert_equal ['chat.postMessage'] * 2, @calls.map(&:first)
  end

  def test_disabled_setting_posts_normally_and_missing_actor_still_coalesces
    run_delivery do
      @settings['slack'].delete('notification_coalescing')
      send_notification(1)
      send_notification(2)
      assert_empty @cache.entries
      @settings['slack']['notification_coalescing'] = { 'enabled' => true, 'seconds' => 30 }
      send_notification(3, actor: nil)
      send_notification(4, actor: nil)
    end
    assert_equal %w[chat.postMessage chat.postMessage chat.postMessage chat.update], @calls.map(&:first)
  end

  def test_thread_destinations_are_kept_separate
    run_delivery do
      send_notification(1, thread_ts: '100.1')
      send_notification(2, thread_ts: '100.1')
      send_notification(3, thread_ts: '200.1')
      send_notification(4, thread_ts: '100.1')
    end
    assert_equal %w[chat.postMessage chat.update chat.postMessage chat.update], @calls.map(&:first)
    refute @calls[1][1].key?('thread_ts')
    assert_equal '200.1', @calls[2][1]['thread_ts']
    assert_equal @calls[1][1]['ts'], @calls[3][1]['ts']
  end

  def test_retries_do_not_append_the_same_source_twice
    run_delivery do
      send_notification(1)
      send_notification(2)
      send_notification(2)
      send_notification(2, metadata: { 'entities' => [{ 'id' => 'refreshed' }] })
    end
    assert_equal %w[chat.postMessage chat.update], @calls.map(&:first)
  end

  def test_old_sources_are_revalidated_with_only_the_issue_revision_advanced
    checked = []
    @allowed = lambda do |ctx, _project|
      checked << ctx.dup
      ctx['journal_id'] != 1 || ctx['issue_revision'] == '1'
    end
    run_delivery do
      send_notification(1)
      send_notification(2)
    end
    assert_equal %w[chat.postMessage chat.update], @calls.map(&:first)
    assert_includes checked, context(1).merge('issue_revision' => '2')
    assert_equal 1, @calls.last[1]['attachments'].length
  end

  def test_deleted_message_falls_back_but_transient_failure_keeps_group_for_retry
    run_delivery do
      send_notification(1)
      @failure = Slackmine::SlackApiError.new('chat.update', 200, { 'error' => 'message_not_found' })
      send_notification(2)
      assert_equal %w[chat.postMessage chat.update chat.postMessage], @calls.map(&:first)
      @failure = Slackmine::SlackApiError.new('chat.update', 200, { 'error' => 'ratelimited' })
      assert_raises(Slackmine::SlackApiError) { send_notification(3) }
      @failure = nil
      send_notification(3)
    end
    assert_equal %w[chat.postMessage chat.update chat.postMessage chat.update chat.update], @calls.map(&:first)
    assert_equal ['Change 2', 'Change 3'], @calls.last[1]['attachments'].map { |a| a.dig('blocks', 0, 'text', 'text') }
  end

  def test_size_limits_shorten_history_inside_the_same_post
    run_delivery do
      6.times { |index| send_notification(index + 1) }
    end
    assert_equal ['chat.postMessage'] + ['chat.update'] * 5, @calls.map(&:first)
    assert_equal 5, @calls[-2][1]['attachments'].length
    assert_equal 5, @calls[-1][1]['attachments'].length
    assert_includes JSON.generate(@calls.last[1]), 'Earlier updates and full history:'
  end

  def test_lock_contention_does_not_overwrite_another_workers_state
    run_delivery do
      send_notification(1)
      key = @cache.entries.keys.first
      @cache.write("#{key}/lock", 'other-worker', expires_in: 300)
      before = @cache.read(key)
      Slackmine::NotificationCoalescing.stub(:sleep, ->(*) {}) do
        assert_raises(Slackmine::NotificationCoalescing::DeliveryUnavailable) { send_notification(2) }
      end
      assert_equal before, @cache.read(key)
      assert_equal 'other-worker', @cache.read("#{key}/lock")
    end
    assert_equal ['chat.postMessage'], @calls.map(&:first)
  end

  def test_new_images_are_shared_during_update_and_temporary_previews_are_removed
    run_delivery do
      send_notification(1)
      message = payload(2)
      message['attachments'][0]['blocks'] << { 'type' => 'image', 'slack_file' => { 'id' => 'F123' }, 'alt_text' => 'image' }
      Slackmine.notify(message, project: @project)
    end
    assert_equal %w[chat.postMessage chat.update chat.update], @calls.map(&:first)
    assert_equal 'F123', @calls[1][1].dig('blocks', 0, 'accessory', 'slack_file', 'id')
    assert_equal [], @calls.last[1]['blocks']
    assert_equal 2, @calls.last[1]['attachments'].length
  end

  def test_private_edited_or_deleted_retained_comments_are_not_republished
    original_check = Slackmine::NotificationSafety.method(:allowed?)
    %i[private edited deleted].each do |change|
      @cache = Cache.new
      @calls.clear
      @project[:active?] = true
      issue = OpenStruct.new(id: 42, project: @project, is_private?: false,
                             updated_on: @clock, custom_field_values: [], children: [], relations: [])
      first = OpenStruct.new(id: 1, journalized: issue, private_notes?: false, details: [], updated_on: @clock)
      second = OpenStruct.new(id: 2, journalized: issue, private_notes?: false, details: [], updated_on: @clock)
      journals = { 1 => first, 2 => second }
      @allowed = original_check
      Issue.stub(:find_by, issue) do
        Journal.stub(:find_by, ->(id:) { journals[id] }) do
          run_delivery do
            ctx = Slackmine::NotificationSafety.context(@project, 'comment_added', nil, 1, source: first)
            send_notification(1, _slackmine_delivery_context: ctx)
            case change
            when :private then first[:private_notes?] = true
            when :edited then first.updated_on += 1
            when :deleted then journals.delete(1)
            end
            issue.updated_on += 1
            ctx = Slackmine::NotificationSafety.context(@project, 'comment_added', nil, 2, source: second)
            send_notification(2, _slackmine_delivery_context: ctx)
          end
        end
      end
      assert_equal %w[chat.postMessage chat.update], @calls.map(&:first), change.to_s
      assert_equal 1, @calls.last[1]['attachments'].length
      assert_equal 'Change 2', @calls.last[1].dig('attachments', 0, 'blocks', 0, 'text', 'text')
    end
  end

  def test_project_override_and_channel_changes_are_respected
    @settings['slack']['notification_coalescing']['enabled'] = false
    @settings['projects'] = { 'example' => { 'slack' => { 'notification_coalescing' => { 'enabled' => true, 'seconds' => 30 } } } }
    run_delivery do
      send_notification(1)
      send_notification(2)
      @settings['slack']['default_channel_id'] = 'C456'
      send_notification(3)
    end
    assert_equal %w[chat.postMessage chat.update chat.postMessage], @calls.map(&:first)
    assert_equal 'C456', @calls.last[1]['channel']
  end

  def test_issue_deletion_also_edits_the_existing_post_within_the_window
    run_delivery do
      send_notification(1)
      send_notification(2, _slackmine_delivery_context: context(2).merge('event' => 'issue_deleted'))
    end
    assert_equal %w[chat.postMessage chat.update], @calls.map(&:first)
  end

  def test_seven_production_updates_and_twenty_field_changes_edit_one_post
    @settings['slack']['notification_coalescing']['seconds'] = 300
    actor, issue = formatted_fixture
    offsets = [0, 2, 6, 9, 11, 26, 28]
    run_delivery do
      offsets.each_with_index do |offset, index|
        @clock = Time.at(1000 + offset)
        send_formatted(index + 1, actor, issue, index.to_s, (index + 1).to_s, notes: index == 4 ? 'test' : nil)
      end
      assert_equal ['chat.postMessage'] + ['chat.update'] * 6, @calls.map(&:first)
      assert_equal ['1001.000001'], @calls.drop(1).map { |_, request| request['ts'] }.uniq
      assert_includes JSON.generate(@calls.last[1]), 'test'
      13.times { |index| send_formatted(index + 8, actor, issue, (index + 7).to_s, (index + 8).to_s) }
      assert_equal ['chat.postMessage'] + ['chat.update'] * 19, @calls.map(&:first)
      assert_includes JSON.generate(@calls.last[1]), (0..20).to_a.join(' → ')
      refute_includes JSON.generate(@calls.last[1]), 'Earlier updates'
      @clock = Time.at(1299)
      send_formatted(21, actor, issue, '20', '21')
      assert_equal 'chat.update', @calls.last.first
      assert_equal '1001.000001', @calls.last[1]['ts']
      @clock = Time.at(1300)
      send_formatted(22, actor, issue, '21', '22')
      assert_equal 'chat.postMessage', @calls.last.first
    end
  end

  def test_different_authors_and_their_comments_keep_the_same_post
    actor, issue = formatted_fixture
    other = User.new
    other.name = 'LUMEN'
    other.define_singleton_method(:id) { 8 }
    run_delivery do
      [actor, other].each_with_index do |author, index|
        message = Slackmine::Formatter.journal_payload(issue, actor: author, notes: "Comment by #{author.name}")
        message['_slackmine_delivery_context'] = context(index + 1).merge('event' => 'comment_added')
        Slackmine.notify(message, project: @project)
      end
    end
    assert_equal %w[chat.postMessage chat.update], @calls.map(&:first)
    blocks = @calls.last[1].dig('attachments', 0, 'blocks')
    assert_includes blocks.first.dig('text', 'text'), 'Kota / LUMEN'
    assert_equal ['*Kota*', '*LUMEN*'], blocks.select { |block| %w[*Kota* *LUMEN*].include?(block.dig('text', 'text')) }.map { |block| block.dig('text', 'text') }
    assert_includes JSON.generate(blocks), 'Comment by Kota'
    assert_includes JSON.generate(blocks), 'Comment by LUMEN'
  end

  def test_cache_failure_retries_instead_of_posting_a_duplicate
    run_delivery do
      send_notification(1)
      @cache.define_singleton_method(:write) { |*_, **_| raise IOError, 'cache unavailable' }
      assert_raises(Slackmine::NotificationCoalescing::DeliveryUnavailable) { send_notification(2) }
    end
    assert_equal ['chat.postMessage'], @calls.map(&:first)
  end

  def test_concurrent_notifications_wait_and_edit_the_first_post
    entered, release = Queue.new, Queue.new
    api = @api
    @api = lambda do |method, *args, **options|
      if method == 'chat.postMessage'
        entered << true
        release.pop
      end
      api.call(method, *args, **options)
    end
    run_delivery do
      first = Thread.new { send_notification(1) }
      entered.pop
      second = Thread.new { send_notification(2) }
      sleep(0.05)
      release << true
      [first, second].each(&:value)
    end
    assert_equal %w[chat.postMessage chat.update], @calls.map(&:first)
    assert_equal '1001.000001', @calls.last[1]['ts']
    assert_equal ['Change 1', 'Change 2'], @calls.last[1]['attachments'].map { |attachment| attachment.dig('blocks', 0, 'text', 'text') }
  end

  def test_automatic_comment_threads_do_not_bypass_coalescing
    @settings['slack']['comment_notifications_in_threads'] = true
    actor, issue = formatted_fixture
    run_delivery do
      send_formatted(1, actor, issue, 'Closed', 'Assigned')
      message = Slackmine::Formatter.journal_payload(issue, actor: actor, notes: 'Comment')
      message['_slackmine_delivery_context'] = context(2).merge('event' => 'comment_added')
      message['_slackmine_comment_issue_id'] = issue.id
      Slackmine::CommentThreads.stub(:latest_thread, ->(*) { flunk 'coalescing must take precedence' }) do
        Slackmine.notify(JSON.parse(JSON.generate(message)), project: @project)
      end
    end
    assert_equal %w[chat.postMessage chat.update], @calls.map(&:first)
    refute @calls.last[1].key?('thread_ts')
    assert_includes JSON.generate(@calls.last[1]), 'Comment'
  end

  def test_existing_cached_groups_are_adopted_without_starting_a_new_post
    run_delivery do
      send_notification(1)
      key = @cache.entries.keys.first
      state = @cache.read(key)
      state.merge!(state.delete('sources').first)
      @cache.write(key, state, expires_in: 30)
      send_notification(2)
    end
    assert_equal %w[chat.postMessage chat.update], @calls.map(&:first)
    assert_equal '1001.000001', @calls.last[1]['ts']
  end

  def formatted_fixture
    actor = User.new
    actor.name = 'Kota'
    actor.define_singleton_method(:id) { 7 }
    issue = OpenStruct.new(id: 42, subject: 'Monit investigation', description: '', project: @project,
                           tracker: OpenStruct.new(name: 'Task'), status: OpenStruct.new(name: 'Closed'),
                           author: actor, is_private?: false, done_ratio: 0)
    [actor, issue]
  end

  def send_formatted(revision, actor, issue, old_value, value, notes: nil, image: nil)
    issue.status = OpenStruct.new(name: value)
    detail = OpenStruct.new(property: 'attr', prop_key: 'status_id', old_value: old_value, value: value)
    Slackmine::Formatter.stub(:detail_old_value, ->(item, **_) { item.old_value }) do
      Slackmine::Formatter.stub(:detail_new_value, ->(_issue, item) { item.value }) do
        message = if notes
                    Slackmine::Formatter.journal_payload(issue, actor: actor, notes: notes, details: [detail])
                  else
                    Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'updated', details: [detail])
                  end
        if image
          # This is the same untagged image block produced by add_images after
          # replacing a Markdown image in a tagged body section.
          message['attachments'][0]['blocks'].insert(2,
            { 'type' => 'image', 'slack_file' => { 'id' => image }, 'alt_text' => image })
        end
        # Exercise the serialized ActiveJob boundary as well as the actual
        # formatter, Work Object compaction and delivery implementation.
        message = JSON.parse(JSON.generate(message.merge('_slackmine_delivery_context' => context(revision))))
        Slackmine.notify(message, project: @project)
      end
    end
  end

  def test_real_work_object_notifications_have_one_heading_and_one_status_history
    @settings['slack']['work_object_previews'] = true
    @settings['slack']['work_object_fields'] = { 'status' => true }
    actor, issue = formatted_fixture
    run_delivery do
      send_formatted(1, actor, issue, 'Closed', 'Assigned')
      send_formatted(2, actor, issue, 'Assigned', 'In progress')
      send_formatted(3, actor, issue, 'In progress', 'Closed')
    end
    assert_equal %w[chat.postMessage chat.update chat.update], @calls.map(&:first)
    message = @calls.last[1]
    assert_equal 1, message['attachments'].length
    blocks = message.dig('attachments', 0, 'blocks')
    assert_equal 1, blocks.count { |block| block.dig('text', 'text').to_s.include?('Kota') }
    assert_equal 1, blocks.count { |block| block.dig('text', 'text') == '*Changes*' }
    fields = blocks.flat_map { |block| Array(block['fields']) }
    assert_equal ['*Status*' + "\nClosed → Assigned → In progress → Closed"], fields.select { |field| field['text'].start_with?('*Status*') }.map { |field| field['text'] }
    assert_equal 'Closed', message.dig('metadata', 'entities', 0, 'entity_payload', 'fields', 'status', 'value')
    refute_includes JSON.generate(@calls), '_slackmine_'
  end

  def test_comment_bodies_and_images_remain_inside_the_single_card
    actor, issue = formatted_fixture
    run_delivery do
      send_formatted(1, actor, issue, 'Closed', 'Assigned', notes: 'First comment', image: 'F001')
      send_formatted(2, actor, issue, 'Assigned', 'In progress', notes: 'Second comment', image: 'F002')
    end
    assert_equal 1, @calls.last[1]['attachments'].length
    blocks = @calls.last[1].dig('attachments', 0, 'blocks')
    text = JSON.generate(blocks)
    assert_equal 1, text.scan('First comment').length
    assert_equal 1, text.scan('Second comment').length
    assert_equal 1, blocks.count { |block| block.dig('text', 'text') == '*Changes*' }
    assert_equal 1, blocks.count { |block| block.dig('text', 'text').to_s.include?('Kota') }
    assert_includes text, 'Closed → Assigned → In progress'
    assert_equal %w[F001 F002], blocks.select { |block| block['type'] == 'image' }.map { |block| block.dig('slack_file', 'id') }
    refute_includes JSON.generate(@calls), '_slackmine_'
  end

  def test_two_comment_only_notifications_merge_and_retain_both_bodies
    @settings['slack']['notification_coalescing'] = { 'enabled' => true }
    actor, issue = formatted_fixture
    run_delivery do
      ['First comment', 'Second comment'].each_with_index do |notes, index|
        message = Slackmine::Formatter.journal_payload(issue, actor: actor, notes: notes, details: [])
        message['_slackmine_delivery_context'] = context(index + 1).merge('event' => 'comment_added')
        Slackmine.notify(JSON.parse(JSON.generate(message)), project: @project)
        @clock += 60
      end
    end
    assert_equal %w[chat.postMessage chat.update], @calls.map(&:first)
    assert_equal 1, @calls.last[1]['attachments'].length
    blocks = @calls.last[1].dig('attachments', 0, 'blocks')
    text = JSON.generate(blocks)
    assert_equal 1, text.scan('First comment').length
    assert_equal 1, text.scan('Second comment').length
    assert_equal 1, blocks.count { |block| block.dig('text', 'text').to_s.include?('Kota') }
    assert_equal '💬 Kota *Comment added*', blocks.first.dig('text', 'text')
    refute_includes JSON.generate(@calls), '_slackmine_'
  end

  def test_creation_comment_and_due_date_change_remain_in_the_configured_heading
    @settings['messages'] = YAML.safe_load(File.read(File.expand_path('../config/slackmine.messages.yml.example', __dir__))).fetch('messages')
    @settings['slack']['work_object_previews'] = true
    @settings['slack']['work_object_fields'] = { 'status' => true, 'due_date' => true }
    actor, issue = formatted_fixture
    issue.description = 'Original body'
    issue.due_date = Date.new(2026, 10, 26)
    run_delivery do
      created = Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'created')
      created['_slackmine_delivery_context'] = context(1).merge('event' => 'issue_created')
      Slackmine.notify(JSON.parse(JSON.generate(created)), project: @project)
      issue.due_date = nil
      detail = OpenStruct.new(property: 'attr', prop_key: 'due_date', old_value: '2026-10-26', value: nil)
      updated = Slackmine::Formatter.journal_payload(issue, actor: actor, notes: 'Recovery confirmed', details: [detail])
      updated['_slackmine_delivery_context'] = context(2).merge('event' => 'due_date_changed')
      Slackmine.notify(JSON.parse(JSON.generate(updated)), project: @project)
    end
    assert_equal %w[chat.postMessage chat.update], @calls.map(&:first)
    first = @calls.first[1].dig('attachments', 0, 'blocks')
    blocks = @calls.last[1].dig('attachments', 0, 'blocks')
    assert_equal '🆕 Kota *Issue created*', first.first.dig('text', 'text')
    assert_equal '🔄 Kota *Issue created ＋ Comment added ＋ Due date changed*', blocks.first.dig('text', 'text')
    # Only the heading changes; creation content still precedes the comment.
    assert_equal first[1], blocks[1]
    assert_includes blocks[3].dig('text', 'text'), 'Recovery confirmed'
    assert_includes JSON.generate(blocks), '2026-10-26 → None'
    refute @calls.last[1].dig('metadata', 'entities', 0, 'entity_payload', 'fields').key?('due_date')
    refute_includes JSON.generate(@calls), '_slackmine_'
  end

  def test_creation_followed_by_repeated_comments_retains_the_creation_once
    actor, issue = formatted_fixture
    run_delivery do
      message = Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'created')
      message['_slackmine_delivery_context'] = context(1).merge('event' => 'issue_created')
      Slackmine.notify(message, project: @project)
      %w[First Second].each_with_index do |notes, index|
        message = Slackmine::Formatter.journal_payload(issue, actor: actor, notes: notes)
        message['_slackmine_delivery_context'] = context(index + 2).merge('event' => 'comment_added')
        Slackmine.notify(message, project: @project)
      end
    end
    assert_equal %w[chat.postMessage chat.update chat.update], @calls.map(&:first)
    assert_equal '💬 Kota *Issue created ＋ Comment added*', @calls.last[1].dig('attachments', 0, 'blocks', 0, 'text', 'text')
  end

  def test_an_oversized_combined_heading_shortens_the_same_post
    @settings['messages'] = { 'events' => { 'issue' => { 'created' => 'c' * 1600 },
                                           'comment' => { 'added' => 'a' * 1600 } } }
    actor, issue = formatted_fixture
    run_delivery do
      message = Slackmine::Formatter.issue_payload(issue, actor: actor, action: 'created')
      message['_slackmine_delivery_context'] = context(1).merge('event' => 'issue_created')
      Slackmine.notify(message, project: @project)
      message = Slackmine::Formatter.journal_payload(issue, actor: actor, notes: 'Comment')
      message['_slackmine_delivery_context'] = context(2).merge('event' => 'comment_added')
      Slackmine.notify(message, project: @project)
    end
    assert_equal %w[chat.postMessage chat.update], @calls.map(&:first)
    assert_includes JSON.generate(@calls.last[1]), 'Earlier updates and full history:'
  end

  def test_avatar_heading_is_kept_once_when_notifications_are_merged
    @settings['messages'] = { 'notification_headers' => { 'issue' => '%{avatar} %{actor} *%{event}*' } }
    actor, issue = formatted_fixture
    api = @api
    @api = lambda do |method, *args, **options|
      if method == 'users.info'
        { 'user' => { 'profile' => { 'image_48' => 'https://avatars.slack-edge.com/kota.png' } } }
      else
        api.call(method, *args, **options)
      end
    end
    User.stub(:find_by, actor) do
      Slackmine.stub(:slack_user_id_for, 'U123') do
        run_delivery do
          send_formatted(1, actor, issue, 'Closed', 'Assigned')
          send_formatted(2, actor, issue, 'Assigned', 'In progress', notes: 'Comment')
        end
      end
    end
    blocks = @calls.last[1].dig('attachments', 0, 'blocks')
    assert_equal 1, blocks.count { |block| block['type'] == 'context' }
    assert_equal 'context', blocks.first['type']
    assert_includes JSON.generate(blocks.first), 'https://avatars.slack-edge.com/kota.png'
    assert_equal ['Kota *Status changed ＋ Comment added*'], blocks.first['elements'].select { |element| element['type'] == 'mrkdwn' }.map { |element| element['text'] }
    refute_includes JSON.generate(@calls), '_slackmine_'
  end
end
