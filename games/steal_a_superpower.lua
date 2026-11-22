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
	placeBest = false, autoPotion = false, pauseOnMove = true, antiAfk = true, reconnect = true}
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
	while alive() and e.boss and m.Parent and not m:GetAttribute("Dead") and not m:GetAttribute("DeadLocal") and os.clock() - t0 < 90 do
		local me = hum()
		if not me or me.Health <= 0 then giveUp("ตัวละครตาย"); return end
		if busyHands() then st.status = "พัก: " .. busyHands(); return end
		-- after 15 s: at this rate would it take more than 90 s? then it's out of reach for now
		local hn = m:FindFirstChildOfClass("Humanoid")
		if hp0 and hn and os.clock() - t0 > 15 then
			local rate = (hp0 - hn.Health) / (os.clock() - t0)
			if rate <= 0 or hn.Health / rate > 90 then giveUp("เลือดบอสลดช้าเกิน"); return end
		end
		local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
		if root then
			local r = hrp()
			local flat = r and (r.Position - root.Position) * Vector3.new(1, 0, 1)
			local dir = (flat and flat.Magnitude > 1) and flat.Unit or Vector3.new(0, 0, 1)
			if not r or (r.Position - root.Position).Magnitude > 14 then
				warp(root.Position + dir * (root.Size.X / 2 + 6), root.Position)
			end
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
loopEvery("Upgrade Train", 4, 30, function()
	if not e.upgradeTrain then return end
	local d = D()
	if not (d and d.Base) then return end
	local lvl = d.Base.Bench or 1
	if lvl >= BaseConfig.BenchMaxLevel then st.bench = "เบนช์เต็มแล้ว"; return end
	local cost = BaseConfig.BenchCost(lvl)
	st.bench = ("เบนช์ Lv %d · อัปต่อไป $%s"):format(lvl, short(cost))
	if Big.lt(d.Cash, cost) then return end
	local _, _, up = benchParts()
	if not up then return end
	if firePrompt(up) then
		task.wait(1)
		if D().Base.Bench > lvl then st.upgrades += 1 end
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
		if price and price > 0 and potion.Type then
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
local bossOpts, bossByLabel, bossDef = {}, {}, {}
for _, b in ipairs(BOSSES) do
	local label = bossLabel(b)
	bossOpts[#bossOpts + 1] = label
	bossByLabel[label] = b
	if table.find(e.bosses, b.name) then bossDef[#bossDef + 1] = label end
end
L:Dropdown({Name = "└ บอสที่จะตี (เลือกได้หลายตัว)", Multi = true, Required = false, Options = bossOpts, Default = bossDef,
	Callback = function(v)
		local names = {}
		for _, label in ipairs(picked(v)) do if bossByLabel[label] then names[#names + 1] = bossByLabel[label].name end end
		e.bosses = names; sv()
	end}, "SSPBosses")
L:Toggle({Name = "└ รอบอสที่เลือกเกิดครบทุกตัวก่อน แล้วไล่ตีรวดเดียว", Default = e.waitAll, Callback = function(v) e.waitAll = v; sv() end}, "SSPWaitAll")
L:Toggle({Name = "Auto Train (ไม่มีบอส → กลับไปยกเวทที่เบนช์)", Default = e.train, Callback = function(v) e.train = v; sv() end}, "SSPTrain")
L:Label({Text = "บอสที่เลือกตัวไหนเกิด (ตัวแรงสุดก่อน) → ลุกจากเบนช์ วาร์ปไปตี (ใช้ Auto Attack ของเกม)\nตายแล้วแพ็คบินเข้ากระเป๋า → กลับเบนช์ (อยู่ในโซนปลอดภัย แพ็คเข้าบัญชีเอง) → บอสเกิดใหม่ไปตีอีก"})
L:Header({Text = "การ์ด / อัปเกรด"})
L:Toggle({Name = "Auto Open Packs (เปิดแพ็คทั้งหมด)", Default = e.openPacks, Callback = function(v) e.openPacks = v; sv() end}, "SSPOpen")
L:Toggle({Name = "Auto Merge Card (รวมการ์ดซ้ำให้เลเวลขึ้น)", Default = e.merge, Callback = function(v) e.merge = v; sv() end}, "SSPMerge")
L:Toggle({Name = "Auto Equip Best Card in Base (วางการ์ดดีสุดในฐาน)", Default = e.placeBest, Callback = function(v) e.placeBest = v; sv() end}, "SSPBest")
L:Toggle({Name = "Auto Upgrade Train (อัปเบนช์ด้วยเงิน)", Default = e.upgradeTrain, Callback = function(v) e.upgradeTrain = v; sv() end}, "SSPUpTrain")
L:Toggle({Name = "Auto Buy Potion (ซื้อยาในร้านด้วยเงินเกม ไม่ใช้ Robux)", Default = e.autoPotion, Callback = function(v) e.autoPotion = v; sv() end}, "SSPPotion")
L:Toggle({Name = "Auto Rebirth (ถึงเลเวลที่ต้องการ → รีเบิร์ธ)", Default = e.rebirth, Callback = function(v) e.rebirth = v; sv() end}, "SSPRebirth")
L:Toggle({Name = "หยุดบอทตอนฉันกดเดินเอง", Default = e.pauseOnMove, Callback = function(v) e.pauseOnMove = v; sv() end}, "SSPPause")

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
				("ซื้อยา %d ขวด · ล่าสุด: %s"):format(st.potions or 0, tostring(st.lastPotion or "-")),
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
