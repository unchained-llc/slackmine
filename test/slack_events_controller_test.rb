# frozen_string_literal: true

# This plugin's standalone suite has no Rails installation. Exercise the actual
# controller method with a minimal request/response adapter; production Rails
# supplies the routing, headers, and ActiveJob adapter.
require_relative 'image_notification_test'

module ActionController
  class Base
    def self.protect_from_forgery(*)
    end

    attr_accessor :request
    attr_reader :status, :response_body

    def head(status)
      @status = status
    end

    def render(json:)
      @status = :ok
      @response_body = json
    end
  end
end

require_relative '../app/controllers/slackmine_events_controller'
require_relative '../app/jobs/slackmine_work_object_details_job'
require_relative '../app/jobs/slackmine_work_object_unfurl_job'
require_relative '../app/jobs/slackmine_work_object_interaction_job'
require_relative '../app/jobs/slackmine_thread_comment_job'
require_relative '../app/jobs/slackmine_app_home_job'

class SlackEventsControllerTest < Minitest::Test
  class RequestCache
    attr_reader :entries
    def initialize
      @entries = {}
    end
    def write(key, value, unless_exist:, expires_in:)
      return false if unless_exist && @entries.key?(key)
      @entries[key] = { value: value, expires_in: expires_in }
      true
    end
    def delete(key)
      @entries.delete(key)
    end
  end

  def interaction_body(trigger: 'write-trigger')
    URI.encode_www_form('payload' => JSON.generate({
      'type' => 'view_submission', 'api_app_id' => 'ATEST', 'team' => { 'id' => 'TTEST' },
      'user' => { 'id' => 'U123' }, 'trigger_id' => trigger,
      'view' => { 'type' => 'modal', 'callback_id' => 'slackmine_add_comment',
        'private_metadata' => '{}', 'state' => { 'values' => {
          'new_comment' => { 'new_comment' => { 'value' => 'Do not save twice' } }
        } } }
    }))
  end

  def test_interaction_runs_on_the_request_thread_and_redelivery_does_not_repeat_it
    request_thread = Thread.current
    calls = []
    body = interaction_body
    Slackmine::WorkObjects.stub(:process_interaction, lambda { |*args|
      assert_same request_thread, Thread.current
      calls << args
    }) do
      2.times { assert_equal :ok, dispatch(raw: body).status }
      assert_equal 1, calls.length
      assert_equal :ok, dispatch(raw: interaction_body(trigger: 'new-user-action')).status
      assert_equal 2, calls.length
    end
    assert @cache.entries.keys.all? { |key| key.match?(/\Aslackmine:work_object_request:[0-9a-f]{64}\z/) }
    assert @cache.entries.values.all? { |entry| entry == { value: true, expires_in: 600 } }
  end

  def test_invalid_interaction_signature_does_not_claim_request_or_run_handler
    Slackmine::WorkObjects.stub(:process_interaction, ->(*) { flunk 'Unverified request must not run' }) do
      assert_equal :unauthorized, dispatch(raw: interaction_body, signature: 'v0=' + '0' * 64).status
    end
    assert_empty @cache.entries
  end

  def test_slack_failure_after_save_is_logged_without_repeating_the_write
    errors = []
    durations = []
    logger = Object.new
    logger.define_singleton_method(:error) { |message| errors << message }
    logger.define_singleton_method(:info) { |message| durations << message }
    saved = 0
    body = interaction_body
    Rails.stub(:logger, logger) do
      Slackmine::WorkObjects.stub(:process_interaction, lambda { |*|
        saved += 1
        raise Slackmine::SlackApiError.new('entity.presentDetails', '200', { 'error' => 'expired_trigger_id' })
      }) do
        2.times { assert_equal :ok, dispatch(raw: body).status }
      end
    end
    assert_equal 1, saved
    assert_equal ['Slackmine: Work Object process_interaction failed: expired_trigger_id'], errors
    assert_match(/process_interaction duration_ms=\d+\z/, durations.first)
    assert_equal 1, durations.length
  end

  def test_uncertain_save_failure_keeps_claim_so_redelivery_cannot_repeat_write
    body = interaction_body
    calls = 0
    Slackmine::WorkObjects.stub(:process_interaction, lambda { |*|
      calls += 1
      raise 'Save outcome is uncertain'
    }) do
      assert_raises(RuntimeError) { dispatch(raw: body) }
      assert_equal :ok, dispatch(raw: body).status
    end
    assert_equal 1, calls
  end

  def test_details_network_timeout_is_acknowledged_and_logged
    errors = []
    logger = Object.new
    logger.define_singleton_method(:error) { |message| errors << message }
    logger.define_singleton_method(:info) { |_| }
    Rails.stub(:logger, logger) do
      assert_equal :ok, dispatch(handler_error: Net::ReadTimeout.new).status
    end
    assert_equal ['Slackmine: Work Object present_details failed: Net::ReadTimeout'], errors
  end

  def test_watch_button_and_confirmation_run_synchronously_without_inputs
    interaction = { 'type' => 'block_actions', 'api_app_id' => 'ATEST',
      'team' => { 'id' => 'TTEST' }, 'user' => { 'id' => 'U123' }, 'trigger_id' => 'fresh-trigger',
      'container' => { 'type' => 'entity_detail', 'entity_url' => 'https://example.com/issues/7' },
      'actions' => [{ 'action_id' => 'slackmine_watch' }] }
    opened = []
    Slackmine::WorkObjects.stub(:process_interaction, ->(*args) { opened << args }) do
      assert_equal :ok, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(interaction))).status
      assert_equal 1, opened.length
      assert_equal 'fresh-trigger', opened.first.last['trigger_id']
      assert_equal :unauthorized, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(interaction)), signature: 'v0=' + '0' * 64).status
      assert_equal 1, opened.length
      interaction['type'] = 'view_submission'
      interaction['view'] = { 'type' => 'modal', 'callback_id' => 'slackmine_watch_settings', 'private_metadata' => '{}' }
      assert_equal :ok, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(interaction))).status
      assert_equal 2, opened.length
      assert_equal({}, opened.last.last.dig('view', 'state', 'values'))
      interaction['view']['callback_id'] = 'slackmine_edit_issue'
      assert_equal :bad_request, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(interaction))).status
    end
  end

  def setup
    @cache = RequestCache.new
    @queued_home = []
    @settings = { 'slack' => { 'events' => {
      'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'test-secret'
    } } }
    @payload = { 'type' => 'event_callback', 'api_app_id' => 'ATEST', 'team_id' => 'TTEST',
                 'event' => { 'type' => 'entity_details_requested', 'trigger_id' => 'test-trigger',
                              'user' => 'U123', 'entity_url' => 'https://example.com/issues/7',
                              'external_ref' => { 'id' => 'issue7', 'type' => 'slackmine_issue' },
                              'unused_field' => 'do not queue' } }
  end

  def dispatch(payload = @payload, signature: nil, timestamp: Time.now.to_i, raw: nil, length: nil, handler_error: nil)
    body = raw || JSON.generate(payload)
    signature ||= 'v0=' + OpenSSL::HMAC.hexdigest('SHA256', 'test-secret', "v0:#{timestamp}:#{body}")
    controller = SlackmineEventsController.new
    controller.request = OpenStruct.new(content_length: length || body.bytesize, raw_post: body,
                                        headers: { 'X-Slack-Request-Timestamp' => timestamp.to_s,
                                                   'X-Slack-Signature' => signature })
    @handled = []
    @queued_unfurls = []
    @queued_interactions = []
    handler = lambda do |*args|
      assert_nil controller.status, 'Work Object handling must run before the HTTP response'
      raise handler_error if handler_error
      @handled << args
    end
    Slackmine.stub(:config, @settings) do
      Rails.stub(:cache, @cache) do
        Slackmine::WorkObjects.stub(:present_details, handler) do
          Slackmine::WorkObjects.stub(:unfurl_links, handler) do
            rejected_job = ->(*) { flunk 'Details and interactions must run directly' }
            SlackmineWorkObjectDetailsJob.stub(:perform_later, rejected_job) do
              SlackmineWorkObjectUnfurlJob.stub(:perform_later, ->(*args) { @queued_unfurls << args }) do
                SlackmineAppHomeJob.stub(:perform_later, ->(*args) { @queued_home << args }) do
                  SlackmineWorkObjectInteractionJob.stub(:perform_later, ->(*args) { @fail_interaction_enqueue ? false : (@queued_interactions << args) }) { controller.receive }
                end
              end
            end
          end
        end
      end
    end
    controller
  end

  def test_signed_challenge_without_app_ids_returns_challenge_and_does_not_queue
    response = dispatch({ 'type' => 'url_verification', 'challenge' => 'verify-me' })
    assert_equal :ok, response.status
    assert_equal({ challenge: 'verify-me' }, response.response_body)
    assert_empty @handled
  end

  def test_signed_details_event_runs_before_ack_with_only_necessary_fields
    response = dispatch
    assert_equal :ok, response.status
    assert_equal 1, @handled.length
    app_id, team_id, event = @handled.first
    assert_equal 'ATEST', app_id
    assert_equal 'TTEST', team_id
    assert_equal 'test-trigger', event['trigger_id']
    refute event.key?('unused_field')
  end

  def test_invalid_signature_expired_timestamp_and_wrong_app_are_not_queued
    [dispatch(signature: 'v0=' + '0' * 64), dispatch(timestamp: Time.now.to_i - 301),
     dispatch(@payload.merge('api_app_id' => 'AOTHER'))].each do |response|
      assert_equal :unauthorized, response.status
    end
    assert_empty @handled
  end

  def test_invalid_json_and_oversized_requests_are_rejected
    assert_equal :bad_request, dispatch(raw: '{').status
    assert_equal :bad_request, dispatch(raw: '[]').status
    assert_equal :payload_too_large, dispatch(length: 65_537).status
    assert_equal :payload_too_large, dispatch(raw: ' ' * 65_537).status
    assert_empty @handled
  end

  def test_large_signed_thread_confirmation_is_allowed_but_other_large_forms_are_rejected
    payload = { 'type' => 'view_submission', 'api_app_id' => 'ATEST', 'team' => { 'id' => 'TTEST' },
      'view' => { 'callback_id' => 'slackmine_thread_connect_save', 'blocks' => ['x' * 70_000] } }
    body = URI.encode_www_form('payload' => JSON.generate(payload))
    Slackmine::ThreadConnections.stub(:interaction, ->(*) { {} }) do
      assert_equal :ok, dispatch(raw: body).status
      assert_equal :unauthorized, dispatch(raw: body, signature: 'v0=' + '0' * 64).status
      payload['type'] = 'block_actions'
      payload['actions'] = [{ 'action_id' => 'history_group_0' }]
      assert_equal :ok, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(payload))).status
      payload['actions'] = [{ 'action_id' => 'unrelated' }]
      assert_equal :payload_too_large, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(payload))).status
      payload['type'] = 'view_submission'
      payload['view']['callback_id'] = 'other'
      assert_equal :payload_too_large, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(payload))).status
    end
  end

  def test_missing_trigger_and_unrelated_events_do_not_queue
    event = @payload['event'].merge('trigger_id' => '')
    assert_equal :bad_request, dispatch(@payload.merge('event' => event)).status
    assert_empty @handled
    event = @payload['event'].merge('type' => 'app_mention')
    assert_equal :ok, dispatch(@payload.merge('event' => event)).status
    assert_empty @handled
  end

  def test_signed_callback_without_app_and_team_ids_is_forbidden
    assert_equal :forbidden, dispatch(@payload.reject { |key, _| %w[api_app_id team_id].include?(key) }).status
    assert_empty @handled
  end

  def test_job_passes_event_to_details_handler
    arguments = nil
    Slackmine::WorkObjects.stub(:present_details, ->(*args) { arguments = args }) do
      SlackmineWorkObjectDetailsJob.new.perform('ATEST', 'TTEST', @payload['event'])
    end
    assert_equal ['ATEST', 'TTEST', @payload['event']], arguments
  end

  def test_signed_link_refresh_queues_only_needed_fields
    event = { 'type' => 'link_shared', 'is_unfurl_refresh' => true, 'user' => 'U123',
              'channel' => 'C123', 'message_ts' => '123.456', 'unfurl_id' => 'refresh-id',
              'source' => 'conversations_history', 'links' => [{ 'url' => 'https://example.com/issues/7' }],
              'unused_field' => 'do not queue' }
    response = dispatch(@payload.merge('event' => event))
    assert_equal :ok, response.status
    assert_empty @handled
    assert_equal 1, @queued_unfurls.length
    assert_equal ['ATEST', 'TTEST'], @queued_unfurls.first.first(2)
    assert_equal true, @queued_unfurls.first[2]['is_unfurl_refresh']
    assert_equal event['links'], @queued_unfurls.first[2]['links']
    refute @queued_unfurls.first[2].key?('unused_field')
    assert_equal :unauthorized, dispatch(@payload.merge('event' => event), signature: 'v0=' + '0' * 64).status
    assert_empty @handled
  end

  def test_modal_with_slack_link_saves_after_ack
    body = interaction_body
    payload = JSON.parse(URI.decode_www_form(body).first.last)
    payload['view']['state']['values']['new_comment']['new_comment']['value'] = 'https://example.slack.com/archives/C123/p123'
    assert_equal :ok, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(payload))).status
    assert_equal 1, @queued_interactions.length
    assert_empty @handled
  end

  def test_detail_edit_with_slack_link_is_deferred_without_expiring_ack
    payload = JSON.parse(URI.decode_www_form(interaction_body).first.last)
    payload['view']['type'] = 'entity_detail'
    payload['view']['state']['values']['new_comment']['new_comment']['value'] = 'https://example.slack.com/archives/C123/p123'
    assert_equal :ok, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(payload))).status
    assert_equal true, @queued_interactions.first.last['deferred']
    assert_empty @handled
  end

  def test_failed_slow_edit_enqueue_can_be_retried
    payload = JSON.parse(URI.decode_www_form(interaction_body).first.last)
    payload['view']['state']['values']['new_comment']['new_comment']['value'] = 'https://example.slack.com/archives/C123/p123'
    body = URI.encode_www_form('payload' => JSON.generate(payload))
    @fail_interaction_enqueue = true
    assert_equal :service_unavailable, dispatch(raw: body).status
    assert_empty @cache.entries
    @fail_interaction_enqueue = false
    assert_equal :ok, dispatch(raw: body).status
    assert_equal 1, @queued_interactions.size
  end

  def test_unfurl_job_passes_event_to_handler
    event = { 'type' => 'link_shared', 'user' => 'U123', 'links' => [] }
    arguments = nil
    Slackmine::WorkObjects.stub(:unfurl_links, ->(*args) { arguments = args }) do
      SlackmineWorkObjectUnfurlJob.new.perform('ATEST', 'TTEST', event)
    end
    assert_equal ['ATEST', 'TTEST', event], arguments
  end

  def test_signed_work_object_interaction_runs_directly_from_form_payload
    interaction = { 'type' => 'block_actions', 'api_app_id' => 'ATEST',
                    'team' => { 'id' => 'TTEST' }, 'user' => { 'id' => 'U123' },
                    'container' => { 'type' => 'entity_detail', 'entity_url' => 'https://example.com/issues/7' },
                    'actions' => [{ 'action_id' => 'slackmine_assign_to_me' }], 'token' => 'do-not-queue' }
    body = URI.encode_www_form('payload' => JSON.generate(interaction))
    handled = []
    Slackmine::WorkObjects.stub(:process_interaction, ->(*args) { handled << args }) do
      assert_equal :ok, dispatch(raw: body).status
      assert_equal 'ATEST', handled.first[0]
      assert_equal 'TTEST', handled.first[1]
      assert_equal 'slackmine_assign_to_me', handled.first[2].dig('actions', 0, 'action_id')
      refute handled.first[2].key?('token')
      assert_equal :unauthorized, dispatch(raw: body, signature: 'v0=' + '0' * 64).status
      assert_equal :bad_request, dispatch(raw: body + '&other=1').status
      assert_equal 1, handled.length
    end
  end

  def test_signed_detail_edit_passes_only_editable_values_directly
    interaction = { 'type' => 'view_submission', 'api_app_id' => 'ATEST',
                    'team' => { 'id' => 'TTEST' }, 'user' => { 'id' => 'U123' },
                    'view' => { 'type' => 'entity_detail', 'entity_url' => 'https://example.com/issues/7',
                                'state' => { 'values' => {
                                  'new_comment' => { 'new_comment.input' => { 'value' => 'Test note' } },
                                  'unrelated' => { 'value' => 'do-not-queue' }
                                } } }, 'token' => 'do-not-queue' }
    body = URI.encode_www_form('payload' => JSON.generate(interaction))
    handled = []
    Slackmine::WorkObjects.stub(:process_interaction, ->(*args) { handled << args }) do
      assert_equal :ok, dispatch(raw: body).status
      values = handled.first[2].dig('view', 'state', 'values')
      assert_equal 'Test note', values.dig('new_comment', 'new_comment.input', 'value')
      refute values.key?('unrelated')
      refute handled.first[2].key?('token')
    end
  end

  def test_signed_card_and_modal_interactions_preserve_only_scoped_context
    card = { 'type' => 'block_actions', 'api_app_id' => 'ATEST', 'team' => { 'id' => 'TTEST' },
             'user' => { 'id' => 'U123' }, 'trigger_id' => 'trigger',
             'container' => { 'type' => 'message_attachment', 'entity_url' => 'https://example.com/issues/7',
                              'external_ref' => { 'id' => 'issue7' }, 'channel_id' => 'C123',
                              'message_ts' => '123.456', 'is_ephemeral' => true, 'other' => 'drop' },
             'actions' => [{ 'action_id' => 'slackmine_edit_issue', 'value' => 'drop' }] }
    handled = []
    Slackmine::WorkObjects.stub(:process_interaction, ->(*args) { handled << args }) do
      assert_equal :ok, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(card))).status
      assert_equal 'C123', handled.first[2].dig('container', 'channel_id')
      refute handled.first[2]['container'].key?('other')
      refute handled.first[2]['actions'].first.key?('value')
      card['actions'].first['value'] = 'slackmine_issue:7'
      assert_equal :ok, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(card))).status
      assert_equal 'slackmine_issue:7', handled.last[2].dig('actions', 0, 'value')
      assert_equal true, handled.last[2].dig('container', 'is_ephemeral')
      modal = card.merge('type' => 'view_submission', 'view' => {
        'type' => 'modal', 'callback_id' => 'slackmine_edit_issue', 'private_metadata' => '{}',
        'state' => { 'values' => {
          'subject' => { 'subject' => { 'value' => 'Updated subject' } },
          'priority' => { 'priority' => { 'selected_option' => { 'value' => '5' } } },
          'assignee' => { 'assignee' => { 'selected_option' => { 'value' => '3' } } },
          'due_date' => { 'due_date' => { 'selected_date' => '2026-10-12' } },
          'description' => { 'description' => { 'value' => 'Updated description' } },
          'unrelated' => { 'value' => 'drop' }
        } }
      })
      assert_equal :ok, dispatch(raw: URI.encode_www_form('payload' => JSON.generate(modal))).status
      values = handled.last[2].dig('view', 'state', 'values')
      assert_equal 'Updated subject', values.dig('subject', 'subject', 'value')
      assert_equal '5', values.dig('priority', 'priority', 'selected_option', 'value')
      assert_equal '3', values.dig('assignee', 'assignee', 'selected_option', 'value')
      assert_equal '2026-10-12', values.dig('due_date', 'due_date', 'selected_date')
      assert_equal 'Updated description', values.dig('description', 'description', 'value')
      refute values.key?('unrelated')
    end
  end

  def test_image_only_reply_keeps_file_ids_through_queue_serialization
    @settings['slack'].merge!('thread_comments' => true, 'default_channel_id' => 'C123')
    @payload['event'] = { 'type' => 'message', 'subtype' => 'file_share', 'user' => 'U123',
      'channel' => 'C123', 'ts' => '1000.000002', 'thread_ts' => '1000.000001',
      'files' => [{ 'id' => 'F123', 'url_private' => 'do not queue', 'name' => 'screen.png' }],
      'unused_field' => 'do not queue' }
    queued = []
    SlackmineThreadCommentJob.stub(:perform_later, ->(*args) { queued << args }) do
      assert_equal :ok, dispatch.status
    end
    assert_equal 1, queued.size
    args = JSON.parse(JSON.generate(queued.first))
    assert_equal [{ 'id' => 'F123' }], args.last['files']
    refute args.last.key?('unused_field')
    assert Slackmine::ThreadComments.reply_event?(args.last)
    received = []
    Slackmine::ThreadComments.stub(:process, ->(*values) { received << values }) do
      SlackmineThreadCommentJob.new.perform(*args)
    end
    assert_equal args, received.first
  end

  def test_thread_reply_is_queued_only_when_enabled_and_for_the_configured_channel
    # This test covers notification threads with explicit connections disabled.
    @settings['slack']['thread_connections'] = false
    @settings['slack'].merge!('thread_comments' => true, 'default_channel_id' => 'C123')
    @payload['event'] = { 'type' => 'message', 'user' => 'U123', 'text' => 'Reply',
                          'channel' => 'C123', 'ts' => '1000.000002', 'thread_ts' => '1000.000001' }
    queued = []
    SlackmineThreadCommentJob.stub(:perform_later, ->(*args) { queued << args }) do
      assert_equal :ok, dispatch.status
      assert_equal 1, queued.length
      assert_equal @payload['event'], queued.first.last
      @settings['slack']['thread_comments'] = false
      dispatch
      assert_equal 1, queued.length
      @settings['slack']['thread_comments'] = true
      @payload['event']['channel'] = 'COTHER'
      dispatch
      assert_equal 1, queued.length
      @payload['event']['channel'] = 'C123'
      @payload['event']['bot_id'] = 'B123'
      dispatch
      assert_equal 1, queued.length
    end
  end
end
