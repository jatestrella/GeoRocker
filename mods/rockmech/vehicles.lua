-- rockmech/vehicles.lua
-- 載具（2×2×2）：挖土機（鏟碎石）、卡車（載運、傾倒）、推土機（推碎石）。
-- 只處理碎石：完整岩石要先爆破或用魔杖弄碎（爆破 → 裝載 → 運輸）。
-- 操作：右鍵上車；駕駛中 Shift 下車，W/S 前進後退，A/D 轉向。
--   挖土機：E 鏟起前方的碎石到鏟斗（1 m³ = 8 級）；空白鍵倒出：前方 4 m 內有卡車就倒進卡車，否則倒在前方地上
--   卡車：空白鍵把車斗（8 m³ = 64 級）的碎石倒在車尾
--   推土機：往前開時把正前方的碎石往前推（推不動就停）
-- 不在車上時左鍵：收回成物品（車上的碎石換成碎石物品，8 級 = 1 個）
-- 碎石的增減用 set_node／remove_node，照常觸發開挖記錄、支撐判定；動過的碎石再依安息角流動。

local NLEV = rockmech.RUBBLE_LEVELS
local collapse = rockmech.collapse

local TYPES = {
	excavator = {desc = "挖土機 Excavator", color = "#e0a020", cap = NLEV, speed = 2.0},
	truck = {desc = "卡車 Dump truck", color = "#c84020", cap = 8 * NLEV, speed = 5.0},
	dozer = {desc = "推土機 Bulldozer", color = "#e8c828", cap = 0, speed = 2.5},
}
local TURN_RATE = 1.6        -- rad/s
local DUMP_REACH = 4         -- 挖土機倒進卡車的距離 (m)

-- 貼圖（[fill 組合）。cube 的六面：上、下、+X、−X、+Z（車頭：yaw 0 朝 +Z）、−Z
local function tex(kind, loaded)
	local c = TYPES[kind].color
	local body = ("[fill:16x16:%s^[fill:16x3:0,13:#2a2a2a"):format(c)          -- 底部履帶／輪
	local side = body .. "^[fill:5x4:9,3:#9fd0ff"                             -- 車窗
	local top = ("[fill:16x16:%s"):format(c)
	local front = body
	if kind == "excavator" then
		front = body .. "^[fill:12x5:2,8:#505050^[fill:2x6:7,2:#404040"          -- 鏟斗與手臂
	elseif kind == "dozer" then
		front = body .. "^[fill:16x5:0,8:#3a3a3a"                              -- 推土鏟
	elseif kind == "truck" then
		top = ("[fill:16x16:%s^[fill:14x14:1,1:#5a2010"):format(c)             -- 車斗
		if loaded then top = top .. "^[fill:12x12:2,2:#6a6058" end
		front = body .. "^[fill:10x4:3,3:#9fd0ff"                              -- 擋風玻璃
	end
	return {top, body, side, side, front, body}
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

-- 車頭（f = 1）或車尾（f = −1）外側、距車身中心 dist 的 2 格寬一排（地面層 + 上方 h−1 層）
local function face_cells(pos, s, f, dist, y0, h)
	local px, pz = -s.z, s.x
	local cx, cz = pos.x + f * s.x * dist, pos.z + f * s.z * dist
	local cells = {}
	for _, l in ipairs({-0.5, 0.5}) do
		local x = math.floor(cx + px * l + 0.5)
		local z = math.floor(cz + pz * l + 0.5)
		for dy = 0, h - 1 do cells[#cells + 1] = {x = x, y = y0 + dy, z = z} end
	end
	return cells
end

-- 地面層（車身下半格的中心高程）
local function ground_y(pos) return math.floor(pos.y - 0.5 + 0.5) end

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
-- 回傳倒不下的級數
local function deposit_column(x, z, ytop, base, a, max_h)
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
			collapse.check_cell(p)
		elseif k and k < NLEV and rockmech.rubble_base[n] == base then
			local put = math.min(NLEV - k, a)
			core.swap_node(p, {name = rockmech.rubble_with_level(base, k + put)})
			a = a - put
			collapse.check_cell(p)
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

local function find_truck(pos, s)
	local front = {x = pos.x + s.x * 2.5, y = pos.y, z = pos.z + s.z * 2.5}
	for _, obj in ipairs(core.get_objects_inside_radius(front, DUMP_REACH)) do
		local e = obj:get_luaentity()
		if e and e.vkind == "truck" then return e end
	end
end

-- 推土機：把貼著鏟刀那一排（2 格寬、地面層與上一層）的碎石收起來，倒到再前面一排（每欄最多堆 3 格），
-- 不放進車身的位置。前面是岩石或倒不下 → 放回原處，回傳 true（被擋住）
local function push(self, pos, s)
	local y0 = ground_y(pos)
	local src = face_cells(pos, s, 1, 1.5, y0, 2)
	local dst = face_cells(pos, s, 1, 2.5, y0, 1)
	local blocked = false
	for _, c in ipairs(src) do
		local n = core.get_node(c).name
		if not rockmech.rubble_level[n] and not passable(n) then blocked = true end   -- 岩石：推不動
	end
	if blocked then return true end
	local got = {}
	for _, c in ipairs(src) do
		local n = core.get_node(c).name
		local k = rockmech.rubble_level[n]
		if k then
			local base = rockmech.rubble_base[n]
			got[base] = (got[base] or 0) + k
			core.remove_node(c)
		end
	end
	for base, lv in pairs(got) do
		local rest = 0
		for i, c in ipairs(dst) do
			local share = math.ceil(lv / (#dst - i + 1))
			lv = lv - share
			rest = rest + deposit_column(c.x, c.z, y0 + 2, base, share, 3)
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

-- 駕駛的 HUD
local function hud_text(self)
	local def = TYPES[self.vkind]
	local s = def.desc
	if def.cap > 0 then
		local t = load_total(self)
		s = s .. ("　載量 %d / %d 級（%.1f / %.0f m³）"):format(t, def.cap, t / NLEV, def.cap / NLEV)
	end
	if self.vkind == "excavator" then s = s .. "\nE 鏟碎石　空白鍵 倒（前方有卡車就倒進卡車）"
	elseif self.vkind == "truck" then s = s .. "\n空白鍵 把車斗倒在車尾"
	else s = s .. "\n往前開把碎石往前推" end
	return s .. "　Shift 下車"
end
local function update_hud(self)
	local d = self.driver and core.get_player_by_name(self.driver)
	if not d then return end
	if self.hud then d:hud_change(self.hud, "text", hud_text(self))
	else
		self.hud = d:hud_add({type = "text", position = {x = 0.5, y = 0.85}, alignment = {x = 0, y = 0},
			text = hud_text(self), number = 0xFFE080, z_index = 100})
	end
	if self.vkind == "truck" then
		self.object:set_properties({textures = tex("truck", load_total(self) > 0)})
	end
end

local function get_off(self)
	local d = self.driver and core.get_player_by_name(self.driver)
	if d then
		d:set_detach()
		if self.hud then d:hud_remove(self.hud) end
		d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		local p = self.object:get_pos()
		local _, s = dirs(self.object:get_yaw())
		core.after(0.1, function()
			if d:get_pos() then d:set_pos({x = p.x - s.z * 2, y = p.y + 0.5, z = p.z + s.x * 2}) end
		end)
	end
	self.driver, self.hud = nil, nil
end

for kind, def in pairs(TYPES) do
	local ename = "rockmech:" .. kind
	core.register_entity(ename, {
		initial_properties = {
			physical = true,
			collide_with_objects = false,
			collisionbox = {-0.98, -1, -0.98, 0.98, 0.98, 0.98},
			selectionbox = {-1, -1, -1, 1, 1, 1},
			visual = "cube",
			visual_size = {x = 2, y = 2, z = 2},
			textures = tex(kind, false),
			stepheight = kind == "dozer" and 0.3 or 1.1,   -- 推土機只壓得過很薄的碎石（3/8 格以上要推走，不是爬過去）
			static_save = true,
		},
		vkind = kind,
		on_activate = function(self, staticdata)
			self.load = {}
			local d = staticdata ~= "" and core.deserialize(staticdata) or nil
			if d then
				self.load = d.load or {}
				if d.yaw then self.object:set_yaw(d.yaw) end
			end
			self.object:set_acceleration({x = 0, y = -9.81, z = 0})
			self.object:set_armor_groups({immortal = 1})
			if kind == "truck" then self.object:set_properties({textures = tex("truck", load_total(self) > 0)}) end
			self.t_act = 0
		end,
		get_staticdata = function(self)
			return core.serialize({load = self.load, yaw = self.object:get_yaw()})
		end,
		on_rightclick = function(self, clicker)
			if not clicker or not clicker:is_player() then return end
			local name = clicker:get_player_name()
			if self.driver == name then get_off(self); return end
			if self.driver then return end
			self.driver = name
			clicker:set_attach(self.object, "", {x = 0, y = 10, z = -3}, {x = 0, y = 0, z = 0})
			clicker:set_eye_offset({x = 0, y = 4, z = 0}, {x = 0, y = 4, z = 0})
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
			self.object:remove()
			return true
		end,
		on_step = function(self, dtime)
			local obj = self.object
			local pos = obj:get_pos()
			local yaw = obj:get_yaw()
			local vel = obj:get_velocity()
			local d = self.driver and core.get_player_by_name(self.driver)
			if self.driver and not d then self.driver, self.hud = nil, nil end
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
			if kind == "dozer" and fwd > 0 then
				if push(self, pos, s) then speed = 0 end
			end
			obj:set_velocity({x = dir.x * speed, y = vel.y, z = dir.z * speed})
			-- 作業鍵（防連按：0.4 s）
			self.t_act = self.t_act - dtime
			if driven and self.t_act <= 0 then
				if kind == "excavator" and ctrl.aux1 then
					self.t_act = 0.4
					local want = def.cap - load_total(self)
					local y0 = ground_y(pos)
					local cells = {}
					for _, dist in ipairs({1.5, 2.5}) do
						for _, c in ipairs(face_cells(pos, s, 1, dist, y0 - 1, 3)) do cells[#cells + 1] = c end
					end
					table.sort(cells, function(a, b) return a.y > b.y end)
					for _, c in ipairs(cells) do
						if want <= 0 then break end
						local t, base = take_rubble(c, want)
						if t > 0 then
							self.load[base] = (self.load[base] or 0) + t
							want = want - t
						end
					end
					update_hud(self)
				elseif ctrl.jump and (kind == "excavator" or kind == "truck") and load_total(self) > 0 then
					self.t_act = 0.6
					local truck = kind == "excavator" and find_truck(pos, s)
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
						truck.object:set_properties({textures = tex("truck", true)})
						update_hud(truck)
					else
						local f = kind == "truck" and -1 or 1
						dump_to_ground(self, face_cells(pos, s, f, 1.5, ground_y(pos), 1), ground_y(pos) + 1)
					end
					update_hud(self)
				end
			end
		end,
	})
	core.register_craftitem(ename .. "_item", {
		description = def.desc .. "\n" .. ({
			excavator = "右鍵上車；E 鏟碎石、空白鍵倒出（前方有卡車就倒進卡車）",
			truck = "右鍵上車；空白鍵把車斗倒在車尾（載量 8 m³）",
			dozer = "右鍵上車；往前開把碎石往前推",
		})[kind],
		inventory_image = tex(kind, kind == "truck")[5],
		stack_max = 1,
		on_place = function(itemstack, placer, pointed)
			if pointed.type ~= "node" then return itemstack end
			local a = pointed.above
			local obj = core.add_entity({x = a.x + 0.5, y = a.y + 0.5, z = a.z + 0.5}, ename)
			if obj and placer then obj:set_yaw(placer:get_look_horizontal()) end
			if not core.is_creative_enabled(placer and placer:get_player_name() or "") then itemstack:take_item() end
			return itemstack
		end,
	})
end
