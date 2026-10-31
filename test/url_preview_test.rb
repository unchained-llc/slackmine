# frozen_string_literal: true
require 'minitest/autorun'
require 'ostruct'
require_relative '../lib/slackmine/url_preview'
require_relative '../lib/slackmine/notification_coalescing'

module Rails
  def self.logger; nil; end
end
class Journal
  class << self; attr_accessor :record; end
  def self.find_by(id:); record; end
end
module Slackmine
  class << self
    attr_accessor :configuration, :restricted
    def effective_config(_project); configuration; end
    def files_transfer_restricted?(_project); restricted; end
  end
  module NotificationSafety
    class << self; attr_accessor :allowed; end
    def self.allowed?(*); allowed; end
  end
end

class UrlPreviewTest < Minitest::Test
  URL = 'https://example.com/article?a=1&b=2'
  def setup
    Slackmine.configuration = {'slack' => {'url_previews' => true}}
    Slackmine.restricted = false
    Slackmine::NotificationSafety.allowed = true
    Journal.record = OpenStruct.new(notes: URL)
    @project = Object.new
    @context = {'event' => 'comment_added', 'journal_id' => 9}
    @payload = {'attachments' => [{'blocks' => [{'type' => 'section', 'text' => {'type' => 'mrkdwn', 'text' => CGI.escapeHTML(URL)}}]}]}
    @metadata = {title: 'A & B', description: 'Hello', host: 'example.com', image: 'https://example.com/a.jpg'}
  end

  def mark(&fetch)
    Slackmine::UrlPreviewFetcher.stub(:fetch, fetch || ->(*) { @metadata }) do
      Slackmine::UrlPreview.mark(@payload, project: @project, journal_id: 9, context: @context)
    end
  end

  def test_card_has_right_side_image_and_no_duplicate_text
    result = mark
    card = result.dig('attachments', 0, 'blocks', 1)
    assert_includes card.dig('text', 'text'), 'A &amp; B'
    assert_equal @metadata[:image], card.dig('accessory', 'image_url')
    assert_equal 'image', card.dig('accessory', 'type')
    assert_equal false, result['unfurl_links']
    refute result.key?('text')
    assert_equal 1, @payload['attachments'][0]['blocks'].length
  end

  def test_disabled_restricted_or_unauthorized_never_fetches
    Slackmine.configuration['slack']['url_previews'] = false
    assert_equal @payload, mark { flunk 'disabled' }
    Slackmine.configuration['slack']['url_previews'] = true
    Slackmine.restricted = true
    assert_equal @payload, mark { flunk 'restricted' }
    Slackmine.restricted = false
    Slackmine::NotificationSafety.allowed = false
    assert_equal @payload, mark { flunk 'unauthorized' }
  end

  def test_multiple_urls_and_urls_in_text
    Journal.record.notes = "See www.unchained.co.jp\nwww.kybr.co.jp"
    @payload['attachments'][0]['blocks'][0]['text']['text'] = Journal.record.notes
    fetched = []
    result = mark { |url| fetched << url; @metadata }
    assert_equal ['http://www.unchained.co.jp', 'http://www.kybr.co.jp'], fetched
    assert_equal 3, result.dig('attachments', 0, 'blocks').length
  end

  def test_deleted_mismatched_failed_or_changed_authorization_preserves_notification
    @context['event'] = 'comment_deleted'
    assert_equal @payload, mark { flunk 'deleted' }
    @context['event'] = 'comment_added'
    @payload['attachments'][0]['blocks'][0]['text']['text'] = 'different content'
    assert_equal @payload, mark { flunk 'mismatched' }
    @payload['attachments'][0]['blocks'][0]['text']['text'] = CGI.escapeHTML(URL)
    assert_equal @payload, mark { nil }
    assert_equal @payload, mark { raise IOError }
    assert_equal @payload, mark { Slackmine::NotificationSafety.allowed = false; @metadata }
  end

  def test_markdown_links_and_code_are_handled
    source = "See [example](https://example.com/a). `https://hidden.example`"
    assert_equal [['https://example.com/a', 'https://example.com/a']], Slackmine::UrlPreview.urls_in(source)
  end

  def test_slack_rejection_fallback_removes_only_image
    result = mark
    fallback = Slackmine::UrlPreview.without_preview_images(result)
    assert_nil fallback.dig('attachments', 0, 'blocks', 1, 'accessory')
    assert_equal 2, fallback.dig('attachments', 0, 'blocks').length
    assert_equal @metadata[:image], result.dig('attachments', 0, 'blocks', 1, 'accessory', 'image_url')
  end

  def test_coalescing_retains_cards_and_unfurl_setting
    first = {'payload' => mark, 'parts' => nil}
    second = {'payload' => {'attachments' => []}, 'parts' => nil}
    outgoing, = Slackmine::NotificationCoalescing.combine_sources([first, second])
    assert_equal false, outgoing['unfurl_links']
    assert_equal 2, outgoing.dig('attachments', 0, 'blocks').length
  end
end
