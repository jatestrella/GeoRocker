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
-- ANGLE_OF_REPOSE：目標安息角（度），實際機率以此計算
-- SLOPE_RANDOMNESS：機率曲線平滑度，小→硬門檻、大→較隨機
local SLOPE_THRESHOLD = 1
local ANGLE_OF_REPOSE = 30
local SLOPE_RANDOMNESS = 1.0
local SLOPE_TAN = math.tan(math.rad(ANGLE_OF_REPOSE))

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
                    core.spawn_falling_node(tp)
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

-- 嘗試讓岩石依機率 + 安息角滑落到相鄰 8 方向較低的柱子
local function try_slope_slide(pos)
    local node = core.get_node(pos)
    if not is_rock(node.name) then return false end
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
check_stability_and_move = function(pos)
    local node = core.get_node_or_nil(pos)
    if not node or not is_rock(node.name) then return end

    -- 無支撐自動掉落：下方是空氣就直接落下
    local below = {x=pos.x, y=pos.y-1, z=pos.z}
    if core.get_node(below).name == "air" then
        fall_with_slope_settle(pos)
        return
    end

    -- 安息角：相鄰柱子過低就滑落
    try_slope_slide(pos)
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

-- 7. 註冊行為：放置／移除岩石時觸發區域更新
local function register_physics_events(name)
    local def = core.registered_nodes[name]
    if not def then return end

    local new_groups = table.copy(def.groups or {})
    new_groups.falling_node = nil
    new_groups.rockmech_rock = 1

    core.override_item(name, {
        groups = new_groups,
        after_place_node = function(pos)
            physics_updating = true
            update_affected_area(pos)
            physics_updating = false
        end,
        on_destruct = function(pos)
            if physics_updating then return end  -- 物理系統內部操作，不重複觸發
            core.after(0.05, function()
                physics_updating = true
                update_affected_area(pos)
                physics_updating = false
            end)
        end
    })
end

register_physics_events("default:stone")
for _, nodename in pairs(rockmech.node_of_lith) do
    register_physics_events(nodename)
end
