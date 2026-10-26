-- rockmech/collapse.lua
-- 由 physics_core 移植的坍塌機制（懸空掉落 + 安息角滑動）。
-- 階段 3 的關鍵塊判定（keyblock.lua）完成後再取代此檔的觸發邏輯。
--
-- 與 physics_core 的差異：
--   * 岩石判定改為 group rockmech_rock（各岩性 node 與 default:stone）
--   * 移除柱狀累計 σy（get_sigma_y_accumulation / calc_node_stress 與 metadata）；
--     初始應力改由 stress.lua 依深度計算，見地質羅盤
--   * 移除 2×2×2 large_rock（改由 mapgen.lua 依深度產生岩性）
--   * 實體改名 rockmech:sliding_node（保留 physics_core:sliding_node 舊名相容）

local collapse = {}
rockmech.collapse = collapse

-- 碎石安息角（rockmech_slope_angle，預設 35°）：顆粒流（granular.lua）的臨界坡度
local SLOPE_TAN = math.tan(math.rad(rockmech.cfg.slope.angle))

local physics_updating = false  -- 防止物理連鎖觸發

-- 位置預約系統：避免兩個方塊同時鎖定同一目標位置造成重疊
local reserved_positions = {}
local function pos_key(p) return string.format("%d,%d,%d", p.x, p.y, p.z) end
local function is_reserved(p) return reserved_positions[pos_key(p)] == true end
local function reserve_pos(p) reserved_positions[pos_key(p)] = true end
local function release_pos(p) reserved_positions[pos_key(p)] = nil end

-- 1. 滑動實體：水平逐步移動
local SLIDE_SPEED = 10.0  -- 滑動速度（格/秒），數值越小越慢越明顯

local sliding_node_def = {
    initial_properties = {
        physical = false,
        visual = "node",
        node = {name = "air"},
        visual_size = {x = 1, y = 1, z = 1},
        collisionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
        glow = -1,
    },
    node_name = "",
    target_pos = nil,

    set_node = function(self, name, target)
        self.node_name = name
        self.target_pos = target
        self.object:set_properties({node = {name = name}})
        -- 計算 3D 方向速度（支援對角移動）
        local pos = self.object:get_pos()
        local dir = {
            x = target.x - pos.x,
            y = target.y - pos.y,
            z = target.z - pos.z
        }
        local len = math.sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z)
        if len > 0 then
            self.object:set_velocity({
                x = dir.x / len * SLIDE_SPEED,
                y = dir.y / len * SLIDE_SPEED,
                z = dir.z / len * SLIDE_SPEED
            })
        end
    end,

    on_step = function(self, dtime)
        if not self.target_pos then
            self.object:remove()
            return
        end
        local pos = self.object:get_pos()
        local tp = self.target_pos
        local dx = tp.x - pos.x
        local dy = tp.y - pos.y
        local dz = tp.z - pos.z
        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

        if dist < 0.1 then
            self.object:remove()
            if self.reserved_side then release_pos(self.reserved_side) end

            if core.get_node(tp).name == "air" then
                core.set_node(tp, {name = self.node_name})
                -- 落地後仍檢查下方：若仍是空氣（例如 escape 落到懸空位置）就掉落
                local below = {x=tp.x, y=tp.y-1, z=tp.z}
                if core.get_node(below).name == "air" then
                    -- 物理系統內部操作：不當作新的開挖觸發
                    physics_updating = true
                    core.spawn_falling_node(tp)
                    physics_updating = false
                end
            end
            if self.reserved_landing then release_pos(self.reserved_landing) end
        end
    end,

    on_activate = function(self, staticdata)
        if staticdata and staticdata ~= "" then
            local data = core.deserialize(staticdata)
            if data then
                self.node_name = data.node_name or ""
                self.target_pos = data.target_pos
                if self.node_name ~= "" then
                    self.object:set_properties({node = {name = self.node_name}})
                end
            end
        end
    end,

    get_staticdata = function(self)
        return core.serialize({
            node_name = self.node_name,
            target_pos = self.target_pos
        })
    end,
}

core.register_entity("rockmech:sliding_node", sliding_node_def)
-- 舊世界中尚在滑動的實體
core.register_entity(":physics_core:sliding_node", table.copy(sliding_node_def))

-- 2. 岩石判定
local function is_rock(node_name)
    if not node_name then return false end
    return core.get_item_group(node_name, "rockmech_rock") > 0
end
collapse.is_rock = is_rock

-- [前置聲明]
local try_escape_or_destroy
local check_stability_and_move
local update_affected_area

-- 3. 安息角輔助

-- 預先計算掉落落點 y（第一個非空氣上方）
local function compute_landing_y(pos)
    local y = pos.y - 1
    for _ = 1, 64 do
        local n = core.get_node({x=pos.x, y=y, z=pos.z})
        if n.name ~= "air" then return y + 1 end
        y = y - 1
    end
    return nil
end

-- 把 pos 的岩石變成翻滾落石（rockfall_entity.lua）。數量達上限時回傳 false，
-- 呼叫者改用原本的掉落／滑動方式。
-- start：產生位置（預設為格中心）
local function launch_rockfall(pos, velocity, start)
    local rfe = rockmech.rockfall_entity
    if not rfe or not rfe.can_spawn() then return false end
    local node = core.get_node(pos)
    if not is_rock(node.name) then return false end
    local prev = physics_updating
    physics_updating = true  -- 移除 node 不當作新的開挖觸發
    core.remove_node(pos)
    physics_updating = prev
    if not rfe.spawn(start or {x=pos.x, y=pos.y, z=pos.z}, node.name, velocity) then
        core.set_node(pos, node)
        return false
    end
    return true
end
collapse.launch_rockfall = launch_rockfall

-- 碎屑粒子（純視覺）：在 pos 附近噴出 amount 顆，外觀取自 node 的貼圖（同挖方塊時的碎片）
local function debris(pos, node_name, amount, vel)
    if not node_name or node_name == "" or node_name == "air" then return end
    vel = vel or {x = 0, y = 0, z = 0}
    core.add_particlespawner({
        amount = amount, time = 0.3,
        minpos = {x = pos.x - 0.4, y = pos.y - 0.3, z = pos.z - 0.4},
        maxpos = {x = pos.x + 0.4, y = pos.y + 0.4, z = pos.z + 0.4},
        minvel = {x = vel.x - 0.8, y = vel.y + 0.3, z = vel.z - 0.8},
        maxvel = {x = vel.x + 0.8, y = vel.y + 1.6, z = vel.z + 0.8},
        minacc = {x = 0, y = -9.8, z = 0}, maxacc = {x = 0, y = -9.8, z = 0},
        minexptime = 0.6, maxexptime = 1.5,
        minsize = 0, maxsize = 0,
        collisiondetection = true,
        node = {name = node_name},
    })
end
collapse.debris = debris

---------------------------------------------------------------------------
-- 碎石的顆粒流（模型見 granular.lua）
-- 碎石每格分 8 級（1/8 m）。一欄碎石的頂格與周圍 8 方向的表面比較，超過安息角就
-- 分一部分流到最陡的一側；每一步間隔 GRAN_STEP_DELAY 秒，看得到碎石堆慢慢攤成斜坡。
---------------------------------------------------------------------------
local granular = rockmech.granular
local GRAN_STEP_DELAY = 0.12
local GRAN_MAX_CHAIN = 48
local NLEV = rockmech.RUBBLE_LEVELS

local function rubble_k(name) return rockmech.rubble_level[name] end
local function passable(name)
    local d = core.registered_nodes[name]
    return d ~= nil and d.walkable == false
end

-- 碎石欄的頂格：從 p 往上走到最上面一格碎石。回傳位置、名稱；p 不是碎石回傳 nil
local function rubble_top(p)
    local q = {x = p.x, y = p.y, z = p.z}
    local n = core.get_node(q).name
    if not rubble_k(n) then return nil end
    for _ = 1, 64 do
        local up = {x = q.x, y = q.y + 1, z = q.z}
        local un = core.get_node(up).name
        if not rubble_k(un) then break end
        q, n = up, un
    end
    return q, n
end

-- 鄰欄（x, z）相對於來源頂格高度 ty 的表面高度與承接位置。
-- 回傳 e（八分之一公尺）, land = {pos, k}（k = 承接格目前的級數，0 = 空格）；擋住回傳 nil
local function neighbor_surface(x, z, ty, base)
    local p = {x = x, y = ty, z = z}
    local n = core.get_node_or_nil(p)
    if not n then return nil end
    local nk = rubble_k(n.name)
    if nk then
        if nk < NLEV and rockmech.rubble_base[n.name] == base then
            return granular.surface(ty, nk), {pos = p, k = nk}
        end
        return nil
    end
    if not passable(n.name) then return nil end
    for y = ty - 1, ty - 48, -1 do
        local q = {x = x, y = y, z = z}
        local m = core.get_node_or_nil(q)
        if not m then return nil end
        if not passable(m.name) then
            local mk = rubble_k(m.name)
            if mk and mk < NLEV and rockmech.rubble_base[m.name] == base then
                return granular.surface(y, mk), {pos = q, k = mk}
            end
            return granular.surface(y, NLEV), {pos = {x = x, y = y + 1, z = z}, k = 0}
        end
    end
    return nil
end

-- 把 pos 的碎石設為 k 級（0 = 移除；移除會觸發 on_destruct：支撐判定、露出岩面的破壞檢查）
local function set_rubble(pos, base, k)
    local name = rockmech.rubble_with_level(base, k)
    if name then core.swap_node(pos, {name = name}) else core.remove_node(pos) end
end

-- 在承接位置加上 a 級碎石；滿了往上一格堆
local function add_rubble(land, base, a)
    local p, k = land.pos, land.k
    local put = math.min(NLEV - k, a)
    if k == 0 then core.set_node(p, {name = rockmech.rubble_with_level(base, put)})
    else core.swap_node(p, {name = rockmech.rubble_with_level(base, k + put)}) end
    a = a - put
    local up = {x = p.x, y = p.y + 1, z = p.z}
    while a > 0 and passable(core.get_node(up).name) do
        put = math.min(NLEV, a)
        core.set_node(up, {name = rockmech.rubble_with_level(base, put)})
        a = a - put
        up = {x = up.x, y = up.y + 1, z = up.z}
    end
end

local fall_with_slope_settle

-- 顆粒流一步：先往下倒（下方是不滿格的同種碎石），否則依安息角流向最陡的一側。
-- 之後在來源與承接位置排程下一步（最多 chain 步）
local function granular_settle(pos, chain)
    if not rockmech.cfg.slope.enabled then return end
    chain = chain or GRAN_MAX_CHAIN
    if chain <= 0 then return end
    local T, tn = rubble_top(pos)
    if not T then return end
    local base, k = rockmech.rubble_base[tn], rubble_k(tn)
    local below = {x = T.x, y = T.y - 1, z = T.z}
    local bn = core.get_node(below).name
    if passable(bn) then
        fall_with_slope_settle(T)
        return
    end
    local prev = physics_updating
    local next_pos
    local bk = rubble_k(bn)
    if bk and bk < NLEV and rockmech.rubble_base[bn] == base then
        -- 往下倒：先把下面那格填滿
        local put = math.min(NLEV - bk, k)
        physics_updating = true
        core.swap_node(below, {name = rockmech.rubble_with_level(base, bk + put)})
        set_rubble(T, base, k - put)
        physics_updating = prev
        next_pos = {below}
    else
        local nbs, lands = {}, {}
        for i, d in ipairs(granular.DIRS) do
            local e, land = neighbor_surface(T.x + d[1], T.z + d[2], T.y, base)
            nbs[i] = {e = e, d = d[3]}
            lands[i] = land
        end
        local i, amount = granular.choose_flow(granular.surface(T.y, k), k, nbs, SLOPE_TAN)
        if not i then return end
        local land = lands[i]
        physics_updating = true
        set_rubble(T, base, k - amount)
        add_rubble(land, base, amount)
        physics_updating = prev
        local d = granular.DIRS[i]
        debris({x = T.x + d[1] * 0.4, y = T.y, z = T.z + d[2] * 0.4}, base,
            math.max(3, amount * 2), {x = d[1] * 1.5, y = 0, z = d[2] * 1.5})
        next_pos = {k - amount > 0 and T or below, land.pos}
    end
    core.after(GRAN_STEP_DELAY, function()
        for _, p in ipairs(next_pos) do granular_settle(p, chain - 1) end
    end)
end
collapse.granular_settle = granular_settle

-- 碎石懸空：沿用原版 falling node 落下（不滿格的碎石保留級數），落地後接著顆粒流
fall_with_slope_settle = function(pos)
    local target_y = compute_landing_y(pos)
    if target_y then
        -- 落點若已被其他方塊預約，往上找下一個空位
        local landing = {x=pos.x, y=target_y, z=pos.z}
        while is_reserved(landing) do
            landing.y = landing.y + 1
            if landing.y >= pos.y then landing = nil; break end
        end
        if landing then
            reserve_pos(landing)
            local fall_dist = pos.y - landing.y
            local delay = 0.3 + math.sqrt(math.max(1, fall_dist)) * 0.45
            core.spawn_falling_node(pos)
            core.after(delay, function()
                release_pos(landing)
                local n = core.get_node(landing).name
                if fall_dist >= 2 then debris(landing, rockmech.rubble_base[n] or n, 8) end
                granular_settle(landing, GRAN_MAX_CHAIN)
            end)
            return
        end
    end
    -- 沒有可用落點 → 維持原本行為
    core.spawn_falling_node(pos)
end

-- 4. 破壞處理：優先側移，無路可走才破壞（不觸發連鎖更新）
-- 目前沒有呼叫者（physics_core 中的應力破壞判定已關閉），保留給之後的剝落判定使用。
try_escape_or_destroy = function(pos, node)
    -- 優先檢查下方，沒支撐就直接掉落
    local below = {x=pos.x, y=pos.y-1, z=pos.z}
    if core.get_node(below).name == "air" then
        core.spawn_falling_node(pos)
        return
    end

    -- 其次往旁邊側移
    local escape_dirs = {
        {x=1, y=0, z=0}, {x=-1, y=0, z=0},
        {x=0, y=0, z=1}, {x=0, y=0, z=-1}
    }
    for _, ed in ipairs(escape_dirs) do
        local target = {x=pos.x+ed.x, y=pos.y+ed.y, z=pos.z+ed.z}
        if core.get_node(target).name == "air" and not is_reserved(target) then
            local original_name = node.name
            reserve_pos(target)
            core.remove_node(pos)
            local obj = core.add_entity(
                {x=pos.x, y=pos.y, z=pos.z},
                "rockmech:sliding_node"
            )
            if obj then
                local le = obj:get_luaentity()
                le.reserved_side = target
                le.reserved_landing = target
                le:set_node(original_name, target)
            else
                core.set_node(target, {name = original_name})
                release_pos(target)
            end
            core.sound_play("default_break_glass", {pos = pos, gain = 0.3})
            return
        end
    end

    -- 四周都沒空位才破壞
    core.set_node(pos, {name = "air"})
    core.sound_play("default_break_glass", {pos = pos, gain = 0.5})
end
collapse.try_escape_or_destroy = try_escape_or_destroy

-- 5. 單點擾動檢查：懸空掉落 → 安息角滑動（不連鎖）
-- 某格是否為實心（walkable；未載入視為實心）
local function is_solid_at(p)
    local n = core.get_node_or_nil(p)
    if not n then return true end
    local d = core.registered_nodes[n.name]
    return not d or d.walkable ~= false
end

-- 碎石：下方懸空就落下，否則依安息角滑動。
-- 完整岩石：這裡不處理。是否懸空由支撐判定（support.lua，連通性）決定；
--           破壞由軸差破壞準則決定。
check_stability_and_move = function(pos)
    local node = core.get_node_or_nil(pos)
    if not node or not is_rock(node.name) then return end

    if rockmech.is_rubble(node.name) then
        local below = {x=pos.x, y=pos.y-1, z=pos.z}
        if passable(core.get_node(below).name) then
            fall_with_slope_settle(pos)
        else
            granular_settle(pos)
        end
    end
end

-- 6. 區域更新：僅開挖點周圍5格，判定但不再連鎖
update_affected_area = function(center_pos)
    if not center_pos then return end
    local cp = {x=math.floor(center_pos.x), y=math.floor(center_pos.y), z=math.floor(center_pos.z)}

    for dx = -5, 5 do
        for dy = -5, 5 do
            for dz = -5, 5 do
                local pos = {x=cp.x+dx, y=cp.y+dy, z=cp.z+dz}
                if vector.distance(pos, cp) <= 5 then
                    check_stability_and_move(pos)
                end
            end
        end
    end
end
collapse.update_affected_area = update_affected_area

-- 7. 軸差破壞（模型見 failure.lua）
-- 開挖觸發 → 同一 tick 內合併 → VoxelManip 一次讀取 → 純函式評估 →
-- 破壞的臨空格以 try_escape_or_destroy 剝落 → 有限輪數連鎖重算
local cfg = rockmech.cfg
local fcfg = cfg.failure
local stress = rockmech.stress
local failure = rockmech.failure

local solid_of, weight_of, lith_of, bonded_of, rubble_of
local function build_cid_maps()
    if solid_of then return end
    solid_of, weight_of, lith_of, bonded_of, rubble_of = {}, {}, {}, {}, {}
    -- 碎石：cid → 級數比例（側面的碎石只給側壓，見 failure.lua）
    for _, n in ipairs(rockmech.rubble_nodes) do
        rubble_of[core.get_content_id(n)] = (rockmech.rubble_level[n] or rockmech.RUBBLE_LEVELS) / rockmech.RUBBLE_LEVELS
    end
    for name, def in pairs(core.registered_nodes) do
        local cid = core.get_content_id(name)
        solid_of[cid] = def.walkable ~= false
        if def.walkable ~= false then
            weight_of[cid] = fcfg.gamma_other
            -- 鍵結：天然的實心地層（完整岩石、土、礦石…）；碎石、沙等鬆散材料
            -- 以及玩家建築（is_ground_content = false）不鍵結
            local groups = def.groups or {}
            if def.is_ground_content ~= false and (groups.rockmech_rubble or 0) == 0
                    and (groups.falling_node or 0) == 0 then
                bonded_of[cid] = true
            end
        end
    end
    -- 未載入區塊：側向視為實心（保守），但不計入荷重
    local c_ignore = core.get_content_id("ignore")
    solid_of[c_ignore] = true
    weight_of[c_ignore] = nil
    for _, nodename in ipairs(rockmech.lith_nodes) do
        local key = rockmech.lith_of_node[nodename].name
        local cid = core.get_content_id(nodename)
        lith_of[cid] = key
        weight_of[cid] = cfg.lithologies[key].gamma
    end
end

-- 讀取 [minp, maxp] 成為 failure.lua / support.lua 的網格格式。
-- 預設往上多讀 overburden_scan 公尺以累計柱狀荷重；no_overburden 時不多讀。
function collapse.read_grid(minp, maxp, no_overburden)
    build_cid_maps()
    local vm = core.get_voxel_manip()
    local top = {x = maxp.x, y = maxp.y + (no_overburden and 0 or fcfg.overburden_scan), z = maxp.z}
    local emin, emax = vm:read_from_map(minp, top)
    local data = vm:get_data()
    local p2 = vm:get_param2_data()   -- 岩性格的 param2 1..100 = 該格的 GSI（rockmass.lua）
    vm:close()
    return {
        data = data, p2 = p2,
        ox = emin.x, oy = emin.y, oz = emin.z,
        nx = emax.x - emin.x + 1, ny = emax.y - emin.y + 1, nz = emax.z - emin.z + 1,
        solid_of = solid_of, weight_of = weight_of, lith_of = lith_of, bonded_of = bonded_of,
        rubble_of = rubble_of,
        -- 實際需要的範圍（failure.compute_loads 只算這些欄）
        req = {x1 = minp.x, x2 = maxp.x, z1 = minp.z, z2 = maxp.z, y1 = minp.y, y2 = maxp.y},
    }
end

-- 開挖前的初始應力：往上掃描 pos 正上方的柱子，最高的天然實心格（鍵結：岩石、土、礦）
-- 視為地表，其間的空隙與碎石視為原本是岩石。每段讀 overburden_scan 公尺，
-- 直到一整段都沒有天然實心格或到達 initial_scan_max；仍未到頂（或碰到未載入區塊）時
-- 假設岩層連續到 y0（同 failure.compute_loads）。
-- 回傳 stress.initial_from 的表，另加 top_y（地表高程）、extrapolated（是否外插）
function collapse.initial_stress(pos, lith)
    build_cid_maps()
    local c_ignore = core.get_content_id("ignore")
    local step = math.max(16, fcfg.overburden_scan)
    local column, n = {}, 0
    local cont = false
    local vm = core.get_voxel_manip()
    while n < fcfg.initial_scan_max do
        local y1 = pos.y + n + 1
        local y2 = pos.y + math.min(n + step, fcfg.initial_scan_max)
        local emin, emax = vm:read_from_map({x = pos.x, y = y1, z = pos.z}, {x = pos.x, y = y2, z = pos.z})
        local area = VoxelArea(emin, emax)
        local data = vm:get_data()
        local any = false
        cont = false
        for y = y1, y2 do
            local cid = data[area:index(pos.x, y, pos.z)]
            n = n + 1
            if cid == c_ignore then
                cont = true
                break
            end
            if bonded_of[cid] then
                column[n] = weight_of[cid] or fcfg.gamma_other
                any = true
            end
        end
        if cont then break end
        if not any then break end
        cont = column[n] ~= nil and n >= fcfg.initial_scan_max
    end
    vm:close()
    local extra = 0
    if cont then extra = math.max(0, cfg.surface_y - (pos.y + n)) end
    local sv, h = stress.overburden(column, n, lith.gamma, extra)
    local st = stress.initial_from(cfg, sv, h)
    st.top_y = pos.y + h
    st.extrapolated = extra > 0
    return st
end

local wcfg = cfg.weakness

-- 穿過格 (x,y,z) 的節理組（與貼圖跡線相同的平面與延續性判定，不受貼圖 2 條上限限制）
local function joints_at(x, y, z, sets)
    sets = sets or rockmech.get_joint_sets()
    local tr = rockmech.jointtex.cell_traces(rockmech.joints, sets, x, y, z, #sets)
    local out = {}
    for k = 1, #tr do out[k] = sets[tr[k].set] end
    return out
end
collapse.joints_at = joints_at

-- 岩體強度（Hoek-Brown、GSI、相似比 N）。舊設定 strength_scale 仍乘在 σci 上
local rock = rockmech.rockmass.new(cfg, {ucs_scale = fcfg.strength_scale})
local model_n = rock.N
collapse.rock = rock

-- 懸臂斷裂用：格 i 的岩體張力強度 (MPa)
local function tensile_at(g, i, key)
    if not key then return cfg.overhang.tensile_other / model_n end
    local ly = math.floor((i - 1) / g.nx) % g.ny
    return rock.at(key, g.oy + ly, g.p2 and g.p2[i]).sigt
end

-- detail = true：不做前置篩選（HUD／資訊頁／羅盤顯示完整的弱面資訊）
-- 逐格節理滑動（Jaeger／楔形）只用間距 ≤ weakness.max_spacing 的組（遍在節理的概念）；
-- 間距較大的明確節理由塊體力學處理（關鍵塊體、稜柱、懸臂），避免同一組節理被重複計算
local weak_src, weak_list
local function weak_sets()
    local sets = rockmech.get_joint_sets()
    if weak_src ~= sets then
        weak_src, weak_list = sets, {}
        for _, js in ipairs(sets) do
            if (js.spacing_eff or js.spacing) <= wcfg.max_spacing then weak_list[#weak_list + 1] = js end
        end
    end
    return weak_list
end
collapse.weak_sets = weak_sets

function collapse.failure_params(detail)
    return {
        detail = detail,
        joint_sets = weak_sets(),
        axial = fcfg.enabled,
        weakness = wcfg.enabled and {c = wcfg.c / model_n, tanphi = math.tan(math.rad(wcfg.phi)),
            daylight = wcfg.daylight, wedge = wcfg.wedge, lat_cos = math.cos(math.rad(wcfg.lateral_limit))} or nil,
        joints_at = joints_at,
        surface_y = cfg.surface_y, k0 = cfg.k0, lithologies = cfg.lithologies,
        window = fcfg.window,
        rock = rock,
        rubble_k = 1 - math.sin(math.rad(cfg.slope.angle)), rubble_gamma = fcfg.gamma_other,
        KH = cfg.KH, Kh = cfg.Kh, sH0 = cfg.sH0, sh0 = cfg.sh0, sH_azimuth = cfg.sH_azimuth,
    }
end

-- 盒子工具
-- 開挖前狀態（只有開挖造成的惡化才破壞）
-- changes = {map = {[座標] = true}, list = {{x, y, z, cid}...}}：本次觸發中改變的格與其原本的方塊。
-- 同一格多次改變時保留最早的（= 開挖前）。
local icfg = cfg.induced
local function new_changes() return {map = {}, list = {}} end
local function name_cid(name)
    if name and core.registered_nodes[name] then return core.get_content_id(name) end
end
-- r：這個改變的影響範圍（玩家造成 = rockmech_failure_radius；物理造成 = 延伸範圍）
local function add_change(chg, p, name, cid, r)
    local k = pos_key(p)
    local e = chg.map[k]
    if e then
        if r and (not e.r or r > e.r) then e.r = r end
        return
    end
    e = {x = p.x, y = p.y, z = p.z, cid = cid or name_cid(name), r = r}
    chg.map[k] = e
    chg.list[#chg.list + 1] = e
end
local function merge_changes(dst, src)
    for _, c in ipairs(src.list) do add_change(dst, c, nil, c.cid, c.r) end
end

-- 影響範圍：玩家造成的改變 / 物理造成的移除（延伸）
local function primary_radius() return fcfg.radius end
local function secondary_radius()
    return math.max(1, math.floor(fcfg.radius * fcfg.secondary_factor + 0.5))
end
collapse.secondary_radius = secondary_radius
-- 把網格還原成開挖前（就地修改）。回傳復原函式
local function restore_grid(grid, list)
    local nx, ny, nz = grid.nx, grid.ny, grid.nz
    local saved = {}
    for _, c in ipairs(list) do
        if c.cid then
            local lx, ly, lz = c.x - grid.ox, c.y - grid.oy, c.z - grid.oz
            if lx >= 0 and ly >= 0 and lz >= 0 and lx < nx and ly < ny and lz < nz then
                local i = 1 + lx + ly * nx + lz * nx * ny
                saved[#saved + 1] = {i, grid.data[i]}
                grid.data[i] = c.cid
            end
        end
    end
    grid.L = nil   -- failure.compute_loads 的快取
    return function()
        for k = #saved, 1, -1 do grid.data[saved[k][1]] = saved[k][2] end
        grid.L = nil
    end
end

local function cube(c, r)
    return {{x = c.x - r, y = c.y - r, z = c.z - r}, {x = c.x + r, y = c.y + r, z = c.z + r}}
end
local function union(boxes)
    local a = {x = math.huge, y = math.huge, z = math.huge}
    local b = {x = -math.huge, y = -math.huge, z = -math.huge}
    for _, bx in ipairs(boxes) do
        for _, k in ipairs({"x", "y", "z"}) do
            a[k] = math.min(a[k], bx[1][k]); b[k] = math.max(b[k], bx[2][k])
        end
    end
    return a, b
end
local function volume(a, b)
    return (b.x - a.x + 1) * (b.y - a.y + 1) * (b.z - a.z + 1)
end

-- 評估一組盒子（不修改地圖）。回傳 failed（由上往下）, stats, ms
-- 盒子分散時（聯集體積遠大於各盒總和）逐盒讀取，避免讀入巨大區域。
function collapse.evaluate_failure_boxes(boxes)
    local t0 = core.get_us_time()
    local params = collapse.failure_params()
    local margin = fcfg.window + 1
    local groups = {boxes}
    local ua, ub = union(boxes)
    local sum = 0
    for _, bx in ipairs(boxes) do sum = sum + volume(bx[1], bx[2]) end
    if #boxes > 1 and volume(ua, ub) > 2 * sum then
        groups = {}
        for _, bx in ipairs(boxes) do groups[#groups + 1] = {bx} end
    end

    local all, seen = {}, {}
    local stats = {evaluated = 0, failed = 0, min_fs = math.huge}
    for _, grp in ipairs(groups) do
        local a, b = union(grp)
        local grid = collapse.read_grid(
            {x = a.x - margin, y = a.y - margin, z = a.z - margin},
            {x = b.x + margin, y = b.y + margin, z = b.z + margin})
        local failed, st = failure.evaluate_boxes(grid, params, grp)
        stats.evaluated = stats.evaluated + st.evaluated
        if st.min_fs < stats.min_fs then
            stats.min_fs, stats.min_fs_pos, stats.min_fs_state =
                st.min_fs, st.min_fs_pos, st.min_fs_state
        end
        for _, f in ipairs(failed) do
            local k = pos_key(f)
            if not seen[k] then
                seen[k] = true
                all[#all + 1] = f
            end
        end
    end
    table.sort(all, function(u, v) return u.y > v.y end)
    stats.failed = #all
    return all, stats, (core.get_us_time() - t0) / 1000
end

-- 以中心點與半徑評估（指令／除錯用）
function collapse.evaluate_failure(centers, r)
    local boxes = {}
    for _, c in ipairs(centers) do boxes[#boxes + 1] = cube(c, r) end
    return collapse.evaluate_failure_boxes(boxes)
end

-- 破壞格：原地換成碎石（swap_node 不觸發 on_destruct）。碎石仍是實心、提供側向
-- 支撐，避免在岩體內部產生空洞；之後是否移動交給懸空掉落／安息角滑動。
-- 目前正在處理的剝落連鎖輪數（0 = 不在剝落處理中）。物理造成的移除依此決定後續檢查的輪數
local fail_gen = 0

function collapse.apply_failure(failed, round)
    local prev_gen = fail_gen
    fail_gen = round or fcfg.max_cascade
    physics_updating = true
    for _, f in ipairs(failed) do
        local p = {x = f.x, y = f.y, z = f.z}
        local name = core.get_node(p).name
        if rockmech.lith_of_node[name] then
            core.swap_node(p, {name = rockmech.rubble_for(name)})
            debris(p, rockmech.rubble_for(name), 10)
        end
    end
    -- 由上往下（failed 已排序）判定掉落／滑動
    for _, f in ipairs(failed) do
        check_stability_and_move({x = f.x, y = f.y, z = f.z})
    end
    physics_updating = false
    fail_gen = prev_gen
end

-- 只保留開挖造成的破壞（穩定 → 不穩定）：開挖前就會破壞、且對著天然空氣露出來的格視為既有狀態。
-- 回傳 保留的 failed, 略過的格數
-- 開挖過的位置（岩石或碎石被移除過；存在世界的 mod storage，鍵為 "ex:x,y,z"）。
-- 用來分辨一格岩石是對著天然空氣、還是對著開挖出來的空間露出來
local ex_storage = core.get_mod_storage()
local EX_PREFIX = "ex:"
local excavated = {}
for k in pairs(ex_storage:to_table().fields) do
    if k:sub(1, #EX_PREFIX) == EX_PREFIX then excavated[k:sub(#EX_PREFIX + 1)] = true end
end
function collapse.mark_excavated(p)
    local k = pos_key(vector.round(p))
    if not excavated[k] then
        excavated[k] = true
        ex_storage:set_string(EX_PREFIX .. k, "1")
    end
end
function collapse.unmark_excavated(p)
    local k = pos_key(vector.round(p))
    if excavated[k] then
        excavated[k] = nil
        ex_storage:set_string(EX_PREFIX .. k, "")
    end
end
-- 這一格是否對著開挖出來的空間露出來（相鄰的開挖過位置現在是非實心）
local EX_NB = {{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1}}
local function exposed_to_excavation(p)
    for _, d in ipairs(EX_NB) do
        local q = {x = p.x + d[1], y = p.y + d[2], z = p.z + d[3]}
        if excavated[pos_key(q)] then
            local def = core.registered_nodes[core.get_node(q).name]
            if not def or def.walkable == false then return true end
        end
    end
    return false
end
collapse.exposed_to_excavation = exposed_to_excavation

local function filter_induced_failures(failed, changes)
    if #failed == 0 then return failed, 0 end
    local t = {}
    for _, f in ipairs(failed) do t[#t + 1] = cube(f, 0) end
    local a, b = union(t)
    local m = fcfg.window + 1
    local grid = collapse.read_grid(vector.subtract(a, m), vector.add(b, m))
    local params = collapse.failure_params()
    restore_grid(grid, changes.list)
    local out, skipped = {}, 0
    for _, f in ipairs(failed) do
        local before = failure.cell_state(grid, f.x, f.y, f.z, params)
        -- 開挖前就會破壞，而且是對著天然空氣露出來 → 既有狀態。
        -- 對著開挖出來的空間露出來的不算（例如碎石滑走後露出、當時沒被檢查到的岩壁）
        if before and before.fails and not exposed_to_excavation(f) then
            skipped = skipped + 1
        else
            out[#out + 1] = f
        end
    end
    return out, skipped
end

-- 單一佇列：所有觸發（開挖、連鎖）合併成同一批處理
local queue_boxes, queue_round = {}, 0
local queue_changes = new_changes()
local queue_scheduled = false
local process_queue

local function enqueue(box, round, changes)
    if changes then merge_changes(queue_changes, changes) end
    queue_boxes[#queue_boxes + 1] = box
    if round > queue_round then queue_round = round end
    if queue_scheduled then return end
    queue_scheduled = true
    core.after(0, process_queue)
end

process_queue = function()
    queue_scheduled = false
    local boxes, round, changes = queue_boxes, queue_round, queue_changes
    queue_boxes, queue_round, queue_changes = {}, 0, new_changes()
    -- 遊戲中關閉破壞準則（軸差與弱面皆關）時，進行中的連鎖也一併停止
    if #boxes == 0 or not (fcfg.enabled or wcfg.enabled) then return end

    local failed, stats, ms = collapse.evaluate_failure_boxes(boxes)
    local skipped = 0
    if icfg.enabled and #failed > 0 then
        local t0 = core.get_us_time()
        failed, skipped = filter_induced_failures(failed, changes)
        ms = ms + (core.get_us_time() - t0) / 1000
    end
    if skipped > 0 then
        core.log("action", ("[rockmech] 破壞 第 %d 輪：%d 格開挖前就 FS ≤ 1，視為既有狀態不處理")
            :format(round, skipped))
    end
    if ms > fcfg.budget_ms then
        core.log("warning", ("[rockmech] 軸差破壞檢查 %.1f ms（預算 %g ms），第 %d 輪、%d 盒、評估 %d 格")
            :format(ms, fcfg.budget_ms, round, #boxes, stats.evaluated))
    end
    if #failed == 0 then return end

    local n_slip = 0
    for _, f in ipairs(failed) do
        if f.state.fails_slip and not f.state.fails_axial then n_slip = n_slip + 1 end
    end
    core.log("action", ("[rockmech] 破壞 第 %d 輪：%d 格（其中節理滑動 %d）（%.1f ms）"):format(
        round, #failed, n_slip, ms))
    -- 下一輪的「開挖」= 這一輪剝落的格（記下剝落前的方塊；物理造成 → 延伸範圍）
    local next_changes = new_changes()
    for _, f in ipairs(failed) do add_change(next_changes, f, core.get_node(f).name, nil, secondary_radius()) end
    collapse.apply_failure(failed, round)

    if round >= fcfg.max_cascade then
        core.log("action", ("[rockmech] 軸差破壞連鎖達上限 %d 輪，停止"):format(fcfg.max_cascade))
        return
    end
    -- 下一輪只檢查破壞格附近（外包盒 ± 延伸範圍）
    local a, b = union((function()
        local t = {}
        for _, f in ipairs(failed) do t[#t + 1] = cube(f, 0) end
        return t
    end)())
    local r2 = secondary_radius()
    local next_box = {
        {x = a.x - r2, y = a.y - r2, z = a.z - r2},
        {x = b.x + r2, y = b.y + r2, z = b.z + r2},
    }
    core.after(fcfg.cascade_delay, function()
        local prev_gen = fail_gen
        fail_gen = round
        physics_updating = true
        for _, f in ipairs(failed) do
            -- 剝落後上方可能懸空：沿用懸空掉落／滑動判定
            check_stability_and_move({x = f.x, y = f.y + 1, z = f.z})
        end
        physics_updating = false
        fail_gen = prev_gen
        enqueue(next_box, round + 1, next_changes)
    end)
end

-- 開挖觸發：同一 tick 內的多次觸發合併成一次檢查。
-- prev：該格改變前的方塊名稱（省略時取目前的方塊；在 on_destruct 中即為被移除的方塊）
-- r：檢查半徑（省略為玩家造成的範圍）；round：連鎖輪數（物理造成的觸發從較後面的輪數開始，
-- 讓連鎖總長度有上限）
function collapse.queue_failure_check(pos, prev, r, round)
    if not (fcfg.enabled or wcfg.enabled) then return end
    local p = vector.round(pos)
    r = r or primary_radius()
    add_change(queue_changes, p, prev or core.get_node(p).name, nil, r)
    enqueue(cube(p, r), round or 1)
    if not round and r == primary_radius() and collapse.queue_mass_check then collapse.queue_mass_check(p) end
end

-- 8. 支撐判定（模型見 support.lua）
-- 移除方塊 → 同一 tick 合併 → VoxelManip 一次讀取 → 純函式找懸空群 →
-- 懸空群以原版 falling node 由下往上落下
local scfg = cfg.support
local pending_starts, support_scheduled = {}, false
local support_changes = new_changes()

-- 記下一批改變（爆破等以 VoxelManip 修改、不經過 on_destruct 者）：list = {{pos, name}...}
function collapse.record_changes(list)
    for _, c in ipairs(list) do
        local p = vector.round(c.pos)
        collapse.mark_excavated(p)
        add_change(support_changes, p, c.name, nil, primary_radius())
        add_change(queue_changes, p, c.name, nil, primary_radius())
    end
end
local NB6 = {{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1}}

local function face_jointed(x, y, z, axis)
    return rockmech.joints.face_joint(rockmech.get_joint_sets(), x, y, z, axis) ~= nil
end

-- 懸空格直剪（failure.shear_state）的參數
local shcfg = cfg.shear
local function cell_jointed(x, y, z)
    return #rockmech.jointtex.cell_traces(rockmech.joints, rockmech.get_joint_sets(), x, y, z, 1) > 0
end
function collapse.shear_params()
    return {
        lithologies = cfg.lithologies, rock = rock, surface_y = cfg.surface_y,
        cell_jointed = cell_jointed, shear = shcfg,
        tensile_other = cfg.overhang.tensile_other / model_n,
    }
end

-- 單格的直剪狀態（HUD／資訊頁用）
function collapse.shear_state(pos)
    local r = cfg.overhang.radius
    local grid = collapse.read_grid(vector.subtract(pos, r), vector.add(pos, r), true)
    return failure.shear_state(grid, pos.x, pos.y, pos.z, collapse.shear_params())
end

function collapse.overhang_params()
    local ocfg = cfg.overhang
    return {
        lithologies = cfg.lithologies, scale = ocfg.scale, tensile_at = tensile_at,
        gamma_other = cfg.failure.gamma_other, max_voxels = ocfg.max_voxels,
        face_jointed = ocfg.joints and face_jointed or nil,
    }
end

-- pos 周圍 ±r 臨空岩格的最小 FS（節理滑動、軸差），顯示用
function collapse.nearby_min_fs(pos, r)
    local w = 2 * fcfg.window + 1
    local grid = collapse.read_grid(vector.subtract(pos, r + w), vector.add(pos, r + w))
    return rockmech.failure.min_fs_in_box(grid, collapse.failure_params(true),
        {vector.subtract(pos, r), vector.add(pos, r)})
end

-- 關鍵塊體參數
local kcfg = cfg.keyblock
local function face_set(x, y, z, axis)
    return rockmech.joints.face_joint(rockmech.get_joint_sets(), x, y, z, axis)
end
-- 塊體接觸面的局部應力（MPa）：{σxx, σyy, σzz, σxz}，依網格快取
local stress_params
local function stress_at(g, x, y, z)
    local cache = g.stress_cache
    if not cache then cache = {}; g.stress_cache = cache end
    local i = failure.index(g, x, y, z)
    if not i then return nil end
    local v = cache[i]
    if v == nil then
        if not stress_params then
            stress_params = collapse.failure_params()
            stress_params.weakness = nil
        end
        local st = failure.cell_state(g, x, y, z, stress_params)
        v = st and {st.sx, st.sy, st.sz, st.sxz} or false
        cache[i] = v
    end
    return v or nil
end

function collapse.keyblock_params()
    return {
        stress_at = stress_at, clamp = kcfg.clamp, mass_clamp = kcfg.mass_clamp,
        face_set = face_set, joint_sets = rockmech.get_joint_sets(),
        c = kcfg.c * 1000 / model_n, tanphi = math.tan(math.rad(cfg.weakness.phi)),
        lithologies = cfg.lithologies, gamma_other = cfg.failure.gamma_other,
        max_cells = kcfg.max_cells,
    }
end

-- 單格所在的關鍵塊體（HUD／資訊頁用）：nil（非岩石）、false（與岩體相連）或岩塊
function collapse.keyblock_state(pos)
    local r = math.min(24, math.ceil(kcfg.max_cells ^ (1 / 3)) + 6)
    local grid = collapse.read_grid(vector.subtract(pos, r), vector.add(pos, r), true)
    return rockmech.keyblock.block_at(grid, collapse.keyblock_params(), pos.x, pos.y, pos.z)
end

local MODE_NAME = {fall = "落下", plane = "平面滑動", wedge = "楔形滑動"}
collapse.keyblock_mode_name = MODE_NAME

-- 單格的懸臂狀態（HUD／資訊頁／羅盤用；與懸臂斷裂同一個模型與範圍）
function collapse.overhang_state(pos)
    local r = cfg.overhang.radius
    local grid = collapse.read_grid(vector.subtract(pos, r), vector.add(pos, r), true)
    return rockmech.overhang.cell_state(grid, collapse.overhang_params(), pos.x, pos.y, pos.z)
end

local function run_support_check()
    support_scheduled = false
    local starts = pending_starts
    pending_starts = {}
    local changes = support_changes
    support_changes = new_changes()
    if #starts == 0 or not scfg.enabled then return end
    local n_existing = 0

    local t0 = core.get_us_time()
    local ocfg = cfg.overhang
    -- 讀取半徑：支撐判定與懸臂斷裂共用同一份網格，取兩者較大者
    local r = scfg.radius
    if ocfg.enabled and ocfg.radius > r then r = ocfg.radius end
    -- 起點分群：相距不超過 r 的歸同一群，各群分別讀取（避免遠處的觸發合併成巨大區域）
    local groups = {}
    for _, s in ipairs(starts) do
        local g
        for _, cand in ipairs(groups) do
            if s.x >= cand.a.x - r and s.x <= cand.b.x + r and s.y >= cand.a.y - r
                    and s.y <= cand.b.y + r and s.z >= cand.a.z - r and s.z <= cand.b.z + r then
                g = cand
                break
            end
        end
        if not g then
            g = {a = {x = s.x, y = s.y, z = s.z}, b = {x = s.x, y = s.y, z = s.z}, starts = {}}
            groups[#groups + 1] = g
        end
        g.starts[#g.starts + 1] = s
        for _, k in ipairs({"x", "y", "z"}) do
            g.a[k] = math.min(g.a[k], s[k]); g.b[k] = math.max(g.b[k], s[k])
        end
    end

    local comps, stats = {}, {visited = 0}
    local slides = {}      -- 關鍵塊體滑動（沿滑動方向移出）
    local n_overhang, n_shear = 0, 0
    local oparams = collapse.overhang_params()
    for _, g in ipairs(groups) do
        local grid = collapse.read_grid(
            {x = g.a.x - r, y = g.a.y - r, z = g.a.z - r},
            {x = g.b.x + r, y = g.b.y + r, z = g.b.z + r}, true)
        local c, st = rockmech.support.find_unsupported(grid, g.starts, scfg.max_voxels)
        stats.visited = stats.visited + st.visited
        local og = {}
        if ocfg.enabled then
            og = rockmech.overhang.find_failing_local(grid, oparams, g.starts)
            -- 被節理切離（FS 0）的群：節理不傳張力，但可能被周圍岩塊卡住、或被現地應力夾住。
            -- 交給塊體分析（含應力夾持）：卡住或 FS ≥ 1 就留在原位
            if kcfg.enabled and #og > 0 then
                local kp0 = collapse.keyblock_params()
                local keep, n_held = {}, 0
                for _, comp in ipairs(og) do
                    if (comp.fs or 0) <= 0 and #comp.cells <= kcfg.max_cells then
                        local r = rockmech.keyblock.analyze_group(grid, kp0, comp.cells)
                        if r.fs >= 1 then
                            n_held = n_held + 1
                        else
                            keep[#keep + 1] = comp
                        end
                    else
                        keep[#keep + 1] = comp
                    end
                end
                if n_held > 0 then
                    core.log("action", ("[rockmech] 懸臂：%d 群被節理切離但塊體分析穩定（卡住或被應力夾持），留在原位")
                        :format(n_held))
                end
                og = keep
            end
        end
        -- 只有開挖造成的才掉落（穩定 → 不穩定）：開挖前就會斷（0 < FS < 1）的群不處理。
        -- 完全懸空、或 FS = 0 的一律掉落
        if icfg.enabled and (#c > 0 or #og > 0) then
            local fs_after = {}
            for k, comp in ipairs(og) do fs_after[k] = comp.fs or 0 end
            local undo = restore_grid(grid, changes.list)
            -- 完全懸空的群一律掉落（不可能平衡，例如洞穴生成留下的懸空岩塊）
            local keep_c = c
            local keep_og = {}
            local query = rockmech.overhang.make_query(grid, oparams)
            -- 玩家直接造成的改變（挖掘、放置、爆破）的位置
            local player_changes = {}
            for _, ch in ipairs(changes.list) do
                if ch.r == primary_radius() then player_changes[#player_changes + 1] = ch end
            end
            -- 群是否被玩家直接挖到：改變的格就在群裡，或與群的格面相鄰
            local function touched(comp)
                if #player_changes == 0 then return false end
                local set = {}
                for _, p in ipairs(comp.cells) do set[pos_key(p)] = true end
                for _, ch in ipairs(player_changes) do
                    if set[pos_key(ch)] then return true end
                    for _, d in ipairs(NB6) do
                        if set[pos_key({x = ch.x + d[1], y = ch.y + d[2], z = ch.z + d[3]})] then return true end
                    end
                end
                return false
            end
            for k, comp in ipairs(og) do
                local p = comp.cells[1]
                local before = query(p.x, p.y, p.z)
                -- FS = 0（被節理切離、碰不到支撐）一律掉落：強度再高也不可能平衡
                if before >= 1 or fs_after[k] <= 0 then
                    keep_og[#keep_og + 1] = comp
                    core.log("action", ("[rockmech] 懸臂斷裂（開挖造成）：%d 格，整群 FS %.3f → %.3f")
                        :format(#comp.cells, before, fs_after[k]))
                elseif #comp.cells <= icfg.touch_max and touched(comp) then
                    -- 既有的不穩定，但被玩家直接挖到、而且不大：一樣掉落
                    keep_og[#keep_og + 1] = comp
                    core.log("action", ("[rockmech] 懸臂斷裂（既有不穩定、被直接挖到）：%d 格，整群 FS %.3f → %.3f")
                        :format(#comp.cells, before, fs_after[k]))
                else
                    n_existing = n_existing + 1
                end
            end
            undo()
            c, og = keep_c, keep_og
        end
        local taken = {}
        for _, comp in ipairs(c) do
            comps[#comps + 1] = comp
            for _, p in ipairs(comp.cells) do taken[pos_key(p)] = true end
        end
        -- 懸臂／頂板彎曲斷裂：從根部整段斷開（與上面的懸空群不重複）
        for _, comp in ipairs(og) do
            local cells = {}
            for _, p in ipairs(comp.cells) do
                if not taken[pos_key(p)] then cells[#cells + 1] = p; taken[pos_key(p)] = true end
            end
            if #cells > 0 then
                comps[#comps + 1] = {cells = cells, grid = grid}
                n_overhang = n_overhang + 1
            end
        end
        -- 懸空格直剪：底下懸空的岩格。改變處會影響水平距離 max_span 內的懸空格（路徑可能經過改變處），
        -- 範圍 = 所有改變格（含各自的影響半徑）的外框，水平再往外 max_span
        if shcfg.enabled and #changes.list > 0 then
            local sp = collapse.shear_params()
            local gnx, gny, gnz = grid.nx, grid.ny, grid.nz
            local gsy, gsz = gnx, gnx * gny
            local gdata, gsolid, glith = grid.data, grid.solid_of, grid.lith_of
            local bx1, by1, bz1, bx2, by2, bz2 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
            for _, ch in ipairs(changes.list) do
                local rr = ch.r or primary_radius()
                bx1 = math.min(bx1, ch.x - rr); bx2 = math.max(bx2, ch.x + rr)
                by1 = math.min(by1, ch.y - rr); by2 = math.max(by2, ch.y + rr)
                bz1 = math.min(bz1, ch.z - rr); bz2 = math.max(bz2, ch.z + rr)
            end
            local ms = shcfg.max_span
            bx1, bx2 = math.max(bx1 - ms, grid.ox + 1), math.min(bx2 + ms, grid.ox + gnx - 2)
            bz1, bz2 = math.max(bz1 - ms, grid.oz + 1), math.min(bz2 + ms, grid.oz + gnz - 2)
            by1, by2 = math.max(by1, grid.oy + 1), math.min(by2, grid.oy + gny - 2)
            local cand = {}
            for z = bz1, bz2 do for y = by1, by2 do for x = bx1, bx2 do
                local i = 1 + (x - grid.ox) + (y - grid.oy) * gsy + (z - grid.oz) * gsz
                if glith[gdata[i]] and not gsolid[gdata[i - gsy]] and not taken[pos_key({x = x, y = y, z = z})] then
                    cand[#cand + 1] = {x = x, y = y, z = z}
                end
            end end end
            local fail = {}
            for _, q in ipairs(cand) do
                local s = failure.shear_state(grid, q.x, q.y, q.z, sp)
                if s and s.fs < 1 then fail[#fail + 1] = {pos = q, after = s} end
            end
            -- 只有開挖造成的才剪斷（穩定 → 不穩定）；FS = 0（沒有連著岩體）一律掉
            if icfg.enabled and #fail > 0 then
                local undo = restore_grid(grid, changes.list)
                local keep = {}
                for _, f in ipairs(fail) do
                    -- 底下是開挖出來的空間：一定是開挖造成的（開挖前這格不懸空）
                    local below = {x = f.pos.x, y = f.pos.y - 1, z = f.pos.z}
                    local b = not excavated[pos_key(below)]
                        and failure.shear_state(grid, f.pos.x, f.pos.y, f.pos.z, sp)
                    if not b or b.fs >= 1 or f.after.fs <= 0 then keep[#keep + 1] = f
                    else n_existing = n_existing + 1 end
                end
                undo()
                fail = keep
            end
            -- 相鄰的剪斷格合成一群落下
            local fset = {}
            for _, f in ipairs(fail) do fset[pos_key(f.pos)] = f end
            local n_sh = 0
            for _, f in ipairs(fail) do
                local k0 = pos_key(f.pos)
                if fset[k0] then
                    local cells, stack = {}, {f.pos}
                    fset[k0] = nil
                    local minfs = f.after.fs
                    while #stack > 0 do
                        local p = stack[#stack]; stack[#stack] = nil
                        cells[#cells + 1] = p
                        taken[pos_key(p)] = true
                        for _, d in ipairs(NB6) do
                            local q = {x = p.x + d[1], y = p.y + d[2], z = p.z + d[3]}
                            local fq = fset[pos_key(q)]
                            if fq then
                                fset[pos_key(q)] = nil
                                if fq.after.fs < minfs then minfs = fq.after.fs end
                                stack[#stack + 1] = q
                            end
                        end
                    end
                    table.sort(cells, function(u, v) return u.y < v.y end)
                    comps[#comps + 1] = {cells = cells, grid = grid}
                    n_sh = n_sh + 1
                    core.log("action", ("[rockmech] 懸空直剪：%d 格剪斷落下（最小 FS %.3f；例：Q %.0f kN、R %.0f kN、到支撐 %d 格、斷面 %d 格）")
                        :format(#cells, minfs, f.after.Q, f.after.R, f.after.n, f.after.hs))
                end
            end
            n_shear = n_shear + n_sh
        end
        -- 關鍵塊體：被節理與臨空面圍住的岩塊，以重力判斷落下／滑動
        if kcfg.enabled then
            local kp = collapse.keyblock_params()
            -- 起點：支撐判定的起點，加上每個改變格周圍其影響範圍（玩家 6 m／物理延伸 3 m）內
            -- 有臨空面的岩格（完全被包在岩體裡的岩塊不可能滑出）
            local kstarts = {}
            for _, s in ipairs(g.starts) do kstarts[#kstarts + 1] = s end
            local gnx, gny, gnz = grid.nx, grid.ny, grid.nz
            local gsy, gsz = gnx, gnx * gny
            local gdata, gbond, gsolid, grub = grid.data, grid.bonded_of, grid.solid_of, grid.rubble_of
            local kseen = {}
            for _, c in ipairs(changes.list) do
                local rr = c.r or primary_radius()
                for z = c.z - rr, c.z + rr do for y = c.y - rr, c.y + rr do for x = c.x - rr, c.x + rr do
                    local lx, ly, lz = x - grid.ox, y - grid.oy, z - grid.oz
                    if lx >= 1 and ly >= 1 and lz >= 1 and lx <= gnx - 2 and ly <= gny - 2 and lz <= gnz - 2 then
                        local i = 1 + lx + ly * gsy + lz * gsz
                        if not kseen[i] and gbond[gdata[i]] then
                            kseen[i] = true
                            local function open(j) return not gsolid[gdata[j]] or grub[gdata[j]] ~= nil end
                            if open(i + 1) or open(i - 1) or open(i + gsz) or open(i - gsz)
                                    or not gsolid[gdata[i + gsy]] or not gsolid[gdata[i - gsy]] then
                                kstarts[#kstarts + 1] = {x = x, y = y, z = z}
                            end
                        end
                    end
                end end end
            end
            local blocks = rockmech.keyblock.find_blocks(grid, kp, kstarts)
            -- 關鍵塊體不套用「只算開挖造成」：已被節理切開、可自由滑出且 FS < 1 的岩塊
            -- 不可能靠強度低估來解釋成平衡，被判定碰到就滑出
            local failing = {}
            for _, b in ipairs(blocks) do
                if b.fs < 1 and not taken[pos_key(b.cells[1])] then failing[#failing + 1] = b end
            end
            for _, b in ipairs(failing) do
                for _, p in ipairs(b.cells) do taken[pos_key(p)] = true end
                core.log("action", ("[rockmech] 關鍵塊體：%d 格（W %.0f kN）%s，FS %.2f")
                    :format(#b.cells, b.W, MODE_NAME[b.mode] or "?", b.fs))
                if b.mode == "fall" then
                    comps[#comps + 1] = {cells = b.cells, grid = grid}
                else
                    slides[#slides + 1] = b
                end
            end
        end
    end
    local ms = (core.get_us_time() - t0) / 1000
    if ms > scfg.budget_ms then
        core.log("warning", ("[rockmech] 支撐判定 %.1f ms（預算 %g ms），起點 %d、展開 %d 格")
            :format(ms, scfg.budget_ms, #starts, stats.visited))
    end
    if n_existing > 0 then
        core.log("action", ("[rockmech] 支撐判定：%d 群開挖前就會斷（0 < FS < 1），視為既有狀態不處理")
            :format(n_existing))
    end
    if #comps == 0 and #slides == 0 then return end

    local n, n_rigid = 0, 0
    local rfe = rockmech.rigidfall_entity
    physics_updating = true
    local n_stuck = 0
    -- 由下往上處理：下面的群先移走，疊在上面的群才算得出落下距離
    local function min_y(c)
        local m = math.huge
        for _, p in ipairs(c.cells) do if p.y < m then m = p.y end end
        return m
    end
    for _, c in ipairs(comps) do c.min_y = min_y(c) end
    table.sort(comps, function(a, b) return a.min_y < b.min_y end)
    local oparams_m = collapse.overhang_params()
    local n_merged = 0
    for _, c in ipairs(comps) do
        local done = false
        local dd = rfe and rockmech.rigidfall.drop_distance(c.cells, rfe.is_solid, 256)
        -- 被下方擋住：擋住它的若是懸空的岩體（不是坐在地面上），上面這段斷了以後重量壓在它身上。
        -- 下方那段承受的荷重由 t_l 變成 t_l + t_u：σb = 3γ(t_l + t_u)d²/t_l²，
        -- 即 FS_加載 = FS × t_l / (t_l + t_u)。FS_加載 < 1 → 它也撐不住，併進來一起掉（最多往下併 8 層）；
        -- 否則上面這段只是坐在穩固的下層上，保留原位
        local tries = 0
        while dd == 0 and c.grid and tries < 8 do
            tries = tries + 1
            local own = {}
            for _, p in ipairs(c.cells) do own[pos_key(p)] = true end
            local added = false
            for _, p in ipairs(c.cells) do
                local q = {x = p.x, y = p.y - 1, z = p.z}
                if not own[pos_key(q)] and rfe.is_solid(q.x, q.y, q.z) then
                    local seg, seg_fs, t_l = rockmech.overhang.segment_at(c.grid, oparams_m, q.x, q.y, q.z)
                    -- 壓在它上面的厚度：這一欄中屬於本群、連續疊在 q 上方的格數
                    local t_u = 0
                    while own[pos_key({x = q.x, y = q.y + 1 + t_u, z = q.z})] do t_u = t_u + 1 end
                    -- FS = ∞：它只是坐在更下層上的中間塊（由下層承擔）→ 一併帶下、繼續往下找
                    if seg and (seg_fs == math.huge or seg_fs * t_l / (t_l + t_u) < 1) then
                        for _, s in ipairs(seg) do
                            local k = pos_key(s)
                            if not own[k] and rockmech.lith_of_node[core.get_node(s).name] then
                                own[k] = true
                                c.cells[#c.cells + 1] = s
                                added = true
                            end
                        end
                    end
                end
            end
            if not added then break end
            n_merged = n_merged + 1
            table.sort(c.cells, function(u, v) return u.y < v.y end)
            dd = rockmech.rigidfall.drop_distance(c.cells, rfe.is_solid, 256)
        end
        -- 還是被擋住：擋住它的是撐得住的岩體（或地面、碎石）。坐在上面的那幾欄留下，
        -- 其餘懸空的部分從交界處斷開，照樣掉（剩下的若又被留下的欄擋住，再剔除，最多 6 次）
        if dd == 0 and #c.cells > 1 then
            local rest = c.cells
            for _ = 1, 6 do
                local own = {}
                for _, p in ipairs(rest) do own[pos_key(p)] = true end
                local blocked = {}
                for _, p in ipairs(rest) do
                    local q = {x = p.x, y = p.y - 1, z = p.z}
                    if not own[pos_key(q)] and rfe.is_solid(q.x, q.y, q.z) then blocked[p.x .. "," .. p.z] = true end
                end
                local nxt = {}
                for _, p in ipairs(rest) do
                    if not blocked[p.x .. "," .. p.z] then nxt[#nxt + 1] = p end
                end
                if #nxt == 0 or #nxt == #rest then break end
                rest = nxt
                local d2 = rockmech.rigidfall.drop_distance(rest, rfe.is_solid, 256)
                if d2 and d2 >= 1 then
                    core.log("action", ("[rockmech] 支撐判定：%d 格中有 %d 格坐在撐得住的岩體上而留下，其餘 %d 格斷開落下")
                        :format(#c.cells, #c.cells - #rest, #rest))
                    c.cells, dd = rest, d2
                    break
                end
            end
        end
        -- 完全動不了（正下方被群外、坐在地面上的實心格擋住）：不移除，避免移除後馬上落回原位又再觸發判定
        if dd == 0 then
            done = true
            n_stuck = n_stuck + 1
        -- 剛體整塊落下
        elseif scfg.rigid and rfe and #c.cells <= scfg.rigid_max then
            local d = dd
            if d and d >= 1 then
                local cells = {}
                for _, p in ipairs(c.cells) do
                    local name = core.get_node(p).name
                    if is_rock(name) then
                        cells[#cells + 1] = {x = p.x, y = p.y, z = p.z, name = name}
                    end
                end
                for _, p in ipairs(cells) do core.remove_node(p) end
                done = #cells == 0 or rfe.spawn(cells, d)
                if not done then
                    for _, p in ipairs(cells) do core.set_node(p, {name = p.name}) end
                end
                if done then n_rigid = n_rigid + 1 end
            end
        end
        -- 否則逐格（原版 falling node）
        if not done then
            n = n + #c.cells
            for _, p in ipairs(c.cells) do   -- 由低到高
                core.spawn_falling_node(p)
            end
        elseif dd ~= 0 then
            n = n + #c.cells
        end
    end
   -- 關鍵塊體沿節理滑動：每一格變成碎石外觀的翻滾落石，初速度沿滑動方向，
    -- 之後由落石的物理（碰撞、反彈、滾動）帶下坡，停下時放成碎石。
    -- 翻滾落石已達上限或被關閉時：原地變成碎石，再依安息角往下滑
    local rfx = rockmech.rockfall_entity
    for _, b in ipairs(slides) do
        local cells = {}
        for _, p in ipairs(b.cells) do
            local name = core.get_node(p).name
            -- 同一輪中已經落下／移走的格子（例如也屬於斷開落下的群）不再滑出
            if is_rock(name) then
                cells[#cells + 1] = {x = p.x, y = p.y, z = p.z,
                    rubble = rockmech.lith_of_node[name] and rockmech.rubble_for(name) or name}
            end
        end
        local cap = 0
        if rfx and rfx.can_spawn() then cap = cfg.rockfall.max_active - rfx.active_count() end
        if #cells <= cap then
            for _, p in ipairs(cells) do core.remove_node(p) end
            local m = b.dir
            for _, p in ipairs(cells) do
                local speed = 2 + math.random()
                rfx.spawn({x = p.x, y = p.y, z = p.z}, p.rubble, {
                    x = m.x * speed + (math.random() - 0.5) * 0.4,
                    y = m.y * speed,
                    z = m.z * speed + (math.random() - 0.5) * 0.4,
                })
            end
            core.log("action", ("[rockmech] 關鍵塊體滑出：%d 格，以翻滾落石沿 (%.2f,%.2f,%.2f) 滾落")
                :format(#cells, m.x, m.y, m.z))
        else
            for _, p in ipairs(cells) do core.swap_node(p, {name = p.rubble}) end
            table.sort(cells, function(u, v) return u.y < v.y end)
            for _, p in ipairs(cells) do check_stability_and_move(p) end
            core.log("action", ("[rockmech] 關鍵塊體滑出：%d 格（翻滾落石已達上限），原地變成碎石"):format(#cells))
        end
        n = n + #cells
    end
    if n_merged > 0 then
        core.log("action", ("[rockmech] 支撐判定：%d 次把下方懸空、撐不住的岩體一併帶下"):format(n_merged))
    end
    if n_stuck > 0 then
        core.log("action", ("[rockmech] 支撐判定：%d 群判定會掉但正下方被擋住、動不了，保留原位"):format(n_stuck))
    end
    -- 群上方若有碎石等，可能因此懸空
    for _, c in ipairs(comps) do
        for _, p in ipairs(c.cells) do
            check_stability_and_move({x = p.x, y = p.y + 1, z = p.z})
        end
    end
    physics_updating = false
    core.log("action", ("[rockmech] 支撐判定：%d 群落下（懸臂斷裂 %d 群；懸空直剪 %d 群；整塊落下 %d 群）、共 %d 格（%.1f ms，展開 %d 格）")
        :format(#comps, n_overhang, n_shear, n_rigid, n, ms, stats.visited))
end

-- 剛體落地後：碎石依安息角判定
function collapse.after_rigid_land(placed)
    -- 落地碎屑：只在底部的格子（正下方不是同一群）噴
    local own = {}
    for _, it in ipairs(placed) do own[pos_key(it.pos)] = true end
    for _, it in ipairs(placed) do
        if not own[pos_key({x = it.pos.x, y = it.pos.y - 1, z = it.pos.z})] then
            debris(it.pos, rockmech.rubble_for(it.name), 5)
        end
    end
    physics_updating = true
    for _, it in ipairs(placed) do
        if rockmech.is_rubble(it.name) then
            check_stability_and_move(it.pos)
        end
    end
    physics_updating = false
end

-- 單格判定（碎石掉落／安息角滑動），供爆破等外部使用
function collapse.check_cell(pos)
    local prev = physics_updating
    physics_updating = true
    check_stability_and_move(pos)
    physics_updating = prev
end

-- 某格改變後：以其 6 個鄰格為起點排入支撐判定。
-- prev：該格改變前的方塊名稱（省略時取目前的方塊；在 on_destruct 中即為被移除的方塊）
-- 物理系統內部的移除（崩落、滑出、碎石移動）用延伸範圍，其餘（玩家）用玩家範圍
function collapse.queue_support_check(pos, prev)
    if not scfg.enabled then return end
    local p = vector.round(pos)
    add_change(support_changes, p, prev or core.get_node(p).name, nil,
        physics_updating and secondary_radius() or primary_radius())
    for _, d in ipairs(NB6) do
        pending_starts[#pending_starts + 1] = {x = p.x + d[1], y = p.y + d[2], z = p.z + d[3]}
    end
    if support_scheduled then return end
    support_scheduled = true
    core.after(0, run_support_check)
end

-- 挖掉非岩石（例如土）也可能讓上方岩石懸空；岩石本身由 on_destruct 觸發
core.register_on_dignode(function(pos, oldnode)
    if physics_updating or is_rock(oldnode.name) then return end
    collapse.queue_support_check(pos, oldnode.name)
end)

-- 9. 掉落破碎：包裝原版 falling node entity
-- 開始掉落時記下高度；落地放回 node 前，完整岩石依落下高度有機率變成碎石。
-- 變成碎石後接著依安息角判定。（原版 entity 的定義表是所有實例的 metatable，
-- 直接包裝其方法即可套用到每個 falling node。）
do
    local fb = cfg.fallbreak
    local ent = core.registered_entities["__builtin:falling_node"]
    local orig_set_node = ent.set_node
    local orig_try_place = ent.try_place

    ent.set_node = function(self, node, meta)
        local pos = self.object:get_pos()
        if pos then self.rm_start_y = pos.y end
        return orig_set_node(self, node, meta)
    end

    ent.try_place = function(self, bcp, bcn)
        local broke = false
        local name = self.node and self.node.name
        if fb.enabled and name and is_rock(name) and not rockmech.is_rubble(name) and self.rm_start_y then
            local pos = self.object:get_pos()
            local h = self.rm_start_y - pos.y
            local lith = rockmech.lith_of_node[name]
            local h_ref = lith and lith.break_height or fb.break_height
            if math.random() < rockmech.rockfall.break_probability(h, h_ref) then
                self.node = {name = rockmech.rubble_for(name)}
                broke = true
            end
        end
        local ok = orig_try_place(self, bcp, bcn)
        if ok and broke then
            -- 碎石落地後依安息角判定（下一個 tick，等 node 放好）
            local p = vector.round(self.object:get_pos())
            core.after(0, function()
                for dy = 0, 1 do
                    local q = {x = p.x, y = p.y + dy, z = p.z}
                    if rockmech.is_rubble(core.get_node(q).name) then
                        physics_updating = true
                        check_stability_and_move(q)
                        physics_updating = false
                        break
                    end
                end
            end)
        end
        return ok
    end
end

-- 10. 註冊行為：放置／移除岩石時觸發區域更新
-- intact = true：完整岩石。玩家挖掘後原地變成碎石（不掉落物品），
-- 碎石要再挖一次才會移除（相當於出碴）。
local function register_physics_events(name, intact)
    local def = core.registered_nodes[name]
    if not def then return end

    local new_groups = table.copy(def.groups or {})
    new_groups.falling_node = nil
    new_groups.rockmech_rock = 1

    local overrides = {
        groups = new_groups,
        after_place_node = function(pos)
            collapse.unmark_excavated(pos)
            -- 玩家放置的完整岩石：換成該位置應有的節理材質變體（swap 不觸發 callback）
            local lith = rockmech.lith_of_node[core.get_node(pos).name]
            if lith then
                core.swap_node(pos, {name = rockmech.joint_variant_for(lith.name, pos)})
            end
            physics_updating = true
            update_affected_area(pos)
            physics_updating = false
            -- 放上去的岩石增加懸臂自重、也可能懸空：同樣做支撐判定與懸臂斷裂
            collapse.queue_support_check(pos, "air")
        end,
        on_destruct = function(pos)
            collapse.mark_excavated(pos)
            -- 支撐判定不受防護限制：任何移除（包括物理系統把碎石移走、
            -- 落石離開原位）都可能讓上方岩石懸空。判定很便宜，且只會讓
            -- 懸空群落下，不會無限連鎖。
            collapse.queue_support_check(pos)
            -- 正上方若是碎石（不在支撐判定的鍵結範圍內），也要重新判定掉落／滑動
            local above = {x = pos.x, y = pos.y + 1, z = pos.z}
            core.after(0, function()
                if rockmech.is_rubble(core.get_node(above).name) then
                    local prev = physics_updating
                    physics_updating = true
                    check_stability_and_move(above)
                    physics_updating = prev
                end
            end)
            -- 物理系統造成的移除（崩落、滑出、碎石滑走）也會露出新岩面，要檢查（延伸範圍），
            -- 但連鎖要有上限：剝落連鎖第 k 輪中的移除 → 第 k + 1 輪；其他物理移除只檢查一次
            -- （不再往下連鎖），避免「碎石滑走 → 露出新岩面 → 再剝落」無限往後退
            if physics_updating then
                local rnd = fail_gen > 0 and fail_gen + 1 or fcfg.max_cascade
                if rnd <= fcfg.max_cascade then
                    collapse.queue_failure_check(pos, nil, secondary_radius(), rnd)
                end
                return
            end
            core.after(0.05, function()
                physics_updating = true
                update_affected_area(pos)
                physics_updating = false
            end)
            collapse.queue_failure_check(pos)
        end
    }
    if intact then
        overrides.drop = ""
        -- on_destruct 排定的檢查在之後的 tick 才執行，屆時這裡已經是碎石：
        -- 碎石下方懸空就落下、超過安息角就滑動；軸差破壞要等碎石被清走、
        -- 真正出現開口時才會觸發。
        overrides.after_dig_node = function(pos, oldnode)
            core.set_node(pos, {name = rockmech.rubble_for(oldnode.name)})
            debris(pos, rockmech.rubble_for(oldnode.name), 6)
        end
    end
    core.override_item(name, overrides)
end

register_physics_events("default:stone", true)
for _, nodename in ipairs(rockmech.rubble_nodes) do
    register_physics_events(nodename, false)
end
for _, nodename in ipairs(rockmech.lith_nodes) do
    register_physics_events(nodename, true)
end

-- 11. 整體滑動（大型平面／楔形，見 keyblock.find_masses）
-- 玩家造成的改變（挖掘、爆破、清碴）周圍排入檢查；同一秒內的觸發合併，最多每秒一次。
-- 讀取範圍較大（mass_radius），所以獨立於每次挖掘都會跑的支撐判定。
-- 滑出的岩體原地變成碎石，再由顆粒流往下攤開。
do
    local mass_centers, mass_scheduled, mass_last = {}, false, 0
    local function run_mass_check()
        mass_scheduled = false
        mass_last = core.get_us_time()
        local centers = mass_centers
        mass_centers = {}
        if not (kcfg.enabled and kcfg.mass) or #centers == 0 then return end
        local t0 = core.get_us_time()
        local R = kcfg.mass_radius
        local rs = primary_radius()
        -- 中心分群（相距 ≤ R 的合併）
        local groups = {}
        for _, c in ipairs(centers) do
            local g
            for _, cand in ipairs(groups) do
                if math.abs(c.x - cand.c.x) <= R and math.abs(c.y - cand.c.y) <= R and math.abs(c.z - cand.c.z) <= R then
                    g = cand; break
                end
            end
            if not g then g = {c = c, list = {}}; groups[#groups + 1] = g end
            g.list[#g.list + 1] = c
        end
        local kp = collapse.keyblock_params()
        kp.max_mass = kcfg.mass_max
        kp.max_floods = kcfg.mass_floods
        local n_mass, n_cells = 0, 0
        local stats_all = {floods = 0, visited = 0}
        for _, grp in ipairs(groups) do
            local a = {x = math.huge, y = math.huge, z = math.huge}
            local b = {x = -math.huge, y = -math.huge, z = -math.huge}
            for _, c in ipairs(grp.list) do
                for _, k in ipairs({"x", "y", "z"}) do
                    a[k] = math.min(a[k], c[k]); b[k] = math.max(b[k], c[k])
                end
            end
            local grid = collapse.read_grid(vector.subtract(a, R), vector.add(b, R), true)
            -- 起點：每個中心 ±rs 內、側面或下方開放的岩格
            local gnx, gny = grid.nx, grid.ny
            local gsy, gsz = gnx, gnx * gny
            local gdata, gsolid, grub, gbond = grid.data, grid.solid_of, grid.rubble_of, grid.bonded_of
            local function open(j) return not gsolid[gdata[j]] or grub[gdata[j]] ~= nil end
            local starts, seen = {}, {}
            for _, c in ipairs(grp.list) do
                for z = c.z - rs, c.z + rs do for y = c.y - rs, c.y + rs do for x = c.x - rs, c.x + rs do
                    local lx, ly, lz = x - grid.ox, y - grid.oy, z - grid.oz
                    if lx >= 1 and ly >= 1 and lz >= 1 and lx <= gnx - 2 and ly <= gny - 2 and lz <= grid.nz - 2 then
                        local i = 1 + lx + ly * gsy + lz * gsz
                        if not seen[i] and gbond[gdata[i]] then
                            seen[i] = true
                            if open(i + 1) or open(i - 1) or open(i + gsz) or open(i - gsz) or open(i - gsy) then
                                starts[#starts + 1] = {x = x, y = y, z = z}
                            end
                        end
                    end
                end end end
            end
            -- 岩橋的凝聚力：中心高程的岩體張力強度（kPa）
            local lith = rockmech.lith_at(grp.c.x, grp.c.y, grp.c.z)
            kp.bridge_c = rock.at(lith.name, grp.c.y).sigt * 1000
            local masses, st = rockmech.keyblock.find_masses(grid, kp, starts)
            stats_all.floods = stats_all.floods + st.floods
            stats_all.visited = stats_all.visited + st.visited
            for _, m in ipairs(masses) do
                n_mass = n_mass + 1
                n_cells = n_cells + #m.cells
                core.log("action", ("[rockmech] 整體%s（%s）：%d 格（W %.0f kN）FS %.2f，原地崩成碎石")
                    :format(m.mode == "wedge" and "楔形滑動" or m.mode == "plane" and "平面滑動" or "落下",
                        table.concat(m.sets, "∩"), #m.cells, m.W, m.fs))
                -- 原地變成碎石（VoxelManip 一次寫入，不觸發 on_destruct）
                local ma = {x = math.huge, y = math.huge, z = math.huge}
                local mb = {x = -math.huge, y = -math.huge, z = -math.huge}
                for _, p in ipairs(m.cells) do
                    for _, k in ipairs({"x", "y", "z"}) do
                        ma[k] = math.min(ma[k], p[k]); mb[k] = math.max(mb[k], p[k])
                    end
                end
                local vm = core.get_voxel_manip()
                local e1, e2 = vm:read_from_map(ma, mb)
                local area = VoxelArea(e1, e2)
                local data = vm:get_data()
                local own = {}
                for _, p in ipairs(m.cells) do
                    local vi = area:index(p.x, p.y, p.z)
                    local name = core.get_name_from_content_id(data[vi])
                    if rockmech.lith_of_node[name] then
                        data[vi] = core.get_content_id(rockmech.rubble_for(name))
                    end
                    own[pos_key(p)] = true
                end
                vm:set_data(data)
                vm:write_to_map(true)
                vm:close()
                if rockmech.jointmesh then rockmech.jointmesh.dirty_box(ma, mb) end
                -- 碎屑與顆粒流：每欄的頂格（由下往上），稍後依序判定
                local tops = {}
                for _, p in ipairs(m.cells) do
                    if not own[pos_key({x = p.x, y = p.y + 1, z = p.z})] then tops[#tops + 1] = p end
                end
                table.sort(tops, function(u, v) return u.y < v.y end)
                local step = math.max(1, math.floor(#tops / 16))
                for i = 1, #tops, step do debris(tops[i], rockmech.RUBBLE, 8) end
                for i, p in ipairs(tops) do
                    core.after(0.2 + 0.02 * i, function() collapse.check_cell(p) end)
                end
                -- 岩體後方露出的岩面：一次性的破壞檢查（不再連鎖）
                for i = 1, #m.cells, math.max(1, math.floor(#m.cells / 8)) do
                    collapse.queue_failure_check(m.cells[i], nil, secondary_radius(), fcfg.max_cascade)
                end
            end
        end
        local ms = (core.get_us_time() - t0) / 1000
        if ms > kcfg.mass_budget_ms or n_mass > 0 then
            core.log(ms > kcfg.mass_budget_ms and "warning" or "action",
                ("[rockmech] 整體滑動檢查 %.1f ms：擴展 %d 個組合、%d 格；崩落 %d 團、%d 格")
                :format(ms, stats_all.floods, stats_all.visited, n_mass, n_cells))
        end
    end

    function collapse.queue_mass_check(pos)
        if not (kcfg.enabled and kcfg.mass) then return end
        mass_centers[#mass_centers + 1] = vector.round(pos)
        if mass_scheduled then return end
        mass_scheduled = true
        local since = (core.get_us_time() - mass_last) / 1e6
        core.after(math.max(0.3, 1.0 - since), run_mass_check)
    end
end
