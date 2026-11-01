# frozen_string_literal: true

class SlackmineThreadConnectionJob < ApplicationJob
  queue_as :slackmine

  def perform(app, team, source, view_id = nil, step = nil)
    case step
    when 'picker' then Slackmine::ThreadConnections.prepare_picker(app, team, source, view_id)
    when 'preview' then Slackmine::ThreadConnections.prepare_preview(app, team, source, view_id)
    when 'save'
      begin
        Slackmine::ThreadConnections.complete_submission(app, team, source)
      rescue StandardError => e
        # The Slack marker or Redmine save may already exist. An automatic
        # retry could repeat a partial write; leave the claim pending.
        Rails.logger&.error("Slackmine: connection save outcome uncertain: #{e.class}")
      end
    else Slackmine::ThreadConnections.finish(app, team, source)
    end
  end
end
