-- rockmech/nocraft.lua
-- 拿掉遊戲內建的合成：東西都向攤主買，或用鋸木台、木工桌做（woodwork.lua）；背包第一頁是個人資料加物品欄，沒有 3×3 合成格。
--   內建的合成表（木鎬、箱子、火把、熔爐…）全部清掉，免得繞過商店和木工。
--   合成格裡如果還有舊世界留下的東西，進遊戲時退回背包（放不下就掉在腳邊）。

local S = rockmech.S

core.register_on_mods_loaded(function()
	for name in pairs(core.registered_items) do
		-- 沒有配方的不用清（clear_craft 會對每一個印警告）
		if name ~= "" and core.get_all_craft_recipes(name) then core.clear_craft({output = name}) end
	end
end)

if core.get_modpath("sfinv") and sfinv and sfinv.pages["sfinv:crafting"] then
	sfinv.override_page("sfinv:crafting", {
		title = S("Backpack"),
		get = function(self, player, context)
			-- 物品欄上面放個人資料（knowledge.lua；經營模式才有）。頁面變寬、物品欄置中、接在個人資料下面（高度跟著內容走）
			if not rockmech.profile_fs then return sfinv.make_formspec(player, context, "", true) end
			local top, h = rockmech.profile_fs(player)
			local W = rockmech.PROFILE_W or 8
			local x0, y0 = (W - 8) / 2, math.max(5.2, h + 0.4)
			local inv = {}
			for i = 0, 7 do inv[#inv + 1] = ("image[%g,%g;1,1;gui_hb_bg.png]"):format(x0 + i, y0) end
			inv[#inv + 1] = ("list[current_player;main;%g,%g;8,1;]list[current_player;main;%g,%g;8,3;8]")
				:format(x0, y0, x0, y0 + 1.15)
			return sfinv.make_formspec(player, context, top .. table.concat(inv), false, ("size[%g,%g]"):format(W, y0 + 3.9))
		end,
	})
end

core.register_on_joinplayer(function(player)
	local inv = player:get_inventory()
	for _, list in ipairs({"craft"}) do
		for i, st in ipairs(inv:get_list(list) or {}) do
			if not st:is_empty() then
				local left = inv:add_item("main", st)
				if not left:is_empty() then core.add_item(player:get_pos(), left) end
				inv:set_stack(list, i, ItemStack())
			end
		end
	end
end)
