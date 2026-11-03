# frozen_string_literal: true
require 'mail'
require 'nokogiri'

module Slackmine
  # Embed only the bundled public logo; never fetch URLs or user attachments.
  module MailInlineIcon
    # A relative placeholder survives Rails sanitization; replace it only after rendering.
    SOURCE = 'slackmine-bundled-logo.png'.freeze
    PATH = File.expand_path('../../assets/images/slack-mark.png', __dir__).freeze
    module_function

    def embed(message)
      parts = [message] + message.all_parts
      parts.select { |part| part.mime_type == 'text/html' }.each do |html_part|
        html = html_part.body.decoded
        next unless html.include?(SOURCE)

        document = Nokogiri::HTML.parse(html, nil, html_part.charset || 'UTF-8')
        icons = document.css('.slackmine-link-card img.slackmine-mail-icon').select { |img| img['src'] == SOURCE }
        next if icons.empty?

        related = Mail::Part.new
        related.content_type = 'multipart/related'
        related.attachments.inline['slackmine-logo.png'] = {mime_type: 'image/png', content: File.binread(PATH)}
        image = related.attachments['slackmine-logo.png']
        icons.each do |img|
          img['src'] = image.url
          # Set alignment after template sanitization and CSS processing.
          img['style'] = 'display: block; width: 16px; height: 16px; margin: 0'
        end
        html = document.to_html

        if html_part.equal?(message)
          body_part = Mail::Part.new
          body_part.content_type = message.content_type
          body_part.body = html
          message.body = nil
          message.content_type = related.content_type
          message.content_transfer_encoding = nil
          message.add_part(body_part)
          related.parts.each { |part| message.add_part(part) }
        else
          parent = parent_of(message, html_part)
          html_part.content_transfer_encoding = nil
          html_part.body = html
          # Templates may already attach logos/avatars around the alternative
          # body. Keep all CID resources in that existing related scope.
          container = related_parent_of(message, html_part)
          if container
            container.add_part(image)
            next
          end
          # PartsList insertion bypasses Mail#add_part's boundary initialization.
          related.parts.clear
          related.add_part(html_part)
          related.add_part(image)
          parent.parts[parent.parts.index(html_part)] = related
        end
      end
    end

    def parent_of(node, target)
      return node if node.parts.include?(target)
      node.parts.each do |part|
        parent = parent_of(part, target)
        return parent if parent
      end
      nil
    end
    private_class_method :parent_of

    def related_parent_of(node, target)
      parent = parent_of(node, target)
      return unless parent
      return parent if parent.mime_type == 'multipart/related'

      related_parent_of(node, parent)
    end
    private_class_method :related_parent_of
  end
end
