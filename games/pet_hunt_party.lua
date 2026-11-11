-- Pet Hunt Party RPG (placeId 88452215181406) auto script.
-- UI/structure mirrors hunting_together_boss.lua: MacLib window, RightShift
-- toggles it, every feature defaults OFF, settings persist, autoexec-friendly.
--
-- Drives the game through its OWN client controllers (required live), so actions
-- look exactly like the player's:
--   Auto Farm  -> the game's own auto just STANDS on one spawn and hits whatever
--                 lands next to it. This drives the character with Humanoid:MoveTo
--                 toward the highest-level monster in the current field (+ the
--                 game's auto-attack via TargetController), so it actually roams
--                 to level-appropriate monsters instead of camping low ones.
--   Auto Sell  -> Controllers.GearState.get().gear + RS.Remotes.Gear:FireServer
--                 ("sell", uid): the Bag's SELL call. Never sells locked/equipped/
--                 zero-value. (Bypasses the AutoSellPass gamepass gate.)
--   Auto Collect    -> keeps the game's "autoPickup" setting on.
--   Auto Equip Best -> best owned item per slot via Gear:FireServer("equip", uid).
--   Auto Open Chest -> fireproximityprompt on any "Open Chest" prompt in range.
-- Auto Boss (world boss travel+dodge) still to come.

getgenv().__PHP = (getgenv().__PHP or 0) + 1
local G = getgenv().__PHP
pcall(function() if getgenv().__PHPW then getgenv().__PHPW:Unload() end end)
local function alive() return getgenv().__PHP == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local plr = Players.LocalPlayer

-- ------------------------------------------------------------------ settings
local SF = "PetHunt/state.json"
local DEFAULTS = {phFarm = false, phSellOn = false, phSellTiers = nil, phSellEvery = 20,
	phCollect = false, phEquip = false, phEquipEvery = 15, phChest = false, phFarmBoss = false,
	phBossOn = false, phBossPick = nil, phFarmPos = nil,
	phWBOn = false, phWBPick = nil, phWBFields = nil, phReconnect = true,
	phFarmBelow = 99, phFarmAbove = 10}  -- farm monsters in [myLv-below, myLv+above]
local e = {}
pcall(function()
	if isfile and isfile(SF) then
		local t = HS:JSONDecode(readfile(SF))
		if type(t) == "table" then e = t end
	end
end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
local function sv()
	pcall(function()
		if makefolder and not isfolder("PetHunt") then makefolder("PetHunt") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

-- ------------------------------------------------------------- game handles
local function controllers()
	local ps = plr:FindFirstChild("PlayerScripts")
	local c = ps and ps:FindFirstChild("Client")
	c = c and c:FindFirstChild("Controllers")
	return c
end

local TC, GearState, Equipment, gearRemote, GSettings, Zones
local function hooks()
	if TC and GearState and Equipment and gearRemote then return true end
	local c = controllers()
	if not c then return false end
	local okC = pcall(function()
		TC = require(c:WaitForChild("TargetController", 5))
		GearState = require(c:WaitForChild("GearState", 5))
	end)
	pcall(function() GSettings = require(c:WaitForChild("Settings", 5)) end)
	pcall(function() Equipment = require(RS.Shared.Config.Equipment) end)
	pcall(function() Zones = require(RS.Shared.Config.Zones) end)
	pcall(function() gearRemote = RS.Remotes.Gear end)
	return okC and TC ~= nil and GearState ~= nil and Equipment ~= nil and gearRemote ~= nil
end

local function myChar()
	local c = plr.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then return c, hum, hrp end
	return nil
end

-- Which field (Zones.fields entry) a position sits in. Fields are laid along X
-- ~380 studs apart, so "same field" = within half that of the field's entrance.
local function fieldAt(pos)
	if not Zones then return nil end
	local ok, f = pcall(Zones.baseAt, pos)
	if ok and type(f) == "table" and f.id then return f end
	return nil
end

-- Auto Reconnect: 3-trigger version (PlayerRemoving alone misses silent drops
-- where the transport dies but LocalPlayer never leaves and the native
-- "Disconnected" dialog just sits there). Debounced 5s, hooked once across
-- reloads. cp_boot's queue_on_teleport re-runs the script on the new join.
if not getgenv().__PHP_RECON then
	getgenv().__PHP_RECON = true
	local TeleportService = game:GetService("TeleportService")
	local firedAt = 0
	local function tryReconnect()
		if not e.phReconnect then return end
		if os.clock() - firedAt < 5 then return end
		firedAt = os.clock()
		pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
	end
	pcall(function() Players.PlayerRemoving:Connect(function(p) if p == plr then tryReconnect() end end) end)
	pcall(function() plr.AncestryChanged:Connect(function(_, parent) if parent ~= Players then tryReconnect() end end) end)
	pcall(function() game:GetService("GuiService").ErrorMessageChanged:Connect(tryReconnect) end)
	task.spawn(function()
		local CoreGui = game:GetService("CoreGui")
		while true do
			task.wait(5)
			if e.phReconnect then
				pcall(function()
					for _, inst in ipairs(CoreGui:GetDescendants()) do
						if inst:IsA("TextLabel") and inst.Text == "Disconnected" then tryReconnect(); break end
					end
				end)
			end
		end
	end)
end

-- ----------------------------------------------------------------- rarity
-- def.lines is the gear's stat-line count = rarity tier 0..4 (dungeon gear is
-- its own bucket "dg"), the same key the game's "Sell all" uses.
local TIER_LABELS = {
	[0] = "ขั้น 0 (ธรรมดา)",
	[1] = "ขั้น 1",
	[2] = "ขั้น 2",
	[3] = "ขั้น 3",
	[4] = "ขั้น 4 (สูงสุด)",
	dg = "ของดันเจี้ยน",
}
local TIER_ORDER = {0, 1, 2, 3, 4, "dg"}

local function defaultTiers()
	-- by default only the cheap tiers, mirroring the game's {[0]=true,1,2}
	return {[TIER_LABELS[0]] = true, [TIER_LABELS[1]] = true, [TIER_LABELS[2]] = true}
end
if type(e.phSellTiers) ~= "table" then e.phSellTiers = defaultTiers() end

local function tierOf(def)
	if def.dungeon then return "dg" end
	return math.clamp(tonumber(def.lines) or 0, 0, 4)
end

-- ------------------------------------------------------------------- stats
local stats = {farm = "-", sell = "-", sold = 0, gold = 0, collect = "-", equip = "-", equipped = 0, chest = "-"}

-- 7 gear slots (Equipment.types). Auto Equip Best fills each with the strongest
-- owned item you can actually wear (class nil = any class, else your class).
local SLOTS = {"weapon", "headgear", "face", "armor", "garment", "shoes", "accessory"}

-- --------------------------------------------------------------- auto farm
-- The game's own auto parks on a spawn and only swats what touches it. So: keep
-- the game's auto ON (for skills + the actual hitting) but DRIVE the character
-- with Humanoid:MoveTo toward the highest-level monster in the field it can
-- handle, so it roams to level-appropriate monsters. Stays inside the current
-- field (monsters X within half a field-spacing of ours) and ignores the field
-- boss unless phFarmBoss is set. Real walking only — no teleporting.
local PFS = game:GetService("PathfindingService")
local NEAR_RADIUS = 150       -- fight the strongest monster THIS close first (so it
                              -- actually engages instead of chasing a far wanderer)
local FARM_RADIUS = 450       -- only roam this far when nothing is near
local ENGAGE_DIST = 16        -- within this = arrived, turn auto ON and attack
local STUCK_S = 10            -- can't reach a target in this long -> skip it a while
local farmTarget = nil
local travelStart = 0         -- when we started heading to the CURRENT target (stuck timer)
local lastPick = 0            -- last time we re-evaluated the target (repick cadence)
local skipUntil = {}          -- monster -> os.clock() deadline

-- Pick a target in the SAME FIELD as us (baseAt per nearby candidate, so the
-- character never chases one across the field gate into a locked field):
--   phFarmBoss on + the field boss present & reachable -> the boss (to unlock
--   the next field); otherwise the highest-level monster, closest breaking ties.
local function pickTarget(hrp)
	local myField = fieldAt(hrp.Position)
	local myId = myField and myField.id
	local now = os.clock()
	local bossId = myField and myField.boss
	-- nearHi: strongest within NEAR_RADIUS (what we actually fight)
	-- nearest: closest anything within FARM_RADIUS (roam toward it when none near)
	-- bossPick: the field boss when phFarmBoss is on
	-- level window relative to the player (e.g. "no more than 2 below me")
	local myLv = tonumber(plr:GetAttribute("Level")) or 1
	local loLv = myLv - (tonumber(e.phFarmBelow) or 99)
	local hiLv = myLv + (tonumber(e.phFarmAbove) or 10)
	local nearHi, nearHiLv, nearHiD, nearest, nearestD, bossPick
	for _, m in ipairs(workspace.Monsters:GetChildren()) do
		if m.PrimaryPart and (tonumber(m:GetAttribute("Health")) or 0) > 0
			and (not skipUntil[m] or skipUntil[m] < now) then
			local isBoss = m:GetAttribute("IsBoss") == true or m:GetAttribute("MonsterId") == bossId
			if (not isBoss) or e.phFarmBoss then
				local d = (m.PrimaryPart.Position - hrp.Position).Magnitude
				if d < FARM_RADIUS then
					local mf = fieldAt(m.PrimaryPart.Position)
					if not myId or (mf and mf.id == myId) then
						if isBoss and e.phFarmBoss and (not bossPick or d < bossPick.d) then
							bossPick = {m = m, d = d}
						end
						-- regular monsters must fall in the chosen level window
						local lv = tonumber(m:GetAttribute("Level")) or 0
						if (not isBoss) and lv >= loLv and lv <= hiLv then
							if not nearest or d < nearestD then nearest, nearestD = m, d end
							if d < NEAR_RADIUS and (not nearHi or lv > nearHiLv or (lv == nearHiLv and d < nearHiD)) then
								nearHi, nearHiLv, nearHiD = m, lv, d
							end
						end
					end
				end
			end
		end
	end
	if bossPick then return bossPick.m end  -- boss first when phFarmBoss is on
	if nearHi then return nearHi end        -- strongest nearby: engage now
	return nearest                          -- nothing near: roam to the closest
end

-- Walk to a point AROUND buildings with PathfindingService (straight MoveTo got
-- caught on structures). Follows the computed waypoints; recomputes when the goal
-- drifts or the route runs out. Returns true while still en route.
-- Travel to a point with PathfindingService + robust unstick. The map has
-- stairs, walls and raised arena platforms that the navmesh sometimes can't
-- route to; then a straight MoveTo wedges into a corner. So: track progress
-- toward the goal, and when it stalls, SIDESTEP perpendicular (alternating
-- left/right) and jump to peel off the wall, and force a path replan.
local pf = {path = nil, wps = {}, i = 1, goal = nil, at = 0, lastPos = nil,
	bestD = math.huge, bestAt = 0, jumpAt = 0, side = 1, sideUntil = 0}
local function pathTo(hum, hrp, goalPos)
	local now = os.clock()
	local toGoal = Vector3.new(goalPos.X - hrp.Position.X, 0, goalPos.Z - hrp.Position.Z)
	local goalD = toGoal.Magnitude

	-- progress tracking
	if goalD < pf.bestD - 2 then pf.bestD = goalD; pf.bestAt = now end
	local stalled = now - pf.bestAt > 1.3

	local needReplan = not pf.goal or (goalPos - pf.goal).Magnitude > 12 or pf.i > #pf.wps or stalled
	if needReplan and now - pf.at > 0.45 then
		pf.at = now
		if not pf.path then pf.path = PFS:CreatePath({AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = true, AgentMaxSlope = 89, WaypointSpacing = 5}) end
		local ok = pcall(function() pf.path:ComputeAsync(hrp.Position, goalPos) end)
		if ok and pf.path.Status == Enum.PathStatus.Success then
			pf.wps = pf.path:GetWaypoints(); pf.i = 2; pf.goal = goalPos
		else
			pf.wps = {}; pf.goal = goalPos
		end
	end

	if stalled then
		-- sidestep off the obstacle: a point to the side + slightly ahead, + jump.
		-- flip side every 1.2s so we try both ways out of a corner.
		if now > pf.sideUntil then pf.side = -pf.side; pf.sideUntil = now + 1.2 end
		local dir = goalD > 1 and toGoal.Unit or Vector3.new(0, 0, 1)
		local perp = Vector3.new(-dir.Z, 0, dir.X)
		hum:MoveTo(hrp.Position + perp * (pf.side * 8) + dir * 3)
		if now - pf.jumpAt > 0.5 then hum.Jump = true; pf.jumpAt = now end
		pf.lastPos = hrp.Position
		return
	end

	local wp = pf.wps[pf.i]
	local aim = wp and wp.Position or goalPos
	if wp and wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
	hum:MoveTo(aim)
	-- climb help: hop when barely moving or the aim is above us (stairs)
	if pf.lastPos then
		local moved = (hrp.Position - pf.lastPos).Magnitude
		if (moved < 1.2 or aim.Y - hrp.Position.Y > 2.5) and now - pf.jumpAt > 0.85 then
			hum.Jump = true; pf.jumpAt = now
		end
	end
	pf.lastPos = hrp.Position
	if wp then
		local flat = Vector3.new(hrp.Position.X - wp.Position.X, 0, hrp.Position.Z - wp.Position.Z)
		if flat.Magnitude < 5 then pf.i += 1 end
	end
end
local function pathReset() pf.goal = nil; pf.wps = {}; pf.i = 1; pf.lastPos = nil; pf.bestD = math.huge; pf.bestAt = os.clock() end

-- Travel with the game's auto OFF (so it doesn't fight our MoveTo and stutter),
-- then switch it ON only once we're on top of the monster. Re-issue MoveTo only
-- when the goal shifts, so the walk is smooth instead of restarting every tick.
local function setAuto(want)
	if (TC.auto == true) ~= want then pcall(TC.setAuto, want) end
end

-- ------------------------------------------------------- auto field boss
-- Each field has one boss (Zones.fields[].boss); it spawns at the field's arena
-- and appears in workspace.Monsters as an IsBoss model with that MonsterId. Pick
-- which to fight; when a chosen one is up in OUR field, go kill it, then walk back
-- to the saved farm spot and keep farming until it (or another) respawns.
local FIELD_BOSSES, BOSS_LABEL = {}, {}
local function buildFieldBosses()
	if #FIELD_BOSSES > 0 then return end
	local okZ, Z = pcall(require, RS.Shared.Config.Zones)
	local okM, M = pcall(require, RS.Shared.Config.Monsters)
	if not (okZ and okM and type(Z.fields) == "table") then return end
	for _, f in ipairs(Z.fields) do
		local bid = f.boss
		local d = (M.defs or {})[bid] or {}
		local name = d.name or bid
		local lv = tonumber(d.level) or (f.levels and f.levels[2]) or 0
		local label = ("%s · Lv%d (%s)"):format(name, lv, f.name or f.id)
		table.insert(FIELD_BOSSES, {fieldId = f.id, bossId = bid, name = name, lv = lv, label = label,
			respawn = tonumber(d.respawn) or 600})
		BOSS_LABEL[bid] = label
	end
end
buildFieldBosses()

-- World bosses: rarer event bosses (WorldBoss config, every ~30 min). A live one
-- is a monster in workspace.Monsters carrying a WorldBoss attribute + MonsterId.
-- They can be anywhere, so (unlike field bosses) we don't restrict to our field.
local WB_LABEL = {}        -- both "wb_<id>" (live MonsterId) and "<id>" -> display name
local WORLD_BOSSES = {}
local FIELDS = {}          -- {id, name, label} per field, for the world-boss field picker
local FIELD_NAME = {}      -- fieldId -> plain display name (for ArenaCenter->field match)
local FIELD_LABEL = {}     -- fieldId -> picker label (name + level range)
local WB_LEVEL = 99        -- world bosses scale to ~ maxFieldLevel + levelOver
local function buildWorldBosses()
	if #WORLD_BOSSES > 0 then return end
	local okZ, Z = pcall(require, RS.Shared.Config.Zones)
	local maxLv = 0
	if okZ then
		for _, f in ipairs(Z.allFields or Z.fields or {}) do -- allFields = all 12 biomes
			local hi = f.levels and f.levels[2] or 0
			maxLv = math.max(maxLv, tonumber(hi) or 0)
			local name = f.name or f.id
			FIELD_NAME[f.id] = name
			local flabel = (f.levels and f.levels[1]) and ("%s (Lv%d-%d)"):format(name, f.levels[1], f.levels[2]) or name
			FIELD_LABEL[f.id] = flabel
			table.insert(FIELDS, {id = f.id, name = name, label = flabel})
		end
	end
	local okWB, WB = pcall(require, RS.Shared.Config.WorldBoss)
	if okWB then
		WB_LEVEL = maxLv + (tonumber(WB.levelOver) or 3)
		if type(WB.byId) == "table" then
			for id, d in pairs(WB.byId) do
				local name = (type(d) == "table" and d.name) or id
				local label = ("%s · Lv~%d"):format(name, WB_LEVEL)
				table.insert(WORLD_BOSSES, {id = id, name = name, label = label})
				WB_LABEL[id] = name          -- config id
				WB_LABEL["wb_" .. id] = name -- live monster MonsterId is prefixed "wb_"
			end
		end
	end
end
buildWorldBosses()

-- A live world boss (WorldBoss attribute) worth fighting. Two optional filters,
-- so you can target by boss name, by WHICH MAP it spawned in, or both:
--   phWBPick   -- empty = any boss name
--   phWBFields -- empty = any field; else only engage one whose spawn map is picked
local function findWorldBoss(hrp)
	if not e.phWBOn then return nil end
	local pickOn = type(e.phWBPick) == "table" and next(e.phWBPick) ~= nil
	local fieldOn = type(e.phWBFields) == "table" and next(e.phWBFields) ~= nil
	local best, bestD
	for _, m in ipairs(workspace.Monsters:GetChildren()) do
		if m.PrimaryPart and m:GetAttribute("WorldBoss") and (tonumber(m:GetAttribute("Health")) or 0) > 0 then
			local name = WB_LABEL[m:GetAttribute("MonsterId")]
			local okName = (not pickOn) or (name and e.phWBPick[name])
			local okField = not fieldOn
			if fieldOn then
				local center = m:GetAttribute("ArenaCenter")
				local pos = (typeof(center) == "Vector3") and center or m.PrimaryPart.Position
				local f = fieldAt(pos)
				okField = f and e.phWBFields[FIELD_LABEL[f.id] or f.id] == true
			end
			if okName and okField then
				local dd = (m.PrimaryPart.Position - hrp.Position).Magnitude
				if not best or dd < bestD then best, bestD = m, dd end
			end
		end
	end
	return best
end

local needReturn = false
local engagingBoss = false
local bossDeadAt = {}  -- bossId -> os.time() of last death (to estimate respawn)
local bossWasUp = {}   -- bossId -> was alive last status tick
-- A selected field boss that's alive and in the SAME field as us (so it's
-- walkable; cross-field needs a warp we don't do here). Nearest first.
local function findBossTarget(hrp)
	if not (e.phBossOn and type(e.phBossPick) == "table") then return nil end
	local myField = fieldAt(hrp.Position)
	local myId = myField and myField.id
	local best, bestD
	for _, m in ipairs(workspace.Monsters:GetChildren()) do
		if m.PrimaryPart and m:GetAttribute("IsBoss") == true and (tonumber(m:GetAttribute("Health")) or 0) > 0 then
			local label = BOSS_LABEL[m:GetAttribute("MonsterId")]
			if label and e.phBossPick[label] then
				local mf = fieldAt(m.PrimaryPart.Position)
				if not myId or (mf and mf.id == myId) then
					local dd = (m.PrimaryPart.Position - hrp.Position).Magnitude
					if not best or dd < bestD then best, bestD = m, dd end
				end
			end
		end
	end
	return best
end

task.spawn(function()
	while alive() do
		task.wait(0.12)
		if not (e.phFarm or e.phBossOn or e.phWBOn) then stats.farm = "ปิดอยู่"; pathReset(); continue end
		if not hooks() then stats.farm = "รอเข้าเกม"; continue end
		local _, hum, hrp = myChar()
		if not hrp then stats.farm = "รอเกิดใหม่"; continue end

		-- Drive a boss trip: travel (auto off, pathfind) until close, then hold auto
		-- ON and FOLLOW the roaming boss until it's really far (35) -- hysteresis so
		-- small boss moves don't flip the mode off and interrupt attacks.
		local function fightBoss(boss, tag)
			needReturn = true
			local d = (boss.PrimaryPart.Position - hrp.Position).Magnitude
			if d > (engagingBoss and 35 or ENGAGE_DIST) then
				engagingBoss = false
				setAuto(false); pathTo(hum, hrp, boss.PrimaryPart.Position)
				stats.farm = ("ไป%s %s (ห่าง %.0f)"):format(tag, boss.Name, d)
			else
				engagingBoss = true
				setAuto(true)
				if TC.current ~= boss then pcall(TC.set, boss) end
				if d > 8 then hum:MoveTo(boss.PrimaryPart.Position) else hum:MoveTo(hrp.Position); pathReset() end
				stats.farm = ("%s %s (เลือด %d%%)"):format(tag, boss.Name,
					math.floor((tonumber(boss:GetAttribute("Health")) or 0) / math.max(tonumber(boss:GetAttribute("MaxHealth")) or 1, 1) * 100))
			end
		end

		-- WORLD BOSS first (rare event), then FIELD BOSS
		if e.phWBOn then
			local wb = findWorldBoss(hrp)
			if wb and wb.PrimaryPart then fightBoss(wb, "ตีบอสโลก"); continue end
		end
		if e.phBossOn then
			local boss = findBossTarget(hrp)
			if boss and boss.PrimaryPart then fightBoss(boss, "ตีบอส"); continue end
		end

		-- no boss up: any boss mode on -> walk back to the saved farm spot after a
		-- trip. Full 3D distance (the arena often sits directly ABOVE the farm spot,
		-- same X/Z higher Y, so a flat check would strand us up there).
		if e.phBossOn or e.phWBOn then
			engagingBoss = false
			if needReturn and type(e.phFarmPos) == "table" and e.phFarmPos.x then
				local fp = Vector3.new(e.phFarmPos.x, e.phFarmPos.y, e.phFarmPos.z)
				if (hrp.Position - fp).Magnitude > ENGAGE_DIST then
					setAuto(false); pathTo(hum, hrp, fp)
					stats.farm = "กลับจุดฟาร์ม"
					continue
				end
				needReturn = false; pathReset()
			end
			-- otherwise fall through and farm while waiting for the boss to respawn
			if not e.phFarm then
				-- boss-only mode: hold near the farm spot and let the game auto fight
				local fp = type(e.phFarmPos) == "table" and e.phFarmPos.x and Vector3.new(e.phFarmPos.x, e.phFarmPos.y, e.phFarmPos.z)
				if fp and (hrp.Position - fp).Magnitude > 40 then
					setAuto(false); pathTo(hum, hrp, fp)
					stats.farm = "รอบอส (กลับจุดฟาร์ม)"
				else
					setAuto(true); pathReset()
					stats.farm = "รอบอสเกิด (ฟาร์มรอ)"
				end
				continue
			end
		end

		local t = farmTarget
		local now = os.clock()
		local dead = not (t and t.Parent and (tonumber(t:GetAttribute("Health")) or 0) > 0)
		-- re-pick when the target died, or ~once a second while still walking to a
		-- far one (so a closer/stronger monster that wandered in gets taken instead)
		local far = t and t.PrimaryPart and (t.PrimaryPart.Position - hrp.Position).Magnitude > ENGAGE_DIST
		if dead or (far and now - lastPick > 1) then
			lastPick = now
			local nt = pickTarget(hrp)
			if nt ~= t then farmTarget, t, travelStart = nt, nt, now; pathReset() end
		end

		-- Boss mode with no boss up: field bosses spawn at the BossArena on a timer
		-- (no summon prompt), so camp the arena and farm there -- when the boss
		-- pops within NEAR_RADIUS it gets picked next tick. Only kick in when the
		-- current pick isn't already a boss and we're not near the arena yet.
		local tIsBoss = t and t:GetAttribute("IsBoss") == true
		local myF = fieldAt(hrp.Position)
		local arena = e.phFarmBoss and myF and myF.arena and myF.arena.center
		if arena and not tIsBoss then
			local ac = (typeof(arena) == "Vector3") and arena or Vector3.new(arena.X or arena[1] or 436, 0, arena.Z or arena[3] or 112)
			if (Vector3.new(hrp.Position.X - ac.X, 0, hrp.Position.Z - ac.Z)).Magnitude > 55 then
				setAuto(false)
				pathTo(hum, hrp, ac)
				stats.farm = "ไปรอบอสที่ลานบอส (" .. (myF.name or myF.id) .. ")"
				continue
			end
		end

		if not (t and t.PrimaryPart) then
			setAuto(false)
			local f = fieldAt(hrp.Position)
			stats.farm = f and ("ไม่เจอมอนในฟิลด์ " .. (f.name or f.id) .. (e.phFarmBoss and " (รอบอสเกิด)" or "")) or "ไม่เจอมอนในฟิลด์นี้"
		else
			local d = (t.PrimaryPart.Position - hrp.Position).Magnitude
			if d > ENGAGE_DIST then
				-- been walking too long without arriving (wall/wanderer): drop it
				if os.clock() - travelStart > STUCK_S then
					skipUntil[t] = os.clock() + 12
					farmTarget = nil
					pathReset()
				else
					-- travel: auto OFF, walk AROUND buildings to the monster
					setAuto(false)
					pathTo(hum, hrp, t.PrimaryPart.Position)
					local boss = (t:GetAttribute("IsBoss") == true)
					stats.farm = ("%s %s L%d (ห่าง %.0f)"):format(boss and "ไปตีบอส" or "เดินไปหา",
						t.Name, tonumber(t:GetAttribute("Level")) or 0, d)
				end
			else
				-- arrived: auto ON, let the game attack; re-lock our target
				setAuto(true)
				pathReset()
				if TC.current ~= t then pcall(TC.set, t) end
				local boss = (t:GetAttribute("IsBoss") == true)
				stats.farm = ("%s %s L%d"):format(boss and "ตีบอส" or "ตี", t.Name, tonumber(t:GetAttribute("Level")) or 0)
			end
		end
	end
end)

-- -------------------------------------------------------------- auto chest
-- Party Chests drop in the world with an "Open Chest" ProximityPrompt. Fire it
-- the moment one is in range (fireproximityprompt skips the hold), so chests get
-- opened instantly while you farm near them.
task.spawn(function()
	local total = 0
	while alive() do
		task.wait(0.4)
		if not e.phChest then stats.chest = "ปิดอยู่"; continue end
		local _, _, hrp = myChar()
		if not hrp then continue end
		local opened = 0
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.Enabled
				and (d.Name == "PartyChestPrompt" or d.ActionText == "Open Chest" or d.ObjectText == "Party Chest") then
				local part = d.Parent
				local pos = part and (part:IsA("BasePart") and part.Position
					or (part:IsA("Model") and select(1, part:GetBoundingBox()).Position))
				local maxd = d.MaxActivationDistance > 0 and d.MaxActivationDistance or 14
				if pos and (pos - hrp.Position).Magnitude <= maxd + 2 then
					local ok = pcall(function() fireproximityprompt(d) end)
					if ok then opened += 1; total += 1 end
				end
			end
		end
		stats.chest = opened > 0 and ("เพิ่งเปิด " .. opened .. " กล่อง (รวม " .. total .. ")")
			or ("เฝ้ารอกล่อง (เปิดแล้ว " .. total .. ")")
	end
end)

-- --------------------------------------------------------------- auto sell
-- Build the sell list exactly like the Bag's sellAllPick: by selected tier, not
-- locked, not equipped, sellPrice > 0; then fire the Bag's own sell remote one
-- item at a time with small delays so it reads like manual selling.
local function sellScan()
	if not hooks() then return {}, 0 end
	local ok, g = pcall(GearState.get)
	if not ok or type(g) ~= "table" or type(g.gear) ~= "table" then return {}, 0 end
	local equipped = {}
	for _, uid in pairs(g.equipped or {}) do equipped[uid] = true end
	local list, gold = {}, 0
	for uid, piece in pairs(g.gear) do
		local def = Equipment.defs[piece.id]
		if def and not piece.locked and not equipped[uid] and (tonumber(def.sellPrice) or 0) > 0 then
			local label = TIER_LABELS[tierOf(def)]
			if e.phSellTiers[label] then
				table.insert(list, uid)
				gold += tonumber(def.sellPrice) or 0
			end
		end
	end
	return list, gold
end

local function sellNow()
	local list = sellScan()
	for _, uid in ipairs(list) do
		if not alive() or not e.phSellOn then break end
		pcall(function() gearRemote:FireServer("sell", uid) end)
		stats.sold += 1
		task.wait(0.15)
	end
	return #list
end

task.spawn(function()
	while alive() do
		if not e.phSellOn then stats.sell = "ปิดอยู่"; task.wait(1); continue end
		if not hooks() then stats.sell = "รอเข้าเกม"; task.wait(2); continue end
		local pending, gold = sellScan()
		if #pending > 0 then
			stats.sell = ("กำลังขาย %d ชิ้น (~%d Gold)"):format(#pending, gold)
			sellNow()
		else
			stats.sell = "ไม่มีของเข้าเงื่อนไข"
		end
		local wait = math.max(tonumber(e.phSellEvery) or 20, 5)
		for _ = 1, wait do if not alive() or not e.phSellOn then break end task.wait(1) end
	end
end)

-- ------------------------------------------------------------- auto collect
-- The game auto-collects loot while its "autoPickup" setting is on, and with no
-- kind filter set it grabs every kind. This just guarantees autoPickup stays on
-- (re-enables it if it ever gets switched off), so nothing is left on the ground.
task.spawn(function()
	while alive() do
		task.wait(3)
		if not e.phCollect then stats.collect = "ปิดอยู่"; continue end
		if not GSettings then stats.collect = "รอเข้าเกม"; continue end
		local on = false
		pcall(function()
			if GSettings.get("autoPickup") ~= true then GSettings.set("autoPickup", true) end
			on = GSettings.get("autoPickup") == true
		end)
		stats.collect = on and "เปิดเก็บของอัตโนมัติ" or "ตั้งค่าไม่ได้"
	end
end)

-- --------------------------------------------------------- auto equip best
-- For each slot, the owned item with the highest (level, tier, refine) that your
-- class can wear. Equip it only when it isn't already the equipped one.
local function equipBest()
	if not hooks() then return end
	local ok, g = pcall(GearState.get)
	if not ok or type(g) ~= "table" or type(g.gear) ~= "table" then return end
	local myClass = plr:GetAttribute("Class")
	local equipped = g.equipped or {}
	local function scoreOf(uid)
		local piece = g.gear[uid]
		local def = piece and Equipment.defs[piece.id]
		if not def then return -1 end
		return (tonumber(def.level) or 0) * 1e6 + (tonumber(def.lines) or 0) * 1e3 + (tonumber(piece.refine) or 0)
	end
	local best = {}
	for uid, piece in pairs(g.gear) do
		local def = Equipment.defs[piece.id]
		if def and (def.class == nil or def.class == myClass) then
			local slot = def.type
			local score = scoreOf(uid)
			if not best[slot] or score > best[slot].score then
				best[slot] = {uid = uid, score = score}
			end
		end
	end
	local did = 0
	for _, slot in ipairs(SLOTS) do
		local b = best[slot]
		-- swap only when the best is STRICTLY better than what's on (equal-score
		-- duplicates, e.g. two identical caps, must not churn the equip remote)
		if b and equipped[slot] ~= b.uid and b.score > scoreOf(equipped[slot]) then
			pcall(function() gearRemote:FireServer("equip", b.uid) end)
			did += 1
			stats.equipped += 1
			task.wait(0.15)
		end
	end
	stats.equip = did > 0 and ("สวมเพิ่ม " .. did .. " ชิ้น") or "ดีสุดแล้ว"
end

task.spawn(function()
	while alive() do
		if not e.phEquip then stats.equip = "ปิดอยู่"; task.wait(1); continue end
		if not hooks() then stats.equip = "รอเข้าเกม"; task.wait(2); continue end
		equipBest()
		local wait = math.max(tonumber(e.phEquipEvery) or 15, 5)
		for _ = 1, wait do if not alive() or not e.phEquip then break end task.wait(1) end
	end
end)

-- ---------------------------------------------------------------------- UI
print("[PetHunt] Loading MacLib...")
local ok, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not ok or not Lib then print("[PetHunt] MacLib failed: " .. tostring(Lib)) return end
task.wait()
if not alive() then return end

local W = Lib:Window({Title = "Pet Hunt Party", Subtitle = "Auto", DragStyle = 1,
	ShowUserInfo = true, AcrylicBlur = false})
getgenv().__PHPW = W
local TG = W:TabGroup()
local Tabs = {
	Farm = TG:Tab({Name = "Auto Farm", Image = "rbxassetid://10723343321"}),
	Boss = TG:Tab({Name = "Auto Boss", Image = "rbxassetid://10723346959"}),
	Sell = TG:Tab({Name = "Auto Sell", Image = "rbxassetid://10709769841"}),
	Gear = TG:Tab({Name = "เก็บ/สวม", Image = "rbxassetid://10723345576"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}

-- Farm tab
local FL = Tabs.Farm:Section({Side = "Left"})
FL:Header({Text = "Auto Farm" })
FL:Toggle({Name = "เปิด Auto Farm (เดินหามอนเลเวลสูงสุดในฟิลด์)", Default = e.phFarm,
	Callback = function(v) e.phFarm = v; sv() end}, "PHFarm")
FL:Toggle({Name = "ตีบอสฟิลด์ด้วย (ปลดล็อกฟิลด์ถัดไป)", Default = e.phFarmBoss,
	Callback = function(v) e.phFarmBoss = v; sv() end}, "PHFarmBoss")
FL:Label({Text = "เดินไปหามอนในช่วงเลเวลที่เลือก (เทียบกับเลเวลเรา)"})
FL:Slider({Name = "ฟาร์มมอนต่ำกว่าเวลฉันได้ถึง (เลเวล)", Minimum = 0, Maximum = 99, Default = e.phFarmBelow,
	Precision = 0, DisplayMethod = "Round", Suffix = " lv",
	Callback = function(v) e.phFarmBelow = math.floor(v + 0.5); sv() end}, "PHFarmBelow")
FL:Slider({Name = "ฟาร์มมอนสูงกว่าเวลฉันได้ถึง (เลเวล)", Minimum = 0, Maximum = 30, Default = e.phFarmAbove,
	Precision = 0, DisplayMethod = "Round", Suffix = " lv",
	Callback = function(v) e.phFarmAbove = math.floor(v + 0.5); sv() end}, "PHFarmAbove")
FL:Label({Text = "เช่น อยากฟาร์มมอนต่ำกว่าเราไม่เกิน 2 → ตั้ง 'ต่ำกว่า'=2\nไม่มีมอนในช่วง = ไม่ฟาร์ม (ย้ายฟิลด์/ปรับช่วงเอา)"})

FL:Header({Text = "Auto Open Chest"})
FL:Toggle({Name = "เปิด Auto Open Chest (เปิดกล่องปาร์ตี้ทันที)", Default = e.phChest,
	Callback = function(v) e.phChest = v; sv() end}, "PHChest")
FL:Label({Text = "เปิดกล่องปาร์ตี้ที่ตกตอนฟาร์มให้ทันทีเมื่ออยู่ในระยะ"})

local FR = Tabs.Farm:Section({Side = "Right"})
FR:Header({Text = "สถานะ"})
local farmLbl = FR:Label({Text = "-"})
local chestLbl = FR:Label({Text = "-"})

-- Boss tab: field bosses
local BL = Tabs.Boss:Section({Side = "Left"})
BL:Header({Text = "Auto Field Boss"})
BL:Toggle({Name = "เปิด Auto Field Boss (ไปตีบอสฟิลด์ที่เลือก)", Default = e.phBossOn,
	Callback = function(v) e.phBossOn = v; sv() end}, "PHBossOn")
local bossOpts, bossDefault = {}, {}
for _, b in ipairs(FIELD_BOSSES) do table.insert(bossOpts, b.label) end
if type(e.phBossPick) == "table" then for lbl, on in pairs(e.phBossPick) do if on then table.insert(bossDefault, lbl) end end end
BL:Dropdown({Name = "บอสฟิลด์ที่จะตี", Multi = true, Required = false,
	Options = bossOpts, Default = bossDefault,
	Callback = function(v)
		local sel = {}
		if type(v) == "table" then
			for k, on in pairs(v) do if on == true then sel[k] = true elseif type(k) == "number" then sel[on] = true end end
		end
		e.phBossPick = sel; sv()
	end}, "PHBossPick")
local farmPosLbl
local function farmPosText()
	local fp = e.phFarmPos
	if type(fp) ~= "table" or not fp.x then return "จุดฟาร์ม: ยังไม่ได้ตั้ง" end
	return ("จุดฟาร์ม: %.0f, %.0f, %.0f"):format(fp.x, fp.y, fp.z)
end
BL:Button({Name = "ตั้งจุดฟาร์ม (ตำแหน่งตอนนี้)",
	Callback = function()
		local _, _, hrp = myChar()
		if not hrp then return end
		local p = hrp.Position
		e.phFarmPos = {x = p.X, y = p.Y, z = p.Z}; sv()
		pcall(function() farmPosLbl:UpdateName(farmPosText()) end)
	end})
farmPosLbl = BL:Label({Text = farmPosText()})
BL:Label({Text = "เลือกบอส → บอสเกิดในฟิลด์ที่อยู่ จะไปตี พอตีเสร็จกลับจุดฟาร์ม\nตีได้เฉพาะบอสในฟิลด์เดียวกับจุดฟาร์ม (ข้ามฟิลด์ยังไม่รองรับ)"})

BL:Header({Text = "Auto World Boss"})
BL:Toggle({Name = "เปิด Auto World Boss (บอสโลก ทุก ~30 นาที)", Default = e.phWBOn,
	Callback = function(v) e.phWBOn = v; sv() end}, "PHWBOn")
local wbOpts, wbDefault = {}, {}
for _, b in ipairs(WORLD_BOSSES) do table.insert(wbOpts, b.label) end
if type(e.phWBPick) == "table" then for lbl, on in pairs(e.phWBPick) do if on then table.insert(wbDefault, lbl) end end end
BL:Dropdown({Name = "เลือกตามชื่อบอสโลก (ว่าง=ทุกตัว)", Multi = true, Required = false,
	Options = wbOpts, Default = wbDefault,
	Callback = function(v)
		local sel = {}
		if type(v) == "table" then
			for k, on in pairs(v) do if on == true then sel[k] = true elseif type(k) == "number" then sel[on] = true end end
		end
		e.phWBPick = sel; sv()
	end}, "PHWBPick")
-- World bosses only spawn in the Volcano biome (the game's summon is volcano-only
-- and the one observed spawned there), so the map picker lists only real spawn
-- biomes, not all 12 fields.
local WB_SPAWN_FIELDS = {volcano = true}
local fieldOpts, fieldDefault = {}, {}
for _, f in ipairs(FIELDS) do if WB_SPAWN_FIELDS[f.id] then table.insert(fieldOpts, f.label) end end
if type(e.phWBFields) == "table" then for lbl, on in pairs(e.phWBFields) do if on then table.insert(fieldDefault, lbl) end end end
BL:Dropdown({Name = "เลือกตามแมพที่บอสโลกเกิด (ว่าง=ทุกจุด)", Multi = true, Required = false,
	Options = fieldOpts, Default = fieldDefault,
	Callback = function(v)
		local sel = {}
		if type(v) == "table" then
			for k, on in pairs(v) do if on == true then sel[k] = true elseif type(k) == "number" then sel[on] = true end end
		end
		e.phWBFields = sel; sv()
	end}, "PHWBFields")
BL:Label({Text = "เลือกได้ 2 แบบ: ตามชื่อบอส หรือตามแมพที่เกิด (เช่น เฉพาะ\nMoon Base) · เลือกทั้งคู่ = ต้องตรงทั้งชื่อและแมพ · ว่าง=ไม่กรอง"})

local BR = Tabs.Boss:Section({Side = "Right"})
BR:Header({Text = "สถานะบอสฟิลด์"})
local bossLbl = BR:Label({Text = "-"})

-- Sell tab
local SLs = Tabs.Sell:Section({Side = "Left"})
SLs:Header({Text = "Auto Sell"})
SLs:Toggle({Name = "เปิด Auto Sell", Default = e.phSellOn,
	Callback = function(v) e.phSellOn = v; sv() end}, "PHSellOn")
local tierOpts = {}
for _, t in ipairs(TIER_ORDER) do table.insert(tierOpts, TIER_LABELS[t]) end
local tierDefault = {}
for lbl, on in pairs(e.phSellTiers) do if on then table.insert(tierDefault, lbl) end end
SLs:Dropdown({Name = "ขั้นของที่จะขาย", Multi = true, Required = false,
	Options = tierOpts, Default = tierDefault,
	Callback = function(v)
		local sel = {}
		if type(v) == "table" then
			for k, on in pairs(v) do if on == true then sel[k] = true elseif type(k) == "number" then sel[on] = true end end
		end
		e.phSellTiers = sel; sv()
	end}, "PHSellTiers")
SLs:Label({Text = "ไม่ขายเด็ดขาด: ของที่ lock, ที่ใส่อยู่, ของราคา 0\n(ใช้คำสั่งขายปกติของเกม ไม่ต้องมี Auto Sell Pass)"})
local SRs = Tabs.Sell:Section({Side = "Right"})
SRs:Header({Text = "สถานะ"})
local sellLbl = SRs:Label({Text = "-"})

-- Gear tab: collect + equip
local GLs = Tabs.Gear:Section({Side = "Left"})
GLs:Header({Text = "Auto Collect"})
GLs:Toggle({Name = "เปิด Auto Collect (เก็บของอัตโนมัติ)", Default = e.phCollect,
	Callback = function(v) e.phCollect = v; sv() end}, "PHCollect")
GLs:Label({Text = "บังคับเปิด auto pickup ของเกม (เก็บทุกชนิด: gold,\nโพชั่น, วัตถุดิบ, ของ, การ์ด) เปิดกลับถ้ามันถูกปิด"})
GLs:Header({Text = "Auto Equip Best"})
GLs:Toggle({Name = "เปิด Auto Equip Best (สวมของดีสุด)", Default = e.phEquip,
	Callback = function(v) e.phEquip = v; sv() end}, "PHEquip")
GLs:Label({Text = "สวมของแรงสุดที่คลาสใส่ได้ ทุกช่อง\n(เรียงตาม เลเวล > ขั้น > ตีบวก)"})
local GRs = Tabs.Gear:Section({Side = "Right"})
GRs:Header({Text = "สถานะ"})
local collectLbl = GRs:Label({Text = "-"})
local equipLbl = GRs:Label({Text = "-"})

-- Settings tab
local STs = Tabs.Settings:Section({Side = "Left"})
STs:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() W:SetState(not W:GetState()) end) end}, "PHToggleUIKeybind")
STs:Label({Text = "กด RightShift เพื่อซ่อน/แสดงหน้าต่าง\nตั้งค่าเซฟที่: " .. SF})
STs:Header({Text = "General"})
STs:Toggle({Name = "Auto Reconnect (เน็ตหลุด/เซิร์ฟมีปัญหา → เข้าใหม่)", Default = e.phReconnect,
	Callback = function(v) e.phReconnect = v; sv() end}, "PHReconnect")
STs:Label({Text = "กำลังจะมา: Auto World Boss (บอสโลกทุก 30 นาที)"})

task.spawn(function()
	while alive() do
		pcall(function() farmLbl:UpdateName("ฟาร์ม: " .. stats.farm) end)
		pcall(function() chestLbl:UpdateName("กล่อง: " .. stats.chest) end)
		pcall(function()
			-- index live boss monsters by id (field + world)
			local live = {}
			for _, m in ipairs(workspace.Monsters:GetChildren()) do
				if (m:GetAttribute("IsBoss") or m:GetAttribute("WorldBoss")) and (tonumber(m:GetAttribute("Health")) or 0) > 0 then
					live[m:GetAttribute("MonsterId")] = m
				end
			end
			-- track deaths to estimate field-boss respawn (no server timer is exposed)
			local now = os.time()
			for _, b in ipairs(FIELD_BOSSES) do
				local isUp = live[b.bossId] ~= nil
				if bossWasUp[b.bossId] and not isUp then bossDeadAt[b.bossId] = now end
				bossWasUp[b.bossId] = isUp
			end
			-- field boss lines
			local lines = {"= บอสฟิลด์ ="}
			for _, b in ipairs(FIELD_BOSSES) do
				local m = live[b.bossId]
				local st
				if m then
					st = ("เกิดอยู่ %d%%"):format(math.floor((tonumber(m:GetAttribute("Health")) or 0) / math.max(tonumber(m:GetAttribute("MaxHealth")) or 1, 1) * 100))
				elseif bossDeadAt[b.bossId] then
					local left = (bossDeadAt[b.bossId] + (b.respawn or 600)) - now
					st = left > 0 and ("เกิดใน %d:%02d"):format(math.floor(left / 60), left % 60) or "ใกล้เกิด"
				else
					st = "-"
				end
				local mark = (type(e.phBossPick) == "table" and e.phBossPick[b.label]) and "✔ " or "· "
				lines[#lines + 1] = ("%s%s Lv%d: %s"):format(mark, b.name, b.lv, st)
			end
			-- world boss lines
			lines[#lines + 1] = "= บอสโลก ="
			local wbUp = {}
			for _, m in ipairs(workspace.Monsters:GetChildren()) do
				if m:GetAttribute("WorldBoss") and (tonumber(m:GetAttribute("Health")) or 0) > 0 then
					local center = m:GetAttribute("ArenaCenter")
					local f = fieldAt((typeof(center) == "Vector3") and center or m.PrimaryPart and m.PrimaryPart.Position)
					wbUp[#wbUp + 1] = ("%s Lv%s (%s)"):format(m.Name, tostring(m:GetAttribute("Level") or "?"), f and (FIELD_NAME[f.id] or f.id) or "?")
				end
			end
			lines[#lines + 1] = #wbUp > 0 and ("เกิดอยู่: " .. table.concat(wbUp, ", ")) or "ยังไม่เกิด (เกิดทุก ~30 นาที)"
			bossLbl:UpdateName(table.concat(lines, "\n"))
		end)
		pcall(function()
			local pending, gold = sellScan()
			sellLbl:UpdateName(("%s\nขายไปแล้ว: %d ชิ้น\nตอนนี้เข้าเงื่อนไข: %d ชิ้น (~%d Gold)")
				:format(stats.sell, stats.sold, #pending, gold))
		end)
		pcall(function() collectLbl:UpdateName("เก็บของ: " .. stats.collect) end)
		pcall(function() equipLbl:UpdateName(("สวมของ: %s\nสวมไปแล้วรวม %d ชิ้น"):format(stats.equip, stats.equipped)) end)
		task.wait(0.5)
	end
end)

W.onUnloaded(function()
	if getgenv().__PHP == G then getgenv().__PHP = G + 1 end
	print("[PetHunt] Unloaded")
end)
Tabs.Farm:Select()
print("[PetHunt] UI ready")
