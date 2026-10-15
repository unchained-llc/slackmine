# frozen_string_literal: true

module Slackmine
  module ChannelMatching
    CACHE_TTL = 600
    CACHE_LIMIT = 32
    CACHE_LOCK = Mutex.new
    module_function

    def normalized_name(value)
      value.to_s.strip.downcase.gsub(/[[:space:]]+/, '-')
    end

    def channel_for(project)
      return unless Slackmine.effective_config(project).dig('slack', 'auto_map_channels_by_name') == true

      name = normalized_name(project.identifier)
      token = Slackmine.bot_token(project)
      return if name.empty? || token.empty?

      ids = directory(token)[name]
      ids.first if ids && ids.length == 1
    end

    def directory(token)
      # Process memory only: no DB, Redis, Rails.cache, or file dependency.
      key = Digest::SHA256.hexdigest(token)
      CACHE_LOCK.synchronize do
        @cache ||= {}
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @cache.delete_if { |_key, entry| entry[:expires_at] <= now }
        return @cache[key][:channels] if @cache.key?(key)

        channels = fetch_directory(token)
        @cache.shift if @cache.length >= CACHE_LIMIT
        @cache[key] = { channels: channels, expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + CACHE_TTL }
        channels
      end
    end

    def fetch_directory(token)
      channels = Hash.new { |hash, name| hash[name] = [] }
      cursor = nil
      seen = {}
      10.times do
        request = { 'types' => 'public_channel,private_channel', 'exclude_archived' => true, 'limit' => 200 }
        request['cursor'] = cursor if cursor
        # Unlike conversations.list, this returns only the bot's memberships.
        response = Slackmine.slack_api('users.conversations', request, token,
          form: true, open_timeout: 2, read_timeout: 3)
        Array(response['channels']).each do |channel|
          next unless channel.is_a?(Hash) && !channel['is_archived'] && !channel['is_im'] && !channel['is_mpim']
          next if channel['is_member'] == false
          id = channel['id'].to_s
          name = normalized_name(channel['name'])
          next unless id.match?(/\A[CG][A-Z0-9]+\z/) && !name.empty?

          channels[name] << id unless channels[name].include?(id)
        end
        cursor = response.dig('response_metadata', 'next_cursor').to_s.strip
        return channels.to_h if cursor.empty?
        raise 'Repeated Slack channel cursor' if seen[cursor]

        seen[cursor] = true
      end
      raise 'Slack channel listing exceeded 10 pages'
    rescue StandardError => e
      Rails.logger&.warn("Slackmine: automatic channel matching failed: #{e.class}")
      {}
    end
  end
end
