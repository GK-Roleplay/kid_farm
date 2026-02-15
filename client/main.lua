local tabletOpen = false
local actionBusy = false
local cancelActionRequested = false
local activeActionId = 0
local playerState = nil
local objectiveBlip = nil
local currentInsideZone = nil
local lastHintTick = 0

local function pushLocalToast(toastType, text)
    SendNUIMessage({
        action = 'toast',
        toast = {
            type = toastType,
            text = text
        }
    })
end

local function pushFeedText(text)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandThefeedPostTicker(false, false)
end

local function drawHelpText(message)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

local function drawText3D(coords, text)
    local onScreen, screenX, screenY = GetScreenCoordFromWorldCoord(coords.x, coords.y, coords.z)
    if not onScreen then
        return
    end

    SetTextScale(0.32, 0.32)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(255, 255, 255, 215)
    SetTextCentre(true)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(screenX, screenY)
end

local function drawCornerObjective(text)
    SetTextFont(4)
    SetTextScale(0.37, 0.37)
    SetTextColour(235, 245, 255, 225)
    SetTextDropShadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 205)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(('Objective: %s'):format(text))
    EndTextCommandDisplayText(0.015, 0.82)
end

local function showSubtitle(text)
    BeginTextCommandPrint('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandPrint(2800, true)
end

local function chatHint(text)
    TriggerEvent('chat:addMessage', {
        color = { 124, 206, 114 },
        args = { 'kid_farm', text }
    })
end

local function openTablet(tab)
    if not Config.UI.TabletEnabled then
        pushFeedText('Farming tablet is disabled. Use classic mode controls.')
        return
    end

    tabletOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        tab = tab or 'collect',
        title = Config.Ui.tabletTitle
    })

    if playerState then
        SendNUIMessage({ action = 'sync', state = playerState })
    end
end

local function closeTablet()
    tabletOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
    SendNUIMessage({ action = 'progress', show = false })
end

local function zoneToTab(zoneKey)
    if zoneKey == 'field' then
        return 'collect'
    end
    if zoneKey == 'mill' then
        return 'process'
    end
    if zoneKey == 'market' then
        return 'sell'
    end
    return 'collect'
end

local function getDistanceToZone(zoneKey)
    local zone = Config.Zones[zoneKey]
    if not zone then
        return math.huge
    end

    local pos = GetEntityCoords(PlayerPedId())
    local dx = pos.x - zone.coords.x
    local dy = pos.y - zone.coords.y
    local dz = pos.z - zone.coords.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function isNearZone(zoneKey)
    local zone = Config.Zones[zoneKey]
    if not zone then
        return false
    end

    return getDistanceToZone(zoneKey) <= zone.radius
end

local function clearActionVisualsAndTasks()
    local ped = PlayerPedId()
    ClearPedTasksImmediately(ped)
    ClearPedTasks(ped)
    SendNUIMessage({ action = 'progress', show = false })
end

local function stopCurrentAction(showFeedback, customMessage)
    local wasBusy = actionBusy

    activeActionId = activeActionId + 1
    cancelActionRequested = true
    actionBusy = false

    clearActionVisualsAndTasks()

    if tabletOpen then
        SetNuiFocus(true, true)
    else
        SetNuiFocus(false, false)
    end

    if showFeedback then
        if wasBusy then
            pushLocalToast('success', customMessage or 'Current action stopped.')
        else
            pushLocalToast('warn', customMessage or 'No action is running right now.')
        end
    elseif customMessage and customMessage ~= '' then
        pushLocalToast('info', customMessage)
    end
end

local function runProgressAction(durationMs, scenarioName, progressLabel, finished)
    if actionBusy then
        pushLocalToast('warn', 'Please finish your current action first.')
        return
    end

    actionBusy = true
    cancelActionRequested = false
    activeActionId = activeActionId + 1
    local actionId = activeActionId
    SetNuiFocus(false, false)

    local ped = PlayerPedId()
    if scenarioName and scenarioName ~= '' then
        TaskStartScenarioInPlace(ped, scenarioName, 0, true)
    end

    local start = GetGameTimer()
    local cancelled = false
    while true do
        if actionId ~= activeActionId or cancelActionRequested or not actionBusy then
            cancelled = true
            break
        end

        local elapsed = GetGameTimer() - start
        local pct = math.floor((elapsed / durationMs) * 100)
        if pct > 100 then
            pct = 100
        end

        SendNUIMessage({
            action = 'progress',
            show = true,
            label = progressLabel,
            percent = pct
        })

        if elapsed >= durationMs then
            break
        end

        Wait(120)
    end

    if actionId ~= activeActionId then
        return
    end

    clearActionVisualsAndTasks()
    actionBusy = false
    cancelActionRequested = false

    if tabletOpen then
        SetNuiFocus(true, true)
    end

    if not cancelled and finished then
        finished()
    end
end

local function clearObjectiveBlip()
    if objectiveBlip and DoesBlipExist(objectiveBlip) then
        RemoveBlip(objectiveBlip)
    end

    objectiveBlip = nil
end

local function refreshObjectiveBlip()
    if not Config.ObjectiveBlip.enabled or not playerState then
        clearObjectiveBlip()
        return
    end

    local objective = playerState.objective
    local zoneKey = playerState.routeTarget or (objective and objective.zone)
    local zone = zoneKey and Config.Zones[zoneKey]

    if not zone or not playerState.farmEnabled then
        clearObjectiveBlip()
        return
    end

    if not objectiveBlip or not DoesBlipExist(objectiveBlip) then
        objectiveBlip = AddBlipForCoord(zone.coords.x, zone.coords.y, zone.coords.z)
        SetBlipSprite(objectiveBlip, Config.ObjectiveBlip.sprite)
        SetBlipColour(objectiveBlip, Config.ObjectiveBlip.colour)
        SetBlipScale(objectiveBlip, Config.ObjectiveBlip.scale)
        SetBlipDisplay(objectiveBlip, 4)
        SetBlipAsShortRange(objectiveBlip, false)
    else
        SetBlipCoords(objectiveBlip, zone.coords.x, zone.coords.y, zone.coords.z)
    end

    local routeOn = Config.ObjectiveBlip.routeEnabled and (playerState.preferences and playerState.preferences.waypoint)
    SetBlipRoute(objectiveBlip, routeOn and true or false)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName((Config.ObjectiveBlip.labelPrefix or 'Farming: ') .. zone.label)
    EndTextCommandSetBlipName(objectiveBlip)
end

local function expectedZoneFromStage()
    if not playerState or not playerState.stage then
        return nil
    end

    local stage = playerState.stage
    if stage == 'go_field' or stage == 'collect' then
        return 'field'
    end
    if stage == 'go_barn' or stage == 'process' then
        return 'mill'
    end
    if stage == 'go_market' or stage == 'sell' then
        return 'market'
    end

    return nil
end

local function promptForZone(zoneKey)
    if not playerState or not playerState.farmEnabled then
        if zoneKey == 'field' and Config.ClassicMode.startMarkerAtField then
            return ('Press ~INPUT_CONTEXT~ to start farming.')
        end

        return 'Use /farm to start farming.'
    end

    if playerState.stage == 'daily_complete' then
        return Config.DailyLimit.friendlyMessage
    end

    local expectedZone = expectedZoneFromStage()
    if not expectedZone then
        return 'Use /farmhelp for farming instructions.'
    end

    if zoneKey ~= expectedZone then
        local expectedLabel = Config.Zones[expectedZone] and Config.Zones[expectedZone].label or expectedZone
        return ('You need to go to %s next. Check your map marker!'):format(expectedLabel)
    end

    if zoneKey == 'field' then
        return ('Press ~INPUT_CONTEXT~ to Harvest')
    end

    if zoneKey == 'mill' then
        return ('Press ~INPUT_CONTEXT~ to Process')
    end

    if zoneKey == 'market' then
        return ('Press ~INPUT_CONTEXT~ to Sell')
    end

    return 'Press ~INPUT_CONTEXT~ to continue farming.'
end

local function runClassicInteract(zoneKey)
    if not Config.ClassicMode.enabled then
        return
    end

    if not playerState or not playerState.farmEnabled then
        TriggerServerEvent('kid_farm:classicInteract', { zone = zoneKey })
        return
    end

    local stage = playerState.stage

    if stage == 'go_field' or stage == 'collect' then
        if zoneKey ~= 'field' then
            TriggerServerEvent('kid_farm:classicInteract', { zone = zoneKey })
            return
        end

        CreateThread(function()
            runProgressAction(
                Config.Actions.collectDurationMs,
                Config.Actions.collectScenario,
                'Harvesting crops...',
                function()
                    TriggerServerEvent('kid_farm:classicInteract', {
                        zone = 'field',
                        crop = Config.ClassicMode.defaultCrop
                    })
                end
            )
        end)

        return
    end

    if stage == 'go_barn' or stage == 'process' then
        if zoneKey ~= 'mill' then
            TriggerServerEvent('kid_farm:classicInteract', { zone = zoneKey })
            return
        end

        CreateThread(function()
            runProgressAction(
                Config.Actions.processDurationMs,
                Config.Actions.processScenario,
                'Processing your harvest...',
                function()
                    TriggerServerEvent('kid_farm:classicInteract', {
                        zone = 'mill',
                        recipe = Config.ClassicMode.defaultProcessRecipe
                    })
                end
            )
        end)

        return
    end

    if stage == 'go_market' or stage == 'sell' then
        if zoneKey ~= 'market' then
            TriggerServerEvent('kid_farm:classicInteract', { zone = zoneKey })
            return
        end

        CreateThread(function()
            runProgressAction(
                Config.Actions.sellDurationMs,
                Config.Actions.sellScenario,
                'Preparing your sale...',
                function()
                    TriggerServerEvent('kid_farm:classicInteract', {
                        zone = 'market',
                        items = Config.ClassicMode.autoSellAllOnInteract and {} or nil
                    })
                end
            )
        end)

        return
    end

    TriggerServerEvent('kid_farm:classicInteract', { zone = zoneKey })
end

RegisterNetEvent('kid_farm:syncState', function(newState)
    playerState = newState
    SendNUIMessage({ action = 'sync', state = playerState })
    refreshObjectiveBlip()
end)

RegisterNetEvent('kid_farm:status', function(newState)
    playerState = newState
    SendNUIMessage({ action = 'sync', state = playerState })
    refreshObjectiveBlip()
end)

RegisterNetEvent('kid_farm:toast', function(payload)
    SendNUIMessage({ action = 'toast', toast = payload })
    if payload and payload.text then
        pushFeedText(payload.text)
    end
end)

RegisterNetEvent('kid_farm:saleReceipt', function(receipt)
    SendNUIMessage({ action = 'receipt', receipt = receipt })
end)

RegisterNetEvent('kid_farm:levelUp', function(data)
    SendNUIMessage({ action = 'levelUp', data = data })
    if data and data.level then
        pushFeedText(('Level up! You are now level %d.'):format(data.level))
    end
end)

RegisterNetEvent('kid_farm:stopAnim', function(payload)
    local message = nil
    if type(payload) == 'table' then
        message = payload.message
    elseif type(payload) == 'string' then
        message = payload
    end

    stopCurrentAction(false, message)
end)

RegisterNUICallback('close', function(_, cb)
    closeTablet()
    cb({ ok = true })
end)

RegisterNUICallback('requestSync', function(_, cb)
    TriggerServerEvent('kid_farm:requestSync')
    cb({ ok = true })
end)

RegisterNUICallback('setWaypoint', function(data, cb)
    local enabled = data and data.enabled and true or false
    TriggerServerEvent('kid_farm:setWaypoint', enabled)
    cb({ ok = true })
end)

RegisterNUICallback('collect', function(data, cb)
    local cropKey = tostring(data and data.crop or 'wheat')
    local cropLabel = (Config.Crops[cropKey] and Config.Crops[cropKey].label) or cropKey

    cb({ ok = true })

    if not isNearZone('field') then
        pushLocalToast('warn', 'Move to the Field to collect crops.')
        return
    end

    CreateThread(function()
        runProgressAction(
            Config.Actions.collectDurationMs,
            Config.Actions.collectScenario,
            ('Collecting %s...'):format(cropLabel),
            function()
                TriggerServerEvent('kid_farm:collect', { crop = cropKey })
            end
        )
    end)
end)

RegisterNUICallback('process', function(data, cb)
    local recipeKey = tostring(data and data.recipe or '')
    local recipeLabel = (Config.Recipes[recipeKey] and Config.Recipes[recipeKey].label) or 'Recipe'

    cb({ ok = true })

    if not isNearZone('mill') then
        pushLocalToast('warn', 'Move to the Barn to process items.')
        return
    end

    CreateThread(function()
        runProgressAction(
            Config.Actions.processDurationMs,
            Config.Actions.processScenario,
            ('Processing %s...'):format(recipeLabel),
            function()
                TriggerServerEvent('kid_farm:process', { recipe = recipeKey })
            end
        )
    end)
end)

RegisterNUICallback('sell', function(data, cb)
    cb({ ok = true })

    if not isNearZone('market') then
        pushLocalToast('warn', 'Move to the Market to sell items.')
        return
    end

    local selectedItems = type(data and data.items) == 'table' and data.items or {}

    CreateThread(function()
        runProgressAction(
            Config.Actions.sellDurationMs,
            Config.Actions.sellScenario,
            'Preparing your sale...',
            function()
                TriggerServerEvent('kid_farm:sell', { items = selectedItems })
            end
        )
    end)
end)

RegisterCommand(Config.Ui.command, function()
    if not Config.UI.TabletEnabled then
        pushFeedText('Tablet mode is disabled. Use /farm and classic controls.')
        return
    end

    if tabletOpen then
        closeTablet()
    else
        openTablet('collect')
        TriggerServerEvent('kid_farm:requestSync')
    end
end, false)

RegisterKeyMapping(Config.Ui.command, 'Open Farming Tablet', 'keyboard', Config.Ui.keybind)

local function teleportToZone(zoneKey)
    local zone = Config.Zones[zoneKey]
    if not zone then
        pushFeedText('Unknown farm zone.')
        return
    end

    local ped = PlayerPedId()
    local targetZ = zone.coords.z + 1.0
    SetEntityCoordsNoOffset(ped, zone.coords.x, zone.coords.y, targetZ, false, false, false)
    SetEntityHeading(ped, 0.0)
    pushFeedText(('Teleported to %s.'):format(zone.label))
end

RegisterCommand('farmtp', function(_, args)
    local destination = tostring(args and args[1] or ''):lower()
    if destination == '' then
        pushFeedText('Usage: /farmtp field | mill | market')
        return
    end

    if destination == 'barn' then
        destination = 'mill'
    end

    teleportToZone(destination)
end, false)

RegisterCommand('farmfield', function()
    teleportToZone('field')
end, false)

RegisterCommand('farmmill', function()
    teleportToZone('mill')
end, false)

RegisterCommand('farmmarket', function()
    teleportToZone('market')
end, false)

RegisterCommand('stopanim', function()
    stopCurrentAction(true)
end, false)

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local nearestKey = nil
        local nearestDistance = math.huge
        local drawZones = {}

        for zoneKey, zone in pairs(Config.Zones) do
            local dx = pos.x - zone.coords.x
            local dy = pos.y - zone.coords.y
            local dz = pos.z - zone.coords.z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

            if distance < nearestDistance then
                nearestDistance = distance
                nearestKey = zoneKey
            end

            if distance <= (Config.Interaction.drawDistance or 35.0) then
                drawZones[#drawZones + 1] = {
                    key = zoneKey,
                    zone = zone,
                    distance = distance
                }
            end
        end

        local sleep = 1200
        if nearestDistance <= 100.0 then
            sleep = 350
        end
        if nearestDistance <= 30.0 then
            sleep = 0
        end

        if sleep == 0 then
            if Config.Guidance.showMarkers then
                for _, row in ipairs(drawZones) do
                    local zone = row.zone
                    local markerColor = zone.markerColor or Config.Interaction.markerColor
                    DrawMarker(
                        Config.Interaction.markerType,
                        zone.coords.x,
                        zone.coords.y,
                        zone.coords.z - 1.0,
                        0.0, 0.0, 0.0,
                        0.0, 0.0, 0.0,
                        Config.Interaction.markerScale.x,
                        Config.Interaction.markerScale.y,
                        Config.Interaction.markerScale.z,
                        markerColor.r,
                        markerColor.g,
                        markerColor.b,
                        markerColor.a,
                        false,
                        true,
                        2,
                        false,
                        nil,
                        nil,
                        false
                    )
                end
            end

            if Config.Guidance.show3DText then
                for _, row in ipairs(drawZones) do
                    if row.distance <= (row.zone.radius + 8.0) then
                        drawText3D(
                            vec3(row.zone.coords.x, row.zone.coords.y, row.zone.coords.z + 1.1),
                            row.zone.label
                        )
                    end
                end
            end
        end

        local insideZone = nil
        if nearestKey then
            local nearestZone = Config.Zones[nearestKey]
            if nearestDistance <= nearestZone.radius then
                insideZone = nearestKey
            end

            if nearestDistance <= (nearestZone.radius + 1.0) then
                if Config.Guidance.showHelpPrompt then
                    drawHelpText(promptForZone(nearestKey))
                end

                if IsControlJustReleased(0, Config.ClassicMode.interactKey or Config.Interaction.keyCode) then
                    if Config.ClassicMode.enabled then
                        runClassicInteract(nearestKey)
                    else
                        openTablet(zoneToTab(nearestKey))
                        TriggerServerEvent('kid_farm:requestSync')
                    end
                end
            end
        end

        if insideZone ~= currentInsideZone then
            currentInsideZone = insideZone
            if currentInsideZone then
                TriggerServerEvent('kid_farm:arrivedZone', currentInsideZone)
            end
        end

        Wait(sleep)
    end
end)

CreateThread(function()
    while true do
        if Config.Guidance.showObjectiveHint and Config.Guidance.objectiveHintMode == 'corner' and playerState and playerState.objective and playerState.objective.text then
            drawCornerObjective(playerState.objective.text)
            Wait(0)
        else
            Wait(350)
        end
    end
end)

CreateThread(function()
    while true do
        Wait(1000)

        if Config.Guidance.showObjectiveHint
            and Config.Guidance.objectiveHintMode ~= 'corner'
            and playerState
            and playerState.objective
            and playerState.objective.text
        then
            local intervalMs = (Config.Guidance.objectiveHintIntervalSeconds or 20) * 1000
            local tick = GetGameTimer()

            if tick - lastHintTick >= intervalMs then
                lastHintTick = tick
                local text = ('Objective: %s'):format(playerState.objective.text)

                if Config.Guidance.objectiveHintMode == 'subtitle' then
                    showSubtitle(text)
                elseif Config.Guidance.objectiveHintMode == 'chat' then
                    chatHint(text)
                end
            end
        end
    end
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    Wait(1200)
    TriggerServerEvent('kid_farm:requestSync')
end)

AddEventHandler('playerSpawned', function()
    Wait(800)
    TriggerServerEvent('kid_farm:requestSync')
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    stopCurrentAction(false)
    closeTablet()
    clearObjectiveBlip()
end)
