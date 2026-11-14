-- Pet Hunt Party RPG (placeId 88452215181406) auto script.
-- UI/structure mirrors hunting_together_boss.lua: MacLib window, RightShift
-- toggles it, every feature defaults OFF, settings persist, autoexec-friendly.
--
-- Drives the game through its OWN client controllers (required live), so actions
-- look exactly like the player's:
--   Auto Farm  -> the game's own auto just STANDS on one spawn and hits whatever
--                 lands next to it. This drives the character with Humanoid:MoveTo
--                 toward the highest-level monster in the current field (+ the
--                 game's auto-attack via TargetController), so it actually roams
--                 to level-appropriate monsters instead of camping low ones.
--   Auto Sell  -> Controllers.GearState.get().gear + RS.Remotes.Gear:FireServer
--                 ("sell", uid): the Bag's SELL call. Never sells locked/equipped/
--                 zero-value. (Bypasses the AutoSellPass gamepass gate.)
--   Auto Collect    -> keeps the game's "autoPickup" setting on.
--   Auto Equip Best -> best owned item per slot via Gear:FireServer("equip", uid).
--   Auto Open Chest -> fireproximityprompt on any "Open Chest" prompt in range.
-- Auto Boss (world boss travel+dodge) still to come.

getgenv().__PHP = (getgenv().__PHP or 0) + 1
local G = getgenv().__PHP
pcall(function() if getgenv().__PHPW then getgenv().__PHPW:Unload() end end)
-- MacLib's :Unload() doesn't reliably Destroy its ScreenGui, and MacLib parents the
-- window inconsistently (sometimes a direct child of gethui, sometimes nested under
-- CoreGui.RobloxGui), so reloads -- and a second executor auto-running the same file
-- -- stacked duplicate windows on screen. DEEP-purge every MacLib window (any
-- ScreenGui carrying both a "Base" and a "Notifications" frame) across every GUI root
-- before building a fresh one. Guarantees exactly one window, however many copies ran.
pcall(function()
	local plr0 = game:GetService("Players").LocalPlayer
	local roots = {
		(gethui and gethui()) or nil,
		game:GetService("CoreGui"),
		plr0 and plr0:FindFirstChildOfClass("PlayerGui"),
	}
	local seen = {}
	for _, root in ipairs(roots) do
		if root then
			for _, g in ipairs(root:GetDescendants()) do
				if not seen[g] and g:IsA("ScreenGui")
					and g:FindFirstChild("Base") and g:FindFirstChild("Notifications") then
					seen[g] = true
					g:Destroy()
				end
			end
		end
	end
end)
local function alive() return getgenv().__PHP == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local plr = Players.LocalPlayer

-- ------------------------------------------------------------------ settings
local SF = "PetHunt/state.json"
local DEFAULTS = {phFarm = false, phSellOn = false, phSellTiers = nil, phSellEvery = 20,
	phCollect = false, phEquip = false, phEquipEvery = 15, phChest = false, phFarmBoss = false,
	phBossOn = false, phBossPick = nil, phFarmPos = nil,
	phWBOn = false, phWBPick = nil, phWBFields = nil, phReconnect = true,
	phBossWaitLv = true,    -- only go fight a field boss once my level >= its level
	phBossUnbeaten = true,  -- skip field bosses already cleared (Beat_<id> attr = field unlocked)
	phAutoWarp = true,      -- walk to a WarpStone and warp to the right field (incl. after a death->town)
	phDodge = true,         -- step out of boss/monster skill telegraphs (BossCast red zones)
	phRide = true,          -- ride the equipped mount on long walks, dismount in attack range
	phNav = true,           -- field walks follow our scanned NavMap (PetHunt/nav/*.json, A*); no map/no path -> old walker
	phStayPut = true,       -- farm spot set: stand exactly on it, only shoot what's in range
	phSellMats = false,     -- sell monster junk (Items type "material") via the shop's SELL LOOT
	phChestWalk = true,     -- Auto Chest on: walk to party chests within 150 studs (server checks range)
	phDgOn = false,         -- Auto Dungeon: clear rooms / boss / open the boss chest while in a run
	phDgReplay = false,     -- back in town after a run -> enter the picked dungeon again (solo / leader)
	phDgAccept = false,     -- party member: auto-join the leader's ready check
	phDgPick = "crypt:hard", phDgUseKeys = true, phDgKeepKeys = 0,
	phAutoRejoin = false,   -- disconnected / kicked -> rejoin this game (then Auto Replay re-enters)
	phDgBuyKeys = false,    -- out of keys -> buy one (250k gold) -- only on, user's explicit request
	phDgGoldFloor = 5,      -- ...but never take gold below this many MILLION
	phFarmBelow = 99, phFarmAbove = 10}  -- farm monsters in [myLv-below, myLv+above]
local e = {}
pcall(function()
	if isfile and isfile(SF) then
		local t = HS:JSONDecode(readfile(SF))
		if type(t) == "table" then e = t end
	end
end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
local function sv()
	pcall(function()
		if makefolder and not isfolder("PetHunt") then makefolder("PetHunt") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

-- ------------------------------------------------------------- game handles
local function controllers()
	local ps = plr:FindFirstChild("PlayerScripts")
	local c = ps and ps:FindFirstChild("Client")
	c = c and c:FindFirstChild("Controllers")
	return c
end

local TC, GearState, Equipment, gearRemote, GSettings, Zones, PW, MR
local function hooks()
	if TC and GearState and Equipment and gearRemote then return true end
	local c = controllers()
	if not c then return false end
	local okC = pcall(function()
		TC = require(c:WaitForChild("TargetController", 5))
		GearState = require(c:WaitForChild("GearState", 5))
	end)
	pcall(function() MR = require(c:WaitForChild("MountRide", 5)) end)
	-- the game's own walker (quest auto-walk / click-to-move): cost-map routes that
	-- prefer roads, avoid the boss Dais, cross between fields over the bridges
	pcall(function() PW = require(c:WaitForChild("PathWalker", 5)) end)
	pcall(function() GSettings = require(c:WaitForChild("Settings", 5)) end)
	pcall(function() Equipment = require(RS.Shared.Config.Equipment) end)
	pcall(function() Zones = require(RS.Shared.Config.Zones) end)
	pcall(function() gearRemote = RS.Remotes.Gear end)
	return okC and TC ~= nil and GearState ~= nil and Equipment ~= nil and gearRemote ~= nil
end

local function myChar()
	local c = plr.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then return c, hum, hrp end
	return nil
end

-- Which field (Zones.fields entry) a position sits in. Fields are laid along X
-- ~380 studs apart, so "same field" = within half that of the field's entrance.
local function fieldAt(pos)
	if not Zones then return nil end
	local ok, f = pcall(Zones.baseAt, pos)
	if ok and type(f) == "table" and f.id then return f end
	return nil
end

-- [NAV BEGIN] generated from pethunt_nav.lua by sync_nav.py -- edit that file, not this block
local Nav = (function()
-- Pet Hunt NavMap core: load grid scanned per field, A* + string-pull, walker.
-- Returns a single table so it costs one local in the main chunk.
local Nav = {}
do
	local HS = game:GetService("HttpService")
	local DIR = "PetHunt/nav/"
	local UP_STEP = 1.6      -- max climb between orthogonal cells (studs)
	local DROP = 18          -- max drop allowed
	local maps = {}
	Nav.maps = maps
	Nav.SCAN_V = 3   -- bump when the scanner changes: older files rescan when their field is next visited

	local function decode(d)
		local W, H = d.w, d.h
		local hts = table.create(W * H)
		local k = 0
		for v in (d.hts .. ","):gmatch("([^,]*),") do
			k += 1
			hts[k] = (v ~= "") and (tonumber(v) / 10 + d.base) or false
		end
		local haz, wall = table.create(W * H), table.create(W * H)
		for i = 1, W * H do
			haz[i] = d.haz:byte(i) == 49
			wall[i] = tonumber(d.wall:sub(i, i), 16) or 0
		end
		-- edge-adjacent cells get a small cost so routes stay off cliff lips
		local edge = table.create(W * H, false)
		for j = 0, H - 1 do
			for i = 0, W - 1 do
				local idx = j * W + i + 1
				local h = hts[idx]
				if h then
					for dj = -1, 1 do
						for di = -1, 1 do
							local ni, nj = i + di, j + dj
							local nh = (ni >= 0 and nj >= 0 and ni < W and nj < H) and hts[nj * W + ni + 1]
							-- off-map / hole beside us, or a wall taller than a step: body would rub it
							if not nh or nh > h + UP_STEP then
								edge[idx] = true
							end
						end
					end
				end
			end
		end
		return { name = d.field, cell = d.cell, x0 = d.x0, z0 = d.z0, w = W, h = H,
			hts = hts, haz = haz, wall = wall, edge = edge, poi = d.poi, bad = {} }
	end

	function Nav.load(field)
		if maps[field] then return maps[field] end
		local path = DIR .. field .. ".json"
		if not (isfile and isfile(path)) then return nil end
		local ok, d = pcall(function() return HS:JSONDecode(readfile(path)) end)
		if not ok or type(d) ~= "table" then return nil end
		local m = decode(d)
		maps[field] = m
		return m
	end

	function Nav.inside(m, p)
		local i = math.floor((p.X - m.x0) / m.cell + 0.5)
		local j = math.floor((p.Z - m.z0) / m.cell + 0.5)
		return i >= 0 and j >= 0 and i < m.w and j < m.h
	end

	function Nav.cellOf(m, p)
		return math.floor((p.X - m.x0) / m.cell + 0.5), math.floor((p.Z - m.z0) / m.cell + 0.5)
	end

	function Nav.worldOf(m, i, j)
		local h = m.hts[j * m.w + i + 1]
		return Vector3.new(m.x0 + i * m.cell, (h or 0) + 3, m.z0 + j * m.cell)
	end

	-- wall bit between (i,j) and neighbour (i+di, j+dj)
	local function walled(m, i, j, di, dj)
		local W = m.w
		if dj < 0 or (dj == 0 and di < 0) then
			i, j, di, dj = i + di, j + dj, -di, -dj
		end
		local bit = (di == 1 and dj == 0) and 1 or (di == 0 and dj == 1) and 2 or (di == 1 and dj == 1) and 4 or 8
		return bit32.band(m.wall[j * W + i + 1] or 0, bit) ~= 0
	end

	local function stepOk(m, i, j, di, dj)
		local W, H = m.w, m.h
		local ni, nj = i + di, j + dj
		if ni < 0 or nj < 0 or ni >= W or nj >= H then return false end
		local a, b = m.hts[j * W + i + 1], m.hts[nj * W + ni + 1]
		if not a or not b then return false end
		local dh = b - a
		local lim = (di ~= 0 and dj ~= 0) and UP_STEP * 1.42 or UP_STEP
		if dh > lim and dh <= 2.6 and (di == 0 or dj == 0) then
			-- top of a ramp: 3-stud samples land short of the wedge's top edge, so the last
			-- sample reads ~2 below the floor it joins. Allowed only while already climbing.
			local pi, pj = i - di, j - dj
			local prev = (pi >= 0 and pj >= 0 and pi < W and pj < H) and m.hts[pj * W + pi + 1]
			if prev and a - prev >= 0.5 then lim = 2.6 end
		end
		if dh > lim or dh < -DROP then return false end
		if walled(m, i, j, di, dj) then return false end
		if m.bad[(j * W + i) * 9 + (dj + 1) * 3 + (di + 1)] then return false end
		if di ~= 0 and dj ~= 0 then
			-- no corner cutting: both orthogonal legs must be legal
			if not stepOk(m, i, j, di, 0) or not stepOk(m, i + di, j, 0, dj) then return false end
			if not stepOk(m, i, j, 0, dj) or not stepOk(m, i, j + dj, di, 0) then return false end
		end
		return true
	end
	Nav.stepOk = stepOk

	-- nearest walkable cell to world point within r cells
	function Nav.snap(m, p, r)
		local ci, cj = Nav.cellOf(m, p)
		local best, bi, bj = math.huge, nil, nil
		for dj = -(r or 4), (r or 4) do
			for di = -(r or 4), (r or 4) do
				local i, j = ci + di, cj + dj
				if i >= 0 and j >= 0 and i < m.w and j < m.h then
					local h = m.hts[j * m.w + i + 1]
					local enterable = false
					if h then
						for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
							if Nav.stepOk(m, i + d[1], j + d[2], -d[1], -d[2]) then enterable = true break end
						end
					end
					if enterable then
						local d = di * di + dj * dj + math.abs(h - p.Y) * 0.3
						if d < best then best, bi, bj = d, i, j end
					end
				end
			end
		end
		return bi, bj
	end

	local NB = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

	-- partial = true: if the goal can't be reached, return the route to the reachable cell
	-- closest to it (goal across a bridge / on a pillar top) instead of nil
	function Nav.astar(m, si, sj, gi, gj, maxIter, partial)
		local W = m.w
		local start, goal = sj * W + si, gj * W + gi
		if start == goal then return { { si, sj } } end
		local g, came, closed = { [start] = 0 }, {}, {}
		local heap, hn = { { 0, start } }, 1
		local function push(f, n)
			hn += 1
			heap[hn] = { f, n }
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
				local l, r, s = c * 2, c * 2 + 1, c
				if l <= hn and heap[l][1] < heap[s][1] then s = l end
				if r <= hn and heap[r][1] < heap[s][1] then s = r end
				if s == c then break end
				heap[s], heap[c] = heap[c], heap[s]
				c = s
			end
			return top
		end
		local function hcost(n)
			local dx, dz = math.abs(n % W - gi), math.abs(n // W - gj)
			return math.max(dx, dz) + 0.414 * math.min(dx, dz)
		end
		local function build(last)
			local out, n = {}, last
			while n do
				table.insert(out, 1, { n % W, n // W })
				n = came[n]
			end
			return out
		end
		local it = 0
		local bestN, bestH = start, hcost(start)
		while hn > 0 do
			it += 1
			if it > (maxIter or 40000) then break end
			local cur = pop()[2]
			if cur == goal then return build(goal) end
			if not closed[cur] then
				closed[cur] = true
				local hc = hcost(cur)
				if hc < bestH then bestN, bestH = cur, hc end
				local ci, cj = cur % W, cur // W
				for _, d in ipairs(NB) do
					if stepOk(m, ci, cj, d[1], d[2]) then
						local nb = (cj + d[2]) * W + ci + d[1]
						if not closed[nb] then
							local cost = (d[1] ~= 0 and d[2] ~= 0) and 1.414 or 1
							local idx = nb + 1
							if m.haz[idx] then cost *= 8 end
							if m.edge[idx] then cost += 1.5 end
							local ng = g[cur] + cost
							if not g[nb] or ng < g[nb] then
								g[nb] = ng
								came[nb] = cur
								push(ng + hcost(nb), nb)
							end
						end
					end
				end
			end
		end
		if partial and bestN ~= start then return build(bestN), true end
		return nil
	end

	-- can we walk straight from cell a to cell b? (supercover line, each step legal)
	local function lineOk(m, ai, aj, bi, bj)
		local i, j = ai, aj
		local dx, dz = bi - ai, bj - aj
		local sx, sz = dx > 0 and 1 or -1, dz > 0 and 1 or -1
		local nx, nz = math.abs(dx), math.abs(dz)
		local ix, iz = 0, 0
		while ix < nx or iz < nz do
			local t1 = (0.5 + ix) / math.max(nx, 1e-9)
			local t2 = (0.5 + iz) / math.max(nz, 1e-9)
			local di, dj = 0, 0
			if nx == 0 then t1 = math.huge end
			if nz == 0 then t2 = math.huge end
			if math.abs(t1 - t2) < 1e-9 then
				di, dj = sx, sz ix += 1 iz += 1
			elseif t1 < t2 then
				di = sx ix += 1
			else
				dj = sz iz += 1
			end
			if not stepOk(m, i, j, di, dj) then return false end
			local idx = (j + dj) * m.w + i + di + 1
			if m.haz[idx] or m.edge[idx] then return false end
			i, j = i + di, j + dj
		end
		return true
	end

	function Nav.smooth(m, cells)
		if #cells <= 2 then return cells end
		local out = { cells[1] }
		local a = 1
		while a < #cells do
			local b = #cells
			while b > a + 1 and not lineOk(m, cells[a][1], cells[a][2], cells[b][1], cells[b][2]) do
				b -= 1
			end
			out[#out + 1] = cells[b]
			a = b
		end
		return out
	end

	-- full plan: world from -> world to; returns list of Vector3 waypoints (or nil, reason)
	-- partial = true: unreachable / off-map goal -> route to the closest reachable cell
	function Nav.plan(m, from, to, partial)
		local si, sj = Nav.snap(m, from, 3)
		if not si then return nil, "start-off-map" end
		local gi, gj = Nav.snap(m, to, 6)
		if not gi then
			if not partial then return nil, "goal-off-map" end
			gi, gj = Nav.cellOf(m, to)
			gi, gj = math.clamp(gi, 0, m.w - 1), math.clamp(gj, 0, m.h - 1)
		end
		local cells = Nav.astar(m, si, sj, gi, gj, nil, partial)
		if not cells then return nil, "no-path" end
		local pts = {}
		for _, c in ipairs(Nav.smooth(m, cells)) do pts[#pts + 1] = Nav.worldOf(m, c[1], c[2]) end
		return pts, cells
	end

	function Nav.markBad(m, p, q)
		local ai, aj = Nav.cellOf(m, p)
		local bi, bj = Nav.cellOf(m, q)
		local di, dj = math.clamp(bi - ai, -1, 1), math.clamp(bj - aj, -1, 1)
		m.bad[(aj * m.w + ai) * 9 + (dj + 1) * 3 + (di + 1)] = true
	end

	-- Field folder must be streamed in. Collidable floors are often CanQuery=false, so they are
	-- flipped on for the duration of the scan and restored after. yieldFn() is called between rows.
	function Nav.scan(field, yieldFn)
		local World = workspace:FindFirstChild("World")
		if not World then return nil, "no-world" end
		local folders = {}
		if field == "town" then
			for _, n in ipairs({ "Town", "Shrine", "PartyStage", "CostumeShowcase" }) do
				if World:FindFirstChild(n) then folders[#folders + 1] = World[n] end
			end
		elseif World:FindFirstChild("Field_" .. field) then
			folders[1] = World["Field_" .. field]
		end
		if #folders == 0 then return nil, "no-field" end
		local F = folders[1]
		local CELL = 3
		local mn, mx, nparts = nil, nil, 0
		for _, fo in ipairs(folders) do
			for _, d in ipairs(fo:GetDescendants()) do
				if d:IsA("BasePart") then
					nparts += 1
					if d.CanCollide and d.Size.Magnitude < 2000 then
						local p = d.Position
						mn = mn and Vector3.new(math.min(mn.X, p.X), math.min(mn.Y, p.Y), math.min(mn.Z, p.Z)) or p
						mx = mx and Vector3.new(math.max(mx.X, p.X), math.max(mx.Y, p.Y), math.max(mx.Z, p.Z)) or p
					end
				end
			end
		end
		if nparts < 500 or not mn then return nil, "not-streamed" end
		local x0 = math.floor(mn.X / CELL) * CELL - 6
		local z0 = math.floor(mn.Z / CELL) * CELL - 6
		local W = math.ceil((mx.X - x0 + 6) / CELL) + 1
		local H = math.ceil((mx.Z - z0 + 6) / CELL) + 1
		local TOPY, BOTY = mx.Y + 60, mn.Y - 80
		local base = math.floor(mn.Y - 80)
		local changed = {}
		for _, d in ipairs(workspace.World:GetDescendants()) do
			if d:IsA("BasePart") and d.CanCollide then
				-- v2: the LevelGate Arch over every bridge entrance is head-high overhead, not a
				-- floor: the down ray hit its top and the bridge entrance read as a 20-stud wall
				local arch = d.Name == "Arch" and d.Parent and d.Parent.Name == "LevelGate"
				if arch and d.CanQuery then
					d.CanQuery = false
					changed[#changed + 1] = d
				elseif not arch and not d.CanQuery then
					d.CanQuery = true
					changed[#changed + 1] = d
				end
			end
		end
		local hts, haz, wall, hitInst = {}, {}, {}, {}
		local ok, err = pcall(function()
			local rp = RaycastParams.new()
			rp.FilterType = Enum.RaycastFilterType.Include
			rp.FilterDescendantsInstances = { workspace.World }
			rp.RespectCanCollide = true
			local lavas = {}
			for _, fo in ipairs(folders) do
				for _, d in ipairs(fo:GetDescendants()) do
					if d:IsA("BasePart") and (d.Name == "Lava" or d.Name == "Acid" or d.Name == "Spikes") then lavas[#lavas + 1] = d end
				end
			end
			for j = 0, H - 1 do
				for i = 0, W - 1 do
					local x, z = x0 + i * CELL, z0 + j * CELL
					local idx = j * W + i + 1
					local y = nil
					local r = workspace:Raycast(Vector3.new(x, TOPY, z), Vector3.new(0, BOTY - TOPY, 0), rp)
					if r and r.Instance.Name ~= "Ocean" and r.Normal.Y >= 0.55 then
						y = r.Position.Y
						if workspace:Raycast(Vector3.new(x, y + 0.2, z), Vector3.new(0, 4.8, 0), rp) then y = nil end
					end
					hts[idx] = y
					hitInst[idx] = y and r.Instance or nil
					local hz = 0
					if y then
						local p = Vector3.new(x, y, z)
						for _, l in ipairs(lavas) do
							local lp = l.CFrame:PointToObjectSpace(p)
							if math.abs(lp.X) <= l.Size.X / 2 + 1.5 and math.abs(lp.Z) <= l.Size.Z / 2 + 1.5 and math.abs(lp.Y) <= l.Size.Y / 2 + 3 then
								hz = 1
								break
							end
						end
					end
					haz[idx] = hz
				end
				if yieldFn and j % 10 == 0 then yieldFn(j / H * 0.5) end
			end
			-- v3: stamp every collidable block part onto the grid. A 3-stud grid can miss a
			-- 2x2x2 cube entirely and the waist ray passes over it (jungle 3246,25: a cube pile
			-- stuck the bot every visit). Cell blocked if a part within 1.2 studs of its centre
			-- rises > 1.4 above that cell's floor and starts below head height. Wedges (ramps)
			-- and tilted parts are left to the rays; the part a cell stands on is skipped.
			local np = 0
			for _, fo in ipairs(folders) do
				for _, d in ipairs(fo:GetDescendants()) do
					if d:IsA("Part") and d.CanCollide and d.Shape == Enum.PartType.Block
						and math.abs(d.Orientation.X) < 1 and math.abs(d.Orientation.Z) < 1 then
						local cf, sz, c = d.CFrame, d.Size, d.Position
						local top, bot = c.Y + sz.Y / 2, c.Y - sz.Y / 2
						local hx = math.abs(cf.RightVector.X) * sz.X / 2 + math.abs(cf.LookVector.X) * sz.Z / 2 + 1.2
						local hz = math.abs(cf.RightVector.Z) * sz.X / 2 + math.abs(cf.LookVector.Z) * sz.Z / 2 + 1.2
						local i0 = math.max(0, math.ceil((c.X - hx - x0) / CELL))
						local i1 = math.min(W - 1, math.floor((c.X + hx - x0) / CELL))
						local j0 = math.max(0, math.ceil((c.Z - hz - z0) / CELL))
						local j1 = math.min(H - 1, math.floor((c.Z + hz - z0) / CELL))
						for jj = j0, j1 do
							for ii = i0, i1 do
								local idx = jj * W + ii + 1
								local fy = hts[idx]
								if fy and hitInst[idx] ~= d and top > fy + 1.5 and bot < fy + 5.5 then
									local lp = cf:PointToObjectSpace(Vector3.new(x0 + ii * CELL, c.Y, z0 + jj * CELL))
									if math.abs(lp.X) <= sz.X / 2 + 1.2 and math.abs(lp.Z) <= sz.Z / 2 + 1.2 then
										hts[idx] = nil
									end
								end
							end
						end
						np += 1
						if yieldFn and np % 400 == 0 then yieldFn(0.5) end
					end
				end
			end
			local dirs = { { 1, 0, 1 }, { 0, 1, 2 }, { 1, 1, 4 }, { -1, 1, 8 } }
			for j = 0, H - 1 do
				for i = 0, W - 1 do
					local idx = j * W + i + 1
					local y, mbits = hts[idx], 0
					if y then
						for _, d in ipairs(dirs) do
							local ni, nj = i + d[1], j + d[2]
							if ni >= 0 and ni < W and nj < H then
								local y2 = hts[nj * W + ni + 1]
								if y2 then
									local wy = math.max(y, y2) + 2.2
									local a = Vector3.new(x0 + i * CELL, wy, z0 + j * CELL)
									local b = Vector3.new(x0 + ni * CELL, wy, z0 + nj * CELL)
									if workspace:Raycast(a, b - a, rp) or workspace:Raycast(b, a - b, rp) then mbits += d[3] end
								end
							end
						end
					end
					wall[idx] = mbits
				end
				if yieldFn and j % 10 == 0 then yieldFn(0.5 + j / H * 0.5) end
			end
		end)
		for _, d in ipairs(changed) do d.CanQuery = not d.CanQuery end
		if not ok then return nil, tostring(err) end
		local hs, hzs, ws, walk = {}, {}, {}, 0
		local hex = "0123456789abcdef"
		for k = 1, W * H do
			local y = hts[k]
			if y then walk += 1 end
			hs[k] = y and tostring(math.floor((y - base) * 10 + 0.5)) or ""
			hzs[k] = tostring(haz[k])
			ws[k] = hex:sub((wall[k] or 0) + 1, (wall[k] or 0) + 1)
		end
		local poi = { ramps = {} }
		for _, fo in ipairs(folders) do
			local stone = fo:FindFirstChild("WarpStone")
			if stone and not poi.warp then local c = stone:GetPivot().Position poi.warp = { c.X, c.Y, c.Z } end
			local arena = fo:FindFirstChild("BossArena")
			if arena and not poi.arena then local c = arena:GetPivot().Position poi.arena = { c.X, c.Y, c.Z } end
			for _, d in ipairs(fo:GetDescendants()) do
				if d.Name == "StairRamp" then poi.ramps[#poi.ramps + 1] = { d.Position.X, d.Position.Y, d.Position.Z } end
			end
		end
		-- zone config (Shared.Config.Zones): spawn regions, arena, gate, exit, terraces, town NPCs.
		-- Config vectors are flat (Y=0); Y is filled from the scanned floor under that point.
		local function floorY(x, z)
			local i = math.floor((x - x0) / CELL + 0.5)
			local j = math.floor((z - z0) / CELL + 0.5)
			for r = 0, 3 do
				for dj = -r, r do
					for di = -r, r do
						local ii, jj = i + di, j + dj
						if ii >= 0 and jj >= 0 and ii < W and jj < H then
							local y = hts[jj * W + ii + 1]
							if y then return math.floor(y * 10 + 0.5) / 10 end
						end
					end
				end
			end
			return nil
		end
		local function v3(v)
			if typeof(v) ~= "Vector3" then return nil end
			return { math.floor(v.X * 10 + 0.5) / 10, floorY(v.X, v.Z) or v.Y, math.floor(v.Z * 10 + 0.5) / 10 }
		end
		pcall(function()
			local Z = require(game:GetService("ReplicatedStorage").Shared.Config.Zones)
			local zone = {}
			if field == "town" then
				for k, v in pairs(Z.town) do
					if typeof(v) == "Vector3" then zone[k] = v3(v) end
				end
				zone.name = Z.town.name
				if Z.shrine and typeof(Z.shrine.center) == "Vector3" then
					zone.shrine = { c = v3(Z.shrine.center), r = Z.shrine.radius, name = Z.shrine.name }
				end
			else
				local w = Z.warpById and Z.warpById[field]
				local b = w and w.base
				if b then
					zone.name, zone.boss, zone.levels, zone.gold = b.name, b.boss, b.levels, w.gold
					zone.entrance = v3(b.entrance)
					if b.exit then zone.exit = { c = v3(b.exit.center), r = b.exit.radius } end
					if b.arena then zone.arena = { c = v3(b.arena.center), r = b.arena.radius, level = b.arena.level } end
					if b.gate then
						zone.gate = { at = v3(b.gate.at), back = v3(b.gate.back), boss = b.gate.boss, level = b.gate.level }
					end
					zone.spawns = {}
					for _, s in ipairs(b.spawns or {}) do
						local rg = s.region or {}
						zone.spawns[#zone.spawns + 1] = { monster = s.monster, count = s.count, c = v3(rg.center),
							size = rg.size and { rg.size.X, rg.size.Y } or nil }
					end
					zone.terraces = {}
					for _, t in ipairs(b.terraces or {}) do
						zone.terraces[#zone.terraces + 1] = { c = v3(t.center), r = t.radius, level = t.level }
					end
				end
			end
			poi.zone = zone
		end)
		local data = { v = Nav.SCAN_V, field = field, cell = CELL, x0 = x0, z0 = z0, w = W, h = H, base = base,
			hts = table.concat(hs, ","), haz = table.concat(hzs), wall = table.concat(ws), poi = poi,
			parts = nparts, scanned = os.time(), placeVersion = game.PlaceVersion }
		if not isfolder("PetHunt") then makefolder("PetHunt") end
		if not isfolder("PetHunt/nav") then makefolder("PetHunt/nav") end
		writefile(DIR .. field .. ".json", HS:JSONEncode(data))
		maps[field] = decode(data)
		return maps[field], ("%dx%d walk=%d parts=%d"):format(W, H, walk, nparts)
	end

	-- read just the header of a saved map (for "needs rescan?" checks)
	function Nav.savedInfo(field)
		local path = DIR .. field .. ".json"
		if not (isfile and isfile(path)) then return nil end
		local ok, d = pcall(function() return HS:JSONDecode(readfile(path)) end)
		if not ok then return nil end
		return { parts = d.parts or 0, placeVersion = d.placeVersion, scanned = d.scanned, v = d.v or 1 }
	end

	-- stuck log: PetHunt/nav/stuck.json  [{f,x,y,z,gx,gz,t}]
	function Nav.logStuck(m, p, goal)
		local path = DIR .. "stuck.json"
		local list = {}
		pcall(function() list = HS:JSONDecode(readfile(path)) end)
		list[#list + 1] = { f = m.name, x = math.floor(p.X), y = math.floor(p.Y), z = math.floor(p.Z),
			gx = math.floor(goal.X), gz = math.floor(goal.Z), t = os.time() }
		while #list > 200 do table.remove(list, 1) end
		pcall(writefile, path, HS:JSONEncode(list))
	end

	-- Per-tick driver for a caller that re-asks every ~0.1s (the main script's pathTo).
	-- st = persistent state table. Returns true when it issued the movement this tick;
	-- false = no map / no path / gave up -> caller uses its old walker.
	local function flatD(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude end
	function Nav.drive(st, fid, hum, hrp, goal)
		if not fid then return false end
		st.scanTried = st.scanTried or {}
		local m = maps[fid] or Nav.load(fid)
		if m and not st.verChecked then
			st.verChecked = {}
		end
		if m and st.verChecked and not st.verChecked[fid] then
			-- game updated since the scan -> rescan in the background (old map stays in use meanwhile)
			st.verChecked[fid] = true
			local info = Nav.savedInfo(fid)
			if info and (info.placeVersion ~= game.PlaceVersion or (info.v or 1) < Nav.SCAN_V) then
				task.spawn(function()
					task.wait(2)
					if Nav.scan(fid, function() task.wait() end) then st.pts, st.outTarget = nil, nil end
				end)
			end
		end
		if not m then
			if not st.scanTried[fid] then
				st.scanTried[fid] = true
				task.spawn(function() task.wait(3) Nav.scan(fid, function() task.wait() end) end)
			end
			return false
		end
		local pos = hrp.Position
		if not Nav.inside(m, pos) then return false end
		local now = os.clock()
		if st.failUntil and now < st.failUntil and st.failGoal and flatD(st.failGoal, goal) < 8 then return false end
		local target = goal
		local outside = not Nav.inside(m, goal)
		if outside then
			-- goal is in another field (e.g. the nearest WarpStone is across the bridge):
			-- A* toward it with partial=true ends at the reachable cell closest to it = the
			-- bridge end; the bridge itself is the old walker's (it used to start from mid-
			-- field and wedge into the pocket beside snow's east ramp every time)
			if st.outGoal and flatD(st.outGoal, goal) < 6 and st.outTarget then
				target = st.outTarget
			else
				local pts = Nav.plan(m, pos, goal, true)
				if not pts then st.failUntil, st.failGoal = now + 6, goal return false end
				target = pts[#pts]
				st.outGoal, st.outTarget = goal, target
			end
			if flatD(target, pos) < 5 then return false end
		end
		if now - (st.last or 0) > 0.6 then st.pts = nil end   -- caller paused: start fresh
		st.last = now
		if not st.pts or flatD(st.goal, target) > 6 or st.field ~= fid or now - st.planAt > 12 then
			if not st.goal or flatD(st.goal, target) > 6 then st.stuckN = 0 end
			local pts = Nav.plan(m, pos, target, true)
			if not pts then
				st.failUntil, st.failGoal, st.pts = now + 6, goal, nil
				return false
			end
			st.pts, st.i, st.goal, st.field, st.planAt = pts, 2, target, fid, now
			st.markPos, st.markAt, st.jumped = pos, now, false
		end
		local pts = st.pts
		-- advance: close enough, or already past it along the segment (fast mounts overshoot)
		while st.i <= #pts do
			local wp = pts[st.i]
			local last = st.i == #pts
			if flatD(wp, pos) <= (last and 3 or 3.5) then
				st.i += 1
			elseif not last then
				local prev = pts[st.i - 1]
				local seg = Vector3.new(wp.X - prev.X, 0, wp.Z - prev.Z)
				local rel = Vector3.new(pos.X - wp.X, 0, pos.Z - wp.Z)
				if seg.Magnitude > 0.1 and seg.Unit:Dot(rel) > 0 and flatD(wp, pos) < 10 then st.i += 1 else break end
			else
				break
			end
		end
		if st.i > #pts then
			hum:MoveTo(target)   -- route done; goal may sit inside a solid (obelisk) -> push at it
			return true
		end
		local wp = pts[st.i]
		hum:MoveTo(wp)
		if wp.Y - pos.Y > 2.2 and now - (st.jumpAt or 0) > 0.6 then hum.Jump = true st.jumpAt = now end
		-- stuck handling: jump at 1s, give up this edge at 2.5s (mark bad + log + replan)
		if (pos - st.markPos).Magnitude > 1.5 then
			st.markPos, st.markAt, st.jumped = pos, now, false
		else
			local still = now - st.markAt
			if still > 1 and not st.jumped then
				hum.Jump = true
				st.jumped = true
			elseif still > 2.5 then
				Nav.markBad(m, pos, wp)
				Nav.logStuck(m, pos, wp)
				st.stuckN = (st.stuckN or 0) + 1
				st.pts = nil
				if st.stuckN >= 4 then st.failUntil, st.failGoal = now + 10, goal end
				st.markPos, st.markAt = pos, now
			end
		end
		return true
	end

	-- Walk to goal along the navmap. opts: alive() -> bool, arrive (studs), timeout (s), onStatus(str)
	-- returns true | false, reason
	function Nav.walk(m, goal, opts)
		opts = opts or {}
		local plr = game:GetService("Players").LocalPlayer
		local arrive = opts.arrive or 4
		local deadline = os.clock() + (opts.timeout or 60)
		local replans = 0
		local function alive() return (not opts.alive) or opts.alive() end
		-- goal may sit inside something solid (obelisk, boss pedestal): the nearest enterable
		-- cell is the real target, and reaching it counts as arrival
		local gi, gj = Nav.snap(m, goal, 6)
		local goalCell = gi and Nav.worldOf(m, gi, gj)
		local function arrived(p)
			if Vector3.new(goal.X - p.X, 0, goal.Z - p.Z).Magnitude <= arrive then return true end
			return goalCell ~= nil and Vector3.new(goalCell.X - p.X, 0, goalCell.Z - p.Z).Magnitude <= 2.5
		end
		while alive() and os.clock() < deadline do
			local ch = plr.Character
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
			if not hum or not hrp or hum.Health <= 0 then return false, "dead" end
			if arrived(hrp.Position) then return true end
			local pts, why = Nav.plan(m, hrp.Position, goal)
			if not pts then return false, why end
			local stuckAt = nil
			for k = 2, #pts do
				local wp = pts[k]
				local last = k == #pts
				local lastPos, lastProg = hrp.Position, os.clock()
				local jumped = false
				while alive() and os.clock() < deadline do
					if hum.Health <= 0 then return false, "dead" end
					local p = hrp.Position
					local d = Vector3.new(wp.X - p.X, 0, wp.Z - p.Z).Magnitude
					if d <= (last and arrive or 2.5) then break end
					hum:MoveTo(wp)
					if (p - lastPos).Magnitude > 1 then
						lastPos, lastProg, jumped = p, os.clock(), false
					elseif os.clock() - lastProg > 0.9 and not jumped then
						hum.Jump = true
						jumped = true
					elseif os.clock() - lastProg > 2.2 then
						stuckAt = { p, wp }
						break
					end
					if opts.onStatus then opts.onStatus(("nav %d/%d"):format(k, #pts)) end
					task.wait(0.1)
				end
				if stuckAt then break end
			end
			if not stuckAt then
				if arrived(hrp.Position) then return true end
			elseif Vector3.new(goal.X - stuckAt[1].X, 0, goal.Z - stuckAt[1].Z).Magnitude <= arrive + 4 then
				-- blocked right at the goal (boss body, pedestal): close enough
				return true
			else
				Nav.markBad(m, stuckAt[1], stuckAt[2])
				Nav.logStuck(m, stuckAt[1], stuckAt[2])
				replans += 1
				if replans > 4 then return false, "stuck" end
			end
		end
		return false, alive() and "timeout" or "cancelled"
	end
end
return Nav
end)()
-- [NAV END]

-- Every combat field OPEN right now. Z.allFields lists all 12 biomes (Z.fields only
-- has the 7 original); fields past Moon Base are released by time via opensAt, and
-- their config `comingSoon` flag goes STALE once that timestamp passes -- so we gate
-- on opensAt, never on comingSoon. Falls back to Z.fields if allFields is missing.
local function openFields(Z)
	local src = (type(Z.allFields) == "table" and #Z.allFields > 0) and Z.allFields or Z.fields
	if type(src) ~= "table" then return {} end
	local now = os.time()
	local out = {}
	for _, f in ipairs(src) do
		local opensAt = tonumber(f.opensAt)
		if (not opensAt) or opensAt <= now then out[#out + 1] = f end
	end
	return out
end

-- Field bosses fight in PHASES: at low HP the boss calls helpers and raises a SHIELD
-- (attribute Shielded=true) -- while shielded it takes no damage, and the helpers
-- (Monster models tagged BossAdd) can even heal it. Kill the adds first to break the
-- shield, then resume the boss. This finds the nearest living add to retarget onto.
local function nearestBossAdd(pos)
	local M = workspace:FindFirstChild("Monsters")
	if not M then return nil end
	local best, bestD
	for _, j in ipairs(M:GetChildren()) do
		if j:GetAttribute("BossAdd") and j.PrimaryPart and (tonumber(j:GetAttribute("Health")) or 0) > 0 then
			local d = (j.PrimaryPart.Position - pos).Magnitude
			if not best or d < bestD then best, bestD = j, d end
		end
	end
	return best
end

-- Auto Reconnect: 3-trigger version (PlayerRemoving alone misses silent drops
-- where the transport dies but LocalPlayer never leaves and the native
-- "Disconnected" dialog just sits there). Debounced 5s, hooked once across
-- reloads. cp_boot's queue_on_teleport re-runs the script on the new join.
if not getgenv().__PHP_RECON then
	getgenv().__PHP_RECON = true
	local TeleportService = game:GetService("TeleportService")
	local firedAt = 0
	local function tryReconnect()
		if not e.phReconnect then return end
		if os.clock() - firedAt < 5 then return end
		firedAt = os.clock()
		pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
	end
	pcall(function() Players.PlayerRemoving:Connect(function(p) if p == plr then tryReconnect() end end) end)
	pcall(function() plr.AncestryChanged:Connect(function(_, parent) if parent ~= Players then tryReconnect() end end) end)
	pcall(function() game:GetService("GuiService").ErrorMessageChanged:Connect(tryReconnect) end)
	task.spawn(function()
		local CoreGui = game:GetService("CoreGui")
		while true do
			task.wait(5)
			if e.phReconnect then
				pcall(function()
					for _, inst in ipairs(CoreGui:GetDescendants()) do
						if inst:IsA("TextLabel") and inst.Text == "Disconnected" then tryReconnect(); break end
					end
				end)
			end
		end
	end)
end

-- ----------------------------------------------------------------- rarity
-- def.lines is the gear's stat-line count = rarity tier 0..4 (dungeon gear is
-- its own bucket "dg"), the same key the game's "Sell all" uses.
-- named exactly like the game's bag shows gear ("Tier IV · Armor · Lv.93"):
-- Kit.GearArt.tierName maps lines 0..4 -> I..V, dungeon gear -> DG
local TIER_LABELS = {
	[0] = "Tier I",
	[1] = "Tier II",
	[2] = "Tier III",
	[3] = "Tier IV",
	[4] = "Tier V",
	dg = "DG",
}
-- Legendary (no sellable field gear exists at that rarity -- only dungeon gear reaches
-- it) and dungeon gear are NEVER offered or sold (user: "เอา Dungeon ออก เดี๋ยวลบมั่ว")
local TIER_ORDER = {0, 1, 2, 3}
local NEVER_SELL = {[4] = true, dg = true}

local function defaultTiers()
	-- by default only the cheap tiers, mirroring the game's {[0]=true,1,2}
	return {[TIER_LABELS[0]] = true, [TIER_LABELS[1]] = true, [TIER_LABELS[2]] = true}
end
if type(e.phSellTiers) ~= "table" then e.phSellTiers = defaultTiers() end
do   -- migrate picks saved under the old Thai labels ("ขั้น 0 (ธรรมดา)" ...)
	local OLD = {["ขั้น 0 (ธรรมดา)"] = 0, ["ขั้น 1"] = 1, ["ขั้น 2"] = 2, ["ขั้น 3"] = 3, ["ขั้น 4 (สูงสุด)"] = 4, ["ของดันเจี้ยน"] = "dg",
		Common = 0, Uncommon = 1, Rare = 2, Epic = 3, Legendary = 4, Dungeon = "dg"}
	local migrated = false
	for old, t in pairs(OLD) do
		if e.phSellTiers[old] then e.phSellTiers[old] = nil; e.phSellTiers[TIER_LABELS[t]] = true; migrated = true end
	end
	-- drop any saved Legendary/Dungeon pick: those can never be sold by this script
	for t in pairs(NEVER_SELL) do
		if e.phSellTiers[TIER_LABELS[t]] then e.phSellTiers[TIER_LABELS[t]] = nil; migrated = true end
	end
	if migrated then pcall(function() writefile(SF, HS:JSONEncode(e)) end) end
end
-- per-rarity level filter: phSellLv[tierKey] = {["93"] = true, ...}; empty = sell every level
if type(e.phSellLv) ~= "table" then e.phSellLv = {} end

local function tierOf(def)
	if def.dungeon then return "dg" end
	return math.clamp(tonumber(def.lines) or 0, 0, 4)
end

-- ------------------------------------------------------------------- stats
local stats = {farm = "-", sell = "-", sold = 0, gold = 0, collect = "-", equip = "-", equipped = 0, chest = "-"}
getgenv().__PHP_STATS = stats   -- read-only diagnostics handle (current generation's status)
stats.sessionAt = os.clock()
stats.kills = 0

-- 7 gear slots (Equipment.types). Auto Equip Best fills each with the strongest
-- owned item you can actually wear (class nil = any class, else your class).
local SLOTS = {"weapon", "headgear", "face", "armor", "garment", "shoes", "accessory"}

-- --------------------------------------------------------------- auto farm
-- The game's own auto parks on a spawn and only swats what touches it. So: keep
-- the game's auto ON (for skills + the actual hitting) but DRIVE the character
-- with Humanoid:MoveTo toward the highest-level monster in the field it can
-- handle, so it roams to level-appropriate monsters. Stays inside the current
-- field (monsters X within half a field-spacing of ours) and ignores the field
-- boss unless phFarmBoss is set. Real walking only — no teleporting.
local PFS = game:GetService("PathfindingService")
local NEAR_RADIUS = 150       -- fight the strongest monster THIS close first (so it
                              -- actually engages instead of chasing a far wanderer)
local FARM_RADIUS = 450       -- only roam this far when nothing is near
local ENGAGE_DIST = 16        -- within this = arrived, turn auto ON and attack
local DISENGAGE_DIST = 34     -- once engaged, only go back to travel past this (hysteresis)
local STUCK_S = 6             -- can't reach a target in this long -> skip it a while
local farmTarget = nil
local travelStart = 0         -- when we started heading to the CURRENT target (stuck timer)
local lastPick = 0            -- last time we re-evaluated the target (repick cadence)
local skipUntil = {}          -- monster -> os.clock() deadline

-- Pick a target in the SAME FIELD as us (baseAt per nearby candidate, so the
-- character never chases one across the field gate into a locked field):
--   phFarmBoss on + the field boss present & reachable -> the boss (to unlock
--   the next field); otherwise the highest-level monster, closest breaking ties.
-- Farm anchor: when a farm spot is set (Boss tab button) and it's in the field we're
-- standing in, ONLY farm monsters within ANCHOR_RADIUS of it. Before, the spot was
-- only a "return here after a boss trip" point and pickTarget roamed the whole field
-- (user: "ตั้งจุดฟามไว้ แต่มันเดินไปฟามจุดอื่น"). Flat XZ distance -- terrain is terraced.
local ANCHOR_RADIUS = 70
local function farmAnchor(hrp)
	local fp = e.phFarmPos
	if type(fp) ~= "table" or not fp.x then return nil end
	local a = Vector3.new(fp.x, fp.y, fp.z)
	local fa, fh = fieldAt(a), fieldAt(hrp.Position)
	if fa and fh and fa.id == fh.id then return a end
	return nil
end
local function flatDist(p, q) return Vector3.new(p.X - q.X, 0, p.Z - q.Z).Magnitude end

local function pickTarget(hrp)
	local myField = fieldAt(hrp.Position)
	local myId = myField and myField.id
	local now = os.clock()
	local anchor = farmAnchor(hrp)
	-- spot is set but in ANOTHER field: auto-warp is taking us home, so don't pick up
	-- random monsters here on the way (only a selected boss may still be fought)
	local spotElsewhere = e.phAutoWarp and type(e.phFarmPos) == "table" and e.phFarmPos.x and not anchor
	local bossId = myField and myField.boss
	-- nearHi: strongest within NEAR_RADIUS (what we actually fight)
	-- nearest: closest anything within FARM_RADIUS (roam toward it when none near)
	-- bossPick: the field boss when phFarmBoss is on
	-- level window relative to the player (e.g. "no more than 2 below me")
	local myLv = tonumber(plr:GetAttribute("Level")) or 1
	local below = tonumber(e.phFarmBelow) or 99
	local above = tonumber(e.phFarmAbove) or 10
	local loLv = myLv - below
	local hiLv = myLv + above
	-- targetLv: the level we actually AIM for = my level shifted down by "below" and
	-- up by "above" (so below=2,above=0 -> 2 under me; 0,0 -> exactly my level). We
	-- pick the in-window monster whose level is closest to this, not the strongest.
	local targetLv = myLv - below + above
	-- fieldMax = highest-level monster in the field REGARDLESS of the window, used
	-- as a fallback so we keep farming (and levelling) when nothing falls inside
	-- the chosen window -- e.g. my level outran the field's top monster.
	local nearBest, nearBestOff, nearBestD, nearest, nearestD, bossPick, fieldMax, fieldMaxLv, fieldMaxD
	for _, m in ipairs(workspace.Monsters:GetChildren()) do
		if m.PrimaryPart and (tonumber(m:GetAttribute("Health")) or 0) > 0
			and m:GetAttribute("Dummy") ~= true   -- skip town DPS-test dummies
			and (not skipUntil[m] or skipUntil[m] < now) then
			local isBoss = m:GetAttribute("IsBoss") == true or m:GetAttribute("MonsterId") == bossId
			if (not isBoss) or e.phFarmBoss then
				local d = (m.PrimaryPart.Position - hrp.Position).Magnitude
				local inAnchor = isBoss
					or (anchor and flatDist(m.PrimaryPart.Position, anchor) < ANCHOR_RADIUS)
					or (not anchor and not spotElsewhere)
				if d < FARM_RADIUS and inAnchor then
					local mf = fieldAt(m.PrimaryPart.Position)
					if not myId or (mf and mf.id == myId) then
						local bid2 = m:GetAttribute("MonsterId")
						local bossOk = not (e.phBossUnbeaten and plr:GetAttribute("Beat_" .. tostring(bid2)) == true)
							and ((not e.phBossWaitLv) or myLv >= (tonumber(m:GetAttribute("Level")) or BOSS_LV[bid2] or 0))
						if isBoss and e.phFarmBoss and bossOk and (not bossPick or d < bossPick.d) then
							bossPick = {m = m, d = d}
						end
						local lv = tonumber(m:GetAttribute("Level")) or 0
						if not isBoss then
							-- travel cost, not straight-line distance: a monster on another
							-- terrace (cliff in between, |dy| > 9) means a detour via a ramp,
							-- so it costs its height x3 and loses ties to same-floor ones
							local dy = math.abs(m.PrimaryPart.Position.Y - hrp.Position.Y)
							local cost = d + (dy > 9 and dy * 3 or 0)
							local floorPen = dy > 9 and 3 or 0
							-- always remember the field's strongest (fallback)
							if not fieldMax or lv > fieldMaxLv or (lv == fieldMaxLv and cost < fieldMaxD) then
								fieldMax, fieldMaxLv, fieldMaxD = m, lv, cost
							end
							-- inside the window, aim for targetLv: pick the monster whose
							-- level is closest to it (tie -> cheapest to reach). nearest =
							-- cheapest in-window monster, used only to roam into the action.
							if lv >= loLv and lv <= hiLv then
								if not nearest or cost < nearestD then nearest, nearestD = m, cost end
								local off = math.abs(lv - targetLv) + floorPen
								if d < NEAR_RADIUS and (not nearBest or off < nearBestOff or (off == nearBestOff and cost < nearBestD)) then
									nearBest, nearBestOff, nearBestD = m, off, cost
								end
							end
						end
					end
				end
			end
		end
	end
	if bossPick then
		-- SHIELD PHASE: while the boss is shielded (it summoned helpers) it takes no
		-- damage -- kill the BossAdd helpers first so the shield breaks, then the boss.
		if bossPick.m:GetAttribute("Shielded") == true then
			local add = nearestBossAdd(hrp.Position)
			if add then return add end
		end
		return bossPick.m
	end
	if nearBest then return nearBest end    -- nearby monster closest to target level
	if nearest then return nearest end      -- roam to the closest in-window
	return fieldMax                         -- none in window: farm the field's best
end

-- Walk to a point AROUND buildings with PathfindingService (straight MoveTo got
-- caught on structures). Follows the computed waypoints; recomputes when the goal
-- drifts or the route runs out. Returns true while still en route.
-- Travel to a point with PathfindingService + robust unstick. The map has
-- stairs, walls and raised arena platforms that the navmesh sometimes can't
-- route to; then a straight MoveTo wedges into a corner. So: track progress
-- toward the goal, and when it stalls, SIDESTEP perpendicular (alternating
-- left/right) and jump to peel off the wall, and force a path replan.
-- Trust PathfindingService: it routes around buildings and up stairs/ramps
-- (confirmed it returns Success + a climbing path to raised arenas). Just follow
-- the waypoints faithfully, jump to climb steps, and when we stop making progress
-- (wedged in a corner) JUMP to pop free and RECOMPUTE the route -- never hand-steer
-- straight into geometry, which is what was wedging the character before.
-- Normal travel = PathfindingService (natural walk, routes around buildings and up
-- stairs). The permanent anti-stuck: progress is measured toward the GOAL, and if we
-- don't get closer for ~1.3s (wedged on any terrain, in any field), we TELEPORT-HOP
-- past the obstacle in small 9-stud steps. Small hops stay under the game's position
-- anti-cheat cap (verified: ~45 studs/s holds, big jumps snap back), and each hop is
-- SNAPPED DOWN onto real ground (raycast) so we never hop into a wall or off a ledge
-- into the void. This is what makes "เดินติด" impossible regardless of the map.
local pf = {path = nil, wps = {}, i = 1, goal = nil, at = 0, jumpAt = 0,
	bestGoalD = math.huge, goalProgAt = 0}
local HOP_PARAMS = RaycastParams.new()
HOP_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
-- v4 (arena fix). Boss arenas sit on a plateau 12 studs up, ringed by Cliff walls
-- (top ~16.5 above ground) with ONE StairRamp. v3 failed there in a loop:
--   * "stuck" = no straight-line progress to the goal, but the route to the ramp
--     DETOURS away from the boss -> false "stuck" after 1.3s;
--   * it then hopped straight AT the goal -> into the cliff, and its ground-snap ray
--     started only 12 above the char = INSIDE the 16.5-tall cliff, so the ray skipped
--     the cliff and snapped back to the ground at its foot. Repeat forever.
-- v4: stuck = the character physically isn't moving (<3 studs in 1.3s), or no 3D
-- progress for 8s (orbiting); a detour that keeps walking is fine. Hops follow the
-- PATH (next waypoint, i.e. up the ramp), snapped from just above that waypoint;
-- only with no path at all do we hop at the goal with a ray high enough to clear
-- cliffs. Distances are 3D so standing UNDER the arena never counts as "arrived".
local function navTo(hum, hrp, goalPos)
	local now = os.clock()
	local pos = hrp.Position
	local goalD = (goalPos - pos).Magnitude
	-- not called for a while (we were fighting / standing on purpose): the stuck
	-- timers are stale -- restart them, or the first step after every kill reads as
	-- "stuck 1.3s" and teleport-hops (user saw it as warping like a cheat)
	if now - (pf.lastCall or 0) > 0.5 then
		pf.markPos = pos; pf.markAt = now; pf.bestGoalD = goalD; pf.goalProgAt = now; pf.hopping = false
	end
	pf.lastCall = now
	if goalD < pf.bestGoalD - 3 then pf.bestGoalD = goalD; pf.goalProgAt = now end
	if not pf.markPos or (pos - pf.markPos).Magnitude > 3 then pf.markPos = pos; pf.markAt = now end
	local stillFor = now - (pf.markAt or now)
	-- stage 1 (1.3s not moving): jump + replan, still walking -- invisible
	-- stage 2 (3s not moving, or 12s orbiting with no progress): teleport-hop burst
	local wedged = stillFor > 1.3
	local stuck = pf.forceHop or stillFor > 3 or (now - (pf.goalProgAt or now) > 12)
	pf.forceHop = false
	if wedged and not pf.hopping and now - pf.jumpAt > 0.6 then
		hum.Jump = true; pf.jumpAt = now; pf.goal = nil   -- forces a fresh route below
	end
	if stuck and not pf.hopping then
		pf.hopping = true; pf.hopStartGoalD = goalD; pf.hopStartAt = now
		stats.hops = (stats.hops or 0) + 1
	end
	-- short bursts: stop as soon as we've broken free (moved 12 closer) or 1.2s
	if pf.hopping and (goalD < (pf.hopStartGoalD or goalD) - 12 or goalD < 6 or now - (pf.hopStartAt or now) > 1.2) then
		pf.hopping = false; pf.bestGoalD = goalD; pf.goalProgAt = now; pf.markPos = pos; pf.markAt = now
	end

	-- Route in the BACKGROUND. ComputeAsync yields for 50-500ms; done inline it froze
	-- this loop, the character reached its 4-stud waypoint and stood still until the
	-- new route arrived -- the "เดินๆหยุดๆ" stutter on every replan. Now we keep
	-- walking the old route (or straight at the goal) while the new one computes.
	local needReplan = not pf.goal or (goalPos - pf.goal).Magnitude > 10
		or pf.i > #pf.wps or #pf.wps == 0 or pf.hopping
	if needReplan and not pf.computing and now - pf.at > 0.4 then
		pf.at = now; pf.computing = true; pf.goal = goalPos
		if not pf.path then pf.path = PFS:CreatePath({AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, AgentMaxSlope = 89, WaypointSpacing = 4}) end
		local path, from, gen = pf.path, pos, pf.gen
		task.spawn(function()
			local ok = pcall(function() path:ComputeAsync(from, goalPos) end)
			pf.computing = false
			if pf.gen ~= gen then return end   -- pathReset() happened meanwhile: discard
			if ok and path.Status == Enum.PathStatus.Success then
				local wps = path:GetWaypoints()
				-- we kept moving while it computed: resume from the waypoint nearest us
				local cur = hrp.Position
				local bi, bd = 2, math.huge
				for k = 2, math.min(#wps, 12) do
					local dd = (wps[k].Position - cur).Magnitude
					if dd < bd then bi, bd = k, dd end
				end
				pf.wps = wps; pf.i = bi
			else
				pf.wps = {}
			end
		end)
	end

	-- skip waypoints we're already standing on (flat-close AND same height band)
	local wp = pf.wps[pf.i]
	while wp and Vector3.new(pos.X - wp.Position.X, 0, pos.Z - wp.Position.Z).Magnitude < 4
		and math.abs(wp.Position.Y - pos.Y) < 6 do
		pf.i += 1; wp = pf.wps[pf.i]
	end
	local aim = wp and wp.Position or goalPos
	-- look ahead up to 3 waypoints along flat, jump-free stretches so MoveTo always
	-- has ~12 studs to cover (no stop at each 4-stud point between loop ticks)
	if wp then
		for k = pf.i + 1, math.min(pf.i + 3, #pf.wps) do
			local w = pf.wps[k]
			if w.Action == Enum.PathWaypointAction.Jump or math.abs(w.Position.Y - wp.Position.Y) > 2 then break end
			aim = w.Position
		end
	end

	-- HOP MODE: small ground-snapped teleport steps (under the anti-cheat cap).
	if pf.hopping and goalD > 1 then
		local flat = Vector3.new(aim.X - pos.X, 0, aim.Z - pos.Z)
		if flat.Magnitude < 1 then flat = Vector3.new(goalPos.X - pos.X, 0, goalPos.Z - pos.Z) end
		if flat.Magnitude > 0.5 then
			local hopXZ = pos + flat.Unit * math.min(9, flat.Magnitude)
			-- following a path: snap onto the path surface (just above the waypoint);
			-- no path: cast from well above so a cliff/plateau top gets hit, not skipped
			local topY = wp and (math.max(pos.Y, aim.Y) + 6) or (math.max(pos.Y, goalPos.Y) + 22)
			HOP_PARAMS.FilterDescendantsInstances = {hrp.Parent, workspace:FindFirstChild("Monsters"), workspace:FindFirstChild("BossFx")}
			local hit = workspace:Raycast(Vector3.new(hopXZ.X, topY, hopXZ.Z), Vector3.new(0, -120, 0), HOP_PARAMS)
			if hit then hrp.CFrame = CFrame.new(hit.Position + Vector3.new(0, 3, 0)) end
		end
		return
	end

	hum:MoveTo(aim)
	-- jump to climb: on a Jump waypoint, or when the next point is above us
	if ((wp and wp.Action == Enum.PathWaypointAction.Jump) or (aim.Y - pos.Y > 1.5))
		and now - pf.jumpAt > 0.25 then
		hum.Jump = true; pf.jumpAt = now
	end
end
local function pathReset()
	pf.gen = (pf.gen or 0) + 1   -- invalidates any route still computing in the background
	pf.goal = nil; pf.wps = {}; pf.i = 1; pf.bestGoalD = math.huge
	pf.goalProgAt = os.clock(); pf.hopping = false; pf.markPos = nil; pf.markAt = os.clock()
	if pf.nav then pf.nav.pts = nil end
	-- stop the game walker ONLY if it's still on OUR travel goal -- the game's own
	-- chase (after TC.set) also drives PathWalker and must not be cancelled
	if PW and pf.pwGoal then
		local ok, g = pcall(PW.goal)
		if ok and g and (g - pf.pwGoal).Magnitude < 1 then pcall(PW.stop) end
		pf.pwGoal = nil
	end
end

-- Travel = the game's PathWalker (what quest auto-walk uses): exact routes over the
-- real terrain, ramps and bridges. Our navigator (navTo: PathfindingService +
-- ground-snapped hops) is only the fallback when the walker makes no progress 4s.
-- one ground-snapped teleport step (<=9 studs, under the anti-cheat cap) toward target;
-- snaps from topY down so it lands on the walkable surface along the route
local function hopStep(hrp, target, topY)
	local pos = hrp.Position
	local flat = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
	if flat.Magnitude < 0.5 then return false end
	local hopXZ = pos + flat.Unit * math.min(9, flat.Magnitude)
	HOP_PARAMS.FilterDescendantsInstances = {hrp.Parent, workspace:FindFirstChild("Monsters"), workspace:FindFirstChild("BossFx")}
	local hit = workspace:Raycast(Vector3.new(hopXZ.X, topY, hopXZ.Z), Vector3.new(0, -120, 0), HOP_PARAMS)
	if not hit then return false end
	hrp.CFrame = CFrame.new(hit.Position + Vector3.new(0, 3, 0))
	return true
end

-- Auto Ride: the game's own mount toggle (Mounts:InvokeServer("ride", bool)); the
-- class walk speed is slow, the mount isn't. Throttled; the dodge roll dismounts by itself.
local arenaInfoFwd   -- = arenaInfo (defined further down, with the arena map knowledge)
local lastRideAt = 0
local function ride(want)
	if not (e.phRide and MR) then return end
	local okR, riding = pcall(MR.isRiding)
	if not okR or riding == want then return end
	if want and (plr:GetAttribute("Mount") or "") == "" then return end   -- no mount equipped
	if os.clock() - lastRideAt < 1.5 then return end
	lastRideAt = os.clock()
	pcall(MR.toggle, want)
end

local function pathTo(hum, hrp, goalPos)
	local now = os.clock()
	-- a manual push (walk off a terrace edge / up a ramp) is in progress: don't let the
	-- walker or our own unstick kicks override it with the route that just stalled
	if now < (pf.manualUntil or 0) then
		-- dropped off the terrace: the push did its job, hand back to the walker now
		if pf.manualStartY and hrp.Position.Y < pf.manualStartY - 4 then
			pf.manualUntil = 0; pf.manualStartY = nil
		else
			return
		end
	end
	if flatDist(hrp.Position, goalPos) > 40 then ride(true) end
	-- NAVMAP (user: "เดินติด" / "เอา navmapjson มาใช้จริง"): our own scanned grid of the
	-- field -> A* over ramps/terraces, walked waypoint by waypoint. Runs BEFORE the old arena-exit
	-- push below: that push fired beside snow's arena ramp and drove us into the wall
	-- forever ("เดินติดมุมนี้ประจำ"). Falls through to the old code when there's no map,
	-- no path, or it gave up on this goal.
	if e.phNav and not plr:GetAttribute("DungeonRun") then
		pf.nav = pf.nav or {}
		getgenv().__PHP_NAVST = pf.nav   -- read-only diagnostics handle
		local f = fieldAt(hrp.Position)
		local okN, drove = pcall(Nav.drive, pf.nav, f and f.id, hum, hrp, goalPos)
		if okN and drove then
			if PW and pf.pwGoal then pcall(PW.stop); pf.pwGoal = nil end
			stats.navWalk = (stats.navWalk or 0) + 1
			return
		end
		if not okN then stats.navErr = tostring(drove) end
	end
	-- LEAVING A BOSS ARENA: the plateau's only way down is its StairRamp; the walker
	-- sometimes can't find it from on top. Known route: rim end of the ramp -> down.
	do
		local p0 = hrp.Position
		local ai = arenaInfoFwd and arenaInfoFwd(fieldAt(p0))
		if ai and flatDist(goalPos, ai.center) > ai.radius + 6 then
			local onArena = p0.Y > ai.floorY + 1 and flatDist(p0, ai.center) < ai.radius + 2
			local onRamp = flatDist(p0, ai.bot) + flatDist(p0, ai.top) <= ai.len + 3
				and p0.Y > ai.bot.Y + 1 and p0.Y < ai.floorY + 5
			if onArena or onRamp then
				if PW then pcall(PW.stop) end
				pf.pwGoal = nil
				if onArena and flatDist(p0, ai.top) > 3 then hum:MoveTo(ai.top) else hum:MoveTo(ai.botOut) end
				return
			end
		end
	end
	if not PW or now < (pf.fallbackUntil or 0) then return navTo(hum, hrp, goalPos) end
	local pos = hrp.Position
	if now - (pf.pwLast or 0) > 0.5 then pf.pwMark = pos; pf.pwMarkAt = now; pf.pwKick = nil end   -- stale after a pause
	pf.pwLast = now
	if not pf.pwMark or (pos - pf.pwMark).Magnitude > 3 then pf.pwMark = pos; pf.pwMarkAt = now; pf.pwKick = nil end
	local still = now - (pf.pwMarkAt or now)
	-- Level 1 (1.5s still): the walker only re-issues MoveTo every ~3s per waypoint and
	-- stalls after anything interrupts it (a dodge stop, a terrace lip). Push toward its
	-- own next waypoint ourselves + jump, then restart it with a fresh route. Invisible.
	if still > 1.5 and not pf.pwKick then
		pf.pwKick = now
		local okA, route = pcall(PW.ahead)
		if okA and type(route) == "table" then
			for _, p in ipairs(route) do
				if typeof(p) == "Vector3" and flatDist(p, pos) > 2 then hum:MoveTo(p); break end
			end
		end
		hum.Jump = true
		task.delay(0.6, function()
			if pf.pwGoal == goalPos or not PW.isWalking() then
				pcall(PW.stop); pf.pwGoal = goalPos; pf.pwAt = os.clock()
				pcall(PW.walkTo, goalPos)
			end
		end)
		return
	end
	-- Level 2 (3.5s still): hop a short burst ALONG THE WALKER'S OWN ROUTE (ahead()
	-- = its upcoming waypoints, e.g. up the ramp) -- not straight at the goal through
	-- a cliff -- then let it walk again. No route at all: our navigator, hopping now.
	if still > 3.5 then
		local okA, route = pcall(PW.ahead)
		local nextPt
		if okA and type(route) == "table" then
			for _, p in ipairs(route) do
				if typeof(p) == "Vector3" and Vector3.new(p.X - pos.X, 0, p.Z - pos.Z).Magnitude > 3 then nextPt = p; break end
			end
		end
		if nextPt then
			pf.pwHopUntil = pf.pwHopUntil and pf.pwHopUntil > now and pf.pwHopUntil or now + 1.2
			if now < pf.pwHopUntil then
				if hopStep(hrp, nextPt, math.max(pos.Y, nextPt.Y) + 6) then stats.hops = (stats.hops or 0) + 1 end
				return
			end
			pf.pwHopUntil = nil; pf.pwMarkAt = now; pf.pwKick = nil
			pcall(PW.stop); pf.pwAt = now; pf.pwGoal = goalPos
			pcall(PW.walkTo, goalPos)
			return
		end
		pcall(PW.stop); pf.pwGoal = nil
		pf.fallbackUntil = now + 6; pf.pwMarkAt = now; pf.pwKick = nil; pf.forceHop = true
		return navTo(hum, hrp, goalPos)
	end
	local okG, g = pcall(PW.goal)
	g = okG and g or nil
	if not PW.isWalking() or not g or (g - goalPos).Magnitude > 8 then
		if now - (pf.pwAt or 0) > 0.6 then
			pf.pwAt = now; pf.pwGoal = goalPos
			pcall(PW.walkTo, goalPos)
		end
	end
end
-- Height gap that means "not on the same floor" (target on a plateau/terrace above
-- or below us). Same-floor gaps are ~2-6 (root heights differ); a 12-stud plateau
-- reads ~15. Past this we must PATHFIND (via the ramp), never MoveTo straight at it.
local FLOOR_GAP = 9

-- Travel with the game's auto OFF (so it doesn't fight our MoveTo and stutter),
-- then switch it ON only once we're on top of the monster. Re-issue MoveTo only
-- when the goal shifts, so the walk is smooth instead of restarting every tick.
-- The game's AUTO (TC.auto) drives auto-target picking AND auto skill casting
-- (CombatController reads it) and tells the server (AutoState). So for every fight it
-- stays ON and we set the target like a player click (TC.set) -- the game then
-- chases it with its own PathWalker (any distance), shoots, and casts skills.
-- What broke attacks before was TOGGLING it every travel/dodge tick: setAuto(false)
-- clears the target + tells the server to stop. Now it only goes OFF for walks to a
-- non-monster spot (warp stone, farm spot, loot) so auto doesn't wander off to hit
-- random monsters on the way -- a few toggles a minute, not every tick.
local function setAuto(want)
	if want then
		if TC.auto ~= true then pcall(TC.setAuto, true) end
	elseif TC.auto == true then
		pcall(TC.setAuto, false)
	end
end

-- ------------------------------------------------------- auto field boss
-- Each field has one boss (Zones.fields[].boss); it spawns at the field's arena
-- and appears in workspace.Monsters as an IsBoss model with that MonsterId. Pick
-- which to fight; when a chosen one is up in OUR field, go kill it, then walk back
-- to the saved farm spot and keep farming until it (or another) respawns.
local FIELD_BOSSES, BOSS_LABEL, BOSS_LV = {}, {}, {}
local function buildFieldBosses()
	if #FIELD_BOSSES > 0 then return end
	local okZ, Z = pcall(require, RS.Shared.Config.Zones)
	local okM, M = pcall(require, RS.Shared.Config.Monsters)
	if not (okZ and okM) then return end
	-- build from openFields (all 12 biomes, not just the 7 in Z.fields) so the boss
	-- dropdown is complete through Volcano Valley, not cut off at Moon Base.
	for _, f in ipairs(openFields(Z)) do
		local bid = f.boss
		if bid and not BOSS_LV[bid] then
			local d = (M.defs or {})[bid] or {}
			local name = d.name or bid
			local lv = tonumber(d.level) or (f.levels and f.levels[2]) or 0
			local label = ("%s · Lv%d (%s)"):format(name, lv, f.name or f.id)
			table.insert(FIELD_BOSSES, {fieldId = f.id, bossId = bid, name = name, lv = lv, label = label,
				respawn = tonumber(d.respawn) or 600})
			BOSS_LABEL[bid] = label
			BOSS_LV[bid] = lv
		end
	end
end
buildFieldBosses()

-- ------------------------------------------------------------- auto-warp
-- Cross-field travel: the game warps you by firing Net.event("Warp"):FireServer(fieldId)
-- while you STAND ON a WarpStone (verified: fire it >6 studs away = nothing; on the
-- stone = teleports). Destinations are gated by Zones.gateBlock (level/boss) and cost
-- Gold. This gets us to the right field -- and recovers after a death dumps us in town.
local Net = require(RS.Shared.Net)
local function beatBoss(bid) return plr:GetAttribute("Beat_" .. tostring(bid)) == true end
-- A WarpStone is an 8.3-wide Platform with a SOLID 2.4-wide Obelisk in the middle and
-- corner posts. We used to walk at the obelisk's center -- a point INSIDE a solid part,
-- so both PathWalker and PathfindingService returned no path and we fell back to a
-- straight MoveTo into whatever cliff was in the way (stood stuck for minutes). Now we
-- walk to the platform edge facing us: 3.3 from the obelisk, on the platform top,
-- between the corner posts -- reachable, and still inside the ~6-stud warp range.
local WARP_STONES = {}         -- {center = obelisk pos, topY = platform top} (static)
local warpStonesAt = 0
local function warpStones()
	if os.clock() - warpStonesAt < 8 and #WARP_STONES > 0 then return WARP_STONES end
	warpStonesAt = os.clock()
	WARP_STONES = {}
	for _, m in ipairs(workspace:GetDescendants()) do
		if m.Name == "Obelisk" and m:IsA("BasePart") then
			local topY = -math.huge   -- highest Platform top (the inner slab you stand on)
			for _, s in ipairs(m.Parent and m.Parent:GetChildren() or {}) do
				if s.Name == "Platform" and s:IsA("BasePart") then topY = math.max(topY, s.Position.Y + s.Size.Y / 2) end
			end
			if topY == -math.huge then topY = m.Position.Y - m.Size.Y / 2 end
			WARP_STONES[#WARP_STONES + 1] = {center = m.Position, topY = topY}
		end
	end
	return WARP_STONES
end
-- returns: stand point (walk target), distance from us to the obelisk center
local function nearestStone(pos)
	local best, bestD
	-- NavMap on: THIS field's stone (any stone warps anywhere). The nearest one is often
	-- across a bridge whose LevelGate we can't walk through -> jittered at the bridge end
	-- for minutes (walkwatch: wizard/splash/snow "ไปหินวาร์ป ... ห่าง 93/145").
	local here = e.phNav and fieldAt(pos)
	for _, s in ipairs(warpStones()) do
		local d = (s.center - pos).Magnitude
		if here then
			local sf = fieldAt(s.center)
			if not (sf and sf.id == here.id) then d = d + 100000 end
		end
		if not best or d < bestD then best, bestD = s, d end
	end
	if best and bestD >= 100000 then bestD = (best.center - pos).Magnitude end
	if not best then return nil, nil end
	local c = best.center
	local dx, dz = pos.X - c.X, pos.Z - c.Z
	local side = (math.abs(dx) >= math.abs(dz)) and Vector3.new(dx >= 0 and 3.3 or -3.3, 0, 0)
		or Vector3.new(0, 0, dz >= 0 and 3.3 or -3.3)
	return Vector3.new(c.X + side.X, best.topY, c.Z + side.Z), bestD
end
local function fieldUnlocked(fid)
	if fid == "town" then return true end
	local okZ, Z = pcall(require, RS.Shared.Config.Zones)
	if not okZ then return false end
	local field
	for _, f in ipairs(openFields(Z)) do if f.id == fid then field = f break end end
	if not field then return false end
	local myLv = tonumber(plr:GetAttribute("Level")) or 1
	local ok, block = pcall(Z.gateBlock, field, myLv, beatBoss)
	if not ok or block ~= nil then return false end
	local w = Z.warpById and Z.warpById[fid]
	local gold = tonumber(plr:GetAttribute("Gold")) or 0
	return (not w) or gold >= (tonumber(w.gold) or 0)
end
local function isCombatField(fid)
	if not fid or fid == "town" then return false end
	local okZ, Z = pcall(require, RS.Shared.Config.Zones)
	if not okZ then return false end
	for _, f in ipairs(openFields(Z)) do if f.id == fid and f.levels then return true end end
	return false
end
-- Which field should we be in right now? (curId = the field we're standing in)
-- workspace.Monsters holds every field's monsters (streaming only drops their parts),
-- so a selected boss being alive can be checked from anywhere on the map.
local function bossAlive(bid)
	for _, m in ipairs(workspace.Monsters:GetChildren()) do
		if m:GetAttribute("IsBoss") == true and m:GetAttribute("MonsterId") == bid
			and (tonumber(m:GetAttribute("Health")) or 0) > 0 then return true end
	end
	return false
end
local function farmSpotField()
	local fp = e.phFarmPos
	if type(fp) ~= "table" or not fp.x then return nil end
	local f = fieldAt(Vector3.new(fp.x, fp.y, fp.z))
	return f and f.id
end
local wbWantedFwd   -- = wbWanted (world boss section below)
local function wantedField(curId)
	if not e.phAutoWarp then return nil end
	local myLv = tonumber(plr:GetAttribute("Level")) or 1
	-- 0) Auto World Boss: announced ("soon") or live world boss that passes the
	--    filters -> its field, ahead of everything else (it's rare and timed)
	if wbWantedFwd then
		local w = wbWantedFwd()
		if w and w.field and (w.field == curId or fieldUnlocked(w.field)) then return w.field end
	end
	-- 1) Auto Field Boss: a selected boss is UP (and my level is enough) -> its field.
	--    One in the field we're already in wins.
	if e.phBossOn and type(e.phBossPick) == "table" then
		local pick
		for _, b in ipairs(FIELD_BOSSES) do
			if e.phBossPick[b.label] and bossAlive(b.bossId)
				and ((not e.phBossWaitLv) or myLv >= (b.lv or 0)) and fieldUnlocked(b.fieldId) then
				if b.fieldId == curId then return curId end
				pick = pick or b.fieldId
			end
		end
		if pick then return pick end
	end
	-- 2) A farm spot is set: that's HOME. Go back to its field (warp if needed) and
	--    farm only there (user: "ตีเฉพาะบอส และมอนตรงจุดที่มาร์ค" -- it was left
	--    roaming Neon City while the spot was in Volcano).
	local home = farmSpotField()
	if home and (home == curId or fieldUnlocked(home)) then return home end
	-- 3) Boss mode, no spot: wait in a selected boss's field.
	if e.phBossOn and type(e.phBossPick) == "table" then
		for _, b in ipairs(FIELD_BOSSES) do
			if e.phBossPick[b.label] and fieldUnlocked(b.fieldId) then return b.fieldId end
		end
	end
	-- 2) Already in a real combat field -> STAY. Never zone-hop on my own just
	--    because levelling unlocked a harder field (user: "กลัวมันไปติดโซนถัดไป").
	--    Warping then only happens to RECOVER after a death dumps us in town.
	if isCombatField(curId) then return curId end
	-- 3) Not in a field (died -> town, etc.): go to the highest unlocked combat
	--    field I'm high enough for -- i.e. back to where I was farming.
	local myLv = tonumber(plr:GetAttribute("Level")) or 1
	local okZ, Z = pcall(require, RS.Shared.Config.Zones)
	if okZ then
		local best
		for _, f in ipairs(openFields(Z)) do
			if f.id ~= "town" and f.levels and myLv >= f.levels[1] and fieldUnlocked(f.id) then
				best = f.id
			end
		end
		return best
	end
	return nil
end
local lastWarpFire = 0
-- read-only diagnostics handle
getgenv().__PHP_DBG = {wantedField = wantedField, fieldUnlocked = fieldUnlocked, farmSpotField = farmSpotField,
	bossAlive = bossAlive, e = e, FIELD_BOSSES = FIELD_BOSSES}

-- World bosses: rarer event bosses (WorldBoss config, every ~30 min). A live one
-- is a monster in workspace.Monsters carrying a WorldBoss attribute + MonsterId.
-- They can be anywhere, so (unlike field bosses) we don't restrict to our field.
local WB_LABEL = {}        -- both "wb_<id>" (live MonsterId) and "<id>" -> display name
local WORLD_BOSSES = {}
local FIELDS = {}          -- {id, name, label} per field, for the world-boss field picker
local FIELD_NAME = {}      -- fieldId -> plain display name (for ArenaCenter->field match)
local FIELD_LABEL = {}     -- fieldId -> picker label (name + level range)
local WB_LEVEL = 99        -- world bosses scale to ~ maxFieldLevel + levelOver
local function buildWorldBosses()
	if #WORLD_BOSSES > 0 then return end
	local okZ, Z = pcall(require, RS.Shared.Config.Zones)
	local maxLv = 0
	if okZ then
		for _, f in ipairs(Z.allFields or Z.fields or {}) do -- allFields = all 12 biomes
			local hi = f.levels and f.levels[2] or 0
			maxLv = math.max(maxLv, tonumber(hi) or 0)
			local name = f.name or f.id
			FIELD_NAME[f.id] = name
			local flabel = (f.levels and f.levels[1]) and ("%s (Lv%d-%d)"):format(name, f.levels[1], f.levels[2]) or name
			FIELD_LABEL[f.id] = flabel
			table.insert(FIELDS, {id = f.id, name = name, label = flabel})
		end
	end
	local okWB, WB = pcall(require, RS.Shared.Config.WorldBoss)
	if okWB then
		WB_LEVEL = maxLv + (tonumber(WB.levelOver) or 3)
		if type(WB.byId) == "table" then
			for id, d in pairs(WB.byId) do
				local name = (type(d) == "table" and d.name) or id
				local label = ("%s · Lv~%d"):format(name, WB_LEVEL)
				table.insert(WORLD_BOSSES, {id = id, name = name, label = label})
				WB_LABEL[id] = name          -- config id
				WB_LABEL["wb_" .. id] = name -- live monster MonsterId is prefixed "wb_"
			end
		end
	end
end
buildWorldBosses()

-- A live world boss (WorldBoss attribute) worth fighting. Two optional filters,
-- so you can target by boss name, by WHICH MAP it spawned in, or both:
--   phWBPick   -- empty = any boss name
--   phWBFields -- empty = any field; else only engage one whose spawn map is picked
-- The boss dropdown stores LABELS ("The Clover Queen · Lv~102") but we look bosses up
-- by NAME ("The Clover Queen"): compare by label prefix. (Before, the two never matched,
-- so picking bosses filtered EVERY world boss out -- "it spawned but didn't go".)
local function wbNamePicked(name)
	if type(e.phWBPick) ~= "table" or next(e.phWBPick) == nil then return true end
	if not name then return false end
	for label, on in pairs(e.phWBPick) do
		if on and (label == name or label:sub(1, #name) == name) then return true end
	end
	return false
end
-- map filter: the server says which field it landed in (WorldBossField); the model's
-- own position/ArenaCenter doesn't resolve to the right field (read as "town")
local function wbFieldPicked(fieldId)
	if type(e.phWBFields) ~= "table" or next(e.phWBFields) == nil then return true end
	return fieldId ~= nil and e.phWBFields[FIELD_LABEL[fieldId] or fieldId] == true
end
local function findWorldBoss(hrp)
	if not e.phWBOn then return nil end
	local wbField = game:GetService("ReplicatedStorage"):GetAttribute("WorldBossField")
	local best, bestD
	for _, m in ipairs(workspace.Monsters:GetChildren()) do
		if m.PrimaryPart and m:GetAttribute("WorldBoss") and (tonumber(m:GetAttribute("Health")) or 0) > 0 then
			local name = WB_LABEL[m:GetAttribute("MonsterId")] or m.Name
			local okName = wbNamePicked(name) or wbNamePicked(m.Name)
			local okField = wbFieldPicked(wbField)
			if okName and okField then
				local dd = (m.PrimaryPart.Position - hrp.Position).Magnitude
				if not best or dd < bestD then best, bestD = m, dd end
			end
		end
	end
	return best
end

local needReturn = false
local engagingBoss = false
local engagingFarm = false
local bossDeadAt = {}  -- bossId -> os.time() of last death (to estimate respawn)
local bossWasUp = {}   -- bossId -> was alive last status tick
-- A selected field boss that's alive and in the SAME field as us (so it's
-- walkable; cross-field needs a warp we don't do here). Nearest first.
local function findBossTarget(hrp)
	if not (e.phBossOn and type(e.phBossPick) == "table") then return nil end
	local myField = fieldAt(hrp.Position)
	local myId = myField and myField.id
	local myLv = tonumber(plr:GetAttribute("Level")) or 1
	local best, bestD
	for _, m in ipairs(workspace.Monsters:GetChildren()) do
		if m.PrimaryPart and m:GetAttribute("IsBoss") == true and (tonumber(m:GetAttribute("Health")) or 0) > 0 then
			local bid = m:GetAttribute("MonsterId")
			local label = BOSS_LABEL[bid]
			-- A boss the user EXPLICITLY picked in this dropdown is always fought, beaten
			-- or not (farming its drops is the point). The "skip beaten" toggle only
			-- applies to Auto Farm's "ตีบอสฟิลด์ด้วย" unlock mode -- before, it silently
			-- vetoed every pick for a max-level player who has beaten them all.
			if label and e.phBossPick[label] then
				-- level gate: keep farming until I reach the boss's level, then engage.
				-- the boss's own Level attr wins; fall back to the config level.
				local bossLv = tonumber(m:GetAttribute("Level")) or BOSS_LV[bid] or 0
				if (not e.phBossWaitLv) or myLv >= bossLv then
					local mf = fieldAt(m.PrimaryPart.Position)
					if not myId or (mf and mf.id == myId) then
						local dd = (m.PrimaryPart.Position - hrp.Position).Magnitude
						if not best or dd < bestD then best, bestD = m, dd end
					end
				end
			end
		end
	end
	return best
end

-- ------------------------------------------------------------- auto dodge
-- Bosses (and some monsters) telegraph every skill with a BossCast event before it
-- lands: {id, windup (0.7-2.8s, shorter when enraged), shape, arena, shapes = list of
--   line   {center, dir, length, width}   -- strip starting at center along dir
--   circle {center, radius} / ring {center, radius, inner (safe hole)}
--   safe   {center, radius}                -- shape "shelter": ONLY these are safe
-- }; a BossHit with the same id fires when it lands. shape "stack" (follows a player,
-- "stand together to share the hit") is a shared hit, not something to dodge.
-- We wrap BossFx.play (the client calls it for every one of these) to record them,
-- and a fast loop walks us to the nearest safe spot on the SAME floor (never off the
-- arena plateau), dash-rolling (the game's own dodge) when walking won't make it.
-- The main loop yields movement to this while `dodging` is set.
local RunService = game:GetService("RunService")
local hazards = {}
local dodging = false
-- Everything tuned for the crypt boss (wider margins, pools, marks, stars, towers,
-- channels, shrink ring, per-frame dodge...) is gated on this: field / world boss
-- (Auto Boss) keeps its original, proven dodge behaviour untouched.
local function inDG() return plr:GetAttribute("DungeonRun") ~= nil end
-- channel casts (Requiem / Soul Harvest: "Hit it hard to break the charge!"): unbroken
-- they land a 5x hit + 5-6s STUN -- the stun is what got us killed. Until this clock
-- runs out the dungeon logic pours everything into the boss.
local dgChannelUntil = 0
local fightFocus = nil   -- the boss model we're fighting: its LIVE position bounds the dodge
-- the circle that boss is tied to ({center, radius}): world boss = WorldBossSpot r42
-- (WorldBoss.arena), field boss = its ArenaFloor r40. Leave it (or drag the boss out
-- of it) and the boss leashes back to full HP -- so we never stand, dodge, or chase
-- helpers outside it.
local fightArena = nil
-- Shrinking ring (BossPhase kind "shrink": center, from -> to over `over` s): the
-- longer the fight, the smaller the safe circle; outside it ticks damage. Crypt boss:
-- at 45% HP, down to r20 over 80s. Live radius = the ring's inner edge right now.
local shrinkZone = nil
local function shrinkRadius()
	local z = shrinkZone
	if not z then return nil end
	if os.clock() - z.t0 > (z.over or 0) + 240 then shrinkZone = nil; return nil end   -- stale
	local k = math.clamp((os.clock() - z.t0) / math.max(z.over or 1, 0.1), 0, 1)
	return z.from + (z.to - z.from) * k, z.center
end
local SHRINK_MARGIN = 2
local function inFightArena(p, margin)
	if inDG() then
		local r, c = shrinkRadius()
		if r and flatDist(p, c) > r - SHRINK_MARGIN - (margin or 0) then return false end
	end
	if not fightArena then return true end
	return flatDist(p, fightArena.center) <= fightArena.radius - (margin or 0)
end
local DODGE_MARGIN = 2.5      -- field / world boss (original)
local DODGE_MARGIN_DG = 3.5   -- dungeon: server judges position late, hits come in chains
local relaxMargin = nil       -- set for a second, tighter escape search when none was found
pcall(function()
	local BF = require(plr.PlayerScripts.Client.Controllers.BossFx)
	if not getgenv().__PHP_BFPLAY_ORIG then   -- wrap ONCE; reloads only swap the callback
		local orig = BF.play
		getgenv().__PHP_BFPLAY_ORIG = orig
		BF.play = function(kind, data, ...)
			local cb = getgenv().__PHP_ONCAST
			if cb then pcall(cb, kind, data) end
			return orig(kind, data, ...)
		end
	end
end)
local okMC, MoveCtl = pcall(require, plr.PlayerScripts.Client.Controllers.MoveController)
getgenv().__PHP_ONCAST = function(kind, data)
	if not alive() or type(data) ~= "table" then return end
	-- diagnostics ring buffer (getgenv().__PHP_CASTLOG): what was cast, where we stood
	pcall(function()
		if kind ~= "BossCast" and kind ~= "BossLock" and kind ~= "BossHit" and kind ~= "BossPhase" then return end
		local log = getgenv().__PHP_CASTLOG or {}
		getgenv().__PHP_CASTLOG = log
		local _, _, r0 = myChar()
		local nf, myd, near = 0, nil, nil
		for _, s in ipairs(type(data.shapes) == "table" and data.shapes or {}) do
			if type(s) == "table" then
				if s.follow then nf = nf + 1 end
				if r0 and typeof(s.center) == "Vector3" then
					local d = flatDist(s.center, r0.Position) - (tonumber(s.radius) or 0)
					near = math.min(near or math.huge, d)
					if s.follow == plr.UserId then myd = flatDist(s.center, r0.Position) end
				end
			end
		end
		if not near or near > 150 then return end   -- other parties' runs broadcast too
		local _, h0 = myChar()
		local vel = r0 and Vector3.new(r0.AssemblyLinearVelocity.X, 0, r0.AssemblyLinearVelocity.Z).Magnitude or 0
		log[#log + 1] = ("%.2f v=%.0f ws=%s goal=%s %s %s/%s id=%s wu=%s n=%d fol=%d myd=%s edge=%s hp=%s seal=%s dodge=%s"):format(os.clock(),
			vel, h0 and tostring(math.floor(h0.WalkSpeed)) or "-", tostring(getgenv().__PHP_DGOAL and r0 and math.floor(flatDist(getgenv().__PHP_DGOAL, r0.Position)) or "-"), kind,
			tostring(data.shape or data.kind), tostring(data.name), tostring(data.id), tostring(data.windup),
			type(data.shapes) == "table" and #data.shapes or 0, nf, myd and ("%.1f"):format(myd) or "-",
			("%.1f"):format(near), h0 and h0.MaxHealth > 0 and ("%d%%"):format(h0.Health / h0.MaxHealth * 100) or "-",
			tostring((tonumber(plr:GetAttribute("SealedUntil")) or 0) > workspace:GetServerTimeNow()), tostring(dodging))
		if #log > 200 then table.remove(log, 1) end
	end)
	-- every party's boss phases are broadcast server-wide: only OUR room's ring counts
	-- (another run's shrink/clear was overwriting ours -> we walked out of the real ring)
	if kind == "BossPhase" and data.kind == "shrink" and typeof(data.center) == "Vector3" then
		local _, _, rS = myChar()
		if rS and flatDist(data.center, rS.Position) < 150 then
			shrinkZone = {center = data.center, from = tonumber(data.from) or 60, to = tonumber(data.to) or 20,
				over = tonumber(data.over) or 60, t0 = os.clock(), model = data.model}
		end
		return
	elseif kind == "BossClear" then
		if shrinkZone and shrinkZone.model ~= nil and data.model == shrinkZone.model then shrinkZone = nil end
		return
	end
	if kind == "BossCast" and type(data.shapes) == "table" then
		if data.shape == "stack" then return end
		local _, _, hrp = myChar()
		if not hrp then return end
		local near = false
		for _, s in ipairs(data.shapes) do
			if typeof(s.center) == "Vector3" and flatDist(s.center, hrp.Position) < 120
				and math.abs(s.center.Y - hrp.Position.Y) < 30 then near = true; break end
		end
		if not near then return end
		local impact = os.clock() + (tonumber(data.windup) or 1)
		local tEnd = impact + 0.35
		-- channel (Requiem / Soul Harvest: the big slow red circle): NOT dodged (user: "วง
		-- แดงใหญ่ๆ ที่มันนานๆ ไม่ต้องหลบ ยืนตีคุ้มกว่า") -- stand and pour damage into the boss
		local dg = inDG()
		if dg and data.shape == "channel" then dgChannelUntil = impact + 0.2; return end
		-- "puddles" (Grave Mist etc.): the green pools STAY on the floor for `duration`
		-- (20s on the crypt boss) ticking damage -- they must stay a hazard that long, or
		-- we walk straight back into them the moment they land
		local persist = dg and data.shape == "puddles"
		if persist then tEnd = impact + (tonumber(data.duration) or 20) + 0.5 end
		-- "mark"-style casts FOLLOW a player during the windup (shape.follow = UserId)
		-- and lock `lock` seconds before landing (Lantern Hex: 0.75s, and it SEALS potions
		-- for 5s). Snapshot the circle exactly when the game locks it, so we get the whole
		-- 0.75s to get out instead of a hopeless 0.45s.
		local followMe = false
		for _, s in ipairs(data.shapes) do if s.follow == plr.UserId then followMe = true end end
		local arena = type(data.arena) == "table" and typeof(data.arena.center) == "Vector3"
			and {center = data.arena.center, radius = tonumber(data.arena.radius) or 40} or nil
		local shapes = {}   -- own copies: the lock rewrites centres, the game's fx keep theirs
		for i, s in ipairs(data.shapes) do shapes[i] = type(s) == "table" and table.clone(s) or s end
		hazards[data.id or os.clock()] = {shapes = shapes, shape = data.shape,
			boss = typeof(data.boss) == "Vector3" and data.boss or nil, arena = arena,
			tEnd = tEnd, impact = impact, followMe = followMe, persist = persist,
			tLock = dg and (impact - math.max(tonumber(data.lock) or 0.75, 0.5)) or (tEnd - 0.35 - 0.45)}
	elseif kind == "BossLock" and data.id ~= nil and inDG() then
		-- the server's own lock: exact final centres of the follow-marks (Lantern Hex)
		local h = hazards[data.id]
		if h then
			for i, s in ipairs(type(data.shapes) == "table" and data.shapes or {}) do
				if h.shapes[i] and typeof(s.center) == "Vector3" then h.shapes[i].center = s.center end
			end
			h.locked = true
		end
	elseif kind == "BossHit" and data.id ~= nil then
		local h = hazards[data.id]
		if h and not h.persist then h.tEnd = math.min(h.tEnd, os.clock() + 0.15) end
		-- pools land here: (re)register them for their full lifetime even if we missed
		-- the cast (joined the room mid-skill / were out of the 120-stud window)
		if inDG() and data.shape == "puddles" and type(data.shapes) == "table" then
			local life = os.clock() + (tonumber(data.duration) or 20) + 0.5
			if h then h.tEnd = math.max(h.tEnd, life); h.persist = true
			else
				hazards[data.id] = {shapes = data.shapes, shape = "puddles", persist = true, tEnd = life,
					boss = typeof(data.boss) == "Vector3" and data.boss or nil}
			end
		end
	end
end
local function shapeHits(s, p, extra)
	if typeof(s.center) ~= "Vector3" then return false end
	local DODGE_MARGIN = relaxMargin or (inDG() and DODGE_MARGIN_DG or DODGE_MARGIN)
	local k = s.kind
	if k == "line" then
		if typeof(s.dir) ~= "Vector3" then return false end
		local d = Vector3.new(s.dir.X, 0, s.dir.Z)
		if d.Magnitude < 0.01 then return false end
		d = d.Unit
		local v = Vector3.new(p.X - s.center.X, 0, p.Z - s.center.Z)
		local along = v:Dot(d)
		if along < -DODGE_MARGIN or along > (tonumber(s.length) or 0) + DODGE_MARGIN then return false end
		return (v - d * along).Magnitude < (tonumber(s.width) or 6) / 2 + DODGE_MARGIN
	elseif k == "safe" or k == "tower" then
		return false
	end
	local dd = flatDist(p, s.center)   -- circle / ring / arena-wide disc
	if dd > (tonumber(s.radius) or 0) + DODGE_MARGIN + (extra or 0) then return false end
	if k == "ring" and dd < (tonumber(s.inner) or 0) - DODGE_MARGIN then return false end
	return true
end
local function hazardHits(h, p)
	if h.followMe and not h.locked then return false end   -- still tracking us: not yet
	if h.shape == "shelter" then   -- everything is lethal except inside a safe circle
		for _, s in ipairs(h.shapes) do
			if s.kind == "safe" and typeof(s.center) == "Vector3"
				and flatDist(p, s.center) < (tonumber(s.radius) or 0) - 1.5 then return false end
		end
		return true
	end
	-- Tomb Wards ("Stand in the tombs, or everyone gets hit!"): safe ONLY inside a tomb
	local dg = inDG()
	if dg and h.shape == "towers" then
		for _, s in ipairs(h.shapes) do
			if typeof(s.center) == "Vector3" and flatDist(p, s.center) < (tonumber(s.radius) or 5) - 1.5 then return false end
		end
		return true
	end
	-- marks: the server judges our position ~0.15s late -> clear them by a wider margin
	local extra = (dg and h.shape == "mark") and 3 or 0
	for _, s in ipairs(h.shapes) do if shapeHits(s, p, extra) then return true end end
	return false
end
local function safeEverywhere(p)
	for _, h in pairs(hazards) do if hazardHits(h, p) then return false end end
	return true
end
local function sameFloor(p, refY)
	HOP_PARAMS.FilterDescendantsInstances = {plr.Character, workspace:FindFirstChild("Monsters"), workspace:FindFirstChild("BossFx")}
	local hit = workspace:Raycast(Vector3.new(p.X, refY + 6, p.Z), Vector3.new(0, -14, 0), HOP_PARAMS)
	return hit and math.abs(hit.Position.Y + 3 - refY) < 4
end
-- Boss fights happen inside the arena circle (BossCast.arena {center, radius}); leaving
-- it drags us out of range and the boss leashes/resets. So an escape spot must stay
-- INSIDE the arena (3-stud margin) and is scored to stay within attack range of the
-- boss. If no safe spot exists inside the circle we return nil = take the hit and keep
-- attacking (user: "ถ้าหลบไม่ได้ ก็ยอมโดนสกิลไป").
local ATTACK_RANGE = 38    -- Archer attackRange (Classes.defs); refreshed below per class
pcall(function()
	local Classes = require(RS.Shared.Config.Classes)
	local d = (Classes.defs or Classes)[plr:GetAttribute("Class") or ""]
	if d and tonumber(d.attackRange) then ATTACK_RANGE = tonumber(d.attackRange) end
end)
local function findEscape(pos, bossPos, prefDir)
	local dg = inDG()
	if not dg or (prefDir and prefDir.Magnitude < 0.3) then prefDir = nil end
	local starOn = false
	for _, h in pairs(hazards) do
		if dg and h.shape == "star" then
			starOn = true
			if not bossPos then
				bossPos = typeof(h.boss) == "Vector3" and h.boss
					or (h.shapes[1] and typeof(h.shapes[1].center) == "Vector3" and h.shapes[1].center) or nil
			end
		end
	end
	local arena
	for _, h in pairs(hazards) do if h.arena then arena = h.arena; break end end
	local best, bestScore
	-- HARD limit (not just a score): stay well inside attack range of the boss's live
	-- position, or the boss loses us and leashes back to full HP
	local keepIn = dg and math.max(ATTACK_RANGE + 4, 16) or math.max(ATTACK_RANGE - 8, 16)
	local function try(c, extra)
		if arena and flatDist(c, arena.center) > arena.radius - 3 then return end
		if not inFightArena(c, dg and 1 or 3) then return end
		if bossPos and flatDist(c, bossPos) > keepIn then return end
		if safeEverywhere(c) and sameFloor(c, pos.Y) then
			local score = flatDist(pos, c) + (extra or 0) + (bossPos and flatDist(c, bossPos) * 0.25 or 0)
			-- STAR (Spirit Star / Eclipse: 8-12 spokes out of the boss): the gaps between
			-- spokes only open up far from the boss -- prefer spots well away from it
			if starOn and bossPos then score = score - math.min(flatDist(c, bossPos), 30) * 0.8 end
			if prefDir then   -- already running: keep the momentum, don't turn around
				local v = Vector3.new(c.X - pos.X, 0, c.Z - pos.Z)
				if v.Magnitude > 0.5 then score = score + (1 - prefDir.Unit:Dot(v.Unit)) * 4 end
			end
			if not best or score < bestScore then best, bestScore = c, score end
		end
	end
	for _, h in pairs(hazards) do
		-- channel (Requiem / Soul Harvest): a 5x hit + 5s stun on everyone inside. The boss
		-- stands still while it charges, so get OUT past its edge even beyond our usual
		-- arena clamp (no drag: it isn't following) -- the floor check keeps us in the room
		if dg and h.shape == "channel" then
			for _, s in ipairs(h.shapes) do
				if typeof(s.center) == "Vector3" and tonumber(s.radius) then
					for a = 0, 23 do
						local ang = a * math.pi / 12
						local c = Vector3.new(s.center.X + math.cos(ang) * (s.radius + 4), pos.Y, s.center.Z + math.sin(ang) * (s.radius + 4))
						local sr, sc = shrinkRadius()
						if (not sr or flatDist(c, sc) <= sr - SHRINK_MARGIN) and safeEverywhere(c) and sameFloor(c, pos.Y) then
							local score = flatDist(pos, c)
							if not best or score < bestScore then best, bestScore = c, score end
						end
					end
				end
			end
		end
	end
	if best then return best end
	for _, h in pairs(hazards) do   -- shelter / tombs: the safe circles themselves
		if dg and (h.shape == "shelter" or h.shape == "towers") then
			for _, s in ipairs(h.shapes) do
				if (s.kind == "safe" or h.shape == "towers") and typeof(s.center) == "Vector3" then
					local c = Vector3.new(s.center.X, pos.Y, s.center.Z)
					-- the game put it there: skip OUR arena clamp / boss-range limit, keep
					-- only the shrinking ring and the "is it actually safe" checks
					local sr, sc = shrinkRadius()
					if (not sr or flatDist(c, sc) <= sr - SHRINK_MARGIN) and safeEverywhere(c) then
						local score = flatDist(pos, c)
						if not best or score < bestScore then best, bestScore = c, score end
					end
				end
			end
		elseif not dg and h.shape == "shelter" then   -- field / world boss: original logic
			for _, s in ipairs(h.shapes) do
				if s.kind == "safe" and typeof(s.center) == "Vector3" then try(Vector3.new(s.center.X, pos.Y, s.center.Z)) end
			end
		end
	end
	if best then return best end
	for _, r in ipairs(dg and {5, 8, 11, 14, 17, 22, 30} or {5, 8, 12, 16, 22, 30}) do   -- nearest ring that has a safe spot
		for a = 0, 15 do
			local ang = a * math.pi / 8
			try(pos + Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r))
		end
		if best then return best end
	end
	return nil
end
-- The dodge goal is re-issued EVERY FRAME: the game's TargetController re-plants us
-- (MoveTo(own pos) on target/range changes) between our 0.05s ticks, and a single
-- MoveTo got us ~5 studs in 0.75s instead of the 16 a held order gives.
local dodgeGoal = nil
getgenv().__PHP_DBG = {hazards = hazards, hazardHits = hazardHits, findEscape = findEscape,
	safeEverywhere = safeEverywhere, inFightArena = inFightArena, shrinkRadius = shrinkRadius,
	arena = function() return fightArena end}
do
	local dodgeHB
	dodgeHB = RunService.Heartbeat:Connect(function()
		if not alive() then dodgeHB:Disconnect(); return end
		getgenv().__PHP_DGOAL = dodging and dodgeGoal or nil
		if dodging and dodgeGoal then
			local _, h = myChar()
			if h then h:MoveTo(dodgeGoal) end
		end
	end)
end
task.spawn(function()
	local lastRoll = 0
	while alive() do
		task.wait(0.05)
		local now = os.clock()
		stats.dodgeTick = now
		if not dodging then dodgeGoal = nil end
		for id, h in pairs(hazards) do if now > h.tEnd then hazards[id] = nil end end
		if not e.phDodge or not next(hazards) then dodging = false; continue end
		local _, hum, hrp = myChar()
		if not hrp then dodging = false; continue end
		local pos = hrp.Position
		for _, h in pairs(hazards) do   -- lock follow-marks at our spot just before impact
			if h.followMe and not h.locked and now >= h.tLock then
				h.locked = true
				for _, s in ipairs(h.shapes) do
					if s.follow == plr.UserId then s.center = Vector3.new(pos.X, s.center and s.center.Y or pos.Y, pos.Z) end
				end
			end
		end
		local dg = inDG()
		local soonest, bossPos, urgent = nil, nil, false
		for _, h in pairs(hazards) do
			if hazardHits(h, pos) then
				if dg and h.shape == "mark" then urgent = true end   -- seals potions: always roll out
				-- time to the actual impact (tEnd carries slack; pools have none)
				local left = (dg and h.impact and not h.persist and now < h.impact) and (h.impact - now) or (h.tEnd - now)
				soonest = math.min(soonest or math.huge, left)
				bossPos = bossPos or h.boss
			end
		end
		-- Star up and we're close to the boss: back off even if no spoke is on us right
		-- now -- the follow-up star (rotated half a step) lands in today's gaps, and
		-- near the boss there is no gap wide enough to stand in
		if dg and not soonest then
			for _, h in pairs(hazards) do
				local bp = typeof(h.boss) == "Vector3" and h.boss or (h.shapes[1] and typeof(h.shapes[1].center) == "Vector3" and h.shapes[1].center)
				if h.shape == "star" and bp and flatDist(pos, bp) < 20 and h.impact and now < h.impact + 1.2 then
					soonest = math.max(h.impact - now, 0.3); bossPos = bp
					break
				end
			end
		end
		-- A mark is FOLLOWING us and about to lock: be already running when it locks, so
		-- after the lock we only need the last ~11 studs with full speed (+ the roll)
		-- instead of starting from a standstill. Run along the arena, away from danger.
		if dg and not soonest then
			local preLock = false
			for _, h in pairs(hazards) do
				-- whole windup: be at full speed by the lock, never starting from a standstill
				if h.followMe and not h.locked and h.tLock - now < 1.6 and h.tLock - now > -0.2 then preLock = true end
			end
			if preLock then
				local md = hum.MoveDirection
				local bestP, bestS
				for a = 0, 11 do
					local ang = a * math.pi / 6
					local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
					local p = pos + dir * 14
					if inFightArena(p, 3) and safeEverywhere(p) and safeEverywhere(pos + dir * 7) and sameFloor(p, pos.Y) then
						local s = (md.Magnitude > 0.3 and (1 - md.Unit:Dot(dir)) * 6 or 0)
						if fightArena then s = s + flatDist(p, fightArena.center) * 0.15 end
						if not bestS or s < bestS then bestP, bestS = p, s end
					end
				end
				if bestP then
					if not dodging and PW then pcall(PW.stop) end
					dodging = true
					dodgeGoal = bestP
					hum:MoveTo(bestP)
					stats.farm = "วงตามตัว: วิ่งรอหลบ"
					continue
				end
			end
		end
		if not soonest then
			if dodging then hum:MoveTo(pos) end   -- reached safety: stop; main loop resumes
			dodging = false
			continue
		end
		-- bound the escape by where the boss IS now, not where it stood when it cast
		local ff = fightFocus
		if ff and ff.Parent and ff.PrimaryPart and (tonumber(ff:GetAttribute("Health")) or 0) > 0 then
			bossPos = ff.PrimaryPart.Position
		end
		local esc = findEscape(pos, bossPos, hum.MoveDirection)
		if not esc and dg then
			-- enraged double stars (Spirit Star + Eclipse, each with a rotated follow-up)
			-- leave no gap at our usual margin -> we stood still and ate 4 spokes. Take the
			-- best thin gap there is instead of tanking everything.
			relaxMargin = 0.8
			local okE, e2 = pcall(findEscape, pos, bossPos, hum.MoveDirection)
			relaxMargin = nil
			if okE then esc = e2 end
		end
		if not esc then
			-- nowhere safe inside the arena: take the hit, keep fighting
			if dodging then hum:MoveTo(pos) end
			dodging = false
			stats.tanked = (stats.tanked or 0) + 1
		end
		if esc then
			if not dodging then
				stats.dodges = (stats.dodges or 0) + 1
				if PW then pcall(PW.stop) end   -- the game walker would override our MoveTo
			end
			dodging = true   -- AUTO + target stay set: we keep shooting while stepping out
			dodgeGoal = dg and esc or nil   -- per-frame re-issue: dungeon only
			hum:MoveTo(esc)
			stats.farm = "หลบสกิลบอส"
			-- Dash-roll (the game's Q dodge: ~11 studs burst + Dodge remote) when
			--   * walking can't make it before impact, or
			--   * we're STILL inside the zone in the last 0.35s (wedged on a monster etc.)
			-- The roll goes along Humanoid.MoveDirection, so wait until MoveTo has
			-- actually turned us toward the escape (else the game rolls BACKWARD).
			local cantWalk = flatDist(pos, esc) > (hum.WalkSpeed * math.max(soonest - 0.15, 0.05)) * 0.8
			local lastChance = soonest <= 0.35
			local want = Vector3.new(esc.X - pos.X, 0, esc.Z - pos.Z)
			-- the roll always dashes ~11 studs: if the landing spot isn't on this same
			-- floor (arena edge / cliff), rolling throws us OFF the plateau -> walk instead
			local rollSafe = want.Magnitude > 0.5 and sameFloor(pos + want.Unit * 12, pos.Y)
				and sameFloor(pos + want.Unit * 6, pos.Y)
			-- a potion-sealing mark is about to lock on us: keep the roll (0.9s cd) for it
			local saveRoll = false
			if dg and not urgent then
				for _, h2 in pairs(hazards) do
					if h2.followMe and not h2.locked and h2.tLock - now < 1.2 then saveRoll = true end
				end
			end
			local wantRoll = dg and (not saveRoll and now - lastRoll > 0.92 and (cantWalk or lastChance or urgent or soonest < 0.95))
				or (not dg and now - lastRoll > 0.95 and (cantWalk or lastChance))   -- field: original rule
			if okMC and MoveCtl.dodge and rollSafe and wantRoll then
				lastRoll = now
				task.spawn(function()
					for _ = 1, 6 do   -- up to ~6 frames for MoveDirection to line up
						local md = hum.MoveDirection
						if want.Magnitude < 0.5 or (md.Magnitude > 0.5 and md.Unit:Dot(want.Unit) > 0.6) then break end
						RunService.Heartbeat:Wait()
					end
					if pcall(MoveCtl.dodge) then stats.rolls = (stats.rolls or 0) + 1 end
				end)
			end
		end
	end
end)

-- Fight a monster/boss the way a player does: AUTO on + click it (TC.set). The game's
-- step() chases it with PathWalker at any distance, stops at attack range, shoots and
-- casts skills. We only SUPERVISE the chase for stuck:
--   2.5s not moving while out of range -> jump + PW.stop (step() re-chases next
--     frame with a fresh route; the walker otherwise only re-issues every ~3s)
--   5s  -> short ground-snapped hop burst along the walker's own route (PW.ahead)
--   9s  -> report "stuck" (farm drops the target for a while)
-- returns "fight" (in range), "chase", or "stuck"
local chaseMark = {}
local CLOSE_IN = 6   -- boss fights: stand this close (flat) to the boss
local function engageTarget(hum, hrp, t, closeIn)
	setAuto(true)
	if TC.current ~= t then pcall(TC.set, t) end
	local now, pos = os.clock(), hrp.Position
	if chaseMark.t ~= t then chaseMark.idleAt = nil end
	if chaseMark.t ~= t or not chaseMark.pos or (pos - chaseMark.pos).Magnitude > 3 then
		chaseMark.t = t; chaseMark.pos = pos; chaseMark.at = now; chaseMark.kick = nil
	end
	local tp = t.PrimaryPart.Position
	-- exactly the game's own in-range test (TargetController step: attackRange +
	-- target Radius - 0.5, flat) -- with a different cutoff we flip-flopped between
	-- "chase" and "fight" while the game was happily shooting from the boundary
	local reach = ATTACK_RANGE + (tonumber(t:GetAttribute("Radius")) or 1) - 0.5
	if flatDist(tp, pos) <= reach and math.abs(tp.Y - pos.Y) < FLOOR_GAP + 5 then
		chaseMark.at = now; chaseMark.kick = nil; chaseMark.idleAt = nil
		ride(false)   -- off the mount to shoot
		-- Boss: the game's chase parks us at max attack range (38 for Archer) -- right
		-- at the arena edge (radius 40), so the first dodge stepped us out and the boss
		-- leashed to full HP. Walk in next to it (keep shooting meanwhile); dodges then
		-- have room inside the circle.
		local fd = flatDist(tp, pos)
		if closeIn and not dodging and fd > CLOSE_IN + (tonumber(t:GetAttribute("Radius")) or 1) + 2 then
			local away = Vector3.new(pos.X - tp.X, 0, pos.Z - tp.Z)
			local stand = away.Magnitude > 0.5 and (tp + away.Unit * (CLOSE_IN + (tonumber(t:GetAttribute("Radius")) or 1))) or tp
			-- keep the stand spot inside the boss's circle
			if fightArena and not inFightArena(stand, 4) then
				local c = fightArena.center
				local dir = Vector3.new(stand.X - c.X, 0, stand.Z - c.Z)
				if dir.Magnitude > 0.5 then stand = Vector3.new(c.X, 0, c.Z) + dir.Unit * (fightArena.radius - 5) end
			end
			hum:MoveTo(Vector3.new(stand.X, pos.Y, stand.Z))
		end
		return "fight"
	end
	if flatDist(tp, pos) > reach + 25 then ride(true) end   -- long chase: ride there
	-- the game's chase sometimes just doesn't start (target a hair past range, or on
	-- another terrace): if its walker has been idle 0.8s while we're out of range,
	-- walk there ourselves with the same walker instead of standing around
	local walking = PW and PW.isWalking()
	if walking then chaseMark.idleAt = nil else chaseMark.idleAt = chaseMark.idleAt or now end
	if chaseMark.idleAt and now - chaseMark.idleAt > 0.8 then
		-- still the same give-up rule: 7s without getting anywhere = unreachable
		-- (e.g. just past range but below a cliff from the farm spot) -> skip it
		if now - chaseMark.at > 7 then return "stuck" end
		pathTo(hum, hrp, tp)
		return "chase"
	end
	-- the game walker still heading somewhere else (an old loot spot / farm spot left
	-- over from before a warp) fights the chase: drop it so step() re-routes to t
	if PW then
		local okG, g = pcall(PW.goal)
		if okG and g and flatDist(g, tp) > 25 then pcall(PW.stop); pf.pwGoal = nil end
	end
	local still = now - chaseMark.at
	if still > 2 and not chaseMark.kick then
		chaseMark.kick = now
		-- push toward the walker's own next waypoint, jump, then let step() re-chase
		local okA, route = pcall(function() return PW and PW.ahead() end)
		if okA and type(route) == "table" then
			for _, p in ipairs(route) do
				if typeof(p) == "Vector3" and flatDist(p, pos) > 2 then hum:MoveTo(p); break end
			end
		end
		hum.Jump = true
		task.delay(0.6, function() if PW then pcall(PW.stop) end end)
	elseif still > 4.5 then
		local nextPt
		local okA, route = pcall(function() return PW and PW.ahead() end)
		if okA and type(route) == "table" then
			for _, p in ipairs(route) do
				if typeof(p) == "Vector3" and flatDist(p, pos) > 3 then nextPt = p; break end
			end
		end
		local ok = nextPt and hopStep(hrp, nextPt, math.max(pos.Y, nextPt.Y) + 6)
			or hopStep(hrp, tp, math.max(pos.Y, tp.Y) + 22)
		if ok then stats.hops = (stats.hops or 0) + 1 end
		if still > 7 then return "stuck" end
	end
	return "chase"
end

-- ARENA MAP KNOWLEDGE. Every field's boss arena is a plateau ~12 studs above the field
-- (ArenaFloor), ringed by cliffs, and its ONLY way up is the one StairRamp whose top
-- end sits on the arena rim (~40 from the center) at floor height (measured across all
-- fields). The game's chase measures range flat, so it happily parked us BELOW the
-- plateau "in range" -- outside the arena circle, where the boss counts nobody in
-- its arena and leashes back to full HP. So for bosses we route deterministically:
-- ramp bottom -> straight up the ramp -> onto the arena, then fight.
local arenaCache = {}   -- fieldId -> {center, radius, floorY, top, bot, topIn, botOut, len}
local WORLD_RP = RaycastParams.new()
WORLD_RP.FilterType = Enum.RaycastFilterType.Include
local function arenaInfo(f)
	if not (f and f.id and f.arena and f.arena.center) then return nil end
	local c = arenaCache[f.id]
	if c then return c end
	local world = workspace:FindFirstChild("World")
	local folder = world and world:FindFirstChild("Field_" .. f.id)
	if not folder then return nil end
	WORLD_RP.FilterDescendantsInstances = {world}
	local ac = f.arena.center
	local aHit = workspace:Raycast(Vector3.new(ac.X, 600, ac.Z), Vector3.new(0, -800, 0), WORLD_RP)
	if not aHit then   -- not streamed in yet: ask for it, try again next tick
		task.spawn(function() pcall(plr.RequestStreamAroundAsync, plr, Vector3.new(ac.X, 200, ac.Z), 3) end)
		return nil
	end
	local floorY = aHit.Position.Y
	local best, bestD
	for _, p in ipairs(folder:GetDescendants()) do
		if p:IsA("BasePart") and p.Name == "StairRamp" then
			local look = p.CFrame.LookVector
			local e1, e2 = p.Position + look * p.Size.Z / 2, p.Position - look * p.Size.Z / 2
			local h1 = workspace:Raycast(Vector3.new(e1.X, 600, e1.Z), Vector3.new(0, -800, 0), WORLD_RP)
			local h2 = workspace:Raycast(Vector3.new(e2.X, 600, e2.Z), Vector3.new(0, -800, 0), WORLD_RP)
			if h1 and h2 then
				local top, bot = h1.Position, h2.Position
				if bot.Y > top.Y then top, bot = bot, top end
				local d = flatDist(top, ac)
				if math.abs(top.Y - floorY) < 3 and d < 50 and (not best or d < bestD) then
					best, bestD = {top = top, bot = bot}, d
				end
			end
		end
	end
	if not best then return nil end
	local dir = Vector3.new(best.top.X - best.bot.X, 0, best.top.Z - best.bot.Z)
	local u = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(1, 0, 0)
	c = {center = Vector3.new(ac.X, floorY, ac.Z), radius = tonumber(f.arena.radius) or 40, floorY = floorY,
		top = best.top, bot = best.bot, len = dir.Magnitude,
		topIn = best.top + u * 5, botOut = best.bot - u * 4}
	arenaCache[f.id] = c
	return c
end
arenaInfoFwd = arenaInfo
-- returns true while it's still taking us up onto the arena (caller skips the fight)
local function climbToArena(hum, hrp, ai)
	local pos = hrp.Position
	local onArena = pos.Y > ai.floorY + 1 and flatDist(pos, ai.center) < ai.radius + 2
	if onArena then return false end
	setAuto(false)   -- short climb: don't let the game's chase pull another way
	local onRamp = flatDist(pos, ai.bot) + flatDist(pos, ai.top) <= ai.len + 3 and pos.Y > ai.bot.Y + 1
	if onRamp or flatDist(pos, ai.bot) < 5 or flatDist(pos, ai.botOut) < 4 then
		if PW then pcall(PW.stop) end
		pathReset()
		hum:MoveTo(ai.topIn)   -- the ramp is one straight walkable slope
		if hum.MoveDirection.Magnitude < 0.1 then hum.Jump = true end
	else
		pathTo(hum, hrp, ai.botOut)
	end
	return true
end

-- Boss loot: after a boss dies its drops scatter around it as Parts named "Loot" in
-- workspace.LootDrops, and the game's Auto Pickup only grabs what's near you or your
-- pet. We used to leave the instant it died, so the loot stayed on the ground. Now
-- we hold a loot phase: wait for drops, walk onto each one near the corpse.
local lastBoss, lastBossPos = nil, nil
local lastBossWB = false
local WB_ARENA_R = 42   -- WorldBoss.arena.radius
pcall(function()
	local W = require(RS.Shared.Config.WorldBoss)
	if W.arena and tonumber(W.arena.radius) then WB_ARENA_R = tonumber(W.arena.radius) end
end)
local chestIgnore = setmetatable({}, {__mode = "k"})   -- chests that won't open for us
local chestNear = setmetatable({}, {__mode = "k"})     -- chest -> when we got next to it
local lootPhase = nil      -- {center, minT, untilT, ignore = {part = true}, nearAt = {part = t}}
-- WHOSE DROP (user: "worldboss จบ แล้วมันวิ่งเก็บของคนอื่น" / "มีคนยืนฟามใกล้ๆ มันก็วิ่งไปเก็บ"):
-- the game's LootDrops controller keeps a record per rendered drop -- {mine, owner, parts}
-- in upvalue 2 of LootDrops.tap. Parts of a record with mine == false are another
-- player's: never walk to them. Unknown parts fall through to the old heuristics below.
local lootOwn = {at = 0, other = {}}
function lootOwn.isOther(p)
	local now = os.clock()
	if now - lootOwn.at > 0.4 then
		lootOwn.at = now
		local set = {}
		pcall(function()
			local c = controllers()
			local mod = c and c:FindFirstChild("LootDrops")
			local list = mod and debug.getupvalues(require(mod).tap)[2]
			for _, en in pairs(type(list) == "table" and list or {}) do
				if type(en) == "table" and en.mine == false and type(en.parts) == "table" then
					for _, q in pairs(en.parts) do
						if typeof(q) == "Instance" then set[q] = true end
					end
				end
			end
		end)
		lootOwn.other = set
	end
	return lootOwn.other[p] == true
end
-- LootDrops also shows OTHER players' drops, which we can't pick up: ignore what was
-- already lying there when our boss died, and anything we've stood on for 1.5s that
-- didn't vanish (= not ours) -- otherwise we circle someone else's loot for 10s.
local function nearestLoot(center, pos)
	local f = workspace:FindFirstChild("LootDrops")
	if not f then return nil end
	local lp = lootPhase
	local now = os.clock()
	local best, bestD
	for _, p in ipairs(f:GetChildren()) do
		-- the game takes a claimable drop (gear/card) once we're within 12 of where it
		-- landed and retries every 3s if the server says no -- so only call a drop
		-- "not ours" after standing within 8 of it for 4.5s (covers one retry)
		if lp and not lp.ignore[p] and p:IsA("BasePart") and flatDist(p.Position, pos) < 8 then
			lp.nearAt[p] = lp.nearAt[p] or now
			if now - lp.nearAt[p] > 4.5 then lp.ignore[p] = true end
		end
		if p:IsA("BasePart") and not (lp and lp.ignore[p]) and flatDist(p.Position, center) < ((lp and lp.radius) or 80)
			and not lootOwn.isOther(p) then
			local d = flatDist(p.Position, pos)
			if not best or d < bestD then best, bestD = p, d end
		end
	end
	return best, bestD
end

-- STEP ASSIST: what a player does by reflex -- if we're being told to walk (MoveDirection
-- set, by us or by the game's walker) but we've barely moved for 0.4s, we're against
-- a lip (top of a StairRamp, a terrace step): jump. Cheap, invisible, works on every map.
-- RAMP PUSH (map knowledge for every StairRamp, not just the arena one): the game's
-- walker pauses ~3s at ramp ends ("stepping") and sometimes never resumes, leaving us
-- parked at the top/bottom lip with no MoveTo at all -- so the step assist above never
-- fires. If we've stood still 1s on or right beside a ramp while a walk is active,
-- push to the end of that ramp that matches where we're going (up if the goal is
-- higher, down if lower) and jump.
local rampEnds = setmetatable({}, {__mode = "k"})   -- ramp part -> {hi = V3, lo = V3}
local function endsOf(ramp)
	local c = rampEnds[ramp]
	if c then return c end
	local look = ramp.CFrame.LookVector
	local e1, e2 = ramp.Position + look * ramp.Size.Z / 2, ramp.Position - look * ramp.Size.Z / 2
	local world = workspace:FindFirstChild("World")
	if not world then return nil end
	WORLD_RP.FilterDescendantsInstances = {world}
	local h1 = workspace:Raycast(Vector3.new(e1.X, ramp.Position.Y + 40, e1.Z), Vector3.new(0, -80, 0), WORLD_RP)
	local h2 = workspace:Raycast(Vector3.new(e2.X, ramp.Position.Y + 40, e2.Z), Vector3.new(0, -80, 0), WORLD_RP)
	if not (h1 and h2) then return nil end
	local hi, lo = h1.Position, h2.Position
	if lo.Y > hi.Y then hi, lo = lo, hi end
	local u = Vector3.new(hi.X - lo.X, 0, hi.Z - lo.Z)
	u = u.Magnitude > 0.1 and u.Unit or Vector3.new(1, 0, 0)
	c = {hi = hi + u * 4, lo = lo - u * 4}   -- a few studs past each end, off the lip
	rampEnds[ramp] = c
	return c
end
task.spawn(function()
	local stillSince, lastPush, lastPos = nil, 0, nil
	while alive() do
		task.wait(0.25)
		local _, hum, hrp = myChar()
		if not (hum and hrp) or dodging or not (PW and PW.isWalking()) then stillSince = nil; continue end
		local pos = hrp.Position
		-- "still" = no real HORIZONTAL progress (jump-bouncing against a lip moves us up
		-- and down every tick and used to reset this, so the push never fired)
		if not lastPos or flatDist(pos, lastPos) > 2.5 then lastPos = pos; stillSince = nil
		else stillSince = stillSince or os.clock() end
		if stillSince and os.clock() - stillSince > 1 and os.clock() - lastPush > 1.5 then
			local okG, goal = pcall(PW.goal)
			if okG and goal then
				if goal.Y < pos.Y - 5 then
					-- going DOWN a terrace: no need for the ramp at all -- just walk off
					-- the edge toward the goal (an 8-stud drop, no damage)
					local dir = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
					if dir.Magnitude > 1 then
						lastPush = os.clock()
						pcall(PW.stop)
						-- walk far enough to actually reach the edge (a mound can be ~40
						-- across); the hold ends early once we've dropped (see pathTo)
						pf.manualUntil = os.clock() + 4
						pf.manualStartY = pos.Y
						hum:MoveTo(pos + dir.Unit * math.min(45, dir.Magnitude))
						stats.rampPush = (stats.rampPush or 0) + 1
					end
				else
					local ramp
					for _, p in ipairs(workspace:GetPartBoundsInRadius(pos, 14)) do
						if p.Name == "StairRamp" and p:IsA("BasePart") then ramp = p; break end
					end
					local ends = ramp and endsOf(ramp)
					if ends then
						lastPush = os.clock()
						pcall(PW.stop)
						pf.manualUntil = os.clock() + 2
						hum:MoveTo((goal.Y > pos.Y + 2) and ends.hi or ends.lo)
						hum.Jump = true
						stats.rampPush = (stats.rampPush or 0) + 1
					end
				end
			end
		end
	end
end)

task.spawn(function()
	local blockedSince, lastJump = nil, 0
	while alive() do
		task.wait(0.1)
		local _, hum, hrp = myChar()
		if hum and hrp and not dodging and hum.MoveDirection.Magnitude > 0.5
			and hum.FloorMaterial ~= Enum.Material.Air then
			local v = hrp.AssemblyLinearVelocity
			if Vector3.new(v.X, 0, v.Z).Magnitude < 3 then
				blockedSince = blockedSince or os.clock()
				if os.clock() - blockedSince > 0.4 and os.clock() - lastJump > 0.6 then
					hum.Jump = true; lastJump = os.clock()
					stats.stepJumps = (stats.stepJumps or 0) + 1
				end
			else
				blockedSince = nil
			end
		else
			blockedSince = nil
		end
	end
end)

-- World boss schedule straight from the server's ReplicatedStorage attributes (what
-- the game's own WORLD BOSS banner + GO! button read): WorldBoss = state ("soon"
-- while announced, ~2 min before landing), WorldBossId, WorldBossField, WorldBossAt
-- (landing time), WorldBossLanding (where GO! walks you), WorldBossSpot (arena centre).
local function wbInfo()
	local RSa = game:GetService("ReplicatedStorage")
	local state = RSa:GetAttribute("WorldBoss")
	if not state then return nil end
	local spot, landing = RSa:GetAttribute("WorldBossSpot"), RSa:GetAttribute("WorldBossLanding")
	return {state = state, id = RSa:GetAttribute("WorldBossId"), field = RSa:GetAttribute("WorldBossField"),
		at = tonumber(RSa:GetAttribute("WorldBossAt")),
		spot = typeof(spot) == "Vector3" and spot or nil, landing = typeof(landing) == "Vector3" and landing or nil}
end
-- the current world boss, if Auto World Boss is on, it passes the name/field filters,
-- and it's either announced or actually alive
local function wbWanted()
	if not e.phWBOn then return nil end
	local w = wbInfo()
	if not (w and w.field) then return nil end
	local name = w.id and (WB_LABEL[w.id] or WB_LABEL["wb_" .. tostring(w.id)])
	if not wbNamePicked(name) then return nil end
	if not wbFieldPicked(w.field) then return nil end
	local live = false
	for _, m in ipairs(workspace.Monsters:GetChildren()) do
		if m:GetAttribute("WorldBoss") and (tonumber(m:GetAttribute("Health")) or 0) > 0 then live = true; break end
	end
	if w.state ~= "soon" and not live then return nil end   -- results/cleanup phase: nothing to do
	-- announced but far off: keep doing whatever we were doing; only head out ~45s
	-- before landing (warp ~5s + walk ~10s -> on the spot ~30s early, user's choice)
	if not live and w.at and w.at - workspace:GetServerTimeNow() > 45 then return nil end
	w.name = name or tostring(w.id)
	w.live = live
	return w
end
wbWantedFwd = wbWanted

-- ------------------------------------------------------------------ DUNGEON
-- Runs live in workspace.Dungeons; rooms sit in a straight line along +X per slot
-- (Config.Dungeons.roomCenter(def, slot, stage), slots 520 apart on Z), joined by a
-- 9-wide corridor. Monsters are ordinary workspace.Monsters entries with MonsterId
-- "dg_<dungeon>_<diff>_<slot>_<kind><n>". Remote Net.func("Dungeon"):
--   "state" -> {inRun, keys, free{id=n}, clears, keyPrice}   "enter", id, diff
--   "ready", bool (party ready check)   "leave" (with the boss chest up = opens it
--   for everyone first, then back to town)   "loaded" (the game's loader calls it)
-- Server pushes Effect("Dungeon", {kind = ready|readyState|cancel|loading|start|
-- stage|restart|gate|elites|miniboss|boss|chest|chestOpen|result}).
local DG = nil
pcall(function() DG = require(RS.Shared.Config.Dungeons) end)
local dgStats = {runs = 0, wins = 0, lastSec = nil, status = "-", waitUntil = 0, lastTry = 0,
	backAt = 0, chestAt = nil, keys = nil, free = nil, lastErr = nil}
getgenv().__PHP_DG = dgStats
local function dgCall(...)
	local ok, r = pcall(function(...) return Net.func("Dungeon"):InvokeServer(...) end, ...)
	if ok and type(r) == "table" then return r end
	return {ok = false}
end
local function dgPick()
	local id, diff = tostring(e.phDgPick or "crypt:hard"):match("^([^:]+):(.+)$")
	return id or "crypt", diff or "hard"
end
-- {def, slot, stage, prefix} for the run we're in (nil outside a run)
local function dgRun(hrp)
	local id = plr:GetAttribute("DungeonRun")
	local def = id and DG and DG.byId[id]
	if not def then return nil end
	local slot, bestD = 0, nil
	for s = 0, math.max((DG.slots or 8) - 1, 0) do
		local ok, c = pcall(DG.roomCenter, def, s, 1)
		if ok and c then
			local d = math.abs(c.Z - hrp.Position.Z)
			if not bestD or d < bestD then slot, bestD = s, d end
		end
	end
	local stage = math.clamp(tonumber(plr:GetAttribute("DungeonStage")) or 1, 1, #def.stages)
	local diff = plr:GetAttribute("DungeonDiff") or "normal"
	-- the number in the id is the difficulty tier, NOT the slot: our run's monsters are
	-- told apart from other parties' runs by lane (slots sit 520 apart on Z)
	local okC, c1 = pcall(DG.roomCenter, def, slot, 1)
	return {def = def, id = id, slot = slot, stage = stage, laneZ = okC and c1 and c1.Z or hrp.Position.Z,
		prefix = ("dg_%s_%s_"):format(id, diff)}
end
local function dgRoom(run, stage)
	local ok, c = pcall(DG.roomCenter, run.def, run.slot, stage)
	return ok and c or nil, run.def.stages[stage] and run.def.stages[stage].radius or 30
end
-- the boss chest's prompt (spawns after the boss dies, near the throne room)
local function dgChestPrompt(run, hrp)
	local c = dgRoom(run, #run.def.stages) or hrp.Position
	local best, bestD
	local function consider(p)
		if p:IsA("ProximityPrompt") and p.Enabled then
			local part = p.Parent
			if part and part:IsA("Attachment") then part = part.Parent end
			if part and part:IsA("BasePart") then
				local d = flatDist(part.Position, c)
				if d < 140 and (not best or d < bestD) then best, bestD = p, d end
			end
		end
	end
	local root = workspace:FindFirstChild("Dungeons")
	for _, p in ipairs(root and root:GetDescendants() or {}) do consider(p) end
	for _, ch in ipairs(workspace:GetChildren()) do
		if ch:IsA("Model") and ch.Name:lower():find("chest") then
			for _, p in ipairs(ch:GetDescendants()) do consider(p) end
		end
	end
	return best
end
-- walk along the room line: get onto the corridor's Z first, then straight along X
local function dgWalk(hum, hrp, run, goal)
	local pos = hrp.Position
	local slotZ = (dgRoom(run, 1) or goal).Z
	if math.abs(goal.X - pos.X) > 20 and math.abs(pos.Z - slotZ) > 4 then
		hum:MoveTo(Vector3.new(pos.X, pos.Y, slotZ))
	else
		hum:MoveTo(Vector3.new(goal.X, pos.Y, goal.Z))
	end
end
local dgMark = {pos = nil, at = 0}
-- CHEST LOOT (user: "เปิดกล่องในดันเสร็จ รอเก็บของด้วย"): after the boss chest opens,
-- sweep what it drops (workspace.LootDrops) before the REPLAY vote restarts the run.
-- {center, minT, untilT, ignore = {part = true}, nearAt = {part = t}}
local dgLootPhase = nil
local dgChestPos = nil
local dgBuyKeyFwd = nil   -- = dgTryBuyKey (defined further down, next to the town loop)
local function dgStartLoot()
	local now = os.clock()
	local _, _, hrp0 = myChar()
	dgLootPhase = {center = dgChestPos or (hrp0 and hrp0.Position), minT = now + 2.5, untilT = now + 12,
		ignore = {}, nearAt = {}}
	-- drops already lying around belong to someone else / were already handled
	local lf = workspace:FindFirstChild("LootDrops")
	for _, p in ipairs(lf and lf:GetChildren() or {}) do dgLootPhase.ignore[p] = true end
end
-- returns true while it's driving the character
local function dgLootTick(hum, hrp)
	local lp = dgLootPhase
	if not lp then return false end
	local now = os.clock()
	if now > lp.untilT or not lp.center then dgLootPhase = nil; return false end
	local pos = hrp.Position
	local best, bestD
	local lf = workspace:FindFirstChild("LootDrops")
	for _, p in ipairs(lf and lf:GetChildren() or {}) do
		if p:IsA("BasePart") and not lp.ignore[p] and flatDist(p.Position, lp.center) < 70 and not lootOwn.isOther(p) then
			local d = flatDist(p.Position, pos)
			-- stood on it 4.5s and it's still there: not ours to take
			if d < 8 then
				lp.nearAt[p] = lp.nearAt[p] or now
				if now - lp.nearAt[p] > 4.5 then lp.ignore[p] = true end
			end
			if not lp.ignore[p] and (not best or d < bestD) then best, bestD = p, d end
		end
	end
	if best then
		setAuto(false)
		if bestD > 4 then hum:MoveTo(Vector3.new(best.Position.X, pos.Y, best.Position.Z)) end
		stats.farm = "ดันเจี้ยน: เก็บของจากหีบ"
		return true
	end
	if now < lp.minT then
		stats.farm = "ดันเจี้ยน: รอของจากหีบตก"
		return true
	end
	dgLootPhase = nil
	return false
end
-- HP potion ourselves at 50% (the game's AUTO waits lower). Lantern Hex SEALS potions
-- (SealedUntil attr) -- nothing to drink then, so don't waste the call.
local dgPotion
do
local okCC, CombatC = pcall(require, plr.PlayerScripts.Client.Controllers.CombatController)
local dgPotAt = 0
function dgPotion(hum)
	if not okCC or type(CombatC) ~= "table" or not CombatC.usePotion then return end
	-- potions heal a FIXED amount (yellow 6000 of ~53k max = 11%) on a 1s cooldown while
	-- boss hits take 20-25%: drink on cooldown from 85% down, strongest potion we own
	-- a potion-sealing mark is coming for us: top up NOW, we can't drink for 5s after
	local markIncoming = false
	for _, h in pairs(hazards) do
		if h.followMe and not h.locked then markIncoming = true; break end
	end
	local limit = markIncoming and 0.97 or 0.85
	if hum.MaxHealth <= 0 or hum.Health <= 0 or hum.Health / hum.MaxHealth > limit then return end
	if (tonumber(plr:GetAttribute("SealedUntil")) or 0) > workspace:GetServerTimeNow() then return end
	if os.clock() - dgPotAt < 1.05 then return end
	dgPotAt = os.clock()
	local inv = plr:FindFirstChild("Inventory")
	local okI, Items = pcall(require, RS.Shared.Config.Items)
	local bestId, bestHeal
	if inv and okI and Items.defs then
		for id, n in pairs(inv:GetAttributes()) do
			local d = Items.defs[id]
			if d and tonumber(d.heal) and (tonumber(n) or 0) > 0 and (not bestHeal or d.heal > bestHeal) then
				bestId, bestHeal = id, d.heal
			end
		end
	end
	if bestId and CombatC.useItem then pcall(CombatC.useItem, bestId) else pcall(CombatC.usePotion, "hp") end
end
end
local function dgTick(hum, hrp)
	local run = dgRun(hrp)
	if not run then return false end
	dgPotion(hum)
	lootPhase = nil; lastBoss = nil
	if dgLootTick(hum, hrp) then return true end
	local now = os.clock()
	local pos = hrp.Position
	if not dgMark.pos or (pos - dgMark.pos).Magnitude > 3 then dgMark.pos = pos; dgMark.at = now end
	local stuckFor = now - dgMark.at
	local nStages = #run.def.stages
	-- BOSS CHEST: walk to it and open it; if no prompt turns up / the server ignores
	-- it for 20s, "leave" -- with the chest up that opens it for everyone first
	if plr:GetAttribute("DungeonChest") == true then
		dgStats.chestAt = dgStats.chestAt or now
		fightArena = nil; fightFocus = nil
		local prompt = dgChestPrompt(run, hrp)
		local part = prompt and prompt.Parent
		if part and part:IsA("Attachment") then part = part.Parent end
		setAuto(false)
		if part then
			local d = flatDist(part.Position, pos)
			if d > math.max((prompt.MaxActivationDistance or 10) - 3, 4) then
				if stuckFor > 3 then pathTo(hum, hrp, part.Position) else dgWalk(hum, hrp, run, part.Position) end
				stats.farm = ("ดันเจี้ยน: ไปเปิดหีบบอส (ห่าง %.0f)"):format(d)
			else
				pathReset()
				pcall(fireproximityprompt, prompt)
				stats.farm = "ดันเจี้ยน: เปิดหีบบอส"
			end
		else
			stats.farm = "ดันเจี้ยน: หาหีบบอส"
		end
		if now - dgStats.chestAt > 20 then
			dgStats.chestAt = now   -- retry window, not a spam loop
			task.spawn(dgCall, "leave")
			stats.farm = "ดันเจี้ยน: เปิดหีบให้ทุกคน (Leave)"
		end
		return true
	end
	dgStats.chestAt = nil
	-- current room: the stage attr says which; monsters of our run only
	local center, radius = dgRoom(run, run.stage)
	-- HOLD THE MIDDLE (user: "ลากบอสออกไกลเกินเลือดดี / พยายามอยู่ center"): pulling
	-- the boss away from its room makes it regen to full. We stand on the room centre,
	-- only shoot what's in range from there, step at most DG_STEP_R out toward a far
	-- one, and the dodge loop's escape spots are clamped to DG_ARENA_R of the centre.
	-- the leash only matters in the boss room; ordinary rooms may be crossed freely
	-- (ranged mobs at the edge never walk in, and we stood there "waiting" forever)
	local bossRoom = run.stage >= nStages
	-- boss room: the throne boss hovers at the room centre; keep inside r40 of it (no
	-- leash) with room to dodge. Ordinary rooms: the whole room.
	-- user: "ยืนยิงแล้วหลบแถวๆวงเขียวตรงกลาง (r9)": orbit just outside the sigil, dodge
	-- within 24 of the centre
	local DG_HOLD_R, DG_ARENA_R = 5, 32
	-- boss room: step out up to 24 to keep adds in bow range -- standing "out of range"
	-- while the ring keeps closing is what made the late fight so cramped
	local DG_STEP_R = bossRoom and 24 or radius + 6
	fightArena = center and {center = center, radius = bossRoom and math.min(radius - 4, DG_ARENA_R) or radius + 4} or nil
	local boss, mobs = nil, {}
	for _, m in ipairs(workspace.Monsters:GetChildren()) do
		local mid = m:GetAttribute("MonsterId")
		if m.PrimaryPart and type(mid) == "string" and mid:sub(1, #run.prefix) == run.prefix
			and math.abs(m.PrimaryPart.Position.Z - run.laneZ) < 160
			and (tonumber(m:GetAttribute("Health")) or 0) > 0 then
			local mp = m.PrimaryPart.Position
			-- this room only (or something already in range of us): never go hunting
			-- leftovers down the corridor
			local reachM = ATTACK_RANGE + (tonumber(m:GetAttribute("Radius")) or 1) - 0.5
			if (center and flatDist(mp, center) <= radius + 10) or flatDist(mp, pos) <= reachM then
				if m:GetAttribute("IsBoss") == true then boss = m else mobs[#mobs + 1] = m end
			end
		end
	end
	-- boss is immune while its adds are up (Shielded): clear the adds first
	local pool = mobs
	if boss and (boss:GetAttribute("Shielded") ~= true or #mobs == 0) then pool = {boss} end
	local channeling = boss and os.clock() < dgChannelUntil
	if channeling and boss:GetAttribute("Shielded") ~= true then pool = {boss} end   -- break the charge
	-- SHIELD PHASE: the boss is immune and its adds (spawned out at the room edge) HEAL
	-- it every tick -- we stood "out of range" while it went 30% -> 57%. Go get them,
	-- anywhere in the room; back to the centre once they're dead.
	-- ...but only so far: wandering out to 40-53 dragged the boss along and that's where
	-- we died. Step <=20 toward them (bow range covers the rest), not while sealed.
	local sealedNow = (tonumber(plr:GetAttribute("SealedUntil")) or 0) > workspace:GetServerTimeNow()
	local addHunt = bossRoom and boss and boss:GetAttribute("Shielded") == true and #mobs > 0 and not sealedNow
	if addHunt then
		DG_STEP_R = 20
		fightArena = center and {center = center, radius = math.min(radius - 3, 32)} or nil
	end
	-- a star is up: allow backing off to r32 so the dodge can get out where the gaps are
	if bossRoom then
		for _, h in pairs(hazards) do
			if h.shape == "star" and fightArena then
				fightArena = {center = fightArena.center, radius = math.max(fightArena.radius, math.min(radius - 3, 32))}
				break
			end
		end
	end
	-- SEALED (no potions for 5s): play safe -- hold the spot by the centre, shoot only
	-- what's already in range, dodge; no stepping out after anything
	if bossRoom and sealedNow then DG_STEP_R = 0 end
	if #pool > 0 then
		local anchor = center and Vector3.new(center.X, pos.Y, center.Z) or pos
		local function reachOf(m) return ATTACK_RANGE + (tonumber(m:GetAttribute("Radius")) or 1) - 0.5 end
		local function inReach(m, from)
			local mp = m.PrimaryPart.Position
			return flatDist(mp, from) <= reachOf(m) and math.abs(mp.Y - from.Y) < 40
		end
		-- keep the current target while it's still valid (no flip-flop), else nearest the centre
		local best
		local cur = TC.current
		for _, m in ipairs(pool) do if m == cur then best = m end end
		if not best then
			local bestD
			for _, m in ipairs(pool) do
				local d = flatDist(m.PrimaryPart.Position, anchor) - reachOf(m)
				if not bestD or d < bestD then best, bestD = m, d end
			end
		end
		fightFocus = boss
		local bp = best.PrimaryPart.Position
		-- where to stand: the centre if it reaches; else step toward it, capped at DG_STEP_R
		-- the room centre, always (user: "พยายามอยู่ center" / "ลากบอสออกโง่ๆ"): standing
		-- off the boss made us back away as it followed = dragging it. Dodges step out,
		-- then we come straight back here.
		local stand = anchor
		-- BOSS ROOM (user: "ไม่ต้องยืนใต้ตีนบอส แค่ยืนวน center ไม่ออกนอกวงเวลาวงบีบ"):
		-- circle the room centre at ~14 studs on the side AWAY from the boss -- never
		-- under it, never far enough to drag it -- shrinking with the closing ring.
		if bossRoom and center then
			-- user: "ยืนเว้นระยะห่างน่าจะตายยากขึ้น": orbit ~22 out from the centre on the
			-- far side of the boss. Anchored to the CENTRE, not the boss, so we never back
			-- away as it follows (that was the drag) -- just a wider circle around the sigil.
			local R = 22
			local sr0 = shrinkRadius()
			if sr0 then R = math.min(R, math.max(sr0 - SHRINK_MARGIN - 5, 3)) end
			local bp0 = boss and boss.PrimaryPart and boss.PrimaryPart.Position
			local dir
			if bp0 and flatDist(bp0, anchor) > 4 then
				dir = Vector3.new(anchor.X - bp0.X, 0, anchor.Z - bp0.Z).Unit
			else
				-- boss sitting on the centre: hold our spot on the circle (standing still =
				-- full damage; constant walking only stretched the fight into the tiny ring)
				local cur = Vector3.new(pos.X - anchor.X, 0, pos.Z - anchor.Z)
				local ang = (cur.Magnitude > 1 and math.atan2(cur.Z, cur.X) or 0)
				dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
			end
			stand = anchor + dir * R
		end
		if not inReach(best, stand) then
			local dir = Vector3.new(bp.X - stand.X, 0, bp.Z - stand.Z)
			local need = math.min(dir.Magnitude - reachOf(best) + 3, DG_STEP_R)
			if dir.Magnitude > 0.5 and need > 0 then stand = stand + dir.Unit * need end
		end
		-- shrinking ring up: stay well inside its live radius (it keeps closing)
		local sr, sc = shrinkRadius()
		if sr then
			local lim = math.max(sr - SHRINK_MARGIN - 3, 2)
			local v = Vector3.new(stand.X - sc.X, 0, stand.Z - sc.Z)
			if v.Magnitude > lim then
				stand = Vector3.new(sc.X, pos.Y, sc.Z) + (v.Magnitude > 0.5 and v.Unit * lim or Vector3.zero)
			end
		end
		-- never park in a poison pool / live telegraph: nearest clean spot next to it
		if not safeEverywhere(stand) then
			local alt = findEscape(stand, boss and boss.PrimaryPart and boss.PrimaryPart.Position or nil)
			if alt then stand = Vector3.new(alt.X, pos.Y, alt.Z) end
		end
		local reachable = inReach(best, stand) or (inReach(best, pos) and inFightArena(pos, 0))
		if reachable then
			setAuto(true)
			if TC.current ~= best then pcall(TC.set, best) end
			ride(false)
		else
			-- out of range even from the edge of our zone: don't target it (the game's
			-- AUTO chase would drag us -- and the boss -- out); let it come to us
			if TC.current then pcall(TC.set, nil) end
			setAuto(false)
		end
		local off = flatDist(pos, stand)
		-- a telegraph is still about to land and we're clear of it: STAY. Walking back to
		-- the orbit spot now cuts straight through the beam we just stepped out of.
		-- only when the walk back actually crosses it (else keep moving / shooting)
		local pending = false
		if not dodging and off > DG_HOLD_R and safeEverywhere(pos) then
			for _, k in ipairs({0.25, 0.5, 0.75, 1}) do
				local q = pos:Lerp(Vector3.new(stand.X, pos.Y, stand.Z), k)
				for _, h in pairs(hazards) do   -- telegraphs about to land, not lingering pools
					if not h.persist and hazardHits(h, q) then pending = true; break end
				end
				if pending then break end
			end
		end
		if pending then
			pathReset()
			if PW and PW.isWalking and PW.isWalking() then pcall(PW.stop) end
			hum:MoveTo(pos)
			dgMark.at = now
		elseif not dodging and off > DG_HOLD_R then
			-- the router (with its jump/hop unstick kicks) only OUTSIDE the room: inside, the
			-- floor is a flat open disc, and "stuck" there just meant we stood shooting --
			-- which is what made the character hop around all fight
			local outside = center and flatDist(pos, anchor) > radius + 2
			if (stuckFor > 2.5 or dgMark.pathing) and outside then
				-- walking straight isn't getting there (pillar / ledge): the game's walker
				-- routes it -- and must NOT be stopped every tick (that froze us at the wall);
				-- stay on the route until we've arrived
				dgMark.pathing = true
				pathTo(hum, hrp, stand)
			else
				if PW and PW.isWalking and PW.isWalking() then pcall(PW.stop) end   -- would override MoveTo
				pathReset()
				if not outside then dgMark.pathing = false end
				if center and flatDist(pos, anchor) > radius + 15 then dgWalk(hum, hrp, run, stand) else hum:MoveTo(stand) end
			end
		else
			if not dodging then dgMark.pathing = false end
			pathReset()
			dgMark.at = now
		end
		local hp = math.floor((tonumber(best:GetAttribute("Health")) or 0) / math.max(tonumber(best:GetAttribute("MaxHealth")) or 1, 1) * 100)
		local what = reachable and "ตี" or "รอเข้าระยะ"
		if channeling then what = "ทุบให้ร่ายแตก! " .. what end
		if sr then what = ("[วงบีบ r%d] "):format(sr) .. what end
		if boss and best ~= boss and boss:GetAttribute("Shielded") == true then what = what .. "ลูกน้อง(บอสมีโล่)" end
		stats.farm = ("ดันเจี้ยน ด่าน %d/%d: %s %s (%d%%)%s"):format(run.stage, nStages, what, best.Name, hp,
			off > DG_HOLD_R and " · กลับกลางห้อง" or "")
		return true
	end
	-- room empty (next wave spawning / gate just opened): stand in the room's middle
	fightFocus = nil
	if center and flatDist(pos, center) > 10 then
		setAuto(false)
		if stuckFor > 3 then pathTo(hum, hrp, center) else pathReset(); dgWalk(hum, hrp, run, center) end
		stats.farm = ("ดันเจี้ยน ด่าน %d/%d: เดินไปห้องถัดไป (ห่าง %.0f)"):format(run.stage, nStages, flatDist(pos, center))
	else
		pathReset()
		setAuto(true)
		dgMark.at = now
		stats.farm = ("ดันเจี้ยน ด่าน %d/%d: รอมอนเวฟถัดไป"):format(run.stage, nStages)
	end
	return true
end

-- AUTO RESPAWN inside a run: the KNOCKED OUT card's RESPAWN button is
-- Net.event("Revive"):FireServer("respawn"). Only while respawns are left
-- (DungeonLives) -- at 0 the button would mean leaving the run.
-- Fallback: press the card's own RESPAWN button (fires its real click handlers), in
-- case the bare remote call isn't enough. Never the town / leave buttons.
local function dgClickRespawn()
	local pg = plr:FindFirstChildOfClass("PlayerGui")
	if not pg or type(getconnections) ~= "function" then return false end
	for _, b in ipairs(pg:GetDescendants()) do
		if b:IsA("GuiButton") and b.Visible then
			local txt = (b:IsA("TextButton") and b.Text or "")
			for _, l in ipairs(b:GetDescendants()) do
				if l:IsA("TextLabel") then txt = txt .. " " .. l.Text end
			end
			local up = txt:upper()
			if (up:find("RESPAWN") or txt:find("เกิดใหม่")) and not up:find("TOWN") and not txt:find("เมือง")
				and not up:find("LEAVE") and not txt:find("ออก") then
				local fired = false
				for _, sig in ipairs({b.Activated, b.MouseButton1Click}) do
					local okC, cons = pcall(getconnections, sig)
					if okC then for _, c in ipairs(cons) do pcall(function() c:Fire() end); fired = true end end
				end
				if fired then return true end
			end
		end
	end
	return false
end
task.spawn(function()
	local downAt, lastTry, tries = nil, 0, 0
	while alive() do
		task.wait(0.5)
		local okR, errR = pcall(function()
			local now = workspace:GetServerTimeNow()
			local du = tonumber(plr:GetAttribute("DownUntil")) or 0
			local _, hum0 = myChar()
			local isDown = plr:GetAttribute("DungeonRun") ~= nil and (du > now or (hum0 ~= nil and hum0.Health <= 0))
			if not isDown then
				if downAt then dgStats.respawn = ("เกิดใหม่แล้ว หลังตาย %.0f วิ (กด %d ครั้ง)"):format(os.clock() - downAt, tries) end
				downAt = nil; tries = 0
				return
			end
			downAt = downAt or os.clock()
			local lives = tonumber(plr:GetAttribute("DungeonLives")) or 0
			dgStats.respawn = ("ตายอยู่ %.0f วิ · เหลือเกิด %d · กดไป %d ครั้ง"):format(os.clock() - downAt, lives, tries)
			if not (e.phDgOn or e.phAutoRejoin) or lives <= 0 then return end
			if os.clock() - downAt < 1.5 or os.clock() - lastTry < 2 then return end
			lastTry = os.clock(); tries = tries + 1
			dgStats.status = ("ตาย: กดเกิดใหม่ (เหลือ %d)"):format(lives)
			Net.event("Revive"):FireServer("respawn")
			if tries >= 2 then dgClickRespawn() end   -- remote alone didn't take: click the button
		end)
		if not okR then dgStats.respawnErr = tostring(errR) end
	end
end)

-- server pushes: auto-join ready checks, count results
local dgConn
pcall(function()
	dgConn = Net.event("Effect").OnClientEvent:Connect(function(kind, data)
		if not alive() or kind ~= "Dungeon" or type(data) ~= "table" then return end
		if data.kind == "ready" and (e.phDgAccept or e.phDgReplay) then
			dgStats.status = ("รับคำเชิญ %s แล้ว"):format(tostring(data.leader or "หัวหน้า"))
			task.delay(0.6, function() if alive() then dgCall("ready", true) end end)
		elseif data.kind == "cancel" then
			dgStats.waitUntil = 0
			dgStats.status = "ready check ยกเลิก (" .. tostring(data.reason or "?") .. ")"
		elseif data.kind == "chest" then
			dgChestPos = typeof(data.position) == "Vector3" and data.position or nil
		elseif data.kind == "chestOpen" then
			dgStartLoot()
		elseif data.kind == "loading" or data.kind == "start" or data.kind == "restart" then
			dgStats.waitUntil = 0
			dgStats.startedAt = os.clock()
			shrinkZone = nil   -- new run: the old boss ring is gone
			dgLootPhase = nil; dgChestPos = nil
		elseif data.kind == "result" then
			dgStats.runs = dgStats.runs + 1
			if data.win ~= false then dgStats.wins = dgStats.wins + 1 end
			dgStats.lastSec = tonumber(data.seconds)
			dgStats.backAt = os.clock() + (tonumber(data.returnIn) or (DG and DG.returnDelay) or 15)
			-- the result card's REPLAY button = Dungeon:replay(id, diff), a party vote:
			-- once everyone voted the same run restarts without the trip to town
			if e.phDgReplay then
				local id = data.dungeon or plr:GetAttribute("DungeonRun")
				local diff = data.diff or plr:GetAttribute("DungeonDiff")
				local resAt = os.clock()
				task.spawn(function()
					task.wait(0.8)   -- the vote is a remote call; no need to wait for the card's art
				-- hold the vote until the chest's drops are picked up (capped: the game sends
				-- everyone home ~15s after the result)
				local tW = os.clock()
				while dgLootPhase and (e.phDgOn or e.phAutoRejoin) and os.clock() - tW < 10 and alive() do
					dgStats.status = "เก็บของจากหีบก่อน แล้วค่อยกด REPLAY"
					task.wait(0.2)
				end
				-- out of free runs and keys: buy one now so the REPLAY vote can go through
				if dgBuyKeyFwd and e.phDgBuyKeys and e.phDgUseKeys then
					local st = dgCall("state")
					local free = st.ok and type(st.free) == "table" and tonumber(st.free[id]) or 0
					if st.ok and free <= 0 then pcall(dgBuyKeyFwd, tonumber(st.keys) or 0) end
				end
					for _ = 1, 4 do
						if not alive() or not e.phDgReplay then return end
						-- the vote already went through (new run started): stop re-voting
						if (dgStats.startedAt or 0) > resAt then dgStats.status = "REPLAY: เริ่มรอบใหม่"; return end
						local r = dgCall("replay", id, diff)
						if r.ok then
							dgStats.status = r.waiting and "กด REPLAY แล้ว รอทุกคนโหวต" or "REPLAY: เริ่มรอบใหม่"
							dgStats.replays = (dgStats.replays or 0) + 1
							return
						end
						dgStats.status = "กด REPLAY ไม่ผ่าน: " .. tostring(r.error or "?")
						task.wait(2)
					end
				end)
			end
		elseif data.kind == "replayState" then
			local n = type(data.votes) == "table" and #data.votes or 0
			dgStats.status = ("โหวต REPLAY แล้ว %d คน"):format(n)
		end
	end)
end)
if dgConn then
	task.spawn(function() while alive() do task.wait(1) end; pcall(function() dgConn:Disconnect() end) end)
end

-- AUTO BUY KEY (only with the toggle on): out of free runs and at/below the keep-floor
-- -> buy ONE key (DG.keyPrice gold) via the dungeon panel's own "buyKey" call, never
-- taking gold below the floor. Returns true when a key was bought.
do   -- (block: the main chunk is at Luau's 200-local limit)
local dgBuyAt = 0
local function dgTryBuyKey(keys)
	if not (e.phDgBuyKeys and e.phDgUseKeys) then return false end
	if (tonumber(keys) or 0) > (tonumber(e.phDgKeepKeys) or 0) then return false end
	if os.clock() - dgBuyAt < 3 then return false end
	local price = tonumber(DG and DG.keyPrice) or 250000
	local gold = tonumber(plr:GetAttribute("Gold")) or 0
	local floor = (tonumber(e.phDgGoldFloor) or 0) * 1e6
	if gold - price < floor then
		dgStats.status = ("กุญแจหมด: ทองไม่พอซื้อ (เหลือ %.1fM เก็บไว้ %dM)"):format(gold / 1e6, tonumber(e.phDgGoldFloor) or 0)
		return false
	end
	dgBuyAt = os.clock()
	local r = dgCall("buyKey")
	if r.ok then
		dgStats.keys = tonumber(r.keys) or ((tonumber(keys) or 0) + 1)
		dgStats.bought = (dgStats.bought or 0) + 1
		dgStats.status = ("ซื้อกุญแจแล้ว (รวมซื้อ %d ดอก)"):format(dgStats.bought)
		return true
	end
	dgStats.status = "ซื้อกุญแจไม่ได้: " .. tostring(r.error or "?")
	return false
end
dgBuyKeyFwd = dgTryBuyKey
end

-- AUTO REJOIN: the "Disconnected / kicked" prompt sets GuiService's error message.
-- Teleport back into this game (a fresh server). Real's environment doesn't survive
-- the hop by itself -- cp_boot.lua re-queues itself with queue_on_teleport and loads
-- this script again, whose saved settings (Auto Dungeon / Auto Replay) take it from
-- town straight back into the dungeon.
pcall(function()
	local GuiService = game:GetService("GuiService")
	local TeleportService = game:GetService("TeleportService")
	local rejoining = false
	local function rejoin(why)
		if rejoining or not e.phAutoRejoin or not alive() then return end
		rejoining = true
		dgStats.status = "หลุด: กำลังเข้าเกมใหม่ (" .. tostring(why):sub(1, 40) .. ")"
		task.spawn(function()
			task.wait(3)
			for _ = 1, 30 do   -- servers can refuse for a while; keep trying ~5 min
				if not e.phAutoRejoin then break end
				pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
				task.wait(10)
			end
			rejoining = false
		end)
	end
	local c = GuiService.ErrorMessageChanged:Connect(function(msg)
		if type(msg) == "string" and msg ~= "" then rejoin(msg) end
	end)
	task.spawn(function() while alive() do task.wait(1) end; c:Disconnect() end)
end)

-- AUTO REPLAY: back in town -> enter again (solo, or as party leader). A party member
-- can't start a run; it rides the leader's ready check (auto-joined above).
task.spawn(function()
	while alive() do
		task.wait(1)
		-- Auto Start Dungeon (phAutoRejoin) also drives this: in town -> go in
		if not (e.phDgReplay or e.phAutoRejoin) then if not plr:GetAttribute("DungeonRun") then dgStats.status = "ปิดอยู่" end; continue end
		if plr:GetAttribute("DungeonRun") then dgStats.status = "อยู่ในรอบ"; continue end
		if not DG or not DG.enabled() then dgStats.status = "เกมปิดดันเจี้ยนอยู่"; continue end
		local now = os.clock()
		if now < dgStats.backAt + 3 then dgStats.status = "รอกลับเมือง"; continue end
		local inParty = (plr:GetAttribute("PartyId") or "") ~= ""
		if inParty and plr:GetAttribute("PartyLeader") ~= true then
			dgStats.status = "เป็นลูกปาร์ตี้: รอหัวหน้ากดเข้า (ยอมรับให้เอง)"
			continue
		end
		if now < dgStats.waitUntil then dgStats.status = "รอทุกคนกดพร้อม"; continue end
		if now - dgStats.lastTry < 8 then continue end
		dgStats.lastTry = now
		local id, diff = dgPick()
		local def = DG.byId[id]
		local dd = def and def.difficultyById and def.difficultyById[diff]
		if not (def and dd) or def.soon then dgStats.status = "ดันเจี้ยนที่เลือกยังไม่เปิด"; continue end
		local need = DG.minLevel(dd) or 0
		if (tonumber(plr:GetAttribute("Level")) or 1) < need then dgStats.status = ("เลเวลไม่ถึง (ต้อง %d)"):format(need); continue end
		local st = dgCall("state")
		if st.ok then
			dgStats.keys = tonumber(st.keys) or 0
			dgStats.free = type(st.free) == "table" and tonumber(st.free[id]) or 0
			if st.inRun then dgStats.status = "อยู่ในรอบ"; continue end
		end
		-- free runs first; keys only if allowed and above the keep-floor. Never buys keys.
		if def.keys and not def.unlimited and (dgStats.free or 0) <= 0 then
			if not e.phDgUseKeys then dgStats.status = "รอบฟรีหมด (ปิดใช้กุญแจ)"; continue end
			if (dgStats.keys or 0) <= (tonumber(e.phDgKeepKeys) or 0) and not dgBuyKeyFwd(dgStats.keys) then
				if not e.phDgBuyKeys then
					dgStats.status = ("กุญแจเหลือ %d (เก็บไว้ %d) หยุดเข้า"):format(dgStats.keys or 0, tonumber(e.phDgKeepKeys) or 0)
				end
				continue
			end
		end
		local r = dgCall("enter", id, diff)
		if r.ok and r.waiting then
			dgStats.waitUntil = os.clock() + ((DG.readySeconds or 20) + 5)
			dgStats.status = "เรียกปาร์ตี้ (ready check)"
		elseif r.ok then
			dgStats.status = "กำลังเข้าดันเจี้ยน"
			dgStats.lastTry = os.clock() + 7   -- loading screen
		else
			dgStats.lastErr = r.error and tostring(r.error) or "เข้าไม่ได้"
			dgStats.status = "เข้าไม่ได้: " .. dgStats.lastErr
			dgStats.lastTry = os.clock() + 7
		end
	end
end)

local wdPos, wdAt = nil, os.clock()
local stayAnchored, stayTarget = false, nil   -- stay-put mode: AUTO anchored on the spot / last target
-- how far (flat studs) stay-put may step off the spot to fight. Unset = by class:
-- ranged (attack range >= 20, e.g. Archer 38) = 0 feet locked; melee = 25
local function stayRadius()
	local r = tonumber(e.phStayRadius)
	if r then return math.max(0, r) end
	return ATTACK_RANGE >= 20 and 0 or 25
end
task.spawn(function()
	while alive() do
		task.wait(0.12)
		local inDungeon = plr:GetAttribute("DungeonRun") ~= nil
		if not (e.phFarm or e.phBossOn or e.phWBOn or e.phDgOn or e.phAutoRejoin) then stats.farm = "ปิดอยู่"; pathReset(); wdAt = os.clock(); continue end
		-- inside a dungeon run the field logic (warp stones, farm spot, field bosses,
		-- watchdog hops) must never run: a Warp from in here would drag us out
		if inDungeon and not (e.phDgOn or e.phAutoRejoin) then stats.farm = "อยู่ในดันเจี้ยน (Auto Dungeon ปิด)"; pathReset(); wdAt = os.clock(); continue end
		if not hooks() then stats.farm = "รอเข้าเกม"; continue end
		local _, hum, hrp = myChar()
		if not hrp then stats.farm = inDungeon and "ดันเจี้ยน: รอเกิดใหม่" or "รอเกิดใหม่"; wdAt = os.clock(); continue end
		-- AUTO RUN: our own MoveTo counts as walking (16) -- the game only runs (x1.5 = 24)
		-- for shift / its run toggle / its walker / a mount. Keep the run toggle on.
		if okMC and MoveCtl.toggleRun and MoveCtl.isRunning then
			if inDungeon or e.phBossOn or e.phWBOn then   -- dungeon / Auto Boss / Auto World Boss
				local okRun, running = pcall(MoveCtl.isRunning)
				if okRun and not running then
					pcall(MoveCtl.toggleRun); getgenv().__PHP_RUNON = true
				end
			elseif getgenv().__PHP_RUNON then
				-- back outside: hand the run toggle back the way we found it (Auto Boss untouched)
				getgenv().__PHP_RUNON = nil
				pcall(MoveCtl.toggleRun)
			end
		end
		-- the dodge loop owns movement while a skill telegraph covers us
		if dodging then
			wdAt = os.clock(); pathReset()
			if inDungeon and (e.phDgOn or e.phAutoRejoin) then pcall(dgPotion, hum) end   -- still drink while stepping out
			continue
		end
		if inDungeon then
			wdAt = os.clock()
			if getgenv().__PHP_OLDRANGE and GSettings then   -- stay-put's tight autoRange off in here
				pcall(function() GSettings.set("autoRange", getgenv().__PHP_OLDRANGE) end)
				getgenv().__PHP_OLDRANGE = nil; getgenv().__PHP_SETRANGE = nil
			end
			stayAnchored = false
			local okT, errT = pcall(dgTick, hum, hrp)
			if not okT then stats.farm = "ดันเจี้ยน error: " .. tostring(errT) end
			continue
		end
		-- not in a run and Auto Dungeon is the only mode on: idle in town (replay loop drives)
		if not (e.phFarm or e.phBossOn or e.phWBOn) then stats.farm = "รอรอบดันเจี้ยนถัดไป"; pathReset(); wdAt = os.clock(); continue end

		-- WATCHDOG (unattended insurance): if the character is totally frozen -- no
		-- 4-stud move for 30s -- it's wedged in a state pathTo can't see. Teleport-hop
		-- a few ground-snapped steps toward the field entrance and re-pick fresh, so
		-- an overnight AFK run can never sit stuck in one spot.
		if not wdPos or (hrp.Position - wdPos).Magnitude > 4 then wdPos = hrp.Position; wdAt = os.clock() end
		if os.clock() - wdAt > 30 then
			wdAt = os.clock()
			local f = fieldAt(hrp.Position)
			local flat = f and f.entrance and Vector3.new(f.entrance.X - hrp.Position.X, 0, f.entrance.Z - hrp.Position.Z)
			local dir = (flat and flat.Magnitude > 1) and flat.Unit
				or Vector3.new(math.random() * 2 - 1, 0, math.random() * 2 - 1).Unit
			for _ = 1, 4 do
				local hopXZ = hrp.Position + dir * 10
				HOP_PARAMS.FilterDescendantsInstances = {hrp.Parent, workspace:FindFirstChild("Monsters")}
				local hit = workspace:Raycast(hopXZ + Vector3.new(0, 12, 0), Vector3.new(0, -80, 0), HOP_PARAMS)
				if hit then hrp.CFrame = CFrame.new(hit.Position + Vector3.new(0, 3, 0)) end
				task.wait(0.12)
			end
			for k in pairs(skipUntil) do skipUntil[k] = nil end
			farmTarget = nil; engagingFarm = false; engagingBoss = false; pathReset()
			wdPos = hrp.Position
			stats.farm = "แก้ติด (watchdog เด้งหลุด)"
			stats.watchdog = (stats.watchdog or 0) + 1
			continue
		end

		-- BOSS LOOT: the boss we were fighting just died -> stay and pick up its drops
		-- before warping/walking anywhere (wait ~2.5s for them to land, max 10s).
		if lastBoss and (not lastBoss.Parent or (tonumber(lastBoss:GetAttribute("Health")) or 0) <= 0) then
			local now0 = os.clock()
			-- world boss: rewards arrive after the game's ~9s results screen and scatter
			-- wider -> wait it out and sweep longer/wider so nothing is left behind
			lootPhase = lastBossWB
				and {center = lastBossPos or hrp.Position, minT = now0 + 11, untilT = now0 + 40, radius = 100, ignore = {}, nearAt = {}}
				or {center = lastBossPos or hrp.Position, minT = now0 + 2.5, untilT = now0 + 18, radius = 80, ignore = {}, nearAt = {}}
			fightArena = nil
			stats.kills = (stats.kills or 0) + 1
			stats.bossKills = (stats.bossKills or 0) + 1
			local lf = workspace:FindFirstChild("LootDrops")
			for _, p in ipairs(lf and lf:GetChildren() or {}) do lootPhase.ignore[p] = true end   -- pre-existing = not ours
			lastBoss = nil
			fightFocus = nil
		end
		if lootPhase then
			local now0 = os.clock()
			if now0 > lootPhase.untilT then
				lootPhase = nil
			else
				local drop, dd = nearestLoot(lootPhase.center, hrp.Position)
				-- a drop we've been walking to for 5s without reaching (on a cliff lip,
				-- off the walkable area) is skipped instead of circling it for the full phase
				if drop then
					if lootPhase.cur ~= drop then lootPhase.cur = drop; lootPhase.curAt = now0 end
					if now0 - lootPhase.curAt > 5 and dd > 8 then
						lootPhase.ignore[drop] = true
						drop = nil
					end
				end
				if drop then
					setAuto(false)   -- don't let auto drag us to a monster mid-pickup
					wdAt = os.clock()
					-- within 5 of where it lies is well inside the game's 12-stud take range
					if dd > 5 then pathTo(hum, hrp, drop.Position) else pathReset() end
					stats.farm = "เก็บของบอส"
					continue
				elseif now0 < lootPhase.minT then
					wdAt = os.clock()
					stats.farm = "รอของบอสดรอป"
					continue
				end
				lootPhase = nil
			end
		end

		-- AUTO-WARP: if we're not in the field we should be in (e.g. dumped in town
		-- after a death, or the selected boss is in another field), walk onto the
		-- nearest WarpStone and fire the Warp remote. This is what lets farming/boss
		-- resume after dying instead of standing in town.
		do
			local curF = fieldAt(hrp.Position)
			local wf = wantedField(curF and curF.id)
			if wf and (not curF or curF.id ~= wf) then
				engagingFarm = false; engagingBoss = false
				local stone, sd = nearestStone(hrp.Position)
				if stone and sd and sd > 6 then
					setAuto(false); pathTo(hum, hrp, stone)
					stats.farm = ("ไปหินวาร์ป -> %s (ห่าง %.0f)"):format(wf, sd)
				elseif stone then
					-- The warp is now a 3s CAST (HomeCast effect, 3-2-1 over the head) that
					-- the game cancels the moment we move. So: come to a full stop first,
					-- fire once, then stand still -- no re-fire inside the cast (re-firing
					-- every 2.5s restarted it before it could land = the "slow warp").
					setAuto(false); pathReset()
					if PW then pcall(PW.stop) end   -- never carry a walk across a warp
					lootPhase = nil
					local vel = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z).Magnitude
					local since = os.clock() - lastWarpFire
					if since > 5.5 then
						if vel > 1.5 then
							hum:MoveTo(hrp.Position)   -- still sliding in: stop, fire next tick
							stats.farm = "วาร์ปไป " .. wf .. " (หยุดนิ่งก่อนร่าย)"
						else
							hum:MoveTo(hrp.Position)
							pcall(function() Net.event("Warp"):FireServer(wf) end)
							lastWarpFire = os.clock()
							stats.farm = "วาร์ปไป " .. wf .. " (ยืนร่าย 3 วิ)"
						end
					else
						stats.farm = ("วาร์ปไป %s (ยืนร่าย %.1f วิ)"):format(wf, math.max(0, 3.2 - since))
					end
					wdAt = os.clock()
				else
					stats.farm = "หา WarpStone ไม่เจอ"
				end
				continue
			end
		end

		-- Drive a boss trip: travel (auto off, pathfind) until close, then hold auto
		-- ON and FOLLOW the roaming boss until it's really far (35) -- hysteresis so
		-- small boss moves don't flip the mode off and interrupt attacks.
		local function fightBoss(boss, tag)
			needReturn = true
			lastBoss, lastBossPos = boss, boss.PrimaryPart.Position   -- for the loot phase
			-- SHIELD PHASE: the boss raises a shield (Shielded=true) and spawns BossAdd
			-- helpers; attacking the boss does nothing until they die (they may also heal
			-- it). Target the nearest add until the shield drops, then the boss again.
			fightFocus = boss
			local isWB = boss:GetAttribute("WorldBoss") ~= nil
			lastBossWB = isWB
			-- the circle this boss is tied to
			local ai = (not isWB) and arenaInfo(fieldAt(boss.PrimaryPart.Position)) or nil
			if isWB then
				local spot = game:GetService("ReplicatedStorage"):GetAttribute("WorldBossSpot")
				local ac = boss:GetAttribute("ArenaCenter")
				local c = typeof(spot) == "Vector3" and spot or (typeof(ac) == "Vector3" and ac) or nil
				local r = tonumber(boss:GetAttribute("ArenaRadius")) or WB_ARENA_R
				fightArena = c and {center = c, radius = r} or nil
			elseif ai and flatDist(boss.PrimaryPart.Position, ai.center) < ai.radius + 10 then
				fightArena = {center = ai.center, radius = ai.radius}
			else
				fightArena = nil
			end
			-- shield phase: kill its helpers -- but only ones INSIDE its circle (chasing a
			-- helper out of the circle drags the boss after us and it leashes/resets)
			local t, addMode = boss, false
			if boss:GetAttribute("Shielded") == true then
				local best, bestD
				local M = workspace:FindFirstChild("Monsters")
				for _, j in ipairs(M and M:GetChildren() or {}) do
					if j:GetAttribute("BossAdd") and j.PrimaryPart and (tonumber(j:GetAttribute("Health")) or 0) > 0
						and inFightArena(j.PrimaryPart.Position, 0) then
						local d = flatDist(j.PrimaryPart.Position, hrp.Position)
						if not best or d < bestD then best, bestD = j, d end
					end
				end
				if best then t, addMode = best, true end
			end
			-- not up on the boss's arena yet: take the known ramp first
			if ai and flatDist(boss.PrimaryPart.Position, ai.center) < ai.radius + 10 and climbToArena(hum, hrp, ai) then
				stats.farm = ("ขึ้นทางลาดลานบอส %s"):format(boss.Name)
				return
			end
			-- outside the boss's circle (knocked out / walked out): get back in first
			if fightArena and not dodging and not inFightArena(hrp.Position, 2) then
				local c = fightArena.center
				local dir = Vector3.new(hrp.Position.X - c.X, 0, hrp.Position.Z - c.Z)
				local back = dir.Magnitude > 0.5 and (Vector3.new(c.X, hrp.Position.Y, c.Z) + dir.Unit * (fightArena.radius - 8))
					or Vector3.new(c.X, hrp.Position.Y, c.Z)
				setAuto(true)
				if TC.current ~= t then pcall(TC.set, t) end
				if flatDist(hrp.Position, c) > fightArena.radius + 25 then pathTo(hum, hrp, back) else hum:MoveTo(back) end
				stats.farm = ("กลับเข้าวงบอส %s"):format(boss.Name)
				return
			end
			pathReset()   -- our own walk (if any) yields to the game's chase
			local r = engageTarget(hum, hrp, t, true)
			engagingBoss = (r == "fight")
			if r == "fight" then wdAt = os.clock() end   -- standing to shoot is not "stuck"
			if addMode then
				stats.farm = ("%s: กำจัดลูกน้อง (โล่ %s)"):format(tag, boss.Name)
			elseif r == "fight" then
				stats.farm = ("%s %s (เลือด %d%%)"):format(tag, boss.Name,
					math.floor((tonumber(boss:GetAttribute("Health")) or 0) / math.max(tonumber(boss:GetAttribute("MaxHealth")) or 1, 1) * 100))
			else
				stats.farm = ("ไป%s %s (ห่าง %.0f)"):format(tag, boss.Name, (t.PrimaryPart.Position - hrp.Position).Magnitude)
			end
		end

		-- WORLD BOSS first (rare event), then FIELD BOSS
		if e.phWBOn then
			local wb = findWorldBoss(hrp)
			if wb and wb.PrimaryPart then fightBoss(wb, "ตีบอสโลก"); continue end
			-- announced but not landed yet: be standing at its landing spot when it does
			-- (auto-warp above already brought us to its field)
			local w = wbWanted()
			if w and w.state == "soon" and not w.live then
				local curF = fieldAt(hrp.Position)
				local dest = w.landing or w.spot
				if curF and curF.id == w.field and dest then
					local left = w.at and math.max(0, math.ceil(w.at - workspace:GetServerTimeNow())) or 0
					wdAt = os.clock()
					if flatDist(hrp.Position, dest) > 8 then
						setAuto(false)
						pathTo(hum, hrp, dest)
						stats.farm = ("ไปรอบอสโลก %s (ลงใน %d:%02d)"):format(w.name, left // 60, left % 60)
					else
						pathReset()
						setAuto(true)   -- swat whatever wanders in while we wait
						stats.farm = ("รอบอสโลก %s ลงจอด %d:%02d"):format(w.name, left // 60, left % 60)
					end
					continue
				end
			end
		end
		if e.phBossOn then
			local boss = findBossTarget(hrp)
			if boss and boss.PrimaryPart then fightBoss(boss, "ตีบอส"); continue end
		end

		-- PARTY CHESTS: the server only accepts the Open Chest prompt within ~10 studs
		-- (tested: fired from 613 studs = rejected), so instead of opening from afar we
		-- walk to any chest in this field within 150 studs, open it on arrival (the chest
		-- loop fires the prompt instantly, no hold), then the normal flow resumes. Runs
		-- only when no boss needed us this tick. A chest we've stood next to for 4s
		-- that's still there isn't ours to open -> ignored.
		if e.phChest and e.phChestWalk then
			local myF = fieldAt(hrp.Position)
			local best, bestD
			for _, ch in ipairs(workspace:GetChildren()) do
				if ch.Name == "Party Chest" and not chestIgnore[ch] then
					local base = ch:FindFirstChild("Base")
					local prompt = base and base:FindFirstChildWhichIsA("ProximityPrompt")
					if base and prompt and prompt.Enabled then
						local cf = fieldAt(base.Position)
						local d = flatDist(base.Position, hrp.Position)
						if d <= 150 and (not myF or (cf and cf.id == myF.id)) and (not best or d < bestD) then best, bestD = ch, d end
					end
				end
			end
			if best then
				local base = best.Base
				wdAt = os.clock()
				if bestD > 6 then
					chestNear[best] = nil
					setAuto(false)
					pathTo(hum, hrp, base.Position)
					stats.farm = ("ไปเปิดกล่องปาร์ตี้ (ห่าง %.0f)"):format(bestD)
				else
					pathReset()
					local prompt = base:FindFirstChildWhichIsA("ProximityPrompt")
					if prompt then pcall(fireproximityprompt, prompt) end
					chestNear[best] = chestNear[best] or os.clock()
					if os.clock() - chestNear[best] > 4 then chestIgnore[best] = true end
					stats.farm = "เปิดกล่องปาร์ตี้"
				end
				continue
			end
		end

		-- no boss up: any boss mode on -> walk back to the saved farm spot after a
		-- trip. Full 3D distance (the arena often sits directly ABOVE the farm spot,
		-- same X/Z higher Y, so a flat check would strand us up there).
		if e.phBossOn or e.phWBOn then
			engagingBoss = false
			if needReturn and type(e.phFarmPos) == "table" and e.phFarmPos.x then
				local fp = Vector3.new(e.phFarmPos.x, e.phFarmPos.y, e.phFarmPos.z)
				if (hrp.Position - fp).Magnitude > ENGAGE_DIST then
					setAuto(false); pathTo(hum, hrp, fp)
					stats.farm = "กลับจุดฟาร์ม"
					continue
				end
				needReturn = false; pathReset()
			end
			-- otherwise fall through to the farm block below: while the boss isn't
			-- available yet (not up, or my level hasn't reached it) we actively farm
			-- the field's best monsters via pickTarget so we level toward the boss.
		end

		-- STAY PUT: farm spot saved and we're in its field -> stand exactly on it and only
		-- shoot what's within attack range of it; never walk after monsters. Uses the
		-- game's own autoStay (AUTO anchors to where it was switched on) with autoRange
		-- clamped to our attack range so its auto-picks never need a step either.
		local spot = e.phStayPut and farmAnchor(hrp)
		if spot then
			-- R = how far from the spot we may step out (0 = feet locked: ranged classes
			-- shoot everything from the spot; melee needs room, so it walks out to fight
			-- inside R and comes back when nothing's left / when dragged past R)
			local R = stayRadius()
			local sp = hrp.Position
			local atSpot = flatDist(sp, spot) <= 2.5 and math.abs(sp.Y - spot.Y) <= 4
			local function inZone(m)
				local mp = m.PrimaryPart.Position
				local reach = ATTACK_RANGE + (tonumber(m:GetAttribute("Radius")) or 1) - 0.5
				return flatDist(mp, spot) <= R + reach and math.abs(mp.Y - spot.Y) < 25
			end
			-- best monster in the zone: in the level window first, then nearest the spot
			local myLv = tonumber(plr:GetAttribute("Level")) or 1
			local below = tonumber(e.phFarmBelow) or 99
			local above = tonumber(e.phFarmAbove) or 10
			local targetLv = myLv - below + above
			local best, bestScore
			for _, m in ipairs(workspace.Monsters:GetChildren()) do
				if m.PrimaryPart and (tonumber(m:GetAttribute("Health")) or 0) > 0 and m:GetAttribute("Dummy") ~= true
					and (m:GetAttribute("IsBoss") ~= true or e.phFarmBoss) and inZone(m) then
					local lv = tonumber(m:GetAttribute("Level")) or 0
					local inWin = lv >= myLv - below and lv <= myLv + above
					local score = (inWin and 0 or 1000) + math.abs(lv - targetLv) * 10 + flatDist(m.PrimaryPart.Position, spot)
					if not best or score < bestScore then best, bestScore = m, score end
				end
			end
			local cur = TC.current
			if cur and (not cur.Parent or (tonumber(cur:GetAttribute("Health")) or 0) <= 0) then cur = nil end
			if stayTarget and stayTarget ~= cur and (not stayTarget.Parent or (tonumber(stayTarget:GetAttribute("Health")) or 0) <= 0) then
				stats.kills = (stats.kills or 0) + 1
			end
			if cur and cur.PrimaryPart and not inZone(cur) then pcall(TC.set, nil); cur = nil end   -- never chase out of the zone
			-- walk back to the spot when: feet-lock mode and we're off it; dragged past
			-- R; or nothing left to fight in the zone
			local tooFar = flatDist(sp, spot) > R + 6
			if (R == 0 and not atSpot) or tooFar or (not atSpot and not cur and not best) then
				stayAnchored = false
				if tooFar then pcall(TC.set, nil) end
				setAuto(false)
				pathTo(hum, hrp, spot)
				stats.farm = ("กลับไปยืนจุดฟาร์ม (ห่าง %.0f)"):format(flatDist(sp, spot))
				continue
			end
			pathReset()
			wdAt = os.clock()
			-- the game's own auto stays inside the same zone: autoStay + autoRange
			local wantRange = math.clamp(math.floor(R + ATTACK_RANGE), 20, 150)
			if GSettings and getgenv().__PHP_SETRANGE ~= wantRange then
				pcall(function()
					if not getgenv().__PHP_OLDRANGE then getgenv().__PHP_OLDRANGE = GSettings.get("autoRange") end
					GSettings.set("autoRange", wantRange)
					if GSettings.get("autoStay") ~= true then GSettings.set("autoStay", true) end
					getgenv().__PHP_SETRANGE = wantRange
				end)
			end
			if atSpot and not stayAnchored then
				-- re-anchor the game's AUTO on this exact spot (it anchors where it's turned on)
				pcall(TC.setAuto, false); pcall(TC.setAuto, true)
				stayAnchored = true
			end
			setAuto(true)
			-- keep hitting the current one until it dies (no flip-flopping); then the best
			if not cur and best then pcall(TC.set, best); cur = best end
			stayTarget = cur
			stats.farm = cur and ("%s: %s L%d"):format(R == 0 and "ยืนตีที่จุดฟาร์ม" or "ตีรอบจุดฟาร์ม", cur.Name, tonumber(cur:GetAttribute("Level")) or 0)
				or "ยืนรอมอนเข้าระยะที่จุดฟาร์ม"
			continue
		elseif getgenv().__PHP_OLDRANGE and GSettings then
			-- stay mode off (or no spot here): give the player's autoRange back
			pcall(function() GSettings.set("autoRange", getgenv().__PHP_OLDRANGE) end)
			getgenv().__PHP_OLDRANGE = nil
			getgenv().__PHP_SETRANGE = nil
		end
		stayAnchored = false

		local t = farmTarget
		local now = os.clock()
		local dead = not (t and t.Parent and (tonumber(t:GetAttribute("Health")) or 0) > 0)
		if dead and t and engagingFarm then stats.kills = (stats.kills or 0) + 1; engagingFarm = false end
		-- re-pick when the target died, or ~once a second while still walking to a
		-- far one (so a closer/stronger monster that wandered in gets taken instead)
		local far = t and t.PrimaryPart and (t.PrimaryPart.Position - hrp.Position).Magnitude > ENGAGE_DIST
		if dead or (far and now - lastPick > 1) then
			lastPick = now
			local nt = pickTarget(hrp)
			if nt ~= t then farmTarget, t, travelStart = nt, nt, now; pathReset() end
		end

		-- Boss mode with no boss up: field bosses spawn at the BossArena on a timer
		-- (no summon prompt), so camp the arena and farm there -- when the boss
		-- pops within NEAR_RADIUS it gets picked next tick. Only kick in when the
		-- current pick isn't already a boss and we're not near the arena yet.
		local tIsBoss = t and t:GetAttribute("IsBoss") == true
		local myF = fieldAt(hrp.Position)
		-- only camp the boss arena if this field's boss is actually eligible:
		-- not already cleared, and my level has reached it (user: don't walk to the
		-- boss when my level hasn't reached the next field yet).
		local fbid = myF and myF.boss
		local fbEligible = fbid
			and not (e.phBossUnbeaten and plr:GetAttribute("Beat_" .. tostring(fbid)) == true)
			and ((not e.phBossWaitLv) or (tonumber(plr:GetAttribute("Level")) or 1) >= (BOSS_LV[fbid] or 0))
		local arena = e.phFarmBoss and fbEligible and myF and myF.arena and myF.arena.center
		if arena and not tIsBoss then
			local ac = (typeof(arena) == "Vector3") and arena or Vector3.new(arena.X or arena[1] or 436, 0, arena.Z or arena[3] or 112)
			-- config arena centers are at y=0 (underground): snap onto the real ArenaFloor,
			-- or the walkers path toward a point inside the terrain and never arrive
			HOP_PARAMS.FilterDescendantsInstances = {plr.Character, workspace:FindFirstChild("Monsters"), workspace:FindFirstChild("BossFx")}
			local gHit = workspace:Raycast(Vector3.new(ac.X, hrp.Position.Y + 120, ac.Z), Vector3.new(0, -300, 0), HOP_PARAMS)
			if gHit then ac = gHit.Position end
			if (Vector3.new(hrp.Position.X - ac.X, 0, hrp.Position.Z - ac.Z)).Magnitude > 55 then
				setAuto(false)
				pathTo(hum, hrp, ac)
				stats.farm = "ไปรอบอสที่ลานบอส (" .. (myF.name or myF.id) .. ")"
				continue
			end
		end

		if not (t and t.PrimaryPart) then
			engagingFarm = false
			setAuto(false)
			-- nothing alive near the farm spot: walk back onto it and wait for respawns
			-- there, instead of standing wherever the last kill happened
			local anc = farmAnchor(hrp)
			if anc and flatDist(hrp.Position, anc) > 10 then
				pathTo(hum, hrp, anc)
				stats.farm = "กลับจุดฟาร์ม (รอมอนเกิด)"
				continue
			end
			local f = fieldAt(hrp.Position)
			wdAt = os.clock()   -- waiting on the spot for respawns is not "stuck"
			stats.farm = f and ("ไม่เจอมอนในฟิลด์ " .. (f.name or f.id) .. (e.phFarmBoss and " (รอบอสเกิด)" or "")) or "ไม่เจอมอนในฟิลด์นี้"
		else
			local d = (t.PrimaryPart.Position - hrp.Position).Magnitude
			local boss = (t:GetAttribute("IsBoss") == true)
			if boss then
				-- field boss picked in farm mode ("ตีบอสฟิลด์ด้วย"): same treatment as
				-- Auto Boss -- known ramp onto the arena, stand close, kill the adds while
				-- it's shielded, loot afterwards
				fightBoss(t, "ตีบอส")
				continue
			end
			-- AUTO on + click the target: the game chases (PathWalker), shoots and casts
			-- skills; engageTarget only supervises the chase and reports a hopeless one.
			pathReset()
			local r = engageTarget(hum, hrp, t)
			if r == "stuck" then
				skipUntil[t] = os.clock() + 12   -- unreachable (wall / bad terrain): pick another
				farmTarget = nil
				engagingFarm = false
			elseif r == "fight" then
				engagingFarm = true
				travelStart = os.clock()
				-- a ranged class shoots from one spot for minutes: the watchdog must
				-- not read that as "frozen" (it was teleport-hopping us away from the
				-- monsters every 30s -- the "warping away while farming" bug)
				wdAt = os.clock()
				stats.farm = ("%s %s L%d"):format(boss and "ตีบอส" or "ตี", t.Name, tonumber(t:GetAttribute("Level")) or 0)
			else
				engagingFarm = false
				stats.farm = ("%s %s L%d (ห่าง %.0f)"):format(boss and "ไปตีบอส" or "เดินไปหา",
					t.Name, tonumber(t:GetAttribute("Level")) or 0, d)
			end
		end
	end
end)

-- -------------------------------------------------------------- auto chest
-- Party Chests drop in the world with an "Open Chest" ProximityPrompt. Fire it
-- the moment one is in range (fireproximityprompt skips the hold), so chests get
-- opened instantly while you farm near them.
task.spawn(function()
	local total = 0
	while alive() do
		task.wait(0.4)
		if not e.phChest then stats.chest = "ปิดอยู่"; continue end
		local _, _, hrp = myChar()
		if not hrp then continue end
		local opened = 0
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.Enabled
				and (d.Name == "PartyChestPrompt" or d.ActionText == "Open Chest" or d.ObjectText == "Party Chest") then
				local part = d.Parent
				local pos = part and (part:IsA("BasePart") and part.Position
					or (part:IsA("Model") and select(1, part:GetBoundingBox()).Position))
				local maxd = d.MaxActivationDistance > 0 and d.MaxActivationDistance or 14
				if pos and (pos - hrp.Position).Magnitude <= maxd + 2 then
					local ok = pcall(function() fireproximityprompt(d) end)
					if ok then opened += 1; total += 1 end
				end
			end
		end
		stats.chest = opened > 0 and ("เพิ่งเปิด " .. opened .. " กล่อง (รวม " .. total .. ")")
			or ("เฝ้ารอกล่อง (เปิดแล้ว " .. total .. ")")
	end
end)

-- --------------------------------------------------------------- auto sell
-- Build the sell list exactly like the Bag's sellAllPick: by selected tier, not
-- locked, not equipped, sellPrice > 0; then fire the Bag's own sell remote one
-- item at a time with small delays so it reads like manual selling.
local function sellScan()
	if not hooks() then return {}, 0 end
	local ok, g = pcall(GearState.get)
	if not ok or type(g) ~= "table" or type(g.gear) ~= "table" then return {}, 0 end
	local equipped = {}
	for _, uid in pairs(g.equipped or {}) do equipped[uid] = true end
	local list, gold = {}, 0
	for uid, piece in pairs(g.gear) do
		local def = Equipment.defs[piece.id]
		if def and not piece.locked and not equipped[uid] and (tonumber(def.sellPrice) or 0) > 0
			and not NEVER_SELL[tierOf(def)] then
			local tier = tierOf(def)
			local label = TIER_LABELS[tier]
			-- rarity picked; then its level filter: none picked = every level of it
			local lvs = e.phSellLv[tostring(tier)]
			local anyLv = false
			if type(lvs) == "table" then for _, on in pairs(lvs) do if on then anyLv = true; break end end end
			local lvOk = (not anyLv) or lvs[tostring(def.level)] == true
			if e.phSellTiers[label] and lvOk then
				table.insert(list, uid)
				gold += tonumber(def.sellPrice) or 0
			end
		end
	end
	return list, gold
end

local function sellNow()
	local list = sellScan()
	for _, uid in ipairs(list) do
		if not alive() or not e.phSellOn then break end
		pcall(function() gearRemote:FireServer("sell", uid) end)
		stats.sold += 1
		task.wait(0.15)
	end
	return #list
end

-- Monster junk: Items type "material" (Sugar Cube, Lava Rock, boss feathers...). They
-- have no recipe or other use anywhere in the game's configs -- only monster drop
-- tables -- so they exist to be sold. Counts live as attributes on plr.Inventory.
-- Selling uses the item shop's own SELL LOOT action: Net.func("Shop"):InvokeServer(
-- "sellMaterials"), which sells every material and nothing else.
local function matScan()
	local inv = plr:FindFirstChild("Inventory")
	local okI, Items = pcall(require, RS.Shared.Config.Items)
	if not (inv and okI) then return 0, 0 end
	local n, gold = 0, 0
	for id, cnt in pairs(inv:GetAttributes()) do
		local d = Items.defs[id]
		if d and d.type == "material" and tonumber(cnt) and cnt > 0 then
			n += cnt; gold += cnt * (tonumber(d.sellPrice) or 0)
		end
	end
	return n, gold
end
stats.mats = "ปิดอยู่"
task.spawn(function()
	while alive() do
		task.wait(3)
		if not e.phSellMats then stats.mats = "ปิดอยู่"; continue end
		local n, gold = matScan()
		if n <= 0 then stats.mats = "ไม่มีวัตถุดิบให้ขาย"; continue end
		local ok, res = pcall(function() return Net.func("Shop"):InvokeServer("sellMaterials") end)
		if ok and type(res) == "table" and res.ok then
			stats.matsSold = (stats.matsSold or 0) + n
			stats.mats = ("ขายวัตถุดิบ %d ชิ้น (~%d ทอง) แล้ว"):format(n, gold)
		else
			stats.mats = "ขายไม่สำเร็จ: " .. tostring(type(res) == "table" and res.error or res)
		end
		local wait = math.max(tonumber(e.phSellEvery) or 20, 10)
		for _ = 1, wait do if not alive() or not e.phSellMats then break end task.wait(1) end
	end
end)

task.spawn(function()
	while alive() do
		if not e.phSellOn then stats.sell = "ปิดอยู่"; task.wait(1); continue end
		if not hooks() then stats.sell = "รอเข้าเกม"; task.wait(2); continue end
		local pending, gold = sellScan()
		if #pending > 0 then
			stats.sell = ("กำลังขาย %d ชิ้น (~%d Gold)"):format(#pending, gold)
			sellNow()
		else
			stats.sell = "ไม่มีของเข้าเงื่อนไข"
		end
		local wait = math.max(tonumber(e.phSellEvery) or 20, 5)
		for _ = 1, wait do if not alive() or not e.phSellOn then break end task.wait(1) end
	end
end)

-- ------------------------------------------------------------- auto collect
-- The game auto-collects loot while its "autoPickup" setting is on, and with no
-- kind filter set it grabs every kind. This just guarantees autoPickup stays on
-- (re-enables it if it ever gets switched off), so nothing is left on the ground.
task.spawn(function()
	while alive() do
		task.wait(3)
		if not e.phCollect then stats.collect = "ปิดอยู่"; continue end
		if not GSettings then stats.collect = "รอเข้าเกม"; continue end
		local on = false
		pcall(function()
			if GSettings.get("autoPickup") ~= true then GSettings.set("autoPickup", true) end
			on = GSettings.get("autoPickup") == true
		end)
		stats.collect = on and "เปิดเก็บของอัตโนมัติ" or "ตั้งค่าไม่ได้"
	end
end)

-- --------------------------------------------------------- auto equip best
-- For each slot, the owned item with the highest (level, tier, refine) that your
-- class can wear. Equip it only when it isn't already the equipped one.
local function equipBest()
	if not hooks() then return end
	local ok, g = pcall(GearState.get)
	if not ok or type(g) ~= "table" or type(g.gear) ~= "table" then return end
	local myClass = plr:GetAttribute("Class")
	local equipped = g.equipped or {}
	local function scoreOf(uid)
		local piece = g.gear[uid]
		local def = piece and Equipment.defs[piece.id]
		if not def then return -1 end
		return (tonumber(def.level) or 0) * 1e6 + (tonumber(def.lines) or 0) * 1e3 + (tonumber(piece.refine) or 0)
	end
	local best = {}
	for uid, piece in pairs(g.gear) do
		local def = Equipment.defs[piece.id]
		if def and (def.class == nil or def.class == myClass) then
			local slot = def.type
			local score = scoreOf(uid)
			if not best[slot] or score > best[slot].score then
				best[slot] = {uid = uid, score = score}
			end
		end
	end
	local did = 0
	for _, slot in ipairs(SLOTS) do
		local b = best[slot]
		-- swap only when the best is STRICTLY better than what's on (equal-score
		-- duplicates, e.g. two identical caps, must not churn the equip remote)
		if b and equipped[slot] ~= b.uid and b.score > scoreOf(equipped[slot]) then
			pcall(function() gearRemote:FireServer("equip", b.uid) end)
			did += 1
			stats.equipped += 1
			task.wait(0.15)
		end
	end
	stats.equip = did > 0 and ("สวมเพิ่ม " .. did .. " ชิ้น") or "ดีสุดแล้ว"
end

task.spawn(function()
	while alive() do
		if not e.phEquip then stats.equip = "ปิดอยู่"; task.wait(1); continue end
		if not hooks() then stats.equip = "รอเข้าเกม"; task.wait(2); continue end
		equipBest()
		local wait = math.max(tonumber(e.phEquipEvery) or 15, 5)
		for _ = 1, wait do if not alive() or not e.phEquip then break end task.wait(1) end
	end
end)

-- ---------------------------------------------------------------------- UI
print("[PetHunt] Loading MacLib...")
local ok, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not ok or not Lib then print("[PetHunt] MacLib failed: " .. tostring(Lib)) return end
task.wait()
if not alive() then return end

local W = Lib:Window({Title = "Pet Hunt Party", Subtitle = "Auto", DragStyle = 1,
	ShowUserInfo = true, AcrylicBlur = false})
getgenv().__PHPW = W
local TG = W:TabGroup()
local Tabs = {
	Farm = TG:Tab({Name = "Auto Farm", Image = "rbxassetid://10723343321"}),
	Boss = TG:Tab({Name = "Auto Boss", Image = "rbxassetid://10723346959"}),
	Dungeon = TG:Tab({Name = "ดันเจี้ยน", Image = "rbxassetid://10723396107"}),
	Sell = TG:Tab({Name = "Auto Sell", Image = "rbxassetid://10709769841"}),
	Gear = TG:Tab({Name = "เก็บ/สวม", Image = "rbxassetid://10723345576"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}

-- Farm tab
local FL = Tabs.Farm:Section({Side = "Left"})
FL:Header({Text = "Auto Farm" })
FL:Toggle({Name = "เปิด Auto Farm (เดินหามอนเลเวลสูงสุดในฟิลด์)", Default = e.phFarm,
	Callback = function(v) e.phFarm = v; sv() end}, "PHFarm")
FL:Toggle({Name = "ตีบอสฟิลด์ด้วย (ปลดล็อกฟิลด์ถัดไป)", Default = e.phFarmBoss,
	Callback = function(v) e.phFarmBoss = v; sv() end}, "PHFarmBoss")
FL:Toggle({Name = "└ ข้ามบอสที่ตีผ่านแล้ว (ปลดล็อกด่านแล้ว)", Default = e.phBossUnbeaten,
	Callback = function(v) e.phBossUnbeaten = v; sv() end}, "PHBossUnbeaten")
FL:Toggle({Name = "ฟาร์มที่จุดฟาร์ม (ล็อกจุดยืน)", Default = e.phStayPut,
	Callback = function(v) e.phStayPut = v; sv() end}, "PHStayPut")
FL:Slider({Name = "└ ระยะเดินออกจากจุดได้ (0 = ล็อกขา)", Minimum = 0, Maximum = 70, Default = stayRadius(),
	Precision = 0, DisplayMethod = "Round", Suffix = " studs",
	Callback = function(v) e.phStayRadius = math.floor(v + 0.5); sv() end}, "PHStayRadius")
FL:Label({Text = "สายยิงไกล (ธนู): 0 = ยืนนิ่ง ยิงทุกตัวที่ถึงจากจุด\nสายตีใกล้: ~20-30 = เดินออกไปตีมอนในวงนี้ แล้วกลับมาที่จุดเอง\n(ยังไม่เคยปรับ = ตั้งให้ตามอาชีพ: ยิงไกล 0 / ตีใกล้ 25)"})
local stayLbl
local function stayText()
	local fp = e.phFarmPos
	if type(fp) ~= "table" or not fp.x then return "จุดยืน: ยังไม่ได้ตั้ง (กดปุ่มด้านบนตอนยืนตรงจุดที่ต้องการ)" end
	return ("จุดยืน: %.0f, %.0f, %.0f"):format(fp.x, fp.y, fp.z)
end
FL:Button({Name = "ตั้งจุดยืนฟาร์ม = ตำแหน่งตอนนี้",
	Callback = function()
		local _, _, hrp = myChar()
		if not hrp then return end
		local p = hrp.Position
		e.phFarmPos = {x = p.X, y = p.Y, z = p.Z}; sv()
		pcall(function() stayLbl:UpdateName(stayText()) end)
	end})
stayLbl = FL:Label({Text = stayText()})
FL:Label({Text = "เลือกช่วงเลเวลมอนที่จะฟาร์ม (นับจากเลเวลเรา):"})
local farmRangeLbl
local function farmRangeText()
	local myLv = tonumber(plr:GetAttribute("Level")) or 0
	local below = tonumber(e.phFarmBelow) or 0
	local above = tonumber(e.phFarmAbove) or 0
	local tgt = myLv - below + above
	return ("➜ เล็งมอน ~Lv %d (เลเวลคุณ %d, ต่ำ -%d/สูง +%d)"):format(math.max(tgt, 0), myLv, below, above)
end
FL:Slider({Name = "ต่ำกว่าเราได้ (เลเวล)", Minimum = 0, Maximum = 99, Default = e.phFarmBelow,
	Precision = 0, DisplayMethod = "Round", Suffix = " lv",
	Callback = function(v) e.phFarmBelow = math.floor(v + 0.5); sv()
		if farmRangeLbl then pcall(function() farmRangeLbl:UpdateName(farmRangeText()) end) end
	end}, "PHFarmBelow")
FL:Slider({Name = "สูงกว่าเราได้ (เลเวล)", Minimum = 0, Maximum = 30, Default = e.phFarmAbove,
	Precision = 0, DisplayMethod = "Round", Suffix = " lv",
	Callback = function(v) e.phFarmAbove = math.floor(v + 0.5); sv()
		if farmRangeLbl then pcall(function() farmRangeLbl:UpdateName(farmRangeText()) end) end
	end}, "PHFarmAbove")
farmRangeLbl = FL:Label({Text = farmRangeText()})
FL:Label({Text = "เช่น อยากตีมอนต่ำกว่าเราไม่เกิน 2 → 'ต่ำกว่า'=2, 'สูงกว่า'=0"})

FL:Header({Text = "Auto Open Chest"})
FL:Toggle({Name = "เปิด Auto Open Chest (เปิดกล่องปาร์ตี้ทันที)", Default = e.phChest,
	Callback = function(v) e.phChest = v; sv() end}, "PHChest")
FL:Toggle({Name = "└ เดินไปเปิดกล่องที่อยู่ใกล้ (ไม่เกิน 150 studs)", Default = e.phChestWalk,
	Callback = function(v) e.phChestWalk = v; sv() end}, "PHChestWalk")
FL:Label({Text = "เปิดกล่องปาร์ตี้ทันทีเมื่ออยู่ในระยะ (เซิร์ฟเวอร์ตรวจระยะ ~10 studs\nเปิดจากไกลไม่ได้) · ถ้ามีกล่องในฟิลด์เดียวกันจะเดินไปเปิดแล้วกลับมาทำต่อ\n(ไม่ไปตอนตีบอส)"})

local FR = Tabs.Farm:Section({Side = "Right"})
FR:Header({Text = "สถานะ"})
local farmLbl = FR:Label({Text = "-"})
local chestLbl = FR:Label({Text = "-"})

-- Boss tab: field bosses
local BL = Tabs.Boss:Section({Side = "Left"})
BL:Header({Text = "Auto Field Boss"})
BL:Toggle({Name = "เปิด Auto Field Boss (ไปตีบอสฟิลด์ที่เลือก)", Default = e.phBossOn,
	Callback = function(v) e.phBossOn = v; sv() end}, "PHBossOn")
BL:Toggle({Name = "รอเวลถึงเลเวลบอสก่อนค่อยไปตี (ระหว่างนั้นฟาร์มมอน)", Default = e.phBossWaitLv,
	Callback = function(v) e.phBossWaitLv = v; sv() end}, "PHBossWaitLv")
local bossOpts, bossDefault = {}, {}
for _, b in ipairs(FIELD_BOSSES) do table.insert(bossOpts, b.label) end
if type(e.phBossPick) == "table" then for lbl, on in pairs(e.phBossPick) do if on then table.insert(bossDefault, lbl) end end end
BL:Dropdown({Name = "บอสฟิลด์ที่จะตี", Multi = true, Required = false,
	Options = bossOpts, Default = bossDefault,
	Callback = function(v)
		local sel = {}
		if type(v) == "table" then
			for k, on in pairs(v) do if on == true then sel[k] = true elseif type(k) == "number" then sel[on] = true end end
		end
		e.phBossPick = sel; sv()
	end}, "PHBossPick")
local farmPosLbl
local function farmPosText()
	local fp = e.phFarmPos
	if type(fp) ~= "table" or not fp.x then return "จุดฟาร์ม: ยังไม่ได้ตั้ง" end
	return ("จุดฟาร์ม: %.0f, %.0f, %.0f"):format(fp.x, fp.y, fp.z)
end
BL:Button({Name = "ตั้งจุดฟาร์ม (ตำแหน่งตอนนี้)",
	Callback = function()
		local _, _, hrp = myChar()
		if not hrp then return end
		local p = hrp.Position
		e.phFarmPos = {x = p.X, y = p.Y, z = p.Z}; sv()
		pcall(function() farmPosLbl:UpdateName(farmPosText()) end)
	end})
farmPosLbl = BL:Label({Text = farmPosText()})
BL:Label({Text = "บอสที่เลือกจะไปตีเสมอ (ผ่านแล้วก็ตี) พอตายกลับจุดฟาร์ม\nระหว่างรอบอสเกิด ฟาร์มเฉพาะรอบจุดฟาร์ม (รัศมี 70)"})

BL:Toggle({Name = "หลบสกิลบอสอัตโนมัติ (เดินออกวงแดง + กดหลบ)", Default = e.phDodge,
	Callback = function(v) e.phDodge = v; sv() end}, "PHDodge")

BL:Header({Text = "Auto World Boss"})
BL:Toggle({Name = "เปิด Auto World Boss (บอสโลก ทุก ~30 นาที)", Default = e.phWBOn,
	Callback = function(v) e.phWBOn = v; sv() end}, "PHWBOn")
local wbOpts, wbDefault = {}, {}
for _, b in ipairs(WORLD_BOSSES) do table.insert(wbOpts, b.label) end
if type(e.phWBPick) == "table" then for lbl, on in pairs(e.phWBPick) do if on then table.insert(wbDefault, lbl) end end end
BL:Dropdown({Name = "เลือกตามชื่อบอสโลก (ว่าง=ทุกตัว)", Multi = true, Required = false,
	Options = wbOpts, Default = wbDefault,
	Callback = function(v)
		local sel = {}
		if type(v) == "table" then
			for k, on in pairs(v) do if on == true then sel[k] = true elseif type(k) == "number" then sel[on] = true end end
		end
		e.phWBPick = sel; sv()
	end}, "PHWBPick")
-- World bosses land in any field (seen: Toy Town, Gem Burrow, ...; ReplicatedStorage
-- WorldBossField says which) -- so every field is offered.
local fieldOpts, fieldDefault = {}, {}
for _, f in ipairs(FIELDS) do table.insert(fieldOpts, f.label) end
if type(e.phWBFields) == "table" then for lbl, on in pairs(e.phWBFields) do if on then table.insert(fieldDefault, lbl) end end end
BL:Dropdown({Name = "เลือกตามแมพที่บอสโลกเกิด (ว่าง=ทุกจุด)", Multi = true, Required = false,
	Options = fieldOpts, Default = fieldDefault,
	Callback = function(v)
		local sel = {}
		if type(v) == "table" then
			for k, on in pairs(v) do if on == true then sel[k] = true elseif type(k) == "number" then sel[on] = true end end
		end
		e.phWBFields = sel; sv()
	end}, "PHWBFields")
BL:Label({Text = "เกมประกาศก่อนลง 2 นาที → วาร์ปไปฟิลด์นั้น ยืนรอจุดลงจอด\nลงแล้ว → ตีจนตาย (ยืนชิด ตีลูกน้องตอนกางโล่ หลบสกิล) → เก็บของ → กลับไปทำต่อ\nบอสโลกมาก่อนบอสฟิลด์เสมอ · กรองตามชื่อ/แมพได้ (ว่าง = ทุกตัว ทุกแมพ)"})

local BR = Tabs.Boss:Section({Side = "Right"})
BR:Header({Text = "สถานะบอสฟิลด์"})
local bossLbl = BR:Label({Text = "-"})

-- Dungeon tab
local DLs = Tabs.Dungeon:Section({Side = "Left"})
DLs:Header({Text = "Auto Dungeon"})
DLs:Toggle({Name = "เปิด Auto Dungeon (ตีในดันเจี้ยนเอง: ห้อง → บอส → เปิดหีบ)", Default = e.phDgOn,
	Callback = function(v) e.phDgOn = v; sv() end}, "PHDgOn")
DLs:Toggle({Name = "Auto Replay (กดปุ่ม REPLAY หน้าจบดันให้เอง)", Default = e.phDgReplay,
	Callback = function(v) e.phDgReplay = v; sv() end}, "PHDgReplay")
DLs:Toggle({Name = "Auto Join ปาร์ตี้ (ลูกปาร์ตี้: กด Join ให้เองตอนหัวหน้าเรียก)", Default = e.phDgAccept,
	Callback = function(v) e.phDgAccept = v; sv() end}, "PHDgAccept")
local dgOpts, dgByLabel, dgDefault = {}, {}, nil
for _, d in ipairs(DG and DG.list or {}) do
	if not d.soon then
		for _, df in ipairs(d.difficulties or {}) do
			local lbl = ("%s · %s (Lv.%d+)"):format(d.name or d.id, df.name or df.id, tonumber(df.level) or 0)
			table.insert(dgOpts, lbl)
			dgByLabel[lbl] = d.id .. ":" .. df.id
			if dgByLabel[lbl] == e.phDgPick then dgDefault = lbl end
		end
	end
end
DLs:Dropdown({Name = "ดันเจี้ยน / ความยากที่จะเข้า (Replay)", Multi = false, Required = true,
	Options = dgOpts, Default = dgDefault or dgOpts[1],
	Callback = function(v)
		if type(v) == "table" then v = v[1] or next(v) end
		if dgByLabel[v] then e.phDgPick = dgByLabel[v]; sv() end
	end}, "PHDgPick")
DLs:Toggle({Name = "Auto Start Dungeon (อยู่เมือง → เข้าดัน+ตีเอง · หลุด/โดนเตะ → เข้าเกมใหม่แล้วไปต่อ)", Default = e.phAutoRejoin,
	Callback = function(v) e.phAutoRejoin = v; sv() end}, "PHAutoRejoin")
DLs:Toggle({Name = "ใช้กุญแจเมื่อรอบฟรีวันนี้หมด", Default = e.phDgUseKeys,
	Callback = function(v) e.phDgUseKeys = v; sv() end}, "PHDgUseKeys")
DLs:Slider({Name = "└ เก็บกุญแจไว้อย่างน้อย (ถึงแล้วหยุดเข้า)", Minimum = 0, Maximum = 100, Default = tonumber(e.phDgKeepKeys) or 0,
	Precision = 0, DisplayMethod = "Round", Suffix = " ดอก",
	Callback = function(v) e.phDgKeepKeys = math.floor(v + 0.5); sv() end}, "PHDgKeepKeys")
DLs:Toggle({Name = "ซื้อกุญแจเองเมื่อหมด (ดอกละ 250k ทอง · ต้องเปิด 'ใช้กุญแจ' ด้วย)", Default = e.phDgBuyKeys,
	Callback = function(v) e.phDgBuyKeys = v; sv() end}, "PHDgBuyKeys")
DLs:Slider({Name = "└ เก็บทองไว้อย่างน้อย (ล้าน) ต่ำกว่านี้ไม่ซื้อ", Minimum = 0, Maximum = 200, Default = tonumber(e.phDgGoldFloor) or 5,
	Precision = 0, DisplayMethod = "Round", Suffix = "M",
	Callback = function(v) e.phDgGoldFloor = math.floor(v + 0.5); sv() end}, "PHDgGoldFloor")
DLs:Label({Text = "จบดัน → กด REPLAY ให้เองทันที (โหวต: ทุกคนในปาร์ตี้ต้องกด ครบแล้วเริ่มรอบใหม่เลย)\nถ้าโหวตไม่ครบจนกลับเมือง: เดี่ยว/หัวหน้า → กดเข้าใหม่ให้ · ลูกปาร์ตี้ → รอหัวหน้าเรียก\nใช้รอบฟรีก่อน แล้วค่อยใช้กุญแจ · ไม่ซื้อกุญแจให้เด็ดขาด\nในดันเจี้ยน: ตีมอนห้องปัจจุบัน → เดินห้องถัดไป → บอส (หลบสกิล) → เปิดหีบ"})
local DRs = Tabs.Dungeon:Section({Side = "Right"})
DRs:Header({Text = "สถานะดันเจี้ยน"})
local dgLbl = DRs:Label({Text = "-"})
task.spawn(function()
	local lastState = 0
	while alive() do
		pcall(function()
			-- keys / free runs refresh every 20s while in town (cheap server read)
			if not plr:GetAttribute("DungeonRun") and os.clock() - lastState > 20 then
				lastState = os.clock()
				local st = dgCall("state")
				if st.ok then
					local id = dgPick()
					dgStats.keys = tonumber(st.keys) or dgStats.keys
					dgStats.free = type(st.free) == "table" and tonumber(st.free[id]) or dgStats.free
				end
			end
			local lines = {}
			local run = plr:GetAttribute("DungeonRun")
			if run then
				local left = math.max(0, math.floor((tonumber(plr:GetAttribute("DungeonEnds")) or 0) - workspace:GetServerTimeNow()))
				table.insert(lines, ("ในรอบ: %s (%s)"):format(DG and DG.byId[run] and DG.byId[run].name or run, tostring(plr:GetAttribute("DungeonDiff"))))
				table.insert(lines, ("ด่าน %s/%s · เวฟ %s/%s · เหลือมอน %s"):format(tostring(plr:GetAttribute("DungeonStage")), tostring(plr:GetAttribute("DungeonStages")),
					tostring(plr:GetAttribute("DungeonWave")), tostring(plr:GetAttribute("DungeonWaves")), tostring(plr:GetAttribute("DungeonLeft"))))
				table.insert(lines, ("ชีวิต %s/%s · เวลาเหลือ %d:%02d%s"):format(tostring(plr:GetAttribute("DungeonLives")), tostring(plr:GetAttribute("DungeonLivesMax")),
					left // 60, left % 60, plr:GetAttribute("DungeonChest") and " · หีบบอสรอเปิด" or ""))
			else
				table.insert(lines, "ไม่ได้อยู่ในดันเจี้ยน")
			end
			table.insert(lines, ("Replay: %s"):format(dgStats.status))
			table.insert(lines, ("กุญแจ %s ดอก · รอบฟรีวันนี้ %s"):format(tostring(dgStats.keys or "?"), tostring(dgStats.free or "?")))
			table.insert(lines, ("จบไปแล้ว %d รอบ (ชนะ %d)%s"):format(dgStats.runs, dgStats.wins,
				dgStats.lastSec and (" · รอบล่าสุด %d:%02d"):format(dgStats.lastSec // 60, dgStats.lastSec % 60) or ""))
			table.insert(lines, "ฟาร์ม: " .. tostring(stats.farm))
			dgLbl:UpdateName(table.concat(lines, "\n"))
		end)
		task.wait(1)
	end
end)

-- Sell tab
local SLs = Tabs.Sell:Section({Side = "Left"})
SLs:Header({Text = "Auto Sell"})
SLs:Toggle({Name = "เปิด Auto Sell", Default = e.phSellOn,
	Callback = function(v) e.phSellOn = v; sv() end}, "PHSellOn")
local tierOpts = {}
for _, t in ipairs(TIER_ORDER) do table.insert(tierOpts, TIER_LABELS[t]) end
local tierDefault = {}
for lbl, on in pairs(e.phSellTiers) do if on then table.insert(tierDefault, lbl) end end
local lvDropdowns = {}   -- tierKey (string) -> level dropdown, shown only while its rarity is picked
local function refreshLvVisibility()
	for _, t in ipairs(TIER_ORDER) do
		local dd = lvDropdowns[tostring(t)]
		if dd then pcall(function() dd:SetVisibility(e.phSellTiers[TIER_LABELS[t]] == true) end) end
	end
end
local function readMulti(v)
	local sel = {}
	if type(v) == "table" then
		for k, on in pairs(v) do if on == true then sel[k] = true elseif type(k) == "number" then sel[on] = true end end
	end
	return sel
end
SLs:Dropdown({Name = "Tier ที่จะขาย", Multi = true, Required = false,
	Options = tierOpts, Default = tierDefault,
	Callback = function(v)
		e.phSellTiers = readMulti(v); sv()
		refreshLvVisibility()
	end}, "PHSellTiers")
-- one level picker per rarity: the levels that rarity's gear actually comes in
-- (from the game's Equipment defs). Nothing picked = sell that rarity at every level.
do
	local okE, Eq = pcall(require, RS.Shared.Config.Equipment)
	for _, t in ipairs(TIER_ORDER) do
		local key = tostring(t)
		local levels, seenLv = {}, {}
		if okE and type(Eq.defs) == "table" then
			for _, def in pairs(Eq.defs) do
				if (tonumber(def.sellPrice) or 0) > 0 and tierOf(def) == t and def.level and not seenLv[def.level] then
					seenLv[def.level] = true
					table.insert(levels, tonumber(def.level))
				end
			end
		end
		table.sort(levels)
		local opts, byLabel, def = {}, {}, {}
		for _, lv in ipairs(levels) do
			local lbl = "Lv " .. lv
			table.insert(opts, lbl); byLabel[lbl] = tostring(lv)
			if type(e.phSellLv[key]) == "table" and e.phSellLv[key][tostring(lv)] then table.insert(def, lbl) end
		end
		if #opts > 0 then
			lvDropdowns[key] = SLs:Dropdown({Name = ("└ เลเวล %s ที่จะขาย (ไม่เลือก = ขายทุกเลเวล)"):format(TIER_LABELS[t]),
				Multi = true, Required = false, Search = true, Options = opts, Default = def,
				Callback = function(v)
					local picked = {}
					for lbl in pairs(readMulti(v)) do if byLabel[lbl] then picked[byLabel[lbl]] = true end end
					e.phSellLv[key] = picked; sv()
				end}, "PHSellLv_" .. key)
		end
	end
	refreshLvVisibility()
end
SLs:Label({Text = "ไม่ขายเด็ดขาด: Tier V, ของดันเจี้ยน (DG), ของที่ lock, ที่ใส่อยู่, ของราคา 0\n(ใช้คำสั่งขายปกติของเกม ไม่ต้องมี Auto Sell Pass)"})
SLs:Header({Text = "ขยะจากมอน (วัตถุดิบ)"})
SLs:Toggle({Name = "ขายวัตถุดิบอัตโนมัติ (ปุ่ม SELL LOOT ของเกม)", Default = e.phSellMats,
	Callback = function(v) e.phSellMats = v; sv() end}, "PHSellMats")
local matsLbl = SLs:Label({Text = "-"})
SLs:Label({Text = "ขายเฉพาะไอเทมประเภทวัตถุดิบ (ดรอปจากมอน) ไม่แตะยา/หินตีบวก/อุปกรณ์\nวัตถุดิบในเกมนี้ไม่มีสูตรคราฟต์ใช้ มีไว้ขายอย่างเดียว"})
task.spawn(function()
	while alive() do
		pcall(function()
			local n, gold = matScan()
			matsLbl:UpdateName(("ในกระเป๋า: %d ชิ้น (~%s ทอง)\nสถานะ: %s"):format(n,
				gold >= 1e6 and ("%.2fM"):format(gold / 1e6) or tostring(gold), tostring(stats.mats)))
		end)
		task.wait(1)
	end
end)
local SRs = Tabs.Sell:Section({Side = "Right"})
SRs:Header({Text = "สถานะ"})
local sellLbl = SRs:Label({Text = "-"})

-- Gear tab: collect + equip
local GLs = Tabs.Gear:Section({Side = "Left"})
GLs:Header({Text = "Auto Collect"})
GLs:Toggle({Name = "เปิด Auto Collect (เก็บของอัตโนมัติ)", Default = e.phCollect,
	Callback = function(v) e.phCollect = v; sv() end}, "PHCollect")
GLs:Label({Text = "บังคับเปิด auto pickup ของเกม (เก็บทุกชนิด: gold,\nโพชั่น, วัตถุดิบ, ของ, การ์ด) เปิดกลับถ้ามันถูกปิด"})
GLs:Header({Text = "Auto Equip Best"})
GLs:Toggle({Name = "เปิด Auto Equip Best (สวมของดีสุด)", Default = e.phEquip,
	Callback = function(v) e.phEquip = v; sv() end}, "PHEquip")
GLs:Label({Text = "สวมของแรงสุดที่คลาสใส่ได้ ทุกช่อง\n(เรียงตาม เลเวล > ขั้น > ตีบวก)"})
local GRs = Tabs.Gear:Section({Side = "Right"})
GRs:Header({Text = "สถานะ"})
local collectLbl = GRs:Label({Text = "-"})
local equipLbl = GRs:Label({Text = "-"})

-- Settings tab
local STs = Tabs.Settings:Section({Side = "Left"})
STs:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() W:SetState(not W:GetState()) end) end}, "PHToggleUIKeybind")
STs:Label({Text = "กด RightShift เพื่อซ่อน/แสดงหน้าต่าง\nตั้งค่าเซฟที่: " .. SF})
STs:Header({Text = "General"})
STs:Toggle({Name = "Auto Reconnect (เน็ตหลุด/เซิร์ฟมีปัญหา → เข้าใหม่)", Default = e.phReconnect,
	Callback = function(v) e.phReconnect = v; sv() end}, "PHReconnect")
STs:Toggle({Name = "Auto Warp (วาร์ปไปฟิลด์ที่ถูก / ตายแล้ววาร์ปกลับจากเมือง)", Default = e.phAutoWarp,
	Callback = function(v) e.phAutoWarp = v; sv() end}, "PHAutoWarp")
STs:Toggle({Name = "เดินด้วย NavMap (แผนที่สแกนเอง ไม่ติดทางลาด/ขั้นพื้น)", Default = e.phNav,
	Callback = function(v) e.phNav = v; sv() end}, "PHNav")
STs:Toggle({Name = "Auto Ride (ขี่สัตว์ตอนเดินไกล / ลงเองตอนเข้าระยะตี)", Default = e.phRide,
	Callback = function(v) e.phRide = v; sv() end}, "PHRide")
STs:Label({Text = "กำลังจะมา: Auto World Boss (บอสโลกทุก 30 นาที)"})

task.spawn(function()
	while alive() do
		pcall(function()
			-- session farm stats: kills of monsters we were fighting, kill rate, gold/hour
			local mins = math.max((os.clock() - (stats.sessionAt or os.clock())) / 60, 1 / 60)
			local gold = tonumber(plr:GetAttribute("Gold")) or 0
			stats.goldStart = stats.goldStart or gold
			local gph = (gold - stats.goldStart) / mins * 60
			farmLbl:UpdateName(("ฟาร์ม: %s\nฆ่าแล้ว %d ตัว (%.1f/นาที) | ทอง %s/ชม."):format(stats.farm, stats.kills or 0,
				(stats.kills or 0) / mins, gph >= 1e6 and ("%.1fM"):format(gph / 1e6) or ("%.0fk"):format(gph / 1e3)))
		end)
		pcall(function() chestLbl:UpdateName("กล่อง: " .. stats.chest) end)
		pcall(function() if farmRangeLbl then farmRangeLbl:UpdateName(farmRangeText()) end end)
		pcall(function()
			-- index live boss monsters by id (field + world)
			local live = {}
			for _, m in ipairs(workspace.Monsters:GetChildren()) do
				if (m:GetAttribute("IsBoss") or m:GetAttribute("WorldBoss")) and (tonumber(m:GetAttribute("Health")) or 0) > 0 then
					live[m:GetAttribute("MonsterId")] = m
				end
			end
			-- track deaths to estimate field-boss respawn (no server timer is exposed)
			local now = os.time()
			for _, b in ipairs(FIELD_BOSSES) do
				local isUp = live[b.bossId] ~= nil
				if bossWasUp[b.bossId] and not isUp then bossDeadAt[b.bossId] = now end
				bossWasUp[b.bossId] = isUp
			end
			-- field boss lines
			-- realtime: the server publishes each boss's respawn moment as
			-- workspace.Monsters attribute BossBack_<bossId> (server time) -- the same
			-- value behind the game's "BACK IN m:ss" pill over each arena
			local lines = {"= บอสฟิลด์ ="}
			local srvNow = workspace:GetServerTimeNow()
			for _, b in ipairs(FIELD_BOSSES) do
				local m = live[b.bossId]
				local st
				if m then
					st = ("🟢 เกิดแล้ว (เลือด %d%%)"):format(math.floor((tonumber(m:GetAttribute("Health")) or 0) / math.max(tonumber(m:GetAttribute("MaxHealth")) or 1, 1) * 100))
				else
					local back = tonumber(workspace.Monsters:GetAttribute("BossBack_" .. b.bossId))
					local left = back and math.ceil(back - srvNow)
					if left and left > 0 then
						st = ("⏳ เกิดใน %d:%02d"):format(left // 60, left % 60)
					else
						st = "⏳ กำลังเกิด"
					end
				end
				local mark = (type(e.phBossPick) == "table" and e.phBossPick[b.label]) and "✔ " or "· "
				lines[#lines + 1] = ("%s%s Lv%d: %s"):format(mark, b.name, b.lv, st)
			end
			-- world boss lines
			lines[#lines + 1] = "= บอสโลก ="
			local wbUp = {}
			for _, m in ipairs(workspace.Monsters:GetChildren()) do
				if m:GetAttribute("WorldBoss") and (tonumber(m:GetAttribute("Health")) or 0) > 0 then
					local center = m:GetAttribute("ArenaCenter")
					local f = fieldAt((typeof(center) == "Vector3") and center or m.PrimaryPart and m.PrimaryPart.Position)
					wbUp[#wbUp + 1] = ("%s Lv%s (%s)"):format(m.Name, tostring(m:GetAttribute("Level") or "?"), f and (FIELD_NAME[f.id] or f.id) or "?")
				end
			end
			-- realtime from the server's ReplicatedStorage attributes (what the game's
			-- own "WORLD BOSS INCOMING m:ss" banner reads): WorldBoss = "soon" while
			-- announced, WorldBossAt = landing time, WorldBossEnds = despawn time.
			local RSa = game:GetService("ReplicatedStorage")
			local wbState = RSa:GetAttribute("WorldBoss")
			local wbId = RSa:GetAttribute("WorldBossId")
			local wbField = RSa:GetAttribute("WorldBossField")
			local wbName = (wbId and (WB_LABEL[wbId] or WB_LABEL["wb_" .. tostring(wbId)])) or tostring(wbId or "?")
			local wbWhere = wbField and (FIELD_NAME[wbField] or wbField) or "?"
			local wbAt = tonumber(RSa:GetAttribute("WorldBossAt"))
			if wbAt then getgenv().__PHP_WBLAST = wbAt end   -- remember for the next-round estimate
			if #wbUp > 0 then
				local ends = tonumber(RSa:GetAttribute("WorldBossEnds"))
				local left = ends and math.max(0, math.ceil(ends - srvNow))
				lines[#lines + 1] = "🟢 เกิดแล้ว: " .. table.concat(wbUp, ", ")
					.. (left and ("  (หายใน %d:%02d)"):format(left // 60, left % 60) or "")
			elseif wbState == "soon" and wbAt then
				local left = math.max(0, math.ceil(wbAt - srvNow))
				lines[#lines + 1] = ("⏳ %s เกิดใน %d:%02d ที่ %s"):format(wbName, left // 60, left % 60, wbWhere)
			elseif getgenv().__PHP_WBLAST then
				local nxt = getgenv().__PHP_WBLAST + 1800
				while nxt < srvNow do nxt += 1800 end
				local left = math.ceil(nxt - srvNow)
				lines[#lines + 1] = ("⏳ รอบหน้า ~%d:%02d (ประกาศก่อนเกิด 2 นาที)"):format(left // 60, left % 60)
			else
				lines[#lines + 1] = "⏳ ยังไม่ประกาศ (เกิดทุก 30 นาที ประกาศก่อน 2 นาที)"
			end
			bossLbl:UpdateName(table.concat(lines, "\n"))
		end)
		pcall(function()
			local pending, gold = sellScan()
			sellLbl:UpdateName(("%s\nขายไปแล้ว: %d ชิ้น\nตอนนี้เข้าเงื่อนไข: %d ชิ้น (~%d Gold)")
				:format(stats.sell, stats.sold, #pending, gold))
		end)
		pcall(function() collectLbl:UpdateName("เก็บของ: " .. stats.collect) end)
		pcall(function() equipLbl:UpdateName(("สวมของ: %s\nสวมไปแล้วรวม %d ชิ้น"):format(stats.equip, stats.equipped)) end)
		task.wait(0.5)
	end
end)

W.onUnloaded(function()
	if getgenv().__PHP == G then getgenv().__PHP = G + 1 end
	-- give the player's own autoRange back if stay-put mode had clamped it
	if getgenv().__PHP_OLDRANGE and GSettings then
		pcall(function() GSettings.set("autoRange", getgenv().__PHP_OLDRANGE) end)
		getgenv().__PHP_OLDRANGE = nil
	end
	getgenv().__PHP_SETRANGE = nil
	print("[PetHunt] Unloaded")
end)
Tabs.Farm:Select()
print("[PetHunt] UI ready")
