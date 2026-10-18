# frozen_string_literal: true

require 'securerandom'

module Slackmine
  module NotificationCoalescing
    class DeliveryUnavailable < StandardError; end

    module_function

    def window_seconds
      settings = Slackmine.effective_config.dig('slack', 'notification_coalescing')
      return 0 unless settings.is_a?(Hash) && settings['enabled'] == true

      seconds = settings['seconds']
      seconds.is_a?(Integer) && seconds.positive? ? [seconds, 300].min : 300
    end

    # A fixed window from the first post, never extended by subsequent edits.
    # Store rendered cards briefly in the existing cache; never store the token.
    def deliver(payload, project:, context:, actor_id:, channel:, token:, parts: nil)
      seconds = window_seconds
      eligible = seconds.positive? && context && context['issue_id'] &&
        Slackmine::EVENT_PATHS[context['event']]&.first == 'issue'
      return Slackmine.post_message(payload, channel, token) unless eligible

      key = "slackmine/notification-coalescing/v3/#{Digest::SHA256.hexdigest(token)}/#{project.id}/#{channel}/#{context['issue_id']}"
      key += "/thread/#{payload['thread_ts']}" if payload['thread_ts']
      lock_key = "#{key}/lock"
      owner = SecureRandom.hex(16)
      cache = Rails.cache
      locked = false
      begin
        raise DeliveryUnavailable, 'notification coalescing requires a shared cache' unless cache
        100.times do |attempt|
          locked = cache.write(lock_key, owner, unless_exist: true, expires_in: 300)
          break if locked
          sleep(0.05) if attempt < 99
        end
        raise DeliveryUnavailable, 'notification group is busy; retry delivery' unless locked
      rescue StandardError => e
        raise DeliveryUnavailable, "notification group unavailable: #{e.class}"
      end

      begin
        begin
          state = cache.read(key)
        rescue StandardError => e
          raise DeliveryUnavailable, "notification group could not be read: #{e.class}"
        end
        # Rendered file IDs/avatars can change when a job is retried. Identify
        # the source revision, rather than those optional presentation details.
        fingerprint = Digest::SHA256.hexdigest(JSON.generate(context))
        now = Time.now.to_f
        reusable = state.is_a?(Hash) &&
          state['thread_ts'] == payload['thread_ts'] &&
          now - state['started_at'].to_f < seconds &&
          state['ts'].to_s.match?(/\A\d+\.\d+\z/)
        return unless NotificationSafety.allowed?(context, project)
        sources = reusable ? state.fetch('sources') { [state] } : []
        retained = sources.select do |source|
          # Remove stale/private sources from the content, not the post ID.
          source['contexts'].all? do |previous|
            NotificationSafety.allowed?(previous.merge('issue_revision' => context['issue_revision']), project)
          end
        end
        if reusable && retained.length == sources.length && retained.any? { |source| source['fingerprints'].include?(fingerprint) }
          return { 'ok' => true, 'ts' => state['ts'] }
        end
        retained.reject! { |source| source['fingerprints'].include?(fingerprint) }
        current = { 'payload' => payload, 'parts' => parts, 'contexts' => [context], 'fingerprints' => [fingerprint] }
        retained << current
        outgoing, retained, omitted = fit_sources(retained, context, omitted: reusable && state['omitted'])

        begin
          result = if reusable
                     Slackmine.post_message(outgoing, channel, token, ts: state['ts'])
                   else
                     Slackmine.post_message(outgoing, channel, token)
                   end
        rescue SlackApiError => e
          # A deleted message or a workspace edit restriction starts a new
          # group. Transient/API failures propagate for the normal job retry.
          raise unless reusable && %w[message_not_found cant_update_message edit_window_closed].include?(e.code)

          reusable = false
          outgoing = payload
          result = Slackmine.post_message(payload, channel, token)
          retained = [current]
          omitted = false
        end
        next_state = {
          'actor_id' => actor_id, 'thread_ts' => payload['thread_ts'],
          'started_at' => reusable ? state['started_at'] : now,
          'ts' => reusable ? state['ts'] : result['ts'], 'payload' => outgoing,
          'sources' => retained, 'omitted' => omitted
        }
        begin
          saved = cache.write(key, next_state, expires_in: seconds)
          Rails.logger&.warn('Slackmine: notification group write was rejected') unless saved
        rescue StandardError => e
          # Delivery already succeeded; a cache failure must not duplicate it.
          Rails.logger&.warn("Slackmine: could not remember notification group: #{e.class}")
        end
        result
      ensure
        begin
          cache.delete(lock_key) if cache.read(lock_key) == owner
        rescue StandardError => e
          Rails.logger&.warn("Slackmine: could not release notification group: #{e.class}")
        end
      end
    end

    # Content limits may shorten the history, but never start another post.
    # Keep source boundaries so edited/private comments can be removed safely.
    def fit_sources(sources, context, omitted: false)
      loop do
        outgoing, = combine_sources(sources)
        outgoing = with_history_link(outgoing, context) if omitted
        return [outgoing, sources, omitted] if bounded?(outgoing)

        if sources.length > 1
          sources = sources.drop(1)
          omitted = true
        else
          latest = sources.first
          outgoing = latest['payload'].merge('attachments' => [latest['payload'].fetch('attachments').first.merge('blocks' => [])])
          outgoing = with_history_link(outgoing, context)
          raise DeliveryUnavailable, 'notification metadata exceeds message limits' unless bounded?(outgoing)

          compact = latest.merge('payload' => outgoing, 'parts' => nil)
          return [outgoing, [compact], true]
        end
      end
    end

    def combine_sources(sources)
      outgoing = sources.first['payload']
      parts = sources.first['parts']
      sources.drop(1).each do |source|
        if parts && source['parts']
          parts = merge_parts(parts, source['parts'])
          outgoing = render_parts(source['payload'], parts)
        else
          parts = nil
          outgoing = source['payload'].merge('attachments' => outgoing.fetch('attachments') + source['payload'].fetch('attachments'))
        end
      end
      [outgoing, parts]
    end

    def with_history_link(payload, context)
      link = Formatter.interpolate(Formatter.message('notification_coalescing', 'history'),
        { url: Formatter.url("/issues/#{context['issue_id']}"), id: context['issue_id'] },
        fallback: Formatter::DEFAULT_MESSAGES.dig('notification_coalescing', 'history'))
      attachments = Marshal.load(Marshal.dump(payload.fetch('attachments')))
      blocks = attachments.first['blocks'] ||= []
      notice = Formatter.section_text(link)
      blocks << notice unless blocks.include?(notice)
      payload.merge('attachments' => attachments)
    end

    # These internal roles survive avatar expansion, Work Object compaction
    # and image uploads, and are removed before anything reaches Slack.
    def extract_parts!(payload)
      changes = payload.delete('_slackmine_notification_changes')
      heading = payload.delete('_slackmine_notification_heading')
      parts = { 'header' => [], 'body' => [], 'metadata' => [], 'changes' => changes }
      parts['heading'] = heading if heading
      Array(payload['attachments']).each do |attachment|
        attachment['blocks'] = Array(attachment['blocks']).map do |source|
          block = source.dup
          role = block.delete('_slackmine_part') || 'body'
          parts[role] << block if parts.key?(role) && role != 'changes'
          block
        end
      end
      parts unless changes.nil? || Array(payload['attachments']).length != 1
    end

    def merge_parts(previous, current)
      changes = Marshal.load(Marshal.dump(previous['changes']))
      current['changes'].each do |entry|
        existing = changes.find { |item| item['key'] == entry['key'] }
        if existing && existing['values'] && entry['values']
          values = entry['values']
          values = values.drop(1) if existing['values'].last == values.first
          existing['values'].concat(values)
          existing['value'] = existing['values'].join(' → ')
        elsif existing && !existing['values'] && !entry['values']
          existing['value'] = "#{existing['value']}\n#{entry['value']}"
        else
          changes << Marshal.load(Marshal.dump(entry))
        end
      end
      header = if current['changes'].empty? && previous['changes'].any?
                 previous['header']
               else
                 current['header']
               end
      heading = current['heading']
      if previous['heading'] && heading && !current['header'].empty?
        heading = heading.merge('events' => (previous['heading']['events'] + heading['events']).uniq,
                                'actors' => (Array(previous['heading']['actors']) + Array(heading['actors'])).uniq)
        header = current['header'].dup
        header[0] = render_heading(header.first, heading)
      end
      bodies = [previous, current].flat_map do |part|
        part.fetch('body_sources') { [{ 'actor' => Array(part.dig('heading', 'actors')).first, 'blocks' => part['body'] }] }
      end
      mixed = heading && Array(heading['actors']).length > 1
      body = bodies.flat_map do |source|
        prefix = mixed && source['actor'] && source['blocks'].any? ? [Formatter.section_text("*#{Formatter.text(source['actor'])}*")] : []
        prefix + source['blocks']
      end
      { 'header' => header, 'body' => body, 'body_sources' => bodies,
        'changes' => changes, 'metadata' => current['metadata'], 'heading' => heading }
    end

    def render_heading(source, heading)
      template = heading['template'].gsub(Formatter::NOTIFICATION_EVENT_MARKER) { Formatter.text(heading['events'].join(' ＋ ')) }
      template = template.gsub(Formatter::NOTIFICATION_ACTOR_MARKER) { Formatter.text(Array(heading['actors']).join(' / ')) }
      segments = template.split(Formatter::AVATAR_MARKER, -1)
      image = Array(source['elements']).find { |element| element['type'] == 'image' }
      if source['type'] == 'context' && image
        elements = []
        segments.each_with_index do |segment, index|
          elements << image.dup if index.positive?
          elements << { 'type' => 'mrkdwn', 'text' => segment.strip } unless segment.strip.empty?
        end
        source.merge('elements' => elements)
      else
        source.merge('text' => source.fetch('text').merge('text' => segments.join.gsub(/[ \t]{2,}/, ' ').strip))
      end
    end

    def render_parts(payload, parts)
      blocks = parts['header'] + parts['body']
      if parts['changes'].any?
        blocks += [{ 'type' => 'divider' }, Formatter.section_text("*#{Formatter.text(Formatter.section_label('changes'))}*")]
        blocks += Formatter.change_field_blocks(parts['changes'].map { |entry| [entry['label'], entry['value']] })
      end
      blocks += parts['metadata']
      blocks = blocks.each_with_object([]) do |block, result|
        next if block['type'] == 'divider' && (result.empty? || result.last['type'] == 'divider')
        result << block
      end
      blocks.pop while blocks.last && blocks.last['type'] == 'divider'
      attachment = payload.fetch('attachments').first.merge('blocks' => blocks)
      payload.merge('attachments' => [attachment])
    end

    def bounded?(payload)
      attachments = Array(payload['attachments'])
      attachments.length <= 5 &&
        attachments.sum { |attachment| Array(attachment['blocks']).length } <= 45 &&
        attachments.all? do |attachment|
          Array(attachment['blocks']).all? do |block|
            (block['type'] != 'section' || block.dig('text', 'text').to_s.length <= 3000) &&
              Array(block['elements']).all? { |element| element['text'].to_s.length <= 3000 } &&
              Array(block['fields']).all? { |field| field['text'].to_s.length <= 2000 }
          end
        end &&
        JSON.generate(payload).bytesize <= 24_000
    end
  end
end
