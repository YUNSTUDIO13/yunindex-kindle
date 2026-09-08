-- Yunindex阅读统计 v2.3 触摸热区：与 Yunindex阅读统计.sh 的绘制坐标严格对应。
-- 仅观测 evdev，无 EVIOCGRAB / eatTapMode / 不写设备。
-- v2.3：arg[3]=page（dashboard|ranking），按 page 返回不同热区集
--
-- 修正说明（依据 KPW6 实机诊断）：
--   KPW6 = armv7l 32 位架构（kernel 5.15 但 32 位用户态），
--   struct input_event 恒为 16 字节（32-bit time_t: 8B 时间戳 + 2B type + 2B code + 4B value）。
--   早期实现的「read(24) 自动探测」是 bug：Lua fread 会攒满 24 字节（= 1.5 个事件），
--   误判为 24 字节模式，后续解析全部错位。此版固定 16 字节定长读取。

local device   = arg[1] or "/dev/input/event1"
local log_path = arg[2] or "/mnt/us/reading-time/dashboard-touch.log"
local page     = arg[3] or "dashboard"   -- v2.3: dashboard | ranking
-- v2.3.35: 删 htab 死参数（arg[4] 历史上从未参与任何热区判断，launcher 传值无害）
local origin_x = tonumber(arg[5] or "0") or 0
local origin_y = tonumber(arg[6] or "0") or 0
local view_w   = tonumber(arg[7] or "1272") or 1272
local view_h   = tonumber(arg[8] or "1696") or 1696
local logical_w, logical_h = 1272, 1696

local f = assert(io.open(device, "rb"))
local log = io.open(log_path, "a")
local x, y = nil, nil

local EV_SIZE = 16          -- 32-bit 平台定长
local T_OFF, C_OFF, V_OFF = 9, 11, 13   -- type/code/value 偏移（1-based）

local function u16(s, p)
    local a, b = s:byte(p, p + 1)
    return a + b * 256
end
local function u32(s, p)
    local a, b, c, d = s:byte(p, p + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function note(message)
    if log then log:write(os.date("%Y-%m-%d %H:%M:%S "), message, "\n"); log:flush() end
end
local function finish(action)
    note("action=" .. action)
    io.write(action, "\n")
    f:close()
    if log then log:close() end
    os.exit(0)
end
local function inside(px, py, left, top, right, bottom)
    return px >= left and px <= right and py >= top and py <= bottom
end

local function action_for_logical(px, py)
    -- 关闭（右上角按钮，两页共用）
    -- v2.4.1：热区对齐 × 视觉圆心 (1180,120)。旧热区 y≤127 把圆的下半 21px 漏在区外，
    --   瞄圆心戳时常判空（需连戳）；新区 90×120 正压圆心，左界 1140 避开排序胶囊(x≤1130)。
    if inside(px, py, 1140, 60, 1230, 180) then return "exit" end

    if page == "ranking" then
        -- 排行页热区（v2.3）
        -- 左下 tab：「指标」[80,1545,300,1625] → goto_dashboard
        if inside(px, py, 80, 1545, 300, 1625) then return "goto_dashboard" end
        -- 左下 tab：「排行」[320,1545,540,1625] → goto_ranking（点自己 noop）
        if inside(px, py, 320, 1545, 540, 1625) then return "goto_ranking" end
        -- 右下翻页 ‹ [820,1545,930,1625]
        if inside(px, py, 820, 1545, 930, 1625) then return "rank_prev" end
        -- 右下翻页 › [1080,1545,1190,1625]
        if inside(px, py, 1080, 1545, 1190, 1625) then return "rank_next" end
        -- 排序胶囊 [890,90,1130,150] → rank_toggle_sort（切时长/日均；v7 缩短+上提对齐关闭按钮）
        if inside(px, py, 890, 90, 1130, 150) then return "rank_toggle_sort" end
        return nil
    end

    -- dashboard 页热区（原 v2.2 单页版 + v2.3 左下 tab）
    -- 年份切换胶囊（v2.3: 与 ranking 翻页同款单胶囊 [820,1545,1190,1625]，‹ 左半 / › 右半）
    if inside(px, py, 820, 1545, 930, 1625) then return "period_prev" end
    if inside(px, py, 1080, 1545, 1190, 1625) then return "period_next" end
    -- 左下 tab：「指标」[80,1545,300,1625]（点自己 noop → goto_dashboard）
    if inside(px, py, 80, 1545, 300, 1625) then return "goto_dashboard" end
    -- 左下 tab：「排行」[320,1545,540,1625] → goto_ranking
    if inside(px, py, 320, 1545, 540, 1625) then return "goto_ranking" end
    return nil
end

local function action_for_physical(px, py)
    if px < origin_x or py < origin_y or
       px > origin_x + view_w or py > origin_y + view_h then
        return nil
    end
    local lx = math.floor((px - origin_x) * logical_w / view_w + 0.5)
    local ly = math.floor((py - origin_y) * logical_h / view_h + 0.5)
    local action = action_for_logical(lx, ly)
    if action then
        note(string.format("mapped x=%d y=%d action=%s", lx, ly, action))
    end
    return action
end

note(string.format("touch watcher v2.3 device=%s page=%s viewport=%dx%d+%d+%d evsize=16B (fixed)",
    device, page, view_w, view_h, origin_x, origin_y))

while true do
    local event = f:read(EV_SIZE)
    if not event or #event ~= EV_SIZE then
        note("short read got=" .. tostring(event and #event or "nil"))
        os.exit(2)
    end
    local etype = u16(event, T_OFF)
    local code  = u16(event, C_OFF)
    local value = u32(event, V_OFF)
    if etype == 3 then                    -- EV_ABS
        if code == 53 or code == 0 then x = value end   -- ABS_MT_X / ABS_X
        if code == 54 or code == 1 then y = value end   -- ABS_MT_Y / ABS_Y
    elseif etype == 0 and code == 0 and x and y then    -- EV_SYN / SYN_REPORT
        note(string.format("tap x=%d y=%d", x, y))
        local action = action_for_physical(x, y) or action_for_physical(y, x)
        if action then finish(action) end
        x, y = nil, nil
    end
end
