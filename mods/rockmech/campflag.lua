-- rockmech/campflag.lua
-- 「回營地」旗子（原本在 team.lua）：拿著按左鍵或右鍵就回營地。教學地圖每人發一支（class/team.lua），其他地圖向工具室管理員買。
-- 分了組回自己組的營地（class/team.lua 的 rockmech.class_send_home），沒分組回出生點的營地。

local cfg = rockmech.cfg
if not cfg.career then return end
local S = rockmech.S

-- 把玩家送到 x0 那座營地（地圖先生成好，才知道地面多高）
local function send_to(name, x0)
	core.emerge_area({x = x0 - 2, y = -30, z = -2}, {x = x0 + 2, y = 40, z = 2}, function(_, _, rem)
		if rem > 0 then return end
		local p = core.get_player_by_name(name)
		if p then
			if p:get_attach() then p:set_detach() end
			p:set_pos(rockmech.career_spawn(x0))
			p:set_look_horizontal(math.pi / 2)     -- 臉朝西：礦區（煤層露頭）在營地西邊
		end
	end)
end
rockmech.send_to_camp = send_to

---------------------------------------------------------------------------
-- 「回營地」旗子：拿著按左鍵或右鍵就回營地（教學地圖每人發一支，其他地圖向工具室管理員買）
---------------------------------------------------------------------------

local FLAG = "rockmech:camp_flag"
local function go_camp(itemstack, user)
	if not (user and user:is_player()) then return itemstack end
	local name = user:get_player_name()
	local t = rockmech.team_of(name)
	if t and rockmech.class_send_home then
		rockmech.class_send_home(name, t)
		core.chat_send_player(name, S("[Back to camp] Camp of team @1", t))
	else
		send_to(name, cfg.career_camp_dx)
		core.chat_send_player(name, S("[Back to camp] Spawn"))
	end
	return itemstack
end
core.register_craftitem(FLAG, {
	description = S("Back to camp\nClick to go back to your team's camp"),
	short_description = S("Back to camp"),
	inventory_image = "[fill:16x16:#00000000^[fill:2x15:3,1:#6a4a28^[fill:9x6:5,1:#c04030^[fill:9x2:5,3:#f0e0b0",
	stack_max = 1,
	groups = {not_in_creative_inventory = 1},
	on_use = go_camp,
	on_secondary_use = go_camp,
	on_place = go_camp,
	on_drop = function(itemstack) return itemstack end,     -- 丟不掉
})
