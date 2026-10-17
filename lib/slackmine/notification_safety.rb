# frozen_string_literal: true
require 'digest'
require 'time'

module Slackmine
  module NotificationSafety
    module_function

    # Queue references and security state alongside the preformatted content.
    # Old jobs without this context cannot safely establish their audience.
    def context(project, event, issue_id, journal_id, source: nil)
      journal = source if source && source.respond_to?(:journalized)
      journal ||= Journal.find_by(id: journal_id) if journal_id
      issue = source if source && source.respond_to?(:is_private?) && !journal
      issue ||= journal&.journalized || (Issue.find_by(id: issue_id) if issue_id)
      return if (journal_id && !journal) || (issue_id && !issue && event != 'issue_deleted')
      issue_event = Slackmine::EVENT_PATHS[event]&.first == 'issue'
      return if issue_event && !issue && !(event == 'issue_deleted' && issue_id)
      return if issue && (issue.is_private? || issue.project != project)
      return if journal && journal.private_notes?

      fields = issue && issue.respond_to?(:custom_field_values) ? issue.custom_field_values.map(&:custom_field) : []
      if journal
        fields += journal.details.select { |detail| detail.property == 'cf' }.map { |detail| CustomField.find_by(id: detail.prop_key) }
      end
      related = []
      if issue
        related << issue.parent if issue.respond_to?(:parent)
        related.concat(issue.children.first(20)) if issue.respond_to?(:children)
        related.concat(issue.relations.first(20).map { |relation| relation.other_issue(issue) }) if issue.respond_to?(:relations)
      end
      if journal
        journal.details.each do |detail|
          next unless detail.property == 'relation' || (detail.property == 'attr' && %w[parent_id child_id].include?(detail.prop_key))
          [detail.old_value, detail.value].each { |id| related << Issue.find_by(id: id) if id.to_s.match?(/\A[1-9]\d*\z/) }
        end
      end
      { 'version' => 1, 'event' => event, 'issue_id' => issue&.id || issue_id, 'journal_id' => journal_id,
        'issue_revision' => revision(issue), 'journal_revision' => revision(journal),
        'channel' => Slackmine.channel_id(project), 'token_hash' => Digest::SHA256.hexdigest(Slackmine.bot_token(project)),
        'public_field_ids' => fields.select { |field| Formatter.public_custom_field?(field) }.map(&:id).uniq,
        'related_ids' => related.compact.select { |item| !item.is_private? && item.project == project }.map(&:id).uniq }
    end

    def allowed?(context, project)
      return false unless context.is_a?(Hash) && context['version'] == 1 && project.active?
      return false if context['event'] && !Slackmine.event_enabled?(project, context['event'])
      return false unless context['channel'] == Slackmine.channel_id(project) &&
                          context['token_hash'] == Digest::SHA256.hexdigest(Slackmine.bot_token(project))
      if context['issue_id']
        issue = Issue.find_by(id: context['issue_id'])
        return false unless issue ? !issue.is_private? && issue.project == project : context['event'] == 'issue_deleted'
        return false if issue && revision(issue) != context['issue_revision']
      end
      if context['journal_id']
        journal = Journal.find_by(id: context['journal_id'])
        return false unless journal && !journal.private_notes? && journal.journalized == issue
        return false unless revision(journal) == context['journal_revision']
      end
      return false unless Array(context['public_field_ids']).all? { |id| Formatter.public_custom_field?(CustomField.find_by(id: id)) }
      Array(context['related_ids']).all? do |id|
        related = Issue.find_by(id: id)
        related && !related.is_private? && related.project == project
      end
    end

    def revision(record)
      record.updated_on&.utc&.iso8601(6) if record && record.respond_to?(:updated_on)
    end
  end
end
