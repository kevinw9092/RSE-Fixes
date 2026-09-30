-- Building collision diagnostics (read-only: nothing in the game is changed).
--
-- Investigates "walking through player-built pieces after joining or
-- teleporting". Player buildings reach each client through a per-player
-- building stream and are spawned in time slices, in several forms:
-- individual actors (BaseBuildingActor), instances in cell-wide instanced
-- meshes (CellBuildingManager / CellBuildingProxy), and lightweight pieces.
-- A snapshot answers, for the area around the player:
--   * the player's side: capsule collision, object type, responses, movement mode
--   * building actors: present? ghosted? collision on? would they block the capsule?
--   * building instances in instanced meshes: present? collision on? blocking?
--   * the spawn backlog: pieces still waiting to load or spawn
--   * the building settings that pace spawning and streaming
local B = {}

local SETTINGS = '/Script/Dominion.Default__BuildingSettings'
local PRIMITIVE = '/Script/Engine.PrimitiveComponent'
local ISM = '/Script/Engine.InstancedStaticMeshComponent'
local RESPONSE = { [0] = 'i', [1] = 'o', [2] = 'B' } -- ignore, overlap, block
local ENABLED = { [0] = 'none', [1] = 'query', [2] = 'physics', [3] = 'query+physics', [4] = 'probe', [5] = 'query+probe' }
local MOVEMENT = { [0] = 'none', [1] = 'walking', [2] = 'navwalking', [3] = 'falling', [4] = 'swimming', [5] = 'flying', [6] = 'custom' }

local function valid(o)
    local k = type(o)
    if k ~= 'userdata' and k ~= 'table' then return false end
    local ok, v = pcall(function() return o:IsValid() end) -- structs have no IsValid
    return ok and v == true
end
local function full(o) return valid(o) and o:GetFullName() or '' end
local function get(fn) local ok, v = pcall(fn) if ok then return v end return nil end
local function str(v)
    if type(v) == 'string' then return v end
    local s = get(function() return v:ToString() end)
    return type(s) == 'string' and s or '?'
end
local function short(o) return (full(get(function() return o:GetClass() end)):match('%.([%w_]+)$') or '?'):gsub('_C$', '') end
local function alive(a) return valid(a) and get(function() return a:IsActorBeingDestroyed() end) ~= true end

-- Elements of a TArray however this UE4SS build hands it over.
local function list(value)
    local out = {}
    if value == nil then return out end
    if type(value) == 'table' then
        for _, v in ipairs(value) do out[#out + 1] = v end
        return out
    end
    local n = get(function() return #value end)
    if type(n) == 'number' and n > 0 then
        for i = 1, n do
            local e = get(function() return value[i] end)
            if e ~= nil then out[#out + 1] = e end
        end
        if #out > 0 then return out end
    end
    pcall(function() value:ForEach(function(_, e) out[#out + 1] = get(function() return e:get() end) end) end)
    return out
end

-- Number of entries in a TMap/TSet/TArray, or nil if it cannot be read.
local function count(container)
    if container == nil then return nil end
    local n = get(function() return #container end)
    if type(n) == 'number' then return n end
    n = get(function() return container:Num() end)
    if type(n) == 'number' then return n end
    local c = 0
    local ok = pcall(function() container:ForEach(function() c = c + 1 end) end)
    return ok and c or nil
end

local function location(o, component)
    local v = get(function() return component and o:K2_GetComponentLocation() or o:K2_GetActorLocation() end)
    local x, y, z = get(function() return v.X end), get(function() return v.Y end), get(function() return v.Z end)
    if type(x) ~= 'number' then return nil end
    return { X = x, Y = y, Z = z }
end

local function metres(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz) / 100
end

-- Scene components of an actor (root first), through the attachment tree.
local function primitives(actor)
    local out, seen = {}, {}
    local function walk(comp, depth)
        if not valid(comp) or depth > 8 or seen[full(comp)] then return end
        seen[full(comp)] = true
        if get(function() return comp:IsA(PRIMITIVE) end) then out[#out + 1] = comp end
        local n = get(function() return comp:GetNumChildrenComponents() end) or 0
        for i = 0, n - 1 do walk(get(function() return comp:GetChildComponent(i) end), depth + 1) end
    end
    walk(get(function() return actor:K2_GetRootComponent() end), 0)
    return out
end

-- Collision of one primitive: { on, enabled, profile, obj, resp }.
local function collision(prim)
    local enabled = get(function() return prim:GetCollisionEnabled() end)
    local resp = {}
    for ch = 0, 31 do
        resp[ch] = RESPONSE[get(function() return prim:GetCollisionResponseToChannel(ch) end)] or '?'
    end
    return {
        enabled = enabled,
        on = enabled == 1 or enabled == 3 or enabled == 5, -- has query collision (movement sweeps use queries)
        profile = str(get(function() return prim:GetCollisionProfileName() end)),
        obj = get(function() return prim:GetCollisionObjectType() end),
        resp = resp,
    }
end

local function respString(c)
    local t = {}
    for ch = 0, 31 do t[#t + 1] = c.resp[ch] end
    return table.concat(t)
end

-- Would this primitive stop the player's capsule? Both sides must block each other.
local function blocks(piece, capsule)
    if not piece.on then return false, 'no collision (' .. tostring(ENABLED[piece.enabled] or piece.enabled) .. ')' end
    if not capsule.on then return false, 'player capsule has no collision' end
    local capsuleToPiece = capsule.resp[piece.obj]
    local pieceToCapsule = piece.resp[capsule.obj]
    if capsuleToPiece ~= 'B' then return false, 'player ignores channel ' .. tostring(piece.obj) .. ' (' .. tostring(capsuleToPiece) .. ')' end
    if pieceToCapsule ~= 'B' then return false, 'piece ignores player channel ' .. tostring(capsule.obj) .. ' (' .. tostring(pieceToCapsule) .. ')' end
    return true, 'blocks'
end

-- ------------------------------------------------------------------ player

-- Found every tick, so only property reads here: no game function is called
-- on objects that may belong to a world being torn down (a function call on
-- such an object can crash the game; a property read cannot write anywhere).
local function isLocal(pc)
    local player = get(function() return pc.Player end)
    return valid(player) and get(function() return player:IsA('/Script/Engine.LocalPlayer') end) == true
end

local cachedPC
local function localController()
    if valid(cachedPC) and isLocal(cachedPC) then return cachedPC end
    cachedPC = nil
    for _, pc in ipairs(FindAllOf('PlayerController') or {}) do
        if valid(pc) and isLocal(pc) then cachedPC = pc break end
    end
    return cachedPC
end

-- Drops every game object this module holds (called when a map loads: the
-- old world's objects are about to be destroyed, and IsValid() does not
-- reliably catch a destroyed object).
function B.forget()
    cachedPC = nil
end

function B.player()
    local pc = localController()
    local pawn = pc and get(function() return pc.Pawn end)
    if not valid(pawn) then return nil end
    return pawn, location(pawn)
end

-- 'walking', 'falling', ... for the local character.
function B.movementMode(pawn)
    return MOVEMENT[get(function() return pawn.CharacterMovement.MovementMode end)] or '?'
end

-- Player-built pieces use meshes from the building kit.
local function buildingMesh(path) return path:find('/Base_Building/', 1, true) ~= nil end

local function meshOf(comp)
    local m = get(function() return comp.StaticMesh end)
    if not valid(m) then m = get(function() return comp:GetStaticMesh() end) end
    return valid(m) and full(m):match('^%S+%s+(.+)$') or ''
end

-- The component the character stands on, as this machine sees it:
-- { label, key, building, mesh, comp }. key changes whenever the floor does.
function B.floorInfo(pawn)
    local movement = get(function() return pawn.CharacterMovement end)
    local floor = get(function() return movement.CurrentFloor end)
    local walkable = get(function() return floor.bWalkableFloor end)
    -- The character's movement base is the component it stands on (an engine
    -- function, no weak-pointer layout to guess). Floor hit as a fallback.
    local comp = get(function() return pawn:GetMovementBase() end)
    if not valid(comp) then comp = get(function() return pawn.BasedMovement.MovementBase end) end
    if not valid(comp) then comp = get(function() return floor.HitResult.Component:get() end) end
    if not valid(comp) then comp = get(function() return floor.HitResult.Component:Get() end) end
    if not valid(comp) then comp = get(function() return floor.HitResult.Component end) end
    if not valid(comp) then
        local hitActor = get(function() return floor.HitResult.HitObjectHandle.Actor:get() end)
        if not valid(hitActor) then hitActor = get(function() return floor.HitResult.HitObjectHandle.Actor end) end
        if valid(hitActor) then
            local label = short(hitActor) .. ' (actor only)'
            return { label = label, key = full(hitActor), building = false, mesh = '' }
        end
    end
    if not valid(comp) then
        local label = walkable and '(unknown component)' or 'nothing'
        return { label = label, key = label, building = false, mesh = '' }
    end
    local owner = get(function() return comp:GetOwner() end)
    local mesh = meshOf(comp)
    local building = buildingMesh(mesh)
    local name = short(owner) .. '.' .. (get(function() return comp:GetFName():ToString() end) or '?')
    local meshName = mesh:match('%.([%w_]+)$')
    local label = name .. (meshName and (' [' .. meshName .. ']') or '') .. (building and ' BUILDING' or '')
    return { label = label, key = full(comp), building = building, mesh = mesh, comp = comp }
end

-- ---------------------------------------------------------------- snapshot

-- Collects everything near the player. radius in metres.
function B.collect(radius)
    local pawn, here = B.player()
    if not pawn then return nil end
    local s = { at = here, pawn = full(pawn) }

    local capsulePrim = get(function() return pawn:K2_GetRootComponent() end)
    s.capsule = valid(capsulePrim) and collision(capsulePrim) or nil
    local movement = get(function() return pawn.CharacterMovement end)
    s.movement = MOVEMENT[get(function() return movement.MovementMode end)] or '?'
    -- What the character stands on, as this machine sees it.
    local floor = get(function() return movement.CurrentFloor end)
    s.floorWalkable = get(function() return floor.bWalkableFloor end)
    local info = B.floorInfo(pawn)
    s.floor = info.label
    s.floorInfo = info

    -- Individual building actors
    s.actors = {}
    for _, actor in ipairs(FindAllOf('BaseBuildingActor') or {}) do
        if alive(actor) then
            local d = metres(location(actor), here)
            if d <= radius then
                local entry = { name = short(actor), d = d, ghosted = get(function() return actor.bGhosted end),
                    hidden = get(function() return actor.bHidden end), parts = {} }
                for _, prim in ipairs(primitives(actor)) do
                    local c = collision(prim)
                    if s.capsule then c.blocks, c.why = blocks(c, s.capsule) end
                    c.name = get(function() return prim:GetFName():ToString() end) or '?'
                    entry.parts[#entry.parts + 1] = c
                end
                s.actors[#s.actors + 1] = entry
            end
        end
    end
    table.sort(s.actors, function(a, b) return a.d < b.d end)

    -- Pieces drawn as instances of cell-wide instanced meshes
    s.meshes = {}
    for _, cls in ipairs({ 'CellBuildingManager', 'CellBuildingProxy', 'LightweightBuildingPieceManager', 'GlobalBuildingManager' }) do
        for _, owner in ipairs(FindAllOf(cls) or {}) do
            if alive(owner) then
                for _, prim in ipairs(primitives(owner)) do
                    if get(function() return prim:IsA(ISM) end) then
                        local near = #list(get(function()
                            return prim:GetInstancesOverlappingSphere({ X = here.X, Y = here.Y, Z = here.Z }, radius * 100, true)
                        end))
                        if near > 0 then
                            local c = collision(prim)
                            if s.capsule then c.blocks, c.why = blocks(c, s.capsule) end
                            c.owner = cls
                            c.near = near
                            c.total = get(function() return prim:GetInstanceCount() end)
                            c.mesh = (full(get(function() return prim.StaticMesh end)):match('%.([%w_]+)$')) or '?'
                            s.meshes[#s.meshes + 1] = c
                        end
                    end
                end
            end
        end
    end

    -- Building-kit meshes on plain static mesh actors (how some pieces appear)
    s.kit = {}
    for _, actor in ipairs(FindAllOf('StaticMeshActor') or {}) do
        if alive(actor) then
            local d = metres(location(actor), here)
            if d <= radius then
                for _, prim in ipairs(primitives(actor)) do
                    local mesh = meshOf(prim)
                    if buildingMesh(mesh) then
                        local c = collision(prim)
                        if s.capsule then c.blocks, c.why = blocks(c, s.capsule) end
                        c.d, c.mesh = d, mesh:match('%.([%w_]+)$') or mesh
                        s.kit[#s.kit + 1] = c
                    end
                end
            end
        end
    end
    table.sort(s.kit, function(a, b) return a.d < b.d end)

    -- Spawn backlog and known piece actors
    s.backlogFrom = {}
    for _, cls in ipairs({ 'BuildingPieceActorSpawnService', 'BuildingSubsystem', 'BuildingPieceSubsystem' }) do
        local o = (FindAllOf(cls) or {})[1]
        if valid(o) then
            local load = count(get(function() return o.PieceIDToPendingLoad end))
            local spawn = count(get(function() return o.PieceIDToPendingSpawn end))
            s.backlogFrom[#s.backlogFrom + 1] = cls .. ((load or spawn) and '' or ' (maps unreadable)')
            s.pendingLoad = s.pendingLoad or load
            s.pendingSpawn = s.pendingSpawn or spawn
        end
    end
    local global = (FindAllOf('GlobalBuildingManager') or {})[1]
    s.pieceActors = valid(global) and count(get(function() return global.PieceIDToBuildingPieceActor end)) or nil
    return s
end

local function summary(s)
    local actorsNoColl, actorsPass, ghosted = 0, 0, 0
    for _, a in ipairs(s.actors) do
        if a.ghosted then ghosted = ghosted + 1 end
        local anyBlock, anyOn = false, false
        for _, c in ipairs(a.parts) do
            if c.on then anyOn = true end
            if c.blocks then anyBlock = true end
        end
        if not anyOn then actorsNoColl = actorsNoColl + 1 end
        if not anyBlock then actorsPass = actorsPass + 1 end
    end
    local instances, meshNoColl, meshPass = 0, 0, 0
    for _, m in ipairs(s.meshes) do
        instances = instances + m.near
        if not m.on then meshNoColl = meshNoColl + m.near end
        if not m.blocks then meshPass = meshPass + m.near end
    end
    local kitNoColl, kitPass = 0, 0
    for _, k in ipairs(s.kit) do
        if not k.on then kitNoColl = kitNoColl + 1 end
        if not k.blocks then kitPass = kitPass + 1 end
    end
    local cap = s.capsule
    return string.format(
        'player: collision %s, profile %s, channel %s, movement %s, standing on %s | piece actors: %d (no collision %d, not blocking %d) | '
            .. 'kit meshes: %d (no collision %d, not blocking %d) | mesh instances: %d in %d meshes (no collision %d, not blocking %d) | '
            .. 'pending load %s, spawn %s | piece actors known %s',
        cap and (ENABLED[cap.enabled] or tostring(cap.enabled)) or '?', cap and cap.profile or '?', cap and tostring(cap.obj) or '?', s.movement,
        tostring(s.floor) .. (s.floorWalkable == false and ' (not walkable)' or ''),
        #s.actors, actorsNoColl, actorsPass, #s.kit, kitNoColl, kitPass, instances, #s.meshes, meshNoColl, meshPass,
        tostring(s.pendingLoad), tostring(s.pendingSpawn), tostring(s.pieceActors))
end

-- Settings that pace building spawning and streaming.
function B.settings(out)
    local cdo = get(function() return StaticFindObject(SETTINGS) end)
    if not valid(cdo) then out('building settings: not found') return end
    local parts = {}
    for _, key in ipairs({
        'BuildingPieceSpawnSliceTimeMicroseconds', 'BuildingPieceDestroySliceTimeMicroseconds',
        'LoadingScreenBuildingPieceSpawnSliceTimeMicrosecondsOnline', 'LoadingScreenBuildingPieceSpawnSliceTimeMicrosecondsStandalone',
        'MaxReliableBufferPopulationForBuildingStreaming', 'SoftMaxBuildingStreamingRPCPayloadSizeBytes',
        'ServerSoftMaxBuildingStreamingBitrateDownloadMbps', 'ServerSoftMaxBuildingStreamingBitrateUploadMbps',
    }) do
        local v = get(function() return cdo[key] end)
        if v == nil then v = get(function() return cdo.BuildingReplicationStreamSettings[key] end) end
        parts[#parts + 1] = key .. '=' .. tostring(type(v) == 'userdata' and str(v) or v)
    end
    parts[#parts + 1] = 'ActiveCollisionProfileName=' .. str(get(function() return cdo.ActiveCollisionProfileName end))
    parts[#parts + 1] = 'InactiveCollisionProfileName=' .. str(get(function() return cdo.InactiveCollisionProfileName end))
    out('building settings: ' .. table.concat(parts, ', '))
end

-- Every building-kit mesh within `radius` of the snapshot position, whatever
-- object owns it: static mesh components and instanced meshes alike. Walks
-- every such component in the world, so it only runs in full reports.
function B.deepScan(out, s, radius)
    local seen, groups, order = {}, {}, {}
    local CLOSE = 5
    local close, kitISM, kitOrder = {}, {}, {}
    local center = { X = s.at.X, Y = s.at.Y, Z = s.at.Z }
    local scanned = 0
    for _, cls in ipairs({ 'StaticMeshComponent', 'InstancedStaticMeshComponent', 'HierarchicalInstancedStaticMeshComponent' }) do
        for _, comp in ipairs(FindAllOf(cls) or {}) do
            local key = full(comp)
            if key ~= '' and not seen[key] then
                seen[key] = true
                scanned = scanned + 1
                local mesh = meshOf(comp)
                local isISM = get(function() return comp:IsA(ISM) end) == true
                -- Any mesh component close by, whatever its mesh: the deck must be among these.
                if not isISM then
                    local d = metres(location(comp, true), s.at)
                    if d <= CLOSE then close[#close + 1] = { comp = comp, d = d, mesh = mesh } end
                elseif mesh ~= '' and buildingMesh(mesh) then
                    -- Building-kit instanced meshes anywhere, distance aside.
                    local total = get(function() return comp:GetInstanceCount() end)
                    if type(total) == 'number' and total > 0 then
                        local owner = get(function() return comp:GetOwner() end)
                        local c = collision(comp)
                        local k = string.format('%s [%s] %s, profile %s, channel %s', short(owner), mesh:match('%.([%w_]+)$') or mesh,
                            ENABLED[c.enabled] or tostring(c.enabled), c.profile, tostring(c.obj))
                        if not kitISM[k] then kitISM[k] = 0 kitOrder[#kitOrder + 1] = k end
                        kitISM[k] = kitISM[k] + total
                    end
                end
                if mesh ~= '' and buildingMesh(mesh) then
                    local near, unknown = 0, false
                    if get(function() return comp:IsA(ISM) end) then
                        local hits = get(function() return comp:GetInstancesOverlappingSphere(center, radius * 100, true) end)
                        near = #list(hits)
                        if hits == nil then
                            -- The query could not be read: report the mesh anyway (distance unknown).
                            local total = get(function() return comp:GetInstanceCount() end)
                            if type(total) == 'number' and total > 0 then near, unknown = total, true end
                        end
                    else
                        near = metres(location(comp, true), s.at) <= radius and 1 or 0
                    end
                    if near > 0 then
                        local owner = get(function() return comp:GetOwner() end)
                        local c = collision(comp)
                        local blocking, why = false, 'no player capsule'
                        if s.capsule then blocking, why = blocks(c, s.capsule) end
                        local g = string.format('%s%s [%s] %s, profile %s, channel %s -> %s', unknown and '(distance unknown) ' or '', short(owner),
                            mesh:match('%.([%w_]+)$') or mesh, ENABLED[c.enabled] or tostring(c.enabled), c.profile, tostring(c.obj), why)
                        if not groups[g] then groups[g] = 0 order[#order + 1] = g end
                        groups[g] = groups[g] + near
                    end
                end
            end
        end
    end
    out(string.format('   building-kit meshes within %dm (searched %d mesh components): %d kinds', radius, scanned, #order))
    for i, g in ipairs(order) do
        if i > 30 then out('   ... ' .. (#order - 30) .. ' more') break end
        out(string.format('      %dx %s', groups[g], g))
    end
    -- Everything within CLOSE metres, nearest first.
    table.sort(close, function(a, b) return a.d < b.d end)
    out(string.format('   every mesh component within %dm: %d', CLOSE, #close))
    for i, e in ipairs(close) do
        if i > 40 then out('      ... ' .. (#close - 40) .. ' more') break end
        local owner = get(function() return e.comp:GetOwner() end)
        local c = collision(e.comp)
        local why = 'no player capsule'
        if s.capsule then local _, w = blocks(c, s.capsule) why = w end
        local folder = e.mesh:match('^(.*)/[^/]+$') or '?'
        out(string.format('      %.1fm %s.%s [%s] in %s: %s, profile %s, channel %s -> %s', e.d, short(owner),
            get(function() return e.comp:GetFName():ToString() end) or '?', e.mesh:match('%.([%w_]+)$') or 'no mesh', folder,
            ENABLED[c.enabled] or tostring(c.enabled), c.profile, tostring(c.obj), why))
    end
    -- Building-kit instanced meshes anywhere in the world.
    out(string.format('   building-kit instanced meshes anywhere: %d kinds', #kitOrder))
    for i, k in ipairs(kitOrder) do
        if i > 25 then out('      ... ' .. (#kitOrder - 25) .. ' more') break end
        out(string.format('      %d instances: %s', kitISM[k], k))
    end
end

-- Every primitive (anything that draws or collides) within `near` metres,
-- found by walking every object in the game: no class name is assumed, so
-- subclasses the other searches cannot name are included.
function B.everything(out, s, near)
    if type(ForEachUObject) ~= 'function' then out('   every object near you: ForEachUObject not available') return end
    local found, classes, walked = {}, {}, 0
    pcall(ForEachUObject, function(obj)
        walked = walked + 1
        if not get(function() return obj:IsA(PRIMITIVE) end) then return end
        local name = full(obj)
        if name == '' or name:find('Default__', 1, true) or name:find('_GEN_VARIABLE', 1, true) then return end
        local d = metres(location(obj, true), s.at)
        if d > near then return end
        local cls = short(obj)
        classes[cls] = (classes[cls] or 0) + 1
        found[#found + 1] = { comp = obj, d = d, cls = cls }
    end)
    table.sort(found, function(a, b) return a.d < b.d end)
    local names = {}
    for cls, n in pairs(classes) do names[#names + 1] = cls .. ' x' .. n end
    table.sort(names)
    out(string.format('   every primitive within %dm (walked %d objects): %d  [%s]', near, walked, #found, table.concat(names, ', ')))
    for i, e in ipairs(found) do
        if i > 40 then out('      ... ' .. (#found - 40) .. ' more') break end
        local owner = get(function() return e.comp:GetOwner() end)
        local c = collision(e.comp)
        local why = 'no player capsule'
        if s.capsule then local _, w = blocks(c, s.capsule) why = w end
        local mesh = meshOf(e.comp)
        local instances = get(function() return e.comp:GetInstanceCount() end)
        out(string.format('      %.1fm %s %s.%s%s%s: %s, profile %s, channel %s -> %s', e.d, e.cls, short(owner),
            get(function() return e.comp:GetFName():ToString() end) or '?',
            mesh ~= '' and (' [' .. (mesh:match('%.([%w_]+)$') or mesh) .. ']') or '',
            type(instances) == 'number' and (' (' .. instances .. ' instances)') or '',
            ENABLED[c.enabled] or tostring(c.enabled), c.profile, tostring(c.obj), why))
    end
end

-- The building system's own representation components: how many exist, and
-- the reflected properties of the ones nearest the player.
local REPRESENTATION = {
    'CellBuildingInstanceRepresentationComponent', 'CellBuildingStaticMeshComponentRepresentationComponent',
    'CellBuildingActorRepresentationComponent', 'CellBuildingUnmanagedActorRepresentationComponent', 'ISMPoolComponent',
}
local function describeValue(v)
    if v == nil then return 'nil' end
    local t = type(v)
    if t ~= 'userdata' and t ~= 'table' then return tostring(v) end
    if valid(v) then return full(v):gsub('^%S+%s+', ''):match('([^/]+)$') or full(v) end
    local s = get(function() return v:ToString() end)
    if type(s) == 'string' then return '"' .. s .. '"' end
    local n = get(function() return #v end)
    if type(n) == 'number' then return '[' .. n .. ' entries]' end
    return '(struct)'
end
function B.representations(out, s)
    for _, cls in ipairs(REPRESENTATION) do
        local all = FindAllOf(cls) or {}
        local list2 = {}
        for _, comp in ipairs(all) do
            if valid(comp) then
                local owner = get(function() return comp:GetOwner() end)
                list2[#list2 + 1] = { comp = comp, owner = owner, d = metres(location(owner), s.at) }
            end
        end
        table.sort(list2, function(a, b) return a.d < b.d end)
        out(string.format('   %s: %d', cls, #list2))
        for i = 1, math.min(2, #list2) do
            local e = list2[i]
            local props = {}
            pcall(function()
                e.comp:GetClass():ForEachProperty(function(prop)
                    local pname = get(function() return prop:GetFName():ToString() end)
                    if pname then
                        props[#props + 1] = pname .. '=' .. describeValue(get(function() return e.comp[pname] end))
                    end
                end)
            end)
            out(string.format('      nearest #%d: owner %s %.1fm | %s', i, short(e.owner), e.d, table.concat(props, ', '):sub(1, 900)))
        end
    end
end

-- Writes a snapshot. detail: also list pieces one by one (nearest first).
function B.report(out, label, radius, detail)
    local ok, s = pcall(B.collect, radius)
    if not ok then out(label .. ' failed: ' .. tostring(s)) return end
    if not s then out(label .. ': no local character') return end
    out(string.format('%s at (%.0f, %.0f, %.0f), radius %dm: %s', label, s.at.X, s.at.Y, s.at.Z, radius, summary(s)))
    if s.capsule and detail then
        out('   player capsule responses (channel 0..31, B block / o overlap / i ignore): ' .. respString(s.capsule))
    end
    if detail then
        for i, a in ipairs(s.actors) do
            if i > 45 then out('   ... ' .. (#s.actors - 45) .. ' more piece actors') break end
            local blocking = {}
            for _, c in ipairs(a.parts) do
                if c.blocks then blocking[#blocking + 1] = c.name .. ' (' .. c.profile .. ', channel ' .. tostring(c.obj) .. ')' end
            end
            out(string.format('   piece %s %.1fm: %d parts, blocking you: %s', a.name, a.d, #a.parts,
                #blocking > 0 and table.concat(blocking, ', ') or 'NONE'))
        end
    end
    local shown = 0
    for _, a in ipairs(s.actors) do
        for _, c in ipairs(a.parts) do
            if not c.blocks then
                if shown < (detail and 12 or 6) then
                    out(string.format('   actor %s %.1fm%s%s part %s: %s, profile %s, channel %s -> %s',
                        a.name, a.d, '', a.hidden and ' hidden' or '', c.name,
                        ENABLED[c.enabled] or tostring(c.enabled), c.profile, tostring(c.obj), tostring(c.why)))
                    if detail and shown < 3 then out('      responses: ' .. respString(c)) end
                end
                shown = shown + 1
            end
        end
    end
    for i, k in ipairs(s.kit) do
        if (detail or not k.blocks) and i <= (detail and 15 or 6) then
            out(string.format('   kit mesh %s %.1fm: %s, profile %s, channel %s -> %s',
                k.mesh, k.d, ENABLED[k.enabled] or tostring(k.enabled), k.profile, tostring(k.obj), tostring(k.why)))
        end
    end
    if detail and s.floorInfo and valid(s.floorInfo.comp) and s.capsule then
        local c = collision(s.floorInfo.comp)
        local ok, why = blocks(c, s.capsule)
        out(string.format('   floor %s: %s, profile %s, channel %s -> %s', s.floor, ENABLED[c.enabled] or tostring(c.enabled), c.profile, tostring(c.obj), why))
    end
    if detail then
        B.deepScan(out, s, radius)
        B.everything(out, s, 5)
        B.representations(out, s)
    end
    if detail then out('   backlog read from: ' .. (#s.backlogFrom > 0 and table.concat(s.backlogFrom, ', ') or 'no spawn service or subsystem found')) end
    for i, m in ipairs(s.meshes) do
        if detail or not m.blocks then
            if i <= (detail and 15 or 4) then
                out(string.format('   instances %d/%s of %s in %s: %s, profile %s, channel %s -> %s',
                    m.near, tostring(m.total), m.mesh, m.owner, ENABLED[m.enabled] or tostring(m.enabled), m.profile, tostring(m.obj), tostring(m.why)))
            end
        end
    end
end

return B
