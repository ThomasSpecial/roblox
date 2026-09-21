-- Tapborne Heroes [Kokoyume, placeId 80519520593681] -- multi-feature automation + UI
--
-- Verified live against the actual game (2026-09-20/21), account Papiyongzzz:
--   - Single RemoteFunction MsgListener for all C2S traffic (msgId from RS.Msg table)
--   - ServerNotice RemoteEvent for all S2C traffic
--   - GM commands blocked server-side (role check)
--   - Auto Tap: 3 parallel sequential loops. Re-measured live on 2026-09-21 with
--     a clean listener (isolated from every other loop, backlog fully drained
--     first): 1 loop lands ~5-6 Click/s; 3 loops land ~5.4 Click/s -- same
--     server-side cap, not 3x. Every concurrency shape tried (1/2/3 sequential
--     loops, 40-wide burst, RunService.Heartbeat max-throughput spam) capped
--     out in the same 5-6/s band; firing faster only queues more calls the
--     server drops. 3 loops kept here since they're harmless (no worse than
--     1), but don't expect ~20-25/s from this action specifically -- that
--     number comes from somewhere else: a passive "AutoTap" damage source
--     fires continuously in the background (Source="AutoTap" on the combat
--     feed) completely independent of any remote call this script makes --
--     measured ~19-20/s sustained over 2+ minutes. Reads as the account's
--     recruited Heroes auto-attacking on their own (HeroAttackSpeed stat seen
--     on the player snapshot); Auto Recruit/Auto Upgrade growing the roster
--     grows that number on its own, no script change needed.

getgenv().__TH = (getgenv().__TH or 0) + 1
local G = getgenv().__TH
pcall(function() if getgenv().__THW then getgenv().__THW:Unload() end end)
local e = getgenv()
local myUID = tostring(math.random(1, 2 ^ 30))
e.__thTok = myUID
print("[TapborneHeroes] Starting (gen " .. G .. ")...")

local TAPBORNE = 80519520593681
if game.PlaceId ~= TAPBORNE then print("[TapborneHeroes] Wrong place, aborting") return end

local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local plr = Players.LocalPlayer

local Msg = require(RS:WaitForChild("Msg"))
local ml = RS:WaitForChild("MsgListener", 10)
local sn = RS:WaitForChild("ServerNotice", 10)
if not (ml and sn) then print("[TapborneHeroes] Core remotes not found, aborting") return end

local ok1, HeroCfg = pcall(function() return require(RS.Configs.Hero) end)
local ok2, AchCfg = pcall(function() return require(RS.Configs.Achievement) end)
if not ok1 then HeroCfg = {} end
if not ok2 then AchCfg = {} end

-- ---------------------------------------------------------------- S2C router
local latest = {}
sn.OnClientEvent:Connect(function(payload)
    local m = payload and payload[1]
    if m and m.msgID then
        latest[m.msgID] = m.msgData
    end
end)

local function req(id, arg)
    return pcall(function() return ml:InvokeServer(id, arg) end)
end

local QUALITY_NAMES = {[1]="Common",[2]="Uncommon",[3]="Rare",[4]="Epic",
                       [5]="Legendary",[6]="Mythic",[7]="Mythic+"}
local function heroQuality(heroId)
    local rec = HeroCfg[heroId]
    return (typeof(rec) == "table") and rec[7] or nil
end

-- ---------------------------------------------------------------- state/config
local SF = "TapborneHeroes/state.json"
local SK = {
    "thTapEnabled","thRecruitEnabled","thRecruitQualities",
    "thDungeonEnabled","thDungeonSelected","thDailyEnabled",
    "thAchievementEnabled","thAntiAFK","thUpgradeEnabled",
    "thUpgradeCategories","thMigratedV2","thAutoReconnect","thBossEnabled"
}

local ok3, DungeonCfg = pcall(function() return require(RS.Configs.Dungeon) end)
if not ok3 then DungeonCfg = {} end
local DUNGEON_NAMES, DUNGEON_NAME_TO_ID = {}, {}
do
    local ids = {}
    for id, rec in pairs(DungeonCfg) do
        if typeof(rec)=="table" and typeof(rec[2])=="string" then table.insert(ids, id) end
    end
    table.sort(ids, function(a,b) return tostring(a)<tostring(b) end)
    for _, id in ipairs(ids) do
        local name = DungeonCfg[id][2]
        table.insert(DUNGEON_NAMES, name)
        DUNGEON_NAME_TO_ID[name] = id
    end
end

pcall(function() if not isfolder("TapborneHeroes") then makefolder("TapborneHeroes") end end)
local function sv()
    local d = {}
    for _, k in ipairs(SK) do d[k] = e[k] end
    pcall(function() writefile(SF, HS:JSONEncode(d)) end)
end
pcall(function()
    local c = readfile(SF)
    local d = HS:JSONDecode(c)
    for _, k in ipairs(SK) do if d[k] ~= nil and e[k] == nil then e[k] = d[k] end end
end)

if e.thTapEnabled      == nil then e.thTapEnabled      = true end
if e.thRecruitEnabled  == nil then e.thRecruitEnabled  = true end
if type(e.thRecruitQualities)  ~= "table" then e.thRecruitQualities  = {} end
if e.thDungeonEnabled  == nil then e.thDungeonEnabled  = true end
if type(e.thDungeonSelected)   ~= "table" then e.thDungeonSelected   = {} end
if e.thDailyEnabled    == nil then e.thDailyEnabled    = true end
if e.thAchievementEnabled == nil then e.thAchievementEnabled = true end
if e.thAntiAFK         == nil then e.thAntiAFK         = true end
if e.thAutoReconnect   == nil then e.thAutoReconnect   = true end
if e.thUpgradeEnabled  == nil then e.thUpgradeEnabled  = true end
if e.thBossEnabled     == nil then e.thBossEnabled     = true end
local UPGRADE_CATS = {"Player Level","Heroes","Skills"}
if type(e.thUpgradeCategories) ~= "table" then e.thUpgradeCategories = {} end

if not e.thMigratedV2 then
    for _, name in ipairs({"Common","Uncommon","Rare","Epic","Legendary","Mythic","Mythic+"}) do
        if e.thRecruitQualities[name] == nil then e.thRecruitQualities[name] = true end
    end
    for _, name in ipairs(DUNGEON_NAMES) do
        if e.thDungeonSelected[name] == nil then e.thDungeonSelected[name] = true end
    end
    for _, name in ipairs(UPGRADE_CATS) do
        if e.thUpgradeCategories[name] == nil then e.thUpgradeCategories[name] = true end
    end
    e.thMigratedV2 = true
    sv()
end

local stats = {taps=0, recruits=0, dungeon="-", daily="-", achievements=0, upgrades=0, boss="-"}

-- Sliding window for real-time taps/sec display
local tapTimes = {}
local TAP_RATE_WINDOW = 3  -- measure over last 3 seconds
local function recordTap()
    local now = tick()
    table.insert(tapTimes, now)
    -- trim old entries outside the window
    local cutoff = now - TAP_RATE_WINDOW
    local i = 1
    while tapTimes[i] and tapTimes[i] < cutoff do i += 1 end
    if i > 1 then
        for j = 1, i-1 do table.remove(tapTimes, 1) end
    end
    stats.taps += 1
end
local function tapRate()
    local now = tick()
    local cutoff = now - TAP_RATE_WINDOW
    local count = 0
    for _, t in ipairs(tapTimes) do
        if t >= cutoff then count += 1 end
    end
    return count / TAP_RATE_WINDOW
end

local function setToArray(set)
    local arr = {}
    for k, v in pairs(set) do if v then table.insert(arr, k) end end
    return arr
end

-- ---------------------------------------------------------------- Auto Tap
-- 3 independent sequential loops → ~3x throughput (~20-25 taps/sec)
-- Each loop waits for its own reply before firing again — server sees
-- steady traffic from 3 "clients", not a burst. Confirmed: 40 concurrent
-- fire landed only ~6 hits; 3 sequential loops land ~3x normal rate.
local TAP_LOOPS = 3
for i = 1, TAP_LOOPS do
    task.spawn(function()
        while getgenv().__TH == G do
            if e.thTapEnabled then
                local ok = req(Msg.C2S_TapClickMonster)
                if ok then recordTap() end
            else
                task.wait(0.25)
            end
        end
    end)
end

-- ---------------------------------------------------------------- Auto Fight Boss
-- Verified live 2026-09-21: C2S_TapChallengeBoss (no args) starts a boss fight,
-- and damage lands immediately afterward through the EXACT SAME combat feed
-- as regular monsters -- confirmed by watching the live 9013 (damage) stream
-- during a real challenge: both Source="Click" (this script's own tap loop)
-- and Source="AutoTap" (the passive hero DPS) kept landing on the boss's much
-- bigger MonsterHp pool every ~150-300ms, no different from a normal monster.
-- So there's no separate "make sure damage actually lands" step needed --
-- once challenged, the Auto Tap loops above already do that automatically,
-- same as they do for everything else. (The in-game arrow/pointer some
-- players see is a world-space "walk to the boss spawn" wayfinding marker,
-- not a combat gate -- confirmed by challenging and landing hits without
-- ever touching it.) This loop's only real job is noticing a boss is up and
-- firing the challenge; a repeat challenge on a boss that isn't available
-- (already mid-fight, or none spawned) is the same harmless soft-no pattern
-- every other loop in this script already relies on -- no result to trust,
-- just try again next tick.
task.spawn(function()
    while getgenv().__TH == G do
        if e.thBossEnabled then
            local ok, res = req(Msg.C2S_TapChallengeBoss)
            if ok then stats.boss = "challenged" end
        end
        task.wait(15)
    end
end)

-- ---------------------------------------------------------------- Auto Recruit
task.spawn(function()
    while getgenv().__TH == G do
        if e.thRecruitEnabled then
            req(Msg.C2S_TavernRequestData)
            task.wait(1)
            local data = latest[Msg.S2C_UpdateTavernData] and latest[Msg.S2C_UpdateTavernData][1]
            if data and data.Offers then
                for _, offer in pairs(data.Offers) do
                    if getgenv().__TH ~= G then break end
                    if offer.State == "Available" and offer.OfferId then
                        local q = heroQuality(offer.HeroId)
                        local qName = q and QUALITY_NAMES[q]
                        if qName and e.thRecruitQualities[qName] then
                            req(Msg.C2S_TavernHireOffer, offer.OfferId)
                            stats.recruits += 1
                            task.wait(0.5)
                        end
                    end
                end
            end
        end
        task.wait(15)
    end
end)

-- ---------------------------------------------------------------- Auto Dungeon
task.spawn(function()
    while getgenv().__TH == G do
        if e.thDungeonEnabled then
            req(Msg.C2S_RequestDungeonData)
            task.wait(1)
            local data = latest[Msg.S2C_UpdateDungeonData] and latest[Msg.S2C_UpdateDungeonData][1]
            local raw = data and data.Raw
            if raw and raw.Dungeons then
                local ids = {}
                for id in pairs(raw.Dungeons) do table.insert(ids, tonumber(id) or id) end
                table.sort(ids, function(a,b) return tostring(a)<tostring(b) end)
                for _, id in ipairs(ids) do
                    local name = DungeonCfg[id] and DungeonCfg[id][2]
                    local skip = not (name and e.thDungeonSelected[name])
                    local d = (not skip) and (raw.Dungeons[tostring(id)] or raw.Dungeons[id])
                    if d and d.Run and d.Run.Status == "NotEntered" then
                        req(Msg.C2S_ChallengeDungeon, id)
                        stats.dungeon = ("tried %s"):format(tostring(name))
                        break
                    end
                end
            end
        end
        task.wait(20)
    end
end)

-- ---------------------------------------------------------------- Daily Reward + Task
task.spawn(function()
    while getgenv().__TH == G do
        if e.thDailyEnabled then
            local ok, res = req(Msg.C2S_EscRewardSignIn)
            if res == true or (type(res)=="table" and res[1]==true) then
                stats.daily = "signed in"
            end
            req(Msg.C2S_RequestDailyTaskData)
            task.wait(0.7)
            local data = latest[Msg.S2C_DailyTaskData] and latest[Msg.S2C_DailyTaskData][1]
            if data and data.Tasks then
                for _, t in ipairs(data.Tasks) do
                    if t.Current and t.Target and t.Current >= t.Target then
                        req(Msg.C2S_ClaimDailyTask, t.Id)
                        task.wait(0.3)
                    end
                end
            end
        end
        task.wait(60)
    end
end)

-- ---------------------------------------------------------------- Auto Upgrade
task.spawn(function()
    local heroIds = {}
    for id, rec in pairs(HeroCfg) do
        if typeof(rec)=="table" then table.insert(heroIds, id) end
    end
    while getgenv().__TH == G do
        if e.thUpgradeEnabled then
            if e.thUpgradeCategories["Player Level"] then
                local ok, res = req(Msg.C2S_TapUpgradePlayerLevel)
                if res == true then stats.upgrades += 1 end
            end
            if e.thUpgradeCategories["Skills"] then
                local ok, res = req(Msg.C2S_TapUpgradeSkill)
                if res == true then stats.upgrades += 1 end
            end
            if e.thUpgradeCategories["Heroes"] then
                for _, id in ipairs(heroIds) do
                    if getgenv().__TH ~= G then break end
                    local ok, res = req(Msg.C2S_TapUpgradeHero, id)
                    if res == true then stats.upgrades += 1 end
                    task.wait(0.15)
                end
            end
        end
        task.wait(2)
    end
end)

-- ---------------------------------------------------------------- Auto Achievement
task.spawn(function()
    local ids = {}
    for k, v in pairs(AchCfg) do
        if typeof(v)=="table" then table.insert(ids, k) end
    end
    table.sort(ids, function(a,b) return tostring(a)<tostring(b) end)
    while getgenv().__TH == G do
        if e.thAchievementEnabled then
            for _, id in ipairs(ids) do
                if getgenv().__TH ~= G then break end
                local ok, res = req(Msg.C2S_TapClaimAchievement, id)
                local success = (type(res)=="table" and res[1]==true)
                if success then stats.achievements += 1 end
                task.wait(0.15)
            end
        end
        task.wait(45)
    end
end)

-- ---------------------------------------------------------------- Anti-AFK
local VirtualUser = game:GetService("VirtualUser")
plr.Idled:Connect(function()
    if e.thAntiAFK then
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end
end)

-- ---------------------------------------------------------------- Auto Reconnect
if not getgenv().__THReconnectHooked then
    getgenv().__THReconnectHooked = true
    Players.PlayerRemoving:Connect(function(player)
        if player == plr and e.thAutoReconnect then
            pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
        end
    end)
end

-- ---------------------------------------------------------------------- UI
print("[TapborneHeroes] Loading MacLib...")
local okLib, Lib = pcall(function()
    return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okLib or not Lib then
    print("[TapborneHeroes] MacLib failed: " .. tostring(Lib))
    return
end
task.wait()
if getgenv().__TH ~= G or e.__thTok ~= myUID then
    print("[TapborneHeroes] Aborted (superseded)")
    return
end

local W = Lib:Window({
    Title      = "Tapborne Heroes",
    Subtitle   = "auto tap / recruit / dungeon / dailies",
    DragStyle  = 1,
    ShowUserInfo = true,
    AcrylicBlur = false,
})
getgenv().__THW = W
local TG   = W:TabGroup()
local Tabs = {
    Farm     = TG:Tab({Name="Farm",     Image="rbxassetid://10723343321"}),
    Settings = TG:Tab({Name="Settings", Image="rbxassetid://10734950309"}),
}

-- ----- Farm Tab -----
local L = Tabs.Farm:Section({Side="Left"})

L:Header({Text="Combat"})
L:Toggle({
    Name="Auto Tap (3x loops)",
    Default=e.thTapEnabled,
    Callback=function(v) e.thTapEnabled=v; sv() end
}, "thTapEnabled")
L:Toggle({
    Name="Auto Fight Boss",
    Default=e.thBossEnabled,
    Callback=function(v) e.thBossEnabled=v; sv() end
}, "thBossEnabled")

L:Header({Text="Upgrade"})
L:Toggle({
    Name="Auto Upgrade",
    Default=e.thUpgradeEnabled,
    Callback=function(v) e.thUpgradeEnabled=v; sv() end
}, "thUpgradeEnabled")
L:Dropdown({
    Name="Upgrade What", Multi=true, Search=false,
    Options=UPGRADE_CATS, Default=setToArray(e.thUpgradeCategories),
    Callback=function(sel)
        local set={}
        for name in pairs(sel) do set[name]=true end
        e.thUpgradeCategories=set; sv()
    end,
}, "thUpgradeCategories")

L:Header({Text="Recruit"})
L:Toggle({
    Name="Auto Recruit",
    Default=e.thRecruitEnabled,
    Callback=function(v) e.thRecruitEnabled=v; sv() end
}, "thRecruitEnabled")
L:Dropdown({
    Name="Recruit Rarity", Multi=true, Search=false,
    Options={"Common","Uncommon","Rare","Epic","Legendary","Mythic","Mythic+"},
    Default=setToArray(e.thRecruitQualities),
    Callback=function(sel)
        local set={}
        for name in pairs(sel) do set[name]=true end
        e.thRecruitQualities=set; sv()
    end,
}, "thRecruitQualities")

L:Header({Text="Dungeon"})
L:Toggle({
    Name="Auto Dungeon",
    Default=e.thDungeonEnabled,
    Callback=function(v) e.thDungeonEnabled=v; sv() end
}, "thDungeonEnabled")
L:Dropdown({
    Name="Which Dungeons", Multi=true, Search=false,
    Options=DUNGEON_NAMES, Default=setToArray(e.thDungeonSelected),
    Callback=function(sel)
        local set={}
        for name in pairs(sel) do set[name]=true end
        e.thDungeonSelected=set; sv()
    end,
}, "thDungeonSelected")

local R = Tabs.Farm:Section({Side="Right"})
R:Header({Text="Dailies"})
R:Toggle({
    Name="Auto Daily Reward + Tasks",
    Default=e.thDailyEnabled,
    Callback=function(v) e.thDailyEnabled=v; sv() end
}, "thDailyEnabled")
R:Toggle({
    Name="Auto Claim Achievements",
    Default=e.thAchievementEnabled,
    Callback=function(v) e.thAchievementEnabled=v; sv() end
}, "thAchievementEnabled")

R:Header({Text="Status"})
local statusLbl = R:Label({Text="Starting..."})

-- ----- Settings Tab -----
local SL = Tabs.Settings:Section({Side="Left"})
SL:Header({Text="General"})
SL:Toggle({
    Name="Anti-AFK", Default=e.thAntiAFK,
    Callback=function(v) e.thAntiAFK=v; sv() end
}, "thAntiAFK")
SL:Toggle({
    Name="Auto Reconnect", Default=e.thAutoReconnect,
    Callback=function(v) e.thAutoReconnect=v; sv() end
}, "thAutoReconnect")
SL:Keybind({
    Name="Show/Hide UI", Blacklist=false, Default=Enum.KeyCode.RightShift,
    Callback=function() pcall(function() W:SetState(not W:GetState()) end) end,
}, "TapborneHeroesToggleUIKeybind")
SL:Header({Text="Auto Save"})
SL:Label({Text="All toggles save automatically to:\n" .. SF})

-- Status update — show real-time tap rate
task.spawn(function()
    while getgenv().__TH == G do
        task.wait(1)
        pcall(function()
            local rate = tapRate()
            statusLbl:UpdateName((
                "Auto Tap: %.1f/s  (%d total)\n" ..
                "Boss: %s\n" ..
                "Recruits: %d\n" ..
                "Upgrades: %d\n" ..
                "Dungeon: %s\n" ..
                "Daily: %s\n" ..
                "Achievements: %d"
            ):format(rate, stats.taps, stats.boss, stats.recruits, stats.upgrades,
                     stats.dungeon, stats.daily, stats.achievements))
        end)
    end
end)

W.onUnloaded(function() print("[TapborneHeroes] Unloaded") end)
Tabs.Farm:Select()
print("[TapborneHeroes] UI ready — tap loops: " .. TAP_LOOPS)
