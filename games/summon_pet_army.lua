-- [🌾 HARVEST EVENT] Summon a Pet Army 🐲 (placeId 89695026030574) -- Auto Farm: pick zone -> rarity -> creatures,
-- warp to them, punch until the army kills them, summon the soul. MacLib window, RightShift toggles it,
-- settings persist (PetArmy/state_<userId>.json).
--
-- How the game works (verified 2026-11-21):
--   Config.Zones[i].Pools = {Easy, Hard, Rare, Chase, Divine, Boss} -> creature kinds; Config.RarityLadder[i][tier] = rarity name
--   Wild creatures: CollectionService tag "WildCreature", attributes Kind / Zone / Tier / HP / MaxHP / Size (1 Tiny .. 5 Huge)
--     / OwnerId (set while another player fights it). StreamingEnabled (radius 1024): only creatures near the character exist.
--   Remotes.Punch:FireServer(model) -- range Config.Punch.Range (11) + half the creature's size, cooldown 0.9 s; the army joins in
--   Remotes.Soul "add"(id, {kind, size, chance, sure, life}) after a kill -> Remotes.SoulChoice:FireServer(id, "summon")
--   Remotes.Arise (pos, playerName, ...) = caught. Army full -> it goes to storage (Notify "Army full! ... stored").

getgenv().__SPA = (getgenv().__SPA or 0) + 1
local G = getgenv().__SPA
pcall(function() if getgenv().__SPAW then getgenv().__SPAW:Unload() end end)
local function alive() return getgenv().__SPA == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local CS = game:GetService("CollectionService")
local UIS = game:GetService("UserInputService")
local plr = Players.LocalPlayer

local Shared = RS:WaitForChild("Shared")
local Remotes = RS:WaitForChild("Remotes")
local Config = require(Shared:WaitForChild("Config"))
local CreatureData = require(Shared:WaitForChild("CreatureData"))
local Punch = Remotes:WaitForChild("Punch")
local SoulRE = Remotes:WaitForChild("Soul")
local SoulChoice = Remotes:WaitForChild("SoulChoice")
local AriseRE = Remotes:WaitForChild("Arise")
local NotifyRE = Remotes:WaitForChild("Notify")
local ArmyAction = Remotes:WaitForChild("ArmyAction")
local ShroudRE = Remotes:WaitForChild("Shroud")

-- ------------------------------------------------------------------ settings
local SF = ("PetArmy/state_%d.json"):format(plr.UserId)
local DEFAULTS = {farm = false, zones = {}, rars = {}, kinds = {}, minSize = 1, catchOthers = false, shroud = true, shroudPen = true, pauseOnMove = true, reconnect = true, antiAfk = true}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
local function sv()
	pcall(function()
		if makefolder and not isfolder("PetArmy") then makefolder("PetArmy") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

local st = {status = "ปิดอยู่", target = "-", shroud = "-", shroudKills = 0, placed = 0, opened = 0, kills = 0, caught = 0, missed = 0, lastCatch = "-", army = "-", wd = "-", err = "-"}
local caughtBy = {}

-- ------------------------------------------------------------------ game tables
local TIERS = {"Easy", "Hard", "Rare", "Chase", "Divine", "Boss"}
local SIZE_NAMES = {}
for i, s in ipairs(Config.Sizes.List) do SIZE_NAMES[i] = s.Name end

local ZONES = {}   -- {id, index, name, tiers = {tier = {kinds}}}
local ZONE_BY_ID = {}
for i, z in ipairs(Config.Zones) do
	local info = {id = z.Id, index = i, name = z.Name, secret = z.Secret == true, zmin = z.ZMin, zmax = z.ZMax, tiers = {}}
	for _, tier in ipairs(TIERS) do
		local kinds = {}
		for _, k in ipairs((z.Pools or {})[tier] or {}) do
			if CreatureData[k] and not CreatureData[k].Retired then kinds[#kinds + 1] = k end
		end
		if #kinds > 0 then info.tiers[tier] = kinds end
	end
	ZONES[#ZONES + 1] = info
	ZONE_BY_ID[z.Id] = info
end
local function rarityOf(zone, tier)
	if tier == "Boss" then return "Boss" end
	local l = Config.RarityLadder[zone.index]
	return l and l[tier] or tier
end
local function cname(kind) return (CreatureData[kind] and CreatureData[kind].DisplayName) or kind end
local function unlocked(zone)
	if zone.index == 1 then return true end
	if zone.secret then return plr:GetAttribute(zone.id .. "Found") == true end
	return plr:GetAttribute(zone.id .. "Unlocked") == true
end

-- spawn points per zone (surveyed 2026-11-21). The zone streams in once the character stands at any of them;
-- every CreatureSpawns part seen while playing is added and saved, so later visits know more spots.
local ANCHORS = {
	Zone1 = {Vector3.new(30, 2, -160), Vector3.new(0, 2, -270), Vector3.new(48, 2, -58)},
	Zone2 = {Vector3.new(62, 1, -756), Vector3.new(-6, 2, -647), Vector3.new(0, 2, -836)},
	Zone3 = {Vector3.new(118, 47, -1476)},
	Zone4 = {Vector3.new(82, 2, -2446), Vector3.new(122, 26, -2626)},
	Zone5 = {Vector3.new(3, -38, -3648), Vector3.new(107, -38, -3520)},
	Zone6 = {Vector3.new(64, 2, -5330), Vector3.new(112, 46, -5626), Vector3.new(0, 46, -5873)},
	Zone7 = {Vector3.new(-264, 14, -7238), Vector3.new(-260, 2, -6880), Vector3.new(-345, 14, -7583)},
	Zone8 = {Vector3.new(-345, 122, -8625), Vector3.new(-15, 122, -8650)},
}
e.spawns = type(e.spawns) == "table" and e.spawns or {}
local function anchorsOf(zid)
	local out = table.clone(ANCHORS[zid] or {})
	for _, p in ipairs(e.spawns[zid] or {}) do out[#out + 1] = Vector3.new(p[1], p[2], p[3]) end
	return out
end
local function learnSpawns()
	local changed = false
	for _, z in ipairs(ZONES) do
		local folder = workspace:FindFirstChild("Zones") and workspace.Zones:FindFirstChild(Config.Zones[z.index].Folder)
		local sp = folder and folder:FindFirstChild("CreatureSpawns")
		if sp then
			local list = e.spawns[z.id] or {}
			for _, p in ipairs(sp:GetChildren()) do
				if p:IsA("BasePart") then
					local v = {math.floor(p.Position.X), math.floor(p.Position.Y), math.floor(p.Position.Z)}
					local dup = false
					for _, a in ipairs(anchorsOf(z.id)) do
						if (a - Vector3.new(v[1], v[2], v[3])).Magnitude < 40 then dup = true break end
					end
					if not dup and #list < 12 then list[#list + 1] = v; changed = true end
				end
			end
			e.spawns[z.id] = list
		end
	end
	if changed then sv() end
end

-- ------------------------------------------------------------------ selection
-- all multi-select: e.zones = {zoneId}, e.rars = {rarity name}, e.kinds = {kind}; the targets are e.kinds
local KIND_ZONE, KIND_RAR = {}, {}
for _, z in ipairs(ZONES) do
	for tier, kinds in pairs(z.tiers) do
		for _, k in ipairs(kinds) do
			if not KIND_ZONE[k] then KIND_ZONE[k], KIND_RAR[k] = z.id, rarityOf(z, tier) end
		end
	end
end
local function list(v) return type(v) == "table" and v or {} end
e.zones, e.rars, e.kinds = list(e.zones), list(e.rars), list(e.kinds)
if type(e.sel) == "table" and next(e.sel) then   -- settings from the one-zone-at-a-time version
	for zid, s in pairs(e.sel) do
		if type(s) == "table" and ZONE_BY_ID[zid] then
			for _, k in ipairs(list(s.kinds)) do
				if not table.find(e.kinds, k) then e.kinds[#e.kinds + 1] = k end
				if not table.find(e.zones, zid) then e.zones[#e.zones + 1] = zid end
				if KIND_RAR[k] and not table.find(e.rars, KIND_RAR[k]) then e.rars[#e.rars + 1] = KIND_RAR[k] end
			end
		end
	end
	e.sel = nil
	sv()
end
local function targetMap()   -- kind -> zoneId
	local m = {}
	for _, k in ipairs(e.kinds) do
		if KIND_ZONE[k] then m[k] = KIND_ZONE[k] end
	end
	return m
end

-- ------------------------------------------------------------------ helpers
local function fmt(n)
	n = tonumber(n) or 0
	if n >= 1e12 then return ("%.2fT"):format(n / 1e12) end
	if n >= 1e9 then return ("%.2fB"):format(n / 1e9) end
	if n >= 1e6 then return ("%.2fM"):format(n / 1e6) end
	if n >= 1e3 then return ("%.1fK"):format(n / 1e3) end
	return tostring(math.floor(n))
end
local function hum() local c = plr.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function hrp() local c = plr.Character; return c and c:FindFirstChild("HumanoidRootPart") end

local lastMove = 0
local MOVE_KEYS = {}
for _, k in ipairs({"W", "A", "S", "D", "Up", "Down", "Left", "Right", "Space"}) do MOVE_KEYS[Enum.KeyCode[k]] = true end
local inputConn = UIS.InputChanged:Connect(function(io)
	if io.KeyCode == Enum.KeyCode.Thumbstick1 and io.Position.Magnitude > 0.3 then lastMove = os.clock() end
end)
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
	if plr:GetAttribute("Drumming") then return "กำลังตีกลอง" end
	if e.pauseOnMove and os.clock() - lastMove < 3 then return "คุณกำลังเดินเอง" end
	return nil
end

local groundRay = RaycastParams.new()
groundRay.FilterType = Enum.RaycastFilterType.Exclude
groundRay.RespectCanCollide = true
local function groundAt(pos)
	local ex = {}
	if plr.Character then ex[#ex + 1] = plr.Character end
	for _, n in ipairs({"WildCreatures", "Followers"}) do
		local f = workspace:FindFirstChild(n)
		if f then ex[#ex + 1] = f end
	end
	groundRay.FilterDescendantsInstances = ex
	local hit = workspace:Raycast(pos + Vector3.new(0, 25, 0), Vector3.new(0, -80, 0), groundRay)
	return hit and (hit.Position + Vector3.new(0, 3, 0)) or pos
end
local function warp(pos, lookAt)
	local r = hrp()
	if not r then return false end
	r.AssemblyLinearVelocity = Vector3.zero
	r.CFrame = lookAt and CFrame.lookAt(pos, Vector3.new(lookAt.X, pos.Y, lookAt.Z)) or (CFrame.new(pos) * (r.CFrame - r.CFrame.Position))
	return true
end
-- far warp: ask the server to stream the spot first so the floor exists when the character lands
local function warpFar(pos)
	pcall(function() plr:RequestStreamAroundAsync(pos, 4) end)
	if not alive() then return false end
	return warp(groundAt(pos + Vector3.new(0, 3, 0)))
end

-- every job runs as its own supervised loop: a pass that hangs is cancelled and the loop carries on
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
			while not done and alive() and os.clock() - t0 < limit do task.wait(0.2) end
			if not done then
				pcall(task.cancel, th)
				st.wd = ("%s ค้างเกิน %d วิ → ตัดแล้วเริ่มใหม่ · %s"):format(name, limit, os.date("%H:%M:%S"))
			end
			task.wait(period)
		end
	end)
end

-- ------------------------------------------------------------------ souls
local pending = {}   -- soul id -> kind (summon sent, waiting for Arise)
local soulConn = SoulRE.OnClientEvent:Connect(function(kind, id, data)
	if not alive() then return end
	if kind == "add" and type(data) == "table" and data.kind then
		local want = targetMap()[data.kind] ~= nil
		if e.farm and (want or e.catchOthers) then
			pending[id] = data.kind
			pcall(SoulChoice.FireServer, SoulChoice, id, "summon")
		end
	elseif kind == "remove" and pending[id] then
		local k = pending[id]
		pending[id] = nil
		if data == "summon" then st.lastSoul = k else st.missed += 1 end   -- "fade" = the soul ran out before the roll
	end
end)
local ariseConn = AriseRE.OnClientEvent:Connect(function(_, who)
	if not alive() then return end
	if tostring(who) == plr.Name and st.lastSoul then
		local k = st.lastSoul
		st.caught += 1
		caughtBy[k] = (caughtBy[k] or 0) + 1
		st.lastCatch = cname(k) .. " · " .. os.date("%H:%M:%S")
	end
end)
local notifyConn = NotifyRE.OnClientEvent:Connect(function(msg)
	if not alive() or type(msg) ~= "string" then return end
	if msg:find("escap") or msg:find("Missed") or msg:find("broke free") then st.missed += 1 end
	st.lastNote = msg:sub(1, 80)
end)

-- ------------------------------------------------------------------ shrouded
-- "Shrouded ???" (CreatureData.Shroud): the server rolls one at a time into a random zone and announces it on
-- Remotes.Shroud "appear" {zoneNum, zone}. Killing it gives a Mystery Soul (player attribute MysterySouls) that hatches
-- in the camp pen: Shroud:FireServer("hold") then ("place", pos inside my PenArea); a hatched orb
-- (workspace.MysterySouls child, Owner = me, ReadyAt <= now) opens with ("open", Id) from within 14 studs.
local shroudSeen = {zone = nil, at = 0}
local shroudConn = ShroudRE.OnClientEvent:Connect(function(kind, data)
	if not alive() then return end
	if kind == "appear" and type(data) == "table" and data.zoneNum then
		shroudSeen.zone, shroudSeen.at = tonumber(data.zoneNum), os.clock()
		st.shroud = ("เกิดที่ %s · %s"):format(tostring(data.zone or ("โซน " .. data.zoneNum)), os.date("%H:%M:%S"))
	elseif kind == "got" then
		st.shroudKills += 1
		st.shroud = "ได้ Mystery Soul · " .. os.date("%H:%M:%S")
		shroudSeen.zone = nil
	end
end)
local function shroudDead(m)
	return not m.Parent or m:GetAttribute("Dying") == true or (m:GetAttribute("HP") ~= nil and m:GetAttribute("HP") <= 0)
end
local function findShroud()
	if not e.shroud then return nil end
	local r = hrp()
	if not r then return nil end
	local best, bd
	local seen = {}
	local list = CS:GetTagged("Shroud")
	for _, m in ipairs(CS:GetTagged("WildCreature")) do
		if m:GetAttribute("Kind") == "Shroud" or m:GetAttribute("Tier") == "Shroud" then list[#list + 1] = m end
	end
	for _, m in ipairs(list) do
		if not seen[m] and m:IsA("Model") and not shroudDead(m) then
			seen[m] = true
			local o = m:GetAttribute("OwnerId")
			if not (o and o ~= plr.UserId) then
				local d = (m:GetPivot().Position - r.Position).Magnitude
				if not bd or d < bd then best, bd = m, d end
			end
		end
	end
	return best
end

-- ------------------------------------------------------------------ farm
local function isTarget(m, tmap)
	if not (m.Parent and m.PrimaryPart) then return false end
	local k = m:GetAttribute("Kind")
	if not k or not tmap[k] then return false end
	if tmap[k] ~= m:GetAttribute("Zone") then return false end
	local o = m:GetAttribute("OwnerId")
	if o and o ~= plr.UserId then return false end
	if (m:GetAttribute("HP") or 0) <= 0 then return false end
	if (m:GetAttribute("Size") or 3) < (tonumber(e.minSize) or 1) then return false end
	return true
end
local function findTarget(tmap)
	local r = hrp()
	if not r then return nil end
	local best, bd
	for _, m in ipairs(CS:GetTagged("WildCreature")) do
		if isTarget(m, tmap) then
			local d = (m.PrimaryPart.Position - r.Position).Magnitude
			if not bd or d < bd then best, bd = m, d end
		end
	end
	return best
end

local function fight(m)
	local pp = m.PrimaryPart
	local name = m:GetAttribute("DisplayName") or m.Name
	if m:GetAttribute("Kind") == "Shroud" or CS:HasTag(m, "Shroud") then name = "Shrouded ???" end
	local zid = m:GetAttribute("Zone")
	local boss = m:GetAttribute("Tier") == "Boss"
	local limit = boss and 240 or 90
	local t0 = os.clock()
	local lastHP, lastDrop = m:GetAttribute("HP"), os.clock()
	local function dead() return shroudDead(m) or (m:GetAttribute("HP") or 1) <= 0 end
	while alive() and e.farm and not dead() do
		if busyHands() then st.status = "พัก: " .. busyHands(); return end
		local o = m:GetAttribute("OwnerId")
		if o and o ~= plr.UserId then st.status = name .. " มีคนอื่นตีอยู่ → หาตัวใหม่"; return end
		pp = m.PrimaryPart
		local cf, size = m:GetPivot(), pp and pp.Size or select(2, m:GetBoundingBox())
		local half = math.min(math.max(size.X, size.Z) / 2, 30)
		local away = cf.Position - (cf.LookVector * (half + 5))
		local spot = groundAt(Vector3.new(away.X, cf.Position.Y, away.Z))
		warp(spot, cf.Position)
		pcall(Punch.FireServer, Punch, m)
		local hp = m:GetAttribute("HP") or 0
		if lastHP and hp < lastHP then lastHP, lastDrop = hp, os.clock() end
		st.target = ("%s (%s) · HP %s / %s"):format(name, ZONE_BY_ID[zid] and ZONE_BY_ID[zid].name or tostring(zid), fmt(hp), fmt(m:GetAttribute("MaxHP")))
		st.status = "กำลังตี " .. name
		if os.clock() - t0 > limit then st.status = name .. " ตีนานเกิน " .. limit .. " วิ → ข้าม"; return end
		if os.clock() - lastDrop > 25 then st.status = name .. " เลือดไม่ลด 25 วิ → ข้าม"; return end
		task.wait(0.95)
	end
	if dead() then
		st.kills += 1
		st.status = name .. " ตายแล้ว → รอ soul แล้วจับ"
		task.wait(1.5)   -- the soul arrives ~0.3 s after the kill, the summon roll ~0.3 s after that
	end
end

local function myPen()
	local idx = plr:GetAttribute("Plot")
	local plots = workspace:FindFirstChild("Camp") and workspace.Camp:FindFirstChild("Plots")
	if not (idx and plots) then return nil end
	for _, p in ipairs(plots:GetChildren()) do
		if p:GetAttribute("PlotIndex") == idx then return p:FindFirstChild("PenArea", true) end
	end
end
local function myReadyOrbs()
	local out = {}
	local f = workspace:FindFirstChild("MysterySouls")
	for _, o in ipairs(f and f:GetChildren() or {}) do
		if o:GetAttribute("Owner") == plr.UserId and not o:GetAttribute("OpenAt")
			and (o:GetAttribute("ReadyAt") or math.huge) <= workspace:GetServerTimeNow() then
			out[#out + 1] = o
		end
	end
	return out
end
local CAMP = Vector3.new(3000, 5, 300)
local nextPenCheck = 0
local function penJob()
	if not e.shroudPen or os.clock() < nextPenCheck then return false end
	local souls = plr:GetAttribute("MysterySouls") or 0
	if souls <= 0 then
		-- orbs outside the camp aren't streamed: peek at the camp every few minutes so finished hatches get opened
		pcall(function() plr:RequestStreamAroundAsync(CAMP, 3) end)
		if #myReadyOrbs() == 0 then nextPenCheck = os.clock() + 180; return false end
	end
	st.status = ("กลับแคมป์: วาง Mystery Soul %d · เปิดที่ฟักเสร็จ %d"):format(souls, #myReadyOrbs())
	local pen = myPen()
	if not pen then
		warpFar(CAMP)
		task.wait(1.5)
		pen = myPen()
	end
	if not pen then st.shroud = "หาคอกตัวเองไม่เจอ"; nextPenCheck = os.clock() + 60; return false end
	warpFar(pen.Position + Vector3.new(0, 4, 0))
	local t0 = os.clock()
	while plr:GetAttribute("Zone") ~= "Camp" and os.clock() - t0 < 4 do task.wait(0.2) end
	for _ = 1, souls do
		if not alive() then break end
		pcall(ShroudRE.FireServer, ShroudRE, "hold")
		task.wait(0.4)
		local hx, hz = math.max(pen.Size.X / 2 - 3, 0), math.max(pen.Size.Z / 2 - 3, 0)
		local pos = pen.CFrame:PointToWorldSpace(Vector3.new((math.random() * 2 - 1) * hx, 0, (math.random() * 2 - 1) * hz))
		pos = Vector3.new(pos.X, pen.Position.Y + pen.Size.Y / 2, pos.Z)
		local before = plr:GetAttribute("MysterySouls") or 0
		pcall(ShroudRE.FireServer, ShroudRE, "place", pos)
		task.wait(1.6)   -- the client allows one place per 1.5 s
		if (plr:GetAttribute("MysterySouls") or 0) < before then st.placed += 1 end
	end
	task.wait(0.5)
	for _, o in ipairs(myReadyOrbs()) do
		if not alive() then break end
		warp(groundAt(o:GetPivot().Position + Vector3.new(5, 0, 0)), o:GetPivot().Position)
		task.wait(0.3)
		pcall(ShroudRE.FireServer, ShroudRE, "open", o:GetAttribute("Id"))
		st.opened += 1
		task.wait(3.5)   -- countdown / crack animation, then the creature arises
	end
	nextPenCheck = os.clock() + 20
	return true
end

local scoutIdx, zoneCursor, zoneSince = 0, 0, 0
local function farmStep()
	if not e.farm then st.status = "ปิดอยู่"; st.target = "-"; return end
	local why = busyHands()
	if why then st.status = "พัก: " .. why; return end
	local tmap = targetMap()
	local zoneList = {}
	for _, z in ipairs(ZONES) do
		for _, zid in pairs(tmap) do if zid == z.id then zoneList[#zoneList + 1] = z; break end end
	end
	learnSpawns()
	local sh = findShroud()
	if sh then return fight(sh) end
	if penJob() then return end

	-- a Shrouded was announced: scout its zone first for 3 minutes (it may sit in a zone with no picked creatures)
	local shZone = e.shroud and shroudSeen.zone and os.clock() - shroudSeen.at < 180 and ZONES[shroudSeen.zone]
	if shZone and not unlocked(shZone) then shZone = nil end
	if shZone then
		for i, x in ipairs(zoneList) do if x == shZone then table.remove(zoneList, i) break end end
		table.insert(zoneList, 1, shZone)
	end
	if #zoneList == 0 then st.status = e.shroud and "รอ Shrouded เกิด (ยังไม่ได้เลือกตัวอื่น)" or "ยังไม่ได้เลือกตัวที่จะจับ"; st.target = "-"; return end

	local m = findTarget(tmap)
	if m then return fight(m) end

	-- nothing streamed in: go to the next targeted zone's spawn spots (one zone at a time, ~6 s per spot)
	if shZone or zoneCursor < 1 or zoneCursor > #zoneList then zoneCursor = 1 end
	local z = zoneList[zoneCursor]
	if not unlocked(z) then
		st.status = z.name .. " ยังไม่ปลดล็อก → ข้าม"
		zoneCursor += 1
		return
	end
	local spots = anchorsOf(z.id)
	if #spots == 0 then
		local mid = (z.zmin + z.zmax) / 2
		spots = {Vector3.new(0, 20, mid)}
	end
	scoutIdx = scoutIdx % #spots + 1
	st.status = ("หาเป้าใน %s (จุด %d/%d)"):format(z.name, scoutIdx, #spots)
	st.target = "ยังไม่เจอ (ตัวหายาก Chase/Divine เกิดนาน ๆ ครั้ง)"
	warpFar(spots[scoutIdx])
	local t0 = os.clock()
	while alive() and e.farm and os.clock() - t0 < 6 do
		task.wait(0.5)
		if findTarget(tmap) or findShroud() then return end
	end
	if scoutIdx >= #spots and not shZone then zoneCursor += 1 end
end
loopEvery("Auto Farm", 0.1, 300, farmStep)

-- army / storage count for the status panel
task.spawn(function()
	while alive() do
		pcall(function()
			local ok, r = pcall(ArmyAction.InvokeServer, ArmyAction, "get")
			if ok and type(r) == "table" and type(r.state) == "table" then
				local s = r.state
				st.army = ("army %d/%d · storage %d%s"):format(#(s.army or {}), s.slots or 0, #(s.storage or {}), s.capped and " (เต็ม!)" or "")
			end
		end)
		task.wait(20)
	end
end)

-- anti-AFK
local VirtualUser = game:GetService("VirtualUser")
local idleConn = plr.Idled:Connect(function()
	if not alive() or not e.antiAfk then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
	st.wd = "anti-AFK กันเตะ · " .. os.date("%H:%M:%S")
end)

-- auto reconnect: only real disconnect codes (256-511); 273/274 = account joined elsewhere -> leave it alone
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
		for _ = 1, 20 do
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
if not okL or not Lib then warn("[PetArmy] MacLib failed: " .. tostring(Lib)) return end
if not alive() then return end
local Win = Lib:Window({Title = "Summon a Pet Army", Subtitle = "Auto Farm", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__SPAW = Win
local TG = Win:TabGroup()
local Tabs = {
	Main = TG:Tab({Name = "Auto Farm", Image = "rbxassetid://10723346959"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}

local function picked(v)   -- MacLib multi callback -> list of option labels
	local out = {}
	for k, on in pairs(type(v) == "table" and v or {}) do
		local label = type(k) == "number" and on or (on and k)
		if type(label) == "string" then out[#out + 1] = label end
	end
	return out
end

local L = Tabs.Main:Section({Side = "Left"})
L:Header({Text = "Auto Farm"})
L:Toggle({Name = "Auto Farm", Default = e.farm, Callback = function(v) e.farm = v; sv() end}, "SPAFarm")
L:Label({Text = "วาร์ปไปหาตัวที่เลือก → ตี (army ช่วยตี) → ตายแล้วกด summon จับให้\nเลือกโซน (หลายโซนได้) → rarity ที่มีในโซนเหล่านั้น → ตัวที่จะจับ · ที่เลือกเซฟอัตโนมัติ"})

local zoneOpts, zoneByLabel, zoneLabel = {}, {}, {}
for _, z in ipairs(ZONES) do
	if not z.secret or unlocked(z) then
		local label = ("%d · %s%s"):format(z.index, z.name, unlocked(z) and "" or " (ยังล็อก)")
		zoneOpts[#zoneOpts + 1] = label
		zoneByLabel[label] = z
		zoneLabel[z.id] = label
	end
end
local RAR_ORDER = table.clone(Config.RarityOrder)
RAR_ORDER[#RAR_ORDER + 1] = "Boss"

local rebuilding = false
local rarDD, kindDD, selLbl
local kindByLabel = {}

local function refreshSelLabel()
	if not selLbl then return end
	local byZone = {}
	for _, k in ipairs(e.kinds) do
		local zid = KIND_ZONE[k]
		if zid then byZone[zid] = byZone[zid] or {}; table.insert(byZone[zid], cname(k)) end
	end
	local lines = {}
	for _, z in ipairs(ZONES) do
		if byZone[z.id] then lines[#lines + 1] = ("%d %s: %s"):format(z.index, z.name, table.concat(byZone[z.id], ", ")) end
	end
	selLbl:UpdateName(#lines > 0 and table.concat(lines, "\n") or "ยังไม่ได้เลือกตัวไหน")
end

-- creatures of every picked zone whose rarity is picked; picks that fall out of the list are dropped
local function rebuildKinds()
	local opts, keep, def = {}, {}, {}
	kindByLabel = {}
	for _, z in ipairs(ZONES) do
		if table.find(e.zones, z.id) then
			for _, tier in ipairs(TIERS) do
				local rar = z.tiers[tier] and rarityOf(z, tier)
				if rar and table.find(e.rars, rar) then
					for _, k in ipairs(z.tiers[tier]) do
						local label = ("%s · %s · โซน %d"):format(cname(k), rar, z.index)
						opts[#opts + 1] = label
						kindByLabel[label] = k
						if table.find(e.kinds, k) then keep[#keep + 1] = k; def[#def + 1] = label end
					end
				end
			end
		end
	end
	e.kinds = keep
	rebuilding = true
	pcall(function() kindDD:ClearOptions() end)
	if #opts > 0 then pcall(function() kindDD:InsertOptions(opts) end) end
	pcall(function() kindDD:UpdateSelection(def) end)
	rebuilding = false
	sv()
	refreshSelLabel()
end

-- rarities present in the picked zones (each zone maps its tiers to different rarities)
local function rebuildRarities()
	local have = {}
	for _, z in ipairs(ZONES) do
		if table.find(e.zones, z.id) then
			for tier in pairs(z.tiers) do have[rarityOf(z, tier)] = true end
		end
	end
	local opts, keep = {}, {}
	for _, r in ipairs(RAR_ORDER) do
		if have[r] then
			opts[#opts + 1] = r
			if table.find(e.rars, r) then keep[#keep + 1] = r end
		end
	end
	e.rars = keep
	rebuilding = true
	pcall(function() rarDD:ClearOptions() end)
	if #opts > 0 then pcall(function() rarDD:InsertOptions(opts) end) end
	pcall(function() rarDD:UpdateSelection(keep) end)
	rebuilding = false
	rebuildKinds()
end

L:Header({Text = "เลือกเป้า (เลือกได้หลายอันทุกช่อง)"})
local zoneDef = {}
for _, zid in ipairs(e.zones) do if zoneLabel[zid] then zoneDef[#zoneDef + 1] = zoneLabel[zid] end end
L:Dropdown({Name = "1. โซน", Multi = true, Required = false, Options = zoneOpts, Default = zoneDef,
	Callback = function(v)
		local zs = {}
		for _, label in ipairs(picked(v)) do if zoneByLabel[label] then zs[#zs + 1] = zoneByLabel[label].id end end
		e.zones = zs; sv()
		task.defer(rebuildRarities)
	end}, "SPAZone")
rarDD = L:Dropdown({Name = "2. Rarity", Multi = true, Required = false, Options = {}, Default = {},
	Callback = function(v)
		if rebuilding then return end
		local rs = {}
		for _, label in ipairs(picked(v)) do if table.find(RAR_ORDER, label) then rs[#rs + 1] = label end end
		e.rars = rs
		task.defer(rebuildKinds)
	end}, "SPARarity")
kindDD = L:Dropdown({Name = "3. ตัวที่จะจับ", Multi = true, Required = false, Options = {}, Default = {},
	Callback = function(v)
		if rebuilding then return end
		local ks = {}
		for _, label in ipairs(picked(v)) do if kindByLabel[label] then ks[#ks + 1] = kindByLabel[label] end end
		e.kinds = ks; sv()
		refreshSelLabel()
	end}, "SPAKinds")
L:Button({Name = "เลือกทุกตัวที่อยู่ในช่อง 3", Callback = function()
	local all = {}
	for _, k in pairs(kindByLabel) do all[#all + 1] = k end
	e.kinds = all
	rebuildKinds()
end})
L:Button({Name = "ล้างเป้าทั้งหมด", Callback = function()
	e.kinds = {}
	rebuildKinds()
end})
L:Header({Text = "ตัวเลือก"})
local sizeOpts = {}
for i, n in ipairs(SIZE_NAMES) do sizeOpts[i] = i == 1 and "ทุกขนาด" or (n .. " ขึ้นไป") end
L:Dropdown({Name = "ขนาดขั้นต่ำ", Multi = false, Required = true, Options = sizeOpts, Default = math.clamp(tonumber(e.minSize) or 1, 1, #sizeOpts),
	Callback = function(v)
		local label = type(v) == "table" and picked(v)[1] or v
		local i = table.find(sizeOpts, label)
		if i then e.minSize = i; sv() end
	end}, "SPASize")
L:Header({Text = "Shrouded ???"})
L:Toggle({Name = "ล่า Shrouded (เกิดสุ่มทุกโซน)", Default = e.shroud, Callback = function(v) e.shroud = v; sv() end}, "SPAShroud")
L:Toggle({Name = "└ เอา Mystery Soul ไปวางฟักที่คอก + เปิดเมื่อฟักเสร็จ", Default = e.shroudPen, Callback = function(v) e.shroudPen = v; sv() end}, "SPAShroudPen")
L:Label({Text = "เกมประกาศเมื่อ Shrouded เกิด → วาร์ปไปโซนนั้นตีก่อนตัวอื่น (ต้องเปิด Auto Farm)\nตายแล้วได้ Mystery Soul → กลับแคมป์วางในคอก ฟัก 15-60 นาที → เปิดได้ Rare / Chase / Divine"})
L:Toggle({Name = "จับ soul ตัวอื่นที่ตายด้วย (army ตีโดน)", Default = e.catchOthers, Callback = function(v) e.catchOthers = v; sv() end}, "SPAOthers")
L:Toggle({Name = "หยุดบอทตอนฉันกดเดินเอง", Default = e.pauseOnMove, Callback = function(v) e.pauseOnMove = v; sv() end}, "SPAPause")
-- Anti-AFK / Auto Reconnect sit on this tab and on Settings; both copies stay in sync
local guardTabs, afkT, recT = false, {}, {}
local function syncSet(key, toggles, v)
	if guardTabs then return end
	e[key] = v; sv()
	guardTabs = true
	for _, t in ipairs(toggles) do pcall(function() if t:GetState() ~= v then t:UpdateState(v) end end) end
	guardTabs = false
end
L:Header({Text = "กันหลุด"})
afkT[#afkT + 1] = L:Toggle({Name = "Anti-AFK (กันโดนเตะตอนยืนนิ่ง 20 นาที)", Default = e.antiAfk, Callback = function(v) syncSet("antiAfk", afkT, v) end}, "SPAAntiAfk1")
recT[#recT + 1] = L:Toggle({Name = "Auto Reconnect (หลุด / โดนเตะ → เข้าเกมใหม่เอง)", Default = e.reconnect, Callback = function(v) syncSet("reconnect", recT, v) end}, "SPAReconnect1")

local R = Tabs.Main:Section({Side = "Right"})
R:Header({Text = "สถานะ"})
local stLbl = R:Label({Text = "-"})
R:Header({Text = "เป้าที่เลือกไว้ (ทุกโซน)"})
selLbl = R:Label({Text = "-"})
R:Header({Text = "จับได้รอบนี้"})
local catchLbl = R:Label({Text = "-"})

local S = Tabs.Settings:Section({Side = "Left"})
S:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() Win:SetState(not Win:GetState()) end) end}, "SPAToggleUI")
S:Header({Text = "กันหลุด"})
afkT[#afkT + 1] = S:Toggle({Name = "Anti-AFK (กันโดนเตะตอนยืนนิ่ง 20 นาที)", Default = e.antiAfk, Callback = function(v) syncSet("antiAfk", afkT, v) end}, "SPAAntiAfk")
recT[#recT + 1] = S:Toggle({Name = "Auto Reconnect (หลุด / โดนเตะ → เข้าเกมใหม่เอง)", Default = e.reconnect, Callback = function(v) syncSet("reconnect", recT, v) end}, "SPAReconnect")
S:Label({Text = "เข้าเกมใหม่แล้วสคริปต์โหลดเองผ่าน loader พร้อมค่าที่ตั้งไว้"})
S:Label({Text = "ตั้งค่าเซฟที่: " .. SF})

task.defer(rebuildRarities)

task.spawn(function()
	while alive() do
		pcall(function()
			stLbl:UpdateName(table.concat({
				st.status,
				"เป้า: " .. st.target,
				("Shrouded: %s · ฆ่า %d · Mystery Soul ถืออยู่ %d · วาง %d · เปิด %d"):format(st.shroud, st.shroudKills,
					plr:GetAttribute("MysterySouls") or 0, st.placed, st.opened),
				("ฆ่า %d · จับได้ %d · ล่าสุด: %s"):format(st.kills, st.caught, st.lastCatch),
				st.army,
				"แจ้งเตือนเกม: " .. tostring(st.lastNote or "-"),
				"Watchdog: " .. st.wd,
				"Error: " .. st.err,
			}, "\n"))
			local lines = {}
			for k, n in pairs(caughtBy) do lines[#lines + 1] = ("%s × %d"):format(cname(k), n) end
			table.sort(lines)
			catchLbl:UpdateName(#lines > 0 and table.concat(lines, "\n") or "ยังไม่ได้จับ")
		end)
		task.wait(0.5)
	end
end)

-- unload: stop every loop and drop the connections when the window closes or the script reloads
task.spawn(function()
	while alive() do task.wait(1) end
	for _, c in ipairs({soulConn, ariseConn, notifyConn, shroudConn, inputConn, idleConn, errConn}) do pcall(function() c:Disconnect() end) end
end)
pcall(function()
	Win.onUnloaded(function() if getgenv().__SPA == G then getgenv().__SPA = G + 1 end end)
end)
