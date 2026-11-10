-- rockmech/oreshaft.lua
-- 豎井（溜井）：採場地面上的方井（邊長 2·half+1），深 DEPTH m。井壁是一圈完整、沒有節理切過的硬大理岩（厚 ring m），
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
local HALF = cfg.shaft_half or 4
local RING = cfg.shaft_ring or 6

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
		local R = HALF + RING
		for y = bottom - 1, top + 6 do
			for x = s.x - R, s.x + R do for z = s.z - R, s.z + R do
				local p = {x = x, y = y, z = z}
				local inside = math.abs(x - s.x) <= HALF and math.abs(z - s.z) <= HALF
				if inside and y >= bottom then
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
			local R = HALF + RING
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
	local x = d.x + HALF + 1
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
						for x = d.x - HALF, d.x + HALF do for z = d.z - HALF, d.z + HALF do
							local p = {x = x, y = y, z = z}
							local k = rockmech.rubble_level[core.get_node(p).name]
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
