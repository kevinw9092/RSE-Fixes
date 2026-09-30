-- Server-side watch (read-only): on a dedicated server or a listen host, the
-- players connected from other machines. Their game has a building's
-- collision while the server may not (yet): arriving on a building (join or
-- teleport) the server's movement then pulls them through it, and their game
-- jitters between the two. For a while after each arrival this logs what the
-- SERVER sees under that player: height, movement mode, floor, and every
-- solid layer below (traced with the player's collision profile).
--
-- On a client there are no other players' controllers, so this does nothing.
local B = require('buildings')
local S = {}

local WATCH = 20   -- seconds to watch after a join or teleport
local REPEAT = 3   -- seconds between lines while nothing changes

local function get(fn) local ok, v = pcall(fn) if ok then return v end return nil end

local players = {} -- controller full name -> { name, pawnName, pawn, at, watch }

-- Map loads: drop everything held, unread (the old world is being destroyed).
function S.forget() players = {} end

local function playerName(pc)
    local n = get(function() return pc.PlayerState:GetPlayerName():ToString() end)
    if type(n) == 'string' and n ~= '' then return n end
    return get(function() return pc:GetFName():ToString() end) or '?'
end

-- A building-like layer: collision with no component (how the game's building
-- pieces showed up on the client) or a building-kit mesh.
local function buildingLayer(layers)
    for _, l in ipairs(layers or {}) do
        if l.name:find('no component', 1, true) or l.name:find('BB_', 1, true) then return l end
    end
end

local function startWatch(p, reason, log)
    p.watch = { from = os.clock(), reason = reason, z = p.at.Z, last = nil, lastT = -math.huge, found = nil, lowest = p.at.Z }
    log(string.format('server: %s arrived (%s) at (%.0f, %.0f, %.0f): watching what the server sees under them for %d s',
        p.name, reason, p.at.X, p.at.Y, p.at.Z, WATCH))
end

local function watchStep(p, log)
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
    local layers, err = B.probe(p.pawn, p.at)
    local deck = buildingLayer(layers)
    if deck and not w.found then w.found = { t = t, name = deck.name } end
    local floor = B.floorInfo(p.pawn)
    local mode = B.movementMode(p.pawn)
    local below = B.probeText(p.pawn, p.at, layers, err)
    local key = mode .. '|' .. floor.key .. '|' .. below
    if key == w.last and now - w.lastT < REPEAT then return end
    w.last, w.lastT = key, now
    log(string.format('server: %s +%.1fs (%s): height %+.0f cm, %s, standing on %s | below: %s',
        p.name, t, w.reason, p.at.Z - w.z, mode, floor.label, below))
end

-- Called every loop tick (250 ms).
function S.step(log, teleportMetres)
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
        if pawnName ~= p.pawnName then
            p.pawnName = pawnName
            p.name = playerName(e.pc)
            startWatch(p, 'join or respawn', log)
        elseif previous then
            local dx, dy, dz = e.at.X - previous.X, e.at.Y - previous.Y, e.at.Z - previous.Z
            local moved = math.sqrt(dx * dx + dy * dy + dz * dz) / 100
            if moved >= teleportMetres then startWatch(p, string.format('teleport, %.0fm', moved), log) end
        end
        if p.watch then watchStep(p, log) end
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
        log(string.format('server: %s at (%.0f, %.0f, %.0f), %s, standing on %s | below: %s', playerName(e.pc),
            e.at.X, e.at.Y, e.at.Z, B.movementMode(e.pawn), floor.label, B.probeText(e.pawn, e.at)))
    end
end

return S
