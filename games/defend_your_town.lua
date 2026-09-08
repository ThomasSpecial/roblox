getgenv().__DYT=(getgenv().__DYT or 0)+1;local G=getgenv().__DYT
pcall(function() if getgenv().__DYTW then getgenv().__DYTW:Unload() end end)
local e=getgenv()
local myUID=tostring(math.random(1,2^30));e.__dytTok=myUID
print("[DYT] Starting (gen "..G..")...")

local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local VU=game:GetService("VirtualUser")
local TSvc=game:GetService("TeleportService")
local HS=game:GetService("HttpService")
local LP=Players.LocalPlayer

local SF="DefendYourTown/state.json"
local SK={"coinOn","prodOn","chestOn","questOn","startWaveOn","skipWaveOn","afkOn","recOn"}
-- 400 studs covers the whole plot. Do NOT use a huge value: the game's PickupLoot
-- loops over a (2*radius/10)^2 grid every Heartbeat -- 1e9 = full client freeze.
local COIN_BIG=400
local COIN_DEF=25

-- ===== game hooks =====
local EMC;pcall(function() EMC=require(RS.Modules.EventManagerClient) end)
local function fire(name,...)
	if not EMC then return end
	local a={...}
	pcall(function() EMC.FireServer(name,table.unpack(a)) end)
end

local lootMod;pcall(function()
	lootMod=require(LP.PlayerScripts.ClientScripts.Gameplay["C_LootDropHandler "])
end)
local function setCoinRadius(v)
	if not (lootMod and debug and debug.setupvalue) then return end
	pcall(debug.setupvalue,lootMod.PickupLoot,3,v)
	pcall(debug.setupvalue,lootMod.UpdateMagnet,3,v)
end

-- ===== state =====
pcall(function() if not isfolder("DefendYourTown") then makefolder("DefendYourTown") end end)
local function sv() local d={} for _,k in ipairs(SK) do d[k]=e[k] end;pcall(function() writefile(SF,HS:JSONEncode(d)) end) end
pcall(function() local d=HS:JSONDecode(readfile(SF));for _,k in ipairs(SK) do if type(d[k])=="boolean" and e[k]==nil then e[k]=d[k] end end end)
if e.afkOn==nil then e.afkOn=true end
if e.recOn==nil then e.recOn=true end
for _,k in ipairs(SK) do if e[k]==nil then e[k]=false end end
e.__chestSeen=e.__chestSeen or {}
e.__chestCount=e.__chestCount or 0
e.__lastSkip=0

-- ===== loops =====
task.spawn(function()
	while e.__DYT==G do
		if e.coinOn then setCoinRadius(COIN_BIG) end
		task.wait(1)
	end
end)

task.spawn(function()
	while e.__DYT==G do
		if e.prodOn then
			pcall(function() LP:SetAttribute("AutoCollect",true) end)
			if not LP:GetAttribute("AutoCollectActive") then fire("ToggleAutoCollect") end
		end
		task.wait(1)
	end
end)

local function scanChests()
	local gp=workspace:FindFirstChild("Gameplay")
	local bin=gp and gp:FindFirstChild("Bin")
	if not bin then return end
	for _,d in ipairs(bin:GetChildren()) do            -- Bin only -- ~40 items, not the whole map
		if d:IsA("Model") then
			local uq=d:GetAttribute("UnqiueID")
			if uq and d:GetAttribute("DespawnAt") and not e.__chestSeen[uq] then
				e.__chestSeen[uq]=true
				e.__chestCount=(e.__chestCount or 0)+1
				fire("ChestOpened",uq)
			end
		end
	end
end
task.spawn(function()
	while e.__DYT==G do
		if e.chestOn then pcall(scanChests) end
		task.wait(1.5)
	end
end)

-- ===== Auto Claim Quest (daily quests + daily goal; server ignores incomplete) =====
task.spawn(function()
	while e.__DYT==G do
		if e.questOn then
			for i=1,6 do fire("ClaimDailyQuestReward",i) end
			fire("ClaimDailyGoalReward")
		end
		task.wait(5)
	end
end)

task.spawn(function()
	while e.__DYT==G do
		if e.startWaveOn then
			if not LP:GetAttribute("AutoGoblinRaid") then fire("ToggleAutoGoblinRaid") end
			if not workspace:FindFirstChild("Gameplay") or not LP:GetAttribute("RaidActive") then
				fire("StartGoblinRaid")
			end
		end
		task.wait(2)
	end
end)

task.spawn(function()
	while e.__DYT==G do
		if e.skipWaveOn then
			if not LP:GetAttribute("AutoSkipWave") then fire("ToggleAutoSkipWave") end
			if os.clock()-e.__lastSkip>2.2 then
				e.__lastSkip=os.clock()
				fire("SkipGoblinRaidWave",false)
			end
		end
		task.wait(1)
	end
end)

-- ===== Anti-AFK / Auto Reconnect =====
if not e.__DYT_AFK then
	e.__DYT_AFK=true
	LP.Idled:Connect(function()
		if e.afkOn then pcall(function() VU:CaptureController();VU:ClickButton2(Vector2.new()) end) end
	end)
end
if not e.__DYT_REC then
	e.__DYT_REC=true
	local fired=false
	function e.__dytRec()
		if fired then return end
		fired=true;task.delay(5,function() fired=false end)
		if e.recOn then pcall(function() TSvc:Teleport(game.PlaceId,LP) end) end
	end
	Players.PlayerRemoving:Connect(function(p) if p==LP then e.__dytRec() end end)
	LP.AncestryChanged:Connect(function(_,pa) if pa~=Players then e.__dytRec() end end)
end
task.spawn(function()
	while e.__DYT==G do
		task.wait(5)
		if e.recOn and e.__dytRec then
			pcall(function()
				for _,i in ipairs(game:GetService("CoreGui"):GetDescendants()) do
					if i:IsA("TextLabel") and i.Text=="Disconnected" then e.__dytRec() return end
				end
			end)
		end
	end
end)

-- ===== UI (MacLib) =====
print("[DYT] Loading UI...")
local ok,lib=pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not ok or not lib then print("[DYT] MacLib failed: "..tostring(lib)) return end
local Lib=lib
task.wait()
if e.__DYT~=G or e.__dytTok~=myUID then print("[DYT] Aborted") return end
pcall(function() if e.__DYTW then e.__DYTW:Unload() end end)

local W=Lib:Window({Title="Defend Your Town",Subtitle="v1.0",DragStyle=1,ShowUserInfo=true,AcrylicBlur=false})
local TG=W:TabGroup()
local TCollect=TG:Tab({Name="Collect",Image="rbxassetid://10723345035"})
local TWave=TG:Tab({Name="Wave",Image="rbxassetid://10734943674"})
local TMisc=TG:Tab({Name="Misc",Image="rbxassetid://10734950309"})

local CL=TCollect:Section({Side="Left"})
CL:Header({Text="Instant Collect"})
CL:Toggle({Name="Auto Collect Coin",Default=e.coinOn,Callback=function(v)
	e.coinOn=v;if not v then setCoinRadius(COIN_DEF) end;sv()
end},"coinOn")
CL:Toggle({Name="Auto Collect Production",Default=e.prodOn,Callback=function(v)
	e.prodOn=v
	if not v and LP:GetAttribute("AutoCollectActive") then fire("ToggleAutoCollect") end
	sv()
end},"prodOn")
CL:Toggle({Name="Auto Open Chest",Default=e.chestOn,Callback=function(v) e.chestOn=v;sv() end},"chestOn")
CL:Header({Text="Rewards"})
CL:Toggle({Name="Auto Claim Quest",Default=e.questOn,Callback=function(v) e.questOn=v;sv() end},"questOn")
local CR=TCollect:Section({Side="Right"})
CR:Header({Text="Status"})
local statLbl=CR:Label({Text="idle"})

local WL=TWave:Section({Side="Left"})
WL:Header({Text="Goblin Raid"})
WL:Toggle({Name="Auto Start Wave",Default=e.startWaveOn,Callback=function(v) e.startWaveOn=v;sv() end},"startWaveOn")
WL:Toggle({Name="Auto Skip Wave",Default=e.skipWaveOn,Callback=function(v)
	e.skipWaveOn=v
	if not v and LP:GetAttribute("AutoSkipWave") then fire("ToggleAutoSkipWave") end
	sv()
end},"skipWaveOn")
WL:Label({Text="Skip has a 2s server cooldown between waves."})

local ML=TMisc:Section({Side="Left"})
ML:Header({Text="System"})
ML:Toggle({Name="Anti-AFK",Default=e.afkOn,Callback=function(v) e.afkOn=v;sv() end},"afkOn")
ML:Toggle({Name="Auto Reconnect",Default=e.recOn,Callback=function(v) e.recOn=v;sv() end},"recOn")
ML:Keybind({Name="Toggle UI",Blacklist=false,Default=Enum.KeyCode.RightShift,
	Callback=function() pcall(function() W:SetState(not W:GetState()) end) end},"DytUI")

task.spawn(function()
	while e.__DYT==G do
		pcall(function()
			statLbl:UpdateName(("Chests %d\nAutoCollect %s\nAutoWave %s  AutoSkip %s"):format(
				e.__chestCount or 0,
				tostring(LP:GetAttribute("AutoCollectActive")),
				tostring(LP:GetAttribute("AutoGoblinRaid")),
				tostring(LP:GetAttribute("AutoSkipWave"))))
		end)
		task.wait(1)
	end
end)

e.__DYTW=W
TCollect:Select()
print("[DYT] v1.0 OK")
