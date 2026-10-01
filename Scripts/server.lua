-- Server side: on a dedicated server or a listen host, the players connected
-- from other machines. Arriving on a building (join or teleport), their game
-- has the building's collision while the server may not yet: the server's
-- movement then pulls them through it, and it never takes their position back.
--
-- Two parts, each switched separately:
--   watch (Debug): for a while after each arrival, log what the SERVER sees
--     under that player: height, movement mode, floor, every solid layer below.
--   hold (HoldArrivals, the fix): freeze each arriving player on the server
--     (the game's own FreezeCharacter) until building collision exists under
--     them, place them just above its top, and release them. Arriving on the
--     ground releases at once; nothing building-like within the time limit
--     releases where they are. While the game itself holds them (loading the
--     world around them, teleporting, frozen) the hold waits and starts when
--     the game lets go.
--
-- Arrivals: a new pawn (join, respawn), the end of the game's own teleport
-- (ADominionPlayerCharacter:IsTeleporting(), polled), or a jump of
-- TeleportDistance within one check (teleports the flag misses).
-- Not used: Client_OnEveryCellsLoadedForTheFirstTime and
-- Multicast_NotifyPlayTeleportCompleteVFX as hooks. A hooked native RPC runs
-- its hook only where its body runs: a Client_ RPC called on the server is
-- only sent, so the hook would never fire there; the multicast fires only
-- for teleports that play the end effect. The flags polled above cover both.
--
-- On a client there are no other players' controllers, so this does nothing.
local B = require('buildings')
local S = {}

local WATCH = 20        -- seconds to watch after a join or teleport
local REPEAT = 3        -- seconds between watch lines while nothing changes
local GROUND = 10       -- cm: solid non-building ground this close under the feet = arrived on the ground
local REACH = 60        -- cm above the feet a building floor may be (the server may have let them sink a little)
local CLEARANCE = 2     -- cm above the floor's top to place them
local LANDING = 500     -- cm below the feet something solid must be before letting them fall
local HOLD_CAP = 60     -- seconds: longest hold even with nothing under them yet; longest wait on the world-loaded flag
local MOVE_WALKING, MOVE_FALLING = 1, 3
local MODE_NAME = { [0] = 'none', [1] = 'walking', [2] = 'navwalking', [3] = 'falling', [4] = 'swimming', [5] = 'flying', [6] = 'custom' }

local function get(fn) local ok, v = pcall(fn) if ok then return v end return nil end

local players = {} -- controller full name -> { name, pawnName, pawn, at, teleporting, watch, wait, hold }

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
-- Building pieces trace as a component-less hit with a real instance number
-- (#3083 ...); the landscape also has no component but is instance #0, so it
-- does not count (0.3.0 did count it).
local function isBuilding(l)
    if l.name:find('BB_', 1, true) then return true end
    return l.name:find('no component', 1, true) ~= nil and type(l.item) == 'number' and l.item > 0
end
-- The highest thing solid to land on, from REACH above the feet (they may
-- have sunk a little before the hold caught them) to LANDING below them.
local function solidBelow(layers)
    local best
    for _, l in ipairs(layers or {}) do
        if l.z <= REACH and l.z >= -LANDING and (not best or l.z > best.z) then best = l end
    end
    return best
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

-- The freeze: UDominionMovementComponent:FreezeCharacter(LockerObject) and
-- UnFreezeCharacter(LockerObject) keep a lock per locker object; the
-- character stays frozen while any lock is held, and only the object that
-- took a lock gives it back. The locker is the player's controller: it exists
-- on the server for as long as they are connected (through respawns), so it
-- cannot vanish with our lock still held; the game is unlikely to lock with
-- it; and a hold starts only while nothing holds them (IsCharacterFrozen
-- false). It is the controller found this tick (B.remotePlayers), never kept.
local function frozen(pawn) return get(function() return pawn.CharacterMovement:IsCharacterFrozen() end) end
local function freeze(pawn, locker) return pcall(function() pawn.CharacterMovement:FreezeCharacter(locker) end) end
local function unfreeze(pawn, locker) return pcall(function() pawn.CharacterMovement:UnFreezeCharacter(locker) end) end
-- The 0.3 hold, kept as the fallback when the freeze does not take on this
-- server: movement mode none, re-applied every tick, falling on release.
local MOVE_NONE = 0
local function setMode(pawn, mode) return pcall(function() pawn.CharacterMovement:SetMovementMode(mode, 0) end) end
local function moveTo(pawn, at, z)
    return pcall(function() pawn:K2_SetActorLocation({ X = at.X, Y = at.Y, Z = z }, false, {}, true) end)
end

-- Lets them go: placed on top of what was found (if anything), then the lock
-- is given back. Their speed is left alone: the server's Velocity is
-- overwritten by the next move from their game (0.3.1 cleared it in vain).
local function release(p, pc, why, note, placeZ)
    local h = p.hold
    p.hold = nil
    if placeZ then moveTo(p.pawn, p.at, placeZ) end
    unfreeze(p.pawn, pc)
    if h.modeHold then setMode(p.pawn, MOVE_FALLING) end
    note(string.format('server: %s released after %.1fs: %s%s', p.name, os.clock() - h.from, why,
        frozen(p.pawn) == true and ' (still frozen: the game holds a lock too)' or ''))
end

-- Why the game itself is holding them, or nil. On a join the game keeps the
-- character still until the world around it has loaded; 0.3.0 took that over
-- and let a player fall after 10 s into ground that did not exist yet (a death
-- on 2026-09-30, 266 m below the spawn with the terrain above).
-- bWorldLoadedAroundCharacter is trusted for HOLD_CAP seconds: should it
-- never turn true on this server, holds still happen after that.
local function gameHolding(p, waited)
    if p.teleporting then return 'teleporting' end
    if frozen(p.pawn) == true then return 'frozen' end
    local mode = get(function() return p.pawn.CharacterMovement.MovementMode end)
    if mode ~= MOVE_WALKING and mode ~= MOVE_FALLING then return 'movement ' .. (MODE_NAME[mode] or tostring(mode)) end
    if waited <= HOLD_CAP and get(function() return p.pawn.bWorldLoadedAroundCharacter end) == false then
        return 'world around them not loaded'
    end
end

-- Starts a hold, or skips it: arrived on the ground.
local function startHold(p, pc, layers, note)
    for _, l in ipairs(layers or {}) do
        if math.abs(l.z) <= GROUND and not isBuilding(l) then
            note(string.format('server: %s arrived on the ground (%s): no hold', p.name, l.name))
            return
        end
        if l.z < -GROUND then break end
    end
    local okFreeze = freeze(p.pawn, pc)
    -- The freeze did not take (or is not available): hold the 0.3 way instead.
    local modeHold = not okFreeze or frozen(p.pawn) == false
    if modeHold and not setMode(p.pawn, MOVE_NONE) then
        if okFreeze then unfreeze(p.pawn, pc) end
        return
    end
    p.hold = { from = os.clock(), z = p.at.Z, modeHold = modeHold }
    note(string.format('server: %s held on arrival at (%.0f, %.0f, %.0f) until building collision exists under them%s',
        p.name, p.at.X, p.at.Y, p.at.Z, modeHold and ' (the freeze did not take: holding by movement mode)' or ''))
end

-- An arrival: hold now, or wait while the game holds them itself.
-- probe(): the layers under them (traced once per tick, when first needed).
local function arrive(p, pc, why, note, probe)
    local game = gameHolding(p, 0)
    if game then
        p.wait = { from = os.clock(), why = why }
        note(string.format('server: %s arrived (%s) while the game holds them itself (%s): waiting for it to let go',
            p.name, why, game))
        return
    end
    startHold(p, pc, probe(), note)
end

local function waitStep(p, pc, note, probe)
    local waited = os.clock() - p.wait.from
    if gameHolding(p, waited) then return end
    local flag = get(function() return p.pawn.bWorldLoadedAroundCharacter end)
    note(string.format('server: %s let go by the game after %.1fs (%s)%s', p.name, waited, p.wait.why,
        flag == false and ' (world-loaded flag still false; not waited for longer)' or ''))
    p.wait = nil
    startHold(p, pc, probe(), note)
end

local function holdStep(p, pc, layers, note, seconds)
    local h = p.hold
    -- The highest building floor at most REACH above the feet (a roof further
    -- up is not where they arrived).
    local best
    for _, l in ipairs(layers or {}) do
        if isBuilding(l) and l.z <= REACH and (not best or l.z > best.z) then best = l end
    end
    if best then
        release(p, pc, string.format('building floor %+.0f cm (%s), placed on top', best.z, best.name), note,
            p.at.Z + best.z + CLEARANCE)
        return
    end
    local held = os.clock() - h.from
    if held > seconds then
        -- Never let them fall into nothing: the world under them may still be
        -- loading. Keep holding until something solid is there (HOLD_CAP).
        local ground = solidBelow(layers)
        if ground then
            release(p, pc, string.format('no building collision under them within %d s; landing on %s (%+.0f cm)',
                seconds, ground.name, ground.z), note, ground.z > 0 and (p.at.Z + ground.z + CLEARANCE) or nil)
            return
        end
        if held > HOLD_CAP then
            release(p, pc, 'still nothing solid under them after ' .. HOLD_CAP .. ' s; released anyway', note)
            return
        end
        if not h.waitNoted then
            h.waitNoted = true
            note(string.format('server: %s has nothing solid under them yet after %d s: still holding', p.name, seconds))
        end
    end
    -- Keep them where they arrived: nothing may have moved them down meanwhile.
    if p.at.Z < h.z - 5 then moveTo(p.pawn, p.at, h.z) end
    if h.modeHold then setMode(p.pawn, MOVE_NONE) end
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
        local wasTeleporting = p.teleporting
        p.teleporting = get(function() return e.pawn:IsTeleporting() end) == true
        local arrival
        if pawnName ~= p.pawnName then
            p.pawnName, p.name, p.hold, p.wait = pawnName, playerName(e.pc), nil, nil
            arrival = 'join or respawn'
        elseif not p.hold and not p.wait then
            if wasTeleporting and not p.teleporting then
                arrival = 'teleport'
            elseif previous and not p.teleporting then
                -- The jump: teleports the game's flag does not report.
                local dx, dy, dz = e.at.X - previous.X, e.at.Y - previous.Y, e.at.Z - previous.Z
                local moved = math.sqrt(dx * dx + dy * dy + dz * dz) / 100
                if moved >= opts.teleport then arrival = string.format('teleport, %.0fm', moved) end
            end
        end
        local probed, layers, err = false, nil, nil
        local function probe()
            if not probed then probed, layers, err = true, B.probe(e.pawn, e.at) end
            return layers
        end
        if arrival then
            if opts.watch then startWatch(p, arrival, opts.log) end
            if opts.hold then arrive(p, e.pc, arrival, opts.note, probe) end
        elseif p.wait then
            if opts.hold then waitStep(p, e.pc, opts.note, probe) else p.wait = nil end
        end
        if p.hold then
            if opts.hold then holdStep(p, e.pc, probe(), opts.note, opts.holdSeconds)
            else release(p, e.pc, 'HoldArrivals turned off', opts.note) end
        end
        if p.watch then
            if opts.watch then
                local below = probe()
                watchStep(p, opts.log, below, err)
            else
                p.watch = nil
            end
        end
    end
    for key in pairs(players) do
        if not seen[key] then players[key] = nil end
    end
end

-- "fixes_players": one line per player on another machine, now.
function S.report(log)
    local list = B.remotePlayers(true)
    if #list == 0 then
        log('server: no players from other machines here (this is a client, or nobody has joined)')
        return
    end
    for _, e in ipairs(list) do
        local floor = B.floorInfo(e.pawn)
        local p = players[e.key]
        log(string.format('server: %s at (%.0f, %.0f, %.0f), %s%s, standing on %s | below: %s', playerName(e.pc),
            e.at.X, e.at.Y, e.at.Z, B.movementMode(e.pawn),
            (p and p.hold) and ' (held)' or (p and p.wait) and ' (waiting for the game to let go)' or '', floor.label,
            B.probeText(e.pawn, e.at)))
    end
end

return S
