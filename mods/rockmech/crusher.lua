-- rockmech/crusher.lua
-- 破碎站（賣礦）：放在平地上，朝玩家的方向挖一個受料倉：9×9 m、深 4 m 的階梯漏斗，壁坡 45° 比殘餘摩擦角陡，
-- 碎石不會留在壁上。底部 3×3 m 是格柵（給料口），只從這裡吃料，上方的料靠碎石流動自己補進來。
-- 卡車、挖土機、推土機倒進來都一樣；每秒最多 rockmech_crusher_rate 噸，倒太快就在倉裡排隊。
-- 過磅入帳：照品位拆成煤和廢石：煤噸 × 回收率 × 價格 × 收購比例 − 廢石噸 × 廢石處理費（config.crush_income）。
-- 收購比例：有火車的地圖是 cfg.coal_yard_ratio（坑口價，火車照原價），沒有火車是 1。品位太低就賠錢：截止品位。錢記在放置破碎站的玩家的帳戶（分了組就是整組，見 team.lua）。
-- 礦價每個交易日（rockmech_price_period 秒）浮動一次：rockmech.ore_price。
-- 右鍵可以切換成廢石場：倒進來的碎石直接棄置，不收入，每噸付 rockmech_dump_fee（預設 0）。
-- 受料倉、格柵、強制載入給選礦場（plant.lua）共用：rockmech.hopper_lib

local cfg = rockmech.cfg
local S = rockmech.S
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
-- 收煤站付市價的幾成：有火車（教學地圖）才打折，火車照原價收
function rockmech.yard_ratio()
	return rockmech.train_enabled and rockmech.train_enabled() and cfg.coal_yard_ratio or 1
end
-- 這座收哪一種礦（meta 的 ore；沒選過就是這張地圖的主要礦），多種礦的地圖標題後面加礦名
local function ore_of(meta) return rockmech.active_ore(meta:get_string("ore")) end
rockmech.facility_ore = ore_of
local function title_of(pos)
	local t = core.get_node(pos).name == CRUSHER_BIG and S("Large crusher") or S("Crusher")
	return rockmech.multi_ore() and (t .. "  " .. S(ore_of(core.get_meta(pos)).label)) or t
end
local SIZE, FEEDER = 9, 3    -- 受料倉開口（大型破碎站、選礦場）、底部格柵的邊長 (m)
local SMALL_SIZE = 7         -- 一般破碎站的受料倉開口（小一號）；每座的開口記在機身的 meta size
-- 倉深 (m)：每往下一層四邊各內縮 1 m（壁坡 45°），最底層就是格柵的大小
local function depth_of(size) return (size - FEEDER) / 2 + 1 end
local DEPTH = depth_of(SIZE)
-- 容量（級），裝到倉口
local function capacity_of(size)
	local c = 0
	for dy = 0, depth_of(size) - 1 do c = c + (size - 2 * dy) ^ 2 * rockmech.vehicles.NLEV end
	return c
end
local PILE = 8              -- 格柵上往上找幾格碎石
local FIND_R = 15           -- 傾倒點離格柵中心多近（水平距離）算在破碎站
rockmech.HOPPER_RANGE = FIND_R
rockmech.HOPPER_HALF = SIZE / 2   -- 倉口中心到邊 (m)：最大的；實際的用 rockmech.hopper_half_at(格柵中心)
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
	return cfg.main_ore      -- 這張地圖的主要礦（config.lua 的 rockmech_ores）
end
rockmech.main_ore = main_ore
-- 每噸廢石的處理費：礦種自己的（大理岩：水泥廠的雜質罰款），沒寫就用 rockmech_crusher_fee
function rockmech.gangue_fee(ore) ore = ore or cfg.main_ore; return ore and ore.fee or cfg.crusher_fee end
function rockmech.gangue_label(ore) ore = ore or cfg.main_ore; return S(ore and ore.gangue or "Gangue") end
-- 多種礦的地圖：破碎站、選礦廠、皮帶控制箱、訂單各自選一種礦（meta / 設定裡的 ore 鍵），別種礦算廢石。
-- 礦種不寫死：選項就是這張地圖開著的礦（cfg.active_ores）；只有一種礦時不顯示選單，就是那一種
function rockmech.multi_ore() return #cfg.active_ores > 1 end
function rockmech.active_ore(key)
	for _, o in ipairs(cfg.active_ores) do if o.key == key then return o end end
	return cfg.main_ore
end
-- 碎石（base、param2）對某種礦的品位：是這種礦的碎石才算，別種礦和廢石都是 0
function rockmech.grade_for(base, p2, ore)
	return ore and rockmech.ore_of_rubble[base] == ore and p2 / 255 or 0
end
-- 碎石對某種金屬礦的含銅量（0..1）：同一族的原礦、精礦、尾礦都算，其他是 0
function rockmech.metal_content(base, p2, ore)
	local m = ore and ore.metal
	local o = rockmech.ore_of_rubble[base]
	if not (m and o and o.metal and o.metal.family == m.family) then return 0 end
	return p2 / 255 * o.metal.scale
end
-- 一份料（tons 噸、碎石 base、param2）賣給收 ore 的破碎站 → 礦的噸數（剝採比用）, 貨款, 廢料處理費, 廢料噸數, 含銅噸數。
--   一般的礦（config.crush_income）：品位 × 回收率 × 價格 × 收購比例；廢料（矸石、片岩）照 (1 − 品位) 收處理費。
--   金屬礦（copper.lua）：精礦照含銅量計價、扣冶煉費；原礦是外包選礦，尾礦每噸收處理費；別的碎石整車變尾礦
-- c（可省）：成分表（assay.lua）；有化學成分（鐵、金、有害雜質）的照 config.element_value 另外計價、罰款，
-- 算進貨款和處理費，另外回傳 鐵貨款, 金貨款, 有害雜質罰款（結算單分列）
function rockmech.sale_value(tons, base, p2, ore, owner, c)
	local q, gross, fee, w, cu = rockmech.sale_value_main(tons, base, p2, ore, owner)
	local vfe, vau, hfee = 0, 0, 0
	if type(c) == "table" and (c.fe or c.au or c.harm) then
		vfe, vau, hfee = cfg.element_value(tons, c, rockmech.yard_ratio(), rockmech.gold_price and rockmech.gold_price())
	end
	return q, gross + vfe + vau, fee + hfee, w, cu, vfe, vau, hfee
end
function rockmech.sale_value_main(tons, base, p2, ore, owner)
	local m = ore and ore.metal
	if not m then
		local g = rockmech.grade_for(base, p2, ore)
		local gross = tons * g * rockmech.eff_ore_recovery(owner, ore) * rockmech.ore_price(ore) * rockmech.yard_ratio()
		local w = tons * (1 - g)
		return tons * g, gross, w * rockmech.gangue_fee(ore), w, 0
	end
	local c = rockmech.metal_content(base, p2, ore)
	local Cu = rockmech.copper
	local price = rockmech.ore_price(ore) * rockmech.yard_ratio()
	if rockmech.ore_of_rubble[base] == cfg.ores[m.conc] then        -- 精礦：直接賣給冶煉廠
		return tons, Cu.conc_value(tons, tons * c, price, m.tc), 0, 0, tons * c
	end
	local fee = rockmech.gangue_fee(ore)
	local value, tail = Cu.toll(tons, c, m, price, rockmech.eff_ore_recovery(owner, ore), fee)
	return c > 0 and tons or 0, value, tail * fee, tail, tons * c
end
-- 選礦種的下拉選單（formspec）；只有一種礦時是空字串
function rockmech.ore_dropdown(x, y, w, field, ore)
	if not rockmech.multi_ore() then return "" end
	local items, sel = {}, 1
	for i, o in ipairs(cfg.active_ores) do
		items[i] = core.formspec_escape(S(o.label))
		if o == ore then sel = i end
	end
	return ("dropdown[%g,%g;%g,0.8;%s;%s;%d;true]"):format(x, y, w, field, table.concat(items, ","), sel)
end
-- 下拉選單回傳的值（index_event = true：序號）→ 礦
function rockmech.ore_from_field(v)
	local i = tonumber(v)
	return i and cfg.active_ores[i] or nil
end
local function price_text(ore)
	local c = price_change(ore)
	return S("@1 price @2 (@3 @4%)", S(ore.label), rockmech.price_str(ore, rockmech.ore_price(ore)), c >= 0 and "▲" or "▼", ("%.0f"):format(math.abs(c) * 100))
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
-- 單機地圖（rockmech_solo，不是教學地圖）沒有分組：整張地圖一個帳戶，歸營地的主人（第一個進來的人）；
-- 開放連線時：合作（rockmech_multiplayer = coop）大家共用這個帳戶；競爭（compete）每人自己的帳戶，
-- 開伺服器的人用營地主人的帳戶（單機玩過的錢接得上）。舊存檔沒記主人：有 singleplayer 的錢就是 singleplayer
local SOLO_OWNER = "solo_owner"
function rockmech.solo_account(name)
	local o = storage:get_string(SOLO_OWNER)
	if o ~= "" then return o end
	o = storage:contains(MONEY .. "singleplayer") and "singleplayer" or name
	storage:set_string(SOLO_OWNER, o)
	return o
end
function rockmech.account_of(name)
	if name:find(":", 1, true) then return name end
	if cfg.solo and not cfg.teacher then
		if cfg.multiplayer == "compete" and not core.is_singleplayer() and name ~= core.settings:get("name") then return name end
		return rockmech.solo_account(name)
	end
	local t = rockmech.team_of(name)
	return t and ("team:" .. t) or name
end
function rockmech.account_label(acc)
	if acc == "camp:spawn" then return S("Spawn camp (shared)") end     -- 第一個進世界的人已分組時，出生點營地的帳戶（career.lua）
	local t = acc:match("^team:(.+)$")
	if t == "0" then return S("Teacher team") end
	return t and S("Team @1", t) or acc
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
	rockmech.notify(name, S("This facility belongs to @1; other teams cannot touch it", rockmech.account_label(owner)))
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
function rockmech.eff_vehicle_mult(owner) return 1 + 0.05 * rockmech.research_level(owner, "maintenance") end
function rockmech.eff_blast_mult(owner) return 1 + 0.05 * rockmech.research_level(owner, "blast_design") end   -- 爆破設計：破碎半徑
function rockmech.eff_support_mult(owner) return 1 + 0.1 * rockmech.research_level(owner, "support_method") end -- 支撐工法：岩栓、噴凝土強度
function rockmech.eff_fuel_mult(owner) return 1 - 0.05 * rockmech.research_level(owner, "eco_driving") end      -- 省油駕駛：油耗
-- 某個位置的支護算哪一組的研發：上課世界照礦帶；其他世界（單人）照線上第一位玩家
function rockmech.support_mult_at(pos)
	local lane = not core.is_singleplayer() and rockmech.lane_team and rockmech.lane_team(pos)
	if lane then return rockmech.eff_support_mult("team:" .. lane) end
	local p = core.get_connected_players()[1]
	return p and rockmech.eff_support_mult(p:get_player_name()) or 1
end
function rockmech.eff_dig_mult(owner) return 1 + 0.1 * rockmech.research_level(owner, "skilled_miner") end   -- 熟練礦工：挖礦、鑽孔速度   -- 定期保養：車速
function rockmech.eff_ore_recovery(owner, ore) return math.min(1, ore.recovery + 0.01 * rockmech.research_level(owner, "ore_recovery")) end
-- 浮選（選礦場處理金屬礦）：精礦品位（研發「精礦品位」每級 +1%）、最高回收率（研發「排矸站回收率」每級 +1%，跟煤共用）
function rockmech.eff_conc_grade(owner, ore) return ore.metal.conc_grade + 0.01 * rockmech.research_level(owner, "conc_grade") end
function rockmech.eff_flotation_recovery(owner, ore) return math.min(0.99, ore.recovery + 0.01 * rockmech.research_level(owner, "plant_recovery")) end

local money_hud = {}        -- 玩家名稱 → HUD id

-- 右上角的資金；帳戶還沒開（沒有資金紀錄）就收起來
local function show_money(player)
	local name = player:get_player_name()
	local acc = rockmech.account_of(name)
	if not storage:contains(MONEY .. acc) then
		if money_hud[name] then player:hud_change(money_hud[name], "text", "") end
		return
	end
	local m = storage:get_float(MONEY .. acc)
	local team = rockmech.team_of(name)
	local amount = (m < 0 and "−" or "") .. ("$%.0f"):format(math.abs(m))
	local text = (team and S("Team @1   Funds @2", team, amount) or S("Funds @1", amount))
	-- 價格漲跌：身上帶著廣播收音機才顯示（market.lua）；沒有就去貨櫃辦公室的告示板看
	if rockmech.has_radio and rockmech.has_radio(player) then
		for _, o in ipairs(cfg.active_ores) do text = text .. "\n" .. price_text(o) end
		text = text
			.. (rockmech.market_hud and ("\n" .. rockmech.market_hud()) or "")
	end
	if money_hud[name] then
		player:hud_change(money_hud[name], "text", text)
	else
		money_hud[name] = player:hud_add({type = "text", position = {x = 0.98, y = 0.06}, alignment = {x = -1, y = 1},
			number = 0xFFE080, text = text, z_index = 100})
	end
end
rockmech.show_money = show_money
rockmech.coal_price_text = function()
	local t = {}
	for _, o in ipairs(cfg.active_ores) do t[#t + 1] = price_text(o) end
	return table.concat(t, "\n")
end

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
	for _, ore in ipairs(cfg.active_ores) do storage:set_float(PRICE_PREV .. ore.key, factor(ore)) end
	-- 每天：市場（market.lua）先走一步（事件、柴油、炸藥、鋼材，事件開始時煤價也會先跳），煤價再往事件的目標走
	local first = today - math.min(days, 30)
	for d = first + 1, today do
		local z_oil = rockmech.market_day_step and rockmech.market_day_step(d)
		for _, ore in ipairs(cfg.active_ores) do
			local m = rockmech.market_target and rockmech.market_target(ore.key) or 0
			local r = z_oil and rockmech.market_coal_oil or 0
			local z = r * (z_oil or 0) + math.sqrt(1 - r * r) * gauss()
			local x = math.log(factor(ore))
			x = math.max(lo, math.min(hi, x - cfg.price_revert * (x - m) + cfg.price_vol * z))
			storage:set_float(PRICE .. ore.key, math.exp(x))
		end
	end
	for _, ore in ipairs(cfg.active_ores) do
		local prev = ore.price * storage:get_float(PRICE_PREV .. ore.key)
		rockmech.notify_all(S("[Market] Today's @1 price $@2/t (yesterday $@3, @4 @5%)", S(ore.label), ("%.0f"):format(rockmech.ore_price(ore)),
			("%.0f"):format(prev), price_change(ore) >= 0 and "▲" or "▼", ("%.0f"):format(math.abs(price_change(ore)) * 100)))
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
-- 這座的受料倉開口：機身 meta 記的（舊的沒記就是 SIZE）；蓋之前看機種
local function size_of(meta) local v = meta:get_int("size"); return v > 0 and v or SIZE end
local function size_for(name) return name == CRUSHER and SMALL_SIZE or SIZE end
-- 格柵中心 c 的受料倉開口：找旁邊的機身
local function size_at(c)
	local b = core.find_node_near(c, 10, {CRUSHER, CRUSHER_BIG, "rockmech:plant"})
	return b and size_of(core.get_meta(b)) or SIZE
end
function rockmech.hopper_half_at(c) return size_at(c) / 2 end

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
local function hopper_levels(c, size)
	local r = ((size or size_at(c)) - 1) / 2
	local n = 0
	for x = c.x - r, c.x + r do for z = c.z - r, c.z + r do for y = c.y + 1, c.y + PILE do
		n = n + (rockmech.rubble_level[core.get_node({x = x, y = y, z = z}).name] or 0)
	end end end
	return n
end
-- 受料倉還放得下幾級（無人駕駛用來判斷要不要等）
function rockmech.hopper_room(c)
	local size = size_at(c)
	return capacity_of(size) - hopper_levels(c, size)
end

-- 倉裡的碎石往給料口流：每次掃整個倉，每欄走一步。只叫給料口旁邊的格子的話，外圈階梯上的料不會動。
-- 倉裡被車壓過變成夯實碎石的（殘餘摩擦角較陡，會卡在倉壁階梯上）換回一般碎石：倉裡的料是鬆的
local loose_of
local function drain(c, size)
	if not loose_of then
		loose_of = {}
		for name, cname in pairs(rockmech.compact_of) do loose_of[cname] = name end
	end
	local r = ((size or size_at(c)) - 1) / 2
	for x = c.x - r, c.x + r do for z = c.z - r, c.z + r do
		for y = c.y + PILE, c.y + 1, -1 do
			local q = {x = x, y = y, z = z}
			local node = core.get_node(q)
			if loose_of[node.name] then
				core.swap_node(q, {name = loose_of[node.name], param2 = node.param2})
				for yy = y - 1, c.y + 1, -1 do        -- 同一欄下面的也一起鬆開
					local qq = {x = x, y = yy, z = z}
					local nn = core.get_node(qq)
					if loose_of[nn.name] then core.swap_node(qq, {name = loose_of[nn.name], param2 = nn.param2}) end
				end
			end
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
	for c, head in ipairs({S("Item"), S("Quantity"), S("Unit price"), S("Amount")}) do
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
			local t, base, p2, ca = V.take_rubble(p, want)
			want = want - t
			eaten = eaten + t
			take(t, base, p2, ca)
			meta:set_int("next", (start + i) % #cells)
		end
	end
	drain(hopper_center(meta), size_of(meta))
	meta:set_float("carry", eaten > 0 and budget - math.floor(budget) or 0)
	if eaten > 0 then rockmech.collapse.rubble_sound(pos, eaten) end
	return eaten
end

-- 一個交易日的結算：通知帳戶所有在線上的成員（分組時是整組）；破碎先響金幣聲，再出結算表。day：結的是哪一個交易日
local function report(meta, owner, dump, day)
	local bt = meta:get_float("batch_t")
	local bq, bg, bf = meta:get_float("batch_q"), meta:get_float("batch_g"), meta:get_float("batch_f")
	local members = rockmech.account_members(rockmech.account_of(owner))
	local title = S("Trading day @1   @2 t", tostring(day + 1), ("%.1f"):format(bt))
	if dump then
		for _, m in ipairs(members) do
			rockmech.notify(m, bf > 0 and S("[Waste dump] Daily total: @1 t dumped, dumping fee −$@2", ("%.1f"):format(bt), ("%.0f"):format(bf))
				or S("[Waste dump] Daily total: @1 t dumped", ("%.1f"):format(bt)))
			if bf > 0 then
				show_bill(m, S("Waste dump daily statement   @1", title), {
					{S("Dumping fee"), ("%.1f t"):format(bt), ("$%g"):format(cfg.dump_fee), money_text(-bf), RED}})
			end
		end
	else
		local ore = ore_of(meta)
		local rows = {}
		local bw = meta:get_float("batch_w")
		-- 化學成分（褐鐵礦的鐵、金、有害雜質）另外列：主礦那一列只算主礦的貨款
		local bfe, bau, bh = meta:get_float("batch_fe"), meta:get_float("batch_au"), meta:get_float("batch_h")
		bg, bf = bg - bfe - bau, bf - bh
		if ore and ore.metal then
			-- 金屬礦：平均含銅量、貨款（精礦照含銅量、原礦外包選礦）
			local bc = meta:get_float("batch_cu")
			rows[#rows + 1] = {S("@1 (grade @2%)", S(ore.label), rockmech.grade_num(ore, bt > 0 and bc / bt / ore.metal.scale or 0)),
				("%.1f t"):format(bt), rockmech.price_str(ore, rockmech.ore_price(ore)), money_text(bg), GREEN}
		elseif ore then
			local r = rockmech.yard_ratio()
			rows[#rows + 1] = {S("@1 (grade @2%)", S(ore.label), ("%.0f"):format(100 * bq / bt)), ("%.1f t"):format(bq),
				("$%.0f × %.0f%%"):format(rockmech.ore_price(ore), rockmech.eff_ore_recovery(owner, ore) * 100) .. (r < 1 and (" × %.0f%%"):format(r * 100) or ""),
				money_text(bg), GREEN}
			if bw <= 0 then bw = bt - bq end          -- 舊存檔沒記廢料噸數
		end
		local E = cfg.elements
		if bfe > 0 then rows[#rows + 1] = {S(E.fe.label), "", ("$%g/t @ %.0f%%"):format(E.fe.price, E.fe.basis * 100), money_text(bfe), GREEN} end
		local ap = rockmech.gold_price and rockmech.gold_price() or E.au.price
		if bau > 0 then rows[#rows + 1] = {S(E.au.label), ("%.1f g"):format(bau / ap / E.au.recovery), ("$%.0f/g × %.0f%%"):format(ap, E.au.recovery * 100), money_text(bau), GREEN} end
		rows[#rows + 1] = {S("Waste disposal (@1)", rockmech.gangue_label(ore)), ("%.1f t"):format(bw), ("$%g"):format(rockmech.gangue_fee(ore)), money_text(-bf), RED}
		if bh > 0 then rows[#rows + 1] = {S(E.harm.label), "", ("$%g/t per 1%%"):format(E.harm.fee / 100), money_text(-bh), RED} end
		bg, bf = bg + bfe + bau, bf + bh
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
		rows[#rows + 1] = {S("Net income"), "", "", money_text(net), net >= 0 and GREEN or RED}
		for _, m in ipairs(members) do
			core.sound_play("rockmech_coin", {to_player = m, gain = 0.8}, true)
		end
		core.after(COIN_LEAD, function()
			for _, m in ipairs(members) do
				rockmech.notify(m, S("[Crusher] Daily total: @1 t, net income @2", ("%.1f"):format(bt), money_text(net)))
				show_bill(m, S("Crusher daily statement   @1", title), rows)
			end
		end)
	end
	for _, k in ipairs({"batch_t", "batch_q", "batch_g", "batch_f", "batch_m", "batch_w", "batch_cu", "batch_fe", "batch_au", "batch_h"}) do meta:set_float(k, 0) end
end

rockmech.show_bill, rockmech.money_text = show_bill, money_text     -- wages.lua 的人事費單子

-- 運作中的特效（附近有人才放）：一般破碎站從顎破出口（機身後面）噴出碎石；大型破碎廠房屋頂冒白色粉塵
local function crush_fx(pos, meta)
	local near = false
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), pos) < 48 then near = true; break end
	end
	if not near then return end
	local c = hopper_center(meta)
	local dx, dz = c.x - pos.x, c.z - pos.z
	if math.abs(dx) > math.abs(dz) then dx, dz = dx > 0 and 1 or -1, 0 else dx, dz = 0, dz > 0 and 1 or -1 end
	if core.get_node(pos).name == CRUSHER_BIG then
		core.add_particlespawner({amount = 6, time = STEP,
			minpos = {x = pos.x - 0.9, y = pos.y + 2.6, z = pos.z - 0.9}, maxpos = {x = pos.x + 0.6, y = pos.y + 3.0, z = pos.z + 0.9},
			minvel = {x = -0.2, y = 0.4, z = -0.2}, maxvel = {x = 0.2, y = 0.9, z = 0.2},
			minacc = {x = 0.05, y = 0.05, z = 0.05}, maxacc = {x = 0.15, y = 0.15, z = 0.15},
			minexptime = 3, maxexptime = 5, minsize = 5, maxsize = 10,
			texture = "[fill:4x4:#ececec^[opacity:140"})
	else
		-- 出料口在機身後面（受料倉的反方向）、平台上
		local o = {x = pos.x - dx * 0.7, y = pos.y + 0.9, z = pos.z - dz * 0.7}
		core.add_particlespawner({amount = 10, time = STEP,
			minpos = vector.subtract(o, 0.25), maxpos = vector.add(o, 0.25),
			minvel = {x = -dx * 1.2 - 0.4, y = 0.5, z = -dz * 1.2 - 0.4}, maxvel = {x = -dx * 2.4 + 0.4, y = 1.6, z = -dz * 2.4 + 0.4},
			minacc = {x = 0, y = -9.8, z = 0}, maxacc = {x = 0, y = -9.8, z = 0},
			minexptime = 0.5, maxexptime = 1.0, minsize = 0, maxsize = 0, collisiondetection = true,
			node = {name = rockmech.RUBBLE}})
		core.add_particlespawner({amount = 4, time = STEP,
			minpos = vector.subtract(o, 0.3), maxpos = vector.add(o, 0.3),
			minvel = {x = -0.2, y = 0.2, z = -0.2}, maxvel = {x = 0.2, y = 0.6, z = 0.2},
			minexptime = 1.0, maxexptime = 2.0, minsize = 2, maxsize = 4,
			texture = "[fill:4x4:#c8c0b4^[opacity:110"})
	end
end

local function crush(pos, dtime)
	local meta = core.get_meta(pos)
	local dump = meta:get_string("mode") == "dump"
	-- 這一步的帳：煤的噸數、煤的貨款（煤噸 × 價格 × 回收率 × 收購比例）、廢石處理費（廢石噸 × 每噸；廢石場是全部噸數 × 棄置費）
	-- 只收這座選的礦：別種礦和廢石一樣算廢石、照這種礦的廢石處理費扣
	local ore = ore_of(meta)
	local ore_t, gross, fee, waste, cu, xfe, xau, xh = 0, 0, 0, 0, 0, 0, 0, 0
	local eaten = eat(pos, dtime, rate_of(pos), nil, function(t, base, p2, ca)
		local tons = tons_of(t)
		local q, g, f, w, c, vfe, vau, hfee = rockmech.sale_value(tons, base, p2, ore, meta:get_string("owner"), ca)
		ore_t, cu = ore_t + q, cu + c
		if dump then fee = fee + tons * cfg.dump_fee
		else
			gross, fee, waste = gross + g, fee + f, waste + w
			xfe, xau, xh = xfe + vfe, xau + vau, xh + hfee
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
	crush_fx(pos, core.get_meta(pos))
	local t = tons_of(eaten)
	if income ~= 0 then rockmech.add_money(owner, income) end
	-- 剝採比（全組累計）：送來的料裡，礦石（照品位折算）和廢石各幾噸
	local acc = rockmech.account_of and rockmech.account_of(owner) or owner
	storage:set_float("strip_o:" .. acc, storage:get_float("strip_o:" .. acc) + ore_t)
	storage:set_float("strip_w:" .. acc, storage:get_float("strip_w:" .. acc) + math.max(0, t - ore_t))
	for key, v in pairs({batch_t = t, batch_q = ore_t, batch_g = gross, batch_f = fee, batch_m = income, batch_w = waste, batch_cu = cu,
			batch_fe = xfe, batch_au = xau, batch_h = xh,
			total_t = t, total_q = ore_t, total_g = gross, total_f = fee, total_m = income, total_cu = cu}) do
		meta:set_float(key, meta:get_float(key) + v)
	end
end

-- 剝採比 = 廢石噸數 ÷ 礦石噸數（全組累計，破碎站和廢石場送來的料）
function rockmech.strip_ratio(acc)
	local o, w = storage:get_float("strip_o:" .. acc), storage:get_float("strip_w:" .. acc)
	return o > 0 and w / o or nil, w, o
end
local function formspec(pos, viewer)
	local meta = core.get_meta(pos)
	local queue = hopper_levels(hopper_center(meta), size_of(meta))
	local total = meta:get_float("total_t")
	local dump = meta:get_string("mode") == "dump"
	local rate = rate_of(pos)
	-- 排隊：倉裡還有多少、照處理能力還要多久
	local qt = tons_of(queue)
	local queue_text = S("Queue @1 t, about @2 s to process", ("%.1f"):format(qt), tostring(math.ceil(qt / rate)))
	local ore = ore_of(meta)
	local prices = {S("@1 at 100% grade: $@2 per tonne today (base $@3), recovery @4%", S(ore.label), ("%.0f"):format(rockmech.ore_price(ore)),
		("%g"):format(ore.price), ("%.0f"):format(rockmech.eff_ore_recovery(meta:get_string("owner"), ore) * 100))}
	if ore.metal then        -- 金屬礦：銅價、精礦冶煉費、原礦外包選礦
		prices = {S("Copper @1 today (base @2)", rockmech.price_str(ore, rockmech.ore_price(ore)), rockmech.price_str(ore, ore.price))}
	end
	return table.concat({
		"formspec_version[6]size[11,8.4]",
		("label[0.5,0.6;%s]"):format(core.formspec_escape(dump and S("Waste dump (rubble dumped here is discarded, no income)") or title_of(pos))),
		("label[0.5,1.2;%s]"):format(core.formspec_escape(dump
			and S("Capacity: @1 t/s   Dumping fee: $@2 per tonne", ("%g"):format(rate), ("%g"):format(cfg.dump_fee))
			or S("Capacity: @1 t/s   @2: $@3 per tonne", ("%g"):format(rate), rockmech.gangue_label(ore), ("%g"):format(rockmech.gangue_fee(ore))))),
		("label[0.5,1.8;%s]"):format(core.formspec_escape(dump and S("Ore dumped here is also discarded as waste") or table.concat(prices, "; "))),
		("textarea[0.5,6.5;10,1;;;%s]"):format(core.formspec_escape(queue_text)),
		dump and "" or (rockmech.multi_ore() and ("label[0.5,4.9;%s]"):format(core.formspec_escape(S("Buys:"))) or "")
			.. rockmech.ore_dropdown(2.5, 4.5, 3.5, "ore", ore),
		("button[0.5,5.5;8,0.8;mode;%s]"):format(core.formspec_escape(dump and S("Switch to crusher (sell ore)")
			or S("Switch to waste dump (discard, $@1 per tonne)", ("%g"):format(cfg.dump_fee)))),
		("label[0.5,2.4;%s]"):format(core.formspec_escape(S("Hopper: @1 / @2 m³ (@3 t)", ("%.1f"):format(queue / V.NLEV),
			("%.0f"):format(capacity_of(size_of(meta)) / V.NLEV), ("%.1f"):format(tons_of(queue))))),
		("label[0.5,3.0;%s]"):format(core.formspec_escape(S("Total processed: @1 t, average grade @2%", ("%.1f"):format(total),
			ore.metal and rockmech.grade_num(ore, total > 0 and meta:get_float("total_cu") / total / ore.metal.scale or 0)
			or ("%.0f"):format(total > 0 and 100 * meta:get_float("total_q") / total or 0)))),
		("label[0.5,3.6;%s]"):format(core.formspec_escape(S("Totals: sales $@1 − gangue $@2 = net income $@3", ("%.0f"):format(meta:get_float("total_g")),
			("%.0f"):format(meta:get_float("total_f")), ("%.0f"):format(meta:get_float("total_m"))))),
		("label[0.5,4.2;%s]"):format(core.formspec_escape(S("Funds (@1): $@2", rockmech.account_label(meta:get_string("owner")),
			("%.0f"):format(rockmech.money(meta:get_string("owner")))))),
		(function()
			-- 剝採比：要有採礦規劃能力（knowledge.lua）
			if viewer and rockmech.can_see and not rockmech.can_see(viewer, "planning") then
				return "label[0.5,7.9;" .. core.formspec_escape(S("Stripping ratio: you need to learn mine planning to understand it")) .. "]"
			end
			local acc = rockmech.account_of and rockmech.account_of(meta:get_string("owner")) or meta:get_string("owner")
			local sr, w, o = rockmech.strip_ratio(acc)
			return ("label[0.5,7.9;%s]"):format(core.formspec_escape(sr and S("Stripping ratio @1 (waste @2 t ÷ ore @3 t, team total)", ("%.2f"):format(sr), ("%.0f"):format(w), ("%.0f"):format(o))
				or S("Stripping ratio: no ore delivered yet")))
		end)(),
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
		meta:set_string("infotext", meta:get_string("mode") == "dump" and S("Waste dump (right-click to view)") or S("@1 (right-click to view)", title_of(pos)))
		core.show_formspec(name, CRUSHER, formspec(pos, name))
	end
	local pick = fields.ore and rockmech.ore_from_field(fields.ore)
	if pick and rockmech.owner_ok(core.get_meta(pos):get_string("owner"), name) then
		local meta = core.get_meta(pos)
		if pick ~= ore_of(meta) then
			meta:set_string("ore", pick.key)
			if meta:get_string("mode") ~= "dump" then meta:set_string("infotext", S("@1 (right-click to view)", title_of(pos))) end
			core.show_formspec(name, CRUSHER, formspec(pos, name))
		end
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
	description = S("Hopper concrete lining"),
	short_description = S("Hopper lining"),
	tiles = {"[fill:16x16:#9a9890^[fill:16x1:0,7:#86847c^[fill:1x16:7,0:#86847c^[fill:2x2:3,3:#a8a69e^[fill:2x2:11,12:#8e8c84"},
	is_ground_content = false,
	groups = {not_in_creative_inventory = 1},
	drop = "",
})
-- 倉的範圍（meta 的 gx, gy, gz）：第 dy 層（倉口 dy = 0）是邊長 SIZE − 2·dy 的正方形
local function line_hopper(meta)
	local size = size_of(meta)
	local depth = depth_of(size)
	local c, half = hopper_center(meta), (size - 1) / 2
	local top = meta:get_int("gy") + depth
	local function cavity(x, y, z)
		local dy = top - y
		if dy < 0 or dy >= depth then return false end
		return math.max(math.abs(x - c.x), math.abs(z - c.z)) <= half - dy
	end
	-- 整個範圍先載入（倉壁可能跨到還沒載入的區塊）；還是讀到 ignore 就回傳 nil，下次載入再補
	core.load_area({x = c.x - half - 1, y = top - depth, z = c.z - half - 1}, {x = c.x + half + 1, y = top + 1, z = c.z + half + 1})
	local n, missing = 0, false
	for y = top - depth, top + 1 do
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

-- (x, z) 這一欄從 y 往下是不是受料倉（空氣、碎石往下找，碰到格柵或倉壁護坡就是）：原木倒進來當廢石（woodwork.lua）
function rockmech.in_hopper(x, z, y)
	for yy = y, y - 12, -1 do
		local n = core.get_node({x = x, y = yy, z = z}).name
		if n == GRATE or n == LINING then return true end
		if n ~= "air" and not rockmech.rubble_level[n] then return false end
	end
	return false
end

-- 倉裡原有的碎石不挖，之後逐欄疊到新的倉底（舊倉擴建）
local function dig_hopper(pos, dx, dz, size)
	size = size or size_for(core.get_node(pos).name)
	local depth = depth_of(size)
	local half = (size - 1) / 2
	local cx, cz = pos.x + dx * (2 + half), pos.z + dz * (2 + half)    -- 受料倉中心，緊貼機身
	local gy = pos.y - 1 - depth
	for dy = 0, depth - 1 do
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
	meta:set_int("size", size)
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
	local c, h = hopper_center(meta), (size_of(meta) - 1) / 2
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
local function site_ok(pos, dx, dz, size)
	size = size or SIZE
	local depth = depth_of(size)
	local half = (size - 1) / 2
	local cx, cz = pos.x + dx * (2 + half), pos.z + dz * (2 + half)    -- 受料倉中心，緊貼機身
	local function solid(p) return not V.passable(core.get_node(p).name) end
	for x = cx - half, cx + half do for z = cz - half, cz + half do
		if solid({x = x, y = pos.y, z = z}) then return false end
		for y = pos.y - 1 - depth, pos.y - 1 do
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

-- 在 pos 蓋破碎站（機身），受料倉朝 (dx, dz)。地不平回傳 false。force：不檢查地形（豎井底下埋在岩石裡的，oreshaft.lua）
function rockmech.crusher_build(pos, dx, dz, name, node, force)
	-- 範圍內不滿一格的土石先清掉（woodwork.lua）：不然機身架在薄片上
	-- 整地（woodwork.lua）：範圍內的土清到岩盤、低的回填，沒蓋成就復原
	local rec = not force and rockmech.clear_site and rockmech.facility_cells
		and rockmech.clear_site(rockmech.facility_cells(node or CRUSHER, pos, dx, dz), pos)
	local size = size_for(node or CRUSHER)
	if not force and (rec == false or not site_ok(pos, dx, dz, size)) then rockmech.site_undo(rec); return false end
	if rec then rockmech.site_charge(rec, name) end
	-- 進料溜槽、板式給料機朝受料倉（模型的 +Z 是進料那一側）
	core.set_node(pos, {name = node or CRUSHER, param2 = core.dir_to_facedir({x = dx, y = 0, z = dz})})
	dig_hopper(pos, dx, dz, size)
	local meta = core.get_meta(pos)
	local acc = rockmech.account_of(name)       -- 分了組就掛在組上，收入進整組的帳戶
	meta:set_string("owner", acc)
	meta:set_string("infotext", S("@1 (@2, right-click to view)", title_of(pos), rockmech.account_label(acc)))
	core.get_node_timer(pos):start(STEP)
	keep_loaded(pos)
	if not storage:contains(MONEY .. acc) then rockmech.add_money(acc, 0) end
	return true
end

-- 外觀：模型 models/rockmech_crusher(_big).obj（devtools/make_crusher_mesh.py 產生）。
--   一般破碎站：露天機台（鋼構底座、格柵平台、顎式破碎機、兩側飛輪、馬達、出料皮帶、扶手、朝受料倉的進料溜槽）；
--     tiles：鋼構、機身、平台、飛輪、馬達、皮帶、欄杆、溜槽
--   大型破碎站：破碎廠房（混凝土基座、浪板外牆、斜屋頂、窗帶、朝受料倉的捲門進料口、後面的出料皮帶廊道、集塵筒倉）；
--     tiles：基座、外牆、鋼柱、窗帶、屋頂、警示條、捲門、廊道、筒倉
local function tile(t) return {name = t, backface_culling = false} end
local T_FRAME = tile("[fill:16x16:#3a3e44^[fill:16x1:0,15:#2a2e34^[fill:1x16:15,0:#2a2e34")
local T_DECK = tile("[fill:16x16:#5c6064^[fill:16x1:0,3:#3a3c40^[fill:16x1:0,7:#3a3c40^[fill:16x1:0,11:#3a3c40^[fill:16x1:0,15:#3a3c40"
	.. "^[fill:1x16:3,0:#3a3c40^[fill:1x16:7,0:#3a3c40^[fill:1x16:11,0:#3a3c40^[fill:1x16:15,0:#3a3c40")
local T_WHEEL = tile("[fill:16x16:#2a2a2a^[fill:16x2:0,7:#5a5a5a^[fill:2x16:7,0:#5a5a5a^[fill:16x1:0,0:#4a4a4a")
local T_MOTOR = tile("[fill:16x16:#3a6aa0^[fill:16x1:0,3:#2a5080^[fill:16x1:0,7:#2a5080^[fill:16x1:0,11:#2a5080")
local T_BELT = tile("[fill:16x16:#1e1e1e^[fill:16x1:0,4:#3a3a3a^[fill:16x1:0,12:#3a3a3a")
local T_RAIL = tile("[fill:16x16:#f0c020")
local T_CHUTE = tile("[fill:16x16:#7a7468^[fill:16x1:0,8:#6a6458^[fill:3x2:4,3:#8a8478^[fill:2x3:11,10:#6a6458")
-- 板式給料機（倉底斜上到進料口）：一片片鋼板
local T_APRON = tile("[fill:16x16:#3a3a3a^[fill:16x2:0,0:#5a5a5a^[fill:16x2:0,8:#5a5a5a^[fill:16x1:0,7:#1a1a1a^[fill:16x1:0,15:#1a1a1a")
local BODY = "[fill:16x16:#d8a820^[fill:16x1:0,15:#a88010^[fill:1x16:15,0:#a88010^[fill:2x2:2,2:#a88010^[fill:2x2:12,2:#a88010"
local BOX = {type = "fixed", fixed = {-1.45, -0.5, -1.45, 1.45, 2.4, 1.45}}

core.register_node(GRATE, {
	description = S("Crusher grate"),
	tiles = {"[fill:16x16:#181818^[fill:16x3:0,1:#8a8a8a^[fill:16x3:0,9:#8a8a8a^[fill:3x16:1,0:#8a8a8a^[fill:3x16:9,0:#8a8a8a"},
	groups = {cracky = 2, not_in_creative_inventory = 1},
	is_ground_content = false,
	drop = "",
})

local crusher_def = {
	description = S("Crusher\nRight-click on flat ground to build"),
	short_description = S("Crusher"),
	drawtype = "mesh",
	mesh = "rockmech_crusher.obj",
	paramtype = "light",
	paramtype2 = "facedir",
	selection_box = BOX, collision_box = BOX,
	tiles = {T_FRAME, tile(BODY), T_DECK, T_WHEEL, T_MOTOR, T_BELT, T_RAIL, T_CHUTE, T_APRON},
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
			rockmech.notify(name, S("[Crusher] Place it on flat ground: the 3×3 m machine and the @1×@2 m area in front need level ground, solid rock below and clear space above",
				tostring(size_for(itemstack:get_name())), tostring(size_for(itemstack:get_name()))))
			return itemstack
		end
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	on_rightclick = function(pos, node, clicker)
		editing[clicker:get_player_name()] = pos
		core.show_formspec(clicker:get_player_name(), CRUSHER, formspec(pos, clicker:get_player_name()))
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
local function ribs(base, line, step)
	local t = {"[fill:16x16:" .. base}
	for x = 1, 15, step do t[#t + 1] = ("[fill:1x16:%d,0:%s"):format(x, line) end
	return table.concat(t, "^")
end
local PLANT_TILES = {
	tile("[fill:16x16:#9a9890^[fill:16x1:0,15:#86847c^[fill:1x16:15,0:#86847c"),                       -- 混凝土基座
	tile(ribs("#c8ccd0", "#a4a8ac", 3)),                                                            -- 浪板外牆
	tile("[fill:16x16:#3a3e44^[fill:16x1:0,15:#2a2e34"),                                            -- 鋼柱、鋼梁
	tile("[fill:16x16:#9fd0ff^[fill:1x16:0,0:#4a5058^[fill:1x16:8,0:#4a5058^[fill:16x1:0,0:#4a5058"),   -- 窗帶
	tile(ribs("#46607a", "#36506a", 4)),                                                            -- 屋頂浪板
	tile("[fill:16x16:#f0c020^[fill:4x16:0,0:#202020^[fill:4x16:8,0:#202020"),                      -- 黃黑警示條
	tile("[fill:16x16:#8a8e92^[fill:16x1:0,3:#6a6e72^[fill:16x1:0,7:#6a6e72^[fill:16x1:0,11:#6a6e72^[fill:16x1:0,15:#6a6e72"),   -- 捲門
	tile("[fill:16x16:#6e7278^[fill:16x1:0,0:#4a4e54^[fill:1x16:15,0:#4a4e54"),                     -- 皮帶廊道
	tile("[fill:16x16:#dcdcd6^[fill:16x1:0,8:#b8b8b0"),                                             -- 集塵筒倉
	T_APRON,                                                                                        -- 板式給料機
}
big.description = S("Large crusher\nRight-click on flat ground to build")
big.short_description = S("Large crusher")
big.inventory_image = "rockmech_icon_crusher_big.png"
big.mesh = "rockmech_crusher_big.obj"
big.tiles = PLANT_TILES
local BIG_BOX = {type = "fixed", fixed = {{-1.45, -0.5, -1.45, 1.45, 2.4, 1.45}, {-0.6, 2.4, -0.6, 0.6, 2.9, 0.6}}}
big.selection_box, big.collision_box = BIG_BOX, BIG_BOX
core.register_node(CRUSHER_BIG, big)

-- 舊的破碎站（蓋的時候還沒有朝向）：轉到受料倉那一邊
core.register_lbm({
	label = "rockmech: 破碎站轉向受料倉",
	name = "rockmech:crusher_face_hopper3",
	nodenames = {CRUSHER, CRUSHER_BIG},
	run_at_every_load = false,
	action = function(pos, node)
		local meta = core.get_meta(pos)
		if meta:get_string("gx") == "" then return end
		local c = hopper_center(meta)
		local dx, dz = c.x - pos.x, c.z - pos.z
		if math.abs(dx) > math.abs(dz) then dx, dz = dx > 0 and 1 or -1, 0 else dx, dz = 0, dz > 0 and 1 or -1 end
		local p2 = core.dir_to_facedir({x = dx, y = 0, z = dz})
		if node.param2 ~= p2 then core.swap_node(pos, {name = node.name, param2 = p2}) end
	end,
})

-- 舊版小倉擴建成現在的大小：舊格柵回填成下面的岩石，再照新尺寸挖（倉裡的碎石留著，疊到新的倉底）
local function enlarge(pos)
	local meta = core.get_meta(pos)
	if core.get_node(pos).name ~= CRUSHER or meta:get_int("size") >= SMALL_SIZE then return end
	local old = hopper_center(meta)
	local dx, dz = 0, 0
	if math.abs(old.x - pos.x) > math.abs(old.z - pos.z) then dx = old.x > pos.x and 1 or -1
	else dz = old.z > pos.z and 1 or -1 end
	local reach = 2 + SIZE
	core.load_area({x = pos.x - reach, y = pos.y - DEPTH - 2, z = pos.z - reach}, {x = pos.x + reach, y = pos.y + PILE, z = pos.z + reach})
	for _, c in ipairs(grate_cells(meta)) do
		core.swap_node(c, core.get_node({x = c.x, y = c.y - 1, z = c.z}))
	end
	dig_hopper(pos, dx, dz, SMALL_SIZE)
	core.log("action", ("[rockmech] 受料倉擴建成 %d×%d m：機身 %s"):format(SMALL_SIZE, SMALL_SIZE, core.pos_to_string(pos)))
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
	SIZE = SIZE, size_for = size_for, PILE = PILE, STEP = STEP, GRATE = GRATE, tons_of = tons_of, eat = eat,
	hopper_center = hopper_center, hopper_levels = hopper_levels, grate_cells = grate_cells, dig_hopper = dig_hopper,
	site_ok = site_ok, keep_loaded = keep_loaded, each_block = each_block,
}
