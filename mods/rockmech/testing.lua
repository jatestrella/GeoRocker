-- rockmech/testing.lua
-- 現場的岩石強度試驗（工具室管理員賣）：
--   施密特錘（rockmech:schmidt_hammer）：對岩面左鍵，敲 10 次讀回彈值 R（取中位數），
--     用 Katz 等人（2000）的經驗式換算單軸抗壓強度：UCS ≈ 2.208 · e^(0.067 R)（MPa）。
--     遊戲裡反過來：由這一格岩石的 UCS 算 R，每次敲加一點散布（± 2）。
--   點荷重試驗機（rockmech:point_load）：放在地上的岩芯箱 3 格內；打開岩芯箱、點一段岩芯 →「點荷重試驗」，
--     一次一個試體，讀點荷重強度指數 Is(50)（散布 ± 10 %），記進野帳本（coredrill.lua）。UCS ≈ K · Is(50)，K = 22（ISRM 20–25）。
-- 試驗量的是完整岩石（實驗室尺度）的強度：遊戲裡用的是 lithology 的 UCS ÷ 相似比 N（rockmech_model_scale）。
-- 岩性名稱要有岩體分類能力才看得到（knowledge.lua），強度數字就是儀器讀數，人人看得到。

local cfg = rockmech.cfg
local S = rockmech.S
local HAMMER, PLT = "rockmech:schmidt_hammer", "rockmech:point_load"
local K_PLT = 22
local function see(name, ab) return not rockmech.can_see or rockmech.can_see(name, ab) end
local function ucs_of(key)
	local l = cfg.lithologies[key]
	return l and l.ucs / (cfg.model_scale or 1)
end
local function tell(name, msg) rockmech.notify(name, msg) end

-- 回彈值 R ↔ UCS（Katz et al. 2000）
local function r_of_ucs(ucs) return math.log(math.max(2.3, ucs) / 2.208) / 0.067 end
local function ucs_of_r(R) return 2.208 * math.exp(0.067 * R) end

core.register_tool(HAMMER, {
	description = S("Schmidt hammer\nRight-click a rock face"),
	short_description = S("Schmidt hammer"),
	inventory_image = "[fill:16x16:#00000000^[fill:4x12:6,2:#c8c8c0^[fill:4x3:6,1:#303030^[fill:6x3:5,12:#2050a0",
	-- 右鍵敲一下：一個回彈值 R（散布約 ±3），記進背包裡的野帳本（coredrill.lua）；要自己取中位數、換算 UCS
	on_place = function(itemstack, user, pointed)
		if not (user and user:is_player()) or pointed.type ~= "node" then return itemstack end
		local name = user:get_player_name()
		local node = core.get_node(pointed.under)
		local lith = rockmech.lith_of_node[node.name]
		if not lith then tell(name, S("[Schmidt hammer] Use it on an intact rock face (rubble and soil give no reading)")); return itemstack end
		local R = math.floor(r_of_ucs(ucs_of(lith.name)) + (math.random() + math.random() + math.random() - 1.5) * 2.6 + 0.5)
		local p = pointed.under
		local rec = {x = p.x, y = p.y, z = p.z, r = R, lith = see(name, "rockmass") and lith.name or nil}
		local n = rockmech.fieldbook_add_schmidt and rockmech.fieldbook_add_schmidt(user, rec)
		if n then
			tell(name, S("[Schmidt hammer] @1: R = @2 (recorded in the field notebook, @3 readings; left-click the notebook to see them)",
				core.pos_to_string(p), tostring(R), tostring(n)))
		else
			tell(name, S("[Schmidt hammer] @1: R = @2 (no field notebook in your inventory: not recorded)", core.pos_to_string(p), tostring(R)))
		end
		core.sound_play("default_dig_cracky", {pos = p, gain = 0.5, max_hear_distance = 12}, true)
		return itemstack
	end,
})

-- 點荷重試驗機：放在地上（岩芯箱 3 格內），打開岩芯箱點一段岩芯做試驗（coredrill.lua）
rockmech.PLT_K = K_PLT
-- 配色：藍色鋼構框架、深灰底座、黑色油壓千斤頂、銀色錐頭、白色錶面黑框紅指針。
-- nodebox 每個盒子取貼圖上自己那塊位置（32 px = 1 m，列由上往下），所以一張貼圖上分區塗色就能讓各部件不同色
local FRAME, BASE, JACK, STEEL, FACE, NEEDLE = "#2f6db5", "#2b2e33", "#1d1d1f", "#c9ccd0", "#f2f2ea", "#d02020"
local function fill(w, h, x, y, c) return ("^[fill:%dx%d:%d,%d:%s"):format(w, h, x, y, c) end
local PLT_FRONT = "[fill:32x32:" .. FRAME .. fill(32, 3, 0, 29, BASE) .. fill(5, 7, 14, 22, JACK) .. fill(2, 2, 15, 20, STEEL)
	.. fill(2, 6, 15, 6, STEEL) .. fill(5, 5, 26, 15, JACK) .. fill(3, 3, 27, 16, FACE) .. fill(1, 2, 28, 16, NEEDLE)
local PLT_SIDE_G = "[fill:32x32:" .. FRAME .. fill(32, 3, 0, 29, BASE) .. fill(6, 5, 13, 15, JACK) .. fill(4, 3, 14, 16, FACE) .. fill(1, 2, 16, 16, NEEDLE)
local PLT_SIDE = "[fill:32x32:" .. FRAME .. fill(32, 3, 0, 29, BASE)
local PLT_TOP = "[fill:32x32:" .. BASE .. fill(20, 4, 6, 14, FRAME) .. fill(4, 6, 26, 13, JACK)
local PLT_INV = "[fill:16x16:#00000000^[fill:12x2:2,13:" .. BASE .. "^[fill:2x11:3,2:" .. FRAME .. "^[fill:2x11:11,2:" .. FRAME
	.. "^[fill:10x2:3,2:" .. FRAME .. "^[fill:2x3:7,10:" .. JACK .. "^[fill:1x2:7,4:" .. STEEL .. "^[fill:3x3:13,7:" .. JACK .. "^[fill:1x1:14,8:" .. FACE
core.register_node(PLT, {
	description = S("Point load tester"),
	inventory_image = PLT_INV, wield_image = PLT_INV,
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir", sunlight_propagates = true,
	tiles = {PLT_TOP, "[fill:32x32:" .. BASE, PLT_SIDE_G, PLT_SIDE, PLT_FRONT, PLT_FRONT},
	node_box = {type = "fixed", fixed = {
		{-0.35, -0.5, -0.25, 0.35, -0.42, 0.25},      -- 底座
		{-0.3, -0.42, -0.05, -0.22, 0.3, 0.05},       -- 兩根立柱
		{0.22, -0.42, -0.05, 0.3, 0.3, 0.05},
		{-0.3, 0.3, -0.07, 0.3, 0.38, 0.07},          -- 橫樑
		{-0.07, -0.42, -0.07, 0.07, -0.2, 0.07},      -- 千斤頂
		{-0.03, -0.2, -0.03, 0.03, -0.14, 0.03},      -- 下錐頭
		{-0.03, 0.12, -0.03, 0.03, 0.3, 0.03},        -- 上錐頭
		{0.3, -0.12, -0.09, 0.44, 0.04, 0.09},        -- 壓力錶
	}},
	selection_box = {type = "fixed", fixed = {-0.35, -0.5, -0.25, 0.44, 0.38, 0.25}},
	groups = {dig_immediate = 2},
	is_ground_content = false, stack_max = 1,
	sounds = default.node_sound_metal_defaults and default.node_sound_metal_defaults() or nil,
})

rockmech.schmidt_r_of_ucs, rockmech.schmidt_ucs_of_r = r_of_ucs, ucs_of_r
