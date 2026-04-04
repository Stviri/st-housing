local RSGCore = exports['rsg-core']:GetCoreObject()

lib.cron.new(Config.TaxCronJob, function()
    print('^2[st-housing]^7 Running tax check...')
    -- Select only needed columns; avoid SELECT * on potentially large table
    local result = MySQL.query.await(
        'SELECT plotid, citizenid, house_type, is_abandoned, UNIX_TIMESTAMP(last_tax_paid) as last_tax_paid FROM st_plots WHERE citizenid IS NOT NULL'
    )
    if not result or #result == 0 then return end

    local now         = os.time()
    local graceSecs   = Config.TaxGraceDays * 86400
    local abandonSecs = (Config.TaxGraceDays + Config.AbandonDays) * 86400

    -- Build online citizenid → serverId map once (O(players)) instead of
    -- rescanning all players for every plot (previous O(plots × players) pattern).
    local onlineByChar = {}
    for _, playerId in ipairs(GetPlayers()) do
        local P = RSGCore.Functions.GetPlayer(tonumber(playerId))
        if P then onlineByChar[P.PlayerData.citizenid] = tonumber(playerId) end
    end

    for _, row in ipairs(result) do
        local overdueSecs = now - row.last_tax_paid

        if overdueSecs > abandonSecs then
            -- REPOSSESS
            MySQL.query.await('DELETE FROM inventories WHERE identifier = ?', { 'st_plot_storage_' .. row.plotid })
            MySQL.update.await(
                'UPDATE st_plots SET citizenid = NULL, allowed_players = ?, is_abandoned = 1 WHERE plotid = ?',
                { '[]', row.plotid }
            )

            local idx = PlotIndex[row.plotid]
            if idx then
                Config.PlayerProps[idx].citizenid       = nil
                Config.PlayerProps[idx].allowed_players = {}
                Config.PlayerProps[idx].is_abandoned    = 1
                TriggerClientEvent('st-housing:client:updatePlotData', -1, row.plotid, Config.PlayerProps[idx])
            end

            local pid = onlineByChar[row.citizenid]
            if pid then
                TriggerClientEvent('ox_lib:notify', pid, {
                    title       = 'Property Repossessed',
                    description = 'Your property was repossessed due to unpaid taxes.',
                    type        = 'error',
                    duration    = 10000
                })
            end
            print('^1[st-housing]^7 Repossessed plot ' .. row.plotid)

        elseif overdueSecs > graceSecs and row.is_abandoned == 0 then
            -- WARN — mark abandoned
            MySQL.update.await('UPDATE st_plots SET is_abandoned = 1 WHERE plotid = ?', { row.plotid })

            local idx = PlotIndex[row.plotid]
            if idx then
                Config.PlayerProps[idx].is_abandoned = 1
                TriggerClientEvent('st-housing:client:updatePlotData', -1, row.plotid, Config.PlayerProps[idx])
            end

            local pid = onlineByChar[row.citizenid]
            if pid then
                TriggerClientEvent('ox_lib:notify', pid, {
                    title       = 'Tax Overdue Warning',
                    description = 'Pay your property tax or it will be repossessed!',
                    type        = 'error',
                    duration    = 10000
                })
            end
        end
    end
end)

RegisterNetEvent('st-housing:server:payTax', function(plotId)
    local src    = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local plotRow = MySQL.single.await(
        'SELECT citizenid, house_type, is_abandoned, UNIX_TIMESTAMP(last_tax_paid) as last_tax_paid FROM st_plots WHERE plotid = ?',
        { plotId }
    )
    if not plotRow or plotRow.citizenid ~= Player.PlayerData.citizenid then return end

    local houseConfig = Config.Houses[plotRow.house_type]
    if not houseConfig then return end

    -- Prevent paying again if tax was already paid within the last 24 hours
    if os.time() - (plotRow.last_tax_paid or 0) < 86400 then
        TriggerClientEvent('ox_lib:notify', src, {
            title       = 'Tax Already Paid',
            description = 'Your property tax has already been paid today.',
            type        = 'inform'
        })
        return
    end

    local taxAmount  = houseConfig.taxPerDay
    local playerCash = Player.Functions.GetMoney('cash')

    if playerCash < taxAmount then
        TriggerClientEvent('ox_lib:notify', src, {
            title       = 'Not Enough Money',
            description = 'Tax costs $' .. taxAmount,
            type        = 'error'
        })
        return
    end

    Player.Functions.RemoveMoney('cash', taxAmount, 'property-tax')
    MySQL.update.await('UPDATE st_plots SET last_tax_paid = NOW(), is_abandoned = 0 WHERE plotid = ?', { plotId })

    local idx = PlotIndex[plotId]
    if idx then
        Config.PlayerProps[idx].is_abandoned = 0
        TriggerClientEvent('st-housing:client:updatePlotData', -1, plotId, Config.PlayerProps[idx])
    end

    TriggerClientEvent('ox_lib:notify', src, {
        title       = 'Tax Paid',
        description = '$' .. taxAmount .. ' property tax paid.',
        type        = 'success'
    })
end)
