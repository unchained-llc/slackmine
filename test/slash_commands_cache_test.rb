# frozen_string_literal: true
require_relative 'slash_commands_test'
require_relative '../app/jobs/slackmine_command_form_job'

module Rails
  def self.cache; nil; end unless respond_to?(:cache)
end

class SlashCommandsCacheTest < Minitest::Test
  COMMANDS = Slackmine::SlashCommands
  class Cache
    def initialize; @data = {}; end
    def read(key); @data[key]; end
    def write(key, value, unless_exist: false, expires_in:)
      return false if unless_exist && @data.key?(key)
      @data[key] = value
      true
    end
    def delete(key); @data.delete(key); end
  end

  def setup
    @cache = Cache.new
    @viewer = OpenStruct.new(id: 123)
    @payload = { 'type' => 'view_submission', 'user' => { 'id' => 'U123' }, 'view' => {
      'id' => 'V123', 'callback_id' => 'slackmine_command_create', 'private_metadata' => '1',
      'state' => { 'values' => {} } } }
  end

  def submit(&save)
    Rails.stub(:cache, @cache) do
      COMMANDS.stub(:enabled?, true) do
        COMMANDS.stub(:integration?, true) do
          Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
            COMMANDS.stub(:save_form, save) { COMMANDS.interaction('ATEST', 'TTEST', @payload) }
          end
        end
      end
    end
  end

  def test_successful_submission_is_not_repeated
    count = 0
    previous = User.current
    2.times { assert_equal({}, submit { |*| count += 1; {} }) }
    assert_equal 1, count
    assert_same previous, User.current
  end

  def test_validation_error_allows_correction
    assert_equal 'errors', submit { |*| { 'response_action' => 'errors' } }['response_action']
    count = 0
    assert_equal({}, submit { |*| count += 1; {} })
    assert_equal 1, count
  end

  def test_uncertain_failure_does_not_immediately_repeat_write
    assert_raises(RuntimeError) { submit { |*| raise 'Uncertain outcome' } }
    count = 0
    result = submit { |*| count += 1; {} }
    assert_equal 'errors', result['response_action']
    assert_equal 0, count
  end

  def test_slack_link_creation_acknowledges_then_saves_once_in_job
    @payload['view']['state']['values'] = {
      'subject' => { 'subject' => { 'value' => 'Example' } },
      'description' => { 'description' => { 'value' => 'https://example.slack.com/archives/C123/p123' } },
      'tracker' => { 'tracker' => { 'selected_option' => { 'value' => '1' } } }
    }
    queued = []
    SlackmineCommandFormJob.stub(:perform_later, ->(*args) { queued << args; Object.new }) do
      COMMANDS.stub(:background_form_allowed?, true) do
        assert_equal({}, submit { |*| flunk 'Save must wait for worker' })
      end
    end
    assert_equal 1, queued.length
    assert_equal %w[subject description tracker], queued.first[5].keys
    assert_equal 'pending', @cache.read(@cache.instance_variable_get(:@data).keys.first)
    calls = 0
    Rails.stub(:cache, @cache) do
      COMMANDS.stub(:enabled?, true) do
        COMMANDS.stub(:integration?, true) do
          Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
            COMMANDS.stub(:save_form, ->(*) { calls += 1; {} }) do
              Slackmine.stub(:slack_api, ->(*) { flunk 'Successful saves must not send a DM' }) do
                SlackmineCommandFormJob.new.perform(*queued.first)
                SlackmineCommandFormJob.new.perform(*queued.first)
              end
            end
          end
        end
      end
    end
    assert_equal 1, calls
  end

  def test_background_form_validation_failure_reports_to_user_and_releases_claim
    values = { 'description' => { 'description' => { 'value' => 'https://example.slack.com/archives/C123/p123' } } }
    key = "slackmine:submission:#{Digest::SHA256.hexdigest(['ATEST', 'TTEST', @viewer.id, 'V123'].join(':'))}"
    @cache.write(key, 'pending', expires_in: 86_400)
    sent = []
    Rails.stub(:cache, @cache) do
      COMMANDS.stub(:enabled?, true) do
        COMMANDS.stub(:integration?, true) do
          Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
            COMMANDS.stub(:save_form, ->(*) { { 'response_action' => 'errors' } }) do
              Slackmine.stub(:slack_api, ->(*args) { sent << args }) do
                COMMANDS.complete_form('ATEST', 'TTEST', 'U123', 'create', '1', values, @viewer.id, 'V123')
              end
            end
          end
        end
      end
    end
    assert_nil @cache.read(key)
    assert_equal 'chat.postMessage', sent.first.first
    assert_equal 'U123', sent.first[1]['channel']
  end

  def test_background_form_permission_loss_reports_failure_without_saving
    key = "slackmine:submission:#{Digest::SHA256.hexdigest(['ATEST', 'TTEST', @viewer.id, 'V123'].join(':'))}"
    @cache.write(key, 'pending', expires_in: 86_400)
    sent = []
    Rails.stub(:cache, @cache) do
      Slackmine::WorkObjects.stub(:viewer_for, nil) do
        COMMANDS.stub(:save_form, ->(*) { flunk 'Permission loss must not save' }) do
          Slackmine.stub(:slack_api, ->(*args) { sent << args }) do
            COMMANDS.complete_form('ATEST', 'TTEST', 'U123', 'create', '1', {}, @viewer.id, 'V123')
          end
        end
      end
    end
    assert_nil @cache.read(key)
    assert_equal 'U123', sent.first[1]['channel']
  end

  def test_background_form_uncertain_save_reports_failure_and_keeps_claim
    key = "slackmine:submission:#{Digest::SHA256.hexdigest(['ATEST', 'TTEST', @viewer.id, 'V123'].join(':'))}"
    @cache.write(key, 'pending', expires_in: 86_400)
    sent = []
    Rails.stub(:cache, @cache) do
      COMMANDS.stub(:enabled?, true) do
        COMMANDS.stub(:integration?, true) do
          Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
            COMMANDS.stub(:save_form, ->(*) { raise 'Uncertain outcome' }) do
              Slackmine.stub(:slack_api, ->(*args) { sent << args }) do
                COMMANDS.complete_form('ATEST', 'TTEST', 'U123', 'create', '1', {}, @viewer.id, 'V123')
              end
            end
          end
        end
      end
    end
    assert_equal 'pending', @cache.read(key)
    assert_equal 'U123', sent.first[1]['channel']
  end
end
