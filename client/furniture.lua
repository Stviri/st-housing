-- Furniture placement and entity management for st-housing
-- All furniture entities are LOCAL (non-networked, client-side only).
-- Each client independently spawns and manages furniture from plotData.furniture[].
-- Server is authoritative: DB stores {model, x, y, z, heading} per furniture piece.
--
-- FLOW:
--   Player buys furniture at NPC (with quantity) → st_furniture items with metadata {model=...}
--   Player uses item → server fires startFurniturePlacement → ghost placement loop
--   Player confirms within 200m of plot center → server saves to DB → broadcasts
--   All clients receive updateFurnitureData and respawn furniture for that plot
--   Owner selects ox_target "Remove Furniture" → server removes from DB → broadcasts

local RSGCore = exports['rsg-core']:GetCoreObject()

-- SpawnedFurniture[plotId] = { {entity, furnitureIdx}, ... }
local SpawnedFurniture = {}

-- Active ghost placement state
local FurniturePlacementActive = false

-- Active preview state (prevent stacking previews)
local FurniturePreviewActive = false

-- =============================================
-- PROP LABEL HELPER
-- 'p_chair04x' → 'Chair 04x'
-- =============================================
local function PropLabel(model)
    local s = model:gsub('^[ps]_', ''):gsub('_', ' ')
    return (s:gsub('^%l', string.upper))
end

-- =============================================
-- DELETE ALL FURNITURE ENTITIES FOR A PLOT
-- =============================================
local function DeleteFurnitureForPlot(plotId)
    local items = SpawnedFurniture[plotId]
    if not items then return end
    for _, f in ipairs(items) do
        if DoesEntityExist(f.entity) then
            exports.ox_target:removeLocalEntity(f.entity)
            SetEntityAsMissionEntity(f.entity, false)
            FreezeEntityPosition(f.entity, false)
            DeleteObject(f.entity)
        end
    end
    SpawnedFurniture[plotId] = nil
end

-- =============================================
-- SPAWN ALL FURNITURE ENTITIES FOR A PLOT
-- Runs in its own thread; safe to call at any time.
-- =============================================
local function SpawnFurnitureForPlot(propData)
    if not propData or not propData.furniture or #propData.furniture == 0 then return end

    local plotId = propData.plotid
    local myCid  = RSGCore.Functions.GetPlayerData().citizenid

    CreateThread(function()
        DeleteFurnitureForPlot(plotId)

        local entities = {}
        for idx, fData in ipairs(propData.furniture) do
            local modelHash = joaat(fData.model)
            RequestModel(modelHash)
            local attempts = 0
            while not HasModelLoaded(modelHash) and attempts < 100 do
                Wait(10)
                attempts = attempts + 1
            end
            if not HasModelLoaded(modelHash) then
                print('^1[st-housing]^7 Failed to load furniture model: ' .. fData.model)
                goto nextFurniture
            end

            local obj = CreateObject(modelHash, fData.x, fData.y, fData.z, false, false, false)
            SetEntityAsMissionEntity(obj, true)
            SetEntityCoordsNoOffset(obj, fData.x, fData.y, fData.z, false, false, false, true)
            SetEntityRotation(obj, 0.0, 0.0, (tonumber(fData.heading) or 0) + 0.0, 2, false)
            FreezeEntityPosition(obj, true)
            SetModelAsNoLongerNeeded(modelHash)

            -- Owner-only ox_target for removal
            if myCid == propData.citizenid then
                local capturedPlotId = plotId
                local capturedIdx    = idx
                local capturedModel  = fData.model
                exports.ox_target:addLocalEntity(obj, {
                    {
                        name     = 'furniture_remove_' .. plotId .. '_' .. idx,
                        icon     = 'fa-solid fa-trash',
                        label    = 'Remove ' .. PropLabel(capturedModel),
                        onSelect = function()
                            TriggerServerEvent('st-housing:server:removeFurniture', capturedPlotId, capturedIdx)
                        end,
                        distance = 2.5,
                    }
                })
            end

            table.insert(entities, { entity = obj, furnitureIdx = idx })
            ::nextFurniture::
        end

        SpawnedFurniture[plotId] = entities
        if Config.Debug then
            print('^2[st-housing]^7 Spawned ' .. #entities .. ' furniture pieces for plot ' .. plotId)
        end
    end)
end

exports('SpawnFurnitureForPlot', SpawnFurnitureForPlot)
exports('DeleteFurnitureForPlot', DeleteFurnitureForPlot)

-- =============================================
-- IN-WORLD FURNITURE PREVIEW
-- Spawns a static ghost of the prop 3m in front of the player for
-- Config.FurniturePreviewDuration ms, with a countdown HUD line.
-- Triggered as a LOCAL event from the NPC shop "Preview" option.
-- =============================================
AddEventHandler('st-housing:client:previewFurniture', function(propModel)
    if FurniturePreviewActive then
        lib.notify({ title = 'Preview Active', description = 'Wait for the current preview to finish', type = 'inform' })
        return
    end
    FurniturePreviewActive = true

    CreateThread(function()
        local propHash = joaat(propModel)
        RequestModel(propHash)
        local attempts = 0
        while not HasModelLoaded(propHash) and attempts < 100 do
            Wait(10)
            attempts = attempts + 1
        end
        if not HasModelLoaded(propHash) then
            lib.notify({ title = 'Preview Failed', description = 'Could not load model', type = 'error' })
            FurniturePreviewActive = false
            return
        end

        -- Spawn 3m in front of player at ground level
        local ped     = PlayerPedId()
        local pedPos  = GetEntityCoords(ped)
        local pedHead = GetEntityHeading(ped)
        local rad     = math.rad(pedHead)
        local spawnX  = pedPos.x + (-math.sin(rad) * 3.0)
        local spawnY  = pedPos.y + ( math.cos(rad) * 3.0)
        local spawnZ  = pedPos.z

        local obj = CreateObject(propHash, spawnX, spawnY, spawnZ, false, false, false)
        SetEntityAsMissionEntity(obj, true)
        SetEntityAlpha(obj, 180, false)
        SetEntityCollision(obj, false, false)
        SetEntityRotation(obj, 0.0, 0.0, pedHead, 2, false)
        FreezeEntityPosition(obj, true)
        SetModelAsNoLongerNeeded(propHash)

        local label    = PropLabel(propModel)
        local duration = Config.FurniturePreviewDuration or 5000
        local endTime  = GetGameTimer() + duration

        -- Draw countdown text each frame until timer expires
        CreateThread(function()
            while GetGameTimer() < endTime and DoesEntityExist(obj) do
                local remaining = math.ceil((endTime - GetGameTimer()) / 1000)
                local text = CreateVarString(10, 'LITERAL_STRING', label .. ' — Preview (' .. remaining .. 's)')
                Citizen.InvokeNative(0xB87A37EEB7FAA67D, text, 0.5, 0.92, 0.4, 0.35, 0)
                Wait(0)
            end
        end)

        Wait(duration)

        if DoesEntityExist(obj) then
            SetEntityAsMissionEntity(obj, false)
            DeleteObject(obj)
        end
        FurniturePreviewActive = false
    end)
end)

-- =============================================
-- FURNITURE PLACEMENT LOOP
-- Reuses housing prompt group and all six prompts from prompts.lua.
-- plotId, plotX/Y/Z define the 200m zone constraint.
-- =============================================
-- Enables or disables collision on all placed furniture entities for a plot.
-- Called at the start/end of placement so the ghost can't snap to or drag them.
local function SetPlacedFurnitureCollision(plotId, enabled)
    local placed = SpawnedFurniture[plotId]
    if not placed then return end
    for _, f in ipairs(placed) do
        if DoesEntityExist(f.entity) then
            SetEntityCollision(f.entity, enabled, false)
        end
    end
end

local function RunFurniturePlacement(propModel, plotId, plotX, plotY, plotZ)
    if FurniturePlacementActive then
        lib.notify({ title = 'Already Placing', description = 'Finish current placement first', type = 'error' })
        return
    end
    FurniturePlacementActive = true

    local propHash = joaat(propModel)
    RequestModel(propHash)
    local attempts = 0
    while not HasModelLoaded(propHash) and attempts < 200 do
        Wait(10)
        attempts = attempts + 1
    end

    if not HasModelLoaded(propHash) then
        lib.notify({ title = 'Error', description = 'Could not load furniture model', type = 'error' })
        FurniturePlacementActive = false
        TriggerServerEvent('st-housing:server:cancelFurniturePlacement')
        return
    end

    -- Disable collision on all already-placed furniture for this plot so the
    -- ghost object cannot snap to their surfaces or drag them via physics.
    SetPlacedFurnitureCollision(plotId, false)

    -- Seed the ghost near the camera
    local camCoord = GetGameplayCamCoord()
    local camRot   = GetGameplayCamRot()
    local rz       = math.rad(camRot.z)
    local seed     = {
        x = camCoord.x + (-math.sin(rz) * 5.0),
        y = camCoord.y + ( math.cos(rz) * 5.0),
        z = camCoord.z,
    }

    local prop = CreateObject(propHash, seed.x, seed.y, seed.z, false, false, false)
    SetEntityAlpha(prop, 150, false)
    SetEntityCollision(prop, false, false)
    FreezeEntityPosition(prop, true)

    local heading      = 0.0
    local heightOffset = 0.0
    local confirmed    = false
    local plotCenter   = vector3(plotX, plotY, plotZ)
    local promptGroup  = exports['st-housing']:GetHousingPromptGroup()

    CreateThread(function()
        while not confirmed do
            local camRot2   = GetGameplayCamRot()
            local camCoord2 = GetGameplayCamCoord()
            local rz2       = math.rad(camRot2.z)
            local rx2       = math.rad(camRot2.x)
            local dx  = -math.sin(rz2) * math.abs(math.cos(rx2))
            local dy  =  math.cos(rz2) * math.abs(math.cos(rx2))
            local dz  =  math.sin(rx2)
            local dest = {
                x = camCoord2.x + dx * 1000.0,
                y = camCoord2.y + dy * 1000.0,
                z = camCoord2.z + dz * 1000.0,
            }

            local _, hit, coords, _, _ = GetShapeTestResult(
                StartShapeTestRay(
                    camCoord2.x, camCoord2.y, camCoord2.z,
                    dest.x, dest.y, dest.z,
                    -1, PlayerPedId(), 0
                )
            )

            if hit then
                local finalZ      = coords.z + heightOffset
                local finalCoords = vector3(coords.x, coords.y, finalZ)

                SetEntityCoordsNoOffset(prop, coords.x, coords.y, finalZ, false, false, false, true)
                SetEntityHeading(prop, heading)

                -- Zone check
                local zoneDist = #(finalCoords - plotCenter)
                local inZone   = zoneDist <= Config.FurniturePlacementRadius

                -- More opaque = bad (outside zone), normal alpha = good
                SetEntityAlpha(prop, inZone and 150 or 220, false)

                -- Prompt group label
                local groupStr = CreateVarString(10, 'LITERAL_STRING', Config.FurniturePromptGroupName)
                PromptSetActiveGroupThisFrame(promptGroup, groupStr)

                -- Out-of-zone HUD warning
                if not inZone then
                    local warnStr = CreateVarString(10, 'LITERAL_STRING',
                        'Outside property zone  ' .. math.floor(zoneDist) .. 'm / ' .. Config.FurniturePlacementRadius .. 'm max')
                    Citizen.InvokeNative(0xB87A37EEB7FAA67D, warnStr, 0.5, 0.92, 0.4, 0.35, 0)
                end

                -- Rotation
                if IsControlPressed(1, 0xA65EBAB4) then heading = heading + 1.0 end
                if IsControlPressed(1, 0xDEB34313) then heading = heading - 1.0 end
                if heading >  360.0 then heading = 0.0   end
                if heading <    0.0 then heading = 360.0 end

                -- Height
                if IsControlPressed(0, joaat('INPUT_FRONTEND_UP'))   then heightOffset = heightOffset + 0.05 end
                if IsControlPressed(0, joaat('INPUT_FRONTEND_DOWN'))  then heightOffset = heightOffset - 0.05 end

                -- Confirm (hold)
                if PromptHasHoldModeCompleted(SetPrompt) then
                    if not inZone then
                        lib.notify({
                            title       = 'Out of Zone',
                            description = 'Move inside your property zone to place furniture',
                            type        = 'error',
                            duration    = 3000,
                        })
                    else
                        confirmed = true
                        local ghostCoords = GetEntityCoords(prop)
                        if DoesEntityExist(prop) then DeleteObject(prop) end
                        SetModelAsNoLongerNeeded(propHash)
                        FurniturePlacementActive = false
                        TriggerServerEvent('st-housing:server:placeFurniture',
                            plotId, propModel,
                            ghostCoords.x, ghostCoords.y, ghostCoords.z,
                            heading
                        )
                    end
                end

                -- Cancel (hold)
                if PromptHasHoldModeCompleted(CancelPrompt) then
                    confirmed = true
                    if DoesEntityExist(prop) then DeleteObject(prop) end
                    SetModelAsNoLongerNeeded(propHash)
                    FurniturePlacementActive = false
                    TriggerServerEvent('st-housing:server:cancelFurniturePlacement')
                    lib.notify({ title = 'Cancelled', description = 'Furniture returned to inventory', type = 'inform' })
                end
            end

            Wait(0)
        end
        -- Restore collision on placed furniture now that the ghost is gone.
        SetPlacedFurnitureCollision(plotId, true)
    end)
end

-- =============================================
-- NET EVENT: START FURNITURE PLACEMENT
-- =============================================
RegisterNetEvent('st-housing:client:startFurniturePlacement', function(propModel, plotId, plotX, plotY, plotZ)
    RunFurniturePlacement(propModel, plotId, plotX, plotY, plotZ)
end)

-- =============================================
-- NET EVENT: UPDATE FURNITURE FOR ONE PLOT
-- =============================================
RegisterNetEvent('st-housing:client:updateFurnitureData', function(plotId, furnitureArray)
    local propData = nil
    for _, p in ipairs(Config.PlayerProps) do
        if p.plotid == plotId then
            propData = p
            break
        end
    end
    if not propData then return end
    propData.furniture = furnitureArray
    SpawnFurnitureForPlot(propData)
end)

-- =============================================
-- FORCE REMOVE PLOT — delete furniture too
-- =============================================
AddEventHandler('st-housing:client:forceRemovePlot', function(plotId)
    DeleteFurnitureForPlot(plotId)
end)

-- =============================================
-- CLEANUP ON RESOURCE STOP
-- =============================================
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for plotId, _ in pairs(SpawnedFurniture) do
        DeleteFurnitureForPlot(plotId)
    end
end)
