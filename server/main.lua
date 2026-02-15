local Profiles = {}
local Cooldowns = {}
local DbReady = false

local SAVE_DEBOUNCE_MS = (Config.Persistence and Config.Persistence.saveDebounceMs) or 1500
local SAVE_INTERVAL_MS = (Config.Persistence and Config.Persistence.saveIntervalMs) or 60000

local function nowMs()
    return GetGameTimer()
end

local function todayDate()
    return os.date('%Y-%m-%d')
end

local function roundNumber(num)
    return math.floor((num or 0) + 0.5)
end

local function clampInt(value, minValue, maxValue)
    local n = tonumber(value) or 0
    n = math.floor(n)

    if minValue and n < minValue then
        n = minValue
    end

    if maxValue and n > maxValue then
        n = maxValue
    end

    return n
end

local function parsePositiveInt(value)
    local n = tonumber(value)
    if not n then
        return nil
    end

    n = math.floor(n)
    if n <= 0 then
        return nil
    end

    return n
end

local function getFieldHarvestLimit()
    local raw = (Config.Actions and Config.Actions.maxFieldHarvestsPerCycle) or 10
    return clampInt(raw, 1, 100)
end

local function getProcessBatchLimit()
    local raw = (Config.Actions and Config.Actions.maxProcessBatchesPerCycle) or 10
    return clampInt(raw, 1, 100)
end

local function getIdentifier(source)
    local fallback = ('src:%d'):format(source)

    for i = 0, GetNumPlayerIdentifiers(source) - 1 do
        local id = GetPlayerIdentifier(source, i)
        if id and id:sub(1, 8) == 'license:' then
            return id
        end
    end

    for i = 0, GetNumPlayerIdentifiers(source) - 1 do
        local id = GetPlayerIdentifier(source, i)
        if id and id ~= '' then
            return id
        end
    end

    return fallback
end

local function copyMap(input)
    local out = {}
    if type(input) ~= 'table' then
        return out
    end

    for k, v in pairs(input) do
        out[k] = v
    end

    return out
end

local function normalizeZone(zoneKey)
    local key = tostring(zoneKey or ''):lower()
    if key == 'barn' then
        key = 'mill'
    end

    if Config.Zones[key] then
        return key
    end

    return nil
end

local function rateLimit(source, actionKey)
    local actionLimits = Config.Security and Config.Security.rateLimitsMs or {}
    local limit = tonumber(actionLimits[actionKey]) or 0

    if limit <= 0 then
        return true
    end

    local playerMap = Cooldowns[source]
    if not playerMap then
        playerMap = {}
        Cooldowns[source] = playerMap
    end

    local tick = nowMs()
    local last = playerMap[actionKey] or 0

    if tick - last < limit then
        return false
    end

    playerMap[actionKey] = tick
    return true
end

local function getDistanceToZone(source, zoneKey)
    local zone = Config.Zones[zoneKey]
    if not zone then
        return math.huge
    end

    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 then
        return math.huge
    end

    local pos = GetEntityCoords(ped)
    if not pos then
        return math.huge
    end

    local dx = pos.x - zone.coords.x
    local dy = pos.y - zone.coords.y
    local dz = pos.z - zone.coords.z

    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function isNearZone(source, zoneKey)
    local zone = Config.Zones[zoneKey]
    if not zone then
        return false
    end

    local tolerance = (Config.Security and Config.Security.distanceTolerance) or 2.5
    return getDistanceToZone(source, zoneKey) <= (zone.radius + tolerance)
end

local function farmChat(source, message, color)
    TriggerClientEvent('chat:addMessage', source, {
        color = color or { 124, 206, 114 },
        args = { 'kid_farm', message }
    })
end

local function farmToast(source, toastType, text)
    TriggerClientEvent('kid_farm:toast', source, {
        type = toastType,
        text = text
    })
end

local function markDirty(profile)
    profile._dirty = true
    profile._nextSaveAt = nowMs() + SAVE_DEBOUNCE_MS
end

local function ensureInventoryShape(inventory)
    local shaped = {}
    for _, itemKey in ipairs(Config.ItemOrder) do
        shaped[itemKey] = clampInt(inventory[itemKey] or 0, 0)
    end

    return shaped
end
local function getLevelFromXp(xp)
    local thresholds = Config.Progression.levelThresholds or { 0 }
    local level = 1

    for i = 1, #thresholds do
        if xp >= thresholds[i] then
            level = i
        else
            break
        end
    end

    return level
end

local function getLevelProgressPct(xp, level)
    local thresholds = Config.Progression.levelThresholds or { 0 }
    local currentThreshold = thresholds[level] or 0
    local nextThreshold = thresholds[level + 1]

    if not nextThreshold or nextThreshold <= currentThreshold then
        return 100
    end

    local progress = (xp - currentThreshold) / (nextThreshold - currentThreshold)
    if progress < 0 then
        progress = 0
    elseif progress > 1 then
        progress = 1
    end

    return roundNumber(progress * 100)
end

local function getLevelBonusPct(level)
    local perLevel = (Config.Progression and Config.Progression.levelBonusPerLevel) or 0.05
    local cap = (Config.Progression and Config.Progression.levelBonusCap) or 0.35
    local pct = math.max(0, (level - 1) * perLevel)

    if pct > cap then
        pct = cap
    end

    return pct
end

local function resetDailyQuest(profile)
    profile.quest.wentField = false
    profile.quest.collected = false
    profile.quest.processed = false
    profile.quest.sold = false
    profile.quest.collectStreak = 0
    profile.quest.processStreak = 0
end

local function setStage(profile, newStage)
    if profile.stage ~= newStage then
        profile.stage = newStage
        markDirty(profile)
    end
end

local function setFarmEnabled(profile, enabled)
    local flag = enabled and true or false
    if profile.farmEnabled ~= flag then
        profile.farmEnabled = flag
        markDirty(profile)
    end

    if not flag then
        setStage(profile, 'job_off')
        profile.preferences.manualRoute = nil
        return
    end

    if Config.DailyLimit.enabled and profile.daily.actions >= Config.DailyLimit.maxActions then
        setStage(profile, 'daily_complete')
        resetDailyQuest(profile)
    else
        setStage(profile, 'go_field')
        resetDailyQuest(profile)
    end
end

local function resetDailyIfNeeded(profile)
    local today = todayDate()
    if profile.daily.lastResetDate == today then
        return false
    end

    profile.daily.lastResetDate = today
    profile.daily.actions = 0
    profile.daily.collect = 0
    profile.daily.process = 0
    profile.daily.sell = 0

    if profile.stage == 'daily_complete' and profile.farmEnabled then
        setStage(profile, 'go_field')
    end

    markDirty(profile)
    return true
end

local function getDailyRemaining(profile)
    if not Config.DailyLimit.enabled then
        return math.huge
    end

    return math.max(0, Config.DailyLimit.maxActions - profile.daily.actions)
end

local function isDailyBlocked(profile, actionType)
    if not Config.DailyLimit.enabled then
        return false
    end

    if profile.daily.actions < Config.DailyLimit.maxActions then
        return false
    end

    if actionType == 'sell' and not Config.DailyLimit.blockSellAtLimit then
        return false
    end

    return true
end

local function applyXp(source, profile, amount)
    if amount <= 0 then
        return
    end

    local beforeLevel = profile.level
    profile.xp = profile.xp + amount
    profile.level = getLevelFromXp(profile.xp)
    markDirty(profile)

    if profile.level > beforeLevel then
        TriggerClientEvent('kid_farm:levelUp', source, {
            level = profile.level,
            previousLevel = beforeLevel
        })
    end
end

local function tryPayoutExternal(source, amount)
    local payout = Config.Payout or {}
    local resourceName = payout.resource
    local methodName = payout.method

    if not resourceName or not methodName then
        return false
    end

    if GetResourceState(resourceName) ~= 'started' then
        return false
    end

    local ok, result = pcall(function()
        if payout.useThirdArg then
            return exports[resourceName][methodName](source, amount, payout.thirdArgValue)
        end

        return exports[resourceName][methodName](source, amount)
    end)

    if not ok then
        print(('[kid_farm] payout export failed for source %s: %s'):format(source, tostring(result)))
        return false
    end

    return true
end

local function sortedRecipeKeys()
    local keys = {}
    for recipeKey in pairs(Config.Recipes) do
        keys[#keys + 1] = recipeKey
    end

    table.sort(keys)
    return keys
end

local function recipeFromArg(arg)
    local raw = tostring(arg or ''):lower()
    if raw == '' then
        return nil
    end

    if Config.Recipes[raw] then
        return raw
    end

    local alias = Config.ProcessAliases and Config.ProcessAliases[raw]
    if alias and Config.Recipes[alias] then
        return alias
    end

    local idx = tonumber(raw)
    if idx then
        local keys = sortedRecipeKeys()
        return keys[idx]
    end

    return nil
end

local function canCraftCount(profile, recipe)
    local maxTimes = math.huge

    for inputItem, needed in pairs(recipe.inputs or {}) do
        if needed <= 0 then
            return 0
        end

        local have = profile.inventory[inputItem] or 0
        local possible = math.floor(have / needed)
        if possible < maxTimes then
            maxTimes = possible
        end
    end

    if maxTimes == math.huge then
        return 0
    end

    return math.max(0, maxTimes)
end

local function hasAnyProcessable(profile)
    for _, recipe in pairs(Config.Recipes) do
        if canCraftCount(profile, recipe) > 0 then
            return true
        end
    end

    return false
end

local function hasAnySellable(profile)
    for itemKey, price in pairs(Config.SellPrices) do
        if (price or 0) > 0 and (profile.inventory[itemKey] or 0) > 0 then
            return true
        end
    end

    return false
end
local function ensureCycleStageForZone(profile, zoneKey)
    if zoneKey == 'field' and profile.stage == 'go_field' then
        profile.quest.wentField = true
        setStage(profile, 'collect')
        return true
    end

    if zoneKey == 'mill' and profile.stage == 'go_barn' then
        setStage(profile, 'process')
        return true
    end

    if zoneKey == 'market' and profile.stage == 'go_market' then
        setStage(profile, 'sell')
        return true
    end

    return false
end

local function objectiveForProfile(profile)
    if not profile.farmEnabled then
        return {
            key = 'job_off',
            zone = nil,
            text = 'Use /farm to start farming.'
        }
    end

    if profile.stage == 'daily_complete' then
        return {
            key = 'daily_complete',
            zone = nil,
            text = Config.DailyLimit.friendlyMessage
        }
    end

    if profile.stage == 'go_field' then
        return {
            key = 'go_field',
            zone = 'field',
            text = 'Go to the Field and start your farm day.'
        }
    end

    if profile.stage == 'collect' then
        local limit = getFieldHarvestLimit()
        local streak = clampInt(profile.quest.collectStreak or 0, 0, limit)
        return {
            key = 'collect',
            zone = 'field',
            text = ('Press [%s] to Harvest at the Field (%d/%d).'):format(
                Config.ClassicMode.interactKeyLabel or 'E',
                streak,
                limit
            )
        }
    end

    if profile.stage == 'go_barn' then
        if not hasAnyProcessable(profile) and hasAnySellable(profile) then
            return {
                key = 'go_market_raw',
                zone = 'market',
                text = 'Your batch is small. Go to Market and sell your raw crops.'
            }
        end

        return {
            key = 'go_barn',
            zone = 'mill',
            text = 'Take your crops to the Barn for processing.'
        }
    end

    if profile.stage == 'process' then
        local processLimit = getProcessBatchLimit()
        local processStreak = clampInt(profile.quest.processStreak or 0, 0, processLimit)

        if not hasAnyProcessable(profile) and hasAnySellable(profile) then
            return {
                key = 'go_market_raw',
                zone = 'market',
                text = 'Not enough ingredients right now. Sell your crops at Market.'
            }
        end

        return {
            key = 'process',
            zone = 'mill',
            text = ('Press [%s] to Process at the Barn (%d/%d).'):format(
                Config.ClassicMode.interactKeyLabel or 'E',
                processStreak,
                processLimit
            )
        }
    end

    if profile.stage == 'go_market' then
        return {
            key = 'go_market',
            zone = 'market',
            text = 'Head to the Market to sell your goods.'
        }
    end

    if profile.stage == 'sell' then
        return {
            key = 'sell',
            zone = 'market',
            text = ('Press [%s] to Sell at the Market.'):format(Config.ClassicMode.interactKeyLabel or 'E')
        }
    end

    return {
        key = 'go_field',
        zone = 'field',
        text = 'Go to the Field and continue farming.'
    }
end

local function buildQuestSteps(profile)
    local doneField = profile.quest.wentField or profile.quest.collected or profile.quest.processed or profile.quest.sold
    local doneCollect = profile.quest.collected or profile.quest.processed or profile.quest.sold
    local doneProcess = profile.quest.processed or profile.quest.sold
    local doneSell = profile.quest.sold

    return {
        { key = 'go_field', label = 'Go to Field', done = doneField },
        { key = 'collect', label = 'Collect crops', done = doneCollect },
        { key = 'process', label = 'Process at Barn', done = doneProcess },
        { key = 'sell', label = 'Sell at Market', done = doneSell }
    }
end

local function serializeRecipes()
    local output = {}

    for recipeKey, recipe in pairs(Config.Recipes) do
        output[recipeKey] = {
            key = recipeKey,
            label = recipe.label,
            inputs = copyMap(recipe.inputs),
            outputs = copyMap(recipe.outputs),
            xp = recipe.xp or 0
        }
    end

    return output
end

local function profileState(profile)
    local objective = objectiveForProfile(profile)
    local routeTarget = profile.preferences.manualRoute or objective.zone

    return {
        farmEnabled = profile.farmEnabled,
        stage = profile.stage,
        xp = profile.xp,
        level = profile.level,
        levelProgressPct = getLevelProgressPct(profile.xp, profile.level),
        levelBonusPct = roundNumber(getLevelBonusPct(profile.level) * 100),
        wallet = profile.wallet,
        inventory = copyMap(profile.inventory),
        itemOrder = Config.ItemOrder,
        itemLabels = Config.ItemLabels,
        crops = Config.Crops,
        recipes = serializeRecipes(),
        sellPrices = Config.SellPrices,
        objective = objective,
        routeTarget = routeTarget,
        questSteps = buildQuestSteps(profile),
        daily = {
            actions = profile.daily.actions,
            collect = profile.daily.collect,
            process = profile.daily.process,
            sell = profile.daily.sell,
            maxActions = Config.DailyLimit.maxActions,
            remaining = getDailyRemaining(profile),
            lastResetDate = profile.daily.lastResetDate
        },
        stats = {
            totalEarned = profile.stats.totalEarned,
            loopsCompleted = profile.stats.loopsCompleted
        },
        preferences = {
            waypoint = profile.preferences.waypoint,
            manualRoute = profile.preferences.manualRoute
        }
    }
end

local function syncProfile(source, profile)
    TriggerClientEvent('kid_farm:syncState', source, profileState(profile))
end

local function createDefaultProfile(identifier)
    return {
        identifier = identifier,
        xp = 0,
        level = 1,
        wallet = 0,
        inventory = ensureInventoryShape({}),
        daily = {
            actions = 0,
            collect = 0,
            process = 0,
            sell = 0,
            lastResetDate = todayDate()
        },
        stats = {
            totalEarned = 0,
            loopsCompleted = 0
        },
        preferences = {
            waypoint = Config.Objective.defaultWaypoint and true or false,
            manualRoute = nil
        },
        quest = {
            wentField = false,
            collected = false,
            processed = false,
            sold = false,
            collectStreak = 0,
            processStreak = 0
        },
        farmEnabled = false,
        stage = 'job_off',
        _dirty = false,
        _nextSaveAt = 0,
        _saving = false
    }
end

local function loadProfile(source)
    local identifier = getIdentifier(source)
    local row = DB.fetchOne('SELECT * FROM kid_farm_players WHERE identifier = @identifier', {
        ['@identifier'] = identifier
    })

    local profile = createDefaultProfile(identifier)

    if row then
        profile.xp = clampInt(row.xp, 0)
        profile.level = clampInt(row.level, 1)
        profile.wallet = clampInt(row.wallet, 0)
        profile.inventory = ensureInventoryShape({
            wheat = row.wheat,
            corn = row.corn,
            flour = row.flour,
            bread = row.bread
        })
        profile.daily.actions = clampInt(row.daily_actions, 0)
        profile.daily.collect = clampInt(row.daily_collect, 0)
        profile.daily.process = clampInt(row.daily_process, 0)
        profile.daily.sell = clampInt(row.daily_sell, 0)
        profile.daily.lastResetDate = tostring(row.last_reset_date or todayDate())
        profile.stats.totalEarned = clampInt(row.total_earned, 0)
        profile.stats.loopsCompleted = clampInt(row.loops_completed, 0)
        profile.preferences.waypoint = (tonumber(row.waypoint_enabled) or 0) == 1

        local expectedLevel = getLevelFromXp(profile.xp)
        if profile.level ~= expectedLevel then
            profile.level = expectedLevel
            markDirty(profile)
        end
    else
        markDirty(profile)
    end

    resetDailyIfNeeded(profile)
    Profiles[source] = profile

    return profile
end
local function ensureProfile(source)
    if Profiles[source] then
        return Profiles[source]
    end

    if not DbReady then
        return nil
    end

    return loadProfile(source)
end

local function saveProfile(source, force)
    local profile = Profiles[source]
    if not profile then
        return
    end

    if profile._saving then
        return
    end

    if not force and not profile._dirty then
        return
    end

    profile._saving = true

    DB.execute([[
        INSERT INTO kid_farm_players (
            identifier, xp, level, wallet,
            wheat, corn, flour, bread,
            daily_actions, daily_collect, daily_process, daily_sell,
            last_reset_date, total_earned, loops_completed, waypoint_enabled
        ) VALUES (
            @identifier, @xp, @level, @wallet,
            @wheat, @corn, @flour, @bread,
            @daily_actions, @daily_collect, @daily_process, @daily_sell,
            @last_reset_date, @total_earned, @loops_completed, @waypoint_enabled
        )
        ON DUPLICATE KEY UPDATE
            xp = VALUES(xp),
            level = VALUES(level),
            wallet = VALUES(wallet),
            wheat = VALUES(wheat),
            corn = VALUES(corn),
            flour = VALUES(flour),
            bread = VALUES(bread),
            daily_actions = VALUES(daily_actions),
            daily_collect = VALUES(daily_collect),
            daily_process = VALUES(daily_process),
            daily_sell = VALUES(daily_sell),
            last_reset_date = VALUES(last_reset_date),
            total_earned = VALUES(total_earned),
            loops_completed = VALUES(loops_completed),
            waypoint_enabled = VALUES(waypoint_enabled)
    ]], {
        ['@identifier'] = profile.identifier,
        ['@xp'] = profile.xp,
        ['@level'] = profile.level,
        ['@wallet'] = profile.wallet,
        ['@wheat'] = profile.inventory.wheat,
        ['@corn'] = profile.inventory.corn,
        ['@flour'] = profile.inventory.flour,
        ['@bread'] = profile.inventory.bread,
        ['@daily_actions'] = profile.daily.actions,
        ['@daily_collect'] = profile.daily.collect,
        ['@daily_process'] = profile.daily.process,
        ['@daily_sell'] = profile.daily.sell,
        ['@last_reset_date'] = profile.daily.lastResetDate,
        ['@total_earned'] = profile.stats.totalEarned,
        ['@loops_completed'] = profile.stats.loopsCompleted,
        ['@waypoint_enabled'] = profile.preferences.waypoint and 1 or 0
    })

    profile._dirty = false
    profile._nextSaveAt = 0
    profile._saving = false
end

local function actionDenied(source, profile)
    local objective = objectiveForProfile(profile)
    local zoneKey = objective.zone
    local zoneLabel = zoneKey and Config.Zones[zoneKey] and Config.Zones[zoneKey].label or 'the next zone'
    farmToast(source, 'warn', ('You need to go to %s next. Check your map marker!'):format(zoneLabel))
end

local function collectAction(source, profile, cropKey)
    resetDailyIfNeeded(profile)

    if not profile.farmEnabled then
        farmToast(source, 'warn', 'Use /farm to start farming first.')
        return false
    end

    if profile.stage == 'daily_complete' then
        farmToast(source, 'warn', Config.DailyLimit.friendlyMessage)
        return false
    end

    if not isNearZone(source, 'field') then
        farmToast(source, 'warn', 'Move closer to the Field before harvesting.')
        return false
    end

    ensureCycleStageForZone(profile, 'field')

    if profile.stage ~= 'collect' then
        actionDenied(source, profile)
        return false
    end

    if isDailyBlocked(profile, 'collect') then
        setStage(profile, 'daily_complete')
        farmToast(source, 'warn', Config.DailyLimit.friendlyMessage)
        return false
    end

    local crop = Config.Crops[cropKey]
    if not crop then
        cropKey = Config.ClassicMode.defaultCrop
        crop = Config.Crops[cropKey]
    end

    if not crop then
        farmToast(source, 'error', 'No crop config found for harvesting.')
        return false
    end

    local gain = math.random(crop.collectMin or 1, crop.collectMax or 1)
    profile.inventory[cropKey] = (profile.inventory[cropKey] or 0) + gain
    profile.daily.actions = profile.daily.actions + 1
    profile.daily.collect = profile.daily.collect + 1
    profile.quest.wentField = true
    profile.quest.collected = true
    profile.quest.processed = false
    profile.quest.sold = false
    profile.quest.collectStreak = clampInt((profile.quest.collectStreak or 0) + 1, 0)

    applyXp(source, profile, (crop.collectXP or 0) * gain)
    local harvestLimit = getFieldHarvestLimit()
    if profile.quest.collectStreak >= harvestLimit then
        TriggerClientEvent('kid_farm:stopAnim', source, {
            reason = 'harvest_limit_reached'
        })

        if hasAnyProcessable(profile) then
            setStage(profile, 'go_barn')
            farmToast(source, 'info', ('Harvest basket full (%d/%d). Head to the Barn to process.'):format(profile.quest.collectStreak, harvestLimit))
        else
            setStage(profile, 'go_market')
            farmToast(source, 'info', ('Harvest basket full (%d/%d). This batch is small, so sell at Market now.'):format(profile.quest.collectStreak, harvestLimit))
        end
    else
        setStage(profile, 'collect')
        if hasAnyProcessable(profile) then
            farmToast(source, 'info', ('Harvest %d/%d. Keep collecting or go to Barn anytime.'):format(profile.quest.collectStreak, harvestLimit))
        else
            farmToast(source, 'info', ('Harvest %d/%d. Keep collecting or sell at Market anytime.'):format(profile.quest.collectStreak, harvestLimit))
        end
    end
    markDirty(profile)

    farmToast(source, 'success', ('Great job! You collected %dx %s.'):format(gain, crop.label or cropKey))
    return true
end

local function processAction(source, profile, recipeKey, requestedTimes)
    resetDailyIfNeeded(profile)

    if not profile.farmEnabled then
        farmToast(source, 'warn', 'Use /farm to start farming first.')
        return false
    end
    if profile.stage == 'daily_complete' then
        farmToast(source, 'warn', Config.DailyLimit.friendlyMessage)
        return false
    end

    if not isNearZone(source, 'mill') then
        farmToast(source, 'warn', 'Move closer to the Barn before processing.')
        return false
    end

    ensureCycleStageForZone(profile, 'mill')

    if profile.stage ~= 'process' then
        if profile.stage == 'collect' and hasAnyProcessable(profile) then
            setStage(profile, 'process')
        end
    end

    if profile.stage ~= 'process' then
        actionDenied(source, profile)
        return false
    end

    if isDailyBlocked(profile, 'process') then
        setStage(profile, 'daily_complete')
        farmToast(source, 'warn', Config.DailyLimit.friendlyMessage)
        return false
    end

    local recipe = Config.Recipes[recipeKey]
    if not recipe then
        farmToast(source, 'warn', 'Unknown recipe. Use /process to view options.')
        return false
    end

    local processLimit = getProcessBatchLimit()
    local processStreak = clampInt(profile.quest.processStreak or 0, 0, processLimit)
    local remainingBatchSlots = math.max(0, processLimit - processStreak)

    if remainingBatchSlots <= 0 then
        if hasAnySellable(profile) then
            setStage(profile, 'go_market')
            farmToast(source, 'info', ('Processing cap reached (%d/%d). Go to Market and sell this batch.'):format(processStreak, processLimit))
        else
            setStage(profile, 'go_field')
            resetDailyQuest(profile)
            farmToast(source, 'info', 'Processing cap reached and no leftovers remain. Go back to Field.')
        end

        markDirty(profile)
        return false
    end

    local maxTimes = canCraftCount(profile, recipe)
    if maxTimes <= 0 then
        if hasAnySellable(profile) then
            setStage(profile, 'go_market')
            markDirty(profile)
            farmToast(source, 'warn', 'Not enough ingredients. You can sell your crops at Market.')
        else
            setStage(profile, 'go_field')
            resetDailyQuest(profile)
            markDirty(profile)
            farmToast(source, 'info', 'No processable ingredients or leftovers right now. Go back to Field.')
        end
        return false
    end

    local times = requestedTimes or 1
    times = clampInt(times, 1, math.min(maxTimes, remainingBatchSlots))

    for inputItem, needed in pairs(recipe.inputs or {}) do
        profile.inventory[inputItem] = (profile.inventory[inputItem] or 0) - (needed * times)
    end

    for outputItem, produced in pairs(recipe.outputs or {}) do
        profile.inventory[outputItem] = (profile.inventory[outputItem] or 0) + (produced * times)
    end

    profile.daily.actions = profile.daily.actions + 1
    profile.daily.process = profile.daily.process + 1
    profile.quest.processed = true
    profile.quest.sold = false
    profile.quest.processStreak = clampInt(processStreak + times, 0, processLimit)

    applyXp(source, profile, (recipe.xp or 0) * times)
    local hasMoreProcessable = hasAnyProcessable(profile)
    local hasLeftovers = hasAnySellable(profile)

    if profile.quest.processStreak >= processLimit then
        if hasLeftovers then
            setStage(profile, 'go_market')
            farmToast(source, 'info', ('Processed %d/%d batches. Head to Market to sell.'):format(profile.quest.processStreak, processLimit))
        else
            setStage(profile, 'go_field')
            resetDailyQuest(profile)
            farmToast(source, 'info', 'Processed 10 batches and no leftovers remain. Back to Field.')
        end
    elseif hasMoreProcessable then
        setStage(profile, 'process')
        farmToast(source, 'info', ('Processed %d/%d batches. Keep processing or go sell at Market.'):format(profile.quest.processStreak, processLimit))
    else
        if hasLeftovers then
            setStage(profile, 'go_market')
            farmToast(source, 'info', ('Not enough ingredients to reach %d. Sell leftovers at Market now.'):format(processLimit))
        else
            setStage(profile, 'go_field')
            resetDailyQuest(profile)
            farmToast(source, 'info', ('Not enough ingredients and no leftovers. Return to Field.'))
        end
    end

    markDirty(profile)

    farmToast(source, 'success', ('Nice! Processed %d batch(es) of %s.'):format(times, recipe.label or recipeKey))
    return true
end

local function buildSaleItems(profile, requestItems)
    local items = {}

    local function addItem(itemKey, quantity)
        local price = Config.SellPrices[itemKey] or 0
        local have = profile.inventory[itemKey] or 0
        local qty = clampInt(quantity, 0, have)

        if qty <= 0 or price <= 0 then
            return
        end

        items[#items + 1] = {
            key = itemKey,
            label = Config.ItemLabels[itemKey] or itemKey,
            quantity = qty,
            unitPrice = price,
            lineTotal = qty * price
        }
    end

    if type(requestItems) ~= 'table' then
        for _, itemKey in ipairs(Config.ItemOrder) do
            addItem(itemKey, profile.inventory[itemKey] or 0)
        end
        return items
    end

    local hasExplicit = false
    for itemKey, quantity in pairs(requestItems) do
        hasExplicit = true
        addItem(itemKey, quantity)
    end

    if not hasExplicit then
        for _, itemKey in ipairs(Config.ItemOrder) do
            addItem(itemKey, profile.inventory[itemKey] or 0)
        end
    end

    return items
end

local function sellAction(source, profile, requestItems)
    resetDailyIfNeeded(profile)

    if not profile.farmEnabled then
        farmToast(source, 'warn', 'Use /farm to start farming first.')
        return false
    end

    if profile.stage == 'daily_complete' then
        farmToast(source, 'warn', Config.DailyLimit.friendlyMessage)
        return false
    end

    if not isNearZone(source, 'market') then
        farmToast(source, 'warn', 'Move closer to the Market before selling.')
        return false
    end

    ensureCycleStageForZone(profile, 'market')

    if profile.stage ~= 'sell' then
        if (profile.stage == 'collect' and hasAnySellable(profile))
            or ((profile.stage == 'go_barn' or profile.stage == 'process') and not hasAnyProcessable(profile) and hasAnySellable(profile)) then
            setStage(profile, 'sell')
        else
            actionDenied(source, profile)
            return false
        end
    end

    if isDailyBlocked(profile, 'sell') then
        setStage(profile, 'daily_complete')
        farmToast(source, 'warn', Config.DailyLimit.friendlyMessage)
        return false
    end

    local saleItems = buildSaleItems(profile, requestItems)
    if #saleItems == 0 then
        farmToast(source, 'warn', 'You have nothing to sell right now.')
        return false
    end

    local subtotal = 0
    local soldCount = 0

    for _, line in ipairs(saleItems) do
        profile.inventory[line.key] = (profile.inventory[line.key] or 0) - line.quantity
        subtotal = subtotal + line.lineTotal
        soldCount = soldCount + line.quantity
    end

    local bonusPct = getLevelBonusPct(profile.level)
    local totalPayout = roundNumber(subtotal * (1.0 + bonusPct))

    local paidToWallet = false
    if not tryPayoutExternal(source, totalPayout) then
        profile.wallet = profile.wallet + totalPayout
        paidToWallet = true
    end

    local xpCfg = Config.Progression.xp or {}
    local gainedXp = (xpCfg.sellBase or 0) + (xpCfg.sellPerItem or 0) * soldCount
    applyXp(source, profile, gainedXp)

    profile.daily.actions = profile.daily.actions + 1
    profile.daily.sell = profile.daily.sell + 1
    profile.stats.totalEarned = profile.stats.totalEarned + totalPayout
    profile.stats.loopsCompleted = profile.stats.loopsCompleted + 1

    profile.quest.sold = true

    if Config.DailyLimit.enabled and profile.daily.actions >= Config.DailyLimit.maxActions then
        setStage(profile, 'daily_complete')
    else
        if hasAnySellable(profile) then
            setStage(profile, 'sell')
            farmToast(source, 'info', 'You still have leftovers. Sell the remaining items at Market.')
        else
            setStage(profile, 'go_field')
            resetDailyQuest(profile)
        end
    end

    markDirty(profile)

    TriggerClientEvent('kid_farm:saleReceipt', source, {
        items = saleItems,
        bonusPct = roundNumber(bonusPct * 100),
        subtotal = subtotal,
        totalPayout = totalPayout,
        paidToWallet = paidToWallet
    })

    farmToast(source, 'success', ('Sold %d item(s) for $%d.'):format(soldCount, totalPayout))
    return true
end

local function resolveBestRecipe(profile)
    local preferred = Config.ClassicMode.defaultProcessRecipe
    if preferred and Config.Recipes[preferred] and canCraftCount(profile, Config.Recipes[preferred]) > 0 then
        return preferred
    end

    for recipeKey, recipe in pairs(Config.Recipes) do
        if canCraftCount(profile, recipe) > 0 then
            return recipeKey
        end
    end

    return nil
end

local function ensureLoadedThen(source, action)
    local profile = ensureProfile(source)
    if not profile then
        farmToast(source, 'error', 'Farm data is still loading. Please try again in a moment.')
        return
    end

    resetDailyIfNeeded(profile)
    action(profile)
end

RegisterNetEvent('kid_farm:requestSync', function()
    local source = source
    if not rateLimit(source, 'requestSync') then
        return
    end

    ensureLoadedThen(source, function(profile)
        syncProfile(source, profile)
    end)
end)

RegisterNetEvent('kid_farm:requestStatus', function()
    local source = source
    if not rateLimit(source, 'requestStatus') then
        return
    end

    ensureLoadedThen(source, function(profile)
        TriggerClientEvent('kid_farm:status', source, profileState(profile))
    end)
end)

RegisterNetEvent('kid_farm:setWaypoint', function(enabled)
    local source = source
    if not rateLimit(source, 'setWaypoint') then
        return
    end

    ensureLoadedThen(source, function(profile)
        profile.preferences.waypoint = enabled and true or false
        if not profile.preferences.waypoint then
            profile.preferences.manualRoute = nil
        end

        markDirty(profile)
        syncProfile(source, profile)
    end)
end)

RegisterNetEvent('kid_farm:arrivedZone', function(zoneKey)
    local source = source
    if not rateLimit(source, 'arrivedZone') then
        return
    end

    local normalizedZone = normalizeZone(zoneKey)
    if not normalizedZone then
        return
    end

    ensureLoadedThen(source, function(profile)
        if not profile.farmEnabled then
            return
        end

        if not isNearZone(source, normalizedZone) then
            return
        end

        if ensureCycleStageForZone(profile, normalizedZone) then
            syncProfile(source, profile)
        end
    end)
end)

RegisterNetEvent('kid_farm:collect', function(payload)
    local source = source
    if not rateLimit(source, 'collect') then
        return
    end

    local cropKey = tostring(payload and payload.crop or Config.ClassicMode.defaultCrop)

    ensureLoadedThen(source, function(profile)
        collectAction(source, profile, cropKey)
        syncProfile(source, profile)
    end)
end)

RegisterNetEvent('kid_farm:process', function(payload)
    local source = source
    if not rateLimit(source, 'process') then
        return
    end

    local recipeKey = tostring(payload and payload.recipe or '')

    ensureLoadedThen(source, function(profile)
        processAction(source, profile, recipeKey, 1)
        syncProfile(source, profile)
    end)
end)

RegisterNetEvent('kid_farm:sell', function(payload)
    local source = source
    if not rateLimit(source, 'sell') then
        return
    end

    local requestItems = payload and payload.items or nil

    ensureLoadedThen(source, function(profile)
        sellAction(source, profile, requestItems)
        syncProfile(source, profile)
    end)
end)

RegisterNetEvent('kid_farm:classicInteract', function(payload)
    local source = source
    if not Config.ClassicMode.enabled then
        return
    end

    if not rateLimit(source, 'classicInteract') then
        return
    end

    local zoneKey = normalizeZone(payload and payload.zone)
    if not zoneKey then
        return
    end

    ensureLoadedThen(source, function(profile)
        if not isNearZone(source, zoneKey) then
            farmToast(source, 'warn', 'Move closer to the marker first.')
            return
        end

        if not profile.farmEnabled then
            if zoneKey == 'field' and Config.ClassicMode.startMarkerAtField then
                setFarmEnabled(profile, true)
                ensureCycleStageForZone(profile, 'field')
                farmToast(source, 'success', Config.ClassicMode.startMessage)
                syncProfile(source, profile)
            else
                farmToast(source, 'warn', 'Use /farm to start farming.')
            end
            return
        end

        if profile.stage == 'daily_complete' then
            farmToast(source, 'warn', Config.DailyLimit.friendlyMessage)
            syncProfile(source, profile)
            return
        end

        if zoneKey == 'field' and (profile.stage == 'go_field' or profile.stage == 'collect') then
            collectAction(source, profile, tostring(payload and payload.crop or Config.ClassicMode.defaultCrop))
            syncProfile(source, profile)
            return
        end

        if zoneKey == 'mill' and (profile.stage == 'go_barn' or profile.stage == 'process') then
            local recipeKey = tostring(payload and payload.recipe or '')
            if recipeKey == '' then
                recipeKey = resolveBestRecipe(profile)
            end

            if not recipeKey then
                if hasAnySellable(profile) then
                    setStage(profile, 'go_market')
                    farmToast(source, 'info', 'This batch cannot be processed yet. Go to Market and sell your crops.')
                else
                    farmToast(source, 'warn', 'No recipe available. Use /process to choose a recipe and amount.')
                end
                syncProfile(source, profile)
                return
            end

            processAction(source, profile, recipeKey, 1)
            syncProfile(source, profile)
            return
        end

        if zoneKey == 'market' and (profile.stage == 'go_market' or profile.stage == 'sell') then
            local requestItems = Config.ClassicMode.autoSellAllOnInteract and {} or (payload and payload.items)
            sellAction(source, profile, requestItems)
            syncProfile(source, profile)
            return
        end

        actionDenied(source, profile)
        syncProfile(source, profile)
    end)
end)

if Config.Commands.farm then
    RegisterCommand('farm', function(source, args)
        if source == 0 then
            print('[kid_farm] /farm can only be used by players.')
            return
        end

        if not rateLimit(source, 'toggleJob') then
            return
        end

        ensureLoadedThen(source, function(profile)
            local arg = tostring(args[1] or ''):lower()
            local enable = nil

            if arg == 'on' or arg == 'start' then
                enable = true
            elseif arg == 'off' or arg == 'stop' then
                enable = false
            else
                enable = not profile.farmEnabled
            end

            setFarmEnabled(profile, enable)

            if enable and isNearZone(source, 'field') then
                ensureCycleStageForZone(profile, 'field')
            end

            if enable then
                farmToast(source, 'success', Config.ClassicMode.startMessage)
            else
                farmToast(source, 'warn', Config.ClassicMode.stopMessage)
            end

            syncProfile(source, profile)
        end)
    end, false)
end

if Config.Commands.farmhelp then
    RegisterCommand('farmhelp', function(source)
        if source == 0 then
            return
        end

        farmChat(source, 'Farm loop: /farm -> Field (E) -> Barn (E) -> Market (E) -> repeat.')
        farmChat(source, 'Classic commands: /farmstatus, /farmroute [field|barn|market|off], /process [recipe|1|2] [amount], /sell [item|all] [amount].')
        farmChat(source, 'Tablet is optional: use /farmtablet if you want the full UI.')
    end, false)
end

if Config.Commands.farmstatus then
    RegisterCommand('farmstatus', function(source)
        if source == 0 then
            return
        end

        if not rateLimit(source, 'requestStatus') then
            return
        end

        ensureLoadedThen(source, function(profile)
            local objective = objectiveForProfile(profile)
            local bonusPct = roundNumber(getLevelBonusPct(profile.level) * 100)
            farmChat(source, ('Status: %s | Level %d (%d XP) | Bonus +%d%%'):format(profile.farmEnabled and 'ON' or 'OFF', profile.level, profile.xp, bonusPct))
            farmChat(source, ('Objective: %s'):format(objective.text))
            farmChat(source, ('Inventory: Wheat %d | Corn %d | Flour %d | Bread %d'):format(
                profile.inventory.wheat,
                profile.inventory.corn,
                profile.inventory.flour,
                profile.inventory.bread
            ))
            farmChat(source, ('Daily actions: %d/%d (remaining %d)'):format(
                profile.daily.actions,
                Config.DailyLimit.maxActions,
                getDailyRemaining(profile)
            ))
        end)
    end, false)
end
if Config.Commands.farmroute then
    RegisterCommand('farmroute', function(source, args)
        if source == 0 then
            return
        end

        if not rateLimit(source, 'setRoute') then
            return
        end

        ensureLoadedThen(source, function(profile)
            local arg = tostring(args[1] or ''):lower()
            if arg == '' or arg == 'auto' or arg == 'objective' then
                profile.preferences.manualRoute = nil
                profile.preferences.waypoint = true
                farmToast(source, 'success', 'Route set to automatic objective mode.')
                markDirty(profile)
                syncProfile(source, profile)
                return
            end

            if arg == 'off' then
                profile.preferences.manualRoute = nil
                profile.preferences.waypoint = false
                farmToast(source, 'warn', 'Route guidance turned off.')
                markDirty(profile)
                syncProfile(source, profile)
                return
            end

            local zoneKey = normalizeZone(arg)
            if not zoneKey then
                farmToast(source, 'warn', 'Usage: /farmroute [field|barn|market|off|auto]')
                return
            end

            profile.preferences.manualRoute = zoneKey
            profile.preferences.waypoint = true
            markDirty(profile)
            farmToast(source, 'success', ('Route locked to %s.'):format(Config.Zones[zoneKey].label))
            syncProfile(source, profile)
        end)
    end, false)
end

if Config.Commands.process then
    RegisterCommand('process', function(source, args)
        if source == 0 then
            return
        end

        if not rateLimit(source, 'processCommand') then
            return
        end

        ensureLoadedThen(source, function(profile)
            if not profile.farmEnabled then
                farmToast(source, 'warn', 'Use /farm to start farming first.')
                return
            end

            if not isNearZone(source, 'mill') then
                farmToast(source, 'warn', 'Go to the Barn before processing.')
                return
            end

            local recipeArg = args[1]
            if not recipeArg then
                farmChat(source, 'Process options:')
                local keys = sortedRecipeKeys()
                for idx, recipeKey in ipairs(keys) do
                    local recipe = Config.Recipes[recipeKey]
                    farmChat(source, ('  %d) %s  -> use /process %d [amount]'):format(idx, recipe.label or recipeKey, idx))
                end
                return
            end

            local recipeKey = recipeFromArg(recipeArg)
            if not recipeKey then
                farmToast(source, 'warn', 'Unknown recipe. Use /process to list recipes.')
                return
            end

            local recipe = Config.Recipes[recipeKey]
            local maxTimes = canCraftCount(profile, recipe)
            if maxTimes <= 0 then
                if hasAnySellable(profile) then
                    setStage(profile, 'go_market')
                    markDirty(profile)
                    farmToast(source, 'warn', 'Not enough ingredients. Go to Market and sell your crops.')
                else
                    farmToast(source, 'warn', 'Not enough ingredients for that recipe.')
                end
                syncProfile(source, profile)
                return
            end

            local amount = parsePositiveInt(args[2])
            if not amount then
                amount = maxTimes
            end

            amount = math.min(amount, maxTimes)

            processAction(source, profile, recipeKey, amount)
            syncProfile(source, profile)
        end)
    end, false)
end

if Config.Commands.sell then
    RegisterCommand('sell', function(source, args)
        if source == 0 then
            return
        end

        if not rateLimit(source, 'sellCommand') then
            return
        end

        ensureLoadedThen(source, function(profile)
            if not profile.farmEnabled then
                farmToast(source, 'warn', 'Use /farm to start farming first.')
                return
            end

            if not isNearZone(source, 'market') then
                farmToast(source, 'warn', 'Go to the Market before selling.')
                return
            end

            local first = tostring(args[1] or ''):lower()
            local requestItems = {}

            if first == '' or first == 'all' then
                requestItems = {}
            else
                if not Config.SellPrices[first] then
                    farmToast(source, 'warn', 'Unknown sell item. Try /sell all or /sell wheat 5')
                    return
                end

                local amount = parsePositiveInt(args[2])
                if not amount then
                    amount = profile.inventory[first] or 0
                end

                requestItems[first] = amount
            end

            sellAction(source, profile, requestItems)
            syncProfile(source, profile)
        end)
    end, false)
end

AddEventHandler('playerDropped', function()
    local source = source
    if Profiles[source] then
        saveProfile(source, true)
    end

    Profiles[source] = nil
    Cooldowns[source] = nil
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    for source in pairs(Profiles) do
        saveProfile(source, true)
    end
end)

CreateThread(function()
    while true do
        Wait(1000)
        local tick = nowMs()

        for source, profile in pairs(Profiles) do
            if profile._dirty and profile._nextSaveAt > 0 and tick >= profile._nextSaveAt then
                saveProfile(source, false)
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(SAVE_INTERVAL_MS)

        for source, profile in pairs(Profiles) do
            if profile._dirty then
                saveProfile(source, false)
            end
        end
    end
end)

DB.ready(function()
    DB.execute([[
        CREATE TABLE IF NOT EXISTS kid_farm_players (
            identifier VARCHAR(80) NOT NULL PRIMARY KEY,
            xp INT NOT NULL DEFAULT 0,
            level INT NOT NULL DEFAULT 1,
            wallet INT NOT NULL DEFAULT 0,
            wheat INT NOT NULL DEFAULT 0,
            corn INT NOT NULL DEFAULT 0,
            flour INT NOT NULL DEFAULT 0,
            bread INT NOT NULL DEFAULT 0,
            daily_actions INT NOT NULL DEFAULT 0,
            daily_collect INT NOT NULL DEFAULT 0,
            daily_process INT NOT NULL DEFAULT 0,
            daily_sell INT NOT NULL DEFAULT 0,
            last_reset_date DATE NOT NULL,
            total_earned INT NOT NULL DEFAULT 0,
            loops_completed INT NOT NULL DEFAULT 0,
            waypoint_enabled TINYINT(1) NOT NULL DEFAULT 1,
            updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            INDEX idx_kid_farm_last_reset (last_reset_date),
            INDEX idx_kid_farm_level (level)
        )
    ]])

    DbReady = true
    print('[kid_farm] database ready and farming loop loaded.')
end)
