# frozen_string_literal: true

module Slackmine
  module ThreadComments
    module_function

    class InvalidPermalink < StandardError; end

    def enabled?(project)
      Slackmine.effective_config(project).dig('slack', 'thread_comments') == true
    end

    def reply_event?(event)
      event.is_a?(Hash) && event['type'] == 'message' &&
        [nil, '', 'thread_broadcast', 'file_share'].include?(event['subtype']) &&
        !event['bot_id'] && !event['app_id'] && !event['edited'] &&
        event['user'].to_s.match?(/\A[UW][A-Z0-9]+\z/) &&
        event['channel'].to_s.match?(/\A[CG][A-Z0-9]+\z/) &&
        event['thread_ts'].to_s.match?(/\A\d+\.\d+\z/) &&
        posted_at(event['ts']) && event['ts'] != event['thread_ts'] &&
        (event['text'].nil? || event['text'].is_a?(String)) &&
        (!event['text'].to_s.strip.empty? || Array(event['files']).any?)
    end

    def contexts(app_id, team_id, channel)
      base = Slackmine.config
      candidates = [nil]
      projects = base['projects']
      candidates.concat(projects.keys.map { |key| Project.find_by(identifier: key) }.compact) if projects.is_a?(Hash)
      auto_scopes = [base] + (projects.is_a?(Hash) ? projects.values.select { |value| value.is_a?(Hash) } : [])
      if auto_scopes.any? { |scope| scope.dig('slack', 'auto_map_channels_by_name') == true }
        candidates.concat(Project.active.to_a)
      end
      candidates.uniq.select do |project|
        settings = Slackmine.effective_config(project)
        slack = settings['slack']
        events = slack['events'] if slack.is_a?(Hash)
        configured_channel = project ? Slackmine.channel_id(project) : (slack['default_channel_id'] if slack.is_a?(Hash))
        slack.is_a?(Hash) && slack['thread_comments'] == true && events.is_a?(Hash) &&
          events['app_id'] == app_id && events['team_id'] == team_id && configured_channel == channel
      end
    end

    def accepted_reply?(app_id, team_id, event)
      return false unless reply_event?(event)
      return true if ThreadConnections.receives?(app_id, team_id)
      !contexts(app_id, team_id, event['channel']).empty?
    end

    def addressed_to_bot?(event, project, cache: {})
      ids = event['text'].to_s.scan(/<@([UW][A-Z0-9]+)(?:\|[^>]+)?>/).flatten.uniq
      ids.any? do |id|
        unless cache.key?(id)
          member = Slackmine.slack_api('users.info', { 'user' => id }, Slackmine.bot_token(project),
                                      form: true, open_timeout: 2, read_timeout: 3)['user']
          # Do not import a Bot request when its recipient could not be verified.
          raise IOError, 'Slack mention identity unavailable' unless member.is_a?(Hash) && member['id'] == id
          cache[id] = member['is_bot'] == true || member['is_app_user'] == true
        end
        cache[id]
      end
    end

    def issue_from_parent(message, app_id, thread_ts)
      return unless message.is_a?(Hash) && message['ts'] == thread_ts && message['bot_id'] &&
                    (message['app_id'] || message.dig('bot_profile', 'app_id')) == app_id
      # Accept our subject section or our own Work Object unfurl. Never scan
      # user comments or arbitrary links for a target Issue.
      Array(message['attachments']).each do |attachment|
        next unless attachment.is_a?(Hash)
        if attachment['is_app_unfurl'] == true && attachment['app_id'] == app_id &&
           attachment['bot_id'] == message['bot_id']
          url = attachment['from_url'].to_s
          id = url.match(%r{/issues/([1-9]\d*)\z})
          if id && url == Formatter.url("/issues/#{id[1]}") && attachment['title_link'] == url
            return Issue.find_by(id: id[1].to_i)
          end
        end
        subject = attachment.dig('blocks', 1, 'text', 'text').to_s
        match = subject.match(/\A\*<([^|>]+)\|/)
        next unless match
        url = match[1]
        id = url.match(%r{/issues/([1-9]\d*)\z})
        next unless id && url == Formatter.url("/issues/#{id[1]}")
        return Issue.find_by(id: id[1].to_i)
      end
      issue_from_history_unfurl(message)
    end

    def issue_from_history_unfurl(message)
      # conversations.history may reduce an entity unfurl to from_url/id.
      # The parent app/bot was authenticated above. Bind this reduced URL to
      # the first Issue reference in our notification fallback, never notes.
      attachments = Array(message['attachments']).select { |item| item.is_a?(Hash) }
      notification = attachments.find { |item| item['blocks'].is_a?(Array) && item['fallback'].is_a?(String) }
      reference = notification && notification['fallback'].match(/(?:\A|\s)#([1-9]\d*):/)
      return unless reference

      urls = attachments.select { |item| (item.keys - %w[from_url id]).empty? }
                        .map { |item| item['from_url'] }.compact.uniq
      return unless urls == [Formatter.url("/issues/#{reference[1]}")]

      Issue.find_by(id: reference[1].to_i)
    end

    def process(app_id, team_id, event, batch_ready: false)
      return unless reply_event?(event)
      if ThreadConnections.receives?(app_id, team_id)
        return :ignored if addressed_to_bot?(event, nil)
        source = { 'channel' => event['channel'], 'ts' => event['thread_ts'] }
        connection = ThreadState.connection(app_id, team_id, source)
        return ThreadConnections.process_reply(connection, app_id, team_id, event) if connection
      end
      tried_tokens = []
      contexts(app_id, team_id, event['channel']).each do |context|
        token = Slackmine.bot_token(context)
        next if token.to_s.empty? || tried_tokens.include?(token)
        tried_tokens << token
        response = Slackmine.slack_api('conversations.history', {
          'channel' => event['channel'], 'oldest' => event['thread_ts'], 'latest' => event['thread_ts'],
          'inclusive' => true, 'limit' => 1
        }, token, form: true)
        issue = issue_from_parent(Array(response['messages']).first, app_id, event['thread_ts'])
        next unless issue && enabled?(issue.project) &&
                    Slackmine.channel_id(issue.project) == event['channel'] &&
                    WorkObjects.integration_for(app_id, team_id, project: issue.project) &&
                    Slackmine.bot_token(issue.project) == token

        Slackmine.with_project(issue.project) do
          return :ignored if addressed_to_bot?(event, issue.project)

          wait = ThreadCommentBatch.timing(issue.project).first
          unless batch_ready || wait.zero?
            previous = ThreadCommentBatch.previous_turn(issue, event)
            save_batch(issue, previous, team_id) if previous
            return ThreadCommentBatch.schedule(app_id, team_id, event, wait)
          end
          events = batch_ready ? ThreadCommentBatch.collect(issue, app_id, team_id, event) : [event]
          return :waiting unless events
          return :ignored if events.empty?
          return save_batch(issue, events, team_id)
        end
        return
      end
      nil
    end

    def save_batch(issue, events, team_id)
      result = if events.size == 1
                 persist_reply(issue, events.first, team_id)
               else
                 persist_reply(issue, events.first, team_id, events: events)
               end
      # A duplicate never creates a second Journal or a second feedback post.
      feedback(issue, events.first, result) if result != :duplicate
      result
    end

    def feedback(issue, event, result)
      key = result == :saved ? 'saved' : (result == :image_failed ? 'image_failed' : 'restricted')
      text = Formatter.interpolate(Formatter.message('thread_comments', key), { id: issue.id, product_name: Formatter.message('work_objects', 'product_name') },
                                   fallback: Formatter::DEFAULT_MESSAGES.dig('thread_comments', key))
      text = Formatter.link_issue_reference(text, issue.id)
      ThreadFeedback.post(issue.project, event['channel'], event['thread_ts'], text, 'comment', source_ts: event['ts'])
    rescue StandardError => e
      # Saving already succeeded. Feedback failure must not replay a note.
      Rails.logger&.error("Slackmine: thread comment feedback failed: #{e.class}")
    ensure
      Rails.logger&.info("Slackmine: thread comment issue=#{issue.id} result=#{result}")
    end

    def posted_at(timestamp)
      match = timestamp.to_s.match(/\A(\d{1,12})\.(\d{1,6})\z/)
      return unless match
      # Parse integers, not a Float: current epoch values lose microseconds
      # when converted through floating point.
      Time.at(match[1].to_i, match[2].ljust(6, '0').to_i, :microsecond).utc
    end

    def persist_reply(issue, event, team_id, events: [event], connected: false, import_viewer: nil, history_cards: nil, import_timestamp: nil)
      previous_user = User.current
      previous_origin = Thread.current[:slackmine_thread_comment]
      previous_files = Thread.current[:slackmine_thread_files]
      previous_images = Thread.current[:slackmine_thread_images]
      previous_messages = Thread.current[:slackmine_thread_messages]
      original_project = issue.project.identifier
      token = nil
      persistence_started = false
      Thread.current[:slackmine_thread_comment] = true
      uploads = []
      event = event.merge('text' => events.map { |item| item['text'].to_s }.join("\n\n"),
                          'files' => events.flat_map { |item| Array(item['files']) }.uniq)
      timestamp = history_cards ? (import_timestamp || Time.now.utc) : posted_at(event['ts'])
      return :restricted unless timestamp
      if issue.class.respond_to?(:connection) && issue.class.connection.transaction_open?
        raise 'Thread import cannot run inside an outer database transaction'
      end

      result = issue.with_lock do
        next :restricted unless issue.project.identifier == original_project &&
          (connected ? ThreadConnections.enabled?(issue.project) : enabled?(issue.project))
        viewer = import_viewer || WorkObjects.viewer_for(event['user'])
        allowed = viewer && issue.project.active? && !issue.is_private? && issue.visible?(viewer) &&
                  issue.notes_addable?(viewer) && event['text'].to_s.length <= (history_cards ? ThreadConnections::MAX_HISTORY_TEXT : 10_000)
        next :restricted unless allowed
        restrict_transfer = Slackmine.files_transfer_restricted?(issue.project)
        next :restricted if !restrict_transfer && Array(event['files']).any? && !issue.attachments_addable?(viewer)

        ThreadState.recover(issue, team_id, events)
        token, indices = ThreadState.claim(issue.id, team_id, events)
        next :duplicate if indices.empty?
        events = indices.map { |index| events[index] }
        history_cards = indices.map { |index| history_cards[index] } if history_cards
        timestamp = posted_at(events.first['ts']) unless history_cards
        event = events.first.merge('text' => events.map { |item| item['text'].to_s }.join("\n\n"),
                                   'files' => events.flat_map { |item| Array(item['files']) }.uniq)
        urls = events.map do |item|
          response = Slackmine.slack_api('chat.getPermalink',
            { 'channel' => item['channel'], 'message_ts' => item['ts'] },
            Slackmine.bot_token(issue.project), form: true)
          url = response['permalink'].to_s
          target = LinkCards.parse(url)
          unless target && target['channel'] == item['channel'] && posted_at(target['ts']) == posted_at(item['ts'])
            raise InvalidPermalink
          end
          # Keep the thread timestamp so quote retrieval uses replies API.
          uri = URI.parse(url)
          uri.query = URI.encode_www_form(URI.decode_www_form(uri.query.to_s).reject { |key, _| key == 'thread_ts' } +
                                         [['thread_ts', item['thread_ts']]])
          uri.to_s
        end
        notes = history_cards ? ThreadConnections.message('history_heading', project: issue.project) : urls.join("\n\n")
        User.current = viewer
        journal = issue.init_journal(viewer, notes)
        unless restrict_transfer
          uploads = Slackmine.with_project(issue.project) do
            ThreadFiles.download(event, Slackmine.bot_token(issue.project))
          end
        end
        # The Issue row lock's transaction includes both attachments and Journal.
        # Validate every file before saving any, then use the Issue association
        # so Redmine records attachment additions in this same Journal.
        attachments = uploads.map { |file| Attachment.new(file: file, author: viewer) }
        attachments.each { |attachment| raise ActiveRecord::RecordInvalid.new(attachment) unless attachment.valid? }
        attachments.each do |attachment|
          attachment.save!
          issue.attachments << attachment
        end
        unless attachments.empty?
          references = attachments.map do |attachment|
            path = attachment.filename
            unless ThreadFiles::TYPES.key?(attachment.content_type)
              next %Q(attachment:"#{path}")
            end
            Setting.text_formatting == 'textile' ? "!#{path}!" : "![](#{path})"
          end
          journal.notes = notes + "\n\n" + references.join("\n\n")
        end
        journal.created_on = timestamp
        # A new imported note is not an edit. Redmine displays "edited" when
        # updated_on differs from created_on; later edits keep normal timestamps.
        journal.updated_on = timestamp
        image_maps = []
        file_maps = []
        events.zip(urls).each do |item, url|
          file_ids = Array(item['files']).map { |file| file['id'] }
          own = attachments.select { |attachment| file_ids.any? { |id| attachment.filename.start_with?("#{id}-") } }
          image_maps << { url: url, ids: own.select { |a| ThreadFiles::TYPES.key?(a.content_type) }.map(&:id) }
          file_maps << { url: url, ids: own.reject { |a| ThreadFiles::TYPES.key?(a.content_type) }.map(&:id) }
        end
        if history_cards
          # Encode individual speakers as separate snapshots inside ONE Journal.
          # Saved quotes render without a fresh API fetch and remain searchable.
          quotes = history_cards.each_with_index.map do |entry, index|
            card = entry['card'].dup
            card['thread_image_ids'] = image_maps[index][:ids] unless image_maps[index][:ids].empty?
            card['thread_file_ids'] = file_maps[index][:ids] unless file_maps[index][:ids].empty?
            LinkQuotes.encode(card, urls[index], project: issue.project)
          end
          journal.notes = notes + "\n\n" + quotes.join("\n\n")
          journal.notes += "\n\n" + references.join("\n\n") unless attachments.empty?
        end
        Thread.current[:slackmine_thread_images] = events.size == 1 ? image_maps.first : image_maps
        Thread.current[:slackmine_thread_files] = events.size == 1 ? file_maps.first : file_maps
        # Batch history already supplied each message. Quote those snapshots
        # instead of fetching every reply again within the import time budget.
        Thread.current[:slackmine_thread_messages] = events.zip(urls).map { |item, url| { url: url, message: item } } if events.size > 1
        persistence_started = true
        issue.save!
        raise 'Slack reply Journal was not persisted' unless journal.persisted?
        token = ThreadState.record_journal(issue.id, team_id, events, token, journal.id)
        :saved
      end
      # Keep the claim pending until the transaction has committed. An
      # uncertain outcome remains pending rather than creating a duplicate.
      ThreadState.finish(issue.id, team_id, events, token) if result == :saved
      result
    rescue ThreadFiles::ImportError => error
      ThreadState.release(issue.id, team_id, events, token)
      Rails.logger&.warn("Slackmine: thread file rejected: #{error.message}")
      :image_failed
    rescue ActiveRecord::RecordInvalid
      ThreadState.release(issue.id, team_id, events, token)
      :restricted
    rescue InvalidPermalink
      ThreadState.release(issue.id, team_id, events, token)
      :restricted
    rescue StandardError
      ThreadState.release(issue.id, team_id, events, token) unless persistence_started
      raise
    ensure
      uploads.each(&:close!) if uploads
      User.current = previous_user
      Thread.current[:slackmine_thread_comment] = previous_origin
      Thread.current[:slackmine_thread_images] = previous_images
      Thread.current[:slackmine_thread_files] = previous_files
      Thread.current[:slackmine_thread_messages] = previous_messages
    end
  end
end
