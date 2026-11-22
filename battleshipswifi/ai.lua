--[[--
The e-reader as an opponent. Pure Lua: no KOReader modules.

choose(level, target, fleet, rand) picks the square to fire at from what is
known of the opponent's board (a Board.target()):
- "easy": random squares; after a hit it fires next to it only half of the time.
- "normal": hunts on a checkerboard (every ship covers two neighbouring
  squares), and after a hit fires next to it, along the line of hits first.
- "hard": counts, for every square, the ways the ships still afloat could lie
  over it (consistent with the misses, the sunk ships and the rule that ships
  don't touch) and fires at the likeliest one; after a hit only placements
  through the hits count.

player(opts) plays a whole match: its own Match (role "guest") that talks to
the human's match by lines, like a device over Wi-Fi would.
]]

local Board = require("battleshipswifi/board")
local Match = require("battleshipswifi/match")

local M = {}

M.LEVELS = { "easy", "normal", "hard" }
M.DEFAULT_LEVEL = "normal"

local SIZE = Board.SIZE
local ORTHO = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function unknown(target, x, y)
    return Board.inside(x, y) and target.marks[y][x] == nil
end

local function pick(list, rand)
    if #list == 0 then return nil end
    return list[rand(#list)]
end

-- Squares hit but not (yet) part of a sunk ship.
local function open_hits(target)
    local hits = {}
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            if target.marks[y][x] == "hit" then hits[#hits + 1] = { x, y } end
        end
    end
    return hits
end

local function random_shot(target, rand, parity)
    local all, even = {}, {}
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            if target.marks[y][x] == nil then
                all[#all + 1] = { x, y }
                if (x + y) % 2 == 0 then even[#even + 1] = { x, y } end
            end
        end
    end
    return pick(parity and #even > 0 and even or all, rand)
end

-- Unknown squares next to the hits; `line` = those that continue a line of two hits.
local function next_to_hits(target, hits)
    local near, line, seen = {}, {}, {}
    for _i, h in ipairs(hits) do
        for _j, d in ipairs(ORTHO) do
            local x, y = h[1] + d[1], h[2] + d[2]
            local k = y * SIZE + x
            if unknown(target, x, y) and not seen[k] then
                seen[k] = true
                near[#near + 1] = { x, y }
                local bx, by = h[1] - d[1], h[2] - d[2]
                if Board.inside(bx, by) and target.marks[by][bx] == "hit" then line[#line + 1] = { x, y } end
            end
        end
    end
    return near, line
end

--- Shapes of the fleet not sunk yet.
function M.afloat(target, fleet)
    local left = {}
    for _i, shape in ipairs(Board.FLEETS[fleet]) do left[#left + 1] = shape end
    for _i, ship in ipairs(target.ships) do
        if not ship.revealed then
            for i, shape in ipairs(left) do
                if shape == ship.shape then
                    table.remove(left, i)
                    break
                end
            end
        end
    end
    return left
end

--- density[y][x]: in how many ways the ships afloat can cover the unknown square (x, y).
-- With open hits, only placements through them count (if there are any).
function M.density(target, fleet)
    local marks = target.marks
    local hits = open_hits(target)
    local function count(through_hits)
        local density, total = {}, 0
        for y = 0, SIZE - 1 do density[y] = {} end
        for _i, shape in ipairs(M.afloat(target, fleet)) do
            for _r, rot in ipairs(Board.rotations(shape)) do
                for oy = 0, SIZE - rot.h do
                    for ox = 0, SIZE - rot.w do
                        local ok, covered, mine = true, 0, {}
                        for _c, c in ipairs(rot.cells) do
                            local x, y = ox + c[1], oy + c[2]
                            local mark = marks[y][x]
                            if mark == "hit" then covered = covered + 1
                            elseif mark ~= nil then ok = false; break end
                            mine[y * SIZE + x] = true
                        end
                        if ok and (covered > 0) == through_hits then
                            -- a hit next to it, but not in it, would be another ship touching this one
                            for _c, c in ipairs(rot.cells) do
                                for dy = -1, 1 do
                                    for dx = -1, 1 do
                                        local x, y = ox + c[1] + dx, oy + c[2] + dy
                                        if Board.inside(x, y) and marks[y][x] == "hit" and not mine[y * SIZE + x] then
                                            ok = false
                                        end
                                    end
                                end
                                if not ok then break end
                            end
                        end
                        if ok and (covered > 0) == through_hits then
                            local weight = through_hits and covered or 1
                            for _c, c in ipairs(rot.cells) do
                                local x, y = ox + c[1], oy + c[2]
                                if marks[y][x] == nil then
                                    density[y][x] = (density[y][x] or 0) + weight
                                    total = total + weight
                                end
                            end
                        end
                    end
                end
            end
        end
        return density, total
    end
    if #hits > 0 then
        local density, total = count(true)
        if total > 0 then return density end
    end
    return (count(false))
end

local function likeliest(target, fleet, rand)
    local density = M.density(target, fleet)
    local best, top = {}, 0
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            local d = density[y][x] or 0
            if d > top then best, top = { { x, y } }, d
            elseif d == top and d > 0 then best[#best + 1] = { x, y } end
        end
    end
    return pick(best, rand)
end

--- The square to fire at: x, y (nil when there is none left).
function M.choose(level, target, fleet, rand)
    rand = rand or math.random
    local shot
    if level == "hard" then
        shot = likeliest(target, fleet, rand)
    else
        local hits = open_hits(target)
        if #hits > 0 and (level == "normal" or rand(2) == 1) then
            local near, line = next_to_hits(target, hits)
            shot = pick(level == "normal" and #line > 0 and line or near, rand)
        end
        shot = shot or random_shot(target, rand, level == "normal")
    end
    shot = shot or random_shot(target, rand, false)
    if shot then return shot[1], shot[2] end
end

-- Player ----------------------------------------------------------------------

local Player = {}
Player.__index = Player

--- opts: level, name, rand, delay (seconds before each shot, so that the
-- human sees what happened), restore (a snapshot of its match, after a restart;
-- nil is returned when it is unusable). Lines for the human's match come out of poll().
function M.player(opts)
    local p = setmetatable({
        level = opts.level or M.DEFAULT_LEVEL,
        rand = opts.rand or math.random,
        delay = opts.delay or 0,
        inbox = {},
        outbox = {},
    }, Player)
    local send = function(line) table.insert(p.outbox, (line:gsub("\n$", ""))) end
    if opts.restore then -- a snapshot of its match (Match:snapshot())
        p.match = Match.restore(opts.restore, { send = send, rand = p.rand })
        if not p.match then return nil end
    else
        p.match = Match.new{ role = "guest", name = opts.name, rand = p.rand, send = send }
        p.match:hello()
    end
    return p
end

--- A line from the human's match (handled at the next poll()).
function Player:deliver(line)
    table.insert(self.inbox, (line:gsub("\n$", "")))
end

--- Handles the delivered lines and plays (gets ready, fires, agrees to play
-- again). Returns the lines for the human's match, and an error, if any.
function Player:poll(now)
    local m = self.match
    while #self.inbox > 0 do
        local _ev, err = m:receive(table.remove(self.inbox, 1))
        if err then return self:flush(), err end
    end
    if m.phase == "placing" and m.peer and not m.ready then
        m:set_ready()
    elseif m.phase == "over" and m.peer_rematch and not m.rematch then
        m:request_rematch()
    elseif m:my_turn() then
        self.turn_since = self.turn_since or now
        if now - self.turn_since >= self.delay then
            self.turn_since = nil
            local x, y = M.choose(self.level, m.target, m.fleet, self.rand)
            if x then m:fire(x, y) end
        end
    else
        self.turn_since = nil
    end
    return self:flush()
end

function Player:flush()
    local out = self.outbox
    self.outbox = {}
    return out
end

return M
