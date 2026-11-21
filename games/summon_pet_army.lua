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
local DEFAULTS = {farm = false, zones = {}, rars = {}, kinds = {}, minSize = 1, catchOthers = false, drum = false, hboss = false, shroud = true, shroudPen = true, pauseOnMove = true, reconnect = true, antiAfk = true}
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
	-- zone 8 is ~2,450 studs long (easy band z -8.6k at y 122, hard band z -9.2k..-9.4k at y 177, boss -9722): the hard-band
	-- spots stream the far half too
	Zone8 = {Vector3.new(-345, 177, -9180), Vector3.new(-245, 122, -8880), Vector3.new(-245, 177, -9430)},
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
-- e.zones = {zoneId} picked zones; e.zsel[zoneId] = {rars = {rarity name}, kinds = {kind}} per zone.
-- Per picked rarity: the picked creatures of that rarity, or all of them when none is picked.
local KIND_ZONE, KIND_RAR, KIND_TIER = {}, {}, {}
for _, z in ipairs(ZONES) do
	for tier, kinds in pairs(z.tiers) do
		for _, k in ipairs(kinds) do
			if not KIND_ZONE[k] then KIND_ZONE[k], KIND_RAR[k], KIND_TIER[k] = z.id, rarityOf(z, tier), tier end
		end
	end
end
local function list(v) return type(v) == "table" and v or {} end
e.zones = list(e.zones)
e.zsel = type(e.zsel) == "table" and e.zsel or {}
local function zsel(zid)
	local s = type(e.zsel[zid]) == "table" and e.zsel[zid] or {}
	s.rars, s.kinds = list(s.rars), list(s.kinds)
	e.zsel[zid] = s
	return s
end
do   -- settings from the earlier layouts (one shared rarity / kind list, or e.sel per zone by tier)
	local migrated = false
	for _, zid in ipairs(e.zones) do   -- the old shared rarity list -> every picked zone that has those rarities
		local z = ZONE_BY_ID[zid]
		for _, r in ipairs(list(e.rars)) do
			for tier in pairs(z and z.tiers or {}) do
				local s = zsel(zid)
				if rarityOf(z, tier) == r and not table.find(s.rars, r) then s.rars[#s.rars + 1] = r end
			end
		end
	end
	for _, k in ipairs(list(e.kinds)) do
		local zid = KIND_ZONE[k]
		if zid then
			local s = zsel(zid)
			if not table.find(s.kinds, k) then s.kinds[#s.kinds + 1] = k end
			if not table.find(s.rars, KIND_RAR[k]) then s.rars[#s.rars + 1] = KIND_RAR[k] end
			if not table.find(e.zones, zid) then e.zones[#e.zones + 1] = zid end
			migrated = true
		end
	end
	if type(e.sel) == "table" then
		for zid, old in pairs(e.sel) do
			if type(old) == "table" and ZONE_BY_ID[zid] then
				for _, k in ipairs(list(old.kinds)) do
					local s = zsel(zid)
					if not table.find(s.kinds, k) then s.kinds[#s.kinds + 1] = k end
					if KIND_RAR[k] and not table.find(s.rars, KIND_RAR[k]) then s.rars[#s.rars + 1] = KIND_RAR[k] end
					if not table.find(e.zones, zid) then e.zones[#e.zones + 1] = zid end
					migrated = true
				end
			end
		end
	end
	if e.kinds or e.rars or e.sel then e.kinds, e.rars, e.sel, e.viewZone = nil, nil, nil, nil; migrated = true end
	if migrated then sv() end
end
local function zoneTargets(z)   -- list of kinds this zone hunts right now
	local s = zsel(z.id)
	local out = {}
	for _, tier in ipairs(TIERS) do
		local rar = z.tiers[tier] and rarityOf(z, tier)
		if rar and table.find(s.rars, rar) then
			local any = false
			for _, k in ipairs(z.tiers[tier]) do if table.find(s.kinds, k) then out[#out + 1] = k; any = true end end
			if not any then   -- no creature picked inside this rarity = the whole rarity
				for _, k in ipairs(z.tiers[tier]) do out[#out + 1] = k end
			end
		end
	end
	return out
end
local function targetMap()   -- kind -> zoneId
	local m = {}
	for _, z in ipairs(ZONES) do
		if table.find(e.zones, z.id) then
			for _, k in ipairs(zoneTargets(z)) do m[k] = z.id end
		end
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
	-- drumming (Command training at the plot drum) is left alone: after every night the game parks everyone on the drum,
	-- and stepping off is all it takes, so Auto Farm just warps away
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
-- RequestStreamAroundAsync can hang for a long time, so it gets its own thread and at most `wait` seconds
local function streamAround(pos, wait)
	local done = false
	task.spawn(function()
		pcall(function() plr:RequestStreamAroundAsync(pos, wait) end)
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < wait do task.wait(0.1) end
end
-- far warp: ask the server to stream the spot first so the floor exists when the character lands
local function warpFar(pos)
	streamAround(pos, 1)
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
-- The soul floats where the creature died and can only be summoned from within Config.Soul.Range (16 studs) of it.
-- The bot fights from 22-60 studs away, so a summon fired from there is ignored and the soul fades (Life 30 s).
-- grabSouls() walks over to every pending soul and keeps pressing summon until the server takes it.
local SoulCfg = (Config.Soul or {})
local SOUL_RANGE, SOUL_LIFE = SoulCfg.Range or 16, SoulCfg.Life or 30
local pending = {}   -- soul id -> {kind, pos, t, life}
local function soulDist(sl)
	local r = hrp()
	if not r or typeof(sl.pos) ~= "Vector3" then return math.huge end
	return Vector3.new(r.Position.X - sl.pos.X, 0, r.Position.Z - sl.pos.Z).Magnitude
end
local soulConn = SoulRE.OnClientEvent:Connect(function(kind, id, data)
	if not alive() then return end
	if kind == "add" and type(data) == "table" and data.kind then
		local want = targetMap()[data.kind] ~= nil
		if e.farm and (want or e.catchOthers) then
			local sl = {kind = data.kind, pos = data.pos, t = os.clock(), life = tonumber(data.life) or SOUL_LIFE}
			pending[id] = sl
			if soulDist(sl) < SOUL_RANGE - 2 then pcall(SoulChoice.FireServer, SoulChoice, id, "summon") end
		end
	elseif kind == "remove" and pending[id] then
		local k = pending[id].kind
		pending[id] = nil
		if data == "summon" then st.lastSoul, st.lastSoulAt = k, os.clock() else st.missed += 1 end   -- "fade" = the soul ran out before the roll
	end
end)
local ariseConn = AriseRE.OnClientEvent:Connect(function(_, who)
	if not alive() then return end
	if tostring(who) ~= plr.Name then return end
	local k = st.lastSoul and os.clock() - (st.lastSoulAt or 0) < 4 and st.lastSoul
	st.lastSoul = nil
	local label = k and cname(k) or "อื่น ๆ (เปิด Mystery Soul / จับเอง)"
	st.caught += 1
	caughtBy[label] = (caughtBy[label] or 0) + 1
	st.lastCatch = label .. " · " .. os.date("%H:%M:%S")
end)
local function grabSouls()
	for id, sl in pairs(pending) do
		if os.clock() - sl.t > sl.life then
			pending[id] = nil
		elseif typeof(sl.pos) == "Vector3" then
			local t0 = os.clock()
			while pending[id] == sl and alive() and os.clock() - t0 < 5 and os.clock() - sl.t < sl.life do
				if soulDist(sl) > SOUL_RANGE - 6 then
					warp(groundAt(sl.pos + Vector3.new(0, 0, 4)), sl.pos)
					task.wait(0.15)
				end
				st.status = "เข้าไปใกล้ soul แล้วกด summon: " .. cname(sl.kind)
				pcall(SoulChoice.FireServer, SoulChoice, id, "summon")
				task.wait(0.4)
			end
			if pending[id] == sl and os.clock() - t0 >= 5 then pending[id] = nil end   -- server never took it: give up on this one
		end
	end
end

local notifyConn = NotifyRE.OnClientEvent:Connect(function(msg)
	if not alive() or type(msg) ~= "string" then return end
	if msg:find("escap") or msg:find("Missed") or msg:find("broke free") then st.missed += 1 end
	st.lastNote = msg:sub(1, 80)
	if msg:find("Dawn", 1, true) then st.dawnAt = os.clock() end   -- new creatures (and Shrouded) roll at dawn
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
		st.annTick = (st.annTick or 0) + 1
		st.shroud = ("เกิดที่ %s · %s"):format(tostring(data.zone or ("โซน " .. data.zoneNum)), os.date("%H:%M:%S"))
	elseif kind == "got" then
		st.shroudKills += 1
		st.shroud = "ได้ Mystery Soul · " .. os.date("%H:%M:%S")
		shroudSeen.zone = nil
	end
end)
-- Remotes.Announce {kind, zoneNum, zone, rarity} = "A <kind> spawned in <zone>!" -- the rare tiers are only hunted
-- after one of these, so the bot doesn't hop around zones where nothing it wants is alive
-- tiers that are never announced but are (nearly) always out: Easy / Hard / Boss, and Rare (one per zone, back 60 s
-- after a kill -- e.g. zone 8 "Secret" Tempest Griffin). These get scouted in person; Chase / Divine wait for the announcement.
local ALWAYS_TIERS = {Easy = true, Hard = true, Boss = true, Rare = true}
local scoutMiss = {}   -- zoneId -> os.clock() of the last visit that found nothing (skip it for 40 s)
local spawnSeen = {}   -- kind -> {zone = zoneNum, at = os.clock(), misses = n}
local announceConn = Remotes:WaitForChild("Announce").OnClientEvent:Connect(function(a)
	if not alive() or type(a) ~= "table" or not a.kind or not tonumber(a.zoneNum) then return end
	spawnSeen[a.kind] = {zone = tonumber(a.zoneNum), at = os.clock(), misses = 0}
	st.annTick = (st.annTick or 0) + 1
	st.lastAnn = ("%s เกิดที่ %s · %s"):format(cname(a.kind), tostring(a.zone or a.zoneNum), os.date("%H:%M:%S"))
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

-- my army = workspace.Followers models with Owner = my UserId; a fainted one has SleepUntil (or Dying) set
local function myArmy()
	local total, awake, near = 0, 0, 0
	local r = hrp()
	local f = workspace:FindFirstChild("Followers")
	for _, m in ipairs(f and f:GetChildren() or {}) do
		if m:GetAttribute("Owner") == plr.UserId then
			total += 1
			if m:GetAttribute("SleepUntil") == nil and m:GetAttribute("Dying") ~= true then
				awake += 1
				if r and (m:GetPivot().Position - r.Position).Magnitude < 45 then near += 1 end
			end
		end
	end
	return total, awake, near
end
local function armyReady()
	local total, awake, near = myArmy()
	return total > 0 and awake >= math.ceil(total * 0.6) and near >= math.max(1, math.ceil(awake * 0.6)), total, awake, near
end
-- stand at `spot` until the army is with me and awake (fainted ones wake after ~10 s)
local function waitArmy(spot, look, maxWait, why)
	local t0 = os.clock()
	while alive() and e.farm and os.clock() - t0 < maxWait do
		local ok, total, awake, near = armyReady()
		if ok then return true end
		st.status = ("%s · รอ army: ตื่น %d/%d · มาถึง %d"):format(why, awake, total, near)
		if spot then warp(spot, look) end
		task.wait(0.5)
	end
	return armyReady()
end

-- Tested 2026-11-21 (Jungle Raptor, 14M HP): wild creatures never attack someone just standing near them, and the
-- army never attacks on its own -- my punch starts the fight, then whoever is close gets hit (the player has 100 HP).
-- So: stand 30 studs off with the army gathered, hop in, punch once, hop straight back; the army finishes it (~1 s).
-- Punch again only when its HP stops dropping (the army lost interest). Got hit anyway -> back off further.
st.fightLog = {}
local function logFight(m, why)
	local z = ZONE_BY_ID[m:GetAttribute("Zone")]
	table.insert(st.fightLog, 1, ("%s %s (%s, %s) ← %s"):format(os.date("%H:%M"), m:GetAttribute("DisplayName") or m.Name,
		z and ("โซน " .. z.index) or tostring(m:GetAttribute("Zone")), tostring(m:GetAttribute("Tier")), why))
	while #st.fightLog > 6 do table.remove(st.fightLog) end
end
local function fight(m)
	local name = m:GetAttribute("DisplayName") or m.Name
	if m:GetAttribute("Kind") == "Shroud" or CS:HasTag(m, "Shroud") then name = "Shrouded ???" end
	local zid = m:GetAttribute("Zone")
	local boss = m:GetAttribute("Tier") == "Boss"
	local limit = boss and 240 or 90
	local function dead() return shroudDead(m) or (m:GetAttribute("HP") or 1) <= 0 end
	local r0 = hrp()
	local dir = r0 and (r0.Position - m:GetPivot().Position) * Vector3.new(1, 0, 1)
	dir = (dir and dir.Magnitude > 1) and dir.Unit or Vector3.new(0, 0, 1)
	local function geom()
		local pp = m.PrimaryPart
		local cf = m:GetPivot()
		local size = pp and pp.Size or select(2, m:GetBoundingBox())
		local half = math.min(math.max(size.X, size.Z) / 2, 30)
		return cf.Position, half
	end
	local function standAt(d)
		if not m.Parent then return end
		local at, half = geom()
		local p = at + dir * (half + d)
		warp(groundAt(Vector3.new(p.X, at.Y, p.Z)), at)
	end
	local zoneName = ZONE_BY_ID[zid] and ZONE_BY_ID[zid].name or tostring(zid)
	local function show(hp)
		st.target = ("%s (%s) · HP %s / %s"):format(name, zoneName, fmt(hp), fmt(m:GetAttribute("MaxHP")))
	end

	-- 1. stage: 22 studs past its edge (~30 from the centre) and let the army gather around me
	local gap = 22
	standAt(gap)
	local t0 = os.clock()
	while alive() and e.farm and not dead() and os.clock() - t0 < 12 do
		local ok, total, awake, near = armyReady()
		if ok then break end
		st.status = ("เจอ %s · ยืนห่าง รอ army: ตื่น %d/%d · อยู่ใกล้ %d"):format(name, awake, total, near)
		standAt(gap)
		task.wait(0.4)
	end
	local _, total0, awake0 = armyReady()
	if awake0 == 0 then st.status = name .. ": army สลบหมด / ยังไม่มา → ไว้ทีหลัง"; return end

	local h = hum()
	local lastHP, lastDrop, lastPunch = m:GetAttribute("HP"), 0, 0
	t0 = os.clock()
	while alive() and e.farm and not dead() do
		if busyHands() then st.status = "พัก: " .. busyHands(); return end
		local o = m:GetAttribute("OwnerId")
		if o and o ~= plr.UserId then st.status = name .. " มีคนอื่นตีอยู่ → หาตัวใหม่"; return end
		local hp = m:GetAttribute("HP") or 0
		if lastHP and hp < lastHP then lastHP, lastDrop = hp, os.clock() end
		show(hp)
		h = hum()
		if h and h.Health < h.MaxHealth then gap = math.min(gap + 15, 60) end   -- something reached me: stand further off
		local _, total, awake = armyReady()
		if awake < math.ceil(total * 0.4) then
			st.status = ("%s · army สลบ %d/%d → ถอยรอให้ตื่น"):format(name, total - awake, total)
			standAt(gap + 20)
			task.wait(0.5)
		elseif os.clock() - lastDrop > 3 and os.clock() - lastPunch > 1 then
			-- 2. hop in, punch once, hop back
			standAt(2)
			task.wait(0.3)
			pcall(Punch.FireServer, Punch, m)
			lastPunch = os.clock()
			task.wait(0.3)
			standAt(gap)
			st.status = ("ต่อย %s แล้วถอย · army ตื่น %d/%d"):format(name, awake, total)
		else
			standAt(gap)
			st.status = ("army กำลังตี %s · ยืนห่าง %d · army ตื่น %d/%d"):format(name, gap, awake, total)
		end
		if os.clock() - t0 > limit then st.status = name .. " ตีนานเกิน " .. limit .. " วิ → ข้าม"; return end
		if lastDrop > 0 and os.clock() - lastDrop > 25 then st.status = name .. " เลือดไม่ลด 25 วิ → ข้าม"; return end
		task.wait(0.25)
	end
	if dead() then
		st.kills += 1
		st.status = name .. " ตายแล้ว → รอ soul แล้วเข้าไปจับ"
		local t1 = os.clock()
		while os.clock() - t1 < 2 and not next(pending) do task.wait(0.1) end   -- the soul arrives ~0.3 s after the kill
		grabSouls()
		task.wait(0.5)
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
		streamAround(CAMP, 3)
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

-- Auto Drum: stand at my plot's WarDrum (Camp.Plots.Plot<n>.WarDrum, within ~7 studs of its Skin while Home) to
-- train Command. Only while there is nothing picked to hunt; leaving the drum is just warping away.
local lastDrumWarp = 0
local function drumJob()
	if plr:GetAttribute("Drumming") then st.drum = "กำลังตีกลอง"; return end
	if os.clock() - lastDrumWarp < 4 then return end
	lastDrumWarp = os.clock()
	local plots = workspace:FindFirstChild("Camp") and workspace.Camp:FindFirstChild("Plots")
	local plot = plots and plots:FindFirstChild("Plot" .. tostring(plr:GetAttribute("Plot")))
	local drum = plot and plot:FindFirstChild("WarDrum")
	if not drum then
		warpFar(CAMP)
		task.wait(0.5)
		plot = plots and plots:FindFirstChild("Plot" .. tostring(plr:GetAttribute("Plot")))
		drum = plot and plot:FindFirstChild("WarDrum")
		if not drum then st.drum = "หากลองไม่เจอ"; return end
	end
	local skin = drum:FindFirstChild("Skin") or drum.PrimaryPart
	local at = skin and skin.Position or drum:GetPivot().Position
	warp(groundAt(at + Vector3.new(4, 0, 0)), at)
	st.drum = "วาร์ปไปตีกลอง"
end
local function waitAnnounce(sec)   -- idle until `sec` passes or the game announces a spawn
	local a0, t0 = st.annTick, os.clock()
	while alive() and os.clock() - t0 < sec and st.annTick == a0 do task.wait(0.05) end
end


-- ------------------------------------------------------------------ harvest boss (event)
-- Camp.HarvestEvent.Gate: walking through Swirl.Body (a 16x22 portal plane) takes you to Camp.HarvestArena
-- (ArrivalCF ~ 3000,0,2690, boss at BossCF ~ 3000,0,2590). The gate's "Timer" label reads "NEXT IN mm:ss" while closed.
-- Every follower deals a flat 100 DPS (Config.Events.Harvest.Boss.FollowerDPS), fight lasts 180 s, reward 1000 Kernels.
-- Remotes.HarvestBossFX: "slam"(center, radius, delay) and "volley"(?, landing points, radius, flight, stagger) are
-- warned before they hit -> the fight loop keeps the character out of every warned circle.
local HBCfg = (Config.Events and Config.Events.Harvest and Config.Events.Harvest.Boss) or {}
local HB_KIND = HBCfg.Kind or "CornucopiaColossus"
local danger = {}   -- {pos, r, untilT}
local hbFxConn = Remotes:WaitForChild("HarvestBossFX").OnClientEvent:Connect(function(kind, a1, a2, a3, a4, a5)
	if not alive() then return end
	local t = os.clock()
	if kind == "slam" and typeof(a1) == "Vector3" then
		danger[#danger + 1] = {pos = a1, r = (tonumber(a2) or 34) + 8, untilT = t + (tonumber(a3) or 2) + 0.6}
	elseif kind == "volley" and type(a2) == "table" then
		local flight, stagger = tonumber(a4) or 2.4, tonumber(a5) or 0
		for i, pos in ipairs(a2) do
			if typeof(pos) == "Vector3" then
				danger[#danger + 1] = {pos = pos, r = (tonumber(a3) or 10) + 6, untilT = t + flight + (i - 1) * stagger + 0.6}
			end
		end
	end
	st.hbFx = kind .. " · " .. os.date("%H:%M:%S")
end)
local function inDanger(pos)
	local t = os.clock()
	for i = #danger, 1, -1 do
		local d = danger[i]
		if d.untilT < t then
			table.remove(danger, i)
		else
			local v = pos - d.pos
			if Vector3.new(v.X, 0, v.Z).Magnitude < d.r then return true end
		end
	end
	return false
end
local function hbGate()
	local ev = workspace:FindFirstChild("Camp") and workspace.Camp:FindFirstChild("HarvestEvent")
	local gate = ev and ev:FindFirstChild("Gate")
	local body = gate and gate:FindFirstChild("Swirl") and gate.Swirl:FindFirstChild("Body")
	local timer
	for _, l in ipairs(gate and gate:GetDescendants() or {}) do
		if l:IsA("TextLabel") and l.Name == "Timer" then timer = l.Text end
	end
	return body, timer
end
local function hbBoss()
	for _, m in ipairs(CS:GetTagged("WildCreature")) do
		if m:GetAttribute("Kind") == HB_KIND and m.Parent and not m:GetAttribute("Dying") and (m:GetAttribute("HP") or 1) > 0 then return m end
	end
	local f = workspace:FindFirstChild("WildCreatures")
	for _, m in ipairs(f and f:GetChildren() or {}) do
		if m:GetAttribute("Kind") == HB_KIND and not m:GetAttribute("Dying") and (m:GetAttribute("HP") or 1) > 0 then return m end
	end
end
local function inArena()
	local r = hrp()
	local a = workspace:FindFirstChild("Camp") and workspace.Camp:FindFirstChild("HarvestArena")
	local bcf = a and a:GetAttribute("BossCF")
	local center = typeof(bcf) == "CFrame" and bcf.Position or Vector3.new(3000, 0, 2590)
	return r and (Vector3.new(r.Position.X, 0, r.Position.Z) - Vector3.new(center.X, 0, center.Z)).Magnitude < 200, center
end
local GATE_AT = Vector3.new(3145, 12, 214)
local lastGatePeek = 0
local function hbOpen()
	local body, timer = hbGate()
	if not body and os.clock() - lastGatePeek > 20 then   -- out hunting: stream the gate in to read its timer
		lastGatePeek = os.clock()
		streamAround(GATE_AT, 2)
		body, timer = hbGate()
	end
	if not body then return false, "ยังไม่เห็นประตู (อยู่ไกลแคมป์)" end
	-- seen 2026-11-21: "NEXT IN mm:ss" (about every 30 min) -> "FIGHTING NOW!" for the ~2 min fight. Walking in while it
	-- still says NEXT IN gets you bounced back out, and a label that hasn't loaded yet reads "" -- only FIGHT means open.
	local up = tostring(timer or ""):upper()
	if up:find("FIGHT", 1, true) then return true, timer end
	local m, sec = up:match("NEXT IN (%d+):(%d+)")
	if m and tonumber(m) * 60 + tonumber(sec) <= 2 then return true, timer end
	return false, (timer and timer ~= "") and timer or "อ่านป้ายไม่ได้"
end
-- walk through the portal plane: start on one side, step across in small hops so the server sees the crossing
local function hbEnter()
	local body = hbGate()
	if not body then warpFar(CAMP); task.wait(0.5); body = hbGate() end
	if not body then return false end
	for _, dir in ipairs({1, -1}) do
		local look = body.CFrame.LookVector * dir
		local base = body.Position - Vector3.new(0, body.Size.Y / 2 - 3, 0)
		for k = 0, 8 do
			warp(base - look * 8 + look * (k * 2), base + look * 30)
			task.wait(0.06)
		end
		local t0 = os.clock()
		while os.clock() - t0 < 3 do
			if inArena() then return true end
			task.wait(0.2)
		end
	end
	return inArena()
end
local function hbFight(m)
	local name = "Harvest Boss"
	local t0 = os.clock()
	while alive() and e.hboss and m.Parent and not m:GetAttribute("Dying") and (m:GetAttribute("HP") or 1) > 0 and os.clock() - t0 < 200 do
		local cf = m:GetPivot()
		local pp = m.PrimaryPart
		local size = pp and pp.Size or Vector3.new(20, 20, 20)
		local reach = (Config.Punch.Range or 11) + size.X / 2 + size.Y / 2 - 2
		local r0 = math.min(math.max(size.X, size.Z) / 2 + 6, reach)
		-- pick a spot on a ring around the boss that is outside every warned circle (prefer the closest ring)
		local spot
		for _, radius in ipairs({r0, r0 + 15, r0 + 35, r0 + 60}) do
			for k = 0, 15 do
				local a = k / 16 * math.pi * 2
				local cand = cf.Position + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
				if not inDanger(cand) then spot = cand; break end
			end
			if spot then break end
		end
		spot = groundAt(spot or (cf.Position + Vector3.new(0, 0, r0 + 80)))
		local r = hrp()
		if r and (inDanger(r.Position) or (r.Position - spot).Magnitude > 6) then warp(spot, cf.Position) end
		if r and (r.Position - cf.Position).Magnitude <= reach + 4 then pcall(Punch.FireServer, Punch, m) end
		local _, total, awake = armyReady()
		st.hb = ("กำลังตี %s · HP %s / %s · army ตื่น %d/%d · หลบ %d วง"):format(name, fmt(m:GetAttribute("HP")), fmt(m:GetAttribute("MaxHP")), awake, total, #danger)
		task.wait(0.3)
	end
	if not m.Parent or m:GetAttribute("Dying") or (m:GetAttribute("HP") or 1) <= 0 then
		st.hbWins = (st.hbWins or 0) + 1
		st.hb = "ชนะ Harvest Boss · " .. os.date("%H:%M:%S")
	end
end
-- returns true while it owns the character
local hbTried = 0
local function harvestJob()
	if not e.hboss then st.hb = "ปิดอยู่"; return false end
	local here = inArena()
	local boss = hbBoss()
	if here and boss then hbFight(boss); return true end
	local open, timer = hbOpen()
	if not open then
		st.hb = "ปิด · " .. tostring(timer)
		return false
	end
	if here then st.hb = "อยู่ในสนาม รอบอสโผล่"; task.wait(0.5); return os.clock() - hbTried < 20 end
	if os.clock() - hbTried < 15 then return false end   -- a failed entry waits a bit before the next try
	hbTried = os.clock()
	st.hb = "บอสเปิดแล้ว (" .. tostring(timer) .. ") → เข้าประตู"
	if hbEnter() then
		st.hb = "เข้าสนามแล้ว"
		local t0 = os.clock()
		while os.clock() - t0 < 8 and not hbBoss() do task.wait(0.2) end
		boss = hbBoss()
		if boss then hbFight(boss) end
		return true
	end
	st.hb = "เข้าประตูไม่สำเร็จ (" .. tostring(timer) .. ") → ลองใหม่อีก 15 วิ"
	return false
end

local scoutIdx, zoneCursor = {}, 0   -- scoutIdx[zoneId] = next spawn spot to stand on in that zone
local function farmStep()
	if next(pending) and not busyHands() then grabSouls() end   -- souls from kills the army finished while I was elsewhere
	if e.hboss and not busyHands() and harvestJob() then st.status = "Harvest Boss: " .. tostring(st.hb); return end
	if not e.farm then
		st.status = e.drum and "Auto Farm ปิด · ตีกลองอย่างเดียว" or "ปิดอยู่"; st.target = "-"
		if e.drum and not busyHands() then drumJob() end
		return
	end
	local why = busyHands()
	if why then st.status = "พัก: " .. why; return end
	local tmap = targetMap()
	local zoneList = {}
	for _, z in ipairs(ZONES) do
		for _, zid in pairs(tmap) do if zid == z.id then zoneList[#zoneList + 1] = z; break end end
	end
	learnSpawns()
	local sh = findShroud()
	if sh then logFight(sh, "Shrouded"); return fight(sh) end
	if penJob() then return end

	local m = findTarget(tmap)
	if m then
		if spawnSeen[m:GetAttribute("Kind")] then spawnSeen[m:GetAttribute("Kind")] = nil end
		logFight(m, "ตัวที่เลือก (" .. tostring(KIND_RAR[m:GetAttribute("Kind")] or "?") .. ")")
		return fight(m)
	end

	-- where to look: an announced Shrouded, then announced picks, then picked zones whose picks are always out
	local goZone, why
	local shZone = e.shroud and shroudSeen.zone and os.clock() - shroudSeen.at < 180 and ZONES[shroudSeen.zone]
	if shZone and unlocked(shZone) then goZone, why = shZone, "Shrouded" end
	if not goZone then
		for kind, info in pairs(spawnSeen) do
			local z = ZONES[info.zone]
			if os.clock() - info.at > 600 or info.misses >= 3 then
				spawnSeen[kind] = nil
			elseif z and tmap[kind] == z.id and unlocked(z) then
				goZone, why = z, kind
				break
			end
		end
	end
	if not goZone then
		local common = {}
		for _, z in ipairs(zoneList) do
			if unlocked(z) then
				for kind, zid in pairs(tmap) do
					if zid == z.id and ALWAYS_TIERS[KIND_TIER[kind]] and os.clock() - (scoutMiss[z.id] or -99) > 40 then common[#common + 1] = z; break end
				end
			end
		end
		if #common == 0 then
			st.waiting = #zoneList > 0 or e.shroud
			if #zoneList == 0 then
				st.status = e.shroud and "รอ Shrouded เกิด (ยังไม่ได้เลือกตัวอื่น)" or "ยังไม่ได้เลือกตัวที่จะจับ"
			else
				st.status = "รอตัวที่เลือกเกิด: เกมประกาศ → วาร์ปทันที · ส่องโซนจากที่เดิม (ไม่ย้ายตัว): " .. tostring(st.peek or "-")
			end
			st.target = "ล่าสุดที่เกมประกาศ: " .. tostring(st.lastAnn or "-")
			if e.drum then drumJob(); st.status ..= " · ระหว่างรอ: " .. tostring(st.drum) end
			waitAnnounce(1)
			return
		end
		if zoneCursor < 1 or zoneCursor > #common then zoneCursor = 1 end
		goZone, why = common[zoneCursor], nil
		zoneCursor += 1
	end

	st.waiting = false
	local spots = anchorsOf(goZone.id)
	if #spots == 0 then spots = {Vector3.new(0, 20, (goZone.zmin + goZone.zmax) / 2)} end
	-- one spot already streams the whole zone (radius 1024)
	scoutIdx[goZone.id] = (scoutIdx[goZone.id] or 0) % #spots + 1
	local si = scoutIdx[goZone.id]
	if why == "Shrouded" then
		st.status = ("Shrouded เกิดที่ %s → วาร์ปไปหา"):format(goZone.name)
	elseif why then
		st.status = ("%s เกิดที่ %s → วาร์ปไปหา"):format(cname(why), goZone.name)
	else
		st.status = ("หาเป้าใน %s (จุด %d/%d)"):format(goZone.name, si, #spots)
	end
	st.target = "ยังไม่เจอ"
	warpFar(spots[si])
	local t0 = os.clock()
	while alive() and e.farm and os.clock() - t0 < 3.5 do
		task.wait(0.5)
		if findTarget(tmap) or findShroud() then return end
	end
	if not why then scoutMiss[goZone.id] = os.clock() end
	-- announced one not found from here: try the other spots a couple of times, then forget it (caught by someone else)
	if why and why ~= "Shrouded" and spawnSeen[why] then spawnSeen[why].misses += 1 end
end
loopEvery("Auto Farm", 0.1, 300, farmStep)

-- not every rare spawn is announced: while waiting, ask the server to stream one spawn spot of a picked zone at a
-- time (the character stays put). A picked creature that streams in is seen by findTarget and the farm warps to it.
local peekZone, peekSpot = 0, {}
loopEvery("Peek", 0.5, 30, function()
	if not (e.farm and st.waiting) then return end
	local tmap = targetMap()
	local zl = {}
	-- a Shrouded isn't always announced either: with the Shrouded toggle on, every unlocked zone gets peeked;
	-- for 90 s after dawn (when it rolls) the picked zones step aside so the sweep goes round faster
	local dawn = e.shroud and st.dawnAt and os.clock() - st.dawnAt < 90
	for _, z in ipairs(ZONES) do
		if unlocked(z) and not (z.secret and not unlocked(z)) then
			local picked = false
			for _, zid in pairs(tmap) do if zid == z.id then picked = true; break end end
			if (picked and not dawn) or e.shroud then zl[#zl + 1] = z end
		end
	end
	if #zl == 0 then return end
	peekZone = peekZone % #zl + 1
	local z = zl[peekZone]
	local spots = anchorsOf(z.id)
	if #spots == 0 then return end
	peekSpot[z.id] = (peekSpot[z.id] or 0) % #spots + 1
	st.peek = ("%s จุด %d/%d%s"):format(z.name, peekSpot[z.id], #spots, dawn and " (เช้าแล้ว: กวาดหา Shrouded)" or "")
	streamAround(spots[peekSpot[z.id]], dawn and 2 or 4)
end)

-- leg-lock guard: BossIntroClient / EntranceClient set WalkSpeed, JumpPower, JumpHeight = 0 for a cutscene and restore
-- them afterwards; warping out mid-cutscene can leave them at 0 (2026-11-21: "เดินไม่ได้โดนล็อกขา")
task.spawn(function()
	local zeroSince = nil
	local SP = game:GetService("StarterPlayer")
	while alive() do
		local h = hum()
		if h and h.Health > 0 and h.WalkSpeed == 0 then
			zeroSince = zeroSince or os.clock()
			if os.clock() - zeroSince > 10 then
				pcall(function()
					h.WalkSpeed = plr:GetAttribute("BaseWalkSpeed") or SP.CharacterWalkSpeed
					h.JumpPower = SP.CharacterJumpPower
					h.JumpHeight = SP.CharacterJumpHeight
				end)
				st.wd = "ปลดล็อกขาให้ (cutscene ค้าง) · " .. os.date("%H:%M:%S")
				zeroSince = nil
			end
		else
			zeroSince = nil
		end
		task.wait(1)
	end
end)

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
	Event = TG:Tab({Name = "Event", Image = "rbxassetid://10723346959"}),
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
L:Label({Text = "วาร์ปไปหาตัวที่เลือก → ตี (army ช่วยตี) → ตายแล้วกด summon จับให้\nที่เลือกเซฟอัตโนมัติ · ไปทีละโซนที่มีเป้า"})

local zoneOpts, zoneByLabel, zoneLabel = {}, {}, {}
for _, z in ipairs(ZONES) do
	if not z.secret or unlocked(z) then
		local label = ("%d · %s%s"):format(z.index, z.name, unlocked(z) and "" or " (ยังล็อก)")
		zoneOpts[#zoneOpts + 1] = label
		zoneByLabel[label] = z
		zoneLabel[z.id] = label
	end
end

local selLbl
local zoneUI = {}   -- zoneId -> {rar = dropdown, kind = dropdown, byLabel = {label -> kind}, rebuilding = bool}

local function refreshSelLabel()
	if not selLbl then return end
	local lines = {}
	for _, z in ipairs(ZONES) do
		if table.find(e.zones, z.id) then
			local s = zsel(z.id)
			if #s.rars == 0 then
				lines[#lines + 1] = ("%d %s: ยังไม่ได้เลือก rarity"):format(z.index, z.name)
			else
				local names = {}
				for _, k in ipairs(zoneTargets(z)) do names[#names + 1] = cname(k) end
				lines[#lines + 1] = ("%d %s: %s"):format(z.index, z.name, table.concat(names, ", "))
			end
		end
	end
	selLbl:UpdateName(#lines > 0 and table.concat(lines, "\n") or "ยังไม่ได้เลือกโซน")
end

-- one zone's creature list = creatures of its picked rarities; picks outside them are dropped
local function rebuildKinds(z)
	local ui = zoneUI[z.id]
	if not ui then return end
	local s = zsel(z.id)
	local opts, keep, def = {}, {}, {}
	ui.byLabel = {}
	for _, tier in ipairs(TIERS) do
		local rar = z.tiers[tier] and rarityOf(z, tier)
		if rar and table.find(s.rars, rar) then
			for _, k in ipairs(z.tiers[tier]) do
				local label = ("%s · %s"):format(cname(k), rar)
				opts[#opts + 1] = label
				ui.byLabel[label] = k
				if table.find(s.kinds, k) then keep[#keep + 1] = k; def[#def + 1] = label end
			end
		end
	end
	s.kinds = keep
	ui.rebuilding = true
	pcall(function() ui.kind:ClearOptions() end)
	if #opts > 0 then pcall(function() ui.kind:InsertOptions(opts) end) end
	pcall(function() ui.kind:UpdateSelection(def) end)
	ui.rebuilding = false
	sv()
	refreshSelLabel()
end

local function showZones()
	for _, z in ipairs(ZONES) do
		local ui = zoneUI[z.id]
		if ui then
			local on = table.find(e.zones, z.id) ~= nil
			pcall(function() ui.rar:SetVisibility(on) end)
			pcall(function() ui.kind:SetVisibility(on) end)
		end
	end
	refreshSelLabel()
end

L:Header({Text = "เลือกเป้า"})
local zoneDef = {}
for _, zid in ipairs(e.zones) do if zoneLabel[zid] then zoneDef[#zoneDef + 1] = zoneLabel[zid] end end
L:Dropdown({Name = "โซน (เลือกได้หลายโซน)", Multi = true, Required = false, Options = zoneOpts, Default = zoneDef,
	Callback = function(v)
		local zs = {}
		for _, label in ipairs(picked(v)) do if zoneByLabel[label] then zs[#zs + 1] = zoneByLabel[label].id end end
		table.sort(zs, function(a, b) return ZONE_BY_ID[a].index < ZONE_BY_ID[b].index end)
		e.zones = zs; sv()
		task.defer(showZones)
	end}, "SPAZone")
L:Label({Text = "เลือกโซนแล้ว แต่ละโซนจะมีช่อง Rarity + ตัวที่จะจับ แยกของตัวเอง\nตัวที่จะจับ ไม่เลือก = จับทุกตัวใน rarity นั้น"})

-- every zone gets its own Rarity + creature dropdowns, shown only while the zone is picked
for _, z in ipairs(ZONES) do
	if zoneLabel[z.id] then
		local s = zsel(z.id)
		local ui = {byLabel = {}, rebuilding = false}
		zoneUI[z.id] = ui
		local rarOpts, rarDef = {}, {}
		for _, tier in ipairs(TIERS) do
			if z.tiers[tier] then
				local rar = rarityOf(z, tier)
				rarOpts[#rarOpts + 1] = rar
				if table.find(s.rars, rar) then rarDef[#rarDef + 1] = rar end
			end
		end
		ui.rar = L:Dropdown({Name = ("โซน %d · Rarity"):format(z.index), Multi = true, Required = false, Options = rarOpts, Default = rarDef,
			Callback = function(v)
				local rs = {}
				for _, label in ipairs(picked(v)) do if table.find(rarOpts, label) then rs[#rs + 1] = label end end
				zsel(z.id).rars = rs
				task.defer(rebuildKinds, z)
			end}, "SPARar" .. z.id)
		ui.kind = L:Dropdown({Name = ("└ โซน %d · ตัวที่จะจับ (ไม่เลือก = ทุกตัว)"):format(z.index), Multi = true, Required = false, Options = {}, Default = {},
			Callback = function(v)
				if ui.rebuilding then return end
				local ks = {}
				for _, label in ipairs(picked(v)) do if ui.byLabel[label] then ks[#ks + 1] = ui.byLabel[label] end end
				zsel(z.id).kinds = ks; sv()
				refreshSelLabel()
			end}, "SPAKind" .. z.id)
	end
end
L:Header({Text = "ตัวเลือก"})
local sizeOpts = {}
for i, n in ipairs(SIZE_NAMES) do sizeOpts[i] = i == 1 and "ทุกขนาด" or (n .. " ขึ้นไป") end
L:Dropdown({Name = "ขนาดขั้นต่ำ", Multi = false, Required = true, Options = sizeOpts, Default = math.clamp(tonumber(e.minSize) or 1, 1, #sizeOpts),
	Callback = function(v)
		local label = type(v) == "table" and picked(v)[1] or v
		local i = table.find(sizeOpts, label)
		if i then e.minSize = i; sv() end
	end}, "SPASize")
L:Header({Text = "Auto Drum"})
L:Toggle({Name = "Auto Drum (ไม่มีตัวให้ล่า → ไปตีกลองเก็บ Command)", Default = e.drum, Callback = function(v) e.drum = v; sv() end}, "SPADrum")
L:Label({Text = "มีตัวที่เลือกเกิด / Shrouded เกิด → ทิ้งกลองไปล่าก่อน แล้วกลับมาตีต่อ"})
L:Header({Text = "Shrouded ???"})
L:Toggle({Name = "ล่า Shrouded (เกิดสุ่มทุกโซน)", Default = e.shroud, Callback = function(v) e.shroud = v; sv() end}, "SPAShroud")
L:Toggle({Name = "└ เอา Mystery Soul ไปวางฟักที่คอก + เปิดเมื่อฟักเสร็จ", Default = e.shroudPen, Callback = function(v) e.shroudPen = v; sv() end}, "SPAShroudPen")
L:Label({Text = "เกมประกาศเมื่อ Shrouded เกิด → วาร์ปไปโซนนั้นตีก่อนตัวอื่น (ต้องเปิด Auto Farm)\nตายแล้วได้ Mystery Soul → กลับแคมป์วางในคอก ฟัก 15-60 นาที → เปิดได้ Rare / Chase / Divine"})
L:Toggle({Name = "จับ soul ตัวอื่นที่ตายด้วย (army ตีโดน)", Default = e.catchOthers, Callback = function(v) e.catchOthers = v; sv() end}, "SPAOthers")
L:Toggle({Name = "หยุดบอทตอนฉันกดเดินเอง", Default = e.pauseOnMove, Callback = function(v) e.pauseOnMove = v; sv() end}, "SPAPause")
-- Anti-AFK / Auto Reconnect live on the Settings tab only (user, 2026-11-21: duplicate on the main tab was noise)
local guardTabs, afkT, recT = false, {}, {}
local function syncSet(key, toggles, v)
	if guardTabs then return end
	e[key] = v; sv()
	guardTabs = true
	for _, t in ipairs(toggles) do pcall(function() if t:GetState() ~= v then t:UpdateState(v) end end) end
	guardTabs = false
end

local R = Tabs.Main:Section({Side = "Right"})
R:Header({Text = "สถานะ"})
local stLbl = R:Label({Text = "-"})
R:Header({Text = "เป้าที่เลือกไว้ (ทุกโซน)"})
selLbl = R:Label({Text = "-"})
R:Header({Text = "บอทไปตีอะไร (ล่าสุดก่อน)"})
local fightLbl = R:Label({Text = "-"})
R:Header({Text = "จับได้รอบนี้"})
local catchLbl = R:Label({Text = "-"})

local EV = Tabs.Event:Section({Side = "Left"})
EV:Header({Text = "🦃 Harvest Boss"})
EV:Toggle({Name = "Auto Harvest Boss", Default = e.hboss, Callback = function(v) e.hboss = v; sv() end}, "SPAHBoss")
EV:Label({Text = "ประตู HARVEST BOSS ในแคมป์เปิดเมื่อไหร่ → ทิ้งทุกอย่างเข้าไปตี (ล่าสัตว์ / ตีกลองไว้ก่อน)\nบอสเตือนทุบพื้น / ปาผลไม้ → ยืนนอกวงเตือนเสมอ · ชนะได้ 1,000 Kernels"})
local EVR = Tabs.Event:Section({Side = "Right"})
EVR:Header({Text = "สถานะ"})
local hbLbl = EVR:Label({Text = "-"})

local S = Tabs.Settings:Section({Side = "Left"})
S:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() Win:SetState(not Win:GetState()) end) end}, "SPAToggleUI")
S:Header({Text = "กันหลุด"})
afkT[#afkT + 1] = S:Toggle({Name = "Anti-AFK (กันโดนเตะตอนยืนนิ่ง 20 นาที)", Default = e.antiAfk, Callback = function(v) syncSet("antiAfk", afkT, v) end}, "SPAAntiAfk")
recT[#recT + 1] = S:Toggle({Name = "Auto Reconnect (หลุด / โดนเตะ → เข้าเกมใหม่เอง)", Default = e.reconnect, Callback = function(v) syncSet("reconnect", recT, v) end}, "SPAReconnect")
S:Label({Text = "เข้าเกมใหม่แล้วสคริปต์โหลดเองผ่าน loader พร้อมค่าที่ตั้งไว้"})
S:Label({Text = "ตั้งค่าเซฟที่: " .. SF})

task.defer(function()
	for _, z in ipairs(ZONES) do if zoneUI[z.id] then rebuildKinds(z) end end
	showZones()
end)

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
				"เกมประกาศล่าสุด: " .. tostring(st.lastAnn or "-"),
				"แจ้งเตือนเกม: " .. tostring(st.lastNote or "-"),
				"Watchdog: " .. st.wd,
				"Error: " .. st.err,
			}, "\n"))
			local lines = {}
			for k, n in pairs(caughtBy) do lines[#lines + 1] = ("%s × %d"):format(k, n) end
			table.sort(lines)
			catchLbl:UpdateName(#lines > 0 and table.concat(lines, "\n") or "ยังไม่ได้จับ")
			fightLbl:UpdateName(#st.fightLog > 0 and table.concat(st.fightLog, "\n") or "ยังไม่ได้ตี")
			local _, timer = hbGate()
			hbLbl:UpdateName(table.concat({
				tostring(st.hb or (e.hboss and "รอ" or "ปิดอยู่")),
				"ป้ายประตู: " .. tostring(timer or "-"),
				("ชนะไปแล้ว %d ครั้ง · Kernels %s"):format(st.hbWins or 0, fmt(plr:GetAttribute("Kernels"))),
				"ท่าล่าสุดของบอส: " .. tostring(st.hbFx or "-"),
			}, "\n"))
		end)
		task.wait(0.5)
	end
end)

-- unload: stop every loop and drop the connections when the window closes or the script reloads
task.spawn(function()
	while alive() do task.wait(1) end
	for _, c in ipairs({soulConn, ariseConn, notifyConn, shroudConn, announceConn, hbFxConn, inputConn, idleConn, errConn}) do pcall(function() c:Disconnect() end) end
end)
pcall(function()
	Win.onUnloaded(function() if getgenv().__SPA == G then getgenv().__SPA = G + 1 end end)
end)
