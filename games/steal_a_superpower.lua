-- [⚡] Steal a Superpower! (placeId 74183246285569) -- Boss loop (warp to a picked boss, Auto Attack kills it, packs come
-- home with you) <-> training on the bench, + Auto Open Packs, Auto Rebirth, Auto Upgrade Train, Auto Place Best Cards.
-- MacLib window, RightShift toggles it, settings persist (StealSuperpower/state_<userId>.json).
--
-- How the game works (verified 2026-11-21):
--   Enemies are simulated on the client (LocalEnemies controller). Pads live in ReplicatedStorage.EnemyPads (attrs
--   Enemy / Gate / PadCFrame / RespawnTime); the controller's pad table (upvalue of readPad) keeps Due (waiting to spawn)
--   and Alive per pad for every pad, near or far, and spawns a pad's enemy once you're within ~380 studs of it.
--   A local kill is reported by the game itself (Remotes.EnemyKill). Boss loot = packs that fly onto your carry stack;
--   they are claimed when you stand in the lobby SafeZone (your base is inside it).
--   The game's own Auto Attack setting (SettingsController "AutoAttack") casts your primary card on the nearest enemy in
--   range, except while lifting. Bench: Plot<Base>.Bench (LiftPrompt / UpgradePrompt -- never the RobuxUpgradePrompt),
--   getting up = the game's JumpRequest handler. BestButton.Press.BestPrompt places the best cards on the holders.
--   Remotes.Rebirth:InvokeServer() once PowerConfig.Level(Power) >= Progression.RebirthLevelRequirement(Rebirths).
--   Remotes.OpenAllPacks:InvokeServer() opens every unopened pack.

getgenv().__SSP = (getgenv().__SSP or 0) + 1
local G = getgenv().__SSP
pcall(function() if getgenv().__SSPW then getgenv().__SSPW:Unload() end end)
local function alive() return getgenv().__SSP == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local CS = game:GetService("CollectionService")
local UIS = game:GetService("UserInputService")
local plr = Players.LocalPlayer

local Remotes = RS:WaitForChild("Remotes")
local PlayerState = require(RS.Client.Core.PlayerState)
local LocalEnemies = require(RS.Client.Controllers.LocalEnemies)
local SettingsCtl = require(RS.Client.Controllers.SettingsController)
local EnemyConfig = require(RS.Shared.Config.EnemyConfig)
local ZoneConfig = require(RS.Shared.Config.ZoneConfig)
local PowerConfig = require(RS.Shared.Config.PowerConfig)
local BaseConfig = require(RS.Shared.Config.BaseConfig)
local Progression = require(RS.Shared.Rules.Progression)
local Big = require(RS.Shared.Util:WaitForChild("Big"))

-- ------------------------------------------------------------------ settings
local SF = ("StealSuperpower/state_%d.json"):format(plr.UserId)
local DEFAULTS = {boss = false, bosses = {}, waitAll = true, train = true, openPacks = false, rebirth = false, upgradeTrain = false, merge = false,
	placeBest = false, instaKill = false, mobFarm = false, mobZones = false, autoSacrifice = false, autoTree = false, autoAscend = false, godMode = false, autoSkill = true, pierce = true, autoPotion = false, potionTypes = false, potionTiers = false, pauseOnMove = true, antiAfk = true, reconnect = true}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
local function sv()
	pcall(function()
		if makefolder and not isfolder("StealSuperpower") then makefolder("StealSuperpower") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

local st = {status = "-", boss = "-", kills = 0, opened = 0, rebirths = 0, upgrades = 0, placed = 0, wd = "-", err = "-"}

-- ------------------------------------------------------------------ helpers
local function D() return PlayerState.Data end
getgenv().__SSPDBG = {e = e, st = st}   -- read-only peek for debugging from the executor
local function hum() local c = plr.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function hrp() local c = plr.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local function short(n)
	local ok, s = pcall(function() return require(RS.Shared.Util:FindFirstChild("Format")).Short(n) end)
	return ok and s or tostring(n)
end

local lastMove = 0
local MOVE_KEYS = {}
for _, k in ipairs({"W", "A", "S", "D", "Up", "Down", "Left", "Right"}) do MOVE_KEYS[Enum.KeyCode[k]] = true end
task.spawn(function()
	while alive() do
		if not UIS:GetFocusedTextBox() then
			for k in pairs(MOVE_KEYS) do if UIS:IsKeyDown(k) then lastMove = os.clock() break end end
		end
		task.wait(0.1)
	end
end)
local function busyHands()
	local h = hum()
	if not h or not hrp() or h.Health <= 0 then return "ไม่มีตัวละคร (รอเกิดใหม่)" end
	if e.pauseOnMove and os.clock() - lastMove < 3 then return "คุณกำลังเดินเอง" end
	if plr:GetAttribute("InCutscene") then return "คัตซีน" end
	return nil
end

local function warp(pos, lookAt)
	local r = hrp()
	if not r then return end
	r.Anchored = false
	r.AssemblyLinearVelocity = Vector3.zero
	r.CFrame = lookAt and CFrame.lookAt(pos, Vector3.new(lookAt.X, pos.Y, lookAt.Z)) or CFrame.new(pos)
end

local function loopEvery(name, period, limit, body)
	task.spawn(function()
		while alive() do
			local done = false
			local th = task.spawn(function()
				local ok, err = pcall(body)
				if not ok then st.err = name .. ": " .. tostring(err):sub(1, 110) end
				done = true
			end)
			local t0 = os.clock()
			while not done and alive() and os.clock() - t0 < limit do task.wait(0.05) end
			if not done then
				pcall(task.cancel, th)
				st.wd = ("%s ค้างเกิน %d วิ → ตัดแล้วเริ่มใหม่ · %s"):format(name, limit, os.date("%H:%M:%S"))
			end
			task.wait(period)
		end
	end)
end

local function firePrompt(p)
	if not p then return false end
	if fireproximityprompt then
		return pcall(fireproximityprompt, p)
	end
	return pcall(function() p:InputHoldBegin(); task.wait(p.HoldDuration + 0.05); p:InputHoldEnd() end)
end

-- ------------------------------------------------------------------ base / bench
local function myPlot()
	local b = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Bases")
	return b and b:FindFirstChild("Plot" .. tostring(plr:GetAttribute("Base")))
end
local function benchParts()
	local plot = myPlot()
	local bench = plot and plot:FindFirstChild("Bench")
	if not bench then return end
	local lie = bench:FindFirstChild("LiePoint", true)
	local lift = bench:FindFirstChild("LiftPrompt", true)
	local up = bench:FindFirstChild("UpgradePrompt", true)   -- the cash one; RobuxUpgradePrompt is never touched
	return lie, lift, up
end
local function lifting() return plr:GetAttribute("Lifting") == true or plr:GetAttribute("LiftingLocal") == true end
local function getUp()
	if not lifting() then return true end
	-- the game's own "get up" runs from UserInputService.JumpRequest
	for _, c in ipairs(getconnections and getconnections(UIS.JumpRequest) or {}) do pcall(function() c:Fire() end) end
	local t0 = os.clock()
	while lifting() and os.clock() - t0 < 2 do task.wait(0.1) end
	if lifting() then
		pcall(function() Remotes.BenchStop:FireServer() end)
		local r = hrp()
		if r then r.Anchored = false end
		plr:SetAttribute("LiftingLocal", nil)
		task.wait(0.5)
	end
	return not lifting()
end
local function trainStep()
	if lifting() then st.status = "กำลัง train บนเบนช์"; return end
	local lie, lift = benchParts()
	if not (lie and lift) then
		pcall(function() Remotes.TeleportHome:FireServer() end)
		task.wait(1.5)
		lie, lift = benchParts()
		if not (lie and lift) then st.status = "หาเบนช์ไม่เจอ"; return end
	end
	warp(lie.Position + Vector3.new(0, 3, 0))
	task.wait(0.3)
	firePrompt(lift)
	task.wait(1)
	st.status = lifting() and "กำลัง train บนเบนช์" or "กด Lift แล้ว รอเกมตอบ"
end

-- ------------------------------------------------------------------ bosses
local PADS_TABLE
local function padTable()
	if PADS_TABLE then return PADS_TABLE end
	for _, v in pairs(debug.getupvalues(LocalEnemies.Start)) do
		if type(v) == "function" and debug.info(v, "n") == "readPad" then
			for _, t in pairs(debug.getupvalues(v)) do
				if type(t) == "table" then
					local _, first = next(t)
					if type(first) == "table" and first.Due ~= nil then PADS_TABLE = t end
				end
			end
		end
	end
	return PADS_TABLE
end
local BOSSES = {}   -- ordered list {padId, name, gate, level, at}
do
	for _, cfg in ipairs(RS:WaitForChild("EnemyPads"):GetChildren()) do
		local enemy = cfg:GetAttribute("Enemy")
		local ec = (EnemyConfig.Types and EnemyConfig.Types[enemy]) or EnemyConfig[enemy] or (EnemyConfig.Enemies and EnemyConfig.Enemies[enemy])
		local isBoss = (cfg:GetAttribute("Count") == 1 and cfg:GetAttribute("Gate") ~= nil) or (ec and ec.Boss)
		local pcf = cfg:GetAttribute("PadCFrame")
		if isBoss and typeof(pcf) == "CFrame" then
			BOSSES[#BOSSES + 1] = {padId = tonumber(cfg.Name) or cfg.Name, enemy = enemy, gate = cfg:GetAttribute("Gate"),
				level = cfg:GetAttribute("Level") or 0, at = pcf.Position, name = cfg:GetAttribute("Name") or enemy,
				-- the in-game nameplate ("Doomsekkar", "The Grand Pumpkin"); the pad Name ("RuneVault Boss") stays the save key
				display = (type(ec) == "table" and type(ec.Name) == "string" and ec.Name ~= "") and ec.Name or cfg:GetAttribute("Name") or enemy}
		end
	end
	table.sort(BOSSES, function(a, b) return a.level < b.level end)
end
-- PlayerState.Data.Gates[gate] = true once that zone's boss is BEATEN (PlaceConfig.beaten counts them), so the next
-- zone's door is open as soon as the boss before it is beaten (user 2026-11-22: Empyrean showed locked but he gets in)
local function gateOpen(b)
	local d = D()
	local gates = d and d.Gates or {}
	if b.gate == nil or b.gate == "Tutorial" or gates[b.gate] == true then return true end
	for i, x in ipairs(BOSSES) do
		if x == b then return i == 1 or gates[BOSSES[i - 1].gate] == true end
	end
	return false
end
-- a boss the army can't kill would eat every sweep (and the character): after a losing fight it is skipped a while
local tooStrong = {}   -- name -> os.clock() until which it is skipped
local function skipped(b) return (tooStrong[b.name] or 0) > os.clock() end
-- short on purpose: the dropdown cuts anything past ~28 characters, and the boss name already says the zone
local function bossLabel(b)
	return ("Lv %d · %s%s"):format(b.level, b.display, gateOpen(b) and "" or " (ล็อก)")
end
local function padState(b)
	local pads = padTable()
	local p = pads and (pads[b.padId] or pads[tostring(b.padId)])
	if not p then return "?" end
	if (p.Alive or 0) > 0 or (p.Due or 0) > 0 then return "alive" end
	return "dead"
end
local function bossModel(b)
	local f = workspace:FindFirstChild("Enemies")
	for _, m in ipairs(f and f:GetChildren() or {}) do
		if m:GetAttribute("PadId") == b.padId and m:GetAttribute("Boss") and not m:GetAttribute("Dead") and not m:GetAttribute("DeadLocal") then
			return m
		end
	end
end
local function pickBoss()
	for i = #BOSSES, 1, -1 do   -- strongest picked boss first
		local b = BOSSES[i]
		if table.find(e.bosses, b.name) and gateOpen(b) and not skipped(b) and padState(b) == "alive" then return b end
	end
end

local function ensureAutoAttack()
	local ok, on = pcall(SettingsCtl.Get, "AutoAttack")
	if ok and not on then pcall(SettingsCtl.Set, "AutoAttack", true) end
end

-- God Mode: enemies are simulated on this client and every hit on me is computed here and then REPORTED by the client
-- (LocalEnemyAbilities' local hurt() -> Remotes.EnemyHurtMe "Hit", stunMe() -> "Stun"). Those two Lua functions are
-- hooked directly (hookfunction), NOT through a game-wide __namecall hook: a namecall hook routes every method call the
-- game makes through executor code, and the executor then blacklists the game's own Robux purchase prompts ("This
-- function has been disabled/blacklisted for security reasons" -- user 2026-11-23 couldn't buy with Robux).
-- Installed once per session; getgenv().__SSPGOD3 (mirrors e.godMode) decides whether a hit is swallowed.
if not getgenv().__SSPGODHOOK3 and hookfunction and getgc then
	local hurtF, stunF
	for _, f in ipairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) then
			local ok, src = pcall(debug.info, f, "s")
			-- compare the tail: a plain string.find on this source returned nothing in this executor
			if ok and type(src) == "string" and src:sub(-19) == "LocalEnemyAbilities" then
				local n = debug.info(f, "n")
				if n == "hurt" then hurtF = f elseif n == "stunMe" then stunF = f end
			end
		end
	end
	if hurtF and stunF then
		getgenv().__SSPGODHOOK3 = true
		local oldHurt, oldStun
		oldHurt = hookfunction(hurtF, function(...)
			if getgenv().__SSPGOD3 then getgenv().__SSPGODN = (getgenv().__SSPGODN or 0) + 1; return end
			return oldHurt(...)
		end)
		oldStun = hookfunction(stunF, function(...)
			if getgenv().__SSPGOD3 then return false, 0 end
			return oldStun(...)
		end)
	end
end
getgenv().__SSPGOD = false   -- the old namecall version's flag (sessions that still carry it stop dropping reports)
task.spawn(function()
	while alive() do getgenv().__SSPGOD3 = e.godMode == true; task.wait(0.2) end
	getgenv().__SSPGOD3 = false
end)

-- Auto Skill: the game's own Auto Attack only fires the primary (M1). The E / F skills go through AbilityController's
-- local use(slot, auto, auto, targetPos) -- the same function the key binds and Auto Attack call; it checks cooldowns
-- itself and, with auto = true, stays quiet when a skill isn't ready. Slots = the `bind` closure's upvalue table
-- {[1] = {Card, Id, Key}, [2] = ...} (index 1 = E, 2 = F; locked MERGE slots are simply absent).
local abilityUse, abilitySlots
local function findAbilities()
	if abilityUse and abilitySlots then return true end
	local bindF
	for _, f in ipairs(getgc and getgc(false) or {}) do
		if type(f) == "function" and islclosure(f) then
			local ok, src = pcall(debug.info, f, "s")
			if ok and src and src:find("AbilityController", 1, true) then
				local n = debug.info(f, "n")
				if n == "use" then abilityUse = f elseif n == "bind" then bindF = f end
			end
		end
	end
	for _, v in pairs(bindF and debug.getupvalues(bindF) or {}) do
		if type(v) == "table" then
			local _, first = next(v)
			if type(first) == "table" and first.Id and first.Card then abilitySlots = v end
		end
	end
	return abilityUse ~= nil and abilitySlots ~= nil
end
-- Attacks through buildings: the hero combat code (Shared.Combat.BasicHeroCombat & co.) casts a ray from the character
-- along the attack (RespectCanCollide, Exclude = {character, workspace.Enemies, ...}) and cuts the attack's reach at the
-- first wall it meets (`Distance = hit.Distance`) -- so a boss behind a pillar / house never gets hit (user 2026-11-22).
-- Those sideways combat rays (caller source = a Shared.Combat.* module, debug.info level 3) report "no wall".
-- workspace:Raycast is a method call, so this one needs a __namecall hook -- which also makes the executor block the
-- game's Robux purchase prompts. So the hook exists ONLY while the toggle is on: switching it off (or unloading the
-- script) restores the previous __namecall, and Robux purchases work again.
getgenv().__SSPPIERCE, getgenv().__SSPPIERCE2 = false, false   -- older builds' flags (their hooks pass everything through)
local function pierceInstall()
	local G = getgenv()
	if G.__SSPPIERCE3 or not (hookmetamethod and getnamecallmethod) then return end
	local orig
	orig = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		if self == workspace and not checkcaller() and getnamecallmethod() == "Raycast" then
			local _, dir, params = ...
			if typeof(dir) == "Vector3" and math.abs(dir.Y) < dir.Magnitude * 0.5 and typeof(params) == "RaycastParams"
				and params.RespectCanCollide and params.FilterType == Enum.RaycastFilterType.Exclude then
				local ok, src = pcall(debug.info, 3, "s")   -- 2 = this [C] call, 3 = the Lua function that cast the ray
				if ok and type(src) == "string" and src:find("Shared.Combat.", 1, true) then
					G.__SSPPIERCEN = (G.__SSPPIERCEN or 0) + 1
					return nil
				end
			end
		end
		return orig(self, ...)
	end))
	G.__SSPPIERCE3 = orig
end
local function pierceRemove()
	local G = getgenv()
	local orig = G.__SSPPIERCE3
	if not orig then return end
	G.__SSPPIERCE3 = nil
	pcall(hookmetamethod, game, "__namecall", orig)
end
task.spawn(function()
	while alive() do
		if e.pierce then pierceInstall() else pierceRemove() end
		task.wait(0.3)
	end
	pierceRemove()
end)
local lastSkill = 0
local function castSkills(target)
	if not e.autoSkill or os.clock() - lastSkill < 0.25 or not findAbilities() then return end
	lastSkill = os.clock()
	for _, slot in pairs(abilitySlots) do
		if type(slot) == "table" and slot.Id then
			local ok = pcall(abilityUse, slot, true, true, target)
			if not ok then abilityUse, abilitySlots = nil, nil; return end   -- controller rebuilt: look it up again next time
		end
	end
end

-- Instant Kill (user 2026-11-23): enemies are simulated here; LocalEnemies.Damage(model, amount) takes
-- amount / HealthUnit off the local Humanoid and, at 0, the game's own die() fires Remotes.EnemyKill(padId, seq, golden,
-- pos) -- the server only gets that kill report, no damage numbers. One Damage call worth the whole health bar kills it
-- through the normal path (phases, rewards, packs). Verified: a Lv 1451 mob 249 studs away and Eerie Pumpkin Head
-- (Lv 1640, untouchable by normal hits) both died at once and paid out (packs, EnemyReward, Gates.DeepSanctum).
local LocalEnemiesMod = LocalEnemies
local function instaKill(m)
	local h = m and m:FindFirstChildOfClass("Humanoid")
	if not h or h.Health <= 0 or m:GetAttribute("Dead") or m:GetAttribute("DeadLocal") then return false end
	local unit = EnemyConfig.HealthUnit and EnemyConfig.HealthUnit(m) or 1
	local ok = pcall(LocalEnemiesMod.Damage, m, h.Health * unit * 1.01 + 1)
	if ok then st.instaKills = (st.instaKills or 0) + 1 end
	return ok
end

local function fightBoss(b)
	if not getUp() then st.status = "ลุกจากเบนช์ไม่ได้"; return end
	ensureAutoAttack()
	st.status = "วาร์ปไปหา " .. b.display
	warp(b.at + Vector3.new(0, 6, 25), b.at)
	local t0 = os.clock()
	local m
	while alive() and os.clock() - t0 < 8 do
		m = bossModel(b)
		if m then break end
		task.wait(0.1)
	end
	if not m then st.status = b.display .. " ไม่โผล่ (มีคนตีไปแล้ว?)"; task.wait(0.2); return end
	t0 = os.clock()
	local h0 = m:FindFirstChildOfClass("Humanoid")
	local hp0 = h0 and h0.Health
	local function giveUp(why)
		tooStrong[b.name] = os.clock() + 900
		st.status = ("%s ตีไม่ไหว (%s) → ข้ามตัวนี้ 15 นาที"):format(b.display, why)
	end
	local limit = e.godMode and 600 or 90   -- nothing can hurt us in God Mode, so a slow kill is still a kill
	while alive() and e.boss and m.Parent and not m:GetAttribute("Dead") and not m:GetAttribute("DeadLocal") and os.clock() - t0 < limit do
		local me = hum()
		if not me or me.Health <= 0 then giveUp("ตัวละครตาย"); return end
		if busyHands() then st.status = "พัก: " .. busyHands(); return end
		-- after 15 s: at this rate would it take more than 90 s? then it's out of reach for now
		local hn = m:FindFirstChildOfClass("Humanoid")
		if hp0 and hn and os.clock() - t0 > 15 then
			local rate = (hp0 - hn.Health) / (os.clock() - t0)
			if (rate <= 0 and os.clock() - t0 > (e.godMode and 40 or 15)) or (rate > 0 and hn.Health / rate > limit) then giveUp("เลือดบอสลดช้าเกิน"); return end
		end
		local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
		if root then
			local r = hrp()
			local flat = r and (r.Position - root.Position) * Vector3.new(1, 0, 1)
			local dir = (flat and flat.Magnitude > 1) and flat.Unit or Vector3.new(0, 0, 1)
			if not r or (r.Position - root.Position).Magnitude > 14 then
				warp(root.Position + dir * (root.Size.X / 2 + 6), root.Position)
			end
			castSkills(root.Position)
		end
		if e.instaKill then instaKill(m) end
		local h = m:FindFirstChildOfClass("Humanoid")
		st.boss = ("%s · HP %s / %s"):format(b.display, h and short(h.Health) or "?", h and short(h.MaxHealth) or "?")
		st.status = "กำลังตี " .. b.display .. " (Auto Attack ของเกม)"
		task.wait(0.3)
	end
	if not m.Parent or m:GetAttribute("Dead") or m:GetAttribute("DeadLocal") then
		st.kills += 1
		st.needBank = true
		st.lastKill = b.display .. " · " .. os.date("%H:%M:%S")
		-- no standing around (user 2026-11-22): the packs fly to the character wherever it goes and are claimed in the
		-- lobby safe zone anyway, so go straight on to the next boss / the bench
		st.status = b.display .. " ตายแล้ว → ไปต่อเลย"
		task.wait(0.15)
	end
end

-- ------------------------------------------------------------------ mob farming (user 2026-11-22: in the later worlds the
-- bench barely levels you, killing mobs does). Every zone = 3 camps of 4 mobs (respawn 8 s) and then its boss pad; a camp
-- belongs to the first boss above it in level, and is reachable exactly when that boss is (gateOpen). Packs that drop
-- ride on the character (Data.Carried, CarryCapacity attr) and are banked in the lobby safe zone -> TeleportHome when full.
local CAMPS = {}   -- {padId, name, level, at, zone = boss}
do
	for _, cfg in ipairs(RS:WaitForChild("EnemyPads"):GetChildren()) do
		local pcf = cfg:GetAttribute("PadCFrame")
		local isBoss = false
		for _, b in ipairs(BOSSES) do if b.padId == (tonumber(cfg.Name) or cfg.Name) then isBoss = true end end
		if not isBoss and typeof(pcf) == "CFrame" and (cfg:GetAttribute("Count") or 1) > 1 then
			local lvl = cfg:GetAttribute("Level") or 0
			local zone
			for _, b in ipairs(BOSSES) do if b.level >= lvl then zone = b; break end end
			if zone then
				CAMPS[#CAMPS + 1] = {padId = tonumber(cfg.Name) or cfg.Name, name = cfg:GetAttribute("Name") or cfg.Name, level = lvl, at = pcf.Position, zone = zone}
			end
		end
	end
	table.sort(CAMPS, function(a, b) return a.level < b.level end)
end
local function zoneKey(b) return tostring(b.gate or b.name) end
local function campMobs(c)
	local out = {}
	local f = workspace:FindFirstChild("Enemies")
	for _, m in ipairs(f and f:GetChildren() or {}) do
		if m:GetAttribute("PadId") == c.padId and not m:GetAttribute("Dead") and not m:GetAttribute("DeadLocal") then
			local h = m:FindFirstChildOfClass("Humanoid")
			if not h or h.Health > 0 then out[#out + 1] = m end
		end
	end
	return out
end
local function farmZones()
	-- picks saved in another world (e.g. "DeepSanctum" from World 3 while in World 4) match nothing here -> fall back
	local anyHere = false
	if type(e.mobZones) == "table" then
		for _, z in ipairs(e.mobZones) do
			for _, b in ipairs(BOSSES) do if zoneKey(b) == z then anyHere = true end end
		end
	end
	if not anyHere then
		-- nothing picked: the highest zone that is open
		local best
		for _, b in ipairs(BOSSES) do if gateOpen(b) then best = b end end
		return best and {[zoneKey(best)] = true} or {}
	end
	local set = {}
	for _, z in ipairs(e.mobZones) do set[z] = true end
	return set
end
local farmCamp
-- a camp just cleared still reads "alive" in the pad table for a moment; remember it as empty so the next pick goes
-- straight to another camp instead of standing there (user 2026-11-23: warping between camps was too slow)
local campEmptyUntil = {}   -- padId -> os.clock()
-- "end the run" = go home: packs riding on the character are banked in the lobby safe zone. Done right after a boss
-- sweep (st.needBank) and before the carry fills -- a pack that drops while the carry is full is lost (user 2026-11-22:
-- "ตีบอสเสร็จ end run ก่อนแล้วค่อยมาฟามมอน ... การ์ดเต็ม = ไม่ได้การ์ด").
local CARRY_SPARE = 3
-- what rides on the character is the player attribute CarriedPacks ("1294:Abyss;1309:Abyss;..."), NOT Data.Carried
-- (that one stays empty -- the first version read it and never went home, user: "การ์ดเต็มยังไม่เห็น end run")
local function carriedCount()
	local raw = plr:GetAttribute("CarriedPacks")
	if type(raw) ~= "string" or raw == "" then return 0 end
	local n = 0
	for _ in raw:gmatch("[^;]+") do n += 1 end
	return n
end
local function bankPacks()
	local carried = carriedCount()
	local cap = tonumber(plr:GetAttribute("CarryCapacity")) or 0
	if carried == 0 then st.needBank = false; return false end
	local full = cap > 0 and carried >= math.max(1, cap - CARRY_SPARE)
	if not st.needBank and not full then return false end
	st.status = st.needBank and ("ตีบอสเสร็จ → กลับบ้านจบรอบ ให้แพ็ค %d ใบเข้าบัญชีก่อน"):format(carried)
		or ("แพ็คใกล้เต็ม (%d/%d) → กลับบ้านให้แพ็คเข้าบัญชี"):format(carried, cap)
	-- Remotes.TeleportHome only works from a boss arena's home portal; out in the zones it does nothing, so warp to the
	-- player's base spawn (attr BaseSpawn, inside the lobby safe zone) like the bench trip does
	getUp()
	local spawnCF = plr:GetAttribute("BaseSpawn")
	if typeof(spawnCF) == "CFrame" then warp(spawnCF.Position + Vector3.new(0, 3, 0)) else pcall(function() Remotes.TeleportHome:FireServer() end) end
	local t0 = os.clock()
	while alive() and os.clock() - t0 < 10 and carriedCount() > 0 do task.wait(0.25) end
	if carriedCount() == 0 then st.banked = (st.banked or 0) + 1; st.lastBank = os.date("%H:%M:%S") end
	st.needBank = false
	farmCamp = nil
	return true
end
local function farmStep()
	if not getUp() then st.status = "ลุกจากเบนช์ไม่ได้"; return end
	if bankPacks() then return end
	ensureAutoAttack()
	local zones = farmZones()
	-- stay on the current camp while it still has mobs, otherwise the nearest camp (in a picked open zone) with mobs up
	local r = hrp()
	if farmCamp and padState(farmCamp) ~= "alive" then farmCamp = nil end
	if not farmCamp then
		local best, bd
		for _, c in ipairs(CAMPS) do
			if zones[zoneKey(c.zone)] and gateOpen(c.zone) and padState(c) == "alive" and (campEmptyUntil[c.padId] or 0) < os.clock() then
				local dist = r and (r.Position - c.at).Magnitude or 0
				if not bd or dist < bd then best, bd = c, dist end
			end
		end
		farmCamp = best
	end
	if not farmCamp then st.status = "ฟาร์มมอน: รอมอนในโซนที่เลือกเกิด (เกิดใหม่ทุก 8 วิ)"; task.wait(0.15); return end
	local c = farmCamp
	local fresh = not r or (r.Position - c.at).Magnitude > 60
	if fresh then warp(c.at + Vector3.new(0, 6, 14), c.at); task.wait(0.05) end
	local mobs = campMobs(c)
	local t0 = os.clock()
	-- only a camp we just warped to gets a moment for its mobs to spawn/stream in
	while #mobs == 0 and fresh and alive() and os.clock() - t0 < 1 do task.wait(0.05); mobs = campMobs(c) end
	if #mobs == 0 then campEmptyUntil[c.padId] = os.clock() + 3; farmCamp = nil; return end
	r = hrp()
	local target, td
	for _, m in ipairs(mobs) do
		local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
		if root and r then
			local dd = (root.Position - r.Position).Magnitude
			if not td or dd < td then target, td = m, dd end
		end
	end
	if not target then return end
	if e.instaKill then
		-- the whole camp in one go; Damage works at range, the mobs only have to be spawned (we are at the camp)
		local n = 0
		for _, mob in ipairs(mobs) do if instaKill(mob) then n += 1 end end
		st.mobKills = (st.mobKills or 0) + n
		st.status = ("ฟาร์มมอน (Instant Kill): %s · ฆ่า %d ตัว"):format(c.name, n)
		campEmptyUntil[c.padId] = os.clock() + 1.5
		farmCamp = nil
		task.wait(0.1)
		return
	end
	local root = target:FindFirstChild("HumanoidRootPart") or target.PrimaryPart
	local t1 = os.clock()
	while alive() and e.mobFarm and target.Parent and not target:GetAttribute("Dead") and not target:GetAttribute("DeadLocal") and os.clock() - t1 < 25 do
		if busyHands() then return end
		local me = hum()
		if not me or me.Health <= 0 then farmCamp = nil; return end
		r = hrp()
		if root and r and (r.Position - root.Position).Magnitude > 10 then
			local flat = (r.Position - root.Position) * Vector3.new(1, 0, 1)
			local dir = flat.Magnitude > 1 and flat.Unit or Vector3.new(0, 0, 1)
			warp(root.Position + dir * (root.Size.X / 2 + 4), root.Position)
		end
		if root then castSkills(root.Position) end
		st.status = ("ฟาร์มมอน: %s · เหลือ %d ตัว"):format(c.name, #campMobs(c))
		task.wait(0.08)
	end
	st.mobKills = (st.mobKills or 0) + ((not target.Parent or target:GetAttribute("Dead") or target:GetAttribute("DeadLocal")) and 1 or 0)
end

-- ------------------------------------------------------------------ main loop: boss when one is up, bench otherwise
loopEvery("Boss/Train", 0.1, 150, function()
	local why = busyHands()
	if why then st.status = "พัก: " .. why; return end
	if e.boss and #e.bosses > 0 then
		-- wait-for-all: stay on the bench until every picked (unlocked) boss is up, then clear them in one trip
		local want, up = 0, 0
		for _, b in ipairs(BOSSES) do
			if table.find(e.bosses, b.name) and gateOpen(b) and not skipped(b) then
				want += 1
				if padState(b) == "alive" then up += 1 end
			end
		end
		st.ready = ("บอสเกิดแล้ว %d / %d"):format(up, want)
		if want > 0 and (not e.waitAll or up >= want or st.sweeping) then
			local b = pickBoss()
			if b then
				-- bank before the next boss when the carry is (nearly) full, mob farm on or not -- the packs of every boss
				-- after that point were simply lost (user 2026-11-23: "การ์ดเต็มไม่ endrun", 23/23 mid-sweep)
				local cap = tonumber(plr:GetAttribute("CarryCapacity")) or 0
				if cap > 0 and carriedCount() >= math.max(1, cap - CARRY_SPARE) then
					local keep = st.needBank
					st.needBank = false
					bankPacks()
					st.needBank = keep and carriedCount() > 0
					return
				end
				st.sweeping = true
				return fightBoss(b)
			end
		end
		st.sweeping = false
	end
	if st.needBank and carriedCount() > 0 and not e.mobFarm then
		-- sweep done and no mob farm: end the run (the bench is in the safe zone, but Auto Train may be off)
		if bankPacks() then return end
	end
	if e.mobFarm and #CAMPS > 0 then
		farmStep()
		if e.boss and st.ready then st.status ..= " · " .. st.ready end
		return
	end
	if e.train then
		-- packs on my back are claimed in the lobby safe zone, and the bench is inside it
		trainStep()
		if e.boss and st.ready then st.status ..= " · " .. st.ready end
	else
		st.status = e.boss and "รอบอสเกิด (ปิด train อยู่)" or "ปิดอยู่"
	end
end)

-- ------------------------------------------------------------------ side jobs
-- Remotes.OpenAllPacks is "Developers only"; the pack screen opens one kind at a time with OpenPack(name, count)
local PackConfig = require(RS.Shared.Config.PackConfig)
loopEvery("Open Packs", 3, 60, function()
	if not e.openPacks then return end
	local d = D()
	for name, have in pairs(d and d.Packs or {}) do
		have = tonumber(have) or 0
		if have > 0 and alive() and e.openPacks then
			local n = math.min(have, PackConfig.MaxOpenAtOnce or 1)
			local ok, r = pcall(function() return Remotes.OpenPack:InvokeServer(name, n) end)
			if not (ok and type(r) == "table") and n > 1 then
				n = 1
				ok, r = pcall(function() return Remotes.OpenPack:InvokeServer(name, 1) end)
			end
			if ok and type(r) == "table" then
				st.opened += n
				st.lastOpen = ("%s x%d · %s"):format(name, n, os.date("%H:%M:%S"))
			else
				st.lastOpen = ("เปิด %s ไม่ได้: %s"):format(name, tostring(r):sub(1, 40))
			end
			task.wait(1)
		end
	end
end)
-- Merge = the cards screen's "merge all": Remotes.FuseAll:InvokeServer() levels up every card with enough copies
local CardStats = require(RS.Shared.Rules.CardStats)
loopEvery("Merge", 6, 30, function()
	if not e.merge then return end
	local d = D()
	if not (d and d.Cards) then return end
	local okN, _, n = pcall(CardStats.FuseAll, d.Cards, CardStats.FuseNeed and CardStats.FuseNeed(d) or nil)
	if not (okN and n and n > 0) then return end
	local ok, r, msg = pcall(function() return Remotes.FuseAll:InvokeServer() end)
	if ok and r then
		st.merged = (st.merged or 0) + n
		st.lastMerge = ("รวม %d ใบ · %s"):format(n, os.date("%H:%M:%S"))
	else
		st.lastMerge = "รวมไม่ได้: " .. tostring(msg or r):sub(1, 40)
	end
end)
loopEvery("Rebirth", 5, 30, function()
	if not e.rebirth then return end
	local d = D()
	if not d then return end
	local need = Progression.RebirthLevelRequirement(d.Rebirths or 0)
	local lvl = PowerConfig.Level(d.Power or 0)
	st.reb = ("Level %d / %d"):format(lvl, need)
	if lvl < need then return end
	local ok, r = pcall(function() return Remotes.Rebirth:InvokeServer() end)
	if ok and r then st.rebirths += 1; st.lastReb = os.date("%H:%M:%S") end
end)
-- Remotes.BenchUpgrade:FireServer() = the cash upgrade the sign's UpgradePrompt does (BaseController.onUpgrade); the
-- RobuxUpgradePrompt is never touched. Upgrades back to back while the cash covers the next level (user 2026-11-22:
-- one prompt every ~5 s was far too slow), waiting only for Data.Base.Bench to tick before the next one.
loopEvery("Upgrade Train", 1, 60, function()
	if not e.upgradeTrain then return end
	for _ = 1, 200 do
		local d = D()
		if not (d and d.Base and alive() and e.upgradeTrain) then return end
		local lvl = d.Base.Bench or 1
		if lvl >= BaseConfig.BenchMaxLevel then st.bench = "เบนช์เต็มแล้ว"; return end
		local cost = BaseConfig.BenchCost(lvl)
		st.bench = ("เบนช์ Lv %d · อัปต่อไป $%s"):format(lvl, short(cost))
		if Big.lt(d.Cash, cost) then return end
		Remotes.BenchUpgrade:FireServer()
		local t0 = os.clock()
		while alive() and os.clock() - t0 < 2 and ((D().Base and D().Base.Bench) or lvl) <= lvl do task.wait(0.05) end
		if ((D().Base and D().Base.Bench) or lvl) <= lvl then return end   -- server said no: try again next round
		st.upgrades += 1
	end
end)
loopEvery("Place Best", 10, 30, function()
	if not e.placeBest then return end
	local d = D()
	if not d then return end
	local ok, _, better = pcall(BaseConfig.BestHolders, d)
	if not (ok and better) then return end
	local plot = myPlot()
	local p = plot and plot:FindFirstChild("BestPrompt", true)
	if p and firePrompt(p) then st.placed += 1; st.lastPlace = os.date("%H:%M:%S") end
end)

-- Auto Buy Potion: the Potion Shop restocks every Potions.RestockSeconds (1800 s); CosmeticConfig.PotionShelf(Data, now)
-- = current slot, PotionStock(userId, slot) = the cards on the shelf ({Type, Tier}), PotionLeft(Data, potion, slot) = how
-- many are left. Buying is the green CASH button only: Remotes.BuyCosmetic:InvokeServer("Potion", typeId, tier) -- the
-- purple Robux button (PurchasePrompt.PromptProduct) is never touched. Bought potions land in the Backpack.
local CosmeticConfig = require(RS.Shared.Config.CosmeticConfig)
-- every buyable tier: the shelf is rolled per WORLD (PotionStock), World 1 only stocks I/II but World 2 also stocks III+
-- (user 2026-11-22: Health III was skipped because the list only had the World 1 tiers)
local SHOP_TIERS = {}
for _, t in ipairs(CosmeticConfig.Potions.Tiers or {}) do if (t.Price or 0) > 0 then SHOP_TIERS[#SHOP_TIERS + 1] = t end end
-- one-time upgrade of the old saved default {I, II} to every tier
if type(e.potionTiers) == "table" and not e.potionTiersV2 then
	for _, t in ipairs(SHOP_TIERS) do if not table.find(e.potionTiers, t.Tier) then table.insert(e.potionTiers, t.Tier) end end
	e.potionTiersV2 = true
end
if type(e.potionTypes) ~= "table" then e.potionTypes = {}; for _, t in ipairs(CosmeticConfig.Potions.Types or {}) do table.insert(e.potionTypes, t.Id) end end
if type(e.potionTiers) ~= "table" then e.potionTiers = {}; for _, t in ipairs(SHOP_TIERS) do table.insert(e.potionTiers, t.Tier) end end
loopEvery("Buy Potion", 5, 60, function()
	if not e.autoPotion then return end
	local d = D()
	if not d or not CosmeticConfig.Potions.Selling then return end
	local slot = CosmeticConfig.PotionShelf(d, workspace:GetServerTimeNow())
	local shelf = CosmeticConfig.PotionStock(plr.UserId, slot) or {}
	for _, potion in pairs(shelf) do
		if not (alive() and e.autoPotion) then return end
		local tier = potion.Tier
		local price = tier and tier.Price
		if price and price > 0 and potion.Type and table.find(e.potionTypes, potion.Type.Id) and table.find(e.potionTiers, tier.Tier) then
			local left = CosmeticConfig.PotionLeft(D(), potion, slot) or 0
			while left > 0 and alive() and e.autoPotion and not Big.lt(D().Cash, price) do
				local ok, r1, r2 = pcall(function() return Remotes.BuyCosmetic:InvokeServer("Potion", potion.Type.Id, tier.Tier) end)
				if not (ok and r1) then
					st.lastPotion = ("ซื้อ %s %s ไม่ได้: %s"):format(potion.Type.Name, tier.Numeral, tostring(ok and r2 or r1):sub(1, 40))
					return
				end
				st.potions = (st.potions or 0) + 1
				st.lastPotion = ("%s %s ($%s) · %s"):format(potion.Type.Name, tier.Numeral, short(price), os.date("%H:%M:%S"))
				task.wait(0.6)
				left = CosmeticConfig.PotionLeft(D(), potion, slot) or 0
			end
		end
	end
end)

-- Card Shrine (user 2026-11-22). Shared.Rules.Shrine:
--   Sacrifice: Remotes.Sacrifice:InvokeServer(cardId, n) turns spare copies into Shards; Shrine.Spare(Data, id) = copies
--     minus the one the game always keeps (0 for Exclusive / Exotic+ cards). Only cards at CardStats.MaxLevel (10) are fed
--     to it -- lower cards still need their copies for Auto Merge.
--   Skill Tree: Remotes.TreeBuy:InvokeServer(nodeId); Shrine.CantBuy(Data, id) == nil means it can be bought now
--     (parents owned, boss gate beaten, shards enough). "Ascend" (Ascension, 2500 shards, needs all five branches) is the
--     tree's rebirth and has its own toggle.
local Shrine = require(RS.Shared.Rules.Shrine)
local CardStats = require(RS.Shared.Rules.CardStats)
local CARD_MAX = CardStats.MaxLevel or 10
-- the tree's "rebirth" node differs per world ("Ascend" in World 3, "W4Apex" in World 4): it is the node on the Ascend branch
local function ascendId()
	for id, node in pairs(Shrine.TreeById or {}) do if node.Branch == "Ascend" then return id end end
	return "Ascend"
end
-- shards still needed to buy every node not owned yet (Ascension included). Sacrificing past that only piles up shards
-- that have nothing left to buy and are gone after the rebirth (user 2026-11-23) -- so Auto Sacrifice stops there.
local function shardsNeeded(d)
	local need = 0
	for id, node in pairs(Shrine.TreeById or {}) do
		if not Shrine.Owns(d, id) then need += tonumber(node.Cost) or 0 end
	end
	return need
end
loopEvery("Sacrifice", 3, 60, function()
	if not e.autoSacrifice then return end
	local d = D()
	if not d or not Shrine.Open(d) then st.shrine = "ยังเปิด Card Shrine ไม่ได้ (ต้องชนะบอสก่อน)"; return end
	local missing = shardsNeeded(d) - (tonumber(d.Shards) or 0)
	if missing <= 0 then
		st.lastSacrifice = "ชาร์ดพอซื้อต้นไม้ที่เหลือทั้งหมดแล้ว → ไม่ย่อยเพิ่ม (เก็บการ์ดไว้)"
		return
	end
	for id, card in pairs(d.Cards or {}) do
		if not (alive() and e.autoSacrifice) or missing <= 0 then return end
		local spare = Shrine.Spare(D(), id)
		if type(card) == "table" and (tonumber(card.Level) or 1) >= CARD_MAX and spare > 0 then
			local each = tonumber(Shrine.ShardsEach(D(), id)) or 0
			local n = math.min(spare, 1000, each > 0 and math.ceil(missing / each) or spare)
			local gain = Shrine.ShardsGained(D(), id, n)
			local ok, r1, r2 = pcall(function() return Remotes.Sacrifice:InvokeServer(id, n) end)
			if ok and r1 then
				missing -= tonumber(gain) or 0
				st.sacrificed = (st.sacrificed or 0) + n
				st.lastSacrifice = ("%s x%d → +%s ชาร์ด · %s"):format(id, n, tostring(gain), os.date("%H:%M:%S"))
			else
				st.lastSacrifice = ("ย่อย %s ไม่ได้: %s"):format(id, tostring(ok and r2 or r1):sub(1, 40))
			end
			task.wait(0.4)
		end
	end
end)
loopEvery("Skill Tree", 2, 60, function()
	if not (e.autoTree or e.autoAscend) then return end
	for _ = 1, 50 do
		local d = D()
		if not (d and alive()) then return end
		local pick
		local asc = ascendId()
		if e.autoAscend and Shrine.TreeById[asc] and not Shrine.CantBuy(d, asc) then
			pick = asc
		elseif e.autoTree then
			local best
			for id, node in pairs(Shrine.TreeById) do
				if id ~= asc and not Shrine.CantBuy(d, id) and (not best or (node.Cost or 0) < (Shrine.TreeById[best].Cost or 0)) then best = id end
			end
			pick = best
		end
		if not pick then return end
		local ok, r1, r2 = pcall(function() return Remotes.TreeBuy:InvokeServer(pick) end)
		if not (ok and r1) then st.lastTree = ("ซื้อ %s ไม่ได้: %s"):format(pick, tostring(ok and r2 or r1):sub(1, 40)); return end
		st.treeBought = (st.treeBought or 0) + 1
		st.lastTree = ("%s (%s ชาร์ด) · %s"):format(pick, tostring(Shrine.TreeById[pick].Cost), os.date("%H:%M:%S"))
		task.wait(0.4)
	end
end)

-- anti-AFK (the game rejoins idle players after 900 s) + auto reconnect
local VirtualUser = game:GetService("VirtualUser")
local idleConn = plr.Idled:Connect(function()
	if not alive() or not e.antiAfk then return end
	pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
	st.wd = "anti-AFK · " .. os.date("%H:%M:%S")
end)
local GuiService = game:GetService("GuiService")
local TeleportService = game:GetService("TeleportService")
local rejoining = false
local errConn = GuiService.ErrorMessageChanged:Connect(function()
	task.defer(function()
		if rejoining or not e.reconnect or not alive() then return end
		local ok, code = pcall(function() return GuiService:GetErrorCode().Value end)
		if not ok or type(code) ~= "number" or code < 256 or code >= 512 or code == 273 or code == 274 then return end
		rejoining = true
		st.wd = ("หลุด (code %d) → เข้าเกมใหม่ · %s"):format(code, os.date("%H:%M:%S"))
		task.wait(5)
		for _ = 1, 20 do
			if not e.reconnect or not alive() then break end
			pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
			task.wait(15)
		end
		rejoining = false
	end)
end)

-- ---------------------------------------------------------------------- UI
local okL, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okL or not Lib then warn("[SSP] MacLib failed: " .. tostring(Lib)) return end
if not alive() then return end
local Win = Lib:Window({Title = "Steal a Superpower!", Subtitle = "Boss + Train", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__SSPW = Win
local TG = Win:TabGroup()
local Tabs = {
	Main = TG:Tab({Name = "Auto Farm", Image = "rbxassetid://10723346959"}),
	Potion = TG:Tab({Name = "Potion", Image = "rbxassetid://10709769841"}),
	Shrine = TG:Tab({Name = "Card Shrine", Image = "rbxassetid://10723346959"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}
local function picked(v)
	local out = {}
	for k, on in pairs(type(v) == "table" and v or {}) do
		local label = type(k) == "number" and on or (on and k)
		if type(label) == "string" then out[#out + 1] = label end
	end
	return out
end

local L = Tabs.Main:Section({Side = "Left"})
L:Header({Text = "บอส ↔ train"})
L:Toggle({Name = "Auto Boss (บอสเกิด → ไปตี เก็บการ์ด)", Default = e.boss, Callback = function(v) e.boss = v; sv() end}, "SSPBoss")
-- The "(ล็อก)" suffix depends on PlayerState.Data.Gates, which may still be the default (empty) table when the script
-- starts right after a join / world teleport (user 2026-11-22, World 2: every boss after the first showed locked).
-- So labels are rebuilt whenever the lock picture changes, and lookups ignore the suffix.
local function baseLabel(label) return (tostring(label):gsub(" %(ล็อก%)$", "")) end
local bossByBase = {}
for _, b in ipairs(BOSSES) do bossByBase[("Lv %d · %s"):format(b.level, b.display)] = b end
local function bossOptions()
	local opts, sel = {}, {}
	for _, b in ipairs(BOSSES) do
		local label = bossLabel(b)
		opts[#opts + 1] = label
		if table.find(e.bosses, b.name) then sel[#sel + 1] = label end
	end
	return opts, sel
end
local bossRebuilding = false
local bossOpts, bossDef = bossOptions()
local bossDD = L:Dropdown({Name = "└ บอสที่จะตี (เลือกได้หลายตัว)", Multi = true, Required = false, Options = bossOpts, Default = bossDef,
	Callback = function(v)
		if bossRebuilding then return end
		local names = {}
		for _, label in ipairs(picked(v)) do local b = bossByBase[baseLabel(label)]; if b then names[#names + 1] = b.name end end
		e.bosses = names; sv()
	end}, "SSPBosses")
task.spawn(function()
	local shown = table.concat(bossOpts, "|")
	while alive() do
		task.wait(2)
		local opts, sel = bossOptions()
		local sig = table.concat(opts, "|")
		if sig ~= shown then
			shown = sig
			bossRebuilding = true
			pcall(function()
				bossDD:ClearOptions()
				bossDD:InsertOptions(opts)
				bossDD:UpdateSelection(sel)
			end)
			bossRebuilding = false
		end
	end
end)
L:Toggle({Name = "└ รอบอสที่เลือกเกิดครบทุกตัวก่อน แล้วไล่ตีรวดเดียว", Default = e.waitAll, Callback = function(v) e.waitAll = v; sv() end}, "SSPWaitAll")
L:Toggle({Name = "└ Auto Skill (กดสกิล E / F ใส่บอสเมื่อพร้อม)", Default = e.autoSkill, Callback = function(v) e.autoSkill = v; sv() end}, "SSPSkill")
L:Toggle({Name = "└ โจมตีทะลุสิ่งก่อสร้าง (ปิดก่อนซื้อของด้วย Robux)", Default = e.pierce, Callback = function(v) e.pierce = v; sv() end}, "SSPPierce")
L:Toggle({Name = "Instant Kill (บอส / มอน ตายทีเดียว)", Default = e.instaKill, Callback = function(v) e.instaKill = v; sv() end}, "SSPInsta")
L:Toggle({Name = "God Mode (ศัตรู / บอสตีไม่เข้า ไม่โดนสตัน)", Default = e.godMode, Callback = function(v) e.godMode = v; sv() end}, "SSPGod")
L:Toggle({Name = "Auto Train (ไม่มีบอส → กลับไปยกเวทที่เบนช์)", Default = e.train, Callback = function(v) e.train = v; sv() end}, "SSPTrain")
L:Label({Text = "บอสที่เลือกตัวไหนเกิด (ตัวแรงสุดก่อน) → ลุกจากเบนช์ วาร์ปไปตี (ใช้ Auto Attack ของเกม)\nตายแล้วแพ็คบินเข้ากระเป๋า → กลับเบนช์ (อยู่ในโซนปลอดภัย แพ็คเข้าบัญชีเอง) → บอสเกิดใหม่ไปตีอีก"})
L:Header({Text = "ฟาร์มมอน"})
L:Toggle({Name = "Auto Farm มอน (ไม่มีบอส → ไปตีมอนแทนยกเวท)", Default = e.mobFarm, Callback = function(v) e.mobFarm = v; sv() end}, "SSPMob")
local zoneOpts, zoneByLabel, zoneDef, seenZone = {}, {}, {}, {}
for _, c in ipairs(CAMPS) do
	local key = zoneKey(c.zone)
	if not seenZone[key] then
		seenZone[key] = true
		local label = ("Lv %d+ · %s"):format(c.level, key)
		zoneOpts[#zoneOpts + 1] = label
		zoneByLabel[label] = key
		if type(e.mobZones) == "table" and table.find(e.mobZones, key) then zoneDef[#zoneDef + 1] = label end
	end
end
L:Dropdown({Name = "└ โซนที่จะฟาร์ม (ไม่เลือก = โซนสูงสุดที่เข้าได้)", Multi = true, Required = false, Options = zoneOpts, Default = zoneDef,
	Callback = function(v)
		local keys = {}
		for _, label in ipairs(picked(v)) do if zoneByLabel[label] then keys[#keys + 1] = zoneByLabel[label] end end
		e.mobZones = keys; sv()
	end}, "SSPMobZones")
L:Label({Text = "แต่ละโซนมีแคมป์มอน 3 แคมป์ (4 ตัว เกิดใหม่ทุก 8 วิ) · บอสที่เลือกเกิด → ไปตีบอสก่อน\nพกแพ็คเต็ม → วาร์ปกลับบ้านให้แพ็คเข้าบัญชีแล้วกลับมาฟาร์มต่อ · โซนที่ยังเข้าไม่ได้ข้ามเอง"})
L:Header({Text = "การ์ด / อัปเกรด"})
L:Toggle({Name = "Auto Open Packs (เปิดแพ็คทั้งหมด)", Default = e.openPacks, Callback = function(v) e.openPacks = v; sv() end}, "SSPOpen")
L:Toggle({Name = "Auto Merge Card (รวมการ์ดซ้ำให้เลเวลขึ้น)", Default = e.merge, Callback = function(v) e.merge = v; sv() end}, "SSPMerge")
L:Toggle({Name = "Auto Equip Best Card in Base (วางการ์ดดีสุดในฐาน)", Default = e.placeBest, Callback = function(v) e.placeBest = v; sv() end}, "SSPBest")
L:Toggle({Name = "Auto Upgrade Train (อัปเบนช์ด้วยเงิน)", Default = e.upgradeTrain, Callback = function(v) e.upgradeTrain = v; sv() end}, "SSPUpTrain")
L:Toggle({Name = "Auto Rebirth (ถึงเลเวลที่ต้องการ → รีเบิร์ธ)", Default = e.rebirth, Callback = function(v) e.rebirth = v; sv() end}, "SSPRebirth")
L:Toggle({Name = "หยุดบอทตอนฉันกดเดินเอง", Default = e.pauseOnMove, Callback = function(v) e.pauseOnMove = v; sv() end}, "SSPPause")

local PL = Tabs.Potion:Section({Side = "Left"})
PL:Header({Text = "ร้านยา"})
PL:Toggle({Name = "Auto Buy Potion (ซื้อด้วยเงินเกม ไม่ใช้ Robux)", Default = e.autoPotion, Callback = function(v) e.autoPotion = v; sv() end}, "SSPPotion")
local typeOpts, typeByLabel, typeDef = {}, {}, {}
for _, t in ipairs(CosmeticConfig.Potions.Types or {}) do
	local label = tostring(t.Name)
	typeOpts[#typeOpts + 1] = label
	typeByLabel[label] = t.Id
	if table.find(e.potionTypes, t.Id) then typeDef[#typeDef + 1] = label end
end
PL:Dropdown({Name = "ยาที่จะซื้อ (เลือกได้หลายอย่าง)", Multi = true, Required = false, Options = typeOpts, Default = typeDef,
	Callback = function(v)
		local ids = {}
		for _, label in ipairs(picked(v)) do if typeByLabel[label] then ids[#ids + 1] = typeByLabel[label] end end
		e.potionTypes = ids; sv()
	end}, "SSPPotionTypes")
local tierOpts, tierByLabel, tierDef = {}, {}, {}
for _, t in ipairs(SHOP_TIERS) do
	local label = ("%s · x%s · %d นาที · $%s"):format(t.Numeral, tostring(t.Multiplier), math.floor((t.Seconds or 0) / 60), short(t.Price))
	tierOpts[#tierOpts + 1] = label
	tierByLabel[label] = t.Tier
	if table.find(e.potionTiers, t.Tier) then tierDef[#tierDef + 1] = label end
end
PL:Dropdown({Name = "ระดับยา (เลือกได้หลายระดับ)", Multi = true, Required = false, Options = tierOpts, Default = tierDef,
	Callback = function(v)
		local tiers = {}
		for _, label in ipairs(picked(v)) do if tierByLabel[label] then tiers[#tiers + 1] = tierByLabel[label] end end
		e.potionTiers = tiers; e.potionTiersV2 = true; sv()
	end}, "SSPPotionTiers")
PL:Label({Text = "ร้านเปลี่ยนของทุก 30 นาที · เช็กทุก 5 วิ ซื้อทุกขวดที่ตรงกับที่เลือกและเงินพอ\nกดแค่ปุ่มเขียว (เงินเกม) ไม่แตะปุ่ม Robux · ยาที่ซื้อเข้า Backpack"})
local PR = Tabs.Potion:Section({Side = "Right"})
PR:Header({Text = "ในร้านตอนนี้"})
local potLbl = PR:Label({Text = "-"})

local SHL = Tabs.Shrine:Section({Side = "Left"})
SHL:Header({Text = "ย่อยการ์ด (Sacrifice Cards)"})
SHL:Toggle({Name = ("Auto Sacrifice (ย่อยเฉพาะการ์ด Lv %d)"):format(CARD_MAX), Default = e.autoSacrifice, Callback = function(v) e.autoSacrifice = v; sv() end}, "SSPSacrifice")
SHL:Label({Text = ("ย่อยแค่พอให้ชาร์ดถึงยอดที่ต้องใช้ซื้อต้นไม้ที่เหลือทั้งหมด (รวม Ascension) แล้วหยุด\nย่อยใบซ้ำของการ์ดที่เลเวลเต็ม (%d) แล้วเท่านั้น → ได้ชาร์ด\nเกมเก็บไว้ให้ 1 ใบเสมอ · การ์ด Exclusive / Exotic ขึ้นไปย่อยไม่ได้\nการ์ดที่ยังไม่เต็มไม่แตะ (ยังต้องใช้ใบซ้ำรวมเลเวล)"):format(CARD_MAX)})
SHL:Header({Text = "Skill Tree"})
SHL:Toggle({Name = "Auto Skill Tree (ซื้อช่องที่ซื้อได้ ถูกสุดก่อน)", Default = e.autoTree, Callback = function(v) e.autoTree = v; sv() end}, "SSPTree")
SHL:Toggle({Name = "Auto Ascension (Rebirth ของต้นไม้ · 2500 ชาร์ด)", Default = e.autoAscend, Callback = function(v) e.autoAscend = v; sv() end}, "SSPAscend")
SHL:Label({Text = "Ascension = เพิ่มทุกอย่าง x2 ต้องซื้อครบทั้ง 5 สายก่อน\nเปิดทั้งคู่: พอซื้อ Ascension ได้ บอทจะซื้อ Ascension ก่อนช่องอื่น"})
local SHR = Tabs.Shrine:Section({Side = "Right"})
SHR:Header({Text = "สถานะ"})
local shrineLbl = SHR:Label({Text = "-"})

local R = Tabs.Main:Section({Side = "Right"})
R:Header({Text = "สถานะ"})
local stLbl = R:Label({Text = "-"})
R:Header({Text = "บอส"})
local bossLbl = R:Label({Text = "-"})

local S = Tabs.Settings:Section({Side = "Left"})
S:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() Win:SetState(not Win:GetState()) end) end}, "SSPToggleUI")
S:Header({Text = "กันหลุด"})
S:Toggle({Name = "Anti-AFK (เกมเตะคนยืนนิ่ง 15 นาที)", Default = e.antiAfk, Callback = function(v) e.antiAfk = v; sv() end}, "SSPAntiAfk")
S:Toggle({Name = "Auto Reconnect (หลุด / โดนเตะ → เข้าเกมใหม่เอง)", Default = e.reconnect, Callback = function(v) e.reconnect = v; sv() end}, "SSPReconnect")
S:Label({Text = "ตั้งค่าเซฟที่: " .. SF})

task.spawn(function()
	while alive() do
		pcall(function()
			local d = D() or {}
			stLbl:UpdateName(table.concat({
				st.status,
				("ฆ่าบอส %d · ล่าสุด: %s · ฆ่ามอน %d"):format(st.kills, tostring(st.lastKill or "-"), st.mobKills or 0),
				("เปิดแพ็ค %d (ล่าสุด %s) · วางการ์ดดีสุด %d ครั้ง · อัปเบนช์ %d · รีเบิร์ธ %d"):format(st.opened, tostring(st.lastOpen or "-"), st.placed, st.upgrades, st.rebirths),
				("เงิน $%s · Rebirth %s · %s"):format(short(d.Cash), tostring(d.Rebirths), tostring(st.reb or "-")),
				tostring(st.bench or "-") .. " · รวมการ์ด: " .. tostring(st.lastMerge or "-"),
				"Watchdog: " .. st.wd,
				"Error: " .. st.err,
			}, "\n"))
			local lines = {}
			for _, b in ipairs(BOSSES) do
				if table.find(e.bosses, b.name) then
					lines[#lines + 1] = ("%s: %s"):format(b.display, not gateOpen(b) and "ยังล็อก" or skipped(b) and ("ตีไม่ไหว ข้ามอีก %d นาที"):format(math.ceil((tooStrong[b.name] - os.clock()) / 60))
					or padState(b) == "alive" and "เกิดแล้ว" or "รอเกิด")
				end
			end
			pcall(function()
				local slot, ends = CosmeticConfig.PotionShelf(d, workspace:GetServerTimeNow())
				local left = math.floor(math.max(0, (ends or 0) - workspace:GetServerTimeNow()))
				local lines = {("ของใหม่ในอีก %d:%02d"):format(left // 60, left % 60)}
				for _, p in pairs(CosmeticConfig.PotionStock(plr.UserId, slot) or {}) do
					local want = table.find(e.potionTypes, p.Type.Id) and table.find(e.potionTiers, p.Tier.Tier)
					lines[#lines + 1] = ("%s %s · เหลือ %d · $%s%s"):format(p.Type.Name, p.Tier.Numeral, CosmeticConfig.PotionLeft(d, p, slot) or 0, short(p.Tier.Price), want and "" or " (ไม่ได้เลือก)")
				end
				lines[#lines + 1] = ("ซื้อแล้ว %d ขวด · ล่าสุด: %s"):format(st.potions or 0, tostring(st.lastPotion or "-"))
				potLbl:UpdateName(table.concat(lines, "\n"))
			end)
			pcall(function()
				local spareMax, spareCards = 0, 0
				for id, card in pairs(d.Cards or {}) do
					local sp = Shrine.Spare(d, id)
					if type(card) == "table" and (tonumber(card.Level) or 1) >= CARD_MAX and sp > 0 then spareMax += sp; spareCards += 1 end
				end
				local nextId, nextCost
				for id, node in pairs(Shrine.TreeById or {}) do
					local why = Shrine.CantBuy(d, id)
					if (not why or why == "Not enough shards") and id ~= ascendId() and (not nextCost or (node.Cost or 0) < nextCost) then nextId, nextCost = id, node.Cost or 0 end
				end
				local ascId = ascendId()
				local asc = Shrine.CantBuy(d, ascId)
				local need = shardsNeeded(d)
				shrineLbl:UpdateName(table.concat({
					("ชาร์ด %s · Card Shrine %s"):format(tostring(d.Shards or 0), Shrine.Open(d) and "เปิดแล้ว" or "ยังไม่เปิด"),
					("การ์ด Lv %d ที่มีใบซ้ำ: %d แบบ รวม %d ใบ"):format(CARD_MAX, spareCards, spareMax),
					("ย่อยไปแล้ว %d ใบ · ล่าสุด: %s"):format(st.sacrificed or 0, tostring(st.lastSacrifice or "-")),
					nextId and ("ช่องถัดไป: %s (%s ชาร์ด)"):format(nextId, tostring(nextCost)) or "ต้นไม้: ไม่มีช่องที่ซื้อได้ตอนนี้",
					("Ascension (%s, %s ชาร์ด): %s"):format(ascId, short((Shrine.TreeById[ascId] or {}).Cost or 0), asc and tostring(asc) or "ซื้อได้แล้ว!"),
					("ต้องใช้อีก %s ชาร์ดซื้อที่เหลือทั้งหมด · มี %s → %s"):format(short(need), short(tonumber(d.Shards) or 0),
						(tonumber(d.Shards) or 0) >= need and "พอแล้ว ไม่ย่อยเพิ่ม" or ("ขาด " .. short(need - (tonumber(d.Shards) or 0)))),
					("ซื้อช่องไปแล้ว %d · ล่าสุด: %s"):format(st.treeBought or 0, tostring(st.lastTree or "-")),
					st.shrine or "",
				}, "\n"))
			end)
			bossLbl:UpdateName(st.boss .. "\n" .. (#lines > 0 and table.concat(lines, "\n") or "ยังไม่ได้เลือกบอส"))
		end)
		task.wait(0.5)
	end
end)

task.spawn(function()
	while alive() do task.wait(1) end
	for _, c in ipairs({idleConn, errConn}) do pcall(function() c:Disconnect() end) end
end)
pcall(function()
	Win.onUnloaded(function() if getgenv().__SSP == G then getgenv().__SSP = G + 1 end end)
end)
