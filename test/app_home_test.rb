# frozen_string_literal: true

require_relative 'message_shortcuts_test'
require_relative '../app/jobs/slackmine_app_home_job'

class IssueQuery
end unless defined?(IssueQuery)

class Issue
  def self.visible(*)
  end unless respond_to?(:visible)
end

class Journal
  def self.visible(*)
  end unless respond_to?(:visible)
end

class Watcher
  def self.where(*)
  end
end unless defined?(Watcher)

class AppHomeTest < Minitest::Test
  HOME = Slackmine::AppHome
  WORK = Slackmine::WorkObjects

  class Scope
    attr_reader :calls
    def initialize(rows = [])
      @rows, @calls = rows, []
    end
    %i[where order includes limit select].each do |method|
      define_method(method) { |*args| @calls << [method, args]; self }
    end
    def open
      @calls << [:open, []]
      self
    end
    def to_a
      @rows
    end
  end

  class FakeIssueQuery
    attr_accessor :column_names, :sort_criteria
    attr_reader :filters, :options
    def initialize
      @filters = {}
    end
    def add_filter(key, operator, values)
      @filters[key] = [operator, values]
    end
    def issues(**options)
      @options = options
      []
    end
  end

  def setup
    @settings = { 'slack' => { 'app_home' => true, 'bot_token' => 'token',
      'events' => { 'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'test-secret' } } }
    @viewer = OpenStruct.new(id: 3)
    @project = OpenStruct.new(id: 9, identifier: 'example', name: 'Example', active?: true)
    @issue = OpenStruct.new(id: 7, project: @project, subject: '<unsafe & title>', status: OpenStruct.new(name: 'Open'),
                           due_date: Date.new(2026, 10, 5), visible?: true, is_private?: false)
    @issue.define_singleton_method(:visible?) { |*_args| true }
  end

  def home_action(action = 'refresh', value = 'all')
    { 'type' => 'block_actions', 'api_app_id' => 'ATEST', 'team' => { 'id' => 'TTEST' },
      'user' => { 'id' => 'U123' }, 'trigger_id' => 'fresh-trigger',
      'view' => { 'type' => 'home', 'callback_id' => 'slackmine_home', 'private_metadata' => 'all' },
      'actions' => [{ 'action_id' => HOME::PREFIX + action, 'value' => value }] }
  end

  def test_enabled_requires_shared_opt_in_app_team_secret_and_token
    Slackmine.stub(:config, @settings) do
      assert HOME.enabled?('ATEST', 'TTEST')
      refute HOME.enabled?('OTHER', 'TTEST')
      refute HOME.enabled?('ATEST', 'OTHER')
      @settings['slack']['app_home'] = false
      refute HOME.enabled?('ATEST', 'TTEST')
      @settings['slack']['app_home'] = true
      @settings['slack']['events'].delete('signing_secret')
      WORK.stub(:integration_for, nil) { refute HOME.enabled?('ATEST', 'TTEST') }
      @settings['slack']['events']['signing_secret'] = 'test-secret'
      Slackmine.stub(:bot_token, '') { refute HOME.enabled?('ATEST', 'TTEST') }
    end
  end

  def test_unmapped_user_publishes_no_issue_data_and_restores_project_context
    calls = []
    Slackmine.stub(:config, @settings) do
      WORK.stub(:viewer_for, nil) do
        HOME.stub(:allowed_projects, ->(*) { flunk 'queried projects for unmapped viewer' }) do
          Slackmine.stub(:slack_api, ->(*args, **options) { calls << [args, options] }) do
            Slackmine.with_project(@project) do
              HOME.publish('ATEST', 'TTEST', 'U123')
              assert_equal @project, Thread.current[:slackmine_project]
            end
            HOME.publish('ATEST', 'TTEST', 'not-a-user')
            HOME.publish('ATEST', 'TTEST', 'U123', 'untrusted')
          end
        end
      end
    end
    assert_equal 1, calls.length
    assert_equal 'views.publish', calls.first[0][0]
    assert_equal 'U123', calls.first[0][1]['user_id']
    assert_includes calls.first[0][1].to_json, 'not linked'
    assert_equal true, calls.first[1][:form]
  end

  def test_only_active_matching_enabled_projects_with_same_identity_are_selected
    projects = [@project, OpenStruct.new(id: 10, identifier: 'disabled', active?: true),
      OpenStruct.new(id: 11, identifier: 'other_app', active?: true),
      OpenStruct.new(id: 12, identifier: 'other_user', active?: true),
      OpenStruct.new(id: 13, identifier: 'inactive', active?: false)]
    @settings['projects'] = {
      'disabled' => { 'slack' => { 'app_home' => false } },
      'other_app' => { 'slack' => { 'events' => { 'app_id' => 'OTHER' } } },
      'other_user' => { 'users' => { 'another-user' => 'U123' } }
    }
    scope = Scope.new(projects)
    Slackmine.stub(:config, @settings) do
      Project.stub(:allowed_to, scope) do
        WORK.stub(:viewer_for, ->(*) { Thread.current[:slackmine_project].id == 12 ? OpenStruct.new(id: 99) : @viewer }) do
          assert_equal [9], HOME.allowed_projects(@viewer, 'ATEST', 'TTEST', 'U123')
        end
      end
    end
    assert_includes scope.calls, [:where, [{ status: Project::STATUS_ACTIVE }]]
  end

  def test_group_limits_issues_and_preserves_literal_text
    scope = Scope.new(Array.new(11, @issue))
    blocks = []
    HOME.add_group(blocks, 'updated', scope)
    table = blocks.last
    assert_equal 'data_table', table['type']
    assert_equal 10, table['rows'].drop(1).length
    assert_includes table['caption'], '10+'
    assert_includes table['rows'][1][0].dig('elements', 0, 'elements', 0, 'text'), '<unsafe & title>'
    assert_equal '7', table['rows'][1][4].dig('element', 'value')
    assert_equal ['divider', 'data_table'], blocks.map { |block| block['type'] }
    assert_equal 5, table['page_size']
    assert_includes scope.calls, [:limit, [11]]
  end

  def test_issue_metadata_supports_users_groups_and_unassigned_issues
    [OpenStruct.new(name: 'Alice'), OpenStruct.new(name: 'Support group'), nil].each do |assignee|
      @issue.assigned_to = assignee
      scope = Scope.new([@issue])
      blocks = []
      HOME.add_group(blocks, 'reported', scope)
      row = blocks.last['rows'][1]
      expected = assignee ? assignee.name : Slackmine::Formatter.message('values', 'unassigned')
      assert_equal @issue.status.name, row[1]['text']
      assert_equal expected, row[2]['text']
      assert_equal @issue.due_date.iso8601, row[3]['text']
      assert_equal "\n#{@issue.project.name}", row[0].dig('elements', 0, 'elements', 1, 'text')
      assert_equal 5, row.length
      assert_includes scope.calls, [:includes, [:project, :status, :assigned_to]]
    end
    @issue.due_date = nil
    blocks = []
    HOME.add_group(blocks, 'my', [@issue])
    assert_includes blocks.last['rows'][1][3]['text'], '—'
  end

  def test_title_is_a_browser_link_and_edit_is_in_the_last_column
    other = @issue.dup
    other.id = 8
    blocks = []
    HOME.add_group(blocks, 'my', [@issue, other])
    edit_label = Slackmine::Formatter.message('work_objects', 'edit_issue')
    blocks.last['rows'].drop(1).zip([@issue, other]).each do |row, issue|
      link = row[0].dig('elements', 0, 'elements', 0)
      assert_equal 'link', link['type']
      assert_equal Slackmine::Formatter.url("/issues/#{issue.id}"), link['url']
      assert_equal "##{issue.id} #{issue.subject}", link['text']
      assert_equal true, link.dig('style', 'bold')
      assert_equal 'action_cell', row[4]['type']
      edit = row[4]['element']
      assert_equal "slackmine_home_detail_#{issue.id}", edit['action_id']
      assert_equal issue.id.to_s, edit['value']
      assert_equal edit_label, edit.dig('text', 'text')
      assert_equal edit_label, row[4].dig('fallback', 'text')
      refute edit.key?('url')
    end
    @issue.subject = "\u9577" * 300
    blocks.clear
    HOME.add_group(blocks, 'my', [@issue])
    assert_equal 200, blocks.last['rows'][1][0].dig('elements', 0, 'elements', 0, 'text').length
  end

  def test_four_full_tables_stay_within_slacks_total_cell_character_limit
    @issue.subject = 'x' * 1000
    @issue.project.name = 'x' * 1000
    @issue.status.name = 'x' * 1000
    @issue.assigned_to = OpenStruct.new(name: 'x' * 1000)
    blocks = []
    formatter = Slackmine::Formatter
    formatter.stub(:field_label, 'x' * 1000) do
      formatter.stub(:message, 'x' * 1000) do
        %w[updated this_week my reported].each do |key|
          HOME.add_group(blocks, key, Scope.new(Array.new(11, @issue)))
        end
      end
    end
    cells = blocks.select { |block| block['type'] == 'data_table' }.flat_map { |block| block['rows'].flatten }
    length = cells.sum do |cell|
      case cell['type']
      when 'rich_text' then cell['elements'].sum { |section| section['elements'].sum { |element| element['text'].length } }
      when 'action_cell' then cell.dig('element', 'text', 'text').length
      else cell['text'].length
      end
    end
    assert_operator length, :<=, 20_000
  end

  def test_empty_group_shows_only_one_heading_and_the_empty_message
    blocks = []
    HOME.add_group(blocks, 'updated', Scope.new)
    assert_equal ['divider', 'section', 'section'], blocks.map { |block| block['type'] }
    assert_includes blocks.last.dig('text', 'text'), HOME.message('empty')
  end

  def test_list_edit_button_routes_to_existing_permission_checked_modal
    calls = []
    HOME.stub(:open_detail, ->(*args) { calls << args }) do
      HOME.interaction('ATEST', 'TTEST', home_action('detail_7', '7'))
      HOME.interaction('ATEST', 'TTEST', home_action('detail_bad', '7'))
    end
    assert_equal [['ATEST', 'TTEST', 'U123', '7', 'fresh-trigger', 'all']], calls
  end

  def test_control_block_id_changes_with_filter_to_avoid_preserved_stale_selection
    all = HOME.view(nil, 'ATEST', 'TTEST', 'U123', 'all')['blocks'][1]
    my = HOME.view(nil, 'ATEST', 'TTEST', 'U123', 'my')['blocks'][1]
    refute_equal all['block_id'], my['block_id']
    assert_equal 'my', my.dig('elements', 0, 'initial_option', 'value')
  end

  def test_home_actions_only_accept_our_view_and_valid_filter
    queued = []
    Slackmine.stub(:config, @settings) do
      SlackmineAppHomeJob.stub(:perform_later, ->(*args) { queued << args }) do
        HOME.interaction('ATEST', 'TTEST', home_action)
        select = home_action('filter')
        select['actions'][0]['selected_option'] = { 'value' => 'this_week' }
        HOME.interaction('ATEST', 'TTEST', select)
        HOME.interaction('ATEST', 'TTEST', home_action('refresh', 'bad'))
        HOME.interaction('OTHER', 'TTEST', home_action)
        forged = home_action
        forged['view']['type'] = 'modal'
        HOME.interaction('ATEST', 'TTEST', forged)
      end
    end
    assert_equal [['ATEST', 'TTEST', 'U123', 'all'], ['ATEST', 'TTEST', 'U123', 'this_week']], queued
  end

  def test_selection_publishes_without_refresh_and_refresh_preserves_current_selection
    calls = []
    Slackmine.stub(:config, @settings) do
      WORK.stub(:viewer_for, nil) do
        Slackmine.stub(:slack_api, ->(_method, body, *_args, **_options) { calls << body }) do
          SlackmineAppHomeJob.stub(:perform_later, ->(*args) { HOME.publish(*args) }) do
            select = home_action('filter')
            select['actions'][0]['selected_option'] = { 'value' => 'reported' }
            HOME.interaction('ATEST', 'TTEST', select)
            assert_equal ['reported'], calls.map { |body| body.dig('view', 'private_metadata') }

            refresh = home_action('refresh', 'all')
            refresh['actions'][0]['block_id'] = 'slackmine_home_controls_all'
            refresh['view']['state'] = { 'values' => {
              'slackmine_home_controls_all' => { 'slackmine_home_filter' => { 'selected_option' => { 'value' => 'reported' } } },
              'slackmine_home_controls_my' => { 'slackmine_home_filter' => { 'selected_option' => { 'value' => 'my' } } }
            } }
            HOME.interaction('ATEST', 'TTEST', refresh)
            assert_equal %w[reported reported], calls.map { |body| body.dig('view', 'private_metadata') }
          end
        end
      end
    end
  end

  def test_view_uses_requested_four_sections_in_order_and_individual_filters
    groups, queries = [], []
    HOME.stub(:allowed_projects, [9]) do
      HOME.stub(:my_page_rows, ->(viewer, projects, key) {
        assert_equal @viewer, viewer
        assert_equal [9], projects
        queries << key
        [@issue]
      }) do
        HOME.stub(:add_group, ->(_blocks, key, _rows) { groups << key }) do
          HOME.view(@viewer, 'ATEST', 'TTEST', 'U123', 'all')
          assert_equal %w[updated this_week my reported], groups
          HOME::SECTIONS.each do |key|
            groups.clear
            HOME.view(@viewer, 'ATEST', 'TTEST', 'U123', key)
            assert_equal [key], groups
          end
        end
      end
    end
    assert_equal HOME::SECTIONS * 2, queries
  end

  def test_my_page_queries_match_filters_sort_and_restore_current_user
    previous = User.current
    HOME::SECTIONS.each do |key|
      query = FakeIssueQuery.new
      IssueQuery.stub(:new, ->(**attributes) {
        assert_same @viewer, User.current
        assert_equal @viewer, attributes[:user]
        query
      }) do
        assert_equal [], HOME.my_page_rows(@viewer, [9], key)
      end
      assert_same previous, User.current
      assert_equal ['o', ['']], query.filters['status_id']
      assert_equal ['=', [Project::STATUS_ACTIVE.to_s]], query.filters['project.status']
      assert_equal({ limit: 11, include: [:assigned_to], conditions: { project_id: [9] } }, query.options)
      assert_equal ['subject'], query.column_names
      case key
      when 'updated'
        assert_equal ['=', ['me']], query.filters['updated_by']
      when 'reported'
        assert_equal ['=', ['me']], query.filters['author_id']
      else
        assert_equal ['=', ['me']], query.filters['assigned_to_id']
      end
      expected_sort = key == 'my' ? [['priority', 'desc'], ['updated_on', 'desc']] :
        (key == 'this_week' ? [['project', 'asc']] : [['updated_on', 'desc']])
      assert_equal expected_sort, query.sort_criteria
      assert_equal ['w', ['']], query.filters['due_date'] if key == 'this_week'
    end
    IssueQuery.stub(:new, ->(**_args) { raise 'query failed' }) do
      assert_raises(RuntimeError) { HOME.my_page_rows(@viewer, [9], 'updated') }
    end
    assert_same previous, User.current
  end

  def test_editable_details_reuse_permission_checked_modal_and_keep_home_filter
    @settings['slack'].merge!('work_object_actions' => true, 'work_object_previews' => true)
    @issue.define_singleton_method(:attributes_editable?) { |*_args| true }
    @issue.define_singleton_method(:safe_attribute?) { |*_args| false }
    @issue.define_singleton_method(:notes_addable?) { |*_args| true }
    calls = []
    Slackmine.stub(:config, @settings) do
      WORK.stub(:viewer_for, @viewer) do
        Issue.stub(:find_by, @issue) do
          Slackmine.stub(:slack_api, ->(*args, **_options) { calls << args }) do
            HOME.open_detail('ATEST', 'TTEST', 'U123', '7', 'fresh', 'this_week')
          end
        end
      end
    end
    form = calls.first[1]['view']
    assert_equal 'slackmine_edit_issue', form['callback_id']
    assert form['submit']
    context = JSON.parse(form['private_metadata'])
    assert_equal 'this_week', context['app_home']
    assert_equal Digest::SHA256.hexdigest(context['entity_url']), context.dig('external_ref', 'id')
    assert form['blocks'].any? { |block| block['block_id'] == 'new_comment' }
  end

  def test_modal_save_refreshes_home_and_reports_failed_update_without_repeating_write
    @settings['slack'].merge!('work_object_actions' => true, 'work_object_previews' => true)
    payload = { 'type' => 'view_submission', 'user' => { 'id' => 'U123' },
      'view' => { 'type' => 'modal', 'callback_id' => 'slackmine_edit_issue',
        'private_metadata' => JSON.generate('app_home' => 'my'), 'state' => { 'values' => {} } } }
    writes = []
    refreshes = []
    result = :saved
    Slackmine.stub(:config, @settings) do
      WORK.stub(:viewer_for, @viewer) do
        WORK.stub(:issue_for, @issue) do
          WORK.stub(:update_issue, ->(*args, **_attrs) { writes << args; result }) do
            Issue.stub(:find_by, @issue) do
              SlackmineWorkObjectRefreshJob.stub(:perform_later, ->(*args) { WORK.refresh_after_interaction(*args) }) do
                HOME.stub(:publish, ->(*args, **options) { refreshes << [args, options] }) do
                  WORK.process_interaction('ATEST', 'TTEST', payload)
                  result = :restricted
                  WORK.process_interaction('ATEST', 'TTEST', payload)
                end
                HOME.stub(:publish, ->(*) { raise 'Slack unavailable' }) do
                  WORK.process_interaction('ATEST', 'TTEST', payload)
                end
              end
            end
          end
        end
      end
    end
    assert_equal 3, writes.length
    assert_equal ['ATEST', 'TTEST', 'U123', 'my'], refreshes.first[0]
    assert_nil refreshes.first[1][:notice]
    assert_match(/7/, refreshes.last[1][:notice])
  end

  def test_detail_rechecks_visibility_mapping_and_integration_before_opening
    calls = []
    Slackmine.stub(:config, @settings) do
      WORK.stub(:viewer_for, @viewer) do
        Issue.stub(:find_by, @issue) do
          Slackmine.stub(:slack_api, ->(*args, **_options) { calls << args }) do
            HOME.open_detail('ATEST', 'TTEST', 'U123', '7', 'fresh', 'all')
            @issue.define_singleton_method(:visible?) { |*_args| false }
            HOME.open_detail('ATEST', 'TTEST', 'U123', '7', 'fresh', 'all')
            HOME.open_detail('OTHER', 'TTEST', 'U123', '7', 'fresh', 'all')
            HOME.open_detail('ATEST', 'TTEST', 'U123', '7', '', 'all')
            HOME.open_detail('ATEST', 'TTEST', 'U123', 'bad', 'fresh', 'all')
          end
        end
      end
    end
    assert_equal 1, calls.length
    assert_equal 'views.open', calls.first[0]
    refute calls.first[1]['view'].key?('submit')
    assert_includes calls.first[1]['view'].to_json, 'issues/7'
  end
end

class SlackEventsControllerTest
  def test_home_event_is_signed_direct_and_messages_tab_is_ignored
    queued = []
    @settings['slack'].merge!('app_home' => true, 'bot_token' => 'token')
    event = { 'type' => 'event_callback', 'api_app_id' => 'ATEST', 'team_id' => 'TTEST',
              'event' => { 'type' => 'app_home_opened', 'user' => 'U123', 'tab' => 'home', 'channel' => 'D123' } }
    assert_equal :ok, dispatch(event).status
    assert_equal :unauthorized, dispatch(event, signature: 'v0=' + '0' * 64).status
    event['event']['tab'] = 'messages'
    assert_equal :ok, dispatch(event).status
    queued = @queued_home
    assert_equal [['ATEST', 'TTEST', 'U123', 'all']], queued
  end

  def test_reopening_home_preserves_only_our_valid_filter
    @settings['slack'].merge!('app_home' => true, 'bot_token' => 'token')
    queued = []
    event = { 'type' => 'event_callback', 'api_app_id' => 'ATEST', 'team_id' => 'TTEST',
              'event' => { 'type' => 'app_home_opened', 'user' => 'U123', 'tab' => 'home',
                'view' => { 'callback_id' => 'slackmine_home', 'private_metadata' => 'my' } } }
    assert_equal :ok, dispatch(event).status
    event['event']['view']['private_metadata'] = 'invalid'
    assert_equal :ok, dispatch(event).status
    event['event']['view'] = { 'callback_id' => 'other_app', 'private_metadata' => 'this_week' }
    assert_equal :ok, dispatch(event).status
    queued = @queued_home
    assert_equal %w[my all all], queued.map(&:last)
  end

  def test_home_detail_routing_is_synchronous_and_requires_signature
    calls = []
    payload = AppHomeTest.new('test_home_actions_only_accept_our_view_and_valid_filter').home_action('detail', '7')
    Slackmine::AppHome.stub(:interaction, ->(*args) { calls << args; {} }) do
      raw = URI.encode_www_form('payload' => JSON.generate(payload))
      assert_equal :ok, dispatch(raw: raw).status
      assert_equal :unauthorized, dispatch(raw: raw, signature: 'v0=' + '0' * 64).status
    end
    assert_equal 1, calls.length
    assert_equal 'fresh-trigger', calls.first.last['trigger_id']
  end
end
