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

local stats = {hits = 0, collected = 0, equips = 0, skillNodes = 0, quests = 0, index = 0, rebirths = 0, rebirthNote = "-", target = "-"}

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

local function refreshTarget()
	local ok, entries = call("GetEnemyLedgerEntries-RemoteFunction")
	if not ok or type(entries) ~= "table" then currentTarget = nil return end

	local enemiesFolder = workspace:FindFirstChild("Game") and workspace.Game:FindFirstChild("Enemies")
	if not enemiesFolder then currentTarget = nil return end

	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then currentTarget = nil return end

	local best, bestDist, bestPart
	for _, entry in pairs(entries) do
		-- skip anything without a real hp reading -- bosses (BossIntroPending)
		-- didn't carry one in testing; a mob mid-farm always did
		-- Boss entries DO carry hp (measured live: 62,814 / 108,289 / 380,874 on
		-- the level 25/30/35 bosses) -- the earlier "bosses have no hp block"
		-- read was wrong. The hp==nil allowance below is kept purely as a
		-- safety net so a ledger entry that ever omits hp isn't silently
		-- dropped as a target. Since M1 is Tool:Activate() and the SERVER picks
		-- what's in the weapon arc, orbiting a boss is all that's needed to
		-- fight it; a pre-intro boss answers BossIntroPending for the ~1.6s its
		-- intro lasts, then hits land normally.
		local alive = entry.enemyId and (entry.hp == nil or (entry.hp.current or 0) > 0)
		if alive then
			for _, m in ipairs(enemiesFolder:GetChildren()) do
				if m.Name == entry.archetypeId then
					local part = bodyPartOf(m)
					if part then
						local d = (hrp.Position - part.Position).Magnitude
						if not bestDist or d < bestDist then
							best, bestDist, bestPart = entry, d, part
						end
					end
					break
				end
			end
		end
	end

	if best then
		currentTarget = {enemyId = best.enemyId, part = bestPart, position = bestPart.Position}
		stats.target = tostring(best.archetypeId)
	else
		currentTarget = nil
		stats.target = "-"
	end
end

task.spawn(function()
	while getgenv().__SH == G do
		if e.shFarmEnabled or e.shOrbitEnabled then
			pcall(refreshTarget)
		end
		task.wait(1)
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

	local shouldFly = e.shOrbitEnabled and currentTarget ~= nil
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
		if e.shRebirthEnabled then
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
		task.wait(30)
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
			-- "Revive & Continue" and is left alone on purpose.
			pcall(function()
				local pg = plr:FindFirstChild("PlayerGui")
				local screen = pg and pg:FindFirstChild("GameUI") and pg.GameUI:FindFirstChild("VictoryEndScreen", true)
				local btn = screen and screen:FindFirstChild("NextStage", true)
				if btn and btn.Visible and (btn:IsA("TextButton") or btn:IsA("ImageButton")) and getconnections then
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
				end
			end)
			if plr:GetAttribute("PlayerArea") == "Lobby" then
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
		-- 3s, not 10: watched live with Loop pinned to level 8, the game
		-- re-enabled auto-progression and jumped to level 11 on a wave clear
		-- between polls, and a 10s gap left the account farming the wrong level
		-- for most of that window before the pin caught it. 3s keeps the drift
		-- to a couple of seconds at most.
		task.wait(3)
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
for _, evName in ipairs({"BossIntroStarted-RemoteEvent", "ZoneIntroStarted-RemoteEvent", "ZoneIntroClientStarted-RemoteEvent"}) do
	local ev = net:FindFirstChild(evName)
	if ev then
		ev.OnClientEvent:Connect(function()
			if getgenv().__SH ~= G or not e.shSkipAnim then return end
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
			local zc = net:FindFirstChild("ZoneIntroCompleted-RemoteEvent")
			local zd = net:FindFirstChild("SetZoneIntroDeferred-RemoteEvent")
			local zs = net:FindFirstChild("GetZoneIntroState-RemoteFunction")
			if zs and zc then
				local ok, st = pcall(function() return zs:InvokeServer() end)
				if ok and type(st) == "table" and (st.active or st.isActive or st.introId) then
					pcall(function() zc:FireServer(st.introId or st) end)
					if zd then pcall(function() zd:FireServer(true) end) end
				end
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
FL:Header({Text = "Animation"})
FL:Toggle({Name = "Auto Skip Animation", Default = e.shSkipAnim,
	Callback = function(v) e.shSkipAnim = v; sv() end}, "shSkipAnim")
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
IL:Label({Text = "Auto Rebirth only ever fires when the game itself\nreports canRebirth -- never forces one early."})

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
			farmStatusLbl:UpdateName(("Target: %s\nHits: %d\nCoins collected: %d"):format(
				stats.target, stats.hits, stats.collected))
		end)
		pcall(function()
			invStatusLbl:UpdateName(("Equips: %d\nSkill nodes bought: %d\nQuests claimed: %d\nIndex claims: %d\nRebirths: %d (%s)"):format(
				stats.equips, stats.skillNodes, stats.quests, stats.index, stats.rebirths, stats.rebirthNote))
		end)
	end
end)

W.onUnloaded(function() print("[SoulHero] Unloaded") end)
Tabs.Farm:Select()
print("[SoulHero] UI ready")
