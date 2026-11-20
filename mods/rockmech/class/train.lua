-- rockmech/class/train.lua（教學地圖才載入）
-- 這支只管軌道（東西向的直線、每組一段、裝車點、路權）；車廂、機車、班次、結帳、視窗是共用的 traincore.lua。
-- 火車出貨（原型，只在教學地圖：分組礦帶）：營地南邊的走廊鋪一條東西向的鐵路（每組礦帶一段，連起來貫穿全圖）。
-- 火車是賣礦的管道（不是訂單）：上班時間（HOURS，08:00–20:00）一直有車，晚上沒車 → 學生要自己堆料（倉儲）。
--   一列 N 節車廂（每節 CAP_M3 m³）從礦帶西邊開進來，停在裝車點（黃黑標示柱，每節一根）不動；
--   N 節都裝滿就開走，下一班馬上從西邊開進來。按「現在出發」帶著已經裝的先走；20:00 還沒滿就帶著已經裝的開走。
--   裝車：裝車料斗（放料臂 10 m）、怪手直接裝、卡車在車廂旁邊倒（orders.lua 的倒料對準）。
--   時鐘：教學地圖的天色跟交易日走：開盤 06:00，一個交易日 24 小時，晚上會暗（不管 time_speed 設多少；不改設定檔）。
--   出發時每節結帳（跟收煤站同一套，但照原價）：煤噸 × 回收率 × 當天煤價 − 廢石噸 × 廢石處理費。
--   收煤站只付 cfg.coal_yard_ratio（坑口價），火車照原價，但要配合班次、湊滿一列。
-- 鐵路和兩側路肩是路權（camp.lua 的保護）：不能挖、不能蓋、炸不壞，往下 10 m 也不能挖；卡車可以直接開過去。
--   碎石滾到軌道上會擋住火車（停下來等清），要自己清。
-- 列車是畫面：狀態（位置、每節的料）存在 mod storage，附近有人才放出來，沒人就收掉（不存進地圖）。

local S = rockmech.S
local cfg = rockmech.cfg
local storage = rockmech.collapse.storage
local O = rockmech.orders

local lanes = cfg.coal_seam and cfg.coal_seam.lane_w
if not (cfg.career and cfg.teacher and lanes and O) then return end

local RAIL_Z = -80                               -- 鐵路中心線的 z
local LOAD_REL = -26                             -- 裝車點＝第 1 節（相對營地中心 x0）：收料區（x0−17..−11）的西邊，4 節的北邊都是空地
local LINE = {x1 = -(cfg.career_camp_dx or 0) - lanes / 2, x2 = -(cfg.career_camp_dx or 0) + lanes / 2 - 1}   -- 這一組礦帶的那一段
local T = rockmech.traincore                     -- traincore.lua：車廂、機車、班次、結帳、視窗
local N, L_LOCO, PITCH = T.N, T.L_LOCO, T.PITCH   -- 車廂數、機車長、車廂間距（中心到中心）
local HOURS = {8, 20}                            -- 上班時間：這段時間一直有車
local NEAR = 96                                  -- 離裝車點多近有人才放出列車
local YAW = -math.pi / 2                         -- 車頭朝 +x
local RAIL, BALLAST, MARK = "rockmech:rail", "rockmech:rail_ballast", "rockmech:rail_marker"

local function site_of(acc) return O.site_of(acc) end
local function rail_y() return O.sy() + 1 end                -- 軌道方塊的 y
local function load_x(x0) return x0 + LOAD_REL + 0.5 end
local function stop_head(x0) return load_x(x0) + L_LOCO + PITCH / 2 end   -- 停好時的車頭 x：第 1 節在裝車點，後面幾節往西排
local function wagon_x(x0, i) return math.floor(load_x(x0) - (i - 1) * PITCH) end   -- 停好時第 i 節的中心（標示柱的 x）

-- 現在幾點（0～24）：教學地圖的時鐘跟交易日走（開盤 06:00，一個交易日 24 小時），天色也照這個（下面每秒對一次）
local function hour()
	local p = cfg.price_period
	local into = core.get_gametime() - rockmech.market_day() * p
	return (6 + 24 * into / p) % 24
end
local function in_hours()
	local h = hour()
	return h >= HOURS[1] and h < HOURS[2]
end
local function start_head(x0) return x0 + LINE.x1 + 2 + L_LOCO + N * PITCH end
local function end_head(x0) return x0 + LINE.x2 - 1 end

---------------------------------------------------------------------------
-- 方塊：軌道、路肩、裝車點標示柱
---------------------------------------------------------------------------

local function noop() end
local BAL = "[fill:16x16:#7a746c^[fill:2x2:3,3:#5e5850^[fill:2x2:10,6:#8e887e^[fill:2x2:6,11:#5e5850^[fill:1x1:13,13:#9a948a"
core.register_node(RAIL, {
	description = S("Railway track"),
	-- 頂面：碎石道碴、枕木（橫的）、兩條鋼軌（沿 x）
	tiles = {BAL .. "^[fill:3x16:1,0:#5a4030^[fill:3x16:9,0:#5a4030^[fill:16x2:0,3:#9aa0a6^[fill:16x1:0,4:#5a5e64"
		.. "^[fill:16x2:0,11:#9aa0a6^[fill:16x1:0,12:#5a5e64", BAL},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
core.register_node(BALLAST, {
	description = S("Track ballast"), tiles = {BAL},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
core.register_node(MARK, {
	description = S("Loading point"),
	drawtype = "nodebox", paramtype = "light", sunlight_propagates = true,
	node_box = {type = "fixed", fixed = {{-0.12, -0.5, -0.12, 0.12, 1.3, 0.12}, {-0.35, 1.0, -0.06, 0.35, 1.45, 0.06}}},
	tiles = {"[fill:16x16:#e0b428^[fill:16x4:0,0:#202020^[fill:16x4:0,8:#202020"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
	on_rightclick = function(pos, node, clicker)
		if clicker and clicker:is_player() then rockmech.notify(clicker:get_player_name(), S("[Train] Loading point: wagons stop here")) end
	end,
})

-- 鋪鐵路：這一組礦帶那一段。地面那一層換成軌道（中線）和路肩（兩側），上面清空
local function lay(x0)
	local y = rail_y()
	for x = x0 + LINE.x1, x0 + LINE.x2 do
		for dz = -1, 1 do
			local z = RAIL_Z + dz
			core.set_node({x = x, y = y, z = z}, {name = dz == 0 and RAIL or BALLAST})
			for yy = y + 1, y + 6 do
				local p = {x = x, y = yy, z = z}
				if core.get_node(p).name ~= "air" then core.remove_node(p) end
			end
			for yy = y - 1, y - 3, -1 do
				local p = {x = x, y = yy, z = z}
				local d = core.registered_nodes[core.get_node(p).name]
				if d and d.walkable ~= false then break end
				core.set_node(p, {name = BALLAST})
			end
		end
	end
	storage:set_string("rail:" .. x0, "1")
	core.log("action", ("[rockmech] 營地 x = %d 鋪好鐵路"):format(x0))
end
-- 每節一根標示柱（舊的世界：舊位置的柱子先拔掉，再照現在的節數、裝車點重插）
local POSTS_VER = N .. "@" .. LOAD_REL
local function posts(x0)
	local y = rail_y()
	for x = x0 + LINE.x1, x0 + LINE.x2 do
		local p = {x = x, y = y + 1, z = RAIL_Z - 2}
		if core.get_node(p).name == MARK then core.remove_node(p) end
	end
	for i = 1, N do core.set_node({x = wagon_x(x0, i), y = y + 1, z = RAIL_Z - 2}, {name = MARK}) end
	storage:set_string("rail_posts:" .. x0, POSTS_VER)
end
core.after(6, function()
	for _, x0 in ipairs(O.sites()) do
		if storage:get_string("rail:" .. x0) == "1" and storage:get_string("rail_posts:" .. x0) ~= POSTS_VER then
			local y = rail_y()
			core.emerge_area({x = x0 + LINE.x1, y = y, z = RAIL_Z - 3}, {x = x0 + LINE.x2, y = y + 2, z = RAIL_Z - 1}, function(_, _, rem)
				if rem == 0 then posts(x0) end
			end)
		elseif storage:get_string("rail:" .. x0) ~= "1" then
			local y = rail_y()
			core.emerge_area({x = x0 + LINE.x1, y = y - 4, z = RAIL_Z - 3}, {x = x0 + LINE.x2, y = y + 7, z = RAIL_Z + 2}, function(_, _, rem)
				if rem > 0 or storage:get_string("rail:" .. x0) == "1" then return end
				local col = rockmech.collapse
				col.quiet = col.quiet + 1
				local ok, err = pcall(function() lay(x0); posts(x0) end)
				col.quiet = col.quiet - 1
				if not ok then core.log("error", "[rockmech] rail: " .. tostring(err)) end
			end)
		end
	end
end)
-- 路權：軌道、兩側路肩、標示柱那一排
rockmech.camp.protect({x1 = LINE.x1, x2 = LINE.x2, z1 = RAIL_Z - 2, z2 = RAIL_Z + 1})

---------------------------------------------------------------------------
-- 列車（traincore.lua）：每組一列，車頭沿 x 往東開
---------------------------------------------------------------------------

local KEYS = {}
for i = 0, cfg.career_teams or 0 do KEYS[#KEYS + 1] = "team:" .. i end   -- 0 = 老師組（出生點的營地）
local function players_near(p)
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) < NEAR then return true end
	end
	return false
end
local debug = {}
local line = T.line({
	id = "class",
	keys = function() return KEYS end,
	skey = function(acc) return "train:" .. acc end,
	uid = function(acc, i) return ("train-%s-%d"):format(acc, i) end,
	-- 組員不在線也照樣跑班次；鐵路還沒鋪、帳戶還沒開就不跑
	ready = function(acc)
		local x0 = site_of(acc)
		return x0 ~= nil and storage:get_string("rail:" .. x0) == "1" and rockmech.has_account(acc)
	end,
	pose = function(acc, s) return s, RAIL_Z + 0.5, rail_y() + 0.5, YAW end,
	s_start = function(acc) return start_head(site_of(acc)) end,
	s_stop = function(acc) return stop_head(site_of(acc)) end,
	s_end = function(acc) return end_head(site_of(acc)) end,
	-- 裝車點附近有人才放出畫面（force：測試用）
	active = function(acc)
		local lp = {x = load_x(site_of(acc)), y = rail_y(), z = RAIL_Z}
		return (debug.force or players_near(lp)) and core.get_node(lp).name ~= "ignore"
	end,
	-- 車頭前面 2 m 的軌道上方有東西（碎石…）
	blocked = function(acc, st)
		local y = rail_y() + 1
		for dx = 0, 2 do
			local n = core.get_node({x = math.floor(st.head + dx + 0.5), y = y, z = RAIL_Z}).name
			if not rockmech.air_like(n) and n ~= "ignore" then return n end
		end
	end,
	payer = function(acc) return acc end,
	wagon_owner = function(acc) return acc end,
	owns = function(acc, a) return acc == a end,
	hours = HOURS, hour = hour,
	tick = function() core.set_timeofday(hour() / 24) end,    -- 天色跟教學地圖的時鐘走
	migrate = function(st) if st.phase == "coming" then st.phase = "in" end end,   -- 舊版的狀態
})
function rockmech.train_remove(acc) line.remove(acc) end
debug.spawn, debug.despawn, debug.states, debug.stop_head, debug.load_x = line.spawn, line.despawn, line.states, stop_head, load_x
debug.RAIL_Z, debug.LINE, debug.hour, debug.in_hours, debug.N = RAIL_Z, LINE, hour, line.in_hours, N
debug.depart = line.depart
rockmech.train_debug = debug
