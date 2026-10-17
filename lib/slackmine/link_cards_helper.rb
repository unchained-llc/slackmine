# frozen_string_literal: true
require 'nokogiri'
require_relative 'slack_markup'

module Slackmine
  module LinkCardsHelper
    def textilizable(*args)
      options = args.last.is_a?(Hash) ? args.last : {}
      object, attribute = args.size >= 2 && !args[1].is_a?(Hash) ? args.first(2) : [options[:object], nil]
      preview = args.first.is_a?(String) && respond_to?(:controller_name) &&
                controller_name == 'previews' && %w[issue text].include?(action_name) && options[:formatting] != false
      if preview
        issue = object if object.is_a?(Issue)
        journal_id = nil
      elsif object.is_a?(Issue) && attribute == :description
        issue = object; journal_id = nil
      elsif object.is_a?(Journal) && attribute == :notes && object.journalized.is_a?(Issue)
        issue = object.journalized; journal_id = object.id
      else
        return super
      end
      project = preview ? (issue ? issue.project : @project) : issue.project
      card_view = respond_to?(:controller_name) && options[:formatting] != false &&
                  (preview || (controller_name == 'issues' && action_name == 'show' && request.format.html?) ||
                   (controller_name == 'journals' && action_name == 'update' && request.format.js?))
      mail_cards = LinkCards.enabled?(project) &&
                   Slackmine.effective_config(project).dig('slack', 'link_cards', 'mail_enabled') != false
      render_cards = card_view ? LinkCards.redmine_enabled?(project) : mail_cards
      raw = if preview
              args.first
            elsif card_view
              LinkCards.source(issue, User.current, journal_id)
            elsif object.respond_to?(attribute)
              object.public_send(attribute).to_s
            end
      return super unless raw
      time_formatter = ->(value) { format_time(Time.iso8601(value)) }
      quotes = LinkQuotes.blocks(raw, project: project)
      mail_icon = card_view || !mail_cards ? nil : '<img class="slackmine-mail-icon" src="slackmine-bundled-logo.png" alt="" width="16" height="16">'
      replacements = {}
      quote_urls = {}
      prepared = raw.to_s.dup
      rendered_quotes = []
      LinkCards.quote_groups(raw, quotes).each do |group|
        block, card = group.first
        card = LinkCards.combine_conversation(group.map(&:last)) if group.size > 1
        rendered_quotes << card
        token = "SLACKQUOTE#{SecureRandom.hex(16)}"
        quote_urls[token] = group.size == 1 ? (card['source_urls'] || card['url']) :
                            group.flat_map { |_, entry| Array(entry['source_urls'] || entry['url']) }
        replacements[token] = if options[:formatting] == false || !render_cards
                                %(<span style="white-space: pre-wrap">#{SlackMarkup.escape(group.map { |source, _| LinkQuotes.plain_source(source, project: project) }.join("\n\n"))}</span>)
                              else
                                LinkCards.render_card(card, card['url'], project,
                                                      time_formatter: time_formatter, icon_html: mail_icon)
                              end
        prepared = prepared.sub(block, token)
        group.drop(1).each { |source, _| prepared = prepared.sub(source, '') }
      end
      html = quotes.empty? ? super : super(prepared, options.merge(object: object))
      unless replacements.empty?
        fragment = Nokogiri::HTML.fragment(html.to_s)
        quote_paragraphs = fragment.css('p').select { |node| replacements.keys.any? { |token| node.text.include?(token) } }
        LinkCards.place_saved_cards(fragment, replacements, quote_urls, project: project) if render_cards
        fragment.xpath('.//text()').each do |node|
          next unless replacements.keys.any? { |token| node.text.include?(token) }
          pieces = node.text.split(/(#{Regexp.union(replacements.keys)})/)
          node.replace(Nokogiri::HTML.fragment(pieces.map { |piece| replacements[piece] || SlackMarkup.escape(piece) }.join))
        end
        # The appended quote placeholders may have had their own paragraphs.
        quote_paragraphs.each { |node| node.remove if node.text.strip.empty? && node.element_children.all? { |child| child.name == 'br' } }
        html = fragment.to_html
      end
      html = LinkCards.place_reply_images(html, rendered_quotes, attachments: issue.attachments) if journal_id
      html = LinkCards.place_reply_files(html, rendered_quotes, attachments: issue.attachments) if journal_id
      return html.html_safe unless card_view && render_cards
      @slack_link_card_state ||= { api: {}, cards: {}, count: 0,
                                   deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5 }
      live_options = preview ? { preview_source: raw, project: project } : {}
      html = LinkCards.render_links(html, issue, User.current, journal_id, @slack_link_card_state,
                             **live_options,
                             time_formatter: time_formatter,
                             quoted_urls: quotes.flat_map { |_, card| Array(card['source_urls'] || card['url']) })
      html.html_safe
    end
  end

  module LinkCards
    module_function

    # Match normal conversation pickup: combine adjacent messages by the same speaker.
    def quote_groups(raw, quotes)
      groups = []
      previous_end = 0
      quotes.each do |block, card|
        position = raw.index(block, previous_end)
        previous = groups.last && groups.last.last.last
        nonce = card['thread_connection_nonce'].to_s
        if previous && nonce.match?(/\A[a-f0-9]{32}\z/) &&
           nonce == previous['thread_connection_nonce'] && card['channel'] == previous['channel'] &&
           card['author'] == previous['author'] && card['avatar'] == previous['avatar'] &&
           raw[previous_end...position].strip.empty?
          groups.last << [block, card]
        else
          groups << [[block, card]]
        end
        previous_end = position + block.length
      end
      groups
    end

    def combine_conversation(cards)
      combined = cards.first.merge('text' => cards.map { |card| LinkQuotes.resolved_text(card) }.join("\n"),
                                   'names' => {},
                                   'source_urls' => cards.flat_map { |card| Array(card['source_urls'] || card['url']) })
      %w[thread_image_ids thread_file_ids].each do |key|
        ids = cards.flat_map { |card| Array(card[key]) }.uniq
        combined[key] = ids unless ids.empty?
      end
      combined
    end

    # Only the importer records this association; never infer it from note text.
    # Move already formatted images, preserving Redmine's sizing and links.
    def place_reply_images(html, quotes, attachments: [])
      marked = quotes.select { |quote| quote['thread_image_ids'] }
      return html if marked.empty?
      fragment = Nokogiri::HTML.fragment(html.to_s)
      marked.each do |quote|
        ids = quote['thread_image_ids']
        next unless (ids - attachments.map(&:id)).empty?
        cards = fragment.css('.slackmine-link-card').select do |card|
          footer = card.element_children.last
          footer && footer.name == 'a' && LinkQuotes.identity(footer['href']) == LinkQuotes.identity(quote['url'])
        end
        next unless cards.size == 1
        card = cards.first
        images = ids.map do |id|
          image_url = Formatter.url("/attachments/download/#{id}")
          fragment.css('img[src]').find do |img|
            src = URI.join(image_url, img['src']).to_s
            (src == image_url || src.start_with?(image_url + '/')) && !img.ancestors.include?(card)
          rescue URI::InvalidURIError
            false
          end
        end
        next if images.any?(&:nil?)
        gallery = Nokogiri::XML::Node.new('span', fragment.document)
        gallery['class'] = 'slackmine-link-card-images'
        card.element_children.last.add_previous_sibling(gallery)
        images.each do |img|
          node = img.parent.name == 'a' && img.parent.element_children.size == 1 && img.parent.text.strip.empty? ? img.parent : img
          paragraph = node.parent
          gallery.add_child(node)
          paragraph.remove if paragraph.name == 'p' && paragraph.text.strip.empty? && paragraph.element_children.all? { |child| child.name == 'br' }
        end
      end
      fragment.to_html
    end

    # Only explicit reply-import metadata may associate downloads with a card.
    def place_reply_files(html, quotes, attachments: [])
      marked = quotes.select { |quote| quote['thread_file_ids'] }
      return html if marked.empty?
      fragment = Nokogiri::HTML.fragment(html.to_s)
      marked.each do |quote|
        files = quote['thread_file_ids'].map { |id| attachments.find { |a| a.id == id } }
        next if files.any?(&:nil?)
        cards = fragment.css('.slackmine-link-card').select do |card|
          footer = card.element_children.last
          footer && footer.name == 'a' && LinkQuotes.identity(footer['href']) == LinkQuotes.identity(quote['url'])
        end
        next unless cards.size == 1
        card = cards.first
        next if card.at_css('.slackmine-link-card-files')
        downloads = Nokogiri::XML::Node.new('span', fragment.document)
        downloads['class'] = 'slackmine-link-card-files'
        files.each do |file|
          url = Formatter.url("/attachments/#{file.id}")
          source_urls = [url, Formatter.url("/attachments/download/#{file.id}")]
          # Recognize both Redmine attachment references and earlier imported URLs.
          fragment.css('a[href]').select do |anchor|
            !anchor.ancestors.include?(card) && source_urls.include?(URI.join(url, anchor['href']).to_s)
          rescue URI::InvalidURIError
            false
          end.each do |anchor|
            paragraph = anchor.parent
            anchor.remove
            paragraph.remove if paragraph.name == 'p' && paragraph.text.strip.empty? && paragraph.element_children.all? { |child| child.name == 'br' }
          end
          link = Nokogiri::XML::Node.new('a', fragment.document)
          link['href'] = url
          link.content = file.filename
          downloads.add_child(link)
        end
        card.element_children.last.add_previous_sibling(downloads)
      end
      fragment.to_html
    end

    def place_saved_cards(fragment, replacements, quote_urls, project: Thread.current[:slackmine_project])
      quote_urls.each do |token, url|
        anchors = fragment.css('a[href]').select do |anchor|
          next false if anchor.ancestors.any? { |node| %w[pre code].include?(node.name) || node['class'].to_s.split.include?('slackmine-link-card') }
          Array(url).any? { |source| LinkQuotes.identity(anchor['href']) == LinkQuotes.identity(source) }
        end
        next if anchors.empty?
        replace_link_with_card(anchors.first, replacements[token])
        replacements[token] = ''
        # Keep additional references compact without repeating the saved body.
        anchors.drop(1).each do |anchor|
          if url.is_a?(Array)
            replace_link_with_card(anchor, '')
          else
            anchor.content = link_message('compact_open', project: project) if anchor.text == anchor['href']
          end
        end
      end
    end

    def replace_link_with_card(anchor, html)
      # Cards are block elements; the URL's adjacent line breaks add extra blank lines.
      %i[previous_sibling next_sibling].each do |direction|
        sibling = anchor.public_send(direction)
        sibling = sibling.public_send(direction) while sibling && sibling.text? && sibling.text.strip.empty?
        sibling.remove if sibling && sibling.name == 'br'
      end
      anchor.replace(Nokogiri::HTML.fragment(html))
    end

    def header(card, time_formatter = nil, mail: false)
      timestamp = time_formatter && card['timestamp'] ? time_formatter.call(card['timestamp']) : card['timestamp']
      attributes = mail ? ' class="slackmine-mail-avatar"' : ' loading="lazy" style="width: 28px; height: 28px; border-radius: 6px; vertical-align: middle; margin-right: 6px"'
      safe_avatar = LinkQuotes.safe_avatar(card['avatar'])
      avatar = safe_avatar ? %(<img src="#{SlackMarkup.escape(safe_avatar)}" alt="" width="28" height="28"#{attributes}>) : ''
      metadata = %(<strong>#{SlackMarkup.escape(card['author'])}</strong><span> · ##{SlackMarkup.escape(card['channel'])} · #{SlackMarkup.escape(timestamp)}</span>)
      content = if mail && !avatar.empty?
                  %(<span class="slackmine-mail-header-layout" style="display: inline-table; vertical-align: middle; border-collapse: collapse"><span style="display: table-cell; vertical-align: middle; padding-right: 6px; line-height: 0">#{avatar}</span><span style="display: table-cell; vertical-align: middle; line-height: 20px">#{metadata}</span></span>)
                else
                  avatar + metadata
                end
      %(<span class="slackmine-link-card-header" style="display: block; font-size: .9em">#{content}</span>)
    end

    def link_message(key, project: Thread.current[:slackmine_project], **values)
      Formatter.interpolate(Formatter.message('link_cards', key, project: project), values,
                            fallback: Formatter::DEFAULT_MESSAGES.dig('link_cards', key))
    end

    def render_card(card, url, project, time_formatter: nil, icon_html: nil)
      text = SlackMarkup.render(card['text'], card['names'] || {})
      if card['verified'] == false
        label = SlackMarkup.escape(link_message('unverified_quote', project: project))
        return %(<span class="slackmine-link-card slackmine-unverified-quote" style="display: block; white-space: pre-wrap"><strong>#{label}</strong>\n#{text}</span>)
      end
      wording = Slackmine.messages_config
      project_wording = wording.dig('projects', project.identifier.to_s, 'messages', 'link_cards', 'open') if project
      global_wording = wording.dig('messages', 'link_cards', 'open')
      separate_wording = [project_wording, global_wording].any? { |value| value.is_a?(String) && !value.strip.empty? }
      legacy_link_text = Slackmine.effective_config(project).dig('slack', 'link_cards', 'link_text')
      link_text = separate_wording ? nil : legacy_link_text
      link_text = link_message('open', project: project) unless link_text.is_a?(String) && !link_text.strip.empty?
      link_text = SlackMarkup.escape(link_text)
      label = if icon_html
                %(<span class="slackmine-mail-link-layout" style="display: inline-table; vertical-align: middle; border-collapse: collapse"><span style="display: table-cell; vertical-align: middle; padding-right: 6px; line-height: 0">#{icon_html}</span><span style="display: table-cell; vertical-align: middle; line-height: 20px; white-space: nowrap">#{link_text}</span></span>)
              else
                link_text
              end
      context = +''
      if card['thread_reply']
        context << %(<span class="slackmine-thread-label" style="display: block; font-size: .85em; margin-bottom: 8px">#{SlackMarkup.escape(link_message('thread_reply', project: project))}</span>)
        if (parent = card['parent'])
          parent = parent.merge('channel' => card['channel'])
          context << %(<span class="slackmine-thread-parent" style="display: block; padding: 10px 12px; margin-bottom: 12px; border-left: 2px solid #aaa; font-size: .9em">#{header(parent, time_formatter, mail: !icon_html.nil?)}<span class="slackmine-link-card-text" style="display: block; white-space: pre-wrap; overflow-wrap: anywhere; margin: 10px 0">#{SlackMarkup.render(parent['text'].to_s[0, 500], parent['names'] || {})}</span>#{SlackMarkup.link(card['parent_url'], link_message('parent_open', project: project))}</span>)
        else
          context << SlackMarkup.link(card['parent_url'], link_message('parent_open', project: project))
        end
      elsif card['reply_count'].to_i > 0
        context << %(<span class="slackmine-thread-label" style="display: block; font-size: .85em; margin-bottom: 8px">#{SlackMarkup.escape(link_message('reply_count', project: project, count: card['reply_count'].to_i))}</span>)
      end
      %(<span class="slackmine-link-card" style="--slack-card-color: #{color(project)}; display: block; box-sizing: border-box; margin: .7em 0; padding: 14px 16px; max-width: 680px; border: 1px solid #d9d9e3; border-left: 4px solid #{color(project)}; border-radius: 8px; background: transparent; color: inherit">#{context}#{header(card, time_formatter, mail: !icon_html.nil?)}<span class="slackmine-link-card-text" style="display: block; white-space: pre-wrap; overflow-wrap: anywhere; margin: 10px 0">#{text}</span>#{SlackMarkup.link(url, label).sub('<a ', '<a style="display: inline-block; margin-top: 6px; font-weight: 700" ')}</span>)
    end

    def render_links(html, issue, viewer, journal_id, state, time_formatter: nil, quoted_urls: [], preview_source: nil, project: nil)
      project ||= issue.project if issue
      return html unless redmine_enabled?(project)
      if preview_source
        permitted = viewer && viewer.logged? && project &&
                    (issue ? LinkQuotes.editable_source?(issue, viewer) : viewer.allowed_to?(:add_issues, project))
        return html unless permitted
      end

      fragment = Nokogiri::HTML.fragment(html.to_s)
      changed = false
      fragment.css('a[href]').each do |anchor|
        next if anchor.ancestors.any? { |node| %w[pre code a].include?(node.name) || node['class'].to_s.split.include?('slackmine-link-card') }
        url = anchor['href']
        next unless parse(url)
        next if quoted_urls.any? { |quoted| LinkQuotes.identity(quoted) == LinkQuotes.identity(url) }
        key = [issue && issue.id, journal_id, url]
        unless state[:cards].key?(key)
          break if state[:count] >= 20 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > state[:deadline]
          state[:count] += 1
          state[:cards][key] = if preview_source
                                 fetch_for_project(project, url, viewer: viewer, api_cache: state[:api], deadline: state[:deadline]) if referenced?(preview_source, parse(url))
                               else
                                 fetch(issue, viewer, url, journal_id: journal_id, api_cache: state[:api], deadline: state[:deadline])
                               end
        end
        card = state[:cards][key]
        next unless card
        replace_link_with_card(anchor, render_card(card, url, project, time_formatter: time_formatter))
        changed = true
      end
      changed ? fragment.to_html : html
    end
  end
end
