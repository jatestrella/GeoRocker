-- rockmech/vehicles.lua
-- 載具共用部分：實體註冊（上下車、駕駛、追蹤相機、隨地形傾斜、收回成物品）、零件、碎石的取放。
-- 各種車在自己的檔案：vehicle_excavator.lua（挖土機）、vehicle_truck.lua（卡車；有車斗的車共用部分）、
-- vehicle_haul.lua（礦卡）、vehicle_dozer.lua（推土機）、vehicle_jumbo.lua（鑽堡、裝藥台車）、vehicle_drillrig.lua（露天鑽機）；
-- 駕駛艙 HUD、後照鏡與倒車攝影機畫面在 vehicle_views.lua。
-- 只處理碎石：完整岩石要先爆破或用魔杖弄碎（爆破 → 裝載 → 運輸）。
-- 操作：右鍵上車；駕駛中 Shift 下車，W/S 前進後退，A/D 轉向；Z 切換追蹤相機（從車子後上方看作動）。
-- 駕駛的相機在車頂（挖土機：駕駛艙頂）前緣。不在車上時左鍵：收回成物品（車上的碎石換成碎石物品，8 級 = 1 個）
-- 碎石的增減用 set_node／remove_node，照常觸發開挖記錄、支撐判定；動過的碎石再依安息角流動。

local NLEV = rockmech.RUBBLE_LEVELS
local collapse = rockmech.collapse

local V = {NLEV = NLEV}
rockmech.vehicles = V

-- 經營模式：車子記下放置者的帳戶（分組時是整組，見 crusher.lua 的 rockmech.account_of），
-- 別組的人不能上車、收車、用對講機指揮；老師（server 權限）都可以。沒有記錄的舊車誰都能開
function V.may_use(self, name)
	if not self.owner or self.owner == "" or not rockmech.account_of then return true end
	if rockmech.account_of(name) == self.owner then return true end
	if core.check_player_privs(name, {server = true}) then return true end
	core.chat_send_player(name, ("這是%s的車，別組不能開"):format(rockmech.account_label(self.owner)))
	return false
end
-- 血條：受損的車頭上浮一條（永遠面向看的人），滿血時拿掉。50% 以上綠、30% 以上黃、以下紅，報廢是空的紅框
local HPBAR = "rockmech:hpbar"
core.register_entity(HPBAR, {
	initial_properties = {visual = "sprite", physical = false, pointable = false, static_save = false,
		visual_size = {x = 1.6, y = 0.22}, textures = {"[fill:32x4:#202020"}, glow = 8, use_texture_alpha = true},
	on_detach = function(self) self.object:remove() end,
})
local function update_bar(self)
	local hp = self.hp or 100
	local bar = self.hpbar
	if hp >= 100 then
		if bar and bar:get_pos() then bar:remove() end
		self.hpbar = nil
		return
	end
	if not (bar and bar:get_pos()) then
		bar = core.add_entity(self.object:get_pos(), HPBAR)
		if not bar then return end
		local def = V.TYPES[self.vkind]
		bar:set_attach(self.object, "", {x = 0, y = ((def.top or def.half) + 1.0) * 10, z = 0}, {x = 0, y = 0, z = 0})
		self.hpbar = bar
	end
	local w = math.max(0, math.min(30, math.floor(30 * hp / 100 + 0.5)))
	local c = hp >= 50 and "#40d040" or hp >= 30 and "#e0c020" or "#e03020"
	local tex = "[fill:32x4:#c02020^[fill:30x2:1,1:#202020"
	if w > 0 then tex = tex .. ("^[fill:%dx2:1,1:%s"):format(w, c) end
	if hp > 0 then tex = tex:gsub("#c02020", "#101010", 1) end
	bar:set_properties({textures = {tex}})
end

-- 指著車看到的說明：哪一組的車、耐久度（血條也跟著更新）
function V.update_infotext(self)
	update_bar(self)
	local t = {}
	if self.owner and self.owner ~= "" and rockmech.account_label then t[#t + 1] = rockmech.account_label(self.owner) .. "的車" end
	local hp = self.hp or 100
	if hp <= 0 then t[#t + 1] = "【報廢】找機械技工修理"
	elseif hp < 100 then t[#t + 1] = ("耐久 %d%%"):format(math.floor(hp + 0.5)) end
	self.object:set_properties({infotext = table.concat(t, "\n")})
end
-- 車輛登記：mod storage 的 vreg:<車輛編號> = "車種|主人"，車子沒載入也數得到（操作員人數上限 = 全組的怪手數，operator.lua）。
-- 車子載入、換主人時寫，收起來時刪
local VREG = "vreg:"
function V.registry_save(self)
	if not self.uid then return end
	local v = (self.vkind or "") .. "|" .. (self.owner or "")
	if self.vreg_v == v then return end
	self.vreg_v = v
	rockmech.collapse.storage:set_string(VREG .. self.uid, v)
end
function V.registry_drop(uid) if uid then rockmech.collapse.storage:set_string(VREG .. uid, "") end end
-- 帳戶 acc 有幾台車種名稱含 pattern 的車（純文字比對）
function V.count_owned(acc, pattern)
	local n, seen = 0, {}
	for _, k in ipairs(rockmech.collapse.storage:get_keys()) do
		local uid = k:match("^" .. VREG .. "(.+)$")
		if uid then
			local kind, owner = rockmech.collapse.storage:get_string(k):match("^(.-)|(.*)$")
			if kind and owner == acc and kind:find(pattern, 1, true) then n = n + 1; seen[uid] = true end
		end
	end
	for uid, e in pairs(V.by_uid) do
		if not seen[uid] and e.owner == acc and e.vkind and e.vkind:find(pattern, 1, true) then n = n + 1 end
	end
	return n
end
function V.set_owner(self, acc)
	self.owner = acc
	V.update_infotext(self)
	V.registry_save(self)
end

-- 耐久度（impact.lua 的落石、之後的機械技工修理）：0–100%，存在 mod storage 的 vhp:<車輛編號>
-- = {hp, owner, kind, pos}，車子沒載入時機械技工也查得到。100 kJ 的撞擊扣到 0（報廢）：
-- 低於 WORN 冒黑煙、跑得慢；0 不能開、不能作業，冒濃煙
local VHP = "vhp:"
local HP_PER_KJ = 1          -- 每 kJ 扣幾 %
V.WORN = 30
local function vstorage() return rockmech.collapse.storage end
function V.save_hp(self)
	local st = vstorage()
	if (self.hp or 100) >= 100 then st:set_string(VHP .. self.uid, "")
	else
		local p = self.object:get_pos()
		st:set_string(VHP .. self.uid, core.serialize({hp = self.hp, owner = self.owner, kind = self.vkind,
			pos = p and vector.round(p)}))
	end
end
function V.load_hp(self)
	local s = vstorage():get_string(VHP .. self.uid)
	local d = s ~= "" and core.deserialize(s)
	self.hp = d and d.hp or 100
	V.update_infotext(self)
end
function V.damage(self, kj)
	if not self or not self.uid then return end
	local before = self.hp or 100
	if before <= 0 then return end
	self.hp = math.max(0, before - kj * HP_PER_KJ)
	V.save_hp(self)
	V.update_infotext(self)
	if V.update_hud then V.update_hud(self) end
	local def = V.TYPES[self.vkind]
	local who = self.driver
	local msg = self.hp <= 0 and ("%s被落石砸到報廢了（%.0f kJ），找機械技工修理"):format(def.desc, kj)
		or ("%s被落石砸到（%.0f kJ），耐久剩 %d%%"):format(def.desc, kj, math.floor(self.hp + 0.5))
	if self.owner and rockmech.account_members then
		for _, m in ipairs(rockmech.account_members(self.owner)) do core.chat_send_player(m, "[車輛] " .. msg) end
	elseif who then core.chat_send_player(who, "[車輛] " .. msg) end
end
-- 受損的車冒煙（沒有人開也冒）
local function damage_smoke(self, dtime)
	local hp = self.hp or 100
	if hp >= V.WORN then return end
	self.dsmoke_t = (self.dsmoke_t or 0) + dtime
	if self.dsmoke_t < 0.4 then return end
	self.dsmoke_t = 0
	local p = self.object:get_pos()
	local near = false
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) < 64 then near = true; break end
	end
	if not near then return end
	local def = V.TYPES[self.vkind]
	local o = {x = p.x, y = p.y + (def.top or def.half) + 0.3, z = p.z}
	core.add_particlespawner({amount = hp <= 0 and 8 or 3, time = 0.4,
		minpos = vector.subtract(o, 0.6), maxpos = vector.add(o, 0.6),
		minvel = {x = -0.3, y = 1.0, z = -0.3}, maxvel = {x = 0.3, y = 2.2, z = 0.3},
		minexptime = 1.5, maxexptime = 3, minsize = 3, maxsize = hp <= 0 and 9 or 5,
		texture = "[fill:4x4:#1a1a1a^[opacity:" .. (hp <= 0 and 200 or 140)})
end
V.damage_smoke = damage_smoke

-- 各種車的設定（各車的檔案用 V.register 加入）。
-- desc、color；cap：載量（級）；speed：m/s；half：碰撞箱半邊長；lat：車頭外一排的橫向位置（相對中心）；
-- eye_up／eye_fwd／eye_side：相機在車身中心上方、沿視線往前、往右（負 = 左）的距離（m）；mirror：右後照鏡位置（車身座標，左鏡 x 取負）；
-- rearcam：倒車攝影機位置；tilt：外觀隨地形傾斜時量地面的位置（前、後端的 z，左右兩側的 z 與 ±x）；
-- rear：車身伸出碰撞箱後方到 z = −rear（選取框跟著加長；tail_lat／tail_dy 是倒車、轉彎檢查點，見 V.tail_guard）；top：碰撞箱上緣（預設 half，車身不是立方體時用）；
-- overhangs：伸出碰撞箱那段擋人的範圍（見 V.overhang_push）；overhangs_now(self)：會動的擋人範圍（挖土機鏟斗）；max_grade：最大爬坡角（rad；行進方向整台車長的平均坡度）；
-- top_speed／accel：直線前進時從 speed 加速到 top_speed（m/s、m/s²）；tire（輪胎直徑，爬台階的上限，見 V.max_step）；stepheight（沒有 tire 的車，預設 1.1）；look_limit：第一人稱視線離車頭最多幾度（rad，省略 → 不限）；inv_image、item_desc：物品。
-- 各車的行為（都可省略）：parts（零件清單）、on_spawn(self)（零件生成後）、on_load(self, data)／on_save(self, data)、
-- refresh(self)（外觀與名牌）、hud(self)（HUD 加的文字）、can_turn(self, pos, yaw, yaw2)、
-- move(self, ctx)（設定 ctx.speed）、step(self, ctx)（設定速度之後）、action(self, ctx)（作業鍵）。
-- ctx：obj、pos、yaw、dir（車頭方向）、s（對齊格線的方向）、fwd、dtime、d（駕駛）、ctrl、speed
local TYPES = {}
V.TYPES = TYPES
local TURN_RATE = 1.6        -- rad/s

-- 駕駛視線：第一人稱相機不受 set_attach 位移影響（遊戲內確認：改位移視角不變），改用 set_eye_offset。
-- 玩家掛在車身中心（腳在中心），相機往上 eye_up、沿視線方向往前 eye_fwd（m）：坐在車頂前緣，
-- 往前看得到自己的車頂前緣與車頭正前方的地面（車身方塊從裡面看不透明，相機不能放進車身）
local EYE_HEIGHT = 1.625
V.EYE_HEIGHT = EYE_HEIGHT
local function eye_offset(def)
	return {x = (def.eye_side or 0) * 10, y = (def.eye_up - EYE_HEIGHT) * 10, z = def.eye_fwd * 10}
end

-- 貼圖（[fill 組合）。cube 的六面：上、下、+X、−X、+Z（車頭：yaw 0 朝 +Z）、−Z
function V.box_tex(c, front)
	local t = ("[fill:16x16:%s"):format(c)
	return {t, t, t, t, front or t, t}
end
-- 物品圖示：32×32 透明底的側面剪影（車頭朝右）。r = {{x, y, w, h, 顏色}, …}，後面的蓋前面的。
-- 下面的 icon_* 把輪子、履帶、斜的手臂加進 r
function V.icon(r)
	local t = {"[fill:32x32:#00000000"}
	for _, q in ipairs(r) do t[#t + 1] = ("^[fill:%dx%d:%d,%d:%s"):format(q[3], q[4], q[1], q[2], q[5]) end
	return table.concat(t)
end
function V.icon_wheel(r, cx, cy, rad)   -- 輪子（切角的方塊近似圓）＋輪轂
	r[#r + 1] = {cx - rad + 1, cy - rad, 2 * rad - 2, 2 * rad, "#1c1c1c"}
	r[#r + 1] = {cx - rad, cy - rad + 1, 2 * rad, 2 * rad - 2, "#1c1c1c"}
	r[#r + 1] = {cx - 1, cy - 1, 2, 2, "#9a9a9a"}
end
function V.icon_track(r, x, y, w, h)   -- 履帶（圓角長條＋負重輪）
	r[#r + 1] = {x + 1, y, w - 2, h, "#2a2a2a"}
	r[#r + 1] = {x, y + 1, w, h - 2, "#2a2a2a"}
	for k = x + 2, x + w - 4, 4 do r[#r + 1] = {k, y + math.floor(h / 2) - 1, 2, 2, "#5a5a5a"} end
end
function V.icon_line(r, x0, y0, x1, y1, w, c)   -- 斜的手臂：從 (x0, y0) 到 (x1, y1)、粗 w
	local n = math.max(math.abs(x1 - x0), math.abs(y1 - y0), 1)
	for i = 0, n do
		r[#r + 1] = {math.floor(x0 + (x1 - x0) * i / n + 0.5), math.floor(y0 + (y1 - y0) * i / n + 0.5), w, w, c}
	end
end
V.TRACK = "[fill:16x16:#2a2a2a^[fill:16x2:0,0:#454545^[fill:16x2:0,14:#454545^[fill:2x12:3,2:#383838^[fill:2x12:9,2:#383838"

-- 零件：掛在車身上的 cube 實體。外觀都由零件組成，車身本體全透明
local CLEAR = "[fill:1x1:#00000000"
local PART = "rockmech:vehicle_part"
V.CLEAR, V.PART = CLEAR, PART
local BOARD_REACH = 4        -- 上車：人離車身邊緣（車寬、車尾較長的一邊）多遠以內 (m)

-- 無人作業的車（開著的無人卡車、有操作員的怪手）走到哪裡就把周圍 ±KEEP_R m、上下 ±KEEP_DY m 的區塊暫時強制載入
-- （不存檔、邊走邊換）：引擎只跑玩家附近的區塊，人在礦場時開往破碎站的卡車、人在破碎站時礦場的怪手都會停住。
-- 有人駕駛、關掉無人作業、車子卸載或收起來就放掉。重開遊戲後要玩家走近一次才會再動起來
local KEEP_R, KEEP_DY, KEEP_MOVE = 10, 4, 2
local function keep_area(self, pos, release)
	local on = not release and not self.driver and ((self.ahs and self.ahs.on) or (self.op and self.op.on))
	if on and self.kept_at and math.abs(pos.x - self.kept_at.x) < KEEP_MOVE and math.abs(pos.y - self.kept_at.y) < KEEP_MOVE
			and math.abs(pos.z - self.kept_at.z) < KEEP_MOVE then return end
	if not on and not self.kept then return end
	local want = {}
	if on then
		local f = math.floor
		for bx = f((pos.x - KEEP_R) / 16), f((pos.x + KEEP_R) / 16) do
			for by = f((pos.y - KEEP_DY) / 16), f((pos.y + KEEP_DY) / 16) do
				for bz = f((pos.z - KEEP_R) / 16), f((pos.z + KEEP_R) / 16) do
					local b = {x = bx * 16, y = by * 16, z = bz * 16}
					want[core.hash_node_position(b)] = b
				end
			end
		end
	end
	local had = self.kept or {}
	for h, b in pairs(want) do if not had[h] then core.forceload_block(b, true, -1) end end
	for h, b in pairs(had) do if not want[h] then core.forceload_free_block(b, true) end end
	self.kept = on and want or nil
	self.kept_at = on and vector.copy(pos) or nil
end
core.register_entity(PART, {
	initial_properties = {
		physical = false, collide_with_objects = false, pointable = false, static_save = false,
		visual = "cube", textures = V.box_tex("#808080"), backface_culling = true,
	},
	-- 沒有掛在載具上的零件自己消失：載具卸載、重新載入或被收起來時，引擎可能先把零件拆下來
	-- （載具就找不到它們），留在原地像壞掉、重疊的車。每 0.5 s 檢查一次（生成時同一步就掛上去了）
	on_step = function(self, dtime)
		self.t_check = (self.t_check or 0) + dtime
		if self.t_check < 0.5 then return end
		self.t_check = 0
		if not self.object:get_attach() then self.object:remove() end
	end,
})
local function remove_parts(self)
	for _, c in ipairs(self.object:get_children()) do
		local e = c:get_luaentity()
		if e and e.name == PART then c:remove() end
	end
	-- 已經被拆下來（不在 children 裡）的也一起清掉
	for _, o in ipairs(self.part_list or {}) do
		if o:get_pos() then o:remove() end
	end
	self.part_list = nil
end
-- parts：{id（可選，存到 self.parts[id]）, pos（m）, size, tex, rot（可選）}
local function spawn_parts(self, parts)
	remove_parts(self)
	self.parts, self.part_list = {}, {}
	for _, pt in ipairs(parts) do
		local o = core.add_entity(self.object:get_pos(), PART)
		if o then
			o:set_properties({visual_size = pt.size, textures = pt.tex})
			o:set_attach(self.object, "", {x = pt.pos.x * 10, y = pt.pos.y * 10, z = pt.pos.z * 10}, pt.rot or {x = 0, y = 0, z = 0})
			if pt.id then self.parts[pt.id] = o end
			self.part_list[#self.part_list + 1] = o
		end
	end
end

-- 伸出碰撞箱那段（車斗、鏟刀、車尾、鏟斗）擋人：玩家的碰撞只認碰撞箱（不轉、也不認掛在車上的東西；
-- 而且只看中心在玩家附近約 3.4 m 內的物件，礦卡這種大車的邊緣離中心太遠也擋不住），
-- 所以由伺服器每一步檢查，站進那段的玩家往最近的開放側推出去（不往車身那側推）。
-- regions：車身座標的長方體 {x0, x1, z0, z1, y0, y1, body = "z0"／"z1"（貼著車身的那側，可省略）}
local PLAYER_R, PLAYER_H = 0.3, 1.7
local PUSH_CLEAR = 0.15     -- 推出去時離邊界再多留這麼多 (m)：剛好推到邊界上，浮點誤差會讓下一步又算在裡面，
                            -- 每一步都重設位置，人就浮在半空、走不動（看起來卡在車上）
-- 玩家的身體（半徑 PLAYER_R、高 PLAYER_H，腳底 q）蓋到的格子都是空的
local function body_free(q)
	for x = math.floor(q.x - PLAYER_R + 0.5), math.floor(q.x + PLAYER_R + 0.5) do
		for z = math.floor(q.z - PLAYER_R + 0.5), math.floor(q.z + PLAYER_R + 0.5) do
			for y = math.floor(q.y + 0.5 + 0.01), math.floor(q.y + PLAYER_H + 0.5) do
				if not V.passable(core.get_node({x = x, y = y, z = z}).name) then return false end
			end
		end
	end
	return true
end
V.body_free = body_free

-- 車子快照：停著不動的車，引擎只在正常關機或區塊卸載時才把資料寫進地圖；伺服器被強制結束（關掉視窗）
-- 就回到上次存的樣子（位置、載量、模組…）。每 SNAP_EVERY 秒把載入中的車整份資料（get_staticdata）連同位置、
-- 時間（os.time）寫進 mod storage 的 vsnap:<車輛編號>；讀檔時比較地圖裡的資料（get_staticdata 也記時間）跟快照，
-- 用比較新的那份。收車時刪掉
local SNAP_EVERY = 60
local SNAP = "vsnap:"
function V.snapshot_of(uid)
	local s = rockmech.collapse.storage:get_string(SNAP .. uid)
	return s ~= "" and core.deserialize(s) or nil
end
function V.snapshot_clear(uid)
	if uid then rockmech.collapse.storage:set_string(SNAP .. uid, "") end
end
function V.snapshot_all()
	local st, n = rockmech.collapse.storage, 0
	for uid, e in pairs(V.by_uid) do
		local pos = e.object and e.object:get_pos()
		if pos and e.get_staticdata then
			st:set_string(SNAP .. uid, core.serialize({wall = os.time(), pos = pos, data = e:get_staticdata()}))
			n = n + 1
		end
	end
	return n
end
local snap_t = 0
core.register_globalstep(function(dtime)
	snap_t = snap_t + dtime
	if snap_t < SNAP_EVERY then return end
	snap_t = 0
	V.snapshot_all()
end)
-- 玩家腳底 p（世界座標）在車身 pos、朝向 yaw 時要推到哪裡（世界座標）；不在任何一段裡回傳 nil
function V.overhang_push(regions, pos, yaw, p)
	local c, sn = math.cos(yaw), math.sin(yaw)
	local dx, dz = p.x - pos.x, p.z - pos.z
	local lx, lz, ly = dx * c + dz * sn, -dx * sn + dz * c, p.y - pos.y
	for _, r in ipairs(regions) do
		local m = PLAYER_R
		if lx > r.x0 - m and lx < r.x1 + m and lz > r.z0 - m and lz < r.z1 + m and ly + PLAYER_H > r.y0 and ly < r.y1 then
			-- 候選位置：左、右、不貼車身的前或後、車頂上，由近到遠；選第一個站得下人的（腳和頭那兩格都是空的）。
			-- 不然車停在山壁、受料倉邊時，人會被推進岩石裡，看起來就是卡在車裡出不來
			local cands = {}
			m = PLAYER_R + PUSH_CLEAR
			local function add(d, x, z, top)
				local q = top and {x = p.x, y = pos.y + r.y1, z = p.z}
					or {x = p.x + x * c - z * sn, y = p.y, z = p.z + x * sn + z * c}
				cands[#cands + 1] = {d = math.abs(d), q = q, top = top}
			end
			add(r.x0 - m - lx, r.x0 - m - lx, 0)
			add(r.x1 + m - lx, r.x1 + m - lx, 0)
			if r.body ~= "z0" then add(r.z0 - m - lz, 0, r.z0 - m - lz) end
			if r.body ~= "z1" then add(r.z1 + m - lz, 0, r.z1 + m - lz) end
			add(r.y1 - ly - 0.4, 0, 0, true)       -- 車頂：剛好在上緣附近時最近
			table.sort(cands, function(a, b) return a.d < b.d end)
			for _, cd in ipairs(cands) do
				if not cd.top and body_free(cd.q) then return cd.q end
			end
			-- 近的都被擋住：往左右、不貼車身的那頭再外推，最多 3 m（同一高度或高一格）
			for extra = 1, 3 do
				for _, cd in ipairs(cands) do
					if not cd.top then
						local dx, dz = cd.q.x - p.x, cd.q.z - p.z
						local len = math.sqrt(dx * dx + dz * dz)
						if len > 1e-3 then
							for _, dy in ipairs({0, 1}) do
								local q = {x = cd.q.x + dx / len * extra, y = cd.q.y + dy, z = cd.q.z + dz / len * extra}
								if body_free(q) then return q end
							end
						end
					end
				end
			end
			return {x = p.x, y = pos.y + r.y1 + 0.05, z = p.z}      -- 四周都被擋住：站到車頂上
		end
	end
end
local function push_players(self, pos, yaw, def, regions)
	local reach = (def.rear or def.half) + 8
	for _, pl in ipairs(core.get_connected_players()) do
		if not pl:get_attach() then
			local p = pl:get_pos()
			if math.abs(p.x - pos.x) < reach and math.abs(p.z - pos.z) < reach then
				local q = V.overhang_push(regions, pos, yaw, p)
				if q then pl:set_pos(q) end
			end
		end
	end
end

-- (x, z) 這一欄、y_from 往下 depth 格內最上面的實心面高度（不滿格碎石照級數），找不到回傳 nil
local function ground_top(x, y_from, z, depth)
	local xi, zi = math.floor(x + 0.5), math.floor(z + 0.5)
	for y = math.floor(y_from + 0.5), math.floor(y_from + 0.5) - depth, -1 do
		local n = core.get_node({x = xi, y = y, z = zi}).name
		local nd = core.registered_nodes[n]
		if n ~= "air" and (not nd or nd.walkable ~= false) then
			local k = rockmech.rubble_level[n] or rockmech.road_level[n]
			return k and (y - 0.5 + k / NLEV) or (y + 0.5)
		end
	end
end
V.ground_top = ground_top

-- 隨地形傾斜：量前後軸（履帶前後端）、左右輪（履帶）下方的地面（def.tilt），算俯仰（前高為正）
-- 與側傾（右側低為正，set_rotation 是右手 Z-X-Y：X 正 = 抬頭、Z 正 = 向右傾）。只有外觀傾斜，碰撞箱維持水平
-- 爬坡：行進方向上（f = 1 前進、−1 倒車）從後端接地點到前端前方 1 m 的平均坡度（rad，上坡為正）。
-- 沿車身每 0.5 m 量地面高度，取任兩點斜率的中位數（Theil-Sen）。只比兩點差一格就差很多；
-- 最小平方法會把一個台階當成斜坡，車頭爬上去、車尾還沒上去時被「坡太陡」卡住。地面在車底往上 1.6 m 以內找。
-- 前進時車身底下或車尾後面有一格以上的斷崖就只量斷崖以前的：車尾懸在坑上（受料倉口），不是在爬那個坑。
-- 只看斷崖，不能用「比車底低多少」過濾：車尾較平的地面拿掉，中位數反而變陡（車轍坡實測 12.7° 變 20.6°）
local function travel_grade(p, yaw, def, f)
	local t = def.tilt
	local c, sn = math.cos(yaw), math.sin(yaw)
	local za, zb = t.rear, t.front + 1
	if f < 0 then za, zb = t.rear - 1, t.front end
	local from = p.y - def.half + 1.6
	local zs, hs = {}, {}
	for z = za, zb, 0.5 do
		local h = ground_top(p.x - z * sn, from, p.z + z * c, 10)
		if h then zs[#zs + 1], hs[#hs + 1] = z, h end
	end
	local first = 1
	if f > 0 then
		for i = 1, #zs - 1 do
			if zs[i + 1] <= def.half and hs[i + 1] - hs[i] >= 1 then first = i + 1 end
		end
	end
	if #zs - first < 2 then return 0 end
	local slopes = {}
	for i = first, #zs do for j = i + 1, #zs do
		slopes[#slopes + 1] = (hs[j] - hs[i]) / (zs[j] - zs[i])
	end end
	table.sort(slopes)
	return math.atan(f * slopes[math.ceil(#slopes / 2)])
end

local function ground_tilt(p, yaw, def)
	local TILT_AXLES = def.tilt
	local c, sn = math.cos(yaw), math.sin(yaw)
	local function at(lx, lz)
		return p.x + lx * c - lz * sn, p.z + lx * sn + lz * c
	end
	local from, depth = p.y + 0.5, 8   -- 1:1 坡上車尾量測點的地面可比車身中心低 5 m 以上
	-- 從 (lx0, lz0) 沿 (dx, dz) 走 len 公尺：一路接著地面走，碰到超過 1 m 的斷崖就停。
	-- 懸在坑洞上的那一段沒有接地，不能拿洞底算傾角
	local function reach(lx0, lz0, dx, dz, len)
		local h
		for t = 0, len, 0.5 do
			local x, z = at(lx0 + dx * t, lz0 + dz * t)
			local g = ground_top(x, from, z, depth)
			if not g or (h and g < h - 1) then break end
			h = g
		end
		return h
	end
	local hf, hr = reach(0, 0, 0, 1, TILT_AXLES.front), reach(0, 0, 0, -1, -TILT_AXLES.rear)
	local hl = reach(0, TILT_AXLES.side_z, -1, 0, TILT_AXLES.side_x)
	local hq = reach(0, TILT_AXLES.side_z, 1, 0, TILT_AXLES.side_x)
	local pitch, roll = 0, 0
	if hf and hr then pitch = math.atan((hf - hr) / (TILT_AXLES.front - TILT_AXLES.rear)) end
	if hl and hq then roll = math.atan((hl - hq) / (2 * TILT_AXLES.side_x)) end
	local lim = math.rad(25)
	return math.max(-lim, math.min(lim, pitch)), math.max(-lim, math.min(lim, roll))
end

function V.lerp(a, b, t) return {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t} end
local atan2 = math.atan2 or math.atan
V.atan2 = atan2
-- 繞垂直軸轉 ψ（rad）：+Z 轉 ψ 後指向 (sin ψ, cos ψ)，與掛載旋轉的 Y 角同一個方向（見 seg_attach）。
-- 挖土機上部結構迴轉：上部座標 → 車身座標；實體 yaw 對應 h2v(·, −yaw)
local function h2v(p, psi)
	local c, sn = math.cos(psi), math.sin(psi)
	return {x = p.x * c + p.z * sn, y = p.y, z = -p.x * sn + p.z * c}
end
V.h2v = h2v
function V.v2h(p, psi)
	local c, sn = math.cos(psi), math.sin(psi)
	return {x = p.x * c - p.z * sn, y = p.y, z = p.x * sn + p.z * c}
end
-- 角度內插（走最短的方向）
function V.lerp_angle(a, b, t)
	local d = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + d * t
end
-- 長方體零件（長軸是自身 +Y）擺在 a → c 之間。
-- 掛載旋轉：左手座標、外旋 X → Y → Z（度）。+Y 軸先繞 X 轉 θx、再繞 Y 轉 θy 後指向
-- (sin θx·sin θy, cos θx, sin θx·cos θy)：θx = acos(v.y)、θy = atan2(v.x, v.z)
function V.seg_attach(self, o, a, c)
	if not o then return end
	local v = {x = c.x - a.x, y = c.y - a.y, z = c.z - a.z}
	local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if len < 1e-6 then return end
	local tx = math.deg(math.acos(math.max(-1, math.min(1, v.y / len))))
	local ty = math.deg(atan2(v.x, v.z))
	o:set_attach(self.object, "", {x = (a.x + c.x) * 5, y = (a.y + c.y) * 5, z = (a.z + c.z) * 5}, {x = tx, y = ty, z = 0})
end

-- 世界座標 → 車身座標（車頭 +Z；含隨地形傾斜：實體旋轉依序是側傾 Z、俯仰 X、偏航 Y，這裡反過來解）。
-- 挖臂在這個座標裡解，車身傾斜時挖斗照樣落在目標上
function V.to_local(self, wp)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local dx, dy, dz = wp.x - p.x, wp.y - p.y, wp.z - p.z
	local c, sn = math.cos(yaw), math.sin(yaw)
	local x, y, z = dx * c + dz * sn, dy, -dx * sn + dz * c
	local cp, sp = math.cos(self.pitch or 0), math.sin(self.pitch or 0)
	y, z = y * cp - z * sp, y * sp + z * cp
	local cr, sr = math.cos(self.roll or 0), math.sin(self.roll or 0)
	return {x = x * cr - y * sr, y = x * sr + y * cr, z = z}
end
-- 車身座標 → 世界座標（to_local 的反向）
function V.to_world(self, lp)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local cr, sr = math.cos(self.roll or 0), math.sin(self.roll or 0)
	local x, y, z = lp.x * cr + lp.y * sr, -lp.x * sr + lp.y * cr, lp.z
	local cp, sp = math.cos(self.pitch or 0), math.sin(self.pitch or 0)
	y, z = y * cp + z * sp, -y * sp + z * cp
	local c, sn = math.cos(yaw), math.sin(yaw)
	return {x = p.x + x * c - z * sn, y = p.y + y, z = p.z + x * sn + z * c}
end

-- 追蹤相機：Z 鍵時把駕駛掛到一個看不見、跟著車子的點上（Luanti 內建第三人稱拉不遠）。
-- 位置：車尾後 3.5 m、車頂上方 4 m（眼睛）
local CHASE = "rockmech:chasecam"
core.register_entity(CHASE, {
	initial_properties = {
		physical = false, collide_with_objects = false, pointable = false, static_save = false,
		visual = "sprite", textures = {"[fill:1x1:#00000000"}, use_texture_alpha = true,
	},
	on_activate = function(self)
		core.after(1, function()
			if self.object:get_pos() and #self.object:get_children() == 0 then self.object:remove() end
		end)
	end,
})
local function chase_pos(self, def)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local back = (def.rear or def.half) + 3.5   -- 車尾後 3.5 m
	local up = def.half + 4.0                 -- 車頂上方 4 m（眼睛）
	return {x = p.x + math.sin(yaw) * back, y = p.y + up - EYE_HEIGHT, z = p.z - math.cos(yaw) * back}
end

function V.passable(name)
	local def = core.registered_nodes[name]
	return name == "air" or (def and def.walkable == false)
end
local passable = V.passable

-- 車頭方向（連續）與對齊格線的方向
local function dirs(yaw)
	local dx, dz = -math.sin(yaw), math.cos(yaw)
	local sx, sz
	if math.abs(dx) > math.abs(dz) then sx, sz = dx > 0 and 1 or -1, 0 else sx, sz = 0, dz > 0 and 1 or -1 end
	return {x = dx, z = dz}, {x = sx, z = sz}
end
V.dirs = dirs

-- 車頭（f = 1）或車尾（f = −1）外側、距車身中心 dist 的一排（地面層 + 上方 h−1 層）。
-- lat：橫向位置（預設 2 格寬 {−0.5, 0.5}）
function V.face_cells(pos, s, f, dist, y0, h, lat)
	local px, pz = -s.z, s.x
	local cx, cz = pos.x + f * s.x * dist, pos.z + f * s.z * dist
	local cells = {}
	for _, l in ipairs(lat or {-0.5, 0.5}) do
		local x = math.floor(cx + px * l + 0.5)
		local z = math.floor(cz + pz * l + 0.5)
		for dy = 0, h - 1 do cells[#cells + 1] = {x = x, y = y0 + dy, z = z} end
	end
	return cells
end

-- 地面層（車身最下面那層格子的高程）。half：碰撞箱半邊長（預設 1）
function V.ground_y(pos, half) return math.floor(pos.y - (half or 1) + 0.5) end

-- 從 cell 取走最多 want 級碎石。回傳 取走的級數, 碎石種類, 品位（param2）
function V.take_rubble(cell, want)
	local node = core.get_node(cell)
	local name = node.name
	local k = rockmech.rubble_level[name]
	if not k or want <= 0 then return 0 end
	local base = rockmech.rubble_base[name]
	local t = math.min(k, want)
	local rest = rockmech.rubble_with_level(base, k - t, node.param2)
	if rest then core.swap_node(cell, {name = rest, param2 = node.param2}) else core.remove_node(cell) end
	collapse.check_cell({x = cell.x, y = cell.y + 1, z = cell.z})   -- 上方的碎石往下掉
	return t, base, node.param2
end

-- 車上的碎石：self.load[種類] = 級數；礦石碎石另外記 self.loadq[種類] = Σ 級數 × 品位
function V.load_put(self, base, lv, g)
	self.load[base] = (self.load[base] or 0) + lv
	if rockmech.ore_of_rubble[base] then
		self.loadq[base] = (self.loadq[base] or 0) + lv * (g or 0)
	end
end
-- 車上這種碎石的平均品位（param2）
function V.load_grade(self, base)
	local lv, q = self.load[base], self.loadq[base]
	return lv and lv > 0 and q and math.floor(q / lv + 0.5) or 0
end
-- 車上這種碎石只剩 rest 級（平均品位不變）
function V.load_keep(self, base, rest)
	local lv = self.load[base]
	if self.loadq[base] then self.loadq[base] = rest > 0 and self.loadq[base] * rest / lv or nil end
	self.load[base] = rest > 0 and rest or nil
end

-- g：品位（param2），和既有的碎石合併時加權平均
-- 在 (x, z) 這一欄、從 ytop 往下找落點，倒 a 級 base 碎石；滿了往上堆（最多 max_h 格，預設 8）。
-- placed（可選）：收集倒下的格子，不立即做安息角流動（推土機推著的那堆）。回傳倒不下的級數
local function deposit_column(x, z, ytop, base, a, max_h, placed, g)
	g = g or 0
	local y = ytop
	for _ = 1, 8 do
		if not passable(core.get_node({x = x, y = y - 1, z = z}).name) then break end
		y = y - 1
	end
	for _ = 1, max_h or 8 do
		if a <= 0 then break end
		local p = {x = x, y = y, z = z}
		local n = core.get_node(p).name
		local k = rockmech.rubble_level[n]
		if passable(n) then
			local put = math.min(NLEV, a)
			core.set_node(p, {name = rockmech.rubble_with_level(base, put, g), param2 = g})
			a = a - put
			if placed then placed[#placed + 1] = p else collapse.check_cell(p) end
		elseif k and k < NLEV and rockmech.rubble_mixable(rockmech.rubble_base[n], base) then
			local put = math.min(NLEV - k, a)
			local b2, g2 = rockmech.rubble_merge(rockmech.rubble_base[n], k, core.get_node(p).param2, base, put, g)
			core.swap_node(p, {name = rockmech.rubble_with_level(b2, k + put, g2), param2 = g2})
			a = a - put
			if placed then placed[#placed + 1] = p else collapse.check_cell(p) end
		end
		y = y + 1
	end
	return a
end
V.deposit_column = deposit_column

V.by_uid = {}      -- 車輛編號（存在車上，重開遊戲不變）→ 目前載入的實體
local function load_total(self)
	local t = 0
	for _, v in pairs(self.load) do t = t + v end
	return t
end
V.load_total = load_total
-- 載量給人看：m³（1 級 = 1/8 m³，級是程式內部的單位）和噸（計價用的密度 rockmech_rubble_density，跟破碎站結算一致）。
-- cap 可省略
function V.volume_text(lv, cap)
	local s = ("%.1f"):format(lv / NLEV)
	if cap then s = s .. (" / %.0f"):format(cap / NLEV) end
	return s .. (" m³（%.0f t）"):format(lv / NLEV * rockmech.cfg.rubble_density)
end

-- 名牌：離最近的玩家超過 NAMETAG_R 就先不顯示（名牌畫在所有 HUD 上面，遠處一堆車會蓋住右上角的結算表），
-- 走近再出現。V.nametag 記下想顯示的字，車子的 on_step 每秒檢查一次距離
local NAMETAG_R = 40
local function nametag_near(pos)
	if not pos then return false end
	for _, p in ipairs(core.get_connected_players()) do
		local pp = p:get_pos()
		if pp and vector.distance(pp, pos) <= NAMETAG_R then return true end
	end
	return false
end
local function nametag_apply(self)
	local want = self.tag_text or ""
	local show = want ~= "" and nametag_near(self.object:get_pos())
	local text, color = show and want or "", self.tag_color or "#ffffff"
	if text == self.tag_shown and color == self.tag_shown_color then return end
	self.tag_shown, self.tag_shown_color = text, color
	self.object:set_properties({nametag = text, nametag_color = color})
end
function V.nametag(self, text, color)
	self.tag_text, self.tag_color = text or "", color
	nametag_apply(self)
end

-- 爬台階：def.tire（輪胎直徑，m）的車最高爬輪胎的一半，但至少爬得上一格方塊（否則地形的 1 m 台階都上不去）。
-- 台階低於 STEP_FREE 不減速（車轍、碎石的小高低差），越接近上限掉得越快，到上限剩 STEP_CRAWL（1 km/h）
local STEP_FREE, STEP_CRAWL = 0.25, 1 / 3.6
function V.max_step(def)
	return math.max(def.tire / 2, 1.05)
end
function V.step_speed(v, h, hmax)
	if h <= STEP_FREE then return v end
	local a = math.abs(v)
	local r = math.min(1, (h - STEP_FREE) / (hmax - STEP_FREE))
	local slow = math.max(math.min(a, STEP_CRAWL), a * (1 - r) ^ 2)
	return v >= 0 and slow or -slow
end

-- 行進方向前方（車頭或車尾外側）的地面比車底高多少
local function step_ahead(pos, dir, def, f, speed)
	local j = (f > 0 and def.half or -(def.rear or def.half)) + f * math.max(0.6, math.abs(speed) * 0.3)
	local base = pos.y - def.half
	local hmax = V.max_step(def)
	local h = 0
	for _, l in ipairs(def.lat or {-0.5, 0.5}) do
		local x, z = pos.x + dir.x * j + dir.z * l, pos.z + dir.z * j - dir.x * l
		local top = ground_top(x, base + hmax + 2, z, math.ceil(hmax) + 4)
		if top then h = math.max(h, top - base) end
	end
	return h
end

-- 車底的碎石坡：回傳 坡度 tanθ（往下坡的單位向量 x, z）；車底大多不是碎石回傳 0。
-- 量車身中央前後左右 1.5 m 的地面高度：碎石堆常常比車小，量到車身外緣會跨過堆頂，兩邊抵銷。地面在車底上下幾格內找
local function rubble_slope(pos, def)
	local r = math.min(def.half, 1.5)
	local base = pos.y - def.half
	local from = base + 3
	local function top(x, z) return ground_top(x, from, z, 8) end
	local e, w, n, s = top(pos.x + r, pos.z), top(pos.x - r, pos.z), top(pos.x, pos.z + r), top(pos.x, pos.z - r)
	if not (e and w and n and s) then return 0 end
	local loose = 0
	for _, p in ipairs({{0, 0}, {r, 0}, {-r, 0}, {0, r}, {0, -r}}) do
		local x, z = math.floor(pos.x + p[1] + 0.5), math.floor(pos.z + p[2] + 0.5)
		for y = math.floor(from + 0.5), math.floor(from + 0.5) - 8, -1 do
			local name = core.get_node({x = x, y = y, z = z}).name
			if rockmech.rubble_level[name] then loose = loose + 1; break end
			if not V.passable(name) then break end
		end
	end
	if loose < 3 then return 0 end
	local gx, gz = (e - w) / (2 * r), (n - s) / (2 * r)
	local t = math.sqrt(gx * gx + gz * gz)
	if t < 1e-6 then return 0 end
	return t, -gx / t, -gz / t
end
V.rubble_slope = rubble_slope

-- 車在碎石坡上滑動：坡度超過摩擦角（tanθ > μ）就沿最陡方向下滑，a = g(sinθ − μ·cosθ)，g 取 10。
-- 滑起來之後是動摩擦 μk = 0.7 μ：坡被壓垮變緩也不會馬上停，要滑到坡腳。
-- 回傳 這一步的滑動速度 x, z（m/s）
local SLIDE_MAX, SLIDE_STOP = 6, 2     -- 最快 (m/s)、坡度不夠時的減速 (m/s²，碎石面有起伏，太大一顛就停了)
local function slide_step(self, pos, def, dtime)
	local mu = rockmech.cfg.vehicle_slide_mu
	if (self.slide or 0) > 0 then mu = mu * 0.7 end
	local t, dx, dz = rubble_slope(pos, def)
	self.slope_t, self.slope_x, self.slope_z = t, dx, dz
	if mu > 0 and t > mu then
		local th = math.atan(t)
		local a = 10 * (math.sin(th) - mu * math.cos(th))
		self.slide = math.min(SLIDE_MAX, (self.slide or 0) + a * dtime)
		self.slide_x, self.slide_z = dx, dz
	elseif (self.slide or 0) > 0 then
		self.slide = math.max(0, self.slide - SLIDE_STOP * dtime)
	end
	local v = self.slide or 0
	if v <= 0 then return 0, 0 end
	return v * self.slide_x, v * self.slide_z
end

-- 噴凝土路面：車底三個位置（中央、左右輪跡）有兩個踩在噴凝土上就加速
local function on_shotcrete(pos, def, dir)
	local gy = math.floor(pos.y - def.half + 0.5)
	local lat = def.lat or {-0.5, 0.5}
	local n = 0
	for _, l in ipairs({0, lat[1], lat[#lat]}) do
		local x, z = math.floor(pos.x + dir.z * l + 0.5), math.floor(pos.z - dir.x * l + 0.5)
		for y = gy, gy - 1, -1 do
			if core.get_item_group(core.get_node({x = x, y = y, z = z}).name, "shotcrete") > 0 then n = n + 1; break end
		end
	end
	return n >= 2
end

-- 引擎聲：有人駕駛（或自動駕駛）才發動，一段循環音，運作時放大，約 1 秒漸變。車越重音高越低
local ENGINE_IDLE, ENGINE_RUN, ENGINE_FADE = 0.1, 0.55, 0.45
local function engine_stop(self)
	local e = self.engine
	if e then
		core.sound_stop(e.handle)
		self.engine = nil
	end
end
-- 排煙（代表吃油）：引擎發動時（有駕駛或自動駕駛）從排氣管口冒煙，怠速淡灰、作業或行駛時濃黑。
-- 排氣管口：def.exhaust（車身座標）；沒設就在車頂右後側；def.exhaust = false 不冒煙（之後的電動車）。
-- 跟其他粒子一樣，只給 EXHAUST_NEAR m 內有玩家的車產生
local EXHAUST_STEP, EXHAUST_NEAR = 0.25, 64
function V.exhaust(self, def, working, dtime)
	if def.exhaust == false or def.pushed or not self.engine then return end
	self.smoke_t = (self.smoke_t or 0) + dtime
	if self.smoke_t < EXHAUST_STEP then return end
	self.smoke_t = 0
	local pos = self.object:get_pos()
	local near = false
	for _, p in ipairs(core.get_connected_players()) do
		if vector.distance(p:get_pos(), pos) < EXHAUST_NEAR then near = true; break end
	end
	if not near then return end
	local lp = def.exhaust
	if not lp then
		local hw = 0.5
		for _, l in ipairs(def.lat or {0}) do hw = math.max(hw, math.abs(l) + 0.5) end
		lp = {x = hw * 0.6, y = (def.top or def.half) + 0.2, z = -(def.rear or def.half) * 0.3}
	end
	local o = V.to_world(self, lp)
	local big = (def.half or 1) >= 2.5
	core.add_particlespawner({
		amount = working and (big and 6 or 4) or 1, time = EXHAUST_STEP,
		minpos = vector.subtract(o, 0.05), maxpos = vector.add(o, 0.05),
		minvel = {x = -0.2, y = 1.2, z = -0.2}, maxvel = {x = 0.2, y = working and 2.5 or 1.5, z = 0.2},
		minacc = {x = 0.1, y = 0.2, z = 0.1}, maxacc = {x = 0.3, y = 0.4, z = 0.3},
		minexptime = 1.0, maxexptime = working and 2.4 or 1.6,
		minsize = big and 3 or 2, maxsize = working and (big and 7 or 5) or 3,
		texture = working and "[fill:4x4:#2a2a2a^[opacity:170" or "[fill:4x4:#8a8a8a^[opacity:110",
	})
end

local function engine_update(self, kind, working)
	local g = rockmech.cfg.vehicle_sound_gain
	if not (self.driver or self.autopilot) or g <= 0 then return engine_stop(self) end
	local e = self.engine
	if not e then
		local mass = kind == "excavator" and V.MASS.excavator_big or V.MASS[kind] or 20     -- 兩種挖土機同一個聲音
		local pitch = math.max(0.55, math.min(0.8, 0.8 * (20 / mass) ^ 0.2))
		e = {work = false, handle = core.sound_play("rockmech_engine", {object = self.object, loop = true,
			gain = ENGINE_IDLE * g, pitch = pitch, max_hear_distance = 48})}
		self.engine = e
	end
	if working ~= e.work then
		e.work = working
		core.sound_fade(e.handle, ENGINE_FADE, (working and ENGINE_RUN or ENGINE_IDLE) * g)
	end
end

-- 碰撞箱是平的方盒，一個角頂到碎石堆，整台車就架在那裡、中央懸空。車身中央離地時把箱子縮到中央，
-- 車才落得下去、順著坡傾斜；四周都不比車底高了再放回完整的箱子
local BOX_FREE, BOX_SMALL = 0.5, 1
local function settle_box(self, def, pos, dtime)
	self.box_t = (self.box_t or 0) + dtime
	if self.box_t < 0.25 then return end
	self.box_t = 0
	local base = pos.y - def.half
	local center = ground_top(pos.x, base + 2, pos.z, 8)
	if not self.box_small then
		if center and base - center > BOX_FREE then
			self.box_small = true
			local r, t = math.min(def.half - 0.02, BOX_SMALL), (def.top or def.half) - 0.02
			self.object:set_properties({collisionbox = {-r, -def.half, -r, r, t, r}})
		end
		return
	end
	local r = def.half
	for _, p in ipairs({{r, r}, {r, -r}, {-r, r}, {-r, -r}, {r, 0}, {-r, 0}, {0, r}, {0, -r}}) do
		local g = ground_top(pos.x + p[1], base + 3, pos.z + p[2], 3)
		if g and g > base + 0.1 then return end
	end
	self.box_small = nil
	local b, t = def.half - 0.02, (def.top or def.half) - 0.02
	self.object:set_properties({collisionbox = {-b, -def.half, -b, b, t, b}})
end

-- 車輛的自重 (t)，車種沒列的用 20
V.MASS = {cart = 0.2, truck = 15, haul = 70, bulktruck = 30, dozer = 20, excavator = 20, excavator_big = 100,
	jumbo = 30, charger = 20, drillrig = 25, suv = 2.5}

-- 接地壓力 (kPa) = (自重 + 車上的碎石) / 兩條輪跡的面積（各寬 1 m、長 = 車長），g 取 10。
-- 重量都在輪子或履帶下面，不能平均到整個車身
function V.ground_pressure(self, def, kind)
	local kn = (V.MASS[kind] or 20) * 10 + load_total(self) / NLEV * rockmech.cfg.failure.gamma_other
	return kn / (2 * (def.half + (def.rear or def.half)))
end

-- 交通壓實：碎石被車（總重 ≥ compact_mass）壓過 compact_passes 趟就換成壓實版（nodes.lua rockmech.compact_of），
-- 摩擦角變成 rockmech_compact_phi（collapse.lua），車輪擠不開；級數、礦種、品位都不變。
-- 壓實前照樣有車轍，壓實後高低不平就用推土機削（設計坡度）。壓過的趟數記在這格的 metadata
local function compact(p, name)
	local c = rockmech.compact_of[name]
	if not c then return end      -- 已經壓實了
	local meta = core.get_meta(p)
	local n = meta:get_int("passes") + 1
	if n < rockmech.cfg.compact_passes then meta:set_int("passes", n); return end
	meta:set_string("passes", "")
	core.swap_node(p, {name = c, param2 = core.get_node(p).param2})
end
-- 總重（t）：自重＋車上的碎石
local function gross_mass(self, kind)
	return (V.MASS[kind] or 20) + load_total(self) / NLEV * rockmech.cfg.failure.gamma_other / 10
end
V.gross_mass = gross_mass

-- 車頭（倒車時車尾）的左右兩條輪跡壓到碎石：每一格每趟判定一次，碎石只往外側擠（往前後流會把車轍填回去）。
-- 在碎石坡上（tanθ > 0.35）整個車寬都判定、往下坡擠：坡在安息角附近時，加上車重就往下垮，並往坡上傳。
-- 夠重的車整個車寬都算壓實的趟數（車轍照樣只在輪跡）。
-- 履帶車（沒有 def.tire：推土機、怪手、鑽機）不擠車轍：履帶把重量攤在很大的面積上，接地壓力只有輪胎的十分之一左右；
-- 推土機整坡時履帶壓在剛推好的面上，擠出車轍就整不平。陡的碎石坡照樣往下垮（那是邊坡破壞）
-- 車速快時一步走超過 1 m，沿著這一步的路徑逐格補上
function V.press_rubble(self, kind, def, pos, dir, f)
	local j = f > 0 and def.half or -(def.rear or def.half)
	local cx, cz = pos.x + dir.x * j, pos.z + dir.z * j
	local gy = math.floor(pos.y - def.half + 0.5)
	local q = V.ground_pressure(self, def, kind)
	local heavy = gross_mass(self, kind) >= rockmech.cfg.compact_mass
	self.pressed = self.pressed or {}
	local last = self.press_at or {x = cx, z = cz}
	self.press_at = {x = cx, z = cz}
	local steps = math.min(8, math.max(1, math.ceil(math.max(math.abs(cx - last.x), math.abs(cz - last.z)))))
	for t = 1, steps do
		local px, pz = last.x + (cx - last.x) * t / steps, last.z + (cz - last.z) * t / steps
		local lat = def.lat or {-0.5, 0.5}
		local downhill = (self.slope_t or 0) > 0.35
		for _, l in ipairs((downhill or heavy) and lat or {lat[1], lat[#lat]}) do
			local x, z = math.floor(px + dir.z * l + 0.5), math.floor(pz - dir.x * l + 0.5)
			local key = x + 65536 * z
			if self.pressed[l] ~= key then
				self.pressed[l] = key
				-- 車子傾斜時，車頭、車尾的地面和車身中心差好幾格
				for y = gy + 3, gy - 4, -1 do
					local p = {x = x, y = y, z = z}
					local name = core.get_node(p).name
					if rockmech.rubble_level[name] then
						if heavy then compact(p, name) end   -- 先算趟數：擠過之後這格可能已經不是原來的碎石
						if downhill then
							rockmech.collapse.rubble_sound(p, 1)
							rockmech.collapse.squeeze(p, q, {x = self.slope_x, z = self.slope_z, slump = true})
						elseif def.tire and (l == lat[1] or l == lat[#lat]) then   -- 輪跡
							rockmech.collapse.rubble_sound(p, 1)      -- 壓過就有聲音，空車擠不動碎石也一樣
							rockmech.collapse.squeeze(p, q, {x = dir.z * l, z = -dir.x * l})
						end
						break
					end
					if not V.passable(name) then break end
				end
			end
		end
	end
end

-- 倒出車上的碎石：平均分到 cells 所在的欄（每欄往上最多堆 8 格），之後依安息角流開
function V.dump_to_ground(self, cells, ytop)
	for base, lv in pairs(self.load) do
		local rest = 0
		local g = V.load_grade(self, base)
		for i, c in ipairs(cells) do
			local share = math.ceil(lv / (#cells - i + 1))
			lv = lv - share
			rest = rest + deposit_column(c.x, c.z, ytop, base, share, nil, nil, g)
		end
		V.load_keep(self, base, rest)
	end
end

-- 車身在 pos、朝向 yaw 時，車身座標的長方形範圍 x0..x1、z0..z1（高度在車底到車頂之間）裡有沒有
-- 沒在車上的玩家（半徑 0.3）或別台車（碰撞箱半邊長當半徑）。碰撞箱只蓋到車身那段，
-- 伸出去的車斗、鏟刀、車尾移動前用這個檢查人和車（方塊另外檢查）
-- 長車尾（車身座標 z −rear..−half：卡車車斗、鑽堡後段）不在碰撞箱裡，倒車、轉彎前自己檢查。
-- def.tail_lat／tail_dy：檢查點的橫向位置與離車底高度（更低的小台階、碎石讓碰撞箱自己爬）。
-- 回傳車尾卡進實心方塊的檢查點數
local function tail_overlap(p, yaw, def)
	local c, sn = math.cos(yaw), math.sin(yaw)
	local bottom = p.y - def.half
	local n_hit = 0
	for lz = -def.rear + 0.05, -def.half - 0.25, 0.5 do   -- 從車尾最末端開始
		for _, lx in ipairs(def.tail_lat) do
			local wx, wz = p.x + lx * c - lz * sn, p.z + lx * sn + lz * c
			for _, dy in ipairs(def.tail_dy) do
				local n = core.get_node({x = math.floor(wx + 0.5), y = math.floor(bottom + dy + 0.5), z = math.floor(wz + 0.5)}).name
				local nd = core.registered_nodes[n]
				if n ~= "air" and (not nd or nd.walkable ~= false) then n_hit = n_hit + 1 end
			end
		end
	end
	return n_hit
end
-- 從 (p, yaw) 動到 (p2, yaw2) 會不會讓車尾撞得更多（已經卡住時，不會更糟的動作照樣允許，才能脫困）
local function tail_blocked(p, yaw, p2, yaw2, def)
	local after = tail_overlap(p2, yaw2, def)
	if after == 0 then return false end
	return after > tail_overlap(p, yaw, def)
end
-- 轉彎：車尾會撞到方塊、人或車就不轉
-- 車尾和人、車：碰撞箱只蓋到車身，車斗可以貼到別台車旁邊。本來就貼著就不擋，不然永遠離不開
local function tail_hits(self, def, pos, yaw, pos2, yaw2)
	return V.objects_in(self, pos2, yaw2, -def.half, def.half, -def.rear, -def.half)
		and not V.objects_in(self, pos, yaw, -def.half, def.half, -def.rear, -def.half)
end
function V.tail_can_turn(self, pos, yaw, yaw2, def)
	return not (tail_blocked(pos, yaw, pos, yaw2, def) or tail_hits(self, def, pos, yaw, pos, yaw2))
end
-- 倒車：看後面一點（全速 0.1 s 走的距離）；前進時車尾跟著車頭走過的路，不必檢查。
-- 伺服器卡頓時一步會退很遠、預判擋不住：倒車後車尾撞得比上一步多，就退回上一步的位置
function V.tail_guard(self, def, ctx)
	local pos, dir = ctx.pos, ctx.dir
	if self.tail_safe then
		local safe = self.tail_safe
		self.tail_safe = nil
		if tail_overlap(pos, ctx.yaw, def) > safe.n then
			ctx.obj:set_pos(safe.pos)
			ctx.speed = 0
			return
		end
	end
	if ctx.speed >= 0 then return end
	local la = ctx.speed * 0.1
	local p2 = {x = pos.x + dir.x * la, y = pos.y, z = pos.z + dir.z * la}
	if tail_blocked(pos, ctx.yaw, p2, ctx.yaw, def) or tail_hits(self, def, pos, ctx.yaw, p2, ctx.yaw) then
		ctx.speed = 0
	else
		self.tail_safe = {pos = vector.copy(pos), n = tail_overlap(pos, ctx.yaw, def)}
	end
end

-- only：只看 "player" 或 "vehicle"，不給就都看。回傳 擋到了沒, 擋到的車
function V.objects_in(self, pos, yaw, x0, x1, z0, z1, only)
	local def = TYPES[self.vkind]
	local c, sn = math.cos(yaw), math.sin(yaw)
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	local center = {x = pos.x + cx * c - cz * sn, y = pos.y, z = pos.z + cx * sn + cz * c}
	local r = math.sqrt(((x1 - x0) / 2) ^ 2 + ((z1 - z0) / 2) ^ 2) + 3
	local bottom, top = pos.y - def.half, pos.y + (def.top or def.half)
	-- 同時擋到好幾台車時，先回報無人卡車（無人駕駛要叫它讓路；先回報旁邊的怪手的話就叫不到）
	local first
	for _, o in ipairs(core.get_objects_inside_radius(center, r)) do
		local e = o:get_luaentity()
		local p, m, lo, hi = o:get_pos()
		if o:is_player() and not o:get_attach() then
			if only ~= "vehicle" then m, lo, hi = 0.3, p.y, p.y + 1.8 end
		elseif e and e ~= self and e.vkind and TYPES[e.vkind] and only ~= "player" then
			local od = TYPES[e.vkind]
			m, lo, hi = od.half, p.y - od.half, p.y + (od.top or od.half)
		end
		if m and hi > bottom and lo < top then
			local dx, dz = p.x - pos.x, p.z - pos.z
			local lx, lz = dx * c + dz * sn, -dx * sn + dz * c
			if lx > x0 - m and lx < x1 + m and lz > z0 - m and lz < z1 + m then
				if not e or not e.vkind or (e.ahs and e.ahs.on) then return true, e and e.vkind and e or nil end
				first = first or e
			end
		end
	end
	if first then return true, first end
	return false
end

-- 載的碎石裡最多的那種（給車斗、鏟斗裡的碎石塊用貼圖）：回傳 總級數, 種類
function V.load_mix(self)
	local total, best, bl = 0, nil, 0
	for base, lv in pairs(self.load or {}) do
		total = total + lv
		if lv > bl then best, bl = base, lv end
	end
	return total, best
end
-- 車上的礦石：回傳 礦石, 整車的品位（0..1，廢石算 0）；沒有礦石回傳 nil
function V.load_ore(self)
	local total, ore, q = 0, nil, 0
	for base, lv in pairs(self.load or {}) do
		total = total + lv
		local o = rockmech.ore_of_rubble[base]
		if o then ore, q = o, q + (self.loadq[base] or 0) end
	end
	if not ore or total == 0 then return nil end
	return ore, q / total / 255
end
-- 碎石種類的貼圖（給碎石塊零件）
function V.rubble_tex(base)
	local nd = core.registered_nodes[base]
	local t = nd and nd.tiles and nd.tiles[1]
	return type(t) == "table" and t.name or t or "[fill:16x16:#6a6058"
end

-- 車斗、鏟斗裡碎石的貼圖：有礦石時和地上的碎石一樣，用整車的品位選外觀
function V.fill_tex(self)
	local ore, grade = V.load_ore(self)
	if not ore then
		local _, best = V.load_mix(self)
		return V.rubble_tex(best)
	end
	return V.rubble_tex(rockmech.rubble_with_level(ore.rubble, NLEV, grade * 255))
end

dofile(rockmech.modpath .. "/vehicle_views.lua")
local hud_clear, update_hud, update_mirrors = V.hud_clear, V.update_hud, V.update_mirrors

-- 車上存放：def.store = {{物品, 容量, 名稱}, …}，self.store[物品] = 數量（跟著車存檔，收車時還給玩家）。
-- V.open_store 打開存放畫面：「裝滿」從背包拿（創造模式直接裝滿）、「卸下」放回背包；作業時用 V.store_take 消耗
function V.store_count(self, item) return self.store[item] or 0 end
function V.store_take(self, item, n)
	local have = self.store[item] or 0
	n = math.min(n, have)
	self.store[item] = have - n
	return n
end
local store_open = {}
local function store_formspec(self)
	local list = TYPES[self.vkind].store
	local fs = {("formspec_version[6]size[8.2,%.1f]"):format(1.5 + #list * 1.2)}
	for i, s in ipairs(list) do
		local y = 0.4 + (i - 1) * 1.2
		fs[#fs + 1] = ("item_image[0.4,%.1f;0.9,0.9;%s]label[1.5,%.2f;%s　%d / %d]button[4.5,%.1f;1.6,0.9;fill_%d;裝滿]button[6.2,%.1f;1.6,0.9;out_%d;卸下]")
			:format(y, s[1], y + 0.45, s[3], V.store_count(self, s[1]), s[2], y, i, y, i)
	end
	fs[#fs + 1] = ("button_exit[5.8,%.1f;2,0.7;ok;完成]"):format(0.5 + #list * 1.2)
	return table.concat(fs)
end
function V.open_store(self, player)
	store_open[player:get_player_name()] = self
	core.show_formspec(player:get_player_name(), "rockmech:store", store_formspec(self))
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "rockmech:store" then return end
	local name = player:get_player_name()
	local self = store_open[name]
	if not self or not self.object:get_pos() then return true end
	local inv = player:get_inventory()
	for i, s in ipairs(TYPES[self.vkind].store) do
		local item, cap = s[1], s[2]
		local have = V.store_count(self, item)
		if fields["fill_" .. i] and have < cap then
			local got = core.is_creative_enabled(name) and cap - have
				or inv:remove_item("main", ItemStack(item .. " " .. (cap - have))):get_count()
			self.store[item] = have + got
		elseif fields["out_" .. i] and have > 0 then
			self.store[item] = inv:add_item("main", ItemStack(item .. " " .. have)):get_count()
		end
	end
	if fields.quit or fields.ok then store_open[name] = nil
	else core.show_formspec(name, "rockmech:store", store_formspec(self)) end
	update_hud(self)
	return true
end)

-- 駕駛的姿勢（有 player_api 時）：上車坐著、下車恢復
local function set_seated(player, on, pose)
	if not player then return end
	-- 開車時收起快捷欄與手上拿的東西（不擋駕駛艙畫面），下車再顯示
	player:hud_set_flags({hotbar = not on, wielditem = not on})
	if not player_api then return end
	local name = player:get_player_name()
	player_api.player_attached[name] = on or nil
	player_api.set_animation(player, on and (pose or "sit") or "stand")
end

local function drop_chase(self)
	if self.chase then
		if self.chase:get_pos() then self.chase:remove() end
		self.chase = nil
	end
end

local function get_off(self)
	local d = self.driver and core.get_player_by_name(self.driver)
	drop_chase(self)
	if d then
		d:set_detach()
		d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		d:set_camera({mode = "any"})
		set_seated(d, false)
		hud_clear(self, d)
		-- 放到車外站得下人的地方（不能放進車身、伸出去的車斗或岩石、碎石裡，會卡住）：
		-- 左側、右側（車身中段、靠後）、車尾後、車頭前，依序選第一個空的；腳底在地面上（或高一格）
		local p = self.object:get_pos()
		local yaw = self.object:get_yaw()
		local def = TYPES[self.vkind]
		local c, sn = math.cos(yaw), math.sin(yaw)
		local hw = def.half + PLAYER_R + PUSH_CLEAR + 0.3
		-- 伸出碰撞箱那段（車斗、挖臂…）的寬度也要讓開
		for _, r in ipairs(def.overhangs or {}) do hw = math.max(hw, -r.x0 + PLAYER_R + PUSH_CLEAR, r.x1 + PLAYER_R + PUSH_CLEAR) end
		local rear = (def.rear or def.half) + PLAYER_R + PUSH_CLEAR + 0.3
		local cands = {{-hw, 0}, {hw, 0}, {-hw, -rear / 2}, {hw, -rear / 2}, {0, -rear}, {0, def.half + 1.2},
			{-hw - 1.5, 0}, {hw + 1.5, 0}}
		local feet = p.y - def.half + 0.05
		local spot
		for _, cd in ipairs(cands) do
			for _, dy in ipairs({0, 1}) do
				local q = {x = p.x + cd[1] * c - cd[2] * sn, y = feet + dy, z = p.z + cd[1] * sn + cd[2] * c}
				if body_free(q) then spot = q; break end
			end
			if spot then break end
		end
		spot = spot or {x = p.x, y = p.y + (def.top or def.half) + 0.1, z = p.z}     -- 四周都被擋住：站到車頂上
		core.after(0.1, function()
			if d:get_pos() then d:set_pos(spot) end
		end)
	end
	self.driver = nil
	hud_clear(self, nil)
end

-- 註冊一種車：實體 rockmech:<kind> 與物品 rockmech:<kind>_item
function V.register(kind, def)
	TYPES[kind] = def
	local ename = "rockmech:" .. kind
	core.register_entity(ename, {
		initial_properties = {
			physical = true,
			collide_with_objects = true,   -- 玩家擋得住、車子之間會相撞（只有碰撞箱那段；伸出去的車斗、鏟刀、挖臂不算）
			collisionbox = {-def.half + 0.02, -def.half, -def.half + 0.02, def.half - 0.02, (def.top or def.half) - 0.02, def.half - 0.02},
			selectionbox = def.select_box or def.rear and {-def.half, -def.half, -def.rear, def.half, def.top or def.half, def.half, rotate = true}
				or {-def.half, -def.half, -def.half, def.half, def.top or def.half, def.half},
			visual = "cube",
			-- 外觀都由零件組成：車身不能放大（掛在上面的零件位置與大小會跟著放大），
			-- 用全透明貼圖（不能設 is_visible = false，掛在上面的零件會一起被隱藏）
			visual_size = {x = 1, y = 1, z = 1},
			textures = {CLEAR, CLEAR, CLEAR, CLEAR, CLEAR, CLEAR},
			use_texture_alpha = true,
			backface_culling = true,       -- 從車身裡面往外看是透明的
			stepheight = def.tire and V.max_step(def) + 0.02 or def.stepheight or 1.1,
			static_save = true,
		},
		vkind = kind,
		on_activate = function(self, staticdata)
			self.load, self.store, self.loadq = {}, {}, {}
			local data = staticdata ~= "" and core.deserialize(staticdata) or nil
			-- 快照比地圖裡的資料新（伺服器被強制結束，地圖沒存到最新的車）：用快照，車子放回快照的位置
			local snap = data and data.uid and V.snapshot_of(data.uid)
			if snap and snap.wall > (data.wall or 0) then
				local sd = core.deserialize(snap.data)
				if sd then
					data = sd
					if snap.pos then self.object:set_pos(snap.pos) end
					core.log("action", ("[rockmech] %s（%s）從快照還原（地圖裡的資料比較舊）"):format(def.desc, data.uid))
				end
			end
			self.uid = data and data.uid or ("%x-%x"):format(os.time(), math.random(0, 0xffffff))
			V.by_uid[self.uid] = self
			if data then
				self.load = data.load or {}
				self.loadq = data.loadq or {}
				self.store = data.store or {}
				if data.yaw then self.object:set_yaw(data.yaw) end
				if data.owner then V.set_owner(self, data.owner) end
				V.load_hp(self)
			end
			if def.on_load then def.on_load(self, data or {}) end
			V.registry_save(self)
			self.object:set_acceleration({x = 0, y = -9.81, z = 0})
			self.object:set_armor_groups({immortal = 1})
			V.refresh(self)
			self.t_act = 0
			if def.parts then
				core.after(0, function()
					if self.object:get_pos() then
						spawn_parts(self, def.parts)
						if def.on_spawn then def.on_spawn(self) end
					end
				end)
			end
		end,
		on_deactivate = function(self)
			if V.by_uid[self.uid] == self then V.by_uid[self.uid] = nil end
			if self.kept then keep_area(self, self.object:get_pos() or {x = 0, y = 0, z = 0}, true) end   -- 放掉強制載入的區塊
			engine_stop(self)
			remove_parts(self)
			drop_chase(self)
		end,
		get_staticdata = function(self)
			local data = {load = self.load, loadq = self.loadq, store = self.store, yaw = self.object:get_yaw(), uid = self.uid,
				owner = self.owner, wall = os.time()}
			if def.on_save then def.on_save(self, data) end
			return core.serialize(data)
		end,
		on_rightclick = function(self, clicker)
			if not clicker or not clicker:is_player() then return end
			local name = clicker:get_player_name()
			if self.driver == name then get_off(self); return end
			if self.driver then return end
			if not V.may_use(self, name) then return end
			-- 無人機飛行中（或拿著遙控器）按右鍵：起飛／回到起飛點，不上車
			if rockmech.drone_flying and rockmech.drone_flying(name) or rockmech.drone_remote_item
					and rockmech.drone_remote_item(clicker:get_wielded_item():get_name()) then
				rockmech.drone_toggle(clicker)
				return
			end
			if clicker:get_wielded_item():get_name() == "rockmech:radio" then   -- 對講機：右鍵和左鍵一樣，不上車
				rockmech.radio_click(clicker, {type = "object", ref = self.object})
				return
			end
			if clicker:get_wielded_item():get_name() == "rockmech:ahs_module" then   -- 自動駕駛模組：裝到這台車上
				if V.ahs and V.ahs.install then V.ahs.install(self, clicker) end
				return
			end
			if clicker:get_wielded_item():get_name() == "rockmech:breaker_kit" then  -- 油壓破碎錘改裝套件：只有怪手裝得上
				if def.install_breaker then def.install_breaker(self, clicker)
				else core.chat_send_player(name, "[破碎錘] 只有怪手裝得上") end
				return
			end
			if def.rightclick and def.rightclick(self, clicker) then return end   -- 拿著特定物品按右鍵（怪手操作員）
			-- 上車要走到車旁邊：手上的東西指得遠（對講機 64 m）時，右鍵點得到遠處的車
			local cp, vp = clicker:get_pos(), self.object:get_pos()
			if math.sqrt((cp.x - vp.x) ^ 2 + (cp.z - vp.z) ^ 2) > math.max(def.half, def.rear or 0) + BOARD_REACH then return end
			if rockmech.career_load and rockmech.career_load(clicker, self, def) then return end
			-- 從別台車直接換過來：先把原本那台的駕駛清掉（否則兩台都聽這個玩家的）
			local parent = clicker:get_attach()
			local pe = parent and parent:get_luaentity()
			if pe and pe ~= self and pe.driver == name then
				hud_clear(pe, clicker)
				pe.driver = nil
			end
			self.driver = name
			-- def.pushed（手推車）：人走在車後面推，面向車斗。實體的車尾朝前（車斗、倒土的邏輯都不用改）
			if def.pushed then
				clicker:set_attach(self.object, "", {x = 0, y = -def.half * 10, z = def.push_z * 10}, {x = 0, y = 180, z = 0})
				clicker:set_look_horizontal(self.object:get_yaw() + math.pi)
			else
				clicker:set_attach(self.object, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
			end
			-- 第三人稱：盡量抬高（上限 y 1.5 m、前後 ±0.5 m），從後上方看得到駕駛艙與手臂
			clicker:set_eye_offset(eye_offset(def), {x = 0, y = 15, z = -5})
			clicker:set_camera({mode = "first"})
			set_seated(clicker, true, def.pushed and "stand")
			update_hud(self)
		end,
		on_punch = function(self, puncher)
			if not puncher or not puncher:is_player() or self.driver then return true end
			-- 經營模式：車放出來就收不回身上了（跟真的一樣），只有開了 /god 的人可以收
			if rockmech.cfg.career and puncher:get_meta():get_int("godmode:on") ~= 1 then return true end
			if not V.may_use(self, puncher:get_player_name()) then return true end
			if rockmech.cfg.career and load_total(self) > 0 then    -- 經營模式碎石不進物品欄
				core.chat_send_player(puncher:get_player_name(), "車上還有碎石，先倒掉才能收起來")
				return true
			end
			local inv = puncher:get_inventory()
			local left = inv:add_item("main", ItemStack(ename .. "_item"))
			if not left:is_empty() then core.add_item(self.object:get_pos(), left) end
			for base, lv in pairs(self.load) do
				local n = math.floor(lv / NLEV + 0.5)
				if n > 0 then
					local l2 = inv:add_item("main", ItemStack(base .. " " .. n))
					if not l2:is_empty() then core.add_item(self.object:get_pos(), l2) end
				end
			end
			for item, n in pairs(self.store) do
				if n > 0 then
					local l3 = inv:add_item("main", ItemStack(item .. " " .. n))
					if not l3:is_empty() then core.add_item(self.object:get_pos(), l3) end
				end
			end
			-- 裝了自動駕駛模組：模組一起還給他；有雇操作員：解雇（停止計薪）
			if self.ahs_mod then
				if self.uid then rockmech.collapse.storage:set_string("ahsmod:" .. self.uid, "") end
				local l4 = inv:add_item("main", ItemStack("rockmech:ahs_module"))
				if not l4:is_empty() then core.add_item(self.object:get_pos(), l4) end
			end
			if self.breaker then
				local l5 = inv:add_item("main", ItemStack("rockmech:breaker_kit"))
				if not l5:is_empty() then core.add_item(self.object:get_pos(), l5) end
			end
			-- 有操作員（在車上或站在旁邊等）：回營地休息（operator.lua）
			if self.op and (self.op.on or self.op.standby) and rockmech.op_send_rest then rockmech.op_send_rest(self, puncher) end
			V.snapshot_clear(self.uid)
			V.registry_drop(self.uid)
			remove_parts(self)
			self.object:remove()
			return true
		end,
		on_step = function(self, dtime)
			local obj = self.object
			-- 掛在別的東西上（平板拖車載著）：不自己動，只冒受損的煙
			if obj:get_attach() then
				damage_smoke(self, dtime)
				return
			end
			local pos = obj:get_pos()
			local yaw = obj:get_yaw()
			local vel = obj:get_velocity()
			keep_area(self, pos)
			self.t_tag = (self.t_tag or 0) + dtime
			if self.t_tag >= 1 then self.t_tag = 0; nametag_apply(self) end
			-- 零件被引擎拆掉了（見 PART 的 on_step）：每秒檢查一次，少了就整組重新生成
			if self.part_list then
				self.t_parts = (self.t_parts or 0) + dtime
				if self.t_parts >= 1 then
					self.t_parts = 0
					for _, o in ipairs(self.part_list) do
						local par = o:get_pos() and o:get_attach()
						if par ~= obj then
							spawn_parts(self, def.parts)
							if def.on_spawn then def.on_spawn(self) end
							V.refresh(self)
							break
						end
					end
				end
			end
			local d = self.driver and core.get_player_by_name(self.driver)
			if self.driver and not d then self.driver = nil; hud_clear(self, nil) end
			-- 駕駛已經不在這台車上（換到別台、被傳送、死亡等）：不再聽他的
			if d then
				local parent = d:get_attach()
				local pe = parent and parent:get_luaentity()
				if not (pe == self or (self.chase and parent and pe and pe.name == CHASE and pe.vehicle == self)) then
					hud_clear(self, d)
					if not parent then
						d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
						d:set_camera({mode = "any"})
						set_seated(d, false)
					end
					self.driver, d = nil, nil
				end
			end
			if d then update_mirrors(self, d, dtime) end
			-- 第一人稱視線限制在車頭左右 look_limit 以內（看後面用後照鏡、倒車攝影機）
			if d and def.look_limit and not self.chase then
				local front = yaw + (def.pushed and math.pi or 0)   -- 手推車的前方是實體的車尾
				local rel = (d:get_look_horizontal() - front + math.pi) % (2 * math.pi) - math.pi
				if math.abs(rel) > def.look_limit then
					d:set_look_horizontal(front + (rel > 0 and def.look_limit or -def.look_limit))
				end
			end
			local fwd, turn = 0, 0
			damage_smoke(self, dtime)
			local wrecked = (self.hp or 100) <= 0
			-- self.autopilot：沒有駕駛時的控制輸入（測試、指令用），格式同 get_player_control
			local ctrl = d and d:get_player_control() or self.autopilot or {}
			local driven = d or self.autopilot
			if driven then
				if d and ctrl.sneak then get_off(self); return end
				fwd = (ctrl.up and 1 or 0) - (ctrl.down and 1 or 0)
				if def.pushed then fwd = -fwd end
				turn = (ctrl.left and 1 or 0) - (ctrl.right and 1 or 0)
			end
			if wrecked then fwd, turn = 0, 0 end                                   -- 報廢：不能開、不能轉
			-- 手推車沒有方向盤：人看哪裡就推向哪裡
			if def.pushed and d then
				local rel = (d:get_look_horizontal() - yaw) % (2 * math.pi) - math.pi
				local step = TURN_RATE * dtime
				turn = math.max(-1, math.min(1, rel / step))
				if math.abs(rel) < 0.02 then turn = 0 end
			end
			if turn ~= 0 and def.can_turn and not def.can_turn(self, pos, yaw, yaw + turn * TURN_RATE * dtime) then
				turn = 0
			end
			if turn ~= 0 then
				yaw = yaw + turn * TURN_RATE * dtime
				obj:set_yaw(yaw)
			end
			-- 外觀隨地形傾斜（角度平滑趨近）
			if def.tilt then
				local tp, tr = ground_tilt(pos, yaw, def)
				local k = math.min(1, dtime * 6)
				self.pitch = (self.pitch or 0) + (tp - (self.pitch or 0)) * k
				self.roll = (self.roll or 0) + (tr - (self.roll or 0)) * k
				obj:set_rotation({x = self.pitch, y = yaw, z = self.roll})
			end
			local regions = def.overhangs_now and def.overhangs_now(self) or def.overhangs
			if regions then push_players(self, pos, yaw, def, regions) end
			local dir, s = dirs(yaw)
			settle_box(self, def, pos, dtime)
			local slide_x, slide_z = slide_step(self, pos, def, dtime)
			if fwd ~= 0 or (self.slide or 0) > 0 then V.press_rubble(self, kind, def, pos, dir, fwd ~= 0 and fwd or 1) end
			-- 直線前進一段時間後慢慢加速到 top_speed；轉彎時減速回 speed，停下、倒車就回到 speed
			local speed = def.speed * fwd * ((self.hp or 100) < V.WORN and 0.6 or 1)   -- 受損：跑得慢
			if def.top_speed then
				local cur = self.cruise or def.speed
				if fwd > 0 and turn == 0 then cur = math.min(def.top_speed, cur + def.accel * dtime)
				elseif fwd > 0 then cur = math.max(def.speed, cur - 4 * dtime)
				else cur = def.speed end
				self.cruise = cur
				if fwd > 0 then speed = cur end
			end
			local ctx = {obj = obj, pos = pos, yaw = yaw, dir = dir, s = s, fwd = fwd, dtime = dtime, d = d, ctrl = ctrl,
				speed = speed}
			-- 爬坡能力：上坡超過最大爬坡角就上不去；坡上越陡越慢（到最大爬坡角剩 30%）
			local steep
			if def.max_grade and fwd ~= 0 then
				local g = travel_grade(pos, yaw, def, fwd)
				if g > def.max_grade then
					ctx.speed, ctx.fwd = 0, 0
					steep = ("坡太陡（%d° > %d°）"):format(math.floor(math.deg(g) + 0.5), math.floor(math.deg(def.max_grade) + 0.5))
				elseif g > 0 then
					ctx.speed = ctx.speed * (1 - 0.7 * g / def.max_grade)
				end
			end
			if def.tire and ctx.fwd ~= 0 then
				-- 往前看的距離照實際車速（不是想開的速度：在坡上被減速成慢爬時還照極速往前看，坡本身就一直被當成台階）
				local h, hmax = step_ahead(pos, dir, def, ctx.fwd, math.sqrt(vel.x * vel.x + vel.z * vel.z)), V.max_step(def)
				ctx.speed = V.step_speed(ctx.speed, h, hmax)
				if h > hmax and not steep then steep = ("台階太高（%.1f m > %.1f m）"):format(h, hmax) end
			end
			if steep ~= self.steep then self.steep = steep; update_hud(self) end
			if ctx.speed ~= 0 and on_shotcrete(pos, def, dir) then ctx.speed = ctx.speed * rockmech.cfg.shotcrete_speed end
			if def.move then def.move(self, ctx) end
			if def.pushed then
				if d and player_api then player_api.set_animation(d, ctx.speed ~= 0 and "walk" or "stand") end
			else
				local working = ctx.speed ~= 0 or turn ~= 0 or self.dig ~= nil or self.tip ~= nil or self.boring ~= nil
					or (def.busy ~= nil and def.busy(self))
				engine_update(self, kind, working)
				V.exhaust(self, def, working, dtime)
				-- 燃料費（fuel.lua）：引擎發動（有人駕駛或自動駕駛）才耗油，空車停著不算
				if driven and rockmech.fuel_step then rockmech.fuel_step(self, kind, working, dtime) end
			end
			obj:set_velocity({x = dir.x * ctx.speed + slide_x, y = vel.y, z = dir.z * ctx.speed + slide_z})
			-- HUD 時速（每 5 km/h 更新一次）
			if def.top_speed then
				local kmh = math.floor(math.abs(ctx.speed) * 3.6 / 5 + 0.5) * 5
				if kmh ~= self.kmh then self.kmh = kmh; update_hud(self) end
			end
			if def.step then def.step(self, ctx) end
			-- 儀表板按鍵列（vehicle_views.lua）：開關狀態變了就重畫
			if d then
				self.keys_t = (self.keys_t or 0) + dtime
				if self.keys_t >= 0.5 then self.keys_t = 0; V.update_keys(self, d) end
			end
			-- Z（zoom 鍵）：切換追蹤相機（駕駛掛到車子後上方的點上）／車頂第一人稱
			if d then
				if ctrl.zoom and not self.zoom_held and not def.pushed then
					if self.chase then
						drop_chase(self)
						d:set_detach()
						d:set_attach(obj, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
						d:set_eye_offset(eye_offset(def), {x = 0, y = 15, z = -5})
					else
						local c = core.add_entity(chase_pos(self, def), CHASE)
						if c then
							c:get_luaentity().vehicle = self
							self.chase = c
							d:set_detach()
							d:set_attach(c, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
							d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
						end
					end
					d:set_camera({mode = "first"})
					set_seated(d, true)
					update_hud(self)   -- 追蹤相機時收起駕駛艙框與後照鏡，回到車上再顯示
				end
				self.zoom_held = ctrl.zoom
			end
			-- 追蹤相機跟著車子
			if self.chase then
				if self.chase:get_pos() and d then self.chase:move_to(chase_pos(self, def), true)
				else drop_chase(self) end
			end
			-- 作業鍵（防連按：各車自己設 self.t_act）
			self.t_act = self.t_act - dtime
			if driven and self.t_act <= 0 and def.action and not wrecked then def.action(self, ctx) end
		end,
	})
	core.register_craftitem(ename .. "_item", {
		description = def.desc .. "\n" .. def.item_desc .. (rockmech.cfg.career and "\n放出來就收不回背包，先選好位置再放" or ""),
		inventory_image = def.inv_image,
		stack_max = 1,
		on_place = function(itemstack, placer, pointed)
			if pointed.type ~= "node" then return itemstack end
			local a = pointed.above
			local odd = (def.half * 2) % 2 == 1
			local off = odd and 0 or 0.5
			local obj = core.add_entity({x = a.x + off, y = a.y - 0.5 + def.half, z = a.z + off}, ename)
			if obj and placer then obj:set_yaw(placer:get_look_horizontal() + (def.pushed and math.pi or 0)) end
			-- 經營模式：車歸放置者的帳戶（分組時是整組）
			if obj and placer and rockmech.cfg.career and rockmech.account_of then
				local e = obj:get_luaentity()
				if e then V.set_owner(e, rockmech.account_of(placer:get_player_name())) end
			end
			if not core.is_creative_enabled(placer and placer:get_player_name() or "") then itemstack:take_item() end
			return itemstack
		end,
	})
end

dofile(rockmech.modpath .. "/vehicle_excavator.lua")
dofile(rockmech.modpath .. "/vehicle_ahs.lua")
dofile(rockmech.modpath .. "/vehicle_truck.lua")
dofile(rockmech.modpath .. "/vehicle_haul.lua")
dofile(rockmech.modpath .. "/vehicle_cart.lua")
dofile(rockmech.modpath .. "/vehicle_dozer.lua")
dofile(rockmech.modpath .. "/vehicle_jumbo.lua")
dofile(rockmech.modpath .. "/vehicle_drillrig.lua")
dofile(rockmech.modpath .. "/vehicle_bulktruck.lua")
dofile(rockmech.modpath .. "/vehicle_suv.lua")
dofile(rockmech.modpath .. "/vehicle_miner.lua")
dofile(rockmech.modpath .. "/vehicle_lowboy.lua")
dofile(rockmech.modpath .. "/vehicle_corerig.lua")
