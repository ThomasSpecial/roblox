-- [DRAGON] Poly Loot (placeId 124032631078772) -- mob / boss auto farm: target lock, orbit / behind / hit & run,
-- telegraph dodge, auto attack, auto skill, low-HP retreat. Move mode Walk / Tween / Teleport.
-- MacLib window, RightShift toggles it, settings persist (PolyLoot/state_<userId>.json).
--
-- How the game works (verified 2026-11-25 on Chekkadeiz / FrostV):
--   Mobs: workspace.Animal_Live.{Aggressors, Passives}; models named by GUID, attributes Animal, Tier
--     (Tiny/Small/Med/Large/Boss), Health, MaxHealth, Damage, AttackType. Model pivot = where it stands.
--   Attack: Weapon_Engine.Remotes.WeaponAttack:FireServer(step 1..3) per swing, FireServer(0) when the combo ends.
--     The server does the hitbox from the character's position/facing -> stand close and face the target.
--   Skills: Ability_Engine.Remotes.AbilityFired:FireServer(seq, name, targetPos); the server only accepts equipped
--     skills (player attributes AbilitySlot1..3) off cooldown; AbilityCastResult(seq, name, ok, reason, cd) answers.
--   Loot is granted on kill (the drops on the floor are visual only) -> nothing to pick up.
--   Mob attacks show "AttackBoxTelegraph" parts (CollectionService tag) before they land -> leave the box.
--   Anti-cheat: Movement_Client.MovementPathReporter streams the root position to the server every 0.2 s.
--     Short hops (< ~45 studs) passed; tweening 28-45 studs/s through town was snapped back 110-160 studs and
--     then reset to spawn; 60 studs/s killed the character. Walk (Humanoid:MoveTo + Pathfinding) is the default.

getgenv().__PLOOT = (getgenv().__PLOOT or 0) + 1
local G = getgenv().__PLOOT
pcall(function() if getgenv().__PLOOTW then getgenv().__PLOOTW:Unload() end end)
local function alive() return getgenv().__PLOOT == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local CS = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local PFS = game:GetService("PathfindingService")
local plr = Players.LocalPlayer

local ATTACK_GAME = "ท่าฟันของเกม (Tool:Activate)"
local ATTACK_REMOTE = "ยิง remote ตรง (ไม่มีท่า)"
local WeaponAttack = RS:WaitForChild("Weapon_Engine"):WaitForChild("Remotes"):WaitForChild("WeaponAttack")
local AbilityRemotes = RS:WaitForChild("Ability_Engine"):WaitForChild("Remotes")
local AbilityFired = AbilityRemotes:WaitForChild("AbilityFired")
local AbilityCastResult = AbilityRemotes:WaitForChild("AbilityCastResult")
local AnimalLive = workspace:WaitForChild("Animal_Live")

-- ------------------------------------------------------------------ settings
local SF = ("PolyLoot/state_%d.json"):format(plr.UserId)
local DEFAULTS = {
	farm = false, mobs = {}, bossOnly = false, passives = false, radius = 400,
	targetMode = "ใกล้สุด", pattern = "วนรอบตัว (Orbit)", moveMode = "Walk",
	tweenSpeed = 22, tpMax = 40, standDist = 5, orbitRadius = 7, orbitSpeed = 1.6,
	attack = true, swing = 0.55, attackMode = "ท่าฟันของเกม (Tool:Activate)", reach = 11, dodge = true, dodgeMargin = 3,
	skill = true, skillMode = "ใช้ทันทีที่คูลดาวน์หมด", healAt = 60,
	retreat = true, retreatAt = 35, resumeAt = 80, antiAfk = true, equip = true,
	loot = true, lootAlways = false, lootRadius = 80,
	sell = false, sellRar = {}, dismantle = false, disRar = {}, invEvery = 20,
}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
if type(e.mobs) ~= "table" then e.mobs = {} end
if type(e.sellRar) ~= "table" then e.sellRar = {} end
if type(e.disRar) ~= "table" then e.disRar = {} end
local function sv()
	pcall(function()
		if makefolder and not isfolder("PolyLoot") then makefolder("PolyLoot") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

local st = {status = "ปิดอยู่", target = nil, kills = 0, skills = 0, dodges = 0, snaps = 0, loots = 0, last = {}, weapon = nil}
local function log(s)
	table.insert(st.last, 1, os.date("%H:%M:%S") .. " " .. s)
	while #st.last > 8 do table.remove(st.last) end
end

-- ------------------------------------------------------------------ character
local function char()
	local c = plr.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if hrp and hum and hum.Health > 0 then return c, hrp, hum end
end
local function hpPct()
	local _, _, hum = char()
	return hum and hum.MaxHealth > 0 and hum.Health / hum.MaxHealth * 100 or 0
end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end

-- keep the weapon in hand (the server swings whatever tool is equipped)
local function ensureWeapon()
	local c, _, hum = char()
	if not c then return false end
	local held = c:FindFirstChildOfClass("Tool")
	if held then st.weapon = held.Name return true end
	if not e.equip then return false end
	local bp = plr:FindFirstChildOfClass("Backpack")
	local tool = bp and st.weapon and bp:FindFirstChild(st.weapon)
	if tool and tool:IsA("Tool") then pcall(function() hum:EquipTool(tool) end) task.wait(0.3) end
	return c:FindFirstChildOfClass("Tool") ~= nil
end

-- ------------------------------------------------------------------ mobs
local function mobAlive(m)
	return m and m.Parent and (tonumber(m:GetAttribute("Health")) or 0) > 0
end
local function mobPos(m) return m:GetPivot().Position end
local function mobKinds()
	local seen, list = {}, {}
	for _, f in ipairs({"Aggressors", "Passives"}) do
		local folder = AnimalLive:FindFirstChild(f)
		if folder then
			for _, m in ipairs(folder:GetChildren()) do
				local a = m:GetAttribute("Animal")
				if a and not seen[a] then seen[a] = true; list[#list + 1] = a end
			end
		end
	end
	for a in pairs(e.mobs) do if not seen[a] then list[#list + 1] = a end end
	table.sort(list)
	return list
end
local function wanted(m)
	if not mobAlive(m) then return false end
	if e.bossOnly and m:GetAttribute("Tier") ~= "Boss" then return false end
	local any = next(e.mobs) ~= nil
	if any and not e.mobs[m:GetAttribute("Animal") or ""] then return false end
	return true
end
local function pickTarget(hrp)
	local best, bestScore
	local folders = {AnimalLive:FindFirstChild("Aggressors")}
	if e.passives then folders[#folders + 1] = AnimalLive:FindFirstChild("Passives") end
	for _, folder in ipairs(folders) do
		for _, m in ipairs(folder and folder:GetChildren() or {}) do
			if wanted(m) then
				local d = (mobPos(m) - hrp.Position).Magnitude
				if d <= e.radius then
					local hp = tonumber(m:GetAttribute("Health")) or 0
					local score = (e.targetMode == "เลือดน้อยสุด" and hp) or (e.targetMode == "เลือดมากสุด" and -hp) or d
					if not bestScore or score < bestScore then best, bestScore = m, score end
				end
			end
		end
	end
	return best
end

-- ------------------------------------------------------------------ movement
local mover = {goal = nil, mode = nil}   -- tween/teleport goals are applied on Heartbeat; walk uses MoveTo
local path = {goal = nil, wps = nil, i = 0, at = 0}
local lastPosSkip = false   -- our own unstuck hop: don't count it as a server snap-back

-- stuck watch: progress is sampled every 0.8 s while walking
local stuck = {at = 0, pos = nil, n = 0}
local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
local function blocked(c, from, to)
	wallParams.FilterDescendantsInstances = {c, AnimalLive}
	local dir = flat(to - from)
	if dir.Magnitude < 1 then return false end
	return workspace:Raycast(from, dir, wallParams) ~= nil
end
local function computePath(hrp, goal)
	path.goal, path.at, path.wps, path.i = goal, os.clock(), nil, 2
	for _, cfg in ipairs({
		{AgentRadius = 2, AgentHeight = 5.5, AgentCanJump = true, AgentCanClimb = true, WaypointSpacing = 4},
		{AgentRadius = 1, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = true, WaypointSpacing = 3},
	}) do
		local p = PFS:CreatePath(cfg)
		local ok = pcall(function() p:ComputeAsync(hrp.Position, goal) end)
		if ok and p.Status == Enum.PathStatus.Success then path.wps = p:GetWaypoints() return true end
	end
	return false
end
local function walkTo(hrp, hum, goal)
	local c = hrp.Parent
	-- straight line when nothing is in the way, else Pathfinding (recomputed only when the goal moves or we get stuck)
	local direct = flat(goal - hrp.Position).Magnitude < 30 and not blocked(c, hrp.Position, goal)
	if direct then
		path.wps = nil
	elseif not path.wps or (path.goal - goal).Magnitude > 8 then
		computePath(hrp, goal)
	end
	local target = goal
	if not direct and path.wps then
		local w = path.wps[path.i]
		while w and flat(w.Position - hrp.Position).Magnitude < 2.5 do
			path.i += 1
			w = path.wps[path.i]
		end
		if w then
			if w.Action == Enum.PathWaypointAction.Jump or w.Position.Y > hrp.Position.Y + 1.5 then hum.Jump = true end
			target = w.Position
		else
			path.wps = nil
		end
	end
	hum:MoveTo(target)

	-- unstuck: jump -> new path -> short hop (hops under ~10 studs pass the server's position check)
	local now = os.clock()
	if not stuck.pos or now - stuck.at > 0.8 then
		if stuck.pos and flat(hrp.Position - stuck.pos).Magnitude < 1.2 and flat(target - hrp.Position).Magnitude > 2 then
			stuck.n += 1
			st.stuck = (st.stuck or 0) + 1
			hum.Jump = true
			if stuck.n == 2 or stuck.n == 4 then computePath(hrp, goal) end
			if stuck.n >= 3 then
				local dir = flat(target - hrp.Position)
				dir = dir.Magnitude > 0.1 and dir.Unit or hrp.CFrame.LookVector
				local hop = hrp.Position + dir * math.min(6, flat(target - hrp.Position).Magnitude) + Vector3.new(0, 3, 0)
				hrp.CFrame = CFrame.new(hop) * (hrp.CFrame - hrp.Position)
				lastPosSkip = true
			end
			if stuck.n >= 6 then stuck.n = 0 end
		else
			stuck.n = 0
		end
		stuck.pos, stuck.at = hrp.Position, now
	end
end

-- one call per tick: send the character toward goal with the selected mode
local function moveTo(goal)
	local _, hrp, hum = char()
	if not hrp then return end
	if e.moveMode == "Walk" then
		mover.goal = nil
		walkTo(hrp, hum, goal)
	elseif e.moveMode == "Teleport" and (goal - hrp.Position).Magnitude <= e.tpMax then
		mover.goal, mover.mode = goal, "tp"
	else
		-- Tween, or Teleport beyond tpMax (glides at the tween speed instead of one long jump)
		mover.goal, mover.mode = goal, "tween"
	end
end
local function stopMove()
	mover.goal = nil
	path.wps = nil
	local _, hrp, hum = char()
	if hum and hrp then hum:MoveTo(hrp.Position) end
end

local lookAt = nil   -- position the character keeps facing while farming
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
local lastPos
local hbConn = RunService.Heartbeat:Connect(function(dt)
	if not alive() then return end
	local c, hrp, hum = char()
	if not hrp then lastPos = nil return end
	-- snap-back counter (the server pulled us somewhere we did not go)
	if lastPos and (hrp.Position - lastPos).Magnitude > 20 and not (mover.goal and mover.mode == "tp") and not lastPosSkip then
		st.snaps += 1
	end
	lastPosSkip = false
	if mover.goal then
		local goal = mover.goal
		if mover.mode == "tp" then
			hrp.CFrame = CFrame.new(goal) * (hrp.CFrame - hrp.Position)
			hrp.AssemblyLinearVelocity = Vector3.zero
			mover.goal = nil
		else
			local delta = goal - hrp.Position
			if flat(delta).Magnitude < 1 then
				mover.goal = nil
			else
				local stepLen = math.min(flat(delta).Magnitude, e.tweenSpeed * dt)
				local np = hrp.Position + flat(delta).Unit * stepLen
				-- stay on the ground so the reported path looks like running, not flying
				rp.FilterDescendantsInstances = {c, AnimalLive}
				local hit = workspace:Raycast(np + Vector3.new(0, 6, 0), Vector3.new(0, -30, 0), rp)
				local y = hit and (hit.Position.Y + hum.HipHeight + hrp.Size.Y / 2) or np.Y + math.clamp(delta.Y, -stepLen, stepLen)
				hrp.CFrame = CFrame.new(Vector3.new(np.X, y, np.Z)) * (hrp.CFrame - hrp.Position)
				hrp.AssemblyLinearVelocity = flat(delta).Unit * e.tweenSpeed
			end
		end
	end
	lastPos = hrp.Position
end)

-- ------------------------------------------------------------------ dodge
-- returns a safe point outside the first telegraph box the character stands in, or nil
local function dodgePoint(hrp)
	for _, p in ipairs(CS:GetTagged("AttackBoxTelegraph")) do
		if p:IsA("BasePart") and p.Parent then
			local lp = p.CFrame:PointToObjectSpace(hrp.Position)
			local hx, hz = p.Size.X / 2 + e.dodgeMargin, p.Size.Z / 2 + e.dodgeMargin
			if math.abs(lp.X) < hx and math.abs(lp.Z) < hz and math.abs(lp.Y) < p.Size.Y / 2 + 8 then
				-- leave through the nearest side
				local outs = {
					{hx - lp.X, Vector3.new(hx + 2, lp.Y, lp.Z)},
					{hx + lp.X, Vector3.new(-hx - 2, lp.Y, lp.Z)},
					{hz - lp.Z, Vector3.new(lp.X, lp.Y, hz + 2)},
					{hz + lp.Z, Vector3.new(lp.X, lp.Y, -hz - 2)},
				}
				table.sort(outs, function(a, b) return a[1] < b[1] end)
				local w = p.CFrame:PointToWorldSpace(outs[1][2])
				return Vector3.new(w.X, hrp.Position.Y, w.Z)
			end
		end
	end
end

-- ------------------------------------------------------------------ skills
local skillCd = {}   -- name -> os.clock() when ready
local seq = math.random(100000, 900000)
AbilityCastResult.OnClientEvent:Connect(function(_, name, ok, reason, cd)
	if type(name) ~= "string" then return end
	local left = tonumber(cd) or 0
	skillCd[name] = os.clock() + math.max(left, ok and 1 or 2)
	if ok then st.skills += 1; log("ใช้สกิล " .. name) end
end)
local function equippedSkills()
	local list = {}
	for i = 1, 3 do
		local s = plr:GetAttribute("AbilitySlot" .. i)
		if type(s) == "string" and s ~= "" then list[#list + 1] = s end
	end
	return list
end
local HEALS = {AreaHeal = true, QuickHeal = true}
local function useSkills(targetPos)
	if not e.skill then return end
	local _, hrp = char()
	if not hrp then return end
	for _, name in ipairs(equippedSkills()) do
		if os.clock() >= (skillCd[name] or 0) then
			local isHeal = HEALS[name]
			local go = e.skillMode == "ใช้ทันทีที่คูลดาวน์หมด" or (isHeal and hpPct() <= e.healAt) or (not isHeal and targetPos)
			if isHeal and e.skillMode ~= "ใช้ทันทีที่คูลดาวน์หมด" and hpPct() > e.healAt then go = false end
			if go then
				seq = seq % 2147483647 + 1
				skillCd[name] = os.clock() + 2   -- until the server answers
				pcall(function() AbilityFired:FireServer(seq, name, isHeal and hrp.Position or (targetPos or hrp.Position)) end)
			end
		end
	end
end

-- ------------------------------------------------------------------ loot
-- item drops (weapons / armor / bones / food) are workspace.WorldBits.<id>.<part>.ProximityPrompt "Pick Up";
-- XP and coins are granted on kill and only fly to you visually
local lootTried = {}   -- prompt -> {n, at}
local function nextDrop(hrp)
	local wb = workspace:FindFirstChild("WorldBits")
	if not wb then return end
	local best, bd
	for _, d in ipairs(wb:GetChildren()) do
		local pr = d:FindFirstChildWhichIsA("ProximityPrompt", true)
		-- the game keeps these prompts Enabled = false (DropPromptLock) but firing them still picks up;
		-- wbFast lists the user ids the drop belongs to
		local owners = d:GetAttribute("wbFast")
		local mine = type(owners) ~= "string" or owners == "" or owners:find("," .. plr.UserId .. ",", 1, true) ~= nil
		if pr and mine and pr.ActionText == "Pick Up" then
			local t = lootTried[pr]
			if not (t and (t.n >= 6 or os.clock() - t.at < 1.5)) then
				local part = pr.Parent
				local pos = part:IsA("BasePart") and part.Position or (part:IsA("Attachment") and part.WorldPosition)
				if pos then
					local dist = (pos - hrp.Position).Magnitude
					if dist <= e.lootRadius and (not bd or dist < bd) then best, bd = {pr = pr, pos = pos}, dist end
				end
			end
		end
	end
	return best, bd
end
-- one step of looting; returns true while busy with a drop
local function lootStep(hrp)
	if not e.loot then return false end
	local drop, dist = nextDrop(hrp)
	if not drop then return false end
	local reach = math.max(drop.pr.MaxActivationDistance - 2, 3)
	if dist > reach then
		moveTo(drop.pos)
		st.status = ("ไปเก็บ %s · %.0f stud"):format(drop.pr.ObjectText, dist)
		return true
	end
	local t = lootTried[drop.pr] or {n = 0, at = 0}
	t.n += 1
	t.at = os.clock()
	lootTried[drop.pr] = t
	pcall(function()
		drop.pr.HoldDuration = 0
		if fireproximityprompt then fireproximityprompt(drop.pr) else drop.pr:InputHoldBegin(); task.wait(); drop.pr:InputHoldEnd() end
	end)
	if t.n == 1 then st.loots += 1; log("เก็บ " .. drop.pr.ObjectText) end
	st.status = "เก็บของ " .. drop.pr.ObjectText
	return true
end

-- ------------------------------------------------------------------ farm loop
local combo, swingAt, swinging = 0, 0, false
local function endCombo()
	-- the game's weapon client closes its own combo; only the raw-remote mode has to send 0
	if swinging and e.attackMode ~= ATTACK_GAME then pcall(function() WeaponAttack:FireServer(0) end) end
	swinging, combo = false, 0
end
-- turn toward the target only when we're clearly off (rotating every frame froze the walk animation)
local function face(hrp, pos)
	local dir = flat(pos - hrp.Position)
	if dir.Magnitude < 0.5 then return end
	if hrp.CFrame.LookVector:Dot(dir.Unit) < 0.94 then
		hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + dir)
	end
end
local orbitAng = 0
local retreating = false
local lockStart = 0

task.spawn(function()
	while alive() do
		local dt = 0.1
		local ok, err = pcall(function()
			if not e.farm then
				if st.target then st.target = nil; lookAt = nil; endCombo(); stopMove() end
				local _, hrp, hum = char()
				if hum and not hum.AutoRotate then hum.AutoRotate = true end
				st.status = "ปิดอยู่"
				if hrp and e.lootAlways then lootStep(hrp) end
				return
			end
			local c, hrp, hum = char()
			if not c then st.status = "รอตัวละครเกิด"; st.target = nil; endCombo() return end

			-- target: keep the locked one until it dies / leaves range (lock mode never switches early)
			local t = st.target
			if t and not mobAlive(t) then
				st.kills += 1
				log(("ฆ่า %s (รวม %d)"):format(tostring(t:GetAttribute("Animal")), st.kills))
				t = nil
			end
			if t and e.targetMode ~= "ล็อกตัวเดิมจนตาย" and (mobPos(t) - hrp.Position).Magnitude > e.radius + 50 then t = nil end
			if t and e.targetMode ~= "ล็อกตัวเดิมจนตาย" and not wanted(t) then t = nil end
			if not t then
				t = pickTarget(hrp)
				if t then lockStart = os.clock(); log(("ล็อก %s/%s HP %s"):format(tostring(t:GetAttribute("Animal")), tostring(t:GetAttribute("Tier")), tostring(t:GetAttribute("Health")))) end
			end
			st.target = t
			if not t then
				endCombo(); lookAt = nil
				st.status = ("ไม่มีมอนที่เลือกในระยะ %d"):format(e.radius)
				return
			end
			local tp = mobPos(t)
			local dist = flat(tp - hrp.Position).Magnitude

			-- low HP: back off and let AreaHeal / regen work
			if e.retreat then
				if hpPct() <= e.retreatAt then retreating = true end
				if retreating and hpPct() >= e.resumeAt then retreating = false end
			else
				retreating = false
			end
			useSkills(tp)
			if retreating then
				endCombo(); lookAt = nil
				local away = flat(hrp.Position - tp)
				away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
				moveTo(tp + away * 45)
				st.status = ("ถอยเลือดต่ำ %d%% → รอ %d%%"):format(hpPct(), e.resumeAt)
				return
			end

			-- dodge first, then pick up drops, then fight
			local dp = e.dodge and dodgePoint(hrp)
			if not dp and lootStep(hrp) then
				endCombo(); lookAt = nil
				return
			end
			if dp then
				st.dodges += 1
				moveTo(dp)
				lookAt = tp
				st.status = "หลบท่า"
			elseif dist > math.max(e.standDist, e.orbitRadius) + 8 then
				endCombo(); lookAt = nil
				moveTo(Vector3.new(tp.X, hrp.Position.Y, tp.Z))
				st.status = ("เดินทางไปหา %s · %.0f stud (%s)"):format(tostring(t:GetAttribute("Animal")), dist, e.moveMode)
				return
			else
				lookAt = tp
				local pattern = e.pattern
				if pattern == "วนรอบตัว (Orbit)" then
					local cur = math.atan2(hrp.Position.Z - tp.Z, hrp.Position.X - tp.X)
					orbitAng = cur + e.orbitSpeed * 0.6
					local goal = tp + Vector3.new(math.cos(orbitAng), 0, math.sin(orbitAng)) * e.orbitRadius
					moveTo(Vector3.new(goal.X, hrp.Position.Y, goal.Z))
				elseif pattern == "ตีแล้วถอย (Hit & Run)" then
					local phase = (os.clock() - lockStart) % 3
					local away = flat(hrp.Position - tp)
					away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
					local r = phase < 2 and e.standDist or e.standDist + 10
					moveTo(tp + away * r)
				else -- ยืนหลังมอน (Behind)
					local look = t:GetPivot().LookVector
					local goal = tp - flat(look).Unit * e.standDist
					if flat(goal - hrp.Position).Magnitude > 1.5 then moveTo(Vector3.new(goal.X, hrp.Position.Y, goal.Z)) end
				end
				st.status = ("ตี %s/%s · HP %s/%s · ระยะ %.0f"):format(tostring(t:GetAttribute("Animal")), tostring(t:GetAttribute("Tier")),
					tostring(t:GetAttribute("Health")), tostring(t:GetAttribute("MaxHealth")), dist)
			end

			-- attack when in reach (the hitbox is the server's; reach ~ stand distance + a few studs)
			if e.attack and dist <= e.reach and ensureWeapon() then
				face(hrp, tp)
				if e.attackMode == ATTACK_GAME then
					-- Tool:Activate() runs the game's own swing: animation, combo 1-2-3 and its timing
					local tool = c:FindFirstChildOfClass("Tool")
					if tool then pcall(function() tool:Activate() end) end
					swinging = true
				elseif os.clock() >= swingAt then
					combo = combo % 3 + 1
					swinging = true
					swingAt = os.clock() + e.swing
					pcall(function() WeaponAttack:FireServer(combo) end)
				end
			elseif swinging and os.clock() >= swingAt then
				endCombo()
			end
		end)
		if not ok then st.status = "error: " .. tostring(err) end
		task.wait(dt)
	end
	endCombo()
	mover.goal = nil
	pcall(function() local _, _, hum = char(); if hum then hum.AutoRotate = true end end)
end)

-- ------------------------------------------------------------------ auto sell / dismantle by rarity
-- Inventory lives in PlayerData.Data.Inventory.{Weapons, Armors}[serial] = {Id, Count, Locked, Favorited, Source};
-- rarity = ItemRegistry[Id].Rarity. SellRequest:FireServer({[serial] = count}); DismantleRequest:FireServer({serials})
-- (one rarity per batch, max 50 -- the game's own dismantle deck refuses mixed rarities).
local RARITIES = {"Common", "Rare", "Epic", "Legendary", "Godly", "Secret", "Unknown"}
local ItemRegistry, PlayerDataMod
pcall(function() ItemRegistry = require(RS.Inventory_Engine.Modules.ItemRegistry) end)
pcall(function() PlayerDataMod = require(plr.PlayerScripts:WaitForChild("Data_Client"):WaitForChild("PlayerData")) end)
local SellRequest = RS:WaitForChild("Inventory_Engine"):WaitForChild("Remotes"):WaitForChild("SellRequest")
local DismantleRequest = RS:WaitForChild("Crafting_Engine"):WaitForChild("Remotes"):WaitForChild("DismantleRequest")
SellRequest.OnClientEvent:Connect(function(ok, n, msg)
	if ok then st.sold = (st.sold or 0) + (tonumber(n) or 0); log(("ขายแล้ว %s"):format(tostring(n)))
	else log("ขายไม่ได้: " .. tostring(msg or n)) end
end)
DismantleRequest.OnClientEvent:Connect(function(ok, info, msg)
	if ok and type(info) == "table" then st.dismantled = (st.dismantled or 0) + (tonumber(info.Items) or 1); log(("ย่อยแล้ว %s ชิ้น"):format(tostring(info.Items or 1)))
	else log("ย่อยไม่ได้: " .. tostring(msg or info)) end
end)

local function invData()
	local ok, d = pcall(function() return PlayerDataMod:WaitFor().Data end)
	return ok and d or nil
end
-- every serial we may touch: unlocked, not favourite, not worn / held, not a starter weapon
local function candidates()
	local d = invData()
	if not d or not ItemRegistry then return {} end
	local worn = {}
	for _, serial in pairs(d.Equipped or {}) do worn[serial] = true end
	local out = {}
	for _, cat in ipairs({"Weapons", "Armors"}) do
		for serial, it in pairs((d.Inventory or {})[cat] or {}) do
			local reg = ItemRegistry[it.Id]
			if type(it) == "table" and reg and not it.Locked and not it.Favorited and not worn[serial]
				and it.Source ~= "Starter" and (not st.weapon or it.Id ~= st.weapon or not worn[serial]) then
				out[#out + 1] = {serial = serial, id = it.Id, count = it.Count or 1, rarity = reg.Rarity or "Unknown"}
			end
		end
	end
	return out
end
local function invPass()
	local list = candidates()
	-- dismantle wins when a rarity is ticked in both lists
	if e.dismantle then
		local byR = {}
		for _, c in ipairs(list) do
			if e.disRar[c.rarity] then byR[c.rarity] = byR[c.rarity] or {}; table.insert(byR[c.rarity], c.serial) end
		end
		for _, serials in pairs(byR) do
			for i = 1, #serials, 50 do
				local batch = {}
				for j = i, math.min(i + 49, #serials) do batch[#batch + 1] = serials[j] end
				pcall(function() DismantleRequest:FireServer(batch) end)
				task.wait(1.5)
			end
		end
	end
	if e.sell then
		local sell, n = {}, 0
		for _, c in ipairs(list) do
			if e.sellRar[c.rarity] and not (e.dismantle and e.disRar[c.rarity]) then sell[c.serial] = c.count; n += 1 end
		end
		if n > 0 then pcall(function() SellRequest:FireServer(sell) end) end
	end
end
task.spawn(function()
	while alive() do
		if e.sell or e.dismantle then pcall(invPass) end
		for _ = 1, math.max(5, e.invEvery) do if not alive() then break end task.wait(1) end
	end
end)

-- anti-AFK
local idleConn = plr.Idled:Connect(function()
	if not e.antiAfk then return end
	pcall(function()
		local VU = game:GetService("VirtualUser")
		VU:CaptureController()
		VU:ClickButton2(Vector2.new())
	end)
end)

-- ---------------------------------------------------------------------- UI
local okL, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okL or not Lib then warn("[PolyLoot] MacLib failed: " .. tostring(Lib)) return end
if not alive() then return end
local Win = Lib:Window({Title = "Poly Loot", Subtitle = "Auto Farm", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__PLOOTW = Win
local TG = Win:TabGroup()
local TARGET_OPTS = {"ใกล้สุด", "เลือดน้อยสุด", "เลือดมากสุด", "ล็อกตัวเดิมจนตาย"}
local MOVE_OPTS = {"Walk", "Tween", "Teleport"}
local PATTERN_OPTS = {"วนรอบตัว (Orbit)", "ยืนหลังมอน (Behind)", "ตีแล้วถอย (Hit & Run)"}
local SKILL_OPTS = {"ใช้ทันทีที่คูลดาวน์หมด", "สกิลฮีลใช้ตอนเลือดต่ำ"}
local function idx(opts, v) return table.find(opts, v) or 1 end
local FarmTab = TG:Tab({Name = "Farm", Image = "rbxassetid://10723346959"})

local L = FarmTab:Section({Side = "Left"})
L:Header({Text = "Auto Farm"})
L:Toggle({Name = "Auto Farm (ล็อกมอน · เดินไปตี)", Default = e.farm, Callback = function(v) e.farm = v; sv() end}, "PLFarm")
L:Toggle({Name = "Auto Attack", Default = e.attack, Callback = function(v) e.attack = v; sv() end}, "PLAttack")
L:Dropdown({Name = "วิธีโจมตี", Multi = false, Required = true, Options = {ATTACK_GAME, ATTACK_REMOTE},
	Default = e.attackMode == ATTACK_REMOTE and 2 or 1, Callback = function(v) e.attackMode = v; sv() end}, "PLAtkMode")
L:Slider({Name = "ระยะเริ่มฟัน (stud)", Default = e.reach, Minimum = 4, Maximum = 20, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.reach = v; sv() end}, "PLReach")
L:Slider({Name = "ความถี่การฟัน (วินาที/ครั้ง)", Default = e.swing, Minimum = 0.2, Maximum = 1.2, DisplayMethod = "Round", Precision = 2,
	Callback = function(v) e.swing = v; sv() end}, "PLSwing")
L:Label({Text = "ความถี่ใช้กับโหมดยิง remote · ท่าฟันของเกมใช้จังหวะของเกมเอง"})
L:Header({Text = "เก็บของ"})
L:Toggle({Name = "Instant Loot (เก็บของที่ดรอป · ไม่ต้องกดค้าง)", Default = e.loot, Callback = function(v) e.loot = v; sv() end}, "PLLoot")
L:Toggle({Name = "└ เก็บแม้ปิด Auto Farm", Default = e.lootAlways, Callback = function(v) e.lootAlways = v; sv() end}, "PLLootAlways")
L:Slider({Name = "└ ระยะเก็บของ (stud)", Default = e.lootRadius, Minimum = 10, Maximum = 300, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.lootRadius = v; sv() end}, "PLLootR")

L:Header({Text = "เลือกมอน"})
local mobDrop = L:Dropdown({Name = "มอนที่จะฟาร์ม (ไม่เลือก = ทุกตัว)", Multi = true, Required = false, Options = mobKinds(),
	Default = (function() local d = {} for k in pairs(e.mobs) do d[#d + 1] = k end return d end)(),
	Callback = function(v)
		local m = {}
		if type(v) == "table" then
			for k, on in pairs(v) do
				if type(k) == "string" and on == true then m[k] = true elseif type(on) == "string" then m[on] = true end
			end
		end
		e.mobs = m; sv()
	end}, "PLMobs")
L:Button({Name = "รีเฟรชรายชื่อมอน", Callback = function()
	pcall(function() mobDrop:ClearOptions(); mobDrop:InsertOptions(mobKinds()) end)
end})
L:Toggle({Name = "เฉพาะบอส (Tier = Boss)", Default = e.bossOnly, Callback = function(v) e.bossOnly = v; sv() end}, "PLBoss")
L:Toggle({Name = "รวมสัตว์ไม่โจมตี (Passives)", Default = e.passives, Callback = function(v) e.passives = v; sv() end}, "PLPassive")
L:Slider({Name = "ระยะค้นหา (stud)", Default = e.radius, Minimum = 50, Maximum = 2000, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.radius = v; sv() end}, "PLRadius")
L:Dropdown({Name = "การล็อกเป้า", Multi = false, Required = true, Options = TARGET_OPTS,
	Default = idx(TARGET_OPTS, e.targetMode), Callback = function(v) e.targetMode = v; sv() end}, "PLTarget")

local Rt = FarmTab:Section({Side = "Right"})
Rt:Header({Text = "สถานะ"})
local stLbl = Rt:Label({Text = "-"})
Rt:Header({Text = "ล่าสุด"})
local logLbl = Rt:Label({Text = "-"})

local MoveTab = TG:Tab({Name = "Movement", Image = "rbxassetid://10723346959"})
local M = MoveTab:Section({Side = "Left"})
M:Header({Text = "การเคลื่อนที่"})
M:Dropdown({Name = "วิธีเดินทาง", Multi = false, Required = true, Options = MOVE_OPTS,
	Default = idx(MOVE_OPTS, e.moveMode), Callback = function(v) e.moveMode = v; stopMove(); sv() end}, "PLMove")
M:Slider({Name = "ความเร็ว Tween (stud/วินาที)", Default = e.tweenSpeed, Minimum = 10, Maximum = 120, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.tweenSpeed = v; sv() end}, "PLTweenSpeed")
M:Slider({Name = "Teleport ไกลสุดต่อครั้ง (stud)", Default = e.tpMax, Minimum = 10, Maximum = 2000, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.tpMax = v; sv() end}, "PLTpMax")
M:Label({Text = "Walk = เดินจริง (Pathfinding) ปลอดภัยสุด\nTween/Teleport: เกมมีกันโกงเช็กตำแหน่งทุก 0.2 วิ\n· Tween 28+ ทะลุตึกโดนดึงกลับ · 60 ตัวละครตาย\n· Teleport เกินระยะที่ตั้งจะ Tween แทน\nตัวเลข 'โดนดึงกลับ' ในสถานะขึ้น = ลดความเร็ว"})

local P = MoveTab:Section({Side = "Right"})
P:Header({Text = "รูปแบบการฟาร์ม"})
P:Dropdown({Name = "รูปแบบ", Multi = false, Required = true, Options = PATTERN_OPTS,
	Default = idx(PATTERN_OPTS, e.pattern), Callback = function(v) e.pattern = v; sv() end}, "PLPattern")
P:Slider({Name = "ระยะยืนตี (stud)", Default = e.standDist, Minimum = 2, Maximum = 12, DisplayMethod = "Round", Precision = 1,
	Callback = function(v) e.standDist = v; sv() end}, "PLStand")
P:Slider({Name = "รัศมีวนรอบ (stud)", Default = e.orbitRadius, Minimum = 3, Maximum = 15, DisplayMethod = "Round", Precision = 1,
	Callback = function(v) e.orbitRadius = v; sv() end}, "PLOrbitR")
P:Slider({Name = "ความเร็ววนรอบ", Default = e.orbitSpeed, Minimum = 0.3, Maximum = 4, DisplayMethod = "Round", Precision = 1,
	Callback = function(v) e.orbitSpeed = v; sv() end}, "PLOrbitS")
P:Header({Text = "หลบดาเมจ"})
P:Toggle({Name = "หลบวงเตือนท่ามอน (AttackBoxTelegraph)", Default = e.dodge, Callback = function(v) e.dodge = v; sv() end}, "PLDodge")
P:Slider({Name = "ระยะเผื่อตอนหลบ (stud)", Default = e.dodgeMargin, Minimum = 0, Maximum = 10, DisplayMethod = "Round", Precision = 1,
	Callback = function(v) e.dodgeMargin = v; sv() end}, "PLDodgeM")
P:Toggle({Name = "ถอยเมื่อเลือดต่ำ", Default = e.retreat, Callback = function(v) e.retreat = v; sv() end}, "PLRetreat")
P:Slider({Name = "└ ถอยเมื่อเลือด ≤ %", Default = e.retreatAt, Minimum = 5, Maximum = 90, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.retreatAt = v; sv() end}, "PLRetreatAt")
P:Slider({Name = "└ กลับไปตีเมื่อเลือด ≥ %", Default = e.resumeAt, Minimum = 20, Maximum = 100, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.resumeAt = v; sv() end}, "PLResumeAt")

local SkTab = TG:Tab({Name = "Skills", Image = "rbxassetid://10723346959"})
local K = SkTab:Section({Side = "Left"})
K:Header({Text = "Auto Use Skill"})
K:Toggle({Name = "Auto Use Skill (สกิลที่ใส่ไว้)", Default = e.skill, Callback = function(v) e.skill = v; sv() end}, "PLSkill")
K:Dropdown({Name = "โหมดสกิล", Multi = false, Required = true, Options = SKILL_OPTS,
	Default = idx(SKILL_OPTS, e.skillMode), Callback = function(v) e.skillMode = v; sv() end}, "PLSkillMode")
K:Slider({Name = "└ ฮีลเมื่อเลือด ≤ %", Default = e.healAt, Minimum = 10, Maximum = 95, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.healAt = v; sv() end}, "PLHealAt")
K:Label({Text = "เซิร์ฟเวอร์ยอมเฉพาะสกิลที่ใส่ในช่อง + คูลดาวน์หมด\nเปลี่ยนสกิลในเกมแล้วสคริปต์ใช้ตามเอง"})
local K2 = SkTab:Section({Side = "Right"})
K2:Header({Text = "สกิลที่ใส่อยู่"})
local skLbl = K2:Label({Text = "-"})

local function multiSet(v)
	local m = {}
	if type(v) == "table" then
		for k, on in pairs(v) do
			if type(k) == "string" and on == true then m[k] = true elseif type(on) == "string" then m[on] = true end
		end
	end
	return m
end
local function picked(set) local d = {} for k in pairs(set) do d[#d + 1] = k end return d end
local InvTab = TG:Tab({Name = "Inventory", Image = "rbxassetid://10723346959"})
local IL = InvTab:Section({Side = "Left"})
IL:Header({Text = "Auto Sell ตาม Rarity"})
IL:Toggle({Name = "Auto Sell", Default = e.sell, Callback = function(v) e.sell = v; sv() end}, "PLSell")
IL:Dropdown({Name = "Rarity ที่จะขาย", Multi = true, Required = false, Options = RARITIES, Default = picked(e.sellRar),
	Callback = function(v) e.sellRar = multiSet(v); sv() end}, "PLSellRar")
IL:Header({Text = "Auto ย่อย (Dismantle) ตาม Rarity"})
IL:Toggle({Name = "Auto ย่อย", Default = e.dismantle, Callback = function(v) e.dismantle = v; sv() end}, "PLDis")
IL:Dropdown({Name = "Rarity ที่จะย่อย", Multi = true, Required = false, Options = RARITIES, Default = picked(e.disRar),
	Callback = function(v) e.disRar = multiSet(v); sv() end}, "PLDisRar")
IL:Slider({Name = "เช็กกระเป๋าทุก (วินาที)", Default = e.invEvery, Minimum = 5, Maximum = 120, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.invEvery = v; sv() end}, "PLInvEvery")
IL:Button({Name = "ขาย / ย่อยตอนนี้เลย (ตามที่ติ๊ก)", Callback = function() task.spawn(function() pcall(invPass) end) end})
IL:Label({Text = "เฉพาะอาวุธ + เกราะ · ไม่แตะของ Locked / Favorite / ที่ใส่อยู่ / อาวุธเริ่มต้น\nติ๊ก Rarity เดียวกันทั้ง 2 ฝั่ง = ย่อย (ไม่ขาย)"})
local IR2 = InvTab:Section({Side = "Right"})
IR2:Header({Text = "กระเป๋า (ของที่ขาย/ย่อยได้)"})
local invLbl = IR2:Label({Text = "-"})

local SetTab = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"})
local SS = SetTab:Section({Side = "Left"})
SS:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() Win:SetState(not Win:GetState()) end) end}, "PLToggleUI")
SS:Toggle({Name = "ถืออาวุธให้อัตโนมัติ", Default = e.equip, Callback = function(v) e.equip = v; sv() end}, "PLEquip")
SS:Toggle({Name = "Anti-AFK", Default = e.antiAfk, Callback = function(v) e.antiAfk = v; sv() end}, "PLAntiAfk")
SS:Label({Text = "God Mode / Inf Damage ทำไม่ได้: ดาเมจคิดฝั่งเซิร์ฟเวอร์\nXP / เหรียญเข้าตัวตอนมอนตายเอง · ของชิ้นใช้ Instant Loot\nตั้งค่าเซฟที่: " .. SF})

task.spawn(function()
	while alive() do
		pcall(function()
			local _, _, hum = char()
			stLbl:UpdateName(table.concat({
				st.status,
				("เลือดเรา %s · โหมด %s · %s"):format(hum and ("%d/%d"):format(hum.Health, hum.MaxHealth) or "-", e.moveMode, e.pattern),
				("ฆ่า %d · เก็บของ %d · สกิล %d · หลบ %d · โดนดึงกลับ %d"):format(st.kills, st.loots, st.skills, st.dodges, st.snaps),
				"อาวุธ: " .. tostring(st.weapon or "-"),
			}, "\n"))
			logLbl:UpdateName(#st.last > 0 and table.concat(st.last, "\n") or "-")
			local sk = {}
			for _, name in ipairs(equippedSkills()) do
				local left = (skillCd[name] or 0) - os.clock()
				sk[#sk + 1] = ("%s · %s"):format(name, left > 0 and ("คูลดาวน์ %.0f วิ"):format(left) or "พร้อม")
			end
			skLbl:UpdateName(#sk > 0 and table.concat(sk, "\n") or "ไม่มีสกิลในช่อง")
			if os.clock() % 3 < 0.5 then
				local cnt = {}
				for _, c in ipairs(candidates()) do cnt[c.rarity] = (cnt[c.rarity] or 0) + 1 end
				local lines = {}
				for _, r in ipairs(RARITIES) do
					if cnt[r] then
						lines[#lines + 1] = ("%s: %d%s"):format(r, cnt[r], (e.dismantle and e.disRar[r]) and " → ย่อย" or (e.sell and e.sellRar[r]) and " → ขาย" or "")
					end
				end
				lines[#lines + 1] = ("รอบนี้ ขาย %d · ย่อย %d"):format(st.sold or 0, st.dismantled or 0)
				invLbl:UpdateName(table.concat(lines, "\n"))
			end
		end)
		task.wait(0.5)
	end
end)

task.spawn(function()
	while alive() do task.wait(1) end
	pcall(function() hbConn:Disconnect() end)
	pcall(function() idleConn:Disconnect() end)
	pcall(function() local _, hrp, hum = char(); if hum then hum.AutoRotate = true; hum:MoveTo(hrp.Position) end end)
end)
pcall(function()
	Win.onUnloaded(function() if getgenv().__PLOOT == G then getgenv().__PLOOT = G + 1 end end)
end)
pcall(function() local c = plr.Character; local t = c and c:FindFirstChildOfClass("Tool"); if t then st.weapon = t.Name end end)
FarmTab:Select()
