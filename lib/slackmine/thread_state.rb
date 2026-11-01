# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'

module Slackmine
  # Shared, persistent state for explicit thread connections and imported posts.
  # Redis keys deliberately contain no message text or credentials.
  module ThreadState
    module_function

    class PendingImport < StandardError; end

    PREFIX = 'slackmine:thread-state:v1:'
    CONNECT_SCRIPT = <<~LUA.freeze
      local old = redis.call('GET', KEYS[1])
      if redis.call('EXISTS', KEYS[2]) == 1 then return 'closed' end
      if old then
        local current = cjson.decode(old)
        if current.active then
          if current.nonce == ARGV[1] then return 'same' else return 'conflict' end
        end
      end
      redis.call('SET', KEYS[1], ARGV[2])
      return 'connected'
    LUA
    DISCONNECT_SCRIPT = <<~LUA.freeze
      local old = redis.call('GET', KEYS[1])
      if not old then return 0 end
      local current = cjson.decode(old)
      if not current.active or current.nonce ~= ARGV[1] then return 0 end
      redis.call('SET', KEYS[2], '1')
      redis.call('SET', KEYS[1], ARGV[2])
      return 1
    LUA
    CLAIM_SCRIPT = <<~LUA.freeze
      for i, key in ipairs(KEYS) do
        local value = redis.call('GET', key)
        if value and value ~= 'done' then return redis.error_reply('IMPORT_PENDING') end
      end
      local claimed = {}
      for i, key in ipairs(KEYS) do
        if not redis.call('GET', key) then
          redis.call('SET', key, ARGV[1])
          table.insert(claimed, i)
        end
      end
      return claimed
    LUA
    FINISH_SCRIPT = <<~LUA.freeze
      for i, key in ipairs(KEYS) do
        if redis.call('GET', key) ~= ARGV[1] then return redis.error_reply('IMPORT_CLAIM_CHANGED') end
      end
      for i, key in ipairs(KEYS) do redis.call('SET', key, 'done') end
      return #KEYS
    LUA
    RELEASE_SCRIPT = <<~LUA.freeze
      for i, key in ipairs(KEYS) do
        if redis.call('GET', key) == ARGV[1] then redis.call('DEL', key) end
      end
      return #KEYS
    LUA
    RECORD_JOURNAL_SCRIPT = <<~LUA.freeze
      for i, key in ipairs(KEYS) do
        if redis.call('GET', key) ~= ARGV[1] then return redis.error_reply('IMPORT_CLAIM_CHANGED') end
      end
      for i, key in ipairs(KEYS) do redis.call('SET', key, ARGV[2]) end
      return #KEYS
    LUA
    RECOVER_SCRIPT = <<~LUA.freeze
      if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
      if ARGV[2] == 'done' then redis.call('SET', KEYS[1], 'done') else redis.call('DEL', KEYS[1]) end
      return 1
    LUA

    def key(kind, *identity)
      # Isolate separate Redmine instances sharing one Sidekiq Redis.
      instance = defined?(Setting) && Setting.respond_to?(:host_name) ? Setting.host_name.to_s : ''
      PREFIX + kind + ':' + Digest::SHA256.hexdigest(JSON.generate([instance, *identity]))
    end

    def connection_key(app, team, source)
      key('connection', app, team, source['channel'], timestamp_id(source['ts']))
    end

    def closed_key(app, team, source)
      key('closed', app, team, source['channel'], timestamp_id(source['ts']), source['nonce'])
    end

    def import_key(issue_id, team, event)
      key('import', issue_id, team, event['channel'], timestamp_id(event['ts']))
    end

    def timestamp_id(value)
      match = value.to_s.match(/\A(\d{1,12})\.(\d{1,6})\z/)
      raise ArgumentError, 'Invalid Slack timestamp' unless match
      "#{match[1].to_i}.#{match[2].ljust(6, '0')}"
    end

    def submission_key(app, team, source)
      key('submission', app, team, source['user_id'], source['nonce'], source['disconnect'] == true)
    end

    def claim_submission(app, team, source)
      key = submission_key(app, team, source)
      with_redis do |redis|
        redis.call('SET', key, 'pending', 'NX') ? 'claimed' : redis.call('GET', key)
      end
    end

    def finish_submission(app, team, source)
      with_redis { |redis| redis.call('SET', submission_key(app, team, source), 'done') }
    end

    def release_submission(app, team, source)
      with_redis { |redis| redis.call('EVAL', RELEASE_SCRIPT, 1, submission_key(app, team, source), 'pending') }
    end

    def with_redis
      require 'sidekiq'
      Sidekiq.redis { |redis| yield redis }
    end

    def connection(app, team, source)
      raw = with_redis { |redis| redis.call('GET', connection_key(app, team, source)) }
      raw && JSON.parse(raw)
    end

    def connect(app, team, source)
      state = { 'issue_id' => source.fetch('issue_id'), 'cutoff' => source.fetch('cutoff'),
                'nonce' => source.fetch('nonce'), 'active' => true }
      with_redis { |redis| redis.call('EVAL', CONNECT_SCRIPT, 2, connection_key(app, team, source), closed_key(app, team, source), source['nonce'], JSON.generate(state)) }
    end

    def disconnect(app, team, source)
      state = { 'issue_id' => source.fetch('issue_id'), 'cutoff' => source.fetch('cutoff'),
                'nonce' => source.fetch('nonce'), 'active' => false }
      with_redis { |redis| redis.call('EVAL', DISCONNECT_SCRIPT, 2, connection_key(app, team, source), closed_key(app, team, source), source['nonce'], JSON.generate(state)) } == 1
    end

    def claim(issue_id, team, events)
      keys = events.map { |event| import_key(issue_id, team, event) }
      raise ArgumentError, 'Duplicate source messages' unless keys.uniq.size == keys.size
      return [nil, []] if keys.empty?
      token = 'pending:' + SecureRandom.hex(16)
      indices = with_redis { |redis| redis.call('EVAL', CLAIM_SCRIPT, keys.size, *keys, token) }
      [token, indices.map { |index| index.to_i - 1 }]
    rescue StandardError => e
      raise PendingImport, 'A previous import has an unresolved outcome' if e.message.include?('IMPORT_PENDING')
      raise
    end

    # Called while holding the Issue row lock. A pending entry with a journal
    # ID can be resolved after a crash by checking the committed journal; a
    # claim without one cannot have committed because it was not yet recorded.
    def recover(issue, team, events)
      keys = events.map { |event| import_key(issue.id, team, event) }
      return if keys.empty?
      with_redis do |redis|
        redis.call('MGET', *keys).each_with_index do |value, index|
          next unless value.to_s.start_with?('pending:')
          raise PendingImport, 'Invalid pending import state' unless value.match?(/\Apending:[0-9a-f]{32}(?::journal:[1-9]\d*)?\z/)
          match = value.match(/\Apending:[0-9a-f]{32}:journal:([1-9]\d*)\z/)
          journal = issue.journals.find_by(id: match[1].to_i) if match
          if journal && !journal_contains_event?(issue, journal, events[index])
            raise PendingImport, 'The committed journal no longer identifies the original Slack message'
          end
          disposition = journal ? 'done' : 'clear'
          redis.call('EVAL', RECOVER_SCRIPT, 1, keys[index], value, disposition)
        end
      end
    end

    def journal_contains_event?(issue, journal, event)
      notes = journal.notes.to_s
      urls = notes.scan(%r{https://[^\s<>"']+}).map { |url| url.sub(/[)\],.;]+\z/, '') }
      urls.concat(LinkQuotes.blocks(notes, project: issue.project).flat_map { |_, card| Array(card['source_urls'] || card['url']) })
      urls.any? do |url|
        target = LinkCards.parse(url)
        target && target['channel'] == event['channel'] && timestamp_id(target['ts']) == timestamp_id(event['ts'])
      end
    end

    def record_journal(issue_id, team, events, token, journal_id)
      raise ArgumentError, 'A persisted journal ID is required' unless journal_id.to_i.positive?
      keys = events.map { |event| import_key(issue_id, team, event) }
      recorded = "#{token}:journal:#{journal_id}"
      with_redis { |redis| redis.call('EVAL', RECORD_JOURNAL_SCRIPT, keys.size, *keys, token, recorded) }
      recorded
    end

    def finish(issue_id, team, events, token)
      return if events.empty?
      keys = events.map { |event| import_key(issue_id, team, event) }
      with_redis { |redis| redis.call('EVAL', FINISH_SCRIPT, keys.size, *keys, token) }
    end

    def release(issue_id, team, events, token)
      return if events.empty? || !token
      keys = events.map { |event| import_key(issue_id, team, event) }
      with_redis { |redis| redis.call('EVAL', RELEASE_SCRIPT, keys.size, *keys, token) }
    end
  end
end
