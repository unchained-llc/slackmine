# frozen_string_literal: true
require_relative 'link_quotes_test'

class LinkCardsSecurityTest < LinkCardsTest
  def test_dm_shared_and_unverified_channels_never_fetch_message_text
    [ { 'is_im' => true }, { 'is_mpim' => true },
      { 'is_ext_shared' => true }, { 'is_shared' => true }, { 'is_org_shared' => true },
      { 'is_member' => false }, { 'is_private' => nil }, { 'id' => 'COTHER' } ].each do |flags|
      original = @channel
      @channel = original.merge(flags)
      @calls.clear
      assert_nil fetch, flags.inspect
      refute @calls.any? { |method, _| %w[conversations.history conversations.replies].include?(method) }
      @channel = original
    end
  end

  def test_private_channel_quotes_require_both_user_and_bot_membership_and_verified_identity
    url = URL.sub('C123', 'G123')
    @issue.description = url
    @channel.merge!('id' => 'G123', 'is_private' => true)
    card = fetch(url)
    refute_nil card
    assert_equal @message['text'], card['text']
    quote = Slackmine::LinkQuotes.encode(card, url)
    assert Slackmine::LinkQuotes.blocks(quote).first.last['verified']

    @members = ['UOTHER']
    @calls.clear
    assert_nil fetch(url)
    refute @calls.any? { |method, _| %w[conversations.history conversations.replies].include?(method) }

    @members = ['U123']
    @channel['is_member'] = false
    @calls.clear
    assert_nil fetch(url)
    refute @calls.any? { |method, _| %w[conversations.history conversations.replies].include?(method) }

    @channel['is_member'] = true
    @identity_allowed = false
    @calls.clear
    assert_nil fetch(url)
    refute @calls.any? { |method, _| %w[conversations.history conversations.replies].include?(method) }
  end

  def test_private_dm_and_group_dm_still_never_fetch_message_text
    @channel['is_private'] = true
    %w[is_im is_mpim].each do |flag|
      @channel[flag] = true
      @calls.clear
      assert_nil fetch
      refute @calls.any? { |method, _| %w[conversations.history conversations.replies].include?(method) }
      @channel.delete(flag)
    end
  end

  def test_nonmember_and_unmapped_identity_cannot_fetch_a_card
    @members = ['UOTHER']
    assert_nil fetch
    refute @calls.any? { |method, _| method == 'conversations.history' }
    @members = ['U123']
    @identity_allowed = false
    @calls.clear
    assert_nil fetch
    refute @calls.any? { |method, _| method == 'conversations.history' }
    Slackmine.stub(:slack_api, ->(*) { flunk 'Anonymous project fetch contacted Slack' }) do
      assert_nil CARDS.fetch_for_project(@issue.project, URL)
    end
  end

  def test_authorization_identity_uses_explicit_mapping_or_fresh_email_and_never_a_name_cache
    viewer = OpenStruct.new(login: 'alice', mail: 'alice@example.com')
    calls = []
    api = ->(method, body) { calls << [method, body]; { 'user' => { 'id' => 'U123' } } }
    Slackmine.stub(:config, { 'users' => { 'alice' => 'U456' } }) do
      assert_equal 'U456', CARDS.slack_identity(viewer, api)
      assert_empty calls
    end
    Slackmine.stub(:config, { 'slack' => { 'auto_map_users_by_email' => true } }) do
      assert_equal 'U123', CARDS.slack_identity(viewer, api)
      assert_equal [['users.lookupByEmail', { 'email' => 'alice@example.com' }]], calls
    end
    Slackmine.stub(:config, { 'slack' => { 'auto_map_users_by_email' => true }, 'users' => { 'alice' => false } }) do
      api = ->(*) { flunk 'Explicitly disabled identity must not fall back' }
      assert_nil CARDS.slack_identity(viewer, api)
    end
  end

  def test_private_channel_mentions_do_not_disclose_channel_names
    message = { 'text' => 'See <#GSECRET>', 'ts' => '1791115675.755579', 'username' => 'Alice' }
    api = ->(*) { { 'channel' => { 'id' => 'GSECRET', 'is_private' => true, 'name' => 'secret-customer' } } }
    card = CARDS.message_card(message, api)
    refute card['names'].key?('GSECRET')
    refute_includes CARDS.render_card(card, URL, @issue.project), 'secret-customer'
  end
end

class QuoteSecurityTest < Minitest::Test
  def setup
    @card = { 'author' => 'Alice', 'channel' => 'general', 'timestamp' => '2026-10-17T00:00:00Z',
              'avatar' => 'https://avatars.slack-edge.com/avatar.png', 'text' => 'Approved text',
              'thread_image_ids' => [41], 'thread_connection_nonce' => 'a' * 32 }
    @quote = Slackmine::LinkQuotes.encode(@card, LinkCardsTest::URL)
  end

  def card(quote = @quote)
    Slackmine::LinkQuotes.blocks(quote).first.last
  end

  def test_signature_survives_reload_and_mail_newlines_but_rejects_content_edits
    assert card['verified']
    assert card(@quote.gsub("\n", "\r\n"))['verified']
    altered = card(@quote.sub('Approved text', 'Forged text'))
    refute altered['verified']
    refute altered.key?('thread_image_ids')
    refute altered.key?('thread_connection_nonce')
    refute altered.key?('avatar')
    refute_includes Slackmine::LinkQuotes.plain_source(@quote.sub('Approved text', 'Forged text')), 'Alice'
  end

  def test_metadata_tampering_and_legacy_quotes_have_no_authenticated_identity_or_image
    match = Slackmine::LinkQuotes::PATTERN.match(@quote)
    data = JSON.parse(Base64.strict_decode64(match[1]))
    [false, true].each do |legacy|
      data['author'] = 'Forged CEO'
      data['avatar'] = 'https://attacker.example/track.png'
      data.delete('signature') if legacy
      changed = @quote.sub(match[1], Base64.strict_encode64(JSON.generate(data)))
      parsed = card(changed)
      refute parsed['verified']
      html = Slackmine::LinkCards.render_card(parsed, parsed['url'], nil)
      assert_includes html, 'Unverified quote'
      refute_includes html, 'Forged CEO'
      refute_includes html, 'attacker.example'
      assert_empty Nokogiri::HTML.fragment(html).css('img')
    end
  end

  def test_application_key_change_invalidates_quotes_and_arbitrary_images_are_rejected
    generator = Object.new
    generator.define_singleton_method(:generate_key) { |*| 'another-application-key' }
    Rails.application.stub(:key_generator, generator) { refute card['verified'] }
    ['https://attacker.example/track.png', 'https://avatars.slack-edge.com.attacker.example/a',
     'https://avatars.slack-edge.com@attacker.example/a', 'http://avatars.slack-edge.com/a',
     'https://avatars.slack-edge.com:8443/a'].each do |url|
      assert_nil Slackmine::LinkQuotes.safe_avatar(url)
    end
    assert_equal @card['avatar'], Slackmine::LinkQuotes.safe_avatar(@card['avatar'])
  end
end

class NotificationSecurityTest < Minitest::Test
  def setup
    @project = OpenStruct.new(id: 1, identifier: 'secure', active?: true)
    @issue = OpenStruct.new(id: 7, project: @project, is_private?: false,
                            subject: 'SECRET', custom_field_values: [], children: [], relations: [])
    @journal = OpenStruct.new(id: 8, journalized: @issue, private_notes?: false, details: [])
    @settings = { 'slack' => { 'bot_token' => 'test-token', 'default_channel_id' => 'C123' } }
    @sent = []
  end

  def context
    Slackmine.stub(:config, @settings) do
      Project.stub(:find_by, @project) do
        Issue.stub(:find_by, ->(id:) { @missing_issue ? nil : (id.to_s == '99' ? @related : @issue) }) do
          Journal.stub(:find_by, ->(**_) { @missing_journal ? nil : @journal }) do
            Slackmine.stub(:post_message, ->(*args) { @sent << args }) { yield }
          end
        end
      end
    end
  end

  def payload
    { 'text' => 'Queued content', '_slackmine_delivery_context' =>
      Slackmine::NotificationSafety.context(@project, 'comment_added', 7, 8, source: @journal) }
  end

  def perform(message)
    SlackmineNotificationJob.new.perform(message, 1)
  end

  def test_unchanged_public_source_is_sent_and_internal_context_is_not_posted
    context do
      perform(payload)
      assert_equal 1, @sent.size
      refute @sent.first.first.key?('_slackmine_delivery_context')
    end
  end

  def test_newly_private_issue_or_comment_moved_issue_and_changed_channel_never_send
    [-> { @issue[:is_private?] = true }, -> { @journal[:private_notes?] = true },
     -> { @issue.project = OpenStruct.new(id: 2) }, -> { @settings['slack']['default_channel_id'] = 'COTHER' },
     -> { @settings['slack']['bot_token'] = 'another-token' }, -> { @project[:active?] = false },
     -> { @settings['events'] = { 'comment_added' => false } }].each do |change|
      setup
      context do
        message = payload
        change.call
        perform(message)
        assert_empty @sent
      end
    end
  end

  def test_deleted_sources_and_legacy_jobs_do_not_send
    context do
      message = payload
      @missing_issue = true
      perform(message)
      @missing_issue = false
      @missing_journal = true
      perform(message)
      @missing_journal = false
      perform('text' => 'Legacy unguarded content')
      assert_empty @sent
    end
  end

  def test_edited_source_cancels_stale_text_in_the_queue
    @issue.updated_on = Time.utc(2026, 10, 17, 0, 0, 0)
    @journal.updated_on = @issue.updated_on
    context do
      message = payload
      @journal.updated_on += 1
      perform(message)
      assert_empty @sent
      message = payload
      @issue.updated_on += 1
      perform(message)
      assert_empty @sent
    end
  end

  def test_privacy_changed_during_profile_lookup_is_rechecked_before_posting
    context do
      message = payload.merge('_slackmine_actor_id' => 3)
      Slackmine.stub(:with_notification_avatar, ->(body, *_, **_) { @issue[:is_private?] = true; body }) do
        perform(message)
      end
      assert_empty @sent
    end
  end

  def test_changed_custom_field_or_related_issue_visibility_cancels_a_queued_message
    field = OpenStruct.new(id: 42, visible?: true)
    @issue.custom_field_values = [OpenStruct.new(custom_field: field)]
    context do
      CustomField.stub(:find_by, field) do
        message = payload
        field[:visible?] = false
        perform(message)
        assert_empty @sent
      end
      @related = OpenStruct.new(id: 99, project: @project, is_private?: false)
      @issue.children = [@related]
      message = payload
      @related[:is_private?] = true
      perform(message)
      assert_empty @sent
    end
  end

  def test_private_and_cross_project_related_subjects_are_never_formatted
    detail = OpenStruct.new(property: 'relation', prop_key: 'relates', old_value: nil, value: '7')
    context do
      @issue[:is_private?] = true
      assert_empty Slackmine::Formatter.change_fields(OpenStruct.new(project: @project), [detail])
      @issue[:is_private?] = false
      assert_empty Slackmine::Formatter.change_fields(OpenStruct.new(project: OpenStruct.new(id: 2)), [detail])
      refute_includes Slackmine::Formatter.relation_issue_link(7), 'SECRET'
      assert_includes Slackmine::Formatter.change_fields(OpenStruct.new(project: @project), [detail]).to_s, 'SECRET'
    end
  end

  def test_role_restricted_fields_are_not_exported_even_with_hidden_changes_enabled
    detail = OpenStruct.new(property: 'cf', prop_key: '42', old_value: 'SECRET_OLD', value: 'SECRET_NEW')
    field = OpenStruct.new(id: 42, name: 'Restricted', visible?: false)
    context do
      CustomField.stub(:find_by, field) do
        assert_empty Slackmine::Formatter.visible_issue_changes([detail])
        assert_empty Slackmine::Formatter.change_fields(@issue, [detail])
      end
    end
  end
end

class SlashSearchSecurityTest < Minitest::Test
  def test_dm_search_uses_requester_visibility_and_rechecks_each_result
    viewer = OpenStruct.new(id: 3)
    scope = Object.new
    calls = []
    %i[where order limit].each { |method| scope.define_singleton_method(method) { |*args| calls << [method, args]; self } }
    issue = OpenStruct.new(project: OpenStruct.new, subject: 'FORBIDDEN')
    issue.define_singleton_method(:visible?) { |user| raise 'Wrong identity' unless user.equal?(viewer); false }
    scope.define_singleton_method(:to_a) { [issue] }
    added_visible = !Issue.respond_to?(:visible)
    added_sanitize = !Issue.respond_to?(:sanitize_sql_like)
    Issue.define_singleton_method(:visible) { |_| nil } if added_visible
    Issue.define_singleton_method(:sanitize_sql_like) { |value| value } if added_sanitize
    Slackmine::WorkObjects.stub(:viewer_for, viewer) do
      Issue.stub(:visible, ->(user) { assert_same viewer, user; scope }) do
        Slackmine::SlashCommands.stub(:authorized_project?, true) do
          result = Slackmine::SlashCommands.run('ATEST', 'TTEST', 'U123', 'D123', 'search text') { flunk 'Forbidden single result rendered' }
          refute_includes result.to_json, 'FORBIDDEN'
          assert_equal 'LOWER(issues.subject) LIKE ?', calls.first.last.first
          assert_equal '%text%', calls.first.last.last
        end
      end
    end
  ensure
    Issue.singleton_class.remove_method(:visible) if added_visible
    Issue.singleton_class.remove_method(:sanitize_sql_like) if added_sanitize
  end
end
