# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/slackmine/slack_http_pool'

class SlackHttpPoolTest < Minitest::Test
  class FakeHttp
    attr_accessor :use_ssl, :max_retries, :open_timeout, :read_timeout, :failure
    attr_reader :starts, :requests, :finished

    def initialize
      @starts = @requests = 0
      @started = false
    end

    def start
      @starts += 1
      @started = true
    end

    def started?; @started; end
    def finish; @finished = true; @started = false; end

    def request(request)
      @requests += 1
      raise IOError, 'connection lost' if failure
      request
    end
  end

  def test_reuses_connection_and_updates_timeouts
    http = FakeHttp.new
    begin
      pool = Slackmine::SlackHttpPool.new(http_factory: -> { http })
      assert_equal :first, pool.request(:first, open_timeout: 1, read_timeout: 2)
      assert_equal :second, pool.request(:second, open_timeout: 3, read_timeout: 4)
      assert_equal 1, http.starts
      assert_equal 2, http.requests
      assert_equal [3, 4, 0, true], [http.open_timeout, http.read_timeout, http.max_retries, http.use_ssl]
    end
  end

  def test_failed_request_discards_connection_without_retry
    first = FakeHttp.new
    first.failure = true
    second = FakeHttp.new
    connections = [first, second]
    begin
      pool = Slackmine::SlackHttpPool.new(size: 1, http_factory: -> { connections.shift })
      assert_raises(IOError) { pool.request(:post, open_timeout: 1, read_timeout: 1) }
      assert_equal 1, first.requests
      assert first.finished
      assert_equal :next, pool.request(:next, open_timeout: 1, read_timeout: 1)
    end
  end

  def test_pool_limits_concurrency_and_waits_only_until_open_timeout
    entered = Queue.new
    release = Queue.new
    http = FakeHttp.new
    http.define_singleton_method(:request) { |request| entered << true; release.pop; request }
    begin
      pool = Slackmine::SlackHttpPool.new(size: 1, http_factory: -> { http })
      worker = Thread.new { pool.request(:one, open_timeout: 1, read_timeout: 1) }
      entered.pop
      assert_raises(Net::OpenTimeout) { pool.request(:two, open_timeout: 0.01, read_timeout: 1) }
      release << true
      assert_equal :one, worker.value
    end
  end

  def test_fork_gets_a_new_pool
    skip 'fork unavailable' unless Process.respond_to?(:fork)
    parent = Slackmine.slack_http_pool
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(Slackmine.slack_http_pool.equal?(parent) ? 'same' : 'new')
      writer.close
      exit! 0
    end
    writer.close
    assert_equal 'new', reader.read
    Process.wait(pid)
  end
end
