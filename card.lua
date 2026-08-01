-- Anime Card Farm Automation
-- Auto Carry & Open Boxes (fires the plot conveyor's own "Carry" ProximityPrompt;
-- the game's own CardBoxClient script handles the walk animation and automatically
-- fires CardReachedArrival, i.e. "opening" the box, once it arrives) + Auto Spawn
-- Pack (auto-buys world pack stands, filtered by a Rarity/buff Dropdown; Robux-only
-- packs are excluded on purpose) + Auto Sell Packs + Auto Equip Best Card + Auto
-- Claim Daily / Playtime / Offline Rewards + Anti-AFK + Auto Reconnect + Auto Save
-- UI built with Maclib (https://github.com/biggaboy212/Maclib)

getgenv().__CardGen = (getgenv().__CardGen or 0) + 1
local myGen = getgenv().__CardGen

pcall(function()
    if getgenv().__CardWindow then getgenv().__CardWindow:Unload() end
end)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local LocalPlayer = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local SellRE = Remotes:WaitForChild("SellRE")
local DailyRewardRE = Remotes:WaitForChild("DailyRewardRE")
local PlayTimeRewardRE = Remotes:WaitForChild("PlayTimeRewardRE")
local OfflineRE = Remotes:WaitForChild("OfflineRE")
local ConveyorSettingsRE = Remotes:WaitForChild("ConveyorSettingsRE")
local CardSlotRE = ReplicatedStorage:WaitForChild("CardSlotRE")

local ConveyorPacks = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ConveyorPacks"))

-- ===== Auto Save (same pattern as Idle Slayers / RNG Heroes automation) =====
local SAVE_FOLDER = "AnimeCardFarmAutomation"
local SAVE_FILE = SAVE_FOLDER .. "/state.json"
pcall(function() if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end end)
local PERSIST_KEYS = {
    "AutoCarryOpenEnabled", "CarryMinValue", "AutoSpawnPackEnabled", "SpawnRarityFilter", "SpawnBuffFilter",
    "AutoSellPacksEnabled", "AutoEquipBestEnabled",
    "AutoClaimDailyEnabled", "AutoClaimPlaytimeEnabled", "AutoClaimOfflineEnabled",
    "AntiAFKEnabled", "AutoReconnectEnabled",
}
local function loadPersistedState()
    local ok, content = pcall(function() return readfile(SAVE_FILE) end)
    if not ok or not content or content == "" then return end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not ok2 or type(data) ~= "table" then return end
    for _, key in ipairs(PERSIST_KEYS) do
        if data[key] ~= nil and getgenv()[key] == nil then getgenv()[key] = data[key] end
    end
end
loadPersistedState()
local function saveState()
    local data = {}
    for _, key in ipairs(PERSIST_KEYS) do data[key] = getgenv()[key] end
    pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(data)) end)
end

if getgenv().AutoCarryOpenEnabled == nil then getgenv().AutoCarryOpenEnabled = false end
if getgenv().CarryMinValue == nil then getgenv().CarryMinValue = "No Minimum" end
if getgenv().AutoSpawnPackEnabled == nil then getgenv().AutoSpawnPackEnabled = false end
if getgenv().SpawnRarityFilter == nil then getgenv().SpawnRarityFilter = {} end
if getgenv().SpawnBuffFilter == nil then getgenv().SpawnBuffFilter = {} end
if getgenv().AutoSellPacksEnabled == nil then getgenv().AutoSellPacksEnabled = false end
if getgenv().AutoEquipBestEnabled == nil then getgenv().AutoEquipBestEnabled = false end
if getgenv().AutoClaimDailyEnabled == nil then getgenv().AutoClaimDailyEnabled = true end
if getgenv().AutoClaimPlaytimeEnabled == nil then getgenv().AutoClaimPlaytimeEnabled = true end
if getgenv().AutoClaimOfflineEnabled == nil then getgenv().AutoClaimOfflineEnabled = true end
if getgenv().AntiAFKEnabled == nil then getgenv().AntiAFKEnabled = true end
if getgenv().AutoReconnectEnabled == nil then getgenv().AutoReconnectEnabled = true end

-- ===== Pack catalog (world stands) -- excludes RobuxOnly packs on purpose =====
local PackCatalog = {}
for _, v in ipairs(ConveyorPacks.List) do
    if not v.RobuxOnly then
        table.insert(PackCatalog, {Id = v.Id, Rarity = v.Rarity, Price = tonumber(v.Price) or 0})
    end
end
local RarityOptions = {}
do
    local seen = {}
    for _, v in ipairs(PackCatalog) do
        if not seen[v.Rarity] then
            seen[v.Rarity] = true
            table.insert(RarityOptions, v.Rarity)
        end
    end
end
local BuffOptions = {}
for _, v in ipairs(PackCatalog) do
    table.insert(BuffOptions, v.Id)
end

-- ===== Helpers =====
local function getPlotN0()
    local plotNumVal = LocalPlayer:FindFirstChild("PlotNumber")
    local plotNum = plotNumVal and plotNumVal.Value or 1
    local plots = workspace:FindFirstChild("MAP") and workspace.MAP:FindFirstChild("Plots")
    local plot = plots and plots:FindFirstChild(tostring(plotNum))
    return plot and plot:FindFirstChild("Plot_N0")
end

local function getCash()
    local v = LocalPlayer:FindFirstChild("CashValue")
    return v and v.Value or 0
end

local function getHRP()
    local character = LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

-- Parses display strings like "$26.2K" / "1.5M" / "3T" into a plain number.
local MONEY_SUFFIX_MULT = {
    ["K"] = 1e3, ["M"] = 1e6, ["B"] = 1e9, ["T"] = 1e12,
    ["QA"] = 1e15, ["QI"] = 1e18, ["SX"] = 1e21, ["SP"] = 1e24,
}
local function parseMoneyText(text)
    if not text then return 0 end
    local numStr, suffix = tostring(text):match("([%d%.]+)%s*([%a]*)")
    local num = tonumber(numStr)
    if not num then return 0 end
    suffix = tostring(suffix or ""):upper()
    return num * (MONEY_SUFFIX_MULT[suffix] or 1)
end
local CARRY_THRESHOLD_OPTIONS = {"No Minimum", "100K", "1M", "1B", "1T"}
local CARRY_THRESHOLD_VALUES = {["No Minimum"] = 0, ["100K"] = 1e5, ["1M"] = 1e6, ["1B"] = 1e9, ["1T"] = 1e12}

-- Finds real ground below a world position via raycast so we never blindly
-- teleport the character into the void or through the map -- if no ground is
-- found within range, the caller must skip the teleport entirely instead of
-- guessing a position (this is what previously caused fall-to-death warps).
local function findSafeGroundPosition(position, maxDrop)
    maxDrop = maxDrop or 400
    local character = LocalPlayer.Character
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    if character then rayParams.FilterDescendantsInstances = {character} end
    local origin = position + Vector3.new(0, 50, 0)
    local result = workspace:Raycast(origin, Vector3.new(0, -maxDrop, 0), rayParams)
    if result then
        return result.Position + Vector3.new(0, 3, 0)
    end
    return nil
end

-- ===== Auto Carry & Open Boxes (item 1 + 4: "Carry" prompt on the plot's own
-- conveyor. Triggering it picks up whatever box is currently spawned; the
-- game's own CardBoxClient script (already running) then plays the walk-to-
-- arrival animation and fires CardReachedArrival itself -- that's the actual
-- "open" step that grants the card. We only need to trigger the pickup.
-- Teleports to the box each cycle (own plot, always loaded/safe ground) since
-- the executor's fireproximityprompt still enforces real distance here.) =====
local carryStatusText = "Idle"
local function doAutoCarry()
    if not getgenv().AutoCarryOpenEnabled then
        carryStatusText = "Idle"
        return
    end
    local plotN0 = getPlotN0()
    local boxBase = plotN0 and plotN0:FindFirstChild("BoxBaseModel")
    local proxiBox = boxBase and boxBase:FindFirstChild("ProxiBox")
    local prompt = proxiBox and proxiBox:FindFirstChildOfClass("ProximityPrompt")
    if not (prompt and proxiBox:IsA("BasePart")) then
        carryStatusText = "Waiting for conveyor box..."
        return
    end
    local boxValue = parseMoneyText(prompt.ObjectText)
    local minValue = CARRY_THRESHOLD_VALUES[getgenv().CarryMinValue or "No Minimum"] or 0
    carryStatusText = "Box value: " .. tostring(prompt.ObjectText)
    if not prompt.Enabled then return end
    if boxValue < minValue then
        carryStatusText = carryStatusText .. " (below threshold, skipped)"
        return
    end
    local hrp = getHRP()
    if not hrp then return end
    local originalCFrame = hrp.CFrame
    local ok = pcall(function()
        hrp.Anchored = true
        hrp.CFrame = CFrame.new(proxiBox.Position + Vector3.new(0, 3, 0), proxiBox.Position)
    end)
    task.wait(0.15)
    if prompt.Enabled then
        pcall(function() fireproximityprompt(prompt) end)
    end
    task.wait(0.15)
    pcall(function()
        hrp.CFrame = originalCFrame
        hrp.Anchored = false
    end)
end

-- ===== Auto Spawn Pack (item 6: buys from world pack stands, filtered by
-- separate Rarity and Buff (pack name) Dropdowns. Each stand instantly grants
-- its pack on trigger -- verified live earlier this session. Teleport is
-- raycast-verified (findSafeGroundPosition) and the character is restored to
-- their original spot afterward -- a blind position teleport here previously
-- warped the character into the void and killed them.) =====
local spawnStatusText = "Idle"
local spawnCycleIndex = 1
local function getSelectedFilters()
    local raritySet, buffSet = {}, {}
    for _, r in ipairs(getgenv().SpawnRarityFilter or {}) do raritySet[r] = true end
    for _, b in ipairs(getgenv().SpawnBuffFilter or {}) do buffSet[b] = true end
    return raritySet, buffSet
end
local function doAutoSpawnPack()
    if not getgenv().AutoSpawnPackEnabled then return end
    local raritySet, buffSet = getSelectedFilters()
    local hasRarityFilter = next(raritySet) ~= nil
    local hasBuffFilter = next(buffSet) ~= nil
    if not (hasRarityFilter or hasBuffFilter) then
        spawnStatusText = "Select a Rarity and/or Buff filter first"
        return
    end
    local hrp = getHRP()
    if not hrp then return end

    local tried = 0
    while tried < #PackCatalog do
        spawnCycleIndex = (spawnCycleIndex % #PackCatalog) + 1
        local pack = PackCatalog[spawnCycleIndex]
        tried += 1
        local matches = (not hasRarityFilter or raritySet[pack.Rarity]) and (not hasBuffFilter or buffSet[pack.Id])
        if matches then
            local model = workspace:FindFirstChild(pack.Id)
            local main = model and model:FindFirstChild("Main")
            local prompt = main and main:FindFirstChildOfClass("ProximityPrompt")
            if prompt then
                if getCash() >= pack.Price then
                    local groundPos = findSafeGroundPosition(main.Position)
                    if not groundPos then
                        spawnStatusText = "No safe ground found for: " .. pack.Id .. " (skipped)"
                        return
                    end
                    local originalCFrame = hrp.CFrame
                    pcall(function()
                        hrp.Anchored = true
                        hrp.CFrame = CFrame.new(groundPos, main.Position)
                    end)
                    task.wait(0.25)
                    if prompt.Enabled then
                        pcall(function() fireproximityprompt(prompt) end)
                        spawnStatusText = "Bought: " .. pack.Id
                    else
                        spawnStatusText = "Not available yet: " .. pack.Id
                    end
                    task.wait(0.2)
                    pcall(function()
                        hrp.CFrame = originalCFrame
                        hrp.Anchored = false
                    end)
                else
                    spawnStatusText = "Can't afford: " .. pack.Id
                end
            else
                spawnStatusText = "Stand not found (not streamed in?): " .. pack.Id
            end
            return
        end
    end
    spawnStatusText = "None of the selected packs have a stand in the world"
end

-- ===== Auto Sell Packs (item 2) =====
local sellStatusText = "Idle"
local function doAutoSellPacks()
    if not getgenv().AutoSellPacksEnabled then return end
    local received = nil
    local conn
    conn = SellRE.OnClientEvent:Connect(function(...) received = {...} end)
    pcall(function() SellRE:FireServer("SellPacks") end)
    task.wait(1)
    if conn then conn:Disconnect() end
    if received and received[1] == "Result" and received[2] and received[2].Total then
        sellStatusText = "Sold for $" .. tostring(received[2].Total)
    elseif received and received[1] == "Empty" then
        sellStatusText = "Nothing to sell right now"
    elseif received and received[1] == "Blocked" then
        sellStatusText = "Blocked: " .. tostring(received[2] and received[2].Reason or "unknown")
    else
        sellStatusText = "Fired (no response)"
    end
end

-- ===== Auto Equip Best Card (item 3) =====
local function doAutoEquipBest()
    if not getgenv().AutoEquipBestEnabled then return end
    pcall(function() CardSlotRE:FireServer("EquipBest") end)
end

-- ===== Auto Claim Daily Reward =====
local function doAutoClaimDaily()
    if not getgenv().AutoClaimDailyEnabled then return end
    pcall(function() DailyRewardRE:FireServer("Claim") end)
end

-- ===== Auto Claim Playtime Rewards (real free path -- the visible "ClaimAll"
-- button in this game is a Robux purchase prompt, NOT a free bulk claim, so we
-- loop the individual ClaimReward call per ready index instead, exactly like a
-- manual player clicking each ready reward.) =====
local playtimeStatusText = "Idle"
local function doAutoClaimPlaytime()
    if not getgenv().AutoClaimPlaytimeEnabled then return end
    local received = nil
    local conn
    conn = PlayTimeRewardRE.OnClientEvent:Connect(function(...)
        received = {...}
    end)
    pcall(function() PlayTimeRewardRE:FireServer("RequestState") end)
    task.wait(1.5)
    if conn then conn:Disconnect() end
    if not (received and received[1] == "State" and received[2]) then
        playtimeStatusText = "No state received"
        return
    end
    local state = received[2]
    local claimed = 0
    for i, reward in ipairs(state.Rewards or {}) do
        if reward.Ready and not reward.Claimed then
            pcall(function()
                PlayTimeRewardRE:FireServer("ClaimReward", {RewardIndex = i})
            end)
            claimed += 1
            task.wait(0.2)
        end
    end
    playtimeStatusText = claimed > 0 and ("Claimed " .. claimed .. " reward(s)") or "Nothing ready"
end

-- ===== Auto Claim Offline Reward (free path only -- "ClaimNormal"; the double
-- reward path is a Robux purchase, intentionally not used) =====
local function doAutoClaimOffline()
    if not getgenv().AutoClaimOfflineEnabled then return end
    pcall(function() OfflineRE:FireServer("ClaimNormal") end)
end

-- ===== Anti-AFK =====
LocalPlayer.Idled:Connect(function()
    if not getgenv().AntiAFKEnabled then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

-- ===== Auto Reconnect =====
-- game:BindToClose() is server-only -- Players.PlayerRemoving is the client-
-- legal signal that fires when this player is about to be removed, giving a
-- brief window to fire a re-teleport (won't catch every hard disconnect/kick,
-- only graceful leaves, but it's the best a client script can do).
if not getgenv().__CardReconnectHooked then
    getgenv().__CardReconnectHooked = true
    Players.PlayerRemoving:Connect(function(player)
        if player == LocalPlayer and getgenv().AutoReconnectEnabled then
            pcall(function()
                TeleportService:Teleport(game.PlaceId, LocalPlayer)
            end)
        end
    end)
end

-- ===== UI (Maclib) =====
local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()

local Window = MacLib:Window({
    Title = "Anime Card Farm Automation",
    Subtitle = "by Claude",
    DragStyle = 1,
    ShowUserInfo = true,
    AcrylicBlur = false,
})

-- Tab icons use Roblox's Lucide icon pack (rbxassetid images), verified against
-- dawid-scripts/Fluent's src/Icons.lua (master branch).
local TabGroup = Window:TabGroup()
local Tabs = {
    Conveyor = TabGroup:Tab({Name = "Conveyor", Image = "rbxassetid://10734908793"}), -- lucide-package-open
    Packs = TabGroup:Tab({Name = "Packs", Image = "rbxassetid://10734952273"}),       -- lucide-shopping-bag
    Rewards = TabGroup:Tab({Name = "Rewards", Image = "rbxassetid://10723396402"}),   -- lucide-gift
    Misc = TabGroup:Tab({Name = "Misc", Image = "rbxassetid://10734963191"}),         -- lucide-sliders-horizontal
    Settings = TabGroup:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}), -- lucide-settings
}

-- ----- Conveyor Tab -----
local CarrySection = Tabs.Conveyor:Section({Side = "Left"})
CarrySection:Header({Text = "Auto Carry & Open Boxes"})
CarrySection:Toggle({
    Name = "Auto Carry & Open Boxes",
    Default = getgenv().AutoCarryOpenEnabled,
    Callback = function(value) getgenv().AutoCarryOpenEnabled = value; saveState() end,
}, "AutoCarryOpenEnabled")
CarrySection:Dropdown({
    Name = "Minimum Box Value",
    Multi = false,
    Options = CARRY_THRESHOLD_OPTIONS,
    Default = getgenv().CarryMinValue,
    Callback = function(value)
        local picked = type(value) == "table" and value[1] or value
        getgenv().CarryMinValue = CARRY_THRESHOLD_VALUES[picked] and picked or "No Minimum"
        saveState()
    end,
}, "CarryMinValue")
CarrySection:Label({Text = "Triggers your plot's own \"Carry\" prompt. The game\nauto-plays the walk animation and opens the box\nfor you once it arrives -- carry = open here.\nTeleports to the box each time (own plot, safe) since\nthe executor still enforces real pickup distance."})
local carryStatusLabel = CarrySection:Label({Text = "Idle"})

-- ----- Packs Tab -----
local SpawnSection = Tabs.Packs:Section({Side = "Left"})
SpawnSection:Header({Text = "Auto Spawn Pack"})
SpawnSection:Toggle({
    Name = "Auto Spawn Pack",
    Default = getgenv().AutoSpawnPackEnabled,
    Callback = function(value) getgenv().AutoSpawnPackEnabled = value; saveState() end,
}, "AutoSpawnPackEnabled")
local function makeMultiFilterCallback(genvKey, options)
    return function(value)
        local selectedSet = {}
        if type(value) == "table" then
            for k, v2 in pairs(value) do
                if type(k) == "string" and v2 == true then
                    selectedSet[k] = true
                elseif type(k) == "number" and type(v2) == "string" then
                    selectedSet[v2] = true
                end
            end
        end
        local newList = {}
        for _, label in ipairs(options) do
            if selectedSet[label] then table.insert(newList, label) end
        end
        getgenv()[genvKey] = newList
        saveState()
    end
end
SpawnSection:Dropdown({
    Name = "Rarity Filter",
    Multi = true,
    Search = true,
    Options = RarityOptions,
    Default = getgenv().SpawnRarityFilter,
    Callback = makeMultiFilterCallback("SpawnRarityFilter", RarityOptions),
}, "SpawnRarityFilter")
SpawnSection:Dropdown({
    Name = "Buff (Pack Name) Filter",
    Multi = true,
    Search = true,
    Options = BuffOptions,
    Default = getgenv().SpawnBuffFilter,
    Callback = makeMultiFilterCallback("SpawnBuffFilter", BuffOptions),
}, "SpawnBuffFilter")
SpawnSection:Label({Text = "Buys directly from world pack stands.\nRobux-only packs are excluded.\nBoth filters are AND'd together; leave one empty\nto match on the other alone."})
local spawnStatusLabel = SpawnSection:Label({Text = "Idle"})

local SellEquipSection = Tabs.Packs:Section({Side = "Right"})
SellEquipSection:Header({Text = "Auto Sell Packs"})
SellEquipSection:Toggle({
    Name = "Auto Sell Packs",
    Default = getgenv().AutoSellPacksEnabled,
    Callback = function(value) getgenv().AutoSellPacksEnabled = value; saveState() end,
}, "AutoSellPacksEnabled")
SellEquipSection:Label({Text = "Sells all unopened packs in your inventory\n(does not touch cards)."})
local sellStatusLabel = SellEquipSection:Label({Text = "Idle"})
SellEquipSection:Header({Text = "Auto Equip Best Card"})
SellEquipSection:Toggle({
    Name = "Auto Equip Best Card",
    Default = getgenv().AutoEquipBestEnabled,
    Callback = function(value) getgenv().AutoEquipBestEnabled = value; saveState() end,
}, "AutoEquipBestEnabled")

-- ----- Rewards Tab -----
local RewardsSection = Tabs.Rewards:Section({Side = "Left"})
RewardsSection:Header({Text = "Auto Claim Daily Reward"})
RewardsSection:Toggle({
    Name = "Auto Claim Daily Reward",
    Default = getgenv().AutoClaimDailyEnabled,
    Callback = function(value) getgenv().AutoClaimDailyEnabled = value; saveState() end,
}, "AutoClaimDailyEnabled")
RewardsSection:Header({Text = "Auto Claim Playtime Rewards"})
RewardsSection:Toggle({
    Name = "Auto Claim Playtime Rewards",
    Default = getgenv().AutoClaimPlaytimeEnabled,
    Callback = function(value) getgenv().AutoClaimPlaytimeEnabled = value; saveState() end,
}, "AutoClaimPlaytimeEnabled")
RewardsSection:Label({Text = "Claims each ready reward individually (the free path).\nThe in-game \"Claim All\" button is a Robux prompt --\nnot used here."})
local playtimeStatusLabel = RewardsSection:Label({Text = "Idle"})
RewardsSection:Header({Text = "Auto Claim Offline Reward"})
RewardsSection:Toggle({
    Name = "Auto Claim Offline Reward",
    Default = getgenv().AutoClaimOfflineEnabled,
    Callback = function(value) getgenv().AutoClaimOfflineEnabled = value; saveState() end,
}, "AutoClaimOfflineEnabled")

-- ----- Misc Tab -----
local MiscSection = Tabs.Misc:Section({Side = "Left"})
MiscSection:Header({Text = "Misc"})
MiscSection:Toggle({
    Name = "Anti-AFK",
    Default = getgenv().AntiAFKEnabled,
    Callback = function(value) getgenv().AntiAFKEnabled = value; saveState() end,
}, "AntiAFKEnabled")
MiscSection:Toggle({
    Name = "Auto Reconnect",
    Default = getgenv().AutoReconnectEnabled,
    Callback = function(value) getgenv().AutoReconnectEnabled = value; saveState() end,
}, "AutoReconnectEnabled")
MiscSection:Keybind({
    Name = "Show/Hide UI",
    Blacklist = false,
    Default = Enum.KeyCode.RightShift,
    Callback = function() pcall(function() Window:SetState(not Window:GetState()) end) end,
}, "CardToggleUIKeybind")

-- ----- Settings Tab -----
local SettingsSection = Tabs.Settings:Section({Side = "Left"})
SettingsSection:Header({Text = "Auto Save"})
SettingsSection:Label({Text = "All toggles save automatically to:\n" .. SAVE_FILE})

-- ===== Background loops =====
task.spawn(function()
    while getgenv().__CardGen == myGen do
        pcall(doAutoCarry)
        pcall(function() carryStatusLabel:UpdateName(carryStatusText) end)
        task.wait(0.6)
    end
end)

task.spawn(function()
    while getgenv().__CardGen == myGen do
        pcall(doAutoSpawnPack)
        pcall(function() spawnStatusLabel:UpdateName(spawnStatusText) end)
        task.wait(1.5)
    end
end)

task.spawn(function()
    while getgenv().__CardGen == myGen do
        pcall(doAutoSellPacks)
        pcall(function() sellStatusLabel:UpdateName(sellStatusText) end)
        task.wait(5)
    end
end)

task.spawn(function()
    while getgenv().__CardGen == myGen do
        pcall(doAutoEquipBest)
        task.wait(5)
    end
end)

task.spawn(function()
    while getgenv().__CardGen == myGen do
        pcall(doAutoClaimDaily)
        task.wait(60)
    end
end)

task.spawn(function()
    while getgenv().__CardGen == myGen do
        pcall(doAutoClaimPlaytime)
        pcall(function() playtimeStatusLabel:UpdateName(playtimeStatusText) end)
        task.wait(20)
    end
end)

task.spawn(function()
    while getgenv().__CardGen == myGen do
        pcall(doAutoClaimOffline)
        task.wait(60)
    end
end)

getgenv().__CardWindow = Window
Tabs.Conveyor:Select()
