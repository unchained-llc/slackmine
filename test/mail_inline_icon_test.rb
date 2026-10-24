# frozen_string_literal: true
require 'minitest/autorun'
require 'rails-html-sanitizer'
require_relative '../lib/slackmine/mail_inline_icon'
require_relative '../lib/slackmine/mail_preference'

class MailInlineIconTest < Minitest::Test
  ICON = '<span class="slackmine-link-card"><a href="https://example.slack.com/archives/C123/p123"><span class="slackmine-mail-link-layout" style="display: inline-table; vertical-align: middle"><span style="display: table-cell; vertical-align: middle; padding-right: 6px"><img class="slackmine-mail-icon" src="slackmine-bundled-logo.png"></span><span style="display: table-cell; vertical-align: middle; line-height: 20px"><strong>Japanese text</strong></span></span></a></span>'.freeze

  def assert_embedded(message, count)
    # Encoding can lazily repair missing headers; verify before that happens.
    related = ([message] + message.all_parts).find { |part| part.mime_type == 'multipart/related' }
    refute_nil related
    refute_nil related.boundary
    refute_empty related.boundary
    assert_equal related.boundary, related.body.boundary
    raw_related = related.header.encoded + "\r\n" + related.body.encoded
    parsed_related = Mail.read_from_string(raw_related)
    assert_equal ['text/html', 'image/png'], parsed_related.parts.map(&:mime_type)
    received = Mail.read_from_string(message.encoded)
    html = received.all_parts.find { |part| part.mime_type == 'text/html' }
    doc = Nokogiri::HTML.parse(html.body.decoded)
    logos = received.attachments.select { |part| part.filename == 'slackmine-logo.png' }
    assert_equal 1, logos.size
    assert_equal 'inline', logos.first.content_disposition.split(';').first
    assert_equal File.binread(Slackmine::MailInlineIcon::PATH), logos.first.body.decoded
    assert_equal count, doc.css('img').size
    doc.css('img').each { |img| assert_includes img['style'], 'display: block' }
    assert_equal count, doc.css('.slackmine-mail-link-layout').size
    doc.css('.slackmine-mail-link-layout').each do |layout|
      assert_equal 2, layout.element_children.size
      layout.element_children.each { |cell| assert_match(/vertical-align:\s*middle/, cell['style']) }
      assert_equal 'Japanese text', layout.element_children.last.text
    end
    assert_equal [logos.first.url], doc.css('img').map { |img| img['src'] }.uniq
    assert_includes doc.text, 'Japanese text'
    received
  end

  def test_html_only_and_repeat_processing
    message = Mail.new(from: 'sender@example.com', to: 'recipient@example.com', subject: 'Example', content_type: 'text/html; charset=UTF-8', body: ICON * 2)
    2.times { Slackmine::MailInlineIcon.embed(message) }
    received = assert_embedded(message, 2)
    assert_equal 'recipient@example.com', received.to.first
    assert_equal 'Example', received.subject
  end

  def test_plain_part_and_existing_attachments_survive
    message = Mail.new(from: 'sender@example.com', to: 'recipient@example.com')
    message.text_part = Mail::Part.new(content_type: 'text/plain; charset=UTF-8', body: 'Plain notification')
    message.html_part = Mail::Part.new(content_type: 'text/html; charset=UTF-8', body: ICON)
    message.attachments['document.pdf'] = {mime_type: 'application/pdf', content: 'PDF content'}
    Slackmine::MailInlineIcon.embed(message)
    received = assert_embedded(message, 1)
    assert_equal 'Plain notification', received.all_parts.find { |part| part.mime_type == 'text/plain' }.body.decoded
    assert_equal 'PDF content', received.attachments['document.pdf'].body.decoded
  end

  def test_mailer_patch_embeds_logo_when_mail_is_built
    base = Class.new do
      def mail(*args, **kwargs)
        Mail.new(content_type: 'text/html; charset=UTF-8', body: MailInlineIconTest::ICON)
      end
    end
    mailer = Class.new(base) { prepend Slackmine::MailerPatch }.new
    assert_embedded(mailer.mail, 1)
  end

  def test_sanitized_template_still_embeds_logo
    allowed_tags = %w[a b blockquote br code del div em h1 h2 h3 h4 h5 h6 hr i img li ol p pre s span strong table tbody td th thead tr u ul]
    allowed_attributes = %w[alt class colspan href rowspan src style title width height]
    html = Rails::Html::SafeListSanitizer.new.sanitize(ICON, tags: allowed_tags, attributes: allowed_attributes)
    assert_equal Slackmine::MailInlineIcon::SOURCE, Nokogiri::HTML.fragment(html).at_css('img')['src']
    message = Mail.new(content_type: 'text/html; charset=UTF-8', body: html)
    Slackmine::MailInlineIcon.embed(message)
    received = assert_embedded(message, 1)
    refute_includes received.all_parts.find { |part| part.mime_type == 'text/html' }.body.decoded, Slackmine::MailInlineIcon::SOURCE
  end

  def test_mailer_patch_preserves_long_japanese_html_when_delivery_inlines_css
    text = "Issue updated. \u65e5\u672c\u8a9e comment." * 1000
    avatar = '<img class="slackmine-mail-avatar" src="https://avatars.slack-edge.com/example.png">'
    html = '<html><body><p>' + text + '</p>' + ICON.sub('</span></a>', avatar + '</span></a>') + '</body></html>'
    base = Class.new do
      define_method(:mail) do |*args|
        message = Mail.new
        message.text_part = Mail::Part.new(content_type: 'text/plain; charset=UTF-8', body: 'Plain text')
        message.html_part = Mail::Part.new(content_type: 'text/html; charset=UTF-8', body: html)
        message
      end
    end
    mailer = Class.new(base) { prepend Slackmine::MailerPatch }.new
    image = File.binread(Slackmine::MailInlineIcon::PATH)
    Slackmine::MailInlineAvatar.stub(:fetch, { content: image, mime_type: 'image/png', extension: 'png' }) do
      message = mailer.mail
      part = message.html_part
      assert_nil part.content_transfer_encoding
      # Roadie::Rails::MailInliner assigns transformed, decoded HTML on delivery.
      document = Nokogiri::HTML.parse(part.body.decoded, nil, 'UTF-8')
      document.at_css('p')['style'] = 'color: purple'
      part.body = document.to_html
      received = Mail.read_from_string(message.encoded)
      doc = Nokogiri::HTML.parse(received.html_part.body.decoded, nil, 'UTF-8')
      assert_equal text, doc.at_css('p').text
      assert_equal 'color: purple', doc.at_css('p')['style']
      assert_equal 'Plain text', received.text_part.body.decoded.force_encoding('UTF-8')
      assert_equal 2, received.attachments.size
      received.attachments.each { |attachment| assert_equal image, attachment.body.decoded }
      assert doc.css('img').all? { |node| node['src'].start_with?('cid:') }
    end
  end

  def test_unmarked_mail_is_untouched
    message = Mail.new(content_type: 'text/html', body: '<img src="https://example.com/logo.png">')
    Slackmine::MailInlineIcon.embed(message)
    assert_empty message.attachments
    assert_equal '<img src="https://example.com/logo.png">', message.body.decoded
  end
end
