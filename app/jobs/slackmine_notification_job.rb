# frozen_string_literal: true

class SlackmineNotificationJob < ApplicationJob
  queue_as :slack

  def perform(payload, project_id, image_names = [], image_source_id = nil, issue_id = nil)
    project = Project.find_by(id: project_id)
    return unless project
    return unless Slackmine::NotificationSafety.allowed?(payload['_slackmine_delivery_context'], project)

    # Accept the short-lived five-argument jobs already queued by the first
    # implementation as well as the four-argument format used now.
    issue_id ||= -image_source_id if image_source_id.is_a?(Integer) && image_source_id.negative?
    journal_id = image_source_id if image_source_id.is_a?(Integer) && image_source_id.positive?
    Slackmine.notify(payload, project: project, image_names: image_names,
                                    journal_id: journal_id, issue_id: issue_id)
  end
end
