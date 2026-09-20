-- Tapborne Heroes [Kokoyume, placeId 80519520593681] -- multi-feature automation + UI
--
-- Verified live against the actual game (2026-09-20), account Papiyongzzz:
--   - This game does NOT use Knit's normal per-service RemoteEvent/RemoteFunction
--     folders (confirmed: zero such instances exist anywhere in the game tree,
--     even after Knit itself finished starting). All client<->server traffic
--     goes through ONE generic RPC channel instead:
--       * ReplicatedStorage.MsgListener (RemoteFunction) -- client -> server,
--         call as MsgListener:InvokeServer(msgId, arg). msgId is an opaque
--         number; the actual mapping (282 of them) lives in a genuinely plain,
--         unobfuscated require()'d table: ReplicatedStorage.Msg (keys like
--         "C2S_TapClickMonster" / "S2C_DungeonResult").
--       * ReplicatedStorage.ServerNotice (RemoteEvent) -- server -> client,
--         fires with ONE table argument shaped {[1] = {msgID = <id>,
--         msgData = {<payload>, ...}}}. This is the confirmed shape from
--         HttpService:JSONEncode on live captures, not a guess.
--     (ReplicatedStorage.ClientNotice exists too but never fired during
--     testing -- likely client -> server chat/social only.)
--   - Client scripts are fully obfuscated (script-grep/semantic-search both
--     return 0 matches on this client, same as Ride A Pet and Loot Wars
--     before it) -- everything below came from requiring the plain data
--     modules directly (Msg, Configs.Hero, Configs.Dungeon, Configs.Achievement,
--     GameSettings) and from live request/response capture on ServerNotice,
--     not from reading any script source.
--   - GameSettings.AutoTapBundleID exists -- SetAutoTapEnabled(true) was tried
--     live and the server pushed back S2C_UpdateAutoTapState=false regardless
--     of the argument, both directions, twice. Reads as a paid-bundle-gated
--     toggle this account doesn't own, not a bug. Auto Tap here instead just
--     fires C2S_TapClickMonster on a loop -- confirmed live: the resulting
--     S2C_TapDamageFeedback carries Source="Click", proving each call lands
--     as a normal manual tap, same action a real player performs, just timed
--     by the script instead of a finger.
--   - Recruiting: GameSettings.HERO_QUALITY_MAX = 7, and Configs.Hero's
--     per-hero array carries quality at index 7 (== index 8, duplicated).
--     GameSettings.EquipmentQuality.Configs names tiers 1-6 as Common /
--     Uncommon / Rare / Epic / Legendary / Mythic -- tier 7 has no equipment
--     config entry (some heroes do reach quality 7 live, e.g. hero 10020) so
--     it's labelled "Mythic+" here rather than guessing a real name for it.
--     TavernHireOffer takes the offer's OfferId (string, e.g. "67"), confirmed
--     via TavernRequestData -> Offers{slot -> {OfferId, HeroId, State,
--     RecruitCost, ...}}. First guess here was C2S_TapRecruitHeroInstance
--     (name sounded right) -- shipped, then confirmed live it was wrong: fired
--     with a real offerId + plenty of gold, no error, no result message, and
--     the offer just sat "Available" forever. TavernHireOffer is the real
--     tavern-buy action -- same call, offer flipped straight to "Hired".
--     A hire call on an unaffordable offer still silently no-ops (confirmed
--     separately: RecruitCost 629000 > Gold 276789 produced no error either) --
--     both failure modes look identical from here, which is why nothing in
--     this script trusts the call succeeding; it just re-reads tavern state.
--   - Dungeon: RequestDungeonData -> Dungeons{id -> {Run={Status="NotEntered"
--     | ..., WindowStart, CurrentWave, ...}, ClearCount}}. ChallengeDungeon(id)
--     confirmed live -- a closed dungeon answers {DungeonId, Result=
--     "EntryClosed"} on S2C_DungeonResult, not an error, so this just tries
--     the lowest NotEntered dungeon id each pass and reads Result back.
--   - Achievement: claiming with a guessed id answered {false, id,
--     "NotCurrentAchievement"} -- confirms achievements gate on a single
--     "current" one (sequential track), but this session never found the
--     call that reveals which id that is (S2C_TapAchievementData never
--     arrived during testing, and Configs.Achievement carries no "current"
--     marker). Best-effort here: tries every known achievement id from
--     Configs.Achievement at low frequency. Every wrong guess is a harmless
--     rejected InvokeServer call, same as the recruit/dungeon "soft no" cases
--     above -- nothing here can double-claim or lose progress.

getgenv().__TH = (getgenv().__TH or 0) + 1
local G = getgenv().__TH
pcall(function() if getgenv().__THW then getgenv().__THW:Unload() end end)
local e = getgenv()
local myUID = tostring(math.random(1, 2 ^ 30))
e.__thTok = myUID
print("[TapborneHeroes] Starting (gen " .. G .. ")...")

local TAPBORNE = 80519520593681
if game.PlaceId ~= TAPBORNE then print("[TapborneHeroes] Wrong place, aborting") return end

local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local plr = Players.LocalPlayer

local Msg = require(RS:WaitForChild("Msg"))
local ml = RS:WaitForChild("MsgListener", 10)
local sn = RS:WaitForChild("ServerNotice", 10)
if not (ml and sn) then print("[TapborneHeroes] Core remotes not found, aborting") return end

local ok1, HeroCfg = pcall(function() return require(RS.Configs.Hero) end)
local ok2, AchCfg = pcall(function() return require(RS.Configs.Achievement) end)
if not ok1 then HeroCfg = {} end
if not ok2 then AchCfg = {} end

-- ---------------------------------------------------------------- S2C router
-- Every server push lands here keyed by msgID -> most recent payload. Cheap,
-- generic, and matches the "one channel, many message types" shape of this
-- game's whole protocol instead of hand-wiring a listener per feature.
local latest = {}
sn.OnClientEvent:Connect(function(payload)
	local m = payload and payload[1]
	if m and m.msgID then
		latest[m.msgID] = m.msgData
	end
end)

local function req(id, arg)
	return pcall(function() return ml:InvokeServer(id, arg) end)
end

local QUALITY_NAMES = {[1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic",
                        [5] = "Legendary", [6] = "Mythic", [7] = "Mythic+"}
local function heroQuality(heroId)
	local rec = HeroCfg[heroId]
	return (typeof(rec) == "table") and rec[7] or nil
end

-- ---------------------------------------------------------------- state/config
local SF = "TapborneHeroes/state.json"
local SK = {"thTapEnabled", "thRecruitEnabled", "thRecruitQualities", "thDungeonEnabled",
            "thDungeonSelected", "thDailyEnabled", "thAchievementEnabled", "thAntiAFK",
            "thUpgradeEnabled", "thUpgradeCategories", "thMigratedV2", "thAutoReconnect"}

local ok3, DungeonCfg = pcall(function() return require(RS.Configs.Dungeon) end)
if not ok3 then DungeonCfg = {} end
local DUNGEON_NAMES, DUNGEON_NAME_TO_ID = {}, {}
do
	local ids = {}
	for id, rec in pairs(DungeonCfg) do
		if typeof(rec) == "table" and typeof(rec[2]) == "string" then table.insert(ids, id) end
	end
	table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
	for _, id in ipairs(ids) do
		local name = DungeonCfg[id][2]
		table.insert(DUNGEON_NAMES, name)
		DUNGEON_NAME_TO_ID[name] = id
	end
end
pcall(function() if not isfolder("TapborneHeroes") then makefolder("TapborneHeroes") end end)
local function sv()
	local d = {}
	for _, k in ipairs(SK) do d[k] = e[k] end
	pcall(function() writefile(SF, HS:JSONEncode(d)) end)
end
pcall(function()
	local c = readfile(SF)
	local d = HS:JSONDecode(c)
	for _, k in ipairs(SK) do if d[k] ~= nil and e[k] == nil then e[k] = d[k] end end
end)
if e.thTapEnabled == nil then e.thTapEnabled = true end
if e.thRecruitEnabled == nil then e.thRecruitEnabled = true end
if type(e.thRecruitQualities) ~= "table" then e.thRecruitQualities = {} end
if e.thDungeonEnabled == nil then e.thDungeonEnabled = true end
if type(e.thDungeonSelected) ~= "table" then e.thDungeonSelected = {} end
if e.thDailyEnabled == nil then e.thDailyEnabled = true end
if e.thAchievementEnabled == nil then e.thAchievementEnabled = true end
if e.thAntiAFK == nil then e.thAntiAFK = true end
if e.thAutoReconnect == nil then e.thAutoReconnect = true end
if e.thUpgradeEnabled == nil then e.thUpgradeEnabled = true end
local UPGRADE_CATS = {"Player Level", "Heroes", "Skills"}
if type(e.thUpgradeCategories) ~= "table" then e.thUpgradeCategories = {} end

-- ONE-TIME migration, not a permanent backfill -- an earlier version fed
-- MacLib's Dropdown a {name=true} set as Default when it wants an array
-- (MacLib source, ~line 2859: `table.find(Settings.Default, v)` -- an array
-- search, so a dict Default silently matched almost nothing) and that left
-- state.json with only whatever handful of keys happened to survive. First
-- fix attempt force-added every missing key back as true on EVERY load --
-- which "fixed" the corruption but also meant unchecking anything in the UI
-- never stuck: next load, this same code saw the key "missing" again and
-- re-added it. That's the exact bug just reported ("config keeps resetting,
-- not what I set"). Real fix: backfill missing keys only once, gated by
-- thMigratedV2, and persist that flag immediately -- every load after this
-- one trusts whatever the user actually has selected, missing key or not.
if not e.thMigratedV2 then
	for _, name in ipairs({"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Mythic+"}) do
		if e.thRecruitQualities[name] == nil then e.thRecruitQualities[name] = true end
	end
	for _, name in ipairs(DUNGEON_NAMES) do
		if e.thDungeonSelected[name] == nil then e.thDungeonSelected[name] = true end
	end
	for _, name in ipairs(UPGRADE_CATS) do
		if e.thUpgradeCategories[name] == nil then e.thUpgradeCategories[name] = true end
	end
	e.thMigratedV2 = true
	sv()   -- persist the one-time repair now, not on the next dropdown click
end

local stats = {taps = 0, recruits = 0, dungeon = "-", daily = "-", achievements = 0, upgrades = 0}

-- MacLib's multi-Dropdown Default wants an ARRAY of selected option names
-- (its own demo: Default = {"Apple", "Orange"}), not a {name=true} set. Fed
-- it the set directly for Recruit Rarity/Which Dungeons the first time --
-- confirmed live afterward that thRecruitQualities had silently lost 2 of 7
-- keys (Common, Uncommon) with no error anywhere, which is exactly why Auto
-- Recruit looked "on" but never bought the two cheapest-tier heroes actually
-- on offer. The farm loops still want the set shape (O(1) membership check),
-- so keep storing that in e.* and only convert to an array right here, at
-- the one spot MacLib actually reads it.
local function setToArray(set)
	local arr = {}
	for k, v in pairs(set) do if v then table.insert(arr, k) end end
	return arr
end

-- ---------------------------------------------------------------- Auto Tap
-- "As fast as possible" measured two ways live, not guessed:
--   - 20 calls fired one at a time, each waiting for its own InvokeServer to
--     return: ~2.38s total (~119ms/call), essentially all landed as real
--     Source="Click" damage. InvokeServer's own network round-trip is already
--     the pacing here -- nothing to gain by adding an extra task.wait on top,
--     which is what the previous 0.25s sleep was doing (paying ~130ms of
--     idle time per tap for nothing).
--   - 40 calls fired concurrently (task.spawn per call, not waiting for
--     replies) landed only ~6 real hits -- the server throttles/drops a
--     burst. Firing faster than the round-trip by going concurrent doesn't
--     get more taps in, it just gets most of them silently rejected.
-- So: sequential, no added sleep, let each InvokeServer's own round-trip set
-- the pace -- that's the genuine fastest sustainable rate, not a burst that
-- mostly gets thrown away.
task.spawn(function()
	while getgenv().__TH == G do
		if e.thTapEnabled then
			local ok = req(Msg.C2S_TapClickMonster)
			if ok then stats.taps += 1 end
		else
			task.wait(0.25)
		end
	end
end)

-- ---------------------------------------------------------------- Auto Recruit
task.spawn(function()
	while getgenv().__TH == G do
		if e.thRecruitEnabled then
			req(Msg.C2S_TavernRequestData)
			task.wait(1)
			local data = latest[Msg.S2C_UpdateTavernData] and latest[Msg.S2C_UpdateTavernData][1]
			if data and data.Offers then
				for _, offer in pairs(data.Offers) do
					if getgenv().__TH ~= G then break end
					if offer.State == "Available" and offer.OfferId then
						local q = heroQuality(offer.HeroId)
						local qName = q and QUALITY_NAMES[q]
						if qName and e.thRecruitQualities[qName] then
							-- TapRecruitHeroInstance (the first guess) is NOT the tavern
							-- buy action -- fired it with a real offerId and the offer
							-- just sat "Available" forever, no error, nothing. Confirmed
							-- live that TavernHireOffer is the real one: same call, offer
							-- flipped straight to "Hired".
							req(Msg.C2S_TavernHireOffer, offer.OfferId)
							stats.recruits += 1
							task.wait(0.5)
						end
					end
				end
			end
		end
		task.wait(15)
	end
end)

-- ---------------------------------------------------------------- Auto Dungeon
task.spawn(function()
	while getgenv().__TH == G do
		if e.thDungeonEnabled then
			req(Msg.C2S_RequestDungeonData)
			task.wait(1)
			local data = latest[Msg.S2C_UpdateDungeonData] and latest[Msg.S2C_UpdateDungeonData][1]
			local raw = data and data.Raw
			if raw and raw.Dungeons then
				local ids = {}
				for id in pairs(raw.Dungeons) do table.insert(ids, tonumber(id) or id) end
				table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
				for _, id in ipairs(ids) do
					local name = DungeonCfg[id] and DungeonCfg[id][2]
						local skip = not (name and e.thDungeonSelected[name])
						local d = (not skip) and (raw.Dungeons[tostring(id)] or raw.Dungeons[id])
					if d and d.Run and d.Run.Status == "NotEntered" then
						local ok, res = req(Msg.C2S_ChallengeDungeon, id)
						stats.dungeon = ("tried %s"):format(tostring(name))
						break
					end
				end
			end
		end
		task.wait(20)
	end
end)

-- ---------------------------------------------------------------- Daily Reward + Task
task.spawn(function()
	while getgenv().__TH == G do
		if e.thDailyEnabled then
			local ok, res = req(Msg.C2S_EscRewardSignIn)
			if res == true or (type(res) == "table" and res[1] == true) then
				stats.daily = "signed in"
			end

			req(Msg.C2S_RequestDailyTaskData)
			task.wait(0.7)
			local data = latest[Msg.S2C_DailyTaskData] and latest[Msg.S2C_DailyTaskData][1]
			if data and data.Tasks then
				for _, t in ipairs(data.Tasks) do
					if t.Current and t.Target and t.Current >= t.Target then
						req(Msg.C2S_ClaimDailyTask, t.Id)
						task.wait(0.3)
					end
				end
			end
		end
		task.wait(60)
	end
end)

-- ---------------------------------------------------------------- Auto Upgrade
-- Three categories, each confirmed live independently, each a genuinely
-- different call:
--   - "Player Level": C2S_TapUpgradePlayerLevel, no args -- confirmed
--     (InvokeServer returned true, Gold dropped from the spend).
--   - "Heroes": C2S_TapUpgradeHero(heroId) -- takes the shared Configs.Hero
--     id (e.g. 10005), NOT a per-copy instance id. Confirmed live (true) on
--     an owned hero. There's no confirmed way from here to list which
--     Configs.Hero ids are actually owned, so this loops every known hero id
--     -- an unowned one just answers false, same harmless-reject pattern as
--     the achievement claimer.
--   - "Skills": C2S_TapUpgradeSkill, no args -- confirmed (returned true).
--   - Artifacts were tried too (TapUpgradeArtifact / TapAcquireNextArtifact,
--     both with and without an id) and never once returned true in testing
--     -- left out rather than shipping a category that silently never works.
--     If artifacts unlock later (stage-gated, most likely), worth revisiting.
task.spawn(function()
	local heroIds = {}
	for id, rec in pairs(HeroCfg) do
		if typeof(rec) == "table" then table.insert(heroIds, id) end
	end

	while getgenv().__TH == G do
		if e.thUpgradeEnabled then
			if e.thUpgradeCategories["Player Level"] then
				local ok, res = req(Msg.C2S_TapUpgradePlayerLevel)
				if res == true then stats.upgrades += 1 end
			end
			if e.thUpgradeCategories["Skills"] then
				local ok, res = req(Msg.C2S_TapUpgradeSkill)
				if res == true then stats.upgrades += 1 end
			end
			if e.thUpgradeCategories["Heroes"] then
				for _, id in ipairs(heroIds) do
					if getgenv().__TH ~= G then break end
					local ok, res = req(Msg.C2S_TapUpgradeHero, id)
					if res == true then stats.upgrades += 1 end
					task.wait(0.15)
				end
			end
		end
		task.wait(10)
	end
end)

-- ---------------------------------------------------------------- Auto Achievement
-- See header note: no confirmed way to ask "which achievement is current" --
-- tries every known id from Configs.Achievement, low frequency. A wrong id
-- just answers {false, id, "NotCurrentAchievement"} and nothing happens.
task.spawn(function()
	local ids = {}
	for k, v in pairs(AchCfg) do
		if typeof(v) == "table" then table.insert(ids, k) end
	end
	table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)

	while getgenv().__TH == G do
		if e.thAchievementEnabled then
			for _, id in ipairs(ids) do
				if getgenv().__TH ~= G then break end
				local ok, res = req(Msg.C2S_TapClaimAchievement, id)
				local success = (type(res) == "table" and res[1] == true)
				if success then stats.achievements += 1 end
				task.wait(0.15)
			end
		end
		task.wait(45)
	end
end)

-- ---------------------------------------------------------------- Anti-AFK
-- Standard, universal technique -- answers Roblox's own platform "are you
-- still there" Idled event via VirtualUser, same as every other script in
-- this repo that has one (Loot Wars, Ride A Pet). Not a bypass of anything
-- game-specific; the tap loop above already keeps real input flowing to the
-- game server, this is purely for the client-side popup.
local VirtualUser = game:GetService("VirtualUser")
plr.Idled:Connect(function()
	if e.thAntiAFK then
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end
end)

-- ---------------------------------------------------------------- Auto Reconnect
-- Same pattern as roll_anime.lua: Players.PlayerRemoving fires right as the
-- local player is about to leave the server (kick, crash, or the "Client:
-- Disconnect" case this whole session has been chasing) -- Teleport back
-- into the same place immediately. Hooked once via a flag, not gated by the
-- generation counter, since PlayerRemoving only ever fires once per real
-- disconnect regardless of which script generation is currently "active".
if not getgenv().__THReconnectHooked then
	getgenv().__THReconnectHooked = true
	Players.PlayerRemoving:Connect(function(player)
		if player == plr and e.thAutoReconnect then
			pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
		end
	end)
end

-- ---------------------------------------------------------------------- UI
print("[TapborneHeroes] Loading MacLib...")
local okLib, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okLib or not Lib then print("[TapborneHeroes] MacLib failed: " .. tostring(Lib)) return end
task.wait()
if getgenv().__TH ~= G or e.__thTok ~= myUID then print("[TapborneHeroes] Aborted (superseded)") return end

local W = Lib:Window({Title = "Tapborne Heroes", Subtitle = "auto tap / recruit / dungeon / dailies",
                       DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__THW = W
local TG = W:TabGroup()
local Tabs = {
	Farm = TG:Tab({Name = "Farm", Image = "rbxassetid://10723343321"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}

-- ----- Farm Tab -----
local L = Tabs.Farm:Section({Side = "Left"})
L:Header({Text = "Combat"})
L:Toggle({Name = "Auto Tap", Default = e.thTapEnabled,
	Callback = function(v) e.thTapEnabled = v; sv() end}, "thTapEnabled")

L:Header({Text = "Upgrade"})
L:Toggle({Name = "Auto Upgrade", Default = e.thUpgradeEnabled,
	Callback = function(v) e.thUpgradeEnabled = v; sv() end}, "thUpgradeEnabled")
L:Dropdown({
	Name = "Upgrade What", Multi = true, Search = false,
	Options = UPGRADE_CATS, Default = setToArray(e.thUpgradeCategories),
	Callback = function(sel)
		local set = {}
		for name in pairs(sel) do set[name] = true end
		e.thUpgradeCategories = set
		sv()
	end,
}, "thUpgradeCategories")

L:Header({Text = "Recruit"})
L:Toggle({Name = "Auto Recruit", Default = e.thRecruitEnabled,
	Callback = function(v) e.thRecruitEnabled = v; sv() end}, "thRecruitEnabled")
L:Dropdown({
	Name = "Recruit Rarity", Multi = true, Search = false,
	Options = {"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Mythic+"},
	Default = setToArray(e.thRecruitQualities),
	Callback = function(sel)
		local set = {}
		for name in pairs(sel) do set[name] = true end
		e.thRecruitQualities = set
		sv()
	end,
}, "thRecruitQualities")

L:Header({Text = "Dungeon"})
L:Toggle({Name = "Auto Dungeon", Default = e.thDungeonEnabled,
	Callback = function(v) e.thDungeonEnabled = v; sv() end}, "thDungeonEnabled")
L:Dropdown({
	Name = "Which Dungeons", Multi = true, Search = false,
	Options = DUNGEON_NAMES, Default = setToArray(e.thDungeonSelected),
	Callback = function(sel)
		local set = {}
		for name in pairs(sel) do set[name] = true end
		e.thDungeonSelected = set
		sv()
	end,
}, "thDungeonSelected")

local R = Tabs.Farm:Section({Side = "Right"})
R:Header({Text = "Dailies"})
R:Toggle({Name = "Auto Daily Reward + Tasks", Default = e.thDailyEnabled,
	Callback = function(v) e.thDailyEnabled = v; sv() end}, "thDailyEnabled")
R:Toggle({Name = "Auto Claim Achievements", Default = e.thAchievementEnabled,
	Callback = function(v) e.thAchievementEnabled = v; sv() end}, "thAchievementEnabled")
R:Header({Text = "Status"})
local statusLbl = R:Label({Text = "Starting..."})

-- ----- Settings Tab -----
local SettingsLeft = Tabs.Settings:Section({Side = "Left"})
SettingsLeft:Header({Text = "General"})
SettingsLeft:Toggle({
	Name = "Anti-AFK", Default = e.thAntiAFK,
	Callback = function(v) e.thAntiAFK = v; sv() end,
}, "thAntiAFK")
SettingsLeft:Toggle({
	Name = "Auto Reconnect", Default = e.thAutoReconnect,
	Callback = function(v) e.thAutoReconnect = v; sv() end,
}, "thAutoReconnect")
SettingsLeft:Keybind({
	Name = "Show/Hide UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() W:SetState(not W:GetState()) end) end,
}, "TapborneHeroesToggleUIKeybind")
SettingsLeft:Header({Text = "Auto Save"})
SettingsLeft:Label({Text = "All toggles save automatically to:\n" .. SF})

task.spawn(function()
	while getgenv().__TH == G do
		task.wait(1)
		pcall(function()
			statusLbl:UpdateName(("Taps: %d\nRecruits: %d\nUpgrades: %d\nDungeon: %s\nDaily: %s\nAchievements: %d")
				:format(stats.taps, stats.recruits, stats.upgrades, stats.dungeon, stats.daily, stats.achievements))
		end)
	end
end)

W.onUnloaded(function() print("[TapborneHeroes] Unloaded") end)
Tabs.Farm:Select()
print("[TapborneHeroes] UI ready")
