# frozen_string_literal: true
# Copyright (C) UNCHAINED


require_relative 'lib/slackmine'


Redmine::Plugin.register :slackmine do
  name 'Slackmine'
  author 'UNCHAINED'
  url 'https://github.com/unchained-llc/slackmine'
  description 'Integrate Redmine 7 with Slack: notifications, Work Objects, issue actions, search, and thread replies.'
  version '1.7.2'
  requires_redmine version_or_higher: '7.0.0'

  menu :admin_menu, :slackmine_admin,
       { controller: 'slackmine_admin', action: 'index' },
       caption: :label_slackmine_admin, icon: 'slackmine', plugin: :slackmine,
       html: { class: 'icon' },
       if: proc { User.current.admin? }


end
