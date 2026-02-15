Config = {}

Config.UI = {
    TabletEnabled = true
}

Config.Ui = {
    command = 'farmtablet',
    keybind = 'F6',
    tabletTitle = 'Sunny Farm Tablet'
}

Config.ClassicMode = {
    enabled = true,
    interactKey = 38, -- E
    interactKeyLabel = 'E',
    startMarkerAtField = true,
    defaultCrop = 'wheat',
    defaultProcessRecipe = 'flour',
    autoSellAllOnInteract = true,
    startMessage = 'Farming started. Follow your map marker to the next step.',
    stopMessage = 'Farming stopped. Use /farm to start again.'
}

Config.Interaction = {
    keyCode = 38, -- Backward-compatible alias, mirrored from ClassicMode.interactKey.
    keyLabel = 'E',
    markerType = 1,
    markerScale = vec3(1.5, 1.5, 0.35),
    markerColor = { r = 92, g = 194, b = 112, a = 180 },
    drawDistance = 35.0
}

Config.Guidance = {
    showMarkers = true,
    show3DText = true,
    showHelpPrompt = true,
    showObjectiveHint = true,
    objectiveHintMode = 'corner', -- corner | subtitle | chat
    objectiveHintIntervalSeconds = 20
}

Config.ObjectiveBlip = {
    enabled = true,
    routeEnabled = true,
    sprite = 280,
    colour = 2,
    scale = 0.95,
    labelPrefix = 'Farming: '
}

Config.Objective = {
    showHelperText = true,
    defaultWaypoint = true
}

Config.Commands = {
    farm = true,
    farmhelp = true,
    farmstatus = true,
    farmroute = true,
    process = true,
    sell = true
}

Config.Progression = {
    levelThresholds = { 0, 90, 220, 420, 700, 1050, 1500, 2050 },
    levelBonusPerLevel = 0.05,
    levelBonusCap = 0.35,
    xp = {
        sellBase = 10,
        sellPerItem = 2
    }
}

Config.DailyLimit = {
    enabled = true,
    maxActions = 120,
    blockSellAtLimit = false,
    friendlyMessage = 'Great work today. The farm is resting now. Please come back tomorrow.'
}

Config.Persistence = {
    saveIntervalMs = 60000,
    saveDebounceMs = 1500
}

Config.Security = {
    distanceTolerance = 2.5,
    rateLimitsMs = {
        requestSync = 900,
        requestStatus = 900,
        arrivedZone = 1200,
        toggleJob = 1100,
        classicInteract = 1200,
        collect = 1500,
        process = 1500,
        sell = 1200,
        setWaypoint = 600,
        setRoute = 600,
        processCommand = 1300,
        sellCommand = 1300
    }
}

Config.Actions = {
    collectDurationMs = 3500,
    processDurationMs = 4000,
    sellDurationMs = 2200,
    collectScenario = 'WORLD_HUMAN_GARDENER_PLANT',
    processScenario = 'WORLD_HUMAN_HAMMERING',
    sellScenario = 'WORLD_HUMAN_CLIPBOARD',
    maxFieldHarvestsPerCycle = 10,
    maxProcessBatchesPerCycle = 10
}

Config.Zones = {
    field = {
        label = 'Sunny Field',
        description = 'Pick fresh crops here.',
        coords = vec3(2219.93, 5578.14, 53.84),
        radius = 24.0,
        markerColor = { r = 107, g = 214, b = 119, a = 180 },
        blip = {
            enabled = false,
            sprite = 68,
            color = 2,
            scale = 0.85,
            name = 'Farm Field'
        }
    },
    mill = {
        label = 'Barn Mill',
        description = 'Turn crops into tasty products.',
        coords = vec3(2885.93, 4387.35, 50.29),
        radius = 16.0,
        markerColor = { r = 237, g = 168, b = 67, a = 180 },
        blip = {
            enabled = false,
            sprite = 566,
            color = 17,
            scale = 0.85,
            name = 'Barn Mill'
        }
    },
    market = {
        label = 'Happy Market',
        description = 'Sell your farm goods for rewards.',
        coords = vec3(1707.24, 4938.23, 42.06),
        radius = 16.0,
        markerColor = { r = 95, g = 164, b = 255, a = 180 },
        blip = {
            enabled = false,
            sprite = 605,
            color = 3,
            scale = 0.85,
            name = 'Farm Market'
        }
    }
}

Config.Crops = {
    wheat = {
        label = 'Wheat',
        collectMin = 1,
        collectMax = 3,
        collectXP = 7
    },
    corn = {
        label = 'Corn',
        collectMin = 1,
        collectMax = 2,
        collectXP = 8
    }
}

Config.Recipes = {
    flour = {
        label = 'Mill Flour',
        inputs = { wheat = 2 },
        outputs = { flour = 1 },
        xp = 15
    },
    cornflour = {
        label = 'Corn Flour',
        inputs = { corn = 2 },
        outputs = { flour = 1 },
        xp = 14
    },
    bread = {
        label = 'Bake Bread',
        inputs = { flour = 2, corn = 1 },
        outputs = { bread = 1 },
        xp = 18
    }
}

Config.ProcessAliases = {
    wheat = 'flour',
    corn = 'cornflour'
}

Config.SellPrices = {
    wheat = 11,
    corn = 13,
    flour = 28,
    bread = 45
}

Config.ItemOrder = { 'wheat', 'corn', 'flour', 'bread' }

Config.ItemLabels = {
    wheat = 'Wheat',
    corn = 'Corn',
    flour = 'Flour',
    bread = 'Bread'
}

Config.Payout = {
    resource = 'money_system',
    method = 'AddPlayerCash',
    useThirdArg = true,
    thirdArgValue = true
}
