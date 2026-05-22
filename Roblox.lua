-- TP Lock Script (Global Vector Position + Rotation Alignment Patch)
-- Features: Safe Zone System, Noclip, Keybind Manager Tab, and Fixed CFrame Matrix

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

getgenv().TPToLowHP = true

local LOCK_DELAY = 0.015
local MAX_HP_THRESHOLD = 150e18
local FARM_DISTANCE = -40 -- Default positioning value

local currentTarget = nil
local scriptRunning = true
local autoFarmMode = false
local priorityHighToLow = true -- false = Low→High, true = High→Low

local selectedEnemies = {}
local dropdownMap = {}

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

-- Initialize Safe Zone on load
getOrCreateSafeZone()

--------------------------------------------------
-- Noclip Variables
--------------------------------------------------
local noclipEnabled = true
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
    if num < 1000 then
        return tostring(math.floor(num))
    end

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
-- UI Initialization (Rayfield Auto-Save Active)
--------------------------------------------------

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "TP Lock Script",
    LoadingTitle = "Lock-on System",
    LoadingSubtitle = "Optimized Edition",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "TPLockConfig",
        FileName = "Settings"
    },
    KeySystem = false
})

local MainTab = Window:CreateTab("Auto Farm All", 4483362458)
local AutoFarmTab = Window:CreateTab("Auto Farm Selected", 4483362458)
local SettingsTab = Window:CreateTab("Settings", 4483362458)
local KeybindsTab = Window:CreateTab("Keybinds", 4483362458) 

--------------------------------------------------
-- Main Tab Components
--------------------------------------------------

local StatusLabel = MainTab:CreateLabel("Status: ENABLED")
local TargetLabel = MainTab:CreateLabel("Current Target: None")
local PriorityLabel = MainTab:CreateLabel("Priority: Low HP → High HP")

local TPToggle = MainTab:CreateToggle({
    Name = "Enable TP Lock",
    CurrentValue = true,
    Flag = "TPLockEnabled",
    Callback = function(Value)
        getgenv().TPToLowHP = Value
        if Value then
            autoFarmMode = false
        else
            currentTarget = nil
        end
        StatusLabel:Set("Status: " .. (Value and "ENABLED" or "DISABLED"))
    end
})

local PriorityToggle = MainTab:CreateToggle({
    Name = "Priority: High HP First",
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
    Callback = function(Value)
        LOCK_DELAY = Value
    end
})

local ThresholdLabel = MainTab:CreateLabel("Current Threshold: " .. formatNumber(MAX_HP_THRESHOLD))

MainTab:CreateInput({
    Name = "Max HP Threshold",
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
            if realName then
                selectedEnemies[realName] = true
            end
        end
        SelectedCountLabel:Set("Selected Enemies: " .. tostring(#Options))
    end
})

local AutoFarmToggle = AutoFarmTab:CreateToggle({
    Name = "Enable Auto Farm",
    CurrentValue = false,
    Flag = "AutoFarmEnabled",
    Callback = function(Value)
        autoFarmMode = Value
        if Value then
            getgenv().TPToLowHP = false
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
        for name, hp in pairs(uniqueEnemies) do
            table.insert(sorted, {name = name, hp = hp})
        end

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
-- Settings Configuration
--------------------------------------------------

SettingsTab:CreateSlider({
    Name = "Target Distance Offset (Y-Axis)",
    Range = {-50, 50},
    Increment = 1,
    CurrentValue = FARM_DISTANCE,
    Suffix = " studs",
    Flag = "FarmDistanceOffset",
    Callback = function(Value)
        FARM_DISTANCE = Value
    end
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
        getgenv().TPToLowHP = false
        setCharacterHidden(false)
        if noclipConnection then noclipConnection:Disconnect() end
        if safeZonePart then safeZonePart:Destroy() end -- Destroy Safe Zone
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
    Callback = function()
        TPToggle:Set(not getgenv().TPToLowHP)
    end
})

KeybindsTab:CreateKeybind({
    Name = "Toggle Auto Farm (Selected)",
    CurrentKeybind = "V",
    HoldToInteract = false,
    Flag = "KB_AutoFarm",
    Callback = function()
        AutoFarmToggle:Set(not autoFarmMode)
    end
})

KeybindsTab:CreateKeybind({
    Name = "Toggle Target Priority",
    CurrentKeybind = "H",
    HoldToInteract = false,
    Flag = "KB_Priority",
    Callback = function()
        PriorityToggle:Set(not priorityHighToLow)
    end
})

KeybindsTab:CreateKeybind({
    Name = "Toggle Noclip",
    CurrentKeybind = "N",
    HoldToInteract = false,
    Flag = "KB_Noclip",
    Callback = function()
        NoclipToggle:Set(not noclipEnabled)
    end
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
            
            -- Ignore other players in the server
            if not Players:GetPlayerFromCharacter(parentModel) then
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

                    -- Resolve Current HP
                    if bossHealthObj and bossHealthObj:IsA("NumberValue") then
                        currentHP = bossHealthObj.Value
                    else
                        currentHP = hum.Health
                    end

                    -- Resolve Max HP according to new rules
                    if maxHealthObj and maxHealthObj:IsA("NumberValue") then
                        maxHP = maxHealthObj.Value
                    else
                        if hum.MaxHealth ~= 100 then
                            maxHP = hum.MaxHealth
                        elseif hum.MaxHealth == 100 and parentModel.Name == "Slime" then
                            maxHP = 100
                        end
                    end

                    -- Only add if they are valid AND have more than 0 HP
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

local function isValidTarget(enemy)
    if not enemy or not enemy.hrp or not enemy.hrp.Parent then return false end
    
    -- Check the live health dynamically so we don't stay locked onto corpses
    local liveHealth = enemy.humanoid.Health
    local bossHealthObj = enemy.humanoid:FindFirstChild("BossHealth")
    if bossHealthObj and bossHealthObj:IsA("NumberValue") then
        liveHealth = bossHealthObj.Value
    end
    
    if liveHealth <= 0 then return false end
    if autoFarmMode then return selectedEnemies[enemy.name] == true end
    
    return enemy.maxHealthValue < MAX_HP_THRESHOLD
end

local function isValidTarget(enemy)
    if not enemy or not enemy.hrp or not enemy.hrp.Parent then return false end
    if enemy.currentHealth <= 0 then return false end
    if autoFarmMode then return selectedEnemies[enemy.name] == true end
    return enemy.maxHealthValue < MAX_HP_THRESHOLD
end

local function findNewTarget()
    local enemies = getEnemies()
    local bestTarget = nil

    if priorityHighToLow then
        local highestHP = -1
        for _, enemy in ipairs(enemies) do
            if isValidTarget(enemy) and enemy.maxHealthValue > highestHP then
                highestHP = enemy.maxHealthValue
                bestTarget = enemy
            end
        end
    else
        local lowestHP = math.huge
        for _, enemy in ipairs(enemies) do
            if isValidTarget(enemy) and enemy.maxHealthValue < lowestHP then
                lowestHP = enemy.maxHealthValue
                bestTarget = enemy
            end
        end
    end
    return bestTarget
end

--------------------------------------------------
-- Main Loop Execution Thread
--------------------------------------------------

task.spawn(function()
    while scriptRunning do
        local farmingActive = getgenv().TPToLowHP or autoFarmMode
        if farmingActive then
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")

            if root and humanoid then
                -- 1. If target is dead or invalid, clear it immediately
                if currentTarget and not isValidTarget(currentTarget) then
                    currentTarget = nil
                end

                -- 2. If we don't have a target, find one instantly
                if not currentTarget then
                    currentTarget = findNewTarget()
                end

                -- 3. If we now have a target, teleport and lock on
                if currentTarget then
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
                    
                    -- Update UI health dynamically without scanning the whole workspace
                    local liveHealth = currentTarget.humanoid.Health
                    local bossHealthObj = currentTarget.humanoid:FindFirstChild("BossHealth")
                    if bossHealthObj and bossHealthObj:IsA("NumberValue") then
                        liveHealth = bossHealthObj.Value
                    end
                    currentTarget.currentHealth = liveHealth

                    TargetLabel:Set(string.format(
                        "Target: %s | HP: %s/%s",
                        currentTarget.name,
                        formatNumber(currentTarget.currentHealth),
                        formatNumber(currentTarget.maxHealthValue)
                    ))
                    
                    task.wait(LOCK_DELAY)
                else
                    -- 4. Safe zone fallback (ONLY triggers if there are exactly 0 alive enemies on the map)
                    TargetLabel:Set("Current Target: Searching (Safe Zone)")
                    
                    local zone = getOrCreateSafeZone()
                    humanoid:ChangeState(Enum.HumanoidStateType.Physics)
                    root.Velocity = Vector3.new(0, 0, 0)
                    root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                    
                    -- Teleport player constantly slightly above the platform
                    root.CFrame = CFrame.new(zone.Position + Vector3.new(0, 10, 0))
                    
                    task.wait(0.05)
                end
            else
                task.wait(1)
            end
        else
            currentTarget = nil
            task.wait(0.25)
        end
    end
end)

--------------------------------------------------
-- Automatic Configuration Loading
--------------------------------------------------
Rayfield:LoadConfiguration()
print("TP Lock Script Loaded and Configurations Synced")