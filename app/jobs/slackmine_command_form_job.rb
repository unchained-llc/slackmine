# frozen_string_literal: true

class SlackmineCommandFormJob < ApplicationJob
  queue_as :slackmine

  def perform(app, team, slack_user, kind, id, values, user_id, view_id)
    Slackmine::SlashCommands.complete_form(app, team, slack_user, kind, id, values, user_id, view_id)
  end
end
