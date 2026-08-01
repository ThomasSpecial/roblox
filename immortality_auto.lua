-- [Immortality Incremental] Auto Script v2.3
-- Individual mark toggles + Karma NoCooldown + Ghost Snap + Auto Star + Auto Redeem Codes

local G=(getgenv().__IG or 0)+1; getgenv().__IG=G
pcall(function() if getgenv().__IW and getgenv().__IW.Unload then getgenv().__IW:Unload() end end)
getgenv().__LIB = nil  -- force fresh MacLib every load (stale lib after unload = invisible window)

local LP        = game:GetService("Players").LocalPlayer
local RS        = game:GetService("ReplicatedStorage")
local VU        = game:GetService("VirtualUser")
local UIS       = game:GetService("UserInputService")
local TSvc      = game:GetService("TeleportService")
local RunService= game:GetService("RunService")
local TweenSvc  = game:GetService("TweenService")
local RE  = RS:WaitForChild("RemoteEvents",10)
if not RE then print("[IM] ERROR: RemoteEvents not found"); return end

local e = getgenv()
if e.IM_soulFocusList==nil then e.IM_soulFocusList={"Essence"} end
if e.IM_beastStage==nil then e.IM_beastStage=tostring(LP:GetAttribute("BeastHighestStage") or 1) end
if e.IM_soulFocus==nil  then e.IM_soulFocus="Essence" end
if e.IM_starMethod==nil then e.IM_starMethod="TP" end
if e.IM_starDelay==nil  then e.IM_starDelay=0.15 end
-- Mark toggles: nil-check only (persist between reloads, default false on first load)
local MARK_KEYS={"IM_mark_Insight","IM_mark_Essence","IM_mark_Karma","IM_mark_Soulfire","IM_mark_Stars","IM_mark_Laws","IM_mark_Nebula","IM_mark_Quasar","IM_mark_Miasma","IM_mark_Vitality","IM_mark_Anima","IM_mark_Ash","IM_mark_Divinity","IM_mark_Faith"}
for _,k in ipairs(MARK_KEYS) do if e[k]==nil then e[k]=false end end
-- Hard-reset every load
e.IM_autoRealm     = false
e.IM_autoTemper    = false
e.IM_antiAfk       = true
e.IM_autoRec       = true
e.IM_autoQi        = false
e.IM_autoInsight   = false
e.IM_autoEssence   = false
e.IM_autoSoul      = false
e.IM_autoBeast     = false
e.IM_autoBeastUpg  = false
e.IM_autoJade      = false
e.IM_autoBlood     = false
e.IM_autoKarma     = false
e.IM_karmaNoCD     = true
e.IM_autoStar      = false
e.IM_minKey        = "RightShift"
-- Persist counters across reloads (nil-check)
if e.__IM_starCollected==nil then e.__IM_starCollected=0 end

local function R(name) return RE:FindFirstChild(name) end
local function fire(name,...)
    local args={...}
    local r=R(name)
    if r then pcall(function() r:FireServer(table.unpack(args)) end) end
end

local function keyCodeName(k)
    if type(k)=="string" then return k end
    local s=tostring(k)
    return s:match("Enum%.KeyCode%.(.+)") or s
end

-- ============================================================
-- Ghost Snap: teleport char invisibly, camera locked in place
-- Server detects physics touch; player sees nothing move.
-- Only one snap runs at a time (snapping flag as mutex).
-- ============================================================
local snapping = false
local function ghostSnap(targetCF, duration)
    if snapping then return end
    snapping = true
    local char = LP.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then snapping = false; return end

    local savedHRP     = hrp.CFrame
    local savedAnchored= hrp.Anchored
    local cam          = workspace.CurrentCamera
    local savedCamCF   = cam.CFrame

    -- 1. Hide all BaseParts of character (client-side only)
    local restore = {}
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            restore[part] = part.LocalTransparencyModifier
            part.LocalTransparencyModifier = 1
        end
    end

    -- 2. Lock camera via RenderStepped so PlayerModule cannot override
    local camConn = RunService.RenderStepped:Connect(function()
        cam.CameraType = Enum.CameraType.Scriptable
        cam.CFrame     = savedCamCF
    end)

    -- 3. Teleport and anchor for the hold -- unanchored, default gravity
    -- (~196 studs/s^2) pulls the HRP ~2 studs off target in just 0.15s,
    -- which is the entire Star Forging COLLECTION_RADIUS (2 studs). Verified
    -- live this was making star collection unreliable; anchoring during the
    -- hold keeps the character exactly on the target the whole time.
    pcall(function()
        hrp.CFrame = targetCF
        hrp.Anchored = true
    end)

    -- 4. Hold for required duration, but in small increments checking the
    -- script generation -- if the script gets re-executed while this call is
    -- still mid-hold, "snapping" here is a local to the OLD closure and the
    -- new script's own copy has no idea this is running, so without this
    -- check two independent camera locks could run concurrently and fight
    -- over CameraType/CFrame, leaving the screen stuck. Bail out early and
    -- still run the cleanup below either way.
    local waited = 0
    while waited < duration do
        if getgenv().__IG ~= G then break end
        local step = math.min(0.05, duration - waited)
        task.wait(step)
        waited += step
    end

    -- 5. Return to original position
    pcall(function()
        hrp.Anchored = savedAnchored
        hrp.CFrame = savedHRP
    end)

    -- 6. Restore transparency
    for part, val in pairs(restore) do
        pcall(function()
            if part and part.Parent then
                part.LocalTransparencyModifier = val
            end
        end)
    end

    -- 7. Restore camera
    camConn:Disconnect()
    cam.CameraType = Enum.CameraType.Custom

    snapping = false
end

-- ============================================================
-- Ghost Batch: same idea as ghostSnap, but hides/locks/anchors ONCE for a
-- whole list of target CFrames instead of once per target. ghostSnap called
-- back-to-back per star was the cause of the visible flicker -- every single
-- star triggered a full hide -> show -> hide cycle for the local player.
-- Batching means the character disappears once, visits every target while
-- still hidden, then reappears once at the end.
-- ============================================================
-- mode "TP"    = instant snap per target (fastest)
-- mode "Tweak" = smoothly tween the hidden HRP between targets instead of
--                snapping -- character is invisible either way so this looks
--                identical locally, but a smooth move rather than a string of
--                instant teleports may replicate/pass server checks more
--                consistently if "TP" mode ever proves unreliable.
local function ghostBatch(targets, holdEach, gapEach, mode)
    if snapping or #targets == 0 then return end
    snapping = true
    local char = LP.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then snapping = false; return end

    local savedHRP      = hrp.CFrame
    local savedAnchored = hrp.Anchored
    local cam            = workspace.CurrentCamera
    local savedCamCF     = cam.CFrame

    local restore = {}
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            restore[part] = part.LocalTransparencyModifier
            part.LocalTransparencyModifier = 1
        end
    end

    local camConn = RunService.RenderStepped:Connect(function()
        cam.CameraType = Enum.CameraType.Scriptable
        cam.CFrame     = savedCamCF
    end)

    for _, targetCF in ipairs(targets) do
        if not e.IM_autoStar then break end
        -- Same generation guard as ghostSnap -- bail out of the loop (still
        -- runs cleanup below) if a newer script instance has taken over, so
        -- an old, stuck-in-progress batch can't keep the camera locked.
        if getgenv().__IG ~= G then break end
        if mode=="Tweak" then
            -- Tween while unanchored (keeps replicating every frame of the
            -- move, not just start/end), then anchor once landed to hold.
            pcall(function() hrp.Anchored = false end)
            local tw = TweenSvc:Create(hrp, TweenInfo.new(math.max(holdEach*0.6,0.05), Enum.EasingStyle.Linear), {CFrame = targetCF})
            tw:Play()
            tw.Completed:Wait()
            pcall(function() hrp.Anchored = true end)
        else
            -- Set CFrame FIRST while still unanchored -- HumanoidRootPart
            -- position changes only replicate to the server reliably through
            -- normal client network ownership, which anchoring suppresses.
            -- Anchoring only AFTER the position lands (to hold it steady
            -- against gravity for the brief collection window) keeps every
            -- star's position visible to the server.
            pcall(function()
                hrp.Anchored = false
                hrp.CFrame = targetCF
                hrp.Anchored = true
            end)
        end
        task.wait(holdEach)
        task.wait(gapEach)
    end

    pcall(function()
        hrp.Anchored = false
        hrp.CFrame = savedHRP
        hrp.Anchored = savedAnchored
    end)

    for part, val in pairs(restore) do
        pcall(function()
            if part and part.Parent then
                part.LocalTransparencyModifier = val
            end
        end)
    end

    camConn:Disconnect()
    cam.CameraType = Enum.CameraType.Custom

    snapping = false
end

-- ============================================================
-- Walk Collect: real Humanoid:MoveTo() pathing, character fully visible the
-- whole time. No hide, no camera lock, no anchoring -- so zero flicker.
-- Uses the same "snapping" mutex so it still yields to Karma NoCD hold.
-- The Hold Delay slider (0.1-1.0) drives actual WalkSpeed here -- 0.1 =
-- fastest (WALK_SPEED_MAX), 1.0 = normal (WALK_SPEED_MIN) -- so "delay"
-- means the same thing across every method: lower = more aggressive.
-- ============================================================
local WALK_SPEED_MIN, WALK_SPEED_MAX = 16, 50
local function walkCollectStars(targets, holdEach)
    if snapping or #targets == 0 then return end
    snapping = true
    local char = LP.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not (hum and hrp) then snapping = false; return end

    local savedWalkSpeed = hum.WalkSpeed
    local t = math.clamp((holdEach - 0.1) / 0.9, 0, 1) -- 0 at delay=0.1, 1 at delay=1.0
    pcall(function() hum.WalkSpeed = WALK_SPEED_MAX - t * (WALK_SPEED_MAX - WALK_SPEED_MIN) end)

    for _, targetCF in ipairs(targets) do
        if not e.IM_autoStar then break end
        if getgenv().__IG ~= G then break end
        local targetPos = targetCF.Position
        local reached, conn = false, nil
        pcall(function()
            conn = hum.MoveToFinished:Connect(function() reached = true end)
            hum:MoveTo(targetPos)
        end)
        local waited = 0
        local timeout = 3 -- generous cap in case a star is unreachable/blocked
        while not reached and waited < timeout do
            if getgenv().__IG ~= G then break end
            task.wait(0.1)
            waited += 0.1
        end
        if conn then conn:Disconnect() end
        -- No settle wait -- move to the next star the instant this one is
        -- reached (collection is a continuous proximity check, not a
        -- one-time touch, so there's nothing to wait for here).
    end

    pcall(function() hum.WalkSpeed = savedWalkSpeed end)
    snapping = false
end

-- ============================================================
-- Find the star visuals folder. StarForgingConfig.RUNTIME_FOLDER_NAME
-- ("StarCollectibles") is a stale/unused name -- verified live that the
-- current client (StarForgingClient.lua) actually parents each spawned star
-- under workspace.StarForgingLocalVisuals (StarForgingConfig.LOCAL_VISUAL_
-- FOLDER_NAME), named "Star_<id>". That folder also holds a non-star
-- "StarCollectionRange" indicator disc (from StarCollectionRangeClient.lua),
-- so callers must filter children to the "Star_" name prefix.
-- ============================================================
local function findStarFolder()
    return workspace:FindFirstChild("StarForgingLocalVisuals")
end

-- Greedy nearest-neighbor route: repeatedly pick whichever remaining target
-- is closest to "wherever we'd currently be", starting from the player's
-- real position. For a handful of points (max ~5-9 per batch) this gives a
-- route close to optimal without needing a real TSP solver, and it matters
-- most for Walk mode where distance = real travel time.
local function sortTargetsByNearest(targets, startPos)
    local remaining = {}
    for i, t in ipairs(targets) do remaining[i] = t end
    local ordered = {}
    local currentPos = startPos
    while #remaining > 0 do
        local bestIdx, bestDist = 1, math.huge
        for i, t in ipairs(remaining) do
            local d = (t.Position - currentPos).Magnitude
            if d < bestDist then bestDist = d; bestIdx = i end
        end
        local chosen = table.remove(remaining, bestIdx)
        table.insert(ordered, chosen)
        currentPos = chosen.Position
    end
    return ordered
end

local MARKS = {
    {id="Insight",  remote="InsightMarkPress",  key="IM_mark_Insight"},
    {id="Essence",  remote="EssenceMarkPress",  key="IM_mark_Essence"},
    {id="Karma",    remote="KarmaMarkPress",    key="IM_mark_Karma"},
    {id="Soulfire", remote="SoulfireMarkPress", key="IM_mark_Soulfire"},
    {id="Stars",    remote="StarsMarkPress",    key="IM_mark_Stars"},
    {id="Laws",     remote="LawsMarkPress",     key="IM_mark_Laws"},
    {id="Nebula",   remote="NebulaMarkPress",   key="IM_mark_Nebula"},
    {id="Quasar",   remote="QuasarMarkPress",   key="IM_mark_Quasar"},
    {id="Miasma",   remote="MiasmaMarkPress",   key="IM_mark_Miasma"},
    {id="Vitality", remote="VitalityMarkPress", key="IM_mark_Vitality"},
    {id="Anima",    remote="AnimaMarkPress",    key="IM_mark_Anima"},
    {id="Ash",      remote="AshMarkPress",      key="IM_mark_Ash"},
    {id="Divinity", remote="DivinityMarkPress", key="IM_mark_Divinity"},
    {id="Faith",    remote="FaithMarkPress",    key="IM_mark_Faith"},
}

local QI_UPG      = {"QiMultiplier","BreakthroughLuck","MarkBulk"}
local INSIGHT_UPG = {"InsightMultiplier","InsightQiMultiplier","InsightLuckMultiplier","InsightMarkSpeed"}
local ESSENCE_UPG = {
    "EssenceYield","MoteFlow","CauldronFocus","RefinementLink",
    "EssenceLuckMultiplier","EssenceQiMultiplier","EssenceInsightMultiplier",
}
local SOUL_UPG = {
    "SoulEssenceMultiplier","SoulLuckMultiplier","SoulQiMultiplier",
    "SoulfireKarmaMultiplier","SoulAutomationUnlock",
    "SoulAutoBreakthrough","SoulAutoInsightGain",
    "SoulAutoBuyQiUpgrades","SoulAutoBuyInsightUpgrades","SoulAutoBuyEssenceUpgrades",
}
local BEAST_UPG = {"BeastDamage","BeastAttackInterval","BeastTimerExtension","BeastRemnantYield","ApexPursuit"}
local JADE_UPG  = {
    "JadeQiMultiplier","JadeLuckMultiplier","JadeInsightMultiplier",
    "JadeEssenceMultiplier","JadeSoulfireMultiplier",
}

local function fmtBig(m,ex)
    local v=m*(10^ex)
    if     ex>=15 then return string.format("%.2fQ",v/1e15)
    elseif ex>=12 then return string.format("%.2fT",v/1e12)
    elseif ex>=9  then return string.format("%.2fB",v/1e9)
    elseif ex>=6  then return string.format("%.1fM",v/1e6)
    elseif ex>=3  then return string.format("%.0fK",v/1e3)
    else               return string.format("%.0f",v) end
end

local function getAttrBig(attr)
    local m=LP:GetAttribute(attr.."Mantissa") or 0
    local ex=LP:GetAttribute(attr.."Exponent") or 0
    return fmtBig(m,ex)
end

local function getMarkInterval()
    local m=LP:GetAttribute("MarkSpeedMantissa") or 1
    local ex=LP:GetAttribute("MarkSpeedExponent") or 0
    local rate=m*(10^ex)
    return math.max(0.05,1/math.max(rate,1))
end

print("[IM] v2.3 Loading MacLib...")
if not e.__LIB then
    local ok,lib=pcall(function()
        return loadstring(game:HttpGet(
            "https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
    end)
    if not ok or not lib then print("[IM] MacLib load failed -- aborting"); return end
    e.__LIB=lib
end
local Lib=e.__LIB
task.wait()
if getgenv().__IG~=G then print("[IM] Aborted (newer instance)"); return end

local W=Lib:Window({Title="Immortality Auto",Subtitle="v2.3",DragStyle=1,ShowUserInfo=true,AcrylicBlur=false})
e.__IW=W
local TG=W:TabGroup()
local ICON="rbxassetid://10723407389"
local TM  =TG:Tab({Name="Marks",     Image=ICON})
local TQ  =TG:Tab({Name="Qi",        Image=ICON})
local TI  =TG:Tab({Name="Insight",   Image=ICON})
local TE  =TG:Tab({Name="Essence",   Image=ICON})
local TSF =TG:Tab({Name="Soulfire",  Image=ICON})
local TK  =TG:Tab({Name="Karma",     Image=ICON})
local TB  =TG:Tab({Name="Beast",     Image=ICON})
local TJB =TG:Tab({Name="Jade/Blood",Image=ICON})
local TSD =TG:Tab({Name="Stars",     Image=ICON})
local TST =TG:Tab({Name="Settings",  Image=ICON})

-- ============================================================
-- TAB: MARKS
-- ============================================================
local ML=TM:Section({Side="Left"})
local MR=TM:Section({Side="Right"})

ML:Header({Text="Auto Marks (1 / 2)"})
ML:Toggle({Name="Insight",  Default=e.IM_mark_Insight,  Callback=function(v) e.IM_mark_Insight=v  end})
ML:Toggle({Name="Essence",  Default=e.IM_mark_Essence,  Callback=function(v) e.IM_mark_Essence=v  end})
ML:Toggle({Name="Karma",    Default=e.IM_mark_Karma,    Callback=function(v) e.IM_mark_Karma=v    end})
ML:Toggle({Name="Soulfire", Default=e.IM_mark_Soulfire, Callback=function(v) e.IM_mark_Soulfire=v end})
ML:Toggle({Name="Stars",    Default=e.IM_mark_Stars,    Callback=function(v) e.IM_mark_Stars=v    end})
ML:Toggle({Name="Laws",     Default=e.IM_mark_Laws,     Callback=function(v) e.IM_mark_Laws=v     end})
ML:Toggle({Name="Nebula",   Default=e.IM_mark_Nebula,   Callback=function(v) e.IM_mark_Nebula=v   end})

ML:Header({Text="Realm / Temper"})
ML:Toggle({Name="Auto Realm Press",              Default=e.IM_autoRealm,  Callback=function(v) e.IM_autoRealm=v  end})
ML:Toggle({Name="Auto Temper (ClaimRefinement)", Default=e.IM_autoTemper, Callback=function(v) e.IM_autoTemper=v end})

MR:Header({Text="Auto Marks (2 / 2)"})
MR:Toggle({Name="Quasar",   Default=e.IM_mark_Quasar,   Callback=function(v) e.IM_mark_Quasar=v   end})
MR:Toggle({Name="Miasma",   Default=e.IM_mark_Miasma,   Callback=function(v) e.IM_mark_Miasma=v   end})
MR:Toggle({Name="Vitality", Default=e.IM_mark_Vitality, Callback=function(v) e.IM_mark_Vitality=v end})
MR:Toggle({Name="Anima",    Default=e.IM_mark_Anima,    Callback=function(v) e.IM_mark_Anima=v    end})
MR:Toggle({Name="Ash",      Default=e.IM_mark_Ash,      Callback=function(v) e.IM_mark_Ash=v      end})
MR:Toggle({Name="Divinity", Default=e.IM_mark_Divinity, Callback=function(v) e.IM_mark_Divinity=v end})
MR:Toggle({Name="Faith",    Default=e.IM_mark_Faith,    Callback=function(v) e.IM_mark_Faith=v    end})

MR:Header({Text="Status"})
local mSpeedLbl  =MR:Label({Text="Speed: ?"})
local mActiveLbl =MR:Label({Text="Active: ?"})
local mAttemptLbl=MR:Label({Text="Attempts: ?"})
local mLuckLbl   =MR:Label({Text="BrkLuck: ?"})
e.IM_mSpeedLbl=mSpeedLbl; e.IM_mActiveLbl=mActiveLbl
e.IM_mAttemptLbl=mAttemptLbl; e.IM_mLuckLbl=mLuckLbl

-- ============================================================
-- TAB: QI
-- ============================================================
local QL=TQ:Section({Side="Left"})
local QR=TQ:Section({Side="Right"})

QL:Header({Text="Qi Upgrades (PurchaseUpgrade)"})
QL:Toggle({Name="Auto Buy Qi Upgrades",Default=e.IM_autoQi,
    Callback=function(v) e.IM_autoQi=v end})

QL:Header({Text="Upgrades Included"})
QL:Label({Text="* More Qi  (QiMultiplier)"})
QL:Label({Text="* More Luck  (BreakthroughLuck)"})
QL:Label({Text="* More Mark Bulk  (MarkBulk)"})

QR:Header({Text="Qi Status"})
local qiValLbl  =QR:Label({Text="Qi: ?"})
local qiLuckLbl =QR:Label({Text="BrkLuck: ?"})
local qiBulkLbl =QR:Label({Text="Mark Bulk: ?"})
e.IM_qiValLbl=qiValLbl; e.IM_qiLuckLbl=qiLuckLbl; e.IM_qiBulkLbl=qiBulkLbl

-- ============================================================
-- TAB: INSIGHT
-- ============================================================
local IL=TI:Section({Side="Left"})
local IR=TI:Section({Side="Right"})

IL:Header({Text="Insight Upgrades (PurchaseInsight)"})
IL:Toggle({Name="Auto Buy Insight Upgrades",Default=e.IM_autoInsight,
    Callback=function(v) e.IM_autoInsight=v end})

IL:Header({Text="Upgrades Included"})
IL:Label({Text="* More Insight  (InsightMultiplier)"})
IL:Label({Text="* More Qi  (InsightQiMultiplier)"})
IL:Label({Text="* More Luck  (InsightLuckMultiplier)"})
IL:Label({Text="* More Mark Speed  (InsightMarkSpeed)"})

IL:Header({Text="Insight Reset"})
IL:Label({Text="Resets Qi & Insight -> gain Insight pts"})
IL:Label({Text="Requires Realm threshold to be met"})
IL:Button({Name="[R] Perform Insight Reset",Callback=function()
    fire("PurchaseInsight")
end})

IR:Header({Text="Insight Status"})
local insightLbl   =IR:Label({Text="Insight: ?"})
local insightRstLbl=IR:Label({Text="Reset gain: ?"})
e.IM_insightLbl=insightLbl; e.IM_insightRstLbl=insightRstLbl

-- ============================================================
-- TAB: ESSENCE
-- ============================================================
local EL=TE:Section({Side="Left"})
local ER=TE:Section({Side="Right"})

EL:Header({Text="Essence Upgrades (Primary)"})
EL:Toggle({Name="Auto Buy Essence Upgrades",Default=e.IM_autoEssence,
    Callback=function(v) e.IM_autoEssence=v end})
EL:Label({Text="* More Essence  (EssenceYield)"})
EL:Label({Text="* More Upgrades  (RefinementLink)"})
EL:Label({Text="* Essence Spawn Rate  (MoteFlow)"})
EL:Label({Text="* Essence Speed  (CauldronFocus)"})

EL:Header({Text="Extra Upgrades (Essence pts)"})
EL:Label({Text="* More Luck  (EssenceLuckMultiplier)"})
EL:Label({Text="* More Qi  (EssenceQiMultiplier)"})
EL:Label({Text="* More Insight  (EssenceInsightMultiplier)"})

ER:Header({Text="Essence Status"})
local essLbl     =ER:Label({Text="Essence: ?"})
local essSpawnLbl=ER:Label({Text="Spawn Int: ?"})
e.IM_essLbl=essLbl; e.IM_essSpawnLbl=essSpawnLbl

-- ============================================================
-- TAB: SOULFIRE
-- ============================================================
local SFL=TSF:Section({Side="Left"})
local SFR=TSF:Section({Side="Right"})

SFL:Header({Text="Soulfire Upgrades (PurchaseSoulfire)"})
SFL:Toggle({Name="Auto Buy Soulfire Upgrades",Default=e.IM_autoSoul,
    Callback=function(v) e.IM_autoSoul=v end})
SFL:Label({Text="* More Essence - More Luck - More Qi"})
SFL:Label({Text="* Karma Boost - Unlock Automations"})
SFL:Label({Text="* Auto Breakthrough - Passive Insight"})
SFL:Label({Text="* Auto Qi/Insight/Essence Upgrades"})

SFL:Header({Text="Soul Focus (auto-cycles selected)"})
local sfFocusDD=SFL:Dropdown({
    Name="Soul Focus",
    Options={"Essence","Qi","Luck"},
    Default=e.IM_soulFocusList,
    Multi=true,
    IgnoreConfig=true,
    Callback=function(v)
        e.IM_soulFocusList = type(v)=="table" and v or {v}
    end
})
pcall(function() sfFocusDD:UpdateSelection(e.IM_soulFocusList) end)
SFL:Label({Text="Selects multiple -> cycles every 30s"})

SFL:Header({Text="Soul Forging Reset"})
SFL:Label({Text="[!] Resets Realm - Qi - Insight - Essence"})
SFL:Label({Text="Converts Essence -> Soulfire"})
SFL:Label({Text="Requires SoulForgingUnlocked = true"})
SFL:Button({Name="[R] Perform Soul Forging Reset",Callback=function()
    fire("PurchaseSoulfire")
end})

SFR:Header({Text="Soulfire Status"})
local sfLbl      =SFR:Label({Text="Soulfire: ?"})
local sfFocusLbl =SFR:Label({Text="Focus: ?"})
local sfUnlockLbl=SFR:Label({Text="Unlocked: ?"})
e.IM_sfLbl=sfLbl; e.IM_sfFocusLbl=sfFocusLbl; e.IM_sfUnlockLbl=sfUnlockLbl

-- ============================================================
-- TAB: KARMA
-- ============================================================
local KL=TK:Section({Side="Left"})
local KR=TK:Section({Side="Right"})

KL:Header({Text="Karma Farm (Ghost Snap)"})
KL:Toggle({Name="Auto Farm Karma",Default=e.IM_autoKarma,
    Callback=function(v) e.IM_autoKarma=v end})
KL:Toggle({Name="NoCooldown (Permanent Hold)",Default=e.IM_karmaNoCD,
    Callback=function(v) e.IM_karmaNoCD=v end})
KL:Label({Text="ON  → char locked at plate 100% (max rate)"})
KL:Label({Text="OFF → ghost snap 0.2s per tick (old mode)"})

KL:Header({Text="Manual Control"})
KL:Button({Name="Press Karma Mark Once",Callback=function()
    fire("KarmaMarkPress")
end})

KR:Header({Text="Karma Status"})
local karmaLbl     =KR:Label({Text="Karma: ?"})
local karmaGainLbl =KR:Label({Text="Gain/tick: ?"})
local karmaMeterLbl=KR:Label({Text="Meter: ?"})
local karmaUnlkLbl =KR:Label({Text="Unlocked: ?"})
e.IM_karmaLbl=karmaLbl; e.IM_karmaGainLbl=karmaGainLbl
e.IM_karmaMeterLbl=karmaMeterLbl; e.IM_karmaUnlkLbl=karmaUnlkLbl

-- ============================================================
-- TAB: BEAST
-- ============================================================
local BL=TB:Section({Side="Left"})
local BR=TB:Section({Side="Right"})

BL:Header({Text="Beast Stage Hunt"})
BL:Toggle({Name="Auto Beast Hunt",Default=e.IM_autoBeast,
    Callback=function(v) e.IM_autoBeast=v end})
BL:Label({Text="Ghost snap per wave (invisible, cam locked)"})

local beastMaxStage=LP:GetAttribute("BeastHighestStage") or 1
local STAGE_OPTS={}
for i=1,math.max(beastMaxStage,1) do table.insert(STAGE_OPTS,tostring(i)) end
local bStageDD=BL:Dropdown({
    Name="Target Stage",
    Options=STAGE_OPTS,
    Default=e.IM_beastStage,
    IgnoreConfig=true,
    Callback=function(v)
        e.IM_beastStage=v
        if e.IM_autoBeast then fire("SetBeastStage",tonumber(v) or 1) end
    end
})
pcall(function() bStageDD:UpdateSelection(e.IM_beastStage) end)

BL:Header({Text="Beast Remnant Upgrades"})
BL:Toggle({Name="Auto Buy Beast Upgrades",Default=e.IM_autoBeastUpg,
    Callback=function(v) e.IM_autoBeastUpg=v end})
BL:Label({Text="* More Damage  (BeastDamage)"})
BL:Label({Text="* Faster Hunt Strikes  (BeastAttackInterval)"})
BL:Label({Text="* Longer Hunt Time  (BeastTimerExtension)"})
BL:Label({Text="* More Beast Remnants  (BeastRemnantYield)"})
BL:Label({Text="* Apex Pursuit  (ApexPursuit)"})

BR:Header({Text="Beast Status"})
local bStgLbl  =BR:Label({Text="Stage: ?"})
local bKillLbl =BR:Label({Text="Kills: ?"})
local bRemLbl  =BR:Label({Text="Remnants: ?"})
local bUnlkLbl =BR:Label({Text="Hunt: ?"})
e.IM_bStgLbl=bStgLbl; e.IM_bKillLbl=bKillLbl
e.IM_bRemLbl=bRemLbl; e.IM_bUnlkLbl=bUnlkLbl

-- ============================================================
-- TAB: JADE / BLOODLINES
-- ============================================================
local JL=TJB:Section({Side="Left"})
local JR=TJB:Section({Side="Right"})

JL:Header({Text="Jade Daily Upgrades"})
JL:Toggle({Name="Auto Buy Jade Upgrades",Default=e.IM_autoJade,
    Callback=function(v) e.IM_autoJade=v end})
JL:Label({Text="Buys: Qi - Luck - Insight - Essence"})
JL:Label({Text="       Soulfire (more as unlocked)"})
JL:Label({Text="Daily Jade = server auto-pays (no btn)"})

JL:Header({Text="Bloodlines (Core Rolls)"})
JL:Toggle({Name="Auto Roll Bloodline",Default=e.IM_autoBlood,
    Callback=function(v) e.IM_autoBlood=v end})
JL:Label({Text="Fires RollBloodline every buy cycle"})

JR:Header({Text="Jade Status"})
local jadeLbl      =JR:Label({Text="Jade: ?"})
local jadeStreakLbl=JR:Label({Text="Streak: ?"})
JR:Header({Text="Bloodline Status"})
local bloodLbl=JR:Label({Text="Rolls this session: 0"})
e.IM_jadeLbl=jadeLbl; e.IM_jadeStreakLbl=jadeStreakLbl
e.IM_bloodLbl=bloodLbl
e.__IM_bloodCount=e.__IM_bloodCount or 0

-- ============================================================
-- TAB: STARS
-- ============================================================
local SDL=TSD:Section({Side="Left"})
local SDR=TSD:Section({Side="Right"})

SDL:Header({Text="Auto Star Collect"})
SDL:Toggle({Name="Auto Collect Stars",Default=e.IM_autoStar,
    Callback=function(v) e.IM_autoStar=v end})
local STAR_METHOD_OPTS={"TP","Tweak","Walk"}
SDL:Dropdown({Name="Collection Method",Options=STAR_METHOD_OPTS,Default=table.find(STAR_METHOD_OPTS,e.IM_starMethod) or 1,
    IgnoreConfig=true,
    Callback=function(v) e.IM_starMethod=type(v)=="table" and v[1] or v end})
SDL:Label({Text="TP/Tweak = ghost teleport (verified live: often"})
SDL:Label({Text="does NOT register with the server, use with caution)"})
SDL:Label({Text="Walk = real movement -- verified live, works reliably"})
local starDelaySlider=SDL:Slider({Name="Delay (Walk: WalkSpeed, TP/Tweak: hold time)",Minimum=0.1,Maximum=1.0,Default=e.IM_starDelay,Precision=2,
    Callback=function(v) e.IM_starDelay=v end})
SDL:Label({Text="Works alongside Karma hold (yielded priority)"})
SDL:Label({Text="Stars spawn up to 5 at a time, 1/sec"})
SDL:Label({Text="Collection radius: 2 studs (server-checked)"})

SDL:Header({Text="Promo Codes (one-time per account)"})
SDL:Label({Text="59 codes loaded from CodeConfig — auto-run"})
SDL:Label({Text="on startup. Button below to run again."})
SDL:Button({Name="Redeem All 59 Codes",Callback=function()
    task.spawn(function()
        local rf = RE:FindFirstChild("RedeemShopCode")
        if not rf then print("[IM] RedeemShopCode RF not found"); return end
        local ok2,cc = pcall(require, RS.Modules.CodeConfig)
        if not ok2 then print("[IM] CodeConfig load failed"); return end
        local total, redeemed, already = 0, 0, 0
        for k, v in pairs(cc.Codes) do
            total = total + 1
            local s, r = pcall(function() return rf:InvokeServer(v.displayCode or k) end)
            if s and r then redeemed=redeemed+1 else already=already+1 end
            task.wait(0.25)
        end
        local msg = string.format("Codes: %d new / %d already used (%d total)", redeemed, already, total)
        print("[IM] "..msg)
        pcall(function() if e.IM_starCodeLbl then e.IM_starCodeLbl:UpdateName(msg) end end)
    end)
end})
local starCodeLbl=SDL:Label({Text="Last redeem: not run yet"})
e.IM_starCodeLbl=starCodeLbl

SDR:Header({Text="Star Status"})
local starActiveLbl=SDR:Label({Text="Active stars: 0"})
local starCollLbl  =SDR:Label({Text="Collected: 0 this session"})
local starValLbl   =SDR:Label({Text="Stars owned: ?"})
e.IM_starActiveLbl=starActiveLbl
e.IM_starCollLbl=starCollLbl
e.IM_starValLbl=starValLbl

-- ============================================================
-- TAB: SETTINGS
-- ============================================================
local STL=TST:Section({Side="Left"})
local STR=TST:Section({Side="Right"})

STL:Header({Text="Utility"})
STL:Toggle({Name="Anti-AFK",Default=e.IM_antiAfk,
    Callback=function(v) e.IM_antiAfk=v end})
STL:Toggle({Name="Auto Reconnect (on death)",Default=e.IM_autoRec,
    Callback=function(v) e.IM_autoRec=v end})

STL:Header({Text="UI Keybind (Minimize toggle)"})
local keyKB=STL:Keybind({
    Name="Minimize Key",
    Default=Enum.KeyCode[e.IM_minKey] or Enum.KeyCode.RightShift,
    IgnoreConfig=true,
    Callback=function(key)
        e.IM_minKey=keyCodeName(key)
        pcall(function() W:SetKeybind(key) end)
    end
})
pcall(function() W:SetKeybind(Enum.KeyCode[e.IM_minKey] or Enum.KeyCode.RightShift) end)

STR:Header({Text="Timing"})
STR:Label({Text="Mark loop:   dynamic (MarkSpeed attr)"})
STR:Label({Text="Karma loop:  dynamic (same speed)"})
STR:Label({Text="Star loop:   0.5s poll / 0.15s per snap"})
STR:Label({Text="Buy loop:    every 3s per cycle"})
STR:Label({Text="Beast loop:  every 4s"})
STR:Label({Text="Status loop: every 2s"})
STR:Label({Text="SF cycle:    every 30s"})
STR:Header({Text="v2.3 -- Immortality Auto"})
STR:Label({Text="All remotes confirmed via source code"})

-- ============================================================
-- Anti-AFK (connect once per session)
-- ============================================================
if not e.__IM_afk then e.__IM_afk=true
    LP.Idled:Connect(function()
        if e.IM_antiAfk then
            pcall(function() VU:CaptureController(); VU:ClickButton2(Vector2.new()) end)
        end
    end)
end

-- Minimize keybind handled natively by W:SetKeybind() above

-- ============================================================
-- LOOP 1: Auto Mark + Realm + Temper
-- ============================================================
task.spawn(function()
    while getgenv().__IG==G do
        local interval=getMarkInterval()

        local fired={}
        for _,mk in ipairs(MARKS) do
            if e[mk.key] then
                fire(mk.remote)
                table.insert(fired,mk.id:sub(1,3))
            end
        end
        pcall(function()
            if e.IM_mActiveLbl then
                e.IM_mActiveLbl:UpdateName("Active: "..
                    (#fired>0 and table.concat(fired," ") or "none"))
            end
        end)

        if e.IM_autoRealm  then fire("RealmPress") end
        if e.IM_autoTemper then fire("ClaimRefinement") end

        task.wait(interval)
    end
end)

-- ============================================================
-- LOOP 2: Beast Stage + Remnant Upgrades (ghost snap per wave)
-- ============================================================
task.spawn(function()
    while getgenv().__IG==G do
        task.wait(1)

        local current  = LP:GetAttribute("BeastCurrentStage") or 1
        local highest  = LP:GetAttribute("BeastHighestStage")  or 1
        local inArena  = LP:GetAttribute("BeastInArena") == true
        local kc       = LP:GetAttribute("BeastKillCount")      or 0
        local kg       = LP:GetAttribute("BeastKillGoal")       or 10
        local tr       = LP:GetAttribute("BeastStageTimerRemaining") or 0
        local unlocked = LP:GetAttribute("BeastHuntUnlocked") == true

        if e.IM_autoBeast then
            if not inArena and not snapping then
                local arenaModel = workspace:FindFirstChild("ArenaMain")
                local arenaBase  = arenaModel and arenaModel:FindFirstChild("ArenaBase")
                if arenaBase then
                    fire("SetBeastStage", tonumber(e.IM_beastStage) or 1)
                    task.spawn(function()
                        ghostSnap(
                            CFrame.new(arenaBase.Position + Vector3.new(0, 5, 0)),
                            16
                        )
                    end)
                end
            elseif inArena then
                fire("SetBeastStage", tonumber(e.IM_beastStage) or 1)
            end
        end

        if e.IM_autoBeastUpg then
            for _,id in ipairs(BEAST_UPG) do
                fire("PurchaseUpgrade",id,false); task.wait(0.08)
            end
        end

        pcall(function()
            if e.IM_bStgLbl  then
                e.IM_bStgLbl:UpdateName(string.format("Stage: %d / %d",current,highest)) end
            if e.IM_bKillLbl then
                e.IM_bKillLbl:UpdateName(string.format("Kills: %d/%d  Timer: %.0fs",kc,kg,tr)) end
            if e.IM_bRemLbl  then
                e.IM_bRemLbl:UpdateName("Remnants: "..getAttrBig("BeastRemnants")) end
            if e.IM_bUnlkLbl then
                e.IM_bUnlkLbl:UpdateName("Hunt: "..(unlocked and "Unlocked" or "Locked")) end
        end)
    end
end)

-- ============================================================
-- LOOP 3: Auto Buy (Qi / Insight / Essence / Soulfire / Jade / Blood)
-- ============================================================
task.spawn(function()
    while getgenv().__IG==G do
        task.wait(3)

        if e.IM_autoQi then
            for _,id in ipairs(QI_UPG) do
                fire("PurchaseUpgrade",id,false); task.wait(0.08)
            end
        end

        if e.IM_autoInsight then
            for _,id in ipairs(INSIGHT_UPG) do
                fire("PurchaseInsight",id); task.wait(0.08)
            end
        end

        if e.IM_autoEssence then
            for _,id in ipairs(ESSENCE_UPG) do
                fire("PurchaseUpgrade",id,false); task.wait(0.08)
            end
        end

        if e.IM_autoSoul then
            for _,id in ipairs(SOUL_UPG) do
                fire("PurchaseUpgrade",id,true); task.wait(0.08)
            end
        end

        if e.IM_autoJade then
            for _,id in ipairs(JADE_UPG) do
                fire("PurchaseUpgrade",id,false); task.wait(0.08)
            end
        end

        if e.IM_autoBlood then
            fire("RollBloodline")
            e.__IM_bloodCount=(e.__IM_bloodCount or 0)+1
            pcall(function()
                if e.IM_bloodLbl then
                    e.IM_bloodLbl:UpdateName("Rolls this session: "..e.__IM_bloodCount) end
            end)
        end
    end
end)

-- ============================================================
-- LOOP 4: Status labels (every 2s)
-- ============================================================
task.spawn(function()
    while getgenv().__IG==G do
        task.wait(2)
        pcall(function()
            local spdM=LP:GetAttribute("MarkSpeedMantissa") or 0
            local spdE=LP:GetAttribute("MarkSpeedExponent") or 0
            local rate=(spdM)*(10^spdE)
            local att=LP:GetAttribute("BreakthroughAttempts") or 0

            if e.IM_mSpeedLbl   then e.IM_mSpeedLbl:UpdateName(string.format("Speed: %.1f/s",rate)) end
            if e.IM_mAttemptLbl then e.IM_mAttemptLbl:UpdateName("Attempts: "..att) end
            if e.IM_mLuckLbl    then e.IM_mLuckLbl:UpdateName("BrkLuck: "..getAttrBig("BreakthroughLuck")) end

            if e.IM_qiValLbl  then e.IM_qiValLbl:UpdateName("Qi: "..getAttrBig("Qi")) end
            if e.IM_qiLuckLbl then e.IM_qiLuckLbl:UpdateName("BrkLuck: "..getAttrBig("BreakthroughLuck")) end
            local bulk=LP:GetAttribute("Upgrade_MarkBulk") or 0
            if e.IM_qiBulkLbl then e.IM_qiBulkLbl:UpdateName("MarkBulk Lv: "..bulk) end

            if e.IM_insightLbl    then e.IM_insightLbl:UpdateName("Insight: "..getAttrBig("Insight")) end
            if e.IM_insightRstLbl then
                e.IM_insightRstLbl:UpdateName("Reset gain: "..getAttrBig("InsightResetPreview")) end

            if e.IM_essLbl then e.IM_essLbl:UpdateName("Essence: "..getAttrBig("Essence")) end

            if e.IM_sfLbl then e.IM_sfLbl:UpdateName("Soulfire: "..getAttrBig("Soulfire")) end
            local focus=LP:GetAttribute("ActiveSoulFocus") or "?"
            if e.IM_sfFocusLbl then e.IM_sfFocusLbl:UpdateName("Focus: "..tostring(focus)) end
            local sfUnlk=LP:GetAttribute("SoulForgingUnlocked")==true
            if e.IM_sfUnlockLbl then
                e.IM_sfUnlockLbl:UpdateName("Soul Forging: "..(sfUnlk and "Unlocked" or "Locked")) end

            if e.IM_karmaLbl then e.IM_karmaLbl:UpdateName("Karma: "..getAttrBig("Karma")) end
            if e.IM_karmaGainLbl then
                e.IM_karmaGainLbl:UpdateName("Gain/tick: "..getAttrBig("KarmaGainPerTick")) end
            if e.IM_karmaMeterLbl then
                local prog=LP:GetAttribute("KarmaMeterProgress") or 0
                e.IM_karmaMeterLbl:UpdateName(string.format("Meter: %.1f%%",prog*100)) end
            if e.IM_karmaUnlkLbl then
                local unlk=LP:GetAttribute("KarmaUnlocked")==true
                e.IM_karmaUnlkLbl:UpdateName("Unlocked: "..(unlk and "Yes" or "No")) end

            if e.IM_jadeLbl then e.IM_jadeLbl:UpdateName("Jade: "..getAttrBig("Jade")) end
            local streak=LP:GetAttribute("JadeDailyStreak") or 0
            if e.IM_jadeStreakLbl then
                e.IM_jadeStreakLbl:UpdateName("Daily Streak: "..streak.." day(s)") end

            -- Stars status
            local sc = findStarFolder()
            local activeCount = sc and #sc:GetChildren() or 0
            if e.IM_starActiveLbl then
                e.IM_starActiveLbl:UpdateName("Active stars: "..activeCount) end
            if e.IM_starValLbl then
                local sm=LP:GetAttribute("HighestStarsOwnedMantissa") or 0
                local se=LP:GetAttribute("HighestStarsOwnedExponent") or 0
                e.IM_starValLbl:UpdateName("Stars owned: "..fmtBig(sm,se)) end
        end)
    end
end)

-- ============================================================
-- Auto Reconnect: event-driven (NOT poll)
-- ============================================================
if not e.__IM_rec then e.__IM_rec=true
    pcall(function()
        LP.OnTeleport:Connect(function(state)
            if state==Enum.TeleportState.RequestedFromServer and e.IM_autoRec then
                task.wait(2)
                pcall(function() TSvc:Teleport(game.PlaceId,LP) end)
            end
        end)
    end)
    pcall(function()
        game:BindToClose(function()
            if e.IM_autoRec then
                pcall(function() TSvc:Teleport(game.PlaceId,LP) end)
            end
        end)
    end)
end

-- ============================================================
-- LOOP 6: Auto Karma — PERMANENT ghost hold on KarmaGainButtonTop
-- ============================================================
local karmaHolding     = false
local karmaHRPConn     = nil
local karmaCamConn2    = nil
local karmaPartRestore = {}
local karmaSavedPos    = nil
local karmaSavedCam2   = nil

local function karmaHoldStart()
    if karmaHolding then return end
    local char   = LP.Character
    local hrp    = char and char:FindFirstChild("HumanoidRootPart")
    local btn    = workspace:FindFirstChild("KarmaGainButton")
    local btnTop = btn and btn:FindFirstChild("KarmaGainButtonTop")
    if not hrp or not btnTop then return end

    karmaHolding  = true
    karmaSavedPos = hrp.CFrame
    local cam     = workspace.CurrentCamera
    karmaSavedCam2 = cam.CFrame
    local targetCF = CFrame.new(btnTop.Position + Vector3.new(0, 3, 0))

    karmaPartRestore = {}
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then
            karmaPartRestore[p] = p.LocalTransparencyModifier
            p.LocalTransparencyModifier = 1
        end
    end

    karmaCamConn2 = RunService.RenderStepped:Connect(function()
        cam.CameraType = Enum.CameraType.Scriptable
        cam.CFrame     = karmaSavedCam2
    end)

    -- Yields to both beast snap AND star snap (snapping flag covers both)
    karmaHRPConn = RunService.Heartbeat:Connect(function()
        if snapping then return end
        pcall(function()
            local h = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
            if h then h.CFrame = targetCF end
        end)
    end)
end

local function karmaHoldStop()
    if not karmaHolding then return end
    karmaHolding = false
    if karmaHRPConn  then karmaHRPConn:Disconnect();  karmaHRPConn  = nil end
    if karmaCamConn2 then karmaCamConn2:Disconnect(); karmaCamConn2 = nil end
    local char = LP.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if hrp and karmaSavedPos then
        pcall(function() hrp.CFrame = karmaSavedPos end)
    end
    for p, v in pairs(karmaPartRestore) do
        pcall(function() if p and p.Parent then p.LocalTransparencyModifier = v end end)
    end
    karmaPartRestore = {}
    pcall(function() workspace.CurrentCamera.CameraType = Enum.CameraType.Custom end)
    karmaSavedPos = nil; karmaSavedCam2 = nil
end

task.spawn(function()
    while getgenv().__IG==G do
        task.wait(0.5)
        local unlocked = LP:GetAttribute("KarmaUnlocked")==true
        local want     = e.IM_autoKarma and unlocked
        if want and e.IM_karmaNoCD then
            if not karmaHolding then karmaHoldStart() end
        else
            if karmaHolding then karmaHoldStop() end
        end
    end
    karmaHoldStop()
end)

task.spawn(function()
    while getgenv().__IG==G do
        local unlocked = LP:GetAttribute("KarmaUnlocked")==true
        if e.IM_autoKarma and not e.IM_karmaNoCD and unlocked and not karmaHolding then
            local btn    = workspace:FindFirstChild("KarmaGainButton")
            local btnTop = btn and btn:FindFirstChild("KarmaGainButtonTop")
            if btnTop then
                ghostSnap(CFrame.new(btnTop.Position + Vector3.new(0,3,0)), 0.2)
            end
        end
        task.wait(math.max(getMarkInterval(), 1.0))
    end
end)

-- ============================================================
-- LOOP 7: Soul Focus Cycle (every 30s)
-- ============================================================
task.spawn(function()
    local idx=1
    while getgenv().__IG==G do
        task.wait(30)
        local list=e.IM_soulFocusList
        if type(list)~="table" or #list==0 then continue end
        if idx>#list then idx=1 end
        local focus=list[idx]
        idx=idx+1
        fire("SetSoulFocus",focus)
        e.IM_soulFocus=focus
    end
end)

-- ============================================================
-- LOOP 8: Auto Star Collect
-- Polls the star visuals folder every 0.5s and, if any live stars exist,
-- collects all of them in one pass using whichever method is selected:
--   TP    -- ghostBatch instant snap (hidden once per batch, not per star)
--   Tweak -- ghostBatch smooth tween (still hidden, less abrupt movement)
--   Walk  -- real Humanoid:MoveTo() pathing (fully visible, zero flicker)
-- Hold delay per star is user-adjustable (0.1-1.0s) via the Slider.
-- Stars re-spawn server-side at 1/sec up to 5 max, so a fresh batch every
-- 0.5s keeps up with the spawn rate.
-- ============================================================
task.spawn(function()
    while getgenv().__IG==G do
        task.wait(0.5)
        if not e.IM_autoStar then continue end

        local sc = findStarFolder()
        if not sc then continue end

        -- The same folder also holds the non-star "StarCollectionRange"
        -- indicator disc -- only snap to actual "Star_<id>" instances.
        local targets = {}
        for _, child in ipairs(sc:GetChildren()) do
            if child.Name:match("^Star_") then
                local part = child:IsA("BasePart") and child
                    or child:FindFirstChildWhichIsA("BasePart", true)
                if part and part.Parent then
                    -- Snap to star center + 1 stud up (lands within COLLECTION_RADIUS=2)
                    table.insert(targets, CFrame.new(part.Position + Vector3.new(0, 1, 0)))
                end
            end
        end
        if #targets == 0 then continue end

        -- Route nearest-first from wherever the player actually is, so the
        -- batch never backtracks past a close star to grab a far one first.
        pcall(function()
            local char = LP.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then targets = sortTargetsByNearest(targets, hrp.Position) end
        end)

        local delay = e.IM_starDelay or 0.15
        local method = e.IM_starMethod or "TP"
        if method == "Walk" then
            walkCollectStars(targets, delay)
        else
            ghostBatch(targets, delay, 0.08, method)
        end

        e.__IM_starCollected = (e.__IM_starCollected or 0) + #targets
        pcall(function()
            if e.IM_starCollLbl then
                e.IM_starCollLbl:UpdateName("Collected: "..e.__IM_starCollected.." this session")
            end
        end)
    end
end)

-- ============================================================
-- Startup: auto-redeem all 59 codes once per executor session
-- Server rejects already-redeemed codes silently — safe to retry.
-- Guarded by __IM_codesRedeemed so reload doesn't re-fire 59 requests.
-- ============================================================
if not e.__IM_codesRedeemed then e.__IM_codesRedeemed=true
    task.spawn(function()
        task.wait(4)  -- wait for game to fully settle
        local rf = RE:FindFirstChild("RedeemShopCode")
        if not rf then return end
        local ok2, cc = pcall(require, RS.Modules.CodeConfig)
        if not ok2 or not cc then return end
        local total, redeemed = 0, 0
        for k, v in pairs(cc.Codes) do
            total = total + 1
            local s, r = pcall(function() return rf:InvokeServer(v.displayCode or k) end)
            if s and r then redeemed = redeemed + 1 end
            task.wait(0.25)
        end
        local msg = string.format("Codes: %d new / %d already used (%d total)", redeemed, total-redeemed, total)
        print("[IM] "..msg)
        pcall(function() if e.IM_starCodeLbl then e.IM_starCodeLbl:UpdateName(msg) end end)
    end)
end

local _mc=0; for _,mk in ipairs(MARKS) do if e[mk.key] then _mc=_mc+1 end end
print(string.format("[IM] v2.3 OK | Marks:%d/14 Karma:%s Star:%s Realm:%s Beast:%s AntiAfk:%s",
    _mc, tostring(e.IM_autoKarma), tostring(e.IM_autoStar),
    tostring(e.IM_autoRealm), tostring(e.IM_autoBeast), tostring(e.IM_antiAfk)))
