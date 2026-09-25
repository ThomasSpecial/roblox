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
    "thUpgradeCategories","thMigratedV2","thAutoReconnect","thBossEnabled",
    "thSkillsEnabled","thReserveEnabled","thReserveQualities",
    "thExpeditionEnabled","thExpeditionRarities","thExpeditionDuration",
    "thFrenzyEnabled","thFrenzyMinDiamonds","thRebirthEnabled","thRebirthMinStage",
    "thSkyChestEnabled","thEquipBestEnabled","thExtrasEnabled",
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
if e.thReserveEnabled  == nil then e.thReserveEnabled  = true end
-- Brand new key -- nil means genuinely first-ever load, default it to the
-- full rarity set then (same as thRecruitQualities' own defaults). Present
-- but not a table (or already an empty {} the user deliberately emptied via
-- the dropdown) is respected as-is -- NOT force-repopulated, learned the
-- hard way from thRecruitQualities silently un-unchecking itself every
-- reload when an earlier version of this backfill ran unconditionally.
if e.thReserveQualities == nil then
    e.thReserveQualities = {}
    for _, name in ipairs({"Common","Uncommon","Rare","Epic","Legendary","Mythic","Mythic+"}) do
        e.thReserveQualities[name] = true
    end
elseif type(e.thReserveQualities) ~= "table" then
    e.thReserveQualities = {}
end
if e.thDungeonEnabled  == nil then e.thDungeonEnabled  = true end
if type(e.thDungeonSelected)   ~= "table" then e.thDungeonSelected   = {} end
if e.thDailyEnabled    == nil then e.thDailyEnabled    = true end
if e.thAchievementEnabled == nil then e.thAchievementEnabled = true end
if e.thAntiAFK         == nil then e.thAntiAFK         = true end
if e.thAutoReconnect   == nil then e.thAutoReconnect   = true end
if e.thUpgradeEnabled  == nil then e.thUpgradeEnabled  = true end
if e.thBossEnabled     == nil then e.thBossEnabled     = true end
if e.thSkillsEnabled   == nil then e.thSkillsEnabled   = true end
local UPGRADE_CATS = {"Player Level","Heroes","Skills"}
if type(e.thUpgradeCategories) ~= "table" then e.thUpgradeCategories = {} end
-- Expedition / store / rebirth / extras (added 2026-09-25). Rarity names
-- here are the game's own RarityConfigs order (GameSettings): 1 Common,
-- 2 Rare, 3 Epic, 4 Legendary, 5 Mythical, 6 Supreme, 7 Ultimate -- that
-- is what hero instances carry as Rarity and what the Expedition UI
-- shows, distinct from the Tavern quality list used by Recruit above.
local EXP_RARITY_NAMES = {"Common","Rare","Epic","Legendary","Mythical","Supreme","Ultimate"}
local EXP_RARITY_ID = {}
for i, n in ipairs(EXP_RARITY_NAMES) do EXP_RARITY_ID[n] = i end
local EXP_DURATIONS = {{"4h (Short)","Short"},{"8h (Standard)","Standard"},{"12h (Long)","Long"}}
if e.thExpeditionEnabled == nil then e.thExpeditionEnabled = true end
if type(e.thExpeditionRarities) ~= "table" then e.thExpeditionRarities = {} end   -- empty = Auto Select Best
if type(e.thExpeditionDuration) ~= "string" then e.thExpeditionDuration = "Standard" end
if e.thFrenzyEnabled   == nil then e.thFrenzyEnabled   = false end   -- spends diamonds: opt-in
-- Diamond floor for the Frenzy buyer: a buy only happens while (diamonds -
-- price) stays at or above this. Under it the buyer pauses by itself and
-- resumes on its own once diamonds climb back over -- no toggling needed.
if type(e.thFrenzyMinDiamonds) ~= "number" then e.thFrenzyMinDiamonds = 0 end
if e.thRebirthEnabled  == nil then e.thRebirthEnabled  = false end   -- resets the run: opt-in
if type(e.thRebirthMinStage) ~= "number" then e.thRebirthMinStage = 0 end
if e.thSkyChestEnabled == nil then e.thSkyChestEnabled = true end
if e.thEquipBestEnabled == nil then e.thEquipBestEnabled = true end
if e.thExtrasEnabled   == nil then e.thExtrasEnabled   = true end

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

local stats = {taps=0, recruits=0, dungeon="-", daily="-", achievements=0, upgrades=0, boss="-", skills=0,
    expedition="-", expeditions=0, frenzy="-", frenzyBuys=0, rebirth="-", rebirths=0, chests=0, chestHits=0, extras=0, extrasNote="-"}
e.__thStats = stats   -- exposed for live probes only

-- The game's client managers live on the shared table (ClientExpeditionManager,
-- ClientPlayerManager, ClientSkyChestManager, ...). Driving them instead of
-- the raw msgs keeps their request ids / pending flags in sync with the UI.
local function SH()
    local ok, s = pcall(function() return (getrenv and getrenv().shared) or shared end)
    return (ok and type(s) == "table") and s or nil
end

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
-- Two bugs, two fixes, in order:
--
-- BUG 1 (fixed 2026-09-21): C2S_TapChallengeBoss (no args) starts a boss
-- fight, and damage lands immediately afterward through the EXACT SAME
-- combat feed as regular monsters -- no special targeting step needed. But
-- re-firing it while ALREADY mid-fight does NOT no-op or resume -- it starts
-- a brand new encounter and throws the current one away. Caught live: a boss
-- at 1.28e18/5.81e18 HP (78% dead) got re-challenged by the original blind
-- 15s timer and the next hit landed on a FRESH boss 10x bigger, back near
-- full HP. First fix: gate re-challenging on BossRetryAvailable from the
-- S2C_UpdateCombatData (9001) snapshot.
--
-- BUG 2 (fixed 2026-09-22): that gate is only as good as the snapshot
-- feeding it, and 9001 turned out NOT to push reliably or often -- passively
-- watching it for 40s of real, ongoing gameplay caught exactly 2 pushes,
-- both stale "true" values, while boss fights were verifiably starting and
-- dealing real damage the whole time (confirmed separately via the 9013
-- damage feed). Relying on it left the exact same symptom as Bug 1 under a
-- different mechanism -- reported again as "ยัง Fight ตอนดาเมทฉันไม่พอ" (still
-- fighting when my damage isn't enough): the loop kept reading a stale
-- "available" and blindly re-challenging into fights already in progress.
--
-- Real fix: stop depending on any pushed snapshot for fight-state at all.
-- The 9013 damage feed IS reliable during an active fight -- dozens of real
-- events land every ~30s window, every one carrying the current target's
-- MonsterMaxHp for free. So: challenge, then actively WATCH that feed for
-- the fight's own known duration (measured live, ~30s -- wait a bit past it
-- for margin) summing real damage dealt, and only decide to challenge again
-- once that wait is over. Structurally can't re-challenge mid-fight anymore
-- -- there's no poll gap for a stale flag to lie into, the loop is asleep
-- for the fight's whole duration by construction.
--
-- The same watch also finally gives a REAL win/loss check with zero
-- dependency on ever finding a reward message (never found one worth
-- trusting -- see the long dead-end in this file's history): summed damage
-- >= the boss's own MonsterMaxHp means it died. A loss earns a backoff
-- before the next attempt, buying Auto Upgrade time to raise real damage
-- instead of burning attempts on a fight current power already proved it
-- can't finish (measured live: base Click+AutoTap alone was only covering
-- ~50-55% of a boss's HP per window at this account's current power -- a
-- genuine account-power gap, not something any smarter challenge timing
-- fixes -- see the "don't rely on Auto Use Skills" note lower down).
-- First live test of the watch-window design (above) produced an
-- immediate false "defeated!" every single cycle -- the watcher was summing
-- ALL S2C_TapDamageFeedback events for the full 34s blindly, and once a
-- fight actually ends (win, or the ~30s timer), the account's Click/AutoTap
-- loops carry straight on hitting REGULAR monsters for the REST of that same
-- 34s window -- those hits landed in the same sum. A run of ordinary kills
-- easily outweighs a single monster's MaxHp, so the "damage >= MaxHp" check
-- tripped almost immediately regardless of whether the boss itself ever
-- took meaningful damage. Fix: LOCK ONTO the specific target's MonsterMaxHp
-- from the first event seen after challenging, only accumulate further hits
-- whose MonsterMaxHp still matches that locked value (a ~0.01% tolerance,
-- not exact equality -- these numbers run past 1e18 where Luau's
-- double-precision floats can't represent every integer exactly, so two
-- reads of what's conceptually the same value aren't guaranteed bit-
-- identical), and treat a stretch with no matching event as that specific
-- fight being over -- stop watching THEN rather than blindly riding out the
-- full window padded with unrelated grinding damage.
-- Second live iteration: summing Damage myself (first version of this
-- comment block) produced an immediate false "defeated!" every cycle --
-- once a fight actually ends, the account's Click/AutoTap loops carry
-- straight on hitting REGULAR monsters for the rest of the watch window,
-- and those hits landed in the same sum, trivially exceeding any one
-- monster's MaxHp. A same-target-lock fix (matching MonsterMaxHp within a
-- tolerance) then showed the opposite problem -- premature idle-timeouts at
-- ~1% HP, because the boss's own reported MaxHp isn't perfectly constant
-- moment to moment at these magnitudes (regen recalculating the pool, or
-- float precision past 1e18) and kept slipping outside the match tolerance.
--
-- Simpler fix that sidesteps both: don't reimplement damage accounting at
-- all -- every S2C_TapDamageFeedback event already carries the server's own
-- authoritative MonsterHp (remaining), not just Damage dealt. Track the
-- LARGEST MonsterMaxHp pool seen during the watch window (the boss should
-- always dwarf whatever regular monster the account might also be grinding
-- in the background) and the most recent MonsterHp reading that belongs to
-- that same pool (5% tolerance, self-updating so gradual drift/regen still
-- tracks) -- that reading, at the moment the fight goes idle, IS the real
-- outcome, read straight from the server instead of computed by us.
local BOSS_FIGHT_WATCH_S = 34       -- hard ceiling -- measured fight length ~30s, +margin
local BOSS_TARGET_IDLE_S = 4        -- no matching-target hit for this long = fight's over
local BOSS_LOSS_BACKOFF_S = 180     -- 3 min between retries after a confirmed loss
local BOSS_NO_FIGHT_RETRY_S = 10    -- short retry if a challenge visibly did nothing
local bossNextAllowedAt = 0
task.spawn(function()
    while getgenv().__TH == G do
        if e.thBossEnabled and os.clock() >= bossNextAllowedAt then
            req(Msg.C2S_TapChallengeBoss)
            stats.boss = "challenged, watching fight..."
            -- brief warm-up: lets any regular-monster hit reply already in
            -- flight from the tap loop land and clear out first, so it
            -- can't get adopted as "the boss" by accident right at the start
            task.wait(0.5)

            local bestMaxHp = 0
            local hpAtBest = nil
            local lastMatchAt = nil
            local watchConn
            watchConn = sn.OnClientEvent:Connect(function(payload)
                local m = payload and payload[1]
                if not (m and m.msgID == Msg.S2C_TapDamageFeedback) then return end
                local d = m.msgData[1]
                if d.MonsterMaxHp > bestMaxHp * 1.05 then
                    -- a clearly bigger pool than anything seen this window --
                    -- the boss (or its regen growing it); adopt it
                    bestMaxHp = d.MonsterMaxHp
                    hpAtBest = d.MonsterHp
                    lastMatchAt = os.clock()
                elseif bestMaxHp > 0 and math.abs(d.MonsterMaxHp - bestMaxHp) / bestMaxHp < 0.05 then
                    -- same pool, fresher reading
                    bestMaxHp = d.MonsterMaxHp
                    hpAtBest = d.MonsterHp
                    lastMatchAt = os.clock()
                end
                -- anything clearly smaller than the biggest pool seen so far
                -- (regular grinding continuing alongside/after the boss) is
                -- simply ignored -- never touches bestMaxHp/hpAtBest
            end)

            local t0 = os.clock()
            while os.clock() - t0 < BOSS_FIGHT_WATCH_S and getgenv().__TH == G do
                task.wait(1)
                if lastMatchAt and os.clock() - lastMatchAt > BOSS_TARGET_IDLE_S then
                    break   -- the boss's own pool stopped updating -- fight's over
                end
            end
            watchConn:Disconnect()

            if not hpAtBest then
                -- challenge visibly did nothing (no boss-scale damage seen at
                -- all) -- nothing to back off from, just don't hammer it
                bossNextAllowedAt = os.clock() + BOSS_NO_FIGHT_RETRY_S
                stats.boss = "no boss available right now"
            elseif hpAtBest <= bestMaxHp * 0.01 then
                bossNextAllowedAt = os.clock()
                stats.boss = "defeated! trying next one"
            else
                bossNextAllowedAt = os.clock() + BOSS_LOSS_BACKOFF_S
                stats.boss = ("lost (%.0f%% HP left) -- retrying in %ds"):format(
                    100 * hpAtBest / bestMaxHp, BOSS_LOSS_BACKOFF_S)
            end
        end
        task.wait(2)
    end
end)

-- ---------------------------------------------------------------- Auto Use Skills
-- The real fix for "ยังสู้บอสไม่ได้" turned out to need more than not resetting
-- the fight -- verified live that Click+AutoTap alone gets the boss down to
-- ~7.5% HP within its ~30s window but not quite to zero. Configs.Skill has 4
-- combat-relevant active skills this account owns that the script never used:
--   101 Heavenly Strike -- deals tapDamageMultiplier x tap damage INSTANTLY.
--       Confirmed live: a single cast hit for 2.44e19 while a normal tap was
--       hitting for 1.63e17 at the same time -- ~150x one tap in one call.
--       That alone is a huge chunk of a boss's total HP pool.
--   105 Berserker Rage -- +tap damage% for 20s, "Also affects Heavenly
--       Strike" per its own description -- cast this right before 101 so the
--       multiplier applies to the burst too, not just regular taps.
--   103 Critical Strike / 104 War Cry -- smaller buffs (+crit%, +hero atk
--       speed%), harmless to also try.
-- Skill 102 (Shadow Clone) is deliberately left out -- its "AutoTap" damage
-- source has been observed running continuously since before this script
-- ever called TapUseSkill, so it's already active/self-sustaining and
-- doesn't need a poke here.
--
-- Cooldowns read from Configs.Skill are long (1800s/30min for Heavenly
-- Strike, 3600s/60min for the others) -- trying one every 20s is the same
-- harmless soft-no pattern as everywhere else in this script (confirmed
-- live: InvokeServer on an on-cooldown skill just returns false, no error),
-- it just happens to actually succeed once every 30-60 minutes. Casting
-- Berserker Rage then Heavenly Strike in that order, together, right as a
-- boss fight is live (BossRetryAvailable == false) is what lines the burst
-- up with the fight that actually needs it instead of a random grind moment.
-- Not gated on "boss fight currently active" -- cooldowns are long enough
-- (30-60min) relative to how often a boss fight is actually up that gating
-- would just leave a ready skill sitting unused for a long stretch; firing
-- as soon as it's off cooldown regardless of context still helps (normal
-- stage clearing benefits from these too), and whenever a cast does land
-- during a live boss fight, that's this loop's 20s poll cadence lining up
-- with a fight window on its own, not a hard requirement to do so.
local SKILL_ORDER = {105, 103, 104, 101}   -- buffs first, Heavenly Strike last
task.spawn(function()
    while getgenv().__TH == G do
        if e.thSkillsEnabled then
            for _, id in ipairs(SKILL_ORDER) do
                if getgenv().__TH ~= G then break end
                local ok, res = req(Msg.C2S_TapUseSkill, id)
                if res == true then stats.skills += 1 end
                task.wait(0.3)
            end
        end
        task.wait(20)
    end
end)

-- ---------------------------------------------------------------- Auto Recruit
-- Auto Reserve is folded into this same loop rather than a separate one --
-- it needs the exact same tavern-offer data Auto Recruit already fetches,
-- and its whole point is to catch offers Auto Recruit just failed to buy.
--
-- Verified live 2026-09-22:
--   - C2S_TavernReserveOffer(offerId) moves an Available offer into
--     data.Reserved (a dict keyed by reserve slot, each entry carrying the
--     same OfferId/HeroId/RecruitCost as the original) and flips that
--     offer's State to "Reserved" so the tavern's own rotation/refresh can't
--     wipe it out from under the account while gold catches up.
--   - Slot limit (GameSettings.HERO_TAVERN_DEFAULT_RESERVE_SLOTS = 2 by
--     default) is enforced server-side, not tracked here: reserving past the
--     limit answers {Success=false, Reason="ReserveFull"} cleanly -- no need
--     to count slots ourselves, same soft-no pattern as everything else.
--   - S2C_TavernActionResult (9215) reports {Action, OfferId, Success,
--     Reason} for BOTH Recruit and Reserve attempts -- a failed hire on an
--     unaffordable offer answers {Action="Recruit", Success=false,
--     Reason="PurchaseFailed"}, confirmed live. That Success flag is read
--     right after each hire attempt below to decide whether to fall back to
--     reserving it -- no need to read/parse the account's Gold value at all
--     (there's no cheap on-demand way to read it found this session; the
--     visible GoldLabel in ScreenGui_Main reads stale/desynced numbers next
--     to everything server-confirmed here, not trustworthy).
--   - TavernHireOffer on an already-Reserved offer works exactly like a
--     normal hire (confirmed live: State went Reserved -> Hired) -- so
--     "buying out of reserve" is just retrying the normal hire call on
--     whatever's sitting in data.Reserved each pass, same soft-no-until-
--     affordable pattern.
task.spawn(function()
    while getgenv().__TH == G do
        if e.thRecruitEnabled or e.thReserveEnabled then
            req(Msg.C2S_TavernRequestData)
            task.wait(1)
            local data = latest[Msg.S2C_UpdateTavernData] and latest[Msg.S2C_UpdateTavernData][1]

            if e.thRecruitEnabled and data and data.Offers then
                for _, offer in pairs(data.Offers) do
                    if getgenv().__TH ~= G then break end
                    if offer.State == "Available" and offer.OfferId then
                        local q = heroQuality(offer.HeroId)
                        local qName = q and QUALITY_NAMES[q]
                        if qName and e.thRecruitQualities[qName] then
                            req(Msg.C2S_TavernHireOffer, offer.OfferId)
                            task.wait(0.4)
                            local result = latest[Msg.S2C_TavernActionResult]
                            local r = result and result[1]
                            local bought = r and r.Action == "Recruit" and r.OfferId == offer.OfferId and r.Success
                            if bought then
                                stats.recruits += 1
                            elseif e.thReserveEnabled and e.thReserveQualities[qName] then
                                req(Msg.C2S_TavernReserveOffer, offer.OfferId)
                                task.wait(0.4)
                            end
                        end
                    end
                end
            end

            if e.thReserveEnabled and data and data.Reserved then
                for _, r in pairs(data.Reserved) do
                    if getgenv().__TH ~= G then break end
                    if r.OfferId then
                        req(Msg.C2S_TavernHireOffer, r.OfferId)
                        task.wait(0.4)
                        local result = latest[Msg.S2C_TavernActionResult]
                        local rr = result and result[1]
                        if rr and rr.Action == "Recruit" and rr.OfferId == r.OfferId and rr.Success then
                            stats.recruits += 1
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

-- ---------------------------------------------------------------- Auto Expedition
-- Everything here goes through shared.ClientExpeditionManager (read out of
-- the live client): GetSnapshot() -> {Status="Running"|"Completed"|"Claiming"
-- |nil, CanClaim, CanStart, Ready, Available, RemainingSeconds, Duration},
-- SetDuration("Short"|"Standard"|"Long") = 4h/8h/12h, AutoSelect() (the
-- game's own "Auto" button: best 5 idle heroes by Rarity>Tier>Dps>Level),
-- Clear() + ToggleHero(instanceId) for a hand-picked team of 5,
-- RequestStartExpedition() -> C2S_ExpeditionStart {RequestId,
-- HeroInstanceIds, Duration}, RequestClaimExpedition() -> C2S_ExpeditionClaim
-- once EndsAt has passed. Hero instances sit in _state.Instances with
-- {InstanceId, Rarity 1-7, Tier, Level, Dps, Active}; Active ones are the
-- deployed party and are never sent. RequestFinishNow is a Robux product
-- (FinishProductId) and is never called -- the loop simply waits.
local function expeditionTeam(em, picks)
    local inst = em._state and em._state.Instances
    if type(inst) ~= "table" then return {} end
    local cand = {}
    for _, h in ipairs(inst) do
        if h.Active ~= true and picks[h.Rarity] and not em:IsHeroOnExpedition(h.InstanceId) then
            cand[#cand + 1] = h
        end
    end
    table.sort(cand, function(a, b)
        if (a.Rarity or 0) ~= (b.Rarity or 0) then return (a.Rarity or 0) > (b.Rarity or 0) end
        if (a.Tier or 0) ~= (b.Tier or 0) then return (a.Tier or 0) > (b.Tier or 0) end
        if (tonumber(a.Dps) or 0) ~= (tonumber(b.Dps) or 0) then return (tonumber(a.Dps) or 0) > (tonumber(b.Dps) or 0) end
        return (a.Level or 0) > (b.Level or 0)
    end)
    return cand
end
task.spawn(function()
    while getgenv().__TH == G do
        if e.thExpeditionEnabled then
            pcall(function()
                local S = SH()
                local em = S and S.ClientExpeditionManager
                if not em then stats.expedition = "manager n/a" return end
                local snap = em:GetSnapshot()
                if type(snap) ~= "table" then return end
                if not (snap.Loaded and snap.ServerLoaded) then
                    em:RequestData()
                    stats.expedition = "syncing"
                    return
                end
                if snap.CanClaim or snap.Status == "Completed" then
                    local ok = em:RequestClaimExpedition()
                    if ok then stats.expeditions += 1 stats.expedition = ("claimed (%d)"):format(stats.expeditions) end
                    return
                end
                if snap.Status == "Running" then
                    local left = tonumber(snap.RemainingSeconds) or 0
                    stats.expedition = ("running %s, %dh %02dm left"):format(tostring(snap.Duration), left // 3600, (left % 3600) // 60)
                    return
                end
                if snap.Status == "Claiming" or snap.Pending or snap.ClaimPending then return end
                if snap.Available ~= true then stats.expedition = "not available" return end
                -- idle: build the team and go
                em:SetDuration(e.thExpeditionDuration)
                local picks = {}
                for name, on in pairs(e.thExpeditionRarities) do if on and EXP_RARITY_ID[name] then picks[EXP_RARITY_ID[name]] = true end end
                local usedAuto = true
                if next(picks) then
                    local cand = expeditionTeam(em, picks)
                    if #cand >= 5 then
                        em:Clear()
                        for i = 1, 5 do em:ToggleHero(cand[i].InstanceId) end
                        usedAuto = false
                    end
                end
                if usedAuto then em:AutoSelect() end
                local snap2 = em:GetSnapshot()
                if snap2.Ready and snap2.CanStart ~= false then
                    local ok, why = em:RequestStartExpedition()
                    stats.expedition = ok and ("started %s (%s)"):format(tostring(e.thExpeditionDuration), usedAuto and "auto" or "picked")
                        or ("start refused: " .. tostring(why))
                else
                    stats.expedition = "team not ready"
                end
            end)
        end
        task.wait(20)
    end
end)

-- ---------------------------------------------------------------- Auto Buy Tap Frenzy (diamonds)
-- Store "Tap Frenzy" = product 3629007156 (GameSettings.TapFrenzy: +90s of
-- 20 auto-taps/s per buy, buys stack onto the timer). Diamond price comes
-- from ClientConfigManager.Product:Get(id).diamond (140 on this build);
-- C2S_BuyStoreUtilityWithDiamond(productId) is the store button. The live
-- timer is ClientPlayerManager:GetTapTempBuffs()["Product:TapFrenzy"]
-- .LeftTime -- re-bought when it drops under 5s (or is gone).
local FRENZY_PRODUCT = 3629007156
local function frenzyLeft()
    local S = SH()
    local pm = S and S.ClientPlayerManager
    if not pm then return nil end
    local ok, buffs = pcall(function() return pm:GetTapTempBuffs() end)
    local b = ok and type(buffs) == "table" and buffs["Product:TapFrenzy"] or nil
    return b and tonumber(b.LeftTime) or 0
end
local function frenzyPrice()
    local S = SH()
    local ok, p = pcall(function() return S.ClientConfigManager.Product:Get(FRENZY_PRODUCT) end)
    local price = ok and type(p) == "table" and tonumber(p.diamond) or nil
    return price or 140
end
task.spawn(function()
    while getgenv().__TH == G do
        if e.thFrenzyEnabled then
            pcall(function()
                local left = frenzyLeft()
                if left == nil then stats.frenzy = "manager n/a" return end
                local S = SH()
                local dia = 0
                pcall(function() dia = S.ClientPlayerManager:GetPlayerDiamond() or 0 end)
                local price = frenzyPrice()
                local floor = tonumber(e.thFrenzyMinDiamonds) or 0
                local underFloor = dia - price < floor
                if left > 5 then
                    stats.frenzy = ("%ds left (%d buys)%s"):format(left, stats.frenzyBuys,
                        underFloor and (" | next buy paused: keeping %d"):format(floor) or "")
                    return
                end
                if dia < price then stats.frenzy = ("need %d diamonds (have %d)"):format(price, dia) return end
                if underFloor then
                    stats.frenzy = ("paused: keeping %d diamonds (have %d, buy costs %d)"):format(floor, dia, price)
                    return
                end
                local ok, res = req(Msg.C2S_BuyStoreUtilityWithDiamond, FRENZY_PRODUCT)
                if ok and res ~= false then
                    stats.frenzyBuys += 1
                    stats.frenzy = ("bought (%d)"):format(stats.frenzyBuys)
                    task.wait(3)
                else
                    stats.frenzy = "buy refused"
                end
            end)
        end
        task.wait(5)
    end
end)

-- ---------------------------------------------------------------- Auto Rebirth
-- C2S_TapRequestRebirthInfo -> S2C_TapRebirthInfo {CanRebirth, Stage,
-- HighestStage, TotalHeroLevel, NeedHeroLevel, RebirthCount}; the confirm
-- button is C2S_TapConfirmRebirth (no args), result on S2C_TapRebirthResult.
-- Gated on the game's own CanRebirth AND a minimum current Stage so a run
-- isn't reset the moment the hero-level requirement is met.
task.spawn(function()
    while getgenv().__TH == G do
        if e.thRebirthEnabled then
            pcall(function()
                req(Msg.C2S_TapRequestRebirthInfo)
                task.wait(0.7)
                local info = latest[Msg.S2C_TapRebirthInfo] and latest[Msg.S2C_TapRebirthInfo][1]
                if type(info) ~= "table" then stats.rebirth = "no info" return end
                local stage = tonumber(info.Stage) or 0
                local minStage = tonumber(e.thRebirthMinStage) or 0
                if not info.CanRebirth then
                    stats.rebirth = ("not ready (hero lv %s / need %s)"):format(tostring(info.TotalHeroLevel), tostring(info.NeedHeroLevel))
                elseif stage < minStage then
                    stats.rebirth = ("waiting for stage %d (now %d)"):format(minStage, stage)
                else
                    local ok, res = req(Msg.C2S_TapConfirmRebirth)
                    task.wait(1)
                    local r = latest[Msg.S2C_TapRebirthResult] and latest[Msg.S2C_TapRebirthResult][1]
                    if ok and res ~= false then
                        stats.rebirths += 1
                        stats.rebirth = ("rebirthed (%d)%s"):format(stats.rebirths, type(r) == "table" and r.Info and (" count=" .. tostring(r.Info.RebirthCount)) or "")
                    else
                        stats.rebirth = "refused"
                    end
                end
            end)
        end
        task.wait(10)
    end
end)

-- ---------------------------------------------------------------- Auto Sky Chest
-- S2C_TapSkyChestSpawn {ChestUid, ...} announces the flying chest; the
-- game's own click handler is C2S_TapHitSkyChest(ChestUid) once per tap.
-- Hit it every 0.2s from the spawn event until S2C_TapSkyChestRemoved /
-- Reward lands (or 80 hits, whichever first).
local chestGen = 0
local function hitChest(uid)
    chestGen += 1
    local myGen = chestGen
    local hits = 0
    task.spawn(function()
        while getgenv().__TH == G and e.thSkyChestEnabled and chestGen == myGen and hits < 80 do
            local S = SH()
            local mgr = S and S.ClientSkyChestManager
            if mgr and mgr.ActiveChest == nil then break end
            local ok, res = req(Msg.C2S_TapHitSkyChest, uid)
            if not ok or res == false then break end
            hits += 1
            stats.chestHits += 1
            task.wait(0.2)
        end
    end)
end
sn.OnClientEvent:Connect(function(payload)
    if getgenv().__TH ~= G then return end
    local m = payload and payload[1]
    if not (m and m.msgID) then return end
    if m.msgID == Msg.S2C_TapSkyChestSpawn and e.thSkyChestEnabled then
        local d = m.msgData and m.msgData[1]
        local uid = type(d) == "table" and d.ChestUid or d
        if uid then hitChest(uid) end
    elseif m.msgID == Msg.S2C_TapSkyChestRemoved then
        chestGen += 1
    elseif m.msgID == Msg.S2C_TapSkyChestReward then
        stats.chests += 1
        chestGen += 1
    elseif m.msgID == Msg.S2C_OfflineRewardData and e.thExtrasEnabled then
        -- the free "claim" path of the offline-reward popup (the paid
        -- multiplier is a Robux product and is never touched)
        task.delay(1, function() if req(Msg.C2S_ClaimOfflineReward) then stats.extras += 1 stats.extrasNote = "offline reward" end end)
    end
end)
task.spawn(function()
    -- a chest already up when the script loads
    task.wait(2)
    local S = SH()
    local mgr = S and S.ClientSkyChestManager
    local c = mgr and mgr.ActiveChest
    if c and c.ChestUid and e.thSkyChestEnabled then hitChest(c.ChestUid) end
end)

-- ---------------------------------------------------------------- Auto Equip Best Heroes
-- C2S_TapAutoEquipHeroes is the Heroes tab's "Auto" deploy button (server
-- picks the party). Re-run every minute so new recruits get slotted.
task.spawn(function()
    while getgenv().__TH == G do
        if e.thEquipBestEnabled then req(Msg.C2S_TapAutoEquipHeroes) end
        task.wait(60)
    end
end)

-- ---------------------------------------------------------------- Auto Claim Extras
-- Online gift (ClientOnlineGiftManager.State {Claimed, ReadyAtServerTime}
-- -> C2S_ClaimOnlineGift), seven-day login gift (GetLoginRewardInfo()
-- {RewardsCanClaimed[i], RewardsClaimed[i]} -> C2S_ClaimSevenDayGift(i)),
-- mail attachments (C2S_MailRequestData -> S2C_MailData {Mails} ->
-- C2S_MailClaim(id)). Offline reward is handled on its data event above.
task.spawn(function()
    while getgenv().__TH == G do
        if e.thExtrasEnabled then
            pcall(function()
                local S = SH()
                if not S then return end
                local og = S.ClientOnlineGiftManager
                if og and type(og.State) == "table" and og.State.Claimed ~= true and og.GetRemaining and og:GetRemaining() <= 0 then
                    if req(Msg.C2S_ClaimOnlineGift) then stats.extras += 1 stats.extrasNote = "online gift" end
                end
                local sd = S.ClientSevenDayManager
                local info = sd and sd.GetLoginRewardInfo and sd:GetLoginRewardInfo()
                if type(info) == "table" then
                    local can, done = info.RewardsCanClaimed or {}, info.RewardsClaimed or {}
                    for i = 1, 7 do
                        if can[i] == true and done[i] ~= true then
                            if req(Msg.C2S_ClaimSevenDayGift, i) then stats.extras += 1 stats.extrasNote = "7-day gift " .. i end
                            task.wait(0.5)
                        end
                    end
                end
                req(Msg.C2S_MailRequestData)
                task.wait(1)
                local md = latest[Msg.S2C_MailData] and latest[Msg.S2C_MailData][1]
                local mails = type(md) == "table" and md.Mails
                if type(mails) == "table" then
                    for _, mail in pairs(mails) do
                        if type(mail) == "table" then
                            local id = mail.Id or mail.MailId or mail.Uid or mail.id
                            local has = mail.Attachments or mail.Rewards or mail.Items or mail.HasAttachment
                            if id and has and mail.Claimed ~= true and mail.Status ~= "Claimed" then
                                if req(Msg.C2S_MailClaim, id) then stats.extras += 1 stats.extrasNote = "mail" end
                                task.wait(0.5)
                            end
                        end
                    end
                end
            end)
        end
        task.wait(60)
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
L:Toggle({
    Name="Auto Use Skills",
    Default=e.thSkillsEnabled,
    Callback=function(v) e.thSkillsEnabled=v; sv() end
}, "thSkillsEnabled")

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
L:Toggle({
    Name="Auto Reserve",
    Default=e.thReserveEnabled,
    Callback=function(v) e.thReserveEnabled=v; sv() end
}, "thReserveEnabled")
L:Dropdown({
    Name="Reserve Rarity", Multi=true, Search=false,
    Options={"Common","Uncommon","Rare","Epic","Legendary","Mythic","Mythic+"},
    Default=setToArray(e.thReserveQualities),
    Callback=function(sel)
        local set={}
        for name in pairs(sel) do set[name]=true end
        e.thReserveQualities=set; sv()
    end,
}, "thReserveQualities")

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

L:Header({Text="Expedition"})
L:Toggle({
    Name="Auto Expedition (claim + restart loop)",
    Default=e.thExpeditionEnabled,
    Callback=function(v) e.thExpeditionEnabled=v; sv() end
}, "thExpeditionEnabled")
L:Dropdown({
    Name="Expedition Rarities (empty = Auto Select Best)", Multi=true, Search=false,
    Options=EXP_RARITY_NAMES, Default=setToArray(e.thExpeditionRarities),
    Callback=function(sel)
        local set={}
        for name in pairs(sel) do set[name]=true end
        e.thExpeditionRarities=set; sv()
    end,
}, "thExpeditionRarities")
local EXP_DUR_LABELS = {}
for i, d in ipairs(EXP_DURATIONS) do EXP_DUR_LABELS[i] = d[1] end
local function expDurIndex()
    for i, d in ipairs(EXP_DURATIONS) do if d[2] == e.thExpeditionDuration then return i end end
    return 2
end
L:Dropdown({
    Name="Expedition Duration", Multi=false, Required=true,
    Options=EXP_DUR_LABELS, Default=expDurIndex(),   -- single-select Default is an INDEX
    Callback=function(v)
        local picked = type(v)=="table" and v[1] or v
        for _, d in ipairs(EXP_DURATIONS) do
            if d[1] == picked then e.thExpeditionDuration = d[2]; sv() end
        end
    end,
}, "thExpeditionDuration")
L:Label({Text="Picks the 5 best idle heroes of the chosen rarities (or the\ngame's own Auto Select when nothing is picked), starts the run,\nclaims it when the timer ends and starts the next one."})

L:Header({Text="Store"})
L:Toggle({
    Name="Auto Buy Tap Frenzy (diamonds, 90s each)",
    Default=e.thFrenzyEnabled,
    Callback=function(v) e.thFrenzyEnabled=v; sv() end
}, "thFrenzyEnabled")
L:Input({
    Name="Keep At Least (diamonds)", Placeholder="0 = spend everything",
    Default=tostring(e.thFrenzyMinDiamonds),
    AcceptedCharacters=function(t) return (tostring(t):gsub("%D", "")) end,
    -- MacLib fires Callback only on FocusLost (Enter / click away); a value
    -- typed and then left alone never reached it. onChanged fires per
    -- keystroke, so the number is live and saved as it is typed.
    onChanged=function(t)
        e.thFrenzyMinDiamonds = tonumber(t) or 0
        sv()
    end,
    Callback=function(t)
        e.thFrenzyMinDiamonds = tonumber(t) or 0
        sv()
    end,
}, "thFrenzyMinDiamonds")
L:Label({Text="Re-buys the moment the Frenzy timer runs out (opt-in: spends\ndiamonds every ~90s). Buying pauses by itself once a buy would\ndrop diamonds under the number above, and resumes on its own\nwhen you have that much plus one buy again."})

L:Header({Text="Rebirth"})
L:Toggle({
    Name="Auto Rebirth",
    Default=e.thRebirthEnabled,
    Callback=function(v) e.thRebirthEnabled=v; sv() end
}, "thRebirthEnabled")
local REBIRTH_STAGE_OPTIONS, REBIRTH_STAGE_LEVELS = {"As soon as allowed"}, {0}
for lv = 10, 1000, 10 do
    REBIRTH_STAGE_OPTIONS[#REBIRTH_STAGE_OPTIONS + 1] = ("Stage %d"):format(lv)
    REBIRTH_STAGE_LEVELS[#REBIRTH_STAGE_LEVELS + 1] = lv
end
local function rebirthStageIndex(level)
    for i, lv in ipairs(REBIRTH_STAGE_LEVELS) do if lv == level then return i end end
    return 1
end
L:Dropdown({
    Name="Rebirth At Stage", Multi=false, Required=true, Search=true,
    Options=REBIRTH_STAGE_OPTIONS, Default=rebirthStageIndex(e.thRebirthMinStage),
    Callback=function(v)
        local picked = type(v)=="table" and v[1] or v
        if type(picked) ~= "string" then return end
        e.thRebirthMinStage = tonumber(picked:match("%d+")) or 0
        sv()
    end,
}, "thRebirthMinStage")
L:Label({Text="Fires only when the game reports CanRebirth AND the current\nstage is at or past the pick."})

local R = Tabs.Farm:Section({Side="Right"})
R:Header({Text="Extras"})
R:Toggle({
    Name="Auto Sky Chest",
    Default=e.thSkyChestEnabled,
    Callback=function(v) e.thSkyChestEnabled=v; sv() end
}, "thSkyChestEnabled")
R:Toggle({
    Name="Auto Equip Best Heroes",
    Default=e.thEquipBestEnabled,
    Callback=function(v) e.thEquipBestEnabled=v; sv() end
}, "thEquipBestEnabled")
R:Toggle({
    Name="Auto Claim Online / 7-Day / Mail / Offline",
    Default=e.thExtrasEnabled,
    Callback=function(v) e.thExtrasEnabled=v; sv() end
}, "thExtrasEnabled")
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
                "Skills used: %d\n" ..
                "Recruits: %d\n" ..
                "Upgrades: %d\n" ..
                "Dungeon: %s\n" ..
                "Daily: %s\n" ..
                "Achievements: %d\n" ..
                "Expedition: %s\n" ..
                "Tap Frenzy: %s\n" ..
                "Rebirth: %s\n" ..
                "Sky chests: %d (%d hits) | Extras: %d (%s)"
            ):format(rate, stats.taps, stats.boss, stats.skills, stats.recruits, stats.upgrades,
                     stats.dungeon, stats.daily, stats.achievements,
                     stats.expedition, stats.frenzy, stats.rebirth, stats.chests, stats.chestHits, stats.extras, stats.extrasNote))
        end)
    end
end)

W.onUnloaded(function() print("[TapborneHeroes] Unloaded") end)
Tabs.Farm:Select()
print("[TapborneHeroes] UI ready — tap loops: " .. TAP_LOOPS)
