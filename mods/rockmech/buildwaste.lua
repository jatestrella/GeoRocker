-- rockmech/buildwaste.lua
-- 建築廢棄物：磚、石磚、石塊、玻璃、貨櫃牆板這些玩家做不出來的建材，拆掉（挖掉）以後不掉方塊，
-- 原地變成建築廢棄物（rockmech.RUBBLE_DEBRIS），跟岩石挖了變碎石一樣：要扛走、裝車、倒掉。
-- 量照方塊的體積：整格 8 級（滿格）、樓梯 6 級、半格 4 級、玻璃片 1 級。
-- 木頭類（原木、木磚、木樓梯、門…）不算：玩家用鋸木台、木工桌做得出來，挖了照常拿回來。

local A = rockmech.assay
local NLEV = rockmech.RUBBLE_LEVELS

-- 石材、磚、玻璃（Minetest Game 的方塊名稱，不含 "default:"）；樓梯、半格一起算
local MASONRY = {"brick", "stonebrick", "stone_block", "cobble", "mossycobble",
	"desert_stonebrick", "desert_stone_block", "desert_cobble",
	"sandstonebrick", "sandstone_block", "desert_sandstone_brick", "desert_sandstone_block",
	"silver_sandstone_brick", "silver_sandstone_block", "obsidianbrick", "obsidian_block", "glass", "obsidian_glass"}
local OTHERS = {["rockmech:glass_pane"] = 1, ["rockmech:office_wall"] = NLEV, ["rockmech:office_wall_base"] = NLEV,
	["rockmech:office_post"] = NLEV, ["rockmech:office_roof"] = NLEV, ["rockmech:office_floor"] = NLEV}

rockmech.build_waste = {}      -- node 名稱 → 拆掉留下幾級建築廢棄物

local function waste_after_dig(pos, oldnode)
	local lv = rockmech.build_waste[oldnode.name] or NLEV
	if core.get_node(pos).name ~= "air" then return end
	A.place(pos, rockmech.RUBBLE_DEBRIS, lv, A.new(0))
	if rockmech.collapse and rockmech.collapse.update_affected_area then
		core.after(0.05, function() rockmech.collapse.update_affected_area(pos) end)    -- 懸空就掉下來、太陡就滑
	end
end

local function make_waste(name, lv)
	local def = core.registered_nodes[name]
	if not def then return end
	rockmech.build_waste[name] = lv
	local old = def.after_dig_node
	core.override_item(name, {drop = "", after_dig_node = function(pos, oldnode, oldmeta, digger)
		if old then old(pos, oldnode, oldmeta, digger) end
		waste_after_dig(pos, oldnode)
	end})
end

core.register_on_mods_loaded(function()
	for _, m in ipairs(MASONRY) do
		make_waste("default:" .. m, NLEV)
		make_waste("stairs:stair_" .. m, 6)
		make_waste("stairs:stair_inner_" .. m, 7)
		make_waste("stairs:stair_outer_" .. m, 5)
		make_waste("stairs:slab_" .. m, 4)
	end
	for name, lv in pairs(OTHERS) do make_waste(name, lv) end
end)
