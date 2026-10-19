# 《汉末烽火》

《汉末烽火》是一款以三国战棋为题材的单机 SRPG 原型。当前项目采用 Godot 4.7.2 Standard 单一运行时，正式项目入口和全部运行时数据都位于 [`godot/`](godot/)。

## 当前主线

- **唯一运行时：Godot 4.7.2 Standard**，入口为 [`godot/Campaign.tscn`](godot/Campaign.tscn)。它承载战役、战斗、存档、装备、剧情事件和后续发行工作。
- **canonical 数据：** [`godot/data/`](godot/data/)。Godot 的 `DataRepository` 是正式数据入口，负责版本、引用、棋盘、单位、目标和战役扩展字段的校验。
- **当前基准战场：**“颍川之战 · 河桥争夺”，12×10 棋盘，双方各 5 个单位。

浏览器原型、根目录兼容数据、浏览器测试和双端校验脚本已从当前项目移除。早期浏览器实现和跨运行时 parity 的过程记录保留在 [`progress.md`](progress.md) 中，并明确标注为历史。

## 运行 Godot 主线

在 Godot 项目管理器中导入 `godot/`，或从仓库根目录运行：

```sh
godot --editor --path godot
```

按 F6/F5 运行主场景 `Campaign.tscn`。无头检查：

```sh
godot --headless --path godot --script tests/architecture_smoke.gd
godot --headless --path godot --script tests/core_rules_smoke.gd
godot --headless --path godot --script tests/replay_parity_smoke.gd
godot --headless --path godot --script tests/p3_smoke.gd
godot --headless --path godot --script tests/objectives_smoke.gd
godot --headless --path godot --script tests/low_priority_smoke.gd
godot --headless --path godot --script tests/export_readiness.gd
```

Godot 的完整操作和限制见 [`godot/README.md`](godot/README.md)。导出模板目前不随仓库提供，`export_readiness.gd` 只做静态门禁，不伪造平台导出成功。

## 快速检查

```sh
node --input-type=module -e "import fs from 'node:fs'; for (const path of fs.readdirSync('godot/data', {recursive:true}).filter((p) => p.endsWith('.json'))) JSON.parse(fs.readFileSync('godot/data/' + p, 'utf8')); console.log('Godot JSON OK')"
```

[`godot/data/replays/replay-parity.json`](godot/data/replays/replay-parity.json) 是 Godot 内部回放 smoke fixture，供 [`godot/tests/replay_parity_smoke.gd`](godot/tests/replay_parity_smoke.gd) 验证固定 seed、命令序列、状态摘要和敌方移动 trace 的可重复性。文件名保留历史兼容性，但当前不再表示跨运行时比较。

项目设计、运行时架构、当前阶段验收标准和历史记录分别见 [`DESIGN.md`](DESIGN.md)、[`godot/ARCHITECTURE.md`](godot/ARCHITECTURE.md) 与 [`progress.md`](progress.md)。
