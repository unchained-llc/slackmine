# frozen_string_literal: true

class SlackmineAppHomeJob < ApplicationJob
  queue_as :slackmine

  def perform(app_id, team_id, user_id, filter = 'all')
    Slackmine::AppHome.publish(app_id, team_id, user_id, filter)
  rescue Slackmine::SlackApiError => e
    Rails.logger.error("Slackmine: App Home publish failed: #{e.code}")
  end
end
