# frozen_string_literal: true
require 'minitest/autorun'
require 'nokogiri'
require_relative '../lib/slackmine/url_preview_fetcher'

class UrlPreviewFetcherTest < Minitest::Test
  def test_rejects_private_and_mixed_dns_answers
    ['127.0.0.1', '10.0.0.1', '::1', '::ffff:8.8.8.8'].each do |address|
      Resolv.stub(:getaddresses, [address]) do
        assert_nil Slackmine::UrlPreviewFetcher.fetch('https://example.test/')
      end
    end
    Resolv.stub(:getaddresses, ['8.8.8.8', '192.168.1.1']) do
      assert_nil Slackmine::UrlPreviewFetcher.fetch('https://example.test/')
    end
  end

  def test_extracts_open_graph_data_and_resolves_image
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response['content-type'] = 'text/html; charset=utf-8'
    html = '<html><head><title>Fallback</title><meta property="og:title" content="Example &amp; Co"><meta property="og:description" content="A page"><meta property="og:image" content="/cover.png"></head></html>'
    response.define_singleton_method(:read_body) { |&block| block.call(html) }
    http = Object.new
    %i[ipaddr= use_ssl= open_timeout= read_timeout=].each { |name| http.define_singleton_method(name) { |_value| } }
    http.define_singleton_method(:start) { |&block| block.call(self) }
    captured = []
    http.define_singleton_method(:request) { |request, &block| captured << request; block.call(response) }
    Resolv.stub(:getaddresses, ['8.8.8.8']) do
      Net::HTTP.stub(:new, http) do
        result = Slackmine::UrlPreviewFetcher.fetch('https://example.test/page')
        assert_equal 'Slackmine-LinkPreview/1.0', captured.first['User-Agent']
        assert_equal 'Example & Co', result[:title]
        assert_equal 'A page', result[:description]
        assert_equal 'https://example.test/cover.png', result[:image]
      end
    end
  end
end
