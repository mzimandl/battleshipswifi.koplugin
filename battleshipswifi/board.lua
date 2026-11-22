--[[--
Battleships boards. Pure Lua: no KOReader modules.

Coordinates are 0-based: x = column (A–J), y = row (1–10).
A ship is { shape, x, y, rot, hits }: `shape` is a key of SHAPES, `rot` a
0-based index into its distinct orientations (rotations(shape): the quarter
turns, then the mirrored ones), (x, y) the top/left corner of its bounding box. Ships may not overlap or touch, not even
diagonally. Wire form: "x,y,shape,rot".
]]

local M = {}

M.SIZE = 10 -- the classic board; rules may make it bigger (SIZES)
M.SIZES = { 10, 12 }

--- Rules the host picks (protocol 4): size of the board, salvo (as many shots a
-- turn as ships afloat, see match.lua) and touch (ships may touch). Missing
-- fields get the classic values.
function M.rules(r)
    r = r or {}
    local size = (r.size == 12) and 12 or 10
    return { size = size, salvo = r.salvo == true, touch = r.touch == true }
end

--- Rules as one word for the wire: "10", "12s", "10t", "12st"…
function M.encode_rules(r)
    r = M.rules(r)
    return tostring(r.size) .. (r.salvo and "s" or "") .. (r.touch and "t" or "")
end

--- A word from encode_rules() back, or nil.
function M.decode_rules(word)
    local size, flags = (word or ""):match("^(%d+)([st]*)$")
    size = tonumber(size)
    if size ~= 10 and size ~= 12 then return nil end
    return { size = size, salvo = flags:find("s", 1, true) ~= nil, touch = flags:find("t", 1, true) ~= nil }
end

-- Keys of squares in sets: y * KEY + x (any size).
local KEY = 100
M.KEY = KEY

--- Ship shapes: their squares as { x, y } offsets.
M.SHAPES = {
    line5 = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 }, { 4, 0 } },
    line4 = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 } },
    line3 = { { 0, 0 }, { 1, 0 }, { 2, 0 } },
    line2 = { { 0, 0 }, { 1, 0 } },
    -- ####
    -- .##.
    carrier = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 }, { 1, 1 }, { 2, 1 } },
    -- .#.
    -- ###
    -- .#.
    cruiser = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 }, { 1, 2 } },
    -- ####
    -- .#..
    battleship = { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 }, { 1, 1 } },
    -- #..
    -- ###
    destroyer = { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } },
    submarine = { { 0, 0 }, { 1, 0 } },
}

--- Fleets: shapes, biggest first (random placement goes in this order).
M.FLEETS = {
    classic = { "line5", "line4", "line3", "line3", "line2" },
    shapes = { "carrier", "cruiser", "battleship", "destroyer", "submarine", "submarine" },
}
M.FLEET_ORDER = { "classic", "shapes" }
M.DEFAULT_FLEET = "classic"

--- Whether (x, y) is on a board of `size` (default SIZE).
local function inside(x, y, size)
    size = size or M.SIZE
    return x >= 0 and y >= 0 and x < size and y < size
end
M.inside = inside

-- Squares moved so that the smallest x and y are 0, sorted by row, then column.
local function normalize(cells)
    local min_x, min_y = math.huge, math.huge
    for _i, c in ipairs(cells) do
        min_x, min_y = math.min(min_x, c[1]), math.min(min_y, c[2])
    end
    local out, w, h = {}, 0, 0
    for _i, c in ipairs(cells) do
        local x, y = c[1] - min_x, c[2] - min_y
        out[#out + 1] = { x, y }
        w, h = math.max(w, x + 1), math.max(h, y + 1)
    end
    table.sort(out, function(a, b) return a[2] < b[2] or (a[2] == b[2] and a[1] < b[1]) end)
    return out, w, h
end

local function key(cells)
    local parts = {}
    for _i, c in ipairs(cells) do parts[#parts + 1] = c[1] .. "," .. c[2] end
    return table.concat(parts, ";")
end

local rotation_cache = {}

--- Distinct orientations of a shape: list of { cells, w, h, mirrored, key },
-- cells normalized (see above): first the quarter turns clockwise (the first
-- one is the shape as defined), then those of the mirror image that are new
-- (mirrored = true; none for symmetric shapes). nil for an unknown shape.
-- (Protocol version 2 knew only the quarter turns: their indices stay.)
function M.rotations(shape)
    if rotation_cache[shape] then return rotation_cache[shape] end
    local base = M.SHAPES[shape]
    if not base then return nil end
    local out, seen = {}, {}
    local mirror = {}
    for _i, c in ipairs(base) do mirror[#mirror + 1] = { -c[1], c[2] } end
    for _side, start in ipairs({ base, mirror }) do
        local cells = start
        for _turn = 1, 4 do
            local norm, w, h = normalize(cells)
            local k = key(norm)
            if not seen[k] then
                seen[k] = true
                out[#out + 1] = { cells = norm, w = w, h = h, mirrored = start == mirror, key = k }
            end
            local turned = {}
            for _i, c in ipairs(norm) do turned[#turned + 1] = { -c[2], c[1] } end -- clockwise
            cells = turned
        end
    end
    rotation_cache[shape] = out
    return out
end

--- The orientation (rot) of a shape's mirror image of orientation `rot`
-- (flipped left to right); the same rot for a symmetric one.
function M.mirrored(shape, rot)
    local r = M.rotations(shape)[rot + 1]
    local flipped = {}
    for _i, c in ipairs(r.cells) do flipped[#flipped + 1] = { -c[1], c[2] } end
    local k = key((normalize(flipped)))
    for i, o in ipairs(M.rotations(shape)) do
        if o.key == k then return i - 1 end
    end
    return rot
end

local function rotation(ship)
    return M.rotations(ship.shape)[ship.rot + 1]
end

--- Number of squares of a shape.
function M.size(shape)
    return #M.SHAPES[shape]
end

--- Number of squares of a fleet.
function M.fleet_size(fleet)
    local n = 0
    for _i, shape in ipairs(M.FLEETS[fleet]) do n = n + M.size(shape) end
    return n
end

--- Squares of a ship: list of { x, y }.
function M.cells(ship)
    local out = {}
    for _i, c in ipairs(rotation(ship).cells) do out[#out + 1] = { ship.x + c[1], ship.y + c[2] } end
    return out
end

--- Width and height of a ship's bounding box.
function M.extent(ship)
    local r = rotation(ship)
    return r.w, r.h
end

local function covers(ship, x, y)
    local dx, dy = x - ship.x, y - ship.y
    for _i, c in ipairs(rotation(ship).cells) do
        if c[1] == dx and c[2] == dy then return true end
    end
    return false
end
M.covers = covers

--- Water squares around a ship (inside a board of `size`).
function M.around(ship, size)
    local out, seen = {}, {}
    for _i, c in ipairs(M.cells(ship)) do
        for dy = -1, 1 do
            for dx = -1, 1 do
                local x, y = c[1] + dx, c[2] + dy
                local k = y * KEY + x
                if inside(x, y, size) and not seen[k] and not covers(ship, x, y) then
                    seen[k] = true
                    out[#out + 1] = { x, y }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a[2] < b[2] or (a[2] == b[2] and a[1] < b[1]) end)
    return out
end

function M.encode_ship(ship)
    return string.format("%d,%d,%s,%d", ship.x, ship.y, ship.shape, ship.rot)
end

--- A ship from encode_ship(), on a board of `size` (default SIZE), or nil.
function M.decode_ship(s, size)
    local x, y, shape, rot = (s or ""):match("^(%d+),(%d+),(%l[%l%d]*),(%d+)$")
    if not x then return nil end
    local rotations = M.rotations(shape)
    if not rotations then return nil end
    local ship = { x = tonumber(x), y = tonumber(y), shape = shape, rot = tonumber(rot), hits = 0 }
    if ship.rot >= #rotations then return nil end
    local w, h = M.extent(ship)
    if not inside(ship.x, ship.y, size) or not inside(ship.x + w - 1, ship.y + h - 1, size) then return nil end
    return ship
end

-- Own board -------------------------------------------------------------------

local Board = {}
Board.__index = Board

--- fleet: a key of FLEETS (DEFAULT_FLEET when nil); rules: see M.rules().
function M.new(fleet, rules)
    rules = M.rules(rules)
    local b = setmetatable({ fleet = fleet or M.DEFAULT_FLEET, ships = {}, shots = {},
        size = rules.size, touch = rules.touch }, Board)
    for y = 0, b.size - 1 do b.shots[y] = {} end
    return b
end

--- Index of the ship on (x, y), or nil.
function Board:ship_at(x, y)
    for i, ship in ipairs(self.ships) do
        if covers(ship, x, y) then return i end
    end
end

--- Whether `ship` fits on the board without overlapping (or, unless the rules
-- allow it, touching) the others (ship `skip` ignored).
function Board:fits(ship, skip)
    local w, h = M.extent(ship)
    local size = self.size
    if not inside(ship.x, ship.y, size) or not inside(ship.x + w - 1, ship.y + h - 1, size) then return false end
    local taken = {}
    for i, other in ipairs(self.ships) do
        if i ~= skip then
            for _j, c in ipairs(M.cells(other)) do taken[c[2] * KEY + c[1]] = true end
        end
    end
    local reach = self.touch and 0 or 1
    for _i, c in ipairs(M.cells(ship)) do
        for dy = -reach, reach do
            for dx = -reach, reach do
                local x, y = c[1] + dx, c[2] + dy
                if inside(x, y, size) and taken[y * KEY + x] then return false end
            end
        end
    end
    return true
end

--- Places the whole fleet at random. rand(n) returns 1..n (math.random).
function Board:randomize(rand)
    rand = rand or math.random
    for _attempt = 1, 100 do
        self.ships = {}
        local ok = true
        for _i, shape in ipairs(M.FLEETS[self.fleet]) do
            local rotations = M.rotations(shape)
            local placed = false
            for _try = 1, 200 do
                local rot = rand(#rotations) - 1
                local r = rotations[rot + 1]
                local ship = {
                    shape = shape, rot = rot, hits = 0,
                    x = rand(self.size - r.w + 1) - 1, y = rand(self.size - r.h + 1) - 1,
                }
                if self:fits(ship) then
                    table.insert(self.ships, ship)
                    placed = true
                    break
                end
            end
            if not placed then ok = false; break end
        end
        if ok then return true end
    end
    return false
end

--- The square a ship is moved and turned by: its first square (top row, leftmost).
function M.anchor(ship)
    local c = rotation(ship).cells[1]
    return ship.x + c[1], ship.y + c[2]
end

--- Ship i turned to `rot` with its anchor square on (x, y), moved back onto
-- the board when that is near the edge; whether it fits there or not.
function Board:position(i, x, y, rot)
    local ship = self.ships[i]
    rot = rot or ship.rot
    local r = M.rotations(ship.shape)[rot + 1]
    local a = r.cells[1]
    local moved = { shape = ship.shape, rot = rot, hits = 0, x = x - a[1], y = y - a[2] }
    moved.x = math.max(0, math.min(moved.x, self.size - r.w))
    moved.y = math.max(0, math.min(moved.y, self.size - r.h))
    return moved
end

-- Ship i placed (see position()); nil when it doesn't fit there.
function Board:placed(i, x, y, rot)
    local moved = self:position(i, x, y, rot)
    if self:fits(moved, i) then return moved end
end

--- Moves ship i so that its anchor square is (x, y). Returns true when it fits.
function Board:move(i, x, y)
    local moved = self:placed(i, x, y)
    if not moved then return false end
    self.ships[i] = moved
    return true
end

-- Orientations of `shape` on the same side as `rot` (mirrored or not), in
-- clockwise order: after `rot`, or with `from`, starting at `from`.
local function turns_after(shape, rot, from)
    local rotations = M.rotations(shape)
    local side = rotations[rot + 1].mirrored
    local list = {}
    for i, r in ipairs(rotations) do
        if r.mirrored == side then list[#list + 1] = i - 1 end
    end
    local start = 1
    for k, v in ipairs(list) do
        if v == (from or rot) then start = from and k or k + 1 end
    end
    local out = {}
    for k = 0, #list - 1 do out[#out + 1] = list[(start - 1 + k) % #list + 1] end
    return out
end

-- Ship i turned clockwise (one or more quarter turns, the first that fits)
-- around its anchor square, or nil. Turning never mirrors it.
function Board:turned(i)
    local ship = self.ships[i]
    local x, y = M.anchor(ship)
    for _k, rot in ipairs(turns_after(ship.shape, ship.rot)) do
        if rot ~= ship.rot then
            local turned = self:placed(i, x, y, rot)
            if turned then return turned end
        end
    end
end

--- Whether ship i looks different in a mirror (L, T…; a line or a cross doesn't).
function Board:can_mirror(i)
    local ship = self.ships[i]
    return M.mirrored(ship.shape, ship.rot) ~= ship.rot
end

-- Ship i mirrored around its anchor square (turned further, if needed, to fit), or nil.
function Board:mirrored(i)
    local ship = self.ships[i]
    local flipped = M.mirrored(ship.shape, ship.rot)
    if flipped == ship.rot then return nil end
    local x, y = M.anchor(ship)
    for _k, rot in ipairs(turns_after(ship.shape, flipped, flipped)) do
        local moved = self:placed(i, x, y, rot)
        if moved then return moved end
    end
end

--- Mirrors ship i (see mirrored()). Returns true when it fits.
function Board:mirror(i)
    local moved = self:mirrored(i)
    if not moved then return false end
    self.ships[i] = moved
    return true
end

--- Whether ship i can turn where it is.
function Board:can_rotate(i)
    return self:turned(i) ~= nil
end

--- Turns ship i (see turned()). Returns true when it fits.
function Board:rotate(i)
    local turned = self:turned(i)
    if not turned then return false end
    self.ships[i] = turned
    return true
end

--- Water squares where tapping can't move ship i (it wouldn't fit):
-- blocked[y][x] = true.
function Board:blocked(i)
    local blocked = {}
    for y = 0, self.size - 1 do
        blocked[y] = {}
        for x = 0, self.size - 1 do
            if not self:ship_at(x, y) and not self:placed(i, x, y) then blocked[y][x] = true end
        end
    end
    return blocked
end

--- Whether the fleet is complete.
function Board:complete()
    return #self.ships == #M.FLEETS[self.fleet]
end

--- An opponent's shot. Returns "miss" | "hit" | "sunk" | "won" and the ship
-- (for sunk/won), or nil, "repeat" / "outside".
function Board:shoot(x, y)
    if not inside(x, y, self.size) then return nil, "outside" end
    if self.shots[y][x] then return nil, "repeat" end
    local i = self:ship_at(x, y)
    if not i then
        self.shots[y][x] = "miss"
        return "miss"
    end
    self.shots[y][x] = "hit"
    local ship = self.ships[i]
    ship.hits = ship.hits + 1
    if ship.hits < M.size(ship.shape) then return "hit" end
    for _i, other in ipairs(self.ships) do
        if other.hits < M.size(other.shape) then return "sunk", ship end
    end
    return "won", ship
end

--- Whether ship i is sunk.
function Board:sunk(i)
    local ship = self.ships[i]
    return ship.hits >= M.size(ship.shape)
end

function Board:encode_fleet()
    local parts = {}
    for _i, ship in ipairs(self.ships) do parts[#parts + 1] = M.encode_ship(ship) end
    return table.concat(parts, " ")
end

-- Target board (what we know of the opponent's) ------------------------------

local Target = {}
Target.__index = Target

--- marks[y][x]: nil (unknown), "miss", "near" (water next to a sunk ship, when
-- ships may not touch), "hit", "sunk". `ships` = sunk ships and, after the game,
-- the revealed fleet. rules: see M.rules().
function M.target(rules)
    rules = M.rules(rules)
    local t = setmetatable({ marks = {}, ships = {}, sunk = 0, size = rules.size, touch = rules.touch }, Target)
    for y = 0, t.size - 1 do t.marks[y] = {} end
    return t
end

function Target:can_fire(x, y)
    return inside(x, y, self.size) and self.marks[y][x] == nil
end

--- Records the result of our shot; `ship` comes with sunk/won.
function Target:apply(x, y, result, ship)
    if result == "miss" then
        self.marks[y][x] = "miss"
        return
    end
    self.marks[y][x] = "hit"
    if (result == "sunk" or result == "won") and ship then
        self.sunk = self.sunk + 1
        table.insert(self.ships, ship)
        for _i, c in ipairs(M.cells(ship)) do self.marks[c[2]][c[1]] = "sunk" end
        if not self.touch then -- the water around it is known only when ships may not touch
            for _i, c in ipairs(M.around(ship, self.size)) do
                if self.marks[c[2]][c[1]] == nil then self.marks[c[2]][c[1]] = "near" end
            end
        end
    end
end

--- Adds the opponent's revealed fleet (after the game); sunk ships are skipped.
function Target:reveal(ships)
    for _i, ship in ipairs(ships) do
        local known = false
        for _j, s in ipairs(self.ships) do
            if M.encode_ship(s) == M.encode_ship(ship) then known = true end
        end
        if not known then
            ship.revealed = true
            table.insert(self.ships, ship)
        end
    end
end

--- Index into ships of the ship covering (x, y), or nil.
function Target:ship_at(x, y)
    for i, ship in ipairs(self.ships) do
        if covers(ship, x, y) then return i end
    end
end

--- Column letter and row number: (0, 0) → "A1".
function M.label(x, y)
    return string.char(65 + x) .. tostring(y + 1)
end

return M
