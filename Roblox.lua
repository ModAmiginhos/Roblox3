-- TP Lock Script (Global Vector Position + Rotation Alignment Patch)
-- Features: Auto Equip, Safe Zone System, Noclip, Keybinds, Dummy Blacklist, and Remote-Triggered Auto Bosses

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

getgenv().TPToLowHP = true

local LOCK_DELAY = 0.015
local MAX_HP_THRESHOLD = 1e15
local FARM_DISTANCE = 4 -- Default positioning value

local currentTarget = nil
local scriptRunning = true

-- Modes
local autoFarmMode = false
local priorityHighToLow = false -- false = Low→High, true = High→Low

-- Auto Equip Variables
local autoEquipEnabled = false
local selectedWeapon = nil

-- Boss Handling Variables
local autoBossMode = false
local isBossFarming = false
local bossCooldowns = {} -- Tracks individual cooldowns: bossCooldowns["BossName"] = tick()
local activeBossTargetName = nil
local bossWasFound = false
local bossWaitTimeout = 0

local selectedEnemies = {}
local dropdownMap = {}

local selectedBosses = {}
local bossDropdownMap = {}

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
    LoadingSubtitle = "Auto Boss Edition",
    ConfigurationSaving = { Enabled = true, FolderName = "TPLockConfig", FileName = "Settings" },
    KeySystem = false
})

-- TABS
local AutoEquipTab = Window:CreateTab("Auto Equip", 4483362458)
local MainTab = Window:CreateTab("Auto Farm All", 4483362458)
local AutoFarmTab = Window:CreateTab("Auto Farm Selected", 4483362458)
local AutoBossTab = Window:CreateTab("Auto Bosses", 4483362458)
local SettingsTab = Window:CreateTab("Settings", 4483362458)
local KeybindsTab = Window:CreateTab("Keybinds", 4483362458) 

-- Forward Declarations for Toggles
local TPToggle, AutoFarmToggle, AutoBossToggle, AutoEquipToggle

--------------------------------------------------
-- Auto Equip Components (Tab 1)
--------------------------------------------------
local AutoEquipStatusLabel = AutoEquipTab:CreateLabel("Auto Equip: DISABLED")

local WeaponDropdown = AutoEquipTab:CreateDropdown({
    Name = "Select Weapon",
    Options = {},
    CurrentOption = {},
    MultipleOptions = false,
    Flag = "AutoEquipSelectedWeapon", -- It is safe to save this
    Callback = function(Option)
        if Option and Option[1] then
            selectedWeapon = Option[1]
        else
            selectedWeapon = nil
        end
    end
})

AutoEquipTab:CreateButton({
    Name = "Refresh Weapons",
    Callback = function()
        local options = {}
        local uniqueWeapons = {}
        
        -- Scan Backpack
        for _, item in ipairs(player.Backpack:GetChildren()) do
            if item:IsA("Tool") and not uniqueWeapons[item.Name] then
                uniqueWeapons[item.Name] = true
                table.insert(options, item.Name)
            end
        end
        
        -- Scan Character (if tool is already equipped)
        if player.Character then
            for _, item in ipairs(player.Character:GetChildren()) do
                if item:IsA("Tool") and not uniqueWeapons[item.Name] then
                    uniqueWeapons[item.Name] = true
                    table.insert(options, item.Name)
                end
            end
        end
        
        WeaponDropdown:Refresh(options)
    end
})

AutoEquipToggle = AutoEquipTab:CreateToggle({
    Name = "Enable Auto Equip",
    CurrentValue = false,
    Flag = "AutoEquipEnabled",
    Callback = function(Value)
        autoEquipEnabled = Value
        AutoEquipStatusLabel:Set("Auto Equip: " .. (Value and "ENABLED" or "DISABLED"))
    end
})

--------------------------------------------------
-- Main Tab Components (Auto Farm All)
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
            changingToggles = false
            
            autoFarmMode = false
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
-- Auto Farm Selected Components
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
        if not isBossFarming then currentTarget = nil end
    end
})

--------------------------------------------------
-- Auto Bosses Components
--------------------------------------------------
local BossCooldownLabel = AutoBossTab:CreateLabel("Auto Bosses: DISABLED")
local SelectedBossesCountLabel = AutoBossTab:CreateLabel("Selected Bosses: 0")
AutoBossTab:CreateLabel("Farms bosses, then farms regular NPCs during their cooldowns.")
AutoBossTab:CreateLabel("Note: Boss settings DO NOT save to prevent script glitches.")

local BossDropdown = AutoBossTab:CreateDropdown({
    Name = "Select Bosses",
    Options = {},
    CurrentOption = {},
    MultipleOptions = true,
    -- FLAG REMOVED DELIBERATELY TO PREVENT SAVING/GLITCHING
    Callback = function(Options)
        selectedBosses = {}
        for _, displayName in ipairs(Options) do
            local realName = bossDropdownMap[displayName]
            if realName then selectedBosses[realName] = true end
        end
        SelectedBossesCountLabel:Set("Selected Bosses: " .. tostring(#Options))
    end
})

AutoBossToggle = AutoBossTab:CreateToggle({
    Name = "Enable Auto Bosses",
    CurrentValue = false,
    -- FLAG REMOVED DELIBERATELY TO PREVENT SAVING/GLITCHING
    Callback = function(Value)
        autoBossMode = Value
        if not Value then
            if isBossFarming then
                isBossFarming = false
                local stopRemote = ReplicatedStorage:FindFirstChild("StopAutoFarm")
                if stopRemote then stopRemote:FireServer() end
                currentTarget = nil
            end
            BossCooldownLabel:Set("Auto Bosses: DISABLED")
        end
    end
})

local function getBossesFromRS()
    local uniqueBosses = {}
    local bossesFolder = ReplicatedStorage:FindFirstChild("Bosses")
    if bossesFolder then
        for _, bossModel in ipairs(bossesFolder:GetChildren()) do
            local hum = bossModel:FindFirstChildOfClass("Humanoid")
            if hum then
                local maxHP = hum.MaxHealth
                local maxHealthObj = hum:FindFirstChild("MaxHealth")
                if maxHealthObj and maxHealthObj:IsA("NumberValue") then
                    maxHP = maxHealthObj.Value
                end
                uniqueBosses[bossModel.Name] = maxHP
            else
                uniqueBosses[bossModel.Name] = 10000 -- Fallback if Humanoid missing in RS
            end
        end
    end
    return uniqueBosses
end

AutoBossTab:CreateButton({
    Name = "Refresh Boss List (From ReplicatedStorage)",
    Callback = function()
        local uniqueBosses = getBossesFromRS()
        local options = {}
        bossDropdownMap = {}

        local sorted = {}
        for name, hp in pairs(uniqueBosses) do table.insert(sorted, {name = name, hp = hp}) end
        table.sort(sorted, function(a, b) return a.hp < b.hp end)

        for _, boss in ipairs(sorted) do
            local display = string.format("(%s) %s", formatNumber(boss.hp), boss.name)
            table.insert(options, display)
            bossDropdownMap[display] = boss.name
        end
        BossDropdown:Refresh(options)
    end
})

AutoBossTab:CreateButton({
    Name = "Reset Boss Selection",
    Callback = function()
        selectedBosses = {}
        BossDropdown:Set({})
        SelectedBossesCountLabel:Set("Selected Bosses: 0")
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
        autoBossMode = false
        autoEquipEnabled = false
        getgenv().TPToLowHP = false
        if isBossFarming then
            local stopRemote = ReplicatedStorage:FindFirstChild("StopAutoFarm")
            if stopRemote then stopRemote:FireServer() end
        end
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
    Name = "Toggle Auto Bosses",
    CurrentKeybind = "C",
    HoldToInteract = false,
    Flag = "KB_AutoBoss",
    Callback = function() AutoBossToggle:Set(not autoBossMode) end
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
            
            -- Filter out DamageDummy and Players
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

local function isValidTarget(enemy)
    if not enemy or not enemy.hrp or not enemy.hrp.Parent then return false end
    if string.find(enemy.name, "DamageDummy") then return false end
    
    -- If we are farming a boss, STRICTLY check workspace.Bosses to prevent lingering on dead bosses
    if isBossFarming and enemy.name == activeBossTargetName then
        local wsBosses = workspace:FindFirstChild("Bosses")
        if not wsBosses then return false end
        
        local theBoss = wsBosses:FindFirstChild(enemy.name)
        if not theBoss then return false end -- Boss is removed from workspace
        
        local hum = theBoss:FindFirstChildOfClass("Humanoid")
        if not hum then return false end
        
        local liveHealth = hum.Health
        local bossHealthObj = hum:FindFirstChild("BossHealth")
        if bossHealthObj and bossHealthObj:IsA("NumberValue") then
            liveHealth = bossHealthObj.Value
        end
        
        if liveHealth <= 0 then return false end
        return true
    end

    -- Normal NPC checks
    local liveHealth = enemy.humanoid.Health
    local bossHealthObj = enemy.humanoid:FindFirstChild("BossHealth")
    if bossHealthObj and bossHealthObj:IsA("NumberValue") then
        liveHealth = bossHealthObj.Value
    end
    
    if liveHealth <= 0 then return false end

    if autoFarmMode then
        return selectedEnemies[enemy.name] == true
    else
        return enemy.maxHealthValue < MAX_HP_THRESHOLD
    end
end

local function findNewTarget()
    local enemies = getEnemies()
    local bestTarget = nil
    local bestHP = priorityHighToLow and -1 or math.huge

    for _, enemy in ipairs(enemies) do
        local valid = false
        if autoFarmMode then
            valid = (selectedEnemies[enemy.name] == true)
        elseif getgenv().TPToLowHP then
            valid = (enemy.maxHealthValue < MAX_HP_THRESHOLD)
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

--------------------------------------------------
-- Auto Equip Thread
--------------------------------------------------
task.spawn(function()
    while scriptRunning do
        if autoEquipEnabled and selectedWeapon then
            local char = player.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            
            if char and hum and hum.Health > 0 then
                -- Check if the tool is already equipped
                local toolEquipped = char:FindFirstChild(selectedWeapon)
                
                if not toolEquipped then
                    -- If not equipped, look for it in the Backpack and equip it
                    local toolInBackpack = player.Backpack:FindFirstChild(selectedWeapon)
                    if toolInBackpack and toolInBackpack:IsA("Tool") then
                        hum:EquipTool(toolInBackpack)
                    end
                end
            end
        end
        task.wait(0.2) -- Loop runs 5 times a second to keep the weapon equipped smoothly
    end
end)

--------------------------------------------------
-- Main Auto Farm Execution Thread
--------------------------------------------------
task.spawn(function()
    while scriptRunning do
        local farmingActive = getgenv().TPToLowHP or autoFarmMode or autoBossMode
        
        -- Individual Cooldown UI Updater
        if autoBossMode then
            if isBossFarming then
                BossCooldownLabel:Set("Farming Boss: " .. tostring(activeBossTargetName))
            else
                local lowestCooldown = math.huge
                local nextBossReadyName = nil
                local anySelected = false
                
                for bossName, _ in pairs(selectedBosses) do
                    anySelected = true
                    local lastKill = bossCooldowns[bossName] or 0
                    local remaining = math.max(0, 30 - (tick() - lastKill))
                    
                    if remaining < lowestCooldown then
                        lowestCooldown = remaining
                        nextBossReadyName = bossName
                    end
                end
                
                if not anySelected then
                    BossCooldownLabel:Set("Auto Bosses: Select a Boss!")
                elseif nextBossReadyName then
                    if lowestCooldown == 0 then
                        BossCooldownLabel:Set("Next Boss: Ready!")
                    else
                        BossCooldownLabel:Set(string.format("Next Boss (%s) in: %.1fs", nextBossReadyName, lowestCooldown))
                    end
                end
            end
        end

        if farmingActive then
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")

            if root and humanoid then
                
                -- Check individual boss cooldowns to see who is ready to be spawned
                if autoBossMode and not isBossFarming then
                    local bossToSpawn = nil
                    for bossName, _ in pairs(selectedBosses) do
                        local lastKill = bossCooldowns[bossName] or 0
                        if tick() - lastKill >= 30 then
                            bossToSpawn = bossName
                            break -- Found a boss ready to spawn
                        end
                    end
                    
                    if bossToSpawn then
                        isBossFarming = true
                        bossWasFound = false
                        activeBossTargetName = bossToSpawn
                        bossWaitTimeout = tick()
                        
                        -- Fire remote to summon the boss
                        local startRemote = ReplicatedStorage:FindFirstChild("StartAutofarm")
                        if startRemote then 
                            startRemote:FireServer(bossToSpawn)
                        end
                        
                        currentTarget = nil -- Reset target to force finding the new boss
                    end
                end

                -- Boss Farming Phase
                if isBossFarming then
                    local currentBossValid = currentTarget and currentTarget.name == activeBossTargetName and isValidTarget(currentTarget)
                    
                    if not currentBossValid then
                        local bossFoundNow = false
                        for _, enemy in ipairs(getEnemies()) do
                            if enemy.name == activeBossTargetName then
                                currentTarget = enemy
                                bossFoundNow = true
                                bossWasFound = true
                                break
                            end
                        end
                        
                        if not bossFoundNow then
                            -- If boss died/disappeared OR if 10 seconds pass without it spawning
                            if bossWasFound or (tick() - bossWaitTimeout > 10) then
                                isBossFarming = false
                                
                                -- Set the specific cooldown for THIS boss
                                if activeBossTargetName then
                                    bossCooldowns[activeBossTargetName] = tick()
                                end
                                
                                activeBossTargetName = nil
                                
                                local stopRemote = ReplicatedStorage:FindFirstChild("StopAutoFarm")
                                if stopRemote then stopRemote:FireServer() end
                                
                                currentTarget = nil
                            end
                        else
                            bossWaitTimeout = tick()
                        end
                    else
                        bossWaitTimeout = tick()
                    end
                
                -- Standard NPC Farming Phase
                else
                    if currentTarget and not isValidTarget(currentTarget) then
                        currentTarget = nil
                    end

                    if not currentTarget then
                        currentTarget = findNewTarget()
                    end
                end

                -- Teleportation and Tracking
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
                    
                    -- Dynamic Target Label Updating
                    local liveHealth = 0
                    if isBossFarming and currentTarget.name == activeBossTargetName then
                        -- Strict Workspace Check for Boss UI
                        local wsBosses = workspace:FindFirstChild("Bosses")
                        if wsBosses then
                            local theBoss = wsBosses:FindFirstChild(currentTarget.name)
                            if theBoss and theBoss:FindFirstChildOfClass("Humanoid") then
                                local bHum = theBoss:FindFirstChildOfClass("Humanoid")
                                local bHealthObj = bHum:FindFirstChild("BossHealth")
                                liveHealth = (bHealthObj and bHealthObj:IsA("NumberValue")) and bHealthObj.Value or bHum.Health
                            end
                        end
                    else
                        -- Normal NPC Check
                        local bossHealthObj = currentTarget.humanoid:FindFirstChild("BossHealth")
                        if bossHealthObj and bossHealthObj:IsA("NumberValue") then
                            liveHealth = bossHealthObj.Value
                        else
                            liveHealth = currentTarget.humanoid.Health
                        end
                    end
                    
                    currentTarget.currentHealth = liveHealth

                    local statusPrefix = isBossFarming and "[BOSS ACTIVE]" or "Target:"
                    TargetLabel:Set(string.format(
                        "%s %s | HP: %s/%s",
                        statusPrefix,
                        currentTarget.name,
                        formatNumber(currentTarget.currentHealth),
                        formatNumber(currentTarget.maxHealthValue)
                    ))
                    
                    task.wait(LOCK_DELAY)
                else
                    TargetLabel:Set("Current Target: Searching (Safe Zone)")
                    
                    local zone = getOrCreateSafeZone()
                    humanoid:ChangeState(Enum.HumanoidStateType.Physics)
                    root.Velocity = Vector3.new(0, 0, 0)
                    root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
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
