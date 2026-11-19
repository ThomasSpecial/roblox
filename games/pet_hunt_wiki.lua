-- Pet Hunt Party -- local wiki builder.
-- user: "อยากทำเว็บ wiki เวลารันสคริปให้มันรันเว็บวิกิ ดึงข้อมูลเกมมาแสดง ดึงแบบออโต้
-- เวลาเกมอัพเดตก็ให้ดึงมาด้วย" -> picked "ในเครื่องอย่างเดียว".
-- Reads the game's own config modules (ReplicatedStorage.Shared.Config.*) and writes a
-- self-contained wiki into the executor workspace:
--   PetHunt/wiki/index.html  the page (template from GitHub, cached; open it in a browser)
--   PetHunt/wiki/data.mjs    window.PH_DATA = every game table (rebuilt when PlaceVersion changes)
--   PetHunt/wiki/me.mjs      window.PH_ME   = this account's live stats/gear (every minute)
-- Loaded by pet_hunt_party.lua; exposes getgenv().__PHP_WIKI = {build, me, auto, status}.
local DUMPER_VER = 1
local TEMPLATE_URL = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/pet_hunt_wiki.html"
local DIR = "PetHunt/wiki"

local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local plr = game:GetService("Players").LocalPlayer
local C = RS:WaitForChild("Shared"):WaitForChild("Config")

local W = getgenv().__PHP_WIKI or {}
getgenv().__PHP_WIKI = W
W.status = W.status or "ยังไม่ได้สร้าง"

-- ------------------------------------------------------------------ JSON
-- own encoder: the game tables mix array/map keys, hold Color3/Vector3, functions and
-- cycles, which HttpService:JSONEncode refuses. Yields every few thousand nodes.
local function encoder()
	local buf, n, nodes = {}, 0, 0
	local function put(s) n += 1; buf[n] = s end
	local function str(s)
		s = tostring(s):gsub('[%c"\\]', function(c)
			if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n"
			elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t" end
			return ("\\u%04x"):format(c:byte())
		end)
		put('"' .. s .. '"')
	end
	local function num(x)
		if x ~= x or x == math.huge or x == -math.huge then put("null") return end
		if x == math.floor(x) and math.abs(x) < 1e15 then put(("%d"):format(x)) else put(("%.6g"):format(x)) end
	end
	local function storable(v)
		local t = typeof(v)
		return t == "table" or t == "string" or t == "number" or t == "boolean" or t == "Color3" or t == "Vector3"
			or t == "Vector2" or t == "EnumItem" or t == "NumberRange"
	end
	local stack = {}
	local function val(v, depth)
		nodes += 1
		if nodes % 4000 == 0 then task.wait() end
		local t = typeof(v)
		if t == "string" then str(v)
		elseif t == "number" then num(v)
		elseif t == "boolean" then put(v and "true" or "false")
		elseif t == "Color3" then str(("#%02x%02x%02x"):format(math.floor(v.R * 255 + 0.5), math.floor(v.G * 255 + 0.5), math.floor(v.B * 255 + 0.5)))
		elseif t == "Vector3" then put(("[%.2f,%.2f,%.2f]"):format(v.X, v.Y, v.Z))
		elseif t == "Vector2" then put(("[%.2f,%.2f]"):format(v.X, v.Y))
		elseif t == "EnumItem" then str(v.Name)
		elseif t == "NumberRange" then put(("[%g,%g]"):format(v.Min, v.Max))
		elseif t == "table" then
			if stack[v] or depth > 14 then put("null") return end
			stack[v] = true
			local count, maxI = 0, 0
			for k, x in pairs(v) do
				if storable(x) then
					count += 1
					if type(k) == "number" and k >= 1 and k == math.floor(k) then maxI = math.max(maxI, k) else maxI = -1 end
				end
			end
			-- empty -> [] (the page iterates lists; Object.entries/[] lookups are fine on [] too)
			if count == 0 or maxI == count then
				put("[")
				for i = 1, count do
					if i > 1 then put(",") end
					val(v[i], depth + 1)
				end
				put("]")
			else
				put("{")
				local first = true
				for k, x in pairs(v) do
					if storable(x) and (type(k) == "string" or type(k) == "number") then
						if not first then put(",") end
						first = false
						str(k); put(":"); val(x, depth + 1)
					end
				end
				put("}")
			end
			stack[v] = nil
		else
			put("null")
		end
	end
	return function(v) buf, n, nodes = {}, 0, 0; val(v, 0); return table.concat(buf) end
end
local toJSON = encoder()

local function req(name)
	local m = C:FindFirstChild(name)
	if not m then return nil end
	local ok, r = pcall(require, m)
	return ok and type(r) == "table" and r or nil
end
-- copy a module's data fields (no functions), optionally only some keys
local function fields(mod, only)
	if not mod then return nil end
	local out = {}
	if only then
		for _, k in ipairs(only) do out[k] = mod[k] end
	else
		for k, v in pairs(mod) do if type(v) ~= "function" then out[k] = v end end
	end
	return out
end

-- -------------------------------------------------------------- game data
local function collect()
	local D = {}
	local Classes, Stats, EQ, Mon = req("Classes"), req("Stats"), req("Equipment"), req("Monsters")
	local Cards, Pets, Zones, Items = req("Cards"), req("Pets"), req("Zones"), req("Items")
	local okF, F = pcall(require, RS.Shared:FindFirstChild("Formulas"))

	D.meta = {placeVersion = game.PlaceVersion, placeId = game.PlaceId, dumpedAt = os.time(), dumper = DUMPER_VER}

	D.classes = fields(Classes, {"list", "novice", "jobLevel", "lateFrom", "strike", "skillPace", "defs"})
	D.job2 = fields(req("Job2"))
	D.skills = fields(req("Skills"))
	D.leveling = fields(req("Leveling"))
	pcall(function()
		local L = req("Leveling")
		D.leveling.expTable = {}
		for lv = 1, (L.maxLevel or 99) do
			local ok, x = pcall(L.expToNext, lv)
			D.leveling.expTable[lv] = ok and x or 0
		end
	end)

	if Stats then
		D.stats = fields(Stats, {"list", "defs", "startPoints", "perLevel", "max", "caps", "minAttackInterval", "scale", "scaled", "freeResetLevel", "resetGoldPerLevel"})
		-- what one point gives: as an off-stat, and as the class's main (atk) stat
		D.stats.perPoint, D.stats.perPointMain = {}, {}
		for _, s in ipairs(Stats.list or {}) do
			local ok1, a = pcall(Stats.bonus, {[s] = 1}, {atkStat = "__none__"})
			local ok2, b = pcall(Stats.bonus, {[s] = 1}, {atkStat = s}, {[s] = 1})
			D.stats.perPoint[s] = ok1 and a or {}
			D.stats.perPointMain[s] = ok2 and b or {}
		end
	end
	if okF and type(F) == "table" then
		D.formulas = fields(F)
	end

	if EQ then
		D.equipment = fields(EQ, {"defs", "options", "mainOptions", "mainDefault", "rollCaps", "lineNames", "typeNames",
			"types", "refine", "setBonuses", "shopDrop", "shop", "greatFrom", "mainScale", "cardSlots", "cardSlotTypes",
			"slots", "maxPieces", "renamed", "starter"})
		-- roll ranges per item level (the game's own lineOdds/mainOdds text) + roll chance per class pool
		local levels, seen = {}, {}
		for _, def in pairs(EQ.defs or {}) do
			local lv = tonumber(def.level)
			if lv and not seen[lv] then seen[lv] = true; table.insert(levels, lv) end
		end
		table.sort(levels)
		local classes = (Classes and Classes.list) or {}
		local R = {}
		for i, lv in ipairs(levels) do
			if i % 10 == 0 then task.wait() end
			local row = {lines = {}, mains = {}}
			for _, cls in ipairs(classes) do
				local ok, list = pcall(EQ.lineOdds, {level = lv, type = "armor"}, cls)
				if ok and type(list) == "table" then
					for _, l in ipairs(list) do row.lines[l.key] = l.range end
				end
			end
			for _, t in ipairs(EQ.types or {}) do
				local ok, list = pcall(EQ.mainOdds, {level = lv, type = t})
				if ok and type(list) == "table" then
					row.mains[t] = {}
					for _, m in ipairs(list) do row.mains[t][m.key] = {range = m.range, chance = m.chance} end
				end
			end
			R[tostring(lv)] = row
		end
		D.equipment.rangesByLevel = R
		D.equipment.levels = levels
		local pools = {}
		for _, cls in ipairs(classes) do
			local ok, list = pcall(EQ.lineOdds, {level = 99, type = "armor"}, cls)
			if ok and type(list) == "table" then
				pools[cls] = {}
				for _, l in ipairs(list) do pools[cls][l.key] = l.chance end
			end
		end
		D.equipment.lineChanceByClass = pools
		-- refine: bonus per +1 for every piece (refine.perLevel[type](def))
		D.equipment.refinePer = {}
		for id, def in pairs(EQ.defs or {}) do
			local f = EQ.refine and EQ.refine.perLevel and EQ.refine.perLevel[def.type]
			if type(f) == "function" then
				local ok, b = pcall(f, def)
				if ok then D.equipment.refinePer[id] = b end
			end
		end
		-- the shop weapon a field monster drops for each class (level, role) + its chance
		D.equipment.weaponDrop = {}
		if Mon and Mon.defs then
			local done = {}
			for _, m in pairs(Mon.defs) do
				local key = tostring(m.role) .. ":" .. tostring(m.level)
				if (m.role == "normal" or m.role == "elite") and not done[key] then
					done[key] = true
					local row = {}
					for _, cls in ipairs(classes) do
						local ok, gid, ch = pcall(EQ.shopWeaponDrop, m.level, cls, m.role)
						if ok and gid then row[cls] = {gid, ch} end
					end
					D.equipment.weaponDrop[key] = row
				end
			end
		end
	end

	if Mon then
		D.monsters = fields(Mon, {"defs", "list", "openList", "soonList", "fieldGearChance", "dungeonDefs", "bossFights"})
	end
	D.pets = fields(Pets, {"defs", "list", "sets"})
	if Cards then
		D.cards = fields(Cards, {"defs", "dropChance", "rarityDropChance", "rarityOrder", "rarityColors", "slotNames", "betaDropMultiplier", "effects"})
		local ok, m = pcall(Cards.seasonMultiplier)
		D.cards.seasonMultiplier = ok and m or 1
	end
	D.finishes = fields(req("Finishes"))
	D.traits = fields(req("Traits"))
	D.fusion = fields(req("Fusion"))
	D.items = fields(Items, {"defs", "order"})
	if Zones then
		local ok, open = pcall(function() return Zones.openFields end)
		D.zones = {fields = {}, chain = Zones.chain, warpGold = Zones.warpGold}
		for _, f in ipairs(Zones.allFields or Zones.fields or {}) do
			-- gate holds the gate's geometry (~100 KB per field); keep only what a reader needs
			local g = type(f.gate) == "table" and {level = f.gate.level, boss = f.gate.boss, closed = f.gate.closed == true} or nil
			table.insert(D.zones.fields, {id = f.id, name = f.name, levels = f.levels, boss = f.boss, opensAt = f.opensAt,
				comingSoon = f.comingSoon, gate = g})
		end
	end
	D.worldBoss = fields(req("WorldBoss"))
	D.dungeons = fields(req("Dungeons"))
	D.binders = fields(req("Binders"))
	D.tower = fields(req("Tower"))
	D.mounts = fields(req("Mounts"), {"defs", "list"})
	D.companions = fields(req("Companions"))
	D.achievements = fields(req("Achievements"), {"defs", "list", "categories", "tierNames"})
	D.social = fields(req("Social"))
	return D
end

-- ------------------------------------------------------------- this account
local function collectMe()
	local A = plr:GetAttributes()
	local me = {name = plr.Name, display = plr.DisplayName, userId = plr.UserId, at = os.time(), attrs = {}}
	for k, v in pairs(A) do
		if type(v) == "string" and (v:sub(1, 1) == "{" or v:sub(1, 1) == "[") then
			local ok, j = pcall(HS.JSONDecode, HS, v)
			me.attrs[k] = ok and j or v
		elseif type(v) ~= "userdata" then
			me.attrs[k] = v
		end
	end
	pcall(function()
		local GS = require(plr.PlayerScripts.Client.Controllers.GearState)
		local g = GS.get()
		me.equipped, me.cards = {}, g.cards
		for slot, uid in pairs(g.equipped or {}) do
			local p = g.gear and g.gear[uid]
			if p then me.equipped[slot] = {uid = uid, id = p.id, refine = p.refine, main = p.main, options = p.options, locked = p.locked} end
		end
		local n = 0
		for _ in pairs(g.gear or {}) do n += 1 end
		me.bagCount = n
	end)
	return me
end

-- ------------------------------------------------------------------ files
local function ensureDir()
	pcall(function()
		if not isfolder("PetHunt") then makefolder("PetHunt") end
		if not isfolder(DIR) then makefolder(DIR) end
	end)
end

local function template()
	-- dev override (a local copy wins), else GitHub, else the last cached copy
	if isfile(DIR .. "/dev_template.html") then return readfile(DIR .. "/dev_template.html") end
	local ok, html = pcall(function() return game:HttpGet(TEMPLATE_URL .. "?t=" .. os.time()) end)
	if ok and type(html) == "string" and html:find("PH_DATA", 1, true) then
		pcall(writefile, DIR .. "/template_cache.html", html)
		return html
	end
	if isfile(DIR .. "/template_cache.html") then return readfile(DIR .. "/template_cache.html") end
	return nil
end

function W.me()
	ensureDir()
	local ok, err = pcall(function()
		writefile(DIR .. "/me.mjs", "window.PH_ME=" .. toJSON(collectMe()) .. ";")
	end)
	return ok, err
end

function W.page()
	ensureDir()
	local html = template()
	if html then pcall(writefile, DIR .. "/index.html", html) end
	return html ~= nil
end

function W.build(force)
	ensureDir()
	local meta = {}
	pcall(function() meta = HS:JSONDecode(readfile(DIR .. "/meta.json")) end)
	local fresh = meta.placeVersion == game.PlaceVersion and meta.dumper == DUMPER_VER and isfile(DIR .. "/data.mjs")
	if fresh and not force then
		W.status = ("ข้อมูลเป็นของเวอร์ชันเกมนี้แล้ว (v%d)"):format(game.PlaceVersion)
		return false
	end
	W.status = "กำลังดึงข้อมูลเกม..."
	local t0 = os.clock()
	local ok, err = pcall(function()
		local D = collect()
		local js = "window.PH_DATA=" .. toJSON(D) .. ";"
		writefile(DIR .. "/data.mjs", js)
		writefile(DIR .. "/meta.json", HS:JSONEncode({placeVersion = game.PlaceVersion, dumper = DUMPER_VER, at = os.time(), bytes = #js}))
		W.bytes = #js
	end)
	if not ok then
		W.status = "ดึงข้อมูลไม่สำเร็จ: " .. tostring(err)
		warn("[PetHunt wiki] " .. tostring(err))
		return false
	end
	W.status = ("อัปเดตแล้ว: เกมเวอร์ชัน %d (%.1f วินาที, %d KB)"):format(game.PlaceVersion, os.clock() - t0, math.floor((W.bytes or 0) / 1024))
	print("[PetHunt wiki] " .. W.status)
	return true
end

-- run while `alive()` is true: page + data once (data only if the game changed), me.js every 60s
function W.auto(alive, enabled)
	W.gen = (W.gen or 0) + 1
	local gen = W.gen
	task.spawn(function()
		local pageDone = false
		while alive() and W.gen == gen do
			if enabled() then
				if not pageDone then pageDone = W.page() end
				W.build(false)
				W.me()
			end
			for _ = 1, 60 do
				if not alive() or W.gen ~= gen then return end
				task.wait(1)
			end
			-- the game can update under a running server only via a new server, so PlaceVersion is fixed
			-- here; the loop just keeps me.js fresh (and retries the template if GitHub failed)
		end
	end)
end

return W
