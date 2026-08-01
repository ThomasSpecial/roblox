-- Idle Slayers Automation
-- Auto Attack + Damage Test + Auto Upgrade (Player/Hero) + Auto Prestige +
-- Auto Collect Coins + Auto Open Crates + Auto Claim Daily +
-- Auto Summon (x1/x10 + auto-delete Rare/Epic/Legendary + banner info) +
-- Farm Loop (Map/Level + Skip Boss) +
-- Auto Delete (skips Locked + Equipped items) + Anti-AFK
-- Auto Save/Load (writefile, no manual Save/Autoload needed)
-- UI built with Maclib (https://github.com/biggaboy212/Maclib)
-- Paste into your executor, or add after the MCP loader block in your autoexec.

getgenv().__AutomationGen = (getgenv().__AutomationGen or 0) + 1
local myGen = getgenv().__AutomationGen

pcall(function()
    if getgenv().__MacRealWindow then getgenv().__MacRealWindow:Unload() end
end)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

-- ===== Auto Save / Auto Load (writefile/readfile, no manual Save button) =====
-- Persists actual toggle/setting state to disk so it survives full game rejoins
-- (getgenv() is memory-only and resets on every rejoin). Every Callback below
-- calls saveState() right after updating getgenv(), so there is nothing to
-- remember to save -- it just always matches whatever you last set.
-- EXCEPTION: the three Delete "Enable" toggles are deliberately NOT persisted
-- and always start OFF (see the Locked-item incident notes below) -- everything
-- else restores automatically.
local SAVE_FOLDER = "IdleSlayersAutomation"
local SAVE_FILE = SAVE_FOLDER .. "/state.json"
pcall(function()
    if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end
end)

local PERSIST_KEYS = {
    "AutoAttackEnabled", "AttackSpeedMul", "NoCooldown",
    "AutoUpgradePlayerEnabled", "AutoUpgradeHeroEnabled", "AutoUpgradeMultiplier",
    "AutoPrestigeEnabled", "FarmLoopEnabled", "SkipBossEnabled", "FarmLoopBiome", "FarmLoopLevelId",
    "AntiAFKEnabled", "AutoCollectCoins", "AutoOpenCrateEnabled", "SelectedCrate",
    "DeleteRarities_Weapon", "DeleteRarities_Hero", "DeleteRarities_Relic",
    "AutoClaimDailyEnabled", "AutoSummonEnabled", "SummonAmount",
    "InfGold", "InfStardust", "InfPlayPoints", "BypassDamage", "BypassAttackSpeed",
}

local function loadPersistedState()
    local ok, content = pcall(function() return readfile(SAVE_FILE) end)
    if not ok or not content or content == "" then return end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not ok2 or type(data) ~= "table" then return end
    for _, key in ipairs(PERSIST_KEYS) do
        if data[key] ~= nil and getgenv()[key] == nil then
            getgenv()[key] = data[key]
        end
    end
end
loadPersistedState()

local function saveState()
    local data = {}
    for _, key in ipairs(PERSIST_KEYS) do
        data[key] = getgenv()[key]
    end
    pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(data)) end)
end
getgenv().__SaveState = saveState

-- KNOWN ISSUE (Maclib library bug, verified via isolated repro): a single-select
-- Dropdown's button label intermittently never renders the selected option text
-- (shows a blank "..." placeholder), regardless of whether Default (index) or
-- :UpdateSelection(value) is used. Verified via repeated isolated tests that it
-- is NOT tied to option position, creation order, or flag name -- it looks like
-- a genuine race/render bug inside Maclib itself. The underlying value
-- (getgenv() state, what the automation actually does, and the separate status
-- Label under each dropdown) is unaffected and correct -- only the dropdown
-- button's own inline text can occasionally be cosmetically blank. Mitigated
-- (not guaranteed fixed) by re-applying UpdateSelection a few times after a
-- short delay once the whole window has finished building.
local pendingDropdownSync = {}
local function registerDropdownSync(dropdown, value)
    table.insert(pendingDropdownSync, {dropdown = dropdown, value = value})
end
local function retrySyncDropdowns()
    task.spawn(function()
        for _, wait in ipairs({0.3, 1, 2}) do
            task.wait(wait)
            for _, entry in ipairs(pendingDropdownSync) do
                pcall(function() entry.dropdown:UpdateSelection(entry.value) end)
            end
        end
    end)
end

local Library = ReplicatedStorage:WaitForChild("Library")
local Mutex = require(Library:WaitForChild("Mutex"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local CharacterHandler = require(Modules:WaitForChild("CharacterHandler"))
local Data = ReplicatedStorage:WaitForChild("Data")
local Weapons = require(Data:WaitForChild("Weapons"))
local Modifiers = require(Data:WaitForChild("Modifiers"))
local PrestiegeData = require(Data:WaitForChild("Prestiege"))
local World = require(Data:WaitForChild("World"))
local CratesData = require(Data:WaitForChild("Crates"))
local SummonConfig = require(Data:WaitForChild("SummonConfig"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local WeaponAttack = Remotes:WaitForChild("WeaponAttack")
local GetStats = Remotes:WaitForChild("GetStats")
local UnboxCrate = Remotes:WaitForChild("UnboxCrate")
local QueryInventory = Remotes:WaitForChild("QueryInventory")
local QueryInventoryState = Remotes:WaitForChild("QueryInventoryState")
local InventoryAction = Remotes:WaitForChild("InventoryAction")
local Events = ReplicatedStorage:WaitForChild("Events")
local CooldownStart = Events:WaitForChild("CooldownStart")
local QueryUpgradeCost = Remotes:WaitForChild("QueryUpgradeCost")
local TryUpgrade = Remotes:WaitForChild("TryUpgrade")
local Prestiege = Remotes:WaitForChild("Prestiege")
local ChangeLevel = Remotes:WaitForChild("ChangeLevel")
local QueryProgression = Remotes:WaitForChild("QueryProgression")
local UpdateSetting = Remotes:WaitForChild("UpdateSetting")
local ProgressionUpdateRemote = Remotes:WaitForChild("ProgressionUpdate")
local QueryDailyRewards = Remotes:WaitForChild("QueryDailyRewards")
local ClaimDailyReward = Remotes:WaitForChild("ClaimDailyReward")
local HeroSummon = Remotes:WaitForChild("HeroSummon")
local QueryBanner = Remotes:WaitForChild("QueryBanner")
local ToggleAutoDelete = Remotes:WaitForChild("ToggleAutoDelete")
local QueryAutoDelete = Remotes:WaitForChild("QueryAutoDelete")
local Drops = workspace:WaitForChild("Drops")

-- ===== Bypass Patch (client-side Weapons/Modifiers table manipulation) =====
local _bypassWeaponCache = {}
local _bypassModCache = {}

local function applyBypassPatch()
    -- Weapons: ใช้ field จริง "Multiplier" และ "Cooldown"
    for id, weapon in pairs(Weapons) do
        if type(weapon) ~= "table" then continue end
        if not _bypassWeaponCache[id] then
            _bypassWeaponCache[id] = {}
            for k, v in pairs(weapon) do _bypassWeaponCache[id][k] = v end
        end
        local orig = _bypassWeaponCache[id]
        -- Multiplier คือ field damage จริงใน Weapons table
        for _, f in ipairs({"Multiplier","BaseDamage","Damage","DamagePerHit","AttackDamage"}) do
            if type(orig[f]) == "number" then
                weapon[f] = getgenv().BypassDamage and 9e15 or orig[f]
            end
        end
        if type(orig.Cooldown) == "number" then
            weapon.Cooldown = getgenv().BypassAttackSpeed and 0.001 or orig.Cooldown
        end
    end
    -- Modifiers: Multipliers.Damage คือ field หลัก
    for id, mod in pairs(Modifiers) do
        if type(mod) ~= "table" or type(mod.Multipliers) ~= "table" then continue end
        if not _bypassModCache[id] then
            _bypassModCache[id] = {}
            for k, v in pairs(mod.Multipliers) do _bypassModCache[id][k] = v end
        end
        local orig = _bypassModCache[id]
        for _, f in ipairs({"Damage","DamageMultiplier","AttackMultiplier","DamageBonus","Health"}) do
            if type(orig[f]) == "number" and f ~= "Health" then
                mod.Multipliers[f] = getgenv().BypassDamage and (orig[f] * 1e12) or orig[f]
            end
        end
        if type(orig.Cooldown) == "number" then
            mod.Multipliers.Cooldown = getgenv().BypassAttackSpeed and 0.001 or orig.Cooldown
        end
    end
    -- FriendBoostMultiplier: server อ่าน attribute นี้เพื่อ multiply reward
    if getgenv().BypassDamage then
        pcall(function()
            LocalPlayer:SetAttribute("FriendBoostMultiplier", 999999)
            LocalPlayer:SetAttribute("FriendBoostCount", 999)
        end)
    end
end

getgenv().AutoAttackEnabled = getgenv().AutoAttackEnabled or false
getgenv().AttackSpeedMul = getgenv().AttackSpeedMul or 1
getgenv().NoCooldown = getgenv().NoCooldown or false
getgenv().AutoUpgradePlayerEnabled = getgenv().AutoUpgradePlayerEnabled or false
getgenv().AutoUpgradeHeroEnabled = getgenv().AutoUpgradeHeroEnabled or false
getgenv().AutoUpgradeMultiplier = getgenv().AutoUpgradeMultiplier or 0
getgenv().AutoPrestigeEnabled = getgenv().AutoPrestigeEnabled or false
getgenv().AutoUpgradeStats = getgenv().AutoUpgradeStats or {Hero = 0, Weapon = 0}
getgenv().FarmLoopEnabled = getgenv().FarmLoopEnabled or false
getgenv().SkipBossEnabled = getgenv().SkipBossEnabled or false
if getgenv().AntiAFKEnabled == nil then getgenv().AntiAFKEnabled = true end
if getgenv().AutoCollectCoins == nil then getgenv().AutoCollectCoins = true end
if getgenv().AutoOpenCrateEnabled == nil then getgenv().AutoOpenCrateEnabled = false end
getgenv().SelectedCrate = getgenv().SelectedCrate or "Wooden Crate"
getgenv().DeleteRarities_Weapon = getgenv().DeleteRarities_Weapon or {}
getgenv().DeleteRarities_Hero = getgenv().DeleteRarities_Hero or {}
getgenv().DeleteRarities_Relic = getgenv().DeleteRarities_Relic or {}
-- Auto Delete "Enable" toggles always start OFF on load, as a safety default --
-- deliberately NOT part of PERSIST_KEYS, see note above.
getgenv().DeleteEnabled_Weapon = false
getgenv().DeleteEnabled_Hero = false
getgenv().DeleteEnabled_Relic = false
getgenv().__DeleteStats = getgenv().__DeleteStats or {Weapon = 0, Hero = 0, Relic = 0}
getgenv().__SuppressAutoAttack = false
if getgenv().AutoClaimDailyEnabled == nil then getgenv().AutoClaimDailyEnabled = true end
getgenv().__DailyClaimCount = getgenv().__DailyClaimCount or 0
if getgenv().AutoSummonEnabled == nil then getgenv().AutoSummonEnabled = false end
getgenv().SummonAmount = getgenv().SummonAmount or 1
getgenv().__SummonCount = getgenv().__SummonCount or 0
getgenv().InfGold = getgenv().InfGold or false
getgenv().InfStardust = getgenv().InfStardust or false
getgenv().InfPlayPoints = getgenv().InfPlayPoints or false
getgenv().BypassDamage = getgenv().BypassDamage or false
getgenv().BypassAttackSpeed = getgenv().BypassAttackSpeed or false

if not getgenv().FarmLoopBiome then
    local ok, prog = pcall(function() return QueryProgression:InvokeServer() end)
    if ok and prog and prog.Current then
        getgenv().FarmLoopBiome = prog.Current:match("^(.-)%s+%a+$") or World.BiomeOrder[1]
        getgenv().FarmLoopLevelId = prog.Current
    else
        getgenv().FarmLoopBiome = World.BiomeOrder[1]
        getgenv().FarmLoopLevelId = World.Biomes[World.BiomeOrder[1]].LevelOrder[1]
    end
end

local function formatNumber(n)
    n = n or 0
    local neg = n < 0
    n = math.abs(n)
    local suffixes = {"", "K", "M", "B", "T", "Qa", "Qi", "Sx"}
    local i = 1
    while n >= 1000 and i < #suffixes do
        n = n / 1000
        i += 1
    end
    return (neg and "-" or "") .. string.format("%.2f", n) .. suffixes[i]
end

local function formatDuration(seconds)
    if seconds <= 0 then return "now" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then return string.format("%dh %dm %ds", h, m, s) end
    if m > 0 then return string.format("%dm %ds", m, s) end
    return string.format("%ds", s)
end

-- ===== Anti-AFK =====
LocalPlayer.Idled:Connect(function()
    if not getgenv().AntiAFKEnabled then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

-- ===== Auto Collect Coins =====
-- Currency is already granted server-side the instant an enemy dies (verified by
-- watching the Coins leaderstat update independently of any pickup animation) --
-- the dropped coin is purely visual. The game's own MagnetSystem module recomputes
-- each coin's CFrame every frame from coordinates captured at spawn time, so trying
-- to tween/teleport the coin toward the player gets silently overwritten in the same
-- frame. Simplest reliable "auto collect": just clear the drop instantly since the
-- money's already yours either way.
RunService.Heartbeat:Connect(function()
    if getgenv().__AutomationGen ~= myGen then return end
    if not getgenv().AutoCollectCoins then return end
    for _, part in ipairs(Drops:GetChildren()) do
        if part:IsA("BasePart") then
            pcall(function() part:Destroy() end)
        end
    end
end)

-- ===== Auto Attack (mirrors the game's own InputHandler swing logic) =====
local handler = nil
local function refreshHandler(character)
    if character then
        local ok, h = pcall(function() return CharacterHandler:Wait(character) end)
        if ok then handler = h end
    end
end
refreshHandler(LocalPlayer.Character)
LocalPlayer.CharacterAdded:Connect(refreshHandler)

-- Animation/sound are throttled independently of the actual attack rate --
-- firing the swing FX every single hit at 60/s just resets the animation each
-- frame and reads as the character being stuck, not attacking fast.
local lastFxTime = 0
local FX_MIN_INTERVAL = 0.15
local function tryPlayFx(weapon)
    local now = os.clock()
    if now - lastFxTime < FX_MIN_INTERVAL then return end
    lastFxTime = now
    if handler then
        pcall(function()
            CharacterHandler:AnimateSequence(handler, weapon.SwingAnimations)
            CharacterHandler:PlaySoundSequence(handler, weapon.SwingSounds)
        end)
    end
end

-- NOTE: verified live that the server enforces its own fixed per-weapon cooldown
-- no matter how fast/slow WeaponAttack:FireServer() is called -- burst-firing
-- 1200+ times in ~1.4s only produced ~2 real hits (matching the natural 0.6s
-- cooldown), and a controlled 3s A/B of NoCooldown vs x1 vs x100 produced
-- identical damage. So Attack Speed / No Cooldown cannot increase real damage;
-- they only guarantee we never sit idle past the moment the server would allow
-- the next hit -- firing every Heartbeat frame achieves that with zero missed
-- windows, which is all NoCooldown actually buys you.
local function doSwing()
    local character = LocalPlayer.Character
    if not character then return end
    local tool = character:FindFirstChildOfClass("Tool")
    if not (tool and tool:GetAttribute("WeaponId") and tool:GetAttribute("ModifierId")) then return end
    local weapon = Weapons[tool:GetAttribute("WeaponId")]
    if not weapon then return end
    local modifier = Modifiers[tool:GetAttribute("ModifierId")]
    if not modifier then return end

    if getgenv().NoCooldown or getgenv().BypassAttackSpeed then
        tryPlayFx(weapon)
        WeaponAttack:FireServer()
        return
    end

    local mul = math.clamp(getgenv().AttackSpeedMul or 1, 1, 100)
    local cd = (weapon.Cooldown * modifier.Multipliers.Cooldown + 0.1) / mul
    if Mutex:Lock(LocalPlayer, "Mouse1Down", cd) then
        tryPlayFx(weapon)
        CooldownStart:Fire(cd)
        WeaponAttack:FireServer()
    end
end

task.spawn(function()
    while getgenv().__AutomationGen == myGen do
        applyBypassPatch()
        if getgenv().AutoAttackEnabled and not getgenv().__SuppressAutoAttack then doSwing() end
        task.wait((getgenv().NoCooldown or getgenv().BypassAttackSpeed) and 0 or 0.05)
    end
end)

-- ===== Auto Upgrade (Player weapon level / Hero level) =====
local function getPlotId()
    return LocalPlayer:GetAttribute("PlotId")
end

-- IMPORTANT: verified live that the server silently drops a "Weapon" TryUpgrade
-- request if WeaponAttack keeps firing at (or near) the same moment -- Auto
-- Attack + Auto Upgrade(Player) running together meant Weapon purchases almost
-- never landed while Hero purchases (no such conflict) always did, which is
-- why it looked like "only one type buys at a time". Fix: briefly pause Auto
-- Attack around the Weapon TryUpgrade call so it can never collide.
local function tryBuy(category, enabledFlag, onBought)
    if not getgenv()[enabledFlag] then return end
    local plotId = getPlotId()
    if not plotId then return end
    local mult = getgenv().AutoUpgradeMultiplier or 0
    local ok, cost, count = pcall(function()
        return QueryUpgradeCost:InvokeServer(category, mult)
    end)
    if not ok or not cost or cost <= 0 or not count or count <= 0 then return end
    local coins = LocalPlayer.leaderstats.Coins.Value
    if coins >= cost then
        if category == "Weapon" then
            getgenv().__SuppressAutoAttack = true
            TryUpgrade:FireServer(plotId, category, mult)
            task.delay(0.4, function() getgenv().__SuppressAutoAttack = false end)
        else
            TryUpgrade:FireServer(plotId, category, mult)
        end
        getgenv().AutoUpgradeStats[category] += count
        if onBought then onBought() end
    end
end

-- ===== Auto Prestige =====
local function tryPrestige()
    if not getgenv().AutoPrestigeEnabled then return end
    local rebirths = (LocalPlayer:FindFirstChild("leaderstats") and LocalPlayer.leaderstats:FindFirstChild("Rebirths"))
    local currentTier = rebirths and rebirths.Value or 0
    local nextTier = PrestiegeData.Data[currentTier + 1]
    if not nextTier then return end
    local coins = LocalPlayer.leaderstats.Coins.Value
    if coins >= nextTier.Cost then
        Prestiege:FireServer()
    end
end

-- ===== Auto Open Crates (dropdown-selected crate, spends PlayPoints) =====
local function tryOpenCrates(onBought)
    if not getgenv().AutoOpenCrateEnabled then return end
    local crateId = getgenv().SelectedCrate
    local crateInfo = CratesData[crateId]
    if not crateInfo then return end
    local cost = crateInfo.Cost
    local playPoints = LocalPlayer:GetAttribute("PlayPoints") or 0
    local iterations = 0
    while playPoints >= cost and iterations < 50 do
        UnboxCrate:FireServer(crateId)
        playPoints -= cost
        iterations += 1
        if onBought then onBought(crateId) end
    end
end

-- ===== Auto Claim Daily =====
local function tryClaimDaily(onStatus)
    if not getgenv().AutoClaimDailyEnabled then return end
    local ok, data = pcall(function() return QueryDailyRewards:InvokeServer() end)
    if not ok or type(data) ~= "table" then return end
    if data.CanClaim then
        local okC, result = pcall(function() return ClaimDailyReward:InvokeServer() end)
        if okC and result then
            getgenv().__DailyClaimCount += 1
        end
    end
    if onStatus then
        if data.CanClaim then
            onStatus(string.format("Ready to claim! (Day %s)", tostring(data.CurrentDay)))
        else
            local remaining = (data.NextClaimTime or 0) - os.time()
            onStatus(string.format("Day %s claimed. Next in %s", tostring(data.CurrentDay), formatDuration(remaining)))
        end
    end
end

-- ===== Auto Summon (Hero gacha) =====
-- HeroSummon:InvokeServer(count) processes server-side immediately -- the in-game
-- UI's proximity check only gates whether the pull *animation* shows, not whether
-- the summon itself happens, so this works from anywhere. Client has its own 1s
-- Mutex-style cooldown on "HeroSummon" (mirrored here via lastSummonAt) on top of
-- whatever the server enforces.
local lastSummonAt = 0
local function tryAutoSummon(onStatus)
    if not getgenv().AutoSummonEnabled then return end
    if os.clock() - lastSummonAt < 1.1 then return end
    local count = getgenv().SummonAmount or 1
    local cost = (count == 10) and SummonConfig.MultiPullCost or SummonConfig.PullCost
    local stardust = LocalPlayer:GetAttribute("Stardust") or 0
    if stardust < cost then
        if onStatus then onStatus(string.format("Need %d Stardust (have %s)", cost, formatNumber(stardust))) end
        return
    end
    lastSummonAt = os.clock()
    local ok, results = pcall(function() return HeroSummon:InvokeServer(count) end)
    if ok and type(results) == "table" then
        getgenv().__SummonCount += #results
    end
    if onStatus then onStatus("Summoned so far: " .. tostring(getgenv().__SummonCount)) end
end

-- Auto Delete for summon results (Rare/Epic/Legendary only -- Mythic/Secret are
-- never offered, matching the game's own in-shop AutoDeleteButtons). This is the
-- game's own per-rarity future-drops setting (ToggleAutoDelete), same one the
-- native Heroes shop UI uses -- just flipped directly, no polling loop needed.
local function setSummonAutoDelete(rarity, value)
    pcall(function() ToggleAutoDelete:FireServer("Hero", rarity, value) end)
end

local function queryCurrentSummonAutoDelete()
    local ok, state = pcall(function() return QueryAutoDelete:InvokeServer("Hero") end)
    return (ok and type(state) == "table") and state or {}
end

local function refreshBannerLabel(label)
    local ok, banner = pcall(function() return QueryBanner:InvokeServer() end)
    if not ok or type(banner) ~= "table" then return end
    local mythics = table.concat(banner.FeaturedMythics or {}, ", ")
    local legendaries = table.concat(banner.FeaturedLegendaries or {}, ", ")
    if mythics == "" then mythics = "-" end
    if legendaries == "" then legendaries = "-" end
    local remaining = (banner.ExpiresAt or 0) - os.time()
    pcall(function()
        label:UpdateName(string.format("Mythic: %s\nLegendary: %s\nNext banner: %s", mythics, legendaries, formatDuration(remaining)))
    end)
end

-- ===== Farm Loop + Skip Boss =====
-- Loop pins the character to one Map/Level by disabling the game's own "AutoAdvance"
-- setting and re-firing ChangeLevel whenever the server moves you off it.
-- Skip Boss additionally turns off the game's native "Auto Boss" toggle and, the
-- instant a boss becomes available, re-enters the level to reset back to the first
-- monster instead of fighting it.
local function setAutoAdvance(value)
    pcall(function()
        LocalPlayer:SetAttribute("AutoAdvance", value)
        UpdateSetting:FireServer("AutoAdvance", value)
    end)
end

-- IMPORTANT: always leaves native Auto Boss back ON when Loop/Skip Boss are turned
-- off, otherwise normal progression silently stalls waiting for a boss no one triggers.
local function setNativeAutoBoss(shouldBeOn)
    pcall(function()
        local gui = LocalPlayer.PlayerGui:FindFirstChild("FullScreen")
        gui = gui and gui:FindFirstChild("ProgressionGui")
        gui = gui and gui:FindFirstChild("MainFrame")
        local autoBossBtn = gui and gui:FindFirstChild("AutoBoss")
        local label = autoBossBtn and autoBossBtn:FindFirstChild("BiomeLabel")
        if not (autoBossBtn and label) then return end
        local isOn = label.Text:find("ON") ~= nil
        if isOn ~= shouldBeOn then
            local fired = false
            pcall(function()
                for _, conn in ipairs(getconnections(autoBossBtn.MouseButton1Click)) do
                    conn:Fire()
                    fired = true
                end
            end)
            if not fired then
                pcall(function() autoBossBtn.MouseButton1Click:Fire() end)
            end
        end
    end)
end

-- Single place that (re)applies Loop/Skip Boss state to the game's own
-- AutoAdvance/Auto Boss settings -- used by the Loop toggle AND by the
-- post-Prestige resync below, so both paths can never fall out of sync.
local function applyFarmStateNow()
    if getgenv().FarmLoopEnabled then
        setAutoAdvance(false)
        pcall(function() ChangeLevel:FireServer(getgenv().FarmLoopLevelId) end)
        setNativeAutoBoss(not getgenv().SkipBossEnabled)
    else
        setAutoAdvance(true)
        setNativeAutoBoss(true)
    end
end

local function tryFarmLoop(onStatus)
    if not getgenv().FarmLoopEnabled then return end
    local targetId = getgenv().FarmLoopLevelId
    if not targetId then return end
    local ok, prog = pcall(function() return QueryProgression:InvokeServer() end)
    if not ok or not prog then return end
    if not (prog.Unlocked and prog.Unlocked[targetId]) then
        if onStatus then onStatus("Locked: " .. targetId .. " (current: " .. tostring(prog.Current) .. ")") end
        return
    end
    if prog.Current ~= targetId then
        ChangeLevel:FireServer(targetId)
    end
    if onStatus then onStatus("Current: " .. tostring(prog.Current)) end
end

-- Extra listener alongside the game's own ProgressionUpdate handler (doesn't
-- replace it) -- resets to the first monster the instant a boss is available.
if not getgenv().__ProgressionHooked then
    getgenv().__ProgressionHooked = true
    ProgressionUpdateRemote.OnClientEvent:Connect(function(data)
        if not (getgenv().FarmLoopEnabled and getgenv().SkipBossEnabled) then return end
        if type(data) ~= "table" then return end
        if data.BossAvailable and data.EnemyKilled then
            pcall(function()
                ChangeLevel:FireServer(data.LevelId or getgenv().FarmLoopLevelId)
            end)
        end
    end)
end

-- Rebirth (Prestige) resets the server's own progression/AutoAdvance/AutoBoss
-- state, which silently undoes whatever Loop/Skip Boss had set up -- previously
-- this required manually re-toggling Loop/Skip Boss off and on after every
-- prestige to "unstick" it. Now: re-apply our farm state automatically the
-- instant the Rebirths stat actually changes (covers Auto Prestige AND manual
-- prestige), no user action needed.
if not getgenv().__RebirthHooked then
    getgenv().__RebirthHooked = true
    task.spawn(function()
        local ls = LocalPlayer:WaitForChild("leaderstats")
        local rebirthsStat = ls:WaitForChild("Rebirths")
        rebirthsStat.Changed:Connect(function()
            task.wait(1)
            applyFarmStateNow()
        end)
    end)
end

-- Apply persisted Farm Loop / Auto Attack state to the actual game immediately
-- on load (not just wait for the background loop's next pass), so a rejoin with
-- Loop saved ON resumes the correct AutoAdvance/AutoBoss config right away.
applyFarmStateNow()

-- ===== Auto Delete (from live inventory, not just future drops) =====
-- The game's own ToggleAutoDelete setting only affects items obtained AFTER it's
-- enabled -- it won't touch what's already in your bag. Since the end result is
-- the same either way (item ends up gone), this instead scans the real inventory
-- via QueryInventory and bulk-deletes matching items via InventoryAction
-- "MultiDelete", so existing items get cleared out too, not just future ones.
--
-- SAFETY: the game has a real per-item Lock feature (InventoryHandler's Lock
-- button -> InventoryAction:FireServer("Lock", uniqueId)), and there is NO
-- server-side protection against auto-deleting a locked or currently-equipped
-- item -- it is entirely on the caller to check. This queries
-- QueryInventoryState:InvokeServer("Locked") and ("Equipped") every pass and
-- excludes any UniqueId present in either set before building the delete list.
local function tryDeleteInventory(category, rarityKey, enabledFlag, onDeleted)
    if not getgenv()[enabledFlag] then return end
    local rarities = getgenv()[rarityKey]
    if not rarities or #rarities == 0 then return end
    local raritySet = {}
    for _, r in ipairs(rarities) do raritySet[r] = true end

    local okItems, items = pcall(function() return QueryInventory:InvokeServer(category) end)
    if not okItems or type(items) ~= "table" then return end

    local okLocked, locked = pcall(function() return QueryInventoryState:InvokeServer("Locked") end)
    locked = (okLocked and type(locked) == "table") and locked or {}
    local okEquipped, equipped = pcall(function() return QueryInventoryState:InvokeServer("Equipped") end)
    equipped = (okEquipped and type(equipped) == "table") and equipped or {}

    local ids = {}
    for _, item in ipairs(items) do
        if raritySet[item.Rarity] and not locked[item.UniqueId] and not equipped[item.UniqueId] then
            table.insert(ids, item.UniqueId)
        end
    end
    if #ids > 0 then
        pcall(function() InventoryAction:FireServer("MultiDelete", ids) end)
        getgenv().__DeleteStats[category] += #ids
        if onDeleted then onDeleted(#ids) end
    end
end

-- ===== UI (Maclib) =====
local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()

local Window = MacLib:Window({
    Title = "Idle Slayers Automation",
    Subtitle = "by Claude",
    DragStyle = 1,
    ShowUserInfo = true,
    AcrylicBlur = false, -- keep the game screen sharp, no blur behind the UI
})

-- Tab icons use Roblox's Lucide icon pack (rbxassetid images, max 16x16), the
-- same asset set Fluent/Maclib both reference -- verified against
-- dawid-scripts/Fluent's src/Icons.lua generated file.
local TabGroup = Window:TabGroup()
local Tabs = {
    Combat = TabGroup:Tab({Name = "Combat", Image = "rbxassetid://10734975692"}),   -- lucide-swords
    Economy = TabGroup:Tab({Name = "Economy", Image = "rbxassetid://10709811110"}), -- lucide-coins
    Summon = TabGroup:Tab({Name = "Summon", Image = "rbxassetid://10723396000"}),   -- lucide-gem
    Farm = TabGroup:Tab({Name = "Farm", Image = "rbxassetid://10734886202"}),       -- lucide-map
    Delete = TabGroup:Tab({Name = "Delete", Image = "rbxassetid://10747362241"}),   -- lucide-trash-2
    Misc = TabGroup:Tab({Name = "Misc", Image = "rbxassetid://10734963191"}),       -- lucide-sliders-horizontal
    Settings = TabGroup:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}), -- lucide-settings
    Bypass = TabGroup:Tab({Name = "Bypass", Image = "rbxassetid://10723397078"}),     -- lucide-zap
}

-- ----- Combat: Left = controls, Right = Damage Test -----
local CombatSection = Tabs.Combat:Section({Side = "Left"})
CombatSection:Toggle({
    Name = "Auto Attack",
    Default = getgenv().AutoAttackEnabled,
    Callback = function(value) getgenv().AutoAttackEnabled = value; saveState() end,
}, "AutoAttackEnabled")
CombatSection:Slider({
    Name = "Attack Speed",
    Default = math.min(getgenv().AttackSpeedMul or 1, 100),
    Minimum = 1, Maximum = 100, DisplayMethod = "Value", Precision = 0,
    Callback = function(value) getgenv().AttackSpeedMul = value; saveState() end,
}, "AttackSpeedMul")
CombatSection:Toggle({
    Name = "No Cooldown",
    Default = getgenv().NoCooldown,
    Callback = function(value) getgenv().NoCooldown = value; saveState() end,
}, "NoCooldownEnabled")
CombatSection:Label({Text = "Note: server caps real hit rate; speed/no-cd only avoid missing windows"})

-- ----- Combat: Damage Test tool -----
-- Measures real damage dealt (via GetStats) over a chosen window, with a live
-- running total while it counts down, then a final Total/DPS breakdown you can copy.
local TestSection = Tabs.Combat:Section({Side = "Right"})
local testRunning = false
local testResultText = "No test run yet."

local testStatusLabel = TestSection:Label({Text = "Idle"})

local durationInput = TestSection:Input({
    Name = "Duration (s)",
    Placeholder = "10",
    AcceptedCharacters = "Numeric",
    Callback = function() end,
}, "TestDurationInput")

local startBtn
local function runDamageTest()
    if testRunning then return end
    local durationStr = (durationInput.Text and durationInput.Text ~= "") and durationInput.Text or "10"
    local duration = tonumber(durationStr) or 10
    duration = math.clamp(duration, 1, 300)

    testRunning = true
    pcall(function() startBtn:UpdateName("Running...") end)

    local ok1, stats1 = pcall(function() return GetStats:InvokeServer() end)
    if not (ok1 and stats1) then
        pcall(function() testStatusLabel:UpdateName("Failed to read stats") end)
        pcall(function() startBtn:UpdateName("Start Test") end)
        testRunning = false
        return
    end
    local baseTotal = stats1.TotalDamage or 0
    local baseWeapon = stats1.TotalWeaponDamage or 0
    local baseHero = stats1.TotalHeroDamage or 0

    local elapsed = 0
    while elapsed < duration and testRunning do
        task.wait(1)
        elapsed += 1
        local ok2, stats2 = pcall(function() return GetStats:InvokeServer() end)
        if ok2 and stats2 then
            local delta = (stats2.TotalDamage or 0) - baseTotal
            pcall(function()
                testStatusLabel:UpdateName(string.format("Testing... %ds left | Dmg so far: %s", duration - elapsed, formatNumber(delta)))
            end)
        end
    end

    local ok3, stats3 = pcall(function() return GetStats:InvokeServer() end)
    local finalTotal = (ok3 and stats3 and stats3.TotalDamage) or baseTotal
    local finalWeapon = (ok3 and stats3 and stats3.TotalWeaponDamage) or baseWeapon
    local finalHero = (ok3 and stats3 and stats3.TotalHeroDamage) or baseHero

    local totalDmg = finalTotal - baseTotal
    local weaponDmg = finalWeapon - baseWeapon
    local heroDmg = finalHero - baseHero
    local dps = totalDmg / duration

    testResultText = string.format(
        "Damage Test (%ds)\nTotal: %s (%d)\nWeapon: %s | Hero: %s\nDPS: %s (%.1f)",
        duration, formatNumber(totalDmg), totalDmg, formatNumber(weaponDmg), formatNumber(heroDmg), formatNumber(dps), dps
    )

    pcall(function()
        testStatusLabel:UpdateName(string.format("Done! Total: %s | DPS: %s", formatNumber(totalDmg), formatNumber(dps)))
    end)
    pcall(function() startBtn:UpdateName("Start Test") end)
    testRunning = false
end

startBtn = TestSection:Button({
    Name = "Start Test",
    Callback = function() task.spawn(runDamageTest) end,
})

TestSection:Button({
    Name = "Reset",
    Callback = function()
        testRunning = false
        testResultText = "No test run yet."
        pcall(function() testStatusLabel:UpdateName("Idle") end)
        pcall(function() startBtn:UpdateName("Start Test") end)
    end,
})

TestSection:Button({
    Name = "Copy Result",
    Callback = function()
        pcall(function() setclipboard(testResultText) end)
        pcall(function() testStatusLabel:UpdateName("Copied to clipboard!") end)
        task.delay(1.5, function()
            if not testRunning then
                pcall(function() testStatusLabel:UpdateName("Idle") end)
            end
        end)
    end,
})

-- ----- Economy: Auto Upgrade card, Auto Open Crates card, Prestige + Daily on the right -----
local EconLeft = Tabs.Economy:Section({Side = "Left"})
EconLeft:Header({Text = "Auto Upgrade"})
EconLeft:Toggle({
    Name = "Player",
    Default = getgenv().AutoUpgradePlayerEnabled,
    Callback = function(value) getgenv().AutoUpgradePlayerEnabled = value; saveState() end,
}, "AutoUpgradePlayerEnabled")
EconLeft:Toggle({
    Name = "Hero",
    Default = getgenv().AutoUpgradeHeroEnabled,
    Callback = function(value) getgenv().AutoUpgradeHeroEnabled = value; saveState() end,
}, "AutoUpgradeHeroEnabled")

local multMap = {["x1"] = 1, ["x10"] = 10, ["x100"] = 100, ["MAX"] = 0}
local multMapRev = {[1] = "x1", [10] = "x10", [100] = "x100", [0] = "MAX"}
local amountOptions = {"x1", "x10", "x100", "MAX"}
local amountDropdown = EconLeft:Dropdown({
    Name = "Amount",
    Options = amountOptions,
    Callback = function(value) getgenv().AutoUpgradeMultiplier = multMap[value] or 0; saveState() end,
}, "UpgradeMultiplier")
local amountTarget = multMapRev[getgenv().AutoUpgradeMultiplier or 0] or "MAX"
amountDropdown:UpdateSelection(amountTarget)
registerDropdownSync(amountDropdown, amountTarget)

EconLeft:Toggle({
    Name = "Auto Collect Coins",
    Default = getgenv().AutoCollectCoins,
    Callback = function(value) getgenv().AutoCollectCoins = value; saveState() end,
}, "AutoCollectCoins")

-- Dropdown to pick the crate, single toggle to auto-open whichever is selected.
-- Display labels show the PlayPoints cost and use "Steel" as the display name for
-- what the game's own data calls "Iron Crate" -- map back to the real id on select.
local CrateSection = Tabs.Economy:Section({Side = "Left"})
CrateSection:Header({Text = "Auto Open Crates"})
local crateDisplayToId = {
    ["Wooden Crate (5P)"] = "Wooden Crate",
    ["Spiked Crate (10P)"] = "Spiked Crate",
    ["Steel Crate (15P)"] = "Iron Crate",
}
local crateIdToDisplay = {
    ["Wooden Crate"] = "Wooden Crate (5P)",
    ["Spiked Crate"] = "Spiked Crate (10P)",
    ["Iron Crate"] = "Steel Crate (15P)",
}
local crateOptions = {"Wooden Crate (5P)", "Spiked Crate (10P)", "Steel Crate (15P)"}
local crateDropdown = CrateSection:Dropdown({
    Name = "Crate",
    Options = crateOptions,
    Callback = function(value) getgenv().SelectedCrate = crateDisplayToId[value] or "Wooden Crate"; saveState() end,
}, "SelectedCrate")
local crateTarget = crateIdToDisplay[getgenv().SelectedCrate] or "Wooden Crate (5P)"
crateDropdown:UpdateSelection(crateTarget)
registerDropdownSync(crateDropdown, crateTarget)
CrateSection:Toggle({
    Name = "Open Chest",
    Default = getgenv().AutoOpenCrateEnabled,
    Callback = function(value) getgenv().AutoOpenCrateEnabled = value; saveState() end,
}, "AutoOpenCrateEnabled")
local crateStatusLabel = CrateSection:Label({Text = "Crates opened: 0"})

local EconRight = Tabs.Economy:Section({Side = "Right"})
local upgradeStatusLabel = EconRight:Label({Text = string.format("Bought: Player +%d | Hero +%d", getgenv().AutoUpgradeStats.Weapon, getgenv().AutoUpgradeStats.Hero)})
EconRight:Toggle({
    Name = "Auto Prestige",
    Default = getgenv().AutoPrestigeEnabled,
    Callback = function(value) getgenv().AutoPrestigeEnabled = value; saveState() end,
}, "AutoPrestigeEnabled")

local DailySection = Tabs.Economy:Section({Side = "Right"})
DailySection:Header({Text = "Daily Reward"})
DailySection:Toggle({
    Name = "Auto Claim Daily",
    Default = getgenv().AutoClaimDailyEnabled,
    Callback = function(value) getgenv().AutoClaimDailyEnabled = value; saveState() end,
}, "AutoClaimDailyEnabled")
local dailyStatusLabel = DailySection:Label({Text = "Checking..."})

-- ----- Summon -----
local SummonLeft = Tabs.Summon:Section({Side = "Left"})
SummonLeft:Header({Text = "Auto Summon"})
SummonLeft:Toggle({
    Name = "Auto Summon",
    Default = getgenv().AutoSummonEnabled,
    Callback = function(value) getgenv().AutoSummonEnabled = value; saveState() end,
}, "AutoSummonEnabled")
local summonAmountRev = {[1] = "x1", [10] = "x10"}
local summonAmountOptions = {"x1", "x10"}
local summonAmountDropdown = SummonLeft:Dropdown({
    Name = "Amount",
    Options = summonAmountOptions,
    Callback = function(value) getgenv().SummonAmount = (value == "x10") and 10 or 1; saveState() end,
}, "SummonAmount")
local summonAmountTarget = summonAmountRev[getgenv().SummonAmount] or "x1"
summonAmountDropdown:UpdateSelection(summonAmountTarget)
registerDropdownSync(summonAmountDropdown, summonAmountTarget)
local summonStatusLabel = SummonLeft:Label({Text = string.format("Summoned so far: %d", getgenv().__SummonCount)})

-- Rare/Epic/Legendary only -- matches the game's own in-shop AutoDeleteButtons
-- (Mythic/Secret are never offered there since those should never be auto-tossed).
local summonRarities = {"Rare", "Epic", "Legendary"}
local currentSummonAutoDelete = queryCurrentSummonAutoDelete()
SummonLeft:Header({Text = "Auto Delete Summon Results"})
for _, rarity in ipairs(summonRarities) do
    SummonLeft:Toggle({
        Name = rarity,
        Default = currentSummonAutoDelete[rarity] or false,
        Callback = function(value) setSummonAutoDelete(rarity, value) end,
    }, "SummonAutoDelete_" .. rarity)
end

local SummonRight = Tabs.Summon:Section({Side = "Right"})
SummonRight:Header({Text = "Current Banner"})
local bannerLabel = SummonRight:Label({Text = "Loading..."})

-- ----- Farm -----
local FarmLeft = Tabs.Farm:Section({Side = "Left"})

local levelDropdown
local function refreshLevelOptions(biome, selectValue)
    local levels = World.Biomes[biome] and World.Biomes[biome].LevelOrder or {}
    if levelDropdown then
        pcall(function() levelDropdown:ClearOptions() end)
        pcall(function() levelDropdown:InsertOptions(levels) end)
        pcall(function() levelDropdown:UpdateSelection(selectValue or levels[1]) end)
    end
    return levels
end

local mapDropdown = FarmLeft:Dropdown({
    Name = "Map",
    Options = World.BiomeOrder,
    Callback = function(value)
        getgenv().FarmLoopBiome = value
        local levels = World.Biomes[value] and World.Biomes[value].LevelOrder or {}
        getgenv().FarmLoopLevelId = levels[1]
        refreshLevelOptions(value, levels[1])
        saveState()
    end,
}, "FarmMap")
mapDropdown:UpdateSelection(getgenv().FarmLoopBiome)
registerDropdownSync(mapDropdown, getgenv().FarmLoopBiome)

local initialLevels = World.Biomes[getgenv().FarmLoopBiome] and World.Biomes[getgenv().FarmLoopBiome].LevelOrder or {}
levelDropdown = FarmLeft:Dropdown({
    Name = "Level",
    Options = initialLevels,
    Callback = function(value) getgenv().FarmLoopLevelId = value; saveState() end,
}, "FarmLevel")
levelDropdown:UpdateSelection(getgenv().FarmLoopLevelId)
registerDropdownSync(levelDropdown, getgenv().FarmLoopLevelId)

FarmLeft:Toggle({
    Name = "Loop",
    Default = getgenv().FarmLoopEnabled,
    Callback = function(value)
        getgenv().FarmLoopEnabled = value
        applyFarmStateNow()
        saveState()
    end,
}, "FarmLoopEnabled")

FarmLeft:Toggle({
    Name = "Skip Boss",
    Default = getgenv().SkipBossEnabled,
    Callback = function(value)
        getgenv().SkipBossEnabled = value
        if getgenv().FarmLoopEnabled then setNativeAutoBoss(not value) end
        saveState()
    end,
}, "SkipBossEnabled")

local farmStatusLabel = FarmLeft:Label({Text = "Idle"})

-- ----- Delete: multi-select Rarity + Enable per category. Deletes directly from
-- the live inventory (see tryDeleteInventory above) so it also clears items you
-- already own, not just future drops. Locked and currently-Equipped items are
-- always skipped. Always starts OFF/empty. -----
local rarityOrder = {"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret"}
local deleteStatusLabels = {}
local function buildDeleteSection(section, category, title, rarityKey, enabledKey)
    section:Header({Text = title})
    section:Dropdown({
        Name = "Rarities",
        Multi = true,
        Options = rarityOrder,
        Default = getgenv()[rarityKey],
        Callback = function(value)
            -- Defensive: Maclib's multi-dropdown callback shape isn't documented
            -- precisely, so accept either {[rarity]=true} or {[i]=rarity}.
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
            for _, rarity in ipairs(rarityOrder) do
                if selectedSet[rarity] then table.insert(newList, rarity) end
            end
            getgenv()[rarityKey] = newList
            saveState()
        end,
    }, "DeleteRarities_" .. category)
    section:Toggle({
        Name = "Enable",
        Default = false,
        Callback = function(value) getgenv()[enabledKey] = value end,
    }, "DeleteEnable_" .. category)
    local label = section:Label({Text = "Deleted: 0 (locked & equipped are skipped)"})
    deleteStatusLabels[category] = label
end

local WeaponDeleteSection = Tabs.Delete:Section({Side = "Left"})
buildDeleteSection(WeaponDeleteSection, "Weapon", "Weapons", "DeleteRarities_Weapon", "DeleteEnabled_Weapon")

local HeroDeleteSection = Tabs.Delete:Section({Side = "Right"})
buildDeleteSection(HeroDeleteSection, "Hero", "Heroes", "DeleteRarities_Hero", "DeleteEnabled_Hero")

local RelicDeleteSection = Tabs.Delete:Section({Side = "Right"})
buildDeleteSection(RelicDeleteSection, "Relic", "Relics", "DeleteRarities_Relic", "DeleteEnabled_Relic")

-- ----- Misc -----
local MiscSection = Tabs.Misc:Section({Side = "Left"})
MiscSection:Toggle({
    Name = "Anti-AFK",
    Default = getgenv().AntiAFKEnabled,
    Callback = function(value) getgenv().AntiAFKEnabled = value; saveState() end,
}, "AntiAFKEnabled")
MiscSection:Keybind({
    Name = "Show/Hide UI",
    Blacklist = false,
    Default = Enum.KeyCode.RightShift,
    Callback = function()
        pcall(function() Window:SetState(not Window:GetState()) end)
    end,
}, "ToggleUIKeybind")

-- ----- Settings: now just shows auto-save status, no manual Save/Load needed -----
local SettingsSection = Tabs.Settings:Section({Side = "Left"})
SettingsSection:Header({Text = "Auto Save"})
SettingsSection:Label({Text = "All toggles/settings save automatically to:\n" .. SAVE_FILE})
SettingsSection:Label({Text = "Delete 'Enable' toggles are the one exception -- they always start OFF for safety."})
SettingsSection:Label({Text = "Note: dropdown button text can occasionally show blank due to a Maclib\nlibrary rendering bug -- the status label below each dropdown always\nshows the real current value regardless."})

-- ----- Bypass Tab -----
local BypassLeft = Tabs.Bypass:Section({Side = "Left"})
BypassLeft:Header({Text = "Infinite Currency"})
BypassLeft:Toggle({
    Name = "Inf Gold (Coins)",
    Default = getgenv().InfGold,
    Callback = function(value) getgenv().InfGold = value; saveState() end,
}, "InfGold")
BypassLeft:Toggle({
    Name = "Inf Stardust",
    Default = getgenv().InfStardust,
    Callback = function(value) getgenv().InfStardust = value; saveState() end,
}, "InfStardust")
BypassLeft:Toggle({
    Name = "Inf Player Points",
    Default = getgenv().InfPlayPoints,
    Callback = function(value) getgenv().InfPlayPoints = value; saveState() end,
}, "InfPlayPoints")
BypassLeft:Label({Text = "Sets currency attributes to max client-side.\nEnables Auto Upgrade / Crates / Summon to always fire."})

local BypassRight = Tabs.Bypass:Section({Side = "Right"})
BypassRight:Header({Text = "Combat Bypass"})
BypassRight:Toggle({
    Name = "Bypass Damage",
    Default = getgenv().BypassDamage,
    Callback = function(value)
        getgenv().BypassDamage = value
        applyBypassPatch()
        saveState()
    end,
}, "BypassDamage")
BypassRight:Toggle({
    Name = "Bypass Attack Speed",
    Default = getgenv().BypassAttackSpeed,
    Callback = function(value)
        getgenv().BypassAttackSpeed = value
        applyBypassPatch()
        saveState()
    end,
}, "BypassAttackSpeed")
BypassRight:Label({Text = "Modifies Weapons/Modifiers data tables.\nBypass Damage: inflates BaseDamage x1e12.\nBypass Speed: weapon.Cooldown → 0.001."})

-- ===== Resize grips (right edge, bottom edge, bottom-right corner) =====
-- Maclib has no built-in edge-resize, so this adds a small Fluent-style one.
local function findWindowFrame()
    for _, v in ipairs(game:GetDescendants()) do
        if v:IsA("TextLabel") and v.Text == "Idle Slayers Automation" then
            local cur = v.Parent
            while cur do
                if cur:IsA("Frame") and cur.Name == "Base" then
                    return cur
                end
                cur = cur.Parent
            end
        end
    end
    return nil
end

local baseFrame = findWindowFrame()
if baseFrame then
    local MIN_W, MIN_H = 500, 380
    local specs = {
        {name = "R",  anchor = Vector2.new(1, 0.5), pos = UDim2.new(1, 0, 0.5, 0), size = UDim2.new(0, 6, 1, -24), dx = 1, dy = 0},
        {name = "B",  anchor = Vector2.new(0.5, 1), pos = UDim2.new(0.5, 0, 1, 0), size = UDim2.new(1, -24, 0, 6), dx = 0, dy = 1},
        {name = "BR", anchor = Vector2.new(1, 1),   pos = UDim2.new(1, 0, 1, 0),   size = UDim2.fromOffset(16, 16), dx = 1, dy = 1},
    }
    for _, spec in ipairs(specs) do
        local grip = Instance.new("Frame")
        grip.Name = "ResizeGrip_" .. spec.name
        grip.AnchorPoint = spec.anchor
        grip.Position = spec.pos
        grip.Size = spec.size
        grip.BackgroundTransparency = 1
        grip.ZIndex = 100
        grip.Parent = baseFrame

        local dragging = false
        local startInput, startSize

        grip.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                startInput = input.Position
                local ok, sz = pcall(function() return Window:GetSize() end)
                startSize = ok and sz or UDim2.fromOffset(868, 650)
            end
        end)

        UserInputService.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                local delta = input.Position - startInput
                local newW = math.max(MIN_W, startSize.X.Offset + (spec.dx == 1 and delta.X or 0))
                local newH = math.max(MIN_H, startSize.Y.Offset + (spec.dy == 1 and delta.Y or 0))
                pcall(function() Window:SetSize(UDim2.fromOffset(newW, newH)) end)
            end
        end)

        UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
    end
end

-- ===== Background loops =====
-- Split into independent loops (instead of one shared sequential cycle) so
-- Auto Upgrade can run on its own fast 0.1s cadence without being held up by
-- (or forcing the pace of) heavier operations like Auto Delete, which does
-- several InvokeServer round-trips per category and stays on a slower cadence
-- to avoid spamming the server.
task.spawn(function()
    while getgenv().__AutomationGen == myGen do
        pcall(tryBuy, "Weapon", "AutoUpgradePlayerEnabled", function()
            pcall(function()
                upgradeStatusLabel:UpdateName(string.format("Bought: Player +%d | Hero +%d", getgenv().AutoUpgradeStats.Weapon, getgenv().AutoUpgradeStats.Hero))
            end)
        end)
        task.wait(0.1)
    end
end)
task.spawn(function()
    while getgenv().__AutomationGen == myGen do
        pcall(tryBuy, "Hero", "AutoUpgradeHeroEnabled", function()
            pcall(function()
                upgradeStatusLabel:UpdateName(string.format("Bought: Player +%d | Hero +%d", getgenv().AutoUpgradeStats.Weapon, getgenv().AutoUpgradeStats.Hero))
            end)
        end)
        task.wait(0.1)
    end
end)

getgenv().__CrateStats = getgenv().__CrateStats or {}
task.spawn(function()
    while getgenv().__AutomationGen == myGen do
        pcall(tryPrestige)
        task.wait(0.1)
        pcall(tryOpenCrates, function(crateId)
            getgenv().__CrateStats[crateId] = (getgenv().__CrateStats[crateId] or 0) + 1
            local total = 0
            for _, c in pairs(getgenv().__CrateStats) do total += c end
            pcall(function() crateStatusLabel:UpdateName("Crates opened: " .. total) end)
        end)
        task.wait(0.1)
        pcall(tryFarmLoop, function(text)
            pcall(function() farmStatusLabel:UpdateName(text) end)
        end)
        task.wait(0.1)
    end
end)

task.spawn(function()
    while getgenv().__AutomationGen == myGen do
        for _, category in ipairs({"Weapon", "Hero", "Relic"}) do
            pcall(tryDeleteInventory, category, "DeleteRarities_" .. category, "DeleteEnabled_" .. category, function()
                local lbl = deleteStatusLabels[category]
                if lbl then pcall(function() lbl:UpdateName("Deleted: " .. getgenv().__DeleteStats[category]) end) end
            end)
        end
        task.wait(2)
    end
end)

task.spawn(function()
    while getgenv().__AutomationGen == myGen do
        pcall(tryClaimDaily, function(text) pcall(function() dailyStatusLabel:UpdateName(text) end) end)
        task.wait(30)
    end
end)

task.spawn(function()
    while getgenv().__AutomationGen == myGen do
        pcall(tryAutoSummon, function(text) pcall(function() summonStatusLabel:UpdateName(text) end) end)
        task.wait(1)
    end
end)

task.spawn(function()
    while getgenv().__AutomationGen == myGen do
        pcall(refreshBannerLabel, bannerLabel)
        task.wait(5)
    end
end)

-- ===== Infinite Currency Loops =====
-- set ทั้ง leaderstat (UI display) และ attribute (ที่ auto-features อ่าน)
task.spawn(function()
    while getgenv().__AutomationGen == myGen do
        if getgenv().InfGold then
            pcall(function()
                local ls = LocalPlayer:FindFirstChild("leaderstats")
                if ls then
                    if ls:FindFirstChild("Coins") then ls.Coins.Value = 2^53 end
                end
                LocalPlayer:SetAttribute("Coins", 2^53)
            end)
        end
        if getgenv().InfStardust then
            pcall(function()
                local ls = LocalPlayer:FindFirstChild("leaderstats")
                if ls and ls:FindFirstChild("Stardust") then
                    ls.Stardust.Value = 2^53
                end
                LocalPlayer:SetAttribute("Stardust", 2^53)
            end)
        end
        if getgenv().InfPlayPoints then
            pcall(function()
                LocalPlayer:SetAttribute("PlayPoints", 2^53)
            end)
        end
        task.wait(0.05)
    end
end)

getgenv().__MacRealWindow = Window
Window:SetState(true)
retrySyncDropdowns()
Tabs.Combat:Select()
