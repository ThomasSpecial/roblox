-- Battle Royale (placeId 108448382032231) -- chest ESP with a rarity filter.
-- MacLib window, RightShift toggles it, settings persist (BattleRoyale/state.json).
--
-- From the game's own client (Interface.Components.World.Chests):
--   * a lootable chest = an instance tagged Tags.Chest ("Chest"); opening it removes the
--     tag (CollectionService:RemoveTag + Net packet), so the tag set IS the unopened set.
--   * rarity = the chest's "Rarity" attribute, an index into Shared.Config.Rarities
--     (1 Common .. 6 Mythic); the prompt reads "<Rarity> Chest". Before the server
--     assigns it the attribute is nil -> fall back to the model (EpicChest_* /
--     LegendaryChest_* meshes), else "Normal" (the game's own prompt just says "Chest").
-- Drawn with BoxHandleAdornment + BillboardGui (no 31-Highlight limit) in gethui().

getgenv().__BRESP = (getgenv().__BRESP or 0) + 1
local G = getgenv().__BRESP
pcall(function() if getgenv().__BRESPW then getgenv().__BRESPW:Unload() end end)
pcall(function()
	local plr0 = game:GetService("Players").LocalPlayer
	for _, root in ipairs({(gethui and gethui()) or nil, game:GetService("CoreGui"), plr0 and plr0:FindFirstChildOfClass("PlayerGui")}) do
		if root then
			for _, g in ipairs(root:GetDescendants()) do
				if g:IsA("ScreenGui") and g:FindFirstChild("Base") and g:FindFirstChild("Notifications") then g:Destroy() end
			end
		end
	end
end)
local function alive() return getgenv().__BRESP == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local CS = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local plr = Players.LocalPlayer

local RARITIES = {"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic"}
pcall(function()
	local r = require(RS.Shared.Config.Rarities)
	for i = 1, 6 do if type(r[i]) == "string" then RARITIES[i] = r[i] end end
end)
local CHEST_TAG = "Chest"
pcall(function() CHEST_TAG = require(RS.Shared.Config.Tags).Chest or CHEST_TAG end)
local COLORS = {
	Common = Color3.fromRGB(190, 190, 190), Uncommon = Color3.fromRGB(80, 220, 90), Rare = Color3.fromRGB(60, 150, 255),
	Epic = Color3.fromRGB(190, 80, 255), Legendary = Color3.fromRGB(255, 170, 30), Mythic = Color3.fromRGB(255, 60, 90),
	Normal = Color3.fromRGB(255, 255, 255),
}

-- ------------------------------------------------------------------ settings
local SF = "BattleRoyale/state.json"
local DEFAULTS = {espOn = true, espRarities = nil, espMaxDist = 1500, espBox = true, espText = true}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
if type(e.espRarities) ~= "table" then
	e.espRarities = {Normal = true}
	for _, r in ipairs(RARITIES) do e.espRarities[r] = true end
end
if e.espRarities.Unknown ~= nil then e.espRarities.Normal = e.espRarities.Unknown; e.espRarities.Unknown = nil end
local function sv()
	pcall(function()
		if makefolder and not isfolder("BattleRoyale") then makefolder("BattleRoyale") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

-- ------------------------------------------------------------------ ESP
local holder = Instance.new("Folder")
holder.Name = "BR_ChestESP"
holder.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local function rarityOf(chest)
	local v = chest:GetAttribute("Rarity")
	if typeof(v) == "number" and RARITIES[v] then return RARITIES[v] end
	if type(v) == "string" and COLORS[v] then return v end
	for _, d in ipairs(chest:GetDescendants()) do
		local n = d.Name
		for i = #RARITIES, 1, -1 do
			if n:find(RARITIES[i] .. "Chest", 1, true) then return RARITIES[i] end
		end
	end
	return "Normal"
end

local entries = {}   -- chest -> {box, bb, label, rarity}
local function clear(chest)
	local en = entries[chest]
	if en then
		pcall(function() en.box:Destroy() end)
		pcall(function() en.bb:Destroy() end)
		entries[chest] = nil
	end
end
local function build(chest)
	if entries[chest] or not chest:IsDescendantOf(workspace) then return end
	local ok, cf, size = pcall(function() return chest:GetBoundingBox() end)
	if not ok then
		if chest:IsA("BasePart") then cf, size = chest.CFrame, chest.Size else return end
	end
	local anchor = chest:FindFirstChild("Top", true)
	if not (anchor and anchor:IsA("BasePart")) then anchor = chest:FindFirstChildWhichIsA("BasePart", true) end
	if not anchor then return end
	local box = Instance.new("BoxHandleAdornment")
	box.Name = "Box"
	box.AlwaysOnTop = true
	box.ZIndex = 5
	box.Transparency = 0.55
	box.Size = size + Vector3.new(0.4, 0.4, 0.4)
	box.Adornee = anchor
	box.CFrame = anchor.CFrame:ToObjectSpace(cf)
	box.Parent = holder
	local bb = Instance.new("BillboardGui")
	bb.Name = "Tag"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(160, 34)
	bb.StudsOffsetWorldSpace = Vector3.new(0, size.Y / 2 + 1.5, 0)
	bb.Adornee = anchor
	bb.LightInfluence = 0
	bb.Parent = holder
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = false
	label.TextSize = 13
	label.TextStrokeTransparency = 0.3
	label.Parent = bb
	entries[chest] = {box = box, bb = bb, label = label, anchor = anchor, rarity = rarityOf(chest)}
end

for _, c in ipairs(CS:GetTagged(CHEST_TAG)) do build(c) end
local addConn = CS:GetInstanceAddedSignal(CHEST_TAG):Connect(function(c) task.defer(build, c) end)
local remConn = CS:GetInstanceRemovedSignal(CHEST_TAG):Connect(clear)   -- opened / gone

local counts = {}
task.spawn(function()
	while alive() do
		local cam = workspace.CurrentCamera
		local origin = cam and cam.CFrame.Position or Vector3.zero
		local maxD = tonumber(e.espMaxDist) or 1500
		local c = {}
		for chest, en in pairs(entries) do
			if not chest.Parent or not chest:IsDescendantOf(workspace) or not CS:HasTag(chest, CHEST_TAG) then
				clear(chest)
			else
				en.rarity = rarityOf(chest)   -- the server can assign it after spawn
				local d = (en.anchor.Position - origin).Magnitude
				local show = e.espOn and e.espRarities[en.rarity] == true and d <= maxD
				if show then c[en.rarity] = (c[en.rarity] or 0) + 1 end
				local col = COLORS[en.rarity] or COLORS.Normal
				en.box.Visible = show and e.espBox
				en.box.Color3 = col
				en.bb.Enabled = show and e.espText
				en.label.TextColor3 = col
				en.label.Text = ("%s\n%dm"):format(en.rarity == "Normal" and "Chest" or (en.rarity .. " Chest"), math.floor(d))
			end
		end
		counts = c
		task.wait(0.2)
	end
end)

-- ------------------------------------------------------------------ player ESP
-- Drawing API, updated every RenderStepped (realtime): 2D box fitted to the projected
-- character bounds, R15/R6 skeleton lines, name / distance / health bar. Party members
-- (same "Party" attribute on the Player) count as teammates.
for k, v in pairs({pOn = true, pBox = true, pSkel = true, pName = true, pHealth = true, pTracer = false,
	pTeam = false, pMaxDist = 2000}) do
	if e[k] == nil then e[k] = v end
end
local ENEMY, MATE = Color3.fromRGB(255, 70, 70), Color3.fromRGB(80, 230, 120)
local BONES_R15 = {
	{"Head", "UpperTorso"}, {"UpperTorso", "LowerTorso"},
	{"UpperTorso", "LeftUpperArm"}, {"LeftUpperArm", "LeftLowerArm"}, {"LeftLowerArm", "LeftHand"},
	{"UpperTorso", "RightUpperArm"}, {"RightUpperArm", "RightLowerArm"}, {"RightLowerArm", "RightHand"},
	{"LowerTorso", "LeftUpperLeg"}, {"LeftUpperLeg", "LeftLowerLeg"}, {"LeftLowerLeg", "LeftFoot"},
	{"LowerTorso", "RightUpperLeg"}, {"RightUpperLeg", "RightLowerLeg"}, {"RightLowerLeg", "RightFoot"},
}
local BONES_R6 = {
	{"Head", "Torso"}, {"Torso", "Left Arm"}, {"Torso", "Right Arm"}, {"Torso", "Left Leg"}, {"Torso", "Right Leg"},
}
local function newLine(th) local l = Drawing.new("Line"); l.Thickness = th or 1.5; l.Visible = false; return l end
local pDraw = {}   -- player -> drawings
local function dropPlayer(p)
	local d = pDraw[p]
	if not d then return end
	for _, o in ipairs(d.all) do pcall(function() o:Remove() end) end
	pDraw[p] = nil
end
local function drawFor(p)
	local d = pDraw[p]
	if d then return d end
	d = {all = {}}
	local function add(o) d.all[#d.all + 1] = o; return o end
	d.boxOut = add(Drawing.new("Square")); d.boxOut.Thickness = 3; d.boxOut.Filled = false; d.boxOut.Color = Color3.new(0, 0, 0)
	d.box = add(Drawing.new("Square")); d.box.Thickness = 1.5; d.box.Filled = false
	d.name = add(Drawing.new("Text")); d.name.Size = 14; d.name.Center = true; d.name.Outline = true
	d.dist = add(Drawing.new("Text")); d.dist.Size = 13; d.dist.Center = true; d.dist.Outline = true
	d.hpBack = add(Drawing.new("Square")); d.hpBack.Filled = true; d.hpBack.Color = Color3.new(0, 0, 0)
	d.hp = add(Drawing.new("Square")); d.hp.Filled = true
	d.tracer = add(newLine(1.2))
	d.bones = {}
	for i = 1, #BONES_R15 do d.bones[i] = add(newLine(1.6)) end
	for _, o in ipairs(d.all) do o.Visible = false end
	pDraw[p] = d
	return d
end
local function hideAll(d) for _, o in ipairs(d.all) do o.Visible = false end end
local remPlayer = Players.PlayerRemoving:Connect(dropPlayer)
getgenv().__BRESP_P = pDraw   -- console / debugging

local renderConn = RunService.RenderStepped:Connect(function()
	if not alive() then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	local myParty = plr:GetAttribute("Party")
	local camPos = cam.CFrame.Position
	local vp = cam.ViewportSize
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= plr then
			local d = drawFor(p)
			local ch = p.Character
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			local root = ch and ch:FindFirstChild("HumanoidRootPart")
			local mate = myParty ~= nil and p:GetAttribute("Party") == myParty
			local ok = e.pOn and root and hum and hum.Health > 0 and (e.pTeam or not mate)
			local dist = ok and (root.Position - camPos).Magnitude or 0
			if ok and dist > (tonumber(e.pMaxDist) or 2000) then ok = false end
			if not ok then
				hideAll(d)
			else
				local col = mate and MATE or ENEMY
				-- screen-space bounds from every body part's projected centre +- its size
				local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
				local onScreen = false
				for _, part in ipairs(ch:GetChildren()) do
					if part:IsA("BasePart") and part.Transparency < 1 then
						local cf, sz = part.CFrame, part.Size / 2
						for _, c in ipairs({Vector3.new(sz.X, sz.Y, 0), Vector3.new(-sz.X, -sz.Y, 0), Vector3.new(0, sz.Y, sz.Z), Vector3.new(0, -sz.Y, -sz.Z)}) do
							local s, vis = cam:WorldToViewportPoint(cf:PointToWorldSpace(c))
							if s.Z > 0 then
								onScreen = onScreen or vis
								minX, minY = math.min(minX, s.X), math.min(minY, s.Y)
								maxX, maxY = math.max(maxX, s.X), math.max(maxY, s.Y)
							end
						end
					end
				end
				if not onScreen or minX == math.huge then
					hideAll(d)
				else
					local w, h = maxX - minX, maxY - minY
					d.box.Visible, d.boxOut.Visible = e.pBox, e.pBox
					d.box.Position, d.box.Size, d.box.Color = Vector2.new(minX, minY), Vector2.new(w, h), col
					d.boxOut.Position, d.boxOut.Size = d.box.Position, d.box.Size
					d.name.Visible = e.pName
					d.name.Text = p.DisplayName
					d.name.Color = col
					d.name.Position = Vector2.new(minX + w / 2, minY - 17)
					d.dist.Visible = e.pName
					d.dist.Text = ("%dm"):format(math.floor(dist))
					d.dist.Color = Color3.new(1, 1, 1)
					d.dist.Position = Vector2.new(minX + w / 2, maxY + 2)
					local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
					d.hpBack.Visible, d.hp.Visible = e.pHealth, e.pHealth
					d.hpBack.Position, d.hpBack.Size = Vector2.new(minX - 6, minY - 1), Vector2.new(4, h + 2)
					d.hp.Position, d.hp.Size = Vector2.new(minX - 5, minY + h * (1 - frac)), Vector2.new(2, h * frac)
					d.hp.Color = Color3.fromRGB(255 * (1 - frac), 220 * frac + 35, 60)
					d.tracer.Visible = e.pTracer
					d.tracer.From = Vector2.new(vp.X / 2, vp.Y)
					d.tracer.To = Vector2.new(minX + w / 2, maxY)
					d.tracer.Color = col
					local bones = hum.RigType == Enum.HumanoidRigType.R15 and BONES_R15 or BONES_R6
					for i, line in ipairs(d.bones) do
						local b = bones[i]
						local a0 = b and ch:FindFirstChild(b[1])
						local a1 = b and ch:FindFirstChild(b[2])
						if e.pSkel and a0 and a1 then
							local s0, v0 = cam:WorldToViewportPoint(a0.Position)
							local s1, v1 = cam:WorldToViewportPoint(a1.Position)
							if s0.Z > 0 and s1.Z > 0 then
								line.From, line.To, line.Color, line.Visible = Vector2.new(s0.X, s0.Y), Vector2.new(s1.X, s1.Y), col, true
							else
								line.Visible = false
							end
						else
							line.Visible = false
						end
					end
				end
			end
		end
	end
end)

-- ---------------------------------------------------------------------- UI
local okL, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okL or not Lib then warn("[BR ESP] MacLib failed: " .. tostring(Lib)) return end
if not alive() then return end
local W = Lib:Window({Title = "Battle Royale", Subtitle = "Chest ESP", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__BRESPW = W
local TG = W:TabGroup()
local Tabs = {
	ESP = TG:Tab({Name = "ESP กล่อง", Image = "rbxassetid://10723346959"}),
	PESP = TG:Tab({Name = "ESP คน", Image = "rbxassetid://10734950309"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}
local L = Tabs.ESP:Section({Side = "Left"})
L:Header({Text = "Chest ESP"})
L:Toggle({Name = "เปิด ESP กล่อง", Default = e.espOn,
	Callback = function(v) e.espOn = v; sv() end}, "BREspOn")
local rarOpts = {}
for _, r in ipairs(RARITIES) do rarOpts[#rarOpts + 1] = r end
rarOpts[#rarOpts + 1] = "Normal"
local rarDefault = {}
for _, r in ipairs(rarOpts) do if e.espRarities[r] then rarDefault[#rarDefault + 1] = r end end
L:Dropdown({Name = "Rarity ที่จะแสดง (เลือกได้หลายอย่าง)", Multi = true, Required = false, Options = rarOpts, Default = rarDefault,
	Callback = function(v)
		local sel = {}
		if type(v) == "table" then
			for k, on in pairs(v) do
				if on == true and type(k) == "string" then sel[k] = true
				elseif type(k) == "number" and type(on) == "string" then sel[on] = true end
			end
		end
		e.espRarities = sel; sv()
	end}, "BREspRarities")
L:Toggle({Name = "กรอบกล่อง (มองทะลุกำแพง)", Default = e.espBox,
	Callback = function(v) e.espBox = v; sv() end}, "BREspBox")
L:Toggle({Name = "ป้ายชื่อ + ระยะ", Default = e.espText,
	Callback = function(v) e.espText = v; sv() end}, "BREspText")
L:Slider({Name = "ระยะแสดงสูงสุด", Minimum = 50, Maximum = 3000, Default = tonumber(e.espMaxDist) or 1500,
	Precision = 0, DisplayMethod = "Round", Suffix = " studs",
	Callback = function(v) e.espMaxDist = math.floor(v + 0.5); sv() end}, "BREspMaxDist")
L:Label({Text = "สี: Common เทา · Uncommon เขียว · Rare ฟ้า · Epic ม่วง · Legendary ส้ม · Mythic แดง\nNormal = กล่องธรรมดา (เกมไม่ได้ใส่ rarity ให้ ป้ายในเกมขึ้นแค่ \"Chest\")\nกล่องที่เปิดแล้วหายจาก ESP เอง"})
local R = Tabs.ESP:Section({Side = "Right"})
R:Header({Text = "กล่องที่เห็นตอนนี้"})
local cntLbl = R:Label({Text = "-"})

local P = Tabs.PESP:Section({Side = "Left"})
P:Header({Text = "Player ESP (realtime)"})
P:Toggle({Name = "เปิด ESP คน", Default = e.pOn, Callback = function(v) e.pOn = v; sv() end}, "BRPOn")
P:Toggle({Name = "กรอบตามตัว", Default = e.pBox, Callback = function(v) e.pBox = v; sv() end}, "BRPBox")
P:Toggle({Name = "Skeleton (โครงกระดูก)", Default = e.pSkel, Callback = function(v) e.pSkel = v; sv() end}, "BRPSkel")
P:Toggle({Name = "ชื่อ + ระยะ", Default = e.pName, Callback = function(v) e.pName = v; sv() end}, "BRPName")
P:Toggle({Name = "แถบเลือด", Default = e.pHealth, Callback = function(v) e.pHealth = v; sv() end}, "BRPHealth")
P:Toggle({Name = "เส้น Tracer จากกลางจอล่าง", Default = e.pTracer, Callback = function(v) e.pTracer = v; sv() end}, "BRPTracer")
P:Toggle({Name = "แสดงเพื่อนในปาร์ตี้ด้วย (สีเขียว)", Default = e.pTeam, Callback = function(v) e.pTeam = v; sv() end}, "BRPTeam")
P:Slider({Name = "ระยะแสดงสูงสุด", Minimum = 50, Maximum = 5000, Default = tonumber(e.pMaxDist) or 2000,
	Precision = 0, DisplayMethod = "Round", Suffix = " studs",
	Callback = function(v) e.pMaxDist = math.floor(v + 0.5); sv() end}, "BRPMaxDist")
P:Label({Text = "ศัตรู = แดง · เพื่อนปาร์ตี้ = เขียว\nอัปเดตทุกเฟรม กรอบพอดีตัวตามท่าทาง"})

local S = Tabs.Settings:Section({Side = "Left"})
S:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() W:SetState(not W:GetState()) end) end}, "BRToggleUI")
S:Label({Text = "ตั้งค่าเซฟที่: " .. SF})

task.spawn(function()
	while alive() do
		pcall(function()
			local lines, total = {}, 0
			for _, r in ipairs(rarOpts) do
				local n = counts[r] or 0
				total += n
				if n > 0 then lines[#lines + 1] = ("%s: %d"):format(r, n) end
			end
			cntLbl:UpdateName(("ทั้งหมด %d กล่อง\n%s"):format(total, #lines > 0 and table.concat(lines, "\n") or "-"))
		end)
		task.wait(0.5)
	end
end)

W.onUnloaded(function()
	if getgenv().__BRESP == G then getgenv().__BRESP = G + 1 end
	pcall(function() addConn:Disconnect() end)
	pcall(function() remConn:Disconnect() end)
	pcall(function() holder:Destroy() end)
	pcall(function() renderConn:Disconnect() end)
	pcall(function() remPlayer:Disconnect() end)
	for p in pairs(pDraw) do dropPlayer(p) end
	print("[BR ESP] Unloaded")
end)
Tabs.ESP:Select()
print("[BR ESP] UI ready")
