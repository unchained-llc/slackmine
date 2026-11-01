# frozen_string_literal: true

require 'net/http'
require 'thread'

module Slackmine
  # One bounded pool per process; connections are never shared between threads.
  class SlackHttpPool
    SIZE = 5

    def initialize(size: SIZE, http_factory: -> { Net::HTTP.new('slack.com', 443) })
      @size = size
      @http_factory = http_factory
      @mutex = Mutex.new
      @available = ConditionVariable.new
      @idle = []
      @count = 0
    end

    def request(request, open_timeout:, read_timeout:)
      http = checkout(open_timeout)
      reusable = false
      begin
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        http.start unless http.started?
        response = http.request(request)
        reusable = true
        response
      ensure
        checkin(http, reusable)
      end
    end

    private

    def checkout(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        loop do
          return @idle.pop unless @idle.empty?
          if @count < @size
            http = @http_factory.call
            http.use_ssl = true
            http.max_retries = 0
            @count += 1
            return http
          end
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Net::OpenTimeout, 'Slack HTTP connection pool exhausted' if remaining <= 0
          @available.wait(@mutex, remaining)
        end
      end
    end

    def checkin(http, reusable)
      @mutex.synchronize do
        if reusable
          @idle << http
        else
          begin
            http.finish if http.started?
          rescue IOError, SystemCallError
            # The connection is already unusable.
          ensure
            @count -= 1
          end
        end
        @available.signal
      end
    end
  end

  def self.slack_http_pool
    # Reinitialize inherited sockets and synchronization state after a fork.
    if !@slack_http_pool || @slack_http_pool_pid != Process.pid
      @slack_http_pool = SlackHttpPool.new
      @slack_http_pool_pid = Process.pid
    end
    @slack_http_pool
  end
end
