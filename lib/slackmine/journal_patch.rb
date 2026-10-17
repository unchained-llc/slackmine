# frozen_string_literal: true

require_relative 'formatter'

module Slackmine
  module JournalPatch
    def self.included(base)
      base.before_validation :import_slack_notes_quotes
      base.after_create_commit :notify_slack_journal_created
      base.after_update_commit :notify_slack_journal_comment_changed
    end

    private

    def import_slack_notes_quotes
      return unless will_save_change_to_notes? && journalized.is_a?(Issue)
      self.notes = LinkQuotes.import(notes, journalized, User.current)
    end

    def notify_slack_journal_created
      issue = journalized
      return unless issue.is_a?(Issue)
      return if Thread.current[:slackmine_thread_comment] &&
                Slackmine.effective_config(issue.project).dig('slack', 'suppress_thread_comment_notifications') != false
      return if issue.is_private? || private_notes?

      comment_enabled = !notes.to_s.strip.empty? && Slackmine.event_enabled?(issue.project, 'comment_added')
      enabled_details = Slackmine::Formatter.public_changes(details).select do |detail|
        Slackmine.event_enabled?(issue.project, slack_event_for_detail(detail))
      end
      return unless comment_enabled || enabled_details.any?

      payload = if comment_enabled
                  Slackmine::Formatter.journal_payload(
                    issue, actor: user, notes: notes,
                    details: enabled_details
                  )
                else
                  Slackmine::Formatter.issue_payload(
                    issue, actor: user, action: 'updated', details: enabled_details
                  )
                end
      if comment_enabled && enabled_details.empty? &&
         Slackmine.effective_config(issue.project).dig('slack', 'comment_notifications_in_threads') == true
        payload = payload.merge('_slackmine_comment_issue_id' => issue.id)
      end
      Slackmine.enqueue(
        payload,
        project: issue.project,
        event: enabled_details.any? ? slack_event_for_detail(enabled_details.first) : 'comment_added',
        image_names: comment_enabled ? Slackmine::Formatter.image_references(notes) : [],
        journal_id: id, source: self
      )
    end

    def notify_slack_journal_comment_changed
      issue = journalized
      return unless issue.is_a?(Issue)
      return if issue.is_private? || private_notes? || attribute_before_last_save('private_notes')
      return unless saved_change_to_notes?

      previous_notes = notes_before_last_save.to_s.strip
      return if previous_notes.empty?

      action = notes.to_s.strip.empty? ? 'deleted' : 'updated'
      event = "comment_#{action}"
      return unless Slackmine.event_enabled?(issue.project, event)

      image_names = action == 'updated' ? Slackmine::Formatter.image_references(notes) : []

      payload = Slackmine::Formatter.journal_payload(
        issue, actor: updated_by || User.current, notes: notes, comment_action: action,
        previous_notes: notes_before_last_save
      )
      if Slackmine.effective_config(issue.project).dig('slack', 'comment_notifications_in_threads') == true
        payload = payload.merge('_slackmine_comment_issue_id' => issue.id)
      end
      Slackmine.enqueue(
        payload,
        project: issue.project, event: event,
        image_names: image_names, journal_id: id, source: self
      )
    end

    def slack_event_for_detail(detail)
      return 'issue_updated' unless detail.respond_to?(:property)

      case detail.property
      when 'relation'
        detail.value.to_s.empty? ? 'relation_removed' : 'relation_added'
      when 'attachment'
        detail.value.to_s.empty? ? 'attachment_removed' : 'attachment_added'
      when 'cf'
        'custom_field_changed'
      when 'attr'
        {
          'status_id' => 'status_changed',
          'assigned_to_id' => 'assignee_changed',
          'priority_id' => 'priority_changed',
          'category_id' => 'category_changed',
          'due_date' => 'due_date_changed',
          'start_date' => 'start_date_changed',
          'fixed_version_id' => 'version_changed',
          'subject' => 'subject_changed',
          'description' => 'description_changed',
          'parent_id' => 'parent_changed'
        }.fetch(detail.prop_key.to_s) do
          if detail.prop_key.to_s == 'child_id'
            detail.value.to_s.empty? ? 'child_removed' : 'child_added'
          else
            'issue_updated'
          end
        end
      else
        'issue_updated'
      end
    end
  end
end
