-- Server side: on a dedicated server or a listen host, the players connected
-- from other machines. Arriving on a building (join or teleport), their game
-- has the building's collision while the server may not yet: the server's
-- movement then pulls them through it, and it never takes their position back.
--
-- Two parts, each switched separately:
--   watch (Debug): for a while after each arrival, log what the SERVER sees
--     under that player: height, movement mode, floor, every solid layer below.
--   hold (HoldArrivals, the fix): freeze each arriving player on the server
--     until building collision exists under them, place them just above its
--     top, and release them. Arriving on the ground releases at once; nothing
--     building-like within the time limit releases where they are.
--
-- On a client there are no other players' controllers, so this does nothing.
local B = require('buildings')
local S = {}

local WATCH = 20        -- seconds to watch after a join or teleport
local REPEAT = 3        -- seconds between watch lines while nothing changes
local GROUND = 10       -- cm: solid non-building ground this close under the feet = arrived on the ground
local REACH = 60        -- cm above the feet a building floor may be (the server may have let them sink a little)
local CLEARANCE = 2     -- cm above the floor's top to place them
local MOVE_NONE, MOVE_FALLING = 0, 3

local function get(fn) local ok, v = pcall(fn) if ok then return v end return nil end

local players = {} -- controller full name -> { name, pawnName, pawn, at, watch, hold }

-- Map loads: drop everything held, unread (the old world is being destroyed;
-- its pawns go with it, so no hold needs releasing).
function S.forget() players = {} end

local function playerName(pc)
    local n = get(function() return pc.PlayerState:GetPlayerName():ToString() end)
    if type(n) == 'string' and n ~= '' then return n end
    return get(function() return pc:GetFName():ToString() end) or '?'
end

-- A building-like layer: collision with no component (how the game's building
-- pieces show up in a trace) or a building-kit mesh.
local function isBuilding(l)
    return l.name:find('no component', 1, true) ~= nil or l.name:find('BB_', 1, true) ~= nil
end
local function buildingLayer(layers)
    for _, l in ipairs(layers or {}) do
        if isBuilding(l) then return l end
    end
end

-- ------------------------------------------------------------------ watch

local function startWatch(p, reason, log)
    p.watch = { from = os.clock(), reason = reason, z = p.at.Z, last = nil, lastT = -math.huge, found = nil, lowest = p.at.Z }
    log(string.format('server: %s arrived (%s) at (%.0f, %.0f, %.0f): watching what the server sees under them for %d s',
        p.name, reason, p.at.X, p.at.Y, p.at.Z, WATCH))
end

local function watchStep(p, log, layers, err)
    local w = p.watch
    local now = os.clock()
    local t = now - w.from
    if t > WATCH then
        log(string.format('server: %s watch (%s) ended: %s; lowest height %+.0f cm', p.name, w.reason,
            w.found and string.format('building collision under them from +%.1fs (%s)', w.found.t, w.found.name)
                or 'no building collision under them on the server',
            w.lowest - w.z))
        p.watch = nil
        return
    end
    w.lowest = math.min(w.lowest, p.at.Z)
    local deck = buildingLayer(layers)
    if deck and not w.found then w.found = { t = t, name = deck.name } end
    local floor = B.floorInfo(p.pawn)
    local mode = B.movementMode(p.pawn)
    local below = B.probeText(p.pawn, p.at, layers, err)
    local key = mode .. '|' .. floor.key .. '|' .. below
    if key == w.last and now - w.lastT < REPEAT then return end
    w.last, w.lastT = key, now
    log(string.format('server: %s +%.1fs (%s): height %+.0f cm, %s%s, standing on %s | below: %s',
        p.name, t, w.reason, p.at.Z - w.z, mode, p.hold and ' (held)' or '', floor.label, below))
end

-- ------------------------------------------------------------------- hold

local function setMode(pawn, mode)
    return pcall(function() pawn.CharacterMovement:SetMovementMode(mode, 0) end)
end
local function moveTo(pawn, at, z)
    return pcall(function() pawn:K2_SetActorLocation({ X = at.X, Y = at.Y, Z = z }, false, {}, true) end)
end

local function release(p, why, note, placeZ)
    local h = p.hold
    p.hold = nil
    if placeZ then moveTo(p.pawn, p.at, placeZ) end
    setMode(p.pawn, MOVE_FALLING) -- lands on whatever is under them now
    note(string.format('server: %s released after %.1fs: %s', p.name, os.clock() - h.from, why))
end

-- Starts a hold, or skips it when the player arrived on the ground.
local function startHold(p, layers, note)
    for _, l in ipairs(layers or {}) do
        if math.abs(l.z) <= GROUND and not isBuilding(l) then
            note(string.format('server: %s arrived on the ground (%s): no hold', p.name, l.name))
            return
        end
        if l.z < -GROUND then break end
    end
    if not setMode(p.pawn, MOVE_NONE) then return end
    p.hold = { from = os.clock(), z = p.at.Z }
    note(string.format('server: %s held on arrival at (%.0f, %.0f, %.0f) until building collision exists under them',
        p.name, p.at.X, p.at.Y, p.at.Z))
end

local function holdStep(p, layers, note, seconds)
    local h = p.hold
    -- The highest building floor at most REACH above the feet (a roof further
    -- up is not where they arrived).
    local best
    for _, l in ipairs(layers or {}) do
        if isBuilding(l) and l.z <= REACH and (not best or l.z > best.z) then best = l end
    end
    if best then
        release(p, string.format('building floor %+.0f cm (%s), placed on top', best.z, best.name), note,
            p.at.Z + best.z + CLEARANCE)
        return
    end
    if os.clock() - h.from > seconds then
        release(p, 'no building collision under them within ' .. seconds .. ' s, left in place', note)
        return
    end
    -- Keep them where they arrived: nothing may have moved them down meanwhile.
    if p.at.Z < h.z - 5 then moveTo(p.pawn, p.at, h.z) end
    setMode(p.pawn, MOVE_NONE)
end

-- ------------------------------------------------------------------- loop

-- Called every loop tick (250 ms). opts: { watch, hold, holdSeconds, teleport, log, note }
function S.step(opts)
    local seen = {}
    for _, e in ipairs(B.remotePlayers()) do
        seen[e.key] = true
        local p = players[e.key]
        if not p then
            p = {}
            players[e.key] = p
        end
        local previous = p.at
        local pawnName = B.fullName(e.pawn)
        p.pawn, p.at = e.pawn, e.at
        local arrival
        if pawnName ~= p.pawnName then
            p.pawnName, p.name, p.hold = pawnName, playerName(e.pc), nil
            arrival = 'join or respawn'
        elseif previous and not p.hold then
            local dx, dy, dz = e.at.X - previous.X, e.at.Y - previous.Y, e.at.Z - previous.Z
            local moved = math.sqrt(dx * dx + dy * dy + dz * dz) / 100
            if moved >= opts.teleport then arrival = string.format('teleport, %.0fm', moved) end
        end
        local layers, err
        if arrival or p.watch or p.hold then layers, err = B.probe(e.pawn, e.at) end
        if arrival then
            if opts.watch then startWatch(p, arrival, opts.log) end
            if opts.hold then startHold(p, layers, opts.note) end
        end
        if p.hold then
            if opts.hold then holdStep(p, layers, opts.note, opts.holdSeconds)
            else release(p, 'HoldArrivals turned off', opts.note) end
        end
        if p.watch then
            if opts.watch then watchStep(p, opts.log, layers, err) else p.watch = nil end
        end
    end
    for key in pairs(players) do
        if not seen[key] then players[key] = nil end
    end
end

-- "fixes_players": one line per player on another machine, now.
function S.report(log)
    local list = B.remotePlayers()
    if #list == 0 then
        log('server: no players from other machines here (this is a client, or nobody has joined)')
        return
    end
    for _, e in ipairs(list) do
        local floor = B.floorInfo(e.pawn)
        local p = players[e.key]
        log(string.format('server: %s at (%.0f, %.0f, %.0f), %s%s, standing on %s | below: %s', playerName(e.pc),
            e.at.X, e.at.Y, e.at.Z, B.movementMode(e.pawn), (p and p.hold) and ' (held)' or '', floor.label,
            B.probeText(e.pawn, e.at)))
    end
end

return S
