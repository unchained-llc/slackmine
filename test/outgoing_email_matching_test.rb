# frozen_string_literal: true
require_relative 'image_notification_test'

class OutgoingEmailMatchingTest < Minitest::Test
  class ExpiringCache
    attr_accessor :now
    attr_reader :entries

    def initialize
      @now = 0
      @entries = {}
    end

    def read(key)
      value, expiry = @entries[key]
      Marshal.load(value) if expiry && expiry > now
    end

    def write(key, value, expires_in:)
      @entries[key] = [Marshal.dump(value), now + expires_in]
    end

    def fetch(key, expires_in:)
      existing = read(key)
      return existing unless existing.nil?

      value = yield
      write(key, value, expires_in: expires_in)
      value
    end
  end

  def setup
    @cache = ExpiringCache.new
    @warnings = []
    @logger = Object.new
    warnings = @warnings
    @logger.define_singleton_method(:warn) { |message| warnings << message }
    @settings = { 'slack' => { 'bot_token' => 'secret-token', 'auto_map_users_by_email' => true } }
    @calls = []
    @response = { 'members' => [member('U123', 'alice@example.com')] }
  end

  def member(id, email, team = 'T123')
    { 'id' => id, 'team_id' => team, 'profile' => { 'email' => email } }
  end

  def configured
    Slackmine.stub(:config, @settings) do
      Rails.stub(:cache, @cache) do
        Rails.stub(:logger, @logger) do
          Slackmine.stub(:slack_api, lambda { |method, params, token, **options|
            @calls << [method, params, token]
            assert_equal 'users.list', method
            assert_equal true, options[:form]
            result = @responses ? @responses.shift : @response
            raise result if result.is_a?(Exception)
            result
          }) { yield }
        end
      end
    end
  end

  def error(code)
    Slackmine::SlackApiError.new('users.list', '200', {
      'error' => code, 'response_metadata' => { 'messages' => ['alice@example.com secret-token'] }
    })
  end

  def test_250_lookups_share_two_paginated_requests_and_cached_refreshes
    members = 250.times.map { |i| member("U#{i}", "user#{i}@example.com") }
    @responses = [
      { 'members' => members.first(200), 'response_metadata' => { 'next_cursor' => 'next' } },
      { 'members' => members.drop(200) }
    ]
    configured do
      2.times do
        250.times { |i| assert_equal "U#{i}", Slackmine.slack_user_id_for_email(" USER#{i}@example.com ") }
      end
    end
    assert_equal [{ 'limit' => 200 }, { 'limit' => 200, 'cursor' => 'next' }], @calls.map { |call| call[1] }
    serialized = @cache.entries.to_s
    refute_includes serialized, 'example.com'
    refute_includes serialized, 'secret-token'
    refute_includes serialized, 'profile'
  end

  def test_missing_user_is_quiet_and_directory_refreshes_after_ten_minutes
    configured do
      3.times { assert_nil Slackmine.slack_user_id_for_email('missing@example.com') }
      assert_equal 'U123', Slackmine.slack_user_id_for_email('alice@example.com')
      assert_equal 1, @calls.size
      assert_empty @warnings
      @cache.now = 599
      assert_equal 'U123', Slackmine.slack_user_id_for_email('alice@example.com')
      @cache.now = 600
      @response = { 'members' => [] }
      assert_nil Slackmine.slack_user_id_for_email('alice@example.com')
    end
    assert_equal 2, @calls.size
  end

  def test_api_failure_backs_off_for_all_addresses_and_recovers_after_a_minute
    @response = error('missing_scope')
    configured do
      assert_nil Slackmine.slack_user_id_for_email('alice@example.com')
      assert_nil Slackmine.slack_user_id_for_email('bob@example.com')
      assert_equal 1, @calls.size
      assert_equal 1, @warnings.size
      assert_includes @warnings.first, 'code=missing_scope'
      refute_includes @warnings.first, 'alice@example.com'
      refute_includes @warnings.first, 'secret-token'
      @cache.now = 60
      @response = { 'members' => [member('U123', 'alice@example.com')] }
      assert_equal 'U123', Slackmine.slack_user_id_for_email('alice@example.com')
      assert_equal 2, @calls.size
    end
  end

  def test_cache_is_separate_for_tokens_and_workspaces
    configured do
      assert_equal 'U123', Slackmine.slack_user_id_for_email('alice@example.com')
      @settings['slack']['bot_token'] = 'another-token'
      @response = { 'members' => [member('U456', 'alice@example.com', 'T456')] }
      assert_equal 'U456', Slackmine.slack_user_id_for_email('alice@example.com')
      @settings['slack']['events'] = { 'team_id' => 'T123' }
      assert_nil Slackmine.slack_user_id_for_email('alice@example.com')
      @settings['slack']['events']['team_id'] = 'T456'
      assert_equal 'U456', Slackmine.slack_user_id_for_email('alice@example.com')
    end
    assert_equal 4, @calls.size
  end

  def test_duplicate_email_ids_are_ambiguous_even_across_pages
    @responses = [
      { 'members' => [member('U123', 'alice@example.com')], 'response_metadata' => { 'next_cursor' => 'next' } },
      { 'members' => [member('U456', 'ALICE@example.com'), member('U789', 'bob@example.com')] }
    ]
    configured do
      assert_nil Slackmine.slack_user_id_for_email('alice@example.com')
      assert_equal 'U789', Slackmine.slack_user_id_for_email('bob@example.com')
    end
  end

  def test_incomplete_listing_is_not_used_or_cached_as_success
    first_page = { 'members' => [member('U123', 'alice@example.com')], 'response_metadata' => { 'next_cursor' => 'repeated' } }
    @response = first_page
    configured do
      assert_nil Slackmine.slack_user_id_for_email('alice@example.com')
      assert_nil Slackmine.slack_user_id_for_email('alice@example.com')
    end
    assert_equal 2, @calls.size
    assert_equal 1, @warnings.size
    refute @cache.entries.keys.any? { |key| key.start_with?('slackmine/email-users/') }
  end

  def test_page_limit_prevents_endless_listing_with_distinct_cursors
    @responses = 10.times.map { |i| { 'members' => [member('U123', 'alice@example.com')], 'response_metadata' => { 'next_cursor' => "next#{i}" } } }
    configured { assert_nil Slackmine.slack_user_id_for_email('alice@example.com') }
    assert_equal 10, @calls.size
    refute @cache.entries.keys.any? { |key| key.start_with?('slackmine/email-users/') }
  end

  def test_transport_failure_is_backed_off_without_logging_message
    @response = IOError.new('alice@example.com secret-token')
    configured do
      2.times { assert_nil Slackmine.slack_user_id_for_email('alice@example.com') }
    end
    assert_equal 1, @calls.size
    assert_equal 1, @warnings.size
    assert_includes @warnings.first, 'IOError'
    refute_includes @warnings.first, 'secret-token'
  end

  def test_malformed_listing_returns_no_match
    @response = { 'members' => {} }
    configured { assert_nil Slackmine.slack_user_id_for_email('alice@example.com') }
    assert_equal 1, @warnings.size
  end

  def test_untrusted_error_code_is_not_logged
    @response = error('alice@example.com secret-token')
    configured { assert_nil Slackmine.slack_user_id_for_email('alice@example.com') }
    assert_includes @warnings.first, 'code=unknown_error'
    refute_includes @warnings.first, 'secret-token'
  end

  def test_incoming_authorization_does_not_reuse_cached_outgoing_identity
    user = User.new
    user.login = 'alice'
    user.mail = 'alice@example.com'
    user.define_singleton_method(:active?) { true }
    relation = Object.new
    %i[joins distinct limit].each { |method| relation.define_singleton_method(method) { |*| self } }
    relation.define_singleton_method(:where) do |_sql, email|
      @records = email == 'alice@example.com' ? [user] : []
      self
    end
    relation.define_singleton_method(:to_a) { @records }
    User.define_singleton_method(:active) {} unless User.respond_to?(:active)
    methods = []
    incoming_email = 'alice@example.com'
    Slackmine.stub(:config, @settings) do
      Rails.stub(:cache, @cache) do
        User.stub(:active, relation) do
          Slackmine.stub(:slack_api, lambda { |method, *, **options|
            methods << method
            method == 'users.list' ? @response : { 'user' => member('U123', incoming_email) }
          }) do
            assert_equal 'U123', Slackmine.slack_user_id_for_email('alice@example.com')
            assert_same user, Slackmine::WorkObjects.viewer_for('U123')
            incoming_email = 'changed@example.com'
            assert_nil Slackmine::WorkObjects.viewer_for('U123')
            assert_equal 'U123', Slackmine.slack_user_id_for_email('alice@example.com')
          end
        end
      end
    end
    assert_equal %w[users.list users.info users.info], methods
  end
end
