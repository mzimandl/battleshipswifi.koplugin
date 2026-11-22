-- Off-device tests. Run from the repo root:  luajit tests/run.lua
package.path = "./?.lua;" .. package.path

local Board = require("battleshipswifi/board")
local Protocol = require("battleshipswifi/protocol")
local Match = require("battleshipswifi/match")
local Net = require("battleshipswifi/net")

local passed, failed = 0, 0
local function eq(actual, expected, name)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL %s\n  expected: %q\n  actual:   %q"):format(name, tostring(expected), tostring(actual)))
    end
end

-- Seeded random numbers, the same on every Lua version.
local function rng(seed)
    local s = seed
    return function(n)
        s = (s * 1103515245 + 12345) % 2147483648
        return s % n + 1
    end
end

-- Board: placement ------------------------------------------------------------
-- a straight ship of the classic fleet
local function ship(x, y, len, dir) return { x = x, y = y, shape = "line" .. len, rot = dir == "h" and 0 or 1, hits = 0 } end
local function shaped(x, y, shape, rot) return { x = x, y = y, shape = shape, rot = rot or 0, hits = 0 } end

local b = Board.new()
b.ships = { ship(0, 0, 3, "h") }
eq(b:fits(ship(0, 2, 2, "h")), true, "one row of water between ships is enough")
eq(b:fits(ship(3, 1, 2, "h")), false, "ships may not touch at a corner")
eq(b:fits(ship(3, 0, 2, "v")), false, "ships may not touch at the end")
eq(b:fits(ship(4, 0, 2, "v")), true, "a gap of one column is enough")
eq(b:fits(ship(9, 0, 2, "h")), false, "ships stay on the board")
eq(b:fits(ship(1, 0, 3, "h"), 1), true, "the ship itself is ignored when moving it")
eq(b:ship_at(2, 0), 1, "ship_at finds the ship")
eq(b:ship_at(3, 0), nil, "ship_at: water")

for seed = 1, 20 do
    local r = Board.new()
    eq(r:randomize(rng(seed)), true, "random fleet " .. seed)
    local ok = r:complete()
    for i, s in ipairs(r.ships) do
        if not r:fits(s, i) then ok = false end
    end
    eq(ok, true, "random fleet is valid " .. seed)
end

b = Board.new()
b.ships = { ship(8, 0, 2, "h"), ship(0, 5, 3, "v") }
eq(b:rotate(1), true, "rotate a ship")
eq(Board.encode_ship(b.ships[1]), "8,0,line2,1", "rotated around its first cell")
eq(b:rotate(2), true, "rotate at the edge")
eq(Board.encode_ship(b.ships[2]), "0,5,line3,0", "rotated ship")
eq(b:move(2, 9, 9), true, "move near the edge")
eq(Board.encode_ship(b.ships[2]), "7,9,line3,0", "moved ship kept on the board")
eq(b:move(2, 7, 1), false, "can't move next to another ship")
eq(Board.encode_ship(b.ships[2]), "7,9,line3,0", "failed move leaves the ship")
b.ships = { ship(0, 0, 4, "h"), ship(0, 2, 2, "h") }
eq(b:rotate(1), false, "can't rotate onto another ship")
eq(b:can_rotate(1), false, "no room to turn")
eq(b:can_rotate(2), true, "room to turn")
local blocked = b:blocked(2)
eq(blocked[1][0], true, "next to another ship: no room")
eq(blocked[0][4], true, "touching a ship's end: no room")
eq(blocked[0][5], nil, "one square apart: room")
eq(blocked[0][9], nil, "far enough: room")
eq(blocked[0][0], nil, "ship squares are not shaded")
eq(blocked[2][1], nil, "the moved ship's own squares count as free")
eq(blocked[3][0] or blocked[3][5], nil, "row below is free")
local n_blocked = 0
for y = 0, 9 do for x = 0, 9 do if blocked[y][x] then n_blocked = n_blocked + 1 end end end
eq(n_blocked, 6, "blocked: A2-E2 and E1")

-- Board: shooting -------------------------------------------------------------
b = Board.new()
b.ships = { ship(0, 0, 2, "h"), ship(5, 5, 2, "v") }
eq(b:shoot(9, 9), "miss", "miss")
eq(select(2, b:shoot(9, 9)), "repeat", "same square twice")
eq(select(2, b:shoot(10, 0)), "outside", "outside the board")
eq(b:shoot(0, 0), "hit", "hit")
local res, sunk = b:shoot(1, 0)
eq(res .. " " .. Board.encode_ship(sunk), "sunk 0,0,line2,0", "sunk with its ship")
eq(b:shoot(5, 5), "hit", "hit the second ship")
eq(b:shoot(5, 6), "won", "last ship sunk wins")
eq(b:encode_fleet(), "0,0,line2,0 5,5,line2,1", "fleet encoding")

local t = Board.target()
eq(t:can_fire(3, 3), true, "unknown square can be fired at")
t:apply(3, 3, "miss")
eq(t:can_fire(3, 3), false, "known square can't")
t:apply(0, 0, "hit")
t:apply(1, 0, "sunk", ship(0, 0, 2, "h"))
eq(t.marks[0][0] .. t.marks[0][1], "sunksunk", "sunk ship marked")
eq(t.marks[1][2], "near", "water around a sunk ship is marked")
eq(t:can_fire(2, 1), false, "can't fire next to a sunk ship")
eq(t.marks[3][3], "miss", "misses stay")
t:reveal({ ship(0, 0, 2, "h"), ship(5, 5, 3, "v") })
eq(#t.ships, 2, "revealed fleet adds only unknown ships")
eq(t:ship_at(5, 7), 2, "revealed ship found")

eq(Board.label(0, 0) .. Board.label(9, 9), "A1J10", "labels")
eq(Board.decode_ship("8,0,line3,0"), nil, "ship off the board rejected")
eq(Board.decode_ship("1,2,line3,2"), nil, "rotation the shape doesn't have rejected")
eq(Board.decode_ship("1,2,boat,0"), nil, "unknown shape rejected")
eq(Board.decode_ship("1,2,3,v"), nil, "version 1 ships rejected")
eq(Board.encode_ship(Board.decode_ship("1,2,line3,1")), "1,2,line3,1", "ship round trip")
eq(#Board.around(ship(0, 0, 2, "h")), 4, "water around a corner ship")

-- Board: shaped ships -----------------------------------------------------------
local turns = {}
for shape in pairs(Board.SHAPES) do turns[shape] = #Board.rotations(shape) end
eq(turns.line3 .. turns.cruiser .. turns.carrier .. turns.battleship .. turns.destroyer, "21444",
    "distinct quarter turns")
eq(Board.fleet_size("classic") .. " " .. Board.fleet_size("shapes"), "17 24", "fleet sizes")
local function drawn(s)
    local w, h = Board.extent(s)
    local rows = {}
    for y = 0, h - 1 do
        local row = ""
        for x = 0, w - 1 do row = row .. (Board.covers(s, s.x + x, s.y + y) and "#" or ".") end
        rows[#rows + 1] = row
    end
    return table.concat(rows, "/")
end
eq(drawn(shaped(0, 0, "carrier")), "####/.##.", "carrier")
eq(drawn(shaped(0, 0, "carrier", 1)), ".#/##/##/.#", "carrier turned clockwise")
eq(drawn(shaped(0, 0, "destroyer", 2)), "###/..#", "destroyer turned twice")
eq(drawn(shaped(0, 0, "cruiser")), ".#./###/.#.", "cruiser")
eq(#Board.around(shaped(3, 3, "cruiser")), 16, "water around a cross")
eq(table.concat({ Board.anchor(shaped(3, 3, "cruiser")) }, ","), "4,3", "anchor: first square of the top row")

b = Board.new("shapes")
b.ships = { shaped(0, 0, "cruiser") }
eq(b:fits(shaped(2, 0, "submarine")), false, "touching the cross's arm at a corner")
eq(b:fits(shaped(3, 0, "submarine")), false, "diagonal to the cross's arm")
eq(b:fits(shaped(4, 0, "submarine")), true, "one square apart from the arm")
eq(b:fits(shaped(3, 3, "submarine")), true, "two squares diagonally from the cross")
eq(b:fits(shaped(1, 3, "submarine")), false, "below the cross's foot")
b.ships = { shaped(0, 0, "cruiser"), shaped(5, 5, "destroyer") }
eq(b:move(1, 7, 1), true, "moving a cross by its anchor")
eq(Board.encode_ship(b.ships[1]), "6,1,cruiser,0", "the tapped square is the cross's top")
eq(b:move(1, 9, 0), true, "moved back onto the board")
eq(Board.encode_ship(b.ships[1]), "7,0,cruiser,0", "kept on the board")
eq(b:rotate(2), true, "turn a destroyer")
eq(Board.encode_ship(b.ships[2]), "5,5,destroyer,1", "turned around its anchor")
b.ships = { shaped(0, 0, "destroyer", 0), shaped(0, 4, "carrier") }
eq(b:rotate(1), true, "turn skips quarter turns that don't fit")
eq(b.ships[1].rot ~= 0, true, "it turned")
for seed = 1, 20 do
    local r = Board.new("shapes")
    eq(r:randomize(rng(seed)), true, "random shaped fleet " .. seed)
    local ok = r:complete()
    for i, s in ipairs(r.ships) do
        if not r:fits(s, i) then ok = false end
    end
    eq(ok, true, "random shaped fleet is valid " .. seed)
end
b = Board.new("shapes")
b.ships = { shaped(0, 0, "battleship"), shaped(6, 6, "submarine") }
for _i, c in ipairs({ { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 } }) do b:shoot(c[1], c[2]) end
eq(b:shoot(1, 1), "sunk", "a shaped ship sinks when all its squares are hit")
t = Board.target()
t:apply(1, 1, "sunk", shaped(0, 0, "battleship"))
eq(t.marks[0][3] .. t.marks[1][1] .. t.marks[1][2] .. t.marks[2][1], "sunksunknearnear", "marks around a shaped ship")
eq(t.marks[2][3], nil, "beyond the water around it: unknown")

-- Protocol ----------------------------------------------------------------------
eq(Protocol.clean_name("  Ann\nB\tc  "), "Ann B c", "names lose control characters")
eq(Protocol.clean_name(string.rep("ž", 30)), string.rep("ž", 24), "names are cut by characters")
local cmd, words, rest = Protocol.parse("HELLO 2 Žluťoučký kůň")
eq(cmd .. "|" .. words[1] .. "|" .. rest, "HELLO|2|2 Žluťoučký kůň", "parse")
eq(Protocol.parse("hello"), nil, "commands are upper case")
local buf = Protocol.buffer()
eq(#buf:push("PI"), 0, "partial line waits")
local lines = buf:push("NG\r\nSHOT 1 2\nRES")
eq(table.concat(lines, ","), "PING,SHOT 1 2", "complete lines")
eq(buf:push("ULT\n")[1], "RESULT", "rest of the line")
eq(select(2, buf:push(string.rep("x", 600))), "too long", "endless line is an error")
local h, p = Protocol.parse_address(" 192.168.1.5 ")
eq(h .. ":" .. p, "192.168.1.5:" .. Protocol.PORT, "address without port")
h, p = Protocol.parse_address("10.0.0.2:7000")
eq(h .. ":" .. p, "10.0.0.2:7000", "address with port")
eq(Protocol.parse_address("10.0.0.2:99999"), nil, "port out of range")
eq(Protocol.parse_address("a b"), nil, "invalid address")
eq(table.concat(Protocol.broadcasts("192.168.1.5"), ","), "255.255.255.255,192.168.1.255", "broadcast addresses")
eq(#Protocol.broadcasts(nil), 1, "global broadcast without an address")
eq(Protocol.is_discover(Protocol.discover()), true, "discover")
eq(Protocol.is_discover("DISCOVER 99"), false, "other version ignored")
local ann = Protocol.parse_announce(Protocol.announce(7531, "shapes", "Kindle Paperwhite"))
eq(ann.port .. " " .. ann.fleet .. " " .. ann.name, "7531 shapes Kindle Paperwhite", "announce round trip")
eq(Protocol.parse_announce("GAME 99 7531 classic x"), nil, "announce of another version ignored")
eq(Protocol.parse_announce("GAME 1 7531 x"), nil, "version 1 announce ignored")
eq(select(2, Match.new{ role = "host", name = "H", send = function() end }:receive("HELLO 1 Old")), "version",
    "version 1 guest refused")

-- Match: two players wired together ------------------------------------------
local function pair(seed)
    local host, guest
    local to_guest, to_host = {}, {}
    host = Match.new{ role = "host", name = "Host", rand = rng(seed), send = function(l) table.insert(to_guest, l) end }
    guest = Match.new{ role = "guest", name = "Guest", rand = rng(seed + 100), send = function(l) table.insert(to_host, l) end }
    local events = { host = {}, guest = {} }
    local function deliver()
        local any = true
        while any do
            any = false
            while #to_host > 0 do
                any = true
                local l = table.remove(to_host, 1):gsub("\n$", "")
                local ev, err = host:receive(l)
                assert(not err, "host: " .. tostring(err) .. " on " .. l)
                if ev then table.insert(events.host, ev.type) end
            end
            while #to_guest > 0 do
                any = true
                local l = table.remove(to_guest, 1):gsub("\n$", "")
                local ev, err = guest:receive(l)
                assert(not err, "guest: " .. tostring(err) .. " on " .. l)
                if ev then table.insert(events.guest, ev.type) end
            end
        end
    end
    return host, guest, deliver, events
end

local host, guest, deliver, events = pair(7)
eq(host.phase, "placing", "host starts placing")
eq(host.board:complete(), true, "a random fleet is ready at the start")
eq(host:set_ready(), nil, "host ready before anyone joined")
guest:hello()
deliver()
eq(host.peer .. "/" .. guest.peer, "Guest/Host", "names exchanged")
eq(guest.peer_ready, true, "guest learns that the host is ready")
eq(events.host[1], "joined", "host: joined event")
local ev = guest:set_ready()
deliver()
eq(host.phase .. guest.phase, "battlebattle", "both ready: the battle starts")
eq(events.guest[#events.guest], "start", "guest: start event")
eq((host.turn == "me") ~= (guest.turn == "me"), true, "exactly one player's turn")
eq(guest:fire(0, 0) and host:fire(0, 0), false, "only the player on turn can fire")

-- play the whole game: each player fires at every square in order
local function play(a, z, deliver_fn)
    local next_shot = { [a] = 0, [z] = 0 }
    for _step = 1, 400 do
        if a.phase ~= "battle" then break end
        local shooter = a:my_turn() and a or z
        repeat
            local n = next_shot[shooter]
            next_shot[shooter] = n + 1
            local x, y = n % 10, math.floor(n / 10)
            local fired = shooter.target:can_fire(x, y) and shooter:fire(x, y)
        until fired
        deliver_fn()
    end
end
play(host, guest, deliver)
eq(host.phase .. guest.phase, "overover", "the game ends")
eq((host.winner == "me") ~= (guest.winner == "me"), true, "exactly one winner")
local winner, loser = host, guest
if guest.winner == "me" then winner, loser = guest, host end
eq(winner.target.sunk, #Board.FLEETS.classic, "winner sank the whole fleet")
eq(#loser.target.ships, #Board.FLEETS.classic, "loser sees the winner's whole fleet")
eq(winner:fire(9, 9), false, "no shots after the game")

guest:request_rematch()
deliver()
eq(host.phase, "over", "rematch needs both players")
eq(events.host[#events.host], "rematch_request", "host: rematch request")
host:request_rematch()
deliver()
eq(host.phase .. guest.phase, "placingplacing", "rematch: both place ships again")
eq(host.ready or guest.ready or host.peer_ready, false, "rematch resets ready")
eq(host.peer, "Guest", "rematch keeps the opponent")

-- shaped fleet: the host picks it, the guest takes it from WELCOME
do
    local to_guest, to_host = {}, {}
    local h2 = Match.new{ role = "host", name = "H", fleet = "shapes", rand = rng(11), send = function(l) table.insert(to_guest, l) end }
    local g2 = Match.new{ role = "guest", name = "G", rand = rng(12), send = function(l) table.insert(to_host, l) end }
    local gev = {}
    local function deliver2()
        local any = true
        while any do
            any = false
            while #to_host > 0 do
                any = true
                local l = table.remove(to_host, 1):gsub("\n$", "")
                local _ev, err = h2:receive(l)
                assert(not err, "host: " .. tostring(err) .. " on " .. l)
            end
            while #to_guest > 0 do
                any = true
                local l = table.remove(to_guest, 1):gsub("\n$", "")
                local ev2, err = g2:receive(l)
                assert(not err, "guest: " .. tostring(err) .. " on " .. l)
                if ev2 then table.insert(gev, ev2) end
            end
        end
    end
    eq(g2.board.fleet, "classic", "guest starts with the default fleet")
    g2:set_ready()
    g2:hello()
    deliver2()
    eq(to_guest[1], nil, "all delivered")
    eq(g2.fleet .. " " .. g2.board.fleet .. " " .. g2.peer, "shapes shapes H", "guest takes the host's fleet")
    eq(gev[1].fleet_changed, true, "joined event says the fleet changed")
    eq(g2.ready, false, "guest places the new fleet again")
    eq(#g2.board.ships, 6, "shaped fleet placed")
    h2:set_ready(); g2:set_ready()
    deliver2()
    eq(h2.phase .. g2.phase, "battlebattle", "shaped battle starts")
    play(h2, g2, deliver2)
    eq(h2.phase .. g2.phase, "overover", "shaped game ends")
    local w2 = h2.winner == "me" and h2 or g2
    eq(w2.target.sunk, 6, "whole shaped fleet sunk")
    g2:request_rematch(); h2:request_rematch()
    deliver2()
    eq(h2.board.fleet .. g2.board.fleet, "shapesshapes", "rematch keeps the fleet")
    local g3 = Match.new{ role = "guest", name = "G", fleet = "shapes", send = function() end }
    local ev3 = g3:receive("WELCOME " .. Protocol.VERSION .. " shapes Host Name")
    eq(tostring(ev3.fleet_changed) .. " " .. g3.peer, "false Host Name", "fleet known from the game list")
    eq(select(2, Match.new{ role = "guest", name = "G", send = function() end }:receive("WELCOME 2 boats H")),
        "bad WELCOME", "unknown fleet refused")
end

-- protocol errors
host, guest, deliver = pair(3)
eq(select(2, guest:receive("SHOT 1 1")), "not your turn", "shot before the battle")
eq(select(2, guest:receive("HELLO 2 x")), "unexpected HELLO", "guest doesn't take HELLO")
eq(select(2, host:receive("HELLO 99 x")), "version", "other version refused")
eq(select(2, host:receive("READY")), "unexpected READY", "READY before HELLO")
eq(host:receive("FUTURE stuff"), nil, "unknown commands are ignored")
eq(select(2, host:receive("ERROR busy")), "busy", "ERROR ends the match")
host:receive("HELLO 2 G")
eq(select(2, host:receive("HELLO 2 G")), "already joined", "second HELLO refused")
host:set_ready()
host:receive("READY")
eq(host.phase, "battle", "host starts when both are ready")
host.turn = "peer"
eq(select(2, host:receive("SHOT 10 0")), "bad SHOT", "shot outside the board")
host:receive("SHOT 0 0")
eq(select(2, host:receive("SHOT 0 0")) ~= nil, true, "same square twice is an error (or not the turn)")
host.turn, host.pending = "me", nil
host:fire(4, 4)
eq(select(2, host:receive("RESULT 5 5 miss")), "unexpected RESULT", "result for another square")
eq(select(2, host:receive("RESULT 4 4 sunk")), "bad RESULT", "sunk without the ship")
host:receive("RESULT 4 4 miss")
eq(host.turn, "peer", "miss passes the turn")

-- the host's opponent leaves before the battle
host = Match.new{ role = "host", name = "H", send = function() end }
host:receive("HELLO 2 G")
host:receive("READY")
host:drop_peer()
eq(host.peer == nil and not host.peer_ready, true, "drop_peer waits for another opponent")

-- AI: the e-reader as an opponent ----------------------------------------------
local AI = require("battleshipswifi/ai")
-- shots a level needs to sink a whole fleet, on average over `games` boards
local function shots_needed(level, fleet, games, seed)
    local r = rng(seed)
    local total, valid = 0, true
    for _g = 1, games do
        local board = Board.new(fleet)
        board:randomize(r)
        local t2 = Board.target()
        for shot = 1, 100 do
            local x, y = AI.choose(level, t2, fleet, r)
            if not (x and t2:can_fire(x, y)) then valid = false; break end
            local res2, sunk_ship = board:shoot(x, y)
            t2:apply(x, y, res2, sunk_ship)
            if res2 == "won" then total = total + shot; break end
            if shot == 100 then valid = false end
        end
    end
    return total / games, valid
end
for _f, fleet in ipairs({ "classic", "shapes" }) do
    local avg = {}
    for _l, level in ipairs(AI.LEVELS) do
        local a, valid = shots_needed(level, fleet, 30, 5)
        avg[level] = a
        eq(valid, true, fleet .. " " .. level .. ": only unknown squares, the whole fleet sunk")
    end
    eq(avg.easy > avg.normal and avg.normal > avg.hard, true,
        ("%s: harder levels need fewer shots (%.1f, %.1f, %.1f)"):format(fleet, avg.easy, avg.normal, avg.hard))
end
do
    -- after a hit, normal and hard fire next to it
    local t3 = Board.target()
    t3:apply(4, 4, "hit")
    for _i, level in ipairs({ "normal", "hard" }) do
        local x, y = AI.choose(level, t3, "classic", rng(3))
        eq(math.abs(x - 4) + math.abs(y - 4), 1, level .. ": next to the hit")
    end
    t3:apply(5, 4, "hit")
    local x, y = AI.choose("normal", t3, "classic", rng(4))
    eq(y == 4 and (x == 3 or x == 6), true, "normal: along the line of hits")
    -- hard never fires where no ship afloat fits
    local t4 = Board.target()
    for y2 = 0, 9 do for x2 = 0, 9 do
        if not (y2 == 0 and x2 <= 1) and not (y2 == 9 and x2 == 9) then t4.marks[y2][x2] = "miss" end
    end end
    t4.ships = {}
    for _i, shape in ipairs({ "line5", "line4", "line3", "line3" }) do t4.ships[#t4.ships + 1] = { shape = shape } end
    x, y = AI.choose("hard", t4, "classic", rng(5))
    eq(x .. "," .. y, "0,0", "hard: only where the last ship (2 squares) fits")
    eq(table.concat(AI.afloat(t4, "classic"), ","), "line2", "ships afloat")
end
do
    -- a whole match against the e-reader player, and a rematch
    local ai = AI.player{ level = "hard", name = "Reader", rand = rng(21) }
    local human = Match.new{ role = "host", name = "H", fleet = "shapes", rand = rng(22),
        send = function(l) ai:deliver(l) end }
    local clock2 = 0
    local function run(steps)
        for _s = 1, steps do
            clock2 = clock2 + 0.5
            local lines2, err = ai:poll(clock2)
            assert(not err, err)
            for _i, l in ipairs(lines2) do
                local _ev, herr = human:receive(l)
                assert(not herr, tostring(herr) .. " on " .. l)
            end
        end
    end
    run(2)
    eq(human.peer .. " " .. tostring(human.peer_ready) .. " " .. ai.match.fleet, "Reader true shapes",
        "the e-reader joins with the host's fleet and gets ready")
    human:set_ready()
    run(1)
    eq(human.phase, "battle", "battle against the e-reader")
    local next_shot = 0
    for _s = 1, 400 do
        if human.phase ~= "battle" then break end
        if human:my_turn() then
            repeat
                local x, y = next_shot % 10, math.floor(next_shot / 10)
                next_shot = next_shot + 1
            until human.target:can_fire(x, y) and human:fire(x, y)
        end
        run(1)
    end
    run(1) -- the last RESULT reaches the e-reader
    eq(human.phase .. ai.match.phase, "overover", "the game against the e-reader ends")
    eq((human.winner == "me") ~= (ai.match.winner == "me"), true, "one winner")
    eq(human.winner, "peer", "hard e-reader beats firing square by square")
    eq(#human.target.ships, 6, "the e-reader's fleet revealed")
    human:request_rematch()
    run(2)
    eq(human.phase .. ai.match.phase .. tostring(human.peer_ready), "placingplacingtrue", "the e-reader plays again")
end

-- Net with fake sockets ----------------------------------------------------------
local function fake_tcp(incoming)
    local s = { sent = "", incoming = incoming or {}, closed = false }
    function s:settimeout() end
    function s:setoption() return true end
    function s:send(data) self.sent = self.sent .. data; return #data end
    function s:receive()
        local chunk = table.remove(self.incoming, 1)
        if chunk == "CLOSE" then return nil, "closed", "" end
        if chunk then return nil, "timeout", chunk end
        return nil, "timeout", ""
    end
    function s:close() self.closed = true end
    return s
end

local sock = fake_tcp({ "PING\nSHO", "T 1 2\n" })
local conn = Net.connection(sock, 0)
local got = conn:poll(5)
eq(table.concat(got, ","), "PING", "first poll: one line")
eq(conn.last_seen, 5, "data updates last_seen")
eq(conn:poll(6)[1], "SHOT 1 2", "line completed in the next poll")
eq(#conn:poll(7), 0, "nothing more")
eq(conn.last_seen, 6, "no data, last_seen kept")
conn:send("BYE\n")
eq(sock.sent, "BYE\n", "send")
sock.incoming = { "CLOSE" }
eq(select(2, conn:poll(8)), "closed", "closed connection reported")
eq(sock.closed, true, "socket closed")

-- partial sends are kept for later
sock = fake_tcp()
local accept = 2
function sock:send(data)
    local n = math.min(accept, #data)
    self.sent = self.sent .. data:sub(1, n)
    if n < #data then return nil, "timeout", n end
    return n
end
conn = Net.connection(sock, 0)
conn:send("ABCDEF\n")
eq(sock.sent, "AB", "partial send")
accept = 100
conn:poll(1)
eq(sock.sent, "ABCDEF\n", "rest sent on the next poll")

-- discovery
local function fake_udp()
    local u = { out = {}, inbox = {} }
    function u:setsockname(_h, port) self.port = port; return true end
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
local udps = {}
local fake_socket = {
    udp = function() local u = fake_udp(); table.insert(udps, u); return u end,
    bind = function() local s = fake_tcp(); s.accept = function() return nil end; return s end,
}
local hst = Net.host(fake_socket, 7531)
local hudp = udps[#udps]
eq(hudp.port, Protocol.DISCOVERY_PORT, "host listens for discovery")
hudp.inbox = { { "DISCOVER 2", "10.0.0.9", 7533 }, { "junk", "10.0.0.8", 1 } }
hst:answer("Host", "shapes")
eq(#hudp.out .. " " .. hudp.out[1][1] .. " " .. hudp.out[1][2], "1 GAME 2 7531 shapes Host 10.0.0.9", "host answers DISCOVER only")
hudp.inbox = { { "DISCOVER 2", "10.0.0.9", 7533 } }
hst:answer(nil)
eq(#hudp.out, 1, "no answers once the game is full")

local search = Net.search(fake_socket, "10.0.0.5")
local sudp = udps[#udps]
eq(sudp.port, Protocol.SEARCH_PORT, "search listens on its port")
search:send()
eq(#sudp.out .. " " .. sudp.out[2][2], "2 10.0.0.255", "discover broadcast to both addresses")
sudp.inbox = { { "GAME 2 7531 shapes Host", "10.0.0.9", 7532 }, { "GAME 2 7531 shapes Host", "10.0.0.9", 7532 } }
eq(search:poll(1), true, "found a game")
eq(#search.games .. " " .. search.games[1].name .. " " .. search.games[1].ip .. " " .. search.games[1].fleet,
    "1 Host 10.0.0.9 shapes", "one entry per host, with its fleet")
eq(search:poll(2), false, "nothing new")
eq(search:expire(4, 5), false, "recently seen game stays")
eq(search:expire(7, 5), true, "silent game dropped")
eq(#search.games, 0, "list empty")

-- L10n: every _("…") of main.lua is translated, and the catalog has no stale entries
loadstring = loadstring or load
local function msgids(path)
    local src = io.open(path):read("*a")
    local ids = {}
    for lit in src:gmatch('_%(%s*(".-[^\\]")%s*%)') do ids[loadstring("return " .. lit)()] = true end
    for lit in src:gmatch('_%(%s*%[%[(.-)%]%]%s*%)') do ids[lit] = true end
    return ids
end
local used = msgids("main.lua")
local cs = require("battleshipswifi/l10n/cs")
local missing, stale = {}, {}
for id in pairs(used) do if not cs[id] then missing[#missing + 1] = id end end
for id in pairs(cs) do if not used[id] then stale[#stale + 1] = id end end
table.sort(missing); table.sort(stale)
eq(table.concat(missing, " | "), "", "all strings translated to Czech")
eq(table.concat(stale, " | "), "", "no unused Czech translations")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
