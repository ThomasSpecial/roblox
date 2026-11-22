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
local DigConfig = require(RS:WaitForChild("DigConfig"))
local UIS = game:GetService("UserInputService")

-- ------------------------------------------------------------------ settings
local SF = ("AmuletStreet/state_%d.json"):format(plr.UserId)
local DEFAULTS = {clerkToBot = true, haggle = true, dig = false, repair = true, woodFallback = true, pauseOnMove = true, counter = false, buyPct = 80, buy = true, selfCert = true, dismiss = true, overlay = true, antiAfk = true, reconnect = true}
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
-- learned[model|variant|proc] = genuine? -- the server's own verdict, kept when it disagreed with the feature rule
-- (user 2026-11-22: a self check said fake, the server said genuine). Saved, so a combination is only ever wrong once.
e.learned = type(e.learned) == "table" and e.learned or {}
local lastSelf   -- {key, said, model, feat, t}
local dbg = {decisions = {}, verdicts = {}, haggles = {}}
getgenv().__AMSDBG = dbg
dbg.e, dbg.st = e, st   -- read-only peek for debugging from the executor
local function specKey(spec)
	local f = spec and spec.Features or {}
	return ("%s|%s|%s"):format(tostring(spec and spec.Model), tostring(f.Variant), tostring(f.Proc))
end
local pushConn = Push.OnClientEvent:Connect(function(kind, data)
	if kind == "state" and type(data) == "table" then S = data; stateAt = os.clock(); return end
	if kind == "verdict" and type(data) == "table" and lastSelf and os.clock() - lastSelf.t < 15 then
		local rec = {key = lastSelf.key, said = lastSelf.said, right = data.Right, genuine = data.Genuine, feat = lastSelf.feat, at = os.date("%H:%M:%S")}
		table.insert(dbg.verdicts, rec)
		if data.Right == false and type(data.Genuine) == "boolean" then
			e.learned[lastSelf.key] = data.Genuine
			sv()
			st.wrong = (st.wrong or 0) + 1
			note(("ตรวจพลาด %s → จำไว้แล้ว ครั้งหน้าตอบ %s"):format(lastSelf.key, data.Genuine and "แท้" or "เก๊"))
		end
		lastSelf = nil
	end
end)

-- fake meshes per model: Check.Fake ids ("G3_F2"); FakeDisabled ones (retired fakes) count as "unsure".
-- Every model also ships a genuine alternate mesh "<Mesh>_F0" that is NOT a fake (user 2026-11-22: V3_F0 was certified
-- as fake by the first rule, server said genuine) -- so only a listed fake id means fake, never "anything but the base mesh".
local FAKE_MESH = {}
for id, m in pairs(Lab.Models) do
	FAKE_MESH[id] = {}
	for _, c in ipairs(m.Checks or {}) do
		if c.Fake then FAKE_MESH[id][c.Fake] = c.FakeDisabled and "retired" or "fake" end
	end
end
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
	local learnedVal = e.learned[specKey(spec)]
	if learnedVal ~= nil then return learnedVal end
	local g = genuineFeatures(spec.Model)
	if not g then return nil end
	local f = spec.Features or {}
	if f.Proc ~= nil then return false end
	local mark = f.Variant ~= nil and FAKE_MESH[spec.Model] and FAKE_MESH[spec.Model][f.Variant]
	if mark == "fake" then return false end
	if mark == "retired" then return nil end
	for k, v in pairs(g) do if k ~= "Variant" and f[k] ~= nil and f[k] ~= v then return false end end
	for k in pairs(f) do if g[k] == nil then return nil end end
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
	if gen == nil then return "pass", nil, "ไม่แน่ใจแท้ / เก๊ → ไม่เอา (ไม่เสี่ยง)" end
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
local sitAtCounter   -- set in the dig section (needs warp / lastMove); returns true when it just sat down
local acted = {}   -- [customerId#i#stage] = clock: sent already, the state push that confirms it is still on its way
local slowDown = 0   -- extra seconds per decision, raised when the server says "slow down", decays again
-- Haggling (Act "haggle" {i, pct}): the game offers ShopConfig.Cases.Haggle (5/10/20 %) off the asking price while
-- Cases.Unlocked; each customer has Patience hearts and a hidden floor (collector 88-95 % of the ask ... scammer 55-70 %).
-- What a refusal costs isn't visible client-side, so the bot keeps the last heart: haggle only while Patience >= 2,
-- biggest cut first on a deal it would take anyway, smallest cut that gets under the cap on one it would pass.
local haggled = {}   -- [customerId .. "#" .. i] = {tried = {pct = true}, done = bool}
local function haggleStep(C, row, gen, ask, cap)
	if not e.haggle or not gen or not ask then return false end
	local cases = S.Cases
	if not (cases and cases.Unlocked) or C.Intent == "cert" or C.Intent == "pickup" then return false end
	local hearts = tonumber(C.Patience)
	if hearts and hearts < 2 then return false end
	local key = tostring(C.Id) .. "#" .. tostring(row.i)
	local h = haggled[key] or {tried = {}}
	haggled[key] = h
	if h.done then return false end
	if not hearts and next(h.tried) then return false end   -- walk-ins show no hearts: one try only
	local cuts = {}
	for _, pct in ipairs(cases.Haggle or {5, 10, 20}) do if not h.tried[pct] then cuts[#cuts + 1] = pct end end
	if #cuts == 0 then return false end
	local pick
	if ask <= cap then
		table.sort(cuts, function(a, b) return a > b end); pick = cuts[1]
	else
		table.sort(cuts)
		for _, pct in ipairs(cuts) do if math.floor(ask * (1 - pct / 100) / 10 + 0.5) * 10 <= cap then pick = pct; break end end
		if not pick then return false end
	end
	h.tried[pick] = true
	local stageKey = row.it.Stage == "post" and "PostAsk" or "Ask"
	st.status = ("ต่อราคาองค์ที่ %s -%d%% (ขอ %s · ความอดทน %s)"):format(tostring(row.i), pick, money(ask), tostring(hearts or "-"))
	local t0 = os.clock()
	while alive() and e.counter and os.clock() - t0 < 0.3 + slowDown do task.wait(0.05) end
	local ok, r1, r2 = pcall(Act.InvokeServer, Act, "haggle", {i = row.i, pct = pick})
	lastAct = os.clock()
	local t1 = os.clock()
	local newAsk, newHearts = ask, hearts or -1
	while alive() and os.clock() - t1 < 3 do
		local C2 = S and S.Customer
		local it2 = C2 and C2.Id == C.Id and C2.Items and C2.Items[row.i]
		if not it2 then break end
		newAsk, newHearts = tonumber(it2[stageKey]) or ask, tonumber(C2.Patience) or -1
		if newAsk ~= ask or newHearts ~= (hearts or -1) then break end
		task.wait(0.1)
	end
	local won = newAsk < ask
	if won then h.done = true end
	st.haggles = (st.haggles or 0) + 1
	if won then st.haggleWon = (st.haggleWon or 0) + 1; st.saved = (st.saved or 0) + (ask - newAsk) end
	table.insert(dbg.haggles, {at = os.date("%H:%M:%S"), pct = pick, ask = ask, newAsk = newAsk, hearts = hearts, newHearts = newHearts, ok = ok and r1, msg = ok and r2 or r1})
	note(won and ("ต่อราคา -%d%% สำเร็จ: %s → %s"):format(pick, money(ask), money(newAsk))
		or ("ต่อราคา -%d%% ไม่ยอม (ความอดทน %s → %s)%s"):format(pick, tostring(hearts or "-"), tostring(newHearts), (ok and r2) and (" · " .. tostring(r2)) or ""))
	return true
end
local function counterStep()
	if next(acted) and math.random() < 0.02 then for k, t in pairs(acted) do if os.clock() - t > 30 then acted[k] = nil end end end
	if not S then st.status = "รอข้อมูลร้านจากเกม (เกมส่งมาเมื่อมีลูกค้า / ของเปลี่ยน)"; return end
	local C = S.Customer
	if not C or not C.Id then st.status = "รอลูกค้าที่เคาน์เตอร์"; doneSince = nil; return end
	if plr:GetAttribute("CounterSeated") ~= true then
		if not e.dig and sitAtCounter and sitAtCounter() then st.status = "ลูกค้ารออยู่ → วาร์ปกลับไปนั่งเคาน์เตอร์"; return end
		st.status = e.dig and "อยู่โหมดขุด → ลูกน้องหน้าร้านรับลูกค้าแทน" or "ลูกค้ารออยู่ แต่ยังไม่ได้นั่งที่เคาน์เตอร์ (คุณกำลังเดินเอง)"
		return
	end
	local open = 0
	for _, row in ipairs(itemsOf(C)) do
		local it = row.it
		if it.Stage ~= "done" then open += 1 end
		local actKey = ("%s#%s#%s"):format(tostring(C.Id), tostring(row.i), tostring(it.Stage))
		if acted[actKey] and os.clock() - acted[actKey] < 4 then continue end
		local action, extra, why = decide(C, it)
		if (action == "buy" or action == "buyPost" or action == "pass") and it.Stage ~= "return" then
			local gen = isGenuine(it.Spec)
			local ask = tonumber(it.Stage == "post" and it.PostAsk or it.Ask)
			local cap = math.min(marketValue(it) * (tonumber(e.buyPct) or 80) / 100, tonumber(S.Cash) or 0)
			if haggleStep(C, row, gen, ask, cap) then return end
		end
		if action then
			-- short look per item (user 2026-11-22: "ช้าจัด"); the server answers "slow down" when pushed too hard -> slowDown
			local dt = 0.15 + math.random() * 0.15 + slowDown
			st.status = ("ลูกค้า%s · องค์ที่ %s %s: %s"):format(C.Intent == "pickup" and "มารับคืน" or "", tostring(row.i), short(modelName(it.Model), 22), why)
			local t0 = os.clock()
			while alive() and e.counter and os.clock() - t0 < dt do task.wait(0.1) end
			if not alive() or not e.counter then return end
			-- the state may have moved on while we "looked" (you clicked it yourself, the clerk took it, the customer left)
			local C2 = S and S.Customer
			local it2 = C2 and C2.Id == C.Id and C2.Items and C2.Items[row.i]
			if not it2 or it2.Stage ~= it.Stage then return end
			local args = {i = row.i, dt = os.clock() - t0 + 0.6}
			for k, v in pairs(extra or {}) do args[k] = v end
			if action == "self" then
				lastSelf = {key = specKey(it.Spec), said = args.v, t = os.clock(), feat = HS:JSONEncode(it.Spec.Features or {})}
			end
			table.insert(dbg.decisions, {at = os.date("%H:%M:%S"), action = action, key = specKey(it.Spec), v = args.v, feat = HS:JSONEncode(it.Spec.Features or {})})
			if #dbg.decisions > 60 then table.remove(dbg.decisions, 1) end
			local ok, r1, r2 = pcall(Act.InvokeServer, Act, action, args)
			lastAct = os.clock()
			if ok and r1 then acted[actKey] = os.clock() end
			if ok and r1 then
				if action == "buy" or action == "buyPost" then
					st.bought += 1; st.spent += tonumber(action == "buy" and it.Ask or it.PostAsk) or 0
				elseif action == "pass" then
					st.passed += 1; if isGenuine(it.Spec) == false then st.fakesRejected += 1 end
				elseif action == "self" then st.selfCerts += 1
				elseif action == "machine" then st.machine += 1
				elseif action == "handBack" then st.handed += 1 end
				note(("#%s %s · %s"):format(tostring(row.i), short(modelName(it.Model), 18), why))
				slowDown = math.max(0, slowDown - 0.05)
			else
				if tostring(ok and r2 or r1) == "slow down" then slowDown = math.min(2, slowDown + 0.3) end
				note(("#%s %s ไม่ผ่าน: %s"):format(tostring(row.i), action, tostring(ok and r2 or r1)))
				if action == "self" then selfFailed[it.Model] = true end   -- next pass sends it to the machine instead
				task.wait(1)
			end
			continue   -- straight on to the next piece; `acted` keeps this one from being sent twice before the push lands
		end
	end
	if open == 0 and e.dismiss then
		if doneFor ~= C.Id then doneFor, doneSince = C.Id, os.clock() end
		if os.clock() - doneSince > 2 and os.clock() - lastAct > 1 then
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

-- Clerk (staff "clerk") sorts the tray BY EYE and, with Policy.normal = "auto", rents/certifies ordinary pieces itself --
-- that is where fakes kept getting bought (user 2026-11-22: "ยังซื้อพระปลอม"; Stats.FakesBought never rose from the
-- bot's own buys). While the bot sits at the counter the clerk passes every piece to the owner (normal + sell = "owner");
-- when the bot leaves (Auto Dig / Auto Counter off) the user's own settings come back. Act("clerkPolicy", {Pile, Mode}),
-- spaced out -- two calls back to back get "slow down".
local CLERK_PILES = {"normal", "sell"}
local lastPolicyCall = 0
local function clerkJob()
	local pol = S and S.Clerk and S.Clerk.Policy
	if not pol or os.clock() - lastPolicyCall < 2 then return end
	local want
	if e.clerkToBot and e.counter and not e.dig then
		want = {normal = "owner", sell = "owner"}
		if not e.clerkSaved then
			e.clerkSaved = {normal = pol.normal or "auto", sell = pol.sell or "pile"}
			if e.clerkSaved.normal == "owner" then e.clerkSaved.normal = "auto" end
			if e.clerkSaved.sell == "owner" then e.clerkSaved.sell = "pile" end
			sv()
		end
	elseif e.clerkSaved then
		want = e.clerkSaved
	else
		return
	end
	for _, pile in ipairs(CLERK_PILES) do
		if want[pile] and pol[pile] ~= want[pile] then
			lastPolicyCall = os.clock()
			local ok, r1, r2 = pcall(Act.InvokeServer, Act, "clerkPolicy", {Pile = pile, Mode = want[pile]})
			if ok and r1 then
				note(("ลูกน้องหน้าร้าน: %s → %s"):format(pile == "normal" and "พระธรรมดา" or "ลูกค้ามาขาย", want[pile] == "owner" and "ส่งให้บอทดูทุกองค์" or "คืนค่าเดิมของคุณ"))
			end
			return
		end
	end
	if want == e.clerkSaved then e.clerkSaved = nil; sv() end
end
task.spawn(function()
	while alive() do
		pcall(clerkJob)
		task.wait(0.5)
	end
end)

task.spawn(function()
	while alive() do
		if e.counter then
			local ok, err = pcall(counterStep)
			if not ok then st.err = os.date("%H:%M:%S ") .. tostring(err) end
		else
			st.status = "Auto Counter ปิดอยู่"
		end
		task.wait(0.1)
	end
end)

-- ------------------------------------------------------------------ auto dig + shovel repair
-- Digging is a ProximityPrompt (Mound > DigPrompt, HoldDuration = shovel DigTime) that has to be HELD: InputHoldBegin,
-- wait, InputHoldEnd -> the server rolls the find and pushes "digChest" (finds go to the safe by themselves), Dur - 1.
-- fireproximityprompt does not count. Repair = Act("digRepair", shovelKey) within ~10 studs of DigUncle (server refuses
-- from afar), price prorated by wear. User 2026-11-22: warping OK, dig nonstop (the clerk serves customers meanwhile).
local FIELD_MIN, FIELD_MAX = DigConfig.Field.Min, DigConfig.Field.Max
local UNCLE_AT = DigConfig.Uncle.Position
local function hum() local c = plr.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function hrp() local c = plr.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local lastMove = 0
local MOVE_KEYS = {}
for _, k in ipairs({"W", "A", "S", "D", "Up", "Down", "Left", "Right", "Space"}) do MOVE_KEYS[Enum.KeyCode[k]] = true end
task.spawn(function()
	while alive() do
		if not UIS:GetFocusedTextBox() then
			for k in pairs(MOVE_KEYS) do if UIS:IsKeyDown(k) then lastMove = os.clock() break end end
		end
		task.wait(0.1)
	end
end)
local function standUp()
	local h = hum()
	if h and h.Sit then h.Sit = false; h.Jump = true; task.wait(0.5) end
end
local function warp(pos, lookAt)
	local r = hrp()
	if not r then return false end
	r.AssemblyLinearVelocity = Vector3.zero
	r.CFrame = lookAt and CFrame.lookAt(pos, Vector3.new(lookAt.X, pos.Y, lookAt.Z)) or CFrame.new(pos)
	return true
end
local function inField(pos)
	return pos.X >= FIELD_MIN.X - 2 and pos.X <= FIELD_MAX.X + 2 and pos.Z >= FIELD_MIN.Z - 2 and pos.Z <= FIELD_MAX.Z + 2 and pos.Y > -3 and pos.Y < 8
end
local function nearestMound()
	local r = hrp()
	local f = workspace:FindFirstChild("DigMounds")
	if not r or not f then return nil end
	local best, bd
	for _, m in ipairs(f:GetChildren()) do
		local p = m:FindFirstChild("DigPrompt", true)
		local ok, pos = pcall(function() return m:GetPivot().Position end)
		if ok and p and p.Enabled and inField(pos) then
			local d = (pos - r.Position).Magnitude
			if not bd or d < bd then best, bd = m, d end
		end
	end
	return best
end
local function shovel()
	local d = S and S.Dig or {}
	local key = d.Equip or "wood"
	local cfg = DigConfig.ByKey[key] or {}
	local dur = d.Dur and d.Dur[key]
	return key, cfg, tonumber(dur), d
end
local function repairCost(key, dur)
	local cfg = DigConfig.ByKey[key]
	if not cfg or not cfg.Dur or not cfg.Repair or cfg.Repair <= 0 then return 0 end
	return math.ceil(cfg.Repair * (1 - math.clamp((dur or 0) / cfg.Dur, 0, 1)) / 10) * 10
end
local function atUncle(action, arg)
	standUp()
	warp(UNCLE_AT + Vector3.new(-5, 3, 0), UNCLE_AT)
	task.wait(0.6)
	local ok, r1, r2 = pcall(Act.InvokeServer, Act, action, arg)
	return ok and r1 == true, ok and r2 or r1
end
local repairWait = 0
local function shovelJob()
	local key, cfg, dur, d = shovel()
	-- back from the wooden stand-in once the real shovel can be paid for
	if key == "wood" and e.mainShovel and e.mainShovel ~= "wood" and d.Own and d.Own[e.mainShovel] and os.clock() > repairWait then
		local mdur = d.Dur and tonumber(d.Dur[e.mainShovel]) or 0
		local cost = repairCost(e.mainShovel, mdur)
		if (tonumber(S.Cash) or 0) >= cost then
			if cost > 0 then
				local ok, msg = atUncle("digRepair", e.mainShovel)
				if not ok then repairWait = os.clock() + 60; st.dig = "ซ่อม " .. e.mainShovel .. " ไม่ผ่าน: " .. tostring(msg); return true end
				st.repairs = (st.repairs or 0) + 1
			end
			local ok, msg = atUncle("digEquip", e.mainShovel)
			note(ok and ("ซ่อม + ใส่%s คืนแล้ว (%s)"):format(DigConfig.ByKey[e.mainShovel].Name, money(cost)) or ("ใส่พลั่วคืนไม่ผ่าน: " .. tostring(msg)))
			if ok then e.mainShovel = nil; sv() else repairWait = os.clock() + 60 end
			return true
		end
	end
	if not dur or dur < 0 or dur > 0 then return false end   -- wood = -1 (never wears), or still has uses
	if not e.repair then st.dig = "พลั่วพัง (ปิดซ่อมอัตโนมัติไว้)"; return true end
	if os.clock() < repairWait then st.dig = ("พลั่วพัง · ซ่อมไม่ผ่าน รอลองใหม่ %d วิ"):format(math.ceil(repairWait - os.clock())); return true end
	local cost = repairCost(key, dur)
	st.dig = ("%s พัง → ไปหาลุงซ่อม (%s)"):format(tostring(cfg.Name or key), money(cost))
	if (tonumber(S.Cash) or 0) >= cost then
		local ok, msg = atUncle("digRepair", key)
		if ok then
			st.repairs = (st.repairs or 0) + 1
			note(("ซ่อม%s แล้ว (%s)"):format(tostring(cfg.Name or key), money(cost)))
			return true
		end
		st.dig = "ซ่อมไม่ผ่าน: " .. tostring(msg)
	else
		st.dig = ("พลั่วพัง · เงินไม่พอซ่อม (ต้องใช้ %s)"):format(money(cost))
	end
	if e.woodFallback and d.Own and d.Own.wood then
		local ok = atUncle("digEquip", "wood")
		if ok then
			e.mainShovel = key; sv()
			note("เงินไม่พอซ่อม → ใช้พลั่วไม้ขุดไปก่อน (ไม่มีวันพัง) เงินพอแล้วจะกลับมาซ่อม")
			return true
		end
	end
	repairWait = os.clock() + 60
	return true
end
local lastSitTry = 0
function sitAtCounter()
	if os.clock() - lastMove < 3 or os.clock() - lastSitTry < 4 then return false end
	lastSitTry = os.clock()
	local plot = workspace.Plots:FindFirstChild("Plot" .. tostring(plr:GetAttribute("Plot")))
	local chair = plot and plot:FindFirstChild("ShopScene") and plot.ShopScene:FindFirstChild("Counter") and plot.ShopScene.Counter:FindFirstChild("Chair")
	local seat = chair and chair:FindFirstChild("Seat")
	local sp = seat and seat:FindFirstChild("SitPrompt")
	if not sp then return false end
	standUp()
	warp(seat.Position + Vector3.new(0, 3, 0))
	task.wait(0.3)
	pcall(fireproximityprompt, sp, 1, true)
	local t0 = os.clock()
	while os.clock() - t0 < 2 and plr:GetAttribute("CounterSeated") ~= true do task.wait(0.1) end
	return true
end
local digSeat   -- true while dig mode moved us off the chair
local function digStep()
	local h, r = hum(), hrp()
	if not h or not r or h.Health <= 0 then st.dig = "รอตัวละครเกิด"; return end
	if e.pauseOnMove and os.clock() - lastMove < 3 then st.dig = "พัก: คุณกำลังเดินเอง"; return end
	if not S or not S.Dig then st.dig = "รอข้อมูลร้านจากเกม"; return end
	if shovelJob() then return end
	local m = nearestMound()
	if not m then
		standUp()
		if not inField(r.Position) then warp(Vector3.new((FIELD_MIN.X + FIELD_MAX.X) / 2, 4, (FIELD_MIN.Z + FIELD_MAX.Z) / 2)) end
		st.dig = "ไม่มีเนินดินในลาน รอเกิด (ต้นชั่วโมงเกิดเยอะ)"
		task.wait(1)
		return
	end
	standUp()
	digSeat = true
	local mp = m:GetPivot().Position
	local away = (r.Position - mp) * Vector3.new(1, 0, 1)
	away = away.Magnitude > 0.5 and away.Unit or Vector3.new(1, 0, 0)
	local stand = mp + away * 3.5
	if (r.Position - stand).Magnitude > 2 then warp(Vector3.new(stand.X, mp.Y + 3, stand.Z), mp); task.wait(0.15) end
	local p = m:FindFirstChild("DigPrompt", true)
	if not p or not p.Enabled then return end
	local key, cfg, dur = shovel()
	local digs0 = S.Dig.Stats and S.Dig.Stats.Digs or 0
	st.dig = ("ขุดเนินดิน · %s %s"):format(tostring(cfg.Name or key), dur and dur >= 0 and ("(เหลือ %d/%d)"):format(dur, cfg.Dur or 0) or "")
	local ok = pcall(function()
		p:InputHoldBegin()
		local t0 = os.clock()
		while alive() and e.dig and os.clock() - t0 < p.HoldDuration + 0.1 do task.wait(0.03) end
		p:InputHoldEnd()
	end)
	local t1 = os.clock()
	while alive() and os.clock() - t1 < 1.5 and (S.Dig.Stats and S.Dig.Stats.Digs or 0) == digs0 do task.wait(0.05) end
	if ok and (S.Dig.Stats and S.Dig.Stats.Digs or 0) > digs0 then st.digs = (st.digs or 0) + 1 end
end
local digFound = {}
local digConn = Push.OnClientEvent:Connect(function(kind, data)
	if kind == "digChest" and type(data) == "table" and e.dig then
		local what = data.Kind == "broken" and "เศษพระชำรุด" or data.Kind == "dirt" and "พระดินชาวบ้าน" or tostring(data.Name or "?")
		table.insert(digFound, 1, os.date("%H:%M ") .. short(what, 26) .. (data.Raw and (" · สภาพ " .. tostring(data.Condition)) or ""))
		if #digFound > 5 then table.remove(digFound) end
	end
end)
task.spawn(function()
	while alive() do
		if e.dig then
			local ok, err = pcall(digStep)
			if not ok then st.err = os.date("%H:%M:%S ") .. tostring(err) end
		elseif digSeat then
			-- dig switched off: go back and sit at the counter so Auto Counter can work again
			digSeat = nil
			lastSitTry = 0
			pcall(sitAtCounter)
			st.dig = "ปิดอยู่ (กลับไปนั่งเคาน์เตอร์แล้ว)"
		else
			st.dig = "ปิดอยู่"
		end
		task.wait(0.15)
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
L:Toggle({Name = "ให้ลูกน้องหน้าร้านส่งทุกองค์ให้บอทดู (ลูกน้องดูด้วยตา ซื้อของปลอมได้)", Default = e.clerkToBot, Callback = function(v) e.clerkToBot = v; sv() end}, "AMSClerk")
L:Toggle({Name = "ต่อราคาก่อนรับเช่า (เก็บความอดทนลูกค้าไว้ 1 ดวงเสมอ)", Default = e.haggle, Callback = function(v) e.haggle = v; sv() end}, "AMSHaggle")
L:Toggle({Name = "ตรวจเองเมื่อมีสมุดรุ่นนั้น (ได้ค่าตรวจเต็ม แทนส่งเครื่องเสีย 70%)", Default = e.selfCert, Callback = function(v) e.selfCert = v; sv() end}, "AMSSelf")
L:Toggle({Name = "ส่งลูกค้ากลับเมื่อทุกองค์เสร็จแล้ว", Default = e.dismiss, Callback = function(v) e.dismiss = v; sv() end}, "AMSDismiss")
L:Header({Text = "ตัวช่วยดู"})
L:Toggle({Name = "ป้ายบอก แท้ / เก๊ + ราคาตลาด บนจอ", Default = e.overlay, Callback = function(v) e.overlay = v; sv() end}, "AMSOverlay")

L:Header({Text = "ขุดพระ"})
L:Toggle({Name = "Auto Dig (วาร์ปไปลานขุด ขุดเนินดินไม่หยุด)", Default = e.dig, Callback = function(v) e.dig = v; sv() end}, "AMSDig")
L:Toggle({Name = "└ พลั่วพัง → วาร์ปไปหาลุงซ่อมให้", Default = e.repair, Callback = function(v) e.repair = v; sv() end}, "AMSRepair")
L:Toggle({Name = "└ เงินไม่พอซ่อม → ใช้พลั่วไม้ขุดไปก่อน", Default = e.woodFallback, Callback = function(v) e.woodFallback = v; sv() end}, "AMSWood")
L:Toggle({Name = "หยุดบอทขุดตอนฉันกดเดินเอง", Default = e.pauseOnMove, Callback = function(v) e.pauseOnMove = v; sv() end}, "AMSPause")
L:Label({Text = "ระหว่างขุด ลูกน้องหน้าร้านรับลูกค้าแทน · ของที่ขุดได้เข้าตู้เซฟเอง\nปิด Auto Dig → วาร์ปกลับไปนั่งเคาน์เตอร์ให้"})

local R = Tabs.Main:Section({Side = "Right"})
R:Header({Text = "สถานะ"})
local stLbl = R:Label({Text = "-"})
R:Header({Text = "ขุดพระ"})
local digLbl = R:Label({Text = "-"})
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
				("ต่อราคา %d ครั้ง สำเร็จ %d (ประหยัด %s)\n"):format(st.haggles or 0, st.haggleWon or 0, money(st.saved or 0)) .. ("รับเช่า %d องค์ (จ่าย %s) · ไม่เอา %d (เก๊ %d) · ตรวจเอง %d (พลาด %d) · ส่งเครื่อง %d · ส่งคืน %d"):format(st.bought, money(st.spent), st.passed,
					st.fakesRejected, st.selfCerts, st.wrong or 0, st.machine, st.handed),
				("เงินร้าน %s · ร้าน %s · ข้อมูลล่าสุด %s"):format(money(S and S.Cash or 0), tostring(S and S.StageName or "-"),
					S and ("%d วิก่อน"):format(math.floor(os.clock() - stateAt)) or "ยังไม่มี"),
				"Watchdog: " .. st.wd,
				"Error: " .. st.err,
			}, "\n"))
			logLbl:UpdateName(#st.log > 0 and table.concat(st.log, "\n") or "-")
			local key, cfg, dur, d = shovel()
			digLbl:UpdateName(table.concat({
				tostring(st.dig or "-"),
				("ขุดรอบนี้ %d · ซ่อม %d ครั้ง · %s %s · ขุดทั้งหมด %s"):format(st.digs or 0, st.repairs or 0, tostring(cfg.Name or key),
					dur and dur >= 0 and ("%d/%d"):format(dur, cfg.Dur or 0) or "ไม่พัง", tostring(d.Stats and d.Stats.Digs or "-")),
				#digFound > 0 and ("เจอล่าสุด: " .. table.concat(digFound, " · ")) or "เจอล่าสุด: -",
			}, "\n"))
		end)
		task.wait(0.5)
	end
end)

task.spawn(function()
	while alive() do task.wait(1) end
	for _, c in ipairs({pushConn, digConn, idleConn, errConn}) do pcall(function() c:Disconnect() end) end
	pcall(function() gui:Destroy() end)
end)
pcall(function()
	Win.onUnloaded(function() if getgenv().__AMS == G then getgenv().__AMS = G + 1 end end)
end)
