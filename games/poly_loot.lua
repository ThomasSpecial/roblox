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
--     then reset to spawn; 60 studs/s killed the character. Walk (Humanoid:Move every frame + Pathfinding) is the default.

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
	bossHunt = false, bossPick = {}, bossRange = 500, bossSeen = {}, bossSafe = true,
	autoBuy = false, buyPick = {}, buyEqRar = {}, buyKeep = 20000, buyTrip = true, merchantPos = nil,
	targetMode = "คุ้มที่สุด (ฟาร์มไวสุด)", pattern = "วนรอบตัว (Orbit)", moveMode = "Walk",
	tweenSpeed = 22, tpMax = 40, standDist = 5, orbitRadius = 7, orbitSpeed = 1.6,
	attack = true, swing = 0.55, attackMode = "ท่าฟันของเกม (Tool:Activate)", reach = 11, dodge = true, dodgeMargin = 3,
	skill = true, skillMode = "ใช้ทันทีที่คูลดาวน์หมด", healAt = 60,
	retreat = true, retreatAt = 35, resumeAt = 80, antiAfk = true, equip = true,
	loot = true, lootAlways = false, lootRadius = 80,
	sell = false, sellRar = {}, dismantle = false, disRar = {}, invEvery = 20, disMin = 3, disWhenFull = true, bagFree = 3,
	useAnchor = true, anchor = nil, anchorR = 150,
	speedOn = false, speedMult = 1.2,
	watchdog = true, wdTravel = 60, wdKill = 240, autoRejoin = true, wdReset = true,
	usePotion = true, useFood = true, healItemAt = 45, healItemGap = 6, deathLog = {},
	autoStats = false, statW = {Damage = 0, Health = 0, Defense = 0},
	claimQuest = true, claimIndex = true, claimPlaytime = true, claimDaily = true,
	stayInHeal = true, healMargin = 4,
	smart = true, smartDanger = 15, smartRange = 14, aura = true, learn = {},
}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
if type(e.mobs) ~= "table" then e.mobs = {} end
if type(e.sellRar) ~= "table" then e.sellRar = {} end
if type(e.disRar) ~= "table" then e.disRar = {} end
if type(e.learn) ~= "table" then e.learn = {} end
if type(e.statW) ~= "table" then e.statW = {Damage = 0, Health = 0, Defense = 0} end
local function sv()
	pcall(function()
		if makefolder and not isfolder("PolyLoot") then makefolder("PolyLoot") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

local st = {status = "ปิดอยู่", target = nil, kills = 0, skills = 0, dodges = 0, snaps = 0, loots = 0, last = {}, weapon = nil}
getgenv().__PLDBG = st   -- debug handle (status / current target)
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
-- weapon tools carry WeaponId / InventorySerial attributes; food and potions don't. The old check took "holding any
-- tool" as armed, so an Apple left in hand after eating stayed there and the farm never swung again.
local function isWeaponTool(t) return t ~= nil and t:IsA("Tool") and t:GetAttribute("WeaponId") ~= nil end
local busyUntil = 0     -- the farm loop doesn't swing / re-equip while we eat
local function ensureWeapon()
	local c, _, hum = char()
	if not c then return false end
	local held = c:FindFirstChildOfClass("Tool")
	if isWeaponTool(held) then
		st.weapon, st.weaponSerial = held.Name, held:GetAttribute("InventorySerial") or st.weaponSerial
		return true
	end
	if not e.equip or os.clock() < busyUntil then return false end
	local bp = plr:FindFirstChildOfClass("Backpack")
	local tool
	for _, t in ipairs(bp and bp:GetChildren() or {}) do
		if isWeaponTool(t) and (not st.weapon or t.Name == st.weapon) then tool = t break end
	end
	if tool then
		pcall(function() hum:EquipTool(tool) end)
		task.wait(0.3)
	elseif os.clock() - (st.reequipAt or 0) > 1.5 then
		-- the item in hand replaced the weapon tool: ask the server for the weapon back (same as the hotbar)
		st.reequipAt = os.clock()
		local w = st.weaponSerial
		if not w then
			pcall(function()
				local d = require(plr.PlayerScripts.Data_Client.PlayerData):WaitFor().Data
				w = d.Equipped and d.Equipped.Weapon
			end)
		end
		if w then pcall(function() RS.Inventory_Engine.Remotes.EquipRequest:FireServer(w) end) task.wait(0.4) end
	end
	return isWeaponTool(c:FindFirstChildOfClass("Tool"))
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
-- farm spot: only mobs within anchorR of it count, and after a death / respawn we walk back to it
local function anchorPos()
	local a = e.useAnchor and e.anchor
	return type(a) == "table" and tonumber(a[1]) and Vector3.new(a[1], a[2], a[3]) or nil
end
local function setAnchor(pos)
	e.anchor = pos and {math.floor(pos.X * 10) / 10, math.floor(pos.Y * 10) / 10, math.floor(pos.Z * 10) / 10} or nil
	sv()
end
-- "fastest farm" targeting: value of going for mob X = XP per second (each mob's _RolledXP attribute) of the short route X -> nearest neighbour
-- -> ... (up to 4 mobs, hops < 45 studs), time = run time (distance / run speed) + kill time (HP / our measured DPS).
-- One lone mob far away loses to two mobs standing together in the other direction.
local SMART_TARGET = "คุ้มที่สุด (ฟาร์มไวสุด)"
local dpsStat = {dmg = 0, time = 0, t = nil, h = 0, at = 0}
local function myDps() return (dpsStat.dmg + 1200 * 8) / (dpsStat.time + 8) end   -- 1200/s prior, ~8 s weight
local function runSpeed() return 20 * ((e.speedOn and e.speedMult) or 1) * 0.85 end  -- 0.85: paths aren't straight
local function mobHp(m) return tonumber(m:GetAttribute("Health")) or 0 end
local function mobXp(m) return tonumber(m:GetAttribute("_RolledXP")) or 1 end
-- a kill takes at least one swing (~0.6 s) even when the hit one-shots it
local function killTime(m, dps) return math.max(mobHp(m) / dps, 0.6) end
-- mobs we couldn't damage (on a ledge above us / behind rock): ignored for a while
local skipUntil = setmetatable({}, {__mode = "k"})
local NEAR_R = 90     -- picked mobs this close always count, farm spot or not
local CLOSE_R = 35    -- a picked mob this close is fought before anything farther (smart mode included)
local function candidates_(hrp)
	local anchor = anchorPos()
	local list = {}
	local folders = {AnimalLive:FindFirstChild("Aggressors")}
	if e.passives then folders[#folders + 1] = AnimalLive:FindFirstChild("Passives") end
	for _, folder in ipairs(folders) do
		for _, m in ipairs(folder and folder:GetChildren() or {}) do
			if wanted(m) and not ((skipUntil[m] or 0) > os.clock()) then
				local mp = mobPos(m)
				local d = (mp - hrp.Position).Magnitude
				-- with a farm spot: mobs around the spot, plus any picked mob near us (don't run past one standing
				-- 70 studs away to the spot circle). Moths spread 180+ studs from the spot: with 50 here half of them
				-- were ignored and the bot walked away from them.
				if (anchor and (flat(mp - anchor).Magnitude <= e.anchorR or (d <= NEAR_R and math.abs(mp.Y - hrp.Position.Y) < 20)))
					or (not anchor and d <= e.radius) then
					list[#list + 1] = {m = m, p = mp, d = d}
				end
			end
		end
	end
	return list
end
local function routeValue(fromPos, first, pool)
	local speed, dps = runSpeed(), myDps()
	local used = {[first.m] = true}
	local pos = first.p
	local time = flat(pos - fromPos).Magnitude / speed + killTime(first.m, dps)
	local n = mobXp(first.m)
	for _ = 1, 3 do
		local nb, nd
		for _, c in ipairs(pool) do
			if not used[c.m] then
				local d = flat(c.p - pos).Magnitude
				if d < 45 and (not nd or d < nd) then nb, nd = c, d end
			end
		end
		if not nb then break end
		used[nb.m] = true
		time += nd / speed + killTime(nb.m, dps)
		n += mobXp(nb.m)
		pos = nb.p
	end
	return n / math.max(time, 0.1)
end
local function pickTarget(hrp)
	local list = candidates_(hrp)
	if e.targetMode == SMART_TARGET then
		table.sort(list, function(a, b) return a.d < b.d end)
		local pool = {}
		for i = 1, math.min(#list, 25) do pool[i] = list[i] end
		-- a mob right next to us goes first: the XP/s route math liked a wounded mob 150 studs away (kill time looks
		-- tiny) and the bot walked past Moths standing beside it. Only the close ones compete then.
		local closeOnly = pool[1] and pool[1].d <= CLOSE_R
		local best, bestV
		for _, c in ipairs(pool) do
			if not closeOnly or c.d <= CLOSE_R * 1.7 then
				local v = routeValue(hrp.Position, c, pool)
				if not bestV or v > bestV then best, bestV = c.m, v end
			end
		end
		return best, bestV, pool
	end
	local best, bestScore
	for _, c in ipairs(list) do
		local hp = mobHp(c.m)
		local score = (e.targetMode == "เลือดน้อยสุด" and hp) or (e.targetMode == "เลือดมากสุด" and -hp) or c.d
		if not bestScore or score < bestScore then best, bestScore = c.m, score end
	end
	return best
end

-- boss hunt: a picked boss (Tier = Boss) alive within bossRange of us or of the farm spot takes over from the normal
-- target until it dies; then the farm goes back to its mobs / spot. Every boss seen is remembered for the picker.
local function bossTarget(hrp)
	if not e.bossHunt then return nil end
	local anchor = anchorPos()
	local best, bd
	for _, f in ipairs({"Aggressors", "Passives"}) do
		local folder = AnimalLive:FindFirstChild(f)
		for _, m in ipairs(folder and folder:GetChildren() or {}) do
			if m:GetAttribute("Tier") == "Boss" and mobAlive(m) then
				local kind = tostring(m:GetAttribute("Animal") or "?")
				if not e.bossSeen[kind] then e.bossSeen[kind] = true; sv() end
				-- only the bosses picked by name: TripleCobra has ~1.4M HP, "any boss" would park us on it
				local _, _, hum = char()
				-- one hit of it kills us (TripleCobra hits ~13k): walking there only feeds the death loop
				local lethal = e.bossSafe and hum and (tonumber(m:GetAttribute("Damage")) or 0) >= hum.MaxHealth * 0.9
				if lethal and e.bossPick[kind] and st.bossSkip ~= kind then
					st.bossSkip = kind
					log(("ข้ามบอส %s: ตีทีละ %s แต่เลือดเต็มเรา %d (ปิด 'ข้ามบอสที่ตีทีเดียวตาย' ถ้าจะไปจริง)"):format(kind,
						tostring(m:GetAttribute("Damage")), hum.MaxHealth))
				end
				if e.bossPick[kind] and not lethal then
					local ok, p = pcall(function() return m:GetPivot().Position end)
					if ok then
						local d = (p - hrp.Position).Magnitude
						local da = anchor and flat(p - anchor).Magnitude or d
						if math.min(d, da) <= e.bossRange and (not bd or d < bd) then best, bd = m, d end
					end
				end
			end
		end
	end
	return best
end
local function bossKinds()
	local seen, list = {}, {}
	for k in pairs(e.bossSeen) do seen[k] = true end
	for k in pairs(e.bossPick) do seen[k] = true end
	-- every boss the game defines (Animal_Engine.Config), not only the ones streamed in near us so far
	pcall(function()
		local AC = require(RS.Animal_Engine.Config)
		for _, n in ipairs(AC.AnimalNames()) do
			local d = AC.Get(n)
			if type(d) == "table" and d.Tier == "Boss" then seen[n] = true end
		end
	end)
	for _, f in ipairs({"Aggressors", "Passives"}) do
		local folder = AnimalLive:FindFirstChild(f)
		for _, m in ipairs(folder and folder:GetChildren() or {}) do
			if m:GetAttribute("Tier") == "Boss" and m:GetAttribute("Animal") then seen[m:GetAttribute("Animal")] = true end
		end
	end
	for k in pairs(seen) do list[#list + 1] = k end
	table.sort(list)
	return list
end

-- ------------------------------------------------------------------ movement
-- tween/teleport goals are applied on Heartbeat; walk = Humanoid:Move(dir) every frame, like holding W: the game's
-- Movement_Client.Animate reads Humanoid.MoveDirection, which MoveTo() leaves at zero (legs slid without stepping)
local mover = {goal = nil, mode = nil, walk = nil}
-- the PlayerModule's ControlModule calls Humanoid:Move(zero) every frame while no key is held -> switch it off while
-- the script walks, give it back when farming stops
local Controls
pcall(function() Controls = require(plr.PlayerScripts:WaitForChild("PlayerModule", 5)):GetControls() end)
local controlsOff = false
-- a respawn brings the ControlModule back (it zeroes Humanoid:Move every frame) -> disable it again next walk
plr.CharacterAdded:Connect(function() controlsOff = false end)
local controlsAt = 0
local function setControls(on)
	if not Controls then return end
	-- "off" is re-asserted every 2 s: a respawn or an older copy of this script unloading can switch it back on
	if controlsOff == not on and (on or os.clock() - controlsAt < 2) then return end
	controlsOff, controlsAt = not on, os.clock()
	pcall(function() if on then Controls:Enable() else Controls:Disable() end end)
end
-- [NAV BEGIN] generated from polyloot_nav.lua by sync_plnav.py -- edit that file, not this block
local Nav = (function()
-- Poly Loot NavMap: multi-layer grid (the cave runs under the mountains, bridges over rivers), scanned tile by tile
-- (StreamingEnabled: each tile is streamed in first), A* + string-pull. Saved to PolyLoot/nav/<name>.json.
-- Cell = 3 studs. A column holds up to 8 standable floors (top-down raycasts that keep going below every hit).
-- Each floor stores 8 "blocked" bits, one per neighbour direction (waist-height rays both ways, headroom for jumps).
local Nav = {}
do
	local HS = game:GetService("HttpService")
	local Players = game:GetService("Players")
	local DIR = "PolyLoot/nav/"
	local CELL = 3
	local MAXL = 8
	local WALK_UP = 2.0    -- climb without jumping between orthogonal cells (ramps sample ~2 per cell)
	local JUMP_UP = 5.5    -- ledge we can jump onto (JumpPower 50 clears ~7)
	local DROP = 12        -- max drop we walk off
	local HEAD = 5         -- clear space a floor needs above it
	local TILE = 64        -- columns per scan tile side (192 studs)
	Nav.SCAN_V = 3   -- maps saved by an older scanner are ignored (rescan); v3: bounds cover the jungle / dark forest
	Nav.maps = {}
	-- town + fields + cave + jungle (TripleCobra -305,-1418) + dark forest; v2 stopped at x -160 and bosses past it
	-- fell back to Roblox Pathfinding
	Nav.BOUNDS = {x0 = -620, z0 = -2380, x1 = 1200, z1 = 500, top = 420, bot = 30}

	-- direction n (1..8) <-> bit 2^(n-1)
	local DIRS = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}, {1, 1}, {-1, 1}, {-1, -1}, {1, -1}}
	local DIRN = {}
	for n, d in ipairs(DIRS) do DIRN[d[1] * 3 + d[2]] = n end

	local function decode(d)
		local hts, wall = {}, {}
		for l = 1, MAXL do hts[l], wall[l] = {}, {} end
		local k = 0
		for col in (d.cols .. ","):gmatch("([^,]*),") do
			k += 1
			if col ~= "" then
				local l = 0
				for h, w in col:gmatch("(%-?%d+):(%x%x)") do
					l += 1
					hts[l][k] = tonumber(h) / 10 + d.base
					wall[l][k] = tonumber(w, 16)
				end
			end
		end
		local m = {name = d.name, cell = d.cell, x0 = d.x0, z0 = d.z0, w = d.w, h = d.h, base = d.base, top = d.top or 420,
			bot = d.bot or 30, hts = hts, wall = wall, bad = {}, edge = {}, nodes = d.nodes, scanned = d.scanned, tiles = {},
			tx = math.ceil(d.w / TILE), tz = math.ceil(d.h / TILE)}
		if type(d.tiles) == "string" and #d.tiles == m.tx * m.tz then
			for t = 1, #d.tiles do m.tiles[t] = d.tiles:sub(t, t) end
		else
			-- older file: a tile with any floor counts as scanned, an empty one as unknown
			for k = 1, d.w * d.h do
				if hts[1][k] then
					local i, j = (k - 1) % d.w, (k - 1) // d.w
					m.tiles[(j // TILE) * m.tx + i // TILE + 1] = "1"
				end
			end
		end
		return m
	end

	function Nav.load(name)
		if Nav.maps[name] then return Nav.maps[name] end
		local path = DIR .. name .. ".json"
		if not (isfile and isfile(path)) then return nil end
		local ok, d = pcall(function() return HS:JSONDecode(readfile(path)) end)
		if not ok or type(d) ~= "table" or not d.cols or (d.v or 1) < Nav.SCAN_V then return nil end
		local m = decode(d)
		Nav.maps[name] = m
		return m
	end

	function Nav.inside(m, p)
		local i = math.floor((p.X - m.x0) / CELL + 0.5)
		local j = math.floor((p.Z - m.z0) / CELL + 0.5)
		return i >= 0 and j >= 0 and i < m.w and j < m.h
	end

	-- floor of column k nearest to y within [y - DROP, y + up] (the same rule the scanner used for wall bits)
	local function layerTo(m, k, y, up)
		local best, bd
		for l = 1, MAXL do
			local h = m.hts[l][k]
			if not h then break end
			local dh = h - y
			if dh <= up and dh >= -DROP and (not bd or math.abs(dh) < bd) then best, bd = l, math.abs(dh) end
		end
		return best
	end

	-- legal step from floor (i,j,l) in direction (di,dj)? -> neighbour layer, isJump
	local step
	step = function(m, i, j, l, di, dj, walkOnly)
		local ni, nj = i + di, j + dj
		if ni < 0 or nj < 0 or ni >= m.w or nj >= m.h then return nil end
		local k = j * m.w + i + 1
		local y = m.hts[l][k]
		if not y then return nil end
		local diag = di ~= 0 and dj ~= 0
		local k2 = nj * m.w + ni + 1
		local l2 = layerTo(m, k2, y, diag and WALK_UP * 1.42 or JUMP_UP)
		if not l2 then return nil end
		local n = DIRN[di * 3 + dj]
		if bit32.band(m.wall[l][k] or 0, bit32.lshift(1, n - 1)) ~= 0 then return nil end
		if m.bad[((k - 1) * MAXL + l - 1) * 8 + n] then return nil end
		local dh = m.hts[l2][k2] - y
		if walkOnly and dh > WALK_UP then return nil end
		if diag then
			-- no corner cutting: both orthogonal legs must be walkable
			local la = step(m, i, j, l, di, 0, true)
			if not la or not step(m, i + di, j, la, 0, dj, true) then return nil end
			local lb = step(m, i, j, l, 0, dj, true)
			if not lb or not step(m, i, j + dj, lb, di, 0, true) then return nil end
		end
		return l2, dh > WALK_UP
	end
	Nav.step = step

	local function isEdge(m, i, j, l)
		local key = ((j * m.w + i) * MAXL + l)
		local v = m.edge[key]
		if v == nil then
			v = false
			for n = 1, 4 do
				if not step(m, i, j, l, DIRS[n][1], DIRS[n][2]) then v = true break end
			end
			m.edge[key] = v
		end
		return v
	end

	function Nav.worldOf(m, i, j, l)
		return Vector3.new(m.x0 + i * CELL, m.hts[l][j * m.w + i + 1] + 3, m.z0 + j * CELL)
	end

	-- nearest standable floor to a world point (root-part height, or a mob pivot) within r cells
	function Nav.snap(m, p, r)
		local ci = math.floor((p.X - m.x0) / CELL + 0.5)
		local cj = math.floor((p.Z - m.z0) / CELL + 0.5)
		local best, bi, bj, bl = math.huge
		for dj = -r, r do
			for di = -r, r do
				local i, j = ci + di, cj + dj
				if i >= 0 and j >= 0 and i < m.w and j < m.h then
					local k = j * m.w + i + 1
					for l = 1, MAXL do
						local h = m.hts[l][k]
						if not h then break end
						local dy = h + 3 - p.Y
						if dy > -14 and dy < 7 then
							local d = di * di + dj * dj + dy * dy * 0.3
							if d < best then
								local enter = false
								for n = 1, 4 do
									if step(m, i, j, l, DIRS[n][1], DIRS[n][2]) then enter = true break end
								end
								if enter then best, bi, bj, bl = d, i, j, l end
							end
						end
					end
				end
			end
		end
		return bi, bj, bl
	end

	-- A* over floors; partial = route to the reachable floor closest to the goal when it can't be reached.
	-- yieldFn() is called every 4000 expansions (long trips explore 100k+ floors).
	function Nav.astar(m, si, sj, sl, gi, gj, gl, partial, yieldFn)
		local W = m.w
		local function id(i, j, l) return (j * W + i) * MAXL + l - 1 end
		local start, goal = id(si, sj, sl), id(gi, gj, gl)
		if start == goal then return {{si, sj, sl}} end
		local g, came, closed = {[start] = 0}, {}, {}
		local heap, hn = {{0, start}}, 1
		local function push(f, nd)
			hn += 1
			heap[hn] = {f, nd}
			local c = hn
			while c > 1 do
				local p = c // 2
				if heap[p][1] <= heap[c][1] then break end
				heap[p], heap[c] = heap[c], heap[p]
				c = p
			end
		end
		local function pop()
			local top = heap[1]
			heap[1] = heap[hn]
			heap[hn] = nil
			hn -= 1
			local c = 1
			while true do
				local a, b, s = c * 2, c * 2 + 1, c
				if a <= hn and heap[a][1] < heap[s][1] then s = a end
				if b <= hn and heap[b][1] < heap[s][1] then s = b end
				if s == c then break end
				heap[s], heap[c] = heap[c], heap[s]
				c = s
			end
			return top
		end
		local function hcost(i, j)
			local dx, dz = math.abs(i - gi), math.abs(j - gj)
			return math.max(dx, dz) + 0.414 * math.min(dx, dz)
		end
		local function build(last)
			local out, nd = {}, last
			while nd do
				local l = nd % MAXL + 1
				local c = nd // MAXL
				table.insert(out, 1, {c % W, c // W, l})
				nd = came[nd]
			end
			return out
		end
		local it, bestN, bestH = 0, start, hcost(si, sj)
		while hn > 0 do
			it += 1
			if it > 400000 then break end
			if yieldFn and it % 4000 == 0 then yieldFn() end
			local cur = pop()[2]
			if cur == goal then return build(goal) end
			if not closed[cur] then
				closed[cur] = true
				local cl = cur % MAXL + 1
				local cc = cur // MAXL
				local ci, cj = cc % W, cc // W
				local hc = hcost(ci, cj)
				if hc < bestH then bestN, bestH = cur, hc end
				for n = 1, 8 do
					local d = DIRS[n]
					local l2, jump = step(m, ci, cj, cl, d[1], d[2])
					if l2 then
						local ni, nj = ci + d[1], cj + d[2]
						local nb = id(ni, nj, l2)
						if not closed[nb] then
							local cost = n > 4 and 1.414 or 1
							if jump then cost += 3 end
							if isEdge(m, ni, nj, l2) then cost += 1.5 end
							local ng = g[cur] + cost
							if not g[nb] or ng < g[nb] then
								g[nb] = ng
								came[nb] = cur
								push(ng + hcost(ni, nj), nb)
							end
						end
					end
				end
			end
		end
		if partial and bestN ~= start then return build(bestN), true end
		return nil
	end

	-- straight walk from floor a to floor b: every supercover step walkable, no cliff-lip / wall-side floors
	local function lineOk(m, a, b)
		local i, j, l = a[1], a[2], a[3]
		local dx, dz = b[1] - i, b[2] - j
		local sx, sz = dx > 0 and 1 or -1, dz > 0 and 1 or -1
		local nx, nz = math.abs(dx), math.abs(dz)
		local ix, iz = 0, 0
		while ix < nx or iz < nz do
			local t1 = nx == 0 and math.huge or (0.5 + ix) / nx
			local t2 = nz == 0 and math.huge or (0.5 + iz) / nz
			local di, dj = 0, 0
			if math.abs(t1 - t2) < 1e-9 then
				di, dj = sx, sz
				ix += 1
				iz += 1
			elseif t1 < t2 then
				di = sx
				ix += 1
			else
				dj = sz
				iz += 1
			end
			local l2 = step(m, i, j, l, di, dj, true)
			if not l2 then return false end
			i, j, l = i + di, j + dj, l2
			if isEdge(m, i, j, l) and not (i == b[1] and j == b[2]) then return false end
		end
		return l == b[3]
	end

	function Nav.smooth(m, cells)
		if #cells <= 2 then return cells end
		local out = {cells[1]}
		local a = 1
		while a < #cells do
			local b = math.min(#cells, a + 40)   -- cap the look-ahead: long lines are costly and rarely valid
			while b > a + 1 and not lineOk(m, cells[a], cells[b]) do b -= 1 end
			out[#out + 1] = cells[b]
			a = b
		end
		return out
	end

	-- from / to world points -> {{pos = Vector3, jump = bool}, ...} (first = where we stand) or nil, reason
	function Nav.plan(m, from, to, partial, yieldFn)
		local si, sj, sl = Nav.snap(m, from, 3)
		if not si then return nil, "start-off-map" end
		local gi, gj, gl = Nav.snap(m, to, 6)
		if not gi then return nil, "goal-off-map" end
		local cells, part = Nav.astar(m, si, sj, sl, gi, gj, gl, partial, yieldFn)
		if not cells then return nil, "no-path" end
		local pts, prevY = {}, nil
		for _, c in ipairs(Nav.smooth(m, cells)) do
			local p = Nav.worldOf(m, c[1], c[2], c[3])
			pts[#pts + 1] = {pos = p, jump = prevY ~= nil and p.Y - prevY > WALK_UP}
			prevY = p.Y
		end
		return pts, part and "partial" or nil
	end

	-- the step from p toward q failed in the real world: forbid it for this session
	function Nav.markBad(m, p, q)
		local i, j, l = Nav.snap(m, p, 1)
		if not i then return end
		local qi = math.floor((q.X - m.x0) / CELL + 0.5)
		local qj = math.floor((q.Z - m.z0) / CELL + 0.5)
		local di, dj = math.clamp(qi - i, -1, 1), math.clamp(qj - j, -1, 1)
		local n = DIRN[di * 3 + dj]
		if not n or (di == 0 and dj == 0) then return end
		m.bad[((j * m.w + i) * MAXL + l - 1) * 8 + n] = true
		m.edge = {}
	end

	-- ---------------------------------------------------------------- scanner
	local DYNAMIC = {"Animal_Live", "Companion_Live", "AbilityEffects", "RuntimeMounts", "Animal_LocalDebris",
		"WorldBits", "_EmoteFX_Local", "Camera", "Animal_SpawnPoints", "Knight_SpawnPoints", "AudioZones"}
	local function rayParams()
		local ex = {}
		for _, n in ipairs(DYNAMIC) do
			local f = workspace:FindFirstChild(n)
			if f then ex[#ex + 1] = f end
		end
		for _, p in ipairs(Players:GetPlayers()) do if p.Character then ex[#ex + 1] = p.Character end end
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = ex
		rp.RespectCanCollide = true
		return rp
	end

	local function newMap(name, B)
		local x0 = math.floor(B.x0 / CELL) * CELL
		local z0 = math.floor(B.z0 / CELL) * CELL
		local W = math.floor((B.x1 - x0) / CELL) + 1
		local H = math.floor((B.z1 - z0) / CELL) + 1
		local m = {name = name, cell = CELL, x0 = x0, z0 = z0, w = W, h = H, base = math.floor(B.bot) - 10,
			top = B.top, bot = B.bot, hts = {}, wall = {}, bad = {}, edge = {}, nodes = 0, tiles = {},
			tx = math.ceil(W / TILE), tz = math.ceil(H / TILE)}
		for l = 1, MAXL do m.hts[l], m.wall[l] = {}, {} end
		return m
	end

	function Nav.save(m)
		local cols, nodes = table.create(m.w * m.h), 0
		for k = 1, m.w * m.h do
			local parts = {}
			for l = 1, MAXL do
				local y = m.hts[l][k]
				if not y then break end
				nodes += 1
				parts[#parts + 1] = ("%d:%02x"):format(math.floor((y - m.base) * 10 + 0.5), m.wall[l][k] or 255)
			end
			cols[k] = table.concat(parts, "|")
		end
		local tiles = table.create(m.tx * m.tz)
		for t = 1, m.tx * m.tz do tiles[t] = m.tiles[t] or "0" end
		m.nodes, m.scanned = nodes, os.time()
		local data = {v = Nav.SCAN_V, name = m.name, cell = CELL, x0 = m.x0, z0 = m.z0, w = m.w, h = m.h, base = m.base,
			top = m.top, bot = m.bot, cols = table.concat(cols, ","), tiles = table.concat(tiles), nodes = nodes,
			scanned = m.scanned, placeVersion = game.PlaceVersion}
		if makefolder then
			if not isfolder("PolyLoot") then makefolder("PolyLoot") end
			if not isfolder("PolyLoot/nav") then makefolder("PolyLoot/nav") end
		end
		writefile(DIR .. m.name .. ".json", HS:JSONEncode(data))
	end

	-- tile states: "1" scanned with floors, "2" scanned while standing next to it and empty (void / sea),
	-- "0" unknown: it wasn't streamed in when we looked (StreamingEnabled) -> filled later when we pass by
	function Nav.tileCounts(m)
		local c = {["0"] = 0, ["1"] = 0, ["2"] = 0}
		for t = 1, m.tx * m.tz do
			local v = m.tiles[t] or "0"
			c[v] = (c[v] or 0) + 1
		end
		return c
	end
	local function tileCentre(m, t)
		local tx, tz = (t - 1) % m.tx, (t - 1) // m.tx
		local i0, j0 = tx * TILE, tz * TILE
		local i1, j1 = math.min(m.w - 1, i0 + TILE - 1), math.min(m.h - 1, j0 + TILE - 1)
		return m.x0 + (i0 + i1) / 2 * CELL, m.z0 + (j0 + j1) / 2 * CELL, i0, j0, i1, j1
	end

	-- collidable parts the game made unqueryable would be invisible to rays: flip them on while scanning
	local function flipOn()
		local flipped = {}
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BasePart") and d.CanCollide and not d.CanQuery then
				d.CanQuery = true
				flipped[#flipped + 1] = d
			end
		end
		return function()
			for _, d in ipairs(flipped) do pcall(function() d.CanQuery = false end) end
		end
	end

	-- scan one tile into the map from what is streamed in right now. near = we stand next to it (an empty result
	-- is real); returns true when the tile was written
	local function scanTile(m, t, rp, near, yieldFn)
		local W, H = m.w, m.h
		local _, _, i0, j0, i1, j1 = tileCentre(m, t)
		local top, bot, base = m.top or 420, m.bot or 30, m.base
		local fresh = {}
		local found = 0
		local function floorsAt(i, j)
			local x, z = m.x0 + i * CELL, m.z0 + j * CELL
			local list = {}
			local y0, prevY = top, nil
			for _ = 1, 20 do
				local r = workspace:Raycast(Vector3.new(x, y0, z), Vector3.new(0, bot - y0, 0), rp)
				if not r then break end
				local y = r.Position.Y
				local standable = r.Normal.Y >= 0.55
				if standable then
					if not prevY then
						standable = not workspace:Raycast(Vector3.new(x, y + 0.2, z), Vector3.new(0, HEAD, 0), rp)
					else
						-- a surface lies above (the one we came down through). From open space the up-ray hits its
						-- underside; from inside a solid (overlapping / embedded parts) the ray starts inside and hits
						-- nothing -> that "floor" is buried. v2: such buried floors made routes through rock.
						local up = workspace:Raycast(Vector3.new(x, y + 0.2, z), Vector3.new(0, prevY - y + 0.5, 0), rp)
						standable = up ~= nil and up.Position.Y - y >= HEAD
					end
				end
				prevY = y
				if standable then
					list[#list + 1] = math.floor((y - base) * 10 + 0.5) / 10 + base
					if #list >= MAXL then break end
				end
				-- keep going below this surface (a ray starting inside the part passes out of it)
				y0 = y - 0.3
				if y0 <= bot then break end
			end
			return list
		end
		for j = j0, j1 do
			for i = i0, i1 do
				local list = floorsAt(i, j)
				fresh[j * W + i + 1] = list
				if #list > 0 then found += 1 end
			end
			if yieldFn and j % 8 == 0 then yieldFn() end
		end
		if found == 0 and not near then return false end
		for k, list in pairs(fresh) do
			for l = 1, MAXL do m.hts[l][k], m.wall[l][k] = list[l], nil end
		end

		local function wallsAt(i, j)
			local k = j * W + i + 1
			local x, z = m.x0 + i * CELL, m.z0 + j * CELL
			for l = 1, MAXL do
				local y = m.hts[l][k]
				if not y then break end
				local bits = 0
				for n = 1, 8 do
					local d = DIRS[n]
					local ni, nj = i + d[1], j + d[2]
					local blockedDir = true
					if ni >= 0 and nj >= 0 and ni < W and nj < H then
						local k2 = nj * W + ni + 1
						local diag = n > 4
						-- same neighbour rule as layerTo()
						local best, bd
						for l2 = 1, MAXL do
							local h = m.hts[l2][k2]
							if not h then break end
							local dh = h - y
							if dh <= (diag and WALK_UP * 1.42 or JUMP_UP) and dh >= -DROP and (not bd or math.abs(dh) < bd) then
								best, bd = h, math.abs(dh)
							end
						end
						if best then
							local wy = math.max(y, best) + 2.2
							local a = Vector3.new(x, wy, z)
							local b = Vector3.new(m.x0 + ni * CELL, wy, m.z0 + nj * CELL)
							blockedDir = workspace:Raycast(a, b - a, rp) ~= nil or workspace:Raycast(b, a - b, rp) ~= nil
							if not blockedDir and best - y > WALK_UP then
								-- jumping up needs room above our head for the whole arc
								blockedDir = workspace:Raycast(Vector3.new(x, y + 0.2, z), Vector3.new(0, best - y + HEAD, 0), rp) ~= nil
							end
						end
					end
					if blockedDir then bits += bit32.lshift(1, n - 1) end
				end
				m.wall[l][k] = bits
			end
		end
		-- walls of the tile and of the ring around it (the neighbours' edge columns now see our fresh floors)
		for j = math.max(0, j0 - 1), math.min(H - 1, j1 + 1) do
			for i = math.max(0, i0 - 1), math.min(W - 1, i1 + 1) do wallsAt(i, j) end
			if yieldFn and j % 4 == 0 then yieldFn() end
		end
		m.tiles[t] = found > 0 and "1" or "2"
		m.edge = {}
		return true
	end

	-- full pass: every tile (or only the unknown ones with opts.missingOnly), streaming each in first when we can.
	-- Keeps what an earlier scan found for tiles that aren't streamed in now.
	-- opts: name, bounds, onStatus(text), yieldFn(), alive(), missingOnly
	function Nav.scan(opts)
		opts = opts or {}
		local name = opts.name or "main"
		local say = opts.onStatus or function() end
		local yieldFn = opts.yieldFn or function() task.wait() end
		local plr = Players.LocalPlayer
		local m = Nav.maps[name] or Nav.load(name) or newMap(name, opts.bounds or Nav.BOUNDS)
		local t0 = os.clock()
		local streamStuck = false
		local restore = flipOn()
		local total = m.tx * m.tz
		local ok, err = pcall(function()
			for t = 1, total do
				if not (opts.missingOnly and m.tiles[t] ~= nil and m.tiles[t] ~= "0") then
					local cx, cz = tileCentre(m, t)
					-- tiles near us are already streamed in; a request that times out once means the queue is stuck
					-- (one request never returned and blocked the rest: the scan hung at 120/160) -> from then on we
					-- scan what is loaded and leave the rest to fillNear()
					local me = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
					local dist = me and Vector2.new(me.Position.X - cx, me.Position.Z - cz).Magnitude or math.huge
					if dist > 450 and not streamStuck then
						local streamed = false
						task.spawn(function()
							pcall(function() plr:RequestStreamAroundAsync(Vector3.new(cx, 150, cz), 6) end)
							streamed = true
						end)
						local ts = os.clock()
						while not streamed and os.clock() - ts < 8 do task.wait(0.1) end
						if not streamed then streamStuck = true end
					end
					if opts.alive and not opts.alive() then error("cancelled") end
					say(("สแกนพื้น %d/%d"):format(t, total))
					scanTile(m, t, rayParams(), dist < 250, yieldFn)
				end
			end
		end)
		restore()
		if not ok then return nil, tostring(err) end
		Nav.save(m)
		Nav.maps[name] = m
		local c = Nav.tileCounts(m)
		return m, ("%dx%d · %d จุดยืน · ครบ %d/%d ส่วน (ยังขาด %d) · %d วิ"):format(m.w, m.h, m.nodes, c["1"] + c["2"], total,
			c["0"], math.floor(os.clock() - t0))
	end

	-- fill unknown tiles around a point (call it every few seconds while playing); returns how many were written
	function Nav.fillNear(m, pos, maxTiles, yieldFn)
		local list = {}
		for t = 1, m.tx * m.tz do
			if (m.tiles[t] or "0") == "0" then
				local cx, cz = tileCentre(m, t)
				local d = Vector2.new(pos.X - cx, pos.Z - cz).Magnitude
				if d < 420 then list[#list + 1] = {t, d} end
			end
		end
		if #list == 0 then return 0 end
		table.sort(list, function(a, b) return a[2] < b[2] end)
		local restore = flipOn()
		local n = 0
		local ok = pcall(function()
			local rp = rayParams()
			for i = 1, math.min(#list, maxTiles or 2) do
				if scanTile(m, list[i][1], rp, list[i][2] < 250, yieldFn) then n += 1 end
			end
		end)
		restore()
		return ok and n or 0
	end

	-- a tile scanned while its real ground wasn't streamed in keeps only what lay below it (Dark Forest: the map had a
	-- flat 89.8 under the forest floor at 103.6 -> "start-off-map", the bot hopped in place). Spot-check the scanned
	-- tiles near us once per session: real top floor clearly higher than the stored one -> back to "0", fillNear redoes it.
	-- Only "higher" counts: a hit we miss now (unqueryable part, streamed out) never makes a tile stale.
	function Nav.verifyNear(m, pos, maxTiles)
		m.checked = m.checked or {}
		local list = {}
		for t = 1, m.tx * m.tz do
			if m.tiles[t] == "1" and not m.checked[t] then
				local cx, cz = tileCentre(m, t)
				local d = Vector2.new(pos.X - cx, pos.Z - cz).Magnitude
				if d < 300 then list[#list + 1] = {t, d} end
			end
		end
		if #list == 0 then return 0 end
		table.sort(list, function(a, b) return a[2] < b[2] end)
		local rp = rayParams()
		local top, bot = m.top or 420, m.bot or 30
		local function liveTop(x, z)
			local y0 = top
			for _ = 1, 12 do
				local r = workspace:Raycast(Vector3.new(x, y0, z), Vector3.new(0, bot - y0, 0), rp)
				if not r then return nil end
				local y = r.Position.Y
				if r.Normal.Y >= 0.55 and not workspace:Raycast(Vector3.new(x, y + 0.2, z), Vector3.new(0, HEAD, 0), rp) then
					return y
				end
				y0 = y - 0.3
				if y0 <= bot then return nil end
			end
		end
		local stale = 0
		for n = 1, math.min(#list, maxTiles or 3) do
			local t = list[n][1]
			m.checked[t] = true
			local _, _, i0, j0, i1, j1 = tileCentre(m, t)
			local bad, seen = 0, 0
			for j = j0 + 4, j1, 10 do
				for i = i0 + 4, i1, 10 do
					local y = liveTop(m.x0 + i * CELL, m.z0 + j * CELL)
					if y then
						seen += 1
						local h = m.hts[1][j * m.w + i + 1]
						if not h or y > h + 2 then bad += 1 end
					end
				end
			end
			if bad >= 4 and bad >= seen * 0.1 then
				m.tiles[t] = "0"
				stale += 1
			end
		end
		return stale
	end
end
return Nav
end)()
-- [NAV END]
local path = {goal = nil, wps = nil, i = 0, at = 0, nav = false}
local NAV_NAME = "main"
local navMap = nil
local navTried = false
local function getNav()
	if not navMap and not navTried then
		navTried = true
		local ok, m = pcall(Nav.load, NAV_NAME)
		if ok then navMap = m end
		if not navMap then
			-- no map / made by an older scanner: scan once in the background (~40 s), Pathfinding meanwhile
			task.spawn(function()
				task.wait(5)
				if st.navScanning or not alive() then return end
				st.navScanning = true
				local m2, info = Nav.scan({name = NAV_NAME, alive = alive, onStatus = function(t) st.navWhy = t end})
				if m2 and alive() then navMap = m2; path.wps = nil end
				log(m2 and ("สแกน NavMap เสร็จ: " .. tostring(info)) or ("สแกน NavMap ไม่สำเร็จ: " .. tostring(info)))
				st.navScanning = false
			end)
		end
	end
	return navMap
end
-- StreamingEnabled: parts of the map far from us weren't loaded during the scan. Every 8 s the unknown tiles within
-- ~400 studs (streamed in now) are scanned into the map; the file is re-saved at most once a minute.
task.spawn(function()
	local dirty, lastSave = 0, os.clock()
	while alive() do
		task.wait(8)
		local m = navMap
		local _, hrp = char()
		if m and hrp and not st.navScanning then
			local okV, stale = pcall(Nav.verifyNear, m, hrp.Position, 3)
			if okV and stale > 0 then
				st.navStale = (st.navStale or 0) + stale
				log(("NavMap: พื้นในแผนที่ไม่ตรงของจริง %d ส่วน -> สแกนใหม่"):format(stale))
			end
			local n = Nav.fillNear(m, hrp.Position, 2, function() task.wait() end)
			if n > 0 then
				dirty += n
				st.navFilled = (st.navFilled or 0) + n
			end
			if dirty > 0 and os.clock() - lastSave > 60 then
				pcall(Nav.save, m)
				dirty, lastSave = 0, os.clock()
			end
		end
	end
end)
local lastPosSkip = false   -- our own unstuck hop: don't count it as a server snap-back

-- stuck watch: progress is sampled every 0.8 s while walking
local stuck = {at = 0, pos = nil, n = 0}
local unstick   -- defined below (forward-declared for walkTo / followRoute)
local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
-- a fat sweep at knee, waist and head height: a single thin ray slipped between fence rails and walked us into them
local function blocked(c, from, to)
	wallParams.FilterDescendantsInstances = {c, AnimalLive}
	local dir = flat(to - from)
	if dir.Magnitude < 1 then return false end
	local hum = c:FindFirstChildOfClass("Humanoid")
	local hrp = c:FindFirstChild("HumanoidRootPart")
	local feetY = from.Y - (hrp and hrp.Size.Y / 2 or 1) - (hum and hum.HipHeight or 2)
	for _, y in ipairs({feetY + 1.3, from.Y, from.Y + 1.5}) do
		local o = Vector3.new(from.X, y, from.Z)
		local ok, hit = pcall(function() return workspace:Spherecast(o, 1.1, dir, wallParams) end)
		if ok and hit and hit.Normal.Y < 0.7 then return true end
	end
	return false
end
-- is there floor (no more than 6 studs below our feet) under point p? Orbit / dodge / short straight walks
-- stepped off the Cobra plateau into a 24-stud pit nobody can climb out of
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
local function groundOk(c, feetY, p)
	groundParams.FilterDescendantsInstances = {c, AnimalLive}
	local r = workspace:Raycast(Vector3.new(p.X, feetY + 4, p.Z), Vector3.new(0, -10.5, 0), groundParams)
	return r ~= nil
end
local function groundAlong(c, from, to, feetY)
	local d = flat(to - from)
	local n = math.floor(d.Magnitude / 3)
	for k = 1, n do
		if not groundOk(c, feetY, from + d * (k / math.max(n, 1))) then return false end
	end
	return groundOk(c, feetY, to)
end
local function feetOf(hrp, hum)
	return hrp.Position.Y - hrp.Size.Y / 2 - (hum and hum.HipHeight or 2)
end
local function computePath(hrp, goal)
	path.goal, path.at, path.wps, path.i, path.nav = goal, os.clock(), nil, 2, false
	local m = getNav()
	if m and Nav.inside(m, hrp.Position) and Nav.inside(m, goal) then
		local ok, pts, why = pcall(Nav.plan, m, hrp.Position, goal, true, function() task.wait() end)
		if ok and pts and #pts >= 2 then
			local wps = {}
			for _, q in ipairs(pts) do
				wps[#wps + 1] = {Position = q.pos, Action = q.jump and Enum.PathWaypointAction.Jump or Enum.PathWaypointAction.Walk}
			end
			path.wps, path.nav = wps, true
			path.goal, path.at = goal, os.clock()
			st.navPlans = (st.navPlans or 0) + 1
			st.navWhy = why or "ok"
			return true
		end
		st.navWhy = ok and tostring(pts == nil and why or "short") or ("error " .. tostring(pts))
	end
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
unstick = function(hrp, hum, target, repath)
	local now = os.clock()
	local td = flat(target - hrp.Position).Magnitude
	if stuck.target and (stuck.target - target).Magnitude > 2 then
		-- reached / switched waypoint since the last check = progress
		stuck.n, stuck.td, stuck.target, stuck.at = 0, td, target, now
		return
	end
	if not stuck.td or now - stuck.at > 1 then
		if stuck.td and td > 2.5 and stuck.td - td < 1 and hum.MoveDirection.Magnitude > 0.5
			and hum.FloorMaterial ~= Enum.Material.Air then
			stuck.n += 1
			st.stuck = (st.stuck or 0) + 1
			hum.Jump = true
			stuck.pathOnly = now + 5
			if stuck.n <= 2 then
				repath()
			else
				local dir = flat(target - hrp.Position)
				dir = dir.Magnitude > 0.1 and dir.Unit or hrp.CFrame.LookVector
				hrp.CFrame = CFrame.new(hrp.Position + dir * math.min(4, td)) * (hrp.CFrame - hrp.Position)
				lastPosSkip = true
				if stuck.n >= 5 then stuck.n = 0; repath() end
			end
		elseif stuck.td and stuck.td - td >= 1 then
			stuck.n = 0
		end
		stuck.td, stuck.target, stuck.at = td, target, now
	end
end
local function walkTo(hrp, hum, goal)
	local c = hrp.Parent
	-- straight line when nothing is in the way, else Pathfinding (recomputed only when the goal moves or we get stuck);
	-- after getting stuck the straight line is not trusted for a few seconds
	local direct = os.clock() > (stuck.pathOnly or 0) and flat(goal - hrp.Position).Magnitude < 30 and not blocked(c, hrp.Position, goal)
		and math.abs(goal.Y - hrp.Position.Y) < 6 and groundAlong(c, hrp.Position, goal, feetOf(hrp, hum))
	if direct then
		path.wps = nil
	elseif not path.wps or (path.goal - goal).Magnitude > math.max(8, flat(goal - hrp.Position).Magnitude * 0.15) then
		-- a far, moving target (boss) is re-planned only when it moved a fair share of the distance: re-planning a
		-- 400-stud route every few studs it walked made us stop and turn constantly
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
	mover.walk = target

	-- unstuck, judged by progress toward the CURRENT waypoint (a long path winds sideways, so distance to the final
	-- goal often doesn't shrink while we walk it fine): 1) jump + Pathfinding only 2) thinner-agent path
	-- 3+) short flat hop toward the waypoint (hops under ~10 studs pass the server's position check)
	local now = os.clock()
	unstick(hrp, hum, target, function()
		if path.nav and navMap then Nav.markBad(navMap, hrp.Position, target) end
		computePath(hrp, goal)
	end)
end

-- recorded route: our own footsteps from where a long trip started (normally the respawn in town) to the farm spot,
-- saved to PolyLoot/route_<uid>.json the first time we arrive; later trips follow it instead of Pathfinding
local ROUTE_FILE = ("PolyLoot/route_%d.json"):format(plr.UserId)
local trail = {}          -- recent footsteps (grounded, >= 4 studs apart)
local backtrack = {i = nil, stop = 1, untilT = 0}   -- watchdog: walk our footsteps backwards
local route = nil         -- {anchor = {x,y,z}, pts = {{x,y,z}, ...}}
local routeI = nil
local tripStart = nil     -- trail index where the current far-away trip began
pcall(function()
	if isfile and isfile(ROUTE_FILE) then
		local t = HS:JSONDecode(readfile(ROUTE_FILE))
		if type(t) == "table" and type(t.pts) == "table" and #t.pts >= 2 then route = t end
	end
end)
local function routeFor(anchor)
	if not (route and anchor and route.anchor) then return nil end
	local a = Vector3.new(route.anchor[1], route.anchor[2], route.anchor[3])
	return (a - anchor).Magnitude < 15 and route or nil
end
local function trailTick(hrp, hum)
	if hum.FloorMaterial == Enum.Material.Air then return end
	local last = trail[#trail]
	local p = hrp.Position
	if not last or (p - Vector3.new(last[1], last[2], last[3])).Magnitude >= 4 then
		if last and (p - Vector3.new(last[1], last[2], last[3])).Magnitude > 30 then
			-- a teleport / respawn: start a fresh trail
			table.clear(trail)
			tripStart = nil
		end
		trail[#trail + 1] = {math.floor(p.X * 10) / 10, math.floor(p.Y * 10) / 10, math.floor(p.Z * 10) / 10}
		if #trail > 600 then
			table.remove(trail, 1)
			if tripStart then tripStart = math.max(1, tripStart - 1) end
		end
	end
	local anchor = anchorPos()
	if not anchor then return end
	local da = flat(p - anchor).Magnitude
	if da > e.anchorR + 150 then
		tripStart = tripStart or #trail
	elseif tripStart and da < 20 then
		local pts = {}
		for i = tripStart, #trail do pts[#pts + 1] = trail[i] end
		if #pts >= 10 then
			route = {anchor = {anchor.X, anchor.Y, anchor.Z}, pts = pts}
			pcall(function()
				if makefolder and not isfolder("PolyLoot") then makefolder("PolyLoot") end
				writefile(ROUTE_FILE, HS:JSONEncode(route))
			end)
			log(("บันทึกเส้นทางมาจุดฟาร์มแล้ว (%d จุด)"):format(#pts))
		end
		tripStart = nil
	end
end
-- walk the recorded route from the point nearest to us; false = not usable from here
local function followRoute(hrp, hum)
	local r = routeFor(anchorPos())
	if not r then return false end
	local p = hrp.Position
	if not routeI then
		local best, bd
		for i, q in ipairs(r.pts) do
			local d = (Vector3.new(q[1], q[2], q[3]) - p).Magnitude
			if not bd or d < bd then best, bd = i, d end
		end
		if not best or bd > 40 then return false end
		routeI = best
	end
	local q = r.pts[routeI]
	while q and flat(Vector3.new(q[1], q[2], q[3]) - p).Magnitude < 3 do
		routeI += 1
		q = r.pts[routeI]
	end
	if not q then routeI = nil return false end
	local target = Vector3.new(q[1], q[2], q[3])
	if target.Y > p.Y + 1.5 then hum.Jump = true end
	mover.walk = target
	unstick(hrp, hum, target, function() routeI = nil end)
	st.route = ("%d/%d"):format(routeI, #r.pts)
	return true
end

-- one call per tick: send the character toward goal with the selected mode
-- AreaHeal drops a field where you stand when it's cast (Radius 18, 7.5 s, heals only inside) -> while it lasts,
-- every move except a dodge is pulled back inside it
local healZone = nil   -- {c = Vector3, untilT = os.clock(), r = studs}
local function inHealZone() return healZone and os.clock() < healZone.untilT and e.stayInHeal end
local function clampHeal(goal)
	if not inHealZone() then return goal end
	local off = flat(goal - healZone.c)
	local r = math.max(healZone.r - e.healMargin, 2)
	if off.Magnitude <= r then return goal end
	local p = healZone.c + off.Unit * r
	return Vector3.new(p.X, goal.Y, p.Z)
end
local function moveTo(goal, free)
	local c, hrp, hum = char()
	if not hrp then return end
	if not free then goal = clampHeal(goal) end
	-- short repositioning (combat): the spot must have floor under it, else hold position
	if e.moveMode == "Walk" and flat(goal - hrp.Position).Magnitude < 20 and not groundOk(c, feetOf(hrp, hum), goal) then
		mover.walk = nil
		return
	end
	if e.moveMode == "Walk" then
		mover.goal = nil
		setControls(false)
		-- far from the farm spot and heading back into it: use the recorded route when there is one
		local a = anchorPos()
		local navHere = getNav() and Nav.inside(navMap, hrp.Position)
		if not navHere and a and flat(hrp.Position - a).Magnitude > e.anchorR + 40 and flat(goal - a).Magnitude < e.anchorR + 40 then
			if followRoute(hrp, hum) then return end
		else
			routeI = nil
		end
		walkTo(hrp, hum, goal)
	elseif e.moveMode == "Teleport" and (goal - hrp.Position).Magnitude <= e.tpMax then
		mover.goal, mover.mode, mover.walk = goal, "tp", nil
	else
		-- Tween, or Teleport beyond tpMax (glides at the tween speed instead of one long jump)
		mover.goal, mover.mode, mover.walk = goal, "tween", nil
	end
end
local function stopMove()
	mover.goal, mover.walk = nil, nil
	path.wps = nil
	local _, _, hum = char()
	if hum then hum:Move(Vector3.zero) end
end
-- for helper scripts (quest runners): walk with the same navmap / unstick logic as the farm
st.api = {moveTo = moveTo, stopMove = stopMove, char = char, setControls = setControls}
st.api.plan = function(a, b) local m = getNav() if not m then return nil, "no-map" end return Nav.plan(m, a, b, true) end

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
	if not lastPosSkip then pcall(trailTick, hrp, hum) end
	lastPosSkip = false
	do
		-- boost only while travelling: with 1.5x on, swings next to a frog did 0 damage (the server doesn't trust our
		-- position at that speed); same frog, normal speed, standing still: one swing = 77k
		local want = (e.farm and e.speedOn and e.speedMult ~= 1 and os.clock() > (st.fightUntil or 0)) and e.speedMult or nil
		-- escaping a slam: the game's swing slow (_WSMultC_WeaponSwing 0.5 -> WalkSpeed 10) kept us inside the circle.
		-- Cancel it only, so we run at the normal 20, never faster than a player can
		if e.farm and os.clock() < (st.evadeUntil or 0) then
			local sw = tonumber(hum:GetAttribute("_WSMultC_WeaponSwing")) or 1
			want = sw > 0 and sw < 1 and math.min(1 / sw, 2) or nil
		end
		if hum:GetAttribute("_WSMultC_PolyLoot") ~= want then hum:SetAttribute("_WSMultC_PolyLoot", want) end
	end
	if mover.walk then
		local d = flat(mover.walk - hrp.Position)
		if d.Magnitude > 0.8 then
			local dir = d.Unit
			hum:Move(dir)
			-- a ledge / rock in front that is lower than the head -> jump it
			if hum.FloorMaterial ~= Enum.Material.Air and os.clock() - (mover.jumpAt or 0) > 0.45 then
				rp.FilterDescendantsInstances = {c, AnimalLive}
				local feet = hrp.Position - Vector3.new(0, hrp.Size.Y / 2 + hum.HipHeight - 0.8, 0)
				local low = workspace:Raycast(feet, dir * 3, rp)
				if low and low.Normal.Y < 0.6 then
					local high = workspace:Raycast(hrp.Position + Vector3.new(0, 2.5, 0), dir * 3.5, rp)
					if not high then hum.Jump = true; mover.jumpAt = os.clock() end
				end
			end
		else
			hum:Move(Vector3.zero)
		end
	end
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
-- the mob that owns a telegraph = the aggressor standing nearest to it; its Damage attribute is the hit we'd take
local function telegraphDamage(p)
	local best, bd
	local folder = AnimalLive:FindFirstChild("Aggressors")
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		local ok, pos = pcall(function() return m:GetPivot().Position end)
		if ok then
			local d = (pos - p.Position).Magnitude
			if d < 20 and (not bd or d < bd) then best, bd = m, d end
		end
	end
	return best and tonumber(best:GetAttribute("Damage"))
end
-- returns a safe point outside the first telegraph box the character stands in, or nil.
-- Weak hits (< smartDanger % of our current HP) aren't worth dodging: stepping out stops our swings, and a pack of
-- wolves kept us dodging for minutes (9.8k dodges, no kills). Our own hit knocks the mob back and cancels its attack.
local function dodgePoint(hrp, hum)
	for _, p in ipairs(CS:GetTagged("AttackBoxTelegraph")) do
		if p:IsA("BasePart") and p.Parent then
			local lp = p.CFrame:PointToObjectSpace(hrp.Position)
			local hx, hz = p.Size.X / 2 + e.dodgeMargin, p.Size.Z / 2 + e.dodgeMargin
			local dmg = hum and telegraphDamage(p)
			local weak = dmg and hum.Health > 0 and dmg < hum.Health * e.smartDanger / 100
			if not weak and math.abs(lp.X) < hx and math.abs(lp.Z) < hz and math.abs(lp.Y) < p.Size.Y / 2 + 8 then
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
local AbilityData
pcall(function() AbilityData = require(RS.Ability_Engine.Data.AbilityData) end)
local castPos = {}   -- name -> where we stood when we fired it (the heal field's centre)
AbilityCastResult.OnClientEvent:Connect(function(_, name, ok, reason, cd)
	if type(name) ~= "string" then return end
	local left = tonumber(cd) or 0
	skillCd[name] = os.clock() + math.max(left, ok and 1 or 2)
	if ok then
		st.skills += 1
		log("ใช้สกิล " .. name)
		local def = AbilityData and AbilityData[name]
		if name == "AreaHeal" and castPos[name] then
			healZone = {c = castPos[name], untilT = os.clock() + (def and def.Duration or 7.5) - 0.2, r = def and def.Radius or 18}
		end
	end
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
				castPos[name] = hrp.Position
				-- heals go without a position, exactly like the game's own button (AreaHeal.GetTargetPosition = nil)
				pcall(function() AbilityFired:FireServer(seq, name, (not isHeal) and (targetPos or hrp.Position) or nil) end)
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

-- ------------------------------------------------------------------ auto sell / dismantle by rarity
-- Inventory lives in PlayerData.Data.Inventory.{Weapons, Armors}[serial] = {Id, Count, Locked, Favorited, Source};
-- rarity = ItemRegistry[Id].Rarity. SellRequest:FireServer({[serial] = count}); DismantleRequest:FireServer({serials})
-- (one rarity per batch, max 50 -- the game's own dismantle deck refuses mixed rarities).
local RARITIES = {"Common", "Rare", "Epic", "Legendary", "Godly", "Secret", "Unknown"}
local ItemRegistry, PlayerDataMod
pcall(function() ItemRegistry = require(RS.Inventory_Engine.Modules.ItemRegistry) end)
local SecretSource
-- bag = Weapons + Armors slots; cap = InvLimits.GetCap(data) (50 + boosts)
local InvLimits
pcall(function() InvLimits = require(RS.Inventory_Engine.Modules.InvLimits) end)
local function bagState(d)
	if not (InvLimits and d) then return 0, 50 end
	local okU, used = pcall(InvLimits.CountSlots, d)
	local okC, cap = pcall(InvLimits.GetCap, d)
	return okU and used or 0, okC and cap or 50
end
pcall(function() SecretSource = require(RS.Inventory_Engine.Modules.SecretSource) end)
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
	-- Secret (scaling) gear copies the best plain item of the same kind / armor slot in the bag; removing that
	-- source zeroes the Secret item (that's how the Lightning Dragon helmet + chestplate lost their stats).
	-- SecretSource.Check(data, serial, alreadyRemoved) is the game's own guard -> skip every source.
	local removing = {}
	local function isSource(serial)
		if not SecretSource then return true end   -- can't tell -> don't touch anything
		local ok, r = pcall(SecretSource.Check, d, serial, removing)
		return not ok or r ~= nil
	end
	for _, cat in ipairs({"Weapons", "Armors"}) do
		for serial, it in pairs((d.Inventory or {})[cat] or {}) do
			local reg = ItemRegistry[it.Id]
			local upgraded = type(it.Meta) == "table" and (tonumber(it.Meta.UpgradeLevel) or 0) > 0
			if type(it) == "table" and reg and not it.Locked and not it.Favorited and not upgraded and not worn[serial]
				and it.Source ~= "Starter" and not isSource(serial) then
				removing[serial] = true
				out[#out + 1] = {serial = serial, id = it.Id, count = it.Count or 1, rarity = reg.Rarity or "Unknown"}
			end
		end
	end
	return out
end
-- dismantling is refused away from a crafting table ("Head back to the crafting bench to do that."): tables are
-- models tagged CraftingStation, the game's UI opens within 11 studs
-- farm spot follows the picked mobs: when none of them lives within anchorR of the spot but some are loaded
-- elsewhere, the spot moves to the middle of the nearest group of them (picked Frog + Crocodile while standing
-- on the Cobra spot: they were 290-340 studs off, the farm just waited). With no spot yet: here.
local lastFit = 0
local function fitAnchor()
	if not e.useAnchor then return end
	lastFit = os.clock()
	local _, hrp = char()
	if not hrp then return end
	local a = anchorPos()
	if not a then setAnchor(hrp.Position); log("ตั้งจุดฟาร์มตรงนี้") return end
	local pts = {}
	for _, f in ipairs({"Aggressors", "Passives"}) do
		local folder = AnimalLive:FindFirstChild(f)
		for _, m in ipairs(folder and folder:GetChildren() or {}) do
			if wanted(m) and (f == "Aggressors" or e.passives) then
				local ok, p = pcall(function() return m:GetPivot().Position end)
				if ok then
					if flat(p - a).Magnitude <= e.anchorR then return end   -- spot still has picked mobs
					pts[#pts + 1] = p
				end
			end
		end
	end
	if #pts == 0 then return end
	local near, nd
	for _, p in ipairs(pts) do
		local d = (p - hrp.Position).Magnitude
		if not nd or d < nd then near, nd = p, d end
	end
	local sum, n = Vector3.zero, 0
	for _, p in ipairs(pts) do
		if flat(p - near).Magnitude <= math.max(60, e.anchorR * 0.8) then sum += p; n += 1 end
	end
	local c = sum / n
	setAnchor(c)
	log(("มอนที่เลือกไม่อยู่แถวจุดฟาร์มเดิม → ย้ายจุดฟาร์มไปกลางกลุ่ม (%d ตัว, ห่าง %.0f stud)"):format(n, flat(c - hrp.Position).Magnitude))
end
local trip = {active = false, at = 0, kind = nil}
local noProg = {t = nil, hp = 0, at = 0}
local healAvailable = function() return false end   -- set by the heal-item section (defined after the farm loop)
local shopTripPos = function() return nil end   -- set by the auto-buy section (defined after the farm loop)
local shopTripBuy = function() end
local function nearestStation(pos)
	local best, bd
	for _, m in ipairs(CS:GetTagged("CraftingStation")) do
		local ok, p = pcall(function() return m:GetPivot().Position end)
		if ok then
			local d = (p - pos).Magnitude
			if not bd or d < bd then best, bd = p, d end
		end
	end
	return best, bd
end
local function toDismantle()
	local byR, n = {}, 0
	for _, c in ipairs(candidates()) do
		if e.disRar[c.rarity] then byR[c.rarity] = byR[c.rarity] or {}; table.insert(byR[c.rarity], c.serial); n += 1 end
	end
	return byR, n
end
local function dismantleNow()
	local byR = toDismantle()
	for _, serials in pairs(byR) do
		for i = 1, #serials, 50 do
			local batch = {}
			for j = i, math.min(i + 49, #serials) do batch[#batch + 1] = serials[j] end
			pcall(function() DismantleRequest:FireServer(batch) end)
			task.wait(1.5)
		end
	end
end
local function invPass(manual)
	local list = candidates()
	-- dismantle wins when a rarity is ticked in both lists
	if e.dismantle or manual then
		local _, n = toDismantle()
		if n > 0 then
			local _, hrp = char()
			local _, d = nearestStation(hrp and hrp.Position or Vector3.zero)
			if d and d <= 10 then
				dismantleNow()
			elseif not trip.active and (manual or n >= math.min(e.disMin, select(2, bagState(invData())) or e.disMin) or (e.disWhenFull and (function()
				local used, cap = bagState(invData())
				return used >= cap - e.bagFree
			end)())) then
				trip.active, trip.at, trip.kind = true, os.clock(), "craft"
				log(("ของรอย่อย %d ชิ้น → ไปโต๊ะคราฟ"):format(n))
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
st.invPass = invPass   -- debug handle
st.setAnchor = function(pos) setAnchor(pos) end
st.cfg = e
task.spawn(function()
	while alive() do
		if e.sell or e.dismantle then pcall(invPass) end
		for _ = 1, math.max(5, e.invEvery) do if not alive() then break end task.wait(1) end
	end
end)

-- ------------------------------------------------------------------ auto buy (Merchant)
-- The coin shop: Data.Merchant.Slots = {{Key, Remaining}} (5 daily offers + unlocked extra slots, restock every 12 h,
-- NextRestockAt). Merchant_Engine.Remotes.PurchaseRequest:FireServer(key) buys one; the server answers
-- (ok, ?, reason) and refuses "not-at-merchant" unless we stand by a "MerchantStation"-tagged model (UI opens at 11).
-- MerchantConfig.Get(key) -> {ItemId, Price}; weapons / armour offers are keyed "EQ_<item>".
local MerchantConfig
pcall(function() MerchantConfig = require(RS.Merchant_Engine.MerchantConfig) end)
local PurchaseRequest = RS:WaitForChild("Merchant_Engine"):WaitForChild("Remotes"):WaitForChild("PurchaseRequest")
local buyReply = nil
PurchaseRequest.OnClientEvent:Connect(function(ok, _, reason) buyReply = {ok = ok, reason = reason} end)
local BUY_REASON = {coins = "เหรียญไม่พอ", ["not-at-merchant"] = "ไม่ได้ยืนที่ร้าน", ["inventory-full"] = "กระเป๋าเต็ม",
	["out-of-stock"] = "ของหมด", ["not-offered"] = "วันนี้ไม่มีขาย"}
local buyBlockUntil = 0
-- the station only exists while streamed in -> remember where it was
local function merchantPos(from)
	local best, bd
	for _, m in ipairs(CS:GetTagged("MerchantStation")) do
		local ok, p = pcall(function() return m:IsA("Model") and m:GetPivot().Position or m.Position end)
		if ok then
			local d = from and (p - from).Magnitude or 0
			if not bd or d < bd then best, bd = p, d end
		end
	end
	if best then
		local cur = e.merchantPos
		if not cur or (Vector3.new(cur[1], cur[2], cur[3]) - best).Magnitude > 3 then
			e.merchantPos = {math.floor(best.X * 10) / 10, math.floor(best.Y * 10) / 10, math.floor(best.Z * 10) / 10}
			sv()
			log("จำตำแหน่งร้าน Merchant แล้ว")
		end
		return best
	end
	local a = e.merchantPos
	return a and Vector3.new(a[1], a[2], a[3]) or nil
end
-- offers we want and can afford (keeping buyKeep coins)
local function shopWants(d)
	local out = {}
	if not (MerchantConfig and d and d.Merchant) then return out end
	local coins = tonumber(d.Coins) or 0
	for _, slot in ipairs(d.Merchant.Slots or {}) do
		local left = tonumber(slot.Remaining) or 0
		local ent = left > 0 and MerchantConfig.Get(slot.Key)
		if ent then
			local want
			if MerchantConfig.IsEquipment(ent) then
				local def = ItemRegistry and ItemRegistry[ent.ItemId]
				want = def and e.buyEqRar[def.Rarity or "Common"]
			else
				want = e.buyPick[ent.ItemId]
			end
			local price = tonumber(ent.Price) or 0
			if want and coins - price >= e.buyKeep then
				out[#out + 1] = {key = slot.Key, id = ent.ItemId, price = price, left = left}
			end
		end
	end
	return out, coins
end
local function buyNow()
	local bought = 0
	for _, o in ipairs((shopWants(invData()))) do
		for _ = 1, o.left do
			local d = invData()
			if not d or (tonumber(d.Coins) or 0) - o.price < e.buyKeep then break end
			buyReply = nil
			pcall(function() PurchaseRequest:FireServer(o.key) end)
			local t0 = os.clock()
			while not buyReply and os.clock() - t0 < 4 do task.wait(0.1) end
			if not (buyReply and buyReply.ok) then
				local why = buyReply and tostring(buyReply.reason) or "ไม่ตอบ"
				log(("ซื้อ %s ไม่ได้: %s"):format(o.id, BUY_REASON[why] or why))
				if why ~= "out-of-stock" then buyBlockUntil = os.clock() + 300 return bought end
				break
			end
			bought += 1
			st.bought = (st.bought or 0) + 1
			log(("ซื้อ %s (%d เหรียญ)"):format(o.id, o.price))
			task.wait(0.4)
		end
	end
	return bought
end
st.buyNow = buyNow   -- debug handle
shopTripPos = function(from) return merchantPos(from) end
shopTripBuy = function() buyNow() end
-- every 20 s: something worth buying -> buy if we stand at the shop, else (farming) walk there
task.spawn(function()
	while alive() do
		for _ = 1, 20 do if not alive() then return end task.wait(1) end
		if e.autoBuy and not trip.active and os.clock() > buyBlockUntil then
			pcall(function()
				local wants = shopWants(invData())
				if #wants == 0 then return end
				local _, hrp = char()
				if not hrp then return end
				local pos = merchantPos(hrp.Position)
				if pos and (pos - hrp.Position).Magnitude <= 10 then
					buyNow()
				elseif pos and e.farm and e.buyTrip then
					trip.active, trip.at, trip.kind = true, os.clock(), "shop"
					log(("ร้านมีของที่ตั้งไว้ %d อย่าง → เดินไปซื้อ"):format(#wants))
				elseif not pos then
					st.shopNote = "ยังไม่รู้ว่าร้านอยู่ไหน: เดินผ่านร้านในเมืองสักครั้ง สคริปต์จะจำเอง"
				end
			end)
		end
	end
end)
-- remember the shop the moment it streams in
CS:GetInstanceAddedSignal("MerchantStation"):Connect(function()
	task.wait(1)
	local _, hrp = char()
	pcall(merchantPos, hrp and hrp.Position)
end)
task.spawn(function() local _, hrp = char() pcall(merchantPos, hrp and hrp.Position) end)

-- ------------------------------------------------------------------ auto stats
-- Free points = Data.StatPoints + Data.BankedPoints (Upgrades_Client); spent with
-- Stats_Engine.Remotes.AllocateUpgrade:FireServer(stat, amount), stat = "Damage" | "Health" | "Defense";
-- current levels in Data.Upgrades. A re-stat costs money, so nothing is spent unless the user gave the stat a weight.
local STATS = {"Damage", "Health", "Defense"}
local AllocateUpgrade = RS:WaitForChild("Stats_Engine"):WaitForChild("Remotes"):WaitForChild("AllocateUpgrade")
local function freePoints(d) return (tonumber(d.StatPoints) or 0) + (tonumber(d.BankedPoints) or 0) end
-- the stat furthest below its share of the weights gets the next point
local function nextStat(d)
	local total = 0
	for _, s in ipairs(STATS) do total += e.statW[s] or 0 end
	if total <= 0 then return nil end
	local best, bestGap
	for _, s in ipairs(STATS) do
		local w = e.statW[s] or 0
		if w > 0 then
			local have = tonumber((d.Upgrades or {})[s]) or 0
			local gap = have / w
			if not bestGap or gap < bestGap then best, bestGap = s, gap end
		end
	end
	return best
end
task.spawn(function()
	while alive() do
		if e.autoStats then
			pcall(function()
				local d = invData()
				if not d then return end
				local pts = freePoints(d)
				if pts > 0 then
					local s = nextStat(d)
					if s then
						AllocateUpgrade:FireServer(s, 1)
						st.statsSpent = (st.statsSpent or 0) + 1
						log(("อัป %s +1 (เหลือ %d แต้ม)"):format(s, pts - 1))
					end
				end
			end)
		end
		task.wait(e.autoStats and 0.6 or 2)
	end
end)

-- ------------------------------------------------------------------ auto claim
-- Quests: Quest_Engine.Remotes.Claim:FireServer(questId) (the Quests window's Claim button); ids come from
--   Data.Quests.Daily.Slots, Achievements.Progress and Story.Active; Daily/Achievements .Completed = already claimed.
-- Index: Index_Engine.Remotes.ClaimReward:InvokeServer(category, key) for entries not yet "Claimed".
-- Playtime: Reward_Engine.Remotes.ClaimPlaytime:InvokeServer(tier); Data.Rewards.Playtime.Claimed[tier].
-- Daily login: Reward_Engine.Remotes.ClaimDaily:InvokeServer() once Data.Rewards.Daily.NextDailyAt has passed.
local QuestClaim = RS:WaitForChild("Quest_Engine"):WaitForChild("Remotes"):WaitForChild("Claim")
local IndexClaim = RS:WaitForChild("Index_Engine"):WaitForChild("Remotes"):WaitForChild("ClaimReward")
local RewardRemotes = RS:WaitForChild("Reward_Engine"):WaitForChild("Remotes")
local ClaimPlaytime = RewardRemotes:WaitForChild("ClaimPlaytime")
local ClaimDaily = RewardRemotes:WaitForChild("ClaimDaily")
local questTried = {}   -- id -> os.clock() of the last attempt (unfinished quests are refused; retry slowly)
-- quest rewards arrive as ShowRewardPopup(rewards, claimId) and are only granted on ConfirmReward(claimId), which the
-- game sends when the popup is closed -> confirm it ourselves so an AFK farm doesn't leave rewards hanging
local confirmed = {}
pcall(function()
	RewardRemotes:WaitForChild("ShowRewardPopup").OnClientEvent:Connect(function(_, claimId)
		if not claimId or not e.claimQuest then return end
		task.delay(2, function()
			if confirmed[claimId] or not alive() then return end
			confirmed[claimId] = true
			pcall(function() RewardRemotes.ConfirmReward:FireServer(claimId) end)
			st.claims = (st.claims or 0) + 1
			log("รับรางวัลเควส")
		end)
	end)
end)
local function claimPass()
	local d = invData()
	if not d then return end
	if e.claimQuest then
		local q = d.Quests or {}
		local ids = {}
		local daily = q.Daily or {}
		for _, id in pairs(daily.Slots or {}) do if not (daily.Completed or {})[id] then ids[#ids + 1] = id end end
		local ach = q.Achievements or {}
		for id in pairs(ach.Progress or {}) do if not (ach.Completed or {})[id] then ids[#ids + 1] = id end end
		for id in pairs((q.Story or {}).Active or {}) do ids[#ids + 1] = id end
		for _, id in ipairs(ids) do
			if os.clock() - (questTried[id] or -1e9) > 120 then
				questTried[id] = os.clock()
				pcall(function() QuestClaim:FireServer(id) end)
				task.wait(0.25)
			end
		end
	end
	if e.claimIndex then
		for cat, t in pairs(d.Index or {}) do
			if type(t) == "table" then
				for key, state in pairs(t) do
					if state ~= "Claimed" then
						local ok, r = pcall(function() return IndexClaim:InvokeServer(cat, key) end)
						if ok and r then st.claims = (st.claims or 0) + 1; log("รับ Index " .. tostring(key)) end
						task.wait(0.3)
					end
				end
			end
		end
	end
	local rw = d.Rewards or {}
	if e.claimPlaytime then
		local claimed = ((rw.Playtime or {}).Claimed) or {}
		for tier = 1, 12 do
			if not claimed[tier] and not claimed[tostring(tier)] then
				local ok, r = pcall(function() return ClaimPlaytime:InvokeServer(tier) end)
				if ok and r and (r == true or (type(r) == "table" and r.ok ~= false and r.success ~= false)) then
					st.claims = (st.claims or 0) + 1; log("รับ Playtime ขั้น " .. tier)
				end
				break   -- tiers unlock in order: only the next one can be ready
			end
		end
	end
	if e.claimDaily then
		local dl = rw.Daily or {}
		local now = os.time()
		if (tonumber(dl.Available) or 0) > 0 or (tonumber(dl.NextDailyAt) and now >= dl.NextDailyAt) then
			local ok, r = pcall(function() return ClaimDaily:InvokeServer() end)
			if ok and r then st.claims = (st.claims or 0) + 1; log("รับ Daily") end
		end
	end
end
task.spawn(function()
	task.wait(3)
	while alive() do
		if e.claimQuest or e.claimIndex or e.claimPlaytime or e.claimDaily then pcall(claimPass) end
		for _ = 1, 30 do if not alive() then break end task.wait(1) end
	end
end)

-- ------------------------------------------------------------------ smart combat
-- Each mob runs _State IDLE -> CHASE -> ATTACK (telegraph appears, the hit lands ~0.8 s later) -> ...; our swings put
-- it in KNOCKBACK, which cancels the attack. So light hitters are simply out-traded, heavy ones are side-stepped:
-- every attack start near us is timed, every HP loss is pinned on the attack that caused it, and per mob type we keep
-- {attacks, hits, damage, windup}. When a mob that hits "too hard" (>= smartDanger % of current HP) starts an
-- attack within smartRange, we step out until its windup is over, then go back in.
local learn = e.learn
local mobState = {}    -- model -> {state, attackAt}
local recent = {}      -- attacks of the last 2 s: {name, at}
local function L(name)
	learn[name] = learn[name] or {att = 0, hits = 0, dmg = 0, wind = 0, windN = 0}
	return learn[name]
end
local function windupOf(name)
	local l = learn[name]
	if l and l.windN >= 2 then return math.clamp(l.wind / l.windN, 0.3, 2.5) end
	return 0.85
end
local function hitOf(m)
	local l = learn[m:GetAttribute("Animal") or "?"]
	if l and l.hits >= 2 then return l.dmg / l.hits end
	return tonumber(m:GetAttribute("Damage")) or 0
end
task.spawn(function()
	local lastSave = os.clock()
	while alive() do
		local _, hrp = char()
		local folder = AnimalLive:FindFirstChild("Aggressors")
		if hrp and folder then
			local now = os.clock()
			for _, m in ipairs(folder:GetChildren()) do
				local stt = m:GetAttribute("_State")
				local rec = mobState[m]
				if stt == "ATTACK" or rec then
					local ok, pos = pcall(function() return m:GetPivot().Position end)
					if ok and (pos - hrp.Position).Magnitude < 45 then
						if not rec then rec = {}; mobState[m] = rec end
						if stt ~= rec.state then
							if stt == "ATTACK" then
								rec.attackAt = now
								local name = m:GetAttribute("Animal") or "?"
								L(name).att += 1
								table.insert(recent, {name = name, at = now})
							end
							rec.state = stt
						end
					end
				end
			end
			for m in pairs(mobState) do if not m.Parent then mobState[m] = nil end end
			while recent[1] and now - recent[1].at > 2 do table.remove(recent, 1) end
		end
		if os.clock() - lastSave > 30 then lastSave = os.clock(); sv() end
		task.wait(0.05)
	end
end)
-- HP loss -> the most recent attack that started 0.2-1.8 s before it
local function bindHurt(c)
	local hum = c:WaitForChild("Humanoid", 10)
	if not hum then return end
	local last = hum.Health
	hum.HealthChanged:Connect(function(h)
		if h < last and alive() then
			local now, best = os.clock(), nil
			for i = #recent, 1, -1 do
				local a = recent[i]
				if now - a.at >= 0.2 and now - a.at <= 1.8 then best = a break end
			end
			if best then
				local l = L(best.name)
				l.hits += 1
				l.dmg += last - h
				l.wind += now - best.at
				l.windN += 1
				best.at = -1e9   -- one hit per attack
			end
		end
		last = h
	end)
end
if plr.Character then task.spawn(bindHurt, plr.Character) end
plr.CharacterAdded:Connect(bindHurt)
-- point to step to while a dangerous attack winds up, or nil
-- how far a mob's hit reaches (Animal_Engine.Config): Haunted Tree Slam = 12-stud root eruption around it
local AnimalCfg
pcall(function() AnimalCfg = require(RS.Animal_Engine.Config) end)
local hitRadCache, areaCache = {}, {}
-- radius of an area attack (slam / impale / skyfall circle), 0 for plain melee
local function areaRadius(name)
	if areaCache[name] == nil then
		local r = 0
		pcall(function()
			local d = AnimalCfg.Get(name)
			r = math.max(tonumber(d.SlamRadius) or 0, tonumber(d.ImpaleRadius) or 0, tonumber(d.SkyfallRadius) or 0)
		end)
		areaCache[name] = r
	end
	return areaCache[name]
end
local function hitRadius(name)
	if hitRadCache[name] == nil then
		local r = 0
		pcall(function()
			local d = AnimalCfg.Get(name)
			r = math.max(tonumber(d.SlamRadius) or 0, tonumber(d.AttackRange) or 0, tonumber(d.ImpaleRadius) or 0,
				tonumber(d.SkyfallRadius) or 0)
		end)
		hitRadCache[name] = r
	end
	return hitRadCache[name]
end
local function smartEvade(hrp, hum)
	if not e.smart then return nil end
	local now = os.clock()
	-- every attack about to land on us is summed: one Haunted Tree slam (~5.7k) is under 15 % of our HP, but a pack of
	-- 3-4 trees slams together for 11k+ -> judged one by one, none was "dangerous" and we stood in all of them
	local total, need, push, worst, worstDmg = 0, 0, Vector3.zero, nil, 0
	for m, rec in pairs(mobState) do
		-- the attack START counts, not the current state: our swing puts the mob in KNOCKBACK 0.1 s later, but a Slam
		-- already wound up still lands ~0.6 s after it began. Requiring state == ATTACK ended the evade early and we
		-- walked back into the roots.
		if rec.attackAt and m.Parent then
			local name = m:GetAttribute("Animal") or "?"
			if now - rec.attackAt < windupOf(name) + 0.15 then
				local mp = mobPos(m)
				local d = flat(mp - hrp.Position).Magnitude
				local safeR = math.max(e.smartRange, hitRadius(name) + 4)
				if d < safeR then
					local dmg = hitOf(m)
					total += dmg
					need = math.max(need, safeR - d)
					local away = flat(hrp.Position - mp)
					away = away.Magnitude > 0.1 and away.Unit or -hrp.CFrame.LookVector
					push += away * dmg
					if dmg > worstDmg then worst, worstDmg = name, dmg end
				end
			end
		end
	end
	-- also anything >= 8 % of max HP: at full HP the "% of current HP" rule let 5.7k slams (9 % of 61k) through every time
	if total > 0 and total >= math.min(hum.Health * e.smartDanger / 100, hum.MaxHealth * 0.08) then
		local dir = flat(push)
		dir = dir.Magnitude > 0.1 and dir.Unit or -hrp.CFrame.LookVector
		local p = hrp.Position + dir * (need + 3)
		return Vector3.new(p.X, hrp.Position.Y, p.Z), worst, total
	end
end
local function learnText()
	local rows = {}
	for name, l in pairs(learn) do
		if l.att > 0 then
			rows[#rows + 1] = ("%s: ตี %d · โดน %d%s%s"):format(name, l.att, l.hits,
				l.hits > 0 and (" · เฉลี่ย %d"):format(l.dmg / l.hits) or "",
				l.windN > 0 and (" · ง้าง %.2fs"):format(l.wind / l.windN) or "")
		end
	end
	table.sort(rows)
	return #rows > 0 and table.concat(rows, "\n") or "ยังไม่มีข้อมูล (เรียนรู้ระหว่างฟาร์ม)"
end

-- ------------------------------------------------------------------ farm loop
local combo, swingAt, swinging = 0, 0, false
local function endCombo()
	-- the game's weapon client closes its own combo; only the raw-remote mode has to send 0
	if swinging and e.attackMode ~= ATTACK_GAME then pcall(function() WeaponAttack:FireServer(0) end) end
	swinging, combo = false, 0
end
-- turn toward the target only when we're clearly off (rotating every frame froze the walk animation)
local function swingNow(c)
	if e.attackMode == ATTACK_GAME then
		local tool = c:FindFirstChildOfClass("Tool")
		if tool then pcall(function() tool:Activate() end) end
		swinging = true
	elseif os.clock() >= swingAt then
		combo = combo % 3 + 1
		swinging = true
		swingAt = os.clock() + e.swing
		pcall(function() WeaponAttack:FireServer(combo) end)
	end
end
local function face(hrp, pos)
	local dir = flat(pos - hrp.Position)
	if dir.Magnitude < 0.5 then return end
	if hrp.CFrame.LookVector:Dot(dir.Unit) < 0.94 then
		hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + dir)
	end
end
-- Kill Aura: any aggressor inside weapon reach gets swung at (the server's hitbox needs us next to it, so a real
-- long-range aura is impossible)
local function aura(c, hrp)
	if not (e.aura and e.attack) or os.clock() < busyUntil then return false end
	local folder = AnimalLive:FindFirstChild("Aggressors")
	for _, m in ipairs(folder and folder:GetChildren() or {}) do
		if mobAlive(m) then
			local ok, pos = pcall(function() return m:GetPivot().Position end)
			if ok and flat(pos - hrp.Position).Magnitude <= e.reach and math.abs(pos.Y - hrp.Position.Y) < 12 then
				st.fightUntil = os.clock() + 2
				if ensureWeapon() then face(hrp, pos); swingNow(c) end
				return true
			end
		end
	end
	return false
end
local orbitAng = 0
local retreating = false
local lockStart = 0

task.spawn(function()
	while alive() do
		local dt = 0.1
		local ok, err = pcall(function()
			if backtrack.i and os.clock() < backtrack.untilT then
				local c, hrp, hum = char()
				if not hrp then backtrack.i = nil return end
				local q = trail[backtrack.i]
				while q and flat(Vector3.new(q[1], q[2], q[3]) - hrp.Position).Magnitude < 3 and backtrack.i > backtrack.stop do
					backtrack.i -= 1
					q = trail[backtrack.i]
				end
				if not q or backtrack.i <= backtrack.stop then backtrack.i = nil; path.wps = nil return end
				setControls(false)
				mover.goal = nil
				mover.walk = Vector3.new(q[1], q[2], q[3])
				st.status = ("Watchdog: เดินย้อนรอยเท้า (%d)"):format(backtrack.i - backtrack.stop)
				return
			end
			backtrack.i = nil
			if trip.active then
				local _, hrp = char()
				if not hrp then return end
				local shop = trip.kind == "shop"
				local pos, d
				if shop then
					pos = shopTripPos(hrp.Position)
					d = pos and (pos - hrp.Position).Magnitude
				else
					pos, d = nearestStation(hrp.Position)
				end
				-- the shop is in town, far from most farm spots: allow a longer walk
				if not pos or os.clock() - trip.at > (shop and 300 or 120) then
					trip.active = false
					log(shop and "ไปร้านไม่ถึง (หมดเวลา)" or "ไปโต๊ะคราฟไม่ถึง (หมดเวลา)")
				elseif d > 8 then
					endCombo(); lookAt = nil
					moveTo(pos)
					st.status = (shop and "เดินไปร้าน Merchant เพื่อซื้อของ · %.0f stud" or "เดินไปโต๊ะคราฟเพื่อย่อย · %.0f stud"):format(d)
					return
				else
					stopMove()
					if shop then
						st.status = "ซื้อของที่ร้าน Merchant"
						shopTripBuy()
					else
						st.status = "ย่อยของที่โต๊ะคราฟ"
						dismantleNow()
					end
					trip.active = false
					return
				end
			end
			if not e.farm then
				-- a helper script (quest runner) is driving the character through st.api: hands off
				if st.extBusy then st.status = st.extStatus or "สคริปต์เควสกำลังทำงาน"; return end
				if st.target then st.target = nil; lookAt = nil; endCombo(); stopMove() end
				-- check the real ControlModule state, not just our flag: a respawn / rejoin / older copy of the script can
				-- leave it disabled while controlsOff says false -> the player can't walk ("ขาแข็ง")
				local ctlDead = false
				pcall(function() ctlDead = Controls and Controls.activeController and Controls.activeController.enabled == false end)
				if (controlsOff or ctlDead) and not (e.lootAlways and mover.walk) then
					mover.walk = nil
					controlsOff = true
					setControls(true)
				end
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
			local anchor = anchorPos()
			local boss = bossTarget(hrp)
			st.bossActive = boss ~= nil
			if boss then
				if t ~= boss then
					t = boss
					lockStart = os.clock()
					log(("บอสเกิด → ไปตี %s (HP %s)"):format(tostring(boss:GetAttribute("Animal")), tostring(boss:GetAttribute("Health"))))
				end
			else
			if t and e.targetMode ~= "ล็อกตัวเดิมจนตาย" then
				-- out of the spot circle AND not near us (a mob near us counts as a candidate, see NEAR_R)
				if anchor and flat(mobPos(t) - anchor).Magnitude > e.anchorR + 30
					and (mobPos(t) - hrp.Position).Magnitude > NEAR_R + 20 then t = nil
				elseif not anchor and (mobPos(t) - hrp.Position).Magnitude > e.radius + 50 then t = nil end
			end
			if t and e.targetMode ~= "ล็อกตัวเดิมจนตาย" and not wanted(t) then t = nil end
			-- non-lock modes re-check twice a second: a mob that (re)spawned closer / weaker takes over,
			-- with a margin so two similar mobs don't flip-flop
			-- a mob we already hurt is finished first: our hits knock it back out of reach, and re-evaluating then
			-- swapped a half-dead Cobra (177k/300k) for a full one 100 studs away, back and forth
			local committed = t and mobAlive(t) and mobHp(t) < (tonumber(t:GetAttribute("MaxHealth")) or math.huge) * 0.97
				and flat(mobPos(t) - hrp.Position).Magnitude < 45
			if t and not committed and e.targetMode ~= "ล็อกตัวเดิมจนตาย" and os.clock() - (st.reevalAt or 0) > 0.5 then
				st.reevalAt = os.clock()
				local cand, candV, pool = pickTarget(hrp)
				if cand and cand ~= t then
					local better
					if e.targetMode == SMART_TARGET then
						-- don't drop the mob we're already hitting; otherwise switch when the new route is clearly better
						local dt = flat(mobPos(t) - hrp.Position).Magnitude
						if dt > e.reach + 2 then
							local curV = routeValue(hrp.Position, {m = t, p = mobPos(t)}, pool or {})
							local dc = flat(mobPos(cand) - hrp.Position).Magnitude
							-- walking to a far one while a picked mob stands right here: take the close one
							better = (candV and candV > curV * 1.3) or (dc <= CLOSE_R and dt > CLOSE_R * 2)
						end
					elseif e.targetMode == "เลือดน้อยสุด" then
						better = (tonumber(cand:GetAttribute("Health")) or 0) < (tonumber(t:GetAttribute("Health")) or 0) * 0.8
					elseif e.targetMode == "เลือดมากสุด" then
						better = (tonumber(cand:GetAttribute("Health")) or 0) > (tonumber(t:GetAttribute("Health")) or 0) * 1.25
					else
						local dt = flat(mobPos(t) - hrp.Position).Magnitude
						local dc = flat(mobPos(cand) - hrp.Position).Magnitude
						better = dc + 6 < dt and dc < dt * 0.8
					end
					if better then
						t = cand
						lockStart = os.clock()
						log(("สลับไป %s (ใกล้/ดีกว่า)"):format(tostring(cand:GetAttribute("Animal"))))
					end
				end
			end
			end -- boss
			if not t then
				t = pickTarget(hrp)
				if t then lockStart = os.clock(); log(("ล็อก %s/%s HP %s"):format(tostring(t:GetAttribute("Animal")), tostring(t:GetAttribute("Tier")), tostring(t:GetAttribute("Health")))) end
			end
			st.target = t
			if not t then
				endCombo(); lookAt = nil
				if anchor and flat(anchor - hrp.Position).Magnitude > 12 then
					-- nothing to hit near the farm spot from here (e.g. just respawned in town): walk back
					if not aura(c, hrp) then endCombo() end
					moveTo(anchor)
					st.status = ("กลับจุดฟาร์ม · %.0f stud"):format(flat(anchor - hrp.Position).Magnitude)
				else
					stopMove()
					st.status = anchor and ("รอมอนเกิดรอบจุดฟาร์ม (รัศมี %d)"):format(e.anchorR) or ("ไม่มีมอนที่เลือกในระยะ %d"):format(e.radius)
					if anchor and os.clock() - lastFit > 5 then fitAnchor() end
				end
				return
			end
			local tp = mobPos(t)
			local dist = flat(tp - hrp.Position).Magnitude
			-- a mob on a ledge 20 studs up but 9 across is NOT in reach: we stood under the cliff swinging at rock
			if dist < 30 then st.fightUntil = os.clock() + 2 end
			local dy = math.abs(tp.Y - hrp.Position.Y)
			if dy > 8 then dist = math.max(dist, math.max(e.standDist, e.orbitRadius) + 9 + dy) end
			-- in reach but its HP doesn't move for 8 s -> we can't actually hit it: skip it for 45 s
			do
				local h = mobHp(t)
				-- close by (flat < 40) but no damage: 8 s when "in reach", 20 s while still trying to climb to it
				if noProg.t ~= t or h < noProg.hp - 1 or flat(tp - hrp.Position).Magnitude > 40 then
					noProg.t, noProg.hp, noProg.at = t, h, os.clock()
				elseif os.clock() - noProg.at > (dist <= e.reach + 2 and 8 or 20) then
					skipUntil[t] = os.clock() + 45
					log(("ตี %s ไม่เข้า (อยู่บนที่สูง/หลังหิน) → ข้ามไปตัวอื่น 45 วิ"):format(tostring(t:GetAttribute("Animal"))))
					st.target, noProg.t = nil, nil
					endCombo()
					return
				end
			end
			do
				local now, h = os.clock(), mobHp(t)
				if dpsStat.t == t then
					if dist <= e.reach + 1 then
						dpsStat.time += math.min(now - dpsStat.at, 0.5)
						if h < dpsStat.h then dpsStat.dmg += dpsStat.h - h end
					end
				else
					dpsStat.t = t
				end
				dpsStat.h, dpsStat.at = h, now
				st.dps = myDps()
			end

			-- low HP: back off and let AreaHeal / regen work
			if e.retreat then
				-- retreat only when there's nothing worth eating: ranged mobs (Cobra spit) hit us while we wait anyway
				if hpPct() <= e.retreatAt and not ((e.usePotion or e.useFood) and healAvailable()) then retreating = true end
				if retreating and (e.usePotion or e.useFood) and healAvailable() and hpPct() > e.retreatAt then retreating = false end
				if retreating and hpPct() >= e.resumeAt then retreating = false end
			else
				retreating = false
			end
			useSkills(tp)
			if retreating then
				endCombo(); lookAt = nil
				local away = flat(hrp.Position - tp)
				away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
				if inHealZone() then
					moveTo(healZone.c)
				else
					moveTo(tp + away * 45)
				end
				st.status = ("ถอยเลือดต่ำ %d%% → รอ %d%%"):format(hpPct(), e.resumeAt)
				return
			end

			-- smart evade (heavy hitter winding up) > telegraph dodge > drops > fight
			local ev, evName, evDmg = smartEvade(hrp, hum)
			if ev then
				st.evades = (st.evades or 0) + 1
				st.evadeUntil = os.clock() + 0.3
				endCombo()
				moveTo(ev, true)
				st.status = ("ถอยหลบ %s (ตีแรง ~%d)"):format(tostring(evName), evDmg or 0)
				return
			end
			local dp = e.dodge and dodgePoint(hrp, hum)
			if not dp and lootStep(hrp) then
				lookAt = nil
				if not aura(c, hrp) then endCombo() end
				return
			end
			if dp then
				st.dodges += 1
				moveTo(dp, true)
				lookAt = tp
				st.status = "หลบท่า"
			elseif dist > math.max(e.standDist, e.orbitRadius) + 8 then
				lookAt = nil
				if not aura(c, hrp) then endCombo() end
				moveTo(e.moveMode == "Walk" and tp or Vector3.new(tp.X, hrp.Position.Y, tp.Z))
				st.status = ("เดินทางไปหา %s · %.0f stud (%s)"):format(tostring(t:GetAttribute("Animal")), dist, e.moveMode)
				return
			else
				lookAt = tp
				local pattern = e.pattern
				-- small mobs (Frog / Tiny / Small): circling turned our back to them and they hopped under our feet;
				-- the swing's hitbox is in front of us -> stand ~4.5 studs off, face it, no orbit
				local tier = t:GetAttribute("Tier")
				local fd = flat(hrp.Position - tp).Magnitude
				if tier == "Tiny" or tier == "Small" then
					if fd < 3.5 then
						local away = flat(hrp.Position - tp)
						away = away.Magnitude > 0.1 and away.Unit or -hrp.CFrame.LookVector
						moveTo(tp + away * 4.5, true)
					elseif fd > e.reach - 1 then
						moveTo(Vector3.new(tp.X, hrp.Position.Y, tp.Z), true)
					else
						stopMove()
					end
				elseif pattern == "วนรอบตัว (Orbit)" then
					local cur = math.atan2(hrp.Position.Z - tp.Z, hrp.Position.X - tp.X)
					orbitAng = cur + e.orbitSpeed * 0.6
					-- area slams (Haunted Tree: 12-stud circle around it, lands 0.62 s after the wind-up, we swing at
					-- WalkSpeed 10): from 7 studs we only got to ~13 before it landed and took every slam. Fight at the
					-- edge of our reach instead -> a few steps clear it.
					local r = e.orbitRadius
					local area = areaRadius(t:GetAttribute("Animal") or "?")
					if area > r then r = math.max(r, math.min(e.reach - 1.5, area - 2)) end
					local goal = tp + Vector3.new(math.cos(orbitAng), 0, math.sin(orbitAng)) * r
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
			if os.clock() < busyUntil then
				-- eating / drinking: hands are busy
			elseif e.attack and dist <= e.reach and ensureWeapon() then
				-- Tool:Activate() runs the game's own swing: animation, combo 1-2-3 and its timing
				face(hrp, tp)
				swingNow(c)
			elseif aura(c, hrp) then
				-- something else is in reach while we close in on the target
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

-- ------------------------------------------------------------------ heal items (potions / food)
-- Consumables are used like the hotbar does: EquipRequest(serial) puts the item in hand, Tool:Activate() eats /
-- drinks it, EquipRequest(weaponSerial) puts the weapon back (verified: Apple 76 -> 75, sword back in hand).
local InvRemotes = RS.Inventory_Engine.Remotes
local HEAL_ORDER = {"HealthPotion2", "HealthPotion", "GoldenApple", "Cake", "JungleCookies", "BananaBread", "Banana",
	"Coconut", "Milk", "Bandage", "Apple"}
local FOODS = {GoldenApple = true, Cake = true, JungleCookies = true, BananaBread = true, Banana = true, Coconut = true,
	Milk = true, Apple = true, Bandage = true}
local lastHeal = 0
local regenUntil = 0
-- how much an item really heals (Consumable_Engine.ConsumableDefs): HealthPotion = 50 HP flat, Apple = 30 HP,
-- GoldenApple = 50 % of max HP + 5 %/s regeneration for 60 s. With ~6k max HP the flat ones are worthless: the old
-- fixed order drank 50-HP potions over and over while a Cobra spat on us.
local ConsDefs
pcall(function() ConsDefs = require(RS.Consumable_Engine.ConsumableDefs) end)
local function healValue(id, maxHp)
	local def = ConsDefs and ConsDefs[id]
	if type(def) ~= "table" then return 0, 0 end
	local v, regen = 0, 0
	for _, fx in ipairs(def) do
		if fx.type == "heal" then
			v += tonumber(fx.amount) or 0
		elseif fx.type == "healPercent" then
			v += (tonumber(fx.percent) or 0) * maxHp
		elseif fx.type == "applyEffect" and fx.effect == "Regeneration" and type(fx.params) == "table" then
			local per = (tonumber(fx.params.pctPerTick) or 0) * maxHp / (tonumber(fx.params.tickInterval) or 1)
			v += per * math.min(tonumber(fx.duration) or 0, 15)   -- count the first 15 s of regen
			regen = tonumber(fx.duration) or 0
		end
	end
	return v, regen
end
-- best item we have that heals at least 10 % of max HP
local function healItem(d)
	local _, _, hum = char()
	local maxHp = hum and hum.MaxHealth or 100
	local cons = (d.Inventory or {}).Consumables or {}
	local best, bestId, bestV, bestRegen
	for serial, it in pairs(cons) do
		local id = it.Id
		if (tonumber(it.Count) or 0) > 0 and ((FOODS[id] and e.useFood) or (not FOODS[id] and e.usePotion)) then
			local v, regen = healValue(id, maxHp)
			if v >= maxHp * 0.1 and (not bestV or v > bestV) then best, bestId, bestV, bestRegen = serial, id, v, regen end
		end
	end
	return best, bestId, bestRegen
end
healAvailable = function()
	local d = invData()
	return d ~= nil and healItem(d) ~= nil
end
local function useHeal()
	local d = invData()
	local c, _, hum = char()
	if not (d and c) then return end
	local serial, id, regen = healItem(d)
	if not serial then return end
	busyUntil = os.clock() + 2.5
	lastHeal = os.clock()
	local before = (d.Inventory.Consumables[serial] or {}).Count
	local hp0 = hum and hum.Health or 0
	-- remember the weapon BEFORE the food goes in hand (Equipped changes once it's held)
	local held0 = c:FindFirstChildOfClass("Tool")
	local w = (isWeaponTool(held0) and held0:GetAttribute("InventorySerial")) or st.weaponSerial or (d.Equipped and d.Equipped.Weapon)
	pcall(function() InvRemotes.EquipRequest:FireServer(serial) end)
	for _ = 1, 10 do
		task.wait(0.1)
		local held = c:FindFirstChildOfClass("Tool")
		if held and not isWeaponTool(held) then pcall(function() held:Activate() end) break end
	end
	-- weapon back the moment it's eaten (count dropped / HP jumped), not after a fixed 2 s
	local t0 = os.clock()
	while os.clock() - t0 < 1.6 do
		task.wait(0.1)
		local it = (invData() or d).Inventory.Consumables[serial]
		if not it or it.Count ~= before or (hum and hum.Health > hp0 + 20) then break end
	end
	-- weapon back, and make sure it really is in hand (retry, then the backpack route in ensureWeapon)
	for _ = 1, 3 do
		if w then pcall(function() InvRemotes.EquipRequest:FireServer(w) end) end
		local t1 = os.clock()
		while os.clock() - t1 < 0.8 and not isWeaponTool(c:FindFirstChildOfClass("Tool")) do task.wait(0.1) end
		if isWeaponTool(c:FindFirstChildOfClass("Tool")) then break end
	end
	if (regen or 0) > 0 then regenUntil = os.clock() + math.min(regen, 30) end
	busyUntil = 0
	if not isWeaponTool(c:FindFirstChildOfClass("Tool")) then pcall(ensureWeapon) end
	st.heals = (st.heals or 0) + 1
	log(("กิน %s (เลือด %d%%)"):format(id, hpPct()))
end
task.spawn(function()
	while alive() do
		task.wait(0.25)
		-- while a regeneration item works, eat again only in an emergency
		if e.farm and (e.usePotion or e.useFood) and hpPct() > 0 and hpPct() <= e.healItemAt
			and os.clock() - lastHeal > e.healItemGap and (os.clock() > regenUntil or hpPct() <= 25) then
			pcall(useHeal)
		end
	end
end)

-- death log: what we were fighting, who was around, who landed the last hit
local function bindDeath(c)
	local hum = c:WaitForChild("Humanoid", 10)
	if not hum then return end
	hum.Died:Connect(function()
		if not alive() then return end
		local hrp = c:FindFirstChild("HumanoidRootPart")
		local around = {}
		for m, rec in pairs(mobState) do
			if m.Parent and hrp then
				local ok, pos = pcall(function() return m:GetPivot().Position end)
				if ok and (pos - hrp.Position).Magnitude < 25 then
					around[#around + 1] = ("%s(%s)"):format(tostring(m:GetAttribute("Animal")), tostring(rec.state))
				end
			end
		end
		local lastBy = recent[#recent] and recent[#recent].name or "?"
		st.deaths = (st.deaths or 0) + 1
		local line = ("ตาย: เป้า %s · รอบตัว %s · โดนล่าสุดจาก %s"):format(st.target and tostring(st.target:GetAttribute("Animal")) or "-",
			#around > 0 and table.concat(around, ",") or "-", lastBy)
		log(line)
		e.deathLog = e.deathLog or {}
		table.insert(e.deathLog, 1, os.date("%m-%d %H:%M ") .. line)
		while #e.deathLog > 20 do table.remove(e.deathLog) end
		sv()
	end)
end
if plr.Character then task.spawn(bindDeath, plr.Character) end
plr.CharacterAdded:Connect(bindDeath)

-- ------------------------------------------------------------------ watchdog (unattended / overnight)
-- 1) heading back to the farm spot but the distance hasn't shrunk 15 studs in wdTravel s -> reset the character
--    (respawn in town, from where Pathfinding / the recorded route reaches the spot)
-- 2) a target exists but nothing died for wdKill s -> reset
-- 3) kicked / disconnected -> rejoin this place; the loader is queued to run again after the teleport
local LOADER_URL = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/loader.lua"
local wd = {best = nil, at = os.clock(), kills = 0, killAt = os.clock(), grace = 0, tries = 0}
local function resetChar(why)
	local _, _, hum = char()
	if not hum then return end
	st.resets = (st.resets or 0) + 1
	log("Watchdog รีเซ็ตตัวละคร: " .. why)
	wd.grace = os.clock() + 25
	wd.best, wd.at, wd.killAt = nil, os.clock(), os.clock()
	routeI = nil
	path.wps = nil
	pcall(function() hum.Health = 0 end)
end
task.spawn(function()
	while alive() do
		task.wait(5)
		pcall(function()
			local now = os.clock()
			if st.kills ~= wd.kills then wd.kills, wd.killAt = st.kills, now end
			if not (e.farm and e.watchdog) or now < wd.grace or trip.active or st.bossActive then
				wd.best, wd.at = nil, now
				if not e.farm then wd.killAt = now end
				return
			end
			local _, hrp = char()
			if not hrp then wd.at, wd.killAt = now, now return end
			local a = anchorPos()
			if a then
				local d = flat(hrp.Position - a).Magnitude
				if d > e.anchorR + 40 then
					if not wd.best or d < wd.best - 15 then wd.best, wd.at, wd.tries = d, now, 0 end
					if now - wd.at > e.wdTravel then
						wd.tries = (wd.tries or 0) + 1
						if wd.tries <= 2 or not e.wdReset then
							-- walk back the way we came (~100 studs of our own footsteps), then Pathfinding again
							backtrack.i = #trail
							backtrack.stop = math.max(1, #trail - 25)
							backtrack.untilT = now + 20
							path.wps, routeI = nil, nil
							st.backtracks = (st.backtracks or 0) + 1
							log(("Watchdog: ติด → เดินย้อนรอยเท้า (ครั้งที่ %d)"):format(wd.tries))
							wd.at = now
						else
							resetChar(("เดินย้อนแล้วยังติด (ห่าง %.0f)"):format(d))
						end
						return
					end
				else
					wd.best, wd.at, wd.tries = nil, now, 0
				end
			end
			if st.target and now - wd.killAt > e.wdKill and e.wdReset then resetChar(("ไม่ได้ฆ่ามอนเลย %d วิ"):format(e.wdKill)) return end
			-- trapped: near the spot, nothing killed for 30 s, and the navmap's walkable area around us doesn't
			-- reach the spot while we stand well below it (fell into a pit) -> twice in a row = reset now
			if a and navMap and e.wdReset and now - wd.killAt > 30 and flat(hrp.Position - a).Magnitude < e.anchorR + 40
				and hrp.Position.Y < a.Y - 8 then
				local ok, pts = pcall(Nav.plan, navMap, hrp.Position, a, true, function() task.wait() end)
				local endP = ok and pts and pts[#pts].pos
				if endP and flat(endP - a).Magnitude > 30 and endP.Y < a.Y - 8 then
					wd.trapped = (wd.trapped or 0) + 1
					if wd.trapped >= 2 then
						wd.trapped = 0
						resetChar("ตกหลุม เดินกลับขึ้นจุดฟาร์มไม่ได้")
						return
					end
				else
					wd.trapped = 0
				end
			end
			st.wd = ("ฆ่าล่าสุด %d วิก่อน%s"):format(now - wd.killAt, wd.best and (" · ระยะกลับ %.0f (คืบล่าสุด %d วิก่อน)"):format(wd.best, now - wd.at) or "")
		end)
	end
end)
pcall(function()
	game:GetService("GuiService").ErrorMessageChanged:Connect(function(msg)
		if not (alive() and e.autoRejoin) or msg == "" then return end
		log("หลุดจากเกม: " .. tostring(msg) .. " → เข้าใหม่")
		local qot = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
		if qot then pcall(qot, ('loadstring(game:HttpGet("%s"))()'):format(LOADER_URL)) end
		task.wait(5)
		for _ = 1, 20 do
			pcall(function() game:GetService("TeleportService"):Teleport(game.PlaceId, plr) end)
			task.wait(15)
		end
	end)
end)

-- reward screen ("NEW LOOT!" / "Click Anywhere To Continue"): while it is up the game sets UIWorldClear, and the
-- weapon client's canAttack() refuses every swing -> an AFK farm stood next to mobs for minutes until the watchdog
-- reset it (217 resets in one night). Close it like a player would: click the footer (not a card, which would flip it).
do
	local RewardScreenMod
	pcall(function() RewardScreenMod = require(RS.Reward_Engine.Modules.RewardScreen) end)
	local VIM = game:GetService("VirtualInputManager")
	local shownAt
	task.spawn(function()
		while alive() do
			task.wait(0.5)
			pcall(function()
				local gui = plr.PlayerGui:FindFirstChild("RewardScreen")
				local up = gui and gui.Enabled and (not RewardScreenMod or RewardScreenMod.IsActive())
				if not up then shownAt = nil return end
				shownAt = shownAt or os.clock()
				-- the screen ignores clicks until its reveal has played (~1-2 s)
				if not e.farm or os.clock() - shownAt < 2 then return end
				local foot = gui:FindFirstChild("Main") and gui.Main:FindFirstChild("Footer")
				local cam = workspace.CurrentCamera
				local p = foot and (foot.AbsolutePosition + foot.AbsoluteSize / 2)
					or Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y * 0.95)
				local inset = game:GetService("GuiService"):GetGuiInset()
				VIM:SendMouseButtonEvent(p.X + inset.X, p.Y + inset.Y, 0, true, game, 0)
				task.wait(0.05)
				VIM:SendMouseButtonEvent(p.X + inset.X, p.Y + inset.Y, 0, false, game, 0)
				st.popups = (st.popups or 0) + 1
				shownAt = os.clock() - 1   -- retry in ~1 s if it is still up
			end)
		end
	end)
end

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
local TARGET_OPTS = {SMART_TARGET, "ใกล้สุด", "เลือดน้อยสุด", "เลือดมากสุด", "ล็อกตัวเดิมจนตาย"}
local MOVE_OPTS = {"Walk", "Tween", "Teleport"}
local PATTERN_OPTS = {"วนรอบตัว (Orbit)", "ยืนหลังมอน (Behind)", "ตีแล้วถอย (Hit & Run)"}
local SKILL_OPTS = {"ใช้ทันทีที่คูลดาวน์หมด", "สกิลฮีลใช้ตอนเลือดต่ำ"}
local function idx(opts, v) return table.find(opts, v) or 1 end
local FarmTab = TG:Tab({Name = "Farm", Image = "rbxassetid://10723346959"})

local L = FarmTab:Section({Side = "Left"})
L:Header({Text = "Auto Farm"})
L:Toggle({Name = "Auto Farm (ล็อกมอน · เดินไปตี)", Default = e.farm, Callback = function(v)
	e.farm = v
	if v then fitAnchor() end
	sv()
end}, "PLFarm")
L:Toggle({Name = "Auto Attack", Default = e.attack, Callback = function(v) e.attack = v; sv() end}, "PLAttack")
L:Toggle({Name = "Kill Aura (ฟันทุกตัวที่อยู่ในระยะ แม้ตอนเดิน/เก็บของ)", Default = e.aura, Callback = function(v) e.aura = v; sv() end}, "PLAura")
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
		if e.farm then fitAnchor() end
	end}, "PLMobs")
L:Button({Name = "รีเฟรชรายชื่อมอน", Callback = function()
	pcall(function() mobDrop:ClearOptions(); mobDrop:InsertOptions(mobKinds()) end)
end})
L:Toggle({Name = "เฉพาะบอส (Tier = Boss)", Default = e.bossOnly, Callback = function(v) e.bossOnly = v; sv() end}, "PLBoss")
L:Toggle({Name = "รวมสัตว์ไม่โจมตี (Passives)", Default = e.passives, Callback = function(v) e.passives = v; sv() end}, "PLPassive")
L:Slider({Name = "ระยะค้นหา (stud)", Default = e.radius, Minimum = 50, Maximum = 2000, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.radius = v; sv() end}, "PLRadius")
L:Header({Text = "จุดฟาร์ม (ตายแล้วกลับมาที่เดิม)"})
L:Toggle({Name = "ฟาร์มเฉพาะรอบจุดฟาร์ม", Default = e.useAnchor, Callback = function(v) e.useAnchor = v; sv() end}, "PLAnchorOn")
L:Slider({Name = "└ รัศมีรอบจุดฟาร์ม (stud)", Default = e.anchorR, Minimum = 30, Maximum = 600, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.anchorR = v; sv() end}, "PLAnchorR")
L:Button({Name = "ตั้งจุดฟาร์ม = ตรงที่ยืนอยู่", Callback = function()
	local _, hrp = char()
	if hrp then setAnchor(hrp.Position); log("ตั้งจุดฟาร์มตรงนี้") end
end})
L:Button({Name = "ลบเส้นทางที่บันทึกไว้ (ให้บันทึกใหม่)", Callback = function()
	route, routeI = nil, nil
	pcall(function() if delfile and isfile(ROUTE_FILE) then delfile(ROUTE_FILE) end end)
	log("ลบเส้นทางแล้ว")
end})
L:Button({Name = "ล้างจุดฟาร์ม (กลับไปใช้ระยะค้นหารอบตัว)", Callback = function() setAnchor(nil); log("ล้างจุดฟาร์มแล้ว") end})
L:Dropdown({Name = "การล็อกเป้า", Multi = false, Required = true, Options = TARGET_OPTS,
	Default = idx(TARGET_OPTS, e.targetMode), Callback = function(v) e.targetMode = v; sv() end}, "PLTarget")

local Rt = FarmTab:Section({Side = "Right"})
Rt:Header({Text = "สถานะ"})
local stLbl = Rt:Label({Text = "-"})
-- Smart still learns every mob's hits in the background (e.learn); the table itself isn't shown any more
Rt:Header({Text = "ล่าสุด"})
local logLbl = Rt:Label({Text = "-"})

local BossTab = TG:Tab({Name = "Boss", Image = "rbxassetid://10723346959"})
local B = BossTab:Section({Side = "Left"})
B:Header({Text = "ล่าบอส"})
B:Toggle({Name = "บอสเกิด → ไปตีบอสก่อน แล้วกลับมาฟาร์มต่อ", Default = e.bossHunt, Callback = function(v) e.bossHunt = v; sv() end}, "PLBossHunt")
local bossDrop = B:Dropdown({Name = "└ บอสที่จะไปตี (ต้องเลือกชื่อ)", Multi = true, Required = false, Search = true, Options = bossKinds(),
	Default = (function() local d = {} for k in pairs(e.bossPick) do d[#d + 1] = k end return d end)(),
	Callback = function(v)
		local m = {}
		if type(v) == "table" then
			for k, on in pairs(v) do
				if type(k) == "string" and on == true then m[k] = true elseif type(on) == "string" then m[on] = true end
			end
		end
		e.bossPick = m; sv()
	end}, "PLBossPick")
B:Button({Name = "รีเฟรชรายชื่อบอส", Callback = function()
	pcall(function() bossDrop:ClearOptions(); bossDrop:InsertOptions(bossKinds()) end)
end})
B:Slider({Name = "└ ไปตีบอสที่อยู่ไม่เกิน (stud จากตัว/จุดฟาร์ม)", Default = e.bossRange, Minimum = 50, Maximum = 2000, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.bossRange = v; sv() end}, "PLBossRange")
B:Toggle({Name = "└ ข้ามบอสที่ตีทีเดียวตาย (ดาเมจ ≥ 90% เลือดเต็ม)", Default = e.bossSafe, Callback = function(v) e.bossSafe = v; sv() end}, "PLBossSafe")
B:Label({Text = "บอสตีแรง (Spider ~1,000/ที) · เปิด Smart หลบท่า + ถอยเลือดต่ำไว้\nTripleCobra เลือด ~1.4 ล้าน อย่าเลือกถ้าตีไม่ไหว"})
local BR = BossTab:Section({Side = "Right"})
BR:Header({Text = "เวลาเกิดบอส"})
local bossLbl = BR:Label({Text = "-"})
local function pickSet(v)
	local m = {}
	if type(v) == "table" then
		for k, on in pairs(v) do
			if type(k) == "string" and on == true then m[k] = true elseif type(on) == "string" then m[on] = true end
		end
	end
	return m
end
-- Boss signs (tag "BossSign": attrs Boss, BossAlive, BossRespawnAt = server epoch) only exist while streamed in, so
-- every time we see one we remember it (e.bossTimes, saved). A boss model alive near us = up right now. A boss we saw
-- alive and then lost without a sign telling us more -> predicted from its RespawnSeconds (Animal_Engine.Config).
if type(e.bossTimes) ~= "table" then e.bossTimes = {} end
local bossLive = {}   -- kind -> {m = model, seen = os.clock()}
if e.bossHud == nil then e.bossHud = true end
if type(e.bossHudShow) ~= "table" then e.bossHudShow = {} end   -- empty = every boss
-- on-screen box right above the game's coin counter (HUD.Holder.LeftList.YourCoins), follows it when the HUD rescales
local HUD_NAME = "PolyLootBossHud"
local hudGui, hudText
pcall(function()
	-- gethui() here is CoreGui.RobloxGui, itself a ScreenGui: a ScreenGui inside it never renders
	local root = (gethui and gethui()) or game:GetService("CoreGui")
	if root:IsA("ScreenGui") then root = root.Parent end
	local old = root:FindFirstChild(HUD_NAME)
	if old then old:Destroy() end
	hudGui = Instance.new("ScreenGui")
	hudGui.Name = HUD_NAME
	hudGui.ResetOnSpawn = false
	hudGui.IgnoreGuiInset = true
	hudGui.DisplayOrder = 5
	local f = Instance.new("Frame")
	f.Name = "Box"
	f.AnchorPoint = Vector2.new(0, 1)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
	f.BackgroundTransparency = 0.35
	f.BorderSizePixel = 0
	f.Visible = false
	f.Parent = hudGui
	Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)
	local pad = Instance.new("UIPadding", f)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
	hudText = Instance.new("TextLabel")
	hudText.BackgroundTransparency = 1
	hudText.Size = UDim2.new(1, 0, 0, 0)
	hudText.AutomaticSize = Enum.AutomaticSize.Y
	hudText.Font = Enum.Font.GothamBold
	hudText.TextSize = 16
	hudText.TextColor3 = Color3.new(1, 1, 1)
	hudText.TextStrokeTransparency = 0.5
	hudText.TextXAlignment = Enum.TextXAlignment.Left
	hudText.TextYAlignment = Enum.TextYAlignment.Top
	hudText.TextWrapped = true
	hudText.RichText = true
	hudText.Parent = f
	hudGui.Parent = root
end)
local function bossHud(text)
	if not hudGui then return end
	local f = hudGui.Box
	if not text then f.Visible = false return end
	hudText.Text = '<font color="#FFB347">⏱ เวลาเกิดบอส</font>\n' .. text
	local coins
	pcall(function() coins = plr.PlayerGui.HUD.Holder.LeftList.YourCoins end)
	if coins and coins.AbsoluteSize.X > 0 then
		-- AbsolutePosition is measured from below the top bar (any ScreenGui); our Position (IgnoreGuiInset) from the
		-- very top of the screen -> add the bar height
		local dy = game:GetService("GuiService"):GetGuiInset().Y
		f.Size = UDim2.fromOffset(math.max(coins.AbsoluteSize.X, 200), 0)
		f.Position = UDim2.fromOffset(coins.AbsolutePosition.X, coins.AbsolutePosition.Y + dy - 6)
	else
		f.Size = UDim2.fromOffset(240, 0)
		f.Position = UDim2.new(0, 18, 0, 220)
	end
	f.Visible = true
end
local function fmtLeft(s)
	s = math.max(0, math.floor(s))
	if s >= 3600 then return ("%d:%02d:%02d"):format(s // 3600, s % 3600 // 60, s % 60) end
	return ("%d:%02d"):format(s // 60, s % 60)
end
task.spawn(function()
	local lastSave = 0
	while alive() do
		pcall(function()
			local now = workspace:GetServerTimeNow()
			local changed = false
			for _, s in ipairs(CS:GetTagged("BossSign")) do
				local kind = s:GetAttribute("Boss")
				if type(kind) == "string" then
					local at = tonumber(s:GetAttribute("BossRespawnAt")) or 0
					local up = s:GetAttribute("BossAlive") == true
					local old = e.bossTimes[kind]
					if not old or old.at ~= at or old.alive ~= up then
						e.bossTimes[kind] = {at = at, alive = up, seen = now, src = "sign"}
						changed = true
					else
						old.seen = now
					end
				end
			end
			-- live boss models in range of streaming
			local liveNow = {}
			for _, f in ipairs({"Aggressors", "Passives"}) do
				local folder = AnimalLive:FindFirstChild(f)
				for _, m in ipairs(folder and folder:GetChildren() or {}) do
					if m:GetAttribute("Tier") == "Boss" and mobAlive(m) then
						local kind = tostring(m:GetAttribute("Animal") or "?")
						liveNow[kind] = m
						bossLive[kind] = {m = m, seen = os.clock()}
					end
				end
			end
			for kind, rec in pairs(bossLive) do
				if not liveNow[kind] and (not rec.m.Parent or not mobAlive(rec.m)) then
					-- it died (or despawned) in front of us: no sign around -> predict from its respawn time
					local bt = e.bossTimes[kind]
					if not bt or bt.src ~= "sign" or (now - (bt.seen or 0)) > 5 then
						local rs = 0
						pcall(function() rs = tonumber(AnimalCfg.Get(kind).RespawnSeconds) or 0 end)
						if rs > 0 then e.bossTimes[kind] = {at = now + rs, alive = false, seen = now, src = "kill"}; changed = true end
					end
					bossLive[kind] = nil
				elseif not liveNow[kind] then
					bossLive[kind] = nil   -- streamed out, still alive somewhere: keep what the sign said
				end
			end
			if changed and os.clock() - lastSave > 20 then lastSave = os.clock(); sv() end

			-- one line per boss: picked ones first, then everything we know about
			local _, hrp = char()
			local names, seenN = {}, {}
			local function add(k) if not seenN[k] then seenN[k] = true; names[#names + 1] = k end end
			local picked = {}
			for k in pairs(e.bossPick) do picked[#picked + 1] = k end
			table.sort(picked)
			for _, k in ipairs(picked) do add(k) end
			local rest = {}
			for k in pairs(e.bossTimes) do rest[#rest + 1] = k end
			for k in pairs(liveNow) do rest[#rest + 1] = k end
			table.sort(rest)
			for _, k in ipairs(rest) do add(k) end
			local lines, hud = {}, {}
			for _, k in ipairs(names) do
				local m, bt = liveNow[k], e.bossTimes[k]
				local mark = e.bossPick[k] and "★ " or ""
				local txt, short, col
				if m then
					local d = hrp and (mobPos(m) - hrp.Position).Magnitude
					txt = ("เกิดแล้ว! HP %s · ห่าง %s stud"):format(tostring(math.floor(mobHp(m))), d and ("%.0f"):format(d) or "?")
					short, col = ("เกิดแล้ว! %s stud"):format(d and ("%.0f"):format(d) or "?"), "#6CFF7A"
				elseif bt and bt.alive then
					txt = ("เกิดแล้ว (ป้ายบอก%s)"):format(now - (bt.seen or now) > 5 and (" เมื่อ " .. fmtLeft(now - bt.seen) .. " ก่อน") or "")
					short, col = "เกิดแล้ว!", "#6CFF7A"
				elseif bt and bt.at > now then
					txt = ("เกิดในอีก %s%s"):format(fmtLeft(bt.at - now), bt.src == "kill" and " (คาดจากเวลาที่ตาย)" or "")
					short, col = fmtLeft(bt.at - now) .. (bt.src == "kill" and " ~" or ""), bt.at - now < 60 and "#FFD84A" or "#FFFFFF"
				elseif bt and bt.at > 0 then
					txt = ("น่าจะเกิดแล้ว (ถึงเวลาเมื่อ %s ก่อน)"):format(fmtLeft(now - bt.at))
					short, col = "น่าจะเกิดแล้ว", "#FFD84A"
				else
					txt = "ยังไม่รู้เวลา (ต้องเคยเห็นป้ายบอส/เห็นมันตาย)"
					short, col = "?", "#9A9A9A"
				end
				lines[#lines + 1] = ("%s%s: %s"):format(mark, k, txt)
				local show = (next(e.bossHudShow) == nil or e.bossHudShow[k]) and not (e.bossHudHideUnknown and short == "?")
				if show then hud[#hud + 1] = ('%s%s  <font color="%s">%s</font>'):format(mark, k, col, short) end
			end
			pcall(function() bossHud(e.bossHud and #hud > 0 and table.concat(hud, "\n") or nil) end)
			bossLbl:UpdateName(#lines > 0 and table.concat(lines, "\n") or "ยังไม่มีข้อมูล · เดินผ่านป้ายบอสครั้งเดียวก็จำเวลาได้")
		end)
		task.wait(1)
	end
end)
BR:Header({Text = "แสดงบนจอ (เหนือช่องเหรียญ)"})
BR:Toggle({Name = "แสดงเวลาเกิดบอสบนจอ", Default = e.bossHud, Callback = function(v) e.bossHud = v; sv() end}, "PLBossHud")
local function hudOpts()
	local o, seen = {}, {}
	for _, k in ipairs(bossKinds()) do if not seen[k] then seen[k] = true; o[#o + 1] = k end end
	for k in pairs(e.bossTimes) do if not seen[k] then seen[k] = true; o[#o + 1] = k end end
	table.sort(o)
	return o
end
local hudDrop = BR:Dropdown({Name = "└ บอสที่แสดง (ไม่เลือก = ทุกตัว)", Multi = true, Required = false, Search = true, Options = hudOpts(),
	Default = (function() local d = {} for k in pairs(e.bossHudShow) do d[#d + 1] = k end return d end)(),
	Callback = function(v) e.bossHudShow = pickSet(v); sv() end}, "PLBossHudShow")
BR:Button({Name = "└ รีเฟรชรายชื่อ", Callback = function()
	pcall(function() hudDrop:ClearOptions(); hudDrop:InsertOptions(hudOpts()) end)
end})
BR:Toggle({Name = "└ ซ่อนบอสที่ยังไม่รู้เวลา (?)", Default = e.bossHudHideUnknown == true, Callback = function(v) e.bossHudHideUnknown = v; sv() end}, "PLBossHudHideUnk")

local MoveTab = TG:Tab({Name = "Movement", Image = "rbxassetid://10723346959"})
local M = MoveTab:Section({Side = "Left"})
M:Header({Text = "การเคลื่อนที่"})
M:Dropdown({Name = "วิธีเดินทาง", Multi = false, Required = true, Options = MOVE_OPTS,
	Default = idx(MOVE_OPTS, e.moveMode), Callback = function(v) e.moveMode = v; stopMove(); sv() end}, "PLMove")
M:Toggle({Name = "ปรับความเร็ววิ่งตอนฟาร์ม", Default = e.speedOn, Callback = function(v) e.speedOn = v; sv() end}, "PLSpeedOn")
M:Slider({Name = "└ ความเร็ว x เท่า (1.0 = ปกติ 20)", Default = e.speedMult, Minimum = 1, Maximum = 2, DisplayMethod = "Round", Precision = 2,
	Callback = function(v) e.speedMult = v; sv() end}, "PLSpeedMult")
M:Label({Text = "ใช้ระบบความเร็วของเกมเอง (ฟันแล้วช้าลงเหมือนเดิม)\nเซิร์ฟเวอร์เช็กความเร็ว: เกิน ~1.3 เท่า (26) อาจโดนดึงกลับ\nดูตัวเลข 'โดนดึงกลับ' ในหน้า Farm ถ้าขึ้น = ลดลง"})
M:Slider({Name = "ความเร็ว Tween (stud/วินาที)", Default = e.tweenSpeed, Minimum = 10, Maximum = 120, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.tweenSpeed = v; sv() end}, "PLTweenSpeed")
M:Slider({Name = "Teleport ไกลสุดต่อครั้ง (stud)", Default = e.tpMax, Minimum = 10, Maximum = 2000, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.tpMax = v; sv() end}, "PLTpMax")
M:Header({Text = "NavMap (แผนที่ทางเดิน)"})
local navLbl = M:Label({Text = "-"})
local function navText()
	local m = getNav()
	if not m then return "NavMap: ยังไม่มี → ใช้ Pathfinding ของ Roblox\nกดสแกนด้านล่าง (ยืนที่ไหนก็ได้ ~1-2 นาที)" end
	local c = Nav.tileCounts(m)
	return ("NavMap: %dx%d ช่อง · %d จุดยืน · ครบ %d/%d ส่วน (เติมระหว่างเล่นแล้ว %d)\nวางเส้นทางไปแล้ว %d ครั้ง (%s)"):format(
		m.w, m.h, m.nodes or 0, c["1"] + c["2"], m.tx * m.tz, st.navFilled or 0, st.navPlans or 0, tostring(st.navWhy or "-"))
end
pcall(function() navLbl:UpdateName(navText()) end)
task.spawn(function()
	while alive() do
		task.wait(2)
		pcall(function() navLbl:UpdateName(navText()) end)
	end
end)
M:Button({Name = "สแกน NavMap ใหม่ (เมือง ทุ่ง ถ้ำ)", Callback = function()
	if st.navScanning then return end
	st.navScanning = true
	task.spawn(function()
		local m, info = Nav.scan({name = NAV_NAME, alive = alive, onStatus = function(t) pcall(function() navLbl:UpdateName(t) end) end})
		if m then navMap, navTried = m, true; path.wps = nil end
		log(m and ("สแกน NavMap เสร็จ: " .. tostring(info)) or ("สแกน NavMap ไม่สำเร็จ: " .. tostring(info)))
		st.navScanning = false
	end)
end})
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
P:Toggle({Name = "Smart: ถอยเฉพาะมอนที่ตีแรง (เรียนรู้จังหวะแต่ละตัว)", Default = e.smart, Callback = function(v) e.smart = v; sv() end}, "PLSmart")
P:Slider({Name = "└ ตีแรง = โดนทีละ ≥ % ของเลือดตอนนั้น", Default = e.smartDanger, Minimum = 3, Maximum = 60, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.smartDanger = v; sv() end}, "PLSmartDanger")
P:Slider({Name = "└ ระยะถอยออกจากมอน (stud)", Default = e.smartRange, Minimum = 8, Maximum = 30, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.smartRange = v; sv() end}, "PLSmartRange")
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
K:Header({Text = "กินยา / ของกินเมื่อเลือดต่ำ"})
K:Toggle({Name = "ใช้ยา (HealthPotion)", Default = e.usePotion, Callback = function(v) e.usePotion = v; sv() end}, "PLUsePot")
K:Toggle({Name = "ใช้ของกิน (GoldenApple / Apple / ...)", Default = e.useFood, Callback = function(v) e.useFood = v; sv() end}, "PLUseFood")
K:Slider({Name = "└ กินเมื่อเลือด ≤ %", Default = e.healItemAt, Minimum = 10, Maximum = 90, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.healItemAt = v; sv() end}, "PLHealItemAt")
K:Slider({Name = "└ เว้นระหว่างกิน (วิ)", Default = e.healItemGap, Minimum = 2, Maximum = 30, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.healItemGap = v; sv() end}, "PLHealItemGap")
K:Toggle({Name = "อยู่ในวง AreaHeal จนวงหมด (7.5 วิ)", Default = e.stayInHeal, Callback = function(v) e.stayInHeal = v; sv() end}, "PLStayHeal")
K:Slider({Name = "└ เว้นจากขอบวง (stud)", Default = e.healMargin, Minimum = 0, Maximum = 12, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.healMargin = v; sv() end}, "PLHealMargin")
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
-- max = the bag's real capacity (InvLimits.GetCap, grows with bag upgrades), not a fixed 50
local disMinSl = IL:Slider({Name = "└ ย่อยเมื่อของรอย่อย ≥ (ชิ้น)", Default = e.disMin, Minimum = 1,
	Maximum = math.max(select(2, bagState(invData())) or 50, 1), DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.disMin = v; sv() end}, "PLDisMin")
task.spawn(function()
	while alive() do
		pcall(function()
			local d = invData()
			if not d then return end
			local _, cap = bagState(d)
			if cap and cap > 0 and disMinSl.Settings.Maximum ~= cap then
				disMinSl.Settings.Maximum = cap
				if e.disMin > cap then e.disMin = cap; sv() end
				disMinSl:UpdateValue(e.disMin)
			end
		end)
		task.wait(10)
	end
end)
IL:Toggle({Name = "└ หรือไปย่อยเมื่อกระเป๋าใกล้เต็ม", Default = e.disWhenFull, Callback = function(v) e.disWhenFull = v; sv() end}, "PLDisFull")
IL:Slider({Name = "    ใกล้เต็ม = เหลือช่องว่าง ≤", Default = e.bagFree, Minimum = 0, Maximum = 20, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.bagFree = v; sv() end}, "PLBagFree")
IL:Button({Name = "ขาย / ย่อยตอนนี้เลย (ตามที่ติ๊ก)", Callback = function() task.spawn(function() pcall(invPass, true) end) end})
IL:Label({Text = "เฉพาะอาวุธ + เกราะ · ไม่แตะของ Locked / ติดดาว (Favorite) / อัปเกรดแล้ว / ที่ใส่อยู่ / อาวุธเริ่มต้น\nย่อยได้เฉพาะที่โต๊ะคราฟ: ของครบจำนวนแล้วเดินไปโต๊ะใกล้สุดเอง ย่อยเสร็จกลับมาฟาร์ม\nติ๊ก Rarity เดียวกันทั้ง 2 ฝั่ง = ย่อย (ไม่ขาย)"})
local IR2 = InvTab:Section({Side = "Right"})
IR2:Header({Text = "กระเป๋า (ของที่ขาย/ย่อยได้)"})
local invLbl = IR2:Label({Text = "-"})
IR2:Header({Text = "Auto Buy (ร้าน Merchant)"})
local BUY_ITEMS = {}
pcall(function()
	local seen = {}
	for _, ent in pairs(MerchantConfig.Pool) do
		if ent.ItemId and not seen[ent.ItemId] then seen[ent.ItemId] = true; BUY_ITEMS[#BUY_ITEMS + 1] = ent.ItemId end
	end
	table.sort(BUY_ITEMS)
end)
IR2:Toggle({Name = "Auto Buy", Default = e.autoBuy, Callback = function(v) e.autoBuy = v; sv() end}, "PLBuy")
IR2:Dropdown({Name = "ของที่จะซื้อ", Multi = true, Required = false, Search = true, Options = BUY_ITEMS, Default = picked(e.buyPick),
	Callback = function(v) e.buyPick = multiSet(v); sv() end}, "PLBuyPick")
IR2:Dropdown({Name = "อาวุธ/เกราะที่ร้านขาย (ตาม Rarity)", Multi = true, Required = false, Options = {"Epic", "Legendary", "Godly"},
	Default = picked(e.buyEqRar), Callback = function(v) e.buyEqRar = multiSet(v); sv() end}, "PLBuyEq")
IR2:Slider({Name = "เก็บเหรียญไว้อย่างน้อย", Default = e.buyKeep, Minimum = 0, Maximum = 500000, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.buyKeep = v; sv() end}, "PLBuyKeep")
IR2:Toggle({Name = "└ ตอนฟาร์ม: เดินไปร้านเองเมื่อมีของที่ตั้งไว้", Default = e.buyTrip, Callback = function(v) e.buyTrip = v; sv() end}, "PLBuyTrip")
local shopLbl = IR2:Label({Text = "-"})
IR2:Button({Name = "ซื้อตอนนี้เลย (ต้องยืนที่ร้าน)", Callback = function() task.spawn(function() pcall(buyNow) end) end})
task.spawn(function()
	while alive() do
		pcall(function()
			local d = invData()
			local m = d and d.Merchant
			local lines = {}
			if m and MerchantConfig then
				for _, slot in ipairs(m.Slots or {}) do
					local ent = MerchantConfig.Get(slot.Key)
					lines[#lines + 1] = ("%s %s · %s เหรียญ · เหลือ %s"):format(tonumber(slot.Remaining) and slot.Remaining > 0 and "•" or "×",
						tostring(ent and ent.ItemId or slot.Key), tostring(ent and ent.Price or "?"), tostring(slot.Remaining))
				end
				local left = math.max(0, (tonumber(m.NextRestockAt) or 0) - os.time())
				lines[#lines + 1] = ("เหรียญ %s · รีสต็อกใน %d ชม. %d น. · ซื้อไปแล้ว %d"):format(tostring(d.Coins), left // 3600, left % 3600 // 60, st.bought or 0)
			end
			local _, hrp = char()
			local pos = merchantPos(hrp and hrp.Position)
			lines[#lines + 1] = pos and ("ร้านอยู่ห่าง %.0f stud"):format(hrp and (pos - hrp.Position).Magnitude or 0)
				or "ยังไม่รู้ตำแหน่งร้าน: เดินผ่านร้านในเมืองสักครั้ง สคริปต์จะจำเอง"
			shopLbl:UpdateName(table.concat(lines, "\n"))
		end)
		task.wait(3)
	end
end)

local StTab = TG:Tab({Name = "Stats", Image = "rbxassetid://10723346959"})
local SL = StTab:Section({Side = "Left"})
SL:Header({Text = "Auto Stats (ปิดไว้ก่อน)"})
SL:Toggle({Name = "Auto Stats (ลงแต้มที่ว่างอยู่)", Default = e.autoStats, Callback = function(v) e.autoStats = v; sv() end}, "PLStats")
SL:Label({Text = "ตั้งสัดส่วนของแต่ละสเตตัส · 0 = ไม่ลงเลย\nเช่น Damage 2 / Health 1 = ลง Damage 2 แต้มต่อ Health 1 แต้ม\nทั้งหมดเป็น 0 = ไม่ลงอะไร (รีสเตตัสเสียเงิน)"})
for _, s in ipairs(STATS) do
	SL:Slider({Name = s, Default = e.statW[s] or 0, Minimum = 0, Maximum = 10, DisplayMethod = "Round", Precision = 0,
		Callback = function(v) e.statW[s] = v; sv() end}, "PLStatW_" .. s)
end
local SR = StTab:Section({Side = "Right"})
SR:Header({Text = "สเตตัสตอนนี้"})
local statLbl = SR:Label({Text = "-"})

local RwTab = TG:Tab({Name = "Rewards", Image = "rbxassetid://10723346959"})
local RL = RwTab:Section({Side = "Left"})
RL:Header({Text = "Auto Claim (เช็กทุก 30 วิ)"})
RL:Toggle({Name = "Auto Claim Quest (Daily / Achievement / Story)", Default = e.claimQuest, Callback = function(v) e.claimQuest = v; sv() end}, "PLCQuest")
RL:Toggle({Name = "Auto Claim Index", Default = e.claimIndex, Callback = function(v) e.claimIndex = v; sv() end}, "PLCIndex")
RL:Toggle({Name = "Auto Claim Playtime", Default = e.claimPlaytime, Callback = function(v) e.claimPlaytime = v; sv() end}, "PLCPlay")
RL:Toggle({Name = "Auto Claim Daily", Default = e.claimDaily, Callback = function(v) e.claimDaily = v; sv() end}, "PLCDaily")
RL:Button({Name = "เคลมตอนนี้เลย", Callback = function() task.spawn(function() pcall(claimPass) end) end})
local RR = RwTab:Section({Side = "Right"})
RR:Header({Text = "สถานะรางวัล"})
local rwLbl = RR:Label({Text = "-"})

local SetTab = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"})
local SS = SetTab:Section({Side = "Left"})
SS:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() Win:SetState(not Win:GetState()) end) end}, "PLToggleUI")
SS:Header({Text = "Watchdog (ปล่อยทิ้งไว้ข้ามคืน)"})
SS:Toggle({Name = "Watchdog: ติดนาน → รีเซ็ตตัวละคร", Default = e.watchdog, Callback = function(v) e.watchdog = v; sv() end}, "PLWd")
SS:Slider({Name = "└ เดินกลับจุดฟาร์มไม่คืบ (วิ)", Default = e.wdTravel, Minimum = 20, Maximum = 300, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.wdTravel = v; sv() end}, "PLWdTravel")
SS:Slider({Name = "└ ไม่ได้ฆ่ามอนเลย (วิ)", Default = e.wdKill, Minimum = 60, Maximum = 900, DisplayMethod = "Round", Precision = 0,
	Callback = function(v) e.wdKill = v; sv() end}, "PLWdKill")
SS:Toggle({Name = "└ ทางสุดท้าย: รีเซ็ตตัวละคร (ตาย 1 ครั้ง)", Default = e.wdReset, Callback = function(v) e.wdReset = v; sv() end}, "PLWdReset")
SS:Label({Text = "ติด → เดินย้อนรอยเท้า 2 รอบก่อน · ยังติดอยู่ค่อยรีเซ็ต (ถ้าเปิดไว้)"})
SS:Toggle({Name = "หลุดเกม → เข้าใหม่อัตโนมัติ", Default = e.autoRejoin, Callback = function(v) e.autoRejoin = v; sv() end}, "PLRejoin")
SS:Toggle({Name = "ถืออาวุธให้อัตโนมัติ", Default = e.equip, Callback = function(v) e.equip = v; sv() end}, "PLEquip")
SS:Toggle({Name = "Anti-AFK", Default = e.antiAfk, Callback = function(v) e.antiAfk = v; sv() end}, "PLAntiAfk")
SS:Label({Text = "God Mode / Inf Damage ทำไม่ได้: ดาเมจคิดฝั่งเซิร์ฟเวอร์\nXP / เหรียญเข้าตัวตอนมอนตายเอง · ของชิ้นใช้ Instant Loot\nตั้งค่าเซฟที่: " .. SF})

task.spawn(function()
	while alive() do
		pcall(function()
			local _, _, hum = char()
			stLbl:UpdateName(table.concat({
				st.status,
				(function()
					local a = anchorPos()
					local _, hrp = char()
					local r = routeFor(a)
					return a and ("จุดฟาร์ม %.0f,%.0f,%.0f · ห่าง %.0f stud · เส้นทาง: %s"):format(a.X, a.Y, a.Z, hrp and flat(a - hrp.Position).Magnitude or 0,
						r and (#r.pts .. " จุด" .. (routeI and (" (เดินอยู่ " .. tostring(st.route) .. ")") or "")) or "ยังไม่มี (บันทึกตอนเดินมาถึงครั้งแรก)")
						or "จุดฟาร์ม: ไม่ได้ตั้ง (ใช้ระยะค้นหารอบตัว)"
				end)(),
				("ดาเมจเรา ~%d/วิ (วัดจากที่ตีจริง)"):format(st.dps or 1200),
				("เลือดเรา %s · โหมด %s · %s"):format(hum and ("%d/%d"):format(hum.Health, hum.MaxHealth) or "-", e.moveMode, e.pattern),
				("ฆ่า %d · เก็บของ %d · สกิล %d · หลบ %d · ถอย Smart %d · โดนดึงกลับ %d"):format(st.kills, st.loots, st.skills, st.dodges, st.evades or 0, st.snaps),
				"อาวุธ: " .. tostring(st.weapon or "-"),
				("Watchdog: %s · ย้อนรอย %d · รีเซ็ต %d"):format(tostring(st.wd or "-"), st.backtracks or 0, st.resets or 0),
				("ตาย %d · กินยา/ของกิน %d%s"):format(st.deaths or 0, st.heals or 0, (e.deathLog or {})[1] and ("\nตายล่าสุด " .. e.deathLog[1]) or ""),
			}, "\n"))
			logLbl:UpdateName(#st.last > 0 and table.concat(st.last, "\n") or "-")
			local sk = {}
			for _, name in ipairs(equippedSkills()) do
				local left = (skillCd[name] or 0) - os.clock()
				sk[#sk + 1] = ("%s · %s"):format(name, left > 0 and ("คูลดาวน์ %.0f วิ"):format(left) or "พร้อม")
			end
			skLbl:UpdateName(#sk > 0 and table.concat(sk, "\n") or "ไม่มีสกิลในช่อง")
			local d = invData()
			if d then
				local rw = d.Rewards or {}
				local pt, dl = rw.Playtime or {}, rw.Daily or {}
				local nClaimed = 0
				for _ in pairs(pt.Claimed or {}) do nClaimed += 1 end
				local left = (tonumber(dl.NextDailyAt) or 0) - os.time()
				rwLbl:UpdateName(("Playtime: รับแล้ว %d ขั้น · เล่นมา %d นาที\nDaily: streak %s · %s\nเคลมรอบนี้ %d"):format(nClaimed,
					math.floor((tonumber(pt.Accrued) or 0) / 60), tostring(dl.Streak or 0),
					left > 0 and ("รอบหน้าอีก %dชม %dนาที"):format(left // 3600, (left % 3600) // 60) or "พร้อมรับ", st.claims or 0))
				local up = d.Upgrades or {}
				statLbl:UpdateName(("Damage %d · Health %d · Defense %d\nแต้มว่าง %d · เลเวล %s\nลงไปรอบนี้ %d แต้ม"):format(tonumber(up.Damage) or 0,
					tonumber(up.Health) or 0, tonumber(up.Defense) or 0, freePoints(d), tostring(d.Level), st.statsSpent or 0))
			end
			if os.clock() % 3 < 0.5 then
				local cnt = {}
				for _, c in ipairs(candidates()) do cnt[c.rarity] = (cnt[c.rarity] or 0) + 1 end
				local lines = {}
				for _, r in ipairs(RARITIES) do
					if cnt[r] then
						lines[#lines + 1] = ("%s: %d%s"):format(r, cnt[r], (e.dismantle and e.disRar[r]) and " → ย่อย" or (e.sell and e.sellRar[r]) and " → ขาย" or "")
					end
				end
				local used, cap = bagState(d)
				lines[#lines + 1] = ("กระเป๋า %d/%d ช่อง"):format(used, cap)
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
	mover.walk = nil
	setControls(true)
	pcall(function() local _, _, hum = char(); if hum then hum:SetAttribute("_WSMultC_PolyLoot", nil) end end)
	pcall(function() local _, _, hum = char(); if hum then hum.AutoRotate = true; hum:Move(Vector3.zero) end end)
	pcall(function() if hudGui then hudGui:Destroy() end end)
end)
pcall(function()
	Win.onUnloaded(function() if getgenv().__PLOOT == G then getgenv().__PLOOT = G + 1 end end)
end)
pcall(function() local c = plr.Character; local t = c and c:FindFirstChildOfClass("Tool"); if t then st.weapon = t.Name end end)
FarmTab:Select()
