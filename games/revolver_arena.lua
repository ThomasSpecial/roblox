-- [RANKED] Revolver Arena (placeId 108419873026523) -- ESP / Aimbot (silent + camera) / Auto Shoot / Wallbang
-- MacLib window, RightShift toggles it, settings persist (RevolverArena/state_<uid>.json).
--
-- From the game's own client (Client.Weapons.WeaponController.fireRevolver):
--   * every shooter (players AND bots) is a Model in workspace.Combatants; bots have
--     CombatantId "B<n>", players "P<userId>"; dead = attribute Alive == false, spawn shield = Protected
--   * a shot = dir from AimAssist.bendShot(camPos, camLook) -> client raycast -> Network.Fire:FireServer
--     {id, origin, dir, hit = {model, part, pos}?, extra}. Network is a QuickNet table, so its
--     FireServer is a plain Lua field we can wrap; WeaponController requires the same table.
--   * Hitbox: Head/HitboxHead = HeadDamage 999 (one shot), body parts = 100 (ranked 50)
-- Silent aim: bendShot returns the direction to the target part (client ray, tracer and
-- hit marker all agree); Wallbang: the Fire payload gets hit = target part even when the
-- client ray stopped on a wall.

getgenv().__RVA = (getgenv().__RVA or 0) + 1
local G = getgenv().__RVA
pcall(function() if getgenv().__RVAW then getgenv().__RVAW:Unload() end end)
pcall(function() if getgenv().__RVA_RESTORE then getgenv().__RVA_RESTORE() end end)
local function alive() return getgenv().__RVA == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera

local Shared = RS:WaitForChild("Shared", 30)
local okT, Teams = pcall(function() return require(Shared:WaitForChild("Teams", 15)) end)
local okN, Net = pcall(function() return require(Shared:WaitForChild("Network", 15)) end)
local aaMod = plr.PlayerScripts:WaitForChild("Client", 10)
aaMod = aaMod and aaMod:WaitForChild("Weapons", 10)
aaMod = aaMod and aaMod:WaitForChild("AimAssist", 10)
local okA, AimAssist = pcall(require, aaMod)

-- ------------------------------------------------------------------ settings
local SF = ("RevolverArena/state_%d.json"):format(plr.UserId)
local DEFAULTS = {espOn = true, espName = true, espDist = true, espGlow = true, espBots = true,
	aimOn = true, aimMode = "Silent Aim", aimPart = "Head", aimFov = 250, aimFovInf = false, aimFovShow = true,
	aimSmooth = 0.35, aimHold = true, wallbang = false, visOnly = true,
	autoShoot = false}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
local function sv()
	pcall(function()
		if makefolder and not isfolder("RevolverArena") then makefolder("RevolverArena") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

local ENEMY, MATE, LOCKED = Color3.fromRGB(255, 60, 60), Color3.fromRGB(0, 255, 90), Color3.fromRGB(255, 220, 40)

-- ------------------------------------------------------------------ combatants
local function combatFolder() return workspace:FindFirstChild("Combatants") end
local function myModel()
	local f = combatFolder()
	return (f and f:FindFirstChild(plr.Name)) or plr.Character
end
local function isMe(m) return m == plr.Character or m.Name == plr.Name or m:GetAttribute("UserId") == plr.UserId end
local function isAlly(m)
	local mine = myModel()
	if not (okT and mine) then return false end
	local ok, r = pcall(Teams.allies, m, mine)
	return ok and r == true
end
local function isBot(m) return tostring(m:GetAttribute("CombatantId") or ""):sub(1, 1) == "B" end
local function aliveModel(m)
	if m:GetAttribute("Alive") == false then return false end
	local h = m:FindFirstChildOfClass("Humanoid")
	return not h or h.Health > 0
end

local PART_ALIASES = {
	Head = {"Head", "HitboxHead"},
	UpperTorso = {"UpperTorso", "HitboxBody", "LowerTorso"},
	LowerTorso = {"LowerTorso", "UpperTorso", "HitboxBody"},
}
local function aimPartOf(m)
	local want = e.aimPart
	if want == "สุ่ม (หัว/ตัว)" then want = math.random() < 0.5 and "Head" or "UpperTorso" end
	for _, n in ipairs(PART_ALIASES[want] or PART_ALIASES.Head) do
		local p = m:FindFirstChild(n)
		if p and p:IsA("BasePart") then return p end
	end
	return m:FindFirstChild("Head") or m.PrimaryPart
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local function visible(part, model)
	local ex = {cam}
	local mine = myModel()
	if mine then ex[#ex + 1] = mine end
	if plr.Character and plr.Character ~= mine then ex[#ex + 1] = plr.Character end
	for _, n in ipairs({"Effects", "Ragdolls", "Revolver", "Knife"}) do
		local f = workspace:FindFirstChild(n)
		if f then ex[#ex + 1] = f end
	end
	rayParams.FilterDescendantsInstances = ex
	local o = cam.CFrame.Position
	local hit = workspace:Raycast(o, part.Position - o, rayParams)
	return not hit or hit.Instance:IsDescendantOf(model)
end

-- ------------------------------------------------------------------ target pick
local target, targetPart = nil, nil
local function pickTarget()
	local f = combatFolder()
	if not f then return nil end
	local mid = cam.ViewportSize / 2
	local best, bestScore, bestPart
	for _, m in ipairs(f:GetChildren()) do
		if m:IsA("Model") and not isMe(m) and aliveModel(m) and m:GetAttribute("Protected") ~= true and not isAlly(m) then
			local p = aimPartOf(m)
			if p then
				local sp, on = cam:WorldToViewportPoint(p.Position)
				local d2 = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
				local inFov = e.aimFovInf or (on and d2 <= e.aimFov)
				if inFov then
					local seen = visible(p, m)
					if seen or e.wallbang or not e.visOnly then
						local score = (on and d2 or 5000) + (seen and 0 or 2000)
						if not bestScore or score < bestScore then best, bestScore, bestPart = m, score, p end
					end
				end
			end
		end
	end
	return best, bestPart
end

-- ------------------------------------------------------------------ hooks (silent aim / wallbang)
local origBend = okA and AimAssist and AimAssist.bendShot
local origFire = okN and Net and Net.Fire and Net.Fire.FireServer
local function silentOn() return e.aimOn and e.aimMode == "Silent Aim" end
-- the game's module tables are frozen (table.freeze) -> unfreeze just for the swap
local function setField(t, k, v)
	local ro = isreadonly and isreadonly(t)
	if ro and setreadonly then setreadonly(t, false) end
	rawset(t, k, v)
	if ro and setreadonly then setreadonly(t, true) end
end
local myBend, myFire
if origBend then
	myBend = function(o, look, ...)
		if alive() and silentOn() and targetPart and targetPart.Parent then
			return (targetPart.Position - o).Unit
		end
		return origBend(o, look, ...)
	end
	setField(AimAssist, "bendShot", myBend)
end
if origFire then
	myFire = function(self, payload, ...)
		if alive() and e.aimOn and type(payload) == "table" and target and targetPart and targetPart.Parent then
			local pos = targetPart.Position
			local o = payload.origin or cam.CFrame.Position
			if silentOn() or e.wallbang then payload.dir = (pos - o).Unit end
			if e.wallbang and not payload.hit then
				payload.hit = {model = target, part = targetPart.Name, pos = pos}
				payload.extra = nil
			end
		end
		return origFire(self, payload, ...)
	end
	setField(Net.Fire, "FireServer", myFire)
end
-- only undo OUR hooks: an old copy's (deferred) unload must not strip a newer copy's hooks
local function restore()
	if myBend and AimAssist.bendShot == myBend then setField(AimAssist, "bendShot", origBend) end
	if myFire and Net.Fire.FireServer == myFire then setField(Net.Fire, "FireServer", origFire) end
end
getgenv().__RVA_RESTORE = restore

-- ------------------------------------------------------------------ ESP
local holder = Instance.new("Folder")
holder.Name = "RVA_ESP"
holder.Parent = (gethui and gethui()) or game:GetService("CoreGui")
local esp = {}   -- model -> {hl, bb, lbl}
local function dropEsp(m)
	local d = esp[m]
	if d then pcall(function() d.hl:Destroy() end); pcall(function() d.bb:Destroy() end); esp[m] = nil end
end
local function getEsp(m)
	local d = esp[m]
	if d and d.hl.Parent then return d end
	local hl = Instance.new("Highlight")
	hl.FillTransparency = 0.6
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Parent = holder
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(200, 34)
	bb.StudsOffset = Vector3.new(0, 3.2, 0)
	bb.AlwaysOnTop = true
	bb.Parent = holder
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 13
	lbl.TextStrokeTransparency = 0.3
	lbl.Parent = bb
	d = {hl = hl, bb = bb, lbl = lbl}
	esp[m] = d
	return d
end

local fovCircle
pcall(function()
	fovCircle = Drawing.new("Circle")
	fovCircle.Thickness = 1.5
	fovCircle.NumSides = 64
	fovCircle.Filled = false
	fovCircle.Transparency = 0.8
	fovCircle.Color = Color3.fromRGB(255, 255, 255)
end)

-- ------------------------------------------------------------------ main loop
local lastShot = 0
local aiming = false
UIS.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton2 then aiming = true end end)
UIS.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton2 then aiming = false end end)

local renderName = "RVA_Aim_" .. G
RunService:BindToRenderStep(renderName, Enum.RenderPriority.Camera.Value + 1, function()
	if not alive() then pcall(function() RunService:UnbindFromRenderStep(renderName) end); return end
	cam = workspace.CurrentCamera
	-- target
	if e.aimOn then target, targetPart = pickTarget() else target, targetPart = nil, nil end
	-- camera lock
	if e.aimOn and e.aimMode == "Camera Lock" and targetPart and (aiming or not e.aimHold) then
		local cf = cam.CFrame
		local goal = CFrame.lookAt(cf.Position, targetPart.Position)
		cam.CFrame = cf:Lerp(goal, math.clamp(1 - e.aimSmooth, 0.05, 1))
	end
	-- fov circle
	if fovCircle then
		fovCircle.Visible = e.aimOn and e.aimFovShow and not e.aimFovInf
		fovCircle.Position = cam.ViewportSize / 2
		fovCircle.Radius = e.aimFov
		fovCircle.Color = target and LOCKED or Color3.fromRGB(255, 255, 255)
	end
	-- auto shoot (the game's own M1 path: ammo, fire rate and reload stay legit)
	if e.autoShoot and target and os.clock() - lastShot > 0.45 and UIS:GetFocusedTextBox() == nil then
		local ready = e.wallbang or visible(targetPart, target)
		if ready and (e.aimMode == "Silent Aim" or e.aimMode == "Camera Lock") then
			lastShot = os.clock()
			pcall(mouse1click)
		end
	end
end)

task.spawn(function()
	while alive() do
		pcall(function()
			local f = combatFolder()
			local seen = {}
			local myPos = cam.CFrame.Position
			if e.espOn and f then
				for _, m in ipairs(f:GetChildren()) do
					if m:IsA("Model") and not isMe(m) and aliveModel(m) and (e.espBots or not isBot(m)) then
						seen[m] = true
						local d = getEsp(m)
						local mate = isAlly(m)
						local col = (m == target) and LOCKED or (mate and MATE or ENEMY)
						d.hl.Adornee = m
						d.hl.Enabled = e.espGlow
						d.hl.FillColor = col
						d.hl.OutlineColor = col
						local head = m:FindFirstChild("Head") or m.PrimaryPart
						d.bb.Adornee = head
						d.bb.Enabled = (e.espName or e.espDist) and head ~= nil
						local parts = {}
						if e.espName then
							parts[#parts + 1] = (mate and "★ " or "") .. tostring(m:GetAttribute("DisplayName") or m.Name) .. (isBot(m) and " [BOT]" or "")
						end
						if e.espDist and head then parts[#parts + 1] = ("%dm"):format((head.Position - myPos).Magnitude) end
						d.lbl.Text = table.concat(parts, "  ")
						d.lbl.TextColor3 = col
					end
				end
			end
			for m in pairs(esp) do if not seen[m] then dropEsp(m) end end
		end)
		task.wait(0.1)
	end
end)

-- ---------------------------------------------------------------------- UI
local okL, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okL or not Lib then warn("[RVA] MacLib failed: " .. tostring(Lib)) return end
if not alive() then return end
local W = Lib:Window({Title = "Revolver Arena", Subtitle = "ESP / Aim", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__RVAW = W
local TG = W:TabGroup()
local Tabs = {
	Aim = TG:Tab({Name = "Aimbot", Image = "rbxassetid://10734950309"}),
	ESP = TG:Tab({Name = "ESP", Image = "rbxassetid://10723346959"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}
local A = Tabs.Aim:Section({Side = "Left"})
A:Header({Text = "Aimbot"})
A:Toggle({Name = "เปิด Aimbot", Default = e.aimOn, Callback = function(v) e.aimOn = v; sv() end}, "RVAAimOn")
local MODES = {"Silent Aim", "Camera Lock"}
A:Dropdown({Name = "โหมด", Multi = false, Required = true, Options = MODES,
	Default = table.find(MODES, e.aimMode) or 1,
	Callback = function(v) if type(v) == "table" then v = v[1] end; if v then e.aimMode = v; sv() end end}, "RVAAimMode")
local PARTS = {"Head", "UpperTorso", "LowerTorso", "สุ่ม (หัว/ตัว)"}
A:Dropdown({Name = "ยิงส่วนไหน", Multi = false, Required = true, Options = PARTS,
	Default = table.find(PARTS, e.aimPart) or 1,
	Callback = function(v) if type(v) == "table" then v = v[1] end; if v then e.aimPart = v; sv() end end}, "RVAAimPart")
A:Toggle({Name = "ยิงทะลุกำแพง (Wallbang)", Default = e.wallbang, Callback = function(v) e.wallbang = v; sv() end}, "RVAWallbang")
A:Toggle({Name = "ล็อกเฉพาะเป้าที่มองเห็น (ปิด Wallbang อยู่)", Default = e.visOnly, Callback = function(v) e.visOnly = v; sv() end}, "RVAVisOnly")
A:Toggle({Name = "Auto Shoot (ยิงเองเมื่อมีเป้า)", Default = e.autoShoot, Callback = function(v) e.autoShoot = v; sv() end}, "RVAAutoShoot")
A:Header({Text = "FOV / Camera Lock"})
A:Toggle({Name = "ไม่จำกัด FOV (ล็อกทุกทิศ)", Default = e.aimFovInf, Callback = function(v) e.aimFovInf = v; sv() end}, "RVAFovInf")
A:Slider({Name = "FOV", Minimum = 30, Maximum = 800, Default = tonumber(e.aimFov) or 250, Precision = 0,
	DisplayMethod = "Round", Suffix = " px", Callback = function(v) e.aimFov = math.floor(v + 0.5); sv() end}, "RVAFov")
A:Toggle({Name = "แสดงวง FOV", Default = e.aimFovShow, Callback = function(v) e.aimFovShow = v; sv() end}, "RVAFovShow")
A:Toggle({Name = "Camera Lock: ต้องกดคลิกขวาค้าง", Default = e.aimHold, Callback = function(v) e.aimHold = v; sv() end}, "RVAAimHold")
A:Slider({Name = "Camera Lock: ความนุ่ม (0 = ดูดทันที)", Minimum = 0, Maximum = 0.95, Default = tonumber(e.aimSmooth) or 0.35,
	Precision = 2, Callback = function(v) e.aimSmooth = v; sv() end}, "RVASmooth")
A:Label({Text = "Silent Aim: กระสุนวิ่งเข้าเป้าเอง กล้องไม่ขยับ\nCamera Lock: หมุนกล้องเข้าเป้า\nHead = 999 ดาเมจ (นัดเดียวตาย) · ตัว = 100 (Ranked 50)"})

local AR = Tabs.Aim:Section({Side = "Right"})
AR:Header({Text = "สถานะ"})
local stLbl = AR:Label({Text = "-"})

local Es = Tabs.ESP:Section({Side = "Left"})
Es:Header({Text = "ESP"})
Es:Toggle({Name = "เปิด ESP", Default = e.espOn, Callback = function(v) e.espOn = v; sv() end}, "RVAEspOn")
Es:Toggle({Name = "Glow รอบตัว (มองทะลุกำแพง)", Default = e.espGlow, Callback = function(v) e.espGlow = v; sv() end}, "RVAEspGlow")
Es:Toggle({Name = "ชื่อ", Default = e.espName, Callback = function(v) e.espName = v; sv() end}, "RVAEspName")
Es:Toggle({Name = "ระยะ", Default = e.espDist, Callback = function(v) e.espDist = v; sv() end}, "RVAEspDist")
Es:Toggle({Name = "แสดงบอทด้วย", Default = e.espBots, Callback = function(v) e.espBots = v; sv() end}, "RVAEspBots")
Es:Label({Text = "แดง = ศัตรู · เขียว + ★ = ทีมเดียวกัน · เหลือง = เป้าที่ล็อกอยู่\n[BOT] = บอทของเกม"})

local S = Tabs.Settings:Section({Side = "Left"})
S:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() W:SetState(not W:GetState()) end) end}, "RVAToggleUI")
S:Label({Text = "ตั้งค่าเซฟที่: " .. SF})

-- shot results from the server (ShotResult: id, ok, {landed, killed, headshot}) -> status
local results = {shots = 0, landed = 0, kills = 0}
pcall(function()
	Net.ShotResult.OnClientEvent:Connect(function(_, ok, info)
		if not alive() then return end
		results.shots += 1
		if type(info) == "table" then
			if info.landed then results.landed += 1 end
			if info.killed then results.kills += 1 end
		end
	end)
end)
task.spawn(function()
	while alive() do
		pcall(function()
			stLbl:UpdateName(("เป้า: %s%s\nยิง %d · โดน %d · ฆ่า %d"):format(
				target and tostring(target:GetAttribute("DisplayName") or target.Name) or "-",
				targetPart and (" (" .. targetPart.Name .. (visible(targetPart, target) and "" or " · หลังกำแพง") .. ")") or "",
				results.shots, results.landed, results.kills))
		end)
		task.wait(0.3)
	end
end)

W.onUnloaded(function()
	if getgenv().__RVA == G then getgenv().__RVA = G + 1 end
	pcall(function() RunService:UnbindFromRenderStep(renderName) end)
	pcall(restore)
	pcall(function() holder:Destroy() end)
	pcall(function() fovCircle:Remove() end)
	print("[RVA] Unloaded")
end)
Tabs.Aim:Select()
print("[RVA] UI ready")
