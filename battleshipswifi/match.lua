--[[--
One match between two players: the state machine on top of the wire format.
Pure Lua: no KOReader modules, no sockets. main.lua passes in `send(line)`
and feeds received lines to receive().

Phases: "placing" (ships being placed, waiting for READY from both),
"battle", "over". The host picks who shoots first (START). A hit or a sunk
ship lets the shooter fire again; a miss passes the turn.

receive() and the local actions return an event table for the UI (or nil when
nothing visible changed); on a protocol error receive() returns nil, error.
Events: joined (fleet_changed when the guest had to take the host's fleet), peer_ready, start, incoming (opponent's shot), result (ours),
fleet, rematch_request, rematch, left, resumed. result and incoming carry the
sunk ship (sunk/won). `score` counts the games won against this opponent,
`stats` this game's shots (record()).

Resuming after a lost connection (see protocol.lua): the game lines each side
sends are kept in `log`, the ones received counted in `received`; resume()
(guest) and the RESUME/RESUMED handlers send again what the other side missed.
can_resume() says whether both sides know how (a battle has started, SESSION
exchanged).
]]

local Board = require("battleshipswifi/board")
local Protocol = require("battleshipswifi/protocol")

local M = {}

local Match = {}
Match.__index = Match

--- opts: role = "host" | "guest", name, send(line), rand (math.random),
-- fleet (a key of Board.FLEETS; the host's choice, the guest learns it from WELCOME)
function M.new(opts)
    local m = setmetatable({
        role = opts.role,
        fleet = Board.FLEETS[opts.fleet or ""] and opts.fleet or Board.DEFAULT_FLEET,
        name = Protocol.clean_name(opts.name),
        send_line = opts.send,
        rand = opts.rand or math.random,
        log = {}, -- game lines we sent (since the opponent joined)
        received = 0, -- game lines received
        started = false, -- a battle has started (with this opponent)
        score = { me = 0, peer = 0 }, -- games won against this opponent
    }, Match)
    if m.role == "host" then
        local chars, id = "abcdefghijklmnopqrstuvwxyz0123456789", {}
        for i = 1, 10 do
            local k = m.rand(#chars)
            id[i] = chars:sub(k, k)
        end
        -- with the time: math.random may start the same after every launch
        m.session = table.concat(id) .. string.format("%x", os.time())
    end
    m:reset()
    return m
end

-- Lines that change the game: counted, and sent again after a lost connection.
local GAME_LINES = { READY = true, START = true, SHOT = true, RESULT = true, FLEET = true, REMATCH = true }

function Match:reset()
    self.phase = "placing"
    self.board = Board.new(self.fleet)
    self.board:randomize(self.rand)
    self.target = Board.target()
    self.ready, self.peer_ready = false, false
    self.rematch, self.peer_rematch = false, false
    self.turn, self.pending, self.winner = nil, nil, nil
    self.last_fired, self.last_incoming = nil, nil
    -- this game's shots: count, hits (sunk ones too), the series of hits now and the longest
    self.stats = {
        me = { shots = 0, hits = 0, series = 0, best = 0 },
        peer = { shots = 0, hits = 0, series = 0, best = 0 },
    }
end

-- Counts a shot of "me" or "peer"; a won game goes to the score.
function Match:record(side, result)
    local st = self.stats[side]
    st.shots = st.shots + 1
    if result == "miss" then
        st.series = 0
    else
        st.hits = st.hits + 1
        st.series = st.series + 1
        st.best = math.max(st.best, st.series)
    end
    if result == "won" then self.score[side] = self.score[side] + 1 end
end

function Match:send(cmd, ...)
    local line = Protocol.line(cmd, ...)
    if GAME_LINES[cmd] then table.insert(self.log, line) end
    if self.send_line then self.send_line(line) end
end

-- Sends again our game lines after the first `n` (the ones the other side has).
function Match:send_again(n)
    for i = n + 1, #self.log do
        if self.send_line then self.send_line(self.log[i]) end
    end
end

--- Whether a lost connection can be resumed (else the game is over).
function Match:can_resume()
    return self.started and self.session ~= nil and (self.role == "guest" or self.peer_resumes == true)
end

--- Guest, connected again after a lost connection: asks to go on.
function Match:resume()
    self:send("RESUME", Protocol.VERSION, self.session, self.received, self.name)
end

--- Guest: introduce ourselves after connecting.
function Match:hello()
    self:send("HELLO", Protocol.VERSION, self.name)
end

function Match:ping()
    self:send("PING")
end

function Match:bye()
    self:send("BYE")
end

--- Host: the opponent left before the battle; wait for another one.
function Match:drop_peer()
    self.peer = nil
    self.peer_ready = false
    self.log, self.received, self.peer_resumes = {}, 0, nil
    self.score = { me = 0, peer = 0 }
end

function Match:begin(first)
    self.started = true
    self.phase = "battle"
    self.turn = first == self.role and "me" or "peer"
    return { type = "start", turn = self.turn }
end

function Match:maybe_start()
    if self.role ~= "host" or self.phase ~= "placing" then return nil end
    if not (self.peer and self.ready and self.peer_ready) then return nil end
    local first = self.rand(2) == 1 and "host" or "guest"
    self:send("START", first)
    return self:begin(first)
end

--- Confirms our fleet. Returns an event when the battle starts at once.
function Match:set_ready()
    if self.phase ~= "placing" or self.ready or not self.board:complete() then return nil end
    self.ready = true
    if self.peer then self:send("READY") end
    return self:maybe_start()
end

--- Our shot. Returns true when it was sent.
function Match:fire(x, y)
    if self.phase ~= "battle" or self.turn ~= "me" or self.pending then return false end
    if not self.target:can_fire(x, y) then return false end
    self.pending = { x, y }
    self:send("SHOT", x, y)
    return true
end

function Match:request_rematch()
    if self.phase ~= "over" or self.rematch then return nil end
    self.rematch = true
    self:send("REMATCH")
    if self.peer_rematch then
        self:reset()
        return { type = "rematch" }
    end
end

local function coords(words)
    local x, y = tonumber(words[1]), tonumber(words[2])
    if not x or not y or x % 1 ~= 0 or y % 1 ~= 0 or not Board.inside(x, y) then return nil end
    return x, y
end

local handlers = {}

function handlers:HELLO(words, rest)
    if self.role ~= "host" then return nil, "unexpected HELLO" end
    if self.peer then return nil, "already joined" end
    if tonumber(words[1]) ~= Protocol.VERSION then
        self:send("ERROR", "version")
        return nil, "version"
    end
    self.peer = Protocol.clean_name(rest:match("^%S+%s*(.*)$"))
    self.log, self.received, self.peer_resumes = {}, 0, nil
    self.score = { me = 0, peer = 0 }
    self:send("WELCOME", Protocol.VERSION, self.fleet, self.name)
    self:send("SESSION", self.session)
    if self.ready then self:send("READY") end
    return { type = "joined", name = self.peer }
end

function handlers:WELCOME(words, rest)
    if self.role ~= "guest" or self.peer then return nil, "unexpected WELCOME" end
    if tonumber(words[1]) ~= Protocol.VERSION then return nil, "version" end
    local fleet = words[2]
    if not Board.FLEETS[fleet or ""] then return nil, "bad WELCOME" end
    self.peer = Protocol.clean_name(rest:match("^%S+%s+%S+%s*(.*)$"))
    local changed = fleet ~= self.fleet
    if changed then
        -- the host plays another fleet: place that one
        self.fleet = fleet
        self:reset()
    end
    if self.ready then self:send("READY") end
    return { type = "joined", name = self.peer, fleet_changed = changed }
end

function handlers:SESSION(words)
    local id = words[1]
    if not id or not id:match("^%w+$") then return nil, "bad SESSION" end
    if self.role == "guest" then
        self.session = id
        self:send("SESSION", id) -- we can resume
    elseif id == self.session then
        self.peer_resumes = true
    end
    return nil
end

function handlers:RESUME(words, rest)
    local n = tonumber(words[3])
    if self.role ~= "host" or tonumber(words[1]) ~= Protocol.VERSION or words[2] ~= self.session
        or not self.started or not self.peer or not n or n % 1 ~= 0 or n < 0 or n > #self.log then
        self:send("ERROR", "resume")
        return nil, "resume"
    end
    local name = rest:match("^%S+%s+%S+%s+%S+%s*(.*)$")
    if name and name ~= "" then self.peer = Protocol.clean_name(name) end
    self:send("RESUMED", Protocol.VERSION, self.received)
    self:send_again(n)
    return { type = "resumed" }
end

function handlers:RESUMED(words)
    local n = tonumber(words[2])
    if self.role ~= "guest" or tonumber(words[1]) ~= Protocol.VERSION or not n or n % 1 ~= 0
        or n < 0 or n > #self.log then
        return nil, "bad RESUMED"
    end
    self:send_again(n)
    return { type = "resumed" }
end

function handlers:ERROR(words)
    return nil, words[1] or "error"
end

function handlers:READY()
    if self.phase ~= "placing" or not self.peer then return nil, "unexpected READY" end
    self.peer_ready = true
    return self:maybe_start() or { type = "peer_ready" }
end

function handlers:START(words)
    if self.role ~= "guest" or self.phase ~= "placing" or not (self.ready and self.peer_ready) then
        return nil, "unexpected START"
    end
    if words[1] ~= "host" and words[1] ~= "guest" then return nil, "bad START" end
    return self:begin(words[1])
end

function handlers:SHOT(words)
    if self.phase ~= "battle" or self.turn ~= "peer" then return nil, "not your turn" end
    local x, y = coords(words)
    if not x then return nil, "bad SHOT" end
    local result, ship = self.board:shoot(x, y)
    if not result then return nil, "bad SHOT" end
    self.last_incoming = { x, y }
    if ship then self:send("RESULT", x, y, result, Board.encode_ship(ship))
    else self:send("RESULT", x, y, result) end
    if result == "miss" then self.turn = "me" end
    self:record("peer", result)
    if result == "won" then
        self.phase, self.winner = "over", "peer"
    end
    return { type = "incoming", x = x, y = y, result = result, ship = ship }
end

function handlers:RESULT(words)
    local x, y = coords(words)
    local p = self.pending
    if not p or not x or p[1] ~= x or p[2] ~= y then return nil, "unexpected RESULT" end
    local result = words[3]
    local ship
    if result == "sunk" or result == "won" then
        ship = Board.decode_ship(words[4])
        if not ship then return nil, "bad RESULT" end
    elseif result ~= "miss" and result ~= "hit" then
        return nil, "bad RESULT"
    end
    self.pending = nil
    self.last_fired = { x, y }
    self.target:apply(x, y, result, ship)
    self:record("me", result)
    if result == "miss" then self.turn = "peer" end
    if result == "won" then
        self.phase, self.winner = "over", "me"
        self:send("FLEET", self.board:encode_fleet())
    end
    return { type = "result", x = x, y = y, result = result, ship = ship }
end

function handlers:FLEET(words)
    if self.phase ~= "over" then return nil, "unexpected FLEET" end
    local ships = {}
    for _i, w in ipairs(words) do
        local ship = Board.decode_ship(w)
        if ship then ships[#ships + 1] = ship end
    end
    self.target:reveal(ships)
    return { type = "fleet" }
end

function handlers:REMATCH()
    if self.phase ~= "over" then return nil end
    self.peer_rematch = true
    if self.rematch then
        self:reset()
        return { type = "rematch" }
    end
    return { type = "rematch_request" }
end

function handlers:BYE()
    return { type = "left" }
end

function handlers:PING()
    return nil
end

--- A line from the opponent.
function Match:receive(line)
    local cmd, words, rest = Protocol.parse(line)
    local handler = cmd and handlers[cmd]
    if not handler then return nil end -- unknown commands are ignored (newer versions)
    local ev, err = handler(self, words, rest)
    if GAME_LINES[cmd] and not err then self.received = self.received + 1 end
    return ev, err
end

-- Saving and restoring (surviving a restart of KOReader) ------------------------

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

-- The fields a snapshot keeps (plain values and tables, no functions).
local SAVED = { "role", "fleet", "name", "peer", "session", "started", "peer_resumes", "log", "received",
    "score", "stats", "phase", "ready", "peer_ready", "rematch", "peer_rematch", "turn", "pending", "winner",
    "last_fired", "last_incoming" }

--- The whole state as plain tables (for LuaSettings).
function Match:snapshot()
    local snap = {}
    for _i, k in ipairs(SAVED) do snap[k] = copy(self[k]) end
    snap.board = { ships = copy(self.board.ships), shots = copy(self.board.shots) }
    snap.target = { marks = copy(self.target.marks), ships = copy(self.target.ships), sunk = self.target.sunk }
    return snap
end

--- A match from snapshot(); opts: send(line), rand. nil when the snapshot is unusable.
function M.restore(snap, opts)
    if type(snap) ~= "table" or not Board.FLEETS[snap.fleet or ""] or (snap.role ~= "host" and snap.role ~= "guest")
        or type(snap.board) ~= "table" or type(snap.target) ~= "table" then
        return nil
    end
    local m = M.new{ role = snap.role, name = snap.name, fleet = snap.fleet, send = opts.send, rand = opts.rand }
    for _i, k in ipairs(SAVED) do
        if snap[k] ~= nil then m[k] = copy(snap[k]) end
    end
    m.board = Board.new(snap.fleet)
    m.board.ships = copy(snap.board.ships or {})
    for y = 0, Board.SIZE - 1 do m.board.shots[y] = copy((snap.board.shots or {})[y] or {}) end
    m.target = Board.target()
    for y = 0, Board.SIZE - 1 do m.target.marks[y] = copy((snap.target.marks or {})[y] or {}) end
    m.target.ships = copy(snap.target.ships or {})
    m.target.sunk = snap.target.sunk or 0
    for _i, ship in ipairs(m.board.ships) do
        if not Board.decode_ship(Board.encode_ship(ship)) then return nil end
    end
    return m
end

--- Whose turn it is: "me", "peer" or nil.
function Match:my_turn()
    return self.phase == "battle" and self.turn == "me" and not self.pending
end

return M
