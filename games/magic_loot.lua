-- Magic Loot[Beta] Automation v1.0
-- Auto Pickup (price/rarity filter, high-to-low priority) + Auto Train +
-- Auto Claim Daily + Auto Sell (price/rarity filter) + Auto Craft Alchemy
-- (craft+collect loop) + Auto Stage (farm to target, return town) +
-- Auto Rebirth + Auto Redeem Code + Settings
-- (Anti-AFK, Speed, Jump, Auto Save, Auto Reconnect)
--
-- This game dispatches everything through one generic channel --
-- NetWork.FireServer(NetMsg.X, ...) / NetWork.InvokeServer(NetMsg.X, ...) --
-- from ReplicatedFirst.AllSideCode.UtilsSystem, with human-readable message
-- names (123 of them). Confirmed live by hooking NetWork.FireServer/
-- InvokeServer and capturing real traffic during an actual dungeon run:
--   DROP_PICKUP(dropGuid), DUNGEON_SPAWN_STAGE(stageNum), DUNGEON_RETURN_TOWN()
--   RELEASE_GROUP_SKILL(slot, {...}) -- 174 calls, confirms skills already
--   auto-fire on their own with zero manual input, so nothing here casts.
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

-- __MLWindow is only assigned on the last line of this file, so any run that
-- died partway left its window on screen with nothing tracking it -- five of
-- them piled up during one debugging session. Sweep by title instead of
-- trusting the handle, so a crashed predecessor still gets cleaned up.
pcall(function()
    local host = (gethui and gethui()) or game:GetService("CoreGui")
    for _, gui in ipairs(host:GetChildren()) do
        if gui:IsA("ScreenGui") then
            for _, d in ipairs(gui:GetDescendants()) do
                if d:IsA("TextLabel") and d.Text == "Magic Loot [Beta]" then
                    gui:Destroy()
                    break
                end
            end
        end
    end
end)

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local LocalPlayer = Players.LocalPlayer

-- This used to be a bare require on line one of the real work, which is exactly
-- what made autoexec run this script three times on a fresh join. Injected that
-- early, ReplicatedFirst.AllSideCode has not replicated yet, so the require
-- threw "AllSideCode is not a valid member of ReplicatedFirst" -- and the
-- autoexec wrapper counted a thrown script as a failed fetch and re-ran the
-- whole file. Attempt two then got further and died on PlayerData still being
-- nil (the game logs "加载业务模块失败: PlayerData" at that point -- UtilsSystem
-- resolves before its own submodules finish loading). Each dead attempt left a
-- window behind. Wait for the folder, then wait for the submodules to actually
-- populate, before touching anything.
local AllSideCode = ReplicatedFirst:WaitForChild("AllSideCode", 30)
if not AllSideCode then
    warn("[MagicLoot] AllSideCode never replicated -- aborting cleanly instead of erroring")
    return
end
local UtilsSystem = require(AllSideCode:WaitForChild("UtilsSystem", 30))

local NetWork, NetMsg, PlayerData, CfgFind, GetData
do
    local REQUIRED = { "NetWork", "NetMsg", "PlayerData", "CfgFind", "GetData" }
    local deadline = os.clock() + 30
    while os.clock() < deadline do
        local missing
        for _, name in ipairs(REQUIRED) do
            if UtilsSystem[name] == nil then missing = name break end
        end
        if not missing then break end
        task.wait(0.2)
    end
    NetWork    = UtilsSystem.NetWork
    NetMsg     = UtilsSystem.NetMsg
    PlayerData = UtilsSystem.PlayerData
    CfgFind    = UtilsSystem.CfgFind
    GetData    = UtilsSystem.GetData
    for _, name in ipairs(REQUIRED) do
        if UtilsSystem[name] == nil then
            warn("[MagicLoot] UtilsSystem." .. name .. " never loaded -- aborting cleanly")
            return
        end
    end
end
local CollectionService = game:GetService("CollectionService")

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
    "AutoTrainEnabled", "TrainZoneMode", "TrainZoneId", "TrainManualTapEnabled", "TrainTapRate",
    "AutoClaimDailyEnabled",
    "AutoDinoRollEnabled", "DinoRollBatch", "DinoRollKeepTickets",
    "AutoDinoQuestEnabled",
    "AutoSellEnabled", "SellIgnoreIds",
    "AutoAlchemyEnabled", "AlchemyRecipeId", "AutoUsePotionEnabled", "AutoUsePotionSelected",
    "AutoStageEnabled", "StageTarget", "AutoReturnOnBagFull", "MobHoverHeight", "StageSavedPositions",
    "AutoStageJumpEnabled", "StageJumpPick",
    "AutoRebirthEnabled",
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

-- ===== Short amounts (1k / 150m / 1.5b / 1t) =====
-- Drop values in this game span 8 to 6,950,000,000 -- read live off the whole
-- materialConf table. Typing that range digit by digit is how you end up filtering
-- at 195000000 when you meant 1950000000, and the old Min Price control could not
-- express it at all: it was a slider capped at 50000, so every threshold above
-- fifty thousand was simply unreachable while the items ran to seven billion.
local AMOUNT_SUFFIX = {k = 1e3, m = 1e6, b = 1e9, t = 1e12}

local function parseAmount(value)
    if type(value) == "number" then return math.max(0, math.floor(value)) end
    local text = tostring(value or ""):gsub("[%s,]", ""):lower()
    if text == "" then return 0 end
    local numberPart, suffix = text:match("^(%d*%.?%d+)([kmbt]?)$")
    if not numberPart then return nil end
    local amount = tonumber(numberPart)
    if not amount then return nil end
    return math.floor(amount * (AMOUNT_SUFFIX[suffix] or 1))
end

local function formatAmount(amount)
    amount = tonumber(amount) or 0
    -- Descending so the largest fitting unit wins; 1e12 first or 1t prints as 1000b.
    for _, unit in ipairs({{1e12, "t"}, {1e9, "b"}, {1e6, "m"}, {1e3, "k"}}) do
        if amount >= unit[1] then
            local scaled = amount / unit[1]
            -- %.15g rather than a fixed precision: 1.5b keeps its half, 2b does
            -- not become "2.0b", and nothing prints in exponent form.
            return string.format("%.15g", math.floor(scaled * 100 + 0.5) / 100) .. unit[2]
        end
    end
    return tostring(math.floor(amount))
end

local e = getgenv()
if e.AutoPickupEnabled == nil then e.AutoPickupEnabled = false end
-- Accepts a raw number or a short string either way, so setting
-- getgenv().PickupMinPrice = "150m" by hand works exactly like picking it.
e.PickupMinPrice = parseAmount(e.PickupMinPrice) or 0
if e.PickupRaritySet == nil then e.PickupRaritySet = {} end
if e.AutoTrainEnabled == nil then e.AutoTrainEnabled = false end
if e.TrainZoneMode == nil then e.TrainZoneMode = "Best" end
if e.TrainZoneId == nil then e.TrainZoneId = 0 end
if e.TrainManualTapEnabled == nil then e.TrainManualTapEnabled = true end
-- Older builds let this go down to 0.02 and saved it. tapInterval() clamps at
-- use, so a stale 0.02 was harmless but the slider still displayed it -- a number
-- the server will not honour, sitting in the UI looking authoritative. Normalise
-- it on load so what is saved, what is shown, and what is sent all agree.
if e.TrainTapRate == nil then e.TrainTapRate = 0.125 end
e.TrainTapRate = math.max(0.125, tonumber(e.TrainTapRate) or 0.125)
if e.AutoClaimDailyEnabled == nil then e.AutoClaimDailyEnabled = false end
if e.AutoDinoRollEnabled == nil then e.AutoDinoRollEnabled = false end
if e.DinoRollBatch == nil then e.DinoRollBatch = 1 end
if e.DinoRollKeepTickets == nil then e.DinoRollKeepTickets = 0 end
if e.AutoDinoQuestEnabled == nil then e.AutoDinoQuestEnabled = false end
if e.AutoSellEnabled == nil then e.AutoSellEnabled = false end
if e.SellIgnoreIds == nil then e.SellIgnoreIds = {} end
if e.AutoAlchemyEnabled == nil then e.AutoAlchemyEnabled = false end
if e.AutoUsePotionEnabled == nil then e.AutoUsePotionEnabled = false end
if e.AutoUsePotionSelected == nil then e.AutoUsePotionSelected = {} end
if e.AlchemyRecipeId == nil then e.AlchemyRecipeId = "" end
if e.AutoStageEnabled == nil then e.AutoStageEnabled = false end
if e.StageTarget == nil then e.StageTarget = 0 end
if e.AutoReturnOnBagFull == nil then e.AutoReturnOnBagFull = false end
if e.MobHoverHeight == nil then e.MobHoverHeight = 12 end
if e.StageSavedPositions == nil then e.StageSavedPositions = {} end
if e.AutoStageJumpEnabled == nil then e.AutoStageJumpEnabled = true end
-- 0 = follow Target Stage automatically, anything else = jump exactly there
if e.StageJumpPick == nil then e.StageJumpPick = 0 end
if e.AutoRebirthEnabled == nil then e.AutoRebirthEnabled = false end
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
-- The pickup loop repaints this status every 0.15s. A message written from the
-- Min Price box would be gone before it could be read, so the loop holds off
-- while a hint is fresh. Declared here, not down in the UI, because doAutoPickup
-- closes over it and a later `local` would leave this reading a stray global.
local pickupPriceHintUntil = 0
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
    -- A hint from the Min Price box owns the status line for three seconds.
    if os.clock() < pickupPriceHintUntil then return end
    if not e.AutoPickupEnabled then pickupStatusText = "Idle"; return end
    local items = getDropItems()
    -- price high -> low priority, exactly as requested
    table.sort(items, function(a, b) return a.gold > b.gold end)
    -- parseAmount, not tonumber -- a hand-set getgenv().PickupMinPrice = "150m"
    -- would read as nil through tonumber and silently collapse the filter to 0,
    -- picking up everything while the panel still claimed a threshold.
    local minPrice = parseAmount(e.PickupMinPrice) or 0
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
    -- Threshold echoed back in the same shorthand it was picked in, so a filter
    -- that is quietly rejecting everything shows its own reason.
    local threshold = minPrice > 0 and ("min " .. formatAmount(minPrice)) or "any price"
    pickupStatusText = fired > 0
        and ("Picked up " .. fired .. " item(s) -- " .. threshold)
        or (#items .. " drop(s) on ground, none above " .. threshold)
end

-- ===== Auto Train (rewritten -- the game moved training server-side) =====
-- The old build spammed TRAIN_MANUAL_CLICK every 0.01s and called that Auto
-- Train. That stopped paying, and not because the remote broke. Measured live,
-- standing in zone 5:
--     CalcTrainGain            21,000,000,000 per click
--     idle 3s, zero clicks     +1,008,000,000,000
--     clicking 0.01s for 3s    +1,008,000,000,000   accepted=0  rejected=26
--     clicking 0.2s  for 3s    +1,008,000,000,000   accepted=0  rejected=10
-- Identical to idle either way. That was read as "there is a click quota and we
-- burned it", which was WRONG, and the wrong diagnosis is what left Manual Tap
-- looking broken ever since: it was left switched on inside the very mode that
-- makes it impossible.
--
-- Re-measured properly, A/B, in and out of a zone. The rule is not a quota:
--   INSIDE a zone   idle 6s  +4,032,000,000,000
--                   click 6s +4,032,000,000,000   accepted=0   rejected=11
--   OUTSIDE a zone  idle 6s  +0
--                   click 6s +462,000,000,000     accepted=11  rejected=0
-- The server REJECTS every manual click while TRAIN_AUTO_TICK is already paying
-- you. Manual tapping is not throttled, it is mutually exclusive with standing
-- in a zone. Best/Manual mode parks you in a zone, so the tap could never land
-- there -- not once, ever. That is the whole bug.
--
-- Outside a zone the tap does pay, at 42B per accepted click, with a real
-- ceiling near 8 accepted/sec measured across three rates:
--   0.20s  22 accepted   0 rejected   154B/sec
--   0.05s  45 accepted   1 rejected   315B/sec
--   0.01s  47 accepted  18 rejected   329B/sec
-- So anything faster than ~0.125s buys nothing but rejections. TAP_MIN_INTERVAL
-- clamps to that instead of letting the slider ask for 0.02s and get 18 refusals
-- for every 47 hits.
--
-- Which means tapping is worth about a 4x zone (330B/sec against zone 5's
-- measured 672B/sec). It beats zones 1-3, loses to 4 and up. The zone table:
--   1=1.5x free   2=2x(Rb2)   3=4x(Rb5)   4=6x(Rb9)   5=8x(Rb12)
--   6=10x RobuxTrain1   7=15x(Rb18)   8=25x RobuxTrain2   9=100x RobuxTrain3
-- so on an account that can reach zone 4+, parking out-earns tapping; on a fresh
-- account that can only reach zone 1, tapping is more than 2x better. The panel
-- prints both numbers live so the call is visible instead of assumed -- but the
-- choice stays the user's, because Manual Tap also means "do not move me", and
-- that is worth something no rate comparison can express.
--
local trainStatusText = "Idle"
local trainPlanText = "Comparing zone vs tap..."
local lastTrainTap = 0
local lastTrainPlanRefresh = 0
-- Rolling counters so the panel can prove the tap is landing instead of the user
-- having to trust that it is.
local tapAccepted, tapRejected = 0, 0

-- ~8 accepted/sec is the server's real ceiling; below this interval every extra
-- call comes back rejected.
local TAP_MIN_INTERVAL = 0.125
-- 42B per accepted click x 8/sec, measured.
local TAP_RATE_PER_SEC = 42000000000 * 8
-- Zone 5 (8x) measured at 672B/sec, so one multiplier point is worth 84B/sec.
local ZONE_RATE_PER_MULTIPLIER = 84000000000

local function tapInterval()
    return math.max(TAP_MIN_INTERVAL, tonumber(e.TrainTapRate) or TAP_MIN_INTERVAL)
end

local function inTrainZone()
    local inGroundVal = LocalPlayer:FindFirstChild("InTrainGround")
    return inGroundVal and inGroundVal.Value == true
end

-- What the zone the character happens to be standing in pays, whether or not
-- this script put them there.
local function trainZoneRateHere()
    local groundIdVal = LocalPlayer:FindFirstChild("TrainGroundId")
    local id = groundIdVal and tonumber(groundIdVal.Value) or 0
    if id <= 0 then return 0 end
    local ok, cfg = pcall(function() return CfgFind.FindTrainCfgById(id) end)
    local add = (ok and cfg and tonumber(cfg.Add)) or 0
    return add * ZONE_RATE_PER_MULTIPLIER
end

-- One tap, but only where a tap can possibly be accepted. Inside a zone the
-- server refuses every one of these, so firing there is pure noise on the wire.
local function tryTrainTap()
    if not e.TrainManualTapEnabled then return false, "tap off" end
    if inTrainZone() then return false, "in zone -- server rejects taps here" end
    -- This is the ONLY pacer. The loop below used to also task.wait(tapInterval())
    -- and then this line re-checked the same interval -- two throttles on one
    -- number, so any iteration whose sleep came back a hair early was thrown away
    -- and the next one paid the full wait again. That halved the real rate:
    -- 203B/sec measured against a 330B/sec ceiling. The loop now ticks on a short
    -- fixed slice and this gate keeps the actual spacing honest.
    if (os.clock() - lastTrainTap) < tapInterval() then return false, nil end
    lastTrainTap = os.clock()
    local result = invoke(NetMsg.TRAIN_MANUAL_CLICK)
    if type(result) == "table" and result.ok then
        tapAccepted += 1
        return true, nil
    end
    tapRejected += 1
    return false, nil
end

local function formatRate(perSec)
    if perSec >= 1e12 then return string.format("%.1fT/s", perSec / 1e12) end
    return string.format("%.0fB/s", perSec / 1e9)
end

local function getTrainZones()
    local zones = {}
    for _, inst in ipairs(CollectionService:GetTagged("Train")) do
        local okId, id = pcall(function() return GetData.GetTrainIdFromInstance(inst) end)
        local okZone, zonePart = pcall(function() return GetData.ResolveZonePart(inst) end)
        if okId and id and okZone and zonePart then
            local okCfg, cfg = pcall(function() return CfgFind.FindTrainCfgById(id) end)
            local okCan, can = pcall(function() return GetData.CanEnterTrainGround(LocalPlayer, id) end)
            zones[id] = {
                id = id,
                part = zonePart,
                add = (okCfg and cfg and tonumber(cfg.Add)) or 0,
                rebirth = (okCfg and cfg and tonumber(cfg.Rebirth)) or 0,
                passTag = (okCfg and cfg and cfg.OnlyTag) or "",
                canEnter = okCan and type(can) == "table" and can.ok == true,
                reason = okCan and type(can) == "table" and can.reason or nil,
            }
        end
    end
    return zones
end

-- Highest Add the account is actually allowed into. Reading CanEnterTrainGround
-- rather than comparing Rebirth ourselves -- zone 6/8/9 gate on a GamePass, not
-- a rebirth count, and the server is the one that decides either way.
local function pickBestTrainZone(zones)
    local best
    for _, z in pairs(zones) do
        if z.canEnter and (not best or z.add > best.add) then best = z end
    end
    return best
end

-- Zone income vs tap income, both from measured constants, so the panel can say
-- which one this account should actually be doing instead of leaving the user to
-- work it out from a multiplier.
-- Printed whether or not Manual Tap is on, because the whole question the user
-- actually has is "am I leaving money on the table by not warping?" -- and the
-- answer flips with rebirth count, so a fixed sentence in a label would go stale.
local function refreshTrainPlan()
    local zones = getTrainZones()
    if not next(zones) then trainPlanText = "No zones in range (not in the lobby)"; return end
    local best = pickBestTrainZone(zones)
    local zoneRate = best and (best.add * ZONE_RATE_PER_MULTIPLIER) or 0
    trainPlanText = string.format("Tap in place %s  |  best zone %s = %s  ->  %s pays more",
        formatRate(TAP_RATE_PER_SEC),
        best and tostring(best.id) or "-", formatRate(zoneRate),
        zoneRate > TAP_RATE_PER_SEC and ("zone " .. tostring(best.id)) or "tapping")
end

-- Manual Tap is train-in-place: it NEVER touches CFrame. That is the point of it
-- -- ordinary training from wherever you are standing, no teleport to a zone.
-- It is also the only arrangement where a tap can be accepted at all, since the
-- server refuses manual clicks whenever it is already auto-ticking you inside a
-- zone. So the toggle overrides Zone Mode outright rather than combining with it.
local function doTapInPlaceTrain()
    if inTrainZone() then
        local groundIdVal = LocalPlayer:FindFirstChild("TrainGroundId")
        trainStatusText = string.format(
            "Standing in zone %s -- earning %s passively (taps are refused inside a zone)",
            tostring(groundIdVal and groundIdVal.Value or "?"), formatRate(trainZoneRateHere()))
        return
    end
    tryTrainTap()
    trainStatusText = string.format("Tapping in place @%.3fs -- ok %d / rejected %d  (~%s)",
        tapInterval(), tapAccepted, tapRejected, formatRate(TAP_RATE_PER_SEC))
end

local function doAutoTrain()
    if not e.AutoTrainEnabled then
        -- Manual Tap overrides Zone Mode, which makes it read like the main
        -- switch -- but Auto Train still gates the whole loop, so a panel showing
        -- "Manual Tap: on" over a bare "Idle" looks like a broken tap rather than
        -- a switch that was never thrown. Name the actual blocker.
        trainStatusText = e.TrainManualTapEnabled
            and "Auto Train is OFF -- Manual Tap cannot fire until you switch it on"
            or "Idle"
        return
    end

    -- Manual Tap wins outright over Zone Mode. It means "train normally, right
    -- here" -- nothing below this line runs, so the character is never moved.
    if e.TrainManualTapEnabled then return doTapInPlaceTrain() end

    local zones = getTrainZones()
    if not next(zones) then trainStatusText = "No Train zones found -- not in the lobby?"; return end

    local target
    if e.TrainZoneMode == "Manual" and tonumber(e.TrainZoneId) and tonumber(e.TrainZoneId) > 0 then
        target = zones[tonumber(e.TrainZoneId)]
        if not target then trainStatusText = "Zone " .. tostring(e.TrainZoneId) .. " does not exist"; return end
        if not target.canEnter then
            trainStatusText = "Zone " .. target.id .. " locked (" .. tostring(target.reason) .. ") -- pick another"
            return
        end
    else
        target = pickBestTrainZone(zones)
        if not target then
            trainStatusText = "No zone this account can enter -- switch on Manual Tap"
            return
        end
    end

    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then trainStatusText = "No character"; return end

    local groundIdVal = LocalPlayer:FindFirstChild("TrainGroundId")
    local autoVal = LocalPlayer:FindFirstChild("IsAutoTraining")
    local currentId = groundIdVal and tonumber(groundIdVal.Value) or 0

    -- Only move when actually out of position. Re-CFraming a player who is
    -- already parked and earning would fight their own movement for no gain.
    if (not inTrainZone()) or currentId ~= target.id then
        hrp.CFrame = CFrame.new(target.part.Position + Vector3.new(0, 4, 0))
        trainStatusText = string.format("Moving to zone %d (%.1fx)", target.id, target.add)
        return
    end

    -- No tap here on purpose. The server refuses every manual click while it is
    -- already auto-ticking you, so the old call in this branch was 2 rejected
    -- remotes a second forever -- the whole reason Manual Tap read as broken.
    trainStatusText = string.format("Zone %d (%.1fx) -- earning %s  auto=%s",
        target.id, target.add, formatRate(target.add * ZONE_RATE_PER_MULTIPLIER),
        tostring(autoVal and autoVal.Value))
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

-- ===== Dino Event (远古魔法复苏 / "Ancient Magic Reborn", event id 1) =====
-- Both remotes captured live against the running server, not read off the UI:
--   InvokeServer(EVENT_HATCH_DRAW, 1)      -> {times=1, itemIds={...}}
--                                             ticket 1 -> 0
--   InvokeServer(EVENT_TASK_CLAIM, onlyTag) -> true
--                                             Completed[tag] nil -> 1
-- The draw arg is a plain roll count (the UI offers 1 / 3 / 10), NOT a table --
-- and the ticket is a real bag item, id 9 "活动抽奖券", separate from the Dino
-- Coin shop currency at id 8. Free tickets drip in at TicketIntervalSec=900,
-- capped at TicketDailyMax=3 a day, so this is a slow trickle, not a faucet.
local EVENT_TICKET_ITEM_ID = 9
local EVENT_COIN_ITEM_ID = 8

local function countBagItem(itemId)
    local bag = PlayerData.GetPlrDataByKey(LocalPlayer, "Bag")
    if type(bag) ~= "table" then return 0 end
    local total = 0
    for _, entry in pairs(bag) do
        if type(entry) == "table" and tonumber(entry.id) == itemId then
            total += tonumber(entry.count) or 0
        end
    end
    return total
end

local dinoRollStatusText = "Toggle is OFF"
local function doAutoDinoRoll()
    if not e.AutoDinoRollEnabled then dinoRollStatusText = "Toggle is OFF"; return end

    local activeOk, activeCfg = pcall(function() return CfgFind.GetActiveEventCfg() end)
    if not activeOk or type(activeCfg) ~= "table" then
        dinoRollStatusText = "No event running right now"
        return
    end

    local batch = tonumber(e.DinoRollBatch) or 1
    local keep = math.max(0, tonumber(e.DinoRollKeepTickets) or 0)
    local tickets = countBagItem(EVENT_TICKET_ITEM_ID)
    local spendable = tickets - keep

    if spendable < batch then
        dinoRollStatusText = string.format("Tickets %d (keep %d) -- need %d for x%d", tickets, keep, batch, batch)
        return
    end

    local result = invoke(NetMsg.EVENT_HATCH_DRAW, batch)
    if type(result) == "table" then
        local drawn = tonumber(result.times) or batch
        local coins = countBagItem(EVENT_COIN_ITEM_ID)
        dinoRollStatusText = string.format("Rolled x%d -- tickets left %d, coins %d",
            drawn, countBagItem(EVENT_TICKET_ITEM_ID), coins)
    else
        -- Server said no. Almost always "not enough tickets for this batch size"
        -- (x3/x10 each want that many), so say so instead of a bare failure.
        dinoRollStatusText = string.format("Server refused x%d roll (had %d ticket(s))", batch, tickets)
    end
end

-- ResetType is numeric in taskConf: 1=Timed, 2=Daily, 3=Once -- and the player
-- side stores each under a NAMED bucket in Event.EventTask, so the two have to
-- be mapped explicitly. Target count lives in cfg.need[1] (a table, not a
-- number), progress in bucket.Progress[onlyTag], and bucket.Completed[onlyTag]
-- is set to 1 once claimed. Claimable is exactly: progress >= need and not
-- already in Completed.
local DINO_RESET_BUCKETS = { [1] = "Timed", [2] = "Daily", [3] = "Once" }

local dinoQuestStatusText = "Toggle is OFF"
local function collectDinoTasks()
    local rows = {}
    local ev = PlayerData.GetPlrDataByKey(LocalPlayer, "Event")
    local eventTask = type(ev) == "table" and ev.EventTask or nil
    if type(eventTask) ~= "table" then return rows end

    for resetType, bucketName in pairs(DINO_RESET_BUCKETS) do
        local okList, list = pcall(function() return CfgFind.GetTaskListByResetType(resetType) end)
        local bucket = eventTask[bucketName]
        if okList and type(list) == "table" and type(bucket) == "table" then
            local progressMap = type(bucket.Progress) == "table" and bucket.Progress or {}
            local completedMap = type(bucket.Completed) == "table" and bucket.Completed or {}
            for _, cfg in ipairs(list) do
                local tag = cfg.onlyTag
                if type(tag) == "string" and tag ~= "" then
                    local need = type(cfg.need) == "table" and (tonumber(cfg.need[1]) or 0) or (tonumber(cfg.need) or 0)
                    local progress = tonumber(progressMap[tag]) or 0
                    local claimed = completedMap[tag] ~= nil
                    table.insert(rows, {
                        bucket = bucketName, tag = tag, need = need,
                        progress = progress, claimed = claimed,
                        canClaim = (not claimed) and need > 0 and progress >= need,
                    })
                end
            end
        end
    end
    return rows
end

local function doAutoDinoQuest()
    if not e.AutoDinoQuestEnabled then dinoQuestStatusText = "Toggle is OFF"; return end

    local rows = collectDinoTasks()
    if #rows == 0 then dinoQuestStatusText = "No event task data"; return end

    local claimed, pending = 0, 0
    for _, row in ipairs(rows) do
        if row.canClaim then
            local result = invoke(NetMsg.EVENT_TASK_CLAIM, row.tag)
            print("[MagicLoot][DinoQuest] " .. row.bucket .. " " .. row.tag ..
                " (" .. row.progress .. "/" .. row.need .. ") -> " .. tostring(result))
            if result == true then claimed += 1 end
            task.wait(0.25)
        elseif not row.claimed then
            pending += 1
        end
    end

    if claimed > 0 then
        dinoQuestStatusText = "Claimed " .. claimed .. " task(s), " .. pending .. " still in progress"
    else
        dinoQuestStatusText = pending .. " task(s) in progress, nothing ready"
    end
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
--
-- A LOCKED entry poisons the batch exactly the same way, and that one cost a
-- real "Tried 32 item(s), server did not confirm": 9 of those 32 carried
-- lock==1 (the padlock in the game's own backpack UI, BAG_LOCK_ITEMS) and took
-- the other 23 down with them. Proven at zero risk by sending a batch of one
-- locked item -- returned false, item still in the bag afterwards. So lock is
-- filtered alongside equip, and because the lock is set in the game's own UI it
-- doubles as an ignore list the player can drive without this panel.
--
-- ===== Sell ignore list =====
-- 48 materials, read live from materialConf. Only materials are listed because
-- SELL_MATERIAL only ever sees tp==2 -- offering the whole item table would put
-- hundreds of rows in the dropdown that this feature can never act on.
--
-- English names come from TranslationHelper.TranslateByKey(ZhName), resolved
-- live. The potion table further up is hardcoded because require()'ing the
-- translation module returns an empty table in this executor -- but
-- TranslateByKey is a different door into the same data and it does work:
-- GetLocaleId() reads "en-us" and CheckTranslateByKey confirms a real entry for
-- all 48 before any of this is trusted. Anything that somehow has no translation
-- keeps its ZhName rather than vanishing from the list.
--
-- Sorted by rarity ascending, then by value -- junk first, which is the order
-- someone scanning for "what am I about to lose" actually reads in.
local sellIgnoreLabels = {}
local sellLabelToId = {}
local sellIdToLabel = {}
do
    local translate
    do
        local ok, TH = pcall(function() return UtilsSystem.TranslationHelper end)
        if ok and type(TH) == "table" and type(TH.TranslateByKey) == "function" then
            translate = TH.TranslateByKey
        end
    end
    local okConf, conf = pcall(function() return CfgFind.GetCfgByName("materialConf") end)
    if okConf and type(conf) == "table" then
        local rows = {}
        for id, cfg in pairs(conf) do
            local numericId = tonumber(id)
            if numericId and type(cfg) == "table" then
                local name = cfg.ZhName
                if translate then
                    local okName, translated = pcall(translate, cfg.ZhName)
                    if okName and type(translated) == "string" and translated ~= "" then
                        name = translated
                    end
                end
                table.insert(rows, {
                    id = numericId,
                    name = name or ("Material " .. numericId),
                    xyd = tonumber(cfg.xyd) or 0,
                    gold = tonumber(cfg.GoldValue) or 0,
                })
            end
        end
        table.sort(rows, function(a, b)
            if a.xyd ~= b.xyd then return a.xyd < b.xyd end
            if a.gold ~= b.gold then return a.gold < b.gold end
            return a.id < b.id
        end)
        for _, row in ipairs(rows) do
            local label = row.name .. " (" .. (RARITY_NAMES_EN[row.xyd] or ("Rarity " .. row.xyd)) .. ")"
            -- Two materials sharing a name AND a rarity would collide on the
            -- label key and one would silently become un-ignorable. None do
            -- today; disambiguate by id if that ever changes.
            if sellLabelToId[label] then label = label .. " #" .. row.id end
            table.insert(sellIgnoreLabels, label)
            sellLabelToId[label] = row.id
            sellIdToLabel[row.id] = label
        end
    end
end

local sellStatusText = "Toggle is OFF"
local function doAutoSell()
    if not e.AutoSellEnabled then sellStatusText = "Toggle is OFF"; return end
    local bag = PlayerData.GetPlrDataByKey(LocalPlayer, "Bag")
    if type(bag) ~= "table" then sellStatusText = "No bag data"; return end
    -- Keyed by item id, not by the dropdown's label. Labels are translated at
    -- load, so a language change would silently orphan every saved entry and the
    -- ignore list would quietly start selling the things it was protecting. Ids
    -- do not move.
    local ignoreIds = type(e.SellIgnoreIds) == "table" and e.SellIgnoreIds or {}
    local ids = {}
    local ignoredCount, lockedCount = 0, 0
    for onlyIdKey, entry in pairs(bag) do
        if type(entry) == "table" and entry.equip ~= 1 and tostring(entry.tp) == "2" then
            if tonumber(entry.lock) == 1 then
                lockedCount += 1
            elseif ignoreIds[tostring(entry.id)] then
                ignoredCount += 1
            else
                table.insert(ids, tonumber(entry.onlyID) or tonumber(onlyIdKey))
            end
        end
    end
    -- Both counts get reported. Without them "Nothing matching filter" cannot
    -- tell the ignore list apart from a bag full of padlocks, and the padlocks
    -- are the ones that used to fail the whole batch silently.
    local keptParts = {}
    if #ids == 0 or ignoredCount > 0 then table.insert(keptParts, ignoredCount .. " on ignore list") end
    if lockedCount > 0 then table.insert(keptParts, lockedCount .. " locked") end
    local keptNote = #keptParts > 0 and ("  (kept: " .. table.concat(keptParts, ", ") .. ")") or ""
    print("[MagicLoot][Sell] sellable " .. #ids .. ", ignored " .. ignoredCount .. ", locked " .. lockedCount)
    if #ids > 0 then
        local result = invoke(NetMsg.SELL_MATERIAL, {onlyIDList = ids})
        print("[MagicLoot][Sell] invoked with " .. #ids .. " id(s) -> result=" .. tostring(result))
        sellStatusText = (result and ("Sold " .. #ids .. " item(s)")
            or ("Server refused " .. #ids .. " item(s)")) .. keptNote
    else
        sellStatusText = "Nothing to sell" .. keptNote
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

-- Which room the character is PHYSICALLY standing in, by nearest room centre.
--
-- roomProgress was the wrong thing to key saved spots off, and here is why it
-- read as "the button is stuck on Room 1": roomProgress is the WALKER's cursor,
-- and the walker only runs while Auto Stage is ON. Farm a dungeon by hand with
-- the toggle off and roomProgress never leaves 1 no matter how far in you get.
-- Even with it on, a manual walk or a stage jump moves the body without moving
-- the cursor. DungeonAggroStage is no good either -- that was the original bug,
-- it still reports the PREVIOUS run's final value right after a re-entry.
--
-- Position is the one signal that can't be stale. workspace.场景 holds 27
-- numbered rooms, each with its own 战斗区域 volume, and they sit far enough
-- apart that "nearest centre" is unambiguous: measured live standing in room 5,
-- nearest was 39.4 studs and the runner-up 70.9. Both the save side and the
-- orbit-skip lookup read this now, so they can never disagree about which room
-- a spot belongs to.
local function currentPhysicalRoom()
    -- The 27 rooms exist in workspace even while standing in town, so without
    -- this gate the button would confidently name a room the character is
    -- nowhere near. InDungeonChallenge reads 0 in town and the live stage
    -- number inside a run (measured 5 while standing in room 5).
    local inDungeonVal = LocalPlayer:FindFirstChild("InDungeonChallenge")
    if not (inDungeonVal and inDungeonVal.Value > 0) then return nil end
    local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local scene = workspace:FindFirstChild("场景")
    if not hrp or not scene then return nil end
    local bestNum, bestDist
    for _, room in ipairs(scene:GetChildren()) do
        local num = tonumber(room.Name)
        if num then
            local mark = room:FindFirstChild("战斗区域") or room:FindFirstChild("Root")
            if mark and mark:IsA("BasePart") then
                local dist = (mark.Position - hrp.Position).Magnitude
                if not bestDist or dist < bestDist then bestNum, bestDist = num, dist end
            end
        end
    end
    return bestNum
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

-- ===== Stage Jump (the game's own teleport, added in a recent update) =====
-- NetWork.FireServer(NetMsg.STAGE_JUMP_REQUEST, stageNumber) -- a bare number,
-- fired not invoked (confirmed from StageJump.lua's own button handler).
--
-- Two separate ceilings, and the second one is the surprising one:
--   only 5 stages are teleport targets at all -- 4, 8, 13, 18, 23 (the entries
--   in dungeonConf carrying a TeleIcon), and
--   jumpMax = min(CareerMaxStage + 1, broom.Dungeon)
-- Read live right now: CareerMaxStage 21, but the equipped 海盗扫帚 has
-- Dungeon = 13, so jumpMax is 13 -- the BROOM is the limit, not progress. Ask
-- for stage 17 and the honest answer is "13, that's as far as this broom goes."
-- The client shows "需要先通关该关卡才可以传送" for anything past it, so firing
-- blind would just get silently refused.
local TELEPORTABLE_STAGES = {4, 8, 13, 18, 23}

local function getStageJumpMax()
    local career = 0
    local careerVal = LocalPlayer:FindFirstChild("CareerMaxStage")
    if careerVal then career = math.floor(tonumber(careerVal.Value) or 0) end

    local broomId = tonumber(PlayerData.GetPlrDataByKey(LocalPlayer, "NowBroom")) or 0
    if broomId <= 0 then
        local broomVal = LocalPlayer:FindFirstChild("NowBroom")
        if broomVal then broomId = math.floor(tonumber(broomVal.Value) or 0) end
    end
    local broomMax = 0
    if broomId > 0 then
        local ok, cfg = pcall(function() return CfgFind.FindCfgByID(broomId) end)
        if ok and type(cfg) == "table" then broomMax = math.floor(tonumber(cfg.Dungeon) or 0) end
    end

    if career <= 0 or broomMax <= 0 then return 0 end
    return math.min(career + 1, broomMax)
end

-- Highest teleport point that is both at or below the target and inside the
-- jump ceiling. Returns nil when even stage 4 is out of reach, or when the
-- target is close enough that walking there is the whole job anyway.
local function pickStageJumpTarget(target)
    local jumpMax = getStageJumpMax()
    if jumpMax <= 0 then return nil, "teleport locked (no broom / no clears)" end

    -- An explicit pick from the dropdown wins outright -- if you asked for
    -- stage 8 you get stage 8, even with Target Stage set to 17.
    local forced = tonumber(e.StageJumpPick) or 0
    if forced > 0 then
        if forced > jumpMax then
            return nil, string.format("stage %d is past the ceiling (%d)", forced, jumpMax)
        end
        return forced, string.format("jump %d (picked, ceiling %d)", forced, jumpMax)
    end

    local best
    for _, stage in ipairs(TELEPORTABLE_STAGES) do
        if stage <= target and stage <= jumpMax then best = stage end
    end
    if not best then return nil, "no teleport point at or below stage " .. target end
    return best, string.format("jump %d (auto for target %d, ceiling %d)", best, target, jumpMax)
end

-- The jump is a broom flight, not a warp. Flight.lua bails out of its update
-- loop the moment the character carries StageJumpAnimating, which is the tell:
-- the server plays the jump AS a broom animation, so firing STAGE_JUMP_REQUEST
-- while on foot gets you moved without ever running the arrival -- you land in
-- a stage that never spawns anything. Confirmed live:
--   InvokeServer(TOGGLE_BROOM) -> true, character JetPacking = 11000003
-- Mount first, jump second. Dismount after landing so the orbit/anchor logic
-- and combat behave like a normal run.
-- TOGGLE_BROOM is a toggle, and JetPacking is written by the game's own Flight
-- loop, not by the server. The first version of dismountBroom cleared that
-- attribute by hand "to be tidy" -- which desynced the two sides: the client
-- read as dismounted while the server still had us mounted, so the next
-- TOGGLE_BROOM dismounted instead of mounting and JetPacking never came back.
-- That is exactly what "broom refused to mount" was, three runs in a row.
-- Proven by toggling three times and watching it go on / on / off. Nothing here
-- touches the attribute now; DISMOUNT_BROOM is explicit and one-directional, so
-- it is used for getting off instead of another toggle.
-- Three separate signals, and reading only the first one is what made the jump
-- work sometimes and time out other times. Captured across a clean cycle:
--   after dismount   JetPacking=nil          BroomFly=false      BroomCD  -22.1s
--   after toggle     JetPacking=11000003     BroomFly=11000003   BroomCD   +6.6s
--   after a jump     JetPacking=11000003     BroomFly=11000003   FlightSpeed 16.5
--   settled          JetPacking=11000003     BroomFly=11000003   FlightSpeed 42.4
-- BroomCD lives on the PLAYER (not the character) and is a future timestamp --
-- toggling inside that window half-mounts: JetPacking sets but BroomFly stays
-- false, and the server drops STAGE_JUMP_REQUEST with no reply at all, which
-- read as the 15s "landed=false" timeout. So: wait out the cooldown, confirm
-- BroomFly and not just JetPacking, then actually get airborne before jumping.
local function broomCooldownRemaining()
    return (tonumber(LocalPlayer:GetAttribute("BroomCD")) or 0) - os.time()
end

local function ensureBroomMounted()
    local char = LocalPlayer.Character
    if not char then return false end

    local function flying()
        local c = LocalPlayer.Character
        return c and c:GetAttribute("JetPacking") and LocalPlayer:GetAttribute("BroomFly") and true or false
    end
    if flying() then return true end

    for attempt = 1, 2 do
        -- Never toggle into the cooldown -- that is the half-mount.
        local guard = 0
        while broomCooldownRemaining() > 0 and guard < 12 do
            task.wait(0.5)
            guard = guard + 0.5
        end

        invoke(NetMsg.TOGGLE_BROOM)
        for _ = 1, 25 do
            task.wait(0.1)
            if flying() then
                -- Mounted is not airborne. STAGE_JUMP_REQUEST needs a broom that
                -- is actually moving, so kick off the ground and let the flight
                -- physics spin up before handing over.
                local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
                if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end) end
                for _ = 1, 20 do
                    task.wait(0.1)
                    local c = LocalPlayer.Character
                    local speed = c and tonumber(c:GetAttribute("BroomFlightSpeed")) or 0
                    if speed > 0 then return true end
                end
                return flying()
            end
        end
        if attempt == 1 then task.wait(0.5) end
    end
    return false
end

local function dismountBroom()
    local char = LocalPlayer.Character
    if not char or not char:GetAttribute("JetPacking") then return end
    invoke(NetMsg.DISMOUNT_BROOM)
    for _ = 1, 15 do
        task.wait(0.1)
        char = LocalPlayer.Character
        if not (char and char:GetAttribute("JetPacking")) then return end
    end
end

-- Landing is signalled by StageJumpAnimating going set and then clearing again.
-- Waiting on the attribute instead of a flat sleep means a slow flight still
-- finishes before the room walker starts yanking the character around.
local function waitForStageJumpLanding(timeoutSeconds)
    local deadline = os.clock() + (timeoutSeconds or 12)
    local sawAnimation = false
    while os.clock() < deadline do
        local char = LocalPlayer.Character
        local animating = char and char:GetAttribute("StageJumpAnimating")
        if animating then
            sawAnimation = true
        elseif sawAnimation then
            return true
        end
        task.wait(0.15)
    end
    return sawAnimation
end

local stageJumpedThisRun = false
local stageWasInDungeon = false
-- The mount sequence waits on a cooldown, a toggle and then lift-off, which
-- adds up to half a minute worst case. doAutoStage used to run all of that
-- inline, so the whole stage loop -- status text, bag checks, everything --
-- stopped dead for the duration and Auto Stage looked frozen the moment it was
-- switched on. It runs on its own thread now; the loop keeps ticking and just
-- reports what the jump thread is doing.
local stageJumpBusy = false

-- These three drive room-walking and the saved-position lookup, and they used to
-- be declared below doAutoStage. That was survivable while only the walker
-- touched them -- but the stage-jump branch has to reseat roomProgress after a
-- teleport, and assigning a not-yet-declared local from up here would have made
-- a silent global that the real local later shadows: the jump would look fine
-- and the walker would still march off toward room 1. Declared before both users.
local roomProgress = 1
local emptyTicks = 0
local lastRoomEntered = 0
-- wasInDungeon moved up with them: the walker resets roomProgress to 1 the first
-- tick it sees a fresh run, and it runs at 0.3s against doAutoStage's 1s. If the
-- jump landed first, that reset would wipe roomProgress right back to 1 and send
-- the character walking from the front anyway. The jump sets this true itself.
local wasInDungeon = false

local function doAutoStage()
    if not e.AutoStageEnabled then stageStatusText = "Toggle is OFF"; return end
    local target = tonumber(e.StageTarget) or 0
    if target <= 0 then stageStatusText = "Toggle ON -- set a target stage first"; return end

    local inDungeonVal = LocalPlayer:FindFirstChild("InDungeonChallenge")
    local inDungeon = inDungeonVal and inDungeonVal.Value > 0
    if not inDungeon then
        lastProgressStage = -1
        lastProgressTime = 0
        -- Cleared on the in-dungeon -> town transition only. Clearing it every
        -- town tick would re-arm the jump each second, so a run with no valid
        -- teleport target would reprint "skipped" forever and a failed mount
        -- would retry in a tight loop instead of just taking the portal.
        if stageWasInDungeon then stageJumpedThisRun = false end
        stageWasInDungeon = false
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
        -- The teleport belongs HERE, in town, not after entering. The game
        -- refuses to mount a broom inside a dungeon ("cannot mount in dungeon"),
        -- and the jump IS a broom flight -- so firing it from inside was asking
        -- for the one thing that location forbids. It failed to mount four runs
        -- straight in the dungeon and mounted first try in town, every time.
        -- The jump flies you into the run at that stage, so it replaces the
        -- portal walk rather than following it.
        if stageJumpBusy then
            -- The jump thread owns the character right now. Do nothing else --
            -- walking to the portal mid-flight would fight it.
            return
        end

        if e.AutoStageJumpEnabled and not stageJumpedThisRun then
            local jumpTo, note = pickStageJumpTarget(target)
            if jumpTo then
                stageJumpedThisRun = true
                stageJumpBusy = true
                task.spawn(function()
                    stageStatusText = "Mounting broom for stage " .. jumpTo .. "..."
                    if not ensureBroomMounted() then
                        print("[MagicLoot][StageJump] broom refused to mount in town -- using the portal")
                        stageStatusText = "Broom would not mount -- walking to the portal"
                    else
                        fire(NetMsg.STAGE_JUMP_REQUEST, jumpTo)
                        -- roomProgress drives room-walking and the saved-position
                        -- lookup, so it has to follow the teleport or the next
                        -- tick would march back toward room 1 from where we land.
                        roomProgress = jumpTo
                        lastRoomEntered = 0
                        emptyTicks = 0
                        wasInDungeon = true
                        print("[MagicLoot][StageJump] " .. tostring(note) .. " (from town, on broom)")
                        stageStatusText = "Flying to stage " .. jumpTo .. " (" .. tostring(note) .. ")"
                        local landed = waitForStageJumpLanding(15)
                        dismountBroom()
                        print("[MagicLoot][StageJump] landed=" .. tostring(landed))
                        if not landed then
                            stageStatusText = "Teleport did not land -- falling back to the portal"
                        end
                    end
                    stageJumpBusy = false
                end)
                return
            end
            stageJumpedThisRun = true
            print("[MagicLoot][StageJump] skipped -- " .. tostring(note))
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

    stageWasInDungeon = true

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
        local bagFull, bagWhich = isEitherBagFull()
        if e.AutoReturnOnBagFull then
            -- Loop-farm the target stage instead of leaving as soon as it's
            -- clear -- room-advancement already stops once current>=target
            -- (see teleportToNearestMob), so this just keeps fighting
            -- whatever keeps spawning here until the bag actually fills.
            if bagFull then
                fire(NetMsg.DUNGEON_RETURN_TOWN)
                lastReturnTime = os.clock()
                stageStatusText = "Bag full (" .. bagWhich .. ") at target stage " .. current .. " -- returned to town"
                return
            end
            stageStatusText = "At target stage " .. current .. " -- farming until bag full"
            return
        end
        -- Waiting to pick up is pointless once the bag is actually full --
        -- fireproximityprompt() can't collect anything more at that point,
        -- so getDropItems() would never empty out and this would hang here
        -- forever ("stuck on the last stage" when the bag fills up mid-run).
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
local orbitAngleDeg = 0
local lastSavedStageApplied = nil

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
    -- Hands off while the stage jump is flying. This loop anchors the root part
    -- and re-CFrames it every 0.3s, which would drag the character straight out
    -- of the broom animation mid-flight and land the jump nowhere.
    if stageJumpBusy or char:GetAttribute("StageJumpAnimating") or char:GetAttribute("JetPacking") then
        hrp.Anchored = false
        return
    end
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
        lastSavedStageApplied = nil
        return
    end
    if not wasInDungeon then
        -- Just arrived in a fresh run -- always start the search at room 1,
        -- never at whatever roomProgress happened to hold before.
        wasInDungeon = true
        roomProgress = 1
        emptyTicks = 0
        lastRoomEntered = 0
        lastSavedStageApplied = nil
    end

    -- A saved spot for this exact stage overrides the mob-head orbit entirely
    -- -- some rooms have geometry where the orbit ring clips a wall or drifts
    -- into a mob's attack cone, so once the user has manually parked
    -- somewhere skills actually land, pin there instead. Anchored + re-CFrame
    -- every tick, same as the mob-orbit branch below -- unanchored let combat
    -- knockback drag the character clean off the saved spot (confirmed live:
    -- drifted 30+ studs away within seconds when left unanchored).
    -- Keyed off currentPhysicalRoom(), NOT DungeonAggroStage and no longer
    -- roomProgress either. DungeonAggroStage was the original bug: right after a
    -- fresh re-entry it still reports the PREVIOUS run's final stage, so a save
    -- for stage 17 matched at room 1 and pinned the character on an empty spot
    -- forever. roomProgress fixed that but introduced its own gap -- it is the
    -- walker's cursor, so it only tracks the body while Auto Stage drives it.
    -- Where the character actually stands answers the question for both.
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
    -- A saved spot pins the character, but ONLY while the room still has
    -- something alive in it. The first version checked this before scanning for
    -- monsters and returned unconditionally, which meant a room with a saved
    -- spot never reached the room-advance logic further down -- clear the room
    -- and the character just kept sitting on its mark forever. That is exactly
    -- "target 18, saved spots on 17 and 18, stuck on 17": room 17 was cleared,
    -- the pin held, and nothing ever walked into room 18 to make the server
    -- advance the stage. Empty room now falls through to the advance path.
    local savedPos = e.StageSavedPositions[tostring(currentPhysicalRoom() or roomProgress)]
    if savedPos and nearest then
        emptyTicks = 0
        hrp.Anchored = true
        hrp.CFrame = CFrame.new(savedPos.X, savedPos.Y, savedPos.Z)
        lastSavedStageApplied = roomProgress
        return
    end
    lastSavedStageApplied = nil

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
    Subtitle = "v1.2 Clean",
    DragStyle = 1,
    ShowUserInfo = true,
    AcrylicBlur = false,
})

-- MacLib's Slider constructor calls updateSliderBarSize, which reads
-- AbsoluteSize off the bar it just made. On this executor that read throws
-- "The current thread cannot access 'Instance' (lacking capability Plugin)"
-- from inside MacLib, and it is FATAL -- v1.1 died on the first Sell-tab slider
-- with the Farm tab already built and nothing printed after it. Maddeningly it
-- is order-dependent: the identical slider builds fine in isolation and the
-- Farm tab's own slider survives, so this can't be fixed by picking a different
-- element type. Wrapped instead -- a slider that refuses to render degrades to
-- a read-only label and the rest of the script still loads.
local function safeSlider(section, settings, flag)
    local ok, result = pcall(function() return section:Slider(settings, flag) end)
    if ok then return result end
    return section:Label({
        Text = settings.Name .. " = " .. tostring(settings.Default) ..
            "\n(slider blocked -- set getgenv() value directly)"
    })
end

-- Input was written off in this file as fatally broken on this executor. It is
-- not, and that was worth re-testing rather than inheriting: built a throwaway
-- MacLib window, added an Input, called Tab:Select() -- constructed clean and
-- rendered a real InputBox. The original diagnosis was almost certainly a
-- misread of the slider crash, which IS real and does throw. Same guard shape as
-- safeSlider regardless, since one executor behaving is not all of them.
local function safeInput(section, settings, flag)
    local ok, result = pcall(function() return section:Input(settings, flag) end)
    if ok and result then return result end
    return section:Label({
        Text = settings.Name .. "\n(input blocked -- set the getgenv() value directly)"
    })
end

local TabGroup = Window:TabGroup()
local Tabs = {
    Farm     = TabGroup:Tab({Name = "Farm",     Image = "rbxassetid://10723343321"}),
    Sell     = TabGroup:Tab({Name = "Sell",     Image = "rbxassetid://10734952273"}),
    Alchemy  = TabGroup:Tab({Name = "Alchemy",  Image = "rbxassetid://10747363465"}),
    Stage    = TabGroup:Tab({Name = "Stage",    Image = "rbxassetid://10734975692"}),
    Event    = TabGroup:Tab({Name = "Event",    Image = "rbxassetid://10747363465"}),
    Claims   = TabGroup:Tab({Name = "Claims",   Image = "rbxassetid://10734963191"}),
    Settings = TabGroup:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}

-- ----- Farm Tab -----
local FarmLeft = Tabs.Farm:Section({Side = "Left"})
FarmLeft:Header({Text = "Auto Pickup"})
FarmLeft:Toggle({
    Name = "Auto Pickup", Default = e.AutoPickupEnabled,
    Callback = function(v) e.AutoPickupEnabled = v; saveState() end,
}, "AutoPickupEnabled")
-- Numeric entry here is an Input again. The old note claiming Input throws
-- "lacking capability Plugin" on this executor was tested and is wrong -- see
-- safeInput. The Slider crash it was confused with is real and still guarded.
-- Free text, not a ladder of preset rows. A dropdown could only ever offer the
-- values someone guessed in advance, and the range here is 8 to 6,950,000,000 --
-- any fixed list is either too coarse to aim with or too long to scroll.
--
-- AcceptedCharacters is a live filter MacLib runs on every keystroke, so the
-- box physically cannot hold a letter that means nothing here. What survives it
-- still goes through parseAmount, which rejects the shapes that pass the
-- character filter but are not numbers -- "1.5.2", "kk", "5m3".
FarmLeft:Label({Text = "Min Price -- type 0, 1k, 150m, 1.5b, 1t"})
safeInput(FarmLeft, {
    Name = "Min Price",
    Placeholder = "0 / 1k / 150m / 1.5b",
    Default = (e.PickupMinPrice or 0) > 0 and formatAmount(e.PickupMinPrice) or "",
    AcceptedCharacters = function(text)
        return (tostring(text):gsub("[^%d%.kmbtKMBT]", ""))
    end,
    -- Fires on FocusLost, not per keystroke, so a half-typed "15" on the way to
    -- "150m" never briefly becomes the live threshold.
    Callback = function(text)
        local amount = parseAmount(text)
        if amount then
            e.PickupMinPrice = amount
            saveState()
            pickupPriceHintUntil = os.clock() + 3
            pickupStatusText = "Min Price set to " .. (amount > 0 and formatAmount(amount) or "any price")
        else
            -- MacLib exposes no setter for the box text, so a rejected entry
            -- stays visible while the real threshold does not change. Saying so
            -- is the only thing that stops that reading as "it took my value".
            pickupPriceHintUntil = os.clock() + 3
            pickupStatusText = "Could not read \"" .. tostring(text) ..
                "\" -- still " .. (parseAmount(e.PickupMinPrice) > 0
                    and formatAmount(e.PickupMinPrice) or "any price")
        end
    end,
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
local pickupStatusLabel = FarmLeft:Label({Text = "Idle"})

local FarmRight = Tabs.Farm:Section({Side = "Right"})
FarmRight:Header({Text = "Auto Train"})
FarmRight:Toggle({
    Name = "Auto Train", Default = e.AutoTrainEnabled,
    Callback = function(v) e.AutoTrainEnabled = v; saveState() end,
}, "AutoTrainEnabled")

-- Zone labels are built from the live config so the multipliers and the lock
-- reason are whatever the server says today, not what they were when this was
-- written. Rebuilt on demand rather than at load, since Rebirth changes them.
local trainZoneLabelToId = {}
local function buildTrainZoneOptions()
    trainZoneLabelToId = {}
    local labels = {}
    local zones = getTrainZones()
    local ids = {}
    for id in pairs(zones) do table.insert(ids, id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local z = zones[id]
        local suffix
        if z.canEnter then
            suffix = "unlocked"
        elseif z.passTag ~= "" then
            suffix = "needs " .. z.passTag
        else
            suffix = "needs Rebirth " .. z.rebirth
        end
        local label = string.format("Zone %d  -  %.1fx  (%s)", id, z.add, suffix)
        table.insert(labels, label)
        trainZoneLabelToId[label] = id
    end
    return labels
end

-- "Stay" used to live here and meant "don't move me". Manual Tap is that option
-- now, and having both was the trap -- Stay + Manual Tap read as two settings for
-- one behaviour while Best/Manual + Manual Tap was a combination that could never
-- work. A saved "Stay" from an older build maps onto Best.
if e.TrainZoneMode == "Stay" then e.TrainZoneMode = "Best" end
FarmRight:Dropdown({
    Name = "Zone Mode (ignored while Manual Tap is on)", Options = {"Best", "Manual"},
    Default = e.TrainZoneMode,
    Callback = function(selected)
        if selected then e.TrainZoneMode = selected; saveState() end
    end,
}, "TrainZoneModeDropdown")
local trainZoneDropdown = FarmRight:Dropdown({
    Name = "Zone (Manual mode only)", Options = buildTrainZoneOptions(), Search = true,
    Callback = function(selected)
        if selected and trainZoneLabelToId[selected] then
            e.TrainZoneId = trainZoneLabelToId[selected]
            saveState()
        end
    end,
}, "TrainZoneIdDropdown")
FarmRight:Button({Name = "Refresh Zone List", Callback = function()
    pcall(function()
        trainZoneDropdown:ClearOptions()
        trainZoneDropdown:InsertOptions(buildTrainZoneOptions())
    end)
end})
FarmRight:Toggle({
    Name = "Manual Tap (train here, no teleport)", Default = e.TrainManualTapEnabled,
    Callback = function(v) e.TrainManualTapEnabled = v; saveState() end,
}, "TrainManualTapEnabled")
-- Floor is 0.125, not 0.02. The server accepts ~8 taps/sec and refuses the rest,
-- so the old 0.02 minimum only ever bought rejections -- 18 of them per 47 hits,
-- measured. Letting the slider ask for something the server will not give is how
-- a working feature reads as broken.
safeSlider(FarmRight, {
    Name = "Tap Rate", Minimum = 0.125, Maximum = 1,
    Default = math.max(0.125, tonumber(e.TrainTapRate) or 0.125), Precision = 3, Suffix = "s",
    Callback = function(v) e.TrainTapRate = math.max(0.125, tonumber(v) or 0.125); saveState() end,
}, "TrainTapRateSlider")
local trainPlanLabel = FarmRight:Label({Text = "Comparing zone vs tap..."})
-- Manual Tap ON  = train where you stand, no teleport, ~330B/sec from taps.
-- Manual Tap OFF = Best parks you in the highest zone you can enter, Manual
-- parks you in the one picked above. Income there is the server's own
-- TRAIN_AUTO_TICK and taps are refused, so the two never mix.
local trainStatusLabel = FarmRight:Label({Text = "Idle"})

-- ----- Sell Tab -----
local SellLeft = Tabs.Sell:Section({Side = "Left"})
SellLeft:Header({Text = "Auto Sell"})
SellLeft:Toggle({
    Name = "Auto Sell", Default = e.AutoSellEnabled,
    Callback = function(v) e.AutoSellEnabled = v; saveState() end,
}, "AutoSellEnabled")
-- Max Price and Max Rarity sliders lived here. Both are gone: they were a blunt
-- way of saying "keep the good stuff", and the ignore list says it exactly --
-- by item, by name, with the rarity printed. Two controls that could contradict
-- each other became one that cannot.
--
-- Search = true because 48 rows is past the point of scrolling for one of them.
SellLeft:Dropdown({
    Name = "Never Sell (ignore list)", Options = sellIgnoreLabels, Multi = true, Search = true,
    Default = (function()
        local arr = {}
        for idKey in pairs(e.SellIgnoreIds) do
            local label = sellIdToLabel[tonumber(idKey)]
            if label then table.insert(arr, label) end
        end
        return arr
    end)(),
    -- Stored as ids. The dropdown speaks labels, the sell filter speaks ids, and
    -- this is the one place that converts -- so a label that changes with the
    -- game's language never reaches state.json.
    Callback = function(selected)
        local ids = {}
        for label in pairs(selected or {}) do
            local id = sellLabelToId[label]
            if id then ids[tostring(id)] = true end
        end
        e.SellIgnoreIds = ids
        saveState()
    end,
}, "SellIgnoreDropdown")
-- Sells at or below BOTH limits, never touches equipped items or the list above.
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
-- Only Training/Lucky buff potions are listed -- the skill-granting alchemy
-- potions are never auto-used. Nothing selected means this does nothing.
local usePotionStatusLabel = AlchemyRight:Label({Text = "Idle"})

-- ----- Stage Tab -----
local StageLeft = Tabs.Stage:Section({Side = "Left"})
StageLeft:Header({Text = "Auto Stage"})
StageLeft:Toggle({
    Name = "Auto Stage", Default = e.AutoStageEnabled,
    Callback = function(v) e.AutoStageEnabled = v; saveState(); print("[MagicLoot][Toggle] AutoStageEnabled -> " .. tostring(v)) end,
}, "AutoStageEnabled")
safeSlider(StageLeft, {
    Name = "Target Stage (0 = disabled)", Minimum = 0, Maximum = 200,
    Default = e.StageTarget, Precision = 0,
    Callback = function(v) e.StageTarget = math.floor(tonumber(v) or 0); saveState() end,
}, "StageTargetSlider")
StageLeft:Toggle({
    Name = "Stage Teleport (skip the walk)", Default = e.AutoStageJumpEnabled,
    Callback = function(v) e.AutoStageJumpEnabled = v; saveState() end,
}, "AutoStageJumpEnabled")
-- Dropdown lists every teleport point the game has, each one labelled with
-- whether the current broom can actually reach it, so a locked pick is obvious
-- before it silently does nothing.
local stageJumpLabelToId = {}
local function buildStageJumpOptions()
    stageJumpLabelToId = {}
    local jumpMax = getStageJumpMax()
    local labels = {"Auto (closest to Target Stage)"}
    stageJumpLabelToId[labels[1]] = 0
    for _, stage in ipairs(TELEPORTABLE_STAGES) do
        local label = string.format("Stage %d%s", stage, stage <= jumpMax and "" or "   (locked)")
        table.insert(labels, label)
        stageJumpLabelToId[label] = stage
    end
    return labels
end

local stageJumpDropdown = StageLeft:Dropdown({
    Name = "Teleport To", Options = buildStageJumpOptions(),
    Default = (function()
        local pick = tonumber(e.StageJumpPick) or 0
        if pick <= 0 then return "Auto (closest to Target Stage)" end
        for label, id in pairs(stageJumpLabelToId) do if id == pick then return label end end
        return "Auto (closest to Target Stage)"
    end)(),
    Callback = function(selected)
        if selected and stageJumpLabelToId[selected] then
            e.StageJumpPick = stageJumpLabelToId[selected]
            saveState()
        end
    end,
}, "StageJumpPickDropdown")
StageLeft:Button({Name = "Refresh Teleport List", Callback = function()
    pcall(function()
        stageJumpDropdown:ClearOptions()
        stageJumpDropdown:InsertOptions(buildStageJumpOptions())
    end)
end})
local stageJumpInfoLabel = StageLeft:Label({Text = "Teleport: checking..."})
StageLeft:Toggle({
    Name = "Return Town on Bag Full", Default = e.AutoReturnOnBagFull,
    Callback = function(v) e.AutoReturnOnBagFull = v; saveState() end,
}, "AutoReturnOnBagFull")
safeSlider(StageLeft, {
    Name = "Mob Hover Height", Minimum = 3, Maximum = 40,
    Default = e.MobHoverHeight, Precision = 0,
    Callback = function(v) e.MobHoverHeight = v; saveState() end,
}, "MobHoverHeightSlider")
-- Snaps onto the nearest live monster every 0.3s so skills stay in range, until
-- DungeonAggroStage reaches the target -- then DUNGEON_RETURN_TOWN. With Bag
-- Full ON it also returns early when either bag caps, then loops back in.
local stageStatusLabel = StageLeft:Label({Text = "Idle"})

StageLeft:Header({Text = "Custom Farm Position"})
-- Three buttons became one. The old set was "Save for Current Stage" / "Clear
-- for Current Stage" / "Clear ALL", and picking between the first two meant
-- already knowing whether this room had a save -- which the label only told you
-- if you went and read it first. One button that reads the state itself and
-- flips it removes that whole step: stand where you want, press, done. Press
-- again on the same room to undo it.
--
-- Saves are keyed by roomProgress, NOT DungeonAggroStage. Those are two
-- different numbers: DungeonAggroStage is the server's cleared-stage counter
-- and can still report the PREVIOUS run's final value right after a re-entry,
-- so a save made against it never matched on the read side and the orbit ran
-- forever. roomProgress resets to 1 on every fresh entry and only moves through
-- real local room advancement, so both sides agree.
local savedPosStatusLabel = StageLeft:Label({Text = "Saved rooms: none"})
-- Physical position first, walker cursor only as a fallback for when the
-- character has no room to be nearest to (standing in town).
local function currentRoomKey()
    return tostring(currentPhysicalRoom() or roomProgress)
end
-- The button's own name is the instruction. Reading "Clear Saved Spot (Room 7)"
-- tells you this room is already saved without looking anywhere else.
local savePosButton
-- The status line repaints on a 1s tick, so a rejection message written straight
-- into it survives less than a second and reads as the button doing nothing at
-- all. Hold the line for 3s instead and let the tick skip it until then.
local savedPosHintUntil = 0
local function refreshSavedPosStatus()
    local key = currentRoomKey()
    local saved = e.StageSavedPositions[key] ~= nil
    pcall(function()
        savePosButton:UpdateName(saved
            and ("Clear Saved Spot (Room " .. key .. ")")
            or  ("Save This Spot (Room " .. key .. ")"))
    end)
    if os.clock() < savedPosHintUntil then return end

    -- Keys are stringified room numbers, so a plain sort would order them
    -- 1, 10, 17, 2. Sort the numbers as numbers.
    local rooms = {}
    for roomKey in pairs(e.StageSavedPositions) do
        table.insert(rooms, tonumber(roomKey) or 0)
    end
    table.sort(rooms)
    pcall(function()
        savedPosStatusLabel:UpdateName(#rooms > 0
            and ("Saved rooms: " .. table.concat(rooms, ", "))
            or  "Saved rooms: none")
    end)
end
local function savedPosHint(text)
    savedPosHintUntil = os.clock() + 3
    pcall(function() savedPosStatusLabel:UpdateName(text) end)
end
savePosButton = StageLeft:Button({Name = "Save This Spot", Callback = function()
    local key = currentRoomKey()
    if e.StageSavedPositions[key] then
        e.StageSavedPositions[key] = nil
        saveState()
        savedPosHintUntil = 0
        refreshSavedPosStatus()
        return
    end
    local inDungeonVal = LocalPlayer:FindFirstChild("InDungeonChallenge")
    local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not (inDungeonVal and inDungeonVal.Value > 0) or not hrp then
        savedPosHint("Get inside a run first, then press this")
        return
    end
    e.StageSavedPositions[key] = {X = hrp.Position.X, Y = hrp.Position.Y, Z = hrp.Position.Z}
    saveState()
    savedPosHint("Saved room " .. key .. " -- orbit skipped here")
end})
StageLeft:Button({Name = "Clear All Saved Spots", Callback = function()
    e.StageSavedPositions = {}
    saveState()
    savedPosHintUntil = 0
    refreshSavedPosStatus()
end})
task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(refreshSavedPosStatus)
        pcall(function()
            -- Was two lines: a "reachable: 4, 8, 13" list plus a verdict. The
            -- list was redundant -- the ceiling already implies it, and the
            -- dropdown marks locked entries itself. Verdict only now.
            local jumpMax = getStageJumpMax()
            local pick, note = pickStageJumpTarget(tonumber(e.StageTarget) or 0)
            stageJumpInfoLabel:UpdateName(pick
                and string.format("Teleport to %d, walk from there (ceiling %d)", pick, jumpMax)
                or  string.format("Walking from 1 -- %s", tostring(note)))
        end)
        task.wait(1)
    end
end)

-- ----- Event Tab (Dino) -----
local EventLeft = Tabs.Event:Section({Side = "Left"})
EventLeft:Header({Text = "Auto Roll Dino"})
EventLeft:Toggle({
    Name = "Auto Roll", Default = e.AutoDinoRollEnabled,
    Callback = function(v) e.AutoDinoRollEnabled = v; saveState() end,
}, "AutoDinoRollEnabled")
EventLeft:Dropdown({
    Name = "Roll Batch", Options = {"x1", "x3", "x10"},
    Default = "x" .. tostring(e.DinoRollBatch or 1),
    Callback = function(selected)
        if selected then
            e.DinoRollBatch = tonumber((tostring(selected):gsub("x", ""))) or 1
            saveState()
        end
    end,
}, "DinoRollBatchDropdown")
-- Slider, not an Input box. MacLib's Input runs a TextService size check that
-- throws "lacking capability Plugin" on this executor's thread identity and
-- takes the whole script down at load. A 0-10 slider covers the range anyway,
-- since TicketDailyMax is 3.
safeSlider(EventLeft, {
    Name = "Keep Tickets (0 = spend all)", Minimum = 0, Maximum = 10,
    Default = e.DinoRollKeepTickets, Precision = 0,
    Callback = function(v) e.DinoRollKeepTickets = math.floor(tonumber(v) or 0); saveState() end,
}, "DinoRollKeepTicketsSlider")
-- Free tickets drip in every 15 min, 3/day max, and x3/x10 each need that many
-- in hand -- so on a free account x1 is the only batch that ever fires.
local dinoRollStatusLabel = EventLeft:Label({Text = "Idle"})
local dinoWalletLabel = EventLeft:Label({Text = "Tickets: ?   Dino Coins: ?"})

local EventRight = Tabs.Event:Section({Side = "Right"})
EventRight:Header({Text = "Auto Claim Quest Dino"})
EventRight:Toggle({
    Name = "Auto Claim Quest", Default = e.AutoDinoQuestEnabled,
    Callback = function(v) e.AutoDinoQuestEnabled = v; saveState() end,
}, "AutoDinoQuestEnabled")
-- Sweeps Timed / Daily / Once every 20s, submits anything already at target.
local dinoQuestStatusLabel = EventRight:Label({Text = "Idle"})
local dinoTaskListLabel = EventRight:Label({Text = "Loading tasks..."})
EventRight:Button({Name = "Refresh Task List", Callback = function()
    local rows = collectDinoTasks()
    if #rows == 0 then
        pcall(function() dinoTaskListLabel:UpdateName("No event task data") end)
        return
    end
    local lines = {}
    for _, row in ipairs(rows) do
        local mark = row.claimed and "[done]" or (row.canClaim and "[READY]" or "[    ]")
        table.insert(lines, string.format("%s %s  %d/%d", mark, row.bucket, row.progress, row.need))
    end
    table.sort(lines)
    pcall(function() dinoTaskListLabel:UpdateName(table.concat(lines, "\n")) end)
end})

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
safeInput(ClaimsRight, {
    Name = "Codes", Placeholder = "CODE1, CODE2",
    Callback = function(t) redeemCodesText = t or "" end,
}, "RedeemCodesInput")
local redeemStatusLabel = ClaimsRight:Label({Text = "Ready"})
ClaimsRight:Button({Name = "Redeem Now", Callback = function()
    redeemStatusLabel:UpdateName("Redeeming...")
    local codes = redeemCodesText
    if codes == "" then codes = tostring(getgenv().MagicLootCodes or "") end
    doRedeemCodes(codes, function(claimed, tried)
        pcall(function() redeemStatusLabel:UpdateName("Redeemed " .. claimed .. "/" .. tried) end)
    end)
end})

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
-- Same treatment as safeSlider: Keybind is another MacLib element that reaches
-- for Instance state at construction, and one throw here would strand the
-- Settings tab and every background loop declared after it.
pcall(function()
    SettingsLeft:Keybind({
        Name = "Show/Hide UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
        Callback = function() pcall(function() Window:SetState(not Window:GetState()) end) end,
    }, "MagicLootToggleUIKeybind")
end)
SettingsLeft:Header({Text = "Auto Save"})
SettingsLeft:Label({Text = "Auto-saved to " .. SAVE_FILE})

local SettingsRight = Tabs.Settings:Section({Side = "Right"})
SettingsRight:Header({Text = "Movement"})
SettingsRight:Toggle({
    Name = "Speed", Default = e.WalkSpeedEnabled,
    Callback = function(v) e.WalkSpeedEnabled = v; applyMovement(); saveState() end,
}, "WalkSpeedEnabled")
safeSlider(SettingsRight, {
    Name = "Speed Value", Minimum = 16, Maximum = 200,
    Default = e.WalkSpeedValue, Precision = 0,
    Callback = function(v) e.WalkSpeedValue = v; applyMovement(); saveState() end,
})
SettingsRight:Toggle({
    Name = "Jump Power", Default = e.JumpPowerEnabled,
    Callback = function(v) e.JumpPowerEnabled = v; applyMovement(); saveState() end,
}, "JumpPowerEnabled")
safeSlider(SettingsRight, {
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
        -- refreshTrainPlan walks all 9 tagged zones and pcalls CanEnterTrainGround
        -- on each -- 27 calls. Running that on the tap cadence cost more than the
        -- taps did: measured 196B/sec against a 330B/sec ceiling, because the scan
        -- ate the interval. It only changes on rebirth, so once a second is plenty.
        if os.clock() - lastTrainPlanRefresh >= 1 then
            lastTrainPlanRefresh = os.clock()
            pcall(refreshTrainPlan)
            pcall(function() trainPlanLabel:UpdateName(trainPlanText) end)
        end
        pcall(function() trainStatusLabel:UpdateName(trainStatusText) end)
        -- A flat 0.5s loop capped taps at 2/sec against a server that accepts 8 --
        -- that was the second half of "Manual Tap doesn't work". Tick on a slice
        -- well under the tap interval and let tryTrainTap's own gate set the real
        -- spacing; parking needs none of that pace and still idles at 0.5s.
        if e.AutoTrainEnabled and e.TrainManualTapEnabled and not inTrainZone() then
            task.wait(0.03)
        else
            task.wait(0.5)
        end
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoDinoRoll)
        pcall(function() dinoRollStatusLabel:UpdateName(dinoRollStatusText) end)
        pcall(function()
            dinoWalletLabel:UpdateName(string.format("Tickets: %d   Dino Coins: %d",
                countBagItem(EVENT_TICKET_ITEM_ID), countBagItem(EVENT_COIN_ITEM_ID)))
        end)
        task.wait(10)
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoDinoQuest)
        pcall(function() dinoQuestStatusLabel:UpdateName(dinoQuestStatusText) end)
        task.wait(20)
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
        -- 5s, not 30s. A tick with nothing to claim costs two PlayerData reads
        -- and twelve IsOnlineTierClaimable checks -- all client-side, zero
        -- remote traffic -- so polling six times as often buys a much tighter
        -- claim latency for nothing. The remote only fires on a tier that
        -- actually reads claimable.
        task.wait(5)
    end
end)

task.spawn(function()
    while getgenv().__MLG == myGen do
        pcall(doAutoRebirth)
        pcall(function() rebirthStatusLabel:UpdateName(rebirthStatusText) end)
        task.wait(5)
    end
end)

applyMovement()

-- state.json was only ever written from a UI callback, so any value that reached
-- getgenv another way -- the TrainTapRate normalisation above, or a setting
-- carried in from a previous run -- lived in memory and died on rejoin, quietly
-- reverting to whatever the file still said. One save at the end of load makes
-- the file agree with what is actually on screen.
saveState()

getgenv().__MLWindow = Window
-- Select() runs MacLib's tab Tween, and the tween touches Instance state the
-- same way the sliders did -- this was the final thing killing the load, one
-- line from the end, after every tab had already been built. The tab still
-- opens on click; only the auto-select on load is lost.
pcall(function() Tabs.Farm:Select() end)
-- Version string carries a load stamp on purpose. An older injected build and a
-- freshly executed one used to print the exact same line, which is how a stale
-- copy sat in memory looking like a broken feature. Now they can't match.
print(string.format("[MagicLoot] v1.2 Clean loaded (gen %d, %s)", myGen, os.date("%H:%M:%S")))
