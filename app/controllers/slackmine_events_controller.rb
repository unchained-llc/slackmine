# frozen_string_literal: true

require 'uri'
require 'digest'
require 'timeout'

class SlackmineEventsController < ActionController::Base
  # This endpoint uses Slack signatures, never a browser session or Redmine's
  # login cookie. Other Redmine controllers keep their normal CSRF protection.
  protect_from_forgery with: :null_session

  def receive
    return head :payload_too_large if request.content_length.to_i > 65_536
    body = request.raw_post
    return head :payload_too_large if body.bytesize > 65_536
    form = body.start_with?('payload=')
    if form
      pairs = URI.decode_www_form(body)
      return head :bad_request unless pairs.length == 1 && pairs.first[0] == 'payload'
      payload = JSON.parse(pairs.first[1])
    else
      payload = JSON.parse(body)
    end
    return head :bad_request unless payload.is_a?(Hash)

    team_id = form ? payload.dig('team', 'id') : payload['team_id']

    integration = Slackmine::WorkObjects.verified_integration(
      body, request.headers['X-Slack-Request-Timestamp'], request.headers['X-Slack-Signature'],
      app_id: payload['api_app_id'], team_id: team_id
    )
    return head :unauthorized unless integration

    if payload['type'] == 'url_verification'
      return render json: { challenge: payload['challenge'] } if payload['challenge'].is_a?(String)
      return head :bad_request
    end
    # Message shortcuts omit api_app_id. Resolve only known message shortcuts from
    # the verified signing secret, while still requiring the configured team.
    app_id = payload['api_app_id']
    if app_id.nil? && form && payload['type'] == 'message_action' && (Slackmine::MessageShortcuts.handles?(payload) || Slackmine::ThreadConnections.handles?(payload))
      app_id = integration['app_id']
    end
    return head :forbidden unless app_id == integration['app_id'] && team_id == integration['team_id']

    if form
      if Slackmine::ThreadConnections.handles?(payload)
        return render json: Slackmine::ThreadConnections.interaction(app_id, team_id, payload)
      end
      if Slackmine::AppHome.handles?(payload)
        return render json: Slackmine::AppHome.interaction(app_id, team_id, payload)
      end
      if Slackmine::MessageShortcuts.handles?(payload)
        return render json: Slackmine::MessageShortcuts.interaction(app_id, team_id, payload)
      end
      if Slackmine::SlashCommands.handles?(payload)
        return render json: Slackmine::SlashCommands.interaction(payload['api_app_id'], team_id, payload)
      end
      return head :bad_request unless %w[block_actions view_submission].include?(payload['type'])
      source_key = payload['type'] == 'block_actions' ? 'container' : 'view'
      source = payload[source_key]
      return head :bad_request unless source.is_a?(Hash)
      interaction = payload.slice('type', 'trigger_id')
      interaction['user'] = { 'id' => payload.dig('user', 'id') }
      interaction[source_key] = source.slice('type', 'entity_url', 'external_ref', 'channel_id', 'message_ts', 'is_ephemeral',
                                              'callback_id', 'private_metadata')
      if source_key == 'container'
        interaction['actions'] = Array(payload['actions']).map do |action|
          next {} unless action.is_a?(Hash)
          scoped = action.slice('action_id')
          value = action['value']
          scoped['value'] = value if value.is_a?(String) && value.match?(/\Aslackmine_issue:[1-9]\d*\z/)
          scoped
        end
      else
        values = source.dig('state', 'values')
        # The watch confirmation has no input blocks; Slack may omit state.
        values = {} if values.nil? && source['type'] == 'modal' && source['callback_id'] == 'slackmine_watch_settings'
        return head :bad_request unless values.is_a?(Hash)
        interaction['view']['state'] = { 'values' => values.slice('subject', 'status', 'priority', 'assignee', 'due_date', 'new_comment', 'description') }
      end
      # The signed request can be redelivered while this Web process is still
      # saving or refreshing Slack. Claim it before any write, using only a hash
      # of the already verified body; never cache submitted text or permissions.
      key = "slackmine:work_object_request:#{Digest::SHA256.hexdigest(body)}"
      return head :ok unless Rails.cache.write(key, true, unless_exist: true, expires_in: 600)

      values = interaction.dig('view', 'state', 'values') || {}
      slow_edit = %w[modal entity_detail].include?(interaction.dig('view', 'type')) &&
        values.values.any? { |group| group.is_a?(Hash) && group.values.any? { |item|
          item.is_a?(Hash) && item['value'].is_a?(String) && item['value'].match?(%r{\.slack\.com/archives/}i)
        } }
      if slow_edit
        interaction['deferred'] = true
        job = SlackmineWorkObjectInteractionJob.perform_later(app_id, team_id, interaction)
        unless job
          Rails.cache.delete(key)
          return head :service_unavailable
        end
      else
        run_work_object(:process_interaction, app_id, team_id, interaction)
      end
      return head :ok
    end

    event = payload['event']
    if payload['type'] == 'event_callback' && event.is_a?(Hash) && event['type'] == 'app_home_opened'
      return head :bad_request unless event['user'].is_a?(String)
      if event['tab'] == 'home' && Slackmine::AppHome.enabled?(app_id, team_id)
        view = event['view']
        filter = view.is_a?(Hash) && view['callback_id'] == 'slackmine_home' ? view['private_metadata'] : nil
        filter = 'all' unless Slackmine::AppHome::FILTERS.include?(filter)
        return head :service_unavailable unless SlackmineAppHomeJob.perform_later(app_id, team_id, event['user'], filter)
      end
    elsif payload['type'] == 'event_callback' && event.is_a?(Hash) && event['type'] == 'entity_details_requested'
      return head :bad_request if event['trigger_id'].to_s.empty? || event['user'].to_s.empty?

      # Process live details directly in the signed endpoint's Web process.
      run_work_object(:present_details, app_id, team_id, event.slice(
        'type', 'trigger_id', 'user', 'entity_url', 'external_ref'
      ))
    elsif payload['type'] == 'event_callback' && event.is_a?(Hash) && event['type'] == 'link_shared'
      return head :bad_request unless event['user'].is_a?(String) && event['links'].is_a?(Array)

      job = SlackmineWorkObjectUnfurlJob.perform_later(app_id, team_id, event.slice(
        'type', 'user', 'links', 'channel', 'message_ts', 'unfurl_id', 'source', 'is_unfurl_refresh'
      ))
      return head :service_unavailable unless job
    elsif payload['type'] == 'event_callback' && Slackmine::ThreadComments.accepted_reply?(payload['api_app_id'], payload['team_id'], event)
      reply = event.slice(
        'type', 'subtype', 'user', 'text', 'channel', 'ts', 'thread_ts'
      )
      # The worker resolves authoritative metadata with files.info. Keep only
      # IDs, but do not drop image-only replies at the queue boundary.
      if event['files'].is_a?(Array)
        reply['files'] = event['files'].map { |file| file.is_a?(Hash) ? file.slice('id') : {} }
      end
      SlackmineThreadCommentJob.perform_later(payload['api_app_id'], payload['team_id'], reply)
    end
    head :ok
  rescue Slackmine::SlackApiError => e
    Rails.logger&.error("Slackmine: synchronous Slack operation failed: #{e.code}")
    head :ok
  rescue Timeout::Error, IOError, SystemCallError => e
    Rails.logger&.error("Slackmine: synchronous Slack operation failed: #{e.class}")
    head :ok
  rescue JSON::ParserError, ArgumentError
    head :bad_request
  end

  private

  def run_work_object(method, app_id, team_id, payload)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Slackmine::WorkObjects.public_send(method, app_id, team_id, payload)
  rescue Slackmine::SlackApiError => e
    # A Slack refresh failure must not replay a completed Redmine write.
    Rails.logger&.error("Slackmine: Work Object #{method} failed: #{e.code}")
  rescue Timeout::Error, IOError, SystemCallError => e
    Rails.logger&.error("Slackmine: Work Object #{method} failed: #{e.class}")
  ensure
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.logger&.info("Slackmine: Work Object #{method} duration_ms=#{elapsed}")
  end
end
