-- Ghost prop placement system
-- Handles both initial placement and owner adjustment (ghost-phase reposition).

local isPlacing = false

-- =============================================
-- MATH HELPERS
-- =============================================
local function RotationToDirection(rotation)
    local r = {
        x = (math.pi / 180) * rotation.x,
        y = (math.pi / 180) * rotation.y,
        z = (math.pi / 180) * rotation.z,
    }
    return {
        x = -math.sin(r.z) * math.abs(math.cos(r.x)),
        y =  math.cos(r.z) * math.abs(math.cos(r.x)),
        z =  math.sin(r.x),
    }
end

local function RayCastGamePlayCamera(distance)
    local camRot   = GetGameplayCamRot()
    local camCoord = GetGameplayCamCoord()
    local dir      = RotationToDirection(camRot)

    local dest = {
        x = camCoord.x + dir.x * distance,
        y = camCoord.y + dir.y * distance,
        z = camCoord.z + dir.z * distance,
    }

    local _, hit, coords, _, entity = GetShapeTestResult(
        StartShapeTestRay(
            camCoord.x, camCoord.y, camCoord.z,
            dest.x, dest.y, dest.z,
            -1, PlayerPedId(), 0
        )
    )

    return hit, coords, entity
end

-- =============================================
-- VALIDATION
-- opts (optional table):
--   skipPlotId — plotId whose own coords are excluded from proximity check
-- =============================================
local function IsValidPlacement(coords, opts)
    opts = opts or {}
    local x, y, z = table.unpack(GetEntityCoords(cache.ped))

    local inTown = Citizen.InvokeNative(0x43AD8FC02B429D33, x, y, z, 1)
    if inTown ~= false then
        return false, 'Cannot place inside a town'
    end

    for _, prop in ipairs(Config.PlayerProps) do
        if opts.skipPlotId and prop.plotid == opts.skipPlotId then goto nextprop end
        local propCoords = vector3(prop.x, prop.y, prop.z)
        if #(coords - propCoords) < Config.MinPlotDistance then
            return false, 'Too close to another property'
        end
        ::nextprop::
    end

    return true, nil
end

-- =============================================
-- SHARED PLACEMENT LOOP
-- opts (required):
--   houseConfig — Config.Houses[houseType] table
--   onConfirm   — function(ghostCoords, heading) called on successful confirm
-- opts (optional):
--   initialHeading — starting heading (default 0.0)
--   validationOpts — table passed through to IsValidPlacement
--   onCancel       — function() called when player cancels; use to return items
-- =============================================
local function RunPlacementLoop(opts)
    if isPlacing then
        lib.notify({ title = 'Already Placing', description = 'Finish current placement first', type = 'error' })
        return
    end
    isPlacing = true

    local houseConfig  = opts.houseConfig
    local propHash     = joaat(houseConfig.propmodel)
    local prop         = nil
    local heading      = opts.initialHeading or 0.0
    local heightOffset = 0.0
    local confirmed    = false
    local validOpts    = opts.validationOpts or {}

    -- Load model
    RequestModel(propHash)
    local attempts = 0
    while not HasModelLoaded(propHash) and attempts < 200 do
        Wait(10)
        attempts = attempts + 1
    end

    if not HasModelLoaded(propHash) then
        lib.notify({ title = 'Error', description = 'Could not load house model', type = 'error' })
        if opts.onCancel then opts.onCancel() end  -- each caller handles its own side-effects
        isPlacing = false
        return
    end

    -- Initial raycast to seed ghost position
    local hit, coords = RayCastGamePlayCamera(Config.PlaceDistance)
    if not hit then
        lib.notify({ title = 'Error', description = 'Could not find placement location', type = 'error' })
        SetModelAsNoLongerNeeded(propHash)
        if opts.onCancel then opts.onCancel() end
        isPlacing = false
        return
    end

    prop = CreateObject(propHash, coords.x, coords.y, coords.z, false, false, false)
    SetEntityAlpha(prop, 150, false)
    SetEntityCollision(prop, false, false)
    FreezeEntityPosition(prop, true)

    -- Placement loop
    CreateThread(function()
        while not confirmed do
            hit, coords = RayCastGamePlayCamera(Config.PlaceDistance)

            if hit then
                local finalZ      = coords.z + heightOffset
                local finalCoords = vector3(coords.x, coords.y, finalZ)

                SetEntityCoordsNoOffset(prop, coords.x, coords.y, finalZ, false, false, false, true)
                SetEntityHeading(prop, heading)

                local isValid, reason = IsValidPlacement(finalCoords, validOpts)
                SetEntityAlpha(prop, isValid and 150 or 220, false)

                local groupName = CreateVarString(10, 'LITERAL_STRING', Config.PromptGroupName)
                PromptSetActiveGroupThisFrame(
                    exports['st-housing']:GetHousingPromptGroup(),
                    groupName
                )

                -- Rotation
                if IsControlPressed(1, 0xA65EBAB4) then
                    heading = heading + 1.0
                elseif IsControlPressed(1, 0xDEB34313) then
                    heading = heading - 1.0
                end
                if heading > 360.0 then heading = 0.0   end
                if heading < 0.0   then heading = 360.0 end

                -- Height adjust
                if IsControlPressed(0, joaat('INPUT_FRONTEND_UP')) then
                    heightOffset = heightOffset + 0.05
                elseif IsControlPressed(0, joaat('INPUT_FRONTEND_DOWN')) then
                    heightOffset = heightOffset - 0.05
                end

                -- Confirm
                if PromptHasHoldModeCompleted(SetPrompt) then
                    if not isValid then
                        lib.notify({ title = 'Invalid Location', description = reason, type = 'error', duration = 4000 })
                    else
                        confirmed = true
                        local ghostCoords = GetEntityCoords(prop)
                        DeleteObject(prop)
                        SetModelAsNoLongerNeeded(propHash)
                        opts.onConfirm(ghostCoords, heading)
                        isPlacing = false
                    end
                end

                -- Cancel
                if PromptHasHoldModeCompleted(CancelPrompt) then
                    confirmed = true
                    if DoesEntityExist(prop) then DeleteObject(prop) end
                    SetModelAsNoLongerNeeded(propHash)
                    isPlacing = false
                    if opts.onCancel then opts.onCancel() end
                end
            end

            Wait(0)
        end
    end)
end

-- =============================================
-- INITIAL PLACEMENT (use building plan item)
-- onCancel returns the plan to inventory via server event.
-- =============================================
local function PlaceHouseProp(houseType, houseConfig)
    RunPlacementLoop({
        houseConfig = houseConfig,
        onConfirm   = function(ghostCoords, heading)
            TriggerServerEvent('st-housing:server:createPlot', houseType, ghostCoords, heading)
        end,
        onCancel = function()
            -- Return plan and notify only for initial placement cancel.
            -- Ghost-phase adjustment cancel has its own onCancel that does NOT return the plan.
            TriggerServerEvent('st-housing:server:returnHousePlan', houseType)
            lib.notify({ title = 'Cancelled', description = 'Placement cancelled — plan returned to inventory', type = 'inform' })
        end,
    })
end

-- =============================================
-- ADJUSTMENT PLACEMENT (owner repositions ghost-phase house)
-- plotId        — which plot is being moved
-- houseType     — string key into Config.Houses
-- houseConfig   — Config.Houses[houseType]
-- currentHeading — ghost starts at this heading
-- =============================================
local function StartAdjustmentPlacement(plotId, houseType, houseConfig, currentHeading)
    RunPlacementLoop({
        houseConfig    = houseConfig,
        initialHeading = currentHeading,
        validationOpts = {
            skipPlotId = plotId,  -- don't flag own plot as "too close"
        },
        onConfirm = function(ghostCoords, heading)
            -- Server will broadcast forceRemovePlot which calls AllowPlotSpawn,
            -- then updatePropData with new coords so the spawn loop re-spawns there.
            TriggerServerEvent('st-housing:server:adjustPlotPosition', plotId, ghostCoords, heading)
        end,
        onCancel = function()
            -- Lift suppression so the spawn loop re-spawns the original ghost in place.
            -- No plan is returned — the ghost plot still exists; player is just cancelling the reposition.
            exports['st-housing']:AllowPlotSpawn(plotId)
            lib.notify({ title = 'Cancelled', description = 'Placement adjustment cancelled', type = 'inform' })
        end,
    })
end

-- =============================================
-- EVENTS
-- =============================================
RegisterNetEvent('st-housing:client:startPlacement', function(houseType)
    local houseConfig = Config.Houses[houseType]
    if not houseConfig then return end
    PlaceHouseProp(houseType, houseConfig)
end)

-- Export for use in building.lua
exports('StartAdjustmentPlacement', StartAdjustmentPlacement)
