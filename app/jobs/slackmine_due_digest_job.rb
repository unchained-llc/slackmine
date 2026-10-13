# frozen_string_literal: true

class SlackmineDueDigestJob < ApplicationJob
  queue_as :slack

  MAX_ISSUES_PER_MESSAGE = 100

  def perform(user_id, scheduled_on, filters = nil)
    today = Date.current
    return unless scheduled_on == today.iso8601

    user = User.find_by(id: user_id)
    return unless user&.active?

    filters = {} unless filters.is_a?(Hash)
    groups = due_issues_for(user, today, filters)
    groups.each do |(token, slack_user_id), issues|
      begin
        dm = Slackmine.slack_api('conversations.open', { 'users' => slack_user_id }, token)
      rescue Slackmine::SlackApiError => error
        raise unless error.code == 'cannot_dm_bot'

        Rails.logger.warn("Slackmine: due reminder skipped for Redmine user ##{user.id} " \
                          "(Slack user #{slack_user_id}: cannot_dm_bot)")
        next
      end
      channel = dm.dig('channel', 'id')
      raise "Slack conversations.open returned no DM channel for Redmine user ##{user.id}" unless channel.to_s.match?(/\AD[A-Z0-9]+\z/)

      sorted = issues.sort_by { |issue| [issue.due_date, issue.project.name, issue.id] }
      sorted.each_slice(MAX_ISSUES_PER_MESSAGE).with_index do |batch, index|
        sleep(1) if index.positive?
        payload = Slackmine.with_project(batch.first.project) do
          Slackmine::Formatter.due_digest_payload(batch, today: today, part: index + 1,
                                                                  total_parts: (sorted.size + MAX_ISSUES_PER_MESSAGE - 1) / MAX_ISSUES_PER_MESSAGE)
        end
        Slackmine.post_message(payload, channel, token)
      end
    end
  end

  # Shared read-only selection for scheduled and personal on-demand digests.
  def due_issues_for(user, today, filters = {})
    max_days = filters.fetch('days') { Slackmine.due_reminder_max_days }
    issues = Issue.joins(:status).where(issue_statuses: { is_closed: false })
                  .where(assigned_to_id: user.id)
                  .where('issues.due_date <= ?', today + max_days)
                  .includes(:project)
    issues = Slackmine.due_reminder_filter_scope(issues, filters)
    groups = Hash.new { |hash, key| hash[key] = [] }
    issues.find_each do |issue|
      project = issue.project
      settings = Slackmine.due_reminder_settings(project)
      next unless settings[:enabled] && issue.due_date <= today + filters.fetch('days', settings[:days])
      next unless project.active? && issue.visible?(user)
      Slackmine.with_project(project) do
        token = Slackmine.bot_token(project)
        slack_user_id = Slackmine.slack_user_id_for(user)
        unless token.present? && slack_user_id
          Rails.logger.warn("Slackmine: due reminder skipped for issue ##{issue.id} (token or Slack user mapping missing)")
          next
        end

        groups[[token, slack_user_id]] << issue
      end
    end
    groups
  end
end
