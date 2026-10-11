[English](README.md) | [日本語](README.ja.md)

# Slackmine

![Slackmine — Slack and Redmine integration](docs/assets/slackmine-icon.png)

Version **1.5.5**.

The plugin was renamed from **Redmine Event Notifications for Slack** (`redmine_slack_notification`) to **Slackmine** as it grew from notifications into a broader Slack–Redmine integration. Internal names, plugin ID, configuration filename and endpoints now use `slackmine`; the former names are no longer supported.

A Redmine 7 plugin that sends Issue, Wiki, News, Document, file, forum, time entry, Version, and Project events to Slack. It can also send daily Issue due-date reminders to assignees by Slack DM. Notifications use a colored Block Kit attachment with a link to the Redmine record. Delivery runs through ActiveJob, normally on Sidekiq's `slack` queue.

The plugin provides notifications, Work Object actions, and optional slash commands. It does not add project settings tabs or Redmine custom fields.

## Features

| Feature | What it does |
| --- | --- |
| [Redmine event notifications](#event-switches) | Notify Slack about Issue creation, changes, comments, and deletion, plus Wiki, News, time entry, Version, and Project events. Enable or disable individual events globally or per project. |
| [Notification formatting](#notification-content) | Choose metadata, colors, and wording; show body diffs and inline Issue images; mention mapped assignees. |
| [Project channel routing](#inherit-a-parent-project-channel) | Use an explicit channel or an optional unique name match, then try parent projects from nearest to farthest, and finally the default channel. Configure separate Slack apps/tokens per project when needed. |
| [Issue Work Object previews](#ticket-work-object-previews) | Display Issue cards and details inside Slack, with configurable fields and current data fetched when details open. |
| [Issue actions in Slack](#work-object-card-and-detail-actions) | Edit permitted status, assignee, priority, and due date; add comments; assign to yourself; start/complete work; watch/unwatch. The time-entry action opens the Redmine form. |
| [Comment notification threads](#threaded-redmine-comment-notifications) | Group Redmine Issue comment notifications in a Slack thread. |
| [Connect a conversation to an existing Issue](#connect-a-slack-thread-to-an-existing-issue) | Use a message shortcut, review/select past posts as one connecting-user comment, and import future replies/files under mapped users. Consecutive posts by the same speaker share one standard card with one header and Slack link; a speaker change starts another card, preserving conversation order. Disconnect from the same menu. Enabled by default; signed Bot posts in Slack hold the connection without a plugin table or migration. |
| [Slack replies to Redmine comments](#add-redmine-comments-from-notification-threads) | Save text/file replies in supported notification threads as Redmine comments and attachments under the mapped user's identity. |
| [Slash commands](#slash-command) | Find Issues, list your assigned/due Issues, request a personal reminder digest, create Issues, add comments, and change status or assignee through forms or direct command arguments. Single-Issue results can use Work Object cards, with text fallback when previews are disabled. |
| [Create an Issue from a Slack message](#create-an-issue-from-a-slack-message) | Use a message shortcut, choose a permitted project, and review a new-Issue form prefilled with the selected message and its source link. |
| [Slack link retrieval and cards](#slack-message-cards-in-issue-text) | Fetch messages linked from Issue descriptions/comments, save searchable quotes in the existing text fields, and display cards at the link positions with resolved names and thread context. |
| [Due-date reminders](#daily-due-date-dms) | Send scheduled Slack DM digests of assigned open Issues that are overdue or due within a configurable window. Scheduling is configured separately. |
| [App Home issue lists](#app-home-issue-lists) | View open issues updated by you, due this week, assigned to you, or reported by you. Five-column tables show title/project, status, assignee, due date, and edit actions. Filters refresh automatically; titles open Redmine and buttons open permitted Slack edit/comment forms. |
| [User mapping](#assignee-mentions) | Map Redmine users to Slack IDs explicitly; optionally match names for outgoing mentions or [email addresses for incoming authorization](#match-viewers-by-email). Actions still enforce Redmine permissions and workflow rules. |
| [Personal email preference](#personal-email-preference) | Let each user opt out of supported notification emails when Slack notification settings and channel membership qualify. Account/security emails remain enabled; Slack delivery success is not checked. |
| [Administration screen](#administration-overview) | Inspect effective settings, event colors, project/channel routing and user mentions. Queue monitoring, execution history and test notifications are available only when using Sidekiq. |

Work Object previews/actions, slash commands, thread integration, and reminders require their respective configuration and Slack app scopes/events. The personal email option is off by default. See each linked section for setup and limits.

The images below illustrate supported feature content and controls using fictional English data. They are not live screenshots or pixel-exact reproductions of Slack; surrounding navigation is omitted, and notification configuration examples show YAML, while the administration illustration shows the supported read-only settings view. Both language versions share the same images.

See the [Slack scopes and feature setup tables](#slack-scopes-and-feature-setup) for the permissions and app settings needed by each feature.

## Requirements and setup

- Redmine 7.0 or later.
- A Slack app with a Bot Token and the [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) scope. Add [`im:write`](https://docs.slack.dev/reference/scopes/im.write/) for due-date DMs, [`files:write`](https://docs.slack.dev/reference/scopes/files.write/) for inline Issue images, and [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) if you enable automatic user mapping by name. Reinstall the Slack app after changing scopes so its Bot Token receives them.
- To use automatic user matching for the [personal email preference](#personal-email-preference), add both [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) and [`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/), then reinstall the Slack app.
- A Slack channel for each project, or a default channel. Invite the bot to each destination channel, including private channels.
- For due-date DMs or results from long-running form saves, turn on the Slack app's **App Home → Display Messages tab** setting.
- An ActiveJob worker that processes the `slack` queue. Sidekiq is recommended in production.

1. From the Redmine application root, clone this repository into `plugins/slackmine`:

   ```sh
   git clone https://github.com/unchained-llc/slackmine.git plugins/slackmine
   ```

2. Copy the [behavior configuration example](config/slackmine.yml.example) to the application's `config/slackmine.yml`.
3. Set the Bot Token and a default or project-specific channel ID. To use Japanese wording, copy the [Japanese message example](config/slackmine.messages.ja.yml.example) to `config/slackmine.messages.yml`; to customize English wording, start from the [English message example](config/slackmine.messages.yml.example). Keep the real configuration files out of Git.
4. Configure Sidekiq to process the `slack` queue and invite the bot to the configured channels.
5. Restart Redmine and Sidekiq. Both processes cache the YAML configuration.

### Slack scopes and feature setup

Add only the scopes needed for your features under **OAuth & Permissions → Bot Token Scopes**. Basic channel notifications start with [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/). Reinstall the app after changing scopes and invite the bot to the destination channels.

| Bot Token scope | Used for |
| --- | --- |
| [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) | Notifications, feedback, and deleting the bot's own feedback messages |
| [`im:write`](https://docs.slack.dev/reference/scopes/im.write/) | Sending due-date reminder DMs |
| [`files:write`](https://docs.slack.dev/reference/scopes/files.write/) | Uploading Redmine attachment images into Slack notifications |
| [`files:read`](https://docs.slack.dev/reference/scopes/files.read/) | Importing Slack thread attachments into Redmine |
| [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) | Automatic name matching, excluding bot-directed mentions, and author/mention profiles in link cards |
| [`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/) plus [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) | Matching viewers by email; automatic user matching for personal email suppression |
| [`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/) / [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/) | Public / private channel history for threaded comment notifications, reply imports/batching, and Slack link cards |
| [`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/) / [`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/) | Public / private channel information for name matching, email-suppression membership checks, and Slack link cards |
| [`im:history`](https://docs.slack.dev/reference/scopes/im.history/) plus [`im:read`](https://docs.slack.dev/reference/scopes/im.read/) / [`mpim:history`](https://docs.slack.dev/reference/scopes/mpim.history/) plus [`mpim:read`](https://docs.slack.dev/reference/scopes/mpim.read/) | Slack link cards from DMs / group DMs. Not needed to send ordinary reminder DMs |
| [`links:read`](https://docs.slack.dev/reference/scopes/links.read/) plus [`links:write`](https://docs.slack.dev/reference/scopes/links.write/) | Unfurling and refreshing Redmine URL Work Objects |
| [`commands`](https://docs.slack.dev/reference/scopes/commands/) | Slash commands and creating issues through a message shortcut |

Notifications and message responses share the [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) requirement. Combine the scopes above for the features you use. Choose public/private channel scopes according to the conversation type. Follow each feature link for its limits and detailed setup.

| Feature | Required Slack scopes | Additional Slack app setup | YAML and operational requirements |
| --- | --- | --- | --- |
| Channel notifications | [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) | Invite the bot to the destination | Bot Token, destination channel, `slack` queue worker |
| [Inline Issue images](#inline-issue-images) | [`files:write`](https://docs.slack.dev/reference/scopes/files.write/) | — | Supported images attached to Redmine |
| [Assignee mentions](#assignee-mentions) | No extra scope for explicit mappings; [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) for automatic name matching | — | `users` or `slack.auto_map_users_by_name: true` |
| [Match viewers by email](#match-viewers-by-email) | [`users:read`](https://docs.slack.dev/reference/scopes/users.read/), [`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/) | — | `slack.auto_map_users_by_email: true`, `slack.events.team_id` |
| [Match channels by name](#match-projects-to-channels-by-name) | [`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/) / [`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/) | Invite the bot to the channels | `slack.auto_map_channels_by_name: true` |
| [Work Object notification previews](#ticket-work-object-previews) | [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) | Enable Work Object Previews and select Task | `slack.work_object_previews: true` |
| [Work Object details](#ticket-work-object-previews) | No additional scope for details themselves | Subscribe to [`entity_details_requested`](https://docs.slack.dev/reference/events/entity_details_requested/) in Event Subscriptions | `slack.work_object_previews: true`, `slack.events`, user mapping |
| [Work Object URL unfurl/refresh](#ticket-work-object-previews) | [`links:read`](https://docs.slack.dev/reference/scopes/links.read/), [`links:write`](https://docs.slack.dev/reference/scopes/links.write/) | Subscribe to [`link_shared`](https://docs.slack.dev/reference/events/link_shared/); register the Redmine host in App unfurl domains | `slack.work_object_previews: true`, `slack.events`, user mapping |
| [Work Object edits/comments](#work-object-card-and-detail-actions) | No additional scope for the action itself | Enable Interactivity | `slack.work_object_previews: true`, `slack.work_object_actions: true`, `slack.events`, user mapping, Redmine action permissions |
| [Threaded comment notifications](#threaded-redmine-comment-notifications) | [`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/) / [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/) | No event subscription needed | `slack.comment_notifications_in_threads: true`, `slack.events.app_id` |
| [Import Slack replies as comments](#add-redmine-comments-from-notification-threads) | [`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/) / [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/), [`users:read`](https://docs.slack.dev/reference/scopes/users.read/); also [`files:read`](https://docs.slack.dev/reference/scopes/files.read/) for attachments | Subscribe to [`message.channels`](https://docs.slack.dev/reference/events/message.channels/) / [`message.groups`](https://docs.slack.dev/reference/events/message.groups/) | `slack.thread_comments: true`, `slack.events`, user mapping, Redmine comment/attachment permissions |
| [Create from a message](#create-an-issue-from-a-slack-message) | [`commands`](https://docs.slack.dev/reference/scopes/commands/) | Set the message shortcut callback ID to `slackmine_message_create`; enable Interactivity | `slack.slash_command`, global Bot Token and `slack.events`, user mapping, Redmine issue-creation permission |
| [Slash commands](#slash-command) | [`commands`](https://docs.slack.dev/reference/scopes/commands/), [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) for responses | Register the command; enable Interactivity | `slack.slash_command`, global Bot Token and `slack.events`, user mapping |
| [App Home](#app-home-issue-lists) | No additional scope for display itself | Enable Home Tab; subscribe to [`app_home_opened`](https://docs.slack.dev/reference/events/app_home_opened/); enable Interactivity for form controls | Global `slack.app_home: true`, Bot Token and `slack.events`, user mapping |
| [Due-date reminder DMs](#daily-due-date-dms) | [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/), [`im:write`](https://docs.slack.dev/reference/scopes/im.write/) | Enable Messages Tab | `due_reminders.enabled: true`, user mapping, daily rake task schedule |
| [Personal email suppression](#personal-email-preference) | [`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/) / [`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/); also [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) and [`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/) for automatic matching | Invite the bot to the destination | User's email-suppression preference, user mapping, recipient's channel membership |
| [Slack link cards in Redmine](#slack-message-cards-in-issue-text) | The conversation's [`*:history`](https://docs.slack.dev/reference/scopes/) and [`*:read`](https://docs.slack.dev/reference/scopes/), [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) | Bot membership in the conversation; no event subscription needed | `slack.link_cards.enabled: true`, Bot Token |

User mapping uses explicit `users` entries or email matching where supported. Automatic name matching does not authorize inbound viewing or editing. Slack scopes do not grant additional Redmine permissions.

| Slack app setting | Value and purpose |
| --- | --- |
| Event Subscriptions → Request URL | `https://redmine.example.com/slackmine/events`. Subscribe to the bot events for the enabled features |
| Interactivity & Shortcuts → Request URL | `https://redmine.example.com/slackmine/interactions`. Receives buttons, forms, and message shortcuts |
| Slash Commands → Request URL | `https://redmine.example.com/slackmine/commands`. Match the registered command name to `slack.slash_command` |
| Select Menus → Options Load URL | **Leave empty**. Slackmine sends options with its forms and does not need an external options endpoint |

Configure App ID, Team ID, and Signing Secret under `slack.events`. The Signing Secret is separate from the Bot Token. Restart Redmine and Sidekiq after YAML changes. Details, modals, and App Home have no dedicated additional OAuth scope; they still require setup and user mapping ([details](https://docs.slack.dev/reference/methods/entity.presentDetails/), [modals](https://docs.slack.dev/reference/methods/views.open/), [App Home event](https://docs.slack.dev/reference/events/app_home_opened/)).

A minimal configuration is:

```yaml
slack:
  # SLACK_BOT_TOKEN can supply the shared token instead.
  bot_token: 'xoxb-REPLACE-ME'
  default_channel_id: 'C0123456789'

projects:
  agentic:
    slack:
      bot_token: 'xoxb-AGENTIC-BOT-TOKEN'
      default_channel_id: 'C0234567890'
```

The plugin reads the first configuration file it finds:

1. `<Redmine root>/config/slackmine.yml`
2. `plugins/slackmine/config/slackmine.yml`

Behavior groups `slack`, `events`, `users`, and `due_reminders` can be overridden under `projects.<identifier>`. Put global `messages` and project-specific `projects.<identifier>.messages` in the separate `slackmine.messages.yml` file. Nested maps merge by key, so omitted project keys inherit the global value. Explicit `false` values override `true`. For Bot Tokens, the priority is `projects.<identifier>.slack.bot_token`, then `SLACK_BOT_TOKEN`, then global `slack.bot_token`. For channels, `projects.<identifier>.slack.default_channel_id` takes priority over the older `projects.<identifier>.channel_id`, then a unique automatic name match for that project when enabled. If neither resolves a channel, the same checks are applied to each ancestor from nearest to farthest, then global `slack.default_channel_id` is used. Project keys are Redmine **identifiers**, not display names. A missing token or channel prevents delivery and is logged. Channel IDs typically begin with `C` for public channels or `G` for private channels. Keep every project token out of Git and restart Redmine and Sidekiq after changing the YAML.

For example, this project uses its own token and channel, disables comment notifications, hides Issue project metadata, changes the card color, and overrides one Slack user mapping. Other settings retain their global values. The heading belongs in `slackmine.messages.yml`:

```yaml
projects:
  agentic:
    slack:
      bot_token: 'xoxb-AGENTIC-BOT-TOKEN'
      default_channel_id: 'C0234567890'
      attachment_color: '#123456'
      metadata:
        issue:
          project: false
    events:
      issue:
        comment:
          added: false
    users:
      alice: 'U0123456789'
```

The corresponding project-specific heading in the separate message file is:

```yaml
projects:
  agentic:
    messages:
      events:
        issue:
          created: 'New Agentic issue'
```

## Event switches

![Event switches](docs/images/features/event-notifications.webp)

The `events` tree controls delivery. The table gives every supported leaf and its default when omitted. `true` enables an event and `false` disables it; use YAML booleans, not quoted strings.

| Path below `events` | Default | Trigger |
| --- | :---: | --- |
| `issue.created` | `true` | Issue created |
| `issue.updated.enabled` | `true` | Parent switch for all Issue detail changes below |
| `issue.updated.other_changed` | `true` | Other Issue details, such as tracker |
| `issue.updated.status_changed` | `true` | Status |
| `issue.updated.assignee_changed` | `true` | Assignee |
| `issue.updated.priority_changed` | `true` | Priority |
| `issue.updated.category_changed` | `true` | Category |
| `issue.updated.due_date_changed` | `true` | Due date |
| `issue.updated.start_date_changed` | `true` | Start date |
| `issue.updated.version_changed` | `true` | Issue target version |
| `issue.updated.subject_changed` | `true` | Subject |
| `issue.updated.description_changed` | `true` | Description |
| `issue.updated.custom_field_changed` | `true` | Custom field |
| `issue.updated.attachment.added` / `.removed` | `true` | Attachment added / removed |
| `issue.updated.relation.added` / `.removed` | `true` | Relation added / removed |
| `issue.updated.parent_changed` | `true` | Parent Issue changed |
| `issue.updated.child.added` / `.removed` | `true` | Child Issue added / removed |
| `issue.comment.added` / `.updated` / `.deleted` | `true` | Issue comment added / edited / removed |
| `issue.deleted` | `true` | Issue deleted |
| `wiki.created` / `.updated` | `true` | Wiki page created / updated |
| `wiki.deleted` | `false` | Wiki page deleted |
| `news.created` / `.updated` | `true` | News created / updated |
| `news.deleted` | `false` | News deleted |
| `news.comment.added` / `.updated` / `.deleted` | `true` | News comment added / edited / removed |
| `time_entry.created` / `.updated` | `true` | Time entry created / updated |
| `time_entry.deleted` | `false` | Time entry deleted |
| `version.created` / `.updated` | `true` | Version record created / updated |
| `version.deleted` | `false` | Version record deleted |
| `project.updated` | `true` | Project updated |

`issue.updated.enabled: false` suppresses every Issue detail change, even when an individual detail leaf is `true`. It does **not** suppress `issue.comment.*`, `issue.created`, or `issue.deleted`. `news.comment.*` is independent of `news.updated`. `issue.updated.version_changed` refers to an Issue's target version; `version.updated` refers to editing a Version record.

When one Issue Journal changes several details and adds a comment, the plugin sends one notification containing the enabled parts. Disabled details are omitted. If no part is enabled, it sends nothing. Clearing an existing Issue Journal's notes is reported as `issue.comment.deleted`. Redmine's standard News screen has no comment-edit action, but updating a News Comment record can trigger `news.comment.updated`.

Set global switches under `events`, then override individual leaves for a project under `projects.<identifier>.events`:

```yaml
events:
  issue:
    updated:
      enabled: true
      status_changed: true
      due_date_changed: false
    comment:
      added: false

projects:
  agentic:
    channel_id: 'C0234567890'
    events:
      issue:
        comment:
          added: true
        updated:
          status_changed: false
```

A project override takes precedence over the global value for the same leaf. To override a globally disabled `issue.updated.enabled`, enable that parent for the project as well. Existing flat keys such as `status_changed`, `comment_added`, and `issue_updated` remain supported at either level. At the same level, a nested leaf wins over its flat equivalent. For legacy flat configuration, `issue_updated` controls both the parent switch and `other_changed`. The [example YAML](config/slackmine.yml.example) contains the full nested tree.

Deletion of Wiki pages, News, time entries, and Versions defaults to off because those notifications were added after the original events. Deletion links point to a containing project view because the deleted record's own page is gone.

Documents, files, and forum topics/replies support all of their standard
creation, editing, and deletion operations:

| Object | Notification switches |
| --- | --- |
| Document | `events.document.created`, `.updated`, `.deleted` |
| Document attachment | `events.document.file.added`, `.updated`, `.deleted` |
| Project/version file | `events.file.added`, `.updated`, `.deleted` |
| Forum topic/reply | `events.message.posted`, `.updated`, `.deleted` |

Creation and editing default to enabled; deletion defaults to disabled. All
switches support per-project overrides. Document edits include title,
description, and category; file edits include filename, description, type,
and digest; forum edits include subject, content, sticky, and locked state.
Internal timestamps, download counts, and reply counters do not generate edit
notifications. Notifications run after commit; rolled-back changes do not post.
Deletion links open the containing Documents, files, or board page.

Headings and icons can be customized globally or per project:

```yaml
messages:
  events:
    document:
      created: Document created
      updated: Document updated
      deleted: Document deleted
    file:
      added: File added
      updated: File updated
      deleted: File deleted
    message:
      posted: Forum message posted
      updated: Forum message updated
      deleted: Forum message deleted
  icons:
    document:
      created: '📄'
      updated: '✏️'
      deleted: '🗑️'
    file:
      added: '📎'
      updated: '✏️'
      deleted: '🗑️'
    message:
      posted: '💬'
      updated: '✏️'
      deleted: '🗑️'
```

Document attachments share `messages.events.file` and `messages.icons.file`
with project/version files. Issue attachments continue to use the Issue change
notification, without a second file notification. Redmine has no standard
Document/file/forum edit or deletion emails; these operations add only Slack
notifications. Due-reminder email remains outside mail suppression.

## Notification content

![Notification content](docs/images/features/notification-formatting.webp)

The card contains an event heading, a link to the Redmine record, and relevant text or changed fields. Issue creation and updates include the configured current-value metadata; comment-only and deletion notifications do not. Other event types show their metadata unless disabled below. `slack.attachment_color` changes the card's left border:

```yaml
slack:
  attachment_color: '#2E7D32'
```

The default is `'#6D5DFB'`. Use a quoted six-digit hex value; invalid values fall back to the default. Slack attachments preserve the card border and sections when Markdown lists or images appear.

`messages.colors` sets the left border color using the same type/action keys as `messages.icons`. Omitted or invalid values fall back to `slack.attachment_color`. Override colors per project under `projects.<identifier>.messages.colors`. A comment combined with field changes uses `issue.updated`, matching the icon. Due reminders continue to use `due_reminders.colors`.

```yaml
messages:
  colors:
    issue:
      created: '#2E7D32'
      updated: '#1565C0'
      deleted: '#C62828'
    comment:
      added: '#6D5DFB'
      updated: '#F79009'
      deleted: '#C62828'
```

For Issues, use one `slack.metadata.issue` map for both creation and updates. A field set to `true` appears whenever either notification is sent, even if it did not change. By default, `project`, `updater`, `tracker`, `category`, and `priority` are visible; the other Issue fields are hidden. Unset scalar values show `Not set`; empty lists show `None`. For other notification types, set `slack.metadata.<type>.<field>` to `false` to hide a field; unspecified fields remain visible. Available fields are:

| Type | Fields |
| --- | --- |
| `issue` | `project`, `updater`, `tracker`, `category`, `priority`, `status`, `assignee`, `author`, `target_version`, `start_date`, `due_date`, `estimated_hours`, `done_ratio`, `parent_issue`, `children`, `relations`, `attachments`, `watchers`, `custom_fields` |
| `wiki` | `project`, `updater`, `location` |
| `news`, `news_comment`, `project` | `project`, `updater` |
| `time_entry` | `project`, `updater`, `hours`, `spent_on` |
| `version` | `project`, `updater`, `status`, `due_date` |

Operation notification headings show the actor independently of metadata visibility. Configure each kind under `messages.notification_headers`: `issue`, `comment`, `wiki`, `document`, `file`, `message`, `news`, `news_comment`, `time_entry`, `version`, and `project`. All headers support `%{actor}`, `%{event}`, `%{icon}`, `%{project}`, `%{subject}`, `%{product_name}`, `%{noun}`, and `%{action}`. Issue and Comment headers also support `%{id}`. Project-specific message overrides apply. The legacy `templates.issue_updated_header` is used only when `notification_headers.issue` is not configured.

```yaml
messages:
  notification_headers:
    comment: "%{icon} %{actor} *%{event}*"
    news: "%{actor} · %{project} · *%{event}*"
  work_objects:
    product_name: Example Tracker
  commands:
    full_form: Open the full form in %{product_name}
```

`%{product_name}` is available in every message and resolves from the same project's `work_objects.product_name`. Other variables depend on the individual template.

For example, this shows the current status and target version on both new Issues and Issue updates, and hides the project on News notifications:

```yaml
slack:
  metadata:
    issue:
      status: true
      target_version: true
    news:
      project: false
```

Set a type such as `wiki: false` or `issue: false` to hide its entire metadata section. `slack.metadata: false` hides metadata everywhere. A section with no visible fields is omitted. `messages.fields` changes labels without changing visibility.

Related Issues and child Issues are linked when available; private Issues are omitted. Custom fields use Redmine's visible custom field values and can be selected by numeric ID:

```yaml
slack:
  metadata:
    issue:
      target_version: true
      relations: true
      custom_fields:
            '42': true
```

Issue updates also show a separate **Changes** section with the old and new values of changed fields. Changes to visible fields are always shown. By default, changes to hidden fields are shown too; set `slack.issue_changes_when_hidden: false` to omit them:

```yaml
slack:
  issue_changes_when_hidden: false
```

This switch does not hide the Issue description diff, the subject link, or comments. The `events.issue.updated` switches still decide which changes cause a notification and reach the formatter; this switch only controls whether changes to hidden metadata fields appear in the card. For `custom_fields`, a boolean shows or hides all visible custom fields; a map uses `default` for unspecified IDs. The IDs are Redmine custom field IDs, independent of field names and translated labels.

Custom field metadata uses Redmine's standard display formatting when the notification is generated. Enumeration IDs resolve to option names, user/version references resolve to names, and boolean values use Redmine's localized Yes/No labels. Multiple values are comma-separated; ordinary numeric fields remain numeric. No additional configuration or ID-to-name mapping is required.

Existing `metadata.issue.created` / `metadata.issue.updated` maps are still read for compatibility. Replace them with the single `metadata.issue` map when editing your YAML; do not mix the two forms. The former per-field `slack.issue_changes` map and `slack.issue_change_details` switch are no longer used. Use `issue_changes_when_hidden` for hidden-field changes and `events.issue.updated` for notification triggers.

Issue creation includes the description. New comments include their text. An Issue update shows only enabled detail changes and, when applicable, a description diff. A Wiki update shows the edit comment if provided and a body diff when its text changed; Wiki creation does not include the full page body. News creation includes a summary of its description. Deleted comments display removed lines. The record title links to the full content in Redmine.

Redmine Markdown is converted for Slack text. Numbered lists use Slack `markdown` blocks so repeated `1.` markers render as an ordered list. Markdown tables in notification summaries, comments, and changed bodies use Slack `markdown` blocks so pipe tables render as tables; this applies to Issue and non-Issue notifications. Content over Slack's 12,000-character Markdown-block limit falls back to [`mrkdwn`](https://docs.slack.dev/messaging/formatting-message-text/) sections.

### Ticket Work Object Previews

![Ticket Work Object Previews](docs/images/features/work-object-previews.webp)

Set `slack.work_object_previews: true` to add Slack **Task Work Object** metadata to public Issue creation, update, and comment notifications. Omitted or `false` preserves existing notifications. The event body, change diffs, colored attachments, and images remain; Slack can display an additional Work Object card. Deleted Issues, non-Issue notifications, and daily due-date DMs are excluded.

```yaml
slack:
  work_object_previews: true
  metadata:
    issue:
      status: true
      assignee: true
      due_date: true
projects:
  another-project:
    slack:
      work_object_previews: false
```

You can also disable this globally and enable it for individual projects. Restart both Redmine and Sidekiq after changing YAML.

In the Slack app settings, enable **Work Object Previews**, select **Task**, and save. Check workspace preview restrictions too. Notifications use the existing [`chat.postMessage`](https://docs.slack.dev/reference/methods/chat.postMessage/) call; notification previews alone do not require new event subscriptions or link-unfurl scopes. See [Slack's notifications implementation](https://docs.slack.dev/messaging/work-objects-implementation/#notifications-implementation).

The header contains the subject, Issue number, and tracker. Standard fields include status, priority, assignee, author, and due date only when enabled by `slack.metadata.issue`. Project, tracker, category, updater, and target version use custom fields with the same visibility settings and `messages.fields` labels. When a Work Object is present, the notification omits its duplicate subject link and current metadata fields. Comments, descriptions, before/after changes, and fields absent from the Work Object remain in the event card. Assignees and authors use display names without introducing mentions or additional user-directory requests.

The SHA-256 digest of the Issue URL is used as `external_ref.id` to satisfy Slack's ID character restrictions, keeping creation, updates, and comments associated with the same object while distinguishing identical Issue numbers on different Redmine instances. Changing the Redmine hostname changes this identity. The link's `url` remains the original Issue URL.

Notification cards contain a **snapshot from notification generation**. Opening a card or refreshing its detail pane sends [`entity_details_requested`](https://docs.slack.dev/reference/events/entity_details_requested/); the plugin returns current Issue data through [`entity.presentDetails`](https://docs.slack.dev/reference/methods/entity.presentDetails/). See [Slack's details API](https://docs.slack.dev/reference/methods/entity.presentDetails/).

Slack's built-in Work Object refresh uses [`link_shared`](https://docs.slack.dev/reference/events/link_shared/) and [`chat.unfurl`](https://docs.slack.dev/reference/methods/chat.unfurl/). Configure [`links:read`](https://docs.slack.dev/reference/scopes/links.read/), [`links:write`](https://docs.slack.dev/reference/scopes/links.write/), the [`link_shared`](https://docs.slack.dev/reference/events/link_shared/) subscription, and the issue URL host under **App unfurl domains**, then reinstall the app after changing scopes or domains. If Slack returns [`cannot_unfurl_url`](https://docs.slack.dev/reference/methods/chat.unfurl/#errors), check **Workspace settings → Attachments → Blocked previews**: domain blocks prevent both initial unfurls and refreshes even with correct app permissions. See [Slack's refresh event specification](https://docs.slack.dev/reference/events/link_shared/).

To enable details, configure the Slack app and workspace IDs and the **Basic Information → App Credentials → Signing Secret**. This is separate from the Bot Token; `SLACK_SIGNING_SECRET` can supply it instead.

```yaml
slack:
  work_object_previews: true
  events:
    app_id: 'A0123456789'
    team_id: 'T0123456789'
    signing_secret: 'REPLACE-ME'
users:
  alice: 'U0123456789' # Replace with the actual Slack member ID
```

1. Deploy the code and YAML, restart Redmine and Sidekiq, and ensure Sidekiq consumes the `slack` queue.
2. Enable **Event Subscriptions** in the Slack app. Set Request URL to `https://redmine.example.com/slackmine/events` and confirm **Verified**. Adjust the host and any Redmine installation subdirectory for your deployment.
3. Add [`entity_details_requested`](https://docs.slack.dev/reference/events/entity_details_requested/) under **Subscribe to bot events** and **Save Changes**. No additional OAuth scopes are required for this event or [`entity.presentDetails`](https://docs.slack.dev/reference/methods/entity.presentDetails/).
4. Open a Work Object card and check status, assignee, due date, and description. Change the Issue in Redmine and refresh the detail pane to verify the current values. A new notification is unnecessary.

The endpoint verifies the signature, timestamp, app, and workspace before directly processing Work Object requests in the receiving Web process. Authorization uses explicit `users` mappings from Redmine login/email to Slack ID or enabled `auto_map_users_by_email` matching; `auto_map_users_by_name` is never used to grant access. Unmapped, locked, or unauthorized users, private Issues, inactive projects, and projects with previews disabled receive a restricted response without Issue content. Project-specific apps can override `projects.<identifier>.slack.events` and `users`.

Authorized details include the current title, Issue ID, tracker, project, status, priority, assignee, author, due date, creation/update timestamps, and description (up to 10,000 characters). Detail fields are independent of notification `slack.metadata.issue` settings. Existing comments, Redmine custom fields, and pasted-link unfurls are not included. Editing can be enabled with the setting below.

Failures are logged in Redmine/Sidekiq as `Work Object details failed` or `Work Object unfurl failed`, with the Slack API error code. Successful reads do not produce diagnostic logs. If Slack returns `missing_interactivity_url`, configure the app's **Interactivity & Shortcuts** Request URL.

### Work Object card fields

Card fields follow the YAML key order in `work_object_fields`, skipping disabled and empty fields. Description and Last comment are not pinned to the end. Project-specific keys appear first in their configured order, followed by inherited fields in global configuration order.

Use `slack.work_object_fields` to toggle every supported card body field with `true` or `false`. Unspecified fields are hidden. Explicit field settings override action-enabled defaults and notification `metadata.issue` settings. Empty values are omitted, except unassigned assignees and progress of `0%`. Progress is displayed as an exact percentage, without a bar.

Omitting this map hides all card body fields. Override it per project under `projects.<identifier>.slack.work_object_fields`. These settings control the main card body, not the required title/issue identity, detail pane, or editing permissions.

```yaml
slack:
  work_object_fields:
    status: true
    assignee: true
    priority: true
    due_date: true
    category: true
    done_ratio: true
    project: false
    tracker: false
    author: false
    updater: false
    target_version: false
    start_date: false
    estimated_hours: false
    description: false
    last_comment: false
```

`last_comment: true` displays the latest public comment with its author and ISO 8601 timestamp. Private and empty notes are excluded; the body is limited to 1,000 characters. An identical complete comment body is omitted from the notification only when it is not truncated. Edit/delete diffs are preserved. Refreshing the card fetches the latest public comment.

`description: true` displays the issue description in the card. Blank descriptions are hidden and text beyond 1,000 characters is truncated. The detail pane description is unchanged.

All built-in display text defaults to English. Override buttons, dialogs, and errors with `messages.work_objects`, editor field labels with `messages.fields`, and the unassigned label with `messages.values.unassigned`. The [message example](config/slackmine.messages.yml.example) lists every key. `edit_title` and `edit_failed` support `%{id}`. Slack-owned labels and menus follow Slack language settings.

The card open button links to the issue URL. Configure its label with `messages.work_objects.open_issue`, which supports `%{product_name}`.

The main card Add comment button opens a comment-only modal. It requires comment permission and cannot change issue attributes. Editing remains available in the detail pane. Configure the label with `messages.work_objects.add_comment`.

### Work Object card and detail actions

Work Object details, form opening, and short edits run in the receiving Web process. Post-save card and App Home refreshes and URL unfurls use the `slack` queue. Edits containing Slack links also queue their save because quote imports may take longer; detail-panel results go to the Slack app Messages tab. Thread connection opens a loading form immediately and tries history review in the Web process; reviews exceeding two seconds fall back to Sidekiq. Connection saving stays queued. App Home list publishing and slash command delivery use Sidekiq. Notifications, reminders, and reply imports continue to use jobs.

Identical interaction redeliveries are suppressed by storing a SHA-256 digest of the verified body and an acceptance marker in the existing `Rails.cache` for ten minutes. Submitted text and permissions are not cached. Suppression across Web processes requires a shared cache with atomic `unless_exist` support. Cache loss or disabling the cache can still allow duplicates; a failure before saving also prevents replay of that same request. Check the Redmine result before starting a new action.

Direct operations still wait for database and Slack API calls, so the three-second acknowledgement deadline is not guaranteed. Verify details, modal opening, and job completion after deployment. Check both `Slackmine: Work Object ... duration_ms=...` logs and Sidekiq. Restart Web and Sidekiq processes to load the deployed code.

![Work Object card and detail actions](docs/images/features/issue-actions.webp)

Set `slack.work_object_actions: true` to show status, assignee (including unassigned), priority, and due date plus the Add comment and Open in source service buttons on every public Issue Work Object card with previews enabled. Set `work_object_actions: false` to disable these features. Edit issue opens a Slack modal for permitted status, assignee, priority, due date, and comment changes. The default is disabled. Enable **Interactivity & Shortcuts** in the Slack app and set its Request URL to `https://redmine.example.com/slackmine/interactions`. The same `slack.events` signing configuration authenticates the requests.

```yaml
slack:
  work_object_previews: true
  work_object_actions: true
```

Fields and buttons embedded in previously posted cards do not update automatically; those messages need a new notification or an in-place update. The detail pane fetches the current issue whenever it opens.

Edit issue includes a picker with assignable Redmine users and an unassigned option. The detail pane also exposes permitted assignee, status, priority, and due date edits and a blank comment input. Assign to me makes no change if the viewer already owns the issue. The modal lists assignable users and an unassigned option when the list has at most 99 users. Every submission rechecks the Slack-to-Redmine user mapping, issue visibility, edit and note permissions, status workflow, active priorities, and assignable users before writing to Redmine. After an edit, the plugin refreshes the originating card or detail pane with the latest issue state. A Slack API failure during card refresh is logged without retrying an already saved Redmine change.

The Work Object's conversation view is separate from Redmine's comment history. Existing Redmine comments are not displayed there. For issues with actions enabled, a new Redmine comment can be added from the detail pane's edit form. Posting comments from notification threads is available through the following setting.

### Work Object button selection and order

Use `slack.work_object_buttons` booleans and YAML key order to select actions on cards and detail panes. When configured, omitted buttons are hidden; omitting the entire map preserves the previous button layout. Project keys precede inherited global keys.

```yaml
slack:
  work_object_actions: true
  work_object_buttons:
    add_comment: false
    reply: false
    open_issue: false
    edit_issue: false
    change_assignee: false
    assign_to_me: false
    start_work: true
    complete_work: true
    log_time: false
    watch: false
  work_object_start_status_id: 3
  # Completion status ID; use the actual completed status from your workflow.
  work_object_complete_status_id: 5
```

The example enables only Start work and Complete work, using status IDs 3 and 5. Adjust these IDs to your Redmine workflow.

Supported keys: `add_comment` (comment-only modal), `reply` (return to the most recent former assignee and add a comment), `open_issue` (source issue URL), `edit_issue` (edit modal), `change_assignee` (assignee-only modal), `assign_to_me`, `start_work`, `complete_work`, `log_time`, `watch` (both watch and unwatch).

The first two available actions are primary buttons and the next five are overflow actions. Only seven are displayed; additional actions are omitted with a warning log. `start_work` requires `work_object_start_status_id`; `complete_work` requires `work_object_complete_status_id` and both validate the current workflow on submission. Each is hidden when its target ID is unset or already reached. When both buttons are enabled, only Start work is shown before starting; only Complete work is shown at the configured start status. Both buttons are hidden at the completion status or any Redmine closed status. Configure both status IDs. A single enabled button retains its independent behavior. Choose your actual completion status ID; no status is inferred from its name. `log_time` opens the Redmine time-entry form, where permissions and required fields are enforced. Watch actions affect only the acting user and are idempotent.

Detail panes filter actions for the viewer's permissions, assignee, and watcher state. Shared cards cannot personalize buttons per viewer, so permissions and personal state are checked when invoked. Labels use the corresponding `messages.work_objects` keys.

Enable `reply: true` to show a Reply button. It selects the most recent different former assignee from assignment history and saves reassignment with the comment. If history is unavailable, the former assignee is inactive or not assignable, or the viewer cannot change the assignee, it adds only the comment. Comment permission is required. Opening the modal does not change the issue; history and permissions are checked again when saving. `add_comment: true` adds only a comment. Customize the Reply label and modal explanation with `messages.work_objects.reply` and `reply_hint`.

To show both buttons:

If a button is missing, check that `add_comment` / `reply` is `true`, including any project override. A `false` or omitted entry in the button map hides that action independently of the seven-action limit. Put comment and reply first, as below, to prioritize them as the two primary buttons. Existing cards may retain older actions; check a new notification or reload the card.

```yaml
slack:
  work_object_actions: true
  work_object_buttons:
    reply: true
    add_comment: true
```

Description editing is available in the Work Object detail pane and the Issue edit modal when Redmine allows the acting user to edit `description`. The full raw text is used, including whitespace and Markdown. Slack text inputs support at most 3,000 characters: longer existing descriptions remain read-only and the modal links to the full Redmine edit form. Long descriptions are never shortened for saving. Clearing an editable description saves an empty value. Saves recheck permissions and record changes through the normal Redmine journal and notification path.

With `watch: true`, both shared cards and detail panes open Watch settings showing your current state and a Watch or Unwatch submit button. The current state is checked on click, so a stale Watch/Unwatch label cannot prevent switching the setting. Opening the form does not change the watch state. Watch forms open synchronously to avoid queue delays expiring Slack modal triggers; confirmation also saves synchronously in the Web process. Input-free confirmation payloads are accepted. There is no separate `unwatch` button setting. Labels use `messages.work_objects.watch_settings`, `watching`, `not_watching`, `watch`, and `unwatch`.

### Match viewers by email

Set `slack.auto_map_users_by_email: true` to authorize Work Object details and Slack thread replies by matching the Slack member's email to exactly one active Redmine user's registered email address (including additional addresses). Matching is case-insensitive. Existing `users` mappings take priority, including mappings that are invalid, locked, ambiguous, or assign the Redmine user to another Slack identity; email matching does not bypass them. Issue visibility and comment permissions are still checked.

```yaml
slack:
  auto_map_users_by_email: true
```

Add both [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) and [`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/) Bot Token scopes, then reinstall the app. The plugin fetches fresh identity data with [`users.info`](https://docs.slack.dev/reference/methods/users.info/) for each authorization. Missing email, multiple active Redmine matches, inactive users, bots, deleted Slack users, foreign-workspace identities, and API failures deny automatic access. The configured `slack.events.team_id` must match the Slack identity's workspace. Email identity data is not cached or saved in a new table, Redis, or a file, and is not included in diagnostic logs. Override the switch under `projects.<identifier>.slack.auto_map_users_by_email`.

This is distinct from `auto_map_users_by_name`, which only resolves outgoing mentions and due-reminder recipients. Email matching is for incoming viewer/comment authorization and does not automatically enable outgoing mentions or DMs.

### Inherit a parent project channel

![Inherit a parent project channel](docs/images/features/channel-routing.webp)

For each level, the plugin first checks explicit `slack.default_channel_id` or legacy `channel_id`, then a unique match between the Redmine display name and an existing Slack channel when automatic matching is enabled. It starts with the issue's own project, then follows the actual Redmine parent hierarchy from nearest to farthest. The global default is used only if no project in the hierarchy resolves a channel. Thus a child with no matching channel can use its parent's existing channel without repeating channel IDs in YAML. A child's own name match takes priority over any ancestor setting.

This applies only to destination channels; bot tokens, events, messages, users, and reminder settings keep their existing global/project rules. The bot used by the child must have access to the selected channel. Moving a project changes its inherited destination. `slack.auto_map_channels_by_name: true` must be enabled for the child to search names throughout the hierarchy; each ancestor also uses its own effective automatic-matching setting. Setting it to `false` on the child disables all name lookup, while explicit ancestor channels remain available.

```yaml
projects:
  parent-project:
    channel_id: 'C0123456789'
  # Children with no channel override use the parent-project channel.
```

### Match projects to channels by name

Enable `slack.auto_map_channels_by_name: true` to match Redmine project **display names** to Slack channel names. Names are trimmed and compared case-insensitively; whitespace becomes a hyphen (`Customer Support` → `customer-support`). Project identifiers are not used for matching. No fuzzy matching, channel creation, or automatic joining is performed.

```yaml
slack:
  auto_map_channels_by_name: true
  default_channel_id: 'C0123456789' # Optional fallback
projects:
  example:
    slack:
      auto_map_channels_by_name: false
      default_channel_id: 'C0234567890'
```

Routing checks each project from child to root: explicit `slack.default_channel_id`, legacy `channel_id`, then a unique automatic name match. The first resolved channel wins; global `slack.default_channel_id` is used only after exhausting the hierarchy. A missing match, ambiguous match, or API failure uses the global fallback; without a fallback, delivery is skipped and logged. The switch can be overridden per project.

The plugin uses [`users.conversations`](https://docs.slack.dev/reference/methods/users.conversations/) to list only channels the Bot belongs to. Add [`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/) for public channels and [`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/) for private channels, then reinstall the app. These are separate from the [`*:history`](https://docs.slack.dev/reference/scopes/) scopes used for threaded notifications. Archived channels and DMs are excluded. Listings are cached by Bot Token in process memory for ten minutes; no DB, Redis, file storage, or Rails cache is used. Rename/membership changes can take up to ten minutes to be reflected; restarting workers clears their caches. Listing is bounded to ten pages of 200 channels; incomplete or failed listings are not used for matching. Each worker has its own cache.

Automatic routing also applies to comment notification threads and Slack-to-Redmine thread replies. Projects do not need YAML entries to participate when the global switch is enabled; existing reply permissions and explicit user mappings or enabled email matching still apply.

### Threaded Redmine comment notifications

![Threaded Redmine comment notifications](docs/images/features/comment-threads.webp)

Set `slack.comment_notifications_in_threads: true` to post comment-only additions, edits, and deletions in the latest matching Issue notification thread in the configured channel. Omitted or `false` keeps channel posts. Updates that also contain enabled Issue changes remain channel posts. When a thread is found, new comments show a configurable heading and the formatted comment body, without repeating the Issue link, full event card, or Work Object preview. Comment edits retain the configured body/diff presentation; deletions retain the removal diff. Images continue to be supported. Channel fallback uses the full notification. This option works independently of `slack.thread_comments` and Work Object Previews.

```yaml
slack:
  comment_notifications_in_threads: true
  events:
    app_id: 'A0123456789'
```

Override per project under `projects.<identifier>.slack.comment_notifications_in_threads`. The Bot must belong to the channel and have [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/) for private channels or [`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/) for public channels; reinstall the app after adding scopes. `slack.events.app_id` identifies this app's notifications. No new Event Subscription is required for outgoing comment notifications.

Customize the compact notification heading with `messages.thread_notifications.added_header`, `updated_header`, and `deleted_header`. Templates support `%{product_name}`, `%{id}`, `%{actor}`, and `%{subject}`, including project-specific overrides under `projects.<identifier>.messages`. Defaults and examples are English. The heading is separate from the comment body, which is displayed only once. References to the current Issue using `#%{id}` in the heading automatically link to its Redmine page.

```yaml
messages:
  thread_notifications:
    added_header: '%{actor} · %{product_name} #%{id}: New comment'
    updated_header: '%{actor} · %{product_name} #%{id}: Comment updated'
    deleted_header: '%{actor} · %{product_name} #%{id}: Comment deleted'
```

Each delivery searches up to three history pages, requesting 100 messages per page (Slack may return fewer). Only root notifications from the configured app with the exact Issue subject link qualify; user messages, links in comment bodies, and broadcast replies do not. Missing matches, missing app configuration, and lookup errors fall back to a normal channel post. No thread mapping is saved in a database, Redis, or a file. The latest notification may differ from the thread where a conversation started; older threads outside the search range are not found. History requests add latency and consume Slack API rate limits. Existing cards are not moved.

### Add Redmine comments from notification threads

![Add Redmine comments from notification threads](docs/images/features/thread-replies.webp)

Set `slack.thread_comments: true` to save text and file replies to this plugin's Issue notifications as Redmine comments authored by the replying user. Omitted or `false` disables the feature. Work Object Previews are optional.

```yaml
slack:
  thread_comments: true
  events:
    app_id: 'A0123456789'
    team_id: 'T0123456789'
    signing_secret: 'REPLACE-ME'
users:
  alice: 'U0123456789' # Actual Slack member ID
projects:
  another-project:
    slack:
      thread_comments: false
```

Bot messages and human replies that `@mention` a Bot or app user are always excluded from comment imports, with no result feedback. Mentions of human users remain eligible. Batched imports also exclude Bot-directed posts. Recipient verification requires the Bot Token scope [`users:read`](https://docs.slack.dev/reference/scopes/users.read/); temporary lookup failures retry the job without importing an unverified reply.

For private channels, add the Bot Token scope [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/) and subscribe to [`message.groups`](https://docs.slack.dev/reference/events/message.groups/). Public channels use [`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/) and [`message.channels`](https://docs.slack.dev/reference/events/message.channels/). Reinstall the app after adding scopes. Request URL and signature verification are shared with Work Object details. The bot must be a member of the channel. See [Slack's message events](https://docs.slack.dev/reference/events/message/).

When effective `restrict_transfer` or global `force_restrict_transfer` is `true`, file replies retain the source message permalink without using `files:read`. See [File-transfer restriction for audit and internal policies](#file-transfer-restriction-for-audit-and-internal-policies).

Normal file imports (including file-only posts) require the Bot Token scope [`files:read`](https://docs.slack.dev/reference/scopes/files.read/); reinstall the app after adding it. PDF, Office documents, archives, text files and other Slack-hosted files are downloaded using bot authorization and saved as ordinary Redmine Issue attachments under the replying user. PNG, JPEG, GIF and WebP images are validated and displayed inline. Other formats, including SVG and video, are saved as `attachment:"filename"` references and shown as filename links to Redmine’s attachment viewer. Preview availability depends on Redmine and the file type. The importer records attachment IDs in the saved Slack quote metadata so only explicitly associated attachments appear inside their card, between the message body and “Open in Slack”. Ordinary notes and older replies without this metadata keep their existing layout; when no card is available, attachment references remain below the source permalink. Image references use attachment filenames, preserving `@2x` suffixes for Redmine’s image sizing. A reply can contain up to 10 files, each no larger than 10 MiB or Redmine’s configured attachment limit (whichever is lower), and at most 50 MiB in total. Redmine attachment permissions and extension restrictions apply. Files and the comment are saved in the same transaction; a failed download or invalid attachment does not leave a partial comment. Retries do not duplicate saved attachments. External files are unsupported. Rejected file replies receive failure feedback; transient API/network errors are retried by the job.

No extra tables, DB migrations, or Redis processing-state entries are required. The plugin fetches only the parent notification through [`conversations.history`](https://docs.slack.dev/reference/methods/conversations.history/), verifies its app ID and canonical Issue subject URL, and accepts replies only in channels currently configured as notification destinations. Existing notifications are supported. Replies to other apps, users, or arbitrary Issue links are ignored.

Work Object cards can appear in history responses as only a `from_url` and attachment ID while Slack prepares the full card. The plugin also recognizes this reduced form when the authenticated app notification's first Issue reference in its fallback matches the single canonical card URL. Conflicting or ambiguous references remain ignored. Successful comment saves receive a confirmation in the same Slack thread.

Authorization requires an explicit `users` mapping or enabled unique email matching to an active Redmine user, Issue visibility, and tracker-aware permission to add notes. Private Issues, inactive projects, and unmapped users are denied. Replies with up to 10,000 characters are accepted. The comment stores the source message permalink; the existing quote importer can save its text and display it as a card when link cards are enabled. The existing Journal `created_on` and `updated_on` are both set to the original Slack posting time, parsed without floating-point conversion, so a new imported comment is not marked as edited. Later Redmine edits update the normal edit timestamp. The Issue, mapped author, and posting time identify repeated deliveries. The existing Issue row lock serializes duplicate checks and comment saves. No additional tables, columns, Redis state, or state files are required. Editing the comment text does not affect duplicate detection. Legacy comments containing provenance lines are still recognized as duplicates.

Reliable duplicate detection requires the existing `journals.created_on` column to preserve microseconds (six fractional digits). Lower timestamp precision may treat distinct replies from the same author as duplicates. A different comment by the same mapped author on the same Issue at the exact same timestamp is also treated as a duplicate. Deleting the comment or changing its author or posting time removes its duplicate protection. Existing provenance lines are not removed automatically.

Customize the service name shown in Work Object cards and detail headers/open buttons with `messages.work_objects.product_name` (default: `Redmine`). Thread reply feedback supports `%{id}` and `%{product_name}`. References using `#%{id}` automatically link to the Issue, including success and restriction feedback. All these keys support overrides under `projects.<identifier>.messages`.

```yaml
messages:
  work_objects:
    product_name: 'Example Tracker'
  thread_comments:
    saved: '✅ Comment added to %{product_name} #%{id}.'
    restricted: '⚠️ Could not add the comment. Check your permissions.'
```

These settings affect new notifications and freshly requested details. Existing notification cards are not rewritten. Slack-owned UI text such as “Details” and “Conversations” follows Slack’s language settings.

Replies are saved immediately by default (`wait_seconds` omitted or `0`). The example below enables batching: consecutive replies from the same Slack user in the same thread are combined into one Redmine comment after 60 seconds of silence, or at most 300 seconds from the first reply. Omitted `max_wait_seconds` defaults to 300. A reply from another user closes the preceding group, so A → A → B → A becomes three comments in source order; Bot feedback does not split human turns. The batch is displayed in one card with a single author/time header and the combined text. Short replies are separated by a single line break, and the card has one Open in Slack link. All source URLs are retained in the saved quote data and attachments are imported together; saving feedback is sent once. Different users, threads, apps and workspaces are kept separate. At most 20 messages are combined; the existing text/file limits apply to the whole batch. These timings are scheduled deadlines; a busy worker can save later.

```yaml
slack:
  thread_comment_batch:
    wait_seconds: 60      # omitted or 0 saves immediately
    max_wait_seconds: 300
  thread_comment_feedback_cleanup_seconds: -1
```

Project overrides are supported. Delayed jobs carry the source event, then fetch the thread from Slack with [`conversations.replies`](https://docs.slack.dev/reference/methods/conversations.replies/); there is no new DB table or cache buffer. The worker must support ActiveJob delayed jobs (e.g. Sidekiq), and the Bot needs access to the replies API for the channel. No Slack message is posted while waiting. Existing replies are not retroactively combined. History retrieval is limited to 1000 messages; larger threads fail rather than saving an incomplete batch. Restart Redmine and the worker after changing YAML.

During an ongoing Slack thread conversation, a “Comment added” confirmation after every reply can make the exchange harder to follow. Optional automatic cleanup gives participants time to check the result, then removes the Bot’s feedback to keep the conversation easy to read. For example, `slack.thread_comment_feedback_cleanup_seconds: 60` removes feedback 60 seconds after it is posted. This applies to success, permission-denial, and file-rejection messages.

`slack.thread_comment_feedback_cleanup_seconds` controls the delay before deletion. The default is `-1` (keep messages); `0` skips posting all result messages, including success, denial, and failure feedback and a positive value specifies the delay in seconds. Invalid values also disable cleanup. Override it under `projects.<identifier>.slack`. Original Slack replies and Redmine comments remain. Automatic deletion with a positive delay requires a worker supporting scheduled jobs (such as Sidekiq); deletion may run later depending on worker availability. Changing the setting to `-1` before a queued deletion runs also cancels that deletion.

The result is posted to the same thread. Customize the text with `messages.thread_comments.saved` (supports `%{id}` and `%{product_name}`) and `messages.thread_comments.restricted`. File rejection feedback uses `messages.thread_comments.image_failed`. The normal Slack notification for the newly saved comment is suppressed; standard Redmine email notifications and other callbacks still run. Bot messages and Slack edits/deletions are not synchronized. Replies containing inaccessible, oversized or invalid files are rejected in full. Slack mentions and link syntax are not converted to Redmine markup. If result feedback fails after saving, the comment remains saved and the failure is logged. Disabling the feature keeps previously saved comments.

Set `slack.suppress_thread_comment_notifications: false` to send normal Slack notifications for imported comments. Omitted or `true` keeps suppression enabled. Event switches and `comment_notifications_in_threads` still apply; saving feedback is sent independently. Override per project under `projects.<identifier>.slack.suppress_thread_comment_notifications`. This switch does not change email notification behavior. Restart Redmine and the worker after changing YAML.

```yaml
slack:
  thread_comments: true
  suppress_thread_comment_notifications: false
```

After deploying code and YAML, restart Redmine and Sidekiq. Reply to a test Issue notification and verify the author, exact comment text, and success response. Also check unauthorized users, bot replies, and Slack edits to ensure they do not add comments.

### Body diffs

By default, edits to Issue descriptions and comments, Wiki and forum message bodies, News descriptions and comments, and Document descriptions show a line diff. The `diff` code block marks removed lines with `-` and added lines with `+`, with two unchanged lines of context. Long lines and large diffs are shortened; follow the record link for the full text. A Wiki edit that changes only its edit comment has no body diff. `document.description` controls Document description diffs; `message.body` controls forum topic and reply body diffs. Forum edits display the diff or updated body once. File notifications show the description as text and do not generate body diffs.

Set `slack.body_diff` for each type. `false` shows the updated text instead of a diff:

```yaml
slack:
  body_diff:
    issue:
      description: true
      comment: false
    wiki:
      body: true
    news:
      description: false
      comment: true
    document:
      description: true
    message:
      body: true
```

Missing entries default to `true`. Setting `issue`, `wiki`, `news`, `document`, or `message` to `false` disables diffs for all children of that parent. The older scalar form, `body_diff: true` or `body_diff: false`, still applies to every type. Deleted Issue and News comments **always** show their removed lines as a diff, regardless of this setting.

### File-transfer restriction for audit and internal policies

Companies with strict audit or internal policies limiting external file transfers and copies can exchange links to the original source instead of transferring file contents.

```yaml
slack:
  files:
    restrict_transfer: true
    force_restrict_transfer: false
```

When enabled, Redmine images are linked to their attachment pages instead of uploaded to Slack. Incoming Slack replies retain the source message permalink without fetching file metadata, downloading contents, or saving attachments. File-only replies also save a permalink. Text and quote cards continue through the existing import flow. Attachment-add permission is unnecessary in this mode; Issue visibility and comment-add authorization still apply.

The global setting is the default. Override it per project with `projects.<identifier>.slack.files.restrict_transfer`. For example, use links globally while allowing file transfers for an approved project:

```yaml
slack:
  files:
    restrict_transfer: true
projects:
  file-sharing-project:
    slack:
      files:
        restrict_transfer: false
```

To prohibit exceptions under company policy, set global `slack.files.force_restrict_transfer: true`. It takes precedence over both global and project `restrict_transfer: false`, restricting file transfers for every project. `force_restrict_transfer` is global-only; project values are ignored. It defaults to `false`.

```yaml
slack:
  files:
    force_restrict_transfer: true
```

Projects without an override inherit the global `restrict_transfer` setting. When enforcement is off and `restrict_transfer` is omitted or effectively `false`, existing file transfers are preserved. Restart web and job-worker processes after changing the configuration. Queued jobs use the setting when executed. Previously transferred files and saved comments are retained. Opening a source link requires access to the original service.

Link-only mode also disables automatic link and media previews on outgoing Slack messages.

This option restricts file-content transfers by Slackmine. Conversation text, URLs, and filenames still pass through the integration; enabling it alone does not establish compliance with all audit requirements. It does not control other integrations or users uploading files directly to Slack.

### Inline Issue images

The following applies when file-transfer restriction is off. When effective `restrict_transfer` or global `force_restrict_transfer` is `true`, images become links as described in [File-transfer restriction for audit and internal policies](#file-transfer-restriction-for-audit-and-internal-policies).

For new public Issues and public Issue comments, the plugin recognizes local Markdown image references such as `![](screenshot.png)`. On creation, it can upload a matching image attached to the Issue; for comments, it uses images attached to the same Journal. Supported formats are PNG, JPEG, and GIF. Images appear inside the colored card. It does not fetch remote URLs or filesystem paths. Images must be nonempty and at most 20 MiB. The Bot Token needs [`files:write`](https://docs.slack.dev/reference/scopes/files.write/).

This also applies when an existing public Issue comment is edited. With `body_diff.issue.comment: false`, an eligible image appears at its Markdown position in the updated text. With `true`, image previews appear after the comment diff. Deleted comments do not re-upload images. A successful upload replaces the Markdown reference without adding a duplicate attachment link. If a recognized image cannot be uploaded, including when it exceeds the size limit, the notification contains a link to its Redmine attachment or Issue.

To share a newly uploaded private file with the channel, the plugin posts a temporary top-level reference along with the complete colored card, then removes the temporary preview with [`chat.update`](https://docs.slack.dev/reference/methods/chat.update/). If cleanup fails, it logs the error without reposting the notification. A newly uploaded file that is not ready yet is retried briefly. Already posted Slack messages are not rewritten when this plugin is updated.

### Wording and templates

The `messages` tree in `slackmine.messages.yml` changes notification wording, icons, and colors; it does not control whether an event is sent. All keys are optional. Omitted or empty strings use built-in defaults. `messages.templates.icon_fallback` sets the icon for unknown events. The [English](config/slackmine.messages.yml.example) and [Japanese](config/slackmine.messages.ja.yml.example) examples list every available key with sample values:

English defaults are stored in [config/slackmine.messages.yml.example](config/slackmine.messages.yml.example), with a [Japanese example](config/slackmine.messages.ja.yml.example) available to copy. Put customized wording in a Git-ignored `config/slackmine.messages.yml`; a file in the Redmine application's `config` directory takes precedence over one in the plugin directory. Project overrides belong under `projects.<identifier>.messages` in the same file. During migration, the plugin still reads legacy `messages` values from `slackmine.yml`, but the separate message file wins. Thread connection dialogs, feedback, errors, and the saved history heading use `messages.thread_connections`. Slack quote cards and their plain-text fallbacks use `messages.link_cards`. Unknown event and relation labels use `messages.templates.event_fallback` and `relation_fallback`. Legacy `slack.link_cards.link_text` applies only when the separate file does not set `messages.link_cards.open`.

```yaml
messages:
  thread_connections:
    title: Connect a thread
    close: Close
    connect: Connect
    connected: This thread is connected. Future replies and attachments will be saved.
    history_heading: Conversation imported before connection
  link_cards:
    open: Open in Slack
    parent_open: Open parent message in Slack
    reply_count: '%{count} thread replies'
projects:
  example:
    messages:
      thread_connections:
        connect: Connect to this project
```

The initial dialog uses global wording because no Issue has been selected yet. Once the Issue is known, dialogs and feedback use its project's overrides. Keep each template's `%{...}` placeholders as shown in the default YAML. Invalid placeholders fall back to the default template. Changing the saved history heading affects new imports; existing comments are retained.

| Group | Controls |
| --- | --- |
| `messages.events` | Visible event labels such as `Issue updated` |
| `messages.icons` | Event emoji |
| `messages.colors` | Event card border colors |
| `messages.sections` | Card section headings |
| `messages.fields` | Metadata and changed-field labels |
| `messages.relations` | Relation names |
| `messages.values` | Placeholder words and changed-value verbs |
| `messages.diff` | Diff heading and truncation notice |
| `messages.images` | Temporary preview wording, alt text, and fallback link label |
| `messages.templates` | Visible Issue-update heading and plain-text attachment fallbacks |
| `messages.due_reminders` | Daily DM headings, labels, relative timing, and fallbacks |
| `messages.thread_connections` | Connection dialogs, feedback, errors, and saved history heading |
| `messages.link_cards` | Quote-card links, thread context, and plain-text fallback templates |

An Issue update heading uses the Redmine user who made the update. Its default format is `🔄 Alice *Issue updated*` in Slack markup. You can change the text after the icon without editing the plugin:

```yaml
messages:
  templates:
    issue_updated_header: '%{actor} *%{event}*'
```

The `issue_updated_header` template also applies when an Issue update contains a comment. Issue creation, deletion, and standalone comment headings retain their own event labels. The actor is shown as a name, not as a Slack mention.

The other templates produce plain-text attachment fallbacks for clients that cannot display the rich card:

| Template | Applies to | Available placeholders |
| --- | --- | --- |
| `issue_updated_header` | Visible Issue-update heading | `%{actor}`, `%{event}` |
| `issue_fallback` | Issue creation, update without a comment, and deletion | `%{project}`, `%{actor}`, `%{action}`, `%{tracker}`, `%{id}`, `%{subject}` |
| `journal_fallback` | Issue changes with a comment and standalone Issue comments | `%{project}`, `%{actor}`, `%{event}`, `%{tracker}`, `%{id}`, `%{subject}` |
| `generic_fallback` | Wiki, News, News comments, time entries, Versions, and Projects | `%{event}`, `%{subject}` |

For example, `generic_fallback: '%{event}: %{subject}'` produces `News updated: Example title`. Keep placeholders in `%{name}` form. An unknown placeholder causes that template to fall back to its built-in default.

### Assignee mentions

![Assignee mentions](docs/images/features/user-mapping.webp)

When an Issue assignee changes, an explicit `users` mapping can turn the new assignee into a Slack mention:

```yaml
users:
  # Redmine login or email address: Slack member ID
  alice: 'U0123456789'
```

With `slack.auto_map_users_by_name: true`, the plugin can also match a Redmine **login** to exactly one active human Slack member's `profile.display_name` or account `name`, case-insensitively. Explicit mappings win. Missing or ambiguous matches stay as plain Redmine names. The directory is cached for ten minutes; an API failure also falls back to plain names. Automatic mapping requires [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) and an app reinstall after the scope is added. Assignee mention matching does not read email addresses and does not require [`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/). Using automatic name matching for the [personal email preference](#personal-email-preference) additionally requires [`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/) to verify the recipient's identity.

To stop mentioning an assignee, set their Redmine login mapping under `users` to `null` and use `slack.auto_map_users_by_name: false`. If their email address also maps to a Slack ID, set that mapping to `null` too. Without a matching Slack ID, the assignee appears as their plain Redmine name. This removes the explicit user mapping for other features as well; it is not a mention-only preference.

```yaml
slack:
  auto_map_users_by_name: false
users:
  alice: null
  'alice@example.com': null # if the email address was also mapped
```

`auto_map_users_by_email` identifies users for incoming Slack views and actions; `auto_map_channels_by_name` chooses notification channels. Both default to `false`, and neither needs to change to disable mentions.

The new assignee uses Slack's `<@U0123456789>` mention format. Issue authors, Journal authors, Wiki updaters, and the actor in the Issue-update heading are displayed as names without automatic mentions.

## Create an Issue from a Slack message

![Create an Issue from a Slack message](docs/images/features/message-to-issue.webp)

In the Slack app's **Interactivity & Shortcuts**, enable Interactivity with Request URL `https://redmine.example.com/slackmine/interactions`, then create a **message shortcut** with callback ID `slackmine_message_create`. Use the label **Create an Issue from a message**. Add the [`commands`](https://docs.slack.dev/reference/scopes/commands/) Bot scope and reinstall the app when scopes change. This feature reuses the [slash-command](#slash-command) integration: configure `slack.slash_command`, the global Bot Token, signing secret, app/team IDs, and user mapping. Work Object previews are optional.

When also using [thread connections](#connect-a-slack-thread-to-an-existing-issue), name the other shortcut **Connect a thread to an existing Issue**. The two labels distinguish creating an Issue from the selected message from connecting the entire thread to an existing Issue.

Open a message's **More actions** menu and choose the shortcut. Select a project, then review the tracker, subject, and description before saving. The first nonblank line becomes the subject; the description includes the message text and a permalink obtained with [`chat.getPermalink`](https://docs.slack.dev/reference/methods/chat.getPermalink/). Thread replies are supported, but only the selected message is copied. When the normal message text is empty, text from Block Kit sections and attachment cards (titles, bodies, and fields) is used instead. Attachment files, full thread history, and AI summaries are not imported. Slack's raw text formatting is retained. Subjects are limited to 255 characters, and descriptions to 3,000 characters with space reserved for the source link; review any shortened text before saving.

The picker includes up to 100 active projects where the mapped user can create Issues and the configured app/team integration is authorized. Projects matching the source channel appear first. Permissions and allowed trackers are checked again in the next form and on save. No Issue is created by opening the shortcut or selecting a project. Required custom fields still use the full Redmine form link; opening that link does not transfer the draft. Saving follows the existing Issue-creation path and its cache-based retry protection and normal notifications.

The selected message is temporarily stored in the existing `Rails.cache`, bound to the initiating user and app/team, for 30 minutes. After the picker changes to the creation form, the draft is held in the form. An expired or unavailable source cache requires reopening the shortcut. Multiple web workers need a shared cache or session affinity for this two-step flow. No new database tables or cache service are installed. Opening and updating modals is synchronous and subject to Slack's three-second response limit; test with the installed app after deployment. A private-channel or DM source can be copied into a project visible to other members: review the destination and draft before saving.

## Connect a Slack thread to an existing Issue

![Message menu shortcuts: create an Issue or connect a thread](docs/images/features/message-menu.webp)

From a message's **More actions** menu, choose **Connect a thread to an existing Issue** and enter the Issue number. **Save past conversation too** is selected by default. Review the past posts and deselect any you do not want to import. Confirming the connection saves the selected history as one comment under the connecting user's Redmine identity, preserving the original speakers, timestamps, and Slack links. Future replies and files are saved under each mapped user's Redmine identity.

Use **Create an Issue from a message** for the creation shortcut and **Connect a thread to an existing Issue** for this connection shortcut. Creation copies only the selected message; connection applies to the whole thread. Rename shortcut labels without changing their callback IDs.

Open the same shortcut again to disconnect. Saved comments remain. If a connection-time import fails, check the saved thread and Issue state before starting a new action. Future reply events retain Slack queue retries. If the conversation changes after confirmation, disconnect and review it again. Reconnecting starts a new review; selecting the same history again creates another quoted comment, so deselect history when it is no longer needed.

### Slack app setup for thread connections

1. Enable **Interactivity & Shortcuts** and set Request URL to `https://redmine.example.com/slackmine/interactions`. Reuse the URL if already configured.
2. Under **Shortcuts → Create New Shortcut → On messages**, register:
   - Name: `Connect a thread to an existing Issue`
   - Short Description: `Connect a conversation to an existing Issue and save past posts and future replies`
   - Callback ID: **`slackmine_thread_connect`**
3. Add the relevant **OAuth & Permissions → Bot Token Scopes**:

   | Scope | Purpose |
   | --- | --- |
   | `commands` | Message shortcuts |
   | `chat:write` | Connection, disconnection, and import-result messages |
   | `channels:read` / `groups:read` | Public/private channel information and the connecting user's membership |
   | `channels:history` / `groups:history` | Public/private thread history and reply events |
   | `users:read` | Original speaker profiles and excluding messages addressed to bots |
   | `files:read` | Importing attachments; unnecessary when file transfer is restricted |
   | `users:read.email` | Only when using `auto_map_users_by_email` |

4. **Install / Reinstall to Workspace** after adding scopes, and verify that the Bot Token matches your configuration.
5. Enable **Event Subscriptions** with Request URL `https://redmine.example.com/slackmine/events`. Subscribe to **`message.channels`** for public channels and **`message.groups`** for private channels.
6. Invite the bot to the source channel. Conversations outside the destination project's notification channels can be connected. DMs and group DMs are unsupported.

No additional slash command, Options Load URL, or Work Object setup is required. If reply importing is already configured, the main additions are the message shortcut and any missing read scopes.

Slack references: [message shortcuts](https://docs.slack.dev/interactivity/implementing-shortcuts/), [thread history](https://docs.slack.dev/reference/methods/conversations.replies/), and [channel membership](https://docs.slack.dev/reference/methods/conversations.members/).

### Redmine setup for thread connections

Deploy the code and configuration and restart Redmine and Sidekiq. No dedicated table, additional database, or migration is required. Signed bot posts in Slack hold the connection state; Slack modals hold review information. Redmine stores only standard comments and attachments. Confirmation deduplication uses the existing `Rails.cache`, which must be shared across Web processes and handle `unless_exist` atomically.

Example `config/slackmine.yml`:

```yaml
slack:
  thread_connections: true   # Default is true; false stops this feature
  bot_token: 'xoxb-REPLACE-ME'
  events:
    app_id: 'A0123456789'
    team_id: 'T0123456789'
    signing_secret: 'REPLACE-ME'

users:
  alice: 'U0123456789'
```

`thread_comments` controls the existing notification-thread importer. Explicit connections are independently controlled by `thread_connections` and work even with `thread_comments: false`. Set `projects.<identifier>.slack.thread_connections: false` to disable connections for a project.

Choose a destination project using the same Slack app/team and Bot Token as the global configuration. Configure explicit `users` mappings or `auto_map_users_by_email`; name-only matching does not authorize edits. The connecting user must be able to view and comment on the Issue, and attach files when importing attachments. Future replies check the same permissions for each speaker. Private Issues cannot be connected.

The shortcut opens a loading form directly, then queues connection lookup. Selecting an Issue reviews history in the Web process and returns the completed preview in the acknowledgement when it finishes within two seconds. Slower reviews display a loading view and fall back to Sidekiq after a one-second delay so the acknowledgement cannot overwrite the completed preview. Confirmation acknowledges promptly and queues the connection, disconnection, and selected history import. Identical confirmations are suppressed with the existing Rails cache; atomic shared-cache support is needed across Web processes. Pending, uncertain, and completed requests remain claimed for 24 hours. Check the saved thread and Issue state before repeating an action.

For timing checks, compare `connection preview direct duration_ms` or `connection preview deferred` in the Web log with completion times for `SlackmineThreadConnectionJob` in Sidekiq. Quote and attachment saving always runs in the job. Verify the thread and Issue before retrying an uncertain save.

### Thread connection display and limits

Past conversation uses the same cards as normal conversation pickup. Consecutive posts by the same speaker are joined with a single newline, with one speaker/timestamp header (using the first post's time) and one **Open in Slack** link. A speaker change starts a new card: A→A→B→A produces three cards in conversation order. Original post URLs remain in the saved data, and attachments appear in the corresponding card. This applies to both web and email, including previously saved connection-history imports.

- Past history includes up to 20 human posts, including the parent. For longer history, deselect past-conversation importing. The whole thread is limited to 1,000 posts; incomplete history is rejected rather than silently truncated.
- Each post and the combined selected text are limited to 10,000 characters. Slack's review-modal block limits also apply.
- Bot posts and posts addressed to bots are excluded. Historical speakers need not have Redmine mappings to be included as quotations.
- Replies added between review and confirmation are imported without duplicate saving when reply events overlap. If the thread exceeds 1,000 posts during catch-up, disconnect and review again.
- Future replies are saved immediately. The notification-thread `thread_comment_batch` setting does not apply to explicit connections.
- Existing attachment restrictions apply. Selected history is limited to 10 files and 50 MiB combined. Images appear in the quote; other files have download links. Restricted file transfer prevents downloads.
- Existing Slack link cards render the quotations. When cards are disabled, speaker, timestamp, links, and text remain readable as plain text.
- If selected text, speaker, or file IDs change after review, saving stops and requires a new review. Later Slack edits/deletions are not synchronized. Disconnecting does not delete saved comments or attachments.
- Connection and disconnection bot posts are the connection state. Deletion or Slack retention expiry can make state unrecoverable; retain these posts. Reconnect existing threads after changing the Signing Secret.
- Reply events are queued and connections are checked against Slack thread history, without a database mapping. This also adds history requests for normal notification threads.
- Each thread connects to one Issue. Disabling the feature globally or for the project stops imports. Re-enabling does not automatically import all history from the disabled period.

### Verify thread connections in a live installation

Use a test Issue and channel to check:

1. Opening the shortcut from the parent or another user's reply selects the same thread.
2. Deselecting a historical post saves only the selected posts in one comment under the connecting user's identity.
3. Future replies, images, and files use the speaker's identity and correct attachment placement in Redmine and email.
4. Replies added during review are saved exactly once.
5. Retries do not duplicate history, and disconnecting stops future replies and delayed jobs from saving.
6. Unauthorized users, private Issues, and projects using different app/team/token settings cannot be connected.

Connection tests stub Slack APIs and Redmine model operations without an additional database:

```sh
ruby -Itest test/thread_connections_test.rb
ruby -Itest test/thread_connections_notes_test.rb
```

Stub tests do not verify live Slack/Redmine rendering or production delivery.

## App Home issue lists

![App Home issue lists](docs/images/features/app-home.webp)

The Home shows four sections in order: Updated by me, Due this week, Assigned to me, and Reported by me. Updated means any visible journal authored by you, not only the last updater. Updated and reported issues sort by latest issue update; assigned issues sort by priority then latest update; due-this-week issues sort by project. All use Redmine’s standard `IssueQuery` filters for open issues, active projects, user/group assignment, visibility, and the current week.

Lists use a five-column table: title with project underneath, status, assignee, due date, and an “Edit issue” button. Title links open the browser (up to 200 characters), and edit buttons open the permission-checked Slack form. Each section has one heading and shows five issues per page, up to 10 issues total. Slack controls column widths and mobile rendering. Customize section labels with `messages.app_home`, attribute labels with `messages.fields`, and the edit button with `messages.work_objects.edit_issue`. Reopening Home preserves the selected filter.

Enable shared `slack.app_home: true`, configure the shared bot token and `slack.events` app/team IDs and signing secret, enable **App Home → Show Tabs → Home Tab** in Slack, and subscribe to the bot event [`app_home_opened`](https://docs.slack.dev/reference/events/app_home_opened/) at the existing `/slackmine/events` endpoint. Configure user mappings (or email matching), then restart Redmine and Sidekiq.

A selector switches between all four sections or one section. Each section shows up to 10 issues (`10+` means more); an issue matching several sections can appear in each. Due-this-week includes the entire current week, including dates earlier this week, and uses Redmine’s week boundary.

Data refreshes when Home opens, when the filter changes, on Refresh, and after saving from a Home detail form. Other updates appear on the next refresh. No new database schema or periodic job is required. Projects must be active, visible to the viewer, enabled for App Home, use the shared app/team, and map the Slack user to the same Redmine account as the shared configuration. Project-only apps are unsupported. Unmapped users see an explanation without issue data.

The edit button shows an issue link and permitted edit/comment inputs, reusing the Work Object modal and Redmine permission/workflow checks. Existing `work_object_previews`, `work_object_actions`, and `work_object_buttons` settings control edits. Otherwise details are read-only. Visible private issues may be listed, but retain the existing prohibition on Slack edits. Override labels through `messages.app_home` in the example configuration.

## Slash command

![Slash command](docs/images/features/slash-commands.webp)

Set `slack.slash_command: /slackmine` (omit it to disable), register the same command in the Slack app, and set its Request URL to `https://redmine.example.com/slackmine/commands`. Add the [`commands`](https://docs.slack.dev/reference/scopes/commands/) scope and reinstall the app. Keep Interactivity enabled at `/slackmine/interactions` and configure the existing signing secret, app/team IDs, bot token, and user mappings. This command uses the global integration and user mapping; results are limited to projects belonging to that integration.

No additional database tables or migrations are needed. Form-submission and explicit-value command retries use the existing `Rails.cache`: an in-flight key lasts five minutes and a successful submission key lasts 24 hours. Validation errors release the key so corrected forms can be submitted. Unexpected failures retain the short-lived key because the write outcome may be uncertain. This is best-effort deduplication, not a transaction with the issue write: cache eviction, expiry, process-local/null caches, and a crash between saving and recording success can allow duplicates. Explicit-value commands use a server-derived request key and save the response before Slack delivery, so a delivery retry reuses the saved response. A shared cache with atomic `unless_exist` support coordinates web workers and command workers; no new cache service is installed by the plugin.

| Command | Result |
| --- | --- |
| `/slackmine` or `/slackmine help` | Usage and My issues / Due soon / My due reminders / New issue buttons |
| `/slackmine 123` or `/slackmine #123` | Work Object card when configured; otherwise an issue link, status, and comment button |
| `/slackmine my` | Your directly assigned, open issues |
| `/slackmine due` | Your overdue issues and issues due within three days |
| `/slackmine reminders` | Run your personal due-reminder digest now, using the scheduled reminder settings |
| `/slackmine search words` | Case-insensitive subject search |
| `/slackmine new [project-identifier]` | Project selection followed by a tracker, subject, and description modal |
| `/slackmine comment 123` | Button that opens the comment modal |
| `/slackmine status 123 [status name or ID]` | Queue a status change, or omit the value for a permitted-status picker |
| `/slackmine assign 123 [user login, name, or ID]` | Queue an assignee change, or omit the value for an assignable-user picker |

The `status` and `assign` commands also accept `#123`. With no value, they open a picker from the returned button and save only after submitting the modal. Supplying a value queues the edit and returns its result privately: for example, `/slackmine status 123 Done` or `/slackmine assign 123 alice`. Names must match exactly (case-insensitively) and identify one permitted candidate; names containing spaces are supported without quotes. IDs avoid ambiguous names. Assignment also accepts `me`, `none`, and the configured unassigned label. Unknown, ambiguous, or disallowed values leave the issue unchanged and return a picker button. Replace `/slackmine` with your configured `slack.slash_command`. They require `slack.work_object_actions: true`, an active mapped Redmine user, a public issue in the same integration, and permission to edit the selected attribute. Work Object previews are not required for these commands. Status choices follow the viewer's Redmine workflow; assignee choices use Redmine's assignable users, with an Unassigned option. The assignee picker supports at most 99 users, and the status picker at most 100 statuses; use Redmine's issue form if the picker cannot open. Saving rechecks permissions, integration, the workflow, and assignable users under the existing issue row lock. Selecting the current value closes the modal without adding a journal. No extra Slack command registration or scopes are required. Successful queued changes and unchanged results return the latest Work Object card when previews are configured, using the existing card fields and buttons. Without previews, they keep the text confirmation. The result is cached before delivery, so retries do not repeat the edit or rebuild the card.

Results are ephemeral (visible only to the requester). When a number lookup or a `my` / `due` / `search` result contains exactly one issue, the response automatically uses a Work Object card if the project enables `slack.work_object_previews: true` and uses the command bot token. Card fields and buttons follow the existing YAML settings; no new switch is needed. Unconfigured previews and private issues keep the simple display. Work Object action buttons carry the issue ID because Slack can omit the entity URL and reference from ephemeral button interactions. The plugin resolves the ID against its own Redmine instance and applies the same integration, visibility, and edit checks. Editing from a private result opens the usual full form, including permitted status, priority, assignee, due date, and comment fields. Ephemeral cards cannot be refreshed with [`chat.update`](https://docs.slack.dev/reference/methods/chat.update/); run the lookup again after saving. Multi-issue lists use the reminder format: a colored attachment with a count heading and bulleted issue links, project names, and relative due dates. Issues without due dates omit the timing suffix. The list order is unchanged and there are no per-issue buttons. Line formatting uses `messages.due_reminders`; group labels use `messages.commands.my`, `.due`, and `.search`. Use `/slackmine 123` or `/slackmine comment 123` to access the comment action. Lists display up to ten results from the newest hundred candidates; the project picker displays up to twenty projects and prefers the current channel's project. Use the optional project identifier to narrow it. Every read checks Redmine visibility; form submission rechecks permissions and workflow validation. Required custom fields are not collected in the simple new-issue modal: use its full Redmine form link when necessary. Comments require `work_object_actions: true` and follow the existing public-issue edit policy. Successful writes use normal Redmine notification behavior; there is no automatic channel-sharing action. Slash commands are unavailable inside threads; the existing thread-comment integration remains available there.

`/slackmine reminders` reuses the scheduled digest selection and formatting: directly assigned open issues, Redmine visibility, `due_reminders.enabled`, and global/project `due_reminders.days`. It returns overdue, today, and upcoming sections privately in the invoking conversation, with an explicit empty result and batches of up to 100 issues. Only the current app/team and matching Slack user mapping are included. It does not run the all-user cron task or change its schedule. Unlike `/slackmine due`, it uses the configured reminder window and is not limited to ten results. Existing `messages.due_reminders` wording/colors apply; the command label and empty message are under `messages.commands`. No additional Slack command registration, scopes, or database tables are needed.

All command text is configurable under `messages.commands` in the English example. The multiline `messages.commands.help` lists every command and replaces `%{command}` with `slack.slash_command`. If your YAML already overrides `help`, update that value or remove it to use the new default. Search, lists, and reminder delivery use Sidekiq. Modal buttons open forms directly while their trigger IDs are valid. Simple form submissions save directly; creation and comment forms containing Slack links queue quote import and send the result to the initiating user's Slack app Messages tab. Enable that tab in the app's App Home settings for these notices.

## Daily due-date DMs

![Daily due-date DMs](docs/images/features/due-reminders.webp)

Run the task once a day in the Redmine application's time zone. It queues jobs on the `slack` queue; the worker sends the DMs:

```bash
cd /path/to/slackmine
bundle exec rake slackmine:due_reminders RAILS_ENV=production
```

Schedule the task once a day with the scheduler used by your Redmine installation. Each execution sends another digest, even on the same day.

For cron, put the command in a small script that changes to the Redmine directory first:

```sh
#!/bin/sh
cd /path/to/slackmine || exit 1
bundle exec rake slackmine:due_reminders days=7 RAILS_ENV=production
```

The task accepts the same filters as Redmine's reminder command. Set them as Rake environment arguments; omitted filters include all matching Issues:

| Option | Meaning |
| --- | --- |
| `days` | Days before the due date. Overrides `due_reminders.days` in the YAML, including project overrides. Without it, the YAML setting applies (default: 3). |
| `tracker` | Tracker ID. |
| `project` | Project ID or identifier. |
| `users` | Comma-separated Redmine user IDs whose assigned Issues should be included. |
| `version` | Target version name, matched case-insensitively as in Redmine. |

For example, to restrict a run to users 3 and 5, or to combine all filters:

```bash
bundle exec rake slackmine:due_reminders users=3,5 RAILS_ENV=production
bundle exec rake slackmine:due_reminders days=7 tracker=2 project=example users=3,5 version="1.0" RAILS_ENV=production
```

Only Issues matching every supplied filter are included, and the worker checks the filters and assignee again before sending. Invalid values or nonexistent users, trackers, projects, and versions stop the task before any jobs are queued. Every invocation sends the current matching Issues again, including Issues already sent earlier that day.

By default, assigned open Issues are included daily from **three days before their due date** through every overdue day, until their status is marked **closed** in Redmine. The worker sends one compact DM per assignee and groups the linked Issues under overdue, due today, and upcoming headings. Each group has its own color: overdue is red, due today is amber, and upcoming uses the configured attachment color. Issue lines show relative timing without repeating the calendar date; the due-today heading carries that context. A digest with more than 100 Issues is split into numbered messages. Separate bot tokens or Slack user mappings can produce a separate digest for each app. Each run sends the current matching Issues, even if the task already ran that day.

```yaml
due_reminders:
  enabled: true
  days: 3
  colors:
    overdue: '#D92D20'
    today: '#F79009'
    # upcoming: '#6D5DFB'
projects:
  example:
    due_reminders:
      enabled: false
```

Set `due_reminders.colors.overdue`, `.today`, and `.upcoming` to six-digit hex colors. Invalid or omitted values use the defaults; an omitted upcoming color uses `slack.attachment_color`. Colors can also be overridden per project under `projects.<identifier>.due_reminders.colors`.

The assignee must be an active Redmine user who can view the Issue, and must map to a Slack user through `users` or `slack.auto_map_users_by_name`. Group assignees and unmapped users are skipped and logged. Private Issues can be sent to their own assignee by DM when Redmine grants that user access. DM delivery needs a Bot Token with [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) and [`im:write`](https://docs.slack.dev/reference/scopes/im.write/); it does not use the project's channel ID. In the Slack app settings, enable **App Home → Messages Tab → Display Messages tab**; otherwise Slack returns [`messages_tab_disabled`](https://docs.slack.dev/reference/methods/conversations.open/#errors) even after [`conversations.open`](https://docs.slack.dev/reference/methods/conversations.open/) succeeds. After adding scopes, reinstall the Slack app. Verify a test Issue in the recipient's Slack DM before relying on the schedule.

The digest wording is configurable under `messages.due_reminders` in `slackmine.messages.yml`. The [message example](config/slackmine.messages.yml.example) lists every key and its placeholders. For example, change the title and the overdue group label without changing the other groups:

```yaml
messages:
  due_reminders:
    title: '📋 *Due reminders: %{count}%{suffix}*'
    overdue_label: '🚨 Overdue'
```

The same keys can be overridden under `projects.<identifier>.messages.due_reminders`.

## Personal email preference

![Personal email preference](docs/images/features/email-preference.webp)

In **My account → Email notifications**, below **I don't want to be notified of changes that I make myself**, each user can enable **Skip email for notifications covered by Slack** (off by default). This uses the existing Redmine user preference storage; no database migration is required.

The option applies to new Issues, Issue changes/comments, Wiki creation/updates, News creation/comments, Documents, project/version/Document files, and forum topics/replies. For Issue updates, only triggers enabled in Redmine’s email notification settings participate in suppression. With general Issue updates disabled and comment mail enabled, an unrelated relation, date, or attachment change does not prevent suppressing the comment email. If general Issue updates are enabled, all visible changes participate. Email is skipped only when all applicable mail triggers have Slack events enabled, a Bot Token and destination channel resolve for that project, and the recipient resolves to a Slack member currently in that channel. An explicit `users` login/email mapping takes priority. Without one, `slack.auto_map_users_by_name: true` can resolve a unique name match; a fresh Slack profile must also have an email address matching the recipient's primary Redmine email (case-insensitive). Existing project/ancestor/default channel routing is used. Invalid explicit mappings do not fall back to automatic matching. Private Issues and private notes, unsupported notification types, and account/security emails retain their normal Redmine email behavior.

Membership is checked synchronously using [`conversations.members`](https://docs.slack.dev/reference/methods/conversations.members/), without caching positive results. The app needs [`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/) for public channels or [`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/) for private channels. Automatic name matching additionally needs [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) and [`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/); missing or mismatched email, inactive/bot/foreign identities, ambiguous names, and lookup failures retain email. Identity verification is performed for each email without caching profile email data. Reinstall after adding scopes. Missing configuration/mapping, nonmembership, API failures, malformed responses, and incomplete pagination retain email. Lookups are limited to ten pages of 200 members, with two-second connection and three-second read timeouts per request.

This option checks notification configuration and channel membership, **not Slack delivery success**. It adds no delivery-coordination job: if a later Slack post fails, a skipped email is not sent as a fallback. It also does not change Redmine's existing mail notification selection; disabling the checkbox restores that selection.

## Administration overview

![Slackmine administration: current settings and Sidekiq tasks](docs/images/features/administration.webp)

Queue monitoring, execution history and test notifications are available **only when the ActiveJob adapter is Sidekiq**. Other adapters keep their existing notification behavior; queue/history information is unavailable and the test button is disabled. The **Queue and tasks** tab inspects pending, running, scheduled, retry and dead jobs. The latest 100 Slackmine execution attempts are recorded for up to seven days after installation; historical completed jobs cannot be reconstructed. History uses the existing Sidekiq Redis/Valkey instance at `slackmine:admin:job_history:v1`; no Redmine database tables are added. Only job names, IDs, outcomes, timestamps, durations and exception classes are stored, without job arguments, message bodies or credentials. Selecting a project changes the test destination; task monitoring remains global across Slackmine jobs. Job completion does not guarantee delivery for regular notifications. The administrator-only test button enqueues one message to the displayed destination, revalidates that destination before posting, and uses the same Slack queue. It requires Sidekiq and valid Bot/channel settings. Each job set is scanned up to 500 entries and truncated results are marked.

Administrator labels and descriptions are kept in `config/locales/slackmine_admin.ja.yml` and `config/locales/slackmine_admin.en.yml`, following the Redmine UI language. They are separate from Slack notification wording in `slackmine.messages.yml`.

Administrators can open **Administration → Slackmine** (`/admin/slackmine`) to inspect loaded settings with localized key descriptions, project/channel routing, and active users' Slack mention targets. The settings and user tabs support selecting a project to apply its overrides. Projects can be filtered by status and default to active projects. The settings table combines each key with a gray description beneath it, followed by the built-in default and current value. Current values that differ from code defaults are bold, including multiline values, and can be filtered with Changed values only. Valid color codes include a small square swatch, and effective event colors have a separate section. Context-dependent defaults show their values and conditions rather than being compared against a single value. Routing uses the existing parent-project inheritance and automatic matching; user mentions use the same login/email mappings and automatic name matching as notifications. The user list defaults to mapped users and offers Mapped, Unmapped, and All filters. Selecting a project restricts the list to its active members. Filtering occurs before pagination (50 entries per page). The user tab also shows configured mapping entries, including entries without an active Redmine account.

Settings and mappings are read-only; test notifications are sent through an explicit administrator action. Credentials are masked, including the effective Bot Token after environment-variable precedence. Message wording includes built-in defaults and the separate message file; omitted operational keys continue to use code defaults and are not listed. Automatic matching may make read-only Slack API calls and reuse caches for up to 10 minutes. The channel list does not verify event enablement or successful delivery. Missing configuration files are identified on the screen to distinguish an unloaded configuration from an unmapped account or default English wording. Restart web/worker processes after editing configuration files to refresh loaded settings.

## Delivery and operations

`SlackmineNotificationJob` is enqueued after the Redmine event on the `slack` ActiveJob queue. For Sidekiq, include that queue in its configuration, for example:

```yaml
:queues:
  - default
  - mailers
  - slack
```

Slack API failures are logged and retried by Sidekiq. They do not roll back the Redmine operation. A failure to remove temporary image previews after a successful post is logged but does not retry the job, avoiding a duplicate message. Check the `SlackmineNotificationJob` and `Slackmine` log lines when a notification is absent.

For development, ActiveJob's inline adapter can run without Sidekiq:

```ruby
config.active_job.queue_adapter = :inline
```

Inline delivery happens during the Redmine request and may increase response time if Slack is slow. Use a worker that processes the `slack` queue in production.

If a notification is missing, check in this order:

1. The relevant event leaf and any parent switch are enabled globally and for the project.
2. The running Redmine and Sidekiq processes have the intended token. `SLACK_BOT_TOKEN` overrides YAML.
3. The project identifier maps to the intended channel, or a default channel is configured, and the bot is a member.
4. The Bot Token has [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/), plus [`files:write`](https://docs.slack.dev/reference/scopes/files.write/) or [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) for those optional features. Reinstall after adding a scope.
5. Sidekiq processes the `slack` queue; inspect the job error and Slack API error code in the log.

A YAML change requires restarting both Redmine and Sidekiq. A successful job post confirms API delivery; check the target channel to confirm the visible layout and images. Existing messages are not updated retroactively.

## Slack message cards in issue text

Card styles are loaded throughout Redmine so activity feeds, editor previews, and issue quick previews use the same subdued borders as issue details.

Set `slack.link_cards.enabled: false` to disable Slack link content retrieval, new quote imports, and card rendering in both Redmine and email. Existing saved quotes remain as readable plain text; they are not deleted.

Set `slack.link_cards.redmine_enabled: false` to disable only Redmine web cards and live previews of unquoted links. Content retrieval and quote imports when saving, and email cards, continue. Use the existing `mail_enabled: false` to disable only email cards. All three options default to `true`, preserving current behavior, and support overrides under `projects.<identifier>.slack.link_cards`.

Description and comment editor previews render submitted saved quotes with the same cards, without calling the Slack API for saved quotes. Bare URLs fetch live cards after issue/project permission checks; unavailable messages remain ordinary links. Previewing does not save quotes.

![Slack message cards in issue text](docs/images/features/slack-link-cards.webp)

When an issue description or comment containing a Slack permalink such as `https://example.slack.com/archives/C123/p1791115675755579` is created or edited, the plugin retrieves the message and appends a quote to the **existing description/notes column**. No database migration, new table, index or background job is required. The quoted body and resolved mention labels are saved as plain searchable text, with card metadata in a delimited block. The original URL and source wording are retained. The quote is a snapshot of the message at save time: Slack edits/deletions do not alter it. Repeated URLs (including different query parameters for the same message) and repeated saves do not append duplicate quotes. Code blocks and inline code are excluded using the current Redmine Markdown/Textile formatter. Failed retrievals leave the source unchanged and do not prevent saving.

Saved cards replace the original link at its position in the source text; the card footer opens Slack. Comment updates via Ajax and full page reloads use the same rendering, preserving link order and intervening text. Redundant line breaks next to cards and empty paragraphs left by moved quotes are removed; normal text line breaks remain. If the original link is removed, the quote still displays where it was stored. Saved quotes render as cards in Ruby, without browser JavaScript or Slack API calls while viewing. Quote bodies are escaped/rendered as Slack markup, never executed as Redmine macros or raw HTML. Plain-text notification emails and outgoing Slack notifications use readable quotes without storage markers. Existing unquoted links keep their live preview until the description/comment is changed and saved; existing records are not bulk modified. Copying an existing quote preserves its snapshot.

Configure the left border color globally or override it under `projects.<identifier>.slack.link_cards`:

```yaml
slack:
  link_cards:
    enabled: true
    redmine_enabled: true
    mail_enabled: true
    color: '#6D5DFB'
```

Only six-digit hex colors are accepted; omitted or invalid values use `#6D5DFB`. Thread replies have a reply label, a compact parent preview when available, and a link to the parent. Parent messages show their reply count. Only the selected message and its parent are fetched, not the entire thread. Both permalink query parameters (`thread_ts`) and message metadata identify replies. Users and channel mentions are resolved to names; failed lookups retain the supplied label or ID. Missing bot profiles are looked up with [`bots.info`](https://docs.slack.dev/reference/methods/bots.info/).

Access follows Redmine issue and private-note permissions. Viewers do not need a mapped Slack account or channel membership: **saving a link shares and stores its message content (and parent preview for a reply) for readers of that issue or note.** The configured project bot must be a conversation member and have the appropriate history scope ([`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/), [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/), [`im:history`](https://docs.slack.dev/reference/scopes/im.history/), or [`mpim:history`](https://docs.slack.dev/reference/scopes/mpim.history/)) and conversation-read scope ([`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/), [`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/), [`im:read`](https://docs.slack.dev/reference/scopes/im.read/), or [`mpim:read`](https://docs.slack.dev/reference/scopes/mpim.read/)). Author, user-mention and bot profiles use [`users:read`](https://docs.slack.dev/reference/scopes/users.read/). Reinstall the app after adding scopes. The permalink host must match the bot's authenticated workspace.

Slack [`mrkdwn`](https://docs.slack.dev/messaging/formatting-message-text/) emphasis, strike-through, links, quotes and code are rendered, along with basic Markdown headings, lists, bold text and links. Standard emoji shortcodes become Unicode; custom emoji retain their shortcode. Raw HTML stays literal and links allow only HTTP, HTTPS and mailto. A reply not found in history is attempted through [`conversations.replies`](https://docs.slack.dev/reference/methods/conversations.replies/); API restrictions or failure may leave it as a normal link. Files are not imported.

Set `messages.link_cards.open` in `slackmine.messages.yml` to customize the
**Open in Slack** label for both Redmine and email. Omitted or blank values use
`Open in Slack`; the value is plain text, not HTML.

Set `slack.link_cards.mail_enabled: false` to disable HTML email quote cards and
the inline logo, keeping the original Slack link and plain quote text. Omitted or
`true` enables them. Project overrides use
`projects.<identifier>.slack.link_cards.mail_enabled`; Redmine cards are unaffected.

Saved quotes in HTML email use inline card styles, preserve hand-typed list markers,
indentation and line breaks, and render supported emphasis. The Slack mark beside
**Open in Slack** is a bundled PNG attached inline and referenced by `cid:`;
it does not require access to the authenticated Redmine website. Plain-text
parts and existing attachments are preserved. The PNG is derived from the
attributed `assets/images/slack-mark.svg` and remains a Slack trademark.

At most 20 unique links are considered per save, with a five-second budget for starting API calls and short network timeouts; links beyond the budget remain ordinary links. API results are reused only within that import, scoped by bot token. The same bounded retrieval remains for legacy live previews. Quotes are saved inside the source column; no shared HTML cache is used. Redmine issue/private-note permissions apply to the stored source and to normal Redmine search results. **The saved quote text is searchable through Redmine's existing issue-description and journal-note search** (disable “titles only” to include bodies). No separate search index is needed. Original unquoted links are not searchable by Slack message wording until imported. Snapshots can be edited or removed with the source text; removing only the original URL does not remove the stored quote. All ordinary Redmine notifications/history apply to these saved text changes.

## Privacy and development

Channel notifications exclude private Issues and private Journal notes. Daily DMs may include private Issues only when the assignee can view them in Redmine. Images from private Issues or notes are not uploaded. Do not commit a real `slackmine.yml` or expose the Bot Token in logs, examples, or support requests. Rotate a token if it is exposed.

The repository's local test suite can be run with:

```bash
ruby -Itest test/image_notification_test.rb
ruby -Itest test/admin_controller_test.rb
ruby -Itest test/standard_notifications_test.rb
ruby -Itest test/slack_events_controller_test.rb
ruby -Itest test/slash_commands_cache_test.rb
ruby -Itest test/slash_commands_edit_test.rb
ruby -Itest test/app_home_test.rb
ruby -Itest test/message_shortcuts_test.rb
ruby -Itest test/thread_connections_test.rb
ruby -Itest test/thread_connections_notes_test.rb
ruby -Itest test/thread_images_test.rb
ruby -Itest test/thread_comment_feedback_cleanup_test.rb
```

These tests exercise notification formatting and delivery logic with stubs. Additionally, run `ruby -Itest test/thread_connections_test.rb` for signed Slack connection state, previews, and reply routing. Run `ruby -Itest test/thread_comments_persistence_test.rb` where ActiveRecord and sqlite3 are available to check persistence, duplicate suppression, permission denial, and notification-loop suppression using in-memory Issue/Journal fixture tables. Run `ruby -Itest test/notification_transactions_test.rb` separately with ActiveRecord and sqlite3 to verify commit/rollback behavior for Issue deletion and generic notification models. See [notification audit](#notification-coverage-and-verification) for the coverage matrix and remaining runtime checks. These tests do not connect to production databases or Redis, post to Slack, or verify a live Redmine installation.

The administration overview's ERB rendering and HTML escaping can also be checked with `ruby -Itest test/admin_view_test.rb` where ActionView is available. These tests do not verify a running Redmine 7 administration page.

Job monitoring, bounded history and test-notification destination checks can be verified with `ruby -Itest test/job_monitor_test.rb`. These tests use adapters and do not send real Slack messages.


## Notification coverage and verification

The following matrix describes the implementation, configuration, and formatting covered by automated tests. Live Slack and SMTP delivery require separate integration checks.

| Object | Notifications | Body edit presentation | Standard email suppression |
| --- | --- | --- | --- |
| Issue | Creation, deletion, journal attribute/relation/attachment/parent/child changes | `body_diff.issue.description` | Creation and enabled Redmine journal mail triggers |
| Issue comment | Addition, editing, deletion | `body_diff.issue.comment`; deletion always shows removed lines | New-comment trigger only; edits/deletions do not add new mail actions |
| Wiki | Creation, text/edit-comment updates, deletion | `body_diff.wiki.body` | Creation/update |
| News | Creation, update, deletion | `body_diff.news.description` | Creation |
| News comment | Addition, content edits, deletion | `body_diff.news.comment`; deletion always shows removed lines | Addition |
| Document | Creation, title/description/category edits, deletion | `body_diff.document.description` | Creation |
| Project/Version file | Addition, filename/description/content-type/digest edits, deletion | Description text; no generated body diff | Addition |
| Document attachment | Addition, editing, deletion | Same File formatter, labels, icons, and metadata | Addition |
| Forum topic/reply | Posting, subject/content/sticky/locked edits, deletion | `body_diff.message.body` | Posting |
| Time entry | Creation, update, deletion | Current comment text; no generated body diff | No standard mail action intercepted |
| Version | Creation, update, deletion | Current description text; no generated body diff | No standard mail action intercepted |
| Project | Update | Current description text; no generated body diff | No standard mail action intercepted |
| Due reminder | Configured daily/on-demand digest | Dedicated reminder formatting | No suppression of reminder emails |

Event switches use `events`; headings/icons use `messages.events` and `messages.icons`; metadata uses `slack.metadata`. Project overrides use the same trees under `projects.<identifier>`. Document attachment event switches are separate under `events.document.file`, while their rendering uses the shared `file` keys.

`body_diff: false` displays updated text instead of hiding it. Missing diff settings default to true. There is no separate global switch to hide all notification bodies. New deletion switches default to false; Issue and comment deletion defaults retain their established behavior.

### Verification scope

Stub tests cover notification formatting, delivery paths, mail policy, command permissions, Work Objects, App Home, quotes, imports, and event handling. Event switches are tested disabled globally and enabled per project; body-diff settings are tested independently. Model-fixture tests cover persistence, duplicate suppression, permissions, notification-loop suppression, transaction commit/rollback, attachment lifecycle, and updater identity. These simplified fixtures do not replace a full Redmine 7 installation.

Notifications are queued after transaction commit so rolled-back changes do not enqueue them. Creation uses the original author; updates and deletions use the current actor. Forum body edits display either the diff or the updated body once. Mail suppression follows Redmine's enabled notification triggers; a disabled relation/date/custom-field trigger does not block suppression of an enabled comment trigger.

### Integration checks and limits

- ActionMailer tests require ActionMailer and the relevant dependencies. An unavailable dependency means that suite has not been verified in that environment.
- Live Redmine 7 callback ordering, cascading parent deletions, Sidekiq execution, Slack rendering, and SMTP delivery require checks on a test installation.
- Mail suppression checks enabled events, user identity, channel configuration, and membership. It does not wait for successful asynchronous Slack delivery; network or worker failures after suppression can prevent delivery.
- YAML is cached in each process. Restart or reload Redmine and workers after applying configuration changes.

## Version history

The pre-1.0 entries below retrospectively group development milestones. Their
version numbers are editorial labels, not a record of published releases or Git tags.

| Version | Highlights |
| --- | --- |
| **1.5.5** | Resolve custom field metadata to Redmine display values, including enumeration names, referenced names, and localized boolean labels. |
| **1.5.4** | Show actors in every operation notification, customize headers with YAML variables, and reuse the configured product name across messages. |
| **1.5.3** | Render saved Slack quotes and bare Slack URLs as cards in description and comment editor previews. |
| **1.5.2** | Fix corrupted HTML notification emails when Roadie inlines CSS after Slack images are embedded. Preserve Japanese text, inline images, and the plain-text alternative. |
| **1.5.1** | Fix missing Slack avatars in notification emails when Slack returns a Gravatar URL. Safely embed Gravatar images and Slack default-avatar redirects as inline attachments. |
| **1.5.0** | Add the localized Slackmine administration screen for effective settings, event-color swatches, project/channel routing and user mentions. Add Sidekiq-only queue monitoring, bounded execution history and test notifications. |
| **1.4.0** | Separate display wording from operational settings and add a Japanese wording example. Improve duplicate-operation handling and failure responses for Slack interactions. |
| **1.3.0** | Process Work Object details and short actions in the Web process; queue URL unfurls, post-save refreshes, App Home lists, slash command delivery, connection saves, and quote-heavy form saves. Review thread history in the Web process first, falling back to Sidekiq after two seconds. |
| **1.2.2** | Added file-transfer restrictions for audit and internal policies: use source links instead of transferring files, allow per-project exceptions, or enforce the restriction globally. |
| **1.2.1** | Added switches to disable Slack link retrieval, quote imports, and all cards, or only Redmine web cards. Documented how to disable assignee mentions. |
| **1.2.0** | Added options to hide or automatically clear comment-save confirmations to keep thread conversations readable. |
| **1.1.0** | Added optional batching of consecutive Slack thread replies from the same user, preserving source order, links, and attachments without a new DB table or cache buffer. Replies save immediately by default; the example uses a 60-second wait and a 300-second maximum. Added a switch for normal Slack notifications of imported comments. |
| **1.0.0** | First major release as Slackmine. Document, file, and forum notifications cover creation, editing, and deletion. Email suppression follows enabled Redmine mail triggers. |
| **0.9.0** | Renamed the plugin and its configuration, endpoints, and tasks to Slackmine. Extended thread replies to images, PDFs, and other files, with attachment previews and links. |
| **0.6.0** | Added Slack notification-thread replies as Redmine comments and saved Slack message quotes with links back to the original conversation. |
| **0.5.0** | Added Issue Work Object previews, live details, editing, search, creation, slash commands, and personal App Home Issue lists. |
| **0.4.0** | Added due-date reminder DMs and an optional personal preference to suppress email covered by Slack notifications. |
| **0.3.0** | Expanded project channel routing, parent-project fallback, user mapping, and project-specific configuration. |
| **0.2.0** | Expanded notification formatting with Block Kit cards, configurable metadata and wording, body diffs, and inline Issue images. |
| **0.1.0** | Initial Redmine-to-Slack event notification integration under the former plugin name. |
