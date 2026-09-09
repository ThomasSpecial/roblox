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
local SK={"coinOn","prodOn","chestOn","questOn","startWaveOn","skipWaveOn","shieldOn",
	"buyOn","sellOn","traderOn","afkOn","recOn"}
local SKL={"buyCats","sellRars"}
local COIN_BIG=400
local COIN_DEF=25
local RARITIES={"Common","Uncommon","Rare","Epic","Mythic","Legendary","Void","Limited","Secret"}
local BUY_CATS={"Fighter","Defense","Production","Walls"}
local UICAT_TO_TYPE={Fighter="Warrior",Defense="Defense",Production="Resource",Walls="Wall"}

-- ===== game hooks =====
local EMC;pcall(function() EMC=require(RS.Modules.EventManagerClient) end)
local FMC;pcall(function() FMC=require(RS.Modules.FunctionManagerClient) end)
local GU;pcall(function() GU=require(RS.Modules.GameUtility) end)
local function fire(name,...)
	if not EMC then return end
	local a={...}
	pcall(function() EMC.FireServer(name,table.unpack(a)) end)
end
local function invoke(name,...)
	if not FMC then return end
	local a={...}
	local ok,res=pcall(function() return FMC.InvokeServer(name,table.unpack(a)) end)
	if ok then return res end
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
local function sv()
	local d={}
	for _,k in ipairs(SK) do d[k]=e[k] end
	for _,k in ipairs(SKL) do d[k]=e[k] end
	pcall(function() writefile(SF,HS:JSONEncode(d)) end)
end
pcall(function()
	local d=HS:JSONDecode(readfile(SF))
	for _,k in ipairs(SK) do if type(d[k])=="boolean" and e[k]==nil then e[k]=d[k] end end
	for _,k in ipairs(SKL) do if type(d[k])=="table" and e[k]==nil then e[k]=d[k] end end
end)
if e.afkOn==nil then e.afkOn=true end
if e.recOn==nil then e.recOn=true end
for _,k in ipairs(SK) do if e[k]==nil then e[k]=false end end
if type(e.buyCats)~="table" then e.buyCats={} end
if type(e.sellRars)~="table" then e.sellRars={} end
e.__chestSeen=e.__chestSeen or {}
e.__chestCount=e.__chestCount or 0
e.__lastSkip=0
e.__bought=e.__bought or 0
e.__sold=e.__sold or 0

-- ===== collect / wave / shield loops =====
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
	for _,d in ipairs(bin:GetChildren()) do
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
			if not LP:GetAttribute("RaidActive") then fire("StartGoblinRaid") end
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
local function myPlot()
	local plots=workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Plots")
	if not plots then return end
	local id=tostring(LP.UserId)
	for _,p in ipairs(plots:GetChildren()) do
		if tostring(p:GetAttribute("Owner"))==id then return p end
	end
end
task.spawn(function()
	while e.__DYT==G do
		if e.shieldOn then
			local plot=myPlot()
			local st=plot and plot:GetAttribute("ShieldState")
			local dur=LP:GetAttribute("TownShieldDuration") or 0
			local cd=(plot and plot:GetAttribute("ShieldCooldown")) or 0
			if not LP:GetAttribute("IsRaided") and dur<=0 and cd<=0 and (st==nil or st=="Ready") then
				fire("ActivateShield")
			end
		end
		task.wait(3)
	end
end)

-- ===== Auto Buy (Game Shop stock, by category) =====
local function autoBuy()
	local gs=LP.PlayerGui:FindFirstChild("GameShop")
	if not gs then return end
	local want={}
	for _,c in ipairs(e.buyCats) do want[UICAT_TO_TYPE[c] or c]=true end
	if not next(want) then return end
	local cash=LP:GetAttribute("Cash") or 0
	for _,d in ipairs(gs:GetDescendants()) do
		if not e.buyOn or e.__DYT~=G then return end
		local id=d:GetAttribute("ID")
		local typ=d:GetAttribute("Type")
		local price=tonumber(d:GetAttribute("Price"))
		if id and typ and price and typ~="Product" and want[typ] and cash>=price then
			fire("BuyFromGameShopStock",{Type=typ,ID=id})
			e.__bought=(e.__bought or 0)+1
			cash=cash-price
			task.wait(0.3)
		end
	end
end

-- ===== Auto Sell (inventory, by rarity) =====
local function autoSell()
	if not (FMC and GU) then return end
	local inv=invoke("GetInventoryData")
	if type(inv)~="table" then return end
	local locked=invoke("GetData","LockedSellItems");if type(locked)~="table" then locked={} end
	local want={}
	for _,r in ipairs(e.sellRars) do want[r]=true end
	if not next(want) then return end
	for cat,items in pairs(inv) do
		if type(items)=="table" then
			for id,dat in pairs(items) do
				if not e.sellOn or e.__DYT~=G then return end
				local amt=tonumber((type(dat)=="table" and dat.Amount) or dat) or 0
				if amt>0 and not locked[id] then
					local m=GU.GetItemByID(cat,id)
					local rar=m and m:GetAttribute("Rarity")
					if rar and want[rar] then
						fire("SellItem",{Type=cat,ID=id},"All")
						e.__sold=(e.__sold or 0)+amt
						task.wait(0.12)
					end
				end
			end
		end
	end
end

-- ===== Auto Buy Trader (Black Market / Shop Event -- buys with Gems) =====
local function autoTrader()
	if not FMC then return end
	local bm=LP.PlayerGui:FindFirstChild("BlackMarket")
	if not bm then return end
	local seen={}
	for _,d in ipairs(bm:GetDescendants()) do
		if not e.traderOn or e.__DYT~=G then return end
		local id=d:GetAttribute("ID")
		if id and not seen[id] and (d:GetAttribute("Price") or d:GetAttribute("Cost") or d:GetAttribute("GemCost") or d:GetAttribute("GemPrice")) then
			seen[id]=true
			invoke("BuyShopEventItem",id)
			task.wait(0.4)
		end
	end
end

task.spawn(function()
	while e.__DYT==G do
		if e.buyOn then pcall(autoBuy) end
		if e.sellOn then pcall(autoSell) end
		if e.traderOn then pcall(autoTrader) end
		task.wait(3)
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

local function listFromSet(sel)
	local t={} for k,v in pairs(sel) do if v==true or v==k then t[#t+1]=k end end
	table.sort(t);return t
end

local W=Lib:Window({Title="Defend Your Town",Subtitle="v2.0",DragStyle=1,ShowUserInfo=true,AcrylicBlur=false})
local TG=W:TabGroup()
local TCollect=TG:Tab({Name="Collect",Image="rbxassetid://10723345035"})
local TShop=TG:Tab({Name="Shop",Image="rbxassetid://10723415576"})
local TWave=TG:Tab({Name="Wave",Image="rbxassetid://10734943674"})
local TMisc=TG:Tab({Name="Misc",Image="rbxassetid://10734950309"})

-- Collect
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

-- Shop
local SHL=TShop:Section({Side="Left"})
SHL:Header({Text="Auto Buy  (Game Shop, uses Cash)"})
SHL:Toggle({Name="Enable Auto Buy",Default=e.buyOn,Callback=function(v) e.buyOn=v;sv() end},"buyOn")
SHL:Dropdown({Name="Categories",Multi=true,Options=BUY_CATS,Default=e.buyCats,
	Callback=function(sel) e.buyCats=listFromSet(sel);sv() end},"buyCats")
SHL:Header({Text="Auto Sell  (Inventory, by Rarity)"})
SHL:Toggle({Name="Enable Auto Sell",Default=e.sellOn,Callback=function(v) e.sellOn=v;sv() end},"sellOn")
SHL:Dropdown({Name="Rarities",Multi=true,Options=RARITIES,Default=e.sellRars,
	Callback=function(sel) e.sellRars=listFromSet(sel);sv() end},"sellRars")
local SHR=TShop:Section({Side="Right"})
SHR:Header({Text="Trader"})
SHR:Toggle({Name="Auto Buy Trader",Default=e.traderOn,Callback=function(v) e.traderOn=v;sv() end},"traderOn")
SHR:Label({Text="Trader (Black Market) shows up periodically and buys with Gems -- runs only while it's open. 10M Shield is a Robux product; Unlimited Builder / x10 Build Speed / x10 Money are server-authoritative and can't be done client-side."})
local shopLbl=SHR:Label({Text="bought 0  sold 0"})

-- Wave
local WL=TWave:Section({Side="Left"})
WL:Header({Text="Goblin Raid"})
WL:Toggle({Name="Auto Start Wave",Default=e.startWaveOn,Callback=function(v) e.startWaveOn=v;sv() end},"startWaveOn")
WL:Toggle({Name="Auto Skip Wave",Default=e.skipWaveOn,Callback=function(v)
	e.skipWaveOn=v
	if not v and LP:GetAttribute("AutoSkipWave") then fire("ToggleAutoSkipWave") end
	sv()
end},"skipWaveOn")
WL:Header({Text="Town Protection"})
WL:Toggle({Name="Auto Shield (1M / free)",Default=e.shieldOn,Callback=function(v) e.shieldOn=v;sv() end},"shieldOn")

-- Misc
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
		pcall(function() shopLbl:UpdateName(("bought %d  sold %d"):format(e.__bought or 0,e.__sold or 0)) end)
		task.wait(1)
	end
end)

e.__DYTW=W
TCollect:Select()
print("[DYT] v2.0 OK")
