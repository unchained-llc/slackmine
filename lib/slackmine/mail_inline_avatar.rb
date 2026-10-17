# frozen_string_literal: true
require 'mail'
require 'nokogiri'
require 'net/http'
require 'uri'
require 'timeout'

module Slackmine
  module MailInlineAvatar
    MAX_BYTES = 256 * 1024
    MAX_IMAGES = 4
    module_function

    def embed(message)
      cache = {}
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      ([message] + message.all_parts).select { |part| part.mime_type == 'text/html' }.each do |html_part|
        html = html_part.body.decoded
        next unless html.include?('slackmine-mail-avatar')

        document = Nokogiri::HTML.parse(html, nil, html_part.charset || 'UTF-8')
        avatars = document.css('.slackmine-link-card img.slackmine-mail-avatar')
        next if avatars.empty?

        resources = Mail::Part.new(content_type: 'multipart/related')
        avatars.each do |avatar|
          source = avatar['src'].to_s
          unless cache.key?(source)
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            cache[source] = if cache.size < MAX_IMAGES && remaining > 0
                              fetch(source, remaining)
                            end
          end
          data = cache[source]
          unless data
            avatar.remove
            next
          end

          # Reuse a CID for repeated appearances of the same avatar in this HTML part.
          filename = "slackmine-avatar-#{cache.keys.index(source)}.#{data[:extension]}"
          unless resources.attachments[filename]
            resources.attachments.inline[filename] = { mime_type: data[:mime_type], content: data[:content] }
          end
          avatar['src'] = resources.attachments[filename].url
          # Apply after the mail template's responsive image rules have been inlined.
          avatar['style'] = 'display: block; width: 28px; height: 28px; max-width: 28px; border-radius: 6px'
          avatar.remove_attribute('srcset')
          avatar.remove_attribute('class')
        end
        html_part.content_transfer_encoding = nil
        html_part.body = document.to_html
        next if resources.parts.empty?

        if html_part.equal?(message)
          body = Mail::Part.new(content_type: message.content_type, body: html_part.body.decoded)
          message.body = nil
          message.content_type = 'multipart/related'
          message.add_part(body)
          resources.parts.each { |part| message.add_part(part) }
        else
          parent = parent_of(message, html_part)
          if parent.mime_type == 'multipart/related'
            resources.parts.each { |part| parent.add_part(part) }
          else
            images = resources.parts.dup
            resources.parts.clear
            resources.add_part(html_part)
            images.each { |part| resources.add_part(part) }
            parent.parts[parent.parts.index(html_part)] = resources
          end
        end
      end
    end

    def allowed_url(source)
      avatar_uri(source)&.to_s
    end

    def fetch(source, seconds)
      uri = avatar_uri(source)
      return unless uri

      bytes = +''.b
      Timeout.timeout([seconds, 3].min) do
        # Revalidate every redirect; never send credentials to avatar services.
        3.times do |attempt|
          redirect = nil
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 2, read_timeout: 2) do |http|
            http.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
              if response.is_a?(Net::HTTPRedirection)
                return unless gravatar_uri?(uri) && attempt < 2
                redirect = avatar_uri(URI.join(uri.to_s, response['Location'].to_s).to_s)
                return unless redirect
              else
                return unless response.is_a?(Net::HTTPSuccess)
                return if response['Content-Length'].to_i > MAX_BYTES
                response.read_body do |chunk|
                  return if bytes.bytesize + chunk.bytesize > MAX_BYTES
                  bytes << chunk
                end
              end
            end
          end
          break unless redirect
          uri = redirect
        end
      end
      if bytes.start_with?("\x89PNG\r\n\x1a\n".b)
        { content: bytes, mime_type: 'image/png', extension: 'png' }
      elsif bytes.start_with?("\xff\xd8\xff".b)
        { content: bytes, mime_type: 'image/jpeg', extension: 'jpg' }
      end
    rescue StandardError
      # Avatar failure must not prevent notification delivery or retain remote images.
      nil
    end

    def gravatar_uri?(uri)
      %w[secure.gravatar.com gravatar.com www.gravatar.com 0.gravatar.com 1.gravatar.com 2.gravatar.com].include?(uri.host) &&
        uri.path.match?(%r{\A/avatar/(?:[a-f0-9]{32}|[a-f0-9]{64})(?:\.jpg)?\z}i)
    end

    def avatar_uri(source)
      return if source.bytesize > 2048
      uri = URI.parse(source)
      return unless uri.scheme == 'https' && uri.port == 443 && !uri.userinfo && !uri.fragment
      return uri if uri.host == 'avatars.slack-edge.com' && !uri.query
      if uri.host == 'a.slack-edge.com'
        return uri if !uri.query && uri.path.match?(%r{\A/[^?#]*/img/avatars/ava_[a-z0-9_-]+\.png\z}i)
      elsif %w[i0.wp.com i1.wp.com i2.wp.com].include?(uri.host)
        # Gravatar proxies custom defaults through WordPress; allow Slack images only.
        return unless uri.query == 'ssl=1'
        target = URI.parse('https:/' + uri.path)
        return uri if %w[avatars.slack-edge.com a.slack-edge.com].include?(target.host) && avatar_uri(target.to_s)
      elsif gravatar_uri?(uri)
        params = URI.decode_www_form(uri.query.to_s)
        return unless params.map(&:first).uniq.size == params.size
        return unless params.all? do |key, value|
          case key
          when 's', 'size' then value.match?(/\A[0-9]{1,4}\z/) && value.to_i.between?(1, 2048)
          when 'd', 'default'
            next false unless %w[avatars.slack-edge.com a.slack-edge.com].include?(URI.parse(value).host)
            avatar_uri(value)
          else false
          end
        end
        return uri
      end
      nil
    rescue URI::InvalidURIError, ArgumentError
      nil
    end
    private_class_method :avatar_uri, :gravatar_uri?

    def parent_of(node, target)
      return node if node.parts.include?(target)
      node.parts.each do |part|
        parent = parent_of(part, target)
        return parent if parent
      end
      nil
    end
    private_class_method :parent_of
  end
end
