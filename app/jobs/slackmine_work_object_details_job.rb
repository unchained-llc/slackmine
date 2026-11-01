# frozen_string_literal: true

class SlackmineWorkObjectDetailsJob < ApplicationJob
  queue_as :slackmine

  def perform(app_id, team_id, event)
    Slackmine::WorkObjects.present_details(app_id, team_id, event)
  rescue Slackmine::SlackApiError => e
    # Trigger-based requests should be retried by refreshing the detail pane,
    # rather than replaying an expired trigger through Sidekiq retries.
    Rails.logger.error("Slackmine: Work Object details failed: #{e.code}")
  end
end
