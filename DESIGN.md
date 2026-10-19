# 《汉末烽火》当前架构与数据契约

## 当前方向

Godot 4.7.2 Standard 是项目唯一运行时，目标是可保存、可测试、可发行的单机 SRPG。正式入口、规则服务、表现层、存档和全部运行时数据都位于 `godot/`。

当前基准战场是“颍川之战 · 河桥争夺”：12×10 棋盘、120 个格子、双方各 5 个单位。`yingchuan-02` 已进入 Godot 战役目录，但阶段 1 先稳定 `yingchuan-01` 的核心闭环。

## 单一运行时与数据源

`godot/data/` 是唯一 canonical 数据源。Godot 的 `DataRepository` 是正式运行时的数据入口，负责版本、引用、棋盘、单位、目标和战役扩展字段的校验。新增正式关卡、兵种、技能、地形和战役内容只编辑这里。

根目录的浏览器原型、兼容快照和同步校验脚本已移除；不存在需要双向同步或跨运行时对齐的当前数据流程。历史阶段曾有一套浏览器数据副本，相关差异只在 [`progress.md`](progress.md) 的历史记录中保留。

## 运行时数据契约

- 所有 JSON 文档带正整数 `version`。
- `characterId`、`classId`、`skillId`、`terrainId`、`instanceId` 和战场 `id` 是稳定 ID，显示名称不能替代它们。
- 战场 `board.width`/`height` 与 `tiles` 行列必须一致；当前基准战场为 `12×10`。
- 单位使用左上角 `(0, 0)`、向右为 `x`、向下为 `y` 的坐标；`instanceId` 在单个战场内唯一。
- `level` 与 `exp` 属于战场实例；兵种基础属性和成长来自 `classes.json`，人物个人修正来自 `characters.json`。
- `objectives`、`rules`、`events` 是可选扩展，未知字段不得静默改变规则。

## Godot 主线模块

```text
Campaign / BattleScene       表现层：输入、地图绘制、HUD、动画
        │
GameSession                  应用层：组合依赖、派发命令、读快照、恢复战斗
        │
BattleService                领域层：移动、攻击、技能、地形、AI、胜负
        │
DataRepository / Save*      基础设施：JSON 校验、版本化状态、原子存档
```

- `godot/scripts/data/DataRepository.gd`：Godot canonical JSON 的唯一入口。
- `godot/scripts/domain/BattleService.gd`：不依赖 UI 的命令驱动规则层。
- `godot/scripts/domain/ObjectiveEvaluator.gd`：目标驱动的胜负判定。
- `godot/scripts/domain/EnemyPolicy.gd`：敌方策略接口和基础 AI。
- `godot/scripts/save/`：战役/战斗存档和损坏回退。
- `godot/scripts/presentation/`：战场、棋盘、HUD、输入和音频门面。
- `godot/legacy/MainLegacy.gd`：历史切片，只作迁移对照，不是入口。

领域层只操作 `BattleState`，通过命令提交变更并输出事件；表现层消费事件，不直接计算伤害或修改 HP/MP。

### Godot 回放 smoke fixture

`godot/data/replays/replay-parity.json` 是当前最小回放 smoke 契约。每个 scenario 包含完整的 `battle`、固定 `commands` 和共享 `seed`；Godot 通过 `ReplayService` 执行，并逐步检查 `mode`、`phase`、`turn`、单位状态和 `enemyMovement` trace。文件名保留历史兼容性，但当前不再表示跨运行时比较。

该摘要刻意不包含表现日志、剧情旗标、存档字段或 RNG 内部状态。Godot smoke 在首个状态差异处报告路径和值，不通过修改 fixture 掩盖差异；地形效果、技能和跨关状态按 Godot 自身规则验证。

## 战役扩展方式

- `CampaignState` 只保存永久进度：已完成关卡、队伍、等级/经验、金钱、装备和剧情旗标。
- `BattleState` 只保存当前战场临时状态：单位位置、HP/MP、状态、回合和事件序号。
- `BattleState` 同时记录 `storyFlags`、`consumedEventIds` 和 `commandLog`；`eventFlags` 仅作为旧存档兼容字段。
- 关卡通过 `BattleDefinition` 注册，不把关卡 ID 写死在视图中。
- AI 通过策略接口替换：`AggressivePolicy`、`RangedPolicy`、`ProtectPolicy`，不把 AI 分支塞进 HUD。
- 规则效果最终抽象为可组合的 `Effect`/`Status`，避免每新增一个技能就修改渲染脚本。

## 分阶段路线

### P0：领域骨架（已完成）

- 数据仓库校验、战斗服务、事务命令、敌方阶段、版本化存档接口。
- headless smoke 覆盖数据加载、移动、非法命令回滚和结束回合。

### P1：表现层拆分（已完成）

- `BattleScene` 只负责生命周期和输入映射。
- `BoardView` 负责地形、单位、选择层和动画。
- `BattleHud` 负责单位详情、技能按钮、战斗记录。
- 删除旧表现层中的重复规则计算，所有操作改走 `GameSession.dispatch()`。

### P2：战役与存档（已完成）

- 首页/章节地图/编队界面、双关卡目录和解锁。
- `CampaignState`、经验/等级/金币奖励、版本校验与损坏存档 `.bak` 回退。
- 关卡胜利/失败后提交永久状态；战斗状态按命令自动保存并可中途恢复，未完成战斗不会发放奖励。

### P3：内容系统（已完成）

- 已实现装备属性注入、库存/槽位/兵种限制、战役界面换装与卸下。
- 已实现 `class_advancements.json` 驱动的兵种进阶、等级/金币/道具门槛和永久存档迁移。
- 已实现范围伤害/治疗、持续伤害与状态属性修正。
- 已实现带条件分支的剧情事件，以及可暂停战斗的对话节点和 `dialogue_choice` 命令。
- `tests/p3_smoke.gd` 覆盖换装、对话旗标、条件事件、兵种进阶和状态效果；数据 schema 校验会在启动时报告坏引用。

### P4：发行质量

- 固定种子回放、性能预算、输入防抖、断电/崩溃恢复、导出平台检查和完整回归。
- `tests/export_readiness.gd` 做静态发行门禁；它只验证项目、场景和数据完整性，不把未安装导出模板误报为已导出。

## 验收门槛

- 规则层可在 headless 下运行，不启动渲染器也能完成一局最小战斗。
- 非法命令不会改变快照；同一 seed + 同一命令序列得到相同事件序列。
- 存档版本不匹配时拒绝加载并保留旧文件。
- 新增一个关卡、技能或 AI 策略不需要修改 HUD 或棋盘绘制代码。
