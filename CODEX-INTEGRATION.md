# 已解决：Codex hook 未触发

## 结论

根因是 **hook 已被加载，但还没有被用户信任**，不是插件注册、二进制路径或
`command` handler 不受桌面版支持。

Codex 0.153.4 的 App Server `hooks/list` 对本插件返回了 8 个 hook，每个都是：

- `source: plugin`
- `pluginId: dp104status@dp104status`
- `handlerType: command`
- `enabled: true`
- `trustStatus: untrusted`

在 Codex CLI 的 `Hooks need review` 界面批准后，同一查询的 8 个结果全部变为
`trustStatus: trusted`。

## 修复步骤

插件 marketplace 在本仓库的 `codex/` 目录。首次安装时：

```bash
swiftc -O dp104status.swift -o dp104status
codex plugin marketplace add /absolute/path/to/dp104status/codex
codex plugin add dp104status@dp104status
```

然后在本仓库中启动 CLI：

```bash
codex --no-alt-screen
```

1. 如果 Codex 询问是否信任目录，选 `Yes, continue`。
2. 在 `Hooks need review` 界面检查 8 条命令。
3. 确认命令都是 `<repo>/dp104status hook codex` 后，选
   `Trust all and continue`。
4. 退出 CLI，在 Codex 桌面版新建一个任务。

信任结果会以每条 hook 的内容哈希写入 `~/.codex/config.toml` 的
`[hooks.state]`。不要手动填写或复制这些哈希；命令、超时或其他 hook 内容一旦改变，
Codex 会把对应项标记为 `modified`，并要求重新审批。

## 插件结构

Codex 从 `.codex-plugin/plugin.json` 的顶层 `hooks` 字段加载这 8 个定义：

```text
codex/
  .agents/plugins/marketplace.json
  plugins/dp104status/
    .codex-plugin/plugin.json
```

之前同时存在的 `hooks/hooks.json` 没有出现在 `hooks/list` 的 `sourcePath` 中，
已删除，避免让人误以为两份定义都会生效。

Codex 桌面版确实支持 `command` handler，不需要为此改成 MCP server，也不需要
监听私有的 rollout JSONL。

`SessionEnd` 在当前 Codex 中的超时上限是 3 秒。manifest 和
`./dp104status hooks codex` 的输出都使用 3 秒，其他事件保持 5 秒。

## 更新插件

本地开发中修改 hook 后，需要刷新插件缓存、重装并重新审批变更的 hook。
请使用 Codex 插件工具生成 cachebuster，然后：

```bash
codex plugin add dp104status@dp104status
codex --no-alt-screen
```

已打开的任务可能保留启动时的 hook 快照，所以最后要用一个新任务验证。

## 验证

下游状态机可以先手动测试：

```bash
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","agent_id":"main"}' \
  | ./dp104status hook codex
./dp104status status            # -> CODEX WORK
echo '{"hook_event_name":"SessionEnd","session_id":"t1","agent_id":"main"}' \
  | ./dp104status hook codex
```

完整链路验证：

```bash
./dp104status daemon            # 也可以由 launchd 启动
# 在 Codex 桌面版的新任务里发一条消息，然后在另一个终端查看：
cat ~/.dp104status/state.json   # 运行期间应出现 codex:<session>:main
./dp104status status            # 运行期间应显示 CODEX WORK
```

如果修改过 hook 后又不触发，先重新运行 `codex --no-alt-screen` 检查是否出现
`Hooks need review`，不要先改成 MCP 或转去解析会话日志。
