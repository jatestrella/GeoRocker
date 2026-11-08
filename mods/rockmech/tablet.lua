-- rockmech/tablet.lua
-- 數值分析平板（大地技師賣）：平板上跑數值模型，看準心指著那一格岩石的應力狀態。
--   拿在手上：平板螢幕（上半部）即時畫那一格的 Mohr 圓（應力解的 σ1、σ3）和強度包絡線（岩體：紅；完整岩石：灰色虛線）；
--     σ1、σ3 的數字顯示在資訊泡泡。不會「Mohr 圓分析」（只能考試學會）的人，螢幕上只有軟體畫面、沒有圓，數字照樣有。
--   按住右鍵：平板舉到畫面正中央正面看（大張的 Mohr 圓、刻度、破壞時的 σ1、強度 / 應力）；放開就放下。
-- 螢幕是伺服器畫的 PNG（暫時的媒體檔）。手上的：傳給大家（別人看你手上的平板也看得到），換到這把平板的 wield_image；
-- 正面看的：只傳給自己，用 HUD 圖層顯示（開視窗的話放開右鍵就偵測不到了）。

local S = rockmech.S
local M = rockmech.mohr
local TABLET = "rockmech:fea_tablet"
local TW, TH = 160, 120                 -- 平板（手上那張圖）的像素
local SX, SY, SW, SH = 6, 6, 148, 78    -- 螢幕在平板上的位置、大小：放在上半部（拿在手上時下半部會跑出畫面）
local FRAME = "[fill:" .. TW .. "x" .. TH .. ":#1e1e22^[fill:24x4:68,110:#3a3a40"
local SCREEN_IDLE = FRAME .. ("^[fill:%dx%d:%d,%d:#dfe6ee^[fill:%dx10:%d,%d:#3a6aa0"):format(SW, SH, SX, SY, SW, SX, SY)
local TICK = 0.15                       -- 檢查按鍵的間隔
local REFRESH = 2                       -- 同一格多久重算一次（周圍可能已經開挖）
local BW, BH = 640, 400                 -- 正面看的圖

local function can_mohr(name) return not rockmech.can_see or rockmech.can_see(name, "mohr", true) end

-- 指著的岩石的應力狀態：{pos, s1, s3, rm, lith}；不是岩石回傳 nil
local function state_at(pos)
	local rep = rockmech.stress_report(pos)
	local s = rep.local_state
	if not (s and s.rm) then return nil end
	local fc = rockmech.fem_cell and rockmech.fem_cell(pos)
	return {pos = pos, s1 = fc and fc.s1 or s.s1, s3 = fc and fc.s3 or s.s3, rm = s.rm, lith = rep.lith}
end

local function mohr_png(st, w, h, bg)
	local rm, mi = st.rm, st.lith.mi or 10
	return M.draw({w = w, h = h, bg = bg, circles = {{st.s1, st.s3, M.COLOR.circle, 2}},
		envs = {{pts = M.envelope(rm.sigci, mi, 1, 0.5, st.s1 * 1.3 + 1), color = M.COLOR.intact, dashed = true},
			{pts = M.envelope(rm.sigci, rm.mb, rm.s, rm.a, st.s1 * 1.3 + 1), color = M.COLOR.mass}}})
end

local function numbers(st)
	return S("Numerical model: σ1 @1  σ3 @2 MPa", ("%.2f"):format(st.s1), ("%.2f"):format(st.s3))
end
local function detail_lines(st)
	local rm = st.rm
	local f_mass = M.s1_fail(rm.sigci, rm.mb, rm.s, rm.a, st.s3)
	local f_int = M.s1_fail(rm.sigci, st.lith.mi or 10, 1, 0.5, st.s3)
	return {
		{nil, S("@1, GSI @2", S(st.lith.description), tostring(rm.gsi))},
		{M.COLOR.circle, numbers(st)},
		{M.COLOR.mass, S("Rock mass: σ1 at failure @1 MPa, strength / stress @2", ("%.2f"):format(f_mass), ("%.2f"):format(f_mass / math.max(st.s1, 1e-6)))},
		{M.COLOR.intact, S("Intact rock: σ1 at failure @1 MPa", ("%.2f"):format(f_int))},
	}
end

-- 換手上平板的螢幕（tex = nil：待機畫面）
local function set_screen(player, tex)
	local stack = player:get_wielded_item()
	if stack:get_name() ~= TABLET then return end
	local meta = stack:get_meta()
	local v = tex or ""
	if meta:get_string("wield_image") == v then return end
	meta:set_string("wield_image", v)
	player:set_wielded_item(stack)
end

-- 暫時的媒體檔：to = nil 傳給所有人，否則只給 to；name 收到了才 cb(檔名)
local serial = 0
local function send(name, png, to, cb)
	serial = serial + 1
	local fname = ("rockmech_tab_%s_%d.png"):format(name:gsub("[^%w_]", "_"), serial)
	local dir = core.get_worldpath() .. "/rockmech_media"
	core.mkdir(dir)
	local path = dir .. "/" .. fname
	local fh = io.open(path, "wb")
	if not fh then return end
	fh:write(png)
	fh:close()
	local done = false
	core.dynamic_add_media({filepath = path, ephemeral = true, to_player = to}, function(who)
		if who == name and not done then done = true; cb(fname) end
	end)
	core.after(60, function() os.remove(path) end)
end

---------------------------------------------------------------------------
-- 正面看（按住右鍵）：HUD 圖層
---------------------------------------------------------------------------
local function big_remove(player, w)
	for _, id in ipairs(w.big_huds or {}) do player:hud_remove(id) end
	w.big_huds, w.big_key = nil, nil
end
local function big_show(player, w, st, key)
	local name = player:get_player_name()
	local function add(def)
		def.position = def.position or {x = 0.5, y = 0.5}
		def.z_index = def.z_index or 200
		local id = player:hud_add(def)
		w.big_huds[#w.big_huds + 1] = id
	end
	local function place(fname, ax)
		big_remove(player, w)
		w.big_huds, w.big_key = {}, key
		local lines = st and detail_lines(st) or {{nil, S("Point the tablet at rock")}}
		local panel_h = (fname and BH + 40 or 0) + 30 + #lines * 24 + 20
		local top = -panel_h / 2
		add({type = "image", alignment = {x = 0, y = 1}, offset = {x = 0, y = top - 16}, scale = {x = BW + 40, y = panel_h + 32},
			text = "[fill:1x1:#1e1e22", z_index = 199})
		local y = top
		if fname then
			add({type = "image", alignment = {x = 0, y = 1}, offset = {x = 0, y = y}, scale = {x = 1, y = 1}, text = fname})
			-- 刻度：σn（MPa）
			for v = math.ceil(ax.smin / ax.step) * ax.step, ax.smax, ax.step do
				local x = ax.x0 + v * ax.k
				if x > 10 and x < BW - 30 then
					add({type = "text", alignment = {x = 0, y = 1}, offset = {x = x - BW / 2, y = y + BH + 4}, text = ("%g"):format(v), number = 0xD0D0D0})
				end
			end
			add({type = "text", alignment = {x = -1, y = 1}, offset = {x = BW / 2, y = y + BH + 22}, text = S("σn (MPa)"), number = 0xD0D0D0})
			add({type = "text", alignment = {x = 1, y = 1}, offset = {x = -BW / 2 + 4, y = y + 2}, text = "τ", number = 0x303030})
			y = y + BH + 46
		end
		for _, l in ipairs(lines) do
			if l[1] then add({type = "image", alignment = {x = 1, y = 1}, offset = {x = -BW / 2, y = y + 4}, scale = {x = 12, y = 12}, text = "[fill:1x1:" .. l[1]}) end
			add({type = "text", alignment = {x = 1, y = 1}, offset = {x = -BW / 2 + 20, y = y}, text = l[2], number = 0xFFFFFF})
			y = y + 24
		end
		if st and not can_mohr(name) then
			add({type = "text", alignment = {x = 1, y = 1}, offset = {x = -BW / 2 + 20, y = y}, number = 0xFFC080,
				text = S("Learn \"Mohr circle analysis\" from the professor to see the Mohr circle")})
		end
	end
	if st and can_mohr(name) then
		w.big_busy = true
		local png, ax = mohr_png(st, BW, BH, string.char(244, 246, 248, 255))
		send(name, png, name, function(fname)
			w.big_busy = false
			if w.big_on then place(fname, ax) end
		end)
	else
		place(nil)
	end
end

---------------------------------------------------------------------------
-- 每一步：手上的螢幕、按住右鍵正面看
---------------------------------------------------------------------------
local watch = {}        -- 玩家名稱 → {key, t, busy, big_on, big_key, big_huds, big_busy}
local t_acc = 0
core.register_globalstep(function(dtime)
	t_acc = t_acc + dtime
	if t_acc < TICK then return end
	local dt = t_acc
	t_acc = 0
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local w = watch[name]
		if player:get_wielded_item():get_name() ~= TABLET then
			if w then big_remove(player, w); watch[name] = nil end
		else
			if not w then w = {t = 0}; watch[name] = w end
			w.t = w.t + dt
			local pos = rockmech.pointed_node_pos and rockmech.pointed_node_pos(player, 8)
			local node = pos and core.get_node(pos)
			local rock = node and rockmech.lith_of_node[node.name]
			local key = rock and core.pos_to_string(pos) or ""
			local fresh = w.key ~= key or w.t > REFRESH
			local st
			-- 手上的螢幕
			if fresh and not w.busy then
				w.key, w.t = key, 0
				st = rock and state_at(pos)
				if not st then set_screen(player, nil)
				else
					rockmech.info_bubble(player, {numbers(st)}, pos)
					if can_mohr(name) then
						w.busy = true
						send(name, mohr_png(st, SW, SH, string.char(236, 240, 244, 255)), nil, function(fname)
							w.busy = false
							if watch[name] == w and w.key == key then
								set_screen(player, FRAME .. ("^[combine:%dx%d:%d,%d="):format(TW, TH, SX, SY) .. fname)
							end
						end)
					else
						set_screen(player, SCREEN_IDLE)
					end
				end
			end
			-- 按住右鍵：正面看；放開就收起來
			local hold = player:get_player_control().place
			if hold and not player:get_attach() then
				w.big_on = true
				w.big_t = (w.big_t or 0) + dt
				if (w.big_key ~= key or w.big_t > REFRESH) and not w.big_busy then
					w.big_t = 0
					if st == nil and rock then st = state_at(pos) end
					big_show(player, w, st or nil, key)
				end
			elseif w.big_on then
				w.big_on = false
				big_remove(player, w)
			end
		end
	end
end)

core.register_craftitem(TABLET, {
	description = S("Numerical analysis tablet\nHold it to see the stress of the rock you point at; hold right-click to look at it up close"),
	short_description = S("Numerical analysis tablet"),
	inventory_image = "[fill:16x16:#00000000^[fill:14x11:1,3:#1e1e22^[fill:12x9:2,4:#dfe6ee^[fill:12x2:2,4:#3a6aa0^[fill:5x4:6,7:#1f5fbf^[fill:5x1:4,10:#d03030",
	wield_image = SCREEN_IDLE,
	wield_scale = {x = 1.15, y = 0.86, z = 0.12},
	stack_max = 1,
	-- 右鍵本身不做事（按住右鍵正面看，由上面每一步檢查）
	on_place = function(itemstack) return itemstack end,
	on_secondary_use = function(itemstack) return itemstack end,
})

-- 重新連線時，手上平板的螢幕還指著上次的暫時檔（已經沒有了）：背包裡的平板都換回待機畫面
core.register_on_joinplayer(function(player)
	local inv = player:get_inventory()
	for i, st in ipairs(inv:get_list("main") or {}) do
		if st:get_name() == TABLET and st:get_meta():get_string("wield_image") ~= "" then
			st:get_meta():set_string("wield_image", "")
			inv:set_stack("main", i, st)
		end
	end
end)
core.register_on_leaveplayer(function(player) watch[player:get_player_name()] = nil end)
