# frozen_string_literal: true

class SlackmineTestNotificationJob < ApplicationJob
  queue_as :slackmine

  def perform(project_id, expected_channel, text)
    project = Project.find(project_id) if project_id
    Slackmine.with_project(project) do
      channel = Slackmine::JobMonitor.test_channel(project)
      token = Slackmine.bot_token(project)
      raise ArgumentError, 'Test notification destination changed or is unavailable' if channel.to_s.empty? || channel != expected_channel || token.to_s.empty?
      Slackmine.post_message({ 'text' => text, 'attachments' => [{ 'color' => Slackmine::Formatter.attachment_color, 'text' => text }] }, channel, token)
    end
  end
end
