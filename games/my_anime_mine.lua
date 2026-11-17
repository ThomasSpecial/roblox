-- My Anime Mine (placeId 79389059854988) -- Auto Collect / Auto Sell / Auto Research / Auto Unlock Zone
-- MacLib window, RightShift toggles it, settings persist (AnimeMine/state.json).
--
-- Everything goes through the game's own GameState.SendEvent (Remotes.GamestateEvent):
--   MineTakeChest()                     -> plot chest -> bag (the chest's "Take all"); works from anywhere
--   MineSellItems({oreName, ...})       -> sells those ores; the server only accepts it near the
--                                          SellStand (SellPrompt, 14 studs) -> teleport there and back
--   MineBuySkill(zone, family, nodeId)  -> one research pip; works from anywhere
--   MineSelectZone("Z<n>")              -> enters / unlocks a zone (needs the previous zone's research
--                                          complete + Money >= Zones[Z].UnlockCost)
-- Player data: GameState.GetData2() -> .Money, .MineGame.{Ores, Chest, Skills, UnlockedZones, CurrentZone}

getgenv().__AMINE = (getgenv().__AMINE or 0) + 1
local G = getgenv().__AMINE
pcall(function() if getgenv().__AMINEW then getgenv().__AMINEW:Unload() end end)
local function alive() return getgenv().__AMINE == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local plr = Players.LocalPlayer

local GS = require(RS.Modules.GameState)
local MC = require(RS.Modules.MineConfig)
local Inv = require(RS.Modules.MineInventory)

-- ------------------------------------------------------------------ settings
local SF = ("AnimeMine/state_%d.json"):format(plr.UserId)
local DEFAULTS = {collect = true, collectEvery = 1, sell = true, sellEvery = 1, research = true,
	researchAll = false, unlock = true, park = true}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
-- user: "auto sell ไม่เห็นจะ instant" -> sell right after every collect (old defaults 2s / 10s)
if not e.instantMigrated then e.collectEvery = 1; e.sellEvery = 1; e.instantMigrated = true end
local function sv()
	pcall(function()
		if makefolder and not isfolder("AnimeMine") then makefolder("AnimeMine") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

local st = {collect = "-", sell = "-", research = "-", unlock = "-", sold = 0, bought = 0}

local function data()
	local d = GS.GetData2()
	return d, d and d.MineGame
end
local function money() local d = data(); return tonumber(d and d.Money) or 0 end
local function fmt(n)
	local ok, s = pcall(function() return require(RS.Modules.String):ToMoney(n) end)
	return ok and s or ("$" .. tostring(math.floor(n)))
end
local function zoneIndex(z) return table.find(MC.ZoneKeys, z) end
local function deepestUnlocked(m)
	local best, bi = "Z1", 1
	for z, on in pairs(m.UnlockedZones or {}) do
		local i = zoneIndex(z)
		if on and i and i > bi then best, bi = z, i end
	end
	return best, bi
end

-- ------------------------------------------------------------------ collect
local function collectTick()
	local _, m = data()
	if not m then return end
	if type(m.Chest) == "table" and next(m.Chest) ~= nil then
		GS.SendEvent("MineTakeChest")
		st.collect = "เก็บของจาก chest แล้ว " .. os.date("%H:%M:%S")
	else
		st.collect = "chest ว่าง"
	end
end

-- ------------------------------------------------------------------ sell
local function sellSpot()
	local sp = workspace:FindFirstChild("SellStand")
	for _, d in ipairs((sp or workspace):GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "SellPrompt" then
			local p = d.Parent
			if p:IsA("Attachment") then return p.WorldPosition end
			if p:IsA("BasePart") then return p.Position end
		end
	end
end
local function sellTick()
	local _, m = data()
	if not m then return end
	local keys = {}
	for _, it in ipairs(Inv.Collect(m, "All", Inv.KindOrder.OreFirst)) do
		if it.Kind == "Ore" and (tonumber(it.Count) or 0) > 0 then keys[#keys + 1] = it.Key end
	end
	if #keys == 0 then st.sell = "ไม่มีแร่ในกระเป๋า"; return end
	local pos = sellSpot()
	local ch = plr.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	if not (pos and hrp) then st.sell = "หาร้านขายไม่เจอ"; return end
	-- user: "ทำแบบ instant ดิ" -> park at the stand: the crew mines the plot without us
	-- (tested: same income while standing at the stand), so every sell goes out the moment
	-- ore lands in the bag -- no hop, no replication wait (8/8 sells in 8s, none missed)
	if e.park then
		local spot = pos + Vector3.new(0, 0, 7)
		if (hrp.Position - spot).Magnitude > 9 then
			hrp.CFrame = CFrame.new(spot, pos)
			task.wait(0.15)
		end
		local m0 = money()
		GS.SendEvent("MineSellItems", keys)
		task.wait(0.15)
		local got = money() - m0
		if got > 0 then st.sold += got end
		st.sell = ("ขาย %d ชนิด +%s · %s"):format(#keys, fmt(math.max(0, got)), os.date("%H:%M:%S"))
		return
	end
	-- tested: the server needs our new position replicated first -- 1 frame is too soon,
	-- 0.1s is enough. Hop there, sell, hop straight back (~0.15s away from the plot);
	-- a miss bumps the wait for the next try.
	local back = hrp.CFrame
	local m0 = money()
	hrp.CFrame = CFrame.new(pos + Vector3.new(0, 0, 7), pos)
	task.wait(st.sellWait or 0.12)
	GS.SendEvent("MineSellItems", keys)
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	if hrp.Parent then hrp.CFrame = back end
	task.wait(0.5)
	local got = money() - m0
	if got > 0 then
		st.sold += got
		st.sellWait = math.max(0.12, (st.sellWait or 0.12) - 0.04)
		st.sell = ("ขาย %d ชนิด +%s · %s"):format(#keys, fmt(got), os.date("%H:%M:%S"))
	else
		st.sellWait = math.min((st.sellWait or 0.12) + 0.08, 0.5)
		st.sell = "ขายไม่ติด ลองใหม่ (รอ " .. st.sellWait .. " วิ)"
	end
end

-- ------------------------------------------------------------------ research
-- cheapest open, not-maxed node; deepest unlocked zone first (its research gates the next zone)
local function researchTick()
	local _, m = data()
	if not m then return false end
	local skills = m.Skills or {}
	local cash = money()
	local zones = {}
	local deep = deepestUnlocked(m)
	zones[1] = deep
	if e.researchAll then
		for z, on in pairs(m.UnlockedZones or {}) do if on and z ~= deep then zones[#zones + 1] = z end end
	end
	local best, bestCost, bestZone
	local left = 0
	for _, z in ipairs(zones) do
		local sk = skills[z] or {}
		for _, n in ipairs(MC.GetSkillNodes(z)) do
			local okO, open = pcall(MC.IsSkillNodeOpen, sk, n)
			local okM, maxed = pcall(MC.IsSkillNodeMaxed, sk, n)
			if okO and open and okM and not maxed then
				left += 1
				local okC, cost = pcall(MC.GetSkillCost, z, sk[n.Family] or 0, n.Family)
				cost = okC and tonumber(cost) or math.huge
				if not bestCost or cost < bestCost then best, bestCost, bestZone = n, cost, z end
			end
		end
	end
	local a, b = MC.GetZoneResearchProgress(skills, deep)
	if not best then st.research = ("%s: %d/%d · ไม่มีอันที่เปิดให้ซื้อ"):format(deep, a, b); return false end
	if bestCost > cash then
		st.research = ("%s: %d/%d · รอเงิน %s (%s)"):format(deep, a, b, fmt(bestCost), best.Name or best.Id)
		return false
	end
	GS.SendEvent("MineBuySkill", bestZone, best.Family, best.Id)
	st.bought += 1
	st.research = ("%s: %d/%d · ซื้อ %s (%s)"):format(deep, a, b, best.Name or best.Id, fmt(bestCost))
	return true
end

-- ------------------------------------------------------------------ unlock zone
local unlockTry = 0
local function unlockTick()
	local _, m = data()
	if not m then return end
	local deep, di = deepestUnlocked(m)
	local nextZ = MC.ZoneKeys[di + 1]
	if not nextZ then st.unlock = "ปลดครบทุกโซนแล้ว"; return end
	local z = MC.Zones[nextZ] or {}
	local cost = tonumber(z.UnlockCost) or 0
	local a, b = MC.GetZoneResearchProgress(m.Skills or {}, deep)
	local name = z.DisplayName or nextZ
	if a < b then st.unlock = ("%s: รอ research %s ให้ครบ (%d/%d)"):format(name, deep, a, b); return end
	if money() < cost then st.unlock = ("%s: รอเงิน %s"):format(name, fmt(cost)); return end
	if os.clock() - unlockTry < 5 then return end
	unlockTry = os.clock()
	GS.SendEvent("MineSelectZone", nextZ)
	st.unlock = ("ปลด %s (%s) แล้ว"):format(name, fmt(cost))
end

-- ------------------------------------------------------------------ loops
task.spawn(function()
	local lastC, lastS, lastR = 0, 0, 0
	while alive() do
		local now = os.clock()
		local fast = e.sell and e.park   -- parked at the stand: collect + sell every 0.2s
		if e.collect and (fast or now - lastC >= (tonumber(e.collectEvery) or 1)) then
			lastC = now
			pcall(collectTick)
			if fast then task.wait(0.15) end
		end
		if e.sell and (fast or now - lastS >= (tonumber(e.sellEvery) or 1)) then
			lastS = now
			pcall(sellTick)
		end
		if now - lastR >= 0.5 then
			lastR = now
			if e.unlock then pcall(unlockTick) end
			if e.research then
				-- several pips in a row while affordable, then breathe
				for _ = 1, 5 do
					local ok, more = pcall(researchTick)
					if not (ok and more) then break end
					task.wait(0.35)
				end
			end
		end
		task.wait(fast and 0.05 or 0.5)
	end
end)

-- ---------------------------------------------------------------------- UI
local okL, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okL or not Lib then warn("[AnimeMine] MacLib failed: " .. tostring(Lib)) return end
if not alive() then return end
local W = Lib:Window({Title = "My Anime Mine", Subtitle = "Auto Farm", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__AMINEW = W
local TG = W:TabGroup()
local Tabs = {
	Main = TG:Tab({Name = "Auto", Image = "rbxassetid://10723346959"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}
local L = Tabs.Main:Section({Side = "Left"})
L:Header({Text = "เก็บ / ขาย"})
L:Toggle({Name = "Auto Collect Instant (เก็บของจาก chest)", Default = e.collect,
	Callback = function(v) e.collect = v; sv() end}, "AMCollect")
L:Slider({Name = "└ เก็บทุก", Minimum = 1, Maximum = 30, Default = tonumber(e.collectEvery) or 1,
	Precision = 0, DisplayMethod = "Round", Suffix = " วิ",
	Callback = function(v) e.collectEvery = math.floor(v + 0.5); sv() end}, "AMCollectEvery")
L:Toggle({Name = "Auto Sell Instant (ขายแร่ทั้งหมด วาร์ปไปร้านแล้วกลับ)", Default = e.sell,
	Callback = function(v) e.sell = v; sv() end}, "AMSell")
L:Slider({Name = "└ ขายทุก", Minimum = 1, Maximum = 120, Default = tonumber(e.sellEvery) or 1,
	Precision = 0, DisplayMethod = "Round", Suffix = " วิ",
	Callback = function(v) e.sellEvery = math.floor(v + 0.5); sv() end}, "AMSellEvery")
L:Toggle({Name = "└ ยืนประจำร้าน (ขายทันทีที่แร่เข้า ไม่ต้องวาร์ปไปกลับ)", Default = e.park,
	Callback = function(v) e.park = v; sv() end}, "AMPark")
L:Label({Text = "ขายเฉพาะแร่ ไม่แตะตัวละคร / pickaxe\nยืนประจำร้าน: ตัวละครยืนที่ร้านขายตลอด ทีมยังขุดที่แปลงเหมือนเดิม\nเก็บ + ขายทุก 0.2 วิ (ปิด = วาร์ปไปขายตามรอบที่ตั้ง)"})
L:Header({Text = "Research / Zone"})
L:Toggle({Name = "Auto Research Tree (ซื้ออันถูกสุดก่อน)", Default = e.research,
	Callback = function(v) e.research = v; sv() end}, "AMResearch")
L:Toggle({Name = "└ ซื้อทุกโซนที่ปลดแล้ว (ปิด = เฉพาะโซนลึกสุด)", Default = e.researchAll,
	Callback = function(v) e.researchAll = v; sv() end}, "AMResearchAll")
L:Toggle({Name = "Auto Unlock Zone (research ครบ + เงินถึง → ปลดโซนถัดไป)", Default = e.unlock,
	Callback = function(v) e.unlock = v; sv() end}, "AMUnlock")

local R = Tabs.Main:Section({Side = "Right"})
R:Header({Text = "สถานะ"})
local stLbl = R:Label({Text = "-"})

local S = Tabs.Settings:Section({Side = "Left"})
S:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() W:SetState(not W:GetState()) end) end}, "AMToggleUI")
S:Label({Text = "ตั้งค่าเซฟที่: " .. SF})

task.spawn(function()
	while alive() do
		pcall(function()
			local _, m = data()
			stLbl:UpdateName(table.concat({
				"เงิน: " .. fmt(money()) .. " · โซนตอนนี้: Z" .. tostring(m and m.CurrentZone or "?"),
				"Collect: " .. st.collect,
				"Sell: " .. st.sell .. " · รวม +" .. fmt(st.sold),
				"Research: " .. st.research .. " · ซื้อไป " .. st.bought .. " ครั้ง",
				"Zone: " .. st.unlock,
			}, "\n"))
		end)
		task.wait(1)
	end
end)

W.onUnloaded(function()
	if getgenv().__AMINE == G then getgenv().__AMINE = G + 1 end
	print("[AnimeMine] Unloaded")
end)
Tabs.Main:Select()
print("[AnimeMine] UI ready")
