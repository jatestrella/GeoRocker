-- rockmech/vehicle_excavator.lua
-- 反鏟挖土機（由 vehicles.lua 載入）：同一套程式產生兩種尺寸（excavator(kind, P)，P 是尺寸與數值）：
--   挖土機（3×3×3：兩側半格寬履帶、2×2×2 駕駛艙、前方動臂與鏟斗，鏟斗 4 m³）
--   礦用挖土機（200 t 級，Komatsu PC2000／Cat 6020B：7 寬 × 7 高、大機艙、左前方駕駛室，手臂約 15 m、鏟斗 12 m³）
--   E：挖斗伸到滑鼠指的位置，挖起那一格周圍的碎石（dig_r 格內、上下各 1 層）再收回；
--   空白鍵：挖斗伸到滑鼠指的位置倒出（指著有車斗的車就倒進車斗），同樣的抬起 → 下降 → 倒 → 收回動作。
--   第一人稱駕駛時上部結構（機艙、駕駛室、手臂）跟著視線的水平方向迴轉；追蹤相機（第三人稱）時不跟

local S = rockmech.S
local E = core.formspec_escape
local V = rockmech.vehicles
local TYPES, NLEV = V.TYPES, V.NLEV
local h2v, v2h, lerp, lerp_angle, atan2 = V.h2v, V.v2h, V.lerp, V.lerp_angle, V.atan2
local box_tex, seg_attach, to_local = V.box_tex, V.seg_attach, V.to_local

-- 圖示：履帶、上部結構、駕駛室、動臂＋斗桿＋鏟斗。一般的畫小一點（佔圖示下半）；
-- big：礦用，撐滿整個圖示，駕駛室架高、有欄杆與爬梯、配重高、鏟斗大
local function excavator_icon(c, big)
	local r = {}
	if not big then
		V.icon_track(r, 5, 26, 16, 5)
		r[#r + 1] = {6, 21, 15, 5, c}; r[#r + 1] = {5, 21, 3, 4, "#3a3a3a"}
		r[#r + 1] = {13, 16, 6, 5, c}; r[#r + 1] = {14, 17, 4, 3, "#9fd0ff"}
		V.icon_line(r, 17, 20, 22, 12, 2, c)
		V.icon_line(r, 23, 12, 25, 21, 2, c)
		r[#r + 1] = {23, 22, 5, 4, "#505050"}
		return V.icon(r)
	end
	V.icon_track(r, 1, 24, 24, 8)
	r[#r + 1] = {3, 15, 20, 9, c}; r[#r + 1] = {1, 11, 6, 13, "#3a3a3a"}
	r[#r + 1] = {13, 4, 8, 11, c}; r[#r + 1] = {14, 5, 6, 5, "#9fd0ff"}
	r[#r + 1] = {3, 12, 10, 1, "#e0e0e0"}; r[#r + 1] = {3, 12, 1, 3, "#e0e0e0"}; r[#r + 1] = {12, 12, 1, 3, "#e0e0e0"}
	for y = 16, 22, 2 do r[#r + 1] = {10, y, 3, 1, "#3a3a3a"} end   -- 爬梯
	V.icon_line(r, 19, 13, 25, 0, 4, c)
	V.icon_line(r, 27, 0, 28, 13, 3, c)
	r[#r + 1] = {22, 14, 10, 10, "#505050"}; r[#r + 1] = {22, 23, 10, 1, "#808080"}
	return V.icon(r)
end
local load_total, update_hud = V.load_total, V.update_hud
local TRACK = V.TRACK

-- 挖的動作：抬到目標上方 P.lift → 往下插進目標（挖）→ 抬回目標上方 → 收回。各段時間 (s)
local DIG_PHASES = {0.3, 0.2, 0.2, 0.3}
local DIG_TOTAL = DIG_PHASES[1] + DIG_PHASES[2] + DIG_PHASES[3] + DIG_PHASES[4]

-- 有車斗的車（卡車等，TYPES[kind].bed）
local function hauler_def(e)
	local hd = e and e.vkind and TYPES[e.vkind]
	return hd and hd.bed and hd
end

-- 操作員是真的人（operator.lua）：在機械設備課長那裡雇用拿到一張「怪手操作員」，對沒人的怪手按右鍵就用掉這張、
-- 他坐上怪手作業。右鍵有操作員坐著的怪手不會上車，而是打開操作員頁面：截止品位、叫下車（站在怪手旁邊等，人才能上車）、
-- 回基地休息。站在旁邊等的操作員對他按右鍵可以叫他上車作業或回基地。
-- 他坐在怪手上原地作業（不開動履帶，換工作面由玩家開過去）：在手臂範圍內挖表面露出、品位 ≥ 截止品位的碎石
-- （最近的先挖；鏟斗會帶到旁邊的格子，界線附近的廢石一起上來就是貧化），有卡車停在手臂範圍內就倒進去
-- （無人卡車、玩家開來的都算），沒車就拿著滿斗等。車子（自己、卡車）底下的格子不挖
-- 油壓破碎錘改裝套件：拿著對怪手右鍵裝上（vehicles.lua）。鏟斗空的時候空白鍵切換鏟斗／破碎錘；
-- 破碎錘對著岩石按 E：敲 UCS × rockmech_breaker_s_per_mpa 秒（比能：破碎同體積的岩石，所需能量跟強度成正比），
-- 那格變成原地的碎石（同鎬子，品位留著）
core.register_craftitem("rockmech:breaker_kit", {
	description = S("Hydraulic breaker\nRight-click an excavator to fit it"),
	short_description = S("Hydraulic breaker kit"),
	inventory_image = "[fill:16x16:#00000000^[fill:6x9:5,1:#2a2a2a^[fill:6x2:5,4:#c8a020^[fill:2x5:7,10:#8a8e92",
	stack_max = 1,
})
local OP_ITEM = "rockmech:operator"
local OP_THINK, OP_IDLE = 0.5, 2     -- 每隔幾秒想下一步；沒東西可挖時隔久一點再找 (s)
local op_editing = {}                -- 玩家名稱 → 正在設定的怪手
-- 經營模式（車子有主人）：操作員付日薪（wages.lua），在車上、站在旁邊等都計薪，回基地休息才停
local function op_paid(self) return rockmech.cfg.career and self.owner and self.owner ~= "" and rockmech.wage_hire end
local function op_form(self)
	local op = self.op or {cutoff = 0.5}
	local paid = op_paid(self)
	local items, sel = {}, 1
	for i = 0, 20 do
		items[#items + 1] = (i * 5) .. "%"
		if math.abs(i * 0.05 - op.cutoff) < 1e-6 then sel = i + 1 end
	end
	return table.concat({
		"formspec_version[6]size[11.5,5.7]",
		("label[0.5,0.6;%s]"):format(E(S("@1 operator", TYPES[self.vkind].short or S("Excavator")))),
		("label[0.5,1.2;%s]"):format(E(S("Status: @1", op.on and (op.msg or S("Working")) or S("No operator")))),
		("label[0.5,1.9;%s]"):format(E(S("Cut-off grade (only digs rubble with grade ≥ this)"))),
		("dropdown[0.5,2.2;3,0.8;cutoff;%s;%d;false]"):format(table.concat(items, ","), sel),
		("button[0.5,3.4;3.4,0.8;off;%s]"):format(E(S("Step down (so a player can drive)"))),
		("button[4.05,3.4;3.4,0.8;rest;%s]"):format(E(S("Rest at base"))),
		("button_exit[7.6,3.4;3.4,0.8;close;%s]"):format(E(S("Close"))),
		paid and ("label[0.5,4.6;%s]label[0.5,5.1;%s]"):format(
			E(S("Daily wage $@1 (one trading day = @2 min), deducted pro rata while team members are online",
				("%g"):format(rockmech.operator_wage()), tostring(math.floor(rockmech.cfg.price_period / 60 + 0.5)))),
			E(S("Wages are paid while in the cab or waiting nearby; only resting at base stops them")))
			or ("label[0.5,4.6;%s]"):format(E(S("Works in place: once the ore within arm reach is dug out, drive the excavator to a new face"))),
	})
end
rockmech.op_paid = op_paid
-- 對講機：左鍵點怪手選定，再左鍵點地面叫那台的操作員開過去（op.go）；點正在移動的那台叫它停下。
-- 只有派了操作員的怪手聽得到。走法見 op_drive
local RADIO = "rockmech:radio"
local radio_sel = {}        -- 玩家名稱 → 選定的怪手 uid
local function radio_tell(name, msg) if name then rockmech.notify(name, S("[Radio] @1", msg)) end end
local function excavator_of(ref)
	for _ = 1, 3 do                          -- 點到手臂、駕駛室這些零件：往上找車身
		local e = ref and ref:get_luaentity()
		if e and e.vkind then return e.vkind:find("excavator", 1, true) and e or nil end
		ref = ref and ref:get_attach()
	end
end
-- 有車斗、能無人駕駛的車（卡車、礦卡）
local function hauler_of(ref)
	for _ = 1, 3 do
		local e = ref and ref:get_luaentity()
		if e and e.vkind then
			local def = V.TYPES[e.vkind]
			return def and def.bed and not def.no_ahs and e or nil
		end
		ref = ref and ref:get_attach()
	end
end
-- 左鍵、右鍵都一樣（右鍵點車子由 vehicles.lua 轉過來，不會上車）
-- 點卡車、礦卡：遠端打開那台的無人駕駛設定（啟動、停止、立即出發…），跟坐在車上按 E 一樣
function rockmech.radio_click(user, pointed)
	local name = user:get_player_name()
	if pointed.type == "object" then
		local h = hauler_of(pointed.ref)
		if h then
			if not V.may_use(h, name) then return end
			if h.driver then radio_tell(name, S("Someone is driving that vehicle")); return end
			V.ahs.open(h, user)
			return
		end
		local e = excavator_of(pointed.ref)
		if not e then radio_tell(name, S("Point at an excavator or a truck")); return end
		if not rockmech.vehicles.may_use(e, name) then return end
		if e.op and e.op.go and radio_sel[name] == e.uid then
			e.op.go, e.op.esc, e.op.msg = nil, nil, nil
			e.autopilot = {}
			radio_tell(name, S("Stopped"))
			return
		end
		radio_sel[name] = e.uid
		radio_tell(name, (e.op and e.op.on) and S("Excavator selected: click the ground to send it there")
			or S("Excavator selected, but it has no operator (send one in with an Excavator operator first)"))
	elseif pointed.type == "node" then
		local e = radio_sel[name] and V.by_uid[radio_sel[name]]
		if not (e and e.object:get_pos()) then radio_tell(name, S("Select an excavator first")); return end
		if not (e.op and e.op.on) then radio_tell(name, S("That excavator has no operator")); return end
		local g = pointed.above
		e.op.go, e.op.by, e.op.tries, e.op.esc, e.op.prog = {x = g.x, y = g.y, z = g.z}, name, 0, nil, nil
		core.add_particlespawner({amount = 30, time = 2, pos = {min = vector.subtract(g, 0.3), max = vector.add(g, {x = 0.3, y = 2, z = 0.3})},
			vel = {x = 0, y = 1, z = 0}, exptime = 1, size = 3, texture = "[fill:4x4:#40a0ff", glow = 14, playername = name})
		radio_tell(name, S("Copy, heading to (@1, @2, @3), @4 m", ("%d"):format(g.x), ("%d"):format(g.y), ("%d"):format(g.z),
			("%d"):format(vector.distance(e.object:get_pos(), g))))
	end
end
core.register_craftitem(RADIO, {
	description = S("Radio\nClick an excavator, then the ground"),
	short_description = S("Radio"),
	inventory_image = "[fill:16x16:#00000000^[fill:6x11:5,4:#303030^[fill:4x3:6,6:#70c070^[fill:1x4:9,0:#303030^[fill:4x3:6,11:#555555",
	stack_max = 1,
	range = 64,
	on_use = function(itemstack, user, pointed) rockmech.radio_click(user, pointed) end,
	on_place = function(itemstack, user, pointed) rockmech.radio_click(user, pointed); return itemstack end,
})

-- 操作員坐在駕駛座上：一個坐姿的人（從車窗看得到）
local function op_show(self)
	local op = self.op
	if op and op.on then
		rockmech.vehicles.nametag(self, S("Operator: @1 (cut-off grade @2%)", op.msg or S("Working"), ("%d"):format(op.cutoff * 100 + 0.5)), "#ffe080")
	else
		rockmech.vehicles.nametag(self, "")
	end
	rockmech.vehicles.cab_figure(self)
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= OP_ITEM then return end
	local name = player:get_player_name()
	local self = op_editing[name]
	if not self or not self.object:get_pos() then return true end
	local op = self.op or {cutoff = 0.5}
	self.op = op
	if fields.cutoff then op.cutoff = (tonumber(fields.cutoff:match("^(%d+)")) or 50) / 100 end
	if fields.off and op.on then
		-- 叫下車：站到怪手旁邊等（照樣計薪），人才能上車
		rockmech.op_step_down(self)
		rockmech.notify(name, S("[Operator] Stepped down and waiting beside the excavator; right-click him to send him back to work or to rest at base"))
		op_editing[name] = nil
		core.close_formspec(name, OP_ITEM)
		return true
	elseif fields.rest and op.on then
		rockmech.op_send_rest(self, player)
		op_editing[name] = nil
		core.close_formspec(name, OP_ITEM)
		return true
	end
	op_show(self)
	if fields.quit or fields.close then op_editing[name] = nil
	else core.show_formspec(name, OP_ITEM, op_form(self)) end
	return true
end)

-- clear：車窗半透明（看得到裡面的人；駕駛室要 alpha = true）
local function cab_tex(c, win_w, clear)
	local ww = win_w or 6
	local win = clear and (V.cab_glass(c, 2, 2, 12, 7) .. "^[fill:16x2:0,14:#2a2a2a")
		or ("[fill:16x16:%s^[fill:12x7:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local side = clear and (V.cab_glass(c, 14 - ww, 2, ww, 6) .. "^[fill:16x2:0,14:#2a2a2a")
		or ("[fill:16x16:%s^[fill:%dx6:%d,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c, ww, 14 - ww)
	return {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", side, side, win, ("[fill:16x16:%s"):format(c)}
end

-- P：def 的欄位（desc、color、cap、speed、half…）之外：
--   body：不轉的零件（履帶、下車架）；house：跟著迴轉的零件 {id, pos（上部結構座標）, size, tex}
--   boom_root、bucket_rest（上部結構座標）、boom_len、stick_len、boom_w、stick_w；bucket（挖斗大小）、bucket_color
--   bucket_real（鏟斗真實尺寸：寬、斗高、斗深；斗裡碎石的大小也照這個算）
--   dig_r（挖、倒在目標周圍幾格）、dig_reach（從相機量）、lift（抬到目標上方）、swing_rate（rad/s）、dump_reach
--   body_box（擋人：車身，大車引擎擋不住走近的玩家）
local function excavator(kind, P)
	local def = P.def
	local BOOM_ROOT, BUCKET_REST = P.boom_root, P.bucket_rest
	local BOOM_LEN, STICK_LEN = P.boom_len, P.stick_len
	local ARM_REACH = BOOM_LEN + STICK_LEN
	def.arm_reach = ARM_REACH

	local parts = {}
	for _, p in ipairs(P.body) do parts[#parts + 1] = p end
	for _, p in ipairs(P.house) do parts[#parts + 1] = p end
	-- 鏟斗：側面看是 J 形的殼（前壁、底板、往駕駛那側翹起的斗唇）＋兩片側板＋斗齒。
	-- 下面的座標是「平端」姿勢（開口朝上）的鏟斗座標，中心在小臂尖端；挖、倒時整組繞橫軸翻（self.curl）
	-- 尺寸照真實鏟斗（P.bucket_real：寬、斗高、斗深；接點在後壁頂端，接點到齒尖約 1.2–1.3 倍斗深）
	local BR = P.bucket_real or P.bucket
	local BW, BH, BD = BR.x, BR.y, BR.z
	local BT = BH * 0.09                                   -- 鋼板厚度
	local lip_a, lip_c = {y = -BH / 2, z = -BD / 4}, {y = BH * 0.1, z = -BD / 2}
	local lip_len = math.sqrt((lip_c.y - lip_a.y) ^ 2 + (lip_c.z - lip_a.z) ^ 2)
	local lip_pitch = atan2(lip_c.z - lip_a.z, lip_c.y - lip_a.y)
	local lip_dir = {y = (lip_c.y - lip_a.y) / lip_len, z = (lip_c.z - lip_a.z) / lip_len}
	local bc = P.bucket_color
	local shell = ("[fill:16x16:%s^[fill:16x1:0,0:#2a2a2a^[fill:16x1:0,15:#2a2a2a^[fill:1x16:0,0:#2a2a2a^[fill:1x16:15,0:#2a2a2a"):format(bc)
	local side = ("[fill:16x16:%s^[fill:16x2:0,0:#303030^[fill:2x16:0,0:#303030^[fill:2x16:14,0:#303030^[fill:10x2:3,9:#3c3c3c"):format(bc)
	local steel = "[fill:16x16:#9a9ea4^[fill:16x3:0,13:#c8ccd0"
	-- {id, 鏟斗座標的中心, 大小, 自己的俯仰（rad）, 貼圖}
	local BK = {
		{"bucket", {x = 0, y = -BH / 2 + BT / 2, z = BD / 8}, {x = BW, y = BT, z = BD * 0.75}, 0, {shell, shell, shell, shell, shell, shell}},
		{"bk_front", {x = 0, y = 0, z = BD / 2 - BT / 2}, {x = BW, y = BH, z = BT}, 0, {shell, shell, shell, shell, shell, shell}},
		{"bk_lip", {x = 0, y = (lip_a.y + lip_c.y) / 2, z = (lip_a.z + lip_c.z) / 2}, {x = BW, y = lip_len, z = BT}, lip_pitch, {shell, shell, shell, shell, shell, shell}},
		{"bk_sl", {x = -BW / 2 + BT / 2, y = 0, z = 0}, {x = BT, y = BH, z = BD}, 0, {side, side, side, side, side, side}},
		{"bk_sr", {x = BW / 2 - BT / 2, y = 0, z = 0}, {x = BT, y = BH, z = BD}, 0, {side, side, side, side, side, side}},
		-- 頂上的耳板（跟小臂接的地方）
		{"bk_ear", {x = 0, y = BH / 2 + BT, z = BD * 0.38}, {x = BW * 0.3, y = BT * 2, z = BD * 0.24}, 0, box_tex("#303030")},
	}
	local NT = BW > 2 and 6 or 5
	local TL = BH * 0.22
	for i = 1, NT do
		local x = -BW / 2 + BW * (i - 0.5) / NT
		BK[#BK + 1] = {"bk_t" .. i, {x = x, y = lip_c.y + lip_dir.y * TL / 2, z = lip_c.z + lip_dir.z * TL / 2},
			{x = BW / NT * 0.45, y = TL, z = BT * 1.6}, lip_pitch, {steel, steel, steel, steel, steel, steel}}
	end
	for _, k in ipairs(BK) do
		parts[#parts + 1] = {id = k[1], pos = BUCKET_REST, size = k[3], tex = k[5]}
	end
	-- 翻斗角度（rad，繞鏟斗的橫軸；0 = 平端、開口朝上；負的往外翻：挖之前張開、倒的時候開口朝下）
	local CURL_OPEN, CURL_DUMP = math.rad(-165), math.rad(-140)
	local function rot_x(o, th)
		local c, sn = math.cos(th), math.sin(th)
		return {x = o.x, y = o.y * c - o.z * sn, z = o.y * sn + o.z * c}
	end
	-- 小臂尖端接在耳板頂上（鏟斗座標），鏟斗掛在下面
	local EAR = {x = 0, y = BH / 2 + BT * 2, z = BD * 0.38}
	local function place_bucket(self, vb, psi, hide)
		local ps, th = self.parts, self.curl or 0
		for i, k in ipairs(BK) do
			local o = ps[k[1]]
			if o and i > 1 then o:set_properties({is_visible = not hide}) end
			if o and not hide then
				local c = vector.add(vb, h2v(rot_x(k[2], th), psi))
				o:set_attach(self.object, "", {x = c.x * 10, y = c.y * 10, z = c.z * 10},
					{x = math.deg(th + k[4]), y = math.deg(psi), z = 0})
			end
		end
	end
	-- 破碎錘：換掉鏟斗時，鏟斗那個零件變成細長的錘身，下面再伸出一根鋼鑿（平常藏起來）
	local HAMMER = {x = P.bucket.x * 0.36, y = P.bucket.y * 1.6, z = P.bucket.z * 0.62}
	local CHISEL = {x = P.bucket.x * 0.09, y = P.bucket.y * 0.75, z = P.bucket.x * 0.09}
	local hs = "[fill:16x16:#2a2a2c^[fill:16x2:0,2:#d8a020^[fill:16x1:0,13:#18181a^[fill:2x6:7,6:#3a3a3e"
	local HAMMER_TEX = {"[fill:16x16:#3a3a3e", "[fill:16x16:#18181a", hs, hs, hs, hs}
	parts[#parts + 1] = {id = "chisel", pos = BUCKET_REST, size = CHISEL, tex = box_tex("#b8bcc2")}
	local HAMMER_REST = {x = BUCKET_REST.x, y = BUCKET_REST.y - P.bucket.y / 2 + HAMMER.y + CHISEL.y, z = BUCKET_REST.z}
	local function rest(self) return self.tool == "breaker" and HAMMER_REST or BUCKET_REST end
	-- 手臂停在哪（上部結構座標）：挖完、倒完就停在那裡，下一個動作從這裡開始；還沒動過就是收起的位置
	local function hold(self) return self.arm_h or rest(self) end
	parts[#parts + 1] = {id = "boom", pos = BUCKET_REST, size = {x = P.boom_w, y = BOOM_LEN, z = P.boom_w}, tex = box_tex(def.color)}
	-- 小臂：跟大臂的接點在小臂上端約 1/5 處（接點以上 STICK_TAIL 是給小臂油壓缸推的尾巴），接點到鏟斗仍是 STICK_LEN
	local STICK_TAIL = STICK_LEN / 4
	parts[#parts + 1] = {id = "stick", pos = BUCKET_REST, size = {x = P.stick_w, y = STICK_LEN + STICK_TAIL, z = P.stick_w}, tex = box_tex(def.color)}
	-- 鏟斗裡的碎石：高度依載量（空 → 不顯示），貼圖用載最多的那種碎石
	-- 碎石的大小照鏟斗內部：寬＝斗寬扣兩片側板，長＝底板扣前壁，高：空 15% → 滿 95% 斗高
	local FILL_W, FILL_L = BW - 2 * BT - 0.02, BD * 0.75 - BT - 0.02
	local FILL_Z = BD / 8 - BT / 2
	local FILL_H0, FILL_H1 = BH * 0.15, BH * 0.95
	parts[#parts + 1] = {id = "fill", pos = BUCKET_REST, size = {x = FILL_W, y = 0.2, z = FILL_L}, tex = box_tex("#6a6058")}
	def.parts = parts
	-- 冒煙：排氣管（上部結構的 "stack" 零件）頂端，跟著迴轉
	-- 駕駛座的人偶（操作員、開追蹤相機的駕駛）：駕駛室裡，跟著上部結構轉
	if P.op_seat then
		function def.figure_pos(self) return h2v(P.op_seat, self.swing or 0) end
		function def.figure_yaw(self) return self.swing or 0 end
	end
	function def.figure_skin(self)
		if self.op and self.op.on then return rockmech.npc_skin and rockmech.npc_skin("operator") or "character.png" end
	end
	for _, hp in ipairs(P.house) do
		if hp.id == "stack" then
			local top = {x = hp.pos.x, y = hp.pos.y + hp.size.y / 2 + 0.05, z = hp.pos.z}
			def.exhaust = function(self) return h2v(top, self.swing or 0) end
		end
	end

	-- 油壓缸（大臂缸、小臂缸、鏟斗缸）：缸筒從一端、活塞桿從另一端，長度都固定，各自朝對方伸過去，
	-- 兩段重疊多少跟著手臂姿勢變，看起來就是在伸縮。長度在下面掃過整個工作範圍後決定
	local CYL_KEYS = {"boom", "arm", "bkt"}
	local CYL = {}
	local function unit(v) local l = vector.length(v); return l > 1e-6 and vector.divide(v, l) or nil end
	local function perp(dir, ref)         -- ref 垂直於 dir 的分量（單位向量）
		return unit(vector.subtract(ref, vector.multiply(dir, vector.dot(ref, dir))))
	end
	local UP = {x = 0, y = 1, z = 0}
	-- 三支缸的兩端（車身座標）；base 是大臂缸在上部結構上的固定點
	local function cyl_points(vr, ve, vb, base)
		local bd = unit(vector.subtract(ve, vr)) or UP
		local nb = perp(bd, UP) or {x = 0, y = 0, z = 1}                  -- 大臂上方
		local u = unit(vector.subtract(vb, ve)) or {x = 0, y = -1, z = 0}
		local out = perp(u, vector.subtract(ve, vr))                       -- 小臂外側（離大臂那邊）
		out = out and vector.multiply(out, 1) or nb
		local tail = vector.subtract(ve, vector.multiply(u, STICK_TAIL * 0.9))
		local boom_mid = vector.add(vr, vector.multiply(bd, BOOM_LEN * 0.45))
		return {
			boom = {base, vector.subtract(boom_mid, vector.multiply(nb, P.boom_w * 0.6))},
			arm = {vector.add(vector.add(vr, vector.multiply(bd, BOOM_LEN * 0.4)), vector.multiply(nb, P.boom_w * 0.9)), tail},
			bkt = {vector.add(vector.add(ve, vector.multiply(u, STICK_LEN * 0.1)), vector.multiply(out, P.stick_w * 0.8)),
				vector.add(vector.add(ve, vector.multiply(u, STICK_LEN * 0.85)), vector.multiply(out, P.stick_w * 0.8))},
		}
	end
	local CYL_BASE = {x = BOOM_ROOT.x, y = BOOM_ROOT.y - BOOM_LEN * 0.2, z = BOOM_ROOT.z + BOOM_LEN * 0.05}
	-- 挖斗位置 b（上部結構座標）→ 實際搆得到的挖斗位置、手肘位置。
	-- 手臂兩節長度固定：手肘由餘弦定理求出（手肘朝上），長方體沿各節方向旋轉（seg_attach）
	local function arm_solve(b)
		local dx, dy, dz = b.x - BOOM_ROOT.x, b.y - BOOM_ROOT.y, b.z - BOOM_ROOT.z
		local hl = math.sqrt(dx * dx + dz * dz)
		local hx, hz = 0, 1
		if hl > 1e-6 then hx, hz = dx / hl, dz / hl end
		local D = math.sqrt(hl * hl + dy * dy)
		local Dmin, Dmax = math.abs(BOOM_LEN - STICK_LEN) + 0.05, ARM_REACH - 0.05
		local phi = atan2(dy, hl)
		if D > Dmax or D < Dmin then
			D = math.max(Dmin, math.min(Dmax, D))
			b = {x = BOOM_ROOT.x + D * math.cos(phi) * hx, y = BOOM_ROOT.y + D * math.sin(phi), z = BOOM_ROOT.z + D * math.cos(phi) * hz}
		end
		local cosA = (BOOM_LEN * BOOM_LEN + D * D - STICK_LEN * STICK_LEN) / (2 * BOOM_LEN * D)
		local ang = phi + math.acos(math.max(-1, math.min(1, cosA)))
		local elbow = {x = BOOM_ROOT.x + BOOM_LEN * math.cos(ang) * hx, y = BOOM_ROOT.y + BOOM_LEN * math.sin(ang),
			z = BOOM_ROOT.z + BOOM_LEN * math.cos(ang) * hz}
		return b, elbow
	end

	-- 掃過工作範圍（上部結構座標、不迴轉）：每支缸兩端距離的最長、最短 → 缸筒、活塞桿長度
	do
		local lo, hi = {}, {}
		for f = 0, 20 do
			for h = -20, 20 do
				local b = {x = BOOM_ROOT.x, y = BOOM_ROOT.y + h / 20 * ARM_REACH, z = BOOM_ROOT.z + f / 20 * ARM_REACH}
				local bb, el = arm_solve(b)
				local pts = cyl_points(BOOM_ROOT, el, bb, CYL_BASE)
				for _, k in ipairs(CYL_KEYS) do
					local d = vector.distance(pts[k][1], pts[k][2])
					lo[k], hi[k] = math.min(lo[k] or d, d), math.max(hi[k] or d, d)
				end
			end
		end
		for _, k in ipairs(CYL_KEYS) do
			-- 最長時兩段剛好接上；最短時缸筒不超過另一端太多
			local L = math.max(hi[k] / 2 + 0.05, math.min(lo[k], hi[k] * 0.6))
			local w = (k == "bkt" and P.stick_w or P.boom_w) * 0.42
			CYL[k] = L
			parts[#parts + 1] = {id = "cb_" .. k, pos = BUCKET_REST, size = {x = w, y = L, z = w}, tex = box_tex(def.color)}
			parts[#parts + 1] = {id = "cr_" .. k, pos = BUCKET_REST, size = {x = w * 0.55, y = L, z = w * 0.55}, tex = box_tex("#c8ccd0")}
		end
	end

	-- 鏟斗裡的碎石（parts.fill）：跟著載量改高度與貼圖，擺在挖斗上面
	local function place_fill(self, b, psi)
		local o = self.parts and self.parts.fill
		if not o then return end
		local total, best = V.load_mix(self)
		local frac = math.min(1, total / def.cap)
		local h = frac > 0 and (FILL_H0 + (FILL_H1 - FILL_H0) * frac) or 0
		local tex = total > 0 and V.fill_tex(self)
		local key = ("%.2f/%s"):format(h, tostring(tex))
		if self.fill_key ~= key then
			self.fill_key = key
			if h > 0 then
				local t = tex
				o:set_properties({is_visible = true, visual_size = {x = FILL_W, y = h, z = FILL_L}, textures = {t, t, t, t, t, t}})
			else
				o:set_properties({is_visible = false})
			end
		end
		-- 碎石放在斗裡（底板上），跟著鏟斗翻
		local th = self.curl or 0
		local c = vector.add(b, h2v(rot_x({x = 0, y = -BH / 2 + BT + h / 2, z = FILL_Z}, th), psi or 0))
		o:set_attach(self.object, "", {x = c.x * 10, y = c.y * 10, z = c.z * 10}, {x = math.deg(th), y = math.deg(psi or 0), z = 0})
	end

	-- 挖斗放在 b（上部結構座標）；上部結構迴轉 self.swing
	local function place_arm(self, b)
		local ps = self.parts
		if not ps then return end
		local psi = self.swing or 0
		local elbow
		-- b 是斗身中心；小臂尖端在耳板上（跟著翻斗轉）。破碎錘：b 就是小臂尖端
		local ear = self.tool ~= "breaker" and rot_x(EAR, self.curl or 0) or nil
		if ear then b = vector.add(b, ear) end
		b, elbow = arm_solve(b)
		local vb, ve, vr = h2v(b, psi), h2v(elbow, psi), h2v(BOOM_ROOT, psi)
		local vc = ear and vector.subtract(vb, h2v(ear, psi)) or vb      -- 斗身中心
		local rot = {x = 0, y = math.deg(psi), z = 0}
		for _, hp in ipairs(P.house) do
			local o = ps[hp.id]
			if o then
				local c = h2v(hp.pos, psi)
				o:set_attach(self.object, "", {x = c.x * 10, y = c.y * 10, z = c.z * 10}, rot)
			end
		end
		if self.tool == "breaker" then
			-- 破碎錘：挖臂末端是錘身的上端，錘身、鋼鑿順著 hammer_dir（車身座標，平常垂直往下；
			-- 敲側面時 45° 往下指著作用面）伸出去，鋼鑿尖碰到岩面，不跟岩塊重疊
			local dir = self.hammer_dir or {x = 0, y = -1, z = 0}
			local mid = vector.add(vb, vector.multiply(dir, HAMMER.y))
			local tip = vector.add(mid, vector.multiply(dir, CHISEL.y))
			place_bucket(self, vb, psi, true)
			seg_attach(self, ps.bucket, vb, mid)
			seg_attach(self, ps.chisel, mid, tip)
		else
			place_bucket(self, vc, psi, false)
		end
		place_fill(self, vc, psi)
		self.bucket_at = vc
		seg_attach(self, ps.boom, vr, ve)
		local su = vector.normalize(vector.subtract(vb, ve))
		seg_attach(self, ps.stick, vector.subtract(ve, vector.multiply(su, STICK_TAIL)), vb)
		local pts = cyl_points(vr, ve, vb, h2v(CYL_BASE, psi))
		for _, k in ipairs(CYL_KEYS) do
			local a, c = pts[k][1], pts[k][2]
			local dir = unit(vector.subtract(c, a))
			if dir then
				local L = CYL[k]
				-- 兩端比缸筒還近：缸筒往後退（縮進車身／手臂裡），不刺穿另一端
				local a0 = vector.distance(a, c) < L and vector.subtract(c, vector.multiply(dir, L)) or a
				seg_attach(self, ps["cb_" .. k], a0, vector.add(a0, vector.multiply(dir, L)))
				seg_attach(self, ps["cr_" .. k], vector.subtract(c, vector.multiply(dir, L)), c)
			end
		end
	end

	-- 目標（車身座標）→ 上部結構要轉的角度、目標在上部結構座標、離動臂根部的距離
	local function swing_to(tl)
		local psi = atan2(tl.x, tl.z)
		local h = v2h(tl, psi)
		local reach = math.sqrt((h.x - BOOM_ROOT.x) ^ 2 + (h.y - BOOM_ROOT.y) ^ 2 + (h.z - BOOM_ROOT.z) ^ 2)
		return psi, h, reach
	end

	local AIM_MARGIN = 0.5
	-- 滑鼠指的東西：從駕駛的相機沿視線找。回傳 {under, above}（方塊）或 {truck = 有車斗的車}；沒有回傳 nil。
	-- with_trucks：也找有車斗的車（跳過自己、零件與玩家）
	local function aim(self, d, pos, with_trucks)
		local look = d:get_look_dir()
		local hl = math.sqrt(look.x * look.x + look.z * look.z)
		local fx, fz = hl > 0 and look.x / hl or 0, hl > 0 and look.z / hl or 0
		local side = def.eye_side or 0   -- 往右（視線的右邊 = (fz, −fx)）
		-- 相機高度：坐著的動畫把玩家的眼睛高度改成 0.8 m（不是站著的 1.625），照玩家實際的 eye_height 算，
		-- 不然射線從比相機高約 0.8 m 的地方出發，指到的格子會比準心遠
		local pr = d.get_properties and d:get_properties()
		local eh = pr and pr.eye_height or V.EYE_HEIGHT
		local eye = {x = pos.x + fx * def.eye_fwd + fz * side, y = pos.y + eh + def.eye_up - V.EYE_HEIGHT, z = pos.z + fz * def.eye_fwd - fx * side}
		local reach = P.dig_reach
		if self.chase and self.chase:get_pos() then
			eye = vector.add(self.chase:get_pos(), {x = 0, y = eh, z = 0})
			reach = P.dig_reach + 12   -- 追蹤相機在車子後方，射線要長一點
		end
		-- 先找方塊
		local node_hit, node_t
		for pt in core.raycast(eye, vector.add(eye, vector.multiply(look, reach)), false, false) do
			if pt.type == "node" then
				node_hit = {under = pt.under, above = pt.above}
				node_t = vector.distance(eye, pt.intersection_point)
				break
			end
		end
		-- 再找有車斗的車：沿視線每 0.1 m 檢查是否落在車身內（照車子朝向旋轉；伺服器的射線不會旋轉選取框）。
		-- 車身每邊放寬 AIM_MARGIN：指到車斗邊框時射線只掠過車身一小段，要算指到
		if with_trucks then
			local trucks = {}
			for _, o in ipairs(core.get_objects_inside_radius(eye, reach + 12)) do
				local e = o:get_luaentity()
				if e and e ~= self and hauler_def(e) then trucks[#trucks + 1] = e end
			end
			if #trucks > 0 then
				local tmax = node_t or reach
				for t = 0, tmax, 0.1 do
					local p = vector.add(eye, vector.multiply(look, t))
					for _, e in ipairs(trucks) do
						local tp, ty = e.object:get_pos(), e.object:get_yaw()
						if tp then
							local dx, dy, dz = p.x - tp.x, p.y - tp.y, p.z - tp.z
							local c, sn = math.cos(ty), math.sin(ty)
							local lx, lz = dx * c + dz * sn, -dx * sn + dz * c
							local td = TYPES[e.vkind]
							local m = td.aim_margin or AIM_MARGIN
							if math.abs(lx) <= td.half + m and dy >= -td.half and dy <= td.bed.aim_top + m
								and lz >= -td.rear - m and lz <= td.half + m then
								return {truck = e}
							end
						end
					end
				end
			end
		end
		return node_hit
	end
	if kind == "excavator" then rockmech.vehicle_aim = aim end   -- 測試用

	-- 車頭前方的有車斗的車（HUD 顯示它的載量）
	local function find_truck(pos, s)
		local dd = def.half + 1.5
		local front = {x = pos.x + s.x * dd, y = pos.y, z = pos.z + s.z * dd}
		for _, obj in ipairs(core.get_objects_inside_radius(front, P.dump_reach)) do
			local e = obj:get_luaentity()
			if hauler_def(e) then return e end
		end
	end

	function def.hud(self)
		local s = ""
		local p = self.object:get_pos()
		local truck = p and find_truck(p, select(2, V.dirs(self.object:get_yaw())))
		if truck then
			local tt, cap = load_total(truck), TYPES[truck.vkind].cap
			s = s .. "\n" .. S("@1 ahead: @2", TYPES[truck.vkind].short, V.volume_text(tt, cap))
		end
		if self.breaker then s = s .. "\n" .. (self.tool == "breaker" and S("Tool: hydraulic breaker") or S("Tool: bucket (Space switches to the breaker when the bucket is empty)")) end
		return s
	end
	function def.keys(self)
		if self.tool == "breaker" then
			return {{"E", S("Break rock (block under cursor)"), on = self.dig ~= nil}, {S("Space"), S("Back to bucket")}}
		end
		return {{"E", S("Dig (where the cursor points)"), on = self.dig ~= nil},
			{S("Space"), self.breaker and load_total(self) == 0 and S("Switch to breaker") or S("Dump (point at a truck to load it)")}}
	end
	-- 擋人：鏟斗（跟著手臂動；用把鏟斗連同裡面的碎石包起來的方塊，不照迴轉角轉），大車再加上整個車身
	-- 擋人：只有大車的車身（引擎擋不住走近的玩家）。鏟斗不擋：手臂停在工作的位置（常常在地上、坑裡），
	-- 擋人範圍旁邊推不出去時會把人放到鏟斗頂上、每一步重放一次，人就卡在半空中
	function def.overhangs_now(self)
		return P.body_box and {P.body_box} or nil
	end

	function def.on_load(self, data)
		self.swing, self.op = data.swing, data.op
		self.breaker, self.tool = data.breaker, data.tool
		-- 舊版的操作員（還沒算進全組的雇用人數）：補算一個
		if self.op and (self.op.on or self.op.standby) and not self.op.counted then
			self.op.counted = true
			if rockmech.op_adopt then rockmech.op_adopt(data.owner) end
		end
	end
	function def.on_save(self, data) data.swing, data.op, data.breaker, data.tool = self.swing, self.op, self.breaker, self.tool end
	-- 鏟斗的樣子：裝著破碎錘時是深灰色的錘頭
	local function show_tool(self)
		local ps = self.parts
		if not ps then return end
		local hammer = self.tool == "breaker"
		if ps.bucket then
			ps.bucket:set_properties(hammer and {visual_size = HAMMER, textures = HAMMER_TEX}
				or {visual_size = BK[1][3], textures = BK[1][5]})
		end
		if ps.chisel then ps.chisel:set_properties({is_visible = hammer}) end
		place_arm(self, hold(self))
	end
	function def.on_spawn(self) place_arm(self, rest(self)); op_show(self); show_tool(self) end
	-- 油壓破碎錘改裝套件（vehicles.lua：拿著套件對怪手右鍵）
	function def.install_breaker(self, player)
		local name = player:get_player_name()
		if self.breaker then rockmech.notify(name, S("[Breaker] This one already has it installed")); return end
		self.breaker, self.tool = true, "bucket"
		if not core.is_creative_enabled(name) then
			local st = player:get_wielded_item(); st:take_item(); player:set_wielded_item(st)
		end
		rockmech.notify(name, S("[Breaker] Installed: with an empty bucket press Space to switch to the breaker, then point at rock and press E to break it"))
		update_hud(self)
	end
	def.show_tool = show_tool

	-- 右鍵：操作員坐在車上 → 操作員頁面（不上車）；拿著「怪手操作員」對沒人的怪手 → 派他上車
	function def.rightclick(self, clicker)
		local name = clicker:get_player_name()
		local op = self.op
		if op and op.on then
			op_editing[name] = self
			core.show_formspec(name, OP_ITEM, op_form(self))
			return true
		end
		if clicker:get_wielded_item():get_name() ~= OP_ITEM then return false end
		if op and op.standby then
			rockmech.notify(name, S("[Operator] This excavator's operator is waiting beside it: right-click him to send him in"))
			return true
		end
		local stack = clicker:get_wielded_item()
		if not rockmech.op_card_ok(stack, clicker, self) then return true end
		self.op = {cutoff = op and op.cutoff or 0.5, on = true, t = 0, counted = true}
		if op_paid(self) then rockmech.wage_hire(self.uid, self.owner) end
		if not core.is_creative_enabled(name) then
			stack:take_item()
			clicker:set_wielded_item(stack)
		end
		op_show(self)
		rockmech.notify(name, op_paid(self) and S("[Operator] Getting in to work, daily wage $@1 (paid while team members are online)", ("%g"):format(rockmech.operator_wage()))
			or S("[Operator] Getting in to work"))
		op_editing[name] = self
		core.show_formspec(name, OP_ITEM, op_form(self))
		return true
	end
	def.op_show = op_show

	-- 操作員：手臂搆得到 wp 嗎（和 def.action 用同一套算法，挑出來的目標一定挖得到）
	local function in_reach(self, wp)
		local _, _, reach = swing_to(to_local(self, wp))
		return reach <= ARM_REACH - 0.2
	end
	-- 停在手臂範圍內、還裝得下、沒在開也沒在倒的有車斗的車，最近的那台
	local function op_truck(self, pos)
		local best, bd
		for _, o in ipairs(core.get_objects_inside_radius(pos, ARM_REACH + 10)) do
			local e = o:get_luaentity()
			local td = e ~= self and hauler_def(e)
			if td and not e.tip and load_total(e) < td.cap and vector.length(o:get_velocity()) < 0.3 then
				local bt = V.bed_target(e, pos)
				local d = vector.distance(pos, bt)
				if in_reach(self, bt) and (not bd or d < bd) then best, bd = e, d end
			end
		end
		return best
	end
	-- 手臂範圍內表面露出、品位 ≥ 截止品位、不在車子底下的碎石，最近的那格。
	-- 鏟斗會挖起目標周圍 dig_r 格、上下各 1 層：車子底下再往外留這一圈，才不會把車子的地基挖空
	local SAFE = P.dig_r + 0.5
	local function op_target(self, pos, cutoff)
		local R = math.ceil(ARM_REACH)
		local cars = {}
		for _, o in ipairs(core.get_objects_inside_radius(pos, R + 12)) do
			local e = o:get_luaentity()
			if e and e.vkind and TYPES[e.vkind] then cars[#cars + 1] = {o:get_pos(), o:get_yaw(), TYPES[e.vkind]} end
		end
		local p0 = vector.round(pos)
		local best, bd
		for _, c in ipairs(core.find_nodes_in_area(vector.subtract(p0, {x = R, y = R, z = R}), vector.add(p0, {x = R, y = 4, z = R}), rockmech.rubble_nodes)) do
			local node = core.get_node(c)
			local ore = rockmech.ore_of_rubble[rockmech.rubble_base[node.name]]
			local g = ore and node.param2 / 255 or 0
			if g >= cutoff - 1e-6 and V.passable(core.get_node({x = c.x, y = c.y + 1, z = c.z}).name) then
				local under = false
				for _, car in ipairs(cars) do
					local cp, yaw, td = car[1], car[2], car[3]
					local dx, dz = c.x - cp.x, c.z - cp.z
					local co, sn = math.cos(yaw), math.sin(yaw)
					local lx, lz = dx * co + dz * sn, -dx * sn + dz * co
					if c.y <= cp.y - td.half + 1.5 and math.abs(lx) <= td.half + SAFE
						and lz >= -(td.rear or td.half) - SAFE and lz <= td.half + SAFE then under = true; break end
				end
				local d = vector.distance(pos, c)
				if not under and (not bd or d < bd) and in_reach(self, c) then best, bd = c, d end
			end
		end
		return best
	end
	local function op_say(self, msg)
		if self.op.msg ~= msg then self.op.msg = msg; op_show(self) end
	end
	-- 對講機叫他開到 op.go：原地轉向目標再直線開過去（爬坡、台階照車輛本身的限制）。
	-- 想往前開卻 STUCK_T 秒沒前進 1 m 就脫困一次：倒車、往左或右（輪流）轉、再往前開；試 STUCK_TRIES 次還過不去就停下回報。
	-- 不會繞過大障礙（坑、岩壁）：那要玩家分段指揮
	local ARRIVE, STUCK_T, STUCK_TRIES = math.max(1.5, def.half), 4, 4
	local function op_drive(self, ctx)
		local op, pos = self.op, ctx.pos
		local g = op.go
		local dx, dz = g.x - pos.x, g.z - pos.z
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist < ARRIVE then
			op.go, op.esc, op.prog = nil, nil, nil
			self.autopilot = {}
			op_say(self, nil)
			radio_tell(op.by, S("Arrived, starting work"))
			return
		end
		local esc = op.esc
		if esc then
			esc.t = esc.t - ctx.dtime
			if esc.t > 0 then self.autopilot = esc.steps[esc.i]; return end
			esc.i = esc.i + 1
			if esc.steps[esc.i] then esc.t = esc.times[esc.i]; self.autopilot = esc.steps[esc.i]; return end
			op.esc = nil
		end
		local diff = (atan2(-dx, dz) - ctx.yaw + math.pi) % (2 * math.pi) - math.pi
		local ap = {}
		if diff > 0.08 then ap.left = true elseif diff < -0.08 then ap.right = true end
		if math.abs(diff) < 0.6 then ap.up = true end
		if ap.up then
			local pr = op.prog
			if not pr then pr = {p = vector.copy(pos), t = 0}; op.prog = pr end
			pr.t = pr.t + ctx.dtime
			if vector.distance(pos, pr.p) > 1 then
				op.prog = nil
			elseif pr.t > STUCK_T then
				op.prog = nil
				op.tries = (op.tries or 0) + 1
				if op.tries > STUCK_TRIES then
					op.go = nil
					self.autopilot = {}
					op_say(self, nil)
					radio_tell(op.by, S("Can't get through; stopping here (@1 m short)", ("%d"):format(dist + 0.5)))
					return
				end
				local side = op.tries % 2 == 1 and "left" or "right"
				op.esc = {i = 1, t = 1.5, times = {1.5, 1.2, 2.5}, steps = {{down = true}, {[side] = true}, {up = true}}}
			end
		else
			op.prog = nil
		end
		self.autopilot = ap
		op_say(self, S("Heading to the target (@1 m to go)", ("%d"):format(dist + 0.5)))
	end
	-- 每一步：決定操作員下一個動作（self.autopilot：aux1 + target 挖、jump + dump_truck 倒）
	local function operate(self, ctx)
		local op = self.op
		if self.dig then self.autopilot = {}; return end
		if op.go then op_drive(self, ctx); return end
		op.t = (op.t or 0) - ctx.dtime
		if op.t > 0 then self.autopilot = {}; return end
		op.t = OP_THINK
		local pos = ctx.pos
		if load_total(self) > 0 then
			local truck = op_truck(self, pos)
			op.wait_truck = not truck      -- 綁定的卡車停在搆不到的地方：它看到會重新停車（vehicle_ahs.lua）
			if truck then
				self.autopilot = {jump = true, dump_truck = truck}
				op_say(self, S("Loading the truck"))
			else
				self.autopilot = {}
				op_say(self, S("Bucket full, waiting for a truck"))
			end
			return
		end
		local target = op_target(self, pos, op.cutoff)
		op.wait_truck = false
		op.idle = not target     -- 沒東西可挖：綁定的無人卡車看到就帶著已經裝的先走（vehicle_ahs.lua）
		if target then
			self.autopilot = {aux1 = true, target = target}
			op_say(self, nil)
		else
			self.autopilot = {}
			op.t = OP_IDLE
			op_say(self, S("No rubble with grade ≥ @1% within arm reach", ("%d"):format(op.cutoff * 100 + 0.5)))
		end
	end

	-- 目標周圍 dig_r 格內的欄（離中心近的先）
	local function around(a, y)
		local cells = {}
		for dx = -P.dig_r, P.dig_r do for dz = -P.dig_r, P.dig_r do cells[#cells + 1] = {x = a.x + dx, y = y, z = a.z + dz} end end
		table.sort(cells, function(u, v) return math.abs(u.x - a.x) + math.abs(u.z - a.z) < math.abs(v.x - a.x) + math.abs(v.z - a.z) end)
		return cells
	end

	-- 倒出鏟斗：倒進車斗（裝得下多少倒多少），或倒在指到的那格周圍（之後依安息角攤開）
	local function dump_bucket(self, dg)
		local truck = dg.truck
		if truck and truck.object:get_pos() then
			local room = TYPES[truck.vkind].cap - load_total(truck)
			for base, lv in pairs(self.load) do
				local m = math.min(lv, room)
				if m > 0 then
					V.load_put(truck, base, m, V.load_grade(self, base))
					room = room - m
					V.load_keep(self, base, lv - m)
				end
			end
			if load_total(self) > 0 then self.msg = S("@1 is full", TYPES[truck.vkind].short) end
			V.refresh(truck)
			update_hud(truck)
		elseif dg.target then
			V.dump_to_ground(self, around(dg.target, dg.target.y), dg.target.y + 1)
		end
		update_hud(self)
	end

	-- 挖起目標周圍的碎石（dig_r 格內、上下各 1 層；上層、離中心近的先）
	local function dig_bucket(self, target)
		local want = def.cap - load_total(self)
		local cells = {}
		for dy = 1, -1, -1 do
			for _, c in ipairs(around(target, target.y + dy)) do cells[#cells + 1] = c end
		end
		local got = 0
		for _, c in ipairs(cells) do
			if want <= 0 then break end
			if rockmech.dig_topsoil then rockmech.dig_topsoil(c) end      -- 表土：鏟斗挖鬆了再挖起來
			local t, base, g = V.take_rubble(c, want)
			if t > 0 then
				V.load_put(self, base, t, g)
				want = want - t
				got = got + t
			end
		end
		if got == 0 then
			self.msg = want <= 0 and S("Bucket full, dump it first (Space)") or S("No rubble there (blast the rock first)")
		end
		update_hud(self)
	end

	function def.step(self, ctx)
		-- 挖斗：抬到目標上方 → 往下插進目標（挖／倒）→ 抬回目標上方 → 收回
		if self.dig then
			local dg = self.dig
			dg.t = dg.t + ctx.dtime
			-- 破碎錘：錘頭碰到岩石後停在那裡敲 need 秒（冒岩粉、有敲擊聲），敲完那格變成原地的碎石
			if dg.mode == "break" and not dg.done and dg.t >= DIG_PHASES[1] + DIG_PHASES[2] then
				dg.t = DIG_PHASES[1] + DIG_PHASES[2]
				dg.hold = dg.hold + ctx.dtime
				dg.snd = (dg.snd or 0) - ctx.dtime
				if dg.snd <= 0 then
					dg.snd = 0.25
					V.play(self, "default_dig_cracky", {pos = dg.target, gain = 0.8, max_hear_distance = 32})
					core.add_particlespawner({amount = 8, time = 0.2, minpos = vector.subtract(dg.target, 0.5), maxpos = vector.add(dg.target, 0.5),
						minvel = {x = -1, y = 0, z = -1}, maxvel = {x = 1, y = 2, z = 1}, minacc = {x = 0, y = -9, z = 0}, maxacc = {x = 0, y = -9, z = 0},
						minexptime = 0.3, maxexptime = 0.8, minsize = 1, maxsize = 2, texture = "[fill:4x4:#8a8680"})
				end
				if dg.hold >= dg.need then
					dg.done = true
					local node = core.get_node(dg.target)
					if rockmech.lith_of_node[node.name] then
						local rn, rp = rockmech.rubble_node(node)
						core.remove_node(dg.target)          -- 跟鎬子一樣：先移除（觸發開挖、穩定、應力解），原地留碎石
						if core.get_node(dg.target).name == "air" then core.set_node(dg.target, {name = rn, param2 = rp}) end
					end
					dg.t = DIG_PHASES[1] + DIG_PHASES[2] + 1e-3
				end
			elseif not dg.done and dg.t >= DIG_PHASES[1] + DIG_PHASES[2] then
				dg.done = true
				if dg.mode == "dump" then dump_bucket(self, dg) else dig_bucket(self, dg.target) end
			end
			-- 抬起時上部結構轉向目標；挖完收回時轉回車頭（跟著視線時不轉回），倒完就停在倒的方向
			local to = dg.to
			local above = {x = to.x, y = to.y + P.lift, z = to.z}
			local t, ph = dg.t, DIG_PHASES
			local b
			-- 翻斗：挖 → 抬起時張開、插下去時往駕駛這邊捲（舀起來）；倒 → 到了目標上方往外翻、開口朝下，抬起時收回
			local p1, p2, p3 = ph[1], ph[1] + ph[2], ph[1] + ph[2] + ph[3]
			if dg.mode == "dig" then
				self.curl = t < p1 and CURL_OPEN * t / p1 or t < p2 and CURL_OPEN * (1 - (t - p1) / ph[2]) or 0
			elseif dg.mode == "dump" then
				self.curl = t < p1 and 0 or t < p2 and CURL_DUMP * (t - p1) / ph[2] or t < p3 and CURL_DUMP * (1 - (t - p2) / ph[3]) or 0
			else
				self.curl = 0
			end
			dg.from = dg.from or hold(self)
			-- 倒：從停的位置直接移到倒料點、翻斗倒掉、就停在那裡（不先抬到上方、倒完也不抬起來）
			local stop = dg.mode == "dump" and to or above
			if dg.mode == "dump" then
				if t < ph[1] then
					b = lerp(dg.from, to, t / ph[1])
					self.swing = lerp_angle(dg.psi0, dg.psi, t / ph[1])
				else
					b = to; self.swing = dg.psi
				end
			elseif t < ph[1] then
				b = lerp(dg.from, above, t / ph[1])
				self.swing = lerp_angle(dg.psi0, dg.psi, t / ph[1])
			elseif t < ph[1] + ph[2] then b = lerp(above, to, (t - ph[1]) / ph[2]); self.swing = dg.psi
			elseif t < ph[1] + ph[2] + ph[3] then b = lerp(to, above, (t - ph[1] - ph[2]) / ph[3]); self.swing = dg.psi
			else
				b = above; self.swing = dg.psi          -- 做完：手臂停在目標上方，不收回
			end
			place_arm(self, b)
			if t >= DIG_TOTAL then
				self.dig = nil
				self.swing = dg.psi
				self.hammer_dir = nil
				self.arm_h = stop
				place_arm(self, stop)
			end
		end
		if self.op and self.op.on and not ctx.d then operate(self, ctx) end
		if self.op and self.op.standby and rockmech.op_standby_step then rockmech.op_standby_step(self) end
		-- 駕駛（第一人稱、追蹤視角都一樣）：上部結構轉向視線的水平方向（車身座標的迴轉角 ψ 往右為正，實體 yaw 往左為正）
		local d = ctx.d
		self.follow = d ~= nil
		self.swing_t = math.max(0, (self.swing_t or 0) - ctx.dtime)     -- 迴轉中：引擎算運作（多留一下，滑鼠微動時音量才不會一直跳）
		if self.follow and not self.dig and self.parts then
			local goal = ctx.yaw - d:get_look_horizontal()
			local cur = self.swing or 0
			local diff = (goal - cur + math.pi) % (2 * math.pi) - math.pi
			if math.abs(diff) > 1e-3 then
				local st = P.swing_rate * ctx.dtime
				self.swing = cur + math.max(-st, math.min(st, diff))
				place_arm(self, hold(self))
				if math.abs(diff) > 0.02 then self.swing_t = 0.5 end
			end
		end
	end

	function def.busy(self) return (self.swing_t or 0) > 0 end

	function def.action(self, ctx)
		local ctrl, d, pos = ctx.ctrl, ctx.d, ctx.pos
		-- 破碎錘（只有人開的時候；操作員照舊用鏟斗）：E 敲碎滑鼠指的那格岩石；空白鍵換回鏟斗
		if d and self.tool == "breaker" then
			if ctrl.jump and not self.dig then
				self.tool, self.t_act = "bucket", 0.6
				show_tool(self); self.msg = S("Switched to bucket"); update_hud(self)
			elseif ctrl.aux1 and not self.dig then
				self.t_act = DIG_TOTAL + 0.1
				local hit = aim(self, d, pos, false)
				local target = hit and hit.under
				local lith = target and rockmech.lith_of_node[core.get_node(target).name]
				if not lith then
					self.msg = S("Point the breaker at rock")
				else
					-- 上面是空的：錘子垂直站在岩塊上方，鋼鑿尖碰頂面；上面不空（敲牆面）：從瞄到的那一面外側，45° 往下指著那一面
					local up = {x = target.x, y = target.y + 1, z = target.z}
					local n = vector.subtract(hit.above, hit.under)
					local contact, wdir
					if V.passable(core.get_node(up).name) or n.y == 1 then
						contact, wdir = {x = target.x, y = target.y + 0.5, z = target.z}, {x = 0, y = -1, z = 0}
					else
						if n.y ~= 0 then n = {x = 0, y = 0, z = 1} end    -- 從下面瞄到底面：當成正面
						contact = vector.add(target, vector.multiply(n, 0.5))
						wdir = vector.normalize({x = -n.x, y = -1, z = -n.z})
					end
					local cv, dv = to_local(self, contact), vector.subtract(to_local(self, vector.add(contact, wdir)), to_local(self, contact))
					local top = vector.subtract(cv, vector.multiply(dv, HAMMER.y + CHISEL.y))
					local psi, th, reach = swing_to(top)
					self.hammer_dir = dv
					if reach > ARM_REACH then
						self.hammer_dir = nil
						self.msg = S("Out of arm reach (@1 m, arm about @2 m)", ("%.1f"):format(reach), ("%.1f"):format(ARM_REACH))
					else
						local ucs = (rockmech.cfg.lithologies[lith.name] or {}).ucs or 30
						self.dig = {t = 0, mode = "break", target = target, to = th, psi = psi, psi0 = self.swing or 0,
							need = ucs * rockmech.cfg.breaker_rate / (P.breaker_power or 1), hold = 0}   -- 大的破碎錘打擊能量大，敲得快
						self.msg = S("Breaking rock (UCS @1 MPa, about @2 s)", ("%d"):format(ucs), ("%.1f"):format(self.dig.need))
					end
				end
				update_hud(self)
			end
			return
		end
		-- 鏟斗空的、裝了破碎錘：空白鍵換成破碎錘
		if d and self.breaker and ctrl.jump and not self.dig and load_total(self) == 0 then
			self.tool, self.t_act = "breaker", 0.6
			show_tool(self); self.msg = S("Switched to breaker: point at rock and press E to break it"); update_hud(self)
			return
		end
		if ctrl.aux1 and not self.dig then
			self.t_act = DIG_TOTAL + 0.1
			-- 滑鼠指的方塊：從相機沿視線找第一個方塊。沒人駕駛時 ctrl 就是這一步開始時的 self.autopilot
			-- （用 ctrl，不用 self.autopilot：操作員在 def.step 裡已經換成下一步的指令了）
			local target = ctrl.target
			if d then
				local hit = aim(self, d, pos, false)
				target = hit and hit.under
			end
			local tl = target and to_local(self, target)
			local psi, th, reach
			if tl then psi, th, reach = swing_to(tl) end
			if tl and reach > ARM_REACH then
				self.msg = S("Out of arm reach (@1 m, arm about @2 m)", ("%.1f"):format(reach), ("%.1f"):format(ARM_REACH))
			elseif target then
				self.dig = {t = 0, mode = "dig", target = target, to = th, psi = psi, psi0 = self.swing or 0}
				self.msg = nil
			else
				self.msg = S("Bucket can't reach (no block within @1 m)", ("%d"):format(P.dig_reach))
			end
			update_hud(self)
		elseif ctrl.jump and load_total(self) > 0 and not self.dig then
			self.t_act = DIG_TOTAL + 0.1
			local hit
			if d then hit = aim(self, d, pos, true)
			else
				local t = ctrl.dump_target
				hit = ctrl.dump_truck and {truck = ctrl.dump_truck}
					or t and {above = {x = t.x, y = t.y + 1, z = t.z}}
			end
			local dg
			if hit and hit.truck then
				dg = {t = 0, mode = "dump", truck = hit.truck, to = to_local(self, V.bed_target(hit.truck, pos))}
			elseif hit and hit.above then
				local a = hit.above
				dg = {t = 0, mode = "dump", target = a, to = to_local(self, {x = a.x, y = a.y + 0.8, z = a.z})}
			elseif d then
				-- 範圍內沒有指到方塊：沿視線取遠處一點，下面抓最遠距離倒
				dg = {t = 0, mode = "dump", to = to_local(self, vector.add(pos, vector.multiply(d:get_look_dir(), 40)))}
			end
			local reach
			if dg then
				dg.psi, dg.to, reach = swing_to(dg.to)
				dg.psi0 = self.swing or 0
				if reach > ARM_REACH and dg.truck then
					self.msg = S("Can't reach the truck bed (@1 m, arm about @2 m)", ("%.1f"):format(reach), ("%.1f"):format(ARM_REACH))
				else
					if reach > ARM_REACH then
						-- 超出手臂範圍：挖斗伸到同一方向最遠處，倒在那一點正下方
						local k = (ARM_REACH - 0.2) / reach
						local b = {x = BOOM_ROOT.x + (dg.to.x - BOOM_ROOT.x) * k, y = BOOM_ROOT.y + (dg.to.y - BOOM_ROOT.y) * k,
							z = BOOM_ROOT.z + (dg.to.z - BOOM_ROOT.z) * k}
						dg.to = b
						dg.target = vector.round(V.to_world(self, h2v(b, dg.psi)))
						self.msg = S("Out of arm reach; dumping at the farthest point (about @1 m)", ("%.1f"):format(ARM_REACH))
					else
						self.msg = nil
					end
					self.dig = dg
				end
			else
				self.msg = S("Dump where? (no block or truck within @1 m)", ("%d"):format(P.dig_reach))
			end
			update_hud(self)
		end
	end

	V.register(kind, def)
end

-- 挖土機：3×3×3，兩側半格寬履帶、下車架、2×2×2 駕駛艙（偏後）、前方動臂與鏟斗（鏟斗可伸出碰撞箱，只是外觀）
do
	-- 履帶很慢（真實約 3–5 km/h）：長距離用平板拖車載（vehicle_lowboy.lua）
	local def = {desc = S("Excavator"), color = "#e0a020", cap = 4 * NLEV, speed = 1.4,
		half = 1.5, lat = {-1, 0, 1}, eye_up = 1.65, eye_fwd = 0.6, mirror = {x = 1.15, y = 1.3, z = 0.4},
		seat = {x = -0.3, y = 0.0, z = -0.2},     -- 駕駛室偏左（駕駛室靠近迴轉軸，上部結構轉了也差不多在裡面）
		tilt = {front = 1.3, rear = -1.3, side_z = 0, side_x = 1.25}, max_grade = math.rad(35),   -- 履帶挖土機約 70%
		item_desc = S("Right-click to get in; E digs, Space dumps")}
	def.inv_image = excavator_icon(def.color, false)
	local grille_s = ("[fill:16x16:%s^[fill:10x6:3,4:#2a2a2a^[fill:10x1:3,6:#4a4a4a^[fill:10x1:3,8:#4a4a4a"):format(def.color)
	excavator("excavator", {
		def = def,
		body = {
			{pos = {x = -1.25, y = -1.0, z = 0}, size = {x = 0.5, y = 1.0, z = 3.0}, tex = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}},
			{pos = {x = 1.25, y = -1.0, z = 0}, size = {x = 0.5, y = 1.0, z = 3.0}, tex = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}},
			{pos = {x = 0, y = -1.0, z = 0}, size = {x = 2.0, y = 1.0, z = 2.6}, tex = box_tex("#3a3a3a")},
		},
		house = {
			{id = "cab", pos = {x = 0, y = 0.5, z = -0.1}, size = {x = 2.0, y = 2.0, z = 1.2}, tex = cab_tex(def.color, 10, true), alpha = true},
			-- 後側：比駕駛艙矮的引擎室（兩側百葉）、排氣管
			{id = "engine", pos = {x = 0, y = 0.0, z = -1.1}, size = {x = 2.0, y = 1.0, z = 0.8},
				tex = {("[fill:16x16:%s"):format(def.color), "[fill:16x16:#2a2a2a", grille_s, grille_s,
					("[fill:16x16:%s"):format(def.color), ("[fill:16x16:%s"):format(def.color)}},
			{id = "stack", pos = {x = 0.6, y = 0.85, z = -1.2}, size = {x = 0.14, y = 0.7, z = 0.14}, tex = box_tex("#202020")},   -- 排氣管
		},
		boom_root = {x = 0.55, y = 0.3, z = 0.7},        -- 駕駛艙前方（駕駛的右手邊）
		bucket_rest = {x = 0.55, y = -0.9, z = 2.6},     -- 收起時挖斗在車頭前方約 1.1 m
		boom_len = 3.6, stick_len = 3.0, boom_w = 0.5, stick_w = 0.4,
		bucket = {x = 1.3, y = 0.8, z = 0.7}, bucket_color = "#505050",
		op_seat = {x = -0.3, y = 0.0, z = -0.2},          -- 駕駛室裡（上部結構座標）
		bucket_real = {x = 1.25, y = 1.1, z = 1.4},      -- 20 t 級、約 1 m³：寬 1.25、斗高 1.1、斗深 1.4，接點到齒尖約 1.45 m
		dig_r = 1, dig_reach = 10, lift = 2.0, swing_rate = 1.5, dump_reach = 6,

	})
end

-- 礦用挖土機（反鏟，200 t 級）：7 寬 × 7 高（碰撞箱 7×7×7，車底 y −3.5）。履帶 7 m、下車架；
-- 上部結構：大機艙（往後伸出配重）、左前方駕駛室（駕駛的視角在這裡，動臂在正中央不擋視線）；
-- 手臂：動臂 8.2 m＋斗桿 5 m（從車身中心搆得到約 15 m）；鏟斗 12 m³（礦卡 3 斗）
do
	local def = {desc = S("Mining excavator"), color = "#e8a818", cap = 12 * NLEV, speed = 1.0,
		half = 3.5, lat = {-3, -2, -1, 0, 1, 2, 3}, eye_up = 2.85, eye_fwd = 2.4, eye_side = -1.6,
		mirror = {x = 2.8, y = 2.4, z = 1.6},
		tilt = {front = 3.0, rear = -3.0, side_z = 0, side_x = 2.6}, max_grade = math.rad(35),
		item_desc = S("Right-click to get in; E digs, Space dumps")}
	def.inv_image = excavator_icon(def.color, true)
	local c = def.color
	local y = ("[fill:16x16:%s"):format(c)
	local grille = ("[fill:16x16:%s^[fill:12x6:2,5:#2a2a2a^[fill:12x1:2,7:#4a4a4a^[fill:12x1:2,9:#4a4a4a"):format(c)
	local BIG_TRACK = "[fill:16x16:#262626^[fill:16x2:0,0:#454545^[fill:16x2:0,14:#454545^[fill:2x12:2,2:#363636^[fill:2x12:7,2:#363636^[fill:2x12:12,2:#363636"
	local trk = {BIG_TRACK, BIG_TRACK, BIG_TRACK, BIG_TRACK, BIG_TRACK, BIG_TRACK}
	V.track_tex[BIG_TRACK] = 4
	excavator("excavator_big", {
		def = def,
		body = {
			{pos = {x = -2.6, y = -2.7, z = 0}, size = {x = 1.6, y = 1.6, z = 7.0}, tex = trk},
			{pos = {x = 2.6, y = -2.7, z = 0}, size = {x = 1.6, y = 1.6, z = 7.0}, tex = trk},
			{pos = {x = 0, y = -2.4, z = 0}, size = {x = 3.6, y = 1.6, z = 5.0}, tex = box_tex("#3a3a3a")},   -- 下車架
		},
		house = {
			{id = "house", pos = {x = 0, y = -0.6, z = -0.8}, size = {x = 5.4, y = 2.2, z = 6.0}, tex = {y, "[fill:16x16:#2a2a2a", grille, grille, y, y}},
			{id = "cw", pos = {x = 0, y = -0.9, z = -4.1}, size = {x = 5.0, y = 1.6, z = 0.8}, tex = box_tex("#b88a10")},   -- 配重
			{id = "cab", pos = {x = -1.6, y = 1.6, z = 1.4}, size = {x = 2.0, y = 2.2, z = 1.8}, tex = cab_tex(c, 9, true), alpha = true},
			{id = "stack", pos = {x = 1.6, y = 1.0, z = -2.5}, size = {x = 0.3, y = 1.0, z = 0.3}, tex = box_tex("#202020")},   -- 排氣管
		},
		boom_root = {x = 0.5, y = 0.2, z = 2.0},
		bucket_rest = {x = 0.5, y = -2.1, z = 6.5},      -- 收起時挖斗在車頭前方，斗底離地約 10 cm（斗高 2.5 m）
		boom_len = 8.2, stick_len = 5.0, boom_w = 1.1, stick_w = 0.9,
		bucket = {x = 2.8, y = 2.0, z = 1.8}, bucket_color = "#4a4a4a",
		op_seat = {x = -1.6, y = 0.6, z = 1.3},           -- 左前方的駕駛室裡
		breaker_power = 4,                               -- 破碎錘打擊能量約是 20 t 級的 4 倍：同樣的岩石 1/4 時間
		bucket_real = {x = 3.2, y = 2.5, z = 2.8},       -- 200 t 級、約 12 m³：寬 3.2、斗高 2.5、斗深 2.8，接點到齒尖約 2.9 m
		dig_r = 2, dig_reach = 18, lift = 3.5, swing_rate = 0.8, dump_reach = 9,

		body_box = {x0 = -3.5, x1 = 3.5, z0 = -3.5, z1 = 3.5, y0 = -3.5, y1 = 3.0},
	})
end
