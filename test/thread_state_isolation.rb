# frozen_string_literal: true

# Integration tests use an explicitly selected, disposable Redis. Keys for
# each test are isolated and removed without touching unrelated Redis data.
module ThreadStateIsolation
  def before_setup
    super
    skip 'Set SLACKMINE_TEST_REDIS_URL to a dedicated test Redis' unless ENV['SLACKMINE_TEST_REDIS_URL']
  end

  def run(*args)
    return super unless ENV['SLACKMINE_TEST_REDIS_URL'] && defined?(Slackmine::ThreadState)
    require 'sidekiq'
    Sidekiq.configure_client { |config| config.redis = { url: ENV['SLACKMINE_TEST_REDIS_URL'] } }
    original = Slackmine::ThreadState.method(:key)
    prefix = "slackmine:test:#{SecureRandom.hex(16)}:"
    keys = []
    generator = lambda do |kind, *identity|
      key = prefix + original.call(kind, *identity)
      keys << key unless keys.include?(key)
      key
    end
    Slackmine::ThreadState.stub(:key, generator) { super }
  ensure
    if prefix && !keys.empty?
      Slackmine::ThreadState.with_redis { |redis| redis.call('DEL', *keys) }
    end
  end
end
