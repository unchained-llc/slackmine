# frozen_string_literal: true
require_relative 'link_cards_test'

module Redmine
  module WikiFormatting
    def self.to_html(_format, text, *)
      # Test import selection from formatter output, not a reimplementation of Markdown.
      text
    end
  end
end

module Setting
  def self.text_formatting; 'markdown'; end
end

class LinkQuotesTest < Minitest::Test
  Q = Slackmine::LinkQuotes
  URL = LinkCardsTest::URL

  def setup
    @card = { 'author' => 'Example User', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z',
              'avatar' => 'https://cdn.example.com/avatar.png', 'text' => 'Unique searchable wording <@U123>', 'names' => { 'U123' => 'Display Name' } }
    @issue = OpenStruct.new(project: OpenStruct.new(identifier: 'example'), new_record?: false, visible?: true)
    @issue.define_singleton_method(:visible?) { |*| self[:visible?] }
    @viewer = OpenStruct.new(logged?: true)
    @viewer.define_singleton_method(:allowed_to?) { |*| true }
    @calls = []
  end

  def import(text)
    Setting.stub(:text_formatting, 'markdown') do
      Slackmine::LinkCards.stub(:fetch_for_project, ->(_project, url, **_) { @calls << url; @card }) do
        Q.import(text, @issue, @viewer)
      end
    end
  end

  def test_normal_text_skips_formatter_and_slack_lookup
    source = '普通のコメント'
    Redmine::WikiFormatting.stub(:to_html, ->(*) { flunk 'no Slack URL to format' }) do
      assert_equal source, import(source)
    end
    assert_empty @calls
  end

  def test_disabled_link_cards_preserve_source_and_saved_quotes_without_import
    source = "<p><a href=\"#{URL}\">message</a></p>" + Q.encode(@card, URL)
    Slackmine.stub(:config, { 'slack' => { 'link_cards' => { 'enabled' => false } } }) do
      Redmine::WikiFormatting.stub(:to_html, ->(*) { flunk 'Disabled import formatted the source' }) do
        assert_equal source, import(source)
      end
    end
    assert_empty @calls
  end

  def test_disabling_redmine_display_keeps_quote_import_enabled
    source = "<p><a href=\"#{URL}\">message</a></p>"
    Slackmine.stub(:config, { 'slack' => { 'link_cards' => { 'redmine_enabled' => false } } }) do
      assert_includes import(source), '[slack-quote:'
    end
    assert_equal [URL], @calls
  end

  def test_quote_body_is_searchable_plain_text_and_round_trips
    source = "<p><a href=\"#{URL}\">message</a></p>"
    saved = import(source)
    assert_includes saved, 'Unique searchable wording'
    assert_includes saved, 'Display Name'
    assert_includes saved, source
    blocks = Q.blocks(saved)
    assert_equal 1, blocks.size
    assert_equal URL, blocks.first.last['url']
    assert_equal 'Unique searchable wording <@U123|Display Name>', blocks.first.last['text']
    @calls.clear
    assert_equal saved, import(saved)
    assert_empty @calls
    plain = Q.plain_source(saved)
    refute_includes plain, '[slack-quote:'
    assert_includes plain, 'Unique searchable wording'
  end

  def test_saving_an_edited_quote_with_its_permalink_keeps_only_the_unverified_snapshot
    source = %(<a href="#{URL}">source</a>) + "\n\n" + Q.encode(@card, URL)
    source = source.sub('Unique searchable wording', 'Edited wording')
    saved = import(source)
    assert_equal source, saved
    assert_empty @calls
    entries = Q.blocks(saved)
    assert_equal 1, entries.size
    card = entries.first.last
    refute card['verified']
    html = Slackmine::LinkCards.render_card(card, URL, @issue.project)
    doc = Nokogiri::HTML.fragment(html)
    assert_equal 1, doc.css('.slackmine-unverified-quote').size
    assert_includes doc.text, 'Edited wording'
    assert_empty doc.css('.slackmine-link-card-header, img')
    refute_includes doc.text, 'Example User'
    assert_equal saved, import(saved)
    assert_empty @calls
  end

  def test_editing_a_multi_message_quote_does_not_refetch_any_of_its_source_urls
    second = URL.sub('755579', '755580')
    card = @card.merge('source_urls' => [URL, second])
    source = %(<a href="#{URL}">one</a><a href="#{second}">two</a>) + "\n\n" + Q.encode(card, URL)
    source = source.sub('Unique searchable wording', 'Edited wording')
    assert_equal source, import(source)
    assert_empty @calls
    entries = Q.blocks(source)
    assert_equal 1, entries.size
    refute entries.first.last['verified']
    assert_equal [URL, second], entries.first.last['source_urls']
    refute entries.first.last.key?('avatar')
  end

  def test_unsigned_legacy_quote_is_not_silently_replaced_or_duplicated_on_save
    data = @card.reject { |key, _| key == 'text' }.merge('url' => URL)
    quote = "[slack-quote:#{Base64.strict_encode64(JSON.generate(data))}:0123456789abcdef]\nLegacy wording\n[/slack-quote:0123456789abcdef]"
    source = %(<a href="#{URL}">source</a>) + "\n\n" + quote
    assert_equal source, import(source)
    assert_empty @calls
    assert_equal 1, Q.blocks(source).size
    refute Q.blocks(source).first.last['verified']
  end

  def legacy_quote(card = @card)
    data = card.reject { |key, _| key == 'text' }.merge('url' => URL)
    "[slack-quote:#{Base64.strict_encode64(JSON.generate(data))}:0123456789abcdef]\n#{Q.resolved_text(card)}\n[/slack-quote:0123456789abcdef]"
  end

  def test_signing_defaults_on_and_only_boolean_false_disables_it
    [nil, true, 'false', 0].each do |value|
      Slackmine.stub(:config, { 'slack' => { 'link_cards' => { 'sign_quotes' => value } } }) do
        assert Q.signing_enabled?
        assert Q.blocks(Q.encode(@card, URL)).first.last['verified']
      end
    end
    Slackmine.stub(:config, { 'slack' => { 'link_cards' => { 'sign_quotes' => false } } }) do
      Q.stub(:signature, ->(*) { flunk 'Signing disabled must not use the key' }) do
        quote = Q.encode(@card.merge('signature' => 'stale', 'verified' => true), URL)
        metadata = JSON.parse(Base64.strict_decode64(Q::PATTERN.match(quote)[1]))
        refute metadata.key?('signature')
        refute metadata.key?('verified')
      end
    end
  end

  def test_signing_and_verification_are_independent_in_all_four_combinations
    [true, false].product([true, false]).each do |sign, verify|
      settings = { 'slack' => { 'link_cards' => { 'sign_quotes' => sign, 'verify_signatures' => verify } } }
      Slackmine.stub(:config, settings) do
        quote = Q.encode(@card, URL)
        metadata = JSON.parse(Base64.strict_decode64(Q::PATTERN.match(quote)[1]))
        assert_equal sign, metadata.key?('signature')
        card = Q.blocks(quote).first.last
        assert_equal sign || !verify, card['verified']
        assert_includes card['text'], 'Unique searchable wording'
      end
    end
  end

  def test_project_signing_override_applies_when_importing_without_thread_context
    settings = { 'slack' => { 'link_cards' => { 'sign_quotes' => true } },
                 'projects' => { 'example' => { 'slack' => { 'link_cards' => { 'sign_quotes' => false } } } } }
    Slackmine.stub(:config, settings) do
      assert Q.signing_enabled?(nil)
      refute Q.signing_enabled?(@issue.project)
      quote = import(%(<a href="#{URL}">source</a>))
      metadata = JSON.parse(Base64.strict_decode64(Q::PATTERN.match(quote)[1]))
      refute metadata.key?('signature')
      refute Q.blocks(quote, project: @issue.project).first.last['verified']
      assert Q.blocks(Q.encode(@card, URL, project: nil)).first.last['verified']
      signed, = Q.sign_legacy(quote)
      assert Q.blocks(signed, project: @issue.project).first.last['verified']
    end
  end

  def test_verification_defaults_on_and_only_boolean_false_disables_it
    quote = legacy_quote
    [nil, true, 'false', 0].each do |value|
      Slackmine.stub(:config, { 'slack' => { 'link_cards' => { 'verify_signatures' => value } } }) do
        refute Q.blocks(quote).first.last['verified']
      end
    end
    Slackmine.stub(:config, { 'slack' => { 'link_cards' => { 'verify_signatures' => false } } }) do
      assert_equal 'Example User', Q.blocks(quote).first.last['author']
      edited = Q.encode(@card, URL).sub('Unique searchable wording', 'Edited')
      assert_equal 'Example User', Q.blocks(edited).first.last['author']
      # Signature opt-out still enforces metadata and avatar validation.
      invalid = legacy_quote(@card.merge('names' => [], 'text' => 'plain'))
      assert_empty Q.blocks(invalid)
      assert_nil Q.blocks(quote).first.last['avatar']
    end
  end

  def test_verification_supports_explicit_project_overrides_and_plain_text
    settings = { 'slack' => { 'link_cards' => { 'verify_signatures' => false } },
                 'projects' => { 'example' => { 'slack' => { 'link_cards' => { 'verify_signatures' => true } } } } }
    Slackmine.stub(:config, settings) do
      quote = legacy_quote
      assert Q.blocks(quote, project: nil).first.last['verified']
      refute Q.blocks(quote, project: @issue.project).first.last['verified']
      assert_includes Q.plain_source(quote, project: nil), 'Example User'
      refute_includes Q.plain_source(quote, project: @issue.project), 'Example User'
      match = Q::PATTERN.match(quote)
      refute Q.decode(match[1], match[3], verify: true)['verified']
    end
  end

  def test_explicit_legacy_signing_preserves_body_metadata_and_is_idempotent
    quote = legacy_quote.gsub("\n", "\r\n")
    source = "Before\n#{quote}\nAfter"
    updated, counts = Q.sign_legacy(source)
    assert_equal({ signed: 1 }, counts)
    before = Q::PATTERN.match(source)
    after = Q::PATTERN.match(updated)
    assert_equal before[2], after[2]
    assert_equal before[3], after[3]
    old_data = JSON.parse(Base64.strict_decode64(before[1]))
    new_data = JSON.parse(Base64.strict_decode64(after[1]))
    assert new_data.delete('signature')
    assert_equal old_data, new_data
    assert_equal source.sub(before[1], after[1]), updated
    assert Q.blocks(updated).first.last['verified']
    again, counts = Q.sign_legacy(updated)
    assert_equal updated, again
    assert_equal({ skipped: 1 }, counts)
  end

  def test_legacy_signing_does_not_resign_invalid_signatures_or_malformed_metadata
    edited = Q.encode(@card, URL).sub('Unique searchable wording', 'Edited')
    invalid = legacy_quote(@card.merge('names' => [], 'text' => 'plain'))
    source = edited + invalid
    updated, counts = Q.sign_legacy(source)
    assert_equal source, updated
    assert_equal({ skipped: 1, invalid: 1 }, counts)
  end

  def test_parent_quote_is_also_plain_text_and_can_contain_closing_markers
    @card['thread_reply'] = true
    @card['parent_url'] = URL
    @card['parent'] = @card.reject { |key, _| %w[parent parent_url thread_reply].include?(key) }.merge('text' => 'Parent searchable wording')
    @card['text'] = "Literal [/slack-quote:0000000000000000]\n``` code ```\n<script>alert(1)</script>"
    saved = Q.encode(@card, URL)
    assert_includes saved, 'Parent searchable wording'
    decoded = Q.blocks(saved).first.last
    assert_equal @card['text'], decoded['text']
    assert_equal 'Parent searchable wording', decoded['parent']['text']
    html = Slackmine::LinkCards.render_card(decoded, URL, @issue.project)
    assert_includes html, 'Thread reply'
    assert_empty Nokogiri::HTML.fragment(html).css('script')
  end

  def test_imported_notification_reply_omits_parent_but_manual_url_keeps_it
    @card['thread_reply'] = true
    @card['parent_url'] = URL
    @card['parent'] = @card.reject { |key, _| %w[parent parent_url thread_reply].include?(key) }
                           .merge('text' => 'Parent notification')
    source = "<a href=\"#{URL}\">reply</a>"
    previous = Thread.current[:slackmine_thread_comment]
    Thread.current[:slackmine_thread_comment] = true
    saved = import(source)
    decoded = Q.blocks(saved).first.last
    assert_equal URL, decoded['url']
    assert_equal 'Unique searchable wording <@U123|Display Name>', decoded['text']
    refute decoded.key?('parent')
    refute decoded.key?('thread_reply')
    refute_includes saved, 'Parent notification'
    html = Slackmine::LinkCards.render_card(decoded, URL, @issue.project)
    refute_includes html, 'Thread reply'
    refute_includes html, 'Open parent message'
    assert_includes html, 'Example User'
    assert_equal URL, Nokogiri::HTML.fragment(html).at_css('a')['href']

    Thread.current[:slackmine_thread_comment] = nil
    manual = Q.blocks(import(source)).first.last
    assert_equal 'Parent notification', manual['parent']['text']
    assert_equal true, manual['thread_reply']
    assert @card.key?('parent')
  ensure
    Thread.current[:slackmine_thread_comment] = previous
  end

  def test_permissions_failures_code_and_duplicate_targets
    source = "<a href=\"#{URL}\">one</a><a href=\"#{URL}?cid=C123\">two</a><pre><a href=\"#{URL.sub('C123', 'C456')}\">code</a></pre>"
    saved = import(source)
    assert_equal [URL], @calls
    assert_equal 1, Q.blocks(saved).size
    @viewer[:logged?] = false
    @calls.clear
    assert_equal source, import(source)
    assert_empty @calls
    @viewer[:logged?] = true
    @issue[:visible?] = false
    assert_equal source, import(source)
    assert_empty @calls
    @issue[:new_record?] = true
    assert_equal 1, Q.blocks(import(source)).size
    Setting.stub(:text_formatting, 'markdown') do
      Slackmine::LinkCards.stub(:fetch_for_project, nil) do
        assert_equal source, Q.import(source, @issue, @viewer)
      end
    end
  end

  def test_file_association_is_only_recorded_for_the_imported_reply
    origin = Thread.current[:slackmine_thread_comment]
    previous = Thread.current[:slackmine_thread_files]
    Thread.current[:slackmine_thread_comment] = true
    Thread.current[:slackmine_thread_files] = { url: URL, ids: [41] }
    source = %(<a href="#{URL}">reply</a>)
    assert_equal [41], Q.blocks(import(source)).first.last['thread_file_ids']
    Thread.current[:slackmine_thread_files] = { url: URL.sub('C123', 'C456'), ids: [41] }
    refute Q.blocks(import(source)).first.last.key?('thread_file_ids')
    [[], [0], ['41'], [41, 41], (1..11).to_a].each do |ids|
      assert_empty Q.blocks(Q.encode(@card.merge('thread_file_ids' => ids), URL))
    end
  ensure
    Thread.current[:slackmine_thread_comment] = origin
    Thread.current[:slackmine_thread_files] = previous
  end

  def test_image_association_is_only_recorded_for_the_imported_reply
    origin = Thread.current[:slackmine_thread_comment]
    images = Thread.current[:slackmine_thread_images]
    source = %(<a href="#{URL}">reply</a>)
    Thread.current[:slackmine_thread_comment] = true
    Thread.current[:slackmine_thread_images] = { url: URL, ids: [41, 42] }
    assert_equal [41, 42], Q.blocks(import(source)).first.last['thread_image_ids']
    Thread.current[:slackmine_thread_images] = { url: URL.sub('C123', 'C456'), ids: [41] }
    refute Q.blocks(import(source)).first.last.key?('thread_image_ids')
    Thread.current[:slackmine_thread_images] = { url: URL, ids: [41] }
    Thread.current[:slackmine_thread_comment] = nil
    refute Q.blocks(import(source)).first.last.key?('thread_image_ids')
    [[], [0], ['41'], [41, 41], (1..11).to_a].each do |ids|
      assert_empty Q.blocks(Q.encode(@card.merge('thread_image_ids' => ids), URL))
    end
  ensure
    Thread.current[:slackmine_thread_comment] = origin
    Thread.current[:slackmine_thread_images] = images
  end

  def test_invalid_metadata_is_not_interpreted_and_unsafe_avatar_is_removed
    encoded = Base64.strict_encode64(JSON.generate(@card.merge('url' => 'javascript:alert(1)')))
    assert_nil Q.decode(encoded, 'body')
    assert_empty Q.blocks('[slack-quote:invalid:0000000000000000]')
    @card['avatar'] = 'javascript:alert(1)'
    assert_nil Q.blocks(Q.encode(@card, URL)).first.last['avatar']
  end

  def test_batch_snapshots_preserve_text_and_per_message_attachments_without_refetching_replies
    origin = Thread.current[:slackmine_thread_comment]
    previous = Thread.current[:slackmine_thread_messages]
    files = Thread.current[:slackmine_thread_files]
    second_url = URL.sub(/p\d+/, 'p1791001000000003')
    Thread.current[:slackmine_thread_comment] = true
    Thread.current[:slackmine_thread_messages] = [
      { url: URL, message: { 'ts' => '1791001000.000002', 'user' => 'U123', 'channel' => 'C123', 'text' => 'First short message' } },
      { url: second_url, message: { 'ts' => '1791001000.000003', 'user' => 'U123', 'channel' => 'C123', 'text' => 'Second short message' } }
    ]
    Thread.current[:slackmine_thread_files] = [{ url: URL, ids: [41] }, { url: second_url, ids: [42] }]
    Slackmine.stub(:slack_api, ->(method, *_args, **_options) {
      refute_includes %w[conversations.history conversations.replies], method
      # Profile lookups may fail, but accepted text must still be saved.
      raise Slackmine::SlackApiError.new(method, '403', { 'error' => 'missing_scope' })
    }) do
      cards = Q.blocks(import(%(<a href="#{URL}">first</a><a href="#{second_url}">second</a>))).map(&:last)
      assert_equal 1, cards.size
      assert_equal "First short message\nSecond short message", cards.first['text']
      assert_equal [41, 42], cards.first['thread_file_ids']
      assert_equal [URL, second_url], cards.first['source_urls']
      assert_includes Q.plain_source(Q.encode(cards.first, URL)), second_url
      rendered = Slackmine::LinkCards.render_card(cards.first, URL, @issue.project)
      fragment = Nokogiri::HTML.fragment(%(<p><a href="#{URL}">first</a></p><p><a href="#{second_url}">second</a></p>))
      Slackmine::LinkCards.place_saved_cards(fragment, { 'BATCH' => rendered }, { 'BATCH' => [URL, second_url] })
      assert_equal 1, fragment.css('.slackmine-link-card').size
      assert_equal 1, fragment.css('.slackmine-link-card-header').size
      assert_equal [URL], fragment.css('a[href]').map { |a| a['href'] }
      assert_equal "First short message\nSecond short message", fragment.at_css('.slackmine-link-card-text').text
      assert_empty fragment.css('a a')
      assert_includes fragment.text, 'First short message'
      assert_includes fragment.text, 'Second short message'
    end
  ensure
    Thread.current[:slackmine_thread_comment] = origin
    Thread.current[:slackmine_thread_messages] = previous
    Thread.current[:slackmine_thread_files] = files
  end

  def test_callbacks_import_only_changed_fields_and_attach_before_validation
    callback_class = Class.new do
      class << self
        attr_reader :callback
        def before_validation(name); @callback = name; end
        def after_create_commit(*); end
        def after_update_commit(*); end
        def after_destroy_commit(*); end
      end
      attr_accessor :description, :notes, :journalized, :changed
      def will_save_change_to_description?; changed; end
      def will_save_change_to_notes?; changed; end
    end
    issue_class = Class.new(callback_class) { include Slackmine::IssuePatch }
    journal_class = Class.new(callback_class) { include Slackmine::JournalPatch }
    assert_equal :import_slack_description_quotes, issue_class.callback
    assert_equal :import_slack_notes_quotes, journal_class.callback
    record = issue_class.new
    record.description = 'source'
    record.changed = true
    User.stub(:current, @viewer) do
      Q.stub(:import, ->(text, issue, viewer) { assert_equal record, issue; assert_equal @viewer, viewer; text + ' quote' }) do
        record.send(:import_slack_description_quotes)
      end
    end
    assert_equal 'source quote', record.description
    record.changed = false
    Q.stub(:import, ->(*) { flunk 'unchanged field' }) { record.send(:import_slack_description_quotes) }
    journal = journal_class.new
    journal.journalized = Issue.new(123)
    journal.notes = 'comment'; journal.changed = true
    User.stub(:current, @viewer) do
      Q.stub(:import, ->(text, issue, *) { assert_equal journal.journalized, issue; text + ' quote' }) do
        journal.send(:import_slack_notes_quotes)
      end
    end
    assert_equal 'comment quote', journal.notes
  end
  def test_plain_mail_and_slack_notifications_hide_storage_markers
    @card['author'] = '投稿者'
    @card['text'] = 'Unique searchable wording 日本語'
    quote = Q.encode(@card, URL).dup.force_encoding(Encoding::ASCII_8BIT)
    html_part = OpenStruct.new(mime_type: 'text/html', body: OpenStruct.new(decoded: '<p>HTML</p>'))
    text_part = OpenStruct.new(mime_type: 'text/plain', body: OpenStruct.new(decoded: quote))
    message = OpenStruct.new(mime_type: 'multipart/alternative', all_parts: [text_part, html_part])
    base = Class.new do
      attr_accessor :message
      def mail(*, **); message; end
    end
    mailer = Class.new(base) { prepend Slackmine::MailerPatch }.new
    mailer.message = message
    assert_same message, mailer.mail
    assert_includes text_part.body, 'Unique searchable wording'
    refute_includes text_part.body, '[slack-quote:'
    assert_equal '<p>HTML</p>', html_part.body.decoded
    slack = Slackmine::Formatter.mrkdwn(quote)
    assert_includes slack, 'Unique searchable wording'
    refute_includes slack, '[slack-quote:'
  end

end
