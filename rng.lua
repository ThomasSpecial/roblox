getgenv().__G=(getgenv().__G or 0)+1;local G=getgenv().__G
pcall(function() if getgenv().__W then getgenv().__W:Unload() end end)
local e=getgenv()
local myUID=tostring(math.random(1,2^30))
e.__tok=myUID  -- random UID; last script to start always wins
local PL=game:GetService("Players");local RS=game:GetService("ReplicatedStorage")
local VU=game:GetService("VirtualUser");local HS=game:GetService("HttpService")
local TSvc=game:GetService("TeleportService");local LP=PL.LocalPlayer
-- Remotes (WaitForChild with timeouts — fast-fail if game is updating, no infinite hang)
local R=RS:WaitForChild("Remotes",10)
if not R then print("[RNG] ERROR: Remotes not found — re-run script in a few seconds"); return end
local SAR=R:WaitForChild("SetAutoRoll",5)
local GL =R:WaitForChild("GetLevel",5)
local GP =R:WaitForChild("GetPrestige",5)
local PR =R:WaitForChild("PrestigeRequested",5)
local RCA=R:WaitForChild("ReportClickAttack",5)
local GBS=R:WaitForChild("GetBossState",5)
local GDR=R:WaitForChild("GetDailyRewards",5)
local CDR=R:WaitForChild("ClaimDailyReward",5)
local GOR=R:WaitForChild("GetOfflineRewards",5)
local COR=R:WaitForChild("ClaimOfflineRewards",5)
local PU =R:WaitForChild("PurchaseUpgrade",5)
-- Shared/client modules: loaded via _safeReq after it is defined below
local PD,LV,SH,HR,NW,EN,UD,UP
-- Index Calculator: FusionPackage (pcall-safe; nil if unavailable)
local function _safeReq(root,...)
    local obj=root
    for _,n in ipairs({...}) do
        local ok,child=pcall(function() return obj:FindFirstChild(n) end)
        if not ok or not child then return nil end
        obj=child
    end
    local ok2,m=pcall(require,obj); return ok2 and m or nil
end
local _FPFusion=_safeReq(RS,"FusionPackage","Fusion")
local _FPDeps  =_safeReq(RS,"FusionPackage","Dependencies")
local _BnrInfo =_safeReq(RS,"Shared","Information","BannerInfo")
local function fpPeek(s)
    if not _FPFusion or not s then return nil end
    local ok,v=pcall(_FPFusion.peek,s); return ok and v or nil
end
-- Load client/shared modules via _safeReq (nil-safe if structure changes)
PD=_safeReq(RS,"shared","Prestige","PrestigeData")
LV=_safeReq(RS,"shared","Levels","Levels")
SH=_safeReq(RS,"shared","Shared")
HR=_safeReq(RS,"client","Heroes","HeroRender")
NW=_safeReq(RS,"client","Network","Network")
EN=_safeReq(RS,"client","Enemies","Enemies")
UD=_safeReq(RS,"shared","Upgrades","UpgradeData")
UP=_safeReq(RS,"client","Upgrades","Upgrades")
local SF="RNGHeroesAutomation/state.json"
local SK={"aRoll","aPre","aClk","aSC","aAfk","aBoss","aRec","fSpt","bSpt","aDly","hGod","hSpd","hDmg","wSpd","wJmp","hDmgIgn","hSpdIgn","lHop","lHopMin","privCode","preUpgQ"}
pcall(function() if not isfolder("RNGHeroesAutomation") then makefolder("RNGHeroesAutomation") end end)
local function sv() local d={} for _,k in ipairs(SK) do d[k]=e[k] end;pcall(function() writefile(SF,HS:JSONEncode(d)) end) end
pcall(function() local c=readfile(SF);local d=HS:JSONDecode(c);for _,k in ipairs(SK) do if d[k]~=nil and e[k]==nil then e[k]=d[k] end end end)
if e.aRoll==nil then e.aRoll=true end
if e.aAfk==nil then e.aAfk=true end
if e.aRec==nil then e.aRec=true end
if e.aDly==nil then e.aDly=true end
if e.hDmgIgn==nil then e.hDmgIgn="None" end
if e.hSpdIgn==nil then e.hSpdIgn="None" end
if e.lHop==nil then e.lHop=false end
if e.lHopMin==nil then e.lHopMin=2 end
if e.privCode==nil then e.privCode="" end
if e.preUpgQ==nil then e.preUpgQ={} end
-- pre-prestige upgrade helpers
local function ugGetOwned()
    local t={}
    pcall(function() if UP then t=UP.GetOwned() end end)
    return t
end
local function ugGetGold()
    local g=0;pcall(function()
        local c=NW.InvokeServer("GetCurrencies")
        g=(c and c.balances and c.balances.Gold) or 0
    end);return g
end
local function ugCost(id) if not UD then return 0 end;local d=UD[id];return(d and d.Cost)or 0 end
local function ugQueueLabel()
    if not e.preUpgQ or #e.preUpgQ==0 then return "Queue: (empty — prestige freely)" end
    local parts={}
    for i,v in ipairs(e.preUpgQ) do parts[i]=i.."."..v end
    return "Queue: "..table.concat(parts," → ")
end
-- build sorted list of unowned upgrades; returns {{id,name,cost},...}
local function ugUnownedList()
    if not UD then return {} end
    local owned=ugGetOwned()
    local t={}
    for id,data in pairs(UD) do
        if type(data)=="table" and data.Name and data.Cost and not owned[id] then
            table.insert(t,{id=id,name=data.Name,cost=data.Cost})
        end
    end
    table.sort(t,function(a,b) return a.cost<b.cost end)
    return t
end
-- Index Calculator: load all rollable heroes (no Exclusive), check inventory,
-- compute size probs + per-rarity Manual Luck (LuckCap) recommendations
local function ixLoadData()
    local HeroData=_safeReq(RS,"shared","Heroes","HeroData")
    if not HeroData or not SH then return nil end
    local inv; pcall(function() inv=NW.InvokeServer("GetInventory") end)
    if not inv then return nil end
    local invH=inv.Heroes or {}
    local owned=ugGetOwned()
    -- SIZE LUCK: base chances from upgrades × all size-luck multipliers
    local bH=SH.GetStat("SizeChance_Huge",     owned,{}) or 0
    local bG=SH.GetStat("SizeChance_Giant",    owned,{}) or 0
    local bC=SH.GetStat("SizeChance_Colossal", owned,{}) or 0
    local sLk=LP:GetAttribute("ServerLuckMul")     or 1
    local iLk=LP:GetAttribute("IndexLuckMul")      or 1
    local pLk=LP:GetAttribute("PotionSizeLuckMul") or 1
    local eLk=LP:GetAttribute("EventLuckMul")      or 1
    local totSzLk=sLk*iLk*pLk*eLk
    local eH,eG,eC=bH*totSzLk,bG*totSzLk,bC*totSzLk
    local eSum=eH+eG+eC; local den=eSum>1 and eSum or 1
    local pN=math.max(0,1-eSum/den); local pH=eH/den; local pG=eG/den; local pC=eC/den
    -- UNIT LUCK: current Manual Luck (LuckCap) setting from game Settings
    local curLuckCap=false  -- false = MAX (no cap)
    pcall(function()
        local SET=_safeReq(RS,"client","Settings","Settings")
        if SET and SET.GetSettings then
            local s=SET.GetSettings(); curLuckCap=(s and s.LuckCap) or false
        end
    end)
    -- Compact number formatter (defined here because fmt is declared later in file)
    local function fmtN(n)
        if n==false then return "MAX" end
        if n>=1e15 then return string.format("%.2fQ",n/1e15)
        elseif n>=1e12 then return string.format("%.2fT",n/1e12)
        elseif n>=1e9  then return string.format("%.2fB",n/1e9)
        elseif n>=1e6  then return string.format("%.1fM",n/1e6)
        elseif n>=1e3  then return string.format("%.0fK",n/1e3)
        else return tostring(math.floor(n)) end
    end
    -- Optimal LuckCap per rarity: derived from BuildDropTable ladder conditionals
    -- At this cap the units of that rarity have peak drop probability
    local RARITY_ORDER={"Rare","Epic","Legendary","Mythic","Divine","Eternal","Void","Genesis"}
    local RARITY_CAP={
        Rare=3, Epic=148, Legendary=11954, Mythic=2561846,
        Divine=1793292718, Eternal=12809233707378,
        Void=1.79e18, Genesis=false,  -- Genesis = MAX (no cap needed)
    }
    -- All rollable heroes (exclude Exclusive)
    local totW=0; local heroes={}
    for name,d in pairs(HeroData) do
        if d.Rarity~="Exclusive" and d.Weight and d.Weight>0 then
            totW=totW+d.Weight
            table.insert(heroes,{name=name,weight=d.Weight,rarity=d.Rarity or "?"})
        end
    end
    if totW==0 then return nil end
    -- Missing Index entries per size
    local SZLIST={"Normal","Huge","Giant","Colossal"}
    local miss={Normal={},Huge={},Giant={},Colossal={}}
    local tot={Normal=0,Huge=0,Giant=0,Colossal=0}
    for _,h in ipairs(heroes) do
        local hi=invH[h.name]
        for _,sz in ipairs(SZLIST) do
            tot[sz]=tot[sz]+1
            if not(hi and hi.Sizes and hi.Sizes[sz]) then
                table.insert(miss[sz],{name=h.name,weight=h.weight,rarity=h.rarity})
            end
        end
    end
    -- Get player's approximate resolved luck (to know if cap is even reachable)
    local resolvedLuck=2.75e12  -- fallback ~2.75T (typical for high-level players)
    pcall(function()
        local HM=_safeReq(RS,"shared","Heroes","Heroes")
        if not HM or not HM.ResolveLuck then return end
        local lv; pcall(function() lv=NW.InvokeServer("GetLevel") end)
        local ps; pcall(function() ps=NW.InvokeServer("GetPrestige") end)
        if not lv or not ps then return end
        -- multiplierChain = sLk (server luck affects unit luck) × eLk (event)
        local unitMul=sLk*(eLk or 1)
        local r=HM.ResolveLuck(owned,ps.current,lv.level,0,unitMul,nil)
        if r and r>0 then resolvedLuck=r end
    end)
    -- effective cap shown to user: if RARITY_CAP[r] >= resolvedLuck, capping has no effect → show MAX
    local function effectiveCap(r)
        local c=RARITY_CAP[r]
        if c==false then return false end          -- Genesis → MAX
        if c>=resolvedLuck then return false end   -- cap higher than current luck → MAX
        return c
    end
    -- Group missing units by rarity for EACH size
    local function groupByRar(szList)
        local byRar={}
        for _,r in ipairs(RARITY_ORDER) do byRar[r]={} end
        for _,h in ipairs(szList) do
            local r=h.rarity
            if not byRar[r] then byRar[r]={} end
            table.insert(byRar[r],h)
        end
        return byRar
    end
    local missNByRar=groupByRar(miss.Normal)
    local missHByRar=groupByRar(miss.Huge)
    local missGByRar=groupByRar(miss.Giant)
    local missCByRar=groupByRar(miss.Colossal)
    -- Primary recommendation for Normal: lowest rarity with missing units
    local recRarity=nil; local recCap=false; local recCount=0
    for _,r in ipairs(RARITY_ORDER) do
        if missNByRar[r] and #missNByRar[r]>0 then
            recRarity=r; recCap=effectiveCap(r); recCount=#missNByRar[r]; break
        end
    end
    local recStr
    if #miss.Normal==0 then
        recStr="Normal ✓ complete!  See Huge/Giant/Colossal below"
    elseif recRarity then
        recStr=string.format("Normal: Set Manual Luck → %s  (%s, %d missing)",
            fmtN(recCap), recRarity, recCount)
    else
        recStr="—"
    end
    return {
        heroCount=#heroes, totW=totW,
        miss=miss, tot=tot,
        probs={N=pN,H=pH,G=pG,C=pC},
        szLk={s=sLk,i=iLk,p=pLk,e=eLk,tot=totSzLk},
        curLuckCap=curLuckCap, resolvedLuck=resolvedLuck,
        RARITY_ORDER=RARITY_ORDER, RARITY_CAP=RARITY_CAP,
        missNByRar=missNByRar, missHByRar=missHByRar,
        missGByRar=missGByRar, missCByRar=missCByRar,
        recStr=recStr, recRarity=recRarity, recCap=recCap,
        fmtN=fmtN, effectiveCap=effectiveCap,
    }
end
-- roll speed x1000
task.spawn(function()
    local RV=_safeReq(RS,"Client","Rolling","RollingView")
           or _safeReq(RS,"client","Rolling","RollingView")
           or _safeReq(RS,"Nodes","Client","Rolling","RollingView")
    if not RV then return end
    if not e.__ORV then e.__ORV=RV.PlayRoll end
    local o=e.__ORV
    RV.PlayRoll=function(c,h,sz,sp,...) local m=(type(sp)=="number"and sp>0)and sp or 1;return o(c,h,sz,m*1000,...) end
end)
-- anti-afk / reconnect (guarded)
if not e.__AFKh then e.__AFKh=true;LP.Idled:Connect(function() if e.aAfk then pcall(function() VU:CaptureController();VU:ClickButton2(Vector2.new()) end) end end) end
if not e.__RH then e.__RH=true;PL.PlayerRemoving:Connect(function(p) if p==LP and e.aRec then pcall(function() TSvc:Teleport(game.PlaceId,LP) end) end end) end
-- hero god mode
if HR then
    if not e.__OAD then e.__OAD=HR.ApplyLocalDamage end
    HR.ApplyLocalDamage=function(a,b,c,d,...) if e.hGod then return end;return e.__OAD(a,b,c,d,...) end
end
if NW and NW.FireServer then
    if not e.__ONF then e.__ONF=NW.FireServer end
    NW.FireServer=function(ev,...) if e.hGod and(ev=="ReportEnemyAttack"or ev=="ReportBossAoeHit")then local a={...};a[#a]=0;return e.__ONF(ev,table.unpack(a))end;return e.__ONF(ev,...) end
end
-- hero infinite damage (boss-ignore aware)
if SH and SH.Heroes and SH.Heroes.GetCombatATK then
    if not e.__OCA then e.__OCA=SH.Heroes.GetCombatATK end
    SH.Heroes.GetCombatATK=function(...)
        if e.hDmg then
            if e.hDmgIgn=="Boss" and e.__BSA then return e.__OCA(...) end
            return 1e50
        end
        return e.__OCA(...)
    end
end
-- hero speed + click boost (boss-ignore aware)
if SH and SH.GetStat then
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
    if not e.aClk or not EN then return end
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
    if not e.aSC or not EN then return end
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
-- server hop: random public server
local function hopRandom()
    local ok,raw=pcall(function() return game:HttpGet("https://games.roblox.com/v1/games/"..game.PlaceId.."/servers/Public?sortOrder=Asc&limit=100") end)
    if not ok then return end
    local ok2,data=pcall(function() return HS:JSONDecode(raw) end)
    if not ok2 or not data or not data.data or #data.data==0 then return end
    local srv={}
    for _,s in ipairs(data.data) do if s.id~=game.JobId then table.insert(srv,s) end end
    if #srv==0 then srv=data.data end
    pcall(function() TSvc:TeleportToPlaceInstance(game.PlaceId,srv[math.random(1,#srv)].id,LP) end)
end
-- private server hop:
-- If input is a UUID job ID (36 chars with dashes) → TeleportToPlaceInstance directly
-- If input is a link code / full URL → clipboard fallback (can't resolve without auth)
local function isJobId(s) return #s==36 and s:match("^[%x%-]+$")~=nil end
local function hopPrivate(code, statusCb)
    if not code or code=="" then
        if statusCb then statusCb("⚠ Code not set") end;return
    end
    -- extract link code if full URL pasted
    local c=code:match("privateServerLinkCode=([%w_%-]+)") or code:gsub("%s+","")
    -- Method 1: c looks like a Job ID (UUID) → join directly
    if isJobId(c) then
        local ok,err=pcall(function() TSvc:TeleportToPlaceInstance(game.PlaceId,c,LP) end)
        if ok then
            if statusCb then statusCb("Teleporting to server...") end
        else
            if statusCb then statusCb("Teleport failed: "..tostring(err):sub(1,40)) end
        end
        return
    end
    -- Method 2: c is a link code → can't resolve to job ID without auth
    -- Best we can do: copy the private server URL to clipboard
    local url="https://www.roblox.com/games/"..game.PlaceId.."/game?privateServerLinkCode="..c
    pcall(function() setclipboard(url) end)
    if statusCb then statusCb("URL copied! Paste in browser to join") end
end
-- luck server hop: hop until ServerLuckMul >= lHopMin
-- uses attribute change signal for fast detection (no fixed 8s wait)
e.__lHopCount=e.__lHopCount or 0
task.spawn(function()
    if not e.lHop then return end
    e.__lHopCount=e.__lHopCount+1
    -- wait for server to set ServerLuckMul (signal-based, timeout 12s)
    local done=false
    local conn;pcall(function()
        conn=LP:GetAttributeChangedSignal("ServerLuckMul"):Connect(function() done=true end)
    end)
    if LP:GetAttribute("ServerLuckMul") then done=true end  -- already set
    local t0=tick()
    while not done and tick()-t0<12 and e.__G==G and e.lHop do task.wait(0.3) end
    pcall(function() if conn then conn:Disconnect() end end)
    if e.__G~=G or not e.lHop then return end
    local cur=LP:GetAttribute("ServerLuckMul") or 1
    local tgt=e.lHopMin or 2
    print("[RNG] LuckHop #"..e.__lHopCount..": x"..cur.." (want x"..tgt..")")
    if cur>=tgt then
        e.lHop=false;sv()
        e.__lHopResult="✓ Found x"..cur.." (after "..e.__lHopCount.." servers)"
        e.__lHopCount=0
        print("[RNG] LuckHop: done!")
    else
        task.wait(0.5);hopRandom()
    end
end)
-- auto boss  (__BSA = boss state active, always updated regardless of aBoss toggle)
e.__IBA=e.__IBA or false;e.__BSA=e.__BSA or false;local bStat="Waiting..."
local function chkBoss()
    local ok,st=pcall(function() return GBS:InvokeServer() end)
    e.__BSA=(ok and st~=nil)
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
local ugRefreshDD  -- forward-declared; defined after UI widgets are created
local ixRefreshLbls  -- forward-declared; defined after Index tab labels are created
local ixProgLbl,ixNormLbl,ixHugeLbl,ixGiantLbl,ixColosLbl,ixLuckLbl,ixProbLbl,ixRecLbl
local ixMissNLbl,ixMissHLbl,ixMissGLbl,ixMissCLbl
-- prestige + xp (combined, 1 GL call)
local _xpLast,_xpT=nil,nil
local function fmt(n)
    if n>=1e15 then return string.format("%.2fQ",n/1e15)
    elseif n>=1e12 then return string.format("%.2fT",n/1e12)
    elseif n>=1e9 then return string.format("%.2fB",n/1e9)
    elseif n>=1e6 then return string.format("%.1fM",n/1e6)
    elseif n>=1e3 then return string.format("%.0fK",n/1e3)
    else return tostring(math.floor(n)) end
end
local function chkAll(preCb,lvCb,xpCb,pEtaCb)
    -- GP/GL remotes return empty tables; use NW.InvokeServer wrapper instead
    local ok1,ps=pcall(function() return NW.InvokeServer("GetPrestige") end)
    local ok2,ld=pcall(function() return NW.InvokeServer("GetLevel") end)
    if not(ok1 and ok2 and ps and ld) then return end
    local cr=ps.current;local idx=PD and table.find(PD.Order,cr);local nx=idx and PD.Order[idx+1]
    local need=math.huge
    if nx then
        local nd=PD.Ranks[nx];need=nd and nd.RequiredLevel or math.huge;local rem=need-ld.level
        if preCb then preCb((rem<=0 and"✓ READY! "or("Lv "..ld.level.."/"..need.." | "))..cr.." → "..(nd and nd.DisplayName or nx)) end
        if e.aPre and rem<=0 then
            -- pre-prestige upgrade queue
            local doPrestige=true
            if e.preUpgQ and #e.preUpgQ>0 then
                local nextUpg=e.preUpgQ[1]
                local owned=ugGetOwned()
                if owned[nextUpg] then
                    -- already owned (bought manually) → pop and prestige
                    table.remove(e.preUpgQ,1);sv()
                    pcall(function() if e.__ugQLbl then e.__ugQLbl:UpdateName(ugQueueLabel()) end end)
                elseif ugCost(nextUpg)==0 then
                    -- unknown upgrade → pop silently
                    table.remove(e.preUpgQ,1);sv()
                else
                    local cost=ugCost(nextUpg)
                    local gold=ugGetGold()
                    if gold>=cost then
                        -- buy it then prestige
                        if PU then pcall(function() PU:FireServer(nextUpg) end) end
                        task.wait(0.6)
                        table.remove(e.preUpgQ,1);sv()
                        pcall(function() if e.__ugQLbl then e.__ugQLbl:UpdateName(ugQueueLabel()) end end)
                        pcall(function() if e.__ugWaitLbl then e.__ugWaitLbl:UpdateName("Bought: "..nextUpg) end end)
                    else
                        -- waiting for gold
                        doPrestige=false
                        local shortfall=cost-gold
                        pcall(function() if e.__ugWaitLbl then e.__ugWaitLbl:UpdateName("Waiting "..fmt(shortfall).." more gold for: "..nextUpg) end end)
                    end
                end
            end
            if doPrestige then
                pcall(function() PR:FireServer() end)
                task.delay(3, function() pcall(ugRefreshDD) end)  -- refresh after prestige syncs
            end
        end
    else
        if preCb then preCb(PD and("Max prestige: "..cr) or("Prestige: "..cr.."  (data loading...)")) end
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
    if pEtaCb then
        if need==math.huge then pEtaCb("Prestige ETA: Max rank")
        elseif need<=ld.level then pEtaCb("Prestige ETA: ✓ Ready!")
        else
            local tot=ld.required-ld.xp
            if LV and LV.RequiredXPForLevel then
                pcall(function()
                    for lv=ld.level+1,need-1 do
                        tot=tot+(LV.RequiredXPForLevel(lv) or 0)
                    end
                end)
            end
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
local _dlyLast=0
local function chkDly()
    if not e.aDly then return end
    local now=os.clock();if now-_dlyLast<60 then return end;_dlyLast=now
    pcall(function()
        local d=GDR and GDR:InvokeServer()
        if d and d.canClaim and CDR then CDR:InvokeServer() end
    end)
end
if not e.__ORC then e.__ORC=true;task.spawn(function()
    task.wait(3)
    pcall(function() local d=GOR and GOR:InvokeServer();if d and COR then COR:InvokeServer() end end)
end) end
-- XP / Gold Recorder (non-persistent — fresh each load)
local recActive=false
local recLastResult=""  -- updated each tick; Copy button reads this
local recStatLbl,recXPLbl,recXPsLbl,recGoldLbl,recGoldsLbl
local function startRec(durStr)
    if recActive then
        pcall(function() recStatLbl:UpdateName("⚠ Already recording! Press Stop first.") end);return
    end
    local dur=tonumber(durStr)
    if not dur or dur<=0 then
        pcall(function() recStatLbl:UpdateName("⚠ Enter a valid duration (seconds)") end);return
    end
    recActive=true
    pcall(function() recStatLbl:UpdateName("Starting...") end)
    pcall(function() recXPLbl:UpdateName("XP: 0") end)
    pcall(function() recXPsLbl:UpdateName("/s: 0  /hr: 0") end)
    pcall(function() recGoldLbl:UpdateName("Gold: 0") end)
    pcall(function() recGoldsLbl:UpdateName("/s: 0  /hr: 0") end)
    task.spawn(function()
        local ok,ld=pcall(function() return NW.InvokeServer("GetLevel") end)
        local goldNow=ugGetGold()
        if not ok or not ld then
            recActive=false
            pcall(function() recStatLbl:UpdateName("⚠ Failed to start — try again") end);return
        end
        local prevXP=ld.xp
        local prevGold=goldNow
        local totalXP=0
        local totalGold=0
        local t0=os.clock()
        local deadline=t0+dur
        while os.clock()<deadline and recActive and e.__G==G do
            task.wait(2)
            local ok2,ld2=pcall(function() return NW.InvokeServer("GetLevel") end)
            local g2=ugGetGold()
            if ok2 and ld2 then
                local xpNow=ld2.xp
                local dxp=xpNow-prevXP;if dxp>0 then totalXP=totalXP+dxp end
                prevXP=xpNow
                local dg=g2-prevGold;if dg>0 then totalGold=totalGold+dg end
                prevGold=g2
            end
            local elapsed=os.clock()-t0
            local remaining=math.max(0,deadline-os.clock())
            local xpRate=elapsed>0 and totalXP/elapsed or 0
            local goldRate=elapsed>0 and totalGold/elapsed or 0
            local rm=math.floor(remaining/60);local rs=math.floor(remaining%60)
            local remStr=rm>0 and(rm.."m "..rs.."s")or(rs.."s")
            pcall(function() recStatLbl:UpdateName("Recording — "..remStr.." left") end)
            pcall(function() recXPLbl:UpdateName("XP: +"..fmt(totalXP)) end)
            pcall(function() recXPsLbl:UpdateName("/s: "..fmt(xpRate).."  /hr: "..fmt(xpRate*3600)) end)
            pcall(function() recGoldLbl:UpdateName("Gold: +"..fmt(totalGold)) end)
            pcall(function() recGoldsLbl:UpdateName("/s: "..fmt(goldRate).."  /hr: "..fmt(goldRate*3600)) end)
            recLastResult="[RNG "..math.floor(dur).."s Record]\nXP: +"..fmt(totalXP).."  /s: "..fmt(xpRate).."  /hr: "..fmt(xpRate*3600).."\nGold: +"..fmt(totalGold).."  /s: "..fmt(goldRate).."  /hr: "..fmt(goldRate*3600)
        end
        local stoppedEarly=not recActive
        recActive=false
        local elapsed=os.clock()-t0
        local xpRate=elapsed>0 and totalXP/elapsed or 0
        local goldRate=elapsed>0 and totalGold/elapsed or 0
        local em=math.floor(elapsed/60);local es=math.floor(elapsed%60)
        local elStr=em>0 and(em.."m "..es.."s")or(math.floor(elapsed).."s")
        pcall(function() recStatLbl:UpdateName((stoppedEarly and"Stopped"or"✓ Done").." ("..elStr..")") end)
        pcall(function() recXPLbl:UpdateName("XP: +"..fmt(totalXP)) end)
        pcall(function() recXPsLbl:UpdateName("/s: "..fmt(xpRate).."  /hr: "..fmt(xpRate*3600)) end)
        pcall(function() recGoldLbl:UpdateName("Gold: +"..fmt(totalGold)) end)
        pcall(function() recGoldsLbl:UpdateName("/s: "..fmt(goldRate).."  /hr: "..fmt(goldRate*3600)) end)
        recLastResult="[RNG "..elStr.." Record]\nXP: +"..fmt(totalXP).."  /s: "..fmt(xpRate).."  /hr: "..fmt(xpRate*3600).."\nGold: +"..fmt(totalGold).."  /s: "..fmt(goldRate).."  /hr: "..fmt(goldRate*3600)
    end)
end
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
local W=Lib:Window({Title="RNG Heroes",Subtitle="v5.26",DragStyle=1,ShowUserInfo=true,AcrylicBlur=false})
local TG=W:TabGroup()
local TA =TG:Tab({Name="Auto",    Image="rbxassetid://10723343321"})
local TPr=TG:Tab({Name="Prestige",Image="rbxassetid://10734963191"})
local TH =TG:Tab({Name="Heroes",  Image="rbxassetid://6022668955"})
local TB =TG:Tab({Name="Boss",    Image="rbxassetid://10734975692"})
local TM =TG:Tab({Name="Misc",    Image="rbxassetid://10723343321"})
local TI =TG:Tab({Name="Index",   Image="rbxassetid://10723343321"})
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
-- Recorder UI (right column, below KillAura/ST)
local AR2=TA:Section({Side="Right"})
AR2:Header({Text="XP / Gold Recorder"})
local recDurStr="60"
pcall(function()
    AR2:Input({Name="Duration (sec)",Placeholder="e.g. 60, 300, 3600",Callback=function(v)
        if v and v~="" then recDurStr=v end
    end})
end)
AR2:Button({Name="▶ Start Recording",Callback=function() startRec(recDurStr) end})
AR2:Button({Name="■ Stop",Callback=function() recActive=false end})
recStatLbl=AR2:Label({Text="Idle — enter duration & press Start"})
recXPLbl=AR2:Label({Text="XP: —"})
recXPsLbl=AR2:Label({Text="/s: —  /hr: —"})
recGoldLbl=AR2:Label({Text="Gold: —"})
recGoldsLbl=AR2:Label({Text="/s: —  /hr: —"})
AR2:Button({Name="Copy Result",Callback=function()
    if recLastResult=="" then
        pcall(function() recStatLbl:UpdateName("⚠ No result yet — record first") end);return
    end
    pcall(function() setclipboard(recLastResult) end)
    pcall(function() recStatLbl:UpdateName("✓ Copied to clipboard!") end)
end})
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
-- Pre-Prestige Queue section
local PrL2=TPr:Section({Side="Left"})
PrL2:Header({Text="Pre-Prestige Upgrade Queue"})
-- Dropdown starts empty; populated after Upgrades module syncs (task.delay below)
local ugSelName=nil  -- currently selected upgrade name (without cost suffix)
local ugQDD=PrL2:Dropdown({Name="Select Upgrade",Options={"(None)"},Default="(None)",IgnoreConfig=true,Callback=function(v)
    if v=="(None)" then ugSelName=nil
    -- strip trailing " [cost]" only (e.g. "potions [WIP] [100]" → "potions [WIP]")
    else ugSelName=v:match("^(.-)%s+%[[%d%.]+[KMBTQkmbtq]?%]$") or v end
end})
pcall(function() ugQDD:UpdateSelection("(None)") end)
local ugQLbl=PrL2:Label({Text=ugQueueLabel()})
e.__ugQLbl=ugQLbl
local ugWaitLbl=PrL2:Label({Text=""})
e.__ugWaitLbl=ugWaitLbl
PrL2:Button({Name="Upgrade Now",Callback=function()
    if not ugSelName then
        pcall(function() ugWaitLbl:UpdateName("⚠ Select an upgrade first") end);return
    end
    local owned=ugGetOwned()
    if owned[ugSelName] then
        pcall(function() ugWaitLbl:UpdateName("Already owned: "..ugSelName) end);return
    end
    local cost=ugCost(ugSelName)
    if cost==0 then
        pcall(function() ugWaitLbl:UpdateName("Unknown upgrade: "..ugSelName) end);return
    end
    local gold=ugGetGold()
    if gold<cost then
        pcall(function() ugWaitLbl:UpdateName("Need "..fmt(cost-gold).." more gold") end);return
    end
    if not PU then pcall(function() ugWaitLbl:UpdateName("⚠ PurchaseUpgrade remote unavailable") end);return end
    pcall(function() PU:FireServer(ugSelName) end)
    pcall(function() ugWaitLbl:UpdateName("Bought: "..ugSelName) end)
    task.delay(2, function() pcall(ugRefreshDD) end)
end})
PrL2:Button({Name="Add to Queue",Callback=function()
    if not ugSelName then return end
    if not e.preUpgQ then e.preUpgQ={} end
    table.insert(e.preUpgQ,ugSelName);sv()
    pcall(function() ugQLbl:UpdateName(ugQueueLabel()) end)
    pcall(function() ugWaitLbl:UpdateName("Added: "..ugSelName) end)
end})
PrL2:Button({Name="Remove Last",Callback=function()
    if e.preUpgQ and #e.preUpgQ>0 then
        local removed=table.remove(e.preUpgQ);sv()
        pcall(function() ugQLbl:UpdateName(ugQueueLabel()) end)
        pcall(function() ugWaitLbl:UpdateName("Removed: "..removed) end)
    end
end})
PrL2:Button({Name="Clear Queue",Callback=function()
    e.preUpgQ={};sv()
    pcall(function() ugQLbl:UpdateName(ugQueueLabel()) end)
    pcall(function() ugWaitLbl:UpdateName("Queue cleared") end)
end})
-- refresh dropdown options only — does NOT reset current selection
-- call at startup (after sync) and after each prestige
ugRefreshDD = function()
    local newList=ugUnownedList()
    local newOpts={"(None)"}
    for _,u in ipairs(newList) do table.insert(newOpts,u.name.." ["..fmt(u.cost).."]") end
    pcall(function() ugQDD:ClearOptions() end)
    pcall(function() ugQDD:InsertOptions(newOpts) end)
    -- restore selection if it's still valid, otherwise reset
    local selStillValid = ugSelName and (function()
        for _,u in ipairs(newList) do if u.name==ugSelName then return true end end
        return false
    end)()
    if selStillValid then
        pcall(function() ugQDD:UpdateSelection(ugSelName.." ["..fmt(ugCost(ugSelName)).."]") end)
    else
        ugSelName=nil
        pcall(function() ugQDD:UpdateSelection("(None)") end)
    end
end
-- populate dropdown 4 seconds after start (Upgrades module syncs by then)
task.delay(4, function() pcall(ugRefreshDD) end)
-- Heroes tab
local HL=TH:Section({Side="Left"})
HL:Header({Text="Defense"})
HL:Toggle({Name="Infinite Health",Default=e.hGod,Callback=function(v) e.hGod=v;sv() end},"hGod")
HL:Header({Text="Offense"})
HL:Toggle({Name="Infinite Damage",Default=e.hDmg,Callback=function(v) e.hDmg=v;sv() end},"hDmg")
local dmgIgnDD=HL:Dropdown({Name="  Ignore DMG",Options={"None","Boss"},Default=e.hDmgIgn,IgnoreConfig=true,Callback=function(v) e.hDmgIgn=v;sv() end})
pcall(function() dmgIgnDD:UpdateSelection(e.hDmgIgn) end)
HL:Toggle({Name="Atk Speed x1000",Default=e.hSpd,Callback=function(v) e.hSpd=v;sv() end},"hSpd")
local spdIgnDD=HL:Dropdown({Name="  Ignore ATK",Options={"None","Boss"},Default=e.hSpdIgn,IgnoreConfig=true,Callback=function(v) e.hSpdIgn=v;sv() end})
pcall(function() spdIgnDD:UpdateSelection(e.hSpdIgn) end)
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
-- Server Hop section (left)
local MsL2=TM:Section({Side="Left"})
MsL2:Header({Text="Server Hop"})
MsL2:Button({Name="Random Hop",Callback=function() task.spawn(hopRandom) end})
MsL2:Button({Name="Copy This Server's Job ID",Callback=function()
    pcall(function() setclipboard(game.JobId) end)
    pcall(function() privStatLbl:UpdateName("Copied: "..game.JobId:sub(1,18).."...") end)
end})
MsL2:Header({Text="Private Server"})
local privLbl=MsL2:Label({Text=e.privCode~="" and("Code: "..e.privCode:sub(1,12).."...") or"Code: not set"})
local privStatLbl=MsL2:Label({Text=""})
local function applyPrivCode(raw)
    if not raw or raw=="" then return end
    local c=raw:match("privateServerLinkCode=([%w_%-]+)") or raw:gsub("%s+","")
    if c=="" then return end
    e.privCode=c;sv()
    pcall(function() privLbl:UpdateName("Code: "..c:sub(1,12).."...") end)
    pcall(function() privStatLbl:UpdateName("") end)
end
pcall(function()
    MsL2:Input({Name="Job ID  (e.g. abc-123...)",Placeholder="Paste Server Job ID or link...",Callback=function(v) applyPrivCode(v) end})
end)
MsL2:Button({Name="Paste (Clipboard)",Callback=function()
    local ok,raw=pcall(getclipboard);if not ok or not raw then return end
    applyPrivCode(raw)
end})
MsL2:Button({Name="Hop to Private",Callback=function()
    if not e.privCode or e.privCode=="" then
        pcall(function() privStatLbl:UpdateName("⚠ Set code first!") end);return
    end
    pcall(function() privStatLbl:UpdateName("Searching VIP servers...") end)
    task.spawn(function()
        hopPrivate(e.privCode,function(msg)
            pcall(function() privStatLbl:UpdateName(msg) end)
        end)
    end)
end})
-- Luck Server Hop section (right)
-- Note: MacLib has no MultiDropdown — using single Dropdown for minimum target luck
local MsR2=TM:Section({Side="Right"})
MsR2:Header({Text="Luck Server Hop"})
local curLuck=LP:GetAttribute("ServerLuckMul") or 1
local lHopLbl=MsR2:Label({Text=e.lHop and"Searching..."or(e.__lHopResult or("This server: x"..curLuck))})
-- Dropdown: select minimum acceptable ServerLuckMul
-- script hops until cur >= selected value
local lMinOpts={"x2","x4","x8","x16","x32","x64","x128"}
local lMinDefault="x"..(e.lHopMin or 2)
local lHopDD=MsR2:Dropdown({
    Name="Min Luck Boost",
    Options=lMinOpts,
    Default=lMinDefault,
    IgnoreConfig=true,
    Callback=function(v) e.lHopMin=tonumber(v:sub(2)) or 2;sv() end
})
pcall(function() lHopDD:UpdateSelection(lMinDefault) end)
MsR2:Button({Name="Find Luck Server",Callback=function()
    local tgt=e.lHopMin or 2
    local cur=LP:GetAttribute("ServerLuckMul") or 1
    if cur>=tgt then
        e.__lHopResult="✓ Already x"..cur.." (≥ x"..tgt..")"
        pcall(function() lHopLbl:UpdateName(e.__lHopResult) end);return
    end
    e.lHop=true;e.__lHopResult=nil;sv()
    pcall(function() lHopLbl:UpdateName("Starting... (want x"..tgt..")") end)
    task.wait(0.5);task.spawn(hopRandom)
end})
MsR2:Button({Name="Stop Luck Hop",Callback=function()
    e.lHop=false;e.__lHopResult=nil;sv()
    local cur=LP:GetAttribute("ServerLuckMul") or 1
    pcall(function() lHopLbl:UpdateName("Stopped  (this server: x"..cur..")") end)
end})
-- Index tab — roll-based, all sizes, excludes Exclusive
local TIL=TI:Section({Side="Left"})
local TIR=TI:Section({Side="Right"})
TIL:Header({Text="Index Tracker"})
ixProgLbl  = TIL:Label({Text="Loading..."})
ixNormLbl  = TIL:Label({Text="Normal:   ?"})
ixHugeLbl  = TIL:Label({Text="Huge:     ?"})
ixGiantLbl = TIL:Label({Text="Giant:    ?"})
ixColosLbl = TIL:Label({Text="Colossal: ?"})
TIL:Button({Name="↺ Refresh",Callback=function()
    task.spawn(function() pcall(ixRefreshLbls) end)
end})
TIL:Header({Text="Luck & Probabilities"})
ixLuckLbl = TIL:Label({Text="Luck: loading..."})
ixProbLbl = TIL:Label({Text="P(size): loading..."})
ixRecLbl  = TIL:Label({Text="Optimal Luck: —"})
TIR:Header({Text="Missing Units by Size"})
ixMissNLbl = TIR:Label({Text="Normal: —"})
ixMissHLbl = TIR:Label({Text="Huge: —"})
ixMissGLbl = TIR:Label({Text="Giant: —"})
ixMissCLbl = TIR:Label({Text="Colossal: —"})
-- define ixRefreshLbls now that all labels exist
ixRefreshLbls=function()
    local d=ixLoadData()
    if not d then
        pcall(function() ixProgLbl:UpdateName("⚠ Data unavailable — rejoin or wait") end);return
    end
    -- Overall progress
    local totEntry=d.heroCount*4
    local gotEntry=0
    for _,sz in ipairs({"Normal","Huge","Giant","Colossal"}) do
        gotEntry=gotEntry+(d.tot[sz]-#d.miss[sz])
    end
    local pct=math.floor(gotEntry/totEntry*100+0.5)
    pcall(function() ixProgLbl:UpdateName(
        string.format("Total: %d/%d  [%d%%]  (%d heroes)",gotEntry,totEntry,pct,d.heroCount)
    ) end)
    -- Per-size: show got/total and missing count
    local function szLine(sz,lbl)
        local m=#d.miss[sz]; local t=d.tot[sz]
        local tick=m==0 and " ✓" or ""
        pcall(function() lbl:UpdateName(
            string.format("%s: %d/%d  (%d missing)%s",sz,t-m,t,m,tick)
        ) end)
    end
    szLine("Normal",   ixNormLbl)
    szLine("Huge",     ixHugeLbl)
    szLine("Giant",    ixGiantLbl)
    szLine("Colossal", ixColosLbl)
    -- Manual Luck (LuckCap) currently set in game Settings
    local capDisp=d.curLuckCap==false and "MAX (no cap)" or d.fmtN(d.curLuckCap)
    pcall(function() ixLuckLbl:UpdateName("Manual Luck now: "..capDisp) end)
    -- Size chances (separate system from unit luck)
    pcall(function() ixProbLbl:UpdateName(string.format(
        "Size chances: Huge %.2f%%  Giant %.3f%%  Colossal %.4f%%",
        d.probs.H*100,d.probs.G*100,d.probs.C*100
    )) end)
    -- Primary recommendation: which LuckCap to set for best Normal Index hunting
    pcall(function() ixRecLbl:UpdateName(d.recStr) end)
    -- Right panel: per-size rarity breakdown with effective LuckCap
    -- Format: "Rar(2)→3 | Epi(5)→148 | Voi(5)→MAX"
    local function rarBreakdown(byRar, sz, lbl)
        local parts={}
        for _,r in ipairs(d.RARITY_ORDER) do
            local list=byRar[r]
            if list and #list>0 then
                local capTxt=d.fmtN(d.effectiveCap(r))
                table.insert(parts,r:sub(1,3).."("..#list..")→"..capTxt)
            end
        end
        if #parts==0 then
            pcall(function() lbl:UpdateName(sz..": ✓ all obtained!") end)
        else
            pcall(function() lbl:UpdateName(sz.."  "..table.concat(parts," | ")) end)
        end
    end
    rarBreakdown(d.missNByRar, "Normal", ixMissNLbl)
    rarBreakdown(d.missHByRar, "Huge",   ixMissHLbl)
    rarBreakdown(d.missGByRar, "Giant",  ixMissGLbl)
    rarBreakdown(d.missCByRar, "Colossal", ixMissCLbl)
end
-- auto-refresh on startup
task.delay(3, function() pcall(ixRefreshLbls) end)
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
        local hg=e.hGod and"GOD"or"ok"
        local hd=e.hDmg and((e.hDmgIgn=="Boss"and e.__BSA)and"SKIP"or"INF")or"ok"
        local hs=e.hSpd and((e.hSpdIgn=="Boss"and e.__BSA)and"SKIP"or"x1k")or"ok"
        pcall(function() heroLbl:UpdateName("HP:"..hg.."  DMG:"..hd.."  ATK:"..hs) end)
        pcall(function() bsLbl:UpdateName("Boss: "..(e.__BSA and"ACTIVE"or"none")) end)
        -- upgrade queue label refresh
        pcall(function() ugQLbl:UpdateName(ugQueueLabel()) end)
        -- luck hop status
        local cur=LP:GetAttribute("ServerLuckMul") or 1
        if e.lHop then
            local cnt=e.__lHopCount or 0
            pcall(function() lHopLbl:UpdateName("Checked "..cnt.." servers... cur x"..cur.." → want x"..(e.lHopMin or 2)) end)
        elseif e.__lHopResult then
            pcall(function() lHopLbl:UpdateName(e.__lHopResult) end)
        else
            pcall(function() lHopLbl:UpdateName("This server: x"..cur) end)
        end
        task.wait(3)
    end
end)
e.__W=W
TA:Select()
print("[RNG] v5.35 OK")
