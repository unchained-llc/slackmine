# frozen_string_literal: true
require 'base64'
require 'json'
require 'securerandom'
require 'openssl'

module Slackmine
  # Quotes are plain text in existing description/notes columns, not a new table.
  module LinkQuotes
    PATTERN = /\[slack-quote:([A-Za-z0-9+\/=]+):([a-f0-9]{16})\]\r?\n(.*?)\r?\n\[\/slack-quote:\2\]/m
    module_function

    def resolved_text(card)
      names = card['names'] || {}
      card['text'].to_s.gsub(/<([@#])([A-Z0-9]+)(?:\|[^>]+)?>/) do |token|
        kind, id = Regexp.last_match(1), Regexp.last_match(2)
        name = names[id]
        name.to_s.empty? ? token : "<#{kind}#{id}|#{name.to_s.gsub(/[<>|\r\n]/, ' ')}>"
      end
    end

    def encode(card, url)
      data = card.merge('url' => url).reject { |key, _| key == 'text' }
      body = resolved_text(card)
      if card['parent']
        parent_text = resolved_text(card['parent'])[0, 500]
        data['parent'] = card['parent'].reject { |key, _| key == 'text' }
        data['parent_length'] = parent_text.length
        body = parent_text + "\n\n" + body
      end
      id = SecureRandom.hex(8)
      data.delete('verified')
      data.delete('signature')
      data['signature'] = signature(data, body)
      "[slack-quote:#{Base64.strict_encode64(JSON.generate(data))}:#{id}]\n#{body}\n[/slack-quote:#{id}]"
    end

    def decode(metadata, body)
      return if metadata.length > 32_768 || body.length > 12_000
      data = JSON.parse(Base64.strict_decode64(metadata))
      return unless data.is_a?(Hash) && LinkCards.parse(data['url'])
      return unless %w[author channel timestamp].all? { |key| data[key].is_a?(String) }
      Time.iso8601(data['timestamp'])
      if data.key?('source_urls')
        urls = data['source_urls']
        target = identity(data['url'])
        return unless urls.is_a?(Array) && urls.size.between?(1, 20) && urls.first == data['url'] &&
                      urls.all? { |url| url.is_a?(String) && identity(url)&.first(2) == target.first(2) }
      end
      digest = data.delete('signature')
      data.delete('verified')
      expected = signature(data, body)
      verified = digest.is_a?(String) && digest.bytesize == expected.bytesize &&
        digest.bytes.zip(expected.bytes).reduce(0) { |diff, (a, b)| diff | (a ^ b) }.zero?
      unless verified
        unverified = { 'url' => data['url'], 'text' => body, 'verified' => false,
                 'author' => Formatter.message('link_cards', 'unverified_quote'), 'channel' => '', 'timestamp' => data['timestamp'] }
        # Keep validated source references for deduplication only. They never
        # authenticate the edited body, author or attachment associations.
        unverified['source_urls'] = data['source_urls'] if data.key?('source_urls')
        return unverified
      end
      data['verified'] = true
      Time.iso8601(data['timestamp'])
      return unless data['names'].nil? || valid_names?(data['names'])
      %w[thread_image_ids thread_file_ids].each do |key|
        next unless data.key?(key)
        ids = data[key]
        return unless ids.is_a?(Array) && ids.size.between?(1, 10) && ids.uniq == ids &&
                      ids.all? { |id| id.is_a?(Integer) && id > 0 }
      end
      data['avatar'] = safe_avatar(data['avatar'])
      if data['parent_url']
        return unless LinkCards.parse(data['parent_url'])
      end
      if data['parent']
        parent = data['parent']
        length = data['parent_length']
        return unless parent.is_a?(Hash) && length.is_a?(Integer) && length.between?(0, 500) && body[length, 2] == "\n\n"
        return unless %w[author timestamp].all? { |key| parent[key].is_a?(String) }
        Time.iso8601(parent['timestamp'])
        return unless parent['names'].nil? || valid_names?(parent['names'])
        parent['avatar'] = safe_avatar(parent['avatar'])
        parent['text'] = body[0, length]
        data['text'] = body[(length + 2)..-1]
      else
        data['text'] = body
      end
      return if data['thread_reply'] && !data['parent_url']
      data
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end

    def valid_names?(names)
      names.is_a?(Hash) && names.all? { |key, value| key.is_a?(String) && (value.nil? || value.is_a?(String)) }
    end

    def safe_avatar(value)
      MailInlineAvatar.allowed_url(value.to_s)
    end

    def signature(data, body)
      key = Rails.application.key_generator.generate_key('slackmine/link-quotes/v1', 32)
      OpenSSL::HMAC.hexdigest('SHA256', key, JSON.generate([data, body.gsub(/\r\n?/, "\n")]))
    end

    def blocks(text)
      text.to_s.to_enum(:scan, PATTERN).each_with_object([]) do |_, result|
        match = Regexp.last_match
        card = decode(match[1], match[3])
        result << [match[0], card] if card
      end
    end

    def plain_source(text, project: Thread.current[:slackmine_project])
      source = text.to_s.dup
      if source.encoding == Encoding::ASCII_8BIT && source.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        source.force_encoding(Encoding::UTF_8)
      end
      source.gsub(PATTERN) do |raw|
        match = Regexp.last_match
        card = decode(match[1], match[3])
        next raw unless card
        if card['verified'] == false
          next Formatter.message('link_cards', 'unverified_quote', project: project) + "\n" + card['text']
        end
        parent = card['parent']
        prefix = parent ? LinkCards.link_message('plain_parent', project: project, author: parent['author'], text: parent['text']) : ''
        LinkCards.link_message('plain_quote', project: project, author: card['author'], channel: card['channel'], timestamp: card['timestamp'], urls: Array(card['source_urls'] || card['url']).join("\n"), prefix: prefix, text: card['text'])
      end
    end

    def editable_source?(issue, viewer)
      return false unless viewer && viewer.logged?
      issue.new_record? ? viewer.allowed_to?(:add_issues, issue.project) : issue.visible?(viewer)
    end

    def import(text, issue, viewer)
      return text unless LinkCards.enabled?(issue.project)

      return text unless text.to_s.match?(/\.slack\.com\/archives\//i) && editable_source?(issue, viewer)
      existing = blocks(text)
      scan_text = text.to_s.dup
      existing.each { |raw, _| scan_text = scan_text.gsub(raw, '') }
      # Use Redmine's own formatter to exclude inline/fenced code in Markdown or Textile.
      html = Redmine::WikiFormatting.to_html(Setting.text_formatting, scan_text)
      links = Nokogiri::HTML.fragment(html).css('a[href]').reject do |anchor|
        anchor.ancestors.any? { |node| %w[pre code].include?(node.name) }
      end.map { |anchor| anchor['href'] }.select { |url| LinkCards.parse(url) }
      # Editing a snapshot invalidates its signature; it is not a request to
      # fetch the original again and append a second, authenticated card.
      imported = existing.flat_map { |_, card| Array(card['source_urls'] || card['url']).map { |url| identity(url) } }
      cache = {}
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      quotes = []
      batch_cards = []
      links.uniq.first(20).each do |url|
        key = identity(url)
        next if imported.include?(key)
        snapshot = thread_attachments(:slackmine_thread_messages, url) if Thread.current[:slackmine_thread_comment]
        break if !snapshot && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        card = if snapshot
                 thread_message_card(snapshot[:message], issue.project, cache, deadline)
               else
                 LinkCards.fetch_for_project(issue.project, url, viewer: viewer, api_cache: cache, deadline: deadline)
               end
        next unless card
        # Notification replies already have their parent comment in Redmine.
        if Thread.current[:slackmine_thread_comment]
          card = card.reject { |key, _| %w[thread_reply parent parent_url].include?(key) }
          images = thread_attachments(:slackmine_thread_images, url)
          if images && !images[:ids].empty? && identity(images[:url]) == identity(url)
            card = card.merge('thread_image_ids' => images[:ids])
          end
        end
        files = thread_attachments(:slackmine_thread_files, url) if Thread.current[:slackmine_thread_comment]
        if files && !files[:ids].empty? && identity(files[:url]) == identity(url)
          card = card.merge('thread_file_ids' => files[:ids])
        end
        quote = encode(card, url)
        next if blocks(quote).empty?
        quotes << quote
        batch_cards << [card, url] if snapshot
        imported << key
      end
      if batch_cards.size > 1 && batch_cards.size == quotes.size
        combined = batch_cards.first.first.merge(
          'text' => batch_cards.map { |card, _| resolved_text(card) }.join("\n"),
          'names' => {}, 'source_urls' => batch_cards.map(&:last))
        %w[thread_image_ids thread_file_ids].each do |key|
          ids = batch_cards.flat_map { |card, _| Array(card[key]) }.uniq
          combined[key] = ids unless ids.empty?
        end
        quote = encode(combined, batch_cards.first.last)
        quotes = [quote] unless blocks(quote).empty?
      end
      quotes.empty? ? text : text.to_s.rstrip + "\n\n" + quotes.join("\n\n")
    end

    def thread_attachments(key, url)
      entries = Thread.current[key]
      entries = [entries] if entries.is_a?(Hash)
      Array(entries).find { |entry| identity(entry[:url]) == identity(url) }
    end

    def thread_message_card(message, project, cache, deadline)
      token = Slackmine.bot_token(project)
      call = lambda do |method, body|
        key = [token, method, body]
        next cache[key] if cache.key?(key)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout::Error if remaining <= 0
        cache[key] = Slackmine.slack_api(method, body, token, form: true,
          open_timeout: [2, remaining].min, read_timeout: [3, remaining].min)
      end
      info = LinkCards.optional_call(call, 'conversations.info', { 'channel' => message['channel'] })['channel'] || {}
      LinkCards.message_card(message, call).merge('channel' => info['name'] || message['channel'])
    end

    def identity(url)
      target = LinkCards.parse(url)
      target && target.values_at('host', 'channel', 'ts')
    end
  end
end
