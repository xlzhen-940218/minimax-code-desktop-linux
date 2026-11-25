# AGENTS.md — local-runtime-v2 rules

本文件适用于 `packages/local-runtime-v2/**`，并与仓库根 `AGENTS.md` 叠加。

## Composition

- `src/runtime.ts` 只编排固定阶段：初始化 v1 compat、DB、background infra、business services、delivery。
  不得在这里定义或装配某个 service 专属的 ports、error code、recovery 或 lifecycle。
  它只能直接依赖 `infra/db/client.ts`、`infra/db/initialize.ts`、`http/app.ts` 与 `local/app.ts`，其他
  infra / delivery implementation 必须隐藏在更窄的 composition root 后；HTTP 与 process-local
  delivery 是平级边界。
- package facade 的 host factory 只有 `options` 一个参数；component override 只允许 direct-module test seam，
  不得从 `src/index.ts` 导出或让生产调用方注入 DB path、service ports、HTTP hooks。
- `src/background-runtime.ts` 只拥有长驻基础设施的实例与生命周期。当前实例是共享 `Scheduler` 与
  live-only `EventBus`；未来同类 infra 也在这里组装。它不得 import `service`、`compat` 或 `http`。
- `src/services.ts` 是业务 service / Application composition root。新增 Cron、Session 等 service 时修改
  这里和对应的 `src/service/<name>/`，不得给 `runtime.ts` 增加 service-specific wiring。它不得 import
  HTTP 或 process-local delivery，也只能 type-import infra capability 与 aggregate v1 compatibility，不能创建
  infra 或 compatibility value。Session Applications 只有在 TurnHost、Queue recovery/Dispatcher、
  archive-title/cleanup 等 required ports 全部显式提供后才能整体暴露；禁止 noop、v1 fallback 或
  test-only production branch。
- `src/service/<name>/` 必须封装业务规则、状态或生命周期。若删除它只会少一次参数或方法转发，应由现有
  composition root 直接接线；不得为目录对称或“未来可能复用”新增 pass-through service / facade。
- 业务 service 只能借用 `SchedulerClient` 等不含生命周期的 capability；禁止 import concrete
  `Scheduler`，也禁止调用共享 infra 的 `start()` / `stop()`。
- 固定启动顺序是：创建 services 并注册 handler → `BackgroundRuntime.start()` →
  `RuntimeServices.ready()` → HTTP → 后台启动恢复（`startStartupRecovery()`）。ready 只做装配与本地对账，
  执行上次遗留工作的步骤只能放进启动恢复，不得重新放回 ready。关闭顺序先停 background infra，再逆序
  drain services。
- `compat/v1/runtime.ts` 聚合跨代 reference slice，`compat/v1/cron.ts` 保存 Cron-specific adapter，
  `compat/v1/session.ts` 只保存 Session Scope-A capability。
  `runtime.ts` / `services.ts` 只能 import aggregate `compat/v1/runtime.ts`，不得绕过它直连某个
  service-specific compat leaf。业务 service 实现不得直接依赖 compat；v1 能力只能经 composition root 注入。
- service `ready()` 失败不得自行 close：runtime 必须先停止 background infra，再 drain services，避免新
  trigger 进入已关闭的 service。startup rollback 使用同一 dependency-safe 顺序，不按构造顺序机械倒放。
- Scheduler handler 只做同步 admission（持久化/入队）并立即返回；service 自己跟踪和 drain 已接纳工作。
  `Scheduler.stop()` 只停止新 timer，不等待任意 async callback。需要通用 drain 语义时另行扩展 infra，
  不得假设当前 `BackgroundRuntime.close()` 已等待 handler 完成。
- 不为未来 service 预建通用 registry、Dispatcher 或 lifecycle framework。`infra/event-bus` 只保留当前
  Global Events 所需的泛型同步 fan-out / subscribe / close，不得加入 event catalog、filter、replay、HTTP
  或 Session 语义；新的业务事件能力仍优先扩展上述三个显式 composition files。
- `src/application/` 只编排跨 capability workflow、stable application error、generated wire mapping 与
  committed-fact public event projection。它不得 import Hono、HTTP / process-local delivery、concrete
  EventBus、concrete compat store 或 `runtime.ts`，也不得创建单一 `SessionApplication` 聚合转发层。
- Session / Project controller 只把 generated context/request 委托给具名 Application；不得直接 import
  Session System、Project、Queue service 或复制 mapping/error/workflow。34 个方法只有在
  `RuntimeApplications` 完整存在时原子进入 allowlist；Turn-owned Session 方法保持 target baseline。
  `updateProject` 支持由 ProjectApplication 校验的名称与图标 metadata 更新，二者可单独或一次提交；
  归档等字段不在此入口开放。
- Application producer 只能从已经提交的 fact 投影 `GlobalEventInput`。publish 为 commit 后
  best-effort，失败不得回滚业务状态；required participant 必须在 commit 前完成，不能伪装成 event
  subscriber。
- 修改这些边界必须同步运行 package `check:architecture`、`test:architecture` 与根目录
  `scripts/test/local-runtime-layout-check.test.mjs`；禁止通过放宽门禁绕过 ownership。

## Service Layout

- 每个 `src/service/<name>/` 根目录必须包含只做 re-export 的 `index.ts`、纯契约
  `contracts.ts` 和装配入口 `initialize.ts`。Service 外部的生产代码只从 `index.ts` 导入。
- `contracts.ts` / `errors.ts` 保存无 I/O、无可变状态的契约和稳定错误；
  `*.service.ts` / `lifecycle.ts` / `executor.ts` 保存业务编排；
  `*.repository.ts` / `*.adapter.ts` / `*.client.ts` 保存外部绑定；
  `initialize.ts` 与按需存在的 `composition.ts` 负责装配。
- 同一职责的直属生产文件达到 3 个时收进命名明确的子目录；2 个以内保持平铺。单目录直属
  生产 TypeScript 上限为 10，`*.test.ts` 与 `index.ts` 不计入职责分组数量。
- 任意 `index.ts` 都只做 re-export。默认测试继续与被测源文件保持同名 sibling；Agent capability
  的 unit tests 使用 `test/unit/agent/<same-relative-path>.test.ts` 镜像模式，compat/infra 的包级
  unit tests 分别使用 `test/unit/compat/<same-relative-path>.test.ts` 与
  `test/unit/infra/<same-relative-path>.test.ts`。三类测试每个生产源只能有一个镜像测试，且必须
  直接 import 对应源文件（由 dependency-cruiser 语义门禁验证）；`src/service/agent/` 内禁止放置
  `*.test.ts`。
- 一次性迁移或 backfill 使用 `_migration-*`，Demo、PoC 和实验代码使用 `_demo-*` 或进入
  生产构建明确排除的 `__dev__/`。即将删除的兼容层添加 `@deprecated` 并写明删除条件。
- 完整规则和理由见 `.harness/docs/adr/local-runtime-v2-service-layout.md`。

## Tests

- 测试结果不能取决于机器忙不忙。CI runner 经常超卖，72 小时里同一提交重试才通过的 Runtime 失败有 88% 是超时。
  根目录 `.eslintrc.js` 的 `LOCAL_RUNTIME_V2_TEST_RESTRICTED_SYNTAX` 拒绝下面这些写法，`scripts/test/local-runtime-v2-test-lint.test.mjs`
  逐条验证规则本身。在包目录运行的 `lint`、`lint:ci` 和 `lint:files` 都检查 `src/**/test/**`，根目录 `.eslintignore` 的 `**/test/**`
  以前把它们漏掉了。根目录的 `pnpm lint` 仍然跳过所有 test 目录，改 Runtime 测试时要在包目录跑。
- 子进程里不用 tsx 或 ts-node 现场编译 TypeScript（包括 `tsx/esm/api` 的 `register()`），每次起进程都要重新编译整张模块图，
  安静的机器上就要 5-10 秒。逻辑能在进程内测就在进程内测；必须真起进程时，用 `test/helpers/compiled-entry.ts` 把入口编译
  一次，再用普通 node 起 JavaScript。
- 不用 `spawnSync` / `execSync` / `execFileSync`，子进程跑多久，Vitest worker 的事件循环就冻结多久。改用
  `test/helpers/run-command.ts` 的 `runCommand` 或 `runCommandOrThrow`。
- 时限一律经过 `test/helpers/time-budget.ts`。等待用其中的 `waitFor` / `waitUntil`，不直接用 `vi.waitFor` /
  `vi.waitUntil`；用例、hook 和 `AbortSignal.timeout` 的时限包一层 `scaledTimeout()`，`expect.poll` 和自定义包装函数的 `timeout`
  选项也一样。CI 设置
  `MAVIS_TEST_TIME_SCALE`，按机器放大这些时限，全局 `testTimeout` / `hookTimeout` 同样会放大。`time-budget.ts` 依赖
  vitest，子进程入口和它引用的 helper 不能 import 它。
- 不按固定时长等待（`setTimeout` / `setInterval` 带非零延迟，`node:timers/promises` 的 `setTimeout`），也不断言实际耗时。
  直接写 `expect(Date.now() - start)` 算耗时断言，先把 `Date.now() - start` 存进变量、属性或返回值再断言也算。等条件用
  `waitFor`，等某一步用 deferred。要断言某件事还没发生，就用 gate 挡住它，用 `test/helpers/time-budget.ts` 的 `drainEventLoop()`
  冲刷事件循环后检查状态，不和定时器赛跑。它默认跑 20 轮零延迟定时器，约 25 毫秒；`setImmediate` 跑同样轮数只有约 1 毫秒。断言
  promise 还没完成时用同一文件的 `isStillPending()`。只等到钩子被调用不算观察窗口，反向断言前要再冲刷一次。涉及时间
  语义用 fake timers。`setTimeout(fn, 0)` 只是让出事件循环，可以用。`AbortSignal.timeout(scaledTimeout(ms))` 只用来给会卡住的
  操作兜底，不用来等一段时间。
- 只有跑在 fake timers 下的代码不受上一条限制。具体是用例回调里调用了 `vi.useFakeTimers()`，或者 describe 回调、函数或文件
  自己的语句开了 fake timers（包括在 `beforeEach` / `beforeAll` 里开）。同一个文件里用真实时钟的用例照样检查。在 helper 里开
  fake timers 时 lint 看不到，要在用例或 hook 里显式调用。不要为了绕过规则而开 fake timers。
- 耗时的下限（机器越忙只会越长）可以用两个记录下来的时间戳相减来断言。只打印耗时的 benchmark 在根目录 `.eslintrc.js` 里按文件
  豁免，`test/helpers/time-budget.ts` 也是这样豁免的。本包行内 `eslint-disable` 的预算只有 3 条，已经用满。
- 有几种写法 lint 认不出来，写之前先换成顺序断言或 fake timers。一种是两个在别处记录的时间戳相减再断言上限，一种是在 helper 里
  量好耗时再返回，一种是给被测代码传很短的真实截止时间，又期望它在时限内完成，还有一种是用例调用 `vi.useRealTimers()` 之后再 sleep。
- fake timers 下的 `waitFor` 每次检查前都会把 fake 时钟推进一个 interval，推进多少取决于真实等了多久。被测代码的定时器落在这个
  范围内时，结果就取决于机器快慢。这时改成用 `vi.advanceTimersByTimeAsync` 显式推进，或者把定时器设到轮询推不到的范围。
- 测试不设 `retry`，不监听固定端口。反复失败的测试按 `ci/quarantine.json` 的流程隔离。
- mock 返回 `Response` 时，每次调用都新建一个，写成 `mockImplementation(async () => new Response(...))`，只调用一次的用
  `mockResolvedValueOnce`。Response 的 body 只能读一次，`mockResolvedValue(new Response(...))` 让之后每次调用都拿到读完的
  body，被测代码会走报错、重试或退避分支，测的就不是原本的路径。`test/unit/infra/logging/logger.test.ts` 曾因此让安审每次都
  报本地错误，每个用例多等 4-10 秒随机退避。lint 拒绝把 `new Response(...)` 或 `Response.json(...)` 直接传给
  `mockResolvedValue` / `mockReturnValue`。
- 不等生产代码里写死的长时长，也不为了走到上限分支真的造出上限规模的数据。前台 Bash 的 60 秒 soft yield、ZIP64 的 65,535
  条目阈值这类值，通过已有参数或标了 `@internal` 的测试接缝传一个小值，默认值另外断言。lint 认不出这两种写法，评审时要看。
- 单元测试不真起 Runtime Host。`src/**/*.test.ts` 和 `test/unit` 里调用 `createLocalRuntimeHostV2*` 时必须 mock 掉
  `services.js`，真起 Host 的测试放在 `test/integration`。
- 每个测试从零跑一遍数据库迁移不受限制，安静的机器上实测一次约 42 毫秒，不是瓶颈。

## Persistence

- 修改 persistence 前先阅读 `.harness/docs/design/db/v2-db-architecture.md` 与
  `.harness/docs/adr/local-runtime-v2-migration-ownership.md`。
- Drizzle table schema 只定义在 `src/infra/db/schema/`。
- Service 可以使用注入的 `AppDb`、集中 schema 与 Drizzle query builder / expression fragment；禁止访问
  raw SQLite handle 或执行完整 raw SQL statement。
- 不得仅为隐藏 Drizzle 新增单实现的 pass-through Repository / Store；只有它承载业务不变量或存在真实的
  第二个 adapter 时才引入 seam。
- connection、backup、PRAGMA、migration runner 与 schema consistency 只属于 `infra/db`。
- Migration 使用 runner 提供的 connection 与 transaction，不依赖 service 或当前 schema。Migration 可以
  使用冻结的完整 raw SQL；来自数据的值必须使用 bind parameter，禁止字符串插值，DDL 与 identifier 明写在
  migration 中。所有 migration 显式注册到 `ALL_MIGRATIONS`，已发布 migration 不原地修改。
- DB 改动至少运行 package `lint`、`check:architecture`、`test:architecture` 与受影响的 integration tests。
