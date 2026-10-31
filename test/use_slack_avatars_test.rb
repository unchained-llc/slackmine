# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'digest'
require 'uri'

module Rails
  def self.cache; end
  def self.logger; end
end

class User
  attr_accessor :login, :mail, :name
end

class AnonymousUser < User; end

module GravatarHelper
  DEFAULT_OPTIONS = { size: 24 }.freeze
end

class AvatarHelperFixture
  def avatar(_user, _options = {})
    '<span class="avatar">AC</span>'
  end

  def image_tag(url, attributes)
    { url: url, attributes: attributes }
  end

end

class SlackmineUseSlackAvatarsJob
  def self.perform_later(*); end
end

module Slackmine
  def self.config; {}; end
  def self.bot_token(_project = nil); config.dig('slack', 'bot_token'); end
  def self.with_project(_project); yield; end
  def self.slack_user_id_for(user); config.fetch('users')[user.login]; end
  def self.slack_api(*); end
end

require_relative '../lib/slackmine/use_slack_avatars'
AvatarHelperFixture.prepend(Slackmine::UseSlackAvatars::HelperPatch)

class UseSlackAvatarsTest < Minitest::Test
  class Cache
    def initialize; @data = {}; @now = 0; end
    def advance(seconds); @now += seconds; end
    def read(key)
      entry = @data[key]
      return unless entry
      return @data.delete(key) && nil if entry[:expires_at] && entry[:expires_at] <= @now
      entry[:value]
    end
    def write(key, value, unless_exist: false, expires_in: nil, **)
      return false if unless_exist && !read(key).nil?
      @data[key] = { value: value, expires_at: expires_in && @now + expires_in }
      true
    end
    def delete(key); @data.delete(key); end
  end

  def setup
    @cache = Cache.new
    @user = User.new
    @user.login = 'alice'
    @user.mail = 'alice@example.org'
    @user.name = 'Alice'
    def @user.id; 42; end
    @config = { 'slack' => { 'use_slack_avatars' => true, 'bot_token' => 'token', 'events' => { 'team_id' => 'T1' } },
                'users' => { 'alice' => 'U123' } }
  end

  def test_only_slack_cdn_urls_are_accepted
    safe = Slackmine::UseSlackAvatars
    assert safe.safe_url('https://avatars.slack-edge.com/a.png')
    assert safe.safe_url('https://a.slack-edge.com/abcd/img/avatars/ava_001-48.png')
    %w[http://avatars.slack-edge.com/a https://avatars.slack-edge.com.evil/a https://secure.gravatar.com/avatar/a https://avatars.slack-edge.com/a?x=1 https://user@avatars.slack-edge.com/a].each do |url|
      assert_nil safe.safe_url(url)
    end
  end

  def test_refresh_uses_global_mapping_and_rejects_other_workspaces
    Slackmine.stub(:config, @config) do
      Rails.stub(:cache, @cache) do
        key = Slackmine::UseSlackAvatars.cache_key(@user)
        api = ->(_method, body, token, **) {
          assert_equal 'U123', body['user']
          assert_equal 'token', token
          { 'user' => { 'team_id' => 'T1', 'profile' => { 'image_72' => 'https://avatars.slack-edge.com/a.png' } } }
        }
        Slackmine.stub(:slack_api, api) { Slackmine::UseSlackAvatars.refresh(@user, key) }
        assert_equal 'https://avatars.slack-edge.com/a.png', Slackmine::UseSlackAvatars.lookup(@user)
        @config['users']['alice'] = 'U456'
        refute_equal key, Slackmine::UseSlackAvatars.cache_key(@user)
        other_key = Slackmine::UseSlackAvatars.cache_key(@user)
        Slackmine.stub(:slack_api, ->(*) { { 'user' => { 'team_id' => 'T2', 'profile' => { 'image_72' => 'https://avatars.slack-edge.com/a.png' } } } }) do
          Slackmine::UseSlackAvatars.refresh(@user, other_key)
        end
        assert_nil Slackmine::UseSlackAvatars.lookup(@user)
      end
    end
  end

  def test_disabled_by_default
    Slackmine.stub(:config, {}) { refute Slackmine::UseSlackAvatars.enabled? }
  end

  def test_expired_avatar_remains_visible_while_refresh_is_queued
    url = 'https://avatars.slack-edge.com/a.png'
    jobs = []
    Slackmine.stub(:config, @config) do
      Rails.stub(:cache, @cache) do
        key = Slackmine::UseSlackAvatars.cache_key(@user)
        Slackmine.stub(:slack_api, ->(*) { { 'user' => { 'team_id' => 'T1', 'profile' => { 'image_72' => url } } } }) do
          Slackmine::UseSlackAvatars.refresh(@user, key)
        end
        assert_equal url, Slackmine::UseSlackAvatars.lookup(@user)
        @cache.advance(601)
        SlackmineUseSlackAvatarsJob.stub(:perform_later, ->(*args) { jobs << args }) do
          assert_equal url, Slackmine::UseSlackAvatars.lookup(@user)
          assert_equal url, Slackmine::UseSlackAvatars.lookup(@user)
          assert_equal url, AvatarHelperFixture.new.avatar(@user, size: 24)[:url]
        end
        assert_equal [[42, key]], jobs
      end
    end
  end

  def test_successful_refresh_replaces_stale_avatar
    old = 'https://avatars.slack-edge.com/old.png'
    fresh = 'https://avatars.slack-edge.com/new.png'
    Slackmine.stub(:config, @config) do
      Rails.stub(:cache, @cache) do
        key = Slackmine::UseSlackAvatars.cache_key(@user)
        [old, fresh].each do |url|
          Slackmine.stub(:slack_api, ->(*) { { 'user' => { 'team_id' => 'T1', 'profile' => { 'image_72' => url } } } }) do
            Slackmine::UseSlackAvatars.refresh(@user, key)
          end
        end
        assert_equal fresh, Slackmine::UseSlackAvatars.lookup(@user)
        @cache.advance(601)
        SlackmineUseSlackAvatarsJob.stub(:perform_later, ->(*) {}) do
          assert_equal fresh, Slackmine::UseSlackAvatars.lookup(@user)
        end
      end
    end
  end

  def test_api_failure_keeps_last_image_and_retries_after_a_minute
    url = 'https://avatars.slack-edge.com/a.png'
    Slackmine.stub(:config, @config) do
      Rails.stub(:cache, @cache) do
        key = Slackmine::UseSlackAvatars.cache_key(@user)
        Slackmine.stub(:slack_api, ->(*) { { 'user' => { 'team_id' => 'T1', 'profile' => { 'image_72' => url } } } }) do
          Slackmine::UseSlackAvatars.refresh(@user, key)
        end
        @cache.advance(601)
        Slackmine.stub(:slack_api, ->(*) { raise IOError, 'unavailable' }) { Slackmine::UseSlackAvatars.refresh(@user, key) }
        jobs = []
        SlackmineUseSlackAvatarsJob.stub(:perform_later, ->(*args) { jobs << args }) do
          assert_equal url, Slackmine::UseSlackAvatars.lookup(@user)
          assert_empty jobs
          @cache.advance(61)
          assert_equal url, Slackmine::UseSlackAvatars.lookup(@user)
          assert_equal [[42, key]], jobs
        end
      end
    end
  end

  def test_removed_slack_member_discards_previous_avatar
    url = 'https://avatars.slack-edge.com/a.png'
    Slackmine.stub(:config, @config) do
      Rails.stub(:cache, @cache) do
        key = Slackmine::UseSlackAvatars.cache_key(@user)
        Slackmine.stub(:slack_api, ->(*) { { 'user' => { 'team_id' => 'T1', 'profile' => { 'image_72' => url } } } }) do
          Slackmine::UseSlackAvatars.refresh(@user, key)
        end
        Slackmine.stub(:slack_api, ->(*) { { 'user' => { 'team_id' => 'T1', 'deleted' => true } } }) do
          Slackmine::UseSlackAvatars.refresh(@user, key)
        end
        assert_nil Slackmine::UseSlackAvatars.lookup(@user)
        assert_nil @cache.read(Slackmine::UseSlackAvatars.stale_key(@user))
      end
    end
  end

  def test_stale_avatar_is_kept_after_a_long_idle_period
    url = 'https://avatars.slack-edge.com/a.png'
    Slackmine.stub(:config, @config) do
      Rails.stub(:cache, @cache) do
        key = Slackmine::UseSlackAvatars.cache_key(@user)
        Slackmine.stub(:slack_api, ->(*) { { 'user' => { 'team_id' => 'T1', 'profile' => { 'image_72' => url } } } }) do
          Slackmine::UseSlackAvatars.refresh(@user, key)
        end
        @cache.advance(86_401 * 30)
        SlackmineUseSlackAvatarsJob.stub(:perform_later, ->(*) {}) do
          assert_equal url, Slackmine::UseSlackAvatars.lookup(@user)
        end
      end
    end
  end

  def test_stale_avatar_is_not_used_after_mapping_changes
    url = 'https://avatars.slack-edge.com/a.png'
    Slackmine.stub(:config, @config) do
      Rails.stub(:cache, @cache) do
        old_key = Slackmine::UseSlackAvatars.cache_key(@user)
        Slackmine.stub(:slack_api, ->(*) { { 'user' => { 'team_id' => 'T1', 'profile' => { 'image_72' => url } } } }) do
          Slackmine::UseSlackAvatars.refresh(@user, old_key)
        end
        @config['users']['alice'] = 'U456'
        SlackmineUseSlackAvatarsJob.stub(:perform_later, ->(*) {}) do
          assert_nil Slackmine::UseSlackAvatars.lookup(@user)
        end
      end
    end
  end

  def test_stale_avatar_is_kept_if_enqueue_lock_fails
    url = 'https://avatars.slack-edge.com/a.png'
    Slackmine.stub(:config, @config) do
      Rails.stub(:cache, @cache) do
        key = Slackmine::UseSlackAvatars.cache_key(@user)
        Slackmine.stub(:slack_api, ->(*) { { 'user' => { 'team_id' => 'T1', 'profile' => { 'image_72' => url } } } }) do
          Slackmine::UseSlackAvatars.refresh(@user, key)
        end
        @cache.advance(601)
        original_write = @cache.method(:write)
        @cache.stub(:write, ->(cache_key, *args, **options) {
          raise IOError, 'cache write unavailable' if cache_key.end_with?('/pending')
          original_write.call(cache_key, *args, **options)
        }) do
          assert_equal url, Slackmine::UseSlackAvatars.lookup(@user)
        end
      end
    end
  end

  def test_helper_returns_direct_image_with_original_fallback_and_options
    Slackmine.stub(:config, @config) do
      Slackmine::UseSlackAvatars.stub(:lookup, 'https://avatars.slack-edge.com/a.png') do
        result = AvatarHelperFixture.new.avatar(@user, size: 32, class: 'avatar-child', data: { existing: 'value' })
        assert_equal 'https://avatars.slack-edge.com/a.png', result[:url]
        assert_equal 'avatar avatar-child', result[:attributes][:class]
        assert_equal 32, result[:attributes][:width]
        assert_equal '<span class="avatar">AC</span>', result[:attributes][:data][:slackmine_avatar_fallback]
        assert_equal 'value', result[:attributes][:data][:existing]
      end
    end
  end

  def test_cache_miss_enqueues_once_without_calling_slack_in_the_request
    jobs = []
    Slackmine.stub(:config, @config) do
      Rails.stub(:cache, @cache) do
        Slackmine.stub(:slack_api, ->(*) { flunk 'Slack API must not run during rendering' }) do
          SlackmineUseSlackAvatarsJob.stub(:perform_later, ->(*args) { jobs << args }) do
            2.times { assert_nil Slackmine::UseSlackAvatars.lookup(@user) }
          end
        end
        assert_equal [[42, Slackmine::UseSlackAvatars.cache_key(@user)]], jobs
      end
    end
  end
end
