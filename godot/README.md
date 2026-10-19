# 《汉末烽火》Godot 主线

这是项目的唯一正式运行时，使用 Godot 4.7.2 Standard。项目入口、规则服务、存档、表现层和全部运行时数据都在本目录；浏览器原型及其兼容数据已移除。

Godot 通过 `DataRepository` 从本目录的 `data/` 加载唯一 canonical 数据。架构和数据契约见 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

## 打开/运行

在 Godot 项目管理器中导入本目录，或在终端运行：

```sh
/Applications/Godot.app/Contents/MacOS/Godot --editor --path /Users/wxl/code/game/zhanqi/godot
```

按 F6/F5 运行项目主场景 `Campaign.tscn`；战斗场景由战役入口进入。

## 当前可玩内容

- 颍川之战：12×10、河流/桥梁/道路/林地/山地/村庄/农田等地形。
- 5V5 单位、等级成长、HP/MP、移动范围、普通攻击、命中与伤害计算。
- 步兵护卫/坚守、骑兵冲锋/机动、弓箭手精准射击/远射、法师火焰术/冥想、医生治疗/医术。
- 敌方回合的确定性追击 AI：在合法射程且 MP 足够时优先使用已实现的攻击/支援主动技能，否则移动并普通攻击；技能事件会写入战斗记录和回放 trace。
- 战役进度、队伍编成、关卡解锁、金币奖励、战斗经验/升级和自动存档。
- 战斗中途会保存到 `user://saves/campaign-1.battle.json`，重新启动后可继续；存档写入带临时文件和 `.bak` 回退。
- P3 内容：装备属性与换装、兵种进阶、范围技能、中毒/灼烧等持续状态、带条件分支的剧情对话与战斗记录。
- 低优先级内容：装备品质/数量/价格与购买、Control 场景 UI、可选音频事件门面、导出前静态检查。

架构说明见 [`ARCHITECTURE.md`](ARCHITECTURE.md)。旧版单脚本切片保存在 `legacy/MainLegacy.gd`，不再作为项目入口。

## 操作

- 点击我方单位，再点击蓝色格移动；移动后点击红色目标攻击。
- 右侧点击主动技能，再点击红色目标。
- `E` 或右侧按钮结束我方回合；`R` 重置；`ESC` 清除选择。

导出模板暂未安装；开发和运行编辑器不需要它。

发行前可运行：

```sh
godot --headless --path . --script tests/export_readiness.gd
```

该检查不会替代安装导出模板或实际各平台导出。

## 回放 smoke

固定 seed 回放 fixture 位于 `data/replays/replay-parity.json`，由 `tests/replay_parity_smoke.gd` 执行。它覆盖移动、普通攻击、结束回合、胜利/失败和敌方多步地形寻路；每一步检查 Godot 自身的状态摘要，并在敌方主动技能执行时记录 `enemySkill` trace（技能 ID、目标、MP 消耗和受影响单位）。文件名保留历史兼容性，但当前不再表示跨运行时比较。

```sh
godot --headless --path . --script tests/replay_parity_smoke.gd
```

## 当前限制

- 阶段 1 只以 `yingchuan-01` 的核心战斗闭环作为验收目标；第二关和完整战役扩展已接入目录，但不代替核心规则稳定性。
- 正式音频资源、最终主题化 UI、导出模板和平台发布检查仍属于后续发行质量阶段。
