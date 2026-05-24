-- TP Lock Script (Global Vector Position + Rotation Alignment Patch)
-- Features: RS Global Scanning, Complete Modifier Filter, Strict Cooldowns, Auto Bosses, Anti-GameplayPaused, Blacklist, Custom Config, Anti-AFK, Auto-Rejoin

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer

getgenv().TPToLowHP = true
getgenv().CurrentMoon = nil -- Initializing to nil forces the UI to update instantly on execution

local LOCK_DELAY = 0.001
local MAX_HP_THRESHOLD = 150e21
local FARM_DISTANCE = -40 

local currentTarget = nil
local scriptRunning = true

--------------------------------------------------
-- UNIVERSAL CHAT CAPTURE SYSTEM
--------------------------------------------------
local lastChatMessage = "No spawn notification message captured."

-- Legacy Chat Hook
task.spawn(function()
    local chatEvents = ReplicatedStorage:WaitForChild("DefaultChatSystemChatEvents", 5)
    if chatEvents then
        local onMsg = chatEvents:WaitForChild("OnMessageDoneFiltering", 5)
        if onMsg and onMsg:IsA("RemoteEvent") then
            onMsg.OnClientEvent:Connect(function(messageData)
                if messageData and messageData.Message then
                    lastChatMessage = tostring(messageData.Message)
                end
            end)
        end
    end
end)

-- Modern TextChatService Hook
pcall(function()
    local TextChatService = game:GetService("TextChatService")
    if TextChatService then
        TextChatService.MessageReceived:Connect(function(message)
            if message and message.Text then
                lastChatMessage = message.Text
            end
        end)
    end
end)

--------------------------------------------------
-- FIXED MOON STATE SCANNER
--------------------------------------------------
local lastDispatchedColorKey = ""

-- Central Database of Known Moons with Tolerance Anchors
local KNOWN_MOONS = {
    {r = 50,  g = 255, b = 50,  name = "Mega Double Moon (Friend Boost 10x)"},
    {r = 180, g = 80,  b = 255, name = "Enchanted Moon (Moon Essence Drops Are Doubled)"},
    {r = 57,  g = 255, b = 20,  name = "Lucky Moon (Passive drops buffed 2.5x)"},
    {r = 255, g = 50,  b = 50,  name = "Blood Moon (Bosses respawn 5x  faster!)"},
    {r = 255, g = 100, b = 0,   name = "Chaos Moon (2x Enemy modifier chance)"},
    {r = 254, g = 122, b = 44, name = "Eclipse Moon (Bosses Respawn 5x Faster and 2x modifier chance)"},
    {r = 199, g = 199, b = 199, name = "Daytime (No Buffs)"}
}

local function getMoonState()
    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
    if not atmosphere then return "Normal Moon" end
    
    local c = atmosphere.Color
    local r = math.clamp(math.floor(c.R * 255 + 0.5), 0, 255)
    local g = math.clamp(math.floor(c.G * 255 + 0.5), 0, 255)
    local b = math.clamp(math.floor(c.B * 255 + 0.5), 0, 255)
    
    -- First, pass through your known database checking with tolerance rules (+/- 5 points)
    for _, moon in ipairs(KNOWN_MOONS) do
        if math.abs(r - moon.r) <= 5 and math.abs(g - moon.g) <= 5 and math.abs(b - moon.b) <= 5 then
            return moon.name
        end
    end

    -- Treat standard game white rendering as normal baseline behavior without warning hooks
    if math.abs(r - 255) <= 5 and math.abs(g - 255) <= 5 and math.abs(b - 255) <= 5 then
        return "Normal Moon"
    end

    -- If it gets here, it's an unmapped atmosphere layout. 
    local uniqueKey = string.format("%d,%d,%d", r, g, b)
    if lastDispatchedColorKey ~= uniqueKey then
        lastDispatchedColorKey = uniqueKey
        task.spawn(function()
            task.wait(0.4) -- Delayed execution buffer for Roblox chat engine thread synchronization
            sendMoonWebhook(r, g, b, lastChatMessage)
        end)
    end

    return string.format("Unknown Moon (%d, %d, %d)", r, g, b)
end

--------------------------------------------------
-- ANTI-AFK SYSTEM
--------------------------------------------------
player.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

--------------------------------------------------
-- BLACKLIST SYSTEM (Add enemies to ignore here)
--------------------------------------------------
local BLACKLIST = {
    ["Golem"] = true,
}

--------------------------------------------------
-- GameplayPaused Remover System
--------------------------------------------------
local function removeGameplayPaused()
    pcall(function()
        if player.GameplayPaused then
            if sethiddenproperty then
                sethiddenproperty(player, "GameplayPaused", false)
            else
                player.GameplayPaused = false
            end
        end
    end)
end

player:GetPropertyChangedSignal("GameplayPaused"):Connect(removeGameplayPaused)

task.spawn(function()
    while scriptRunning do
        removeGameplayPaused()
        pcall(function()
            local robloxGui = CoreGui:FindFirstChild("RobloxGui")
            if robloxGui and robloxGui:FindFirstChild("PromptOverlay") then
                for _, child in ipairs(robloxGui.PromptOverlay:GetChildren()) do
                    if child.Name == "ErrorPrompt" then
                        local msgArea = child:FindFirstChild("MessageArea")
                        local errFrame = msgArea and msgArea:FindFirstChild("ErrorFrame")
                        local errMsg = errFrame and errFrame:FindFirstChild("ErrorMessage")
                        if errMsg and string.find(string.lower(errMsg.Text), "gameplay paused") then
                            child.Visible = false
                        end
                    end
                end
            end
        end)
        task.wait(0.05)
    end
end)

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
-- MODIFIER FILTER SYSTEM
--------------------------------------------------
local INLINE_MODIFIERS = {
    "Transcendental", "Sanguine", "Godlike", "Ethereal", "Spectral", 
    "Electric", "Infernal", "Inverted", "Colossal", "Abyssal", 
    "Rainbow", "Glacial", "Golden", "Solar", "Lunar", "Small", 
    "Huge", "Big"
}

local function getBaseName(model)
    local originalName = model.Name
    local newName = originalName
    local modifierObj = model:FindFirstChild("AppliedModifiers")
    
    if modifierObj then
        local rawValue = ""
        pcall(function() rawValue = tostring(modifierObj.Value) end)
        
        if rawValue and rawValue ~= "" and rawValue ~= "nil" then
            local cleanValue = string.gsub(rawValue, ",", " ")
            for modWord in string.gmatch(cleanValue, "%S+") do
                local safeMod = modWord:gsub("[%-%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
                newName = string.gsub(newName, safeMod, "")
            end
        end
    end

    for _, modWord in ipairs(INLINE_MODIFIERS) do
        local safeMod = modWord:gsub("[%-%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
        newName = string.gsub(newName, safeMod, "")
    end
    
    newName = string.gsub(newName, "%s+", " ")
    newName = string.match(newName, "^%s*(.-)%s*$") or newName
    
    if newName == "" then return originalName end
    return newName
end

--------------------------------------------------
-- RS Global Scanning
--------------------------------------------------
local function getBossesFromRS()
    local uniqueBosses = {}
    local bossesFolder = ReplicatedStorage:FindFirstChild("Bosses")
    if bossesFolder then
        for _, bossModel in ipairs(bossesFolder:GetChildren()) do
            if BLACKLIST[bossModel.Name] then continue end 
            local hum = bossModel:FindFirstChildOfClass("Humanoid")
            if hum then
                local maxHP = hum.MaxHealth
                local maxHealthObj = hum:FindFirstChild("MaxHealth")
                if maxHealthObj and maxHealthObj:IsA("NumberValue") then
                    maxHP = maxHealthObj.Value
                end
                uniqueBosses[bossModel.Name] = maxHP
            else
                uniqueBosses[bossModel.Name] = 10000 
            end
        end
    end
    return uniqueBosses
end

local function getAllEnemiesFromRS()
    local uniqueEnemies = {}
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("Model") and obj:FindFirstChildOfClass("Humanoid") then
            if BLACKLIST[obj.Name] then continue end 
            local baseName = getBaseName(obj)
            if not string.find(obj.Name, "DamageDummy") then
                local hum = obj:FindFirstChildOfClass("Humanoid")
                local maxHP = hum.MaxHealth
                local maxHealthObj = hum:FindFirstChild("MaxHealth")
                
                if maxHealthObj and maxHealthObj:IsA("NumberValue") then
                    maxHP = maxHealthObj.Value
                elseif hum.MaxHealth == 100 and obj.Name == "Slime" then
                    maxHP = 100
                end
                
                if maxHP and maxHP > 0 then
                    if not uniqueEnemies[baseName] or maxHP > uniqueEnemies[baseName] then
                        uniqueEnemies[baseName] = maxHP
                    end
                end
            end
        end
    end
    return uniqueEnemies
end

--------------------------------------------------
-- Workspace Target Acquisition
--------------------------------------------------
local allKnownBosses = {} 
local selectedEnemies = {}
local selectedBosses = {}
local autoFarmMode = false

function getEnemies()
    local enemies = {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        local hum = obj:FindFirstChildOfClass("Humanoid")
        
        if hum and hum.Parent and hum.Parent ~= player.Character then
            local parentModel = hum.Parent
            if hum:GetState() == Enum.HumanoidStateType.Dead or hum.Health <= 0 then continue end
            
            local baseEnemyName = getBaseName(parentModel)
            if BLACKLIST[parentModel.Name] or BLACKLIST[baseEnemyName] then continue end 

            local isTargetable = true
            if allKnownBosses[parentModel.Name] or allKnownBosses[baseEnemyName] then
                if not (getgenv().isBossFarmingActive and (getgenv().activeBossTarget == parentModel.Name or getgenv().activeBossTarget == baseEnemyName)) then
                    if autoFarmMode and (selectedEnemies[parentModel.Name] or selectedEnemies[baseEnemyName]) then
                        isTargetable = true
                    else
                        isTargetable = false
                    end
                end
            end

            if isTargetable and not string.find(parentModel.Name, "DamageDummy") and not Players:GetPlayerFromCharacter(parentModel) then
                local hrp = parentModel:FindFirstChild("HumanoidRootPart")
                local torso = parentModel:FindFirstChild("Torso") or parentModel:FindFirstChild("UpperTorso")

                local containsQuestScript = false
                if torso then
                    for _, child in ipairs(torso:GetChildren()) do
                        if child:IsA("LuaSourceContainer") or child:IsA("Script") or child:IsA("LocalScript") or child:IsA("ModuleScript") then
                            containsQuestScript = true; break
                        end
                    end
                end

                if hrp and not containsQuestScript then
                    local currentHP, maxHP = nil, nil
                    local bossHealthObj = hum:FindFirstChild("BossHealth")
                    local maxHealthObj = hum:FindFirstChild("MaxHealth")

                    if bossHealthObj and bossHealthObj:IsA("NumberValue") then currentHP = bossHealthObj.Value else currentHP = hum.Health end
                    
                    if maxHealthObj and maxHealthObj:IsA("NumberValue") then 
                        maxHP = maxHealthObj.Value 
                    else 
                        if hum.MaxHealth ~= 100 then 
                            maxHP = hum.MaxHealth 
                        elseif hum.MaxHealth == 100 and baseEnemyName == "Slime" then 
                            maxHP = 100 
                        end
                    end

                    if currentHP and currentHP > 0 and maxHP then
                        table.insert(enemies, {
                            hrp = hrp,
                            humanoid = hum,
                            currentHealth = currentHP,
                            maxHealthValue = maxHP,
                            name = baseEnemyName, 
                            realName = parentModel.Name 
                        })
                    end
                end
            end
        end
    end
    return enemies
end

--------------------------------------------------
-- Pre-Initialization Element Scanners (Fixes Render Crash)
--------------------------------------------------
local dropdownMap = {}
local bossDropdownMap = {}
local bossCooldownLabels = {} 

local uniqueBossData = getBossesFromRS()
local sortedBosses = {}
for name, hp in pairs(uniqueBossData) do 
    table.insert(sortedBosses, {name = name, hp = hp}) 
    allKnownBosses[name] = true
end
table.sort(sortedBosses, function(a, b) return a.hp < b.hp end)

local initialBossOptions = {}
for _, boss in ipairs(sortedBosses) do
    local display = string.format("(%s) %s", formatNumber(boss.hp), boss.name)
    table.insert(initialBossOptions, display)
    bossDropdownMap[display] = boss.name
end
if #initialBossOptions == 0 then table.insert(initialBossOptions, "No Bosses Found") end

local uniqueEnemies = getAllEnemiesFromRS()
local sortedEnemies = {}
for name, hp in pairs(uniqueEnemies) do table.insert(sortedEnemies, {name = name, hp = hp}) end
table.sort(sortedEnemies, function(a, b) return a.hp < b.hp end)

local initialEnemyOptions = {}
for _, enemy in ipairs(sortedEnemies) do
    local display = string.format("(%s) %s", formatNumber(enemy.hp), enemy.name)
    table.insert(initialEnemyOptions, display)
    dropdownMap[display] = enemy.name
end
if #initialEnemyOptions == 0 then table.insert(initialEnemyOptions, "No Enemies Found") end

--------------------------------------------------
-- Global Core Flags
--------------------------------------------------
local priorityHighToLow = true 
local autoEquipEnabled = false
local selectedWeapon = nil
local autoBossMode = false

getgenv().isBossFarmingActive = false
getgenv().activeBossTarget = nil

local bossCooldowns = {} 
local bossWasFound = false
local bossWaitTimeout = 0
local remoteFired = false 
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
        safeZonePart.Position = Vector3.new(0, 100000, 0)
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
-- Helper Functions for Remotes & Workspace
--------------------------------------------------
local function fireStartBossRemote(bossName)
    local remotes = {"StartAutofarm"}
    for _, rName in ipairs(remotes) do
        local remote = ReplicatedStorage:FindFirstChild(rName)
        if remote and remote:IsA("RemoteEvent") then
            remote:FireServer(bossName)
            break
        end
    end
end

local function fireStopBossRemote()
    local remotes = {"StopAutoFarm"}
    for _, rName in ipairs(remotes) do
        local remote = ReplicatedStorage:FindFirstChild(rName)
        if remote and remote:IsA("RemoteEvent") then
            remote:FireServer()
        end
    end
end

local function findBossInWorkspace(bossName)
    local wsBosses = workspace:FindFirstChild("Bosses")
    local containers = wsBosses and {wsBosses, workspace} or {workspace}
    for _, container in ipairs(containers) do
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then
                if child.Name == bossName or getBaseName(child) == bossName then
                    return child
                end
            end
        end
    end
    return nil
end

--------------------------------------------------
-- UI Instantiation Declarations
--------------------------------------------------
local AutoEquipToggle, WeaponDropdown, AutoEquipStatusLabel
local CurrentMoonLabel 
local TPToggle, PriorityToggle, LockDelaySlider, HPThresholdInput, StatusLabel, TargetLabel, PriorityLabel, ThresholdLabel
local AutoFarmToggle, EnemyDropdown, AutoFarmStatusLabel, SelectedCountLabel
local AutoBossToggle, BossDropdown, BossCooldownLabel, SelectedBossesCountLabel
local DistanceSlider, NoclipToggle, configListDropdown, autoLoadLabel

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "TP Lock Script",
    LoadingTitle = "Lock-on System",
    LoadingSubtitle = "RS Global Scanner Edition",
    ConfigurationSaving = { Enabled = false }, 
    KeySystem = false
})

local AutoEquipTab = Window:CreateTab("Auto Equip", 4483362458)
local MainTab = Window:CreateTab("Auto Farm All", 4483362458)
local AutoFarmTab = Window:CreateTab("Auto Farm Selected", 4483362458)
local AutoBossTab = Window:CreateTab("Auto Bosses", 4483362458)
local SettingsTab = Window:CreateTab("Settings", 4483362458)
local ConfigTab = Window:CreateTab("Config", 4483362458)
local KeybindsTab = Window:CreateTab("Keybinds", 4483362458) 

--------------------------------------------------
-- Auto Equip Tab Setup
--------------------------------------------------
CurrentMoonLabel = AutoEquipTab:CreateLabel("Current Moon: Scanning...")
AutoEquipStatusLabel = AutoEquipTab:CreateLabel("Auto Equip: DISABLED")
WeaponDropdown = AutoEquipTab:CreateDropdown({
    Name = "Select Weapon", Options = {"Scanning..."}, CurrentOption = {"Scanning..."}, MultipleOptions = false, Flag = "AutoEquipSelectedWeapon",
    Callback = function(Option) if Option and Option[1] then selectedWeapon = Option[1] else selectedWeapon = nil end end
})

local function RefreshWeapons()
    local options = {}
    local uniqueWeapons = {}
    if player.Backpack then
        for _, item in ipairs(player.Backpack:GetChildren()) do
            if item:IsA("Tool") and not uniqueWeapons[item.Name] then uniqueWeapons[item.Name] = true; table.insert(options, item.Name) end
        end
    end
    if player.Character then
        for _, item in ipairs(player.Character:GetChildren()) do
            if item:IsA("Tool") and not uniqueWeapons[item.Name] then uniqueWeapons[item.Name] = true; table.insert(options, item.Name) end
        end
    end
    if #options == 0 then table.insert(options, "No Weapons Found") end
    pcall(function() WeaponDropdown:Refresh(options) end)
end

AutoEquipTab:CreateButton({ Name = "Refresh Weapons", Callback = RefreshWeapons })
AutoEquipToggle = AutoEquipTab:CreateToggle({
    Name = "Enable Auto Equip", CurrentValue = false, Flag = "AutoEquipEnabled",
    Callback = function(Value) autoEquipEnabled = Value; pcall(function() AutoEquipStatusLabel:Set("Auto Equip: " .. (Value and "ENABLED" or "DISABLED")) end) end
})

--------------------------------------------------
-- Main Tab Setup
--------------------------------------------------
StatusLabel = MainTab:CreateLabel("Status: ENABLED")
TargetLabel = MainTab:CreateLabel("Current Target: None")
PriorityLabel = MainTab:CreateLabel("Priority: High HP → Low HP")

TPToggle = MainTab:CreateToggle({
    Name = "Enable TP Lock", CurrentValue = true, Flag = "TPLockEnabled",
    Callback = function(Value)
        if changingToggles then return end
        getgenv().TPToLowHP = Value
        if Value then
            changingToggles = true
            if AutoFarmToggle then pcall(function() AutoFarmToggle:Set(false) end) end
            changingToggles = false
            autoFarmMode = false
        else
            currentTarget = nil
        end
        pcall(function() StatusLabel:Set("Status: " .. (Value and "ENABLED" or "DISABLED")) end)
    end
})

PriorityToggle = MainTab:CreateToggle({
    Name = "Target Sorting: High HP First", CurrentValue = priorityHighToLow, Flag = "PriorityHighHP",
    Callback = function(Value)
        priorityHighToLow = Value
        pcall(function() PriorityLabel:Set(Value and "Priority: High HP → Low HP" or "Priority: Low HP → High HP") end)
        currentTarget = nil
    end
})

LockDelaySlider = MainTab:CreateSlider({
    Name = "Lock Delay", Range = {0.001, 0.1}, Increment = 0.001, CurrentValue = LOCK_DELAY, Suffix = "s", Flag = "LockDelayValue", 
    Callback = function(Value) LOCK_DELAY = Value end
})

ThresholdLabel = MainTab:CreateLabel("Current Threshold: " .. formatNumber(MAX_HP_THRESHOLD))
HPThresholdInput = MainTab:CreateInput({
    Name = "Max HP Threshold (For Non-Selected)", PlaceholderText = "1QA / 500T / 5B", Flag = "HPThresholdValue",
    Callback = function(Text)
        local num = parseNumber(Text)
        if num then MAX_HP_THRESHOLD = num; pcall(function() ThresholdLabel:Set("Current Threshold: " .. formatNumber(MAX_HP_THRESHOLD)) end) end
    end
})

--------------------------------------------------
-- Auto Farm Selected Tab Setup
--------------------------------------------------
AutoFarmStatusLabel = AutoFarmTab:CreateLabel("Auto Farm: DISABLED")
SelectedCountLabel = AutoFarmTab:CreateLabel("Selected Enemies: 0")

EnemyDropdown = AutoFarmTab:CreateDropdown({
    Name = "Select Enemies & Bosses", Options = initialEnemyOptions, CurrentOption = {}, MultipleOptions = true, Flag = "SelectedEnemiesList",
    Callback = function(Options)
        selectedEnemies = {}
        for _, displayName in ipairs(Options) do
            local realName = dropdownMap[displayName]
            if realName then selectedEnemies[realName] = true end
        end
        pcall(function() SelectedCountLabel:Set("Selected Enemies: " .. tostring(#Options)) end)
    end
})

AutoFarmToggle = AutoFarmTab:CreateToggle({
    Name = "Enable Auto Farm Selected", CurrentValue = false, Flag = "AutoFarmSelectedEnabled",
    Callback = function(Value)
        if changingToggles then return end
        autoFarmMode = Value
        if Value then
            changingToggles = true
            if TPToggle then pcall(function() TPToggle:Set(false) end) end
            changingToggles = false
            getgenv().TPToLowHP = false
        else
            currentTarget = nil
        end
        pcall(function() AutoFarmStatusLabel:Set("Auto Farm: " .. (Value and "ENABLED" or "DISABLED")) end)
    end
})

local function RefreshEnemyDropdown()
    local uniqueEnemiesList = getAllEnemiesFromRS()
    for _, enemy in ipairs(getEnemies()) do
        if not uniqueEnemiesList[enemy.name] then uniqueEnemiesList[enemy.name] = enemy.maxHealthValue end
    end
    local sorted = {}
    for name, hp in pairs(uniqueEnemiesList) do table.insert(sorted, {name = name, hp = hp}) end
    table.sort(sorted, function(a, b) return a.hp < b.hp end)
    local options = {}
    dropdownMap = {}
    for _, enemy in ipairs(sorted) do
        local display = string.format("(%s) %s", formatNumber(enemy.hp), enemy.name)
        table.insert(options, display)
        dropdownMap[display] = enemy.name
    end
    if #options == 0 then table.insert(options, "No Enemies Found") end
    pcall(function() EnemyDropdown:Refresh(options) end)
end

AutoFarmTab:CreateButton({ Name = "Refresh Enemy List", Callback = RefreshEnemyDropdown })
AutoFarmTab:CreateButton({
    Name = "Reset Selection",
    Callback = function()
        selectedEnemies = {}
        pcall(function() EnemyDropdown:Set({}) end)
        pcall(function() SelectedCountLabel:Set("Selected Enemies: 0") end)
        if not getgenv().isBossFarmingActive then currentTarget = nil end
    end
})

--------------------------------------------------
-- Auto Bosses Tab Setup
--------------------------------------------------
BossCooldownLabel = AutoBossTab:CreateLabel("Auto Bosses: DISABLED")
SelectedBossesCountLabel = AutoBossTab:CreateLabel("Selected Bosses: 0")

BossDropdown = AutoBossTab:CreateDropdown({
    Name = "Select Bosses", Options = initialBossOptions, CurrentOption = {}, MultipleOptions = true, Flag = "SelectedBossesList_V3", 
    Callback = function(Options)
        selectedBosses = {}
        for _, displayName in ipairs(Options) do
            local realName = bossDropdownMap[displayName]
            if realName then selectedBosses[realName] = true end
        end
        pcall(function() SelectedBossesCountLabel:Set("Selected Bosses: " .. tostring(#Options)) end)
    end
})

AutoBossToggle = AutoBossTab:CreateToggle({
    Name = "Enable Auto Bosses", CurrentValue = false, Flag = "AutoBossEnabled_V3", 
    Callback = function(Value)
        autoBossMode = Value
        if not Value then
            if getgenv().isBossFarmingActive then
                getgenv().isBossFarmingActive = false
                fireStopBossRemote()
                currentTarget = nil
                remoteFired = false
            end
            pcall(function() BossCooldownLabel:Set("Auto Bosses: DISABLED") end)
        end
    end
})

AutoBossTab:CreateButton({ Name = "Reset Boss Selection", Callback = function() selectedBosses = {}; pcall(function() BossDropdown:Set({}) end); pcall(function() SelectedBossesCountLabel:Set("Selected Bosses: 0") end) end })

AutoBossTab:CreateLabel("— Live Boss Spawn Timers —")
for _, boss in ipairs(sortedBosses) do
    bossCooldownLabels[boss.name] = AutoBossTab:CreateLabel(boss.name .. ": Ready")
end

--------------------------------------------------
-- Settings Tab Setup
--------------------------------------------------
local noclipEnabled = false
local noclipConnection = nil

DistanceSlider = SettingsTab:CreateSlider({
    Name = "Target Distance Offset (Y-Axis)", Range = {-50, 50}, Increment = 1, CurrentValue = FARM_DISTANCE, Suffix = " studs",
    Flag = "FarmDistanceOffset", Callback = function(Value) FARM_DISTANCE = Value end
})

NoclipToggle = SettingsTab:CreateToggle({
    Name = "Noclip", CurrentValue = false, Flag = "NoclipEnabled",
    Callback = function(Value)
        noclipEnabled = Value
        if Value then
            noclipConnection = RunService.Stepped:Connect(function()
                if player.Character then
                    for _, part in ipairs(player.Character:GetDescendants()) do
                        if part:IsA("BasePart") and part.CanCollide then part.CanCollide = false end
                    end
                end
            end)
        else
            if noclipConnection then noclipConnection:Disconnect(); noclipConnection = nil end
        end
    end
})

SettingsTab:CreateButton({
    Name = "Unload Script",
    Callback = function()
        scriptRunning = false; currentTarget = nil; autoFarmMode = false; autoBossMode = false; autoEquipEnabled = false; getgenv().TPToLowHP = false
        if getgenv().isBossFarmingActive then fireStopBossRemote() end
        if noclipConnection then noclipConnection:Disconnect() end
        if safeZonePart then safeZonePart:Destroy() end
        Rayfield:Destroy()
    end
})

--------------------------------------------------
-- Custom Config System Setup
--------------------------------------------------
local CONFIG_FOLDER = "TPLockConfigs"
if not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end

local targetConfigName = "Default"

local function getSavedConfigs()
    local configs = {}
    for _, file in ipairs(listfiles(CONFIG_FOLDER)) do
        if file:sub(-5) == ".json" then
            local name = file:match("([^/\\]+)%.json$")
            if name then table.insert(configs, name) end
        end
    end
    return configs
end

local function saveCustomConfig(name)
    if name == "" or name == "No Configs Found" then return end
    local data = {
        AutoEquipEnabled = autoEquipEnabled,
        SelectedWeapon = selectedWeapon,
        TPLockEnabled = getgenv().TPToLowHP,
        PriorityHighHP = priorityHighToLow,
        LockDelayValue = LOCK_DELAY,
        HPThresholdValue = MAX_HP_THRESHOLD,
        SelectedEnemiesList = selectedEnemies,
        AutoFarmSelectedEnabled = autoFarmMode,
        SelectedBossesList = selectedBosses,
        AutoBossEnabled = autoBossMode,
        FarmDistanceOffset = FARM_DISTANCE,
        NoclipEnabled = noclipEnabled
    }
    writefile(CONFIG_FOLDER .. "/" .. name .. ".json", HttpService:JSONEncode(data))
    Rayfield:Notify({Title = "Config Saved", Content = "Successfully saved config: " .. name, Duration = 3})
    local updated = getSavedConfigs()
    if #updated == 0 then table.insert(updated, "No Configs Found") end
    if configListDropdown then pcall(function() configListDropdown:Refresh(updated) end) end
end

local function loadCustomConfig(name)
    if name == "" or name == "No Configs Found" then return end
    local path = CONFIG_FOLDER .. "/" .. name .. ".json"
    if isfile(path) then
        local success, rawData = pcall(function() return readfile(path) end)
        if success then
            local parsed = HttpService:JSONDecode(rawData)
            changingToggles = true
            
            pcall(function()
                if parsed.AutoEquipEnabled ~= nil then autoEquipEnabled = parsed.AutoEquipEnabled; if AutoEquipToggle then AutoEquipToggle:Set(parsed.AutoEquipEnabled) end end
                if parsed.SelectedWeapon ~= nil then selectedWeapon = parsed.SelectedWeapon; if WeaponDropdown then WeaponDropdown:Set({parsed.SelectedWeapon}) end end
                if parsed.TPLockEnabled ~= nil then getgenv().TPToLowHP = parsed.TPLockEnabled; if TPToggle then TPToggle:Set(parsed.TPLockEnabled) end end
                if parsed.PriorityHighHP ~= nil then priorityHighToLow = parsed.PriorityHighHP; if PriorityToggle then PriorityToggle:Set(parsed.PriorityHighHP) end end
                if parsed.LockDelayValue ~= nil then LOCK_DELAY = parsed.LockDelayValue; if LockDelaySlider then LockDelaySlider:Set(parsed.LockDelayValue) end end
                if parsed.HPThresholdValue ~= nil then MAX_HP_THRESHOLD = parsed.HPThresholdValue; if ThresholdLabel then ThresholdLabel:Set("Current Threshold: " .. formatNumber(parsed.HPThresholdValue)) end end
                if parsed.FarmDistanceOffset ~= nil then FARM_DISTANCE = parsed.FarmDistanceOffset; if DistanceSlider then DistanceSlider:Set(parsed.FarmDistanceOffset) end end
                if parsed.NoclipEnabled ~= nil then noclipEnabled = parsed.NoclipEnabled; if NoclipToggle then NoclipToggle:Set(parsed.NoclipEnabled) end end
                if parsed.AutoFarmSelectedEnabled ~= nil then autoFarmMode = parsed.AutoFarmSelectedEnabled; if AutoFarmToggle then AutoFarmToggle:Set(parsed.AutoFarmSelectedEnabled) end end
                if parsed.AutoBossEnabled ~= nil then autoBossMode = parsed.AutoBossEnabled; if AutoBossToggle then AutoBossToggle:Set(parsed.AutoBossEnabled) end end
                
                if parsed.SelectedEnemiesList then
                    selectedEnemies = parsed.SelectedEnemiesList
                    local displays = {}
                    for d, r in pairs(dropdownMap) do if selectedEnemies[r] then table.insert(displays, d) end end
                    if EnemyDropdown then EnemyDropdown:Set(displays) end
                end

                if parsed.SelectedBossesList then
                    selectedBosses = parsed.SelectedBossesList
                    local displays = {}
                    for d, r in pairs(bossDropdownMap) do if selectedBosses[r] then table.insert(displays, d) end end
                    if BossDropdown then BossDropdown:Set(displays) end
                end
            end)
            
            changingToggles = false
            Rayfield:Notify({Title = "Config Loaded", Content = "Successfully loaded config: " .. name, Duration = 3})
        end
    end
end

ConfigTab:CreateInput({
    Name = "Config Name", PlaceholderText = "Enter Config Name",
    Callback = function(Text) if Text and Text ~= "" then targetConfigName = Text end end
})

ConfigTab:CreateButton({ Name = "Save Config", Callback = function() saveCustomConfig(targetConfigName) end })

local initialConfigsList = getSavedConfigs()
if #initialConfigsList == 0 then table.insert(initialConfigsList, "No Configs Found") end

configListDropdown = ConfigTab:CreateDropdown({
    Name = "Saved Configurations", Options = initialConfigsList, CurrentOption = initialConfigsList[1], MultipleOptions = false,
    Callback = function(Option) if Option and Option[1] and Option[1] ~= "No Configs Found" then targetConfigName = Option[1] end end
})

ConfigTab:CreateButton({ Name = "Load Selected Config", Callback = function() loadCustomConfig(targetConfigName) end })

autoLoadLabel = ConfigTab:CreateLabel("Current Auto-Load: None")
ConfigTab:CreateButton({
    Name = "Set As Auto-Load",
    Callback = function()
        if targetConfigName ~= "" and targetConfigName ~= "No Configs Found" then
            writefile(CONFIG_FOLDER .. "/autoload.txt", targetConfigName)
            pcall(function() autoLoadLabel:Set("Current Auto-Load: " .. targetConfigName) end)
            Rayfield:Notify({Title = "Auto-Load Set", Content = targetConfigName .. " will now load automatically.", Duration = 3})
        end
    end
})

--------------------------------------------------
-- QUEUE ON TELEPORT WRAPPER
--------------------------------------------------
local queueteleport = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)

if queueteleport then
    player.OnTeleport:Connect(function(State)
        if State == Enum.TeleportState.Started then
            local codeToExecute = [[
                loadstring(game:HttpGet("https://raw.githubusercontent.com/ModAmiginhos/Roblox3/refs/heads/main/Roblox.lua"))()
            ]]
            pcall(function() 
                queueteleport(codeToExecute) 
            end)
        end
    end)
else
    ConfigTab:CreateLabel("⚠️ Executor doesn't support QueueOnTeleport")
end

--------------------------------------------------
-- Keybinds Tab Setup
--------------------------------------------------
KeybindsTab:CreateKeybind({ Name = "Toggle TP Lock", CurrentKeybind = "B", HoldToInteract = false, Flag = "KB_TPLock", Callback = function() if TPToggle then TPToggle:Set(not getgenv().TPToLowHP) end end })
KeybindsTab:CreateKeybind({ Name = "Toggle Auto Farm", CurrentKeybind = "V", HoldToInteract = false, Flag = "KB_AutoFarm", Callback = function() if AutoFarmToggle then AutoFarmToggle:Set(not autoFarmMode) end end })
KeybindsTab:CreateKeybind({ Name = "Toggle Auto Bosses", CurrentKeybind = "C", HoldToInteract = false, Flag = "KB_AutoBoss", Callback = function() if AutoBossToggle then AutoBossToggle:Set(not autoBossMode) end end })

--------------------------------------------------
-- Validation & Targeting System
--------------------------------------------------
local function isValidTarget(enemy)
    if not enemy or not enemy.hrp or not enemy.hrp.Parent then return false end
    if not enemy.humanoid or not enemy.humanoid.Parent or enemy.humanoid.Parent ~= enemy.hrp.Parent then return false end
    if enemy.humanoid:GetState() == Enum.HumanoidStateType.Dead then return false end
    if string.find(enemy.name, "DamageDummy") or string.find(enemy.realName, "DamageDummy") then return false end
    
    local liveHealth = enemy.humanoid.Health
    local bossHealthObj = enemy.humanoid:FindFirstChild("BossHealth")
    if bossHealthObj and bossHealthObj:IsA("NumberValue") then liveHealth = bossHealthObj.Value end
    if liveHealth <= 0 then return false end

    if autoFarmMode then return selectedEnemies[enemy.name] == true or selectedEnemies[enemy.realName] == true
    else return enemy.maxHealthValue < MAX_HP_THRESHOLD end
end

local function findNewTarget()
    local enemies = getEnemies()
    local bestTarget = nil
    local bestHP = priorityHighToLow and -1 or math.huge

    for _, enemy in ipairs(enemies) do
        local valid = false
        if autoFarmMode then valid = (selectedEnemies[enemy.name] == true or selectedEnemies[enemy.realName] == true)
        elseif getgenv().TPToLowHP then valid = (enemy.maxHealthValue < MAX_HP_THRESHOLD) end

        if valid then
            if priorityHighToLow then if enemy.maxHealthValue > bestHP then bestHP = enemy.maxHealthValue; bestTarget = enemy end
            else if enemy.maxHealthValue < bestHP then bestHP = enemy.maxHealthValue; bestTarget = enemy end end
        end
    end
    return bestTarget
end

--------------------------------------------------
-- Core Loop Workers
--------------------------------------------------
task.spawn(function()
    while scriptRunning do
        if autoEquipEnabled and selectedWeapon then
            local char = player.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if char and hum and hum.Health > 0 then
                local toolEquipped = char:FindFirstChild(selectedWeapon)
                if not toolEquipped then
                    local toolInBackpack = player.Backpack:FindFirstChild(selectedWeapon)
                    if toolInBackpack and toolInBackpack:IsA("Tool") then hum:EquipTool(toolInBackpack) end
                end
            end
        end
        task.wait(0.01)
    end
end)

task.spawn(function()
    while scriptRunning do
        -- 1. Scan and Update Active Moon State
        local newMoon = getMoonState()
        if newMoon ~= getgenv().CurrentMoon then
            getgenv().CurrentMoon = newMoon
            if CurrentMoonLabel then
                pcall(function() CurrentMoonLabel:Set("Current Moon: " .. newMoon) end)
            end
        end
        
        -- 2. Dynamic Boss Cooldown Modifier (5x faster on Blood Moon)
        local cooldownTime = (getgenv().CurrentMoon == "Blood Moon (Bosses respawn 5x  faster!)") and 5 or (getgenv().CurrentMoon == "Eclipse Moon (Bosses Respawn 5x Faster and 2x modifier chance)") and 5 or 30
        
        local farmingActive = getgenv().TPToLowHP or autoFarmMode or autoBossMode
        
        for bossName, label in pairs(bossCooldownLabels) do
            local lastKill = bossCooldowns[bossName] or 0
            local remaining = math.max(0, cooldownTime - (tick() - lastKill))
            if label then if remaining > 0 then label:Set(string.format("%s: Cooldown (%.1fs)", bossName, remaining)) else label:Set(bossName .. ": Ready") end end
        end

        if autoBossMode and BossCooldownLabel then
            if getgenv().isBossFarmingActive then BossCooldownLabel:Set("Farming Boss: " .. tostring(getgenv().activeBossTarget))
            else
                local lowestCooldown = math.huge
                local nextBossReadyName = nil
                local anySelected = false
                for bossName, _ in pairs(selectedBosses) do
                    anySelected = true
                    local lastKill = bossCooldowns[bossName] or 0
                    local remaining = math.max(0, cooldownTime - (tick() - lastKill))
                    if remaining < lowestCooldown then lowestCooldown = remaining; nextBossReadyName = bossName end
                end
                if not anySelected then BossCooldownLabel:Set("Auto Bosses: Select a Boss!")
                elseif nextBossReadyName then if lowestCooldown == 0 then BossCooldownLabel:Set("Next Boss: Ready!") else BossCooldownLabel:Set(string.format("Next Boss (%s) in: %.1fs", nextBossReadyName, lowestCooldown)) end end
            end
        end

        if farmingActive then
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")

            if root and humanoid then
                if autoBossMode and not getgenv().isBossFarmingActive then
                    local bossToSpawn = nil
                    for bossName, _ in pairs(selectedBosses) do
                        local lastKill = bossCooldowns[bossName] or 0
                        if tick() - lastKill >= cooldownTime then bossToSpawn = bossName; break end
                    end
                    if bossToSpawn then
                        getgenv().isBossFarmingActive = true; bossWasFound = false; getgenv().activeBossTarget = bossToSpawn
                        bossWaitTimeout = tick(); remoteFired = false; currentTarget = nil 
                    end
                end

                if getgenv().isBossFarmingActive then
                    if not remoteFired then fireStartBossRemote(getgenv().activeBossTarget); remoteFired = true end
                    local bossObject = findBossInWorkspace(getgenv().activeBossTarget)
                    local bossAlive = false
                    local bossDeadInstance = false

                    if bossObject then
                        local bHum = bossObject:FindFirstChildOfClass("Humanoid")
                        if bHum then
                            local bHealthObj = bHum:FindFirstChild("BossHealth")
                            local hp = (bHealthObj and bHealthObj:IsA("NumberValue")) and bHealthObj.Value or bHum.Health
                            if bHum:GetState() == Enum.HumanoidStateType.Dead or bHum.Health <= 0 or hp <= 0 then bossDeadInstance = true else bossAlive = true end
                        end
                    end
                    
                    if currentTarget and (currentTarget.name == getgenv().activeBossTarget or currentTarget.realName == getgenv().activeBossTarget) then
                        local bHum = currentTarget.humanoid
                        local bHealthObj = bHum:FindFirstChild("BossHealth")
                        local currentLiveHP = (bHealthObj and bHealthObj:IsA("NumberValue")) and bHealthObj.Value or bHum.Health
                        if currentLiveHP <= 0 or bHum:GetState() == Enum.HumanoidStateType.Dead then bossAlive = false; bossWasFound = true end
                    end
                    
                    if not bossAlive and (bossWasFound or bossDeadInstance) then
                        -- Destroy the Boss locally when detected as dead
                        if bossObject then pcall(function() bossObject:Destroy() end) end
                        if currentTarget and currentTarget.hrp and currentTarget.hrp.Parent then pcall(function() currentTarget.hrp.Parent:Destroy() end) end
                        
                        getgenv().isBossFarmingActive = false; bossCooldowns[getgenv().activeBossTarget] = tick(); fireStopBossRemote()
                        getgenv().activeBossTarget = nil; currentTarget = nil; remoteFired = false
                    elseif not bossAlive and not bossWasFound then
                        if tick() - bossWaitTimeout > 10 then
                            getgenv().isBossFarmingActive = false; bossCooldowns[getgenv().activeBossTarget] = tick(); fireStopBossRemote()
                            getgenv().activeBossTarget = nil; currentTarget = nil; remoteFired = false
                        end
                    else
                        bossWasFound = true; bossWaitTimeout = tick() 
                        if not currentTarget or (currentTarget.name ~= getgenv().activeBossTarget and currentTarget.realName ~= getgenv().activeBossTarget) or not currentTarget.hrp or not currentTarget.hrp.Parent then
                            currentTarget = nil
                            for _, enemy in ipairs(getEnemies()) do
                                if enemy.name == getgenv().activeBossTarget or enemy.realName == getgenv().activeBossTarget then currentTarget = enemy; break end
                            end
                        end
                    end
                else
                    if currentTarget and not isValidTarget(currentTarget) then currentTarget = nil end
                    if not currentTarget then currentTarget = findNewTarget() end
                end

                if currentTarget and not isValidTarget(currentTarget) then currentTarget = nil end

                if currentTarget then
                    local enemyCFrame = currentTarget.hrp.CFrame
                    local enemyPos = enemyCFrame.Position
                    local _, _, _, R00, R01, R02, R10, R11, R12, R20, R21, R22 = enemyCFrame:GetComponents()
                    
                    humanoid:ChangeState(Enum.HumanoidStateType.Physics)
                    root.Velocity = Vector3.new(0, 0, 0)
                    root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                    root.CFrame = CFrame.new(enemyPos.X, enemyPos.Y + FARM_DISTANCE, enemyPos.Z, R00, R01, R02, R10, R11, R12, R20, R21, R22)
                    
                    local liveHealth = 0
                    local bossHealthObj = currentTarget.humanoid:FindFirstChild("BossHealth")
                    if bossHealthObj and bossHealthObj:IsA("NumberValue") then liveHealth = bossHealthObj.Value else liveHealth = currentTarget.humanoid.Health end
                    currentTarget.currentHealth = liveHealth

                    if liveHealth <= 0 then
                        -- Destroy the targeted entity locally when health drops to 0
                        if currentTarget and currentTarget.hrp and currentTarget.hrp.Parent then
                            pcall(function() currentTarget.hrp.Parent:Destroy() end)
                        end
                        
                        if getgenv().isBossFarmingActive then getgenv().isBossFarmingActive = false; bossCooldowns[getgenv().activeBossTarget] = tick(); fireStopBossRemote(); getgenv().activeBossTarget = nil; remoteFired = false end
                        currentTarget = nil; continue 
                    end

                    if TargetLabel then
                        local statusPrefix = getgenv().isBossFarmingActive and "[BOSS ACTIVE]" or "Target:"
                        pcall(function() TargetLabel:Set(string.format("%s %s | HP: %s/%s", statusPrefix, currentTarget.realName or currentTarget.name, formatNumber(currentTarget.currentHealth), formatNumber(currentTarget.maxHealthValue))) end)
                    end
                    task.wait(LOCK_DELAY)
                else
                    if TargetLabel then pcall(function() TargetLabel:Set("Current Target: Searching (Safe Zone)") end) end
                    local zone = getOrCreateSafeZone()
                    root.CFrame = zone.CFrame + Vector3.new(0, 10, 0)
                    humanoid:ChangeState(Enum.HumanoidStateType.RunningNoPhysics)
                    root.Velocity = Vector3.new(0, 0, 0)
                    task.wait(0.01)
                end
            end
        else
            task.wait(0.1)
        end
    end
end)

-- Delayed Post-Rendering Actions
task.defer(function()
    pcall(RefreshWeapons)
    pcall(RefreshEnemyDropdown)
    
    if isfile(CONFIG_FOLDER .. "/autoload.txt") then
        local autoLoadName = readfile(CONFIG_FOLDER .. "/autoload.txt")
        if autoLoadName and autoLoadName ~= "" and isfile(CONFIG_FOLDER .. "/" .. autoLoadName .. ".json") then
            if autoLoadLabel then pcall(function() autoLoadLabel:Set("Current Auto-Load: " .. autoLoadName) end) end
            pcall(function() loadCustomConfig(autoLoadName) end)
        end
    end
end)
