-- Yunindex阅读统计 v2.0 触摸热区：与 Yunindex阅读统计.sh 的绘制坐标严格对应。
-- 仅观测 evdev，无 EVIOCGRAB / eatTapMode / 不写设备。
--
-- 修正说明（依据 KPW6 实机诊断）：
--   KPW6 = armv7l 32 位架构（kernel 5.15 但 32 位用户态），
--   struct input_event 恒为 16 字节（32-bit time_t: 8B 时间戳 + 2B type + 2B code + 4B value）。
--   早期实现的「read(24) 自动探测」是 bug：Lua fread 会攒满 24 字节（= 1.5 个事件），
--   误判为 24 字节模式，后续解析全部错位。此版固定 16 字节定长读取。

local device   = arg[1] or "/dev/input/event1"
local log_path = arg[2] or "/mnt/us/reading-time/dashboard-touch.log"
local mode     = arg[3] or "core"          -- core | history
local htab     = arg[4] or "month"         -- month | year | total
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
    -- 关闭（右上角按钮）
    if inside(px, py, 1130, 35, 1222, 127) then return "exit" end
    -- 年份切换（底部 < 2026 > 按钮，R34 单页版坐标：与 generate_bg.py 按钮框一致）
    -- 按钮框 ar_w=90 ar_h=65 ar_gap=16 ar_total=302 ar_x1=910 ar_y0=1525
    -- < 按钮 [910,1000]，> 按钮 [1122,1212]，y [1525,1590]
    if inside(px, py, 900, 1515, 1010, 1595) then return "period_prev" end
    if inside(px, py, 1110, 1515, 1220, 1595) then return "period_next" end
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

note(string.format("touch watcher v2.0 device=%s mode=%s htab=%s viewport=%dx%d+%d+%d evsize=16B (fixed)",
    device, mode, htab, view_w, view_h, origin_x, origin_y))

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
