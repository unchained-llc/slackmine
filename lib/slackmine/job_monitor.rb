# frozen_string_literal: true

require 'json'

module Slackmine
  module JobMonitor
    module_function

    HISTORY_KEY = 'slackmine:admin:job_history:v1'
    HISTORY_LIMIT = 100
    HISTORY_TTL = 7 * 24 * 60 * 60
    SCAN_LIMIT = 500

    def test_channel(project)
      project ? Slackmine.channel_id(project) : Slackmine.config.dig('slack', 'default_channel_id').to_s.strip
    end

    def available?
      ApplicationJob.queue_adapter.class.name.include?('Sidekiq')
    end

    def load_api
      require 'sidekiq/api'
    end

    def record(job, status, started, error = nil)
      return unless available?
      load_api
      # Never persist arguments, message bodies, user identities or error text.
      entry = { 'job' => job.class.name, 'id' => job.job_id, 'status' => status,
                'finished_at' => Time.now.to_f, 'duration' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
                'error' => error&.class&.name }
      Sidekiq.redis do |connection|
        connection.multi do |transaction|
          transaction.lpush(HISTORY_KEY, JSON.generate(entry))
          transaction.ltrim(HISTORY_KEY, 0, HISTORY_LIMIT - 1)
          transaction.expire(HISTORY_KEY, HISTORY_TTL)
        end
      end
    rescue StandardError, LoadError => e
      Rails.logger.warn("Slackmine job history unavailable: #{e.class}")
    end

    def summary(payload, state, timestamp = nil)
      payload = JSON.parse(payload) if payload.is_a?(String)
      argument = Array(payload['args']).first
      active_job = argument.is_a?(Hash) ? argument : {}
      name = payload['wrapped'] || active_job['job_class'] || payload['class']
      return unless name.to_s.match?(/\ASlackmine\w*Job\z/)
      { 'job' => name, 'id' => active_job['job_id'] || payload['jid'],
        'status' => state, 'timestamp' => timestamp, 'error' => payload['error_class'] }
    end

    def snapshot
      return { available: false } unless available?
      load_api
      queue = Sidekiq::Queue.new('slackmine')
      entries = []
      sources = { 'queued' => queue, 'scheduled' => Sidekiq::ScheduledSet.new,
                  'retry' => Sidekiq::RetrySet.new, 'dead' => Sidekiq::DeadSet.new }
      truncated = false
      sources.each do |state, source|
        truncated ||= source.size > SCAN_LIMIT
        source.each_with_index do |job, index|
          break if index >= SCAN_LIMIT
          row = summary(job.item, state, job.respond_to?(:score) ? job.score : job.item['enqueued_at'])
          entries << row if row
        end
      end
      Sidekiq::WorkSet.new.each do |_process, _thread, work|
        row = summary(work.payload, 'running', work.run_at)
        entries << row if row
      end
      history = Sidekiq.redis { |connection| connection.lrange(HISTORY_KEY, 0, HISTORY_LIMIT - 1) }
      cutoff = Time.now.to_f - HISTORY_TTL
      history = history.map { |value| JSON.parse(value) }.select { |entry| entry['finished_at'].to_f >= cutoff }
      { available: true, entries: entries, history: history, queue_size: queue.size,
        latency: queue.latency, truncated: truncated }
    rescue StandardError, LoadError => e
      Rails.logger.warn("Slackmine job monitor unavailable: #{e.class}")
      { available: false }
    end
  end

  module JobTracking
    def self.included(base)
      base.around_perform :record_slackmine_execution
    end

    def record_slackmine_execution
      return yield unless self.class.name.match?(/\ASlackmine\w*Job\z/)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        result = yield
      rescue StandardError, LoadError => error
        JobMonitor.record(self, 'failed', started, error)
        raise
      else
        JobMonitor.record(self, 'completed', started)
        result
      end
    end
  end
end
