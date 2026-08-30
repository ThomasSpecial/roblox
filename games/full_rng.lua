getgenv().__G=(getgenv().__G or 0)+1;local G=getgenv().__G
pcall(function() if getgenv().__W then getgenv().__W:Unload() end end)
local e=getgenv()
local myUID=tostring(math.random(1,2^30))
e.__tok=myUID
print("[RNG] Starting (gen "..G..")...")
local PL=game:GetService("Players");local RS=game:GetService("ReplicatedStorage")
local VU=game:GetService("VirtualUser");local HS=game:GetService("HttpService")
local TSvc=game:GetService("TeleportService");local LP=PL.LocalPlayer
local R=RS:WaitForChild("Remotes")
local SAR=R:WaitForChild("SetAutoRoll");local GL=R:WaitForChild("GetLevel")
local GP=R:WaitForChild("GetPrestige");local PR=R:WaitForChild("PrestigeRequested")
local RCA=R:WaitForChild("ReportClickAttack");local GBS=R:WaitForChild("GetBossState")
local GDR=R:WaitForChild("GetDailyRewards");local CDR=R:WaitForChild("ClaimDailyReward")
local GOR=R:WaitForChild("GetOfflineRewards");local COR=R:WaitForChild("ClaimOfflineRewards")
local GetRunes=R:WaitForChild("GetRunes")
print("[RNG] Remotes ready, loading modules...")
-- RS.shared.X.Y / RS.client.X.Y used to be plain dot-indexing with zero
-- WaitForChild -- fine once everything's replicated, but a hard "attempt to
-- index nil" if this autoexec fires before ReplicatedStorage.shared/client
-- finish replicating on a fresh join (confirmed live: a stuck session showed
-- __G incremented but never reached "[RNG] Loading UI...", no Infinite-yield
-- warning either, consistent with an early dot-index error swallowed before
-- ever printing). Bounded WaitForChild (10s) on every hop instead -- errors
-- surface as an actual error now instead of a silent, permanent stall.
local SharedF=RS:WaitForChild("shared",10);local ClientF=RS:WaitForChild("client",10)
local PD=require(SharedF:WaitForChild("Prestige",10):WaitForChild("PrestigeData",10))
local LV=require(SharedF:WaitForChild("Levels",10):WaitForChild("Levels",10))
local SH=require(SharedF:WaitForChild("Shared",10))
local HR=require(ClientF:WaitForChild("Heroes",10):WaitForChild("HeroRender",10))
local NW=require(ClientF:WaitForChild("Network",10):WaitForChild("Network",10))
local EN=require(ClientF:WaitForChild("Enemies",10):WaitForChild("Enemies",10))
local Currency=require(ClientF:WaitForChild("Currency",10):WaitForChild("Currency",10))
local FSH=require(SharedF:WaitForChild("Fusion",10):WaitForChild("Fusion",10))
local FCL=require(ClientF:WaitForChild("Fusion",10):WaitForChild("Fusion",10))
local Inv=require(ClientF:WaitForChild("Inventory",10):WaitForChild("Inventory",10))
local TowerData=require(SharedF:WaitForChild("Tower",10):WaitForChild("TowerData",10))
local Crafting=require(SharedF:WaitForChild("Crafting",10):WaitForChild("Crafting",10))
local Items=require(ClientF:WaitForChild("Items",10):WaitForChild("Items",10))
print("[RNG] Modules ready")
-- RuneData hardcoded เพราะ require ใน thread 8 callback ไม่ได้
local RUNE_COST = 25
local RUNE_MAX_LV = 10
local RUNE_INFO = {
    Bean    = {stat="BeanFind",   kind="Mul", rar="RAR"},
    Blade   = {stat="HeroDamage", kind="Mul", rar="RAR"},
    Crit    = {stat="CritChance", kind="Add", rar="EPI"},
    Fortune = {stat="Luck",       kind="Mul", rar="LEG"},
    Greed   = {stat="Gold",       kind="Mul", rar="EPI"},
    Havoc   = {stat="CritDamage", kind="Add", rar="LEG"},
    Swift   = {stat="HeroAtk",    kind="Mul", rar="RAR"},
    Wisdom  = {stat="XP",         kind="Mul", rar="EPI"},
}

local SF="RNGHeroesAutomation/state.json"
local SK={"aRoll","aPre","aClk","aSC","aAfk","aBoss","aRec","fSpt","bSpt","aDly","hGod","hSpd","hDmg","wSpd","wJmp","hDmgIgn","hSpdIgn","aRune","aRuneAmt","aFuse","aCraft","aCraftList","aTower","aTowerTier","aTowerBackToFarm","aTowerUpgOn","aTowerUpg"}
pcall(function() if not isfolder("RNGHeroesAutomation") then makefolder("RNGHeroesAutomation") end end)
local function sv() local d={} for _,k in ipairs(SK) do d[k]=e[k] end;pcall(function() writefile(SF,HS:JSONEncode(d)) end) end
pcall(function() local c=readfile(SF);local d=HS:JSONDecode(c);for _,k in ipairs(SK) do if d[k]~=nil and e[k]==nil then e[k]=d[k] end end end)
if e.aRoll==nil then e.aRoll=true end
if e.aAfk==nil then e.aAfk=true end
if e.aRec==nil then e.aRec=true end
if e.aDly==nil then e.aDly=true end
-- hDmgIgn/hSpdIgn used to be a single string ("None"/"Boss"); now a multi-select
-- list of zones to ignore. Migrate an old string value from a saved state.json
-- straight into the new list shape instead of dropping it.
if type(e.hDmgIgn)~="table" then e.hDmgIgn=(e.hDmgIgn and e.hDmgIgn~="None")and{e.hDmgIgn}or{} end
if type(e.hSpdIgn)~="table" then e.hSpdIgn=(e.hSpdIgn and e.hSpdIgn~="None")and{e.hSpdIgn}or{} end
if e.aRune==nil then e.aRune=false end
if e.aRuneAmt==nil then e.aRuneAmt=1 end
if e.aFuse==nil then e.aFuse=false end
if e.aCraft==nil then e.aCraft=false end
if e.aCraftList==nil then e.aCraftList={} end
if e.aTower==nil then e.aTower=false end
if e.aTowerTier==nil then e.aTowerTier=1 end
if e.aTowerBackToFarm==nil then e.aTowerBackToFarm=true end
if e.aTowerUpgOn==nil then e.aTowerUpgOn=false end
if e.aTowerUpg==nil then e.aTowerUpg={} end

-- roll speed x1000
task.spawn(function()
    local ok,RV=pcall(function() return require(RS:WaitForChild("client"):WaitForChild("Rolling"):WaitForChild("RollingView")) end)
    if not ok then return end
    if not e.__ORV then e.__ORV=RV.PlayRoll end
    local o=e.__ORV
    RV.PlayRoll=function(c,h,sz,sp,...) local m=(type(sp)=="number"and sp>0)and sp or 1;return o(c,h,sz,m*1000,...) end
end)
if not e.__AFKh then e.__AFKh=true;LP.Idled:Connect(function() if e.aAfk then pcall(function() VU:CaptureController();VU:ClickButton2(Vector2.new()) end) end end) end
-- Auto Reconnect -- ported from mutant_plants.lua's 3-trigger version: PlayerRemoving alone missed
-- silent drops where the transport dies but LocalPlayer never actually leaves Players (native
-- "Disconnected" dialog just sits there). tryReconnect is debounced (5s) so PlayerRemoving +
-- AncestryChanged firing for the SAME disconnect don't double-Teleport, and the debounce resets
-- after 5s so the NEXT real disconnect isn't silently swallowed by a latch that never cleared.
if not e.__RH then
    e.__RH=true
    local reconnectFired=false
    local function tryReconnect()
        if reconnectFired then return end
        reconnectFired=true
        task.delay(5,function() reconnectFired=false end)
        if e.aRec then pcall(function() TSvc:Teleport(game.PlaceId,LP) end) end
    end
    PL.PlayerRemoving:Connect(function(p) if p==LP then tryReconnect() end end)
    LP.AncestryChanged:Connect(function(_,parent) if parent~=PL then tryReconnect() end end)
    e.__tryReconnect=tryReconnect
end
-- Third trigger: scan CoreGui every 5s for the native "Disconnected" dialog (Error 277-style drops)
-- -- confirmed in mutant_plants.lua that a plain Teleport still works from inside that state.
task.spawn(function()
    while e.__G==G do
        task.wait(5)
        if e.aRec and e.__tryReconnect then
            pcall(function()
                for _,inst in ipairs(game:GetService("CoreGui"):GetDescendants()) do
                    if inst:IsA("TextLabel") and inst.Text=="Disconnected" then e.__tryReconnect();return end
                end
            end)
        end
    end
end)
if not e.__OAD then e.__OAD=HR.ApplyLocalDamage end
HR.ApplyLocalDamage=function(a,b,c,d,...) if e.hGod then return end;return e.__OAD(a,b,c,d,...) end
if not e.__ONF then e.__ONF=NW.FireServer end
NW.FireServer=function(ev,...) if e.hGod and(ev=="ReportEnemyAttack"or ev=="ReportBossAoeHit")then local a={...};a[#a]=0;return e.__ONF(ev,table.unpack(a))end;return e.__ONF(ev,...) end
-- "Tower" ignore option rides the same e.__BSA-style flag as "Boss" -- e.__InTower
-- is kept current by the TowerDelta listener below (kind=="Floor"/"End"), a second
-- Connect on the same RemoteEvent, so the game's own Tower.lua listener is untouched.
if not e.__OCA then e.__OCA=SH.Heroes.GetCombatATK end
SH.Heroes.GetCombatATK=function(...) if e.hDmg then if(table.find(e.hDmgIgn or{},"Boss")and e.__BSA)or(table.find(e.hDmgIgn or{},"Tower")and e.__InTower)then return e.__OCA(...) end;return 1e50 end;return e.__OCA(...) end
if not e.__OGS then e.__OGS=SH.GetStat end
SH.GetStat=function(n,...)
    if e.hSpd and n=="HeroAttackSpeed" then if(table.find(e.hSpdIgn or{},"Boss")and e.__BSA)or(table.find(e.hSpdIgn or{},"Tower")and e.__InTower)then return e.__OGS(n,...) end;return 1000 end
    if (e.aClk or e.aSC) and n=="ClickAttackDpsFraction" then return 1000 end
    if (e.aClk or e.aSC) and n=="ClickAttackMaxPerSec" then return 1000 end
    return e.__OGS(n,...)
end
if not e.__TDL then
    e.__TDL=true
    pcall(function()
        NW.OnClientEvent("TowerDelta",function(p1)
            if type(p1)~="table" then return end
            if p1.kind=="Floor" then e.__InTower=true;e.__TowerFloor=p1.floor
            elseif p1.kind=="End" then e.__InTower=false end
        end)
    end)
end
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
local function ar() pcall(function() SAR:FireServer(e.aRoll) end) end;ar()
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
local function hh() return LP.Character and LP.Character:FindFirstChild("HumanoidRootPart") end
local function c2t(cf) local p=cf.Position;local l=cf.LookVector;return{px=p.X,py=p.Y,pz=p.Z,lx=l.X,ly=l.Y,lz=l.Z} end
local function t2c(t) if not t then return nil end;local p=Vector3.new(t.px,t.py,t.pz);local l=Vector3.new(t.lx or 0,t.ly or 0,t.lz or -1);return CFrame.new(p,p+l) end
local function sfarm() local h=hh();if not h then return false end;e.fSpt=c2t(h.CFrame);sv();return true end
local function sboss() local h=hh();if not h then return false end;e.bSpt=c2t(h.CFrame);sv();return true end
e.__IBA=e.__IBA or false;e.__BSA=e.__BSA or false;local bStat="Waiting..."
local function chkBoss()
    local ok,st=pcall(function() return GBS:InvokeServer() end)
    e.__BSA=(ok and st~=nil)
    if not e.aBoss then bStat="Off";return end
    -- Tower has the floor while Auto Tower is actively running one -- warping out to
    -- fight a boss mid-run abandons it and the key that bought it. Gated on e.aTower
    -- too, not just e.__InTower: that flag only clears on the server's own "End"
    -- delta, so if the user flicks Auto Tower off mid-run it can stay stuck true with
    -- nothing driving it -- without this it would silently mute Auto Boss forever.
    if e.aTower and e.__InTower then bStat="Skipped (Tower active)";return end
    if not ok then bStat="Error";return end
    local a=e.__BSA
    if a and not e.__IBA then
        local h=hh();if h then e.__BRC=h.CFrame end
        local bh=hh();if bh then
            local s=t2c(e.bSpt)
            if s then bh.CFrame=s
            else local wb=workspace:FindFirstChild("Worldboss");local sp=wb and wb:FindFirstChild("PlayerSpawn");if sp and sp:IsA("BasePart") then bh.CFrame=sp.CFrame*CFrame.new(0,sp.Size.Y/2+3,0) end
            end
        end
        e.__IBA=true;bStat="Warped to boss!"
    elseif not a and e.__IBA then
        local h=hh();local ret=t2c(e.fSpt) or e.__BRC;if h and ret then h.CFrame=ret end;e.__IBA=false;bStat="Boss done."
    elseif a then bStat="In arena..."
    else bStat="Waiting..." end
end
local _xpLast,_xpT=nil,nil
-- Tower's GetTierClearDPS scales with G=1.09 per floor, 25 floors/tier -- by
-- tier 10 that's already north of 1e13. Capped at B before, so Tier 10 printed
-- as a bare "18125B" instead of stepping up a suffix. Extended through Qi
-- (1e18) for headroom against however high tiers keep climbing.
local function fmt(n)
    n=n or 0
    if n>=1e18 then return string.format("%.2fQi",n/1e18)
    elseif n>=1e15 then return string.format("%.2fQa",n/1e15)
    elseif n>=1e12 then return string.format("%.2fT",n/1e12)
    elseif n>=1e9 then return string.format("%.2fB",n/1e9)
    elseif n>=1e6 then return string.format("%.1fM",n/1e6)
    elseif n>=1e3 then return string.format("%.1fK",n/1e3)
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
    local now=os.clock();local remXP=ld.required-ld.xp;local rate=0;local etaStr="Rem: "..fmt(remXP).." XP"
    if _xpLast and _xpT then
        local dt=now-_xpT
        if dt>0 and ld.xp>_xpLast then
            rate=(ld.xp-_xpLast)/dt
            local eta=rate>0 and remXP/rate or math.huge
            etaStr=etaStr.."  |  "..fmt(rate*60).."/min"
            if eta<86400 then local m=math.floor(eta/60);local s=math.floor(eta%60);etaStr=etaStr.."  ETA: "..m.."m "..s.."s" end
        end
    end
    _xpLast=ld.xp;_xpT=now
    if xpCb then xpCb(etaStr) end
    if pEtaCb then
        if need==math.huge then pEtaCb("Prestige ETA: Max rank")
        elseif need<=ld.level then pEtaCb("Prestige ETA: ✓ Ready!")
        else
            local tot=ld.required-ld.xp
            pcall(function() for lv=ld.level+1,need-1 do tot=tot+(LV.RequiredXPForLevel(lv) or 0) end end)
            if rate>0 then
                local eta=tot/rate;local h=math.floor(eta/3600);local m=math.floor((eta%3600)/60);local s=math.floor(eta%60)
                local ts=h>0 and(h.."h "..m.."m")or(m>0 and(m.."m "..s.."s")or(s.."s"))
                pEtaCb("Prestige ETA: "..ts.."  ("..fmt(tot).." XP left)")
            else pEtaCb("Prestige ETA: "..fmt(tot).." XP  (no rate yet)") end
        end
    end
end
local function chkDly() if not e.aDly then return end;pcall(function() local d=GDR:InvokeServer();if d and d.canClaim then CDR:InvokeServer() end end) end
if not e.__ORC then e.__ORC=true;task.spawn(function() pcall(function() local d=GOR:InvokeServer();if d then COR:InvokeServer() end end) end) end

-- ===== Runes =====
local runeStatus="Idle"
local function rollRune(count)
    local beans=Currency.Get("Beans")
    local cost=RUNE_COST*count
    if beans<cost then runeStatus="Need "..cost.." Beans (have "..beans..")";return end
    pcall(function() NW.FireServer("RollRune",count) end)
    runeStatus="Rolled x"..count.." | Beans: "..(beans-cost)
end
local function rollMax()
    local beans=Currency.Get("Beans");local max=math.floor(beans/RUNE_COST)
    if max<=0 then runeStatus="No Beans!";return end
    task.spawn(function()
        local rem=max
        while rem>0 do
            local b=math.min(rem,100)
            pcall(function() NW.FireServer("RollRune",b) end)
            rem-=b;runeStatus="Max rolling... "..rem.." left";task.wait(0.5)
        end
        runeStatus="Max done!"
    end)
end
local function buildRuneList()
    local lines={}
    local beans=Currency.Get("Beans")
    table.insert(lines,string.format("Beans: %d | Cost: %d | Max: %d",beans,RUNE_COST,math.floor(beans/RUNE_COST)))
    table.insert(lines,"──────────────────────")
    local ok,data=pcall(function() return GetRunes:InvokeServer() end)
    if not ok or not data then return table.concat(lines,"\n").."\nFailed to load" end
    local owned={}
    for name,rune in pairs(data.Runes or {}) do
        local info=RUNE_INFO[name] or {stat="?",kind="?",rar="???"}
        local xpStr=rune.Level>=RUNE_MAX_LV and"MAX"or(tostring(rune.Xp).."xp")
        table.insert(owned,string.format("[%s] %s Lv%d — %s %s | %s",
            info.rar,name,rune.Level,info.stat,info.kind,xpStr))
    end
    table.sort(owned)
    for _,l in ipairs(owned) do table.insert(lines,l) end
    return table.concat(lines,"\n")
end

-- ===== Fusion =====
-- FuseHero's server validator (shared.Fusion.Fusion.BuildPlan) rejects before
-- touching inventory if fromStar/size don't check out, so a bad call is a
-- silent no-op, not a wasted dupe. Riding the game's own GetOwnedBuckets +
-- GetNextFusableStar means the args are exactly what FusionView would send.
local fuseStatus="Idle"
local function autoFuseTick()
    if not e.aFuse then fuseStatus="Off";return end
    local ok,buckets=pcall(function() return Inv.GetOwnedBuckets() end)
    if not ok or not buckets then fuseStatus="Error reading inventory";return end
    local did=0
    for _,b in ipairs(buckets) do
        local ok2,entry=pcall(function() return Inv.GetHeroEntry(b.HeroId) end)
        local sz=ok2 and entry and entry.Sizes and entry.Sizes[b.Size]
        if sz then
            local ok3,star=pcall(function() return FSH.GetNextFusableStar(sz) end)
            if ok3 and star then
                pcall(function() FCL.RequestFuse(b.HeroId,b.Size,star,{}) end)
                did+=1
            end
        end
    end
    fuseStatus=did>0 and("Fused "..did.." batch(es) this pass")or"Nothing fusable"
end
task.spawn(function() while e.__G==G do autoFuseTick();task.wait(2) end end)

-- ===== Craft =====
-- Reuses Crafting.MaxAffordable(recipe, Items.GetCount) verbatim -- the exact
-- function CraftingView calls -- instead of re-deriving cost math. GetCraftDaily
-- returns USED counts per recipe Id (confirmed live: Hammer showed 2 with
-- DailyLimit=2, i.e. already exhausted today), not remaining, so remaining is
-- DailyLimit-used, clamped at 0. CraftItem is rate-limited 5 calls/sec server-side --
-- staggered 0.3s apart here so a full-list selection can't burst past it.
local craftStatus="Idle"
local function autoCraftTick()
    if not e.aCraft then craftStatus="Off";return end
    local list=e.aCraftList
    if not list or #list==0 then craftStatus="On, but nothing selected";return end
    local ok,daily=pcall(function() return NW.InvokeServer("GetCraftDaily") end)
    if not ok or type(daily)~="table" then daily={} end
    local did=0
    for _,id in ipairs(list) do
        local recipe=Crafting.GetRecipe(id)
        if recipe then
            local ok2,afford=pcall(function() return Crafting.MaxAffordable(recipe,Items.GetCount) end)
            if ok2 and afford and afford>0 then
                local remaining=afford
                if recipe.DailyLimit then
                    remaining=math.min(remaining,math.max(0,recipe.DailyLimit-(daily[id]or 0)))
                end
                if remaining>=1 then
                    pcall(function() NW.InvokeServer("CraftItem",id,remaining) end)
                    did+=1
                    task.wait(0.3)
                end
            end
        end
    end
    craftStatus=did>0 and("Crafted "..did.." recipe(s) this pass")or"Nothing craftable right now"
end
task.spawn(function() while e.__G==G do autoCraftTick();task.wait(5) end end)

-- ===== Tower =====
-- EnterTower takes the TIER number (not a raw floor) -- confirmed from Tower.lua's
-- own selector (u202) feeding straight into Network.InvokeServer("EnterTower", u202).
-- Run-active state (e.__InTower) comes from the TowerDelta listener above, so this
-- never re-enters mid-run. enteringUntil is a local debounce on top of that in case
-- the delta hasn't arrived yet -- EnterTower is rate-limited 5/5s so nothing exotic,
-- just cheap insurance against double-spending a key on a race.
local towerStatus="Idle"
local towerRanOut=false
local towerEnteringUntil=0
local function autoTowerTick()
    if not e.aTower then towerStatus="Off";towerRanOut=false;return end
    -- Run-active check comes FIRST, before the keys check. EnterTower spends a key
    -- immediately, so Currency.Get("TowerKeys") reads 0 the moment a run starts on
    -- your last key -- checking keys first was reading that as "ran out", firing
    -- LeaveTower on a run that had 240s left on the clock. A run already paid for
    -- runs to completion regardless of what the wallet says.
    if e.__InTower or os.clock()<towerEnteringUntil then
        towerRanOut=false
        towerStatus="In tower (floor "..tostring(e.__TowerFloor or"?")..")"
        return
    end
    local keys=0
    pcall(function() keys=Currency.Get("TowerKeys") end)
    if keys<=0 then
        if not towerRanOut then
            towerRanOut=true
            if e.aTowerBackToFarm then
                local h=hh()
                if h and e.fSpt then pcall(function() h.CFrame=t2c(e.fSpt) end);towerStatus="Out of keys -- back to farm spot"
                else towerStatus="Out of keys -- no farm spot saved (Boss tab)" end
            else
                towerStatus="Out of keys"
            end
        end
        return
    end
    towerRanOut=false
    -- Boss wins the handoff on the way back in: e.__IBA is chkBoss's own "currently
    -- warped to the boss arena" flag. Holding off here means a boss that shows up
    -- right as a tower run ends gets fought first -- tower resumes the moment
    -- chkBoss clears __IBA and returns the player to the farm spot.
    if e.aBoss and e.__IBA then
        towerStatus="Boss fight in progress -- tower paused"
        return
    end
    towerEnteringUntil=os.clock()+6
    local ok,res=pcall(function() return NW.InvokeServer("EnterTower",e.aTowerTier or 1) end)
    if ok and type(res)=="table" and res.ok then
        towerStatus="Entered tier "..(e.aTowerTier or 1).." (floor "..tostring(res.floor or"?")..")"
    else
        towerEnteringUntil=0
        towerStatus="Enter failed"..((ok and type(res)=="table" and res.err)and(": "..tostring(res.err))or"")
    end
end
task.spawn(function() while e.__G==G do autoTowerTick();task.wait(3) end end)

-- BuyTowerUpgrade is rate-limited 10 calls/5s server-side; capped at 8/tick with a
-- 6s tick interval so consecutive ticks never share a rate-limit window. Round-robins
-- the selected upgrades so one maxed/unaffordable id doesn't starve the others.
local towerUpgStatus="Idle"
local function autoTowerUpgradeTick()
    if not e.aTowerUpgOn then towerUpgStatus="Off";return end
    local sel=e.aTowerUpg
    if not sel or #sel==0 then towerUpgStatus="On, but nothing selected";return end
    local pool={}
    for _,id in ipairs(sel) do table.insert(pool,id) end
    local bought=0
    local budget=8
    while budget>0 and #pool>0 do
        local id=pool[1]
        local ok,res=pcall(function() return NW.InvokeServer("BuyTowerUpgrade",id) end)
        budget-=1
        if not ok or not res or(type(res)=="table"and res.err)then
            table.remove(pool,1)
        else
            bought+=1
            table.remove(pool,1);table.insert(pool,id)
            task.wait(0.1)
        end
    end
    towerUpgStatus=bought>0 and("Bought "..bought.." level(s) this pass")or"Nothing affordable right now"
end
task.spawn(function() while e.__G==G do autoTowerUpgradeTick();task.wait(6) end end)

-- ===== UI =====
print("[RNG] Loading UI...")
-- Used to cache e.__LIB across reloads to skip the re-fetch -- but this script
-- Unloads the previous window (line 2) before ever touching __LIB, and a
-- cached lib bound to an already-unloaded window is exactly the "stale lib
-- after unload = invisible window" trap other scripts in this repo already
-- learned to avoid. Force a fresh fetch every load instead; the HttpGet cost
-- is a couple seconds, not worth a silent/broken window.
local ok,lib=pcall(function()
    return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not ok or not lib then print("[RNG] MacLib failed: "..tostring(lib)) return end
e.__LIB=lib
local Lib=e.__LIB
print("[RNG] MacLib loaded, building window...")
task.wait()
if e.__G~=G or e.__tok~=myUID then print("[RNG] Aborted") return end
pcall(function() if e.__W then e.__W:Unload() end end)

local W=Lib:Window({Title="RNG Heroes",Subtitle="v6.4",DragStyle=1,ShowUserInfo=true,AcrylicBlur=false})
local TG=W:TabGroup()
local TA  =TG:Tab({Name="Auto",    Image="rbxassetid://10723343321"})
local TPr =TG:Tab({Name="Prestige",Image="rbxassetid://10734963191"})
local TH  =TG:Tab({Name="Heroes",  Image="rbxassetid://6022668955"})
local TB  =TG:Tab({Name="Boss",    Image="rbxassetid://10734975692"})
local TRune=TG:Tab({Name="Runes",  Image="rbxassetid://10723343321"})
local TC  =TG:Tab({Name="Craft",   Image="rbxassetid://10723343321"})
local TW  =TG:Tab({Name="Tower",   Image="rbxassetid://10723343321"})
local TM  =TG:Tab({Name="Misc",    Image="rbxassetid://10723343321"})

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
HL:Dropdown({
    Name="  Ignore DMG",Multi=true,Options={"Boss","Tower"},Default=e.hDmgIgn,
    Callback=function(sel)
        local list={}
        for id in pairs(sel) do table.insert(list,id) end
        table.sort(list)
        e.hDmgIgn=list;sv()
    end,
},"hDmgIgn")
HL:Toggle({Name="Atk Speed x1000",Default=e.hSpd,Callback=function(v) e.hSpd=v;sv() end},"hSpd")
HL:Dropdown({
    Name="  Ignore ATK",Multi=true,Options={"Boss","Tower"},Default=e.hSpdIgn,
    Callback=function(sel)
        local list={}
        for id in pairs(sel) do table.insert(list,id) end
        table.sort(list)
        e.hSpdIgn=list;sv()
    end,
},"hSpdIgn")
HL:Header({Text="Fusion"})
HL:Toggle({Name="Auto Fuse",Default=e.aFuse,Callback=function(v) e.aFuse=v;sv() end},"aFuse")
local fuseLbl=HL:Label({Text="Idle"})
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

-- Runes tab
local RLeft=TRune:Section({Side="Left"})
RLeft:Header({Text="Roll Runes"})
RLeft:Button({Name="Roll x1",   Callback=function() rollRune(1) end})
RLeft:Button({Name="Roll x10",  Callback=function() rollRune(10) end})
RLeft:Button({Name="Roll x100", Callback=function() rollRune(100) end})
RLeft:Button({Name="Roll Max",  Callback=function() rollMax() end})
RLeft:Header({Text="Auto Open"})
RLeft:Toggle({
    Name="Auto Open Rune",Default=e.aRune,
    Callback=function(v) e.aRune=v;sv() end,
},"aRune")
RLeft:Dropdown({
    Name="Amount",Multi=false,Options={"1","10","100"},
    Default=tostring(e.aRuneAmt or 1),
    Callback=function(v) e.aRuneAmt=tonumber(type(v)=="table" and v[1] or v) or 1;sv() end,
})
local runeStatusLbl=RLeft:Label({Text="Idle"})
local beansLbl=RLeft:Label({Text="Beans: ?"})

local RRight=TRune:Section({Side="Right"})
RRight:Header({Text="Your Runes"})
local runeListLbl=RRight:Label({Text="Loading..."})
RRight:Button({Name="Refresh",Callback=function()
    pcall(function() runeListLbl:UpdateName(buildRuneList()) end)
end})
RRight:Label({Text="Rune Effects Reference:\nBean — BeanFind x (Rare)\nBlade — HeroDamage x (Rare)\nCrit — CritChance + (Epic)\nFortune — Luck x (Legendary)\nGreed — Gold x (Epic)\nHavoc — CritDamage + (Legendary)\nSwift — HeroAttackSpeed x (Rare)\nWisdom — XP x (Epic)"})

-- Craft tab
local CL=TC:Section({Side="Left"})
CL:Header({Text="Auto Craft  (5 calls/sec cap, staggered)"})
CL:Toggle({Name="Auto Craft",Default=e.aCraft,Callback=function(v) e.aCraft=v;sv() end},"aCraft")
local craftIds={}
pcall(function() for _,r in ipairs(Crafting.GetOrderedRecipes()) do table.insert(craftIds,r.Id) end end)
CL:Dropdown({
    Name="Recipes",Multi=true,Options=craftIds,Default=e.aCraftList or {},
    Callback=function(sel)
        local list={}
        for id in pairs(sel) do table.insert(list,id) end
        table.sort(list)
        e.aCraftList=list;sv()
    end,
})
local craftLbl=CL:Label({Text="Idle"})
local CR=TC:Section({Side="Right"})
CR:Header({Text="Recipe Reference"})
local recipeRefLines={}
pcall(function()
    for _,r in ipairs(Crafting.GetOrderedRecipes()) do
        local costParts={}
        for mat,amt in pairs(r.Costs or{}) do table.insert(costParts,amt.."x"..mat) end
        table.sort(costParts)
        local lim=r.DailyLimit and(" (daily "..r.DailyLimit..")")or""
        table.insert(recipeRefLines,string.format("%s -> %s [%s]%s",r.Id,r.Output or r.OutputCurrency or"?",table.concat(costParts,","),lim))
    end
end)
table.sort(recipeRefLines)
CR:Label({Text=#recipeRefLines>0 and table.concat(recipeRefLines,"\n")or"Failed to load"})

-- Tower tab
local WL=TW:Section({Side="Left"})
WL:Header({Text="Auto Tower"})
WL:Toggle({
    Name="Auto Tower",Default=e.aTower,
    Callback=function(v)
        e.aTower=v;sv()
        if not v and e.__InTower then
            pcall(function() NW.FireServer("LeaveTower") end)
            local h=hh()
            if h and e.fSpt then pcall(function() h.CFrame=t2c(e.fSpt) end) end
        end
    end,
},"aTower")
local towerTierOpts={}
local towerTierLookup={}
pcall(function()
    local ts=NW.InvokeServer("GetTowerState")
    local maxTier=(type(ts)=="table" and ts.maxTier) or 1
    for i=1,math.min(maxTier,30) do
        local dps=0
        pcall(function() dps=TowerData.GetTierClearDPS(i) end)
        local label=("Tier %d (DMG Require %s)"):format(i,fmt(dps))
        table.insert(towerTierOpts,label)
        towerTierLookup[label]=i
    end
end)
if #towerTierOpts==0 then towerTierOpts={"Tier 1 (DMG Require ?)"};towerTierLookup[towerTierOpts[1]]=1 end
WL:Dropdown({
    Name="Tier",Multi=false,Options=towerTierOpts,
    Default=towerTierOpts[math.min(e.aTowerTier or 1,#towerTierOpts)],
    Callback=function(v) e.aTowerTier=towerTierLookup[v] or 1;sv() end,
})
local towerLbl=WL:Label({Text="Idle"})
WL:Toggle({Name="Back to Farm on Empty Keys",Default=e.aTowerBackToFarm,Callback=function(v) e.aTowerBackToFarm=v;sv() end},"aTowerBackToFarm")
WL:Label({Text="Uses the Boss tab's Farm Spot as the return point."})
local WR=TW:Section({Side="Right"})
WR:Header({Text="Auto Upgrade Tower  (10 calls/5s cap)"})
WR:Toggle({Name="Auto Upgrade",Default=e.aTowerUpgOn,Callback=function(v) e.aTowerUpgOn=v;sv() end},"aTowerUpgOn")
WR:Dropdown({
    Name="Upgrades",Multi=true,Options={"Damage","Luck","Gold","XP"},Default=e.aTowerUpg or {},
    Callback=function(sel)
        local list={}
        for id in pairs(sel) do table.insert(list,id) end
        table.sort(list)
        e.aTowerUpg=list;sv()
    end,
})
local towerUpgLbl=WR:Label({Text="Idle"})

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

-- ===== Update loops =====
task.spawn(function()
    task.wait(2)
    pcall(function() runeListLbl:UpdateName(buildRuneList()) end)
    while e.__G==G do
        if e.aRune then
            rollRune(e.aRuneAmt or 1)
            task.wait(0.35)
        else
            task.wait(0.3)
        end
        pcall(function() runeStatusLbl:UpdateName(runeStatus) end)
        pcall(function()
            local b=Currency.Get("Beans")
            beansLbl:UpdateName(string.format("Beans: %d | Max: %d",b,math.floor(b/RUNE_COST)))
        end)
    end
end)

task.spawn(function()
    while e.__G==G do
        task.wait(15)
        pcall(function() runeListLbl:UpdateName(buildRuneList()) end)
    end
end)

task.spawn(function()
    while e.__G==G do
        task.wait(1)
        pcall(function() fuseLbl:UpdateName(fuseStatus) end)
        pcall(function() craftLbl:UpdateName(craftStatus) end)
        pcall(function() towerLbl:UpdateName(towerStatus) end)
        pcall(function() towerUpgLbl:UpdateName(towerUpgStatus) end)
    end
end)

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
        local hd=e.hDmg and(((table.find(e.hDmgIgn or{},"Boss")and e.__BSA)or(table.find(e.hDmgIgn or{},"Tower")and e.__InTower))and"SKIP"or"INF")or"ok"
        local hs=e.hSpd and(((table.find(e.hSpdIgn or{},"Boss")and e.__BSA)or(table.find(e.hSpdIgn or{},"Tower")and e.__InTower))and"SKIP"or"x1k")or"ok"
        pcall(function() heroLbl:UpdateName("HP:"..hg.."  DMG:"..hd.."  ATK:"..hs) end)
        pcall(function() bsLbl:UpdateName("Boss: "..(e.__BSA and"ACTIVE"or"none")) end)
        task.wait(3)
    end
end)

e.__W=W
TA:Select()
print("[RNG] v6.4 OK")