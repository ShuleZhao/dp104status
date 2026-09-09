# dp104status

把 Claude Code 和 Codex 的工作状态显示在 Ticktype DP104 的点阵屏上。

屏幕 8×24 分成左右两半，各归一个 agent，颜色表示状态：

```
..#..#..#.......###.....     左：Anthropic 星芒 = Claude
...#.#.#.......#...#....     右：OpenAI 环     = Codex
....###.......#.....#...
..#######.....#..#..#...     蓝 = 在跑   橙 = 等你批准
....###.......#.....#...     绿 = 刚结束  灭 = 闲置
...#.#.#.......#...#....
..#..#..#.......###.....
........................
```

`./dp104status preview working waiting` 可以在终端里预览，不用碰硬件。

也可以切成单行滚动文字（`CLAUDE WORK  CODEX WAIT`），见下面的 display 配置。

没有 agent 在跑的时候，键盘还原成你自己的设置——不占用屏幕。

## 状态

每个产品两档，外加一个"需要你"：

| 显示 | 含义 | 触发事件 |
| --- | --- | --- |
| `WORK` | 在跑 | `UserPromptSubmit` `PreToolUse` `PostToolUse` `SubagentStart` |
| `WAIT` | 卡住了，等你批准 | `PermissionRequest` `Elicitation` |
| `DONE` | 本轮结束（默认显示 30 秒） | `Stop` |
| （不显示） | 闲置 | `SessionEnd`，或 TTL 过期 |

`WAIT` 优先级高于 `WORK`：任一会话在等你，就先告诉你这件事。

不区分成功和失败。Codex 目前没有失败专用 hook，硬做红灯只能靠猜文本，不如不做。

## 构建

零依赖，只要 Xcode Command Line Tools：

```bash
swiftc -O dp104status.swift -o dp104status
```

## 用法

```bash
./dp104status daemon                # 常驻，占用键盘并渲染状态
./dp104status hook <claude|codex>   # 从 stdin 读一个 hook 事件（由 agent 调用）
./dp104status status                # 打印当前会渲染成什么
./dp104status restore               # 把键盘还原成 baseline
./dp104status hooks <claude|codex>  # 打印要安装的 hook 配置
./dp104status config idle <mode>    # 闲置时屏幕停在哪个模式
./dp104status config display <d>    # pixel（图标分区）或 text（滚动文字）
./dp104status preview <a> <b>       # 终端预览图形，参数是两个 agent 的状态
./dp104status pixel-test            # 诊断 CDC 串口链路
```

### 显示方式

```bash
./dp104status config display pixel  # 默认，左右两个图标，走 CDC 串口
./dp104status config display text   # 单行滚动文字，只用 HID
```

pixel 需要 USB CDC 串口；串口连续失败 3 次会自动降级到 text，日志里会说明。

### 闲置模式

没有 agent 在跑时，屏幕停在哪个模式由 `~/.dp104status/config.json` 决定，默认 `info`：

```bash
./dp104status config idle info      # off type custom info spark audio scroll
./dp104status config idle restore   # 还原成 daemon 启动时看到的模式
```

文字槽无论如何都会还原成你自己的内容。

### 安装 hooks

Claude Code —— 把输出合并进 `~/.claude/settings.json`：

```bash
./dp104status hooks claude
```

Codex —— 桌面版没有 CLI，用本地 marketplace 注册 `codex/` 下的插件，
在 `~/.codex/config.toml` 里加两节：

```toml
[marketplaces.dp104status]
source_type = "local"
source = "/Users/skyler/Agent/dp104status/codex"

[plugins."dp104status@dp104status"]
enabled = true
```

改完要重启 Codex 才会加载。

### 开机自启

```bash
cp com.skyler.dp104status.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.skyler.dp104status.plist
```

停掉：

```bash
launchctl unload ~/Library/LaunchAgents/com.skyler.dp104status.plist
```

## 设计

```
Claude/Codex hook 事件
      ↓  (短命进程，flock 下原子写，然后立刻退出)
~/.dp104status/state.json
      ↓  (常驻 daemon 轮询，唯一的 HID 持有者)
DP104 点阵屏  (VIA CUSTOM_MENU_SET_VALUE)
```

**hook 进程绝不打开键盘。** 它解析事件、更新状态文件、退出，而且无论如何都 `exit(0)`——
键盘拔了、daemon 没开、状态文件锁不住，都不会让你的 agent 报错或变慢。

**daemon 是唯一的 HID 持有者。** 它保存用户原有的文字和屏幕模式到
`~/.dp104status/baseline.json`，接管时清空 slot 1–4 只留 slot 0 滚动，
闲置和退出时还原。`SIGTERM` 也会触发还原。

**不碰 flash。** 全程只发 VIA `CUSTOM_MENU_SET_VALUE` (0x07)，这是 RAM 写入、立即生效。
`CUSTOM_MENU_SAVE` (0x09) 一次都不发，所以高频状态变化不会磨损 EEPROM。

**热插拔。** 键盘消失时 daemon 继续运行并每 3 秒重试；插回来后强制重绘，
状态不会因为拔插而丢失。

**自愈。** daemon 缓存了"我以为屏幕在显示什么"以免每个 tick 都重写，但那个缓存
会因为别人动了键盘而失同步——按 `TJM_MOD` 键、VIA 网页、或者手动跑 `restore`。
所以它每 5 秒回读一次屏幕模式和 slot 0，跟缓存不符就重新写入，日志里会记一条
`screen changed externally ... reasserting`。

owner 键是 `{product}:{session_id}:{agent_id}`，子代理独立跟踪，
`Stop` 会连带清掉同会话的子 owner——避免子代理结束时整块屏幕闪一下 DONE。

协议细节见 `DP104-PROTOCOL.md`。

## 已知限制

- 只在 **USB 有线** 下验证过。2.4G / 蓝牙模式下 Raw HID 是否可用未测。
- 屏幕文本是 ASCII，30 字符上限，会自动转大写。
- daemon 用轮询（400ms）而不是文件监听，够用且简单。
