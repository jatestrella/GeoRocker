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

-- 安息角設定
-- SLOPE_THRESHOLD：絕對下限，drop < 此值完全不滑（單位：格）
-- 安息角（度）：設定 rockmech_slope_angle（預設 35°，有稜角岩屑約 34–40°）
-- SLOPE_RANDOMNESS：機率曲線平滑度，小→硬門檻、大→較隨機
local SLOPE_THRESHOLD = 1
local SLOPE_RANDOMNESS = 1.0
local SLOPE_TAN = math.tan(math.rad(rockmech.cfg.slope.angle))

-- 8 方向鄰居（含對角），h 為水平距離
local SLOPE_NEIGHBORS = {
    {x=1,  z=0,  h=1},
    {x=-1, z=0,  h=1},
    {x=0,  z=1,  h=1},
    {x=0,  z=-1, h=1},
    {x=1,  z=1,  h=math.sqrt(2)},
    {x=1,  z=-1, h=math.sqrt(2)},
    {x=-1, z=1,  h=math.sqrt(2)},
    {x=-1, z=-1, h=math.sqrt(2)},
}

-- 計算給定高度差 drop 和水平距離 h 下的滑落機率
local function slope_slide_probability(drop, h)
    if drop < SLOPE_THRESHOLD then return 0 end       -- 絕對下限
    local d_crit = h * SLOPE_TAN                      -- 此方向的臨界高度差
    local excess = drop - d_crit
    if excess <= 0 then return 0 end
    return math.min(1, excess / SLOPE_RANDOMNESS)
end

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

-- 3. 安息角輔助：找出某柱子的頂端 y 座標
local function find_column_top(x, z, from_y, max_search)
    max_search = max_search or 32
    local y = from_y
    for _ = 1, max_search do
        local n = core.get_node({x=x, y=y, z=z})
        if n.name ~= "air" then return y end
        y = y - 1
    end
    return nil
end

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

-- 安息角滑落改為翻滾：從格子邊緣（往滑動方向偏移 0.5 m）以此初速推出 (m/s)，
-- 確保能離開原本那一格（滾動阻力下 1.5 m/s 只滑約 0.3 m 就停住）
local SLIDE_LAUNCH_SPEED = 3.0
local SLIDE_LAUNCH_OFFSET = 0.5

-- 嘗試讓岩石依機率 + 安息角滑落到相鄰 8 方向較低的柱子
local function try_slope_slide(pos)
    -- 遊戲中可關閉（物品欄 rockmech 分頁 / /rockmech_toggle slope）
    if not rockmech.cfg.slope.enabled then return false end
    local node = core.get_node(pos)
    -- 只有碎石受安息角控制；完整岩石由軸差破壞準則控制
    if node.name ~= rockmech.RUBBLE then return false end
    -- 下方無支撐 → 留給正常掉落邏輯處理
    if core.get_node({x=pos.x, y=pos.y-1, z=pos.z}).name == "air" then return false end

    -- 複製並打亂 8 方向鄰居順序
    local dirs = {}
    for i, n in ipairs(SLOPE_NEIGHBORS) do dirs[i] = n end
    for i = #dirs, 2, -1 do
        local j = math.random(i)
        dirs[i], dirs[j] = dirs[j], dirs[i]
    end

    -- 對每個方向獨立擲骰，第一個成功的就滑落
    for _, d in ipairs(dirs) do
        local side = {x=pos.x+d.x, y=pos.y, z=pos.z+d.z}
        if core.get_node(side).name == "air" and not is_reserved(side) then
            local top_y = find_column_top(side.x, side.z, pos.y - 1)
            if top_y then
                local drop = pos.y - (top_y + 1)
                local p = slope_slide_probability(drop, d.h)
                if p > 0 and math.random() < p then
                    -- 優先改為往該方向翻滾（之後的運動由落石物理處理）
                    local s = SLIDE_LAUNCH_SPEED / d.h
                    local o = SLIDE_LAUNCH_OFFSET / d.h
                    if launch_rockfall(pos, {x = d.x * s, y = 0, z = d.z * s},
                            {x = pos.x + d.x * o, y = pos.y, z = pos.z + d.z * o}) then
                        return true
                    end
                    local landing = {x=side.x, y=top_y+1, z=side.z}
                    if not is_reserved(landing) then
                        local original_name = node.name
                        reserve_pos(landing)
                        core.remove_node(pos)
                        local obj = core.add_entity(
                            {x=pos.x, y=pos.y, z=pos.z},
                            "rockmech:sliding_node"
                        )
                        if obj then
                            local le = obj:get_luaentity()
                            le.reserved_landing = landing
                            le:set_node(original_name, landing)
                        else
                            core.set_node(landing, {name = original_name})
                            release_pos(landing)
                        end
                        return true, landing
                    end
                end
            end
        end
    end
    return false
end

-- 非同步遞迴：嘗試滑落，等實體動畫完成後再從新位置繼續
local function iterative_slope_slide(start_pos, depth)
    depth = depth or 8
    if depth <= 0 then return end

    physics_updating = true
    local ok, new_pos = try_slope_slide(start_pos)
    physics_updating = false

    if ok and new_pos then
        -- 3D 直線距離 / 速度（含可能的對角線水平 √2）
        local dx = new_pos.x - start_pos.x
        local dy = new_pos.y - start_pos.y
        local dz = new_pos.z - start_pos.z
        local total = math.sqrt(dx*dx + dy*dy + dz*dz)
        local delay = total / SLIDE_SPEED + 0.15
        core.after(delay, function()
            iterative_slope_slide(new_pos, depth - 1)
        end)
    end
end

-- 結合掉落 + 安息角整理：spawn_falling_node 後排程滑落收尾
-- 垂直落下沿用原版 falling node；落地後若坡度超過安息角，才由
-- iterative_slope_slide → try_slope_slide 改為翻滾落石。
local function fall_with_slope_settle(pos)
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
                iterative_slope_slide(landing, 16)
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

    local below = {x=pos.x, y=pos.y-1, z=pos.z}
    local unsupported = core.get_node(below).name == "air"

    if node.name == rockmech.RUBBLE then
        if unsupported then
            fall_with_slope_settle(pos)
        else
            try_slope_slide(pos)
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
local failure = rockmech.failure

local solid_of, weight_of, lith_of, bonded_of
local function build_cid_maps()
    if solid_of then return end
    solid_of, weight_of, lith_of, bonded_of = {}, {}, {}, {}
    for name, def in pairs(core.registered_nodes) do
        local cid = core.get_content_id(name)
        solid_of[cid] = def.walkable ~= false
        if def.walkable ~= false then
            weight_of[cid] = fcfg.gamma_other
            -- 鍵結：天然的實心地層（完整岩石、土、礦石…）；碎石、沙等鬆散材料
            -- 以及玩家建築（is_ground_content = false）不鍵結
            local groups = def.groups or {}
            if def.is_ground_content ~= false and name ~= rockmech.RUBBLE
                    and (groups.falling_node or 0) == 0 then
                bonded_of[cid] = true
            end
        end
    end
    -- 未載入區塊：側向視為實心（保守），但不計入荷重
    local c_ignore = core.get_content_id("ignore")
    solid_of[c_ignore] = true
    weight_of[c_ignore] = nil
    for key, nodename in pairs(rockmech.node_of_lith) do
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
    vm:close()
    return {
        data = data,
        ox = emin.x, oy = emin.y, oz = emin.z,
        nx = emax.x - emin.x + 1, ny = emax.y - emin.y + 1, nz = emax.z - emin.z + 1,
        solid_of = solid_of, weight_of = weight_of, lith_of = lith_of, bonded_of = bonded_of,
    }
end

function collapse.failure_params()
    return {
        surface_y = cfg.surface_y, k0 = cfg.k0, lithologies = cfg.lithologies,
        window = fcfg.window,
        strength_scale = fcfg.strength_scale,
    }
end

-- 盒子工具
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
            {x = a.x - margin, y = a.y - 1, z = a.z - margin},
            {x = b.x + margin, y = b.y + 1, z = b.z + margin})
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
function collapse.apply_failure(failed)
    local rubble = {name = rockmech.RUBBLE}
    physics_updating = true
    for _, f in ipairs(failed) do
        local p = {x = f.x, y = f.y, z = f.z}
        if rockmech.lith_of_node[core.get_node(p).name] then
            core.swap_node(p, rubble)
        end
    end
    -- 由上往下（failed 已排序）判定掉落／滑動
    for _, f in ipairs(failed) do
        check_stability_and_move({x = f.x, y = f.y, z = f.z})
    end
    physics_updating = false
end

-- 單一佇列：所有觸發（開挖、連鎖）合併成同一批處理
local queue_boxes, queue_round = {}, 0
local queue_scheduled = false
local process_queue

local function enqueue(box, round)
    queue_boxes[#queue_boxes + 1] = box
    if round > queue_round then queue_round = round end
    if queue_scheduled then return end
    queue_scheduled = true
    core.after(0, process_queue)
end

process_queue = function()
    queue_scheduled = false
    local boxes, round = queue_boxes, queue_round
    queue_boxes, queue_round = {}, 0
    -- 遊戲中關閉破壞準則時，進行中的連鎖也一併停止
    if #boxes == 0 or not fcfg.enabled then return end

    local failed, stats, ms = collapse.evaluate_failure_boxes(boxes)
    if ms > fcfg.budget_ms then
        core.log("warning", ("[rockmech] 軸差破壞檢查 %.1f ms（預算 %g ms），第 %d 輪、%d 盒、評估 %d 格")
            :format(ms, fcfg.budget_ms, round, #boxes, stats.evaluated))
    end
    if #failed == 0 then return end

    core.log("action", ("[rockmech] 軸差破壞 第 %d 輪：%d 格（%.1f ms）"):format(round, #failed, ms))
    collapse.apply_failure(failed)

    if round >= fcfg.max_cascade then
        core.log("action", ("[rockmech] 軸差破壞連鎖達上限 %d 輪，停止"):format(fcfg.max_cascade))
        return
    end
    -- 下一輪只檢查破壞格附近（外包盒 ±2）
    local a, b = union((function()
        local t = {}
        for _, f in ipairs(failed) do t[#t + 1] = cube(f, 0) end
        return t
    end)())
    local next_box = {
        {x = a.x - 2, y = a.y - 2, z = a.z - 2},
        {x = b.x + 2, y = b.y + 2, z = b.z + 2},
    }
    core.after(fcfg.cascade_delay, function()
        physics_updating = true
        for _, f in ipairs(failed) do
            -- 剝落後上方可能懸空：沿用懸空掉落／滑動判定
            check_stability_and_move({x = f.x, y = f.y + 1, z = f.z})
        end
        physics_updating = false
        enqueue(next_box, round + 1)
    end)
end

-- 開挖觸發：同一 tick 內的多次觸發合併成一次檢查
function collapse.queue_failure_check(pos)
    if not fcfg.enabled then return end
    enqueue(cube(vector.round(pos), fcfg.radius), 1)
end

-- 8. 支撐判定（模型見 support.lua）
-- 移除方塊 → 同一 tick 合併 → VoxelManip 一次讀取 → 純函式找懸空群 →
-- 懸空群以原版 falling node 由下往上落下
local scfg = cfg.support
local pending_starts, support_scheduled = {}, false
local NB6 = {{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1}}

local function run_support_check()
    support_scheduled = false
    local starts = pending_starts
    pending_starts = {}
    if #starts == 0 or not scfg.enabled then return end

    local t0 = core.get_us_time()
    local r = scfg.radius
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
    for _, g in ipairs(groups) do
        local grid = collapse.read_grid(
            {x = g.a.x - r, y = g.a.y - r, z = g.a.z - r},
            {x = g.b.x + r, y = g.b.y + r, z = g.b.z + r}, true)
        local c, st = rockmech.support.find_unsupported(grid, g.starts, scfg.max_voxels)
        for _, comp in ipairs(c) do comps[#comps + 1] = comp end
        stats.visited = stats.visited + st.visited
    end
    local ms = (core.get_us_time() - t0) / 1000
    if ms > scfg.budget_ms then
        core.log("warning", ("[rockmech] 支撐判定 %.1f ms（預算 %g ms），起點 %d、展開 %d 格")
            :format(ms, scfg.budget_ms, #starts, stats.visited))
    end
    if #comps == 0 then return end

    local n = 0
    physics_updating = true
    for _, c in ipairs(comps) do
        for _, p in ipairs(c.cells) do   -- 由低到高
            core.spawn_falling_node(p)
            n = n + 1
        end
    end
    -- 群上方若有碎石等，可能因此懸空
    for _, c in ipairs(comps) do
        for _, p in ipairs(c.cells) do
            check_stability_and_move({x = p.x, y = p.y + 1, z = p.z})
        end
    end
    physics_updating = false
    core.log("action", ("[rockmech] 支撐判定：%d 群懸空、共 %d 格落下（%.1f ms，展開 %d 格）")
        :format(#comps, n, ms, stats.visited))
end

-- 某格被移除後：以其 6 個鄰格為起點排入支撐判定
function collapse.queue_support_check(pos)
    if not scfg.enabled then return end
    local p = vector.round(pos)
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
    collapse.queue_support_check(pos)
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
        if fb.enabled and name and is_rock(name) and name ~= rockmech.RUBBLE and self.rm_start_y then
            local pos = self.object:get_pos()
            local h = self.rm_start_y - pos.y
            local lith = rockmech.lith_of_node[name]
            local h_ref = lith and lith.break_height or fb.break_height
            if math.random() < rockmech.rockfall.break_probability(h, h_ref) then
                self.node = {name = rockmech.RUBBLE}
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
                    if core.get_node(q).name == rockmech.RUBBLE then
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
            physics_updating = true
            update_affected_area(pos)
            physics_updating = false
        end,
        on_destruct = function(pos)
            -- 支撐判定不受防護限制：任何移除（包括物理系統把碎石移走、
            -- 落石離開原位）都可能讓上方岩石懸空。判定很便宜，且只會讓
            -- 懸空群落下，不會無限連鎖。
            collapse.queue_support_check(pos)
            -- 正上方若是碎石（不在支撐判定的鍵結範圍內），也要重新判定掉落／滑動
            local above = {x = pos.x, y = pos.y + 1, z = pos.z}
            core.after(0, function()
                if core.get_node(above).name == rockmech.RUBBLE then
                    local prev = physics_updating
                    physics_updating = true
                    check_stability_and_move(above)
                    physics_updating = prev
                end
            end)
            if physics_updating then return end  -- 物理系統內部操作，不重複觸發
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
        overrides.after_dig_node = function(pos)
            core.set_node(pos, {name = rockmech.RUBBLE})
        end
    end
    core.override_item(name, overrides)
end

register_physics_events("default:stone", true)
register_physics_events(rockmech.RUBBLE, false)
for _, nodename in pairs(rockmech.node_of_lith) do
    register_physics_events(nodename, true)
end
