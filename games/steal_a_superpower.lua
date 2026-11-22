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
	placeBest = false, godMode = false, autoSkill = true, pierce = true, autoPotion = false, potionTypes = false, potionTiers = false, pauseOnMove = true, antiAfk = true, reconnect = true}
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
		local ec = EnemyConfig[enemy] or (EnemyConfig.Enemies and EnemyConfig.Enemies[enemy])
		local isBoss = (cfg:GetAttribute("Count") == 1 and cfg:GetAttribute("Gate") ~= nil) or (ec and ec.Boss)
		local pcf = cfg:GetAttribute("PadCFrame")
		if isBoss and typeof(pcf) == "CFrame" then
			BOSSES[#BOSSES + 1] = {padId = tonumber(cfg.Name) or cfg.Name, enemy = enemy, gate = cfg:GetAttribute("Gate"),
				level = cfg:GetAttribute("Level") or 0, at = pcf.Position, name = cfg:GetAttribute("Name") or enemy}
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
	return ("Lv %d · %s%s"):format(b.level, b.name, gateOpen(b) and "" or " (ล็อก)")
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

-- God Mode: enemies are simulated on this client and every hit on me is computed here (LocalEnemyAbilities.hurt /
-- u112.Stun) and then REPORTED by the client: Remotes.EnemyHurtMe:FireServer(padId, "Hit", dmg, seq) / (padId, "Stun", s).
-- Dropping those reports = the server never applies the damage or the stun (user 2026-11-22: Empyrean Boss Lv 450 kills
-- the character). One __namecall hook per game session; getgenv().__SSPGOD (set from e.godMode while this build is
-- alive) decides whether it drops, so unloading / switching off restores normal damage at once.
local HurtMe = Remotes:WaitForChild("EnemyHurtMe")
if not getgenv().__SSPGODHOOK and hookmetamethod and getnamecallmethod then
	getgenv().__SSPGODHOOK = true
	local old
	old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		if getgenv().__SSPGOD and self == HurtMe and getnamecallmethod() == "FireServer" then
			getgenv().__SSPGODN = (getgenv().__SSPGODN or 0) + 1
			return nil
		end
		return old(self, ...)
	end))
end
task.spawn(function()
	while alive() do getgenv().__SSPGOD = e.godMode == true; task.wait(0.2) end
	getgenv().__SSPGOD = false
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
-- While getgenv().__SSPPIERCE is set, those sideways combat rays report "no wall". Recognised by the calling function's
-- source (debug.info level 3 = a Shared.Combat.* module); up/down rays (floor, ceiling checks) are left alone.
-- The __namecall hook is installed once per game session and only calls getgenv().__SSPPIERCEFN, so every reload of
-- this script swaps in its current rule (a hook body can't be replaced). v1 of this hook used __SSPPIERCE; that flag is
-- forced off so a session still carrying it stops piercing.
getgenv().__SSPPIERCE = false
getgenv().__SSPPIERCEFN = function(src, dir, params)
	return type(src) == "string" and src:find("Shared.Combat.", 1, true) ~= nil
		and typeof(dir) == "Vector3" and math.abs(dir.Y) < dir.Magnitude * 0.5
		and typeof(params) == "RaycastParams" and params.RespectCanCollide and params.FilterType == Enum.RaycastFilterType.Exclude
end
if not getgenv().__SSPPIERCEHOOK2 and hookmetamethod and getnamecallmethod then
	getgenv().__SSPPIERCEHOOK2 = true
	local old
	old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		if getgenv().__SSPPIERCE2 and self == workspace and not checkcaller() and getnamecallmethod() == "Raycast" then
			local ok, src = pcall(debug.info, 3, "s")   -- 2 = this [C] call, 3 = the Lua function that cast the ray
			local f = getgenv().__SSPPIERCEFN
			local _, dir, params = ...
			if ok and f and f(src, dir, params) then
				getgenv().__SSPPIERCEN = (getgenv().__SSPPIERCEN or 0) + 1
				return nil
			end
		end
		return old(self, ...)
	end))
end
task.spawn(function()
	while alive() do getgenv().__SSPPIERCE2 = e.pierce == true; task.wait(0.2) end
	getgenv().__SSPPIERCE2 = false
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

local function fightBoss(b)
	if not getUp() then st.status = "ลุกจากเบนช์ไม่ได้"; return end
	ensureAutoAttack()
	st.status = "วาร์ปไปหา " .. b.name
	warp(b.at + Vector3.new(0, 6, 25), b.at)
	local t0 = os.clock()
	local m
	while alive() and os.clock() - t0 < 8 do
		m = bossModel(b)
		if m then break end
		task.wait(0.1)
	end
	if not m then st.status = b.name .. " ไม่โผล่ (มีคนตีไปแล้ว?)"; task.wait(0.2); return end
	t0 = os.clock()
	local h0 = m:FindFirstChildOfClass("Humanoid")
	local hp0 = h0 and h0.Health
	local function giveUp(why)
		tooStrong[b.name] = os.clock() + 900
		st.status = ("%s ตีไม่ไหว (%s) → ข้ามตัวนี้ 15 นาที"):format(b.name, why)
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
		local h = m:FindFirstChildOfClass("Humanoid")
		st.boss = ("%s · HP %s / %s"):format(b.name, h and short(h.Health) or "?", h and short(h.MaxHealth) or "?")
		st.status = "กำลังตี " .. b.name .. " (Auto Attack ของเกม)"
		task.wait(0.3)
	end
	if not m.Parent or m:GetAttribute("Dead") or m:GetAttribute("DeadLocal") then
		st.kills += 1
		st.lastKill = b.name .. " · " .. os.date("%H:%M:%S")
		-- no standing around (user 2026-11-22): the packs fly to the character wherever it goes and are claimed in the
		-- lobby safe zone anyway, so go straight on to the next boss / the bench
		st.status = b.name .. " ตายแล้ว → ไปต่อเลย"
		task.wait(0.15)
	end
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
				st.sweeping = true
				return fightBoss(b)
			end
		end
		st.sweeping = false
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
for _, b in ipairs(BOSSES) do bossByBase[("Lv %d · %s"):format(b.level, b.name)] = b end
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
L:Toggle({Name = "└ โจมตีทะลุสิ่งก่อสร้าง (กำแพง / ตึก ไม่บังท่า)", Default = e.pierce, Callback = function(v) e.pierce = v; sv() end}, "SSPPierce")
L:Toggle({Name = "God Mode (ศัตรู / บอสตีไม่เข้า ไม่โดนสตัน)", Default = e.godMode, Callback = function(v) e.godMode = v; sv() end}, "SSPGod")
L:Toggle({Name = "Auto Train (ไม่มีบอส → กลับไปยกเวทที่เบนช์)", Default = e.train, Callback = function(v) e.train = v; sv() end}, "SSPTrain")
L:Label({Text = "บอสที่เลือกตัวไหนเกิด (ตัวแรงสุดก่อน) → ลุกจากเบนช์ วาร์ปไปตี (ใช้ Auto Attack ของเกม)\nตายแล้วแพ็คบินเข้ากระเป๋า → กลับเบนช์ (อยู่ในโซนปลอดภัย แพ็คเข้าบัญชีเอง) → บอสเกิดใหม่ไปตีอีก"})
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
				("ฆ่าบอส %d · ล่าสุด: %s"):format(st.kills, tostring(st.lastKill or "-")),
				("เปิดแพ็ค %d (ล่าสุด %s) · วางการ์ดดีสุด %d ครั้ง · อัปเบนช์ %d · รีเบิร์ธ %d"):format(st.opened, tostring(st.lastOpen or "-"), st.placed, st.upgrades, st.rebirths),
				("เงิน $%s · Rebirth %s · %s"):format(short(d.Cash), tostring(d.Rebirths), tostring(st.reb or "-")),
				tostring(st.bench or "-") .. " · รวมการ์ด: " .. tostring(st.lastMerge or "-"),
				"Watchdog: " .. st.wd,
				"Error: " .. st.err,
			}, "\n"))
			local lines = {}
			for _, b in ipairs(BOSSES) do
				if table.find(e.bosses, b.name) then
					lines[#lines + 1] = ("%s: %s"):format(b.name, not gateOpen(b) and "ยังล็อก" or skipped(b) and ("ตีไม่ไหว ข้ามอีก %d นาที"):format(math.ceil((tooStrong[b.name] - os.clock()) / 60))
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
