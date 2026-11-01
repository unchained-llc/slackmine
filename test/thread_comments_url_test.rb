# frozen_string_literal: true
require_relative 'link_cards_test'
require_relative 'thread_state_isolation'

class ThreadCommentsUrlTest < Minitest::Test
  prepend ThreadStateIsolation
  COMMENTS = Slackmine::ThreadComments
  URL = 'https://example.slack.com/archives/C123/p1791115675755579'

  def setup
    @event = { 'user' => 'U123', 'channel' => 'C123', 'ts' => '1791115675.755579', 'thread_ts' => '1791110000.000001', 'text' => 'Reply body' }
    @viewer = OpenStruct.new(id: 3)
    @journal = OpenStruct.new(id: 88, persisted?: false)
    @issue = OpenStruct.new(id: 7, project: OpenStruct.new(identifier: 'example', active?: true),
                            is_private?: false)
    @issue.define_singleton_method(:with_lock) { |&block| block.call }
    @issue.define_singleton_method(:visible?) { |_| true }
    @issue.define_singleton_method(:notes_addable?) { |_| true }
    journals = Object.new
    journals.define_singleton_method(:where) { |*| [] }
    journals.define_singleton_method(:exists?) { |*| false }
    @issue.journals = journals
    journal = @journal
    @issue.define_singleton_method(:init_journal) { |viewer, notes| journal.user_id = viewer.id; journal.notes = notes; journal }
    @issue.define_singleton_method(:save!) { journal[:persisted?] = true }
    @calls = []
  end

  def persist(url = URL)
    Slackmine.stub(:config, { 'slack' => { 'thread_comments' => true, 'bot_token' => 'test-token' } }) do
      Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
        Slackmine.stub(:slack_api, ->(method, body, token, **_) {
          @calls << [method, body, token]
          { 'permalink' => url }
        }) { COMMENTS.persist_reply(@issue, @event, 'TTEST') }
      end
    end
  end

  def test_saves_reply_url_with_original_author_and_timestamp
    previous = User.current
    assert_equal :saved, persist
    assert_equal URL + '?thread_ts=' + @event['thread_ts'], @journal.notes
    assert_equal 3, @journal.user_id
    assert_equal COMMENTS.posted_at(@event['ts']), @journal.created_on
    assert_equal @journal.created_on, @journal.updated_on
    assert_equal [['chat.getPermalink', { 'channel' => 'C123', 'message_ts' => @event['ts'] }, 'test-token']], @calls
    assert_same previous, User.current
    assert_nil Thread.current[:slackmine_thread_comment]
  end

  def test_missing_invalid_or_different_reply_url_never_saves
    ['', 'https://evil.example/archives/C123/p1791115675755579',
     URL.sub('C123', 'C999'), URL.sub('755579', '755580')].each do |url|
      assert_equal :restricted, persist(url)
      refute @journal.persisted?
      assert_nil @journal.notes
    end
  end

  def test_duplicate_does_not_fetch_permalink_or_save
    assert_equal :saved, persist
    @calls.clear
    assert_equal :duplicate, persist
    assert_empty @calls
    assert @journal.persisted?
  end
end
