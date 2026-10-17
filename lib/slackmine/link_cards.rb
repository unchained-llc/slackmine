# frozen_string_literal: true

require 'uri'
require 'cgi'
require 'time'

module Slackmine
  module LinkCards
    module_function

    def enabled?(project)
      Slackmine.effective_config(project).dig('slack', 'link_cards', 'enabled') != false
    end

    def redmine_enabled?(project)
      enabled?(project) && Slackmine.effective_config(project).dig('slack', 'link_cards', 'redmine_enabled') != false
    end

    # Only parse Slack permalinks; never fetch the supplied URL itself.
    def parse(value)
      return unless value.is_a?(String) && value.length <= 2048
      uri = URI.parse(value)
      return unless uri.scheme == 'https' && uri.port == 443 && !uri.userinfo &&
                    uri.host.to_s.match?(/\A[a-z0-9][a-z0-9-]*\.slack\.com\z/i)
      match = uri.path.match(%r{\A/archives/([CDG][A-Z0-9]+)/p(\d{10,16})/?\z})
      return unless match && match[2].length > 6
      digits = match[2]
      query = URI.decode_www_form(uri.query.to_s).to_h
      thread = query['thread_ts']
      return if thread && !thread.match?(/\A\d+\.\d{6}\z/)
      { 'host' => uri.host.downcase, 'channel' => match[1],
        'ts' => "#{digits[0...-6]}.#{digits[-6..-1]}", 'thread_ts' => thread }
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def referenced?(text, target)
      text.to_s.scan(%r{https://[^\s<>"']+}).any? do |url|
        # Markdown/Textile punctuation can follow a bare permalink.
        parse(CGI.unescapeHTML(url.sub(/[)\],.;]+\z/, ''))) == target
      end
    end

    def source(issue, viewer, journal_id)
      return unless viewer.logged? && issue.visible?(viewer)
      return issue.description if journal_id.to_s.empty?
      return unless journal_id.to_s.match?(/\A[1-9]\d*\z/)
      journal = issue.journals.find_by(id: journal_id)
      return unless journal && (!journal.private_notes? || journal.user_id == viewer.id ||
                                viewer.allowed_to?(:view_private_notes, issue.project))
      journal.notes
    end

    def fetch(issue, viewer, url, journal_id: nil, api_cache: nil, deadline: nil)
      target = parse(url)
      return unless target && referenced?(source(issue, viewer, journal_id), target)
      fetch_for_project(issue.project, url, viewer: viewer, api_cache: api_cache, deadline: deadline)
    end

    # Used at save time after authorizing the edited source, including new records.
    def fetch_for_project(project, url, viewer: nil, api_cache: nil, deadline: nil)
      return unless enabled?(project)
      return unless viewer && viewer.logged?

      target = parse(url)
      return unless target
      Slackmine.with_project(project) do
        token = Slackmine.bot_token(project)
        return if token.to_s.empty?
        call = lambda do |method, body|
          key = [token, method, body]
          cache = api_cache || {}
          next cache[key] if cache.key?(key)
          remaining = deadline ? deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC) : 5
          raise Timeout::Error if remaining <= 0
          cache[key] = Slackmine.slack_api(method, body, token, form: true,
                                                         open_timeout: [2, remaining].min, read_timeout: [3, remaining].min)
        end
        # Reject a permalink from another workspace, even if channel IDs collide.
        auth = call.call('auth.test', {})
        return unless URI.parse(auth['url'].to_s).host.to_s.downcase == target['host']
        channel = target['channel']
        # A permalink is not authorization. Public and private channels both
        # require bot membership and the initiating user's verified membership.
        info = call.call('conversations.info', { 'channel' => channel })['channel']
        return unless info.is_a?(Hash) && info['id'] == channel && [true, false].include?(info['is_private']) &&
                      info['is_member'] == true && !info['is_im'] && !info['is_mpim'] &&
                      !info['is_ext_shared'] && !info['is_shared'] && !info['is_org_shared']
        slack_id = slack_identity(viewer, call)
        return unless slack_id && WorkObjects.viewer_for(slack_id)&.id == viewer.id
        cursor = nil
        seen = {}
        member = false
        20.times do
          params = { 'channel' => channel, 'limit' => 200 }
          params['cursor'] = cursor if cursor
          response = call.call('conversations.members', params)
          if Array(response['members']).include?(slack_id)
            member = true
            break
          end
          cursor = response.dig('response_metadata', 'next_cursor').to_s
          break if cursor.empty? || seen[cursor]
          seen[cursor] = true
        end
        return unless member
        ts = target['ts']
        body = { 'channel' => channel, 'oldest' => ts, 'latest' => ts, 'inclusive' => true, 'limit' => 1 }
        result = call.call('conversations.history', body)
        message = Array(result['messages']).find { |item| item['ts'] == ts }
        if !message && target['thread_ts']
          result = call.call('conversations.replies', body.merge('ts' => target['thread_ts']))
          message = Array(result['messages']).find { |item| item['ts'] == ts }
        end
        return unless message
        card = message_card(message, call)
        card['channel'] = info['name'] || channel
        root_ts = message['thread_ts'] || target['thread_ts']
        if root_ts && root_ts != ts
          card['thread_reply'] = true
          card['parent_url'] = "https://#{target['host']}/archives/#{channel}/p#{root_ts.delete('.')}"
          begin
            parent_result = call.call('conversations.history', body.merge('oldest' => root_ts, 'latest' => root_ts))
            parent = Array(parent_result['messages']).find { |item| item['ts'] == root_ts }
            card['parent'] = message_card(parent, call) if parent
          rescue Slackmine::SlackApiError, Timeout::Error, IOError, SystemCallError
            # Keep the reply and its thread link when the parent is unavailable.
          end
        elsif message['reply_count'].to_i > 0
          card['reply_count'] = message['reply_count'].to_i
        end
        card
      end
    rescue Slackmine::SlackApiError, URI::InvalidURIError, Timeout::Error, IOError, SystemCallError
      nil
    end

    # Authorization never uses the outgoing display-name/directory caches.
    def slack_identity(viewer, call)
      mapping = Slackmine.user_mapping
      key = [viewer.login.to_s, viewer.mail.to_s].find { |candidate| mapping.key?(candidate) }
      id = mapping[key] if key
      if !key && Slackmine.effective_config.dig('slack', 'auto_map_users_by_email') == true && !viewer.mail.to_s.strip.empty?
        id = call.call('users.lookupByEmail', { 'email' => viewer.mail.to_s.strip }).dig('user', 'id')
      end
      id if id.is_a?(String) && id.match?(/\A[UW][A-Z0-9]+\z/)
    end

    def optional_call(call, method, body)
      call.call(method, body) || {}
    rescue Slackmine::SlackApiError, Timeout::Error, IOError, SystemCallError
      {}
    end

    def user_profile(id, call)
      return {} unless id.to_s.match?(/\A[UW][A-Z0-9]+\z/)
      user = optional_call(call, 'users.info', { 'user' => id })['user'] || {}
      profile = user['profile'] || {}
      { 'name' => [profile['display_name'], profile['real_name'], user['name']].find { |v| !v.to_s.empty? },
        'avatar' => profile['image_48'] }
    end

    def message_card(message, call)
      author = message['username'] || message.dig('bot_profile', 'name')
      avatar = message.dig('bot_profile', 'icons', 'image_48')
      profile = user_profile(message['user'], call)
      author = profile['name'] || author
      avatar = profile['avatar'] || avatar
      if author.to_s.empty? && message['bot_id'].to_s.match?(/\AB[A-Z0-9]+\z/)
        bot = optional_call(call, 'bots.info', { 'bot' => message['bot_id'] })['bot'] || {}
        author = bot['name']
        avatar ||= bot.dig('icons', 'image_48')
      end
      text = MessageShortcuts.message_text(message).to_s[0, 6000]
      # Resolve a bounded number of mentions; rendering escapes profile names.
      names = {}
      text.scan(/<@([UW][A-Z0-9]+)(?:\|[^>]+)?>/).flatten.uniq.first(20).each do |id|
        names[id] = user_profile(id, call)['name']
      end
      text.scan(/<#([CDG][A-Z0-9]+)(?:\|[^>]+)?>/).flatten.uniq.first(20).each do |id|
        channel = optional_call(call, 'conversations.info', { 'channel' => id })['channel'] || {}
        # A public message can mention a private channel by ID. Do not use
        # the bot's broader privileges to disclose that channel's name.
        names[id] = channel['name'] if channel['is_private'] == false &&
          !channel['is_ext_shared'] && !channel['is_shared'] && !channel['is_org_shared']
      end
      avatar = LinkQuotes.safe_avatar(avatar)
      { 'author' => author.to_s.empty? ? Formatter.message('link_cards', 'unknown_author') : author, 'avatar' => avatar,
        'text' => text, 'names' => names, 'timestamp' => Time.at(message['ts'].to_f).utc.iso8601 }
    end

    def color(project)
      value = Slackmine.effective_config(project).dig('slack', 'link_cards', 'color').to_s
      value.match?(/\A#[0-9a-f]{6}\z/i) ? value : '#6D5DFB'
    end

  end

  if defined?(Redmine::Hook::ViewListener)
    class LinkCardsHook < Redmine::Hook::ViewListener
      render_on :view_layouts_base_html_head, partial: 'slackmine/link_card_assets'
    end
  end
end
