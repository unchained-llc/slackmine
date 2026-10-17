# frozen_string_literal: true
require_relative 'link_cards_test'

class String
  def html_safe; self; end unless method_defined?(:html_safe)
end

class LinkCardsHelperTest < Minitest::Test
  class BaseView
    attr_accessor :controller_name, :action_name, :request, :html, :render_source, :source_formatter
    def textilizable(*args)
      return source_formatter.call(args.first) if source_formatter && args.first.is_a?(String)
      return "<p>#{CGI.escapeHTML(args.first)}</p>" if render_source && args.first.is_a?(String)
      html
    end
  end
  class View < BaseView
    prepend Slackmine::LinkCardsHelper
  end

  def setup
    @view = View.new
    @view.controller_name = 'issues'
    @view.action_name = 'show'
    @view.request = OpenStruct.new(format: OpenStruct.new(html?: true))
    @view.html = '<p>formatted source</p>'.dup
    @view.html.define_singleton_method(:html_safe) { self }
    @issue = Issue.new(123)
    @issue.project = OpenStruct.new(identifier: 'example')
    @issue.define_singleton_method(:attachments) { [] }
  end

  def test_history_import_renders_distinct_speakers_in_web_and_mail_without_fetching
    @view.render_source = true
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    cards = [['Alice', 'First message'], ['Bob', '<script>Reply</script>']].each_with_index.map do |(author, body), index|
      card = { 'author' => author, 'channel' => 'discussion', 'timestamp' => '2026-10-07T01:00:00Z', 'text' => body,
               'thread_connection_nonce' => 'a' * 32 }
      Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL.sub('755579', "75557#{index}"))
    end
    source = "Slackスレッドから取り込み（接続前の会話）\n\n" + cards.join("\n\n")
    @issue.define_singleton_method(:description) { @description }
    @issue.instance_variable_set(:@description, source)
    %w[issues mailer].each do |surface|
      @view.controller_name = surface
      Slackmine.stub(:slack_api, ->(*) { flunk 'Saved history must render offline' }) do
        Slackmine::LinkCards.stub(:source, source) do
          doc = Nokogiri::HTML.fragment(@view.textilizable(@issue, :description))
          assert_equal 2, doc.css('.slackmine-link-card').size
          assert_includes doc.css('.slackmine-link-card-header').first.text, 'Alice'
          assert_includes doc.css('.slackmine-link-card-header').last.text, 'Bob'
          assert_equal ['First message', '<script>Reply</script>'], doc.css('.slackmine-link-card-text').map(&:text)
          assert_empty doc.css('script')
          refute_includes doc.to_html, '[slack-quote:'
        end
      end
    end
  end

  def test_conversation_grouping_preserves_import_boundaries_and_intervening_text
    card = { 'author' => 'Example', 'channel' => 'discussion', 'text' => 'Saved message', 'timestamp' => '2026-10-07T01:00:00Z',
             'thread_connection_nonce' => 'a' * 32 }
    first = Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL)
    second = Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL.sub('755579', '755580'))
    third = Slackmine::LinkQuotes.encode(card.merge('thread_connection_nonce' => 'b' * 32), LinkCardsTest::URL)
    other_speaker = Slackmine::LinkQuotes.encode(card.merge('author' => 'Other'), LinkCardsTest::URL)
    [ ["#{first}\n\n#{second}", [2]],
      ["#{first}\nIntervening note\n#{second}", [1, 1]],
      ["#{first}\n\n#{third}", [1, 1]],
      ["#{first}\n\n#{other_speaker}\n\n#{second}", [1, 1, 1]],
      ["#{first}\n\n#{Slackmine::LinkQuotes.encode(card.reject { |key, _| key == 'thread_connection_nonce' }, LinkCardsTest::URL)}", [1, 1]]
    ].each do |raw, sizes|
      assert_equal sizes, Slackmine::LinkCards.quote_groups(raw, Slackmine::LinkQuotes.blocks(raw)).map(&:size)
    end
  end

  def test_history_import_matches_normal_pickup_for_consecutive_messages_in_web_and_mail
    @view.render_source = true
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    bodies = ['First post', 'Second post', 'Third post']
    source = bodies.each_with_index.map do |body, index|
      card = { 'author' => 'Alice', 'channel' => 'discussion', 'text' => body,
               'timestamp' => "2026-10-07T12:0#{index}:00Z", 'thread_connection_nonce' => 'a' * 32 }
      Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL.sub('755579', "75557#{index}"))
    end.join("\n\n")
    @issue.define_singleton_method(:description) { source }
    %w[issues mailer].each do |surface|
      @view.controller_name = surface
      Slackmine.stub(:slack_api, ->(*) { flunk 'Saved history must render offline' }) do
        Slackmine::LinkCards.stub(:source, source) do
          doc = Nokogiri::HTML.fragment(@view.textilizable(@issue, :description))
          assert_equal 1, doc.css('.slackmine-link-card').size
          assert_equal 1, doc.css('.slackmine-link-card-header').size
          assert_equal bodies.join("\n"), doc.at_css('.slackmine-link-card-text').text
          assert_includes doc.at_css('.slackmine-link-card-header').text, '#discussion'
          assert_equal 1, doc.css('.slackmine-link-card > a').size
          assert_equal 'Open in Slack', doc.at_css('.slackmine-link-card > a').text
          assert_empty doc.css('.slackmine-thread-conversation')
        end
      end
    end
  end

  def test_grouped_conversation_keeps_attachments_with_their_message
    first = { 'author' => 'Alice', 'channel' => 'discussion', 'text' => 'Image', 'url' => LinkCardsTest::URL,
              'thread_image_ids' => [41] }
    second = first.merge('author' => 'Alice', 'text' => 'File', 'url' => LinkCardsTest::URL.sub('755579', '755580'),
                         'thread_image_ids' => nil, 'thread_file_ids' => [42])
    second.delete('thread_image_ids')
    attachments = [OpenStruct.new(id: 41), OpenStruct.new(id: 42, filename: 'report.pdf')]
    image = '/attachments/download/41/screen.png'
    combined = Slackmine::LinkCards.combine_conversation([first, second])
    html = Slackmine::LinkCards.render_card(combined, combined['url'], @issue.project) +
           %(<p><img src="#{image}" width="344"></p>)
    html = Slackmine::LinkCards.place_reply_images(html, [combined], attachments: attachments)
    html = Slackmine::LinkCards.place_reply_files(html, [combined], attachments: attachments)
    doc = Nokogiri::HTML.fragment(html)
    entry = doc.at_css('.slackmine-link-card')
    assert_equal 1, doc.css('.slackmine-link-card').size
    assert_equal image, entry.at_css('.slackmine-link-card-images img')['src']
    assert_equal 'report.pdf', entry.at_css('.slackmine-link-card-files a').text
    assert_equal first['url'], entry.element_children.last['href']
    assert_equal "Image\nFile", entry.at_css('.slackmine-link-card-text').text
  end

  def test_hook_renders_after_normal_formatting_and_keeps_source_permission_check
    rendered = false
    User.stub(:current, Object.new) do
      Slackmine::LinkCards.stub(:source, 'source') do
        Slackmine::LinkCards.stub(:render_links, lambda { |html, issue, _viewer, journal, state, **options|
          assert_equal @view.html, html
          assert_equal @issue, issue
          assert_nil journal
          assert_equal 0, state[:count]
          rendered = true
          html
        }) { @view.textilizable(@issue, :description) }
      end
      assert rendered
      Slackmine::LinkCards.stub(:source, nil) do
        Slackmine::LinkCards.stub(:render_links, ->(*) { flunk 'denied source' }) do
          assert_equal @view.html, @view.textilizable(@issue, :description)
        end
      end
    end
  end

  def test_editor_previews_mark_edited_saved_quotes_unverified_without_fetching_slack
    @view.controller_name = 'previews'
    @view.render_source = true
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    @view.instance_variable_set(:@project, @issue.project)
    card = { 'author' => 'Alice', 'channel' => 'discussion', 'timestamp' => '2026-10-07T01:00:00Z',
             'text' => 'Original message' }
    raw = LinkCardsTest::URL + "\n\n" + Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL)
    raw = raw.sub('Original message', 'Edited message <script>alert(1)</script>')
    %w[issue text].each do |action|
      @view.action_name = action
      [nil, @issue].each do |object|
        Slackmine::LinkCards.stub(:source, ->(*) { flunk 'Preview must use submitted text' }) do
          Slackmine::LinkCards.stub(:fetch_for_project, ->(*) { flunk 'Saved quotes must not fetch live links' }) do
            doc = Nokogiri::HTML.fragment(@view.textilizable(raw, object: object))
            assert_equal 1, doc.css('.slackmine-link-card').size
            assert_includes doc.at_css('.slackmine-unverified-quote').text, 'Unverified quote'
            assert_includes doc.at_css('.slackmine-unverified-quote').text, 'Edited message'
            refute_includes doc.text, 'Alice'
            assert_empty doc.css('script')
            refute_includes doc.to_html, '[slack-quote:'
            Slackmine.stub(:config, { 'slack' => { 'link_cards' => { 'redmine_enabled' => false } } }) do
              html = @view.textilizable(raw, object: object)
              assert_includes html, 'Edited message'
              refute_includes html, 'class="slackmine-link-card"'
              refute_includes html, '[slack-quote:'
            end
          end
        end
      end
    end
  end

  def test_editor_preview_fetches_submitted_url_with_permission_and_preserves_failed_links
    @view.controller_name = 'previews'
    @view.action_name = 'issue'
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    @view.instance_variable_set(:@project, @issue.project)
    @view.source_formatter = ->(raw) { %(<p><a href="#{CGI.escapeHTML(raw)}">Slack</a></p>) }
    @issue.define_singleton_method(:new_record?) { false }
    @issue.define_singleton_method(:visible?) { |_| true }
    viewer = OpenStruct.new(logged?: true)
    viewer.define_singleton_method(:allowed_to?) { |*| true }
    card = { 'author' => 'Alice', 'text' => 'URL preview', 'channel' => 'discussion', 'timestamp' => '2026-10-07T01:00:00Z' }
    calls = []
    User.stub(:current, viewer) do
      Slackmine::LinkCards.stub(:source, ->(*) { flunk 'Preview must use submitted source' }) do
        Slackmine::LinkCards.stub(:fetch_for_project, ->(project, url, **_) { calls << [project, url]; card }) do
          [@issue, nil].each do |object|
            @view.instance_variable_set(:@slack_link_card_state, nil)
            html = @view.textilizable(LinkCardsTest::URL, object: object)
            assert_includes html, 'URL preview'
            assert_equal 1, Nokogiri::HTML.fragment(html).css('.slackmine-link-card').size
          end
          assert_equal [[@issue.project, LinkCardsTest::URL]] * 2, calls
          @view.instance_variable_set(:@slack_link_card_state, nil)
          @issue.define_singleton_method(:visible?) { |_| false }
          refute_includes @view.textilizable(LinkCardsTest::URL, object: @issue), 'slackmine-link-card'
          viewer.define_singleton_method(:allowed_to?) { |*| false }
          refute_includes @view.textilizable(LinkCardsTest::URL), 'slackmine-link-card'
          viewer.define_singleton_method(:logged?) { false }
          refute_includes @view.textilizable(LinkCardsTest::URL), 'slackmine-link-card'
          assert_equal 2, calls.size
        end
        viewer.define_singleton_method(:logged?) { true }
        @issue.define_singleton_method(:visible?) { |_| true }
        Slackmine::LinkCards.stub(:fetch_for_project, nil) do
          html = @view.textilizable(LinkCardsTest::URL, object: @issue)
          assert_includes html, LinkCardsTest::URL
          refute_includes html, 'slackmine-link-card'
        end
      end
    end
  end

  def test_other_contexts_do_not_fetch_slack
    Slackmine::LinkCards.stub(:source, ->(*) { flunk 'unexpected network context' }) do
      @view.controller_name = 'mailer'
      assert_equal @view.html, @view.textilizable(@issue, :description)
      @view.controller_name = 'issues'
      @view.request.format.define_singleton_method(:html?) { false }
      assert_equal @view.html, @view.textilizable(@issue, :description)
      @view.request.format.define_singleton_method(:html?) { true }
      assert_equal @view.html, @view.textilizable(@issue, :description, formatting: false)
      assert_equal @view.html, @view.textilizable('preview text')
    end
  end

  def test_disabled_web_cards_show_saved_quotes_as_text_and_do_not_fetch_live_links
    @view.render_source = true
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => 'Saved message' }
    raw = LinkCardsTest::URL + Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL)
    %w[enabled redmine_enabled].each do |switch|
      Slackmine.stub(:config, { 'slack' => { 'link_cards' => { switch => false } } }) do
        Slackmine::LinkCards.stub(:source, raw) do
          Slackmine::LinkCards.stub(:render_links, ->(*) { flunk 'Disabled web cards fetched live links' }) do
            html = @view.textilizable(@issue, :description)
            assert_includes html, 'Saved message'
            assert_includes html, LinkCardsTest::URL
            refute_includes html, 'class="slackmine-link-card"'
            refute_includes html, '[slack-quote:'
          end
        end
      end
    end
  end

  def test_web_switch_does_not_disable_mail_but_master_switch_does
    @view.controller_name = 'mailer'
    @view.render_source = true
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => 'Saved message' }
    @issue.define_singleton_method(:description) { @description }
    @issue.instance_variable_set(:@description, Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL))
    Slackmine.stub(:config, { 'slack' => { 'link_cards' => { 'redmine_enabled' => false } } }) do
      assert_includes @view.textilizable(@issue, :description), 'class="slackmine-link-card"'
    end
    Slackmine.stub(:config, { 'slack' => { 'link_cards' => { 'enabled' => false, 'mail_enabled' => true } } }) do
      html = @view.textilizable(@issue, :description)
      assert_includes html, 'Saved message'
      refute_includes html, 'class="slackmine-link-card"'
      refute_includes html, '[slack-quote:'
    end
  end
  def test_mailer_view_without_controller_name_renders_normal_and_saved_notes
    mailer_view = Class.new(BaseView) do
      undef_method :controller_name
      prepend Slackmine::LinkCardsHelper
      def format_time(value); value.iso8601; end
    end.new
    mailer_view.html = '<p>Normal description</p>'
    @issue.define_singleton_method(:description) { @description }
    @issue.instance_variable_set(:@description, 'Normal description')
    Slackmine::LinkCards.stub(:source, ->(*) { flunk 'mail must not fetch Slack' }) do
      assert_equal mailer_view.html, mailer_view.textilizable(@issue, :description)
      card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => 'Saved message' }
      @issue.instance_variable_set(:@description, Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL))
      mailer_view.render_source = true
      rendered = mailer_view.textilizable(@issue, :description)
      assert_includes rendered, 'Saved message'
      refute_includes rendered, '[slack-quote:'
    end
  end

  def test_mail_saved_quote_preserves_markup_without_web_stylesheet_or_slack_fetch
    @view.controller_name = 'mailer'
    @view.render_source = true
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    source = "1. *First*\n    ◦ Child\n\n4. *Next*\n    - Detail <img src=x>"
    card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => source,
             'thread_reply' => true, 'parent_url' => LinkCardsTest::URL,
             'parent' => { 'author' => 'Parent', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => "*Topic*\n  ◦ Context" } }
    @issue.define_singleton_method(:description) { @description }
    @issue.instance_variable_set(:@description, Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL))
    Slackmine::LinkCards.stub(:source, ->(*) { flunk 'mail must not fetch Slack' }) do
      doc = Nokogiri::HTML.fragment(@view.textilizable(@issue, :description, only_path: false))
      assert_includes doc.at_css('.slackmine-link-card')['style'], 'border-left: 4px solid'
      assert_includes doc.at_css('.slackmine-link-card-header')['style'], 'display: block'
      texts = doc.css('.slackmine-link-card-text')
      assert_equal 2, texts.size
      assert_equal "Topic\n  ◦ Context", texts.first.text
      assert_equal source.gsub('*First*', 'First').gsub('*Next*', 'Next'), texts.last.text
      texts.each do |node|
        assert_includes node['style'], 'white-space: pre-wrap'
        assert_includes node['style'], 'display: block'
      end
      assert_equal ['First', 'Next'], texts.last.css('strong').map(&:text)
      assert_empty texts.last.css('img, script, ol, ul, li')
    end
  end

  def test_mail_saved_card_has_inline_styles_and_replaces_original_url
    @view.controller_name = 'mailer'
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z',
             'avatar' => 'https://avatars.slack-edge.com/avatar.png', 'text' => '*Test*' }
    @issue.define_singleton_method(:description) { @description }
    url = LinkCardsTest::URL
    @issue.instance_variable_set(:@description, url + "\n\n" + Slackmine::LinkQuotes.encode(card, url))
    @view.source_formatter = ->(source) { "<p>#{CGI.escapeHTML(source).sub(url, '<a href="' + url + '">' + url + '</a>')}</p>" }
    Slackmine::LinkCards.stub(:source, ->(*) { flunk 'mail must not fetch Slack' }) do
      doc = Nokogiri::HTML.fragment(@view.textilizable(@issue, :description, only_path: false))
      assert_equal 1, doc.css('.slackmine-link-card').size
      assert_equal ['Open in Slack'], doc.css('a').map(&:text)
      avatar = doc.at_css('.slackmine-link-card-header img')
      assert_equal({ 'src' => card['avatar'], 'alt' => '', 'width' => '28', 'height' => '28', 'class' => 'slackmine-mail-avatar' }, avatar.attributes.transform_values(&:value))
      assert_includes avatar.parent['style'], 'display: table-cell; vertical-align: middle; padding-right: 6px'
      metadata_cell = doc.at_css('.slackmine-mail-header-layout').element_children.last
      assert_includes metadata_cell['style'], 'display: table-cell; vertical-align: middle; line-height: 20px'
      assert_equal card['author'], metadata_cell.at_css('strong').text
      assert_includes doc.at_css('.slackmine-link-card')['style'], 'border-left: 4px solid'
      assert_includes doc.at_css('.slackmine-link-card > a')['style'], 'font-weight: 700'
      assert_equal 'Test', doc.at_css('.slackmine-link-card-text strong').text
      icon = doc.at_css('.slackmine-link-card > a img')
      assert_equal '16', icon['width']
      assert_equal 'slackmine-bundled-logo.png', icon['src']
    end
  end

  def test_link_text_is_shared_by_web_and_mail_and_escaped
    card = { 'author' => 'Example', 'channel' => 'example', 'text' => 'Message' }
    [nil, '<img class="slackmine-mail-icon" src="slackmine-bundled-logo.png">'].each do |icon|
      ['Slackで開く', '<script> & "quoted"', nil, '', '  ', false].each do |value|
        Slackmine.stub(:effective_config, { 'slack' => { 'link_cards' => { 'link_text' => value } } }) do
          html = Slackmine::LinkCards.render_card(card, LinkCardsTest::URL, @issue.project, icon_html: icon)
          doc = Nokogiri::HTML.fragment(html)
          expected = value.is_a?(String) && !value.strip.empty? ? value : 'Open in Slack'
          assert_equal expected, doc.at_css('.slackmine-link-card > a').text
          assert_empty doc.css('script')
          assert_equal icon ? 1 : 0, doc.css('.slackmine-mail-icon').size
        end
      end
    end
  end

  def test_separate_message_file_overrides_legacy_link_text
    card = { 'author' => 'Example', 'channel' => 'example', 'text' => 'Message' }
    legacy = { 'slack' => { 'link_cards' => { 'link_text' => 'Old wording' } } }
    separate = { 'messages' => { 'link_cards' => { 'open' => 'New wording' } } }
    Slackmine.stub(:effective_config, legacy) do
      Slackmine.stub(:messages_config, separate) do
        html = Slackmine::LinkCards.render_card(card, LinkCardsTest::URL, @issue.project)
        assert_equal 'New wording', Nokogiri::HTML.fragment(html).at_css('.slackmine-link-card > a').text
      end
    end
  end

  def test_project_wording_is_shared_by_web_mail_and_plain_quotes_and_escaped
    card = { 'author' => 'Alice', 'channel' => 'example', 'timestamp' => '2026-10-07T01:00:00Z',
             'text' => 'Reply', 'thread_reply' => true, 'parent_url' => LinkCardsTest::URL,
             'parent' => { 'author' => 'Bob', 'text' => 'Parent', 'timestamp' => '2026-10-07T00:00:00Z' } }
    settings = { 'messages' => { 'link_cards' => { 'open' => 'Global link' } },
                 'projects' => { 'example' => { 'messages' => { 'link_cards' => {
                   'open' => '<script>Open & read</script>', 'thread_reply' => '<b>Reply</b>',
                   'parent_open' => 'Read parent', 'reply_count' => '%{count} replies here',
                   'plain_parent' => "Parent by %{author}: %{text}\n",
                   'plain_quote' => "%{author} in %{channel}\n%{prefix}%{text}" } } } } }
    Slackmine.stub(:config, settings) do
      [nil, '<img class="slackmine-mail-icon" src="slackmine-bundled-logo.png">'].each do |icon|
        doc = Nokogiri::HTML.fragment(Slackmine::LinkCards.render_card(card, LinkCardsTest::URL, @issue.project, icon_html: icon))
        assert_equal '<script>Open & read</script>', doc.at_css('.slackmine-link-card > a').text
        assert_equal '<b>Reply</b>', doc.at_css('.slackmine-thread-label').text
        assert_equal 'Read parent', doc.at_css('.slackmine-thread-parent a').text
        assert_empty doc.css('script, b')
      end
      root = card.merge('thread_reply' => false, 'reply_count' => 3)
      doc = Nokogiri::HTML.fragment(Slackmine::LinkCards.render_card(root, LinkCardsTest::URL, @issue.project))
      assert_equal '3 replies here', doc.at_css('.slackmine-thread-label').text
      encoded = Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL)
      assert_equal "Alice in example\nParent by Bob: Parent\nReply", Slackmine::LinkQuotes.plain_source(encoded, project: @issue.project)
    end
  end

  def test_mail_cards_can_be_disabled_without_hiding_quote_text_or_web_cards
    card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => '*Saved message*' }
    url = LinkCardsTest::URL
    source = url + "\n\n" + Slackmine::LinkQuotes.encode(card, url)
    @issue.define_singleton_method(:description) { @description }
    @issue.instance_variable_set(:@description, source)
    @view.render_source = true
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    Slackmine.stub(:effective_config, { 'slack' => { 'link_cards' => { 'mail_enabled' => false } } }) do
      @view.controller_name = 'mailer'
      Slackmine::LinkCards.stub(:source, ->(*) { flunk 'mail must not fetch Slack' }) do
        doc = Nokogiri::HTML.fragment(@view.textilizable(@issue, :description))
        assert_empty doc.css('.slackmine-link-card, img')
        assert_includes doc.text, url
        assert_includes doc.text, '*Saved message*'
        refute_includes doc.text, '[slack-quote:'
      end
      @view.controller_name = 'issues'
      User.stub(:current, Object.new) do
        Slackmine::LinkCards.stub(:source, source) do
          Slackmine::LinkCards.stub(:render_links, ->(html, *) { html }) do
            doc = Nokogiri::HTML.fragment(@view.textilizable(@issue, :description))
            assert_equal 1, doc.css('.slackmine-link-card').size
          end
        end
      end
    end
  end

  def test_saved_quote_renders_without_network_and_preserves_private_note_gate
    card = { 'author' => 'Example', 'channel' => 'test', 'timestamp' => '2026-10-05T00:00:00Z',
             'text' => 'Searchable <script>alert(1)</script> {{include(private)}}', 'names' => {} }
    source = "#{LinkCardsTest::URL}\n\n#{Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL)}"
    @view.render_source = true
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    User.stub(:current, Object.new) do
      Slackmine::LinkCards.stub(:source, source) do
        Slackmine::LinkCards.stub(:fetch, ->(*) { flunk 'stored quotes must not fetch' }) do
          html = @view.textilizable(@issue, :description)
          doc = Nokogiri::HTML.fragment(html)
          assert_equal 1, doc.css('.slackmine-link-card').size
          assert_empty doc.css('script')
          assert_includes doc.text, '{{include(private)}}'
          refute_includes html, '[slack-quote:'
        end
      end
      Slackmine::LinkCards.stub(:source, nil) do
        assert_equal @view.html, @view.textilizable(@issue, :description)
      end
    end
  end

  def test_ajax_update_matches_page_reload_with_cards_at_url_positions
    url = LinkCardsTest::URL
    card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => 'Saved message' }
    source = "#{url}\nって返した\n\n#{Slackmine::LinkQuotes.encode(card, url)}"
    journal = Journal.new
    journal.define_singleton_method(:journalized) { @issue }
    journal.instance_variable_set(:@issue, @issue)
    journal.define_singleton_method(:id) { 456 }
    @view.source_formatter = ->(text) { '<p>' + CGI.escapeHTML(text).sub(url, %(<a href="#{url}">#{url}</a>)) + '</p>' }
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    @view.request.format.define_singleton_method(:js?) { true }
    User.stub(:current, Object.new) do
      Slackmine::LinkCards.stub(:source, ->(_issue, _viewer, id) { assert_equal 456, id; source }) do
        Slackmine::LinkCards.stub(:fetch, ->(*) { flunk 'saved quotes must not fetch' }) do
          page = @view.textilizable(journal, :notes)
          @view.controller_name = 'journals'; @view.action_name = 'update'
          @view.request.format.define_singleton_method(:html?) { false }
          ajax = @view.textilizable(journal, :notes)
          assert_equal page, ajax
          doc = Nokogiri::HTML.fragment(ajax)
          assert_equal 1, doc.css('.slackmine-link-card').size
          assert_equal ['Open in Slack'], doc.css('a').map(&:text)
          assert_operator doc.text.index('Saved message'), :<, doc.text.index('って返した')
          refute_includes ajax, '[slack-quote:'
        end
      end
      Slackmine::LinkCards.stub(:source, nil) do
        assert_equal @view.html, @view.textilizable(journal, :notes)
      end
    end
  end

  def test_saved_cards_replace_their_urls_in_source_order
    urls = [LinkCardsTest::URL, LinkCardsTest::URL.sub('C123', 'C456')]
    cards = urls.each_with_index.map do |url, index|
      card = { 'author' => "Author #{index}", 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => "Message #{index}" }
      [url, card]
    end
    fragment = Nokogiri::HTML.fragment("<p>Before</p><p><a href=\"#{urls[1]}\">#{urls[1]}</a></p><p>Between</p><p><a href=\"#{urls[0]}\">#{urls[0]}</a></p><p>After</p><p>TOKEN0</p><p>TOKEN1</p>")
    replacements = {}; mapping = {}
    cards.each_with_index do |(url, card), index|
      replacements["TOKEN#{index}"] = Slackmine::LinkCards.render_card(card, url, @issue.project)
      mapping["TOKEN#{index}"] = url
    end
    Slackmine::LinkCards.place_saved_cards(fragment, replacements, mapping)
    assert_equal ['Message 1', 'Message 0'], fragment.css('.slackmine-link-card-text').map(&:text)
    assert_equal ['Before', 'Message 1', 'Between', 'Message 0', 'After'], fragment.css('p').first(5).map { |p| p.at_css('.slackmine-link-card-text')&.text || p.text }
    assert_equal ['', ''], replacements.values
    assert_equal ['Open in Slack', 'Open in Slack'], fragment.css('a').map(&:text)
    assert_equal [urls[1], urls[0]], fragment.css('.slackmine-link-card a').map { |a| a['href'] }
  end

  def test_card_replacement_removes_only_adjacent_breaks
    url = LinkCardsTest::URL
    fragment = Nokogiri::HTML.fragment("<p>Before<br>\n<a href=\"#{url}\">#{url}</a>\n<br>After<br>Normal line</p>")
    replacements = { 'TOKEN' => '<span class="slackmine-link-card">saved quote</span>' }
    Slackmine::LinkCards.place_saved_cards(fragment, replacements, { 'TOKEN' => url })
    assert_equal 1, fragment.css('br').size
    assert_equal 'After', fragment.at_css('br').previous_sibling.text.strip
    assert_includes fragment.text, 'Normal line'
    assert_equal 1, fragment.css('.slackmine-link-card').size
  end

  def test_orphaned_quote_stays_in_place_and_code_links_are_untouched
    url = LinkCardsTest::URL
    fragment = Nokogiri::HTML.fragment("<pre><a href=\"#{url}\">#{url}</a></pre><p>TOKEN</p>")
    replacements = { 'TOKEN' => '<span class="slackmine-link-card">saved quote</span>' }
    Slackmine::LinkCards.place_saved_cards(fragment, replacements, { 'TOKEN' => url })
    assert_equal '<span class="slackmine-link-card">saved quote</span>', replacements['TOKEN']
    assert_equal url, fragment.at_css('pre a').text
  end

  def test_mail_places_imported_reply_image_and_file_before_slack_link
    @view.controller_name = 'mailer'
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    image = OpenStruct.new(id: 41)
    file = OpenStruct.new(id: 42, filename: 'report.pdf')
    @issue.define_singleton_method(:attachments) { [image, file] }
    url = LinkCardsTest::URL
    card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z',
             'text' => 'Reply', 'thread_image_ids' => [41], 'thread_file_ids' => [42] }
    journal = Journal.new
    journal.define_singleton_method(:id) { 7 }
    issue = @issue
    journal.define_singleton_method(:journalized) { issue }
    source = Slackmine::LinkQuotes.encode(card, url)
    journal.define_singleton_method(:notes) { source }
    image_url = Slackmine::Formatter.url('/attachments/download/41/screen.png')
    file_url = Slackmine::Formatter.url('/attachments/42')
    @view.source_formatter = ->(source) do
      "<p>#{CGI.escapeHTML(source)}</p><p><img src=\"#{image_url}\" width=\"344\" height=\"805\"></p><p><a href=\"#{file_url}\">report.pdf</a></p>"
    end
    Slackmine::LinkCards.stub(:source, ->(*) { flunk 'mail must not fetch Slack' }) do
      doc = Nokogiri::HTML.fragment(@view.textilizable(journal, :notes, only_path: false))
      quote = doc.at_css('.slackmine-link-card')
      assert_equal %w[slackmine-link-card-header slackmine-link-card-text slackmine-link-card-images slackmine-link-card-files],
                   quote.element_children.first(4).map { |node| node['class'] }
      assert_equal 'Open in Slack', quote.element_children.last.text
      assert_equal image_url, quote.at_css('.slackmine-link-card-images img')['src']
      assert_equal '344', quote.at_css('.slackmine-link-card-images img')['width']
      assert_equal file_url, quote.at_css('.slackmine-link-card-files a')['href']
      assert_equal 1, doc.css('.slackmine-link-card-images img').size
      assert_equal 1, doc.css('.slackmine-link-card-files a').size
    end
  end

  def test_explicit_imported_images_move_inside_card_and_preserve_sizing
    url = LinkCardsTest::URL
    card = { 'author' => 'Example', 'channel' => 'example', 'text' => 'Reply', 'url' => url,
             'thread_image_ids' => [41, 42] }
    attachments = [41, 42].map { |id| OpenStruct.new(id: id) }
    image_urls = [41, 42].map { |id| "/attachments/download/#{id}/screen@2x.png" }
    html = '<p>' + Slackmine::LinkCards.render_card(card, url, @issue.project) + '</p>' +
           image_urls.map { |src| %(<p><a href="#{src}" class="image"><img src="#{src}" width="344" height="805" loading="lazy"></a></p>) }.join
    rendered = Slackmine::LinkCards.place_reply_images(html, [card], attachments: attachments)
    doc = Nokogiri::HTML.fragment(rendered)
    assert_equal image_urls, doc.css('.slackmine-link-card-images img').map { |img| img['src'] }
    assert_equal image_urls, doc.css('.slackmine-link-card-images a').map { |a| a['href'] }
    assert_equal ['344', '344'], doc.css('img').map { |img| img['width'] }
    assert_equal ['805', '805'], doc.css('img').map { |img| img['height'] }
    assert_equal 'Open in Slack', doc.at_css('.slackmine-link-card').element_children.last.text
    assert_equal 1, doc.css('p').size
    assert_equal rendered, Slackmine::LinkCards.place_reply_images(rendered, [card], attachments: attachments)
  end

  def test_explicit_file_downloads_appear_inside_only_their_card
    url = LinkCardsTest::URL
    card = { 'author' => 'Example', 'channel' => 'example', 'text' => 'Reply', 'url' => url,
             'thread_file_ids' => [41] }
    file = OpenStruct.new(id: 41, filename: 'F123-report.pdf')
    download = Slackmine::Formatter.url('/attachments/41')
    html = Slackmine::LinkCards.render_card(card, url, @issue.project) + %(<p><a href="#{download}">report.pdf</a></p><p>Other content</p>)
    rendered = Slackmine::LinkCards.place_reply_files(html, [card], attachments: [file])
    doc = Nokogiri::HTML.fragment(rendered)
    assert_equal 'F123-report.pdf', doc.at_css('.slackmine-link-card-files a').text
    assert_equal download, doc.at_css('.slackmine-link-card-files a')['href']
    legacy = html.sub(download, Slackmine::Formatter.url('/attachments/download/41'))
    legacy_doc = Nokogiri::HTML.fragment(Slackmine::LinkCards.place_reply_files(legacy, [card], attachments: [file]))
    assert_equal 1, legacy_doc.css('.slackmine-link-card-files a').size
    assert_empty legacy_doc.css('a[href*="/attachments/download/"]')
    assert_equal 1, doc.css("a[href='#{download}']").size
    assert_equal 'Other content', doc.at_css('p').text
    assert_equal 'Open in Slack', doc.at_css('.slackmine-link-card').element_children.last.text
    assert_equal rendered, Slackmine::LinkCards.place_reply_files(rendered, [card], attachments: [file])
    assert_equal html, Slackmine::LinkCards.place_reply_files(html, [], attachments: [file])
    doc = Nokogiri::HTML.fragment(Slackmine::LinkCards.place_reply_files(html, [card], attachments: []))
    assert_empty doc.css('.slackmine-link-card-files')
  end

  def test_unmarked_missing_and_external_images_stay_outside_card
    url = LinkCardsTest::URL
    card = { 'author' => 'Example', 'channel' => 'example', 'text' => 'Reply', 'url' => url }
    image_url = '/attachments/download/41/screen.png'
    html = Slackmine::LinkCards.render_card(card, url, @issue.project) + %(<p><img src="#{image_url}"></p>)
    attachments = [OpenStruct.new(id: 41)]
    assert_equal html, Slackmine::LinkCards.place_reply_images(html, [card], attachments: attachments)
    assert_equal html, Slackmine::LinkCards.place_reply_images(html, [], attachments: attachments)
    marked = card.merge('thread_image_ids' => [41])
    [[], [OpenStruct.new(id: 42)]].each do |unrelated|
      doc = Nokogiri::HTML.fragment(Slackmine::LinkCards.place_reply_images(html, [marked], attachments: unrelated))
      assert_empty doc.css('.slackmine-link-card-images')
    end
    external = html.sub(image_url, 'https://external.example' + image_url)
    doc = Nokogiri::HTML.fragment(Slackmine::LinkCards.place_reply_images(external, [marked], attachments: attachments))
    assert_empty doc.css('.slackmine-link-card-images')
  end

  def test_journal_rendering_groups_saved_image_without_fetching_slack
    url = LinkCardsTest::URL
    image_url = Slackmine::Formatter.url('/attachments/download/41')
    card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => 'Reply', 'thread_image_ids' => [41] }
    @issue.define_singleton_method(:attachments) { [OpenStruct.new(id: 41)] }
    quote = Slackmine::LinkQuotes.encode(card, url)
    source = "#{url}\n\n![](#{image_url})\n\n#{quote}"
    journal = Journal.new
    journal.define_singleton_method(:journalized) { @issue }
    journal.instance_variable_set(:@issue, @issue)
    journal.define_singleton_method(:id) { 456 }
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    @view.source_formatter = lambda do |text|
      text.split("\n\n").map do |part|
        content = part == url ? %(<a href="#{url}">#{url}</a>) :
                  (part == "![](#{image_url})" ? %(<img src="#{image_url}">) : CGI.escapeHTML(part))
        "<p>#{content}</p>"
      end.join
    end
    User.stub(:current, Object.new) do
      Slackmine::LinkCards.stub(:source, source) do
        Slackmine::LinkCards.stub(:fetch, ->(*) { flunk 'saved quotes must not fetch' }) do
          doc = Nokogiri::HTML.fragment(@view.textilizable(journal, :notes))
          assert_equal 1, doc.css('.slackmine-link-card-images img').size
          assert_equal 1, doc.css('img').size
          assert_equal 1, doc.css('.slackmine-link-card').size
        end
      end
    end
  end

end
