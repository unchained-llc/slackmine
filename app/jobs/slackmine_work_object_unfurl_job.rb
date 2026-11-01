# frozen_string_literal: true

class SlackmineWorkObjectUnfurlJob < ApplicationJob
  queue_as :slackmine

  def perform(app_id, team_id, event)
    Slackmine::WorkObjects.unfurl_links(app_id, team_id, event)
  rescue Slackmine::SlackApiError => e
    Rails.logger.error("Slackmine: Work Object unfurl failed: #{e.code}")
  end
end
