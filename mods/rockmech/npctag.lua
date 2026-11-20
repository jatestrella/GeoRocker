-- rockmech/npctag.lua
-- NPC 的名牌（原本在 nametag.lua；玩家的名牌在 class/nametag.lua，教學地圖才有）

local S = rockmech.S

---------------------------------------------------------------------------
-- NPC 的名牌（攤主、技工、地質師、教授、怪手操作員…）：只給 NPC_NEAR 公尺內的人看。
-- 內建名牌所有人都看得到、多遠都看得到，所以 NPC 自己的名牌清空，改由一個掛在腳底、看不見的小物件帶名牌，
-- 用 set_observers 只送給附近的玩家。NPC 自己改名牌（set_properties nametag）也沒關係：每 0.5 秒把它搬過來。
-- NPC：有名牌、外觀是人物模型（character.b3d）的 rockmech 實體
---------------------------------------------------------------------------
local NPC_TAG = "rockmech:npc_tag"
local NPC_NEAR = 10
core.register_entity(NPC_TAG, {
	initial_properties = {
		visual = "sprite", textures = {"blank.png"}, visual_size = {x = 0.01, y = 0.01},
		selectionbox = {-0.01, 0, -0.01, 0.01, 1.1, 0.01}, collisionbox = {0, 0, 0, 0, 0, 0},
		physical = false, pointable = false, static_save = false,
		nametag = "", nametag_color = "#ffffff", nametag_bgcolor = "#00000060",
	},
	on_step = function(self)
		if not self.object:get_attach() then self.object:remove() end
	end,
	on_blast = function() return false, false, {} end,      -- 爆炸不炸名牌（不然 NPC 的名字就不見了）
	on_punch = function() return true end,
})
local npc_names = {}
core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_entities) do
		local ip = def.initial_properties or {}
		if name:find("^rockmech:") and ip.nametag ~= nil and ip.mesh == "character.b3d" then npc_names[name] = true end
	end
end)
local npc_tags = {}      -- NPC 物件 → 名牌物件
local npc_t = 0
core.register_globalstep(function(dtime)
	npc_t = npc_t + dtime
	if npc_t < 0.5 then return end
	npc_t = 0
	local players = core.get_connected_players()
	for _, e in pairs(core.luaentities) do
		if npc_names[e.name] then
			local o = e.object
			local p = o:get_pos()
			if p then
				local props = o:get_properties()
				local tag = npc_tags[o]
				-- 名牌的字搬到小物件上以後 NPC 自己的是空的：記在 NPC 身上，小物件不見了（被炸、卸載）照這個補回來
				if props.nametag ~= "" then e.rm_tag_text, e.rm_tag_color = props.nametag, props.nametag_color
				elseif e.rm_tag_text and not (tag and tag:get_pos()) then
					props.nametag, props.nametag_color = e.rm_tag_text, e.rm_tag_color
				end
				if props.nametag ~= "" then
					if not (tag and tag:get_pos()) then
						tag = core.add_entity(p, NPC_TAG)
						if tag then
							tag:set_attach(o, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
							-- 名牌高度看 NPC 的身高：坐著的（碰撞箱矮）1.1 m，站著的 1.75 m（在頭頂附近）
							local cb = props.collisionbox
							local h = (cb and cb[5] or 1.7) >= 1.5 and 1.75 or 1.1
							tag:set_properties({selectionbox = {-0.01, 0, -0.01, 0.01, h, 0.01}})
						end
						npc_tags[o] = tag
					end
					if tag then tag:set_properties({nametag = props.nametag, nametag_color = props.nametag_color}) end
					o:set_properties({nametag = ""})
				end
				if tag and tag:get_pos() then
					local near = {}
					for _, pl in ipairs(players) do
						if vector.distance(pl:get_pos(), p) <= NPC_NEAR then near[pl:get_player_name()] = true end
					end
					tag:set_observers(near)
				end
			end
		end
	end
	for o, tag in pairs(npc_tags) do
		if not o:get_pos() then
			if tag and tag:get_pos() then tag:remove() end
			npc_tags[o] = nil
		end
	end
end)
-- NPC 改名牌用這個：已經有名牌物件就直接改它（不要先出現在 NPC 身上讓遠處的人看到一下）
function rockmech.npc_set_tag(o, text)
	local tag = npc_tags[o]
	if tag and tag:get_pos() then tag:set_properties({nametag = text}) else o:set_properties({nametag = text}) end
end
