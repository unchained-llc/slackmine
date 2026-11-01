# frozen_string_literal: true
require_relative 'image_notification_test'
require_relative '../app/jobs/slackmine_thread_comment_feedback_cleanup_job'

class ThreadCommentFeedbackCleanupTest < Minitest::Test
  COMMENTS = Slackmine::ThreadComments
  JOB = SlackmineThreadCommentFeedbackCleanupJob

  def setup
    @project = OpenStruct.new(id: 42, identifier: 'example')
    @issue = OpenStruct.new(id: 7, project: @project)
    @event = { 'channel' => 'C123', 'thread_ts' => '1000.000001', 'ts' => '1001.000002' }
    @settings = { 'slack' => { 'bot_token' => 'test-token', 'thread_comment_feedback_cleanup_seconds' => 60 } }
    @response = { 'ok' => true, 'channel' => 'C123', 'ts' => '1002.000003' }
    @calls = []
    @jobs = []
    @waits = []
  end

  def feedback(result = :saved)
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*args) { @calls << args; @response }) do
        JOB.stub(:set, ->(wait:) { @waits << wait; JOB }) do
          JOB.stub(:perform_later, ->(*args) { @jobs << args }) { COMMENTS.feedback(@issue, @event, result) }
        end
      end
    end
  end

  def test_enabled_cleanup_schedules_only_the_bots_feedback_for_all_results
    %i[saved restricted image_failed].each { |result| feedback(result) }
    assert_equal [60, 60, 60], @waits
    assert_equal [[42, 'C123', '1002.000003', 'comment']] * 3, @jobs
    assert_equal ['chat.postMessage'] * 3, @calls.map(&:first)
    @calls.each do |_, body, token|
      assert_equal @event['thread_ts'], body['thread_ts']
      assert_equal 'test-token', token
    end
  end

  def test_minus_one_keeps_feedback_without_scheduling
    @settings['slack']['thread_comment_feedback_cleanup_seconds'] = -1
    feedback
    assert_equal 1, @calls.size
    assert_empty @jobs
    assert_empty @waits
  end

  def test_omitted_setting_keeps_feedback_without_scheduling
    @settings['slack'].delete('thread_comment_feedback_cleanup_seconds')
    feedback
    assert_equal 1, @calls.size
    assert_empty @jobs
    assert_empty @waits
  end

  def test_zero_suppresses_all_feedback_without_posting_or_scheduling
    @settings['slack']['thread_comment_feedback_cleanup_seconds'] = 0
    %i[saved restricted image_failed].each { |result| feedback(result) }
    assert_empty @calls
    assert_empty @jobs
    assert_empty @waits
  end

  def test_custom_delay_and_project_override
    @settings['slack']['thread_comment_feedback_cleanup_seconds'] = 120
    feedback
    @settings['projects'] = { 'example' => { 'slack' => { 'thread_comment_feedback_cleanup_seconds' => 0 } } }
    feedback
    assert_equal [120], @waits
    assert_equal 1, @calls.size
    @settings['projects']['example']['slack']['thread_comment_feedback_cleanup_seconds'] = -1
    feedback
    assert_equal 1, @jobs.size
    assert_equal 2, @calls.size
  end

  def test_connection_feedback_uses_its_own_cleanup_setting
    @settings['slack']['thread_connection_feedback_cleanup_seconds'] = 5
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*args) { @calls << args; @response }) do
        JOB.stub(:set, ->(wait:) { @waits << wait; JOB }) do
          JOB.stub(:perform_later, ->(*args) { @jobs << args }) do
            Slackmine::ThreadFeedback.post(@project, 'C123', @event['thread_ts'], 'connected', 'connection')
            @settings['slack']['thread_connection_feedback_cleanup_seconds'] = 0
            Slackmine::ThreadFeedback.post(@project, 'C123', @event['thread_ts'], 'connected', 'connection')
          end
        end
      end
    end
    assert_equal [5], @waits
    assert_equal [[42, 'C123', '1002.000003', 'connection']], @jobs
    assert_equal 1, @calls.size
  end

  def test_connection_feedback_defaults_to_kept
    Slackmine.stub(:config, @settings) { assert_equal(-1, Slackmine::ThreadFeedback.cleanup_seconds(@project, 'connection')) }
  end

  def test_connection_cleanup_respects_its_current_project_setting
    @settings['projects'] = { 'example' => { 'slack' => { 'thread_connection_feedback_cleanup_seconds' => -1 } } }
    Slackmine.stub(:config, @settings) do
      Project.stub(:find_by, @project) do
        Slackmine.stub(:slack_api, ->(*args) { @calls << args }) do
          JOB.new.perform(42, 'C123', '1002.000003', 'connection')
          assert_empty @calls
          @settings['projects']['example']['slack']['thread_connection_feedback_cleanup_seconds'] = 5
          JOB.new.perform(42, 'C123', '1002.000003', 'connection')
        end
      end
    end
    assert_equal ['chat.delete'], @calls.map(&:first)
  end

  def test_inline_adapter_leaves_feedback_if_delayed_jobs_are_unavailable
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, @response) do
        JOB.stub(:set, ->(*) { raise NotImplementedError }) { COMMENTS.feedback(@issue, @event, :saved) }
      end
    end
  end

  def test_invalid_settings_disable_cleanup
    [nil, '60', false, {}, -2, Float::NAN, Float::INFINITY].each do |value|
      @settings['slack']['thread_comment_feedback_cleanup_seconds'] = value
      Slackmine.stub(:config, @settings) { assert_equal(-1, Slackmine::ThreadFeedback.cleanup_seconds(@project, 'comment')) }
    end
  end

  def test_missing_or_unsafe_timestamp_never_schedules_deletion
    [nil, '', 'bad', @event['thread_ts'], @event['ts']].each do |timestamp|
      @response['ts'] = timestamp
      feedback
    end
    assert_empty @jobs
  end

  def test_posting_or_enqueue_failure_does_not_escape_feedback
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*) { raise IOError, 'unavailable' }) do
        JOB.stub(:set, ->(*) { flunk 'Failed post scheduled deletion' }) { COMMENTS.feedback(@issue, @event, :saved) }
      end
      Slackmine.stub(:slack_api, @response) do
        JOB.stub(:set, ->(*) { raise IOError, 'queue unavailable' }) { COMMENTS.feedback(@issue, @event, :saved) }
      end
    end
  end

  def perform(project = @project)
    Slackmine.stub(:config, @settings) do
      Project.stub(:find_by, ->(id:) { assert_equal 42, id; project }) do
        JOB.new.perform(42, 'C123', '1002.000003')
      end
    end
  end

  def test_job_uses_current_project_token_and_deletes_only_feedback
    @settings['projects'] = { 'example' => { 'slack' => { 'bot_token' => 'project-token' } } }
    Slackmine.stub(:slack_api, ->(*args) { @calls << args }) { perform }
    assert_equal [['chat.delete', { 'channel' => 'C123', 'ts' => '1002.000003' }, 'project-token']], @calls
  end

  def test_missing_project_disabled_cleanup_or_missing_token_skips_deletion
    Slackmine.stub(:slack_api, ->(*) { flunk 'Unexpected deletion' }) do
      perform(nil)
      @settings['slack']['thread_comment_feedback_cleanup_seconds'] = -1
      perform
      @settings['slack']['thread_comment_feedback_cleanup_seconds'] = 60
      Slackmine.stub(:bot_token, '') { perform }
    end
  end

  def test_already_deleted_is_success_but_other_errors_retry
    missing = Slackmine::SlackApiError.new('chat.delete', '200', { 'error' => 'message_not_found' })
    Slackmine.stub(:slack_api, ->(*) { raise missing }) { perform }
    failure = Slackmine::SlackApiError.new('chat.delete', '429', { 'error' => 'ratelimited' })
    Slackmine.stub(:slack_api, ->(*) { raise failure }) do
      assert_raises(Slackmine::SlackApiError) { perform }
    end
    Slackmine.stub(:slack_api, ->(*) { raise IOError }) { assert_raises(IOError) { perform } }
  end
end
