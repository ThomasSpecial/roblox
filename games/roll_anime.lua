-- Roll Anime to Fight! Automation v2.1
-- อัพเดท: + Mutation Cursed, + Auto Claim BP (tier rewards), + Auto Claim BP Quest, Misc -> Settings
getgenv().__RAG = (getgenv().__RAG or 0) + 1
local myGen = getgenv().__RAG
local SESSION_START = os.clock()

pcall(function()
    if getgenv().__RAWindow then getgenv().__RAWindow:Unload() end
end)

print("[RollAnime] Starting (gen " .. myGen .. ")...")

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local LocalPlayer = Players.LocalPlayer

local CharRemotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Characters")
local Roll = CharRemotes:WaitForChild("Roll")
local Buy = CharRemotes:WaitForChild("Buy")
local UpdateInventory = CharRemotes:WaitForChild("UpdateInventory")
local UpgradeRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Upgrade")
local FightStart = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Fight"):WaitForChild("Start")
local SpinRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SpinWheel"):WaitForChild("Spin")

-- Battlepass tier rewards + quests live under ReplicatedStorage.Modules.Battlepass,
-- NOT ReplicatedStorage.Remotes (that was tried first and hangs -- there is no
-- Quest namespace under Remotes at all). Confirmed live by reading the game's
-- own BattlepassClient LocalScript (MainUI.Frames.Battlepass.BattlepassClient):
--   Modules.Battlepass.Claim:FireServer(level, track)          -- track: "Free"/"Premium"
--   Modules.Battlepass.BattlepassQuest.GetQuestData:InvokeServer() -> {Daily=[...], Weekly=[...]}
--   Modules.Battlepass.BattlepassQuest.ClaimQuest:FireServer(category, questId)
-- All bounded WaitForChild + nil-safe callers so a missing module in some
-- other game/place doesn't hang the whole script the way the old guess did.
local BattlepassModule = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Battlepass", 5)
local BPClaim, BPQuestGetData, BPQuestClaim, BattlepassReward
if BattlepassModule then
    BPClaim = BattlepassModule:WaitForChild("Claim", 5)
    local BPQuestFolder = BattlepassModule:WaitForChild("BattlepassQuest", 5)
    if BPQuestFolder then
        BPQuestGetData = BPQuestFolder:WaitForChild("GetQuestData", 5)
        BPQuestClaim = BPQuestFolder:WaitForChild("ClaimQuest", 5)
    end
    local rewardModule = BattlepassModule:FindFirstChild("BattlepassReward")
    if rewardModule then
        local ok, mod = pcall(require, rewardModule)
        if ok then BattlepassReward = mod end
    end
end

local CharactersInfo = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Characters"):WaitForChild("CharactersInfo"))
local UpgradesInfo = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Shared"):WaitForChild("UpgradesInfo"))
local StatsHandler = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Shared"):WaitForChild("StatsHandler"))
local SpinWheelHandler = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SpinWheel"):WaitForChild("SpinWheelHandler"))
local DataClient = require(ReplicatedStorage:WaitForChild("Data"):WaitForChild("DataService")).client
print("[RollAnime] Remotes/modules ready, waiting for player data...")

-- DataClient:waitForData() has no built-in timeout and isn't a native
-- WaitForChild, so Roblox's own "Infinite yield possible" watchdog never
-- fires for it -- confirmed live: a session got stuck here with zero warning
-- in console, script never reached the UI. Racing it against a 15s timeout
-- so the rest of the script (and the UI) still builds even if data hasn't
-- arrived yet; the background task keeps waiting and DataClient:get(...)
-- calls elsewhere will just see stale/empty results until it resolves.
do
    local dataReady = false
    task.spawn(function()
        DataClient:waitForData()
        dataReady = true
    end)
    local waited = 0
    while not dataReady and waited < 15 do
        task.wait(0.25)
        waited += 0.25
    end
    if dataReady then
        print("[RollAnime] Player data ready (" .. string.format("%.1f", waited) .. "s)")
    else
        warn("[RollAnime] DataClient:waitForData() still not done after 15s -- continuing without blocking further; some stats may show 0/empty until it resolves")
    end
end

local UPGRADE_KEYS = {"Gold", "Luck", "Slots", "Inventory"}
local UPGRADE_LABELS = {Gold = "Gold", Luck = "Luck", Slots = "Slot", Inventory = "Inventory"}
local RARITIES = {"Common", "Rare", "Epic", "Legendary", "Mythic", "Secret", "God", "Limited"}

-- Cursed เพิ่มเข้ามาใหม่ใน v2.0 (Chance=0, event-only, Damage=6.5x)
local MUTATIONS = {"None", "Gold", "Diamond", "Demon", "Destroyer", "Astronaut", "Hollow", "Slayer", "Cursed"}

-- ===== Character catalog =====
local CHAR_INFO = {}
local CHAR_BASE_STATS = {}
local RARITY_CHARACTERS = {}
local CHAR_DISPLAY_NAMES = {}
local CHAR_NAME_FROM_DISPLAY = {}
local RARITY_CHARACTERS_DISPLAY = {}

for _, r in ipairs(RARITIES) do RARITY_CHARACTERS[r] = {} end
for _, entry in pairs(CharactersInfo.Characters) do
    if entry.Name and entry.Rarity then
        CHAR_INFO[entry.Name] = {Rarity = entry.Rarity, Price = tonumber(entry.Price) or 0}
        CHAR_BASE_STATS[entry.Name] = entry
        if RARITY_CHARACTERS[entry.Rarity] then
            table.insert(RARITY_CHARACTERS[entry.Rarity], entry.Name)
        end
        local display = entry.DisplayName and tostring(entry.DisplayName) or entry.Name
        CHAR_DISPLAY_NAMES[entry.Name] = display
        if not CHAR_NAME_FROM_DISPLAY[display] then
            CHAR_NAME_FROM_DISPLAY[display] = entry.Name
        end
    end
end
for _, r in ipairs(RARITIES) do
    table.sort(RARITY_CHARACTERS[r])
    RARITY_CHARACTERS_DISPLAY[r] = {}
    for _, name in ipairs(RARITY_CHARACTERS[r]) do
        table.insert(RARITY_CHARACTERS_DISPLAY[r], CHAR_DISPLAY_NAMES[name] or name)
    end
    table.sort(RARITY_CHARACTERS_DISPLAY[r])
end

-- ===== Auto Save =====
local SAVE_FOLDER = "RollAnimeAutomation"
local SAVE_FILE = SAVE_FOLDER .. "/state.json"
pcall(function() if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end end)
local PERSIST_KEYS = {
    "AutoSummonEnabled", "SummonDelay", "AntiAFKEnabled", "AutoReconnectEnabled",
    "AutoBuyEnabled", "MinPrice", "MaxPrice", "KeepGold", "RarityRules",
    "AutoUpgradeGold", "AutoUpgradeLuck", "AutoUpgradeSlots", "AutoUpgradeInventory",
    "AutoFightStart", "StartAtWave", "StopAtWave", "MaxGameSpeedEnabled",
    "AutoEquipBestEnabled", "EquipFilterBy", "ReplaceWeakerSlots", "AutoSpinWheelEnabled",
    "FPSBoostEnabled", "RemoveOtherBaseEnabled", "BypassEnabled",
    "AutoClaimBPEnabled", "AutoClaimBPQuestEnabled",
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

if getgenv().AutoSummonEnabled == nil then getgenv().AutoSummonEnabled = false end
if getgenv().SummonDelay == nil then getgenv().SummonDelay = 2.2 end
if getgenv().AntiAFKEnabled == nil then getgenv().AntiAFKEnabled = true end
if getgenv().AutoReconnectEnabled == nil then getgenv().AutoReconnectEnabled = true end
if getgenv().AutoBuyEnabled == nil then getgenv().AutoBuyEnabled = false end
if getgenv().MinPrice == nil then getgenv().MinPrice = 0 end
if getgenv().MaxPrice == nil then getgenv().MaxPrice = 0 end
if getgenv().KeepGold == nil then getgenv().KeepGold = 0 end
if getgenv().RarityRules == nil then getgenv().RarityRules = {} end
for _, r in ipairs(RARITIES) do
    if getgenv().RarityRules[r] == nil then
        getgenv().RarityRules[r] = {enabled = false, characters = {}, mutations = {}}
    end
end
if getgenv().AutoUpgradeGold == nil then getgenv().AutoUpgradeGold = false end
if getgenv().AutoUpgradeLuck == nil then getgenv().AutoUpgradeLuck = false end
if getgenv().AutoUpgradeSlots == nil then getgenv().AutoUpgradeSlots = false end
if getgenv().AutoUpgradeInventory == nil then getgenv().AutoUpgradeInventory = false end
if getgenv().AutoFightStart == nil then getgenv().AutoFightStart = false end
if getgenv().StartAtWave == nil then getgenv().StartAtWave = 0 end
if getgenv().StopAtWave == nil then getgenv().StopAtWave = 0 end
if getgenv().MaxGameSpeedEnabled == nil then getgenv().MaxGameSpeedEnabled = false end
if getgenv().AutoEquipBestEnabled == nil then getgenv().AutoEquipBestEnabled = false end
if getgenv().EquipFilterBy == nil then getgenv().EquipFilterBy = "Damage" end
if getgenv().ReplaceWeakerSlots == nil then getgenv().ReplaceWeakerSlots = false end
if getgenv().AutoSpinWheelEnabled == nil then getgenv().AutoSpinWheelEnabled = false end
if getgenv().FPSBoostEnabled == nil then getgenv().FPSBoostEnabled = false end
if getgenv().RemoveOtherBaseEnabled == nil then getgenv().RemoveOtherBaseEnabled = false end
if getgenv().BypassEnabled == nil then getgenv().BypassEnabled = false end
if getgenv().AutoClaimBPEnabled == nil then getgenv().AutoClaimBPEnabled = false end
if getgenv().AutoClaimBPQuestEnabled == nil then getgenv().AutoClaimBPQuestEnabled = false end

-- ===== Helpers =====
local function getGold()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    local gold = ls and ls:FindFirstChild("💰 Gold")
    return gold and gold.Value or 0
end

local function getMyPlot()
    local plots = workspace:FindFirstChild("Plots")
    if not plots then return nil end
    for _, plot in ipairs(plots:GetChildren()) do
        if plot:GetAttribute("Owner") == LocalPlayer.Name then return plot end
    end
    return nil
end

local function getRollPrompt(plot)
    local rollModel = plot and plot:FindFirstChild("Roll")
    return rollModel and rollModel:FindFirstChild("RollPrompt", true)
end

local function getHRP()
    local character = LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function getExecutorName()
    local ok, name, version = pcall(function() return identifyexecutor() end)
    if ok and name then
        return tostring(name) .. (version and (" " .. tostring(version)) or "")
    end
    return "Unknown"
end

local function getGameName()
    local ok, info = pcall(function()
        return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
    end)
    if ok and info and info.Name then return info.Name end
    return "Unknown"
end

local function formatSessionTime()
    local total = math.floor(os.clock() - SESSION_START)
    local h = math.floor(total / 3600)
    local m = math.floor((total % 3600) / 60)
    local s = total % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function getJoinScript()
    return string.format(
        'game:GetService("TeleportService"):TeleportToPlaceInstance(%d, "%s", game:GetService("Players").LocalPlayer)',
        game.PlaceId, tostring(game.JobId)
    )
end

-- ===== Auto Summon =====
-- Teleport ครั้งเดียวตอนออกนอก SUMMON_RANGE studs จาก prompt แล้วค้างอยู่ตรงนั้น
-- ไม่ teleport กลับ-ไปทุก loop -- เวอร์ชันก่อนหน้า (teleport ไปเด้งกลับทุกรอบ
-- SummonDelay) ทำให้ตัวละครกระตุก/เด้งไปมาให้เห็นชัดทุก 0.5-3s ตามที่ผู้ใช้แจ้ง
-- ปัญหานี้เคยแก้แล้วรอบก่อน แต่หลุดกลับไปเป็นเวอร์ชันเดิมตอน sync จาก roll_anime.lua
local SUMMON_RANGE = 8  -- studs -- ถ้าออกกว่านี้ค่อย pull กลับ
local summonStandbyPos = nil  -- CFrame ที่ยืนอยู่หน้าแท่น
local summonStatusText = "Idle"

local function getSummonStandbyPos(promptPart)
    -- ยืนด้านหน้าแท่น ห่าง 3 studs บวก 3 สูง
    return CFrame.new(promptPart.Position + Vector3.new(0, 3, 3))
end

local function ensureNearPrompt(hrp, promptPart)
    local dist = (hrp.Position - promptPart.Position).Magnitude
    if dist > SUMMON_RANGE then
        local target = getSummonStandbyPos(promptPart)
        pcall(function() hrp.CFrame = target end)
        summonStandbyPos = target
        task.wait(0.15)
        return true -- teleported
    end
    return false
end

local function doAutoSummon()
    if not getgenv().AutoSummonEnabled then
        summonStatusText = "Idle"
        summonStandbyPos = nil
        return
    end
    local plot = getMyPlot()
    if not plot then summonStatusText = "Could not find your plot"; return end
    local prompt = getRollPrompt(plot)
    if not prompt then summonStatusText = "Could not find the Summon prompt"; return end
    local hrp = getHRP()
    if not hrp then return end
    local promptPart = prompt.Parent

    -- ครั้งแรก หรือออกนอก range: pull กลับครั้งเดียว แล้วค้างอยู่
    ensureNearPrompt(hrp, promptPart)

    if prompt.Enabled then
        pcall(function() fireproximityprompt(prompt) end)
        summonStatusText = "Rolled"
    else
        summonStatusText = "Near prompt — waiting"
    end
end

-- ===== Auto Buy =====
local function shouldBuy(slotData)
    if not (slotData and slotData.Name and slotData.Rarity) then return false end
    if slotData.Purchased then return false end
    local rules = getgenv().RarityRules[slotData.Rarity]
    if not rules or not rules.enabled then return false end
    if rules.characters and #rules.characters > 0 and not table.find(rules.characters, slotData.Name) then
        return false
    end
    local mutation = slotData.Mutation or "None"
    if rules.mutations and #rules.mutations > 0 and not table.find(rules.mutations, mutation) then
        return false
    end
    local price = tonumber(slotData.Price) or 0
    local minPrice = tonumber(getgenv().MinPrice) or 0
    local maxPrice = tonumber(getgenv().MaxPrice) or 0
    if minPrice > 0 and price < minPrice then return false end
    if maxPrice > 0 and price > maxPrice then return false end
    local keepGold = tonumber(getgenv().KeepGold) or 0
    if keepGold > 0 and (getGold() - price) < keepGold then return false end
    return true
end

local buyStatusText = "Idle"
if not getgenv().__RARollHooked then
    getgenv().__RARollHooked = true
    Roll.OnClientEvent:Connect(function(player, base, characters, movement, rollId)
        if player ~= LocalPlayer then return end
        if not getgenv().AutoBuyEnabled then return end
        local bought = 0
        for slotIndex, slotData in pairs(characters) do
            if shouldBuy(slotData) then
                pcall(function() Buy:FireServer(rollId, slotIndex) end)
                bought += 1
            end
        end
        buyStatusText = bought > 0 and ("Bought " .. bought .. " matching character(s)") or "Watching for matches..."
        pcall(function()
            if getgenv().__RABuyStatusLabel then getgenv().__RABuyStatusLabel:UpdateName(buyStatusText) end
        end)
    end)
end

-- ===== Auto Claim Battlepass (tier rewards) =====
-- Level is derived the same way the game's own getLevelInfo() does: walk
-- BattlepassReward.Rewards[1..MaxLevel], each entry's .EXP is the cumulative
-- cost to reach that level, current level = how many thresholds current Exp
-- clears. Claim:FireServer(level, track) is fired for every level up to that
-- on the Free track, and additionally on Premium if data.Premium.Owned is
-- true for the current season -- the server re-validates both the level and
-- ownership itself, so firing for an unclaimed-but-locked level is a no-op,
-- not an error.
local bpStatusText = "Idle"
local bpClaimedCount = 0

local function getBPLevel(exp)
    if not BattlepassReward then return 0 end
    exp = tonumber(exp) or 0
    local maxLevel = tonumber(BattlepassReward.Config.MaxLevel) or 30
    local level, cumulative = 0, 0
    for i = 1, maxLevel do
        local reward = BattlepassReward.Rewards[i]
        local need = reward and (tonumber(reward.EXP) or 0) or math.huge
        if cumulative + need > exp then break end
        cumulative += need
        level = i
    end
    return level
end

local function doAutoClaimBP()
    if not getgenv().AutoClaimBPEnabled then bpStatusText = "Idle"; return end
    if not (BPClaim and BattlepassReward) then
        bpStatusText = "Not available in this game"
        return
    end
    local ok, data = pcall(function() return DataClient:get("Battlepass") end)
    if not ok or type(data) ~= "table" then bpStatusText = "No data"; return end

    local claimedMap = data.Claimed or {}
    local freeClaimed = claimedMap.Free or {}
    local premiumClaimed = claimedMap.Premium or {}
    local premiumInfo = data.Premium or {}
    local premiumOwned = premiumInfo.Owned == true
        and tonumber(premiumInfo.Season) == (tonumber(BattlepassReward.Config.Season) or 1)
    local level = getBPLevel(data.Exp)

    local claimed = 0
    for i = 1, level do
        if freeClaimed[tostring(i)] ~= true then
            local okClaim = pcall(function() BPClaim:FireServer(i, "Free") end)
            if okClaim then claimed += 1; bpClaimedCount += 1; task.wait(0.15) end
        end
        if premiumOwned and premiumClaimed[tostring(i)] ~= true then
            local okClaim = pcall(function() BPClaim:FireServer(i, "Premium") end)
            if okClaim then claimed += 1; bpClaimedCount += 1; task.wait(0.15) end
        end
    end

    bpStatusText = claimed > 0
        and ("Claimed " .. claimed .. " reward(s) | Total: " .. bpClaimedCount .. " | Level " .. level)
        or ("Nothing to claim | Level " .. level)
end

-- ===== Auto Claim Battlepass Quest =====
-- GetQuestData:InvokeServer() -> {Daily=[...], Weekly=[...]}, each quest has
-- ID/Name/Progress/Requirement/Reward/Completed/Claimed. ClaimQuest:FireServer
-- (category, questId) -- category is literally "Daily" or "Weekly", matching
-- the QuestCategory/QuestId attributes the game's own quest-card buttons set
-- on themselves before firing this exact same remote.
local bpQuestStatusText = "Idle"
local bpQuestClaimedCount = 0

local function doAutoClaimBPQuest()
    if not getgenv().AutoClaimBPQuestEnabled then bpQuestStatusText = "Idle"; return end
    if not (BPQuestGetData and BPQuestClaim) then
        bpQuestStatusText = "Not available in this game"
        return
    end
    local ok, questData = pcall(function() return BPQuestGetData:InvokeServer() end)
    if not ok or type(questData) ~= "table" then bpQuestStatusText = "Error fetching quests"; return end

    local claimed = 0
    for _, cat in ipairs({"Daily", "Weekly"}) do
        local quests = questData[cat]
        if type(quests) == "table" then
            for _, q in ipairs(quests) do
                if type(q) == "table" and q.ID then
                    local progress = tonumber(q.Progress) or 0
                    local requirement = tonumber(q.Requirement) or 1
                    local completed = q.Completed == true or progress >= requirement
                    if completed and q.Claimed ~= true then
                        local okClaim = pcall(function() BPQuestClaim:FireServer(cat, q.ID) end)
                        if okClaim then
                            claimed += 1
                            bpQuestClaimedCount += 1
                            task.wait(0.3)
                        end
                    end
                end
            end
        end
    end

    bpQuestStatusText = claimed > 0
        and ("Claimed " .. claimed .. " quest(s) | Total: " .. bpQuestClaimedCount)
        or "No claimable quests"
end

-- ===== Auto Upgrade =====
local UPGRADE_FLAG_KEYS = {Gold = "AutoUpgradeGold", Luck = "AutoUpgradeLuck", Slots = "AutoUpgradeSlots", Inventory = "AutoUpgradeInventory"}
local upgradeStatusText = {}
local lastUpgradeAttempt = {}
local function getUpgradeLevel(key)
    local v = DataClient:get({"Upgrades", key})
    if v == nil then v = UpgradesInfo.Upgrades.Default[key] end
    return v
end
local function refreshUpgradeStatus(key)
    local level = getUpgradeLevel(key)
    local maxed = UpgradesInfo.IsMaxed(key, level)
    local displayLevel = UpgradesInfo.GetDisplayLevel(key, level)
    upgradeStatusText[key] = UPGRADE_LABELS[key] .. " : " .. (maxed and "MAX" or ("Lv." .. tostring(displayLevel)))
end
local function doAutoUpgrade()
    for _, key in ipairs(UPGRADE_KEYS) do
        refreshUpgradeStatus(key)
        if getgenv()[UPGRADE_FLAG_KEYS[key]] then
            local level = getUpgradeLevel(key)
            if not UpgradesInfo.IsMaxed(key, level) then
                local price = UpgradesInfo.GetPrice(key, level)
                local now = os.clock()
                if price and getGold() >= price and (now - (lastUpgradeAttempt[key] or 0)) > 1.5 then
                    lastUpgradeAttempt[key] = now
                    pcall(function() UpgradeRemote:FireServer("Gold", key) end)
                end
            end
        end
    end
end

-- ===== Fight Control =====
local fightStatusText = "Idle"
local function doAutoFight()
    local plot = getMyPlot()
    if not plot then return end
    local running = plot:GetAttribute("FightRunning") == true
    local wave = tonumber(LocalPlayer:GetAttribute("FightWave")) or 0
    local startAtWave = tonumber(getgenv().StartAtWave) or 0
    local stopAtWave = tonumber(getgenv().StopAtWave) or 0
    if stopAtWave > 0 and running and wave >= stopAtWave then
        pcall(function() FightStart:FireServer("Stop") end)
        fightStatusText = "Stopped -- wave " .. wave .. " reached Stop target"
        return
    end
    if not getgenv().AutoFightStart then
        fightStatusText = running and ("Fighting (wave " .. wave .. ")") or "Idle"
        return
    end
    if running then fightStatusText = "Fighting (wave " .. wave .. ")"; return end
    if startAtWave > 0 and wave < startAtWave then
        fightStatusText = "Waiting -- start manually once to reach wave " .. startAtWave
        return
    end
    pcall(function() FightStart:FireServer("Start") end)
    fightStatusText = "Starting fight..."
end

-- ===== Max Game Speed =====
local SPEED_MULTIPLIER = 10
local function ensureMaxGameSpeed()
    if not getgenv().MaxGameSpeedEnabled then return end
    local plot = getMyPlot()
    if not plot or plot:GetAttribute("FightRunning") ~= true then return end
    local current = tonumber(plot:GetAttribute("FightFastForwardSpeed")) or 1
    if current ~= SPEED_MULTIPLIER then
        plot:SetAttribute("FightFastForwardSpeed", SPEED_MULTIPLIER)
    end
end

-- ===== Bypass =====
-- Luck2x/SuperLuck/UltraLuck -> RandomGenerator (verified client-side)
-- Mutation2x -> MutationInfo (verified client-side)
-- FightFastForwardSpeed -> CustomAttackModules + AttackModules.Loader (plot attribute, no server clamp)
-- Cursed mutation เป็น event-only (Chance=0 ใน MutationInfo) ไม่มี attribute ที่ set ได้
getgenv().__BypassLoop = false
local function toggleBypass(enabled)
    if enabled then
        if getgenv().__BypassLoop then return end
        getgenv().BypassEnabled = true
        getgenv().__BypassLoop = true
        task.spawn(function()
            while getgenv().__BypassLoop and getgenv().__RAG == myGen do
                LocalPlayer:SetAttribute("Luck2x", true)
                LocalPlayer:SetAttribute("SuperLuck", true)
                LocalPlayer:SetAttribute("UltraLuck", true)
                LocalPlayer:SetAttribute("Mutation2x", true)
                local plot = getMyPlot()
                if plot then plot:SetAttribute("FightFastForwardSpeed", SPEED_MULTIPLIER) end
                task.wait(1)
            end
        end)
    else
        getgenv().__BypassLoop = false
        getgenv().BypassEnabled = false
        LocalPlayer:SetAttribute("Luck2x", false)
        LocalPlayer:SetAttribute("SuperLuck", false)
        LocalPlayer:SetAttribute("UltraLuck", false)
        LocalPlayer:SetAttribute("Mutation2x", false)
        local plot = getMyPlot()
        if plot then plot:SetAttribute("FightFastForwardSpeed", 1) end
    end
end

-- ===== Auto Equip Best =====
local equipStatusText = "Idle"
local function doAutoEquipBest()
    if not getgenv().AutoEquipBestEnabled then equipStatusText = "Idle"; return end
    local plot = getMyPlot()
    if plot and plot:GetAttribute("FightRunning") == true then
        equipStatusText = "Waiting for fight to end (roster locked mid-fight)"
        return
    end
    local inv = DataClient:get("Inventory") or {}
    local filterBy = (getgenv().EquipFilterBy == "Health") and "Health" or "Attack"
    local maxSlots = tonumber(DataClient:get({"Upgrades", "Slots"})) or UpgradesInfo.Upgrades.Default.Slots
    local scored = {}
    for _, unit in ipairs(inv) do
        local base = CHAR_BASE_STATS[unit.Name]
        if base then
            local ok, stats = pcall(function() return StatsHandler.GetStats(base, unit, nil, nil) end)
            if ok and stats then
                table.insert(scored, {unit = unit, score = stats[filterBy] or 0})
            end
        end
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    local changed = 0
    if getgenv().ReplaceWeakerSlots then
        local targetSet = {}
        for i = 1, math.min(maxSlots, #scored) do targetSet[scored[i].unit.UUID] = true end
        for _, s in ipairs(scored) do
            local shouldBeEquipped = targetSet[s.unit.UUID] == true
            local isEquipped = s.unit.Equipped == true
            if shouldBeEquipped ~= isEquipped then
                pcall(function() UpdateInventory:FireServer("ToggleHotbar", s.unit.UUID) end)
                changed += 1
                task.wait(0.1)
            end
        end
    else
        local equippedCount = 0
        for _, s in ipairs(scored) do if s.unit.Equipped then equippedCount += 1 end end
        local freeSlots = maxSlots - equippedCount
        if freeSlots > 0 then
            for _, s in ipairs(scored) do
                if freeSlots <= 0 then break end
                if not s.unit.Equipped then
                    pcall(function() UpdateInventory:FireServer("ToggleHotbar", s.unit.UUID) end)
                    changed += 1
                    freeSlots -= 1
                    task.wait(0.1)
                end
            end
        end
    end
    equipStatusText = changed > 0 and ("Equipped/swapped " .. changed .. " unit(s)") or "Team already optimal"
end

-- ===== Auto Spin Wheel =====
local function formatHMS(totalSeconds)
    local total = math.max(0, math.floor(totalSeconds))
    return string.format("%02d:%02d:%02d", math.floor(total/3600), math.floor((total%3600)/60), total%60)
end
local spinStatusText = "Free Spin in ..."
local function doAutoSpinWheel()
    local restartHours = tonumber(SpinWheelHandler.Config.Restart) or 4
    local interval = math.max(1, restartHours) * 3600
    local lastClaim = tonumber(DataClient:get({"SpinLastClaim"})) or tonumber(DataClient:get({"SpinRechargeAt"})) or os.time()
    local elapsed = os.time() - lastClaim
    local remaining = interval - (elapsed % interval)
    if elapsed < 0 then remaining = interval end
    if remaining >= interval then remaining = 0 end
    spinStatusText = "Free Spin in " .. formatHMS(remaining)
    if getgenv().AutoSpinWheelEnabled then
        local spinCount = tonumber(DataClient:get({"Spin"})) or 0
        if spinCount > 0 then pcall(function() SpinRemote:FireServer("Spin") end) end
    end
end

-- ===== Performance =====
local function applyFPSBoost(enabled)
    pcall(function() LocalPlayer:SetAttribute("FPSBoost", enabled) end)
end

local otherPlotsDetached = {}
local function applyRemoveOtherBase(enabled)
    local plots = workspace:FindFirstChild("Plots")
    if not plots then return end
    if enabled then
        for _, plot in ipairs(plots:GetChildren()) do
            if plot:GetAttribute("Owner") ~= LocalPlayer.Name and not otherPlotsDetached[plot] then
                otherPlotsDetached[plot] = true
                pcall(function() plot.Parent = nil end)
            end
        end
    else
        for plot in pairs(otherPlotsDetached) do pcall(function() plot.Parent = plots end) end
        otherPlotsDetached = {}
    end
end

-- ===== Anti-AFK =====
LocalPlayer.Idled:Connect(function()
    if not getgenv().AntiAFKEnabled then return end
    pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
end)

-- ===== Auto Reconnect =====
if not getgenv().__RAReconnectHooked then
    getgenv().__RAReconnectHooked = true
    Players.PlayerRemoving:Connect(function(player)
        if player == LocalPlayer and getgenv().AutoReconnectEnabled then
            pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
        end
    end)
end

-- ===== UI (Maclib) =====
print("[RollAnime] Loading MacLib...")
local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
print("[RollAnime] MacLib loaded, building window...")
local Window = MacLib:Window({
    Title = "Roll Anime to Fight! Automation",
    Subtitle = "v2.1 — +Battlepass",
    DragStyle = 1,
    ShowUserInfo = true,
    AcrylicBlur = false,
})

local TabGroup = Window:TabGroup()
local Tabs = {
    Info       = TabGroup:Tab({Name = "Info",       Image = "rbxassetid://10723415903"}),
    Summon     = TabGroup:Tab({Name = "Summon",     Image = "rbxassetid://10723343321"}),
    Buy        = TabGroup:Tab({Name = "Buy",        Image = "rbxassetid://10734952273"}),
    Fight      = TabGroup:Tab({Name = "Fight",      Image = "rbxassetid://10734975692"}),
    Battlepass = TabGroup:Tab({Name = "Battlepass", Image = "rbxassetid://10747363465"}),
    Upgrade    = TabGroup:Tab({Name = "Upgrade",    Image = "rbxassetid://10747363465"}),
    Settings   = TabGroup:Tab({Name = "Settings",   Image = "rbxassetid://10734950309"}),
}

-- ----- Info Tab -----
local InfoBox1 = Tabs.Info:Section({Side = "Left"})
InfoBox1:Header({Text = "User Info"})
InfoBox1:Label({Text = "User : " .. LocalPlayer.Name})
InfoBox1:Label({Text = "Status : Free"})
InfoBox1:Label({Text = "Executor : " .. getExecutorName()})

local InfoBox2 = Tabs.Info:Section({Side = "Right"})
InfoBox2:Header({Text = "Game Info"})
InfoBox2:Label({Text = "Game : " .. getGameName()})
InfoBox2:Label({Text = "PlaceID : " .. tostring(game.PlaceId)})
local sessionTimeLabel = InfoBox2:Label({Text = "SessionTime : " .. formatSessionTime()})
InfoBox2:Label({Text = "Server : " .. tostring(game.JobId)})
InfoBox2:Button({Name = "Copy Join Script (JobID)", Callback = function()
    pcall(function() setclipboard(getJoinScript()) end)
end})

local InfoBox3 = Tabs.Info:Section({Side = "Left"})
InfoBox3:Header({Text = "Features"})
InfoBox3:Label({Text = "* Auto Summon (rolls)"})
InfoBox3:Label({Text = "* Auto Buy — filter by rarity / DisplayName / Mutation\n  รวม Cursed mutation ใหม่"})
InfoBox3:Label({Text = "* Auto Upgrade (Gold / Luck / Slot / Inventory)"})
InfoBox3:Label({Text = "* Auto Claim Battlepass (tier rewards, Free+Premium)"})
InfoBox3:Label({Text = "* Auto Claim Battlepass Quest (Daily + Weekly)"})
InfoBox3:Label({Text = "* Anti-AFK / Auto Reconnect / Auto Save"})
InfoBox3:Label({Text = "* Bypass (Luck+14 / Mutation2x / Speed10x)"})

local InfoBox4 = Tabs.Info:Section({Side = "Right"})
InfoBox4:Header({Text = "Social"})
InfoBox4:Button({Name = "Copy Discord URL", Callback = function()
    pcall(function() setclipboard("http://discord.gg/frosthub") end)
end})
InfoBox4:Button({Name = "Copy Rscripts URL", Callback = function()
    pcall(function() setclipboard("https://rscripts.net/") end)
end})

-- ----- Summon Tab -----
local SummonSection = Tabs.Summon:Section({Side = "Left"})
SummonSection:Header({Text = "Auto Summon"})
SummonSection:Toggle({
    Name = "Auto Summon", Default = getgenv().AutoSummonEnabled,
    Callback = function(v) getgenv().AutoSummonEnabled = v; saveState() end,
}, "AutoSummonEnabled")
SummonSection:Slider({
    Name = "Summon Delay (s)", Minimum = 0.5, Maximum = 3.0,
    Default = getgenv().SummonDelay, Precision = 2,
    Callback = function(v) getgenv().SummonDelay = v; saveState() end,
})
SummonSection:Label({Text = "Rolls only -- still needs a brief teleport to the\nSummon prompt. Buying is fully remote -- see Buy tab."})
local summonStatusLabel = SummonSection:Label({Text = "Idle"})

local SummonRight = Tabs.Summon:Section({Side = "Right"})
SummonRight:Header({Text = "Status"})
local goldStatusLabel = SummonRight:Label({Text = "Gold: ?"})

local SummonBox2 = Tabs.Summon:Section({Side = "Left"})
SummonBox2:Header({Text = "Auto Equip Best"})
SummonBox2:Toggle({
    Name = "Auto Equip Best", Default = getgenv().AutoEquipBestEnabled,
    Callback = function(v) getgenv().AutoEquipBestEnabled = v; saveState() end,
}, "AutoEquipBestEnabled")
local EQUIP_FILTER_OPTS = {"Damage", "Health"}
SummonBox2:Dropdown({
    Name = "Filter by", Multi = false, Options = EQUIP_FILTER_OPTS,
    Default = table.find(EQUIP_FILTER_OPTS, getgenv().EquipFilterBy) or 1,
    Callback = function(value)
        local picked = type(value) == "table" and value[1] or value
        getgenv().EquipFilterBy = table.find(EQUIP_FILTER_OPTS, picked) and picked or "Damage"
        saveState()
    end,
}, "EquipFilterBy")
SummonBox2:Toggle({
    Name = "Replace Weaker Slots", Default = getgenv().ReplaceWeakerSlots,
    Callback = function(v) getgenv().ReplaceWeakerSlots = v; saveState() end,
}, "ReplaceWeakerSlots")
SummonBox2:Label({Text = "OFF: fills empty slots only.\nON: swaps weaker equipped units too."})
local equipStatusLabel = SummonBox2:Label({Text = "Idle"})

local SummonBox3 = Tabs.Summon:Section({Side = "Right"})
SummonBox3:Header({Text = "Auto Spin Wheel"})
SummonBox3:Toggle({
    Name = "Auto Spin Wheel", Default = getgenv().AutoSpinWheelEnabled,
    Callback = function(v) getgenv().AutoSpinWheelEnabled = v; saveState() end,
}, "AutoSpinWheelEnabled")
SummonBox3:Label({Text = "Only uses free spin tickets -- never buys paid spins."})
local spinStatusLabel = SummonBox3:Label({Text = "Free Spin in ..."})

-- ----- Buy Tab -----
local BuyLeft = Tabs.Buy:Section({Side = "Left"})
BuyLeft:Header({Text = "Auto Buy"})
BuyLeft:Toggle({
    Name = "Auto Buy Summon", Default = getgenv().AutoBuyEnabled,
    Callback = function(v) getgenv().AutoBuyEnabled = v; saveState() end,
}, "AutoBuyEnabled")
BuyLeft:Input({
    Name = "Min Price (0 = any)", Placeholder = tostring(getgenv().MinPrice),
    AcceptedCharacters = "Numeric",
    Callback = function(t) getgenv().MinPrice = tonumber(t) or 0; saveState() end,
}, "MinPriceInput")
BuyLeft:Input({
    Name = "Max Price (0 = any)", Placeholder = tostring(getgenv().MaxPrice),
    AcceptedCharacters = "Numeric",
    Callback = function(t) getgenv().MaxPrice = tonumber(t) or 0; saveState() end,
}, "MaxPriceInput")
BuyLeft:Input({
    Name = "Keep Gold (0 = none)", Placeholder = tostring(getgenv().KeepGold),
    AcceptedCharacters = "Numeric",
    Callback = function(t) getgenv().KeepGold = tonumber(t) or 0; saveState() end,
}, "KeepGoldInput")
local buyStatusLabel = BuyLeft:Label({Text = "Idle"})
getgenv().__RABuyStatusLabel = buyStatusLabel

local RaritySection = Tabs.Buy:Section({Side = "Right"})
RaritySection:Header({Text = "Rarity Rules"})
RaritySection:Label({Text = "Dropdown แสดง DisplayName จริง\nแต่ logic ใช้ internal Name\nMutation filter รวม Cursed แล้ว"})

local enabledRaritiesDefault = {}
for _, r in ipairs(RARITIES) do
    if getgenv().RarityRules[r].enabled then table.insert(enabledRaritiesDefault, r) end
end

local RarityCharDropdowns, RarityMutDropdowns = {}, {}

RaritySection:Dropdown({
    Name = "Rarities", Multi = true, Search = true, Options = RARITIES,
    Default = enabledRaritiesDefault,
    Callback = function(value)
        local selectedSet = {}
        if type(value) == "table" then
            for k, v2 in pairs(value) do
                if type(k) == "string" and v2 == true then selectedSet[k] = true
                elseif type(k) == "number" and type(v2) == "string" then selectedSet[v2] = true end
            end
        end
        for _, r in ipairs(RARITIES) do
            local isSelected = selectedSet[r] == true
            getgenv().RarityRules[r].enabled = isSelected
            pcall(function()
                if RarityCharDropdowns[r] then RarityCharDropdowns[r]:SetVisibility(isSelected) end
                if RarityMutDropdowns[r] then RarityMutDropdowns[r]:SetVisibility(isSelected) end
            end)
        end
        saveState()
    end,
}, "RaritiesSelected")

for _, r in ipairs(RARITIES) do
    local charOptions = RARITY_CHARACTERS_DISPLAY[r]
    local charDefaultDisplay = {}
    for _, savedName in ipairs(getgenv().RarityRules[r].characters or {}) do
        table.insert(charDefaultDisplay, CHAR_DISPLAY_NAMES[savedName] or savedName)
    end

    local charDD = RaritySection:Dropdown({
        Name = r .. " Character",
        Multi = true, Search = true,
        Options = charOptions,
        Default = charDefaultDisplay,
        Callback = function(value)
            local selectedSet = {}
            if type(value) == "table" then
                for k, v2 in pairs(value) do
                    if type(k) == "string" and v2 == true then selectedSet[k] = true
                    elseif type(k) == "number" and type(v2) == "string" then selectedSet[v2] = true end
                end
            end
            local newList = {}
            for _, displayName in ipairs(charOptions) do
                if selectedSet[displayName] then
                    local realName = CHAR_NAME_FROM_DISPLAY[displayName] or displayName
                    table.insert(newList, realName)
                end
            end
            getgenv().RarityRules[r].characters = newList
            saveState()
        end,
    })
    pcall(function() charDD:SetVisibility(getgenv().RarityRules[r].enabled) end)
    RarityCharDropdowns[r] = charDD

    -- MUTATIONS list ตอนนี้รวม "Cursed" แล้ว
    local mutDD = RaritySection:Dropdown({
        Name = r .. " Mutations", Multi = true, Options = MUTATIONS,
        Default = getgenv().RarityRules[r].mutations,
        Callback = function(value)
            local selectedSet = {}
            if type(value) == "table" then
                for k, v2 in pairs(value) do
                    if type(k) == "string" and v2 == true then selectedSet[k] = true
                    elseif type(k) == "number" and type(v2) == "string" then selectedSet[v2] = true end
                end
            end
            local newList = {}
            for _, name in ipairs(MUTATIONS) do
                if selectedSet[name] then table.insert(newList, name) end
            end
            getgenv().RarityRules[r].mutations = newList
            saveState()
        end,
    })
    pcall(function() mutDD:SetVisibility(getgenv().RarityRules[r].enabled) end)
    RarityMutDropdowns[r] = mutDD
end

-- ----- Fight Tab -----
local FightSection = Tabs.Fight:Section({Side = "Left"})
FightSection:Header({Text = "Fight Control"})
FightSection:Toggle({
    Name = "Auto Start", Default = getgenv().AutoFightStart,
    Callback = function(v) getgenv().AutoFightStart = v; saveState() end,
}, "AutoFightStart")
FightSection:Input({
    Name = "Start at wave", Placeholder = tostring(getgenv().StartAtWave),
    AcceptedCharacters = "Numeric",
    Callback = function(t) getgenv().StartAtWave = tonumber(t) or 0; saveState() end,
}, "StartAtWaveInput")
FightSection:Input({
    Name = "Stop at wave", Placeholder = tostring(getgenv().StopAtWave),
    AcceptedCharacters = "Numeric",
    Callback = function(t) getgenv().StopAtWave = tonumber(t) or 0; saveState() end,
}, "StopAtWaveInput")
FightSection:Toggle({
    Name = "Max Game Speed", Default = getgenv().MaxGameSpeedEnabled,
    Callback = function(v) getgenv().MaxGameSpeedEnabled = v; saveState() end,
}, "MaxGameSpeedEnabled")
FightSection:Label({Text = "0 = disabled. Max Game Speed = FightFastForwardSpeed\n10x (no server clamp, verified client-side)."})
local fightStatusLabel = FightSection:Label({Text = "Idle"})

local BypassSection = Tabs.Fight:Section({Side = "Right"})
BypassSection:Header({Text = "Bypass"})
BypassSection:Toggle({
    Name = "Luck+14 / Mutation2x / Speed10x",
    Default = getgenv().BypassEnabled,
    Callback = function(v) toggleBypass(v); saveState() end,
}, "BypassEnabled")
BypassSection:Label({Text = "Verified client-side:\n* Luck2x + SuperLuck + UltraLuck = +14\n* Mutation2x = double mutation chance\n* FightFastForwardSpeed = 10x\nRe-sets ทุก 1s ตลอด session.\n\nCursed = event-only (Chance=0)\nไม่มี attribute ที่ bypass ได้"})
local bypassStatusLabel = BypassSection:Label({Text = getgenv().BypassEnabled and "Running" or "Off"})

-- ----- Battlepass Tab -----
local BPLeft = Tabs.Battlepass:Section({Side = "Left"})
BPLeft:Header({Text = "Auto Claim Battlepass"})
BPLeft:Toggle({
    Name = "Auto Claim Battlepass",
    Default = getgenv().AutoClaimBPEnabled,
    Callback = function(v) getgenv().AutoClaimBPEnabled = v; saveState() end,
}, "AutoClaimBPEnabled")
BPLeft:Label({Text = "Claims every unlocked tier reward\n(Free track always, Premium track only\nif you own this season's pass) ผ่าน\nClaim:FireServer(level, track)\nตรวจทุก 30 วินาที"})
BPLeft:Button({Name = "Claim Now", Callback = function()
    task.spawn(doAutoClaimBP)
end})
local bpStatusLabel = BPLeft:Label({Text = "Idle"})

local BPRight = Tabs.Battlepass:Section({Side = "Right"})
BPRight:Header({Text = "Auto Claim Battlepass Quest"})
BPRight:Toggle({
    Name = "Auto Claim BP Quest",
    Default = getgenv().AutoClaimBPQuestEnabled,
    Callback = function(v) getgenv().AutoClaimBPQuestEnabled = v; saveState() end,
}, "AutoClaimBPQuestEnabled")
BPRight:Label({Text = "Claim quest อัตโนมัติ (Daily + Weekly)\nที่ Completed=true และ Claimed=false\nผ่าน ClaimQuest:FireServer(category, ID)\nตรวจทุก 30 วินาที"})
BPRight:Button({Name = "Claim Now", Callback = function()
    task.spawn(doAutoClaimBPQuest)
end})
local bpQuestStatusLabel = BPRight:Label({Text = "Idle"})

BPLeft:Label({Text = "Note: buying the Premium pass itself still needs\nRobux via RequestGamepass -- only CLAIMING\nalready-unlocked/owned rewards is automated."})

-- ----- Upgrade Tab -----
local UpgradeSection = Tabs.Upgrade:Section({Side = "Left"})
UpgradeSection:Header({Text = "Auto Upgrade"})
local upgradeStatusLabels = {}
for _, key in ipairs(UPGRADE_KEYS) do
    UpgradeSection:Toggle({
        Name = "Auto Upgrade " .. UPGRADE_LABELS[key],
        Default = getgenv()[UPGRADE_FLAG_KEYS[key]],
        Callback = function(v) getgenv()[UPGRADE_FLAG_KEYS[key]] = v; saveState() end,
    }, UPGRADE_FLAG_KEYS[key])
end
local UpgradeRight = Tabs.Upgrade:Section({Side = "Right"})
UpgradeRight:Header({Text = "Status"})
for _, key in ipairs(UPGRADE_KEYS) do
    refreshUpgradeStatus(key)
    upgradeStatusLabels[key] = UpgradeRight:Label({Text = upgradeStatusText[key]})
end
UpgradeRight:Label({Text = "Buys with Gold currency (not Robux)."})

-- ----- Settings Tab -----
local SettingsSection = Tabs.Settings:Section({Side = "Left"})
SettingsSection:Header({Text = "General"})
SettingsSection:Toggle({
    Name = "Anti-AFK", Default = getgenv().AntiAFKEnabled,
    Callback = function(v) getgenv().AntiAFKEnabled = v; saveState() end,
}, "AntiAFKEnabled")
SettingsSection:Toggle({
    Name = "Auto Reconnect", Default = getgenv().AutoReconnectEnabled,
    Callback = function(v) getgenv().AutoReconnectEnabled = v; saveState() end,
}, "AutoReconnectEnabled")
SettingsSection:Keybind({
    Name = "Show/Hide UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
    Callback = function() pcall(function() Window:SetState(not Window:GetState()) end) end,
}, "RollAnimeToggleUIKeybind")

SettingsSection:Header({Text = "Auto Save"})
SettingsSection:Label({Text = "All toggles save automatically to:\n" .. SAVE_FILE})
local PerformanceSection = Tabs.Settings:Section({Side = "Right"})
PerformanceSection:Header({Text = "Performance"})
PerformanceSection:Toggle({
    Name = "FPS Boost", Default = getgenv().FPSBoostEnabled,
    Callback = function(v) getgenv().FPSBoostEnabled = v; applyFPSBoost(v); saveState() end,
}, "FPSBoostEnabled")
PerformanceSection:Toggle({
    Name = "Remove Other Base", Default = getgenv().RemoveOtherBaseEnabled,
    Callback = function(v) getgenv().RemoveOtherBaseEnabled = v; applyRemoveOtherBase(v); saveState() end,
}, "RemoveOtherBaseEnabled")
PerformanceSection:Label({Text = "Remove Other Base is local-only (client-side)."})

-- ===== Background loops =====
task.spawn(function()
    while getgenv().__RAG == myGen do
        pcall(doAutoSummon)
        pcall(function() summonStatusLabel:UpdateName(summonStatusText) end)
        task.wait(getgenv().SummonDelay or 2.2)
    end
end)

task.spawn(function()
    while getgenv().__RAG == myGen do
        pcall(function() goldStatusLabel:UpdateName("Gold: " .. tostring(getGold())) end)
        if not getgenv().AutoBuyEnabled then
            pcall(function() buyStatusLabel:UpdateName("Idle") end)
        end
        task.wait(2)
    end
end)

task.spawn(function()
    while getgenv().__RAG == myGen do
        pcall(doAutoUpgrade)
        for _, key in ipairs(UPGRADE_KEYS) do
            pcall(function()
                if upgradeStatusLabels[key] then upgradeStatusLabels[key]:UpdateName(upgradeStatusText[key]) end
            end)
        end
        task.wait(1.5)
    end
end)

task.spawn(function()
    while getgenv().__RAG == myGen do
        pcall(function() sessionTimeLabel:UpdateName("SessionTime : " .. formatSessionTime()) end)
        task.wait(1)
    end
end)

task.spawn(function()
    while getgenv().__RAG == myGen do
        pcall(doAutoFight)
        pcall(ensureMaxGameSpeed)
        pcall(function() fightStatusLabel:UpdateName(fightStatusText) end)
        task.wait(1)
    end
end)

task.spawn(function()
    while getgenv().__RAG == myGen do
        pcall(doAutoEquipBest)
        pcall(function() equipStatusLabel:UpdateName(equipStatusText) end)
        task.wait(5)
    end
end)

task.spawn(function()
    while getgenv().__RAG == myGen do
        pcall(doAutoSpinWheel)
        pcall(function() spinStatusLabel:UpdateName(spinStatusText) end)
        task.wait(2)
    end
end)

task.spawn(function()
    while getgenv().__RAG == myGen do
        pcall(function()
            bypassStatusLabel:UpdateName(
                getgenv().BypassEnabled and "Running — Luck+14 / Mutation2x / Speed10x" or "Off"
            )
        end)
        task.wait(1)
    end
end)

-- Auto Claim Battlepass + Quest loop ทุก 30 วินาที
task.spawn(function()
    while getgenv().__RAG == myGen do
        pcall(doAutoClaimBP)
        pcall(function() bpStatusLabel:UpdateName(bpStatusText) end)
        pcall(doAutoClaimBPQuest)
        pcall(function() bpQuestStatusLabel:UpdateName(bpQuestStatusText) end)
        task.wait(30)
    end
end)

applyFPSBoost(getgenv().FPSBoostEnabled)
applyRemoveOtherBase(getgenv().RemoveOtherBaseEnabled)
if getgenv().BypassEnabled then toggleBypass(true) end

getgenv().__RAWindow = Window
Tabs.Info:Select()
print("[RollAnime] v2.1 loaded — Cursed mutation + Auto Claim Battlepass + Battlepass Quest")
