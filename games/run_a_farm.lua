-- [UPD] Run A Farm! (placeId 79496881832552) -- Auto Farm (eggs -> stand, pens, quests, daily, pumpkin water) + Auto Upgrade
-- MacLib window, RightShift toggles it, settings persist (RunAFarm/state_<userId>.json).
--
-- How the game works (verified 2026-11-21):
--   State module (PlayerScripts.RunAFarmClient.State).data = server snapshot pushed on every change (coops, basket, stand, quests ...)
--   Remotes.Action:InvokeServer(name, ...) -> (ok, msg)
--     claimQuest(i) / claimDaily / upgradeStand("price") / buyChicken(coop) / hireWorker(role) / upgradeWorkers("speed"|"carry")
--     penMilk(i) / penDig(i) -> needs the character within reach (goat 8 / pig 7) -> "Get closer"
--   Zones are position checks on the server: standing in Coops.CoopN.CollectZone fills the bag with eggs,
--   standing in Stand.StockZone empties bag eggs onto the stand. Buy pads (Plot.Pads.*) buy when stepped on.
--   Pen animal i is ready when plot attribute "Goat<i>"/"Pig<i>" = "readyAt lag hold" has readyAt <= server time.

getgenv().__RAF = (getgenv().__RAF or 0) + 1
local G = getgenv().__RAF
pcall(function() if getgenv().__RAFW then getgenv().__RAFW:Unload() end end)
local function alive() return getgenv().__RAF == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local plr = Players.LocalPlayer

local RAF = RS:WaitForChild("RunAFarm")
local Action = RAF:WaitForChild("Remotes"):WaitForChild("Action")
local Cfg = RAF:WaitForChild("Config")
local Buttons = require(Cfg.Buttons)
local FarmCfg = require(Cfg.Farmyard)
local WorkCfg = require(Cfg.Workers)
local Tutorial = require(Cfg.Tutorial)
local State = require(plr:WaitForChild("PlayerScripts"):WaitForChild("RunAFarmClient"):WaitForChild("State"))

-- ------------------------------------------------------------------ settings
local SF = ("RunAFarm/state_%d.json"):format(plr.UserId)
local DEFAULTS = {farm = true, claim = true, mine = false, crop = false, seedBuy = false, seedPick = {}, seedMin = 20, seedMax = 100, evWater = false, evFeed = false, evFeedOver = false, upgrade = false, upgKeys = {"price", "hens", "hire", "workerUp", "crops", "pads"}, reserve = 0, pauseOnMove = true, reconnect = true, antiAfk = true}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
local function sv()
	pcall(function()
		if makefolder and not isfolder("RunAFarm") then makefolder("RunAFarm") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

local st = {status = "-", eggs = 0, trips = 0, quests = 0, lastQuest = "-", seed = "-", pens = 0, water = 0, buys = 0, lastBuy = "-", wd = "-", err = "-"}

-- ------------------------------------------------------------------ helpers
local function fmt(n)
	n = tonumber(n) or 0
	if n >= 1e9 then return ("%.2fB"):format(n / 1e9) end
	if n >= 1e6 then return ("%.2fM"):format(n / 1e6) end
	if n >= 1e3 then return ("%.1fK"):format(n / 1e3) end
	return tostring(math.floor(n))
end
local function D() return State.data end
local function plot() return State.myPlot() end
local function act(name, ...)
	local ok, r1, r2 = pcall(Action.InvokeServer, Action, name, ...)
	if not ok then return false, tostring(r1) end
	return r1, r2
end
local function now() return workspace:GetServerTimeNow() end
local function hum() local c = plr.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function hrp() local c = plr.Character; return c and c:FindFirstChild("HumanoidRootPart") end

-- the player moving by hand pauses every teleport job for a few seconds, so playing alongside the script works
local lastMove = 0
local function busyHands()
	local h = hum()
	if not h or not hrp() or h.Health <= 0 then return "ไม่มีตัวละคร" end
	if h.SeatPart then return "นั่งรถอยู่" end
	if e.pauseOnMove and os.clock() - lastMove < 2 then return "คุณกำลังเดินเอง" end
	return nil
end
local ownMove = false
-- manual control = movement keys / thumbstick / jump, read from input (the bot's own MoveTo walking never counts)
local UIS = game:GetService("UserInputService")
local MOVE_KEYS = {}
for _, k in ipairs({"W", "A", "S", "D", "Up", "Down", "Left", "Right", "Space"}) do MOVE_KEYS[Enum.KeyCode[k]] = true end
local function heldMoveKey()
	for k in pairs(MOVE_KEYS) do if UIS:IsKeyDown(k) then return true end end
	return false
end
local inputConn = UIS.InputChanged:Connect(function(io)
	if io.KeyCode == Enum.KeyCode.Thumbstick1 and io.Position.Magnitude > 0.3 then lastMove = os.clock() end
end)
task.spawn(function()
	while alive() do
		if not UIS:GetFocusedTextBox() and heldMoveKey() then lastMove = os.clock() end
		task.wait(0.1)
	end
end)

local PFS = game:GetService("PathfindingService")
local function zoneFloor(part, up) return Vector3.new(part.Position.X, part.Position.Y - part.Size.Y / 2 + (up or 3), part.Position.Z) end
local function waitFor(cond, t)
	local t0 = os.clock()
	while os.clock() - t0 < t do
		if cond() then return true end
		task.wait(0.1)
	end
	return cond()
end
-- nothing teleports: every job walks the character with PathfindingService waypoints (straight MoveTo when no path).
-- The server only counts zones / harvests / prompts where the character really stands -- there is no remote for them.
local function walkPath(target, near, timeout, keepGoing)
	local h, r = hum(), hrp()
	if not h or not r then return false end
	if (r.Position - target).Magnitude <= near then return true end
	local wps
	local path = PFS:CreatePath({AgentRadius = 1.8, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 5})
	local ok = pcall(function() path:ComputeAsync(r.Position, target) end)
	if ok and path.Status == Enum.PathStatus.Success then wps = path:GetWaypoints() else wps = {{Position = target, Action = Enum.PathWaypointAction.Walk}} end
	local t0 = os.clock()
	for _, wp in ipairs(wps) do
		if not keepGoing() or busyHands() then h:MoveTo(r.Position); return false end
		if wp.Action == Enum.PathWaypointAction.Jump then h.Jump = true end
		h:MoveTo(wp.Position)
		local w0, lastPos = os.clock(), r.Position
		while ((r.Position - wp.Position) * Vector3.new(1, 0, 1)).Magnitude > 2.5 do
			if (r.Position - target).Magnitude <= near then h:MoveTo(r.Position); return true end
			if os.clock() - t0 > timeout or not keepGoing() or busyHands() then h:MoveTo(r.Position); return false end
			if os.clock() - w0 > 1.5 then
				if (r.Position - lastPos).Magnitude < 1 then h.Jump = true end
				if os.clock() - w0 > 4 then break end
				lastPos = r.Position
			end
			task.wait(0.05)
		end
		if (r.Position - target).Magnitude <= near then h:MoveTo(r.Position); return true end
	end
	return (r.Position - target).Magnitude <= near + 1
end
-- zones are polled by the server about every 0.5 s, so standing DWELL seconds always counts
local DWELL = 0.6
local tripBusy = false
local function trip(fn)
	if not hrp() or tripBusy then return end
	tripBusy, ownMove = true, true
	local ok, err = pcall(fn)
	tripBusy, ownMove = false, false
	if not ok then st.err = tostring(err):sub(1, 120) end
end
local function go(pos, near, timeout) return walkPath(pos, near or 2.5, timeout or 30, alive) end

-- ------------------------------------------------------------------ eggs: coops -> bag -> stand
local function bagEggs(d) return (d.basket and d.basket.egg) or 0 end
local function coopEggs(d)
	local list, total = {}, 0
	for k, c in pairs(d.coops or {}) do
		local n = math.floor(tonumber(c.eggs) or 0)
		if n >= 1 then list[#list + 1] = {i = tonumber(k) or k, n = n}; total += n end
	end
	table.sort(list, function(a, b) return a.n > b.n end)
	return list, total
end
local function nestCap(d) return (d.owned and d.owned.StrawNests) and FarmCfg.NEST_BIG or FarmCfg.NEST end

local function eggJob()
	local d, p = D(), plot()
	if not d or not p then return end
	local bagRoom = (d.basketCap or 0) - (d.basketUsed or 0)
	local standRoom = (d.standCap or 0) - (d.standUsed or 0)
	local list, total = coopEggs(d)
	local full = list[1] and list[1].n >= nestCap(d) - 1
	local wantCollect = bagRoom >= 10 and standRoom >= 20 and total >= 10
	local wantStock = bagEggs(d) > 0 and standRoom >= 10
	if not wantCollect and not wantStock then return end
	trip(function()
		if wantCollect then
			-- plan from the snapshot (the State push lags the server by ~1-2 s): fill the bag, never more than the stand takes
			local room = math.min(bagRoom, standRoom - bagEggs(d))
			for _, c in ipairs(list) do
				if room < 5 then break end
				local z = p.Farmyard.Coops:FindFirstChild("Coop" .. c.i)
				z = z and z:FindFirstChild("CollectZone")
				if z then
					if not go(zoneFloor(z), 2, 30) then return end
					task.wait(DWELL)
					room -= c.n
				end
			end
		end
		if not go(zoneFloor(p.Farmyard.Stand.StockZone), 3, 40) then return end
		task.wait(DWELL)
		waitFor(function() local d3 = D(); return bagEggs(d3) == 0 or d3.standUsed >= d3.standCap end, 0.6)
		st.trips += 1
	end)
end
-- eggs counted from the server pushes: every drop of bag eggs is eggs put on the stand
local lastBag
local bagConn = State.changed.Event:Connect(function(d)
	local n = d and d.basket and (d.basket.egg or 0)
	if not n then return end
	if lastBag and n < lastBag then st.eggs += lastBag - n end
	lastBag = n
end)

-- ------------------------------------------------------------------ pens: milk goats / dig truffles when ready
local PEN = {
	{kind = "Goat", total = "PenGoats", action = "penMilk"},
	{kind = "Pig", total = "PenPigs", action = "penDig"},
}
local function readyPens()
	local p = plot()
	if not p or p:GetAttribute("PenAuto") then return {} end
	local out, t = {}, now()
	for _, k in ipairs(PEN) do
		for i = 1, p:GetAttribute(k.total) or 0 do
			local readyAt = tonumber((tostring(p:GetAttribute(k.kind .. i) or "")):match("^%S+"))
			if readyAt and readyAt <= t then out[#out + 1] = {k = k, i = i} end
		end
	end
	return out
end
local penBlock = {}
local function penJob()
	local p = plot()
	local list = readyPens()
	if #list == 0 then return end
	local folder = workspace:FindFirstChild("RunAFarmPens")
	folder = folder and folder:FindFirstChild(p.Name)
	trip(function()
		for _, a in ipairs(list) do
			local key = a.k.kind .. a.i
			if (penBlock[key] or 0) < os.clock() then
				local ok, msg = act(a.k.action, a.i)
				for _ = 1, 4 do
					if ok or msg ~= "Get closer" then break end
					local m = folder and folder:FindFirstChild(key)
					if not m then break end
					go(m:GetPivot().Position + Vector3.new(0, 2, 0), 4, 20)
					ok, msg = act(a.k.action, a.i)
				end
				if ok then st.pens += 1 else penBlock[key] = os.clock() + 20 end
			end
		end
	end)
end

-- ------------------------------------------------------------------ Weigh-off pumpkin: water when dry (free)
local function waterJob()
	local d, p = D(), plot()
	local w = d and d.weighoff
	if not w or not w.open or w.phase ~= "live" then return end
	if (tonumber(w.wetUntil) or 0) > now() then return end
	local pr = p and p:FindFirstChild("WeighoffPatch")
	pr = pr and pr:FindFirstChild("WaterPrompt", true)
	if not pr or not pr.Enabled or not fireproximityprompt then return end
	local at = pr.Parent
	local pos = at:IsA("Attachment") and at.WorldPosition or at.Position
	trip(function()
		if not go(pos + Vector3.new(0, 2, 0), 7, 40) then return end
		task.wait(0.2)
		fireproximityprompt(pr)
		if waitFor(function() return (tonumber(D().weighoff.wetUntil) or 0) > now() end, 3) then st.water += 1 end
	end)
end

-- ------------------------------------------------------------------ Auto Mine (walks, never teleports)
-- Server rules (tested): MineAim:FireServer("Main", index) chips the aimed block while it is within Mine.REACH (16) of the Head;
-- a block 43 studs away never breaks, one 4 studs away broke in ~1 s. Only exposed blocks exist as parts (Plot.Mine.Wall.Main.B<col>_<depth>_<row>,
-- attribute Type = ore id or "stone"). Ore goes into the bag; standing in Mine.Depots.Depot.DropZone sells it.
-- Elevator: MineHead.CageFloor RidePrompt ("Ride down") on the surface, Mine.Landing.CageFloor RidePrompt ("Ride up") below.
local MineCfg = require(Cfg.Mine)
local MineAim = RAF.Remotes:WaitForChild("MineAim")
local ORE_RANK = {}
for i, id in ipairs(MineCfg.ORDER) do ORE_RANK[id] = i end
local mineBlock = {}
st.mine, st.ores, st.mineSold = "-", 0, 0

local function mineOn() return alive() and e.mine end
local function inMine() local r = hrp(); return r and r.Position.Y < MineCfg.FLOOR + 30 end
local function headPos() local c = plr.Character; local h = c and (c:FindFirstChild("Head") or c:FindFirstChild("HumanoidRootPart")); return h and h.Position end

local function walkTo(target, near, timeout) return walkPath(target, near, timeout, mineOn) end

local function oreValue(t) return (MineCfg.ORES[t] and MineCfg.ORES[t].value) or MineCfg.STONE.value end
local function blockIndex(b)
	local c, dpt, row = b.Name:match("^B(%d+)_(%d+)_(%d+)$")
	if not c then return end
	return MineCfg.index(MineCfg.FACES.Main, tonumber(c), tonumber(dpt), tonumber(row)), tonumber(dpt), tonumber(row)
end

-- best exposed block: ores by value (closer wins ties), stone only when no ore is left in reach of the floor;
-- stone picks the deepest one so the tunnel heads for the richer bands
local function pickBlock(face, head)
	local bestOre, bestOreS, bestStone, bestStoneS
	local t = os.clock()
	for _, b in ipairs(face:GetChildren()) do
		if (mineBlock[b] or 0) < t then
			local idx, dpt, row = blockIndex(b)
			-- on foot only bands <= FOOT_TIER (coal, copper) break; deeper ones need the Rock Buggy and just eat time
			if idx and row <= 5 and MineCfg.bandAt(dpt) <= MineCfg.FOOT_TIER then
				local typ = b:GetAttribute("Type") or "stone"
				local dist = (b.Position - head).Magnitude
				if ORE_RANK[typ] then
					-- a block already in reach costs no walk: weight it over a slightly richer one across the cave
					local s = oreValue(typ) / (1 + dist / 25) * (dist <= MineCfg.REACH - 1 and 2.5 or 1)
					if not bestOreS or s > bestOreS then bestOre, bestOreS = b, s end
				else
					local s = dpt * 10 - dist
					if not bestStoneS or s > bestStoneS then bestStone, bestStoneS = b, s end
				end
			end
		end
	end
	return bestOre or bestStone
end

-- keep the aim fresh (server drops a stale aim) and react the frame the block part is removed
local function chip(b, idx, typ, dpt)
	local limit = 2 + 4 * MineCfg.hardAt(typ, dpt)
	local t0, sent = os.clock(), 0
	while b.Parent and os.clock() - t0 < limit do
		if not mineOn() or busyHands() then break end
		local hp = headPos()
		if not hp or (b.Position - hp).Magnitude > MineCfg.REACH - 0.5 then break end
		if os.clock() - sent >= 0.15 then MineAim:FireServer("Main", idx); sent = os.clock() end
		task.wait()
	end
	return b.Parent == nil
end

local function oreInBag(d)
	local n = 0
	for id in pairs(MineCfg.ORES) do n += (d.basket and d.basket[id]) or 0 end
	return n + ((d.basket and d.basket.stone) or 0)
end

local function rideElevator(model, wantDown)
	local pr = model and model:FindFirstChild("RidePrompt", true)
	if not pr then return false end
	local at = pr.Parent:IsA("Attachment") and pr.Parent.WorldPosition or pr.Parent.Position
	if not walkTo(at, math.max(3, pr.MaxActivationDistance - 2), 40) then return false end
	if fireproximityprompt then fireproximityprompt(pr) end
	return waitFor(function() return inMine() == wantDown end, 15)
end

local function mineStep()
	local d, p = D(), plot()
	if not d or not p then st.mine = "รอข้อมูลฟาร์ม"; return end
	local why = busyHands()
	if why then st.mine = "พัก: " .. why; return end
	local mine = p:FindFirstChild("Mine")
	local face = mine and mine:FindFirstChild("Wall") and mine.Wall:FindFirstChild("Main")
	if not face then st.mine = "ยังไม่มีเหมือง (ซื้อ Mine Shaft ก่อน)"; return end
	if not inMine() then
		-- you came up yourself: don't drag the character back down while you're still playing up here
		local idle = os.clock() - lastMove
		if idle < 60 then st.mine = ("อยู่บนดิน · ไม่กดเดิน %d วิ บอทจะลงลิฟต์เอง"):format(math.ceil(60 - idle)); task.wait(1); return end
		st.mine = "เดินไปลิฟต์ ลงเหมือง"
		rideElevator(p:FindFirstChild("MineHead"), true)
		return
	end
	local full = (d.basketCap or 0) - (d.basketUsed or 0) < 2
	if full and oreInBag(d) > 0 then
		local dz = mine.Depots:FindFirstChild("DropZone", true)
		if not dz then st.mine = "หา Ore Depot ไม่เจอ"; return end
		st.mine = "ถุงเต็ม → เดินไปขายที่ Ore Depot"
		local spot = Vector3.new(dz.Position.X, dz.Position.Y - dz.Size.Y / 2 + 3, dz.Position.Z)
		if walkTo(spot, 4, 45) then
			local before = oreInBag(D())
			waitFor(function() return oreInBag(D()) == 0 end, 4)
			st.mineSold += before - oreInBag(D())
		end
		return
	end
	if full then st.mine = "ถุงเต็ม (ไม่ใช่แร่) — เอาของในถุงไปลงก่อน"; return end
	local hp = headPos()
	local b = hp and pickBlock(face, hp)
	if not b then st.mine = "ไม่มีก้อนที่เดินเท้าขุดได้ (ชั้นถ่านหิน/ทองแดง)"; MineAim:FireServer(nil); task.wait(1); return end
	local idx, dpt = blockIndex(b)
	local typ = b:GetAttribute("Type") or "stone"
	if (b.Position - hp).Magnitude > MineCfg.REACH - 2 then
		st.mine = ("เดินไปขุด %s"):format(typ)
		MineAim:FireServer(nil)
		local out = p:GetPivot():VectorToWorldSpace(Vector3.new(MineCfg.FACES.Main.out.X, 0, MineCfg.FACES.Main.out.Y))
		local spot = Vector3.new(b.Position.X, MineCfg.FLOOR + 3, b.Position.Z) + out * 5
		walkTo(spot, 6, 25)
		hp = headPos()
		if not hp or (b.Position - hp).Magnitude > MineCfg.REACH - 1 then mineBlock[b] = os.clock() + 60; return end
	end
	st.mine = ("ขุด %s"):format(typ)
	if not chip(b, idx, typ, dpt) then mineBlock[b] = os.clock() + 30; MineAim:FireServer(nil) end
end

-- ores counted from the server pushes (bag ore going up = mined)
local lastOre
local oreConn = State.changed.Event:Connect(function(d)
	if not d or not d.basket then return end
	local n = 0
	for id in pairs(MineCfg.ORES) do n += d.basket[id] or 0 end
	if lastOre and n > lastOre and e.mine then st.ores += n - lastOre end
	lastOre = n
end)

task.spawn(function()
	while alive() do
		if e.mine then
			local ok, err = true, nil
			if not tripBusy then tripBusy = true; ok, err = pcall(mineStep); tripBusy = false end
			if not ok then st.err = "mine: " .. tostring(err):sub(1, 110); task.wait(1) end
			task.wait()
		else
			st.mine = "ปิดอยู่"
			task.wait(0.5)
		end
	end
end)

-- ------------------------------------------------------------------ Auto Farm Crop
-- Server rules (tested 2026-11-21): a field's Screen "Status" label reads "<crop> NN%" while growing, "<crop> - Ripe!" when ripe,
-- "Empty - plant seeds" when bare. Ripe crops (Fields.FieldN.Crops.<cell> parts) go into the bag when the character passes
-- within Game.HAND_REACH (4.2) -- a 0.12 s hop per crop counted every time. PlantPrompt only works within 11 studs of the Screen
-- (fired from 205 studs: nothing). Bag crops are dropped by standing in Storage.DropOff.DropZone (Zone=DropOff).
local GameCfg = require(Cfg.Game)
st.crop, st.harvested, st.cropDrops, st.planted = "-", 0, 0, 0

local function fieldStatus(f)
	local s = f:FindFirstChild("Status", true)
	return s and s:IsA("TextLabel") and s.Text or ""
end
local function isCrop(d, k) return k ~= "egg" and d.unlocked and d.unlocked[k] ~= nil end
local function cropsInBag(d)
	local n = 0
	for k, v in pairs(d.basket or {}) do if isCrop(d, k) then n += v end end
	return n
end
local function bagRoom(d) return (d.basketCap or 0) - (d.basketUsed or 0) end
local function storageFull(d) return (d.storageUsed or 0) >= (d.storageCap or 0) - 2 end
local function cropOn() return alive() and e.crop end

local function moveNear(pos, near, timeout)
	if ((hrp() and hrp().Position or pos) - pos).Magnitude > 25 then return walkPath(pos, near, timeout, cropOn) end
	local h, r = hum(), hrp()
	if not h or not r then return false end
	local t0 = os.clock()
	h:MoveTo(pos)
	while ((r.Position - pos) * Vector3.new(1, 0, 1)).Magnitude > near do
		if os.clock() - t0 > timeout or not e.crop or busyHands() then h:MoveTo(r.Position); return false end
		if os.clock() - t0 > 1.2 and r.AssemblyLinearVelocity.Magnitude < 1 then h.Jump = true; h:MoveTo(pos) end
		task.wait(0.05)
	end
	return true
end
local function cropRun(fn)
	trip(fn)
end

-- ------------------------------------------------------------------ Event: Weigh-off giant pumpkin (Event tab)
-- WeighoffPatch.FeedCart FeedPrompt / WaterBarrel WaterPrompt: server prompts, 11 studs, hold 0.25 -> walk there and press.
-- Feed tips the bag's crops into the wheelbarrow: Weighoff.DAILY_LB (1500) a day counts fully, after that AFTER_CAP (20%).
-- Water is free: WATER_HOURS (3 h) of WATER_LB_HOUR (75 lb/h) growth.
local WeighCfg = require(Cfg.Weighoff)
st.ev, st.fed, st.feeds = "-", 0, 0
local function weighLive(d) local w = d and d.weighoff; return w and w.open and w.phase == "live" and w or nil end
local function wantFeed(d)
	local w = weighLive(d)
	if not e.evFeed or not w or cropsInBag(d) <= 0 then return false end
	return (w.fedToday or 0) < WeighCfg.DAILY_LB or e.evFeedOver
end
local function pressPrompt(pr)
	if fireproximityprompt then pcall(fireproximityprompt, pr); return end
	pr:InputHoldBegin(); task.wait(pr.HoldDuration + 0.1); pr:InputHoldEnd()
end
-- runs inside a trip: walk to the wheelbarrow, press Feed until the bag's crops stop going down
local function feedNow(p)
	local patch = p:FindFirstChild("WeighoffPatch")
	local pr = patch and patch:FindFirstChild("FeedPrompt", true)
	if not pr or not pr.Enabled then return false end
	local at = pr.Parent:IsA("Attachment") and pr.Parent.WorldPosition or pr.Parent.Position
	st.ev = ("เดินไปป้อน %d ชิ้นที่รถเข็น"):format(cropsInBag(D()))
	if not walkPath(at + Vector3.new(0, 2, 0), pr.MaxActivationDistance - 4, 45, alive) then return false end
	local fed0 = (D().weighoff and D().weighoff.fedToday) or 0
	for _ = 1, 8 do
		local before = cropsInBag(D())
		if before <= 0 or not wantFeed(D()) then break end
		pressPrompt(pr)
		if not waitFor(function() return cropsInBag(D()) < before end, 2.5) then break end
	end
	local gained = ((D().weighoff and D().weighoff.fedToday) or 0) - fed0
	if gained > 0 then st.fed += gained; st.feeds += 1 end
	return true
end

local function dropCrops(p)
	local dz = p:FindFirstChild("Storage") and p.Storage:FindFirstChild("DropOff")
	dz = dz and dz:FindFirstChild("DropZone")
	if not dz then st.crop = "ยังไม่มีจุด DropOff (สร้าง Storage ก่อน)"; return false end
	-- Auto Feed on: the pumpkin gets the bag first, the storage only what's left
	if wantFeed(D()) then
		st.crop = "ถุงเต็ม → เอาไปป้อนฟักทองก่อน"
		feedNow(p)
		if cropsInBag(D()) == 0 then st.cropDrops += 1; return true end
	end
	st.crop = ("ถุงเต็ม → drop %d ชิ้นที่ Storage"):format(cropsInBag(D()))
	if not moveNear(Vector3.new(dz.Position.X, dz.Position.Y - dz.Size.Y / 2, dz.Position.Z), 6, 30) then return false end
	task.wait(DWELL)
	waitFor(function() return cropsInBag(D()) == 0 or storageFull(D()) end, 3)
	st.cropDrops += 1
	return true
end

-- snake order across the grid so each hop is one cell away
local function snake(list)
	table.sort(list, function(a, b)
		local ca, cb = math.floor(a.Position.X / GameCfg.CELL + 0.5), math.floor(b.Position.X / GameCfg.CELL + 0.5)
		if ca ~= cb then return ca < cb end
		if ca % 2 == 0 then return a.Position.Z < b.Position.Z end
		return a.Position.Z > b.Position.Z
	end)
	return list
end

local function harvestField(p, f)
	local crops = f:FindFirstChild("Crops")
	if not crops then return end
	local list = snake(crops:GetChildren())
	local room = bagRoom(D())
	cropRun(function()
		for _, c in ipairs(list) do
			if not e.crop or busyHands() then break end
			if room < 1 then
				if storageFull(D()) then st.crop = "คลังเต็ม รอรถขนออกก่อน"; break end
				if not dropCrops(p) then break end
				room = bagRoom(D())
				if room < 1 then break end
			end
			if c.Parent == crops then
				st.crop = ("เก็บ %s"):format(f.Name)
				moveNear(c.Position, 2.5, 3)
				room -= 1
			end
		end
		if cropsInBag(D()) > 0 and bagRoom(D()) < 15 and not storageFull(D()) then dropCrops(p) end
	end)
end

local function pickSeed(d)
	local sel = d.selected
	if sel and ((d.seeds and d.seeds[sel]) or 0) > 0 then return sel end
	local best, bestN = nil, 0
	for k, n in pairs(d.seeds or {}) do if n > bestN and d.unlocked and d.unlocked[k] then best, bestN = k, n end end
	if best then act("selectSeed", best); return best end
	return nil
end

-- ------------------------------------------------------------------ Auto Buy Crop (seed bags)
-- buySeeds(id, n) takes any n in one call (tested: 25 wheat in one go); locked crops answer "... seeds are still locked".
-- The State push lags ~1-2 s, so a crop just bought is skipped for a few seconds instead of being bought twice.
local CropCfg = require(Cfg.Crops)
local SEED_IDS = CropCfg.seeds or {"wheat", "carrot", "corn", "potato", "pumpkin"}
st.seedBuy, st.seedBought, st.seedSpent, st.upgWait = "-", 0, 0, "-"
local seedBoughtAt = {}
local function seedName(id) local c = CropCfg[id]; return (c and c.name) or id end
local function seedBuyStep()
	local d = D()
	if not d or not d.seeds then return end
	local lo = math.max(0, math.floor(tonumber(e.seedMin) or 0))
	local hi = math.max(lo + 1, math.floor(tonumber(e.seedMax) or 0))
	local notes = {}
	for _, id in ipairs(e.seedPick or {}) do
		local c = CropCfg[id]
		local have = d.seeds[id] or 0
		if c and c.seedPrice and os.clock() - (seedBoughtAt[id] or 0) > 5 then
			if d.unlocked and d.unlocked[id] == false then
				notes[#notes + 1] = seedName(id) .. " ยังล็อก"
			elseif have < lo then
				local budget = (D().cash or 0) - (tonumber(e.reserve) or 0)
				local need = math.min(hi - have, math.floor(budget / c.seedPrice))
				if need <= 0 then
					notes[#notes + 1] = ("%s เงินไม่พอ ($%s/ถุง)"):format(seedName(id), fmt(c.seedPrice))
				else
					local ok, msg = act("buySeeds", id, need)
					if ok then
						seedBoughtAt[id] = os.clock()
						st.seedBought += need
						st.seedSpent += need * c.seedPrice
						notes[#notes + 1] = ("ซื้อ %s %d ถุง (%d → %d)"):format(seedName(id), need, have, have + need)
					else
						notes[#notes + 1] = seedName(id) .. ": " .. tostring(msg):gsub("[\128-\255]+", "")
					end
				end
			end
		end
	end
	st.seedBuy = #notes > 0 and table.concat(notes, " · ") or ("เมล็ดพอ (ต่ำกว่า %d → ซื้อถึง %d)"):format(lo, hi)
end
task.spawn(function()
	while alive() do
		if e.seedBuy then
			local ok, err = pcall(seedBuyStep)
			if not ok then st.err = "seed: " .. tostring(err):sub(1, 110) end
		else
			st.seedBuy = "ปิดอยู่"
		end
		task.wait(3)
	end
end)

local function plantField(p, f)
	local seed = pickSeed(D())
	if not seed then st.crop = "เมล็ดหมด (เปิด Auto Buy Crop ในแท็บ Auto Buy)"; return end
	local pr = f:FindFirstChild("PlantPrompt", true)
	if not pr or not pr.Enabled or not fireproximityprompt then return end
	local at = pr.Parent:IsA("Attachment") and pr.Parent.WorldPosition or pr.Parent.Position
	cropRun(function()
		st.crop = ("ปลูก %s ที่ %s"):format(seed, f.Name)
		if not moveNear(at + f.Screen.CFrame.LookVector * 4, pr.MaxActivationDistance - 3, 20) then return end
		task.wait(0.15)
		fireproximityprompt(pr)
		if waitFor(function() return not fieldStatus(f):find("Empty") end, 2) then st.planted += 1 end
	end)
end

local function cropStep()
	local d, p = D(), plot()
	if not d or not p then st.crop = "รอข้อมูลฟาร์ม"; return end
	local why = busyHands()
	if why then st.crop = "พัก: " .. why; return end
	if e.mine and inMine() then st.crop = "รอ Auto Mine (อยู่ในเหมือง)"; return end
	if cropsInBag(d) > 0 and bagRoom(d) < 5 and not storageFull(d) then cropRun(function() dropCrops(p) end); return end
	local ripe, empty
	for i = 1, 9 do
		local f = p.Fields:FindFirstChild("Field" .. i)
		if f then
			local s = fieldStatus(f)
			if s:find("Ripe") and f:FindFirstChild("Crops") and #f.Crops:GetChildren() > 0 then ripe = ripe or f
			elseif s:find("Empty") then empty = empty or f end
		end
	end
	if ripe and not storageFull(d) then harvestField(p, ripe); return end
	if empty then plantField(p, empty); return end
	if cropsInBag(d) >= 20 and not storageFull(d) then cropRun(function() dropCrops(p) end); return end
	st.crop = storageFull(d) and "คลังเต็ม รอรถขนออก" or "รอพืชโต"
end

local lastCrop
local cropConn = State.changed.Event:Connect(function(d)
	if not d or not d.basket then return end
	local n = cropsInBag(d)
	if lastCrop and n > lastCrop and e.crop then st.harvested += n - lastCrop end
	lastCrop = n
end)

task.spawn(function()
	while alive() do
		if e.crop then
			local ok, err = pcall(cropStep)
			if not ok then st.err = "crop: " .. tostring(err):sub(1, 110) end
		else
			st.crop = "ปิดอยู่"
		end
		task.wait(0.5)
	end
end)

task.spawn(function()
	while alive() do
		local d, p = D(), plot()
		if not (e.evWater or e.evFeed) then
			st.ev = "ปิดอยู่"
		elseif not d or not p then
			st.ev = "รอข้อมูลฟาร์ม"
		elseif not weighLive(d) then
			st.ev = "อีเวนต์ Weigh-off ไม่เปิดตอนนี้"
		elseif busyHands() then
			st.ev = "พัก: " .. busyHands()
		elseif e.evWater and (tonumber(d.weighoff.wetUntil) or 0) <= now() and not tripBusy then
			st.ev = "เดินไปรดน้ำที่ถัง"
			pcall(waterJob)
		elseif wantFeed(d) and not tripBusy then
			trip(function() feedNow(p) end)
		elseif e.evFeed and (d.weighoff.fedToday or 0) >= WeighCfg.DAILY_LB and not e.evFeedOver then
			st.ev = "ป้อนครบโควต้าวันนี้แล้ว (1,500 lb)"
		elseif e.evFeed and cropsInBag(d) <= 0 then
			st.ev = "รอพืชในถุง (เปิด Auto Farm Crop จะเก็บมาป้อนให้)"
		else
			st.ev = "รอ (น้ำยังไม่แห้ง)"
		end
		task.wait(2)
	end
end)

-- ------------------------------------------------------------------ remote chores
local seedAt = 0
local function claimJob()
	local d = D()
	if not d then return end
	for i, q in pairs(d.quests or {}) do
		if q.goal and q.have and q.have >= q.goal then
			local ok, msg = act("claimQuest", tonumber(i) or i)
			if ok then
				st.quests += 1
				st.lastQuest = ("%s %s +$%s"):format(tostring(q.kind), tostring(q.item), fmt(q.reward))
			elseif msg then
				st.lastQuest = "รับไม่ได้: " .. tostring(msg):gsub("[\128-\255]+", "")
			end
		end
	end
	if d.daily and d.daily.ready and not d.daily.claimed then act("claimDaily") end
	-- field hands plant the selected seed: point it at the crop a harvest/deliver quest is asking for
	if os.clock() - seedAt < 10 then return end
	local want
	for _, q in pairs(d.quests or {}) do
		if (q.kind == "harvest" or q.kind == "deliver") and q.item and (q.have or 0) < (q.goal or 0)
			and d.unlocked and d.unlocked[q.item] and ((d.seeds and d.seeds[q.item]) or 0) > 0 then
			if not want or q.kind == "harvest" then want = q.item end
		end
	end
	if want and d.selected ~= want then
		seedAt = os.clock()
		if act("selectSeed", want) then st.seed = want end
	end
end

-- ------------------------------------------------------------------ auto upgrade: cheapest affordable thing first
local function reqMet(d, b)
	for _, r in ipairs(b.requires or {}) do if not d.owned[r] then return false end end
	return true
end
-- Value model: every purchase gets an estimated extra $/s from the game's own config, payback = price / gain.
-- Cheapest payback goes first. Things the config gives no income figure for (fields, greenhouses, fishing, orchard,
-- workers, crop unlocks) are assumed to pay back in UNKNOWN_PAYBACK, so among them the cheapest wins.
-- Pure storage / speed items (oil tanks, horses) earn nothing by themselves; a tank still counts through the rig it unlocks.
local OilCfg, RanchCfg = require(Cfg.Oil), require(Cfg.Ranch)
local UNKNOWN_PAYBACK = 1800
local function eggSales(p)
	local stand = p and p:FindFirstChild("Farmyard") and p.Farmyard:FindFirstChild("Stand")
	local perMin = stand and stand:GetAttribute("PerMin") or 0
	local avgBuy = (FarmCfg.BUY and (FarmCfg.BUY[1] + FarmCfg.BUY[2]) / 2) or 4
	return perMin * avgBuy / 60, (stand and stand:GetAttribute("EggPrice")) or 0
end
local function oilMult(d) return d.owned.Refinery and (OilCfg.REFINERY or 1) or 1 end
local function ownedCount(d, pads) local n = 0 for _, id in ipairs(pads or {}) do if d.owned[id] then n += 1 end end return n end
-- extra $/s, 0 = earns nothing by itself, nil = unknown
local function gainOf(d, p, b)
	local desc = b.desc or ""
	local rate = tonumber(desc:match("^%+(%d+) oil a second"))
	if rate then return rate * (OilCfg.PRICE or 0) * oilMult(d) end
	if b.id == "Refinery" then
		local r = 0
		for _, rig in ipairs(OilCfg.RIGS or {}) do if d.owned[rig.id] then r += rig.rate or 0 end end
		return r * (OilCfg.PRICE or 0) * ((OilCfg.REFINERY or 1) - 1)
	end
	if b.kind == "oil" and desc:find("^Holds") then return 0 end
	local sheep = RanchCfg.SHEEP and RanchCfg.SHEEP.pay / RanchCfg.SHEEP.every or 0
	if desc == "+1 sheep" then return sheep * (d.owned.AutoShearer and 1 or 0.25) end
	if b.id == "AutoShearer" then return ownedCount(d, RanchCfg.SHEEP and RanchCfg.SHEEP.pads) * sheep * 0.75 end
	if desc == "+1 cow" and RanchCfg.COW then return RanchCfg.COW.pay / RanchCfg.COW.every end
	if b.kind == "ranch" and desc:lower():find("horse") then return 0 end
	local pct = tonumber(desc:match("^%+(%d+)%% customers")) or tonumber(desc:match("^(%d+)%% more customers"))
	if pct then local eps, price = eggSales(p); return eps * price * pct / 100 end
	return nil
end
local function payback(cost, gain)
	if gain == nil then return UNKNOWN_PAYBACK end
	if gain <= 0 then return math.huge end
	return cost / gain
end
local function candidates(d, p)
	local out = {}
	local cash = d.cash or 0
	if p and p:FindFirstChild("Pads") then
		for _, pad in ipairs(p.Pads:GetChildren()) do
			local id = pad:GetAttribute("PadId")
			local b = id and Buttons.byId[id]
			local top = pad:FindFirstChild("Top")
			if b and top and not d.owned[id] and reqMet(d, b) and (top.Position.Y > -50) == not inMine() then
				local price = Tutorial.free(d, id) and 0 or b.price
				local g = gainOf(d, p, b)
				local pb = payback(price, g)
				-- a pad that unlocks a money-maker (tank -> pumpjack) is worth that next step: price both, earn its gain
				for _, x in ipairs(Buttons.list) do
					if not d.owned[x.id] and table.find(x.requires or {}, id) then
						local gx = gainOf(d, p, x)
						if gx and gx > 0 then pb = math.min(pb, (price + x.price) / gx) end
					end
				end
				out[#out + 1] = {cost = price, name = b.name or id, pad = top, gain = g, pb = pb}
			end
		end
	end
	local c = FarmCfg.standUpgradeCost("price", (d.standLevels and d.standLevels.price) or 0)
	if c then
		local eps = eggSales(p)
		local g = eps * (FarmCfg.PRICE_STEP or 0.5)
		out[#out + 1] = {cost = c, name = "ราคาไข่", call = {"upgradeStand", "price"}, gain = g, pb = payback(c, g)}
	end
	for k, coop in pairs(d.coops or {}) do
		local n = coop.chickens or 0
		if n < FarmCfg.MAX_CHICKENS then
			local cost = FarmCfg.chickenPrice(n + 1)
			out[#out + 1] = {cost = cost, name = "ไก่เล้า " .. k, call = {"buyChicken", tonumber(k) or k}, pb = payback(cost, nil)}
		end
	end
	for key, u in pairs(WorkCfg.UPGRADES or {}) do
		local cost = WorkCfg.upgradeCost(key, (d.workerLevels and d.workerLevels[key]) or 0)
		if cost then out[#out + 1] = {cost = cost, name = u.name, call = {"upgradeWorkers", key}, pb = payback(cost, nil)} end
	end
	for _, role in ipairs(WorkCfg.ORDER or {}) do
		local r = WorkCfg.ROLES[role]
		local have = (d.workers and d.workers[role]) or 0
		local need = WorkCfg.requirement(role, have)
		local cost = WorkCfg.hireCost(role, have)
		if r and cost and (need == nil or d.owned[need]) then
			out[#out + 1] = {cost = cost, name = "จ้าง " .. r.name, call = {"hireWorker", role}, pb = payback(cost, nil)}
		end
	end
	for _, id in ipairs(CropCfg.seeds or {}) do
		local cc = CropCfg[id]
		if cc and cc.unlockPrice and d.unlocked and d.unlocked[id] == false and (not cc.needs or d.owned[cc.needs]) then
			out[#out + 1] = {cost = cc.unlockPrice, name = "ปลดล็อก " .. (cc.name or id), call = {"unlockCrop", id}, pb = payback(cc.unlockPrice, nil)}
		end
	end
	table.sort(out, function(a, b)
		if a.pb ~= b.pb then return a.pb < b.pb end
		return a.cost < b.cost
	end)
	return out, cash
end
-- pick: best payback we can afford now -- but keep saving when the overall best is within 2x of the budget
-- and the affordable one is 3x+ slower to pay back
local failUntil = {}
local function pickUpgrade(list, budget)
	local best = list[1]
	for _, c in ipairs(list) do
		if c.cost <= budget and (failUntil[c.name] or 0) < os.clock() then
			if c ~= best and best and best.cost <= budget * 2 and c.pb > best.pb * 3 then return nil, best end
			return c, best
		end
	end
	return nil, best
end
local function upgradeJob()
	if not e.upgrade then return end
	local d, p = D(), plot()
	if not d then return end
	local list, cash = candidates(d, p)
	local c, best = pickUpgrade(list, cash - (tonumber(e.reserve) or 0))
	if not c then
		st.upgWait = best and ("เก็บเงินรอ %s ($%s)"):format(best.name, fmt(best.cost)) or "ไม่มีอะไรให้อัป"
		return
	end
	st.upgWait = "-"
	local ok, msg
	if c.pad then
		if busyHands() then return end
		trip(function()
			if go(c.pad.Position + Vector3.new(0, 3, 0), 2, 45) then
				ok = waitFor(function() return (D().cash or 0) < cash end, 2.5)
			end
		end)
	else
		ok, msg = act(table.unpack(c.call))
	end
	if ok then
		st.buys += 1
		st.lastBuy = ("%s ($%s)"):format(c.name, fmt(c.cost))
		return
	end
	failUntil[c.name] = os.clock() + 30
	if msg then st.lastBuy = ("ซื้อ %s ไม่ได้: %s"):format(c.name, (tostring(msg):gsub("[\128-\255]+", ""))) end
end

-- ------------------------------------------------------------------ main loop + watchdog
local beat = os.clock()
task.spawn(function()
	local tick = 0
	while alive() do
		tick += 1
		beat = os.clock()
		if e.claim and D() then
			local ok, err = pcall(claimJob)
			if not ok then st.err = tostring(err):sub(1, 120) end
		end
		if e.farm and D() and plot() then
			local ok, err = pcall(function()
				local why = busyHands()
				if why then
					st.status = "พักการวาร์ป: " .. why
				else
					st.status = "ฟาร์มอยู่"
					eggJob()
					if not busyHands() then penJob() end
				end
				if tick % 5 == 0 then upgradeJob() end
			end)
			if not ok then st.err = tostring(err):sub(1, 120) end
		elseif not e.farm then
			st.status = "ปิดอยู่"
			if tick % 5 == 0 then pcall(upgradeJob) end
		else
			st.status = "รอข้อมูลฟาร์ม"
		end
		task.wait(1)
	end
end)
task.spawn(function()
	while alive() do
		task.wait(10)
		if os.clock() - beat > 30 then
			st.wd = "ลูปค้าง → เริ่มใหม่ · " .. os.date("%H:%M:%S")
			ownMove = false
			beat = os.clock()
		end
	end
end)

-- anti-AFK: Roblox's 20-minute idle kick fires Players.LocalPlayer.Idled first; a virtual click resets it
local VirtualUser = game:GetService("VirtualUser")
local idleConn = plr.Idled:Connect(function()
	if not alive() or not e.antiAfk then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
	st.wd = "anti-AFK กันเตะ · " .. os.date("%H:%M:%S")
end)

-- auto reconnect: rejoin only on a real disconnect code (Enum.ConnectionError 256-511: lost connection, kicked, idle, timeout).
-- Teleport / place-launch failures (512+) never retrigger it, so a failed hop can't snowball into the server-hop loop
-- the Last Z rejoin hit (2026-11-20). 273/274 = this account joined somewhere else: rejoining would kick that session.
-- After the hop, loader.lua (queue_on_teleport / cp_boot) loads this script again with the saved settings.
local GuiService = game:GetService("GuiService")
local TeleportService = game:GetService("TeleportService")
local SKIP_CODES = {[273] = true, [274] = true}
local rejoining = false
local function reconnect()
	if rejoining or not e.reconnect or not alive() then return end
	local ok, code = pcall(function() return GuiService:GetErrorCode().Value end)
	if not ok or type(code) ~= "number" or code < 256 or code >= 512 or SKIP_CODES[code] then return end
	rejoining = true
	st.wd = ("หลุด (code %d) → กำลังเข้าเกมใหม่ · %s"):format(code, os.date("%H:%M:%S"))
	task.spawn(function()
		task.wait(5)
		for _ = 1, 20 do   -- a full / restarting server can refuse for a while: ~5 min of tries
			if not e.reconnect or not alive() then break end
			pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
			task.wait(15)
		end
		rejoining = false
	end)
end
local errConn = GuiService.ErrorMessageChanged:Connect(function() task.defer(reconnect) end)

-- ---------------------------------------------------------------------- UI
local okL, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okL or not Lib then warn("[RunAFarm] MacLib failed: " .. tostring(Lib)) return end
if not alive() then return end
local Win = Lib:Window({Title = "Run A Farm!", Subtitle = "Auto Farm", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__RAFW = Win
local TG = Win:TabGroup()
local Tabs = {
	Main = TG:Tab({Name = "Auto Farm", Image = "rbxassetid://10723346959"}),
	Upgrade = TG:Tab({Name = "Auto Upgrade", Image = "rbxassetid://10723346959"}),
	Buy = TG:Tab({Name = "Auto Buy", Image = "rbxassetid://10723346959"}),
	Event = TG:Tab({Name = "Event", Image = "rbxassetid://10723346959"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}
local L = Tabs.Main:Section({Side = "Left"})
L:Header({Text = "ฟาร์ม"})
L:Toggle({Name = "Auto Farm", Default = e.farm, Callback = function(v) e.farm = v; sv() end}, "RAFFarm")
L:Label({Text = "เปิดอันเดียวทำให้หมด (เดินเอง ไม่วาร์ป): เก็บไข่ทุกเล้า (รวมไข่ทอง) → วางขายที่แผง · รีดนมแพะ / ขุดเห็ดทรัฟเฟิล\n"
	.. "watchdog"})
L:Toggle({Name = "หยุดบอทตอนฉันกดเดินเอง", Default = e.pauseOnMove, Callback = function(v) e.pauseOnMove = v; sv() end}, "RAFPause")
L:Header({Text = "ปลูกพืช"})
L:Toggle({Name = "Auto Farm Crop", Default = e.crop, Callback = function(v) e.crop = v; sv() end}, "RAFCrop")
L:Label({Text = "แปลงสุก → เก็บทุกต้น · ถุงเต็ม → ไป drop ที่ Storage แล้วกลับมาเก็บต่อ\nแปลงว่าง → ปลูกเมล็ดที่เลือก (เควสเลือกให้) · คลังเต็ม → รอรถขนออก"})
L:Header({Text = "เหมือง"})
L:Toggle({Name = "Auto Mine", Default = e.mine, Callback = function(v)
	e.mine = v; sv()
	if not v then pcall(function() MineAim:FireServer(nil) end); pcall(function() local h, r = hum(), hrp(); if h and r then h:MoveTo(r.Position) end end) end
end}, "RAFMine")
L:Label({Text = "เดินเอง (ไม่วาร์ป): ลงลิฟต์ → ขุดแร่แพงสุดก่อน (เดินเท้าขุดได้ชั้นถ่านหิน + ทองแดง) → ไม่มีแร่ขุดหินเปิดทาง\nถุงเต็ม → เดินไปขายที่ Ore Depot · กดเดินเองเมื่อไหร่บอทหยุดรอ"})
L:Header({Text = "เควส"})
L:Toggle({Name = "Auto Claim Quest", Default = e.claim, Callback = function(v) e.claim = v; sv() end}, "RAFClaim")
L:Label({Text = "เควสเสร็จกดรับเงินเอง + รางวัลรายวัน\nเควสเก็บเกี่ยว/ส่งพืช → เปลี่ยนเมล็ดที่ปลูกเป็นพืชตามเควสให้ (ถ้ามีเมล็ด)"})
local R = Tabs.Main:Section({Side = "Right"})
R:Header({Text = "สถานะ"})
local stLbl = R:Label({Text = "-"})
R:Button({Name = "เก็บไข่ไปวางแผงตอนนี้", Callback = function() task.spawn(function() pcall(eggJob) end) end})

local U = Tabs.Upgrade:Section({Side = "Left"})
U:Toggle({Name = "Auto Upgrade", Default = e.upgrade, Callback = function(v) e.upgrade = v; sv() end}, "RAFUpg")
U:Label({Text = "ซื้ออันที่คุ้มสุดก่อน: ได้เงินเพิ่มเยอะเทียบกับราคา (คืนทุนเร็วสุด)\nอันดีสุดใกล้มีเงินพอ → เก็บเงินรอ ไม่เสียเงินกับของห่วย · ทีละ 1 อย่างทุก ~5 วิ"})
local UR = Tabs.Upgrade:Section({Side = "Right"})
UR:Header({Text = "สถานะ"})
local upgLbl = UR:Label({Text = "-"})
UR:Header({Text = "คิวถัดไป (คุ้มสุดก่อน)"})
local queueLbl = UR:Label({Text = "-"})

local B = Tabs.Buy:Section({Side = "Left"})
B:Header({Text = "เมล็ดพันธุ์"})
B:Toggle({Name = "Auto Buy Crop", Default = e.seedBuy, Callback = function(v) e.seedBuy = v; sv() end}, "RAFSeedBuy")
local seedOpts, seedDef, seedByLabel = {}, {}, {}
for _, id in ipairs(SEED_IDS) do
	local c = CropCfg[id]
	local label = ("%s · $%s/ถุง"):format(seedName(id), fmt(c and c.seedPrice or 0))
	seedOpts[#seedOpts + 1] = label
	seedByLabel[label] = id
	if table.find(e.seedPick or {}, id) then seedDef[#seedDef + 1] = label end
end
B:Dropdown({Name = "└ ซื้อเมล็ดอะไรบ้าง", Multi = true, Required = false, Options = seedOpts, Default = seedDef,
	Callback = function(v)
		local ids = {}
		for name, on in pairs(type(v) == "table" and v or {}) do
			local label = type(name) == "number" and on or (on and name)
			if label and seedByLabel[label] then ids[#ids + 1] = seedByLabel[label] end
		end
		e.seedPick = ids; sv()
	end}, "RAFSeedPick")
B:Input({Name = "└ ซื้อเมื่อเหลือต่ำกว่า (ถุง)", Placeholder = "20", AcceptedCharacters = "Numeric",
	Default = tostring(e.seedMin or 20), Callback = function(v) e.seedMin = tonumber(v) or 0; sv() end}, "RAFSeedMin")
B:Input({Name = "└ ซื้อจนมีถึง (ถุง)", Placeholder = "100", AcceptedCharacters = "Numeric",
	Default = tostring(e.seedMax or 100), Callback = function(v) e.seedMax = tonumber(v) or 0; sv() end}, "RAFSeedMax")
B:Label({Text = "เช่น ต่ำกว่า 20 → ซื้อจนมี 100 · เงินไม่พอซื้อเท่าที่ไหว\nพืชที่ยังล็อกข้ามไป"})
local BR = Tabs.Buy:Section({Side = "Right"})
BR:Header({Text = "สถานะ"})
local buyLbl = BR:Label({Text = "-"})

local EV = Tabs.Event:Section({Side = "Left"})
EV:Header({Text = "Weigh-off · ฟักทองยักษ์"})
EV:Toggle({Name = "Auto Water", Default = e.evWater, Callback = function(v) e.evWater = v; sv() end}, "RAFEvWater")
EV:Label({Text = "น้ำแห้งเมื่อไหร่ เดินไปรดที่ถังให้ (ฟรี · น้ำอยู่ 3 ชม. · โต 75 lb/ชม.)"})
EV:Toggle({Name = "Auto Feed Crops", Default = e.evFeed, Callback = function(v) e.evFeed = v; sv() end}, "RAFEvFeed")
EV:Toggle({Name = "└ ป้อนต่อหลังครบโควต้าวันนี้ (ได้แค่ 20%)", Default = e.evFeedOver, Callback = function(v) e.evFeedOver = v; sv() end}, "RAFEvFeedOver")
EV:Label({Text = "เอาพืชในถุงไปเทที่รถเข็น · วันละ 1,500 lb · ผลไม้หนักสุด\nเปิด Auto Farm Crop ด้วย → ถุงเต็มจะไปป้อนก่อน เหลือค่อย drop ที่ Storage"})
local EVR = Tabs.Event:Section({Side = "Right"})
EVR:Header({Text = "สถานะ"})
local evLbl = EVR:Label({Text = "-"})

local S = Tabs.Settings:Section({Side = "Left"})
S:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() Win:SetState(not Win:GetState()) end) end}, "RAFToggleUI")
S:Header({Text = "กันหลุด"})
S:Toggle({Name = "Anti-AFK (กันโดนเตะตอนยืนนิ่ง 20 นาที)", Default = e.antiAfk, Callback = function(v) e.antiAfk = v; sv() end}, "RAFAntiAfk")
S:Toggle({Name = "Auto Reconnect (หลุด / โดนเตะ → เข้าเกมใหม่เอง)", Default = e.reconnect, Callback = function(v) e.reconnect = v; sv() end}, "RAFReconnect")
S:Label({Text = "เข้าเกมใหม่แล้วสคริปต์โหลดเองผ่าน loader พร้อมค่าที่ตั้งไว้"})
S:Label({Text = "ตั้งค่าเซฟที่: " .. SF})

task.spawn(function()
	while alive() do
		pcall(function()
			local d = D() or {}
			local list, total = coopEggs(d)
			stLbl:UpdateName(table.concat({
				st.status,
				("เงิน $%s · แผง %s/%s · ถุง %s/%s · ไข่ในเล้า %d"):format(fmt(d.cash), fmt(d.standUsed), fmt(d.standCap),
					tostring(d.basketUsed or 0), tostring(d.basketCap or 0), total),
				("ไข่ที่ขนไปแผง %s (%d รอบ) · สัตว์ในคอก %d"):format(fmt(st.eggs), st.trips, st.pens),
				("พืช: %s · เก็บ %d · drop %d ครั้ง · ปลูก %d แปลง"):format(st.crop, st.harvested, st.cropDrops, st.planted),
				("เหมือง: %s · ขุดได้ %d · ขายแร่ %d"):format(st.mine, st.ores, st.mineSold),
				("รับเควส %d · ล่าสุด: %s · เมล็ดตามเควส: %s"):format(st.quests, st.lastQuest, st.seed),
				"Watchdog: " .. st.wd,
				"Error: " .. st.err,
			}, "\n"))
			local seeds = {}
			for _, id in ipairs(e.seedPick or {}) do seeds[#seeds + 1] = ("%s %d"):format(seedName(id), (d.seeds and d.seeds[id]) or 0) end
			local w = d.weighoff
			if w then
				local t = now()
				local lb = (w.lb or 0) + WeighCfg.watered(w.at or t, math.min(t, w.wetUntil or 0))
				local wet = (w.wetUntil or 0) - t
				local left = WeighCfg.END - t
				evLbl:UpdateName(table.concat({
					st.ev,
					("ฟักทอง %s lb · ป้อนวันนี้ %s / %s lb"):format(fmt(lb), fmt(w.fedToday or 0), fmt(WeighCfg.DAILY_LB)),
					wet > 0 and ("น้ำ: เปียกอีก %dh %02dm"):format(wet // 3600, (wet % 3600) // 60) or "น้ำ: แห้ง (ไม่โต)",
					left > 0 and ("อีเวนต์จบใน %dh %02dm"):format(left // 3600, (left % 3600) // 60) or "อีเวนต์จบแล้ว",
					("รอบนี้: ป้อน %d ครั้ง (+%s lb) · รดน้ำ %d ครั้ง"):format(st.feeds, fmt(st.fed), st.water),
				}, "\n"))
			else
				evLbl:UpdateName(st.ev .. "\nยังไม่มีข้อมูลอีเวนต์")
			end
			upgLbl:UpdateName(table.concat({
				e.upgrade and "เปิดอยู่" or "ปิดอยู่",
				("ซื้อไปแล้ว %d อย่าง · ล่าสุด: %s"):format(st.buys, st.lastBuy),
				st.upgWait ~= "-" and st.upgWait or "พร้อมซื้ออันถัดไป",
				("เงิน $%s"):format(fmt(d.cash)),
			}, "\n"))
			local q, budget = {}, (d.cash or 0) - (tonumber(e.reserve) or 0)
			local okC, list = pcall(candidates, d, plot())
			for n, c in ipairs(okC and list or {}) do
				if n > 6 then q[#q + 1] = ("… อีก %d อย่าง"):format(#list - 6); break end
				local pbTxt = c.pb == math.huge and "ไม่เพิ่มรายได้" or c.gain == nil and "ไม่รู้รายได้" or ("คืนทุน ~%d นาที"):format(math.ceil(c.pb / 60))
				q[#q + 1] = ("%s %s · $%s · %s"):format(c.cost <= budget and "✓" or "✗", c.name, fmt(c.cost), pbTxt)
			end
			queueLbl:UpdateName(#q > 0 and table.concat(q, "\n") or "ไม่มีอะไรให้อัปในหมวดที่เปิด")
			buyLbl:UpdateName(table.concat({
				st.seedBuy,
				"มีอยู่: " .. (#seeds > 0 and table.concat(seeds, " · ") or "ยังไม่ได้เลือกเมล็ด"),
				("ซื้อไปแล้ว %d ถุง · ใช้เงิน $%s · เงินตอนนี้ $%s"):format(st.seedBought, fmt(st.seedSpent), fmt(d.cash)),
			}, "\n"))
		end)
		task.wait(0.5)
	end
end)

Win.onUnloaded(function()
	if getgenv().__RAF == G then getgenv().__RAF = G + 1 end
	pcall(function() idleConn:Disconnect() end)
	pcall(function() errConn:Disconnect() end)
	pcall(function() bagConn:Disconnect() end)
	pcall(function() oreConn:Disconnect() end)
	pcall(function() cropConn:Disconnect() end)
	pcall(function() inputConn:Disconnect() end)
	pcall(function() MineAim:FireServer(nil) end)
	print("[RunAFarm] Unloaded")
end)
Tabs.Main:Select()
print("[RunAFarm] UI ready")
