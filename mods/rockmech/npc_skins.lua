-- rockmech/npc_skins.lua
-- NPC 的造型：每種角色一張 64×32 皮膚（跟 character.png 同一種排法，用 [fill 一塊一塊畫），
-- 加上掛在骨架上的立體配件（安全帽、寬邊帽、手上的工具）。
--   rockmech.npc_skin(role)        → 皮膚貼圖
--   rockmech.npc_dress(obj, role)  → 在 on_activate 呼叫，掛上配件（配件不存檔，跟著 NPC 一起消失）
-- 角色：vehicle 機械設備課長、blast 爆破主任、tools 工具室管理員、mechanic 機械技工、geologist 地質學家、professor 大學教授

-- 64×32 皮膚的區塊（Minecraft 舊版排法）：
--   頭 頂(8,0) 底(16,0) 右(0,8) 前(8,8) 左(16,8) 後(24,8)，各 8×8
--   身體 頂(20,16) 右(16,20) 前(20,20) 左(28,20) 後(32,20)，前後 8×12、側 4×12
--   手臂 (40,16)..(56,32)、腿 (0,16)..(16,32)，前面各在 (44,20)、(4,20)
local S = rockmech.S
local SKIN = "#d8a880"

local function painter()
	local f = {"[fill:64x32:#00000000"}
	local p = {}
	function p.r(x, y, w, h, c) f[#f + 1] = ("[fill:%dx%d:%d,%d:%s"):format(w, h, x, y, c) end
	function p.done() return table.concat(f, "^") end
	-- 頭：皮膚、頭髮（頂、兩側上緣、後腦）、眼睛、嘴
	function p.head(hair, top_rows)
		p.r(0, 8, 32, 8, SKIN); p.r(16, 0, 8, 8, SKIN); p.r(8, 0, 8, 8, hair)
		p.r(0, 8, 8, top_rows or 2, hair); p.r(16, 8, 8, top_rows or 2, hair); p.r(24, 8, 8, 5, hair); p.r(8, 8, 8, 1, hair)
		p.r(10, 12, 1, 1, "#2a2a2a"); p.r(13, 12, 1, 1, "#2a2a2a"); p.r(11, 14, 2, 1, "#b07860")
	end
	-- 帽子／安全帽畫在頭頂一圈（立體的帽沿另外掛）
	function p.hat(c, rows)
		rows = rows or 3
		p.r(8, 0, 8, 8, c); p.r(0, 8, 8, rows, c); p.r(8, 8, 8, rows - 1, c); p.r(16, 8, 8, rows, c); p.r(24, 8, 8, rows, c)
	end
	-- 上衣（身體＋手臂，手掌是皮膚）、褲子、鞋子
	function p.top(c) p.r(16, 16, 24, 16, c); p.r(40, 16, 16, 16, c); p.r(40, 30, 16, 2, SKIN); p.r(48, 16, 4, 4, SKIN) end
	function p.pants(c, shoe) p.r(0, 16, 16, 16, c); p.r(0, 29, 16, 3, shoe); p.r(8, 16, 4, 4, shoe) end
	return p
end

local SKINS = {}

-- 地質學家：卡其野外帽、多口袋的橘褐色工作背心、淺色襯衫、卡其工作褲、登山靴
do
	local p = painter()
	p.head("#5a4030", 2)
	p.hat("#b8a070", 2)
	p.top("#e8e2d0")
	p.r(16, 20, 24, 10, "#a8783a")                                   -- 背心
	p.r(23, 20, 2, 10, "#e8e2d0")                                    -- 前襟打開
	p.r(20, 22, 3, 2, "#8a6028"); p.r(25, 22, 3, 2, "#8a6028")       -- 胸前口袋
	p.r(20, 26, 3, 3, "#8a6028"); p.r(25, 26, 3, 3, "#8a6028")       -- 下方口袋
	p.r(21, 21, 1, 1, "#f0f0f0")                                     -- 口袋插的筆
	p.r(28, 20, 4, 10, "#a8783a"); p.r(16, 20, 4, 10, "#a8783a"); p.r(32, 20, 8, 10, "#a8783a")
	p.pants("#a89068", "#5a3a20")
	p.r(4, 24, 3, 2, "#988058"); p.r(4, 24, 3, 2, "#988058")         -- 褲子側袋
	SKINS.geologist = p.done()
end

-- 機械設備課長：白安全帽、淺藍工作襯衫、識別證、深藍長褲
do
	local p = painter()
	p.head("#2a2a2a", 2)
	p.hat("#f4f4f0", 2)
	p.top("#9cc0e0")
	p.r(23, 20, 2, 1, "#ffffff")                                     -- 領口
	p.r(21, 23, 2, 3, "#f0f0f0"); p.r(21, 23, 2, 1, "#2050a0")       -- 識別證
	p.r(24, 21, 1, 9, "#80a8cc")                                     -- 扣子那一排
	p.pants("#2a3550", "#1a1a1a")
	SKINS.vehicle = p.done()
end

-- 爆破主任：紅安全帽、橘色反光背心（銀色反光條）、深灰工作服
do
	local p = painter()
	p.head("#3a3020", 2)
	p.hat("#c02020", 2)
	p.top("#4a4c50")
	p.r(16, 20, 24, 10, "#f07818"); p.r(23, 20, 2, 8, "#4a4c50")
	p.r(16, 25, 24, 1, "#d8d8d8"); p.r(16, 28, 24, 1, "#d8d8d8")
	p.r(40, 21, 16, 1, "#d8d8d8")                                    -- 袖子反光條
	p.pants("#3a3c40", "#1a1a1a")
	p.r(0, 25, 16, 1, "#d8d8d8")                                     -- 褲管反光條
	SKINS.blast = p.done()
end

-- 工具室管理員：綠色工作帽、灰色連身工作服、工具腰帶、灰色八字鬍
do
	local p = painter()
	p.head("#909090", 2)
	p.hat("#3a6a3a", 2)
	p.r(10, 13, 4, 1, "#a0a0a0")                                     -- 八字鬍
	p.top("#7a7e84")
	p.r(16, 28, 24, 2, "#5a3a20"); p.r(22, 28, 2, 2, "#d0b030")      -- 工具腰帶、捲尺
	p.r(26, 28, 1, 2, "#c0c0c0")                                     -- 扳手
	p.r(23, 20, 2, 8, "#6a6e74")                                     -- 拉鍊
	p.pants("#7a7e84", "#2a2a2a")
	SKINS.tools = p.done()
end

-- 機械技工：黃安全帽、藍色連身工作服（油污）、深色工作靴
do
	local p = painter()
	p.head("#3a2a1a", 2)
	p.hat("#f0c020", 2)
	p.top("#2f5f9f")
	p.r(23, 20, 2, 10, "#284f88")                                    -- 拉鍊
	p.r(21, 25, 2, 1, "#202428"); p.r(26, 23, 1, 2, "#202428"); p.r(34, 26, 2, 2, "#202428")   -- 油污
	p.r(40, 28, 16, 2, "#e07818")                                    -- 手套
	p.pants("#2f5f9f", "#1a1a1a")
	p.r(5, 24, 2, 2, "#202428")
	SKINS.mechanic = p.done()
end

-- 大學教授：灰白頭髮、眼鏡、花白鬍子、咖啡色毛呢外套、白襯衫紅領帶、深色西裝褲
do
	local p = painter()
	p.head("#d4d4d0", 3)
	p.r(9, 11, 6, 3, "#202020"); p.r(10, 12, 1, 1, "#b8d0e0"); p.r(13, 12, 1, 1, "#b8d0e0")   -- 眼鏡
	p.r(4, 12, 4, 1, "#202020"); p.r(16, 12, 4, 1, "#202020")                               -- 鏡腳
	p.r(10, 14, 4, 2, "#c8c8c4"); p.r(9, 15, 1, 1, "#c8c8c4"); p.r(14, 15, 1, 1, "#c8c8c4") -- 鬍子
	p.top("#6b4a2e")
	p.r(22, 20, 4, 4, "#f2f2ee"); p.r(23, 20, 2, 7, "#8a1c1c")                             -- 襯衫、領帶
	p.r(23, 28, 1, 1, "#3a2a1a"); p.r(23, 30, 1, 1, "#3a2a1a")                             -- 扣子
	p.r(44, 24, 4, 3, "#5a3a22")                                                           -- 手肘補丁
	p.pants("#3a3a42", "#1a1a1a")
	SKINS.professor = p.done()
end

-- 怪手操作員：黃安全帽、橘色反光背心（銀色反光條）、深藍工作服、工作手套
do
	local p = painter()
	p.head("#2a2018", 2)
	p.hat("#f0c020", 2)
	p.top("#26324a")
	p.r(16, 20, 24, 10, "#f07818"); p.r(23, 20, 2, 8, "#26324a")
	p.r(16, 24, 24, 1, "#d8d8d8"); p.r(16, 27, 24, 1, "#d8d8d8")
	p.r(40, 28, 16, 2, "#9a8058")                                    -- 工作手套
	p.pants("#26324a", "#1a1a1a")
	SKINS.operator = p.done()
end

-- 採礦技師：白安全帽（藍色帽帶）、螢光黃反光背心、淺灰襯衫、深色長褲
do
	local p = painter()
	p.head("#3a2a20", 2)
	p.hat("#f4f4f0", 2)
	p.top("#c8ccd0")
	p.r(16, 20, 24, 10, "#e0e830")                                   -- 反光背心
	p.r(23, 20, 2, 10, "#c8ccd0")                                    -- 前襟
	p.r(16, 26, 24, 1, "#d0d0d0"); p.r(28, 26, 12, 1, "#d0d0d0")     -- 反光條
	p.r(28, 20, 4, 10, "#e0e830"); p.r(32, 20, 8, 10, "#e0e830")
	p.pants("#30343a", "#1a1a1a")
	SKINS.civil = p.done()
end

-- 地質技師：綠色安全帽、卡其工作襯衫、多口袋背心（插著放大鏡和筆）、工作褲
do
	local p = painter()
	p.head("#4a3428", 2)
	p.hat("#2f8a3f", 2)
	p.top("#c8b890")
	p.r(16, 20, 24, 10, "#6a7a48")                                   -- 背心
	p.r(23, 20, 2, 10, "#c8b890")                                    -- 前襟
	p.r(20, 22, 3, 3, "#556238"); p.r(25, 22, 3, 3, "#556238")       -- 口袋
	p.r(21, 21, 1, 2, "#e8e8e8")                                     -- 筆
	p.r(28, 20, 4, 10, "#6a7a48"); p.r(32, 20, 8, 10, "#6a7a48")
	p.pants("#7a6a4a", "#3a2a18")
	SKINS.geo = p.done()
end

-- 大地技師：藍色安全帽、深藍襯衫、橘色反光背心、深色長褲
do
	local p = painter()
	p.head("#3a2a20", 2)
	p.hat("#1f5fbf", 2)
	p.top("#2a3a5a")
	p.r(16, 20, 24, 10, "#f08020")                                   -- 反光背心
	p.r(23, 20, 2, 10, "#2a3a5a")                                    -- 前襟
	p.r(16, 26, 24, 1, "#e0e0e0"); p.r(28, 26, 12, 1, "#e0e0e0")     -- 反光條
	p.r(28, 20, 4, 10, "#f08020"); p.r(32, 20, 8, 10, "#f08020")
	p.pants("#262a30", "#1a1a1a")
	SKINS.geotech = p.done()
end

function rockmech.npc_skin(role) return SKINS[role] or "character.png" end

---------------------------------------------------------------------------
-- 立體配件：掛在骨架上（Head、Arm_Right），位置單位是 1/10 m
---------------------------------------------------------------------------

local PART, TOOL = "rockmech:npc_part", "rockmech:npc_tool"
local function cube(c) local t = "[fill:16x16:" .. c; return {t, t, t, t, t, t} end
core.register_entity(PART, {
	initial_properties = {visual = "cube", physical = false, pointable = false, static_save = false,
		textures = cube("#ffffff"), visual_size = {x = 0.1, y = 0.1, z = 0.1}},
	on_detach = function(self) self.object:remove() end,
})
core.register_entity(TOOL, {
	initial_properties = {visual = "wielditem", physical = false, pointable = false, static_save = false,
		textures = {"air"}, visual_size = {x = 0.25, y = 0.25}},
	on_detach = function(self) self.object:remove() end,
})

-- 手上的工具（只給 NPC 拿，不放進物品欄）
core.register_craftitem("rockmech:geo_hammer", {
	description = S("Geological hammer"), groups = {not_in_creative_inventory = 1},
	inventory_image = "[fill:16x16:#00000000^[fill:2x11:7,4:#2050a0^[fill:2x3:7,12:#1a3060^[fill:9x3:3,2:#b0b4b8^[fill:2x2:2,2:#8a8e92^[fill:3x1:11,3:#8a8e92",
})
core.register_craftitem("rockmech:npc_wrench", {
	description = S("Wrench"), groups = {not_in_creative_inventory = 1},
	inventory_image = "[fill:16x16:#00000000^[fill:2x10:7,5:#a0a4a8^[fill:6x3:5,2:#a0a4a8^[fill:2x2:7,2:#00000000^[fill:2x2:7,14:#c03020",
})

-- 各角色的配件：{bone, pos, rot, size, tex}（帽子）或 {bone, pos, rot, item}（手上的工具）。
-- 位置照 character.b3d 量的（單位 1/10 m）：Head 骨頭原點在脖子，頭的網格 y 0..4.4、x、z ±2.3（頭寬 0.46 m）；
-- Body 繞 y 轉了 180°，所以 Head 骨頭座標裡臉朝 −z。Arm_Right 繞 x 轉 180°：+y 往手掌，手在 y ≈ 5.3
local HEAD_TOP = 4.4
local HARDHAT = function(c)
	return {
		{bone = "Head", pos = {x = 0, y = HEAD_TOP + 0.45, z = 0}, size = {x = 0.5, y = 0.16, z = 0.5}, tex = c},    -- 帽殼（蓋住頭頂）
		{bone = "Head", pos = {x = 0, y = HEAD_TOP - 0.25, z = 0}, size = {x = 0.56, y = 0.025, z = 0.56}, tex = c},  -- 一圈帽沿
	}
end
local DRESS = {
	geologist = {
		{bone = "Head", pos = {x = 0, y = HEAD_TOP - 0.25, z = 0}, size = {x = 0.8, y = 0.025, z = 0.8}, tex = "#a89060"},   -- 寬帽沿
		{bone = "Head", pos = {x = 0, y = HEAD_TOP + 0.7, z = 0}, size = {x = 0.48, y = 0.2, z = 0.48}, tex = "#b8a070"},    -- 帽頂
		{bone = "Head", pos = {x = 0, y = HEAD_TOP - 0.05, z = 0}, size = {x = 0.49, y = 0.04, z = 0.49}, tex = "#5a4028"},  -- 帽帶
		{bone = "Arm_Right", pos = {x = 0, y = 5.5, z = 3}, rot = {x = -90, y = 225, z = 90}, item = "rockmech:geo_hammer"},
	},
	vehicle = HARDHAT("#f4f4f0"),
	geo = (function()
		local t = HARDHAT("#2f8a3f")
		t[#t + 1] = {bone = "Arm_Right", pos = {x = 0, y = 5.5, z = 3}, rot = {x = -90, y = 225, z = 90}, item = "rockmech:geo_hammer"}
		return t
	end)(),
	geotech = HARDHAT("#1f5fbf"),
	operator = HARDHAT("#f0c020"),
	blast = HARDHAT("#c02020"),
	mechanic = (function()
		local t = HARDHAT("#f0c020")
		t[#t + 1] = {bone = "Arm_Right", pos = {x = 0, y = 5.5, z = 3}, rot = {x = -90, y = 225, z = 90}, item = "rockmech:npc_wrench"}
		return t
	end)(),
	tools = {
		{bone = "Head", pos = {x = 0, y = HEAD_TOP - 0.3, z = -3.45}, size = {x = 0.46, y = 0.025, z = 0.25}, tex = "#2f5a2f"},  -- 帽舌（臉朝 −z）
	},
}

function rockmech.npc_dress(obj, role)
	for _, d in ipairs(DRESS[role] or {}) do
		local o = core.add_entity(obj:get_pos(), d.item and TOOL or PART)
		if o then
			if d.item then o:set_properties({textures = {d.item}})
			else o:set_properties({visual_size = d.size, textures = cube(d.tex)}) end
			o:set_attach(obj, d.bone, d.pos, d.rot or {x = 0, y = 0, z = 0})
		end
	end
end
