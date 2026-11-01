# frozen_string_literal: true
# Exercise the real note-building/deduplication code with plain Ruby fixtures.
# No ActiveRecord connection, SQLite, additional DB, or migration is used.
require_relative 'thread_comments_url_test'

class ThreadConnectionsNotesTest < Minitest::Test
  prepend ThreadStateIsolation
  def setup
    fixture = ThreadCommentsUrlTest.new('fixture')
    fixture.setup
    %i[@event @viewer @journal @issue].each { |name| instance_variable_set(name, fixture.instance_variable_get(name)) }
    @stored = []
    @calls = []
    rows = @stored
    @issue.journals.define_singleton_method(:where) do |filter, *|
      filter.is_a?(Hash) ? rows.select { |j| j.user_id == filter[:user_id] && j.created_on == filter[:created_on] } : []
    end
    journal = @journal
    @issue.journals.define_singleton_method(:find_by) { |id:| rows.any? && id == journal.id ? journal : nil }
    @issue.define_singleton_method(:save!) { journal[:persisted?] = true; rows << journal }
    @time = Slackmine::ThreadComments.posted_at('1791115675.999999')
    other = @event.merge('user' => 'U456', 'ts' => '1791115675.755580', 'text' => 'Second speaker')
    @entries = [@event, other].each_with_index.map do |event, index|
      { 'event' => event, 'card' => { 'author' => index.zero? ? 'Alice' : 'Bob', 'text' => event['text'],
        'timestamp' => Slackmine::ThreadComments.posted_at(event['ts']).iso8601,
        'channel' => 'discussion', 'thread_connection_nonce' => 'a' * 32 } }
    end
  end

  def persist(messages = {})
    settings = { 'slack' => { 'thread_connections' => true, 'thread_comments' => false, 'bot_token' => 'token' },
                 'messages' => { 'thread_connections' => messages } }
    Slackmine.stub(:config, settings) do
      Slackmine.stub(:slack_api, ->(method, body, *) {
        @calls << method
        { 'permalink' => "https://example.slack.com/archives/C123/p#{body['message_ts'].delete('.')}" }
      }) do
        Slackmine::ThreadComments.persist_reply(@issue, @event, 'TTEST', events: @entries.map { |e| e['event'] },
          connected: true, import_viewer: @viewer, history_cards: @entries, import_timestamp: @time)
      end
    end
  end

  def test_history_builds_one_journal_with_each_original_speaker_and_connecting_author
    previous = User.current
    assert_equal :saved, persist
    assert_equal 1, @stored.size
    assert_equal @viewer.id, @journal.user_id
    assert_equal @time, @journal.created_on
    cards = Slackmine::LinkQuotes.blocks(@journal.notes).map(&:last)
    assert_equal ['Alice', 'Bob'], cards.map { |c| c['author'] }
    assert_equal ['Reply body', 'Second speaker'], cards.map { |c| c['text'] }
    assert_equal ['a' * 32], cards.map { |c| c['thread_connection_nonce'] }.uniq
    assert_same previous, User.current
    assert_nil Thread.current[:slackmine_thread_comment]
  end

  def test_retry_uses_existing_journal_identity_without_an_additional_store
    assert_equal :saved, persist
    @calls.clear
    assert_equal :duplicate, persist
    assert_equal 1, @stored.size
    assert_empty @calls
  end

  def test_bulk_history_over_10000_characters_saves_every_quote
    @entries = 100.times.map do |index|
      event = @event.merge('ts' => format('1791115%03d.000001', index), 'text' => "#{index}: " + 'x' * 120)
      { 'event' => event, 'card' => { 'author' => 'Alice', 'text' => event['text'],
        'timestamp' => Slackmine::ThreadComments.posted_at(event['ts']).iso8601,
        'channel' => 'discussion', 'thread_connection_nonce' => 'a' * 32 } }
    end
    assert_equal :saved, persist
    cards = Slackmine::LinkQuotes.blocks(@journal.notes).map(&:last)
    assert_equal 100, cards.size
    assert_equal @entries.map { |entry| entry['event']['text'] }, cards.map { |card| card['text'] }
  end

  def test_reconnection_imports_only_posts_not_already_saved
    assert_equal :saved, persist
    old = @entries.last
    new_event = @event.merge('ts' => '1791115675.755581', 'text' => 'New reply')
    @entries = [old, { 'event' => new_event, 'card' => old['card'].merge('text' => 'New reply',
      'timestamp' => Slackmine::ThreadComments.posted_at(new_event['ts']).iso8601, 'thread_connection_nonce' => 'b' * 32) }]
    @calls.clear
    assert_equal :saved, persist
    assert_equal ['chat.getPermalink'], @calls
    assert_equal ['New reply'], Slackmine::LinkQuotes.blocks(@journal.notes).map { |_, card| card['text'] }
  end

  def test_quoted_history_recovers_when_redis_finalization_fails
    Slackmine::ThreadState.stub(:finish, ->(*) { raise IOError, 'Redis unavailable after commit' }) do
      assert_raises(IOError) { persist }
    end
    assert_equal 1, @stored.size
    assert_equal :duplicate, persist
    assert_equal 1, @stored.size
  end

  def test_history_and_normal_replies_share_the_same_message_deduplication
    settings = { 'slack' => { 'thread_comments' => true, 'thread_connections' => true, 'bot_token' => 'token' } }
    Slackmine.stub(:config, settings) do
      Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
        Slackmine.stub(:slack_api, ->(_method, body, *) { { 'permalink' => "https://example.slack.com/archives/C123/p#{body['message_ts'].delete('.')}" } }) do
          assert_equal :saved, Slackmine::ThreadComments.persist_reply(@issue, @event, 'TTEST')
        end
      end
    end
    assert_equal :saved, persist
    assert_equal ['Second speaker'], Slackmine::LinkQuotes.blocks(@journal.notes).map { |_, card| card['text'] }
  end

  def test_configured_history_heading_preserves_speakers_and_deduplication
    assert_equal :saved, persist('history_heading' => 'Conversation imported before connection')
    assert_includes @journal.notes, 'Conversation imported before connection'
    assert_equal ['Alice', 'Bob'], Slackmine::LinkQuotes.blocks(@journal.notes).map { |_, card| card['author'] }
    assert_equal :duplicate, persist('history_heading' => 'A different heading after configuration changes')
    assert_equal 1, @stored.size
  end
end
