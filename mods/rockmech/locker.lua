-- rockmech/locker.lua
-- 置物箱：放小東西（物品欄裡的東西本來就都是小東西）。全組共用，只有自己組和老師打得開、拆得掉。
-- 跟其他設施一樣買施工單（delivery.lua），拿著對地面右鍵放；拆掉（要先清空）變回施工單。

local LOCKER = "rockmech:locker"
local SLOTS = 32
local F = core.formspec_escape

local SIDE = "[fill:16x16:#6a7078^[fill:16x1:0,0:#40464e^[fill:16x1:0,15:#40464e^[fill:1x16:0,0:#40464e^[fill:1x16:15,0:#40464e"
local FRONT = SIDE .. "^[fill:1x14:7,1:#40464e^[fill:2x3:5,6:#d0c060^[fill:2x3:9,6:#d0c060"

local function owner_label(acc) return rockmech.account_label and rockmech.account_label(acc) or acc end
local function may(pos, name)
	local owner = core.get_meta(pos):get_string("owner")
	return rockmech.owner_ok and rockmech.owner_ok(owner, name) or owner == "" or owner == name
end

local function formspec(pos)
	local p = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	return table.concat({
		"size[8,9]",
		("label[0,0;%s]"):format(F(("置物箱（%s）"):format(owner_label(core.get_meta(pos):get_string("owner"))))),
		("list[%s;main;0,0.5;8,4;]"):format(p),
		"list[current_player;main;0,4.85;8,1;]",
		"list[current_player;main;0,6.08;8,3;8]",
		("listring[%s;main]"):format(p),
		"listring[current_player;main]",
	})
end

core.register_node(LOCKER, {
	description = ("置物箱\n放小東西，%d 格；全組共用，只有自己組和老師打得開\n拆掉（要先清空）變回施工單"):format(SLOTS),
	tiles = {SIDE, SIDE, SIDE, SIDE, SIDE, FRONT},
	paramtype2 = "facedir",
	groups = {cracky = 2, not_in_creative_inventory = 1},
	is_ground_content = false,
	drop = "rockmech:order_locker",
	on_construct = function(pos)
		core.get_meta(pos):get_inventory():set_size("main", SLOTS)
	end,
	after_place_node = function(pos, placer)
		local meta = core.get_meta(pos)
		local acc = placer and rockmech.account_of and rockmech.account_of(placer:get_player_name()) or ""
		meta:set_string("owner", acc)
		meta:set_string("infotext", ("置物箱（%s）"):format(owner_label(acc)))
	end,
	on_rightclick = function(pos, node, clicker)
		if not (clicker and clicker:is_player()) then return end
		if not may(pos, clicker:get_player_name()) then return end
		core.show_formspec(clicker:get_player_name(), "rockmech:locker", formspec(pos))
	end,
	can_dig = function(pos, player)
		if not (player and may(pos, player:get_player_name())) then return false end
		if not core.get_meta(pos):get_inventory():is_empty("main") then
			core.chat_send_player(player:get_player_name(), "[置物箱] 裡面還有東西：先拿出來才拆得掉")
			return false
		end
		return true
	end,
	allow_metadata_inventory_put = function(pos, _, _, stack, player) return may(pos, player:get_player_name()) and stack:get_count() or 0 end,
	allow_metadata_inventory_take = function(pos, _, _, stack, player) return may(pos, player:get_player_name()) and stack:get_count() or 0 end,
	allow_metadata_inventory_move = function(pos, _, _, _, _, count, player) return may(pos, player:get_player_name()) and count or 0 end,
})
