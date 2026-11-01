# frozen_string_literal: true

module Slackmine
  module ThreadFeedback
    module_function

    SETTINGS = {
      'comment' => 'thread_comment_feedback_cleanup_seconds',
      'connection' => 'thread_connection_feedback_cleanup_seconds'
    }.freeze

    def cleanup_seconds(project, kind)
      value = Slackmine.effective_config(project).dig('slack', SETTINGS.fetch(kind))
      return -1 if value == -1
      value.is_a?(Numeric) && value.finite? && value >= 0 ? value : -1
    end

    def post(project, channel, thread_ts, text, kind, source_ts: nil)
      wait = cleanup_seconds(project, kind)
      return if wait.zero?
      result = Slackmine.slack_api('chat.postMessage', {
        'channel' => channel, 'thread_ts' => thread_ts, 'text' => text,
        'unfurl_links' => false, 'unfurl_media' => false
      }, Slackmine.bot_token(project))
      timestamp = result['ts']
      if wait.positive? && ThreadComments.posted_at(timestamp) && timestamp != thread_ts && timestamp != source_ts
        begin
          job = SlackmineThreadCommentFeedbackCleanupJob.set(wait: wait).perform_later(project.id, channel, timestamp, kind)
          Rails.logger&.warn('Slackmine: feedback cleanup was not enqueued') unless job
        rescue NotImplementedError => e
          Rails.logger&.warn("Slackmine: scheduled feedback cleanup unavailable: #{e.class}")
        end
      end
      result
    end
  end
end
