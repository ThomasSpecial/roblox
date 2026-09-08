-- Multi-game loader -- one link, dispatches by game.PlaceId.
-- Add new games by pushing their script under games/ and adding an entry below.
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
    -- Ouroboros also covers this place, so registering ours here is a choice, not
    -- a gap being filled -- whichever URL sits on this line is the one that loads.
    [90086669327265]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/cutgrass.lua",  -- +1 Cut Grass Adventure
    [105954652742326] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/mutant_plants.lua", -- Mutant Plants: Base Defense[World Boss]
    -- Not ours -- hands off to Ouroboros' CreatorId dispatcher, same as the Grow a
    -- Chicken Fighter entry above.
    [74729868188364]  = "https://raw.githubusercontent.com/joustingmatch/Ouroboros/main/loader.lua",       -- Fish an Anime RNG
    -- Dungeon Lootr is a multi-place universe: 106484206883664 is the RELEASE
    -- lobby, 132285059959516 is the [Gameplay] sub-place you get teleported into.
    -- Both need the entry -- a direct join into a gameplay server never touches
    -- the lobby. Luarmor loader: needs getgenv().script_key set BEFORE this runs;
    -- the autoexec does that locally so the key never lands in this public repo.
    [106484206883664] = "https://api.luarmor.net/files/v4/loaders/68c9fa895f076506ac0b47e12868d124.lua",   -- Dungeon Lootr [RELEASE] (Luarmor)
    [132285059959516] = "https://api.luarmor.net/files/v4/loaders/68c9fa895f076506ac0b47e12868d124.lua",   -- Dungeon Lootr [Gameplay] (Luarmor)
    [70640255604878]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/pull_an_egg.lua",      -- Pull An Egg
    [87075726814250]  = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/defend_your_town.lua", -- Defend Your Town
}

local url = PLACE_SCRIPTS[game.PlaceId]
if not url then
    warn(("[Loader] No script registered for this game (PlaceId %d, %s)"):format(game.PlaceId, game.Name))
    return
end

local fetched, body = pcall(game.HttpGet, game, url)
if not fetched then
    error("[Loader] Failed to fetch script for PlaceId " .. game.PlaceId .. ": " .. tostring(body))
end

local compiled, err = loadstring(body)
if not compiled then
    error("[Loader] Failed to compile script for PlaceId " .. game.PlaceId .. ": " .. tostring(err))
end

compiled()
