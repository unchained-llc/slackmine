# frozen_string_literal: true

require_relative 'admin_overview_test'
require 'logger'
require 'action_view'

# Render the actual ERB through ActionView. This checks template compilation and
# HTML escaping without a running Redmine, database, or Slack connection.
class AdminViewTest < Minitest::Test
  class View < ActionView::Base
    def l(key, **options)
      value = @labels.dig(*key.to_s.split('.')) || key.to_s
      options.empty? ? value : value % options
    end

    def slackmine_admin_path(options = {})
      '/admin/slackmine?' + URI.encode_www_form(options)
    end

    def project_path(project)
      "/projects/#{project.id}"
    end

    def user_path(user)
      "/users/#{user.id}"
    end

    def slackmine_admin_test_notification_path
      "/admin/slackmine/test_notification"
    end

    def format_time(value)
      value.utc.strftime("%Y-%m-%d %H:%M:%S")
    end

    def html_title(*)
    end

    def pagination_links_full(*)
      'Pagination'
    end
  end

  def render_tab(tab, assigns = {})
    labels = YAML.safe_load(File.read(File.expand_path('../config/locales/slackmine_admin.ja.yml', __dir__))).fetch('ja')
    lookup = ActionView::LookupContext.new([File.expand_path('../app/views', __dir__)])
    view = View.new(lookup, {
      tab: tab, scope_project: nil, scope_projects: [['<script>project</script>', 1]],
      pages: nil, labels: labels, match_methods: {}
    }.merge(assigns), nil)
    view.render(template: 'slackmine_admin/index')
  end

  def test_message_columns_have_room_for_long_text_and_preserve_newlines
    html = render_tab('settings', settings: {'messages' => {'commands' => {'help' => "First line\nSecond line"}}})
    document = Nokogiri::HTML(html)
    assert_equal ['width: 30%', 'width: 35%', 'width: 35%'], document.css('col').map { |col| col['style'] }
    values = document.css('tbody td').drop(1)
    assert values.all? { |cell| cell['style'].include?('text-align: left; vertical-align: top;') }
    assert_includes values.last.text, "First line\nSecond line"
  end

  def test_jobs_show_safe_history_and_post_only_test_button
    html = render_tab('jobs', job_snapshot: {available: true, queue_size: 1, latency: 2.0, truncated: false,
      entries: [{'job' => 'SlackmineNotificationJob', 'id' => 'job1', 'status' => 'queued', 'timestamp' => 1_700_000_000}],
      history: [{'job' => 'SlackmineTestNotificationJob', 'id' => 'job2', 'status' => 'completed', 'duration' => 0.3, 'finished_at' => 1_700_000_001}]},
      test_channel: 'C123', test_ready: true)
    document = Nokogiri::HTML(html)
    assert_includes html, 'SlackmineTestNotificationJob'
    assert_includes html, '最大7日'
    form = document.at_css('form[action="/admin/slackmine/test_notification"]')
    assert_equal 'post', form['method']
    assert_equal 'C123', form.at_css('input[name=expected_channel]')['value']
    assert_includes form.at_css('input[type=submit]')['data-confirm'], 'C123'
    refute form.at_css('input[type=submit]')['disabled']
  end

  def test_changed_messages_are_bold_regardless_of_length
    html = render_tab('settings', settings: {'messages' => {'commands' => {'help' => "A long message " * 20, 'save' => '保存'}}})
    rows = Nokogiri::HTML(html).css('tbody tr')
    assert_nil rows.first.at_css('td:first-child strong code')
    assert rows.first.at_css('td:last-child strong')
    assert rows.last.at_css('td:last-child strong')
  end

  def test_context_defaults_show_values_and_rules_and_color_actions_are_localized
    html = render_tab('settings', settings: {'slack' => {'work_object_buttons' => {'add_comment' => false, 'edit_issue' => true},
      'metadata' => {'issue' => {'custom_fields' => {'42' => false}}}},
      'messages' => {'colors' => {'issue' => {'created' => '#123456'}}}})
    assert_includes html, '通知: true／詳細: false'
    assert_includes html, '通知: false／詳細: true'
    assert_includes html, 'defaultを継承（省略時true）'
    assert_includes html, 'チケットの作成イベントの通知色'
    refute_includes html, '条件に依存'
    assert_includes html, '設定を指定すると、省略したボタンはfalse'
  end

  def test_event_colors_have_a_visible_section_and_safe_read_only_swatches
    html = render_tab('settings', settings: {'slack' => {'attachment_color' => '#123456'},
                                            'messages' => {'colors' => {'issue' => {'created' => '#ABCDEF'}}}})
    document = Nokogiri::HTML(html)
    assert_includes document.css('summary').map(&:text), 'messages.colors'
    assert_includes html, 'messages.colors.issue.created'
    swatches = document.css('svg rect')
    assert_equal ['#6D5DFB', '#123456', '#123456', '#ABCDEF'], swatches.map { |node| node['fill'] }
    assert document.css('svg').all? { |node| node['width'] == '12' && node['height'] == '12' }
    assert_empty document.css('input[type=color]')
    assert document.css('details').reject { |node| node.at_css('summary').text == 'messages' }.all? { |node| node.css('col').map { |col| col['style'] } == ['width: 70%', 'width: 15%', 'width: 15%'] }
    assert document.css('td.text').all? { |node| node['style'].include?('text-align: left') }
    assert_empty document.css('style, link[rel=stylesheet]')
  end

  def test_settings_render_masked_tokens_and_escape_configured_values
    Slackmine.stub(:config, 'slack' => { 'bot_token' => 'sensitive-token', 'attachment_color' => '<script>alert(1)</script>' }) do
      Slackmine.stub(:messages_config, {}) do
        html = render_tab('settings', settings: Slackmine::AdminOverview.settings(nil))
        assert_includes html, '[FILTERED]'
        refute_includes html, 'sensitive-token'
        assert_includes html, '&lt;script&gt;alert(1)&lt;/script&gt;'
        refute_includes html, '<script>'
        assert_includes html, 'name="scope_project_id"'
        assert_includes html, '<em class="info">'
        assert_includes html, 'Slack APIのBot Token'
      end
    end
  end

  def test_explanations_show_file_policy_and_email_mapping_distinctions
    html = render_tab('settings', settings: { 'slack' => { 'files' => { 'force_restrict_transfer' => true },
                                                        'auto_map_users_by_email' => true } })
    assert_includes html, 'プロジェクト側で解除できません'
    assert_includes html, '送信・管理画面のユーザー表示にも使います'
  end

  def test_project_table_uses_routing_and_preserves_closed_status
    project = OpenStruct.new(id: 1, name: '<script>project</script>', identifier: 'example', status: 5)
    Slackmine.stub(:channel_id, ->(candidate) { assert_same project, candidate; 'C123' }) do
      html = render_tab('projects', projects: [project])
      assert_includes html, 'C123'
      assert_includes html, 'project_status_closed'
      assert_includes html, '&lt;script&gt;project&lt;/script&gt;'
      refute_includes html, '<script>'
      assert_includes html, 'scope_project_id=1'
    end
  end

  def test_user_table_renders_mentions_unmapped_users_and_orphaned_configuration
    users = [OpenStruct.new(id: 1, name: 'Alice', login: 'alice', mail: 'alice@example.com'),
             OpenStruct.new(id: 2, name: 'Bob', login: 'bob', mail: 'bob@example.com')]
    html = render_tab('users', users: users, mentions: { 1 => 'U123', 2 => nil }, match_methods: { 1 => :email }, user_mapping: { 'old-account' => 'UOLD' })
    assert_includes html, '照合方法'
    assert_includes html, 'メールアドレス一致'
    assert_includes html, '&lt;@U123&gt;'
    assert_includes html, '対応なし'
    assert_includes html, 'old-account'
    assert_includes html, 'UOLD'
    assert_includes html, 'name="mapping_filter"'
    assert_includes html, '対応あり'
    assert_includes html, 'すべて'
  end

  def test_missing_configuration_warning_and_empty_filtered_list
    html = render_tab('users', users: [], mentions: {}, user_mapping: {}, mapping_filter: 'mapped',
                              missing_configuration: ['slackmine.yml', 'slackmine.messages.yml'])
    assert_includes html, '実設定ファイルが見つかりません'
    assert_includes html, 'slackmine.messages.yml'
    assert_includes html, 'class="nodata"'
    assert_includes html, 'selected="selected" value="mapped"'
  end

  def test_settings_move_values_right_and_mark_only_changes
    html = render_tab('settings', settings: {'slack' => {'work_object_actions' => true, 'thread_comments' => false}})
    document = Nokogiri::HTML(html)
    assert_equal ['設定キー', 'デフォルト値', '現在値'], document.css('table th').map(&:text)
    changed = document.css('tbody tr').select { |row| row.at_css('td:last-child strong') }
    assert_equal 1, changed.length
    assert_includes changed.first.text, 'slack.work_object_actions'
    assert_equal 'false', changed.first.css('td')[1].text
    assert_equal 'true', changed.first.css('td strong').text
    assert_equal 1, changed.first.css('td:first-child em.info').length
    assert_empty document.css('.slackmine-setting-badge')
    refute_includes html, 'admin_overview.css'
    refute_includes html, 'slackmine-setting-'
    filtered = render_tab('settings', settings: {'slack' => {'work_object_actions' => true, 'thread_comments' => false}}, changes_only: true)
    refute_includes filtered, '<code>slack.thread_comments</code>'
    assert_includes filtered, '<code>slack.work_object_actions</code>'
  end
end
