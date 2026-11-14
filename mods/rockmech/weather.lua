-- rockmech/weather.lua
-- 降雨：老師用 /rain <時雨量 mm/h> [分鐘] 下雨。降雨弱化跟時雨量 I 成正比（L = I / rain_max，rain_max = 100 mm/h，
-- 台灣颱風的時雨量量級）：
--   鬆土、崩積土：殘餘摩擦角降低 rain_drop × L × 土的比例（collapse.lua granular_settle，rockmech.rain_tan_for）
--   表土：凝聚力 c 降成 c × (1 − rain_c_loss × L)，自立高度 H_c 跟著降（woodwork.lua，rockmech.rain_level），
--         下雨時抽查露出來的表土陡壁，超過當下的 H_c 就鬆掉、照殘餘摩擦角流，可能連成邊坡滑動
-- 碎石（岩石碎塊）透水、不受影響。雨停馬上回到原本的強度。
-- 氣象站（rockmech:rain_gauge，工具室管理員）：指著看目前的時雨量、這場雨的累積雨量。
-- 畫面：每個玩家身邊下雨（粒子，雨越大越密）、雲變厚變灰。雨的狀態存在 mod storage，伺服器重開照樣下完

local S = rockmech.S
local function g(x) return ("%g"):format(x) end
local function f0(x) return ("%.0f"):format(x) end
local store = core.get_mod_storage()
local cfg = rockmech.cfg.slope
local RAIN_MAX = math.max(1, cfg.rain_max or 100)
local DEFAULT_MIN = 30

local spawners = {}         -- 玩家名稱 → {id, 時雨量}
local clouds = {}           -- 玩家名稱 → 下雨前的雲設定

local function rain_end() return store:get_int("rain_end") end
local function raining() return rain_end() > core.get_gametime() end
-- 目前的時雨量 (mm/h)，沒下雨是 0
local function intensity() return raining() and store:get_float("rain_i") or 0 end
function rockmech.raining() return raining() end
function rockmech.rain_intensity() return intensity() end
-- 降雨程度 L = I / rain_max（0..1）
function rockmech.rain_level() return math.min(1, (rockmech.rain_i_now or 0) / RAIN_MAX) end
-- 這場雨到現在的累積雨量 (mm)：之前各段（時雨量改過）累積的 rain_acc，加上這一段 時雨量 × 時間
function rockmech.rain_total()
	local t0 = store:get_int("rain_start")
	if t0 <= 0 then return 0 end
	local t1 = math.min(core.get_gametime(), rain_end())
	return store:get_float("rain_acc") + math.max(0, t1 - t0) / 3600 * store:get_float("rain_i")
end
-- 土佔 s（0..1）的碎石，下雨時的殘餘摩擦角 tan（沒下雨回傳 nil）：降低 rain_drop × L × s 度
function rockmech.rain_tan_for(s)
	local L = rockmech.rain_level()
	if L <= 0 then return nil end
	return math.tan(math.rad(math.max(1, cfg.phi_r - math.max(0, cfg.rain_drop) * L * s)))
end

local function start_fx(player, i)
	local name = player:get_player_name()
	local sp = spawners[name]
	if sp and sp.i == i then return end
	if sp then core.delete_particlespawner(sp.id) end
	-- 雨越大：雨滴越多、越粗越長、掉得越快、越不透明；雲越厚越暗（L = I / rain_max）
	local L = math.min(1, i / RAIN_MAX)
	local v = 10 + 10 * L
	spawners[name] = {i = i, id = core.add_particlespawner({
		amount = math.floor(30 + 870 * L), time = 0, attached = player,
		minpos = {x = -12, y = 8, z = -12}, maxpos = {x = 12, y = 10, z = 12},
		minvel = {x = 0, y = -v, z = 0}, maxvel = {x = 0, y = -v * 0.85, z = 0},
		minexptime = 0.9, maxexptime = 1.1, minsize = 0.6 + 0.8 * L, maxsize = 0.9 + 1.2 * L,
		collisiondetection = true, collision_removal = true, vertical = true,
		texture = ("[fill:1x%d:#a8c0e0%02x"):format(math.floor(6 + 6 * L), math.floor(120 + 110 * L)), playername = name,
	})}
	clouds[name] = clouds[name] or player:get_clouds()
	local g = math.floor(0xb0 - 0x50 * L)
	player:set_clouds({density = 0.5 + 0.45 * L, color = ("#%02x%02x%02xf0"):format(g, g + 6, g + 14), height = 90, thickness = 16 + 32 * L})
end

local function stop_fx(player)
	local name = player:get_player_name()
	if spawners[name] then core.delete_particlespawner(spawners[name].id); spawners[name] = nil end
	if clouds[name] then player:set_clouds(clouds[name]); clouds[name] = nil end
end

-- 狀態跟畫面同步（每 2 秒，加上 /rain 當下）
local was
local function sync()
	local i = intensity()
	local on = i > 0
	rockmech.rain_i_now = i
	rockmech.raining_now = on
	rockmech.rain_tan = on and rockmech.rain_tan_for(1) or nil
	for _, p in ipairs(core.get_connected_players()) do
		if on then start_fx(p, i) else stop_fx(p) end
	end
	if was ~= nil and was ~= on then
		rockmech.notify_all(on and S("It starts raining (@1 mm/h): soil is getting weaker, watch the slopes.", g(i))
			or S("The rain has stopped (@1 mm in total).", f0(rockmech.rain_total())))
	end
	was = on
end
local t = 0
core.register_globalstep(function(dtime)
	t = t + dtime
	if t < 2 then return end
	t = 0
	sync()
end)
core.register_on_joinplayer(function(player) if raining() then start_fx(player, intensity()) end end)
core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	spawners[name], clouds[name] = nil, nil       -- 粒子跟著玩家一起消失
end)

core.register_chatcommand("rain", {
	params = S("<rainfall mm/h> [minutes] | off"),
	description = S("Rain at intensity I mm/h (max @1, typhoon level), @2 minutes by default. Soil weakening is proportional to I. /rain off stops it; no argument shows the current state.",
		g(RAIN_MAX), tostring(DEFAULT_MIN)),
	privs = {rockmech = true},
	func = function(name, param)
		param = (param or ""):trim()
		local now = core.get_gametime()
		if param == "" then
			if not raining() then return true, S("It is not raining.") end
			return true, S("Raining: @1 mm/h, @2 minutes left, @3 mm so far.", g(intensity()),
				("%.1f"):format((rain_end() - now) / 60), f0(rockmech.rain_total()))
		end
		if param == "off" then
			store:set_int("rain_end", now)
			sync()
			return true, S("Rain stopped.")
		end
		local a, b = param:match("^(%S+)%s*(%S*)$")
		local i, m = tonumber(a), tonumber(b ~= "" and b or DEFAULT_MIN)
		if not i or i <= 0 or not m or m <= 0 then return false, S("Usage: /rain <rainfall mm/h> [minutes], e.g. /rain 60 20; /rain off to stop") end
		i = math.min(i, RAIN_MAX)
		-- 新的一場從 0 累積；下雨中改時雨量：前一段先記進 rain_acc
		if raining() then store:set_float("rain_acc", rockmech.rain_total()) else store:set_float("rain_acc", 0) end
		store:set_int("rain_start", now)
		store:set_float("rain_i", i)
		store:set_int("rain_end", now + math.floor(m * 60))
		sync()
		local L = i / RAIN_MAX
		return true, S("Rain for @1 minutes at @2 mm/h: loose soil residual friction angle @3° → @4°, topsoil cohesion × @5", g(m), g(i), g(cfg.phi_r),
			("%.1f"):format(math.max(1, cfg.phi_r - cfg.rain_drop * L)), ("%.2f"):format(1 - (cfg.rain_c_loss or 0) * L))
	end,
})

-- 氣象站：百葉箱（四支腳撐著白色百葉木箱，上面一片屋頂）。設施（放的時候薄土推到旁邊），指著看目前的雨量
local GAUGE = "rockmech:rain_gauge"
local function gauge_text()
	local i = intensity()
	if i <= 0 then
		local tot = rockmech.rain_total()
		return tot > 0 and S("Weather station\nNot raining (last rain: @1 mm in total)", f0(tot)) or S("Weather station\nNot raining")
	end
	return S("Weather station\nRainfall @1 mm/h\n@2 mm so far", g(i), f0(rockmech.rain_total()))
end
core.register_node(GAUGE, {
	description = S("Weather station"),
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir", sunlight_propagates = true,
	node_box = {type = "fixed", fixed = {
		{-0.32, -0.5, -0.27, -0.26, 0.05, -0.21}, {0.26, -0.5, -0.27, 0.32, 0.05, -0.21},   -- 四支腳
		{-0.32, -0.5, 0.21, -0.26, 0.05, 0.27}, {0.26, -0.5, 0.21, 0.32, 0.05, 0.27},
		{-0.35, 0.05, -0.3, 0.35, 0.42, 0.3},                -- 百葉箱
		{-0.42, 0.42, -0.37, 0.42, 0.5, 0.37},               -- 屋頂
	}},
	selection_box = {type = "fixed", fixed = {-0.42, -0.5, -0.37, 0.42, 0.5, 0.37}},
	-- 白色木箱，側面一條條斜百葉（深一點的灰線），屋頂白色
	tiles = {"[fill:16x16:#f2f2ee", "[fill:16x16:#e8e8e2",
		"[fill:16x16:#f2f2ee^[fill:16x1:0,2:#b8b8b0^[fill:16x1:0,5:#b8b8b0^[fill:16x1:0,8:#b8b8b0^[fill:16x1:0,11:#b8b8b0^[fill:16x1:0,14:#b8b8b0"},
	is_ground_content = false, groups = {cracky = 3, oddly_breakable_by_hand = 2, dig_immediate = 2},
	on_construct = function(pos)
		core.get_meta(pos):set_string("infotext", gauge_text())
		core.get_node_timer(pos):start(5)
	end,
	on_timer = function(pos)
		core.get_meta(pos):set_string("infotext", gauge_text())
		return true
	end,
})
core.register_lbm({
	label = "rockmech: 氣象站更新", name = "rockmech:rain_gauge_timer", nodenames = {GAUGE}, run_at_every_load = true,
	action = function(pos) if not core.get_node_timer(pos):is_started() then core.get_node_timer(pos):start(5) end end,
})
