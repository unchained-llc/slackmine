# frozen_string_literal: true

class SlackmineAdminController < ApplicationController
  layout 'admin'
  self.main_menu = false
  menu_item :slackmine_admin
  before_action :require_admin

  def index
    @tab = %w[settings projects users jobs].include?(params[:tab]) ? params[:tab] : 'settings'
    @scope_project = Project.find(params[:scope_project_id]) if params[:scope_project_id].present?
    @scope_projects = Project.order(:name, :id).pluck(:name, :id) unless @tab == 'projects'
    @missing_configuration = Slackmine::AdminOverview.missing_configuration
    @mapping_filter = %w[mapped unmapped all].include?(params[:mapping_filter]) ? params[:mapping_filter] : 'mapped'
    @changes_only = params[:changes_only] == '1'

    case @tab
    when 'settings'
      @settings = Slackmine::AdminOverview.settings(@scope_project)
    when 'projects'
      @project_status = %w[1 5 9 10 all].include?(params[:project_status]) ? params[:project_status] : '1'
      scope = @project_status == 'all' ? Project.all : Project.where(status: @project_status.to_i)
      @count = scope.count
      @pages = Paginator.new(@count, 50, params[:page])
      @projects = scope.order(:name, :id).limit(@pages.per_page).offset(@pages.offset).to_a
    when 'jobs'
      @job_snapshot = Slackmine::JobMonitor.snapshot
      Slackmine.with_project(@scope_project) do
        @test_channel = Slackmine::JobMonitor.test_channel(@scope_project)
        @test_ready = @test_channel.present? && Slackmine.bot_token(@scope_project).present? && Slackmine::JobMonitor.available?
      end
    when 'users'
      scope = @scope_project ? @scope_project.users : User.active
      candidates = scope.order(:login, :id).to_a
      Slackmine.with_project(@scope_project) do
        matches = candidates.to_h { |user| [user.id, Slackmine.slack_user_match_for(user)] }
        @mentions = matches.transform_values { |match| match && match[:id] }
        @match_methods = matches.transform_values { |match| match && match[:method] }
        candidates.select! { |user| !@mentions[user.id].to_s.empty? } if @mapping_filter == 'mapped'
        candidates.reject! { |user| !@mentions[user.id].to_s.empty? } if @mapping_filter == 'unmapped'
        @user_mapping = Slackmine::AdminOverview.redact(Slackmine.user_mapping)
      end
      @count = candidates.length
      @pages = Paginator.new(@count, 50, params[:page])
      @users = candidates.slice(@pages.offset, @pages.per_page) || []
      @mentions = @users.to_h { |user| [user.id, @mentions[user.id]] }
      @match_methods = @users.to_h { |user| [user.id, @match_methods[user.id]] }
    end
  end
  def test_notification
    project = Project.find(params[:scope_project_id]) if params[:scope_project_id].present?
    Slackmine.with_project(project) do
      channel = Slackmine::JobMonitor.test_channel(project)
      unless Slackmine::JobMonitor.available? && channel.present? && channel == params[:expected_channel] && Slackmine.bot_token(project).present?
        flash[:error] = l(:text_slackmine_admin_test_unavailable)
        return redirect_to slackmine_admin_path(tab: 'jobs', scope_project_id: project&.id)
      end
      job = SlackmineTestNotificationJob.perform_later(project&.id, channel, l(:text_slackmine_admin_test_message))
      flash[job ? :notice : :error] = l(job ? :text_slackmine_admin_test_queued : :text_slackmine_admin_test_unavailable)
    end
    redirect_to slackmine_admin_path(tab: 'jobs', scope_project_id: project&.id)
  rescue StandardError => error
    Rails.logger.warn("Slackmine test enqueue failed: #{error.class}")
    flash[:error] = l(:text_slackmine_admin_test_unavailable)
    redirect_to slackmine_admin_path(tab: 'jobs', scope_project_id: project&.id)
  end
end
