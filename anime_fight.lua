-- Multi-game loader -- one link, dispatches by game.PlaceId.
-- Add new games by pushing their script under games/ and adding an entry below.
local PLACE_SCRIPTS = {
    [107653945083776] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/roll_anime.lua", -- Roll Anime to Fight!
    [108307565942574] = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/games/full_rng.lua",   -- [NOW!!] RNG Heroes
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
