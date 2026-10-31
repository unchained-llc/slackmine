# frozen_string_literal: true

module Slackmine
  module UseSlackAvatars
    REFRESH_INTERVAL = 600
    FAILURE_RETRY_INTERVAL = 60

    module_function

    def enabled?
      Slackmine.config.dig('slack', 'use_slack_avatars') == true
    end

    def cache_key(user)
      # Include identity and global mapping settings so edits cannot reuse an old identity.
      settings = Slackmine.config
      fingerprint = [Slackmine.bot_token(nil), settings['users'], settings.dig('slack', 'auto_map_users_by_name'),
                     settings.dig('slack', 'auto_map_users_by_email'), settings.dig('slack', 'events', 'team_id'),
                     user.login, user.mail].to_json
      "slackmine/use-slack-avatars/#{user.id}/#{Digest::SHA256.hexdigest(fingerprint)}"
    end

    def safe_url(value)
      uri = URI.parse(value.to_s)
      return unless uri.is_a?(URI::HTTPS) && uri.port == 443 && !uri.userinfo && !uri.query && !uri.fragment
      return uri.to_s if uri.host == 'avatars.slack-edge.com'
      return uri.to_s if uri.host == 'a.slack-edge.com' && uri.path.match?(%r{\A/[^?#]*/img/avatars/ava_[a-z0-9_-]+\.png\z}i)

      nil
    rescue URI::InvalidURIError
      nil
    end

    # Keep one last-known image per Redmine user. The cache key includes the
    # identity configuration, so an old mapping cannot supply a new user's image.
    def stale_key(user)
      "slackmine/use-slack-avatars-last/#{user.id}"
    end

    def stale_url(user, key)
      entry = Rails.cache.read(stale_key(user))
      return unless entry.is_a?(Hash) && entry['identity'] == key

      safe_url(entry['url'])
    end

    def lookup(user)
      return unless enabled? && Rails.cache

      key = cache_key(user)
      cached = Rails.cache.read(key)
      return safe_url(cached) || stale_url(user, key) unless cached.nil?

      stale = stale_url(user, key)

      lock = "#{key}/pending"
      begin
        if Rails.cache.write(lock, true, unless_exist: true, expires_in: 120)
          job = SlackmineUseSlackAvatarsJob.perform_later(user.id, key)
          Rails.cache.delete(lock) unless job
        end
      rescue StandardError => e
        Rails.cache.delete(lock) rescue nil
        Rails.logger&.warn("Slackmine: Slack avatar refresh enqueue failed: #{e.class}")
      end
      stale
    rescue StandardError => e
      Rails.logger&.warn("Slackmine: Slack avatar lookup unavailable: #{e.class}")
      nil
    end

    def refresh(user, key)
      return unless enabled? && cache_key(user) == key

      url = Slackmine.with_project(nil) do
        token = Slackmine.bot_token(nil)
        id = Slackmine.slack_user_id_for(user)
        if id && !token.to_s.empty?
          member = Slackmine.slack_api('users.info', { 'user' => id }, token, form: true, open_timeout: 2, read_timeout: 3)['user']
          team = Slackmine.config.dig('slack', 'events', 'team_id').to_s
          if member.is_a?(Hash) && !member['deleted'] && !member['is_bot'] && !member['is_app_user'] && !member['is_stranger'] &&
             (team.empty? || (member['team_id'] || member['team']) == team)
            profile = member['profile'].is_a?(Hash) ? member['profile'] : {}
            %w[image_192 image_72 image_48 image_32 image_24].map { |name| safe_url(profile[name]) }.compact.first
          end
        end
      end
      if url
        Rails.cache.write(stale_key(user), { 'identity' => key, 'url' => url })
      elsif stale_url(user, key)
        Rails.cache.delete(stale_key(user))
      end
      Rails.cache.write(key, url || '', expires_in: url ? REFRESH_INTERVAL : FAILURE_RETRY_INTERVAL)
    rescue StandardError => e
      Rails.logger&.warn("Slackmine: Slack avatar refresh failed: #{e.class}")
      Rails.cache.write(key, '', expires_in: FAILURE_RETRY_INTERVAL)
    ensure
      Rails.cache.delete("#{key}/pending") if Rails.cache
    end

    module HelperPatch
      def avatar(user, options = {})
        return super unless Slackmine::UseSlackAvatars.enabled? && user.is_a?(User) && !user.is_a?(AnonymousUser) && user.id

        url = Slackmine::UseSlackAvatars.lookup(user)
        return super unless url

        fallback = super(user, options.dup)
        attributes = options.dup
        size = (attributes.delete(:size) || GravatarHelper::DEFAULT_OPTIONS[:size]).to_i
        attributes[:class] = ['avatar', attributes[:class]].compact.join(' ')
        attributes[:title] ||= user.name
        attributes[:alt] ||= user.name
        attributes[:width] ||= size
        attributes[:height] ||= size
        attributes[:data] = (attributes[:data] || {}).merge(slackmine_avatar_fallback: fallback.to_s)
        image_tag(url, attributes)
      end
    end
  end

  if defined?(Redmine::Hook::ViewListener)
    class UseSlackAvatarsHook < Redmine::Hook::ViewListener
      render_on :view_layouts_base_html_head, partial: 'slackmine/use_slack_avatars_assets'
    end
  end
end
