# frozen_string_literal: true

require 'uri'
require 'net/http'
require 'resolv'
require 'ipaddr'
require 'nokogiri'

module Slackmine
  module UrlPreviewFetcher
    MAX_BYTES = 256 * 1024
    BLOCKED = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 100::/64 2001:db8::/32 fc00::/7 fe80::/10 ff00::/8].map { |range| IPAddr.new(range) }.freeze

    def self.fetch(url, redirects = 0)
      uri = URI.parse(url.to_s)
      return unless %w[http https].include?(uri.scheme) && uri.hostname && !uri.userinfo && [80, 443].include?(uri.port) && url.to_s.bytesize <= 2048
      addresses = Resolv.getaddresses(uri.hostname).map { |address| IPAddr.new(address) }
      return if addresses.empty? || addresses.any? { |ip| BLOCKED.any? { |range| range.ipv4? == ip.ipv4? && range.include?(ip) } }
      http = Net::HTTP.new(uri.hostname, uri.port, nil)
      http.ipaddr = addresses.first.to_s
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 3
      http.read_timeout = 3
      body = +''
      http.start do |connection|
        connection.request(Net::HTTP::Get.new(uri.request_uri, {'Accept' => 'text/html', 'User-Agent' => 'Slackmine-LinkPreview/1.0'})) do |response|
          if response.is_a?(Net::HTTPRedirection) && response['location'] && redirects < 3
            return fetch(URI.join(uri.to_s, response['location']).to_s, redirects + 1)
          end
          return unless response.is_a?(Net::HTTPSuccess) && response['content-type'].to_s.match?(/\Atext\/html(?:\s*;|\s*\z)/i)
          response.read_body do |chunk|
            body << chunk
            break if body.bytesize >= MAX_BYTES
          end
        end
      end
      document = Nokogiri::HTML(body.byteslice(0, MAX_BYTES))
      title = document.at('meta[property="og:title"]')&.[]('content').to_s.strip
      title = document.at('title')&.text.to_s.strip if title.empty?
      return if title.empty?
      description = document.at('meta[property="og:description"]')&.[]('content').to_s.strip
      description = document.at('meta[name="description"]')&.[]('content').to_s.strip if description.empty?
      image = document.at('meta[property="og:image"]')&.[]('content').to_s.strip
      image_uri = URI.join(uri.to_s, image) unless image.empty?
      image_url = image_uri.to_s if image_uri && image_uri.scheme == 'https' && image_uri.hostname && !image_uri.userinfo
      {title: title.gsub(/\s+/, ' ')[0, 300], description: description.gsub(/\s+/, ' ')[0, 500], host: uri.hostname, image: image_url}
    rescue URI::InvalidURIError, ArgumentError, SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
      nil
    end
  end
end
