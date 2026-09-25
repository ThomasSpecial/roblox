-- Open Sea For Animals [placeId 88047783411976] -- sea-wave sniping / hatchery / power / rewards automation + UI
--
-- Ported into our own MacLib theme from the third-party "2K" build the loader
-- used to hand this place to. Every remote below was verified live against
-- the running game (2026-09-25, account Chekkadeiz) before being wired:
--   - The game is Knit-based. Remotes live under
--     ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services
--     .<Service>.RF/<name> (RemoteFunctions) and .RE/<name> (RemoteEvents).
--     Services + RF confirmed: WaveService{Start,Finished,...},
--     EggService{PlaceEgg,HatchEgg}, AnimalService{EquipBest,CollectOfflineCash},
--     InventoryService{SellEgg,SellAllBrainrots}, TrainingService{StartTraining,
--     StopTraining,BuyTrainTool,EquipTrainTool,ClaimBonus | RE SpawnBonus},
--     PickaxeService{BuyPickaxe,EquipPickaxe}, UpgradesService{Upgrade},
--     RebirthService{Rebirth}, PlaytimeRewardService{ClaimGift},
--     DailyRewardService{ClaimReward,ClaimVIPReward}, FreeShopService{Claim},
--     SpinWheelService{SpinAll}, RewardService{GroupReward},
--     SeasonPassService{ClaimPassReward}, QuestService{ClaimReward},
--     PotionService{UsePotion}, CodesService{RedeemCode}.
--   - Player data is the Knit ReplicaController's GetPlayerData() table:
--     Currencies{Cash,LuminousCoins,PassExp}, Inventory{[id]={itemType="Egg"|
--     "Brainrot", innerEntity={eggType|brainrotType}}}, PlacedEggs, Upgrades
--     {PlotUpgrade,MovementSpeed,Carry}, Rebirth, OwnedTrainTools,
--     EquippedTrainTool, OwnedPickaxes, EquippedPickaxe, OfflineCash,
--     LastFreeShopClaim, DailyReward, Gamepasses, RedeemedGroupReward,
--     SeasonPass{Exp,Free}, Quests, PotionInventory, ActivePotions.
--   - Configs under ReplicatedStorage.Configs: TrainToolConfig.TRAIN_TOOLS
--     [id]={cost,gainPerTrain,isSpecial}, StaffConfig[id]={cost,reach},
--     UpgradeConfig.GetPrice/GetMaxBuyable, RebirthConfig.REBIRTH[n]={Cost=
--     {Cash},CashMulti}, FreeShopConfig.CURRENT_CLAIM_INDEX, SeasonPassConfig
--     .Level.
--   - Sea wave: WaveService.RF.Start(5) answers {spawns={[id]={entity={eggType,
--     mutation,size}, bossId}}}; Finished({id,...}) collects those ids and
--     closes the wave. The player attribute IsWaveActive is true while one
--     is open. Picking the single best id from the spawn list and finishing
--     immediately is the "packet snipe".
--   - Plot: GameShared.PlotUtils.GetPlayerPlot(plr) -> workspace.Plots.<n>;
--     eggs placed there sit in its Eggs folder with attributes EggId,
--     StartTime, Duration (hatch when StartTime+Duration <= server time).
--     PlotSurface is the part eggs get placed on (PlaceEgg(id, CFrame)).
--     Plot holds at most 10 eggs.
--   - Revive/skip/instant-hatch prompts (InitSkip, Prompt*Tier, VideoAd) are
--     Robux or ad flows and are never called.

getgenv().__OS = (getgenv().__OS or 0) + 1
local G = getgenv().__OS
pcall(function() if getgenv().__OSW then getgenv().__OSW:Unload() end end)
local e = getgenv()
local myUID = tostring(math.random(1, 2 ^ 30))
e.__osTok = myUID
print("[OpenSea] Starting (gen " .. G .. ")...")

local OPEN_SEA = 88047783411976
if game.PlaceId ~= OPEN_SEA then print("[OpenSea] Wrong place, aborting") return end

local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local VirtualUser = game:GetService("VirtualUser")
local plr = Players.LocalPlayer

-- ---------------------------------------------------------------- Knit access
-- Seen live on this place: ReplicatedStorage.Packages / _Index lookups come
-- back EMPTY for a few seconds at a time (one probe even got "Packages is
-- not a valid member of ReplicatedStorage") and are fine again a moment
-- later -- the game's loader shuffles things while it boots. So nothing
-- here aborts on a miss: every lookup retries, and the Services folder is
-- re-resolved on demand (by walking for the folder that holds WaveService)
-- instead of being captured once.
local Knit = nil
for _ = 1, 120 do
	local pk = RS:FindFirstChild("Packages")
	local km = pk and pk:FindFirstChild("Knit")
	if km then
		local ok, m = pcall(require, km)
		if ok and type(m) == "table" and m.GetController then Knit = m break end
	end
	task.wait(0.5)
end
if not Knit then print("[OpenSea] Knit not found after 60s, aborting") return end

local knitServices = nil
local function findServices()
	if knitServices and knitServices.Parent and knitServices:FindFirstChild("WaveService") then return knitServices end
	local pk = RS:FindFirstChild("Packages")
	local idx = pk and pk:FindFirstChild("_Index")
	if idx then
		for _, c in ipairs(idx:GetChildren()) do
			local k = c:FindFirstChild("knit")
			local s = k and k:FindFirstChild("Services")
			if s and s:FindFirstChild("WaveService") then knitServices = s return s end
		end
	end
	for _, d in ipairs(RS:GetDescendants()) do
		if d.Name == "Services" and d:FindFirstChild("WaveService") then knitServices = d return d end
	end
	return nil
end
for _ = 1, 120 do
	if findServices() then break end
	task.wait(0.5)
end
print("[OpenSea] Knit services: " .. tostring(knitServices and knitServices:GetFullName()))

-- call("WaveService", "Start", 5) -> pcall'd InvokeServer on Services.WaveService.RF.Start
local function call(service, name, ...)
	local args = {...}
	local folder = findServices()
	local s = folder and folder:FindFirstChild(service)
	local rf = s and s:FindFirstChild("RF")
	local remote = rf and rf:FindFirstChild(name)
	if not remote then return false, "missing:" .. service .. "." .. name end
	return pcall(function() return remote:InvokeServer(table.unpack(args)) end)
end
local function signal(service, name)
	local folder = findServices()
	local s = folder and folder:FindFirstChild(service)
	local re = s and s:FindFirstChild("RE")
	return re and re:FindFirstChild(name) or nil
end

local Replica = nil
local function pdata()
	if not Replica then
		local ok, c = pcall(function() return Knit.GetController("ReplicaController") end)
		if ok and c then Replica = c else return nil end
	end
	local ok, d = pcall(function() return Replica:GetPlayerData() end)
	return ok and type(d) == "table" and d or nil
end
-- configs are resolved lazily (and cached once found) for the same reason
local cfgCache = {}
local function cfg(name)
	if cfgCache[name] then return cfgCache[name] end
	local c = RS:FindFirstChild("Configs")
	local m = c and c:FindFirstChild(name)
	if not m then return nil end
	local ok, t = pcall(require, m)
	if ok and type(t) == "table" then cfgCache[name] = t return t end
	return nil
end
local PlotUtils = nil
local function plotUtils()
	if PlotUtils then return PlotUtils end
	local gs = RS:FindFirstChild("GameShared")
	local m = gs and gs:FindFirstChild("PlotUtils")
	if m then local ok, t = pcall(require, m) if ok then PlotUtils = t end end
	return PlotUtils
end

-- ---------------------------------------------------------------- state/config
local SF = "OpenSea/state.json"
local SK = {
	"osWave", "osHuntBoss", "osMinRarity", "osSpecificEgg", "osMutations", "osWaveDelay",
	"osSellEggs", "osSellRarities", "osSellMutations", "osSellSizes", "osHatch", "osEquipBest", "osSellAnimals", "osOfflineCash",
	"osTrain", "osTrainRing", "osBuyDumbbell", "osBuyStaff",
	"osUpPlot", "osUpSpeed", "osUpCarry", "osRebirth", "osRebirthTarget",
	"osPlaytime", "osDaily", "osFreeShop", "osSpin", "osGroup", "osSeasonPass", "osQuests",
	"osPotions", "osPotionTrain", "osPotionCash", "osPotionLuck",
	"osSpeedEnabled", "osSpeedValue",
	"osAntiAFK", "osAutoReconnect",
}
pcall(function() if not isfolder("OpenSea") then makefolder("OpenSea") end end)
local function sv()
	local d = {}
	for _, k in ipairs(SK) do d[k] = e[k] end
	pcall(function() writefile(SF, HS:JSONEncode(d)) end)
end
pcall(function()
	local d = HS:JSONDecode(readfile(SF))
	for _, k in ipairs(SK) do if d[k] ~= nil and e[k] == nil then e[k] = d[k] end end
end)
local function def(k, v) if e[k] == nil then e[k] = v end end
def("osWave", true); def("osHuntBoss", true); def("osMinRarity", 1); def("osSpecificEgg", "All")
def("osMutations", true); def("osWaveDelay", 2)
def("osSellEggs", false)
-- Rarities to sell: multi-select, stored as an array of rarity names. An
-- EMPTY pick sells nothing (the one filter where "empty = everything"
-- would be a disaster). Old single-pick saves ("Common - Rare" etc.) are
-- migrated into the equivalent set.
if type(e.osSellRarities) ~= "table" then
	local old = e.osSellRarity
	local upto = (old == "Common - Rare" and 3) or (old == "Common - Epic" and 4) or (old == "Common - Legendary" and 5) or nil
	if upto then
		e.osSellRarities = {}
		for i = 1, upto do e.osSellRarities[i] = ({"Common", "Uncommon", "Rare", "Epic", "Legendary"})[i] end
	elseif type(old) == "string" and old ~= "" then
		e.osSellRarities = {old}
	else
		e.osSellRarities = {"Common", "Uncommon", "Rare"}
	end
end
-- multi-select filters on top of rarity: an egg is only sold when its
-- mutation AND size are both in the picks (arrays of names, the shape
-- MacLib's multi Default wants back). Empty pick = that filter is off.
if type(e.osSellMutations) ~= "table" then e.osSellMutations = {"NORMAL"} end
if type(e.osSellSizes) ~= "table" then e.osSellSizes = {} end
def("osHatch", true); def("osEquipBest", true); def("osSellAnimals", false); def("osOfflineCash", true)
def("osTrain", true); def("osTrainRing", true); def("osBuyDumbbell", true); def("osBuyStaff", true)
def("osUpPlot", true); def("osUpSpeed", true); def("osUpCarry", true); def("osRebirth", false); def("osRebirthTarget", 0)
def("osPlaytime", true); def("osDaily", true); def("osFreeShop", true); def("osSpin", true); def("osGroup", true)
def("osSeasonPass", true); def("osQuests", true)
def("osPotions", false); def("osPotionTrain", true); def("osPotionCash", true); def("osPotionLuck", true)
def("osSpeedEnabled", false); def("osSpeedValue", 46)
def("osAntiAFK", true); def("osAutoReconnect", true)

local stats = {waves = 0, eggsTaken = 0, lastEgg = "-", eggsSold = 0, placed = 0, hatched = 0,
	trains = 0, ringStarts = 0, bonuses = 0, buys = 0, upgrades = 0, rebirths = 0, claims = 0, note = "-"}
e.__osStats = stats   -- exposed for live probes only

-- ---------------------------------------------------------------- egg tables
-- Rarity rank order is the one the game's egg list uses; eggType ids come
-- straight from the spawn/inventory entries.
local RARITIES = {"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Divine", "Secret", "Cosmic",
	"Eternal", "SPECIAL", "CYBER", "LAW", "Titanium", "Magical", "Nightfall", "Frosty", "Lightning"}
local RARITY_RANK = {}
for i, r in ipairs(RARITIES) do RARITY_RANK[r] = i end
local EGG_RARITY = {
	basic_egg = "Common", frogs_egg = "Uncommon", bats_egg = "Rare", tigers_egg = "Epic", trex_egg = "Legendary",
	snails_egg = "Mythic", capybara_egg = "Divine", osctrich_egg = "Secret", snake_egg = "Cosmic",
	sphinx_egg = "Eternal", mouse_egg = "Eternal", dragon_egg = "SPECIAL", polarbear_egg = "SPECIAL",
	seal_egg = "SPECIAL", gorilla_egg = "CYBER", mamut_egg = "LAW", ocean_egg = "Titanium", deer_egg = "Magical",
	sleepy_egg = "Nightfall", glacial_egg = "Frosty", volt_egg = "Lightning", flame_egg = "SPECIAL",
	angelic_egg = "SPECIAL", unicorn_egg = "SPECIAL", talon_egg = "SPECIAL",
}
local EGG_LIST = {
	{"Basic Egg", "basic_egg"}, {"Frog Egg", "frogs_egg"}, {"Bat Egg", "bats_egg"}, {"Tiger Egg", "tigers_egg"},
	{"Trex Egg", "trex_egg"}, {"Snails Egg", "snails_egg"}, {"Capybara Egg", "capybara_egg"},
	{"Osctrich Egg", "osctrich_egg"}, {"Snake Egg", "snake_egg"}, {"Sphinx Egg", "sphinx_egg"},
	{"Dragon Egg", "dragon_egg"}, {"Mouse Egg", "mouse_egg"}, {"Polarbear Egg", "polarbear_egg"},
	{"Seal Egg", "seal_egg"}, {"Gorilla Egg", "gorilla_egg"}, {"Mamut Egg", "mamut_egg"},
	{"Ocean Egg", "ocean_egg"}, {"Corals Egg", "deer_egg"}, {"Sleepy Egg", "sleepy_egg"},
	{"Glacial Egg", "glacial_egg"}, {"Volt Egg", "volt_egg"}, {"Flame Egg", "flame_egg"},
	{"Angelic Egg", "angelic_egg"}, {"Unicorn Egg", "unicorn_egg"}, {"Talon Egg", "talon_egg"},
}
local EGG_NAME_OPTIONS, EGG_ID_BY_NAME = {"All"}, {}
for _, p in ipairs(EGG_LIST) do EGG_NAME_OPTIONS[#EGG_NAME_OPTIONS + 1] = p[1]; EGG_ID_BY_NAME[p[1]] = p[2] end
local MIN_RARITY_OPTIONS = {}
for i, r in ipairs(RARITIES) do MIN_RARITY_OPTIONS[i] = (i == 1) and "All (Common+)" or (r .. "+") end
local SELL_OPTIONS = {}
for _, r in ipairs(RARITIES) do SELL_OPTIONS[#SELL_OPTIONS + 1] = r end
local function rankOf(eggType) return RARITY_RANK[EGG_RARITY[eggType] or "Common"] or 1 end
-- Mutation / size vocab, read from the game's own configs (inventory eggs
-- carry innerEntity.mutation -- nil meaning NORMAL -- and innerEntity.size).
-- Seen live: mutation GOLD/DIAMOND/RAINBOW/RADIOACTIVE, size baby/big.
-- Option labels carry the game's own cashMulti so the pick reads as
-- "Diamond (x1.5)"; the id ("DIAMOND") is what gets stored and compared.
-- Read live from MutationConfig / SizeConfig.SIZES: NORMAL x1, GOLD x1.25,
-- DIAMOND x1.5, RADIOACTIVE x1.75, RAINBOW x2; baby x1, big x1.25, huge x1.5.
local MUTATION_OPTIONS, MUTATION_ID_BY_LABEL, MUTATION_LABEL_BY_ID = {}, {}, {}
local SIZE_OPTIONS, SIZE_ID_BY_LABEL, SIZE_LABEL_BY_ID = {}, {}, {}
local function buildOptions(defs, fallback, options, idByLabel, labelById)
	local list = {}
	if type(defs) == "table" then
		for k, v in pairs(defs) do
			if type(v) == "table" then
				local id = (type(v.id) == "string" and v.id) or (type(k) == "string" and k) or nil
				if id then list[#list + 1] = {id = id, name = tostring(v.name or id), mult = tonumber(v.cashMulti) or 1} end
			end
		end
	end
	if #list == 0 then for _, f in ipairs(fallback) do list[#list + 1] = f end end
	table.sort(list, function(a, b) if a.mult ~= b.mult then return a.mult < b.mult end return a.name < b.name end)
	for _, it in ipairs(list) do
		local label = ("%s (x%s)"):format(it.name, tostring(it.mult))
		options[#options + 1] = label
		idByLabel[label] = it.id
		labelById[it.id] = label
	end
end
local mcfg = cfg("MutationConfig")
buildOptions(mcfg, {{id = "NORMAL", name = "Normal", mult = 1}, {id = "GOLD", name = "Gold", mult = 1.25}, {id = "DIAMOND", name = "Diamond", mult = 1.5},
	{id = "RADIOACTIVE", name = "Radioactive", mult = 1.75}, {id = "RAINBOW", name = "Rainbow", mult = 2}}, MUTATION_OPTIONS, MUTATION_ID_BY_LABEL, MUTATION_LABEL_BY_ID)
local scfg = cfg("SizeConfig")
buildOptions(type(scfg) == "table" and scfg.SIZES or nil, {{id = "baby", name = "Baby", mult = 1}, {id = "big", name = "Big", mult = 1.25}, {id = "huge", name = "Huge", mult = 1.5}},
	SIZE_OPTIONS, SIZE_ID_BY_LABEL, SIZE_LABEL_BY_ID)
local function idsToLabels(ids, labelById)
	local out = {}
	for _, id in ipairs(type(ids) == "table" and ids or {}) do if labelById[id] then out[#out + 1] = labelById[id] end end
	return out
end
local function inPick(pick, value)
	if type(pick) ~= "table" or #pick == 0 then return true end
	for _, v in ipairs(pick) do if v == value then return true end end
	return false
end

-- ---------------------------------------------------------------- plot helpers
local function myPlot()
	local pu = plotUtils()
	if pu and pu.GetPlayerPlot then
		local ok, p = pcall(pu.GetPlayerPlot, plr)
		if ok and p then return p end
	end
	local ok, id = call("PlotService", "GetMyPlotId")
	local plots = workspace:FindFirstChild("Plots")
	if ok and id and plots then
		local p = plots:FindFirstChild(tostring(id))
		if p then return p:FindFirstChild(tostring(id)) or p end
	end
	if plots then
		for _, p in ipairs(plots:GetChildren()) do
			if p:GetAttribute("Owner") == plr.UserId then return p:FindFirstChild(p.Name) or p end
		end
	end
	return nil
end
local function trainingController()
	local ok, tc = pcall(function() return Knit.GetController("TrainingController") end)
	return ok and tc or nil
end
local function teleport(cf)
	-- the ring's PreSimulation hook snaps the character back onto the
	-- StandPart every frame while training, so leave the ring first
	local tc = trainingController()
	if tc and tc.IsTraining and tc:IsTraining() then pcall(function() tc:StopTraining(true) end) task.wait(0.1) end
	local char = plr.Character
	if char and char.PrimaryPart then pcall(function() char:PivotTo(cf) end) end
end

-- ---------------------------------------------------------------- Sea wave sniping
-- One wave: Start(5) -> score every spawn -> Finished({bestId}) (or {} to
-- close it without taking junk). Score = rarity rank * 10000, + boss bonus,
-- + mutation bonus, + size bonus. Filters: minimum rarity, a specific egg.
local sniping = false
local function bestSpawn(spawns)
	local minRank = tonumber(e.osMinRarity) or 1
	local specific = EGG_ID_BY_NAME[e.osSpecificEgg]
	local bestId, bestScore, bestType = nil, -1, nil
	for id, s in pairs(spawns) do
		local ent = type(s) == "table" and s.entity or nil
		local eggType = ent and ent.eggType
		if eggType then
			local rank = rankOf(eggType)
			local isBoss = (s.bossId ~= nil) or eggType == "dragon_egg" or eggType == "polarbear_egg" or eggType == "mouse_egg"
			if (specific == nil or eggType == specific) and rank >= minRank then
				local score = rank * 10000
				if isBoss then score += (e.osHuntBoss and 200000 or 50000) end
				if ent.mutation and ent.mutation ~= "NORMAL" then score += (e.osMutations and 30000 or 5000) end
				if ent.size == "huge" then score += 20000 elseif ent.size == "big" then score += 10000 end
				if score > bestScore then bestId, bestScore, bestType = id, score, eggType end
			end
		end
	end
	return bestId, bestType
end
local function runWave()
	if sniping or plr:GetAttribute("IsWaveActive") then return end
	local char = plr.Character
	if not (char and char.PrimaryPart) then return end
	sniping = true
	task.spawn(function()
		pcall(function()
			local ok, res = call("WaveService", "Start", 5)
			if ok and type(res) == "table" and type(res.spawns) == "table" then
				stats.waves += 1
				local id, eggType = bestSpawn(res.spawns)
				task.wait(0.12)
				if id then
					local ok2 = call("WaveService", "Finished", {id})
					if ok2 then stats.eggsTaken += 1; stats.lastEgg = tostring(eggType) end
				else
					call("WaveService", "Finished", {})
				end
			end
		end)
		task.wait(math.clamp(tonumber(e.osWaveDelay) or 2, 1, 10))
		sniping = false
	end)
end
task.spawn(function()
	while getgenv().__OS == G do
		if e.osWave then pcall(runWave) end
		task.wait(1)
	end
end)
-- event bosses (DEVIL / ZEUS) show up as children of RS.ActiveEvents; a wave
-- opened while one is up is where dragon eggs come from
task.spawn(function()
	local ae = RS:FindFirstChild("ActiveEvents")
	if ae then
		ae.ChildAdded:Connect(function(c)
			if getgenv().__OS == G and e.osHuntBoss and (c.Name == "DEVIL" or c.Name == "ZEUS") then
				stats.note = "event boss: " .. c.Name
				task.wait(0.5)
				pcall(runWave)
			end
		end)
	end
end)

-- ---------------------------------------------------------------- eggs / animals / plot
local function sellEggs()
	local d = pdata()
	if not (d and d.Inventory) then return 0 end
	local picks = type(e.osSellRarities) == "table" and e.osSellRarities or {}
	if #picks == 0 then return 0 end
	local sold = 0
	for id, it in pairs(d.Inventory) do
		if it.itemType == "Egg" and it.innerEntity and it.innerEntity.eggType then
			local r = EGG_RARITY[it.innerEntity.eggType] or "Common"
			local want = table.find(picks, r) ~= nil
			local mutation = it.innerEntity.mutation or "NORMAL"
			local size = it.innerEntity.size or "baby"
			if want and not inPick(e.osSellMutations, mutation) then want = false end
			if want and not inPick(e.osSellSizes, size) then want = false end
			if want then
				if call("InventoryService", "SellEgg", id) then sold += 1 end
				task.wait(0.05)
			end
		end
	end
	stats.eggsSold += sold
	return sold
end
local function sellUnusedAnimals()
	call("AnimalService", "EquipBest")
	task.wait(0.2)
	call("InventoryService", "SellAllBrainrots")
end

local lastEquipBest, plotFullUntil = 0, 0
task.spawn(function()
	while getgenv().__OS == G do
		pcall(function()
			local d = pdata()
			if not d then return end
			if e.osSellEggs then sellEggs() end

			if e.osHatch and d.Inventory and os.clock() > plotFullUntil then
				local placed = 0
				for _ in pairs(d.PlacedEggs or {}) do placed += 1 end
				if placed >= 10 then
					plotFullUntil = os.clock() + 20
				else
					local plot = myPlot()
					local surface = plot and plot:FindFirstChild("PlotSurface", true)
					if surface then
						for id, it in pairs(d.Inventory) do
							if it.itemType == "Egg" or (it.innerEntity and it.innerEntity.eggType) then
								local cf = surface.CFrame * CFrame.new(math.random(-15, 15), 1.5, math.random(-15, 15))
								local ok, res = call("EggService", "PlaceEgg", id, cf)
								if ok and res == false then plotFullUntil = os.clock() + 20 break end
								stats.placed += 1
								placed += 1
								if placed >= 10 then plotFullUntil = os.clock() + 20 break end
								task.wait(0.15)
							end
						end
					end
				end
			end

			if e.osHatch then
				local plot = myPlot()
				local eggs = plot and plot:FindFirstChild("Eggs", true)
				if eggs then
					local now = workspace:GetServerTimeNow()
					for _, m in ipairs(eggs:GetChildren()) do
						local id = m:GetAttribute("EggId")
						local startT, dur = tonumber(m:GetAttribute("StartTime")) or 0, tonumber(m:GetAttribute("Duration")) or 120
						if id and startT + dur <= now then
							if call("EggService", "HatchEgg", id) then stats.hatched += 1 end
							task.wait(0.12)
						end
					end
				end
			end

			if e.osEquipBest and os.clock() - lastEquipBest >= 15 then
				lastEquipBest = os.clock()
				call("AnimalService", "EquipBest")
			end

			if e.osSellAnimals and d.Inventory then
				for _, it in pairs(d.Inventory) do
					if it.itemType == "Brainrot" or (it.innerEntity and it.innerEntity.brainrotType) then
						sellUnusedAnimals()
						break
					end
				end
			end

			if e.osOfflineCash and (tonumber(d.OfflineCash) or 0) > 0 then
				call("AnimalService", "CollectOfflineCash")
			end
		end)
		task.wait(2)
	end
end)

-- ---------------------------------------------------------------- training / gear
local function stopTraining()
	call("TrainingService", "StopTraining")
	pcall(function()
		local tc = Knit.GetController("TrainingController")
		if tc and tc.StopTraining then tc:StopTraining(true) end
	end)
	pcall(function()
		local char = plr.Character
		if char then
			char:SetAttribute("IsTrainingLocal", nil)
			char:SetAttribute("DumbbellModel", nil)
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum and hum.WalkSpeed == 0 then hum.WalkSpeed = 16 end
		end
		plr:SetAttribute("IsTrainingLocal", nil)
	end)
end
local function train()
	if plr:GetAttribute("IsWaveActive") then return end
	local d = pdata()
	local tool = d and d.EquippedTrainTool or "dumbell"
	local char = plr.Character
	if char then
		if char:GetAttribute("DumbbellModel") ~= tool then char:SetAttribute("DumbbellModel", tool) end
		char:SetAttribute("IsTrainingLocal", true)
	end
	plr:SetAttribute("IsTrainingLocal", true)
	if call("TrainingService", "StartTraining") then stats.trains += 1 end
end
local function buyBestTool(cfgTable, ownedKey, equippedKey, service, buyName, equipName, metric)
	if type(cfgTable) ~= "table" then return end
	local d = pdata()
	local cash = d and d.Currencies and tonumber(d.Currencies.Cash)
	if not cash then return end
	local owned, equipped = d[ownedKey] or {}, d[equippedKey]
	local bestBuy, bestBuyVal, bestOwned, bestOwnedVal = nil, -1, nil, -1
	for id, t in pairs(cfgTable) do
		if type(t) == "table" then
			local v = tonumber(t[metric]) or 0
			if owned[id] then
				if v > bestOwnedVal then bestOwned, bestOwnedVal = id, v end
			elseif not t.isSpecial and tonumber(t.cost) and t.cost > 0 and cash >= t.cost and v > bestBuyVal then
				bestBuy, bestBuyVal = id, v
			end
		end
	end
	if bestBuy and bestBuyVal > bestOwnedVal then
		if call(service, buyName, bestBuy) then
			stats.buys += 1
			task.wait(0.15)
			call(service, equipName, bestBuy)
		end
	elseif bestOwned and bestOwned ~= equipped then
		call(service, equipName, bestOwned)
	end
end
-- Ring mode: the game's own training. workspace.TrainingArea (ZonePart +
-- StandPart) sits on the player's plot; walking into ZonePart makes
-- TrainingPlaceholderComponent call TrainingController:StartTraining(
-- StandPart), which pivots the character onto the stand, pins it there
-- (PreSimulation snap-back), sets WalkSpeed 0, invokes the server's
-- StartTraining once and runs the dumbbell animation/gain popups until a
-- jump calls StopTraining. Calling the controller directly with the same
-- StandPart is exactly the zone-enter path minus the walk. Runs alongside
-- the silent loop above by design -- the silent StartTraining invokes are
-- idempotent on the server while a session is already open.
local function ringStand()
	local ta = workspace:FindFirstChild("TrainingArea")
	local sp = ta and ta:FindFirstChild("StandPart")
	if sp and sp:IsA("BasePart") then return sp end
	local plot = myPlot()
	local ph = plot and plot:FindFirstChild("TrainingAreaPlaceholder", true)
	return (ph and ph:IsA("BasePart")) and ph or nil
end
local function ringTrain()
	local tc = trainingController()
	if not (tc and tc.StartTraining) then return end
	if tc.IsTraining and tc:IsTraining() then return end
	if plr:GetAttribute("IsWaveActive") then return end
	local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end
	local stand = ringStand()
	if not stand then return end
	if pcall(function() tc:StartTraining(stand) end) then stats.ringStarts += 1 end
end
local function ringStop()
	local tc = trainingController()
	if tc and tc.IsTraining and tc:IsTraining() then pcall(function() tc:StopTraining(true) end) end
end
task.spawn(function()
	while getgenv().__OS == G do
		pcall(function()
			if e.osTrainRing then ringTrain() end
			if e.osTrain then train() end
			if e.osBuyDumbbell then
				local tc = cfg("TrainToolConfig")
				buyBestTool(tc and tc.TRAIN_TOOLS, "OwnedTrainTools", "EquippedTrainTool",
					"TrainingService", "BuyTrainTool", "EquipTrainTool", "gainPerTrain")
			end
			if e.osBuyStaff then
				buyBestTool(cfg("StaffConfig"), "OwnedPickaxes", "EquippedPickaxe", "PickaxeService", "BuyPickaxe", "EquipPickaxe", "reach")
			end
		end)
		task.wait(2)
	end
end)
-- x2 bonus (the purple hand button that pops up around the screen while
-- you're in the ring): the server announces each one on
-- TrainingService.RE.SpawnBonus(bonusId) -- measured live, three in ~25s
-- of ring time -- and the button's click is just ClaimBonus(bonusId). So
-- the claim is fired straight from the event, no screen position to
-- chase, and it belongs to Ring mode: on whenever the ring toggle is.
task.spawn(function()
	local sig = nil
	for _ = 1, 120 do
		sig = signal("TrainingService", "SpawnBonus")
		if sig then break end
		task.wait(0.5)
	end
	if not sig then return end
	local last = nil
	sig.OnClientEvent:Connect(function(bonusId)
		if getgenv().__OS ~= G or not e.osTrainRing or not bonusId or bonusId == last then return end
		last = bonusId
		task.wait(0.05)
		local ok, res = call("TrainingService", "ClaimBonus", bonusId)
		if ok and res ~= false then stats.bonuses += 1 end
	end)
end)

-- ---------------------------------------------------------------- upgrades / rebirth
task.spawn(function()
	while getgenv().__OS == G do
		pcall(function()
			local d = pdata()
			local cash = d and d.Currencies and tonumber(d.Currencies.Cash)
			if not cash then return end
			local up = d.Upgrades or {}
			local UpgradeConfig = cfg("UpgradeConfig")
			local RebirthConfig = cfg("RebirthConfig")
			if UpgradeConfig then
				if e.osUpPlot then
					local price = UpgradeConfig.GetPrice("PlotUpgrade", (up.PlotUpgrade or 0) + 1)
					if price and cash >= price and call("UpgradesService", "Upgrade", "PlotUpgrade", 1) then stats.upgrades += 1 task.wait(0.15) end
				end
				if e.osUpCarry then
					local price = UpgradeConfig.GetPrice("Carry", (up.Carry or 0) + 1)
					if price and cash >= price and call("UpgradesService", "Upgrade", "Carry", 1) then stats.upgrades += 1 task.wait(0.15) end
				end
				if e.osUpSpeed then
					local n = UpgradeConfig.GetMaxBuyable("MovementSpeed", up.MovementSpeed or 0, cash)
					if n and n > 0 and call("UpgradesService", "Upgrade", "MovementSpeed", math.min(n, 10)) then stats.upgrades += 1 task.wait(0.15) end
				end
			end
			if e.osRebirth and RebirthConfig and RebirthConfig.REBIRTH then
				local cur = tonumber(d.Rebirth) or 0
				local target = tonumber(e.osRebirthTarget) or 0
				if target > 0 and cur >= target then return end
				local nxt = RebirthConfig.REBIRTH[cur + 1]
				if nxt and nxt.Cost and nxt.Cost.Cash and cash >= nxt.Cost.Cash then
					if call("RebirthService", "Rebirth") then stats.rebirths += 1 end
				end
			end
		end)
		task.wait(2)
	end
end)

-- ---------------------------------------------------------------- rewards / potions
task.spawn(function()
	local lastDaily, lastPlaytime = 0, 0
	while getgenv().__OS == G do
		pcall(function()
			local d = pdata()
			if not d then return end
			local FreeShopConfig = cfg("FreeShopConfig")
			local SeasonPassConfig = cfg("SeasonPassConfig")
			if e.osFreeShop and FreeShopConfig then
				if (tonumber(d.LastFreeShopClaim) or 0) < (tonumber(FreeShopConfig.CURRENT_CLAIM_INDEX) or 1) then
					if call("FreeShopService", "Claim") then stats.claims += 1 end
				end
			end
			if e.osSpin and d.Currencies and (tonumber(d.Currencies.LuminousCoins) or 0) >= 25 then
				if call("SpinWheelService", "SpinAll") then stats.claims += 1 end
			end
			if e.osPlaytime and os.clock() - lastPlaytime >= 10 then
				lastPlaytime = os.clock()
				pcall(function()
					local c = Knit.GetController("PlaytimeRewardController")
					if c and c.GetAvailableGiftsCount and c:GetAvailableGiftsCount() > 0 then
						local g = c:GetNextClaimableGift()
						if g then c:ClaimGift(g) stats.claims += 1 end
					end
				end)
			end
			if e.osDaily and os.clock() - lastDaily >= 60 then
				lastDaily = os.clock()
				local daily = d.DailyReward
				if type(daily) == "table" and daily.LastClaimedDate then
					if workspace:GetServerTimeNow() - daily.LastClaimedDate >= 86400 then
						local nextDay = (tonumber(daily.LastClaimedDay) or 0) + 1
						if nextDay <= 7 and call("DailyRewardService", "ClaimReward", nextDay) then stats.claims += 1 end
					end
				end
				-- VIP reward only when the pass is actually owned -- otherwise
				-- the server answers with a Robux prompt
				local gp = d.Gamepasses
				if type(gp) == "table" and (gp.VIP or gp.vip) then call("DailyRewardService", "ClaimVIPReward") end
			end
			if e.osGroup and not d.RedeemedGroupReward then
				if call("RewardService", "GroupReward") then stats.claims += 1 end
			end
			if e.osSeasonPass and SeasonPassConfig and type(SeasonPassConfig.Level) == "table" and type(d.SeasonPass) == "table" then
				local exp = tonumber(d.SeasonPass.Exp) or 0
				local lvl = 0
				for i, req in ipairs(SeasonPassConfig.Level) do if exp >= req then lvl = i end end
				local free = d.SeasonPass.Free or {}
				for tier = 1, lvl do
					if not free[tostring(tier)] then
						if call("SeasonPassService", "ClaimPassReward", "Free", tier) then stats.claims += 1 end
					end
				end
			end
			if e.osQuests and type(d.Quests) == "table" then
				for qType, list in pairs(d.Quests) do
					if type(list) == "table" then
						for _, q in pairs(list) do
							if type(q) == "table" and q.id and q.isCompleted and not q.isClaimed then
								if call("QuestService", "ClaimReward", qType, q.id) then stats.claims += 1 end
							end
						end
					end
				end
			end
			if e.osPotions and type(d.PotionInventory) == "table" then
				local active = d.ActivePotions or {}
				for _, p in ipairs({{"osPotionTrain", "Train"}, {"osPotionCash", "Cash"}, {"osPotionLuck", "Luck"}}) do
					if e[p[1]] and (tonumber(d.PotionInventory[p[2]]) or 0) > 0 and not active[p[2]] then
						call("PotionService", "UsePotion", p[2])
					end
				end
			end
		end)
		task.wait(2)
	end
end)

-- ---------------------------------------------------------------- speed / anti-afk / reconnect
task.spawn(function()
	while getgenv().__OS == G do
		if e.osSpeedEnabled then
			pcall(function()
				local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
				local v = math.clamp(tonumber(e.osSpeedValue) or 46, 16, 200)
				if hum and hum.WalkSpeed ~= v and hum.WalkSpeed ~= 0 then hum.WalkSpeed = v end
			end)
		end
		task.wait(0.5)
	end
end)
plr.Idled:Connect(function()
	if getgenv().__OS == G and e.osAntiAFK then
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end
end)
-- Three layers, because three different things can decide you're AFK:
--   1. Roblox's own 20-minute idle kick -- answered by plr.Idled above
--      (VirtualUser click), the standard fix.
--   2. Anything client-side that watches input -- a real F15 key event
--      (unbound in Roblox and in this game) plus a one-pixel mouse nudge
--      every 30s.
--   3. The SERVER, which sees none of that. It only sees what replicates:
--      the character's position. Read out of Chekkadeiz's Roblox log:
--      the game teleported the account to a fresh server at 19:04 and
--      again at 19:44 (~40 min apart) with no kick/disconnect line before
--      either -- a server-side idle sweep. The character had not moved a
--      stud in that time (wave sniping is remote-only, the ring pins it,
--      and no client script in this place tracks idle at all -- searched).
--      So every 5 minutes the character takes a real step: out of the
--      ring if it's in one (the ring loop puts it straight back), a few
--      studs and back otherwise, plus a jump. That is what a human at the
--      keyboard looks like to a server.
local VIM = game:GetService("VirtualInputManager")
local function inputNudge()
	VIM:SendKeyEvent(true, Enum.KeyCode.F15, false, game)
	task.wait(0.05)
	VIM:SendKeyEvent(false, Enum.KeyCode.F15, false, game)
	local cam = workspace.CurrentCamera
	if cam then
		VirtualUser:CaptureController()
		VirtualUser:MoveMouse(Vector2.new(cam.ViewportSize.X / 2 + 1, cam.ViewportSize.Y / 2))
		task.wait(0.1)
		VirtualUser:MoveMouse(Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2))
	end
end
local function afkStep()
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and hrp) or hum.Health <= 0 then return false end
	if plr:GetAttribute("IsWaveActive") then return false end   -- mid-wave: don't yank the character
	local tc = trainingController()
	local wasInRing = tc and tc.IsTraining and tc:IsTraining()
	if wasInRing then
		pcall(function() tc:StopTraining(true) end)   -- StopTraining itself shoves the character 12 studs out
		task.wait(0.4)
	end
	if hum.WalkSpeed <= 0 then hum.WalkSpeed = 16 end
	local start = hrp.Position
	local dir = hrp.CFrame.LookVector
	hum:MoveTo(start + dir * 4)
	task.wait(1.2)
	hum.Jump = true
	task.wait(0.8)
	hum:MoveTo(start)
	task.wait(1.2)
	stats.note = ("afk step %s"):format(os.date("%H:%M"))
	-- ring mode re-enters on its own next tick (IsTraining false now)
	return true
end
e.__osAfkStep = afkStep   -- exposed for live probes only
task.spawn(function()
	local lastStep = os.clock()
	while getgenv().__OS == G do
		task.wait(30)
		if e.osAntiAFK then
			pcall(inputNudge)
			if os.clock() - lastStep >= 300 then
				lastStep = os.clock()
				pcall(afkStep)
			end
		end
	end
end)
if not getgenv().__OSReconnectHooked then
	getgenv().__OSReconnectHooked = true
	Players.PlayerRemoving:Connect(function(p)
		if p == plr and e.osAutoReconnect then
			pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
		end
	end)
end

-- ---------------------------------------------------------------------- UI
print("[OpenSea] Loading MacLib...")
local okLib, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okLib or not Lib then print("[OpenSea] MacLib failed: " .. tostring(Lib)) return end
task.wait()
if getgenv().__OS ~= G or e.__osTok ~= myUID then print("[OpenSea] Aborted (superseded)") return end

local W = Lib:Window({Title = "Open Sea For Animals", Subtitle = "wave / hatchery / power / rewards automation",
                       DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__OSW = W
local TG = W:TabGroup()
local Tabs = {
	Sea = TG:Tab({Name = "Sea", Image = "rbxassetid://10723343321"}),
	Power = TG:Tab({Name = "Power", Image = "rbxassetid://10734963191"}),
	Rewards = TG:Tab({Name = "Rewards", Image = "rbxassetid://10723396402"}),
	Misc = TG:Tab({Name = "Misc", Image = "rbxassetid://10734898355"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}
local function notify(title, desc) pcall(function() W:Notify({Title = title, Description = desc}) end) end
local function indexOf(list, v) return table.find(list, v) or 1 end

-- ----- Sea -----
local SL = Tabs.Sea:Section({Side = "Left"})
SL:Header({Text = "Sea Wave"})
SL:Toggle({Name = "Auto Sea Wave", Default = e.osWave, Callback = function(v) e.osWave = v; sv() end}, "osWave")
SL:Toggle({Name = "Hunt Event Boss (Devil / Zeus)", Default = e.osHuntBoss, Callback = function(v) e.osHuntBoss = v; sv() end}, "osHuntBoss")
SL:Dropdown({
	Name = "Min Egg Rarity", Multi = false, Required = true, Search = true,
	Options = MIN_RARITY_OPTIONS, Default = math.clamp(tonumber(e.osMinRarity) or 1, 1, #MIN_RARITY_OPTIONS),
	Callback = function(v)
		local picked = type(v) == "table" and v[1] or v
		local idx = table.find(MIN_RARITY_OPTIONS, picked)
		if idx then e.osMinRarity = idx; sv() end
	end,
}, "osMinRarity")
SL:Dropdown({
	Name = "Target Specific Egg", Multi = false, Required = true, Search = true,
	Options = EGG_NAME_OPTIONS, Default = indexOf(EGG_NAME_OPTIONS, e.osSpecificEgg),
	Callback = function(v)
		local picked = type(v) == "table" and v[1] or v
		if type(picked) == "string" then e.osSpecificEgg = picked; sv() end
	end,
}, "osSpecificEgg")
SL:Toggle({Name = "Prioritize Mutations", Default = e.osMutations, Callback = function(v) e.osMutations = v; sv() end}, "osMutations")
SL:Slider({
	Name = "Wave Delay", Default = e.osWaveDelay, Minimum = 1, Maximum = 10, DisplayMethod = "Number", Precision = 0,
	Callback = function(v) e.osWaveDelay = v; sv() end,
}, "osWaveDelay")
SL:Header({Text = "Sell Eggs"})
local function multiPick(v, options, idByLabel)
	-- MacLib hands a {label=true} set for multi-select; store the ids as an
	-- ordered array (label -> id through the map built from the config)
	local picked = {}
	if type(v) == "table" then
		for _, label in ipairs(options) do if v[label] == true then picked[#picked + 1] = idByLabel[label] or label end end
		for _, label in ipairs(v) do
			if type(label) == "string" then
				local id = idByLabel[label] or label
				if not table.find(picked, id) then picked[#picked + 1] = id end
			end
		end
	end
	return picked
end
SL:Dropdown({
	Name = "Sell Rarities", Multi = true, Required = false, Search = true,
	Options = SELL_OPTIONS, Default = e.osSellRarities,
	Callback = function(v) e.osSellRarities = multiPick(v, SELL_OPTIONS, {}); sv() end,
}, "osSellRarities")
SL:Dropdown({
	Name = "Sell Mutations", Multi = true, Required = false,
	Options = MUTATION_OPTIONS, Default = idsToLabels(e.osSellMutations, MUTATION_LABEL_BY_ID),
	Callback = function(v) e.osSellMutations = multiPick(v, MUTATION_OPTIONS, MUTATION_ID_BY_LABEL); sv() end,
}, "osSellMutations")
SL:Dropdown({
	Name = "Sell Sizes", Multi = true, Required = false,
	Options = SIZE_OPTIONS, Default = idsToLabels(e.osSellSizes, SIZE_LABEL_BY_ID),
	Callback = function(v) e.osSellSizes = multiPick(v, SIZE_OPTIONS, SIZE_ID_BY_LABEL); sv() end,
}, "osSellSizes")
SL:Label({Text = "(xN) = the game's cash multiplier for that mutation / size.\nAn egg sells only when its rarity is picked AND mutation AND size\nmatch. Empty rarity pick sells nothing; empty mutation/size pick =\nno filter on that. Default keeps every mutated egg (only Normal sold)."})
SL:Toggle({Name = "Auto Sell Eggs (by picks)", Default = e.osSellEggs, Callback = function(v) e.osSellEggs = v; sv() end}, "osSellEggs")
SL:Button({Name = "Sell Picked Eggs Now", Callback = function()
	task.spawn(function() local n = sellEggs() notify("Sold", ("%d eggs (%s)"):format(n, table.concat(e.osSellRarities or {}, ", "))) end)
end})
SL:Header({Text = "Hatchery & Plot"})
SL:Toggle({Name = "Auto Hatch Eggs (place + hatch)", Default = e.osHatch, Callback = function(v) e.osHatch = v; sv() end}, "osHatch")
SL:Toggle({Name = "Auto Equip Best", Default = e.osEquipBest, Callback = function(v) e.osEquipBest = v; sv() end}, "osEquipBest")
SL:Toggle({Name = "Auto Sell Unused Animals", Default = e.osSellAnimals, Callback = function(v) e.osSellAnimals = v; sv() end}, "osSellAnimals")
SL:Button({Name = "Sell Unused Animals Now", Callback = function()
	task.spawn(function() sellUnusedAnimals() notify("Done", "Equipped best, sold the rest") end)
end})
SL:Toggle({Name = "Auto Collect Offline Cash", Default = e.osOfflineCash, Callback = function(v) e.osOfflineCash = v; sv() end}, "osOfflineCash")

local SR = Tabs.Sea:Section({Side = "Right"})
SR:Header({Text = "Status"})
local seaStatusLbl = SR:Label({Text = "Starting..."})

-- ----- Power -----
local PL = Tabs.Power:Section({Side = "Left"})
PL:Header({Text = "Training"})
PL:Toggle({Name = "Auto Train Power (silent)", Default = e.osTrain, Callback = function(v) e.osTrain = v; sv(); if not v and not e.osTrainRing then task.spawn(stopTraining) end end}, "osTrain")
PL:Toggle({Name = "Auto Train in Ring + Auto x2 Bonus", Default = e.osTrainRing, Callback = function(v) e.osTrainRing = v; sv(); if not v then task.spawn(ringStop) end end}, "osTrainRing")
PL:Label({Text = "Silent = fires the server's StartTraining in the background,\nwalk anywhere. Ring = the game's own dumbbell stand on your\nplot (locks you there) and every x2 hand button that pops up\nis claimed the instant the server spawns it. Both can run at once."})
PL:Button({Name = "Stop Training Now", Callback = function() task.spawn(function() ringStop() stopTraining() end) end})
PL:Header({Text = "Gear"})
PL:Toggle({Name = "Auto Buy & Equip Best Dumbbell", Default = e.osBuyDumbbell, Callback = function(v) e.osBuyDumbbell = v; sv() end}, "osBuyDumbbell")
PL:Toggle({Name = "Auto Buy & Equip Best Staff", Default = e.osBuyStaff, Callback = function(v) e.osBuyStaff = v; sv() end}, "osBuyStaff")
PL:Header({Text = "Upgrades"})
PL:Toggle({Name = "Auto Upgrade Plot", Default = e.osUpPlot, Callback = function(v) e.osUpPlot = v; sv() end}, "osUpPlot")
PL:Toggle({Name = "Auto Upgrade Speed", Default = e.osUpSpeed, Callback = function(v) e.osUpSpeed = v; sv() end}, "osUpSpeed")
PL:Toggle({Name = "Auto Upgrade Carry", Default = e.osUpCarry, Callback = function(v) e.osUpCarry = v; sv() end}, "osUpCarry")
PL:Header({Text = "Rebirth"})
PL:Toggle({Name = "Auto Rebirth", Default = e.osRebirth, Callback = function(v) e.osRebirth = v; sv() end}, "osRebirth")
local REBIRTH_OPTIONS = {"Unlimited"}
local rc = cfg("RebirthConfig")
local rebirthMax = (rc and rc.REBIRTH and #rc.REBIRTH) or 10
for i = 1, math.max(rebirthMax, 10) do REBIRTH_OPTIONS[#REBIRTH_OPTIONS + 1] = ("Stop at Rebirth %d"):format(i) end
PL:Dropdown({
	Name = "Rebirth Target", Multi = false, Required = true, Search = true,
	Options = REBIRTH_OPTIONS, Default = math.clamp((tonumber(e.osRebirthTarget) or 0) + 1, 1, #REBIRTH_OPTIONS),
	Callback = function(v)
		local picked = type(v) == "table" and v[1] or v
		local idx = table.find(REBIRTH_OPTIONS, picked)
		if idx then e.osRebirthTarget = idx - 1; sv() end
	end,
}, "osRebirthTarget")
PL:Button({Name = "Rebirth Now", Callback = function()
	task.spawn(function()
		local ok, res = call("RebirthService", "Rebirth")
		notify(ok and res ~= false and "Rebirthed" or "Rebirth refused", ok and res ~= false and "Done" or "Not enough cash / not eligible")
	end)
end})
local PR = Tabs.Power:Section({Side = "Right"})
PR:Header({Text = "Status"})
local powerStatusLbl = PR:Label({Text = "Starting..."})

-- ----- Rewards -----
local RL = Tabs.Rewards:Section({Side = "Left"})
RL:Header({Text = "Freebies"})
RL:Toggle({Name = "Auto Playtime Gifts", Default = e.osPlaytime, Callback = function(v) e.osPlaytime = v; sv() end}, "osPlaytime")
RL:Toggle({Name = "Auto Daily Reward", Default = e.osDaily, Callback = function(v) e.osDaily = v; sv() end}, "osDaily")
RL:Toggle({Name = "Auto Free Shop", Default = e.osFreeShop, Callback = function(v) e.osFreeShop = v; sv() end}, "osFreeShop")
RL:Toggle({Name = "Auto Spin Wheel (25 Luminous)", Default = e.osSpin, Callback = function(v) e.osSpin = v; sv() end}, "osSpin")
RL:Toggle({Name = "Auto Group Reward", Default = e.osGroup, Callback = function(v) e.osGroup = v; sv() end}, "osGroup")
RL:Toggle({Name = "Auto Season Pass (free tier)", Default = e.osSeasonPass, Callback = function(v) e.osSeasonPass = v; sv() end}, "osSeasonPass")
RL:Toggle({Name = "Auto Claim Quests", Default = e.osQuests, Callback = function(v) e.osQuests = v; sv() end}, "osQuests")
RL:Header({Text = "Potions"})
RL:Toggle({Name = "Auto Use Potions", Default = e.osPotions, Callback = function(v) e.osPotions = v; sv() end}, "osPotions")
RL:Toggle({Name = "  Train Potion (x2 power)", Default = e.osPotionTrain, Callback = function(v) e.osPotionTrain = v; sv() end}, "osPotionTrain")
RL:Toggle({Name = "  Cash Potion (x2 cash)", Default = e.osPotionCash, Callback = function(v) e.osPotionCash = v; sv() end}, "osPotionCash")
RL:Toggle({Name = "  Luck Potion (x2 luck)", Default = e.osPotionLuck, Callback = function(v) e.osPotionLuck = v; sv() end}, "osPotionLuck")
RL:Header({Text = "Codes"})
RL:Button({Name = "Redeem Known Codes", Callback = function()
	task.spawn(function()
		local n = 0
		for _, c in ipairs({"RELEASE", "OPENSEA", "SEA", "ANIMALS", "UPDATE1", "UPDATE2", "TRAIN", "POWER", "100K", "50K", "10K", "LIKE", "DISCORD"}) do
			local ok, res = call("CodesService", "RedeemCode", c)
			if ok and res == true then n += 1 end
			task.wait(0.2)
		end
		notify("Codes", ("%d new code(s) redeemed"):format(n))
	end)
end})
RL:Input({
	Name = "Custom Code", Placeholder = "type a code, press Enter",
	Callback = function(text)
		if type(text) ~= "string" or text == "" then return end
		task.spawn(function()
			local ok, res = call("CodesService", "RedeemCode", text)
			notify(ok and res == true and "Redeemed" or "Code refused", text)
		end)
	end,
}, "osCustomCode")

-- ----- Misc -----
local ML = Tabs.Misc:Section({Side = "Left"})
ML:Header({Text = "Teleports"})
ML:Button({Name = "My Plot", Callback = function()
	local plot = myPlot()
	local warp = plot and (plot:FindFirstChild(plot.Name .. "_WarpPart") or plot:FindFirstChild("PlotSurface", true))
	teleport(warp and (warp.CFrame * CFrame.new(0, 3, 0)) or CFrame.new(733.8, 80, 398.2))
end})
ML:Button({Name = "Sea Edge", Callback = function() teleport(CFrame.new(661.8, 77, 325.2)) end})
ML:Button({Name = "Dumbbell Shop", Callback = function() teleport(CFrame.new(667.6, 73, 281.8)) end})
ML:Button({Name = "Staff Shop", Callback = function() teleport(CFrame.new(664.1, 72, 363.2)) end})
ML:Header({Text = "Character"})
ML:Button({Name = "Unstuck / Unlock Walk", Callback = function()
	task.spawn(function()
		stopTraining()
		pcall(function()
			local char = plr.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum then hum.PlatformStand = false hum.WalkSpeed = e.osSpeedEnabled and e.osSpeedValue or 16 hum.JumpPower = 50 end
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				for _, c in ipairs(hrp:GetChildren()) do
					if c:IsA("BodyVelocity") or c:IsA("BodyPosition") or c:IsA("BodyGyro") then c:Destroy() end
				end
			end
		end)
		notify("Unstuck", "Movement restored")
	end)
end})
ML:Toggle({Name = "Custom Walk Speed", Default = e.osSpeedEnabled, Callback = function(v) e.osSpeedEnabled = v; sv() end}, "osSpeedEnabled")
ML:Slider({
	Name = "Walk Speed", Default = e.osSpeedValue, Minimum = 16, Maximum = 200, DisplayMethod = "Number", Precision = 0,
	Callback = function(v) e.osSpeedValue = v; sv() end,
}, "osSpeedValue")

-- ----- Settings -----
local STL = Tabs.Settings:Section({Side = "Left"})
STL:Header({Text = "General"})
STL:Toggle({Name = "Anti-AFK", Default = e.osAntiAFK, Callback = function(v) e.osAntiAFK = v; sv() end}, "osAntiAFK")
STL:Toggle({Name = "Auto Reconnect", Default = e.osAutoReconnect, Callback = function(v) e.osAutoReconnect = v; sv() end}, "osAutoReconnect")
STL:Keybind({
	Name = "Show/Hide UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() W:SetState(not W:GetState()) end) end,
}, "OpenSeaToggleUIKeybind")
STL:Header({Text = "Auto Save"})
STL:Label({Text = "All toggles save automatically to:\n" .. SF})

local function fmt(n)
	n = tonumber(n) or 0
	if n >= 1e15 then return ("%.2fQa"):format(n / 1e15) end
	if n >= 1e12 then return ("%.2fT"):format(n / 1e12) end
	if n >= 1e9 then return ("%.2fB"):format(n / 1e9) end
	if n >= 1e6 then return ("%.2fM"):format(n / 1e6) end
	if n >= 1e3 then return ("%.1fK"):format(n / 1e3) end
	return ("%d"):format(n)
end
task.spawn(function()
	while getgenv().__OS == G do
		task.wait(1)
		pcall(function()
			local d = pdata()
			local cash = d and d.Currencies and d.Currencies.Cash or 0
			local ae = RS:FindFirstChild("ActiveEvents")
			local ev = {}
			if ae then for _, c in ipairs(ae:GetChildren()) do ev[#ev + 1] = c.Name end end
			seaStatusLbl:UpdateName(("Cash: $%s\nWaves: %d | Eggs taken: %d (last: %s)\nEggs sold: %d | Placed: %d | Hatched: %d\nEvent: %s\n%s"):format(
				fmt(cash), stats.waves, stats.eggsTaken, stats.lastEgg, stats.eggsSold, stats.placed, stats.hatched,
				#ev > 0 and table.concat(ev, ", ") or "none", stats.note))
		end)
		pcall(function()
			local d = pdata()
			local tc = trainingController()
			local ring = (tc and tc.IsTraining and tc:IsTraining()) and "in ring" or "idle"
			powerStatusLbl:UpdateName(("Power: %s | Rebirth: %s\nSilent train calls: %d | Ring: %s (%d starts)\nx2 bonuses: %d | Gear bought: %d\nUpgrades: %d | Rebirths: %d | Rewards claimed: %d"):format(
				fmt(d and d.Power), tostring(d and d.Rebirth or "?"), stats.trains, ring, stats.ringStarts, stats.bonuses, stats.buys, stats.upgrades, stats.rebirths, stats.claims))
		end)
	end
end)

W.onUnloaded(function() print("[OpenSea] Unloaded") end)
Tabs.Sea:Select()
print("[OpenSea] UI ready")
