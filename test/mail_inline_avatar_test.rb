# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../lib/slackmine/mail_inline_avatar'
require_relative '../lib/slackmine/mail_inline_icon'

class MailInlineAvatarTest < Minitest::Test
  CDN = 'https://avatars.slack-edge.com/2026-01-01/example_48.png'.freeze
  PNG = File.binread(Slackmine::MailInlineIcon::PATH).freeze

  def avatar(source = CDN)
    %(<span class="slackmine-link-card"><img class="slackmine-mail-avatar" src="#{source}" alt="" width="28" height="28"></span>)
  end

  def data
    { content: PNG, mime_type: 'image/png', extension: 'png' }
  end

  def html_part(message)
    ([message] + message.all_parts).find { |part| part.mime_type == 'text/html' }
  end

  def test_deduplicated_cid_survives_wire_encoding_and_repeat_processing
    message = Mail.new(content_type: 'text/html; charset=UTF-8', body: avatar.sub('alt=""', 'style="height:auto;max-width:100%" alt=""') * 2)
    calls = []
    Slackmine::MailInlineAvatar.stub(:fetch, ->(url, *) { calls << url; data }) do
      2.times { Slackmine::MailInlineAvatar.embed(message) }
    end
    assert_equal [CDN], calls
    received = Mail.read_from_string(message.encoded)
    assert_equal 'multipart/related', received.mime_type
    assert_equal ['text/html', 'image/png'], received.parts.map(&:mime_type)
    image = received.attachments.first
    assert_equal PNG, image.body.decoded
    assert_match(/inline/, image.content_disposition)
    doc = Nokogiri::HTML.fragment(html_part(received).body.decoded)
    assert_equal [image.url, image.url], doc.css('img').map { |node| node['src'] }
    doc.css('img').each do |node|
      assert_includes node['style'], 'width: 28px; height: 28px; max-width: 28px'
      assert_includes node['style'], 'display: block'
      assert_includes node['style'], 'border-radius: 6px'
      refute_includes node['style'], 'height:auto'
    end
    refute_includes doc.to_html, CDN
  end

  def test_existing_logo_related_container_plain_text_and_pdf_are_preserved
    message = Mail.new
    message.text_part = Mail::Part.new(content_type: 'text/plain', body: 'Plain')
    message.html_part = Mail::Part.new(content_type: 'text/html', body: avatar + '<span class="slackmine-link-card"><img class="slackmine-mail-icon" src="slackmine-bundled-logo.png"></span>')
    message.attachments['example.pdf'] = { mime_type: 'application/pdf', content: 'PDF' }
    Slackmine::MailInlineIcon.embed(message)
    Slackmine::MailInlineAvatar.stub(:fetch, data) { Slackmine::MailInlineAvatar.embed(message) }
    received = Mail.read_from_string(message.encoded)
    related = received.all_parts.select { |part| part.mime_type == 'multipart/related' }
    assert_equal 1, related.size
    assert_equal ['text/html', 'image/png', 'image/png'], related.first.parts.map(&:mime_type)
    assert_equal 'Plain', received.text_part.body.decoded
    assert_equal 'PDF', received.attachments['example.pdf'].body.decoded
    doc = Nokogiri::HTML.fragment(html_part(received).body.decoded)
    assert doc.css('img').all? { |node| node['src'].start_with?('cid:') }
  end

  def test_template_inline_images_share_one_related_scope_with_slack_images
    message = Mail.new(content_type: 'multipart/related')
    alternative = Mail::Part.new(content_type: 'multipart/alternative')
    alternative.add_part(Mail::Part.new(content_type: 'text/plain', body: 'Plain'))
    alternative.add_part(Mail::Part.new(content_type: 'text/html', body: avatar +
      '<span class="slackmine-link-card"><img class="slackmine-mail-icon" src="slackmine-bundled-logo.png"></span>'))
    message.add_part(alternative)
    message.attachments.inline['template-logo.png'] = { mime_type: 'image/png', content: PNG }

    Slackmine::MailInlineIcon.embed(message)
    Slackmine::MailInlineAvatar.stub(:fetch, data) { Slackmine::MailInlineAvatar.embed(message) }
    received = Mail.read_from_string(message.encoded)
    assert_equal 1, ([received] + received.all_parts).count { |part| part.mime_type == 'multipart/related' }
    assert_equal 'multipart/alternative', received.parts.first.mime_type
    assert_equal ['text/plain', 'text/html'], received.parts.first.parts.map(&:mime_type)
    assert_equal 3, received.parts.count { |part| part.mime_type == 'image/png' }
    doc = Nokogiri::HTML.fragment(html_part(received).body.decoded)
    doc.css('img').each do |node|
      assert received.parts.any? { |part| part.mime_type == 'image/png' && part.url == node['src'] }
    end
  end

  def test_failed_fetch_removes_avatar_and_does_not_affect_unmarked_images
    message = Mail.new(content_type: 'text/html', body: avatar + '<img src="https://example.com/other.png">')
    Slackmine::MailInlineAvatar.stub(:fetch, nil) { Slackmine::MailInlineAvatar.embed(message) }
    doc = Nokogiri::HTML.fragment(message.body.decoded)
    assert_equal ['https://example.com/other.png'], doc.css('img').map { |node| node['src'] }
    assert_empty message.attachments
  end

  def test_distinct_fetches_are_bounded
    message = Mail.new(content_type: 'text/html', body: 10.times.map { |i| avatar(CDN.sub('example', "image#{i}")) }.join)
    calls = 0
    Slackmine::MailInlineAvatar.stub(:fetch, ->(*) { calls += 1; nil }) { Slackmine::MailInlineAvatar.embed(message) }
    assert_equal 4, calls
    assert_empty Nokogiri::HTML.fragment(message.body.decoded).css('img')
  end

  def test_non_cdn_urls_are_rejected_without_network_requests
    sources = ['http://avatars.slack-edge.com/a.png', 'https://example.com/a.png',
               'https://avatars.slack-edge.com.evil.example/a.png', 'https://user@avatars.slack-edge.com/a.png',
               'https://avatars.slack-edge.com:444/a.png', CDN + '?query=1', CDN + '#fragment', 'invalid']
    Net::HTTP.stub(:start, ->(*) { flunk 'must not access network' }) do
      sources.each { |source| assert_nil Slackmine::MailInlineAvatar.fetch(source, 1) }
    end
  end

  DEFAULT = 'https://a.slack-edge.com/example/img/avatars/ava_0022-48.png'.freeze
  GRAVATAR = ('https://secure.gravatar.com/avatar/' + 'a' * 32 + '.jpg?' +
              URI.encode_www_form('s' => '48', 'd' => DEFAULT)).freeze

  def test_slack_gravatar_is_embedded_as_cid
    message = Mail.new(content_type: 'text/html', body: avatar(GRAVATAR.gsub('&', '&amp;')))
    with_response(Net::HTTPOK.new('1.1', '200', 'OK'), [PNG]) do
      Slackmine::MailInlineAvatar.embed(message)
    end
    received = Mail.read_from_string(message.encoded)
    assert_equal PNG, received.attachments.first.body.decoded
    assert_equal received.attachments.first.url, Nokogiri::HTML.fragment(html_part(received).body.decoded).at_css('img')['src']
  end

  def with_redirects(locations)
    visited = []
    http = Object.new
    http.define_singleton_method(:request) do |request, &block|
      raise 'credentials must not be sent' if request['Authorization']
      location = locations.shift
      response = if location
                   Net::HTTPFound.new('1.1', '302', 'Found').tap { |r| r['Location'] = location }
                 else
                   Net::HTTPOK.new('1.1', '200', 'OK')
                 end
      response.define_singleton_method(:read_body) { |&reader| reader.call(PNG) }
      block.call(response)
    end
    Net::HTTP.stub(:start, ->(host, *args, **options, &block) { visited << host; block.call(http) }) do
      yield visited
    end
  end

  def test_gravatar_redirects_to_slack_default_within_same_download_budget
    with_redirects([GRAVATAR.sub('secure.gravatar.com', 'www.gravatar.com'), DEFAULT]) do |visited|
      assert_equal data, Slackmine::MailInlineAvatar.fetch(GRAVATAR, 1)
      assert_equal %w[secure.gravatar.com www.gravatar.com a.slack-edge.com], visited
    end
  end

  def test_unsafe_gravatar_parameters_are_rejected_without_network
    base = GRAVATAR.split('?').first
    sources = [base.sub('a' * 32, 'not-a-hash'), base + '?s=9999', base + '?s=48&s=96',
               base + '?url=https://example.com/image.png',
               base + '?' + URI.encode_www_form('d' => 'https://127.0.0.1/avatar.png'),
               base + '?' + URI.encode_www_form('d' => GRAVATAR),
               base + '?' + URI.encode_www_form('d' => DEFAULT.sub('/img/avatars/', '/other/')),
               DEFAULT + '?query=1']
    Net::HTTP.stub(:start, ->(*) { flunk 'must not access network' }) do
      sources.each { |source| assert_nil Slackmine::MailInlineAvatar.fetch(source, 1) }
    end
  end

  def test_gravatar_redirect_targets_and_hops_are_bounded
    ['https://127.0.0.1/avatar.png', 'https://secure.gravatar.com.evil.example/avatar.png',
     DEFAULT.sub('https:', 'http:'), DEFAULT.sub('/img/avatars/', '/other/')].each do |target|
      with_redirects([target]) do |visited|
        assert_nil Slackmine::MailInlineAvatar.fetch(GRAVATAR, 1)
        assert_equal ['secure.gravatar.com'], visited
      end
    end
    with_redirects([GRAVATAR, GRAVATAR, GRAVATAR]) do |visited|
      assert_nil Slackmine::MailInlineAvatar.fetch(GRAVATAR, 1)
      assert_equal 3, visited.size
    end
  end

  def test_gravatar_wordpress_proxy_accepts_only_slack_avatar_paths
    proxy = 'https://i2.wp.com/a.slack-edge.com/example/img/avatars/ava_0022-48.png?ssl=1'
    with_redirects([proxy]) do |visited|
      assert_equal data, Slackmine::MailInlineAvatar.fetch(GRAVATAR, 1)
      assert_equal %w[secure.gravatar.com i2.wp.com], visited
    end
    [proxy.sub('a.slack-edge.com', '127.0.0.1'), proxy.sub('/img/avatars/', '/other/'),
     proxy + '&url=https://example.com', proxy.sub('i2.wp.com', 'i2.wp.com.evil.example')].each do |target|
      with_redirects([target]) do |visited|
        assert_nil Slackmine::MailInlineAvatar.fetch(GRAVATAR, 1)
        assert_equal ['secure.gravatar.com'], visited
      end
    end
  end

  def with_response(response, chunks)
    response.define_singleton_method(:read_body) { |&block| chunks.each(&block) }
    http = Object.new
    http.define_singleton_method(:request) do |request, &block|
      raise 'credentials must not be sent' if request['Authorization']
      block.call(response)
    end
    Net::HTTP.stub(:start, ->(*args, **options, &block) { block.call(http) }) { yield }
  end

  def test_download_validates_image_bytes_and_size_and_does_not_follow_redirects
    with_response(Net::HTTPOK.new('1.1', '200', 'OK'), [PNG]) do
      assert_equal data, Slackmine::MailInlineAvatar.fetch(CDN, 1)
    end
    with_response(Net::HTTPOK.new('1.1', '200', 'OK'), ['<html>not an image</html>']) do
      assert_nil Slackmine::MailInlineAvatar.fetch(CDN, 1)
    end
    with_response(Net::HTTPOK.new('1.1', '200', 'OK'), ['a' * (Slackmine::MailInlineAvatar::MAX_BYTES + 1)]) do
      assert_nil Slackmine::MailInlineAvatar.fetch(CDN, 1)
    end
    response = Net::HTTPFound.new('1.1', '302', 'Found')
    response['Location'] = 'https://example.com/image.png'
    with_response(response, [PNG]) { assert_nil Slackmine::MailInlineAvatar.fetch(CDN, 1) }
    Net::HTTP.stub(:start, ->(*) { raise Timeout::Error }) do
      assert_nil Slackmine::MailInlineAvatar.fetch(CDN, 1)
    end
  end
end
