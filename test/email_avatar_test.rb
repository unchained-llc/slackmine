# frozen_string_literal: true
require_relative 'image_notification_test'

class EmailAvatarMappingTest < Minitest::Test
  def setup
    @user = User.new
    @user.login = 'alice'
    @user.mail = ' Alice@Example.com '
    @user.name = 'Alice'
    @settings = { 'slack' => { 'bot_token' => 'token', 'auto_map_users_by_email' => true,
                               'events' => { 'team_id' => 'T123' } }, 'users' => {} }
    @member = { 'id' => 'U123', 'team_id' => 'T123', 'profile' => { 'email' => 'alice@example.com' } }
  end

  def resolve
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*) { { 'members' => [@member] } }) do
        Slackmine.slack_user_id_for(@user)
      end
    end
  end

  def test_matching_email_resolves_with_name_matching_disabled
    assert_equal 'U123', resolve
  end

  def test_project_override_disables_email_lookup_and_invalid_manual_id_does_not_fall_back
    @settings['projects'] = { 'private' => { 'slack' => { 'auto_map_users_by_email' => false } } }
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*) { flunk 'Lookup must not run' }) do
        Slackmine.with_project(OpenStruct.new(identifier: 'private')) do
          assert_nil Slackmine.slack_user_id_for(@user)
        end
        assert_nil Slackmine.slack_user_id_for(@user, by_email: false)
        @settings['users']['alice'] = 'invalid-id'
        assert_nil Slackmine.slack_user_id_for(@user)
      end
    end
  end

  def test_explicit_mapping_wins_without_any_api_call
    @settings['users']['alice'] = 'U456'
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*) { flunk 'Manual mapping must win' }) do
        assert_equal 'U456', Slackmine.slack_user_id_for(@user)
      end
    end
  end

  def test_match_method_reports_the_winning_lookup_without_resolving_twice
    @settings['slack'] = { 'auto_map_users_by_name' => true }.merge(@settings['slack'])
    calls = []
    name_id = 'U789'
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_user_id_for_name, ->(*) { calls << :name; name_id }) do
        Slackmine.stub(:slack_user_id_for_email, ->(*) { calls << :email; 'U123' }) do
          @settings['users'] = { 'alice' => 'U456', @user.mail => 'U999' }
          assert_equal({ id: 'U456', method: :explicit_login }, Slackmine.slack_user_match_for(@user))
          @settings['users'].delete('alice')
          assert_equal({ id: 'U999', method: :explicit_email }, Slackmine.slack_user_match_for(@user))
          assert_empty calls
          @settings['users'].clear
          assert_equal({ id: 'U789', method: :name }, Slackmine.slack_user_match_for(@user))
          assert_equal [:name], calls
          calls.clear
          name_id = nil
          assert_equal({ id: 'U123', method: :email }, Slackmine.slack_user_match_for(@user))
          assert_equal [:name, :email], calls
          calls.clear
          @settings['users']['alice'] = 'invalid'
          assert_nil Slackmine.slack_user_match_for(@user)
          assert_empty calls
        end
      end
    end
  end

  def test_yaml_switch_order_selects_first_unique_match_and_falls_back
    [%w[name email], %w[email name]].each do |order|
      slack = YAML.safe_load(order.map { |kind| "auto_map_users_by_#{kind}: true" }.join("\n"))
      @settings['slack'] = slack
      name_id, email_id = 'UNAME', 'UEMAIL'
      calls = []
      Slackmine.stub(:config, @settings) do
        Slackmine.stub(:slack_user_id_for_name, ->(*) { calls << :name; name_id }) do
          Slackmine.stub(:slack_user_id_for_email, ->(*) { calls << :email; email_id }) do
            expected = order.first.to_sym
            assert_equal({ id: expected == :name ? 'UNAME' : 'UEMAIL', method: expected }, Slackmine.slack_user_match_for(@user))
            assert_equal [expected], calls
            calls.clear
            expected == :name ? name_id = nil : email_id = nil
            assert_equal order.last.to_sym, Slackmine.slack_user_match_for(@user)[:method]
            assert_equal order.map(&:to_sym), calls
            name_id = email_id = nil
            assert_nil Slackmine.slack_user_match_for(@user)
          end
        end
      end
    end
  end

  def test_project_yaml_order_overrides_global_key_positions
    @settings['slack'] = { 'auto_map_users_by_name' => true, 'auto_map_users_by_email' => true }
    @settings['projects'] = { 'email-first' => { 'slack' => {
      'auto_map_users_by_email' => true, 'auto_map_users_by_name' => true
    } } }
    Slackmine.stub(:config, @settings) do
      assert_equal [:name, :email], Slackmine.automatic_user_matching_order
      Slackmine.with_project(OpenStruct.new(identifier: 'email-first')) do
        assert_equal [:email, :name], Slackmine.automatic_user_matching_order
        Slackmine.stub(:slack_user_id_for_email, ->(*) { flunk 'Email matching must be excluded' }) do
          Slackmine.stub(:slack_user_id_for_name, 'UNAME') do
            assert_equal({ id: 'UNAME', method: :name }, Slackmine.slack_user_match_for(@user, by_email: false))
          end
        end
      end
    end
  end

  def test_disabled_email_empty_email_and_empty_token_do_not_call_api
    [{ 'auto_map_users_by_email' => false }, { 'bot_token' => '' }].each do |override|
      Slackmine.stub(:config, @settings.merge('slack' => @settings['slack'].merge(override))) do
        Slackmine.stub(:slack_api, ->(*) { flunk 'Lookup must be disabled' }) do
          assert_nil Slackmine.slack_user_id_for(@user)
        end
      end
    end
    @user.mail = ''
    assert_nil resolve
  end

  def test_rejects_non_humans_wrong_team_and_invalid_ids_or_email
    %w[deleted is_bot is_app_user is_stranger].each do |flag|
      @member[flag] = true
      assert_nil resolve
      @member.delete(flag)
    end
    @member['team_id'] = 'T456'
    assert_nil resolve
    @member['team_id'] = 'T123'
    @member['id'] = 'B123'
    assert_nil resolve
    @member['id'] = 'U123'
    @member['profile']['email'] = 'other@example.com'
    assert_nil resolve
    @member = nil
    assert_nil resolve
  end

  def test_api_failure_falls_back_without_logging_email
    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| warnings << message }
    Slackmine.stub(:config, @settings) do
      Rails.stub(:logger, logger) do
        Slackmine.stub(:slack_api, ->(*) { raise Slackmine::SlackApiError, 'missing_scope alice@example.com' }) do
          assert_nil Slackmine.slack_user_id_for(@user)
          assert_equal({ 'text' => 'Alice' }, Slackmine::Formatter.work_object_user_field(@user)['user'])
        end
      end
    end
    refute_empty warnings
    refute_includes warnings.join, 'alice@example.com'
  end
end
