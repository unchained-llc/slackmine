# frozen_string_literal: true

require_relative 'admin_overview_test'

# Redmine supplies ApplicationController and its require_admin implementation.
# Record the declaration and exercise the real index action with model adapters.
class ApplicationController
  class << self
    attr_accessor :main_menu, :admin_callbacks
    def layout(*)
    end
    def menu_item(*)
    end
    def before_action(callback)
      self.admin_callbacks ||= []
      admin_callbacks << callback
    end
  end
  attr_accessor :params
end

class Paginator
  attr_reader :per_page, :offset
  def initialize(_count, per_page, page)
    @per_page = per_page
    @offset = ([page.to_i, 1].max - 1) * per_page
  end
end

require_relative '../app/controllers/slackmine_admin_controller'

class AdminControllerTest < Minitest::Test
  class Scope
    def initialize(records)
      @records = records
    end
    def order(*)
      self
    end
    def pluck(*keys)
      @records.map { |record| keys.map { |key| record.public_send(key) } }
    end
    def count
      @records.length
    end
    def limit(limit)
      @limit = limit
      self
    end
    def offset(offset)
      @offset = offset
      self
    end
    def to_a
      @records.drop(@offset || 0).first(@limit || @records.length)
    end
  end

  def setup
    Project.define_singleton_method(:order) { |*| } unless Project.respond_to?(:order)
    User.define_singleton_method(:active) {} unless User.respond_to?(:active)
    @project = OpenStruct.new(id: 1, identifier: 'example', name: 'Example')
    @controller = SlackmineAdminController.new
    @previous_context = Thread.current[:slackmine_project]
  end

  def teardown
    Thread.current[:slackmine_project] = @previous_context
  end

  def test_project_status_defaults_to_active_and_filters_before_pagination
    Project.define_singleton_method(:where) { |*| } unless Project.respond_to?(:where)
    @controller.params = { tab: 'projects' }
    Project.stub(:where, ->(conditions) { assert_equal({status: 1}, conditions); Scope.new([@project]) }) do
      @controller.index
    end
    assert_equal '1', @controller.instance_variable_get(:@project_status)
    assert_equal 1, @controller.instance_variable_get(:@count)
    assert_equal [@project], @controller.instance_variable_get(:@projects)
    @controller.params = { tab: 'projects', project_status: '9' }
    Project.stub(:where, ->(conditions) { assert_equal({status: 9}, conditions); Scope.new([]) }) do
      @controller.index
    end
    assert_empty @controller.instance_variable_get(:@projects)
  end

  def test_all_project_statuses_can_be_selected
    Project.define_singleton_method(:all) {} unless Project.respond_to?(:all)
    @controller.params = { tab: 'projects', project_status: 'all' }
    Project.stub(:all, Scope.new([@project])) { @controller.index }
    assert_equal 'all', @controller.instance_variable_get(:@project_status)
    assert_equal [@project], @controller.instance_variable_get(:@projects)
  end

  def test_redmine_admin_guard_is_registered
    assert_equal ApplicationController, SlackmineAdminController.superclass
    assert_includes SlackmineAdminController.admin_callbacks, :require_admin
  end

  def test_unknown_tab_defaults_to_settings_without_fetching_slack
    @controller.params = { tab: 'unknown' }
    Project.stub(:order, Scope.new([@project])) do
      Slackmine.stub(:config, {}) do
        Slackmine.stub(:messages_config, {}) do
          Slackmine.stub(:slack_api, ->(*) { flunk 'Settings must not contact Slack' }) do
            @controller.index
            assert_equal 'settings', @controller.instance_variable_get(:@tab)
            assert_equal [[@project.name, @project.id]], @controller.instance_variable_get(:@scope_projects)
          end
        end
      end
    end
  end

  def test_user_page_uses_project_overrides_and_restores_prior_context
    users = 51.times.map do |i|
      user = User.new
      user.login = "user#{i}"
      user.mail = "user#{i}@example.com"
      user.define_singleton_method(:id) { i + 1 }
      user
    end
    @controller.params = { tab: 'users', scope_project_id: '1', page: '2', mapping_filter: 'all' }
    @project.users = Scope.new(users)
    prior = OpenStruct.new(identifier: 'prior')
    Thread.current[:slackmine_project] = prior
    settings = { 'users' => { 'user50' => 'UGLOBAL' },
                 'projects' => { 'example' => { 'users' => { 'user50' => 'UPROJECT' } } } }
    Project.stub(:find, @project) do
      Project.stub(:order, Scope.new([@project])) do
        User.stub(:active, Scope.new(users)) do
          Slackmine.stub(:config, settings) do
            @controller.index
          end
        end
      end
    end
    assert_equal 51, @controller.instance_variable_get(:@count)
    assert_equal [users.last], @controller.instance_variable_get(:@users)
    assert_equal({51 => 'UPROJECT'}, @controller.instance_variable_get(:@mentions))
    assert_equal({51 => :explicit_login}, @controller.instance_variable_get(:@match_methods))
    assert_equal 'UPROJECT', @controller.instance_variable_get(:@user_mapping)['user50']
    assert_same prior, Thread.current[:slackmine_project]
  end

  def test_default_filter_removes_unmapped_users_before_pagination
    users = 61.times.map do |i|
      user = User.new
      user.login = "user#{i}"
      user.mail = "user#{i}@example.com"
      user.define_singleton_method(:id) { i + 1 }
      user
    end
    @controller.params = { tab: 'users' }
    Project.stub(:order, Scope.new([@project])) do
      User.stub(:active, Scope.new(users)) do
        Slackmine.stub(:config, 'users' => {'user60' => 'ULAST'}) { @controller.index }
      end
    end
    assert_equal 'mapped', @controller.instance_variable_get(:@mapping_filter)
    assert_equal 1, @controller.instance_variable_get(:@count)
    assert_equal [users.last], @controller.instance_variable_get(:@users)
  end

  def test_email_mapping_lists_slack_users_once_for_all_candidates_and_refreshes
    users = 250.times.map do |i|
      user = User.new
      user.login = "user#{i}"
      user.mail = "user#{i}@example.com"
      user.define_singleton_method(:id) { i + 1 }
      user
    end
    members = users.map { |user| { 'id' => "U#{user.id}", 'profile' => { 'email' => user.mail } } }
    settings = { 'slack' => { 'bot_token' => 'test', 'auto_map_users_by_email' => true } }
    calls = []
    @controller.params = { tab: 'users', scope_project_id: '', mapping_filter: 'mapped' }
    Project.stub(:order, Scope.new([@project])) do
      User.stub(:active, Scope.new(users)) do
        Rails.stub(:cache, AutomaticUserMappingTest::MemoryCache.new) do
          Slackmine.stub(:config, settings) do
            Slackmine.stub(:slack_api, lambda { |method, params, *, **options|
              assert_equal 'users.list', method
              calls << params
              params['cursor'] ? { 'members' => members.drop(200) } :
                { 'members' => members.first(200), 'response_metadata' => { 'next_cursor' => 'next' } }
            }) do
              2.times do
                @controller.index
                assert_equal 250, @controller.instance_variable_get(:@count)
                assert_equal 50, @controller.instance_variable_get(:@users).length
                assert_equal 'U1', @controller.instance_variable_get(:@mentions)[1]
                assert_equal [:email], @controller.instance_variable_get(:@match_methods).values.uniq
              end
            end
          end
        end
      end
    end
    assert_equal [{ 'limit' => 200 }, { 'limit' => 200, 'cursor' => 'next' }], calls
  end

  def test_project_members_and_unmapped_filter_exclude_other_users
    member = User.new
    member.login = 'unmapped'
    member.mail = 'unmapped@example.com'
    member.define_singleton_method(:id) { 1 }
    @project.users = Scope.new([member])
    @controller.params = { tab: 'users', scope_project_id: '1', mapping_filter: 'unmapped' }
    Project.stub(:find, @project) do
      Project.stub(:order, Scope.new([@project])) do
        User.stub(:active, -> { flunk 'Project membership must supply the user scope' }) do
          Slackmine.stub(:config, {}) { @controller.index }
        end
      end
    end
    assert_equal 1, @controller.instance_variable_get(:@count)
    assert_equal [member], @controller.instance_variable_get(:@users)
  end
end
