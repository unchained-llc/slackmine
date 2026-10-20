# frozen_string_literal: true

class SlackmineCommandJob < ApplicationJob
  queue_as :slack
  # response_url is a temporary credential; do not print it in job logs.
  self.log_arguments = false if respond_to?(:log_arguments=)

  def perform(app_id, team_id, payload)
    Slackmine::SlashCommands.deliver(app_id, team_id, payload)
  end
end
