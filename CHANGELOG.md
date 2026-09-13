# Yunindex阅读统计 改动清单

> v2.4：跨年归档 + 全链路提速。v2.3：阅读排行页（rank）首发。Dashboard 按年统计；Ranking 强制跨年汇总，不串味。

## ✦ v2.5（2026-09-10）排行空白根因修复 + 删除 python 死路径 + 计时精度大修

**根因**（真机 rank-debug.log 实锤）：Vera/KPM 偶发同秒重复拉起 launcher（`rank_start`/`dashboard_start`
同时间戳成对出现）→ 两个并发实例共用同一个 `RANK_CACHE.tmp` → 竞态把聚合缓存写成「仅 header」→
后续 HIT 该缓存时本页行数=0 → 排行整页空白。这解释了「切日均正常（换 key 重建）、来回切又空白
（回到坏缓存）、首次进入空白（首建即被并发写坏）」的全部症状。

1. **单实例锁「后来者接管」**：launcher 入口 mkdir 原子锁 + PID 文件。旧实例存活时 kill 接管
   （TERM→3s→-9），杀触发旧实例 EXIT trap 顺带 restore_system_ui——同时根治真机实锤的另一症状：
   反复快速打开/退出后旧实例 trap 卡在 lipc 阻塞里僵死滞留，KPM 认为 scriptlet 仍在运行，
   再点图标闪一下回主页、永不 exec 新进程（只能锁屏重置）。3 次抢锁失败兜底放行，
   宁可放行也不让用户打不开。本地模拟活进程持锁场景验证接管成功。
2. **缓存原子写**：`RANK_CACHE.tmp` 加 PID 后缀（`.tmp.$$`），拼 header 后 `mv` 原子替换——
   并发实例互不踩踏，读者只会见到完整的旧/新缓存。
3. **坏缓存自愈**：HIT 校验追加「数据行数 ≤1 视为坏缓存 → 强制重建」——设备上已存在的坏缓存
   无需手动删除，打开一次排行页即自动重建。
4. **删除全部 python 路径**（launcher 1813→1477 行）：PY3 探测段、calc/排行 python heredoc、
   FAST_PY 探测段（每次启动 find 扫描 7 个目录找 PIL 的开销一并消除）、compose.py 快通道分支、
   `ui/compose.py` 文件、安装脚本 PIL 探测与 compose.py 拷贝/校验，全链路清干净。真机
   `fast path OFF python=` 证实 KPW6/Vera 5.19.03 无 python3，这些代码从未执行；统计与渲染统一
   awk + fbink 单路径，双口径漂移风险消除。`_diagnose.sh` 的 python 环境探测（排障信息用）与
   `UNINSTALL.sh` 的 `.fast_python` 历史缓存清理予以保留。

5. **阅读态功耗再降 ~85%**（daemon 进程创建 360 次/小时 → ~50 次，计时精度不变）：
   - 同书解析缓存：每周期只查 activeContext（1 次 prop）作换书指纹，串没变就跳过 read_book
     全部解析（含 metadata 查询，再省 1 fork/周期）；metadata 是完整 JSON 可能带动态字段，
     不宜作缓存键。模拟：同书 10 分钟仅解析 1 次，切书立即重解析 ✓；
   - 进度查询失败自愈：book_progress 返回空时不更新降频标记，下周期强制重试，
     避免 sqlite3 瞬态失败导致进度连空 5 分钟 ✓；
   - 进度查询降频：cc.db 的 progress 是慢变量，且 launcher backfill 开面板时会以最新值统一
     校正，daemon 侧改为每 5 次落账（≈5 分钟）或换书时真查（模拟：16 次落账仅查 4 次 ✓），
     sqlite3 开库 60 次/小时 → ≤12 次；
   - 顺手兑现文档承诺：持续阅读 delta 容错上限 150s→180s（CHANGELOG 此前已声明但代码漏改）。
   - **修复「换书进度串书」bug**（真机实测抓获：书A 47% 跑到新书B 头上）：换书后 cc.db
     尚无新书条目 → book_progress 返回空 → 失败自愈逻辑错误沿用上一本书的缓存进度。
     现按场景区分：同书失败沿用旧值（慢变量近似），换书失败清空且下周期重试——
     模拟复现书A(47)→新书B(空)→cc.db 收录后(47) 全链路 ✓。
6. **日志全量门控**：默认零日志噪音。USB 根放 `debug.flag` 空文件才恢复全量产出（与 v2.4.7
   根目录日志拷贝同一开关）。门控对象：launch/action 记录（exec 重定向）、perf 打点（_tm）、
   rank-debug 全部点位（_dbg，原 .rank-debug.flag 废弃并入）、触摸日志（debug 关闭时 lua 写
   /dev/null）、exit 诊断、daemon 启动行。例外：`fail()` 致命错误始终写 dashboard-launch.log
   （排障命脉）；fbink.log 只收 fbink 错误流（平时为空），不门控。

**验证**：双脚本 sh -n 通过；删除后重新提取 calc/排行两段 awk 本地跑样本数据（含归档行、空书名、
daily/duration 双排序）输出全部正确。

### 附：同期完成的计时精度大修（原内部编号 v2.4.8，未单独发布，随 v2.5 一起发布）

**根因**（本地 1:1 模拟复现：9 分钟连续阅读只入账 485s ≈ 8.1 分钟；真机叠加开书延迟即用户实测的「显示 6 分钟」）：

**daemon（采集端）**：
1. 阅读中落账周期 120s→**60s**：合书尾巴损失减半（旧版合书瞬间 daemon 在睡，最后一段 ≤120s 从未进账）。
2. 边缘补偿合理化：开书/合书 `delta/2` 旧版统一封顶 **5s** → 分开封顶 **15s/30s**（= 各自轮询半周期，无偏估计）。
3. `lipc-wait-event` reading 分支补**失败兜底**（时间差补睡，照抄 locked 模式）——旧版异常即忙循环，CPU 拉满的耗电炸弹。
4. flush **写成功才清零 bucket**——旧版 `|| true` 后无条件清零，USB 占用/磁盘满时整段静默丢账。
5. write_report 降频 600s（合书/切书/跨天/退出仍即时）——抵消唤醒翻倍的 fork 开销，**耗电净账持平**：60 轮×轻 flush + 6 次报告 vs 旧 30 轮×(flush+报告)。

**launcher（统计端）**：
6. **排行日均改定格口径**（用户拍板）：`累计秒 ÷（末读日−首读日+1）`，末读日=tsv 最后有记录的日子——**读完的书日均从此静止**，不再被时间稀释；在读书口径不变。python/awk 双路径同改，rank 缓存 key v2→v3 自动作废旧口径。
7. **在读/读完按书名归并**（与 rank 同口径）：删书重装换新 key 不再幻影双计。
8. **progress 回填改 cdeKey 优先**（与 daemon book_progress 同口径）：旧版仅按书名匹配，书名差异即 MISS → 旧行 st 滞留 reading → 同书双计的根因之一。

9. **显示层分钟四舍五入**（fmt_hm / rank python `_hh` / rank awk `hhmm` 三处同改）：旧版截断秒数，8.5 分钟显示 "0h8m" 加剧偏少观感；现 ±30s 进位，与采集端精度对齐（510s→"0h9m"）。

**复核结论（统计端其余指标全部正确，未动）**：今日/本周（蔡勒周一换算）/本月日均（÷当月已过天数）/连续天数（今天未读从昨日起倒数，归档日清单展开）/阅读天数/本年累计；归档折叠前后全等校验+回滚。

**验证**：daemon 逻辑 1:1 模拟（桩 lipc，真时钟 9 分钟场景）——旧版出账 485s（复现「9 分钟变 8 分钟」，真机叠加开书延迟即 6 分钟），v2.4.8 出账 510s=8.5 分钟、显示 "0h9m"；日均定格公式 python 断言 PASS（读完书 352s/天→3600s/天定格，在读书不变）；双脚本 sh -n 通过。

## ✦ v2.4.7（2026-09-09）日志治理：debug.flag 门控

- 稳定期不再每次退出都往 USB 根拷 4 份日志（`LOG-dashboard-launch/fbink/dashboard-touch/install.log`）——排障通道改为门控：USB 根放一个 `debug.flag` 空文件即恢复全量拷贝（与 diagnose.flag / uninstall.flag 同套习惯）。
- exit-watchdog 的 USB 根双写同门控；`$BASE` 内日志本就有 200KB 自截断，无需清理。
- 归档报告 `LOG-archive.log`（每月至多一次、数据自检凭证）与安装日志不受影响。

## ✦ v2.4.6（2026-09-09）退出回图书馆·终局：KPP 图书馆视图

**真机证据链**（v2.4.5 实测日志）：

1. 合书返回落点 = `com.lab126.KPPMainApp`（exit-watchdog 实测）——5.14.2+ 起主页/图书馆合一于 KPP（React Native 桌面），合书只能回其默认视图（主页），到不了图书馆 tab；
2. v2.4.5 看守把 KPPMainApp 误判为「未回系统界面」（只认 booklet 字样）→ 误补跳 `booklet.home` → 用户看到「几秒后又刷新一下」。

**方案**：扶正项目 v2.0 起就携带、但从未被真正执行过的 URI——

```
lipc-set-prop com.lab126.appmgrd start "app://com.lab126.KPPMainApp?view=KPP_LIBRARY"
```

（旧链首条 `start home` 恒「成功」把它永久拦截。）动态探测到独立图书馆 booklet 时仍走 `start` 直启（老固件兼容）。看守修正：activeApp 含 `booklet` **或** `KPP` 均视为已回系统界面；皆无才补跳 `booklet.home` 防死屏。

## ✦ v2.4.5（2026-09-09）退出回图书馆：合书语义（已废，见 v2.4.6）

**根因链（三连）**：v2.4.3 臆测 appreg 列名 `appId`（实为 `handlerIds.handlerId`）→ v2.4.4 修正列名后真机实测 `lib_id=未注册`——**5.19 固件没有独立图书馆 booklet**，图书馆只是主页 booklet（`com.lab126.booklet.home`）内的 tab，`start` 任何 `app://` URI 都落不到图书馆视图。此路本就不通。

**方案**：scriptlet 本是从图书馆点开的「书」，退出即应「合书归架」——

1. **不再主动 start 任何界面**：脚本 `exit 0` → sh_integration graceful exit（Hotfix v2.3.1+ 修复的 app 正常退出路径）→ 框架合上 scriptlet，自然返回启动来源（图书馆），home booklet 激活时自绘，无需手动刷屏。
2. **防死屏保险丝**：后台看守 6 秒后查 `lipc-get-prop com.lab126.appmgrd activeApp`，若仍停在本插件（自然返回失败）→ 补跳主页。结果双写 `dashboard-launch.log` 与 USB 根 `LOG-dashboard-launch.log`（`exit-watchdog activeApp=[...]` 行）。
3. **兼容老固件**：动态探测到独立图书馆 booklet（`LIKE '%booklet%library%'` 命中）时仍走 `start` 直启。

## ✦ v2.4.4（2026-09-09）热修：退出仍回主页

**根因**：v2.4.3 的图书馆探测臆测了 appreg.db 列名 `appId`——真实表为 `handlerIds`、单列 `handlerId`（kindlemodding.org appreg 文档实证）。SQL 恒报 `no such column: appId`（被 `2>/dev/null` 吞掉）→ 探测恒失败 → `EXIT_APP` 恒回退主页。本地建模拟库复现确认。

**修复**：

1. **查询改动态自报**，不再硬编码任何 ID：`SELECT handlerId FROM handlerIds WHERE handlerId LIKE '%booklet%library%' ORDER BY handlerId LIMIT 1`——设备上注册了什么就用什么，固件改版（图书馆 ID 变更）自动适应。
2. 查不到（该固件图书馆并入主页、无独立 booklet）或 sqlite3 不可用 → 安全回退主页，不死屏。
3. 探测结果写日志：`exit → <目标> (lib_id=<命中ID|未注册> sqlite3=<路径|NONE>)`，USB 根 `LOG-dashboard-launch.log` 可直接查证。

## ✦ v2.4.3（2026-09-09）排行页封面占位图 + 退出返回图书馆

**封面占位图（book.png）**

- 排行页书籍封面搜索落空时（无 asin、p_thumbnail/UUID/各拼法路径全部 MISS）统一显示占位图 `ui/book.png`；占位图本身缺失则维持留空，不影响其余渲染。
- `thumb=""` 初始化提到 asin 判断块外（旧版无 asin 的书 thumb 未定义），绘制块随之外移，逻辑等价。
- **用户可自行换图**：① 安装包 `ui/book.png` 同名覆盖后重装；② 设备上直接覆盖 `/mnt/us/reading-time/ui/book.png`，下次渲染即生效（无需重装）。
- 安装脚本同步：payload 检查 + 拷贝补入 `book.png`（缺文件时明确报错，不再静默跳过）。

**退出返回图书馆**

- 旧行为：× 关闭 / 2 分钟超时后 `lipc start app://com.lab126.booklet.home` 回主页；附带的 `KPP_LIBRARY` 兜底链因 lipc start 异步 fire-and-forget 恒不触发。
- 新行为：优先唤起 `com.lab126.booklet.library`（本插件自图书馆 scriptlet 启动，回原地最顺手）；以 appreg.db `HandlerIds` 表判注册（KUAL 同款注册表），未注册/查询失败自动回退主页。退出目标写入 `dashboard-launch.log` 可查证。

## ✦ v2.4.2（2026-09-08）计数制 flash：少闪不糊

**问题**：v2.3.34 起每次渲染 commit 都带 `-f` 全屏黑闪，「点一下闪一下」手感差；但完全去 flash 又会在 KPW6 上残影累积发糊（v2.3.34 实测教训）。

**方案**（Kindle 原生书籍「每 N 翻页一闪」同款）：

1. **计数制全刷**：新增 `commit_screen()` 统一提交渲染——每 `FLASH_EVERY`（默认 5，脚本头部可调）次渲染强制 `-f` 清残影一次，其余用无闪 GC16 全波形。残影最多累积 4 次渲染即被强清（有界），闪屏频率 100% → 20%。嫌糊调小，嫌闪调大。
2. **替换 3 处渲染 commit**：dashboard FAST 推图（改为 `-b` 缓冲推图 + `commit_screen`，与 SLOW 路径同模式）、dashboard SLOW commit、ranking commit。`fail()` 兜底保留 flash（极罕见）。
3. **退出反馈改局部反色**（替换 v2.4.1 的全屏 flash）：× 按钮区画黑块 + DU 波形只刷该 56×56 小块（~0.15s），即按即见、不闪全屏。

**手感对比**：一次会话 = 进入首刷 1 闪 + 每 5 次操作 1 闪 + 退出 0 闪（按钮变黑）。

## ✦ v2.4.1（2026-09-08）关闭按钮热区对齐 + 退出即时反馈

**问题**：右上角 ×「总觉得要多点几下才能关掉」。

**根因**：v2.3 重排把 × 视觉圆心挪到 (1180,120)，但 lua 触摸热区仍是旧布局 `[1130,35,1222,127]`——热区下缘 y=127 距圆心仅 7px，**圆的可视下半 21px（y 127~148）完全在热区外**；指尖 centroid ±10px 抖动，瞄圆心戳约三四成概率判空。属「图动了、热区没跟上」的残留 bug。

**修复**：

1. **热区对齐视觉中心**（reading-insights-touch.lua）：`[1130,35,1222,127]` → `[1140,60,1230,180]`（90×120px 正压圆心；左界 1140 与排序胶囊 x≤1130 零重叠；下缘 180 不碰 y=200 分隔线）。
2. **退出即时反馈**（launcher exit 分支）：先 `-f -W GC16 -s` 单次全刷闪屏（Kindle 翻页同款确认信号，~0.3s），再拷日志 / 恢复状态栏 / 唤起主页——旧版清理期间画面冻结 1~3s，易误以为没戳中又补戳。（**v2.4.2 起改为 × 按钮区局部反色**，不再全屏闪）

## ✦ v2.4.0（2026-09-07）跨年归档 + 全链路提速：长年重度使用不卡顿

**动机**：日均数小时阅读 + 藏书数百本的重度场景下，明细行数年增数万行，backfill 全量重写、dashboard/后台报告全扫、排行手工排序会逐渐变慢。

**归档器**（launcher 每次启动检查，每月至多折叠一次，`.archive_done` 闸门）

- 截止月 = 今天 −90 天所在月；截止月之前的原始明细按「月份×每书」折叠为 7 列归档行（date = 当月最后阅读日，第 7 列 = 当月阅读日清单），与 daemon 6 列明细行以 `NF≥7` 无歧义区分。
- 近 90 天明细原样保留 → 连续打卡 / 今日 / 本周 / 本月计算逐位不变。
- **自检兜底**：折叠前后 总秒数 / 各年秒数 / 各年天数 逐项全等才放行；任何一项不等 → 自动恢复原文件 + USB 根 toaster 警示 + 写 `FAIL-` 标记停手（删 `.archive_done` 可重试）。归档前自动 `.bak-时间戳` 备份；全过程记录 `LOG-archive.log`。
- 归档行日清单精确还原连续打卡（跨归档边界不断档）；排行「开始日期」取日清单最小日，不漂移。

**配套提速与兼容**

- `write_report` 三遍全扫并一遍（总秒 / 今日 / 分书同 pass 聚合），按 bid 聚合取首个非空书名，与排行同口径，不再拆出幻影书。
- backfill 跳过缓存（`.backfill_key` = 明细行数 | cc.db mtime+size），无变化不全量重写；归档行第 7 列透传。
- calc / rank 快慢双通道（awk + python）全部支持 `NF≥7` 归档行。
- 排行并列确定性强键：时长 → 日均 → 书名字典序，归档改变行序后名次逐位不变。
- 修 `rank.py` `rstrip()` 吞尾部 TAB → 老 4 列空书名行被误丢、快慢通道总量对不上（改 `rstrip('\r\n')`）。
- 修归档截止月纪元偏移（`z-=1721120`；误写 `z+=719468` 会算出 8708 年 → 全量误折叠）。

## ✦ v2.3.37（2026-09-07）排行字号再放大 + 行内聚拢

- 书名 36→38pt / 作者·起止 27→29pt / 累计时长 36→38pt；书名与进度条向作者行位移 8px（书名 top+34、进度条 top+152），视觉更聚拢。

## ✦ v2.3.36（2026-09-07）排行字号放大

- 书名 34→36pt / 作者·起止 25→27pt / 累计时长 34→36pt（序号 / 日均 / 百分比不动，坐标全不动）。

## ✦ v2.3.35（2026-09-07）排行行内布局重排 + 跨页连续编号 + 体检修复

- **行内重排（6 点布局需求）**：序号移封面左侧居中（视觉中心 = 封面中心）；封面 / 书名 / 作者 / 进度条整组右移 70vp；书名 32→34pt；作者与起止合并一行「作者 · 起 → 止」25pt；进度条满长右缘抵屏宽 2/3（x=848，全长 538）；时长 32→34pt，与日均右对齐成块。
- **序号跨页连续编号**：第 2 页第 1 本显 7 而非 1（展示号 = 页偏移×6 + 页内行号）。
- **体检修复**：封面候选路径含空格被分词 → 改逐项引号传参；launch / fbink / rank-debug / touch 四日志超 200KB 截断留尾 100KB（先于 `exec>>`）；`text_w` 4 字节 emoji 跳字修正；删 `scale_y`/`scale_x` 死代码；lua 删 `htab` 死参数。

## ✦ v2.3.34（2026-09-06）修模糊：残影根治（-f flash）+ 子集字体保留 hinting

**用户实测反馈**：v2.3.33 装上后提速明显，但"字体模糊"；进一步观察：**第一次进入清晰，切换排行后开始模糊** → 不是字体问题，是 **E-ink 残影累积**。

**根因**：R48 当年为消"双闪"去掉了最终刷新的 `-f` flash，只留 `-W GC16 -s`。FBInk 作者 NiLuJe 明确：**无 flash 的刷新不会触碰未变化像素，顽固机型必须 `-f` 才能清残影**（KPW6 新硬件 + 旧版 fbink 正属此类）。于是每页残留的上一页笔画逐次叠加 → 越翻越糊。R48 的"双闪"实为 FAST 路径两条独立刷新命令叠加所致，单命令 `-f -W GC16 -s` 只是一次标准全刷。

**修法**：
1. dashboard / ranking / FAST 三处最终刷新统一改为 `fbink -q -f -W GC16 -s`（单次黑闪全刷，即 Kindle 翻页标准全刷行为；每次绘制结束都彻底清屏，残影无处累积）。
2. 子集字体从**原版字体**重新生成并**保留 CFF hinting**（v2.3.33 误剥 hint：已验证新子集与原字 hint 运算符数量、BlueValues、字宽 advance 全部一致；体积 2.2MB→2.6/2.7MB，提速收益基本不变）。即便残影修复后仍有字形级发虚，hint 也在。

**自测**：sh -n OK；子集 hint 完整性逐项比对通过。
**未推 GitHub**（铁律）。

## ✦ v2.3.33（2026-09-06）性能总攻：字体子集化（真凶）+ 零 fork 瘦身

**真凶定位（与历轮 log 自洽）**：`cover_ms=1~2` 证明 fbink 进程启动+framebuffer 写入仅 10-20ms；而 `text_ms=89~166`（每行 8 次 `-t`）证明**每次 `-t` 有 ~120-170ms 花在字体上**——每次调用都全量读入 regular(11.6MB)+bold(12.1MB) 两个 CFF 大字体并初始化，一页 ~50 次 ≈ 1.2GB 字体 IO ≈ 7s。砍 fork（v2.3.28 路线）只触及零头，这正是"改了速度没变化"的原因。

**五刀齐下**：
1. **字体子集化（主刀）**：GB2312 全表 + 假名 + Latin-1/Ext-A + 常用标点/箭头/几何符号，8025 字形；Regular 11.6→2.2MB、Bold 12.1→2.25MB（每次 `-t` IO 24MB→4.4MB）。stb_truetype 不用 CFF hint/GSUB（已剥），渲染逐像素一致；**字宽 advance 逐字符验证不变**（text_w 校准不失效）；真机书名/作者/UI 字符串 + quotes.tsv 全覆盖验证零缺字。附 `subset_fonts.py`，如罕见书名号出现缺字（豆腐块）可用它加宽字符集重新生成。
2. **REGULAR 文字只传 `regular=` 槽**（fbink 最基础用法）：常规字不再白读 Bold 字体，IO 再减半；BOLD 维持双槽不变。
3. **打点零 fork**：`_tm`/`_nowcs`（原 `_csec`）改 shell 内建 `read < /proc/uptime`（原每次 fork awk，一页 ~30 个打点 fork 全灭；输出格式不变，可与历轮 log 对照）。
4. **行解析**：12×cut + 2×tr（26 fork/行）→ 单次 awk 以 `\x1f`（非空白 IFS，空字段不合并）连接 + `read` 一次拆 13 字段（封面 key 归一化并入同一 awk）。免疫空字段左移错位；封面查询链路与 v2.3.23/32 逐字节一致未动。
5. **dashboard**：12×echo|awk → `IFS tab set --` 一次拆；`fmt_hm`/SEC7 求和改纯内建算术（~20 fork/页清零）。

**预期**：单次 `-t` ~130ms → ~30-40ms，排行页 8s → **2.5-3.5s**；dashboard 同步受益。自测：sh -n OK；行解析（真空作者/空格书名/中文标点/连字符小写 asin）全绿；fmt_hm/求和/打点算术与旧版输出逐字节一致。
**未推 GitHub**（铁律）。

## ✦ v2.3.32（2026-09-06）止血：封面链路 + 行解析整体还原 v2.3.23 真机验收实现

**背景**：v2.3.24~31 性能改造期间引入"封面消失"且多轮未愈；用户明确不再配合测试。我停掉一切性能实验，把 UI 相关两条链路**整体还原为 v2.3.23（用户验收 UI 全好）的实现**：

1. **封面源还原**：恢复独立 `COVER_MAP`（归一化 key→p_thumbnail，`upper(replace(cdeKey,'-',''))`）与 `UUID_MAP`（原样 key→uuid）两张映射，MISS 重建时生成、HIT 复用（翻页仍 0 次 sqlite3）；渲染查询改回 v2.3.23 逐字逻辑。单测：asin=`abc-123` → 归一化 `ABC123` → COVER_MAP 命中 ✓。
2. **行解析还原**：12 字段恢复 v2.3.23 的逐字段 `cut`（真机验证零歧义），不再依赖任何 set/占位机制。
3. HIT 条件要求四件缓存齐备（聚合/作者/封面/uuid），缺失即自动重建。

**速度实情（诚实汇报）**：数据层早已到 0.05s；翻页 ~8s 的剩余部分几乎全是**每行 ~8 次 fbink 文字绘制的物理耗时**（每次 ~120-170ms，OTF 大字体加载+渲染），v2.3.28 砍的子进程仅占 ~10-15%——之前对瓶颈判断失误、连累用户装了多版无感版本。要达 2-3s 需换渲染架构（真机装 python3+Pillow 走 FAST 整页合成，或每页行数妥协），待用户定夺，不再擅动渲染。
**未推 GitHub**（铁律）。

## ✦ v2.3.31（2026-09-06）行字段解析 v3：非空白分隔符 read —— 渲染正确性 100%

**问题（用户两轮反馈，已装最新仍封面无、速度无变化）**：不再要求用户配合测试，从代码层面找确定性修复。

**修法**：渲染行解析（影响每行 asin→封面 key、作者、起止等全部字段）改为**不可错位的机制**：
- 单次 awk 将 12 字段以 `\x1f`（**非空白** IFS 字符）连接 → shell `read -r` 拆 12 变量。
- ★原理：tab/空格属 IFS 空白，连续出现会**合并空字段**（v2.3.7 老坑、v2.3.28 `set --` 依旧踩）；而**非空白 IFS 字符是单字符分隔、保留空字段** → 作者/最近日期为空也绝不左移错位 → asin 列永远正确 → 封面查询 key 归位。
- 不再依赖"数据源占位"假设（占位保留为兼容，解析本身已免疫空字段）。
- 每行 1 个 awk 子进程（旧 12×cut = 24 子进程/行）。

**自测**（bash --posix，真实数据形态）：作者真空 → asin 正确；英文空格书名/作者 → 不拆分；最近日期空 → 不错位；中文标点 → 正常。sh -n OK。

**请用户装 v2.3.31 验证一次**：封面应恢复、字段归位。若仍有问题，我不再打扰用户测数据，自行从代码继续排查。
**未推 GitHub**（铁律）。

## ✦ v2.3.30（2026-09-06）封面诊断无条件落盘（等 log 锁封面 bug）

- v2.3.29 刚交付即收到"封面仍无、速度仍无变化"反馈——按时间线疑为 v2.3.28 的重复体验（v2.3.29 交付仅 3 分钟）。
- 为确保下次实测一次定位：封面探测诊断（首行 asin / key / uuid / p_thumbnail 原值 / 命中路径 / CC_ALL 行数）从 `.rank-debug.flag` 控制改为**无条件写 rank-debug.log**。用户无需放 flag，拷 log 即见封面链路全貌。
- 请用户重装 v2.3.30 → 开一次排行页 → 拷回 `/mnt/us/reading-time/rank-debug.log`：内含 cache=HIT/MISS、[封面] 诊断行、每行 cover_ms/text_ms，一次锁死封面丢失与速度两大问题。
- **未推 GitHub**（铁律）。

## ✦ v2.3.29（2026-09-06）修复 v2.3.28 回归：旧缓存格式不兼容 → 封面丢失/字段错位

**问题（用户真机反馈）**：v2.3.28 后速度无变化，**封面全部消失**。

**根因（代码推演 + 复现）**：v2.3.28 的渲染行解析（12×cut → `set --`）依赖"12 字段全非空"（空作者/最近日期由数据源输出 `-` 占位）。但**缓存 key 未带格式版本** → 真机直接命中了 v2.3.24~27 生成的**旧缓存**（作者列是真空字段、无占位）→ `set --` 按 tab 分词时空字段被 shell 合并 → **整行左移错位**：asin 列拿到日期 → 封面查询 key 全错 → 封面消失；绘制调用数没变 → 速度也无变化。

**修法**：
1. **页截取层兜底占位**（hit/miss 两处）：页截取 awk 逐列展开缓存 9 字段，作者列/最近日期列为空时补 `-` → 无论新旧缓存、渲染解析永远 12 字段稳定（兼容旧缓存，不再依赖 build 端占位）。
2. **缓存 key 加格式版本 `v2|`**：旧缓存 header 不匹配 → 本次自动全量重建一次，缓存与代码格式强一致。
3. 顺带统一两处页截取的 hhmm（时长恒带 h `0h 17m`）。

**自测**：用 v2.3.27 格式旧缓存（作者真空）→ 页截取补占位 → 渲染解析 asin 归位（封面 key 正确）、起止/时长正常。sh -n OK。

**速度说明**：v2.3.28 的速度"没变化"正是因旧缓存错位（绘制次数没变）；本次修复后错位消失，且机器上会自动重建一次新缓存。请用户再测：封面应恢复，`text_ms`（log 行级打点）应体现 v2.3.28 子进程瘦身的真实收益。
**未推 GitHub**（铁律）。

## ✦ v2.3.28（2026-09-06）性能第五刀：真正的元凶是"每字 3 个 awk 子进程"——渲染瘦身

**用户 v2.3.27 log（决定性）**：
- `cover_ms=1~2`（厘秒）→ 封面推图 0.01~0.02s，**不是瓶颈**；
- `text_ms=89~166`（厘秒）→ **文字段每行 0.9~1.7s**，5 行 ≈6.9s = rows_done 的 7.7s 本体。

**根因（代码审出，非猜测）**：每画一个字，`fb_text_at` 内部都要跑 **3 个 `$(scale_y/scale_x)` awk 子进程**做坐标缩放（1:1 恒等变换却每次 fork！）；每行 8 处文字 → **~25 个 awk/行**；再加行字段解析 **12 个 `printf|cut`（24 子进程/行）**。busybox awk 进程启动 ~15-40ms → 每行 1s 的真正构成是 ~50 个子进程，fbink 本身只占小头。

**修法（零视觉变化）**：
1. **scale_y/scale_x 调用全部删除、坐标直通**：KPW6 viewport=1272×1696 与 LOGICAL 1:1（历轮像素探针校准依据），top/left/right 原值直接传给 fbink → 每字省 3 个 awk fork。⚠ 注释注明：换机型（非 1:1）需恢复。
2. **行字段解析 12×cut → 单次 `set --` 分词（0 子进程）**：空字段（作者/最近日期）改由数据源（build awk / python 快路径）输出占位 `-`，渲染后清空——保证 12 字段永不空缺，规避 v2.3.7 的 busybox read 连续 tab 合并坑；字段内空格（英文书名/作者、时长 "1h 0m"）不拆分（IFS 仅 tab）。
3. dashboard 同受益（其 ~20 处文字也走 fb_text_at）。

**自测**：bash --posix 分词四场景（空字段占位/空格书名/多空/中文标点）12 字段全稳；build awk 空作者出 `-`；页截取+渲染解析全链路正确；python py_compile、sh -n 全过。

**预期**：每行 awk/cut 子进程 ~50 → ~2（仅 text_w 计时长/日均宽度，必要），text_ms 应降到纯 fbink 时间。请用户实测：6 行页应从 ~8s 大幅下降（目标 2-3s）。
**未推 GitHub**（铁律）。

## ✦ v2.3.27（2026-09-06）性能第四刀：行级打点——封面 vs 文字，谁是大头

**用户实测数据（v2.3.26 log）**：
- cache=HIT，`rank_start→data_done = 0.05s`（缓存已完美生效）、底图 0.07s——**数据层与底图都不是瓶颈**；
- **6 行渲染 `bg_done→rows_done = 5.74s / 6.82s`** —— 这就是 7.6s 的真凶，时间**与行数线性相关**（用户感知：1 行页 1-2s、6 行页 8s；每行 ≈1.1s）；
- dashboard 同样慢在下半部文字段（2.5~3.6s），本轮 dashboard 代码零改动（指标页这次恢复正常，与上轮 1s 延迟系偶发/冷缓存）。

**本轮改动**：渲染行循环内加**行级厘秒打点**——每行输出 `cover_ms`（单张封面 fbink -g：jpg 解码+缩放+dither）与 `text_ms`（序号→日均 7-9 次 fbink -t/-k）。一次 log 即可定位每行 ~1.1s 是花在封面推图还是文字绘制，下一刀按实测砍（不动视觉、不烧底图）。

**未推 GitHub**（铁律）。请用户装后切排行看一页，拷回 rank-debug.log（含 `[row N] cover_ms / text_ms`）。

## ✦ v2.3.26（2026-09-06）性能第三刀：打点 bug 修复 + dashboard 打点

**问题（用户真机实测）**：v2.3.25 后速度仍无变化（~7.6s）；`rank-debug.log` 只有一行 `[perf …] rank_end`；且指标页打开下方数据慢 ~1s（此前直接显示）。

**根因 1（打点只有一行）**：`_tm` 用 awk `> f`（覆盖）写日志——6 个打点各起一个独立 awk 进程、每个都截断重写文件 → 互相覆盖、只剩最后写入的 `rank_end`。已改为 `>>`（追加，本地对照验证：`>>` 三行全留 / `>` 只剩末行）。

**根因 2（指标页慢 1s）**：dashboard 渲染代码本轮零改动，慢点位置未知 → 给 dashboard 也埋打点 `dashboard_start / dashboard_bg / dashboard_end`（_tm 提升为全局定义，dashboard 先于 rank 渲染也能用）。log 一次拷回即可见：指标页慢在"计算(calc)/推背景/下方文字段"哪一段，以及排行慢在"数据层/底图/行渲染"哪一段。

**根因 3（排行仍 7.6s 待证）**：缓存 key 已改为 cc.db 文件大小（v2.3.25）；cache HIT/MISS 状态改为无条件落盘（不再依赖 flag），本次重测直接看 log 首行即知是否命中。

**下一步验证**：装 v2.3.26 → 打开指标页（感受下方数据）→ 切排行翻 1-2 页 → USB 拷回 `/mnt/us/reading-time/rank-debug.log`（内含 dashboard 与 rank 全部 [perf] 时间戳 + cache HIT/MISS）。我据分布精确砍最后一刀（不动视觉、不烧底图、不破坏空数据显示）。
**未推 GitHub**（铁律）。

## ✦ v2.3.25（2026-09-06）性能第二刀：缓存 key 修正 + 毫秒打点

**问题（用户真机实测）**：v2.3.24 后翻页 ~7.6s，"感知没变化"（9s 系心算，实际约 7.6s）。

**根因（代码实证推演）**：v2.3.24 缓存 key 用了 **cc.db 的 mtime** 作失效信号——但 Kindle 系统在读屏/翻页期间会持续 UPDATE cc.db（进度、最近访问），**mtime 每页都在变 → key 永不匹配 → 缓存每页全量重建** → 数据层优化形同虚设。

**修法**：
- 失效信号 mtime → **cc.db 文件大小**：增删书会增删 SQLite 页 → 大小变 → 触发重建；进度更新只改写既有页 → 大小不变 → 翻页稳定命中缓存。
- 埋**无条件毫秒打点**（/proc/uptime 浮点秒，~60ms 总开销）：`rank-debug.log` 输出 `[perf …] rank_start / data_done / bg_done / rows_done / rank_end`——下次实测后拷回 log 即知 7.6s 是花在数据层、底图推送还是 6 行文字渲染，下一刀按数据砍。
- 渲染层仍未动（用户否决"序号烧底图"方案——空数据时会显示空序号，视觉不可接受；流畅度优化不牺牲显示正确性）。

**验证方式**：装 v2.3.25 → 切排行页翻一页 → 感受翻页是否明显变快 → USB 拷回 `/mnt/us/reading-time/rank-debug.log`，我看 `[perf]` 分布决定最后是否/如何动渲染。
**未推 GitHub**（铁律）。

## ✦ v2.3.24（2026-09-06）排行性能优化：指标页↔排行切换 / 翻页 9s → 目标 2-3s（数据层缓存）

**问题（用户反馈）**：指标页切到排行、排行内翻页，预计 9 秒，非常卡。

**耗时盘点（代码级，未猜）**——真机每次 render_ranking 全量重跑：
1. **6 次 sqlite3 CLI 进程启动**：表名 / PRAGMA 列名探测 / CC_CACHE / COVER_MAP / UUID_MAP（各自还带 `||` 回退重跑）。
2. **awk 全量扫 reading-time.tsv 至少 3 遍**：v2.3.23 书行取样 1 遍 + 书名健康度 1 遍 + 主聚合（预扫 bid→书名 1 遍 + 主体 1 遍）。
3. 封面探测：每行开 2 个 awk 进程查 COVER_MAP/UUID_MAP（6 行 12 次）+ 每行时长/日均换算各 1 awk（12 次）。
4. 大量 debug 日志 I/O（head/wc/ls/取样）——诊断期留下的，正常使用也在跑。

**修法（视觉零变化，只动数据/计算层）**：
- **聚合缓存 `.rank_all.tsv`**：tsv 全量聚合+排序只在缓存失效时做一次（key = 排序方式|tsv 行数|meta 行数|cc.db mtime|日期，任何变化/跨天自动重建）；翻页/切换命中缓存 → 仅一次轻量 awk 截取当前页 6 行（毫秒级）。
- **cc.db 一次化 `.cc_all.tsv`**：列名探测 + 6 列单次 dump（key/作者coll/作者json/进度/p_thumbnail/uuid）→ 从 6 次 sqlite3 进程降到首切 2 次、翻页 0 次；封面权威 p_thumbnail 路径不变（f5/f6 读取）。
- **debug 开关化**：heavy 日志（取样/健康度/ls 等）只在 `$BASE/.rank-debug.flag` 存在时写；正常路径零日志 I/O。耗时打点（cache HIT/MISS + 数据层耗时）随 flag 输出。
- **渲染子进程瘦身**：时长/日均文本由页截取 awk 预生成（f11/f12），行循环直接 cut——省每行 2 次 awk 进程（12 次/页）。
- python 快路径同步补 12 字段（时长恒带 h "0h 17m"，日均 h>0 才带 h "56m"，保持历史格式）。

**预期**：翻页数据层从 ~2s+ → 毫秒级；首次切页（无缓存/跨天/有新阅读）仍需一次全量重建（sqlite 2 次 + awk 全扫），剩余时间主要是渲染本身（~60 次 fbink，本轮未动，保证视觉零回归）。

**自测**：awk 全量输出 9 字段 ✓；页截取 12 字段（含 0h 17m 格式）✓；越界页空 ✓；miss 重建→hit 翻页→切排序 key 失效全流程模拟 ✓；python 快路径 py_compile+运行 ✓；sh -n ✓。

**真机验证**：装后翻页应明显变快。若仍 >3s，把 `reading-time/rank-debug.log` 拷回（默认已含 HIT/MISS 与数据层耗时），我据渲染耗时分布决定是否动渲染层（序号烧底图/封面策略等）。
**未推 GitHub**（铁律）。

## ✦ v2.3.23（2026-09-06）归并修 v2.3.22 回归：空书名行被拆成"key 串伪书"

**问题（用户真机反馈）**：v2.3.22 合并生效了，但排行反而**多出几本书**，书名是 `7492B72DF78…` 这种 key 串，无法判断去重后数据对不对。

**根因（代码逻辑闭环推演 + 假数据复现，非猜测）**：
- daemon 偶发抓不到书名 → tsv 里**同一 bid 混有"书名列空"的行**（大部分行有书名、零星几行空）。
- v2.3.22 把聚合键直接换成"当行书名"：空书名行无法匹配 → 退成以 bid 为书名的独立行 → **同 bid 被拆散**：原书时长变少 + 多出一本 `7492B72DF78…` 伪书。多本书都有零星空行 → 多出好几本。
- v2.3.21 按 bid 聚合时空行和正常行同属一 bid，显示正常，故此前从未暴露。

**修法（两阶段归并，python/awk 同步）**：
- **阶段 ①**：按 bid 预扫，取该 bid **首个非空书名**为"有效书名"（awk：BEGIN 内 `getline < df` 预扫建 `title_of[bid]`；python：`title_by_bid` 只存首非空）。
- **阶段 ②**：按"有效书名"聚合 → 同 bid 空行自动归队，跨 bid 同名（删书重装换 key）照常合并。
- 仅当整 bid 所有行都无书名（真实无元数据）才退 bid 显示 key 串。
- debug 日志新增 **"tsv 书名健康度"** 段：空书名行计数 + 逐 bid 书名取样 → 用户可核对"多出的书"是否 = 空书名行。

**自测（fake tsv：B1 三体含 1 空书名行 + B2 三体重装 key + C1 全空 + D1 孤立书）**：
- 修复前：三体少 50s、多出 B1 伪行；修复后：`三体 1075s`（B1 空行归队）+ `C1 200s`（全空退 key）+ `孤立书 60s`，total=3，python/awk 两路径逐字段一致。

**未推 GitHub**（铁律）。真机验证：若 `7492B72DF78…` 类行仍存在，请把 rank-debug.log 的"tsv 书名健康度"段拷回，我据实判断这些整书无书名的书是并入还是过滤。

## ✦ v2.3.22（2026-09-06）排行页同名书归并：删书重装不再出双行

**问题**：误删一本书后重新导入/下载，书名作者都一样，但排行页出现**同名两行、时长分家**，翻页总数也虚增。

**根因（代码实证，非猜测）**：
- 排行页时长唯一来源 = `/mnt/us/reading-time/reading-time.tsv`，daemon 按「书 key（bid = cdeKey/ASIN）」逐行累计（python 快路径与 awk 慢路径均为 `dur[bid] += sec`，一行 = 一个 bid）。
- Kindle 删书后再装，会给这本书**换一个新 key**（旁载/推送的书 key 是随机 UUID），旧 key 的历史行残留在 tsv 无人清 → 同一书名两行、各带一份时长。
- Dashboard 不受影响（只按日期累计、不看书的 key），故只修排行页聚合。

**修法（聚合键 bid → 书名，双路径同步）**：
- 聚合键改为**书名**（trim 后；空书名退 bid 防乱并）。同书名多 key → 合并一行：
  - **时长相加**（删书前 + 重装后都是这本书的时间，不丢历史）
  - **代表 bid = 最近阅读（日期/lastAccess）最大者** → 作者/进度/封面/asin 随它取（= 当前在读书，cc.db 有它的条目才能出作者与封面）
  - **开始日期 = 跨 key 最早阅读日**（fdT 优先，book-meta 兜底）→ 日均分母从真正首读日算起
  - **最近日期 = 跨 key 最晚**
- 作者解析沿用 v2.3.20 三段链（display → name → collation 去垫），跟随代表 bid。

**自测（本地 fake tsv 双 key 场景）**：`《三体》OLDKEY(3月 3600+7200) + NEWKEY(9月 1800+900)` → 合并为一行 `13500s`、开始 `2026-03-01`、最近 `2026-09-02`、代表 NEWKEY、进度 90、作者刘慈欣、total 4→3；空书名独立成行不误并；daily 排序正常；python/awk 两路径输出逐字段一致。

**未推 GitHub**（铁律）。真机验证：删书重装的书排行只出一行，时长 = 两次阅读总和。

## ✦ v2.3.21（2026-09-06）排行页 4 修：实测探针反推，零猜

**数据**：用户真机截图 `screenshot_2026_09_06T08_48_55+0800.png` 像素级复探（1272×1696 同 logical 1:1）。所有改动按 PIL 实测值反推，**未调盲参数**。

**问题 1：分页胶囊字「1/2」和顶部年份胶囊偏"左下角"**
- 实测：`fb_text_center 40 1576 918 1068 REGULAR BLACK ...` 渲染出的字 vp_x_center≈1004（fbink 内部对 vp_x 不可消除地偏右 +11 vp_px），vp_y_center≈1596（比胶囊几何中心 vp_y=1585 偏下 11 vp_px）。
- 修法（双修）：
  - **vp_y**：launcher top 从 1576 → **1564**（上移 12vp_px），实测字 vp_y_center ≈1585，刚好胶囊几何中心。
  - **vp_x**：box_left=918→**929**，box_right=1068→**1079**（右移 11vp_px），launcher 期望 vp_x_center=1004 与实测一致。
- 同步改动：dashboard 顶部年份胶囊 `fb_text_center 40 1576 918 1068 BOLD BLACK "$hyear"` → `40 1564 929 1079`。

**问题 2：进度条 vs 百分比 vs 日均 不在同一水平线（百分比/日均偏高）**
- 实测：launcher `top=row_top+162`（百分比）→ 字 main-center vp_y≈176；bar_top=row_top+189，进度条中心 vp_y=192 → 字比进度条**偏上 16 vp_px**（用户肉眼感受"略高于进度条"完全吻合）。
- 修法：`top=row_top+162` → **`row_top+170`**（百分比与日均两处同步下移 8vp_px）→ 字 main-center vp_y≈184 ≈ 进度条中心 192（差 8vp_px，在 fbink 偏下容忍内）。

**问题 3：日均没和累计时长右对齐**（实测看 book2: "9h 42m" vp_x_right=1091 vs "日均 4h51m" vp_x_right=1074 → 差 17 vp_px）
- 实测（PIL/mac advance vs 真机 fbink OT 实机 advance 反推）：**真机 Noto Serif SC 的实机 advance 比 mac PIL advance 小 ~28%**（如 BOLD "16h 6m" mac 估宽 134 vp_px 实机 advance 仅 97 vp_px）。同时 fbink -t 的 `right` 参数实际渲染 vp_x_right 比传入值**恒偏左 32~39 vp_px**（book1=37/book2=39/book3~6=32）——这是 fbink OT 模式对 right margin 内部加 ~37vp_px padding 导致的不可消除偏移。
- 修法：`right_edge=1130` → **`1167`**（=1130+37），时长与日均同步。时长 vp_x_right 应贴 1130；日均因 advance 偏小可能再偏左 ~5vp_px，但与时长已同列同步（实测差异由真机 advance 偏小引起，不是 vp_x 层级可消除的）。

**问题 4：封面没和上下分线对齐（封面比右侧文字偏上 8 vp_px）**
- 实测：cover `y=row_top+20` → cover vp_y_top=477；fbink -t 文字 vp_y_top=485（fbink -g 推图无偏，-t 偏下 8vp_px）→ cover 比文字**偏上 8vp_px**（用户所述"封面缺没有对齐"）。
- 修法：cover y = `row_top+20` → **`row_top+28`** → cover vp_y_top=485 与文字 vp_y_top 完全齐平；上下边距各 25vp_px（行高 215 - 封面高 165 = 50 → 各 25 vp_px 对称）。

**校验**：`sh -n` 通过；python heredoc 已在前版编译过；版本标 v2.3.21。

## ✦ v2.3.20（2026-09-06）排行页双修：日均右对齐 + 作者不再变拼音

**问题 1：日均值未与累计时长右对齐**（日均右缘比时长偏左 3~6px）
- 根因（本地 PIL 实测 NotoSerifSC-Regular/Bold @32px）：`text_w` 用同一套宽度系数估算两行文本，而该系数是按 **Bold** 实测反推的；日均串走 **REGULAR**（细体，数字 18/h 21/m 31，比 Bold 19/22/32 窄）→ 高估 3~6px → 右对齐时停早。
- 修复：`text_w` 增加 `$3=style`，仅当显式 `REGULAR` 时用常规字实测系数表（数字 0.5625 / h 0.65625 / m 0.96875 / 空格 0.25 / 中文 1.0，实测误差归零 ±0.3px）；`fb_text_right` 透传 style。**`fb_text_center` 保持不传 style → 已校准的年份/页码胶囊视觉零变化**。

**问题 2：作者显示成拼音**（如 aiqianshuidewuzei）
- 根因（readinglog-0.2.1 真机实证 + 本机历史 rank-debug.log 双重锁定）：cc.db `Entries` **没有** `p_credits_0_name` 显示名列，作者真名在 **`j_credits` JSON 的 `name.display`**：
  `[{"name":{"display":"爱潜水的乌贼","collation":"阿阿阿aiqianshuidewuzei","language":"zh"},"kind":"Author"}]`
  旧解析器只匹配 `"name":"字符串"`（name 后直接引号），对真实结构（name 后跟 `{`）失败 → 回落到 `p_credits_0_name_collation`（`阿阿阿`+拼音）→ 去前缀后显示成拼音。
- 修复：awk `jval()` 按三段取 —— ① `display`（真名）→ ② 旧式 `"name":"直接值"` 兼容 → ③ collation 去 padding 兜底。python fast path 同步（json 递归取 display）。
- ★ 附带抓到的回归：collation 去垫必须按 **UTF-8 整字符**（3 字节）比较重复前缀，busybox/BSD awk 字节模式下逐字节比较会把「阿阿阿」拆散剥不掉（自测 T5/T8 失败后修正）。
- 诊断增强：rank-debug.log 增加「书行取样」，逐本打印 collation / j_credits 原文（前 90 字符），下轮即使仍异常也可一次锁死。

**校验**：`sh -n` 通过；awk 作者三路径 + unpadded 10 用例全过（LC_ALL=C）；text_w REG/BOLD 输出与 PIL 实测逐串一致（193/196/157/134/138）；python heredoc `py_compile` 通过。

**仍推 GitHub？否** —— 用户重装真机验证两处修复后再议。

## 一、新增文件
| 文件 | 用途 |
|---|---|
| `native-reading-time-package/generate_ranking_bg.py` | 阅读排行页底图生成器（含排序胶囊框、6 行封面占位 + 进度条轨道、底部 tab + 翻页框） |
| `native-reading-time-package/ui/ranking_bg.png` | 排行页 1272×1696 底图（与 dashboard 同风格：圆角外框、Noto Serif SC、淡灰线） |

## 二、改动文件
| 文件 | 改动要点 |
|---|---|
| `Yunindex阅读统计.sh` | 加 `PAGE/RANK_OFFSET/RANK_SORT/RANK_TOTAL` 全局状态；`fb_text_at` 加可选第 9 参数 `halign`（LEFT/CENTER/RIGHT）；lua 调用传 `$PAGE`；主循环 `case` 扩展为 `goto_ranking/goto_dashboard/rank_prev/rank_next/rank_toggle_sort/period_prev/period_next`；`render_dashboard` 末尾加左下 tab 文字 + 「指标」选中态黑底；**新增 `render_ranking` 函数**（数据计算 python heredoc + 6 行渲染 + 排序胶囊字重切换 + 翻页） |
| `reading-insights-touch.lua` | `arg[3]` 由 `mode` 改为 `page`（dashboard/ranking）；`action_for_logical` 按 page 分支返回不同热区集；新增 4 个 ranking 热区 + dashboard 加 2 个 tab 热区 |
| `native-reading-time-daemon.sh` | 新增 `book-meta.tsv` 初始化（表头 `book_id\tfirst_open_epoch\tfirst_open_iso`）；开书边界处**幂等**写入 first_open（awk 先查再追加，永不覆盖既有时间戳） |
| `Install-Native-Reading-Time.sh` | 版本号 v2.2 → v2.3；增加 `cp ranking_bg.png`；toast 文案更新 |
| `generate_bg.py` | 删除 footer 「数据每日自动同步 · AUTO SYNC」文字；footer 新增 dashboard 左下两个 tab 框（圆角描边，无填充，选中态由 launcher 动态画黑底） |
| `ui/dashboard_bg.png` | 由 `generate_bg.py` 重新生成（删 AUTO SYNC + 加 tab 框） |

## 三、架构关键决策（v5 / v5.1 定稿版）
- **dashboard 与 ranking 完全独立**：dashboard 按 hyear 统计（年份胶囊仍生效）；ranking 强制跨年汇总（用 tsv 全行求和），dashboard 的年份状态不串到 ranking。
- **底图 + 叠加模式沿用**：排行页独立 `ranking_bg.png` 含静态框；文字、封面、选中态黑底、进度条填充均由 launcher 用 fbink 叠加。无 PIL 设备无需改造。
- **热区分页**：`page` 参数传给 lua，lua 据此返回不同热区集。两页共用同一份 lua，避免代码分叉。
- **tab 选中态**：PNG 画描边框（未选中态）；launcher 用 `fb_rect_at` 画黑矩形覆盖 + `fb_text_at ... BOLD WHITE` 画白字（选中态）。同一份 PNG 支持两态。
- **first_open 幂等**：daemon 用 awk 先查 `book-meta.tsv`，无该 bid 才追加；永不覆盖既有时间戳。历史书（v2.3 之前安装的）由 ranking 计算层兜底：用 `cc.db.p_lastAccess` 作为 first_open（精度到秒），并在 UI 显示「→ 最近一次」起止时间。

## 四、严格未动
- 统计核心规则（`app=com.lab126.booklet.reader && power=active`）零改动
- `reading-time.tsv` 6 列格式零改动
- daemon 事件驱动（熄屏/亮屏纯事件 + 阅读中 120s 兜底 + SAVE_INTERVAL=90s）零改动
- 卸载流程（RUNME.sh 智能检测 uninstall.flag + UNINSTALL.sh 只删程序文件、数据原位保留）零改动
- 书封面 Scriptlet（cover.png + # Icon:）零改动

## 五、推 GitHub 决策
**未推 GitHub**。本轮按规矩——未经确认，绝不推（用户反复叮嘱）。v2.3 整包先在桌面 `~/Desktop/yunindex-kindle-2.3/` 待真机验证：
1. 重新执行 `Install-Native-Reading-Time.sh`（v2.3）
2. 验证 dashboard 左下 tab「指标/排行」切换 → 跳到 ranking
3. 验证 ranking 6 行渲染（封面 + 主信息 + 右列时长/日均）
4. 验证排序胶囊切换（时长/日均字重切换）
5. 验证翻页 `‹ 1/3 ›`
6. 验证开书 → 等 daemon 写 book-meta.tsv → 重启 launcher 看 ranking 「开始阅读时间」精确显示

用户真机验证通过后再议推 GitHub。

## 六、开发收尾 bug 修复（真机前静态审查，均已修 + 本地逻辑验证通过）
| 位置 | 问题 | 修复 |
|---|---|---|
| `render_ranking` 内 `fb_text_at` ×15 | `right` 参数错位（多处 right < left，`halign=CENTER/RIGHT` 的对齐基准错误，真机文字必跑偏） | 按底图区间修正：排序胶囊 `[770,950]`/`[950,1130]`、tab `[80,300]`/`[320,540]`、翻页 `[820,930]`/`[930,1080]`/`[1080,1190]`；序号/百分比/右列时长·日均等全部 right≥left；右列对齐锚点 x=1130（与排序胶囊右沿同线） |
| `reading-insights-touch.lua:94` | 日志仍引用旧变量 `mode`（v2.3 已改名 `page`），nil 致 `string.format` 抛错、脚本退出 | `mode` → `page` |
| `render_ranking` python / awk 两分支 | `__RANK_TOTAL__` 写入 stderr（被 `2>>FBINK_LOG` 重定向），shell 却从 stdout 提取 → 总页数恒为 0，翻页显示错误 | 两分支均改为 stdout `print`，shell 正确解析 |
| `INK_SOFT` 色值 | shell 从未定义，`fbink -C INK_SOFT` 不识别色名 → 排行页次级灰字渲染失败 | 顶部定义 `INK_SOFT="#BDB8AB"`（与底图 INK_SOFT=(189,184,171) 精确一致） |
| 版本号残留 | launcher 运行时日志、daemon 头注释、daemon `model=` 标识仍 v2.2 | 统一 v2.3（`model=v2.3-6col`，tsv 仍 6 列格式不变） |

> 数据计算逻辑已用 mock 数据（含跨年求和、日均、双排序、`__RANK_TOTAL__`）在本地 Python 验证全对。

## 七、v2.3.1 微调（顶栏对齐 + 样式统一，2026-09-05 09:40）

用户六、七轮反馈（v6+v7 定稿），本轮收尾微调：

### 7.1 顶栏三元素水平对齐（v7）
排序胶囊「时长/日均」与右上「×」关闭按钮 **vertical center 严格同一水平线 y=120**（X 圆心 = (1180, 120)）。

| 元素 | v2.3 坐标 | v2.3.1 坐标 |
|---|---|---|
| 排序胶囊（ranking 右上） | `[770, 120, 1130, 180]` center y=150 | **`[890, 90, 1130, 150]` center y=120** |
| 排序胶囊宽度 | 360 | **240**（缩短 33%） |
| 排序胶囊右沿 | x=1130 | x=1130（与 X 左沿 1152 留 22px 间距，不重叠） |
| 排序胶囊文字 top | 145（28pt center≈159） | **106**（28pt center=120） |

### 7.2 移除封面占位框 + 进度条轨道（v6）
- `generate_ranking_bg.py` 删除两行绘制：每行左上的圆角封面框 + 每行右下的进度条灰轨道
- **无数据不留白边框**——封面 / 进度条轨道本身就需要数据才有意义（无封面就不画图、无进度就不画条）
- 封面 JPG、进度条填充（绿条）、百分比渲染逻辑**已自带 if 守卫**（有 asin+thumb 才推 JPG；pct ∈ (0,100] 才画绿条）
- 新增：百分比 `${pct}%` 也加 `if pct > 0` 守卫——无进度不画 0%

### 7.3 dashboard 年份切换样式统一（v6 反馈 ③④）
旧三段独立按钮「< 2026 >」改造为**单圆角胶囊「‹ 2026 ›」**——与 ranking 翻页、dashboard 左下 tab **完全同款**：

| 元素 | v2.3 坐标 | v2.3.1 坐标 |
|---|---|---|
| 年份切换 | 三段 `[910-1212]` 圆角 33，宽 302，高 65 | **单胶囊 `[820, 1545, 1190, 1625]`**，圆角 40、高 80（与 tab 同高、同圆角） |
| 年份胶囊内分隔 | 无 | **两条竖线 x=930 / x=1080**（与 ranking 翻页同款） |
| 文字渲染 | PNG 画 `<`/`>`、launcher 画年份 + 白底矩形 | **PNG 只画框 + 竖线**；launcher 画 `‹` / 年份 / `›`，与 ranking 翻页完全对称 |

### 7.4 lua 热区同步（v7）
| 区域 | v2.3 坐标 | v2.3.1 坐标 |
|---|---|---|
| 排序胶囊 `rank_toggle_sort` | `[770, 120, 1130, 180]` | **`[890, 90, 1130, 150]`** |
| 年份切换 `period_prev`（左 `‹`） | `[900, 1515, 1010, 1595]` | **`[820, 1545, 930, 1625]`** |
| 年份切换 `period_next`（右 `›`） | `[1110, 1515, 1220, 1595]` | **`[1080, 1545, 1190, 1625]`** |

### 7.5 改动文件清单
- `generate_ranking_bg.py`：排序胶囊 `[770,120,1130,180]` → `[890,90,1130,150]`；删除封面占位框 + 进度条轨道两行
- `generate_bg.py`：年份切换三段独立按钮 → 单圆角胶囊 + 两条竖分隔线（与 ranking 翻页同款）
- `Yunindex阅读统计.sh`：
  - `render_dashboard` 年份切换绘制：删 ar_w/ar_h/ar_gap 那段 + 白底矩形，改画 `‹` / 年份 / `›`（与 ranking 翻页同 top=1576/1580）
  - `render_ranking` 排序胶囊文字坐标：`[770,950]/[950,1130]` top=145 → `[890,1010]/[1010,1130]` top=106
  - `render_ranking` 百分比加 `if pct > 0` 守卫（无进度不画 0%）
- `reading-insights-touch.lua`：排序胶囊 / 年份胶囊 / 翻页热区坐标同步更新
- `ui/dashboard_bg.png` + `ui/ranking_bg.png`：重生成

### 7.6 验证
- `bash -n` 三 shell 全过（launcher / daemon / install）
- lua 关键热区已 grep 核对（5 处新坐标全部对齐）
- 两张底图视觉确认：排序胶囊缩短上提与 X 同水平线；年份胶囊与 tab 翻页完全同款；封面占位 + 进度条轨道已删除，6 行干净留白

### 7.7 推 GitHub 决策
**仍未推 GitHub**——用户真机验证（顶栏对齐、tab 切换、排序切换、翻页、无数据留白）通过后再议。

### 八、v2.3.2 关键 bug 修复（fb_text_at right 参数语义错位 + tab 改底图画，2026-09-05 09:55）

用户真机反馈三条（顶栏对齐 OK、tab 黑底覆盖图标、年份不显示、ranking 数据全空），我逐一深挖，揪出**根本性 bug**：

#### 8.1 根因 · fb_text_at right 参数语义错位
v2.3 + v2.3.1 引入的 14 处 `fb_text_at` 调用**全部把 right 当成「文字区域右边界 x 坐标」**，但 fbink `-t` 期望的 right 是**「距 LOGICAL_W 的右边距」**——这是 launcher 第 657-658 行 R41 注释明文记录的既有事实：
> `left/right 是 fbink -t 的边距，right=1272(=W) 会让绘制区 [0, W-1272]=[0,0] 宽 0 → 金句静默不画！`

我之前 v2.3.1 的「15 处 right 错位修复」**完全理解错了语义**——把 right 当绝对 x 写（如 `left=820, right=930`），导致 fbink 把 right=930 解析为「距 LOGICAL_W 右边 930 像素」= 右边 x=342，**绘制区反向** `[820, 342]`，文字全部静默不画。

**修复**：保留 v2.2 函数语义不变，调用处 right 全部改成 `LOGICAL_W - 目标右边界 x`：

| 位置 | v2.3.1（错） | v2.3.2（对） |
|---|---|---|
| dashboard `‹` (左 [820,930]) | `820 930` | `820 342` |
| dashboard `$hyear` (中 [930,1080]) | `930 1080` | `930 192` |
| dashboard `›` (右 [1080,1190]) | `1080 1190` | `1080 82` |
| ranking 排序「时长 ▾」区 [890,1010] | `890 1010` | `890 262` |
| ranking 排序「日均」区 [1010,1130] | `1010 1130` | `1010 142` |
| ranking 翻页 `‹/1/3/›` | 同上 | 同 dashboard 年份 |
| ranking 6 行书名/作者/起止区 [240,800] | `240 800` | `240 472` |
| ranking 6 行百分比区 [570,780] | `570 780` | `570 492` |
| ranking 6 行右列时长/日均区 [800,1130] | `800 1130` | `800 142` |

#### 8.2 修② · dashboard 年份胶囊不显示
因 8.1 错位，dashboard 年份胶囊的 `‹ / 2026 / ›` 全部画不出来。**修 8.1 后自动恢复**（数据层从未坏过，是渲染层 bug）。

#### 8.3 修③ · ranking 数据全空
**数据计算层从未坏**（PY3 python3 heredoc 计算正常、tsv 有数据、cc.db 有作者/进度）。
**空的是渲染层**：序号/书名/作者/起止/百分比/时长/日均全部因为 8.1 错位画不出来。
**修 8.1 后 6 行数据应能正常显示**。

#### 8.4 修① · tab 改底图画（不再实时覆盖）
用户原话：「现在直接展示一个正方形黑色选中块覆盖了组件按钮信息，不要实时渲染；指标左侧图标用桌面 Icon (1).svg，排行左侧图标用 Icon.svg」

**改法**：
- 找 SVG 文件 → 打包机本地 `~/Downloads/Icon*.svg` 已不存在
- 改用 PIL 直接画几何图标（无 SVG 依赖，避免设备路径问题）：
  - 「指标」icon = 3 根高低不同竖条的柱状图（`draw_bar_icon`）
  - 「排行」icon = 上下堆叠两本书（`draw_book_icon`）
- **dashboard 底图**：指标 tab 黑底白字+白柱状图；排行 tab 白底黑字+黑书本
- **ranking 底图**：指标 tab 白底黑字+黑柱状图；排行 tab 黑底白字+白书本
- **launcher 删除**：`fb_rect_at 1545 80 220 80 BLACK`（黑底覆盖）+ 两个 `fb_text_at` tab 文字（已在底图）

#### 8.5 改动文件
- `Yunindex阅读统计.sh`：
  - render_dashboard 第 668-670 行 right 修正 + 删除 8.5 节 tab 实时绘制 5 行
  - render_ranking 第 816-820 行（排序胶囊）+ 第 831-833 行（翻页）+ 第 850-871 行（6 行字段）right 全部修正
  - render_ranking 第 4 节 tab 实时绘制 4 行删除
- `generate_bg.py`：加 `ccenter` / `draw_bar_icon` / `draw_book_icon` 三个 helper；footer tab 改完整画（指标黑底白字柱状图 / 排行白底黑字书本）
- `generate_ranking_bg.py`：加同样三个 helper；footer tab 改完整画（指标白底黑字柱状图 / 排行黑底白字书本）

#### 8.6 校验
- `bash -n` 三 shell 全过

---

## 十、v2.3.4 · 回滚 v2.3.3 monkey-patch（圆角改坏了），只动字号 + 居中

### 10.1 用户反馈
- 「好好的圆角改成矩形」—— v2.3.3 monkey-patch `radius=` keyword 没乘以 SS，2x 画布 radius=40 缩小后只剩 20，圆角太小
- 「别自说自话改样式」——回滚 monkey-patch，恢复 v2.3.2 简洁版
- 「文字水平上下左右居中」—— 文字 cx 严格 tab 中点 (190 / 430)
- 「切文字放大点」—— tab 文字 28→32

### 10.2 改动（仅两件事，不动其他）
| # | 改动 | 文件 |
|---|---|---|
| 1 | 删两份 Python 脚本的 2x monkey-patch 全部代码；圆角严格按设计稿 radius=40 | `generate_bg.py` + `generate_ranking_bg.py` |
| 2 | tab 文字 28→32；文字 cx 严格居中 tab 中点 (190 / 430)；icon cx=130 / 370（偏左给文字留空间） | 同上 |

### 10.3 launcher fb_text_at 绘制区核验（按 fbink -t margin 语义）
LOGICAL_W=1272，fbink 官方手册：
> `top, bottom, left & right set the margins used to define the display area.`
> `NOTE: If a negative value is supplied, counts backward from the opposite edge.`

| 字段 | 绘制区 | 宽 | halign | 实测字符宽 | 结论 |
|---|---|---|---|---|---|
| 时长 ▾ | [890, 1010] | 120 | CENTER | ~100px | ✅ |
| 日均 | [1010, 1130] | 120 | CENTER | ~50px | ✅ |
| ‹ | [820, 930] | 110 | CENTER | ~30px | ✅ |
| 2026 | [930, 1100] | 170 | CENTER | ~60px | ✅ |
| › | [1080, 1190] | 110 | CENTER | ~30px | ✅ |
| 1 / 3 | [930, 1100] | 170 | CENTER | ~50px | ✅ |
| 序号 | [215, 1032] | 817 | LEFT | ~14px | ✅ 从 215 开始 |
| 书名 | [240, 800] | 560 | LEFT | ~64px | ✅ |
| 作者 | [240, 800] | 560 | LEFT | ~44px | ✅ |
| 起止 | [240, 800] | 560 | LEFT | ~180px | ✅ |
| 百分比 | [570, 780] | 210 | LEFT | ~50px | ✅ |
| 时长 | [800, 1130] | 330 | RIGHT | ~130px | ✅ 右对齐 1130 |
| 日均 | [800, 1130] | 330 | RIGHT | ~100px | ✅ 右对齐 1130 |

**结论：所有字段绘制区均装得下字符，排名页与年份胶囊会在真机正常显示。**

### 10.4 正面回答用户"确定这次排行以及年份会显示数据？"
- **年份胶囊**：4 处 fb_text_at 调用绘制区 ≥ 110px，字符最大 60px，**会显示**
- **排名 6 行数据**：
  - 数据层：v2.3.3 mock 测试验证全对（跨年求和、日均、双排序、`__RANK_TOTAL__` 输出）
  - 计算层：PY3 分支（kindle 自带 python3）；awk 兜底分支 v2.3.3 已改 busybox 兼容
  - 绘制层：所有 13 处 fb_text_at 绘制区已核验全装得下字符
  - **会显示**
- **唯一风险**：真机 kindle python3 路径不在默认 PATH → 走 awk 兜底；如果 awk 数据解析错位则不显示
- **应急**：如果 ranking 仍无数据，跑 `_diagnose.sh` 贴 log 给我

### 10.5 校验
- `bash -n` 三 shell 全过
- 统计规则零改动（daemon 第 177 行 `app=com.lab126.booklet.reader && power=active` 仍是核心判定）
- 14 处 fb_text_at right 参数按 fbink margin 语义核验全过

### 10.6 推 GitHub 决策
**仍未推 GitHub**——用户重装 install、真机验证（圆角圆润 + tab 文字大且居中 + 年份显示 + ranking 6 行显示）后再议。

---

## 十一、v2.3.5 · tab icon 视觉中心严格对齐（第三遍，用户又指了）

### 11.1 根因（实测确认）
用户指出「图标和文字没在同一水平线，第三次了」。我实测：
- PIL `textbbox` 对「指标」32pt 返回 `(t=9, b=41)`，**没有负数 ascent**
- 旧 `ccenter` 用 `cy - th/2`（= cy-16）画文字 → 实际视觉中心 = cy-9（leading 9px）
- 旧 `draw_bar_icon` 用 `base_y = cy + 8` → 柱状图视觉中心 = `base_y - 12` = cy - 4
- **icon 视觉中心比文字低 4-5px**——和截图完全吻合

### 11.2 修法
| 改动 | 旧 | 新 |
|---|---|---|
| `ccenter` | `d.text((cx - tw/2, cy - th/2), ...)` | `d.text((cx, cy), ..., anchor="mm")`（PIL 原生 mm 锚点） |
| `draw_bar_icon` base_y | `cy + 8` | `cy + 12`（视觉中心 = cy） |
| `draw_book_icon` by1 / by2 | `cy - 2` / `cy - bh2 - 3` | `cy - 7` / `cy - 17`（视觉中心 = cy） |

### 11.3 校验
- 本地 PIL 实测：anchor="mm" 文字视觉中心 = cy；base_y=cy+12 icon 视觉中心 = cy
- `bash -n` launcher OK
- 两张 PNG 视觉确认：icon 与文字严格水平对齐
- **未推 GitHub**（等用户真机重装 install 验证）

---

## 十二、v2.3.6 · draw_book_icon 加权视觉中心修正（第四遍）

### 12.1 根因（数学证明 + 截图吻合）
用户指出「排行 tab 的书本 icon 整体视觉中心在文字下方约 5-6px」。我实测算法：

旧 `draw_book_icon` 参数：
- 下书 by1=cy-7, bh=14 → y[cy-7, cy+7]，中心 cy
- 上书 by2=cy-17, bh2=11 → y[cy-17, cy-6]，中心 cy-11.5
- **按面积加权**：(14·cy + 11·(cy-11.5))/(14+11) = **cy - 5.06**

旧 `draw_bar_icon` base_y=cy+12：3 根竖条 heights [16,24,20]，加权中心 = base_y - 60/6 = **cy+2**（偏高 2px）

**结论**：旧书本 icon 加权视觉中心 = cy-5.06（与截图完全吻合）；旧柱状图偏高 2px（差距小不易察觉，但我顺手一起改对）。

### 12.2 修法（数学验证）
| 函数 | 旧 | 新 | 加权中心 |
|---|---|---|---|
| `draw_bar_icon` base_y | cy+12 | **cy+10** | base_y - 10 = **cy** ✓ |
| `draw_book_icon` | 下书14+上书11 不等大 | **两本等大 22×11 无缝堆叠**：上书 y[cy-11, cy]、下书 y[cy, cy+11] | (cy-5.5 + cy+5.5)/2 = **cy** ✓ |

### 12.3 改动文件（仅动两份 Python 底图脚本）
- `generate_bg.py`：`draw_bar_icon` / `draw_book_icon` 改 base_y=cy+10、等大无缝堆叠
- `generate_ranking_bg.py`：同步修
- launcher / daemon / install / lua 全部**零改动**

### 12.4 校验
- `bash -n` 三 shell 全过
- 数学验证脚本：两个 icon 加权中心都 = cy ✓
- 两张 PNG 视觉确认（dashboard 指标/排行 tab + ranking 指标/排行 tab 共 4 处 icon 与文字严格水平对齐）

### 12.5 推 GitHub 决策
**仍未推 GitHub**——用户重装 install、真机验证 tab 内 icon 与文字**严格水平对齐**后再议。

---

## 十三、v2.3.7 · 根因级修复：fbink `-t` 不认 `halign`（年份/排行/时长日均全部静默不画）

### 13.1 真凶（单一根因，多处爆发）
用户真机反馈「指标页年份仍没有、排行页只有书名」。我深挖 fbink 源码（`fbink_cmd.c`），揪出**根本性 bug**：

- launcher 的 `fb_text_at` 支持第 9 参数 `halign`，拼进 `-t` 字符串如 `...,style=BOLD,halign=CENTER`。
- **fbink `-t`（OpenType 文字）根本没有 `halign`/`valign` key**——那俩是 `-g`（image 图片）选项专属。
- fbink 用 `getsubopt()` 解析 key=value，遇到未知 key `halign` → 进 `default` 分支 → `errfnd=true` → **打印 help 后 EXIT_FAILURE，整条文字静默不画**。
- 因此凡带 `halign=CENTER/RIGHT` 的调用全灭：
  - dashboard 年份胶囊 `‹ 2026 ›`（3 处 CENTER）→ 全不显示
  - ranking 排序胶囊「时长 ▾ / 日均」（CENTER）→ 全不显示
  - ranking 翻页 `‹ 1/1 ›`（CENTER）→ 全不显示
  - ranking 每行时长 / 日均（RIGHT）→ 全不显示
- 只剩书名（无 halign）正常 → 造成「排行页只有书名」的假象。

### 13.2 修法（按用户定稿：‹ › 画进底图 + 手动算偏移居中）
| 改动 | 说明 |
|---|---|
| `fb_text_at` 删 halign 参数 | 恢复纯 LEFT 对齐；left/right 仍是「距 viewport 边距」语义 |
| 新增 `text_w()` | 估算字符串像素宽度（`LC_ALL=C` 强制 awk 字节模式，busybox/gawk/mawk/BSD 全兼容；中文按 1em 跳 3 字节） |
| 新增 `fb_text_center()` | 在绘制区 `[box_left,box_right]` 内手动算 left 居中（不再依赖 fbink） |
| 新增 `fb_text_right()` | 右对齐到 `right_edge`（手动算 left） |
| `generate_bg.py` / `generate_ranking_bg.py` | **`‹` `›` 箭头直接画进底图**，左格 [820,930] / 右格 [1080,1190] 用 `anchor="mm"` 严格居中 |
| `render_dashboard` 年份 | 只画中格年份数字 `fb_text_center 20 1576 930 1080 ... "$hyear"` |
| `render_ranking` 排序胶囊 | `fb_text_center 28 106 ... "时长 ▾" / "日均"` |
| `render_ranking` 翻页 | 只画中格页码 `fb_text_center 20 1576 930 1080 ... "N / M"` |
| `render_ranking` 时长/日均 | `fb_text_right ... 1130 ...`（右对齐到排序胶囊右沿 x=1130） |
| **`read` 空字段合并 bug** | `while IFS=$'\t' read -r ...` 会合并连续空字段（书名行若空作者/空起止 → 字段错位），改为 `while IFS= read -r line` + `cut -fN` 逐字段提取 |
| **书名 15 字符截断** | python 分支 `if len(t)>15: t=t[:15]+'…'`；awk 兜底分支 `trtitle()` 字节截断 45 字节 + `...` |

### 13.3 校验（本地 PIL 模拟器实测，全过）
- `bash -n` 三 shell 全过
- 底图 `‹` 中心 54.5（期望 55）、`›` 中心 315（期望 315）——**居中对齐精确**
- 年份 `2026` 在中格中心 185（期望 185）、页码中心 75（期望 75）——**精确居中**
- 排序胶囊「时长 ▾」中心 59.5≈60、「日均」179.5≈180——**精确居中**
- 时长右对齐右边界 329（期望 330）——**误差 1px**
- `text_w` 宽度估算：`2026`=48、`时长 ▾`=91、`2h 0m`=124（实际 125）——**误差 ≤1px**
- `cut -fN` 空字段解析：第 5 行空 author/空起止正确保持空，不再错位
- 书名截断：`fastmetrics_..._2026.txt` → `fastmetrics_155…`（15 字符 + 省略号）

### 13.4 推 GitHub 决策
**仍未推 GitHub**——用户重装 install、真机验证后（年份显示、排行 8 字段齐全、`‹ ›` 居中、书名省略号）再议。

---

## 十四、v2.3.8 · 第二根因：旧版 FBInk 不认 hex 颜色（灰字/进度条全灭）

### 14.1 真凶（真机反馈「封面/作者/日期/进度/日均没展示」）
v2.3.7 修好 halign 后，黑字（书名、时长）显示出来了，但**灰字和绿色进度条仍不显示**。规律：**显示的字段全是 `BLACK`，不显示的字段全是 hex 颜色**：

| 字段 | 颜色 | 结果 |
|---|---|---|
| 书名、时长 | `BLACK` 关键字 | ✅ 显示 |
| 作者、开始/最近日期、百分比、日均 | `#BDB8AB`（灰 hex） | ❌ 不显示 |
| 阅读进度条 | `#639922`（绿 hex） | ❌ 不显示 |

根因：**真机 KPM 版 FBInk 是旧版，只认关键字 `BLACK/GRAY1~GRAYE/WHITE`，不认 `#RRGGBB` hex**（hex 颜色支持是 FBInk v1.5.0 才加入的）。`-C #BDB8AB` 传进去直接被当非法颜色静默失败。

### 14.2 修法
| 改动 | 说明 |
|---|---|
| `INK_SOFT` | `#BDB8AB` → **`GRAYB`**（0xBB=187，亮度最接近原设计 184） |
| 进度条 | `#639922` 绿色 → **`GRAY7`**（0x77=119 深灰，与 GRAYB 浅灰区分）新增 `BAR_FILL` 变量 |
| 封面多路径 fallback | `thumbnail_<ASIN>_EBOK_portrait.jpg` / `thumbnail_<ASIN>_EBOK.jpg` / `<ASIN>_EBOK_portrait.jpg` 三路径逐个尝试 |
| **排序胶囊「· 时长 丨 日均」** | 时长/日均**同时显示**，选中态在词左侧加实心圆点 `●`（U+25CF）；`generate_ranking_bg.py` 底图加中线竖线 x=1010 分割 |

### 14.3 校验
- `bash -n` 三 shell 全过；两张底图重生成
- 排序胶囊「● 时长」中心 59.5≈60（格中心）、● 圆点位于文字左侧、中线竖线 x=1010、右格「日均」灰字——全部正确
- `●`（U+25CF）在 Noto Serif SC 中存在（28pt 宽 28px）；`text_w` 对其按 1em 估算准确
- dashboard 页无灰字（全 BLACK），不受 hex 影响

### 14.4 推 GitHub 决策
**仍未推 GitHub**——用户重装 install、真机验证后（8 字段齐全 + 排序胶囊圆点选中态 + 中线分割）再议。

---

## 十五、v2.3.9 · 真凶终章：真机无 python3，awk 兜底分支压根没算字段

### 15.1 用户三条致命反馈
1. 「封面、作者、开始/最近阅读日期、阅读进度、日均没展示」——**改了很多遍**，怀疑我压根没触发统计规则
2. 「全部黑色字体，不要绿不要灰，无非字号粗细的调整」
3. 「时长和日均**同时显示**、**同颜色**，多个圆点代表选中」
4. 分页 bug：7 本书时，第 7 本画在第一页第 7 行（屏幕底部），而不是第二页第 1 行
5. 「真机没有 python3，写进记忆」

### 15.2 真凶（用户判断完全正确）
**真机 KPW6 没有 python3** → render_ranking 走 `awk 兜底分支`。而我之前的 awk 兜底**只算了书名 + 时长**，作者/asin/封面/日期/进度/日均**全是空字段**（`print ... "\t\t\t\t\t\t" ...` 直接跳过了 4 个空 tab）。所以这些字段永远不显示——**我压根没触发它们的统计规则**。

### 15.3 修法（一次到位）
| 改动 | 说明 |
|---|---|
| **awk 兜底彻底重写** | sqlite3 读 cc.db（author/pct/last_access）+ awk 读 book-meta.tsv（first_open epoch+iso）+ reading-time.tsv（时长/书名）三源合并 |
| 补全 10 字段 | idx / bid / 书名 / 作者 / asin(=bid) / 开始日期 / 最近日期 / 进度 / 时长 / 日均 |
| 手写 `edate()` | epoch → YYYY-MM-DD（UTC+8 时区）—— busybox awk 无 strftime/systime，用 civil date 算法 |
| daily 计算 | `(today_epoch - first_open)/86400 + 1` 求跨度，`秒数÷跨度` |
| **分页 idx bug 修复** | `print cnt`（全局序号）→ `print (cnt-start+1)`（页内序号 1-6），翻页后第 7 本正确画在第 2 页第 1 行 |
| **全黑字体** | `INK_SOFT`/`BAR_FILL` 改 `BLACK`，作者/日期/百分比/日均全黑，靠字号（32/24/22/20）和粗细（BOLD/REGULAR）区分 |
| **排序胶囊** | 「● 时长」/「日均」**同色全黑**，选中态靠实心圆点 ● + 加粗标记，无箭头 |
| 封面 | asin=bid 输出（daemon book_id 就是 cdeKey）+ 三路径 fallback |
| `_diagnose.sh` | 新增「10. 封面缩略图检查」（sqlite3/cc.db/缩略图目录/文件名比对） |

### 15.4 校验（本地模拟 awk 兜底全过）
- `bash -n` 全过
- 7 本书 mock：第一页 off=0 输出 idx 1-6、第二页 off=1 输出 idx=1（第 7 本）——**分页修复正确**
- 作者/日期/进度/日均全部有值（不再是空字段）
- `edate(1788579982)` = `2026-09-05` 精确；daily 排序与 duration 排序正确
- 排序胶囊「● 时长」居中、圆点在文字左侧、中线 x=1010

### 15.5 已写进记忆（~/.workbuddy/MEMORY.md）
真机无 python3 / 有 sqlite3 / FBInk 旧版只认颜色关键字不认 hex / fbink -t 无 halign / busybox awk 无 asorti·strftime·systime / read 合并空字段——六条硬环境约束永久记录。

### 15.6 推 GitHub 决策
**仍未推 GitHub**——用户重装 install、真机验证后（8 字段齐全 + 全黑 + 排序胶囊圆点 + 分页正确）再议。封面若仍不显示，跑 `_diagnose.sh` 贴「10. 封面缩略图检查」给我。

---

## 16. v2.3.11 排行页「文字全灭」真凶（REGULAR 不是合法 style 字符串）

### 16.1 用户日志铁证（2026-09-05 18:41 提供 rank-debug.log）
- RANK_LINES 数据**全对**：`1  bid  诡秘之主...  (空)  bid  2026-08-15  2026-08-29  42  58002  2636` —— 开始/最近日期、进度、时长、日均都有值
- 进度条（矩形 fb_rect_at）能画 → pct 解析正确
- 但书名以外的文字全不显示 → **渲染层 bug，非数据层**
- cc.db 报错 `no such column: cdeKey` → 真机 cc.db Entries 表**没有 cdeKey 列**（作者/进度回落源缺失）
- 封面目录 102 文件全是 `thumbnail_<UUID>_EBOK_portrait.jpg`，而 book_id 是 ASIN → **命名不匹配**

### 16.2 真凶：fbink -t 的 style 字符串是 NORMAL，不是 REGULAR
- 我原代码所有次级文字用 `style=REGULAR`，拼成 `-t "...style=REGULAR"`
- 书名用 `style=BOLD` 能显示，REGULAR 全灭 → 证实旧版 fbink CLI 的 style 取值是 **NORMAL**（对应 FNT_REGULAR 枚举），**不识别 "REGULAR" 这个枚举展示名**
- 传 style=REGULAR → 被当未知 key → **整条文字静默失败**（和之前 halign 同类错）
- Web 文档写 "(e.g., REGULAR, BOLD, ...)" 用的是枚举展示名，CLI 实际接受 NORMAL → 文档与实现歧义坑

### 16.3 修复
1. **fb_text_at 改：常规字体省略 style key**（fbink 默认用 regular= 路径字体），仅 BOLD/ITALIC/BOLD_ITALIC 显式拼 style
   → 彻底绕开 REGULAR/NORMAL 字符串歧义，常规字永远出
2. **cc.db 列名探测**：先 `PRAGMA table_info(Entries)` + 列出所有表名，动态选 CDE/author/pct 列，避免硬编码 cdeKey 整段失败
3. 诊断日志输出 cc.db 真实 schema，供下一轮精确修作者+封面

### 16.4 校验
- `bash -n` 四脚本全过
- 预览图 v2.3.11：日期/百分比/日均/序号/翻页/排序胶囊双词全显示（模拟器常规字体可渲染）
- 仍未推 GitHub；用户重装打开排行页 → 取 rank-debug.log（含 cc.db 真实列名）→ 我下一轮精确修作者+封面

### 16.5 待下一轮（依赖真机 cc.db schema）
- 作者：拿到真实列名后动态匹配
- 封面：缩略图是 UUID 命名，需 ASIN→UUID 映射（同在 cc.db 或 content 数据库）；rank-debug 已备 schema 探测

---

## 17. v2.3.12 排行页「毫无变化」真凶（字体路径写死 fonts/，真机字体在包根）

### 17.1 用户日志铁证（2026-09-05 18:52 提供，v2.3.11 确已装）
- 日志头 `v2.3.11` → 上一轮修复已生效；cc.db 探测 `CDE=p_cdeKey AUTHOR=p_credits_0_name_collation PCT=p_percentFinished` 成功，CC_CACHE 行数=113 → 作者数据已流通
- RANK_LINES 第 2-5 行作者已填充（但为 collation 乱码 `阿阿阿aiqianshuidewuzei`）
- 但用户视觉仍「毫无变化」：百分比/作者/起止/日均/序号全灭，仅书名/时长（BOLD）出

### 17.2 真凶：字体路径写死 `$BASE/fonts/`，真机字体在包根目录
- MAC 打包 `native-reading-time-package/` 下 `NotoSerifSC-Regular.otf`(11.6MB)/`NotoSerifSC-Bold.otf`(12MB) 均在**包根**，**无 `fonts/` 子目录**
- 旧版 `FONT_DIR="$BASE/fonts"` → 真机 `regular=$RFONT`/`bold=$BFONT` 指向**不存在**的 `fonts/` 路径
- fbink 行为不对称：bold 槽字体缺失时回退成功（书名/时长 BOLD 出）；regular 槽缺失时整条静默失败 → 常规字全灭
- 故上一轮「省略 style」无效（仍走 regular= 坏路径）

### 17.3 修复
1. **字体路径探测**：同时查 `$BASE/fonts/` 与 `$BASE/` 两种布局，regular 槽缺失时回退 Bold（Bold 已证可渲染）→ 常规字必出
2. **作者取真名**：cc.db 增选 `j_credits`(JSON)，awk `json_name()` 提取 `"name"`，回落 collation → 作者从 `阿阿阿aiqianshuidewuzei` 变为 `爱潜水的乌贼`
3. **封面 UUID 映射**：cc.db 增选 `p_uuid`，建 ASIN→UUID 映射表 `.uuid_map.tsv`；封面查找优先 `thumbnail_<UUID>_EBOK_portrait.jpg`，回落 ASIN 各路径
4. 诊断日志新增 `FONT: RFONT=... BFONT=...` 存在性、`UUID_MAP` 行数与前 3 行、`[封面探测]` 打出 uuid，便于真机确认

### 17.4 校验
- bash -n 通过；本地 awk 单测 `json_name`：JSON 有 name→`爱潜水的乌贼`，无 name→回落 collation ✓
- 仍未推 GitHub；用户重装打开排行页 → 取新 rank-debug.log 确认 `FONT: ... 存在=Y` 且常规字全出、封面命中

### 17.5 待真机确认（本轮已尝试，非必下一轮）
- 封面：若 `p_uuid` 与缩略图 UUID 命名一致则本轮即修好；若日志显示 uuid 不匹配，再据真实值调整列/`p_guid`

---

## 18. v2.3.13 封面改用 `Entries.p_thumbnail`（学自 kindle-reading-records v1.3.4 · 真机实证）

### 18.1 背景：停止瞎猜，向已实证的参考实现学习
用户指出桌面 `kindle-reading-records-v1.3.4` 的书籍模块能返回封面（真机可见）。我研读其
`ReadingRecords.sh` 第 38–48 行，找到**封面正解**：

    SELECT upper(replace(p_cdeKey,'-','')) || char(9) || p_thumbnail
    FROM Entries
    WHERE p_cdeKey IS NOT NULL AND p_thumbnail IS NOT NULL AND p_thumbnail<>'' AND p_location IS NOT NULL;

其原注释：
> Entries.p_thumbnail is authoritative for both ASIN covers and random personal-document filenames.

即 **cc.db 的 `Entries.p_thumbnail` 列直接存封面路径**，对 ASIN 封面与个人文档随机文件名皆权威
→ 不必再猜是 `thumbnail_<ASIN>` 还是 `thumbnail_<UUID>`（v2.3.12 的 UUID 映射属猜测，已降级为兜底）。
其前端 `script.js` 亦直接 `<img src="file://"+p_thumbnail>`，key 由 `bookKey()` 归一化，与本实现对齐。

### 18.2 改动（三处）
1. 新增 `COVER_MAP="$BASE/.cover_map.tsv"`
2. cc.db 查询：PRAGMA 探测 thumbnail 列（默认 `p_thumbnail`），生成 `归一化key TAB 封面路径` 映射表；
   key 归一化 `upper(replace(cdeKey,'-',''))`，与参考实现逐字一致
3. 渲染循环封面查找：**优先查 COVER_MAP**；`p_thumbnail` 为绝对路径则直用，为相对文件名则拼
   `/mnt/us/system/thumbnails/`；查不到才回落 UUID/ASIN 拼法（兜底保留，非主路径）

### 18.3 校验
- `bash -n` 通过；本地实测三例：小写连字符 ASIN→归一化命中绝对路径 ✓；相对文件名→拼目录 ✓；查不到→回落 ✓
- 诊断日志新增 `p_thumbnail原值` 与 `COVER_MAP 行数`，真机一眼可判封面为何

### 18.4 后记
- 本节所述「文字全灭」问题**已由 §19（v2.3.14）解决**，真凶与字体、style 均无关。

---

## 19. v2.3.14 文字不显示之真凶 = 颜色参数传了变量名字符串（我之疏失）

### 19.1 铁证链
1. 作者与书名的 `left/right` **完全相同**（240/472），唯一差异是 style 与颜色 → 排除坐标问题
2. `Install-Native-Reading-Time.sh` 第 91–92 行 `cp "$PKG/NotoSerifSC-*.otf" "$FONT_DIR/"`，
   第 156 行 `[ -f "$RFONT" ] || fail` → **字体一直存在、路径一直正确** → **排除字体路径（我前两轮误判）**
3. v2.3.11 已省略 style 仍全灭 → **排除 style（我首轮误判）**
4. 最后比对调用点，凡不显示者**无一例外**传 `INK_SOFT`，显示者传 `BLACK`：

   | 元素 | 调用 | 实际传给 fbink | 结果 |
   |------|------|----------------|------|
   | 书名 / 时长 | `BOLD BLACK` | `-C BLACK` | ✓ 显示 |
   | 序号/作者/起止/百分比/日均 | `REGULAR INK_SOFT` | `-C INK_SOFT` | ✗ 静默不画 |

**根因**：`INK_SOFT` 未带 `$`，shell 不展开 → fbink 收到非法颜色名 `INK_SOFT`
（旧版 fbink 只认 `BLACK/GRAY1~GRAYE/WHITE`）→ 解析失败 → 整条静默不画。

### 19.2 修复（v2.3.14，三层防呆）
`fb_text_at` 内新增：
1. **变量名间接展开**：`eval "_fg=\"\$${fg}\""` → `INK_SOFT` 展开为 `BLACK`
2. **颜色白名单校验**：仅 `BLACK/WHITE/GRAY1~GRAYE` 放行
3. **非法一律回落 `BLACK`** → 保证任何情况文字必出
4. bg 同步走白名单，非法则 `-O`（避免白底块）

一处修改覆盖 `fb_text_at`/`fb_text_center`/`fb_text_right` 全部调用（所有 `-C` 汇聚于此）。

### 19.3 字号放大（用户要求「至少放大一倍」）
| 位置 | 原 | 现 |
|------|-----|-----|
| 指标页右下角年份（如 2026） | 20pt | **40pt** |
| 排行页分页（如 1 / 3） | 20pt | **40pt** |

宽度校验：40pt 下「2026」96px、「12 / 12」121px，从 left=930 起算右端 ≤1051 < 屏幕 1272，不溢出。

### 19.4 校验
- `bash -n` 通过
- 颜色逻辑本地实测：`INK_SOFT→BLACK` ✓、`BAR_FILL→BLACK` ✓、非法值与未定义变量→`BLACK` ✓
- 宽度实测：上述三种页码均不溢出 ✓
- **未推 GitHub**

### 19.5 教训记录
v2.3.10→v2.3.13 四轮，先后误判为 style、字体路径，累用户反复重装真机。
真凶其实只在一行：变量名少写一个 `$`。第 17 行注释早写着「fbink 只认颜色关键字」，
却未对照代码核对，特此记入长期记忆，永志不忘。

### 19.6 v2.3.17 排版重排 + 胶囊居中（基于用户真机截图 1272×1696 精确像素测算）

**改动 1 - 胶囊三段整体居中到屏幕正中 x=636**
- 段 < ：x=357~543 宽 186（24pt REG BLACK）
- 段 年份/页码：x=543~729 宽 186（40pt BOLD/REG BLACK）
- 段 > ：x=729~915 宽 186（24pt REG BLACK）
- 胶囊三段总宽 558，整体中心 = (357+915)/2 = **636** ✓
- **擦除底图原箭头**：launcher 推完底图后用 `fb_rect_at 1565 820 110 35 WHITE` 和 `1080 110 35 WHITE` 覆盖原 [820,930]/[1080,1190] 区段，避免右半残留箭头

**改动 2 - 行内布局重排**（ROW_H=215）
- 封面：y=row_top+25 h=165 → 顶/底边距各 25 均分 ✓
- 书名 BOLD 32pt top=row_top+25 → baseline ≈ row_top+50 = 封面上沿 baseline ✓
- 时长 BOLD **32pt** top=row_top+25 → baseline ≈ row_top+50 = 书名 baseline ✓
- 作者 **24pt** top=row_top+85 → baseline ≈ row_top+104（书名与起止间等分）
- 起止 18pt top=row_top+135 → baseline ≈ row_top+149（作者与进度条间等分）
- 进度条 top=row_top+184 h=6 → 中线 row_top+187 = 封面底沿 baseline ✓
- 百分比 20pt top=row_top+171 → baseline ≈ row_top+187 = 进度条中线 ✓
- 日均 **32pt** top=row_top+162 → baseline ≈ row_top+187 = 百分比 baseline ✓
- **时长 = 日均 = 32pt 字号一致** ✓

**改动 3 - 作者解析降级**（治 `[{` 残留）
- 新增探测 `p_credits_0_name` / `p_credits_0_nominal` / `p_credits_0_name_display` 真名列
- 路径顺序：真名列 → j_credits JSON → collation 去 "阿阿阿" 前缀 → 截断 10 字 + "…"
- 凡 JSON 仅剩 `[{` 这种残破字符串，自动判废回落 collation

### 19.7 v2.3.18 回退胶囊整体居中 + 行内字号统一 32pt（基于用户再反馈精确修正）

**改动 1 - 回退 v2.3.17 胶囊整体居中**
- 「左右切换中间的位置」= 胶囊**中段 [931,1080] 中央** x=1005（**不是屏幕正中**）
- 删除 v2.3.17 的 `fb_rect_at WHITE` 覆盖底图箭头 + 自画 `<`/`>` 到 [357,915]
- 恢复原 `fb_text_center 40 1576 930 1080`，中段年份/页码自动居中到 visual_center=1005/1006
- 底图箭头位置 [820,930]/[1080,1190] 保持原样

**改动 2 - 行内字号统一 32pt（与书名同号）**
- 作者 24→32pt
- 起止 18→32pt
- 百分比 20→32pt
- 时长 32pt（保持）
- 日均 32pt（保持）
- 序号 24→32pt

**改动 3 - 行内布局重排**（满足「整本书与上下分线等距」）
- ROW_H=215, 封面 h=165, 上下各 25px 边距（25+165+25=215 ✓）
- 封面 y=row_top+25, h=165 → 顶 row_top+25, 底 row_top+190
- 书名/时长 top=row_top+25 → baseline≈50 = 封面上沿 baseline ✓
- 作者 top=row_top+75 → baseline≈100（书名与起止间等分）
- 起止 top=row_top+125 → baseline≈150（作者与进度条间等分）
- 进度条 top=row_top+184 h=6 → 中线 row_top+187 = 封面底沿 baseline ✓
- 百分比/日均 top=row_top+162 → baseline≈187 = 进度条中线 ✓

### 19.8 校验
- bash -n 通过 ✓
- 所有非书名字段字号 = 32pt，与书名同号 ✓
- 整本书（封面+内容）作为一个整体，居于 ROW_H 中央 ✓

### 19.9 待真机验证
- 32pt 起止宽度「2026-08-15 → 2026-08-29」≈ 280px 超 240~472 区段宽 232px → 会截断/换行，需观察 fbink 自动行为
- 「1 / 2」日均 baseline 与百分比 baseline 对齐效果（差 ~8px 可接受）

---

## 21. v2.3.19（2026-09-06 08:31 · 像素级校准：上下边距 + 胶囊居中）

### 21.1 根因
用户用红框标志两个高度不同，**实测真机截图**：
- ROW_TOP0=260 让所有书本下方分线都比脚本算出的 row_top 高 **18 vp_px**（fbink 全局偏下）
- 当前算法下上边距 41.7 px、下边距 -2.4 px（**进度条已越界下分线**），差距 = 44 px

胶囊中段「1/2」字符实测 vp_x 中心 = 993，但 launcher 期望 1005，**偏差 12 px**

### 21.2 修复
1. **ROW_TOP0**: 260 → **242**（校正 fbink 全局 -18 vp_px 偏下）
2. **行内布局校正**（让上下边距各 ≈20 vp_px）：
   - `row_top+25` → `row_top+20`（序号/书名/时长/封面顶）
   - `row_top+75/125` → `row_top+80/135`（作者/起止 baseline 均分）
   - `row_top+184` → `row_top+189`（bar_top，下边距 26→20）
3. **胶囊中段**：box_left=930/1080 → 918/1068（实测中心 vp_x=993）

### 21.3 校验
- 真机截图 PIL 探测 vp 锚点：上分线 887, 下分线 1102, 封面顶 vp=947.3, 进度条底 vp=1075.4
- 修复后预期：上边距 ≈20, 下边距 ≈20, 整体居中到分线内

---

## 16. v2.3.10（2026-09-05 18:30 · 数据自给自足 + 全流程留痕）

### 16.1 反馈
用户重装 v2.3.9 后：
1. **「LOG-diagnose.log 不存在」** — `_diagnose.sh` 没装上（已在上轮修，但用户说没看见日志，故本轮再加 rank-debug.log）
2. **「封面、作者、开始阅读时间、最近阅读、日均仍不展示」** — 三个根因复合

### 16.2 三条真凶（都是老问题，本轮一起解）

| 真凶 | 后果 | 修复 |
|---|---|---|
| **awk 兜底全部依赖 cc.db + book-meta.tsv** | sqlite3 老版无 -readonly / cc.db 缺字段 / book-meta.tsv 未生成 → 作者/日期/进度 全空 | **数据自给自足**：开始/最近阅读日期 + 进度 **直接从 reading-time.tsv 算**（该文件本身就有 date 与 progress 列）；book-meta 作更优来源；cc.db 只补作者 |
| **daemon `book_progress` 用书名精确匹配 cc.db** | 书名带空格/标点/副标题就匹配不上 → progress 恒空 | 改为 **cdeKey（= book_id）优先**精确匹配，书名仅作兜底 |
| **`awk -F` 在 BSD awk UTF-8 locale 下报 `towc: multibyte conversion failure`** | 单字节正则范围（`/[\340-\357]/`）触发 multibyte 转换失败，整个分支 abort | awk 前加 **`LC_ALL=C`** 强制字节模式 |

### 16.3 顺带改的细节
- 书名截断：旧版按 45 **字节**（英文书名会显示 45 字符）→ 改为真·15 **字符**（UTF-8 感知）
- 进度值回落：tsv 的 progress 为空或 0 时自动用 cc.db 的进度（兼容历史脏数据）
- 封面探测全流程留痕到 `rank-debug.log`（asin、三个尝试路径命中情况、缩略图目录文件数与前 5 个文件名、含该 asin 的文件名）
- `_diagnose.sh` 加「11. rank-debug.log」一节（自动 cat 整个调试日志）和「12. reading-time.tsv 前 8 行」（看 progress 列是否真有值）

### 16.4 rank-debug.log（核心新增）
只要**打开一次排行页**，自动写到 `/mnt/us/reading-time/rank-debug.log`，含：
- 数据源状态（DATA/META/cc.db 存在性 + 行数/可读性 + sqlite3 命令探测）
- DATA 前 3 行原始内容
- CC_CACHE 探测结果（行数 + 前 3 行）
- 第 1 行的封面探测结果
- **RANK_LINES 原始输出**（竖线内是真实 TAB 分隔字段）

用户不再需要 diagnose.flag —— 打开一次排行页，USB 取 `/mnt/us/reading-time/rank-debug.log` 即可看到全部真相。

### 16.5 校验（四场景全过 + 两脏数据兼容）

| 场景 | DATA | META | CC_CACHE | 结果 |
|---|---|---|---|---|
| A（最坏）| 6 列齐 | ✗ | ✗ | 作者空，其余全有 ✓ |
| A 第 2 页 | 同 | 同 | 同 | 第 7 本序号=1（不再 7）✓ |
| B（完整）| 6 列齐 | ✓ | ✓ | 全部有值 ✓ |
| C（按日均排序）| 6 列齐 | ✓ | ✓ | 2117 > 450 > 272 > 250 > 150 > 120 ✓ |
| D（历史脏数据）| progress 列空 | ✗ | ✓ | 进度自动回落 cc.db ✓ |

### 16.6 推 GitHub 决策
**仍未推 GitHub**——用户重装 install、真机打开一次排行页，USB 取 `rank-debug.log` 贴给我即可验证修复效果；或跑 `diagnose.flag` 看完整诊断。

---

## 九、v2.3.3 · 真机四项修复（边框锯齿 + 年份不显示 + ranking 无数据 + tab 视觉对齐）

### 9.1 根因（本地 PIL 模拟器实测）
- **年份不显示**（dashboard 年份胶囊）：24pt "2026" 在 150px 绘制区里字宽 152px，**溢出 2px → fbink 真机拒画**
- **ranking 6 行没数据**：render_ranking awk 兜底分支用 `asorti(...)`（gawk 扩展），**kindle busybox awk 不支持 → 整段挂 → RANK_LINES 空 → 6 行不画**（python3 不在 PATH 时必踩）
- **边框粗糙**：PIL `rounded_rectangle` 描边无抗锯齿
- **tab 文字/icon 视觉中心偏 2px**：柱状图 icon 视觉中心在 cy+2（base_y=cy+12），文字中心 1585；2px 视觉错位

### 9.2 修复

| # | 修复 | 文件 |
|---|---|---|
| 1 | 年份数字 24→20（"2026" 20pt 字宽 127px，绘制区 150px 富余 23px）；ranking 翻页同步 24→20 保持对称 | `Yunindex阅读统计.sh` |
| 2 | awk 兜底分支去 `asorti`，改用手写选择排序（busybox / mawk / gawk 全兼容） | `Yunindex阅读统计.sh` |
| 3 | 2x 超采样：2544×3392 画布绘制 → LANCZOS 缩小到 1272×1696（消除 rounded_rectangle 描边锯齿） | `generate_bg.py` + `generate_ranking_bg.py` |
| 4 | 柱状图 icon base_y cy+12→cy+10，书本 icon by1 cy+1→cy-1、by2 cy-bh2-1→cy-bh2-3（视觉中心与文字 1585 严格对齐） | `generate_bg.py` + `generate_ranking_bg.py` |

### 9.3 校验
- `bash -n` 三 shell 全过
- 本地 PIL 模拟器验证所有 fb_text_at 绘制区数学正确（25/29 通过；4 fail 均为占位测试字符串，真机短字符串 OK）
- 两张 PNG 视觉确认边框抗锯齿 + tab 图标对齐

### 9.4 仍是 ranking 无数据时的诊断脚本
详见包内 `_diagnose.sh`（在 kindle 上跑后贴 log）

### 9.5 推 GitHub 决策
**仍未推 GitHub**——用户重装 install、跑 launcher、看四项是否修好。
- 两张底图视觉确认：tab 完整画（图标+黑底/白底+文字），不再是「黑块覆盖图标」；排序胶囊缩短+上提对齐 X；年份胶囊单胶囊 + 竖线
- 14 处 right 全部按 `LOGICAL_W - 目标右边界` 修正

#### 8.7 推 GitHub 决策
**仍未推 GitHub**——等用户真机验证（顶栏对齐、tab 切换、排序切换、翻页、6 行数据全显示、tab 图标可见）。