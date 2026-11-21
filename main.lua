--[[--
Battleships plugin: the classic game for two players, each on their own
e-reader, over Wi-Fi. One device hosts the game, the other joins it, either by
address or by finding it on the local network (UDP broadcast).

@module koplugin.Battleships
]]

-- Own modules must be required at load time: PluginLoader only adds the
-- plugin folder to package.path while main.lua is being loaded.
local Board = require("battleshipswifi/board")
local L10n = require("battleshipswifi/l10n")
local Match = require("battleshipswifi/match")
local Net = require("battleshipswifi/net")
local Protocol = require("battleshipswifi/protocol")

local Blitbuffer = require("ffi/blitbuffer")
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
local SEARCH_EXPIRE = 5    -- seconds: games not heard of are dropped from the list

local FLEET_NAMES = {
    classic = _("Classic ships"),
    shapes = _("Shaped ships"),
}

local function now()
    return time.to_s(time.now())
end

local function notify(text)
    Notification:notify(text)
end

-- The running game and the game search. Module-level, not on the plugin
-- instance: KOReader makes a new instance for every reader/file manager.
-- game: { role, match, conn, host, ip, screen, zmq, message, lost, last_ping, rules, animations }
local game = {}
-- finder: { search, menu, zmq, last_sent, rules }
local finder = {}

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

local function disc(bb, cx, cy, r, color)
    r = math.max(1, math.floor(r))
    bb:paintCircle(cx, cy, r, color)
end

local function ring(bb, cx, cy, r, w, color)
    r = math.max(1, math.floor(r))
    bb:paintCircle(cx, cy, r, color, math.max(1, math.min(r, math.floor(w))))
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
local SINK_STEPS = 4
local function frame_count(kind, cells)
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
-- on_tap(x, y) makes it tappable.
local BoardWidget = InputContainer:extend{
    size = nil,
    mode = "own",
    board = nil,
    target = nil,
    selected = nil,
    last = nil,
    anim = nil,
    on_tap = nil,
}

function BoardWidget:init()
    local n = Board.SIZE + 1
    self.cell = math.floor(self.size / n)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.cell * n, h = self.cell * n }
    self.line = math.max(1, math.floor(self.cell / 25))
    self.inset = math.max(self.line + 1, math.floor(self.cell * 0.14))
    self.blocked = self.mode == "own" and self.selected and self.board:blocked(self.selected) or nil
    local fs = font_sizes[self.cell]
    if not fs then
        fs = TextWidget:getFontSizeToFitHeight("cfont", math.floor(self.cell * 0.75), 0)
        font_sizes[self.cell] = fs
    end
    local face = Font:getFace("cfont", fs)
    self.cols, self.rows = {}, {}
    for i = 0, Board.SIZE - 1 do
        self.cols[i] = TextWidget:new{ text = string.char(65 + i), face = face, padding = 0 }
        self.rows[i] = TextWidget:new{ text = tostring(i + 1), face = face, padding = 0 }
    end
    if self.on_tap then
        self.ges_events = {
            TapBoard = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        }
    end
end

function BoardWidget:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function BoardWidget:onTapBoard(_args, ges)
    local x = math.floor((ges.pos.x - self.dimen.x) / self.cell) - 1
    local y = math.floor((ges.pos.y - self.dimen.y) / self.cell) - 1
    if Board.inside(x, y) then self.on_tap(x, y) end
    return true
end

-- Squares' bounding box grown by `grow` squares, kept within lo..SIZE - 1.
local function bounds(cells, grow, lo)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _i, cell in ipairs(cells) do
        x0, y0 = math.min(x0, cell[1]), math.min(y0, cell[2])
        x1, y1 = math.max(x1, cell[1]), math.max(y1, cell[2])
    end
    local hi = Board.SIZE - 1
    return math.max(lo, x0 - grow), math.max(lo, y0 - grow), math.min(hi, x1 + grow), math.min(hi, y1 + grow)
end

--- Screen rectangle an animation of the given squares (list of { x, y }) paints
-- on: the squares, their neighbours and, at the edge, the labels.
function BoardWidget:region(cells)
    local c = self.cell
    local x0, y0, x1, y1 = bounds(cells, 1, -1)
    return Geom:new{
        x = self.dimen.x + c * (x0 + 1), y = self.dimen.y + c * (y0 + 1),
        w = c * (x1 - x0 + 1) + 2 * self.line, h = c * (y1 - y0 + 1) + 2 * self.line,
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
        local x0, y0, x1, y1 = bounds(anim.cells, 1, 0)
        bb:paintRect(ox + x0 * c, oy + y0 * c, (x1 - x0 + 1) * c + line, (y1 - y0 + 1) * c + line, black)
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
    local animated = self.anim and self.anim.set[y * Board.SIZE + x]
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
    local c, n = self.cell, Board.SIZE
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
end

function BoardWidget:onCloseWidget()
    for i = 0, Board.SIZE - 1 do
        self.cols[i]:free()
        self.rows[i]:free()
    end
end

-- Game screen ------------------------------------------------------------------

local GameScreen = InputContainer:extend{
    covers_fullscreen = true,
    selected = nil, -- ship being moved while placing
    anim = nil, -- running animation: { board = "own" | "target", kind, cells, set, ship, frame, frames }
}

--- Plays an animation ("miss", "hit" or "sunk" with its ship) on squares of the
-- "own" or "target" board. Frame 1 is painted with the next update(), the rest
-- every FRAME_TIME with a fast refresh of just those squares and their
-- neighbours; a normal refresh cleans up at the end.
function GameScreen:animate(board, kind, cells, ship)
    self:stopAnimation()
    local set = {}
    for _i, c in ipairs(cells) do set[c[2] * Board.SIZE + c[1]] = true end
    self.anim = { board = board, kind = kind, cells = cells, set = set, ship = ship, frame = 1,
        frames = frame_count(kind, cells) }
    self.anim_step = function() self:animationStep() end
    UIManager:scheduleIn(FRAME_TIME, self.anim_step)
end

function GameScreen:stopAnimation()
    if self.anim_step then UIManager:unschedule(self.anim_step) end
    self.anim, self.anim_step = nil, nil
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
    else
        UIManager:scheduleIn(FRAME_TIME, self.anim_step)
    end
    if widget then UIManager:setDirty(self, done and "ui" or "fast", widget:region(anim.cells)) end
end

--- Animates a shot's result (event "result" on the target board, "incoming" on ours).
function GameScreen:animateShot(board, ev)
    if not game.animations then return end
    local m = game.match
    local kind = ev.result == "miss" and "miss" or ev.result == "hit" and "hit" or "sunk"
    local cells, ship = { { ev.x, ev.y } }, nil
    if kind == "sunk" then
        local where = board == "target" and m.target or m.board
        local i = where:ship_at(ev.x, ev.y)
        if not i then return end
        ship = where.ships[i]
        cells = Board.cells(ship)
    end
    self:animate(board, kind, cells, ship)
end

function GameScreen:onCloseWidget()
    self:stopAnimation()
end

function GameScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:build()
end

function GameScreen:statusText()
    local m = game.match
    local lines = {}
    if game.message then lines[#lines + 1] = game.message end
    if game.lost then
        -- message says why
    elseif m.phase == "placing" then
        if not m.ready then
            if not self.selected then
                lines[#lines + 1] = _("Place your ships: tap a ship to select it, tap it again to turn it, tap the water to move it there.")
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
        if m.pending then lines[#lines + 1] = _("Firing…")
        elseif m.turn == "me" then lines[#lines + 1] = _("Your turn: tap a square on the opponent's board.")
        else lines[#lines + 1] = T(_("%1 is aiming…"), m.peer) end
    else
        lines[#lines + 1] = m.winner == "me" and _("You won!") or T(_("%1 won."), m.peer)
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
    if game.lost then return { close } end
    if m.phase == "placing" then
        return {
            { text = _("Random"), enabled = not m.ready, callback = function()
                m.board:randomize()
                self.selected = nil
                self:update()
            end },
            { text = _("Ready"), enabled = not m.ready, callback = function()
                self.selected = nil
                local ev = m:set_ready()
                if ev then Battleships.onGameEvent(ev) else self:update() end
            end },
        }
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

function GameScreen:onTargetTap(x, y)
    local m = game.match
    if m:fire(x, y) then self:update() end
end

function GameScreen:build()
    local w, h = self.dimen.w, self.dimen.h
    local m = game.match
    local pad = Size.padding.large
    local inner_w = w - 2 * pad
    self.title_bar = TitleBar:new{
        width = w,
        fullscreen = true,
        title = _("Battleships"),
        subtitle = m.peer and T(_("Opponent: %1"), m.peer) or nil,
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
    local row = self:buttonRow()
    local buttons = row and ButtonTable:new{ width = inner_w, buttons = { row }, show_parent = self }
    local used = self.title_bar:getSize().h + status:getSize().h + 3 * pad
        + (buttons and buttons:getSize().h + pad or 0)
    local avail_h = h - used

    local boards
    if m.phase == "placing" then
        boards = BoardWidget:new{
            size = math.min(inner_w, avail_h),
            mode = "own", board = m.board, selected = self.selected,
            on_tap = not m.ready and function(x, y) self:onOwnTap(x, y) end or nil,
        }
        self.board_widgets = { own = boards }
    else
        local face = Font:getFace("cfont", 16)
        local label_target = TextWidget:new{ text = _("Opponent's board"), face = face }
        local label_own = TextWidget:new{ text = _("Your board"), face = face }
        local label_h = label_target:getSize().h
        local target_size, own_size
        local landscape = w > h
        if landscape then
            target_size = math.min(math.floor((inner_w - pad) * 0.58), avail_h - label_h)
            own_size = math.min(inner_w - pad - target_size, avail_h - label_h)
        else
            local h2 = avail_h - 2 * label_h - pad
            target_size = math.min(inner_w, math.floor(h2 * 0.6))
            own_size = math.min(inner_w, h2 - target_size)
        end
        local anim = self.anim
        local target = BoardWidget:new{
            size = target_size, mode = "target", target = m.target, last = m.last_fired,
            anim = anim and anim.board == "target" and anim or nil,
            on_tap = m.phase == "battle" and not game.lost and function(x, y) self:onTargetTap(x, y) end or nil,
        }
        local own = BoardWidget:new{
            size = own_size, mode = "own", board = m.board, last = m.last_incoming,
            anim = anim and anim.board == "own" and anim or nil,
        }
        self.board_widgets = { target = target, own = own }
        local group = landscape and HorizontalGroup or VerticalGroup
        boards = group:new{
            align = landscape and "top" or "center",
            VerticalGroup:new{ align = "center", label_target, target },
            landscape and HorizontalSpan:new{ width = pad } or VerticalSpan:new{ width = pad },
            VerticalGroup:new{ align = "center", label_own, own },
        }
    end

    local content = VerticalGroup:new{
        align = "center",
        self.title_bar,
        VerticalSpan:new{ width = pad },
        status,
        VerticalSpan:new{ width = pad },
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

function GameScreen:update()
    self:build()
    UIManager:setDirty(self, "ui")
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
}

function Battleships.endGame()
    if game.conn then
        if game.match and game.match.peer then game.match:bye() end
        game.conn:close()
    end
    if game.host then game.host:close() end
    if game.zmq then
        UIManager:removeZMQ(game.zmq)
        UIManager:allowStandby()
    end
    kindle_firewall("-D", game.rules)
    local screen = game.screen
    game = {}
    -- the screen covers everything: without a refresh type the display would keep showing it
    if screen then UIManager:close(screen, "full") end
end

--- The connection ended: `reason` = "left" (BYE), an ERRORS key, or a socket error.
local function connection_lost(reason)
    if game.conn then game.conn:close() end
    game.conn = nil
    local m = game.match
    local who = m.peer or _("The opponent")
    if game.role == "host" and m.phase == "placing" and not ERRORS[reason] then
        -- the battle hasn't started: wait for someone else
        if m.peer then game.message = T(_("%1 left."), who) end
        m:drop_peer()
    else
        game.lost = true
        if ERRORS[reason] then game.message = ERRORS[reason]
        elseif reason == "left" then game.message = T(_("%1 left the game."), who)
        else game.message = m.peer and T(_("Connection to %1 lost."), who) or _("Connection lost.") end
        if game.host then game.host:close(); game.host = nil end
    end
    if game.screen then game.screen:update() end
end

local RESULT_TEXT = {
    miss = _("%1: miss."),
    hit = _("%1: hit! Fire again."),
    sunk = _("%1: hit and sunk! Fire again."),
    won = _("%1: hit and sunk!"),
}

local INCOMING_TEXT = {
    miss = _("%1 fired at %2: miss."),
    hit = _("%1 fired at %2: hit."),
    sunk = _("%1 fired at %2: your ship is sunk."),
    won = _("%1 fired at %2: your last ship is sunk."),
}

--- Updates the screen after a match event (see battleshipswifi/match.lua).
function Battleships.onGameEvent(ev)
    local m = game.match
    local t = ev.type
    if t == "joined" then
        game.message = game.role == "host" and T(_("%1 joined the game."), ev.name)
            or T(_("You joined %1's game. Fleet: %2."), ev.name, FLEET_NAMES[m.fleet])
        if ev.fleet_changed and game.screen then game.screen.selected = nil end
    elseif t == "peer_ready" then
        game.message = T(_("%1 is ready."), m.peer)
    elseif t == "start" then
        game.message = ev.turn == "me" and _("The battle begins. You fire first.")
            or T(_("The battle begins. %1 fires first."), m.peer)
    elseif t == "result" then
        game.message = T(RESULT_TEXT[ev.result], Board.label(ev.x, ev.y))
        if game.screen then game.screen:animateShot("target", ev) end
    elseif t == "incoming" then
        game.message = T(INCOMING_TEXT[ev.result], m.peer, Board.label(ev.x, ev.y))
        if game.screen then game.screen:animateShot("own", ev) end
    elseif t == "rematch" then
        game.message = _("New game: place your ships.")
        if game.screen then
            game.screen.selected = nil
            game.screen:stopAnimation()
        end
    elseif t == "left" then
        connection_lost("left")
        return
    end
    if game.screen then game.screen:update() end
end

local function poll_game()
    local t = now()
    if game.host then
        local client = game.host:accept()
        if client then
            if game.conn then
                client:settimeout(1)
                client:send(Protocol.line("ERROR", "busy"))
                client:close()
            else
                game.conn = Net.connection(client, t)
                game.last_ping = t
            end
        end
        game.host:answer(not game.conn and game.match.name or nil, game.match.fleet)
    end
    local conn = game.conn
    if not conn then return end
    local lines, err = conn:poll(t)
    for _i, line in ipairs(lines or {}) do
        local ev, perr = game.match:receive(line)
        if perr then
            logger.warn("Battleships: protocol error", perr, line)
            if not ERRORS[perr] then conn:send(Protocol.line("ERROR", "protocol")) end
            connection_lost(perr)
            return
        end
        if ev then Battleships.onGameEvent(ev) end
        if game.conn ~= conn then return end -- the event ended the connection
    end
    if not lines then
        connection_lost(err)
    elseif t - conn.last_seen > PEER_TIMEOUT then
        connection_lost("timeout")
    elseif t - (game.last_ping or 0) >= PING_INTERVAL then
        game.last_ping = t
        game.match:ping()
    end
end

--- fields.fleet: the host's choice, or what the guest found in the game list.
function Battleships:startGame(role, fields)
    game = fields
    game.role = role
    game.animations = self:animationsOn()
    game.match = Match.new{
        role = role,
        name = self:playerName(),
        fleet = fields.fleet,
        send = function(line) if game.conn then game.conn:send(line) end end,
    }
    game.last_ping = now()
    game.zmq = poller(poll_game, "game")
    UIManager:preventStandby()
    game.screen = GameScreen:new{}
    UIManager:show(game.screen)
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
        self:startGame("host", { host = host, ip = Net.local_ip(socket), rules = rules, fleet = fleet })
    end)
end

--- fleet: the host's, when known from the game list (else WELCOME tells).
function Battleships:joinGame(ip, port, fleet)
    NetworkMgr:runWhenOnline(function()
        Battleships.endGame()
        local socket = require("socket")
        local rules = guest_rules(port)
        kindle_firewall("-A", rules)
        local msg = InfoMessage:new{ text = T(_("Connecting to %1…"), ip) }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local conn, err = Net.connect(socket, ip, port, CONNECT_TIMEOUT, now())
        UIManager:close(msg)
        if not conn then
            kindle_firewall("-D", rules)
            UIManager:show(InfoMessage:new{ text = T(_("Cannot connect to %1: %2"), ip, tostring(err)) })
            return
        end
        self:startGame("guest", { conn = conn, rules = rules, fleet = fleet })
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
        local name = g.name ~= "" and g.name or g.ip
        table.insert(items, {
            text = fleet and T(_("%1 (%2)"), name, FLEET_NAMES[fleet]) or name,
            mandatory = g.ip,
            callback = function()
                local ip, port = g.ip, g.port
                UIManager:close(finder.menu)
                self:joinGame(ip, port, fleet)
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
    if self.settings:readSetting("name") == nil then
        -- before 0.2.0 the plugin was called battleships: keep the name and the last address
        local old = LuaSettings:open(DataStorage:getSettingsDir() .. "/battleships.lua")
        for _i, key in ipairs({ "name", "last_address" }) do
            if old:readSetting(key) ~= nil then self.settings:saveSetting(key, old:readSetting(key)) end
        end
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

Both devices must be on the same Wi-Fi network. One player hosts the game, the other finds it in Find a game or joins by the address shown on the host's screen.]]),
    })
end

function Battleships:mainMenu()
    return {
        { text = _("Host a game"), battleshipswifi_item = "host", sub_item_table_func = function()
            local items = {}
            for _i, fleet in ipairs(Board.FLEET_ORDER) do
                table.insert(items, {
                    text = FLEET_NAMES[fleet],
                    battleshipswifi_item = "host_" .. fleet,
                    callback = function() self:hostGame(fleet) end,
                })
            end
            return items
        end },
        { text = _("Find a game"), battleshipswifi_item = "find", callback = function() self:findGames() end },
        { text = _("Join by address…"), battleshipswifi_item = "join", callback = function() self:joinByAddress() end,
            separator = true },
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
    -- Wi-Fi goes off while the device sleeps: leave instead of timing out.
    stop_finder()
    Battleships.endGame()
end

function Battleships:onExit()
    stop_finder()
    Battleships.endGame()
end

return Battleships
