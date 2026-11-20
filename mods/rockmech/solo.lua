-- rockmech/solo.lua
-- 單機版的權限、開發者電腦的時鐘（原本在 team.lua）

local cfg = rockmech.cfg
if not cfg.career then return end

-- 單機版（rockmech_solo）：引擎在單機時會給玩家幾乎所有權限（含 server，等於老師），這裡只留基本的
-- 開發者開關：minetest.conf 寫 rockmech_dev = true 的電腦照樣有全部權限（/god 測試用；安裝包不寫）
-- 開發者電腦關掉日夜（minetest.conf 的 time_speed = 0）：時間停在中午，不會剛好停在晚上
if core.settings:get_bool("rockmech_dev", false) and tonumber(core.settings:get("time_speed") or "") == 0 then
	core.after(0, function() core.set_timeofday(0.5) end)
end
local SOLO_PRIVS = {interact = true, shout = true}
if cfg.solo and not core.settings:get_bool("rockmech_dev", false) then
	core.register_on_mods_loaded(function()
		if not core.is_singleplayer() then return end
		for priv, def in pairs(core.registered_privileges) do
			if not SOLO_PRIVS[priv] then def.give_to_singleplayer = false end
		end
	end)
end
if cfg.solo then
	core.register_on_joinplayer(function(player)
		local n = player:get_player_name()
		core.log("action", ("[rockmech] solo: %s privs = %s"):format(n, core.privs_to_string(core.get_player_privs(n))))
	end)
end
