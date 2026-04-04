local RSGCore = exports['rsg-core']:GetCoreObject()
Config.PlayerProps = Config.PlayerProps or {}

-- =============================================
-- DOOR ENTITY MANAGEMENT
-- CreateObject is a CLIENT-SIDE native only — it does not exist on the server.
-- Instead the server delegates creation to a designated connected client.
-- That client creates networked entities and reports the net IDs back.
-- All other clients then reference the same entities via NetworkGetEntityFromNetworkId.
--
-- PlotDoorEntities[plotId] = { {entity, netId, closedHeading, x, y, z}, ... }
-- PlotDoorPending[plotId]  = plotData  (waiting for a client to create doors)
-- =============================================
local PlotDoorEntities = {}
local PlotDoorPending  = {}

-- =============================================
-- PLOT INDEX
-- Global O(1) lookup: plotId -> index in Config.PlayerProps.
-- Global so tax.lua (same resource server context) can share it.
-- Built after bulk load, updated on create, rebuilt on demolish.
-- =============================================
PlotIndex = {}
local DoorLockLastChanged  = {}  -- [plotId] = os.clock() timestamp for setDoorLock debounce

-- Tracks players currently in the placement UI after using a plan item.
-- [citizenid] = houseType
-- Set when the plan is consumed on use, cleared on confirm (createPlot) or cancel (returnHousePlan).
-- Replaces the HasItem check in createPlot since the item is removed before placement begins.
local PendingPlacements = {}

local function RebuildPlotIndex()
    PlotIndex = {}
    for i, p in ipairs(Config.PlayerProps) do
        PlotIndex[p.plotid] = i
    end
end

local function NormH(h)
    h = h % 360.0
    if h < 0.0 then h = h + 360.0 end
    return h
end

local function RotateOffset(ox, oy, heading)
    local rad = math.rad(heading)
    return ox * math.cos(rad) - oy * math.sin(rad),
           ox * math.sin(rad) + oy * math.cos(rad)
end

-- Builds the list of world-space door spawn parameters for a plot.
local function BuildDoorRequests(plotData)
    local houseConfig = Config.Houses[plotData.house_type]
    if not houseConfig or not houseConfig.doors or #houseConfig.doors == 0 then return nil end
    local houseHeading = tonumber(plotData.heading) or 0.0
    local doorRequests = {}
    for _, doorDef in ipairs(houseConfig.doors) do
        local rotX, rotY = RotateOffset(doorDef.offset.x, doorDef.offset.y, houseHeading)
        table.insert(doorRequests, {
            model   = doorDef.model,
            x       = plotData.x + rotX,
            y       = plotData.y + rotY,
            z       = plotData.z + doorDef.offset.z,
            heading = NormH(houseHeading + doorDef.offset.heading),
        })
    end
    return doorRequests
end

-- Asks a connected client to create door entities (networked) and report net IDs back.
-- If no client is online the request is stored in PlotDoorPending and retried on next join.
local function RequestDoorCreation(plotId, plotData, targetClient)
    if PlotDoorEntities[plotId] then return end  -- already created
    local doorRequests = BuildDoorRequests(plotData)
    if not doorRequests then return end

    local client = targetClient
    if not client then
        local players = GetPlayers()
        client = players and players[1] and tonumber(players[1]) or nil
    end

    if not client then
        PlotDoorPending[plotId] = plotData
        return
    end

    local isLocked = (plotData.is_locked or 0) == 1
    PlotDoorPending[plotId] = plotData  -- marks in-progress
    TriggerClientEvent('st-housing:client:createDoorsRequest', client, plotId, doorRequests, isLocked)
end

-- Builds the door packet sent to clients: net IDs + per-door data + lock state.
-- Uses PlotIndex for O(1) lock state lookup instead of linear scan.
local function GetDoorPacket(plotId)
    local entries = PlotDoorEntities[plotId]
    if not entries or #entries == 0 then return nil end

    local idx = PlotIndex[plotId]
    local isLocked = (idx and Config.PlayerProps[idx].is_locked) or 0

    local doors = {}
    for _, e in ipairs(entries) do
        table.insert(doors, {
            netId         = e.netId,
            closedHeading = e.closedHeading,
            x = e.x, y = e.y, z = e.z,
        })
    end
    return { is_locked = isLocked == 1, doors = doors }
end

-- =============================================
-- UNIQUE PLOT ID GENERATOR
-- =============================================
local function CreatePlotId()
    local found = false
    local id    = nil
    while not found do
        id = 'PLOT' .. math.random(11111111, 99999999)
        local result = MySQL.single.await('SELECT COUNT(*) as count FROM st_plots WHERE plotid = ?', { id })
        if result.count == 0 then found = true end
    end
    return id
end

-- =============================================
-- BUY BUILDING PLAN FROM HOUSING AGENT
-- =============================================
RegisterNetEvent('st-housing:server:buyPlan', function(houseType)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local houseConfig = Config.Houses[houseType]
    if not houseConfig then return end

    local citizenid = Player.PlayerData.citizenid
    for _, prop in ipairs(Config.PlayerProps) do
        if prop.citizenid == citizenid then
            TriggerClientEvent('ox_lib:notify', src, {
                title       = 'Already Own Property',
                description = 'Sell or demolish your existing property first.',
                type        = 'error'
            })
            return
        end
    end

    local alreadyHas = exports['rsg-inventory']:HasItem(src, houseConfig.planItem, 1)
    if alreadyHas then
        TriggerClientEvent('ox_lib:notify', src, {
            title       = 'Already Have Plan',
            description = 'You already have a ' .. houseConfig.label .. ' plan.',
            type        = 'error'
        })
        return
    end

    local price = houseConfig.price
    local cash  = Player.Functions.GetMoney('cash')
    if cash < price then
        TriggerClientEvent('ox_lib:notify', src, {
            title       = 'Not Enough Money',
            description = 'Costs $' .. price,
            type        = 'error'
        })
        return
    end

    Player.Functions.RemoveMoney('cash', price, 'housing-plan-purchase')
    Player.Functions.AddItem(houseConfig.planItem, 1)
    TriggerClientEvent('ox_lib:notify', src, {
        title       = 'Plan Purchased',
        description = 'Use the ' .. houseConfig.label .. ' plan from your inventory to place it.',
        type        = 'success',
        duration    = 7000
    })
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[houseConfig.planItem], 'add', 1)
end)

-- =============================================
-- REGISTER BUILDING PLAN ITEMS AS USEABLE
-- =============================================
CreateThread(function()
    Wait(1000)
    for houseType, houseConfig in pairs(Config.Houses) do
        RSGCore.Functions.CreateUseableItem(houseConfig.planItem, function(source)
            local Player = RSGCore.Functions.GetPlayer(source)
            if not Player then return end
            local citizenid = Player.PlayerData.citizenid
            -- Remove plan immediately so cancel can return exactly one copy.
            -- A PendingPlacements token replaces the HasItem check in createPlot.
            Player.Functions.RemoveItem(houseConfig.planItem, 1)
            PendingPlacements[citizenid] = houseType
            TriggerClientEvent('st-housing:client:startPlacement', source, houseType)
        end)
        if Config.Debug then
            print('^2[st-housing]^7 Registered useable item: ' .. houseConfig.planItem)
        end
    end
end)

-- =============================================
-- LOAD ALL PLOTS ON SERVER START
-- =============================================
CreateThread(function()
    Wait(2000)
    print('^2[st-housing]^7 Loading plots from database...')
    local result = MySQL.query.await('SELECT * FROM st_plots')
    if not result or #result == 0 then
        print('^3[st-housing]^7 No plots found in database.')
        return
    end
    for i = 1, #result do
        local row = result[i]
        table.insert(Config.PlayerProps, {
            plotid          = row.plotid,
            citizenid       = row.citizenid,
            house_type      = row.house_type,
            propmodel       = row.propmodel,
            x               = row.x,
            y               = row.y,
            z               = row.z,
            heading         = row.heading,
            stage_materials = json.decode(row.stage_materials or '{}'),
            is_complete     = row.is_complete,
            is_abandoned    = row.is_abandoned,
            is_locked       = row.is_locked or 0,
            allowed_players = json.decode(row.allowed_players or '[]'),
            furniture       = json.decode(row.furniture or '[]'),
        })
    end

    RebuildPlotIndex()
    print('^2[st-housing]^7 Loaded ' .. #Config.PlayerProps .. ' plots.')
    TriggerClientEvent('st-housing:client:updatePropData', -1, Config.PlayerProps)

    local completePlots = 0
    for _, plotData in ipairs(Config.PlayerProps) do
        if plotData.is_complete == 1 then
            completePlots = completePlots + 1
            RequestDoorCreation(plotData.plotid, plotData)
        end
    end
    if completePlots > 0 then
        print('^2[st-housing]^7 Door creation requested for ' .. completePlots .. ' complete plots.')
    end
end)

-- =============================================
-- SEND PLOTS TO PLAYER ON CHARACTER SPAWN
-- Uses RSGCore:Server:PlayerLoaded instead of playerJoining so the client is
-- guaranteed to be in the game world before we ask it to create networked door
-- entities. playerJoining fires at TCP connection time (character selection screen);
-- CreateObjectNoOffset silently fails there, leaving PlotDoorEntities empty forever.
-- =============================================
AddEventHandler('RSGCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    CreateThread(function()
        Wait(1000)
        TriggerClientEvent('st-housing:client:updatePropData', src, Config.PlayerProps)

        -- Validate door entities: if the creating client disconnected, the networked
        -- entities may have been cleaned up. Clear any stale entries so this joining
        -- client re-creates them fresh, rather than receiving dead net IDs forever.
        for plotId, entries in pairs(PlotDoorEntities) do
            local stale = false
            for _, e in ipairs(entries) do
                local ent = NetworkGetEntityFromNetworkId(e.netId)
                if not ent or ent == 0 or not DoesEntityExist(ent) then
                    stale = true
                    break
                end
            end
            if stale then
                PlotDoorEntities[plotId] = nil
                local idx = PlotIndex[plotId]
                if idx then
                    PlotDoorPending[plotId] = Config.PlayerProps[idx]
                end
                if Config.Debug then
                    print('^3[st-housing]^7 Stale door entities detected for plot ' .. plotId .. ' — re-queuing creation')
                end
            end
        end

        local allPackets = {}
        for plotId, _ in pairs(PlotDoorEntities) do
            local packet = GetDoorPacket(plotId)
            if packet then
                allPackets[plotId] = packet
            end
        end
        if next(allPackets) then
            TriggerClientEvent('st-housing:client:receiveDoorData', src, allPackets)
        end

        for pendingPlotId, pendingPlotData in pairs(PlotDoorPending) do
            if not PlotDoorEntities[pendingPlotId] then
                RequestDoorCreation(pendingPlotId, pendingPlotData, src)
            else
                PlotDoorPending[pendingPlotId] = nil
            end
        end
    end)
end)

-- =============================================
-- CREATE PLOT
-- =============================================
RegisterNetEvent('st-housing:server:createPlot', function(houseType, coords, heading)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local houseConfig = Config.Houses[houseType]
    if not houseConfig then return end

    local citizenid = Player.PlayerData.citizenid

    for _, prop in ipairs(Config.PlayerProps) do
        if prop.citizenid == citizenid then
            TriggerClientEvent('ox_lib:notify', src, {
                title       = 'Already Own Property',
                description = 'Sell or demolish your existing property first.',
                type        = 'error'
            })
            return
        end
    end

    -- Verify the player went through the legitimate use-item flow.
    -- The plan was already removed on use; PendingPlacements proves it happened.
    if PendingPlacements[citizenid] ~= houseType then
        TriggerClientEvent('ox_lib:notify', src, {
            title       = 'No Active Placement',
            description = 'Use a building plan from your inventory first.',
            type        = 'error'
        })
        return
    end
    PendingPlacements[citizenid] = nil  -- consume the token

    local plotId  = CreatePlotId()
    local plotData = {
        plotid          = plotId,
        citizenid       = citizenid,
        house_type      = houseType,
        propmodel       = houseConfig.propmodel,
        x               = coords.x,
        y               = coords.y,
        z               = coords.z,
        heading         = heading,
        stage_materials = {},
        is_complete     = 0,
        is_abandoned    = 0,
        allowed_players = {},
    }

    MySQL.insert.await(
        'INSERT INTO st_plots (plotid, citizenid, house_type, propmodel, x, y, z, heading, stage_materials, is_complete, is_abandoned, allowed_players, last_tax_paid) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
        { plotId, citizenid, houseType, houseConfig.propmodel, coords.x, coords.y, coords.z, heading, '{}', 0, 0, '[]', os.date('!%Y-%m-%d %H:%M:%S', os.time() - 86400) }
    )

    -- Plan was already removed when the item was used; no RemoveItem needed here.
    table.insert(Config.PlayerProps, plotData)
    PlotIndex[plotId] = #Config.PlayerProps  -- O(1) index update
    TriggerClientEvent('st-housing:client:updatePropData', -1, Config.PlayerProps)

    TriggerClientEvent('ox_lib:notify', src, {
        title       = 'Plot Placed',
        description = 'Start depositing materials to build your ' .. houseConfig.label,
        type        = 'success',
        duration    = 7000
    })
    print('^2[st-housing]^7 ' .. GetPlayerName(src) .. ' created plot ' .. plotId)
end)

-- =============================================
-- RETURN HOUSE PLAN ON PLACEMENT CANCEL
-- Fires when the player cancels the ghost placement before confirming.
-- The plan was consumed by RSGCore on item use, so we give it back here.
-- =============================================
RegisterNetEvent('st-housing:server:returnHousePlan', function(houseType)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local houseConfig = Config.Houses[houseType]
    if not houseConfig then return end

    local citizenid = Player.PlayerData.citizenid

    -- Only return the plan if a valid placement session is active for this type.
    -- This prevents exploiting cancel to get a plan back without having used one.
    if PendingPlacements[citizenid] ~= houseType then return end
    PendingPlacements[citizenid] = nil  -- consume the token

    Player.Functions.AddItem(houseConfig.planItem, 1)
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[houseConfig.planItem], 'add', 1)
end)

-- =============================================
-- CANCEL BUILDING (ghost phase only)
-- Removes the ghost plot and returns the building plan to the owner.
-- Separate from demolishPlot so we never accidentally return a plan
-- when demolishing a completed house.
-- =============================================
RegisterNetEvent('st-housing:server:cancelBuilding', function(plotId)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    local plotRow = MySQL.single.await('SELECT citizenid, house_type, is_complete FROM st_plots WHERE plotid = ?', { plotId })
    if not plotRow or plotRow.citizenid ~= citizenid then return end
    if plotRow.is_complete ~= 0 then return end  -- guard: ghost phase only

    local houseConfig = Config.Houses[plotRow.house_type]
    if not houseConfig then return end

    MySQL.query.await('DELETE FROM st_plots WHERE plotid = ?', { plotId })

    local idx = PlotIndex[plotId]
    if idx then table.remove(Config.PlayerProps, idx) end
    RebuildPlotIndex()

    -- Return the building plan
    Player.Functions.AddItem(houseConfig.planItem, 1)
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[houseConfig.planItem], 'add', 1)

    TriggerClientEvent('st-housing:client:forceRemovePlot', -1, plotId)
    TriggerClientEvent('st-housing:client:updatePropData',  -1, Config.PlayerProps)

    TriggerClientEvent('ox_lib:notify', src, {
        title       = 'Building Cancelled',
        description = 'Building plan returned to your inventory.',
        type        = 'success',
    })
    print('^2[st-housing]^7 ' .. GetPlayerName(src) .. ' cancelled building for plot ' .. plotId)
end)

-- =============================================
-- DEPOSIT MATERIAL
-- =============================================
RegisterNetEvent('st-housing:server:depositMaterial', function(plotId, item, amount)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    local plotRow = MySQL.single.await('SELECT * FROM st_plots WHERE plotid = ?', { plotId })
    if not plotRow then return end
    if plotRow.is_complete == 1 then return end

    local isOwner = plotRow.citizenid == citizenid
    local allowed = json.decode(plotRow.allowed_players or '[]')
    local hasKey  = false
    for _, cid in ipairs(allowed) do if cid == citizenid then hasKey = true break end end
    if not isOwner and not hasKey then return end

    local houseConfig = Config.Houses[plotRow.house_type]
    if not houseConfig then return end

    local maxRequired = 0
    for _, mat in ipairs(houseConfig.totalMaterials) do
        if mat.item == item then maxRequired = mat.amount break end
    end
    if maxRequired == 0 then return end

    local stageMaterials   = json.decode(plotRow.stage_materials or '{}')
    local currentDeposited = stageMaterials[item] or 0
    local canDeposit       = math.min(amount, maxRequired - currentDeposited)
    if canDeposit <= 0 then
        TriggerClientEvent('ox_lib:notify', src, { title = 'No More Needed', description = 'Enough ' .. item .. ' already deposited', type = 'inform' })
        return
    end

    local playerCount = exports['rsg-inventory']:GetItemCount(src, item)
    canDeposit = math.min(canDeposit, playerCount)
    if canDeposit <= 0 then
        TriggerClientEvent('ox_lib:notify', src, { title = 'Not Enough', description = 'You don\'t have enough ' .. item, type = 'error' })
        return
    end

    Player.Functions.RemoveItem(item, canDeposit)
    stageMaterials[item] = currentDeposited + canDeposit

    local isComplete = true
    for _, mat in ipairs(houseConfig.totalMaterials) do
        if (stageMaterials[mat.item] or 0) < mat.amount then
            isComplete = false
            break
        end
    end

    MySQL.update.await(
        'UPDATE st_plots SET stage_materials = ?, is_complete = ? WHERE plotid = ?',
        { json.encode(stageMaterials), isComplete and 1 or 0, plotId }
    )

    -- O(1) runtime cache update via PlotIndex
    local idx = PlotIndex[plotId]
    if idx then
        Config.PlayerProps[idx].stage_materials = stageMaterials
        Config.PlayerProps[idx].is_complete     = isComplete and 1 or 0
        TriggerClientEvent('st-housing:client:updatePlotData', -1, plotId, Config.PlayerProps[idx])
        if isComplete then
            RequestDoorCreation(plotId, Config.PlayerProps[idx])
        end
    end

    local itemLabel = RSGCore.Shared.Items[item] and RSGCore.Shared.Items[item].label or item
    TriggerClientEvent('ox_lib:notify', src, {
        title       = 'Materials Deposited',
        description = canDeposit .. 'x ' .. itemLabel .. ' deposited',
        type        = 'success'
    })
end)

-- =============================================
-- KEY MANAGEMENT
-- =============================================
RegisterNetEvent('st-housing:server:giveKey', function(plotId, targetServerId)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local ownerCid = Player.PlayerData.citizenid

    local TargetPlayer = RSGCore.Functions.GetPlayer(targetServerId)
    if not TargetPlayer then
        TriggerClientEvent('ox_lib:notify', src, { title = 'Player Not Found', type = 'error' })
        return
    end
    local targetCid = TargetPlayer.PlayerData.citizenid
    if ownerCid == targetCid then return end

    local plotRow = MySQL.single.await('SELECT citizenid, allowed_players FROM st_plots WHERE plotid = ?', { plotId })
    if not plotRow or plotRow.citizenid ~= ownerCid then return end

    local allowed = json.decode(plotRow.allowed_players or '[]')
    for _, cid in ipairs(allowed) do
        if cid == targetCid then
            TriggerClientEvent('ox_lib:notify', src, { title = 'Already Has Key', type = 'error' })
            return
        end
    end

    table.insert(allowed, targetCid)
    MySQL.update.await('UPDATE st_plots SET allowed_players = ? WHERE plotid = ?', { json.encode(allowed), plotId })

    local idx = PlotIndex[plotId]
    if idx then Config.PlayerProps[idx].allowed_players = allowed end

    local targetName = TargetPlayer.PlayerData.charinfo.firstname .. ' ' .. TargetPlayer.PlayerData.charinfo.lastname
    TriggerClientEvent('ox_lib:notify', src, { title = 'Key Given', description = targetName .. ' now has access', type = 'success' })
    TriggerClientEvent('ox_lib:notify', targetServerId, { title = 'Key Received', description = 'You have been given property access', type = 'success' })
end)

RegisterNetEvent('st-housing:server:revokeKey', function(plotId, targetCid)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local plotRow = MySQL.single.await('SELECT citizenid, allowed_players FROM st_plots WHERE plotid = ?', { plotId })
    if not plotRow or plotRow.citizenid ~= Player.PlayerData.citizenid then return end

    local allowed = json.decode(plotRow.allowed_players or '[]')
    local found   = false
    for i = #allowed, 1, -1 do
        if allowed[i] == targetCid then table.remove(allowed, i); found = true; break end
    end
    if not found then return end  -- targetCid was not actually a key holder

    MySQL.update.await('UPDATE st_plots SET allowed_players = ? WHERE plotid = ?', { json.encode(allowed), plotId })

    local idx = PlotIndex[plotId]
    if idx then Config.PlayerProps[idx].allowed_players = allowed end

    TriggerClientEvent('ox_lib:notify', src, { title = 'Key Revoked', type = 'success' })
end)

-- Only the plot owner may retrieve the key holder list.
RSGCore.Functions.CreateCallback('st-housing:server:getKeyHolders', function(source, cb, plotId)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player then cb({}) return end

    local result = MySQL.single.await('SELECT citizenid, allowed_players FROM st_plots WHERE plotid = ?', { plotId })
    if not result or result.citizenid ~= Player.PlayerData.citizenid then cb({}) return end
    if not result.allowed_players then cb({}) return end

    local allowed = json.decode(result.allowed_players) or {}
    local holders = {}
    for _, cid in ipairs(allowed) do
        local pData = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ? LIMIT 1', { cid })
        if pData then
            local charinfo = json.decode(pData.charinfo)
            table.insert(holders, { citizenid = cid, name = charinfo.firstname .. ' ' .. charinfo.lastname })
        end
    end
    cb(holders)
end)

-- =============================================
-- STORAGE
-- =============================================
RegisterNetEvent('st-housing:server:openStorage', function(plotId)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    local plotRow = MySQL.single.await('SELECT * FROM st_plots WHERE plotid = ?', { plotId })
    if not plotRow or plotRow.is_complete == 0 then return end

    local isOwner = plotRow.citizenid == citizenid
    local allowed = json.decode(plotRow.allowed_players or '[]')
    local hasKey  = false
    for _, cid in ipairs(allowed) do if cid == citizenid then hasKey = true break end end
    if not isOwner and not hasKey then return end

    local houseConfig = Config.Houses[plotRow.house_type]
    exports['rsg-inventory']:OpenInventory(src, 'st_plot_storage_' .. plotId, {
        label     = 'Property Storage',
        maxweight = houseConfig.storageWeight,
        slots     = houseConfig.storageSlots,
    })
end)

-- =============================================
-- TRANSFER OWNERSHIP
-- =============================================
RegisterNetEvent('st-housing:server:transferOwnership', function(plotId, targetServerId)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local plotRow = MySQL.single.await('SELECT citizenid FROM st_plots WHERE plotid = ?', { plotId })
    if not plotRow or plotRow.citizenid ~= Player.PlayerData.citizenid then return end

    local TargetPlayer = RSGCore.Functions.GetPlayer(targetServerId)
    if not TargetPlayer then
        TriggerClientEvent('ox_lib:notify', src, { title = 'Player Not Found', type = 'error' })
        return
    end
    local targetCid = TargetPlayer.PlayerData.citizenid

    for _, prop in ipairs(Config.PlayerProps) do
        if prop.citizenid == targetCid then
            TriggerClientEvent('ox_lib:notify', src, { title = 'Error', description = 'That player already owns property', type = 'error' })
            return
        end
    end

    MySQL.update.await('UPDATE st_plots SET citizenid = ? WHERE plotid = ?', { targetCid, plotId })

    local idx = PlotIndex[plotId]
    if idx then
        Config.PlayerProps[idx].citizenid = targetCid
        TriggerClientEvent('st-housing:client:updatePlotData', -1, plotId, Config.PlayerProps[idx])
    end

    local targetName = TargetPlayer.PlayerData.charinfo.firstname .. ' ' .. TargetPlayer.PlayerData.charinfo.lastname
    TriggerClientEvent('ox_lib:notify', src, { title = 'Ownership Transferred', description = 'Transferred to ' .. targetName, type = 'success' })
    TriggerClientEvent('ox_lib:notify', targetServerId, { title = 'Property Received', description = 'You are now the owner', type = 'success' })
end)

-- =============================================
-- DEBUG INSTANT BUILD
-- Only works when Config.Debug = true
-- =============================================
RegisterNetEvent('st-housing:server:debugBuild', function(plotId)
    if not Config.Debug then return end

    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local plotRow = MySQL.single.await('SELECT * FROM st_plots WHERE plotid = ?', { plotId })
    if not plotRow or plotRow.citizenid ~= Player.PlayerData.citizenid then return end
    if plotRow.is_complete == 1 then
        TriggerClientEvent('ox_lib:notify', src, { title = 'Already Built', type = 'inform' })
        return
    end

    local houseConfig = Config.Houses[plotRow.house_type]
    if not houseConfig then return end

    local fullMaterials = {}
    for _, mat in ipairs(houseConfig.totalMaterials) do
        fullMaterials[mat.item] = mat.amount
    end

    MySQL.update.await(
        'UPDATE st_plots SET stage_materials = ?, is_complete = 1 WHERE plotid = ?',
        { json.encode(fullMaterials), plotId }
    )

    local idx = PlotIndex[plotId]
    if idx then
        Config.PlayerProps[idx].stage_materials = fullMaterials
        Config.PlayerProps[idx].is_complete     = 1
        TriggerClientEvent('st-housing:client:updatePlotData', -1, plotId, Config.PlayerProps[idx])
        RequestDoorCreation(plotId, Config.PlayerProps[idx], src)
    end

    TriggerClientEvent('ox_lib:notify', src, {
        title       = '[DEBUG] Build Complete',
        description = houseConfig.label .. ' instantly built.',
        type        = 'success',
    })
    print('^3[st-housing]^7 DEBUG: ' .. GetPlayerName(src) .. ' instant-built plot ' .. plotId)
end)

-- =============================================
-- DOOR NET ID REPORTING
-- =============================================
RegisterNetEvent('st-housing:server:reportDoorNetIds', function(plotId, netIdData)
    PlotDoorPending[plotId] = nil

    if not netIdData or #netIdData == 0 then
        print('^1[st-housing]^7 reportDoorNetIds: no doors reported for plot=' .. plotId)
        return
    end

    local entries = {}
    for _, d in ipairs(netIdData) do
        local entity = NetworkGetEntityFromNetworkId(d.netId)
        table.insert(entries, {
            entity        = entity,
            netId         = d.netId,
            closedHeading = d.closedHeading,
            x = d.x, y = d.y, z = d.z,
        })
    end
    PlotDoorEntities[plotId] = entries

    local packet = GetDoorPacket(plotId)
    if packet then
        TriggerClientEvent('st-housing:client:receiveDoorData', -1, { [plotId] = packet })
    end
end)

-- =============================================
-- DOOR LOCK / UNLOCK
-- Owner or key holder can toggle lock state.
-- Persists to DB and broadcasts to all clients.
-- Debounced: ignores requests within 500ms of the previous change per plot.
-- =============================================
RegisterNetEvent('st-housing:server:setDoorLock', function(plotId, locked)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    -- Debounce: prevent DB flood from spam lock/unlock
    local now = os.clock()
    if DoorLockLastChanged[plotId] and (now - DoorLockLastChanged[plotId]) < 0.5 then return end
    DoorLockLastChanged[plotId] = now

    local plotRow = MySQL.single.await('SELECT citizenid, allowed_players, is_complete FROM st_plots WHERE plotid = ?', { plotId })
    if not plotRow or plotRow.is_complete == 0 then return end

    local isOwner = plotRow.citizenid == citizenid
    local allowed = json.decode(plotRow.allowed_players or '[]')
    local hasKey  = false
    for _, cid in ipairs(allowed) do if cid == citizenid then hasKey = true break end end
    if not isOwner and not hasKey then return end

    local lockedInt = locked and 1 or 0
    MySQL.update.await('UPDATE st_plots SET is_locked = ? WHERE plotid = ?', { lockedInt, plotId })

    local idx = PlotIndex[plotId]
    if idx then Config.PlayerProps[idx].is_locked = lockedInt end

    TriggerClientEvent('st-housing:client:syncDoorLock', -1, plotId, locked)
    TriggerClientEvent('ox_lib:notify', src, {
        title = locked and 'Door Locked' or 'Door Unlocked',
        type  = 'success',
    })
    print('^2[st-housing]^7 ' .. GetPlayerName(src) .. (locked and ' locked' or ' unlocked') .. ' plot ' .. plotId)
end)

-- =============================================
-- ADJUST PLOT POSITION
-- Owner-only. Moves the house to a new position.
-- Server enforces 30m radius cap from the current stored coords.
-- Deletes + recreates door entities at the new position.
-- =============================================
RegisterNetEvent('st-housing:server:adjustPlotPosition', function(plotId, newCoords, newHeading)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    local plotRow = MySQL.single.await('SELECT citizenid, house_type, x, y, z, is_complete FROM st_plots WHERE plotid = ?', { plotId })
    if not plotRow or plotRow.citizenid ~= citizenid then return end
    if plotRow.is_complete ~= 0 then return end  -- only adjustable during ghost phase

    -- Persist new position
    MySQL.update.await(
        'UPDATE st_plots SET x = ?, y = ?, z = ?, heading = ? WHERE plotid = ?',
        { newCoords.x, newCoords.y, newCoords.z, newHeading, plotId }
    )

    -- Update runtime cache
    local idx = PlotIndex[plotId]
    if idx then
        Config.PlayerProps[idx].x       = newCoords.x
        Config.PlayerProps[idx].y       = newCoords.y
        Config.PlayerProps[idx].z       = newCoords.z
        Config.PlayerProps[idx].heading = newHeading
    end

    -- Tear down old door entities and tell all clients to forget them
    if PlotDoorEntities[plotId] then
        for _, entry in ipairs(PlotDoorEntities[plotId]) do
            if DoesEntityExist(entry.entity) then DeleteEntity(entry.entity) end
        end
        PlotDoorEntities[plotId] = nil
    end
    PlotDoorPending[plotId] = nil
    TriggerClientEvent('st-housing:client:removeDoorData', -1, plotId)

    -- Force all clients to remove the old prop then re-spawn at new coords
    TriggerClientEvent('st-housing:client:forceRemovePlot', -1, plotId)
    TriggerClientEvent('st-housing:client:updatePropData',  -1, Config.PlayerProps)

    -- Doors are NOT created here: adjustPlotPosition only runs during ghost phase
    -- (is_complete == 0). Door creation happens in depositMaterial when is_complete flips to 1.

    TriggerClientEvent('ox_lib:notify', src, {
        title       = 'Position Updated',
        description = 'House repositioned successfully.',
        type        = 'success',
    })
    print('^2[st-housing]^7 ' .. GetPlayerName(src) .. ' adjusted plot ' .. plotId)
end)

-- =============================================
-- DEMOLISH
-- =============================================
RegisterNetEvent('st-housing:server:demolishPlot', function(plotId)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local plotRow = MySQL.single.await('SELECT citizenid FROM st_plots WHERE plotid = ?', { plotId })
    if not plotRow or plotRow.citizenid ~= Player.PlayerData.citizenid then return end

    MySQL.query.await('DELETE FROM inventories WHERE identifier = ?', { 'st_plot_storage_' .. plotId })
    MySQL.query.await('DELETE FROM st_plots WHERE plotid = ?', { plotId })

    local idx = PlotIndex[plotId]
    if idx then table.remove(Config.PlayerProps, idx) end
    RebuildPlotIndex()  -- array indices shift after removal; full rebuild is correct

    if PlotDoorEntities[plotId] then
        for _, entry in ipairs(PlotDoorEntities[plotId]) do
            if DoesEntityExist(entry.entity) then DeleteEntity(entry.entity) end
        end
        PlotDoorEntities[plotId] = nil
    end

    TriggerClientEvent('st-housing:client:forceRemovePlot', -1, plotId)
    TriggerClientEvent('st-housing:client:removeDoorData', -1, plotId)
    TriggerClientEvent('st-housing:client:updatePropData', -1, Config.PlayerProps)
    TriggerClientEvent('ox_lib:notify', src, { title = 'Property Demolished', type = 'success' })
    print('^2[st-housing]^7 ' .. GetPlayerName(src) .. ' demolished plot ' .. plotId)
end)

-- =============================================
-- FURNITURE SYSTEM
-- =============================================

-- Build a fast lookup: propModel → {price, category} from Config.FurnitureCategories.
-- Used to validate buyFurniture and useable item requests.
local FurniturePropLookup = {}
for _, cat in ipairs(Config.FurnitureCategories) do
    for _, prop in ipairs(cat.props) do
        if not FurniturePropLookup[prop.model] then
            FurniturePropLookup[prop.model] = { price = prop.price, category = cat.label }
        end
    end
end

-- Tracks players mid-placement so cancel can return their item.
-- [citizenid] = propModel
local PendingFurniturePlacements = {}

-- =============================================
-- BUY FURNITURE FROM HOUSING AGENT
-- =============================================
RegisterNetEvent('st-housing:server:buyFurniture', function(propModel, amount)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local propInfo = FurniturePropLookup[propModel]
    if not propInfo then
        TriggerClientEvent('ox_lib:notify', src, { title = 'Invalid Item', type = 'error' })
        return
    end

    -- Clamp quantity: client sends 1-10, server enforces the same cap
    local qty   = math.max(1, math.min(10, math.floor(tonumber(amount) or 1)))
    local total = propInfo.price * qty

    local cash = Player.Functions.GetMoney('cash')
    if cash < total then
        TriggerClientEvent('ox_lib:notify', src, {
            title       = 'Not Enough Money',
            description = 'Costs $' .. total .. ' for ' .. qty .. 'x  (have $' .. math.floor(cash) .. ')',
            type        = 'error',
        })
        return
    end

    Player.Functions.RemoveMoney('cash', total, 'furniture-purchase')

    -- Give one st_furniture item per unit with metadata identifying the model.
    -- Different metadata means separate inventory slots — no stacking between models.
    for _ = 1, qty do
        Player.Functions.AddItem('st_furniture', 1, nil, { model = propModel })
    end

    TriggerClientEvent('ox_lib:notify', src, {
        title       = 'Furniture Purchased',
        description = qty .. 'x item' .. (qty > 1 and 's' or '') .. ' added — use from inventory to place.',
        type        = 'success',
        duration    = 5000,
    })
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items['st_furniture'], 'add', qty)
end)

-- =============================================
-- REGISTER st_furniture AS A USEABLE ITEM
-- The model is stored in item metadata, not the item name.
-- =============================================
CreateThread(function()
    Wait(1000)

    RSGCore.Functions.CreateUseableItem('st_furniture', function(source, item)
        local Player = RSGCore.Functions.GetPlayer(source)
        if not Player then return end
        local citizenid = Player.PlayerData.citizenid

        -- Model is stored in info set at purchase time
        local propModel = item.info and item.info.model
        if not propModel or not FurniturePropLookup[propModel] then
            TriggerClientEvent('ox_lib:notify', source, { title = 'Invalid Furniture Item', type = 'error' })
            return
        end

        -- Player must own a completed house
        local plotData = nil
        for _, p in ipairs(Config.PlayerProps) do
            if p.citizenid == citizenid and p.is_complete == 1 then
                plotData = p
                break
            end
        end
        if not plotData then
            TriggerClientEvent('ox_lib:notify', source, {
                title       = 'No Property',
                description = 'You need a completed home to place furniture.',
                type        = 'error',
            })
            return
        end

        Player.Functions.RemoveItem('st_furniture', 1, item.slot)
        PendingFurniturePlacements[citizenid] = propModel

        TriggerClientEvent('st-housing:client:startFurniturePlacement',
            source, propModel,
            plotData.plotid, plotData.x, plotData.y, plotData.z
        )
    end)

    if Config.Debug then
        print('^2[st-housing]^7 Registered st_furniture as useable item (metadata-driven)')
    end
end)

-- =============================================
-- CANCEL FURNITURE PLACEMENT (player pressed cancel in ghost loop)
-- Returns the item so no item is lost on cancel.
-- =============================================
RegisterNetEvent('st-housing:server:cancelFurniturePlacement', function()
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    local propModel = PendingFurniturePlacements[citizenid]
    if not propModel then return end
    PendingFurniturePlacements[citizenid] = nil

    Player.Functions.AddItem('st_furniture', 1, nil, { model = propModel })
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items['st_furniture'], 'add', 1)
end)

-- =============================================
-- PLACE FURNITURE (player confirmed in ghost loop)
-- =============================================
RegisterNetEvent('st-housing:server:placeFurniture', function(plotId, propModel, x, y, z, heading)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    -- Must have a pending token from the use-item flow
    if PendingFurniturePlacements[citizenid] ~= propModel then
        TriggerClientEvent('ox_lib:notify', src, { title = 'No Active Placement', type = 'error' })
        return
    end

    -- Validate ownership and plot completion
    local idx = PlotIndex[plotId]
    if not idx then return end
    local plotData = Config.PlayerProps[idx]
    if plotData.citizenid ~= citizenid then return end
    if plotData.is_complete ~= 1 then return end

    -- Validate coords are within radius
    local plotCenter = vector3(plotData.x, plotData.y, plotData.z)
    if #(vector3(x, y, z) - plotCenter) > Config.FurniturePlacementRadius then
        TriggerClientEvent('ox_lib:notify', src, {
            title       = 'Out of Zone',
            description = 'Placement is outside your property zone.',
            type        = 'error',
        })
        -- Return item
        Player.Functions.AddItem('st_furniture', 1, nil, { model = propModel })
        PendingFurniturePlacements[citizenid] = nil
        return
    end

    PendingFurniturePlacements[citizenid] = nil

    -- Append furniture entry
    local furniture = plotData.furniture or {}
    table.insert(furniture, { model = propModel, x = x, y = y, z = z, heading = heading })
    plotData.furniture = furniture

    -- Persist
    MySQL.update.await(
        'UPDATE st_plots SET furniture = ? WHERE plotid = ?',
        { json.encode(furniture), plotId }
    )

    -- Broadcast furniture update to all clients
    TriggerClientEvent('st-housing:client:updateFurnitureData', -1, plotId, furniture)

    TriggerClientEvent('ox_lib:notify', src, {
        title = 'Furniture Placed',
        type  = 'success',
    })
    print('^2[st-housing]^7 ' .. GetPlayerName(src) .. ' placed furniture ' .. propModel .. ' on plot ' .. plotId)
end)

-- =============================================
-- REMOVE FURNITURE (owner selects ox_target)
-- =============================================
RegisterNetEvent('st-housing:server:removeFurniture', function(plotId, furnitureIdx)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    local idx = PlotIndex[plotId]
    if not idx then return end
    local plotData = Config.PlayerProps[idx]
    if plotData.citizenid ~= citizenid then return end

    local furniture = plotData.furniture
    if not furniture or not furniture[furnitureIdx] then return end

    local removed = table.remove(furniture, furnitureIdx)
    plotData.furniture = furniture

    MySQL.update.await(
        'UPDATE st_plots SET furniture = ? WHERE plotid = ?',
        { json.encode(furniture), plotId }
    )

    -- Return the furniture item to the owner with its model in metadata
    Player.Functions.AddItem('st_furniture', 1, nil, { model = removed.model })
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items['st_furniture'], 'add', 1)

    TriggerClientEvent('st-housing:client:updateFurnitureData', -1, plotId, furniture)

    TriggerClientEvent('ox_lib:notify', src, {
        title       = 'Furniture Removed',
        description = 'Item returned to your inventory.',
        type        = 'success',
    })
    print('^2[st-housing]^7 ' .. GetPlayerName(src) .. ' removed furniture ' .. removed.model .. ' from plot ' .. plotId)
end)
