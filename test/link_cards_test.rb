# frozen_string_literal: true
require_relative 'message_shortcuts_test'
require 'time'

class LinkCardsTest < Minitest::Test
  CARDS = Slackmine::LinkCards
  URL = 'https://example.slack.com/archives/C123/p1791115675755579'

  def setup
    @viewer = OpenStruct.new(id: 1, logged?: true)
    @viewer.define_singleton_method(:allowed_to?) { |*| false }
    @journal = OpenStruct.new(notes: URL, private_notes?: true, user_id: 2)
    @journals = Object.new
    @journals.define_singleton_method(:find_by) { |**_| @row }
    @journals.instance_variable_set(:@row, @journal)
    @issue = OpenStruct.new(id: 123, description: "[Source](#{URL})", project: OpenStruct.new(identifier: 'example'), journals: @journals)
    @issue.define_singleton_method(:visible?) { |*| @visible != false }
    @calls = []
    @message = { 'ts' => '1791115675.755579', 'user' => 'U123', 'text' => '<script>alert(1)</script> &amp; hello' }
    @workspace = 'https://example.slack.com/'
    @channel = { 'id' => 'C123', 'name' => 'example', 'is_private' => false, 'is_member' => true }
    @members = ['U123']
    @identity_allowed = true
  end

  def fetch(url = URL, **options)
    Slackmine.stub(:bot_token, 'token') do
      Slackmine.stub(:slack_api, lambda { |method, body, *_args|
        @calls << [method, body]
        case method
        when 'auth.test' then { 'url' => @workspace }
        when 'conversations.history' then { 'messages' => body['oldest'] == '1791110000.000001' ? [@parent].compact : (@reply ? [] : [@message]) }
        when 'conversations.replies' then { 'messages' => [@message] }
        when 'conversations.info' then { 'channel' => @channel }
        when 'conversations.members' then { 'members' => @members }
        when 'users.info' then { 'user' => { 'profile' => { 'display_name' => 'Example User', 'image_48' => 'https://cdn.example.com/avatar.png' } } }
        end
      }) do
        CARDS.stub(:slack_identity, 'U123') do
          Slackmine::WorkObjects.stub(:viewer_for, @identity_allowed ? @viewer : nil) { CARDS.fetch(@issue, @viewer, url, **options) }
        end
      end
    end
  end

  def test_permalink_parsing_and_queries
    target = CARDS.parse(URL + '?thread_ts=1791110000.000001&cid=C123')
    assert_equal 'C123', target['channel']
    assert_equal '1791115675.755579', target['ts']
    assert_equal '1791110000.000001', target['thread_ts']
    ['http://example.slack.com/archives/C123/p1791115675755579',
     'https://example.slack.com.evil.example/archives/C123/p1791115675755579',
     'https://example.slack.com@evil.example/archives/C123/p1791115675755579',
     URL + '/evil', URL + '?thread_ts=invalid', URL.sub('https:', 'file:')].each do |url|
      assert_nil CARDS.parse(url)
    end
  end

  def test_disabled_link_cards_never_fetch_slack
    Slackmine.stub(:config, { 'slack' => { 'link_cards' => { 'enabled' => false } } }) do
      assert_nil fetch
      assert_empty @calls
    end
  end

  def test_link_card_defaults_and_project_overrides
    Slackmine.stub(:config, {}) do
      assert CARDS.enabled?(@issue.project)
      assert CARDS.redmine_enabled?(@issue.project)
    end
    settings = { 'slack' => { 'link_cards' => { 'enabled' => false, 'redmine_enabled' => true } },
                 'projects' => { 'example' => { 'slack' => { 'link_cards' => { 'enabled' => true, 'redmine_enabled' => false } } } } }
    Slackmine.stub(:config, settings) do
      assert CARDS.enabled?(@issue.project)
      refute CARDS.redmine_enabled?(@issue.project)
      refute CARDS.enabled?(nil)
      refute CARDS.redmine_enabled?(nil)
    end
  end

  def test_card_fetches_only_exact_message_and_returns_plain_text
    card = fetch
    assert_equal 'Example User', card['author']
    assert_equal 'example', card['channel']
    assert_equal '<script>alert(1)</script> &amp; hello', card['text']
    request = @calls.find { |method, _| method == 'conversations.history' }.last
    assert_equal request['oldest'], request['latest']
    assert_equal 1, request['limit']
  end

  def test_denied_issue_and_unreferenced_url_never_call_slack
    @issue.instance_variable_set(:@visible, false)
    assert_nil fetch
    assert_empty @calls
    @issue.instance_variable_set(:@visible, true)
    assert_nil fetch(URL.sub('C123', 'C456'))
    assert_empty @calls
    @viewer.define_singleton_method(:logged?) { false }
    assert_nil fetch
    assert_empty @calls
  end

  def test_private_note_permission_is_required_even_if_issue_is_visible
    assert_nil fetch(journal_id: '2')
    assert_empty @calls
    @journal.user_id = @viewer.id
    refute_nil fetch(journal_id: '2')
  end

  def test_other_workspace_and_wrong_timestamp_are_rejected
    @workspace = 'https://other.slack.com/'
    assert_nil fetch
    assert_equal ['auth.test'], @calls.map(&:first)
    @workspace = 'https://example.slack.com/'
    @message['ts'] = '1791115675.755580'
    assert_nil fetch
  end

  def test_thread_reply_keeps_exact_timestamp
    @reply = true
    url = URL + '?thread_ts=1791110000.000001'
    @issue.description = url
    refute_nil fetch(url)
    request = @calls.find { |method, _| method == 'conversations.replies' }.last
    assert_equal '1791110000.000001', request['ts']
    assert_equal '1791115675.755579', request['oldest']
  end
  def test_parent_context_and_mentions_are_resolved
    @message['thread_ts'] = '1791110000.000001'
    @message['text'] = 'Hello <@U123> in <#C123>'
    @parent = { 'ts' => '1791110000.000001', 'user' => 'U123', 'text' => 'Original topic' }
    card = fetch
    assert card['thread_reply']
    assert_equal 'Original topic', card.dig('parent', 'text')
    assert_equal 'Example User', card.dig('names', 'U123')
    assert_equal 'example', card.dig('names', 'C123')
    html = CARDS.render_card(card, URL, @issue.project)
    assert_includes html, 'Thread reply'
    assert_includes html, 'Original topic'
    assert_includes html, '@Example User'
    assert_includes html, '#example'
  end

  def test_color_override_and_invalid_css_fallback
    Slackmine.stub(:effective_config, { 'slack' => { 'link_cards' => { 'color' => '#123ABC' } } }) do
      assert_equal '#123ABC', CARDS.color(@issue.project)
    end
    Slackmine.stub(:effective_config, { 'slack' => { 'link_cards' => { 'color' => 'red; background:url(evil)' } } }) do
      assert_equal '#6D5DFB', CARDS.color(@issue.project)
    end
  end

  def test_server_render_excludes_code_preserves_failure_and_memoizes_duplicates
    html = "<p><a href=\"#{URL}\">source</a><a href=\"#{URL}\">again</a></p><pre><a href=\"#{URL}\">code</a></pre>"
    state = { api: {}, cards: {}, count: 0, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5 }
    calls = 0
    CARDS.stub(:fetch, ->(*) { calls += 1; { 'text' => '<script>alert(1)</script>', 'author' => 'Example', 'channel' => 'test' } }) do
      rendered = CARDS.render_links(html, @issue, @viewer, nil, state)
      doc = Nokogiri::HTML.fragment(rendered)
      assert_equal 2, doc.css('.slackmine-link-card').size
      assert_equal 1, doc.css('pre a').size
      assert_empty doc.css('script')
      assert_includes doc.text, '<script>alert(1)</script>'
      assert_equal 1, calls
    end
    state[:cards] = {}; state[:count] = 0
    CARDS.stub(:fetch, nil) { assert_equal html, CARDS.render_links(html, @issue, @viewer, nil, state) }
    state[:count] = 20; state[:cards] = {}
    CARDS.stub(:fetch, ->(*) { flunk 'budget must prevent request' }) do
      assert_equal html, CARDS.render_links(html, @issue, @viewer, nil, state)
    end
  end

  def test_api_cache_reuses_profiles_and_workspace_checks_per_request
    cache = {}
    @message['text'] = '<@U123> <@U123>'
    refute_nil fetch(api_cache: cache)
    refute_nil fetch(api_cache: cache)
    assert_equal 1, @calls.count { |method, _| method == 'users.info' }
    assert_equal 1, @calls.count { |method, _| method == 'auth.test' }
    @calls.clear
    assert_nil fetch(deadline: 0)
    assert_empty @calls
  end

  def test_bot_identity_fallback_and_unavailable_parent
    @message.delete('user')
    @message['bot_id'] = 'B123'
    @message['thread_ts'] = '1791110000.000001'
    @message['reply_count'] = 2
    bot = { 'bot' => { 'name' => 'Example Monitor', 'icons' => { 'image_48' => 'https://cdn.example.com/bot.png' } } }
    Slackmine.stub(:bot_token, 'token') do
      Slackmine.stub(:slack_api, ->(method, body, *) {
        case method
        when 'auth.test' then { 'url' => @workspace }
        when 'conversations.history' then { 'messages' => body['oldest'] == @message['ts'] ? [@message] : [] }
        when 'conversations.info' then { 'channel' => @channel }
        when 'conversations.members' then { 'members' => @members }
        when 'bots.info' then bot
        end
      }) do
        card = CARDS.stub(:slack_identity, 'U123') do
          Slackmine::WorkObjects.stub(:viewer_for, @viewer) { CARDS.fetch(@issue, @viewer, URL) }
        end
        assert_equal 'Example Monitor', card['author']
        assert card['thread_reply']
        assert_nil card['parent']
        assert_includes CARDS.render_card(card, URL, @issue.project), 'Open parent message in Slack'
      end
    end
  end

end
