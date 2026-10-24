# frozen_string_literal: true

# Run separately from the stub suite, with ActiveRecord and sqlite3 available.
# Only these in-memory fixture tables are created; no Redmine DB is accessed.
require 'logger'
require 'active_record'
require 'sqlite3'
require 'minitest/autorun'
require 'ostruct'
require_relative 'quote_signing_support'

module Rails
  def self.application
    OpenStruct.new(config: OpenStruct.new(to_prepare: nil, after_initialize: nil), key_generator: QuoteTestKeyGenerator.new)
  end

  def self.logger
    @logger ||= Logger.new(File::NULL)
  end
end

module Setting
  def self.protocol; 'https'; end
  def self.host_name; 'redmine.example.com'; end
  def self.text_formatting; 'markdown'; end
end

class Project < OpenStruct
  def self.find_by(**); nil; end
  def self.active; []; end
end

class User < ActiveRecord::Base
  def active?; status == 1; end
  has_many :email_addresses
  scope :active, -> { where(status: 1) }
  class << self
    attr_accessor :current
  end
end

require_relative '../lib/slackmine'
Slackmine.instance_variable_set(:@config, {})
Slackmine.instance_variable_set(:@messages_config, {})

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:users) { |t| t.string :login; t.integer :status; t.string :mail }
  create_table(:email_addresses) { |t| t.integer :user_id; t.string :address }
  create_table(:issues) { |t| t.string :subject }
  create_table(:journals) do |t|
    t.integer :issue_id
    t.integer :user_id
    t.text :notes
    t.datetime :created_on, precision: 6
    t.datetime :updated_on, precision: 6
  end
  create_table(:attachments) do |t|
    t.integer :issue_id
    t.integer :author_id
    t.string :content_type
    t.string :filename
    t.binary :content
  end
end

class EmailAddress < ActiveRecord::Base
end

class Issue < ActiveRecord::Base
  has_many :journals
  has_many :attachments
  attr_accessor :project, :private_issue, :can_view, :can_comment, :pending_journal
  after_save do
    if pending_journal
      pending_journal.save!
      self.pending_journal = nil
    end
  end

  def is_private?; !!private_issue; end
  def visible?(_viewer); can_view; end
  def notes_addable?(_viewer); can_comment; end
  def attachments_addable?(_viewer); can_comment; end
  def init_journal(viewer, notes); self.pending_journal = journals.build(user_id: viewer.id, notes: notes); end
end

# Minimal real-DB attachment fixture: the production Redmine Attachment model
# owns disk storage, filename/extension validation and rollback cleanup.
class Attachment < ActiveRecord::Base
  validates_presence_of :filename, :content
  def file=(upload)
    self.filename = upload.original_filename
    self.content_type = upload.content_type
    self.content = upload.read
    upload.rewind
  end
  def author=(viewer); self.author_id = viewer.id; end
end

class Journal < ActiveRecord::Base
  belongs_to :issue
  include Slackmine::JournalPatch
  def journalized; issue; end
  def private_notes?; false; end
end

class ThreadCommentsPersistenceTest < Minitest::Test
  COMMENTS = Slackmine::ThreadComments

  def setup
    EmailAddress.delete_all
    User.delete_all
    Journal.delete_all
    Attachment.delete_all
    Issue.delete_all
    @project = Project.new(identifier: 'agentic', active?: true)
    @issue = Issue.create!(subject: 'Thread target')
    @issue.project = @project
    @issue.can_view = @issue.can_comment = true
    @viewer = OpenStruct.new(id: 3, logged?: true)
    @previous_user = OpenStruct.new(id: 99)
    User.current = @previous_user
    @event = { 'type' => 'message', 'user' => 'U123', 'channel' => 'C123', 'text' => 'Reply from Slack',
               'thread_ts' => '1791001000.000001', 'ts' => '1791001000.000002' }
    # These tests exercise notification-thread replies; explicit connection
    # routing has its own suite and otherwise defaults to enabled.
    @settings = { 'slack' => { 'thread_comments' => true, 'thread_connections' => false, 'thread_comment_batch' => { 'wait_seconds' => 0 }, 'bot_token' => 'test-token',
                              'default_channel_id' => 'C123', 'events' => {
                                'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'test-secret' } } }
    @parent = { 'ts' => @event['thread_ts'], 'bot_id' => 'B123', 'app_id' => 'ATEST', 'attachments' => [
      { 'blocks' => [{ 'text' => { 'text' => 'Issue updated' } },
                    { 'text' => { 'text' => "*<https://redmine.example.com/issues/#{@issue.id}|Issue>*" } }] }
    ] }
  end

  def reply_url(timestamp)
    "https://example.slack.com/archives/C123/p#{timestamp.delete('.')}"
  end

  def persist(events: nil)
    Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
      Slackmine.stub(:config, @settings) do
        Slackmine.stub(:enqueue, ->(*) { flunk 'Comment notification loop' }) do
          Slackmine.stub(:slack_api, ->(method, body, *_args, **_options) {
            raise "Unexpected API: #{method}" unless method == 'chat.getPermalink'
            { 'permalink' => reply_url(body['message_ts']) }
          }) do
            # Card acquisition is tested separately from persistence.
            Slackmine::LinkQuotes.stub(:import, ->(text, *) { text }) do
              if events
                COMMENTS.persist_reply(@issue, events.first, 'TTEST', events: events)
              else
                COMMENTS.persist_reply(@issue, @event, 'TTEST')
              end
            end
          end
        end
      end
    end
  end

  def test_author_identity_duplicate_suppression_and_context_restoration
    assert_equal :saved, persist
    assert_equal 1, Journal.count
    assert_equal 3, Journal.first.user_id
    assert_equal reply_url(@event['ts']) + '?thread_ts=' + @event['thread_ts'], Journal.first.notes
    assert_equal :duplicate, persist
    assert_equal 1, Journal.count
    assert_same @previous_user, User.current
    assert_nil Thread.current[:slackmine_thread_comment]
    @event['ts'] = '1791001000.000003'
    assert_equal :saved, persist
    assert_equal 2, Journal.count
  end

  def test_batch_preserves_each_source_and_is_saved_only_once
    events = [@event, @event.merge('ts' => '1791001000.000003', 'text' => 'Second message')]
    assert_equal :saved, persist(events: events)
    assert_equal 1, Journal.count
    events.each { |event| assert_includes Journal.first.notes, reply_url(event['ts']) }
    assert_equal :duplicate, persist(events: events)
    assert_equal 1, Journal.count
    assert_nil Thread.current[:slackmine_thread_comment]
  end

  def test_reverse_job_completion_keeps_a_a_b_a_in_source_time_order
    first = [@event.merge('text' => 'A first'), @event.merge('ts' => '1791001000.000003', 'text' => 'A second')]
    middle = [@event.merge('user' => 'U456', 'ts' => '1791001000.000004', 'text' => 'B turn')]
    last = [@event.merge('ts' => '1791001000.000005', 'text' => 'A last')]
    # All turns occur in the same second. Preserve Slack's microseconds,
    # even if workers complete them in exactly the opposite order.
    @viewer = OpenStruct.new(id: 3, logged?: true)
    assert_equal :saved, persist(events: last)
    @viewer = OpenStruct.new(id: 4, logged?: true)
    assert_equal :saved, persist(events: middle)
    @viewer = OpenStruct.new(id: 3, logged?: true)
    assert_equal :saved, persist(events: first)
    assert_equal [3, 4, 3], Journal.order(:id).pluck(:user_id)
    history = Journal.order(:created_on, :id).to_a
    assert_equal [first.first, middle.first, last.first].map { |event| COMMENTS.posted_at(event['ts']) }, history.map(&:created_on)
    assert_includes history[0].notes, reply_url(first[0]['ts'])
    assert_includes history[0].notes, reply_url(first[1]['ts'])
    assert_includes history[1].notes, reply_url(middle[0]['ts'])
    assert_includes history[2].notes, reply_url(last[0]['ts'])
    assert_equal :duplicate, persist(events: first)
    assert_equal 3, Journal.count
  end

  def test_batch_combines_files_and_binds_them_to_their_own_source
    events = [@event.merge('files' => [{ 'id' => 'F123' }]),
              @event.merge('ts' => '1791001000.000003', 'files' => [{ 'id' => 'F456' }])]
    files = [image_upload('F123-screen.png'), image_upload('F456-other.png')]
    captured = nil
    Slackmine::ThreadFiles.stub(:download, ->(event, *) {
      assert_equal [{ 'id' => 'F123' }, { 'id' => 'F456' }], event['files']
      files
    }) do
      # persist normally stubs the quote importer; inspect the maps at save time instead.
      @issue.define_singleton_method(:save!) do
        captured_maps = Thread.current[:slackmine_thread_images]
        @captured_batch_maps = captured_maps
        super()
      end
      assert_equal :saved, persist(events: events)
      captured = @issue.instance_variable_get(:@captured_batch_maps)
    end
    assert_equal 2, Attachment.count
    assert_equal 1, Journal.count
    assert_equal 2, captured.size
    assert_equal [Attachment.find_by(filename: 'F123-screen.png').id], captured[0][:ids]
    assert_equal [Attachment.find_by(filename: 'F456-other.png').id], captured[1][:ids]
    assert_includes captured[0][:url], events[0]['ts'].delete('.')
    assert_includes captured[1][:url], events[1]['ts'].delete('.')
    assert_nil Thread.current[:slackmine_thread_images]
  end

  def image_upload(name = 'F123-screen.png')
    file = Tempfile.new('thread-image-db-test')
    file.binmode
    file.write("\x89PNG\r\n\x1a\nimage".b)
    file.rewind
    file.define_singleton_method(:original_filename) { name }
    file.define_singleton_method(:content_type) { 'image/png' }
    file
  end

  def test_image_only_reply_persists_attachment_and_inline_reference_once
    @event['text'] = ''
    @event['subtype'] = 'file_share'
    @event['files'] = [{ 'id' => 'F123' }]
    file = image_upload
    assert COMMENTS.reply_event?(@event)
    Slackmine::ThreadFiles.stub(:download, [file]) { assert_equal :saved, persist }
    assert_equal 1, Attachment.count
    assert_equal @issue.id, Attachment.first.issue_id
    assert_equal 3, Attachment.first.author_id
    assert_includes Journal.first.notes, "![](#{Attachment.first.filename})"
    assert file.closed?
    Slackmine::ThreadFiles.stub(:download, ->(*) { flunk 'Duplicate downloaded images' }) do
      assert_equal :duplicate, persist
    end
    assert_equal 1, Journal.count
    assert_equal 1, Attachment.count
  ensure
    file.close! if file && !file.closed?
  end

  def test_restrict_transfer_saves_file_only_reply_url_without_attachment_permission_or_download
    @settings['slack']['files'] = { 'restrict_transfer' => true }
    @event.merge!('text' => '', 'subtype' => 'file_share', 'files' => [{ 'id' => 'F123' }])
    @issue.define_singleton_method(:attachments_addable?) { |_| false }
    Slackmine::ThreadFiles.stub(:download, ->(*) { flunk 'Link-only downloaded files' }) do
      assert_equal :saved, persist
      assert_equal :duplicate, persist
    end
    assert_equal 0, Attachment.count
    assert_equal 1, Journal.count
    assert_equal reply_url(@event['ts']) + '?thread_ts=' + @event['thread_ts'], Journal.first.notes
    assert_nil Thread.current[:slackmine_thread_files]
    assert_nil Thread.current[:slackmine_thread_images]
  end

  def test_restrict_transfer_batch_keeps_every_message_url_without_downloading_mixed_files
    @settings['slack']['files'] = { 'restrict_transfer' => true }
    events = [@event.merge('files' => [{ 'id' => 'F123' }]),
              @event.merge('ts' => '1791001000.000003', 'text' => '', 'files' => [{ 'id' => 'F456' }])]
    Slackmine::ThreadFiles.stub(:download, ->(*) { flunk 'Link-only downloaded a batch' }) do
      assert_equal :saved, persist(events: events)
    end
    assert_equal 0, Attachment.count
    assert_equal 1, Journal.count
    events.each { |event| assert_includes Journal.first.notes, reply_url(event['ts']) }
  end

  def test_project_can_enable_restrict_transfer_without_global_restriction
    @settings['projects'] = { 'agentic' => { 'slack' => { 'files' => { 'restrict_transfer' => true } } } }
    @event['files'] = [{ 'id' => 'F123' }]
    Slackmine::ThreadFiles.stub(:download, ->(*) { flunk 'Project restriction downloaded files' }) do
      assert_equal :saved, persist
    end
    assert_equal 0, Attachment.count
    assert_includes Journal.first.notes, reply_url(@event['ts'])
  end

  def test_project_can_allow_transfers_under_global_restrict_transfer_setting
    @settings['slack']['files'] = { 'restrict_transfer' => true }
    @settings['projects'] = { 'agentic' => { 'slack' => { 'files' => { 'restrict_transfer' => false } } } }
    @event['files'] = [{ 'id' => 'F123' }]
    file = image_upload
    Slackmine::ThreadFiles.stub(:download, ->(*) {
      refute Slackmine.files_transfer_restricted?
      [file]
    }) { assert_equal :saved, persist }
    assert_equal 1, Attachment.count
    assert_includes Journal.first.notes, '![](F123-screen.png)'
  ensure
    file.close! if file && !file.closed?
  end

  def test_global_force_saves_only_source_url_even_with_project_exception
    @settings['slack']['files'] = { 'restrict_transfer' => false, 'force_restrict_transfer' => true }
    @settings['projects'] = { 'agentic' => { 'slack' => { 'files' => {
      'restrict_transfer' => false, 'force_restrict_transfer' => false } } } }
    @event.merge!('text' => '', 'files' => [{ 'id' => 'F123' }])
    @issue.define_singleton_method(:attachments_addable?) { |_| false }
    Slackmine::ThreadFiles.stub(:download, ->(*) { flunk 'Forced restriction downloaded files' }) do
      assert_equal :saved, persist
    end
    assert_equal 0, Attachment.count
    assert_equal 1, Journal.count
    assert_equal reply_url(@event['ts']) + '?thread_ts=' + @event['thread_ts'], Journal.first.notes
  end

  def test_mixed_pdf_and_image_reply_persists_both_and_duplicate_does_not_download
    @event['files'] = [{ 'id' => 'F123' }, { 'id' => 'F124' }]
    files = [image_upload, image_upload('F124-report.pdf')]
    files.last.define_singleton_method(:content_type) { 'application/pdf' }
    Slackmine::ThreadFiles.stub(:download, files) { assert_equal :saved, persist }
    assert_equal 2, Attachment.count
    assert_includes Journal.first.notes, "![](#{Attachment.first.filename})"
    assert_includes Journal.first.notes, 'attachment:"F124-report.pdf"'
    Slackmine::ThreadFiles.stub(:download, ->(*) { flunk 'Duplicate downloaded files' }) { assert_equal :duplicate, persist }
    assert_equal 1, Journal.count
    assert_equal 2, Attachment.count
    assert files.all?(&:closed?)
    assert_nil Thread.current[:slackmine_thread_files]
  ensure
    files.each { |file| file.close! unless file.closed? } if files
  end

  def test_image_failure_after_attachment_save_rolls_back_every_record
    @event['files'] = [{ 'id' => 'F123' }]
    file = image_upload
    original_save = @issue.method(:save!)
    Slackmine::ThreadFiles.stub(:download, [file]) do
      @issue.stub(:save!, -> { original_save.call; raise IOError, 'simulated crash' }) do
        assert_raises(IOError) { persist }
      end
    end
    assert_equal 0, Journal.count
    assert_equal 0, Attachment.count
    assert file.closed?
    assert_same @previous_user, User.current
    # A fresh model, as on a Sidekiq retry, can save both records successfully.
    @issue.reload
    file = image_upload
    Slackmine::ThreadFiles.stub(:download, [file]) { assert_equal :saved, persist }
    assert_equal 1, Journal.count
    assert_equal 1, Attachment.count
  ensure
    file.close! if file && !file.closed?
  end

  def test_invalid_attachment_rejects_all_images_and_comment
    @event['files'] = [{ 'id' => 'F123' }, { 'id' => 'F124' }]
    files = [image_upload, image_upload('')]
    Slackmine::ThreadFiles.stub(:download, files) { assert_equal :restricted, persist }
    assert_equal 0, Attachment.count
    assert_equal 0, Journal.count
    assert files.all?(&:closed?)
  ensure
    files.each { |file| file.close! unless file.closed? } if files
  end

  def test_restricted_users_private_issues_and_long_text_never_save
    @issue.can_comment = false
    assert_equal :restricted, persist
    @issue.can_comment = true
    @issue.can_view = false
    assert_equal :restricted, persist
    @issue.can_view = true
    @issue.private_issue = true
    assert_equal :restricted, persist
    @issue.private_issue = false
    @event['text'] = 'x' * 10_001
    assert_equal :restricted, persist
    assert_equal 0, Journal.count
    assert_same @previous_user, User.current
  end

  def test_validation_failure_does_not_save_and_restores_user
    @issue.define_singleton_method(:save!) { raise ActiveRecord::RecordInvalid.new(self) }
    assert_equal :restricted, persist
    assert_equal 0, Journal.count
    assert_same @previous_user, User.current
    assert_nil Thread.current[:slackmine_thread_comment]
  end

  def test_parent_identity_exact_timestamp_host_and_subject_position_are_required
    assert_equal @issue, COMMENTS.issue_from_parent(@parent, 'ATEST', @event['thread_ts'])
    assert_nil COMMENTS.issue_from_parent(@parent, 'AOTHER', @event['thread_ts'])
    assert_nil COMMENTS.issue_from_parent(@parent, 'ATEST', '1791001000.999999')
    @parent.delete('bot_id')
    assert_nil COMMENTS.issue_from_parent(@parent, 'ATEST', @event['thread_ts'])
    @parent['bot_id'] = 'B123'
    @parent['attachments'][0]['blocks'][1]['text']['text'] = '*<https://evil.example/issues/1|Issue>*'
    assert_nil COMMENTS.issue_from_parent(@parent, 'ATEST', @event['thread_ts'])
  end

  def test_message_edits_bots_and_root_posts_are_ignored
    assert COMMENTS.reply_event?(@event)
    [{ 'bot_id' => 'B123' }, { 'subtype' => 'message_changed' },
     { 'ts' => @event['thread_ts'] }, { 'edited' => {} }, { 'text' => '' }].each do |override|
      refute COMMENTS.reply_event?(@event.merge(override))
    end
  end

  def test_disabled_feature_and_unmapped_viewer_do_not_save
    @settings['slack']['thread_comments'] = false
    assert_equal :restricted, persist
    @settings['slack']['thread_comments'] = true
    @viewer = nil
    assert_equal :restricted, persist
    assert_equal 0, Journal.count
  end

  def test_original_microsecond_timestamp_is_preserved_and_survives_comment_edits
    @event['ts'] = '1791028111.695359'
    assert_equal :saved, persist
    assert_equal Time.at(1791028111, 695359, :microsecond).utc, Journal.first.created_on
    assert_equal Journal.first.created_on, Journal.first.updated_on
    journal = Journal.first
    # Exercise ActiveRecord's edit timestamps without formatting an unrelated
    # outbound Slack notification in this minimal database fixture.
    journal.stub(:notify_slack_journal_comment_changed, nil) { journal.update!(notes: 'Edited text') }
    refute_equal Journal.first.created_on, Journal.first.updated_on
    assert_equal :duplicate, persist
    assert_equal 1, Journal.count
  end

  def test_failure_after_journal_save_rolls_back_and_can_be_retried
    original_save = @issue.method(:save!)
    @issue.stub(:save!, -> { original_save.call; raise IOError, 'simulated crash' }) do
      assert_raises(IOError) { persist }
    end
    assert_equal 0, Journal.count
    assert_same @previous_user, User.current
    assert_nil Thread.current[:slackmine_thread_comment]
    assert_equal :saved, persist
    assert_equal 1, Journal.count
  end

  def test_invalid_timestamp_does_not_save
    ['broken', '1791001000.0000001', '1000', '-1791001000.000001'].each do |timestamp|
      @event['ts'] = timestamp
      refute COMMENTS.reply_event?(@event)
      assert_equal :restricted, persist
    end
    assert_equal 0, Journal.count
  end

  def test_same_timestamp_from_a_different_author_is_a_separate_comment
    assert_equal :saved, persist
    @viewer = OpenStruct.new(id: 4)
    assert_equal :saved, persist
    assert_equal [3, 4], Journal.order(:id).pluck(:user_id)
  end

  def test_legacy_marker_comments_are_still_recognized_as_duplicates
    Journal.insert_all!([{ issue_id: @issue.id, user_id: 3,
                          notes: "Legacy\n\n#{COMMENTS.source_marker('TTEST', @event)}" }])
    assert_equal :duplicate, persist
    assert_equal 1, Journal.count
  end

  def test_configured_app_team_and_channel_are_required_before_history_access
    Slackmine.stub(:config, @settings) do
      assert COMMENTS.accepted_reply?('ATEST', 'TTEST', @event)
      refute COMMENTS.accepted_reply?('AOTHER', 'TTEST', @event)
      refute COMMENTS.accepted_reply?('ATEST', 'TOTHER', @event)
      refute COMMENTS.accepted_reply?('ATEST', 'TTEST', @event.merge('channel' => 'COTHER'))
      @settings['slack']['thread_comments'] = false
      Slackmine.stub(:slack_api, ->(*) { flunk 'History should not be fetched' }) do
        assert_nil COMMENTS.process('ATEST', 'TTEST', @event)
      end
    end
  end

  def test_automatic_channel_projects_accept_replies_without_project_yaml_entries
    @settings['slack']['auto_map_channels_by_name'] = true
    Slackmine.stub(:config, @settings) do
      Project.stub(:active, [@project]) do
        Slackmine::ChannelMatching.stub(:channel_for, 'C123') do
          assert_includes COMMENTS.contexts('ATEST', 'TTEST', 'C123'), @project
          assert COMMENTS.accepted_reply?('ATEST', 'TTEST', @event)
        end
      end
    end
  end

  def email_viewer(member = {})
    profile = { 'id' => 'U123', 'team_id' => 'TTEST', 'profile' => { 'email' => 'ALICE@EXAMPLE.COM' } }.merge(member)
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*) { { 'user' => profile } }) do
        Slackmine::WorkObjects.viewer_for('U123')
      end
    end
  end

  def create_email_user(login: 'alice', status: 1)
    user = User.create!(login: login, status: status, mail: 'alice@example.com')
    user.email_addresses.create!(address: 'alice@example.com')
    user
  end

  def test_email_matching_is_opt_in_and_requires_unique_active_user
    user = create_email_user
    assert_nil email_viewer
    @settings['slack']['auto_map_users_by_email'] = true
    assert_equal user, email_viewer
    create_email_user(login: 'duplicate')
    assert_nil email_viewer
    User.where(login: 'duplicate').update_all(status: 3)
    assert_equal user, email_viewer
    user.update!(status: 3)
    assert_nil email_viewer
  end

  def test_email_matching_rejects_foreign_bot_deleted_and_missing_email_identities
    create_email_user
    @settings['slack']['auto_map_users_by_email'] = true
    [{ 'id' => 'UOTHER' }, { 'team_id' => 'TOTHER' }, { 'is_bot' => true },
     { 'is_app_user' => true }, { 'deleted' => true }, { 'is_stranger' => true },
     { 'profile' => {} }].each { |member| assert_nil email_viewer(member) }
  end

  def test_explicit_user_mapping_wins_even_when_invalid_or_locked
    user = create_email_user
    @settings['slack']['auto_map_users_by_email'] = true
    @settings['users'] = { 'alice' => 'UOTHER' }
    assert_nil email_viewer
    @settings['users'] = { 'alice' => 'U123' }
    assert_equal user, email_viewer
    user.update!(status: 3)
    assert_nil email_viewer
    @settings['users'] = { 'missing-user' => 'U123' }
    assert_nil email_viewer
  end

  def test_email_api_failure_denies_access_without_saving
    @settings['slack']['auto_map_users_by_email'] = true
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*) { raise IOError, 'Unavailable' }) do
        assert_nil Slackmine::WorkObjects.viewer_for('U123')
      end
    end
    assert_equal 0, Journal.count
  end

  def test_processing_fetches_only_parent_and_does_not_post_feedback_twice
    cleanups = []
    @settings['messages'] = { 'work_objects' => { 'product_name' => 'Example Tracker' },
                              'thread_comments' => { 'saved' => '✅ Added a comment to %{product_name} #%{id}.' } }
    calls = []
    api = ->(method, body, token, **_options) do
      calls << [method, body, token]
      case method
      when 'conversations.history' then { 'messages' => [@parent] }
      when 'chat.getPermalink' then { 'permalink' => reply_url(body['message_ts']) }
      else { 'ts' => '1791001000.000004' }
      end
    end
    Slackmine.stub(:config, @settings) do
      Issue.stub(:find_by, @issue) do
        Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
          Slackmine.stub(:slack_api, api) do
            Slackmine::LinkQuotes.stub(:import, ->(text, *) { text }) do
              COMMENTS.stub(:schedule_feedback_cleanup, ->(*args) { cleanups << args }) do
                2.times { COMMENTS.process('ATEST', 'TTEST', @event) }
              end
            end
          end
        end
      end
    end
    assert_equal 1, Journal.count
    assert_equal 1, calls.count { |call| call[0] == 'chat.postMessage' }
    assert_equal [[@issue.project, @event, { 'ts' => '1791001000.000004' }]], cleanups
    feedback = calls.find { |call| call[0] == 'chat.postMessage' }
    assert_equal "✅ Added a comment to Example Tracker <https://redmine.example.com/issues/#{@issue.id}|##{@issue.id}>.", feedback[1]['text']
    history = calls.first[1]
    assert_equal @event['thread_ts'], history['oldest']
    assert_equal @event['thread_ts'], history['latest']
    assert_equal 1, history['limit']
    assert_equal true, history['inclusive']
  end
end
