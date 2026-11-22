-- Multi-game loader -- one link, dispatches by game.PlaceId.
-- Add new games by pushing their script under games/ and adding an entry below.
--
-- Safe to put in an executor's autoexec folder:
--   * autoexec fires before the game has loaded -- PlaceId is still 0 and there is no
--     LocalPlayer yet, which is why friends saw "it doesn't auto execute". We wait.
--   * re-queues itself with queue_on_teleport, so it runs again after a rejoin /
--     server hop / the scripts' own Auto Reconnect (executors don't re-run autoexec
--     on an in-process teleport).
--   * runs at most ONCE per game session: autoexec + the queued copy + a manual
--     execute can all fire in the same server -- only the first one loads the game
--     script. Force a reload with getgenv().TS_RELOAD = true before executing.
local LOADER_URL = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/loader.lua"
local genv = (getgenv and getgenv()) or _G

-- one run per DataModel. Compared against `game` itself, not a plain flag: some
-- executors keep getgenv across a teleport, and a flag would then block the new server.
if genv.__TS_LOADER_GAME == game and not genv.TS_RELOAD then
    warn("[Loader] already running in this server -- skipped (set getgenv().TS_RELOAD = true to force)")
    return
end
genv.__TS_LOADER_GAME = game
genv.TS_RELOAD = nil

-- run again after the next teleport (once per server; the guard above stops doubles).
-- A script_key set by the user's own autoexec (Luarmor games) is carried along locally.
local qot = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
    or (fluxus and fluxus.queue_on_teleport)
if qot then
    local carry = ""
    if type(genv.script_key) == "string" then
        carry = ("getgenv().script_key = %q\n"):format(genv.script_key)
    end
    pcall(qot, carry .. ([[
local ok, src
for _ = 1, 6 do
    ok, src = pcall(game.HttpGet, game, %q)
    if ok and type(src) == "string" and #src > 100 then break end
    task.wait(5)
end
if ok and src then local f = loadstring(src) if f then f() end end
]]):format(LOADER_URL))
end

-- wait for the game: PlaceId, LocalPlayer and the character all come late in autoexec
if not game:IsLoaded() then game.Loaded:Wait() end
local Players = game:GetService("Players")
while not Players.LocalPlayer do task.wait(0.2) end
local plr = Players.LocalPlayer
if not plr.Character then
    local t0 = os.clock()
    while not plr.Character and os.clock() - t0 < 30 do task.wait(0.25) end
end
task.wait(2)   -- let the game's own client scripts finish their setup

local PLACE_SCRIPTS = {
    [107653945083776] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/roll_anime.lua", -- Roll Anime to Fight!
    [108307565942574] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/full_rng.lua",   -- [NOW!!] RNG Heroes
    [133188236593503] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/magic_loot.lua", -- Magic Loot[Beta]
    -- Third-party build, not ours -- points straight at the upstream repo rather
    -- than a copy under games/, so it tracks whatever they publish.
    [99108783264633]  = "https://raw.githubusercontent.com/kaisenlmao/loader/refs/heads/main/chiyo.lua",   -- [UPD] Build a base RNG
    -- Ouroboros ships its own loader that dispatches on game.CreatorId across 135
    -- games, so this entry hands off to a second dispatcher rather than to a
    -- script. Verified live: CreatorId 180466034 resolves to growchickenfighter.lua.
    [94640181989498]  = "https://raw.githubusercontent.com/joustingmatch/Ouroboros/main/loader.lua",       -- Grow a Chicken Fighter
    [124216119978534]  = "https://raw.githubusercontent.com/joustingmatch/Ouroboros/main/loader.lua",       -- Ride A Pet
    -- Ouroboros also covers this place, so registering ours here is a choice, not
    -- a gap being filled -- whichever URL sits on this line is the one that loads.
    [90086669327265]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/cutgrass.lua",  -- +1 Cut Grass Adventure
    [105954652742326] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/mutant_plants.lua", -- Mutant Plants: Base Defense[World Boss]
    -- Not ours -- hands off to Ouroboros' CreatorId dispatcher, same as the Grow a
    -- Chicken Fighter entry above.
    [74729868188364]  = "https://raw.githubusercontent.com/joustingmatch/Ouroboros/main/loader.lua",       -- Fish an Anime RNG
    [78490532994307]  = "https://raw.githubusercontent.com/joustingmatch/Ouroboros/main/loader.lua",       -- Build An Ant Empire
    -- Dungeon Lootr is a multi-place universe: 106484206883664 is the RELEASE
    -- lobby, 132285059959516 is the [Gameplay] sub-place you get teleported into.
    -- Both need the entry -- a direct join into a gameplay server never touches
    -- the lobby. Luarmor loader: needs getgenv().script_key set BEFORE this runs;
    -- the autoexec does that locally so the key never lands in this public repo.
    [106484206883664] = "https://api.luarmor.net/files/v4/loaders/68c9fa895f076506ac0b47e12868d124.lua",   -- Dungeon Lootr [RELEASE] (Luarmor)
    [132285059959516] = "https://api.luarmor.net/files/v4/loaders/68c9fa895f076506ac0b47e12868d124.lua",   -- Dungeon Lootr [Gameplay] (Luarmor)
    [70640255604878]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/pull_an_egg.lua",      -- Pull An Egg
    [87075726814250]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/defend_your_town.lua", -- Defend Your Town
    [80519520593681]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/tapborne_heroes.lua",  -- Tapborne Heroes
    [99388466709359]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/soul_hero.lua",        -- [IDLE] Soul Hero
    -- Ours (MacLib), ported from the third-party "2K" gist build after reading
    -- it end to end -- same Knit remotes, our theme, our config file.
    [88047783411976]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/open_sea.lua",         -- Open Sea For Animals
    [117483759937632] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/hunting_together.lua", -- ⚔️ [DUNGEON] Hunting Together RPG
    [79389059854988]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/my_anime_mine.lua",    -- ⛏️ My Anime Mine
    [108419873026523] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/revolver_arena.lua",   -- [RANKED] Revolver Arena
    [125866884667103] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/sushi.lua",            -- Sell a Million Sushi
    [88452215181406]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/pet_hunt_party.lua",   -- [🎉RELEASE] Pet Hunt Party 🐾 RPG
    [79496881832552]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/run_a_farm.lua",       -- [UPD] Run A Farm!
    [89695026030574]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/summon_pet_army.lua",  -- Summon a Pet Army
    [74183246285569]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/steal_a_superpower.lua", -- [⚡] Steal a Superpower!
    [116750055341696] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/amulet_street.lua",      -- ถนนพระเครื่อง (Amulet Street)
    -- Battle Royale universe: the match server and the Killstreak mode share one script
    [108448382032231] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/battle_royale.lua",   -- Battle Royale (chest + player ESP)
    [104856666707760] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/battle_royale.lua",   -- Killstreak Battle Royale
}

local url = PLACE_SCRIPTS[game.PlaceId]
if not url then
    genv.__TS_LOADER_GAME = nil
    warn(("[Loader] No script registered for this game (PlaceId %d, %s)"):format(game.PlaceId, game.Name))
    return
end

-- retry: right after joining, HttpGet can fail once or twice
local fetched, body
for attempt = 1, 6 do
    fetched, body = pcall(game.HttpGet, game, url)
    if fetched and type(body) == "string" and #body > 0 then break end
    if attempt < 6 then task.wait(5) end
end
if not fetched then
    genv.__TS_LOADER_GAME = nil   -- failed: let a manual re-execute try again
    error("[Loader] Failed to fetch script for PlaceId " .. game.PlaceId .. ": " .. tostring(body))
end

local compiled, err = loadstring(body)
if not compiled then
    genv.__TS_LOADER_GAME = nil
    error("[Loader] Failed to compile script for PlaceId " .. game.PlaceId .. ": " .. tostring(err))
end

local ran, runErr = pcall(compiled)
if not ran then
    genv.__TS_LOADER_GAME = nil
    error("[Loader] Script error for PlaceId " .. game.PlaceId .. ": " .. tostring(runErr))
end
