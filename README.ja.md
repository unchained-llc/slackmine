[English](README.md) | [日本語](README.ja.md)

# Slackmine

![Slackmine — SlackとRedmineの連携](docs/assets/slackmine-icon.png)

バージョン **1.7.6**。

通知機能からSlackとRedmineの統合へ機能が広がったため、**Redmine Event Notifications for Slack**（`redmine_slack_notification`）から **Slackmine** に改名しました。内部名・プラグインID・設定ファイル名・エンドポイントも `slackmine` に統一し、旧名の互換対応は設けていません。

Redmine 7 の Issue、Wiki、News、文書、ファイル、フォーラム、作業時間、Version、Project のイベントを Slack に通知するプラグインです。Issue の期日が近づいたとき、担当者に Slack DM で毎日リマインダーを送ることもできます。通知には Redmine の対象ページへのリンクと、色付きの Block Kit attachment を使います。配信は ActiveJob を経由し、通常は Sidekiq の `slack` キューで処理します。

このプラグインは通知、Work Object操作、任意のスラッシュコマンドを提供します。プロジェクト設定タブやRedmineのカスタムフィールドは追加しません。

## 機能一覧

| 機能 | できること |
| --- | --- |
| [Redmineのイベント通知](#イベントの切り替え) | Issueの作成・変更・コメント・削除と、Wiki、News、作業時間、Version、Projectのイベントを通知。全体またはプロジェクト単位でイベントごとに有効・無効を設定できます。 |
| [通知の表示設定](#通知内容) | 表示項目・色・文言の変更、本文の差分、Issueの画像表示、対応付けた担当者へのメンション。[投稿の編集による連続通知の集約](#投稿の編集で連続通知をまとめる)。 |
| [プロジェクトの通知先選択](#親プロジェクトのチャンネルを継承する) | 明示したチャンネル、または任意の名前マッチングを使い、見つからなければ近い親から順に探索し、最後にデフォルトへ通知。プロジェクトごとにSlackアプリ／トークンも設定できます。 |
| [IssueのWork Objectプレビュー](#チケットの-work-object-previews) | Slack内にチケットカードと詳細を表示。表示項目を設定でき、詳細を開くと最新情報を取得します。 |
| [Slackからのチケット操作](#work-object-カードと詳細パネルからの操作) | 権限内でステータス・担当者・優先度・期日を変更し、コメント追加、自分への割り当て、作業開始・完了、ウォッチ登録・解除。作業時間の入力はRedmineのフォームを開きます。 |
| [コメント通知のスレッド化](#redmineコメント通知をスレッドにまとめる) | RedmineのIssueコメント通知をSlackのスレッドにまとめます。 |
| [任意のスレッドを既存チケットへ接続](#slackの会話スレッドを既存チケットに接続する) | メッセージメニューから接続し、過去分を確認・選択して1コメントに保存。同じ投稿者の連続した発言は通常のカード1枚にまとめ、投稿者が変わると別カードにします。以後の返信・添付を本人名義で取り込み、同じメニューから解除できます。初期値ON。接続情報はSlackのBot投稿に保持し、追加DB・マイグレーションは不要です。 |
| [Slackの返信をRedmineへ保存](#通知スレッドからredmineにコメントを追加) | 対応する通知スレッドへのテキスト・ファイルの返信を、対応付けたユーザー名義のRedmineコメント・添付として保存します。 |
| [スラッシュコマンド](#スラッシュコマンド) | チケット検索、担当・期日一覧、個人リマインダー、チケット作成、コメント追加、フォームや直接指定によるステータス・担当者変更。1件の結果は設定に応じてカード表示し、プレビュー無効時はテキストで表示します。 |
| [Slackメッセージからチケット作成](#slackメッセージからチケット作成) | メッセージメニューから権限のあるプロジェクトを選び、本文と投稿元リンクを引き継いだ作成フォームを確認して保存します。 |
| [Slackリンク取得・カード表示](#redmine本文内のslackリンクカード) | 説明・コメント内のSlackリンクから本文を取得し、既存の本文欄に検索可能な引用を保存。リンク位置にカードを表示し、名前解決とスレッド情報も表示します。 |
| [期日リマインダー](#毎日の期日リマインダー-dm) | 担当する未完了チケットの期限超過・設定期間内の期日をSlack DMでまとめて通知。定期実行は別途設定します。 |
| [App Homeのチケット一覧](#app-homeのチケット一覧) | 自分が更新した・今週期限・担当している・報告した未完了チケットを5列表で表示。フィルター変更で自動更新し、題名からRedmineを開き、編集ボタンから権限内で編集・コメント追加。 |
| [ユーザーの対応付け](#担当者のメンション) | RedmineユーザーとSlack IDの明示的な対応付け、送信時の名前マッチング、任意の[受信操作時のメールアドレス照合](#メールアドレスで閲覧ユーザーを自動対応付けする)。操作時にはRedmineの権限とワークフローを確認します。 |
| [個人ごとの通知メール抑止](#個人ごとの通知メール設定) | Slack通知設定とチャンネル参加が条件を満たす場合、本人が対象の通知メールを停止できます。アカウント・セキュリティ関連メールは継続し、Slackの配信成功は確認しません。 |
| [管理画面](#管理画面の設定対応一覧) | 実効設定・イベント色・プロジェクト通知先・ユーザーメンションを確認。キュー監視・実行履歴・テスト通知はSidekiq使用時のみ利用できます。 |

Work Objectのプレビュー・操作、スラッシュコマンド、スレッド連携、リマインダーには、それぞれの設定とSlackアプリのスコープ・イベント設定が必要です。個人のメール抑止設定は初期値OFFです。必要な権限とSlack側の設定は[設定一覧](#slack権限と機能別の設定一覧)、各機能の制限はリンク先を参照してください。

以下の画像は、実装で対応している表示内容と操作を架空の英語データで示した機能イメージです。実画面やSlackのレイアウトを完全に再現したものではなく、周辺のナビゲーションは省略しています。通知設定の例はYAMLで示し、管理画面の画像は実装されている閲覧用の設定一覧を示しています。英語版・日本語版で同じ画像を使用しています。

## 要件とセットアップ

- Redmine 7.0 以降。
- Bot Token と [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) スコープを持つ Slack アプリ。期日リマインダーの DM には [`im:write`](https://docs.slack.dev/reference/scopes/im.write/)、Issue の画像を本文内に表示するには [`files:write`](https://docs.slack.dev/reference/scopes/files.write/)、名前によるユーザーの自動対応付けには [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) も必要です。スコープを変更したら、Slack アプリを再インストールして Bot Token に反映してください。
- [個人の通知メール抑止](#個人ごとの通知メール設定)でユーザーの自動マッチングを使う場合は、[`users:read`](https://docs.slack.dev/reference/scopes/users.read/)と[`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/)の両方を追加し、Slackアプリを再インストールしてください。
- プロジェクトごとの通知先チャンネル、またはデフォルトのチャンネル。非公開チャンネルを含め、通知先にはボットを招待してください。
- 期日リマインダーのDMや、時間のかかるフォーム保存結果の通知を使う場合は、Slackアプリの **App Home → Display Messages tab** を有効にしてください。
- `slack` キューを処理する ActiveJob ワーカー。本番環境では Sidekiq を推奨します。

1. Redmine 本体のルートディレクトリから、このリポジトリを `plugins/slackmine` に clone します。

   ```sh
   git clone https://github.com/unchained-llc/slackmine.git plugins/slackmine
   ```

2. [動作設定例](config/slackmine.yml.example)を Redmine アプリケーションの `config/slackmine.yml` にコピーします。
3. Bot Token と、デフォルトまたはプロジェクト固有のチャンネル ID を設定します。日本語で表示する場合は[日本語の文言例](config/slackmine.messages.ja.yml.example)、英語の文言を変更する場合は[英語の文言例](config/slackmine.messages.yml.example)を `config/slackmine.messages.yml` にコピーして編集します。実際の設定ファイルは Git に含めないでください。
4. Sidekiq が `slack` キューを処理するように設定し、ボットを通知先チャンネルに招待します。
5. Redmine と Sidekiq を再起動します。どちらのプロセスも YAML 設定をキャッシュします。

### Slack権限と機能別の設定一覧

**OAuth & Permissions → Bot Token Scopes** に、使う機能の権限だけを追加します。通常のチャンネル通知は [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) から始められます。スコープを変更したらアプリを再インストールし、Botを対象チャンネルへ招待してください。

| Bot Tokenスコープ | 必要になる機能 |
| --- | --- |
| [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) | 通知、操作結果の返信、Botが投稿した確認メッセージの削除 |
| [`im:write`](https://docs.slack.dev/reference/scopes/im.write/) | 期日リマインダーのDM送信 |
| [`files:write`](https://docs.slack.dev/reference/scopes/files.write/) | Redmineの添付画像をSlack通知にアップロード |
| [`files:read`](https://docs.slack.dev/reference/scopes/files.read/) | Slackスレッドの添付ファイルをRedmineへ取り込み |
| [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) | 名前での自動対応付け、Bot宛てメンションの除外、リンクカードの投稿者・メンション表示 |
| [`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/) ＋ [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) | メールアドレスでのユーザー対応付け、個人のメール抑止で自動マッチングを使用 |
| [`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/) / [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/) | 公開 / 非公開チャンネルの履歴取得：コメントのスレッド通知、返信取り込み・まとめ保存、Slackリンクカード |
| [`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/) / [`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/) | 公開 / 非公開チャンネルの情報取得：名前での自動対応付け、メール抑止の参加確認、Slackリンクカード |
| [`im:history`](https://docs.slack.dev/reference/scopes/im.history/) ＋ [`im:read`](https://docs.slack.dev/reference/scopes/im.read/) / [`mpim:history`](https://docs.slack.dev/reference/scopes/mpim.history/) ＋ [`mpim:read`](https://docs.slack.dev/reference/scopes/mpim.read/) | DM / グループDMのSlackリンクカード。通常のリマインダーDM送信には不要 |
| [`links:read`](https://docs.slack.dev/reference/scopes/links.read/) ＋ [`links:write`](https://docs.slack.dev/reference/scopes/links.write/) | Redmine URLのWork Object展開・再読み込み |
| [`commands`](https://docs.slack.dev/reference/scopes/commands/) | スラッシュコマンド、メッセージショートカットからのチケット作成 |

通知やメッセージでの応答には共通で [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) が必要です。以下の権限は上の表から組み合わせて設定します。公開・非公開チャンネルの権限は、利用するチャンネル種別に応じて選びます。各機能の詳細と制限はリンク先を参照してください。

| 機能 | 必要なSlack権限 | Slack側での追加設定 | YAML・運用上の要件 |
| --- | --- | --- | --- |
| 通常のチャンネル通知 | [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) | Botを通知先へ招待 | Bot Token、通知先チャンネル、`slack` キューワーカー |
| [Issueの画像表示](#issue-の画像表示) | [`files:write`](https://docs.slack.dev/reference/scopes/files.write/) | — | Redmineに添付された対応画像 |
| [担当者のメンション](#担当者のメンション) | 明示的な対応付けなら追加不要。名前の自動照合は [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) | — | `users` または `slack.auto_map_users_by_name: true` |
| [メールでのユーザー対応付け](#メールアドレスで閲覧ユーザーを自動対応付けする) | [`users:read`](https://docs.slack.dev/reference/scopes/users.read/)、[`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/) | — | `slack.auto_map_users_by_email: true`、`slack.events.team_id` |
| [チャンネル名の自動対応付け](#プロジェクト識別子とチャンネル名の自動マッチング) | [`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/) / [`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/) | Botを対象チャンネルへ招待 | `slack.auto_map_channels_by_name: true` |
| [Work Object通知プレビュー](#チケットの-work-object-previews) | [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) | Work Object PreviewsをON、Taskを選択 | `slack.work_object_previews: true` |
| [Work Objectの詳細表示](#チケットの-work-object-previews) | 詳細表示自体の追加スコープなし | Event Subscriptionsで [`entity_details_requested`](https://docs.slack.dev/reference/events/entity_details_requested/) を購読 | `slack.work_object_previews: true`、`slack.events`、ユーザー対応付け |
| [Work ObjectのURL展開・再読み込み](#チケットの-work-object-previews) | [`links:read`](https://docs.slack.dev/reference/scopes/links.read/)、[`links:write`](https://docs.slack.dev/reference/scopes/links.write/) | [`link_shared`](https://docs.slack.dev/reference/events/link_shared/) を購読、App unfurl domainsにRedmineのホストを登録 | `slack.work_object_previews: true`、`slack.events`、ユーザー対応付け |
| [Work Objectからの編集・コメント](#work-object-カードと詳細パネルからの操作) | 操作自体の追加スコープなし | InteractivityをON | `slack.work_object_previews: true`、`slack.work_object_actions: true`、`slack.events`、ユーザー対応付け、Redmineの操作権限 |
| [コメント通知をスレッドへ投稿](#redmineコメント通知をスレッドにまとめる) | [`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/) / [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/) | イベント購読は不要 | `slack.comment_notifications_in_threads: true`、`slack.events.app_id` |
| [Slack返信のコメント取り込み](#通知スレッドからredmineにコメントを追加) | [`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/) / [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/)、[`users:read`](https://docs.slack.dev/reference/scopes/users.read/)。添付取り込みは [`files:read`](https://docs.slack.dev/reference/scopes/files.read/) も必要 | [`message.channels`](https://docs.slack.dev/reference/events/message.channels/) / [`message.groups`](https://docs.slack.dev/reference/events/message.groups/) を購読 | `slack.thread_comments: true`、`slack.events`、ユーザー対応付け、Redmineのコメント・添付権限 |
| [メッセージからチケット作成](#slackメッセージからチケット作成) | [`commands`](https://docs.slack.dev/reference/scopes/commands/) | メッセージショートカットのCallback IDを `slackmine_message_create` に設定、InteractivityをON | `slack.slash_command`、全体のBot Token・`slack.events`、ユーザー対応付け、Redmineのチケット追加権限 |
| [スラッシュコマンド](#スラッシュコマンド) | [`commands`](https://docs.slack.dev/reference/scopes/commands/)、応答用の [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) | コマンド登録、InteractivityをON | `slack.slash_command`、全体のBot Token・`slack.events`、ユーザー対応付け |
| [App Home](#app-homeのチケット一覧) | 表示自体の追加スコープなし | Home TabをON、[`app_home_opened`](https://docs.slack.dev/reference/events/app_home_opened/) を購読。フォーム操作はInteractivityをON | 全体の `slack.app_home: true`、Bot Token・`slack.events`、ユーザー対応付け |
| [期日リマインダーDM](#毎日の期日リマインダー-dm) | [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/)、[`im:write`](https://docs.slack.dev/reference/scopes/im.write/) | Messages TabをON | `due_reminders.enabled: true`、ユーザー対応付け、毎日のrakeタスク実行 |
| [個人の通知メール抑止](#個人ごとの通知メール設定) | [`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/) / [`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/)。自動マッチングは [`users:read`](https://docs.slack.dev/reference/scopes/users.read/)、[`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/) も必要 | Botを通知先へ招待 | 本人のメール抑止設定、ユーザー対応付け、通知先への本人の参加 |
| [Redmine本文内のSlackリンクカード](#redmine本文内のslackリンクカード) | 対象の会話の [`*:history`](https://docs.slack.dev/reference/scopes/)・[`*:read`](https://docs.slack.dev/reference/scopes/)、[`users:read`](https://docs.slack.dev/reference/scopes/users.read/) | Botを対象の会話へ参加させる。イベント購読は不要 | `slack.link_cards.enabled: true`、Bot Token |

ユーザー対応付けは `users` の明示的な設定、または対応する機能でのメール自動照合を使います。名前での自動照合はSlackからの閲覧・編集の許可には使いません。Slackのスコープを付けてもRedmineの権限は増えません。

| Slack設定画面の項目 | 設定値・用途 |
| --- | --- |
| Event Subscriptions → Request URL | `https://redmine.example.com/slackmine/events`。使う機能のイベントをSubscribe to bot eventsに登録 |
| Interactivity & Shortcuts → Request URL | `https://redmine.example.com/slackmine/interactions`。ボタン、フォーム、メッセージショートカットの受付 |
| Slash Commands → Request URL | `https://redmine.example.com/slackmine/commands`。コマンド名を `slack.slash_command` と一致させる |
| Select Menus → Options Load URL | **空欄**。現在のSlackmineは選択肢をフォームと一緒に送るため、外部検索用URLは不要 |

`slack.events` にはApp ID、Team ID、Signing Secretを設定します。Signing SecretはBot Tokenとは別です。YAML変更後はRedmineとSidekiqを再起動してください。詳細表示・モーダル・App Homeには専用の追加OAuthスコープがなく、設定とユーザー照合が必要です（[詳細表示](https://docs.slack.dev/reference/methods/entity.presentDetails/)、[モーダル](https://docs.slack.dev/reference/methods/views.open/)、[App Homeイベント](https://docs.slack.dev/reference/events/app_home_opened/)）。

最小限の設定例:

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

プラグインは、次の順で最初に見つかった設定ファイルを読み込みます。

1. `<Redmine root>/config/slackmine.yml`
2. `plugins/slackmine/config/slackmine.yml`

動作設定 `slack`、`events`、`users`、`due_reminders` は、`projects.<identifier>` 以下で上書きできます。文言の `messages` とプロジェクト別の `projects.<identifier>.messages` は別ファイルの `slackmine.messages.yml` に置きます。ネストしたマップはキーごとにマージされ、省略したプロジェクト設定は全体設定を引き継ぎます。`false` を明示すると、全体設定の `true` を上書きします。Bot Token の優先順位は、`projects.<identifier>.slack.bot_token`、`SLACK_BOT_TOKEN`、全体の `slack.bot_token` の順です。チャンネルは、`projects.<identifier>.slack.default_channel_id`、従来の `projects.<identifier>.channel_id`、子自身の名前による自動照合の順に確認します。見つからなければ近い親から同じ順序で確認し、最後に全体の `slack.default_channel_id` を使います。プロジェクトのキーには表示名ではなく Redmine の**識別子**を使います。Token またはチャンネルがない場合、通知は送られずログに記録されます。チャンネル ID は通常、公開チャンネルが `C`、非公開チャンネルが `G` で始まります。プロジェクト固有の Token も Git に含めず、YAML の変更後は Redmine と Sidekiq を再起動してください。

次の動作設定例では、プロジェクト固有の Token とチャンネルを使い、コメント通知と Issue のプロジェクト情報を非表示にし、カードの色・Slack ユーザーの対応付けを変更します。その他の設定は全体設定を引き継ぎます。見出しは別の `slackmine.messages.yml` で変更します。

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

文言ファイルにプロジェクト別の見出しを指定する例です。

```yaml
projects:
  agentic:
    messages:
      events:
        issue:
          created: 'New Agentic issue'
```

## イベントの切り替え

![イベントの切り替え](docs/images/features/event-notifications.webp)

通知するイベントは `events` ツリーで制御します。次の表は、各キーと、省略した場合の初期値を示します。`true` で有効、`false` で無効です。引用符で囲んだ文字列ではなく、YAML の真偽値を使ってください。

| `events` 以下のパス | 初期値 | 対象 |
| --- | :---: | --- |
| `issue.created` | `true` | Issue の作成 |
| `issue.updated.enabled` | `true` | 以下の Issue 詳細変更に対する親スイッチ |
| `issue.updated.other_changed` | `true` | Tracker など、その他の Issue 詳細 |
| `issue.updated.status_changed` | `true` | ステータス |
| `issue.updated.assignee_changed` | `true` | 担当者 |
| `issue.updated.priority_changed` | `true` | 優先度 |
| `issue.updated.category_changed` | `true` | カテゴリ |
| `issue.updated.due_date_changed` | `true` | 期日 |
| `issue.updated.start_date_changed` | `true` | 開始日 |
| `issue.updated.version_changed` | `true` | 対象バージョン |
| `issue.updated.subject_changed` | `true` | 件名 |
| `issue.updated.description_changed` | `true` | 説明 |
| `issue.updated.custom_field_changed` | `true` | カスタムフィールド |
| `issue.updated.attachment.added` / `.removed` | `true` | 添付ファイルの追加・削除 |
| `issue.updated.relation.added` / `.removed` | `true` | 関連の追加・削除 |
| `issue.updated.parent_changed` | `true` | 親 Issue |
| `issue.updated.child.added` / `.removed` | `true` | 子 Issue の追加・削除 |
| `issue.comment.added` / `.updated` / `.deleted` | `true` | Issue コメントの追加・編集・削除 |
| `issue.deleted` | `true` | Issue の削除 |
| `wiki.created` / `.updated` | `true` | Wiki ページの作成・更新 |
| `wiki.deleted` | `false` | Wiki ページの削除 |
| `news.created` / `.updated` | `true` | News の作成・更新 |
| `news.deleted` | `false` | News の削除 |
| `news.comment.added` / `.updated` / `.deleted` | `true` | News コメントの追加・編集・削除 |
| `time_entry.created` / `.updated` | `true` | 作業時間の作成・更新 |
| `time_entry.deleted` | `false` | 作業時間の削除 |
| `version.created` / `.updated` | `true` | Version レコードの作成・更新 |
| `version.deleted` | `false` | Version レコードの削除 |
| `project.updated` | `true` | Project の更新 |

`issue.updated.enabled: false` は、個別の詳細設定が `true` でも、Issue の詳細変更通知をすべて抑止します。`issue.comment.*`、`issue.created`、`issue.deleted` は抑止しません。`news.comment.*` は `news.updated` から独立しています。`issue.updated.version_changed` は Issue の対象バージョンの変更、`version.updated` は Version レコード自体の編集を指します。

1 つの Issue Journal で複数の詳細を変更し、コメントも追加した場合は、有効な部分をまとめて 1 件の通知を送ります。無効な詳細は含めません。有効な部分がなければ送信しません。既存の Issue Journal のコメントを空にすると、`issue.comment.deleted` として通知します。Redmine 標準の News 画面ではコメントを編集できませんが、News Comment レコードを更新すると `news.comment.updated` を通知できます。

全体の切り替えは `events` 以下に置き、プロジェクト固有の設定は `projects.<identifier>.events` 以下で上書きします。

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

同じキーでは、プロジェクト固有の値が全体の値より優先されます。全体で無効にした `issue.updated.enabled` をプロジェクトで上書きする場合は、親スイッチもそのプロジェクトで有効にしてください。従来のフラットなキー `status_changed`、`comment_added`、`issue_updated` なども両方の階層で使えます。同じ階層では、ネストしたキーが対応するフラットなキーより優先されます。従来のフラット設定では、`issue_updated` が親スイッチと `other_changed` の両方を制御します。[設定例](config/slackmine.yml.example)にネストした設定の全体を掲載しています。

Wiki ページ、News、作業時間、Version の削除通知は、後から追加されたため初期状態では無効です。削除されたレコードのページは存在しないため、削除通知のリンクは所属するプロジェクトのページを指します。

### 文書・ファイル・フォーラムの追加／変更／削除

| 対象 | 通知設定 |
| --- | --- |
| 文書 | `events.document.created` / `.updated` / `.deleted` |
| 文書添付 | `events.document.file.added` / `.updated` / `.deleted` |
| プロジェクト／バージョンのファイル | `events.file.added` / `.updated` / `.deleted` |
| フォーラムのトピック／返信 | `events.message.posted` / `.updated` / `.deleted` |

追加・変更は初期値ON、削除はOFFです。プロジェクト別に上書きできます。
文書のタイトル・説明・カテゴリ、ファイル名・説明・形式・ダイジェスト、
フォーラムの件名・本文・固定・ロック状態の変更を通知します。
日時やダウンロード数、返信件数だけの内部更新は通知しません。
保存・削除が確定した後に通知し、ロールバック時は投稿しません。
削除通知のリンクは所属する文書一覧・ファイル一覧・掲示板を開きます。

文言は `messages.events.document` / `.file` / `.message`、アイコンは
`messages.icons.document` / `.file` / `.message` 以下の同名操作で変更します。
文書添付はファイルと同じ文言・アイコン設定を使います。
全キーは[設定例](config/slackmine.yml.example)にあります。
チケット添付は既存のチケット変更通知を使い、ファイル通知を重複させません。
標準メールのない変更・削除操作ではSlack通知だけを追加します。
期日リマインダーのメールは抑制対象外です。

## 通知内容

![通知内容](docs/images/features/notification-formatting.webp)

通知の見出しは既定ではアバターを表示しません。`messages.notification_headers` の書式に `%{avatar}` を追加した場合だけ、操作したユーザーの Slack アバターを表示します。`users` の対応表、`slack.auto_map_users_by_name`、または `slack.auto_map_users_by_email` で Slack ユーザーを特定し、`users:read` 権限で画像を取得します。アバターは Bot Token・ユーザーごとに10分間キャッシュします。対応するユーザーや画像が見つからない場合、または取得に失敗した場合は従来の見出しを表示します。本文だけを表示するスレッド内のコメント通知は対象外です。`messages.notification_headers` の `%{avatar}` で画像の位置を指定できます。既定の並びは「アイコン → 名前・イベント文言」です。画像は Slack の context ブロックで同じ行に表示するため、通常の section より文字が小さくなります。`%{avatar}` を省略した書式では画像を表示せず、通常の section の文字サイズを維持します。

カードにはイベントの見出し、Redmine の対象レコードへのリンク、関連する本文や変更項目を表示します。Issue の作成・更新通知には設定した現在値のメタデータを含めますが、コメントのみの通知と削除通知には含めません。その他のイベントでは、以下の設定で無効にしない限りメタデータを表示します。`slack.attachment_color` はカードの左側の線の色を変更します。

```yaml
slack:
  attachment_color: '#2E7D32'
```

初期値は `'#6D5DFB'` です。6 桁の 16 進カラーコードを引用符で囲んで指定してください。無効な値は初期値に戻ります。Markdown のリストや画像があっても、Slack の attachment はカードの左線とセクションを維持します。

`messages.colors` は `messages.icons` と同じ種別・操作の単位で左線の色を指定します。省略・無効な値は `slack.attachment_color` を使います。`projects.<identifier>.messages.colors` でプロジェクトごとに上書きできます。コメントと項目変更を同時に行った通知は、アイコンと同じく `issue.updated` を使います。期日リマインダーは既存の `due_reminders.colors` を使います。

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

操作通知の見出しは、メタデータの表示設定にかかわらず操作した人の名前を表示します。`messages.notification_headers` の `issue`、`comment`、`wiki`、`document`、`file`、`message`、`news`、`news_comment`、`time_entry`、`version`、`project` で種別ごとに変更できます。共通変数は `%{actor}`（操作した人）、`%{event}`（イベント文言）、`%{icon}`、`%{avatar}`（Slack アバター）、`%{project}`、`%{subject}`、`%{product_name}`、`%{noun}`、`%{action}` です。`issue` と `comment` では `%{id}` も使えます。プロジェクト別の文言設定にも対応します。従来の `templates.issue_updated_header` は、新しい `notification_headers.issue` が未設定の場合のみ利用します。

```yaml
messages:
  notification_headers:
    issue: "%{icon} %{actor} *%{event}*"
    comment: "%{icon} %{actor} *%{event}*"
    news: "%{actor} · %{project} · *%{event}*"
  work_objects:
    product_name: Example Tracker
  commands:
    full_form: "%{product_name}で完全なフォームを開く"
```

`%{product_name}` はすべてのメッセージで利用でき、同じプロジェクトの `work_objects.product_name` から展開します。他の変数は、それぞれのテンプレートが対応するものを使ってください。

Issue には、作成・更新の両方に共通する `slack.metadata.issue` マップを 1 つ使います。項目を `true` にすると、変更の有無にかかわらず、どちらの通知でも表示します。初期状態では `project`、`updater`、`tracker`、`category`、`priority` を表示し、その他の Issue 項目は非表示です。未設定の単一値は `Not set`、空のリストは `None` と表示します。その他の通知種別では、`slack.metadata.<type>.<field>` を `false` にすると項目を非表示にでき、省略した項目は表示されます。指定できる項目は次のとおりです。

| 種別 | 項目 |
| --- | --- |
| `issue` | `project`, `updater`, `tracker`, `category`, `priority`, `status`, `assignee`, `author`, `target_version`, `start_date`, `due_date`, `estimated_hours`, `done_ratio`, `parent_issue`, `children`, `relations`, `attachments`, `watchers`, `custom_fields` |
| `wiki` | `project`, `updater`, `location` |
| `news`, `news_comment`, `project` | `project`, `updater` |
| `time_entry` | `project`, `updater`, `hours`, `spent_on` |
| `version` | `project`, `updater`, `status`, `due_date` |

次の例は、Issue の作成・更新通知で現在のステータスと対象バージョンを表示し、News 通知ではプロジェクトを非表示にします。

```yaml
slack:
  metadata:
    issue:
      status: true
      target_version: true
    news:
      project: false
```

`wiki: false` や `issue: false` のように種別を指定すると、その種別のメタデータセクション全体を非表示にできます。`slack.metadata: false` はすべてのメタデータを非表示にします。表示項目がないセクションは省略します。`messages.fields` は表示・非表示を変えずにラベルだけを変更します。

関連 Issue と子 Issue は、参照できる場合にリンクにします。非公開 Issue は省略します。カスタムフィールドには Redmine 上で閲覧できる値を使い、数値 ID で表示対象を選べます。

通知のカスタムフィールドのメタデータは、通知生成時にRedmine標準の表示処理で変換します。列挙型の選択肢IDは選択肢名、ユーザー・バージョンの参照は名称、真偽値はRedmineの言語設定に応じた「はい／いいえ」になります。複数の値はカンマで区切り、通常の数値項目は数値のまま表示します。追加設定やIDと名称の対応表は不要です。

```yaml
slack:
  metadata:
    issue:
      target_version: true
      relations: true
      custom_fields:
            '42': true
```

Issue の更新通知では、変更前後の値を示す独立した **Changes** セクションも表示します。表示対象の項目の変更は常に表示します。初期状態では非表示項目の変更も表示しますが、`slack.issue_changes_when_hidden: false` で省略できます。

```yaml
slack:
  issue_changes_when_hidden: false
```

この設定は Issue の説明文の差分、件名のリンク、コメントを非表示にしません。`events.issue.updated` の各スイッチは、どの変更が通知を発生させて formatter に渡されるかを決めます。この設定は、メタデータで非表示にした項目の変更をカードに表示するかだけを制御します。`custom_fields` は真偽値で閲覧可能な全カスタムフィールドを表示・非表示にでき、マップを使う場合は `default` が指定されていない ID に適用されます。ID は Redmine のカスタムフィールド ID で、項目名や翻訳済みラベルとは無関係です。

互換性のため、従来の `metadata.issue.created` / `metadata.issue.updated` マップも読み込みます。YAML を編集する際は、単一の `metadata.issue` マップへ置き換え、両方の形式を混在させないでください。以前の項目別 `slack.issue_changes` マップと `slack.issue_change_details` スイッチは使われません。非表示項目の変更には `issue_changes_when_hidden`、通知を発生させる変更には `events.issue.updated` を使ってください。

Issue の作成通知には説明文、新しいコメントの通知にはコメント本文を含めます。Issue の更新通知には、有効な詳細変更と、該当する場合は説明文の差分だけを表示します。Wiki の更新では、編集コメントがあればそれを表示し、本文が変更された場合は差分も表示します。Wiki 作成時には本文全体を含めません。News の作成通知には説明文の要約を含めます。削除されたコメントでは削除行を表示します。レコードのタイトルから Redmine の全文へ移動できます。

Redmine の Markdown は Slack 用テキストに変換します。番号付きリストには Slack の `markdown` ブロックを使い、繰り返し現れる `1.` が順序付きリストとして表示されるようにします。通知の概要・コメント・変更後の本文にある Markdown 表も `markdown` ブロックで表示します。チケット以外の通知も対象です。Slack の Markdown ブロックの上限である 12,000 文字を超える内容は [`mrkdwn`](https://docs.slack.dev/messaging/formatting-message-text/) セクションにフォールバックします。

### コメント通知のURLプレビュー

`slack.url_previews: true` で、公開チケットのコメント内のURLにタイトル・説明・画像を追加します。初期値は `false` で、プロジェクト別にも上書きできます。

```yaml
slack:
  url_previews: true
projects:
  another-project:
    slack:
      url_previews: false
```

プレビューは公開チケットのコメント通知に表示されます。コード内の URL、削除されたコメント、ファイル転送制限中の通知は対象外です。リンク先の情報を取得できない場合も、通知は通常どおり送信します。

Redmine のワーカーがページ情報を取得し、Slack が画像を読み込みます。ローカル・プライベートアドレスへのアクセスは、リダイレクト先も含めて拒否します。Slack が画像を拒否した場合は、画像なしで送信します。通知の表示権限は取得前後に確認します。Slack のブロック数上限に近い場合は、収まる分のプレビューを表示します。

追加の Slack スコープは不要です。設定を変更したら Redmine とワーカーを再起動してください。待機中の通知には送信時の設定が適用されます。

### チケットの Work Object Previews

![チケットの Work Object Previews](docs/images/features/work-object-previews.webp)

`slack.work_object_previews: true` にすると、公開 Issue の作成・更新・コメント通知に Slack の **Task Work Object** メタデータを追加します。省略時と `false` は従来の通知です。既存のイベント本文・変更差分・色付きカード・画像を維持し、Work Object のカードを追加表示できるようにします。Issue の削除通知、Wiki などの通知、毎日の期日リマインダー DM には追加しません。

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

全体設定を `false` にして特定プロジェクトだけ `true` にすることもできます。YAML の変更後は Redmine と Sidekiq を再起動してください。

Slack アプリの管理画面でも **Work Object Previews → ON → Task を選択 → Save** を設定してください。ワークスペース側でプレビューが制限されている場合は、その設定も確認してください。通知は既存の [`chat.postMessage`](https://docs.slack.dev/reference/methods/chat.postMessage/) で送信します。通知プレビューだけのために新しいイベント購読やリンク展開のスコープを追加する必要はありません。[Slack の実装仕様](https://docs.slack.dev/messaging/work-objects-implementation/#notifications-implementation)

件名・チケット番号・トラッカーを Work Object の見出しに使います。ステータス、優先度、担当者、作成者、期日は `slack.metadata.issue` で表示が有効な場合だけ標準フィールドとして送ります。プロジェクト、トラッカー、カテゴリ、更新者、対象バージョンも同じ表示設定に従ってカスタムフィールドとして送ります。ラベルには `messages.fields` を使います。それ以外の項目と説明文・コメント本文は既存の通知カードで表示します。担当者・作成者は、明示的な対応表または有効な名前・メール照合でSlackユーザーを特定し、取得できない場合はRedmineの表示名を使います。この照合によってメンションは発生しません。

チケットの URL の SHA-256 値を `external_ref.id` に使い、Slack の ID 文字制限を満たしながら、同じチケットの作成・更新・コメントで共通の識別子を送ります。別の Redmine の同番号チケットとは区別されます。Redmine のホスト名を変更すると識別子も変わります。リンク先の `url` は元のチケット URL のままです。

通知カードは**通知を生成した時点の情報**です。カードを開いたときと詳細パネルの再読み込み時には、[`entity_details_requested`](https://docs.slack.dev/reference/events/entity_details_requested/) を受け取り、[`entity.presentDetails`](https://docs.slack.dev/reference/methods/entity.presentDetails/) で最新のチケット情報を返します。[Slack の詳細表示 API](https://docs.slack.dev/reference/methods/entity.presentDetails/)

Slack標準のWork Object再読み込みは [`link_shared`](https://docs.slack.dev/reference/events/link_shared/) と [`chat.unfurl`](https://docs.slack.dev/reference/methods/chat.unfurl/) で処理します。[`links:read`](https://docs.slack.dev/reference/scopes/links.read/)・[`links:write`](https://docs.slack.dev/reference/scopes/links.write/)、[`link_shared`](https://docs.slack.dev/reference/events/link_shared/) の購読、**App unfurl domains**へのチケットURLのホスト登録を設定し、権限・ドメイン変更後にアプリを再インストールしてください。[`cannot_unfurl_url`](https://docs.slack.dev/reference/methods/chat.unfurl/#errors) が出る場合は、**ワークスペースの設定と権限 → 添付 → ブロックされたプレビュー**を確認してください。対象ドメインがブロックされていると、権限が正しくても新規展開・再読み込みが失敗します。[Slack の更新イベント仕様](https://docs.slack.dev/reference/events/link_shared/)

詳細表示を使う場合は、次の設定を追加してください。`signing_secret` は Slack アプリの **Basic Information → App Credentials → Signing Secret** の値です。Bot Token とは別の値です。環境変数 `SLACK_SIGNING_SECRET` でも指定できます。

```yaml
slack:
  work_object_previews: true
  events:
    app_id: 'A0123456789'
    team_id: 'T0123456789'
    signing_secret: 'REPLACE-ME'
users:
  alice: 'U0123456789' # 実際のSlackメンバーIDに置き換える
```

1. コードと YAML を配置し、Redmine と Sidekiq を再起動します。Sidekiq が `slack` キューを処理していることを確認してください。
2. Slack アプリの **Event Subscriptions → Enable Events** を ON にします。Request URL を `https://redmine.example.com/slackmine/events` にし、**Verified** を確認します。別のサーバーでは Redmine の公開 URL に合わせてください。サブディレクトリ配置の場合は、そのパスも含めます。
3. **Subscribe to bot events** に [`entity_details_requested`](https://docs.slack.dev/reference/events/entity_details_requested/) を追加し、**Save Changes** します。このイベントと [`entity.presentDetails`](https://docs.slack.dev/reference/methods/entity.presentDetails/) に追加 OAuth スコープは不要です。
4. チャンネルの Work Object カードを開き、ステータス・担当者・期日・説明文を確認します。Redmine で変更後、詳細パネルを再読み込みし、最新値になることを確認します。新しい通知を送る必要はありません。

要求の署名・タイムスタンプ・アプリとワークスペースを検証してから、受信したWebプロセス内で直接処理します。閲覧ユーザーは `users` の明示的なログイン名／メールアドレスと Slack ID の対応付け、または有効な `auto_map_users_by_email` のメール一致で確認します。`auto_map_users_by_name` は閲覧許可に使いません。未対応付け・ロック済み・閲覧権限なしのユーザー、非公開チケット、無効なプロジェクト、`work_object_previews: false` のプロジェクトには内容を返さず、アクセス制限を表示します。プロジェクト別の Slack アプリでは `projects.<identifier>.slack.events` と `users` を上書きできます。

権限確認後の詳細には、最新の件名・チケット番号・トラッカー・プロジェクト・状態・優先度・担当者・作成者・期日・作成／更新日時・説明文（最大10,000文字）を返します。詳細表示の項目は通知用の `slack.metadata.issue` 設定とは独立しています。既存コメントや Redmine カスタムフィールド、貼り付けたリンクの自動展開は含みません。編集は下記の設定で有効にできます。

失敗時は Redmine／Sidekiq ログの `Work Object details failed` または `Work Object unfurl failed` に Slack API のエラーコードを記録します。読み取り成功時の調査用ログは出力しません。`missing_interactivity_url` が返る場合は、Slack アプリの **Interactivity & Shortcuts** の Request URL を設定してください。

### Work Object カードの表示項目

カード内の項目は `work_object_fields` のYAML記載順に表示します。`false` の項目と空の項目は飛ばします。Description／Last commentの末尾固定はありません。プロジェクト別設定がある場合は、その記載順を先に使い、引き継いだ項目を全体設定の順で後ろに追加します。

`slack.work_object_fields` でカード本体の全対応項目を個別に表示・非表示にできます。`true` が表示、`false` が非表示です。省略した項目は非表示です。この設定は `work_object_actions` や通知本文の `metadata.issue` より優先します。項目が空なら表示しません（担当者は「未割当」、進捗は `0%` も表示）。進捗はバーではなく正確な％表示です。

設定全体を省略した場合はカード本体の項目を表示しません。`projects.<identifier>.slack.work_object_fields` でプロジェクト別に上書きできます。対象はメインカードの項目で、必須の件名・チケット番号、右ペインの詳細・編集権限は変更しません。

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

`last_comment: true` は最後の公開コメントの投稿者・ISO 8601日時・本文を表示します。非公開・空のコメントは除外し、本文は1,000文字で省略します。最後のコメントが通知本文と完全一致し、省略がない場合のみ本文側の重複を除きます。編集・削除差分は残します。カード再読み込み時に最新の公開コメントを取得します。

`description: true` でカードに説明文を表示します。空欄は非表示、1,000文字を超える場合は省略します。右ペインの説明全文は従来どおりです。

表示文言の既定値は英語です。`messages.work_objects` でボタン・編集画面・エラー文言、`messages.fields` で編集項目名、`messages.values.unassigned` で未割当表示を変更できます。全キーを[文言の設定例](config/slackmine.messages.yml.example)に掲載しています。`edit_title` と `edit_failed` は `%{id}` を使用できます。Slack自身が表示する標準項目名・メニューはSlackの言語設定に従います。

カードの「外部サービスで開く」は課題URLを開きます。`messages.work_objects.open_issue: '%{product_name}で開く'` で表示名を指定できます。

メインカードの「コメントを追加」はコメント専用モーダルを開きます。コメント追加権限を確認し、課題の各属性は変更しません。右ペインの編集操作は引き続き利用できます。表示名は `messages.work_objects.add_comment` で設定します。

### Work Object カードと詳細パネルからの操作

Work Objectの詳細表示、操作ボタンからのフォーム表示、軽い変更は受信Webプロセスで処理します。保存後のカード・App Home更新とURL展開は `slack` キューで処理します。Slackリンクを含む編集フォームは引用取得が長引くため保存もキューで処理し、詳細パネルの結果はSlackアプリのメッセージ欄へ送ります。スレッド接続はフォームをすぐ開き、確認画面の履歴取得はまずWebプロセスで処理します。2秒以内に終わらなければSidekiqに切り替え、接続・過去分保存はSidekiqで処理します。App Home一覧の公開とスラッシュコマンドの配信もキューで行います。通常通知・期日リマインダー・返信取り込みも引き続きSidekiqを使います。

操作の同一リクエスト再送は、既存の `Rails.cache` に検証済み本文のSHA-256と受付マーカーを10分間記録して抑止します。入力本文や権限はキャッシュしません。複数Webプロセス間の抑止には `unless_exist` を原子的に扱える共有キャッシュが必要です。キャッシュの消失・無効化で重複の可能性が残り、保存前の失敗も同じリクエストでは再実行しません。再操作する前にRedmineの保存結果を確認してください。

直接処理の部分はDB処理とSlack API通信を待つため、3秒以内の完了は保証できません。フォーム・詳細表示は実機で確認し、`Slackmine: Work Object ... duration_ms=...` ログを確認してください。キューのジョブもSidekiq側で確認します。WebとSidekiqの両方を再起動してコードを反映してください。

![Work Object カードと詳細パネルからの操作](docs/images/features/issue-actions.webp)

「課題を編集」には、編集権限に応じて現在の題名（必須・最大255文字）と説明を表示します。題名の変更も通常のRedmineの履歴に記録し、保存後にカードの題名を更新します。担当者は、割り当て可能なRedmineユーザーと「未割当」を選べます。詳細パネルのAssigneeも編集できます。保存時に閲覧・編集権限と割り当て可能なユーザーを再確認します。

Work Objectが表示される通知では、上部の重複見出し、本文中の件名リンク、カードにも表示されている現在値を省きます。コメント・説明・変更前後の差分・カードにない項目は残します。通知本文の整理は新しい通知から適用されます。

`slack.work_object_actions: true` を設定すると、Work Object が有効なすべての公開チケットのメインカードにステータス・担当者（未割当の場合も表示）・優先度・期日と「コメントを追加」「外部サービスで開く」を表示します。`work_object_actions: false` で操作を無効にします。「課題を編集」はSlackのモーダルを開き、権限に応じてステータス・担当者・優先度・期日・コメントを変更できます。既定では無効です。Slack アプリの **Interactivity & Shortcuts** を有効にし、Request URL を `https://redmine.example.com/slackmine/interactions` に設定します。署名検証には上記の `slack.events` 設定を共用します。

```yaml
slack:
  work_object_previews: true
  work_object_actions: true
```

公開済みのカードに埋め込まれた項目・ボタンは自動更新されないため、そのカードは再通知または元のメッセージの更新が必要です。詳細パネルの情報は開くたびに最新のチケットを取得します。

詳細パネルからも、許可されたステータス・優先度・期日を編集し、任意でコメントを追加できます。モーダルの担当者欄には割り当て可能なユーザーと「未割当」を表示します（候補が99人以下の場合）。「自分に割り当てる」は、すでに本人が担当者なら変更しません。操作を受信した後もSlackユーザーとRedmineユーザーの対応、チケットの公開・閲覧・編集権限、遷移可能なステータス、有効な優先度、割り当て可能なユーザーを再確認します。操作結果は元のカードまたは詳細パネルへ反映します。保存後にSlack側のカード更新が失敗しても、Redmineへの書き込みは再実行しません。

Work Object の「会話」表示は Redmine のコメント履歴とは別で、既存コメントは表示されません。操作が有効なチケットでは、詳細パネルの編集フォームから新規コメントを追加できます。通知スレッドからのコメント追加は、次の設定で利用できます。

### Work Object ボタンの選択と順序

`slack.work_object_buttons` の `true/false` と記載順で、カード・詳細パネルの操作を選べます。設定がある場合、省略したボタンは非表示です。設定全体を省略すると従来のボタン構成を維持します。プロジェクト別設定のキーを先に並べ、継承したキーを後に並べます。

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

exampleは作業開始・作業完了だけを有効にし、開始先IDを3、完了先IDを5にしています。実際のRedmineワークフローに合わせてIDを変更してください。

| キー | 操作 |
| --- | --- |
| `add_comment` | コメント専用モーダル |
| `reply` | 直近の別の担当者へ戻してコメントを追加 |
| `open_issue` | 外部サービスの課題URLを開く |
| `edit_issue` | 課題編集モーダル |
| `change_assignee` | 担当者専用モーダル |
| `assign_to_me` | 操作したユーザーに割り当て |
| `start_work` | `work_object_start_status_id` の状態へ遷移 |
| `complete_work` | `work_object_complete_status_id` の完了状態へ遷移 |
| `log_time` | Redmineの作業時間登録画面を開く。登録はその画面で行う |
| `watch` | 本人のウォッチ登録・解除 |

先頭2個は主ボタン、続く5個は「その他」メニューです。最大7個まで表示し、超過分は表示せず警告ログを出します。作業開始・作業完了は遷移先ID未設定・到達済みなら非表示です。両方を有効にすると、開始前は「作業開始」、設定した開始ステータスでは「作業完了」だけ表示します。完了先ステータスまたはRedmineの終了ステータスでは両方を非表示にします。両方のステータスIDを指定してください。片方だけ有効な場合は従来どおり独立して表示します。どちらも押下時にRedmineのワークフローと編集権限を再確認します。完了先IDは実際の完了ステータスを指定してください。右ペインでは編集権限・担当者・ウォッチ状態に応じて不要な操作を除きます。共有カードはユーザーごとに表示を変えられないため、個人の権限・状態は操作時に確認します。作業時間登録はRedmine側の権限・必須項目に従います。表示名は同名の `messages.work_objects` キーで上書きできます。

`reply: true` で返信ボタンを表示します。担当者の変更履歴から直近の別の担当者を選び、コメントと同時に保存します。履歴がない・その担当者が無効または割り当て不可・担当者変更権限がない場合は、担当者を変えずコメントだけを追加します。コメント権限は必須です。フォームを開いた時点では変更せず、保存時に最新の履歴・権限を確認します。`add_comment: true` は担当者を変更せずコメントだけを追加します。表示名と返信フォームの説明は `messages.work_objects.reply`／`reply_hint` で変更できます。

カードに両方を表示する設定例：

ボタンが出ない場合は、プロジェクト別設定を含めて `add_comment`／`reply` が `true` か確認してください。`false` またはボタン設定マップ内で省略した操作は表示されず、7個の上限とは別の条件です。有効な操作のうち先頭2個を主ボタンに表示するため、コメント・返信を優先したい場合は以下のように先頭に配置します。既存カードは古いボタン構成を保持する場合があるため、新しい通知またはカードの再読み込みで確認してください。

```yaml
slack:
  work_object_actions: true
  work_object_buttons:
    reply: true
    add_comment: true
```

Description（説明）は、Redmineで本人に `description` の編集権限がある場合、Work Objectの詳細パネルとチケット編集フォームから変更できます。空白・Markdownを含む元の本文を入力欄に渡します。Slackの入力上限は3,000文字のため、それを超える既存の本文は読み取り専用とし、フォームにRedmineの全項目編集画面へのリンクを表示します。保存のために本文を短縮することはありません。空欄にすると説明を削除できます。保存時も権限を再確認し、通常のRedmineの変更履歴・通知に従います。

`watch: true` で登録・解除の両方が有効になります。共有カード・右ペインのどちらも、押下時に「ウォッチ設定」で本人の現在状態と登録／解除ボタンを表示します。古いウォッチ／解除ラベルが残っていても、現在の状態から操作を選び直します。フォームを開いただけでは変更しません。Slackのフォーム表示用トリガーの期限切れを避けるため表示と確認後の保存の両方を同期処理で行います。入力欄のない確認フォームにも対応します。独立した `unwatch` 設定は不要です。表示文言は `messages.work_objects` の `watch_settings`、`watching`、`not_watching`、`watch`、`unwatch` で指定できます。

### メールアドレスで閲覧ユーザーを自動対応付けする

`slack.auto_map_users_by_email: true` にすると、Slackユーザーのメールアドレスと、有効なRedmineユーザーの登録メールアドレス（追加メールも含む）が一意に一致した場合、Work Object詳細表示とSlackからのコメント登録に利用できます。大文字・小文字は区別しません。既存の `users` 設定を優先し、無効・ロック済み・曖昧な設定や、別のSlackユーザーへの明示的な割り当てをメール一致で迂回しません。チケットの閲覧・コメント権限も引き続き確認します。

```yaml
slack:
  auto_map_users_by_email: true
```

Bot Tokenに [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) と [`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/) の両方を追加し、アプリを再インストールしてください。権限確認ごとに [`users.info`](https://docs.slack.dev/reference/methods/users.info/) で最新のユーザー情報を取得します。メール未取得・複数の有効ユーザーに一致・無効ユーザー・Bot・削除済みSlackユーザー・別ワークスペースのユーザー・APIエラー時は自動許可しません。設定された `slack.events.team_id` とSlackユーザーのワークスペースが一致する必要があります。権限確認に使うメール情報はキャッシュせず、追加テーブル・Redis・ファイルへの保存や診断ログへの出力も行いません。`projects.<identifier>.slack.auto_map_users_by_email` で上書きできます。

名前による `auto_map_users_by_name` は送信時のメンションと期日リマインダーの対応付け用です。メール一致は、詳細閲覧・コメント権限確認に加え、Work Objectの担当者・作成者、通知アバター、管理画面のユーザー対応一覧にも使います。送信・表示用の照合はRedmineの主メールアドレスを使い、`users.list` のページ分割取得結果をBot Token・設定ワークスペースごとに10分キャッシュします。`users:read` と `users:read.email` 権限が必要です。キャッシュにはハッシュ化したメールアドレスの照合キーとSlack IDのみを保存し、生のメールアドレスやプロフィールは保存しません。明示的な対応表を優先します。`auto_map_users_by_name` と `auto_map_users_by_email` の両方が有効なら、YAMLで上に書いた設定から照合し、未一致・複数候補の場合は次の方法を試します。プロジェクトごとに順序を変える場合は、そのプロジェクト内で両方の設定を希望の順に記述します。管理画面の「照合方法」には実際に採用した明示設定（ログインID・メールアドレス）／名前一致／メールアドレス一致を表示します。該当なし・メール重複・Bot等のアカウント・ワークスペース不一致・APIエラーの場合はRedmineの名前表示を維持します。一覧取得の失敗時は同じBot Tokenでの照合を60秒待ち、例外クラスと安全な形式のSlackエラーコードのみを記録します。一覧取得は1ページ200人、最大10ページで、途中失敗時の一覧は使いません。この表示用キャッシュは権限付与やメール抑止には使わず、受信時の権限確認では従来どおり毎回 `users.info` を取得します。メンションやDMを自動的に有効化するものではありません。

### 親プロジェクトのチャンネルを継承する

![親プロジェクトのチャンネルを継承する](docs/images/features/channel-routing.webp)

各階層で `slack.default_channel_id` または従来の `channel_id`、次にプロジェクト表示名と同名の既存Slackチャンネルを確認します。子自身から始め、見つからなければRedmineの実際の親階層を近い順にたどります。どこにもなければ全体のデフォルトチャンネルを使います。子に同名チャンネルがなく、親に対応する既存チャンネルがある場合、子のチャンネルIDをYAMLへ繰り返し記入する必要はありません。子自身の名前一致は祖先の明示設定より優先します。

継承するのは送信先チャンネルだけです。Bot Token・イベント・文言・ユーザー対応付け・リマインダーは従来の全体／個別設定の規則を維持します。子で使うBotが選択先のチャンネルに参加している必要があります。親階層を変更すると継承先も変わります。名前検索には子の `slack.auto_map_channels_by_name: true` が必要で、各祖先の自動照合にもそのプロジェクトの設定を使います。子で `false` にすると祖先を含めた名前検索を無効化しますが、祖先の明示的なチャンネル指定は引き続き参照します。

```yaml
projects:
  parent-project:
    channel_id: 'C0123456789'
  # チャンネルを個別指定しない子は、この親のチャンネルを使います。
```

### プロジェクト識別子とチャンネル名の自動マッチング

`slack.auto_map_channels_by_name: true` で、Redmineプロジェクトの**識別子**とSlackチャンネル名を自動照合できます（識別子 `customer-support` → `#customer-support`）。前後の空白と大文字・小文字の違いを無視し、空白はハイフンに変換します。表示名は照合に使いません。曖昧な部分一致、チャンネル作成、自動参加は行いません。

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

各プロジェクトで `slack.default_channel_id`、旧形式の `channel_id`、一意な名前一致の順に確認します。子自身、近い親から順に祖先を確認し、最初に見つかったチャンネルを使います。どの階層にもなければ共通の `slack.default_channel_id` を使います。一致なし・複数候補・APIエラー時は共通の通知先に戻り、共通設定もなければ通知をスキップしてログに記録します。スイッチはプロジェクト別に上書きできます。

[`users.conversations`](https://docs.slack.dev/reference/methods/users.conversations/) でBotが参加しているチャンネルだけを取得します。公開チャンネルには [`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/)、非公開チャンネルには [`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/) を追加し、アプリを再インストールしてください。スレッド通知に使う [`*:history`](https://docs.slack.dev/reference/scopes/) とは別のスコープです。アーカイブ済みチャンネルとDMは除外します。一覧はBot Token別にプロセスのメモリへ10分間キャッシュし、DB・Redis・ファイル・Railsキャッシュには保存しません。名前・参加状態の変更が反映されるまで最大10分かかり、ワーカーの再起動でキャッシュは消えます。取得は200件ずつ最大10ページに制限し、不完全な一覧や取得失敗時は自動照合に使いません。キャッシュはワーカーごとに独立します。

コメント通知のスレッド投稿とSlackからのコメント登録にも自動判定を適用します。共通スイッチがONならプロジェクト別のYAML設定は不要です。返信の権限確認と、明示的なユーザー対応付けまたは有効なメール自動照合は引き続き必要です。

### 投稿の編集で連続通知をまとめる

最初の通知は即時投稿し、同じチケット・同じ投稿先の後続通知は、更新者や回数によらず[Slackの `chat.update`](https://docs.slack.dev/reference/methods/chat.update/) でその投稿を編集します。見出し・変更欄は1つにまとめ、同じ項目の変更は「終了 → アサイン → 進行中 → 終了」のように履歴をつなげます。コメントと画像は本文に残し、Work Objectと補足項目は最新の通知内容を使用します。更新者が複数の場合は見出しに列記し、コメント本文にも更新者を表示します。チケット作成・項目変更・コメント・削除の通知が対象です。

```yaml
slack:
  notification_coalescing:
    enabled: true
    seconds: 300
```

`enabled: true`で有効、`false`または省略で無効です。集約時間は既定で5分（300秒）です。`seconds`は省略でき、変更する場合は1〜300の整数秒を指定します。範囲外・不正な値では300秒を使い、300秒を超える整数は300秒に制限します。`projects.<identifier>.slack.notification_coalescing`配下の`enabled`・`seconds`でプロジェクト別に上書きできます。最初の投稿からの固定時間で、編集による延長はありません。指定時間内の後続通知は元の投稿を編集し、5回で分割する制限はありません。明示的に異なる投稿先スレッドは個別に集約します。コメント通知の自動スレッド振り分けより投稿の編集を優先します。合計45ブロック・添付5個・見出しや本文ブロック3,000文字・項目2,000文字・24KBの表示上限に達した場合は、同じ投稿内で古い内容を短縮し、チケットの全文履歴へのリンクを残します。リンク文言は`messages.notification_coalescing.history`で設定できます。

投稿先・チケット・通知ごとの本文と権限確認情報を既存の`Rails.cache`に保存します。ワーカー間で`unless_exist`を原子的に扱える共有キャッシュを使用し、指定時間内に記録が消失しないよう運用してください。記録が消失すると元投稿の対応付けも失われます。同時処理は同じ投稿のロックを待ち、キャッシュ障害やロック競合が続く場合は別投稿せずジョブ再試行へ渡します。Slack投稿自体の削除・編集不可の場合のみ代替投稿を作成します。追記前に、保存済みコメントの非公開化・編集・削除、フィールドの公開範囲、通知先・イベント設定を再確認し、条件が変わった内容は元投稿から除いて更新します。追加スコープ・DBテーブル・定期タスクは不要です。YAML変更後はRedmineとワーカーを再起動してください。

### Redmineコメント通知をスレッドにまとめる

![Redmineコメント通知をスレッドにまとめる](docs/images/features/comment-threads.webp)

`slack.comment_notifications_in_threads: true` にすると、コメントだけの追加・編集・削除通知を、設定したチャンネル内の同じチケットの最新通知スレッドに投稿します。省略時・`false` は従来どおりチャンネルに投稿します。有効なチケット項目の変更も含む更新はチャンネルに投稿します。スレッドが見つかった場合、新規コメントは設定可能な見出しと書式付きの本文を表示し、チケットリンク・完全なイベントカード・Work Objectプレビューは繰り返しません。編集は設定された本文・差分表示、削除は削除差分を維持し、画像も引き続き扱います。通常のチャンネル投稿に戻る場合は完全な通知形式を使います。`slack.thread_comments` やWork Object Previewsとは独立した設定です。

```yaml
slack:
  comment_notifications_in_threads: true
  events:
    app_id: 'A0123456789'
```

`projects.<identifier>.slack.comment_notifications_in_threads` でプロジェクト別に上書きできます。Botのチャンネル参加と、非公開チャンネルでは [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/)、公開チャンネルでは [`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/) が必要です。スコープ追加後はアプリを再インストールしてください。`slack.events.app_id` でこのアプリの通知を識別します。コメント通知の送信だけならEvent Subscriptionの追加は不要です。

簡易通知の見出しは `messages.thread_notifications.added_header`・`updated_header`・`deleted_header` で変更できます。`%{product_name}`・`%{id}`・`%{actor}`・`%{subject}` を利用でき、`projects.<identifier>.messages` でプロジェクト別に上書きできます。既定値と設定例は英語です。見出しとコメント本文を分け、本文は一度だけ表示します。見出し内の `#%{id}` は、そのチケットのRedmineページへのリンクになります。

```yaml
messages:
  thread_notifications:
    added_header: '%{actor} · %{product_name} #%{id}: New comment'
    updated_header: '%{actor} · %{product_name} #%{id}: Comment updated'
    deleted_header: '%{actor} · %{product_name} #%{id}: Comment deleted'
```

通知ごとに履歴を最大3ページ、各ページ100件を要求して検索します（Slackが返す件数は少ない場合があります）。設定したアプリの最上位通知で、件名のチケットURLが完全一致するものだけを対象にします。利用者の投稿、コメント本文中のリンク、チャンネルにも送信されたスレッド返信は対象外です。見つからない場合、アプリID未設定、履歴取得エラー時は通常のチャンネル投稿に戻ります。DB・Redis・ファイルにスレッドの対応表は保存しません。会話開始時と最新通知のスレッドが異なる場合があり、検索範囲外の古い通知には戻れません。履歴取得による遅延とSlack API利用回数が増えます。既存の通知は移動しません。

### 通知スレッドからRedmineにコメントを追加

![通知スレッドからRedmineにコメントを追加](docs/images/features/thread-replies.webp)

Work Objectカードは、Slackがカードを準備している間、履歴APIで`from_url`と添付IDだけの形式になることがあります。この簡略形式も、アプリの投稿であることを確認した親通知のfallbackにある最初のチケット番号と、唯一の正規カードURLが一致する場合に識別します。不一致・曖昧な参照は取り込みません。コメント保存成功時は同じSlackスレッドに確認メッセージを返します。

`slack.thread_comments: true` にすると、このプラグインが送った Issue 通知へのテキスト・ファイルの返信を、返信者本人の Redmine コメントとして登録します。省略時・`false` は無効です。Work Object Previews は必須ではありません。

```yaml
slack:
  thread_comments: true
  events:
    app_id: 'A0123456789'
    team_id: 'T0123456789'
    signing_secret: 'REPLACE-ME'
users:
  alice: 'U0123456789' # 実際のSlackメンバーID
projects:
  another-project:
    slack:
      thread_comments: false
```

Bot自身の発言と、人がBotやアプリのユーザーに `@メンション` した発言は常に取り込み対象から除外し、保存結果も返信しません。人へのメンションを含む会話は引き続き取り込みます。まとめ保存でもBot宛ての発言は含めません。メンション先の確認には Bot Token スコープ [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) が必要です。確認APIの一時的な失敗時は、未確認の発言を取り込まずジョブを再試行します。

Slack 側では非公開チャンネル用の Bot Token スコープ [`groups:history`](https://docs.slack.dev/reference/scopes/groups.history/) とイベント [`message.groups`](https://docs.slack.dev/reference/events/message.groups/) を追加してください。公開チャンネルの場合は [`channels:history`](https://docs.slack.dev/reference/scopes/channels.history/) と [`message.channels`](https://docs.slack.dev/reference/events/message.channels/) を使います。スコープ追加後はアプリを再インストールします。署名検証と Request URL は詳細表示と共通です。Bot が対象チャンネルに参加している必要があります。[Slack のメッセージイベント](https://docs.slack.dev/reference/events/message/)

`restrict_transfer` または全体の `force_restrict_transfer` が `true` の場合は、ファイル付き返信も元メッセージへのリンクとして保存し、`files:read` は使用しません。詳しくは[監査・社内規程向けのファイル連携制限](#監査社内規程向けのファイル連携制限)を参照してください。

通常のファイル取り込みでは、ファイル付き返信（ファイルだけの投稿も含む）にはBot Tokenスコープ [`files:read`](https://docs.slack.dev/reference/scopes/files.read/) が必要です。追加後にアプリを再インストールしてください。PDF・Office文書・圧縮ファイル・テキストなど、SlackにアップロードされたファイルをBot認証で取得し、返信者名義の通常のRedmineチケット添付として保存します。PNG・JPEG・GIF・WebPは検証して画像表示し、それ以外（SVG・動画を含む）は `attachment:"ファイル名"` の記法で保存し、ファイル名からRedmineの添付表示ページへリンクします。プレビューの可否はRedmineとファイル形式に依存します。取り込み時に添付IDをSlack引用の保存情報へ記録し、明示的に対応付けた添付だけを本文と「Open in Slack」の間にまとめます。通常のコメントや、この対応情報がない過去の返信は従来の表示を維持します。カードが表示されない場合は出典URLの下に添付参照を表示します。画像は添付ファイル名で参照し、`@2x`も維持してRedmineの画像サイズ補正を適用します。1返信につき最大10ファイル、1ファイルは10 MiBとRedmineの添付サイズ上限の小さい方まで、合計50 MiBまでです。Redmineの添付権限・拡張子制限も適用します。コメントと添付は同じトランザクションで保存し、取得・検証に失敗した場合はコメントだけを残しません。再送で保存済み添付を重複登録しません。外部ファイルは非対応です。ファイルの拒否時は失敗を返信し、一時的なAPI・通信エラーはジョブで再試行します。

追加テーブル・DBマイグレーション・Redisへの処理済みID保存は不要です。返信先の親通知1件だけを [`conversations.history`](https://docs.slack.dev/reference/methods/conversations.history/) で取得し、アプリIDとチケット見出しの正規URLを検証します。対象は現在の設定で通知先になっているチャンネルです。既存の通知にも返信できますが、他のアプリ・ユーザーの投稿や任意のチケットリンクへの返信は登録しません。

`users` に明示的に対応付けた、または有効なメール自動照合で特定したユーザーについて、チケットの閲覧権限とトラッカーを含むコメント追加権限を確認します。非公開チケット・無効なプロジェクト・未対応付けユーザーは拒否します。返信の本文は最大10,000文字まで受け付けます。コメントには元メッセージへのURLを保存し、リンクカードが有効なら既存の引用取り込み処理で本文を保存・カード表示します。既存のJournalの `created_on` と `updated_on` の両方にSlackの元の投稿時刻を設定し、浮動小数点を経由せずマイクロ秒まで保持します。新規取り込み時には「編集済み」を付けず、その後Redmineで編集した場合は通常どおり編集日時が更新されます。同じチケット・対応付けた投稿者・投稿時刻のコメントがあれば再送と判断します。既存のチケット行ロック中に重複確認と保存を行います。追加テーブル・カラム・Redisへの状態保存・状態ファイルは不要です。本文をRedmineで編集しても重複判定は維持されます。旧バージョンの出典行付きコメントも重複確認の対象です。

正確な重複判定には、既存の `journals.created_on` がマイクロ秒（小数点以下6桁）を保持できることが必要です。日時の精度が低い環境では、同じ投稿者の別の返信を重複と判断する場合があります。同じチケット・対応付けた投稿者・完全に同じ投稿時刻の別コメントも重複と判断します。コメントを削除したり、投稿者や投稿時刻を変更したりすると、その返信の重複判定はできなくなります。既存コメントの出典行は自動では削除しません。

Work Objectのカードや詳細ヘッダー、「〜で開く」に使うサービス名は `messages.work_objects.product_name` で変更できます（既定値: `Redmine`）。返信結果の文言には `%{id}` と `%{product_name}` を使えます。成功・拒否の確認メッセージ内の `#%{id}` もチケットへのリンクになります。すべて `projects.<identifier>.messages` でプロジェクト別に上書きできます。

```yaml
messages:
  work_objects:
    product_name: 'Example Tracker'
  thread_comments:
    saved: '✅ Comment added to %{product_name} #%{id}.'
    restricted: '⚠️ Could not add the comment. Check your permissions.'
```

設定変更は新しい通知と再取得した詳細に反映されます。既存の通知カードは書き換えません。「詳細」「会話」などSlack側のUI文言はSlackの言語設定に従います。

既定では即時保存します（`wait_seconds` の省略時・`0`）。下の設定例ではまとめ保存を有効にし、同じSlackユーザーによる同じスレッド内の連続した返信だけを、最後の返信から60秒、最初の返信から最大300秒で1つのRedmineコメントにまとめます。`max_wait_seconds` の省略時は300秒です。別のユーザーが投稿したら、その受信ジョブで直前のまとまりを待ち時間を残さず保存します。新しい投稿者の分は通常の待機を開始するため、A→A→B→Aは発言順を保った3コメントになります。Botの結果返信では区切りません。表示も1枚のカードにまとめ、投稿者・日時を1回表示して本文を順番につなぎます。短い投稿は1改行で区切り、「Open in Slack」は1つだけ表示します。各投稿のURLは引用の保存データに残し、添付もまとめて取り込み、保存結果は1回返します。投稿者・スレッド・アプリ・ワークスペースが違う返信は分けます。1回に最大20投稿までまとめ、既存の本文・添付の上限はまとめた全体に適用します。時間はジョブの実行予定で、ワーカーが混雑すると保存が遅れることがあります。

```yaml
slack:
  thread_comment_batch:
    wait_seconds: 60      # 省略・0なら即時保存
    max_wait_seconds: 300
  thread_comment_feedback_cleanup_seconds: -1
```

プロジェクト別に上書きできます。遅延ジョブに元のイベントを渡し、実行時に [`conversations.replies`](https://docs.slack.dev/reference/methods/conversations.replies/) でSlackのスレッドを取得します。新しいDBテーブルやキャッシュへの蓄積は行いません。ActiveJobの遅延ジョブに対応したワーカー（Sidekiq等）と、対象チャンネルの返信APIを取得できるBot権限が必要です。待機中はSlackへ投稿せず、保存済みのコメントはまとめ直しません。スレッド取得は最大1000投稿とし、超過時は不完全な取り込みをせずエラーにします。YAML変更後はRedmineとワーカーを再起動してください。

Slackのスレッドで会話を続けていると、返信のたびに「コメントを追加しました」という確認メッセージが入り、会話の流れを追いづらくなることがあります。保存結果を確認する時間を残しつつ、会話を読みやすく保つために、Botの結果メッセージを一定時間後に自動削除できます。たとえば `slack.thread_comment_feedback_cleanup_seconds: 60` なら、結果を表示してから60秒後に片付けます。成功・権限拒否・ファイル拒否の結果メッセージが対象です。

`slack.thread_comment_feedback_cleanup_seconds` は削除までの秒数です。省略時・`-1` は削除しない、`0` は結果メッセージを投稿しません（成功・拒否・失敗すべて）。不正な値も削除しない設定として扱います。`projects.<identifier>.slack` で上書きできます。元のSlack返信やRedmineのコメントは削除しません。正の値による自動削除には予約ジョブを実行できるワーカー（Sidekiq等）が必要で、実際の削除時刻はジョブの処理状況により遅れる場合があります。削除実行前に `-1` に変更すると、予約済みの削除も実行しません。

保存結果は同じスレッドに返します。文言は `messages.thread_comments.saved`（`%{id}` と `%{product_name}` を利用可）と `messages.thread_comments.restricted` で変更できます。ファイルの拒否時は `messages.thread_comments.image_failed` を使います。成功コメントの通常のSlack通知は抑制しますが、Redmineの標準メール通知等は通常どおり動きます。Bot投稿・Slackでの編集／削除は同期しません。取得不能・サイズ超過・無効なファイルを含む返信は全体を拒否します。Slackのメンションやリンク表記をRedmine形式へ変換する処理も含みません。保存後の結果返信に失敗してもコメントは残り、ログに記録します。スイッチをOFFにしても既に登録されたコメントは残ります。

`slack.suppress_thread_comment_notifications: false` にすると、Slackから取り込んだコメントも通常のSlack通知を送ります。省略時・`true` は従来どおり抑制します。イベントスイッチと `comment_notifications_in_threads` の設定も適用され、保存結果の返信は別途送ります。`projects.<identifier>.slack.suppress_thread_comment_notifications` でプロジェクト別に上書きできます。メール通知の扱いは変更しません。YAML変更後はRedmineとワーカーを再起動してください。

```yaml
slack:
  thread_comments: true
  suppress_thread_comment_notifications: false
```

コード・YAMLの反映後、RedmineとSidekiqを再起動してください。テスト用チケットの通知へ返信し、本人名義のコメント本文と成功返信を確認します。権限のないユーザー、Bot返信、Slack側での編集も試し、コメントが増えないことを確認してください。

### 本文の差分

初期状態では、Issue の説明文・コメント、Wiki・フォーラムの本文、News の説明文・コメント、文書の説明文を編集すると行単位の差分を表示します。`diff` コードブロックでは、削除行に `-`、追加行に `+` を付け、前後に変更のない行を 2 行ずつ含めます。長い行や大きな差分は短縮されるため、全文はレコードのリンクから確認してください。編集コメントだけを変更した Wiki 更新には本文差分を表示しません。`document.description` は文書の説明文、`message.body` はフォーラムのトピック・返信の本文差分を制御します。フォーラム編集時は差分または更新後の本文を一度だけ表示します。ファイル通知の説明文はテキスト表示で、本文差分は生成しません。

種別ごとに `slack.body_diff` を設定します。`false` にすると差分の代わりに更新後の本文を表示します。

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

省略した項目の初期値は `true` です。`issue`、`wiki`、`news`、`document`、`message` 自体を `false` にすると、その下のすべての差分を無効にします。従来の単一値 `body_diff: true` / `body_diff: false` も、すべての種別に適用されます。削除された Issue・News コメントは、この設定にかかわらず削除行を**常に**差分で表示します。

### 監査・社内規程向けのファイル連携制限

監査や社内規程でファイルの外部転送・複製を厳しく制限する会社向けに、ファイル本体を転送せず、元の保存場所へのリンクだけで連携するオプションがあります。

```yaml
slack:
  files:
    restrict_transfer: true
    force_restrict_transfer: false
```

有効にすると、RedmineからSlackへの画像アップロードを止め、通知内の画像参照をRedmineの添付ファイルへのリンクに置き換えます。SlackからRedmineへの返信取り込みでは、添付ファイルの情報取得・ダウンロード・保存を行わず、Slackの元メッセージへのリンクを保存します。ファイルだけの返信もリンクとして保存します。本文と引用カードの連携は従来どおりです。ファイル保存を行わないため、添付追加権限は不要ですが、チケットの閲覧・コメント追加権限の確認は継続します。

全体設定を既定値として、`projects.<identifier>.slack.files.restrict_transfer` でプロジェクトごとに上書きできます。例えば全体をリンクのみとし、ファイル転送を許可したプロジェクトだけ例外にできます。

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

会社方針として例外を禁止する場合は、全体の `slack.files.force_restrict_transfer: true` を指定します。全体・プロジェクトの `restrict_transfer: false` より優先し、すべてのプロジェクトでファイル転送を制限します。`force_restrict_transfer` は全体設定でのみ有効で、プロジェクト側に指定しても無視します。既定値は `false` です。

```yaml
slack:
  files:
    force_restrict_transfer: true
```

プロジェクト設定を省略すると全体の `restrict_transfer` を継承します。強制が無効で、`restrict_transfer` も省略または有効な設定が `false` なら従来のファイル転送を維持します。設定を変更したらWeb・ジョブワーカーを再起動してください。待機中のジョブも実行時の設定に従います。既に転送したファイル・保存したコメントは削除しません。リンク先の閲覧には元サービスの権限が必要です。

リンクのみのモードでは、Slackへの投稿でリンク・メディアの自動プレビューも無効にします。

このオプションの対象はSlackmineによるファイル本体の転送です。会話本文・URL・ファイル名は引き続き連携するため、監査要件全体への適合を保証するものではありません。別の連携によるファイル転送や、利用者自身によるSlackへのアップロードは制御しません。

### Issue の画像表示

以下はファイル転送制限が無効な場合の動作です。`restrict_transfer` または全体の `force_restrict_transfer` が `true` の場合は、[監査・社内規程向けのファイル連携制限](#監査社内規程向けのファイル連携制限)に従ってリンクに置き換えます。

公開 Issue の作成・コメント通知では、`![](screenshot.png)` のようなローカル Markdown 画像参照を認識します。作成時は Issue に添付された同名の画像を、コメントでは同じ Journal に添付された画像をアップロードできます。対応形式は PNG、JPEG、GIF です。画像は色付きカードの中に表示されます。外部 URL やファイルシステム上のパスは取得しません。画像は空でないことと、20 MiB 以下であることが必要です。Bot Token には [`files:write`](https://docs.slack.dev/reference/scopes/files.write/) が必要です。

公開 Issue の既存コメントを編集した場合にも適用されます。`body_diff.issue.comment: false` では、対象の画像を更新後の本文の Markdown 上の位置に表示します。`true` では、コメントの差分の後に画像プレビューを表示します。削除されたコメントの画像は再アップロードしません。アップロードに成功すると、Markdown の画像参照を置き換え、重複した添付リンクは追加しません。画像がサイズ上限を超えるなどしてアップロードできない場合は、Redmine の添付ファイルまたは Issue へのリンクを通知に含めます。

新しくアップロードした非公開ファイルをチャンネルに共有するため、プラグインはカード全体とともに一時的な最上位の参照を投稿し、その後 [`chat.update`](https://docs.slack.dev/reference/methods/chat.update/) で一時プレビューを削除します。削除に失敗した場合は、通知を再投稿せずエラーを記録します。アップロード直後に利用可能になっていないファイルは、短時間リトライします。プラグイン更新前に投稿された Slack メッセージは書き換えません。

### 文言とテンプレート

`slackmine.messages.yml` の `messages` ツリーで通知文言・アイコン・色を変更できます。イベントを送るかどうかは制御しません。すべてのキーは任意です。省略した値や空文字列には組み込みの初期値を使います。未知のイベントに使うアイコンは `messages.templates.icon_fallback` で指定できます。[日本語](config/slackmine.messages.ja.yml.example)と[英語](config/slackmine.messages.yml.example)の設定例には、使用できるすべてのキーとサンプル値を掲載しています。

英語の既定文言は [config/slackmine.messages.yml.example](config/slackmine.messages.yml.example) にまとめています。日本語の設定例は [config/slackmine.messages.ja.yml.example](config/slackmine.messages.ja.yml.example) です。コピーした `config/slackmine.messages.yml` は Git 管理対象外にしてください。Redmine 本体の `config` に置いたファイルがプラグイン内のファイルより優先されます。プロジェクト別の上書きは同じファイルの `projects.<識別子>.messages` に指定できます。移行中は旧 `slackmine.yml` 内の `messages` も読み取りますが、新しい文言ファイルの値を優先します。スレッド接続の画面・結果通知・エラー・保存する過去会話の見出しは `messages.thread_connections`、Slack引用カードとプレーンテキストの代替表示は `messages.link_cards` で変更できます。未知のイベント名・関連種別の表示は `messages.templates.event_fallback` と `relation_fallback` で変更できます。旧 `slack.link_cards.link_text` は別ファイルに `messages.link_cards.open` がない場合だけ使います。

```yaml
messages:
  thread_connections:
    title: スレッドをチケットに接続
    close: 閉じる
    connect: 接続する
    connected: このスレッドを接続しました。以後の返信・添付を保存します。
    history_heading: Slackスレッドから取り込み（接続前の会話）
  link_cards:
    open: Slackで開く
    parent_open: 親メッセージをSlackで開く
    reply_count: '%{count}件の返信'
projects:
  example:
    messages:
      thread_connections:
        connect: このプロジェクトに接続
```

接続先が未選択の最初の画面には全体設定を使い、チケットが確定した後の画面や結果通知にはそのプロジェクトの設定を適用します。テンプレートの `%{...}` は既定YAMLに記載された名前を使ってください。無効なプレースホルダーは既定テンプレートに戻ります。過去会話の見出し変更は新しい取り込みに適用し、保存済みコメントは維持します。

| グループ | 設定対象 |
| --- | --- |
| `messages.events` | `Issue updated` などのイベント名 |
| `messages.icons` | イベントの絵文字 |
| `messages.colors` | イベントごとのカードの左線の色 |
| `messages.sections` | カードのセクション見出し |
| `messages.fields` | メタデータと変更項目のラベル |
| `messages.relations` | 関連の名称 |
| `messages.values` | 代替表示の語句と変更を示す動詞 |
| `messages.diff` | 差分の見出しと省略通知 |
| `messages.images` | 一時プレビューの文言、代替テキスト、リンクのラベル |
| `messages.templates` | Issue 更新時の見出しと、attachment のプレーンテキスト代替表示 |
| `messages.due_reminders` | 毎日の DM の見出し、ラベル、相対日数、代替表示 |
| `messages.thread_connections` | 接続画面・結果通知・エラー・保存する過去会話の見出し |
| `messages.link_cards` | 引用カードのリンク・スレッド表示・プレーンテキストの代替テンプレート |

Issue の更新通知の見出しには、更新した Redmine ユーザーを使います。Slack マークアップでの初期形式は `🔄 Alice *Issue updated*` です。プラグインを編集せずに、アイコンの後の文言を変更できます。

```yaml
messages:
  templates:
    issue_updated_header: '%{actor} *%{event}*'
```

`issue_updated_header` テンプレートは、コメントを含む Issue 更新にも適用されます。Issue の作成・削除、単独のコメント通知の見出しには、それぞれのイベント名を使います。操作者は Slack のメンションではなく名前で表示します。

その他のテンプレートは、カードを表示できないクライアント向けの attachment のプレーンテキスト代替表示を作ります。

| テンプレート | 適用対象 | 使用できるプレースホルダー |
| --- | --- | --- |
| `issue_updated_header` | Issue 更新通知の見出し | `%{actor}`, `%{event}` |
| `issue_fallback` | Issue の作成、コメントを伴わない更新、削除 | `%{project}`, `%{actor}`, `%{action}`, `%{tracker}`, `%{id}`, `%{subject}` |
| `journal_fallback` | コメントを伴う Issue の変更と、単独の Issue コメント | `%{project}`, `%{actor}`, `%{event}`, `%{tracker}`, `%{id}`, `%{subject}` |
| `generic_fallback` | Wiki、News、News コメント、作業時間、Version、Project | `%{event}`, `%{subject}` |

たとえば `generic_fallback: '%{event}: %{subject}'` は、`News updated: Example title` を作ります。プレースホルダーは `%{name}` 形式で指定してください。不明なプレースホルダーを指定すると、そのテンプレートには組み込みの初期値を使います。

### 担当者のメンション

![担当者のメンション](docs/images/features/user-mapping.webp)

Issue の担当者が変わったとき、明示的な `users` の対応付けによって新しい担当者を Slack メンションにできます。

```yaml
users:
  # Redmine login or email address: Slack member ID
  alice: 'U0123456789'
```

`slack.auto_map_users_by_name: true` を設定すると、Redmine の**ログイン名**と、有効な人間の Slack ユーザーの `profile.display_name` またはアカウントの `name` が大文字・小文字を区別せず完全一致する場合にも、自動で対応付けられます。明示的な対応付けが優先されます。対応するユーザーがいない場合や複数いる場合は、Redmine の名前をそのまま表示します。ユーザー一覧は 10 分間キャッシュし、API エラー時も名前表示へ戻します。自動対応付けには [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) と、スコープ追加後のアプリ再インストールが必要です。担当者メンションの対応付けではメールアドレスを読み込まず、[`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/) は不要です。[個人の通知メール抑止](#個人ごとの通知メール設定)にも名前の自動マッチングを使う場合は、本人確認のため[`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/)も必要です。

担当者のメンションを止めたい場合は、`users` の該当ログイン名を `null` にし、`slack.auto_map_users_by_name: false` にします。同じユーザーのメールアドレスにもSlack IDを設定している場合は、そちらも `null` にしてください。対応するSlack IDがなくなると、Redmineの名前を通常のテキストで表示します。`null` はメンションだけの設定ではなく、他の機能で使う明示的なユーザー対応付けも外します。

```yaml
slack:
  auto_map_users_by_name: false
users:
  alice: null
  'alice@example.com': null # メールアドレスにも対応付けていた場合
```

`auto_map_users_by_email` はSlackからの閲覧・操作時の本人照合と、担当者・作成者・通知アバターの表示、`auto_map_channels_by_name` は通知先チャンネルの自動選択です。両方とも既定値は `false` ですが、メンションを止めるために変更する必要はありません。

新しい担当者には Slack の `<@U0123456789>` メンション形式を使います。Issue の作成者、Journal の作成者、Wiki の更新者、Issue 更新見出しの操作者には、自動メンションを付けず名前を表示します。

## Slackメッセージからチケット作成

![Slackメッセージからチケット作成](docs/images/features/message-to-issue.webp)

Slackアプリの **Interactivity & Shortcuts** でInteractivityを有効にし、Request URLを `https://redmine.example.com/slackmine/interactions` に設定します。**メッセージショートカット**を追加し、Callback IDを `slackmine_message_create`、名前を「メッセージからチケットを作成」にします。Botスコープに [`commands`](https://docs.slack.dev/reference/scopes/commands/) を追加し、スコープを変更した場合はアプリを再インストールしてください。[スラッシュコマンド](#スラッシュコマンド)の連携設定を共用するため、`slack.slash_command`、グローバルBot Token、署名シークレット、app/team ID、ユーザー対応付けが必要です。Work Objectプレビューは任意です。

[既存チケットへの接続](#slackの会話スレッドを既存チケットに接続する)も使う場合は、ショートカット名を「メッセージからチケットを作成」と「スレッドを既存チケットに接続」に揃えると、選択したメッセージからの新規作成とスレッド全体の接続を区別できます。

メッセージの「その他のアクション」からショートカットを実行し、プロジェクトを選択します。次のフォームでトラッカー・題名・説明を確認して保存します。最初の空でない行を題名にし、説明には本文と [`chat.getPermalink`](https://docs.slack.dev/reference/methods/chat.getPermalink/) で取得した投稿元リンクを入れます。スレッド返信からも使用できますが、コピーするのは選択したメッセージだけです。通常の本文が空の場合は、Block Kitや添付カードのタイトル・本文・項目からテキストを取り込みます。添付ファイル・スレッド全体・AI要約は取り込みません。Slackの本文の書式記法はそのまま残ります。題名は255文字、説明は投稿元リンクを含め3,000文字までに短縮するため、保存前に確認してください。

候補は、対応付けられたユーザーにチケット作成権限があり、app/team連携が一致する有効なプロジェクトを最大100件表示します。投稿元チャンネルに対応するプロジェクトを先に並べます。次のフォームと保存時にも権限・トラッカーを確認します。メニューを開いたりプロジェクトを選んだりしただけでは作成しません。必須カスタムフィールドがある場合はRedmineの全項目フォームへのリンクを使用しますが、そのリンク先には下書きは引き継ぎません。保存は既存のチケット作成処理を使い、キャッシュによる再送対策と通常の通知が適用されます。

選択した本文は既存の `Rails.cache` に、実行ユーザーとapp/teamに紐付けて30分間保持します。作成フォームに切り替えた後はフォーム内に下書きが保持されます。プロジェクト選択時にキャッシュが期限切れ・消失した場合は、ショートカットを開き直してください。複数Webワーカーでは共有キャッシュまたは同一ワーカーへの振り分けが必要です。追加テーブルやキャッシュサービスは導入しません。フォーム表示・切り替えは同期処理でSlackの3秒制限があるため、配備後に実際のアプリで確認してください。プライベートチャンネルやDMの本文も、他のメンバーが閲覧できるプロジェクトに転記できます。保存前に作成先と内容を確認してください。

## Slackの会話スレッドを既存チケットに接続する

![メッセージメニュー：新規チケット作成と既存チケットへの接続](docs/images/features/message-menu.webp)

メッセージの「…」から **スレッドを既存チケットに接続** を選び、チケット番号（`#`付きも可）またはRedmineのチケットURLを入力します。検索パラメーターやコメント位置（`#note-…`）付きのURLも使えます。「これまでの会話も保存する」は初期値ONです。確認画面で発言ごとに取り込みを外せます。接続を確定すると、過去分は接続した人の名義の1件のコメントにまとめ、発言ごとの投稿者・日時・Slackへのリンクを残します。以後の返信は、対応付けした本人のRedmineユーザー名義でコメント・添付として保存します。

新規作成用のショートカット名は「メッセージからチケットを作成」、この接続用は「スレッドを既存チケットに接続」に揃えます。新規作成は選択したメッセージだけを使い、接続はスレッド全体を対象とします。名前を変更してもCallback IDは変更しません。

同じメニューを再度開くと接続を解除できます。保存済みコメントは残ります。接続時の取り込みに失敗した場合は、スレッドとRedmineの保存結果を確認してから操作し直します。接続後の返信イベントは従来のSlackキューで処理します。確認後に会話が変更された場合は、接続を解除して確認し直してください。解除後に再接続すると新しい確認を行います。過去分を再度選ぶと引用コメントも改めて作られるため、不要なら過去分を外してください。

### Slackアプリ側の作業

1. **Interactivity & Shortcuts** をONにし、Request URLを `https://redmine.example.com/slackmine/interactions` に設定します。既に設定済みならそのまま使います。
2. **Shortcuts → Create New Shortcut → On messages** を選び、次を登録してSave Changesします。
   - Name: `スレッドを既存チケットに接続`
   - Short Description: `会話を既存チケットに接続し、過去の発言と以後の返信を保存します`
   - Callback ID: **`slackmine_thread_connect`**
3. **OAuth & Permissions → Bot Token Scopes** に、使うチャンネルに応じて以下を追加します。

   | スコープ | 用途 |
   | --- | --- |
   | `commands` | メッセージショートカット |
   | `chat:write` | 接続・解除・保存結果の投稿 |
   | `channels:read` / `groups:read` | 公開 / 非公開チャンネル情報・接続する本人の参加確認 |
   | `channels:history` / `groups:history` | 公開 / 非公開スレッド履歴の取得、返信イベント |
   | `users:read` | 引用の投稿者表示、Bot宛て発言の除外 |
   | `files:read` | 添付ファイルの取り込み。ファイル転送を制限している場合は不要 |
   | `users:read.email` | `auto_map_users_by_email` を使う場合のみ必要 |

4. スコープを追加したら **Install / Reinstall to Workspace** を実行します。発行されたBot Tokenが設定と一致することを確認します。
5. **Event Subscriptions** をONにし、Request URLを `https://redmine.example.com/slackmine/events` に設定します。Subscribe to bot eventsに、公開チャンネルなら **`message.channels`**、非公開チャンネルなら **`message.groups`** を登録して保存します。
6. 接続したいチャンネルへBotを招待します。接続先プロジェクトの通知チャンネルと異なる会話も接続できます。DM・グループDMは対象外です。

スラッシュコマンドの追加登録、Options Load URLの設定、Work Objectの有効化は不要です。既に返信取り込みを使っているアプリでは、新しいメッセージショートカットの登録と不足するreadスコープの確認が主な追加作業です。

Slack公式資料: [メッセージショートカットの設定](https://docs.slack.dev/interactivity/implementing-shortcuts/)、[スレッド履歴](https://docs.slack.dev/reference/methods/conversations.replies/)、[チャンネル参加者](https://docs.slack.dev/reference/methods/conversations.members/)。

### Redmine側の作業

コードと設定を配置してRedmineとSidekiqを再起動します。専用テーブル・追加DB・マイグレーションは不要です。接続設定はSlackの署名付きBot投稿、確認情報はSlackのモーダルに保持します。Redmineには通常のコメント・添付だけを保存します。確認送信の重複抑止には既存の `Rails.cache` を使うため、複数Webプロセス間で共有し、`unless_exist` を原子的に扱える設定が必要です。

`config/slackmine.yml` の例:

```yaml
slack:
  thread_connections: true   # 省略時もtrue。falseで接続機能を停止
  bot_token: 'xoxb-REPLACE-ME'
  events:
    app_id: 'A0123456789'
    team_id: 'T0123456789'
    signing_secret: 'REPLACE-ME'

users:
  alice: 'U0123456789'
```

`thread_comments` は既存の「Bot通知スレッド」の取り込み設定です。今回の明示的な接続は `thread_connections` で独立して制御し、`thread_comments: false` でも使えます。プロジェクト単位の `projects.<identifier>.slack.thread_connections: false` にも対応します。

接続先には、全体設定と同じSlack app/team・Bot Tokenを使用するプロジェクトを選びます。明示的な `users` 対応付け、または `auto_map_users_by_email` を設定します。名前だけの照合は編集の認可に使いません。接続する本人にはチケットの閲覧・コメント権限、添付を取り込む場合は添付権限が必要です。以後の返信も投稿者ごとに同じ権限を確認します。非公開チケットは接続できません。

接続ショートカットは待機画面を直接開き、接続状態の確認をSidekiqへ渡します。チケット選択後の履歴確認はWebプロセスで試し、2秒以内なら確認画面をHTTP応答で直接表示します。2秒を超える場合のみ待機画面を返し、画面更新の競合を防ぐため1秒後にSidekiqで履歴確認を続けます。接続・解除と過去分の取り込みは、受付後にSidekiqで実行します。成功時はスレッドの接続・解除投稿、失敗時は本人への通知とログを確認してください。

接続・解除の確認送信は既存の `Rails.cache` で再送を抑止します。処理中・結果不明・成功済みは24時間記録します。接続状態や確認本文の保存先はSlackのままで、キャッシュには処理識別子とマーカーだけを置きます。複数Webプロセスでの抑止には `unless_exist` を原子的に扱える共有キャッシュが必要です。キャッシュの消失や無効化では重複の可能性が残ります。

確認画面の履歴取得はWebで試み、2秒を超えた場合のみジョブへ切り替えます。引用・添付の保存はジョブ側で行います。Webログの `connection preview direct duration_ms` / `connection preview deferred` とSidekiqのジョブ完了時間を確認してください。処理結果が不明な場合は、スレッドとRedmineを確認してから操作し直します。


### 表示と制限

過去分の表示は通常の会話ピックアップと同じカード形式です。同じ投稿者の連続した発言は本文を1改行でつなぎ、投稿者・日時（先頭の発言）・「Open in Slack」を1回だけ表示します。投稿者が変わると別カードになります。A→A→B→Aは順番を保った3枚のカードとなり、離れたAの発言をまとめません。各投稿の元URLは保存データに残し、添付は対応するカードに表示します。この表示はWebとメールの両方に適用され、既に保存した接続前の会話にも反映されます。

- 過去分は親投稿を含む人の発言20件までです。20件を超える場合は「これまでの会話も保存する」を外して接続できます。スレッド全体は1000件までで、不完全な履歴を黙って切り捨てません。全体が1000件を超えるスレッドには接続できません。
- 発言単体・選択した本文合計は10,000文字まで。Slackの確認画面のブロック上限にも従います。
- Bot投稿・Bot宛ての発言は対象外です。過去分の投稿者はRedmineとの対応付けがなくても引用として保存できます。
- 確認中から接続確定までの新しい返信を補完します。イベント受信と重なった返信は二重保存しません。補完期間のスレッド全体が1000件を超えると取り込みを完了できず、解除して確認し直す対象になります。
- 接続後の返信はすぐに保存します。既存通知スレッド用の `thread_comment_batch` は適用しません。
- 添付は既存の取り込み制限に従います。過去分も選択した発言全体で最大10ファイル・合計50 MiBです。画像は引用に関連付け、その他のファイルはダウンロードリンクとして表示します。ファイル転送制限が有効ならダウンロードしません。
- 表示には既存のSlackリンクカードを使います。カード表示OFF時にも、引用は投稿者・日時・リンク・本文を含むテキストとして読めます。
- 確認後に選択した発言の本文・投稿者・添付IDが変わった場合は保存せず、再確認を求めます。引用は確認時点の内容です。Slackでの後からの編集・削除は反映しません。接続を解除しても保存済みコメント・添付は削除しません。
- 接続・解除のBot投稿が接続設定そのものです。削除やSlackの保持期限で失われると状態を復元できません。接続・解除の投稿は残してください。Signing Secretを変更する場合は既存スレッドの接続をやり直してください。
- DBで接続情報を持たないため、返信イベントをキューで受け取り、Slackのスレッド履歴から接続を確認します。通常の通知スレッドでも追加の履歴取得が発生します。
- 1スレッド1チケット。全体の機能OFFまたはプロジェクトの機能OFFでは返信を保存しません。再度ONにしても停止中の全履歴を自動で取り込みません。

### 実機確認

テスト用のチケット・チャンネルで以下を確認します。

1. 親投稿と別の人の返信からショートカットを開き、どちらも同じスレッドになること。
2. 過去分の選択を一つ外し、Redmineで接続した人の1コメントに選んだ発言だけが表示されること。
3. 接続後の返信・画像・ファイルがRedmineで本人名義・正しい添付表示になり、受信メールでも投稿者・本文・添付・リンクの順序が自然なこと。
4. 確認中に追加した返信が一度だけ保存されること。
5. 再試行で過去分が二重保存されず、解除後の返信・遅延ジョブが保存されないこと。
6. 権限のないユーザー、非公開チケット、異なるapp/team/tokenのプロジェクトに接続できないこと。

接続機能のテストはSlack APIとRedmineのモデル操作をスタブ化し、追加DBなしで実行します。

```sh
ruby -Itest test/thread_connections_test.rb
```

スタブテストはSlack/Redmineの実機表示や本番配信の確認を代替しません。

## App Homeのチケット一覧

![App Homeのチケット一覧](docs/images/features/app-home.webp)

一覧は5列の表で、題名リンク（その下にプロジェクト）、ステータス、担当者、期日、編集ボタンを表示します。題名は最大200文字でブラウザーを開き、編集ボタンは権限に応じたSlack内のフォームを開きます。区分ごとの見出しは1つにし、最大10件を5件ずつ表示します。列幅とモバイルでの描画はSlackが決定します。区分の文言は `messages.app_home`、属性のラベルは `messages.fields`、編集ボタンは `messages.work_objects.edit_issue` で変更できます。ホームを開き直しても、最後に選んだフィルターを引き継ぎます。

Slackのアプリ一覧からこのアプリを開き、**ホーム**タブで「更新したチケット」「今週期限のチケット」「担当しているチケット」「報告したチケット」の順に表示します。各一覧だけへの切り替えもできます。各区分は最大10件で、11件以上は `10+` と表示します。複数の条件に該当するチケットは各区分に表示します。

Redmineの標準 `IssueQuery` を使い、未完了・有効なプロジェクト・本人の閲覧権限を条件にします。「更新した」は自分の閲覧可能な更新履歴が一度でもあるチケットで、更新日時が新しい順です。「今週期限」は本人または所属グループが担当する今週全体のチケットで、プロジェクト順です。今週の過ぎた期日も含め、週の区切りはRedmineの設定に従います。「担当している」は本人または所属グループが担当するチケットで、優先度の高い順、次に更新日時が新しい順です。「報告した」は自分が作成したチケットで、更新日時が新しい順です。


1. 全体の `slack.app_home: true` を設定し、全体の `slack.bot_token` と `slack.events` のアプリID・チームID・Signing Secretを設定します。
2. Slackアプリの **App Home → Show Tabs → Home Tab** を有効にします。
3. **Event Subscriptions → Subscribe to bot events** に [`app_home_opened`](https://docs.slack.dev/reference/events/app_home_opened/) を追加します。Request URLは既存の `/slackmine/events` を使います。
4. Redmineユーザーとの対応付けを設定し、RedmineとSidekiqを再起動します。

ホームを開いたとき、表示を切り替えたとき、「更新」を押したときに取得します。チケット変更後も、このホームから保存した場合は一覧を更新します。他の場所での更新は次の取得時に反映します。追加の定期ジョブやDB変更はありません。

閲覧可能で有効なプロジェクトのチケットだけを表示します。共有アプリと異なるアプリ／チームのプロジェクト、`slack.app_home: false` のプロジェクト、共有設定と異なるRedmineユーザーに対応付けられるプロジェクトは除外します。プロジェクトだけに設定した別アプリのホームには対応しません。未対応付けのユーザーには案内だけを表示します。

編集ボタンはチケットへのリンクと、許可された編集フォームを表示します。編集には既存の `work_object_previews`、`work_object_actions`、`work_object_buttons` の設定とRedmineの権限・ワークフローを適用します。編集不可の場合は閲覧用の画面です。プライベートチケットは本人が閲覧可能な場合に一覧へ表示しますが、Slackからの編集は既存の制限に従い無効です。文言は `messages.app_home`（設定例参照）で変更できます。

## スラッシュコマンド

![スラッシュコマンド](docs/images/features/slash-commands.webp)

`slack.slash_command: /slackmine` を設定し、Slackアプリに同名のコマンドを登録します。省略すると無効です。Request URLは `https://redmine.example.com/slackmine/commands`。[`commands`](https://docs.slack.dev/reference/scopes/commands/) スコープを追加してアプリを再インストールしてください。Interactivityは `/slackmine/interactions` を使用します。既存の署名シークレット、app/team ID、Bot Token、ユーザー対応付けも必要です。グローバルの連携設定・ユーザー対応付けを使用し、同じ連携に属するプロジェクトだけを対象にします。

追加テーブル・DBマイグレーションは不要です。フォーム送信・値指定コマンドの再送対策には既存の `Rails.cache` を使用し、処理中は5分、成功済みは24時間記録します。入力エラー時は記録を解除し、修正後に再送できます。例外時は保存結果が不明な可能性があるため、短時間の処理中記録を残します。DB保存とキャッシュ更新は一体ではないため、キャッシュ消失・期限切れ・プロセス内のみのキャッシュ・保存直後の異常終了では重複の可能性が残ります。値指定コマンドはサーバーで生成したリクエスト識別子を使用し、Slackへの応答前に結果を記録するため、配信の再試行では保存済みの結果を再利用します。複数Web・コマンド処理プロセス間の抑止には、`unless_exist` を原子的に扱える共有キャッシュが必要です。プラグインから新しいキャッシュサービスを導入することはありません。

| コマンド | 動作 |
| --- | --- |
| `/slackmine` / `/slackmine help` | 使い方と自分の課題・期限・リマインダー・新規作成ボタン |
| `/slackmine 123` / `/slackmine #123` | 設定済みならWork Objectカード、未設定ならリンク・状態・コメント追加ボタン |
| `/slackmine my` | 自分に直接割り当てられた未完了課題 |
| `/slackmine due` | 自分の期限超過・3日以内が期日の課題 |
| `/slackmine reminders` | 定期リマインダーの設定で、自分の期日一覧を今すぐ取得 |
| `/slackmine キーワード` または `/slackmine search キーワード` | 題名の部分一致検索（大文字小文字を区別しない） |
| `/slackmine new [プロジェクト識別子]` | プロジェクト選択後、トラッカー・題名・説明の作成フォーム |
| `/slackmine comment 123` | コメントフォームを開くボタン |
| `/slackmine status 123 [ステータス名またはID]` | 値を指定するとジョブで変更、省略すると選択フォームを開くボタン |
| `/slackmine assign 123 [ログイン名・表示名・ID]` | 値を指定するとジョブで変更、省略すると担当者の選択フォームを開くボタン |

`status`・`assign` は `#123` も受け付けます。値を省略した場合は、返されたボタンから選択フォームを開き、送信して初めて変更を保存します。`/slackmine status 123 終了` や `/slackmine assign 123 alice` のように値を指定すると、保存をジョブへ渡し、結果を本人だけに返します。名前は大文字小文字を区別しない完全一致で、許可された候補を1件に特定できる必要があります。空白を含む名前も引用符なしで指定できます。名前が重複する場合はIDを使ってください。担当者は `me`（自分）、`none`・設定した未割当ラベルも指定できます。不明・重複・許可されない値では変更せず、選択フォームを開くボタンを返します。`/slackmine` は設定した `slack.slash_command` に置き換えてください。`slack.work_object_actions: true`、有効なRedmineユーザーへの対応付け、同じ連携に属する公開課題、対象項目の編集権限が必要です。この2つのコマンドにはWork Objectプレビューの有効化は不要です。ステータスは実行者のRedmineワークフローで許可された候補、担当者はRedmineで割当可能なユーザーと「未割当」を表示します。担当者は最大99人、ステータスは最大100件で、フォームを開けない場合はRedmineの課題編集画面を使用してください。保存時にも連携・権限・ワークフロー・割当候補を再確認し、既存の課題行ロック内で更新します。現在と同じ値を選んだ場合は履歴を追加せずフォームを閉じます。Slack側のコマンド追加登録やスコープ追加は不要です。 値指定による変更の成功時・値が同じ場合は、プレビュー設定済みなら最新のWork Objectカードを返し、既存の表示項目・ボタン設定を使います。プレビュー未設定では文字の確認応答を返します。配信前に結果を記録するため、再送時に変更やカード生成を繰り返しません。

結果は実行した本人だけに表示します。番号指定、または `my`・`due`・`search` の結果が1件の場合、対象プロジェクトの `slack.work_object_previews: true` が有効でコマンドと同じBot Tokenを使用していれば、自動でWork Objectカードを表示します。項目・ボタンは既存のYAML設定に従い、新たな切替設定は不要です。未設定や非公開課題では簡易表示を使います。 本人だけに表示するカードのボタン押下では、Slackが課題URLと参照情報を省略する場合があるため、操作ボタンに課題IDを持たせています。自分のRedmineで課題を特定したうえで、連携・閲覧・編集権限を通常どおり確認します。本人だけに表示するカードからも、権限で許可されたステータス・優先度・担当者・期日・コメントの編集フォームを開けます。このカードは [`chat.update`](https://docs.slack.dev/reference/methods/chat.update/) で更新できないため、保存後は番号指定で再取得してください。複数件の課題一覧はリマインダーと同じ色付き添付・件数見出し・箇条書きに統一し、チケットリンク・プロジェクト名・期日までの相対日数を表示します。期日なしでは日数を省略します。並び順は維持し、各行のボタンは表示しません。行の書式は `messages.due_reminders`、見出しは `messages.commands.my`・`.due`・`.search` を使います。コメント操作は `/slackmine 123` または `/slackmine comment 123` から行えます。一覧は最大100件の候補から10件、プロジェクトは最大20件を表示し、現在のチャンネルに対応するプロジェクトを優先します。プロジェクト識別子で絞り込めます。閲覧権限を確認し、保存時にも権限とRedmineの検証を再確認します。必須カスタムフィールドは簡易作成フォームでは入力できないため、フォーム内のRedmineへのリンクから登録してください。コメント追加には `work_object_actions: true` が必要で、既存の公開課題編集ポリシーに従います。保存後は通常のRedmine通知処理が動きます。チャンネルへ共有する操作は追加していません。

`/slackmine reminders` は定期実行と同じ抽出・表示処理を使います。自分が直接担当する未完了課題のうち、閲覧権限、`due_reminders.enabled`、全体・プロジェクト別の `due_reminders.days` を満たすものが対象です。期限超過・今日・近日の一覧を実行した会話で本人だけに返し、0件でも応答します。100件ずつに分割し、現在のapp/teamと本人のSlack対応付けに一致する課題に限定します。全員向けcronの起動やスケジュール変更は行いません。`due` の固定3日・最大10件とは異なり、設定した期間で全件を返します。表示は既存の `messages.due_reminders` と色設定を使用し、ボタン名と0件時の文言は `messages.commands` で変更できます。Slack側のコマンド追加登録・スコープ追加・DBテーブル追加は不要です。

表示文言はexampleの `messages.commands` で変更できます。`messages.commands.help` は複数行のコマンド一覧で、`%{command}` を `slack.slash_command` に置換します。既存YAMLで `help` を上書きしている場合は、その値を更新するか削除すると新しい既定文を利用できます。スラッシュコマンドはスレッド内では使えません。既存のスレッド返信連携を使用してください。検索・一覧・リマインダー配信はSidekiqで処理します。フォームはボタンを押したときに直接開きます。短い保存は直接処理し、Slackリンクを含む新規作成・コメントは引用の取得をジョブで行い、結果を本人のSlackアプリのメッセージ欄へ送ります。この通知を使うにはSlackアプリのApp HomeでMessagesタブを有効にしてください。

## 毎日の期日リマインダー DM

![毎日の期日リマインダー DM](docs/images/features/due-reminders.webp)

Redmine アプリケーションのタイムゾーンに合わせて、タスクを 1 日 1 回実行します。タスクは `slack` キューにジョブを登録し、ワーカーが DM を送ります。

```bash
cd /path/to/slackmine
bundle exec rake slackmine:due_reminders RAILS_ENV=production
```

Redmine の運用環境で使用しているスケジューラーに、このタスクを 1 日 1 回登録してください。同じ日に再実行した場合も、その都度リマインダーが送られます。

Slack が `cannot_dm_bot` で拒否した宛先はスキップし、Redmine と Slack のユーザーIDを警告ログに記録します。ほかの宛先への期限通知は継続します。それ以外の API エラーはジョブの失敗として扱います。

cron から実行する場合は、先に Redmine のディレクトリへ移動する小さなスクリプトにコマンドを記述します。

```sh
#!/bin/sh
cd /path/to/slackmine || exit 1
bundle exec rake slackmine:due_reminders days=7 RAILS_ENV=production
```

Redmine 標準のリマインダーコマンドと同じ絞り込みオプションを Rake の環境引数として指定できます。省略した条件では対象を絞り込みません。

| オプション | 内容 |
| --- | --- |
| `days` | 期日の何日前から通知するか。指定するとプロジェクト別設定を含む YAML の `due_reminders.days` より優先します。省略時は YAML の設定を使います（初期値: 3 日）。 |
| `tracker` | トラッカー ID。 |
| `project` | プロジェクトの ID または識別子。 |
| `users` | 担当 Issue を通知する Redmine ユーザー ID のカンマ区切り。 |
| `version` | 対象バージョン名。Redmine と同様に大文字・小文字を区別せず照合します。 |

たとえば、ユーザー 3 と 5 だけに絞る場合、またはすべての条件を組み合わせる場合は次のように実行します。

```bash
bundle exec rake slackmine:due_reminders users=3,5 RAILS_ENV=production
bundle exec rake slackmine:due_reminders days=7 tracker=2 project=example users=3,5 version="1.0" RAILS_ENV=production
```

指定したすべての条件に一致する Issue だけを対象にし、ワーカーも送信前に条件と担当者を再確認します。値が無効な場合や指定したユーザー・トラッカー・プロジェクト・バージョンが存在しない場合は、ジョブを登録する前に停止します。同じ日に既に通知した Issue も、実行のたびに再送されます。

初期状態では、担当者がいる未完了の Issue を、期日の **3 日前から**期限超過後も毎日、Redmine のステータスが**終了**になるまで通知します。ワーカーは担当者ごとにコンパクトな DM を 1 通送り、リンク付き Issue を期限超過・本日期日・期日が近い課題の見出しでまとめます。各グループの色は独立しており、初期値は期限超過が赤、本日期日がオレンジ、期日が近い課題には設定済みの attachment 色を使います。Issue 行には日付を繰り返さず相対日数を示し、本日期日の見出しが日付の文脈を示します。100 件を超える場合は番号付きの複数メッセージに分割します。Bot Token または Slack ユーザーの対応付けが異なると、アプリごとに別の DM に分かれます。同じ日にタスクを再実行しても、その時点で対象となる Issue を送ります。

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

`due_reminders.colors.overdue`、`.today`、`.upcoming` には 6 桁の 16 進カラーコードを指定します。無効または省略した値は初期値を使います。`upcoming` を省略した場合は `slack.attachment_color` を使います。色は `projects.<identifier>.due_reminders.colors` でプロジェクトごとに上書きできます。

担当者は、Issue を閲覧できる有効な Redmine ユーザーであり、`users` または `slack.auto_map_users_by_name` で Slack ユーザーに対応付けられている必要があります。グループ担当者と対応付けのないユーザーはスキップし、ログに記録します。Redmine で担当者に閲覧権限がある場合は、非公開 Issue も本人への DM に含められます。DM 配信には [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) と [`im:write`](https://docs.slack.dev/reference/scopes/im.write/) を持つ Bot Token が必要です。プロジェクトのチャンネル ID は使いません。Slack アプリの設定で **App Home → Messages Tab → Display Messages tab** を有効にしてください。有効にしていないと、[`conversations.open`](https://docs.slack.dev/reference/methods/conversations.open/) が成功しても Slack が [`messages_tab_disabled`](https://docs.slack.dev/reference/methods/conversations.open/#errors) を返します。スコープを追加した場合はアプリを再インストールしてください。スケジュールに依存する前に、テスト用の Issue が受信者の Slack DM に表示されることを確認してください。

DM の文言は `slackmine.messages.yml` の `messages.due_reminders` 以下で変更できます。[文言の設定例](config/slackmine.messages.yml.example)にすべてのキーとプレースホルダーを掲載しています。たとえば、他のグループを変更せずに見出しと期限超過グループのラベルを変更できます。

```yaml
messages:
  due_reminders:
    title: '📋 *Due reminders: %{count}%{suffix}*'
    overdue_label: '🚨 Overdue'
```

同じキーを `projects.<identifier>.messages.due_reminders` 以下でプロジェクトごとに上書きできます。

## 個人ごとの通知メール設定

![個人ごとの通知メール設定](docs/images/features/email-preference.webp)

**個人設定 → メール通知**の「自分自身による変更の通知は不要」の下で、「Slackで通知する内容のメールを停止」を有効にできます（初期値OFF）。既存のRedmineユーザー設定に保存するため、DBマイグレーションは不要です。

対象はIssue作成・変更・コメント、Wiki作成・更新、News作成・コメント、文書追加、プロジェクト／バージョン／文書のファイル追加、フォーラム投稿です。Issue更新では、Redmineのメール通知設定でONにした発生条件だけを判定します。「チケットの更新」がOFFで「コメントの追加」がONなら、同時に関連付けや期日を変更しても、それらのSlack設定はコメントのメール抑制を妨げません。「チケットの更新」がONなら閲覧可能な変更すべてを判定します。該当するメール発生条件すべてのSlackイベントが有効で、そのプロジェクトのBot Tokenと通知先チャンネルが決まり、対応する本人のSlackアカウントが通知先に参加している場合に停止します。`users`でのログイン名／メールアドレスの明示的な対応付けを優先します。対応付けがなければ、`slack.auto_map_users_by_name: true`による一意の名前マッチングを使い、その都度取得したSlackプロフィールのメールアドレスが本人のRedmineの主メールアドレスと一致することも確認します（大文字・小文字は区別しません）。不正な明示的対応付けがある場合は自動マッチングに切り替えません。通知先は既存のプロジェクト・親プロジェクト・デフォルトの探索を使います。非公開Issue・非公開コメント、対象外の通知、アカウント・セキュリティ関連メールは通常どおりです。

参加確認は[`conversations.members`](https://docs.slack.dev/reference/methods/conversations.members/)で同期的に行い、参加済みという結果はキャッシュしません。公開チャンネルは[`channels:read`](https://docs.slack.dev/reference/scopes/channels.read/)、非公開チャンネルは[`groups:read`](https://docs.slack.dev/reference/scopes/groups.read/)が必要です。名前の自動マッチングには[`users:read`](https://docs.slack.dev/reference/scopes/users.read/)と[`users:read.email`](https://docs.slack.dev/reference/scopes/users.read.email/)も必要です。メールアドレスの欠落・不一致、無効なアカウント・ボット・別ワークスペースのアカウント、曖昧な名前、照合失敗時はメールを残します。本人確認はメールごとに行い、プロフィールのメールアドレスはキャッシュしません。スコープ追加後はアプリを再インストールしてください。設定・対応付けの不足、未参加、APIエラー、不正な応答、ページ取得を完了できない場合はメールを残します。取得は1ページ200人、最大10ページで、各リクエストの接続タイムアウトは2秒、読み取りタイムアウトは3秒です。

確認するのは通知設定と参加状況であり、**Slackへの配信成功ではありません**。配信結果を調整するジョブは追加しません。後からSlackへの投稿が失敗しても、停止したメールを代わりに送る処理はありません。Redmineの既存のメール通知選択は変更せず、チェックを外すとその選択に従った通知に戻ります。

## 管理画面の設定・対応一覧

![Slackmine管理画面：設定値とSidekiqタスク](docs/images/features/administration.webp)

キュー監視・実行履歴・テスト通知は、**ActiveJobがSidekiqを使用している場合のみ利用できます**。他の処理方式では通常通知の動作を維持し、キュー・履歴は取得できない旨を表示してテスト通知ボタンを無効にします。**キュー・タスク**タブで待機中・実行中・予約・リトライ・再試行終了を確認できます。追加後のSlackmine実行履歴を直近100件・最大7日分保存します。追加前の完了履歴は復元できません。履歴は既存のSidekiq用Redis/Valkeyの `slackmine:admin:job_history:v1` に保存し、RedmineのDBテーブルは追加しません。保存対象はジョブ名・ID・結果・時刻・処理時間・例外クラスのみで、引数・メッセージ本文・認証情報は保存しません。プロジェクト選択はテスト通知先に適用し、タスク表示はSlackmine全体を対象にします。通常ジョブの完了は配信確認を保証しません。管理者用テスト通知ボタンは表示中の通知先へ1件を同じslackキューで送信し、送信前に通知先が変わっていないことを確認します。Sidekiqと有効なBot・通知先設定が必要です。各ジョブ集合は先頭500件まで確認し、上限超過を画面に表示します。

管理画面のラベル・解説は `config/locales/slackmine_admin.ja.yml` と `config/locales/slackmine_admin.en.yml` に分離し、Redmine の表示言語に従います。Slack の通知文言を設定する `slackmine.messages.yml` とは別です。

管理者は **管理 → Slackmine**（`/admin/slackmine`）から、読み込み済みの設定値と各キーの解説、プロジェクトと通知先チャンネル、有効なユーザーの Slack メンション先を確認できます。設定値とメンションはプロジェクトを選択すると、そのプロジェクトの上書きを反映します。 プロジェクト一覧は状態で絞り込め、初期表示はアクティブのみです。設定表は設定キーとグレーの解説を同じ列にまとめ、右側にデフォルト値・現在値を表示し、コードの省略時の既定値と異なる現在値を、複数行も含めて太字で表示します。有効なカラーコードには小さな正方形の色見本を付け、イベントごとの実効色は独立した一覧に表示します。「変更ありのみ表示」で絞り込めます。条件に依存する既定値は具体的な値と適用条件を表示し、単一の値とは比較しません。通知先は既存の親プロジェクト継承・自動照合を、メンションは通知と同じログイン名・メールアドレスの対応と名前による自動照合を使います。ユーザー一覧は「対応あり」を初期表示とし、「対応なし」「すべて」に切り替えられます。プロジェクト選択時はそのプロジェクトに所属する有効なユーザーに絞ります。絞り込み後の一覧を50件ずつ表示し、有効な Redmine アカウントがない設定済み対応も別途表示します。

設定・対応一覧は閲覧専用で、テスト通知は管理者の明示操作で送信します。認証情報は環境変数の優先順位を反映した Bot Token を含めてマスクします。表示文言には組み込みの既定値と文言用ファイルを反映します。省略した動作設定はコードの既定値を使い、一覧には表示しません。自動照合では Slack API の読み取りが発生する場合があり、キャッシュは最大10分です。通知先一覧はイベントの有効・無効や配信成功を判定しません。実設定ファイルが見つからない場合は画面に表示し、未対応や英語の既定文言と区別できます。設定ファイル変更後は Web・ワーカープロセスを再起動してください。

## 配信と運用

`SlackmineNotificationJob` は Redmine のイベント後、ActiveJob の `slack` キューに登録されます。Sidekiq を使う場合は、たとえば次のようにキューを設定します。

```yaml
:queues:
  - default
  - mailers
  - slack
```

Slack API の失敗はログに記録され、Sidekiq が再試行します。Redmine の操作はロールバックされません。通知の投稿に成功した後、一時的な画像プレビューの削除に失敗した場合は、重複投稿を避けるため、エラーを記録するだけでジョブを再試行しません。通知が届かない場合は、`SlackmineNotificationJob` と `Slackmine` のログを確認してください。

開発環境では、ActiveJob の inline アダプターを使えば Sidekiq なしで実行できます。

```ruby
config.active_job.queue_adapter = :inline
```

inline 配信は Redmine のリクエスト中に実行されるため、Slack の応答が遅いとリクエスト時間が延びます。本番環境では `slack` キューを処理するワーカーを使ってください。

通知が届かない場合は、次の順に確認します。

1. 対象イベントのキーと親スイッチが、全体設定とプロジェクト設定で有効になっているか。
2. 実行中の Redmine と Sidekiq が意図した Token を使っているか。`SLACK_BOT_TOKEN` は YAML より優先されます。
3. プロジェクト識別子が意図したチャンネルに対応しているか、またはデフォルトのチャンネルが設定されているか。ボットがチャンネルに参加しているか。
4. Bot Token に [`chat:write`](https://docs.slack.dev/reference/scopes/chat.write/) があり、オプション機能に応じて [`files:write`](https://docs.slack.dev/reference/scopes/files.write/) または [`users:read`](https://docs.slack.dev/reference/scopes/users.read/) があるか。スコープの追加後にアプリを再インストールしたか。
5. Sidekiq が `slack` キューを処理しているか。ログでジョブと Slack API のエラーコードを確認してください。

YAML を変更した場合は Redmine と Sidekiq の両方を再起動してください。ジョブの投稿成功は API への配信を示します。実際の表示や画像は通知先のチャンネルで確認してください。既存のメッセージは更新されません。

## Redmine本文内のSlackリンクカード

カード用CSSはRedmine全体で読み込み、活動欄・エディターのプレビュー・チケットのクイックプレビューでも、詳細ページと同じ控えめな枠線を表示します。

`slack.link_cards.enabled: false` でSlackリンク本文の取得・新しい引用の保存・Redmine画面とメールのカード表示をまとめてOFFにできます。既存の保存済み引用は削除せず、通常のテキストとして表示します。

`slack.link_cards.redmine_enabled: false` はRedmine画面のカード表示と未保存リンクのライブプレビューだけをOFFにします。リンク保存時の本文取得・引用保存とメールのカード表示は継続します。メールだけOFFにする場合は既存の `mail_enabled: false` を使います。3項目とも省略時は `true` で、現在の動作を維持します。`projects.<identifier>.slack.link_cards` で個別に上書きできます。

説明・コメントの編集プレビューでも、入力中の保存済み引用を同じカード形式で表示します。保存済み引用にはSlack APIを呼び出さず、URLだけを入力した場合は権限確認後にSlack本文を取得してカード表示します。取得できないURLは通常のリンクのままです。プレビューでは引用を保存しません。

![Redmine本文内のSlackリンクカード](docs/images/features/slack-link-cards.webp)

チケットの説明・コメントに `https://example.slack.com/archives/C123/p1791115675755579` 形式のURLを貼って新規作成・編集すると、Slack本文を取得し、**既存の説明・コメント欄に引用を追記して保存**します。DBマイグレーション・専用テーブル・索引・バックグラウンドジョブは追加しません。引用本文と名前解決済みのメンションは検索可能な文字として保存し、カードの情報は区切り付きのブロックに保持します。元のURL・本文は維持します。引用は保存時点の内容で、Slack側の編集・削除では変わりません。同じ投稿への複数URL（クエリ違いを含む）や再保存でも引用を重複追加しません。コードブロック・インラインコードはRedmineのMarkdown・Textile整形結果に従って除外します。取得できない場合は元の本文のまま保存します。

保存済みカードは元のURLの位置に表示し、カード内の「Slack ↗」から投稿を開けます。コメントの編集直後（Ajax更新）とページの再読み込み後で同じ表示になり、複数のリンクの順序や間に書いた文章を保ちます。カード前後の余分な改行と引用移動後の空段落は取り除き、本文中の通常の改行は維持します。元のURLが削除された場合は、保存済み引用の位置で表示します。保存済みの引用はRuby側でカードにし、閲覧時のJavaScriptやSlack API呼び出しは不要です。引用本文はSlack書式として安全に整形し、Redmineマクロや生HTMLとして実行しません。テキストの通知メール・Slack通知には保存用マーカーを出さず、読める引用を表示します。既存の未取り込みリンクは説明・コメントを変更して保存するまで従来のライブプレビューを維持し、一括で既存レコードを変更しません。保存済みの引用をコピーした場合は、その時点の内容を維持します。

左側の線の色は次のYAMLで指定します。`projects.<識別子>.slack.link_cards` でプロジェクト別に上書きできます。

```yaml
slack:
  link_cards:
    enabled: true
    redmine_enabled: true
    mail_enabled: true
    color: '#6D5DFB'
```

6桁の16進カラーのみ受け付け、省略・不正な値では `#6D5DFB` を使います。返信カードには「スレッドへの返信」、取得できた親投稿の短いプレビュー、親投稿へのリンクを表示します。親投稿には返信件数を表示します。リンクの `thread_ts` と投稿のメタデータから返信を判定し、選択した投稿と親投稿だけを取得します。スレッド全体は取り込みません。ユーザー・チャンネルへのメンションは名前を解決し、失敗時は元のラベルやIDを残します。Botのプロフィールがない場合は [`bots.info`](https://docs.slack.dev/reference/methods/bots.info/) を試します。

リンク本文の自動取得には、操作したRedmineユーザーと一致する有効なSlackアカウントの対応付けと、チャンネル参加の確認が必要です。対象は共有されていない公開・非公開チャンネルで、本人とBotの両方の参加を確認します。DM・グループDM・Slack Connect・権限確認に失敗したURLは通常のリンクのままにします。Botにも参加と履歴・チャンネル情報の閲覧権限が必要です。非公開チャンネルの取得には `groups:history` と `groups:read` が必要です。参加者の確認には `conversations.members` 用の `channels:read`（公開）または `groups:read`（非公開）を使い、ワークスペースとURLのホストも照合します。**取得対象のチャンネル投稿を保存すると、本文はチケット・コメントの読者、API利用者、メール受信者に共有されます。** 確認画面を経由して意図的に転記するスレッド接続は、既存の参加確認・転記先権限確認を維持します。

新規の保存済み引用には、Railsアプリケーションの鍵から用途別に導出したHMAC署名を付け、本文とメタデータの改ざんを検証します。旧形式の署名なし引用・改変された引用・別のアプリケーションや鍵で作成された引用は、発言者・チャンネルの帰属情報、添付との関連付け、アバターを除外した**未検証のテキスト**として表示します。既存本文の削除や自動署名は行いません。引用本文を編集しても、元URLから原文を再取得して別のカードを追加しません。再取得する場合は既存の引用ブロックを削除してからURLを保存します。アバターURLはメール内画像と共通のSlack・Gravatar許可リストに制限します。Railsアプリケーションの秘密鍵を変更すると、既存署名は無効になります。

`slack.link_cards.sign_quotes`（新規引用への署名付与）と `slack.link_cards.verify_signatures`（保存済み引用の署名検証）は独立した設定で、どちらも既定は `true` です。それぞれ `false` でOffにできます。署名Off・検証Onでは、新しく保存した未署名引用が「未検証」と表示されます。検証Offでは未署名・改変された引用も投稿者情報付きで表示します。署名設定の変更で既存の引用は書き換えません。メタデータの形式検査、アバターURL制限、Slack取得時の権限確認は維持します。両設定ともプロジェクト別に上書きでき、変更後はWebとワーカーを再起動してください。

```yaml
slack:
  link_cards:
    sign_quotes: true
    verify_signatures: true
```

管理者が原文から変更されていないと確認した過去の未署名引用は、専用タスクで署名できます。この明示的な署名タスクは `sign_quotes` の設定によらず署名します。Slackから再取得せず保存済み本文とメタデータを使うため、内容の真正性は実行者が確認してください。

```sh
# 件数確認（書き込みなし）
bundle exec rake slackmine:sign_legacy_quotes RAILS_ENV=production
# 新規バックアップファイルを指定して適用
bundle exec rake slackmine:sign_legacy_quotes apply=true backup=/secure/path/legacy-quotes.jsonl RAILS_ENV=production
```

全チケットの説明とコメントが対象です。更新前後の本文を権限 `0600` のJSONLファイルにバックアップし、引用本文・投稿者情報・更新日時を保持して署名だけを追加します。通知や追加履歴は発生しません。既存署名付きの引用は変更せず、形式不正の引用は `invalid` として数えて除外します。再実行しても署名済み引用は変更しません。

本文はSlackの [`mrkdwn`](https://docs.slack.dev/messaging/formatting-message-text/)（太字・斜体・取り消し線・リンク・引用・コード）と基本的なMarkdownの見出し・リスト・太字・リンクを整形します。標準絵文字の名前はUnicodeに変換し、独自絵文字は `:名前:` のまま残します。生HTMLは実行せず文字として表示し、リンク先はHTTP・HTTPS・mailtoに限定します。返信は履歴で取得できない場合 [`conversations.replies`](https://docs.slack.dev/reference/methods/conversations.replies/) を試しますが、APIの制約や失敗で取得できない場合はリンク表示になります。添付ファイルは取り込みません。

1回の保存で最大20件のリンクを候補にし、API呼び出し開始には5秒の予算と短い通信タイムアウトを設けています。制限を超えたリンクは通常表示のままです。同一取り込み中のみBot Token別にAPI結果を再利用します。既存のライブプレビューにも同じ取得制限があります。引用は元の本文欄に保存し、共有HTMLキャッシュは使いません。保存された本文の閲覧・検索結果には、通常のチケット・非公開コメント権限が適用されます。**保存した引用はRedmineの既存の説明・コメント検索で検索可能です。**「タイトルのみ」の検索では本文は対象外なので解除してください。専用の検索索引は不要です。未取り込みの古いリンクは、取り込むまでSlack本文の言葉では検索できません。引用は本文の編集で変更・削除でき、元のURLだけを消しても保存済み引用は残ります。保存した本文の変更には、通常のRedmine通知・変更履歴が適用されます。

## プライバシーと開発

共有通知では、操作ユーザーの権限や表示設定に関係なく、ロールで閲覧を制限したカスタムフィールドとその変更前後の値を除外します。関連チケットの件名は、同じプロジェクトの非公開でないチケットに限ります。ワーカーは送信直前に、現在のチケット・コメントの非公開状態、所属プロジェクトと稼働状態、通知対象フィールド・関連先の公開状態、投入時の送信先・Tokenとの一致を再確認し、変更があれば通知を中止します。この確認情報がない更新前の待機ジョブは送信しません。導入時はWebとワーカーをまとめて再起動してください。送信済みの投稿や転記済みの本文は撤回されません。DM検索は本人のRedmine閲覧権限で絞り込み、返却する各チケットでも再確認します。

チャンネル通知では、非公開 Issue と非公開 Journal のコメントを除外します。毎日の DM には、担当者が Redmine で閲覧できる非公開 Issue を含められます。非公開 Issue や非公開コメントの画像はアップロードしません。実際の `slackmine.yml` をコミットしたり、Bot Token をログ・設定例・サポート依頼に載せたりしないでください。Token が漏れた場合は更新してください。

ローカルのテストスイートは次のコマンドで実行できます。

```bash
ruby -Itest test/image_notification_test.rb
ruby -Itest test/security_regressions_test.rb
ruby -Itest test/standard_notifications_test.rb
ruby -Itest test/slack_events_controller_test.rb
ruby -Itest test/slash_commands_cache_test.rb
ruby -Itest test/slash_commands_edit_test.rb
ruby -Itest test/app_home_test.rb
ruby -Itest test/thread_images_test.rb
ruby -Itest test/thread_comment_feedback_cleanup_test.rb
```

テストはスタブを使って通知の整形と配信ロジックを確認します。追加の `ruby -Itest test/thread_comments_persistence_test.rb` は ActiveRecord と sqlite3 が利用できる環境で実行し、メモリ内のテスト用チケット・コメントテーブルで保存、重複抑制、権限拒否、通知ループ抑制を確認します。追加の `ruby -Itest test/notification_transactions_test.rb` は ActiveRecord と sqlite3 のある環境で別プロセスで実行し、Issue削除と汎用通知モデルのcommit・rollbackを確認します。対応表と実環境での未確認事項は [通知監査](#通知の対応範囲と検証) を参照してください。本番DBやRedisへ接続せず、Slackへの投稿や稼働中のRedmine環境も検証しません。

管理画面の設定・一覧取得は `ruby -Itest test/admin_controller_test.rb`、ERB描画とHTMLエスケープは ActionView が利用できる環境で `ruby -Itest test/admin_view_test.rb` により検証できます。稼働中の Redmine 7 管理画面を検証するものではありません。

キュー監視・履歴の保存上限・テスト通知先の検証は `ruby -Itest test/job_monitor_test.rb` で確認できます。テスト用アダプターを使用し、実際のSlack送信は行いません。

## 通知の対応範囲と検証

以下は実装・設定・整形の対応表と自動テストの検証範囲です。Slackへの表示・SMTPでの配信は、実環境で別途確認します。

| 対象 | 通知 | 本文編集時の表示 | 標準メールの抑制対象 |
| --- | --- | --- | --- |
| チケット | 作成・削除、履歴の属性・関連・添付・親子変更 | `body_diff.issue.description` | 作成と有効なRedmine履歴メールの通知条件 |
| チケットコメント | 追加・編集・削除 | `body_diff.issue.comment`。削除時は削除行を表示 | 新規コメントのみ。編集・削除ではメール処理を追加しない |
| Wiki | 作成・本文／編集コメントの更新・削除 | `body_diff.wiki.body` | 作成・更新 |
| ニュース | 作成・更新・削除 | `body_diff.news.description` | 作成 |
| ニュースコメント | 追加・本文編集・削除 | `body_diff.news.comment`。削除時は削除行を表示 | 追加 |
| 文書 | 作成・題名／説明／カテゴリの編集・削除 | `body_diff.document.description` | 作成 |
| プロジェクト／バージョンのファイル | 追加・ファイル名／説明／Content-Type／ダイジェストの編集・削除 | 説明本文。生成した本文差分は使わない | 追加 |
| 文書の添付 | 追加・編集・削除 | ファイルと共通の整形・文言・アイコン・メタデータ | 追加 |
| フォーラムのトピック／返信 | 投稿・件名／本文／固定／ロックの編集・削除 | `body_diff.message.body` | 投稿 |
| 作業時間 | 作成・更新・削除 | 現在のコメント本文。生成した本文差分は使わない | 標準メール処理の抑制なし |
| バージョン | 作成・更新・削除 | 現在の説明本文。生成した本文差分は使わない | 標準メール処理の抑制なし |
| プロジェクト | 更新 | 現在の説明本文。生成した本文差分は使わない | 標準メール処理の抑制なし |
| 期日リマインダー | 設定した日次／手動の一覧 | 専用のリマインダー形式 | リマインダーメールは抑制しない |

イベントの切り替えは `events`、見出し・アイコンは `messages.events`・`messages.icons`、メタデータは `slack.metadata` で設定します。プロジェクト別設定は `projects.<identifier>` 以下の同じ構造を使います。文書添付のイベント設定は `events.document.file` で独立していますが、表示には共通の `file` キーを使います。

`body_diff: false` は本文を隠す設定ではなく、差分の代わりに更新後の本文を表示します。差分設定の省略時はtrueです。全通知の本文を隠す独立した全体スイッチはありません。新しく追加された削除スイッチは初期値falseで、チケット・コメントの削除設定は従来の初期値を維持します。

### 自動テストの検証範囲

スタブテストは通知整形・配信経路・メール方針・コマンドの権限・Work Object・App Home・引用・取り込み・イベント処理を確認します。イベント設定は全体で無効、プロジェクト別で有効にする場合を検証し、本文差分の設定は種類ごとに独立して検証します。モデルの簡易fixtureによるテストは、保存・重複抑制・権限・通知ループ抑制・トランザクションのcommit／rollback・添付のライフサイクル・更新者を確認します。完全なRedmine 7環境の代わりにはなりません。

通知はトランザクションのcommit後にキューへ追加し、rollbackした変更は通知しません。作成は元の作成者、更新・削除は操作したユーザーを表示します。フォーラムの本文編集は差分または更新後の本文を一度だけ表示します。メール抑制はRedmineで有効な通知条件に従い、関連・日付・カスタムフィールドの条件が無効でも、有効なコメント通知の抑制は妨げません。

### 実環境の確認と制限

- ActionMailerのテストにはActionMailerと関連依存が必要です。依存がない環境では、そのテストの検証は未完了です。
- Redmine 7の実際のコールバック順序・親削除に伴う連鎖削除・Sidekiq処理・Slack表示・SMTP配信は、テスト用の実環境で確認します。
- メール抑制は有効なイベント・ユーザー・チャンネル設定・参加状況を確認します。非同期のSlack配信成功は待たないため、抑制後の通信障害・ワーカー障害で配信できない場合があります。
- YAMLはプロセスごとにキャッシュします。設定変更後はRedmineとワーカーを再起動または再読み込みしてください。

## バージョン履歴

1.0より前の項目は、開発内容を振り返って段階ごとに整理したものです。
過去版の番号は説明用に割り当てており、公開済みリリースやGitタグの記録ではありません。

| バージョン | 主な変更 |
| --- | --- |
| **1.7.6** | 公開チケットのコメント通知に、URLのタイトル・説明・画像をコンパクトに表示できます。YAMLで有効化できます。 |
| **1.7.5** | Slackのチケット編集モーダルに現在の題名を追加しました。権限を確認して変更をRedmineの履歴に記録し、保存後にカードの題名を更新します。 |
| **1.7.4** | コメントの差分通知に今回追加した画像を表示します。URLエンコードされたファイル名やコメント作成後に添付された画像にも対応し、文字だけの編集では既存画像を再表示しません。 |
| **1.7.3** | Slackスレッドの接続先に、チケット番号に加えてRedmineのチケットURLを入力できるようにしました。検索パラメーターやコメント位置付きのURLにも対応します。 |
| **1.7.2** | Slack通知の追加添付ファイル名とチケットの添付一覧から、Redmineの添付詳細ページを開けるようにしました。 |
| **1.7.1** | Slackの専用返信URLを使い、BotがアクセスできないDMやチャンネルでのスラッシュコマンド返信を修正しました。キーワードだけで題名を検索でき、引数なしでは従来通りヘルプを表示します。 |
| **1.7.0** | 同じチケット・投稿先の連続通知を、更新者や回数によらず、最初は即時投稿し、以後は投稿の編集で集約する機能を追加しました。`notification_coalescing.enabled`で切り替え、集約時間は既定5分。同じ項目は変更履歴をつなぎ、コメント・画像を保持し、追記前に公開範囲を再確認します。 |
| **1.6.0** | Slack連携のセキュリティを強化しました。引用時に本人とBotのチャンネル参加を確認し、通知では非公開情報を除外して送信前にも再確認します。引用の改変検知、署名付与と検証の独立した切り替え、過去の未署名引用への署名タスクを追加し、DM検索の閲覧権限確認も強化しました。 |
| **1.5.9** | メール照合によるWork Objectのユーザー表示・通知アバターを修正。送信時のメール照合を一覧取得とキャッシュに変更し、ユーザーごとのAPI呼び出しを解消。管理画面に照合方法を表示し、名前・メール照合の優先順位をYAMLの記述順に対応。 |
| **1.5.8** | チャンネル名の自動マッチをプロジェクト識別子との照合に変更。親プロジェクトの照合にも適用します。 |
| **1.5.7** | 期日リマインダーDMで `cannot_dm_bot` が返ったbot宛先をスキップし、宛先IDをログに記録してほかの宛先への配信を継続します。 |
| **1.5.6** | YAMLの `%{avatar}` で通知見出しにSlackアバターを任意表示できます。既定では表示せず、変数を省略した書式は通常の文字サイズを維持します。 |
| **1.5.5** | カスタムフィールドのメタデータをRedmineの表示値に変換し、選択肢名・参照先の名称・言語設定に応じた真偽値を表示します。 |
| **1.5.4** | 全操作通知に操作した人を表示し、YAML変数による見出し設定と製品名の共通展開に対応します。 |
| **1.5.3** | 説明・コメントの編集プレビューで、保存済みSlack引用とURLだけの入力をカード表示します。 |
| **1.5.2** | Slack画像の埋め込み後にRoadieがCSSを適用すると、通知メールのHTML本文が壊れる問題を修正。日本語本文・インライン画像・テキスト版を保持します。 |
| **1.5.1** | SlackがGravatar URLを返す場合に通知メールのアバターが欠落する問題を修正。Gravatar画像とSlack既定アバターへの転送を安全に取得し、インライン添付として埋め込みます。 |
| **1.5.0** | Slackmine管理画面を追加。実効設定・イベント色の色見本・プロジェクト通知先・ユーザーメンションを多言語で表示。Sidekiq使用時のキュー監視・実行履歴・テスト通知を追加しました。 |
| **1.4.0** | 表示文言を動作設定から分離し、日本語の設定例を追加しました。Slack操作の重複実行や処理失敗時の応答も改善しました。 |
| **1.3.0** | Work Objectの即時表示・軽い操作をWebで処理。URL展開・保存後の更新、App Home一覧、スラッシュコマンド配信、スレッド接続の保存、時間のかかる引用付きフォーム保存をSidekiqで処理。接続先選択後の履歴確認はWebを優先し、2秒を超えた場合にキューへ切り替えます。 |
| **1.2.2** | 監査・社内規程向けのファイル転送制限を追加。ファイル本体の代わりに元の保存場所へのリンクで連携し、プロジェクト別の例外設定と全体強制に対応しました。 |
| **1.2.1** | Slackリンクの本文取得・引用保存・カード表示全体と、Redmine画面のカード表示をそれぞれOFFにできる設定を追加。メンションを無効にする設定方法も追記。 |
| **1.2.0** | 会話を読みやすくするため、コメント保存の確認メッセージを非表示・一定時間後に自動削除できる任意設定を追加。 |
| **1.1.0** | 同じユーザーの連続したSlackスレッド返信をまとめて保存する任意設定を追加。新しいDBテーブルやキャッシュバッファを使わず、元の時系列・リンク・添付を保持します。デフォルトは即時保存、設定例は待機60秒・最大300秒。取り込んだコメントの通常Slack通知を切り替える設定も追加しました。 |
| **1.0.0** | Slackmineとして最初のメジャーリリース。文書・ファイル・フォーラムの追加／変更／削除通知を整備。メール抑制の判定をRedmineで有効なメール発生条件に合わせました。 |
| **0.9.0** | プラグイン名・設定・エンドポイント・タスクをSlackmineに統一。スレッド返信を画像・PDF・その他ファイルに拡張し、添付のプレビューとリンクに対応しました。 |
| **0.6.0** | Slack通知スレッドの返信をRedmineコメントとして保存。Slackメッセージの引用を保存し、元の会話を開くリンクを追加しました。 |
| **0.5.0** | IssueのWork Objectプレビュー、最新情報の詳細表示、編集・検索・作成、スラッシュコマンド、App Homeの個人チケット一覧を追加しました。 |
| **0.4.0** | 期日のリマインダーDMと、Slack通知でカバーされるメールを停止する個人設定を追加しました。 |
| **0.3.0** | プロジェクトの通知先選択、親プロジェクトへのフォールバック、ユーザー対応付け、プロジェクト別設定を拡充しました。 |
| **0.2.0** | Block Kitカード、表示項目・文言の設定、本文差分、チケット画像のインライン表示で通知を改善しました。 |
| **0.1.0** | 旧プラグイン名でRedmineからSlackへのイベント通知を開始しました。 |
