-- rockmech/blasting.lua
-- TNT 爆破與岩石破碎（引擎端）。範圍計算在 blast.lua（純函式）。
--
-- 做法：
--   * 岩性方塊與碎石定義 on_blast（不做事），原版 TNT 就不會直接刪掉它們
--   * 包裝 tnt.boom：原版爆炸結束後，依岩性強度處理半徑內的岩石：
--       中心區炸飛（變成噴出的碎石物品）、外圍原地破碎成碎石
--   * 之後觸發穩定判定、懸臂斷裂、軸差破壞，以及碎石的掉落與滑動
--     （原版 TNT 以 VoxelManip 刪除方塊，不會觸發 on_destruct）

if not (core.get_modpath("tnt") and tnt and tnt.boom) then
	return
end

local blast = rockmech.blast
local cfg = rockmech.cfg
local bcfg = cfg.blast

-- 岩性與碎石：原版 TNT 不直接刪除，交給下面的 blast_rock
for _, n in ipairs(rockmech.lith_nodes) do
	core.override_item(n, {on_blast = function() end})
end
for _, n in ipairs(rockmech.rubble_nodes) do
	core.override_item(n, {on_blast = function() end})
end

local lith_of_cid, rubble_cid, cid_of
local function build_maps()
	if lith_of_cid then return end
	lith_of_cid, rubble_cid, cid_of = {}, {}, {}
	for _, n in ipairs(rockmech.lith_nodes) do
		lith_of_cid[core.get_content_id(n)] = {name = n, lith = rockmech.lith_of_node[n]}
	end
	for _, n in ipairs(rockmech.rubble_nodes) do
		rubble_cid[core.get_content_id(n)] = n
		cid_of[n] = core.get_content_id(n)
	end
	for n, k in pairs(rockmech.road_level) do     -- 炸藥下夯實碎石也一樣飛散
		rubble_cid[core.get_content_id(n)] = rockmech.rubble_with_level(rockmech.RUBBLE, k)
	end
end

local function eject_items(center, counts)
	for name, n in pairs(counts) do
		while n > 0 do
			local k = math.min(n, 10)
			n = n - k
			local obj = core.add_item(center, ItemStack(name .. " " .. k))
			if obj then
				obj:set_velocity({
					x = math.random(-50, 50) / 10,
					y = math.random(30, 80) / 10,
					z = math.random(-50, 50) / 10,
				})
			end
		end
	end
end

-- 處理以 center 為中心、爆炸半徑 R 的岩石破碎。回傳 炸飛格數, 碎石化格數
-- floor_y：只破碎這一層以上（台階爆破的底板 = 孔底）；nil 不限
-- D：爆破擾動帶（破碎區外 damage_t 公尺）的 Hoek-Brown 擾動係數，依裝藥方式（Hoek 2002 的表）：
--   每孔 1 條乳膠炸藥（控制爆破、平滑爆破）0.5；每孔 2 條以上、貼面裝藥、一般 TNT 0.8；ANFO 台階生產爆破 1.0
local DAMAGE_T = math.max(0, bcfg.damage_t or 1)
function rockmech.blast_rock(center, R, floor_y, D)
	build_maps()
	D = D or 0.8
	local fmax = 1
	for _, l in pairs(cfg.lithologies) do
		local f = blast.factor(l.ucs, bcfg.ucs_ref, bcfg.ucs_exp)
		if f > fmax then fmax = f end
	end
	local rr = math.ceil(R * fmax + DAMAGE_T)
	local damaged = {}
	local c0 = vector.round(center)   -- 掃描用整數格點（爆心可以不在格點上，距離照實際爆心算）
	local p1, p2 = vector.subtract(c0, rr), vector.add(c0, rr)
	if floor_y then p1.y = math.max(p1.y, floor_y) end
	if p1.y > p2.y then return 0, 0 end
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map(p1, p2)
	local area = VoxelArea(e1, e2)
	local data = vm:get_data()
	local c_air = core.get_content_id("air")

	local p2data = vm:get_param2_data()
	local ejected, n_eject, n_rubble = {}, 0, 0   -- ejected：滿格碎石名稱 → 累計級數
	local thrown = {}      -- 經營模式：炸飛的碎石 {base, 級數, 品位}，落回爆破坑（世界不掉落碎石）
	local removed, rubbled = {}, {}
	local changes = {}     -- 開挖前的方塊（只有開挖造成的惡化才破壞）
	for z = p1.z, p2.z do for y = p1.y, p2.y do
		local vi = area:index(p1.x, y, z)
		for x = p1.x, p2.x do
			local cid = data[vi]
			local li = lith_of_cid[cid]
			local rb = rubble_cid[cid]
			if li or rb then
				local dx, dy, dz = x - center.x, y - center.y, z - center.z
				local d = math.sqrt(dx * dx + dy * dy + dz * dz)
				local p = {x = x, y = y, z = z}
				if li then
					local zone = blast.zone(d, R, li.lith.ucs, bcfg.ucs_ref, bcfg.inner, bcfg.ucs_exp)
					-- 破碎區外一圈：岩石還在，但被爆破擾動（D）
					if not zone and D > 0 and d <= R * blast.factor(li.lith.ucs, bcfg.ucs_ref, bcfg.ucs_exp) + DAMAGE_T then
						damaged[#damaged + 1] = p
					end
					local rname = rockmech.rubble_for(li.name)
					if zone then changes[#changes + 1] = {pos = p, name = li.name} end
					if zone == "eject" then
						thrown[#thrown + 1] = {rname, rockmech.RUBBLE_LEVELS, rockmech.rubble_p2({name = li.name, param2 = p2data[vi]})}
						data[vi] = c_air
						ejected[rname] = (ejected[rname] or 0) + rockmech.RUBBLE_LEVELS
						n_eject = n_eject + 1
						removed[#removed + 1] = p
					elseif zone == "rubble" then
						local rn, rp = rockmech.rubble_node({name = li.name, param2 = p2data[vi]})
						data[vi], p2data[vi] = core.get_content_id(rn), rp
						n_rubble = n_rubble + 1
						rubbled[#rubbled + 1] = p
					end
				elseif d <= bcfg.inner * R then
					-- 已經是碎石：中心區一樣炸飛
					changes[#changes + 1] = {pos = p, name = rb}
					data[vi] = c_air
					-- 不滿格的碎石：依級數累加到滿格碎石（8 級 = 1 個），物品才會疊在同一堆
					local base = rockmech.rubble_base[rb] or rb
					thrown[#thrown + 1] = {base, rockmech.rubble_level[rb] or rockmech.RUBBLE_LEVELS, p2data[vi]}
					ejected[base] = (ejected[base] or 0) + (rockmech.rubble_level[rb] or rockmech.RUBBLE_LEVELS)
					n_eject = n_eject + 1
					removed[#removed + 1] = p
				end
			end
			vi = vi + 1
		end
	end end

	if n_eject + n_rubble > 0 then
		vm:set_data(data)
		vm:set_param2_data(p2data)
		vm:write_to_map(true)
		vm:update_liquids()
		if rockmech.jointmesh then rockmech.jointmesh.dirty_box(p1, p2) end
	end
	vm:close()
	for _, p in ipairs(damaged) do rockmech.collapse.mark_damage(p, D) end
	-- 級數 → 個數（四捨五入）
	for name, lv in pairs(ejected) do ejected[name] = math.floor(lv / rockmech.RUBBLE_LEVELS + 0.5) end
	if cfg.career then
		for _, t in ipairs(thrown) do
			local left = t[2]
			for _ = 1, #removed do       -- 那一欄滿了就換一欄
				if left <= 0 then break end
				local p = removed[math.random(#removed)]
				left = rockmech.vehicles.deposit_column(p.x, p.z, p.y, t[1], left, nil, nil, t[3])
			end
		end
	else
		eject_items(center, ejected)
	end

	-- 觸發後續判定：爆炸範圍內的移除點（穩定判定、懸臂斷裂）與爆心（軸差破壞）
	local col = rockmech.collapse
	col.record_changes(changes)
	col.queue_stability_check(center)
	for _, p in ipairs(removed) do col.queue_stability_check(p) end
	col.queue_failure_check(center)
	-- 碎石：懸空就落下、超過安息角就滑動（下一個 tick，等其他判定排定）
	table.sort(rubbled, function(a, b) return a.y < b.y end)
	core.after(0.1, function()
		for _, p in ipairs(rubbled) do col.check_cell(p) end
	end)
	core.log("action", ("[rockmech] 爆破 %s R=%.1f：炸飛 %d 格、碎石化 %d 格"):format(
		core.pos_to_string(center), R, n_eject, n_rubble))
	return n_eject, n_rubble
end

-- 原版爆炸時，相鄰（±2 格）的 TNT 會一起引爆，半徑 = ⌊R0·n^(1/3)⌋
local TNT_NAMES = {["tnt:tnt"] = true, ["tnt:tnt_burning"] = true, ["tnt:boom"] = true}
local function count_tnt(pos)
	local n = 0
	for x = -2, 2 do for y = -2, 2 do for z = -2, 2 do
		if TNT_NAMES[core.get_node({x = pos.x + x, y = pos.y + y, z = pos.z + z}).name] then
			n = n + 1
		end
	end end end
	return n
end

local orig_boom = tnt.boom

-- 炸藥（鑽孔裝藥、貼面裝藥，drilling.lua）：爆心 center（可以在岩石裡、可以不在格點上）、岩石破碎半徑 R（m，可為小數）。
-- 原版爆炸照常（聲音、粒子、傷害、炸掉附近非岩石方塊與殉爆；在最近的格點），岩石的破碎用 center 與 R
function rockmech.blast_charge(center, R, floor_y, D)
	orig_boom(vector.round(center), {radius = math.max(1, math.floor(R + 0.5)), explode_center = true})
	if bcfg.enabled and R > 0 then
		rockmech.blast_rock(center, R, floor_y, D)
	end
end

tnt.boom = function(pos, def)
	def = def or {}
	local center = vector.round(pos)
	local n = count_tnt(center)
	if def.explode_center then n = n + 1 end
	local R = blast.effective_radius(def.radius or 1, n)
	orig_boom(pos, def)
	if bcfg.enabled and R > 0 then
		rockmech.blast_rock(center, R)
	end
end
