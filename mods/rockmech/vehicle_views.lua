-- rockmech/vehicle_views.lua
-- 駕駛的 HUD：說明文字、駕駛艙框（全螢幕圖片）、後照鏡與倒車攝影機畫面。由 vehicles.lua 載入。

local V = rockmech.vehicles
local TYPES, NLEV = V.TYPES, V.NLEV
local h2v, CLEAR, PART = V.h2v, V.CLEAR, V.PART

-- 外觀與名牌（各車的 refresh）
function V.refresh(self)
	local def = TYPES[self.vkind]
	if def and def.refresh then def.refresh(self) end
end

-- 駕駛的 HUD 文字：車名、載量、各車自己的說明
local function hud_text(self)
	local def = TYPES[self.vkind]
	local s = def.desc
	if def.cap > 0 then
		local t = V.load_total(self)
		s = s .. ("　載量 %d / %d 級（%.1f / %.0f m³）"):format(t, def.cap, t / NLEV, def.cap / NLEV)
	end
	if def.hud then s = s .. def.hud(self) end
	if def.top_speed then s = s .. ("　%d km/h"):format(self.kmh or 0) end
	if self.steep then s = s .. "\n" .. self.steep end
	return s .. "　Z 切換視角　Shift 下車"
end

-- 駕駛艙框（全螢幕 HUD 圖片，中間透明）：上方車頂邊條、左右 A 柱（車身顏色）、左右上方後照鏡、下方儀表板
local function cockpit_tex(kind)
	local c = TYPES[kind].color
	local dark, mid = "#1e1e1e", "#2c2c2c"
	return table.concat({
		"[fill:160x90:#00000000",
		"^[fill:160x7:0,0:" .. dark, "^[fill:160x2:0,7:" .. c,                        -- 車頂邊條
		"^[fill:10x90:0,0:" .. c, "^[fill:2x90:10,0:" .. dark,                          -- 左 A 柱
		"^[fill:10x90:150,0:" .. c, "^[fill:2x90:148,0:" .. dark,                       -- 右 A 柱
		"^[fill:6x8:12,9:" .. c, "^[fill:6x8:142,9:" .. c,                              -- 柱子上方的斜角
		"^[fill:3x6:18,9:" .. c, "^[fill:3x6:139,9:" .. c,
		"^[fill:160x2:0,70:" .. c, "^[fill:160x18:0,72:" .. mid,                       -- 儀表板
		"^[fill:14x8:18,78:#101010^[fill:12x6:19,79:#203828",                            -- 儀表
		"^[fill:14x8:128,78:#101010^[fill:12x6:129,79:#382820",
		-- 後照鏡（左上、右上）：支架 + 鏡框；鏡面 24×14（x 18／118、y 11 起）上面再疊後照鏡畫面
		"^[fill:6x2:12,17:#303030", "^[fill:26x16:17,10:#151515", "^[fill:24x14:18,11:#7f9fb8",
		"^[fill:6x2:142,17:#303030", "^[fill:26x16:117,10:#151515", "^[fill:24x14:118,11:#7f9fb8",
		(TYPES[kind].rearcam or TYPES[kind].cam) and "^[fill:38x23:61,9:#151515^[fill:2x1:79,32:#303030" or "",   -- 倒車／作業攝影機螢幕
	})
end

-- 後照鏡、倒車攝影機畫面：Luanti 只有一個相機，所以這些畫面是伺服器從鏡頭位置往後打射線、
-- 依碰到的東西上色拼成的小圖（每 MIRROR_DT 秒更新）。
-- 畫方塊、車輛（含自己的車：用實際掛著的零件方塊，位置、旋轉、貼圖照實）與沒在車上的玩家；遠處淡入天空色
local MIRROR_RANGE = 24                                         -- m
local MIRROR_DT = 0.35
local SKY = {0x9c, 0xc0, 0xe4}
-- 畫面：o 鏡頭位置（車身座標；swing → 用上部結構座標、跟著挖土機迴轉）、dir 中心朝向（從正後方往右偏的角度）、
-- down 往下的角度、hfov／vfov 視角、w × h 解析度、hud 在駕駛艙框（160×90）裡的左上角與大小
local function mirror_view(side, m)
	return {o = {x = side * m.x, y = m.y, z = m.z}, dir = side * math.rad(14), down = math.rad(5),
		hfov = math.rad(44), vfov = math.rad(26), w = 24, h = 14, swing = true,
		hud = {x = side < 0 and 18 or 118, y = 11, w = 24, h = 14}}
end
local REARCAM_HUD = {x = 62, y = 10, w = 36, h = 20.25}
local function views_of(kind)
	local def = TYPES[kind]
	local v = {mirror_view(-1, def.mirror), mirror_view(1, def.mirror)}
	if def.rearcam then
		v[3] = {o = def.rearcam, dir = 0, down = math.rad(24), hfov = math.rad(80), vfov = math.rad(42),
			w = 40, h = 22, hud = REARCAM_HUD}
	elseif def.cam then
		-- 作業攝影機（例如露天鑽機看桅桿腳）：對準 def.cam.target、不鏡像（flip = false → 和倒車攝影機一樣鏡像）、
		-- 在 def.cam.mark 畫紅色十字、def.cam.holes 公尺內的孔畫色點
		local c = def.cam
		v[3] = {o = c.o, target = c.target, hfov = c.hfov, vfov = c.vfov, flip = c.flip ~= false, mark = c.mark, holes = c.holes,
			w = c.w or 40, h = c.h or 22, hud = REARCAM_HUD}
	end
	return v
end

local function hex_rgb(h)
	return {tonumber(h:sub(2, 3), 16), tonumber(h:sub(4, 5), 16), tonumber(h:sub(6, 7), 16)}
end
-- 方塊顏色：岩石用岩性顏色、碎石用碎石顏色，其他依群組大略給
local node_rgb = {}
local function rgb_of(name)
	local c = node_rgb[name]
	if c then return c end
	local lith, base = rockmech.lith_of_node[name], rockmech.rubble_base[name]
	local h
	if lith then h = lith.color
	elseif base == rockmech.RUBBLE_GRANITE then h = rockmech.cfg.lithologies.granite.color
	elseif base then h = "#6a6058"
	elseif name == "rockmech:drill_hole" then h = "#e0d8c8"                                   -- 鑽孔：孔口一圈淺色岩粉
	elseif name == "rockmech:charged_hole" or name == "rockmech:surface_charge" then h = "#e8c070"   -- 裝藥：黃點
	elseif name == "rockmech:anfo_hole" or name == "rockmech:anfo_primed" then h = "#e890b0"         -- ANFO：粉紅點
	else
		local g = (core.registered_nodes[name] or {}).groups or {}
		h = name:find("grass") and "#5a8a38" or g.leaves and "#356a28" or g.tree and "#6b5030"
			or g.sand and "#d8c890" or g.soil and "#6b4a2b" or g.water and "#3a68b0" or "#808080"
	end
	c = hex_rgb(h)
	node_rgb[name] = c
	return c
end

-- [fill 組合貼圖 → 色塊清單（後面的蓋前面的）；不是 [fill 組合（例如碎石方塊貼圖）→ false
local tex_cache = {}
local function tex_rects(t)
	local r = tex_cache[t]
	if r ~= nil then return r end
	r = {}
	for op in (t .. "^"):gmatch("(.-)%^") do
		local w, h, x, y, c = op:match("^%[fill:(%d+)x(%d+):(%d+),(%d+):(#%x+)$")
		if not w then w, h, c = op:match("^%[fill:(%d+)x(%d+):(#%x+)$"); x, y = 0, 0 end
		if not w then r = false; break end
		r[#r + 1] = {tonumber(x), tonumber(y), tonumber(w), tonumber(h), c}
	end
	if r and #r == 0 then r = false end
	if r then r.W, r.H = r[1][3], r[1][4] end
	tex_cache[t] = r
	return r
end
-- 貼圖在 (u, v)（0～1，v 往下）的顏色；不認得的貼圖當碎石色
local function tex_color(t, u, v)
	local r = tex_rects(t)
	if not r then return "#6a6058" end
	local px, py = u * r.W, v * r.H
	for k = #r, 1, -1 do
		local q = r[k]
		if px >= q[1] and px < q[1] + q[3] and py >= q[2] and py < q[2] + q[4] then return q[5] end
	end
	return r[1][5]
end

-- 掛載旋轉（度；先繞 X、再繞 Y，與 seg_attach 相同）作用在零件座標的向量上
local function attach_rot(v, rx, ry)
	local cx, sx = math.cos(math.rad(rx)), math.sin(math.rad(rx))
	return h2v({x = v.x, y = v.y * cx - v.z * sx, z = v.y * sx + v.z * cx}, math.rad(ry))
end
local AXES = {{x = 1, y = 0, z = 0}, {x = 0, y = 1, z = 0}, {x = 0, y = 0, z = 1}}
-- 一台車（本體看得見時）與它的零件 → 世界座標的有向箱子 {c 中心, ax 三軸, h 半邊長, tex 六面貼圖}。
-- 只用車子的 yaw（地形傾斜不算）。實體 yaw 對應 h2v(·, −yaw)
local function vehicle_boxes(o, boxes)
	local p, yaw = o:get_pos(), o:get_yaw()
	local function add(off, rx, ry, size, textures)
		local ax = {}
		for i, e in ipairs(AXES) do ax[i] = h2v(attach_rot(e, rx, ry), -yaw) end
		boxes[#boxes + 1] = {c = vector.add(p, h2v(off, -yaw)), ax = ax,
			h = {size.x / 2, size.y / 2, size.z / 2}, tex = textures}
	end
	local pr = o:get_properties()
	if pr.textures[1] ~= CLEAR then add({x = 0, y = 0, z = 0}, 0, 0, pr.visual_size, pr.textures) end
	for _, ch in ipairs(o:get_children()) do
		local e = ch:get_luaentity()
		if e and e.name == PART then
			local cp = ch:get_properties()
			if cp.is_visible ~= false then
				local _, _, ap, ar = ch:get_attach()
				add(vector.multiply(ap, 0.1), ar.x, ar.y, cp.visual_size, cp.textures)
			end
		end
	end
end
local PLAYER_TEX = {}
for i = 1, 6 do PLAYER_TEX[i] = "[fill:4x8:#3a5a9a^[fill:4x2:0,0:#c8a080^[fill:4x3:0,5:#30304a" end

-- 射線（從 eye、單位方向 dir）打到箱子：回傳距離、進入面的軸（1～3）與正負；只找比 tmax 近的
local function hit_box(bx, eye, dir, tmax)
	local dx, dy, dz = bx.c.x - eye.x, bx.c.y - eye.y, bx.c.z - eye.z
	local tmin, axis, sgn = 0, nil, 0
	for i = 1, 3 do
		local a, h = bx.ax[i], bx.h[i]
		local e = a.x * dx + a.y * dy + a.z * dz
		local fd = a.x * dir.x + a.y * dir.y + a.z * dir.z
		if math.abs(fd) > 1e-9 then
			local tn, tf, sg
			if fd > 0 then tn, tf, sg = (e - h) / fd, (e + h) / fd, -1 else tn, tf, sg = (e + h) / fd, (e - h) / fd, 1 end
			if tn > tmin then tmin, axis, sgn = tn, i, sg end
			if tf < tmax then tmax = tf end
			if tmin > tmax then return nil end
		elseif math.abs(e) > h then
			return nil
		end
	end
	if not axis then return nil end   -- 鏡子在箱子裡面
	return tmin, axis, sgn
end
-- 打到箱子那一點的顏色：面（貼圖順序 +Y −Y +X −X +Z −Z）與面上的 (u, v)
local FACE = {{4, 3}, {2, 1}, {6, 5}}
local function box_color(bx, eye, dir, t, axis, sgn)
	local q = {}
	for i = 1, 3 do
		local a = bx.ax[i]
		q[i] = a.x * (eye.x + dir.x * t - bx.c.x) + a.y * (eye.y + dir.y * t - bx.c.y) + a.z * (eye.z + dir.z * t - bx.c.z)
		q[i] = math.max(0, math.min(0.999, (q[i] / bx.h[i] + 1) / 2))
	end
	local u, v
	if axis == 1 then u, v = q[3], 1 - q[2]
	elseif axis == 2 then u, v = q[1], q[3]
	else u, v = q[1], 1 - q[2] end
	local t6 = bx.tex[FACE[axis][sgn > 0 and 2 or 1]] or bx.tex[1]
	return hex_rgb(tex_color(t6, u, v)), {x = bx.ax[axis].x * sgn, y = bx.ax[axis].y * sgn, z = bx.ax[axis].z * sgn}
end

-- 畫一個畫面（view 見 views_of）。看往後方，和照後鏡一樣：畫面左邊 = 車身左側（−X），上 = 上。
-- view.target：對準這一點（車身座標，自動算 dir、down）；view.flip：一般攝影機（往前看時左右不鏡像）；
-- view.mark：在這一點（車身座標）畫紅色十字；view.holes：這個距離內的鑽孔、裝藥畫成明顯的色點（太小、射線常打不到）
-- 有 target 的鏡頭可以在車外：鏡頭和 target 之間有岩石擋住就往 target 拉近
local HOLE_NODES = {"rockmech:drill_hole", "rockmech:charged_hole", "rockmech:anfo_hole", "rockmech:anfo_primed"}
local function render_view(self, view)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local psi = view.swing and self.swing or 0
	local cy, sy = math.cos(yaw), math.sin(yaw)
	local function world(l)   -- 上部結構（挖土機）／車身座標 → 世界方向
		l = h2v(l, psi)
		return {x = l.x * cy - l.z * sy, y = l.y, z = l.x * sy + l.z * cy}
	end
	local eye = vector.add(p, world(view.o))
	local vdir, vdown = view.dir, view.down
	if view.target then
		local dx, dy, dz = view.target.x - view.o.x, view.target.y - view.o.y, view.target.z - view.o.z
		vdir = V.atan2(dx, -dz)
		vdown = -V.atan2(dy, math.sqrt(dx * dx + dz * dz))
		local tp = vector.add(p, world(vector.add(view.target, {x = 0, y = 0.6, z = 0})))
		for hit in core.raycast(tp, eye, false, false) do
			if hit.type == "node" and not V.passable(core.get_node(hit.under).name) then
				eye = vector.add(hit.intersection_point, vector.multiply(vector.direction(eye, tp), 0.3))
				break
			end
		end
	end
	local hsign = view.flip and -1 or 1
	-- 附近的車輛（含自己）與沒在車上的玩家：每台車（或玩家）一組箱子與外接球（射線先比外接球，碰不到整組跳過）
	local groups = {}
	for _, o in ipairs(core.get_objects_inside_radius(eye, MIRROR_RANGE + 8)) do
		local e = o:get_luaentity()
		local boxes = {}
		if e and e.vkind and TYPES[e.vkind] then
			vehicle_boxes(o, boxes)
		elseif o:is_player() and not o:get_attach() then
			boxes[1] = {c = vector.add(o:get_pos(), {x = 0, y = 0.9, z = 0}), ax = AXES, h = {0.3, 0.9, 0.3}, tex = PLAYER_TEX}
		end
		if #boxes > 0 then
			local c = {x = 0, y = 0, z = 0}
			for _, bx in ipairs(boxes) do c = vector.add(c, bx.c) end
			c = vector.divide(c, #boxes)
			local r = 0
			for _, bx in ipairs(boxes) do
				r = math.max(r, vector.distance(c, bx.c) + math.sqrt(bx.h[1] ^ 2 + bx.h[2] ^ 2 + bx.h[3] ^ 2))
			end
			groups[#groups + 1] = {c = c, r = r, boxes = boxes}
		end
	end
	local W, H = view.w, view.h
	local out = {("[fill:%dx%d:#%02x%02x%02x"):format(W, H, SKY[1], SKY[2], SKY[3])}
	for v = 0, H - 1 do
		local b = -vdown + (0.5 - (v + 0.5) / H) * view.vfov
		local cb, sb = math.cos(b), math.sin(b)
		local run, run_x = nil, 0
		local function flush(u)
			if run then out[#out + 1] = ("^[fill:%dx1:%d,%d:%s"):format(u - run_x, run_x, v, run) end
		end
		for u = 0, W - 1 do
			local col
			local a = vdir + hsign * ((u + 0.5) / W - 0.5) * view.hfov
			local dw = world({x = math.sin(a) * cb, y = sb, z = -math.cos(a) * cb})
			local hit = core.raycast(eye, vector.add(eye, vector.multiply(dw, MIRROR_RANGE)), false, false):next()
			local c, n, dist
			local grid = 1   -- 方塊棋盤格明暗（看得出一格一格、遠近與地面起伏）
			if hit and hit.type == "node" then
				c, n = rgb_of(core.get_node(hit.under).name), hit.intersection_normal
				dist = vector.distance(eye, hit.intersection_point)
				if (hit.under.x + hit.under.y + hit.under.z) % 2 == 1 then grid = 0.88 end
			end
			local best, bt, bax, bsg = nil, dist or MIRROR_RANGE, nil, nil
			for _, g in ipairs(groups) do
				local ox, oy, oz = g.c.x - eye.x, g.c.y - eye.y, g.c.z - eye.z
				local along = ox * dw.x + oy * dw.y + oz * dw.z
				if along + g.r > 0 and along - g.r < bt and ox * ox + oy * oy + oz * oz - along * along < g.r * g.r then
					for _, bx in ipairs(g.boxes) do
						local t, axis, sg = hit_box(bx, eye, dw, bt)
						if t then best, bt, bax, bsg = bx, t, axis, sg end
					end
				end
			end
			if best then
				dist, grid = bt, 1
				c, n = box_color(best, eye, dw, bt, bax, bsg)
			end
			if c then
				local shade = (n.y > 0.5 and 1 or n.y < -0.5 and 0.55 or math.abs(n.x) > math.abs(n.z) and 0.82 or 0.7) * grid
				local t = 0.6 * dist / MIRROR_RANGE
				col = {c[1] * shade * (1 - t) + SKY[1] * t, c[2] * shade * (1 - t) + SKY[2] * t,
					c[3] * shade * (1 - t) + SKY[3] * t}
			end
			local hx = col and ("#%02x%02x%02x"):format(math.floor(col[1]), math.floor(col[2]), math.floor(col[3]))
			if hx ~= run then flush(u); run, run_x = hx, u end
		end
		flush(W)
	end
	-- 世界座標的點 → 畫面上的像素（看不到回傳 nil）
	local function project(q)
		local d = vector.subtract(q, eye)
		local lx, lz = d.x * cy + d.z * sy, -d.x * sy + d.z * cy
		local a = (V.atan2(lx, -lz) - vdir + math.pi) % (2 * math.pi) - math.pi
		local b = V.atan2(d.y, math.sqrt(lx * lx + lz * lz))
		local u = math.floor(((hsign * a) / view.hfov + 0.5) * W)
		local v = math.floor((0.5 - (b + vdown) / view.vfov) * H)
		if u >= 0 and u < W and v >= 0 and v < H then return u, v end
	end
	if view.holes and not view.swing then
		local c0 = vector.add(p, world(view.mark or view.target))
		for _, hp in ipairs(core.find_nodes_in_area(vector.subtract(c0, view.holes), vector.add(c0, view.holes), HOLE_NODES)) do
			local u, v = project(hp)
			-- 被擋住的不畫：從鏡頭打到孔口那格，中間先碰到別的方塊就是看不到
			local hit = u and core.raycast(eye, hp, false, false):next()
			if u and (not hit or vector.equals(hit.under, hp)) then
				local c = rgb_of(core.get_node(hp).name)
				out[#out + 1] = ("^[fill:2x2:%d,%d:#%02x%02x%02x"):format(math.min(u, W - 2), math.min(v, H - 2), c[1], c[2], c[3])
			end
		end
	end
	if view.mark then
		local u, v = project(vector.add(p, world(view.mark)))
		if u then
			out[#out + 1] = ("^[fill:5x1:%d,%d:#ff3030^[fill:1x5:%d,%d:#ff3030"):format(u - 2, v, u, v - 2)
		end
	end
	return table.concat(out)
end

rockmech.vehicle_render_view, rockmech.vehicle_views = render_view, views_of   -- 測試用

-- 輪流畫：每 MIRROR_DT / 畫面數 秒畫一個畫面（每個畫面仍是每 MIRROR_DT 秒更新），負擔分散到不同 step
function V.update_mirrors(self, d, dtime)
	if not self.hud_mirror then return end
	local views = views_of(self.vkind)
	self.mirror_t = (self.mirror_t or MIRROR_DT) + dtime
	if self.mirror_t < MIRROR_DT / #views then return end
	self.mirror_t = 0
	local i = (self.mirror_i or 0) % #views + 1
	self.mirror_i = i
	local tex = render_view(self, views[i])
	if tex ~= self.mirror_last[i] then
		d:hud_change(self.hud_mirror[i], "text", tex)
		self.mirror_last[i] = tex
	end
end

-- 移除駕駛的 HUD（說明文字、駕駛艙框、後照鏡與倒車攝影機畫面）
function V.hud_clear(self, player)
	if player then
		if self.hud then player:hud_remove(self.hud) end
		if self.hud_cockpit then player:hud_remove(self.hud_cockpit) end
		for _, id in ipairs(self.hud_mirror or {}) do player:hud_remove(id) end
	end
	self.hud, self.hud_cockpit, self.hud_mirror = nil, nil, nil
end

function V.update_hud(self)
	local d = self.driver and core.get_player_by_name(self.driver)
	if not d then return end
	-- 追蹤相機（第三人稱）時不顯示駕駛艙框、後照鏡與倒車攝影機畫面
	if self.chase then
		if self.hud_cockpit then d:hud_remove(self.hud_cockpit); self.hud_cockpit = nil end
		for _, id in ipairs(self.hud_mirror or {}) do d:hud_remove(id) end
		self.hud_mirror = nil
	end
	if not self.hud_cockpit and not self.chase then
		self.hud_cockpit = d:hud_add({type = "image", position = {x = 0.5, y = 0.5}, alignment = {x = 0, y = 0},
			scale = {x = -100, y = -100}, text = cockpit_tex(self.vkind), z_index = -10})
	end
	if not self.hud_mirror and not self.chase then
		self.hud_mirror, self.mirror_last, self.mirror_t = {}, {}, nil
		for i, view in ipairs(views_of(self.vkind)) do
			local r = view.hud
			self.hud_mirror[i] = d:hud_add({type = "image", alignment = {x = 0, y = 0},
				position = {x = (r.x + r.w / 2) / 160, y = (r.y + r.h / 2) / 90},
				scale = {x = -r.w / 160 * 100, y = -r.h / 90 * 100}, text = "[fill:1x1:#7f9fb8", z_index = -9})
		end
	end
	if self.hud then d:hud_change(self.hud, "text", hud_text(self))
	else
		self.hud = d:hud_add({type = "text", position = {x = 0.5, y = 0.85}, alignment = {x = 0, y = 0},
			text = hud_text(self), number = 0xFFE080, z_index = 100})
	end
	V.refresh(self)
end
