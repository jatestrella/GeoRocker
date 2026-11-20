-- rockmech/trainline.lua
-- 單機地圖的鐵路（cfg.railway）：線形在 railline.lua，地圖產生時就挖好路塹、路堤、隧道、鋪好鋼軌（mapgen.lua）。
-- 列車從北邊的隧道開出來，沿著曲線開到裝車點（黃黑標示柱，每節一根，在小鎮那一側）停好；
--   N 節都裝滿就往南開進隧道，下一班再從北邊來。按「現在出發」帶著已經裝的先走；晚上（20:00）還沒滿也帶著走。
--   上班時間 HOURS 一直有車，晚上沒車。
-- 出發時每節結帳：煤噸 × 回收率 × 當天煤價 − 廢石噸 × 廢石處理費（跟收煤站同一套，但照原價；收煤站只付 coal_yard_ratio）。
-- 鐵路、道床、隧道是路權：不能挖、不能蓋（碎石可以清）；路塹的邊坡可以挖，挖垮了碎石掉到軌道上會擋住火車。
-- 這支只管軌道（線形、方塊、路權）；車廂、機車、班次、結帳、視窗是共用的 traincore.lua。
-- 教學地圖的火車是 class/train.lua（直線、分組礦帶），兩個不會同時開。

local S = rockmech.S
local cfg = rockmech.cfg
if not (cfg.railway and cfg.career and not cfg.teacher) then return end
local R = dofile(rockmech.modpath .. "/railline.lua")
local T = rockmech.traincore              -- traincore.lua：車廂、機車、班次、結帳、視窗
assert(R.N == T.N and R.L_LOCO == T.L_LOCO and R.PITCH == T.PITCH, "railline.lua 的列車尺寸要跟 traincore.lua 一樣")

local HOURS = {7, 20}                            -- 上班時間
local NEAR = 110                                 -- 列車離玩家多近才放出畫面
local BED, LINING, POST = "rockmech:railbed", "rockmech:tunnel_lining", "rockmech:rail_post"
local SEG = "rockmech:rail_seg_"

---------------------------------------------------------------------------
-- 方塊：道床、隧道襯砌、鋼軌（模型，8 種橫向偏移 × degrotate 轉角）、裝車點標示柱
---------------------------------------------------------------------------

local function noop() end
local BAL = "[fill:16x16:#7a746c^[fill:2x2:3,3:#5e5850^[fill:2x2:10,6:#8e887e^[fill:2x2:6,11:#5e5850^[fill:1x1:13,13:#9a948a"
core.register_node(BED, {
	description = S("Track ballast"), tiles = {BAL},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
core.register_node(LINING, {
	description = S("Tunnel lining"),
	tiles = {"[fill:16x16:#9c988f^[fill:16x1:0,7:#86827a^[fill:1x8:7,0:#86827a^[fill:1x8:15,8:#86827a"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
local RAIL_SET = {}
for k = 0, 7 do
	core.register_node(SEG .. k, {
		description = S("Railway track"),
		drawtype = "mesh", mesh = "rockmech_rail_o" .. k .. ".obj",
		tiles = {{name = "[fill:16x16:#8e949a^[fill:16x4:0,0:#b4bac0", backface_culling = false},
			{name = "[fill:16x16:#5a4030^[fill:16x2:0,7:#4a3326", backface_culling = false}},
		paramtype = "light", paramtype2 = "degrotate", sunlight_propagates = true,
		walkable = false, pointable = false, diggable = false, buildable_to = false,
		selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.3, 0.5}},
		is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop, drop = "",
	})
	RAIL_SET[SEG .. k] = true
end
core.register_node(POST, {
	description = S("Loading point"),
	drawtype = "nodebox", paramtype = "light", sunlight_propagates = true,
	node_box = {type = "fixed", fixed = {{-0.12, -0.5, -0.12, 0.12, 1.3, 0.12}, {-0.35, 1.0, -0.06, 0.35, 1.45, 0.06}}},
	tiles = {"[fill:16x16:#e0b428^[fill:16x4:0,0:#202020^[fill:16x4:0,8:#202020"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
	on_rightclick = function(pos, node, clicker)
		if clicker and clicker:is_player() and rockmech.train_form then
			rockmech.train_form(rockmech.account_of(clicker:get_player_name()), clicker)
		end
	end,
})

-- 線形（第一次用到才算：地形函數要等 stress 都載入）
local line
local function L()
	line = line or R.for_cfg(cfg, rockmech.stress)
	return line
end
-- 弧長 s 的位置、yaw（y：軌面 = 道床頂）
local function at(s)
	local l = L()
	local x, z, y, yaw = l:at(s)
	return x, z, l.sy + y + 0.5, yaw
end

---------------------------------------------------------------------------
-- 路權：道床、鋼軌、隧道（中線兩側 FW + 襯砌，軌面下 8 m 到上 7 m）不能挖、不能放；碎石可以清
---------------------------------------------------------------------------

local function rail_protected(pos, name)
	local l = L()
	if not l then return false end
	local z = math.floor(pos.z + 0.5)
	local d, row = l:lateral(pos.x, z)
	if not d or math.abs(d) > R.FW + R.LINING + 0.5 then return false end
	local yr = l.sy + row.yr
	if pos.y < yr - 8 or pos.y > yr + R.H + 1 then return false end
	if name and name ~= "" and core.check_player_privs(name, {rockmech = true}) then return false end
	if rockmech.rubble_level[core.get_node(pos).name] then return false end
	return true
end
rockmech.rail_protected = rail_protected
local old_protected = core.is_protected
function core.is_protected(pos, name)
	if rail_protected(pos, name) then return true end
	return old_protected(pos, name)
end
local last_warn = {}
core.register_on_protection_violation(function(pos, name)
	if not rail_protected(pos, name) then return end
	local now = core.get_us_time()
	if last_warn[name] and now - last_warn[name] < 3e6 then return end
	last_warn[name] = now
	rockmech.notify(name, S("Railway: nothing can be built or dug here"))
end)

---------------------------------------------------------------------------
-- 列車（traincore.lua）：一列，車頭沿線形的弧長往南開
---------------------------------------------------------------------------

local KEYS = {""}
-- 單機：錢記在單機帳戶；多人競爭：記在離裝車點最近的玩家
local function payer()
	local px, pz, py = at(L().s_load)
	local best, bd
	for _, p in ipairs(core.get_connected_players()) do
		local d = vector.distance(p:get_pos(), {x = px, y = py, z = pz})
		if not bd or d < bd then best, bd = p:get_player_name(), d end
	end
	return best and rockmech.account_of(best)
end
-- 列車（車頭後面 20 m）或裝車點附近有人
local function player_near(st)
	local x, z, y = at(st.head - 20)
	local lx, lz, ly = at(L().s_load)
	for _, p in ipairs(core.get_connected_players()) do
		local pp = p:get_pos()
		if vector.distance(pp, {x = x, y = y, z = z}) < NEAR or vector.distance(pp, {x = lx, y = ly, z = lz}) < NEAR then return true end
	end
	return false
end
local line = T.line({
	id = "railway",
	keys = function() return KEYS end,
	skey = function() return "trainline" end,
	uid = function(_, i) return ("trainline-%d"):format(i) end,
	ready = function() return L() ~= nil and (#core.get_connected_players() > 0 or rockmech.trainline_force) end,
	pose = function(_, s) return at(s) end,
	s_start = function() return 6 end,                 -- 北端隧道裡（弧長 m）
	s_stop = function() return L().s_stop end,
	s_end = function() return L().n - 2 end,           -- 南端隧道裡
	active = function(_, st)
		local x, z, y = at(st.head - 20)
		return (rockmech.trainline_force or player_near(st)) and core.get_node({x = x, y = y, z = z}).name ~= "ignore"
	end,
	-- 車頭前面 3 m 的軌道上有東西（碎石…）
	blocked = function(_, st)
		for ds = 0.5, 3, 0.5 do
			-- 用那一排實際的軌面高（道床一格一格升降，平滑的縱斷面會差半格，會把高一階的道碴當成障礙）
			local x, z = at(st.head + ds)
			local zr = math.floor(z + 0.5)
			local yr = R.rail_y(L(), zr)
			for dy = 1, 2 do
				local n = yr and core.get_node({x = math.floor(x + 0.5), y = yr + dy, z = zr}).name or "ignore"
				if not RAIL_SET[n] and not rockmech.air_like(n) and n ~= "ignore" and n ~= POST then return n end
			end
		end
	end,
	payer = payer,
	owns = function() return true end,
	hours = HOURS,
	hour = function() return (core.get_timeofday() or 0.5) * 24 end,
})
rockmech.trainline_debug = {L = L, state = function() return line.state("") end, at = at, depart = function() line.depart("") end}
