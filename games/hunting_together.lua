-- Hunting Together RPG [RonB Games, placeId 117483759937632] -- Auto Boss + UI
--
-- Flow: farm at a saved spot with the game's own Auto Attack -> when a ticked
-- world boss spawns, turn Auto off, WALK to its arena, lock it and fight with
-- Auto on -> when it dies, walk back to the saved spot and resume farming.
--
-- Verified live (2026-11-10, Papiyongzzz, Thief Lv97, placeVersion 852):
--   - Server anti-cheat (CheatWatchClient) flags Teleport / Rapid teleport /
--     Flying / Noclip-underground, so every move here is a real walk
--     (Humanoid:MoveTo), never a CFrame write.
--   - Boss state is replicated on workspace attributes:
--       BossAlive_<monsterId> = true/false, BossNext_<monsterId> = unix respawn.
--     The boss MODEL only streams into workspace.Monsters once you are near
--     its arena (StreamingEnabled), tagged IsBoss=true, MonsterId=<id>, HP attr.
--   - Map is one chain of islands along -Z; ReplicatedStorage attribute
--     NavMapJson = {Zones={Field01..15, Boss01..05 = {X,Z,SX,SZ}}, Gates={{X,Z}}}.
--     The game's own quest-nav walks gate-to-gate (gate.Z -/+ 10); same here.
--     MonsterData[id].Zone = 3/6/9/12/15 -> arena "Boss%02d" (Zone/3).
--   - Auto Attack toggles via LocalPlayer.LumiMenuToggle:Fire("autoToggle")
--     (same path as the F key); state mirrors LocalPlayer attribute AutoOn.
--   - LocalPlayer.LumiLockTarget:Fire(model) is the game's own target lock
--     (CombatClient chases + attacks it); LocalPlayer.CurrentTarget is the
--     ObjectValue holding the active target.

getgenv().__G = (getgenv().__G or 0) + 1
local G = getgenv().__G
pcall(function() if getgenv().__W then getgenv().__W:Unload() end end)
local e = getgenv()
local myUID = tostring(math.random(1, 2 ^ 30))
e.__tok = myUID
print("[HTBoss] Starting (gen " .. G .. ")...")

local HUNTING_TOGETHER = 117483759937632
if game.PlaceId ~= HUNTING_TOGETHER then print("[HTBoss] Wrong place, aborting") return end

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HS = game:GetService("HttpService")
local plr = Players.LocalPlayer
local MonsterData = require(RS:WaitForChild("Shared"):WaitForChild("MonsterData"))
-- 60s: from autoexec on a fresh join the game's PlayerScripts are still loading.
local menuToggle = plr:WaitForChild("LumiMenuToggle", 60)
local lockTarget = plr:WaitForChild("LumiLockTarget", 60)
local currentTarget = plr:WaitForChild("CurrentTarget", 60)
local remotes = RS:WaitForChild("Remotes", 60)
if not (menuToggle and lockTarget and currentTarget and remotes) then print("[HTBoss] Combat hooks not found, aborting") return end

local function alive() return getgenv().__G == G end

-- ---------------------------------------------------------------- state/config
local SF = "HTBoss/state.json"
local SK = {"hbEnabled", "hbBosses", "hbFarmPos", "hbAutoAtFarm", "hbSellOn", "hbSellPick", "hbUseWarp",
            "hbAutoRespawn", "hbRetryBoss", "hbCoatOn", "hbCoatPick", "hbPreArrive", "hbDodge", "hbDash",
            "hbHop", "hbHopWait", "hbHopDelay", "hbReconnect"}
pcall(function() if not isfolder("HTBoss") then makefolder("HTBoss") end end)
local function sv()
	local d = {}
	for _, k in ipairs(SK) do d[k] = e[k] end
	pcall(function() writefile(SF, HS:JSONEncode(d)) end)
end
pcall(function()
	local d = HS:JSONDecode(readfile(SF))
	for _, k in ipairs(SK) do if d[k] ~= nil and e[k] == nil then e[k] = d[k] end end
end)
if e.hbEnabled == nil then e.hbEnabled = false end
if type(e.hbBosses) ~= "table" then e.hbBosses = {} end
if e.hbAutoAtFarm == nil then e.hbAutoAtFarm = true end
if e.hbUseWarp == nil then e.hbUseWarp = true end
if e.hbAutoRespawn == nil then e.hbAutoRespawn = true end
if e.hbRetryBoss == nil then e.hbRetryBoss = true end
if e.hbPreArrive == nil then e.hbPreArrive = true end
if e.hbDodge == nil then e.hbDodge = true end
if e.hbDash == nil then e.hbDash = true end
if e.hbHop == nil then e.hbHop = false end
if tonumber(e.hbHopWait) == nil then e.hbHopWait = 30 end   -- wait for a boss spawning within this
if tonumber(e.hbHopDelay) == nil then e.hbHopDelay = 0 end  -- linger this long before hopping (0 = now)
if e.hbReconnect == nil then e.hbReconnect = true end

local sessionStart = os.clock() -- for the server-hop join-grace below

-- ---------------------------------------------------------------- boss table
local BOSSES = {}
for id, def in pairs(MonsterData) do
	if type(def) == "table" and def.Boss == true and def.ClockRespawn and tonumber(def.Zone) then
		local arena = ("Boss%02d"):format(math.floor(tonumber(def.Zone) / 3))
		table.insert(BOSSES, {id = id, name = def.Name, level = def.Level or 0, arena = arena,
			label = ("%s (Lv%d)"):format(def.Name, def.Level or 0)})
	end
end
table.sort(BOSSES, function(a, b) return a.level < b.level end)
local BY_LABEL, BY_ID = {}, {}
for _, b in ipairs(BOSSES) do BY_LABEL[b.label] = b; BY_ID[b.id] = b end

local function navMap()
	local ok, m = pcall(HS.JSONDecode, HS, RS:GetAttribute("NavMapJson") or "{}")
	return ok and type(m) == "table" and m or {}
end

local function bossAlive(id) return workspace:GetAttribute("BossAlive_" .. id) == true end
local function bossNext(id) return tonumber(workspace:GetAttribute("BossNext_" .. id)) or 0 end

local function findBossModel(id)
	local folder = workspace:FindFirstChild("Monsters")
	if not folder then return nil end
	for _, m in ipairs(folder:GetChildren()) do
		if m:GetAttribute("MonsterId") == id and (tonumber(m:GetAttribute("HP")) or 0) > 0 and m.PrimaryPart then
			return m
		end
	end
	return nil
end

-- ---------------------------------------------------------------- character
local function myChar()
	local c = plr.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then return c, hum, hrp end
	return nil
end

local function autoOn() return plr:GetAttribute("AutoOn") == true end

local function setAuto(want)
	if autoOn() == want then return true end
	menuToggle:Fire("autoToggle")
	local t0 = os.clock()
	while autoOn() ~= want and os.clock() - t0 < 2 do task.wait(0.1) end
	return autoOn() == want
end

local function clearTarget()
	pcall(function() currentTarget.Value = nil end)
end

-- ---------------------------------------------------------------- walking
local stats = {state = "Idle", detail = "-", bossKills = 0, looted = 0, dodges = 0, skillDodges = 0, lastBoss = "-"}
local function setState(s, d) stats.state = s; stats.detail = d or "-" end

-- Crossings between islands. NavMapJson.Gates stops at Z -3508 (the game's own
-- quest-nav never goes deeper), but Field13..Boss05 are joined by bridges too;
-- walking straight at a target past them ran into Field14.Cliffs.Rock and
-- stuck there. Bridges read live from Map.BlockFields.<zone>.Bridge
-- (Deck/Path/Ramp, all at X=0); H = half the crossing length along Z:
local EXTRA_GATES = {
	{X = 0, Z = -3668, H = 20},  -- Boss04 -> Field13 bridge
	{X = 0, Z = -3908, H = 38},  -- Field13 -> Field14 bridge + ramp (-3870..-3946)
	{X = 0, Z = -4164, H = 38},  -- Field14 -> Field15 bridge + ramp (-4126..-4202)
	{X = 0, Z = -4400, H = 20},  -- Field15 -> Boss05 bridge
}

-- Any bridge parts currently streamed in, grouped into crossings by Z overlap.
local function streamedBridges()
	local out = {}
	local fields = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("BlockFields")
	if not fields then return out end
	for _, zone in ipairs(fields:GetChildren()) do
		local br = zone:FindFirstChild("Bridge")
		if br then
			local zmin, zmax, x
			for _, p in ipairs(br:GetDescendants()) do
				if p:IsA("BasePart") and (p.Name == "Deck" or p.Name == "Path" or p.Name == "Ramp") then
					local half = p.Size.Z / 2
					zmin = math.min(zmin or math.huge, p.Position.Z - half)
					zmax = math.max(zmax or -math.huge, p.Position.Z + half)
					x = p.Position.X
				end
			end
			if zmin then table.insert(out, {X = x, Z = (zmin + zmax) / 2, H = (zmax - zmin) / 2}) end
		end
	end
	return out
end

local function allGates()
	local merged = {}
	local function add(g)
		for _, m in ipairs(merged) do
			if math.abs(m.Z - g.Z) < 40 then
				if g.H > m.H then m.X, m.Z, m.H = g.X, g.Z, g.H end
				return
			end
		end
		table.insert(merged, {X = g.X, Z = g.Z, H = g.H})
	end
	for _, g in ipairs(streamedBridges()) do add(g) end
	for _, g in ipairs(EXTRA_GATES) do add(g) end
	for _, g in ipairs(navMap().Gates or {}) do add({X = g.X, Z = g.Z, H = 4}) end
	return merged
end

-- Same idea as the game's quest-nav: every crossing between here and the goal
-- (along Z) becomes an entry and an exit point just past either end, nearest first.
local function buildPath(fromPos, goalX, goalZ)
	local gates = {}
	for _, g in ipairs(allGates()) do
		if (g.Z - fromPos.Z) * (g.Z - goalZ) < 0 then table.insert(gates, g) end
	end
	table.sort(gates, function(a, b) return math.abs(a.Z - fromPos.Z) < math.abs(b.Z - fromPos.Z) end)
	local dir = goalZ < fromPos.Z and -1 or 1
	local pts = {}
	for _, g in ipairs(gates) do
		local off = g.H + 6
		table.insert(pts, Vector2.new(g.X, g.Z - dir * off))
		table.insert(pts, Vector2.new(g.X, g.Z + dir * off))
	end
	table.insert(pts, Vector2.new(goalX, goalZ))
	return pts
end

local function flatDist(pos, p2) return (Vector2.new(pos.X, pos.Z) - p2).Magnitude end

-- Straight lines between gates snag on houses, fences and props, so each leg is
-- walked along a PathfindingService route (recomputed as we go), and when there
-- is no route or we stop gaining ground the fallback is: straight MoveTo, jump,
-- then sidestep left/right. Progress = distance to the leg target shrinking,
-- not just "moved" -- sliding along a wall moves but gets nowhere.
local PathfindingService = game:GetService("PathfindingService")
local PATH_PARAMS = {AgentRadius = 2.5, AgentHeight = 6, AgentCanJump = true, WaypointSpacing = 6}
local LEG_STUCK_S = 14

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function groundAt(x, z, fallbackY)
	local ignore = {workspace:FindFirstChild("Monsters"), workspace:FindFirstChild("Drops"), plr.Character}
	rayParams.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(Vector3.new(x, fallbackY + 120, z), Vector3.new(0, -400, 0), rayParams)
	return hit and hit.Position.Y + 3 or fallbackY
end

local function computeRoute(from, to)
	local path = PathfindingService:CreatePath(PATH_PARAMS)
	local ok = pcall(function() path:ComputeAsync(from, to) end)
	if ok and path.Status == Enum.PathStatus.Success then return path:GetWaypoints() end
	return nil
end

-- Returns "ok" | "abort" | "stuck" | "dead"
local function walkLeg(hum, hrp, target, need, abortIf)
	local best = flatDist(hrp.Position, target)
	local bestAt, jumpAt, sideAt, side = os.clock(), 0, 0, 1
	local route, idx, routeAt = nil, 1, 0
	while flatDist(hrp.Position, target) > need do
		if not alive() then return "abort" end
		if abortIf and abortIf() then hum:MoveTo(hrp.Position); return "abort" end
		if hum.Health <= 0 or not hrp.Parent then return "dead" end
		if hum.Sit then hum.Sit = false end
		local now = os.clock()

		-- (re)plan only when there is no route / it ran out / we stopped gaining ground.
		-- Replanning on a timer made the character hitch every few seconds.
		if (not route or idx > #route or now - bestAt > 1.5) and now - routeAt > 1.5 then
			routeAt = now
			local to = Vector3.new(target.X, groundAt(target.X, target.Y, hrp.Position.Y), target.Y)
			route = computeRoute(hrp.Position, to)
			idx = 2 -- waypoint 1 is where we stand
		end

		local stuckFor = now - bestAt
		if stuckFor > 2.5 and now - sideAt > 2.5 then
			-- sidestep perpendicular to the goal, alternating sides, then replan
			sideAt = now
			local dir = Vector3.new(target.X - hrp.Position.X, 0, target.Y - hrp.Position.Z)
			if dir.Magnitude > 0.1 then
				local perp = Vector3.new(-dir.Z, 0, dir.X).Unit * side * 10
				side = -side
				hum:MoveTo(hrp.Position + perp)
				hum.Jump = true
				task.wait(0.8)
			end
			route = nil
			routeAt = 0
		elseif route and route[idx] then
			-- drop waypoints we're already on top of
			while route[idx] and idx < #route
				and flatDist(hrp.Position, Vector2.new(route[idx].Position.X, route[idx].Position.Z)) <= 5 do
				idx += 1
			end
			-- aim ~3 waypoints (~18 studs) ahead so the humanoid never coasts to a
			-- stop between points; never look past a jump waypoint
			local aim = idx
			while aim < #route and aim < idx + 3 and route[aim].Action ~= Enum.PathWaypointAction.Jump do
				aim += 1
			end
			if route[idx].Action == Enum.PathWaypointAction.Jump
				and flatDist(hrp.Position, Vector2.new(route[idx].Position.X, route[idx].Position.Z)) <= 6 then
				hum.Jump = true
			end
			hum:MoveTo(route[aim].Position)
		else
			hum:MoveTo(Vector3.new(target.X, hrp.Position.Y, target.Y))
			if stuckFor > 1.2 and now - jumpAt > 1 then jumpAt = now; hum.Jump = true end
		end

		task.wait(0.05)
		local d = flatDist(hrp.Position, target)
		if d < best - 1 then best, bestAt = d, os.clock() end
		if os.clock() - bestAt > LEG_STUCK_S then
			hum:MoveTo(hrp.Position)
			return "stuck"
		end
	end
	return "ok"
end

local function walkTo(goalX, goalZ, reach, abortIf)
	local _, hum, hrp = myChar()
	if not hum then return "dead" end
	local pts = buildPath(hrp.Position, goalX, goalZ)
	for i, p in ipairs(pts) do
		local r = walkLeg(hum, hrp, p, (i == #pts) and reach or 6, abortIf)
		if r ~= "ok" then return r end
	end
	hum:MoveTo(hrp.Position)
	return "ok"
end

-- ---------------------------------------------------------------- warp pillars
-- workspace.Map.WarpPillars.WarpPillar_<Id> (attr WarpId = Town/Boss01..05, a
-- "Column" part, WarpPrompt at 12 studs). Remotes.PillarWarp:FireServer(id) is
-- what the pillar's menu fires. Verified live 2026-11-10: fired from ~300 studs
-- away it does nothing; fired standing ~4 studs from a pillar (no prompt needed)
-- the server moved us to the target pillar (Boss03 -> Boss04, 896 studs).
-- Unlocked list = LocalPlayer attr WarpPillars ("Town,Boss02,..."); cost is
-- 1000 Silver per pillar number, free with Premium.
local WARP_OVERHEAD = 40   -- studs-equivalent of the warp + settle delay
local WARP_MIN_SAVING = 120

local function pillarList()
	local folder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("WarpPillars")
	if not folder then return {} end
	local unlocked = {Town = true}
	for id in string.gmatch(tostring(plr:GetAttribute("WarpPillars") or ""), "[^,]+") do unlocked[id] = true end
	local premium = plr:GetAttribute("Premium") == true
	local silver = tonumber(plr:GetAttribute("Silver")) or 0
	local out = {}
	for _, p in ipairs(folder:GetChildren()) do
		local id = p:GetAttribute("WarpId")
		local col = p:FindFirstChild("Column") or p:FindFirstChildWhichIsA("BasePart", true)
		if type(id) == "string" and col and unlocked[id] then
			local cost = premium and 0 or ((tonumber(id:match("(%d+)$")) or 0) * 1000)
			if cost <= silver then table.insert(out, {id = id, pos = col.Position}) end
		end
	end
	return out
end

-- Map is a chain along Z with gates near X=0, so |dZ| + |dX| is a fair walk estimate.
local function walkEst(ax, az, bx, bz) return math.abs(az - bz) + math.abs(ax - bx) end

local function warpFrom(src, dst)
	local _, hum, hrp = myChar()
	if not hum then return false end
	for _ = 1, 2 do
		remotes.PillarWarp:FireServer(dst.id)
		local t0 = os.clock()
		while os.clock() - t0 < 4 do
			task.wait(0.2)
			if not hrp.Parent then return false end
			if flatDist(hrp.Position, Vector2.new(dst.pos.X, dst.pos.Z)) <= 30 then
				task.wait(0.5) -- let the character settle before walking off
				return true
			end
		end
	end
	return false
end

-- Level gates: Map.Barriers.BossLock_<Field> walls across the path (at X=0)
-- with LockText "🔒 Reach Lv.N to pass"; the game turns CanCollide on for you
-- while you are under N. Walking can't cross a locked one, so a pillar or goal
-- on the far side of one is out of reach on foot (warping still jumps it).
local function lockedGateZs()
	local out = {}
	local barriers = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Barriers")
	if not barriers then return out end
	local myLv = tonumber(plr:GetAttribute("Level")) or 1
	for _, p in ipairs(barriers:GetChildren()) do
		if p:IsA("BasePart") and p.Name:match("^BossLock_") then
			local need = tonumber(tostring(p:GetAttribute("LockText") or ""):match("Lv%.?%s*(%d+)"))
			if p.CanCollide or (need and myLv < need) then table.insert(out, p.Position.Z) end
		end
	end
	return out
end

local function walkable(az, bz, locked)
	local lo, hi = math.min(az, bz), math.max(az, bz)
	for _, gz in ipairs(locked) do
		if gz > lo and gz < hi then return false end
	end
	return true
end

-- Cheapest way from `here` to the goal: (src, dst, cost) when a pillar pair
-- beats walking by WARP_MIN_SAVING, else (nil, nil, directCost). Cost in studs;
-- math.huge when every way there crosses a level gate we can't pass yet.
local function planRoute(here, goalX, goalZ)
	local locked = lockedGateZs()
	local direct = walkable(here.Z, goalZ, locked) and walkEst(here.X, here.Z, goalX, goalZ) or math.huge
	if not e.hbUseWarp then return nil, nil, direct end
	local bestSrc, bestDst, bestCost
	local pillars = pillarList()
	for _, s in ipairs(pillars) do
		for _, d in ipairs(pillars) do
			if s ~= d and walkable(here.Z, s.pos.Z, locked) and walkable(d.pos.Z, goalZ, locked) then
				local c = walkEst(here.X, here.Z, s.pos.X, s.pos.Z) + WARP_OVERHEAD + walkEst(d.pos.X, d.pos.Z, goalX, goalZ)
				if not bestCost or c < bestCost then bestSrc, bestDst, bestCost = s, d, c end
			end
		end
	end
	if bestCost and bestCost < direct - WARP_MIN_SAVING then return bestSrc, bestDst, bestCost end
	return nil, nil, direct
end

-- Seconds to get from where we stand to the goal. Paths wiggle (gates, detours
-- round props), so pad the straight estimate by 25% plus a fixed few seconds.
local function travelSeconds(goalX, goalZ)
	local _, hum, hrp = myChar()
	if not hum then return 60 end
	local _, _, cost = planRoute(hrp.Position, goalX, goalZ)
	if cost == math.huge then return -math.huge end -- unreachable: never "time to leave"
	return cost / math.max(hum.WalkSpeed, 8) * 1.25 + 4
end

-- Like walkTo, but goes via a warp pillar pair when that is clearly shorter.
local function travelTo(goalX, goalZ, reach, abortIf)
	local _, hum, hrp = myChar()
	if not hum then return "dead" end
	do
		local bestSrc, bestDst, cost = planRoute(hrp.Position, goalX, goalZ)
		if cost == math.huge then return "stuck" end -- behind a level gate
		if bestSrc then
			local prev = stats.state
			setState(prev, ("ไปเสาวาร์ป %s → %s"):format(bestSrc.id, bestDst.id))
			local r = walkTo(bestSrc.pos.X, bestSrc.pos.Z, 6, abortIf)
			if r ~= "ok" then return r end
			setState(prev, ("วาร์ป %s → %s"):format(bestSrc.id, bestDst.id))
			warpFrom(bestSrc, bestDst) -- on failure just walk the rest from here
			if abortIf and abortIf() then return "abort" end
		end
	end
	return walkTo(goalX, goalZ, reach, abortIf)
end

-- ---------------------------------------------------------------- boss logic
local skipUntil = {}     -- id -> os.clock() deadline after a failed trip
-- Deaths per boss for its CURRENT spawn. Cleared as soon as BossAlive_<id>
-- goes false (BossNext is 0 for every live spawn, so it can't key a spawn).
local MAX_DEATHS_PER_SPAWN = 3
local diedCount = {}
local function noteDeath(id) diedCount[id] = (diedCount[id] or 0) + 1 end
local function deathBlocked(id)
	local n = diedCount[id] or 0
	if n == 0 then return false end
	return not e.hbRetryBoss or n >= MAX_DEATHS_PER_SPAWN
end

local function eligible(b, myLv)
	return e.hbBosses[b.label]
		and (skipUntil[b.id] or 0) < os.clock()
		and not deathBlocked(b.id)
		and myLv >= b.level -- ticked but under-levelled: wait until we reach it
end

local function wantedBoss()
	local _, _, hrp = myChar()
	if not hrp then return nil end
	local myLv = plr:GetAttribute("Level") or 1
	local best, bestD
	for _, b in ipairs(BOSSES) do
		if bossAlive(b.id) and eligible(b, myLv) then
			local z = (navMap().Zones or {})[b.arena]
			if z and select(3, planRoute(hrp.Position, z.X, z.Z)) < math.huge then
				local d = math.abs(z.Z - hrp.Position.Z)
				if not bestD or d < bestD then best, bestD = b, d end
			end
		end
	end
	return best
end

-- Leave early so we're standing in the arena when the boss pops:
-- go once (spawn time - now) <= estimated travel time + PREARRIVE_LEAD_S.
local PREARRIVE_LEAD_S = 8
local function secondsToSpawn(id)
	local nxt = bossNext(id)
	if nxt <= 0 then return nil end
	return nxt - workspace:GetServerTimeNow()
end

local function upcomingBoss()
	if not e.hbPreArrive then return nil end
	local _, _, hrp = myChar()
	if not hrp then return nil end
	local myLv = plr:GetAttribute("Level") or 1
	local best, bestLeft
	for _, b in ipairs(BOSSES) do
		local left = not bossAlive(b.id) and secondsToSpawn(b.id)
		if left and left > -5 and eligible(b, myLv) then
			local z = (navMap().Zones or {})[b.arena]
			if z and left <= travelSeconds(z.X, z.Z) + PREARRIVE_LEAD_S then
				if not bestLeft or left < bestLeft then best, bestLeft = b, left end
			end
		end
	end
	return best
end

-- Alive, or due within the next couple of minutes (we may be travelling ahead of the spawn).
local function bossWorthGoing(id)
	if bossAlive(id) then return true end
	local left = secondsToSpawn(id)
	return left ~= nil and left > -15 and left < 180
end

local function stopRequested() return not alive() or not e.hbEnabled end

-- ----------------------------------------------------------- server hopping
-- When none of the SELECTED bosses are alive here and the soonest one is further
-- off than hbHopWait, jump to another public server of this place to find one
-- that's up (or spawning soon). cp_boot's queue_on_teleport re-runs this whole
-- script on arrival, so a hop just continues on the new server.
local TeleportService = game:GetService("TeleportService")
-- Bosses here spawn every ~1-2 min PER SERVER (ClockRespawn 600s each, several
-- bosses), so the reliable play is to STAY and ride the spawns, not chain-hop.
-- Only hop when the soonest selected boss is genuinely far (> hbHopWait). After a
-- teleport, wait DWELL for NavMap/boss attributes to load so we don't hop away
-- from a live boss we just haven't detected yet.
local HOP_MIN_DWELL = 20
local lastHopAt = 0

-- A selected, level-appropriate boss (ignores skipUntil/deathBlocked on purpose:
-- a fresh server resets those, so a boss we're stuck on here is a reason to hop).
local function hopEligible(b, myLv)
	return e.hbBosses[b.label] == true and myLv >= b.level
end

-- 0 if any selected boss is alive; else the soonest selected spawn; huge if none.
local function soonestSelectedSpawn()
	local myLv = plr:GetAttribute("Level") or 1
	local best
	for _, b in ipairs(BOSSES) do
		if hopEligible(b, myLv) then
			if bossAlive(b.id) then return 0 end
			local left = secondsToSpawn(b.id)
			if left and (not best or left < best) then best = left end
		end
	end
	return best or math.huge
end

local function shouldHop()
	if not e.hbHop then return false end
	if os.clock() - sessionStart < HOP_MIN_DWELL then return false end
	if os.clock() - lastHopAt < 15 then return false end -- don't spam teleport attempts
	if wantedBoss() then return false end              -- a selected boss is alive: fight it
	local wait = tonumber(e.hbHopWait) or 90
	if wait <= 0 then return true end                  -- 0 = hop the instant none is alive
	if upcomingBoss() then return false end            -- one spawns soon enough to pre-arrive
	return soonestSelectedSpawn() > wait
end

-- A failed TeleportToPlaceInstance (full/stale instance) drops you with Error 256
-- instead of moving. So: pick servers with the MOST free space, and if the
-- teleport init fails, fall back to plain matchmaking Teleport (Roblox picks a
-- good server). Guarded so the handler is only wired once across live-reloads.
if not getgenv().__HTBOSS_TPFAIL then
	getgenv().__HTBOSS_TPFAIL = true
	pcall(function()
		TeleportService.TeleportInitFailed:Connect(function(_, _, _)
			task.wait(1)
			pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
		end)
	end)
end

-- Auto Reconnect (ported from the proven 3-trigger version: PlayerRemoving alone
-- misses silent drops where the transport dies but LocalPlayer never leaves and
-- the native "Disconnected" dialog just sits there). Debounced 5s so the triggers
-- firing for the SAME drop don't double-Teleport. Hooked once across reloads.
if not getgenv().__HTBOSS_RECON then
	getgenv().__HTBOSS_RECON = true
	local firedAt = 0
	local function tryReconnect()
		if not e.hbReconnect then return end
		if os.clock() - firedAt < 5 then return end
		firedAt = os.clock()
		pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
	end
	getgenv().__HTBOSS_RECONFN = tryReconnect
	pcall(function() Players.PlayerRemoving:Connect(function(p) if p == plr then tryReconnect() end end) end)
	pcall(function() plr.AncestryChanged:Connect(function(_, parent) if parent ~= Players then tryReconnect() end end) end)
	pcall(function() game:GetService("GuiService").ErrorMessageChanged:Connect(tryReconnect) end)
	task.spawn(function()
		local CoreGui = game:GetService("CoreGui")
		while true do
			task.wait(5)
			if e.hbReconnect then
				pcall(function()
					for _, inst in ipairs(CoreGui:GetDescendants()) do
						if inst:IsA("TextLabel") and inst.Text == "Disconnected" then tryReconnect(); break end
					end
				end)
			end
		end
	end)
end

-- Recently-visited servers, persisted to a file so the list survives the
-- teleport (cp_boot re-runs this script fresh, losing in-memory state). Each
-- server we leave is remembered for RECENT_TTL, so we don't bounce straight back
-- into one we just cleared.
local RECENT_FILE = "HTBoss/recent_servers.json"
local RECENT_TTL = 900   -- 15 min
local RECENT_MAX = 40
local function loadRecent()
	local ok, t = pcall(function() return HS:JSONDecode(readfile(RECENT_FILE)) end)
	if not (ok and type(t) == "table") then return {} end
	local now, out = os.time(), {}
	for id, ts in pairs(t) do
		if type(id) == "string" and type(ts) == "number" and now - ts < RECENT_TTL then out[id] = ts end
	end
	return out
end
local function rememberServer(id)
	if type(id) ~= "string" or id == "" then return end
	local r = loadRecent()
	r[id] = os.time()
	-- cap size: drop the oldest if over RECENT_MAX
	local keys = {}
	for k in pairs(r) do keys[#keys + 1] = k end
	if #keys > RECENT_MAX then
		table.sort(keys, function(a, b) return r[a] < r[b] end)
		for i = 1, #keys - RECENT_MAX do r[keys[i]] = nil end
	end
	pcall(function() writefile(RECENT_FILE, HS:JSONEncode(r)) end)
end

local function serverHop()
	lastHopAt = os.clock()
	setState("Server hopping", "หาเซิร์ฟใหม่...")
	setAuto(false)
	rememberServer(game.JobId) -- don't come back to the one we're leaving
	local recent = loadRecent()
	local place = game.PlaceId
	local list, cursor = {}, ""
	for _ = 1, 5 do
		local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(place)
			.. (cursor ~= "" and ("&cursor=" .. cursor) or "")
		local ok, res = pcall(function() return game:HttpGet(url) end)
		if not ok then break end
		local ok2, data = pcall(function() return HS:JSONDecode(res) end)
		if not (ok2 and type(data) == "table" and type(data.data) == "table") then break end
		for _, s in ipairs(data.data) do
			local playing, cap = tonumber(s.playing) or 0, tonumber(s.maxPlayers) or 0
			if s.id and s.id ~= game.JobId and not recent[s.id] and playing < cap - 1 then
				table.insert(list, {id = s.id, free = cap - playing})
			end
		end
		cursor = data.nextPageCursor
		if not cursor or #list >= 60 then break end
	end
	if #list == 0 then
		pcall(function() TeleportService:Teleport(place, plr) end) -- matchmaking fallback
	else
		-- emptiest servers first, pick randomly among the roomiest few
		table.sort(list, function(a, b) return a.free > b.free end)
		local top = math.min(#list, 8)
		local pick = list[math.random(1, top)].id
		local ok = pcall(function() TeleportService:TeleportToPlaceInstance(place, pick, plr) end)
		if not ok then pcall(function() TeleportService:Teleport(place, plr) end) end
	end
	task.wait(12) -- let the teleport take; TeleportInitFailed retries if it doesn't
end

-- Boss loot: Part children of workspace.Drops tagged "Drop" (OwnerUserId,
-- FreeAt, ItemId attrs) are picked up by standing within ~2.5 studs and firing
-- PickupDrop(true); relic boxes are parts tagged "LootBox" opened from within
-- ~7 studs with OpenLootBox(part). Same reach/remotes as CombatClient's own
-- auto-loot. Honours the game's bot settings (BotJson Loot/OpenBoxes/LootSkip).
local CS = game:GetService("CollectionService")
local LOOT_RADIUS = 90
local LOOT_TIMEOUT_S = 45

local function botSettings()
	local ok, d = pcall(HS.JSONDecode, HS, plr:GetAttribute("BotJson") or "{}")
	return ok and type(d) == "table" and d or {}
end

local function canTake(part, now)
	local owner = tonumber(part:GetAttribute("OwnerUserId")) or 0
	if owner == 0 or owner == plr.UserId then return true end
	return (tonumber(part:GetAttribute("FreeAt")) or math.huge) <= now
end

local function lootTargets(center, tried)
	local bs = botSettings()
	local skip = {}
	if type(bs.LootSkip) == "table" then
		for k, v in pairs(bs.LootSkip) do
			if v == true then skip[k] = true elseif type(v) == "string" then skip[v] = true end
		end
	end
	local now = workspace:GetServerTimeNow()
	local out = {}
	if bs.Loot ~= false then
		for _, p in ipairs(CS:GetTagged("Drop")) do
			if p:IsA("BasePart") and p.Parent and not tried[p] and canTake(p, now)
				and not skip[tostring(p:GetAttribute("ItemId"))]
				and flatDist(p.Position, Vector2.new(center.X, center.Z)) <= LOOT_RADIUS then
				table.insert(out, {part = p, box = false})
			end
		end
	end
	if bs.OpenBoxes ~= false then
		for _, p in ipairs(CS:GetTagged("LootBox")) do
			if p:IsA("BasePart") and p.Parent and not tried[p] and canTake(p, now)
				and flatDist(p.Position, Vector2.new(center.X, center.Z)) <= LOOT_RADIUS then
				table.insert(out, {part = p, box = true})
			end
		end
	end
	return out
end

local function collectLoot(center)
	setAuto(false)
	clearTarget()
	task.wait(1.5) -- drops burst out of the corpse a moment after death
	local tried = {}
	local t0 = os.clock()
	local got = 0
	while os.clock() - t0 < LOOT_TIMEOUT_S and not stopRequested() do
		local _, hum, hrp = myChar()
		if not hum then return end
		local list = lootTargets(center, tried)
		if #list == 0 then break end
		table.sort(list, function(a, b2)
			return (a.part.Position - hrp.Position).Magnitude < (b2.part.Position - hrp.Position).Magnitude
		end)
		local item = list[1]
		local reach = item.box and 6 or 2.2
		setState("Collecting loot", ("%s (%d left)"):format(tostring(item.part:GetAttribute("Label") or item.part.Name), #list))

		local walkStart, lastPos, movedAt = os.clock(), hrp.Position, os.clock()
		while item.part.Parent and flatDist(hrp.Position, Vector2.new(item.part.Position.X, item.part.Position.Z)) > reach do
			if stopRequested() or hum.Health <= 0 or os.clock() - walkStart > 10 then break end
			hum:MoveTo(Vector3.new(item.part.Position.X, hrp.Position.Y, item.part.Position.Z))
			task.wait(0.2)
			if (hrp.Position - lastPos).Magnitude > 1 then
				lastPos, movedAt = hrp.Position, os.clock()
			elseif os.clock() - movedAt > 1.2 then
				hum.Jump = true
				movedAt = os.clock()
			end
		end
		hum:MoveTo(hrp.Position)

		local fireStart = os.clock()
		while item.part.Parent and os.clock() - fireStart < 3 and not stopRequested() do
			if item.box then
				remotes.OpenLootBox:FireServer(item.part)
			else
				remotes.PickupDrop:FireServer(true)
			end
			task.wait(0.6)
		end
		if item.part.Parent then
			tried[item.part] = true -- bag full / not ours yet: don't loop on it
		else
			got += 1
		end
	end
	stats.looted += got
end

-- Boss "stand in the green circle or die" skill. Server fires
-- Remotes.BossFx(kind, bossKey, skillKey, zones, duration):
--   "warn"   -> zones about to land; a zone with Safe=true is the green circle
--               (always Kind "circle": Center Vector3 + Radius).
--   "hit"    -> the skill resolved.
--   "cancel" -> the skill was interrupted (enough damage dealt in time).
-- The game's own Auto never walks into these, so the fight loop below drops
-- Auto + target, walks into the nearest green circle, holds until hit/cancel,
-- then re-engages.
local safePending = nil
local fxConn = remotes.BossFx.OnClientEvent:Connect(function(kind, a2, a3, zones, dur)
	local key = tostring(a2) .. "|" .. tostring(a3)
	if kind == "warn" then
		if type(zones) ~= "table" then return end
		local circles = {}
		for _, z in pairs(zones) do
			if type(z) == "table" and z.Safe and typeof(z.Center) == "Vector3" and tonumber(z.Radius) then
				table.insert(circles, {center = z.Center, radius = tonumber(z.Radius)})
			end
		end
		if #circles > 0 then
			safePending = {key = key, circles = circles, untilT = os.clock() + (tonumber(dur) or 4) + 0.6}
		end
	elseif kind == "hit" or kind == "cancel" then
		if safePending and safePending.key == key then safePending = nil end
	end
end)

-- Red (damage) zones, dodged only for bosses listed here. BossFx a2 is the
-- boss's display name (captured live: "Obsidian Pharaoh", "Ice Golem King").
-- Zone shapes (from BossClient): circle {Center, Radius}, rect {CFrame, Width,
-- Length}, cone {Center, Dir, Radius, Half}. _tiles is only HOW the game draws
-- a zone (tileZone) -- it still hurts, so it is dodged like any other. Room
-- zones are the whole arena (paired with a green Safe circle) and skipped here.
-- Several skills can be pending at once, so every live warning is kept and the
-- escape spot has to be outside all of them. Warn lead time is short (0.9-1.5 s).
local DODGE_BOSSES = {["Volcano Turtle King"] = true}
local DODGE_MARGIN = 3
local dangers = {}  -- live warnings {key, zones, untilT, hitAt, skill}
local dangerVer = 0 -- bumps on every warn / hit, so a dodge in progress replans
local hazards = {}  -- lingering lava pools {Center, Radius, untilT}
-- Flame Breath (captured live): cone R118, half-angle 0.35 rad from the boss,
-- first warn 1.3 s, then ~4 more 0.35 s pulses each re-aimed at the player,
-- ~3200 damage a pulse. At 50 studs you can't get 20 studs sideways in 0.35 s.
local BREATH_SKILLS = {["Flame Breath"] = true}
local breath = nil  -- {key, zone, untilT, skill}
local lastHitAt = {}
local function dropDanger(key)
	for i = #dangers, 1, -1 do
		if dangers[i].key == key then table.remove(dangers, i) end
	end
end
local dangerConn = remotes.BossFx.OnClientEvent:Connect(function(kind, a2, a3, zones, dur)
	local key = tostring(a2) .. "|" .. tostring(a3)
	if kind == "warn" then
		if not DODGE_BOSSES[tostring(a2)] or type(zones) ~= "table" then return end
		local d0 = tonumber(dur) or 1.5
		-- A cone that warns again right after it hits is a channelled breath that
		-- re-aims at you each pulse: handled by dodgeBreath (circle the boss),
		-- not by running out of the current cone.
		local recur = lastHitAt[key] and os.clock() - lastHitAt[key] < 1
		-- A warning that carries a green Safe circle is "stand INSIDE the green":
		-- its red part (Earthquake Stomp phase 2: R118 ring round a Safe R72) is
		-- the area outside the green, so it is left to dodgeIntoSafe. Running out
		-- of the red circle here was running straight out of the green one.
		for _, z in pairs(zones) do
			if type(z) == "table" and z.Safe then return end
		end
		local list = {}
		for _, z in pairs(zones) do
			if type(z) == "table" and not z.Safe and not z.Room then
				if z.Kind == "cone" and typeof(z.Center) == "Vector3" and typeof(z.Dir) == "Vector3"
					and (BREATH_SKILLS[tostring(a3)] or recur) then
					BREATH_SKILLS[tostring(a3)] = true
					breath = {key = key, zone = z, untilT = os.clock() + d0 + 0.9, skill = tostring(a3)}
				else
					table.insert(list, z)
				end
			end
		end
		if #list > 0 then
			dropDanger(key)
			local d = tonumber(dur) or 1.5
			table.insert(dangers, {key = key, zones = list, hitAt = os.clock() + d, untilT = os.clock() + d + 0.4, skill = tostring(a3)})
			dangerVer += 1
		end
	elseif kind == "hit" or kind == "cancel" then
		dropDanger(key)
		dangerVer += 1
		lastHitAt[key] = os.clock()
		if breath and breath.key == key then
			-- next pulse (if any) warns within a frame or two of this hit
			breath.untilT = kind == "cancel" and 0 or os.clock() + 0.6
		end
		-- Fire floor: a circle zone with PoolTime > 0 keeps burning that long after
		-- it lands (BossSkillFx draws the lava pool from the same Center/Radius).
		if kind == "hit" and DODGE_BOSSES[tostring(a2)] and type(zones) == "table" then
			for _, z in pairs(zones) do
				local t = type(z) == "table" and tonumber(z.PoolTime)
				if t and t > 0 and typeof(z.Center) == "Vector3" and tonumber(z.Radius) then
					table.insert(hazards, {Center = z.Center, Radius = tonumber(z.Radius), untilT = os.clock() + t})
				end
			end
		end
	end
end)
task.spawn(function()
	while alive() do task.wait(1) end
	dangerConn:Disconnect()
end)

local function activeHazards()
	local now, live = os.clock(), {}
	for _, h in ipairs(hazards) do if h.untilT > now then table.insert(live, h) end end
	hazards = live
	return live
end

local function liveDangers()
	local now, live = os.clock(), {}
	for _, d in ipairs(dangers) do if d.untilT > now then table.insert(live, d) end end
	dangers = live
	return live
end

-- Boss leash: GameConfig.BossLeash = 90 studs from where the boss spawned; drag
-- it further and it walks home with full HP. The boss trails us, so dodges and
-- the fight itself stay inside LEASH_KEEP of home.
local BOSS_LEASH = tonumber(require(RS.Shared:WaitForChild("GameConfig")).BossLeash) or 90
local LEASH_KEEP = BOSS_LEASH - 30

local function arenaCenter(bossId)
	local b = BY_ID[bossId]
	local z = b and (navMap().Zones or {})[b.arena]
	return z and Vector2.new(z.X, z.Z) or nil
end

-- Where the boss counts its leash from: where we first saw it (it is fresh out
-- of the spawn then), unless that is far off the arena centre (someone already
-- dragged it), then the arena centre.
local homes = setmetatable({}, {__mode = "k"})
local function bossHome(model)
	if not model then return nil end
	if homes[model] then return homes[model] end
	local center = arenaCenter(model:GetAttribute("MonsterId"))
	local pp = model.PrimaryPart
	local home = center
	if pp and (not center or flatDist(pp.Position, center) < 40) then home = Vector2.new(pp.Position.X, pp.Position.Z) end
	homes[model] = home
	return home
end

local function inZone(z, pos, m)
	if z.Kind == "cone" and typeof(z.Center) == "Vector3" and typeof(z.Dir) == "Vector3" then
		local v = Vector3.new(pos.X - z.Center.X, 0, pos.Z - z.Center.Z)
		local d = v.Magnitude
		if d > (tonumber(z.Radius) or 0) + m then return false end
		if d < 2 then return true end
		local dir = Vector3.new(z.Dir.X, 0, z.Dir.Z)
		if dir.Magnitude < 1e-3 then return true end
		local ang = math.acos(math.clamp(v.Unit:Dot(dir.Unit), -1, 1))
		return ang <= (tonumber(z.Half) or 0) + m / d
	elseif typeof(z.CFrame) == "CFrame" and tonumber(z.Width) and tonumber(z.Length) then
		local lp = z.CFrame:PointToObjectSpace(Vector3.new(pos.X, z.CFrame.Position.Y, pos.Z))
		return math.abs(lp.X) <= z.Width / 2 + m and math.abs(lp.Z) <= z.Length / 2 + m
	elseif typeof(z.Center) == "Vector3" and tonumber(z.Radius) then
		return flatDist(pos, Vector2.new(z.Center.X, z.Center.Z)) <= z.Radius + m
	end
	return false
end

local function inAnyZone(zones, pos, m)
	for _, z in ipairs(zones) do if inZone(z, pos, m) then return true end end
	return false
end

local DASH_DIST, DASH_COST, DASH_CD = 16, 25, 2.1
local lastDash = 0

-- Best standable point outside every zone. Candidates on rings around us; each
-- needs ground underneath (don't run off the island) and must stay inside the
-- leash (or at least get closer to home). Score = distance to run, plus a pull
-- toward the boss (less walking back to hit it = no wandering) and home.
-- Spots we can't reach before the hit lands (walk speed + one dash) lose to any
-- spot we can.
local function escapePoint(zones, hrp, home, bossModel, deadline)
	local origin = hrp.Position
	local hum = hrp.Parent and hrp.Parent:FindFirstChildOfClass("Humanoid")
	local reach = math.huge
	if deadline then
		local canDash = e.hbDash and os.clock() - lastDash >= DASH_CD and (tonumber(plr:GetAttribute("LumiStamina")) or 100) >= DASH_COST
		reach = math.max(deadline - os.clock(), 0) * (hum and hum.WalkSpeed or 16) + (canDash and DASH_DIST * 0.8 or 0) + 1
	end
	local bpp = bossModel and bossModel.Parent and bossModel.PrimaryPart
	local bossXZ = bpp and Vector2.new(bpp.Position.X, bpp.Position.Z)
	local homeNow = home and flatDist(origin, home)
	rayParams.FilterDescendantsInstances = {workspace:FindFirstChild("Monsters"), workspace:FindFirstChild("Drops"), plr.Character}
	local best, bestScore
	for _, r in ipairs({5, 8, 11, 14, 18, 23, 29, 36, 44, 53}) do
		for i = 0, 23 do
			local a = i / 24 * math.pi * 2
			local p = origin + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
			local hd = home and flatDist(p, home)
			-- A dodge is over in a second or two and the boss barely moves in that
			-- time, so a spot may go out to the leash itself (Earthquake Stomp is a
			-- 72-stud circle round the boss); spots past LEASH_KEEP just score worse.
			if (not hd or hd <= BOSS_LEASH or hd < homeNow) and not inAnyZone(zones, p, DODGE_MARGIN + 1) then
				local score = r
					+ (bossXZ and flatDist(p, bossXZ) * 0.15 or 0)
					+ (hd and math.max(hd - LEASH_KEEP, 0) * 0.5 or 0)
				if r > reach then score += 1000 end
				if not bestScore or score < bestScore then
					local hit = workspace:Raycast(p + Vector3.new(0, 8, 0), Vector3.new(0, -30, 0), rayParams)
					if hit then best, bestScore = Vector3.new(p.X, hit.Position.Y + 3, p.Z), score end
				end
			end
		end
	end
	return best
end

-- Dash (Q): Remotes.Dash:FireServer(); the server answers and the client pushes
-- DashDistance (16) studs over DashTime (0.3 s) along Humanoid.MoveDirection.
-- Costs 25 of 100 stamina (LumiStamina), 2 s cooldown. Only dash when the
-- landing spot itself is safe ground, so we never dash into lava or off the island.
local function tryDash(hum, hrp, spot, zones)
	if not e.hbDash or os.clock() - lastDash < DASH_CD then return end
	if (tonumber(plr:GetAttribute("LumiStamina")) or 100) < DASH_COST then return end
	local dir = Vector3.new(spot.X - hrp.Position.X, 0, spot.Z - hrp.Position.Z)
	if dir.Magnitude < 9 then return end
	local land = hrp.Position + dir.Unit * DASH_DIST
	if inAnyZone(zones, land, 1) then return end
	rayParams.FilterDescendantsInstances = {workspace:FindFirstChild("Monsters"), workspace:FindFirstChild("Drops"), plr.Character}
	if not workspace:Raycast(land + Vector3.new(0, 8, 0), Vector3.new(0, -30, 0), rayParams) then return end
	hum:MoveTo(spot)
	task.wait() -- let MoveDirection point at the spot before the push direction is read
	lastDash = os.clock()
	remotes.Dash:FireServer()
end

local function concat(a, b)
	local out = table.clone(a)
	for _, v in ipairs(b) do table.insert(out, v) end
	return out
end

local function runTo(hum, hrp, spot, zones, keepGoing)
	tryDash(hum, hrp, spot, zones)
	while keepGoing() and alive() and hum.Health > 0 do
		if flatDist(hrp.Position, Vector2.new(spot.X, spot.Z)) > 1.5 then
			hum:MoveTo(spot)
			tryDash(hum, hrp, spot, zones)
		else
			hum:MoveTo(hrp.Position)
		end
		task.wait(0.05)
	end
end

local function allDangerZones(live)
	local out = {}
	for _, d in ipairs(live) do
		for _, z in ipairs(d.zones) do table.insert(out, z) end
	end
	return out
end

local function earliestHit(live)
	local t
	for _, d in ipairs(live) do if not t or d.hitAt < t then t = d.hitAt end end
	return t
end

-- Red warnings: run to a spot outside ALL live warnings (and lava), then stand
-- there until they have all landed. A new warning mid-run replans from where we
-- are instead of finishing the old run and handing back to Auto first (that
-- back-and-forth was the "walking around confused" look).
local function dodgeDanger(bossModel)
	if not e.hbDodge then return false end
	local _, hum, hrp = myChar()
	if not hum then return false end
	local live = liveDangers()
	if #live == 0 or not inAnyZone(allDangerZones(live), hrp.Position, DODGE_MARGIN) then return false end
	local home = bossHome(bossModel)
	local dodged = false
	while alive() and hum.Health > 0 do
		live = liveDangers()
		if #live == 0 then break end
		local zones = allDangerZones(live)
		local avoid = concat(zones, activeHazards())
		local spot = hrp.Position
		if inAnyZone(zones, hrp.Position, DODGE_MARGIN) then
			spot = escapePoint(avoid, hrp, home, bossModel, earliestHit(live))
			if not spot then break end
		end
		if not dodged then
			dodged = true
			setState("Dodging boss skill", live[#live].skill)
			setAuto(false)
			clearTarget()
		end
		local ver = dangerVer
		runTo(hum, hrp, spot, avoid, function() return dangerVer == ver and #liveDangers() > 0 end)
	end
	if dodged then stats.skillDodges += 1 end
	return dodged
end

-- Channelled breath: each pulse is aimed where we stand when it warns and lands
-- 0.35 s later, so the dodge is to keep moving sideways around the boss fast
-- enough that we are never where it aimed. Close in (ORBIT_R) the sideways
-- distance needed is small (15 * sin 0.35 + margin ~ 9 studs per pulse), far out
-- it isn't, so we spiral in while circling; always the same way round, and dash
-- whenever the current pulse is on us.
local ORBIT_R = 15
local function dodgeBreath(bossModel)
	local br = breath
	if not (br and e.hbDodge) then return false end
	if os.clock() > br.untilT then breath = nil; return false end
	local _, hum, hrp = myChar()
	if not hum then return false end
	setState("Dodging " .. br.skill, stats.detail)
	setAuto(false)
	clearTarget()
	local side
	while alive() and hum.Health > 0 do
		br = breath
		if not br or os.clock() > br.untilT then break end
		local z = br.zone
		local c = z.Center
		local pp = bossModel and bossModel.Parent and bossModel.PrimaryPart
		if pp then c = Vector3.new(pp.Position.X, c.Y, pp.Position.Z) end
		local v = Vector3.new(hrp.Position.X - c.X, 0, hrp.Position.Z - c.Z)
		local d = math.max(v.Magnitude, 0.5)
		local myAng = math.atan2(v.Z, v.X)
		if not side then
			local axis = math.atan2(z.Dir.Z, z.Dir.X)
			local diff = (myAng - axis + math.pi) % (2 * math.pi) - math.pi
			side = diff >= 0 and 1 or -1
		end
		local rT = math.max(ORBIT_R, d - 12)
		local a = myAng + side * math.clamp(14 / d, 0.5, 1.2)
		local target = Vector3.new(c.X + math.cos(a) * rT, hrp.Position.Y, c.Z + math.sin(a) * rT)
		hum:MoveTo(target)
		if inZone(z, hrp.Position, 2) then tryDash(hum, hrp, target, activeHazards()) end
		task.wait(0.05)
	end
	if breath == br then breath = nil end
	stats.skillDodges += 1
	return true
end

-- Standing in a lava pool: step out to the edge nearest the boss. If the boss
-- itself is parked in the pool, wait at the edge (max 5 s) instead of walking
-- straight back in.
local function dodgeHazard(bossModel)
	if not e.hbDodge then return false end
	local live = activeHazards()
	if #live == 0 then return false end
	local _, hum, hrp = myChar()
	if not hum or not inAnyZone(live, hrp.Position, 1.5) then return false end
	local avoid = concat(live, allDangerZones(liveDangers()))
	local spot = escapePoint(avoid, hrp, bossHome(bossModel), bossModel, nil)
	if not spot then return false end
	setState("Leaving fire floor", stats.detail)
	setAuto(false)
	clearTarget()
	local t0, ver = os.clock(), dangerVer
	runTo(hum, hrp, spot, avoid, function()
		if os.clock() - t0 > 5 or dangerVer ~= ver then return false end
		if flatDist(hrp.Position, Vector2.new(spot.X, spot.Z)) > 1.5 then return true end
		local pp = bossModel and bossModel.Parent and bossModel.PrimaryPart
		return pp ~= nil and inAnyZone(activeHazards(), pp.Position, 2)
	end)
	stats.skillDodges += 1
	return true
end

-- Too far from the boss's home: it is about to reset to full HP. Walk back
-- toward home (it follows us) before Auto keeps fighting.
local farSince = nil
local function leashGuard(bossModel)
	if not e.hbDodge then return false end
	local home = bossHome(bossModel)
	local _, hum, hrp = myChar()
	if not (home and hum) then return false end
	local pp = bossModel.PrimaryPart
	if flatDist(hrp.Position, home) <= LEASH_KEEP + 10 then farSince = nil end
	if not farSince and flatDist(hrp.Position, home) > LEASH_KEEP + 10 then farSince = os.clock() end
	local far = (farSince and os.clock() - farSince > 2.5)
		or (pp and flatDist(pp.Position, home) > BOSS_LEASH - 15)
	if not far or #liveDangers() > 0 then return false end
	farSince = nil
	setState("Pulling boss back (leash)", stats.detail)
	setAuto(false)
	clearTarget()
	local t0 = os.clock()
	while alive() and hum.Health > 0 and os.clock() - t0 < 6 and #liveDangers() == 0 do
		if flatDist(hrp.Position, home) < 30 then break end
		hum:MoveTo(Vector3.new(home.X, hrp.Position.Y, home.Y))
		task.wait(0.1)
	end
	return true
end
task.spawn(function()
	while alive() do task.wait(1) end
	fxConn:Disconnect()
end)

local function dodgeIntoSafe(maxOutside)
	local sp = safePending
	if not sp then return false end
	if os.clock() > sp.untilT then safePending = nil; return false end
	local _, hum, hrp = myChar()
	if not hum then return false end
	local best, bestD
	for _, c in ipairs(sp.circles) do
		local d = flatDist(hrp.Position, Vector2.new(c.center.X, c.center.Z))
		if not bestD or d < bestD then best, bestD = c, d end
	end
	-- manual fights: only a green circle near us (some other boss's skill
	-- across the map must not drag us off)
	if maxOutside and bestD > best.radius + maxOutside then return false end
	setState("Dodging into green circle", stats.detail)
	setAuto(false)
	clearTarget()
	local inner = math.max(best.radius * 0.45, 1.5)
	while safePending == sp and os.clock() < sp.untilT and alive() and hum.Health > 0 do
		if flatDist(hrp.Position, Vector2.new(best.center.X, best.center.Z)) > inner then
			hum:MoveTo(Vector3.new(best.center.X, hrp.Position.Y, best.center.Z))
		else
			hum:MoveTo(hrp.Position)
		end
		task.wait(0.1)
	end
	if safePending == sp then safePending = nil end
	stats.dodges += 1
	return true
end

-- Dodging also runs when YOU are fighting (no Auto Boss trip in progress):
-- remember Auto + target, dodge, then put both back.
local inFight = false
task.spawn(function()
	while alive() do
		if not inFight and e.hbDodge and (safePending or breath or #dangers > 0 or #hazards > 0) then
			local wasAuto, tgt = autoOn(), currentTarget.Value
			local boss = tgt and tgt:IsA("Model") and tgt:GetAttribute("IsBoss") and tgt or nil
			local ok, dodged = pcall(function() return dodgeIntoSafe(60) or dodgeBreath(boss) or dodgeDanger(boss) or dodgeHazard(boss) end)
			if ok and dodged then
				if wasAuto then setAuto(true) end
				if tgt and tgt.Parent then lockTarget:Fire(tgt) end
			end
		end
		task.wait(0.05)
	end
end)

local fightBossInner
local function fightBoss(b)
	inFight = true
	local ok, err = pcall(fightBossInner, b)
	inFight = false
	if not ok then warn("[HTBoss] fightBoss error: " .. tostring(err)) end
end

function fightBossInner(b)
	local z = (navMap().Zones or {})[b.arena]
	if not z then skipUntil[b.id] = os.clock() + 60; return end
	stats.lastBoss = b.name

	setAuto(false)
	clearTarget()
	setState("Walking to boss", b.name)
	local r = travelTo(z.X, z.Z, 25, function() return stopRequested() or not bossWorthGoing(b.id) end)
	if r == "dead" then noteDeath(b.id); return end
	if r == "stuck" then skipUntil[b.id] = os.clock() + 15; return end -- short: retry soon (new route), don't sit out the whole spawn
	if r == "abort" then return end

	-- Arrived ahead of the spawn: stand in the arena and wait for it.
	local waitStart = os.clock()
	while not bossAlive(b.id) and not stopRequested() do
		local left = secondsToSpawn(b.id)
		if (left and left < -20) or os.clock() - waitStart > 240 then
			skipUntil[b.id] = os.clock() + 30
			return
		end
		setState("Waiting for boss to spawn", ("%s อีก %d วิ"):format(b.name, math.max(0, math.floor(left or 0))))
		if not myChar() then noteDeath(b.id); return end
		task.wait(0.5)
	end
	if stopRequested() then return end

	setState("Looking for boss", b.name)
	local model
	local t0 = os.clock()
	while not model and os.clock() - t0 < 20 and bossAlive(b.id) and not stopRequested() do
		model = findBossModel(b.id)
		if not model then task.wait(0.5) end
	end
	if not model then
		if bossAlive(b.id) then skipUntil[b.id] = os.clock() + 60 end
		return
	end

	setState("Fighting boss", b.name)
	local home, center = bossHome(model), arenaCenter(b.id)
	if home and center then
		print(("[HTBoss] %s home %.0f,%.0f (arena centre %.0f,%.0f)"):format(b.name, home.X, home.Y, center.X, center.Y))
	end
	setAuto(true)
	lockTarget:Fire(model)
	local fightStart = os.clock()
	local lastBossPos = model.PrimaryPart.Position
	local killed = false
	while not stopRequested() do
		local _, hum = myChar()
		if not hum then noteDeath(b.id); return end
		if model.PrimaryPart then lastBossPos = model.PrimaryPart.Position end
		if not bossAlive(b.id) or not model.Parent or (tonumber(model:GetAttribute("HP")) or 0) <= 0 then
			stats.bossKills += 1
			killed = true
			break
		end
		if os.clock() - fightStart > 600 then skipUntil[b.id] = os.clock() + 300; break end
		if dodgeIntoSafe() or dodgeBreath(model) or dodgeDanger(model) or dodgeHazard(model) or leashGuard(model) then
			setState("Fighting boss", b.name)
			if bossAlive(b.id) and model.Parent then
				setAuto(true)
				lockTarget:Fire(model)
			end
		end
		if currentTarget.Value ~= model and model.Parent then lockTarget:Fire(model) end
		local hp, maxHp = tonumber(model:GetAttribute("HP")) or 0, tonumber(model:GetAttribute("MaxHP")) or 1
		stats.detail = ("%s  HP %d%%"):format(b.name, math.floor(hp / math.max(maxHp, 1) * 100))
		task.wait(0.1)
	end
	clearTarget()
	if killed then collectLoot(lastBossPos) end
end

-- Walk back ONCE after a boss trip / death / enabling, then hand control to
-- the game's Auto. Never police the position afterwards: Auto chases monsters
-- well past any small radius, and pulling it back each time just left the
-- character parked at the spot with Auto switched off.
local needReturn = true

local function returnToFarm()
	if not needReturn then return end
	local fp = e.hbFarmPos
	if type(fp) ~= "table" or not fp.x then needReturn = false; return end
	local _, _, hrp = myChar()
	if not hrp then return end
	if flatDist(hrp.Position, Vector2.new(fp.x, fp.z)) > 6 then
		setAuto(false)
		clearTarget()
		setState("Walking back to farm spot")
		local r = travelTo(fp.x, fp.z, 6, function()
			-- Auto switched on mid-walk (F key / game button) = the player took over.
			return stopRequested() or wantedBoss() ~= nil or upcomingBoss() ~= nil or autoOn()
		end)
		if r == "dead" then return end
		if r == "abort" and not autoOn() then return end
	end
	needReturn = false
	if e.hbAutoAtFarm and not autoOn() then
		setAuto(true)
		if not autoOn() then
			task.wait(1)
			setAuto(true)
		end
	end
end

-- ---------------------------------------------------------------- auto sell
-- Mirrors InventoryClient.junkScan() (the game's "Sell Junk" panel) and sends
-- the same Remotes.BagSell(list) the panel's "Sell Now" button sends:
--   gear (GearJson refs, Kind weapon/armor) bucketed by GearUtil.Resolve().Rarity
--   0..4 = Tier I..V (Tier VI never sold); monster materials = ItemsJson ids with
--   ItemData Kind "etc", Sell > 0, not GameConfig.JunkKeep.
-- Never sold (game rules + stricter extras): anything in LocksJson, equipped
-- (EquipJson / WeaponId), worn by another job (OtherWornJson), in any saved
-- loadout (LoadoutJson), or refined (RefineJson > 0).
-- Verified live: the dry-run scan matched the in-game panel count for count.
-- Selling from the bag outside a shop needs Premium (the panel checks the same).
local GearUtil = require(RS.Shared:WaitForChild("GearUtil"))
local ItemData = require(RS.Shared:WaitForChild("ItemData"))
local GameConfig = require(RS.Shared:WaitForChild("GameConfig"))

local SELL_JUNK = "ขยะมอน (วัตถุดิบ)"
local SELL_TIERS = {[0] = "อุปกรณ์ขั้น I", "อุปกรณ์ขั้น II", "อุปกรณ์ขั้น III", "อุปกรณ์ขั้น IV", "อุปกรณ์ขั้น V"}
local SELL_EVERY_S = 30
local sellStats = {sold = 0, gold = 0, last = "-"}

if e.hbSellOn == nil then e.hbSellOn = false end
if type(e.hbSellPick) ~= "table" then
	e.hbSellPick = {[SELL_JUNK] = true, [SELL_TIERS[0]] = true, [SELL_TIERS[1]] = true}
end

local function pjson(name)
	local ok, t = pcall(HS.JSONDecode, HS, plr:GetAttribute(name) or "{}")
	return ok and type(t) == "table" and t or {}
end

local function collectRefs(t, out)
	for _, v in pairs(t) do
		if type(v) == "string" and v:match("^g%d+$") then out[v] = true
		elseif type(v) == "table" then collectRefs(v, out) end
	end
end

local function sellScan()
	local gear, locks, refine, items = pjson("GearJson"), pjson("LocksJson"), pjson("RefineJson"), pjson("ItemsJson")
	local keep = {}
	for _, ref in pairs(pjson("EquipJson")) do keep[ref] = true end
	for ref in pairs(pjson("OtherWornJson")) do keep[ref] = true end
	collectRefs(pjson("LoadoutJson"), keep)
	local weapon = plr:GetAttribute("WeaponId")
	if weapon then keep[weapon] = true end

	local list, gold = {}, 0
	for ref in pairs(gear) do
		local ok, d = pcall(GearUtil.Resolve, ref, gear)
		if ok and d and (d.Kind == "weapon" or d.Kind == "armor")
			and not locks[ref] and not keep[ref] and (tonumber(refine[ref]) or 0) <= 0 then
			local label = SELL_TIERS[math.floor(d.Rarity or 0)]
			if label and e.hbSellPick[label] then
				table.insert(list, ref)
				gold += tonumber(d.Sell) or 0
			end
		end
	end
	if e.hbSellPick[SELL_JUNK] then
		local junkKeep = GameConfig.JunkKeep or {}
		for id, n in pairs(items) do
			local d = ItemData[id]
			if d and tonumber(n) and n > 0 and d.Kind == "etc" and (tonumber(d.Sell) or 0) > 0
				and not junkKeep[id] and not locks[id] then
				table.insert(list, id)
				gold += (tonumber(d.Sell) or 0) * n
			end
		end
	end
	return list, gold
end

local function sellNow()
	if plr:GetAttribute("Premium") ~= true then
		sellStats.last = "ขายจากกระเป๋าได้เฉพาะ Premium"
		return
	end
	local list, gold = sellScan()
	if #list == 0 then
		sellStats.last = "ไม่มีของให้ขาย"
		return
	end
	remotes.BagSell:FireServer(list)
	sellStats.sold += #list
	sellStats.gold += gold
	sellStats.last = ("ขาย %d รายการ ~%d Gold (%s)"):format(#list, gold, os.date("%H:%M:%S"))
end

task.spawn(function()
	while alive() do
		if e.hbSellOn then pcall(sellNow) end
		task.wait(SELL_EVERY_S)
	end
end)

-- ---------------------------------------------------------------- weapon imbue
-- Items weapon_coat_<fire|water|wind|earth> (Kind usable, 30 min, same element
-- stacks up to 3 h, another element replaces it). Used with
-- Remotes.UseItem:FireServer(itemId) -- same call the bag's Use button makes.
-- Active coat shows in LocalPlayer attr BuffsJson as {Id="coat_w_<element>", EndsAt=<server time>}.
-- One scroll per refill: only when the coat is missing or has <= 60 s left,
-- then wait for EndsAt to move before even considering another.
local COAT_FOLLOW = "ธาตุที่ใช้อยู่ตอนนี้ (ต่ออายุ)"
local COAT_CHOICES = {
	{label = "ไฟ (Fire)", el = "fire"}, {label = "น้ำ (Water)", el = "water"},
	{label = "ลม (Wind)", el = "wind"}, {label = "ดิน (Earth)", el = "earth"},
}
local COAT_REFILL_AT_S = 60
local coatStats = {used = 0, last = "-"}
if e.hbCoatOn == nil then e.hbCoatOn = false end
if type(e.hbCoatPick) ~= "string" then e.hbCoatPick = COAT_FOLLOW end

local function activeCoat()
	local now = workspace:GetServerTimeNow()
	for _, b in ipairs(pjson("BuffsJson")) do
		local el = type(b) == "table" and type(b.Id) == "string" and b.Id:match("^coat_w_(%a+)$")
		if el and (tonumber(b.EndsAt) or 0) > now then return el, b.EndsAt - now end
	end
	return nil, 0
end

local function wantedCoat(current)
	if e.hbCoatPick == COAT_FOLLOW then return current end
	for _, c in ipairs(COAT_CHOICES) do if c.label == e.hbCoatPick then return c.el end end
	return nil
end

local lastCoatUse = 0
local function coatTick()
	local cur, left = activeCoat()
	local el = wantedCoat(cur)
	if not el then coatStats.last = "ยังไม่มีธาตุที่ใช้อยู่ให้ต่ออายุ"; return end
	if cur == el and left > COAT_REFILL_AT_S then
		coatStats.last = ("%s เหลือ %d:%02d"):format(el, math.floor(left / 60), math.floor(left % 60))
		return
	end
	if os.clock() - lastCoatUse < 15 then return end -- wait out replication before another scroll
	local item = "weapon_coat_" .. el
	local have = tonumber(pjson("ItemsJson")[item]) or 0
	if have <= 0 then coatStats.last = "ใบธาตุ " .. el .. " หมดแล้ว"; return end
	lastCoatUse = os.clock()
	remotes.UseItem:FireServer(item)
	coatStats.used += 1
	coatStats.last = ("ใช้ %s 1 ใบ (เหลือ %d) %s"):format(item, have - 1, os.date("%H:%M:%S"))
end

task.spawn(function()
	while alive() do
		if e.hbCoatOn then pcall(coatTick) end
		task.wait(5)
	end
end)

-- ---------------------------------------------------------------- death
-- RespawnClient's "You Died" window: RespawnChoice "town" (free, full HP),
-- "here" (Gold), "robux". Left alone it only auto-picks town after minutes.
-- Pick town straight away; the main loop then warps/walks to a live boss or
-- back to the farm spot from the village.
local lastRespawnAsk = 0
local function handleDeath()
	needReturn = true
	setState("Dead — respawning in town")
	if e.hbAutoRespawn and os.clock() - lastRespawnAsk > 3 then
		lastRespawnAsk = os.clock()
		pcall(function() remotes.RespawnChoice:FireServer("town") end)
	end
end

-- ---------------------------------------------------------------- main loop
task.spawn(function()
	while alive() do
		for _, b in ipairs(BOSSES) do
			if not bossAlive(b.id) then diedCount[b.id] = nil end
		end
		if not e.hbEnabled then
			setState("Idle (Auto Boss off)")
			task.wait(1)
		elseif not myChar() then
			handleDeath()
			task.wait(1)
		else
			local b = wantedBoss()
			-- hbHopWait==0 means "only fight bosses that are alive NOW, else hop" --
			-- so in that mode we DON'T pre-arrive to a soon-spawning boss (that was
			-- why it walked to an arena instead of hopping).
			local immediate = e.hbHop and (tonumber(e.hbHopWait) or 90) <= 0
			local up = (not b and not immediate and not shouldHop()) and upcomingBoss() or nil
			if b then
				fightBoss(b)
				needReturn = true
			elseif up then
				fightBoss(up) -- none alive, but one spawns soon: pre-arrive
				needReturn = true
			elseif shouldHop() then
				-- linger hbHopDelay sec first; a boss showing up cancels the hop
				local delay = tonumber(e.hbHopDelay) or 0
				local t0 = os.clock()
				while os.clock() - t0 < delay and not stopRequested() do
					if wantedBoss() or upcomingBoss() then break end
					setState("Server hopping", ("หน่วง %ds"):format(math.max(0, math.ceil(delay - (os.clock() - t0)))))
					task.wait(1)
				end
				if not (wantedBoss() or upcomingBoss()) and shouldHop() then
					serverHop() -- no selected boss here/soon: jump to another server
				end
			else
				returnToFarm()
				if not (wantedBoss() or upcomingBoss()) then
					if e.hbHop then
						local s = soonestSelectedSpawn()
						setState("Farming", s < math.huge and ("รอบอส/ข้ามเซิร์ฟใน " .. math.max(0, math.floor(s)) .. " วิ") or "waiting for a boss")
					else
						setState("Farming", "waiting for a boss")
					end
				end
				task.wait(1)
			end
		end
	end
end)

-- ---------------------------------------------------------------------- UI
print("[HTBoss] Loading MacLib...")
local ok, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not ok or not Lib then print("[HTBoss] MacLib failed: " .. tostring(Lib)) return end
task.wait()
if not alive() or e.__tok ~= myUID then print("[HTBoss] Aborted (superseded)") return end

local W = Lib:Window({Title = "Hunting Together", Subtitle = "Auto Boss", DragStyle = 1,
                       ShowUserInfo = true, AcrylicBlur = false})
getgenv().__W = W
local TG = W:TabGroup()
local Tabs = {
	Boss = TG:Tab({Name = "Auto Boss", Image = "rbxassetid://10723343321"}),
	Sell = TG:Tab({Name = "Auto Sell", Image = "rbxassetid://10709769841"}),
	Coat = TG:Tab({Name = "ใบธาตุ", Image = "rbxassetid://10723346959"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}

local L = Tabs.Boss:Section({Side = "Left"})
L:Header({Text = "Auto Boss"})
L:Toggle({Name = "เปิด Auto Boss", Default = e.hbEnabled,
	Callback = function(v)
		e.hbEnabled = v; sv()
		if v then needReturn = true end
		if not v then pcall(function() local _, hum, hrp = myChar(); if hum then hum:MoveTo(hrp.Position) end end) end
	end}, "hbEnabled")

local farmLbl
local function farmText()
	local fp = e.hbFarmPos
	if type(fp) ~= "table" or not fp.x then return "จุดฟาร์ม: ยังไม่ได้บันทึก" end
	return ("จุดฟาร์ม: %.0f, %.0f, %.0f"):format(fp.x, fp.y, fp.z)
end
L:Button({Name = "บันทึกจุดฟาร์ม (ตำแหน่งตอนนี้)",
	Callback = function()
		local _, _, hrp = myChar()
		if not hrp then return end
		local p = hrp.Position
		e.hbFarmPos = {x = p.X, y = p.Y, z = p.Z}; sv()
		pcall(function() farmLbl:UpdateName(farmText()) end)
		pcall(function() W:Notify({Title = "Auto Boss", Description = "บันทึกจุดฟาร์มแล้ว", Lifetime = 3}) end)
	end})
farmLbl = L:Label({Text = farmText()})
L:Toggle({Name = "ตายแล้วเกิดที่หมู่บ้านทันที", Default = e.hbAutoRespawn,
	Callback = function(v) e.hbAutoRespawn = v; sv() end}, "hbAutoRespawn")
L:Toggle({Name = "ตายแล้วกลับไปตีบอสตัวเดิมต่อ (สูงสุด 3 ครั้ง/รอบเกิด)", Default = e.hbRetryBoss,
	Callback = function(v) e.hbRetryBoss = v; sv() end}, "hbRetryBoss")
L:Toggle({Name = "ออกเดินทางล่วงหน้า ให้ถึงตอนบอสเกิดพอดี", Default = e.hbPreArrive,
	Callback = function(v) e.hbPreArrive = v; sv() end}, "hbPreArrive")
L:Toggle({Name = "หลบสกิล + พื้นไฟ ของ Volcano Turtle King", Default = e.hbDodge,
	Callback = function(v) e.hbDodge = v; sv() end}, "hbDodge")
L:Toggle({Name = "ใช้ Dash ตอนหลบ", Default = e.hbDash,
	Callback = function(v) e.hbDash = v; sv() end}, "hbDash")
L:Toggle({Name = "ใช้เสาวาร์ป (เดินทางไวขึ้น)", Default = e.hbUseWarp,
	Callback = function(v) e.hbUseWarp = v; sv() end}, "hbUseWarp")
L:Toggle({Name = "เปิด Auto ของเกมตอนถึงจุดฟาร์ม", Default = e.hbAutoAtFarm,
	Callback = function(v) e.hbAutoAtFarm = v; sv() end}, "hbAutoAtFarm")
L:Toggle({Name = "ข้ามเซิร์ฟ (hop) เมื่อไม่มีบอสที่เลือก", Default = e.hbHop,
	Callback = function(v) e.hbHop = v; sv() end}, "hbHop")
-- Two independent knobs (drag, or click the number to type):
--   hbHopWait  = wait for a selected boss that will spawn within this many sec,
--                kill it first; 0 = don't wait for upcoming spawns.
--   hbHopDelay = once there's nothing to wait for, linger this long before the
--                hop (a boss appearing cancels it); 0 = hop immediately.
L:Slider({Name = "รอบอสที่จะเกิดภายใน (วิ)", Minimum = 0, Maximum = 600, Default = e.hbHopWait,
	Precision = 0, DisplayMethod = "Round", Suffix = " วิ",
	Callback = function(v) e.hbHopWait = math.floor(v + 0.5); sv() end}, "hbHopWait")
L:Slider({Name = "ไม่มีบอส → หน่วงก่อนข้ามเซิร์ฟ (วิ) · 0 = ทันที", Minimum = 0, Maximum = 300, Default = e.hbHopDelay,
	Precision = 0, DisplayMethod = "Round", Suffix = " วิ",
	Callback = function(v) e.hbHopDelay = math.floor(v + 0.5); sv() end}, "hbHopDelay")

local bossLabels = {}
for _, b in ipairs(BOSSES) do table.insert(bossLabels, b.label) end
local selected = {}
for label, on in pairs(e.hbBosses) do if on and BY_LABEL[label] then table.insert(selected, label) end end
L:Dropdown({Name = "บอสที่จะไปตี", Multi = true, Required = false,
	Options = bossLabels, Default = selected,
	Callback = function(sel)
		local set = {}
		for name, on in pairs(sel) do if on then set[name] = true end end
		e.hbBosses = set; sv()
	end}, "hbBosses")

local R = Tabs.Boss:Section({Side = "Right"})
R:Header({Text = "สถานะ"})
local stateLbl = R:Label({Text = "Starting..."})
local bossLbl = R:Label({Text = "-"})

local SellL = Tabs.Sell:Section({Side = "Left"})
SellL:Header({Text = "Auto Sell"})
SellL:Toggle({Name = "เปิด Auto Sell (ทุก 30 วิ)", Default = e.hbSellOn,
	Callback = function(v) e.hbSellOn = v; sv() end}, "hbSellOn")
local sellOptions = {SELL_JUNK}
for i = 0, 4 do table.insert(sellOptions, SELL_TIERS[i]) end
local sellDefault = {}
for _, label in ipairs(sellOptions) do if e.hbSellPick[label] then table.insert(sellDefault, label) end end
SellL:Dropdown({Name = "ของที่จะขาย", Multi = true, Required = false,
	Options = sellOptions, Default = sellDefault,
	Callback = function(sel)
		local set = {}
		for name, on in pairs(sel) do if on then set[name] = true end end
		e.hbSellPick = set; sv()
	end}, "hbSellPick")
SellL:Button({Name = "ขายตอนนี้", Callback = function() pcall(sellNow) end})
SellL:Label({Text = "ไม่ขายเด็ดขาด: ของที่ล็อก, ที่ใส่อยู่,\nที่ใส่ในอาชีพอื่น/ชุด Loadout, ที่ตีบวกแล้ว, ขั้น VI"})

local SellR = Tabs.Sell:Section({Side = "Right"})
SellR:Header({Text = "สถานะการขาย"})
local sellLbl = SellR:Label({Text = "-"})

local CoatL = Tabs.Coat:Section({Side = "Left"})
CoatL:Header({Text = "Auto ใบธาตุ (Weapon Imbue)"})
CoatL:Toggle({Name = "เปิด Auto ใบธาตุ", Default = e.hbCoatOn,
	Callback = function(v) e.hbCoatOn = v; sv() end}, "hbCoatOn")
local coatOptions = {COAT_FOLLOW}
for _, c in ipairs(COAT_CHOICES) do table.insert(coatOptions, c.label) end
CoatL:Dropdown({Name = "ธาตุที่จะใช้", Multi = false, Required = true,
	Options = coatOptions, Default = table.find(coatOptions, e.hbCoatPick) or 1, -- single-select Default is an index
	Callback = function(v)
		if type(v) == "table" then for k, on in pairs(v) do if on then v = k break end end end
		if type(v) == "string" then e.hbCoatPick = v; sv() end
	end}, "hbCoatPick")
CoatL:Label({Text = "ใช้ทีละ 1 ใบ ตอนธาตุเดิมเหลือ ≤ 1 นาที (หรือหมดแล้ว)\nเลือกธาตุอื่นจากที่ใช้อยู่ = ใบใหม่จะทับธาตุเดิมทันที"})

local CoatR = Tabs.Coat:Section({Side = "Right"})
CoatR:Header({Text = "สถานะ"})
local coatLbl = CoatR:Label({Text = "-"})

local SL = Tabs.Settings:Section({Side = "Left"})
SL:Header({Text = "UI"})
SL:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() W:SetState(not W:GetState()) end) end}, "HTBossToggleUIKeybind")
SL:Label({Text = "กด RightShift เพื่อซ่อน/แสดงหน้าต่าง"})
SL:Header({Text = "General"})
SL:Toggle({Name = "Auto Reconnect (เน็ตหลุด/เซิร์ฟมีปัญหา → เข้าใหม่)", Default = e.hbReconnect,
	Callback = function(v) e.hbReconnect = v; sv() end}, "hbReconnect")
SL:Header({Text = "Auto Save"})
SL:Label({Text = "ตั้งค่าทั้งหมดเซฟอัตโนมัติที่:\n" .. SF})

-- No on-screen button: the window is toggled with the keybind only. Clear any
-- floating button an older build of this script left behind.
pcall(function()
	for _, root in ipairs({gethui and gethui(), game:GetService("CoreGui")}) do
		local old = root and root:FindFirstChild("HTBossToggle")
		if old then old:Destroy() end
	end
end)

local function fmtWait(sec)
	if sec <= 0 then return "อีกไม่นาน" end
	return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

task.spawn(function()
	while alive() do
		task.wait(1)
		pcall(function()
			stateLbl:UpdateName(("%s\n%s\nฆ่าบอสแล้ว: %d  ·  เก็บของ: %d  ·  หลบวงเขียว: %d  ·  หลบสกิล: %d  ·  Auto เกม: %s")
				:format(stats.state, stats.detail, stats.bossKills, stats.looted, stats.dodges, stats.skillDodges, autoOn() and "ON" or "OFF"))
		end)
		pcall(function()
			local now = math.floor(workspace:GetServerTimeNow())
			local myLv = plr:GetAttribute("Level") or 1
			local lines = {}
			for _, b in ipairs(BOSSES) do
				local mark = e.hbBosses[b.label] and "✔ " or "· "
				local st = bossAlive(b.id) and "เกิดอยู่" or ("เกิดใน " .. fmtWait(bossNext(b.id) - now))
				if myLv < b.level then st = st .. " (เวลไม่ถึง รอ Lv" .. b.level .. ")" end
				table.insert(lines, mark .. b.name .. " — " .. st)
			end
			bossLbl:UpdateName(table.concat(lines, "\n"))
		end)
		pcall(function()
			local cur, left = activeCoat()
			local items = pjson("ItemsJson")
			local counts = {}
			for _, c in ipairs(COAT_CHOICES) do
				table.insert(counts, ("%s %d"):format(c.el, tonumber(items["weapon_coat_" .. c.el]) or 0))
			end
			coatLbl:UpdateName(("ธาตุตอนนี้: %s\nใช้ไปแล้ว: %d ใบ\nล่าสุด: %s\nคงเหลือ: %s")
				:format(cur and ("%s (%d:%02d)"):format(cur, math.floor(left / 60), math.floor(left % 60)) or "ไม่มี",
					coatStats.used, coatStats.last, table.concat(counts, " · ")))
		end)
		pcall(function()
			local pending, pendingGold = sellScan()
			sellLbl:UpdateName(("ล่าสุด: %s\nขายไปแล้ว: %d รายการ · ~%d Gold\nตอนนี้เข้าเงื่อนไขขาย: %d รายการ · ~%d Gold")
				:format(sellStats.last, sellStats.sold, sellStats.gold, #pending, pendingGold))
		end)
	end
end)

W.onUnloaded(function()
	-- Only a manual close (still the live generation) should stop the loops; a
	-- re-run unloads this window too and must not supersede the new copy.
	if getgenv().__G == G then getgenv().__G = G + 1 end
	print("[HTBoss] Unloaded")
end)
Tabs.Boss:Select()
print("[HTBoss] UI ready")
