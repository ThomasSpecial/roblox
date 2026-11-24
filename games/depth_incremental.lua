-- [CLANS] Depth Incremental (placeId 119101118479978) -- auto progression for World 1. One tab per room (Upgrades,
-- Fossils, Worms, Upgrade Tree, Titles, ...) with that room's automation; stairs / rooms / rebirth on the Auto tab.
-- MacLib window, RightShift toggles it, settings persist (DepthInc/state_<userId>.json).
--
-- How the game works (verified 2026-11-24 on Papiyongzzz):
--   Everything is in ReplicatedStorage.PitConfig and the player's attributes; purchases are RemoteEvents in
--   ReplicatedStorage.PitRemotes and do not care where the character stands:
--     BuyStep(n)            next stair n = Steps + 1; price PitConfig.Price(n) * StepDiscount(plr, n) in StepCurrency(n);
--                           StepBlocked(plr, n) returns a reason (boss gate ...) or nil.
--     BuyRoom(id)           PitConfig.Rooms[i] = {id, step, price, currency}; owned -> attribute Room_<id> = true.
--     BuyUpgrade(id, max)   PitConfig.Upgrades[id] = {max, currency (nil = Cash)}, level = attribute Up_<id>,
--                           price UpgradeCost(id, level); the board hangs in room UpgradeRoom[id].
--     BuyTreeNode(id)       PitConfig.TreeById[id] = {cost, currency, parent, rebirth, soon, tree}; owned -> Tree_<id>.
--     Rebirth()             PitConfig.Rebirths[Rebirths + 1] = {cost, currency}; resets cash / stairs / boards.
--     Teleport(roomId)      the game's own Teleport menu ("Surface" = the top); only rooms you own.
--   Position-checked:
--     Fossils are dug by the server while the character stands inside a CollectionService "FossilZone" part
--     (attribute Set -> PitConfig.Fossils[set] = {room, cost, currency}); ~20 digs/s on the Dirt set.
--     Worms (WormSpawned -> WormClient's table) are collected by the game's own client when the character walks
--     within WORM_RADIUS of one; WormCollected(id) fired from across the room is ignored. The room stops spawning
--     once it holds its max, so uncollected worms block new ones.

getgenv().__DINC = (getgenv().__DINC or 0) + 1
local G = getgenv().__DINC
pcall(function() if getgenv().__DINCW then getgenv().__DINCW:Unload() end end)
local function alive() return getgenv().__DINC == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local CS = game:GetService("CollectionService")
local plr = Players.LocalPlayer

local C = require(RS:WaitForChild("PitConfig"))
local R = RS:WaitForChild("PitRemotes")

-- ------------------------------------------------------------------ settings
local SF = ("DepthInc/state_%d.json"):format(plr.UserId)
local DEFAULTS = {stairs = true, rooms = true, saveForRoom = true, rebirth = false, antiAfk = true,
	upg = {}, tree = true, worms = false, dig = false, digSet = "auto"}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
if type(e.upg) ~= "table" then e.upg = {} end
local function sv()
	pcall(function()
		if makefolder and not isfolder("DepthInc") then makefolder("DepthInc") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

local st = {status = "-", steps = 0, rooms = 0, upgrades = 0, nodes = 0, worms = 0, rebirths = 0, wait = "-",
	last = {}, wd = "-", act = "-"}
local function log(s)
	table.insert(st.last, 1, os.date("%H:%M:%S") .. " " .. s)
	while #st.last > 8 do table.remove(st.last) end
end

local function attr(k) return plr:GetAttribute(k) end
local function have(cur) return tonumber(attr(cur or "Cash")) or 0 end
local function short(n)
	local ok, s = pcall(C.Short, n)
	return ok and s or tostring(math.floor(tonumber(n) or 0))
end
local function roomOwned(id) return id == nil or attr("Room_" .. id) == true end
local function title(s)
	return (tostring(s):lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

-- ------------------------------------------------------------------ rooms, boards, trees
local BOARDS = {}   -- room id -> {upgrade ids}, in the game's board order
for id, room in pairs(C.UpgradeRoom) do
	if not (C.Upgrades[id] and C.Upgrades[id].world) then
		BOARDS[room] = BOARDS[room] or {}
		table.insert(BOARDS[room], id)
	end
end
for _, list in pairs(BOARDS) do
	table.sort(list, function(a, b)
		local ia, ib = table.find(C.UpgradeOrder or {}, a) or 999, table.find(C.UpgradeOrder or {}, b) or 999
		return ia < ib or (ia == ib and a < b)
	end)
end
local TREE_ROOM, IS_TREE = {}, {}
for i, room in pairs(C.TreeRoomIds or {}) do TREE_ROOM[i] = room; IS_TREE[room] = true end
-- world 1 fossil sets, in the game's order
local DIG_SETS = {}
for _, set in ipairs(C.FossilSetOrder or {}) do
	local f = C.Fossils[set]
	if f and not f.world then DIG_SETS[#DIG_SETS + 1] = set end
end
local function upgOn(room) return e.upg[room] ~= false end

local function nextStep()
	local n = (tonumber(attr("Steps")) or 0) + 1
	if not C.Steps[n] then return nil, "ซื้อครบทุกขั้นของโลก 1 แล้ว" end
	local ok, why = pcall(C.StepBlocked, plr, n)
	if ok and why then return nil, ("ขั้น %d: %s"):format(n, tostring(why)) end
	local okp, price = pcall(function() return math.floor(C.Price(n) * C.StepDiscount(plr, n)) end)
	if not okp or not price then return nil, "อ่านราคาขั้นไม่ได้" end
	return {kind = "step", id = n, cost = price, cur = C.StepCurrency(n) or "Cash", name = ("ขั้น %d"):format(n)}
end
-- the next room; cash is held back for one the stairs already reached (rooms open everything else)
local function nextRoom()
	local steps = tonumber(attr("Steps")) or 0
	for _, r in ipairs(C.Rooms) do
		if not r.world and not roomOwned(r.id) then return r, (r.step or 0) <= steps end
	end
end
local function upgradeCands(out)
	for room, ids in pairs(BOARDS) do
		if roomOwned(room) and upgOn(room) then
			for _, id in ipairs(ids) do
				local u = C.Upgrades[id]
				local lv = tonumber(attr("Up_" .. id)) or 0
				if u and lv < (u.max or 0) then
					local ok, cost = pcall(C.UpgradeCost, id, lv)
					if ok and tonumber(cost) then
						out[#out + 1] = {kind = "upg", id = id, cost = cost, cur = u.currency or "Cash", name = ("%s Lv%d"):format(id, lv + 1)}
					end
				end
			end
		end
	end
end
local function treeCands(out)
	local rb = tonumber(attr("Rebirths")) or 0
	for id, n in pairs(C.TreeById) do
		if attr("Tree_" .. id) ~= true and not n.soon and not (n.rebirth and rb < n.rebirth) then
			local room = TREE_ROOM[n.tree or 1]
			local parentOk = n.parent == nil or attr("Tree_" .. n.parent) == true
			if room and roomOwned(room) and parentOk and tonumber(n.cost) then
				out[#out + 1] = {kind = "tree", id = id, cost = n.cost, cur = n.currency or "Cash", name = tostring(n.name or id)}
			end
		end
	end
end

local FIRE = {step = "BuyStep", room = "BuyRoom", upg = "BuyUpgrade", tree = "BuyTreeNode"}
local function keyOf(c)
	return c.kind == "step" and "Steps" or c.kind == "room" and ("Room_" .. c.id) or c.kind == "upg" and ("Up_" .. c.id)
		or ("Tree_" .. c.id)
end
local function waitChange(key, before)
	local t0 = os.clock()
	while os.clock() - t0 < 1.5 do
		if attr(key) ~= before then return true end
		task.wait(0.05)
	end
	return false
end

-- ------------------------------------------------------------------ buy loop
local refused = {}
local function shop()
	local room, reached = nextRoom()
	if e.rooms and room and reached and have(room.currency) >= (room.price or math.huge) then
		local before = attr("Room_" .. room.id)
		R.BuyRoom:FireServer(room.id)
		if waitChange("Room_" .. room.id, before) then
			st.rooms += 1
			log("ซื้อห้อง " .. title(room.name or room.id))
		end
		return true
	end
	local cands = {}
	if e.stairs then
		local s, why = nextStep()
		if s then cands[#cands + 1] = s; st.wait = "-" else st.wait = why or "-" end
	end
	upgradeCands(cands)
	if e.tree then treeCands(cands) end
	local reserve = 0
	if e.saveForRoom and e.rooms and room and reached and (room.currency or "Cash") == "Cash" then reserve = room.price or 0 end
	local best
	for _, c in ipairs(cands) do
		local budget = have(c.cur) - (c.cur == "Cash" and c.kind ~= "step" and reserve or 0)
		if c.cost <= budget and (refused[c.kind .. c.id] or 0) < os.clock() then
			if not best or c.cost < best.cost or (c.cost == best.cost and c.kind == "step") then best = c end
		end
	end
	if not best then return false end
	local key = keyOf(best)
	local before = attr(key)
	if best.kind == "upg" then R.BuyUpgrade:FireServer(best.id, false) else R[FIRE[best.kind]]:FireServer(best.id) end
	if waitChange(key, before) then
		if best.kind == "step" then st.steps += 1 elseif best.kind == "upg" then st.upgrades += 1 else st.nodes += 1 end
		if best.kind ~= "step" then log(("%s · %s %s"):format(best.name, short(best.cost), best.cur)) end
	else
		refused[best.kind .. best.id] = os.clock() + 10
	end
	return true
end

task.spawn(function()
	while alive() do
		local any = false
		if attr("DataLoaded") == true then
			local ok, err = pcall(function() any = shop() end)
			if not ok then st.status = "error: " .. tostring(err):sub(1, 120) end
		end
		task.wait(any and 0.12 or 0.5)
	end
end)

-- ------------------------------------------------------------------ rebirth
task.spawn(function()
	while alive() do
		task.wait(2)
		if e.rebirth then
			local nextN = (tonumber(attr("Rebirths")) or 0) + 1
			local r = C.Rebirths[nextN]
			if r and have(r.currency or "Cash") >= (r.cost or math.huge) then
				local before = tonumber(attr("Rebirths")) or 0
				pcall(function() R.Rebirth:FireServer() end)
				task.wait(3)
				if (tonumber(attr("Rebirths")) or 0) > before then
					st.rebirths += 1
					log(("Rebirth ครั้งที่ %d สำเร็จ"):format(nextN))
				end
			end
		end
	end
end)

-- ------------------------------------------------------------------ walking jobs: dig fossils / collect worms
local function char()
	local c = plr.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if hrp and hum and hum.Health > 0 then return hrp, hum end
end
-- WormClient keeps the live worms in an upvalue table {id = {pos, at, born, golden, model ...}}
local wormTbl, wormScanAt = nil, 0
local function worms()
	if wormTbl then return wormTbl end
	-- getgc is heavy: scan at most every 5 s until the table is found (it is only recognisable while holding a worm)
	if os.clock() - wormScanAt < 5 then return end
	wormScanAt = os.clock()
	for _, f in ipairs(getgc()) do
		if type(f) == "function" and islclosure(f) and (debug.info(f, "s") or ""):find("WormClient") then
			for _, v in pairs(debug.getupvalues(f)) do
				if type(v) == "table" then
					local _, w = next(v)
					if type(w) == "table" and w.pos and w.born then wormTbl = v; return v end
				end
			end
		end
	end
	-- empty right now: any WormClient upvalue table that only ever holds worm records; retry later
end
local function pendingWorms()
	local t = worms()
	local list = {}
	for id, w in pairs(t or {}) do
		if type(w) == "table" and (w.at or w.pos) then list[#list + 1] = {id = id, pos = w.at or w.pos} end
	end
	return list
end

local function digSet()
	if e.digSet ~= "auto" and table.find(DIG_SETS, e.digSet) then return e.digSet end
	local best
	for _, set in ipairs(DIG_SETS) do
		local f = C.Fossils[set]
		if roomOwned(f.room or "Fossils") and have(f.currency or "Cash") >= (tonumber(f.cost) or 0) then best = set end
	end
	return best
end
local function digZone(set)
	for _, z in ipairs(CS:GetTagged("FossilZone")) do
		if z:IsA("BasePart") and z:GetAttribute("Set") == set then return z end
	end
end
local function inside(part, pos)
	local p = part.CFrame:PointToObjectSpace(pos)
	local h = part.Size / 2
	return math.abs(p.X) <= h.X - 1 and math.abs(p.Z) <= h.Z - 1 and math.abs(p.Y) <= h.Y + 4
end
local lastTp = 0
local function tpRoom(id)
	if os.clock() - lastTp < 3 then return end
	lastTp = os.clock()
	pcall(function() R.Teleport:FireServer(id) end)
	task.wait(1.2)
end

-- dig: stand inside the chosen fossil zone (warp to its room with the game's Teleport, then walk in)
local function digStep()
	local hrp, hum = char()
	if not hrp then return end
	local set = digSet()
	if not set then st.act = "ขุด: ยังไม่มีห้องฟอสซิลที่ขุดได้" return end
	local f = C.Fossils[set]
	local z = digZone(set)
	if not z or (z.Position - hrp.Position).Magnitude > 80 then
		st.act = ("ขุด: วาร์ปไปห้อง %s"):format(title(f.room or set))
		tpRoom(f.room or "Fossils")
		return
	end
	if not inside(z, hrp.Position) then
		hum:MoveTo(z.Position)
		st.act = ("ขุด: เดินเข้าโซน %s"):format(set)
		return
	end
	st.act = ("ขุดฟอสซิล %s · ขุดแล้ว %s"):format(set, short(have("FossilsDug")))
end

-- worms: walk onto each worm; WormClient collects it itself when we are within reach
local function wormStep(list)
	local hrp, hum = char()
	if not hrp then return end
	local best, bd
	for _, w in ipairs(list) do
		local d = ((w.pos - hrp.Position) * Vector3.new(1, 0, 1)).Magnitude
		if not bd or d < bd then best, bd = w, d end
	end
	if not best then return end
	if bd > 90 or math.abs(best.pos.Y - hrp.Position.Y) > 25 then
		st.act = "หนอน: วาร์ปไปห้อง Worms"
		tpRoom("Worms")
		return
	end
	st.act = ("เดินเก็บหนอน · เหลือ %d ตัว"):format(#list)
	hum:MoveTo(best.pos)
	local t0 = os.clock()
	local t = worms()
	while alive() and os.clock() - t0 < 2.5 and t and t[best.id] do task.wait(0.05) end
	if t and not t[best.id] then st.worms += 1 end
end

-- both on: dig, and go clear the worm room once it has filled up (a full room stops spawning)
local phase = "dig"
local WORM_BATCH = 10
task.spawn(function()
	while alive() do
		local ok, err = pcall(function()
			local wantWorms = e.worms and roomOwned("Worms")
			local list = wantWorms and pendingWorms() or {}
			if wantWorms and e.dig then
				if phase == "dig" and #list >= WORM_BATCH then phase = "worms" elseif phase == "worms" and #list == 0 then phase = "dig" end
			else
				phase = wantWorms and "worms" or "dig"
			end
			if phase == "worms" and wantWorms then
				if #list > 0 then wormStep(list) else st.act = "รอหนอนเกิด"; task.wait(0.3) end
			elseif e.dig then
				digStep()
				task.wait(0.4)
			else
				st.act = "-"
				task.wait(0.5)
			end
		end)
		if not ok then st.act = "error: " .. tostring(err):sub(1, 100); task.wait(1) end
		task.wait(0.03)
	end
end)

-- ------------------------------------------------------------------ anti-AFK
local idleConn = plr.Idled:Connect(function()
	if not (alive() and e.antiAfk) then return end
	pcall(function()
		local VU = game:GetService("VirtualUser")
		VU:CaptureController()
		VU:ClickButton2(Vector2.new())
	end)
	st.wd = "anti-AFK กันเตะ · " .. os.date("%H:%M:%S")
end)

-- ---------------------------------------------------------------------- UI
local okL, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okL or not Lib then warn("[DepthInc] MacLib failed: " .. tostring(Lib)) return end
if not alive() then return end
local Win = Lib:Window({Title = "Depth Incremental", Subtitle = "Auto Progress", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__DINCW = Win
local TG = Win:TabGroup()
local MainTab = TG:Tab({Name = "Auto", Image = "rbxassetid://10723346959"})

local L = MainTab:Section({Side = "Left"})
L:Header({Text = "ลงลึก (ซื้อได้ทุกที่ ไม่ต้องเดิน)"})
L:Toggle({Name = "Auto Stairs (ซื้อขั้นบันได)", Default = e.stairs, Callback = function(v) e.stairs = v; sv() end}, "DIStairs")
L:Toggle({Name = "Auto Rooms (ซื้อห้องใหม่ทันทีที่ถึง + เงินพอ)", Default = e.rooms, Callback = function(v) e.rooms = v; sv() end}, "DIRooms")
L:Toggle({Name = "└ เก็บเงินไว้ซื้อห้องที่ถึงแล้วก่อน", Default = e.saveForRoom, Callback = function(v) e.saveForRoom = v; sv() end}, "DISave")
L:Toggle({Name = "Auto Rebirth (เงินพอ → Rebirth · รีเซ็ตเงิน/ขั้น/บอร์ด)", Default = e.rebirth, Callback = function(v) e.rebirth = v; sv() end}, "DIRebirth")
L:Label({Text = "ขั้นบันได / อัปเกรด / ต้นไม้ ซื้ออันที่ถูกที่สุดก่อน\nAuto Upgrade ของแต่ละห้องอยู่ใน tab ของห้องนั้น"})
L:Header({Text = "วาร์ป (Teleport ของเกม)"})
L:Button({Name = "วาร์ป → The Surface", Callback = function() pcall(function() R.Teleport:FireServer("Surface") end) end})

local Rt = MainTab:Section({Side = "Right"})
Rt:Header({Text = "สถานะ"})
local stLbl = Rt:Label({Text = "-"})
Rt:Header({Text = "ซื้อล่าสุด"})
local logLbl = Rt:Label({Text = "-"})

-- one tab per room that has something to automate (rooms of zones you can reach)
local roomLbls = {}
local rb = tonumber(attr("Rebirths")) or 0
local reachStep = math.huge
for _, Lyr in ipairs(C.TeleportLayers or {}) do
	if not Lyr.world and (tonumber(Lyr.rebirths) or 0) > rb and Lyr.depth then reachStep = math.min(reachStep, Lyr.depth[1]) end
end
local function boardText(roomId)
	local lines = {}
	for _, id in ipairs(BOARDS[roomId] or {}) do
		local u = C.Upgrades[id]
		local lv = tonumber(attr("Up_" .. id)) or 0
		local ok, cost = pcall(C.UpgradeCost, id, lv)
		lines[#lines + 1] = ("%s  %d/%d%s"):format(id, lv, u.max or 0, lv >= (u.max or 0) and "  MAX"
			or (ok and cost and ("  · " .. short(cost) .. " " .. tostring(u.currency or "Cash")) or ""))
	end
	return lines
end
local function treeText(roomId)
	local idx
	for i, r in pairs(TREE_ROOM) do if r == roomId then idx = i end end
	local own, total, nextN = 0, 0, nil
	for id, n in pairs(C.TreeById) do
		if (n.tree or 1) == idx then
			total += 1
			if attr("Tree_" .. id) == true then own += 1
			elseif (n.parent == nil or attr("Tree_" .. n.parent) == true) and not n.soon
				and (not nextN or (tonumber(n.cost) or 0) < (tonumber(nextN.cost) or 0)) then nextN = n end
		end
	end
	return {("โหนด %d/%d"):format(own, total),
		nextN and ("ถัดไป: %s · %s %s"):format(tostring(nextN.name), short(nextN.cost or 0), tostring(nextN.currency or "Cash")) or "ซื้อครบแล้ว"}
end
for _, r in ipairs(C.Rooms) do
	local hasFeat = BOARDS[r.id] or IS_TREE[r.id] or r.id == "Worms" or r.id == "Fossils"
	if not r.world and hasFeat and (r.step or 0) < reachStep then
		local name = title(r.name or r.id)
		local tab = TG:Tab({Name = name, Image = "rbxassetid://10723346959"})
		local A = tab:Section({Side = "Left"})
		A:Header({Text = name})
		if BOARDS[r.id] then
			A:Toggle({Name = "Auto Upgrade (บอร์ดในห้องนี้)", Default = upgOn(r.id),
				Callback = function(v) e.upg[r.id] = v; sv() end}, "DIU_" .. r.id)
		end
		if IS_TREE[r.id] then
			A:Toggle({Name = "Auto Upgrade Tree (ซื้อโหนดถูกสุดก่อน)", Default = e.tree,
				Callback = function(v) e.tree = v; sv() end}, "DIT_" .. r.id)
		end
		if r.id == "Fossils" then
			A:Toggle({Name = "Auto Dig (ไปยืนในโซนขุด · เซิร์ฟเวอร์ขุดให้)", Default = e.dig,
				Callback = function(v) e.dig = v; sv() end}, "DIDig")
			local opts = {"อัตโนมัติ (ห้องดีสุดที่ขุดได้)"}
			for _, set in ipairs(DIG_SETS) do opts[#opts + 1] = set end
			A:Dropdown({Name = "└ ขุดชุดฟอสซิล", Multi = false, Required = true, Options = opts,
				Default = e.digSet == "auto" and 1 or (table.find(opts, e.digSet) or 1),
				Callback = function(v) e.digSet = (v == opts[1]) and "auto" or v; sv() end}, "DIDigSet")
		end
		if r.id == "Worms" then
			A:Toggle({Name = "Auto Collect Worms (เดินเก็บทุกตัว)", Default = e.worms,
				Callback = function(v) e.worms = v; sv() end}, "DIWorms")
			A:Label({Text = "เปิดคู่กับ Auto Dig: ขุดไปก่อน หนอนค้าง " .. WORM_BATCH .. " ตัว → ไปเดินเก็บ → กลับมาขุด\n(ห้องหนอนเต็มแล้วจะไม่เกิดเพิ่ม)"})
		end
		A:Button({Name = "วาร์ป → " .. name, Callback = function()
			if not roomOwned(r.id) then log("ยังไม่มีห้อง " .. name) return end
			pcall(function() R.Teleport:FireServer(r.id) end)
		end})
		local B = tab:Section({Side = "Right"})
		B:Header({Text = "สถานะห้อง"})
		roomLbls[#roomLbls + 1] = {r = r, lbl = B:Label({Text = "-"})}
	end
end
local function roomText(r)
	local steps = tonumber(attr("Steps")) or 0
	if not roomOwned(r.id) then
		return ("ยังไม่มีห้องนี้\nปลดที่ขั้น %d%s · ราคา %s %s"):format(r.step or 0, steps >= (r.step or 0) and " (ถึงแล้ว)" or "",
			short(r.price or 0), tostring(r.currency or "Cash"))
	end
	local lines = {}
	for _, s in ipairs(boardText(r.id)) do lines[#lines + 1] = s end
	if IS_TREE[r.id] then for _, s in ipairs(treeText(r.id)) do lines[#lines + 1] = s end end
	if r.id == "Fossils" then
		lines[#lines + 1] = ("ขุดแล้ว %s · ชุดที่ขุด: %s"):format(short(have("FossilsDug")), tostring(digSet() or "-"))
	end
	if r.id == "Worms" then
		lines[#lines + 1] = ("หนอน %s · ค้างในห้อง %d · เก็บรอบนี้ %d"):format(short(have("Worms")), #pendingWorms(), st.worms)
	end
	return #lines > 0 and table.concat(lines, "\n") or "-"
end

local SetTab = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"})
local SS = SetTab:Section({Side = "Left"})
SS:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() Win:SetState(not Win:GetState()) end) end}, "DIToggleUI")
SS:Toggle({Name = "Anti-AFK", Default = e.antiAfk, Callback = function(v) e.antiAfk = v; sv() end}, "DIAntiAfk")
SS:Label({Text = "tab ห้องโซนใหม่จะขึ้นหลัง Rebirth แล้วโหลดสคริปต์ใหม่\nตั้งค่าเซฟที่: " .. SF})

task.spawn(function()
	while alive() do
		pcall(function()
			local steps = tonumber(attr("Steps")) or 0
			local room, reached = nextRoom()
			local nr = C.Rebirths[(tonumber(attr("Rebirths")) or 0) + 1]
			stLbl:UpdateName(table.concat({
				("ขั้น %d · เงิน %s · หนอน %s · Rebirth %d"):format(steps, short(have("Cash")), short(have("Worms")), tonumber(attr("Rebirths")) or 0),
				room and ("ห้องถัดไป: %s (ขั้น %d · %s %s)%s"):format(title(room.name or room.id), room.step or 0, short(room.price or 0),
					tostring(room.currency or "Cash"), reached and " ← ถึงแล้ว รอเงิน" or "") or "ห้องโลก 1 ครบแล้ว",
				"รอ: " .. tostring(st.wait),
				nr and ("Rebirth ถัดไป: %s %s"):format(short(nr.cost or 0), tostring(nr.currency or "Cash")) or "Rebirth ครบแล้ว",
				"ตัวละคร: " .. tostring(st.act),
				("รอบนี้: ขั้น +%d · ห้อง +%d · อัป +%d · ต้นไม้ +%d · หนอน %d · Rebirth %d"):format(st.steps, st.rooms, st.upgrades,
					st.nodes, st.worms, st.rebirths),
				"Watchdog: " .. st.wd,
				st.status ~= "-" and st.status or nil,
			}, "\n"))
			logLbl:UpdateName(#st.last > 0 and table.concat(st.last, "\n") or "-")
			for _, rl in ipairs(roomLbls) do rl.lbl:UpdateName(roomText(rl.r)) end
		end)
		task.wait(0.5)
	end
end)

task.spawn(function()
	while alive() do task.wait(1) end
	pcall(function() idleConn:Disconnect() end)
	pcall(function() local _, hum = char(); if hum then hum:MoveTo(plr.Character.HumanoidRootPart.Position) end end)
end)
pcall(function()
	Win.onUnloaded(function() if getgenv().__DINC == G then getgenv().__DINC = G + 1 end end)
end)
MainTab:Select()
