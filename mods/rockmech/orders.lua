-- rockmech/orders.lua
-- 訂單：電廠的採購員在營地裡走來走去，找他接訂單（○ 噸、品位 ≥ ○ %、○ 天內交完、每噸 $○，接單時鎖價）。
-- 接了單，電廠的收料車開到營地南邊外側的收料區停在地磅上等裝料（跟破碎站完全分開）：
--   卡車、手推車在車斗旁邊倒料（自動對準車斗）、怪手直接裝進車斗、裝車料斗＋輸送帶也可以。
--   裝滿（或按收料車叫它先走）→ 取樣驗品位：達標照合約價付款、車開走，SECS_NEXT 秒後下一台來；
--   不達標整車退貨：料倒回地磅後面，扣退貨運費，同一台車留著重裝。
--   交完就結案；到期沒交完，沒交的部分 × 單價 × PENALTY 罰款。中途取消也一樣罰。
-- 營地的混凝土地坪（也在這裡）：建築區（講堂、研究帳篷、貨櫃辦公室、長椅的外框）、交車區、收料區鋪混凝土，
--   地坪上不能放東西、建築和地面挖不掉，往下 UNDER m 內也不能挖（碎石、自己放的置物櫃這類還是拿得走）；
--   有 rockmech 權限（老師）的人不受限。新蓋的營地一起鋪，舊的營地補鋪。

local S = rockmech.S
local cfg = rockmech.cfg
local V = rockmech.vehicles
local NLEV = V.NLEV
local storage = rockmech.collapse.storage
local F = core.formspec_escape

---------------------------------------------------------------------------
-- 營地的位置
---------------------------------------------------------------------------

-- 地坪範圍（x 相對營地中心 x0，z 是絕對座標）；line：邊上一圈黃色外框
--   建築區：講堂、研究帳篷、貨櫃辦公室、長椅的外框再外推 2 m
--   交車區：delivery.lua 的 YARD（有東西擋著就不交車）
--   收料區：營地南邊外側、礦帶之間的平地走廊上（卡車從礦區往南開就到）。只鋪收料車加地磅那一條（7 m 寬），
--     兩側不鋪：自己放裝車料斗（放料臂 10 m）、接輸送帶裝進收料車
local PADS = {{x1 = 11, x2 = 32, z1 = -33, z2 = -1},
	{x1 = 10, x2 = 36, z1 = -54, z2 = -36, line = true},
	{x1 = -17, x2 = -11, z1 = -72, z2 = -59, line = true}}
-- 舊版鋪過的範圍（第一版整個南半部；之後的收料區在 z −50..−34、交車區到 z −34）：在新範圍外的換回表土
local OLD_PADS = {{x1 = -21, x2 = 33, z1 = -56, z2 = -1}, {x1 = 10, x2 = 36, z1 = -56, z2 = -34}}
local UNDER = 10                         -- 地坪下幾公尺內不能挖
-- 收料車：停在地磅上，車頭朝北；車身原點（駕駛艙中心）的位置
local BAY = {x = -14, z = -62}
local SCALE = {x1 = -15, x2 = -13, z1 = -69, z2 = -61}     -- 地磅鋼板
local CONCRETE = "rockmech:camp_concrete"
local SCALE_NODE = "rockmech:camp_scale"
local LINE = "rockmech:camp_concrete_line"           -- 黃色外框

local function sites()
	local out = {}
	if storage:get_string("career_site") == "2" then out[#out + 1] = cfg.career_camp_dx end
	if rockmech.team_site_x then
		for i = 1, cfg.career_teams or 0 do
			if storage:get_string("team_site:" .. i) == "1" then out[#out + 1] = rockmech.team_site_x(tostring(i)) end
		end
	end
	return out
end
-- 帳戶的營地：分組是那一組的營地；單人地圖是唯一那座
local function site_of(acc)
	local t = acc:match("^team:(%d+)$")
	if t and rockmech.team_site_x and storage:get_string("team_site:" .. t) == "1" then return rockmech.team_site_x(t) end
	if storage:get_string("career_site") == "2" then return cfg.career_camp_dx end
end
local function sy() return math.floor(cfg.surface_y or 0) end
local function in_rect(x0, r, x, z) return x >= x0 + r.x1 and x <= x0 + r.x2 and z >= r.z1 and z <= r.z2 end
local function in_pad(x0, pos)
	for _, r in ipairs(PADS) do if in_rect(x0, r, pos.x, pos.z) then return true end end
	return false
end
-- (x, z) 地面最上面那格的 y（走得上去的方塊）
local function ground_y(x, z)
	for y = sy() + 8, sy() - 6, -1 do
		local n = core.get_node({x = x, y = y, z = z}).name
		if n == "ignore" then return nil end
		local d = core.registered_nodes[n]
		if n ~= "air" and d and d.walkable ~= false and not n:find("leaves") then return y end
	end
end

---------------------------------------------------------------------------
-- 方塊：混凝土地坪、地磅
---------------------------------------------------------------------------

local function noop() end
core.register_node(CONCRETE, {
	description = S("Concrete slab"),
	tiles = {"[fill:16x16:#a8a49c^[fill:16x1:0,0:#96928a^[fill:1x16:0,0:#96928a^[fill:2x1:5,6:#b8b4ac^[fill:1x1:11,11:#8e8a82"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
core.register_node(LINE, {
	description = S("Painted line"),
	tiles = {"[fill:16x16:#e0b428^[fill:16x1:0,0:#c89c20^[fill:3x1:4,9:#f0cc58^[fill:1x1:12,4:#b8901c",
		"[fill:16x16:#a8a49c^[fill:16x1:0,0:#96928a"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
core.register_node(SCALE_NODE, {
	description = S("Weighbridge"),
	tiles = {"[fill:16x16:#5a5e64^[fill:16x1:0,7:#3a3e44^[fill:1x16:7,0:#3a3e44^[fill:2x2:2,2:#7a7e84^[fill:2x2:12,12:#7a7e84"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})

-- 地面方塊（表土、土、岩石）才鋪；建築的地板、家具、樹、玩家放的東西不動
local function pavable(n)
	if n == "air" or n == "ignore" then return false end
	if n:find("^rockmech:office_") or n:find("^rockmech:camp_") or n:find("^rockmech:tent_") or n:find("^rockmech:sign_") then return false end
	local d = core.registered_nodes[n]
	local g = d and d.groups or {}
	return (g.soil or g.crumbly or g.cracky or g.rockmech_topsoil) and not n:find("leaves") and not n:find("tree")
		and not rockmech.rubble_level[n] or rockmech.rubble_base and rockmech.rubble_base[n] == rockmech.RUBBLE_SOIL
end
-- 鋪地坪；舊版鋪過的（pad:x0 = 1、沒有 pad3）先把新範圍外面的混凝土換回表土
local TOPSOIL = "rockmech:topsoil"
local function pave(x0)
	local base = sy()
	if storage:get_string("pad:" .. x0) == "1" then
		local n = 0
		for _, o in ipairs(OLD_PADS) do for x = x0 + o.x1, x0 + o.x2 do
			for z = o.z1, o.z2 do
				if not in_pad(x0, {x = x, z = z}) then
					for y = base - 1, base + 2 do
						local p = {x = x, y = y, z = z}
						local nn = core.get_node(p).name
						if nn == CONCRETE or nn == SCALE_NODE or nn == LINE then core.set_node(p, {name = TOPSOIL}); n = n + 1 end
					end
				end
			end
		end end
		core.log("action", ("[rockmech] 營地 x = %d 地坪縮小：%d 格混凝土換回表土"):format(x0, n))
	end
	-- 每一欄往下找地面那一層：上面有椅子、長椅、樹、看板也照鋪（擺設留在地坪上）；
	-- 碰到建築的地板或已經鋪好的就停（地板就是建築自己的地面）
	local PAD_NODE = {[CONCRETE] = true, [SCALE_NODE] = true, [LINE] = true}
	for _, r in ipairs(PADS) do
		for x = x0 + r.x1, x0 + r.x2 do
			for z = r.z1, r.z2 do
				local want = in_rect(x0, SCALE, x, z) and SCALE_NODE
					or r.line and (x == x0 + r.x1 or x == x0 + r.x2 or z == r.z1 or z == r.z2) and LINE or CONCRETE
				for y = base + 2, base - 1, -1 do
					local p = {x = x, y = y, z = z}
					local n = core.get_node(p).name
					if n == "ignore" or n == want or n:find("floor") then break end
					if PAD_NODE[n] or pavable(n) then core.set_node(p, {name = want}); break end
				end
			end
		end
	end
	storage:set_string("pad:" .. x0, "1")
	storage:set_string("pad6:" .. x0, "1")
	core.log("action", ("[rockmech] 營地 x = %d 鋪好混凝土地坪、收料區"):format(x0))
end
local function done(x0) return storage:get_string("pad6:" .. x0) == "1" end
local function pave_when_loaded(x0)
	local a, b = {x = math.huge, y = sy() - 8, z = math.huge}, {x = -math.huge, y = sy() + 10, z = -math.huge}
	for _, list in ipairs({PADS, OLD_PADS}) do
		for _, r in ipairs(list) do
			a.x, a.z = math.min(a.x, x0 + r.x1), math.min(a.z, r.z1)
			b.x, b.z = math.max(b.x, x0 + r.x2), math.max(b.z, r.z2)
		end
	end
	core.emerge_area(a, b, function(_, _, rem)
		if rem > 0 or done(x0) then return end
		local col = rockmech.collapse
		col.quiet = col.quiet + 1
		local ok, err = pcall(pave, x0)
		col.quiet = col.quiet - 1
		if not ok then core.log("error", "[rockmech] pave: " .. tostring(err)) end
	end)
end
-- 新蓋的營地：career.lua 蓋營地時整地完先鋪（rockmech.camp_pave），建築、擺設再蓋在地坪上；
-- 舊的營地開服 4 秒後補鋪（或縮小）
function rockmech.camp_pave(x0) if not done(x0) then pave(x0) end end
core.after(4, function()
	for _, x0 in ipairs(sites()) do
		if not done(x0) then pave_when_loaded(x0) end
	end
end)

-- 保護：地坪範圍、地坪下 UNDER m 到上方 40 m。碎石隨時可以清；地面以上玩家自己放的東西（置物櫃…）拿得走
local BUILT = {"^rockmech:office_", "^rockmech:camp_", "^rockmech:tent_", "^rockmech:sign_", "^doors:", "^default:glass$", "^stairs:"}
local function pad_protected(pos, name)
	if not cfg.career then return false end
	local base = sy()
	if pos.y < base - UNDER or pos.y > base + 40 then return false end
	local x0
	for _, s in ipairs(sites()) do
		if storage:get_string("pad:" .. s) == "1" and in_pad(s, pos) then x0 = s; break end
	end
	if not x0 then return false end
	if name and name ~= "" and core.check_player_privs(name, {rockmech = true}) then return false end
	local n = core.get_node(pos).name
	if rockmech.rubble_level[n] then return false end
	if n == "air" then return true end                     -- 放東西（放進空格）
	if pos.y <= base + 1 then return true end              -- 地坪、地面、地下
	for _, pat in ipairs(BUILT) do if n:find(pat) then return true end end
	return false
end
rockmech.pad_protected = pad_protected
local old_protected = core.is_protected
function core.is_protected(pos, name)
	if pad_protected(pos, name) then return true end
	return old_protected(pos, name)
end
local last_warn = {}
core.register_on_protection_violation(function(pos, name)
	if not pad_protected(pos, name) then return end
	local now = core.get_us_time()
	if last_warn[name] and now - last_warn[name] < 3e6 then return end
	last_warn[name] = now
	rockmech.notify(name, S("Concrete slab: nothing can be built or dug here"))
end)

---------------------------------------------------------------------------
-- 訂單
---------------------------------------------------------------------------

local ORDER = "order:"            -- 帳戶 → 進行中的訂單（serialize）
local CAP_M3 = 8                  -- 收料車一車幾 m³
local SECS_NEXT = 60              -- 一車開走後下一台多久來
local PENALTY = 0.3               -- 違約金：沒交的 × 單價 × 這個比例
local REJECT_FEE = 20             -- 退貨運費（每噸）
local DENSITY = function() return cfg.rubble_density or 2.5 end
local function tons_of(lv) return lv / NLEV * DENSITY() end
local CAP_T = function() return tons_of(CAP_M3 * NLEV) end
local money_text = function(v) return rockmech.money_text and rockmech.money_text(v) or ("$%.0f"):format(v) end

local function get_order(acc)
	local s = storage:get_string(ORDER .. acc)
	return s ~= "" and core.deserialize(s) or nil
end
local function set_order(acc, o) storage:set_string(ORDER .. acc, o and core.serialize(o) or "") end
local function today() return rockmech.market_day() end
local function tell(acc, msg)
	for _, m in ipairs(rockmech.account_members(acc)) do rockmech.notify(m, S("[Order] @1", msg)) end
end
local function pct(g) return ("%.0f%%"):format(g * 100) end
local function t1(t) return ("%.1f t"):format(t) end

-- 今天的 3 張訂單（同一天同一組都一樣；鎖的單價照今天的煤價）
local SIZES = {{tons = 40, days = 2}, {tons = 60, days = 3}, {tons = 100, days = 5}}
local SPECS = {0.60, 0.70, 0.80}
local function offers(acc)
	local ore = cfg.ores.coal
	if not ore then return {} end
	local d = today()
	local seed = d * 7919
	for i = 1, #acc do seed = (seed * 31 + acc:byte(i)) % 2147483647 end
	local r = PcgRandom(seed)
	local list = {}
	for i, sz in ipairs(SIZES) do
		local spec = SPECS[r:next(1, #SPECS)]
		local premium = 1.15 + r:next(0, 20) / 100
		list[i] = {tons = sz.tons, days = sz.days, spec = spec,
			price = math.floor(rockmech.ore_price(ore) * spec * premium + 0.5)}
	end
	return list
end

local function accept(acc, o)
	set_order(acc, {tons = o.tons, spec = o.spec, price = o.price, due = today() + o.days, done = 0, paid = 0,
		loads = 0, rejected = 0, next_t = 0})
	tell(acc, S("Accepted: @1 t, grade ≥ @2, @3 days, $@4/t. The pickup truck is on its way to the receiving area",
		o.tons, pct(o.spec), o.days, o.price))
end

-- 結案：交完、到期、取消。收料車收走
local trucks = {}                 -- 帳戶 → 收料車 entity（載入中的）
local function close(acc, o, why)
	local left = math.max(0, o.tons - o.done)
	local fine = math.floor(left * o.price * PENALTY + 0.5)
	if fine > 0 then rockmech.add_money(acc, -fine) end
	set_order(acc, nil)
	local e = trucks[acc]
	if e and e.object:get_pos() then
		V.registry_drop(e.uid); V.snapshot_clear(e.uid)
		e.object:remove()
	end
	trucks[acc] = nil
	local rows = {
		{S("Delivered"), t1(o.done), "", money_text(o.paid), 0x80ff80},
		{S("Penalty"), t1(left), ("$%d × %d%%"):format(o.price, PENALTY * 100), money_text(-fine), 0xff8080},
		{S("Total"), "", "", money_text(o.paid - fine), o.paid - fine >= 0 and 0x80ff80 or 0xff8080},
	}
	if why == "done" then tell(acc, S("Order complete: @1 delivered, received @2", t1(o.done), money_text(o.paid)))
	elseif why == "late" then tell(acc, S("Order expired: @1 short, penalty @2", t1(left), money_text(-fine)))
	else tell(acc, S("Order cancelled: @1 short, penalty @2", t1(left), money_text(-fine))) end
	for _, m in ipairs(rockmech.account_members(acc)) do
		if rockmech.show_bill then rockmech.show_bill(m, S("Order statement"), rows) end
	end
end

---------------------------------------------------------------------------
-- 收料車：有車斗的車（vehicle_truck.lua 的 hauler），不能開，怪手裝得進去
---------------------------------------------------------------------------

local KIND = "receiver"
local ENAME = "rockmech:" .. KIND
do
	local box_tex = V.box_tex
	local c = "#e8e8e0"                          -- 白色車身、綠色車斗
	local bedc = "#2f7a46"
	local truck = {desc = S("Pickup truck"), short = S("Pickup truck"), color = c, cap = CAP_M3 * NLEV, speed = 0,
		top_speed = 0, accel = 0, tire = 1.0, no_ahs = true,
		half = 1.5, lat = {-1, 0, 1}, eye_up = 1.9, eye_fwd = 1.6, eye_side = -0.55, rear = 5.5, mirror = {x = 1.35, y = 1.3, z = 1.2},
		seat = {x = -0.55, y = 0.1, z = 0.6}, tilt = {front = 0.5, rear = -3.8, side_z = -1.6, side_x = 1.1},
		max_grade = math.rad(17), item_desc = ""}
	local r = {}
	r[#r + 1] = {2, 12, 19, 10, bedc}; r[#r + 1] = {22, 11, 8, 12, c}; r[#r + 1] = {24, 13, 5, 5, "#9fd0ff"}
	V.icon_wheel(r, 26, 26, 3); V.icon_wheel(r, 7, 26, 3); V.icon_wheel(r, 14, 26, 3)
	truck.inv_image = V.icon(r)
	local cab_front = V.cab_glass(c, 2, 2, 12, 6) .. "^[fill:4x2:2,12:#f0e070^[fill:4x2:10,12:#f0e070"
	local cab_side = V.cab_side(c, {win = {x = 8, y = 2, w = 6, h = 6}, clear = true, doors = {{x = 6.5, y = 1, w = 8.5, h = 12.5}}})
		.. "^[fill:16x2:0,13:#2f7a46"
	local wheel = {V.TREAD, V.TREAD, V.WHEEL, V.WHEEL, V.TREAD, V.TREAD}
	local body = {
		{pos = {x = 0, y = -0.55, z = -2.0}, size = {x = 1.6, y = 0.3, z = 6.6}, tex = box_tex("#2a2a2a")},
		{pos = {x = 0, y = 0.6, z = 0.5}, size = {x = 2.4, y = 2.0, z = 2.0}, alpha = true,
			tex = {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", cab_side, V.flip_side(cab_side), cab_front, ("[fill:16x16:%s"):format(c)}},
		{pos = {x = 0, y = 0.6, z = -0.46}, size = {x = 2.36, y = 1.96, z = 0.04}, tex = box_tex(c)},
	}
	for _, w in ipairs({{x = -1.15, z = 0.5, wd = 0.35}, {x = 1.15, z = 0.5, wd = 0.35},
			{x = -1.1, z = -3.2, wd = 0.6}, {x = 1.1, z = -3.2, wd = 0.6}, {x = -1.1, z = -4.4, wd = 0.6}, {x = 1.1, z = -4.4, wd = 0.6}}) do
		body[#body + 1] = {pos = {x = w.x, y = -1.0, z = w.z}, size = {x = w.wd, y = 1.0, z = 1.0}, tex = wheel}
	end
	V.hauler(truck, {
		hinge = {x = 0, y = -0.4, z = -5.5}, size = {x = 2.6, y = 1.2, z = 4.8}, body = body,
		floor_tex = "[fill:16x16:#1f4a2c",
		side_tex = ("[fill:16x16:%s^[fill:16x2:0,0:#1f5a32^[fill:2x16:4,0:#3a9a58^[fill:2x16:10,0:#3a9a58"):format(bedc),
		overlap_lat = {-1.25, 0, 1.25}, overlap_dy = {1.2, 2.2}, aim_top = 1.0,
	})
	truck.overhangs = {{x0 = -1.3, x1 = 1.3, z0 = -5.5, z1 = -1.5, y0 = -1.5, y1 = 0.8, body = "z1"}}
	-- 不能開、不能裝東西：右鍵看這一車的狀況（可以叫它先走）
	truck.rightclick = function(self, clicker)
		if rockmech.orders_truck_form then rockmech.orders_truck_form(self, clicker) end
		return true
	end
	-- 名牌：載了幾噸（不顯示品位：要自己判讀）
	local refresh = truck.refresh
	truck.refresh = function(self)
		refresh(self)
		V.nametag(self, S("Pickup truck  @1 / @2", t1(tons_of(V.load_total(self))), t1(CAP_T())),
			V.load_total(self) >= truck.cap and "#ff8060" or "#a0ffb0")
	end
	-- 存檔讀回來：已經不是這組現在的收料車（訂單結了、換了一台）就自己消失
	local on_load = truck.on_load
	truck.on_load = function(self, data)
		if on_load then on_load(self, data) end
		core.after(0, function()
			if not self.object:get_pos() then return end
			local o = self.owner and get_order(self.owner)
			if not (o and o.truck == self.uid) then
				V.registry_drop(self.uid); V.snapshot_clear(self.uid)
				self.object:remove()
				return
			end
			trucks[self.owner] = self
		end)
	end
	V.register(KIND, truck)
	core.override_item(ENAME .. "_item", {groups = {not_in_creative_inventory = 1}})
end

local function truck_of(acc)
	local e = trucks[acc]
	if e and e.object:get_pos() then return e end
	trucks[acc] = nil
end

local function bay_pos(x0)
	local gy = ground_y(x0 + BAY.x, BAY.z)
	if not gy then return nil end
	return {x = x0 + BAY.x + 0.5, y = gy + 0.5 + 1.5, z = BAY.z + 0.5}
end
local function spawn_truck(acc, o)
	local x0 = site_of(acc)
	local p = x0 and bay_pos(x0)
	if not p then return end
	local obj = core.add_entity(p, ENAME)
	local e = obj and obj:get_luaentity()
	if not e then return end
	obj:set_yaw(0)
	V.set_owner(e, acc)
	o.truck = e.uid
	set_order(acc, o)
	trucks[acc] = e
	core.sound_play("rockmech_engine", {pos = p, gain = 0.6, max_hear_distance = 40}, true)
	tell(acc, S("The pickup truck is at the receiving area"))
end

-- 料的總量、品位（礦石的 param2 加權）
local function load_grade(e)
	local total, q = 0, 0
	for base, lv in pairs(e.load) do
		total = total + lv
		if rockmech.ore_of_rubble[base] then q = q + (e.loadq[base] or 0) end
	end
	return total, total > 0 and q / total / 255 or 0
end

-- 驗收（滿了，或叫它先走）
local function weigh(acc, e)
	local o = get_order(acc)
	if not o then return end
	local lv, g = load_grade(e)
	if lv <= 0 then return end
	local t = tons_of(lv)
	local members = rockmech.account_members(acc)
	if g + 1e-6 < o.spec then
		-- 退貨：料倒在車尾（地磅後面），扣運費，這台留著重裝
		local fee = math.floor(t * REJECT_FEE + 0.5)
		rockmech.add_money(acc, -fee)
		o.rejected = o.rejected + 1
		set_order(acc, o)
		e.t_act = 3; e.tip = {t = 0}
		tell(acc, S("Rejected: grade @1 is below @2. The load was dumped back, freight @3", pct(g), pct(o.spec), money_text(-fee)))
		for _, m in ipairs(members) do
			if rockmech.show_bill then
				rockmech.show_bill(m, S("Pickup truck #@1", o.loads + o.rejected), {
					{S("Rejected  grade @1", pct(g)), t1(t), "", "", 0xffffff},
					{S("Return freight"), t1(t), ("$%d"):format(REJECT_FEE), money_text(-fee), 0xff8080}})
			end
		end
		return
	end
	-- 收貨：超過訂單量的部分不付錢
	local pay_t = math.min(t, o.tons - o.done)
	local pay = math.floor(pay_t * o.price + 0.5)
	rockmech.add_money(acc, pay)
	for _, m in ipairs(members) do core.sound_play("rockmech_coin", {to_player = m, gain = 0.8}, true) end
	o.done, o.paid, o.loads = o.done + pay_t, o.paid + pay, o.loads + 1
	o.truck, o.next_t = nil, core.get_gametime() + SECS_NEXT
	set_order(acc, o)
	for _, m in ipairs(members) do
		if rockmech.show_bill then
			rockmech.show_bill(m, S("Pickup truck #@1", o.loads + o.rejected), {
				{S("Accepted  grade @1", pct(g)), t1(t), ("$%d"):format(o.price), money_text(pay), 0x80ff80},
				{S("Order progress"), ("%s / %d t"):format(("%.1f"):format(o.done), o.tons), "", "", 0xffffff}})
		end
	end
	-- 開走
	local p = e.object:get_pos()
	core.sound_play("rockmech_engine", {pos = p, gain = 0.6, max_hear_distance = 40}, true)
	core.add_particlespawner({amount = 30, time = 1, minpos = vector.offset(p, -1.5, -1, -6), maxpos = vector.offset(p, 1.5, 1, 1.5),
		minvel = {x = -0.5, y = 0.3, z = -0.5}, maxvel = {x = 0.5, y = 1.2, z = 0.5}, minexptime = 1, maxexptime = 2,
		minsize = 3, maxsize = 6, texture = "[fill:4x4:#c8c0b4^[opacity:120"})
	V.registry_drop(e.uid); V.snapshot_clear(e.uid)
	e.object:remove()
	trucks[acc] = nil
	if o.done >= o.tons - 1e-6 then close(acc, o, "done")
	else tell(acc, S("Truck left with @1 (@2 / @3 t). Next one in @4 s", t1(t), ("%.1f"):format(o.done), o.tons, SECS_NEXT)) end
end

-- 卡車、手推車在收料車旁邊倒料：對準了就倒進車斗（裝不下的照常倒在地上）
local SNAP = 3.5
local dump_to_ground = V.dump_to_ground
function V.dump_to_ground(self, cells, ytop)
	if self.vkind ~= KIND and cells[1] then
		local cx, cz = 0, 0
		for _, c in ipairs(cells) do cx, cz = cx + c.x, cz + c.z end
		cx, cz = cx / #cells, cz / #cells
		for _, e in pairs(trucks) do
			if e.object:get_pos() and not e.tip then
				local bt = V.bed_target(e)
				local half = V.TYPES[KIND].bed.size.z / 2
				local dx, dz = cx - bt.x, cz - bt.z
				if math.abs(dx) <= SNAP and math.abs(dz) <= half + 1 and math.abs(ytop - bt.y) < 6 then
					local room = V.TYPES[KIND].cap - V.load_total(e)
					for base, lv in pairs(self.load) do
						local m = math.min(lv, room)
						if m > 0 then
							V.load_put(e, base, m, V.load_grade(self, base))
							room = room - m
							V.load_keep(self, base, lv - m)
						end
					end
					V.refresh(e)
					break
				end
			end
		end
	end
	return dump_to_ground(self, cells, ytop)
end

-- 每秒：到期結案、補收料車、滿了就驗收
local tick = 0
core.register_globalstep(function(dtime)
	tick = tick + dtime
	if tick < 1 then return end
	tick = 0
	local d = today()
	local now = core.get_gametime()
	local accs = {}
	for _, p in ipairs(core.get_connected_players()) do accs[rockmech.account_of(p:get_player_name())] = true end
	for i = 1, cfg.career_teams or 0 do accs["team:" .. i] = true end      -- 組員都不在線也要到期結案
	for acc in pairs(accs) do
		local o = get_order(acc)
		if o then
			if d >= o.due then
				close(acc, o, "late")
			else
				local e = truck_of(acc)
				if e then
					if V.load_total(e) >= V.TYPES[KIND].cap and not e.tip then weigh(acc, e) end
				elseif now >= (o.next_t or 0) then
					-- 收料區的區塊載入了才放。還有一台存在地圖裡（o.truck）：它載入時會自己報到（on_load），
					-- 要有人站在旁邊（那一帶一定是活躍的）3 秒還沒報到，才當作不見了重放一台
					local x0 = site_of(acc)
					local bp = x0 and {x = x0 + BAY.x, y = sy(), z = BAY.z}
					local ready = bp and core.get_node(bp).name ~= "ignore"
					if ready and o.truck then
						ready = false
						for _, p in ipairs(core.get_connected_players()) do
							if vector.distance(p:get_pos(), bp) < 20 then ready = true; break end
						end
					end
					if ready then
						o.wait = (o.wait or 0) + 1
						if o.wait >= 3 then o.wait = nil; spawn_truck(acc, o) else set_order(acc, o) end
					end
				end
			end
		end
	end
end)

---------------------------------------------------------------------------
-- 視窗：採購員（接單、看進度、取消）、收料車（叫它先走）
---------------------------------------------------------------------------

local FORM, TFORM = "rockmech:buyer", "rockmech:receiver"
local function lbl(x, y, s) return ("label[%g,%g;%s]"):format(x, y, F(s)) end

local function buyer_form(name)
	local acc = rockmech.account_of(name)
	local o = get_order(acc)
	local out = {"formspec_version[6]size[11,7.4]", lbl(0.5, 0.6, S("Power Plant Buyer"))}
	if o then
		local left = o.due - today()
		out[#out + 1] = lbl(0.5, 1.4, S("Current order: @1 t, grade ≥ @2, $@3/t", o.tons, pct(o.spec), o.price))
		out[#out + 1] = lbl(0.5, 1.9, S("Delivered @1 / @2 t, @3 loads, @4 rejected", ("%.1f"):format(o.done), o.tons, o.loads, o.rejected))
		out[#out + 1] = lbl(0.5, 2.4, S("@1 days left, received @2", left, money_text(o.paid)))
		out[#out + 1] = lbl(0.5, 3.1, S("Short at the deadline: @1% of the price as penalty", PENALTY * 100))
		out[#out + 1] = ("button[0.5,5.8;4,0.8;cancel;%s]"):format(F(S("Cancel order")))
	else
		out[#out + 1] = lbl(0.5, 1.4, S("Deliver to the pickup truck at the receiving area. Price is locked when you accept"))
		out[#out + 1] = lbl(0.5, 1.9, S("Below spec: the whole load is rejected. Short at the deadline: @1% penalty", PENALTY * 100))
		for i, of in ipairs(offers(acc)) do
			local y = 2.4 + i * 1.0
			out[#out + 1] = lbl(0.5, y, S("@1 t   grade ≥ @2   @3 days   $@4/t", of.tons, pct(of.spec), of.days, of.price))
			out[#out + 1] = ("button[7.5,%g;3,0.8;take%d;%s]"):format(y - 0.4, i, F(S("Accept")))
		end
	end
	return table.concat(out)
end
local function open_buyer(player)
	local name = player:get_player_name()
	local acc = rockmech.account_of(name)
	if not rockmech.has_account(name) or not site_of(acc) then
		rockmech.notify(name, S("[Order] You have no camp yet"))
		return
	end
	core.show_formspec(name, FORM, buyer_form(name))
end

local function truck_form(e)
	local lv, _ = load_grade(e)
	return table.concat({"formspec_version[6]size[8,3.6]", lbl(0.5, 0.6, S("Pickup truck")),
		lbl(0.5, 1.3, S("Loaded @1 / @2", t1(tons_of(lv)), t1(CAP_T()))),
		("button[0.5,2.2;4,0.8;go;%s]"):format(F(S("Weigh and send now")))})
end
local open_truck = {}            -- 玩家 → 收料車
function rockmech.orders_truck_form(e, clicker)
	local name = clicker:get_player_name()
	if rockmech.account_of(name) ~= e.owner then return end
	open_truck[name] = e
	core.show_formspec(name, TFORM, truck_form(e))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM and formname ~= TFORM then return end
	local name = player:get_player_name()
	local acc = rockmech.account_of(name)
	if formname == TFORM then
		local e = open_truck[name]
		if fields.go and e and e.object:get_pos() and e.owner == acc and not e.tip then
			core.close_formspec(name, TFORM)
			weigh(acc, e)
		end
		if fields.quit then open_truck[name] = nil end
		return true
	end
	if fields.cancel then
		local o = get_order(acc)
		if o then close(acc, o, "cancel") end
		core.close_formspec(name, FORM)
		return true
	end
	for i = 1, #SIZES do
		if fields["take" .. i] then
			if not get_order(acc) then
				local of = offers(acc)[i]
				if of then accept(acc, of) end
			end
			core.show_formspec(name, FORM, buyer_form(name))
		end
	end
	return true
end)

---------------------------------------------------------------------------
-- 採購員：在營地的地坪上走來走去（路線來回走，每點停一下），有人靠近就停下來
---------------------------------------------------------------------------

local WHO = "buyer"
local NPC = "rockmech:npc_buyer"
-- 路線（x 相對營地中心、z 絕對）：收料區旁 → 看板西邊 → 講堂和研究帳篷之間 → 貨櫃辦公室前 → 出生點
local ROUTE = {{-9, -58}, {-8, -44}, {8, -34}, {11, -21}, {15, -10}, {4, -7}}
local WALK = 1.4
local NEAR_SPAWN, FAR_DROP = 48, 72
local buyers = {}                -- 營地 x0 → entity

local function waypoint(x0, i)
	local w = ROUTE[i]
	local x, z = x0 + w[1], w[2]
	local y = ground_y(x, z)
	return y and {x = x + 0.5, y = y + 0.5, z = z + 0.5}
end

core.register_entity(NPC, {
	initial_properties = {
		physical = true, collide_with_objects = false, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {rockmech.npc_skin(WHO)},
		nametag = S("Power Plant Buyer"), nametag_color = "#a0ffb0", stepheight = 1.1, static_save = false,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		self.object:set_acceleration({x = 0, y = -9.81, z = 0})
		self.object:set_animation({x = 0, y = 79}, 30)
		rockmech.npc_dress(self.object, WHO)
		self.i, self.dir, self.pause = 1, 1, 2
	end,
	on_step = function(self, dtime)
		local x0 = self.x0
		if not x0 or buyers[x0] ~= self.object then self.object:remove(); return end
		local pos = self.object:get_pos()
		local vel = self.object:get_velocity()
		local function stand()
			self.object:set_velocity({x = 0, y = vel.y, z = 0})
			if self.anim ~= "stand" then self.anim = "stand"; self.object:set_animation({x = 0, y = 79}, 30) end
		end
		-- 有人在旁邊：停下來面向他
		for _, p in ipairs(core.get_connected_players()) do
			local pp = p:get_pos()
			if vector.distance(pp, pos) < 4 then
				stand()
				self.object:set_yaw((math.atan2 or math.atan)(-(pp.x - pos.x), pp.z - pos.z))
				return
			end
		end
		if self.pause > 0 then self.pause = self.pause - dtime; stand(); return end
		local tgt = self.tgt or waypoint(x0, self.i)
		self.tgt = tgt
		if not tgt then stand(); return end
		local dx, dz = tgt.x - pos.x, tgt.z - pos.z
		local d = math.sqrt(dx * dx + dz * dz)
		if d < 0.6 then
			-- 到了：停 3–8 秒，往下一點（到底就折返）
			self.pause = math.random(3, 8)
			local n = self.i + self.dir
			if n < 1 or n > #ROUTE then self.dir = -self.dir; n = self.i + self.dir end
			self.i, self.tgt, self.stuck, self.best = n, nil, 0, nil
			stand()
			return
		end
		-- 卡住（8 秒沒更接近）：直接到目標
		if not self.best or d < self.best - 0.2 then self.best, self.stuck = d, 0
		else
			self.stuck = (self.stuck or 0) + dtime
			if self.stuck > 8 then self.object:set_pos(tgt); self.stuck, self.best = 0, nil; return end
		end
		self.object:set_velocity({x = dx / d * WALK, y = vel.y, z = dz / d * WALK})
		self.object:set_yaw((math.atan2 or math.atan)(-dx, dz))
		if self.anim ~= "walk" then self.anim = "walk"; self.object:set_animation({x = 168, y = 187}, 20) end
	end,
	on_rightclick = function(self, clicker)
		if rockmech.hand_first and rockmech.hand_first(clicker) then return end
		if clicker and clicker:is_player() then open_buyer(clicker) end
	end,
	on_punch = function() return true end,
})
rockmech.career_npcs[WHO] = {entity = NPC, title = S("Power Plant Buyer"), sells = S("Coal contracts"),
	color = "#a0ffb0", tint = "#2f7a46", sit = false, roams = true}

-- 營地附近有人才放採購員，沒人了收掉（不存檔）
local bt = 0
core.register_globalstep(function(dtime)
	bt = bt + dtime
	if bt < 2 then return end
	bt = 0
	if not cfg.career then return end
	local players = core.get_connected_players()
	for _, x0 in ipairs(sites()) do
		if storage:get_string("pad:" .. x0) == "1" then
			local c = {x = x0 + 4, y = sy(), z = -25}
			local near
			for _, p in ipairs(players) do
				local d = vector.distance(p:get_pos(), c)
				if d < FAR_DROP then near = math.min(near or d, d) end
			end
			local o = buyers[x0]
			local alive = o and o:get_pos()
			if alive and not near then o:remove(); buyers[x0] = nil
			elseif not alive and near and near < NEAR_SPAWN then
				local p = waypoint(x0, 1)
				if p then
					local obj = core.add_entity(p, NPC)
					local e = obj and obj:get_luaentity()
					if e then e.x0 = x0; buyers[x0] = obj end
				end
			end
		end
	end
end)

---------------------------------------------------------------------------
-- 老師：全班同一張訂單
---------------------------------------------------------------------------

if cfg.teacher then
	core.register_chatcommand("rockmech_order", {
		params = "<tons> <grade %> <days> [price/t]", privs = {rockmech = true},
		description = S("Give every team the same order (teams with an order already are skipped)"),
		func = function(_, param)
			local tons, spec, days, price = (param or ""):match("^%s*(%d+)%s+(%d+)%s+(%d+)%s*(%d*)%s*$")
			if not tons then return false, S("Usage: /rockmech_order <tons> <grade %> <days> [price/t]") end
			spec = tonumber(spec) / 100
			local ore = cfg.ores.coal
			price = tonumber(price) or math.floor(rockmech.ore_price(ore) * spec * 1.25 + 0.5)
			local n, skip = 0, 0
			for i = 1, cfg.career_teams or 0 do
				local acc = "team:" .. i
				if site_of(acc) then
					if get_order(acc) then skip = skip + 1
					else accept(acc, {tons = tonumber(tons), spec = spec, days = tonumber(days), price = price}); n = n + 1 end
				end
			end
			return true, S("Order sent to @1 teams (@2 skipped)", n, skip)
		end,
	})
end

rockmech.orders = {offers = offers, get = get_order, set = set_order, accept = accept, close = close, weigh = weigh,
	truck_of = truck_of, PADS = PADS, BAY = BAY, site_of = site_of, buyers = buyers}
