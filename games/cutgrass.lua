-- +1 Cut Grass Adventure -- Automation v1.0
-- Auto Click + Auto Training + Auto Rebirth + Auto Loot (world/zone picker,
-- highest sell price first) + Auto Sell (remote, no walk to the NPC)
--
-- The game runs on Knit 1.7.2, so every server call is a plain RemoteEvent or
-- RemoteFunction under
--   ReplicatedStorage.Packages._Index["acecateer_knit@1.7.2"].knit.Services
-- and nothing here needs the Knit controller layer. Every remote below was read
-- out of the game's own controllers and then fired against the live server:
--
--   AttackService.RE.AttackRequested:FireServer()      no args (AttackController)
--   RebirtService.RE.RebirthButtonClicked:FireServer() no args (RebirthController)
--   DataService.RF.SellAllBackpackLoot:InvokeServer()  no args (SellLootController)
--       -> {Success=true, SoldCount=1, Earned=5400000000000, SellState=..., State=...}
--       Confirmed live: backpack 1 -> 0, money $3.6B -> $5.4T, character moved
--       0.0 studs. That is the whole answer to "sell without walking to the NPC"
--       -- the shop NPC is a UI, the sale is a remote, and the remote does not
--       care where you stand.
--   DataService.RF.GetBackpackSlotsState   -> {Count, Capacity}
--   DataService.RF.GetBackpackLootSellState-> {Count, Capacity, TotalSellPrice,
--                                              MoneyMultiplier, Items}
--   StrengthService.RF.GetState            -> {Strength, Level, ClickAmount, ...}
--   RebirtService.RF.GetState              -> {CanRebirth, PlayerLevel,
--                                              RequiredLevel, RebirthLevel, ...}
--
-- Click rate: measured against a silent server, and the first measurement was
-- wrong. An early reading suggested a flat 8 credited clicks/sec, but that was
-- taken while the game's own clicker was still running and its output was being
-- counted as ours. With everything else switched off the real shape appears:
--     interval 0.300  fired 3.4/s -> credited 1.9/s
--     interval 0.185  fired 5.5/s -> credited 2.9/s
--     interval 0.125  fired 8.0/s -> credited 4.3/s
--     interval 0.050  fired 20.0/s -> credited 4.9/s
-- The ceiling is DataService.GetAttackCooldown, live 0.1852s, so 5.4/sec is all
-- that exists. The interesting part is the middle column: firing exactly at the
-- cooldown collects barely half of it. A call landing a millisecond before the
-- server's window opens is thrown away and the next one is a full interval
-- behind, so the two clocks beat against each other. Firing at a fraction of the
-- cooldown lands one call inside every window and reaches 91% of the ceiling --
-- so the correct rate is deliberately FASTER than the cooldown, not equal to it.
-- CLICK_DIVISOR encodes that, and the cooldown is re-read live because upgrades
-- lower it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")

-- Same autoexec race that silently killed magic_loot: Players.LocalPlayer is nil
-- for the first moments of a join, and capturing that nil poisons every use of it
-- for the whole run. It fails late and confusingly -- the script starts, bumps its
-- generation counter, then dies on the first unguarded LocalPlayer index with no
-- window ever appearing.
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    local deadline = os.clock() + 30
    repeat
        task.wait(0.1)
        LocalPlayer = Players.LocalPlayer
    until LocalPlayer or os.clock() > deadline
end
if not LocalPlayer then
    warn("[CutGrass] Players.LocalPlayer never arrived -- aborting cleanly")
    return
end

getgenv().__CGA = (getgenv().__CGA or 0) + 1
local myGen = getgenv().__CGA
local SESSION_START = os.clock()

-- Sweep by window title rather than trusting a stored handle. A run that dies
-- partway never reaches the line that saves the handle, and its window then sits
-- on screen with nothing tracking it.
pcall(function()
    if getgenv().__CGAWindow then getgenv().__CGAWindow:Unload() end
end)
pcall(function()
    local host = (gethui and gethui()) or game:GetService("CoreGui")
    for _, gui in ipairs(host:GetChildren()) do
        if gui:IsA("ScreenGui") then
            for _, d in ipairs(gui:GetDescendants()) do
                if d:IsA("TextLabel") and d.Text == "Cut Grass" then
                    gui:Destroy()
                    break
                end
            end
        end
    end
end)

local knitServices = ReplicatedStorage:WaitForChild("Packages", 30)
knitServices = knitServices and knitServices:WaitForChild("_Index", 30)
knitServices = knitServices and knitServices:FindFirstChild("acecateer_knit@1.7.2")
knitServices = knitServices and knitServices:FindFirstChild("knit")
knitServices = knitServices and knitServices:FindFirstChild("Services")
if not knitServices then
    warn("[CutGrass] Knit Services folder never replicated -- aborting cleanly")
    return
end

local Configs = ReplicatedStorage:WaitForChild("Shared", 30)
Configs = Configs and Configs:WaitForChild("Configs", 30)
if not Configs then
    warn("[CutGrass] Shared.Configs never replicated -- aborting cleanly")
    return
end

local LootConfig = require(Configs.Loot)
local WorldsConfig = require(Configs.Worlds)

-- Remote lookups go through here so a service the game renames later fails as a
-- dead toggle instead of a hard error inside a background loop.
local function remote(serviceName, kind, remoteName)
    local service = knitServices:FindFirstChild(serviceName)
    local folder = service and service:FindFirstChild(kind)
    return folder and folder:FindFirstChild(remoteName)
end

local function fireRemote(serviceName, remoteName, ...)
    local re = remote(serviceName, "RE", remoteName)
    if not re then return false end
    local args = {...}
    return (pcall(function() re:FireServer(table.unpack(args)) end))
end

local function invokeRemote(serviceName, remoteName, ...)
    local rf = remote(serviceName, "RF", remoteName)
    if not rf then return nil end
    local args = {...}
    local ok, result = pcall(function() return rf:InvokeServer(table.unpack(args)) end)
    if ok then return result end
    return nil
end

-- ===== Short amounts (1k / 150m / 1.5b / 1t) =====
-- Sell prices here run from 20 to 1,800,000,000,000. Nobody should be counting
-- zeroes to set a threshold, and no slider can span that with usable resolution.
local AMOUNT_SUFFIX = {k = 1e3, m = 1e6, b = 1e9, t = 1e12, q = 1e15}

local function parseAmount(value)
    if type(value) == "number" then return math.max(0, math.floor(value)) end
    local text = tostring(value or ""):gsub("[%s,%$]", ""):lower()
    if text == "" then return 0 end
    local numberPart, suffix = text:match("^(%d*%.?%d+)([kmbtq]?)$")
    if not numberPart then return nil end
    local amount = tonumber(numberPart)
    if not amount then return nil end
    return math.floor(amount * (AMOUNT_SUFFIX[suffix] or 1))
end

local function formatAmount(amount)
    amount = tonumber(amount) or 0
    for _, unit in ipairs({{1e15, "q"}, {1e12, "t"}, {1e9, "b"}, {1e6, "m"}, {1e3, "k"}}) do
        if amount >= unit[1] then
            return string.format("%.15g", math.floor(amount / unit[1] * 100 + 0.5) / 100) .. unit[2]
        end
    end
    return tostring(math.floor(amount))
end

-- ===== Loot table =====
-- LootConfig.Items is keyed by item id, but the thing lying on the ground is a
-- Model named after ModelName ("34_Amber_Beetle"), so the lookup has to go the
-- other way. 74 items, each carrying SellPrice -- which is what "most valuable
-- first" actually sorts on, before the rebirth money multiplier is applied.
local lootByModelName = {}
local lootItemCount = 0
for _, item in pairs(LootConfig.Items) do
    if type(item) == "table" and item.ModelName then
        lootByModelName[item.ModelName] = item
        lootItemCount += 1
    end
end

local function lootInfoFor(model)
    local item = lootByModelName[model.Name]
    if item then return item.DisplayName or model.Name, tonumber(item.SellPrice) or 0, item.Rarity end
    return model.Name, 0, nil
end

-- ===== Worlds and zones =====
-- Worlds.Worlds[id] = {DisplayName, WorldFolderName, SpawnPointName,
--                      FirstZoneIndex, LastZoneIndex, RequiredLevel}
-- Read live: World 1 = zones 1..13 (level 1), World 2 = 14..24 (level 185),
-- World 3 = 25..35 (level 390). Zones stream, so only the handful around the
-- player exist in workspace.Zones at any moment -- which is exactly why the zone
-- dropdown is built from the CONFIG range and not from what happens to be loaded.
local worldOrder = {}
for _, id in ipairs(WorldsConfig.Order or {}) do table.insert(worldOrder, id) end
if #worldOrder == 0 then
    for id in pairs(WorldsConfig.Worlds or {}) do table.insert(worldOrder, id) end
    table.sort(worldOrder)
end

local worldLabelToId = {}
local worldOptions = {}
for _, id in ipairs(worldOrder) do
    local world = WorldsConfig.Worlds[id]
    if world then
        local label = string.format("%s  (zones %d-%d, level %s+)",
            tostring(world.DisplayName or ("World " .. id)),
            tonumber(world.FirstZoneIndex) or 0,
            tonumber(world.LastZoneIndex) or 0,
            tostring(world.RequiredLevel or 1))
        table.insert(worldOptions, label)
        worldLabelToId[label] = id
    end
end

local ZoneConfig = require(Configs.Zone)

-- Zone rows carry a Rarity, so the picker can say what a zone is worth farming
-- rather than making the user learn 35 numbers.
local function zoneLabelFor(index)
    local cell = ZoneConfig.Cells and ZoneConfig.Cells["Zone_" .. index]
    local rarity = cell and cell.Rarity
    if rarity then return string.format("Zone %d  (%s)", index, tostring(rarity)) end
    return "Zone " .. index
end

local function zonesForWorld(worldId)
    local world = WorldsConfig.Worlds[worldId]
    if not world then return {}, {} end
    local labels, labelToIndex = {}, {}
    for index = tonumber(world.FirstZoneIndex) or 1, tonumber(world.LastZoneIndex) or 0 do
        local label = zoneLabelFor(index)
        table.insert(labels, label)
        labelToIndex[label] = index
    end
    return labels, labelToIndex
end

local function zoneSpawnPart(index)
    local zones = workspace:FindFirstChild("Zones")
    local zone = zones and zones:FindFirstChild("Zone_" .. index)
    local spawnZone = zone and zone:FindFirstChild("SpawnZone")
    if spawnZone and spawnZone:IsA("BasePart") then return spawnZone end
    return nil
end

local function worldSpawnPart(worldId)
    local world = WorldsConfig.Worlds[worldId]
    local worlds = workspace:FindFirstChild("Worlds")
    local folder = world and worlds and worlds:FindFirstChild(world.WorldFolderName)
    local spawn = folder and world.SpawnPointName and folder:FindFirstChild(world.SpawnPointName)
    if spawn and spawn:IsA("BasePart") then return spawn end
    return nil
end

-- ===== Persisted settings =====
local SAVE_FOLDER = "CutGrassAutomation"
local SAVE_FILE = SAVE_FOLDER .. "/state.json"
pcall(function() if not isfolder(SAVE_FOLDER) then makefolder(SAVE_FOLDER) end end)
local PERSIST_KEYS = {
    "AutoClickEnabled", "ClickInterval",
    "AutoTrainEnabled", "TrainPadPick",
    "AutoRebirthEnabled",
    "AutoLootEnabled", "LootWorldId", "LootZoneIndex", "LootMinPrice", "LootFollowBest", "LootSellWhenFull",
    "AutoIndexEnabled", "IndexOnlyMissing",
    "AutoSellEnabled", "SellWhenFull", "SellIntervalSeconds",
    "AntiAFKEnabled", "AutoReconnectEnabled",
}
local function loadPersistedState()
    local ok, content = pcall(function() return readfile(SAVE_FILE) end)
    if not ok or not content or content == "" then return end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not ok2 or type(data) ~= "table" then return end
    for _, key in ipairs(PERSIST_KEYS) do
        if data[key] ~= nil and getgenv()[key] == nil then getgenv()[key] = data[key] end
    end
end
loadPersistedState()
local function saveState()
    local data = {}
    for _, key in ipairs(PERSIST_KEYS) do data[key] = getgenv()[key] end
    pcall(function() writefile(SAVE_FILE, HttpService:JSONEncode(data)) end)
end

-- Fire this many times per server cooldown window. 3 lands one call inside every
-- window without flooding; 1 (firing exactly at the cooldown) collects ~54%.
local CLICK_DIVISOR = 3
-- Floor on the wire regardless of what the cooldown says, so a future upgrade
-- that drops the cooldown near zero cannot turn this into a packet storm.
local CLICK_MIN_INTERVAL = 0.03

local e = getgenv()
if e.AutoClickEnabled == nil then e.AutoClickEnabled = false end
-- 0 means "track the server cooldown", which is what anyone should want. A
-- number overrides it for anyone who wants to see the beat effect themselves.
if e.ClickInterval == nil then e.ClickInterval = 0 end
e.ClickInterval = math.max(0, tonumber(e.ClickInterval) or 0)
if e.AutoTrainEnabled == nil then e.AutoTrainEnabled = false end
if e.TrainPadPick == nil then e.TrainPadPick = 0 end
if e.AutoRebirthEnabled == nil then e.AutoRebirthEnabled = false end
if e.AutoLootEnabled == nil then e.AutoLootEnabled = false end
if e.LootWorldId == nil then e.LootWorldId = WorldsConfig.DefaultWorldId or 1 end
if e.LootZoneIndex == nil then e.LootZoneIndex = 0 end
if e.LootMinPrice == nil then e.LootMinPrice = 0 end
e.LootMinPrice = parseAmount(e.LootMinPrice) or 0
if e.LootFollowBest == nil then e.LootFollowBest = false end
-- Defaults ON: looting into a full bag is the one state where doing nothing is
-- never what was wanted.
if e.LootSellWhenFull == nil then e.LootSellWhenFull = true end
if e.AutoIndexEnabled == nil then e.AutoIndexEnabled = false end
if e.IndexOnlyMissing == nil then e.IndexOnlyMissing = true end
if e.AutoSellEnabled == nil then e.AutoSellEnabled = false end
if e.SellWhenFull == nil then e.SellWhenFull = true end
if e.SellIntervalSeconds == nil then e.SellIntervalSeconds = 5 end
if e.AntiAFKEnabled == nil then e.AntiAFKEnabled = true end
if e.AutoReconnectEnabled == nil then e.AutoReconnectEnabled = false end

local function humanoidRootPart()
    local character = LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

-- ===== Auto Click =====
local clickStatusText = "Toggle is OFF"
local clickFired = 0
local lastClickClock = 0
local clickCreditWindow = {startClock = os.clock(), startStrength = nil, rate = 0, gain = 0}

local function strengthState()
    return invokeRemote("StrengthService", "GetState")
end

-- The interval is enforced HERE, off os.clock, and the driving loop ticks on a
-- much shorter slice. Pacing with task.wait(interval) instead cost half the rate:
-- task.wait overshoots under load, and this script runs six other loops, three of
-- which block on InvokeServer. Measured 3.8 clicks/sec against an 8/sec ceiling
-- until the pacing moved off task.wait -- the server was never the limit there,
-- the scheduler was.
-- Cached because GetAttackCooldown is a blocking round trip and the click loop
-- runs 30x a second; the value only moves when an upgrade is bought.
local attackCooldown = 0.185
local lastCooldownRead = 0
local function serverAttackCooldown()
    if (os.clock() - lastCooldownRead) > 5 then
        lastCooldownRead = os.clock()
        local value = tonumber(invokeRemote("DataService", "GetAttackCooldown"))
        if value and value > 0 then attackCooldown = value end
    end
    return attackCooldown
end

local function clickInterval()
    local override = tonumber(e.ClickInterval) or 0
    if override > 0 then return math.max(CLICK_MIN_INTERVAL, override) end
    return math.max(CLICK_MIN_INTERVAL, serverAttackCooldown() / CLICK_DIVISOR)
end

local function doAutoClick()
    if not e.AutoClickEnabled then clickStatusText = "Toggle is OFF"; return end
    if (os.clock() - lastClickClock) < clickInterval() then return end
    lastClickClock = os.clock()
    fireRemote("AttackService", "AttackRequested")
    clickFired += 1
end

-- Credited clicks per second, not calls per second. Those are different numbers
-- above the ceiling and only the first one is income.
local function refreshClickRate()
    local state = strengthState()
    if type(state) ~= "table" then return end
    local strength = tonumber(state.Strength)
    local clickAmount = tonumber(state.ClickAmount) or 0
    if not strength then return end
    local window = clickCreditWindow
    if window.startStrength and clickAmount > 0 then
        local elapsed = os.clock() - window.startClock
        if strength < window.startStrength then
            -- Strength went DOWN, which only happens when a rebirth banks it and
            -- resets to zero. Measuring across that boundary produced a negative
            -- click rate (-32/s was printed once), and a negative rate under a
            -- toggle marked ON is indistinguishable from a dead feature. Drop the
            -- window instead of reporting nonsense.
            window.startClock = os.clock()
            window.startStrength = strength
        elseif elapsed >= 2 then
            window.gain = (strength - window.startStrength) / elapsed
            window.rate = (window.gain) / clickAmount
            window.startClock = os.clock()
            window.startStrength = strength
        end
    else
        window.startClock = os.clock()
        window.startStrength = strength
    end
    if e.AutoClickEnabled then
        -- Strength per second is printed next to the click rate on purpose. Once
        -- the total reaches tens of trillions, a real 8 clicks/sec moves the
        -- on-screen figure so little that a working clicker reads as a dead one --
        -- "82.7T" sits unchanged for ten seconds while it is in fact climbing.
        clickStatusText = string.format("Level %s  |  %.1f / %.1f max clicks/s  |  +%s/s  (+%s each)",
            tostring(state.FormattedLevel or state.Level or "?"),
            window.rate, 1 / serverAttackCooldown(),
            formatAmount(window.gain), formatAmount(clickAmount))
    end
end

-- ===== Auto Training =====
-- TrainZones live at Worlds.<WorldFolder>.TrainZones.TrainZone_N. The suffix is
-- the rebirth level the pad wants (TrainingPads config sets RequireRebirths), so
-- the highest N at or below your rebirth level is the best one you may stand on.
-- Standing there is not enough on its own -- the pad is grass, and grass pays
-- when it is cut, so training is Auto Click aimed at a specific patch.
local trainStatusText = "Toggle is OFF"

local function collectTrainPads()
    local pads = {}
    local worlds = workspace:FindFirstChild("Worlds")
    if not worlds then return pads end
    for _, worldFolder in ipairs(worlds:GetChildren()) do
        local trainZones = worldFolder:FindFirstChild("TrainZones")
        if trainZones then
            for _, pad in ipairs(trainZones:GetChildren()) do
                local index = tonumber(tostring(pad.Name):match("(%d+)$"))
                local part = pad:IsA("BasePart") and pad
                    or (pad:IsA("Model") and (pad:FindFirstChild("Grass_Zone") or pad:FindFirstChildWhichIsA("BasePart")))
                if index and part then
                    table.insert(pads, {
                        index = index,
                        name = pad.Name,
                        world = worldFolder.Name,
                        part = part,
                    })
                end
            end
        end
    end
    table.sort(pads, function(a, b) return a.index < b.index end)
    return pads
end

local function rebirthState()
    return invokeRemote("RebirtService", "GetState")
end

local function pickTrainPad(pads)
    local forced = tonumber(e.TrainPadPick) or 0
    if forced > 0 then
        for _, pad in ipairs(pads) do
            if pad.index == forced then return pad, "picked" end
        end
        return nil, "pad " .. forced .. " is not loaded here"
    end
    local state = rebirthState()
    local rebirthLevel = (type(state) == "table" and tonumber(state.RebirthLevel)) or 0
    local best
    for _, pad in ipairs(pads) do
        if pad.index <= rebirthLevel and (not best or pad.index > best.index) then best = pad end
    end
    if best then return best, string.format("best for rebirth %d", rebirthLevel) end
    -- Nothing unlocked yet, so the lowest pad is the only honest suggestion.
    return pads[1], "no pad matches your rebirth level yet"
end

local function doAutoTrain()
    if not e.AutoTrainEnabled then trainStatusText = "Toggle is OFF"; return end
    local hrp = humanoidRootPart()
    if not hrp then trainStatusText = "No character"; return end
    local pads = collectTrainPads()
    if #pads == 0 then trainStatusText = "No train pads loaded (wrong world?)"; return end
    local pad, note = pickTrainPad(pads)
    if not pad then trainStatusText = tostring(note); return end

    local distance = (pad.part.Position - hrp.Position).Magnitude
    if distance > 12 then
        hrp.CFrame = CFrame.new(pad.part.Position + Vector3.new(0, 6, 0))
        trainStatusText = string.format("Moving to %s (%s)", pad.name, tostring(note))
        return
    end
    -- Already on the pad. Auto Click is what actually pays here, so say so rather
    -- than reporting a cheerful status over a switch that is off.
    fireRemote("AttackService", "AttackRequested")
    trainStatusText = e.AutoClickEnabled
        and string.format("On %s (%s)", pad.name, tostring(note))
        or string.format("On %s -- switch Auto Click on to earn here", pad.name)
end

-- ===== Auto Rebirth =====
local rebirthStatusText = "Toggle is OFF"
-- Counted and shown on purpose. A rebirth wipes Strength back to zero -- that is
-- the mechanic, not a fault -- but from the outside it looks exactly like Auto
-- Click having stopped working, which is precisely how it was first reported.
-- Three rebirths fired during one debugging session and the strength graph was
-- sawtoothed the whole time. The counter is what tells those two apart.
local rebirthsThisSession = 0
local lastRebirthLevel = nil

local function doAutoRebirth()
    local state = rebirthState()
    if type(state) == "table" then
        local level = tonumber(state.RebirthLevel)
        if level and lastRebirthLevel and level > lastRebirthLevel then
            rebirthsThisSession += (level - lastRebirthLevel)
        end
        lastRebirthLevel = level or lastRebirthLevel
    end
    if not e.AutoRebirthEnabled then
        rebirthStatusText = rebirthsThisSession > 0
            and string.format("OFF  |  %d rebirth(s) this session reset Strength", rebirthsThisSession)
            or "Toggle is OFF"
        return
    end
    if type(state) ~= "table" then rebirthStatusText = "No rebirth data"; return end
    if state.IsMaxRebirth == true then rebirthStatusText = "Max rebirth reached"; return end
    if state.CanRebirth == true then
        fireRemote("RebirtService", "RebirthButtonClicked")
        rebirthStatusText = string.format("Rebirthing -> %s (Strength resets)", tostring(state.NextRebirthLevel or "?"))
        task.wait(1.5)
        return
    end
    rebirthStatusText = string.format("Rebirth %s (+%d session)  |  level %s / %s  |  x%s money next",
        tostring(state.RebirthLevel or 0), rebirthsThisSession,
        tostring(state.PlayerLevel or 0), tostring(state.RequiredLevel or "?"),
        tostring(state.NextMoneyMultiplier or "?"))
end

-- ===== Auto Sell =====
-- The shop NPC is a UI, not a gate. SellAllBackpackLoot is a RemoteFunction and
-- the server never asks where the character is standing -- verified by selling
-- from the middle of a zone and measuring 0.0 studs of movement.
local sellStatusText = "Toggle is OFF"
local lastSellClock = 0
local sellEarnedThisSession = 0

local function backpackState()
    return invokeRemote("DataService", "GetBackpackLootSellState")
end

-- InvokeServer yields. The loot loop runs three times a second and used to make
-- this round trip on every single tick, which put a server hop in front of every
-- pickup and starved the click loop sharing the scheduler with it. One cached
-- read per 400ms is plenty -- the only thing that changes the slot count is this
-- script, and it invalidates the cache itself when it does.
local backpackCache = {value = nil, clock = 0}
local function cachedBackpackSlots()
    if backpackCache.value and (os.clock() - backpackCache.clock) < 0.4 then
        return backpackCache.value
    end
    backpackCache.value = invokeRemote("DataService", "GetBackpackSlotsState")
    backpackCache.clock = os.clock()
    return backpackCache.value
end
local function invalidateBackpackCache()
    backpackCache.value = nil
end

local function doAutoSell(force)
    if not force and not e.AutoSellEnabled then sellStatusText = "Toggle is OFF"; return end
    local state = backpackState()
    if type(state) ~= "table" then sellStatusText = "No backpack data"; return end
    local count = tonumber(state.Count) or 0
    local capacity = tonumber(state.Capacity) or 0
    local worth = tonumber(state.TotalSellPrice) or 0

    if count <= 0 then
        sellStatusText = string.format("Empty  (0/%d)", capacity)
        return
    end
    -- Two triggers, and the full one has to win: a bag at capacity blocks every
    -- further pickup, so waiting out the interval there costs real loot.
    local isFull = capacity > 0 and count >= capacity
    local intervalDue = (os.clock() - lastSellClock) >= math.max(1, tonumber(e.SellIntervalSeconds) or 5)
    if not force and not isFull and e.SellWhenFull and not intervalDue then
        sellStatusText = string.format("Holding %d/%d  worth %s", count, capacity, formatAmount(worth))
        return
    end

    lastSellClock = os.clock()
    local result = invokeRemote("DataService", "SellAllBackpackLoot")
    if type(result) == "table" and result.Success then
        local earned = tonumber(result.Earned) or 0
        sellEarnedThisSession += earned
        sellStatusText = string.format("Sold %s item(s) for %s  |  session %s",
            tostring(result.SoldCount or count), formatAmount(earned), formatAmount(sellEarnedThisSession))
    else
        sellStatusText = string.format("Server refused the sale (%d/%d)", count, capacity)
    end
end

-- ===== Auto Loot =====
-- Loot is tagged SpawnedLoot and lives at Zones.Zone_N.SpawnZone.<ModelName>,
-- ten per zone, respawning a second after each pickup. Collection is the game's
-- own ProximityPrompt -- fireproximityprompt on it runs the same handler a real
-- player triggers, which beats guessing at a pickup remote. Confirmed live: the
-- prompt holds for 0.5s and firing it moved the backpack 0/10 -> 1/10.
local lootStatusText = "Toggle is OFF"
local lootCollected = 0
local lootValueCollected = 0

-- ===== Auto Index =====
-- DataService.RF.GetLootIndexData -> {FoundItems = {[ItemId] = true}, FoundCount,
-- TotalCount, StepPercent, StrengthMultiplierPerStep, NextStrengthMultiplier}.
-- Read live: 41 of 74 found, and every 20% completed is worth +0.25x strength --
-- which is why filling the index beats farming price once the cheap items are
-- the ones missing.
--
-- Which zone to hunt in comes out of LootConfig.ZoneRarityWeights[zoneIndex] =
-- {Rarity = weight}. An item can only drop where its rarity rolls, so a zone is
-- worth exactly the sum of (normalised weight x how many items of that rarity are
-- still missing). Scored live rather than hardcoded, because the answer changes
-- every time something is found.
local indexCache = {value = nil, clock = 0}
local function lootIndexData()
    if indexCache.value and (os.clock() - indexCache.clock) < 5 then return indexCache.value end
    indexCache.value = invokeRemote("DataService", "GetLootIndexData")
    indexCache.clock = os.clock()
    return indexCache.value
end
local function invalidateIndexCache() indexCache.value = nil end

local function missingItems()
    local data = lootIndexData()
    local found = (type(data) == "table" and data.FoundItems) or {}
    local missing, byRarity = {}, {}
    for id, item in pairs(LootConfig.Items) do
        if not found[id] then
            missing[id] = item
            byRarity[item.Rarity] = (byRarity[item.Rarity] or 0) + 1
        end
    end
    return missing, byRarity, data
end

-- Only zones in a world the account can actually enter. Zone 30 scored highest
-- while World 3 was still locked behind level 390 -- sending the character at a
-- world it cannot load is how an auto-farmer ends up standing in an empty field
-- reporting success.
local function accessibleWorldIds()
    local state = strengthState()
    local level = (type(state) == "table" and tonumber(state.Level)) or 0
    local ids = {}
    for _, id in ipairs(worldOrder) do
        local world = WorldsConfig.Worlds[id]
        if world and level >= (tonumber(world.RequiredLevel) or 1) then ids[id] = true end
    end
    return ids, level
end

-- The chosen zone is STICKY. Scores across the top zones sit within one percent
-- of each other (30 -> 6.00, 31 -> 5.99, 32 -> 5.95), and pairs() walks a hash
-- table in no fixed order, so recomputing every tick returned a different winner
-- every tick. The character teleported to zone 30, then 31, then 32, arriving
-- nowhere and collecting nothing -- 49 seconds of travel for zero finds. Recompute
-- only when the index actually changes, and break ties on the lowest index so the
-- same inputs always give the same answer.
local indexZoneChoice = {zone = nil, note = nil, stamp = nil}

local function bestIndexZone()
    local _, byRarity = missingItems()
    local totalMissing = 0
    for _, count in pairs(byRarity) do totalMissing += count end
    if totalMissing == 0 then return nil, "Index complete", 0 end

    local allowedWorlds, level = accessibleWorldIds()

    -- Which zones are actually streamed in right now is part of the question, so
    -- it goes in the stamp with the missing set. A stamp of the missing set alone
    -- froze a decision made under different conditions and never revisited it --
    -- the character held a zone chosen minutes earlier while the real best target
    -- had moved to the other side of the map.
    local loadedZones = {}
    local loadedStamp = {}
    local zonesFolder = workspace:FindFirstChild("Zones")
    if zonesFolder then
        for _, zone in ipairs(zonesFolder:GetChildren()) do
            local index = tonumber(tostring(zone.Name):match("(%d+)$"))
            local part = zone:FindFirstChild("SpawnZone")
            if index and part and part:IsA("BasePart") then
                loadedZones[index] = true
                table.insert(loadedStamp, index)
            end
        end
    end
    table.sort(loadedStamp)

    local stampParts = {}
    for rarity, count in pairs(byRarity) do table.insert(stampParts, rarity .. count) end
    table.sort(stampParts)
    local stamp = table.concat(stampParts, "|") .. "#" .. table.concat(loadedStamp, ",")
    if indexZoneChoice.stamp == stamp and indexZoneChoice.zone then
        return indexZoneChoice.zone, indexZoneChoice.note, totalMissing
    end

    local zoneToWorld = {}
    for id in pairs(allowedWorlds) do
        local world = WorldsConfig.Worlds[id]
        for zone = tonumber(world.FirstZoneIndex) or 1, tonumber(world.LastZoneIndex) or 0 do
            zoneToWorld[zone] = id
        end
    end

    -- Two passes. The first only considers zones already streamed in, because a
    -- good-enough target 40 studs away beats a marginally better one that needs a
    -- multi-hop crossing through half the map -- and crossing is what kept failing.
    -- Only when nothing loaded can roll anything missing is the whole table
    -- considered and a real journey started.
    local function scoreZones(restrictToLoaded)
        local bestZone, bestScore, bestNote
        for zone, weights in pairs(LootConfig.ZoneRarityWeights or {}) do
            local zoneIndex = tonumber(zone)
            if zoneIndex and zoneToWorld[zoneIndex] and type(weights) == "table"
                and ((not restrictToLoaded) or loadedZones[zoneIndex]) then
            local total, score = 0, 0
            for _, weight in pairs(weights) do total += weight end
            if total > 0 then
                local covered = {}
                for rarity, weight in pairs(weights) do
                    local missCount = byRarity[rarity] or 0
                    if missCount > 0 then
                        score += (weight / total) * missCount
                        table.insert(covered, string.format("%s x%d", rarity, missCount))
                    end
                end
                -- Strictly greater, then lowest index on a tie -- deterministic
                -- either way, which is the whole point.
                    if score > 0 and (not bestScore or score > bestScore + 1e-9
                        or (math.abs(score - bestScore) <= 1e-9 and zoneIndex < bestZone)) then
                        table.sort(covered)
                        bestZone, bestScore, bestNote = zoneIndex, score, table.concat(covered, ", ")
                    end
                end
            end
        end
        return bestZone, bestNote, bestScore
    end

    local bestZone, bestNote = scoreZones(true)
    if bestZone then
        bestNote = bestNote .. "  here"
    else
        bestZone, bestNote = scoreZones(false)
        if bestZone then bestNote = bestNote .. "  (travelling)" end
    end
    if not bestZone then
        return nil, string.format("Nothing missing is reachable at level %d", level), totalMissing
    end
    indexZoneChoice.zone, indexZoneChoice.note, indexZoneChoice.stamp = bestZone, bestNote, stamp
    return bestZone, bestNote, totalMissing
end

local function currentZoneIndex()
    local hrp = humanoidRootPart()
    if not hrp then return nil end
    local zones = workspace:FindFirstChild("Zones")
    if not zones then return nil end
    local bestIndex, bestDistance
    for _, zone in ipairs(zones:GetChildren()) do
        local index = tonumber(tostring(zone.Name):match("(%d+)$"))
        local spawnZone = zone:FindFirstChild("SpawnZone")
        if index and spawnZone and spawnZone:IsA("BasePart") then
            local distance = (spawnZone.Position - hrp.Position).Magnitude
            if not bestDistance or distance < bestDistance then
                bestIndex, bestDistance = index, distance
            end
        end
    end
    return bestIndex
end

-- Everything on the ground, newest price first. Restricting to one zone is what
-- the picker is for; nil means "wherever we are standing".
local function collectLootTargets(zoneIndex)
    local targets = {}
    local minPrice = parseAmount(e.LootMinPrice) or 0
    local indexing = e.AutoIndexEnabled
    local missing = indexing and missingItems() or nil
    for _, model in ipairs(CollectionService:GetTagged("SpawnedLoot")) do
        if model:IsDescendantOf(workspace) then
            local zone = model.Parent and model.Parent.Parent
            local index = zone and tonumber(tostring(zone.Name):match("(%d+)$"))
            if (not zoneIndex) or index == zoneIndex then
                local part = model:IsA("Model") and (model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")) or model
                local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
                if part and prompt then
                    local item = lootByModelName[model.Name]
                    local displayName, price = lootInfoFor(model)
                    local isMissing = (missing ~= nil) and item ~= nil and missing[item.Id] ~= nil
                    -- Min Price is a price filter and must not hide a first-ever
                    -- find. A missing item is worth collecting at 20 gold.
                    local passes = isMissing or (price >= minPrice)
                    -- "Only missing" turns the whole run into an index hunt: a bag
                    -- filling with duplicates is a bag that cannot hold the thing
                    -- actually being hunted.
                    if indexing and e.IndexOnlyMissing and not isMissing then passes = false end
                    if passes then
                        table.insert(targets, {
                            model = model, part = part, prompt = prompt,
                            name = displayName, price = price, zone = index,
                            missing = isMissing,
                        })
                    end
                end
            end
        end
    end
    -- Missing-from-index outranks price outright. Everything else is most
    -- valuable first, so a bag that fills mid-run fills with the best of what was
    -- on the floor.
    table.sort(targets, function(a, b)
        if a.missing ~= b.missing then return a.missing end
        if a.price ~= b.price then return a.price > b.price end
        return a.name < b.name
    end)
    return targets
end

-- Which world owns a zone. The game ships GetWorldIdForZone for exactly this, so
-- use it and fall back to the index ranges only if it is ever removed.
local function worldIdForZone(zoneIndex)
    if type(WorldsConfig.GetWorldIdForZone) == "function" then
        local ok, id = pcall(WorldsConfig.GetWorldIdForZone, zoneIndex)
        if ok and id then return id end
    end
    for _, id in ipairs(worldOrder) do
        local world = WorldsConfig.Worlds[id]
        if world and zoneIndex >= (tonumber(world.FirstZoneIndex) or 0)
            and zoneIndex <= (tonumber(world.LastZoneIndex) or 0) then
            return id
        end
    end
    return tonumber(e.LootWorldId) or 1
end

-- Standing 215 studs from a zone is not standing in it. The first version called
-- anything under 220 "arrived", which read as success while every pickup stayed
-- out of reach and the character never moved again. A zone's SpawnZone is under
-- 100 studs across, so arrival has to be measured in tens.
local ZONE_ARRIVAL_RADIUS = 70
local lastStepZone, lastStepGap = nil, nil

-- Zones AND world folders both stream on player position -- World_2 lost its own
-- Spawn_Point the moment the character walked to World 3. So there is no fixed
-- landmark to jump to for a zone that has not loaded, and the world-spawn route
-- dead-ends whenever the destination world is the one not loaded.
--
-- Walking the index instead always works: hop to the loaded zone nearest the
-- target number, which pulls the next few zones into range, and repeat. The map
-- streams itself in as the character crosses it.
local function ensureInZone(zoneIndex)
    local hrp = humanoidRootPart()
    if not hrp then return false, "No character" end

    local spawnPart = zoneSpawnPart(zoneIndex)
    if spawnPart then
        if (spawnPart.Position - hrp.Position).Magnitude > ZONE_ARRIVAL_RADIUS then
            hrp.CFrame = CFrame.new(spawnPart.Position + Vector3.new(0, 6, 0))
            return false, "Travelling to zone " .. zoneIndex
        end
        lastStepZone, lastStepGap = nil, nil
        return true, nil
    end

    local zones = workspace:FindFirstChild("Zones")
    local stepPart, stepIndex
    if zones then
        local bestGap
        for _, zone in ipairs(zones:GetChildren()) do
            local index = tonumber(tostring(zone.Name):match("(%d+)$"))
            local part = zone:FindFirstChild("SpawnZone")
            if index and part and part:IsA("BasePart") then
                local gap = math.abs(index - zoneIndex)
                if not bestGap or gap < bestGap then
                    bestGap, stepPart, stepIndex = gap, part, index
                end
            end
        end
    end
    if stepPart then
        -- Only step if it genuinely closes the gap, and never straight back to the
        -- zone just left. Without this the walk ping-pongs between two loaded
        -- zones on either side of the target and the character drifts to nowhere
        -- -- measured at 240 studs from anything, still reporting "travelling".
        local gap = math.abs(stepIndex - zoneIndex)
        if lastStepZone and stepIndex == lastStepZone and lastStepGap and gap >= lastStepGap then
            return false, string.format("Zone %d will not stream in from here", zoneIndex)
        end
        lastStepZone, lastStepGap = stepIndex, gap
        hrp.CFrame = CFrame.new(stepPart.Position + Vector3.new(0, 6, 0))
        return false, string.format("Zone %d not loaded -- stepping via zone %d", zoneIndex, stepIndex)
    end

    local worldId = worldIdForZone(zoneIndex)
    local worldSpawn = worldSpawnPart(worldId)
    if worldSpawn then
        hrp.CFrame = CFrame.new(worldSpawn.Position + Vector3.new(0, 6, 0))
        return false, string.format("Travelling to %s for zone %d",
            tostring(WorldsConfig.Worlds[worldId] and WorldsConfig.Worlds[worldId].DisplayName or worldId), zoneIndex)
    end
    invokeRemote("BaseTeleportService", "TeleportToSpawn")
    return false, "Zone " .. zoneIndex .. " unreachable -- returning to spawn"
end

local function doAutoLoot()
    -- Auto Index runs this loop too. It used to only STEER Auto Loot, so
    -- switching Index on by itself did nothing at all -- toggle on, panel saying
    -- it was on, character standing still. That is the third time in this project
    -- a feature has been built to depend on another tab's switch, and it read as
    -- broken every single time. A toggle either does its job or it should not
    -- exist.
    if not (e.AutoLootEnabled or e.AutoIndexEnabled) then lootStatusText = "Toggle is OFF"; return end
    local hrp = humanoidRootPart()
    if not hrp then lootStatusText = "No character"; return end

    -- A full bag makes every prompt a no-op, so clearing it is not an
    -- optimisation, it is the difference between looting and spinning.
    --
    -- This used to bail with "switch Auto Sell on" and stop dead, which is how
    -- Auto Loot came to look broken the moment ten slots filled: the toggle was
    -- on, the panel said it was on, and nothing was collected ever again. Auto
    -- Loot now clears its own bag by default, because a feature that needs
    -- another tab switched on to do its one job is a trap, not a dependency.
    local slots = cachedBackpackSlots()
    if type(slots) == "table" then
        local count = tonumber(slots.Count) or 0
        local capacity = tonumber(slots.Capacity) or 0
        if capacity > 0 and count >= capacity then
            if e.LootSellWhenFull or e.AutoSellEnabled then
                doAutoSell(true)
                invalidateBackpackCache()
            else
                lootStatusText = string.format(
                    "Backpack full (%d/%d) -- switch on \"Sell when full\" or empty it", count, capacity)
                return
            end
        end
    end

    -- Auto Index drives the destination itself. Leaving the manual zone in charge
    -- would let the picker point at a zone whose rarities cannot roll anything
    -- still missing, which is a farm that can never finish.
    local zoneIndex, indexNote
    if e.AutoIndexEnabled then
        local zone, note = bestIndexZone()
        indexNote = note
        if not zone then lootStatusText = "Index: " .. tostring(note); return end
        zoneIndex = zone
    else
        zoneIndex = tonumber(e.LootZoneIndex) or 0
        if zoneIndex <= 0 then zoneIndex = currentZoneIndex() end
    end
    if not zoneIndex then lootStatusText = "Pick a zone first"; return end

    local inZone, travelNote = ensureInZone(zoneIndex)
    if not inZone then lootStatusText = tostring(travelNote); return end

    local targets = collectLootTargets((e.LootFollowBest and not e.AutoIndexEnabled) and nil or zoneIndex)
    if #targets == 0 then
        if e.AutoIndexEnabled then
            local data = lootIndexData()
            lootStatusText = string.format("Index %s/%s  |  zone %d [%s]  |  waiting for a respawn",
                tostring(type(data) == "table" and data.FoundCount or "?"),
                tostring(type(data) == "table" and data.TotalCount or "?"),
                zoneIndex, tostring(indexNote))
        else
            lootStatusText = string.format("Zone %d -- nothing above %s yet",
                zoneIndex, formatAmount(parseAmount(e.LootMinPrice) or 0))
        end
        return
    end

    local target = targets[1]
    -- The prompt only accepts a trigger within 5 studs (Loot.Spawn's own
    -- PickupPromptMaxActivationDistance), so stand on it rather than hoping.
    hrp.CFrame = CFrame.new(target.part.Position + Vector3.new(0, 3, 0))
    task.wait(0.15)
    local fired = pcall(function() fireproximityprompt(target.prompt) end)
    if fired then
        lootCollected += 1
        lootValueCollected += target.price
        invalidateBackpackCache()
        -- A first-ever find changes the whole plan -- the missing set shrinks and
        -- the best zone may move -- so do not serve a five-second-old index.
        if target.missing then invalidateIndexCache() end
    end

    if e.AutoIndexEnabled then
        local data = lootIndexData()
        lootStatusText = string.format("Index %s/%s  |  %s%s  |  zone %d [%s]",
            tostring(type(data) == "table" and data.FoundCount or "?"),
            tostring(type(data) == "table" and data.TotalCount or "?"),
            target.name, target.missing and "  << NEW" or "",
            zoneIndex, tostring(indexNote))
        return
    end
    lootStatusText = string.format("%s  %s  (%d left in zone %d)  |  session %d items, %s",
        target.name, formatAmount(target.price), #targets - 1, zoneIndex,
        lootCollected, formatAmount(lootValueCollected))
end

-- ===== Anti-AFK / reconnect =====
LocalPlayer.Idled:Connect(function()
    if not e.AntiAFKEnabled then return end
    pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
end)

if not getgenv().__CGAReconnectHooked then
    getgenv().__CGAReconnectHooked = true
    Players.PlayerRemoving:Connect(function(player)
        if player == LocalPlayer and getgenv().AutoReconnectEnabled then
            pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
        end
    end)
end

-- ===== UI =====
local MacLib = loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
local Window = MacLib:Window({
    Title = "Cut Grass",
    Subtitle = "v1.0",
    DragStyle = 1,
    ShowUserInfo = true,
    AcrylicBlur = false,
})

-- MacLib's Slider reads AbsoluteSize off the bar it just built, and on some
-- executor thread identities that read throws and takes the whole script with
-- it. Input and Dropdown are fine; only Slider needs the net.
local function safeSlider(section, settings, flag)
    local ok, result = pcall(function() return section:Slider(settings, flag) end)
    if ok and result then return result end
    return section:Label({
        Text = settings.Name .. " = " .. tostring(settings.Default) ..
            "\n(slider blocked -- set the getgenv() value directly)"
    })
end

local function safeInput(section, settings, flag)
    local ok, result = pcall(function() return section:Input(settings, flag) end)
    if ok and result then return result end
    return section:Label({Text = settings.Name .. "\n(input blocked -- set the getgenv() value directly)"})
end

local TabGroup = Window:TabGroup()
local Tabs = {
    Main    = TabGroup:Tab({Name = "Main",    Image = "rbxassetid://10723407389"}),
    Loot    = TabGroup:Tab({Name = "Loot",    Image = "rbxassetid://10723343321"}),
    Sell    = TabGroup:Tab({Name = "Sell",    Image = "rbxassetid://10734952273"}),
    Settings = TabGroup:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}

-- ----- Main -----
local MainLeft = Tabs.Main:Section({Side = "Left"})
MainLeft:Header({Text = "Auto Click"})
MainLeft:Toggle({
    Name = "Auto Click", Default = e.AutoClickEnabled,
    Callback = function(v) e.AutoClickEnabled = v; saveState() end,
}, "AutoClickEnabled")
-- Floor is the measured ceiling. Letting the box ask for 0.01s would only buy
-- 250 discarded calls every five seconds, which is how a working feature starts
-- looking broken.
safeInput(MainLeft, {
    Name = "Interval (0 = auto)", Placeholder = "0",
    Default = (tonumber(e.ClickInterval) or 0) > 0 and tostring(e.ClickInterval) or "",
    AcceptedCharacters = function(text) return (tostring(text):gsub("[^%d%.]", "")) end,
    Callback = function(text)
        local value = tonumber(text) or 0
        e.ClickInterval = value > 0 and math.max(CLICK_MIN_INTERVAL, value) or 0
        saveState()
    end,
}, "ClickIntervalInput")
MainLeft:Label({Text = "Auto fires 3x per server cooldown.\nFiring exactly at the cooldown loses half\nthe clicks -- the two clocks beat."})
local clickStatusLabel = MainLeft:Label({Text = "Idle"})

MainLeft:Header({Text = "Auto Rebirth"})
MainLeft:Toggle({
    Name = "Auto Rebirth", Default = e.AutoRebirthEnabled,
    Callback = function(v) e.AutoRebirthEnabled = v; saveState() end,
}, "AutoRebirthEnabled")
local rebirthStatusLabel = MainLeft:Label({Text = "Idle"})

local MainRight = Tabs.Main:Section({Side = "Right"})
MainRight:Header({Text = "Auto Training"})
MainRight:Toggle({
    Name = "Auto Training", Default = e.AutoTrainEnabled,
    Callback = function(v) e.AutoTrainEnabled = v; saveState() end,
}, "AutoTrainEnabled")

local trainPadLabelToIndex = {}
local function buildTrainPadOptions()
    trainPadLabelToIndex = {}
    local labels = {"Auto (best for your rebirth)"}
    trainPadLabelToIndex[labels[1]] = 0
    local state = rebirthState()
    local rebirthLevel = (type(state) == "table" and tonumber(state.RebirthLevel)) or 0
    for _, pad in ipairs(collectTrainPads()) do
        local label = string.format("%s%s", pad.name, pad.index <= rebirthLevel and "" or "   (locked)")
        if not trainPadLabelToIndex[label] then
            table.insert(labels, label)
            trainPadLabelToIndex[label] = pad.index
        end
    end
    return labels
end

local trainPadDropdown = MainRight:Dropdown({
    Name = "Train Pad", Options = buildTrainPadOptions(), Search = true,
    Default = "Auto (best for your rebirth)",
    Callback = function(selected)
        if selected and trainPadLabelToIndex[selected] then
            e.TrainPadPick = trainPadLabelToIndex[selected]
            saveState()
        end
    end,
}, "TrainPadDropdown")
MainRight:Button({Name = "Refresh Pad List", Callback = function()
    pcall(function()
        trainPadDropdown:ClearOptions()
        trainPadDropdown:InsertOptions(buildTrainPadOptions())
    end)
end})
-- Measured: 12.5 credited clicks/sec standing on TrainZone_10 against ~5/sec
-- clicking out in the open. The pad is the multiplier, so the two toggles are
-- not alternatives -- Training is where Auto Click stops being ordinary.
MainRight:Label({Text = "Clicking ON a pad measured 12.5/s vs ~5/s\nin the open. Run this WITH Auto Click."})
local trainStatusLabel = MainRight:Label({Text = "Idle"})

-- ----- Loot -----
local LootLeft = Tabs.Loot:Section({Side = "Left"})
LootLeft:Header({Text = "Auto Loot"})
LootLeft:Toggle({
    Name = "Auto Loot", Default = e.AutoLootEnabled,
    Callback = function(v) e.AutoLootEnabled = v; saveState() end,
}, "AutoLootEnabled")

local zoneLabelToIndex = {}
local zoneDropdown
local function currentWorldLabel()
    for label, id in pairs(worldLabelToId) do
        if id == e.LootWorldId then return label end
    end
    return worldOptions[1]
end
-- Zone list is rebuilt from the world's own FirstZoneIndex..LastZoneIndex range,
-- so picking a world immediately narrows the zone picker to that world's zones
-- rather than offering all 35 and letting you choose an impossible one.
local function refreshZoneOptions()
    local labels, labelToIndex = zonesForWorld(e.LootWorldId)
    zoneLabelToIndex = labelToIndex
    pcall(function()
        zoneDropdown:ClearOptions()
        zoneDropdown:InsertOptions(labels)
    end)
    -- A zone from the previous world cannot survive the switch.
    if not labelToIndex[zoneLabelFor(tonumber(e.LootZoneIndex) or 0)] then
        local world = WorldsConfig.Worlds[e.LootWorldId]
        e.LootZoneIndex = world and tonumber(world.FirstZoneIndex) or 0
        saveState()
    end
end

LootLeft:Dropdown({
    Name = "Select World", Options = worldOptions,
    Default = currentWorldLabel(),
    Callback = function(selected)
        local id = selected and worldLabelToId[selected]
        if id then
            e.LootWorldId = id
            saveState()
            refreshZoneOptions()
        end
    end,
}, "LootWorldDropdown")

zoneDropdown = LootLeft:Dropdown({
    Name = "Select Zone", Options = (select(1, zonesForWorld(e.LootWorldId))), Search = true,
    Default = zoneLabelFor(tonumber(e.LootZoneIndex) or 0),
    Callback = function(selected)
        local index = selected and zoneLabelToIndex[selected]
        if index then e.LootZoneIndex = index; saveState() end
    end,
}, "LootZoneDropdown")
zoneLabelToIndex = select(2, zonesForWorld(e.LootWorldId))

safeInput(LootLeft, {
    Name = "Min Price", Placeholder = "0 / 1m / 150m / 1.5b",
    Default = (tonumber(e.LootMinPrice) or 0) > 0 and formatAmount(e.LootMinPrice) or "",
    AcceptedCharacters = function(text) return (tostring(text):gsub("[^%d%.kmbtqKMBTQ]", "")) end,
    Callback = function(text)
        local amount = parseAmount(text)
        if amount then e.LootMinPrice = amount; saveState() end
    end,
}, "LootMinPriceInput")
LootLeft:Toggle({
    Name = "Grab from any loaded zone", Default = e.LootFollowBest,
    Callback = function(v) e.LootFollowBest = v; saveState() end,
}, "LootFollowBest")
LootLeft:Toggle({
    Name = "Sell when full (keeps looting)", Default = e.LootSellWhenFull,
    Callback = function(v) e.LootSellWhenFull = v; saveState() end,
}, "LootSellWhenFull")
LootLeft:Label({Text = "Always takes the highest sell price first,\nso a bag that fills up fills with the best."})
local lootStatusLabel = LootLeft:Label({Text = "Idle"})

local LootRight = Tabs.Loot:Section({Side = "Right"})
LootRight:Header({Text = "Auto Index"})
LootRight:Toggle({
    Name = "Auto Index (collect what's missing)", Default = e.AutoIndexEnabled,
    Callback = function(v) e.AutoIndexEnabled = v; invalidateIndexCache(); saveState() end,
}, "AutoIndexEnabled")
LootRight:Toggle({
    Name = "Only pick up missing items", Default = e.IndexOnlyMissing,
    Callback = function(v) e.IndexOnlyMissing = v; saveState() end,
}, "IndexOnlyMissing")
LootRight:Label({Text = "Works on its own -- Auto Loot not required.\nPicks the zone whose rarities can still roll\nsomething new, and ignores Min Price so a\nfirst find is never filtered out."})
local indexStatusLabel = LootRight:Label({Text = "Index: reading..."})

LootRight:Header({Text = "On The Ground"})
local lootBoardLabel = LootRight:Label({Text = "Scanning..."})
LootRight:Button({Name = "Teleport To Selected Zone", Callback = function()
    task.spawn(function()
        local index = tonumber(e.LootZoneIndex) or 0
        if index <= 0 then return end
        local ok, note = ensureInZone(index)
        lootStatusText = ok and ("Arrived at zone " .. index) or tostring(note)
    end)
end})

-- ----- Sell -----
local SellLeft = Tabs.Sell:Section({Side = "Left"})
SellLeft:Header({Text = "Auto Sell"})
SellLeft:Toggle({
    Name = "Auto Sell", Default = e.AutoSellEnabled,
    Callback = function(v) e.AutoSellEnabled = v; saveState() end,
}, "AutoSellEnabled")
SellLeft:Toggle({
    Name = "Only when backpack is full", Default = e.SellWhenFull,
    Callback = function(v) e.SellWhenFull = v; saveState() end,
}, "SellWhenFull")
safeSlider(SellLeft, {
    Name = "Interval", Minimum = 1, Maximum = 60,
    Default = e.SellIntervalSeconds, Precision = 0, Suffix = "s",
    Callback = function(v) e.SellIntervalSeconds = math.floor(tonumber(v) or 5); saveState() end,
}, "SellIntervalSlider")
SellLeft:Label({Text = "Sells through the server directly.\nNo walking to the shop NPC."})
SellLeft:Button({Name = "Sell Everything Now", Callback = function()
    task.spawn(function() pcall(doAutoSell, true) end)
end})
local sellStatusLabel = SellLeft:Label({Text = "Idle"})

local SellRight = Tabs.Sell:Section({Side = "Right"})
SellRight:Header({Text = "Backpack"})
local backpackLabel = SellRight:Label({Text = "Reading..."})

-- ----- Settings -----
local SettingsLeft = Tabs.Settings:Section({Side = "Left"})
SettingsLeft:Header({Text = "General"})
SettingsLeft:Toggle({
    Name = "Anti-AFK", Default = e.AntiAFKEnabled,
    Callback = function(v) e.AntiAFKEnabled = v; saveState() end,
}, "AntiAFKEnabled")
SettingsLeft:Toggle({
    Name = "Auto Reconnect", Default = e.AutoReconnectEnabled,
    Callback = function(v) e.AutoReconnectEnabled = v; saveState() end,
}, "AutoReconnectEnabled")
pcall(function()
    SettingsLeft:Keybind({
        Name = "Show/Hide UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
        Callback = function() pcall(function() Window:SetState(not Window:GetState()) end) end,
    }, "CutGrassToggleUIKeybind")
end)
SettingsLeft:Label({Text = "Auto-saved to " .. SAVE_FILE})
local sessionLabel = SettingsLeft:Label({Text = "Uptime 00:00:00"})
-- Every loop below spins on this generation check, so bumping it is a real
-- shutdown rather than a window that disappears while ten threads keep firing.
SettingsLeft:Button({Name = "Unload Script", Callback = function()
    getgenv().__CGA = myGen + 1
    saveState()
    task.spawn(function()
        task.wait(0.5)
        pcall(function() Window:Unload() end)
        getgenv().__CGAWindow = nil
        print("[CutGrass] unloaded (gen " .. myGen .. ")")
    end)
end})

-- ===== Background loops =====
-- Short fixed slice, well under the interval. doAutoClick's own os.clock gate is
-- the pacer; this loop only has to wake often enough not to miss the window.
task.spawn(function()
    while getgenv().__CGA == myGen do
        pcall(doAutoClick)
        task.wait(0.03)
    end
end)

task.spawn(function()
    while getgenv().__CGA == myGen do
        pcall(refreshClickRate)
        pcall(function() clickStatusLabel:UpdateName(clickStatusText) end)
        task.wait(1)
    end
end)

task.spawn(function()
    while getgenv().__CGA == myGen do
        pcall(doAutoTrain)
        pcall(function() trainStatusLabel:UpdateName(trainStatusText) end)
        task.wait(0.5)
    end
end)

task.spawn(function()
    while getgenv().__CGA == myGen do
        pcall(doAutoRebirth)
        pcall(function() rebirthStatusLabel:UpdateName(rebirthStatusText) end)
        task.wait(3)
    end
end)

task.spawn(function()
    while getgenv().__CGA == myGen do
        pcall(doAutoLoot)
        pcall(function() lootStatusLabel:UpdateName(lootStatusText) end)
        task.wait(0.35)
    end
end)

task.spawn(function()
    while getgenv().__CGA == myGen do
        pcall(doAutoSell)
        pcall(function() sellStatusLabel:UpdateName(sellStatusText) end)
        task.wait(1)
    end
end)

-- Read-only panels on their own slower cadence: a full loot scan across every
-- loaded zone is far too heavy to run at the pickup loop's rate.
task.spawn(function()
    while getgenv().__CGA == myGen do
        pcall(function()
            local state = backpackState()
            if type(state) == "table" then
                backpackLabel:UpdateName(string.format("%d / %d slots\nWorth %s  (x%s multiplier)",
                    tonumber(state.Count) or 0, tonumber(state.Capacity) or 0,
                    formatAmount(state.TotalSellPrice), tostring(state.MoneyMultiplier or 1)))
            end
        end)
        pcall(function()
            local targets = collectLootTargets(e.LootFollowBest and nil or (tonumber(e.LootZoneIndex) or 0) > 0 and tonumber(e.LootZoneIndex) or nil)
            local lines = {}
            for index = 1, math.min(8, #targets) do
                local target = targets[index]
                table.insert(lines, string.format("%s  %s", formatAmount(target.price), target.name))
            end
            lootBoardLabel:UpdateName(#lines > 0
                and (table.concat(lines, "\n") .. string.format("\n(%d total)", #targets))
                or "Nothing on the ground here")
        end)
        pcall(function()
            local data = lootIndexData()
            if type(data) ~= "table" then return end
            local missing, byRarity = missingItems()
            local zone, note = bestIndexZone()
            local rarities = {}
            for rarity, count in pairs(byRarity) do table.insert(rarities, rarity .. " x" .. count) end
            table.sort(rarities)
            indexStatusLabel:UpdateName(string.format(
                "%s / %s found  (next bonus at %s%%, x%s)\nMissing: %s\n%s",
                tostring(data.FoundCount), tostring(data.TotalCount),
                tostring(data.StepPercent), tostring(data.NextStrengthMultiplier),
                #rarities > 0 and table.concat(rarities, ", ") or "nothing",
                zone and ("-> Zone " .. zone .. "  [" .. tostring(note) .. "]") or tostring(note)))
        end)
        pcall(function()
            local seconds = math.floor(os.clock() - SESSION_START)
            sessionLabel:UpdateName(string.format("Uptime %02d:%02d:%02d  |  gen %d",
                math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60, myGen))
        end)
        task.wait(1)
    end
end)

refreshZoneOptions()
saveState()
getgenv().__CGAWindow = Window
pcall(function() Tabs.Main:Select() end)
print(string.format("[CutGrass] v1.0 loaded (gen %d, %d loot items, %d worlds, %s)",
    myGen, lootItemCount, #worldOptions, os.date("%H:%M:%S")))
