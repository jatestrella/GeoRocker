-- rockmech/crusher.lua
-- 破碎站（賣礦）：放在平地上，朝玩家的方向挖一個受料倉：9×9 m、深 4 m 的階梯漏斗，壁坡 45° 比安息角陡，
-- 碎石不會留在壁上。底部 3×3 m 是格柵（給料口），只從這裡吃料，上方的料靠碎石流動自己補進來。
-- 卡車、挖土機、推土機倒進來都一樣；每秒最多 rockmech_crusher_rate 噸，倒太快就在倉裡排隊。
-- 過磅入帳：收入 = 噸數 ×（品位 × 回收率 × 價格 − 處理費），見 config.crush_income。廢石的品位是 0，
-- 運來破碎只會賠處理費，這就是貧化與截止品位。錢記在放置破碎站的玩家的帳戶（分了組就是整組，見 team.lua）。
-- 礦價每個交易日（rockmech_price_period 秒）浮動一次：rockmech.ore_price。
-- 右鍵可以切換成廢石場：倒進來的碎石直接棄置，不收入，每噸付 rockmech_dump_fee（預設 0）。
-- 受料倉、格柵、強制載入給選礦場（plant.lua）共用：rockmech.hopper_lib

local cfg = rockmech.cfg
local V = rockmech.vehicles
local storage = rockmech.collapse.storage

local CRUSHER, GRATE = "rockmech:crusher", "rockmech:crusher_grate"
local PLANT = "rockmech:plant"     -- 選礦場（plant.lua），同一種受料倉
local CRUSHER_BIG = "rockmech:crusher_big"   -- 大型破碎站：同一種受料倉，處理能力 rockmech_crusher_big_rate
local CRUSHERS = {[CRUSHER] = true, [CRUSHER_BIG] = true}
local HOPPER_BODY = {[CRUSHER] = true, [CRUSHER_BIG] = true, [PLANT] = true}
-- 處理能力：一般／大型，乘上「破碎機改良」研究
local function rate_of(pos)
	return (core.get_node(pos).name == CRUSHER_BIG and cfg.crusher_big_rate or cfg.crusher_rate)
		* rockmech.eff_crusher_mult(core.get_meta(pos):get_string("owner"))
end
local function title_of(pos) return core.get_node(pos).name == CRUSHER_BIG and "大型破碎站" or "破碎站" end
local SIZE, FEEDER = 9, 3    -- 受料倉開口、底部格柵的邊長 (m)
local DEPTH = (SIZE - FEEDER) / 2 + 1              -- 倉深 (m)：每往下一層四邊各內縮 1 m（壁坡 45°），最底層就是格柵的大小
local CAPACITY = 0          -- 容量（級），裝到倉口
for dy = 0, DEPTH - 1 do CAPACITY = CAPACITY + (SIZE - 2 * dy) ^ 2 * rockmech.vehicles.NLEV end
local PILE = 8              -- 格柵上往上找幾格碎石
local FIND_R = 15           -- 傾倒點離格柵中心多近（水平距離）算在破碎站
rockmech.HOPPER_RANGE = FIND_R
rockmech.HOPPER_HALF = SIZE / 2   -- 倉口中心到邊 (m)
local STEP = 1              -- 每幾秒吃一次
local MONEY = "money:"      -- mod storage 的鍵
local COIN_LEAD = 0.4       -- 金幣聲響完多久才出結算訊息 (s)

---------------------------------------------------------------------------
-- 礦價：每個交易日開盤換一次。交易日用遊戲實際經過的時間算（rockmech_price_period 秒，預設 20 分鐘 = 預設的遊戲一天），
-- 不看天色時鐘：time_speed = 0（時間停住、一直白天）時照樣會開盤。
-- 價格 = 基準價（config.ores 的 price）× 倍率；倍率的對數走均值回歸的隨機漫步（Ornstein–Uhlenbeck）：
--   x ← x − θ·x + σ·N(0, 1)，θ = rockmech_price_revert、σ = rockmech_price_vol，
-- 再夾在 rockmech_price_min ～ rockmech_price_max 倍之間。偏離基準越多拉回越大，不會一路漲上天或跌到零
---------------------------------------------------------------------------

local PRICE, PRICE_PREV, PRICE_DAY = "price:", "price_prev:", "price_day"

local function factor(ore) return storage:contains(PRICE .. ore.key) and storage:get_float(PRICE .. ore.key) or 1 end
-- 現在的價格（每噸、品位 100%）
function rockmech.ore_price(ore) return ore.price * factor(ore) end
-- 跟上一個交易日比漲跌（比例）
local function price_change(ore)
	local prev = storage:contains(PRICE_PREV .. ore.key) and storage:get_float(PRICE_PREV .. ore.key) or 1
	return factor(ore) / prev - 1
end
local function main_ore()
	for _, ore in pairs(cfg.ores) do return ore end
end
local function price_text(ore)
	local c = price_change(ore)
	return ("%s價 $%.0f/t（%s %.0f%%）"):format(ore.label, rockmech.ore_price(ore), c >= 0 and "▲" or "▼", math.abs(c) * 100)
end
local function gauss()
	return math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
end
-- 現在是第幾個交易日（世界開始後經過的遊戲時間 ÷ 交易日長度）
local function market_day()
	return math.floor(core.get_gametime() / cfg.price_period)
end
rockmech.market_day = market_day

---------------------------------------------------------------------------
-- 資金
---------------------------------------------------------------------------

-- 帳戶：分了組的玩家（team.lua，mod storage 的 team_of:<玩家>）用整組共用的帳戶 "team:<組>"，
-- 沒分組就是玩家自己的帳戶（單人模式的 singleplayer）。玩家名稱不能有冒號，"team:1" 不會撞到玩家
local TEAM_OF = "team_of:"
function rockmech.team_of(name)
	local t = storage:get_string(TEAM_OF .. name)
	return t ~= "" and t or nil
end
function rockmech.account_of(name)
	if name:find(":", 1, true) then return name end
	local t = rockmech.team_of(name)
	return t and ("team:" .. t) or name
end
function rockmech.account_label(acc)
	if acc == "camp:spawn" then return "出生點公用" end     -- 第一個進世界的人已分組時，出生點營地的帳戶（career.lua）
	local t = acc:match("^team:(.+)$")
	if t == "0" then return "老師組" end
	return t and ("第 " .. t .. " 組") or acc
end
-- 帳戶在線上的成員
function rockmech.account_members(acc)
	local out = {}
	for _, p in ipairs(core.get_connected_players()) do
		if rockmech.account_of(p:get_player_name()) == acc then out[#out + 1] = p:get_player_name() end
	end
	return out
end

-- 設施（破碎站、選礦場）的主人是不是這個玩家（自己的帳戶、自己的組，或老師）；不是就告訴他
function rockmech.owner_ok(owner, name)
	if owner == "" or owner == name or owner == rockmech.account_of(name) then return true end
	if core.check_player_privs(name, {server = true}) then return true end
	core.chat_send_player(name, ("這是%s的設施，別組不能動"):format(rockmech.account_label(owner)))
	return false
end

-- 研究等級（research.lua）：mod storage 的 research:<帳戶>:<項目>，查詢有快取。owner：玩家名稱或帳戶
local research_cache = {}
function rockmech.research_level(owner, key)
	if not owner or owner == "" then return 0 end
	local acc = rockmech.account_of(owner)
	local c = research_cache[acc]
	if not c then c = {}; research_cache[acc] = c end
	local v = c[key]
	if v == nil then v = storage:get_int("research:" .. acc .. ":" .. key); c[key] = v end
	return v
end
function rockmech.research_set(acc, key, lv)
	storage:set_int("research:" .. acc .. ":" .. key, lv)
	research_cache[acc] = nil
end
-- 研究後的係數（每級的效果在這裡；research.lua 的項目表要跟這裡一致）
function rockmech.eff_plant_recovery(owner) return math.min(1, cfg.plant_recovery + 0.01 * rockmech.research_level(owner, "plant_recovery")) end
function rockmech.eff_plant_misplaced(owner) return math.max(0, cfg.plant_misplaced - 0.02 * rockmech.research_level(owner, "plant_misplaced")) end
function rockmech.eff_crusher_mult(owner) return 1 + 0.1 * rockmech.research_level(owner, "crusher_rate") end
function rockmech.eff_conveyor_mult(owner) return 1 + 0.1 * rockmech.research_level(owner, "conveyor_rate") end
function rockmech.eff_ore_recovery(owner, ore) return math.min(1, ore.recovery + 0.01 * rockmech.research_level(owner, "ore_recovery")) end

local money_hud = {}        -- 玩家名稱 → HUD id

-- 右上角的資金；帳戶還沒開（沒有資金紀錄）就收起來
local function show_money(player)
	local name = player:get_player_name()
	local acc = rockmech.account_of(name)
	if not storage:contains(MONEY .. acc) then
		if money_hud[name] then player:hud_change(money_hud[name], "text", "") end
		return
	end
	local ore = main_ore()
	local m = storage:get_float(MONEY .. acc)
	local team = rockmech.team_of(name)
	local text = ("%s資金 %s$%.0f"):format(team and ("第 " .. team .. " 組　") or "", m < 0 and "−" or "", math.abs(m))
		.. (ore and ("\n" .. price_text(ore)) or "")
	if money_hud[name] then
		player:hud_change(money_hud[name], "text", text)
	else
		money_hud[name] = player:hud_add({type = "text", position = {x = 0.98, y = 0.06}, alignment = {x = -1, y = 1},
			number = 0xFFE080, text = text, z_index = 100})
	end
end
rockmech.show_money = show_money

-- name：玩家名稱或帳戶（"team:A"）
function rockmech.has_account(name) return storage:contains(MONEY .. rockmech.account_of(name)) end
function rockmech.money(name) return storage:get_float(MONEY .. rockmech.account_of(name)) end
function rockmech.add_money(name, amount)
	local acc = rockmech.account_of(name)
	storage:set_float(MONEY .. acc, storage:get_float(MONEY .. acc) + amount)
	for _, n in ipairs(rockmech.account_members(acc)) do
		local p = core.get_player_by_name(n)
		if p then show_money(p) end
	end
end

core.register_on_joinplayer(function(player)
	if rockmech.has_account(player:get_player_name()) then show_money(player) end
end)
core.register_on_leaveplayer(function(player) money_hud[player:get_player_name()] = nil end)

-- 開盤：過了幾個交易日就走幾步（最多 30 步，離開很久回來不必一天一天算），換完通知所有人、更新右上角
local function open_market()
	local today = market_day()
	if not storage:contains(PRICE_DAY) then storage:set_int(PRICE_DAY, today); return end
	local days = today - storage:get_int(PRICE_DAY)
	if days <= 0 then return end
	storage:set_int(PRICE_DAY, today)
	local lo, hi = math.log(cfg.price_min), math.log(cfg.price_max)
	for _, ore in pairs(cfg.ores) do
		local f = factor(ore)
		storage:set_float(PRICE_PREV .. ore.key, f)
		local x = math.log(f)
		for _ = 1, math.min(days, 30) do
			x = math.max(lo, math.min(hi, x - cfg.price_revert * x + cfg.price_vol * gauss()))
		end
		storage:set_float(PRICE .. ore.key, math.exp(x))
		local prev = ore.price * storage:get_float(PRICE_PREV .. ore.key)
		core.chat_send_all(("[市場] 今日%s價 $%.0f/t（昨日 $%.0f，%s %.0f%%）"):format(ore.label, rockmech.ore_price(ore), prev,
			price_change(ore) >= 0 and "▲" or "▼", math.abs(price_change(ore)) * 100))
	end
	for _, player in ipairs(core.get_connected_players()) do
		if money_hud[player:get_player_name()] then show_money(player) end
	end
end
local market_t = 0
core.register_globalstep(function(dtime)
	market_t = market_t + dtime
	if market_t < 5 then return end
	market_t = 0
	open_market()
end)

-- pos 在破碎站的容許範圍內就回傳格柵的中心，否則 nil。給 search 就改找這個距離內最近的破碎站，不管容許範圍
function rockmech.grate_center(pos, search)
	local g = core.find_node_near(pos, search or FIND_R + FEEDER, GRATE)
	if not g then return nil end
	local x, y, z = g.x, g.y, g.z
	local function span(dx, dz)
		local k = 0
		while core.get_node({x = x + dx * (k + 1), y = y, z = z + dz * (k + 1)}).name == GRATE do k = k + 1 end
		return k
	end
	local c = {x = x + (span(1, 0) - span(-1, 0)) / 2, y = y, z = z + (span(0, 1) - span(0, -1)) / 2}
	if not search and (pos.x - c.x) ^ 2 + (pos.z - c.z) ^ 2 > FIND_R ^ 2 then return nil end
	return c
end

---------------------------------------------------------------------------
-- 破碎
---------------------------------------------------------------------------

local function grate_cells(meta)
	local x0, y, z0 = meta:get_int("gx"), meta:get_int("gy"), meta:get_int("gz")
	local cells = {}
	for x = x0, x0 + FEEDER - 1 do for z = z0, z0 + FEEDER - 1 do
		cells[#cells + 1] = {x = x, y = y, z = z}
	end end
	return cells
end

-- 格柵這一格上方最高的碎石
local function top_rubble(c)
	if core.get_node(c).name ~= GRATE then return nil end
	for y = c.y + PILE, c.y + 1, -1 do
		local p = {x = c.x, y = y, z = c.z}
		if rockmech.rubble_level[core.get_node(p).name] then return p end
	end
end

-- 受料倉裡的碎石（級）。c：格柵中心
local function hopper_levels(c)
	local r = (SIZE - 1) / 2
	local n = 0
	for x = c.x - r, c.x + r do for z = c.z - r, c.z + r do for y = c.y + 1, c.y + PILE do
		n = n + (rockmech.rubble_level[core.get_node({x = x, y = y, z = z}).name] or 0)
	end end end
	return n
end
-- 受料倉還放得下幾級（無人駕駛用來判斷要不要等）
function rockmech.hopper_room(c) return CAPACITY - hopper_levels(c) end

-- 倉裡的碎石往給料口流：每次掃整個倉，每欄走一步。只叫給料口旁邊的格子的話，外圈階梯上的料不會動
local function drain(c)
	local r = (SIZE - 1) / 2
	for x = c.x - r, c.x + r do for z = c.z - r, c.z + r do
		for y = c.y + PILE, c.y + 1, -1 do
			local q = {x = x, y = y, z = z}
			if rockmech.rubble_level[core.get_node(q).name] then
				rockmech.collapse.granular_settle(q, 1)
				break
			end
		end
	end end
end

local function hopper_center(meta)
	return {x = meta:get_int("gx") + (FEEDER - 1) / 2, y = meta:get_int("gy"), z = meta:get_int("gz") + (FEEDER - 1) / 2}
end

-- 每級碎石的噸數：1/8 m³，密度用 γ/10
-- 計價用：1/8 m³ 一級，密度 rockmech_rubble_density（t/m³，預設 2.5）。只管錢和顯示的噸數，車輛載重的物理照舊
local function tons_of(levels) return levels / V.NLEV * cfg.rubble_density end

-- 從格柵吃料：這一步最多 rate (t/s) × dtime，也不超過 limit 級（選礦場的倉快滿了）。
-- 每吃一塊呼叫 take(級數, 碎石種類, 品位 param2)；回傳吃了幾級。倉裡的料順便往格柵流一步
-- 結算單：右上角資金下面一張小表（項目／數量／單價／金額，數字靠右），BILL_TIME 秒後收掉，下一張來了就換掉。
-- 聊天欄是比例字型排不齊，所以用 HUD 一格一格放
local BILL_TIME = 12
local GREEN, RED, WHITE, GOLD = 0x80FF80, 0xFF8080, 0xFFFFFF, 0xFFE080
local COLS = {{-440, 1}, {-250, -1}, {-130, -1}, {-20, -1}}   -- 各欄離右邊的 x（px）、對齊（1 靠左、−1 靠右）
local ROW_H = 24
local bills = {}            -- 玩家名稱 → {ids, token}
local function money_text(v) return (v < 0 and "−" or "+") .. ("$%.0f"):format(math.abs(v)) end
local function show_bill(name, title, rows)
	local player = core.get_player_by_name(name)
	if not player then return end
	local old = bills[name]
	if old then for _, id in ipairs(old.ids) do player:hud_remove(id) end end
	local ids = {}
	local function add(def)
		def.position, def.z_index = {x = 1, y = 0.13}, 95
		ids[#ids + 1] = player:hud_add(def)
	end
	local n = #rows + 2
	add({type = "image", alignment = {x = -1, y = 1}, offset = {x = -8, y = -6}, scale = {x = 450, y = ROW_H * n + 12},
		text = "[fill:1x1:#101010f4"})   -- 幾乎不透明：後面場景裡的名牌（怪手、卡車）不會透出來疊到字
	add({type = "text", alignment = {x = 1, y = 1}, offset = {x = COLS[1][1], y = 0}, text = title, number = GOLD})
	for c, head in ipairs({"項目", "數量", "單價", "金額"}) do
		add({type = "text", alignment = {x = COLS[c][2], y = 1}, offset = {x = COLS[c][1], y = ROW_H}, text = head, number = 0xB0B0B0})
	end
	for r, row in ipairs(rows) do
		for c = 1, 4 do
			if row[c] ~= "" then
				add({type = "text", alignment = {x = COLS[c][2], y = 1}, offset = {x = COLS[c][1], y = ROW_H * (r + 1)}, text = row[c],
					number = (c == 4 or r == #rows) and row[5] or WHITE})
			end
		end
	end
	local token = {}
	bills[name] = {ids = ids, token = token}
	core.after(BILL_TIME, function()
		local b = bills[name]
		if not (b and b.token == token) then return end
		local p = core.get_player_by_name(name)
		if p then for _, id in ipairs(b.ids) do p:hud_remove(id) end end
		bills[name] = nil
	end)
end
core.register_on_leaveplayer(function(player) bills[player:get_player_name()] = nil end)

local eat_body
local function eat(pos, dtime, rate, limit, take)
	local C = rockmech.collapse
	C.quiet = C.quiet + 1        -- 倉內作業：移除碎石不觸發岩石力學判定（倉壁有護坡）
	local ok, eaten = pcall(function() return eat_body(pos, dtime, rate, limit, take) end)
	C.quiet = C.quiet - 1
	if not ok then error(eaten) end
	return eaten
end
eat_body = function(pos, dtime, rate, limit, take)
	local meta = core.get_meta(pos)
	local budget = meta:get_float("carry") + rate * dtime / tons_of(1)
	local want = math.min(math.floor(budget), limit or math.huge)
	local eaten = 0
	local cells = grate_cells(meta)
	local start = meta:get_int("next")
	for i = 1, #cells do
		if want <= 0 then break end
		local p = top_rubble(cells[(start + i - 1) % #cells + 1])
		if p then
			local t, base, p2 = V.take_rubble(p, want)
			want = want - t
			eaten = eaten + t
			take(t, base, p2)
			meta:set_int("next", (start + i) % #cells)
		end
	end
	drain(hopper_center(meta))
	meta:set_float("carry", eaten > 0 and budget - math.floor(budget) or 0)
	if eaten > 0 then rockmech.collapse.rubble_sound(pos, eaten) end
	return eaten
end

-- 一個交易日的結算：通知帳戶所有在線上的成員（分組時是整組）；破碎先響金幣聲，再出結算表。day：結的是哪一個交易日
local function report(meta, owner, dump, day)
	local bt = meta:get_float("batch_t")
	local bq, bg, bf = meta:get_float("batch_q"), meta:get_float("batch_g"), meta:get_float("batch_f")
	local members = rockmech.account_members(rockmech.account_of(owner))
	local title = ("第 %d 個交易日　%.1f t"):format(day + 1, bt)
	if dump then
		for _, m in ipairs(members) do
			core.chat_send_player(m, ("[廢石場] 日結 %.1f t 棄置%s"):format(bt, bf > 0 and ("，棄置費 −$%.0f"):format(bf) or ""))
			if bf > 0 then
				show_bill(m, "廢石場日結　" .. title, {
					{"棄置費", ("%.1f t"):format(bt), ("$%g"):format(cfg.dump_fee), money_text(-bf), RED}})
			end
		end
	else
		local ore = main_ore()
		local rows = {}
		if ore then
			rows[#rows + 1] = {("%s（品位 %.0f%%）"):format(ore.label, 100 * bq / bt), ("%.1f t"):format(bq),
				("$%.0f × %.0f%%"):format(rockmech.ore_price(ore), rockmech.eff_ore_recovery(owner, ore) * 100), money_text(bg), GREEN}
		end
		rows[#rows + 1] = {"廢石", ("%.1f t"):format(bt - bq), "", "", WHITE}
		rows[#rows + 1] = {"處理費", ("%.1f t"):format(bt), ("$%g"):format(cfg.crusher_fee), money_text(-bf), RED}
		-- 人事費（wages.lua：雇員薪水在組員在線時已經陸續扣了，這裡列出來、算進淨收入）
		local wage = 0
		local wamt, wsec = (rockmech.wage_take or function() end)(rockmech.account_of(owner), day)
		if wamt and wamt > 0 then
			local r = rockmech.wage_row(wamt, wsec)
			rows[#rows + 1] = {r[1], r[2], r[3], money_text(r[4]), RED}
			wage = wamt
		end
		-- 燃料費（fuel.lua：引擎發動時陸續扣了，這裡列出來）
		local famt, fl = (rockmech.fuel_take or function() end)(rockmech.account_of(owner), day)
		if famt and famt > 0 then
			local r = rockmech.fuel_row(famt, fl)
			rows[#rows + 1] = {r[1], r[2], r[3], money_text(r[4]), RED}
			wage = wage + famt
		end
		local net = bg - bf - wage
		rows[#rows + 1] = {"淨收入", "", "", money_text(net), net >= 0 and GREEN or RED}
		for _, m in ipairs(members) do
			core.sound_play("rockmech_coin", {to_player = m, gain = 0.8}, true)
		end
		core.after(COIN_LEAD, function()
			for _, m in ipairs(members) do
				core.chat_send_player(m, ("[破碎站] 日結 %.1f t，淨收入 %s"):format(bt, money_text(net)))
				show_bill(m, "破碎站日結　" .. title, rows)
			end
		end)
	end
	for _, k in ipairs({"batch_t", "batch_q", "batch_g", "batch_f", "batch_m"}) do meta:set_float(k, 0) end
end

rockmech.show_bill, rockmech.money_text = show_bill, money_text     -- wages.lua 的人事費單子

local function crush(pos, dtime)
	local meta = core.get_meta(pos)
	local dump = meta:get_string("mode") == "dump"
	-- 這一步的帳：礦的噸數、礦的貨款（噸 × 價格 × 回收率）、處理費（全部噸數 × 每噸處理費；廢石場是棄置費）
	local ore_t, gross, fee = 0, 0, 0
	local eaten = eat(pos, dtime, rate_of(pos), nil, function(t, base, p2)
		local ore = rockmech.ore_of_rubble[base]
		local tons = tons_of(t)
		local grade = ore and p2 / 255 or 0
		ore_t = ore_t + tons * grade
		if dump then fee = fee + tons * cfg.dump_fee
		else
			if ore then gross = gross + tons * grade * rockmech.eff_ore_recovery(meta:get_string("owner"), ore) * rockmech.ore_price(ore) end
			fee = fee + tons * cfg.crusher_fee
		end
	end)
	local income = gross - fee
	local owner = meta:get_string("owner")
	-- 換日（礦價開盤）後第一步結算前一個交易日（破碎站強制載入，計時器一直跑，開盤後 1 秒內就會結）
	local today, bday = market_day(), meta:get_int("batch_day")
	if bday ~= today then
		if meta:get_float("batch_t") > 0 then report(meta, owner, dump, bday) end
		meta:set_int("batch_day", today)
	end
	if eaten == 0 then return end
	local t = tons_of(eaten)
	if income ~= 0 then rockmech.add_money(owner, income) end
	for key, v in pairs({batch_t = t, batch_q = ore_t, batch_g = gross, batch_f = fee, batch_m = income,
			total_t = t, total_q = ore_t, total_g = gross, total_f = fee, total_m = income}) do
		meta:set_float(key, meta:get_float(key) + v)
	end
end

local function formspec(pos)
	local meta = core.get_meta(pos)
	local queue = hopper_levels(hopper_center(meta))
	local total = meta:get_float("total_t")
	local dump = meta:get_string("mode") == "dump"
	local rate = rate_of(pos)
	-- 排隊：倉裡還有多少、照處理能力還要多久
	local qt = tons_of(queue)
	local queue_text = ("排隊 %.1f t，約 %d 秒處理完"):format(qt, math.ceil(qt / rate))
	local prices = {}
	for _, ore in pairs(cfg.ores) do
		prices[#prices + 1] = ("%s 品位 100%% 今日每噸 $%.0f（基準 $%g），回收率 %.0f%%"):format(ore.label, rockmech.ore_price(ore), ore.price,
			rockmech.eff_ore_recovery(meta:get_string("owner"), ore) * 100)
	end
	return table.concat({
		"formspec_version[6]size[11,7.6]",
		("label[0.5,0.6;%s]"):format(dump and "廢石場（倒進來的碎石直接棄置，不收入）" or title_of(pos)),
		dump and ("label[0.5,1.2;處理能力：%g t/s　棄置費：每噸 $%g]"):format(rate, cfg.dump_fee)
			or ("label[0.5,1.2;處理能力：%g t/s　處理費：每噸 $%g]"):format(rate, cfg.crusher_fee),
		("label[0.5,1.8;%s]"):format(core.formspec_escape(dump and "礦石倒進來也當廢石丟掉" or table.concat(prices, "；"))),
		("textarea[0.5,6.5;10,1;;;%s]"):format(core.formspec_escape(queue_text)),
		("button[0.5,5.5;8,0.8;mode;%s]"):format(dump and "切換成破碎站（賣礦）" or ("切換成廢石場（棄置，每噸 $%g）"):format(cfg.dump_fee)),
		("label[0.5,2.4;受料倉：%.1f / %.0f m³（%.1f t）]"):format(queue / V.NLEV, CAPACITY / V.NLEV, tons_of(queue)),
		("label[0.5,3.0;累計處理：%.1f t，平均品位 %.0f%%]"):format(total, total > 0 and 100 * meta:get_float("total_q") / total or 0),
		("label[0.5,3.6;累計：貨款 $%.0f − 處理費 $%.0f = 淨收入 $%.0f]"):format(meta:get_float("total_g"), meta:get_float("total_f"), meta:get_float("total_m")),
		("label[0.5,4.2;資金（%s）：$%.0f]"):format(core.formspec_escape(rockmech.account_label(meta:get_string("owner"))),
			rockmech.money(meta:get_string("owner"))),
		"button_exit[3,4.8;3,0.8;ok;關閉]",
	})
end
local editing = {}          -- 玩家名稱 → 正在看的破碎站
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= CRUSHER then return end
	local name = player:get_player_name()
	local pos = editing[name]
	if not pos or not CRUSHERS[core.get_node(pos).name] then return true end
	if fields.mode and rockmech.owner_ok(core.get_meta(pos):get_string("owner"), name) then
		local meta = core.get_meta(pos)
		meta:set_string("mode", meta:get_string("mode") == "dump" and "" or "dump")
		meta:set_string("infotext", meta:get_string("mode") == "dump" and "廢石場（右鍵查看）" or (title_of(pos) .. "（右鍵查看）"))
		core.show_formspec(name, CRUSHER, formspec(pos))
	end
	if fields.quit or fields.ok then editing[name] = nil end
	return true
end)

---------------------------------------------------------------------------
-- 方塊
---------------------------------------------------------------------------

-- 機身在 pos、受料倉朝 (dx, dz)：挖階梯漏斗（每往下一層四邊各內縮 1 m）、放格柵、記到機身的 meta。
-- 受料倉的護坡：倉壁是 45° 的台階，留著原來的岩石就會被節理切成岩塊掉進倉裡（倉壁不是開挖面，是設施）。
-- 貼著倉的那一層岩石（六個面任一面接到倉的格子）換成鋼筋混凝土護坡：不是岩石、不帶節理、不參與破壞判定，
-- 但是實心、會承力，後面的岩石就沒有臨空面。爆破只炸岩石和碎石，護坡炸不壞；工具挖不動
local LINING = "rockmech:hopper_lining"
core.register_node(LINING, {
	description = "受料倉混凝土護坡 Hopper lining\n鋼筋混凝土，擋住倉壁的岩石（不會被節理切開掉落）",
	tiles = {"[fill:16x16:#9a9890^[fill:16x1:0,7:#86847c^[fill:1x16:7,0:#86847c^[fill:2x2:3,3:#a8a69e^[fill:2x2:11,12:#8e8c84"},
	is_ground_content = false,
	groups = {not_in_creative_inventory = 1},
	drop = "",
})
-- 倉的範圍（meta 的 gx, gy, gz）：第 dy 層（倉口 dy = 0）是邊長 SIZE − 2·dy 的正方形
local function line_hopper(meta)
	local c, half = hopper_center(meta), (SIZE - 1) / 2
	local top = meta:get_int("gy") + DEPTH
	local function cavity(x, y, z)
		local dy = top - y
		if dy < 0 or dy >= DEPTH then return false end
		return math.max(math.abs(x - c.x), math.abs(z - c.z)) <= half - dy
	end
	-- 整個範圍先載入（倉壁可能跨到還沒載入的區塊）；還是讀到 ignore 就回傳 nil，下次載入再補
	core.load_area({x = c.x - half - 1, y = top - DEPTH, z = c.z - half - 1}, {x = c.x + half + 1, y = top + 1, z = c.z + half + 1})
	local n, missing = 0, false
	for y = top - DEPTH, top + 1 do
		for x = c.x - half - 1, c.x + half + 1 do for z = c.z - half - 1, c.z + half + 1 do
			if not cavity(x, y, z) and (cavity(x + 1, y, z) or cavity(x - 1, y, z) or cavity(x, y + 1, z)
					or cavity(x, y - 1, z) or cavity(x, y, z + 1) or cavity(x, y, z - 1)) then
				local p = {x = x, y = y, z = z}
				local name = core.get_node(p).name
				if name == "ignore" then missing = true
				elseif rockmech.lith_of_node[name] then
					core.swap_node(p, {name = LINING})
					n = n + 1
				end
			end
		end end
	end
	return n, missing
end

-- 倉裡原有的碎石不挖，之後逐欄疊到新的倉底（舊倉擴建）
local function dig_hopper(pos, dx, dz)
	local half = (SIZE - 1) / 2
	local cx, cz = pos.x + dx * (2 + half), pos.z + dz * (2 + half)    -- 受料倉中心，緊貼機身
	local gy = pos.y - 1 - DEPTH
	for dy = 0, DEPTH - 1 do
		local r = half - dy
		for x = cx - r, cx + r do for z = cz - r, cz + r do
			local p = {x = x, y = pos.y - 1 - dy, z = z}
			if not rockmech.rubble_level[core.get_node(p).name] then
				rockmech.collapse.mark_excavated(p)
				core.swap_node(p, {name = "air"})
			end
		end end
	end
	local r = (FEEDER - 1) / 2
	for x = cx - r, cx + r do for z = cz - r, cz + r do
		core.swap_node({x = x, y = gy, z = z}, {name = GRATE})
	end end
	-- 懸空的碎石往下疊：每欄由下往上，保留種類、級數、品位
	for x = cx - half, cx + half do for z = cz - half, cz + half do
		local floor, stack = nil, {}
		for y = gy, pos.y + PILE do
			local p = {x = x, y = y, z = z}
			local n = core.get_node(p)
			if rockmech.rubble_level[n.name] then
				stack[#stack + 1] = n
				core.swap_node(p, {name = "air"})
			elseif n.name ~= "air" and #stack == 0 then
				floor = y
			end
		end
		for i, n in ipairs(stack) do core.swap_node({x = x, y = floor + i, z = z}, n) end
	end end
	local meta = core.get_meta(pos)
	meta:set_int("gx", cx - r)
	meta:set_int("gy", gy)
	meta:set_int("gz", cz - r)
	meta:set_int("size", SIZE)
	local _, missing = line_hopper(meta)
	meta:set_int("lined", missing and 0 or 1)
end

-- 已經蓋好的受料倉（破碎站、大型破碎站、選礦場）補上護坡，每座一次
core.register_lbm({
	label = "受料倉補上混凝土護坡",
	name = "rockmech:hopper_lining_v1",
	nodenames = {CRUSHER, CRUSHER_BIG, PLANT},
	run_at_every_load = true,
	action = function(pos)
		local meta = core.get_meta(pos)
		if meta:get_int("lined") == 1 or meta:get_int("size") == 0 then return end
		local n, missing = line_hopper(meta)
		if not missing then meta:set_int("lined", 1) end
		core.log("action", ("[rockmech] %s 的受料倉補上護坡 %d 格"):format(core.pos_to_string(pos), n))
	end,
})

-- 破碎站不管人在哪裡都要運作：引擎只在玩家附近的區塊跑節點計時器，人到礦場去了倉裡的料就停著。
-- 機身和受料倉（含倉上 PILE 格）所在的區塊強制載入，存在世界裡；一座最多 8 塊。不受 max_forceloaded_blocks（預設 16）
-- 限制：無人卡車、怪手沿途也會暫時強制載入（vehicles.lua），合起來常超過 16
local function each_block(pos, fn)
	local meta = core.get_meta(pos)
	local c, h = hopper_center(meta), (SIZE - 1) / 2
	local a = {x = math.min(pos.x - 1, c.x - h), y = meta:get_int("gy"), z = math.min(pos.z - 1, c.z - h)}
	local b = {x = math.max(pos.x + 1, c.x + h), y = pos.y + PILE, z = math.max(pos.z + 1, c.z + h)}
	for bx = math.floor(a.x / 16), math.floor(b.x / 16) do
		for by = math.floor(a.y / 16), math.floor(b.y / 16) do
			for bz = math.floor(a.z / 16), math.floor(b.z / 16) do fn({x = bx * 16, y = by * 16, z = bz * 16}) end
		end
	end
end
local function keep_loaded(pos)
	local meta = core.get_meta(pos)
	if not HOPPER_BODY[core.get_node(pos).name] or meta:get_int("forceload") == 1 then return end
	local n = 0
	each_block(pos, function(p) n = n + 1; core.forceload_block(p, false, -1) end)
	meta:set_int("forceload", 1)
	core.log("action", ("[rockmech] %s %s 強制載入 %d 個區塊"):format(core.get_node(pos).name, core.pos_to_string(pos), n))
end

-- 機身在 pos、受料倉朝 (dx, dz) 的地形可以蓋嗎：機身 3×3 m 和受料倉要平坦、地下是實心、上方淨空
local function site_ok(pos, dx, dz)
	local half = (SIZE - 1) / 2
	local cx, cz = pos.x + dx * (2 + half), pos.z + dz * (2 + half)    -- 受料倉中心，緊貼機身
	local function solid(p) return not V.passable(core.get_node(p).name) end
	for x = cx - half, cx + half do for z = cz - half, cz + half do
		if solid({x = x, y = pos.y, z = z}) then return false end
		for y = pos.y - 1 - DEPTH, pos.y - 1 do
			if not solid({x = x, y = y, z = z}) then return false end
		end
	end end
	for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
		if not solid({x = x, y = pos.y - 1, z = z}) then return false end
		for y = pos.y, pos.y + 2 do
			if solid({x = x, y = y, z = z}) then return false end
		end
	end end
	return true
end

-- 在 pos 蓋破碎站（機身），受料倉朝 (dx, dz)。地不平回傳 false
function rockmech.crusher_build(pos, dx, dz, name, node)
	if not site_ok(pos, dx, dz) then return false end
	core.set_node(pos, {name = node or CRUSHER})
	dig_hopper(pos, dx, dz)
	local meta = core.get_meta(pos)
	local acc = rockmech.account_of(name)       -- 分了組就掛在組上，收入進整組的帳戶
	meta:set_string("owner", acc)
	meta:set_string("infotext", ("%s（%s，右鍵查看）"):format(title_of(pos), rockmech.account_label(acc)))
	core.get_node_timer(pos):start(STEP)
	keep_loaded(pos)
	if not storage:contains(MONEY .. acc) then rockmech.add_money(acc, 0) end
	return true
end

local BODY = "[fill:16x16:#b08a20^[fill:16x2:0,0:#303030^[fill:16x2:0,14:#303030"

core.register_node(GRATE, {
	description = "Crusher grate (破碎站受料格柵)",
	tiles = {"[fill:16x16:#181818^[fill:16x3:0,1:#8a8a8a^[fill:16x3:0,9:#8a8a8a^[fill:3x16:1,0:#8a8a8a^[fill:3x16:9,0:#8a8a8a"},
	groups = {cracky = 2, not_in_creative_inventory = 1},
	is_ground_content = false,
	drop = "",
})

local crusher_def = {
	description = "Crusher (破碎站)\n對著平地按右鍵放置，朝自己的方向挖 " .. SIZE .. "×" .. SIZE .. " m 受料倉\n碎石倒進倉裡就過磅入帳；廢石要賠處理費",
	drawtype = "nodebox",
	paramtype = "light",
	node_box = {type = "fixed", fixed = {-1.45, -0.5, -1.45, 1.45, 2.4, 1.45}},
	tiles = {BODY},
	inventory_image = "rockmech_icon_crusher.png",      -- devtools/make_icons.py
	groups = {cracky = 2},
	is_ground_content = false,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local pos = pointed.above
		local look = placer:get_look_dir()
		local dx, dz = 0, 0
		if math.abs(look.x) > math.abs(look.z) then dx = look.x > 0 and -1 or 1
		else dz = look.z > 0 and -1 or 1 end
		local name = placer:get_player_name()
		if not rockmech.crusher_build(pos, dx, dz, name, itemstack:get_name()) then
			core.chat_send_player(name, "[破碎站] 要放在平地上：機身 3×3 m 和前方 " .. SIZE .. "×" .. SIZE .. " m 要平坦、地下是實心、上方淨空")
			return itemstack
		end
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	on_rightclick = function(pos, node, clicker)
		editing[clicker:get_player_name()] = pos
		core.show_formspec(clicker:get_player_name(), CRUSHER, formspec(pos))
	end,
	can_dig = function(pos, player)
		return player and rockmech.owner_ok(core.get_meta(pos):get_string("owner"), player:get_player_name())
	end,
	on_timer = function(pos, elapsed)
		crush(pos, math.min(elapsed, 5 * STEP))
		return true
	end,
	on_destruct = function(pos)
		local meta = core.get_meta(pos)
		for _, c in ipairs(grate_cells(meta)) do
			if core.get_node(c).name == GRATE then core.swap_node(c, {name = rockmech.RUBBLE}) end
		end
		if meta:get_int("forceload") == 1 then each_block(pos, function(p) core.forceload_free_block(p, false) end) end
	end,
}
core.register_node(CRUSHER, crusher_def)
-- 大型破碎站：一樣的機身大小和受料倉，處理能力大好幾倍（深灰機身、黃黑警示條）
local big = table.copy(crusher_def)
local BIG_BODY = "[fill:16x16:#4a5058^[fill:16x2:0,0:#f0c020^[fill:16x2:0,14:#f0c020^[fill:2x2:2,0:#202020^[fill:2x2:8,0:#202020^[fill:2x2:14,0:#202020"
big.description = ("Large crusher (大型破碎站)\n處理能力 %g t/s（一般破碎站 %g t/s）\n對著平地按右鍵放置，朝自己的方向挖 %d×%d m 受料倉"):format(
	cfg.crusher_big_rate, cfg.crusher_rate, SIZE, SIZE)
big.tiles, big.inventory_image = {BIG_BODY}, "rockmech_icon_crusher_big.png"
big.node_box = {type = "fixed", fixed = {{-1.45, -0.5, -1.45, 1.45, 2.4, 1.45}, {-0.6, 2.4, -0.6, 0.6, 2.9, 0.6}}}
core.register_node(CRUSHER_BIG, big)

-- 舊版小倉擴建成現在的大小：舊格柵回填成下面的岩石，再照新尺寸挖（倉裡的碎石留著，疊到新的倉底）
local function enlarge(pos)
	local meta = core.get_meta(pos)
	if core.get_node(pos).name ~= CRUSHER or meta:get_int("size") >= SIZE then return end
	local old = hopper_center(meta)
	local dx, dz = 0, 0
	if math.abs(old.x - pos.x) > math.abs(old.z - pos.z) then dx = old.x > pos.x and 1 or -1
	else dz = old.z > pos.z and 1 or -1 end
	local reach = 2 + SIZE
	core.load_area({x = pos.x - reach, y = pos.y - DEPTH - 2, z = pos.z - reach}, {x = pos.x + reach, y = pos.y + PILE, z = pos.z + reach})
	for _, c in ipairs(grate_cells(meta)) do
		core.swap_node(c, core.get_node({x = c.x, y = c.y - 1, z = c.z}))
	end
	dig_hopper(pos, dx, dz)
	core.log("action", ("[rockmech] 受料倉擴建成 %d×%d m：機身 %s"):format(SIZE, SIZE, core.pos_to_string(pos)))
end
core.register_lbm({
	label = "rockmech: 舊版受料倉擴建",
	name = "rockmech:hopper_size_" .. SIZE,
	nodenames = {CRUSHER},
	run_at_every_load = false,
	action = function(pos) core.after(0, enlarge, pos) end,
})
-- 舊世界的破碎站：走近一次就補上強制載入（在擴建之後，區塊照新的倉算）
core.register_lbm({
	label = "rockmech: 破碎站強制載入",
	name = "rockmech:crusher_forceload",
	nodenames = {CRUSHER, CRUSHER_BIG},
	run_at_every_load = false,
	action = function(pos) core.after(1, keep_loaded, pos) end,
})

-- 保險：計時器停了（例如區塊沒存到計時器）破碎站、選礦場就不再吃料，料堆在格柵上。
-- 每 5 秒檢查一次，停了就重新啟動並記一行警告（強制載入的區塊一直是活動的，ABM 會跑到）
core.register_abm({
	label = "rockmech: 破碎站、選礦場的計時器停了就重新啟動",
	nodenames = {CRUSHER, CRUSHER_BIG, "rockmech:plant"},
	interval = 5, chance = 1,
	action = function(pos, node)
		local t = core.get_node_timer(pos)
		if t:is_started() then return end
		t:start(STEP)
		core.log("warning", ("[rockmech] %s %s 的計時器停了，重新啟動"):format(node.name, core.pos_to_string(pos)))
	end,
})

-- 給選礦場（plant.lua）共用
rockmech.hopper_lib = {
	SIZE = SIZE, PILE = PILE, STEP = STEP, GRATE = GRATE, tons_of = tons_of, eat = eat,
	hopper_center = hopper_center, hopper_levels = hopper_levels, grate_cells = grate_cells, dig_hopper = dig_hopper,
	site_ok = site_ok, keep_loaded = keep_loaded, each_block = each_block,
}
