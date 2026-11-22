-- ถนนพระเครื่อง (Amulet Street, placeId 116750055341696) -- counter bot: reads every amulet a customer lays on the tray,
-- tells genuine from fake exactly, and buys / rejects / certifies / hands back for you. MacLib window, RightShift toggles
-- it, settings persist (AmuletStreet/state_<userId>.json).
--
-- How the game works (verified 2026-11-22):
--   Everything goes through ReplicatedStorage.ShopRemotes.Act (RemoteFunction: Act(action, args) -> ok, msg) and the
--   server pushes the whole shop as ShopRemotes.Push("state", data). data.Customer = the customer at the owner's counter:
--   Intent "sell" (wants to rent it to you) / "cert" (wants a certificate) / "both" / "pickup" (collecting after the
--   machine); Items[i] = {Stage = offer|post|return|done|.., Model, Spec = {Condition, Features}, Ask, PostAsk, Fee}.
--   Real vs fake: AmuletLab.Generate builds a fake by swapping ONE check of the model (Features.Variant becomes the
--   check's Fake mesh id like "G3_F2", or Proc is set, or a Fakes value) -- so an item is genuine exactly when its
--   Features equal AmuletLab.Genuine(model).Features. Matches the server's own verdict on every graded item in the safe.
--   Market value shown by the game = ShopMarket.price(data.Market, model) * ShopConfig.CondMult(condition).
--   Counter actions (args {i = item index, dt = seconds spent deciding}): buy, pass, machine, self (+ v = genuine?),
--   buyPost, handBack, dismiss. "self" needs the model's book (Know[model] >= 1); otherwise "machine" (it keeps 70 %).
--   Hired staff carry everything afterwards (runner -> scanner, front -> return shelf, seller/host -> live table / safe).

getgenv().__AMS = (getgenv().__AMS or 0) + 1
local G = getgenv().__AMS
pcall(function() if getgenv().__AMSW then getgenv().__AMSW:Unload() end end)
pcall(function() if getgenv().__AMSGUI then getgenv().__AMSGUI:Destroy() end end)
local function alive() return getgenv().__AMS == G end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local plr = Players.LocalPlayer

local Remotes = RS:WaitForChild("ShopRemotes")
local Act = Remotes:WaitForChild("Act")
local Push = Remotes:WaitForChild("Push")
local Lab = require(RS:WaitForChild("AmuletLab"))
local SC = require(RS:WaitForChild("ShopConfig"))
local Market = require(RS:WaitForChild("ShopMarket"))

-- ------------------------------------------------------------------ settings
local SF = ("AmuletStreet/state_%d.json"):format(plr.UserId)
local DEFAULTS = {counter = false, buyPct = 80, buy = true, selfCert = true, dismiss = true, overlay = true, antiAfk = true, reconnect = true}
local e = {}
pcall(function() if isfile and isfile(SF) then local t = HS:JSONDecode(readfile(SF)); if type(t) == "table" then e = t end end end)
for k, v in pairs(DEFAULTS) do if e[k] == nil then e[k] = v end end
local function sv()
	pcall(function()
		if makefolder and not isfolder("AmuletStreet") then makefolder("AmuletStreet") end
		writefile(SF, HS:JSONEncode(e))
	end)
end

local st = {status = "รอข้อมูลร้านจากเกม", last = "-", bought = 0, passed = 0, fakesRejected = 0, selfCerts = 0, machine = 0,
	handed = 0, spent = 0, wd = "-", err = "-", log = {}}

-- ------------------------------------------------------------------ helpers
local function money(n) local ok, s = pcall(Lab.Money, n); return ok and s or tostring(n) end
local function note(line)
	st.last = os.date("%H:%M:%S ") .. line
	table.insert(st.log, 1, st.last)
	if #st.log > 8 then table.remove(st.log) end
end

local S   -- latest pushed shop state
local stateAt = 0
local pushConn = Push.OnClientEvent:Connect(function(kind, data)
	if kind == "state" and type(data) == "table" then S = data; stateAt = os.clock() end
end)

local genuineCache = {}
local function genuineFeatures(model)
	if genuineCache[model] == nil then
		local ok, g = pcall(Lab.Genuine, model)
		genuineCache[model] = ok and g and g.Features or false
	end
	return genuineCache[model]
end
-- true / false, or nil when the model is unknown to this build
local function isGenuine(spec)
	if type(spec) ~= "table" then return nil end
	local g = genuineFeatures(spec.Model)
	if not g then return nil end
	local f = spec.Features or {}
	if f.Proc ~= nil then return false end
	for k, v in pairs(g) do if f[k] ~= nil and f[k] ~= v then return false end end
	for k in pairs(f) do if g[k] == nil then return false end end
	return true
end
local function marketValue(item)
	local model = item.Model or (item.Spec and item.Spec.Model)
	local ok, p = pcall(Market.price, S and S.Market or {}, model)
	p = ok and tonumber(p) or (Lab.Models[model] and Lab.Models[model].Price) or 0
	return math.floor(p * SC.CondMult(math.clamp(math.floor(tonumber(item.Spec and item.Spec.Condition) or 100), 1, 100)) / 10 + 0.5) * 10
end
local selfFailed = {}   -- model -> true once the server refused a self check (book not enough after all)
local function hasBook(model) return math.floor(((S and S.Know and S.Know[model]) or 0) + 1e-6) >= 1 end
local function modelName(model) local m = Lab.Models[model]; return m and m.Name or tostring(model) end
local function short(s, n) s = tostring(s); return utf8.len(s) and utf8.len(s) > n and (s:sub(1, utf8.offset(s, n + 1) - 1) .. "…") or s end

-- what the bot would do with one tray item: action, args extra, reason
local function decide(C, it)
	local gen = isGenuine(it.Spec)
	local mv = marketValue(it)
	local cash = tonumber(S and S.Cash) or 0
	local cap = math.min(mv * (tonumber(e.buyPct) or 80) / 100, cash)   -- never offer more than the till holds
	local function certify()
		if gen ~= nil and e.selfCert and hasBook(it.Model) and not selfFailed[it.Model] then
			return "self", {v = gen}, ("ตรวจเอง → %s (ได้ค่าตรวจเต็ม %s)"):format(gen and "แท้" or "เก๊", money(it.Fee or 0))
		end
		return "machine", nil, hasBook(it.Model) and "ส่งเครื่องตรวจ" or "ยังไม่มีสมุดรุ่นนี้ → ส่งเครื่องตรวจ"
	end
	if it.Stage == "return" then return "handBack", nil, "ส่งคืนพร้อมใบเซอร์" end
	if it.Stage == "post" then
		local ask = tonumber(it.PostAsk)
		if gen and e.buy and ask and ask <= cap then return "buyPost", nil, ("แท้ · ขอ %s ≤ %d%% ของตลาด %s → รับเช่า"):format(money(ask), e.buyPct, money(mv)) end
		return "pass", nil, gen == false and "เก๊ → ไม่เอา" or (ask or 0) > cash and ("ขอ %s เงินไม่พอ → ไม่เอา"):format(money(ask or 0))
			or ("ขอ %s แพงกว่า %d%% ของตลาด %s → ไม่เอา"):format(money(ask or 0), e.buyPct, money(mv))
	end
	if it.Stage ~= "offer" then return nil end
	if C.Intent == "cert" then return certify() end
	local ask = tonumber(it.Ask)
	if gen and e.buy and ask and ask <= cap then return "buy", nil, ("แท้ · ขอ %s ≤ %d%% ของตลาด %s → รับเช่า"):format(money(ask), e.buyPct, money(mv)) end
	if C.Intent == "both" then return certify() end
	if gen == nil then return nil, nil, "ไม่รู้จักรุ่นนี้ → ปล่อยให้เจ้าของตัดสิน" end
	return "pass", nil, gen == false and "เก๊ → ไม่เอา" or (ask or 0) > cash and ("ขอ %s เงินไม่พอ → ไม่เอา"):format(money(ask or 0))
		or ("ขอ %s แพงกว่า %d%% ของตลาด %s → ไม่เอา"):format(money(ask or 0), e.buyPct, money(mv))
end

local function itemsOf(C)
	local list = {}
	for i, it in pairs(C and C.Items or {}) do
		if type(it) == "table" then list[#list + 1] = {i = tonumber(i) or i, it = it} end
	end
	table.sort(list, function(a, b) return tostring(a.i) < tostring(b.i) end)
	return list
end

-- ------------------------------------------------------------------ counter loop
local lastAct, doneSince, doneFor = 0, nil, nil
local function counterStep()
	if not S then st.status = "รอข้อมูลร้านจากเกม (เกมส่งมาเมื่อมีลูกค้า / ของเปลี่ยน)"; return end
	local C = S.Customer
	if not C or not C.Id then st.status = "รอลูกค้าที่เคาน์เตอร์"; doneSince = nil; return end
	if plr:GetAttribute("CounterSeated") ~= true then st.status = "ลูกค้ารออยู่ แต่ยังไม่ได้นั่งที่เคาน์เตอร์ → ไปนั่งก่อน"; return end
	local open = 0
	for _, row in ipairs(itemsOf(C)) do
		local it = row.it
		if it.Stage ~= "done" then open += 1 end
		local action, extra, why = decide(C, it)
		if action then
			-- look at it like a person would: 1.6-3.2 s per item, never faster than the game's "slow down" guard
			local dt = 1.6 + math.random() * 1.6
			st.status = ("ลูกค้า%s · องค์ที่ %s %s: %s"):format(C.Intent == "pickup" and "มารับคืน" or "", tostring(row.i), short(modelName(it.Model), 22), why)
			local t0 = os.clock()
			while alive() and e.counter and os.clock() - t0 < dt do task.wait(0.1) end
			if not alive() or not e.counter then return end
			-- the state may have moved on while we "looked" (you clicked it yourself, the clerk took it, the customer left)
			local C2 = S and S.Customer
			local it2 = C2 and C2.Id == C.Id and C2.Items and C2.Items[row.i]
			if not it2 or it2.Stage ~= it.Stage then return end
			local args = {i = row.i, dt = os.clock() - t0 + 0.4}
			for k, v in pairs(extra or {}) do args[k] = v end
			local ok, r1, r2 = pcall(Act.InvokeServer, Act, action, args)
			lastAct = os.clock()
			if ok and r1 then
				if action == "buy" or action == "buyPost" then
					st.bought += 1; st.spent += tonumber(action == "buy" and it.Ask or it.PostAsk) or 0
				elseif action == "pass" then
					st.passed += 1; if isGenuine(it.Spec) == false then st.fakesRejected += 1 end
				elseif action == "self" then st.selfCerts += 1
				elseif action == "machine" then st.machine += 1
				elseif action == "handBack" then st.handed += 1 end
				note(("#%s %s · %s"):format(tostring(row.i), short(modelName(it.Model), 18), why))
			else
				note(("#%s %s ไม่ผ่าน: %s"):format(tostring(row.i), action, tostring(ok and r2 or r1)))
				if action == "self" then selfFailed[it.Model] = true end   -- next pass sends it to the machine instead
				task.wait(1)
			end
			return   -- one decision per step; the next state push drives the next one
		end
	end
	if open == 0 and e.dismiss then
		if doneFor ~= C.Id then doneFor, doneSince = C.Id, os.clock() end
		if os.clock() - doneSince > 6 and os.clock() - lastAct > 3 then
			local ok, r1 = pcall(Act.InvokeServer, Act, "dismiss")
			lastAct = os.clock()
			if ok and r1 then note("ทุกองค์เสร็จแล้ว → ส่งลูกค้ากลับ") end
			doneSince = os.clock() + 20
		end
		st.status = "ลูกค้าคนนี้เสร็จแล้ว รอเขาเดินออก"
	else
		st.status = ("ลูกค้า (%s) · เหลือ %d องค์ที่บอทไม่ตัดสิน (ไม่รู้จักรุ่น / รอเครื่องตรวจ)"):format(tostring(C.Intent), open)
	end
end

task.spawn(function()
	while alive() do
		if e.counter then
			local ok, err = pcall(counterStep)
			if not ok then st.err = os.date("%H:%M:%S ") .. tostring(err) end
		else
			st.status = "Auto Counter ปิดอยู่"
		end
		task.wait(0.4)
	end
end)

-- ------------------------------------------------------------------ overlay: real / fake for every tray item
local gui = Instance.new("ScreenGui")
gui.Name = "AmuletCheck"
gui.ResetOnSpawn = false
gui.DisplayOrder = 50
pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
getgenv().__AMSGUI = gui
local box = Instance.new("TextLabel")
box.AnchorPoint = Vector2.new(0.5, 0)
box.Position = UDim2.new(0.5, 0, 0, 58)
box.Size = UDim2.fromOffset(640, 0)
box.AutomaticSize = Enum.AutomaticSize.Y
box.BackgroundColor3 = Color3.fromRGB(25, 20, 18)
box.BackgroundTransparency = 0.2
box.TextColor3 = Color3.fromRGB(255, 255, 255)
box.Font = Enum.Font.GothamMedium
box.TextSize = 17
box.RichText = true
box.TextWrapped = true
box.TextXAlignment = Enum.TextXAlignment.Left
box.Text = ""
box.Visible = false
box.Parent = gui
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)
local pad = Instance.new("UIPadding", box)
pad.PaddingLeft, pad.PaddingRight, pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 10), UDim.new(0, 10), UDim.new(0, 6), UDim.new(0, 6)

local INTENT = {sell = "เอามาให้เช่า", cert = "ขอใบเซอร์", both = "ให้เช่าก็ได้ / ตรวจก่อน", pickup = "มารับพระคืน"}
task.spawn(function()
	while alive() do
		pcall(function()
			local C = S and S.Customer
			if not e.overlay or not C or not C.Id then box.Visible = false; return end
			local lines = {("<b>ลูกค้า: %s</b>"):format(INTENT[C.Intent] or tostring(C.Intent))}
			for _, row in ipairs(itemsOf(C)) do
				local it = row.it
				local gen = isGenuine(it.Spec)
				local tag = gen == true and '<font color="#7CFF6E"><b>แท้</b></font>' or gen == false and '<font color="#FF6A5A"><b>เก๊</b></font>' or "<b>?</b>"
				local ask = it.Stage == "post" and it.PostAsk or it.Ask
				local _, _, why = decide(C, it)
				lines[#lines + 1] = ("#%s %s · %s · สภาพ %s · ตลาด %s%s%s"):format(tostring(row.i), tag, short(modelName(it.Model), 24),
					tostring(it.Spec and it.Spec.Condition or "?"), money(marketValue(it)), ask and (" · ขอ " .. money(ask)) or "",
					it.Stage == "done" and " · เสร็จ" or (why and ('\n    <font color="#FFE038">' .. why .. "</font>") or ""))
			end
			box.Text = table.concat(lines, "\n")
			box.Visible = true
		end)
		task.wait(0.3)
	end
	gui:Destroy()
end)

-- ------------------------------------------------------------------ anti-AFK + auto reconnect
local VirtualUser = game:GetService("VirtualUser")
local idleConn = plr.Idled:Connect(function()
	if not alive() or not e.antiAfk then return end
	pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
	st.wd = "anti-AFK · " .. os.date("%H:%M:%S")
end)
local GuiService = game:GetService("GuiService")
local TeleportService = game:GetService("TeleportService")
local rejoining = false
local errConn = GuiService.ErrorMessageChanged:Connect(function()
	task.defer(function()
		if rejoining or not e.reconnect or not alive() then return end
		local ok, code = pcall(function() return GuiService:GetErrorCode().Value end)
		if not ok or type(code) ~= "number" or code < 256 or code >= 512 or code == 273 or code == 274 then return end
		rejoining = true
		st.wd = ("หลุด (code %d) → เข้าเกมใหม่ · %s"):format(code, os.date("%H:%M:%S"))
		task.wait(5)
		for _ = 1, 20 do
			if not e.reconnect or not alive() then break end
			pcall(function() TeleportService:Teleport(game.PlaceId, plr) end)
			task.wait(15)
		end
		rejoining = false
	end)
end)

-- ---------------------------------------------------------------------- UI
local okL, Lib = pcall(function()
	return loadstring(game:HttpGet("https://github.com/biggaboy212/Maclib/releases/latest/download/maclib.txt"))()
end)
if not okL or not Lib then warn("[AMS] MacLib failed: " .. tostring(Lib)) return end
if not alive() then return end
local Win = Lib:Window({Title = "ถนนพระเครื่อง", Subtitle = "Counter Bot", DragStyle = 1, ShowUserInfo = true, AcrylicBlur = false})
getgenv().__AMSW = Win
local TG = Win:TabGroup()
local Tabs = {
	Main = TG:Tab({Name = "เคาน์เตอร์", Image = "rbxassetid://10723346959"}),
	Settings = TG:Tab({Name = "Settings", Image = "rbxassetid://10734950309"}),
}

local L = Tabs.Main:Section({Side = "Left"})
L:Header({Text = "Auto Counter"})
L:Toggle({Name = "Auto Counter (ตัดสินใจพระที่ลูกค้าวางให้)", Default = e.counter, Callback = function(v) e.counter = v; sv() end}, "AMSCounter")
L:Label({Text = "บอทรู้แท้ / เก๊แน่นอน (เทียบลักษณะกับองค์แท้ของรุ่น)\nเก๊ → ไม่เอา · ขอใบเซอร์ → ตรวจเองตอบถูก (มีสมุด) ไม่งั้นส่งเครื่อง\nมารับคืน → ส่งคืนพร้อมใบเซอร์ · ต้องนั่งที่เคาน์เตอร์"})
L:Toggle({Name = "รับเช่าองค์แท้ที่ราคาคุ้ม", Default = e.buy, Callback = function(v) e.buy = v; sv() end}, "AMSBuy")
L:Slider({Name = "└ รับเช่าเมื่อขอไม่เกิน % ของราคาตลาด", Minimum = 30, Maximum = 100, Default = tonumber(e.buyPct) or 80,
	Precision = 0, DisplayMethod = "Round", Callback = function(v) e.buyPct = math.floor(v + 0.5); sv() end}, "AMSBuyPct")
L:Toggle({Name = "ตรวจเองเมื่อมีสมุดรุ่นนั้น (ได้ค่าตรวจเต็ม แทนส่งเครื่องเสีย 70%)", Default = e.selfCert, Callback = function(v) e.selfCert = v; sv() end}, "AMSSelf")
L:Toggle({Name = "ส่งลูกค้ากลับเมื่อทุกองค์เสร็จแล้ว", Default = e.dismiss, Callback = function(v) e.dismiss = v; sv() end}, "AMSDismiss")
L:Header({Text = "ตัวช่วยดู"})
L:Toggle({Name = "ป้ายบอก แท้ / เก๊ + ราคาตลาด บนจอ", Default = e.overlay, Callback = function(v) e.overlay = v; sv() end}, "AMSOverlay")

local R = Tabs.Main:Section({Side = "Right"})
R:Header({Text = "สถานะ"})
local stLbl = R:Label({Text = "-"})
R:Header({Text = "ล่าสุด"})
local logLbl = R:Label({Text = "-"})

local SS = Tabs.Settings:Section({Side = "Left"})
SS:Keybind({Name = "เปิด/ปิด UI", Blacklist = false, Default = Enum.KeyCode.RightShift,
	Callback = function() pcall(function() Win:SetState(not Win:GetState()) end) end}, "AMSToggleUI")
SS:Header({Text = "กันหลุด"})
SS:Toggle({Name = "Anti-AFK", Default = e.antiAfk, Callback = function(v) e.antiAfk = v; sv() end}, "AMSAntiAfk")
SS:Toggle({Name = "Auto Reconnect (หลุด / โดนเตะ → เข้าเกมใหม่เอง)", Default = e.reconnect, Callback = function(v) e.reconnect = v; sv() end}, "AMSReconnect")
SS:Label({Text = "ตั้งค่าเซฟที่: " .. SF})

task.spawn(function()
	while alive() do
		pcall(function()
			stLbl:UpdateName(table.concat({
				st.status,
				("รับเช่า %d องค์ (จ่าย %s) · ไม่เอา %d (เก๊ %d) · ตรวจเอง %d · ส่งเครื่อง %d · ส่งคืน %d"):format(st.bought, money(st.spent), st.passed,
					st.fakesRejected, st.selfCerts, st.machine, st.handed),
				("เงินร้าน %s · ร้าน %s · ข้อมูลล่าสุด %s"):format(money(S and S.Cash or 0), tostring(S and S.StageName or "-"),
					S and ("%d วิก่อน"):format(math.floor(os.clock() - stateAt)) or "ยังไม่มี"),
				"Watchdog: " .. st.wd,
				"Error: " .. st.err,
			}, "\n"))
			logLbl:UpdateName(#st.log > 0 and table.concat(st.log, "\n") or "-")
		end)
		task.wait(0.5)
	end
end)

task.spawn(function()
	while alive() do task.wait(1) end
	for _, c in ipairs({pushConn, idleConn, errConn}) do pcall(function() c:Disconnect() end) end
	pcall(function() gui:Destroy() end)
end)
pcall(function()
	Win.onUnloaded(function() if getgenv().__AMS == G then getgenv().__AMS = G + 1 end end)
end)
