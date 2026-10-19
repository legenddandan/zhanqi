# 《汉末烽火》单机版架构

## 目标

项目采用 Godot 4.7.2 **单一运行时**，目标是可保存、可测试、可扩展的单机 SRPG。正式入口、规则服务、表现层、存档和运行时数据都在 `godot/`；早期浏览器原型已移除，历史差异仅保留在 `progress.md`。

## 单一运行时与 canonical 数据策略

`godot/` 是项目唯一运行时目录，`godot/data/` 是唯一 canonical 数据源。Godot 的 `DataRepository` 负责正式运行时的 JSON 版本、引用、棋盘、单位、目标和扩展字段校验；新增正式关卡、技能、地形、兵种和战役内容只编辑这里。

根目录浏览器原型、兼容数据快照和双端校验脚本已移除，不存在需要同步或比较的第二套运行时数据。历史阶段的浏览器差异和迁移过程保留在 [`progress.md`](../progress.md) 的历史条目中。

### 迁移规则

1. 正式数据只在 `godot/data/` 编辑。
2. 新增字段时同步更新 `DataRepository` 的 schema 校验和对应 Godot smoke。
3. 每次数据变更都运行 JSON 解析、数据仓库检查和 Godot headless smoke。

## 分层

```text
Main / BattleScene              表现层：输入、动画、HUD、地图绘制
        │ 只调用应用服务
GameSession                     应用层：组合依赖、启动战斗、派发命令、读快照
        │
BattleService                   领域层：回合、移动、攻击、技能、AI、胜负
        │ 只操作 BattleState，并输出事件
DataRepository / SaveRepository 基础设施：JSON 校验、版本化存档、原子写入
```

当前目录对应关系：

- `scripts/data/DataRepository.gd`：Godot canonical JSON 的唯一入口，校验 ID、引用、棋盘尺寸、单位位置、阵营和扩展字段。
- `scripts/domain/BattleService.gd`：不依赖 Node/Canvas 的战斗服务；命令在工作副本执行，成功后才提交。
- `scripts/domain/ObjectiveEvaluator.gd`：按关卡定义判定胜负目标和回合上限，不把“击败全部敌军”硬编码在战斗服务中。
- `scripts/domain/EnemyPolicy.gd` 及其策略实现：把敌方目标选择从战斗执行器中分离，关卡可通过 `rules.aiPolicy` 选择策略；`BattleService` 在目标合法、技能已 ready 且 MP 足够时执行确定性敌方主动技能。
- `scripts/save/SaveCoordinator.gd`：协调战役存档和战斗存档，任一写入失败时恢复旧快照。
- `scripts/app/GameSession.gd`：应用组合根，战役地图与战斗场景都通过它访问规则，并负责战斗恢复。
- `scripts/app/CampaignService.gd`：永久战役状态、编队、奖励、成长与关卡解锁。
- `data/equipment.json` / `data/statuses.json` / `data/class_advancements.json`：装备、持续状态和兵种进阶注册表；技能、关卡奖励通过稳定 ID 引用。
- `data/items.json`：消耗品注册表；营地商店与战斗道具效果都通过稳定 ID 引用。
- `data/terrains.json`：地形同时定义移动成本、防御/命中修正和回合恢复效果，规则层与表现层共用同一注册表。
- `scripts/save/SaveRepository.gd`：默认使用版本化 `user://saves` 存档，存储目录可注入；临时文件写完后再提交，提供 `.bak` 损坏回退。`GameSession` 的第二个构造参数用于 smoke 注入隔离临时目录。
- `scripts/presentation/BattleScene.gd`：Control 场景组合根，只负责生命周期、输入映射和命令派发。
- `scripts/presentation/BoardView.gd`：Control 视图，只绘制地形、单位和选择覆盖层。
- `scripts/presentation/BattleHud.gd`：Control HUD，只绘制状态面板和按钮区域。
- `scripts/presentation/InputController.gd`：把平台输入转成最小事件。
- `scripts/presentation/CampaignScene.gd`：战役目录、编队和继续战斗入口。
- `scripts/presentation/AudioManager.gd`：资源可选的音频门面；没有 `audio/*.ogg` 时保持静默，领域层不依赖音频资源。
- `legacy/MainLegacy.gd`：旧 Demo 表现层，仅作迁移对照，不再作为入口。

## 核心约束

1. **规则不读 UI**：领域层不能引用 `Node2D`、控件、纹理或输入事件。
2. **命令驱动**：移动、攻击、技能、结束回合都是 `{type, ...}` 命令；非法命令返回错误且不改变状态。
3. **事件驱动表现**：规则输出 `unit_moved`、`damaged`、`healed`、`unit_defeated`、`battle_ended` 等事件，表现层据此播放动画和音效。
4. **稳定 ID**：`characterId`、`classId`、`skillId`、`instanceId` 永不使用显示名称替代；重命名不会破坏存档。
5. **版本化数据**：JSON、战斗状态、存档都有 schema version；升级时提供迁移函数，不静默丢字段。
6. **可复现战斗**：战斗服务使用显式随机种子，录制命令序列即可复盘或定位 AI 问题。
7. **失败安全**：读取坏数据回报明确错误；命令事务失败回滚；存档采用临时文件后原子改名。

### Godot 回放 smoke fixture

`data/replays/replay-parity.json` 是当前最小回放 smoke 契约。每个 scenario 包含完整的 `battle`、固定 `commands` 和共享 `seed`；Godot 通过 `ReplayService` 执行，并逐步检查 `mode`、`phase`、`turn`、单位状态、`enemyMovement` 和 `enemySkill` trace。敌方技能 trace 至少包含技能 ID、目标、MP 消耗和受影响单位；文件名保留历史兼容性，但当前不再表示跨运行时比较。

该摘要刻意不包含表现日志、剧情旗标、存档字段或 RNG 内部状态。Godot smoke 在首个状态差异处报告路径和值，不通过修改 fixture 掩盖差异；地形效果、技能和跨关状态按 Godot 自身规则验证。

## 战役扩展方式

- `CampaignState`（下一阶段加入）只保存永久进度：已完成关卡、队伍、等级/经验、金钱、装备和剧情旗标。
- `BattleState` 只保存当前战场临时状态：单位位置、HP/MP、状态、回合和事件序号。
- `BattleState` 同时记录 `storyFlags`、`consumedEventIds` 和 `commandLog`；`eventFlags` 仅作为旧存档兼容字段。
- 关卡通过 `BattleDefinition` 注册，不把关卡 ID 写死在视图中。
- AI 通过策略接口替换：`AggressivePolicy`、`RangedPolicy`、`ProtectPolicy`，不把 AI 分支塞进 HUD。
- 规则效果最终抽象为可组合的 `Effect`/`Status`，避免每新增一个技能就修改渲染脚本。

## 分阶段路线

### P0：领域骨架（Godot 主线已完成）

- 数据仓库校验、战斗服务、事务命令、敌方阶段、版本化存档接口。
- headless smoke 覆盖数据加载、移动、非法命令回滚和结束回合。

### P0.5：运行时与数据源收口（阶段 0）

- Godot 已收口为唯一运行时，`godot/data/` 为唯一 canonical 数据源。
- 根目录浏览器原型、兼容快照和双端校验脚本已移除；历史差异仅保留在 `progress.md`。
- 当前正式基准为 12×10、5V5 的 `yingchuan-01`；历史 8×8 记录只保留在 `progress.md` 的开发日志中。

### P1：表现层拆分（已完成）

- `BattleScene` 只负责生命周期和输入映射。
- `BoardView` 负责地形、单位、选择层和动画。
- `BattleHud` 负责单位详情、技能按钮、战斗记录。
- 删除旧表现层中的重复规则计算，所有操作改走 `GameSession.dispatch()`。

### P2：战役与存档

- 首页/章节地图/编队界面、双关卡目录和解锁。
- `CampaignState`、经验/等级/金币奖励、版本校验与损坏存档 `.bak` 回退。
- 关卡胜利/失败后提交永久状态；战斗状态按命令自动保存并可中途恢复，未完成战斗不会发放奖励。

### P3：内容系统（已完成）

- 已实现装备属性注入、库存/槽位/兵种限制、战役界面换装与卸下。
- 已实现 `class_advancements.json` 驱动的兵种进阶、等级/金币/道具门槛和永久存档迁移。
- 已实现范围伤害/治疗、持续伤害与状态属性修正。
- 已实现带 `requiresFlags`、`forbiddenFlags`、`minTurn`、`setFlags` 的条件剧情事件，以及可暂停战斗的对话节点和 `dialogue_choice` 命令。
- `tests/p3_smoke.gd` 覆盖换装、对话旗标、条件事件、兵种进阶和状态效果；数据 schema 校验会在启动时报告坏引用。

### P4：发行质量

- 固定种子回放、性能预算、输入防抖、断电/崩溃恢复、导出平台检查和完整回归。

#### P4-A（进行中）

- 已完成目标判定器：支持 `defeat_all`、`all_units_dead`、`defeat_unit`、`protect_unit`、`survive_turns`、`reach_tile`、`capture_tile` 和 `maxTurns`。
- 关卡目标由 `BattleDefinition.objectives` 驱动；没有配置目标的旧关卡仍回退到“全歼敌军/我方全灭”。
- `tests/objectives_smoke.gd` 覆盖胜利、失败和回合上限目标。
- 已完成 `EnemyPolicy` 策略接口，当前有 aggressive、ranged、protect 三种策略。
- 已完成 `SaveCoordinator` 双存档回滚协调；战斗命令保存失败会恢复内存状态。
- 已加入剧情旗标/已消费事件分离、命令日志和可选的跨关卡 HP/MP 继承。
- 已加入显式关卡解锁、地形效果、状态抗性、营地休整和更强的存档结构校验。
- 多目标/护送关卡可使用 `protect_unit`、`reach_tile`、`capture_tile` 和 `survive_turns` 目标组合表达。
- 已加入基础消耗品、营地补给商店和战斗中使用道具。
- 已完成装备品质、复制数量、购买上限和装备/消耗品商店；`inventoryCounts` 与旧 `inventory` 数组并存以兼容旧存档。
- 已完成场景根、棋盘和 HUD 的 Control 化，保留数据驱动绘制以便后续替换为更细粒度的控件/主题。
- 已加入资源可选的 `AudioManager` 和移动/攻击/技能/道具/胜负/UI 语义事件接口，不生成假的音频资源。
- 已加入阶段 1 最小 Godot 回放 smoke fixture；固定 seed 下对移动、普通攻击、结束回合和终局摘要逐步检查，首个分歧会直接报告。
- 已将 Godot 敌方“一格逼近”替换为按可通行性、单位阻挡、地形 `moveCost` 和移动点数搜索的确定性 Dijkstra 路径；无法继续时保留最近可达格，并在战斗事件与 `ReplayService` trace 中记录路径、成本和最终位置。核心 smoke 覆盖绕障碍、地形成本、不可达和单位阻挡。
- 已加入阶段 1 敌方技能最小契约：敌方只从 `implementation: "ready"` 的主动技能中选择，在 MP 足够、目标类型/射程合法时执行攻击或支援效果；技能会消耗 MP、结束敌方行动，并输出 `enemy_skill` 事件。`ReplayService` 将其规范化为 `enemySkill` trace；核心 smoke 覆盖合法使用、MP 消耗、目标效果、低 MP 不可用和回放追踪。
- 已加入 `tests/export_readiness.gd` 静态发行门禁；它只验证项目、场景和数据完整性，不把未安装导出模板误报为已导出。

## 验收门槛

- 规则层可在 headless 下运行，不启动渲染器也能完成一局最小战斗。
- 非法命令不会改变快照；同一 seed + 同一命令序列得到相同事件序列。
- 存档版本不匹配时拒绝加载并保留旧文件。
- 新增一个关卡/技能/AI 策略不需要修改 HUD 或棋盘绘制代码。

