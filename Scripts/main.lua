-- RSE-Fixes (RuneScape Enhanced): fixes and diagnostics for RuneScape: Dragonwilds.
--
-- 0.1: diagnostics for walking through player-built pieces after joining a
-- world or teleporting. Nothing in the game is changed yet: the goal is to
-- find out which side fails (the pieces, their collision, or the player).
-- 0.2: the same question asked on the server (server.lua): the client was
-- shown to have the building's collision while falling through it.
-- 0.3: the first fix, on the server (HoldArrivals, off by default): hold each
-- arriving player until building collision exists under them.
local VERSION = '0.3.1'
local B = require('buildings')
local Server = require('server')

local TAG = '[RSE-Fixes] '
local function log(s) print(TAG .. tostring(s) .. '\n') end

-- ------------------------------------------------------------------ config

local cfg = {
    Debug = false,           -- off: no automatic reports or log lines (console command and button still log)
    AutoDiagnose = true,     -- with Debug on: snapshots after teleports and joins, without typing anything
    Radius = 15,             -- metres around the player to inspect
    TeleportDistance = 50,   -- metres moved within one check (1/4 s) that count as a teleport
    HoldArrivals = false,    -- server/host fix: hold arriving players until building collision exists under them
    HoldSeconds = 10,        -- longest hold before releasing them where they are
}

local function modRoot()
    local src = (debug.getinfo(1, 'S').source or ''):gsub('^@', '')
    return src:match('^(.*)[/\\]Scripts[/\\][^/\\]*$')
end

local function loadConfig()
    local root = modRoot()
    local f = root and io.open(root .. '\\config.txt', 'r')
    if not f then return end
    for line in f:lines() do
        local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
        if k and cfg[k] ~= nil then
            v = v:gsub('%s+[#;].*$', '')
            if type(cfg[k]) == 'boolean' then cfg[k] = v:lower() == 'true'
            elseif type(cfg[k]) == 'number' then cfg[k] = tonumber(v) or cfg[k]
            else cfg[k] = v end
        end
    end
    f:close()
end

local function clamp()
    cfg.Radius = math.max(5, math.min(60, tonumber(cfg.Radius) or 15))
    cfg.TeleportDistance = math.max(20, math.min(500, tonumber(cfg.TeleportDistance) or 50))
    cfg.HoldSeconds = math.max(2, math.min(30, tonumber(cfg.HoldSeconds) or 10))
end
loadConfig()
clamp()

-- Mod Menu (optional): live settings and the "Log building diagnostics" button.
local MODMENU_ID = 'RSE-Fixes'
local mmRev, mmAction
local function shared(key)
    local ok, v = pcall(function() return ModRef:GetSharedVariable('ModMenu.' .. MODMENU_ID .. '.' .. key) end)
    if ok then return v end
end

-- Automatic diagnostics (reports after joins and teleports, unstable
-- footing, the floor timeline, the server watch) run only with Debug on:
-- off, the mod does no work and writes nothing until asked.
local function auto() return cfg.Debug and cfg.AutoDiagnose end
local function note(s) if cfg.Debug then log(s) end end

-- ------------------------------------------------------------ snapshots

local queue = {} -- { at = os.clock(), label, detail }
local function schedule(label, delays, detail)
    local now = os.clock()
    for _, d in ipairs(delays) do
        queue[#queue + 1] = { at = now + d, label = string.format('%s +%ds', label, d), detail = detail }
    end
end

local function diagnose(reason)
    log('building diagnostics (' .. reason .. ')')
    B.settings(log)
    B.report(log, 'now', cfg.Radius, true)
    schedule('after command', { 2, 5, 10 }, false)
end

-- ------------------------------------------------------- unstable footing
-- Client and server disagreeing about a floor looks like this: the
-- character flips between walking and falling and gets snapped back up,
-- again and again. Catch that moment and log a full snapshot.
-- A normal jump is two switches and rises while "falling", so: at least 6
-- switches (three cycles), and a snap only counts when the character was
-- already coming down and then jumps up again while still in the air.
local WINDOW, FLIPS, SNAPS, COOLDOWN = 3, 6, 2, 15
local footing = {}   -- { t, mode, z }
local lastUnstable = -math.huge
local function watchFooting(pawn, here)
    local now = os.clock()
    footing[#footing + 1] = { t = now, mode = B.movementMode(pawn), z = here and here.Z }
    while #footing > 0 and now - footing[1].t > WINDOW do table.remove(footing, 1) end
    local flips, snaps = 0, 0
    for i = 2, #footing do
        local a, b = footing[i - 1], footing[i]
        if a.mode ~= b.mode and (a.mode == 'falling' or b.mode == 'falling') then flips = flips + 1 end
        local before = footing[i - 2]
        if before and before.z and a.z and b.z and before.mode == 'falling' and a.mode == 'falling'
            and a.z < before.z - 10 and b.z - a.z > 30 then
            snaps = snaps + 1
        end
    end
    if (flips >= FLIPS or snaps >= SNAPS) and now - lastUnstable > COOLDOWN then
        lastUnstable = now
        log(string.format('unstable footing: %d walking/falling switches and %d upward snaps in %ds', flips, snaps, WINDOW))
        B.report(log, 'unstable footing', cfg.Radius, true)
        schedule('after unstable footing', { 2 }, false)
    end
end

-- ----------------------------------------------------------------- loop

local lastPawn, lastAt

-- Floor timeline: for a while after a join or teleport, log every change of
-- what the character stands on, with the time since the event and the height
-- change. Shows when this machine gets a building's collision.
local FLOOR_WATCH = 15
local floorWatch -- { from = os.clock(), z = start height, key = last floor, reason }
local function startFloorWatch(reason, here)
    floorWatch = { from = os.clock(), z = here and here.Z or 0, key = nil, reason = reason }
end
local function watchFloor(pawn, here)
    if not floorWatch then return end
    local now = os.clock()
    if now - floorWatch.from > FLOOR_WATCH then
        log(string.format('floor watch (%s) ended', floorWatch.reason))
        floorWatch = nil
        return
    end
    local info = B.floorInfo(pawn)
    if info.key ~= floorWatch.key then
        floorWatch.key = info.key
        log(string.format('floor +%.1fs after %s: %s (height %+.0f cm, movement %s) | below: %s',
            now - floorWatch.from, floorWatch.reason, info.label, (here and here.Z or 0) - floorWatch.z, B.movementMode(pawn),
            B.probeText(pawn, here)))
    end
end
-- Map loads: drop every held game object and stay idle until the new world
-- has settled. Calling into an object of the old world after it is destroyed
-- crashes the game natively (a pcall cannot catch it).
local SETTLE = 10
local idleUntil = 0
local function forgetWorld(reason)
    B.forget()
    Server.forget()
    lastPawn, lastAt = nil, nil
    queue, footing, floorWatch = {}, {}, nil
    idleUntil = os.clock() + 60 -- the load-finished hook shortens this to SETTLE
    if reason then note('map loading: paused (' .. reason .. ')') end
end
if type(RegisterLoadMapPreHook) == 'function' then
    pcall(RegisterLoadMapPreHook, function() forgetWorld('load map') end)
end
if type(RegisterLoadMapPostHook) == 'function' then
    pcall(RegisterLoadMapPostHook, function()
        B.forget()
        idleUntil = os.clock() + SETTLE
        note('map loaded: resuming in ' .. SETTLE .. ' s')
    end)
end

local function step()
    if os.clock() < idleUntil then return end
    -- Mod Menu settings and button
    local rev = shared('rev')
    if type(rev) == 'number' and rev ~= mmRev then
        mmRev = rev
        for key in pairs(cfg) do
            local v = shared(key)
            if type(v) == type(cfg[key]) then cfg[key] = v end
        end
        clamp()
    end
    -- Button clicks change only ModMenu.<id>.action ("diagnose#<n>"), not rev.
    -- The first value seen is a baseline: a click from before this load is not replayed.
    local action = shared('action')
    if type(action) == 'string' and action ~= mmAction then
        local first = mmAction == nil
        mmAction = action
        if not first and action:match('^diagnose#') then diagnose('Mod Menu button') end
    elseif mmAction == nil then
        mmAction = '' -- no click yet: the next one is new
    end

    -- Joins (new character) and teleports (large jump within one check)
    local pawn, here = B.player()
    if pawn then
        local name = pawn:GetFullName()
        if auto() and name ~= lastPawn then
            log('character appeared (join, respawn or world change): watching nearby buildings')
            schedule('after join', { 1, 3, 6 }, false)
            startFloorWatch('join', here)
        elseif auto() and lastAt and here then
            local dx, dy, dz = here.X - lastAt.X, here.Y - lastAt.Y, here.Z - lastAt.Z
            local moved = math.sqrt(dx * dx + dy * dy + dz * dz) / 100
            if moved >= cfg.TeleportDistance then
                log(string.format('teleport detected (%.0fm): watching nearby buildings', moved))
                schedule('after teleport', { 1, 3, 6 }, false)
                startFloorWatch('teleport', here)
            end
        end
        lastPawn, lastAt = name, here
        if auto() then
            watchFooting(pawn, here)
            watchFloor(pawn, here)
        end
    else
        lastPawn, lastAt = nil, nil
    end

    -- On a server or listen host: players arriving from other machines.
    if auto() or cfg.HoldArrivals then
        local okServer, serverError = pcall(Server.step, {
            watch = auto(), hold = cfg.HoldArrivals, holdSeconds = cfg.HoldSeconds,
            teleport = cfg.TeleportDistance, log = log, note = note,
        })
        if not okServer then log('server: ' .. tostring(serverError)) end
    end

    -- Due snapshots
    local now = os.clock()
    local i = 1
    while i <= #queue do
        local q = queue[i]
        if now >= q.at then
            table.remove(queue, i)
            B.report(log, q.label, cfg.Radius, q.detail)
        else
            i = i + 1
        end
    end
end

-- One long-lived game-thread loop (see RSE-Transmog: per-call callbacks
-- corrupt some UE4SS builds' callback registry).
if type(LoopInGameThreadWithDelay) == 'function' then
    LoopInGameThreadWithDelay(250, function()
        local ok, err = pcall(step)
        if not ok then log('loop: ' .. tostring(err)) end
    end)
else
    LoopAsync(250, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(step)
            if not ok then log('loop: ' .. tostring(err)) end
        end)
        return false
    end)
end

-- "fixes_buildings" in the console: full snapshot now, compact ones at +2/+5/+10 s.
if type(RegisterConsoleCommandHandler) == 'function' then
    pcall(RegisterConsoleCommandHandler, 'fixes_buildings', function(_, _, ar)
        pcall(function() ar:Log(TAG .. 'v' .. VERSION .. ': building diagnostics written to UE4SS.log') end)
        ExecuteInGameThread(function()
            local ok, err = pcall(diagnose, 'console command')
            if not ok then log('diagnostics failed: ' .. tostring(err)) end
        end)
        return true
    end)
    -- "fixes_players" (on a host): what the server sees under each player from another machine.
    pcall(RegisterConsoleCommandHandler, 'fixes_players', function(_, _, ar)
        pcall(function() ar:Log(TAG .. 'v' .. VERSION .. ': player report written to UE4SS.log') end)
        ExecuteInGameThread(function()
            local ok, err = pcall(Server.report, log)
            if not ok then log('player report failed: ' .. tostring(err)) end
        end)
        return true
    end)
end

log('v' .. VERSION .. ' loaded (' .. (cfg.Debug and ('debug on, auto diagnostics ' .. (cfg.AutoDiagnose and 'on' or 'off'))
    or 'debug off: diagnostics only on request') .. ', hold arrivals ' .. (cfg.HoldArrivals and 'on' or 'off') .. ')')
