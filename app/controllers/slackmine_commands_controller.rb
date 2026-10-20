# frozen_string_literal: true

require 'uri'
require 'digest'
require 'timeout'

class SlackmineCommandsController < ActionController::Base
  protect_from_forgery with: :null_session

  def receive
    return head :payload_too_large if request.content_length.to_i > 65_536
    body = request.raw_post
    return head :payload_too_large if body.bytesize > 65_536
    pairs = URI.decode_www_form(body)
    return head :bad_request unless pairs.map(&:first).uniq.length == pairs.length
    payload = pairs.to_h
    integration = Slackmine::WorkObjects.verified_integration(
      body, request.headers['X-Slack-Request-Timestamp'], request.headers['X-Slack-Signature'],
      app_id: payload['api_app_id'], team_id: payload['team_id']
    )
    return head :unauthorized unless integration && payload['api_app_id'] == integration['app_id'] && payload['team_id'] == integration['team_id']
    return head :forbidden unless Slackmine::SlashCommands.integration?(payload['api_app_id'], payload['team_id'])
    expected = Slackmine.effective_config.dig('slack', 'slash_command')
    return head :forbidden unless expected.to_s.start_with?('/') && payload['command'] == expected
    return head :bad_request unless payload['user_id'].to_s.match?(/\A[UW][A-Z0-9]+\z/) && payload['channel_id'].to_s.match?(/\A[CDG][A-Z0-9]+\z/) && payload['text'].to_s.length <= 1000
    command = payload.slice('user_id', 'channel_id', 'text')
    if Slackmine::SlashCommands.response_uri(payload['response_url'])
      command['response_url'] = payload['response_url']
    end
    if Slackmine::SlashCommands.direct_arguments(payload['text'])
      command['request_key'] = Digest::SHA256.hexdigest([request.headers['X-Slack-Request-Timestamp'], body].join(':'))
    end
    return head :service_unavailable unless SlackmineCommandJob.perform_later(payload['api_app_id'], payload['team_id'], command)
    head :ok
  rescue Slackmine::SlackApiError => e
    Rails.logger&.error("Slackmine: command enqueue failed: #{e.code}")
    head :service_unavailable
  rescue Timeout::Error, IOError, SystemCallError => e
    Rails.logger&.error("Slackmine: command enqueue failed: #{e.class}")
    head :service_unavailable
  rescue ArgumentError
    head :bad_request
  end
end
