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
