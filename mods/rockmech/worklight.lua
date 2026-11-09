-- rockmech/worklight.lua
-- 工作照明燈：像火把一樣放（地上是三腳架、牆上是壁掛、天花板是吊燈），亮度 14（遊戲最大值）。工具室管理員賣。
--   不擋路（人、車可以穿過）；底下或貼著的東西沒了就掉下來變回物品（attached_node）；碎石流過、掉下來就壓壞（rubble_breaks）。
--   岩石力學裡算空格（不是支撐）。

local S = rockmech.S
local ITEM = "rockmech:work_light"

local BODY = "#e0b020"       -- 黃色燈殼
local LAMP = "[fill:16x16:#fffbe0^[fill:14x14:1,1:#ffffff"
local CASE = "[fill:16x16:" .. BODY .. "^[fill:16x1:0,15:#8a6a10"
local LEG = "[fill:16x16:#3a3a3a"

-- wallmounted：地上（wall_bottom）是落地燈，牆上（wall_side）壁掛，天花板（wall_top）吊燈
core.register_node(ITEM, {
	description = S("Work light\nPlace it on the ground, a wall or a ceiling: brightness 14 (brighter than a torch)"),
	short_description = S("Work light"),
	drawtype = "nodebox", paramtype = "light", paramtype2 = "wallmounted", sunlight_propagates = true,
	light_source = 14,
	walkable = false,
	node_box = {
		type = "wallmounted",
		wall_bottom = {-0.25, -0.5, -0.25, 0.25, 0.4, 0.25},
		wall_top = {-0.2, 0.0, -0.2, 0.2, 0.5, 0.2},
		wall_side = {-0.5, -0.2, -0.2, -0.15, 0.2, 0.2},
	},
	selection_box = {type = "wallmounted",
		wall_bottom = {-0.3, -0.5, -0.3, 0.3, 0.4, 0.3},
		wall_top = {-0.2, 0.0, -0.2, 0.2, 0.5, 0.2},
		wall_side = {-0.5, -0.2, -0.2, -0.15, 0.2, 0.2}},
	tiles = {CASE, LEG, CASE, CASE, CASE, LAMP},
	inventory_image = "[fill:16x16:#00000000^[fill:8x6:4,2:" .. BODY .. "^[fill:6x4:5,3:#fffbe0^[fill:2x6:7,8:#3a3a3a^[fill:8x1:4,14:#3a3a3a",
	wield_image = "[fill:16x16:#00000000^[fill:8x6:4,2:" .. BODY .. "^[fill:6x4:5,3:#fffbe0^[fill:2x6:7,8:#3a3a3a^[fill:8x1:4,14:#3a3a3a",
	groups = {dig_immediate = 3, attached_node = 1, rubble_breaks = 1},
	is_ground_content = false,
	sounds = default and default.node_sound_metal_defaults and default.node_sound_metal_defaults() or nil,
})

-- 裝在木柱、木樑上：對著木頭放，換成貼著木頭的樣子；挖起來還是工作照明燈。
-- 木頭是格子中央直徑 20 cm 的圓木：柱頂貼著格子邊界（−0.5），樑的上下面、柱和樑的側面離燈那一格的邊界 0.4（−0.9）。
-- wallmounted 的 node_box 每個方向只能一個方框
local SIDE = {-0.9, -0.14, -0.14, 0.0, 0.14, 0.14}           -- 側面：燈身從木頭表面伸出來
local VARIANTS = {
	{name = "rockmech:work_light_pole", group = "timber_post",
		bottom = {-0.18, -0.5, -0.18, 0.18, 0.1, 0.18}, top = {-0.2, 0.0, -0.2, 0.2, 0.5, 0.2}},
	{name = "rockmech:work_light_beam", group = "timber_stick",
		bottom = {-0.18, -0.9, -0.18, 0.18, -0.3, 0.18}, top = {-0.18, 0.3, -0.18, 0.18, 0.9, 0.18}},
}
for _, v in ipairs(VARIANTS) do
	local def = table.copy(core.registered_nodes[ITEM])
	def.description, def.short_description = nil, nil
	local box = {type = "wallmounted", wall_bottom = v.bottom, wall_top = v.top, wall_side = SIDE}
	def.node_box, def.selection_box = box, table.copy(box)
	def.groups = table.copy(def.groups)
	def.groups.not_in_creative_inventory = 1
	def.drop = ITEM
	def.inventory_image, def.wield_image = nil, nil
	core.register_node(v.name, def)
end

core.override_item(ITEM, {
	on_place = function(itemstack, placer, pointed)
		local out, pos = core.item_place(itemstack, placer, pointed)
		if pos and pointed.type == "node" then
			local un = core.get_node(pointed.under).name
			for _, v in ipairs(VARIANTS) do    -- 木柱先（木柱也有 timber_stick）
				if core.get_item_group(un, v.group) > 0 then
					local n = core.get_node(pos)
					if n.name == ITEM then core.swap_node(pos, {name = v.name, param2 = n.param2}) end
					break
				end
			end
		end
		return out
	end,
})
