getgenv().__SPD=(getgenv().__SPD or 0)+1;local GEN=getgenv().__SPD
pcall(function() if getgenv().__SPDGUI then getgenv().__SPDGUI:Destroy() end end)
local e=getgenv()

local Players=game:GetService("Players")
local UIS=game:GetService("UserInputService")
local RunService=game:GetService("RunService")
local HS=game:GetService("HttpService")
local MPS=game:GetService("MarketplaceService")
local VU=game:GetService("VirtualUser")
local TSvc=game:GetService("TeleportService")
local LP=Players.LocalPlayer

local WS_MIN,WS_MAX=8,300
local VIP_ID=1943557897
local SF="PullAnEgg/panel.json"
local WORLDS={"Spawn","Candy","Frozen","Neon","Galaxy","Glitch","Heaven","Hell","Acid","Circus",
	"Backrooms","Swamp","Spooky","Dreamy","Volcano","Ruby","Sakura","Shadow","Strawberry"}

local function hum()
	local c=LP.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function hrp()
	local c=LP.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function remotesFolder()
	local rs=game:GetService("ReplicatedStorage")
	local sm=rs:FindFirstChild("SharedModules")
	local net=sm and sm:FindFirstChild("Network")
	return net and net:FindFirstChild("Remotes")
end
local function fireRemote(name,...)
	local f=remotesFolder()
	local r=f and f:FindFirstChild(name)
	if r and r:IsA("RemoteEvent") then
		local args={...}
		pcall(function() r:FireServer(table.unpack(args)) end)
		return true
	end
	return false
end

-- ===== state =====
if e.__spdDefault==nil then
	local h=hum()
	e.__spdDefault=(h and h.WalkSpeed and h.WalkSpeed<=40) and h.WalkSpeed or 16
end
local baseWS=e.__spdDefault

local defaults={spdOn=false,spdVal=50,sunOn=false,afkOn=true,recOn=true,
	rbOn=false,trOn=false,dbOn=false,vipOn=false,zone="Candy"}
for k,v in pairs(defaults) do if e[k]==nil then e[k]=v end end
if e.__sunCount==nil then e.__sunCount=0 end

pcall(function()
	if isfile and isfile(SF) then
		local d=HS:JSONDecode(readfile(SF))
		if type(d)=="table" then
			for k,_ in pairs(defaults) do
				if type(d[k])==type(defaults[k]) then e[k]=d[k] end
			end
			if tonumber(d.spdVal) then e.spdVal=math.clamp(tonumber(d.spdVal),WS_MIN,WS_MAX) end
		end
	end
end)
local function save()
	pcall(function()
		if makefolder and isfolder and not isfolder("PullAnEgg") then makefolder("PullAnEgg") end
		local d={} for k,_ in pairs(defaults) do d[k]=e[k] end
		writefile(SF,HS:JSONEncode(d))
	end)
end

-- ===== Speed =====
local function applySpeed()
	local h=hum()
	if h then h.WalkSpeed = e.spdOn and e.spdVal or baseWS end
end
task.spawn(function()
	while e.__SPD==GEN do applySpeed();task.wait(0.4) end
end)
LP.CharacterAdded:Connect(function()
	if e.__SPD~=GEN then return end
	task.wait(0.6);applySpeed()
end)

-- ===== Auto Instant Collect Sun (Summer Coins) =====
local function sunFolder()
	local live=workspace:FindFirstChild("Live")
	return live and live:FindFirstChild("SummerCoins")
end
local function grabCoin(coin)
	if not (e.sunOn and coin and coin.Parent and coin:IsA("BasePart")) then return end
	if typeof(firetouchinterest)~="function" then return end
	local h=hrp()
	if not h then return end
	pcall(function() firetouchinterest(h,coin,0);firetouchinterest(h,coin,1) end)
end
pcall(function() if e.__sunAdd then e.__sunAdd:Disconnect() end end)
pcall(function() if e.__sunRem then e.__sunRem:Disconnect() end end)
task.spawn(function()
	while e.__SPD==GEN do
		local f=sunFolder()
		if f then
			e.__sunAdd=f.ChildAdded:Connect(function(coin)
				if e.__SPD~=GEN then return end
				task.wait(0.03);grabCoin(coin)
			end)
			e.__sunRem=f.ChildRemoved:Connect(function()
				if e.__SPD==GEN and e.sunOn then e.__sunCount=(e.__sunCount or 0)+1 end
			end)
			break
		end
		task.wait(1)
	end
end)
task.spawn(function()
	while e.__SPD==GEN do
		if e.sunOn then
			local f=sunFolder()
			if f then for _,c in ipairs(f:GetChildren()) do grabCoin(c) end end
		end
		task.wait(0.4)
	end
end)

-- ===== Auto Rebirth (every 1s) =====
task.spawn(function()
	while e.__SPD==GEN do
		if e.rbOn then fireRemote("Rebirth") end
		task.wait(1)
	end
end)

-- ===== Auto Train / Auto Dumbbell (Activate Dumbell -- same server action; spam every frame) =====
local lastEquip=0
RunService.Heartbeat:Connect(function()
	if e.__SPD~=GEN then return end
	if not (e.trOn or e.dbOn) then return end
	if LP:GetAttribute("holdingFriend") then return end
	-- keep a dumbbell equipped + flag training zone (best effort)
	if os.clock()-lastEquip>3 then
		lastEquip=os.clock()
		fireRemote("Equip Best")
	end
	pcall(function() LP:SetAttribute("InTrainingZone",true) end)
	fireRemote("Activate Dumbell")
end)

-- ===== Unlock VIP Zone (client-side gamepass spoof) =====
pcall(function()
	if not e.__vipHooked then
		e.__vipHooked=true
		-- hook the game's own check
		pcall(function()
			local sc=_G._Lib and _G._Lib.ShopController
			if sc and type(sc.OwnsGamepass)=="function" then
				local orig=sc.OwnsGamepass
				e.__origOwns=orig
				sc.OwnsGamepass=function(self,id,...)
					if e.vipOn and (id==VIP_ID or tostring(id)=="VIP") then return true end
					return orig(self,id,...)
				end
			end
		end)
		-- hook MarketplaceService as a fallback
		if typeof(hookfunction)=="function" then
			pcall(function()
				local o
				o=hookfunction(MPS.UserOwnsGamePassAsync,function(mps,userId,passId)
					if e.vipOn and passId==VIP_ID then return true end
					return o(mps,userId,passId)
				end)
			end)
		end
	end
end)

-- ===== Anti-AFK =====
if not e.__AFKh then
	e.__AFKh=true
	LP.Idled:Connect(function()
		if e.afkOn then pcall(function() VU:CaptureController();VU:ClickButton2(Vector2.new()) end) end
	end)
end

-- ===== Auto Reconnect =====
if not e.__RH then
	e.__RH=true
	local fired=false
	local function reconnect()
		if fired then return end
		fired=true;task.delay(5,function() fired=false end)
		if e.recOn then pcall(function() TSvc:Teleport(game.PlaceId,LP) end) end
	end
	e.__doReconnect=reconnect
	Players.PlayerRemoving:Connect(function(p) if p==LP then reconnect() end end)
	LP.AncestryChanged:Connect(function(_,parent) if parent~=Players then reconnect() end end)
end
task.spawn(function()
	while e.__SPD==GEN do
		task.wait(5)
		if e.recOn and e.__doReconnect then
			pcall(function()
				for _,i in ipairs(game:GetService("CoreGui"):GetDescendants()) do
					if i:IsA("TextLabel") and i.Text=="Disconnected" then e.__doReconnect();return end
				end
			end)
		end
	end
end)

-- ===== UI =====
local ACC={
	spdOn=Color3.fromRGB(90,150,255), sunOn=Color3.fromRGB(255,190,60),
	rbOn=Color3.fromRGB(200,120,255), trOn=Color3.fromRGB(255,120,120),
	dbOn=Color3.fromRGB(255,150,90), vipOn=Color3.fromRGB(255,215,90),
	afkOn=Color3.fromRGB(110,190,110), recOn=Color3.fromRGB(110,190,110),
}
local OFFCOL=Color3.fromRGB(60,60,68)

local gui=Instance.new("ScreenGui")
gui.Name="SpeedUI_"..tostring(math.random(100000,999999))
gui.ResetOnSpawn=false
gui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
gui.DisplayOrder=2000000000
gui.Parent=(gethui and gethui()) or game:GetService("CoreGui")
e.__SPDGUI=gui

local frame=Instance.new("Frame")
frame.Size=UDim2.fromOffset(248,470)
frame.Position=UDim2.new(0,24,0.5,-235)
frame.BackgroundColor3=Color3.fromRGB(20,20,24)
frame.BorderSizePixel=0
frame.Active=true
frame.Parent=gui
Instance.new("UICorner",frame).CornerRadius=UDim.new(0,8)
local st=Instance.new("UIStroke",frame);st.Color=Color3.fromRGB(255,255,255);st.Transparency=0.9

local bar=Instance.new("Frame")
bar.Size=UDim2.new(1,0,0,30)
bar.BackgroundColor3=Color3.fromRGB(28,28,34)
bar.BorderSizePixel=0
bar.Parent=frame
Instance.new("UICorner",bar).CornerRadius=UDim.new(0,8)
local titleLbl=Instance.new("TextLabel")
titleLbl.BackgroundTransparency=1
titleLbl.Size=UDim2.new(1,-24,1,0)
titleLbl.Position=UDim2.fromOffset(12,0)
titleLbl.Font=Enum.Font.GothamBold
titleLbl.TextSize=13
titleLbl.TextColor3=Color3.fromRGB(235,235,240)
titleLbl.TextXAlignment=Enum.TextXAlignment.Left
titleLbl.Text="Pull An Egg  ·  Panel"
titleLbl.Parent=bar

local body=Instance.new("ScrollingFrame")
body.Position=UDim2.fromOffset(0,30)
body.Size=UDim2.new(1,0,1,-30)
body.BackgroundTransparency=1
body.BorderSizePixel=0
body.ScrollBarThickness=3
body.ScrollBarImageTransparency=0.6
body.CanvasSize=UDim2.new()
body.AutomaticCanvasSize=Enum.AutomaticSize.Y
body.Parent=frame
local pad=Instance.new("UIPadding",body)
pad.PaddingLeft=UDim.new(0,12);pad.PaddingRight=UDim.new(0,12)
pad.PaddingTop=UDim.new(0,10);pad.PaddingBottom=UDim.new(0,10)
local list=Instance.new("UIListLayout",body)
list.Padding=UDim.new(0,8)
list.SortOrder=Enum.SortOrder.LayoutOrder
local ORDER=0
local function nextOrder() ORDER+=1 return ORDER end

local redraws={}
local function header(text)
	local l=Instance.new("TextLabel")
	l.BackgroundTransparency=1
	l.Size=UDim2.new(1,0,0,16)
	l.LayoutOrder=nextOrder()
	l.Font=Enum.Font.GothamBold
	l.TextSize=11
	l.TextColor3=Color3.fromRGB(140,140,150)
	l.TextXAlignment=Enum.TextXAlignment.Left
	l.Text=string.upper(text)
	l.Parent=body
end

local function toggleRow(name,key)
	local row=Instance.new("Frame")
	row.BackgroundTransparency=1
	row.Size=UDim2.new(1,0,0,22)
	row.LayoutOrder=nextOrder()
	row.Parent=body
	local lbl=Instance.new("TextLabel")
	lbl.BackgroundTransparency=1
	lbl.Size=UDim2.new(1,-52,1,0)
	lbl.Font=Enum.Font.GothamMedium
	lbl.TextSize=13
	lbl.TextColor3=Color3.fromRGB(235,235,240)
	lbl.TextXAlignment=Enum.TextXAlignment.Left
	lbl.Text=name
	lbl.Parent=row
	local b=Instance.new("TextButton")
	b.Size=UDim2.fromOffset(44,18)
	b.Position=UDim2.new(1,-44,0.5,-9)
	b.BackgroundColor3=OFFCOL
	b.BorderSizePixel=0
	b.AutoButtonColor=false
	b.Text=""
	b.Parent=row
	Instance.new("UICorner",b).CornerRadius=UDim.new(1,0)
	local k=Instance.new("Frame")
	k.Size=UDim2.fromOffset(14,14)
	k.Position=UDim2.fromOffset(2,2)
	k.BackgroundColor3=Color3.fromRGB(230,230,235)
	k.BorderSizePixel=0
	k.Parent=b
	Instance.new("UICorner",k).CornerRadius=UDim.new(1,0)
	local function paint()
		b.BackgroundColor3 = e[key] and (ACC[key] or Color3.fromRGB(90,150,255)) or OFFCOL
		k.Position = e[key] and UDim2.fromOffset(28,2) or UDim2.fromOffset(2,2)
	end
	b.MouseButton1Click:Connect(function()
		e[key]=not e[key];paint();save()
	end)
	redraws[#redraws+1]=paint
	paint()
end

-- SPEED
header("Movement")
do
	local row=Instance.new("Frame")
	row.BackgroundTransparency=1
	row.Size=UDim2.new(1,0,0,22)
	row.LayoutOrder=nextOrder()
	row.Parent=body
	local lbl=Instance.new("TextLabel")
	lbl.BackgroundTransparency=1
	lbl.Size=UDim2.new(1,-52,1,0)
	lbl.Font=Enum.Font.GothamMedium
	lbl.TextSize=13
	lbl.TextColor3=Color3.fromRGB(235,235,240)
	lbl.TextXAlignment=Enum.TextXAlignment.Left
	lbl.Text="Speed"
	lbl.Parent=row
	local b=Instance.new("TextButton")
	b.Size=UDim2.fromOffset(44,18);b.Position=UDim2.new(1,-44,0.5,-9)
	b.BackgroundColor3=OFFCOL;b.BorderSizePixel=0;b.AutoButtonColor=false;b.Text=""
	b.Parent=row
	Instance.new("UICorner",b).CornerRadius=UDim.new(1,0)
	local k=Instance.new("Frame")
	k.Size=UDim2.fromOffset(14,14);k.Position=UDim2.fromOffset(2,2)
	k.BackgroundColor3=Color3.fromRGB(230,230,235);k.BorderSizePixel=0;k.Parent=b
	Instance.new("UICorner",k).CornerRadius=UDim.new(1,0)

	local sr=Instance.new("Frame")
	sr.BackgroundTransparency=1
	sr.Size=UDim2.new(1,0,0,28)
	sr.LayoutOrder=nextOrder()
	sr.Parent=body
	local boxbg=Instance.new("TextBox")
	boxbg.Size=UDim2.fromOffset(46,22);boxbg.Position=UDim2.fromOffset(0,3)
	boxbg.BackgroundColor3=Color3.fromRGB(30,30,36);boxbg.BorderSizePixel=0
	boxbg.Font=Enum.Font.GothamMedium;boxbg.TextSize=13
	boxbg.TextColor3=Color3.fromRGB(235,235,240);boxbg.ClearTextOnFocus=false
	boxbg.Text=tostring(e.spdVal);boxbg.Parent=sr
	Instance.new("UICorner",boxbg).CornerRadius=UDim.new(0,6)
	local track=Instance.new("Frame")
	track.Size=UDim2.new(1,-58,0,6);track.Position=UDim2.fromOffset(56,11)
	track.BackgroundColor3=Color3.fromRGB(45,45,52);track.BorderSizePixel=0
	track.Active=true;track.Parent=sr
	Instance.new("UICorner",track).CornerRadius=UDim.new(1,0)
	local fill=Instance.new("Frame")
	fill.BackgroundColor3=ACC.spdOn;fill.BorderSizePixel=0;fill.Parent=track
	Instance.new("UICorner",fill).CornerRadius=UDim.new(1,0)
	local sk=Instance.new("Frame")
	sk.Size=UDim2.fromOffset(14,14);sk.AnchorPoint=Vector2.new(0.5,0.5)
	sk.BackgroundColor3=Color3.fromRGB(235,235,240);sk.BorderSizePixel=0;sk.ZIndex=2;sk.Parent=track
	Instance.new("UICorner",sk).CornerRadius=UDim.new(1,0)

	local function paint()
		e.spdVal=math.clamp(math.floor(e.spdVal+0.5),WS_MIN,WS_MAX)
		local a=(e.spdVal-WS_MIN)/(WS_MAX-WS_MIN)
		fill.Size=UDim2.new(a,0,1,0)
		sk.Position=UDim2.new(a,0,0.5,0)
		if not boxbg:IsFocused() then boxbg.Text=tostring(e.spdVal) end
		b.BackgroundColor3=e.spdOn and ACC.spdOn or OFFCOL
		k.Position=e.spdOn and UDim2.fromOffset(28,2) or UDim2.fromOffset(2,2)
		lbl.Text=e.spdOn and ("Speed  "..e.spdVal) or "Speed"
		applySpeed()
	end
	b.MouseButton1Click:Connect(function() e.spdOn=not e.spdOn;paint();save() end)
	boxbg.FocusLost:Connect(function()
		local n=tonumber(boxbg.Text)
		if n then e.spdVal=n;e.spdOn=true end
		paint();save()
	end)
	local drag=false
	local function fromX(x)
		local rel=math.clamp((x-track.AbsolutePosition.X)/math.max(track.AbsoluteSize.X,1),0,1)
		e.spdVal=WS_MIN+rel*(WS_MAX-WS_MIN);e.spdOn=true;paint();save()
	end
	track.InputBegan:Connect(function(i)
		if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then drag=true;fromX(i.Position.X) end
	end)
	UIS.InputEnded:Connect(function(i)
		if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then drag=false end
	end)
	UIS.InputChanged:Connect(function(i)
		if drag and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then fromX(i.Position.X) end
	end)
	redraws[#redraws+1]=paint
	paint()

	local hnt=Instance.new("TextLabel")
	hnt.BackgroundTransparency=1
	hnt.Size=UDim2.new(1,0,0,12);hnt.LayoutOrder=nextOrder()
	hnt.Font=Enum.Font.Gotham;hnt.TextSize=10
	hnt.TextColor3=Color3.fromRGB(140,140,150);hnt.TextXAlignment=Enum.TextXAlignment.Left
	hnt.Text="default "..baseWS.."  ·  "..WS_MIN.."-"..WS_MAX
	hnt.Parent=body
end

-- FARM
header("Farm")
toggleRow("Auto Instant Collect Sun","sunOn")
local sunStat=Instance.new("TextLabel")
sunStat.BackgroundTransparency=1
sunStat.Size=UDim2.new(1,0,0,12);sunStat.LayoutOrder=nextOrder()
sunStat.Font=Enum.Font.Gotham;sunStat.TextSize=10
sunStat.TextColor3=Color3.fromRGB(140,140,150);sunStat.TextXAlignment=Enum.TextXAlignment.Left
sunStat.Text="collected 0";sunStat.Parent=body
toggleRow("Auto Rebirth  (1s)","rbOn")
toggleRow("Auto Train","trOn")
toggleRow("Auto Dumbbell","dbOn")
local trHint=Instance.new("TextLabel")
trHint.BackgroundTransparency=1
trHint.Size=UDim2.new(1,0,0,24);trHint.LayoutOrder=nextOrder()
trHint.Font=Enum.Font.Gotham;trHint.TextSize=10
trHint.TextColor3=Color3.fromRGB(140,140,150);trHint.TextXAlignment=Enum.TextXAlignment.Left
trHint.TextWrapped=true
trHint.Text="Train / Dumbbell = same action (Activate Dumbell), fired every frame. Server rate-limits."
trHint.Parent=body

-- ZONE
header("Zones")
toggleRow("Unlock VIP Zone","vipOn")
do
	local row=Instance.new("Frame")
	row.BackgroundTransparency=1
	row.Size=UDim2.new(1,0,0,26);row.LayoutOrder=nextOrder()
	row.Parent=body
	local dd=Instance.new("TextButton")
	dd.Size=UDim2.new(1,-52,1,0)
	dd.BackgroundColor3=Color3.fromRGB(30,30,36);dd.BorderSizePixel=0
	dd.Font=Enum.Font.GothamMedium;dd.TextSize=12
	dd.TextColor3=Color3.fromRGB(235,235,240)
	dd.Text="Zone: "..e.zone
	dd.Parent=row
	Instance.new("UICorner",dd).CornerRadius=UDim.new(0,6)
	local go=Instance.new("TextButton")
	go.Size=UDim2.fromOffset(44,26);go.Position=UDim2.new(1,-44,0,0)
	go.BackgroundColor3=Color3.fromRGB(90,150,255);go.BorderSizePixel=0
	go.Font=Enum.Font.GothamBold;go.TextSize=12
	go.TextColor3=Color3.fromRGB(255,255,255);go.Text="Go"
	go.Parent=row
	Instance.new("UICorner",go).CornerRadius=UDim.new(0,6)

	local menu=Instance.new("Frame")
	menu.Visible=false
	menu.BackgroundColor3=Color3.fromRGB(26,26,32);menu.BorderSizePixel=0
	menu.Size=UDim2.fromOffset(150,180)
	menu.ZIndex=50
	menu.Parent=frame
	Instance.new("UICorner",menu).CornerRadius=UDim.new(0,6)
	local ms=Instance.new("ScrollingFrame",menu)
	ms.Size=UDim2.fromScale(1,1);ms.BackgroundTransparency=1;ms.BorderSizePixel=0
	ms.ScrollBarThickness=3;ms.CanvasSize=UDim2.new();ms.AutomaticCanvasSize=Enum.AutomaticSize.Y
	ms.ZIndex=50
	local ml=Instance.new("UIListLayout",ms);ml.Padding=UDim.new(0,1)
	for _,w in ipairs(WORLDS) do
		local it=Instance.new("TextButton")
		it.Size=UDim2.new(1,0,0,22);it.BackgroundColor3=Color3.fromRGB(26,26,32)
		it.BorderSizePixel=0;it.Font=Enum.Font.Gotham;it.TextSize=12
		it.TextColor3=Color3.fromRGB(220,220,225);it.Text=w;it.ZIndex=50;it.Parent=ms
		it.MouseButton1Click:Connect(function()
			e.zone=w;dd.Text="Zone: "..w;menu.Visible=false;save()
		end)
	end
	dd.MouseButton1Click:Connect(function()
		menu.Position=UDim2.fromOffset(dd.AbsolutePosition.X-frame.AbsolutePosition.X,
			dd.AbsolutePosition.Y-frame.AbsolutePosition.Y+28)
		menu.Visible=not menu.Visible
	end)
	go.MouseButton1Click:Connect(function()
		if e.zone=="Spawn" then fireRemote("Teleport To Spawn")
		else fireRemote("Teleport To World",e.zone) end
	end)
end

-- SYSTEM
header("System")
toggleRow("Anti-AFK","afkOn")
toggleRow("Auto Reconnect","recOn")

-- window drag
do
	local dz,ds,sp=false
	bar.InputBegan:Connect(function(i)
		if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then
			dz=true;ds=i.Position;sp=frame.Position
		end
	end)
	bar.InputEnded:Connect(function(i)
		if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dz=false end
	end)
	UIS.InputChanged:Connect(function(i)
		if dz and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
			local d=i.Position-ds
			frame.Position=UDim2.new(sp.X.Scale,sp.X.Offset+d.X,sp.Y.Scale,sp.Y.Offset+d.Y)
		end
	end)
end

-- status updater
task.spawn(function()
	while e.__SPD==GEN do
		local f=sunFolder()
		local onG=f and #f:GetChildren() or 0
		sunStat.Text=("collected %d  ·  %d on ground%s"):format(e.__sunCount or 0,onG,f and "" or "  (event off)")
		task.wait(0.5)
	end
end)

for _,fn in ipairs(redraws) do pcall(fn) end
print(("[SPD] Panel ready (gen %d) default=%d"):format(GEN,baseWS))
