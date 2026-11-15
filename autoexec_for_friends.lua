-- ThomasSpecial loader -- autoexec version.
-- Put this file in your executor's autoexec folder, e.g. for Real:
--   %LOCALAPPDATA%\Real\autoexec\thomas_loader.lua
-- loader.lua itself waits for the game to load, re-runs after a rejoin / teleport,
-- and never runs twice in the same server -- this file only retries the download
-- in case the network isn't ready the instant the executor injects.
local URL = "https://raw.githubusercontent.com/ThomasSpecial/roblox/main/loader.lua"
for _ = 1, 6 do
	local ok, src = pcall(game.HttpGet, game, URL)
	if ok and type(src) == "string" and #src > 100 then
		local fn, err = loadstring(src)
		if fn then fn() else warn("[ThomasSpecial] loader compile error: " .. tostring(err)) end
		return
	end
	task.wait(5)
end
warn("[ThomasSpecial] could not download loader.lua")
