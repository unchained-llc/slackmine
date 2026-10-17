# frozen_string_literal: true

require_relative 'formatter'

module Slackmine
  module IssuePatch
    def self.included(base)
      base.before_validation :import_slack_description_quotes
      base.after_create_commit :notify_slack_issue_created
      base.after_destroy_commit :notify_slack_issue_deleted
    end

    private

    def import_slack_description_quotes
      return unless will_save_change_to_description?
      self.description = LinkQuotes.import(description, self, User.current)
    end

    def notify_slack_issue_created
      return if is_private?

      Slackmine.enqueue(
        Slackmine::Formatter.issue_payload(self, actor: author, action: 'created'),
        project: self.project, event: 'issue_created',
        image_names: Slackmine::Formatter.image_references(description), issue_id: id, source: self
      )
    end

    def notify_slack_issue_deleted
      return if is_private?

      Slackmine.enqueue(
        Slackmine::Formatter.issue_payload(self, actor: User.current, action: 'deleted'),
        project: self.project, event: 'issue_deleted', issue_id: id, source: self
      )
    end
  end
end
