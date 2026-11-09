-- rockmech/npc_talk.lua
-- NPC 的對話泡泡：跟 NPC 互動完（右鍵打開的視窗關掉）時，頭上（名牌再上面）冒出一句話，只有點的那個人看得到，SHOW 秒後消失。
-- 泡泡是看不見的小物件帶名牌：米白底、深色字（太長自動換行），四周留一個字寬的空白，外面再一圈深色框。
-- 名牌不能畫框，所以框是另一個名牌（RING）：字是透明的、字小（RING_FS）而排得比較多，剛好比裡面的泡泡大一圈；
-- 名牌照「出現的先後」畫，所以框先出現、泡泡晚一點才填字，泡泡就疊在框上面。
-- 台詞在 npc_lines.lua。原本的右鍵功能（開商店、考試…）照舊，泡泡是加上去的。

local LINES = dofile(rockmech.modpath .. "/npc_lines.lua")
local CHATTER_P = 0.25          -- 講廢話的機率
local BUBBLE = "rockmech:npc_bubble"
local SHOW = 5               -- 泡泡顯示幾秒
local WRAP = 14              -- 每行幾個字（中文；英文照字元數 ×2）
local HEIGHT = 2.15          -- 泡泡中心在 NPC 腳底上方幾公尺（名牌在 1.2 m 左右）
local CREAM, FRAME = "#f4f0e0", "#5a4630"
local FS, RING_FS = 32, 8    -- 泡泡字的大小；框用的字大小（框的粗細約一個 RING_FS 的字）
local K = FS / RING_FS
local PAD = "　"      -- 全形空白：泡泡四周的留白
-- 名牌在螢幕上是固定字級、不會隨距離變小：每 SCALE_T 秒照看的人離多遠調字級。
-- NEAR m 內原尺寸，越遠越小（跟距離成反比），最小 RING_MIN／RING_FS。框的字級跟泡泡維持 1：K（框才對得齊），
-- 所以字級是一格一格的：框 RING_MIN..RING_FS、泡泡 ×K
local NEAR, SCALE_T, RING_MIN = 6, 0.25, 3

core.register_entity(BUBBLE, {
	initial_properties = {
		visual = "sprite", textures = {"[fill:1x1:#00000000"}, visual_size = {x = 0, y = 0}, use_texture_alpha = true,
		selectionbox = {-0.01, 0, -0.01, 0.01, 0.01, 0.01}, collisionbox = {0, 0, 0, 0, 0, 0},
		physical = false, pointable = false, static_save = false,
		nametag = "", nametag_color = "#202020", nametag_bgcolor = CREAM, nametag_fontsize = FS,
	},
	on_step = function(self, dtime)
		self.t = (self.t or 0) + dtime
		if self.t >= SHOW or not self.object:get_attach() then self.object:remove(); return end
		self.st = (self.st or SCALE_T) + dtime
		if self.st < SCALE_T or not self.viewer then return end
		self.st = 0
		local pl = core.get_player_by_name(self.viewer)
		local p = self.object:get_pos()
		if not (pl and p) then return end
		local d = vector.distance(pl:get_pos(), p)
		local r = math.max(RING_MIN, math.min(RING_FS, math.floor(RING_FS * NEAR / math.max(d, 0.1) + 0.5)))
		if r ~= self.r then
			self.r = r
			self.object:set_properties({nametag_fontsize = self.ring and r or r * K})
		end
	end,
})

-- 字寬（以字的大小為 1）：中日韓字 1、空白 0.28、其他英數 0.55
local function em_width(line)
	local w = 0
	for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		w = w + (#ch > 1 and 1 or ch == " " and 0.28 or 0.55)
	end
	return w
end

-- 換行：中日韓字算 2 格寬，其他算 1 格，一行最多 WRAP×2 格。回傳每一行
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
	return out
end

-- 泡泡的字（四周留白）和框的字（透明、全形空白排成比泡泡大一圈的方塊）
local function bubble_texts(text)
	local lines = wrap(text)
	local inner, wmax = {PAD}, 1
	for _, l in ipairs(lines) do
		inner[#inner + 1] = PAD .. l .. PAD
		wmax = math.max(wmax, em_width(l) + 2)
	end
	inner[#inner + 1] = PAD
	local cols = math.floor(wmax * K + 0.5) + 2          -- 左右各多一個小字寬
	local rows = #inner * K + 2                          -- 上下各多一行小字
	local row = PAD:rep(cols)
	local ring = {}
	for i = 1, rows do ring[i] = row end
	return table.concat(inner, "\n"), table.concat(ring, "\n")
end

local function add_part(o, name, props, ring)
	local b = core.add_entity(o:get_pos(), BUBBLE)
	if not b then return end
	local e = b:get_luaentity()
	if e then e.viewer, e.ring = name, ring end
	b:set_attach(o, "", {x = 0, y = HEIGHT * 10, z = 0}, {x = 0, y = 0, z = 0})
	b:set_properties(props)
	b:set_observers({[name] = true})
	return b
end

local bubbles = {}       -- NPC 物件 → {玩家名 → {泡泡, 框}}
local last = {}          -- NPC 物件 → 上一句的序號（不連續說同一句）

-- 從台詞裡挑一句（還沒翻譯）；chatter_p：講廢話的機率
local function pick(o, chatter_p)
	local e = o:get_luaentity()
	local list = e and LINES[e.name]
	if not list or #list == 0 then return end
	if math.random() < chatter_p then
		list = table.copy(LINES.chatter)
		for _, t in ipairs(LINES.own_chatter[e.name] or {}) do list[#list + 1] = t; list[#list + 1] = t end   -- 自己的廢話機會多一點
	end
	local i = math.random(#list)
	if #list > 1 and i == last[o] then i = i % #list + 1 end
	last[o] = i
	return list[i]
end
local function translate(player, str)
	local info = core.get_player_information(player:get_player_name())
	return core.get_translated_string(info and info.lang_code ~= "" and info.lang_code or "zh_TW", str)
end

-- NPC（物件 o）對玩家說一句（text 已經翻譯過的字串，或 nil = 從台詞裡挑）
function rockmech.npc_say(o, player, text)
	local name = player:get_player_name()
	if not text then
		local str = pick(o, CHATTER_P)
		if not str then return end
		text = translate(player, str)
	end
	bubbles[o] = bubbles[o] or {}
	for _, old in ipairs(bubbles[o][name] or {}) do
		if old:get_pos() then old:remove() end
	end
	local inner, ring_txt = bubble_texts(text)
	local ring = add_part(o, name, {nametag = ring_txt, nametag_color = "#00000000", nametag_bgcolor = FRAME, nametag_fontsize = RING_FS}, true)
	local b = add_part(o, name, {})
	bubbles[o][name] = {b, ring}
	-- 泡泡晚一點才填字：讓它的名牌排在框後面（畫在框上面）
	core.after(0.2, function()
		if b and b:get_pos() then b:set_properties({nametag = inner}) end
	end)
end

-- 右鍵：照原本的功能，另外冒泡泡（手上的東西優先時不說話，例如拿著無人機遙控器）
-- 互動結束後才說：右鍵時打開了視窗（商店、考試…），等那個視窗關掉才冒泡泡（不然被視窗擋住）；沒開視窗就馬上說
local forms_shown = {}         -- 玩家名 → 顯示過幾次視窗（攔 core.show_formspec 數）
local pending = {}             -- 玩家名 → {npc, t}：等視窗關掉再說
local old_show = core.show_formspec
function core.show_formspec(name, formname, formspec)
	forms_shown[name] = (forms_shown[name] or 0) + 1
	return old_show(name, formname, formspec)
end
-- 放在最前面（mods 都載入完再插，後註冊的會排在前面）：商店、考試這些視窗的處理會回傳 true，後面的就收不到關視窗
local function on_close(player, formname, fields)
	if not fields.quit then return end
	local name = player:get_player_name()
	local p = pending[name]
	if p then
		pending[name] = nil
		if p.npc:get_pos() and vector.distance(p.npc:get_pos(), player:get_pos()) < 16 then rockmech.npc_say(p.npc, player) end
	end
end
core.register_on_mods_loaded(function() table.insert(core.registered_on_player_receive_fields, 1, on_close) end)
core.register_on_leaveplayer(function(player) pending[player:get_player_name()] = nil; forms_shown[player:get_player_name()] = nil end)

core.register_on_mods_loaded(function()
	for ename in pairs(LINES) do
		local def = core.registered_entities[ename]
		if def then
			local orig = def.on_rightclick
			def.on_rightclick = function(self, clicker, ...)
				local name = clicker and clicker:is_player() and clicker:get_player_name()
				local before = name and forms_shown[name] or 0
				local r
				if orig then r = orig(self, clicker, ...) end
				if name and not (rockmech.hand_first and rockmech.hand_first(clicker)) then
					if (forms_shown[name] or 0) > before then pending[name] = {npc = self.object}
					else rockmech.npc_say(self.object, clicker) end
				end
				return r
			end
		end
	end
end)

-- 沒事自己蹦一句：附近（IDLE_R 內）有玩家時，每隻 NPC 每 1～3 分鐘說一句（多半是廢話），附近的人都看得到同一句
local IDLE_R, IDLE_MIN, IDLE_MAX, IDLE_CHATTER = 12, 60, 180, 0.6
local idle_next = {}     -- NPC 物件 → 下次說話的時間
local idle_t = 0
core.register_globalstep(function(dtime)
	idle_t = idle_t + dtime
	if idle_t < 2 then return end
	idle_t = 0
	local now = core.get_us_time() / 1e6
	local seen = {}
	for _, pl in ipairs(core.get_connected_players()) do
		for _, o in ipairs(core.get_objects_inside_radius(pl:get_pos(), IDLE_R)) do
			local e = not seen[o] and o:get_luaentity()
			if e and LINES[e.name] and core.registered_entities[e.name] then
				seen[o] = true
				if not idle_next[o] then
					idle_next[o] = now + math.random(IDLE_MIN, IDLE_MAX)
				elseif now >= idle_next[o] then
					idle_next[o] = now + math.random(IDLE_MIN, IDLE_MAX)
					local str = pick(o, IDLE_CHATTER)
					if str then
						for _, p2 in ipairs(core.get_connected_players()) do
							if vector.distance(p2:get_pos(), o:get_pos()) <= IDLE_R then rockmech.npc_say(o, p2, translate(p2, str)) end
						end
					end
				end
			end
		end
	end
	-- 附近沒人的 NPC 重新計時（玩家走近才開始算）
	for o in pairs(idle_next) do
		if not seen[o] then idle_next[o] = nil end
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
