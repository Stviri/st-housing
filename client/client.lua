-- Main client file
-- Handles prop spawning loop, vegetation, blips, ox_target

local RSGCore = exports['rsg-core']:GetCoreObject()
local PlayerData = {}
local isLoggedIn = false

-- Spawned prop tracking
local SpawnedProps       = {} -- array
local SpawnedPropsLookup = {} -- hash table keyed by plotid for O(1) lookup
local PropSpatialIndex   = {} -- grid-based spatial index for performance
local LastPlayerPos      = vector3(0, 0, 0)

-- Plots listed here are temporarily hidden during adjustment placement.
-- The spawn loop skips them so it doesn't re-spawn the old ghost mid-placement.
local HiddenPlots = {}

-- Coord-based blips created immediately at login for owned/guest plots.
-- Keyed by plotid. Transferred to SpawnedPropsLookup when the entity spawns.
local PlotBlips = {}

-- Forward declaration so OnPlayerLoaded (defined before updatePropData) can call it.
local RebuildPlotBlips

-- =============================================
-- SPATIAL INDEX (from rex-camping verbatim)
-- =============================================
local function GetGridKey(pos)
    local gridSize = 100
    return math.floor(pos.x / gridSize) .. '_' .. math.floor(pos.y / gridSize)
end

local function AddToSpatialIndex(prop)
    local key = GetGridKey(vector3(prop.x, prop.y, prop.z))
    if not PropSpatialIndex[key] then PropSpatialIndex[key] = {} end
    table.insert(PropSpatialIndex[key], prop)
end

local function GetNearbyFromGrid(playerPos)
    local nearby = {}
    local key    = GetGridKey(playerPos)
    local gx, gy = key:match('([^_]+)_([^_]+)')
    gx, gy = tonumber(gx), tonumber(gy)
    for x = -1, 1 do
        for y = -1, 1 do
            local checkKey = (gx + x) .. '_' .. (gy + y)
            if PropSpatialIndex[checkKey] then
                for _, p in ipairs(PropSpatialIndex[checkKey]) do
                    table.insert(nearby, p)
                end
            end
        end
    end
    return nearby
end

-- =============================================
-- STATE HANDLERS
-- =============================================
AddStateBagChangeHandler('isLoggedIn', nil, function(_, _, value)
    if value then
        isLoggedIn = true
        PlayerData = RSGCore.Functions.GetPlayerData()
    else
        isLoggedIn = false
        PlayerData = {}
    end
end)

AddEventHandler('RSGCore:Client:OnPlayerLoaded', function()
    isLoggedIn = true
    PlayerData = RSGCore.Functions.GetPlayerData()
    -- updatePropData may have arrived before citizenid was set; build blips now.
    RebuildPlotBlips()
end)

RegisterNetEvent('RSGCore:Client:OnPlayerUnload', function()
    isLoggedIn = false
    PlayerData = {}
end)

-- =============================================
-- BLIP STYLE HELPER
-- Applies the correct sprite/name/colour to any blip (coord or entity-attached).
-- =============================================
local function ApplyBlipStyle(blip, propData)
    SetBlipScale(blip, Config.Blip.blipScale)
    if propData.is_abandoned == 1 then
        SetBlipSprite(blip, joaat(Config.Blip.otherBlipSprite), true)
        Citizen.InvokeNative(0x9CB1A1623062F402, blip, Config.Blip.abandonedBlipName)
        if Config.Blip.abandonedColour then
            Citizen.InvokeNative(0x662D364ABF16DE2F, blip, joaat(Config.Blip.abandonedColour))
        end
    elseif propData.citizenid == PlayerData.citizenid then
        SetBlipSprite(blip, joaat(Config.Blip.ownBlipSprite), true)
        Citizen.InvokeNative(0x9CB1A1623062F402, blip, Config.Blip.ownBlipName)
        if Config.Blip.ownColour then
            Citizen.InvokeNative(0x662D364ABF16DE2F, blip, joaat(Config.Blip.ownColour))
        end
    else
        SetBlipSprite(blip, joaat(Config.Blip.otherBlipSprite), true)
        local isGuest = false
        if propData.allowed_players then
            for _, cid in ipairs(propData.allowed_players) do
                if cid == PlayerData.citizenid then isGuest = true break end
            end
        end
        if isGuest then
            Citizen.InvokeNative(0x9CB1A1623062F402, blip, Config.Blip.guestBlipName)
            if Config.Blip.guestColour then
                Citizen.InvokeNative(0x662D364ABF16DE2F, blip, joaat(Config.Blip.guestColour))
            end
        else
            Citizen.InvokeNative(0x9CB1A1623062F402, blip, Config.Blip.otherBlipName)
            if Config.Blip.otherColour then
                Citizen.InvokeNative(0x662D364ABF16DE2F, blip, joaat(Config.Blip.otherColour))
            end
        end
    end
end

-- Creates coord blips for all owned/guest plots in Config.PlayerProps.
-- Safe to call any time PlayerData.citizenid is available.
-- Clears any existing PlotBlips first so re-calls don't leak.
RebuildPlotBlips = function()
    local cid = PlayerData.citizenid
    if not cid then return end

    for _, blip in pairs(PlotBlips) do
        RemoveBlip(blip)
    end
    PlotBlips = {}

    for _, propData in ipairs(Config.PlayerProps) do
        if not (propData.x and propData.y and propData.z) then goto next end
        -- Skip plots already entity-spawned (they already have a blip in spawnedData)
        if SpawnedPropsLookup[propData.plotid] then goto next end

        local isOwned = propData.citizenid == cid
        local isGuest = false
        if not isOwned and propData.allowed_players then
            for _, c in ipairs(propData.allowed_players) do
                if c == cid then isGuest = true break end
            end
        end
        if isOwned or isGuest then
            local blip = BlipAddForCoords(1664425300, propData.x, propData.y, propData.z)
            ApplyBlipStyle(blip, propData)
            PlotBlips[propData.plotid] = blip
        end
        ::next::
    end
end

RegisterNetEvent('st-housing:client:updatePropData', function(data)
    Config.PlayerProps = data or {}
    -- Rebuild spatial index
    PropSpatialIndex = {}
    for _, prop in ipairs(Config.PlayerProps) do
        if prop and prop.x and prop.y and prop.z then
            AddToSpatialIndex(prop)
        end
    end

    -- Rebuild coord blips. If PlayerData isn't ready yet (race on login),
    -- OnPlayerLoaded will call RebuildPlotBlips() once citizenid is available.
    RebuildPlotBlips()

    -- Reset LastPlayerPos so spawn loop runs immediately on next tick
    -- without this, props won't spawn if player hasn't moved 5+ units since last check
    LastPlayerPos = vector3(0, 0, 0)
    if Config.Debug then
        print('^2[st-housing]^7 Received ' .. #Config.PlayerProps .. ' plots')
    end
end)

-- =============================================
-- WINDOW HELPERS
-- Spawn / delete the window prop objects attached to a completed house.
-- Uses the same RotateOffset math as server.lua: local offset → world delta.
-- Only called from within a coroutine (uses Wait internally via RequestModel).
-- =============================================
local function SpawnWindowsForPlot(propData)
    local houseConfig = Config.Houses[propData.house_type]
    if not houseConfig or not houseConfig.windows then return {} end

    local hx       = propData.x
    local hy       = propData.y
    local hz       = propData.z
    local hHeading = (tonumber(propData.heading) or 0) + 0.0
    local hRad     = math.rad(hHeading)

    local windowEntities = {}
    for _, winDef in ipairs(houseConfig.windows) do
        local modelHash = joaat(winDef.model)
        RequestModel(modelHash)
        local attempts = 0
        while not HasModelLoaded(modelHash) and attempts < 100 do
            Wait(10)
            attempts = attempts + 1
        end
        if not HasModelLoaded(modelHash) then
            print('^1[st-housing]^7 Failed to load window model: ' .. winDef.model)
            goto nextWin
        end

        -- Rotate local offset into world space (same formula as server RotateOffset)
        local ox  = winDef.offset.x
        local oy  = winDef.offset.y
        local wx  = hx + ox * math.cos(hRad) - oy * math.sin(hRad)
        local wy  = hy + ox * math.sin(hRad) + oy * math.cos(hRad)
        local wz  = hz + winDef.offset.z
        local wH  = hHeading + winDef.offset.heading

        local winObj = CreateObject(modelHash, wx, wy, wz, false, false, false)
        SetEntityAsMissionEntity(winObj, true)
        SetEntityCoordsNoOffset(winObj, wx, wy, wz, false, false, false, true)
        SetEntityRotation(winObj, 0.0, 0.0, wH, 2, false)
        FreezeEntityPosition(winObj, true)
        SetModelAsNoLongerNeeded(modelHash)

        table.insert(windowEntities, winObj)
        ::nextWin::
    end
    return windowEntities
end

local function DeleteWindowEntities(windows)
    if not windows then return end
    for _, winObj in ipairs(windows) do
        if DoesEntityExist(winObj) then
            SetEntityAsMissionEntity(winObj, false)
            FreezeEntityPosition(winObj, false)
            DeleteObject(winObj)
        end
    end
end

-- =============================================
-- PROP SPAWNING LOOP
-- Only spawns props within render distance
-- Uses spatial index to avoid checking all props every frame
-- =============================================
CreateThread(function()
    while true do
        Wait(500)
        if not isLoggedIn then goto skip end

        local pos = GetEntityCoords(cache.ped)
        if #(pos - LastPlayerPos) < 5.0 then goto skip end
        LastPlayerPos = pos

        local nearby = GetNearbyFromGrid(pos)
        for _, propData in ipairs(nearby) do
            local propPos = vector3(propData.x, propData.y, propData.z)
            if #(pos - propPos) > Config.PropRenderDistance then goto continue end
            if SpawnedPropsLookup[propData.plotid] then goto continue end
            if HiddenPlots[propData.plotid]         then goto continue end  -- suppressed during adjustment

            -- Load model
            local modelHash = joaat(propData.propmodel)
            RequestModel(modelHash)
            local loadAttempts = 0
            while not HasModelLoaded(modelHash) and loadAttempts < 100 do
                Wait(10)
                loadAttempts = loadAttempts + 1
            end
            if not HasModelLoaded(modelHash) then
                print('^1[st-housing]^7 Failed to load model: ' .. propData.propmodel)
                goto continue
            end

            -- Spawn house prop at exact stored coordinates
            -- Heading is set BEFORE freeze so the engine cannot override it,
            -- then again AFTER freeze as a belt-and-suspenders guard.
            -- Force float: MySQL INT column returns Lua integer; passing integer to SetEntityRotation
            -- causes wrong bit-level interpretation (int 165 = float 2.3e-43 ≈ 0). Adding 0.0 forces float subtype.
            local safeHeading = (tonumber(propData.heading) or 0) + 0.0

            local obj = CreateObject(modelHash, propData.x, propData.y, propData.z, false, false, false)
            SetEntityAsMissionEntity(obj, true)
            -- Mirrors the ghost placement loop pattern exactly:
            -- 1) Pin position first (settles collision mesh at correct Z, prevents heading-change from triggering resolution)
            -- 2) Set heading while NOT frozen (frozen+collision blocks SetEntityHeading silently)
            -- 3) Freeze last (locks the already-correct position+heading)
            -- dynamic=false means no gravity/physics so no Z drift during steps 1-3
            SetEntityCoordsNoOffset(obj, propData.x, propData.y, propData.z, false, false, false, true)
            -- SetEntityHeading is silently rejected on collision-enabled non-frozen props (engine physics path blocks it).
            -- SetEntityRotation bypasses this — same native used by the door spawn in doors.lua.
            SetEntityRotation(obj, 0.0, 0.0, safeHeading, 2, false)
            FreezeEntityPosition(obj, true)
            SetModelAsNoLongerNeeded(modelHash)

            -- Ghost alpha if not complete — collision stays ON so ox_target can raycast to it
            if propData.is_complete == 0 then
                SetEntityAlpha(obj, 120, false)
            end

            -- Vegetation removal — clears grass/plants in small radius around house
            local vegModifier = Citizen.InvokeNative(
                0xFA50F79257745E74,
                propData.x, propData.y, propData.z,
                Config.VegetationRadius,
                1,
                1+2+4+8+16+32+64+128+256,
                0
            )

            -- Doors are server-side networked entities (created in server.lua).
            -- This client receives their net IDs via st-housing:client:receiveDoorData
            -- and references them in doors.lua — no local creation needed here.

            -- Map blip: coord-based blip at the prop's world position.
            -- Entity-attached blips (0x23F74C2FDA6E7C61) do not return a valid handle
            -- in RDR2 and cannot be removed with RemoveBlip. Coord-based blips use the
            -- same native as all other blips in this codebase and RemoveBlip works on them.
            -- Remove the coord blip — it will be replaced by the spawned-prop blip below.
            if PlotBlips[propData.plotid] then
                RemoveBlip(PlotBlips[propData.plotid])
                PlotBlips[propData.plotid] = nil
            end
            local blip = Citizen.InvokeNative(0x554D9D53F696D002, 1664425300, vector3(propData.x, propData.y, propData.z))
            ApplyBlipStyle(blip, propData)

            -- ox_target interaction on house prop
            -- NOTE: entity must have collision enabled for ox_target to raycast to it
            if Config.Debug then
                print('^2[st-housing]^7 Adding ox_target to plot ' .. propData.plotid .. ' entity=' .. obj .. ' exists=' .. tostring(DoesEntityExist(obj)))
            end
            exports.ox_target:addLocalEntity(obj, {
                {
                    name     = 'housing_interact_' .. propData.plotid,
                    icon     = 'fa-solid fa-house',
                    label    = 'Interact with Property',
                    onSelect = function()
                        local freshData = nil
                        for _, p in ipairs(Config.PlayerProps) do
                            if p.plotid == propData.plotid then
                                freshData = p
                                break
                            end
                        end
                        if freshData then
                            exports['st-housing']:OpenPlotMenu(propData.plotid, freshData)
                        end
                    end,
                    distance = 7.0,
                }
            })

            -- Spawn window props for completed houses
            local windowEntities = {}
            if propData.is_complete == 1 then
                windowEntities = SpawnWindowsForPlot(propData)
                -- Spawn furniture (local entities, managed by furniture.lua)
                exports['st-housing']:SpawnFurnitureForPlot(propData)
            end

            -- Store in lookup tables
            local spawnedData = {
                obj         = obj,
                plotid      = propData.plotid,
                vegModifier = vegModifier,
                blip        = blip,
                citizenid   = propData.citizenid,
                house_type  = propData.house_type,
                is_complete = propData.is_complete,
                windows     = windowEntities,
            }
            SpawnedProps[#SpawnedProps + 1]            = spawnedData
            SpawnedPropsLookup[propData.plotid] = spawnedData

            if Config.Debug then
                print('^2[st-housing]^7 Spawned plot ' .. propData.plotid)
            end

            ::continue::
        end

        ::skip::
    end
end)

-- =============================================
-- PROGRESS BAR DRAW LOOP
-- Draws floating progress bar above incomplete plots within 30m.
-- Split into two threads to avoid running expensive lookups every frame:
--   Refresh thread (500ms): rebuilds the cache of bars to show.
--   Draw thread   (Wait(0)): just iterates the tiny cache — no table searches.
-- =============================================
local ActiveProgressBars = {}

local function RefreshProgressBars()
    ActiveProgressBars = {}
    if not isLoggedIn then return end
    local pos = GetEntityCoords(cache.ped)
    for _, spawnedProp in ipairs(SpawnedProps) do
        if spawnedProp.is_complete == 0 then
            for _, p in ipairs(Config.PlayerProps) do
                if p.plotid == spawnedProp.plotid then
                    local propPos = vector3(p.x, p.y, p.z)
                    if #(pos - propPos) < 30.0 then
                        table.insert(ActiveProgressBars, {
                            pos      = propPos,
                            progress = exports['st-housing']:CalculateProgress(p.stage_materials or {}, p.house_type),
                            label    = Config.Houses[p.house_type] and Config.Houses[p.house_type].label or 'Property',
                        })
                    end
                    break
                end
            end
        end
    end
end

-- Draw thread: Wait(0) only to keep bars visible every frame; no lookups here.
CreateThread(function()
    while true do
        if not isLoggedIn then Wait(1000) goto barskip end
        for _, bar in ipairs(ActiveProgressBars) do
            exports['st-housing']:DrawProgressBar(bar.pos, bar.progress, bar.label)
        end
        Wait(0)
        ::barskip::
    end
end)

-- Refresh thread: rebuilds which bars to show every 500ms.
CreateThread(function()
    while true do
        Wait(500)
        RefreshProgressBars()
    end
end)

-- =============================================
-- UPDATE SINGLE PLOT (stage progress, completion)
-- Fired from server when materials deposited or house completes
-- =============================================
RegisterNetEvent('st-housing:client:updatePlotData', function(plotId, newData)
    -- Update runtime cache
    for i, prop in ipairs(Config.PlayerProps) do
        if prop.plotid == plotId then
            Config.PlayerProps[i] = newData
            break
        end
    end

    -- Update spatial index
    PropSpatialIndex = {}
    for _, prop in ipairs(Config.PlayerProps) do
        if prop and prop.x and prop.y and prop.z then
            AddToSpatialIndex(prop)
        end
    end

    -- If just completed, make prop solid and flush the progress bar cache
    local spawnedProp = SpawnedPropsLookup[plotId]
    if spawnedProp and newData.is_complete == 1 and spawnedProp.is_complete == 0 then
        SetEntityAlpha(spawnedProp.obj, 255, false)
        spawnedProp.is_complete = 1
        -- Spawn window props now that construction is complete
        spawnedProp.windows = SpawnWindowsForPlot(newData)
        RefreshProgressBars()  -- removes bar immediately rather than waiting 500ms

        -- Server creates door entities and broadcasts net IDs via updatePlotDoorData.
        -- Nothing to do here client-side; doors.lua handles the rest automatically.

        local houseConfig = Config.Houses[newData.house_type]
        lib.notify({
            title       = 'Construction Complete!',
            description = 'Your ' .. (houseConfig and houseConfig.label or 'property') .. ' is built!',
            type        = 'success',
            duration    = 8000
        })
    end
end)

-- =============================================
-- DOOR LOCK SYNC
-- Broadcast from server when any player locks/unlocks a plot's doors.
-- Updates the local door state and the cached prop data so the menu
-- shows the correct Lock/Unlock label next time it opens.
-- =============================================
RegisterNetEvent('st-housing:client:syncDoorLock', function(plotId, locked)
    -- Apply to door system (handles snap-to-closed if currently open)
    exports['st-housing']:SetPlotDoorLock(plotId, locked)

    -- Keep local prop cache consistent so the menu reflects current state
    for i, prop in ipairs(Config.PlayerProps) do
        if prop.plotid == plotId then
            Config.PlayerProps[i].is_locked = locked and 1 or 0
            break
        end
    end
end)

-- =============================================
-- HIDE LOCAL PROP (adjustment placement pre-step)
-- Removes the spawned entity and all its client-side attachments for one plot
-- WITHOUT touching Config.PlayerProps. This lets the spawn loop naturally
-- re-spawn the prop at whichever coords are current after placement ends:
--   - cancel → old coords still in Config.PlayerProps → re-spawns in place
--   - confirm → server broadcasts updatePropData with new coords → re-spawns there
-- =============================================
local function HideLocalProp(plotId)
    -- Suppress the spawn loop FIRST so it cannot re-spawn the prop while we delete it
    HiddenPlots[plotId] = true

    local spawnedProp = SpawnedPropsLookup[plotId]
    if not spawnedProp then return end

    if spawnedProp.vegModifier then
        Citizen.InvokeNative(0x9CF1836C03FB67A2,
            Citizen.PointerValueIntInitialized(spawnedProp.vegModifier), 0
        )
    end

    if spawnedProp.blip then
        RemoveBlip(spawnedProp.blip)
    end

    exports.ox_target:removeLocalEntity(spawnedProp.obj)

    if DoesEntityExist(spawnedProp.obj) then
        SetEntityAsMissionEntity(spawnedProp.obj, false)
        FreezeEntityPosition(spawnedProp.obj, false)
        DeleteObject(spawnedProp.obj)
    end

    DeleteWindowEntities(spawnedProp.windows)

    SpawnedPropsLookup[plotId] = nil
    for i = #SpawnedProps, 1, -1 do
        if SpawnedProps[i].plotid == plotId then
            table.remove(SpawnedProps, i)
            break
        end
    end
end

-- Lifts the spawn suppression for a plot and immediately triggers the spawn loop.
-- Called on adjustment cancel (re-spawn at old coords) or by forceRemovePlot on confirm.
local function AllowPlotSpawn(plotId)
    HiddenPlots[plotId] = nil
    LastPlayerPos = vector3(0, 0, 0)  -- force spawn loop to re-evaluate next tick
end

exports('HideLocalProp',   HideLocalProp)
exports('AllowPlotSpawn',  AllowPlotSpawn)

-- =============================================
-- FORCE REMOVE PLOT (demolish / repossession)
-- =============================================
RegisterNetEvent('st-housing:client:forceRemovePlot', function(plotId)
    HiddenPlots[plotId] = nil  -- lift suppression so spawn loop can re-spawn at new coords

    if PlotBlips[plotId] then
        RemoveBlip(PlotBlips[plotId])
        PlotBlips[plotId] = nil
    end

    local spawnedProp = SpawnedPropsLookup[plotId]
    if spawnedProp then
        -- Doors are server-side; server deletes them and broadcasts removeDoorData.
        -- Furniture is local; delete it here.
        exports['st-housing']:DeleteFurnitureForPlot(plotId)

        -- Remove vegetation modifier
        if spawnedProp.vegModifier then
            Citizen.InvokeNative(0x9CF1836C03FB67A2,
                Citizen.PointerValueIntInitialized(spawnedProp.vegModifier), 0
            )
        end

        -- Remove blip
        if spawnedProp.blip then
            RemoveBlip(spawnedProp.blip)
        end

        -- Remove ox_target
        exports.ox_target:removeLocalEntity(spawnedProp.obj)

        -- Delete prop
        if DoesEntityExist(spawnedProp.obj) then
            SetEntityAsMissionEntity(spawnedProp.obj, false)
            FreezeEntityPosition(spawnedProp.obj, false)
            DeleteObject(spawnedProp.obj)
        end

        DeleteWindowEntities(spawnedProp.windows)

        SpawnedPropsLookup[plotId] = nil
    end

    -- Remove from SpawnedProps array
    for i = #SpawnedProps, 1, -1 do
        if SpawnedProps[i].plotid == plotId then
            table.remove(SpawnedProps, i)
            break
        end
    end

    -- Remove from Config.PlayerProps
    for i = #Config.PlayerProps, 1, -1 do
        if Config.PlayerProps[i].plotid == plotId then
            table.remove(Config.PlayerProps, i)
            break
        end
    end

    -- Rebuild spatial index
    PropSpatialIndex = {}
    for _, prop in ipairs(Config.PlayerProps) do
        if prop and prop.x and prop.y and prop.z then
            AddToSpatialIndex(prop)
        end
    end
end)

-- =============================================
-- HOUSING AGENT NPCs
-- Spawns vendors from Config.HousingAgents
-- =============================================
CreateThread(function()
    for agentIdx, agentData in ipairs(Config.HousingAgents) do
        -- lib.requestModel matches rsg-shops pattern (handles timeout internally)
        lib.requestModel(agentData.model, 5000)

        if not HasModelLoaded(agentData.model) then
            print('^1[st-housing]^7 Failed to load NPC model for: ' .. agentData.label)
            goto nextAgent
        end

        -- Ask the engine for the exact ground Z at this XY position.
        -- Start the raycast well above the given coords so it always hits terrain below.
        -- RequestCollisionAtCoord ensures the terrain chunk is streamed before we query.
        local ax, ay = agentData.coords.x, agentData.coords.y
        RequestCollisionAtCoord(ax, ay, agentData.coords.z)
        local groundFound, groundZ = false, agentData.coords.z
        local attempts = 0
        while not groundFound and attempts < 30 do
            groundFound, groundZ = GetGroundZFor_3dCoord(ax, ay, agentData.coords.z + 150.0, true)
            if not groundFound then Wait(200) end
            attempts = attempts + 1
        end
        -- Fall back to a rough estimate if terrain never loaded (edge case)
        local spawnZ = groundFound and groundZ or agentData.coords.z

        local npc = CreatePed(agentData.model, ax, ay, spawnZ, agentData.coords.w, false, false, false, false)

        -- SetRandomOutfitVariation is required — without it the ped has no outfit and appears invisible
        Citizen.InvokeNative(0x283978A15512B2FE, npc, true)
        SetEntityNoCollisionEntity(npc, PlayerPedId(), false)
        SetEntityCanBeDamaged(npc, false)
        SetEntityInvincible(npc, true)
        SetBlockingOfNonTemporaryEvents(npc, true)
        SetModelAsNoLongerNeeded(agentData.model)
        FreezeEntityPosition(npc, true)

        if Config.Debug then
            print('^2[st-housing]^7 Spawned agent: ' .. agentData.label .. ' entity=' .. npc .. ' exists=' .. tostring(DoesEntityExist(npc)))
        end

        -- Build context menus for this agent (unique IDs per agent index)
        local agentId = tostring(agentIdx)

        -- Housing Plans sub-context
        local planOptions = {}
        for houseType, houseConfig in pairs(Config.Houses) do
            local matList = ''
            for _, mat in ipairs(houseConfig.totalMaterials) do
                matList = matList .. mat.amount .. 'x ' .. mat.item .. '  '
            end
            local capturedType = houseType
            table.insert(planOptions, {
                title       = houseConfig.label,
                description = '$' .. houseConfig.price .. ' — Requires: ' .. matList,
                icon        = 'fa-solid fa-house',
                onSelect    = function()
                    TriggerServerEvent('st-housing:server:buyPlan', capturedType)
                end,
            })
        end
        lib.registerContext({
            id      = 'housing_plans_' .. agentId,
            title   = 'Housing Plans',
            menu    = 'housing_shop_' .. agentId,
            options = planOptions,
        })

        -- Main shop context: Housing Plans | Furniture (NUI)
        lib.registerContext({
            id      = 'housing_shop_' .. agentId,
            title   = agentData.label,
            options = {
                {
                    title       = 'Housing Plans',
                    description = 'Purchase a building plan',
                    icon        = 'fa-solid fa-house',
                    onSelect    = function()
                        lib.showContext('housing_plans_' .. agentId)
                    end,
                },
                {
                    title       = 'Furniture',
                    description = 'Browse and preview furniture for your home',
                    icon        = 'fa-solid fa-couch',
                    onSelect    = function()
                        -- Close the ox_lib context then open the dedicated NUI shop
                        lib.hideContext(false)
                        OpenFurnitureNUI()
                    end,
                },
            },
        })

        exports.ox_target:addLocalEntity(npc, {
            {
                name     = 'housing_agent_' .. agentData.label,
                icon     = 'fa-solid fa-store',
                label    = agentData.label,
                onSelect = function()
                    lib.showContext('housing_shop_' .. agentId)
                end,
                distance = 3.0,
            }
        })

        -- Map blip at fixed coords
        -- Must pass vector3 — agentData.coords is vector4 (has .w for heading) which breaks the native
        local agentCoords3 = vector3(agentData.coords.x, agentData.coords.y, agentData.coords.z)
        local agentBlip = Citizen.InvokeNative(0x554D9D53F696D002, 1664425300, agentCoords3)
        SetBlipSprite(agentBlip, joaat(Config.Blip.agentBlipSprite), true)
        SetBlipScale(agentBlip, 0.35)
        Citizen.InvokeNative(0x9CB1A1623062F402, agentBlip, agentData.label)
        Citizen.InvokeNative(0x662D364ABF16DE2F, agentBlip, joaat(Config.Blip.agentBlipColour))

        ::nextAgent::
    end
end)

-- =============================================
-- CLEANUP ON RESOURCE STOP
-- =============================================
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for _, spawnedProp in ipairs(SpawnedProps) do
        -- Doors are server-side; no client cleanup needed here
        if spawnedProp.vegModifier then
            Citizen.InvokeNative(0x9CF1836C03FB67A2,
                Citizen.PointerValueIntInitialized(spawnedProp.vegModifier), 0
            )
        end
        if spawnedProp.blip then
            RemoveBlip(spawnedProp.blip)
        end
        if DoesEntityExist(spawnedProp.obj) then
            SetEntityAsMissionEntity(spawnedProp.obj, false)
            FreezeEntityPosition(spawnedProp.obj, false)
            DeleteObject(spawnedProp.obj)
        end
        DeleteWindowEntities(spawnedProp.windows)
        exports['st-housing']:DeleteFurnitureForPlot(spawnedProp.plotid)
    end
    SpawnedProps       = {}
    SpawnedPropsLookup = {}
    PropSpatialIndex   = {}
end)
