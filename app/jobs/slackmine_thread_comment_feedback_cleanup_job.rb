# frozen_string_literal: true

class SlackmineThreadCommentFeedbackCleanupJob < ApplicationJob
  queue_as :slackmine

  def perform(project_id, channel, timestamp, kind = 'comment')
    project = Project.find_by(id: project_id)
    return unless project && Slackmine::ThreadFeedback.cleanup_seconds(project, kind) != -1

    token = Slackmine.bot_token(project)
    return if token.to_s.empty?

    Slackmine.slack_api('chat.delete', { 'channel' => channel, 'ts' => timestamp }, token)
  rescue Slackmine::SlackApiError => e
    # A manual deletion or a retry after successful deletion is already done.
    raise unless e.code == 'message_not_found'
  end
end
