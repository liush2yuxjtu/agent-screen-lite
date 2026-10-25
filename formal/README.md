# formal/ — agent-screen-lite 最小 TLA+ Spec

## 建模什么

对应产品约束（见仓库 README tools）：

1. **生命周期**：`screen_create` → (`screen_move_app` | `screen_capture`)* → `screen_destroy`。
2. **具名虚拟屏**：`live` 集合表示已创建且未销毁的 display id。
3. **禁止**：destroy 后再 capture/move；双重 destroy；move/capture 未知 id。

## 不变量（产品语义）

| 不变量 | 含义 |
| --- | --- |
| `Inv_LiveBounded` | 同时存活的虚拟屏不超过 `MaxLive` |
| `Inv_LiveSubsetIds` | 每个 live id 都属于候选 `DisplayIds`（曾可被 create） |
| `Inv_OkTargetsLiveOrCreate` | 成功的 move/capture 只打 live id；成功 destroy 后 id 已不在 live |
| `Inv_RefusedImpliesNotLive` | 拒绝的 move/capture/destroy 针对非 live id |
| `TypeOK` | 状态类型正确 |

产品直译：

- 每个 live display **已被 create 且尚未 destroy**
- **只能**对 live id 做 capture / move_app
- **不能** double-destroy / move 到 unknown id

## 如何跑 TLC

```bash
java -cp tla2tools.jar tlc2.TLC -config Spec.cfg Spec.tla
```

本 box 已用 OpenJDK 21 + tla2tools 跑过 TLC：**PASS**。仓库以 `/verify`（`.agents/skills/verify/SKILL.md`）为合并门禁；`formal/` 存在时 `tla_formal` 必过（缺 jar/Java → FAIL，不是 SKIP）。

## 范围

不建模 Accessibility、PNG 像素、restore/checkpoint、私有 CGVirtualDisplay 细节。只覆盖 **命名虚拟屏生命周期安全**。
