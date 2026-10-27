-- rockmech/vehicles.lua
-- 載具：挖土機（3×3×3：兩側半格寬履帶、2×2×2 駕駛艙、前方動臂與鏟斗）、卡車與推土機（2×2×2）。
-- 只處理碎石：完整岩石要先爆破或用魔杖弄碎（爆破 → 裝載 → 運輸）。
-- 操作：右鍵上車；駕駛中 Shift 下車，W/S 前進後退，A/D 轉向。
--   挖土機：E 挖斗伸到滑鼠指的位置（10 m 內），挖起那一格周圍 3×3×3 的碎石（鏟斗 4 m³ = 32 級）再收回；
--           空白鍵倒出：前方 4 m 內有卡車就倒進卡車，否則倒在前方地上
--   卡車：空白鍵把車斗（8 m³ = 64 級）的碎石倒在車尾；名牌與車斗顯示載量
--   推土機：E 切換放鏟／收鏟。放鏟：往前開時把車身高度 0 那一層的碎石（含車身前半壓著的薄碎石）
--           與正前方第二層的碎石推到再前一排，推不動就停；只壓得過很薄的碎石。收鏟：不推，可爬 1 格
-- 駕駛的相機在車頂（挖土機：駕駛艙頂）前緣。
-- 不在車上時左鍵：收回成物品（車上的碎石換成碎石物品，8 級 = 1 個）
-- 碎石的增減用 set_node／remove_node，照常觸發開挖記錄、支撐判定；動過的碎石再依安息角流動。

local NLEV = rockmech.RUBBLE_LEVELS
local collapse = rockmech.collapse

local TYPES = {
	-- half：碰撞箱半邊長；lat：車頭外一排的橫向位置（相對中心）；eye_up／eye_fwd：相機在車身中心上方、
	-- 沿視線往前的距離（m）
	excavator = {desc = "挖土機 Excavator", color = "#e0a020", cap = 4 * NLEV, speed = 2.0,
		half = 1.5, lat = {-1, 0, 1}, eye_up = 1.65, eye_fwd = 0.45},
	truck = {desc = "卡車 Dump truck", color = "#c84020", cap = 8 * NLEV, speed = 5.0,
		half = 1, lat = {-0.5, 0.5}, eye_up = 1.15, eye_fwd = 0.95},
	dozer = {desc = "推土機 Bulldozer", color = "#e8c828", cap = 0, speed = 2.5,
		half = 1, lat = {-0.5, 0.5}, eye_up = 1.15, eye_fwd = 0.95},
}
local TURN_RATE = 1.6        -- rad/s
-- 駕駛視線：第一人稱相機不受 set_attach 位移影響（遊戲內確認：改位移視角不變），改用 set_eye_offset。
-- 玩家掛在車身中心（腳在中心），相機往下 EYE_DOWN、沿視線方向往前 EYE_FWD（m）：坐在車頂前緣，
-- 往前看得到自己的車頂前緣與車頭正前方的地面（車身方塊從裡面看不透明，相機不能放進車身）
local EYE_HEIGHT = 1.625
local function eye_offset(def)
	return {x = 0, y = (def.eye_up - EYE_HEIGHT) * 10, z = def.eye_fwd * 10}
end
local DUMP_REACH = 4         -- 挖土機倒進卡車的距離 (m)

-- 貼圖（[fill 組合）。cube 的六面：上、下、+X、−X、+Z（車頭：yaw 0 朝 +Z）、−Z
local function tex(kind, frac, blade_down)
	local c = TYPES[kind].color
	local body = ("[fill:16x16:%s^[fill:16x3:0,13:#2a2a2a"):format(c)          -- 底部履帶／輪
	local side = body .. "^[fill:5x4:9,3:#9fd0ff"                             -- 車窗
	local top = ("[fill:16x16:%s"):format(c)
	local front = body
	if kind == "excavator" then
		front = body .. "^[fill:12x5:2,8:#505050^[fill:2x6:7,2:#404040"          -- 鏟斗與手臂
	elseif kind == "dozer" then
		front = body .. (blade_down and "^[fill:16x5:0,11:#3a3a3a" or "^[fill:16x5:0,3:#3a3a3a")   -- 推土鏟（放下／抬起）
	elseif kind == "truck" then
		top = ("[fill:16x16:%s^[fill:14x14:1,1:#5a2010"):format(c)             -- 車斗
		local h = frac and math.min(12, math.ceil(12 * frac)) or 0         -- 碎石依載量比例填滿
		if h > 0 then top = top .. ("^[fill:12x%d:2,%d:#6a6058"):format(h, 14 - h) end
		front = body .. "^[fill:10x4:3,3:#9fd0ff"                              -- 擋風玻璃
	end
	return {top, body, side, side, front, body}
end

-- 挖土機外觀：兩側半格寬履帶、下車架、2×2×2 駕駛艙（偏後）、前方動臂與鏟斗（鏟斗可伸出碰撞箱，只是外觀）
local function box_tex(c, front)
	local t = ("[fill:16x16:%s"):format(c)
	return {t, t, t, t, front or t, t}
end
local TRACK = "[fill:16x16:#2a2a2a^[fill:16x2:0,0:#454545^[fill:16x2:0,14:#454545^[fill:2x12:3,2:#383838^[fill:2x12:9,2:#383838"
local EXC_PARTS = {
	{pos = {x = -1.25, y = -1.0, z = 0}, size = {x = 0.5, y = 1.0, z = 3.0}, tex = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}},
	{pos = {x = 1.25, y = -1.0, z = 0}, size = {x = 0.5, y = 1.0, z = 3.0}, tex = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}},
	{pos = {x = 0, y = -1.0, z = 0}, size = {x = 2.0, y = 1.0, z = 2.6}, tex = box_tex("#3a3a3a")},
	{pos = {x = 0, y = 0.5, z = -0.5}, size = {x = 2.0, y = 2.0, z = 2.0},
		tex = (function()
			local c = TYPES.excavator.color
			local win = ("[fill:16x16:%s^[fill:12x7:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
			local side = ("[fill:16x16:%s^[fill:6x6:8,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
			return {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", side, side, win, ("[fill:16x16:%s"):format(c)}
		end)()},
	{id = "bucket", pos = {x = 0.55, y = -1.0, z = 1.75}, size = {x = 1.3, y = 0.8, z = 0.7}, tex = box_tex("#505050")},
}
-- 動臂：從駕駛艙前方（BOOM_ROOT）到挖斗，一串 BOOM_SEG 個小方塊
local BOOM_ROOT = {x = 0.55, y = 0.6, z = 0.55}
local BUCKET_REST = {x = 0.55, y = -1.0, z = 1.75}
local BOOM_SEG = 7
for i = 1, BOOM_SEG do
	EXC_PARTS[#EXC_PARTS + 1] = {id = "boom" .. i, pos = BUCKET_REST, size = {x = 0.4, y = 0.4, z = 0.4},
		tex = box_tex(TYPES.excavator.color)}
end
local DIG_REACH = 10        -- 挖斗最遠 (m，從相機量)
local DIG_TIME = 0.35       -- 挖斗伸出（收回）的時間 (s)
local CLEAR = "[fill:1x1:#00000000"
local PART = "rockmech:vehicle_part"
core.register_entity(PART, {
	initial_properties = {
		physical = false, collide_with_objects = false, pointable = false, static_save = false,
		visual = "cube", textures = box_tex("#808080"), backface_culling = true,
	},
	on_activate = function(self)
		-- 沒有掛在載具上的零件（例如載具已經卸載）自己消失
		core.after(1, function()
			if self.object:get_pos() and not self.object:get_attach() then self.object:remove() end
		end)
	end,
})
local function remove_parts(self)
	for _, c in ipairs(self.object:get_children()) do
		local e = c:get_luaentity()
		if e and e.name == PART then c:remove() end
	end
end
local function spawn_parts(self, parts)
	remove_parts(self)
	self.parts = {}
	for _, pt in ipairs(parts) do
		local o = core.add_entity(self.object:get_pos(), PART)
		if o then
			o:set_properties({visual_size = pt.size, textures = pt.tex})
			o:set_attach(self.object, "", {x = pt.pos.x * 10, y = pt.pos.y * 10, z = pt.pos.z * 10}, pt.rot or {x = 0, y = 0, z = 0})
			if pt.id then self.parts[pt.id] = o end
		end
	end
end

-- 挖斗放在 b（車身座標，m），動臂的小方塊沿 BOOM_ROOT → b 排開
local function place_arm(self, b)
	local parts = self.parts
	if not parts then return end
	local function at(o, p) if o then o:set_attach(self.object, "", {x = p.x * 10, y = p.y * 10, z = p.z * 10}, {x = 0, y = 0, z = 0}) end end
	at(parts.bucket, b)
	for i = 1, BOOM_SEG do
		local t = (i - 0.5) / BOOM_SEG
		at(parts["boom" .. i], {x = BOOM_ROOT.x + (b.x - BOOM_ROOT.x) * t, y = BOOM_ROOT.y + (b.y - BOOM_ROOT.y) * t,
			z = BOOM_ROOT.z + (b.z - BOOM_ROOT.z) * t})
	end
end

-- 世界座標 → 車身座標（車頭 +Z）
local function to_local(self, wp)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local dx, dy, dz = wp.x - p.x, wp.y - p.y, wp.z - p.z
	local c, sn = math.cos(yaw), math.sin(yaw)
	return {x = dx * c + dz * sn, y = dy, z = -dx * sn + dz * c}
end

local function passable(name)
	local def = core.registered_nodes[name]
	return name == "air" or (def and def.walkable == false)
end

-- 車頭方向（連續）與對齊格線的方向
local function dirs(yaw)
	local dx, dz = -math.sin(yaw), math.cos(yaw)
	local sx, sz
	if math.abs(dx) > math.abs(dz) then sx, sz = dx > 0 and 1 or -1, 0 else sx, sz = 0, dz > 0 and 1 or -1 end
	return {x = dx, z = dz}, {x = sx, z = sz}
end

-- 車頭（f = 1）或車尾（f = −1）外側、距車身中心 dist 的一排（地面層 + 上方 h−1 層）。
-- lat：橫向位置（預設 2 格寬 {−0.5, 0.5}）
local function face_cells(pos, s, f, dist, y0, h, lat)
	local px, pz = -s.z, s.x
	local cx, cz = pos.x + f * s.x * dist, pos.z + f * s.z * dist
	local cells = {}
	for _, l in ipairs(lat or {-0.5, 0.5}) do
		local x = math.floor(cx + px * l + 0.5)
		local z = math.floor(cz + pz * l + 0.5)
		for dy = 0, h - 1 do cells[#cells + 1] = {x = x, y = y0 + dy, z = z} end
	end
	return cells
end

-- 地面層（車身最下面那層格子的高程）。half：碰撞箱半邊長（預設 1）
local function ground_y(pos, half) return math.floor(pos.y - (half or 1) + 0.5) end

-- 從 cell 取走最多 want 級碎石。回傳 取走的級數, 碎石種類
local function take_rubble(cell, want)
	local name = core.get_node(cell).name
	local k = rockmech.rubble_level[name]
	if not k or want <= 0 then return 0 end
	local base = rockmech.rubble_base[name]
	local t = math.min(k, want)
	local rest = rockmech.rubble_with_level(base, k - t)
	if rest then core.swap_node(cell, {name = rest}) else core.remove_node(cell) end
	collapse.check_cell({x = cell.x, y = cell.y + 1, z = cell.z})   -- 上方的碎石往下掉
	return t, base
end

-- 在 (x, z) 這一欄、從 ytop 往下找落點，倒 a 級 base 碎石；滿了往上堆（最多 max_h 格，預設 8）。
-- placed（可選）：收集倒下的格子，不立即做安息角流動（推土機推著的那堆）。回傳倒不下的級數
local function deposit_column(x, z, ytop, base, a, max_h, placed)
	local y = ytop
	for _ = 1, 8 do
		if not passable(core.get_node({x = x, y = y - 1, z = z}).name) then break end
		y = y - 1
	end
	for _ = 1, max_h or 8 do
		if a <= 0 then break end
		local p = {x = x, y = y, z = z}
		local n = core.get_node(p).name
		local k = rockmech.rubble_level[n]
		if passable(n) then
			local put = math.min(NLEV, a)
			core.set_node(p, {name = rockmech.rubble_with_level(base, put)})
			a = a - put
			if placed then placed[#placed + 1] = p else collapse.check_cell(p) end
		elseif k and k < NLEV and rockmech.rubble_base[n] == base then
			local put = math.min(NLEV - k, a)
			core.swap_node(p, {name = rockmech.rubble_with_level(base, k + put)})
			a = a - put
			if placed then placed[#placed + 1] = p else collapse.check_cell(p) end
		end
		y = y + 1
	end
	return a
end

local function load_total(self)
	local t = 0
	for _, v in pairs(self.load) do t = t + v end
	return t
end

-- 倒出車上的碎石：平均分到 cells 所在的欄（每欄往上最多堆 8 格），之後依安息角流開
local function dump_to_ground(self, cells, ytop)
	for base, lv in pairs(self.load) do
		local rest = 0
		for i, c in ipairs(cells) do
			local share = math.ceil(lv / (#cells - i + 1))
			lv = lv - share
			rest = rest + deposit_column(c.x, c.z, ytop, base, share)
		end
		self.load[base] = rest > 0 and rest or nil
	end
end

local function find_truck(pos, s, half)
	local d = (half or 1) + 1.5
	local front = {x = pos.x + s.x * d, y = pos.y, z = pos.z + s.z * d}
	for _, obj in ipairs(core.get_objects_inside_radius(front, DUMP_REACH)) do
		local e = obj:get_luaentity()
		if e and e.vkind == "truck" then return e end
	end
end

-- 推土機（放鏟）：把貼著鏟刀那一排（2 格寬、高度 0～2 三層）與車身前半壓著的高度 0 碎石收起來，
-- 倒到再前面一排（每欄最多堆 3 格），不放進車身的位置。前面是岩石或倒不下 → 放回原處，回傳 true（被擋住）
local function push(self, pos, s)
	local y0 = ground_y(pos)
	local src = face_cells(pos, s, 1, 1.5, y0, 3)   -- 與前面那堆的高度（最多 3 格）一致
	local under = face_cells(pos, s, 1, 0.5, y0, 1)
	local dst = face_cells(pos, s, 1, 2.5, y0, 1)
	local blocked = false
	for _, c in ipairs(src) do
		local n = core.get_node(c).name
		if not rockmech.rubble_level[n] and not passable(n) then blocked = true end   -- 岩石：推不動
	end
	if blocked then return true end
	local got = {}
	for _, c in ipairs(under) do src[#src + 1] = c end
	for _, c in ipairs(src) do
		local n = core.get_node(c).name
		local k = rockmech.rubble_level[n]
		if k then
			local base = rockmech.rubble_base[n]
			got[base] = (got[base] or 0) + k
			-- 不用 remove_node：它會讓周圍 5 格的碎石重新流動，剛推出去的那堆會流回鏟刀前。
			-- 只保留開挖記錄與支撐判定（推走撐住岩石的碎石，上面的岩石照樣會掉）
			core.swap_node(c, {name = "air"})
			collapse.mark_excavated(c)
			collapse.queue_support_check(c, n)
		end
	end
	for base, lv in pairs(got) do
		local rest = 0
		for i, c in ipairs(dst) do
			local share = math.ceil(lv / (#dst - i + 1))
			lv = lv - share
			self.pile = self.pile or {}
			rest = rest + deposit_column(c.x, c.z, y0 + 2, base, share, 3, self.pile)
		end
		if rest > 0 then
			-- 前面堆不下：剩下的放回鏟刀前，推土機停住
			blocked = true
			for _, c in ipairs(src) do
				if rest <= 0 then break end
				rest = deposit_column(c.x, c.z, c.y, base, rest, 2)
			end
		end
	end
	return blocked
end

-- 推土機停止推（停下、後退、收鏟）時，前面那堆照安息角攤開
local function settle_pile(self)
	if not self.pile then return end
	local cells = self.pile
	self.pile = nil
	table.sort(cells, function(a, b) return a.y > b.y end)
	for _, p in ipairs(cells) do collapse.check_cell(p) end
end

-- 駕駛的 HUD
local function hud_text(self)
	local def = TYPES[self.vkind]
	local s = def.desc
	if def.cap > 0 then
		local t = load_total(self)
		s = s .. ("　載量 %d / %d 級（%.1f / %.0f m³）"):format(t, def.cap, t / NLEV, def.cap / NLEV)
	end
	if self.vkind == "excavator" then
		local p = self.object:get_pos()
		local truck = p and find_truck(p, select(2, dirs(self.object:get_yaw())), TYPES.excavator.half)
		if truck then
			local tt = load_total(truck)
			s = s .. ("\n前方卡車：%d / %d 級（%.1f / %.0f m³）"):format(tt, TYPES.truck.cap, tt / NLEV, TYPES.truck.cap / NLEV)
		end
		if self.msg then s = s .. "\n" .. self.msg end
		s = s .. "\nE 挖斗挖滑鼠指的位置　空白鍵 倒（前方有卡車就倒進卡車）"
	elseif self.vkind == "truck" then s = s .. "\n空白鍵 把車斗倒在車尾"
	else s = s .. (self.blade and "　【放鏟】往前開把碎石推走" or "　【收鏟】不推碎石") .. "\nE 放鏟／收鏟" end
	return s .. "　Shift 下車"
end

-- 外觀與名牌（卡車：載量；推土機：鏟子高低）
local function refresh_look(self)
	if self.vkind == "truck" then
		local t, cap = load_total(self), TYPES.truck.cap
		self.object:set_properties({
			textures = tex("truck", t / cap),
			nametag = ("載量 %d / %d 級（%.1f / %.0f m³）"):format(t, cap, t / NLEV, cap / NLEV),
			nametag_color = t >= cap and "#ff8060" or "#ffffff",
		})
	elseif self.vkind == "dozer" then
		self.object:set_properties({textures = tex("dozer", nil, self.blade),
			stepheight = self.blade and 0.3 or 1.1})
	end
end
-- 駕駛艙框（全螢幕 HUD 圖片，中間透明）：上方車頂邊條、左右 A 柱（車身顏色）、下方儀表板
local function cockpit_tex(kind)
	local c = TYPES[kind].color
	local dark, mid = "#1e1e1e", "#2c2c2c"
	return table.concat({
		"[fill:160x90:#00000000",
		"^[fill:160x7:0,0:" .. dark, "^[fill:160x2:0,7:" .. c,                        -- 車頂邊條
		"^[fill:10x90:0,0:" .. c, "^[fill:2x90:10,0:" .. dark,                          -- 左 A 柱
		"^[fill:10x90:150,0:" .. c, "^[fill:2x90:148,0:" .. dark,                       -- 右 A 柱
		"^[fill:6x8:12,9:" .. c, "^[fill:6x8:142,9:" .. c,                              -- 柱子上方的斜角
		"^[fill:3x6:18,9:" .. c, "^[fill:3x6:139,9:" .. c,
		"^[fill:160x2:0,70:" .. c, "^[fill:160x18:0,72:" .. mid,                       -- 儀表板
		"^[fill:14x8:18,78:#101010^[fill:12x6:19,79:#203828",                            -- 儀表
		"^[fill:14x8:128,78:#101010^[fill:12x6:129,79:#382820",
	})
end

-- 移除駕駛的 HUD（說明文字與駕駛艙框）
local function hud_clear(self, player)
	if player then
		if self.hud then player:hud_remove(self.hud) end
		if self.hud_cockpit then player:hud_remove(self.hud_cockpit) end
	end
	self.hud, self.hud_cockpit = nil, nil
end

local function update_hud(self)
	local d = self.driver and core.get_player_by_name(self.driver)
	if not d then return end
	if not self.hud_cockpit then
		self.hud_cockpit = d:hud_add({type = "image", position = {x = 0.5, y = 0.5}, alignment = {x = 0, y = 0},
			scale = {x = -100, y = -100}, text = cockpit_tex(self.vkind), z_index = -10})
	end
	if self.hud then d:hud_change(self.hud, "text", hud_text(self))
	else
		self.hud = d:hud_add({type = "text", position = {x = 0.5, y = 0.85}, alignment = {x = 0, y = 0},
			text = hud_text(self), number = 0xFFE080, z_index = 100})
	end
	refresh_look(self)
end

local function get_off(self)
	local d = self.driver and core.get_player_by_name(self.driver)
	if d then
		d:set_detach()
		d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		hud_clear(self, d)
		local p = self.object:get_pos()
		local _, s = dirs(self.object:get_yaw())
		core.after(0.1, function()
			if d:get_pos() then d:set_pos({x = p.x - s.z * 2, y = p.y + 0.5, z = p.z + s.x * 2}) end
		end)
	end
	self.driver = nil
	hud_clear(self, nil)
end

for kind, def in pairs(TYPES) do
	local ename = "rockmech:" .. kind
	core.register_entity(ename, {
		initial_properties = {
			physical = true,
			collide_with_objects = false,
			collisionbox = {-def.half + 0.02, -def.half, -def.half + 0.02, def.half - 0.02, def.half - 0.02, def.half - 0.02},
			selectionbox = {-def.half, -def.half, -def.half, def.half, def.half, def.half},
			visual = "cube",
			visual_size = kind == "excavator" and {x = 1, y = 1, z = 1} or {x = 2, y = 2, z = 2},
			-- 挖土機的外觀由零件組成：車身用全透明貼圖（不能設 is_visible = false，掛在上面的零件會一起被隱藏）
			textures = kind == "excavator" and {CLEAR, CLEAR, CLEAR, CLEAR, CLEAR, CLEAR} or tex(kind, 0, true),
			use_texture_alpha = kind == "excavator",
			backface_culling = true,       -- 從車身裡面往外看是透明的
			stepheight = kind == "dozer" and 0.3 or 1.1,   -- 推土機放鏟時只壓得過很薄的碎石（要推走，不是爬過去）
			static_save = true,
		},
		vkind = kind,
		on_activate = function(self, staticdata)
			self.load = {}
			local d = staticdata ~= "" and core.deserialize(staticdata) or nil
			if d then
				self.load = d.load or {}
				if d.yaw then self.object:set_yaw(d.yaw) end
				if d.blade ~= nil then self.blade = d.blade end
			end
			if kind == "dozer" and self.blade == nil then self.blade = true end
			self.object:set_acceleration({x = 0, y = -9.81, z = 0})
			self.object:set_armor_groups({immortal = 1})
			refresh_look(self)
			self.t_act = 0
			if kind == "excavator" then
				core.after(0, function()
					if self.object:get_pos() then spawn_parts(self, EXC_PARTS); place_arm(self, BUCKET_REST) end
				end)
			end
		end,
		on_deactivate = function(self)
			remove_parts(self)
		end,
		get_staticdata = function(self)
			return core.serialize({load = self.load, yaw = self.object:get_yaw(), blade = self.blade})
		end,
		on_rightclick = function(self, clicker)
			if not clicker or not clicker:is_player() then return end
			local name = clicker:get_player_name()
			if self.driver == name then get_off(self); return end
			if self.driver then return end
			-- 從別台車直接換過來：先把原本那台的駕駛清掉（否則兩台都聽這個玩家的）
			local parent = clicker:get_attach()
			local pe = parent and parent:get_luaentity()
			if pe and pe ~= self and pe.driver == name then
				hud_clear(pe, clicker)
				pe.driver = nil
			end
			self.driver = name
			clicker:set_attach(self.object, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
			clicker:set_eye_offset(eye_offset(def), {x = 0, y = 0, z = 0})   -- 第三人稱維持預設（前後偏移上限只有 ±0.5 m）
			update_hud(self)
		end,
		on_punch = function(self, puncher)
			if not puncher or not puncher:is_player() or self.driver then return true end
			local inv = puncher:get_inventory()
			local left = inv:add_item("main", ItemStack(ename .. "_item"))
			if not left:is_empty() then core.add_item(self.object:get_pos(), left) end
			for base, lv in pairs(self.load) do
				local n = math.floor(lv / NLEV + 0.5)
				if n > 0 then
					local l2 = inv:add_item("main", ItemStack(base .. " " .. n))
					if not l2:is_empty() then core.add_item(self.object:get_pos(), l2) end
				end
			end
			remove_parts(self)
			self.object:remove()
			return true
		end,
		on_step = function(self, dtime)
			local obj = self.object
			local pos = obj:get_pos()
			local yaw = obj:get_yaw()
			local vel = obj:get_velocity()
			local d = self.driver and core.get_player_by_name(self.driver)
			if self.driver and not d then self.driver = nil; hud_clear(self, nil) end
			-- 駕駛已經不在這台車上（換到別台、被傳送、死亡等）：不再聽他的
			if d then
				local parent = d:get_attach()
				if not (parent and parent:get_luaentity() == self) then
					hud_clear(self, d)
					if not parent then d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}) end
					self.driver, d = nil, nil
				end
			end
			local fwd, turn = 0, 0
			-- self.autopilot：沒有駕駛時的控制輸入（測試、指令用），格式同 get_player_control
			local ctrl = d and d:get_player_control() or self.autopilot or {}
			local driven = d or self.autopilot
			if driven then
				if d and ctrl.sneak then get_off(self); return end
				fwd = (ctrl.up and 1 or 0) - (ctrl.down and 1 or 0)
				turn = (ctrl.left and 1 or 0) - (ctrl.right and 1 or 0)
			end
			if turn ~= 0 then
				yaw = yaw + turn * TURN_RATE * dtime
				obj:set_yaw(yaw)
			end
			local dir, s = dirs(yaw)
			local speed = def.speed * fwd
			-- 推土機：往前開時推碎石，推不動就停
			if kind == "dozer" and self.blade and fwd > 0 then
				if push(self, pos, s) then speed = 0; settle_pile(self) end
			elseif kind == "dozer" then
				settle_pile(self)
			end
			obj:set_velocity({x = dir.x * speed, y = vel.y, z = dir.z * speed})
			-- 挖斗：伸出 DIG_TIME 秒 → 挖 → 收回 DIG_TIME 秒
			if self.dig then
				local dg = self.dig
				dg.t = dg.t + dtime
				if not dg.done and dg.t >= DIG_TIME then
					dg.done = true
					local want = def.cap - load_total(self)
					local cells = {}
					for dx = -1, 1 do for dz = -1, 1 do for dy = 1, -1, -1 do
						cells[#cells + 1] = {x = dg.target.x + dx, y = dg.target.y + dy, z = dg.target.z + dz}
					end end end
					table.sort(cells, function(a, b)
						if a.y ~= b.y then return a.y > b.y end
						return math.abs(a.x - dg.target.x) + math.abs(a.z - dg.target.z)
							< math.abs(b.x - dg.target.x) + math.abs(b.z - dg.target.z)
					end)
					local got = 0
					for _, c in ipairs(cells) do
						if want <= 0 then break end
						local t, base = take_rubble(c, want)
						if t > 0 then
							self.load[base] = (self.load[base] or 0) + t
							want = want - t
							got = got + t
						end
					end
					if got == 0 then
						self.msg = want <= 0 and "鏟斗滿了，先倒掉（空白鍵）" or "那裡沒有碎石（岩石要先爆破）"
					end
					update_hud(self)
				end
				local u = dg.t < DIG_TIME and dg.t / DIG_TIME or math.max(0, 2 - dg.t / DIG_TIME)
				local r, to = BUCKET_REST, dg.to
				place_arm(self, {x = r.x + (to.x - r.x) * u, y = r.y + (to.y - r.y) * u, z = r.z + (to.z - r.z) * u})
				if dg.t >= 2 * DIG_TIME then self.dig = nil; place_arm(self, BUCKET_REST) end
			end
			-- 作業鍵（防連按：0.4 s）
			self.t_act = self.t_act - dtime
			if driven and self.t_act <= 0 then
				if kind == "dozer" and ctrl.aux1 then
					self.t_act = 0.5
					self.blade = not self.blade
					update_hud(self)
					refresh_look(self)
				elseif kind == "excavator" and ctrl.aux1 and not self.dig then
					self.t_act = 2 * DIG_TIME + 0.1
					-- 滑鼠指的方塊：從相機沿視線找第一個方塊
					local target = self.autopilot and self.autopilot.target
					if d then
						local look = d:get_look_dir()
						local hl = math.sqrt(look.x * look.x + look.z * look.z)
						local eye = {x = pos.x + (hl > 0 and look.x / hl or 0) * def.eye_fwd, y = pos.y + def.eye_up,
							z = pos.z + (hl > 0 and look.z / hl or 0) * def.eye_fwd}
						local ray = core.raycast(eye, vector.add(eye, vector.multiply(look, DIG_REACH)), false, false)
						for pt in ray do
							if pt.type == "node" then target = pt.under; break end
						end
					end
					if target then
						self.dig = {t = 0, target = target, to = to_local(self, target)}
						self.msg = nil
					else
						self.msg = "挖斗搆不到（10 m 內沒有方塊）"
					end
					update_hud(self)
				elseif ctrl.jump and (kind == "excavator" or kind == "truck") and load_total(self) > 0 then
					self.t_act = 0.6
					local truck = kind == "excavator" and find_truck(pos, s, def.half)
					if truck then
						local room = TYPES.truck.cap - load_total(truck)
						for base, lv in pairs(self.load) do
							local m = math.min(lv, room)
							if m > 0 then
								truck.load[base] = (truck.load[base] or 0) + m
								room = room - m
								self.load[base] = lv - m > 0 and (lv - m) or nil
							end
						end
						refresh_look(truck)
						update_hud(truck)
					else
						local f = kind == "truck" and -1 or 1
						local y0 = ground_y(pos, def.half)
						dump_to_ground(self, face_cells(pos, s, f, def.half + 0.5, y0, 1, def.lat), y0 + 1)
					end
					update_hud(self)
				end
			end
		end,
	})
	core.register_craftitem(ename .. "_item", {
		description = def.desc .. "\n" .. ({
			excavator = "右鍵上車；E 挖斗挖滑鼠指的位置（鏟斗 4 m³）、空白鍵倒出（前方有卡車就倒進卡車）",
			truck = "右鍵上車；空白鍵把車斗倒在車尾（載量 8 m³）",
			dozer = "右鍵上車；E 放鏟／收鏟，放鏟時往前開把碎石推走",
		})[kind],
		inventory_image = tex(kind, 0, true)[5],
		stack_max = 1,
		on_place = function(itemstack, placer, pointed)
			if pointed.type ~= "node" then return itemstack end
			local a = pointed.above
			local odd = (def.half * 2) % 2 == 1
			local off = odd and 0 or 0.5
			local obj = core.add_entity({x = a.x + off, y = a.y - 0.5 + def.half, z = a.z + off}, ename)
			if obj and placer then obj:set_yaw(placer:get_look_horizontal()) end
			if not core.is_creative_enabled(placer and placer:get_player_name() or "") then itemstack:take_item() end
			return itemstack
		end,
	})
end
