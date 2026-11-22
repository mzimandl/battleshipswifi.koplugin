--[[--
Battleships plugin: the classic game for two players, each on their own
e-reader, over Wi-Fi. One device hosts the game, the other joins it, either by
address or by finding it on the local network (UDP broadcast).

@module koplugin.Battleships
]]

-- Own modules must be required at load time: PluginLoader only adds the
-- plugin folder to package.path while main.lua is being loaded.
local AI = require("battleshipswifi/ai")
local Board = require("battleshipswifi/board")
local L10n = require("battleshipswifi/l10n")
local Match = require("battleshipswifi/match")
local Net = require("battleshipswifi/net")
local Protocol = require("battleshipswifi/protocol")

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Screen = Device.screen
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local gettext = require("gettext")
-- The plugin's strings are not in KOReader's catalog: its own catalog for
-- KOReader's language first (battleshipswifi/l10n/<lang>.lua, required now, see above).
local _ = L10n.wrap(gettext, L10n.catalog(gettext.current_lang, function(name)
    local ok, catalog = pcall(require, "battleshipswifi/l10n/" .. name)
    return ok and catalog or nil
end))
local T = require("ffi/util").template

local Battleships = WidgetContainer:extend{
    name = "battleshipswifi",
    is_doc_only = false,
}

local PING_INTERVAL = 5    -- seconds
local PEER_TIMEOUT = 30    -- seconds without any message → connection lost
local CONNECT_TIMEOUT = 5  -- seconds, blocks the UI
local SEARCH_INTERVAL = 1  -- seconds between DISCOVER broadcasts
local RECONNECT_INTERVAL = 3 -- seconds between attempts to get a lost connection back
local SEARCH_EXPIRE = 5    -- seconds: games not heard of are dropped from the list

local LEVEL_NAMES = {
    easy = _("Easy"),
    normal = _("Normal"),
    hard = _("Hard"),
}
local AI_DELAY = 1.2 -- seconds the e-reader "aims", so that the animations can be seen

local FLEET_NAMES = {
    classic = _("Classic ships"),
    shapes = _("Shaped ships"),
}

--- What a game is played with: "Shaped ships, 12 × 12, salvo, ships may touch".
local function game_kind(fleet, rules)
    local parts = { FLEET_NAMES[fleet] or fleet }
    if rules.size ~= Board.SIZE then parts[#parts + 1] = T(_("%1 × %1"), rules.size) end
    if rules.salvo then parts[#parts + 1] = _("salvo") end
    if rules.touch then parts[#parts + 1] = _("ships may touch") end
    return table.concat(parts, ", ")
end

local function now()
    return time.to_s(time.now())
end

local function notify(text)
    Notification:notify(text)
end

-- The running game and the game search. Module-level, not on the plugin
-- instance: KOReader makes a new instance for every reader/file manager.
-- game: { role, match, conn, host, ip, screen, zmq, message, lost, last_ping, rules, animations,
--         ai (AI.player when playing against the e-reader), standby (preventStandby() called),
--         address (guest: the host's { ip, port }),
--         waiting (the connection is lost, the game can resume), paused (asleep),
--         reconnect (guest while waiting: { pending, next_at, search, found, rules }),
--         candidate (host: a new connection that may be the guest coming back), rebind_at }
local game = {}
-- finder: { search, menu, zmq, last_sent, rules }
local finder = {}

-- The game saved on disk, to go on after KOReader restarts -----------------------
-- battleshipswifi_game.lua, key "game": { role, match (Match:snapshot()), ai = { level,
-- match } (against the e-reader), address (guest), opponent, saved (os.time()) }.

local saved_store
local function store()
    saved_store = saved_store or LuaSettings:open(DataStorage:getSettingsDir() .. "/battleshipswifi_game.lua")
    return saved_store
end

local function saved_game()
    local snap = store():readSetting("game")
    return type(snap) == "table" and type(snap.match) == "table" and snap or nil
end

local function clear_saved_game()
    if saved_game() then
        store():delSetting("game")
        store():flush()
    end
end

--- Saves the running game when it can go on later (against the e-reader, or a
-- network game that can resume); else drops what was saved.
local function save_game()
    local m = game.match
    if not m or game.lost or not (game.ai or m:can_resume()) then
        clear_saved_game()
        return
    end
    store():saveSetting("game", {
        role = game.role,
        match = m:snapshot(),
        ai = game.ai and { level = game.ai.level, match = game.ai.match:snapshot() } or nil,
        address = game.address,
        opponent = m.peer,
        saved = os.time(),
    })
    store():flush()
end

-- Kindle firewall --------------------------------------------------------------

local function host_rules(port)
    return {
        string.format("INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", port),
        string.format("OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", port),
        string.format("INPUT -p udp --dport %d -j ACCEPT", Protocol.DISCOVERY_PORT),
        string.format("OUTPUT -p udp --sport %d -j ACCEPT", Protocol.DISCOVERY_PORT),
    }
end

local function guest_rules(port)
    return {
        string.format("OUTPUT -p tcp --dport %d -j ACCEPT", port),
        string.format("INPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", port),
    }
end

local function search_rules()
    return {
        string.format("INPUT -p udp --dport %d -j ACCEPT", Protocol.SEARCH_PORT),
        string.format("OUTPUT -p udp --sport %d -j ACCEPT", Protocol.SEARCH_PORT),
        string.format("OUTPUT -p udp --dport %d -j ACCEPT", Protocol.DISCOVERY_PORT),
    }
end

-- Opens (op "-A") or closes ("-D") ports in the Kindle firewall (as httpinspector does).
local function kindle_firewall(op, rules)
    if not rules or not Device:isKindle() then return end
    for _i, rule in ipairs(rules) do os.execute("iptables " .. op .. " " .. rule) end
end

-- Stops trying to reconnect (guest) and searching for the host's new address.
local function stop_reconnect()
    local r = game.reconnect
    if not r then return end
    if r.pending then r.pending:close() end
    if r.search then r.search:close() end
    kindle_firewall("-D", r.rules)
    game.reconnect = nil
end

-- Polling: UIManager calls a ZMQ's waitEvent() about every 50 ms; it must
-- return nil (anything else is treated as an input event).
local function poller(fn, name)
    return UIManager:insertZMQ({ waitEvent = function()
        local ok, err = pcall(fn)
        if not ok then logger.warn("Battleships:", name, err) end
        return nil
    end })
end

-- Board widget -----------------------------------------------------------------

local font_sizes = {} -- cell size → label font size

-- Drawing helpers ----------------------------------------------------------------

--- Fills a polygon (list of { x, y }, even-odd rule) row by row.
local function fill_polygon(bb, pts, color)
    local min_y, max_y = math.huge, -math.huge
    for _i, p in ipairs(pts) do
        min_y, max_y = math.min(min_y, p[2]), math.max(max_y, p[2])
    end
    local n = #pts
    for y = math.floor(min_y), math.ceil(max_y) - 1 do
        local yc = y + 0.5
        local xs = {}
        for i = 1, n do
            local a, b = pts[i], pts[i % n + 1]
            if (a[2] <= yc) ~= (b[2] <= yc) then
                xs[#xs + 1] = a[1] + (yc - a[2]) / (b[2] - a[2]) * (b[1] - a[1])
            end
        end
        table.sort(xs)
        for i = 1, #xs - 1, 2 do
            local x0, x1 = math.floor(xs[i] + 0.5), math.floor(xs[i + 1] + 0.5)
            if x1 > x0 then bb:paintRect(x0, y, x1 - x0, 1, color) end
        end
    end
end

--- A straight line `t` pixels thick from (x0, y0) to (x1, y1).
local function thick_line(bb, x0, y0, x1, y1, t, color)
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then return end
    local nx, ny = -dy / len * t / 2, dx / len * t / 2
    fill_polygon(bb, { { x0 + nx, y0 + ny }, { x1 + nx, y1 + ny }, { x1 - nx, y1 - ny }, { x0 - nx, y0 - ny } }, color)
end

--- An explosion: a star with uneven spikes (8 by default) around (cx, cy), radius r.
local function blast(bb, cx, cy, r, color, phase, spikes)
    local pts = {}
    spikes = spikes or 8
    phase = phase or 0
    for i = 0, 2 * spikes - 1 do
        local k
        if i % 2 == 1 then k = 0.45
        elseif i % 4 == 0 then k = 1
        else k = 0.72 end
        local a = phase + math.pi * i / spikes
        pts[#pts + 1] = { cx + r * k * math.sin(a), cy - r * k * math.cos(a) }
    end
    fill_polygon(bb, pts, color)
end

-- Circles get whole-pixel centres: Blitbuffer's setPixel computes the address as
-- data + stride * y + x, and with 32-bit LuaJIT (Kindle) stride is a plain
-- number, so a fractional y shifts the pixel by part of a row (scattered dots).
local function round(v) return math.floor(v + 0.5) end

local function disc(bb, cx, cy, r, color)
    r = math.max(1, math.floor(r))
    bb:paintCircle(round(cx), round(cy), r, color)
end

local function ring(bb, cx, cy, r, w, color)
    r = math.max(1, math.floor(r))
    bb:paintCircle(round(cx), round(cy), r, color, math.max(1, math.min(r, math.floor(w))))
end

--- A flame (hit ship) standing on (cx, cy): black, with a white core. h = height.
local FLAME = {}
for i = 0, 8 do -- round bottom, then the left tongue, the main tip, the right side
    local t = math.pi * i / 8
    FLAME[#FLAME + 1] = { 0.28 * math.cos(t), 0.12 + 0.28 * math.sin(t) }
end
for _i, p in ipairs({ { -0.3, -0.04 }, { -0.25, -0.22 }, { -0.17, -0.4 }, { -0.1, -0.22 }, { -0.03, -0.3 },
    { 0.06, -0.58 }, { 0.2, -0.33 }, { 0.29, -0.1 } }) do
    FLAME[#FLAME + 1] = p
end
local function flame(bb, cx, cy, h)
    for pass = 1, 2 do
        local k, dy = pass == 1 and h or h * 0.45, pass == 1 and 0 or h * 0.12
        local pts = {}
        for _i, p in ipairs(FLAME) do pts[#pts + 1] = { cx + p[1] * k, cy + dy + p[2] * k } end
        fill_polygon(bb, pts, pass == 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)
    end
end

--- A puff of smoke: outlined overlapping circles around (cx, cy), size r.
local function puff(bb, cx, cy, r, w)
    local blobs = { { -0.5, 0.2 }, { 0.5, 0.2 }, { 0, -0.35 } }
    for pass = 1, 2 do
        for _i, o in ipairs(blobs) do
            disc(bb, cx + o[1] * r, cy + o[2] * r, r * 0.62 - (pass == 2 and w or 0),
                pass == 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)
        end
    end
end

-- Animations: frame 1 is shown with the result, the next ones every FRAME_TIME.
-- A sunk ship blows up in up to SINK_STEPS steps along its squares, then sinks.
local FRAME_TIME = 0.15 -- seconds
-- The refresh after the last frame: "partial" (the full waveform, not "ui"'s fast
-- one) clears what the fast frames (black flashes) leave behind.
local CLEANUP_REFRESH = "partial"
local SINK_STEPS = 4

-- Off-screen buffers a board with an animation is painted into first, so that
-- the effects stay on the board and the screen only ever gets finished pixels.
-- One per size (both boards), reused; freed when the game ends.
local canvases = {}
local function canvas_for(w, h, like)
    local key = w .. "x" .. h .. "/" .. tostring(like:getType())
    local canvas = canvases[key]
    if not canvas then
        canvas = Blitbuffer.new(w, h, like:getType())
        canvases[key] = canvas
    end
    return canvas
end
local function free_canvases()
    for key, canvas in pairs(canvases) do
        canvas:free()
        canvases[key] = nil
    end
end
local function frame_count(kind, cells)
    if kind == "shell" then return 1 end -- our shell, until the result comes
    if kind == "miss" then return 6 end
    if kind == "hit" then return 5 end
    return math.min(#cells, SINK_STEPS) + 3
end

--- A 10 × 10 board with column letters and row numbers.
-- mode "own": board = Board (our ships and the opponent's shots), selected = ship index
-- (squares it can't be moved to are shaded);
-- mode "target": target = Board.target(). last = { x, y } is outlined.
-- anim = { kind = "miss" | "hit" | "sunk", cells, set = { [y * SIZE + x] = true },
-- ship (sunk), frame } is drawn over its squares and their neighbours (see GameScreen:animate()).
-- on_tap(x, y) makes it tappable; on_drag(phase, sx, sy, x, y) lets ships be
-- dragged ("move" while the finger moves, "drop" when it lifts, "swipe" for a
-- quick one; sx, sy = the square it started on, x, y = where it is; it returns
-- whether it took the gesture). drag = { i, ship (where it would land), fits }
-- is drawn over the board.
local BoardWidget = InputContainer:extend{
    size = nil,
    mode = "own",
    board = nil,
    target = nil,
    selected = nil,
    last = nil,
    anim = nil,
    drag = nil,
    cursor = nil,
    on_tap = nil,
    on_drag = nil,
}

function BoardWidget:init()
    self.n = (self.board or self.target).size -- squares a side (the rules' board)
    local n = self.n + 1
    self.cell = math.floor(self.size / n)
    self.line = math.max(1, math.floor(self.cell / 25))
    if self.cell * n + 2 * self.line > self.size then -- keep within size, outer border included
        self.cell = self.cell - 1
        self.line = math.max(1, math.floor(self.cell / 25))
    end
    -- the outer grid line (2 × line) lies past the last square: it belongs to
    -- the widget, or a canvas of the widget's size (animations) cuts it off
    local side = self.cell * n + 2 * self.line
    self.dimen = Geom:new{ x = 0, y = 0, w = side, h = side }
    self.inset = math.max(self.line + 1, math.floor(self.cell * 0.14))
    self.blocked = self.mode == "own" and self.selected and self.board:blocked(self.selected) or nil
    local fs = font_sizes[self.cell]
    if not fs then
        fs = TextWidget:getFontSizeToFitHeight("cfont", math.floor(self.cell * 0.75), 0)
        font_sizes[self.cell] = fs
    end
    local face = Font:getFace("cfont", fs)
    self.cols, self.rows = {}, {}
    for i = 0, self.n - 1 do
        self.cols[i] = TextWidget:new{ text = string.char(65 + i), face = face, padding = 0 }
        self.rows[i] = TextWidget:new{ text = tostring(i + 1), face = face, padding = 0 }
    end
    self.ges_events = {}
    if self.on_tap then
        self.ges_events.TapBoard = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } }
    end
    if self.on_drag then
        local function board() return self.dimen end
        -- the finger may lift anywhere (off the board: the drag is cancelled)
        local function anywhere() return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } end
        self.ges_events.PanBoard = { GestureRange:new{ ges = "pan", range = board } }
        self.ges_events.PanReleaseBoard = { GestureRange:new{ ges = "pan_release", range = anywhere } }
        self.ges_events.SwipeBoard = { GestureRange:new{ ges = "swipe", range = board } }
    end
end

--- The square under a screen position (may be off the board).
function BoardWidget:cellAt(pos)
    return math.floor((pos.x - self.dimen.x) / self.cell) - 1, math.floor((pos.y - self.dimen.y) / self.cell) - 1
end

function BoardWidget:onPanBoard(_args, ges)
    local sx, sy = self:cellAt(ges.start_pos or ges.pos)
    local x, y = self:cellAt(ges.pos)
    return self.on_drag("move", sx, sy, x, y)
end

function BoardWidget:onPanReleaseBoard(_args, ges)
    local x, y = self:cellAt(ges.pos)
    return self.on_drag("drop", nil, nil, x, y)
end

function BoardWidget:onSwipeBoard(_args, ges)
    local sx, sy = self:cellAt(ges.pos)
    local x, y = self:cellAt(ges.end_pos or ges.pos)
    return self.on_drag("swipe", sx, sy, x, y)
end

function BoardWidget:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function BoardWidget:onTapBoard(_args, ges)
    local x = math.floor((ges.pos.x - self.dimen.x) / self.cell) - 1
    local y = math.floor((ges.pos.y - self.dimen.y) / self.cell) - 1
    if Board.inside(x, y, self.n) then self.on_tap(x, y) end
    return true
end

-- Squares' bounding box grown by `grow` squares, kept within lo..SIZE - 1.
local function bounds(cells, grow, lo, size)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _i, cell in ipairs(cells) do
        x0, y0 = math.min(x0, cell[1]), math.min(y0, cell[2])
        x1, y1 = math.max(x1, cell[1]), math.max(y1, cell[2])
    end
    local hi = size - 1
    return math.max(lo, x0 - grow), math.max(lo, y0 - grow), math.min(hi, x1 + grow), math.min(hi, y1 + grow)
end

--- Screen rectangle an animation of the given squares (list of { x, y }) paints
-- on: the squares, their neighbours and, at the edge, the labels.
function BoardWidget:region(cells)
    local c = self.cell
    local x0, y0, x1, y1 = bounds(cells, 1, -1, self.n)
    local x, y = c * (x0 + 1), c * (y0 + 1) -- within the widget
    return Geom:new{
        x = self.dimen.x + x, y = self.dimen.y + y,
        w = math.min(c * (x1 - x0 + 1) + 2 * self.line, self.dimen.w - x),
        h = math.min(c * (y1 - y0 + 1) + 2 * self.line, self.dimen.h - y),
    }
end

--- Screen rectangle of one square (with its outline, see last).
function BoardWidget:cellRegion(cell)
    local c = self.cell
    return Geom:new{
        x = self.dimen.x + c * (cell[1] + 1), y = self.dimen.y + c * (cell[2] + 1),
        w = c + 2 * self.line, h = c + 2 * self.line,
    }
end

local function paint_centered(bb, widget, x, y, w, h)
    local size = widget:getSize()
    widget:paintTo(bb, x + math.floor((w - size.w) / 2), y + math.floor((h - size.h) / 2))
end

--- One square of a ship's hull: a rounded body joined to the ship's
-- neighbouring squares, so the whole ship reads as one silhouette.
function BoardWidget:paintHull(bb, px, py, x, y, ship, color, deck)
    local c, m, line = self.cell, self.inset, self.line
    local s = c - 2 * m
    local half = math.floor(c / 2)
    bb:paintRoundedRect(px + m, py + m, s, s, color, math.floor(s / 2))
    local right, down = Board.covers(ship, x + 1, y), Board.covers(ship, x, y + 1)
    if right then bb:paintRect(px + half, py + m, c - half + m + line, s, color) end
    if Board.covers(ship, x - 1, y) then bb:paintRect(px, py + m, half + 1, s, color) end
    if down then bb:paintRect(px + m, py + half, s, c - half + m + line, color) end
    if Board.covers(ship, x, y - 1) then bb:paintRect(px + m, py, s, half + 1, color) end
    if right and down and Board.covers(ship, x + 1, y + 1) then
        bb:paintRect(px + c - m, py + c - m, 2 * m + line, 2 * m + line, color) -- inner corner of a block
    end
    if deck then -- a gun turret
        ring(bb, px + half, py + half, c * 0.15, math.max(1, c / 22), deck)
    end
end

--- The running animation, over the board (grid origin ox, oy). Frames are
-- black and white only: fast refreshes don't show grays well.
function BoardWidget:paintAnim(bb, ox, oy)
    local anim, c, line = self.anim, self.cell, self.line
    local f = anim.frame
    local black, white = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local half = math.floor(c / 2)
    local w = math.max(2, math.floor(c / 20))
    local function center(cell) return ox + cell[1] * c + half, oy + cell[2] * c + half end
    local function shell(cx, cy) -- coming in from above
        disc(bb, cx, cy - c * 0.15, c / 12, black)
        for i = 1, 4 do
            bb:paintRect(cx - math.floor(w / 2), math.floor(cy - c * 0.15 - c * 0.05 - i * c * 0.17), w, math.floor(c * 0.1), black)
        end
    end
    local function flash() -- black over the squares and their neighbours
        local x0, y0, x1, y1 = bounds(anim.cells, 1, 0, self.n)
        bb:paintRect(ox + x0 * c, oy + y0 * c, (x1 - x0 + 1) * c + line, (y1 - y0 + 1) * c + line, black)
    end

    if anim.kind == "shell" then
        shell(center(anim.cells[1]))
        return
    end

    if anim.kind == "miss" then
        local cx, cy = center(anim.cells[1])
        if f == 1 then
            shell(cx, cy)
        elseif f == 2 then -- splash crown
            for i = -2, 2 do
                local x = cx + i * c * 0.12
                fill_polygon(bb, { { x - c * 0.07, cy }, { x + c * 0.07, cy },
                    { x + i * c * 0.1, cy - c * (0.32 - math.abs(i) * 0.07) } }, black)
            end
            bb:paintRect(math.floor(cx - c * 0.3), cy, math.floor(c * 0.6), w, black)
        elseif f == 3 then -- water column
            fill_polygon(bb, { { cx - c * 0.12, cy }, { cx + c * 0.12, cy }, { cx + c * 0.18, cy - c * 0.7 },
                { cx, cy - c * 0.85 }, { cx - c * 0.18, cy - c * 0.7 } }, black)
            ring(bb, cx, cy, c * 0.3, w, black)
            for _i, d in ipairs({ { -0.35, -0.75 }, { 0.32, -0.8 }, { -0.25, -0.95 }, { 0.2, -1.0 } }) do
                disc(bb, cx + d[1] * c, cy + d[2] * c, c / 20, black)
            end
        elseif f == 4 then -- the column falls back
            ring(bb, cx, cy, c * 0.45, w * 1.5, black)
            disc(bb, cx, cy, c * 0.14, black)
            for _i, d in ipairs({ { -0.5, -0.3 }, { 0.5, -0.25 }, { -0.2, -0.45 }, { 0.25, -0.5 } }) do
                disc(bb, cx + d[1] * c, cy + d[2] * c, c / 20, black)
            end
        elseif f == 5 then -- ripples
            ring(bb, cx, cy, c * 0.75, w, black)
            ring(bb, cx, cy, c * 0.35, w * 0.7, black)
        else -- fading ripples
            for _i, r in ipairs({ { 1.0, 24 }, { 0.6, 14 } }) do
                for i = 0, r[2] - 1 do
                    local a = 2 * math.pi * i / r[2]
                    disc(bb, cx + r[1] * c * math.cos(a), cy + r[1] * c * math.sin(a), c / 30, black)
                end
            end
        end
        return
    end

    if anim.kind == "hit" then
        local cx, cy = center(anim.cells[1])
        if f == 1 then
            shell(cx, cy)
        elseif f == 2 then
            flash()
            blast(bb, cx, cy, c * 1.1, white, 0, 12)
        elseif f == 3 then -- fireball over the neighbours
            blast(bb, cx, cy, c * 0.95, black, math.pi / 8, 10)
            blast(bb, cx, cy, c * 0.5, white, 0, 10)
            blast(bb, cx, cy, c * 0.22, black)
        elseif f == 4 then -- debris flying out
            blast(bb, cx, cy, c * 0.45, black, math.pi / 8)
            for i = 0, 7 do
                local a = i * math.pi / 4 + 0.3
                local r = c * (0.7 + (i % 3) * 0.15)
                local x, y = cx + r * math.cos(a), cy + r * math.sin(a)
                fill_polygon(bb, { { x - c * 0.07, y - c * 0.05 }, { x + c * 0.08, y - c * 0.02 }, { x + c * 0.02, y + c * 0.08 } }, black)
            end
        else -- smoke rising over the fire
            flame(bb, cx, cy, c * 0.75)
            puff(bb, cx - c * 0.1, cy - c * 0.6, c * 0.28, w)
            puff(bb, cx + c * 0.17, cy - c * 0.95, c * 0.2, w)
        end
        return
    end

    -- sunk: blasts run along the ship, it blows up, sinks below the waves
    local n = #anim.cells
    local steps = math.min(n, SINK_STEPS)
    if f <= steps then
        for i, cell in ipairs(anim.cells) do
            local step = math.ceil(i * steps / n)
            local cx, cy = center(cell)
            if step == f then
                blast(bb, cx, cy, c * 0.85, black, math.pi / 8, 10)
                blast(bb, cx, cy, c * 0.35, white)
            elseif step < f then
                flame(bb, cx, cy, c * 0.65)
            end
        end
    elseif f == steps + 1 then
        flash()
        for i, cell in ipairs(anim.cells) do
            local cx, cy = center(cell)
            blast(bb, cx, cy, c * 0.75, white, i * 0.4, 10)
        end
    else
        local sink = f == steps + 2 and 0.35 or 0.75
        local m = self.inset
        -- the ship broke up: each row goes down as one piece (joined only along the row)
        local s = c - 2 * m
        for _i, cell in ipairs(anim.cells) do
            local px, py = ox + cell[1] * c, oy + cell[2] * c
            bb:paintRoundedRect(px + m, py + m, s, s, black, math.floor(s / 2))
            if Board.covers(anim.ship, cell[1] + 1, cell[2]) then
                bb:paintRect(px + half, py + m, c - half + m + line, s, black)
            end
            if Board.covers(anim.ship, cell[1] - 1, cell[2]) then bb:paintRect(px, py + m, half + 1, s, black) end
        end
        local amp = math.max(1, math.floor(c / 30))
        for _i, cell in ipairs(anim.cells) do
            local px, py = ox + cell[1] * c, oy + cell[2] * c
            local wy = py + m + math.floor((c - 2 * m) * (1 - sink))
            local lx = cell[1] == 0 and 2 * line or line
            bb:paintRect(px + lx, wy, c - lx, py + c - wy, white) -- under water
            bb:paintRect(px, wy, lx, py + c - wy, black) -- the grid line the hull covered
            for xx = px + lx, px + c - 1 do -- waves along the water line
                local yy = wy + math.floor(amp * math.sin((xx - ox) / c * 6 * math.pi) + 0.5)
                bb:paintRect(xx, yy - 1, 1, math.max(2, line + 1), black)
            end
        end
        local first = anim.cells[1]
        local cx, cy = center(first)
        if f == steps + 2 then
            puff(bb, cx + c * 0.3, cy - c * 0.7, c * 0.3, w)
        else -- bubbles
            for i, cell in ipairs(anim.cells) do
                local bx, by = center(cell)
                ring(bb, bx + (i % 3 - 1) * c * 0.2, by - c * (0.25 + (i % 2) * 0.3), c * (0.06 + (i % 3) * 0.02), w * 0.6, black)
            end
        end
    end
end

function BoardWidget:paintCell(bb, px, py, x, y)
    local c, line = self.cell, self.line
    local half = math.floor(c / 2)
    local cx, cy = px + half, py + half
    local function fill(color) -- the square inside the grid lines (the outer ones are thicker)
        local lx, ly = x == 0 and 2 * line or line, y == 0 and 2 * line or line
        bb:paintRect(px + lx, py + ly, c - lx, c - ly, color)
    end
    local function splash()
        disc(bb, cx, cy, c / 10, Blitbuffer.COLOR_BLACK)
        ring(bb, cx, cy, c * 0.27, math.max(1, c / 30), Blitbuffer.COLOR_GRAY_9)
    end
    local function fire() flame(bb, cx, cy, c * 0.75) end
    local function wreck() blast(bb, cx, cy, c * 0.2, Blitbuffer.COLOR_WHITE) end
    local animated = self.anim and self.anim.set[y * Board.KEY + x]
    -- a sunk ship's hull is gone once it blows up (paintAnim draws what is left)
    local gone = animated and self.anim.kind == "sunk"
        and self.anim.frame > math.min(#self.anim.cells, SINK_STEPS)

    if self.mode == "own" then
        if self.blocked and self.blocked[y][x] then fill(Blitbuffer.COLOR_GRAY_D) end
        local i = self.board:ship_at(x, y)
        local shot = self.board.shots[y][x]
        if i then
            local ship = self.board.ships[i]
            if animated then
                if not gone then self:paintHull(bb, px, py, x, y, ship, Blitbuffer.COLOR_GRAY) end
            elseif self.board:sunk(i) then
                self:paintHull(bb, px, py, x, y, ship, Blitbuffer.COLOR_BLACK)
                wreck()
            elseif self.drag and self.drag.i == i then
                self:paintHull(bb, px, py, x, y, ship, Blitbuffer.COLOR_GRAY_D) -- where it was
            else
                local selected = i == self.selected
                self:paintHull(bb, px, py, x, y, ship,
                    selected and Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_GRAY,
                    shot ~= "hit" and (selected and Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_GRAY_5) or nil)
                if shot == "hit" then fire() end
            end
        elseif shot == "miss" and not animated then
            splash()
        end
    else
        local mark = self.target.marks[y][x]
        local i = self.target:ship_at(x, y)
        if animated then -- as before the shot: the ship goes down during the animation
            if self.anim.kind == "sunk" and self.anim.ship and not gone then
                self:paintHull(bb, px, py, x, y, self.anim.ship, Blitbuffer.COLOR_GRAY)
            elseif self.anim.kind == "hit" then
                fill(Blitbuffer.COLOR_GRAY_D)
            end
        elseif mark == "sunk" and i then
            self:paintHull(bb, px, py, x, y, self.target.ships[i], Blitbuffer.COLOR_BLACK)
            wreck()
        else
            if i then -- revealed after the game
                self:paintHull(bb, px, py, x, y, self.target.ships[i], Blitbuffer.COLOR_GRAY,
                    mark ~= "hit" and Blitbuffer.COLOR_GRAY_5 or nil)
            elseif mark == "hit" then
                fill(Blitbuffer.COLOR_GRAY_D)
            end
            if mark == "hit" then fire()
            elseif mark == "miss" then splash()
            elseif mark == "near" then disc(bb, cx, cy, c / 14, Blitbuffer.COLOR_GRAY_9) end
        end
    end
end

function BoardWidget:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if not self.anim then return self:paintBoard(bb, x, y) end
    -- an animation: paint into a canvas first, so that its effects stay on the board
    local canvas = canvas_for(self.dimen.w, self.dimen.h, bb)
    self:paintBoard(canvas, 0, 0)
    bb:blitFrom(canvas, x, y, 0, 0, self.dimen.w, self.dimen.h)
end

--- Puts the current animation frame (or, with anim = nil, the board as it is)
-- on the screen: only the animation's region is copied there from the canvas,
-- the screen's other pixels stay untouched. Returns the region.
function BoardWidget:paintRegion(cells)
    local region = self:region(cells)
    local bb = Screen.bb
    local canvas = canvas_for(self.dimen.w, self.dimen.h, bb)
    self:paintBoard(canvas, 0, 0)
    bb:blitFrom(canvas, region.x, region.y, region.x - self.dimen.x, region.y - self.dimen.y, region.w, region.h)
    return region
end

function BoardWidget:paintBoard(bb, x, y)
    local c, n = self.cell, self.n
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    for i = 0, n - 1 do
        paint_centered(bb, self.cols[i], x + c * (i + 1), y, c, c)
        paint_centered(bb, self.rows[i], x, y + c * (i + 1), c, c)
    end
    local ox, oy = x + c, y + c
    -- grid first: ships are painted across the lines between their squares
    for i = 0, n do
        local w = (i == 0 or i == n) and self.line * 2 or self.line
        bb:paintRect(ox + i * c, oy, w, n * c + w, Blitbuffer.COLOR_BLACK)
        bb:paintRect(ox, oy + i * c, n * c + w, w, Blitbuffer.COLOR_BLACK)
    end
    for cy = 0, n - 1 do
        for cx = 0, n - 1 do self:paintCell(bb, ox + cx * c, oy + cy * c, cx, cy) end
    end
    if self.last then
        bb:paintBorder(ox + self.last[1] * c, oy + self.last[2] * c, c + self.line, c + self.line,
            math.max(2, math.floor(c / 8)), Blitbuffer.COLOR_BLACK)
    end
    if self.anim then self:paintAnim(bb, ox, oy) end
    if self.drag and self.drag.ship then self:paintDrag(bb, ox, oy) end
    if self.cursor then -- the key cursor: brackets in the square's corners (inside the grid lines)
        local inset = 2 * self.line + 1
        local px, py = ox + self.cursor[1] * c + inset, oy + self.cursor[2] * c + inset
        local inner = c - 2 * inset + self.line
        local t, len = math.max(3, math.floor(c / 8)), math.floor(c / 3)
        local far = inner - t
        for _i, corner in ipairs({ { 0, 0, 1, 1 }, { far, 0, -1, 1 }, { 0, far, 1, -1 }, { far, far, -1, -1 } }) do
            local x0, y0 = px + corner[1], py + corner[2]
            bb:paintRect(corner[3] > 0 and x0 or x0 + t - len, y0, len, t, Blitbuffer.COLOR_BLACK)
            bb:paintRect(x0, corner[4] > 0 and y0 or y0 + t - len, t, len, Blitbuffer.COLOR_BLACK)
        end
    end
end

--- The dragged ship where it would land: dark when it fits there, else hollow.
function BoardWidget:paintDrag(bb, ox, oy)
    local c, m = self.cell, self.inset
    local ship = self.drag.ship
    for _i, cell in ipairs(Board.cells(ship)) do
        local px, py = ox + cell[1] * c, oy + cell[2] * c
        if self.drag.fits then
            self:paintHull(bb, px, py, cell[1], cell[2], ship, Blitbuffer.COLOR_GRAY_4, Blitbuffer.COLOR_GRAY_E)
        else
            bb:paintBorder(px + m, py + m, c - 2 * m, c - 2 * m, math.max(2, math.floor(c / 16)), Blitbuffer.COLOR_BLACK)
        end
    end
end

function BoardWidget:onCloseWidget()
    for i = 0, self.n - 1 do
        self.cols[i]:free()
        self.rows[i]:free()
    end
end

-- Fleet overview ---------------------------------------------------------------

--- The opponent's fleet in small: ships still afloat dark, sunk ones light and
-- crossed out. cell = size of a square; fleet and target = Board.target().
local FleetWidget = WidgetContainer:extend{
    fleet = nil,
    target = nil,
    square = nil,
}

--- Squares wide and high a fleet takes in the overview (ships as defined, a square apart).
local function fleet_extent(fleet)
    local w, h = -1, 0
    for _i, shape in ipairs(Board.FLEETS[fleet]) do
        local r = Board.rotations(shape)[1]
        w, h = w + r.w + 1, math.max(h, r.h)
    end
    return w, h
end

--- Which of the fleet's ships are sunk: list of booleans, in fleet order.
local function sunk_ships(fleet, target)
    local count = {}
    for _i, ship in ipairs(target.ships) do
        if not ship.revealed then count[ship.shape] = (count[ship.shape] or 0) + 1 end
    end
    local sunk = {}
    for i, shape in ipairs(Board.FLEETS[fleet]) do
        sunk[i] = (count[shape] or 0) > 0
        if sunk[i] then count[shape] = count[shape] - 1 end
    end
    return sunk
end

function FleetWidget:init()
    local w, h = fleet_extent(self.fleet)
    self.dimen = Geom:new{ x = 0, y = 0, w = w * self.square, h = h * self.square }
    self.sunk = sunk_ships(self.fleet, self.target)
    self.hull = { cell = self.square, line = 1, inset = math.max(2, math.floor(self.square * 0.14)) }
end

function FleetWidget:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function FleetWidget:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local c = self.square
    local _w, rows = fleet_extent(self.fleet)
    local ox = x
    for i, shape in ipairs(Board.FLEETS[self.fleet]) do
        local r = Board.rotations(shape)[1]
        local ship = { shape = shape, x = 0, y = 0, rot = 0 }
        local oy = y + math.floor((rows - r.h) * c / 2)
        local sunk = self.sunk[i]
        for _j, cell in ipairs(r.cells) do
            BoardWidget.paintHull(self.hull, bb, ox + cell[1] * c, oy + cell[2] * c, cell[1], cell[2], ship,
                sunk and Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_GRAY_5)
        end
        if sunk then -- crossed out
            -- over the ship's width and the whole strip's height (flat ships too)
            local t = math.max(2, math.floor(c / 5))
            local x0, y0, x1, y1 = ox, y, ox + r.w * c, y + rows * c
            thick_line(bb, x0, y0, x1, y1, t, Blitbuffer.COLOR_BLACK)
            thick_line(bb, x0, y1, x1, y0, t, Blitbuffer.COLOR_BLACK)
        end
        ox = ox + (r.w + 1) * c
    end
end

--- How many of the fleet's ships are sunk.
function FleetWidget:sunkCount()
    local n = 0
    for _i, sunk in ipairs(self.sunk) do if sunk then n = n + 1 end end
    return n
end

-- Game screen ------------------------------------------------------------------

-- Share of the room for the boards that the opponent's (the one fired at) gets.
local TARGET_SHARE = 0.66           -- portrait: of the height
local TARGET_SHARE_LANDSCAPE = 0.62 -- landscape: of the width

local status_heights = {} -- "width/lines" → height of that many status lines
local function status_min_height(width, lines)
    local k = width .. "/" .. lines
    if not status_heights[k] then
        local text = {}
        for i = 1, lines do text[i] = "M" end
        local probe = TextBoxWidget:new{ text = table.concat(text, "\n"), face = Font:getFace("cfont", 18), width = width }
        status_heights[k] = probe:getSize().h
        probe:free()
    end
    return status_heights[k]
end

local GameScreen = InputContainer:extend{
    covers_fullscreen = true,
    selected = nil, -- ship being moved while placing
    anim = nil, -- running animation: { board = "own" | "target", kind, cells, set, ship, frame, frames }
}

--- Plays an animation ("miss", "hit" or "sunk" with its ship) on squares of the
-- "own" or "target" board. Frame 1 is painted with the next update(), the rest
-- every FRAME_TIME with a fast refresh of just those squares and their
-- neighbours; a normal refresh cleans up at the end.
function GameScreen:animate(board, kind, cells, ship, first)
    -- our shell goes on as the result's animation: nothing to clean up then
    local old = self.anim
    self:stopAnimation(not (old and old.kind == "shell" and old.board == board))
    local set = {}
    for _i, c in ipairs(cells) do set[c[2] * Board.KEY + c[1]] = true end
    self.anim = { board = board, kind = kind, cells = cells, set = set, ship = ship, frame = first or 1,
        frames = frame_count(kind, cells) }
    if self.anim.frame < self.anim.frames then
        self.anim_step = function() self:animationStep() end
        UIManager:scheduleIn(FRAME_TIME, self.anim_step)
    end
end

--- Stops the running animation. clean: it is being replaced (the next shot came
-- before it ended): its squares get the clean-up refresh it would have had at
-- the end, else what its fast frames left stays on the screen.
function GameScreen:stopAnimation(clean)
    if self.anim_step then UIManager:unschedule(self.anim_step) end
    local anim = self.anim
    self.anim, self.anim_step = nil, nil
    local widget = anim and self.board_widgets and self.board_widgets[anim.board]
    if not widget then return end
    widget.anim = nil
    if not clean then return end -- (even frame 1 may have come with a fast refresh)
    if UIManager:getTopmostVisibleWidget() == self then
        UIManager:waitForVSync()
        UIManager:setDirty(nil, CLEANUP_REFRESH, widget:paintRegion(anim.cells))
    else
        UIManager:setDirty(self, CLEANUP_REFRESH, widget:region(anim.cells))
    end
end

function GameScreen:animationStep()
    local anim = self.anim
    if not anim then return end
    anim.frame = anim.frame + 1
    local done = anim.frame > anim.frames
    local widget = self.board_widgets and self.board_widgets[anim.board]
    if done then
        self.anim, self.anim_step = nil, nil
        if widget then widget.anim = nil end
    end
    if not widget then return end
    if UIManager:getTopmostVisibleWidget() ~= self then
        -- something is shown over the game: no frames over it, just the end state
        self:stopAnimation()
        widget.anim = nil
        UIManager:setDirty(self, CLEANUP_REFRESH, widget:region(anim.cells))
        return
    end
    -- Only the board's region changes, straight on the screen: repainting the
    -- whole game screen makes it white for a moment before the content is
    -- painted. And not while the e-ink controller may still be reading the
    -- screen for the previous refresh: that tears the picture.
    UIManager:waitForVSync()
    UIManager:setDirty(nil, done and CLEANUP_REFRESH or "fast", widget:paintRegion(anim.cells))
    if not done then UIManager:scheduleIn(FRAME_TIME, self.anim_step) end
end

--- Animates a shot's result (event "result" on the target board, "incoming" on
-- ours); after our shell (see onTargetTap) it goes on from frame 2. Returns
-- the squares the shot changed (the shot's, or the sunk ship's), also with
-- animations off.
function GameScreen:animateShot(board, ev)
    local m = game.match
    local kind = ev.result == "miss" and "miss" or ev.result == "hit" and "hit" or "sunk"
    local cells, ship = { { ev.x, ev.y } }, nil
    if kind == "sunk" then
        local where = board == "target" and m.target or m.board
        local i = where:ship_at(ev.x, ev.y)
        if i then
            ship = where.ships[i]
            cells = Board.cells(ship)
        else
            kind = "hit"
        end
    end
    local shelled = self.anim and self.anim.kind == "shell" and self.anim.board == board
    if game.animations then
        self:animate(board, kind, cells, ship, shelled and kind ~= "sunk" and 2 or 1)
    elseif shelled then
        self:stopAnimation()
    end
    return cells
end

function GameScreen:onCloseWidget()
    self:stopAnimation()
end

--- The whole screen is painted into a canvas, then copied to the screen in one
-- go: painted straight there, it would go white for a moment (the frame's
-- background) while the e-ink controller may still be reading it.
function GameScreen:paintTo(bb, x, y)
    local canvas = canvas_for(self.dimen.w, self.dimen.h, bb)
    InputContainer.paintTo(self, canvas, 0, 0)
    bb:blitFrom(canvas, x, y, 0, 0, self.dimen.w, self.dimen.h)
end

function GameScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        local group = Device.input.group
        self.key_events.Close = { { group.Back } }
        self.key_events.KeyMenu = { { "Menu" } }
        if Device:hasDPad() then
            -- arrows move the cursor, Press acts, page keys step through the squares
            self.key_events.KeyUp = { { "Up" }, event = "KeyMove", args = { 0, -1 } }
            self.key_events.KeyDown = { { "Down" }, event = "KeyMove", args = { 0, 1 } }
            self.key_events.KeyLeft = { { "Left" }, event = "KeyMove", args = { -1, 0 } }
            self.key_events.KeyRight = { { "Right" }, event = "KeyMove", args = { 1, 0 } }
            self.key_events.KeyPress = { { "Press" }, event = "KeyAct" }
            self.key_events.KeyNext = { { group.PgFwd }, event = "KeyStep", args = 1 }
            self.key_events.KeyPrev = { { group.PgBack }, event = "KeyStep", args = -1 }
        else
            -- page keys only (one hand): back steps to the next square, forward acts
            self.key_events.KeyNext = { { group.PgBack }, event = "KeyStep", args = 1 }
            self.key_events.KeyPress = { { group.PgFwd }, event = "KeyAct" }
        end
    end
    self:build()
end

-- Key control -------------------------------------------------------------------
-- A cursor on the board that taps would act on (ours while placing, the
-- opponent's in the battle), shown once a key is used.

function GameScreen:cursorBoard()
    local m = game.match
    if game.lost or game.waiting then return nil end
    if m.phase == "placing" and not m.ready then return "own" end
    if m.phase == "battle" then return "target" end
end

-- Moves the cursor to (x, y) and shows it (a fast refresh of the two squares).
function GameScreen:setCursor(x, y)
    local board = self:cursorBoard()
    local widget = board and self.board_widgets and self.board_widgets[board]
    if not widget then return end
    local old = self.cursor
    self.cursor = { x, y }
    widget.cursor = self.cursor
    UIManager:waitForVSync()
    UIManager:setDirty(nil, "fast", widget:paintRegion(old and { old, { x, y } } or { { x, y } }))
end

-- The cursor's square, or a first one: the last shot, else the top left.
function GameScreen:cursorStart()
    local size = game.match.rules.size
    if self.cursor and (self.cursor[1] >= size or self.cursor[2] >= size) then self.cursor = nil end
    if self.cursor then return self.cursor[1], self.cursor[2] end
    local last = game.match.last_fired
    if self:cursorBoard() == "target" and last then return last[1], last[2] end
    return 0, 0
end

function GameScreen:onKeyMove(d)
    local board = self:cursorBoard()
    if not board then return true end
    local size = game.match.rules.size
    local x, y = self:cursorStart()
    if self.cursor then
        x, y = (x + d[1]) % size, (y + d[2]) % size
    end
    self:setCursor(x, y)
    return true
end

-- Steps along the squares (row by row); in the battle, to those not fired at yet.
function GameScreen:onKeyStep(step)
    local board = self:cursorBoard()
    if not board then return true end
    local m = game.match
    local size = m.rules.size
    local x, y = self:cursorStart()
    local n = y * size + x
    for _i = 1, size * size do
        if self.cursor then n = (n + step) % (size * size) end
        local cx, cy = n % size, math.floor(n / size)
        if board ~= "target" or m.target:can_fire(cx, cy) then
            self:setCursor(cx, cy)
            return true
        end
        if not self.cursor then n = (n + step) % (size * size) end
    end
    return true
end

function GameScreen:onKeyAct()
    local board = self:cursorBoard()
    if not board then return true end
    if not self.cursor then return self:onKeyStep(1) end -- first press: show the cursor
    local x, y = self.cursor[1], self.cursor[2]
    if board == "own" then self:onOwnTap(x, y) else self:onTargetTap(x, y) end
    return true
end

--- The Menu key: the screen's buttons in a dialog (it can be used with keys).
function GameScreen:onKeyMenu()
    local rows = {}
    local dialog
    for _i, b in ipairs(self:buttonRow() or {}) do
        if b.enabled ~= false then
            table.insert(rows, { { text = b.text, callback = function()
                UIManager:close(dialog)
                b.callback()
            end } })
        end
    end
    local has_close = false
    for _i, row in ipairs(rows) do if row[1].text == _("Close") then has_close = true end end
    if not has_close then
        table.insert(rows, { { text = _("Close"), callback = function()
            UIManager:close(dialog)
            self:onClose()
        end } })
    end
    dialog = ButtonDialog:new{ title = _("Battleships"), buttons = rows }
    UIManager:show(dialog)
    return true
end

function GameScreen:statusText()
    local m = game.match
    local lines = {}
    -- after the game the winner and the numbers say it all
    local over = m.phase == "over" and not game.lost and not game.waiting
    if game.message and not over then lines[#lines + 1] = game.message end
    if game.lost then
        -- message says why
    elseif game.waiting then
        lines[#lines + 1] = game.role == "host" and T(_("Waiting for %1 to come back…"), m.peer)
            or T(_("Reconnecting to %1…"), m.peer)
    elseif m.phase == "placing" then
        if not m.ready then
            if not self.selected then
                lines[#lines + 1] = _("Place your ships: drag them, or tap a ship to select it, tap it again to turn it, tap the water to move it there.")
            elseif game.match.board:can_rotate(self.selected) then
                lines[#lines + 1] = _("Tap the water to move the ship, tap the ship to turn it. Shaded squares have no room for it.")
            else
                lines[#lines + 1] = _("Tap the water to move the ship. Shaded squares have no room for it, and it has no room to turn here.")
            end
        elseif m.peer then
            lines[#lines + 1] = T(_("Waiting for %1 to place their ships…"), m.peer)
        end
        if not m.peer then
            if game.role == "host" then
                lines[#lines + 1] = game.ip and T(_("Waiting for an opponent. Your address: %1"), game.ip)
                    or _("Waiting for an opponent.")
            else
                lines[#lines + 1] = _("Connecting…")
            end
        end
    elseif m.phase == "battle" then
        -- short, to leave room for the boards; the whole hint before our first shot
        local first = m.stats.me.shots == 0
        if m.pending then lines[#lines + 1] = _("Firing…")
        elseif m.turn == "me" and m.rules.salvo then
            lines[#lines + 1] = first
                and T(_("Your turn: tap a square on the opponent's board. Shots left: %1."), m.shots_left)
                or T(_("Your turn: %1 shots left."), m.shots_left)
        elseif m.turn == "me" then
            lines[#lines + 1] = first and _("Your turn: tap a square on the opponent's board.") or _("Your turn.")
        else lines[#lines + 1] = T(_("%1 is aiming…"), m.peer) end
    else
        lines[#lines + 1] = m.winner == "me" and _("You won!") or T(_("%1 won."), m.peer)
        local function pct(st) return st.shots > 0 and math.floor(100 * st.hits / st.shots + 0.5) or 0 end
        local me, peer = m.stats.me, m.stats.peer
        lines[#lines + 1] = T(_("You: %1 of %2 shots hit (%3 %), longest series %4."),
            me.hits, me.shots, pct(me), me.best)
        lines[#lines + 1] = T(_("%1: %2 of %3 shots hit (%4 %), longest series %5."),
            m.peer, peer.hits, peer.shots, pct(peer), peer.best)
        if m.rematch and not m.peer_rematch then
            lines[#lines + 1] = T(_("Waiting for %1…"), m.peer)
        elseif m.peer_rematch and not m.rematch then
            lines[#lines + 1] = T(_("%1 wants to play again."), m.peer)
        end
    end
    return table.concat(lines, "\n")
end

function GameScreen:buttonRow()
    local m = game.match
    local close = { text = _("Close"), callback = function() self:onClose() end }
    if game.lost or game.waiting then return { close } end
    if m.phase == "placing" then
        local row = {
            { text = _("Random"), enabled = not m.ready, callback = function()
                m.board:randomize()
                self.selected = nil
                self:update()
            end },
        }
        if m.fleet == "shapes" then -- (straight ships look the same in a mirror)
            table.insert(row, { text = _("Mirror"),
                enabled = not m.ready and self.selected ~= nil and m.board:can_mirror(self.selected),
                callback = function()
                    if not self.selected then return end
                    if not m.board:mirror(self.selected) then notify(_("The ship cannot be mirrored here.")) end
                    self:update()
                end })
        end
        table.insert(row, { text = _("Ready"), enabled = not m.ready, callback = function()
            self.selected = nil
            local ev = m:set_ready()
            if ev then Battleships.onGameEvent(ev) else self:update() end
        end })
        return row
    elseif m.phase == "over" then
        return {
            { text = _("Play again"), enabled = not m.rematch, callback = function()
                local ev = m:request_rematch()
                if ev then Battleships.onGameEvent(ev) else self:update() end
            end },
            close,
        }
    end
end

function GameScreen:onOwnTap(x, y)
    local m = game.match
    if m.phase ~= "placing" or m.ready then return end
    local i = m.board:ship_at(x, y)
    if self.selected and i == self.selected then
        if not m.board:rotate(i) then notify(_("The ship cannot turn here.")) end
    elseif i then
        self.selected = i
    elseif self.selected then
        if m.board:move(self.selected, x, y) then self.selected = nil
        else notify(_("The ship does not fit there. Ships may not touch.")) end
    end
    self:update()
end

-- Dragging a ship while placing: see BoardWidget's on_drag.
function GameScreen:onDrag(phase, sx, sy, x, y)
    local m = game.match
    if m.phase ~= "placing" or m.ready then return false end
    local board = m.board
    local function clamp(v) return math.max(0, math.min(board.size - 1, v)) end
    if phase == "drop" then
        if not self.drag then return false end
        return self:dropDrag(x, y)
    end
    if not self.drag then
        local i = Board.inside(sx, sy, board.size) and board:ship_at(sx, sy)
        if not i then return false end
        local ax, ay = Board.anchor(board.ships[i])
        self.drag = { i = i, dx = sx - ax, dy = sy - ay } -- the square held, from the ship's anchor
    end
    if phase == "swipe" then return self:dropDrag(x, y) end
    local d = self.drag
    local cx, cy = clamp(x), clamp(y)
    if d.x == cx and d.y == cy then return true end -- same square: nothing to redraw
    d.x, d.y = cx, cy
    d.ship = board:position(d.i, cx - d.dx, cy - d.dy)
    d.fits = board:fits(d.ship, d.i)
    -- only the board changes, quickly (as an animation frame)
    local widget = self.board_widgets.own
    widget.drag = d
    UIManager:waitForVSync()
    UIManager:setDirty(nil, "fast", widget:paintRegion({ { 0, 0 }, { board.size - 1, board.size - 1 } }))
    return true
end

function GameScreen:dropDrag(x, y)
    local d = self.drag
    self.drag = nil
    if Board.inside(x, y, game.match.board.size) then
        local board = game.match.board
        if board:move(d.i, x - d.dx, y - d.dy) then
            self.selected = d.i -- ready to be turned
        else
            notify(_("The ship does not fit there. Ships may not touch."))
        end
    end -- (lifted off the board: nothing moves)
    self:update()
    return true
end

function GameScreen:onTargetTap(x, y)
    local m = game.match
    if not m:fire(x, y) then return end
    -- show our shell at once, without waiting for the result
    if game.animations then self:animate("target", "shell", { { x, y } }) end
    self:update{ board = "target", cells = game.animations and { { x, y } } or nil }
end

function GameScreen:build()
    local w, h = self.dimen.w, self.dimen.h
    local m = game.match
    local pad = Size.padding.large
    local inner_w = w - 2 * pad
    local last = self.last_shown
    self.previous_last = last
    self.last_shown = { target = m.last_fired, own = m.last_incoming }
    self.title_bar = TitleBar:new{
        width = w,
        fullscreen = true,
        -- the opponent and the score in the title itself: no subtitle line, more room for the boards
        title = m.peer and T(_("%1 · %2"), _("Battleships"), m.score.me + m.score.peer > 0
            and T(_("Opponent: %1 · You %2 : %3"), m.peer, m.score.me, m.score.peer)
            or T(_("Opponent: %1"), m.peer)) or _("Battleships"),
        title_shrink_font_to_fit = true,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local status = TextBoxWidget:new{
        text = self:statusText(),
        face = Font:getFace("cfont", 18),
        width = inner_w,
        alignment = "center",
    }
    -- room for a few lines at least, so that the boards stay put when the text
    -- changes: 3 while placing (the hints), 2 in the battle (message + turn)
    local status_h = math.max(status:getSize().h, status_min_height(inner_w, m.phase == "placing" and 3 or 2))
    local row = self:buttonRow()
    local buttons = row and ButtonTable:new{ width = inner_w, buttons = { row }, show_parent = self }
    local title_h = self.title_bar:getSize().h
    local used = title_h + status_h + 3 * pad
        + (buttons and buttons:getSize().h + pad or 0)
    self.status_region = Geom:new{ x = 0, y = title_h + pad, w = w, h = status_h }
    -- what decides where things are: when it changes, the whole screen is refreshed
    local enabled = {}
    for _i, b in ipairs(row or {}) do enabled[#enabled + 1] = tostring(b.enabled ~= false) end
    self.layout = table.concat({ w, h, m.phase, status_h, table.concat(enabled, ","), tostring(game.lost),
        m.peer or "", tostring(self.selected), tostring(m.ready) }, "|")
    local avail_h = h - used

    local boards
    if m.phase == "placing" then
        boards = BoardWidget:new{
            size = math.min(inner_w, avail_h),
            mode = "own", board = m.board, selected = self.selected, drag = self.drag,
            cursor = self:cursorBoard() == "own" and self.cursor or nil,
            on_tap = not m.ready and function(x, y) self:onOwnTap(x, y) end or nil,
            on_drag = not m.ready and function(...) return self:onDrag(...) end or nil,
        }
        self.board_widgets = { own = boards }
        self.fleet_view = nil
    else
        -- no labels: the opponent's board is the big one, with their fleet below it
        local target_size, own_size
        local landscape = w > h
        -- the opponent's fleet in small below their board: size from a first guess of the board
        local fleet_w, fleet_h = fleet_extent(m.fleet)
        local guess = landscape and math.floor((inner_w - pad) * TARGET_SHARE_LANDSCAPE)
            or math.min(inner_w, math.floor(avail_h * TARGET_SHARE))
        local mini = math.max(4, math.min(math.floor(guess / fleet_w), math.floor(guess / (m.rules.size + 1) * 0.45)))
        local gap = Size.padding.default
        local fleet_space = fleet_h * mini + gap
        if landscape then
            target_size = math.min(math.floor((inner_w - pad) * TARGET_SHARE_LANDSCAPE), avail_h - fleet_space)
            own_size = math.min(inner_w - pad - target_size, avail_h)
        else
            local h2 = avail_h - pad - fleet_space
            target_size = math.min(inner_w, math.floor(h2 * TARGET_SHARE))
            own_size = math.min(inner_w, h2 - target_size)
        end
        -- no wider than the board
        mini = math.max(4, math.min(mini, math.floor(target_size / fleet_w)))
        local fleet_view = FleetWidget:new{ fleet = m.fleet, target = m.target, square = mini }
        self.fleet_view = fleet_view
        local anim = self.anim
        local target = BoardWidget:new{
            size = target_size, mode = "target", target = m.target, last = m.last_fired,
            anim = anim and anim.board == "target" and anim or nil,
            cursor = self:cursorBoard() == "target" and self.cursor or nil,
            on_tap = m.phase == "battle" and not game.lost and not game.waiting
                and function(x, y) self:onTargetTap(x, y) end or nil,
        }
        local own = BoardWidget:new{
            size = own_size, mode = "own", board = m.board, last = m.last_incoming,
            anim = anim and anim.board == "own" and anim or nil,
        }
        self.board_widgets = { target = target, own = own }
        local group = landscape and HorizontalGroup or VerticalGroup
        boards = group:new{
            align = landscape and "top" or "center",
            VerticalGroup:new{ align = "center", target, VerticalSpan:new{ width = gap }, fleet_view },
            landscape and HorizontalSpan:new{ width = pad } or VerticalSpan:new{ width = pad },
            VerticalGroup:new{ align = "center", own },
        }
    end

    local content = VerticalGroup:new{
        align = "center",
        self.title_bar,
        VerticalSpan:new{ width = pad },
        status,
        VerticalSpan:new{ width = status_h - status:getSize().h + pad },
        boards,
        VerticalSpan:new{ width = pad },
    }
    if buttons then table.insert(content, buttons) end
    self[1] = FrameContainer:new{
        width = w,
        height = h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
end

--- Rebuilds the screen and refreshes it. hint = { board = "own" | "target",
-- cells } when only a shot changed: then, if nothing moved, only the status
-- line, the shot's squares (and their neighbours) and the old last-shot outline
-- are refreshed, not the whole screen (faster on e-ink). The squares of a
-- running animation get a fast refresh, sent last: the next frame only waits
-- for that one.
function GameScreen:update(hint)
    local layout = self.layout
    local sunk_before = self.fleet_view and self.fleet_view:sunkCount()
    self:build()
    save_game() -- every change of the game passes here
    if not hint or layout ~= self.layout then
        UIManager:setDirty(self, "ui")
        return
    end
    UIManager:setDirty(self, "ui", self.status_region)
    local board = hint.board
    local prev, now_last = self.previous_last and self.previous_last[board], self.last_shown[board]
    if prev and prev ~= now_last then
        UIManager:setDirty(self, function() return "ui", self.board_widgets[board]:cellRegion(prev) end)
    end
    if self.fleet_view and self.fleet_view:sunkCount() ~= sunk_before then
        UIManager:setDirty(self, function() return "ui", self.fleet_view.dimen end)
    end
    if hint.cells then
        local animated = self.anim and self.anim.board == board
        UIManager:setDirty(self, function()
            return animated and "fast" or "ui", self.board_widgets[board]:region(hint.cells)
        end)
    end
end

function GameScreen:onClose()
    local m = game.match
    local idle = game.lost or m.phase == "over" or not m.peer
    if idle then
        Battleships.endGame()
    else
        UIManager:show(ConfirmBox:new{
            text = _("Leave the game?"),
            ok_text = _("Leave"),
            ok_callback = function() Battleships.endGame() end,
        })
    end
    return true
end

-- Running a game ---------------------------------------------------------------

local ERRORS = {
    version = _("The other device has a different version of Battleships."),
    busy = _("This game already has two players."),
    resume = _("The game can no longer be resumed."),
}

--- Ends the game. keep_saved: KOReader is closing, the saved game stays for later
-- (and the opponent gets no BYE: it waits for us to come back).
function Battleships.endGame(keep_saved)
    if keep_saved then
        save_game()
        if game.conn then game.conn:close(); game.conn = nil end
    else
        clear_saved_game()
    end
    if game.candidate then game.candidate:close() end
    stop_reconnect()
    if game.conn then
        if game.match and game.match.peer then game.match:bye() end
        game.conn:close()
    end
    if game.host then game.host:close() end
    if game.zmq then UIManager:removeZMQ(game.zmq) end
    if game.standby then UIManager:allowStandby() end
    kindle_firewall("-D", game.rules)
    local screen = game.screen
    if screen then screen:stopAnimation() end
    free_canvases()
    game = {}
    -- the screen covers everything: without a refresh type the display would keep showing it
    if screen then UIManager:close(screen, "full") end
end

--- The connection ended: `reason` = "left" (BYE), an ERRORS key, or a socket error.
--- The connection is gone. resumable: lost by the network (not BYE, not an error),
-- so the game waits for it to come back when both sides know how.
local function connection_lost(reason, resumable)
    if game.conn then game.conn:close() end
    game.conn = nil
    local m = game.match
    local who = m.peer or _("The opponent")
    if resumable and m:can_resume() then
        game.waiting = true
        game.message = T(_("Connection to %1 lost."), who)
        if game.role == "guest" and not game.reconnect then game.reconnect = { next_at = 0 } end
    elseif game.role == "host" and m.phase == "placing" and not ERRORS[reason] then
        -- the battle hasn't started: wait for someone else
        if m.peer then game.message = T(_("%1 left."), who) end
        m:drop_peer()
    else
        game.lost = true
        if ERRORS[reason] then game.message = ERRORS[reason]
        elseif reason == "left" then game.message = T(_("%1 left the game."), who)
        else game.message = m.peer and T(_("Connection to %1 lost."), who) or _("Connection lost.") end
        if game.host then game.host:close(); game.host = nil end
        game.waiting = nil
        stop_reconnect()
    end
    if game.screen then
        game.screen:stopAnimation()
        game.screen:update()
    end
end

-- %1 = square, %2 = the sunk ship's name
local RESULT_TEXT = {
    miss = _("%1: miss."),
    hit = _("%1: hit! Fire again."),
    sunk = _("%1: hit, the %2 goes down! Fire again."),
    won = _("%1: hit, the %2 goes down!"),
}

-- In a salvo, a hit doesn't give another shot (the shots of the turn are counted).
local RESULT_SALVO_TEXT = {
    miss = _("%1: miss."),
    hit = _("%1: hit!"),
    sunk = _("%1: hit, the %2 goes down!"),
    won = _("%1: hit, the %2 goes down!"),
}

-- %1 = opponent, %2 = square, %3 = the sunk ship's name
local INCOMING_TEXT = {
    miss = _("%1 fired at %2: miss."),
    hit = _("%1 fired at %2: hit."),
    sunk = _("%1 fired at %2: your %3 goes down."),
    won = _("%1 fired at %2: your %3 goes down, your last ship."),
}

-- Ship names by shape (the classic fleet's two ships of 3 look the same: both cruisers).
local SHIP_NAMES = {
    line5 = _("aircraft carrier"),
    line4 = _("battleship"),
    line3 = _("cruiser"),
    line2 = _("destroyer"),
    carrier = _("aircraft carrier"),
    cruiser = _("cruiser"),
    battleship = _("battleship"),
    destroyer = _("destroyer"),
    submarine = _("submarine"),
}
local function ship_name(ship)
    return ship and SHIP_NAMES[ship.shape] or _("ship")
end

--- Updates the screen after a match event (see battleshipswifi/match.lua).
function Battleships.onGameEvent(ev)
    local m = game.match
    local t = ev.type
    if t == "joined" and game.ai then
        game.message = T(_("You play against the e-reader. Difficulty: %1."), LEVEL_NAMES[game.ai.level])
    elseif t == "peer_ready" and game.ai then
        -- (the e-reader is ready at once: keep the message above)
    elseif t == "joined" then
        game.message = game.role == "host" and T(_("%1 joined the game."), ev.name)
            or T(_("You joined %1's game: %2."), ev.name, game_kind(m.fleet, m.rules))
        if ev.fleet_changed and game.screen then game.screen.selected = nil end
    elseif t == "peer_ready" then
        game.message = T(_("%1 is ready."), m.peer)
    elseif t == "start" then
        game.message = ev.turn == "me" and _("The battle begins. You fire first.")
            or T(_("The battle begins. %1 fires first."), m.peer)
    elseif t == "result" then
        game.message = T((m.rules.salvo and RESULT_SALVO_TEXT or RESULT_TEXT)[ev.result],
            Board.label(ev.x, ev.y), ship_name(ev.ship))
        if game.screen then
            game.screen:update{ board = "target", cells = game.screen:animateShot("target", ev) }
            return
        end
    elseif t == "incoming" then
        game.message = T(INCOMING_TEXT[ev.result], m.peer, Board.label(ev.x, ev.y), ship_name(ev.ship))
        if game.screen then
            game.screen:update{ board = "own", cells = game.screen:animateShot("own", ev) }
            return
        end
    elseif t == "rematch" then
        game.message = _("New game: place your ships.")
        if game.screen then
            game.screen.selected = nil
            game.screen:stopAnimation()
        end
    elseif t == "left" then
        connection_lost("left")
        return
    elseif t == "resumed" then
        game.waiting = nil
        stop_reconnect()
        game.message = T(_("Connection to %1 restored."), m.peer)
    end
    if game.screen then game.screen:update() end
end

-- A line from the opponent (device or e-reader). Returns false when it ended the game
-- (or, while waiting for the opponent to come back, the connection that sent it).
local function handle_line(line)
    local conn = game.conn
    local ev, perr = game.match:receive(line)
    if perr then
        logger.warn("Battleships: protocol error", perr, line)
        if game.waiting and game.role == "host" then
            -- not our guest coming back (RESUME already answered ERROR resume)
            if conn then
                if perr ~= "resume" then conn:send(Protocol.line("ERROR", "busy")) end
                conn:close()
            end
            game.conn = nil
            return false
        end
        if game.waiting and game.role == "guest" and perr == "busy" then
            -- the host still holds our previous attempt: try again
            if conn then conn:close() end
            game.conn = nil
            if game.reconnect then game.reconnect.next_at = now() + RECONNECT_INTERVAL end
            return false
        end
        if conn and not ERRORS[perr] then conn:send(Protocol.line("ERROR", "protocol")) end
        connection_lost(perr)
        return false
    end
    if ev then Battleships.onGameEvent(ev) end
    return game.conn == conn and game.match ~= nil
end

-- Guest waiting to resume: connects again, to the last address or to the one the
-- host answers searches with (its address may have changed), every RECONNECT_INTERVAL.
local function poll_reconnect(t)
    local socket = require("socket")
    local r = game.reconnect
    if not r.search and t >= (r.search_at or 0) then
        r.search = Net.search(socket, Net.local_ip(socket))
        if r.search then
            r.rules = search_rules()
            kindle_firewall("-A", r.rules)
            r.last_sent = 0
        else
            r.search_at = t + RECONNECT_INTERVAL -- no network yet
        end
    end
    if r.search then
        if t - r.last_sent >= SEARCH_INTERVAL then
            r.last_sent = t
            r.search:send()
        end
        r.search:poll(t)
        r.found = r.search.resumes[game.match.session] or r.found
    end
    if game.conn then return end -- connected: waiting for RESUMED
    if r.pending then
        local conn = r.pending:poll(t, CONNECT_TIMEOUT)
        if conn then
            r.pending = nil
            game.conn = conn
            game.last_ping = t
            game.match:resume()
        elseif conn == false then
            r.pending = nil
            r.next_at = t + RECONNECT_INTERVAL
        end
    elseif t >= (r.next_at or 0) then
        local addr = r.found or game.address
        r.pending = Net.connect_async(socket, addr.ip, addr.port, t)
        if not r.pending then r.next_at = t + RECONNECT_INTERVAL end
    end
end

-- Host: a second device connecting while we still have a connection. After the
-- battle started it may be our guest coming back (we haven't noticed it was gone):
-- its first line tells (RESUME); else it is turned away.
local function poll_candidate(t)
    local cand = game.candidate
    local lines = cand:poll(t)
    if not lines then
        game.candidate = nil
        return
    end
    local first = lines[1]
    if not first then
        if t - cand.last_seen > CONNECT_TIMEOUT then cand:close(); game.candidate = nil end
        return
    end
    game.candidate = nil
    if not first:match("^RESUME ") then
        cand:send(Protocol.line("ERROR", "busy"))
        cand:close()
        return
    end
    -- our guest is back: drop the old connection, go on with this one
    if game.conn then game.conn:close() end
    game.conn = cand
    game.waiting = true
    game.last_ping = t
    for _i, line in ipairs(lines) do
        if not handle_line(line) then return end
    end
end

local function poll_game()
    local t = now()
    if game.ai then
        local ai = game.ai
        local lines, err = ai:poll(t)
        if err then logger.warn("Battleships: e-reader player", err) end
        for _i, line in ipairs(lines) do
            if game.ai ~= ai or not handle_line(line) then return end
        end
        return
    end
    if game.paused then return end -- asleep: no network
    local m = game.match
    if game.role == "host" and not game.host and game.waiting and t >= (game.rebind_at or 0) then
        -- after sleeping: listen again (the address may have changed)
        local socket = require("socket")
        game.host = Net.host(socket, Protocol.PORT)
        if game.host then game.ip = Net.local_ip(socket) else game.rebind_at = t + RECONNECT_INTERVAL end
    end
    if game.host then
        local client = game.host:accept()
        if client then
            if not game.conn then
                game.conn = Net.connection(client, t)
                game.last_ping = t
            elseif m:can_resume() and not game.candidate then
                game.candidate = Net.connection(client, t)
            else
                client:settimeout(1)
                client:send(Protocol.line("ERROR", "busy"))
                client:close()
            end
        end
        if game.waiting then game.host:answer(nil, m.fleet, m.session)
        else game.host:answer(not game.conn and m.name or nil, m.fleet, nil, Board.encode_rules(m.rules)) end
    end
    if game.candidate then
        poll_candidate(t)
        if game.match ~= m then return end
    end
    if game.reconnect then poll_reconnect(t) end
    local conn = game.conn
    if not conn then return end
    local lines, err = conn:poll(t)
    for _i, line in ipairs(lines or {}) do
        if not handle_line(line) then return end -- the line ended the connection
    end
    if not lines then
        connection_lost(err, true)
    elseif t - conn.last_seen > PEER_TIMEOUT then
        connection_lost("timeout", true)
    elseif t - (game.last_ping or 0) >= PING_INTERVAL then
        game.last_ping = t
        m:ping()
    end
end

--- fields.fleet: the host's choice, or what the guest found in the game list.
function Battleships:startGame(role, fields)
    game = fields
    game.role = role
    game.animations = self:animationsOn()
    local send = function(line)
        if game.conn then game.conn:send(line)
        elseif game.ai then game.ai:deliver(line) end
    end
    if fields.restore then
        game.match = Match.restore(fields.restore.match, { send = send })
        if not game.match then
            clear_saved_game()
            game = {}
            UIManager:show(InfoMessage:new{ text = _("The saved game cannot be continued.") })
            return false
        end
        game.message = T(_("Continuing the game against %1."), game.match.peer)
    else
        game.match = Match.new{ role = role, name = self:playerName(), fleet = fields.fleet,
            rules = fields.game_rules, send = send }
    end
    game.last_ping = now()
    game.zmq = poller(poll_game, "game")
    if not fields.ai_level then
        -- network games: the device mustn't doze off while the other one plays
        UIManager:preventStandby()
        game.standby = true
    end
    game.screen = GameScreen:new{}
    UIManager:show(game.screen)
    if fields.ai_level then
        local restore = fields.restore and fields.restore.ai
        game.ai = AI.player{ level = fields.ai_level, name = _("E-reader"), delay = AI_DELAY,
            restore = restore and restore.match }
        if not game.ai then
            Battleships.endGame()
            UIManager:show(InfoMessage:new{ text = _("The saved game cannot be continued.") })
            return false
        end
        if restore then
            -- lines that were on the way when it was saved go again (see Match:send_again())
            game.match:send_again(game.ai.match.received)
            game.ai.match:send_again(game.match.received)
        end
    end
    return true
end

--- Goes on with the game saved when KOReader closed (see save_game()).
function Battleships:continueSaved()
    local snap = saved_game()
    if not snap then return end
    if snap.ai then
        local level = LEVEL_NAMES[snap.ai.level or ""] and snap.ai.level or AI.DEFAULT_LEVEL
        self:startGame("host", { restore = snap, ai_level = level })
        return
    end
    NetworkMgr:runWhenOnline(function()
        if game.match then return end
        local address = snap.address
        if snap.role == "guest" and not (type(address) == "table" and address.ip and address.port) then
            clear_saved_game()
            UIManager:show(InfoMessage:new{ text = _("The saved game cannot be continued.") })
            return
        end
        local rules = snap.role == "host" and host_rules(Protocol.PORT) or guest_rules(address.port)
        kindle_firewall("-A", rules)
        if not self:startGame(snap.role, { restore = snap, rules = rules, address = address }) then
            kindle_firewall("-D", rules)
            return
        end
        -- the opponent's device is waiting for us: host listens again, guest reconnects
        game.waiting = true
        if snap.role == "host" then game.rebind_at = 0 else game.reconnect = { next_at = 0 } end
        game.screen:update()
    end)
end

--- A game against the e-reader (no network), with `fleet` and the level set in the menu.
function Battleships:playAgainstReader(fleet)
    Battleships.endGame()
    self:startGame("host", { fleet = fleet, ai_level = self:aiLevel(), game_rules = self:gameRules() })
end

--- The rules picked in the menu (for hosting and against the e-reader).
function Battleships:gameRules()
    return Board.rules{
        size = self.settings:readSetting("rules_size"),
        salvo = self.settings:readSetting("rules_salvo"),
        touch = self.settings:readSetting("rules_touch"),
    }
end

--- Menu items to pick the rules (check boxes; the fleet items start the game).
function Battleships:rulesItems()
    local function toggle(key, on_value)
        return function()
            local now_on = self.settings:readSetting(key) == on_value
            self.settings:saveSetting(key, not now_on and on_value or nil)
            self.settings:flush()
        end
    end
    return {
        { text = T(_("Board %1 × %1"), 12), battleshipswifi_item = "rules_size", keep_menu_open = true,
            checked_func = function() return self:gameRules().size == 12 end, callback = toggle("rules_size", 12) },
        { text = _("Salvo: as many shots a turn as ships afloat"), battleshipswifi_item = "rules_salvo",
            keep_menu_open = true,
            checked_func = function() return self:gameRules().salvo end, callback = toggle("rules_salvo", true) },
        { text = _("Ships may touch"), battleshipswifi_item = "rules_touch", keep_menu_open = true,
            checked_func = function() return self:gameRules().touch end, callback = toggle("rules_touch", true) },
    }
end

--- The fleet picked in the menu (setting `fleet`, shared by hosting and the e-reader).
function Battleships:fleet()
    local fleet = self.settings:readSetting("fleet")
    return Board.FLEETS[fleet or ""] and fleet or Board.FLEET_ORDER[1]
end

--- Start game (`id`_start, calls `start`) and the fleet choice (a submenu like Difficulty).
function Battleships:startItems(id, start)
    local fleets = {}
    for _i, fleet in ipairs(Board.FLEET_ORDER) do
        table.insert(fleets, {
            text = FLEET_NAMES[fleet],
            battleshipswifi_item = "fleet_" .. fleet,
            checked_func = function() return self:fleet() == fleet end,
            radio = true,
            callback = function()
                self.settings:saveSetting("fleet", fleet)
                self.settings:flush()
            end,
        })
    end
    return {
        { text = _("Start game"), battleshipswifi_item = id .. "_start", callback = start, separator = true },
        { text_func = function() return T(_("Ships: %1"), FLEET_NAMES[self:fleet()]) end,
            battleshipswifi_item = "fleet", sub_item_table = fleets, separator = true },
    }
end

function Battleships:aiLevel()
    local level = self.settings:readSetting("ai_level")
    return LEVEL_NAMES[level or ""] and level or AI.DEFAULT_LEVEL
end

function Battleships:hostGame(fleet)
    NetworkMgr:runWhenOnline(function()
        Battleships.endGame()
        local socket = require("socket")
        local host, err = Net.host(socket, Protocol.PORT)
        if not host then
            UIManager:show(InfoMessage:new{ text = T(_("Cannot host a game: %1"), tostring(err)) })
            return
        end
        local rules = host_rules(Protocol.PORT)
        kindle_firewall("-A", rules)
        self:startGame("host", { host = host, ip = Net.local_ip(socket), rules = rules, fleet = fleet,
            game_rules = self:gameRules() })
    end)
end

--- fleet, rules: the host's, when known from the game list (else WELCOME tells).
function Battleships:joinGame(ip, port, fleet, rules)
    NetworkMgr:runWhenOnline(function()
        Battleships.endGame()
        local socket = require("socket")
        local fw_rules = guest_rules(port)
        kindle_firewall("-A", fw_rules)
        local msg = InfoMessage:new{ text = T(_("Connecting to %1…"), ip) }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local conn, err = Net.connect(socket, ip, port, CONNECT_TIMEOUT, now())
        UIManager:close(msg)
        if not conn then
            kindle_firewall("-D", fw_rules)
            UIManager:show(InfoMessage:new{ text = T(_("Cannot connect to %1: %2"), ip, tostring(err)) })
            return
        end
        self:startGame("guest", { conn = conn, rules = fw_rules, fleet = fleet, game_rules = rules,
            address = { ip = ip, port = port } })
        game.match:hello()
    end)
end

function Battleships:joinByAddress()
    local dialog
    dialog = InputDialog:new{
        title = _("Join by address"),
        input = self.settings:readSetting("last_address") or "",
        input_hint = "192.168.1.10",
        description = _("The address is shown on the host's screen."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Join"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                local ip, port = Protocol.parse_address(text)
                if not ip then
                    notify(_("Invalid address"))
                    return
                end
                UIManager:close(dialog)
                self.settings:saveSetting("last_address", text)
                self.settings:flush()
                self:joinGame(ip, port)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Finding games ----------------------------------------------------------------

local function stop_finder()
    if finder.zmq then UIManager:removeZMQ(finder.zmq) end
    if finder.search then finder.search:close() end
    kindle_firewall("-D", finder.rules)
    finder = {}
end

function Battleships:finderItems()
    local items = {}
    for _i, g in ipairs(finder.search and finder.search.games or {}) do
        local fleet = Board.FLEETS[g.fleet or ""] and g.fleet or nil
        local rules = Board.decode_rules(g.rules)
        local name = g.name ~= "" and g.name or g.ip
        table.insert(items, {
            text = fleet and rules and T(_("%1 (%2)"), name, game_kind(fleet, rules)) or name,
            mandatory = g.ip,
            callback = function()
                local ip, port = g.ip, g.port
                UIManager:close(finder.menu)
                self:joinGame(ip, port, fleet, rules)
            end,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("Searching for games…"), dim = true, callback = function() end })
    end
    items[#items].separator = true
    table.insert(items, { text = _("Join by address…"), callback = function()
        UIManager:close(finder.menu)
        self:joinByAddress()
    end })
    return items
end

local function poll_finder(plugin)
    local t = now()
    if t - finder.last_sent >= SEARCH_INTERVAL then
        finder.last_sent = t
        finder.search:send()
    end
    local changed = finder.search:poll(t)
    changed = finder.search:expire(t, SEARCH_EXPIRE) or changed
    if changed and finder.menu then
        finder.menu:switchItemTable(nil, plugin:finderItems())
    end
end

function Battleships:findGames()
    NetworkMgr:runWhenOnline(function()
        stop_finder()
        local socket = require("socket")
        local search, err = Net.search(socket, Net.local_ip(socket))
        if not search then
            UIManager:show(InfoMessage:new{ text = T(_("Cannot search for games: %1"), tostring(err)) })
            return
        end
        finder = { search = search, last_sent = 0, rules = search_rules() }
        kindle_firewall("-A", finder.rules)
        local menu = Menu:new{
            title = _("Find a game"),
            item_table = self:finderItems(),
            covers_fullscreen = true,
            is_borderless = true,
            is_popout = false,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
        }
        local on_close = menu.onCloseWidget
        menu.onCloseWidget = function(m)
            stop_finder()
            if on_close then return on_close(m) end
        end
        finder.menu = menu
        finder.zmq = poller(function() poll_finder(self) end, "search")
        UIManager:show(menu)
    end)
end

-- Plugin -----------------------------------------------------------------------

function Battleships:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/battleshipswifi.lua")
    if not self.settings:readSetting("migrated") then
        -- before 0.2.0 the plugin was called battleships: keep the name and the last address, once
        -- (until 1.1.3 on every start while no name was set, which brought the old address back)
        local old = LuaSettings:open(DataStorage:getSettingsDir() .. "/battleships.lua")
        for _i, key in ipairs({ "name", "last_address" }) do
            if self.settings:readSetting(key) == nil and old:readSetting(key) ~= nil then
                self.settings:saveSetting(key, old:readSetting(key))
            end
        end
        self.settings:saveSetting("migrated", true)
        self.settings:flush()
    end
    self.ui.menu:registerToMainMenu(self)
end

function Battleships:playerName()
    local name = Protocol.clean_name(self.settings:readSetting("name"))
    if name == "" then name = Protocol.clean_name(Device.model or "") end
    if name == "" then name = _("Player") end
    return name
end

function Battleships:editName(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Your name"),
        input = self:playerName(),
        description = _("Shown to the other player and in the list of games."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                self.settings:saveSetting("name", Protocol.clean_name(dialog:getInputText()))
                self.settings:flush()
                UIManager:close(dialog)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Battleships:animationsOn()
    return self.settings:readSetting("animations") ~= false
end

function Battleships:showRules()
    UIManager:show(InfoMessage:new{
        text = _([[The host picks the fleet. Classic ships: five straight ships of 5, 4, 3, 3 and 2 squares. Shaped ships: an aircraft carrier (a row of 4 with 2 below the middle), a cruiser (a cross of 5), a battleship (a row of 4 with 1 below), a destroyer (an L of 4) and two submarines of 2. Ships lie on a 10 × 10 board and may not touch, not even at the corners.

Players take turns firing at a square of the opponent's board. After a hit you fire again, after a miss it's the opponent's turn. Whoever sinks the whole enemy fleet first wins.

Two players: both devices must be on the same Wi-Fi network. One player hosts the game, the other finds it in Find a game or joins by the address shown on the host's screen.

One player: Play against the e-reader, on one device and without a network. The e-reader plays easy, normal or hard (Difficulty).

Rules to pick before starting (Host a game, Play against the e-reader): a 12 × 12 board, salvo (each turn as many shots as you have ships afloat, a hit doesn't give another one) and ships that may touch (then the water around a sunk ship isn't marked).

With keys: the arrows (or the page keys) move a cursor on the board, Press fires or picks up, turns and puts down a ship; without arrows, page back steps to the next square and page forward fires. Menu shows the screen's buttons.]]),
    })
end

function Battleships:mainMenu()
    local items = {}
    local snap = not game.match and saved_game()
    if snap then
        table.insert(items, {
            text = T(_("Continue the game against %1"), snap.opponent or "?"),
            battleshipswifi_item = "continue",
            callback = function() self:continueSaved() end,
            separator = true,
        })
    end
    for _i, it in ipairs(self:gameMenu()) do table.insert(items, it) end
    return items
end

function Battleships:gameMenu()
    return {
        { text = _("Play against the e-reader"), battleshipswifi_item = "ai", sub_item_table_func = function()
            local items = self:startItems("ai", function() self:playAgainstReader(self:fleet()) end)
            for _i, it in ipairs(self:rulesItems()) do table.insert(items, it) end
            items[#items].separator = true
            local levels = {}
            for _i, level in ipairs(AI.LEVELS) do
                table.insert(levels, {
                    text = LEVEL_NAMES[level],
                    battleshipswifi_item = "ai_level_" .. level,
                    checked_func = function() return self:aiLevel() == level end,
                    radio = true,
                    callback = function()
                        self.settings:saveSetting("ai_level", level)
                        self.settings:flush()
                    end,
                })
            end
            table.insert(items, {
                text_func = function() return T(_("Difficulty: %1"), LEVEL_NAMES[self:aiLevel()]) end,
                battleshipswifi_item = "ai_level",
                sub_item_table = levels,
            })
            return items
        end, separator = true },
        { text = _("Host a game"), battleshipswifi_item = "host", sub_item_table_func = function()
            local items = self:startItems("host", function() self:hostGame(self:fleet()) end)
            for _i, it in ipairs(self:rulesItems()) do table.insert(items, it) end
            return items
        end },
        { text = _("Find a game"), battleshipswifi_item = "find", callback = function() self:findGames() end,
            separator = true },
        { text = _("Settings"), battleshipswifi_item = "settings", sub_item_table = {
            { text_func = function() return T(_("Your name: %1"), self:playerName()) end, battleshipswifi_item = "name",
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:editName(touchmenu_instance) end },
            { text = _("Animations"), battleshipswifi_item = "animations", keep_menu_open = true,
                checked_func = function() return self:animationsOn() end,
                callback = function()
                    local on = not self:animationsOn()
                    self.settings:saveSetting("animations", on)
                    self.settings:flush()
                    if game.match then game.animations = on end
                end },
        } },
        { text = _("Rules"), battleshipswifi_item = "rules", keep_menu_open = true,
            callback = function() self:showRules() end },
    }
end

function Battleships:addToMainMenu(menu_items)
    menu_items.battleshipswifi = {
        text = _("Battleships (Wi-Fi)"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:mainMenu() end,
    }
end

function Battleships:onSuspend()
    stop_finder()
    if game.ai or not game.match then return end -- a game against the e-reader just waits
    if game.lost or not game.match:can_resume() then
        -- Wi-Fi goes off while the device sleeps: leave instead of timing out
        Battleships.endGame()
        return
    end
    -- the game waits; the network goes (no BYE: the opponent waits for us to come back)
    if game.candidate then game.candidate:close(); game.candidate = nil end
    if game.conn then game.conn:close(); game.conn = nil end
    if game.host then game.host:close(); game.host = nil end
    stop_reconnect()
    game.reconnect = game.role == "guest" and { next_at = 0 } or nil
    game.waiting, game.paused = true, true
    if game.screen then
        game.screen:stopAnimation()
        game.screen:update()
    end
end

function Battleships:onResume()
    if not game.paused then return end
    game.paused = nil
    game.rebind_at = 0
    if game.screen then game.screen:update() end
    -- the attempts start right away; this only brings Wi-Fi back if it is off
    NetworkMgr:runWhenOnline(function() end)
end

function Battleships:onExit()
    stop_finder()
    -- a game that can go on is saved (see save_game()), to be continued after the restart
    local m = game.match
    Battleships.endGame(m and not game.lost and (game.ai ~= nil or m:can_resume()))
end

return Battleships
