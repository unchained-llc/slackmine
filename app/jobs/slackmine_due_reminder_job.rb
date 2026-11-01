# frozen_string_literal: true

class SlackmineDueReminderJob < ApplicationJob
  queue_as :slackmine

  def perform(issue_id, scheduled_on, target_user_id = nil)
    issue = Issue.find_by(id: issue_id)
    return unless issue
    assignee = issue.assigned_to
    return unless assignee.is_a?(User)
    return if target_user_id && assignee.id != target_user_id

    # Jobs queued by the previous release also use the daily digest.
    SlackmineDueDigestJob.new.perform(assignee.id, scheduled_on)
  end
end
