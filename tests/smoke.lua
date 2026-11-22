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
stub("device", {
    model = "Kindle Test",
    isKindle = function() return kindle end,
    hasKeys = function() return true end,
    input = { group = { Back = "Back" } },
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
local function item(id)
    for _i, it in ipairs(menu_items.battleshipswifi.sub_item_table_func()) do
        if it.battleshipswifi_item == id then return it end
    end
end
eq(item("name").text_func(), "Your name: Kindle Test", "default name is the device model")
local host_items = item("host").sub_item_table_func()
eq(host_items[1].text .. "|" .. host_items[2].text, "Classic ships|Shaped ships", "host picks the fleet")
eq(host_items[1].checked_func == nil and host_items[2].checked_func == nil, true, "plain items, not radio buttons")
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
eq(screen.title_bar.subtitle, nil, "no opponent yet")
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
hudp.inbox = { { "DISCOVER 2", "192.168.1.30", 7533 } }
tick()
eq(hudp.out[1] and hudp.out[1][1], "GAME 2 7531 classic Martin", "discovery answered")

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
local client = fake_tcp({ "HELLO 2 Guest\n" })
table.insert(pending_clients, client)
tick(2)
eq(client.sent:match("^WELCOME 2 classic Martin\n") ~= nil, true, "host welcomes the guest")
eq(screen.title_bar.subtitle, "Opponent: Guest", "opponent shown")
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
eq(table.concat(kinds, " "), "fast fast fast ui", "fast refreshes, then a normal one")
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
eq(dirty[1].w == screen and dirty[1].kind == "ui", true, "and the game screen is refreshed normally")
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
client = fake_tcp({ "HELLO 2 Guest\n" })
table.insert(pending_clients, client)
tick(2)
client.incoming = { "CLOSE" }
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("^Guest left.") ~= nil, true, "guest left before the battle")
eq(screen.title_bar.subtitle, nil, "waiting for another opponent")
hudp = udp_on(7532)
hudp.inbox = { { "DISCOVER 2", "192.168.1.31", 7533 } }
tick()
eq(#hudp.out, 1, "discovery answered again")
client = fake_tcp({ "HELLO 2 Second\n" })
table.insert(pending_clients, client)
tick(2)
eq(screen.title_bar.subtitle, "Opponent: Second", "another guest joins")
-- silence → timeout
clock = clock + 31
tick()
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status, "Second left.\nPlace your ships: tap a ship to select it, tap it again to turn it, tap the water to move it there.\nWaiting for an opponent. Your address: 192.168.1.20",
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
client = fake_tcp({ "HELLO 2 Guest\n" })
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
hudp.inbox = { { "DISCOVER 2", "192.168.1.31", 7533 } }
tick()
eq(hudp.out[#hudp.out][1], "RESUMEGAME 2 7531 " .. session, "searches answered with the session")
-- a stranger is turned away, the host keeps waiting
local stranger = fake_tcp({ "HELLO 2 Stranger\n" })
table.insert(pending_clients, stranger)
tick(2)
eq(stranger.sent .. tostring(stranger.closed), "ERROR busy\ntrue", "a stranger is turned away")
eq(status_of(screen):find("Waiting for Guest to come back", 1, true) ~= nil, true, "still waiting")
-- the guest comes back
local back = fake_tcp({ "RESUME 2 " .. session .. " 2 Guest\n" })
table.insert(pending_clients, back)
tick(2)
eq(back.sent:match("^RESUMED 2 %d+\n") ~= nil, true, "host answers RESUMED")
eq(status_of(screen):match("^Connection to Guest restored.") ~= nil, true, "restored: " .. status_of(screen))
eq(boards(screen)[1].on_tap ~= nil or status_of(screen):find("aiming", 1, true) ~= nil, true, "the game goes on")
-- the guest comes back over a new connection before the host noticed the old one was gone
local again = fake_tcp({ "RESUME 2 " .. session .. " 2 Guest\n" })
table.insert(pending_clients, again)
tick(3)
eq(back.closed, true, "the old connection is dropped")
eq(again.sent:match("^RESUMED 2") ~= nil, true, "and the new one goes on")
-- going to sleep keeps the game; waking up listens again
local binds_before = #udps
plugin:onSuspend()
eq(#zmqs, 1, "asleep: the game is kept")
eq(again.closed and not again.sent:find("BYE", 1, true), true, "the connection closed without BYE")
eq(status_of(screen), "Connection to Guest restored.\nWaiting for Guest to come back…", "waiting while asleep")
plugin:onResume()
tick()
eq(#udps > binds_before, true, "listening again after waking up")
local after = fake_tcp({ "RESUME 2 " .. session .. " 2 Guest\n" })
table.insert(pending_clients, after)
tick(2)
eq(status_of(screen):match("^Connection to Guest restored.") ~= nil and after.sent:match("^RESUMED") ~= nil, true,
    "the guest comes back after the host slept")
-- an unknown session is refused, the game keeps waiting for the right one
after.incoming = { "CLOSE" }
tick()
local wrong = fake_tcp({ "RESUME 2 othergame 0 Guest\n" })
table.insert(pending_clients, wrong)
tick(2)
eq(wrong.sent .. tostring(wrong.closed), "ERROR resume\ntrue", "RESUME of another game refused")
eq(status_of(screen):find("Waiting for Guest to come back", 1, true) ~= nil, true, "still waiting for the right one")
screen:onClose()
eq(shown[#shown].text, "Leave the game?", "leaving while waiting asks first")
shown[#shown].ok_callback()
eq(#zmqs, 0, "Close (and confirm) ends it")

-- Joining by address -----------------------------------------------------------
item("join").callback()
local dialog = dialogs[#dialogs]
dialog.text_value = "not an address!"
dialog.buttons[1][2].callback()
eq(toasts[#toasts], "Invalid address", "invalid address")
dialog.text_value = "10.0.0.66"
dialog.buttons[1][2].callback()
eq(notes[#notes], "Cannot connect to 10.0.0.66: connection refused", "connection refused")
eq(#zmqs, 0, "no game")
item("join").callback()
dialog = dialogs[#dialogs]
eq(dialog.input, "10.0.0.66", "last address remembered")
dialog.text_value = "10.0.0.9:7000"
dialog.buttons[1][2].callback()
eq(connect_to, "10.0.0.9:7000", "connects to the address")
local sock = tcps[#tcps]
eq(sock.sent, "HELLO 2 Martin\n", "guest says hello")
screen = shown[#shown]
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("Connecting…$") ~= nil, true, "guest waits for WELCOME")
sock.incoming = { "WELCOME 2 shapes Host\n" }
tick()
eq(screen.title_bar.subtitle, "Opponent: Host", "guest joined")
eq(#boards(screen)[1].board.ships, 6, "guest places the host's shaped fleet")
status = find_all(screen, function(w) return w.alignment == "center" end)[1].text
eq(status:match("^You joined Host's game. Fleet: Shaped ships.") ~= nil, true, "fleet named: " .. status)
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
item("join").callback()
dialog = dialogs[#dialogs]
dialog.text_value = "10.0.0.9"
dialog.buttons[1][2].callback()
sock = tcps[#tcps]
screen = shown[#shown]
sock.incoming = { "WELCOME 2 classic Host\nSESSION abc123\nREADY\n" }
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
eq(resock.sent:match("^RESUME 2 abc123 %d+ Martin\n") ~= nil, true, "guest asks to resume: " .. resock.sent)
resock.incoming = { "RESUMED 2 1\n" }
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
sudp.inbox = { { "GAME 2 7531 shapes Host", "192.168.1.40", 7532 } }
tick()
eq(menu.item_table[1].text .. " " .. menu.item_table[1].mandatory, "Host (Shaped ships) 192.168.1.40", "game listed with its fleet")
eq(menu.item_table[2].text, "Join by address…", "join by address below")
clock = clock + 10
tick()
eq(menu.item_table[1].text, "Searching for games…", "silent game dropped")
sudp.inbox = { { "GAME 2 7531 shapes Host", "192.168.1.40", 7532 } }
tick()
menu.item_table[1].callback()
eq(sudp.closed, true, "search stopped when the list closes")
eq(connect_to, "192.168.1.40:7531", "joins the game found")
eq(#zmqs, 1, "only the game polled")
plugin:onExit()
eq(#zmqs .. " " .. standby, "0 0", "exit ends the game")

-- Playing against the e-reader ---------------------------------------------------
local ai_items = item("ai").sub_item_table_func()
eq(ai_items[1].text .. "|" .. ai_items[2].text, "Classic ships|Shaped ships", "fleets to play against the e-reader")
eq(ai_items[1].checked_func == nil, true, "plain items")
eq(ai_items[3].text_func(), "Difficulty: Normal", "normal difficulty by default")
ai_items[3].sub_item_table[3].callback()
eq(item("ai").sub_item_table_func()[3].text_func(), "Difficulty: Hard", "difficulty saved")
local sockets_before = #tcps + #udps
ai_items[2].callback()
screen = shown[#shown]
eq(#tcps + #udps, sockets_before, "no network")
eq(standby, 0, "the device may doze off against the e-reader")
tick()
eq(screen.title_bar.subtitle, "Opponent: E-reader", "the e-reader joins")
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
eq(screen.title_bar.subtitle:match("^Opponent: E%-reader · You %d : %d$") ~= nil, true,
    "score in the title: " .. screen.title_bar.subtitle)
plugin:onSuspend()
eq(#zmqs, 1, "going to sleep keeps a game against the e-reader")
local score_before = screen.title_bar.subtitle
buttons(screen)["Play again"].callback()
tick(2)
eq(#boards(screen), 1, "the e-reader plays again: placing")
eq(screen.title_bar.subtitle, score_before, "the score stays for the next game")
plugin:onExit()
eq(#zmqs .. " " .. standby, "0 0", "exit ends it")

-- Settings of the plugin's old name (battleships) are taken over once ---------------
stores[root .. "/settings/battleshipswifi.lua"] = nil
stores[root .. "/settings/battleships.lua"] = { name = "Old Name", last_address = "10.0.0.7" }
local renamed = Battleships:new{ ui = { menu = { registerToMainMenu = function() end } } }
eq(renamed:playerName(), "Old Name", "name taken over from battleships.lua")
eq(renamed.settings:readSetting("last_address"), "10.0.0.7", "last address taken over")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
