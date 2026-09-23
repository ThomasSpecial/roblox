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
	"shQuestEnabled", "shIndexEnabled", "shRebirthEnabled",
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
if e.shM1Interval == nil then e.shM1Interval = 0.1 end
if e.shCollectEnabled == nil then e.shCollectEnabled = true end
if e.shOrbitEnabled == nil then e.shOrbitEnabled = true end
if e.shOrbitMode == nil then e.shOrbitMode = "On Foot" end
if e.shOrbitSpeed == nil then e.shOrbitSpeed = 60 end
if e.shOrbitHeight == nil then e.shOrbitHeight = 6 end
if e.shOrbitDistance == nil then e.shOrbitDistance = 8 end
if e.shEquipBestEnabled == nil then e.shEquipBestEnabled = true end
if e.shSkillTreeEnabled == nil then e.shSkillTreeEnabled = true end
if e.shQuestEnabled == nil then e.shQuestEnabled = true end
if e.shIndexEnabled == nil then e.shIndexEnabled = true end
if e.shRebirthEnabled == nil then e.shRebirthEnabled = true end
if e.shAntiAFK == nil then e.shAntiAFK = true end
if e.shAutoReconnect == nil then e.shAutoReconnect = true end

local stats = {hits = 0, collected = 0, equips = 0, skillNodes = 0, quests = 0, index = 0, rebirths = 0, target = "-"}

-- ---------------------------------------------------------------- shared target tracking
-- Auto Farm Mob, Auto M1, and Orbit all need "which enemy, and where is it"
-- -- computed once here every 1s and shared, instead of three separate loops
-- each re-deriving it (and re-InvokeServer'ing the ledger) independently.
local currentTarget = nil   -- {enemyId, part, position}

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
		if entry.hp and entry.hp.current and entry.hp.current > 0 and entry.enemyId then
			for _, m in ipairs(enemiesFolder:GetChildren()) do
				if m.Name == entry.archetypeId then
					local part = m:FindFirstChildWhichIsA("BasePart", true)
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

	orbitAngle = (orbitAngle + math.rad(e.shOrbitSpeed) * dt) % (2 * math.pi)
	local dist = e.shOrbitDistance
	local height = (e.shOrbitMode == "On Head") and (e.shOrbitHeight + 6) or math.max(e.shOrbitHeight, 0)
	local offset = Vector3.new(math.cos(orbitAngle) * dist, height, math.sin(orbitAngle) * dist)
	local pos = currentTarget.position + offset
	hrp.CFrame = CFrame.new(pos, currentTarget.position)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
end)

-- ---------------------------------------------------------------- Auto Farm Mob / Auto M1
task.spawn(function()
	while getgenv().__SH == G do
		if (e.shFarmEnabled and e.shM1Enabled) and currentTarget then
			local ok = fire("PlayerWeaponAttackRequested-RemoteEvent", currentTarget.enemyId)
			if ok then stats.hits += 1 end
		end
		task.wait(math.max(e.shM1Interval or 0.1, 0.05))
	end
end)

-- ---------------------------------------------------------------- Auto Collect Coin (Instant)
task.spawn(function()
	while getgenv().__SH == G do
		if e.shCollectEnabled then
			local ok, groups = call("GetDropGroups-RemoteFunction")
			if ok and type(groups) == "table" then
				for _, grp in pairs(groups) do
					if getgenv().__SH ~= G then break end
					if grp.dropGroupId then
						local cok, res = call("ClaimDropSlice-RemoteFunction", grp.dropGroupId)
						if cok and type(res) == "table" and res.ok then
							stats.collected += 1
						end
						task.wait(0.15)
					end
				end
			end
		end
		task.wait(3)
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

task.spawn(function()
	while getgenv().__SH == G do
		if e.shSkillTreeEnabled then
			local ok, res = call("MaxBuySkillTreeNodes-RemoteFunction")
			if ok and type(res) == "table" and res.purchasedCount and res.purchasedCount > 0 then
				stats.skillNodes += res.purchasedCount
			end
		end
		task.wait(15)
	end
end)

-- ---------------------------------------------------------------- Auto Claim Quest
task.spawn(function()
	while getgenv().__SH == G do
		if e.shQuestEnabled then
			local ok, res = call("GetQuestState-RemoteFunction")
			if ok and type(res) == "table" and res.categories then
				for _, cat in pairs(res.categories) do
					for _, q in ipairs(cat.quests or {}) do
						if getgenv().__SH ~= G then break end
						if q.completed and not q.claimed and q.id then
							local cok, cres = call("ClaimQuestReward-RemoteFunction", q.id)
							if cok and type(cres) == "table" and cres.ok then
								stats.quests += 1
							end
							task.wait(0.2)
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
				local rok = call("AttemptRebirth-RemoteFunction")
				if rok then stats.rebirths += 1 end
			end
		end
		task.wait(30)
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
	Name = "M1 Interval", Default = e.shM1Interval, Minimum = 0.05, Maximum = 2,
	DisplayMethod = "Float", Precision = 2,
	Callback = function(v) e.shM1Interval = v; sv() end,
}, "shM1Interval")
FL:Toggle({Name = "Auto Collect Coin (Instant)", Default = e.shCollectEnabled,
	Callback = function(v) e.shCollectEnabled = v; sv() end}, "shCollectEnabled")

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
	Options = {"On Head", "On Foot"}, Default = e.shOrbitMode,
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
			invStatusLbl:UpdateName(("Equips: %d\nSkill nodes bought: %d\nQuests claimed: %d\nIndex claims: %d\nRebirths: %d"):format(
				stats.equips, stats.skillNodes, stats.quests, stats.index, stats.rebirths))
		end)
	end
end)

W.onUnloaded(function() print("[SoulHero] Unloaded") end)
Tabs.Farm:Select()
print("[SoulHero] UI ready")
