-- rockmech/npc_talk.lua
-- NPC 的對話泡泡：右鍵跟 NPC 互動時，頭上（名牌再上面）冒出一句話，只有點的那個人看得到，SHOW 秒後消失。
-- 泡泡是一個看不見的小物件帶名牌（米白底、深色字，太長自動換行），下面一個小三角形當尾巴，指向 NPC。
-- 台詞在 npc_lines.lua。原本的右鍵功能（開商店、考試…）照舊，泡泡是加上去的。

local LINES = dofile(rockmech.modpath .. "/npc_lines.lua")
local BUBBLE = "rockmech:npc_bubble"
local SHOW = 5               -- 泡泡顯示幾秒
local WRAP = 14              -- 每行幾個字（中文；英文照字元數 ×2）
local HEIGHT = 1.65          -- 尾巴在 NPC 腳底上方幾公尺（名牌在 1.2 m 左右）
local CREAM = "#f4f0e0"

-- 尾巴：往下指的小三角形
local TAIL = "[fill:8x8:#00000000^[fill:8x2:0,0:" .. CREAM .. "^[fill:6x2:1,2:" .. CREAM .. "^[fill:4x2:2,4:" .. CREAM .. "^[fill:2x2:3,6:" .. CREAM
core.register_entity(BUBBLE, {
	initial_properties = {
		visual = "sprite", textures = {TAIL}, visual_size = {x = 0.5, y = 0.5}, use_texture_alpha = true,
		selectionbox = {-0.01, 0, -0.01, 0.01, 0.25, 0.01}, collisionbox = {0, 0, 0, 0, 0, 0},
		physical = false, pointable = false, static_save = false,
		nametag = "", nametag_color = "#202020", nametag_bgcolor = CREAM .. "f0", nametag_fontsize = 32,   -- 字約一般名牌的兩倍
	},
	on_step = function(self, dtime)
		self.t = (self.t or 0) + dtime
		if self.t >= SHOW or not self.object:get_attach() then self.object:remove() end
	end,
})

-- 換行：中日韓字算 2 格寬，其他算 1 格，一行最多 WRAP×2 格
local function wrap(text)
	local out, line, w = {}, {}, 0
	for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if ch == "\n" then
			out[#out + 1] = table.concat(line); line, w = {}, 0
		else
			local cw = #ch > 1 and 2 or 1
			if w + cw > WRAP * 2 then out[#out + 1] = table.concat(line); line, w = {}, 0 end
			if not (w == 0 and ch == " ") then line[#line + 1] = ch; w = w + cw end
		end
	end
	if #line > 0 then out[#out + 1] = table.concat(line) end
	return table.concat(out, "\n")
end

local bubbles = {}       -- NPC 物件 → {玩家名 → 泡泡物件}
local last = {}          -- NPC 物件 → 上一句的序號（不連續說同一句）

-- NPC（物件 o）對玩家說一句（text 已經翻譯過的字串，或 nil = 從台詞裡挑）
function rockmech.npc_say(o, player, text)
	local name = player:get_player_name()
	local e = o:get_luaentity()
	if not text then
		local list = e and LINES[e.name]
		if not list or #list == 0 then return end
		local i = math.random(#list)
		if #list > 1 and i == last[o] then i = i % #list + 1 end
		last[o] = i
		local info = core.get_player_information(name)
		text = core.get_translated_string(info and info.lang_code ~= "" and info.lang_code or "zh_TW", list[i])
	end
	bubbles[o] = bubbles[o] or {}
	local old = bubbles[o][name]
	if old and old:get_pos() then old:remove() end
	local b = core.add_entity(o:get_pos(), BUBBLE)
	if not b then return end
	b:set_attach(o, "", {x = 0, y = HEIGHT * 10, z = 0}, {x = 0, y = 0, z = 0})
	b:set_properties({nametag = wrap(text)})
	b:set_observers({[name] = true})
	bubbles[o][name] = b
end

-- 右鍵：照原本的功能，另外冒泡泡（手上的東西優先時不說話，例如拿著無人機遙控器）
core.register_on_mods_loaded(function()
	for ename in pairs(LINES) do
		local def = core.registered_entities[ename]
		if def then
			local orig = def.on_rightclick
			def.on_rightclick = function(self, clicker, ...)
				local r
				if orig then r = orig(self, clicker, ...) end
				if clicker and clicker:is_player() and not (rockmech.hand_first and rockmech.hand_first(clicker)) then
					rockmech.npc_say(self.object, clicker)
				end
				return r
			end
		end
	end
end)

-- 清掉已經消失的 NPC 的紀錄
local gc = 0
core.register_globalstep(function(dtime)
	gc = gc + dtime
	if gc < 10 then return end
	gc = 0
	for o in pairs(bubbles) do
		if not o:get_pos() then bubbles[o], last[o] = nil, nil end
	end
end)
