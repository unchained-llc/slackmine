# frozen_string_literal: true
require_relative 'thread_comments_url_test'

module Setting
  def self.attachment_max_size; 5120; end
  def self.text_formatting; 'markdown'; end
end

class ThreadFilesTest < Minitest::Test
  IMAGES = Slackmine::ThreadFiles
  PNG = "\x89PNG\r\n\x1a\nexample".b

  def setup
    @event = { 'files' => [{ 'id' => 'F123' }] }
    @metadata = { 'id' => 'F123', 'mimetype' => 'image/png', 'size' => PNG.bytesize,
                  'name' => '../screen.png', 'url_private' => 'https://files.slack.com/files-pri/T123-F123/screen.png' }
    @uploads = []
    @calls = []
  end

  def test_retina_suffix_survives_filename_sanitizing
    @metadata['name'] = 'screen@2x.png'
    assert_equal 'F123-screen@2x.png', download.first.original_filename
  end

  def test_restrict_transfer_never_fetches_metadata_or_file_contents
    Slackmine.stub(:config, { 'slack' => { 'files' => { 'restrict_transfer' => true } } }) do
      Slackmine.stub(:slack_api, ->(*) { flunk 'Link-only fetched file metadata' }) do
        IMAGES.stub(:fetch, ->(*) { flunk 'Link-only downloaded contents' }) do
          assert_empty IMAGES.download(@event, 'token')
        end
      end
    end
  end

  def test_global_force_blocks_file_api_despite_project_exception
    settings = { 'slack' => { 'files' => { 'force_restrict_transfer' => true } },
                 'projects' => { 'example' => { 'slack' => { 'files' => { 'restrict_transfer' => false } } } } }
    Slackmine.stub(:config, settings) do
      Slackmine.with_project(OpenStruct.new(identifier: 'example')) do
        Slackmine.stub(:slack_api, ->(*) { flunk 'Forced restriction fetched files' }) do
          IMAGES.stub(:fetch, ->(*) { flunk 'Forced restriction downloaded contents' }) do
            assert_empty IMAGES.download(@event, 'token')
          end
        end
      end
    end
  end

  def teardown
    @uploads.each { |file| file.close! unless file.closed? }
  end

  def download(data = PNG)
    Slackmine.stub(:slack_api, ->(method, body, token, **_) {
      @calls << [method, body, token]
      { 'file' => @metadata }
    }) do
      IMAGES.stub(:fetch, ->(url, token, limit) {
        assert_equal @metadata['url_private'], url
        assert_equal 'token', token
        assert_equal 5120 * 1024, limit
        file = Tempfile.new('image-test'); file.binmode; file.write(data); file.rewind
        @uploads << file
        file
      }) { IMAGES.download(@event, 'token') }
    end
  end

  def test_download_authoritative_metadata_and_safe_filename
    files = download
    assert_equal [['files.info', { 'file' => 'F123' }, 'token']], @calls
    assert_equal PNG, files.first.read
    assert_equal 'F123-screen.png', files.first.original_filename
    assert_equal 'image/png', files.first.content_type
  end

  def test_pdf_and_other_files_keep_their_extension_and_content
    [['application/pdf', 'report.pdf', '%PDF-1.7 example'],
     ['application/zip', 'archive.zip', "PK archive"],
     ['text/plain', 'notes.txt', 'notes'],
     ['application/pdf', 'Document.pdf', '%PDF-1.7 example'],
     ['image/svg+xml', 'diagram.svg', '<svg></svg>']].each do |mime, name, data|
      @metadata.merge!('mimetype' => mime, 'name' => name, 'size' => data.bytesize)
      file = download(data).first
      assert_equal "F123-#{name}", file.original_filename
      assert_equal mime, file.content_type
      assert_equal data, file.read
    end
  end

  def test_duplicate_references_download_once
    @event['files'] *= 2
    assert_equal 1, download.size
    assert_equal 1, @calls.size
  end

  def test_unsupported_external_wrong_id_and_oversized_files_never_download
    [{ 'mimetype' => 'invalid' }, { 'is_external' => true }, { 'id' => 'FOTHER' },
     { 'size' => 0 }, { 'size' => 5120 * 1024 + 1 }].each do |changes|
      original = @metadata
      @metadata = original.merge(changes)
      assert_raises(IMAGES::ImportError) { download }
      assert_empty @uploads
      @metadata = original
    end
  end

  def test_invalid_contents_clean_up_downloads
    assert_raises(IMAGES::ImportError) { download('<html>sign in</html>') }
    assert @uploads.first.closed?
    refute File.exist?(@uploads.first.path.to_s)
  end

  def test_failure_on_later_image_cleans_up_earlier_download
    @event['files'] << { 'id' => 'F124' }
    Slackmine.stub(:slack_api, ->(_method, body, *_args, **_) {
      { 'file' => @metadata.merge('id' => body['file']) }
    }) do
      count = 0
      IMAGES.stub(:fetch, ->(*) {
        count += 1
        raise IOError, 'Network interrupted' if count == 2
        file = Tempfile.new('first-image'); file.binmode; file.write(PNG); file.rewind
        @uploads << file
        file
      }) { assert_raises(IOError) { IMAGES.download(@event, 'token') } }
    end
    assert @uploads.first.closed?
  end

  def test_total_size_limit_does_not_download_the_overflowing_image
    @event['files'] = (1..6).map { |index| { 'id' => "F#{index}" } }
    Setting.stub(:attachment_max_size, 10240) do
      Slackmine.stub(:slack_api, ->(_method, body, *_args, **_) {
        { 'file' => @metadata.merge('id' => body['file'], 'size' => IMAGES::MAX_BYTES) }
      }) do
        IMAGES.stub(:fetch, ->(*) {
          file = Tempfile.new('large-image'); file.binmode; file.write(PNG)
          file.truncate(IMAGES::MAX_BYTES); file.rewind; @uploads << file
          file
        }) { assert_raises(IMAGES::ImportError) { IMAGES.download(@event, 'token') } }
      end
    end
    assert_equal 5, @uploads.size
    assert @uploads.all?(&:closed?)
  end

  def test_reference_limit_and_invalid_ids_precede_api_access
    [Array.new(11) { { 'id' => 'F123' } }, [{ 'id' => '../secret' }], [{}], ['F123']].each do |files|
      @event['files'] = files
      assert_raises(IMAGES::ImportError) { download }
      assert_empty @calls
    end
  end

  def test_missing_scope_has_failure_feedback_result
    error = Slackmine::SlackApiError.new('files.info', 200, { 'error' => 'missing_scope' })
    Slackmine.stub(:slack_api, ->(*) { raise error }) do
      assert_raises(IMAGES::ImportError) { IMAGES.download(@event, 'token') }
    end
  end

  def test_download_does_not_send_token_to_redirects_or_arbitrary_hosts
    ['http://files.slack.com/files-pri/test', 'https://evil.example/files-pri/test',
     'https://files.slack.com:8443/files-pri/test', 'https://user@files.slack.com/files-pri/test',
     'https://files.slack.com/api/test'].each do |url|
      Net::HTTP.stub(:start, ->(*) { flunk 'Invalid URL must not start HTTP' }) do
        assert_raises(IMAGES::ImportError) { IMAGES.fetch(url, 'token', 20) }
      end
    end
    response = Net::HTTPFound.new('1.1', '302', 'Found')
    response['Location'] = 'https://evil.example/steal'
    http = Object.new
    http.define_singleton_method(:request) { |_request, &block| block.call(response) }
    Net::HTTP.stub(:start, ->(*_args, **_opts, &block) { block.call(http) }) do
      assert_raises(IMAGES::ImportError) { IMAGES.fetch(@metadata['url_private'], 'token', 20) }
    end
  end

  def test_streaming_limits_apply_even_without_content_length
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.define_singleton_method(:read_body) { |&block| block.call('abc'); block.call('def') }
    http = Object.new
    http.define_singleton_method(:request) do |request, &block|
      raise 'Missing auth' unless request['Authorization'] == 'Bearer token'
      block.call(response)
    end
    Net::HTTP.stub(:start, ->(*_args, **_opts, &block) { block.call(http) }) do
      assert_raises(IMAGES::ImportError) { IMAGES.fetch(@metadata['url_private'], 'token', 5) }
      file = IMAGES.fetch(@metadata['url_private'], 'token', 6)
      @uploads << file
      assert_equal 'abcdef', file.read
    end
  end

  def test_image_only_file_share_events_and_edited_events
    event = { 'type' => 'message', 'subtype' => 'file_share', 'user' => 'U123', 'channel' => 'C123',
              'ts' => '1000.000002', 'thread_ts' => '1000.000001', 'files' => [{ 'id' => 'F123' }] }
    assert Slackmine::ThreadComments.reply_event?(event)
    refute Slackmine::ThreadComments.reply_event?(event.merge('edited' => {}))
    refute Slackmine::ThreadComments.reply_event?(event.merge('ts' => event['thread_ts']))
    refute Slackmine::ThreadComments.reply_event?(event.merge('files' => [], 'text' => ''))
  end
end

class ThreadImageCommentsTest < ThreadCommentsUrlTest
  def setup
    super
    @event['files'] = [{ 'id' => 'F123' }]
    @issue.define_singleton_method(:attachments_addable?) { |_| true }
    @issue.attachments = []
    @upload = Tempfile.new('thread-image-test')
    @upload.write(ThreadFilesTest::PNG); @upload.rewind
    @attachment = OpenStruct.new(id: 55, filename: 'F123-screen@2x.png', content_type: 'image/png', valid?: true)
    @attachment.define_singleton_method(:save!) { true }
  end

  def teardown
    @upload.close! unless @upload.closed?
  end

  def persist(url = URL)
    attachment_factory = Object.new
    attachment_factory.define_singleton_method(:new) { |**_| @attachment }
    attachment_factory.instance_variable_set(:@attachment, @attachment)
    Object.const_set(:Attachment, attachment_factory)
    Slackmine::ThreadFiles.stub(:download, [@upload]) { super }
  ensure
    Object.send(:remove_const, :Attachment)
  end

  def test_saves_reply_url_with_original_author_and_timestamp
    assert_equal :saved, persist
    assert_equal URL + '?thread_ts=' + @event['thread_ts'] + "\n\n![](F123-screen@2x.png)", @journal.notes
    assert_equal [@attachment], @issue.attachments
    assert_equal 3, @journal.user_id
    assert @upload.closed?
  end

  def test_non_image_reply_uses_quoted_attachment_reference_in_both_formatters
    %w[markdown textile].each_with_index do |format, index|
      if index > 0
        teardown
        setup
      end
      @attachment.filename = 'F123-Transfer receipt.pdf'
      @attachment.content_type = 'application/pdf'
      Setting.stub(:text_formatting, format) do
        assert_equal :saved, persist
        assert_includes @journal.notes, 'attachment:"F123-Transfer receipt.pdf"'
        refute_includes @journal.notes, '/attachments/download/'
        refute_includes @journal.notes, '![]'
      end
    end
  end

  def test_attachment_permission_denies_before_downloading
    @issue.define_singleton_method(:attachments_addable?) { |_| false }
    assert_equal :restricted, persist
    assert_empty @calls
    refute @journal.persisted?
  end

  def test_textile_image_reference
    Setting.stub(:text_formatting, 'textile') do
      assert_equal :saved, persist
      assert_includes @journal.notes, '!F123-screen@2x.png!'
    end
  end
end
