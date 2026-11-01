# frozen_string_literal: true

class SlackmineWorkObjectInteractionJob < ApplicationJob
  queue_as :slackmine

  def perform(app_id, team_id, payload)
    Slackmine::WorkObjects.process_interaction(app_id, team_id, payload)
  rescue Slackmine::SlackApiError => e
    Rails.logger.error("Slackmine: Work Object interaction failed: #{e.code}")
  rescue StandardError => e
    # Link imports may have committed an Issue before a later step failed.
    Rails.logger&.error("Slackmine: Work Object interaction outcome uncertain: #{e.class}")
  end
end
