getgenv().__G=(getgenv().__G or 0)+1;local G=getgenv().__G
pcall(function() if getgenv().__W then getgenv().__W:Unload() end end)
local e=getgenv()
local myUID=tostring(math.random(1,2^30))
e.__tok=myUID  -- random UID; last script to start always wins
local PL=game:GetService("Players");local RS=game:GetService("ReplicatedStorage")
local VU=game:GetService("VirtualUser");local HS=game:GetService("HttpService")
local TSvc=game:GetService("TeleportService");local LP=PL.LocalPlayer
local R=RS:WaitForChild("Remotes")
local SAR=R:WaitForChild("SetAutoRoll");local GL=R:WaitForChild("GetLevel")
local GP=R:WaitForChild("GetPrestige");local PR=R:WaitForChild("PrestigeRequested")
local RCA=R:WaitForChild("ReportClickAttack");local GBS=R:WaitForChild("GetBossState")
local GDR=R:WaitForChild("GetDailyRewards");local CDR=R:WaitForChild("ClaimDailyReward")
local GOR=R:WaitForChild("GetOfflineRewards");local COR=R:WaitForChild("ClaimOfflineRewards")
local PD=require(RS.shared.Prestige.PrestigeData)
local LV=require(RS.shared.Levels.Levels);local SH=require(RS.shared.Shared)
local HR=require(RS.client.Heroes.HeroRender);local NW=require(RS.client.Network.Network)
local EN=require(RS.client.Enemies.Enemies)
local SF="RNGHeroesAutomation/state.json"
local SK={"aRoll","aPre","aClk","aSC","aAfk","aBoss","aRec","fSpt","bSpt","aDly","hGod","hSpd","hDmg","wSpd","wJmp","hDmgIgn","hSpdIgn"}
pcall(function() if not isfolder("RNGHeroesAutomation") then makefolder("RNGHeroesAutomation") end end)
local function sv() local d={} for _,k in ipairs(SK) do d[k]=e[k] end;pcall(function() writefile(SF,HS:JSONEncode(d)) end) end
pcall(function() local c=readfile(SF);local d=HS:JSONDecode(c);for _,k in ipairs(SK) do if d[k]~=nil and e[k]==nil then e[k]=d[k] end end end)
if e.aRoll==nil then e.aRoll=true end
if e.aAfk==nil then e.aAfk=true end
if e.aRec==nil then e.aRec=true end
if e.aDly==nil then e.aDly=true end
if e.hDmgIgn==nil then e.hDmgIgn="None" end
if e.hSpdIgn==nil then e.hSpdIgn="None" end
-- roll speed x1000
task.spawn(function()
    local ok,RV=pcall(function() return require(RS:WaitForChild("client"):WaitForChild("Rolling"):WaitForChild("RollingView")) end)
    if not ok then return end
    if not e.__ORV then e.__ORV=RV.PlayRoll end
    local o=e.__ORV
    RV.PlayRoll=function(c,h,sz,sp,...) local m=(type(sp)=="number"and sp>0)and sp or 1;return o(c,h,sz,m*1000,...) end
end)
-- anti-afk / reconnect (guarded)
if not e.__AFKh then e.__AFKh=true;LP.Idled:Connect(function() if e.aAfk then pcall(function() VU:CaptureController();VU:ClickButton2(Vector2.new()) end) end end) end
if not e.__RH then e.__RH=true;PL.PlayerRemoving:Connect(function(p) if p==LP and e.aRec then pcall(function() TSvc:Teleport(game.PlaceId,LP) end) end end) end
-- hero god mode
if not e.__OAD then e.__OAD=HR.ApplyLocalDamage end
HR.ApplyLocalDamage=function(a,b,c,d,...) if e.hGod then return end;return e.__OAD(a,b,c,d,...) end
if not e.__ONF then e.__ONF=NW.FireServer end
NW.FireServer=function(ev,...) if e.hGod and(ev=="ReportEnemyAttack"or ev=="ReportBossAoeHit")then local a={...};a[#a]=0;return e.__ONF(ev,table.unpack(a))end;return e.__ONF(ev,...) end
-- hero infinite damage (boss-ignore aware)
if not e.__OCA then e.__OCA=SH.Heroes.GetCombatATK end
SH.Heroes.GetCombatATK=function(...)
    if e.hDmg then
        if e.hDmgIgn=="Boss" and e.__BSA then return e.__OCA(...) end
        return 1e50
    end
    return e.__OCA(...)
end
-- hero speed + click boost (boss-ignore aware)
if not e.__OGS then e.__OGS=SH.GetStat end
SH.GetStat=function(n,...)
    if e.hSpd and n=="HeroAttackSpeed" then
        if e.hSpdIgn=="Boss" and e.__BSA then return e.__OGS(n,...) end
        return 1000
    end
    if (e.aClk or e.aSC) and n=="ClickAttackDpsFraction" then return 1000 end
    if (e.aClk or e.aSC) and n=="ClickAttackMaxPerSec" then return 1000 end
    return e.__OGS(n,...)
end
-- walk speed / jump loop
task.spawn(function()
    while e.__G==G do
        pcall(function()
            local ch=LP.Character;if not ch then return end
            local hm=ch:FindFirstChildOfClass("Humanoid");if not hm then return end
            if e.wSpd then hm.WalkSpeed=100 end
            if e.wJmp then hm.JumpPower=150 end
        end)
        task.wait(0.5)
    end
end)
-- auto roll
local function ar() pcall(function() SAR:FireServer(e.aRoll) end) end;ar()
-- KillAura: all enemies per round, 3Hz
e.__CC=e.__CC or 0
local function acKA()
    if not e.aClk then return end
    local ok,z=pcall(function() return EN.GetCurrentZone() end);if not ok or not z then return end
    local n=0;pcall(function()
        for s in EN.IterateZoneSlots(z) do
            if EN.IsAlive(z,s) and n<5 then
                local p;pcall(function() p=EN.GetPosition(z,s) end)
                pcall(function() EN.PlayHitFlash(z,s) end);pcall(function() EN.PlayHitBump(z,s) end)
                pcall(function() RCA:FireServer(z,s,p) end);e.__CC+=1;n+=1
            end
        end
    end)
end
task.spawn(function() while e.__G==G do acKA();task.wait(1/3) end end)
-- Single-target: round-robin, 14Hz
e.__CC2=e.__CC2 or 0;local ci=0
local function acST()
    if not e.aSC then return end
    local ok,z=pcall(function() return EN.GetCurrentZone() end);if not ok or not z then return end
    local t={};pcall(function() for s in EN.IterateZoneSlots(z) do if EN.IsAlive(z,s) then table.insert(t,s) end end end);if #t==0 then return end
    ci=(ci%#t)+1;local sl=t[ci];local p;pcall(function() p=EN.GetPosition(z,sl) end)
    pcall(function() EN.PlayHitFlash(z,sl) end);pcall(function() EN.PlayHitBump(z,sl) end)
    pcall(function() RCA:FireServer(z,sl,p) end);e.__CC2+=1
end
task.spawn(function() while e.__G==G do acST();task.wait(1/14) end end)
-- spots
local function hh() return LP.Character and LP.Character:FindFirstChild("HumanoidRootPart") end
local function c2t(cf) local p=cf.Position;local l=cf.LookVector;return{px=p.X,py=p.Y,pz=p.Z,lx=l.X,ly=l.Y,lz=l.Z} end
local function t2c(t) if not t then return nil end;local p=Vector3.new(t.px,t.py,t.pz);local l=Vector3.new(t.lx or 0,t.ly or 0,t.lz or -1);return CFrame.new(p,p+l) end
local function sfarm() local h=hh();if not h then return false end;e.fSpt=c2t(h.CFrame);sv();return true end
local function sboss() local h=hh();if not h then return false end;e.bSpt=c2t(h.CFrame);sv();return true end
-- auto boss  (__BSA = boss state active, always updated regardless of aBoss toggle)
e.__IBA=e.__IBA or false;e.__BSA=e.__BSA or false;local bStat="Waiting..."
local function chkBoss()
    local ok,st=pcall(function() return GBS:InvokeServer() end)
    e.__BSA=(ok and st~=nil)          -- track boss state for ignore hooks
    if not e.aBoss then bStat="Off";return end
    if not ok then bStat="Error";return end
    local a=e.__BSA
    if a and not e.__IBA then
        local h=hh();if h then e.__BRC=h.CFrame end
        local bh=hh();if bh then local s=t2c(e.bSpt);if s then bh.CFrame=s else local wb=workspace:FindFirstChild("Worldboss");local sp=wb and wb:FindFirstChild("PlayerSpawn");if sp and sp:IsA("BasePart") then bh.CFrame=sp.CFrame*CFrame.new(0,sp.Size.Y/2+3,0) end end end
        e.__IBA=true;bStat="Warped to boss!"
    elseif not a and e.__IBA then
        local h=hh();local ret=t2c(e.fSpt) or e.__BRC;if h and ret then h.CFrame=ret end;e.__IBA=false;bStat="Boss done."
    elseif a then bStat="In arena..."
    else bStat="Waiting..." end
end
-- prestige + xp (combined, 1 GL call)
local _xpLast,_xpT=nil,nil
local function fmt(n)
    if n>=1e9 then return string.format("%.2fB",n/1e9)
    elseif n>=1e6 then return string.format("%.1fM",n/1e6)
    elseif n>=1e3 then return string.format("%.0fK",n/1e3)
    else return tostring(math.floor(n)) end
end
local function chkAll(preCb,lvCb,xpCb,pEtaCb)
    local ok1,ps=pcall(function() return GP:InvokeServer() end)
    local ok2,ld=pcall(function() return GL:InvokeServer() end)
    if not(ok1 and ok2 and ps and ld) then return end
    local cr=ps.current;local idx=table.find(PD.Order,cr);local nx=idx and PD.Order[idx+1]
    local need=math.huge
    if nx then
        local nd=PD.Ranks[nx];need=nd and nd.RequiredLevel or math.huge;local rem=need-ld.level
        if preCb then preCb((rem<=0 and"✓ READY! "or("Lv "..ld.level.."/"..need.." | "))..cr.." → "..(nd and nd.DisplayName or nx)) end
        if e.aPre and rem<=0 then pcall(function() PR:FireServer() end) end
    else
        if preCb then preCb("Max prestige: "..cr) end
    end
    local frac=math.floor(ld.xp/ld.required*100)
    if lvCb then lvCb("Lv "..ld.level.."  |  "..fmt(ld.xp).." / "..fmt(ld.required).."  ("..frac.."%)") end
    local now=os.clock();local remXP=ld.required-ld.xp
    local rate=0
    local etaStr="Rem: "..fmt(remXP).." XP"
    if _xpLast and _xpT then
        local dt=now-_xpT
        if dt>0 and ld.xp>_xpLast then
            rate=(ld.xp-_xpLast)/dt
            local eta=rate>0 and remXP/rate or math.huge
            etaStr=etaStr.."  |  "..fmt(rate*60).."/min"
            if eta<86400 then
                local m=math.floor(eta/60);local s=math.floor(eta%60)
                etaStr=etaStr.."  ETA: "..m.."m "..s.."s"
            end
        end
    end
    _xpLast=ld.xp;_xpT=now
    if xpCb then xpCb(etaStr) end
    -- prestige ETA: sum XP across each remaining level up to prestige level
    if pEtaCb then
        if need==math.huge then pEtaCb("Prestige ETA: Max rank")
        elseif need<=ld.level then pEtaCb("Prestige ETA: ✓ Ready!")
        else
            local tot=ld.required-ld.xp  -- XP left in current level
            pcall(function()
                for lv=ld.level+1,need-1 do
                    tot=tot+(LV.RequiredXPForLevel(lv) or 0)
                end
            end)
            if rate>0 then
                local eta=tot/rate
                local h=math.floor(eta/3600)
                local m=math.floor((eta%3600)/60)
                local s=math.floor(eta%60)
                local ts=h>0 and(h.."h "..m.."m")or(m>0 and(m.."m "..s.."s")or(s.."s"))
                pEtaCb("Prestige ETA: "..ts.."  ("..fmt(tot).." XP left)")
            else
                pEtaCb("Prestige ETA: "..fmt(tot).." XP  (no rate yet)")
            end
        end
    end
end
-- daily / offline
local function chkDly() if not e.aDly then return end;pcall(function() local d=GDR:InvokeServer();if d and d.canClaim then CDR:InvokeServer() end end) end
if not e.__ORC then e.__ORC=true;task.spawn(function() pcall(function() local d=GOR:InvokeServer();if d then COR:InvokeServer() end end) end) end
-- cache MacLib; re-runs skip HttpGet but still yield 1 frame so any
-- queued instance can start, increment __G, and overwrite __tok first
print("[RNG] Hooks OK. Loading UI...")
if not e.__LIB then
    local ok,lib=pcall(function()
        return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
    end)
    if not ok or not lib then print("[RNG] MacLib failed") return end
    e.__LIB=lib
end
local Lib=e.__LIB
task.wait()  -- deliberate 1-frame yield: lets queued instances start & claim token
if e.__G~=G or e.__tok~=myUID then print("[RNG] Aborted (newer instance)") return end
pcall(function() if e.__W then e.__W:Unload() end end)
local W=Lib:Window({Title="RNG Heroes",Subtitle="v5.11",DragStyle=1,ShowUserInfo=true,AcrylicBlur=false})
local TG=W:TabGroup()
local TA =TG:Tab({Name="Auto",    Image="rbxassetid://10723343321"})
local TPr=TG:Tab({Name="Prestige",Image="rbxassetid://10734963191"})
local TH =TG:Tab({Name="Heroes",  Image="rbxassetid://6022668955"})
local TB =TG:Tab({Name="Boss",    Image="rbxassetid://10734975692"})
local TM =TG:Tab({Name="Misc",    Image="rbxassetid://10723343321"})
-- Auto tab
local AL=TA:Section({Side="Left"})
AL:Header({Text="Roll"})
AL:Toggle({Name="Auto Roll",Default=e.aRoll,Callback=function(v) e.aRoll=v;ar();sv() end},"aRoll")
AL:Header({Text="Daily & Offline"})
AL:Toggle({Name="Auto Daily",Default=e.aDly,Callback=function(v) e.aDly=v;sv() end},"aDly")
local AR=TA:Section({Side="Right"})
AR:Header({Text="KillAura  (all mobs, 3 Hz)"})
AR:Toggle({Name="KillAura Click",Default=e.aClk,Callback=function(v) e.aClk=v;sv() end},"aClk")
local kaLbl=AR:Label({Text="Hits: 0"})
AR:Header({Text="Single Target  (round-robin, 14 Hz)"})
AR:Toggle({Name="Auto Click",Default=e.aSC,Callback=function(v) e.aSC=v;sv() end},"aSC")
local stLbl=AR:Label({Text="Hits: 0"})
-- Prestige tab
local PrL=TPr:Section({Side="Left"})
PrL:Header({Text="Auto Prestige"})
PrL:Toggle({Name="Auto Prestige",Default=e.aPre,Callback=function(v) e.aPre=v;sv() end},"aPre")
local preLbl=PrL:Label({Text="Checking..."})
local PrR=TPr:Section({Side="Right"})
PrR:Header({Text="Level Progress"})
local lvLbl=PrR:Label({Text="Lv: ..."})
local xpLbl=PrR:Label({Text="Rem: ..."})
PrR:Header({Text="Next Prestige ETA"})
local pEtaLbl=PrR:Label({Text="Calculating..."})
-- Heroes tab
local HL=TH:Section({Side="Left"})
HL:Header({Text="Defense"})
HL:Toggle({Name="Infinite Health",Default=e.hGod,Callback=function(v) e.hGod=v;sv() end},"hGod")
HL:Header({Text="Offense"})
HL:Toggle({Name="Infinite Damage",Default=e.hDmg,Callback=function(v) e.hDmg=v;sv() end},"hDmg")
HL:Dropdown({Name="  Ignore DMG",Options={"None","Boss"},Default=e.hDmgIgn,Callback=function(v) e.hDmgIgn=v;sv() end},"hDmgIgn")
HL:Toggle({Name="Atk Speed x1000",Default=e.hSpd,Callback=function(v) e.hSpd=v;sv() end},"hSpd")
HL:Dropdown({Name="  Ignore ATK",Options={"None","Boss"},Default=e.hSpdIgn,Callback=function(v) e.hSpdIgn=v;sv() end},"hSpdIgn")
local HR_=TH:Section({Side="Right"})
local heroLbl=HR_:Label({Text="HP:ok  DMG:ok  ATK:ok"})
local bsLbl=HR_:Label({Text="Boss: -"})
-- Boss tab
local BL=TB:Section({Side="Left"})
BL:Header({Text="Auto Boss"})
BL:Toggle({Name="Auto Boss",Default=e.aBoss,Callback=function(v) e.aBoss=v;sv() end},"aBoss")
local bossLbl=BL:Label({Text="Waiting..."})
local BR=TB:Section({Side="Right"})
BR:Header({Text="Farm Spot"})
local fLbl=BR:Label({Text=e.fSpt and"✓ Saved"or"Not set"})
BR:Button({Name="Save Farm",Callback=function() if sfarm() then pcall(function() fLbl:UpdateName("✓ Saved") end) end end})
BR:Button({Name="TP to Farm",Callback=function() local h=hh();if h and e.fSpt then h.CFrame=t2c(e.fSpt) end end})
BR:Header({Text="Boss Spot"})
local bpLbl=BR:Label({Text=e.bSpt and"✓ Saved"or"Not set"})
BR:Button({Name="Save Boss",Callback=function() if sboss() then pcall(function() bpLbl:UpdateName("✓ Saved") end) end end})
BR:Button({Name="TP to Boss",Callback=function() local h=hh();if h and e.bSpt then h.CFrame=t2c(e.bSpt) end end})
-- Misc tab
local MsL=TM:Section({Side="Left"})
MsL:Header({Text="System"})
MsL:Toggle({Name="Anti-AFK",Default=e.aAfk,Callback=function(v) e.aAfk=v;sv() end},"aAfk")
MsL:Toggle({Name="Auto Reconnect",Default=e.aRec,Callback=function(v) e.aRec=v;sv() end},"aRec")
MsL:Keybind({Name="Toggle UI",Blacklist=false,Default=Enum.KeyCode.RightShift,Callback=function() pcall(function() W:SetState(not W:GetState()) end) end},"RngUI")
local MsR=TM:Section({Side="Right"})
MsR:Header({Text="Player Speed"})
MsR:Toggle({Name="Walk Speed x6  (100)",Default=e.wSpd,Callback=function(v) e.wSpd=v;sv() end},"wSpd")
MsR:Toggle({Name="High Jump  (150)",Default=e.wJmp,Callback=function(v) e.wJmp=v;sv() end},"wJmp")
-- update loop
task.spawn(function()
    while e.__G==G do
        pcall(chkBoss);pcall(chkDly)
        pcall(chkAll,
            function(t) pcall(function() preLbl:UpdateName(t) end) end,
            function(t) pcall(function() lvLbl:UpdateName(t) end) end,
            function(t) pcall(function() xpLbl:UpdateName(t) end) end,
            function(t) pcall(function() pEtaLbl:UpdateName(t) end) end)
        pcall(function() kaLbl:UpdateName("Hits: "..e.__CC) end)
        pcall(function() stLbl:UpdateName("Hits: "..e.__CC2) end)
        pcall(function() bossLbl:UpdateName(bStat) end)
        -- hero status (SKIP = suppressed by boss-ignore)
        local hg=e.hGod and"GOD"or"ok"
        local hd=e.hDmg and((e.hDmgIgn=="Boss"and e.__BSA)and"SKIP"or"INF")or"ok"
        local hs=e.hSpd and((e.hSpdIgn=="Boss"and e.__BSA)and"SKIP"or"x1k")or"ok"
        pcall(function() heroLbl:UpdateName("HP:"..hg.."  DMG:"..hd.."  ATK:"..hs) end)
        pcall(function() bsLbl:UpdateName("Boss: "..(e.__BSA and"ACTIVE"or"none")) end)
        task.wait(3)
    end
end)
e.__W=W
TA:Select()
print("[RNG] v5.11 OK")
