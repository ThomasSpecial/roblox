-- Mutant Plants: Base Defense[World Boss] Automation v1.0
-- PlaceId 105954652742326
-- Auto Roll (Rarity -> Plant + Mutation filter -> Auto Buy) + Auto Merge +
-- Auto Equip Best + Auto Start Wave + Auto Stop at Wave N + Auto Upgrade
-- (per-stat, max level) + Auto Rebirth + Auto Claim Mission + Auto Claim
-- Daily + Auto Boss (World + Zone, Full Fight / Poke & Leave) + Settings
-- (Anti-AFK, Auto Reconnect, Auto Save)
--
-- This game routes every player action through ONE generic dispatch proxy:
-- game.ReplicatedStorage.Business.OnClientGameEvent. Every method on it
-- (Business, BusinessToId, AutoBuy_Backpack_Item, Buy_Backpack_Item,
-- QuickFuse, StartGp, ExitGp, GetGift, SelectHandUnit, ...) is a stub body
-- in the decompiled ModuleScript -- the real FireServer wiring is injected
-- client-side by StarterPlayer.StarterPlayerScripts.Framework.X0300.
-- ClientEvent.InitOnEvent(v2) after require(), so require()-then-call works
-- exactly like the button handlers that fire these for real. Confirmed
-- live by requiring it and typeof()-checking every method used below --
-- all report "function".
--
-- State lives in require(StarterPlayer.StarterPlayerScripts.Business.C_Data)
-- .GetData() ->
-- {serverData = raw synced values, playData = mostly VarValue-wrapped
-- values (scalars carry .Value, arrays/maps like hand/allCard/sceneUnit/
-- dayTaskSize do not), onlyData = local-only}. Every call site and field
-- path below was read directly out of the game's own decompiled UI
-- ModuleScripts (cited inline), not guessed.

getgenv().__MPG = (getgenv().__MPG or 0) + 1
local myGen = getgenv().__MPG

pcall(function()
    if getgenv().__MPWindow and getgenv().__MPWindow.Unload then
        getgenv().__MPWindow:Unload()
    end
end)
getgenv().__MPLIB = nil -- force a fresh MacLib every load, same reason loot_evo_v3 does this

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local deadline = os.clock() + 30
    repeat
        task.wait(0.1)
        LocalPlayer = Players.LocalPlayer
    until LocalPlayer or os.clock() > deadline
end
if not LocalPlayer then
    warn("[MutantPlants] Players.LocalPlayer never arrived -- aborting cleanly")
    return
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Business = ReplicatedStorage:WaitForChild("Business", 30)
if not Business then
    warn("[MutantPlants] ReplicatedStorage.Business never replicated -- aborting cleanly")
    return
end

local OnClientGameEvent = require(Business:WaitForChild("OnClientGameEvent"))
local PlayConfig = require(ReplicatedStorage:WaitForChild("Data"):WaitForChild("PlayConfig"))
local MainBusiness = require(Business:WaitForChild("MainBusiness"))
local BigNumber = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("X0000"):WaitForChild("BigNumber"))

-- This script's own raw URL -- the exact one loader.lua's PLACE_SCRIPTS table
-- dispatches this PlaceId to. Used only by the Config "Load Config" button to
-- self-reload with new getgenv() values already applied (same HttpGet ->
-- loadstring -> call() shape as the loader itself, so the __MPG-bump/
-- Unload-old-window teardown at the top of this file runs exactly the same
-- way it does on a normal re-execute).
local SELF_URL = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/mutant_plants.lua"

local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
local BusinessModules = PlayerScripts:WaitForChild("BusinessModules")
-- C_Data specifically -- NOT PlayerScripts.Business.C_Data. That clone is
-- never Init()'d by anything (confirmed live: GetData() on it always throws
-- "assertion failed!", u74 permanently nil) -- the real bootstrap populates
-- the StarterPlayerScripts copy instead. Every OTHER module (GameEvent,
-- OnClientGameEvent) resolves fine from the PlayerScripts clone -- this is
-- specific to C_Data. Confirmed live: requiring THIS path returns rebirth=6,
-- matching leaderstats.Rebirth exactly; the PlayerScripts clone never does.
local StarterPlayerScripts = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")
local C_Data = require(StarterPlayerScripts:WaitForChild("Business"):WaitForChild("C_Data"))
local GameEvent = require(PlayerScripts:WaitForChild("Business"):WaitForChild("GameEvent"))
-- FrameworkLink.Update[script] is the game's own per-roll animation lock --
-- RNG_单位_c's real Roll button checks this before firing, and the module
-- itself is at this exact StarterPlayerScripts path (its own require of
-- C_Data uses this same path, confirming it's the live copy). Gating our
-- own rolls on it (see doAutoRoll) means firing the instant the game says
-- it's safe to roll again instead of guessing a fixed cooldown.
local FrameworkLink = require(StarterPlayerScripts:WaitForChild("Business"):WaitForChild("FrameworkLink"))
local RNGRollScript = StarterPlayerScripts:WaitForChild("BusinessModules"):WaitForChild("RNG_单位"):WaitForChild("RNG_单位_c")

-- playData scalars are VarValue-wrapped (confirmed live: nowPlayerHp.Value,
-- nowHand.Value); arrays/maps (hand, allCard, sceneUnit, dayTaskSize,
-- dayTaskIsOk) are not. Read every playData scalar through this so either
-- shape works without guessing per-field.
local function readScalar(v)
    if typeof(v) == "table" then
        if v.Value ~= nil then return v.Value end
        return nil
    end
    return v
end

local function getData()
    local ok, data = pcall(C_Data.GetData)
    if ok then return data end
    return nil
end

-- ===== Rarity / Mutation tables (read live, not hardcoded -- confirmed live:
-- 7 rarities Common..Secret, 6 mutations Common..Void) =====
local RARITY_NAME_BY_ID, RARITY_ID_BY_NAME, RARITY_OPTIONS, RARITY_IDS_ORDERED = {}, {}, {}, {}
do
    local rows = {}
    for _, row in ipairs(PlayConfig.allRarity) do table.insert(rows, row) end
    table.sort(rows, function(a, b) return a.id < b.id end)
    for _, row in ipairs(rows) do
        RARITY_NAME_BY_ID[row.id] = row.name
        RARITY_ID_BY_NAME[row.name] = row.id
        table.insert(RARITY_OPTIONS, row.name)
        table.insert(RARITY_IDS_ORDERED, row.id)
    end
end

local MATERIAL_NAME_BY_ID, MATERIAL_ID_BY_NAME = {}, {}
do
    local rows = {}
    for _, row in ipairs(PlayConfig.allMaterialRarity) do table.insert(rows, row) end
    table.sort(rows, function(a, b) return a.id < b.id end)
    for _, row in ipairs(rows) do
        MATERIAL_NAME_BY_ID[row.id] = row.name
        MATERIAL_ID_BY_NAME[row.name] = row.id
    end
end

-- Mutation is baked into cfg.name as a "Mutation-Species" prefix for every
-- MaterialRarity above 1 (confirmed live: id2 name="Frost-Tomato",
-- MaterialRarity=2; id1 name="Tomato", MaterialRarity=1, no prefix).
-- Strips it back off so "species" means the same plant across all its
-- mutation variants.
local function unitSpecies(cfg)
    local matName = MATERIAL_NAME_BY_ID[cfg.MaterialRarity]
    if matName and matName ~= "Common" then
        local prefix = matName .. "-"
        if cfg.name:sub(1, #prefix) == prefix then
            return cfg.name:sub(#prefix + 1)
        end
    end
    return cfg.name
end

-- ===== Save System: Auto Save (state.json) + Manual named Configs =====
local SAVE_FOLDER = "MutantPlantsAutomation"
local SAVE_FILE = SAVE_FOLDER .. "/state.json"
local CONFIG_FOLDER = SAVE_FOLDER .. "/configs"
local MODE_FILE = SAVE_FOLDER .. "/mode.txt"
local AUTOLOAD_FILE = SAVE_FOLDER .. "/autoload.txt"
pcall(function() if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end end)
pcall(function() if not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end end)
local PERSIST_KEYS = {
    "RollRarityIds", "RollPlantsByRarity", "RollMutationsByRarity", "AutoRollBuyEnabled",
    "AutoMergeEnabled",
    "AutoEquipEnabled",
    "AutoDeleteEnabled", "DeleteRarityIds", "DeletePlantsByRarity",
    "AutoCraftEnabled", "CraftRecipeId", "CraftBatchSize",
    "AutoBuyFruitEnabled", "BuyFruitNames", "AutoBuyItemEnabled", "BuyItemNames",
    "AutoStartWaveEnabled", "AutoStopWaveEnabled", "WaveStopTarget",
    "AutoUpgradeEnabled", "UpgradeStatIds", "UpgradeMaxLevelByStat",
    "AutoRebirthEnabled",
    "AutoClaimMissionEnabled",
    "AutoClaimDailyEnabled",
    "AutoWorldBossEnabled", "WorldBossLevels", "WorldBossModeByLevel", "WorldBossPokeSeconds",
    "AutoZoneBossEnabled", "ZoneBossMode", "ZoneBossPokeSeconds",
    "AntiAFKEnabled", "AutoReconnectEnabled", "BoostFpsEnabled", "HideOtherBasesEnabled",
}
local function readTextFile(path)
    local ok, content = pcall(function() return readfile(path) end)
    if ok and content and content ~= "" then return content end
    return nil
end
local function configPath(name)
    return CONFIG_FOLDER .. "/" .. name .. ".json"
end
-- forceOverwrite=false (state.json's own load, and a Manual-mode AutoLoad
-- config at startup) keeps the "only fill what's still nil" behavior a
-- fresh session needs. forceOverwrite=true (Load Config button, mid-session)
-- replaces whatever's already running -- that's the whole point of Load.
local function applyDataToGenv(data, forceOverwrite)
    for _, key in ipairs(PERSIST_KEYS) do
        if data[key] ~= nil and (forceOverwrite or getgenv()[key] == nil) then
            getgenv()[key] = data[key]
        end
    end
end
local function loadPersistedState()
    local content = readTextFile(SAVE_FILE)
    if not content then return end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    if ok2 and type(data) == "table" then applyDataToGenv(data, false) end
end

-- ManualSaveMode lives in its own MODE_FILE, outside PERSIST_KEYS/state.json
-- and outside every named Config -- so loading an old config (or one saved
-- before this feature existed) can never silently flip the save mode out
-- from under you. Read once per real session (getgenv() survives a Load
-- Config self-reload, so this only ever re-reads disk on a truly fresh run).
if getgenv().ManualSaveMode == nil then
    getgenv().ManualSaveMode = readTextFile(MODE_FILE) == "manual"
end
if getgenv().ManualSaveMode then
    -- Manual mode skips state.json entirely -- the only thing that loads
    -- automatically is whichever Config (if any) is marked AutoLoad.
    local autoLoadName = readTextFile(AUTOLOAD_FILE)
    if autoLoadName then
        local content = readTextFile(configPath(autoLoadName))
        if content then
            local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
            if ok2 and type(data) == "table" then applyDataToGenv(data, false) end
        end
    end
else
    loadPersistedState()
end

local function saveState()
    -- The entire point of Manual mode: every one of the ~30 existing
    -- Callback = function(v) e.X = v; saveState() end call sites across
    -- this file goes quiet with this one early return, no per-callsite
    -- edits needed.
    if getgenv().ManualSaveMode then return end
    local data = {}
    for _, key in ipairs(PERSIST_KEYS) do data[key] = getgenv()[key] end
    pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(data)) end)
end

local e = getgenv()
if e.RollRarityIds == nil then e.RollRarityIds = {} end
if e.RollPlantsByRarity == nil then e.RollPlantsByRarity = {} end
if e.RollMutationsByRarity == nil then e.RollMutationsByRarity = {} end
if e.AutoRollBuyEnabled == nil then e.AutoRollBuyEnabled = false end
if e.AutoMergeEnabled == nil then e.AutoMergeEnabled = false end
if e.AutoEquipEnabled == nil then e.AutoEquipEnabled = false end
if e.AutoDeleteEnabled == nil then e.AutoDeleteEnabled = false end
if e.DeleteRarityIds == nil then e.DeleteRarityIds = {} end
if e.DeletePlantsByRarity == nil then e.DeletePlantsByRarity = {} end
if e.AutoCraftEnabled == nil then e.AutoCraftEnabled = false end
if e.CraftBatchSize == nil then e.CraftBatchSize = 1 end
if e.AutoBuyFruitEnabled == nil then e.AutoBuyFruitEnabled = false end
if e.BuyFruitNames == nil then e.BuyFruitNames = {} end
if e.AutoBuyItemEnabled == nil then e.AutoBuyItemEnabled = false end
if e.BuyItemNames == nil then e.BuyItemNames = {} end
if e.AutoStartWaveEnabled == nil then e.AutoStartWaveEnabled = false end
if e.AutoStopWaveEnabled == nil then e.AutoStopWaveEnabled = false end
if e.WaveStopTarget == nil then e.WaveStopTarget = 0 end
if e.AutoUpgradeEnabled == nil then e.AutoUpgradeEnabled = false end
if e.UpgradeStatIds == nil then e.UpgradeStatIds = {} end
if e.UpgradeMaxLevelByStat == nil then e.UpgradeMaxLevelByStat = {} end
if e.AutoRebirthEnabled == nil then e.AutoRebirthEnabled = false end
if e.AutoClaimMissionEnabled == nil then e.AutoClaimMissionEnabled = false end
if e.AutoClaimDailyEnabled == nil then e.AutoClaimDailyEnabled = false end
if e.AutoWorldBossEnabled == nil then e.AutoWorldBossEnabled = false end
if e.WorldBossLevels == nil then e.WorldBossLevels = {} end
if e.WorldBossModeByLevel == nil then e.WorldBossModeByLevel = {} end
if e.WorldBossPokeSeconds == nil then e.WorldBossPokeSeconds = 6 end
if e.AutoZoneBossEnabled == nil then e.AutoZoneBossEnabled = false end
if e.ZoneBossMode == nil then e.ZoneBossMode = "Poke & Leave" end
if e.ZoneBossPokeSeconds == nil then e.ZoneBossPokeSeconds = 6 end
if e.AntiAFKEnabled == nil then e.AntiAFKEnabled = true end
if e.AutoReconnectEnabled == nil then e.AutoReconnectEnabled = true end
if e.BoostFpsEnabled == nil then e.BoostFpsEnabled = false end
if e.HideOtherBasesEnabled == nil then e.HideOtherBasesEnabled = false end

-- ==========================================================================
-- 1) Auto Roll -- multi-select Rarity, each picked rarity gets its own
-- Plant + Mutation filter pair -> Auto Buy.
-- Manual roll: OnClientGameEvent:Business("RNG_单位") (confirmed call site,
-- RNG_单位_c). Buy a specific rolled slot: OnClientGameEvent:
-- AutoBuy_Backpack_Item("RNG_单位", slotIndex) (confirmed call site). The
-- game's own native auto-buy only filters by Rarity + Mutation
-- (自动抽取单位_稀有度 / 自动抽取单位_材质稀有度) and the mutation half is
-- gated behind a gamepass this account does not own -- so instead of
-- driving the native filter, this rolls manually and reads the 3-slot pool
-- itself (serverData.rollUnitPool, confirmed live), resolves each cfgId
-- through PlayConfig.allUnit, and buys any slot matching ANY selected
-- rarity's own Plant(species) + Mutation filter. No gamepass required.
-- Filters are keyed per rarity id ("r1".."r7") so e.g. Mythic and Secret
-- can each keep their own independent Plant/Mutation picks at once.
--
-- Speed: the old version fired, then blind-slept 0.35s before reading the
-- pool. Measured live, real replication lands in ~70-100ms most of the
-- time -- polling instead of sleeping cuts the common case to a third of
-- that, with a 1.5s ceiling so a slow tick still reads real data instead of
-- stale. Bigger win is on the FIRE side: the real Roll button gates itself
-- on FrameworkLink.Update[script] ~= nil (confirmed live -- that's the
-- flag RNG_单位_c's own OnServerGameEvent.RNG_Unit sets while the result
-- animation is playing, cleared once it finishes). We bypass the button so
-- that gate never blocked us, but the server still runs the same animation
-- state machine on every roll regardless of who triggered it -- so this
-- waits on the exact same flag the real button waits on, which means firing
-- the next roll the instant the game itself says it's safe to, no fixed
-- "skip the animation" guess involved.
-- ==========================================================================
local rollStatusText = "Toggle is OFF"

local function rollMatchesFilter(cfg, raritySet)
    if not raritySet[cfg.rarity] then return false end
    local plants = e.RollPlantsByRarity["r" .. cfg.rarity] or {}
    local muts = e.RollMutationsByRarity["r" .. cfg.rarity] or {}
    if #plants > 0 and not table.find(plants, unitSpecies(cfg)) then return false end
    if #muts > 0 and not table.find(muts, MATERIAL_NAME_BY_ID[cfg.MaterialRarity]) then return false end
    return true
end

local function doAutoRoll()
    if not e.AutoRollBuyEnabled then rollStatusText = "Toggle is OFF"; return end
    if #e.RollRarityIds == 0 then rollStatusText = "Pick at least one Rarity first"; return end
    local raritySet = {}
    for _, id in ipairs(e.RollRarityIds) do raritySet[id] = true end

    local data = getData()
    local pool = data and data.serverData and data.serverData.rollUnitPool
    if type(pool) ~= "table" then rollStatusText = "No roll pool data"; return end

    -- Wait for the game's own animation lock to clear before firing --
    -- 3s ceiling in case it ever gets stuck, so this can't hang forever.
    local lockDeadline = os.clock() + 3
    while FrameworkLink.Update[RNGRollScript] ~= nil and os.clock() < lockDeadline do
        task.wait(0.03)
    end

    local before = { pool[1], pool[2], pool[3] }
    pcall(function() OnClientGameEvent:Business("RNG_单位") end)

    local pollDeadline = os.clock() + 1.5
    while os.clock() < pollDeadline do
        if pool[1] ~= before[1] or pool[2] ~= before[2] or pool[3] ~= before[3] then break end
        task.wait(0.03)
    end

    local bought = 0
    for slot, cfgId in ipairs(pool) do
        local cfg = cfgId and PlayConfig.allUnit[cfgId]
        if cfg and rollMatchesFilter(cfg, raritySet) then
            pcall(function() OnClientGameEvent:AutoBuy_Backpack_Item("RNG_单位", slot) end)
            bought += 1
        end
    end
    rollStatusText = bought > 0
        and ("Bought " .. bought .. " match(es) this roll")
        or "Rolled -- no match this time"
end

-- ==========================================================================
-- 2) Auto Merge -- OnClientGameEvent:QuickFuse("单位") (confirmed call
-- site, MainBackpack). One-shot "merge everything mergeable" -- the
-- confirm dialog GameEvent.ShowYesOrNo wraps the BUTTON, not the remote,
-- so calling this directly skips the dialog with no side effect.
-- ==========================================================================
local mergeStatusText = "Toggle is OFF"
local function doAutoMerge()
    if not e.AutoMergeEnabled then mergeStatusText = "Toggle is OFF"; return end
    local ok = pcall(function() OnClientGameEvent:QuickFuse("单位") end)
    mergeStatusText = ok and ("Fired @ " .. os.date("%H:%M:%S")) or "Call failed"
end

-- ==========================================================================
-- 3) Auto Equip Best -- place the strongest units from hand onto the field.
-- Confirmed live from downUIs.Hand_RefreshItem: playData.hand[i] (i = 1..
-- PlayConfig.handShowSize) holds a cardId, playData.allCard[cardId] =
-- {typeId, cfgId, star, ...}, typeId==1 is a unit card. The visible hand
-- index i is exactly the arg SelectHandUnit expects (confirmed call site,
-- downUIs handItem_mainBut_OnClick: OnClientGameEvent:SelectHandUnit(p1.id)
-- where p1.id was set to i when the button was built).
-- Field has 14 slots (基本操作_c, confirmed "for i = 1, 14 do"). Empty =
-- playData.sceneUnit[i] falsy, unlocked = serverData.sceneUnitChunkUnlock[i]
-- == true. Placement itself: OnClientGameEvent:BusinessToId("放置_单位", i)
-- (confirmed call site) -- the game normally resolves the slot from where
-- the player is standing via a proximity-tracked touch part, but since the
-- remote's argument shape is already the raw slot index, that physical
-- dance isn't needed here.
-- "Best" = rarity, then mutation tier, then star -- no separate CP/power
-- stat exists on PlayConfig.allUnit to rank by instead.
-- ==========================================================================
local equipStatusText = "Toggle is OFF"

local function doAutoEquip()
    if not e.AutoEquipEnabled then equipStatusText = "Toggle is OFF"; return end
    local data = getData()
    if not data then equipStatusText = "No data"; return end
    local pd = data.playData
    local sd = data.serverData
    if type(pd.hand) ~= "table" or type(pd.allCard) ~= "table" then
        equipStatusText = "No hand data (not in a match?)"
        return
    end

    -- Real DPS, not a rarity/mutation/star proxy -- confirmed live the proxy
    -- ranked wrong (a rarity7/mat1/star5 "Corn" scored ABOVE a rarity7/mat1/
    -- star1 "Flytrap" despite the Flytrap doing 3x the actual DPS, because
    -- attack and attack speed are per-species base stats the proxy never
    -- looked at). MainBusiness.Get_UnitDps(bestUnitAtk, card, AtkRep,
    -- atkSpeedRep) is the exact function the game's own DPS labels call
    -- (confirmed call sites: 基本操作_c line 325, MainBackpack line 442) --
    -- it internally does Get_UnitAtkCfg(...) / Get_UnitAtkCd(cfgId,
    -- atkSpeedRep) and returns a BigNumber, same representation as
    -- BigNumber.GetStr() displays ("7.17M" etc). BigCompareNoEqual(a, b) is
    -- "a > b" as a boolean, not a signed int -- caught that the same way as
    -- the World Boss DPS calculator earlier.
    local bestUnitAtk = pd.bestUnitAtk and pd.bestUnitAtk.Value
    local atkRep = pd.AtkRep and pd.AtkRep.Value
    local atkSpeedRep = pd.atkSpeedRep and pd.atkSpeedRep.Value
    if bestUnitAtk == nil or atkRep == nil or atkSpeedRep == nil then
        equipStatusText = "No atk stat data (not in a match?)"
        return
    end

    local function dpsOf(card)
        local ok, v = pcall(function() return MainBusiness.Get_UnitDps(bestUnitAtk, card, atkRep, atkSpeedRep) end)
        return ok and v or BigNumber.GetZero()
    end
    local function dpsGreater(a, b)
        local ok, v = pcall(BigNumber.BigCompareNoEqual, a, b)
        return ok and v or false
    end

    local handShowSize = PlayConfig.handShowSize or 6
    local candidates = {}
    for i = 1, handShowSize do
        local cardId = pd.hand[i]
        local card = cardId and pd.allCard[cardId]
        if card and card.typeId == 1 and PlayConfig.allUnit[card.cfgId] then
            table.insert(candidates, { handIndex = i, score = dpsOf(card) })
        end
    end
    if #candidates == 0 then equipStatusText = "No units in hand"; return end
    table.sort(candidates, function(a, b) return dpsGreater(a.score, b.score) end)

    -- serverData.sceneUnit, NOT playData.sceneUnit -- confirmed live that
    -- playData.sceneUnit is a VarValue wrapper object (AddSet/Set/SetAll
    -- methods, no numeric keys). serverData.sceneUnit is the real plain
    -- array (0 = empty). Placing a hand card into an OCCUPIED slot silently
    -- replaces whatever was there -- confirmed live: slot 3 held "Chomper"
    -- (mat1/star2), a plain BusinessToId("放置_单位", 3) with a hand unit
    -- selected swapped it straight to "Venom-Flytrap" (mat4/star3), no
    -- separate unequip call needed, and the bumped Chomper card reappeared
    -- back in pd.hand at the vacated index. So the fix isn't a new remote --
    -- it's scoring occupied slots too instead of skipping them.
    local zero = BigNumber.GetZero()
    local slots = {}
    for j = 1, 14 do
        local unlocked = true
        pcall(function() unlocked = sd.sceneUnitChunkUnlock and sd.sceneUnitChunkUnlock[j] == true end)
        if unlocked then
            local occupied = sd.sceneUnit and sd.sceneUnit[j]
            local slotScore, isEmpty = zero, true
            if occupied and occupied ~= 0 then
                local placedCard = pd.allCard[occupied]
                if placedCard and PlayConfig.allUnit[placedCard.cfgId] then
                    slotScore = dpsOf(placedCard)
                    isEmpty = false
                end
            end
            table.insert(slots, { slot = j, score = slotScore, isEmpty = isEmpty })
        end
    end
    if #slots == 0 then equipStatusText = "No unlocked slots"; return end
    table.sort(slots, function(a, b) return dpsGreater(b.score, a.score) end) -- worst slot first

    local placed, replaced = 0, 0
    local slotIdx = 1
    for _, cand in ipairs(candidates) do
        if slotIdx > #slots then break end
        local target = slots[slotIdx]
        -- slots ascending + candidates descending: once the best remaining
        -- hand card can't beat the worst remaining slot, none of the rest
        -- can either -- stop instead of scanning the whole board.
        if not dpsGreater(cand.score, target.score) then break end
        pcall(function() OnClientGameEvent:SelectHandUnit(cand.handIndex) end)
        task.wait(0.1)
        pcall(function() OnClientGameEvent:BusinessToId("放置_单位", target.slot) end)
        task.wait(0.15)
        placed += 1
        if not target.isEmpty then replaced += 1 end
        slotIdx += 1
    end

    if placed == 0 then
        equipStatusText = "Board already optimal"
    else
        equipStatusText = string.format("Placed %d unit(s) (%d replaced weaker)", placed, replaced)
    end
end

-- ==========================================================================
-- 3b) Auto Delete -- multi-select Rarity, each picked rarity gets its own
-- Plant filter (empty = any plant at that rarity), same pattern as Roll.
-- PERMANENT -- OnClientGameEvent:Destroy_GidData_Item("单位", gidList)
-- (confirmed call site, MainBackpack.unit_uiView_DeleteYes_OnClick -- the
-- confirm dialog wraps the button, not the remote, same shape as Merge/
-- Rebirth). Batch delete by gid (serverData.hand entries, confirmed live to
-- be gids into playData.allCard, NOT cfgIds directly -- a hand[i] value and
-- its allCard[hand[i]].cfgId are different numbers, verified live).
-- Never touches a locked unit (allCard[gid].isLock) or one currently placed
-- on the field (serverData.sceneUnit, 0 = empty slot -- same array Auto
-- Equip Best reads) -- identical protection the real Delete button applies,
-- confirmed from MainBackpack.Unit_GetDeleteGids's own filtering.
-- ==========================================================================
local deleteStatusText = "Toggle is OFF"

local function deleteMatchesFilter(cfg, raritySet)
    if not raritySet[cfg.rarity] then return false end
    local plants = e.DeletePlantsByRarity["r" .. cfg.rarity] or {}
    if #plants > 0 and not table.find(plants, unitSpecies(cfg)) then return false end
    return true
end

local function doAutoDelete()
    if not e.AutoDeleteEnabled then deleteStatusText = "Toggle is OFF"; return end
    if #e.DeleteRarityIds == 0 then deleteStatusText = "Pick at least one Rarity first"; return end
    local raritySet = {}
    for _, id in ipairs(e.DeleteRarityIds) do raritySet[id] = true end

    local data = getData()
    if not data then deleteStatusText = "No data"; return end
    local sd, pd = data.serverData, data.playData
    if type(sd.hand) ~= "table" or type(pd.allCard) ~= "table" then
        deleteStatusText = "No collection data"
        return
    end

    local placedSet = {}
    if type(sd.sceneUnit) == "table" then
        for _, gid in pairs(sd.sceneUnit) do
            if gid and gid ~= 0 then placedSet[gid] = true end
        end
    end

    local toDelete = {}
    for _, gid in ipairs(sd.hand) do
        if not placedSet[gid] then
            local card = pd.allCard[gid]
            if card and card.typeId == 1 and not card.isLock then
                local cfg = PlayConfig.allUnit[card.cfgId]
                if cfg and deleteMatchesFilter(cfg, raritySet) then
                    table.insert(toDelete, gid)
                end
            end
        end
    end

    if #toDelete == 0 then deleteStatusText = "Nothing matches right now"; return end
    pcall(function() OnClientGameEvent:Destroy_GidData_Item("单位", toDelete) end)
    deleteStatusText = "Deleted " .. #toDelete .. " unit(s)"
end

-- ==========================================================================
-- 3c) Auto Craft -- the "制作机器0D" (Production Machine) system. ONE active
-- production slot account-wide (playData.productionId, 0 = idle). Start:
-- OnClientGameEvent:BusinessToIdSize("开始制作", recipeId, batchSize)
-- (confirmed call site, ProductionWindow.mainBut_OnClick). Claim when done:
-- OnClientGameEvent:Business("领取制作"). Cancel early:
-- OnClientGameEvent:Business("取消制作") -- not used here, this only starts
-- and claims, never cancels a run in progress.
-- Remaining time = productionMaxTime - (now - productionStartTime), same
-- math the real button uses. PlayConfig.allProduction has 18 recipes
-- (confirmed live), each awarding either a unit (itemEnum "单位") or an
-- item (itemEnum "道具") for a cost in materials/gems/units -- labels
-- resolve the award's real name where possible, fall back to enum+id.
-- ==========================================================================
local craftStatusText = "Toggle is OFF"
local CRAFT_RECIPE_OPTIONS, CRAFT_RECIPE_ID_BY_LABEL, CRAFT_RECIPE_LABEL_BY_ID = {}, {}, {}
do
    local function resolveAwardName(entry)
        if type(entry) ~= "table" then return "?" end
        local val = tonumber(entry.value)
        if entry.itemEnum == "单位" and val then
            local cfg = PlayConfig.allUnit[val]
            if cfg then return cfg.name end
        elseif entry.itemEnum == "道具" and val and PlayConfig.allUseItem then
            local cfg = PlayConfig.allUseItem[val]
            if cfg then return cfg.name or cfg.ZhName or ("Item#" .. val) end
        end
        return (entry.itemEnum or "?") .. "#" .. tostring(val)
    end

    local rows = {}
    for id, cfg in pairs(PlayConfig.allProduction) do table.insert(rows, cfg) end
    table.sort(rows, function(a, b) return (a.showUiIndex or a.id) < (b.showUiIndex or b.id) end)
    for _, cfg in ipairs(rows) do
        local mins = math.floor((tonumber(cfg.baseTime) or 0) / 60)
        local timeStr = mins > 0 and (mins .. "m") or ((tonumber(cfg.baseTime) or 0) .. "s")
        local label = resolveAwardName(cfg.award) .. " (" .. timeStr .. ")"
        if CRAFT_RECIPE_ID_BY_LABEL[label] then label = label .. " #" .. cfg.id end
        table.insert(CRAFT_RECIPE_OPTIONS, label)
        CRAFT_RECIPE_ID_BY_LABEL[label] = cfg.id
        CRAFT_RECIPE_LABEL_BY_ID[cfg.id] = label
    end
end

local function doAutoCraft()
    if not e.AutoCraftEnabled then craftStatusText = "Toggle is OFF"; return end
    local recipeId = e.CraftRecipeId
    if not recipeId or not PlayConfig.allProduction[recipeId] then
        craftStatusText = "Pick a recipe first"
        return
    end

    local data = getData()
    if not data then craftStatusText = "No data"; return end
    local pd = data.playData
    local activeId = readScalar(pd.productionId) or 0

    if activeId > 0 then
        local startTime = readScalar(pd.productionStartTime) or 0
        local maxTime = readScalar(pd.productionMaxTime) or 0
        local remaining = math.max(0, maxTime - (DateTime.now().UnixTimestamp - startTime))
        if remaining <= 0 then
            pcall(function() OnClientGameEvent:Business("领取制作") end)
            craftStatusText = "Claiming recipe " .. activeId .. "..."
        else
            local label = CRAFT_RECIPE_LABEL_BY_ID[activeId] or ("Recipe " .. activeId)
            craftStatusText = string.format("Producing %s -- %ds left", label, math.floor(remaining))
        end
        return
    end

    local batch = math.max(1, tonumber(e.CraftBatchSize) or 1)
    pcall(function() OnClientGameEvent:BusinessToIdSize("开始制作", recipeId, batch) end)
    craftStatusText = "Started " .. (CRAFT_RECIPE_LABEL_BY_ID[recipeId] or ("recipe " .. recipeId)) .. " x" .. batch
end

-- ==========================================================================
-- 3d) Auto Buy Fruit / Auto Buy Item -- both the "Fruit Shop" (道具商店,
-- confirmed live: PlayConfig.allUseItem ids 1-6, useType==1, all named
-- "*-Fruit") and the "Item Shop" (道具商店_手雷, confirmed live: ids 7-11,
-- useType==2, all named "*-Grenade") are separate UI panels but call the
-- exact same remote: OnClientGameEvent:Buy_Backpack_Item("道具", id)
-- (confirmed call site, both UseItemStore.ui_Item_buyBut1_OnClick and
-- UseItemStore_Grenade's own copy of the same handler). Stock is shared:
-- playData.allUseItemStoreSize[id] (confirmed live, plain array 1-30,
-- 0 = sold out until the periodic restock) -- both features skip an id
-- with no stock left instead of firing a call that can't succeed.
-- Empty selection = buy any in-stock id from that shop, same "empty = any"
-- convention as Roll/Delete.
-- ==========================================================================
local FRUIT_IDS, GRENADE_IDS = { 1, 2, 3, 4, 5, 6 }, { 7, 8, 9, 10, 11 }

local function buildShopOptions(ids)
    local options, idByName = {}, {}
    for _, id in ipairs(ids) do
        local cfg = PlayConfig.allUseItem[id]
        if cfg then
            table.insert(options, cfg.name)
            idByName[cfg.name] = id
        end
    end
    return options, idByName
end
local FRUIT_OPTIONS, FRUIT_ID_BY_NAME = buildShopOptions(FRUIT_IDS)
local ITEM_OPTIONS, ITEM_ID_BY_NAME = buildShopOptions(GRENADE_IDS)

local fruitStatusText = "Toggle is OFF"
local itemStatusText = "Toggle is OFF"

local function doAutoBuyShop(enabled, selectedNames, idByName, allIds)
    if not enabled then return "Toggle is OFF" end
    local data = getData()
    if not data then return "No data" end
    local stock = data.playData.allUseItemStoreSize
    if type(stock) ~= "table" then return "No stock data" end

    local nameSet = nil
    if type(selectedNames) == "table" and #selectedNames > 0 then
        nameSet = {}
        for _, n in ipairs(selectedNames) do
            local id = idByName[n]
            if id then nameSet[id] = true end
        end
    end

    local bought = 0
    for _, id in ipairs(allIds) do
        if (not nameSet or nameSet[id]) and (tonumber(stock[id]) or 0) > 0 then
            pcall(function() OnClientGameEvent:Buy_Backpack_Item("道具", id) end)
            bought += 1
        end
    end
    return bought > 0 and ("Bought " .. bought .. " item(s)") or "Nothing in stock right now"
end

local function doAutoBuyFruit()
    fruitStatusText = doAutoBuyShop(e.AutoBuyFruitEnabled, e.BuyFruitNames, FRUIT_ID_BY_NAME, FRUIT_IDS)
end

local function doAutoBuyItem()
    itemStatusText = doAutoBuyShop(e.AutoBuyItemEnabled, e.BuyItemNames, ITEM_ID_BY_NAME, GRENADE_IDS)
end

-- ==========================================================================
-- 4/5) Auto Start Wave / Auto Stop at Wave N
-- OnClientGameEvent:StartGp() / :ExitGp() (confirmed call sites, upUIs, no
-- args). Not a per-wave remote -- one session toggle.
-- Wave count read from leaderstats.Wave (definitely a plain IntValue).
-- Stop-at-N restarts the run: ExitGp() then StartGp() again -- this drives
-- a fresh run from wave 1, not a rebirth (Auto Rebirth is its own feature).
-- ==========================================================================
local waveStatusText = "Idle"
local lastStartGpFire = 0

local function currentWave()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    local w = ls and ls:FindFirstChild("Wave")
    return (w and w.Value) or 0
end

-- playData.MainState (confirmed live: plain string, not VarValue-wrapped)
-- is the real signal upUIs itself uses -- server sets it to "比赛" (battle)
-- on its own OnServerGameEvent.StartGp confirmation and "自由" (free) on
-- EndGp. The old version fired StartGp blind every 4s regardless of this,
-- which is exactly what the real button does NOT do (StartBut_OnClick
-- no-ops if a match is already running) -- reported live as "doesn't work
-- after rejoin", most likely a rejoin-timing window where this fired before
-- something was ready and then had no way to show that in the status text.
-- Checking MainState directly fixes both: only fires when genuinely idle,
-- and the status line now says which state it actually saw instead of a
-- blind "keeping match started" guess.
local function matchIsRunning(data)
    local pd = data and data.playData
    return pd and pd.MainState == "比赛"
end

local function doAutoWave()
    if not e.AutoStartWaveEnabled and not e.AutoStopWaveEnabled then
        waveStatusText = "Idle"
        return
    end
    local wave = currentWave()
    local data = getData()
    local running = matchIsRunning(data)

    if e.AutoStopWaveEnabled and tonumber(e.WaveStopTarget) and tonumber(e.WaveStopTarget) > 0
        and wave >= tonumber(e.WaveStopTarget) then
        pcall(function() OnClientGameEvent:ExitGp() end)
        task.wait(1)
        pcall(function() OnClientGameEvent:StartGp() end)
        waveStatusText = string.format("Wave %d reached target %d -- restarted", wave, e.WaveStopTarget)
        lastStartGpFire = os.clock()
        return
    end

    if e.AutoStartWaveEnabled and not running and os.clock() - lastStartGpFire > 4 then
        pcall(function() OnClientGameEvent:StartGp() end)
        lastStartGpFire = os.clock()
        waveStatusText = "Wave " .. wave .. " -- MainState idle, requesting start"
        return
    end
    waveStatusText = "Wave " .. wave .. (e.AutoStartWaveEnabled and (running and " -- match running" or " -- waiting to retry start") or "")
end

-- ==========================================================================
-- 6) Auto Upgrade -- multi-select stats, each picked stat gets its own
-- Max Lv target.
-- OnClientGameEvent:Buy_Backpack_Item("人物属性升级", statId) (confirmed
-- call site, StatUpgradeWindow0D). Stats read live from
-- PlayConfig.allStatUpgrade (confirmed live, 8 entries): Damage Boost,
-- Attack Speed, Attack Range, Diamond Drop, Wins Boost, Luck Boost (this is
-- "Luck"), Unit Slots, Player Health -- each with its own max level
-- (.size), current level read from serverData.allStatUpgrade[statId].
-- Fires one Buy_Backpack_Item per selected-and-pending stat per tick, so N
-- selected stats each advance roughly once per loop interval, not just the
-- first one.
-- ==========================================================================
local upgradeStatusText = "Toggle is OFF"
local STAT_OPTIONS, STAT_ID_BY_NAME, STAT_CFG_BY_NAME, STAT_IDS_ORDERED = {}, {}, {}, {}
do
    local rows = {}
    for id, cfg in pairs(PlayConfig.allStatUpgrade) do table.insert(rows, cfg) end
    table.sort(rows, function(a, b) return a.id < b.id end)
    for _, cfg in ipairs(rows) do
        table.insert(STAT_OPTIONS, cfg.title)
        STAT_ID_BY_NAME[cfg.title] = cfg.id
        STAT_CFG_BY_NAME[cfg.title] = cfg
        table.insert(STAT_IDS_ORDERED, cfg.id)
    end
end

local function doAutoUpgrade()
    if not e.AutoUpgradeEnabled then upgradeStatusText = "Toggle is OFF"; return end
    if #e.UpgradeStatIds == 0 then upgradeStatusText = "Pick at least one stat first"; return end

    local data = getData()
    if not data then upgradeStatusText = "No data"; return end

    local parts = {}
    for _, statId in ipairs(e.UpgradeStatIds) do
        local cfg = PlayConfig.allStatUpgrade[statId]
        if cfg then
            local curLevel = 0
            pcall(function() curLevel = tonumber(data.serverData.allStatUpgrade[statId]) or 0 end)
            local targetLevel = math.min(tonumber(e.UpgradeMaxLevelByStat["s" .. statId]) or cfg.size, cfg.size)
            if curLevel < targetLevel then
                pcall(function() OnClientGameEvent:Buy_Backpack_Item("人物属性升级", statId) end)
                table.insert(parts, string.format("%s Lv%d->%d/%d", cfg.title, curLevel, curLevel + 1, targetLevel))
            else
                table.insert(parts, string.format("%s Lv%d/%d done", cfg.title, curLevel, cfg.size))
            end
        end
    end
    upgradeStatusText = #parts > 0 and table.concat(parts, "  |  ") or "No valid stats selected"
end

-- ==========================================================================
-- 7) Auto Rebirth -- OnClientGameEvent:Business("重生"), no args (confirmed
-- call site, StatUpgradeWindow0D.rebirth_mainBut_OnClick -- fires straight
-- from inside the game's own GameEvent.ShowYesOrNo confirm callback, same
-- "dialog wraps the remote" shape as Auto Merge). Gate is NOT a currency
-- cost: PlayConfig.allRebirth[rebirth+1].con = {value, itemEnum, size}, and
-- for this account itemEnum is "波次最高记录" (wave record) -- so this
-- compares the recorded max wave against that threshold, not gold/gems.
-- ==========================================================================
local rebirthStatusText = "Toggle is OFF"
local function doAutoRebirth()
    if not e.AutoRebirthEnabled then rebirthStatusText = "Toggle is OFF"; return end
    local data = getData()
    if not data then rebirthStatusText = "No data"; return end

    local rebirthCount = tonumber(data.serverData.rebirth) or 0
    local nextCfg = PlayConfig.allRebirth[rebirthCount + 1]
    if not nextCfg then rebirthStatusText = "Max rebirth reached"; return end

    local need = (nextCfg.con and tonumber(nextCfg.con.value)) or 0
    local have = readScalar(data.playData.maxWave) or currentWave()
    if have < need then
        rebirthStatusText = string.format("Rebirth %d needs wave record %d (have %d)", rebirthCount + 1, need, have)
        return
    end
    pcall(function() OnClientGameEvent:Business("重生") end)
    rebirthStatusText = string.format("Requested rebirth %d (wave record %d/%d)", rebirthCount + 1, have, need)
end

-- ==========================================================================
-- 8) Auto Claim Mission -- daily task list.
-- Confirmed call site, DayTaskWindow.ui_item_mainBut_OnClick:
--   OnClientGameEvent:BusinessToId("每日任务_在线时间达到N秒", id)
-- The client hardcodes that literal string for EVERY task id (confirmed
-- from source, not a transcription slip) -- the task id arg is what
-- actually selects which task gets claimed, so this replicates the client
-- exactly. Progress = playData.dayTaskSize[id], requirement =
-- PlayConfig.allDayTask[id].con.size, already-claimed =
-- playData.dayTaskIsOk[id] == true.
-- ==========================================================================
local missionStatusText = "Toggle is OFF"
local function doAutoClaimMission()
    if not e.AutoClaimMissionEnabled then missionStatusText = "Toggle is OFF"; return end
    local data = getData()
    if not data then missionStatusText = "No data"; return end
    local pd = data.playData
    if type(pd.dayTaskSize) ~= "table" then missionStatusText = "No task data"; return end

    local claimed = 0
    for id, cfg in pairs(PlayConfig.allDayTask) do
        local need = math.max(1, (cfg.con and tonumber(cfg.con.size)) or 1)
        local progress = tonumber(pd.dayTaskSize[id]) or 0
        local isClaimed = pd.dayTaskIsOk and pd.dayTaskIsOk[id] == true
        if progress >= need and not isClaimed then
            pcall(function() OnClientGameEvent:BusinessToId("每日任务_在线时间达到N秒", id) end)
            claimed += 1
            task.wait(0.2)
        end
    end
    missionStatusText = claimed > 0 and ("Claimed " .. claimed .. " mission(s)") or "Nothing claimable"
end

-- ==========================================================================
-- 9) Auto Claim Daily -- OnClientGameEvent:GetGift("每日宝箱", 1, 1)
-- (confirmed call site, dayBoxWindow -- exact real button handler args).
-- Server no-ops when nothing is ready, safe to poll on an interval.
-- ==========================================================================
local dailyStatusText = "Toggle is OFF"
local function doAutoClaimDaily()
    if not e.AutoClaimDailyEnabled then dailyStatusText = "Toggle is OFF"; return end
    local ok = pcall(function() OnClientGameEvent:GetGift("每日宝箱", 1, 1) end)
    dailyStatusText = ok and ("Requested @ " .. os.date("%H:%M:%S")) or "Call failed"
end

-- ==========================================================================
-- 10) Auto Boss -- World Boss + Zone Boss.
-- World Boss: OnClientGameEvent:BusinessToId("世界Boss", 1) to join,
-- ("世界Boss", 2) to leave (confirmed call site, upUIs -- same call fires
-- from both the main button while already joined AND the dedicated
-- WorldBoss_Exit_OnClick). Gate: PlayConfig.worldBossUnlockRebirth.
-- WorldBoss_ID (ServerInfo) isn't a boss "type" picker -- PlayConfig.
-- allWorldBoss has exactly 7 entries, ids 1-7 with no gaps (confirmed live,
-- counted directly), all the same boss (Dragon Cannelloni) at rising HP
-- (confirmed live: 40B/55B/65B/85B/100B/125B/200B for ids 1-7). Called
-- "Tier" here on purpose, NOT "Level" -- confirmed from 世界Boss_c.
-- RefreshWorldBossUI: the in-game "Level X" HUD text is a SEPARATE week
-- counter (1-84, tied to real UTC time), not WorldBoss_ID. WorldBoss_ID is
-- only ever used internally to key PlayConfig.allWorldBoss for HP/image/
-- awards -- it's never shown to the player as a number, so "Tier" avoids
-- colliding with a different number the game already calls "Level".
-- Each Tier gets its own Mode dropdown (Full Fight = stay joined, no
-- auto-leave; Poke & Leave = duration timer then leave) -- picking a tier
-- reveals its own Mode pair, same show/hide-by-multi-select pattern as
-- Roll's per-rarity pairs. A tier with no Mode chosen defaults to Full Fight.
-- Zone Boss: OnClientGameEvent:BusinessToId("区域Boss", 1) to join,
-- ("区域Boss", 2) to leave -- confirmed symmetric, dedicated
-- ZoneBoss_Exit_OnClick handler found in source (区域Boss_c.ZeroLink).
-- Gate: PlayConfig.zoneBossUnlockRebirth.
-- Boss HP is not a Workspace Instance property -- it's client-simulated and
-- pushed through GameEvent.SetBossHp(hp, maxHp), a callable table
-- (__call metamethod), from 战斗_c's local combat sim. Tried hooking it by
-- replacing the field with a capture-then-forward wrapper -- broke live:
-- EventHandle dispatches by re-reading the GameEvent.SetBossHp field by name
-- on every call rather than calling a captured self, so the wrapper's own
-- forwarding call re-entered itself every frame during a real boss fight
-- (confirmed live: "EventHandle:15: stack overflow" spamming the console the
-- instant a wave-boss fight was active). Reading boss HP is dropped entirely
-- rather than risk that again -- Poke & Leave is a plain duration timer.
-- Reward-on-participation for a short join/leave (no kill) is also not
-- confirmed server-side either way.
-- ==========================================================================
local function findServerInfo()
    local sys = workspace:FindFirstChild("系统")
    return sys and sys:FindFirstChild("ServerInfo")
end

-- DPS-needed guide: PlayConfig.worldBossRunTime (confirmed live = 1200s,
-- the countdown 世界Boss_c syncs WorldBoss_Time against) is the whole
-- event window, so HP / runTime is the flat DPS a level needs to die
-- within it. Static per level (HP/runtime don't change mid-session) --
-- computed once here, not in the refresh loop.
local WORLD_BOSS_DPS_NEEDED_STR = {}
local function buildWorldBossDpsGuide(levelIds)
    for _, lvl in ipairs(levelIds) do
        local cfg = PlayConfig.allWorldBoss[lvl]
        local runTime = tonumber(PlayConfig.worldBossRunTime) or 1200
        local ok, needed = pcall(function() return BigNumber.DivNumber(cfg.hp, runTime) end)
        WORLD_BOSS_DPS_NEEDED_STR[lvl] = ok and BigNumber.GetStr(needed) or "?"
    end
end

-- Player's current Total DPS: sum of Get_UnitDps over every placed field
-- unit (playData.sceneUnit[i] -> cardId -> playData.allCard[cardId], same
-- indirection confirmed live in 基本操作_c.RefreshSceneUnitData -- this is
-- the exact same call+argument shape the game's own "DPS: " unit labels
-- use, just summed across the board instead of shown per-unit).
local function computeMyTotalDps()
    local data = getData()
    if not data then return nil end
    local pd = data.playData
    if type(pd.sceneUnit) ~= "table" or type(pd.allCard) ~= "table" then return nil end
    local bestUnitAtk = readScalar(pd.bestUnitAtk)
    local atkRep = readScalar(pd.AtkRep)
    local atkSpeedRep = readScalar(pd.atkSpeedRep)
    local total = BigNumber.GetZero()
    for i = 1, 14 do
        local cardId = pd.sceneUnit[i]
        local card = cardId and cardId > 0 and pd.allCard[cardId]
        if card and card.typeId == 1 then
            local ok, dps = pcall(function() return MainBusiness.Get_UnitDps(bestUnitAtk, card, atkRep, atkSpeedRep) end)
            if ok and dps then total = BigNumber.Add(total, dps) end
        end
    end
    return total
end

local worldBossStatusText = "Toggle is OFF"
local worldBossJoined, worldBossJoinedAt = false, 0

local function doAutoWorldBoss()
    if not e.AutoWorldBossEnabled then worldBossStatusText = "Toggle is OFF"; worldBossJoined = false; return end
    local data = getData()
    local sd = data and data.serverData
    local rebirth = sd and tonumber(sd.rebirth) or 0
    if PlayConfig.worldBossUnlockRebirth and rebirth < PlayConfig.worldBossUnlockRebirth then
        worldBossStatusText = "Locked -- needs rebirth " .. PlayConfig.worldBossUnlockRebirth
        return
    end

    local info = findServerInfo()
    local bossIdInst = info and info:FindFirstChild("WorldBoss_ID")
    local bossId = bossIdInst and bossIdInst.Value or 0
    if bossId <= 0 then
        worldBossStatusText = "No World Boss active right now"
        worldBossJoined = false
        return
    end

    if not worldBossJoined then
        pcall(function() OnClientGameEvent:BusinessToId("世界Boss", 1) end)
        worldBossJoined, worldBossJoinedAt = true, os.clock()
        worldBossStatusText = "Joined Tier " .. bossId
        return
    end

    local mode = e.WorldBossModeByLevel["l" .. bossId] or "Full Fight"
    if mode == "Poke & Leave" then
        local elapsed = os.clock() - worldBossJoinedAt
        local dur = tonumber(e.WorldBossPokeSeconds) or 6
        if elapsed >= dur then
            pcall(function() OnClientGameEvent:BusinessToId("世界Boss", 2) end)
            worldBossJoined = false
            worldBossStatusText = string.format("Tier %d -- left after %.1fs (poke)", bossId, elapsed)
        else
            worldBossStatusText = string.format("Tier %d -- poking %.1f/%ds", bossId, elapsed, dur)
        end
    else
        worldBossStatusText = "Tier " .. bossId .. " -- Full Fight"
    end
end

local zoneBossStatusText = "Toggle is OFF"
local zoneBossJoined, zoneBossJoinedAt = false, 0

local function doAutoZoneBoss()
    if not e.AutoZoneBossEnabled then zoneBossStatusText = "Toggle is OFF"; zoneBossJoined = false; return end
    local data = getData()
    local sd = data and data.serverData
    local rebirth = sd and tonumber(sd.rebirth) or 0
    if PlayConfig.zoneBossUnlockRebirth and rebirth < PlayConfig.zoneBossUnlockRebirth then
        zoneBossStatusText = "Locked -- needs rebirth " .. PlayConfig.zoneBossUnlockRebirth
        return
    end

    local info = findServerInfo()
    local bossIdInst = info and info:FindFirstChild("ZoneBoss_ID")
    local active = bossIdInst and bossIdInst.Value and bossIdInst.Value > 0
    if not active then
        zoneBossStatusText = "No Zone Boss active right now"
        zoneBossJoined = false
        return
    end

    if not zoneBossJoined then
        pcall(function() OnClientGameEvent:BusinessToId("区域Boss", 1) end)
        zoneBossJoined, zoneBossJoinedAt = true, os.clock()
        zoneBossStatusText = "Joined"
        return
    end

    if e.ZoneBossMode == "Poke & Leave" then
        local elapsed = os.clock() - zoneBossJoinedAt
        local dur = tonumber(e.ZoneBossPokeSeconds) or 6
        if elapsed >= dur then
            pcall(function() OnClientGameEvent:BusinessToId("区域Boss", 2) end)
            zoneBossJoined = false
            zoneBossStatusText = string.format("Left after %.1fs", elapsed)
        else
            zoneBossStatusText = string.format("In fight %.1f/%ds", elapsed, dur)
        end
    else
        zoneBossStatusText = "Fighting (Full Fight mode)"
    end
end

-- ==========================================================================
-- Boost FPS -- disables Lighting PostEffects (Bloom/SunRays/DepthOfField/
-- ColorCorrection/Blur) and GlobalShadows, drops UserGameSettings graphics
-- quality to its lowest preset. Every prior Enabled state is captured
-- before the first change so turning the toggle back off restores exactly
-- what was there, not just "on" -- this game also flips its own Sky/
-- lighting on events (ServerInfo.SkyType), so a hardcoded restore would
-- fight that instead of returning control to it.
-- ==========================================================================
local Lighting = game:GetService("Lighting")
local boostFpsOriginalState = nil

local function applyBoostFps(enabled)
    if enabled then
        if boostFpsOriginalState == nil then
            boostFpsOriginalState = { GlobalShadows = Lighting.GlobalShadows, effects = {} }
            for _, eff in ipairs(Lighting:GetChildren()) do
                if eff:IsA("PostEffect") then
                    boostFpsOriginalState.effects[eff] = eff.Enabled
                end
            end
        end
        pcall(function() Lighting.GlobalShadows = false end)
        for _, eff in ipairs(Lighting:GetChildren()) do
            if eff:IsA("PostEffect") then
                pcall(function() eff.Enabled = false end)
            end
        end
        pcall(function()
            UserSettings():GetService("UserGameSettings").SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
        end)
    elseif boostFpsOriginalState then
        pcall(function() Lighting.GlobalShadows = boostFpsOriginalState.GlobalShadows end)
        for eff, wasEnabled in pairs(boostFpsOriginalState.effects) do
            pcall(function() if eff.Parent then eff.Enabled = wasEnabled end end)
        end
        pcall(function()
            UserSettings():GetService("UserGameSettings").SavedQualityLevel = Enum.SavedQualitySetting.Automatic
        end)
        boostFpsOriginalState = nil
    end
end

-- ==========================================================================
-- Hide Other Bases -- Workspace.玩家地块 (confirmed live) holds one numbered
-- Folder per plot slot (1-6 on this server), each with a 区域01 Model (the
-- plot's terrain/platform). LocalPlayer.playerIndex (confirmed live, a
-- plain IntValue) is which numbered slot is actually ours -- every OTHER
-- slot's platform gets LocalTransparencyModifier'd to invisible (client-
-- only, reversible, doesn't touch the real Transparency property other
-- players see). Workspace.创建.业务.单位 (confirmed live, 44 live models
-- during testing) is a SHARED folder for every placed plant across every
-- base, not per-player -- filtered by proximity to each OTHER plot's own
-- center instead, since that's the only per-player signal available on
-- these models.
-- ==========================================================================
local plotsFolder = workspace:FindFirstChild("玩家地块")
local unitsFolder = workspace:FindFirstChild("创建")
unitsFolder = unitsFolder and unitsFolder:FindFirstChild("业务")
unitsFolder = unitsFolder and unitsFolder:FindFirstChild("单位")
local HIDE_OTHER_BASES_RADIUS = 80

-- hiddenInstances tracks every non-BasePart thing touched (name/DPS labels,
-- particles, trails) so the exact prior state comes back on restore instead
-- of guessing a default. BaseParts don't need this -- LocalTransparencyModifier
-- has its own always-correct "off" value (0), no original to remember.
local hiddenParts = {}
local hiddenInstances = {}

local function setModelHidden(model, hidden)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            if hidden then
                hiddenParts[d] = true
                d.LocalTransparencyModifier = 1
            elseif hiddenParts[d] then
                d.LocalTransparencyModifier = 0
                hiddenParts[d] = nil
            end
        elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Smoke") or d:IsA("Fire") then
            if hidden then
                if hiddenInstances[d] == nil then hiddenInstances[d] = d.Enabled end
                d.Enabled = false
            elseif hiddenInstances[d] ~= nil then
                d.Enabled = hiddenInstances[d]
                hiddenInstances[d] = nil
            end
        elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
            -- the name/DPS/rarity labels floating over a placed unit --
            -- these are GUIs, not BaseParts, LocalTransparencyModifier does
            -- nothing to them.
            if hidden then
                if hiddenInstances[d] == nil then hiddenInstances[d] = d.Enabled end
                d.Enabled = false
            elseif hiddenInstances[d] ~= nil then
                d.Enabled = hiddenInstances[d]
                hiddenInstances[d] = nil
            end
        elseif d:IsA("Decal") or d:IsA("Texture") then
            if hidden then
                if hiddenInstances[d] == nil then hiddenInstances[d] = d.Transparency end
                d.Transparency = 1
            elseif hiddenInstances[d] ~= nil then
                d.Transparency = hiddenInstances[d]
                hiddenInstances[d] = nil
            end
        end
    end
end

local function myPlotIndex()
    local idx = LocalPlayer:FindFirstChild("playerIndex")
    return idx and idx.Value
end

local function applyHideOtherBases(enabled)
    if not plotsFolder then return end
    local myIndex = myPlotIndex()
    for _, plotFolder in ipairs(plotsFolder:GetChildren()) do
        local idx = tonumber(plotFolder.Name)
        if idx and idx ~= myIndex then
            local area = plotFolder:FindFirstChild("区域01")
            if area then setModelHidden(area, enabled) end
            if enabled and unitsFolder and area then
                local ok, plotCf = pcall(function() return area:GetPivot() end)
                if ok then
                    for _, unit in ipairs(unitsFolder:GetChildren()) do
                        local okU, unitCf = pcall(function() return unit:GetPivot() end)
                        if okU and (unitCf.Position - plotCf.Position).Magnitude <= HIDE_OTHER_BASES_RADIUS then
                            setModelHidden(unit, true)
                        end
                    end
                end
            end
        end
    end
    if not enabled then
        for part in pairs(hiddenParts) do
            pcall(function() if part.Parent then part.LocalTransparencyModifier = 0 end end)
        end
        table.clear(hiddenParts)
        for inst, original in pairs(hiddenInstances) do
            pcall(function()
                if not inst.Parent then return end
                if inst:IsA("Decal") or inst:IsA("Texture") then
                    inst.Transparency = original
                else
                    inst.Enabled = original
                end
            end)
        end
        table.clear(hiddenInstances)
    end
end

-- ==========================================================================
-- Anti-AFK / Auto Reconnect
-- ==========================================================================
LocalPlayer.Idled:Connect(function()
    if getgenv().__MPG == myGen and getgenv().AntiAFKEnabled then
        pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
    end
end)

-- game:BindToClose is SERVER-ONLY -- tried it, threw immediately on the
-- client ("BindToClose can only be called on the server."), unguarded, and
-- took the whole script down before the window could even build. Confirmed
-- live, do not reintroduce it here.
--
-- PlayerRemoving is a server-replicated "a player left the roster" signal,
-- so on a genuinely dead connection there's no live socket left for the
-- server to tell this client anything through it -- it will not fire for
-- every real drop. LocalPlayer.AncestryChanged is added alongside it as a
-- second, purely-local signal: it fires whenever the LocalPlayer instance's
-- position in the DataModel tree changes, including the client's own
-- teardown when it gives up on a dead connection -- that part of the
-- teardown is local instance-tree bookkeeping, not something that needs a
-- live server round-trip to happen. Between the two this catches more real
-- disconnects than either alone, but neither is a hard guarantee: if the
-- connection dies badly enough that the client's Lua VM stops running
-- entirely before any teardown, no script (ours or anyone else's) gets a
-- chance to react -- that is a Roblox engine limit, not something fixable
-- from here.
if not getgenv().__MPReconnectHooked then
    getgenv().__MPReconnectHooked = true
    local reconnectFired = false
    local function tryReconnect()
        if reconnectFired then return end
        reconnectFired = true
        if getgenv().AutoReconnectEnabled then
            pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
        end
    end
    Players.PlayerRemoving:Connect(function(player)
        if player == LocalPlayer then tryReconnect() end
    end)
    LocalPlayer.AncestryChanged:Connect(function(_, parent)
        if parent ~= Players then tryReconnect() end
    end)
end

-- ==========================================================================
-- UI
-- ==========================================================================
print("[MutantPlants] Loading MacLib...")
local ok, lib = pcall(function()
    return loadstring(game:HttpGet(
        "https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not ok or not lib then warn("[MutantPlants] MacLib load failed -- features are active, running headless"); return end
e.__MPLIB = lib
task.wait()
if getgenv().__MPG ~= myGen then return end

local safeSlider = function(section, settings, flag)
    local sok, result = pcall(function() return section:Slider(settings, flag) end)
    if sok then return result end
    return section:Label({ Text = settings.Name .. " = " .. tostring(settings.Default) .. "\n(slider blocked -- set getgenv() value directly)" })
end
local safeInput = function(section, settings, flag)
    local sok, result = pcall(function() return section:Input(settings, flag) end)
    if sok and result then return result end
    return section:Label({ Text = settings.Name .. "\n(input blocked -- set the getgenv() value directly)" })
end

local Window = lib:Window({ Title = "Mutant Plants Automation", Subtitle = "v1.0", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false })
e.__MPWindow = Window
local TabGroup = Window:TabGroup()
-- Lucide icon pack MacLib ships with -- same ids already in use (and
-- labeled) across code.lua/card.lua in this repo, not new guesses.
local Tabs = {
    Roll     = TabGroup:Tab({ Name = "Roll",     Image = "rbxassetid://10723396000" }), -- lucide-gem
    Farm     = TabGroup:Tab({ Name = "Farm",     Image = "rbxassetid://10734886202" }), -- lucide-map
    Wave     = TabGroup:Tab({ Name = "Wave",     Image = "rbxassetid://10723415903" }), -- reused across roll_anime/anime_fight/new.lua, zap (10723397078) didn't render
    Upgrade  = TabGroup:Tab({ Name = "Upgrade",  Image = "rbxassetid://10734963191" }), -- lucide-sliders-horizontal
    Shop     = TabGroup:Tab({ Name = "Shop",     Image = "rbxassetid://10734952273" }), -- lucide-shopping-bag
    Boss     = TabGroup:Tab({ Name = "Boss",     Image = "rbxassetid://10734975692" }), -- lucide-swords
    Claims   = TabGroup:Tab({ Name = "Claims",   Image = "rbxassetid://10723396402" }), -- lucide-gift
    Settings = TabGroup:Tab({ Name = "Settings", Image = "rbxassetid://10734950309" }), -- lucide-settings
}

-- ----- Roll Tab -----
local RollLeft = Tabs.Roll:Section({ Side = "Left" })
RollLeft:Header({ Text = "Rarities (multi)" })

local plantDDByRarity, mutationDDByRarity, headerByRarity = {}, {}, {}

local function rollRaritySet()
    local set = {}
    for _, id in ipairs(e.RollRarityIds) do set[id] = true end
    return set
end

local function currentPlantOptions(rarityId)
    local set, list = {}, {}
    for _, cfg in pairs(PlayConfig.allUnit) do
        if cfg.rarity == rarityId then
            local species = unitSpecies(cfg)
            if not set[species] then set[species] = true; table.insert(list, species) end
        end
    end
    table.sort(list)
    return list
end

local function currentMutationOptions(rarityId)
    local plants = e.RollPlantsByRarity["r" .. rarityId] or {}
    local set, list = {}, {}
    for _, cfg in pairs(PlayConfig.allUnit) do
        if cfg.rarity == rarityId then
            local species = unitSpecies(cfg)
            if #plants == 0 or table.find(plants, species) then
                local matName = MATERIAL_NAME_BY_ID[cfg.MaterialRarity]
                if matName and not set[matName] then set[matName] = true; table.insert(list, matName) end
            end
        end
    end
    table.sort(list)
    return list
end

-- Picking Rarities just shows/hides each rarity's own pre-built Plant +
-- Mutation pair below -- nothing is created/destroyed on the fly (MacLib
-- has no clean "remove this element" call), so all 7 pairs exist from load
-- and only the selected ones are visible. Selecting Mythic + Secret shows
-- exactly those 2 pairs (4 dropdowns); deselecting a rarity just hides its
-- pair again, it doesn't forget the picks inside it.
local rarityDD = RollLeft:Dropdown({
    Name = "Rarity", Options = RARITY_OPTIONS, Multi = true, IgnoreConfig = true,
    Callback = function(selectedSet)
        local ids = {}
        if type(selectedSet) == "table" then
            for name, isOn in pairs(selectedSet) do
                if isOn and RARITY_ID_BY_NAME[name] then table.insert(ids, RARITY_ID_BY_NAME[name]) end
            end
        end
        e.RollRarityIds = ids
        local set = rollRaritySet()
        for id, dd in pairs(plantDDByRarity) do pcall(function() dd:SetVisibility(set[id] == true) end) end
        for id, dd in pairs(mutationDDByRarity) do pcall(function() dd:SetVisibility(set[id] == true) end) end
        for id, hdr in pairs(headerByRarity) do pcall(function() hdr:SetVisibility(set[id] == true) end) end
        saveState()
    end,
}, "RollRarityDropdown")

for _, rarityId in ipairs(RARITY_IDS_ORDERED) do
    local rarityName = RARITY_NAME_BY_ID[rarityId]
    local key = "r" .. rarityId
    local hdr = RollLeft:Header({ Text = rarityName })
    headerByRarity[rarityId] = hdr

    local pdd = RollLeft:Dropdown({
        Name = rarityName .. " Plant (empty = any)", Options = currentPlantOptions(rarityId), Multi = true, IgnoreConfig = true,
        Callback = function(selectedSet)
            local list = {}
            if type(selectedSet) == "table" then
                for name, isOn in pairs(selectedSet) do if isOn then table.insert(list, name) end end
            end
            e.RollPlantsByRarity[key] = list
            -- Changing Plant can shrink which Mutations are even possible for
            -- THIS rarity -- rebuild that pair's mutation options, then drop
            -- any selected Mutation that fell out of it.
            pcall(function()
                local mdd = mutationDDByRarity[rarityId]
                local newOpts = currentMutationOptions(rarityId)
                mdd:ClearOptions(); mdd:InsertOptions(newOpts)
                local kept = {}
                for _, name in ipairs(e.RollMutationsByRarity[key] or {}) do
                    if table.find(newOpts, name) then table.insert(kept, name) end
                end
                e.RollMutationsByRarity[key] = kept
                if #kept > 0 then mdd:UpdateSelection(kept) end
            end)
            saveState()
        end,
    }, "RollPlant_" .. rarityId .. "Dropdown")
    plantDDByRarity[rarityId] = pdd

    local mdd = RollLeft:Dropdown({
        Name = rarityName .. " Mutation (empty = any)", Options = currentMutationOptions(rarityId), Multi = true, IgnoreConfig = true,
        Callback = function(selectedSet)
            local list = {}
            if type(selectedSet) == "table" then
                for name, isOn in pairs(selectedSet) do if isOn then table.insert(list, name) end end
            end
            e.RollMutationsByRarity[key] = list
            saveState()
        end,
    }, "RollMutation_" .. rarityId .. "Dropdown")
    mutationDDByRarity[rarityId] = mdd

    local persistedPlants = e.RollPlantsByRarity[key]
    if persistedPlants and #persistedPlants > 0 then pcall(function() pdd:UpdateSelection(persistedPlants) end) end
    local persistedMuts = e.RollMutationsByRarity[key]
    if persistedMuts and #persistedMuts > 0 then pcall(function() mdd:UpdateSelection(persistedMuts) end) end

    local visible = rollRaritySet()[rarityId] == true
    pdd:SetVisibility(visible)
    mdd:SetVisibility(visible)
    pcall(function() hdr:SetVisibility(visible) end)
end

-- Cosmetic restore now that every pair exists -- shows the right checkmarks
-- on rarityDD itself without disturbing the per-pair state set up above.
if #e.RollRarityIds > 0 then
    local names = {}
    for _, id in ipairs(e.RollRarityIds) do table.insert(names, RARITY_NAME_BY_ID[id]) end
    pcall(function() rarityDD:UpdateSelection(names) end)
end

local RollRight = Tabs.Roll:Section({ Side = "Right" })
RollRight:Header({ Text = "Auto Buy" })
RollRight:Toggle({
    Name = "Auto Roll + Buy", Default = e.AutoRollBuyEnabled,
    Callback = function(v) e.AutoRollBuyEnabled = v; saveState() end,
}, "AutoRollBuyEnabled")
RollRight:Label({ Text = "Rolls RNG_单位 on a loop, buys any slot matching any selected Rarity + its own Plant + Mutation" })
local rollStatusLabel = RollRight:Label({ Text = "Idle" })

-- ----- Farm Tab -----
local FarmLeft = Tabs.Farm:Section({ Side = "Left" })
FarmLeft:Header({ Text = "Auto Merge" })
FarmLeft:Toggle({
    Name = "Auto Merge", Default = e.AutoMergeEnabled,
    Callback = function(v) e.AutoMergeEnabled = v; saveState() end,
}, "AutoMergeEnabled")
FarmLeft:Label({ Text = "Fires QuickFuse on a loop -- merges everything mergeable" })
local mergeStatusLabel = FarmLeft:Label({ Text = "Idle" })
FarmLeft:Divider()

local FarmRight = Tabs.Farm:Section({ Side = "Right" })
FarmRight:Header({ Text = "Auto Equip Best" })
FarmRight:Toggle({
    Name = "Auto Equip Best", Default = e.AutoEquipEnabled,
    Callback = function(v) e.AutoEquipEnabled = v; saveState() end,
}, "AutoEquipEnabled")
FarmRight:Label({ Text = "Places the strongest hand units into empty field slots" })
local equipStatusLabel = FarmRight:Label({ Text = "Idle" })
FarmRight:Divider()

FarmLeft:Header({ Text = "Auto Craft" })
FarmLeft:Toggle({
    Name = "Auto Craft", Default = e.AutoCraftEnabled,
    Callback = function(v) e.AutoCraftEnabled = v; saveState() end,
}, "AutoCraftEnabled")
local craftRecipeDD = FarmLeft:Dropdown({
    Name = "Recipe", Options = CRAFT_RECIPE_OPTIONS, IgnoreConfig = true,
    Callback = function(selected)
        if selected then e.CraftRecipeId = CRAFT_RECIPE_ID_BY_LABEL[selected]; saveState() end
    end,
}, "CraftRecipeDropdown")
if e.CraftRecipeId and CRAFT_RECIPE_LABEL_BY_ID[e.CraftRecipeId] then
    pcall(function() craftRecipeDD:UpdateSelection(CRAFT_RECIPE_LABEL_BY_ID[e.CraftRecipeId]) end)
end
safeInput(FarmLeft, {
    Name = "Batch Size", Default = tostring(e.CraftBatchSize), AcceptedCharacters = "Numeric",
    Callback = function(text) e.CraftBatchSize = math.max(1, tonumber(text) or 1); saveState() end,
}, "CraftBatchSizeInput")
FarmLeft:Label({ Text = "Starts the recipe when the production slot is free, claims it the instant it's done" })
local craftStatusLabel = FarmLeft:Label({ Text = "Idle" })

FarmRight:Header({ Text = "Auto Delete -- Rarities (multi)" })
FarmRight:Label({ Text = "PERMANENT -- never touches a locked or field-placed unit, everything else matching is gone" })

local deletePlantDDByRarity = {}

local function deleteRaritySet()
    local set = {}
    for _, id in ipairs(e.DeleteRarityIds) do set[id] = true end
    return set
end

local deleteRarityDD = FarmRight:Dropdown({
    Name = "Delete Rarity (multi)", Options = RARITY_OPTIONS, Multi = true, IgnoreConfig = true,
    Callback = function(selectedSet)
        local ids = {}
        if type(selectedSet) == "table" then
            for name, isOn in pairs(selectedSet) do
                if isOn and RARITY_ID_BY_NAME[name] then table.insert(ids, RARITY_ID_BY_NAME[name]) end
            end
        end
        e.DeleteRarityIds = ids
        local set = deleteRaritySet()
        for id, dd in pairs(deletePlantDDByRarity) do pcall(function() dd:SetVisibility(set[id] == true) end) end
        saveState()
    end,
}, "DeleteRarityDropdown")

for _, rarityId in ipairs(RARITY_IDS_ORDERED) do
    local rarityName = RARITY_NAME_BY_ID[rarityId]
    local key = "r" .. rarityId
    -- No separate Header here -- the Dropdown's own Name already says
    -- "{rarity} Plant", a header repeating just the rarity name above it
    -- was pure duplication.
    local pdd = FarmRight:Dropdown({
        Name = rarityName .. " Plant (empty = any)", Options = currentPlantOptions(rarityId), Multi = true, IgnoreConfig = true,
        Callback = function(selectedSet)
            local list = {}
            if type(selectedSet) == "table" then
                for name, isOn in pairs(selectedSet) do if isOn then table.insert(list, name) end end
            end
            e.DeletePlantsByRarity[key] = list
            saveState()
        end,
    }, "DeletePlant_" .. rarityId .. "Dropdown")
    deletePlantDDByRarity[rarityId] = pdd
    local persisted = e.DeletePlantsByRarity[key]
    if persisted and #persisted > 0 then pcall(function() pdd:UpdateSelection(persisted) end) end
    pdd:SetVisibility(deleteRaritySet()[rarityId] == true)
end

if #e.DeleteRarityIds > 0 then
    local names = {}
    for _, id in ipairs(e.DeleteRarityIds) do table.insert(names, RARITY_NAME_BY_ID[id]) end
    pcall(function() deleteRarityDD:UpdateSelection(names) end)
end

FarmRight:Toggle({
    Name = "Auto Delete", Default = e.AutoDeleteEnabled,
    Callback = function(v) e.AutoDeleteEnabled = v; saveState() end,
}, "AutoDeleteEnabled")
local deleteStatusLabel = FarmRight:Label({ Text = "Idle" })

-- ----- Wave Tab -----
local WaveLeft = Tabs.Wave:Section({ Side = "Left" })
WaveLeft:Header({ Text = "Auto Start Wave" })
WaveLeft:Toggle({
    Name = "Auto Start Wave", Default = e.AutoStartWaveEnabled,
    Callback = function(v) e.AutoStartWaveEnabled = v; saveState() end,
}, "AutoStartWaveEnabled")
WaveLeft:Label({ Text = "Keeps firing StartGp() so a run never sits idle" })

local WaveRight = Tabs.Wave:Section({ Side = "Right" })
WaveRight:Header({ Text = "Auto Stop at Wave" })
WaveRight:Toggle({
    Name = "Auto Stop at Wave N", Default = e.AutoStopWaveEnabled,
    Callback = function(v) e.AutoStopWaveEnabled = v; saveState() end,
}, "AutoStopWaveEnabled")
safeInput(WaveRight, {
    Name = "Stop at Wave (0 = never)", Default = tostring(e.WaveStopTarget), AcceptedCharacters = "Numeric",
    Callback = function(text) e.WaveStopTarget = tonumber(text) or 0; saveState() end,
}, "WaveStopTargetInput")
WaveRight:Label({ Text = "Restarts the run (ExitGp then StartGp) once this wave is reached" })
local waveStatusLabel = WaveRight:Label({ Text = "Idle" })

-- ----- Upgrade Tab -----
local UpgradeLeft = Tabs.Upgrade:Section({ Side = "Left" })
UpgradeLeft:Header({ Text = "Stats (multi)" })

local maxLvInputByStat = {}

local function upgradeStatSet()
    local set = {}
    for _, id in ipairs(e.UpgradeStatIds) do set[id] = true end
    return set
end

-- Same show/hide-by-set approach as Roll's per-rarity pairs: one Max Lv
-- input per stat is built upfront (loop below), the multi-select here just
-- toggles which ones are visible.
local statDD = UpgradeLeft:Dropdown({
    Name = "Stat", Options = STAT_OPTIONS, Multi = true, IgnoreConfig = true,
    Callback = function(selectedSet)
        local ids = {}
        if type(selectedSet) == "table" then
            for name, isOn in pairs(selectedSet) do
                if isOn and STAT_ID_BY_NAME[name] then table.insert(ids, STAT_ID_BY_NAME[name]) end
            end
        end
        e.UpgradeStatIds = ids
        local set = upgradeStatSet()
        for id, inp in pairs(maxLvInputByStat) do pcall(function() inp:SetVisibility(set[id] == true) end) end
        saveState()
    end,
}, "UpgradeStatDropdown")

for _, statId in ipairs(STAT_IDS_ORDERED) do
    local cfg = PlayConfig.allStatUpgrade[statId]
    local key = "s" .. statId
    if e.UpgradeMaxLevelByStat[key] == nil then e.UpgradeMaxLevelByStat[key] = cfg.size end
    local inp = safeInput(UpgradeLeft, {
        Name = cfg.title .. " Max Lv (of " .. cfg.size .. ")",
        Default = tostring(e.UpgradeMaxLevelByStat[key]),
        AcceptedCharacters = "Numeric",
        Callback = function(text)
            local v = tonumber(text)
            e.UpgradeMaxLevelByStat[key] = v and math.clamp(v, 1, cfg.size) or cfg.size
            saveState()
        end,
    }, "UpgradeMaxLv_" .. statId .. "Input")
    maxLvInputByStat[statId] = inp
    pcall(function() inp:SetVisibility(upgradeStatSet()[statId] == true) end)
end

if #e.UpgradeStatIds > 0 then
    local names = {}
    for _, id in ipairs(e.UpgradeStatIds) do
        local cfg = PlayConfig.allStatUpgrade[id]
        if cfg then table.insert(names, cfg.title) end
    end
    pcall(function() statDD:UpdateSelection(names) end)
end

local UpgradeRight = Tabs.Upgrade:Section({ Side = "Right" })
UpgradeRight:Header({ Text = "Auto Upgrade" })
UpgradeRight:Toggle({
    Name = "Auto Upgrade", Default = e.AutoUpgradeEnabled,
    Callback = function(v) e.AutoUpgradeEnabled = v; saveState() end,
}, "AutoUpgradeEnabled")
local upgradeStatusLabel = UpgradeRight:Label({ Text = "Idle" })

-- ----- Shop Tab -----
local ShopLeft = Tabs.Shop:Section({ Side = "Left" })
ShopLeft:Header({ Text = "Auto Buy Fruit" })
ShopLeft:Toggle({
    Name = "Auto Buy Fruit", Default = e.AutoBuyFruitEnabled,
    Callback = function(v) e.AutoBuyFruitEnabled = v; saveState() end,
}, "AutoBuyFruitEnabled")
local fruitDD = ShopLeft:Dropdown({
    Name = "Fruit (empty = any in stock)", Options = FRUIT_OPTIONS, Multi = true, IgnoreConfig = true,
    Callback = function(selectedSet)
        local list = {}
        if type(selectedSet) == "table" then
            for name, isOn in pairs(selectedSet) do if isOn then table.insert(list, name) end end
        end
        e.BuyFruitNames = list
        saveState()
    end,
}, "BuyFruitDropdown")
if #e.BuyFruitNames > 0 then pcall(function() fruitDD:UpdateSelection(e.BuyFruitNames) end) end
ShopLeft:Label({ Text = "Fruit Shop (道具商店) -- buys with Gems while stock lasts, refills on the shop's own restock timer" })
local fruitStatusLabel = ShopLeft:Label({ Text = "Idle" })

local ShopRight = Tabs.Shop:Section({ Side = "Right" })
ShopRight:Header({ Text = "Auto Buy Item" })
ShopRight:Toggle({
    Name = "Auto Buy Item", Default = e.AutoBuyItemEnabled,
    Callback = function(v) e.AutoBuyItemEnabled = v; saveState() end,
}, "AutoBuyItemEnabled")
local itemDD = ShopRight:Dropdown({
    Name = "Item (empty = any in stock)", Options = ITEM_OPTIONS, Multi = true, IgnoreConfig = true,
    Callback = function(selectedSet)
        local list = {}
        if type(selectedSet) == "table" then
            for name, isOn in pairs(selectedSet) do if isOn then table.insert(list, name) end end
        end
        e.BuyItemNames = list
        saveState()
    end,
}, "BuyItemDropdown")
if #e.BuyItemNames > 0 then pcall(function() itemDD:UpdateSelection(e.BuyItemNames) end) end
ShopRight:Label({ Text = "Item Shop (道具商店_手雷) -- same restock timer as the Fruit Shop, separate stock" })
local itemStatusLabel = ShopRight:Label({ Text = "Idle" })

-- ----- Boss Tab -----
local BossLeft = Tabs.Boss:Section({ Side = "Left" })
BossLeft:Header({ Text = "World Boss" })
BossLeft:Toggle({
    Name = "Auto World Boss", Default = e.AutoWorldBossEnabled,
    Callback = function(v) e.AutoWorldBossEnabled = v; saveState() end,
}, "AutoWorldBossEnabled")
-- Same show/hide-by-multi-select pattern as Roll's per-rarity pairs: one
-- Mode dropdown per World Boss tier is pre-built (loop below), picking a
-- Tier here just toggles which ones are visible. "Tier" not "Level" --
-- see the big comment above doAutoWorldBoss for why (the game's own
-- "Level X" HUD text is an unrelated week counter, not this id).
local WORLD_BOSS_LEVEL_IDS = {}
do
    local ids = {}
    for id in pairs(PlayConfig.allWorldBoss) do table.insert(ids, id) end
    table.sort(ids)
    WORLD_BOSS_LEVEL_IDS = ids
end
local WORLD_BOSS_LEVEL_OPTIONS = {}
for _, lvl in ipairs(WORLD_BOSS_LEVEL_IDS) do table.insert(WORLD_BOSS_LEVEL_OPTIONS, "Tier " .. lvl) end
buildWorldBossDpsGuide(WORLD_BOSS_LEVEL_IDS)

BossLeft:Header({ Text = "DPS Needed (kill within " .. (tonumber(PlayConfig.worldBossRunTime) or 1200) .. "s)" })
local worldBossDpsGuideLabel = BossLeft:Label({ Text = "Calculating..." })
BossLeft:Label({ Text = "\"Tier\" = PlayConfig.allWorldBoss id (drives HP/rewards) -- NOT the in-game \"Level X\" HUD text, that's a separate week counter" })

BossLeft:Label({ Text = "Pick a Tier to reveal its own Full Fight / Poke & Leave choice" })

local worldBossModeDDByLevel = {}

local function worldBossLevelSet()
    local set = {}
    for _, id in ipairs(e.WorldBossLevels) do set[id] = true end
    return set
end

local worldBossLevelDD = BossLeft:Dropdown({
    Name = "Tier (multi)", Options = WORLD_BOSS_LEVEL_OPTIONS, Multi = true, IgnoreConfig = true,
    Callback = function(selectedSet)
        local ids = {}
        if type(selectedSet) == "table" then
            for name, isOn in pairs(selectedSet) do
                if isOn then
                    local lvl = tonumber(name:match("%d+"))
                    if lvl then table.insert(ids, lvl) end
                end
            end
        end
        e.WorldBossLevels = ids
        local set = worldBossLevelSet()
        for lvl, dd in pairs(worldBossModeDDByLevel) do pcall(function() dd:SetVisibility(set[lvl] == true) end) end
        saveState()
    end,
}, "WorldBossLevelDropdown")

for _, lvl in ipairs(WORLD_BOSS_LEVEL_IDS) do
    local key = "l" .. lvl
    local dd = BossLeft:Dropdown({
        Name = "Tier " .. lvl .. " Mode", Options = { "Full Fight", "Poke & Leave" }, IgnoreConfig = true,
        Callback = function(selected)
            if selected then e.WorldBossModeByLevel[key] = selected; saveState() end
        end,
    }, "WorldBossMode_" .. lvl .. "Dropdown")
    worldBossModeDDByLevel[lvl] = dd
    local persisted = e.WorldBossModeByLevel[key]
    if persisted then pcall(function() dd:UpdateSelection(persisted) end) end
    dd:SetVisibility(worldBossLevelSet()[lvl] == true)
end

if #e.WorldBossLevels > 0 then
    local names = {}
    for _, lvl in ipairs(e.WorldBossLevels) do table.insert(names, "Tier " .. lvl) end
    pcall(function() worldBossLevelDD:UpdateSelection(names) end)
end

safeSlider(BossLeft, {
    Name = "Poke Seconds", Minimum = 1, Maximum = 60, Precision = 0,
    Default = e.WorldBossPokeSeconds,
    Callback = function(v) e.WorldBossPokeSeconds = math.floor(tonumber(v) or 6); saveState() end,
}, "WorldBossPokeSlider")
local worldBossStatusLabel = BossLeft:Label({ Text = "Idle" })

local BossRight = Tabs.Boss:Section({ Side = "Right" })
BossRight:Header({ Text = "Zone Boss" })
BossRight:Toggle({
    Name = "Auto Zone Boss", Default = e.AutoZoneBossEnabled,
    Callback = function(v) e.AutoZoneBossEnabled = v; saveState() end,
}, "AutoZoneBossEnabled")
local zoneBossModeDD = BossRight:Dropdown({
    Name = "Mode", Options = { "Full Fight", "Poke & Leave" }, IgnoreConfig = true,
    Callback = function(selected) if selected then e.ZoneBossMode = selected; saveState() end end,
}, "ZoneBossModeDropdown")
pcall(function() zoneBossModeDD:UpdateSelection(e.ZoneBossMode) end)
safeSlider(BossRight, {
    Name = "Poke Seconds", Minimum = 1, Maximum = 60, Precision = 0,
    Default = e.ZoneBossPokeSeconds,
    Callback = function(v) e.ZoneBossPokeSeconds = math.floor(tonumber(v) or 6); saveState() end,
}, "ZoneBossPokeSlider")
local zoneBossStatusLabel = BossRight:Label({ Text = "Idle" })

-- ----- Claims Tab -----
local ClaimsLeft = Tabs.Claims:Section({ Side = "Left" })
ClaimsLeft:Header({ Text = "Auto Rebirth" })
ClaimsLeft:Toggle({
    Name = "Auto Rebirth", Default = e.AutoRebirthEnabled,
    Callback = function(v) e.AutoRebirthEnabled = v; saveState() end,
}, "AutoRebirthEnabled")
ClaimsLeft:Label({ Text = "Gate is wave record, not currency -- fires once the record clears the next tier" })
local rebirthStatusLabel = ClaimsLeft:Label({ Text = "Idle" })

local ClaimsRight = Tabs.Claims:Section({ Side = "Right" })
ClaimsRight:Header({ Text = "Auto Claim Mission + Daily" })
ClaimsRight:Toggle({
    Name = "Auto Claim Mission", Default = e.AutoClaimMissionEnabled,
    Callback = function(v) e.AutoClaimMissionEnabled = v; saveState() end,
}, "AutoClaimMissionEnabled")
local missionStatusLabel = ClaimsRight:Label({ Text = "Idle" })
ClaimsRight:Toggle({
    Name = "Auto Claim Daily", Default = e.AutoClaimDailyEnabled,
    Callback = function(v) e.AutoClaimDailyEnabled = v; saveState() end,
}, "AutoClaimDailyEnabled")
local dailyStatusLabel = ClaimsRight:Label({ Text = "Idle" })

-- ----- Settings Tab -----
local SettingsLeft = Tabs.Settings:Section({ Side = "Left" })
SettingsLeft:Header({ Text = "General" })
SettingsLeft:Toggle({
    Name = "Anti-AFK", Default = e.AntiAFKEnabled,
    Callback = function(v) e.AntiAFKEnabled = v; saveState() end,
}, "AntiAFKEnabled")
SettingsLeft:Toggle({
    Name = "Auto Reconnect", Default = e.AutoReconnectEnabled,
    Callback = function(v) e.AutoReconnectEnabled = v; saveState() end,
}, "AutoReconnectEnabled")
SettingsLeft:Header({ Text = "Performance" })
SettingsLeft:Toggle({
    Name = "Boost FPS", Default = e.BoostFpsEnabled,
    Callback = function(v) e.BoostFpsEnabled = v; pcall(applyBoostFps, v); saveState() end,
}, "BoostFpsEnabled")
SettingsLeft:Toggle({
    Name = "Hide Other Bases", Default = e.HideOtherBasesEnabled,
    Callback = function(v) e.HideOtherBasesEnabled = v; pcall(applyHideOtherBases, v); saveState() end,
}, "HideOtherBasesEnabled")
pcall(function()
    SettingsLeft:Keybind({
        Name = "Show/Hide UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
        Callback = function() pcall(function() Window:SetState(not Window:GetState()) end) end,
    }, "MutantPlantsToggleUIKeybind")
end)
SettingsLeft:Header({ Text = "Auto Save" })
SettingsLeft:Label({ Text = "Auto-saved to " .. SAVE_FILE .. " (only while Manual Save Mode, right, is OFF)" })

-- ----- Settings Tab, Right: Save Mode + named Config profiles -----
-- Two systems, mutually exclusive by getgenv().ManualSaveMode (flipped by
-- the toggle below, read at the top of this file before the UI even
-- builds): Auto (left) keeps writing state.json on every change like
-- before. Manual turns that off -- saveState() no-ops -- and instead you
-- snapshot the live getgenv() settings into named files under
-- CONFIG_FOLDER, load one back explicitly, and optionally mark one
-- AutoLoad so a fresh session picks it up without state.json at all.
local SettingsRight = Tabs.Settings:Section({ Side = "Right" })

-- Config Create/List only matter once Manual mode is on -- Auto Save keeps
-- doing its thing with none of this in view. Every element below that
-- belongs to that section gets wrapped in trackConfigElement() and hidden
-- until the toggle flips it on, instead of cluttering the tab permanently.
local configSectionElements = {}
local function trackConfigElement(el)
    table.insert(configSectionElements, el)
    return el
end
local function setConfigSectionVisible(v)
    for _, el in ipairs(configSectionElements) do
        pcall(function() el:SetVisibility(v) end)
    end
end

SettingsRight:Header({ Text = "Save Mode" })
SettingsRight:Toggle({
    Name = "Manual Save Mode", Default = e.ManualSaveMode,
    Callback = function(v)
        e.ManualSaveMode = v
        pcall(function() writefile(MODE_FILE, v and "manual" or "auto") end)
        setConfigSectionVisible(v)
    end,
}, "ManualSaveMode")
SettingsRight:Label({ Text = "OFF: every change auto-saves (default).\nON: nothing auto-saves -- use Configs below." })

trackConfigElement(SettingsRight:Header({ Text = "Config Create" }))
local configNameInput = trackConfigElement(safeInput(SettingsRight, {
    Name = "Config Name", Placeholder = "e.g. Farming", Default = "",
}, "MPConfigNameInput"))

local configDropdown, autoLoadLabel, configStatusLabel
local selectedConfigName = nil

local function sanitizeConfigName(raw)
    local name = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return (name:gsub("[^%w _%-]", ""))
end

-- listfiles() returns full paths -- name:match strips folder + extension,
-- handling both "/" and "\\" separators since executors differ on this.
local function listConfigNames()
    local names = {}
    local ok, files = pcall(listfiles, CONFIG_FOLDER)
    if ok and type(files) == "table" then
        for _, path in ipairs(files) do
            local name = path:match("([^/\\]+)%.json$")
            if name then table.insert(names, name) end
        end
    end
    table.sort(names)
    return names
end

local function writeConfigSnapshot(name)
    local data = {}
    for _, key in ipairs(PERSIST_KEYS) do data[key] = getgenv()[key] end
    return pcall(function() writefile(configPath(name), HttpService:JSONEncode(data)) end)
end

local function updateConfigStatus(msg)
    pcall(function() configStatusLabel:UpdateName(msg) end)
end

local function refreshConfigDropdown()
    local names = listConfigNames()
    pcall(function() configDropdown:ClearOptions() end)
    pcall(function() configDropdown:InsertOptions(names) end)
    if selectedConfigName and not table.find(names, selectedConfigName) then
        selectedConfigName = nil
    end
end

local function refreshAutoLoadLabel()
    local name = readTextFile(AUTOLOAD_FILE)
    pcall(function() autoLoadLabel:UpdateName("Current AutoLoad Config: " .. (name or "(none)")) end)
end

trackConfigElement(SettingsRight:Button({
    Name = "Create Config",
    Callback = function()
        local okInput, raw = pcall(function() return configNameInput:GetInput() end)
        local name = sanitizeConfigName(okInput and raw or "")
        if name == "" then updateConfigStatus("Type a name first"); return end
        if table.find(listConfigNames(), name) then
            updateConfigStatus("'" .. name .. "' already exists -- use Overwrite")
            return
        end
        local ok = writeConfigSnapshot(name)
        updateConfigStatus(ok and ("Created '" .. name .. "'") or "Write failed")
        refreshConfigDropdown()
    end,
}, "MPCreateConfigButton"))

trackConfigElement(SettingsRight:Header({ Text = "Config List" }))
configDropdown = trackConfigElement(SettingsRight:Dropdown({
    Name = "Configs", Options = listConfigNames(), Multi = false, Search = true,
    Callback = function(selected) selectedConfigName = selected end,
}, "MPConfigDropdown"))

-- Placing into an already-running window mid-session (not a fresh join) --
-- so Load doesn't try to hot-patch ~30 live Toggles/Dropdowns one by one.
-- It force-applies the config into getgenv(), then re-fetches and re-runs
-- this exact script from SELF_URL, same HttpGet->loadstring->call() shape
-- as loader.lua -- which is the same __MPG-bump/Unload-old-window path
-- already proven safe every time this file gets manually reloaded.
trackConfigElement(SettingsRight:Button({
    Name = "Load Config",
    Callback = function()
        if not selectedConfigName then updateConfigStatus("Pick a config first"); return end
        local content = readTextFile(configPath(selectedConfigName))
        if not content then updateConfigStatus("Config file missing"); return end
        local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
        if not ok2 or type(data) ~= "table" then updateConfigStatus("Corrupt config file"); return end
        applyDataToGenv(data, true)
        updateConfigStatus("Loaded '" .. selectedConfigName .. "' -- reloading UI...")
        task.spawn(function()
            local okFetch, body = pcall(function() return game:HttpGet(SELF_URL) end)
            if not okFetch then warn("[MutantPlants] Reload after Load Config failed: " .. tostring(body)); return end
            local compiledFn, err = loadstring(body)
            if not compiledFn then warn("[MutantPlants] Reload compile failed: " .. tostring(err)); return end
            pcall(compiledFn)
        end)
    end,
}, "MPLoadConfigButton"))

trackConfigElement(SettingsRight:Button({
    Name = "Overwrite Config",
    Callback = function()
        if not selectedConfigName then updateConfigStatus("Pick a config first"); return end
        local ok = writeConfigSnapshot(selectedConfigName)
        updateConfigStatus(ok and ("Overwrote '" .. selectedConfigName .. "'") or "Write failed")
    end,
}, "MPOverwriteConfigButton"))

trackConfigElement(SettingsRight:Button({
    Name = "Delete Config",
    Callback = function()
        if not selectedConfigName then updateConfigStatus("Pick a config first"); return end
        local name = selectedConfigName
        pcall(function() delfile(configPath(name)) end)
        if readTextFile(AUTOLOAD_FILE) == name then
            pcall(function() writefile(AUTOLOAD_FILE, "") end)
            refreshAutoLoadLabel()
        end
        selectedConfigName = nil
        updateConfigStatus("Deleted '" .. name .. "'")
        refreshConfigDropdown()
    end,
}, "MPDeleteConfigButton"))

trackConfigElement(SettingsRight:Button({
    Name = "Refresh List",
    Callback = function() refreshConfigDropdown(); updateConfigStatus("List refreshed") end,
}, "MPRefreshConfigListButton"))

trackConfigElement(SettingsRight:Button({
    Name = "Set as AutoLoad",
    Callback = function()
        if not selectedConfigName then updateConfigStatus("Pick a config first"); return end
        local ok = pcall(function() writefile(AUTOLOAD_FILE, selectedConfigName) end)
        if ok then
            refreshAutoLoadLabel()
            updateConfigStatus("AutoLoad set to '" .. selectedConfigName .. "'")
        else
            updateConfigStatus("Write failed")
        end
    end,
}, "MPSetAutoLoadButton"))

trackConfigElement(SettingsRight:Button({
    Name = "Reset AutoLoad",
    Callback = function()
        pcall(function() writefile(AUTOLOAD_FILE, "") end)
        refreshAutoLoadLabel()
        updateConfigStatus("AutoLoad cleared")
    end,
}, "MPResetAutoLoadButton"))

autoLoadLabel = trackConfigElement(SettingsRight:Label({ Text = "Current AutoLoad Config: " .. (readTextFile(AUTOLOAD_FILE) or "(none)") }))
configStatusLabel = trackConfigElement(SettingsRight:Label({ Text = "" }))

-- Initial visibility -- everything above starts hidden unless the account
-- was already in Manual mode when this session's UI first built.
setConfigSectionVisible(e.ManualSaveMode)

-- ===== Background loops =====
task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(function()
            local myDps = computeMyTotalDps()
            local myDpsStr = myDps and BigNumber.GetStr(myDps) or "?"
            local lines = {}
            for _, lvl in ipairs(WORLD_BOSS_LEVEL_IDS) do
                local needStr = WORLD_BOSS_DPS_NEEDED_STR[lvl] or "?"
                local mark = "?"
                if myDps then
                    local cfg = PlayConfig.allWorldBoss[lvl]
                    local runTime = tonumber(PlayConfig.worldBossRunTime) or 1200
                    local okNeeded, needed = pcall(function() return BigNumber.DivNumber(cfg.hp, runTime) end)
                    if okNeeded then
                        -- BigCompare(a, b) returns a plain boolean for "a >= b"
                        -- (confirmed live), not a signed int -- no >= 0 needed.
                        local okCmp, atLeast = pcall(function() return BigNumber.BigCompare(myDps, needed) end)
                        if okCmp then mark = atLeast and "OK" or "LOW" end
                    end
                end
                table.insert(lines, string.format("Tier %d needs %s DPS -- %s", lvl, needStr, mark))
            end
            table.insert(lines, "Your Total DPS: " .. myDpsStr)
            pcall(function() worldBossDpsGuideLabel:UpdateName(table.concat(lines, "\n")) end)
        end)
        task.wait(2)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoRoll)
        pcall(function() rollStatusLabel:UpdateName(rollStatusText) end)
        -- doAutoRoll already paces itself on the real animation lock +
        -- pool-change poll -- this is just a floor so a stuck/instant
        -- return (e.g. toggle off) doesn't spin the loop at full tilt.
        task.wait(0.05)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoMerge)
        pcall(function() mergeStatusLabel:UpdateName(mergeStatusText) end)
        task.wait(3)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoDelete)
        pcall(function() deleteStatusLabel:UpdateName(deleteStatusText) end)
        -- Slower than Merge on purpose -- this is permanent, no need to
        -- hammer it every 3s when nothing new to delete shows up that often.
        task.wait(5)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoCraft)
        pcall(function() craftStatusLabel:UpdateName(craftStatusText) end)
        task.wait(3)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoBuyFruit)
        pcall(function() fruitStatusLabel:UpdateName(fruitStatusText) end)
        pcall(doAutoBuyItem)
        pcall(function() itemStatusLabel:UpdateName(itemStatusText) end)
        task.wait(1)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoEquip)
        pcall(function() equipStatusLabel:UpdateName(equipStatusText) end)
        task.wait(2)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoWave)
        pcall(function() waveStatusLabel:UpdateName(waveStatusText) end)
        task.wait(1)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoUpgrade)
        pcall(function() upgradeStatusLabel:UpdateName(upgradeStatusText) end)
        task.wait(1)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoRebirth)
        pcall(function() rebirthStatusLabel:UpdateName(rebirthStatusText) end)
        task.wait(5)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoClaimMission)
        pcall(function() missionStatusLabel:UpdateName(missionStatusText) end)
        task.wait(10)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoClaimDaily)
        pcall(function() dailyStatusLabel:UpdateName(dailyStatusText) end)
        task.wait(30)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoWorldBoss)
        pcall(function() worldBossStatusLabel:UpdateName(worldBossStatusText) end)
        task.wait(1)
    end
end)

task.spawn(function()
    while getgenv().__MPG == myGen do
        pcall(doAutoZoneBoss)
        pcall(function() zoneBossStatusLabel:UpdateName(zoneBossStatusText) end)
        task.wait(1)
    end
end)

if e.BoostFpsEnabled then pcall(applyBoostFps, true) end
if e.HideOtherBasesEnabled then pcall(applyHideOtherBases, true) end
task.spawn(function()
    while getgenv().__MPG == myGen do
        -- Re-assert while ON -- new units keep landing in the shared
        -- 创建.业务.单位 folder as other players place plants, and this
        -- game resets some Lighting effects on its own (ServerInfo.SkyType
        -- changes), so a one-shot apply at toggle time doesn't stay true.
        if e.HideOtherBasesEnabled then pcall(applyHideOtherBases, true) end
        if e.BoostFpsEnabled then pcall(applyBoostFps, true) end
        task.wait(3)
    end
end)

saveState()
pcall(function() Tabs.Roll:Select() end)
print(string.format("[MutantPlants] v1.0 loaded (gen %d, %s)", myGen, os.date("%H:%M:%S")))
