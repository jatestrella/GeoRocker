-- rockmech/stereonet.lua
-- 地質羅盤＋赤平投影（量測記在野帳本上）：
--   羅盤右鍵岩面：量這一格的節理位態（切過這一格的節理組，每組一筆，加上量測誤差：傾角 ±3°、傾向 ±5°），顯示在準心右上
--   Shift＋E：量坡面位態（周圍 7×7 的地表擬合一個平面）
--   E：把剛量到的記進野帳本（背包裡要有野帳本）
--   赤平投影圖在野帳本的「赤平投影」分頁（下半球、等角投影 Wulff）：各筆量測的極點（依節理組上色）、各組平均位態的大圓、
--     坡面的大圓和極點、各組的摩擦圓（φj = atan(Jr/Ja)：極點在圓內的面比 φj 緩，不會平面滑動）。
--   Markland 平面滑動：節理極點在摩擦圓外、跟坡面極點同一側而且比坡面緩（大圓在坡面大圓裡面）→ 可能滑動。
-- 圖是伺服器即時畫的 PNG（512×512），只傳給看的人。量測記在野帳本上（換一本野帳本就是新的紀錄）。

local cfg = rockmech.cfg
local S = rockmech.S
local joints = rockmech.joints
local COMPASS = "rockmech:compass"
local MAX_N = 200
local SIZE, RAD = 512, 230              -- 圖的像素、投影圓半徑
local rad, deg = math.rad, math.deg

local FIELDBOOK = "rockmech:fieldbook"
local function data_of(stack)
	local d = core.deserialize(stack:get_meta():get_string("stereo"))
	return type(d) == "table" and d or {m = {}}
end
local function save(stack, d)
	stack:get_meta():set_string("stereo", core.serialize(d))
end
-- 背包裡第一本野帳本：回傳 清單索引, 那一疊（沒有回傳 nil）
local function find_book(player)
	local inv = player:get_inventory()
	for i, st in ipairs(inv:get_list("main") or {}) do
		if st:get_name() == FIELDBOOK then return i, st end
	end
end
local function gauss() return (math.random() + math.random() + math.random() - 1.5) * 2 end
local function tell(name, msg) rockmech.notify(name, core.colorize("#80d0ff", S("[Stereonet]") .. " ") .. msg) end

-- 量節理：切過這一格（六個面任一面）而且是節理（不是岩橋）的組
local function measure_joints(pos)
	local sets = rockmech.get_joint_sets()
	local found = {}
	for _, face in ipairs(joints.FACES) do
		local fx, fy, fz, axis = joints.face_key(pos.x, pos.y, pos.z, face)
		for _, it in ipairs(joints.face_info(sets, fx, fy, fz, axis)) do
			if it.joint then found[it.set] = true end
		end
	end
	local out = {}
	for i in pairs(found) do
		local js = sets[i]
		out[#out + 1] = {s = i, d = math.max(0, math.min(90, js.dip_eff + gauss() * 1.5)),
			a = (js.dipdir_eff + gauss() * 2.5) % 360}
	end
	table.sort(out, function(p, q) return p.s < q.s end)
	return out
end

-- 切過這一格的節理組（索引，由小到大；不加量測誤差）
function rockmech.joint_sets_at(pos)
	local sets = rockmech.get_joint_sets()
	local found, out = {}, {}
	for _, face in ipairs(joints.FACES) do
		local fx, fy, fz, axis = joints.face_key(pos.x, pos.y, pos.z, face)
		for _, it in ipairs(joints.face_info(sets, fx, fy, fz, axis)) do
			if it.joint and not found[it.set] then found[it.set] = true; out[#out + 1] = it.set end
		end
	end
	table.sort(out)
	return out
end

-- 量坡面：周圍 7×7 的地表高度最小平方擬合 y = a·x + b·z + c → 傾角、傾向（往下坡的方向；+x 東、+z 北）
local function measure_slope(pos)
	local sx, sz, sxx, szz, sxz, sy, sxy, szy, n = 0, 0, 0, 0, 0, 0, 0, 0, 0
	for dx = -3, 3 do for dz = -3, 3 do
		local top
		for y = pos.y + 8, pos.y - 8, -1 do
			local nd = core.registered_nodes[core.get_node({x = pos.x + dx, y = y, z = pos.z + dz}).name]
			if nd and nd.walkable ~= false then top = y; break end
		end
		if top then
			sx, sz, sxx, szz, sxz = sx + dx, sz + dz, sxx + dx * dx, szz + dz * dz, sxz + dx * dz
			sy, sxy, szy, n = sy + top, sxy + dx * top, szy + dz * top, n + 1
		end
	end end
	if n < 10 then return nil end
	-- 對稱取樣（Σx = Σz = Σxz ≈ 0）時 a = Σxy/Σxx、b = Σzy/Σzz
	local mx, mz, my = sx / n, sz / n, sy / n
	local cxx, czz = sxx / n - mx * mx, szz / n - mz * mz
	local a = (sxy / n - mx * my) / cxx
	local b = (szy / n - mz * my) / czz
	local g = math.sqrt(a * a + b * b)
	if g < 1e-6 then return {d = 0, a = 0} end
	return {d = deg(math.atan(g)), a = deg(math.atan2 and math.atan2(-a, -b) or math.atan(-a, -b)) % 360}
end

---------------------------------------------------------------------------
-- 畫圖
---------------------------------------------------------------------------
local function rgb(hex)
	hex = hex or "#ffffff"
	return tonumber(hex:sub(2, 3), 16) or 255, tonumber(hex:sub(4, 5), 16) or 255, tonumber(hex:sub(6, 7), 16) or 255
end
local function canvas()
	local px = {}
	local white = string.char(255, 255, 255, 255)
	for i = 1, SIZE * SIZE do px[i] = white end
	local c = {}
	function c.dot(x, y, col, r)
		r = r or 1
		x, y = math.floor(x + 0.5), math.floor(y + 0.5)
		for dy = -r + 1, r - 1 do for dx = -r + 1, r - 1 do
			local xx, yy = x + dx, y + dy
			if xx >= 0 and yy >= 0 and xx < SIZE and yy < SIZE and dx * dx + dy * dy < r * r then px[yy * SIZE + xx + 1] = col end
		end end
	end
	function c.set(x, y, col) px[y * SIZE + x + 1] = col end
	function c.png() return core.encode_png(SIZE, SIZE, table.concat(px)) end
	return c
end
local CX, CY = SIZE / 2, SIZE / 2
-- 方向（趨向 trend、傾伏 plunge，度）→ 等角投影的像素
local function proj(trend, plunge)
	local r = RAD * math.tan(rad(90 - plunge) / 2)
	return CX + r * math.sin(rad(trend)), CY - r * math.cos(rad(trend))
end
-- 東、北、上的向量 → 趨向、傾伏（下半球）
local function vec_tp(e, n, u)
	if u > 0 then e, n, u = -e, -n, -u end
	local h = math.sqrt(e * e + n * n)
	return deg(math.atan2 and math.atan2(e, n) or math.atan(e, n)) % 360, deg(math.atan(-u / math.max(h, 1e-9)))
end
local function great_circle(c, d, a, col, w)
	local sa, ca = math.sin(rad(a)), math.cos(rad(a))
	local cd, sd = math.cos(rad(d)), math.sin(rad(d))
	local st = {math.sin(rad(a - 90)), math.cos(rad(a - 90)), 0}        -- 走向
	local dv = {sa * cd, ca * cd, -sd}                                  -- 傾向線（往下）
	for t = 0, 180, 0.25 do
		local ct, s = math.cos(rad(t)), math.sin(rad(t))
		local tr, pl = vec_tp(st[1] * ct + dv[1] * s, st[2] * ct + dv[2] * s, st[3] * ct + dv[3] * s)
		local x, y = proj(tr, pl)
		c.dot(x, y, col, w or 2)
	end
end
local function pole(d, a) return (a + 180) % 360, 90 - d end

-- 運動學分析（Markland 平面、楔形；Goodman 傾倒）：三種破壞模式各一種顏色（避開節理組的紅、藍、黃）
local KIN_COLOR = {planar = "#d050c0", wedge = "#40a050", topple = "#7a5ad8"}
local function angdiff(a, b) local x = (a - b) % 360; return math.min(x, 360 - x) end
local function lat_limit() return (cfg.weakness and cfg.weakness.lateral_limit) or 20 end
-- 這一格像素（離中心 r、方位 th）在極點圖上代表的面：傾角、傾向；當成線看：傾伏、趨向
local function phis_of(d)
	local sets, have, out, seen = rockmech.get_joint_sets(), {}, {}, {}
	for _, m in ipairs(d.m or {}) do have[m.s] = true end
	for i, js in ipairs(sets) do
		if have[i] then
			local phi = js.phi or (cfg.weakness and cfg.weakness.phi) or 30
			if not seen[phi] then seen[phi] = true; out[#out + 1] = phi end
		end
	end
	return out, have
end
-- 塗危險區：平面（極點）、傾倒（極點）、楔形（交線）；幾組 φj 不同時，符合的組越多顏色越深
local function fill_zones(c, d)
	local sl = d.slope
	if not (sl and sl.d > 0.5) then return end
	local phis, have = phis_of(d)
	if #phis == 0 then return end
	local nsets = 0
	for _ in pairs(have) do nsets = nsets + 1 end
	local lam, psi, af = lat_limit(), sl.d, sl.a
	local tpsi = math.tan(rad(psi))
	local phimin = math.min((unpack or table.unpack)(phis))
	local cache = {}
	local function color(kp, kw, kt)
		local key = kp * 100 + kw * 10 + kt
		local v = cache[key]
		if v then return v end
		local r, g, b = 255, 255, 255
		local function mix(hex, a)
			local cr, cg, cb = rgb(hex)
			r, g, b = r * (1 - a) + cr * a, g * (1 - a) + cg * a, b * (1 - a) + cb * a
		end
		if kp > 0 then mix(KIN_COLOR.planar, math.min(0.6, 0.22 + 0.12 * (kp - 1))) end
		if kw > 0 then mix(KIN_COLOR.wedge, 0.28) end
		if kt > 0 then mix(KIN_COLOR.topple, math.min(0.6, 0.22 + 0.12 * (kt - 1))) end
		v = string.char(math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5), 255)
		cache[key] = v
		return v
	end
	local R2 = RAD * RAD
	for py = 0, SIZE - 1 do
		local dy = CY - py
		for px = 0, SIZE - 1 do
			local dx = px - CX
			local r2 = dx * dx + dy * dy
			if r2 <= R2 then
				local dip = 2 * deg(math.atan(math.sqrt(r2) / RAD))        -- 極點 → 面的傾角；當成線：傾伏 = 90 − dip
				local th = deg(math.atan2 and math.atan2(dx, dy) or math.atan(dx, dy)) % 360
				local ddir = (th + 180) % 360
				local kp, kw, kt = 0, 0, 0
				if dip < psi and angdiff(ddir, af) <= lam then
					for _, phi in ipairs(phis) do if dip > phi then kp = kp + 1 end end
				end
				if angdiff(ddir, af + 180) <= lam then
					for _, phi in ipairs(phis) do if dip >= 90 - psi + phi then kt = kt + 1 end end
				end
				if nsets >= 2 then
					local pl, ca = 90 - dip, math.cos(rad(th - af))
					if ca > 0 and pl > phimin and math.tan(rad(pl)) < tpsi * ca then kw = 1 end
				end
				if kp + kw + kt > 0 then c.set(px, py, color(kp, kw, kt)) end
			end
		end
	end
end

-- 運動學分析的結論：各組平均位態、兩兩交線 → {{mode, text}...}
local function kin_verdicts(means, slope)
	local out = {}
	if not (slope and slope.d > 0.5) then return out end
	local sets = rockmech.get_joint_sets()
	local lam, psi, af = lat_limit(), slope.d, slope.a
	local function phi_of(s) local js = sets[s]; return js and js.phi or (cfg.weakness and cfg.weakness.phi) or 30 end
	local function nm(s) return sets[s] and sets[s].name or "?" end
	for _, m in ipairs(means) do
		local phi = phi_of(m.s)
		if angdiff(m.a, af) <= lam and m.d > phi and m.d < psi then
			out[#out + 1] = {mode = "planar", text = S("@1: planar sliding possible", nm(m.s))}
		end
		if angdiff(m.a, af + 180) <= lam and m.d >= 90 - psi + phi then
			out[#out + 1] = {mode = "topple", text = S("@1: toppling possible", nm(m.s))}
		end
	end
	for i = 1, #means do for j = i + 1, #means do
		local a, b = means[i], means[j]
		local function pv(m)
			local tr, pl = pole(m.d, m.a)
			return math.cos(rad(pl)) * math.sin(rad(tr)), math.cos(rad(pl)) * math.cos(rad(tr)), -math.sin(rad(pl))
		end
		local e1, n1, u1 = pv(a)
		local e2, n2, u2 = pv(b)
		local e, n, u = n1 * u2 - u1 * n2, u1 * e2 - e1 * u2, e1 * n2 - n1 * e2
		if e * e + n * n + u * u > 1e-6 then
			local t, p = vec_tp(e, n, u)
			local ca = math.cos(rad(t - af))
			if ca > 0 and p > math.min(phi_of(a.s), phi_of(b.s)) and math.tan(rad(p)) < math.tan(rad(psi)) * ca then
				out[#out + 1] = {mode = "wedge", text = S("@1 × @2 (line @3°/@4°): wedge sliding possible", nm(a.s), nm(b.s),
					("%02.0f"):format(p), ("%03.0f"):format(t))}
			end
		end
	end end
	if #out == 0 then out[1] = {text = S("No kinematically possible failure mode")} end
	for _, v in ipairs(out) do v.color = v.mode and KIN_COLOR[v.mode] end
	return out
end

-- kin：會「赤平投影穩定性分析」：塗危險區、畫交線、回傳結論
local function draw(d, kin)
	local c = canvas()
	if kin then fill_zones(c, d) end
	local grey, black = string.char(200, 200, 200, 255), string.char(30, 30, 30, 255)
	-- 經緯網（每 10° 一條淡的大圓：南北走向的）
	for k = 10, 80, 10 do great_circle(c, k, 90, grey, 1); great_circle(c, k, 270, grey, 1) end
	-- 外圓與方位刻度
	for t = 0, 360, 0.2 do c.dot(CX + RAD * math.sin(rad(t)), CY - RAD * math.cos(rad(t)), black, 2) end
	for t = 0, 350, 10 do
		local r2 = t % 90 == 0 and RAD + 14 or RAD + 7
		for r = RAD, r2 do c.dot(CX + r * math.sin(rad(t)), CY - r * math.cos(rad(t)), black, 1) end
	end
	c.dot(CX, CY, black, 3)
	-- 摩擦圓：極點離中心 φj 以內 = 傾角比 φj 緩
	-- 只畫有量到的節理組，顏色跟那一組的極點一樣；φj 相同的幾組共用一個圓，虛線輪流用各組的顏色
	local sets = rockmech.get_joint_sets()
	local have = {}
	for _, m in ipairs(d.m or {}) do have[m.s] = true end
	local circles, by_phi = {}, {}
	for i, js in ipairs(sets) do
		if have[i] then
			local phi = js.phi or (cfg.weakness and cfg.weakness.phi) or 30
			local k = ("%.1f"):format(phi)
			if not by_phi[k] then by_phi[k] = {phi = phi, cols = {}}; circles[#circles + 1] = by_phi[k] end
			local h = (js.color or "#dc3c3c"):gsub("#", "")
			local cols = by_phi[k].cols
			cols[#cols + 1] = string.char(tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16), 255)
		end
	end
	for _, cr in ipairs(circles) do
		local rf = RAD * math.tan(rad(cr.phi) / 2)
		for t = 0, 359, 1.5 do
			local col = cr.cols[math.floor(t / 12) % #cr.cols + 1]       -- 每 12° 換一個顏色
			c.dot(CX + rf * math.sin(rad(t)), CY - rf * math.cos(rad(t)), col, 2)
		end
	end
	-- 坡面：大圓（粗黑）與極點（方塊）
	if d.slope and d.slope.d > 0.5 then
		great_circle(c, d.slope.d, d.slope.a, black, 3)
		local x, y = proj(pole(d.slope.d, d.slope.a))
		for k = -6, 6 do for l = -6, 6 do c.dot(x + k, y + l, black, 1) end end
	end
	-- 節理：各組平均的大圓、每筆的極點
	local sets = rockmech.get_joint_sets()
	local sum = {}
	for _, m in ipairs(d.m) do
		local js = sets[m.s]
		local r, g, b = rgb(js and js.color)
		local col = string.char(r, g, b, 255)
		local tr, pl = pole(m.d, m.a)
		local x, y = proj(tr, pl)
		c.dot(x, y, col, 5)
		-- 平均：極點向量相加
		local e = math.cos(rad(pl)) * math.sin(rad(tr))
		local nn = math.cos(rad(pl)) * math.cos(rad(tr))
		local u = -math.sin(rad(pl))
		local sm = sum[m.s] or {0, 0, 0, 0, col}
		sm[1], sm[2], sm[3], sm[4] = sm[1] + e, sm[2] + nn, sm[3] + u, sm[4] + 1
		sum[m.s] = sm
	end
	local means = {}
	for s, sm in pairs(sum) do
		local tr, pl = vec_tp(sm[1], sm[2], sm[3])
		local dd, aa = 90 - pl, (tr + 180) % 360
		great_circle(c, dd, aa, sm[5], 2)
		means[#means + 1] = {s = s, d = dd, a = aa, n = sm[4]}
	end
	table.sort(means, function(p, q) return p.s < q.s end)
	local verdicts
	if kin then
		-- 兩兩交線：深灰色的 ×
		local dark = string.char(40, 40, 40, 255)
		for i = 1, #means do for j = i + 1, #means do
			local function pv(m)
				local tr, pl = pole(m.d, m.a)
				return math.cos(rad(pl)) * math.sin(rad(tr)), math.cos(rad(pl)) * math.cos(rad(tr)), -math.sin(rad(pl))
			end
			local e1, n1, u1 = pv(means[i])
			local e2, n2, u2 = pv(means[j])
			local e, n, u = n1 * u2 - u1 * n2, u1 * e2 - e1 * u2, e1 * n2 - n1 * e2
			if e * e + n * n + u * u > 1e-6 then
				local x, y = proj(vec_tp(e, n, u))
				for k = -6, 6 do c.dot(x + k, y + k, dark, 2); c.dot(x + k, y - k, dark, 2) end
			end
		end end
		verdicts = kin_verdicts(means, d.slope)
	end
	return c.png(), means, verdicts
end

---------------------------------------------------------------------------
-- 選單
---------------------------------------------------------------------------
local serial = 0
-- 畫好圖、傳給玩家：cb(檔名, info)，info = {means = {{s, n, d, a}...}, slope}（野帳本的分頁用）
local function media(name, d, cb)
	local kin = not rockmech.can_see or rockmech.can_see(name, "kinematics", true)
	local png, means, verdicts = draw(d, kin)
	serial = serial + 1
	local fname = ("rockmech_stereo_%s_%d.png"):format(name:gsub("[^%w_]", "_"), serial)
	local dir = core.get_worldpath() .. "/rockmech_media"
	core.mkdir(dir)
	local path = dir .. "/" .. fname
	local fh = io.open(path, "wb")
	if not fh then return end
	fh:write(png)
	fh:close()
	core.dynamic_add_media({filepath = path, to_player = name, ephemeral = true}, function()
		cb(fname, {means = means, slope = d.slope, kin = verdicts})
		core.after(30, function() os.remove(path) end)
	end)
end
rockmech.stereonet_media = media
rockmech.stereonet_data = data_of
rockmech.stereonet_clear = function(stack) save(stack, {m = {}}) end

-- 剛量到、還沒記進野帳本的那一筆：玩家名 → {m = {...}} 或 {slope = ...}
local last = {}
local function bubble(player, lines, pos)
	if rockmech.info_bubble then rockmech.info_bubble(player, lines, pos) else tell(player:get_player_name(), table.concat(lines, " ")) end
end

-- 右鍵岩面：量節理
local function measure(itemstack, user, pointed)
	if not (user and user:is_player()) or pointed.type ~= "node" then return itemstack end
	local name = user:get_player_name()
	local pos = pointed.under
	if not rockmech.lith_of_node[core.get_node(pos).name] then bubble(user, {S("Measure on a rock face")}, pos); return itemstack end
	local ms = measure_joints(pos)
	if #ms == 0 then bubble(user, {S("No joint cuts through this block (intact rock bridge); try another block")}, pos); return itemstack end
	local sets = rockmech.get_joint_sets()
	local txt = {}
	local numbers = rockmech.can_see_q and rockmech.can_see_q(user)
	for _, m in ipairs(ms) do
		txt[#txt + 1] = core.colorize(sets[m.s].color or "#ffffff", ("%s  %02.0f° / %03.0f°"):format(sets[m.s].name, m.d, m.a))
		-- 節理面的狀況：描述（ISRM）；有 Q 法圖表才有 Jr、Ja、φj
		if rockmech.joint_condition_lines then
			for _, l in ipairs(rockmech.joint_condition_lines(sets[m.s], numbers)) do txt[#txt + 1] = l end
		end
	end
	txt[#txt + 1] = S("E: write into the field notebook")
	last[name] = {m = ms}
	bubble(user, txt, pos)
	return itemstack
end

core.override_item(COMPASS, {
	description = S("Geological compass\nRight-click a rock face to measure joints; Shift + E measures the slope; E writes it into the field notebook"),
	short_description = S("Geological compass"),
	on_use = nil,
	on_place = measure,
})

-- E：記進野帳本；Shift＋E：量坡面。拿著羅盤、沒坐在車上；按下去那一下才算
local e_down = {}
core.register_globalstep(function()
	for _, pl in ipairs(core.get_connected_players()) do
		local name = pl:get_player_name()
		local c = pl:get_player_control()
		if c.aux1 and not e_down[name] and not pl:get_attach() and pl:get_wielded_item():get_name() == COMPASS then
			if c.sneak then
				local pos = rockmech.pointed_node_pos and rockmech.pointed_node_pos(pl, 8)
				local sl = pos and measure_slope(pos)
				if not sl then bubble(pl, {S("Cannot measure a slope here")}, pos)
				else
					last[name] = {slope = sl}
					bubble(pl, {S("Slope @1° / @2° (dip / dip direction)", ("%02.0f"):format(sl.d), ("%03.0f"):format(sl.a)), S("E: write into the field notebook")}, pos)
				end
			else
				local l = last[name]
				local i, book = find_book(pl)
				if not l then bubble(pl, {S("Measure something first (right-click a rock face)")})
				elseif not book then bubble(pl, {S("You need a field notebook (the readings are kept in it)")})
				else
					local d = data_of(book)
					if l.slope then d.slope = l.slope end
					for _, m in ipairs(l.m or {}) do
						if #d.m >= MAX_N then table.remove(d.m, 1) end
						d.m[#d.m + 1] = m
					end
					save(book, d)
					pl:get_inventory():set_stack("main", i, book)
					last[name] = nil
					bubble(pl, {l.slope and S("Slope written into the field notebook")
						or S("Written into the field notebook (@1 joint readings; see the stereonet tab)", tostring(#d.m))})
				end
			end
		end
		e_down[name] = c.aux1
	end
end)
core.register_on_leaveplayer(function(pl) e_down[pl:get_player_name()] = nil; last[pl:get_player_name()] = nil end)

rockmech.stereonet_draw = draw        -- 測試用
rockmech.stereonet_kin_colors = KIN_COLOR
