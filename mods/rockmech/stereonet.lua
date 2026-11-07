-- rockmech/stereonet.lua
-- 赤平投影（串接地質羅盤）：
--   羅盤左鍵岩面：量這一格的節理位態（切過這一格的節理組，每組記一筆，加上量測誤差：傾角 ±3°、傾向 ±5°）
--   羅盤蹲下＋左鍵：量坡面位態（周圍 7×7 的地表擬合一個平面）
--   羅盤對空中右鍵：打開赤平投影圖（下半球、等角投影 Wulff）：各筆量測的極點（依節理組上色）、各組平均位態的大圓、
--     坡面的大圓和極點、摩擦圓（節理摩擦角 φj：極點在圓內的面比 φj 緩，不會平面滑動）。
--   Markland 平面滑動：節理極點在摩擦圓外、跟坡面極點同一側而且比坡面緩（大圓在坡面大圓裡面）→ 可能滑動。
-- 圖是伺服器即時畫的 PNG（512×512），只傳給看的人。量測記在羅盤上（換一把羅盤就是新的一本）。

local cfg = rockmech.cfg
local S = rockmech.S
local joints = rockmech.joints
local COMPASS = "rockmech:compass"
local FORM = "rockmech:stereonet"
local MAX_N = 200
local SIZE, RAD = 512, 230              -- 圖的像素、投影圓半徑
local rad, deg = math.rad, math.deg

local function data_of(stack)
	local d = core.deserialize(stack:get_meta():get_string("stereo"))
	return type(d) == "table" and d or {m = {}}
end
local function save(stack, d)
	stack:get_meta():set_string("stereo", core.serialize(d))
	stack:get_meta():set_string("description", d.slope
		and S("Geological compass (stereonet: @1 joint readings, slope)", tostring(#d.m))
		or S("Geological compass (stereonet: @1 joint readings)", tostring(#d.m)))
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

local function draw(d)
	local c = canvas()
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
	local phi = cfg.weakness and cfg.weakness.phi or 30
	local rf = RAD * math.tan(rad(phi) / 2)
	local red = string.char(220, 60, 60, 255)
	for t = 0, 360, 1.5 do c.dot(CX + rf * math.sin(rad(t)), CY - rf * math.cos(rad(t)), red, 2) end
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
	return c.png(), means
end

---------------------------------------------------------------------------
-- 選單
---------------------------------------------------------------------------
local serial = 0
local function show(name, d)
	local png, means = draw(d)
	serial = serial + 1
	local fname = ("rockmech_stereo_%s_%d.png"):format(name:gsub("[^%w_]", "_"), serial)
	local dir = core.get_worldpath() .. "/rockmech_media"
	core.mkdir(dir)
	local path = dir .. "/" .. fname
	local fh = io.open(path, "wb")
	if not fh then return end
	fh:write(png)
	fh:close()
	local sets = rockmech.get_joint_sets()
	local lines = {}
	for _, m in ipairs(means) do
		local js = sets[m.s]
		lines[#lines + 1] = core.colorize(js and js.color or "#ffffff", S("@1: @2 readings, mean @3°/@4°", js and js.name or S("Set @1", tostring(m.s)), tostring(m.n), ("%02.0f"):format(m.d), ("%03.0f"):format(m.a)))
	end
	lines[#lines + 1] = d.slope and S("Slope: @1°/@2° (thick black line; the square is its pole)", ("%02.0f"):format(d.slope.d), ("%03.0f"):format(d.slope.a))
		or S("Slope: not measured yet (sneak + left-click to measure the slope)")
	lines[#lines + 1] = core.colorize("#ff8080", S("Red circle: friction circle φj = @1°", ("%g"):format(cfg.weakness and cfg.weakness.phi or 30)))
	core.dynamic_add_media({filepath = path, to_player = name, ephemeral = true}, function()
		local out = {"formspec_version[6]size[17,11]",
			"label[0.4,0.5;" .. core.formspec_escape(S("Stereonet (lower hemisphere, equal-angle projection)   dip/dip direction   north is up")) .. "]",
			("image[0.4,0.9;9.8,9.8;%s]"):format(fname),
			("textarea[10.6,0.9;6.1,7.6;;;%s]"):format(core.formspec_escape(table.concat(lines, "\n") .. "\n\n" ..
				S("Left-click a rock face: measure joints (one reading per set)\nSneak + left-click: measure the slope\n\nMarkland planar sliding: a joint pole outside the friction circle, on the same side as the slope pole, and flatter than the slope (its great circle inside the slope's great circle) → sliding is possible"))),
			"button[10.6,8.8;3,0.7;clear;" .. core.formspec_escape(S("Clear readings")) .. "]",
			"button_exit[13.8,8.8;3,0.7;close;" .. core.formspec_escape(S("Close")) .. "]"}
		core.show_formspec(name, FORM, table.concat(out))
		core.after(30, function() os.remove(path) end)
	end)
end

core.override_item(COMPASS, {
	description = S("Geological compass\nRight-click a rock face: stress and factor of safety; sneak + right-click: full data\nLeft-click a rock face: measure joint orientation (stereonet); sneak + left-click: measure the slope; right-click the air: open the stereonet"),
	short_description = S("Geological compass"),
	on_use = function(itemstack, user, pointed)
		if not (user and user:is_player()) or pointed.type ~= "node" then return itemstack end
		local name = user:get_player_name()
		local pos = pointed.under
		local d = data_of(itemstack)
		if user:get_player_control().sneak then
			local s = measure_slope(pos)
			if not s then tell(name, S("Cannot measure a slope here")); return itemstack end
			d.slope = s
			save(itemstack, d)
			tell(name, S("Slope @1°/@2° (dip/dip direction) recorded", ("%02.0f"):format(s.d), ("%03.0f"):format(s.a)))
			return itemstack
		end
		if not rockmech.lith_of_node[core.get_node(pos).name] then tell(name, S("Measure on a rock face")); return itemstack end
		local ms = measure_joints(pos)
		if #ms == 0 then tell(name, S("No joint cuts through this block (intact rock bridge); try another block")); return itemstack end
		local sets = rockmech.get_joint_sets()
		local txt = {}
		for _, m in ipairs(ms) do
			if #d.m >= MAX_N then table.remove(d.m, 1) end
			d.m[#d.m + 1] = m
			txt[#txt + 1] = core.colorize(sets[m.s].color or "#ffffff", ("%s %02.0f°/%03.0f°"):format(sets[m.s].name, m.d, m.a))
		end
		save(itemstack, d)
		tell(name, S("Measured @1 (@2 readings in total; right-click the air to see the stereonet)", table.concat(txt, ", "), tostring(#d.m)))
		return itemstack
	end,
	on_secondary_use = function(itemstack, user)
		if user and user:is_player() then show(user:get_player_name(), data_of(itemstack)) end
		return itemstack
	end,
})

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	if fields.clear then
		local stack = player:get_wielded_item()
		if stack:get_name() == COMPASS then
			save(stack, {m = {}})
			player:set_wielded_item(stack)
			show(player:get_player_name(), {m = {}})
		end
	end
	return true
end)

rockmech.stereonet_draw = draw        -- 測試用
