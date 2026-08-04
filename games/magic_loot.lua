-- Magic Loot[Beta] Automation v1.0
-- Auto Pickup (price/rarity filter, high-to-low priority) + Auto Train +
-- Auto Claim Daily + Auto Sell (price/rarity filter) + Auto Craft Alchemy
-- (craft+collect loop) + Auto Stage (farm to target, return town) +
-- Auto Rebirth + Auto Redeem Code + Skill NoCooldown + Settings
-- (Anti-AFK, Speed, Jump, Auto Save, Auto Reconnect)
--
-- This game dispatches everything through one generic channel --
-- NetWork.FireServer(NetMsg.X, ...) / NetWork.InvokeServer(NetMsg.X, ...) --
-- from ReplicatedFirst.AllSideCode.UtilsSystem, with human-readable message
-- names (123 of them). Confirmed live by hooking NetWork.FireServer/
-- InvokeServer and capturing real traffic during an actual dungeon run:
--   DROP_PICKUP(dropGuid), DUNGEON_SPAWN_STAGE(stageNum), DUNGEON_RETURN_TOWN()
--   RELEASE_GROUP_SKILL(slot, {...}) -- 174 calls, confirms skills already
--   auto-fire on their own; this script only removes the cooldown gate.
-- CLAIM_DAILY_AWARD/SELL_MATERIAL/PLAYER_REBIRTH/REDEEM_CODE/ALCHEMY_CRAFT_RECIPE
-- argument shapes confirmed by reading the game's own UI ModuleScripts
-- (Login, Sell, Rebirth, SettingRowBind, Alchemy).
--
-- NOT yet live-verified (best-effort, needs testing together):
--   TRAIN_MANUAL_CLICK -- never found an actual FireServer call site in any
--   decompiled script (only the NetMsg definition + listeners for the
--   server->client presentation events). Firing it with no args since that
--   matches every other "you did the thing" message in this game.
--   ALCHEMY_PICKUP_FINISH_POTION -- same story, no call site found. Firing
--   with no args.
--   Auto Pickup uses fireproximityprompt() on each drop's real
--   ProximityPrompt instead of guessing the DROP_PICKUP GUID ourselves --
--   the prompt's own Triggered handler is confirmed (via decompile) to
--   literally do NetWork.FireServer(NetMsg.DROP_PICKUP, thatGuid), so this
--   reuses the game's own ID resolution instead of reinventing it.

getgenv().__MLG = (getgenv().__MLG or 0) + 1
local myGen = getgenv().__MLG
local SESSION_START = os.clock()

pcall(function()
    if getgenv().__MLWindow then getgenv().__MLWindow:Unload() end
end)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local LocalPlayer = Players.LocalPlayer

local UtilsSystem = require(ReplicatedFirst.AllSideCode.UtilsSystem)
local NetWork = UtilsSystem.NetWork
local NetMsg = UtilsSystem.NetMsg
local PlayerData = UtilsSystem.PlayerData
local CfgFind = UtilsSystem.CfgFind

local function fire(msg, ...)
    local args = {...}
    local ok = pcall(function() NetWork.FireServer(msg, table.unpack(args)) end)
    return ok
end
local function invoke(msg, ...)
    local args = {...}
    local ok, result = pcall(function() return NetWork.InvokeServer(msg, table.unpack(args)) end)
    if ok then return result end
    return nil
end

-- ===== Rarity names (Xyd1-10, confirmed live from UIMgr.Gradients: 常见/
-- 罕见/稀有/史诗/传说/神话/秘密/远古/至尊/星界) =====
local RARITY_NAMES = {"常见", "罕见", "稀有", "史诗", "传说", "神话", "秘密", "远古", "至尊", "星界"}
-- English side confirmed live from TranslationHelper.Language's own
-- localizationtableConf entries for each rarity string (same table the
-- game's own UI reads for these labels).
local RARITY_NAMES_EN = {"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Ancient", "Supreme", "Astral Realm"}
local RARITY_INDEX = {}
for i, name in ipairs(RARITY_NAMES) do RARITY_INDEX[name] = i end

-- Chinese ZhName -> English name for the 17 alchemy potions, confirmed live
-- from TranslationHelper.Language.localizationtableConf (each grepped
-- individually against the game's own decompiled translation table --
-- require()'ing that module directly returns an empty table in this
-- executor for some reason, so this is hardcoded from the verified source
-- instead of read live).
local POTION_NAME_EN = {
    ["火箭术药水"] = "Fire Arrow Potion", ["手臂变细药水"] = "Long-long Arms Potion",
    ["水球术药水"] = "Water Orb Potion", ["巨人术药水"] = "Giant Growth Potion",
    ["陨石术药水"] = "Meteorite Potion", ["大地突起药水"] = "Earth Spike Potion",
    ["雷电雷电药水"] = "Thunder-thunder Potion", ["冰霜三棘药水"] = "Frost Thorns Potion",
    ["龙息术药水"] = "Dragon Breath Potion", ["花御木刺药水"] = "Wood Thorn Potion",
    ["光辉之剑药水"] = "Radiant Sword Potion", ["水渊药水"] = "Abyssal Water Potion",
    ["小羊药水"] = "Sheepy Potion", ["连环毒爆药水"] = "Ring Gas Potion",
    ["火焰辣椒药水"] = "Flame Chili Potion", ["暗夜亡魂药水"] = "Night Wraith Potion",
    ["冰莲绽放药水"] = "Lotus Blooms Potion",
}

-- ===== Auto Use Potion options =====
-- Potions in this game split into two unrelated categories, confirmed live
-- via CfgFind.FindCfgByID on every entry in ConfigInstance.potionConf
-- (26 total): SkillID~=0 ones grant a combat skill on use (the 17 alchemy
-- potions above -- precious, meant to be equipped/chosen, never auto-used),
-- BuffID~=0 ones are plain timed buffs (only 4 of them: 2 Training, 2
-- Lucky). Auto Use Potion only ever touches the BuffID kind -- that's the
-- whole "Skills vs Potion (Lucks, Training)" split.
local USE_POTION_ID_TO_LABEL = {
    [9200101] = "Training Potion", [9200102] = "Super Training Potion",
    [9200103] = "Lucky Potion", [9200104] = "Super Lucky Potion",
}
local USE_POTION_LABEL_TO_ID = {}
local USE_POTION_OPTIONS = {}
for id, label in pairs(USE_POTION_ID_TO_LABEL) do
    USE_POTION_LABEL_TO_ID[label] = id
    table.insert(USE_POTION_OPTIONS, label)
end
table.sort(USE_POTION_OPTIONS)

-- ===== Alchemy recipe list (CfgFind.GetAlchemyRecipeList(), confirmed live --
-- 17 recipes, each recipeId maps to a PID (the crafted potion's item id);
-- resolving PID through CfgFind.FindCfgByID gives the real potion name +
-- rarity, since the recipe's own ZhName is just a generic "配方N" placeholder.
-- Label format "Fire Arrow Potion (Common)" -- English name, rarity in
-- parens, no id prefix -- as requested.
local alchemyRecipeLabels = {}
local alchemyLabelToId = {}
local alchemyIdToLabel = {}
do
    local ok, list = pcall(function() return CfgFind.GetAlchemyRecipeList() end)
    if ok and type(list) == "table" then
        table.sort(list, function(a, b) return (tonumber(a.recipeId) or 0) < (tonumber(b.recipeId) or 0) end)
        for _, recipe in ipairs(list) do
            local rid = tonumber(recipe.recipeId)
            if rid then
                local okName, itemCfg = pcall(function() return CfgFind.FindCfgByID(recipe.PID) end)
                local zhName = okName and itemCfg and itemCfg.ZhName
                local potionName = (zhName and POTION_NAME_EN[zhName]) or zhName or ("Recipe " .. rid)
                local xyd = okName and itemCfg and tonumber(itemCfg.xyd)
                local rarityName = xyd and RARITY_NAMES_EN[xyd] or "?"
                local label = potionName .. " (" .. rarityName .. ")"
                table.insert(alchemyRecipeLabels, label)
                alchemyLabelToId[label] = rid
                alchemyIdToLabel[rid] = label
            end
        end
    end
end

-- ===== Auto Save =====
local SAVE_FOLDER = "MagicLootAutomation"
local SAVE_FILE = SAVE_FOLDER .. "/state.json"
pcall(function() if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end end)
local PERSIST_KEYS = {
    "AutoPickupEnabled", "PickupMinPrice", "PickupRaritySet",
    "AutoTrainEnabled",
    "AutoClaimDailyEnabled",
    "AutoSellEnabled", "SellMaxPrice", "SellMaxRarity",
    "AutoAlchemyEnabled", "AlchemyRecipeId", "AutoUsePotionEnabled", "AutoUsePotionSelected",
    "AutoStageEnabled", "StageTarget", "AutoReturnOnBagFull", "MobHoverHeight",
    "AutoRebirthEnabled",
    "SkillNoCooldownEnabled",
    "AntiAFKEnabled", "AutoReconnectEnabled", "WalkSpeedEnabled", "WalkSpeedValue",
    "JumpPowerEnabled", "JumpPowerValue",
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

local e = getgenv()
if e.AutoPickupEnabled == nil then e.AutoPickupEnabled = false end
if e.PickupMinPrice == nil then e.PickupMinPrice = 0 end
if e.PickupRaritySet == nil then e.PickupRaritySet = {} end
if e.AutoTrainEnabled == nil then e.AutoTrainEnabled = false end
if e.AutoClaimDailyEnabled == nil then e.AutoClaimDailyEnabled = false end
if e.AutoSellEnabled == nil then e.AutoSellEnabled = false end
if e.SellMaxPrice == nil then e.SellMaxPrice = 0 end
if e.SellMaxRarity == nil then e.SellMaxRarity = 0 end
if e.AutoAlchemyEnabled == nil then e.AutoAlchemyEnabled = false end
if e.AutoUsePotionEnabled == nil then e.AutoUsePotionEnabled = false end
if e.AutoUsePotionSelected == nil then e.AutoUsePotionSelected = {} end
if e.AlchemyRecipeId == nil then e.AlchemyRecipeId = "" end
if e.AutoStageEnabled == nil then e.AutoStageEnabled = false end
if e.StageTarget == nil then e.StageTarget = 0 end
if e.AutoReturnOnBagFull == nil then e.AutoReturnOnBagFull = false end
if e.MobHoverHeight == nil then e.MobHoverHeight = 12 end
if e.AutoRebirthEnabled == nil then e.AutoRebirthEnabled = false end
if e.SkillNoCooldownEnabled == nil then e.SkillNoCooldownEnabled = false end
if e.AntiAFKEnabled == nil then e.AntiAFKEnabled = true end
if e.AutoReconnectEnabled == nil then e.AutoReconnectEnabled = true end
if e.WalkSpeedEnabled == nil then e.WalkSpeedEnabled = false end
if e.WalkSpeedValue == nil then e.WalkSpeedValue = 16 end
if e.JumpPowerEnabled == nil then e.JumpPowerEnabled = false end
if e.JumpPowerValue == nil then e.JumpPowerValue = 50 end

-- ===== Auto Pickup =====
-- Every drop Model carries GoldValue + Xyd(rarity) attributes directly
-- (confirmed live via Model:SetAttribute in SystemDrop.client) -- no need to
-- read any internal Lua state for the filter/sort itself.
local pickupStatusText = "Idle"
local function getDropItems()
    local items = {}
    local dropsClient = workspace:FindFirstChild("DropsClient")
    if not dropsClient then return items end
    for _, folder in ipairs(dropsClient:GetChildren()) do
        for _, item in ipairs(folder:GetChildren()) do
            if item:IsA("Model") and item.Name == "DropItem" then
                table.insert(items, {
                    model = item,
                    gold = tonumber(item:GetAttribute("GoldValue")) or 0,
                    xyd = tonumber(item:GetAttribute("Xyd")) or 0,
                })
            end
        end
    end
    return items
end
local function doAutoPickup()
    if not e.AutoPickupEnabled then pickupStatusText = "Idle"; return end
    local items = getDropItems()
    -- price high -> low priority, exactly as requested
    table.sort(items, function(a, b) return a.gold > b.gold end)
    local minPrice = tonumber(e.PickupMinPrice) or 0
    local raritySet = type(e.PickupRaritySet) == "table" and e.PickupRaritySet or {}
    local anyRaritySelected = next(raritySet) ~= nil
    local fired = 0
    for _, it in ipairs(items) do
        local rarityName = RARITY_NAMES[it.xyd]
        local passRarity = (not anyRaritySelected) or (rarityName ~= nil and raritySet[rarityName])
        if it.gold >= minPrice and passRarity then
            local prompt = it.model.PrimaryPart and it.model.PrimaryPart:FindFirstChildOfClass("ProximityPrompt")
            if prompt then
                pcall(function() fireproximityprompt(prompt) end)
                fired += 1
            end
        end
    end
    pickupStatusText = fired > 0 and ("Picked up " .. fired .. " item(s) this pass") or "Nothing matching filter"
end

-- ===== Auto Train =====
-- This is a LOBBY-only feature (Workspace.场景.大厅.功能.训练场 -- a Training
-- Ground crystal, not a dungeon mechanic). NetWork.InvokeServer(NetMsg.
-- TRAIN_MANUAL_CLICK, {}) confirmed live -- returns {gain=X, ok=true} with
-- a real currency gain, but ONLY when standing at the crystal; from
-- anywhere else it silently no-ops. Tried ~20 different extra table fields
-- (multiplier/times/count/rate/tier/etc) looking for a click-multiplier
-- knob -- gain never changed, so whatever x2/x4/x8/x15/x100 badge the game
-- shows is a passive stat (Rebirth/bonus-event driven), not something this
-- call controls -- {} is already the correct, complete argument.
local trainStatusText = "Idle"
local function doAutoTrain()
    if not e.AutoTrainEnabled then trainStatusText = "Idle"; return end
    local result = invoke(NetMsg.TRAIN_MANUAL_CLICK, {})
    trainStatusText = (type(result) == "table" and result.gain) and ("Trained -- gained " .. result.gain) or "No response -- likely out of Training Ground range"
end

-- ===== Auto Claim Daily + Online Award =====
-- Two separate reward systems, both wired here:
--   Login daily: PlayerData.GetPlrDataByKey(LP,"Login")[dayIndex].State == 1
--   means claimable (confirmed live from Login.lua's own _onClaimClick).
--   Online award: the gift-icon badge with the red dot -- a DIFFERENT
--   system, PlayerData.GetPlrDataByKey(LP,"OnlineBox") + CfgFind.GetOnline-
--   AwardList()/IsOnlineTierClaimable(), invoked with CLAIM_ONLINE_AWARD
--   (tierId). Confirmed live: 7 of 12 tiers were sitting claimed-but-unpicked
--   the first time this was checked -- this toggle was only touching Login
--   before, never OnlineBox, which is exactly why it looked broken.
local claimDailyStatusText = "Toggle is OFF"
local function doAutoClaimDaily()
    if not e.AutoClaimDailyEnabled then claimDailyStatusText = "Toggle is OFF"; return end
    local claimed = 0

    local login = PlayerData.GetPlrDataByKey(LocalPlayer, "Login")
    if type(login) == "table" then
        for dayKey, dayData in pairs(login) do
            if type(dayData) == "table" and (tonumber(dayData.State) or 0) == 1 then
                local dayNum = tonumber(dayKey)
                if dayNum then
                    local result = invoke(NetMsg.CLAIM_DAILY_AWARD, dayNum)
                    print("[MagicLoot][ClaimDaily] login day " .. dayNum .. " -> result=" .. tostring(result))
                    if result then claimed += 1 end
                    task.wait(0.2)
                end
            end
        end
    end

    local ok, onlineBox = pcall(function() return PlayerData.GetPlrDataByKey(LocalPlayer, "OnlineBox") end)
    if ok and type(onlineBox) == "table" then
        local ok2, list = pcall(function() return CfgFind.GetOnlineAwardList() end)
        if ok2 and type(list) == "table" then
            for _, tier in ipairs(list) do
                local claimableOk, claimable = pcall(function() return CfgFind.IsOnlineTierClaimable(onlineBox, tier) end)
                if claimableOk and claimable then
                    local result = invoke(NetMsg.CLAIM_ONLINE_AWARD, tier.id)
                    print("[MagicLoot][ClaimDaily] online tier " .. tostring(tier.id) .. " -> result=" .. tostring(result))
                    if result then claimed += 1 end
                    task.wait(0.2)
                end
            end
        end
    end

    claimDailyStatusText = claimed > 0 and ("Claimed " .. claimed .. " award(s)") or "Nothing claimable"
end

-- ===== Auto Sell =====
-- PlayerData.GetPlrDataByKey(LP,"Bag") -> {[onlyID] = {id=itemDefId, tp=type,
-- equip=0/1, count=n, onlyID=...}}. GoldValue/rarity come from
-- CfgFind.FindCfgByID(entry.id).GoldValue / .xyd. Never touches equipped
-- items.
--
-- SELL_MATERIAL rejects the WHOLE batch (returns false, sells nothing) if
-- it contains any non-material entry -- confirmed live: selling all 143 bag
-- entries at once failed, selling just the 96 with tp==2 succeeded. The bag
-- mixes several item types (tp 0/2/6/9/13 all seen live) and this remote
-- only accepts tp==2 (materials), so that's the required filter, not just a
-- nice-to-have.
local sellStatusText = "Toggle is OFF"
local function doAutoSell()
    if not e.AutoSellEnabled then sellStatusText = "Toggle is OFF"; return end
    local bag = PlayerData.GetPlrDataByKey(LocalPlayer, "Bag")
    if type(bag) ~= "table" then sellStatusText = "No bag data"; return end
    local maxPrice = tonumber(e.SellMaxPrice) or 0
    local maxRarity = tonumber(e.SellMaxRarity) or 0
    local ids = {}
    for onlyIdKey, entry in pairs(bag) do
        if type(entry) == "table" and entry.equip ~= 1 and tostring(entry.tp) == "2" then
            local ok, cfg = pcall(function() return CfgFind.FindCfgByID(entry.id) end)
            if ok and cfg then
                -- Material configs carry GoldValue, not Price -- confirmed
                -- live via ConfigInstance.materialConf field list and a
                -- direct CfgFind.FindCfgByID probe (no "Price" key exists
                -- on a material entry at all, so this always read nil -> 0
                -- before, silently passing every price filter instead of
                -- actually filtering).
                local price = tonumber(cfg.GoldValue) or 0
                local xyd = tonumber(cfg.xyd) or 0
                local passPrice = maxPrice <= 0 or price <= maxPrice
                local passRarity = maxRarity <= 0 or xyd <= maxRarity
                if passPrice and passRarity then
                    table.insert(ids, tonumber(entry.onlyID) or tonumber(onlyIdKey))
                end
            end
        end
    end
    print("[MagicLoot][Sell] checked, bag entries matching filter: " .. #ids)
    if #ids > 0 then
        local result = invoke(NetMsg.SELL_MATERIAL, {onlyIDList = ids})
        print("[MagicLoot][Sell] invoked with " .. #ids .. " id(s) -> result=" .. tostring(result))
        sellStatusText = result and ("Sold " .. #ids .. " item(s)") or ("Tried " .. #ids .. " item(s), server did not confirm")
    else
        sellStatusText = "Nothing matching filter"
    end
end

-- ===== Auto Craft Alchemy =====
-- ALCHEMY_CRAFT_RECIPE({recipeId=X}) confirmed live (Alchemy.lua). The
-- collect step, ALCHEMY_PICKUP_FINISH_POTION, has no confirmed call site or
-- argument shape -- tried first with no args (matches the game's own
-- no-arg "do the pending thing" pattern), wrapped safely either way. Server
-- rejects craft attempts it can't afford, so looping this is harmless when
-- out of materials.
local alchemyStatusText = "Idle"
local function doAutoCraftAlchemy()
    if not e.AutoAlchemyEnabled then alchemyStatusText = "Idle"; return end
    local recipeId = tonumber(e.AlchemyRecipeId)
    if not recipeId then alchemyStatusText = "Set a Recipe ID first"; return end
    invoke(NetMsg.ALCHEMY_PICKUP_FINISH_POTION)
    task.wait(0.3)
    local result = invoke(NetMsg.ALCHEMY_CRAFT_RECIPE, {recipeId = recipeId})
    alchemyStatusText = result and "Crafted + collected" or "No craft this pass (missing materials or already brewing)"
end

-- ===== Auto Use Potion =====
-- DRINK_POTION(onlyID) confirmed live -- invoked on a real Bag entry
-- (ItemType.Potion, tp==9), returned true and the entry was gone from the
-- bag right after. Only drinks entries whose item id is in the selected
-- set (Training/Lucky potions) -- the skill-granting alchemy potions are
-- never touched even if nothing is selected. Skips equip==1 in case that
-- ever means "actively slotted", same caution as Auto Sell.
local usePotionStatusText = "Toggle is OFF"
local function doAutoUsePotion()
    if not e.AutoUsePotionEnabled then usePotionStatusText = "Toggle is OFF"; return end
    local selected = type(e.AutoUsePotionSelected) == "table" and e.AutoUsePotionSelected or {}
    if next(selected) == nil then usePotionStatusText = "No potion selected"; return end
    local bag = PlayerData.GetPlrDataByKey(LocalPlayer, "Bag")
    if type(bag) ~= "table" then usePotionStatusText = "No bag data"; return end
    local used = 0
    for onlyIdKey, entry in pairs(bag) do
        if type(entry) == "table" and entry.equip ~= 1 and tostring(entry.tp) == "9" then
            local label = USE_POTION_ID_TO_LABEL[tonumber(entry.id)]
            local onlyID = tonumber(entry.onlyID) or tonumber(onlyIdKey)
            if onlyID and label and selected[label] then
                local result = invoke(NetMsg.DRINK_POTION, onlyID)
                if result then used += 1 end
                task.wait(0.15)
            end
        end
    end
    usePotionStatusText = used > 0 and ("Used " .. used .. " potion(s)") or "Nothing to use"
end

-- ===== Auto Stage =====
-- LocalPlayer.DungeonAggroStage (NumberValue) tracks the current stage
-- (confirmed live -- same value SystemDrop.client listens to for its own
-- stage-change handling). DUNGEON_RETURN_TOWN takes no args (confirmed live,
-- captured a real call).
local stageStatusText = "Toggle is OFF"
local lastReturnTime = 0
-- Elite/boss rooms carry monsters with absurd HP pools (confirmed live:
-- a 4-monster pack all at 400,000,001,507,328 HP each) that can legitimately
-- take a minute-plus to clear -- that's not a bug, it's just a slow fight,
-- but from outside it looks identical to a genuinely stuck run. Tracking
-- how long the stage value has sat unchanged tells the two apart: if it's
-- still climbing (however slowly) that's fine, but if it's flatlined too
-- long, abandon and let the portal-reentry loop start a fresh, hopefully
-- easier run instead of potentially sitting there forever.
local STALL_ABANDON_SECONDS = 90
local lastProgressStage = -1
local lastProgressTime = 0
-- 副本引导 ("Dungeon Guide") in the town's 功能 folder is a plain touch
-- trigger, no ProximityPrompt -- confirmed live, teleporting onto it flips
-- InDungeonChallenge to 1 and starts a fresh run at stage 1. Used both to
-- start the very first run and to loop back in after DUNGEON_RETURN_TOWN,
-- so Auto Stage keeps farming instead of sitting idle in town once the
-- target is hit.
local function findDungeonPortal()
    local scene = workspace:FindFirstChild("场景")
    local lobby = scene and scene:FindFirstChild("大厅")
    local funcs = lobby and lobby:FindFirstChild("功能")
    local guideFolder = funcs and funcs:FindFirstChild("副本引导")
    return guideFolder and guideFolder:FindFirstChild("副本引导")
end

-- Two separate bags, confirmed live -- don't conflate them:
--   Stage bag: LocalPlayer.LimitBagUsed (NumberValue), cap read from the
--   "临时背包容量" ("Temporary Backpack Capacity") HUD label, e.g. "5/9" --
--   this is what fills up DURING a dungeon run and is what actually blocks
--   further pickups mid-stage.
--   Total bag: PlayerData.GetPlrDataByKey(LP,"Bag") entry count, cap read
--   from the "仓库.容量" ("Warehouse Capacity") backpack UI label, e.g.
--   "74 / 999" -- the account-wide inventory, independent of any single run.
-- Cap (and now used-count too) is read live from the HUD text instead of
-- computed ourselves, since bag size is an upgradeable stat (ItemID.Limit-
-- BagSize reward) and could change -- and because counting raw PlayerData
-- Bag table entries turned out to NOT match what the game calls "used"
-- (confirmed live: 114 raw onlyID entries in the Bag table vs "67 / 999" on
-- the actual Warehouse Capacity label -- the UI must be counting distinct
-- item stacks, not raw entries. Trusting the label directly sidesteps that
-- entirely instead of guessing at the aggregation rule).
local function parseUsedCap(text)
    if type(text) ~= "string" then return 0, 0 end
    local usedStr, capStr = text:match("(%d+)%s*/%s*(%d+)")
    return tonumber(usedStr) or 0, tonumber(capStr) or 0
end
local function getStageBagUsage()
    local ok, label = pcall(function()
        return LocalPlayer.PlayerGui.ScreenGui.Main.ButtomLeft["临时背包容量"].Label
    end)
    if not ok then return 0, 0 end
    return parseUsedCap(label.Text)
end
local function getTotalBagUsage()
    local ok, label = pcall(function()
        return LocalPlayer.PlayerGui.ScreenGui.Main.Backpack["仓库"]["容量"]:FindFirstChild("Size")
    end)
    if not ok then return 0, 0 end
    return parseUsedCap(label.Text)
end
local function isEitherBagFull()
    local stageUsed, stageCap = getStageBagUsage()
    if stageCap > 0 and stageUsed >= stageCap then return true, "stage bag " .. stageUsed .. "/" .. stageCap end
    local totalUsed, totalCap = getTotalBagUsage()
    if totalCap > 0 and totalUsed >= totalCap then return true, "total bag " .. totalUsed .. "/" .. totalCap end
    return false, nil
end

local function doAutoStage()
    if not e.AutoStageEnabled then stageStatusText = "Toggle is OFF"; return end
    local target = tonumber(e.StageTarget) or 0
    if target <= 0 then stageStatusText = "Toggle ON -- set a target stage first"; return end

    local inDungeonVal = LocalPlayer:FindFirstChild("InDungeonChallenge")
    local inDungeon = inDungeonVal and inDungeonVal.Value > 0
    if not inDungeon then
        lastProgressStage = -1
        lastProgressTime = 0
        -- The user watched this live and noticed re-entry needs a beat
        -- after returning before the server will actually accept it --
        -- matches the touch-trigger silently not registering when hit too
        -- soon after DUNGEON_RETURN_TOWN (the dungeon instance is probably
        -- still tearing down server-side). Widened from 2s to 8s.
        local REENTRY_DELAY_SECONDS = 8
        if os.clock() - lastReturnTime < REENTRY_DELAY_SECONDS then
            stageStatusText = "Returned to town -- waiting " ..
                math.ceil(REENTRY_DELAY_SECONDS - (os.clock() - lastReturnTime)) .. "s before re-entering"
            return
        end
        local guide = findDungeonPortal()
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if guide and hrp and hum then
            -- An instant CFrame jump straight onto 副本引导 never registers --
            -- confirmed live: sitting exactly on it for 60+ seconds straight,
            -- InDungeonChallenge stayed 0 the whole time. Humanoid:MoveTo()
            -- (real physics-driven movement into it) worked on the very
            -- first try. The touch-trigger apparently needs genuine
            -- movement/collision resolution, not just an overlapping CFrame.
            hrp.Anchored = false
            hrp.CFrame = CFrame.new(guide.Position + Vector3.new(6, 0, 0))
            hum:MoveTo(guide.Position)
            print("[MagicLoot][Portal] walking into portal at " .. tostring(guide.Position))
            stageStatusText = "Not in dungeon -- walking to the portal to (re)enter"
        else
            stageStatusText = "Not in dungeon -- portal not found (not in town?)"
        end
        return
    end

    do
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then hrp.Anchored = false end
    end

    local stageVal = LocalPlayer:FindFirstChild("DungeonAggroStage")
    local current = stageVal and stageVal.Value or 0
    print("[MagicLoot][Stage] tick, current=" .. current .. " target=" .. target)

    if current ~= lastProgressStage or lastProgressTime == 0 then
        lastProgressStage = current
        lastProgressTime = os.clock()
    elseif os.clock() - lastProgressTime > STALL_ABANDON_SECONDS then
        -- Same stage for too long -- most likely an elite/boss pack too
        -- tanky to clear in reasonable time. Bail and let the portal loop
        -- start a fresh run rather than potentially sitting here forever.
        fire(NetMsg.DUNGEON_ABANDON_CHALLENGE)
        fire(NetMsg.DUNGEON_RETURN_TOWN)
        lastReturnTime = os.clock()
        lastProgressStage = -1
        lastProgressTime = 0
        stageStatusText = "Stage " .. current .. " stalled " .. STALL_ABANDON_SECONDS .. "s+ (elite pack?) -- abandoned, restarting"
        return
    end

    if current >= target then
        -- Waiting to pick up is pointless once the bag is actually full --
        -- fireproximityprompt() can't collect anything more at that point,
        -- so getDropItems() would never empty out and this would hang here
        -- forever ("stuck on the last stage" when the bag fills up mid-run).
        local bagFull = isEitherBagFull()
        if e.AutoPickupEnabled and not bagFull then
            local remaining = getDropItems()
            if #remaining > 0 then
                stageStatusText = "Target reached -- waiting to pick up " .. #remaining .. " item(s) before returning"
                return
            end
        end
        fire(NetMsg.DUNGEON_RETURN_TOWN)
        lastReturnTime = os.clock()
        stageStatusText = "Stage " .. current .. " >= target " .. target .. " -- returned to town" .. (bagFull and " (bag full)" or "")
        return
    end
    if e.AutoReturnOnBagFull then
        local full, which = isEitherBagFull()
        local su, sc = getStageBagUsage()
        local tu, tc = getTotalBagUsage()
        print("[MagicLoot][BagFull] stage=" .. su .. "/" .. sc .. " total=" .. tu .. "/" .. tc .. " full=" .. tostring(full))
        if full then
            fire(NetMsg.DUNGEON_RETURN_TOWN)
            lastReturnTime = os.clock()
            stageStatusText = "Bag full (" .. which .. ") -- returned to town"
            return
        end
    end
    local folder = workspace:FindFirstChild("LocalMonster")
    local aliveCount, totalHpPct = 0, 0
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            local hum = m:FindFirstChildOfClass("Humanoid")
            if hum and hum.MaxHealth > 0 then
                aliveCount += 1
                totalHpPct += (hum.Health / hum.MaxHealth)
            end
        end
    end
    if aliveCount > 0 then
        local avgHpPct = math.floor((totalHpPct / aliveCount) * 100)
        stageStatusText = "Farming -- stage " .. current .. " / target " .. target ..
            " (" .. aliveCount .. " alive, avg " .. avgHpPct .. "% HP)"
    else
        stageStatusText = "Farming -- stage " .. current .. " / target " .. target
    end
end

-- Skills already auto-cast on their own, but the character doesn't walk
-- toward monsters by itself -- if nothing is in skill range, nothing dies
-- and DungeonAggroStage never advances. Snapping onto the nearest live
-- monster every tick keeps the character in range without needing real
-- pathfinding. Runs whenever Auto Stage is on and the target isn't reached
-- yet -- stops snapping once DUNGEON_RETURN_TOWN fires so it doesn't yank
-- the character around back in town.
--
-- Monsters only spawn once the character is physically inside that stage's
-- room -- confirmed live: workspace.场景[stageNumber].战斗区域 is a distinct
-- trigger volume per room (1,2,3... each 108 studs apart on Z), separate
-- from the LocalMonster folder that only populates after arriving. But
-- DungeonAggroStage only advances AFTER the room is cleared and the
-- character has moved into the next room -- it doesn't drive that move by
-- itself. So if a room sits empty (cleared, or nothing spawned yet) for
-- more than ~2s, nudge forward to the next room's battle area instead of
-- waiting forever on a stage value that won't update until we do.
-- Room targeting is tracked ENTIRELY with local state, driven only by
-- "found a monster or not" -- it never reads DungeonAggroStage to decide
-- which room to head to. Reading the server stage for that was the bug:
-- after DUNGEON_RETURN_TOWN, DungeonAggroStage can still briefly report the
-- previous run's final value (e.g. 16) even after re-entering at room 1,
-- so trusting it to seed/advance roomProgress carried stale progress into
-- the new run and sent the character to a room number that no longer
-- matched where it actually was -- looked like being stuck at stage 1
-- forever (real stage was 1, but this code kept aiming at room 16+).
local roomProgress = 1
local emptyTicks = 0
local lastRoomEntered = 0
local wasInDungeon = false
local orbitAngleDeg = 0

-- Anchoring while sitting on a mob is deliberate -- re-CFraming an
-- unanchored part every 0.3s fights gravity between ticks (falls, then
-- snaps back up), which is the visible bounce. Anchored holds it exactly in
-- place. Unanchored again as soon as there's no mob to sit on, so normal
-- movement/physics apply while walking a room or waiting on a spawn.
local function stopStageTeleport()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then hrp.Anchored = false end
end

local function teleportToNearestMob()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local inDungeonVal = LocalPlayer:FindFirstChild("InDungeonChallenge")
    local inDungeon = inDungeonVal and inDungeonVal.Value > 0
    if not inDungeon then
        -- Not in a run right now (doAutoStage is walking to the portal, or
        -- just reached target and returned) -- reset unconditionally, every
        -- single tick, so nothing stale survives into the next run no
        -- matter which tick actually catches the transition. Anchoring is
        -- NOT touched here -- doAutoStage owns it during the portal
        -- approach (steps back anchored, then in anchored) and this loop
        -- fighting it every 0.3s was undoing that hold before gravity-drop
        -- had time to actually register as leaving the trigger.
        roomProgress = 1
        emptyTicks = 0
        lastRoomEntered = 0
        wasInDungeon = false
        return
    end
    if not wasInDungeon then
        -- Just arrived in a fresh run -- always start the search at room 1,
        -- never at whatever roomProgress happened to hold before.
        wasInDungeon = true
        roomProgress = 1
        emptyTicks = 0
        lastRoomEntered = 0
    end

    local nearest, nearestDist = nil, math.huge
    local folder = workspace:FindFirstChild("LocalMonster")
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            local mPart = m:FindFirstChild("HumanoidRootPart") or (m:IsA("Model") and m.PrimaryPart)
            local hum = m:FindFirstChildOfClass("Humanoid")
            if mPart and (not hum or hum.Health > 0) then
                local dist = (mPart.Position - hrp.Position).Magnitude
                if dist < nearestDist then
                    nearest = mPart
                    nearestDist = dist
                end
            end
        end
    end
    if nearest then
        emptyTicks = 0
        hrp.Anchored = true
        -- A fixed hover point is a stationary target -- the mob's own
        -- attacks land on it every time, full damage, no matter how far
        -- off the ground it sits (confirmed live: dropping the hover height
        -- to 0-2 still took full damage, so it was never about floating vs
        -- grounded, it's proximity/being a sitting duck). Orbiting instead
        -- keeps the character in skill range but never still long enough
        -- for the mob's attacks to reliably land.
        local hoverHeight = tonumber(e.MobHoverHeight) or 12
        local orbitRadius = 8
        orbitAngleDeg = (orbitAngleDeg + 60) % 360
        local rad = math.rad(orbitAngleDeg)
        local offset = Vector3.new(math.cos(rad) * orbitRadius, hoverHeight, math.sin(rad) * orbitRadius)
        hrp.CFrame = CFrame.new(nearest.Position + offset)
        return
    end
    hrp.Anchored = false

    -- Once the target stage is hit, stop pushing INTO new rooms (that would
    -- overshoot past what the user asked for) -- but keep snapping onto
    -- whatever's still alive in the current room above, since doAutoStage
    -- is waiting on drops here before it fires DUNGEON_RETURN_TOWN, and
    -- nothing dies -- so nothing drops -- if this stops moving entirely.
    local stageTarget = tonumber(e.StageTarget) or 0
    local stageVal = LocalPlayer:FindFirstChild("DungeonAggroStage")
    local currentStage = stageVal and stageVal.Value or 0
    if stageTarget > 0 and currentStage >= stageTarget then
        return
    end

    emptyTicks += 1
    local targetRoomNum = roomProgress
    local advancing = emptyTicks > 6
    if advancing then
        targetRoomNum = roomProgress + 1
    end

    -- Already sitting in this room and not yet due to nudge forward -- skip
    -- the re-teleport, only jump when the target room actually changes.
    if targetRoomNum == lastRoomEntered and not advancing then
        return
    end

    local scene = workspace:FindFirstChild("场景")
    local room = scene and scene:FindFirstChild(tostring(targetRoomNum))
    if not room then return end
    -- Root sits on the floor below 战斗区域's Y range, so standing at Root
    -- alone doesn't count as being inside the trigger. Center of 战斗区域 does.
    local battleArea = room:FindFirstChild("战斗区域")
    local target = battleArea or room:FindFirstChild("Root")
    if target then
        hrp.CFrame = CFrame.new(target.Position)
        lastRoomEntered = targetRoomNum
        if advancing then
            roomProgress = targetRoomNum
            emptyTicks = 0
        end
    end
end

-- ===== Auto Rebirth =====
local rebirthStatusText = "Idle"
local function doAutoRebirth()
    if not e.AutoRebirthEnabled then rebirthStatusText = "Idle"; return end
    local result = invoke(NetMsg.PLAYER_REBIRTH)
    rebirthStatusText = result and "Rebirthed!" or "Not eligible yet"
end

-- ===== Auto Redeem Code =====
local function doRedeemCodes(codesText, onDone)
    task.spawn(function()
        local claimed, tried = 0, 0
        for code in tostring(codesText or ""):gmatch("[^%s,]+") do
            tried += 1
            local result = invoke(NetMsg.REDEEM_CODE, string.upper(code))
            if result then claimed += 1 end
            task.wait(0.3)
        end
        if onDone then onDone(claimed, tried) end
    end)
end

-- ===== Skill NoCooldown =====
-- GroupSkillClient.isCooldownActiveByTimestamp is the exact gate
-- PlayerSkillInput checks before allowing a skill to fire again -- skills
-- already auto-cast on their own (confirmed live: 174 RELEASE_GROUP_SKILL
-- calls with zero manual input), this just removes the wait between casts.
local __origIsCooldownActive = nil
local function applySkillNoCooldown(enabled)
    local ok, GroupSkillClient = pcall(function()
        return require(ReplicatedStorage.ClientSideCode.SystemSkill.GroupSkill.GroupSkillClient)
    end)
    if not ok then return false end
    if enabled then
        if not __origIsCooldownActive then
            __origIsCooldownActive = GroupSkillClient.isCooldownActiveByTimestamp
        end
        GroupSkillClient.isCooldownActiveByTimestamp = function() return false end
    elseif __origIsCooldownActive then
        GroupSkillClient.isCooldownActiveByTimestamp = __origIsCooldownActive
    end
    return true
end

-- ===== Settings: movement =====
local function applyMovement()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    if e.WalkSpeedEnabled then
        pcall(function() hum.WalkSpeed = tonumber(e.WalkSpeedValue) or 16 end)
    end
    if e.JumpPowerEnabled then
        pcall(function() hum.JumpPower = tonumber(e.JumpPowerValue) or 50 end)
    end
end
LocalPlayer.CharacterAdded:Connect(function()
    if getgenv().__MLG ~= myGen then return end
    task.wait(1)
    applyMovement()
end)

-- ===== Anti-AFK =====
LocalPlayer.Idled:Connect(function()
    if not e.AntiAFKEnabled then return end
    pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
end)

-- ===== Auto Reconnect =====
if not getgenv().__MLReconnectHooked then
    getgenv().__MLReconnectHooked = true
    Players.PlayerRemoving:Connect(function(player)
        if player == LocalPlayer and getgenv().AutoReconnectEnabled then
            pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
        end
    end)
end

-- ===== UI (Maclib) =====
local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
local Window = MacLib:Window({
    Title = "Magic Loot [Beta]",
    Subtitle = "v1.0",
    DragStyle = 1,
    ShowUserInfo = true,
    AcrylicBlur = false,
})

local TabGroup = Window:TabGroup()
local Tabs = {
    Farm     = TabGroup:Tab({Name = "Farm",     Image = "rbxassetid://10723343321"}),
    Sell     = TabGroup:Tab({Name = "Sell",     Image = "rbxassetid://10734952273"}),
    Alchemy  = TabGroup:Tab({Name = "Alchemy",  Image = "rbxassetid://10747363465"}),
    Stage    = TabGroup:Tab({Name = "Stage",    Image = "rbxassetid://10734975692"}),
    Claims   = TabGroup:Tab({Name = "Claims",   Image = "rbxassetid://10734963191"}),
    Skill    = TabGroup:Tab({Name = "Skill",    Image = "rbxassetid://10723415903"}),
    Settings = TabGroup:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}

-- ----- Farm Tab -----
local FarmLeft = Tabs.Farm:Section({Side = "Left"})
FarmLeft:Header({Text = "Auto Pickup"})
FarmLeft:Toggle({
    Name = "Auto Pickup", Default = e.AutoPickupEnabled,
    Callback = function(v) e.AutoPickupEnabled = v; saveState() end,
}, "AutoPickupEnabled")
FarmLeft:Input({
    Name = "Min Price (0 = any)", Placeholder = tostring(e.PickupMinPrice),
    AcceptedCharacters = "Numeric",
    Callback = function(t) e.PickupMinPrice = tonumber(t) or 0; saveState() end,
}, "PickupMinPriceInput")
FarmLeft:Dropdown({
    Name = "Rarity Filter (none = any)", Options = RARITY_NAMES, Multi = true,
    Default = (function()
        local arr = {}
        for name in pairs(e.PickupRaritySet) do table.insert(arr, name) end
        return arr
    end)(),
    Callback = function(selected) e.PickupRaritySet = selected or {}; saveState() end,
}, "PickupRarityDropdown")
FarmLeft:Label({Text = "Picks highest-price items first, skips anything\nbelow Min Price / outside the selected Rarity set."})
local pickupStatusLabel = FarmLeft:Label({Text = "Idle"})

local FarmRight = Tabs.Farm:Section({Side = "Right"})
FarmRight:Header({Text = "Auto Train"})
FarmRight:Toggle({
    Name = "Auto Train", Default = e.AutoTrainEnabled,
    Callback = function(v) e.AutoTrainEnabled = v; saveState() end,
}, "AutoTrainEnabled")
FarmRight:Label({Text = "UNVERIFIED: no confirmed call site found in\ngame code for TRAIN_MANUAL_CLICK -- test this\none live and tell me if it does nothing."})
local trainStatusLabel = FarmRight:Label({Text = "Idle"})

-- ----- Sell Tab -----
local SellLeft = Tabs.Sell:Section({Side = "Left"})
SellLeft:Header({Text = "Auto Sell"})
SellLeft:Toggle({
    Name = "Auto Sell", Default = e.AutoSellEnabled,
    Callback = function(v) e.AutoSellEnabled = v; saveState() end,
}, "AutoSellEnabled")
SellLeft:Input({
    Name = "Max Price (0 = any)", Placeholder = tostring(e.SellMaxPrice),
    AcceptedCharacters = "Numeric",
    Callback = function(t) e.SellMaxPrice = tonumber(t) or 0; saveState() end,
}, "SellMaxPriceInput")
SellLeft:Input({
    Name = "Max Rarity (0 = any)", Placeholder = tostring(e.SellMaxRarity),
    AcceptedCharacters = "Numeric",
    Callback = function(t) e.SellMaxRarity = tonumber(t) or 0; saveState() end,
}, "SellMaxRarityInput")
SellLeft:Label({Text = "Sells anything AT OR BELOW both limits.\nNever touches equipped items."})
local sellStatusLabel = SellLeft:Label({Text = "Idle"})

-- ----- Alchemy Tab -----
local AlchemyLeft = Tabs.Alchemy:Section({Side = "Left"})
AlchemyLeft:Header({Text = "Auto Craft Alchemy"})
AlchemyLeft:Toggle({
    Name = "Auto Craft + Collect", Default = e.AutoAlchemyEnabled,
    Callback = function(v) e.AutoAlchemyEnabled = v; saveState() end,
}, "AutoAlchemyEnabled")
AlchemyLeft:Dropdown({
    Name = "Potion", Options = alchemyRecipeLabels, Search = true,
    Default = alchemyIdToLabel[tonumber(e.AlchemyRecipeId)],
    Callback = function(selected)
        if selected and alchemyLabelToId[selected] then
            e.AlchemyRecipeId = alchemyLabelToId[selected]
            saveState()
        end
    end,
}, "AlchemyRecipeDropdown")
AlchemyLeft:Label({Text = "Collects any finished potion, then starts the\nnext craft if materials allow. Repeats every 3s.\nCollect step (ALCHEMY_PICKUP_FINISH_POTION) is\nunverified -- watch for it live."})
local alchemyStatusLabel = AlchemyLeft:Label({Text = "Idle"})

local AlchemyRight = Tabs.Alchemy:Section({Side = "Right"})
AlchemyRight:Header({Text = "Auto Use Potion"})
AlchemyRight:Toggle({
    Name = "Auto Use Potion", Default = e.AutoUsePotionEnabled,
    Callback = function(v) e.AutoUsePotionEnabled = v; saveState() end,
}, "AutoUsePotionEnabled")
AlchemyRight:Dropdown({
    Name = "Potions to Auto Use", Options = USE_POTION_OPTIONS, Multi = true,
    Default = (function()
        local arr = {}
        for name in pairs(e.AutoUsePotionSelected) do table.insert(arr, name) end
        return arr
    end)(),
    Callback = function(selected) e.AutoUsePotionSelected = selected or {}; saveState() end,
}, "AutoUsePotionSelectedDropdown")
AlchemyRight:Label({Text = "Only Training/Lucky buff potions are offered\nhere -- skill-granting alchemy potions are\nnever auto-used. Nothing selected = does\nnothing, even with the toggle on."})
local usePotionStatusLabel = AlchemyRight:Label({Text = "Idle"})

-- ----- Stage Tab -----
local StageLeft = Tabs.Stage:Section({Side = "Left"})
StageLeft:Header({Text = "Auto Stage"})
StageLeft:Toggle({
    Name = "Auto Stage", Default = e.AutoStageEnabled,
    Callback = function(v) e.AutoStageEnabled = v; saveState(); print("[MagicLoot][Toggle] AutoStageEnabled -> " .. tostring(v)) end,
}, "AutoStageEnabled")
StageLeft:Input({
    Name = "Target Stage (0 = disabled)", Placeholder = tostring(e.StageTarget),
    AcceptedCharacters = "Numeric",
    Callback = function(t) e.StageTarget = tonumber(t) or 0; saveState() end,
}, "StageTargetInput")
StageLeft:Toggle({
    Name = "Return Town on Bag Full", Default = e.AutoReturnOnBagFull,
    Callback = function(v) e.AutoReturnOnBagFull = v; saveState() end,
}, "AutoReturnOnBagFull")
StageLeft:Slider({
    Name = "Mob Hover Height", Minimum = 3, Maximum = 40,
    Default = e.MobHoverHeight, Precision = 0,
    Callback = function(v) e.MobHoverHeight = v; saveState() end,
}, "MobHoverHeightSlider")
StageLeft:Label({Text = "Snaps onto the nearest live monster every 0.3s\nso skills stay in range, until DungeonAggroStage\nreaches the target -- then fires DUNGEON_RETURN_TOWN.\nWith Bag Full ON, also returns early if either the\nstage bag or the total bag hits its cap -- then loops\nback into a fresh run either way."})
local stageStatusLabel = StageLeft:Label({Text = "Idle"})

-- ----- Claims Tab -----
local ClaimsLeft = Tabs.Claims:Section({Side = "Left"})
ClaimsLeft:Header({Text = "Auto Claim Daily"})
ClaimsLeft:Toggle({
    Name = "Auto Claim Daily", Default = e.AutoClaimDailyEnabled,
    Callback = function(v) e.AutoClaimDailyEnabled = v; saveState(); print("[MagicLoot][Toggle] AutoClaimDailyEnabled -> " .. tostring(v)) end,
}, "AutoClaimDailyEnabled")
local claimDailyStatusLabel = ClaimsLeft:Label({Text = "Idle"})

ClaimsLeft:Header({Text = "Auto Rebirth"})
ClaimsLeft:Toggle({
    Name = "Auto Rebirth", Default = e.AutoRebirthEnabled,
    Callback = function(v) e.AutoRebirthEnabled = v; saveState() end,
}, "AutoRebirthEnabled")
local rebirthStatusLabel = ClaimsLeft:Label({Text = "Idle"})

local ClaimsRight = Tabs.Claims:Section({Side = "Right"})
ClaimsRight:Header({Text = "Redeem Codes"})
local redeemCodesText = ""
ClaimsRight:Input({
    Name = "Codes (comma or space separated)", Placeholder = "CODE1, CODE2",
    Callback = function(t) redeemCodesText = t or "" end,
}, "RedeemCodesInput")
local redeemStatusLabel = ClaimsRight:Label({Text = "Ready"})
ClaimsRight:Button({Name = "Redeem Now", Callback = function()
    redeemStatusLabel:UpdateName("Redeeming...")
    doRedeemCodes(redeemCodesText, function(claimed, tried)
        pcall(function() redeemStatusLabel:UpdateName("Redeemed " .. claimed .. "/" .. tried) end)
    end)
end})

-- ----- Skill Tab -----
local SkillLeft = Tabs.Skill:Section({Side = "Left"})
SkillLeft:Header({Text = "Skill NoCooldown"})
SkillLeft:Toggle({
    Name = "Skill NoCooldown", Default = e.SkillNoCooldownEnabled,
    Callback = function(v)
        e.SkillNoCooldownEnabled = v
        applySkillNoCooldown(v)
        saveState()
    end,
}, "SkillNoCooldownEnabled")
SkillLeft:Label({Text = "Skills already auto-cast on their own.\nThis removes the per-skill cooldown gate\nso they fire back-to-back instead of waiting."})

-- ----- Settings Tab -----
local SettingsLeft = Tabs.Settings:Section({Side = "Left"})
SettingsLeft:Header({Text = "General"})
SettingsLeft:Toggle({
    Name = "Anti-AFK", Default = e.AntiAFKEnabled,
    Callback = function(v) e.AntiAFKEnabled = v; saveState() end,
}, "AntiAFKEnabled")
SettingsLeft:Toggle({
    Name = "Auto Reconnect", Default = e.AutoReconnectEnabled,
    Callback = function(v) e.AutoReconnectEnabled = v; saveState() end,
}, "AutoReconnectEnabled")
SettingsLeft:Keybind({
    Name = "Show/Hide UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
    Callback = function() pcall(function() Window:SetState(not Window:GetState()) end) end,
}, "MagicLootToggleUIKeybind")
SettingsLeft:Header({Text = "Auto Save"})
SettingsLeft:Label({Text = "All toggles save automatically to:\n" .. SAVE_FILE})

local SettingsRight = Tabs.Settings:Section({Side = "Right"})
SettingsRight:Header({Text = "Movement"})
SettingsRight:Toggle({
    Name = "Speed", Default = e.WalkSpeedEnabled,
    Callback = function(v) e.WalkSpeedEnabled = v; applyMovement(); saveState() end,
}, "WalkSpeedEnabled")
SettingsRight:Slider({
    Name = "Speed Value", Minimum = 16, Maximum = 200,
    Default = e.WalkSpeedValue, Precision = 0,
    Callback = function(v) e.WalkSpeedValue = v; applyMovement(); saveState() end,
})
SettingsRight:Toggle({
    Name = "Jump Power", Default = e.JumpPowerEnabled,
    Callback = function(v) e.JumpPowerEnabled = v; applyMovement(); saveState() end,
}, "JumpPowerEnabled")
SettingsRight:Slider({
    Name = "Jump Value", Minimum = 50, Maximum = 300,
    Default = e.JumpPowerValue, Precision = 0,
    Callback = function(v) e.JumpPowerValue = v; applyMovement(); saveState() end,
})

-- ===== Background loops =====
task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoPickup)
        pcall(function() pickupStatusLabel:UpdateName(pickupStatusText) end)
        task.wait(0.15)
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoTrain)
        pcall(function() trainStatusLabel:UpdateName(trainStatusText) end)
        task.wait(0.01)
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoSell)
        pcall(function() sellStatusLabel:UpdateName(sellStatusText) end)
        task.wait(3)
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoCraftAlchemy)
        pcall(function() alchemyStatusLabel:UpdateName(alchemyStatusText) end)
        task.wait(3)
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoUsePotion)
        pcall(function() usePotionStatusLabel:UpdateName(usePotionStatusText) end)
        task.wait(3)
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoStage)
        pcall(function() stageStatusLabel:UpdateName(stageStatusText) end)
        task.wait(1)
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        if e.AutoStageEnabled then
            pcall(teleportToNearestMob)
        else
            pcall(stopStageTeleport)
        end
        task.wait(0.3)
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoClaimDaily)
        pcall(function() claimDailyStatusLabel:UpdateName(claimDailyStatusText) end)
        task.wait(30)
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoRebirth)
        pcall(function() rebirthStatusLabel:UpdateName(rebirthStatusText) end)
        task.wait(5)
    end
end)

if e.SkillNoCooldownEnabled then applySkillNoCooldown(true) end
applyMovement()

getgenv().__MLWindow = Window
Tabs.Farm:Select()
print("[MagicLoot] v1.0 loaded")
