-- rockmech/rigidfall_entity.lua
-- 剛體整塊垂直落下（引擎端）。落下距離由 rigidfall.lua（純函式）計算。
--
-- 外觀：一個主 entity（第一格）＋每格一個附掛的子 entity，整體以重力加速度
-- 往下移動；到達落下距離後按原形狀放回 node。不旋轉、不與其他物體碰撞
-- （落點已事先算好；落地時若地形改變會重新計算）。
-- 主 entity 存檔時記錄形狀與落點；區塊卸載後再載入時直接放到落點。

local rigid = rockmech.rigidfall
local rf = rockmech.rockfall
local cfg = rockmech.cfg

local PARENT = rockmech.modname .. ":rigid_block"
local PART = rockmech.modname .. ":rigid_part"
local api = {}
rockmech.rigidfall_entity = api

local function is_solid(x, y, z)
	local n = core.get_node_or_nil({x = x, y = y, z = z})
	if not n then return true end
	local d = core.registered_nodes[n.name]
	return not d or d.walkable ~= false
end
api.is_solid = is_solid

local function can_place(p)
	local n = core.get_node(p)
	if n.name == "air" then return true end
	local d = core.registered_nodes[n.name]
	return d and d.buildable_to
end

core.register_entity(PART, {
	initial_properties = {
		physical = false, pointable = false, static_save = false,
		visual = "node", node = {name = "air"},
	},
	on_step = function(self)
		-- 主 entity 消失後的孤兒子 entity
		if not self.object:get_attach() then self.object:remove() end
	end,
})

-- 放回 node；依落下高度套用掉落破碎。回傳放置的位置清單
local function place_cells(self, drop)
	local fb = cfg.fallbreak
	local placed = {}
	for _, c in ipairs(self.cells) do
		local p = {x = self.origin.x + c.dx, y = self.origin.y + c.dy - drop, z = self.origin.z + c.dz}
		local name = c.name
		if fb.enabled and name ~= rockmech.RUBBLE then
			local lith = rockmech.lith_of_node[name]
			local h_ref = lith and lith.break_height or fb.break_height
			if math.random() < rf.break_probability(drop, h_ref) then
				name = rockmech.RUBBLE
			end
		end
		if can_place(p) then
			core.set_node(p, {name = name})
			placed[#placed + 1] = {pos = p, name = name}
		else
			core.add_item(p, name) -- 落點被佔（理論上不會發生）
		end
	end
	return placed
end

local function land(self)
	-- 落點仍可用嗎？地形若改變就重新計算
	local cells_now = {}
	for _, c in ipairs(self.cells) do
		cells_now[#cells_now + 1] = {x = self.origin.x + c.dx, y = self.origin.y + c.dy, z = self.origin.z + c.dz}
	end
	local d = rigid.drop_distance(cells_now, is_solid, 256) or self.drop
	if d > self.drop + 0.5 and not self.restored then
		self.drop = d -- 下方障礙已被移走：繼續落
		return
	end

	for _, child in ipairs(self.object:get_children()) do child:remove() end
	self.object:remove()

	local placed = place_cells(self, d)
	if #placed > 0 then
		local def = core.registered_nodes[placed[1].name]
		if def and def.sounds and def.sounds.place then
			core.sound_play(def.sounds.place, {pos = placed[1].pos, gain = 1.0}, true)
		end
	end
	if rockmech.collapse and rockmech.collapse.after_rigid_land then
		rockmech.collapse.after_rigid_land(placed)
	end
end

core.register_entity(PARENT, {
	initial_properties = {
		physical = false, pointable = false, static_save = true,
		visual = "node", node = {name = "air"},
	},

	on_activate = function(self, staticdata)
		if staticdata and staticdata ~= "" then
			local d = core.deserialize(staticdata)
			if d and d.cells then
				self.cells, self.origin, self.drop = d.cells, d.origin, d.drop
				self.restored = true -- 重新載入：下一步直接落地
			end
		end
	end,

	get_staticdata = function(self)
		if not self.cells then return "" end
		return core.serialize({cells = self.cells, origin = self.origin, drop = self.drop})
	end,

	on_step = function(self)
		if not self.cells then
			self.object:remove()
			return
		end
		if self.restored then
			land(self)
			return
		end
		local pos = self.object:get_pos()
		if self.origin.y - pos.y >= self.drop then
			land(self)
		end
	end,
})

-- 讓 cells（{{x,y,z,name}, ...}，node 已被移除）以剛體落下 drop 格
function api.spawn(cells, drop)
	local o = cells[1]
	local parent = core.add_entity({x = o.x, y = o.y, z = o.z}, PARENT)
	if not parent then return false end
	local le = parent:get_luaentity()
	le.origin = {x = o.x, y = o.y, z = o.z}
	le.drop = drop
	le.cells = {}
	for i, c in ipairs(cells) do
		le.cells[i] = {dx = c.x - o.x, dy = c.y - o.y, dz = c.z - o.z, name = c.name}
	end
	parent:set_properties({node = {name = o.name}})
	for i = 2, #cells do
		local c = cells[i]
		local child = core.add_entity({x = c.x, y = c.y, z = c.z}, PART)
		if child then
			child:set_properties({node = {name = c.name}})
			child:set_attach(parent, "", {x = (c.x - o.x) * 10, y = (c.y - o.y) * 10, z = (c.z - o.z) * 10})
		end
	end
	parent:set_acceleration({x = 0, y = -rf.G, z = 0})
	return true
end
