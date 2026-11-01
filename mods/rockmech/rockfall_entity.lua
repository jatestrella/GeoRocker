-- rockmech/rockfall_entity.lua
-- 翻滾落石 entity（引擎端）。物理公式在 rockfall.lua（純函式）。
--
-- 限制：Luanti 的 collisionbox 不能旋轉，碰撞永遠以軸對齊立方體計算；
-- 旋轉只影響外觀。撞擊法向由周圍地表高度估計（平滑階梯狀坡面）。

local rf = rockmech.rockfall
local rcfg = rockmech.cfg.rockfall

local ENT = rockmech.modname .. ":rockfall"
local api = {}
rockmech.rockfall_entity = api

local active = {}       -- luaentity → true
local active_count = 0

local function track(self)
	if not active[self] then
		active[self] = true
		active_count = active_count + 1
	end
end
local function untrack(self)
	if active[self] then
		active[self] = nil
		active_count = active_count - 1
	end
end

local function is_walkable(pos)
	local n = core.get_node_or_nil(pos)
	if not n then return true end
	local d = core.registered_nodes[n.name]
	return not d or d.walkable ~= false
end

-- 欄 (x,z) 在 y0 附近的地表高度（最上面的實心格 y），找不到回傳 nil
local function column_top(x, y0, z)
	for y = y0 + 2, y0 - 3, -1 do
		if is_walkable({x = x, y = y, z = z}) then return y end
	end
	return nil
end

-- 地面格 p 的坡面法向（由周圍四欄地表高度估計）
local function ground_normal(p)
	local h0 = column_top(p.x, p.y, p.z) or p.y
	return rf.surface_normal(h0,
		column_top(p.x - 1, h0, p.z), column_top(p.x + 1, h0, p.z),
		column_top(p.x, h0, p.z - 1), column_top(p.x, h0, p.z + 1))
end

-- 被撞擊表面的回彈係數與滾動阻力
local function surface_params(p)
	local lith = rockmech.lith_of_node[core.get_node(p).name]
	if lith and lith.rn then
		return lith.rn, lith.rt, lith.mu_roll
	end
	return rcfg.rn, rcfg.rt, rcfg.mu_roll
end

local function play_impact(pos, node_name, gain)
	local def = core.registered_nodes[node_name]
	if def and def.sounds and def.sounds.dug then
		core.sound_play(def.sounds.dug, {pos = pos, gain = gain, max_hear_distance = 32}, true)
	end
end

-- 停下：放回 node（原位置或往上兩格內第一個可放置處），否則掉落成物品
local function settle(self)
	local obj = self.object
	local pos = obj:get_pos()
	untrack(self)
	obj:remove()
	if not pos or self.node_name == "" then return end
	local p = vector.round(pos)
	for dy = 0, 2 do
		local q = {x = p.x, y = p.y + dy, z = p.z}
		local n = core.get_node(q)
		local d = core.registered_nodes[n.name]
		if n.name == "air" or (d and d.buildable_to) then
			core.set_node(q, {name = self.node_name, param2 = self.param2 or 0})
			-- 停下來的碎石接著做顆粒流（併入下方不滿格的碎石、依安息角攤開）
			local col = rockmech.collapse
			if col and rockmech.is_rubble(self.node_name) then
				col.debris(q, self.node_name, 4)
				core.after(0.1, col.check_cell, q)
			end
			return
		end
	end
	core.add_item(pos, self.node_name)
end

core.register_entity(ENT, {
	initial_properties = {
		physical = true,
		collide_with_objects = false,
		collisionbox = {-0.45, -0.45, -0.45, 0.45, 0.45, 0.45},
		visual = "node",
		node = {name = "air"},
		visual_size = {x = 0.9, y = 0.9, z = 0.9},
		is_visible = false,   -- node 設好才顯示（node = air 會畫出 air 物品的藍色虛線框）
		static_save = true,
	},

	node_name = "",
	age = 0,
	still = 0,
	roll = 0,
	spin = 0,
	yaw = 0,

	on_activate = function(self, staticdata)
		if staticdata and staticdata ~= "" then
			local d = core.deserialize(staticdata)
			if d then
				self.node_name = d.node_name or ""
				self.param2 = d.param2
				self.age = d.age or 0
				self.roll = d.roll or 0
				self.yaw = d.yaw or 0
			end
		end
		if self.node_name ~= "" then
			self.object:set_properties({node = {name = self.node_name}, is_visible = true})
		end
		self.object:set_acceleration({x = 0, y = -rf.G, z = 0})
		track(self)
	end,

	on_deactivate = function(self)
		untrack(self)
	end,

	get_staticdata = function(self)
		return core.serialize({
			node_name = self.node_name, param2 = self.param2, age = self.age, roll = self.roll, yaw = self.yaw,
		})
	end,

	-- 不受玩家攻擊而消失
	on_punch = function() return true end,

	on_step = function(self, dtime, moveresult)
		if self.node_name == "" then
			untrack(self)
			self.object:remove()
			return
		end
		self.age = self.age + dtime
		local obj = self.object
		local v = obj:get_velocity()
		local contact, contact_n, contact_mu = false, nil, nil

		if moveresult then
			-- 取法向速度最大的節點碰撞處理
			local best, best_vn, best_n
			for _, c in ipairs(moveresult.collisions or {}) do
				if c.type == "node" then
					local vin = c.old_velocity
					local n
					if c.axis == "y" then
						n = vin.y <= 0 and ground_normal(c.node_pos) or {x = 0, y = -1, z = 0}
					elseif c.axis == "x" then
						n = {x = vin.x > 0 and -1 or 1, y = 0, z = 0}
					else
						n = {x = 0, y = 0, z = vin.z > 0 and -1 or 1}
					end
					local vn = -rf.dot(vin, n)
					if not best_vn or vn > best_vn then
						best, best_vn, best_n = c, vn, n
					end
				end
			end

			if best then
				local rn, rt, mu = surface_params(best.node_pos)
				if best_vn >= rcfg.impact_speed then
					local v_out, _, vt_out = rf.impact(best.old_velocity, best_n, rn, rt)
					v = v_out
					self.spin = rf.roll_rate(vt_out)
					play_impact(obj:get_pos(), self.node_name, math.min(1, best_vn / 10))
				elseif best.axis == "y" and best.old_velocity.y <= 0 then
					contact, contact_n, contact_mu = true, best_n, mu
				end
			end
			if not contact and moveresult.touching_ground then
				local below = vector.round(obj:get_pos())
				below.y = below.y - 1
				local _, _, mu = surface_params(below)
				contact, contact_n, contact_mu = true, ground_normal(below), mu
			end
		end

		if contact then
			local a = rf.contact_accel(v, contact_n, contact_mu)
			v = {x = v.x + a.x * dtime, y = v.y, z = v.z + a.z * dtime}
			self.spin = rf.roll_rate({x = v.x, y = 0, z = v.z})
		end
		obj:set_velocity(v)

		-- 外觀旋轉：朝速度方向向前滾動（符號慣例見 rockfall.roll_rotation）
		self.yaw = rf.heading_yaw(v) or self.yaw
		self.roll = (self.roll + self.spin * dtime) % (2 * math.pi)
		obj:set_rotation(rf.roll_rotation(self.roll, self.yaw))

		-- 停止判定：用實際位移速度（被牆擋住時速度不為零但位置不動）。
		-- 完全靜止時引擎不回報碰撞，改看下方是否為實心。
		local now = obj:get_pos()
		local speed = rf.len(v)
		if self.last_pos and dtime > 0 then
			local moved = vector.distance(now, self.last_pos) / dtime
			if moved < speed then speed = moved end
		end
		self.last_pos = now
		if not contact and speed < rcfg.stop_speed then
			local below = vector.round(obj:get_pos())
			below.y = below.y - 1
			contact = is_walkable(below)
		end
		if contact and speed < rcfg.stop_speed then
			self.still = self.still + dtime
		else
			self.still = 0
		end
		if self.still > 0.5 or self.age > rcfg.max_time then
			settle(self)
		end
	end,
})

-- 是否還能產生翻滾落石
function api.can_spawn()
	return rcfg.enabled and active_count < rcfg.max_active
end

function api.active_count()
	return active_count
end

-- 在 pos 產生翻滾落石（呼叫者需先移除該處的 node）。回傳 ObjectRef 或 nil。
function api.spawn(pos, node_name, velocity, param2)
	if not api.can_spawn() then return nil end
	local def = core.registered_nodes[node_name]
	if not def or def.drawtype == "airlike" then return nil end
	local obj = core.add_entity(pos, ENT)
	if not obj then return nil end
	local le = obj:get_luaentity()
	le.node_name = node_name
	le.param2 = param2
	obj:set_properties({node = {name = node_name}, is_visible = true})
	if velocity then obj:set_velocity(velocity) end
	return obj
end
