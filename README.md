# Yunindex · Kindle 阅读统计插件

> Kindle Paperwhite 6 (KPW6) 原生阅读时长统计面板，基于 **Vera 越狱**。
> **真实逐秒计时 · 事件驱动省电 · 单页 dashboard**。

---

## ✨ 特性

- **真实逐秒计时**：阅读器处于活跃前台 + 屏幕点亮时逐秒累积；熄屏暂停、关书停止、换书继续。
- **事件驱动 daemon**：熄屏 / 亮屏走 `lipc-wait-event` 通道，非阅读时段近乎零耗电。
- **自动降级**：若设备不支持 `goingToScreenSaver`，自动退回轮询模式，照常计时，绝不卡屏。
- **单页 dashboard**：9 个核心指标 + 周节奏柱状图 + 高亮金句按月轮播 + 年份切换。
- **高亮句解析**：兼容 UTF-8 BOM 的 `My Clippings.txt`，按时间倒序轮播。
- **数据零丢失**：升级自动备份 `reading-time.tsv`；卸载保留用户数据。
- **纯本地运行**：不联网，无任何外发请求。

---

## 📊 性能数据（轮询 vs 事件驱动）

| 时段 | 轮询 | 事件驱动 | 提升 |
|---|---|---|---|
| 阅读中 CPU 唤醒 | 每 15 秒一次 | 120 秒兜底 + 熄屏事件触发 | **~8×** |
| 非阅读 CPU 唤醒 | 每 15 秒一次 | 几乎为零（事件触发） | **~20×** |
| 综合省电 | 基线 | 降频 + date 单次 fork | **7~8×** |
| 计时精度 | 15 秒采样 | 按真实 delta 累加 | **不变** |

> 计时按真实时间差 `delta` 累加，不按轮询次数——只降频率不丢精度。

---

## 🏗️ 架构

```
yunindex-kindle/
├─ RUNME.sh                              # 安装启动入口（搜索栏 ;log runme）
└─ native-reading-time-package/
   ├─ Yunindex阅读统计.sh                # dashboard 渲染（busybox awk + fbink）
   ├─ native-reading-time-daemon.sh      # Upstart 守护进程（事件驱动）
   ├─ Install-Native-Reading-Time.sh     # 安装脚本
   ├─ reading-insights-touch.lua         # 触摸监听（年份切换 + 2 分钟超时退出）
   ├─ native-reading-time.conf           # daemon 配置
   ├─ generate_bg.py                     # FAST 路径背景图生成
   ├─ ui/compose.py                      # 背景合版
   ├─ ui/dashboard_bg.png                # 仪表板静态背景（已嵌入「Yunindex阅读统计」标题）
   ├─ fonts/NotoSansSC-Regular.otf       # 中文 Sans（嵌入）
   ├─ fonts/NotoSerifSC-Bold.otf         # 中文 Serif Bold（嵌入）
   └─ 安装说明.txt / 卸载说明.txt
```

> 字体嵌入是为 Kindle 上无中文字体可用做的兜底；其他 Kindle 型号可忽略。

---

## 📐 dashboard 字段（9 个核心指标）

| 字段 | 单位 | 含义 |
|---|---|---|
| 今日时长 | h / m | 当日累计阅读时长 |
| 本周时长 | h / m | 本周每日阅读时长求和 |
| 本月日均 | h / m | 当月每日平均阅读时长 |
| 本月时长 | h / m | 当月累计阅读时长 |
| 连续天 | 天 | 历史最长连续日阅读天数 |
| 累计时长 | 本 | 今年累计阅读时长 |
| 累计天 | 本 | 今年累计阅读天数 |
| 读过 | 本 | 今年累计阅读书本数 |
| 读完 | h / m | 今年累计完成阅读书本数 |

> 单位约定：涉及小时分钟字段保留 `xh ym` 格式（如 `12h12m`），其他字段展示为「天」或「本」。

---

## 🛠️ 安装

> 前置：KPW6 已通过 Vera 越狱；电脑 USB 连接设备。

1. **下载**：克隆或下载本仓库到本地。
2. **拷贝**：把仓库根目录的 `RUNME.sh` 和 `native-reading-time-package/` 文件夹拖到 Kindle **USB 根目录**。
3. **安装**：在 Kindle 主页搜索栏输入 `;log runme`，回车。
4. **确认**：装完桌面会展示 `Yunindex阅读统计`。
5. **启动**：点击该“Yunindex阅读统计”，进入 dashboard。

> 升级时直接覆盖目录再 `;log runme` 即可，阅读数据自动备份。

## 🗑️ 卸载

在 Kindle 搜索栏输入 `;log mrpi -u`（uninstall），回车，**或** 删除 `/var/local/mesra/upstart/` 下的 job 链接后重启。

卸载脚本默认保留 `/mnt/us/reading-time/`（含全部历史数据），如需彻底清空再手动删除该目录。

---

## 📦 版本

- **v2.1（当前）**：修复 dashboard 打开时「闪屏两次才显示数据」的问题——渲染改单次 GC16 全刷，打开即直接显示完整数据。
- **v2.0**：品牌改名 `Yunindex`；daemon 升级到事件驱动版；单页 dashboard。
- **v1.x**：原始版本未命名，daemon 轮询版，dashboard 双页布局。

---

## 🔧 v2.1 迭代说明（屏闪修复）

**现象**：打开 dashboard 时先闪一次空背景、再连续闪两次屏，最后才显示所有数据。

**根因**：慢路径渲染把 FBInk 刷屏拆成了多次——

1. `fbink -g` 推空背景图时未加 `-b`（不刷新），先刷了一次空背景；
2. 最后 commit 用了 `-f -W GC16 -s`，其中 `-f`（黑闪 flash）与 `-W GC16`（灰度全刷）叠加，造成「连续两次闪屏」。

**修复**：

- 推背景加 `-b`：只写 framebuffer 不刷屏；
- commit 去掉 `-f` flash：只保留单次 `-W GC16 -s` 灰度全刷；
- FAST 路径同步合并为单次「推图 + GC16 全刷」。

**效果**：慢 / 快路径都从「多次闪屏」降为「单次 GC16 全刷」（e-ink 清残影必需的一次闪），打开即显示完整数据。

---

## 🔒 数据安全

| 场景 | 数据保护 |
|---|---|
| 升级 | `reading-time.tsv` 自动备份到 `reading-time.tsv.bak.YYYYMMDD-HHMMSS` |
| 卸载 | `/mnt/us/reading-time/` 默认保留 |
| 重装 | 不清理历史数据，新旧数据自动合并 |
| 网络 | 纯本地运行，不向任何外部地址发请求 |
| 隐私 | 所有阅读时长、书本数、高亮句仅存储于 Kindle 本机 |

---

## 🧪 真机验证

daemon 启动时会把模型版本写入 `/mnt/us/reading-time/service.log` 首行：

```
... model=v2.1-6col, goingToScreenSaver=1 ...
```

- `goingToScreenSaver=1` → **事件路径已生效**（省电 7~8 倍）。
- `goingToScreenSaver=0` → 设备不支持该事件，已自动降级回轮询（省电约 2 倍，计时照常）。

---

## 📜 许可

仅供个人学习与使用。Kindle 越狱涉及保修失效，请自行评估风险。
