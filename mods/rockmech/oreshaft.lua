-- rockmech/oreshaft.lua
-- 豎井（溜井）：採場地面上的圓井（半徑 r），深 DEPTH m。井壁是一圈完整、沒有節理切過的硬大理岩（厚 ring m），
-- 像一口天然的豎井；採場往下挖時這圈岩石跟著一起挖，井口就降低。
-- 井裡一開始填滿碎石到「井口下 KEEP m」（填料不算錢，撐住井壁）。收料：井裡高過「井口下 KEEP m」的碎石
-- 每 STEP 秒收走、付錢（照品位和市價，廢石收處理費，跟收煤站一樣）；倒多少收多少，碎石面一直維持在井口下 KEEP m。
-- 井口 = 井壁硬大理岩還在的最高那一層（挖掉了就往下找）。
-- 世界設定 rockmech_shafts = x,z;x,z;...（井口中心，遊戲座標）。營地第一次蓋好之後每口井蓋一次（mod storage shaft:<i>）。
-- 有豎井的地圖營地不蓋收煤站（config.lua：cfg.camp_crusher = false）。節理：井壁那一圈不帶節理（init.lua 的 skip）。

local cfg = rockmech.cfg
local S = rockmech.S
local storage = rockmech.collapse.storage
local WALL = "rockmech:shaft_marble"
local DEPTH = 150               -- 井深 (m)
local KEEP = 5                  -- 碎石面維持在井口下幾公尺
local STEP = 2                  -- 每幾秒收一次
local RAD = cfg.shaft_r or 6
local RING = cfg.shaft_ring or 6
local function inside(dx, dz) return dx * dx + dz * dz <= (RAD + 0.5) ^ 2 end
local function in_wall(dx, dz) return dx * dx + dz * dz <= (RAD + RING + 0.5) ^ 2 end

-- 井壁：硬大理岩（沒有節理），挖起來是大理岩碎石
do
	local m = cfg.lithologies.marble
	if m then
		core.register_node(WALL, {
			description = S(m.description), short_description = S(m.description),
			tiles = {m.texture or ("[fill:16x16:" .. m.color)},
			is_ground_content = false,
			groups = {cracky = 2, stone = 1, rockmech_rock = 1, rockmech_ore = 1, not_in_creative_inventory = 1},
		})
		rockmech.lith_of_node[WALL] = m
	end
end

if not (cfg.career and cfg.shafts and #cfg.shafts > 0 and cfg.lithologies.marble) then return end

local V = rockmech.vehicles
local function ground_top(x, z)
	return math.floor(cfg.surface_y) + math.floor(rockmech.stress.terrain_rise(cfg, x, z) + 0.5)
end
local function tons_of(levels) return levels / V.NLEV * cfg.rubble_density end

local function build(i, s, owner)
	local top = ground_top(s.x, s.z)
	local bottom = top - DEPTH
	local fill_top = top - KEEP
	local base = rockmech.rubble_for("rockmech:marble")
	local C = rockmech.collapse
	C.quiet = C.quiet + 1
	local ok, err = pcall(function()
		local R = RAD + RING
		for y = bottom - 1, top + 6 do
			for x = s.x - R, s.x + R do for z = s.z - R, s.z + R do
				local p = {x = x, y = y, z = z}
				local hole = inside(x - s.x, z - s.z)
				if not in_wall(x - s.x, z - s.z) then
					-- 圓環外面不動
				elseif hole and y >= bottom then
					C.mark_excavated(p)
					if y <= fill_top then core.swap_node(p, {name = base, param2 = 200})      -- 填料
					else core.swap_node(p, {name = "air"}) end
				elseif y <= top and rockmech.lith_of_node[core.get_node(p).name] then
					core.swap_node(p, {name = WALL, param2 = 230})      -- 井壁和井底：硬大理岩
				end
			end end
		end
	end)
	C.quiet = C.quiet - 1
	if not ok then error(err) end
	storage:set_string("shaft:" .. i, core.serialize({x = s.x, z = s.z, top = top, owner = owner}))
	core.log("action", ("[rockmech] 豎井 %d：井口 (%d, %d, %d)，深 %d m"):format(i, s.x, top, s.z, DEPTH))
end

local pending = false
local function ensure(owner)
	if pending then return end
	for i, s in ipairs(cfg.shafts) do
		if storage:get_string("shaft:" .. i) == "" then
			pending = true
			local top = ground_top(s.x, s.z)
			local R = RAD + RING
			core.emerge_area({x = s.x - R, y = top - DEPTH - 2, z = s.z - R}, {x = s.x + R, y = top + 8, z = s.z + R}, function(_, _, rem)
				if rem > 0 then return end
				pending = false
				if storage:get_string("shaft:" .. i) == "" then build(i, s, owner) end
				ensure(owner)
			end)
			return
		end
	end
end

core.register_on_joinplayer(function(player)
	core.after(3, function()
		if storage:get_string("career_site") == "" then return end
		local p = core.get_player_by_name(player:get_player_name())
		if p then ensure(rockmech.account_of(p:get_player_name())) end
	end)
end)

---------------------------------------------------------------------------
-- 收料
---------------------------------------------------------------------------

-- 井口：井壁硬大理岩還在的最高一層（從記下的井口往下找）
local function collar(d)
	local x = d.x + RAD + 1
	for y = d.top, d.top - DEPTH, -1 do
		local n = core.get_node({x = x, y = y, z = d.z}).name
		if n == "ignore" then return nil end
		if n == WALL then return y end
	end
end

local sums = {}      -- 井 → {t, money, last}
local function pay(i, d, levels, base, p2)
	local t = tons_of(levels)
	local ore = cfg.main_ore
	local g = rockmech.grade_for(base, p2, ore)
	local gross = t * g * rockmech.eff_ore_recovery(d.owner, ore) * rockmech.ore_price(ore)
	local fee = t * (1 - g) * rockmech.gangue_fee(ore)
	rockmech.add_money(d.owner, gross - fee)
	local s = sums[i] or {t = 0, money = 0}
	s.t, s.money, s.last = s.t + t, s.money + gross - fee, core.get_us_time() / 1e6
	sums[i] = s
end

-- 離 pos 最近、水平距離在 井半徑 + reach 內、高度離井口 8 m 內的豎井：回傳 i, d, 井口高程
local function shaft_near(pos, reach)
	for i in ipairs(cfg.shafts) do
		local d = core.deserialize(storage:get_string("shaft:" .. i))
		if d and (pos.x - d.x) ^ 2 + (pos.z - d.z) ^ 2 <= (RAD + reach) ^ 2 then
			local c = collar(d)
			if c and math.abs(pos.y - c) < 8 then return i, d, c end
		end
	end
end

-- 自動對準（跟破碎站受料倉一樣）：卡車、怪手倒料的那幾欄中心離井口 SNAP m 內，整車倒進井裡、馬上算錢
local SNAP = 4
local dump_to_ground = V.dump_to_ground
function V.dump_to_ground(self, cells, ytop)
	if self.load and cells and cells[1] then
		local cx, cz = 0, 0
		for _, c in ipairs(cells) do cx, cz = cx + c.x, cz + c.z end
		local i, d, c = shaft_near({x = cx / #cells, y = ytop, z = cz / #cells}, SNAP)
		if i then
			local took = 0
			for base, lv in pairs(self.load) do
				if base ~= "default:tree" and rockmech.rubble_level and lv > 0 then
					pay(i, d, lv, base, V.load_grade(self, base))
					V.load_keep(self, base, 0)
					took = took + lv
				end
			end
			if took > 0 then
				local p = {x = d.x, y = c - 2, z = d.z}
				rockmech.collapse.rubble_sound(p, took)
				core.add_particlespawner({amount = 40, time = 1.5, minpos = vector.offset(p, -2, 0, -2), maxpos = vector.offset(p, 2, 3, 2),
					minvel = {x = -0.3, y = -3, z = -0.3}, maxvel = {x = 0.3, y = -1, z = 0.3}, minexptime = 0.8, maxexptime = 1.5,
					minsize = 2, maxsize = 5, texture = "[fill:4x4:#bdb8ae"})
			end
		end
	end
	return dump_to_ground(self, cells, ytop)
end

-- 無人卡車（vehicle_ahs.lua）：傾倒點在井口旁邊 → 當成受料倉，倒車到井邊。r：車身要停在離中心多遠以外
function rockmech.shaft_center(pos)
	local _, d, c = shaft_near(pos, RING + SNAP)
	if d then return {x = d.x, y = c, z = d.z, r = RAD + 0.5} end
end

local tick = 0
core.register_globalstep(function(dtime)
	tick = tick + dtime
	if tick < STEP then return end
	tick = 0
	local now = core.get_us_time() / 1e6
	for i in ipairs(cfg.shafts) do
		local d = core.deserialize(storage:get_string("shaft:" .. i))
		if d then
			local c = collar(d)
			if c then
				local keep = c - KEEP
				local C = rockmech.collapse
				C.quiet = C.quiet + 1
				local ok, err = pcall(function()
					for y = c + 8, keep + 1, -1 do
						for x = d.x - RAD, d.x + RAD do for z = d.z - RAD, d.z + RAD do
							local p = {x = x, y = y, z = z}
							local k = inside(x - d.x, z - d.z) and rockmech.rubble_level[core.get_node(p).name]
							if k then
								local lv, base, p2 = V.take_rubble(p, k)
								if lv > 0 then pay(i, d, lv, base, p2) end
							end
						end end
					end
				end)
				C.quiet = C.quiet - 1
				if not ok then error(err) end
			end
			-- 停止倒料 10 秒後通知一次這一批
			local s = sums[i]
			if s and now - s.last > 10 then
				sums[i] = nil
				for _, m in ipairs(rockmech.account_members(rockmech.account_of(d.owner))) do
					rockmech.notify(m, S("[Ore pass @1] @2 t, @3", i, ("%.1f"):format(s.t), rockmech.money_text and rockmech.money_text(s.money) or ("$%.0f"):format(s.money)))
				end
			end
		end
	end
end)
