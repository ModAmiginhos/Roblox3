-- TP Lock Script (Global Vector Position + Rotation Alignment Patch)
-- Features: Safe Zone System, Noclip, Priority Tab, Keybinds, Instant Switching, and Dummy Blacklist

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

getgenv().TPToLowHP = true

local LOCK_DELAY = 0.015
local MAX_HP_THRESHOLD = 1e15
local FARM_DISTANCE = 4 -- Default positioning value

-- Proximity / Camping System Variables
local bossCampPosition = nil
local CAMP_RADIUS = 150 -- How far away from the boss spawn you can wander to farm regular mobs

local currentTarget = nil
local scriptRunning = true

-- Modes
local autoFarmMode = false
local hybridMode = false
local priorityHighToLow = false -- false = Low→High, true = High→Low

local selectedEnemies = {}
local dropdownMap = {}

-- UI Lock to prevent toggle loops
local changingToggles = false 

--------------------------------------------------
-- Safe Zone System
--------------------------------------------------
local safeZonePart = nil

local function getOrCreateSafeZone()
    if not safeZonePart or not safeZonePart.Parent then
        safeZonePart = Instance.new("Part")
        safeZonePart.Name = "AutoFarmSafeZone_TPLock"
        safeZonePart.Size = Vector3.new(150, 10, 150)
        safeZonePart.Position = Vector3.new(0, 100000, 0) -- Way above the map
        safeZonePart.Anchored = true
        safeZonePart.CanCollide = true
        safeZonePart.Transparency = 0.5
        safeZonePart.BrickColor = BrickColor.new("Toothpaste")
        safeZonePart.Material = Enum.Material.Neon
        safeZonePart.Parent = workspace
    end
    return safeZonePart
end

getOrCreateSafeZone()

--------------------------------------------------
-- Noclip Variables
--------------------------------------------------
local noclipEnabled = false
local noclipConnection = nil

--------------------------------------------------
-- Number Formatting
--------------------------------------------------
local abbreviations = {
    {1e63, "VG"}, {1e60, "NvD"}, {1e57, "OcD"}, {1e54, "SpD"},
    {1e51, "SxD"}, {1e48, "QiD"}, {1e45, "QaD"}, {1e42, "TD"},
    {1e39, "DD"}, {1e36, "UD"}, {1e33, "DC"}, {1e30, "N"},
    {1e27, "OC"}, {1e24, "SP"}, {1e21, "SX"}, {1e18, "QI"},
    {1e15, "QA"}, {1e12, "T"}, {1e9, "B"}, {1e6, "M"}, {1e3, "K"}
}

local function formatNumber(num)
    if num < 1000 then return tostring(math.floor(num)) end
    for _, data in ipairs(abbreviations) do
        local threshold, suffix = data[1], data[2]
        if num >= threshold then
            return string.format("%.2f%s", num / threshold, suffix)
        end
    end
    return tostring(math.floor(num))
end

local function parseNumber(str)
    str = string.upper(string.gsub(str, "%s+", ""))
    for _, data in ipairs(abbreviations) do
        local threshold, suffix = data[1], data[2]
        if string.find(str, suffix .. "$") then
            local numPart = string.gsub(str, suffix .. "$", "")
            local num = tonumber(numPart)
            if num then return num * threshold end
        end
    end
    return tonumber(str)
end

--------------------------------------------------
-- UI Initialization
--------------------------------------------------
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "TP Lock Script",
    LoadingTitle = "Lock-on System",
    LoadingSubtitle = "Proximity Respawn Edition",
    ConfigurationSaving = { Enabled = true, FolderName = "TPLockConfig", FileName = "Settings" },
    KeySystem = false
})

local MainTab = Window:CreateTab("Auto Farm All", 4483362458)
local AutoFarmTab = Window:CreateTab("Auto Farm Selected", 4483362458)
local PriorityTab = Window:CreateTab("Priority Logic", 4483362458)
local SettingsTab = Window:CreateTab("Settings", 4483362458)
local KeybindsTab = Window:CreateTab("Keybinds", 4483362458) 

-- Forward Declarations for Toggles
local TPToggle, AutoFarmToggle, HybridToggle

--------------------------------------------------
-- Main Tab Components
--------------------------------------------------
local StatusLabel = MainTab:CreateLabel("Status: ENABLED")
local TargetLabel = MainTab:CreateLabel("Current Target: None")
local PriorityLabel = MainTab:CreateLabel("Priority: Low HP → High HP")

TPToggle = MainTab:CreateToggle({
    Name = "Enable TP Lock",
    CurrentValue = true,
    Flag = "TPLockEnabled",
    Callback = function(Value)
        if changingToggles then return end
        getgenv().TPToLowHP = Value
        if Value then
            changingToggles = true
            if AutoFarmToggle then AutoFarmToggle:Set(false) end
            if HybridToggle then HybridToggle:Set(false) end
            changingToggles = false
            
            autoFarmMode = false
            hybridMode = false
        else
            currentTarget = nil
        end
        StatusLabel:Set("Status: " .. (Value and "ENABLED" or "DISABLED"))
    end
})

local PriorityToggle = MainTab:CreateToggle({
    Name = "Target Sorting: High HP First",
    CurrentValue = false,
    Flag = "PriorityHighHP",
    Callback = function(Value)
        priorityHighToLow = Value
        PriorityLabel:Set(Value and "Priority: High HP → Low HP" or "Priority: Low HP → High HP")
        currentTarget = nil
    end
})

MainTab:CreateSlider({
    Name = "Lock Delay",
    Range = {0.001, 0.1},
    Increment = 0.001,
    CurrentValue = LOCK_DELAY,
    Suffix = "s",
    Flag = "LockDelayValue",
    Callback = function(Value) LOCK_DELAY = Value end
})

local ThresholdLabel = MainTab:CreateLabel("Current Threshold: " .. formatNumber(MAX_HP_THRESHOLD))
MainTab:CreateInput({
    Name = "Max HP Threshold (For Non-Selected)",
    PlaceholderText = "1QA / 500T / 5B",
    Flag = "HPThresholdValue",
    Callback = function(Text)
        local num = parseNumber(Text)
        if num then
            MAX_HP_THRESHOLD = num
            ThresholdLabel:Set("Current Threshold: " .. formatNumber(MAX_HP_THRESHOLD))
        end
    end
})

--------------------------------------------------
-- Auto Farm Tab Components
--------------------------------------------------
local AutoFarmStatusLabel = AutoFarmTab:CreateLabel("Auto Farm: DISABLED")
local SelectedCountLabel = AutoFarmTab:CreateLabel("Selected Enemies: 0")

local EnemyDropdown = AutoFarmTab:CreateDropdown({
    Name = "Select Enemies",
    Options = {},
    CurrentOption = {},
    MultipleOptions = true,
    Flag = "SelectedEnemiesList",
    Callback = function(Options)
        selectedEnemies = {}
        for _, displayName in ipairs(Options) do
            local realName = dropdownMap[displayName]
            if realName then selectedEnemies[realName] = true end
        end
        SelectedCountLabel:Set("Selected Enemies: " .. tostring(#Options))
    end
})

AutoFarmToggle = AutoFarmTab:CreateToggle({
    Name = "Enable Auto Farm (Selected ONLY)",
    CurrentValue = false,
    Flag = "AutoFarmEnabled",
    Callback = function(Value)
        if changingToggles then return end
        autoFarmMode = Value
        if Value then
            changingToggles = true
            if TPToggle then TPToggle:Set(false) end
            if HybridToggle then HybridToggle:Set(false) end
            changingToggles = false
            
            getgenv().TPToLowHP = false
            hybridMode = false
        else
            currentTarget = nil
        end
        AutoFarmStatusLabel:Set("Auto Farm: " .. (Value and "ENABLED" or "DISABLED"))
    end
})

AutoFarmTab:CreateButton({
    Name = "Refresh Enemy List",
    Callback = function()
        local enemies = getEnemies()
        local options = {}
        dropdownMap = {}
        local uniqueEnemies = {}

        for _, enemy in ipairs(enemies) do
            if not uniqueEnemies[enemy.name] then
                uniqueEnemies[enemy.name] = enemy.maxHealthValue
            end
        end

        local sorted = {}
        for name, hp in pairs(uniqueEnemies) do table.insert(sorted, {name = name, hp = hp}) end
        table.sort(sorted, function(a, b) return a.hp < b.hp end)

        for _, enemy in ipairs(sorted) do
            local display = string.format("(%s) %s", formatNumber(enemy.hp), enemy.name)
            table.insert(options, display)
            dropdownMap[display] = enemy.name
        end
        EnemyDropdown:Refresh(options)
    end
})

AutoFarmTab:CreateButton({
    Name = "Reset Selection",
    Callback = function()
        selectedEnemies = {}
        EnemyDropdown:Set({})
        SelectedCountLabel:Set("Selected Enemies: 0")
        currentTarget = nil
    end
})

--------------------------------------------------
-- Priority Logic Tab Components
--------------------------------------------------
local HybridStatusLabel = PriorityTab:CreateLabel("Hybrid Status: DISABLED")
PriorityTab:CreateLabel("Restricted Mode: Will only farm regular mobs near the boss spawn.")

HybridToggle = PriorityTab:CreateToggle({
    Name = "Enable Hybrid Priority Mode",
    CurrentValue = false,
    Flag = "HybridModeEnabled",
    Callback = function(Value)
        if changingToggles then return end
        hybridMode = Value
        if Value then
            changingToggles = true
            if TPToggle then TPToggle:Set(false) end
            if AutoFarmToggle then AutoFarmToggle:Set(false) end
            changingToggles = false
            
            getgenv().TPToLowHP = false
            autoFarmMode = false
        else
            currentTarget = nil
        end
        HybridStatusLabel:Set("Hybrid Status: " .. (Value and "ACTIVE" or "DISABLED"))
    end
})

PriorityTab:CreateButton({
    Name = "Set Current Position as Boss Camp",
    Callback = function()
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if root then
            bossCampPosition = root.Position
            Rayfield:Notify({
                Title = "Camp Initialized",
                Content = "Locked tracking onto your current area. Character will now stay here to trigger respawns!",
                Duration = 4
            })
        else
            Rayfield:Notify({
                Title = "Error",
                Content = "Character RootPart not found.",
                Duration = 3
            })
        end
    end
})

PriorityTab:CreateSlider({
    Name = "Allowed Farm Distance from Camp",
    Range = {50, 500},
    Increment = 10,
    CurrentValue = CAMP_RADIUS,
    Suffix = " studs",
    Flag = "CampRadiusSlider",
    Callback = function(Value) CAMP_RADIUS = Value end
})

--------------------------------------------------
-- Settings Configuration
--------------------------------------------------
SettingsTab:CreateSlider({
    Name = "Target Distance Offset (Y-Axis)",
    Range = {-50, 50},
    Increment = 1,
    CurrentValue = FARM_DISTANCE,
    Suffix = " studs",
    Flag = "FarmDistanceOffset",
    Callback = function(Value) FARM_DISTANCE = Value end
})

local NoclipToggle = SettingsTab:CreateToggle({
    Name = "Noclip",
    CurrentValue = false,
    Flag = "NoclipEnabled",
    Callback = function(Value)
        noclipEnabled = Value
        if Value then
            noclipConnection = RunService.Stepped:Connect(function()
                if player.Character then
                    for _, part in ipairs(player.Character:GetDescendants()) do
                        if part:IsA("BasePart") and part.CanCollide then
                            part.CanCollide = false
                        end
                    end
                end
            end)
        else
            if noclipConnection then
                noclipConnection:Disconnect()
                noclipConnection = nil
            end
        end
    end
})

SettingsTab:CreateButton({
    Name = "Unload Script",
    Callback = function()
        scriptRunning = false
        currentTarget = nil
        autoFarmMode = false
        hybridMode = false
        getgenv().TPToLowHP = false
        if noclipConnection then noclipConnection:Disconnect() end
        if safeZonePart then safeZonePart:Destroy() end
        Rayfield:Destroy()
    end
})

--------------------------------------------------
-- Keybinds Configuration Tab
--------------------------------------------------
KeybindsTab:CreateKeybind({
    Name = "Toggle TP Lock (Farm All)",
    CurrentKeybind = "B",
    HoldToInteract = false,
    Flag = "KB_TPLock",
    Callback = function() TPToggle:Set(not getgenv().TPToLowHP) end
})

KeybindsTab:CreateKeybind({
    Name = "Toggle Auto Farm (Selected)",
    CurrentKeybind = "V",
    HoldToInteract = false,
    Flag = "KB_AutoFarm",
    Callback = function() AutoFarmToggle:Set(not autoFarmMode) end
})

KeybindsTab:CreateKeybind({
    Name = "Toggle Hybrid Mode",
    CurrentKeybind = "C",
    HoldToInteract = false,
    Flag = "KB_HybridMode",
    Callback = function() HybridToggle:Set(not hybridMode) end
})

KeybindsTab:CreateKeybind({
    Name = "Toggle Noclip",
    CurrentKeybind = "N",
    HoldToInteract = false,
    Flag = "KB_Noclip",
    Callback = function() NoclipToggle:Set(not noclipEnabled) end
})

--------------------------------------------------
-- Core Target Logic
--------------------------------------------------
function getEnemies()
    local enemies = {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        local hum = obj:FindFirstChildOfClass("Humanoid")
        
        if hum and hum.Parent and hum.Parent ~= player.Character then
            local parentModel = hum.Parent
            
            -- Filter out DamageDummy (including DamageDummy1, DamageDummy2, etc.) and Players
            if not string.find(parentModel.Name, "DamageDummy") and not Players:GetPlayerFromCharacter(parentModel) then
                local hrp = parentModel:FindFirstChild("HumanoidRootPart")
                local torso = parentModel:FindFirstChild("Torso") or parentModel:FindFirstChild("UpperTorso")

                local containsQuestScript = false
                if torso then
                    for _, child in ipairs(torso:GetChildren()) do
                        if child:IsA("LuaSourceContainer") or child:IsA("Script") or child:IsA("LocalScript") or child:IsA("ModuleScript") then
                            containsQuestScript = true
                            break
                        end
                    end
                end

                if hrp and not containsQuestScript then
                    local currentHP = nil
                    local maxHP = nil
                    
                    local bossHealthObj = hum:FindFirstChild("BossHealth")
                    local maxHealthObj = hum:FindFirstChild("MaxHealth")

                    if bossHealthObj and bossHealthObj:IsA("NumberValue") then
                        currentHP = bossHealthObj.Value
                    else
                        currentHP = hum.Health
                    end

                    if maxHealthObj and maxHealthObj:IsA("NumberValue") then
                        maxHP = maxHealthObj.Value
                    else
                        if hum.MaxHealth ~= 100 then
                            maxHP = hum.MaxHealth
                        elseif hum.MaxHealth == 100 and parentModel.Name == "Slime" then
                            maxHP = 100
                        end
                    end

                    if currentHP and currentHP > 0 and maxHP then
                        table.insert(enemies, {
                            hrp = hrp,
                            humanoid = hum,
                            currentHealth = currentHP,
                            maxHealthValue = maxHP,
                            name = parentModel.Name
                        })
                    end
                end
            end
        end
    end
    return enemies
end

local function findTargetInList(enemies, onlySelected)
    local bestTarget = nil
    local bestHP = priorityHighToLow and -1 or math.huge

    for _, enemy in ipairs(enemies) do
        local valid = false
        if onlySelected then
            valid = (selectedEnemies[enemy.name] == true)
        else
            valid = (enemy.maxHealthValue < MAX_HP_THRESHOLD)
            
            -- Proximity Check: If in Hybrid Mode and we know where the boss spawns, 
            -- do NOT travel to regular mobs outside the Camp Radius.
            if valid and hybridMode and bossCampPosition then
                local distanceToCamp = (enemy.hrp.Position - bossCampPosition).Magnitude
                if distanceToCamp > CAMP_RADIUS then
                    valid = false
                end
            end
        end

        if valid then
            if priorityHighToLow then
                if enemy.maxHealthValue > bestHP then
                    bestHP = enemy.maxHealthValue
                    bestTarget = enemy
                end
            else
                if enemy.maxHealthValue < bestHP then
                    bestHP = enemy.maxHealthValue
                    bestTarget = enemy
                end
            end
        end
    end
    return bestTarget
end

local function findNewTarget()
    local enemies = getEnemies()
    
    if hybridMode then
        -- Try Priority Bosses first
        local prioTarget = findTargetInList(enemies, true)
        if prioTarget then return prioTarget end
        -- Fallback to local nearby mobs
        return findTargetInList(enemies, false)
    elseif autoFarmMode then
        return findTargetInList(enemies, true)
    elseif getgenv().TPToLowHP then
        return findTargetInList(enemies, false)
    end
    
    return nil
end

local function isValidTarget(enemy)
    if not enemy or not enemy.hrp or not enemy.hrp.Parent then return false end
    
    -- Final safety check to make absolutely sure no DamageDummy slips through
    if string.find(enemy.name, "DamageDummy") then return false end
    
    local liveHealth = enemy.humanoid.Health
    local bossHealthObj = enemy.humanoid:FindFirstChild("BossHealth")
    if bossHealthObj and bossHealthObj:IsA("NumberValue") then
        liveHealth = bossHealthObj.Value
    end
    
    if liveHealth <= 0 then return false end
    
    if hybridMode then
        if selectedEnemies[enemy.name] then return true end
        
        -- Fallback verification must respect the camp zone distance boundaries
        if enemy.maxHealthValue >= MAX_HP_THRESHOLD then return false end
        if bossCampPosition then
            return (enemy.hrp.Position - bossCampPosition).Magnitude <= CAMP_RADIUS
        end
        return true
    elseif autoFarmMode then
        return selectedEnemies[enemy.name] == true
    else
        return enemy.maxHealthValue < MAX_HP_THRESHOLD
    end
end

--------------------------------------------------
-- Main Loop Execution Thread
--------------------------------------------------
local lastPriorityCheck = 0

task.spawn(function()
    while scriptRunning do
        local farmingActive = getgenv().TPToLowHP or autoFarmMode or hybridMode
        if farmingActive then
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")

            if root and humanoid then
                
                -- Priority Overlap Check: If Hybrid Mode is ON, and we are currently fighting a fallback enemy,
                -- Check every 0.5 seconds if a Priority (Selected) enemy has respawned.
                if hybridMode and currentTarget and not selectedEnemies[currentTarget.name] then
                    if tick() - lastPriorityCheck > 0.5 then
                        lastPriorityCheck = tick()
                        local prioTarget = findTargetInList(getEnemies(), true)
                        if prioTarget then
                            currentTarget = prioTarget -- Instantly switch
                        end
                    end
                end

                if currentTarget and not isValidTarget(currentTarget) then
                    currentTarget = nil
                end

                if not currentTarget then
                    currentTarget = findNewTarget()
                end

                if currentTarget then
                    -- Auto-save camp location when actively fighting a boss target
                    if selectedEnemies[currentTarget.name] then
                        bossCampPosition = currentTarget.hrp.Position
                    end

                    local enemyCFrame = currentTarget.hrp.CFrame
                    local enemyPos = enemyCFrame.Position
                    
                    local _, _, _, R00, R01, R02, R10, R11, R12, R20, R21, R22 = enemyCFrame:GetComponents()
                    
                    humanoid:ChangeState(Enum.HumanoidStateType.Physics)
                    root.Velocity = Vector3.new(0, 0, 0)
                    root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                    
                    root.CFrame = CFrame.new(
                        enemyPos.X, 
                        enemyPos.Y + FARM_DISTANCE, 
                        enemyPos.Z, 
                        R00, R01, R02, R10, R11, R12, R20, R21, R22
                    )
                    
                    local liveHealth = currentTarget.humanoid.Health
                    local bossHealthObj = currentTarget.humanoid:FindFirstChild("BossHealth")
                    if bossHealthObj and bossHealthObj:IsA("NumberValue") then
                        liveHealth = bossHealthObj.Value
                    end
                    currentTarget.currentHealth = liveHealth

                    local statusPrefix = (selectedEnemies[currentTarget.name]) and "[BOSS]" or "Target:"
                    
                    TargetLabel:Set(string.format(
                        "%s %s | HP: %s/%s",
                        statusPrefix,
                        currentTarget.name,
                        formatNumber(currentTarget.currentHealth),
                        formatNumber(currentTarget.maxHealthValue)
                    ))
                    
                    task.wait(LOCK_DELAY)
                else
                    -- No targets matched. Choose waiting location based on streaming prevention rules.
                    if hybridMode and bossCampPosition then
                        TargetLabel:Set("Farming Idle: Camping Boss Spawn Zone")
                        
                        humanoid:ChangeState(Enum.HumanoidStateType.Physics)
                        root.Velocity = Vector3.new(0, 0, 0)
                        root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                        root.CFrame = CFrame.new(bossCampPosition + Vector3.new(0, FARM_DISTANCE, 0))
                        
                        task.wait(0.001)
                    else
                        TargetLabel:Set("Current Target: Searching (Safe Zone)")
                        
                        local zone = getOrCreateSafeZone()
                        humanoid:ChangeState(Enum.HumanoidStateType.Physics)
                        root.Velocity = Vector3.new(0, 0, 0)
                        root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                        root.CFrame = CFrame.new(zone.Position + Vector3.new(0, 10, 0))
                        
                        task.wait(0.001)
                    end
                end
            else
                task.wait(0.01)
            end
        else
            currentTarget = nil
            task.wait(0.001)
        end
    end
end)

--------------------------------------------------
-- Automatic Configuration Loading
--------------------------------------------------
Rayfield:LoadConfiguration()
print("TP Lock Script Loaded and Configurations Synced")    
