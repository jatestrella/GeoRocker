-- rockmech/campguard.lua
-- 營地炸不壞（在所有方塊都註冊完之後載入：營地、研究帳篷、講堂的方塊在 career.lua、research.lua、knowledge.lua 裡；
-- 而且要在 tnt 建快取（mods 載入完）之前掛上 on_blast，所以不能等 register_on_mods_loaded）。
-- 營地的建築炸不壞：營地專用的方塊（帳篷、貨櫃辦公室、家具、看板）一律不動；
-- 營地也用到的一般方塊（玻璃、木門、鋼樓梯）在營地範圍裡不動，營地外照常炸掉（自己移除、掉落）
if not rockmech.cfg.teacher then return end     -- 教學地圖才有（防學生炸別人、炸營地）
local function noop() end
local SHARED = {["default:glass"] = true, ["stairs:stair_steelblock"] = true}
for name, def in pairs(core.registered_nodes) do
	if name:find("^rockmech:camp_") or name:find("^rockmech:tent_") or name:find("^rockmech:office_") or name:find("^rockmech:sign_") then
		core.override_item(name, {on_blast = noop})
	elseif SHARED[name] or name:find("^doors:") then
		local old = def.on_blast
		core.override_item(name, {on_blast = function(pos, intensity)
			if rockmech.in_camp and rockmech.in_camp(pos) then return end
			if old then return old(pos, intensity) end
			local drops = core.get_node_drops(core.get_node(pos).name, "")
			core.remove_node(pos)
			return drops
		end})
	end
end

