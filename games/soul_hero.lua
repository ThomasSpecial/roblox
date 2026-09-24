-- [IDLE] Soul Hero [Quez Clan, placeId 99388466709359] -- farm/orbit/inventory automation + UI
--
-- Verified live against the actual game (2026-09-23), account papiyongz1:
--   - Clean, plainly-named remotes under workspace.Network (unlike every
--     other game automated in this repo so far, none of this one's client
--     scripts are readable either -- script-grep/semantic-search both
--     returned 0 matches -- but the remote NAMES here are descriptive
--     enough that reading scripts was never needed).
--   - Combat is server-authoritative on POSITION, not just on the attack
--     call: PlayerWeaponAttackRequested-RemoteEvent:FireServer(enemyId)
--     answers CombatHitRejected with reason="target_out_of_range" unless
--     the character's real HumanoidRootPart is genuinely close. A one-shot
--     hrp.CFrame teleport-jump right next to a target got silently
--     reverted by the server within a tick (same pattern as every other
--     "server owns position" game this session) -- confirmed live, distance
--     read back ~12.8 studs after setting it to ~4. Smooth per-frame CFrame
--     deltas (an actual orbit loop, not a jump) fly under whatever anti-
--     teleport check caught the jump -- this is the standard, working
--     technique for this exact "fly around and farm" genre, and Orbit below
--     is built on it deliberately instead of Humanoid:MoveTo.
--   - Enemies are per-player-instanced: GetEnemyLedgerEntries-RemoteFunction
--     (no args) returns each live enemy as {enemyId, archetypeId, hp={max,
--     current}, state, ownerUserId, resolvedCoinAmount, ...} -- ownerUserId
--     matched this account's own UserId, confirming these are this
--     account's own personal mob instances, not shared/contested. Match an
--     entry's archetypeId against workspace.Game.Enemies' model Names to
--     find its real Position (the ledger itself carries no position field).
--   - Boss-type enemies exist in the same Enemies folder and ARE returned by
--     the ledger, but attacking one before its intro plays answers
--     CombatHitRejected reason="BossIntroPending" -- confirmed live by
--     accidentally wandering next to one. Auto Farm Mob below explicitly
--     skips anything the ledger doesn't report hp on (bosses reliably
--     didn't in testing) rather than trying to also drive the separate boss-
--     intro/encounter flow, which is a different system
--     (RequestBossAction-RemoteFunction, GetBossEncounterState-RemoteFunction)
--     out of scope for a basic farm loop.
--   - Coins: GetDropGroups-RemoteFunction (no args) lists every live coin
--     pile as {dropGroupId, dropType="Coins", remainingAmount,
--     remainingSlices, ...} -- no position field either, and
--     ClaimDropSlice-RemoteFunction(dropGroupId) is ALSO range-gated
--     (confirmed live: {ok=false, reason="out_of_range"} on a distant
--     pile). "Instant" here means never walking to a coin pile on purpose --
--     Auto Collect just retries every known dropGroupId every cycle, and it
--     silently starts succeeding the moment Orbit's own movement happens to
--     bring the character close, same soft-no-until-in-range pattern this
--     whole session has used for everything position-gated.
--   - EquipBestUnits-RemoteFunction and MaxBuySkillTreeNodes-RemoteFunction
--     both confirmed live as complete, no-argument, server-decides-what's-
--     best/affordable actions -- MaxBuy bought 13 nodes in one call in
--     testing. Neither needs any client-side "what's best" logic at all.
--   - ClaimQuestReward-RemoteFunction(questId) confirmed live: an
--     already-claimed quest answers {ok=false, reason="invalid_request"}
--     cleanly, matching the shape GetQuestState-RemoteFunction's per-quest
--     {id, completed, claimed} fields predict. ClaimAllHeroIndexRewards-
--     RemoteFunction batches every hero-index reward in one no-arg call
--     (confirmed: {ok=false, reason="nothing_to_claim"} when there's
--     nothing pending -- clean soft-no). Enemy-index rewards have no
--     equivalent batch call or listing remote found this session
--     (ClaimEnemyIndexReward-RemoteFunction exists but needs a specific id
--     with no matching Get*State remote to source ids from) -- left out
--     rather than guessing ids blindly.
--   - GetRebirthState-RemoteFunction's canRebirth boolean is confirmed
--     present and read live (true on this account already, unlocked with
--     coins=1354, level=15). AttemptRebirth-RemoteFunction was NOT actually
--     fired during testing (resets real run progress -- not something to
--     trigger just to confirm a call shape) -- wired here on the same
--     no-argument convention every other confirmed action remote in this
--     game follows (EquipBestUnits, MaxBuySkillTreeNodes,
--     ClaimAllHeroIndexRewards), gated on canRebirth so it only ever fires
--     when the game itself says the account is ready for it.

getgenv().__SH = (getgenv().__SH or 0) + 1
local G = getgenv().__SH
pcall(function() if getgenv().__SHW then getgenv().__SHW:Unload() end end)
local e = getgenv()
local myUID = tostring(math.random(1, 2 ^ 30))
e.__shTok = myUID
print("[SoulHero] Starting (gen " .. G .. ")...")

local SOUL_HERO = 99388466709359
if game.PlaceId ~= SOUL_HERO then print("[SoulHero] Wrong place, aborting") return end

local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local plr = Players.LocalPlayer

local net = workspace:WaitForChild("Network", 10)
if not net then print("[SoulHero] Network folder not found, aborting") return end

local function call(name, ...)
	local args = {...}
	local remote = net:FindFirstChild(name)
	if not remote then return false, "missing:" .. name end
	return pcall(function() return remote:InvokeServer(table.unpack(args)) end)
end
local function fire(name, ...)
	local args = {...}
	local remote = net:FindFirstChild(name)
	if not remote then return false end
	return pcall(function() remote:FireServer(table.unpack(args)) end)
end

-- ---------------------------------------------------------------- state/config
local SF = "SoulHero/state.json"
local SK = {
	"shFarmEnabled", "shM1Enabled", "shM1Interval", "shCollectEnabled",
	"shOrbitEnabled", "shOrbitMode", "shOrbitSpeed", "shOrbitHeight", "shOrbitDistance",
	"shEquipBestEnabled", "shSkillTreeEnabled",
	"shQuestEnabled", "shIndexEnabled", "shRebirthEnabled", "shNextStageEnabled",
	"shLoopLevelEnabled", "shLoopLevel", "shSkipAnim", "shUpgradePriority", "shUpgradeOrder", "shUpgradeRest",
	"shRebirthMinLevel",
	"shWorldBossEnabled", "shWorldBossPick",
	"shEvolveHeroEnabled", "shHatchEnabled", "shHatchEggs", "shSkipIntroServer", "shDefeatContinue",
	"shWbTitleId", "shFarmTitleId",
	"shAntiAFK", "shAutoReconnect",
}
pcall(function() if not isfolder("SoulHero") then makefolder("SoulHero") end end)
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

if e.shFarmEnabled == nil then e.shFarmEnabled = true end
if e.shM1Enabled == nil then e.shM1Enabled = true end
-- Default 0.01 by request. Note this does NOT mean 100 hits/s: the weapon's
-- own cooldown (PlayerWeaponCooldownSeconds attribute, 0.75 on the starter
-- sword) still gates how often the server accepts a swing -- Tool:Activate()
-- calls landing inside the cooldown are simply ignored. Hammering it this
-- fast just guarantees a swing fires the instant the cooldown clears rather
-- than up to one interval late. Client-side cost of the spam is negligible.
if e.shM1Interval == nil then e.shM1Interval = 0.01 end
if e.shCollectEnabled == nil then e.shCollectEnabled = true end
if e.shOrbitEnabled == nil then e.shOrbitEnabled = true end
if e.shOrbitMode == nil then e.shOrbitMode = "On Foot" end
if e.shOrbitSpeed == nil then e.shOrbitSpeed = 60 end
if e.shOrbitHeight == nil then e.shOrbitHeight = 4 end
if e.shOrbitDistance == nil then e.shOrbitDistance = 6 end
if e.shEquipBestEnabled == nil then e.shEquipBestEnabled = true end
if e.shSkillTreeEnabled == nil then e.shSkillTreeEnabled = true end
if e.shQuestEnabled == nil then e.shQuestEnabled = true end
if e.shIndexEnabled == nil then e.shIndexEnabled = true end
if e.shRebirthEnabled == nil then e.shRebirthEnabled = true end
if type(e.shRebirthMinLevel) ~= "number" then e.shRebirthMinLevel = 0 end   -- 0 = rebirth as soon as the game allows
if e.shWorldBossEnabled == nil then e.shWorldBossEnabled = true end
-- Which world bosses to drop everything for, by display name (Mink / Lonku /
-- Zephyr). Stored as an ARRAY of names -- the shape MacLib's multi-select
-- Default wants back -- not a {name=true} set.
if type(e.shWorldBossPick) ~= "table" then e.shWorldBossPick = {"Mink", "Lonku", "Zephyr"} end
if e.shEvolveHeroEnabled == nil then e.shEvolveHeroEnabled = true end
if e.shHatchEnabled == nil then e.shHatchEnabled = true end
if type(e.shHatchEggs) ~= "table" then e.shHatchEggs = {} end   -- empty = "any egg, highest zone first"
if e.shSkipIntroServer == nil then e.shSkipIntroServer = true end
if e.shDefeatContinue == nil then e.shDefeatContinue = true end
if type(e.shWbTitleId) ~= "string" then e.shWbTitleId = "" end       -- "" = leave the title alone
if type(e.shFarmTitleId) ~= "string" then e.shFarmTitleId = "" end
if e.shNextStageEnabled == nil then e.shNextStageEnabled = true end
if e.shLoopLevelEnabled == nil then e.shLoopLevelEnabled = false end
if type(e.shLoopLevel) ~= "number" then e.shLoopLevel = 1 end
if e.shSkipAnim == nil then e.shSkipAnim = true end
if type(e.shUpgradePriority) ~= "table" then e.shUpgradePriority = {} end
-- Ordered priority list (labels, slot 1 first). Replaces the unordered
-- multi-select set: a set can't express "Damage first, THEN Coin", which is
-- exactly what was asked for. Migrates once from the old set (in list
-- order) so nothing already ticked is lost.
if type(e.shUpgradeOrder) ~= "table" then e.shUpgradeOrder = {} end
-- (the one-time migration from the old set lives below SKILL_FAMILIES,
-- which isn't defined yet at this point in the file)
if e.shUpgradeRest == nil then e.shUpgradeRest = true end

-- Skill-tree families, as the server names them (rankByFamily keys from
-- GetSkillTreeState-RemoteFunction, read live). Node ids are family..rank,
-- so the next purchasable node of a family is family .. (rankByFamily+1)
-- -- confirmed: PurchaseSkillTreeNode("coinIncome4") with rank 3 answered
-- {ok=false, error="NotEnoughCoins"} (a valid id, just unaffordable), and a
-- made-up id answered error="UnknownNode". Order here is the order the
-- priority list is walked in each pass.
local SKILL_FAMILIES = {
	{"Player Damage", "playerDamage"}, {"Hero Damage", "heroDamage"}, {"Coin Income", "coinIncome"},
	{"Soul Income", "soulIncome"}, {"Magnetic Riches", "magneticRiches"}, {"Player Health", "playerHealth"},
	{"Hero Health", "heroHealth"}, {"Player Recovery", "playerRecovery"}, {"Hero Recovery", "heroRecovery"},
	{"Hero Attack Speed", "heroAttackSpeed"}, {"Player Speed", "playerSpeed"}, {"Enemy Capacity", "enemyCapacity"},
	{"Larger Horde", "largerHorde"}, {"Elite Enemies", "eliteEnemies"}, {"Enemy Rush", "enemyRush"},
	{"Hunter's Mark", "huntersMark"}, {"Momentum Rush", "momentumRush"}, {"Battle Frenzy", "battleFrenzy"},
	{"Cleaving Strikes", "cleavingStrikes"}, {"Shockwave Slam", "shockwaveSlam"}, {"Arcane Burst", "arcaneBurst"},
	{"Chain Lightning", "chainLightning"}, {"Longshot", "longshot"}, {"Juggernaut", "juggernaut"},
	{"Empowered Summons", "empoweredSummons"},
}
local SKILL_LABEL_TO_FAMILY, SKILL_LABELS = {}, {}
for i, pair in ipairs(SKILL_FAMILIES) do SKILL_LABEL_TO_FAMILY[pair[1]] = pair[2] SKILL_LABELS[i] = pair[1] end

-- MacLib's multi-Dropdown Default wants an ARRAY of selected option names,
-- not a {name=true} set (learned the hard way in the Tapborne Heroes
-- script: feeding it the set silently dropped entries). Loops keep the set
-- shape for O(1) membership; convert only at the one spot MacLib reads it.
local function setToArray(set)
	local arr = {}
	for k, v in pairs(set) do if v then arr[#arr + 1] = k end end
	return arr
end

-- One-time migration: anything ticked in the old unordered "Upgrade
-- Priority" set becomes the initial ordered list (in SKILL_FAMILIES order),
-- so nothing already chosen is lost when the UI switched to ranked slots.
if #e.shUpgradeOrder == 0 and next(e.shUpgradePriority) ~= nil then
	for _, pair in ipairs(SKILL_FAMILIES) do
		if e.shUpgradePriority[pair[1]] then e.shUpgradeOrder[#e.shUpgradeOrder + 1] = pair[1] end
	end
end
local PRIORITY_SLOTS = 5
local PRIORITY_OPTIONS = {"None"}
for _, label in ipairs(SKILL_LABELS) do PRIORITY_OPTIONS[#PRIORITY_OPTIONS + 1] = label end
-- keep the slot array fixed-length ("None" = empty) -- see the slot callback
for i = 1, PRIORITY_SLOTS do
	if type(e.shUpgradeOrder[i]) ~= "string" then e.shUpgradeOrder[i] = "None" end
end
if e.shAntiAFK == nil then e.shAntiAFK = true end
if e.shAutoReconnect == nil then e.shAutoReconnect = true end

local stats = {hits = 0, collected = 0, equips = 0, skillNodes = 0, quests = 0, index = 0, rebirths = 0, rebirthNote = "-", target = "-", worldBoss = "-", worldBosses = 0,
	evolveStarts = 0, evolveClaims = 0, evolveNote = "-", hatchStarts = 0, hatchClaims = 0, hatchNote = "-", defeats = 0}

-- Set while the World Boss routine is moving the character between areas
-- (join / return / portal walk). Orbit writes hrp.CFrame every frame and
-- would fight the server's own teleport into the arena, so it stands down
-- while this is up.
local wbHold = false
-- os.clock() deadline: while in the future, orbit must not write the
-- character's CFrame. Set by the placement watchdog whenever the server is
-- moving the character itself (zone change, area change, respawn) -- see
-- the "Placement / fall watchdog" section for why fighting that teleport
-- is exactly how the character ended up falling out of the map.
local placementHoldUntil = 0
-- Active combat zone geometry. workspace.ZoneWorld.Zone<n>.PlayBox holds
-- InvisibleBarriers (Floor 120x2x120 + four 75-stud walls) and a
-- CombatSpawn part -- but ONLY for the zone the player is currently in;
-- the other zones' folders are empty, and every zone sits at completely
-- different world coordinates (Zone4 floor at 40000,19,10001; Zone5 spawn
-- at 10000,23,20001). "Zone" is the live player attribute.
local function zonePlayBox()
	local zw = workspace:FindFirstChild("ZoneWorld")
	local z = zw and zw:FindFirstChild("Zone" .. tostring(plr:GetAttribute("Zone")))
	return z and z:FindFirstChild("PlayBox")
end
local function zoneFloor()
	local pb = zonePlayBox()
	local ib = pb and pb:FindFirstChild("InvisibleBarriers")
	local f = ib and ib:FindFirstChild("Floor")
	return (f and f:IsA("BasePart")) and f or nil
end
local function zoneSpawn()
	local pb = zonePlayBox()
	local cs = pb and pb:FindFirstChild("CombatSpawn")
	if cs and cs:IsA("BasePart") then return cs.Position + Vector3.new(0, 3, 0) end
	local f = zoneFloor()
	return f and (f.Position + Vector3.new(0, 4, 0)) or nil
end
-- The arena's own enemy folder once found (the boss model lives wherever
-- the game parents it; discovered by EnemyId attribute, see the World Boss
-- section). nil outside the arena.
local arenaFolder = nil

-- ---------------------------------------------------------------- shared target tracking
-- Auto Farm Mob, Auto M1, and Orbit all need "which enemy, and where is it"
-- -- computed once here every 1s and shared, instead of three separate loops
-- each re-deriving it (and re-InvokeServer'ing the ledger) independently.
local currentTarget = nil   -- {enemyId, part, position}

-- Which part of an enemy model to orbit/face. `FindFirstChildWhichIsA(
-- "BasePart", true)` -- the original choice -- is descendant order, not
-- anatomy: on the level-35 boss (zone4_a2) it returns "Plane", a sprite
-- hanging at Y=40.7, while the body (PrimaryPart "RootPart", 6x6x3) stands
-- at Y=20.0. Orbit then circled ~20 studs above anything hittable and the
-- weapon (Range 10.5) silently found nothing -- 0 hits AND 0 rejections
-- across every distance/height combo tried, versus 15 hits in 8s the
-- moment RootPart was targeted instead (measured live, same boss, seconds
-- apart). Lower bosses only looked fine because their first BasePart
-- happened to sit at body height. Priority: PrimaryPart, then a part named
-- RootPart/HumanoidRootPart, then the lowest non-flat part (covers pure
-- billboard models), then the old first-BasePart fallback.
local function bodyPartOf(model)
	if model.PrimaryPart then return model.PrimaryPart end
	local named = model:FindFirstChild("RootPart", true) or model:FindFirstChild("HumanoidRootPart", true)
	if named and named:IsA("BasePart") then return named end
	local best, bestY
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and not d.Name:lower():find("plane") then
			local s = d.Size
			local flat = math.min(s.X, s.Y, s.Z) < 0.2 and math.max(s.X, s.Y, s.Z) > 8
			if not flat and (not bestY or d.Position.Y < bestY) then best, bestY = d, d.Position.Y end
		end
	end
	return best or model:FindFirstChildWhichIsA("BasePart", true)
end

-- Target selection is fully client-side and event-driven -- no remote in
-- the hot path. Measured live (2026-09-24, level 70, ~1.1s per kill): the
-- moment a mob dies the game DESTROYS its model out of
-- workspace.Game.Enemies in the same tick its CombatState flips to Idle,
-- and the next mob's model was already parented 0.3-0.7s BEFORE that. So
-- "model is in the folder" == "alive", and every model carries the ledger
-- ids as attributes (EnemyId="enemy_1470", ArchetypeId="zone3_a1",
-- Name="Cryb") plus a HealthBarBillboard whose HealthLeft frame's X scale
-- is the hp fraction. The old GetEnemyLedgerEntries-RemoteFunction poll
-- (1s, plus a server round-trip) was the entire A->B delay; ChildRemoved
-- on the folder fires the retarget in the same frame the kill lands.
local enemiesFolder = nil
local function hpFractionOf(model)
	local hl = model:FindFirstChild("HealthLeft", true)
	return hl and hl:IsA("GuiObject") and hl.Size.X.Scale or 1
end

local function refreshTarget()
	if not (enemiesFolder and enemiesFolder.Parent) then currentTarget = nil stats.target = "-" return end
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then currentTarget = nil return end

	local best, bestDist, bestPart
	for _, m in ipairs(enemiesFolder:GetChildren()) do
		local enemyId = m:GetAttribute("EnemyId")
		if enemyId and hpFractionOf(m) > 0 then
			local part = bodyPartOf(m)
			if part then
				local d = (hrp.Position - part.Position).Magnitude
				if not bestDist or d < bestDist then
					best, bestDist, bestPart = m, d, part
				end
			end
		end
	end

	if best then
		local id = best:GetAttribute("EnemyId")
		if not (currentTarget and currentTarget.enemyId == id) then
			currentTarget = {enemyId = id, part = bestPart, position = bestPart.Position}
			stats.target = tostring(best:GetAttribute("Name") or best:GetAttribute("ArchetypeId") or best.Name)
			e.__shTargetId = id   -- exposed for live probes only (currentTarget itself is local)
		end
	else
		currentTarget = nil
		stats.target = "-"
		e.__shTargetId = nil
	end
end

local function retargetNow()
	if e.shFarmEnabled or e.shOrbitEnabled then pcall(refreshTarget) end
end

local function bindEnemiesFolder(folder)
	enemiesFolder = folder
	folder.ChildAdded:Connect(function()
		if getgenv().__SH ~= G then return end
		-- a spawn only matters when we have nothing to hit; otherwise the
		-- nearest-mob pick stays put until the current one actually dies
		if not currentTarget then retargetNow() end
	end)
	folder.ChildRemoved:Connect(function(m)
		if getgenv().__SH ~= G then return end
		if currentTarget and m:GetAttribute("EnemyId") == currentTarget.enemyId then
			currentTarget = nil
			retargetNow()
		end
	end)
	retargetNow()
end

task.spawn(function()
	-- the Game/Enemies folder is rebuilt on area transitions (Lobby <->
	-- Combat), so keep re-binding to whichever instance is current
	while getgenv().__SH == G do
		local gameFolder = workspace:FindFirstChild("Game")
		local folder = gameFolder and gameFolder:FindFirstChild("Enemies")
		-- inside the world-boss arena, follow the arena's folder instead
		if arenaFolder and arenaFolder.Parent and plr:GetAttribute("PlayerArea") == "ServerBoss" then
			folder = arenaFolder
		end
		if folder and folder ~= enemiesFolder then bindEnemiesFolder(folder) end
		-- 0.1s backstop only: catches a target whose hp bar hits 0 without
		-- the model leaving yet, and the nearest-mob re-pick when the
		-- character moves. The real switch is the ChildRemoved above.
		if enemiesFolder and (e.shFarmEnabled or e.shOrbitEnabled) then
			if currentTarget == nil then
				retargetNow()
			else
				-- IsDescendantOf, not just p.Parent: when the whole Game/Enemies
				-- folder is swapped on an area change the old model is detached
				-- as a tree, so its parts still HAVE a parent (the dead model)
				-- and a Parent check alone kept a ghost target alive.
				local p = currentTarget.part
				if not (p and p:IsDescendantOf(enemiesFolder)) or hpFractionOf(p.Parent) <= 0 then
					currentTarget = nil
					retargetNow()
				end
			end
		end
		task.wait(0.1)
	end
end)

-- ---------------------------------------------------------------- Orbit
-- Flies the character in a circle around the current target instead of
-- walking -- keeps attack range satisfied continuously without needing
-- pathfinding, and is what actually gets Auto M1 close enough to land hits
-- in the first place. "On Head" orbits above the target (shOrbitHeight adds
-- on top of the target's own height); "On Foot" orbits at roughly ground
-- level next to it (shOrbitHeight is a small clearance instead).
--
-- First version just set hrp.CFrame on RenderStepped and looked visibly
-- wrong -- the Humanoid's own walk/fall state machine was still fully
-- active underneath and kept fighting the CFrame every frame (gravity
-- pulling it back down, ground friction resisting the horizontal motion),
-- producing jitter instead of a clean circle. Fixed by actually taking the
-- character out of normal movement while orbiting is active:
--   - Humanoid.PlatformStand = true suspends the walk/fall state machine
--     entirely so nothing is fighting the CFrame writes.
--   - HumanoidRootPart.CanCollide = false so flying through terrain/props
--     near the target doesn't snag on them.
--   - AssemblyLinearVelocity/AssemblyAngularVelocity zeroed every frame so
--     no leftover physics momentum accumulates into drift.
--   - RunService.Heartbeat instead of RenderStepped -- runs after physics
--     simulation each step, the correct place for CFrame writes that need
--     to stick (RenderStepped can visibly fight with that step on some
--     frames).
-- Both flags get restored to normal (PlatformStand = false, CanCollide =
-- true) the moment orbiting stops, so walking/falling works normally again
-- as soon as the toggle's off or no target is available.
local orbitAngle = 0
local orbitFlying = false
local function setOrbitFlight(hrp, hum, flying)
	if orbitFlying == flying then return end
	orbitFlying = flying
	hum.PlatformStand = flying
	hrp.CanCollide = not flying
end

RunService.Heartbeat:Connect(function(dt)
	if getgenv().__SH ~= G then return end
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChild("Humanoid")
	if not (hrp and hum) then return end

	local shouldFly = e.shOrbitEnabled and currentTarget ~= nil and not wbHold and os.clock() >= placementHoldUntil
	if not shouldFly then
		if orbitFlying then setOrbitFlight(hrp, hum, false) end
		return
	end
	setOrbitFlight(hrp, hum, true)

	-- Read the mob's position LIVE every frame rather than the snapshot
	-- refreshTarget() took up to 1s ago -- mobs here move (moveSpeed=14 on
	-- the ledger), and since the server picks the M1 target purely by which
	-- mob sits inside the weapon's facing arc, circling and facing a stale
	-- point means facing where the mob WAS, not where it is.
	local part = currentTarget.part
	local center = (part and part.Parent) and part.Position or currentTarget.position
	orbitAngle = (orbitAngle + math.rad(e.shOrbitSpeed) * dt) % (2 * math.pi)
	local dist = e.shOrbitDistance
	local height = (e.shOrbitMode == "On Head") and (e.shOrbitHeight + 6) or math.max(e.shOrbitHeight, 0)
	local offset = Vector3.new(math.cos(orbitAngle) * dist, height, math.sin(orbitAngle) * dist)
	local pos = center + offset
	-- CFrame.new(pos, target.position) pitches the whole body up/down to
	-- literally point at the target -- fine at "On Foot" height but visibly
	-- wrong at any real height offset (the character tips over instead of
	-- standing upright while circling). Flattening the look-at point to the
	-- character's OWN height keeps the CFrame's forward vector horizontal --
	-- only yaw (facing left/right) changes, no pitch -- so the character
	-- stays upright and just turns to face the target, same as a normal
	-- humanoid always does on the ground.
	--
	-- This also matters for M1, not just looks: PlayerWeaponConfig's
	-- ArcDegrees=120 means the server checks the target falls within a
	-- forward-facing cone from the character's OWN orientation -- a pitched-
	-- up/down CFrame points that cone partly at the sky/ground instead of
	-- level at the target, which can fail the arc check even at correct
	-- range. Facing level at the target keeps the cone aimed where it
	-- actually needs to be.
	-- Never orbit outside the active zone's PlayBox: the InvisibleBarriers
	-- walls sit 59 studs out from the floor centre and the floor itself is
	-- the only thing under the character, so a mob hugging a wall would
	-- otherwise put the orbit ring (CanCollide off) on the far side of it.
	local floor = zoneFloor()
	if floor then
		local half = floor.Size.X / 2 - 4
		local c = floor.Position
		pos = Vector3.new(
			math.clamp(pos.X, c.X - half, c.X + half),
			math.clamp(pos.Y, c.Y + 2, c.Y + 60),
			math.clamp(pos.Z, c.Z - half, c.Z + half))
	end
	local lookAt = Vector3.new(center.X, pos.Y, center.Z)
	hrp.CFrame = CFrame.new(pos, lookAt)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
end)

-- ---------------------------------------------------------------- Auto Farm Mob / Auto M1
-- Took three wrong turns to land this one, all verified live on 2026-09-23:
--   1. Firing PlayerWeaponAttackRequested-RemoteEvent:FireServer(enemyId)
--      directly does NOTHING on its own -- no hit, no rejection, no event
--      at all, at 0.05s, 0.8s, or one call after a 6s idle gap, standing
--      still 6.9 studs from a live mob in a normal humanoid state. The
--      single "hit" that made it look like it worked earlier was a target
--      the server picked itself (requested enemy_106, HitResolved named
--      enemy_103) -- i.e. it was never my call that landed it.
--   2. The weapon cooldown theory (PlayerWeaponConfig CooldownSeconds=0.75)
--      was real config but the wrong diagnosis -- the pacing fix alone
--      changed nothing.
--   3. The real mechanism: the M1 is the equipped Tool ("Sword" in the
--      Character). Tool:Activate() runs the game's own client-side swing
--      handler, which does whatever handshake the server actually expects
--      (it's that handler, not us, that fires the Swing/Attack remotes with
--      the right state). Measured back to back in one controlled probe:
--        Activate() only            -> HitResolved (player) = 1
--        swing+attack remotes only  -> 0
--        Activate()+both remotes    -> 1  (remotes add nothing)
--      Target selection is server-side by weapon arc (ArcDegrees=120 from
--      the character's facing, Range=10.5) -- there is no enemyId to send
--      at all; Orbit keeping the character close and FACING the mob is what
--      chooses the target. Interval floor stays at the real 0.75s cooldown.
task.spawn(function()
	while getgenv().__SH == G do
		if (e.shFarmEnabled and e.shM1Enabled) and currentTarget then
			local char = plr.Character
			local hum = char and char:FindFirstChild("Humanoid")
			local tool = char and char:FindFirstChildWhichIsA("Tool")
			if not tool and hum then
				local bp = plr:FindFirstChild("Backpack")
				local t = bp and bp:FindFirstChildWhichIsA("Tool")
				if t then hum:EquipTool(t) task.wait(0.3) tool = char:FindFirstChildWhichIsA("Tool") end
			end
			if tool then
				local ok = pcall(function() tool:Activate() end)
				if ok then stats.hits += 1 end
			end
		end
		task.wait(math.max(e.shM1Interval or 0.01, 0.01))
	end
end)

-- ---------------------------------------------------------------- Auto Collect Coin (Instant)
-- First version polled GetDropGroups-RemoteFunction every 3s and tried
-- ClaimDropSlice on whatever it found -- confirmed live this basically never
-- lands: every drop's own originPosition field reads null (no position data
-- available through ANY remote here), and DropGroupAdded's own expiresAt is
-- only a few seconds out. By the time a 3s poll noticed a drop, it had
-- usually either expired or the character (mid-orbit, already moved to
-- whatever's now the nearest target) had drifted out of range -- confirmed
-- live: claiming a drop caught mid-window still answered
-- {ok=false, reason="missing_or_wrong_owner"} once enough time had passed.
--
-- Real fix: since coins drop at the kill location and Orbit is already
-- flying the character right next to whatever it just killed, the character
-- is likely AT ITS CLOSEST to a fresh drop in the instant it's announced --
-- so claim on the DropGroupAdded event itself instead of polling, firing a
-- few quick retries in case the very first attempt lands a tick before the
-- drop is fully registered server-side.
if net:FindFirstChild("DropGroupAdded-RemoteEvent") then
	net["DropGroupAdded-RemoteEvent"].OnClientEvent:Connect(function(grp)
		if getgenv().__SH ~= G or not e.shCollectEnabled then return end
		if not (grp and grp.dropGroupId) then return end
		task.spawn(function()
			for _ = 1, 4 do
				if getgenv().__SH ~= G then break end
				local ok, res = call("ClaimDropSlice-RemoteFunction", grp.dropGroupId)
				if ok and type(res) == "table" and res.ok then
					stats.collected += 1
					break
				end
				task.wait(0.2)
			end
		end)
	end)
end

-- Periodic 0.5s sweep (by request) on top of the event-driven claim above:
-- re-tries every drop the server still lists via GetDropGroups. The
-- event path is what lands the instant claim at the kill spot; this sweep
-- picks up anything that was out of range at drop time but is in range
-- now that Orbit has moved the character on. Claims within one sweep are
-- spaced 0.1s so a big pile of drops doesn't trip the server's rate limit
-- the way a tight burst of quest claims did ("rate_limited").
task.spawn(function()
	while getgenv().__SH == G do
		if e.shCollectEnabled then
			local ok, groups = call("GetDropGroups-RemoteFunction")
			if ok and type(groups) == "table" then
				for _, grp in pairs(groups) do
					if getgenv().__SH ~= G then break end
					if grp.dropGroupId then
						local cok, res = call("ClaimDropSlice-RemoteFunction", grp.dropGroupId)
						if cok and type(res) == "table" and res.ok then stats.collected += 1 end
						task.wait(0.1)
					end
				end
			end
		end
		task.wait(0.5)
	end
end)

-- ---------------------------------------------------------------- Inventory: Equip Best / Skill Tree
task.spawn(function()
	while getgenv().__SH == G do
		if e.shEquipBestEnabled then
			local ok = call("EquipBestUnits-RemoteFunction")
			if ok then stats.equips += 1 end
		end
		task.wait(20)
	end
end)

-- Priority (added on request): families ticked in "Upgrade Priority" are
-- bought FIRST, each pushed as far as coins allow (PurchaseSkillTreeNode
-- on family..(rank+1) until it answers NotEnoughCoins / UnknownNode), in
-- SKILL_FAMILIES order; only then, if "buy the rest" is on, MaxBuy sweeps
-- whatever else is affordable. With nothing ticked this is exactly the old
-- behaviour. Without this ordering MaxBuy spends the whole coin pool on
-- whatever the server picks, which is why "upgrade Damage/Coin first" was
-- impossible before.
task.spawn(function()
	while getgenv().__SH == G do
		if e.shSkillTreeEnabled then
			local order = e.shUpgradeOrder
			local hasPriority = type(order) == "table" and #order > 0
			if hasPriority then
				local ok, st = call("GetSkillTreeState-RemoteFunction")
				local ranks = ok and type(st) == "table" and st.rankByFamily or {}
				for _, label in ipairs(order) do   -- slot 1 first, exactly as ranked in the UI
					if getgenv().__SH ~= G then break end
					local fam = SKILL_LABEL_TO_FAMILY[label]
					if fam then
						local rank = tonumber(ranks[fam]) or 0
						for _ = 1, 10 do   -- cap per pass; NotEnoughCoins/UnknownNode ends it early
							local pok, pres = call("PurchaseSkillTreeNode-RemoteFunction", fam .. (rank + 1))
							if not (pok and type(pres) == "table" and pres.ok) then break end
							stats.skillNodes += 1
							rank += 1
							task.wait(0.2)
						end
					end
				end
			end
			if e.shUpgradeRest or not hasPriority then
				local ok, res = call("MaxBuySkillTreeNodes-RemoteFunction")
				if ok and type(res) == "table" and res.purchasedCount and res.purchasedCount > 0 then
					stats.skillNodes += res.purchasedCount
				end
			end
		end
		task.wait(15)
	end
end)

-- ---------------------------------------------------------------- Auto Claim Quest
task.spawn(function()
	while getgenv().__SH == G do
		if e.shQuestEnabled then
			-- ClaimQuestReward-RemoteFunction wants THREE args: (categoryId,
			-- periodId, questId). Found by elimination live on 2026-09-23 with two
			-- genuinely claimable weekly quests sitting there: every 1- and 2-arg
			-- shape answered {ok=false, reason="invalid_request"}, and the sibling
			-- ClaimQuestRewards(categoryId) answered "invalid_periods" -- the hint
			-- that a period was the missing piece. periodId is right there on
			-- each category in GetQuestState (e.g. "2026-W39" for Weekly,
			-- "lifetime" for Special). Success returns {state={...}} (the full
			-- refreshed quest state), NOT {ok=true} -- and the quest flipped to
			-- claimed=true on the next read. Spaced 1s apart: a burst of claims
			-- answers "rate_limited".
			local ok, res = call("GetQuestState-RemoteFunction")
			if ok and type(res) == "table" and res.categories then
				for catName, cat in pairs(res.categories) do
					for _, q in ipairs(cat.quests or {}) do
						if getgenv().__SH ~= G then break end
						if q.completed and not q.claimed and q.id then
							local cok, cres = call("ClaimQuestReward-RemoteFunction",
								cat.id or catName, cat.periodId, q.id)
							if cok and type(cres) == "table" and (cres.state or cres.ok) then
								stats.quests += 1
							end
							task.wait(1)
						end
					end
				end
			end
		end
		task.wait(30)
	end
end)

-- ---------------------------------------------------------------- Auto Claim Index
-- Hero Index only -- see header note on why Enemy Index is left out (no
-- listing remote found to source valid reward ids from, and guessing them
-- risks nothing but wasted calls, but there's no confirmed win either).
task.spawn(function()
	while getgenv().__SH == G do
		if e.shIndexEnabled then
			local ok, res = call("ClaimAllHeroIndexRewards-RemoteFunction")
			if ok and type(res) == "table" and res.ok and (res.claimedCount or 0) > 0 then
				stats.index += res.claimedCount
			end
		end
		task.wait(30)
	end
end)

-- ---------------------------------------------------------------- Auto Rebirth
task.spawn(function()
	while getgenv().__SH == G do
		-- Stage gate: the game only unlocks rebirth after boss stages (10, 20,
		-- 30 ... 100), and rebirthing at the first eligible boss wastes the
		-- deeper-stage multiplier. shRebirthMinLevel is the player's pick of
		-- which boss stage to hold out for; 0 means "as soon as the game
		-- allows". CurrentLevel is the live player attribute (same one the
		-- Loop Level / Next Stage loops read), so a rebirth reset drops it
		-- back below the gate and the loop simply waits for the next climb.
		local minLv = tonumber(e.shRebirthMinLevel) or 0
		local curLv = tonumber(plr:GetAttribute("CurrentLevel")) or 0
		if e.shRebirthEnabled and curLv < minLv then
			stats.rebirthNote = ("waiting for stage %d (now %d)"):format(minLv, curLv)
		elseif e.shRebirthEnabled then
			local ok, res = call("GetRebirthState-RemoteFunction")
			if ok and type(res) == "table" and res.canRebirth then
				-- AttemptRebirth answers a table, not a bare bool: {ok=true,...} on
				-- success, or {ok=false, reason=..., retryable=..., unrecoverable=...}
				-- when refused. Counting the bare pcall as a rebirth (the old code)
				-- inflated "Rebirths" on every refusal. Real result of this loop in
				-- one live session: rebirthCount 1 -> 5 on the account -- it works
				-- whenever the game accepts. When the game refuses, canRebirth=true
				-- alone is NOT the real gate: seen live as reason=
				-- "rebirth_unrecoverable" (retryable=false) at level 35 in both the
				-- Combat and Lobby areas, with no error text anywhere in the game's
				-- own UI to explain it. Surface the reason on the status panel so
				-- a refusal is visible instead of silently looking like "no-op".
				local rok, rres = call("AttemptRebirth-RemoteFunction")
				if rok and type(rres) == "table" then
					if rres.ok then
						stats.rebirths += 1
						stats.rebirthNote = "ok"
					else
						stats.rebirthNote = tostring(rres.reason or "refused")
					end
				end
			elseif ok and type(res) == "table" then
				stats.rebirthNote = ("not ready (lv %s / need %s)"):format(tostring(res.currentLevel), tostring(res.nextRewardLevel))
			end
		end
		-- 10s, not 30: with a stage gate the eligible window opens the moment
		-- the boss drops, and a 30s poll could sit on the far side of a level
		-- change long enough to feel like "it's not rebirthing".
		task.wait(10)
	end
end)

-- ---------------------------------------------------------------- Auto Next Stage
-- Stage progression is a built-in game feature, not something to drive by
-- hand: the "AutoProgressionEnabled" player attribute was already true on
-- this account, and the level climbed 24 -> 35 during one live session
-- with zero manual RequestAreaTransition/SetPlayerPartyStage calls -- the
-- game advances on its own the moment a wave/boss clears. So this loop's
-- real jobs are the two things that DO break progression:
--   1. Re-assert SetAutoProgressionEnabled(true) if the attribute ever
--      reads false (a game UI toggle / rebirth reset could flip it).
--   2. Keep the character in the Combat area. My own area-transition
--      probing bounced the account into the Lobby and progression halted
--      there; RequestAreaTransition({source="Lobby",destination="Combat"})
--      answers "invalid_button_transition" (not a button-driven hop), but
--      standing on workspace.Lobby.CombatPortal's part re-enters Combat
--      within a couple of seconds (confirmed live). Same fix works for a
--      character that ends up in the lobby for any other reason (respawn,
--      rebirth flow).
-- Loop Level (added on request): pin the account to ONE chosen level and
-- keep replaying it instead of advancing. Two remotes, both confirmed live:
--   - SetAutoProgressionEnabled-RemoteEvent takes a BARE boolean. true
--     flipped the AutoProgressionEnabled attribute on and the level advanced
--     within the same second; {enabled=true} (table) was read as false and
--     turned it OFF -- so never wrap it.
--   - SetCurrentLevel-RemoteEvent takes a bare level number (31 -> 30
--     confirmed live; the game bounces a cleared level up by one and this
--     pulls it back). Only levels <= UnlockedLevel are meaningful.
-- Loop mode and Auto Next Stage are mutually exclusive by construction: with
-- Loop on, this loop keeps auto-progression OFF and re-pins the level every
-- pass; with Loop off and Next Stage on, it keeps auto-progression ON. It
-- never touches the flag when both are off, so a setting made by hand in
-- the game's own UI is left alone in that case.
local function findNextStageButton()
	local pg = plr:FindFirstChild("PlayerGui")
	local screen = pg and pg:FindFirstChild("GameUI") and pg.GameUI:FindFirstChild("VictoryEndScreen", true)
	local btn = screen and screen:FindFirstChild("NextStage", true)
	if btn and (btn:IsA("TextButton") or btn:IsA("ImageButton")) then return btn end
	return nil
end
-- DefeatEndScreen has two buttons: Buttons.NextStage is "Revive & Continue"
-- -- a Robux product (3610976809, the client waits on
-- PromptProductPurchaseFinished for it) and is never touched -- and
-- Buttons.Return, "Return to last stage", which is the free way off the
-- screen. Without a press the run parks on the defeat screen forever.
local function findDefeatReturnButton()
	local pg = plr:FindFirstChild("PlayerGui")
	local screen = pg and pg:FindFirstChild("GameUI") and pg.GameUI:FindFirstChild("DefeatEndScreen", true)
	local btn = screen and screen:FindFirstChild("Return", true)
	if btn and (btn:IsA("TextButton") or btn:IsA("ImageButton")) then return btn end
	return nil
end

local function pressNextStage(btn)
	if not (btn and btn.Visible and getconnections) then return false end
	local pressed = false
	for _, sig in ipairs({"Activated", "MouseButton1Click"}) do
		local okc, conns = pcall(getconnections, btn[sig])
		if okc and type(conns) == "table" then
			for _, c in ipairs(conns) do
				if pcall(function() if c.Function then c.Function() elseif c.Fire then c:Fire() end end) then pressed = true end
			end
		end
	end
	if pressed then stats.target = "pressed Next Stage" end
	return pressed
end

-- The boss-victory park is the one place the run actually waits on us, so
-- the Next Stage press gets its own fast path instead of riding the 3s
-- progression loop below: the button's Visible flip is hooked directly
-- (fires the same frame the VictoryEndScreen opens), with a 0.1s sweep
-- underneath for a screen the game rebuilds and re-parents. After a press
-- it holds 0.5s so a still-visible button during the server round-trip
-- isn't hammered ten times a second.
task.spawn(function()
	local hookedBtn, hookedConn
	local lastPress = 0
	local function tryPress(btn)
		if not (e.shNextStageEnabled or e.shLoopLevelEnabled) then return end
		if os.clock() - lastPress < 0.5 then return end
		if pcall(pressNextStage, btn) and btn.Visible then lastPress = os.clock() end
	end
	while getgenv().__SH == G do
		local btn = findNextStageButton()
		if btn and btn ~= hookedBtn then
			if hookedConn then hookedConn:Disconnect() end
			hookedBtn = btn
			hookedConn = btn:GetPropertyChangedSignal("Visible"):Connect(function()
				if getgenv().__SH == G and btn.Visible then tryPress(btn) end
			end)
		end
		if btn and btn.Visible then tryPress(btn) end
		if e.shDefeatContinue then
			local rb = findDefeatReturnButton()
			if rb and rb.Visible and os.clock() - lastPress >= 0.5 then
				if pcall(pressNextStage, rb) then
					lastPress = os.clock()
					stats.defeats += 1
					stats.target = "defeat -> returned to stage"
				end
			end
		end
		task.wait(0.1)
	end
	if hookedConn then hookedConn:Disconnect() end
end)

task.spawn(function()
	while getgenv().__SH == G do
		local loopLevel = tonumber(e.shLoopLevel)
		if e.shLoopLevelEnabled and loopLevel then
			if plr:GetAttribute("AutoProgressionEnabled") ~= false then
				fire("SetAutoProgressionEnabled-RemoteEvent", false)
			end
			local cur = tonumber(plr:GetAttribute("CurrentLevel"))
			if cur and cur ~= loopLevel then
				fire("SetCurrentLevel-RemoteEvent", loopLevel)
			end
		elseif e.shNextStageEnabled then
			if plr:GetAttribute("AutoProgressionEnabled") == false then
				fire("SetAutoProgressionEnabled-RemoteEvent", true)
			end
		end
		if e.shNextStageEnabled or e.shLoopLevelEnabled then
			-- THE actual "Auto Next Stage doesn't work" cause, found live at a
			-- level-30 boss: after a boss VICTORY the server parks the run --
			-- GetPendingBossResult reports {phase="victory", resultId=N},
			-- CurrentLevel stays put, no enemies spawn, SetCurrentLevel is
			-- refused and even AutoProgressionEnabled=true doesn't move it --
			-- until the player presses the game's own "Next Stage" button on
			-- GameUI.VictoryEndScreen. Every RequestBossAction payload guessed
			-- (9 shapes) came back invalid_payload, so instead of guessing the
			-- protocol, press the real button by invoking its own connected
			-- click handlers (getconnections) -- the game's code then sends
			-- exactly what the server expects. Confirmed: level 30 -> 31 within
			-- 3s, pending result cleared, wave encounter active. Only the
			-- VictoryEndScreen button is pressed -- DefeatEndScreen's is
			-- "Revive & Continue" and is left alone on purpose. The press
			-- itself now lives in the event-driven pressNextStage loop above;
			-- this pass only handles the lobby bounce.
			if plr:GetAttribute("PlayerArea") == "Lobby" and not wbHold then
				local portal = workspace:FindFirstChild("Lobby") and workspace.Lobby:FindFirstChild("CombatPortal")
				local part = portal and portal:FindFirstChildWhichIsA("BasePart", true)
				local char = plr.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if part and hrp then
					hrp.CFrame = part.CFrame + Vector3.new(0, 2, 0)
					task.wait(4)
				end
			end
		end
		-- 1s (was 10, then 3): watched live with Loop pinned to level 8, the
		-- game re-enabled auto-progression and jumped to level 11 on a wave
		-- clear between polls, and every second of gap is a second farming
		-- the wrong level before the pin catches it. Both remotes here are
		-- no-ops when the attributes already match, so 1s costs nothing.
		task.wait(1)
	end
end)

-- ---------------------------------------------------------------- Auto World Boss
-- "World Boss" in the UI is "ServerBoss" in the code. Everything below was
-- read out of the live client (2026-09-24):
--   - Roster: ReplicatedStorage.Shared.Config.ServerBossConfig.Bosses --
--     mink (lv50 ref, 15k coins), lonku (lv90, 30k), zephyr (lv130, 50k);
--     one spawns every ScheduleIntervalSeconds=3600, fight lasts
--     EncounterSeconds=600, then ResultSeconds=30.
--   - State: GetServerBossSnapshot-RemoteFunction / ServerBossSnapshotChanged
--     -RemoteEvent -> {phase="Idle"|"Active"|"Result", bossId, eventId,
--     endsAt, introEndsAt, nextReservation={bossId,startAt}}. The game's
--     own client service (require(PlayerScripts.Client).ServerBossService)
--     caches it and exposes getSnapshot()/getChangedSignal().
--   - Join = ServerBossService:join() -> PlayerAreaService:requestTransition(
--     "ServerBoss","WorldBossJoin") -> RequestJoinServerBoss-RemoteEvent
--     {destination, source, requestId=GUID}. Return = :returnToLobby() ->
--     RequestReturnFromServerBoss. Both are driven through the game's own
--     service rather than the raw remotes so its presentation fence /
--     WorldContext placement handshake (AcknowledgeWorldContextPlacement)
--     stays in sync -- firing the remote directly leaves the client's area
--     service believing it's still in Combat.
--   - AreaConfig.canBeginClientTransition: Combat->ServerBoss and
--     Lobby->ServerBoss are allowed, ServerBoss->Lobby allowed,
--     ServerBoss->Combat is NOT -- so the way home is arena -> Lobby ->
--     CombatPortal -> Combat, same portal walk the Next Stage loop uses.
-- Flow: boss goes Active and its name is in shWorldBossPick -> hold orbit,
-- join, wait for PlayerArea=="ServerBoss", find the arena's enemy folder
-- (the boss carries EnemyId/ArchetypeId="world_<id>" attributes like every
-- other mob, so the normal targeting + orbit + M1 handle the fight) ->
-- when the phase leaves Active (kill or 10-min escape) return to Lobby,
-- walk the portal, release the hold. Farming resumes on its own.
local WB_BOSSES = {{id = "mink", name = "Mink"}, {id = "lonku", name = "Lonku"}, {id = "zephyr", name = "Zephyr"}}
pcall(function()
	local cfg = require(game:GetService("ReplicatedStorage").Shared.Config.ServerBossConfig)
	local order, out = cfg.BossOrder or {}, {}
	for i = 1, 10 do
		local id = order[i] or order[tostring(i)]
		local b = id and cfg.Bosses and cfg.Bosses[id]
		if b then out[#out + 1] = {id = b.id or id, name = b.displayName or id} end
	end
	if #out > 0 then WB_BOSSES = out end
end)
local WB_NAMES = {}
for _, b in ipairs(WB_BOSSES) do WB_NAMES[#WB_NAMES + 1] = b.name end

local function wbNameOf(bossId)
	for _, b in ipairs(WB_BOSSES) do if b.id == bossId then return b.name end end
	return tostring(bossId)
end
local function wbWanted(bossId)
	local name = wbNameOf(bossId)
	for _, v in ipairs(e.shWorldBossPick or {}) do
		if v == name or v == bossId then return true end
	end
	return false
end

local function wbServices()
	local ps = plr:FindFirstChild("PlayerScripts")
	local cm = ps and ps:FindFirstChild("Client")
	if not (cm and cm:IsA("ModuleScript")) then return nil end
	local ok, C = pcall(require, cm)
	if ok and type(C) == "table" and C.ServerBossService then return C end
	return nil
end
local function wbSnapshot(C)
	local ok, snap = pcall(function() return C.ServerBossService:getSnapshot() end)
	if ok and type(snap) == "table" then return snap end
	local ok2, snap2 = call("GetServerBossSnapshot-RemoteFunction")
	return ok2 and type(snap2) == "table" and snap2 or nil
end
local function wbActive(snap)
	return snap and snap.enabled ~= false and snap.phase == "Active"
		and (type(snap.endsAt) ~= "number" or snap.endsAt > os.time())
end
local function waitArea(want, timeout)
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		if plr:GetAttribute("PlayerArea") == want then return true end
		task.wait(0.1)
	end
	return plr:GetAttribute("PlayerArea") == want
end
-- The arena parents the boss somewhere other than Game/Enemies (folder is
-- rebuilt per area). Find it by the EnemyId attribute every mob carries.
local function findArenaFolder()
	local gf = workspace:FindFirstChild("Game")
	local ge = gf and gf:FindFirstChild("Enemies")
	if ge then
		for _, m in ipairs(ge:GetChildren()) do
			if m:GetAttribute("EnemyId") then return ge end
		end
	end
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("Model") and d:GetAttribute("EnemyId") and tostring(d:GetAttribute("ArchetypeId") or ""):find("^world_") then
			return d.Parent
		end
	end
	return nil
end
local function walkCombatPortal()
	local portal = workspace:FindFirstChild("Lobby") and workspace.Lobby:FindFirstChild("CombatPortal")
	local part = portal and portal:FindFirstChildWhichIsA("BasePart", true)
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChild("Humanoid")
	if not (part and hrp) then return false end
	if hum then hum.PlatformStand = false end
	hrp.CanCollide = true
	hrp.CFrame = part.CFrame + Vector3.new(0, 2, 0)
	return true
end

-- Titles: SetEquippedTitle-RemoteEvent takes the bare title id (what the
-- Titles modal fires). Ownership comes from the game's data replica --
-- require(Shared.Packages.DataService).client:get({"OwnedTitles"}) is a
-- map id -> {grantedAt} -- and names/buffs from Shared.Config.TitleConfig
-- (Definitions[id] = {displayName, buffKind, buffPercent}, Order = ids).
-- Two picks: one worn while inside the world-boss arena (the
-- worldBossDamage titles exist for exactly that), one restored on the way
-- back. "" leaves the title untouched.
local TITLE_OPTIONS, TITLE_IDS = {"None"}, {""}
local function loadTitleOptions()
	local RS = game:GetService("ReplicatedStorage")
	local ok, tc = pcall(function() return require(RS.Shared.Config.TitleConfig) end)
	if not (ok and type(tc) == "table" and type(tc.Definitions) == "table") then return end
	local owned = nil
	pcall(function() owned = require(RS.Shared.Packages.DataService).client:get({"OwnedTitles"}) end)
	local ids = {}
	if type(tc.Order) == "table" and #tc.Order > 0 then
		for _, id in ipairs(tc.Order) do ids[#ids + 1] = id end
	else
		for id in pairs(tc.Definitions) do ids[#ids + 1] = id end
		table.sort(ids)
	end
	for _, id in ipairs(ids) do
		local d = tc.Definitions[id]
		local have = type(owned) ~= "table" or owned[id] ~= nil
		if d and have then
			local buff = d.buffPercent and d.buffKind and (" (+%s%% %s)"):format(tostring(d.buffPercent), tostring(d.buffKind)) or ""
			TITLE_OPTIONS[#TITLE_OPTIONS + 1] = tostring(d.displayName or id) .. buff
			TITLE_IDS[#TITLE_IDS + 1] = id
		end
	end
end
pcall(loadTitleOptions)
local function titleIndexOf(id)
	for i, v in ipairs(TITLE_IDS) do if v == id then return i end end
	return 1
end
local function equipTitle(id)
	if type(id) ~= "string" or id == "" then return end
	if plr:GetAttribute("EquippedTitleId") == id then return end
	fire("SetEquippedTitle-RemoteEvent", id)
end
-- farm title is the resting state: put it on at load unless we're mid-boss
if plr:GetAttribute("PlayerArea") ~= "ServerBoss" then pcall(equipTitle, e.shFarmTitleId) end

local wbJoinedEvent = nil
task.spawn(function()
	while getgenv().__SH == G do
		if e.shWorldBossEnabled then
			pcall(function()
				local C = wbServices()
				if not C then stats.worldBoss = "service n/a" return end
				local snap = wbSnapshot(C)
				if not snap then stats.worldBoss = "no snapshot" return end
				local area = plr:GetAttribute("PlayerArea")
				local active = wbActive(snap)

				if area == "ServerBoss" then
					if active then
						stats.worldBoss = ("fighting %s (%s left)"):format(wbNameOf(snap.bossId),
							type(snap.endsAt) == "number" and ("%ds"):format(math.max(0, snap.endsAt - os.time())) or "?")
						if not (arenaFolder and arenaFolder.Parent) then
							arenaFolder = findArenaFolder()
						end
						-- boss is placed: let orbit/M1 take over
						if arenaFolder and currentTarget then wbHold = false end
						return
					end
					-- Result / Idle while still inside: leave. A short beat first
					-- so the server's reward grant (it happens on the phase flip)
					-- is never raced by our return request.
					stats.worldBoss = "done, returning"
					wbHold = true
					task.wait(2)
					pcall(function() C.ServerBossService:returnToLobby() end)
					if waitArea("Lobby", 15) then
						task.wait(0.5)
						walkCombatPortal()
						waitArea("Combat", 15)
					end
					arenaFolder = nil
					wbHold = false
					stats.worldBosses += 1
					stats.worldBoss = ("returned (%d done)"):format(stats.worldBosses)
					pcall(equipTitle, e.shFarmTitleId)
					return
				end

				-- Transition states: just wait them out.
				if area ~= "Combat" and area ~= "Lobby" then return end

				if active and wbWanted(snap.bossId) and wbJoinedEvent ~= snap.eventId then
					stats.worldBoss = "joining " .. wbNameOf(snap.bossId)
					wbHold = true
					wbJoinedEvent = snap.eventId
					local ok = pcall(function() C.ServerBossService:join() end)
					if ok and waitArea("ServerBoss", 20) then
						arenaFolder = nil
						stats.worldBoss = "in arena: " .. wbNameOf(snap.bossId)
						pcall(equipTitle, e.shWbTitleId)
					else
						-- refused (not eligible / fence rejected) -- don't spam it,
						-- the eventId guard above holds until the next boss
						stats.worldBoss = "join refused: " .. wbNameOf(snap.bossId)
						wbHold = false
					end
					return
				end

				if active then
					stats.worldBoss = ("%s active (skipped, not picked)"):format(wbNameOf(snap.bossId))
				else
					local nr = snap.nextReservation
					if type(nr) == "table" and type(nr.startAt) == "number" then
						local left = math.max(0, nr.startAt - os.time())
						stats.worldBoss = ("next %s in %dm %02ds"):format(wbNameOf(nr.bossId), left // 60, left % 60)
					else
						stats.worldBoss = "idle"
					end
				end
			end)
		elseif wbHold then
			wbHold = false
		end
		task.wait(1)
	end
end)

-- ---------------------------------------------------------------- Placement / fall watchdog
-- Root cause of "after a long farm the character falls out of the map and
-- the run stops / the mobs vanish", read out of the live client:
--   - Every zone (10 levels) is a separate PlayBox at different world
--     coordinates, and only the active zone has its floor/walls instanced.
--     On a zone change the SERVER teleports the character to the new
--     CombatSpawn, then waits for the client to acknowledge the placement
--     (PlayerAreaServiceClient fires AcknowledgeWorldContextPlacement only
--     once HumanoidRootPart is within tolerance of expectedPosition).
--   - Orbit was still writing hrp.CFrame every frame around the OLD zone's
--     last mob, so the client (which owns the character) kept dragging it
--     back to the old coordinates -- where the floor had just been
--     destroyed. Collision came back the moment the old mobs were removed,
--     the character fell to FallenPartsDestroyHeight (-500) and died, and
--     the placement was never acknowledged, so the new zone never started
--     spawning: both symptoms, one cause.
-- Fix, in order of preference:
--   1. stop writing CFrame (placementHoldUntil) the instant the server
--      signals it is moving us -- Zone / PlayerArea / WorldContextCommit
--      attribute changes and CharacterAdded -- and drop the stale target;
--   2. clamp the orbit ring inside the active PlayBox (in the orbit loop);
--   3. a 1s watchdog: below the floor -> teleport to the zone's CombatSpawn;
--      in the Lobby with farm on -> walk the portal; no enemies in Combat
--      for 20s -> re-stand on CombatSpawn (re-triggers the placement
--      ack), 45s -> bounce Lobby -> Combat.
local function holdPlacement(seconds)
	placementHoldUntil = math.max(placementHoldUntil, os.clock() + seconds)
	currentTarget = nil
	e.__shTargetId = nil
end
for _, attr in ipairs({"Zone", "PlayerArea", "WorldContextCommit", "WorldContextRevision"}) do
	plr:GetAttributeChangedSignal(attr):Connect(function()
		if getgenv().__SH == G then holdPlacement(2.5) end
	end)
end
plr.CharacterAdded:Connect(function()
	if getgenv().__SH ~= G then return end
	-- new Humanoid, flags start clean: forget the old one's flight state so
	-- setOrbitFlight re-applies PlatformStand/CanCollide instead of assuming
	orbitFlying = false
	holdPlacement(4)
end)

local function standOn(pos)
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChild("Humanoid")
	if not (hrp and pos) then return false end
	if hum then hum.PlatformStand = false end
	hrp.CanCollide = true
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	hrp.CFrame = CFrame.new(pos)
	return true
end

task.spawn(function()
	local noEnemySince = nil
	local lastRescue = 0
	while getgenv().__SH == G do
		pcall(function()
			if not (e.shFarmEnabled or e.shOrbitEnabled) or wbHold then noEnemySince = nil return end
			local area = plr:GetAttribute("PlayerArea")
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChild("Humanoid")
			if not (hrp and hum) or hum.Health <= 0 then return end

			if area == "Lobby" then
				noEnemySince = nil
				if os.clock() - lastRescue > 5 then
					lastRescue = os.clock()
					holdPlacement(3)
					walkCombatPortal()
					stats.target = "lobby -> portal"
				end
				return
			end
			if area ~= "Combat" then noEnemySince = nil return end

			-- fell out: under the zone floor, or under everything
			local floor = zoneFloor()
			local floorY = floor and floor.Position.Y or 0
			if hrp.Position.Y < floorY - 25 or hrp.Position.Y < -150 then
				local spot = zoneSpawn() or (floor and floor.Position + Vector3.new(0, 4, 0))
				if spot and os.clock() - lastRescue > 2 then
					lastRescue = os.clock()
					holdPlacement(1.5)
					standOn(spot)
					stats.target = "fell -> respawned in zone"
				end
				return
			end

			-- stalled encounter: no enemies at all for a while
			local count = enemiesFolder and enemiesFolder.Parent and #enemiesFolder:GetChildren() or 0
			if count > 0 then noEnemySince = nil return end
			noEnemySince = noEnemySince or os.clock()
			local stalled = os.clock() - noEnemySince
			if stalled > 45 and os.clock() - lastRescue > 30 then
				lastRescue = os.clock()
				noEnemySince = nil
				stats.target = "stalled 45s -> lobby bounce"
				holdPlacement(6)
				local C = nil
				pcall(function() C = require(plr.PlayerScripts.Client) end)
				if C and C.PlayerAreaService then
					pcall(function() C.PlayerAreaService:requestTransition("Lobby", "TopbarLeaveButton") end)
				end
			elseif stalled > 20 and os.clock() - lastRescue > 10 then
				lastRescue = os.clock()
				local spot = zoneSpawn()
				if spot then
					stats.target = "stalled 20s -> re-stand on spawn"
					holdPlacement(2)
					standOn(spot)
				end
			end
		end)
		task.wait(1)
	end
end)

-- ---------------------------------------------------------------- Auto Evolve Hero
-- Hero "evolution" is a timed awakening. Read out of the live client:
--   - HeroIndexService:getState().awakeningsByKey[stackKey] = {state=
--     "not_started"|"in_progress"|(ready), completesAt, durationSeconds,
--     remainingSeconds, tier="awakened"|"perfected"}. An entry only exists
--     once the hero has enough summons (index nextMilestoneCount, e.g. 10
--     copies of a Mythic) -- so the map IS the eligibility list.
--   - StartHeroAwakening-RemoteFunction(stackKey) starts the timer (Rare
--     10 min, Epic 2 h, Legendary 8 h, Mythic/Secret 20 h; perfecting is
--     longer). ClaimHeroEvolution-RemoteFunction(stackKey) finishes it and
--     is the "Claim!" button the Backpack shows when it's done.
-- Both go through the game's HeroIndexService wrappers so its cached state
-- (and the Backpack badge) update from the same reply.
local function heroIndexService()
	local ps = plr:FindFirstChild("PlayerScripts")
	local cm = ps and ps:FindFirstChild("Client")
	if not (cm and cm:IsA("ModuleScript")) then return nil end
	local ok, C = pcall(require, cm)
	return ok and type(C) == "table" and C or nil
end

task.spawn(function()
	local lastRefresh = 0
	while getgenv().__SH == G do
		if e.shEvolveHeroEnabled then
			pcall(function()
				local C = heroIndexService()
				local svc = C and C.HeroIndexService
				if not svc then stats.evolveNote = "service n/a" return end
				if os.clock() - lastRefresh > 60 then
					lastRefresh = os.clock()
					pcall(function() svc:refresh() end)
				end
				local st = svc:getState()
				local map = type(st) == "table" and st.awakeningsByKey
				if type(map) ~= "table" then stats.evolveNote = "no data" return end
				local now = os.time()
				local pending, soonest = 0, nil
				for key, a in pairs(map) do
					if type(a) ~= "table" then continue end
					local stackKey = a.stackKey or key
					local ready = (a.state ~= "not_started" and a.state ~= "in_progress")
						or (type(a.completesAt) == "number" and a.completesAt <= now)
					if a.state == "not_started" then
						local res = svc:startAwakening(stackKey)
						if type(res) == "table" and res.ok then
							stats.evolveStarts += 1
							stats.evolveNote = "started " .. tostring(stackKey)
						else
							stats.evolveNote = ("start %s: %s"):format(tostring(stackKey), tostring(type(res) == "table" and res.reason or res))
						end
						task.wait(1)
					elseif ready then
						local res = svc:claimEvolution(stackKey)
						if type(res) == "table" and res.ok then
							stats.evolveClaims += 1
							stats.evolveNote = "claimed " .. tostring(stackKey)
						else
							stats.evolveNote = ("claim %s: %s"):format(tostring(stackKey), tostring(type(res) == "table" and res.reason or res))
						end
						task.wait(1)
					else
						pending += 1
						local left = type(a.completesAt) == "number" and (a.completesAt - now) or nil
						if left and (not soonest or left < soonest) then soonest = left end
					end
				end
				if pending > 0 and soonest then
					stats.evolveNote = ("%d in progress, next in %dh %02dm"):format(pending, soonest // 3600, (soonest % 3600) // 60)
				elseif pending == 0 and stats.evolveNote:sub(1, 7) ~= "started" and stats.evolveNote:sub(1, 7) ~= "claimed" then
					stats.evolveNote = "nothing eligible"
				end
			end)
		end
		task.wait(10)
	end
end)

-- ---------------------------------------------------------------- Auto Hatch
-- GetPetEggState-RemoteFunction -> {eggs={ {id="zone3_egg", displayName=
-- "Cave Egg", zoneNumber, quantity, hatchDurationSeconds=14400}, ... },
-- hatchery={ ["1"]={eggId, startedAt, completesAt}, ... }, serverNow}.
-- Three hatchery slots (the game's own error text: "All three hatchery
-- slots are occupied"). StartEggHatch-RemoteFunction(eggId) fills a free
-- slot; ClaimEggHatch-RemoteFunction(slotKey) collects a finished one and
-- answers {ok=true, evidence={petId,...}}. Both are invoked directly rather
-- than through PetService:_action so the client's EggHatchRevealService
-- (a tap-to-crack reveal) never gets queued -- the pet lands in the
-- inventory either way, and PetEggStateChanged still refreshes the state.
local EGG_OPTIONS = {}   -- display names, highest zone first
local eggIdByName = {}
local function petState()
	local ok, st = call("GetPetEggState-RemoteFunction")
	return ok and type(st) == "table" and st or nil
end
local function refreshEggOptions(st)
	local eggs = st and st.eggs
	if type(eggs) ~= "table" then return end
	local list = {}
	for _, egg in pairs(eggs) do
		if type(egg) == "table" and egg.id and egg.displayName then list[#list + 1] = egg end
	end
	table.sort(list, function(a, b) return (a.zoneNumber or 0) > (b.zoneNumber or 0) end)
	table.clear(EGG_OPTIONS)
	for _, egg in ipairs(list) do
		EGG_OPTIONS[#EGG_OPTIONS + 1] = egg.displayName
		eggIdByName[egg.displayName] = egg.id
	end
end
refreshEggOptions(petState())
local function hatchWanted(egg)
	local pick = e.shHatchEggs
	if type(pick) ~= "table" or #pick == 0 then return true end
	for _, name in ipairs(pick) do
		if name == egg.displayName or name == egg.id then return true end
	end
	return false
end

task.spawn(function()
	while getgenv().__SH == G do
		if e.shHatchEnabled then
			pcall(function()
				local st = petState()
				if not st then stats.hatchNote = "no data" return end
				if #EGG_OPTIONS == 0 then refreshEggOptions(st) end
				local now = tonumber(st.serverNow) or os.time()
				local hatchery = type(st.hatchery) == "table" and st.hatchery or {}
				local occupied, soonest = 0, nil
				for slot, h in pairs(hatchery) do
					if type(h) == "table" and h.eggId then
						if type(h.completesAt) == "number" and h.completesAt <= now then
							local ok, res = call("ClaimEggHatch-RemoteFunction", tostring(slot))
							if ok and type(res) == "table" and res.ok then
								stats.hatchClaims += 1
								stats.hatchNote = "claimed slot " .. tostring(slot)
								task.wait(0.5)
							else
								occupied += 1
								stats.hatchNote = ("claim slot %s: %s"):format(tostring(slot), tostring(type(res) == "table" and res.error or res))
							end
						else
							occupied += 1
							local left = type(h.completesAt) == "number" and (h.completesAt - now) or nil
							if left and (not soonest or left < soonest) then soonest = left end
						end
					end
				end
				-- fill free slots: highest-zone wanted egg with stock first
				local free = 3 - occupied
				if free > 0 then
					local eggs = {}
					for _, egg in pairs(st.eggs or {}) do
						if type(egg) == "table" and egg.id and (tonumber(egg.quantity) or 0) > 0 and hatchWanted(egg) then eggs[#eggs + 1] = egg end
					end
					table.sort(eggs, function(a, b) return (a.zoneNumber or 0) > (b.zoneNumber or 0) end)
					local i = 1
					while free > 0 and eggs[i] do
						local egg = eggs[i]
						local ok, res = call("StartEggHatch-RemoteFunction", egg.id)
						if ok and type(res) == "table" and res.ok then
							stats.hatchStarts += 1
							stats.hatchNote = "started " .. tostring(egg.displayName)
							free -= 1
							egg.quantity = (tonumber(egg.quantity) or 1) - 1
							if egg.quantity <= 0 then i += 1 end
							task.wait(0.5)
						else
							local err = type(res) == "table" and tostring(res.error) or tostring(res)
							stats.hatchNote = ("start %s: %s"):format(tostring(egg.displayName), err)
							if err == "HatcheryFull" then break end
							i += 1
						end
					end
				elseif soonest then
					stats.hatchNote = ("3/3 hatching, next in %dh %02dm"):format(soonest // 3600, (soonest % 3600) // 60)
				end
			end)
		end
		task.wait(5)
	end
end)

-- ---------------------------------------------------------------- Auto Skip Animation
-- Measured live before building this: the SERVER has essentially no
-- end-of-level delay -- StageCleared, the CurrentLevel attribute change, and
-- AutoProgressionAdvanced all land in the same tick (0.0s apart, 3 levels
-- in a row), and a boss goes intro -> active in 1.6s. The animations the
-- player sits through are client-side only: the stage-clear banner, the
-- zone-intro cinematic (ZoneIntroGui), area transitions (AreaTransitionGui)
-- and the boss intro overlay (BossIntroGui), which also grabs the camera
-- (CameraType Scriptable) for its cinematic. None of them gate anything
-- server-side, so skipping is purely local:
--   - keep those ScreenGuis disabled while the toggle is on (re-enabled the
--     moment it's turned off, nothing is destroyed);
--   - hand the camera back to the player whenever an intro takes it;
--   - if the zone-intro remotes exist at the time (they come and go --
--     ZoneIntroStarted wasn't present during a later probe), acknowledge
--     completion straight away and ask for future intros to be deferred.
-- HeroRollRevealGui is deliberately left alone: hero-summon reveals go
-- through their own Acknowledge*HeroSummon remotes and shouldn't be hidden.
local SKIP_GUIS = {"ZoneIntroGui", "AreaTransitionGui", "BossIntroGui"}
local skipGuiWasEnabled = {}

-- Event-driven skip, on top of the 0.5s poll below. The poll alone was
-- reported as "the boss fade is still there": diffing every GuiObject
-- during a live boss intro showed the intro is BossIntroGui's letterbox
-- bars (BottomLetterbox/…) plus a camera cut (CameraType Scriptable, FOV
-- tweened to ~55) -- both visible for up to a full poll interval before the
-- loop caught them. Three things fire the instant BossIntroStarted arrives:
--   1. press the game's OWN skip control (BossIntroGui…SkipButton) through
--      its connected handlers -- the game then ends its cinematic the way
--      it was designed to, restoring its own camera/FOV state cleanly;
--   2. disable the intro ScreenGuis right away (no 0.5s gap);
--   3. restore the camera on the CameraType change signal itself rather
--      than on the next poll tick.
local function pressGameSkip()
	local pg = plr:FindFirstChild("PlayerGui")
	local gui = pg and pg:FindFirstChild("BossIntroGui")
	local btn = gui and gui:FindFirstChild("SkipButton", true)
	if not (btn and getconnections and (btn:IsA("TextButton") or btn:IsA("ImageButton"))) then return false end
	local pressed = false
	for _, sig in ipairs({"Activated", "MouseButton1Click"}) do
		local okc, conns = pcall(getconnections, btn[sig])
		if okc and type(conns) == "table" then
			for _, c in ipairs(conns) do
				if pcall(function() if c.Function then c.Function() elseif c.Fire then c:Fire() end end) then pressed = true end
			end
		end
	end
	return pressed
end
local function hideIntroGuisNow()
	local pg = plr:FindFirstChild("PlayerGui")
	if not pg then return end
	for _, name in ipairs(SKIP_GUIS) do
		local g = pg:FindFirstChild(name)
		if g and g:IsA("ScreenGui") and g.Enabled then skipGuiWasEnabled[name] = true g.Enabled = false end
	end
end
local function restoreCameraNow()
	local cam = workspace.CurrentCamera
	if not cam then return end
	if cam.CameraType ~= Enum.CameraType.Custom then cam.CameraType = Enum.CameraType.Custom end
	cam.FieldOfView = 70
end
-- Server-side half of the skip. The client normally reports an intro as
-- finished only once its cinematic has played out: BossIntroServiceClient
-- fires BossIntroCompleted {introId} at the end of the boss intro and
-- ZoneIntroServiceClient fires ZoneIntroCompleted {introId, completionMode}
-- for zone intros -- and the same client code fires them IMMEDIATELY when
-- a hero reveal is open (its own "skip" path). Doing that on every intro
-- tells the server we're done the same tick the intro starts, so it has no
-- reason to hold the encounter for the intro window on our account.
local function completeIntroOnServer(evName, payload)
	if type(payload) ~= "table" or type(payload.introId) ~= "string" or payload.introId == "" then return end
	if evName:find("^BossIntro") then
		local done = net:FindFirstChild("BossIntroCompleted-RemoteEvent")
		if done then pcall(function() done:FireServer({introId = payload.introId}) end) end
	else
		local done = net:FindFirstChild("ZoneIntroCompleted-RemoteEvent")
		if done then pcall(function() done:FireServer({introId = payload.introId, completionMode = "interrupted"}) end) end
	end
end
for _, evName in ipairs({"BossIntroStarted-RemoteEvent", "ZoneIntroStarted-RemoteEvent", "ZoneIntroClientStarted-RemoteEvent"}) do
	local ev = net:FindFirstChild(evName)
	if ev then
		ev.OnClientEvent:Connect(function(payload)
			if getgenv().__SH ~= G then return end
			if e.shSkipIntroServer then completeIntroOnServer(evName, payload) end
			if not e.shSkipAnim then return end
			hideIntroGuisNow()
			restoreCameraNow()
			-- the skip button is created a moment after the event; try a few times
			task.spawn(function()
				for _ = 1, 8 do
					if pressGameSkip() then break end
					task.wait(0.1)
				end
				restoreCameraNow()
			end)
		end)
	end
end
workspace.CurrentCamera:GetPropertyChangedSignal("CameraType"):Connect(function()
	if getgenv().__SH == G and e.shSkipAnim and workspace.CurrentCamera.CameraType ~= Enum.CameraType.Custom then
		task.defer(restoreCameraNow)
	end
end)
-- The game turns BossIntroGui ON a moment *after* BossIntroStarted fires, so
-- disabling it inside that event handler happened too early and the
-- letterbox still showed for ~30 frames (measured at the level-55 boss:
-- camera 0 frames non-Custom, FOV never below 70 -- the camera side was
-- fixed -- but the GUI was Enabled for 30 frames until the 0.5s poll got
-- it). Watching each intro GUI's own Enabled property closes that gap: the
-- frame the game enables it, it's disabled again.
local function guardIntroGui(g)
	if not (g:IsA("ScreenGui") and table.find(SKIP_GUIS, g.Name)) then return end
	g:GetPropertyChangedSignal("Enabled"):Connect(function()
		if getgenv().__SH == G and e.shSkipAnim and g.Enabled then
			skipGuiWasEnabled[g.Name] = true
			g.Enabled = false
		end
	end)
end
do
	local pg = plr:FindFirstChild("PlayerGui")
	if pg then
		for _, g in ipairs(pg:GetChildren()) do guardIntroGui(g) end
		pg.ChildAdded:Connect(guardIntroGui)
	end
end
task.spawn(function()
	while getgenv().__SH == G do
		local pg = plr:FindFirstChild("PlayerGui")
		if pg then
			for _, name in ipairs(SKIP_GUIS) do
				local g = pg:FindFirstChild(name)
				if g and g:IsA("ScreenGui") then
					if e.shSkipAnim then
						if g.Enabled then skipGuiWasEnabled[name] = true g.Enabled = false end
					elseif skipGuiWasEnabled[name] then
						g.Enabled = true skipGuiWasEnabled[name] = nil
					end
				end
			end
		end
		if e.shSkipAnim then
			local cam = workspace.CurrentCamera
			if cam and cam.CameraType ~= Enum.CameraType.Custom then
				-- Cutting a cinematic mid-tween leaves the camera wherever the
				-- intro had dragged it: measured live after a boss intro was
				-- skipped -- FieldOfView 58 (default 70) and the camera parked
				-- 62 studs from the character, which reads as "the screen
				-- zoomed". Handing the camera back isn't enough on its own; the
				-- intro's own restore code never runs, so restore it here:
				-- default FOV, and force the Custom camera's zoom back to a
				-- normal third-person distance by pinning the zoom limits for
				-- one frame (the only way to set Custom-camera zoom from a
				-- script), then giving the player's limits back.
				cam.CameraType = Enum.CameraType.Custom
				cam.FieldOfView = 70
				task.spawn(function()
					local minZ, maxZ = plr.CameraMinZoomDistance, plr.CameraMaxZoomDistance
					plr.CameraMinZoomDistance, plr.CameraMaxZoomDistance = 12, 12
					task.wait(0.1)
					plr.CameraMinZoomDistance, plr.CameraMaxZoomDistance = minZ, maxZ
				end)
			end
		end
		-- Backstop for an intro that was already running when the script
		-- loaded (no Started event to catch): ask the server what's in
		-- flight and complete it. Both state remotes answer phase="intro"
		-- with the introId while one is active.
		if e.shSkipIntroServer then
			local zs = net:FindFirstChild("GetZoneIntroState-RemoteFunction")
			if zs then
				local ok, st = pcall(function() return zs:InvokeServer() end)
				if ok and type(st) == "table" and st.phase == "intro" then completeIntroOnServer("ZoneIntro", st) end
			end
			local bs = net:FindFirstChild("GetBossEncounterState-RemoteFunction")
			if bs then
				local ok, st = pcall(function() return bs:InvokeServer() end)
				if ok and type(st) == "table" and st.phase == "intro" then completeIntroOnServer("BossIntro", st) end
			end
		end
		task.wait(0.5)
	end
end)

-- ---------------------------------------------------------------- Anti-AFK
plr.Idled:Connect(function()
	if e.shAntiAFK then
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end
end)

-- ---------------------------------------------------------------- Auto Reconnect
if not getgenv().__SHReconnectHooked then
	getgenv().__SHReconnectHooked = true
	Players.PlayerRemoving:Connect(function(player)
		if player == plr and e.shAutoReconnect then
			pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
		end
	end)
end

-- ---------------------------------------------------------------------- UI
print("[SoulHero] Loading MacLib...")
local okLib, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okLib or not Lib then print("[SoulHero] MacLib failed: " .. tostring(Lib)) return end
task.wait()
if getgenv().__SH ~= G or e.__shTok ~= myUID then print("[SoulHero] Aborted (superseded)") return end

local W = Lib:Window({Title = "Soul Hero", Subtitle = "farm / orbit / inventory automation",
                       DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__SHW = W
local TG = W:TabGroup()
local Tabs = {
	Farm = TG:Tab({Name = "Farm", Image = "rbxassetid://10723343321"}),
	Orbit = TG:Tab({Name = "Orbit", Image = "rbxassetid://10734963191"}),
	Inventory = TG:Tab({Name = "Inventory", Image = "rbxassetid://10723396402"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}

-- ----- Farm Tab -----
local FL = Tabs.Farm:Section({Side = "Left"})
FL:Header({Text = "Farm"})
FL:Toggle({Name = "Auto Farm Mob", Default = e.shFarmEnabled,
	Callback = function(v) e.shFarmEnabled = v; sv() end}, "shFarmEnabled")
FL:Toggle({Name = "Auto M1", Default = e.shM1Enabled,
	Callback = function(v) e.shM1Enabled = v; sv() end}, "shM1Enabled")
FL:Slider({
	Name = "M1 Interval", Default = e.shM1Interval, Minimum = 0.01, Maximum = 2,
	DisplayMethod = "Float", Precision = 2,
	Callback = function(v) e.shM1Interval = v; sv() end,
}, "shM1Interval")
FL:Toggle({Name = "Auto Collect Coin (Instant)", Default = e.shCollectEnabled,
	Callback = function(v) e.shCollectEnabled = v; sv() end}, "shCollectEnabled")
FL:Toggle({Name = "Auto Next Stage", Default = e.shNextStageEnabled,
	Callback = function(v) e.shNextStageEnabled = v; sv() end}, "shNextStageEnabled")
FL:Header({Text = "Loop Level"})
FL:Toggle({Name = "Loop Level (stay on chosen level)", Default = e.shLoopLevelEnabled,
	Callback = function(v) e.shLoopLevelEnabled = v; sv() end}, "shLoopLevelEnabled")
-- Level list is built once at UI time from the highest level the account
-- has ever unlocked (LifetimeUnlockedLevel survives rebirths; UnlockedLevel
-- resets to 1 with each one), padded to at least 50 so the list still
-- covers levels unlocked later in the same session. Picking a level the
-- account hasn't unlocked yet is a harmless soft-no on SetCurrentLevel.
local maxLevel = math.max(tonumber(plr:GetAttribute("LifetimeUnlockedLevel")) or 0,
                          tonumber(plr:GetAttribute("UnlockedLevel")) or 0, 50)
local LEVEL_OPTIONS = {}
for i = 1, maxLevel do LEVEL_OPTIONS[i] = "Level " .. i end
FL:Dropdown({
	Name = "Loop Which Level", Multi = false, Required = true, Search = true,
	Options = LEVEL_OPTIONS,
	Default = math.clamp(math.floor(e.shLoopLevel), 1, maxLevel),   -- single-select Default is an INDEX
	Callback = function(v)
		local picked = type(v) == "table" and v[1] or v
		local n = picked and tonumber(tostring(picked):match("%d+"))
		if n then e.shLoopLevel = n; sv() end
	end,
}, "shLoopLevel")
FL:Header({Text = "World Boss"})
FL:Toggle({Name = "Auto World Boss", Default = e.shWorldBossEnabled,
	Callback = function(v) e.shWorldBossEnabled = v; sv() end}, "shWorldBossEnabled")
FL:Dropdown({
	Name = "Which Bosses", Multi = true, Required = false,
	Options = WB_NAMES,
	Default = e.shWorldBossPick,   -- multi-select Default is an array of names
	Callback = function(v)
		-- MacLib hands a {name=true} set for multi-select; keep the saved
		-- shape as an ordered array so the Default round-trips on reload
		local picked = {}
		if type(v) == "table" then
			for _, name in ipairs(WB_NAMES) do
				if v[name] == true then picked[#picked + 1] = name end
			end
			for _, name in ipairs(v) do
				if type(name) == "string" and not table.find(picked, name) then picked[#picked + 1] = name end
			end
		end
		e.shWorldBossPick = picked
		sv()
	end,
}, "shWorldBossPick")
FL:Label({Text = "When a picked boss spawns (every hour) the farm drops\nwhat it's doing, joins the arena, fights with the same\norbit + M1, then walks back to Combat and resumes."})
FL:Dropdown({
	Name = "Title During World Boss", Multi = false, Required = true, Search = true,
	Options = TITLE_OPTIONS,
	Default = titleIndexOf(e.shWbTitleId),   -- single-select Default is an INDEX
	Callback = function(v)
		local picked = type(v) == "table" and v[1] or v
		local idx = table.find(TITLE_OPTIONS, picked)
		if idx then e.shWbTitleId = TITLE_IDS[idx] or ""; sv() end
	end,
}, "shWbTitleId")
FL:Dropdown({
	Name = "Title After World Boss", Multi = false, Required = true, Search = true,
	Options = TITLE_OPTIONS,
	Default = titleIndexOf(e.shFarmTitleId),
	Callback = function(v)
		local picked = type(v) == "table" and v[1] or v
		local idx = table.find(TITLE_OPTIONS, picked)
		if idx then
			e.shFarmTitleId = TITLE_IDS[idx] or ""
			sv()
			if plr:GetAttribute("PlayerArea") ~= "ServerBoss" then pcall(equipTitle, e.shFarmTitleId) end
		end
	end,
}, "shFarmTitleId")
FL:Label({Text = "Only titles you own are listed, with their equipped buff.\nThe first is worn inside the arena, the second is put back\non the way out (and is your everyday farm title)."})
FL:Header({Text = "Animation"})
FL:Toggle({Name = "Auto Skip Animation", Default = e.shSkipAnim,
	Callback = function(v) e.shSkipAnim = v; sv() end}, "shSkipAnim")
FL:Toggle({Name = "Skip Boss Intro (server)", Default = e.shSkipIntroServer,
	Callback = function(v) e.shSkipIntroServer = v; sv() end}, "shSkipIntroServer")
FL:Label({Text = "Reports every boss / zone intro as finished the tick it\nstarts (BossIntroCompleted / ZoneIntroCompleted), so the\nserver doesn't hold the encounter for the intro window."})
FL:Toggle({Name = "Auto Continue After Defeat", Default = e.shDefeatContinue,
	Callback = function(v) e.shDefeatContinue = v; sv() end}, "shDefeatContinue")
FL:Label({Text = "Presses \"Return to last stage\" on the defeat screen. The\n\"Revive & Continue\" button is a Robux product and is\nnever pressed."})
FL:Label({Text = "Hides the stage-clear / zone-intro / boss-intro cinematics\nand hands the camera back. Server-side there's no delay to\nskip -- the next level starts the same tick a stage clears."})

local FR = Tabs.Farm:Section({Side = "Right"})
FR:Header({Text = "Status"})
local farmStatusLbl = FR:Label({Text = "Starting..."})

-- ----- Orbit Tab -----
local OL = Tabs.Orbit:Section({Side = "Left"})
OL:Header({Text = "Orbit"})
OL:Toggle({Name = "Orbit and Fly Around Mob", Default = e.shOrbitEnabled,
	Callback = function(v) e.shOrbitEnabled = v; sv() end}, "shOrbitEnabled")
OL:Dropdown({
	Name = "Orbit Mode", Multi = false, Required = true,
	-- single-select Default is an index, not the option string (a string left
	-- the box blank on every reload and looked like the choice hadn't saved)
	Options = {"On Head", "On Foot"}, Default = (e.shOrbitMode == "On Head") and 1 or 2,
	Callback = function(v)
		local picked = type(v) == "table" and v[1] or v
		if picked then e.shOrbitMode = picked; sv() end
	end,
}, "shOrbitMode")
local OR_ = Tabs.Orbit:Section({Side = "Right"})
OR_:Header({Text = "Tuning"})
OR_:Slider({
	Name = "Orbit Speed", Default = e.shOrbitSpeed, Minimum = 10, Maximum = 360,
	DisplayMethod = "Number", Precision = 0,
	Callback = function(v) e.shOrbitSpeed = v; sv() end,
}, "shOrbitSpeed")
OR_:Slider({
	Name = "Height", Default = e.shOrbitHeight, Minimum = 0, Maximum = 40,
	DisplayMethod = "Number", Precision = 0,
	Callback = function(v) e.shOrbitHeight = v; sv() end,
}, "shOrbitHeight")
OR_:Slider({
	Name = "Distant", Default = e.shOrbitDistance, Minimum = 3, Maximum = 30,
	DisplayMethod = "Number", Precision = 0,
	Callback = function(v) e.shOrbitDistance = v; sv() end,
}, "shOrbitDistance")

-- ----- Inventory Tab -----
local IL = Tabs.Inventory:Section({Side = "Left"})
IL:Header({Text = "Units"})
IL:Toggle({Name = "Auto Equip Best", Default = e.shEquipBestEnabled,
	Callback = function(v) e.shEquipBestEnabled = v; sv() end}, "shEquipBestEnabled")
IL:Header({Text = "Progression"})
IL:Toggle({Name = "Auto Upgrade Skill Tree", Default = e.shSkillTreeEnabled,
	Callback = function(v) e.shSkillTreeEnabled = v; sv() end}, "shSkillTreeEnabled")
-- Ranked slots instead of drag & drop (MacLib has no reorderable list
-- widget): Priority 1 is bought first, then 2, and so on; "None" leaves a
-- slot empty. Each pick is written straight into e.shUpgradeOrder at that
-- slot and saved. MacLib single-select Default is an INDEX into Options
-- (not the option string -- passing the string left the box blank on every
-- reload, which read as "the dropdown doesn't save" even though the value
-- itself had persisted), so the saved label is mapped back to its index.
IL:Label({Text = "Priority slots: 1 is bought first, then 2, 3... Pick 'None' to leave a slot empty."})
local function priorityIndex(label)
	for i, opt in ipairs(PRIORITY_OPTIONS) do if opt == label then return i end end
	return 1
end
for slot = 1, PRIORITY_SLOTS do
	IL:Dropdown({
		Name = ("Priority %d"):format(slot), Multi = false, Required = true, Search = true,
		Options = PRIORITY_OPTIONS,
		Default = priorityIndex(e.shUpgradeOrder[slot]),
		Callback = function(v)
			local picked = type(v) == "table" and v[1] or v
			if type(picked) ~= "string" then return end
			-- Slot-stable storage: the array always has exactly PRIORITY_SLOTS
			-- entries, "None" marking an empty slot, so slot 3 in the UI is
			-- always index 3 in the file. (Compacting on every change looked
			-- neat but shifted later picks into earlier indices and then a
			-- change to an earlier slot silently overwrote them.) The buy loop
			-- skips "None" and duplicates itself.
			for i = 1, PRIORITY_SLOTS do
				if type(e.shUpgradeOrder[i]) ~= "string" then e.shUpgradeOrder[i] = "None" end
			end
			e.shUpgradeOrder[slot] = picked
			sv()
		end,
	}, "shUpgradeOrder" .. slot)
end
IL:Toggle({Name = "Then buy everything else (Max Buy)", Default = e.shUpgradeRest,
	Callback = function(v) e.shUpgradeRest = v; sv() end}, "shUpgradeRest")
IL:Toggle({Name = "Auto Claim Quest", Default = e.shQuestEnabled,
	Callback = function(v) e.shQuestEnabled = v; sv() end}, "shQuestEnabled")
IL:Toggle({Name = "Auto Claim Index", Default = e.shIndexEnabled,
	Callback = function(v) e.shIndexEnabled = v; sv() end}, "shIndexEnabled")
IL:Toggle({Name = "Auto Rebirth", Default = e.shRebirthEnabled,
	Callback = function(v) e.shRebirthEnabled = v; sv() end}, "shRebirthEnabled")
-- Boss stages are every 10 levels (10, 20 ... 100) and rebirth only unlocks
-- past one, so the picker is the boss list plus an "as soon as allowed" row.
-- Stored as the level number (0 = ASAP); the Default is the option INDEX,
-- so a saved level maps back through REBIRTH_STAGE_LEVELS on reload.
-- Runs go well past 100 (level 145 seen live in one session), so the list
-- covers every 10th stage up to 1,000 -- the game's own "Limitless" title
-- is for reaching stage 1,000. Search is on, so typing "250" finds it.
local REBIRTH_STAGE_OPTIONS, REBIRTH_STAGE_LEVELS = {"As soon as allowed"}, {0}
for lv = 10, 1000, 10 do
	REBIRTH_STAGE_OPTIONS[#REBIRTH_STAGE_OPTIONS + 1] = ("Stage %d"):format(lv)
	REBIRTH_STAGE_LEVELS[#REBIRTH_STAGE_LEVELS + 1] = lv
end
local function rebirthStageIndex(level)
	for i, lv in ipairs(REBIRTH_STAGE_LEVELS) do
		if lv == level then return i end
	end
	return 1
end
IL:Dropdown({
	Name = "Rebirth At Stage", Multi = false, Required = true, Search = true,
	Options = REBIRTH_STAGE_OPTIONS,
	Default = rebirthStageIndex(e.shRebirthMinLevel),
	Callback = function(v)
		local picked = type(v) == "table" and v[1] or v
		if type(picked) ~= "string" then return end
		e.shRebirthMinLevel = tonumber(picked:match("%d+")) or 0
		sv()
	end,
}, "shRebirthMinLevel")
IL:Label({Text = "Waits until CurrentLevel reaches the picked boss stage,\nthen rebirths the moment the game reports canRebirth.\n\"As soon as allowed\" = the first stage the game unlocks."})
IL:Header({Text = "Hero Evolution"})
IL:Toggle({Name = "Auto Evolve Hero", Default = e.shEvolveHeroEnabled,
	Callback = function(v) e.shEvolveHeroEnabled = v; sv() end}, "shEvolveHeroEnabled")
IL:Label({Text = "Starts every awakening the game lists as eligible and\nclaims each one the moment its timer ends (the Backpack's\n\"Claim!\" button) -- no reveal to tap through."})
IL:Header({Text = "Eggs"})
IL:Toggle({Name = "Auto Hatch", Default = e.shHatchEnabled,
	Callback = function(v) e.shHatchEnabled = v; sv() end}, "shHatchEnabled")
IL:Dropdown({
	Name = "Which Eggs", Multi = true, Required = false,
	Options = #EGG_OPTIONS > 0 and EGG_OPTIONS or {"Village Egg", "Forest Egg", "Cave Egg", "Bandit Kingdom Egg", "Titanridge Mountains Egg", "Vikings Territory Egg", "Fallen Crown Castle Egg"},
	Default = e.shHatchEggs,   -- multi-select Default is an array of names
	Callback = function(v)
		local picked = {}
		if type(v) == "table" then
			for _, name in ipairs(EGG_OPTIONS) do
				if v[name] == true then picked[#picked + 1] = name end
			end
			for _, name in ipairs(v) do
				if type(name) == "string" and not table.find(picked, name) then picked[#picked + 1] = name end
			end
		end
		e.shHatchEggs = picked
		sv()
	end,
}, "shHatchEggs")
IL:Label({Text = "Keeps all 3 hatchery slots busy (highest-zone egg first)\nand claims each egg the moment it finishes. Empty pick =\nany egg you own."})

local IR = Tabs.Inventory:Section({Side = "Right"})
IR:Header({Text = "Status"})
local invStatusLbl = IR:Label({Text = "Starting..."})

-- ----- Settings Tab -----
local SL = Tabs.Settings:Section({Side = "Left"})
SL:Header({Text = "General"})
SL:Toggle({Name = "Anti-AFK", Default = e.shAntiAFK,
	Callback = function(v) e.shAntiAFK = v; sv() end}, "shAntiAFK")
SL:Toggle({Name = "Auto Reconnect", Default = e.shAutoReconnect,
	Callback = function(v) e.shAutoReconnect = v; sv() end}, "shAutoReconnect")
SL:Keybind({
	Name = "Show/Hide UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() W:SetState(not W:GetState()) end) end,
}, "SoulHeroToggleUIKeybind")
SL:Header({Text = "Auto Save"})
SL:Label({Text = "All toggles save automatically to:\n" .. SF})

task.spawn(function()
	while getgenv().__SH == G do
		task.wait(1)
		pcall(function()
			farmStatusLbl:UpdateName(("Target: %s\nHits: %d\nCoins collected: %d\nWorld Boss: %s"):format(
				stats.target, stats.hits, stats.collected, stats.worldBoss))
		end)
		pcall(function()
			invStatusLbl:UpdateName(("Equips: %d\nSkill nodes bought: %d\nQuests claimed: %d\nIndex claims: %d\nRebirths: %d (%s)\nEvolve: %d started / %d claimed (%s)\nHatch: %d started / %d claimed (%s)"):format(
				stats.equips, stats.skillNodes, stats.quests, stats.index, stats.rebirths, stats.rebirthNote,
				stats.evolveStarts, stats.evolveClaims, stats.evolveNote, stats.hatchStarts, stats.hatchClaims, stats.hatchNote))
		end)
	end
end)

W.onUnloaded(function() print("[SoulHero] Unloaded") end)
Tabs.Farm:Select()
print("[SoulHero] UI ready")
