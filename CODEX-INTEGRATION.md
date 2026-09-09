# 待解决：Codex hook 没有触发

Claude Code 一侧已经完全跑通。Codex 一侧插件能被加载，但生命周期事件从未到达
`dp104status hook codex`，所以屏幕右半边（OpenAI 环）永远是熄的。

## 现象

Codex 正在跑任务时，`~/.dp104status/state.json` 里没有任何 `codex:` 开头的 owner。

## 已经排除的原因

| 检查项 | 结果 |
| --- | --- |
| 插件是否被加载 | ✅ 已materialize 到 `~/.codex/plugins/cache/dp104status/dp104status/0.1.0/`，八个事件都在 |
| `config.toml` 写法 | ✅ 与官方插件的 `[plugins."name@marketplace"] enabled = true` 完全一致 |
| 是否需要重启 | ✅ 插件缓存写于 14:38:54，Codex app-server 启动于 14:49:18，晚于它 |
| hook 可执行文件 | ✅ 手动 `echo '{...}' \| dp104status hook codex` 正常写入状态并点亮屏幕 |
| 二进制路径 | ✅ `plugin.json` 里是绝对路径，文件存在且可执行 |

也就是说：**链路两端都正常，缺的是 Codex 真正去调用它。**

## 当前实现

marketplace 根目录在本仓库的 `codex/`：

```
codex/
  .agents/plugins/marketplace.json
  plugins/dp104status/
    .codex-plugin/plugin.json      # hooks 内联在 "hooks" 键下
    hooks/hooks.json               # 同样的 hooks，独立文件
```

两种写法同时存在，因为不确定这个 Codex 版本读哪一个。状态机对重复事件是幂等的，
所以即使两边都生效也不会出错。

注册方式（已写入 `~/.codex/config.toml`）：

```toml
[marketplaces.dp104status]
source_type = "local"
source = "<仓库路径>/codex"

[plugins."dp104status@dp104status"]
enabled = true
```

## 最可能的原因

**Codex 需要用户显式批准 hook。** 参考项目 [Keyphore](https://github.com/BarryBarrywu/Keyphore)
的 README 明确描述了这一步："Review and approve the Hooks. Setup presents the eight
task-event definitions before enabling them"，并且批准后需要重新加载 Codex。
它还有一条专门的 ADR 讲"不静默信任 Hook"。

但在当前 Codex 桌面版里没有找到这个批准入口，`~/.codex/.codex-global-state.json`
里也搜不到 `hookTrust` / `trustedHooks` / `hookConsent` 之类的键。

## 次要疑点

官方 bundled 插件（如 `browser`）的 hook 用的是 `"type": "mcp_tool"`，
而本插件用的是 `"type": "command"`——后者是从 Keyphore 抄来的，那是给 **Codex CLI**
用的写法。桌面版是否支持 `command` 类型的 plugin hook，没有直接证据。

## 建议的排查方向

1. 找出桌面版 Codex 的 hook 批准/信任入口，或确认它不存在
2. 确认桌面版是否支持 `"type": "command"` 的 plugin hook；如果只支持 `mcp_tool`，
   需要改成一个极小的 MCP server 来接收事件再转写状态文件
3. 查 Codex 自己的日志（`~/.codex/logs_*.sqlite`，注意需要只读方式打开）
   看有没有 hook 注册或拒绝的记录
4. 兜底方案：放弃 hook，改为监听 `~/.codex/sessions` 的 rollout JSONL
   （Microbridge 的做法）。不依赖 hook，但会耦合私有日志格式，随版本变化易碎，
   因此只作为最后手段

## 验证方法

```bash
swiftc -O dp104status.swift -o dp104status
./dp104status daemon &          # 或用 launchd
# 在 Codex 里跑一个任务，然后：
cat ~/.dp104status/state.json   # 应出现 codex:<session>:main
./dp104status status            # 应显示 "CODEX WORK"
```

手动注入事件可以确认下游一切正常（这条现在就能通过）：

```bash
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","agent_id":"main"}' \
  | ./dp104status hook codex
./dp104status status            # -> CODEX WORK
echo '{"hook_event_name":"SessionEnd","session_id":"t1","agent_id":"main"}' \
  | ./dp104status hook codex
```
