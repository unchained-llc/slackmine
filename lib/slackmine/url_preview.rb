# frozen_string_literal: true

require 'cgi'
require 'uri'
require_relative 'url_preview_fetcher'

module Slackmine
  # Render independent OGP cards in Slack notifications.
  module UrlPreview
    IMAGE_ALT = 'Slackmine URL preview'.freeze
    module_function

    def urls_in(notes)
      source = notes.to_s.gsub(/```[^\n]*\n.*?```/m, '').gsub(/`[^`]+`/, '')
      source.scan(%r{(?:https?://|www\.)[^\s<>"'`]+}i).map do |raw|
        raw = raw.sub(/[.,;!?:]+\z/, '')
        raw = raw[0...-1] while raw.end_with?(')') && raw.count(')') > raw.count('(')
        value = raw.match?(/\Awww\./i) ? "http://#{raw}" : raw
        next if value.bytesize > 2048
        begin
          uri = URI.parse(value)
          next unless %w[http https].include?(uri.scheme) && uri.hostname && !uri.userinfo
          [raw, value]
        rescue URI::InvalidURIError
          nil
        end
      end.compact.uniq
    end

    def mark(payload, project:, journal_id:, context:)
      return payload unless Slackmine.effective_config(project).dig('slack', 'url_previews') == true
      return payload unless journal_id && context.is_a?(Hash) && context['journal_id'].to_i == journal_id.to_i
      return payload if context['event'] == 'comment_deleted' || Slackmine.files_transfer_restricted?(project)
      return payload unless Slackmine::NotificationSafety.allowed?(context, project)
      journal = Journal.find_by(id: journal_id)
      candidates = urls_in(journal&.notes)
      rendered = payload.to_s
      urls = candidates.select { |raw, _| rendered.include?(CGI.escapeHTML(raw)) }.map(&:last).uniq
      attachments = payload['attachments']
      return payload unless attachments.is_a?(Array) && attachments.length == 1 && attachments[0]['blocks'].is_a?(Array)
      available = [45 - attachments[0]['blocks'].length, 0].max
      return payload if urls.empty? || available.zero?
      cards = urls.first(available).map do |url|
        metadata = UrlPreviewFetcher.fetch(url)
        next unless metadata && metadata[:title].to_s != ''
        escape = ->(value) { CGI.escapeHTML(value.to_s).gsub('&#39;', "'").gsub('&quot;', '"') }
        text = "*<#{escape.call(url)}|#{escape.call(metadata[:title].to_s[0, 250])}>*"
        description = escape.call(metadata[:description].to_s[0, 700])
        text += "\n#{description}" unless description.empty?
        text += "\n#{escape.call(metadata[:host].to_s[0, 200])}"
        block = {'type' => 'section', 'text' => {'type' => 'mrkdwn', 'text' => text}}
        image = metadata[:image].to_s
        if image.bytesize <= 2000 && image.match?(/\Ahttps:\/\/[^\s<>]+\z/)
          block['accessory'] = {'type' => 'image', 'image_url' => image, 'alt_text' => IMAGE_ALT}
        end
        block
      end.compact
      return payload if cards.empty? || !Slackmine::NotificationSafety.allowed?(context, project)
      attachment = attachments[0].merge('blocks' => attachments[0]['blocks'] + cards)
      payload.merge('attachments' => [attachment], 'unfurl_links' => false, 'unfurl_media' => false)
    rescue StandardError => e
      Rails.logger&.warn("Slackmine: URL preview preparation unavailable (#{e.class})")
      payload
    end

    def without_preview_images(request)
      changed = false
      attachments = Array(request['attachments']).map do |attachment|
        blocks = Array(attachment['blocks']).map do |block|
          if block.dig('accessory', 'alt_text') == IMAGE_ALT
            changed = true
            block.reject { |key, _| key == 'accessory' }
          else
            block
          end
        end
        attachment.merge('blocks' => blocks)
      end
      changed ? request.merge('attachments' => attachments) : nil
    end
  end
end
