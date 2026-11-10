-- rockmech/oreshaft.lua
-- 豎井（溜井）：採場地面上一個方井，往下 DEPTH m 是地下硐室裡的大型破碎站（受料倉就在井的正下方）。
-- 礦石從井口倒下去，掉進受料倉，破碎站照平常收料、付錢（crusher.lua）。仿和平礦場：礦石經豎井到山裡的碎石機房。
-- 世界設定 rockmech_shafts = x,z;x,z;...（井口中心，遊戲座標）。營地第一次蓋好之後，每口井蓋一次（mod storage shaft:<i>）。
-- 有豎井的地圖營地不蓋收煤站（config.lua：cfg.camp_crusher = false）。

local cfg = rockmech.cfg
if not (cfg.career and cfg.shafts and #cfg.shafts > 0) then return end
local storage = rockmech.collapse.storage
local H = rockmech.hopper_lib
local BIG = "rockmech:crusher_big"
local LINING = "rockmech:hopper_lining"
local DEPTH = 24                -- 井口到破碎站機身的高差 (m)
local SIZE = H.SIZE             -- 井的邊長 = 受料倉開口
local HALF = (SIZE - 1) / 2

local function ground_top(x, z)
	return math.floor(cfg.surface_y) + math.floor(rockmech.stress.terrain_rise(cfg, x, z) + 0.5)
end

local function lith(p) return rockmech.lith_of_node[core.get_node(p).name] ~= nil end

local function build(i, s, owner)
	local top = ground_top(s.x, s.z)
	local by = top - DEPTH
	local B = {x = s.x - (2 + HALF), y = by, z = s.z}      -- 機身在井的西邊，受料倉朝東（正在井下）
	local C = rockmech.collapse
	C.quiet = C.quiet + 1
	local ok, err = pcall(function()
		-- 井：從受料倉頂（機身高度）挖到井口上方，四壁是混凝土
		for y = by, top + 4 do
			for x = s.x - HALF - 1, s.x + HALF + 1 do for z = s.z - HALF - 1, s.z + HALF + 1 do
				local p = {x = x, y = y, z = z}
				local wall = math.abs(x - s.x) > HALF or math.abs(z - s.z) > HALF
				if not wall then
					C.mark_excavated(p)
					core.swap_node(p, {name = "air"})
				elseif y <= top and lith(p) then
					core.swap_node(p, {name = LINING})
				end
			end end
		end
		-- 硐室：機身上方淨空 4 m
		for y = by, by + 3 do
			for x = B.x - 2, B.x + 1 do for z = B.z - 2, B.z + 2 do
				local p = {x = x, y = y, z = z}
				C.mark_excavated(p)
				core.swap_node(p, {name = "air"})
			end end
		end
	end)
	C.quiet = C.quiet - 1
	if not ok then error(err) end
	if rockmech.crusher_build(B, 1, 0, owner, BIG) then
		storage:set_string("shaft:" .. i, core.pos_to_string(B))
		core.log("action", ("[rockmech] 豎井 %d：井口 (%d, %d, %d)，破碎站 %s"):format(i, s.x, top, s.z, core.pos_to_string(B)))
	else
		core.log("warning", ("[rockmech] 豎井 %d 的破碎站蓋不起來 (%d, %d, %d)"):format(i, s.x, by, s.z))
	end
end

local pending = false
local function ensure(owner)
	if pending then return end
	for i, s in ipairs(cfg.shafts) do
		if storage:get_string("shaft:" .. i) == "" then
			pending = true
			local top = ground_top(s.x, s.z)
			local a = {x = s.x - SIZE - 6, y = top - DEPTH - 8, z = s.z - SIZE - 2}
			local b = {x = s.x + SIZE, y = top + 8, z = s.z + SIZE + 2}
			core.emerge_area(a, b, function(_, _, rem)
				if rem > 0 then return end
				pending = false
				if storage:get_string("shaft:" .. i) == "" then build(i, s, owner) end
				ensure(owner)
			end)
			return
		end
	end
end

-- 營地蓋好之後（第一個進來的人是主人）
core.register_on_joinplayer(function(player)
	core.after(3, function()
		if storage:get_string("career_site") == "" then return end
		local p = core.get_player_by_name(player:get_player_name())
		if p then ensure(rockmech.account_of(p:get_player_name())) end
	end)
end)
