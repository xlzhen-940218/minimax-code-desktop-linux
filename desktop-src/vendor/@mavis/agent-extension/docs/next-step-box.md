# Next Step Box

PRD: https://vrfi1sk8a0.feishu.cn/wiki/Dj5KwVXY3iKtK6kSktJckSFOntb

## 结论

- 开关：用户在「设置 > 偏好」里的「下一步卡片」，写入
  `nextStepBox.enabled`。用户没设置过时，按 Apollo
  `agent_config.prompt_suggestion.next_step_default_enabled`
  决定；Apollo 也没配置时默认开启。这个默认值与同一对象里下一句建议的 `default_enabled`
  互不影响，`kill_switch` 和 `sample_rate`
  只作用于下一句建议。生效值在宿主的配置读取边界上填好（`withEffectivePromptSuggestion`），运行时和设置页读到的是同一个值；关闭时不加提示词，也不注册工具。UI 的卡片可点状态跟随配置变化，不需要重启。
- 注册按会话，出卡按回合。开启后，Electron 所有者的可见 conversation 会话（含 SideChat）和 cron 自建的运行会话在每个回合都带同样的提示词和
  `wrap_up`
  定义，同一会话的请求前缀因此不随回合来源变化，prompt 缓存不会失效。channel 会话、任务子会话、普通隐藏会话、MiniApp 会话不注册；Plan 期间也不注册。
- 能出卡的回合分两类。前台用户回合：普通发送（`api`）、编辑后重发（`conversation-mutation`）、点击「继续」（`turn-continuation`）和回答问卷（`questionnaire`，含超时自动回复）。无人值守回合：cron 运行（`cron`）、后台任务完成通知（`background-task`）和其他会话发来的消息（`communication`，如定时提醒的「继续」或 session
  send），卡片留在会话里，用户回来看结果时再答。
- 无人值守回合的卡片强制不阻塞（`nextStepUnattended`）：回合以等待用户结束时不唤醒队列，阻塞卡片会卡住排队消息和后面的定时运行。用户在 cron 会话里自己发的消息属于前台回合，可以阻塞。
- 每次调用 `wrap_up`
  都在这一步结束回合，不向模型返回错误，也不要求它再做什么。正文在调用前已经写完；之后只要再请求一次模型，它就会再写一段文字，历史把这段当成正文，真正的回答被收进过程区。回合种类和参数是否合规只决定出不出卡，不决定回合是否继续。工具不保存跨调用状态。
- 其他回合（`/review`、Goal、任务通知、IM 输入，以及回答 Goal 回合里的问卷后的续跑）里调用 `wrap_up`
  会拿到不出卡的 suppressed 结果（`reason: 'ineligible'`），回合就此结束。本回合用过 `ask_user`
  不影响出卡。调用时还有模型没看到的输入（待注入的 steer 或队列里的用户消息，`hasPendingUserInput`）时也不出卡（`reason: 'superseded'`）并结束回合：steer 消息在本批结束后照常注入，队列消息开新回合。模型已经读过的 steer 不影响出卡。
- SideChat 只允许 reply；是否为 SideChat 以会话记录为准（带 `sideChatOrigin`
  且隐藏），提升为普通会话后按普通会话处理。IM 回复里不输出卡片文字。
- 模型先写完整正文，再单独调用 `wrap_up`
  作为最后一步。本回合还没有正文时，工具边界直接拒绝，这是唯一的拒绝：它只在本回合还没有任何正文时触发，模型接着写的就是唯一的正文，不会造成折叠。
- 一张卡只有一个问题和 0–4 个答案；没有答案时用户在输入框回答，卡片不编造候选项。没有合格问题时不出卡，不再写入只有小结的结果。多个独立决定交给
  `ask_user`（`async=true`），不放进卡片。
- reply 选项只发送 label 原文。label 就是用户对这个问题的完整回答。
- 所有带回答的卡片都用纵向选项行，单个回答和 App 操作也一样：单选点击即执行，多选点提交。数字键、方向键和确认快捷键保留，不显示提示；没有选中时确认键不动作。没有回答的卡片只显示小结和问题，不显示「跳过」。
- 卡片小结最多显示三行，超出时末尾省略。仅被截断时悬停显示产品 Tooltip 内的完整小结；窗口宽度或文案变化后重新判断。待答、已答和已关闭卡片使用同一规则；Electron 窄窗口也保留全文提示，不受移动端隐藏 Tooltip 的规则影响。
- 以 `wrap_up` 结束的回合按正常完成处理：不显示“继续”，不出卡的回合照常生成 Prompt
  Suggestion 灰字，记忆捕获保留收尾正文。
- PTC 回合里 `wrap_up` 仍是顶层直调工具，不进 `run_code`。

## 工具契约

- 字段：`recap`（必填，≤96 个码点；超长不报错、不重试，卡片只显示问题）、`decision`、`ask`（提示词要求 ≤50 字符；卡片最多显示 200 个码点，超过 200 视为没有问题）、`actions`（0–4 个；没有时用户在输入框回答）、`selectionMode`、`allowOther`、`blocked`。
- reply action 只有 `label`（协议上限 40，提示词要求 ≤24）和可选 `recommended`。已删除 `message`。
- app_action：`commit` 打开提交弹窗，`review_changes`
  打开改动面板（本轮有 diff 时定位到本轮，否则显示工作区改动），`new_session`
  新建会话，`archive_session`
  归档当前会话。点 App 操作不发送回答，卡片留在原位，不移到操作栏下方。会话属于启用中的定时任务时，runtime 和界面都不提供
  `archive_session`，归档只能走会先确认的侧栏和顶栏入口。含 app_action 时最多 2 个回答。模型请求当前不可用的 App 操作时，卡片去掉这个按钮，问题和其他回答保留，不向模型报错；一个回答都不剩时，用户在输入框回复（SideChat 不开放 App 操作）。卡片显示时才变得不可用的，同样只移除那一个选项。
- 已删除多题 `questions`。schema 不再接受 `message` 和 `questions`。
- `decision` 缺失或为 `none` 时不出卡，直接结束回合，不校验其他字段。`contextual_follow_up`
  强制不阻塞；含 App 操作的卡片也强制不阻塞，因为点 App 操作不会给模型发消息，等待无法解除。`decision`
  只用于生成门禁，不写进历史。
- 结果写在
  `ToolResult.details`：`kind: 'wrap_up'`、`schema_version: 1`、recap、可选 ask/actions、`blocked`、`waiting_for_user`、`turn_id`。
- 参数一律在入口归一（`prepareWrapUpArguments`，在 schema 校验之前运行，`execute`
  里再跑一次，可重复执行），不向模型返回错误：去掉多余字段和卡片画不出的回答（label 码点数不在 2–40、未知 kind、已删除的
  `message`），超过 4 个的回答只留前 4 个；含 App 操作时只留前 2 个回答、改为单选、去掉
  `allowOther`；单选里多个推荐只保留第一个。长度上限只写在字段说明里，不写成 schema 关键字，因为 schema 按 UTF-16 计数、卡片按码点计数。没有合格问题（`decision`
  缺失或为 `none`、问题为空或超过 200 码点）时不出卡并结束回合（`reason: 'no_question'`）。
- 不出卡的结果写
  `reason`（`disabled`、`ineligible`、`no_question`、`superseded`、`unreadable`），排查时从历史直接看出是哪条规则起作用。

## 提示词

`WRAP_UP_GUIDANCE` 是精简版规则，工具和字段说明都压成短句。要点：

- 正文必须能独立读懂；卡片只装本来要写在结尾的那个问题，不替代回答。
- 只在三项都满足时提问：来自本轮实际结果且对话没回答过；答案会改变判断、建议或下一步；不是“继续已授权的工作”“还有别的吗”或额外交付物推销。没有这样的问题时不调用
  `wrap_up`。
- 执行中缺信息用 `ask_user`，先问再做，不猜收件人、路径或数值。
- `blocked=true`
  只用于没有答案就无法继续的情况。新用户消息取代未答卡片，未答卡片不算授权。正文检查里划分回合起点的“输入”是宿主提交的 user 消息（agent-core
  `isHostSubmittedUserInput`：宿主给每条输入都记录 `canonicalTextRange` 或
  `genuineUserQueryText`），但不含后台任务完成通知（`hostMetadata.backgroundTaskOrigin`，`isBackgroundTaskUserMessage`）。例外：无人值守回合的正文检查把通知也算作回合起点，因为回合可能就是通知开启的，不能拿上一回合的正文放行。其他扩展在回合中 steer 的提醒（如 runaway
  guard）没有来源记录，不算输入。问卷回答、编辑后重发、只发附件的消息即使真实查询文本为空，仍算输入。

提示词在 `packages/agent-extension/src/wrap-up.ts`，不在 `local-runtime-v2/assets/agents/`
下，不受 prompt 资产登记约束。

## 运行时行为

- **结束回合**：`execute` 的每条路径都返回 `terminate: true`。`terminate`
  只有同批结果全部带上才生效，所以 `after_tool_call` 对 `wrap_up` 另外返回
  `terminateAgent`：与其他工具同批时，这一批跑完就停，排在 `wrap_up`
  后面的工具被跳过（写入 skipped 结果）。PTC 的 `run_code` 结束外层回合用的是同一机制。
- **正文检查**：`before_tool_call`
  检查本回合是否已有正文，不再拒绝与其他工具同批的调用。“本回合”指最近一条输入（定义见上）之后的消息（含当前 assistant 消息，pi 在调用钩子前已把它放进
  `context.messages`）。只看非空 `text` 块；thinking 和工具调用不算。无正文时拒绝，理由是
  `Write your complete answer as text first, then call wrap_up alone.`。只读本次调用的上下文，不保存跨调用状态。
- **终止标记**：`terminate` 不进历史。所有 `terminate: true` 且 `waiting_for_user=false`
  的结果在 details 里写
  `terminates_turn: true`（`TURN_TERMINATING_TOOL_RESULT_DETAIL`）。blocked 卡片只写
  `waiting_for_user`，仍按等待用户处理。
- **停止标记**：`terminateAgent` 同样不进历史。`wrap_up` 的每个结果都写
  `stops_turn: true`（agent-core
  `TURN_STOPPING_TOOL_RESULT_DETAIL`），表示这个结果让整批停下，不管同批还有什么。读取方按 pi 的两条规则判断这一步是否关闭（`isTurnClosedByTerminatingTools`）：每个调用的结果都带
  `terminates_turn`，或者有一个结果同时带 `stops_turn` 和
  `terminates_turn`、且同批没有结果在等待用户（如同批的 `request_feature_enable`）。只带
  `stops_turn`、等待用户的阻塞卡片不算结束。续跑判断以同一批里带 `stops_turn`
  的结果为准，同批有等待用户的结果时以它为准，不看 pi 在它后面写的 skipped 结果，所以阻塞卡片和同批的等待仍读成「等待用户」，其余读成不可继续；续跑日志里的等待诊断（`continuationTailWait`）读同一个结果。与其他工具同批时，持久化的 finish
  reason、下一句建议和记忆捕获都按正常结束处理。 `wrap_up`
  不是最后一个调用时（`[wrap_up, X]`），界面只把最后一个调用是 `wrap_up`
  的卡当作待答卡，这张卡以只读显示问题；提示词要求单独、最后调用，本机数据里没有出现过。
- **正常完成判断**：pi 终止后不再请求模型，最后一条 assistant 是 `stopReason: 'toolUse'` 的
  `wrap_up` 调用。agent-core 的 `isTurnClosedByTerminatingTools` /
  `isTurnClosedByTerminatingToolsAt` 判断“最后一条 assistant 的每个工具调用都有带 `terminates_turn`
  的结果”，规则与 pi 的 batch 终止条件一致。以下读取方共用它：
  - Prompt Suggestion：没有问题卡时，这类回合与 `stop` 一样可以生成建议；有问题卡时仍以
    `next_step_card` 跳过。
  - 记忆捕获：这条 assistant 的正文按最终回答计入；它只有工具调用时，计入上一步工具步骤写的正文。Goal
    blocked（`update_goal`）和 `terminate_agent`
    结束的回合带同一标记，也按正常完成收录（2026-11-03 已与 owner 确认）。
  - EventBridge：延迟发出的 completed agent_message 把 `finish_reason` 从 `toolUse` 改成
    `stop`，历史回放和 UI 灰字恢复因此看到正常完成。工具执行前就发出的 finish chunk 仍是
    `toolUse`，随后被 completed 消息覆盖。`update_goal`、带 `terminate_agent` 的 `run_code`
    等带同一标记的回合也会得到 `stop`。
- **继续**：`inspectContinuationHistory` 读到 `terminates_turn` 返回 `unavailable`，读到
  `waiting_for_user` 返回 `waiting-for-user`。
- **PTC**：`wrap_up` 已加入 `PTC_DIRECT_ONLY_TOOL_NAMES`，`run_code` 内调用会被拒绝。生产组装中
  `wrap_up` 由扩展追加在本地目录之后，本来就在顶层；这一项是防御，防止它以后被并进 `run_code`
  子工具后 `terminate` 失效。
- **写入前回读**：执行前的检查把空白 ask、码点数不在 `NEXT_STEP_LABEL_MIN`–`NEXT_STEP_LABEL_MAX`
  之间的 reply 标签算作非法，模型有一次改正机会。组装好的 details 写入前再用 `readNextStepCard`
  读一遍；读不回时不出卡并结束回合，不会对模型说卡片已展示。
- 会话完成事件携带 waitingForUser，读工具结果里通用的 `details.waiting_for_user`
  标记（ask_user、Plan 审批、功能开启都会写），与 runner 的判断一致。卡片不影响桌面的「任务完成」通知：回合结束照常通知，带不带卡片、卡片是否阻塞都一样。
- **会话列表状态**：一行只显示一个「需要用户输入」（`useSessionActivity` 的
  `question`）。待答问卷、阻塞卡片和以等待用户结束的回合共用它，范围都包含侧聊和子会话；已结束回合留下的异步问卷不算，判断与问卷相同。卡片开关关闭时，卡片和等待标记不影响这个状态，问卷照常显示。

## 历史兼容

`readNextStepCard` 是历史和实时事件共用的读取入口，在这里归一：

- 旧 reply action 带 `message` 不判无效，读出时丢掉该字段。
- 用户没点卡片、直接发新消息时，旧卡收成只读快照：卡片本来就提示去输入框回复的（没有回答、只有 App 操作，或
  `allowOther`）显示「已在输入框回复」，其余显示「已跳过」。cron 运行和后台任务完成通知不算用户发的消息，不收起卡片。消息是否真在回答这个问题，界面判断不了，所以不把它记成卡片的回答，只由模型自己读。
- 读不懂的回答（如新版本才有的 App 操作）只丢掉那一项，小结和问题保留；一个回答都不剩时，用户在输入框回复。
- 只有 recap 的旧结果仍能读出，但聊天面板只展示带问题的卡（`findNextStepHistory`），界面上本来就不渲染；新回合不再写入这种结果。
- 旧多题 `questions` 卡片和更早的 `items`
  清单降级为只有 recap 的卡片，不恢复问题，也不恢复等待状态。
- 返回值只含卡片字段，宿主写入的标记（如 `terminates_turn`）不进卡片对象。

## 来源与操作

- 本地 Desktop：入口和 action 都核对当前目标、activeSessionId、Git 与本轮 diff 条件。切换来源、远端控制路由或会话后，旧操作失效。
- SideChat：以会话记录为准，带 `sideChatOrigin` 且 `visibility`
  为 hidden。普通隐藏会话不能借此开放；只允许 reply，不开放提交、归档等 App 操作。提升为普通会话后，即使历史里仍有
  `sidechat_mode` 标记，也按普通会话处理。
- Remote Control：runtime 不排除，UI 侧做只读降级。
- SSH：本次不开放。
- Web
  / 手机 Native：未接入。Web 开放前需要 archon-server 资格开关与等待/队列、cloud-runtime 工具/提示词/终止、Web
  SSE/历史/回复闭环；云端协议扩展先走 IDL MR。

## 与 Prompt Suggestion 的边界

- 当前任务缺信息无法完成：`ask_user`。
- 已有有用结果，还有一个会改变判断或下一步的具体问题：`wrap_up` 的 ask。
- 只有用户可能想问的下一句或可选交付物：不出卡，交给 Prompt Suggestion。
- 待答问题卡优先，两者不同时展示；不出卡的回合照常出灰字。

## 埋点

卡片事件：`next_step_card_view`、`next_step_card_click`（`phase`
区分选择、跳过、提交尝试、成功、失败）、`next_step_card_bypass`、 `next_step_card_dismiss`，都带
`chat_id`、`turn_id`、`card_id`、`blocked`。

设置页开关：`next_step_card_enable_click`，字段与下一句建议的 `prompt_suggestion_enable_click`
相同：`page=setting_page`， `clk_type` 为 `'1'`（打开）或
`'0'`（关闭）。只在设置保存成功后上报，保存失败不报。

默认开启后要回答的问题：看到过卡片的用户里有多少人主动关掉。分母是有 `next_step_card_view`
的用户数，分子是其中上报 `next_step_card_enable_click`、`clk_type='0'`
的用户数。关闭率明显偏高时，考虑把 Apollo `next_step_default_enabled` 改成
`false`，或回头调整出卡的条件。只有开关事件分不出关闭原因。

## 验证边界

自动化覆盖：工具开关、按会话注册与按回合出卡（含 channel 会话不注册、同一会话前缀不变）、正文检查、单题契约与 schema、终止标记、继续判断、Prompt
Suggestion 与记忆捕获对 `wrap_up` 回合的处理、EventBridge `finish_reason`
归一、PTC 直调、旧历史降级。测试使用受控输入，不代表真实模型行为。

离线评测只跑过 MiniMax-M3.1-Flash（结果见 MR 描述），真实 Desktop 只做过部分场景的实机验收。功能默认开启，线上可通过 Apollo
`next_step_default_enabled` 收回。UI 交互细节（选项行、快捷键、答后摘要位置等）以 `packages/ui`
源码和[功能地图](../../../.harness/docs/next-step-box/feature-map/next-step-box.md)为准。
