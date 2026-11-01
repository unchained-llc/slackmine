# frozen_string_literal: true

class SlackmineThreadCommentJob < ApplicationJob
  queue_as :slackmine

  def perform(app_id, team_id, event, batch_ready = false)
    if batch_ready
      Slackmine::ThreadComments.process(app_id, team_id, event, batch_ready: true)
    else
      Slackmine::ThreadComments.process(app_id, team_id, event)
    end
  end
end
