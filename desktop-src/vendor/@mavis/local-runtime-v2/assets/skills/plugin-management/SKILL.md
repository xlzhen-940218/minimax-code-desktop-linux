---
name: plugin-management
description: >-
  Discover official MCode plugins when the user asks whether a named service or Mini App is
  available, wants to use one, explicitly asks for plugin recommendations, or needs an unavailable
  integration for the current task. Search the official marketplace with search_plugins and report
  the plugins' real state. Mere mentions and questions explaining a service do not activate this
  workflow.
descriptions:
  zh-Hans: >-
    用户查询某项服务或 Mini App 是否可用、明确想使用或推荐插件，或当前任务缺少外部能力时使用。
    先复用已有能力；需要时用 search_plugins 查询官方市场，核对插件的实际能力与状态。
    普通内容提及服务不触发此流程。
displayNames:
  zh-Hans: '插件管理'
---

# MCode Plugin Management

Find the capability that serves the user's current goal. Discovery and recommendation are separate
choices; finding a related marketplace item does not make installation useful or timely.

## Decide what the user is asking

| Intent | Behavior |
| --- | --- |
| Availability inquiry ("is there a X plugin?", "can you use X?") | Check the catalogs and answer the actual result and state. If the matching plugin is not ready and `recommendable` is true, you may offer one preparation card for it; do not add a separate installation question. |
| Explicit request for plugin recommendations | Search and choose a small relevant set based on the stated goal. |
| Explicit request to use a named capability | Use the exact existing capability. If preparation is necessary, offer one card for it. |
| A task goal without a named capability | Check existing capabilities first. Recommend only when the capability gap and a suitable plugin match are clear enough to justify setup. |
| Discussion or content work that only mentions a service | Complete that request without marketplace search or recommendation. |

Use the latest message and conversation context. A previous setup discussion does not turn every
follow-up into an installation request. If the task can already be done well with current tools,
continue doing it; do not interrupt merely because a related plugin exists. For a choice that would
change the user's destination or workflow, clarify that choice rather than pushing installation.

## Find the right capability

- Reuse a known suitable built-in tool or connected integration first. An empty direct tool list is
  not proof of unavailability; App tools are discovered through their own host tools.
- For using an existing Mini App, when `miniapp` is exposed, call `{ "action": "list" }` and open the
  exact returned identity. Plugin packages can contain Mini Apps; the installed Mini App list is not
  the full marketplace.
- If the requested capability is not installed or known, call `search_plugins` with the service
  name, brand name, or a concise capability phrase. Keep a user-named target in the first lookup and
  search distinct needs separately. If results are empty or unsuitable, try up to two shorter or
  synonymous terms before reporting no suitable match. Do not keep searching once the match is clear.
- Use returned `plugin_name` values and App `provider` values exactly. A failed search, partial page,
  or `catalog_complete: false` is not proof that a service does not exist. Distinguish unavailable,
  not found, and lookup failure; do not invent capabilities, permissions, or a successful opening.

## Recommend preparation only when justified

Offer preparation when the user explicitly wants to use that capability, asks for plugin
recommendations, asks about availability of a plugin that is not ready, or when a concrete task needs
an integration that existing capabilities cannot adequately provide. The candidate's actual
description must support that need. A related topic or possible future benefit alone is not enough.

- Each search result reports `readiness`, `recommendable`, and `suggestion_state`. Only call
  `request_plugin` for a result with `recommendable: true` and `readiness` other than `ready`.
- When `recommendable` is false, do not call `request_plugin` (`user_requested` does not override it).
  `recommendable: false` does not mean the plugin is missing: it may already be installed, enabled,
  or connected. If it is the plugin the user asked about, report its actual `readiness` in plain
  words; if it is not ready, say it can be set up from the plugin marketplace. Never mention
  recommendation settings or the `recommendable` field, and do not bring up other plugins with it.
- Never list installing or using a plugin as an `ask_user` option or as an access method in a
  questionnaire, and never ask the user to paste tokens, passwords, or credentials in chat. Point to
  the plugin marketplace or settings in the reply text instead.
- At most two cards per reply, and each card must serve a different need. Never offer two cards for
  the same need.
- `suggestion_state: "pending"` means a card already exists; do not create another or remind the user
  to choose. `"declined"` means the user said not now; do not recommend it again in this conversation
  unless the user's latest message explicitly asks for that plugin, then retry with
  `user_requested: true`. `"ready"` means it is prepared; use it.

Call `request_plugin` directly with the exact `plugin_name`, a short task benefit as `reason`, and
only the `required_apps` this task needs (omit it when the task does not identify a subset). Omit
`user_requested` on a first offer; set it to `true` only when retrying a plugin the user declined in
this conversation and their latest message explicitly asks for it. It never overrides
`recommendable: false`.

`request_plugin` only displays an optional card inside the current reply. The card offers
Install / Enable / Connect as appropriate and Not now; setup starts only when the user chooses it.
Showing the card does not install software or authorize an account. The card collects that
decision, so do not use `ask_user` to ask whether to show it, install, or connect, before or after.
The card renders below your reply text and already explains the options. You may say that a card was
offered in this reply, plus one plain sentence about what needs setup, such as
"查询股东结构需要先安装并连接企查查。". Do not place the card anywhere else (such as "上一条回复" or
"上面"), do not tell the user what to click or name the card's buttons, do not narrate internal tools,
IDs, or fields such as `plugin_name`, `readiness`, or `recommendable`, and never imply the plugin is
already prepared or connected (for example "已准备好" or "已接入") before the user finishes setup.
If `request_plugin` returns `status: "ready"` with `usable_in_this_turn: false`, the plugin became
ready after this reply started: say so briefly and end this reply so the user can continue.

Use `ask_user` for consequential task choices, separately from setup, and never mix installation
choices into a task questionnaire. The platform owns installation, enabling, connection, and
verified readiness. Do not request credentials in chat or install through shell commands.
Marketplace items are not delivered files: do not emit `plugin://`, `<deliver-assets>`, or
`<media type="plugin">` for recommendations.

## Keep the conversation moving

A pending card stays in its original reply and does not block ordinary messages. Only dependent
operations wait; continue unrelated work. Respond to the user's latest message with its requested
length and format.

When the user named this service or plugin as the data source and you offered its card, web
research or other tools are a substitute, not independent work: do not start them on your own. Say
in plain words what the plugin would provide, offer the public-source alternative in one sentence,
and stop that part. Continue only work that does not depend on that service. When no service was
named and the card fills a task gap, keep continuing independent work as usual.

A text refusal needs a brief natural reply, not another `request_plugin` call. Clicking Not now only
updates the card; it does not produce a message or another reply. After refusal, stop recommending
that plugin unless the user explicitly changes their mind. Ignoring a card is not a request to
repeat it.

When the card reports the plugin ready, the conversation continues automatically. Follow the latest
user intent with the plugin's actual tools, Skills, or Mini App; do not replay a task the user has
abandoned. Preparing a plugin does not authorize unrelated actions.

## Scope

Official marketplace preparation is available in local MCode Desktop conversations. Custom plugins,
arbitrary MCP setup, and account permission changes use their existing management interfaces. Do
not promise an operation that the current environment does not expose.
