-- rockmech/tablet.lua
-- 數值分析平板（大地技師賣）：平板上跑數值模型，看準心指著那一格岩石的應力狀態。
--   拿在手上：平板的螢幕即時畫那一格的 Mohr 圓（應力解的 σ1、σ3）和強度包絡線（岩體：紅；完整岩石：灰色虛線）；
--     σ1、σ3 的數字顯示在資訊泡泡。不會「Mohr 圓分析」（只能考試學會）的人，螢幕上只有軟體畫面、沒有圓，數字照樣有。
--   右鍵：大視窗正面看（大張的 Mohr 圓、刻度、破壞時的 σ1、強度 / 應力）。
-- 螢幕是伺服器畫的 PNG（暫時的媒體檔，傳給大家：別人看你手上的平板也看得到），換到這把平板的 wield_image（物品 meta）。

local S = rockmech.S
local M = rockmech.mohr
local TABLET = "rockmech:fea_tablet"
local FORM = "rockmech:fea_tablet"
local SW, SH = 144, 104                 -- 螢幕的像素
local FRAME = "[fill:160x120:#1e1e22"
local SCREEN_IDLE = FRAME .. "^[fill:" .. SW .. "x" .. SH .. ":8,8:#dfe6ee^[fill:" .. SW .. "x12:8,8:#3a6aa0"
local TICK, REFRESH = 0.4, 2            -- 檢查間隔；同一格多久重算一次（周圍可能已經開挖）

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

-- 換手上平板的螢幕（tex = nil：沒在看東西）
local function set_screen(player, tex)
	local stack = player:get_wielded_item()
	if stack:get_name() ~= TABLET then return end
	local meta = stack:get_meta()
	local v = tex or ""
	if meta:get_string("wield_image") == v then return end
	meta:set_string("wield_image", v)
	player:set_wielded_item(stack)
end

-- 暫時的媒體檔傳給所有人（別人也看得到你手上的平板），拿著的人收到了才換螢幕
local serial = 0
local function broadcast(name, png, cb)
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
	core.dynamic_add_media({filepath = path, ephemeral = true}, function(who)
		if who == name and not done then done = true; cb(fname) end
	end)
	core.after(60, function() os.remove(path) end)
end

local watch = {}        -- 玩家名稱 → {key, t, busy}
local t_acc = 0
core.register_globalstep(function(dtime)
	t_acc = t_acc + dtime
	if t_acc < TICK then return end
	local dt = t_acc
	t_acc = 0
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		if player:get_wielded_item():get_name() ~= TABLET then
			watch[name] = nil
		else
			local w = watch[name] or {t = 0}
			watch[name] = w
			w.t = w.t + dt
			local pos = rockmech.pointed_node_pos and rockmech.pointed_node_pos(player, 8)
			local node = pos and core.get_node(pos)
			if not (node and rockmech.lith_of_node[node.name]) then
				if w.key then w.key = nil; set_screen(player, nil) end
			else
				local key = core.pos_to_string(pos)
				if (w.key ~= key or w.t > REFRESH) and not w.busy then
					w.key, w.t = key, 0
					local st = state_at(pos)
					if not st then set_screen(player, nil)
					else
						rockmech.info_bubble(player, {numbers(st)}, pos)
						if can_mohr(name) then
							w.busy = true
							broadcast(name, mohr_png(st, SW, SH, string.char(236, 240, 244, 255)), function(fname)
								w.busy = false
								if watch[name] == w and w.key == key then
									set_screen(player, FRAME .. "^[combine:160x120:8,8=" .. fname)
								end
							end)
						else
							set_screen(player, SCREEN_IDLE)
						end
					end
				end
			end
		end
	end
end)

-- 右鍵：大視窗正面看
local BW, BH = 600, 380
local function show_big(player, pos)
	local name = player:get_player_name()
	pos = pos or (rockmech.pointed_node_pos and rockmech.pointed_node_pos(player, 8))
	local node = pos and core.get_node(pos)
	local st = node and rockmech.lith_of_node[node.name] and state_at(pos)
	local E = core.formspec_escape
	if not st then
		rockmech.info_bubble(player, {S("Point the tablet at rock")})
		return
	end
	local rm = st.rm
	local f_mass = M.s1_fail(rm.sigci, rm.mb, rm.s, rm.a, st.s3)
	local f_int = M.s1_fail(rm.sigci, st.lith.mi or 10, 1, 0.5, st.s3)
	local lines = {
		S("@1, GSI @2", S(st.lith.description), tostring(rm.gsi)),
		numbers(st),
		S("Rock mass: σ1 at failure @1 MPa, strength / stress @2", ("%.2f"):format(f_mass), ("%.2f"):format(f_mass / math.max(st.s1, 1e-6))),
		S("Intact rock: σ1 at failure @1 MPa", ("%.2f"):format(f_int)),
	}
	if not can_mohr(name) then
		lines[#lines + 1] = ""
		lines[#lines + 1] = S("Learn \"Mohr circle analysis\" from the professor to see the Mohr circle")
		core.show_formspec(name, FORM, "formspec_version[6]size[11,5]box[0.3,0.3;10.4,4.4;#1e1e22]" ..
			("textarea[0.6,0.6;9.8,3.8;;;%s]"):format(E(table.concat(lines, "\n"))))
		return
	end
	local png, ax = mohr_png(st, BW, BH, string.char(244, 246, 248, 255))
	M.send(name, png, function(fname)
		local W, H = 10.4, 10.4 * BH / BW
		local out = {"formspec_version[6]size[11.6,10.6]", "box[0.4,0.3;10.8,9.95;#1e1e22]",
			("image[0.6,0.5;%g,%g;%s]"):format(W, H, fname)}
		local sc = W / BW
		for v = math.ceil(ax.smin / ax.step) * ax.step, ax.smax, ax.step do
			local x = 0.6 + (ax.x0 + v * ax.k) * sc
			if x > 0.7 and x < 0.6 + W - 0.3 then
				out[#out + 1] = ("label[%g,%g;%s]"):format(x - 0.15, 0.5 + H + 0.25, E(("%g"):format(v)))
			end
		end
		out[#out + 1] = ("label[%g,%g;%s]"):format(0.6 + W - 1.4, 0.5 + H + 0.6, E(S("σn (MPa)")))
		out[#out + 1] = ("label[0.7,0.75;%s]"):format(E("τ"))
		local y = 0.5 + H + 1.0
		local colors = {nil, M.COLOR.circle, M.COLOR.mass, M.COLOR.intact}
		for i, l in ipairs(lines) do
			if colors[i] then out[#out + 1] = ("box[0.7,%g;0.25,0.25;%s]"):format(y - 0.12, colors[i]) end
			out[#out + 1] = ("label[1.1,%g;%s]"):format(y, E(l))
			y = y + 0.42
		end
		core.show_formspec(name, FORM, table.concat(out))
	end)
end

core.register_craftitem(TABLET, {
	description = S("Numerical analysis tablet\nHold it to see the stress of the rock you point at; right-click for a full view"),
	short_description = S("Numerical analysis tablet"),
	inventory_image = "[fill:16x16:#00000000^[fill:14x11:1,3:#1e1e22^[fill:12x9:2,4:#dfe6ee^[fill:12x2:2,4:#3a6aa0^[fill:5x4:6,7:#1f5fbf^[fill:5x1:4,10:#d03030",
	wield_image = SCREEN_IDLE,
	wield_scale = {x = 1.6, y = 1.2, z = 0.15},
	stack_max = 1,
	on_place = function(itemstack, player, pointed)
		if player and player:is_player() then show_big(player, pointed.type == "node" and pointed.under or nil) end
		return itemstack
	end,
	on_secondary_use = function(itemstack, player)
		if player and player:is_player() then show_big(player) end
		return itemstack
	end,
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
