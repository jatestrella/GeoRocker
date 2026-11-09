-- rockmech/nocraft.lua
-- 拿掉遊戲內建的合成：東西都向攤主買，或用鋸木台、木工桌做（woodwork.lua）；背包第一頁是個人資料加物品欄，沒有 3×3 合成格。
--   內建的合成表（木鎬、箱子、火把、熔爐…）全部清掉，免得繞過商店和木工。
--   合成格裡如果還有舊世界留下的東西，進遊戲時退回背包（放不下就掉在腳邊）。

local S = rockmech.S

core.register_on_mods_loaded(function()
	for name in pairs(core.registered_items) do
		if name ~= "" then core.clear_craft({output = name}) end
	end
end)

if core.get_modpath("sfinv") and sfinv and sfinv.pages["sfinv:crafting"] then
	sfinv.override_page("sfinv:crafting", {
		title = S("Backpack"),
		get = function(self, player, context)
			-- 物品欄上面放個人資料（knowledge.lua；經營模式才有）
			local top = rockmech.profile_fs and rockmech.profile_fs(player) or ""
			return sfinv.make_formspec(player, context, top, true)
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
