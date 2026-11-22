-- Smoke test of main.lua against stubbed KOReader modules and fake sockets.
-- Run from the repo root:  luajit tests/smoke.lua
package.path = "./?.lua;" .. package.path

local tmp = os.getenv("TMPDIR") or "/tmp"
local root = tmp .. "/battleships-smoke-" .. os.time()
os.execute("mkdir -p " .. root .. "/settings")

local shown, notes, toasts = {}, {}, {}
local function stub(name, mod) package.preload[name] = function() return mod end end
local function class(t)
    t = t or {}
    t.extend = function(self, o) o = o or {}; setmetatable(o, { __index = self }); o.extend = t.extend; o.new = t.new; return o end
    t.new = function(self, o)
        o = o or {}
        setmetatable(o, { __index = self })
        if o._init then o:_init() end
        if o.init then o:init() end
        return o
    end
    return t
end
local function sized(h) return class({ getSize = function() return { w = 100, h = h } end, free = function() end }) end

stub("gettext", setmetatable({ current_lang = "C" }, { __call = function(_, s) return s end }))
stub("ffi/util", { template = function(s, ...)
    local a = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
end })
-- a buffer that takes any painting call; counts them in `calls`
-- painting calls with fractional coordinates (they scatter pixels on 32-bit LuaJIT)
local fractional = {}
local function fake_bb()
    local bb = { calls = 0 }
    return setmetatable(bb, { __index = function(t, k)
        if k == "getType" then return function() return 1 end end
        return function(_self, ...)
            t.calls = t.calls + 1
            if k:match("^paint") or k == "blitFrom" then
                for i, v in ipairs({ ... }) do
                    if type(v) == "number" and v % 1 ~= 0 then
                        fractional[#fractional + 1] = k .. " arg " .. i .. " = " .. v
                    end
                end
            end
        end
    end })
end
local screen_bb = fake_bb()
stub("ffi/blitbuffer", setmetatable({ new = function() return fake_bb() end }, { __index = function(_, k) return k end }))
stub("datastorage", { getSettingsDir = function() return root .. "/settings" end })
stub("logger", { warn = print, info = function() end, dbg = function() end })
local kindle = false
local dpad = true
stub("device", {
    model = "Kindle Test",
    isKindle = function() return kindle end,
    hasKeys = function() return true end,
    hasDPad = function() return dpad end,
    input = { group = { Back = "Back", PgFwd = "PgFwd", PgBack = "PgBack" } },
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end, bb = screen_bb },
})
stub("ui/font", { getFace = function(_, name, size) return { name = name, size = size } end })
stub("ui/geometry", { new = function(_, o) return o end })
stub("ui/gesturerange", class())
stub("ui/size", { padding = { large = 10, default = 5 }, line = { thin = 1 } })
stub("ui/widget/container/widgetcontainer", class())
stub("ui/widget/container/inputcontainer", class({
    _init = function(self) self.key_events = self.key_events or {}; self.ges_events = self.ges_events or {} end,
}))
stub("ui/widget/container/framecontainer", class())
stub("ui/widget/verticalgroup", class())
stub("ui/widget/horizontalgroup", class())
stub("ui/widget/verticalspan", class())
stub("ui/widget/horizontalspan", class())
stub("ui/widget/titlebar", sized(50))
stub("ui/widget/textboxwidget", sized(40))
stub("ui/widget/buttontable", sized(45))
stub("ui/widget/buttondialog", class())
local TextWidget = sized(20)
TextWidget.getFontSizeToFitHeight = function(_, _name, h) return h end
TextWidget.paintTo = function() end
stub("ui/widget/textwidget", TextWidget)
stub("ui/widget/infomessage", class({ init = function(self) table.insert(notes, self.text) end }))
stub("ui/widget/confirmbox", class())
local dialogs = {}
stub("ui/widget/inputdialog", class({
    init = function(self) table.insert(dialogs, self) end,
    onShowKeyboard = function() end,
    getInputText = function(self) return self.text_value or self.input end,
}))
local menus = {}
stub("ui/widget/menu", class({
    init = function(self) table.insert(menus, self) end,
    switchItemTable = function(self, _title, items) self.item_table = items end,
}))
stub("ui/widget/notification", { notify = function(_, text) table.insert(toasts, text) end })
stub("ui/network/manager", { runWhenOnline = function(_, cb) cb() end })
local clock = 0
stub("ui/time", { now = function() return clock end, to_s = function(t) return t end })
local zmqs, standby, closed = {}, 0, {}
local last_close_refresh
local tasks, dirty = {}, {}
local vsyncs, top_widget = 0, nil
-- runs the scheduled tasks (animation frames)
local function run_tasks()
    local n = 0
    while #tasks > 0 and n < 50 do
        n = n + 1
        table.remove(tasks, 1)()
    end
    return n
end
stub("ui/uimanager", {
    scheduleIn = function(_, _s, fn) table.insert(tasks, fn) end,
    unschedule = function(_, fn) for i = #tasks, 1, -1 do if tasks[i] == fn then table.remove(tasks, i) end end end,
    show = function(_, w) table.insert(shown, w) end,
    close = function(_, w, refresh)
        last_close_refresh = refresh
        table.insert(closed, w)
        if w and w.onCloseWidget then w:onCloseWidget() end
    end,
    forceRePaint = function() end,
    waitForVSync = function() vsyncs = vsyncs + 1 end,
    getTopmostVisibleWidget = function() return top_widget or shown[#shown] end,
    setDirty = function(_, w, kind, region) table.insert(dirty, { w = w, kind = kind, region = region }) end,
    insertZMQ = function(_, z) table.insert(zmqs, z); return z end,
    removeZMQ = function(_, z) for i = #zmqs, 1, -1 do if zmqs[i] == z then table.remove(zmqs, i) end end end,
    preventStandby = function() standby = standby + 1 end,
    allowStandby = function() standby = standby - 1 end,
})
local stores = {} -- settings file → data
stub("luasettings", { open = function(_, path)
    stores[path] = stores[path] or {}
    local data = stores[path]
    return {
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        delSetting = function(_, k) data[k] = nil end,
        flush = function() end,
    }
end })

-- Fake LuaSocket ----------------------------------------------------------------
local function fake_tcp(incoming)
    local s = { sent = "", incoming = incoming or {}, closed = false }
    function s:settimeout() end
    function s:setoption() return true end
    function s:send(data) self.sent = self.sent .. data; return #data end
    function s:receive()
        local chunk = table.remove(self.incoming, 1)
        if chunk == "CLOSE" then return nil, "closed", "" end
        return nil, "timeout", chunk or ""
    end
    function s:close() self.closed = true end
    return s
end
local udps, pending_clients, bind_error = {}, {}, nil
-- the newest UDP socket bound to `port`
local function udp_on(port)
    for i = #udps, 1, -1 do if udps[i].port == port then return udps[i] end end
end
local connect_to
local function fake_udp()
    local u = { out = {}, inbox = {} }
    function u:setsockname(_h, port) self.port = port; return true end
    function u:setpeername() end
    function u:getsockname() return "192.168.1.20" end
    function u:settimeout() end
    function u:setoption() return true end
    function u:sendto(msg, ip, port) table.insert(self.out, { msg, ip, port }) end
    function u:receivefrom()
        local m = table.remove(self.inbox, 1)
        if not m then return nil, "timeout" end
        return m[1], m[2], m[3]
    end
    function u:close() self.closed = true end
    return u
end
local tcps = {}
stub("socket", {
    udp = function() local u = fake_udp(); table.insert(udps, u); return u end,
    tcp = function()
        local s = fake_tcp()
        function s:connect(host, port)
            connect_to = host .. ":" .. port
            if host == "10.0.0.66" then return nil, "connection refused" end
            return 1
        end
        table.insert(tcps, s)
        return s
    end,
    bind = function()
        if bind_error then return nil, bind_error end
        local s = fake_tcp()
        s.accept = function() return table.remove(pending_clients, 1) end
        return s
    end,
})

local passed, failed = 0, 0
local function eq(actual, expected, name)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL %s\n  expected: %q\n  actual:   %q"):format(name, tostring(expected), tostring(actual)))
    end
end

local function tick(n)
    for _i = 1, n or 1 do
        for _j, z in ipairs({ unpack(zmqs) }) do eq(z.waitEvent(z), nil, "waitEvent returns nil") end
    end
end

-- Finds widgets in the screen's tree.
local function find_all(w, pred, out)
    out = out or {}
    if type(w) ~= "table" then return out end
    if pred(w) then table.insert(out, w) end
    for _i, child in ipairs(w) do find_all(child, pred, out) end
    return out
end
local function boards(screen) return find_all(screen, function(w) return w.cell ~= nil end) end
local function buttons(screen)
    local tables = find_all(screen, function(w) return w.buttons ~= nil end)
    local out = {}
    for _i, b in ipairs(tables[1] and tables[1].buttons[1] or {}) do out[b.text] = b end
    return out
end
local function paint(board)
    local bb = fake_bb()
    board:paintTo(bb, 5, 7)
    return bb.calls
end

local Battleships = dofile("main.lua")
local plugin = Battleships:new{ ui = { menu = { registerToMainMenu = function() end } } }
local menu_items = {}
plugin:addToMainMenu(menu_items)
eq(menu_items.battleshipswifi.text, "Battleships (Wi-Fi)", "main menu entry")
local function by_id(items, id)
    for _i, it in ipairs(items) do
        if it.battleshipswifi_item == id then return it end
    end
end
local function item(id) -- also in plain submenus (Settings)
    local function search(items)
        for _i, it in ipairs(items) do
            if it.battleshipswifi_item == id then return it end
            local found = it.sub_item_table and search(it.sub_item_table)
            if found then return found end
        end
    end
    return search(menu_items.battleshipswifi.sub_item_table_func())
end
do
    local ids = {}
    for _i, it in ipairs(menu_items.battleshipswifi.sub_item_table_func()) do ids[#ids + 1] = it.battleshipswifi_item end
    eq(table.concat(ids, " "), "ai host find settings rules", "menu order")
    eq(by_id(item("settings").sub_item_table, "name") ~= nil and by_id(item("settings").sub_item_table, "animations") ~= nil,
        true, "name and animations under Settings")
end
eq(item("name").text_func(), "Your name: Kindle Test", "default name is the device model")
local host_items = item("host").sub_item_table_func()
eq(host_items[1].text .. "|" .. host_items[2].text_func(), "Start game|Ships: Classic ships", "Start game, then the fleet")
do
    local fleets = by_id(host_items, "fleet").sub_item_table
    eq(fleets[1].text .. "|" .. fleets[2].text, "Classic ships|Shaped ships", "fleets to pick")
    eq(fleets[1].checked_func() and fleets[1].radio and not fleets[2].checked_func(), true, "radio items, classic by default")
end
item("name").callback({ updateItems = function() end })
dialogs[#dialogs].text_value = "  Martin\n "
dialogs[#dialogs].buttons[1][2].callback()
eq(item("name").text_func(), "Your name: Martin", "name saved, cleaned")
item("rules").callback()
eq(notes[#notes]:match("^The host picks the fleet") ~= nil, true, "rules shown")

-- Hosting ------------------------------------------------------------------------
bind_error = "address already in use"
item("host").sub_item_table_func()[1].callback()
eq(notes[#notes], "Cannot host a game: address already in use", "port taken")
eq(#zmqs, 0, "nothing polled after a failed host")
bind_error = nil

kindle = true
local executed = {}
local real_execute = os.execute
os.execute = function(cmd) table.insert(executed, cmd) end
item("host").sub_item_table_func()[1].callback()
os.execute = real_execute
eq(#executed, 4, "Kindle firewall opened for TCP and discovery")
local screen = shown[#shown]
eq(screen.covers_fullscreen, true, "game screen shown")
eq(#zmqs, 1, "game polled")
eq(standby, 1, "standby prevented")
eq(screen.title_bar.title, "Battleships", "no opponent yet")
local status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("Your address: 192.168.1.20") ~= nil, true, "host address shown")
eq(#boards(screen), 1, "one board while placing")
eq(paint(boards(screen)[1]) > 30, true, "board painted")
do
    local bw = boards(screen)[1]
    eq(bw:getSize().w, 11 * bw.cell + 2 * bw.line, "the board's size includes the outer grid line")
    eq(bw:getSize().w <= bw.size, true, "and stays within the size it was given")
end

-- discovery answered while waiting
local hudp = udp_on(7532)
hudp.inbox = { { "DISCOVER 4", "192.168.1.30", 7533 } }
tick()
eq(hudp.out[1] and hudp.out[1][1], "GAME 4 7531 classic 10 Martin", "discovery answered")

-- placing: select, rotate, move
local game_board = boards(screen)[1].board
local s1 = game_board.ships[1]
local before = s1.dir
screen:onOwnTap(s1.x, s1.y)
eq(screen.selected, 1, "tap selects a ship")
eq(boards(screen)[1].blocked ~= nil and paint(boards(screen)[1]) > 30, true, "squares without room computed and painted")
local hint = screen:statusText()
eq(hint:find("Shaded squares have no room", 1, true) ~= nil, true, "status explains the shading: " .. hint)
screen:onOwnTap(s1.x, s1.y)
local after = game_board.ships[1].dir
eq(after ~= before or #toasts > 0, true, "second tap turns it (or explains why not)")
buttons(screen)["Random"].callback()
eq(screen.selected, nil, "Random clears the selection")

-- a guest joins
local client = fake_tcp({ "HELLO 4 Guest\n" })
table.insert(pending_clients, client)
tick(2)
eq(client.sent:match("^WELCOME 4 classic 10 Martin\n") ~= nil, true, "host welcomes the guest")
eq(screen.title_bar.title, "Battleships · Opponent: Guest", "opponent shown")
-- a third device is turned away
local extra = fake_tcp()
table.insert(pending_clients, extra)
tick()
eq(extra.sent .. tostring(extra.closed), "ERROR busy\ntrue", "second guest refused")

buttons(screen)["Ready"].callback()
eq(client.sent:match("READY\n$") ~= nil, true, "READY sent")
eq(buttons(screen)["Ready"].enabled, false, "Ready only once")
client.incoming = { "READY\n" }
tick()
eq(client.sent:match("START %a+\n$") ~= nil, true, "START sent when both are ready")
eq(#boards(screen), 2, "two boards in the battle")
for _i, bw in ipairs(boards(screen)) do paint(bw) end

-- make it our turn: if the guest starts, it misses
eq(boards(screen)[1].mode, "target", "the opponent's board comes first")
if client.sent:match("START guest\n$") then
    local own = boards(screen)[2].board
    local free
    for y = 0, 9 do for x = 0, 9 do if not free and not own:ship_at(x, y) then free = { x, y } end end end
    client.incoming = { ("SHOT %d %d\n"):format(free[1], free[2]) }
    tick()
    eq(client.sent:match("RESULT %d+ %d+ miss\n$") ~= nil, true, "opponent's miss answered")
end
-- refreshes requested by one update: "kind" or "kind@w" for a region, lambdas run as after painting
local function refreshes()
    local out = {}
    for _i, d in ipairs(dirty) do
        local kind, region = d.kind, d.region
        if type(kind) == "function" then kind, region = kind() end
        out[#out + 1] = region and (kind .. "@" .. region.w) or kind
    end
    return table.concat(out, " ")
end
dirty = {}
boards(screen)[1].on_tap(3, 4)
eq(client.sent:match("SHOT 3 4\n$") ~= nil, true, "tap fires")
eq(screen.anim and screen.anim.kind, "shell", "our shell shown at once")
paint(boards(screen)[1])
local cw = 3 * boards(screen)[1].cell + 2 * boards(screen)[1].line
eq(refreshes(), "ui@600 fast@" .. cw, "tap: status line and the square's surroundings, not the whole screen")
dirty = {}
client.incoming = { "RESULT 3 4 hit\n" }
tick()
paint(boards(screen)[1])
eq(refreshes(), "ui@600 fast@" .. cw, "result: the same, no full refresh")
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("^D5: hit! Fire again.") ~= nil, true, "result shown")
eq(screen.anim and screen.anim.kind, "hit", "hit animated")
eq(boards(screen)[1].anim, screen.anim, "on the opponent's board")
-- the next shot comes before this animation ends: its squares still get cleaned up
do
    local running = screen.anim
    dirty = {}
    screen:animate("own", "miss", { { 0, 0 } })
    local cleaned = false
    for _i, d in ipairs(dirty) do if d.kind == "partial" then cleaned = true end end
    eq(cleaned, true, "an interrupted animation gets its clean-up refresh")
    -- (put the hit back for the checks below)
    screen:stopAnimation()
    screen.anim = running
    screen.anim_step = function() screen:animationStep() end
    tasks = { screen.anim_step }
    boards(screen)[1].anim = running
end
paint(boards(screen)[1])
dirty = {}
local blits = screen_bb.calls
vsyncs = 0
eq(screen.anim.frame, 2, "the hit goes on after the shell")
-- every frame of every animation paints at whole pixels
do
    local bw = boards(screen)[1]
    local ship = { x = 5, y = 1, shape = "line3", rot = 0, hits = 0 }
    local kinds = { shell = { { 0, 0 } }, miss = { { 9, 9 } }, hit = { { 4, 4 } }, sunk = { { 5, 1 }, { 6, 1 }, { 7, 1 } } }
    local saved = bw.anim
    fractional = {}
    for kind, cells in pairs(kinds) do
        local set = {}
        for _i, c in ipairs(cells) do set[c[2] * 10 + c[1]] = true end
        local frames = ({ shell = 1, miss = 6, hit = 5, sunk = 6 })[kind]
        for f = 1, frames do
            bw.anim = { kind = kind, cells = cells, set = set, ship = ship, frame = f }
            paint(bw)
        end
    end
    bw.anim = saved
    paint(bw)
    eq(#fractional .. " " .. (fractional[1] or ""), "0 ", "no fractional coordinates in painting calls")
end
eq(run_tasks(), 4, "three more frames and the cleanup")
eq(vsyncs, 4, "every frame waits for the previous refresh")
eq(screen_bb.calls - blits, 4, "every frame: one copy of the region to the screen")
eq(dirty[1].w, nil, "frames don't repaint the whole game screen")
local kinds = {}
for _i, d in ipairs(dirty) do kinds[#kinds + 1] = d.kind end
eq(table.concat(kinds, " "), "fast fast fast partial", "fast refreshes, then a clean-up one")
eq(dirty[1].region.w, 3 * boards(screen)[1].cell + 2 * boards(screen)[1].line, "only the square and its neighbours are refreshed")
eq(screen.anim, nil, "animation over")
eq(boards(screen)[1].anim, nil, "board drawn as usual")
-- a sunk ship: every square blasts
eq(screen.fleet_view:sunkCount(), 0, "overview: nothing sunk yet")
boards(screen)[1].on_tap(4, 4)
dirty = {}
client.incoming = { "RESULT 4 4 sunk 3,4,line2,0\n" }
tick()
eq(screen.anim and screen.anim.kind .. #screen.anim.cells, "sunk2", "sunk ship animated on all its squares")
eq(screen:statusText():match("^E5: hit, the destroyer goes down! Fire again.") ~= nil, true,
    "the sunk ship named: " .. screen:statusText())
local fv = screen.fleet_view
eq(table.concat({ tostring(fv.sunk[1]), tostring(fv.sunk[5]) }, " "), "false true", "overview: the 2-square ship struck through")
eq(refreshes():find("ui@" .. fv.dimen.w, 1, true) ~= nil, true, "overview refreshed after the sunk ship: " .. refreshes())
eq(fv.dimen.w <= boards(screen)[1].dimen.w, true, "overview no wider than the board")
paint(boards(screen)[1])
eq(run_tasks(), 5, "sunk (2 squares): blasts in 2 steps, blow-up, 2 sinking frames, cleanup")
-- animations off
item("animations").callback()
eq(item("animations").checked_func(), false, "animations switched off")
boards(screen)[1].on_tap(0, 0)
client.incoming = { "RESULT 0 0 miss\n" }
tick()
eq(screen.anim, nil, "no animation when off")
item("animations").callback()
eq(item("animations").checked_func(), true, "animations back on")
eq(boards(screen)[1].last[1] .. boards(screen)[1].last[2], "00", "last shot outlined")
-- a dialog over the game: no frames over it
-- a miss: ours if it's our turn, else the opponent's on our board
local expect
if screen:statusText():find("Your turn", 1, true) then
    local target = boards(screen)[1].target
    local free
    for y = 9, 0, -1 do for x = 9, 0, -1 do if not free and target:can_fire(x, y) then free = { x, y } end end end
    boards(screen)[1].on_tap(free[1], free[2])
    client.incoming = { ("RESULT %d %d miss\n"):format(free[1], free[2]) }
    expect = "target miss"
else
    local own_board = boards(screen)[2].board
    local water
    for y = 9, 0, -1 do for x = 9, 0, -1 do
        if not water and not own_board:ship_at(x, y) and not own_board.shots[y][x] then water = { x, y } end
    end end
    client.incoming = { ("SHOT %d %d\n"):format(water[1], water[2]) }
    expect = "own miss"
end
tick()
eq(screen.anim and screen.anim.board .. " " .. screen.anim.kind, expect, "miss animated")
top_widget = {}
dirty = {}
eq(run_tasks(), 1, "covered: the animation stops")
eq(dirty[1].w == screen and dirty[1].kind == "partial", true, "and the game screen is refreshed normally")
eq(screen.anim, nil, "no animation left")
top_widget = nil

-- the opponent leaves
client.incoming = { "BYE\n" }
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status, "Guest left the game.", "opponent left")
eq(buttons(screen)["Close"] ~= nil, true, "only Close left")
eq(boards(screen)[1].on_tap, nil, "no more shots")
executed = {}
os.execute = function(cmd) table.insert(executed, cmd) end
buttons(screen)["Close"].callback()
os.execute = real_execute
kindle = false
eq(#executed == 4 and executed[1]:match("^iptables %-D") ~= nil, true, "firewall closed")
eq(#zmqs .. " " .. standby, "0 0", "polling and standby released")
eq(closed[#closed], screen, "screen closed")
eq(last_close_refresh, "full", "screen below refreshed")

-- Host: a guest leaving before the battle frees the seat ------------------------
item("host").sub_item_table_func()[1].callback()
screen = shown[#shown]
client = fake_tcp({ "HELLO 4 Guest\n" })
table.insert(pending_clients, client)
tick(2)
client.incoming = { "CLOSE" }
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("^Guest left.") ~= nil, true, "guest left before the battle")
eq(screen.title_bar.title, "Battleships", "waiting for another opponent")
hudp = udp_on(7532)
hudp.inbox = { { "DISCOVER 4", "192.168.1.31", 7533 } }
tick()
eq(#hudp.out, 1, "discovery answered again")
client = fake_tcp({ "HELLO 4 Second\n" })
table.insert(pending_clients, client)
tick(2)
eq(screen.title_bar.title, "Battleships · Opponent: Second", "another guest joins")
-- silence → timeout
clock = clock + 31
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status, "Second left.\nPlace your ships: drag them, or tap a ship to select it, tap it again to turn it, tap the water to move it there.\nWaiting for an opponent. Your address: 192.168.1.20",
    "timeout before the battle: wait again")
-- protocol error
client = fake_tcp({ "HELLO 1 Old\n" })
table.insert(pending_clients, client)
tick(2)
eq(client.sent, "ERROR version\n", "old version refused")
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("^The other device has a different version") ~= nil, true, "version error shown")
screen:onClose()
eq(#zmqs, 0, "game ended")

-- Resuming after a lost connection (host) -----------------------------------------
local function status_of(sc) return sc:statusText() end
item("host").sub_item_table_func()[1].callback()
screen = shown[#shown]
client = fake_tcp({ "HELLO 4 Guest\n" })
table.insert(pending_clients, client)
tick(2)
local session = client.sent:match("SESSION (%w+)\n")
eq(session ~= nil, true, "the host sends its session")
client.incoming = { "SESSION " .. session .. "\nREADY\n" }
buttons(screen)["Ready"].callback()
tick()
eq(#boards(screen), 2, "battle (resumable guest)")
-- the guest's connection drops
client.incoming = { "CLOSE" }
tick()
eq(status_of(screen), "Connection to Guest lost.\nWaiting for Guest to come back…", "host waits for the guest")
eq(buttons(screen)["Close"] ~= nil and boards(screen)[1].on_tap == nil, true, "only Close, no shots while waiting")
hudp = udp_on(7532)
hudp.inbox = { { "DISCOVER 4", "192.168.1.31", 7533 } }
tick()
eq(hudp.out[#hudp.out][1], "RESUMEGAME 4 7531 " .. session, "searches answered with the session")
-- a stranger is turned away, the host keeps waiting
local stranger = fake_tcp({ "HELLO 4 Stranger\n" })
table.insert(pending_clients, stranger)
tick(2)
eq(stranger.sent .. tostring(stranger.closed), "ERROR busy\ntrue", "a stranger is turned away")
eq(status_of(screen):find("Waiting for Guest to come back", 1, true) ~= nil, true, "still waiting")
-- the guest comes back
local back = fake_tcp({ "RESUME 4 " .. session .. " 2 Guest\n" })
table.insert(pending_clients, back)
tick(2)
eq(back.sent:match("^RESUMED 4 %d+\n") ~= nil, true, "host answers RESUMED")
eq(status_of(screen):match("^Connection to Guest restored.") ~= nil, true, "restored: " .. status_of(screen))
eq(boards(screen)[1].on_tap ~= nil or status_of(screen):find("aiming", 1, true) ~= nil, true, "the game goes on")
-- the guest comes back over a new connection before the host noticed the old one was gone
local again = fake_tcp({ "RESUME 4 " .. session .. " 2 Guest\n" })
table.insert(pending_clients, again)
tick(3)
eq(back.closed, true, "the old connection is dropped")
eq(again.sent:match("^RESUMED 4") ~= nil, true, "and the new one goes on")
-- going to sleep keeps the game; waking up listens again
local binds_before = #udps
plugin:onSuspend()
eq(#zmqs, 1, "asleep: the game is kept")
eq(again.closed and not again.sent:find("BYE", 1, true), true, "the connection closed without BYE")
eq(status_of(screen), "Connection to Guest restored.\nWaiting for Guest to come back…", "waiting while asleep")
plugin:onResume()
tick()
eq(#udps > binds_before, true, "listening again after waking up")
local after = fake_tcp({ "RESUME 4 " .. session .. " 2 Guest\n" })
table.insert(pending_clients, after)
tick(2)
eq(status_of(screen):match("^Connection to Guest restored.") ~= nil and after.sent:match("^RESUMED") ~= nil, true,
    "the guest comes back after the host slept")
-- an unknown session is refused, the game keeps waiting for the right one
after.incoming = { "CLOSE" }
tick()
local wrong = fake_tcp({ "RESUME 4 othergame 0 Guest\n" })
table.insert(pending_clients, wrong)
tick(2)
eq(wrong.sent .. tostring(wrong.closed), "ERROR resume\ntrue", "RESUME of another game refused")
eq(status_of(screen):find("Waiting for Guest to come back", 1, true) ~= nil, true, "still waiting for the right one")
screen:onClose()
eq(shown[#shown].text, "Leave the game?", "leaving while waiting asks first")
shown[#shown].ok_callback()
eq(#zmqs, 0, "Close (and confirm) ends it")

-- Joining by address -----------------------------------------------------------
plugin:joinByAddress()
local dialog = dialogs[#dialogs]
dialog.text_value = "not an address!"
dialog.buttons[1][2].callback()
eq(toasts[#toasts], "Invalid address", "invalid address")
dialog.text_value = "10.0.0.66"
dialog.buttons[1][2].callback()
eq(notes[#notes], "Cannot connect to 10.0.0.66: connection refused", "connection refused")
eq(#zmqs, 0, "no game")
plugin:joinByAddress()
dialog = dialogs[#dialogs]
eq(dialog.input, "10.0.0.66", "last address remembered")
dialog.text_value = "10.0.0.9:7000"
dialog.buttons[1][2].callback()
eq(connect_to, "10.0.0.9:7000", "connects to the address")
local sock = tcps[#tcps]
eq(sock.sent, "HELLO 4 Martin\n", "guest says hello")
screen = shown[#shown]
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("Connecting…$") ~= nil, true, "guest waits for WELCOME")
sock.incoming = { "WELCOME 4 shapes 10 Host\n" }
tick()
eq(screen.title_bar.title, "Battleships · Opponent: Host", "guest joined")
eq(#boards(screen)[1].board.ships, 6, "guest places the host's shaped fleet")
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("^You joined Host's game: Shaped ships.") ~= nil, true, "fleet named: " .. status)
eq(paint(boards(screen)[1]) > 30, true, "shaped ships painted")
sock.incoming = { "READY\n" }
tick()
clock = clock + 6
tick()
eq(sock.sent:match("PING\n$") ~= nil, true, "keepalive")
sock.incoming = { "CLOSE" }
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status, "Connection to Host lost.", "guest: connection lost ends the game (old host, no SESSION)")
plugin:onSuspend()
eq(#zmqs .. " " .. standby, "0 0", "suspend ends the game")

-- Resuming after a lost connection (guest) ------------------------------------------
plugin:joinByAddress()
dialog = dialogs[#dialogs]
dialog.text_value = "10.0.0.9"
dialog.buttons[1][2].callback()
sock = tcps[#tcps]
screen = shown[#shown]
sock.incoming = { "WELCOME 4 classic 10 Host\nSESSION abc123\nREADY\n" }
tick()
eq(sock.sent:find("SESSION abc123\n", 1, true) ~= nil, true, "guest answers SESSION")
buttons(screen)["Ready"].callback()
sock.incoming = { "START host\n" }
tick()
eq(#boards(screen), 2, "guest in the battle")
sock.incoming = { "CLOSE" }
tick()
eq(status_of(screen), "Connection to Host lost.\nReconnecting to Host…", "guest reconnects")
local tcps_before = #tcps
tick()
eq(#tcps > tcps_before, true, "a new connection attempt")
local resock = tcps[#tcps]
tick()
eq(resock.sent:match("^RESUME 4 abc123 %d+ Martin\n") ~= nil, true, "guest asks to resume: " .. resock.sent)
resock.incoming = { "RESUMED 4 1\n" }
tick()
eq(status_of(screen):match("^Connection to Host restored.") ~= nil, true, "guest restored: " .. status_of(screen))
eq(udp_on(7533) == nil or udp_on(7533).closed, true, "the search for the host's address stopped")
-- the host still holds an earlier attempt: try again later
resock.incoming = { "CLOSE" }
tick(3)
tcps[#tcps].incoming = { "ERROR busy\n" }
tick()
eq(status_of(screen):find("Reconnecting to Host", 1, true) ~= nil, true, "busy while reconnecting: try again")
clock = clock + 4
tick(3)
-- the host has started another game meanwhile
local last = tcps[#tcps]
last.incoming = { "ERROR resume\n" }
tick()
eq(status_of(screen), "The game can no longer be resumed.", "guest gives up when the host refuses")
screen:onClose()
eq(#zmqs .. " " .. standby, "0 0", "ended")

-- Finding games ------------------------------------------------------------------
item("find").callback()
local menu = menus[#menus]
eq(menu.item_table[1].text, "Searching for games…", "searching")
eq(#zmqs, 1, "search polled")
local sudp = udp_on(7533)
tick()
eq(#sudp.out, 2, "DISCOVER broadcast")
sudp.inbox = { { "GAME 4 7531 shapes 10 Host", "192.168.1.40", 7532 } }
tick()
eq(menu.item_table[1].text .. " " .. menu.item_table[1].mandatory, "Host (Shaped ships) 192.168.1.40", "game listed with its fleet")
eq(menu.item_table[2].text, "Join by address…", "join by address below")
clock = clock + 10
tick()
eq(menu.item_table[1].text, "Searching for games…", "silent game dropped")
sudp.inbox = { { "GAME 4 7531 shapes 10 Host", "192.168.1.40", 7532 } }
tick()
menu.item_table[1].callback()
eq(sudp.closed, true, "search stopped when the list closes")
eq(connect_to, "192.168.1.40:7531", "joins the game found")
eq(#zmqs, 1, "only the game polled")
plugin:onExit()
eq(#zmqs .. " " .. standby, "0 0", "exit ends the game")

-- Playing against the e-reader ---------------------------------------------------
local ai_items = item("ai").sub_item_table_func()
eq(ai_items[1].text .. "|" .. by_id(ai_items, "fleet").text_func(), "Start game|Ships: Classic ships",
    "against the e-reader: Start game and the fleet")
eq(by_id(ai_items, "ai_level").text_func(), "Difficulty: Normal", "normal difficulty by default")
by_id(ai_items, "ai_level").sub_item_table[3].callback()
eq(by_id(item("ai").sub_item_table_func(), "ai_level").text_func(), "Difficulty: Hard", "difficulty saved")
local sockets_before = #tcps + #udps
by_id(ai_items, "fleet").sub_item_table[2].callback()
eq(by_id(item("host").sub_item_table_func(), "fleet").text_func(), "Ships: Shaped ships", "fleet saved, shared")
by_id(ai_items, "ai_start").callback()
screen = shown[#shown]
eq(#tcps + #udps, sockets_before, "no network")
eq(standby, 0, "the device may doze off against the e-reader")
tick()
eq(screen.title_bar.title, "Battleships · Opponent: E-reader", "the e-reader joins")
eq(screen:statusText():match("^You play against the e%-reader. Difficulty: Hard.") ~= nil, true,
    "difficulty shown: " .. screen:statusText())
eq(#boards(screen)[1].board.ships, 6, "shaped fleet")
buttons(screen)["Ready"].callback()
tick()
eq(#boards(screen), 2, "battle against the e-reader")
local over = false
for _step = 1, 800 do
    if buttons(screen)["Play again"] then over = true; break end
    if screen:statusText():find("Your turn", 1, true) then
        local target = boards(screen)[1].target
        local free
        for y = 0, 9 do for x = 0, 9 do if not free and target:can_fire(x, y) then free = { x, y } end end end
        boards(screen)[1].on_tap(free[1], free[2])
    end
    clock = clock + 0.5
    tick()
    run_tasks()
end
eq(over, true, "a whole game against the e-reader")
eq(screen:statusText():find("E-reader won.", 1, true) ~= nil or screen:statusText():find("You won!", 1, true) ~= nil,
    true, "winner shown: " .. screen:statusText())
eq(screen:statusText():match("You: %d+ of %d+ shots hit %(%d+ %%%), longest series %d+%.\nE%-reader: %d+ of %d+ shots hit")
    ~= nil, true, "numbers of both players after the game: " .. screen:statusText())
eq(screen:statusText():find("goes down", 1, true), nil, "the last shot's message makes room for them")
eq(screen.title_bar.title:match("^Battleships · Opponent: E%-reader · You %d : %d$") ~= nil, true,
    "score in the title: " .. screen.title_bar.title)
plugin:onSuspend()
eq(#zmqs, 1, "going to sleep keeps a game against the e-reader")
local score_before = screen.title_bar.title
buttons(screen)["Play again"].callback()
tick(2)
eq(#boards(screen), 1, "the e-reader plays again: placing")
eq(screen.title_bar.title, score_before, "the score stays for the next game")
plugin:onExit()
eq(#zmqs .. " " .. standby, "0 0", "exit ends it")

-- Rules picked in the menu, and key control ------------------------------------------
do
    local host_menu = item("host").sub_item_table_func()
    local size_item, salvo_item, touch_item = by_id(host_menu, "rules_size"), by_id(host_menu, "rules_salvo"),
        by_id(host_menu, "rules_touch")
    eq(size_item.checked_func() or salvo_item.checked_func() or touch_item.checked_func(), false, "classic rules by default")
    eq(by_id(item("ai").sub_item_table_func(), "rules_salvo") ~= nil, true, "the rules against the e-reader too")
    size_item.callback(); salvo_item.callback()
    eq(size_item.checked_func() and salvo_item.checked_func() and not touch_item.checked_func(), true, "12 × 12 and salvo on")
    by_id(host_menu, "fleet").sub_item_table[1].callback()
    by_id(host_menu, "host_start").callback()
    screen = shown[#shown]
    eq(boards(screen)[1].n .. " " .. boards(screen)[1].board.size, "12 12", "the host places on 12 × 12")
    hudp = udp_on(7532)
    hudp.inbox = { { "DISCOVER 4", "192.168.1.30", 7533 } }
    tick()
    eq(hudp.out[#hudp.out][1], "GAME 4 7531 classic 12s Martin", "the rules are announced")
    client = fake_tcp({ "HELLO 4 Guest\n" })
    table.insert(pending_clients, client)
    tick(2)
    eq(client.sent:match("^WELCOME 4 classic 12s Martin\n") ~= nil, true, "and sent in WELCOME")
    client.incoming = { "READY\n" }
    buttons(screen)["Ready"].callback()
    tick()
    eq(#boards(screen), 2, "salvo battle")
    if client.sent:match("START guest\n") then
        -- the guest's salvo: 5 misses
        local own = boards(screen)[2].board
        local n = 0
        for y = 0, 11 do for x = 0, 11 do
            if n < 5 and not own:ship_at(x, y) then
                client.incoming = { ("SHOT %d %d\n"):format(x, y) }
                tick()
                n = n + 1
            end
        end end
    end
    eq(screen:statusText():match("Shots left: 5%.$") ~= nil, true, "our salvo: 5 shots: " .. screen:statusText())
    -- keys: the cursor appears on the opponent's board and fires there
    dirty, vsyncs = {}, 0
    screen:onKeyMove({ 1, 0 })
    eq(screen.cursor ~= nil and dirty[#dirty].kind .. " " .. vsyncs, "fast 1", "a key shows the cursor (fast refresh)")
    eq(boards(screen)[1].cursor, screen.cursor, "on the opponent's board")
    paint(boards(screen)[1])
    local cx, cy = screen.cursor[1], screen.cursor[2]
    screen:onKeyMove({ -1, 0 })
    eq(screen.cursor[1], (cx - 1) % 12, "arrows move it (round the edge)")
    screen:onKeyAct()
    eq(client.sent:match(("SHOT %d %d\n$"):format(screen.cursor[1], screen.cursor[2])) ~= nil, true, "Press fires at the cursor")
    client.incoming = { ("RESULT %d %d miss\n"):format(screen.cursor[1], screen.cursor[2]) }
    tick()
    eq(screen:statusText():match("Your turn: 4 shots left%.$") ~= nil, true, "a salvo shot used, the short text: " .. screen:statusText())
    local fx, fy = screen.cursor[1], screen.cursor[2]
    screen:onKeyStep(1)
    eq(boards(screen)[1].target:can_fire(screen.cursor[1], screen.cursor[2]), true, "page keys step to a square not fired at")
    eq(screen.cursor[1] ~= fx or screen.cursor[2] ~= fy, true, "past the one fired at")
    -- Menu: the screen's buttons in a dialog
    local shown_before = #shown
    screen:onKeyMenu()
    eq(#shown, shown_before + 1, "Menu shows a dialog")
    eq(shown[#shown].buttons[#shown[#shown].buttons][1].text, "Close", "with Close at least")
    -- back to the classic rules for the rest
    size_item.callback(); salvo_item.callback()
    screen:onClose()
    if shown[#shown].ok_callback then shown[#shown].ok_callback() end
end

-- Placing: dragging and mirroring ------------------------------------------------
do
    local Board = require("battleshipswifi/board")
    by_id(item("ai").sub_item_table_func(), "fleet").sub_item_table[2].callback() -- shaped ships
    by_id(item("ai").sub_item_table_func(), "ai_start").callback()
    screen = shown[#shown]
    tick()
    local board = boards(screen)[1].board
    eq(buttons(screen)["Mirror"] ~= nil and buttons(screen)["Mirror"].enabled == false, true,
        "Mirror button (shaped ships), off without a selected ship")
    local di
    for i, sh in ipairs(board.ships) do if sh.shape == "destroyer" then di = i end end
    local dc = Board.cells(board.ships[di])[1]
    screen:onOwnTap(dc[1], dc[2])
    eq(screen.selected .. " " .. tostring(buttons(screen)["Mirror"].enabled), di .. " true", "a destroyer selected: Mirror on")
    local side = Board.rotations("destroyer")[board.ships[di].rot + 1].mirrored
    toasts = {}
    buttons(screen)["Mirror"].callback()
    eq(Board.rotations("destroyer")[board.ships[di].rot + 1].mirrored ~= side or #toasts == 1, true,
        "Mirror flips it (or says why not)")
    screen.selected = nil
    screen:update()
    -- drag the first ship by its anchor square to a free place
    local si = 1
    local ax, ay = Board.anchor(board.ships[si])
    local tx, ty
    for y = 0, 9 do for x = 0, 9 do
        if not tx and (x ~= ax or y ~= ay) and board:placed(si, x, y)
            and Board.anchor(board:placed(si, x, y)) == x then
            local p = board:placed(si, x, y)
            local px, py = Board.anchor(p)
            if px == x and py == y then tx, ty = x, y end
        end
    end end
    dirty, vsyncs = {}, 0
    eq(boards(screen)[1].on_drag("move", ax, ay, tx, ty), true, "a drag that starts on a ship is taken")
    eq(screen.drag and screen.drag.fits, true, "the preview: it fits there")
    eq(dirty[#dirty] and dirty[#dirty].kind .. " " .. vsyncs, "fast 1", "the preview is a fast refresh of the board")
    paint(boards(screen)[1])
    local n = #dirty
    boards(screen)[1].on_drag("move", ax, ay, tx, ty)
    eq(#dirty, n, "the same square again: nothing redrawn")
    boards(screen)[1].on_drag("drop", nil, nil, tx, ty)
    local nx, ny = Board.anchor(board.ships[si])
    eq(nx .. "," .. ny .. " " .. tostring(screen.selected) .. " " .. tostring(screen.drag), tx .. "," .. ty .. " 1 nil",
        "dropped there, and selected (to turn it)")
    -- onto another ship: it doesn't fit and doesn't move
    local oc = Board.cells(board.ships[2])[1]
    boards(screen)[1].on_drag("move", nx, ny, oc[1], oc[2])
    eq(screen.drag.fits, false, "the preview shows there is no room")
    paint(boards(screen)[1])
    toasts = {}
    boards(screen)[1].on_drag("drop", nil, nil, oc[1], oc[2])
    local mx, my = Board.anchor(board.ships[si])
    eq(mx .. "," .. my .. " " .. #toasts, nx .. "," .. ny .. " 1", "no room: it stays, and the reason is shown")
    -- lifted off the board: nothing happens
    boards(screen)[1].on_drag("move", mx, my, 9, 9)
    boards(screen)[1].on_drag("drop", nil, nil, -3, 12)
    local qx, qy = Board.anchor(board.ships[si])
    eq(qx .. "," .. qy .. " " .. tostring(screen.drag), mx .. "," .. my .. " nil", "lifted off the board: cancelled")
    -- a quick swipe moves it at once
    boards(screen)[1].on_drag("swipe", qx, qy, ax, ay)
    local rx, ry = Board.anchor(board.ships[si])
    eq(rx .. "," .. ry, ax .. "," .. ay, "a swipe moves it at once")
    -- a drag that starts on water isn't ours
    local wx, wy
    for y = 0, 9 do for x = 0, 9 do if not wx and not board:ship_at(x, y) then wx, wy = x, y end end end
    eq(boards(screen)[1].on_drag("move", wx, wy, 0, 0), false, "a drag from the water is left alone")
    eq(boards(screen)[1].on_drag("drop", nil, nil, 0, 0), false, "and so is its end")
    buttons(screen)["Ready"].callback()
    tick()
    eq(boards(screen)[1].on_drag, nil, "no dragging once the battle is on")
    screen:onClose()
    if shown[#shown].ok_callback then shown[#shown].ok_callback() end
    eq(#zmqs, 0, "ended")
end

-- Surviving a restart of KOReader -------------------------------------------------
local game_file = root .. "/settings/battleshipswifi_game.lua"
local function restarted() return Battleships:new{ ui = { menu = { registerToMainMenu = function() end } } } end
local function menu_of(pl) local mi = {}; pl:addToMainMenu(mi); return mi.battleshipswifi.sub_item_table_func() end
local function find_item(items, id) for _i, it in ipairs(items) do if it.battleshipswifi_item == id then return it end end end
local function marks_of(sc)
    local n = 0
    for y = 0, 9 do for x = 0, 9 do if sc.board_widgets.target.target.marks[y][x] then n = n + 1 end end end
    return n
end
local function play_steps(sc, steps)
    for _step = 1, steps do
        if buttons(sc)["Play again"] then return true end
        if sc:statusText():find("Your turn", 1, true) then
            local target = boards(sc)[1].target
            local free
            for y = 0, 9 do for x = 0, 9 do if not free and target:can_fire(x, y) then free = { x, y } end end end
            boards(sc)[1].on_tap(free[1], free[2])
        end
        clock = clock + 0.5
        tick()
        run_tasks()
    end
end
-- (the game above was closed: nothing to continue)
eq(find_item(menu_of(plugin), "continue"), nil, "a closed game leaves nothing to continue")
-- against the e-reader
item("ai").sub_item_table_func()[1].callback()
eq(stores[game_file].game == nil or stores[game_file].game.match.phase == "placing", true,
    "a new game replaces what was saved")
screen = shown[#shown]
tick()
buttons(screen)["Ready"].callback()
tick()
play_steps(screen, 40)
local known = marks_of(screen)
eq(known > 0, true, "some shots fired")
plugin:onExit()
eq(type(stores[game_file].game), "table", "the game against the e-reader is saved when KOReader closes")
eq(#zmqs, 0, "and nothing runs")
local p2 = restarted()
local items2 = menu_of(p2)
eq(items2[1].battleshipswifi_item .. " " .. items2[1].text, "continue Continue the game against E-reader",
    "after the restart: Continue first in the menu")
items2[1].callback()
screen = shown[#shown]
eq(screen:statusText():match("^Continuing the game against E%-reader.") ~= nil, true, "continued: " .. screen:statusText())
eq(marks_of(screen), known, "the same board")
eq(play_steps(screen, 800), true, "the continued game against the e-reader is played to the end")
screen:onClose()
eq(stores[game_file].game, nil, "closing a finished game drops what was saved")
eq(find_item(menu_of(p2), "continue"), nil, "no Continue entry then")
-- a network game (host)
find_item(menu_of(p2), "host").sub_item_table_func()[1].callback()
screen = shown[#shown]
client = fake_tcp({ "HELLO 4 Guest\n" })
table.insert(pending_clients, client)
tick(2)
session = client.sent:match("SESSION (%w+)\n")
client.incoming = { "SESSION " .. session .. "\nREADY\n" }
buttons(screen)["Ready"].callback()
tick()
eq(#boards(screen), 2, "network battle")
p2:onExit()
eq(client.sent:find("BYE", 1, true), nil, "closing KOReader: no BYE, the guest waits")
eq(stores[game_file].game and stores[game_file].game.role, "host", "the network game is saved")
local p3 = restarted()
local udps_before = #udps
find_item(menu_of(p3), "continue").callback()
screen = shown[#shown]
tick()
eq(#udps > udps_before, true, "the restored host listens again")
eq(screen:statusText(), "Continuing the game against Guest.\nWaiting for Guest to come back…", "and waits for the guest")
local returning = fake_tcp({ "RESUME 4 " .. session .. " 1 Guest\n" })
table.insert(pending_clients, returning)
tick(2)
eq(returning.sent:match("^RESUMED 4") ~= nil, true, "the guest resumes with the restored host")
eq(screen:statusText():match("^Connection to Guest restored.") ~= nil, true, "restored: " .. screen:statusText())
screen:onClose()
shown[#shown].ok_callback()
eq(stores[game_file].game, nil, "leaving drops the saved game")
-- a game that can't resume (an older guest without SESSION) isn't saved
find_item(menu_of(p3), "host").sub_item_table_func()[1].callback()
screen = shown[#shown]
client = fake_tcp({ "HELLO 4 Old\nREADY\n" })
table.insert(pending_clients, client)
tick(2)
buttons(screen)["Ready"].callback()
tick()
p3:onExit()
eq(stores[game_file].game, nil, "a game that can't resume isn't saved")
eq(client.sent:find("BYE", 1, true) ~= nil, true, "and the opponent is told")

-- Settings of the plugin's old name (battleships) are taken over once ---------------
stores[root .. "/settings/battleshipswifi.lua"] = nil
stores[root .. "/settings/battleships.lua"] = { name = "Old Name", last_address = "10.0.0.7" }
local renamed = Battleships:new{ ui = { menu = { registerToMainMenu = function() end } } }
eq(renamed:playerName(), "Old Name", "name taken over from battleships.lua")
eq(renamed.settings:readSetting("last_address"), "10.0.0.7", "last address taken over")
renamed.settings:saveSetting("name", nil)
renamed.settings:saveSetting("last_address", "10.0.0.8")
renamed.settings:flush()
local again = Battleships:new{ ui = { menu = { registerToMainMenu = function() end } } }
eq(again.settings:readSetting("last_address"), "10.0.0.8", "only once: a newer address isn't overwritten on the next start")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
