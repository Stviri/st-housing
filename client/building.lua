-- Construction site interactions, progress bar, deposit menu
-- Key/ownership management menus

local RSGCore = exports['rsg-core']:GetCoreObject()

-- =============================================
-- PROGRESS CALCULATION
-- Returns 0-100 based on deposited vs required materials
-- =============================================
local function CalculateProgress(depositedMaterials, houseType)
    local houseConfig = Config.Houses[houseType]
    if not houseConfig then return 0 end

    local totalRequired  = 0
    local totalDeposited = 0

    for _, mat in ipairs(houseConfig.totalMaterials) do
        totalRequired  = totalRequired  + mat.amount
        local deposited = depositedMaterials[mat.item] or 0
        totalDeposited = totalDeposited + math.min(deposited, mat.amount)
    end

    if totalRequired == 0 then return 100 end
    return math.floor((totalDeposited / totalRequired) * 100)
end

-- =============================================
-- DRAW PROGRESS BAR ABOVE GHOST PROP
-- Called every frame when player is near incomplete plot
-- Uses DrawMarker for background and fill
-- =============================================
local function DrawProgressBar(coords, progress, label)
    local barPos = vector3(coords.x, coords.y, coords.z + 3.5)

    -- Background (grey)
    DrawMarker(28,
        barPos.x, barPos.y, barPos.z,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        2.0, 0.25, 0.05,
        50, 50, 50, 180,
        false, true, 2, false, nil, nil, false
    )

    -- Progress fill (green, width scales with progress)
    local fillWidth = math.max(0.01, (progress / 100.0) * 2.0)
    local fillOffsetX = (2.0 - fillWidth) / 2.0
    DrawMarker(28,
        barPos.x - fillOffsetX, barPos.y, barPos.z + 0.01,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        fillWidth, 0.25, 0.05,
        80, 200, 80, 200,
        false, true, 2, false, nil, nil, false
    )
end

-- =============================================
-- MAIN INTERACTION MENU
-- Opens when player interacts with plot via ox_target
-- Shows different options for owner, key holder, stranger
-- =============================================
local function OpenPlotMenu(plotId, plotData)
    local houseConfig = Config.Houses[plotData.house_type]
    if not houseConfig then return end

    local PlayerData    = RSGCore.Functions.GetPlayerData()
    local citizenid     = PlayerData.citizenid
    local isOwner       = plotData.citizenid == citizenid
    local depositedMats = plotData.stage_materials or {}
    local progress      = CalculateProgress(depositedMats, plotData.house_type)

    -- Check if player has key
    local hasKey = false
    if plotData.allowed_players then
        for _, cid in ipairs(plotData.allowed_players) do
            if cid == citizenid then hasKey = true break end
        end
    end

    local options = {}

    -- Progress header (always visible)
    table.insert(options, {
        title    = houseConfig.label .. ' — ' .. progress .. '% Built',
        disabled = true,
        icon     = 'fa-solid fa-hammer',
    })

    -- Lock / Unlock door (owner or key holder, completed house only)
    if (isOwner or hasKey) and plotData.is_complete == 1 then
        local isLocked = plotData.is_locked == 1
        table.insert(options, {
            title = isLocked and 'Unlock Door' or 'Lock Door',
            icon  = isLocked and 'fa-solid fa-lock-open' or 'fa-solid fa-lock',
            event = 'st-housing:client:toggleDoorLock',
            args  = { plotId = plotId, locked = not isLocked },
            arrow = true,
        })
    end

    -- Construction options (owner or key holder only)
    if isOwner or hasKey then
        if plotData.is_complete == 0 then
            -- Deposit materials
            for _, mat in ipairs(houseConfig.totalMaterials) do
                local deposited = depositedMats[mat.item] or 0
                local remaining = math.max(0, mat.amount - deposited)
                local itemLabel = RSGCore.Shared.Items[mat.item] and RSGCore.Shared.Items[mat.item].label or mat.item

                if remaining > 0 then
                    table.insert(options, {
                        title       = 'Deposit ' .. itemLabel,
                        description = deposited .. ' / ' .. mat.amount .. ' (' .. remaining .. ' remaining)',
                        icon        = 'fa-solid fa-box',
                        event       = 'st-housing:client:depositMaterial',
                        args        = { plotId = plotId, item = mat.item, maxAmount = remaining },
                        arrow       = true,
                    })
                else
                    table.insert(options, {
                        title    = itemLabel .. ' ✓',
                        description = mat.amount .. ' / ' .. mat.amount,
                        icon     = 'fa-solid fa-check',
                        disabled = true,
                    })
                end
            end
        else
            -- House complete — storage access
            table.insert(options, {
                title = 'Open Storage',
                icon  = 'fa-solid fa-box-open',
                event = 'st-housing:client:openStorage',
                args  = { plotId = plotId },
                arrow = true,
            })
        end
    end

    -- Owner only options
    if isOwner then
        table.insert(options, {
            title = 'Manage Keys',
            icon  = 'fa-solid fa-key',
            event = 'st-housing:client:manageKeys',
            args  = { plotId = plotId },
            arrow = true,
        })

        table.insert(options, {
            title       = 'Pay Property Tax',
            description = '$' .. houseConfig.taxPerDay .. ' per day',
            icon        = 'fa-solid fa-coins',
            event       = 'st-housing:client:payTax',
            args        = { plotId = plotId },
            arrow       = true,
        })

        if plotData.is_complete == 0 then
            table.insert(options, {
                title       = 'Adjust Placement',
                description = 'Reposition the ghost before building',
                icon        = 'fa-solid fa-arrows-up-down-left-right',
                event       = 'st-housing:client:adjustPlacement',
                args        = { plotId = plotId },
                arrow       = true,
            })
        end

        if plotData.is_complete == 1 then
            table.insert(options, {
                title = 'Transfer Ownership',
                icon  = 'fa-solid fa-handshake',
                event = 'st-housing:client:transferOwnership',
                args  = { plotId = plotId },
                arrow = true,
            })
        end

        -- Ghost phase: cancel and return plan. Completed phase: permanent demolish.
        if plotData.is_complete == 0 then
            table.insert(options, {
                title       = 'Cancel Building',
                description = 'Remove ghost and return building plan',
                icon        = 'fa-solid fa-xmark',
                event       = 'st-housing:client:cancelBuilding',
                args        = { plotId = plotId },
                arrow       = true,
            })
        else
            table.insert(options, {
                title       = 'Demolish Property',
                description = 'WARNING: Permanent',
                icon        = 'fa-solid fa-trash',
                event       = 'st-housing:client:confirmDemolish',
                args        = { plotId = plotId },
                arrow       = true,
            })
        end

        -- Debug-only: instant complete build without materials
        if Config.Debug and plotData.is_complete == 0 then
            table.insert(options, {
                title       = '[DEBUG] Instant Build',
                description = 'Fill all materials and complete house immediately',
                icon        = 'fa-solid fa-bug',
                event       = 'st-housing:client:debugBuild',
                args        = { plotId = plotId },
                arrow       = true,
            })
        end
    end

    lib.registerContext({ id = 'housing_plot_menu', title = houseConfig.label, options = options })
    lib.showContext('housing_plot_menu')
end

-- =============================================
-- DEPOSIT MATERIAL
-- =============================================
RegisterNetEvent('st-housing:client:depositMaterial', function(data)
    local input = lib.inputDialog('Deposit Materials', {
        {
            type    = 'number',
            label   = 'Amount (max ' .. data.maxAmount .. ')',
            required = true,
            min     = 1,
            max     = data.maxAmount,
            default = data.maxAmount,
        }
    })
    if not input or not input[1] then return end
    TriggerServerEvent('st-housing:server:depositMaterial', data.plotId, data.item, tonumber(input[1]))
end)

-- =============================================
-- OPEN STORAGE
-- =============================================
RegisterNetEvent('st-housing:client:openStorage', function(data)
    TriggerServerEvent('st-housing:server:openStorage', data.plotId)
end)

-- =============================================
-- PAY TAX
-- =============================================
RegisterNetEvent('st-housing:client:payTax', function(data)
    TriggerServerEvent('st-housing:server:payTax', data.plotId)
end)

-- =============================================
-- KEY MANAGEMENT
-- =============================================
RegisterNetEvent('st-housing:client:manageKeys', function(data)
    RSGCore.Functions.TriggerCallback('st-housing:server:getKeyHolders', function(keyHolders)
        local options = {
            {
                title       = 'Give Key to Player',
                description = 'Enter their server ID',
                icon        = 'fa-solid fa-user-plus',
                event       = 'st-housing:client:giveKey',
                args        = { plotId = data.plotId },
                arrow       = true,
            }
        }
        if #keyHolders == 0 then
            table.insert(options, {
                title    = 'No key holders yet',
                disabled = true,
                icon     = 'fa-solid fa-info-circle',
            })
        else
            for _, holder in ipairs(keyHolders) do
                table.insert(options, {
                    title       = holder.name,
                    description = 'Click to revoke key',
                    icon        = 'fa-solid fa-user-minus',
                    event       = 'st-housing:client:revokeKey',
                    args        = { plotId = data.plotId, citizenid = holder.citizenid, name = holder.name },
                    arrow       = true,
                })
            end
        end
        lib.registerContext({ id = 'housing_keys_menu', title = 'Key Management', options = options })
        lib.showContext('housing_keys_menu')
    end, data.plotId)
end)

RegisterNetEvent('st-housing:client:giveKey', function(data)
    local input = lib.inputDialog('Give Key', {
        { type = 'number', label = 'Player Server ID', required = true, min = 1 }
    })
    if not input or not input[1] then return end
    TriggerServerEvent('st-housing:server:giveKey', data.plotId, tonumber(input[1]))
end)

RegisterNetEvent('st-housing:client:revokeKey', function(data)
    local confirm = lib.alertDialog({
        header  = 'Revoke Key',
        content = 'Remove ' .. data.name .. '\'s access?',
        centered = true,
        cancel  = true,
    })
    if confirm == 'confirm' then
        TriggerServerEvent('st-housing:server:revokeKey', data.plotId, data.citizenid)
    end
end)

-- =============================================
-- OWNERSHIP TRANSFER
-- =============================================
RegisterNetEvent('st-housing:client:transferOwnership', function(data)
    local input = lib.inputDialog('Transfer Ownership', {
        { type = 'number', label = 'Target Player Server ID', required = true, min = 1 }
    })
    if not input or not input[1] then return end
    TriggerServerEvent('st-housing:server:transferOwnership', data.plotId, tonumber(input[1]))
end)

-- =============================================
-- DEMOLISH
-- =============================================
RegisterNetEvent('st-housing:client:confirmDemolish', function(data)
    local confirm = lib.alertDialog({
        header  = 'Demolish Property',
        content = 'This permanently removes your property and all stored items. Are you sure?',
        centered = true,
        cancel  = true,
    })
    if confirm == 'confirm' then
        TriggerServerEvent('st-housing:server:demolishPlot', data.plotId)
    end
end)

-- =============================================
-- DEBUG INSTANT BUILD
-- =============================================
RegisterNetEvent('st-housing:client:debugBuild', function(data)
    TriggerServerEvent('st-housing:server:debugBuild', data.plotId)
end)

-- =============================================
-- DOOR LOCK TOGGLE
-- =============================================
RegisterNetEvent('st-housing:client:toggleDoorLock', function(data)
    TriggerServerEvent('st-housing:server:setDoorLock', data.plotId, data.locked)
end)

-- =============================================
-- ADJUST PLACEMENT
-- Owner opens the placement UI to fine-tune house position.
-- Movement is capped to 30m from the current stored coords server-side.
-- =============================================
RegisterNetEvent('st-housing:client:adjustPlacement', function(data)
    local plotData = nil
    for _, p in ipairs(Config.PlayerProps) do
        if p.plotid == data.plotId then plotData = p break end
    end
    if not plotData then return end

    local houseConfig = Config.Houses[plotData.house_type]
    if not houseConfig then return end

    -- Remove the existing ghost locally so it doesn't overlap with the placement ghost.
    -- The spawn loop will re-spawn it at the old coords on cancel, or at new coords on confirm.
    exports['st-housing']:HideLocalProp(data.plotId)

    exports['st-housing']:StartAdjustmentPlacement(
        data.plotId,
        plotData.house_type,
        houseConfig,
        tonumber(plotData.heading) or 0.0
    )
end)

-- =============================================
-- CANCEL BUILDING (ghost phase only)
-- Demolishes the ghost plot and returns the building plan to the owner.
-- =============================================
RegisterNetEvent('st-housing:client:cancelBuilding', function(data)
    local confirm = lib.alertDialog({
        header   = 'Cancel Building',
        content  = 'Remove the ghost and return your building plan to inventory?',
        centered = true,
        cancel   = true,
    })
    if confirm == 'confirm' then
        TriggerServerEvent('st-housing:server:cancelBuilding', data.plotId)
    end
end)

-- Export for use in client.lua
exports('OpenPlotMenu',       OpenPlotMenu)
exports('DrawProgressBar',    DrawProgressBar)
exports('CalculateProgress',  CalculateProgress)
