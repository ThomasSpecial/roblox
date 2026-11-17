-- Sell a Million Sushi (placeId 125866884667103)
-- Auto Collect Money / Auto Collect Fish / Auto Deposit Fish / Auto Hire Fisherman / Auto Merge
-- MacLib window, RightShift toggles it, settings persist (Sushi/state_<uid>.json).
--
-- From the game's own client (PlayerScripts.LootPickupScript):
--   * caught fish are CLIENT-side parts in workspace.ClientLoot with a "LootTier" attribute; the
--     game picks them up with RemoteEvents.LootPickup:FireServer({tier, ...}, false) and destroys
--     the parts -- the server takes it from anywhere, so we do the same for every fish at once
--   * money / deposit / hire / merge are server touch pads on our plot
--     (Plots.<assignedPlot>.Sell.CollectButton / DepositButton, Buttons.ButtonBuy<N> / ButtonMerge)
--     -> firetouchinterest, no walking
--   * HUD: cash = CurrencyGui..CashText, fish = LootGui..MoneyText, fishermen = attr CurrentCount

getgenv().__SUSHI = (getgenv().__SUSHI or 0) + 1
local G = getgenv().__SUSHI
pcall(function() if getgenv().__SUSHIW then getgenv().__SUSHIW:Unload() end end)
local function alive() return getgenv().__SUSHI == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local plr = Players.LocalPlayer
local Remotes = RS:WaitForChild("RemoteEvents", 30)

-- ------------------------------------------------------------------ settings
local SF = ("Sushi/state_%d.json"):format(plr.UserId)
local DEFAULTS = {money = true, moneyEvery = 1, fish = true, deposit = true, depositEvery = 1,
	hire = true, hireAmount = "x1", hireEvery = 1, merge = true, mergeEvery = 3}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
local function sv()
	pcall(function()
		if makefolder and not isfolder("Sushi") then makefolder("Sushi") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

-- ------------------------------------------------------------------ helpers
local SUFFIX = {K = 1e3, M = 1e6, B = 1e9, T = 1e12, Qa = 1e15, Qi = 1e18, Sx = 1e21, Sp = 1e24,
	Oc = 1e27, No = 1e30, De = 1e33, Ud = 1e36, Dd = 1e39, Td = 1e42, Qad = 1e45, Qid = 1e48}
local function parseNum(s)
	s = tostring(s or ""):gsub("[%$,%s]", "")
	local n, suf = s:match("^([%d%.]+)(%a*)$")
	n = tonumber(n)
	if not n then return nil end
	if suf ~= "" then
		local m = SUFFIX[suf] or SUFFIX[suf:sub(1, 1):upper() .. suf:sub(2):lower()]
		if not m then return nil end
		n *= m
	end
	return n
end
local function guiText(gui, name)
	local g = plr.PlayerGui:FindFirstChild(gui)
	local t = g and g:FindFirstChild(name, true)
	return t and t.Text
end
local function cash() return parseNum(guiText("CurrencyGui", "CashText")) or 0 end
local function fishHeld() return parseNum(guiText("LootGui", "MoneyText")) or 0 end
local function plot() return workspace.Plots:FindFirstChild(tostring(plr:GetAttribute("assignedPlot"))) end
local function hrp() local c = plr.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local function touch(part)
	local r = hrp()
	if not (r and part) then return false end
	firetouchinterest(r, part, 0)
	task.wait(0.1)
	firetouchinterest(r, part, 1)
	return true
end
local function pad(...)
	local o = plot()
	for _, n in ipairs({...}) do o = o and o:FindFirstChild(n) end
	return o and o:FindFirstChild("Button")
end

local st = {money = "-", fish = "-", deposit = "-", hire = "-", merge = "-", fishTotal = 0, hired = 0}

-- ------------------------------------------------------------------ fish (every catch, instantly)
local function fishTick()
	local f = workspace:FindFirstChild("ClientLoot")
	if not f then return end
	local tiers, parts = {}, {}
	for _, x in ipairs(f:GetDescendants()) do
		if x:IsA("BasePart") then
			local t = x:GetAttribute("LootTier")
			if t then
				tiers[#tiers + 1] = t
				parts[#parts + 1] = x.Parent:IsA("Model") and x.Parent or x
			end
		end
	end
	if #tiers == 0 then return end
	for _, p in ipairs(parts) do pcall(function() p:Destroy() end) end
	Remotes.LootPickup:FireServer(tiers, false)
	st.fishTotal += #tiers
	st.fish = ("เก็บ %d ตัว · %s"):format(#tiers, os.date("%H:%M:%S"))
end

-- ------------------------------------------------------------------ loops
task.spawn(function()
	while alive() do
		if e.fish then pcall(fishTick) end
		task.wait(0.15)
	end
end)

local HIRE = {x1 = "ButtonBuy1", x5 = "ButtonBuy5", x25 = "ButtonBuy25", x100 = "ButtonBuy100"}
task.spawn(function()
	local lastM, lastD, lastH, lastG = 0, 0, 0, 0
	while alive() do
		local now = os.clock()
		if e.deposit and now - lastD >= (tonumber(e.depositEvery) or 1) then
			lastD = now
			pcall(function()
				local n = fishHeld()
				if n > 0 and touch(pad("Sell", "DepositButton")) then
					st.deposit = ("ส่งให้เชฟ %s ตัว · %s"):format(guiText("LootGui", "MoneyText") or "?", os.date("%H:%M:%S"))
				else
					st.deposit = "ไม่มีปลาในมือ"
				end
			end)
		end
		if e.money and now - lastM >= (tonumber(e.moneyEvery) or 1) then
			lastM = now
			pcall(function()
				local c0 = cash()
				if touch(pad("Sell", "CollectButton")) then
					task.wait(0.3)
					local got = cash() - c0
					st.money = got > 0 and ("+$%d · %s"):format(math.floor(got), os.date("%H:%M:%S")) or "ยังไม่มีเงินให้เก็บ"
				end
			end)
		end
		if e.hire and now - lastH >= (tonumber(e.hireEvery) or 1) then
			lastH = now
			pcall(function()
				local name = HIRE[e.hireAmount] or "ButtonBuy1"
				local b = plot() and plot().Buttons:FindFirstChild(name)
				local price = b and parseNum((b:FindFirstChild("PriceText", true) or {}).Text)
				if not (b and price) then st.hire = "หาปุ่มจ้างไม่เจอ"; return end
				if cash() < price then st.hire = ("รอเงิน %s (%s)"):format((b:FindFirstChild("PriceText", true) or {}).Text or "?", e.hireAmount); return end
				local n0 = tonumber(plr:GetAttribute("CurrentCount")) or 0
				touch(b:FindFirstChild("Button"))
				task.wait(0.3)
				local d = (tonumber(plr:GetAttribute("CurrentCount")) or 0) - n0
				if d > 0 then st.hired += d end
				st.hire = ("จ้าง %s · มีทั้งหมด %s คน"):format(e.hireAmount, tostring(plr:GetAttribute("CurrentCount")))
			end)
		end
		if e.merge and now - lastG >= (tonumber(e.mergeEvery) or 3) then
			lastG = now
			pcall(function()
				if touch(pad("Buttons", "ButtonMerge")) then st.merge = "กด Merge · " .. os.date("%H:%M:%S") end
			end)
		end
		task.wait(0.2)
	end
end)

-- ---------------------------------------------------------------------- UI
local okL, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okL or not Lib then warn("[Sushi] MacLib failed: " .. tostring(Lib)) return end
if not alive() then return end
local W = Lib:Window({Title = "Sell a Million Sushi", Subtitle = "Auto Farm", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__SUSHIW = W
local TG = W:TabGroup()
local Tabs = {
	Main = TG:Tab({Name = "Auto", Image = "rbxassetid://10723346959"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}
local L = Tabs.Main:Section({Side = "Left"})
L:Header({Text = "ปลา / เงิน"})
L:Toggle({Name = "Auto Collect Fish Instant (เก็บปลาทุกตัวทันทีที่ตกได้)", Default = e.fish,
	Callback = function(v) e.fish = v; sv() end}, "SUFish")
L:Toggle({Name = "Auto Deposit Fish Instant (ส่งปลาให้เชฟ)", Default = e.deposit,
	Callback = function(v) e.deposit = v; sv() end}, "SUDeposit")
L:Toggle({Name = "Auto Collect Money Instant (เก็บเงิน)", Default = e.money,
	Callback = function(v) e.money = v; sv() end}, "SUMoney")
L:Header({Text = "คนตกปลา"})
L:Toggle({Name = "Auto Hire Fisherman", Default = e.hire,
	Callback = function(v) e.hire = v; sv() end}, "SUHire")
local AMTS = {"x1", "x5", "x25", "x100"}
L:Dropdown({Name = "└ จ้างครั้งละ", Multi = false, Required = true, Options = AMTS,
	Default = table.find(AMTS, e.hireAmount) or 1,
	Callback = function(v) if type(v) == "table" then v = v[1] end; if v then e.hireAmount = v; sv() end end}, "SUHireAmt")
L:Slider({Name = "└ จ้างทุก", Minimum = 0.5, Maximum = 30, Default = tonumber(e.hireEvery) or 1, Precision = 1,
	Suffix = " วิ", Callback = function(v) e.hireEvery = v; sv() end}, "SUHireEvery")
L:Toggle({Name = "Auto Merge Fisherman", Default = e.merge,
	Callback = function(v) e.merge = v; sv() end}, "SUMerge")
L:Slider({Name = "└ Merge ทุก", Minimum = 1, Maximum = 60, Default = tonumber(e.mergeEvery) or 3, Precision = 0,
	Suffix = " วิ", Callback = function(v) e.mergeEvery = math.floor(v + 0.5); sv() end}, "SUMergeEvery")
L:Label({Text = "จ้างเฉพาะตอนเงินพอ (ไม่กดรัวตอนเงินไม่ถึง)\nทุกอย่างกดปุ่มบนแปลงจากระยะไกล ไม่ต้องเดิน"})

local R = Tabs.Main:Section({Side = "Right"})
R:Header({Text = "สถานะ"})
local stLbl = R:Label({Text = "-"})

local S = Tabs.Settings:Section({Side = "Left"})
S:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() W:SetState(not W:GetState()) end) end}, "SUToggleUI")
S:Label({Text = "ตั้งค่าเซฟที่: " .. SF})

task.spawn(function()
	while alive() do
		pcall(function()
			stLbl:UpdateName(table.concat({
				("เงิน: $%s · ปลาในมือ: %s · คนตกปลา: %s"):format(guiText("CurrencyGui", "CashText") or "?",
					guiText("LootGui", "MoneyText") or "?", tostring(plr:GetAttribute("CurrentCount") or "?")),
				"Fish: " .. st.fish .. " · รวม " .. st.fishTotal .. " ตัว",
				"Deposit: " .. st.deposit,
				"Money: " .. st.money,
				"Hire: " .. st.hire .. " · จ้างไป " .. st.hired .. " คน",
				"Merge: " .. st.merge,
			}, "\n"))
		end)
		task.wait(1)
	end
end)

W.onUnloaded(function()
	if getgenv().__SUSHI == G then getgenv().__SUSHI = G + 1 end
	print("[Sushi] Unloaded")
end)
Tabs.Main:Select()
print("[Sushi] UI ready")
