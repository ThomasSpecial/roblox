-- Poly Loot: Sela's Gorilla quest runner (helper, needs poly_loot.lua running: uses getgenv().__PLDBG.api to walk).
-- Phases are functions on getgenv().__SELA; run one with  getgenv().__SELA.run("wood", 25)  and stop with  .stop().
-- Progress / log: getgenv().__SELA.log (newest first), .status
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local plr = Players.LocalPlayer
local st = getgenv().__PLDBG
assert(st and st.api, "poly_loot.lua must be running (st.api)")
local api = st.api
local TC = require(RS.TreeChop_Engine.Config)
local MC = require(RS.Mining_Engine.Config)
local InvR = RS.Inventory_Engine.Remotes
local PD = require(plr.PlayerScripts.Data_Client.PlayerData)

if getgenv().__SELA and getgenv().__SELA.stop then pcall(getgenv().__SELA.stop) end
local S = {log = {}, status = "idle", gen = 0}
getgenv().__SELA = S

local function log(s)
	table.insert(S.log, 1, os.date("%H:%M:%S ") .. s)
	while #S.log > 40 do table.remove(S.log) end
end
local function setStatus(s)
	S.status = s
	st.extStatus = "เควส Sela: " .. s
end
local function data() return PD:WaitFor().Data end
local function count(id)
	local n = 0
	for _, cat in pairs(data().Inventory or {}) do
		if type(cat) == "table" then
			for _, it in pairs(cat) do
				if type(it) == "table" and it.Id == id then n += tonumber(it.Count) or 1 end
			end
		end
	end
	return n
end
local function hrp()
	local c = plr.Character
	return c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
end
local function flatD(a, b) return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude end

local function alive(gen) return S.gen == gen end

-- walk with the farm's navmap walker until within tol (flat) of pos
local function walk(pos, tol, timeout, gen)
	tol = tol or 4
	local t0 = os.clock()
	local lastD, lastT = math.huge, os.clock()
	while alive(gen) do
		local r = hrp()
		if not r then task.wait(0.5) else
			local d = flatD(r.Position, pos)
			-- height counts: light post 6 sits on a cliff 41 studs above the spot under it
			local dy = math.abs(r.Position.Y - pos.Y)
			if d <= tol and dy < 8 then api.stopMove() return true end
			if os.clock() - t0 > (timeout or 120) then api.stopMove() return false end
			local d3 = (r.Position - pos).Magnitude
			if d3 < lastD - 1 then lastD, lastT = d3, os.clock() end
			if os.clock() - lastT > 15 then api.stopMove() return false end   -- no progress
			api.moveTo(pos, d < 20 and dy < 6)
			task.wait(0.2)
		end
	end
	api.stopMove()
	return false
end

local function weaponSerial(id)
	for s, it in pairs(data().Inventory.Weapons or {}) do
		if it.Id == id then return s end
	end
end
local function holding()
	local c = plr.Character
	return c and c:FindFirstChildOfClass("Tool")
end
local function equip(id)
	local t = holding()
	if t and t.Name == id then return t end
	local s = weaponSerial(id)
	if not s then return nil end
	pcall(function() InvR.EquipRequest:FireServer(s) end)
	for _ = 1, 20 do
		task.wait(0.1)
		t = holding()
		if t and t.Name == id then return t end
	end
	return holding()
end

-- WorldBits drops with wbId in `ids` within radius of center -> walk next to each and pick it up
local myTag = "," .. plr.UserId .. ","
local function pickup(ids, center, radius, gen)
	local got = 0
	for _ = 1, 60 do
		if not alive(gen) then break end
		local r = hrp()
		if not r then break end
		local best, bd, bp
		for _, m in ipairs(workspace.WorldBits:GetChildren()) do
			local fast = m:GetAttribute("wbFast")
			-- only our own drops (wbFast lists the owners)
			if ids[m:GetAttribute("wbId") or ""] and (type(fast) ~= "string" or fast == "" or fast:find(myTag, 1, true)) then
				local ok, p = pcall(function() return m:GetPivot().Position end)
				if ok and flatD(p, center) <= radius then
					local d = (p - r.Position).Magnitude
					if not bd or d < bd then best, bd, bp = m, d, p end
				end
			end
		end
		if not best then break end
		if bd > 4.5 then walk(bp, 3, 15, gen) end
		local pr = best:FindFirstChildWhichIsA("ProximityPrompt", true)
		if pr then
			pcall(function() fireproximityprompt(pr) end)
			got += 1
		end
		for _ = 1, 10 do
			if not best.Parent then break end
			task.wait(0.1)
		end
		if best.Parent then
			-- couldn't take it (someone else's / too far): forget it
			best:SetAttribute("wbId", "_skip")
		end
	end
	return got
end

-- ------------------------------------------------------------------ trees
local function trunkPos(t)
	local tr = TC.TrunkOf(t)
	return tr and tr.Position or t:GetPivot().Position, tr
end
local function treeKind(t) return t:GetAttribute("ChopKind") or t.Name end
local badTree = setmetatable({}, {__mode = "k"})
local function nearestTree(kinds, gen)
	local r = hrp()
	if not r then return nil end
	local best, bd
	for _, t in ipairs(CS:GetTagged("ChoppableTree")) do
		if kinds[treeKind(t)] and not badTree[t] and not CS:HasTag(t, "NoChopTree") and not t:GetAttribute("ChopInTown")
			and not t:GetAttribute("_Felled") then
			local p = trunkPos(t)
			local d = flatD(p, r.Position) + math.abs(p.Y - r.Position.Y) * 2
			if not bd or d < bd then best, bd = t, d end
		end
	end
	return best, bd
end
local function chop(t, gen)
	local p = trunkPos(t)
	local r = hrp()
	if not r then return false end
	local away = Vector3.new(r.Position.X - p.X, 0, r.Position.Z - p.Z)
	away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
	-- trunk centre is ~11 studs up a tall trunk: aim at our own height
	local g = p + away * 3.6
	if not walk(Vector3.new(g.X, r.Position.Y, g.Z), 2.5, 60, gen) then badTree[t] = true return false end
	local t0 = os.clock()
	local before = t:GetAttribute("_ChopsLeft")
	while alive(gen) and not t:GetAttribute("_Felled") and t.Parent and os.clock() - t0 < 10 do
		r = hrp()
		if r then r.CFrame = CFrame.lookAt(r.Position, Vector3.new(p.X, r.Position.Y, p.Z)) end
		local tool = holding()
		if tool then pcall(function() tool:Activate() end) end
		task.wait(0.35)
	end
	if not t:GetAttribute("_Felled") then
		if t:GetAttribute("_ChopsLeft") == before then badTree[t] = true end
		return false
	end
	task.wait(1.2)   -- logs / fruit pop out
	return true
end

-- chop trees of `kinds` until count(itemId) >= want
function S.trees(kinds, itemIds, want, gen, axe)
	axe = axe or "Cursed Greataxe"
	local fails = 0
	local lastSweep = 0
	while alive(gen) do
		-- every so often: collect every drop of ours still lying around (missed ones, rolled-away logs)
		if os.clock() - lastSweep > 30 then
			lastSweep = os.clock()
			local r = hrp()
			if r then
				setStatus("เก็บของที่ตกค้าง")
				pickup(itemIds, r.Position, 150, gen)
			end
		end
		local have = math.huge
		for id, n in pairs(want) do have = math.min(have, count(id) - n) end
		if have >= 0 then return true end
		local t = nearestTree(kinds, gen)
		if not t then setStatus("หาต้นไม้ไม่เจอ"); return false end
		equip(axe)
		local tp = trunkPos(t)
		local parts = {}
		for id, n in pairs(want) do parts[#parts + 1] = ("%s %d/%d"):format(id, count(id), n) end
		setStatus(("ตัด %s · %s"):format(treeKind(t), table.concat(parts, " · ")))
		if chop(t, gen) then
			-- logs roll along the fallen trunk (tall pines ~30 studs): 18 left half of them on the ground
			task.wait(0.8)
			pickup(itemIds, tp, 45, gen)
			fails = 0
		else
			fails += 1
			if fails > 6 then setStatus("ตัดไม่ได้ติดกัน 6 ต้น หยุด"); return false end
		end
	end
	return false
end

-- ------------------------------------------------------------------ ores
local badOre = setmetatable({}, {__mode = "k"})
local function nearestOre(kinds)
	local r = hrp()
	if not r then return nil end
	local best, bd
	for _, o in ipairs(CS:GetTagged(MC.TAG)) do
		local kind = o:GetAttribute("OreType") or o:GetAttribute("Ore") or o.Name
		if (not kinds or kinds[kind]) and not badOre[o] and not o:GetAttribute(MC.BROKEN_ATTR) then
			local ok, p = pcall(function() return o:GetPivot().Position end)
			if ok then
				local d = flatD(p, r.Position) + math.abs(p.Y - r.Position.Y) * 2
				if not bd or d < bd then best, bd = o, d end
			end
		end
	end
	return best, bd
end
S.nearestOre = nearestOre
local function oreKind(o) return o:GetAttribute("OreType") or o.Name end
-- mine ores of `kinds` until count(itemId) >= want. Server: within 3.5 studs of the ore's surface, facing it.
function S.mine(gen, kinds, itemId, want, pick)
	pick = pick or "Wooden Pickaxe"
	local fails, lastSweep = 0, 0
	while alive(gen) do
		if count(itemId) >= want then return true end
		if os.clock() - lastSweep > 30 then
			lastSweep = os.clock()
			local r = hrp()
			if r then pickup({[itemId] = true}, r.Position, 120, gen) end
		end
		local o = nearestOre(kinds)
		if not o then
			setStatus(("รอแร่เกิด · %s %d/%d"):format(itemId, count(itemId), want))
			task.wait(2)
		else
			setStatus(("ขุด %s · %s %d/%d"):format(oreKind(o), itemId, count(itemId), want))
			equip(pick)
			local op = o:GetPivot().Position
			local r = hrp()
			local cp = MC.ClosestPoint(o, r.Position)
			local away = Vector3.new(r.Position.X - cp.X, 0, r.Position.Z - cp.Z)
			away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
			local okW = walk(cp + away * 2.2, 1.6, 60, gen)
			local h0 = o:GetAttribute("Health")
			local t0 = os.clock()
			while okW and alive(gen) and o.Parent and not o:GetAttribute(MC.BROKEN_ATTR) and os.clock() - t0 < 12 do
				r = hrp()
				if r then r.CFrame = CFrame.lookAt(r.Position, Vector3.new(op.X, r.Position.Y, op.Z)) end
				local tool = holding()
				if tool then pcall(function() tool:Activate() end) end
				task.wait(0.3)
			end
			if o.Parent and not o:GetAttribute(MC.BROKEN_ATTR) then
				if o:GetAttribute("Health") == h0 then badOre[o] = true end
				fails += 1
				if fails > 6 then setStatus("ขุดไม่เข้าติดกัน 6 ครั้ง หยุด"); return false end
			else
				fails = 0
				task.wait(0.8)
				pickup({[itemId] = true}, op, 25, gen)
			end
		end
	end
	return false
end

-- ------------------------------------------------------------------ quests / light posts
local QR = RS.Quest_Engine.Remotes
local SelaR = RS.SelaQuest_Engine.Remotes
local function story() return data().Quests.Story end
local function questActive(id) return story().Active[id] ~= nil end
local function questDone(id) return (story().History or {})[id] ~= nil end
S.questActive, S.questDone = questActive, questDone
local function accept(id)
	if questActive(id) or questDone(id) then return true end
	pcall(function() QR.AcceptStory:FireServer(id) end)
	for _ = 1, 20 do task.wait(0.15) if questActive(id) then log("รับเควส " .. id) return true end end
	log("รับเควสไม่ได้ " .. id)
	return false
end
local function claim(id)
	if questDone(id) then return true end
	pcall(function() QR.Claim:FireServer(id) end)
	for _ = 1, 20 do task.wait(0.15) if questDone(id) then log("ส่งเควส " .. id) return true end end
	log("ส่งเควสไม่ได้ " .. id)
	return false
end
S.accept, S.claim = accept, claim
local SELA_POS = Vector3.new(-115, 126, -2259)
local POSTS = {
	Vector3.new(-124, 128, -2225), Vector3.new(-167, 146, -2266), Vector3.new(-179, 134, -2218), Vector3.new(-61, 157, -2328),
	Vector3.new(11, 132, -2248), Vector3.new(-241, 150, -2178), Vector3.new(30, 148, -2346),
}
local function postBuilt(i)
	local f = workspace:FindFirstChild("_SelaLightPosts")
	return f and f:FindFirstChild(("LightPost%d"):format(i)) ~= nil and not f:FindFirstChild(("LightPost%d_Blueprint"):format(i))
end
-- a flat, head-clear spot 4-8 studs from p, a few studs below it (the post's foot level)
function S.standNear(p)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local ex = {plr.Character, workspace:FindFirstChild("Animal_Live"), workspace:FindFirstChild("_SelaLightPosts"),
		workspace:FindFirstChild("WorldBits")}
	rp.FilterDescendantsInstances = ex
	for _, off in ipairs({Vector3.new(-4, 0, 0), Vector3.new(4, 0, 0), Vector3.new(0, 0, 4), Vector3.new(0, 0, -4),
		Vector3.new(-6, 0, 6), Vector3.new(6, 0, 6), Vector3.new(-6, 0, -6), Vector3.new(6, 0, -6), Vector3.new(-8, 0, 0),
		Vector3.new(8, 0, 0)}) do
		local h = workspace:Raycast(p + off + Vector3.new(0, 12, 0), Vector3.new(0, -40, 0), rp)
		if h and h.Normal.Y > 0.6 and math.abs(h.Position.Y - (p.Y - 6)) < 12
			and not workspace:Raycast(h.Position + Vector3.new(0, 0.3, 0), Vector3.new(0, 6, 0), rp) then
			return h.Position
		end
	end
end
function S.posts(gen)
	for i, p in ipairs(POSTS) do
		if not alive(gen) then return false end
		if not postBuilt(i) then
			setStatus(("สร้างเสาไฟ %d/7"):format(i))
			local bp = workspace._SelaLightPosts:FindFirstChild(("LightPost%d_Blueprint"):format(i))
			pcall(function() p = bp.Post:GetPivot().Position end)
			walk(p, 6, 180, gen)
			for try = 1, 3 do
				pcall(function() SelaR.BuildPostBegin:FireServer(i) end)
				task.wait(3.1)
				local ok, res, extra = pcall(function() return SelaR.BuildPost:InvokeServer(i) end)
				log(("เสา %d ครั้งที่ %d: %s %s %s"):format(i, try, tostring(ok), tostring(res), tostring(extra)))
				if ok and res == true then break end
				pcall(function() SelaR.BuildPostBegin:FireServer(nil) end)
				if res == "range" then
					-- post on a ledge the navmap can't climb (post 6: 41 studs straight up): short hop onto the
					-- platform next to it (Character:PivotTo; writing HRP.CFrame alone gets undone)
					local spot = S.standNear(p)
					local r = hrp()
					if spot and r and (spot - r.Position).Magnitude < 70 then
						log(("เสา %d: กระโดดขึ้นไป %.0f stud"):format(i, (spot - r.Position).Magnitude))
						plr.Character:PivotTo(CFrame.new(spot + Vector3.new(0, 3.5, 0)))
						task.wait(0.8)
					else
						walk(p, 3, 30, gen)
					end
				else
					walk(p, 3, 30, gen)
				end
			end
		end
	end
	return true
end

-- whole chain up to the mount quest being active
function S.all(gen)
	accept("STORY_SELA_LIGHTS")
	if not questDone("STORY_SELA_LIGHTS") then
		-- materials for the posts still to build only (built ones already took theirs)
		local left = 0
		for i = 1, #POSTS do if not postBuilt(i) then left += 1 end end
		local ironNeed, woodNeed = left * 2, left * 5
		if count("Iron Ore") < ironNeed then S.mine(gen, {Iron = true}, "Iron Ore", ironNeed) end
		if not alive(gen) then return end
		setStatus("เดินไปป่า Jungle")
		walk(SELA_POS, 15, 600, gen)
		S.trees({["Jungle tree"] = true, ["Banana tree"] = true}, {JungleWood = true, Banana = true},
			{JungleWood = woodNeed, Banana = 30}, gen)
		if not alive(gen) then return end
		S.posts(gen)
		if not alive(gen) then return end
		walk(SELA_POS, 12, 300, gen)
		claim("STORY_SELA_LIGHTS")
	end
	if not alive(gen) then return end
	accept("STORY_SELA_TAMING")
	if not questDone("STORY_SELA_TAMING") then
		if count("Banana") < 30 then
			S.trees({["Banana tree"] = true}, {JungleWood = true, Banana = true}, {Banana = 30}, gen)
		end
		walk(SELA_POS, 12, 300, gen)
		claim("STORY_SELA_TAMING")
	end
	if not alive(gen) then return end
	accept("STORY_SELA_MOUNT")
	setStatus("รับเควส King of the Jungle แล้ว")
end

-- King of the Jungle: hand the fighting to the farm (poly_loot) one area at a time, TripleCobra via boss hunt
local MOUNT = "STORY_SELA_MOUNT"
local NEED = {50, 50, 50, 50, 100, 1}   -- Frog, Tiger, Crocodile, Cobra, Gorilla, TripleCobra
local STAGES = {
	{objs = {1, 2, 3}, mobs = {"Frog", "Tiger", "Crocodile"}, anchor = Vector3.new(41, 121, -1790), r = 170},
	{objs = {5}, mobs = {"Gorilla"}, anchor = Vector3.new(308, 137, -2101), r = 230},
	{objs = {4}, mobs = {"Cobra"}, anchor = Vector3.new(-340, 135, -1783), r = 220},
}
local MOTH = {mobs = {"Moth"}, anchor = Vector3.new(860, 104.6, -2330), r = 150}
local function progress()
	local a = story().Active[MOUNT]
	return a and a.Progress or {}
end
local function setFarm(mobs, anchor, r)
	local e = st.cfg
	local m = {}
	for _, n in ipairs(mobs) do m[n] = true end
	e.mobs = m
	e.useAnchor = true
	e.anchor = {math.floor(anchor.X * 10) / 10, math.floor(anchor.Y * 10) / 10, math.floor(anchor.Z * 10) / 10}
	e.anchorR = r
	st.target = nil
end
function S.mountFarm(gen)
	local e = st.cfg
	local oldPick, oldHunt = e.bossPick, e.bossHunt
	local pick = {}
	for k, v in pairs(oldPick or {}) do pick[k] = v end
	pick.TripleCobra = true
	e.bossPick, e.bossHunt = pick, true
	local cur
	while alive(gen) and questActive(MOUNT) do
		local p = progress()
		local all = true
		for i, n in ipairs(NEED) do if (tonumber(p[i]) or 0) < n then all = false end end
		if all then break end
		local stage
		for _, sg in ipairs(STAGES) do
			for _, o in ipairs(sg.objs) do
				if (tonumber(p[o]) or 0) < NEED[o] then stage = stage or sg end
			end
		end
		if not stage then
			-- only the TripleCobra left: wait at the cobra area, boss hunt takes it when it spawns
			stage = STAGES[3]
		end
		if cur ~= stage then
			cur = stage
			setFarm(stage.mobs, stage.anchor, stage.r)
			log("ฟาร์ม " .. table.concat(stage.mobs, "/"))
		end
		st.extBusy = false
		e.farm = true
		local parts = {}
		local names = {"Frog", "Tiger", "Croc", "Cobra", "Gorilla", "TripleCobra"}
		for i, n in ipairs(NEED) do parts[#parts + 1] = ("%s %d/%d"):format(names[i], tonumber(p[i]) or 0, n) end
		S.status = "ฟาร์มเควส: " .. table.concat(parts, " · ")
		task.wait(5)
	end
	if not alive(gen) then return end
	e.farm = false
	st.extBusy = true
	task.wait(1)
	claim(MOUNT)
	log(("SelaGorilla ในกระเป๋า: %d"):format(count("SelaGorilla")))
	e.bossPick, e.bossHunt = oldPick, oldHunt
	-- then back to the Moth farm, as asked
	setFarm(MOTH.mobs, MOTH.anchor, MOTH.r)
	st.extBusy = false
	e.farm = true
	setStatus("ได้กอริลล่าแล้ว → ฟาร์ม Moth")
	log("ไปฟาร์ม Moth ต่อ")
end
function S.full(gen)
	S.all(gen)
	if alive(gen) and questActive(MOUNT) then S.mountFarm(gen) end
end

-- ------------------------------------------------------------------ runner
function S.stop()
	S.gen += 1
	st.extBusy = false
	pcall(api.stopMove)
	setStatus("หยุด")
end
function S.run(phase, ...)
	S.stop()
	local gen = S.gen
	local args = {...}
	st.cfg.farm = false
	st.extBusy = true
	task.spawn(function()
		local ok, err = pcall(function()
			if phase == "wood" then
				local n = args[1] or 25
				local done = S.trees({["Pine Tree"] = true, ["Pine Tree 2"] = true, ["Tall Pine Tree"] = true, ["Tall Pine Tree 2"] = true},
					{Wood = true}, {Wood = n}, gen)
				log(("wood: %s (Wood %d)"):format(tostring(done), count("Wood")))
			elseif phase == "jungle" then
				local done = S.trees({["Jungle tree"] = true, ["Banana tree"] = true}, {JungleWood = true, Banana = true},
					{JungleWood = args[1] or 35, Banana = args[2] or 30}, gen)
				log(("jungle: %s (JungleWood %d, Banana %d)"):format(tostring(done), count("JungleWood"), count("Banana")))
			elseif type(S[phase]) == "function" then
				S[phase](gen, table.unpack(args))
			end
		end)
		if not ok then log("error: " .. tostring(err)) end
		if alive(gen) then
			st.extBusy = false
			setStatus("เสร็จ " .. phase)
		end
	end)
end
S.count, S.walk, S.equip, S.pickup, S.chop = count, walk, equip, pickup, chop
log("loaded")
return S
