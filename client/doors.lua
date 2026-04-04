-- Door system for st-housing
-- Doors are created SERVER-SIDE as networked entities (FiveM OneSync).
-- Every client references the SAME entity via NetworkGetEntityFromNetworkId.
-- Heading changes made by the controlling client replicate automatically to
-- all other players — no per-player broadcast needed for open/close animation.
-- The server only handles lock state (DB-persisted, broadcast on change).
--
-- FLOW:
--   Server creates entity → stores netId → sends to clients on join / house completion
--   Client receives netId → lazily resolves to entity handle once in streaming range
--   Player approaches → NetworkRequestControlOfEntity → animate (syncs to all)
--   Player leaves    → animate back to closedHeading   (syncs to all)
--   Lock/unlock      → server event → broadcast → SetPlotDoorLock on all clients

-- =============================================
-- STATE
-- PlotDoorNetData[plotId]  = { is_locked=bool, doors={ {netId, closedHeading, x,y,z}, ... } }
-- PlotDoorRuntime[plotId]  = { {entity, netId, closedHeading, isOpen, animating, plotId, x,y,z}, ... }
-- PlotLocked[plotId]       = bool   (separate: updated by syncDoorLock before runtime resolves)
-- =============================================
local PlotDoorNetData = {}
local PlotDoorRuntime = {}
local PlotLocked      = {}

-- =============================================
-- HEADING MATH HELPERS
-- =============================================
local function NormH(h)
    h = h % 360.0
    if h < 0.0 then h = h + 360.0 end
    return h
end

local function HDiff(from, to)
    local d = NormH(to) - NormH(from)
    if d >  180.0 then d = d - 360.0 end
    if d < -180.0 then d = d + 360.0 end
    return d
end

-- =============================================
-- LAZY ENTITY RESOLUTION
-- Net IDs arrive before the entity may be within streaming range.
-- Called each proximity tick; returns true once all doors are resolved.
-- =============================================
local function TryResolvePlot(plotId)
    if PlotDoorRuntime[plotId] then return true end

    local data = PlotDoorNetData[plotId]
    if not data or not data.doors then return false end

    local resolved = {}
    for _, info in ipairs(data.doors) do
        local entity = NetworkGetEntityFromNetworkId(info.netId)
        local exists = entity and entity > 0 and DoesEntityExist(entity)
        if not exists then
            return false  -- not in streaming range yet; retry next tick
        end
        FreezeEntityPosition(entity, true)  -- keep door anchored; SetEntityRotation still works
        table.insert(resolved, {
            entity        = entity,
            netId         = info.netId,
            closedHeading = info.closedHeading,
            isOpen        = false,
            animating     = false,
            plotId        = plotId,
            x = info.x, y = info.y, z = info.z,
        })
    end

    PlotDoorRuntime[plotId] = resolved
    -- Lock state may have been set by syncDoorLock before resolution; preserve it
    if PlotLocked[plotId] == nil then
        PlotLocked[plotId] = data.is_locked
    end
    return true
end

-- =============================================
-- SMOOTH HEADING ANIMATION
-- Requests network control so heading changes replicate to all clients.
-- Mid-lock detection: aborts and snaps to closedHeading if locked mid-swing.
-- =============================================
local ANIM_STEP = 6.0  -- degrees per frame (~60fps → full 90° swing ≈ 250ms)

local function AnimateDoor(door, targetHeading)
    if door.animating then return end
    door.animating = true
    CreateThread(function()
        -- Acquire network ownership so our SetEntityRotation calls replicate
        NetworkRequestControlOfEntity(door.entity)
        local waited = 0
        while not NetworkHasControlOfEntity(door.entity) and waited < 10 do
            Wait(0)
            waited = waited + 1
        end

        while DoesEntityExist(door.entity) do
            -- Abort and snap if locked mid-swing
            if PlotLocked[door.plotId] then
                door.isOpen = false
                SetEntityRotation(door.entity, 0.0, 0.0, door.closedHeading, 2, false)
                break
            end

            local current = NormH(GetEntityHeading(door.entity))
            local diff    = HDiff(current, targetHeading)

            if math.abs(diff) <= ANIM_STEP then
                SetEntityRotation(door.entity, 0.0, 0.0, targetHeading, 2, false)
                break
            end

            local dir = diff > 0.0 and 1.0 or -1.0
            SetEntityRotation(door.entity, 0.0, 0.0, NormH(current + dir * ANIM_STEP), 2, false)
            Wait(16)
        end
        door.animating = false
    end)
end

-- =============================================
-- PROXIMITY THREAD
-- Poll rate adapts to nearest door distance:
--   unresolved / < 20m  → 200ms  (needs fast response)
--   20m – 100m          → 400ms
--   > 100m / no doors   → 600ms
-- =============================================
CreateThread(function()
    while true do
        local playerPos = GetEntityCoords(PlayerPedId())
        local hasAny    = false
        local minDist   = math.huge

        for plotId, _ in pairs(PlotDoorNetData) do
            if not TryResolvePlot(plotId) then
                hasAny = true  -- keep polling so resolution retries
                goto nextPlot
            end

            local doors  = PlotDoorRuntime[plotId]
            local locked = PlotLocked[plotId]

            for _, door in ipairs(doors) do
                if not DoesEntityExist(door.entity) then
                    PlotDoorRuntime[plotId] = nil
                    goto nextPlot
                end
                hasAny = true

                local dist = #(playerPos - vector3(door.x, door.y, door.z))
                if dist < minDist then minDist = dist end

                if dist < 1.8 and not locked then
                    if not door.isOpen then
                        door.isOpen = true
                        local fwdX = -math.sin(math.rad(door.closedHeading))
                        local fwdY =  math.cos(math.rad(door.closedHeading))
                        local dot  = fwdX * (playerPos.x - door.x) + fwdY * (playerPos.y - door.y)
                        local swing = dot >= 0.0 and -90.0 or 90.0
                        AnimateDoor(door, NormH(door.closedHeading + swing))
                    end
                else
                    if door.isOpen then
                        door.isOpen = false
                        AnimateDoor(door, door.closedHeading)
                    end
                end
            end

            ::nextPlot::
        end

        local waitMs
        if not hasAny then
            waitMs = 600
        elseif minDist < 20.0 then
            waitMs = 200
        elseif minDist < 100.0 then
            waitMs = 400
        else
            waitMs = 600
        end
        Wait(waitMs)
    end
end)

-- =============================================
-- NET EVENT HANDLERS
-- =============================================

-- =============================================
-- DOOR CREATION (this client is the designated creator)
-- Server sends world-space door parameters; client spawns as networked entities
-- and reports net IDs back so the server can broadcast them to everyone.
-- =============================================
RegisterNetEvent('st-housing:client:createDoorsRequest', function(plotId, doorRequests, isLocked)
    CreateThread(function()
        local netIdData = {}
        for i, req in ipairs(doorRequests) do
            local modelHash = joaat(req.model)

            -- Stream the model before spawning
            RequestModel(modelHash)
            local waited = 0
            while not HasModelLoaded(modelHash) and waited < 50 do
                Wait(100)
                waited = waited + 1
            end

            if HasModelLoaded(modelHash) then
                -- isNetworked=true so all clients share the same entity
                local obj = CreateObjectNoOffset(modelHash, req.x, req.y, req.z, true, false, true)
                local waitCount = 0
                while not DoesEntityExist(obj) and waitCount < 30 do
                    Wait(100)
                    waitCount = waitCount + 1
                end

                if DoesEntityExist(obj) then
                    SetEntityHeading(obj, req.heading)
                    FreezeEntityPosition(obj, true)   -- prevent gravity from dropping the door
                    SetEntityAsMissionEntity(obj, true, true)
                    local netId = NetworkGetNetworkIdFromEntity(obj)
                    table.insert(netIdData, {
                        netId         = netId,
                        closedHeading = req.heading,
                        x = req.x, y = req.y, z = req.z,
                    })
                else
                    print('^1[st-housing]^7 Door entity did not exist after spawn: ' .. req.model)
                end
            else
                print('^1[st-housing]^7 Door model failed to load: ' .. req.model)
            end

            SetModelAsNoLongerNeeded(modelHash)
        end

        TriggerServerEvent('st-housing:server:reportDoorNetIds', plotId, netIdData)
    end)
end)

-- Bulk receive on player join or after server/resource restart
RegisterNetEvent('st-housing:client:receiveDoorData', function(allPackets)
    for plotId, packet in pairs(allPackets) do
        PlotDoorNetData[plotId] = packet
        PlotDoorRuntime[plotId] = nil
        PlotLocked[plotId]      = packet.is_locked
    end
end)

-- Single plot door data (sent when a house first completes construction)
RegisterNetEvent('st-housing:client:updatePlotDoorData', function(plotId, packet)
    PlotDoorNetData[plotId] = packet
    PlotDoorRuntime[plotId] = nil
    PlotLocked[plotId]      = packet.is_locked
end)

-- Plot demolished: delete any locally resolved door entities, then clear state.
-- The server calls DeleteEntity for each door, but its entity handle can be stale
-- (NetworkGetEntityFromNetworkId may return 0 if called too soon after the client
-- reported net IDs). Deleting here on every client is the reliable fallback.
RegisterNetEvent('st-housing:client:removeDoorData', function(plotId)
    local doors = PlotDoorRuntime[plotId]
    if doors then
        for _, door in ipairs(doors) do
            if DoesEntityExist(door.entity) then
                SetEntityAsMissionEntity(door.entity, false, true)
                FreezeEntityPosition(door.entity, false)
                DeleteObject(door.entity)
            end
        end
    end
    PlotDoorNetData[plotId] = nil
    PlotDoorRuntime[plotId] = nil
    PlotLocked[plotId]      = nil
end)

-- =============================================
-- LOCK / UNLOCK  (export called by syncDoorLock handler in client.lua)
-- =============================================
local function SetPlotDoorLock(plotId, locked)
    if not plotId then return end

    PlotLocked[plotId] = locked
    if PlotDoorNetData[plotId] then
        PlotDoorNetData[plotId].is_locked = locked
    end

    local doors = PlotDoorRuntime[plotId]
    if not doors then return end

    if locked then
        for _, door in ipairs(doors) do
            if DoesEntityExist(door.entity) then
                door.isOpen = false
                if not door.animating then
                    NetworkRequestControlOfEntity(door.entity)
                    SetEntityRotation(door.entity, 0.0, 0.0, door.closedHeading, 2, false)
                end
                -- If animating, the AnimateDoor thread detects PlotLocked and snaps itself
            end
        end
    end
end

exports('SetPlotDoorLock', SetPlotDoorLock)
