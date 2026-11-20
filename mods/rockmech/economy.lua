-- rockmech/economy.lua
-- 錢和市場（原本在 crusher.lua，2026-11-20 搬出來）：帳戶、資金、右上角資金 HUD、礦價（交易日開盤）、
-- 賣礦計價（rockmech.sale_value：收煤站、豎井、火車共用）、研究等級和 rockmech.eff_* 係數、碎石的噸數。
-- 破碎站、火車、訂單、薪水、電廠存煤都呼叫這裡；這支不碰任何方塊。

local cfg = rockmech.cfg
local S = rockmech.S
local V = rockmech.vehicles
local storage = rockmech.collapse.storage

local MONEY = "money:"      -- mod storage 的鍵

-- 碎石的噸數（計價、顯示用）：1/8 m³ 一級，密度 rockmech_rubble_density（t/m³，預設 2.5）。車輛載重的物理照舊
function rockmech.tons_of(levels) return levels / V.NLEV * (cfg.rubble_density or 2.5) end

-- 收煤站付市價的幾成：有火車（教學地圖）才打折，火車照原價收
function rockmech.yard_ratio()
	return rockmech.train_enabled and rockmech.train_enabled() and cfg.coal_yard_ratio or 1
end

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
-- 一般的礦（煤、大理岩）tons 噸、品位 g：貨款（礦噸 × 回收率 × 價格 × 收購比例 ratio）、廢料處理費（廢料噸 × 每噸）。
-- 收煤站（ratio = yard_ratio）和火車（ratio = 1，train.lua、trainline.lua）共用
function rockmech.coal_value(tons, g, ore, owner, ratio)
	return tons * g * rockmech.eff_ore_recovery(owner, ore) * rockmech.ore_price(ore) * (ratio or 1),
		tons * (1 - g) * rockmech.gangue_fee(ore)
end
function rockmech.sale_value_main(tons, base, p2, ore, owner)
	local m = ore and ore.metal
	if not m then
		local g = rockmech.grade_for(base, p2, ore)
		local gross, fee = rockmech.coal_value(tons, g, ore, owner, rockmech.yard_ratio())
		return tons * g, gross, fee, tons * (1 - g), 0
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
-- 勻滑開炸（平滑爆破）：鑽堡的孔記下設計底板，炸完地板平整、可以開下坡坑道（vehicle_jumbo.lua）。沒有研發的地圖（非經營模式）直接有
function rockmech.eff_smooth_blast(owner)
	return not rockmech.cfg.career or rockmech.research_level(owner, "smooth_blast") >= 1
end
-- 推土機推力：松土的可裂性門檻（岩體強度 σcm）每級 +20%（vehicle_dozer.lua）
function rockmech.eff_rip_sigcm(owner) return rockmech.cfg.dozer_rip_sigcm * (1 + 0.2 * rockmech.research_level(owner, "dozer_thrust")) end
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
	if rockmech.power_text then text = text .. "\n" .. rockmech.power_text() end      -- 電廠存煤（powerplant.lua）
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
