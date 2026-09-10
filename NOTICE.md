# 来源说明

本项目使用 **GPL-3.0-only**（见 `LICENSE`）。这份文件说明 DP104 的通信协议是
怎么得到的，以及哪些第三方项目影响了本项目——既是致谢，也是为了把来源交代清楚。

本项目与 Ticktype、NuPhy、Anthropic、OpenAI 均无关联，也未获得它们的背书。
"Claude"、"Codex"、"Anthropic"、"OpenAI"、"Ticktype" 是各自所有者的商标，
此处仅用于指代对应的产品。

---

## Ticktype DP104 通信协议

`DP104-PROTOCOL.md` 记录的协议**没有**来自任何官方文档。厂商没有公开发布规格。

它是这样得到的：Ticktype 的配置器 <https://cfg.ticktype.com> 是
[VIA](https://github.com/the-via/app) 官方 web 应用的自托管分支。阅读它公开提供的
前端 JavaScript 打包文件，并在实机上反复验证，从中确定了：

- VIA 自定义菜单的命令编号（`0x07` 设置 / `0x08` 读取 / `0x09` 保存）
- 厂商扩展命令 `0xBF` / `0xD0` / `0xD1`
- channel 与 value 的地址映射（背光 22、底灯 21、点阵屏 26）
- 33 字节 HID 报文与 64 字节 CDC 定长包的帧格式
- 像素载荷的 HSV 编码与"帧 → 行 → 列"排列顺序
- 设备参数（8×24 点阵、5 个文本槽 × 30 字符），读自该站点提供的
  `/tabkb/configs.json`

**没有复制任何代码。** 上述内容是设备接口的事实——命令编号、字节布局、
地址映射、数学换算——本仓库中的 Swift 与 Python 实现均为独立编写。

需要说明的是，这不是"净室"逆向：同一个人既读了原始 JavaScript，也编写了实现，
而非由一人撰写规格、另一人据以实现。

**VIA 本身采用 GPL-3.0。** 本项目选择 GPL-3.0-only，一方面出于对该生态的尊重，
另一方面也让"是否构成衍生作品"这个问题不必再争论。

---

## 设计参考

### [BarryBarrywu/Keyphore](https://github.com/BarryBarrywu/Keyphore) — GPL-3.0-only

一个把 Codex 任务状态显示在 NuPhy Air65 V3 背光上的 macOS 项目。
本项目的整体架构受它启发，**阅读但未复制其代码**：

- hook 进程只写持久化状态后立即退出，绝不打开键盘；由单一常驻进程独占硬件
- owner 键采用 `{product}:{session_id}:{agent_id}`，子代理独立跟踪
- 接管硬件前保存用户原有设置，退出与闲置时还原
- 只写 RAM、不写 EEPROM，避免高频状态变化磨损 flash
- 按状态分级的 TTL，以及"等待批准"优先于"执行中"的聚合顺序

它的 `docs/research/codex-keyboard-status-projects.md` 调研了十余个同类项目，
本项目状态机的优先级设计参考了其中的结论。

Keyphore 面向的是 NuPhy 键盘的 NuPhyIO 协议，与 DP104 无技术重叠——
本项目未使用其任何协议实现。

### 调研中参考过的其他项目

以下项目在设计阶段作为行为参考被阅读，未使用其代码：

- [fldc/nuphyctl](https://github.com/fldc/nuphyctl) — MIT
- [Pixelmoss/codex-kick75-status-lights](https://github.com/Pixelmoss/codex-kick75-status-lights) — MIT
- [Sora-bluesky/kbd-signal](https://github.com/Sora-bluesky/kbd-signal) — MIT
- [DevVig/microbridge](https://github.com/DevVig/microbridge) — MIT

---

## 图形

屏幕上的两个图形是为 7×7 点阵重新绘制的简化标记，用于区分左右两半分别对应
哪个 agent。它们不是 Anthropic 或 OpenAI 的官方标识，也不应被当作官方标识使用。
