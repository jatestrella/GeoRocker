-- 1. 物理參數
ROCK_STRENGTH = 5
COHESION = 2
K_COEFF = 0.5
UNIT_WEIGHT = 1

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

local LARGE_ROCK_NAME = "physics_core:large_rock"

local player_huds = {}
local physics_updating = false  -- 防止物理連鎖觸發

-- 位置預約系統：避免兩個方塊同時鎖定同一目標位置造成重疊
local reserved_positions = {}
local function pos_key(p) return string.format("%d,%d,%d", p.x, p.y, p.z) end
local function is_reserved(p) return reserved_positions[pos_key(p)] == true end
local function reserve_pos(p) reserved_positions[pos_key(p)] = true end
local function release_pos(p) reserved_positions[pos_key(p)] = nil end

-- 2. 滑動實體：水平逐步移動
local SLIDE_SPEED = 10.0  -- 滑動速度（格/秒），數值越小越慢越明顯

minetest.register_entity("physics_core:sliding_node", {
    initial_properties = {
        physical = false,
        visual = "node",
        node = {name = "default:stone"},
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

            if minetest.get_node(tp).name == "air" then
                minetest.set_node(tp, {name = self.node_name})
                -- 落地後仍檢查下方：若仍是空氣（例如 escape 落到懸空位置）就掉落
                local below = {x=tp.x, y=tp.y-1, z=tp.z}
                if minetest.get_node(below).name == "air" then
                    minetest.spawn_falling_node(tp)
                end
            end
            if self.reserved_landing then release_pos(self.reserved_landing) end
        end
    end,

    on_activate = function(self, staticdata)
        if staticdata and staticdata ~= "" then
            local data = minetest.deserialize(staticdata)
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
        return minetest.serialize({
            node_name = self.node_name,
            target_pos = self.target_pos
        })
    end,
})

-- 3. 輔助函數：岩石判定（大岩塊也算，用於重量傳遞與應力計算）
local function is_rock(node_name)
    if not node_name then return false end
    return node_name == "physics_core:mining_block"
        or node_name == "default:stone"
        or node_name == LARGE_ROCK_NAME
end

-- 3. 核心邏輯：垂直應力累計
local function get_sigma_y_accumulation(pos)
    local total_weight = 0
    local current_y = pos.y + 1
    while true do
        local check_pos = {x = pos.x, y = current_y, z = pos.z}
        local node = minetest.get_node_or_nil(check_pos)
        if node and is_rock(node.name) then
            total_weight = total_weight + UNIT_WEIGHT
            current_y = current_y + 1
        else
            break 
        end
    end
    return total_weight + UNIT_WEIGHT
end

-- [前置聲明] 為了避免 Nil 錯誤，先定義函數變數
local calc_node_stress
local try_escape_or_destroy
local check_stability_and_move
local update_affected_area
local shatter_group

-- 3.5 安息角輔助：找出某柱子的頂端 y 座標
local function find_column_top(x, z, from_y, max_search)
    max_search = max_search or 32
    local y = from_y
    for _ = 1, max_search do
        local n = minetest.get_node({x=x, y=y, z=z})
        if n.name ~= "air" then return y end
        y = y - 1
    end
    return nil
end

-- 預先計算掉落落點 y（第一個非空氣上方）
local function compute_landing_y(pos)
    local y = pos.y - 1
    for _ = 1, 64 do
        local n = minetest.get_node({x=pos.x, y=y, z=pos.z})
        if n.name ~= "air" then return y + 1 end
        y = y - 1
    end
    return nil
end

-- 嘗試讓岩石依機率 + 安息角滑落到相鄰 8 方向較低的柱子
local function try_slope_slide(pos)
    local node = minetest.get_node(pos)
    if not is_rock(node.name) then return false end
    -- 大岩塊作為整體，不參與滑落
    if node.name == LARGE_ROCK_NAME then return false end
    -- 下方無支撐 → 留給正常掉落邏輯處理
    if minetest.get_node({x=pos.x, y=pos.y-1, z=pos.z}).name == "air" then return false end

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
        if minetest.get_node(side).name == "air" and not is_reserved(side) then
            local top_y = find_column_top(side.x, side.z, pos.y - 1)
            if top_y then
                local drop = pos.y - (top_y + 1)
                local p = slope_slide_probability(drop, d.h)
                if p > 0 and math.random() < p then
                    local landing = {x=side.x, y=top_y+1, z=side.z}
                    if not is_reserved(landing) then
                        local original_name = node.name
                        reserve_pos(landing)
                        minetest.remove_node(pos)
                        local obj = minetest.add_entity(
                            {x=pos.x, y=pos.y, z=pos.z},
                            "physics_core:sliding_node"
                        )
                        if obj then
                            local le = obj:get_luaentity()
                            le.reserved_landing = landing
                            le:set_node(original_name, landing)
                        else
                            minetest.set_node(landing, {name = original_name})
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
        minetest.after(delay, function()
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
            minetest.spawn_falling_node(pos)
            minetest.after(delay, function()
                release_pos(landing)
                iterative_slope_slide(landing, 16)
            end)
            return
        end
    end
    -- 沒有可用落點 → 維持原本行為
    minetest.spawn_falling_node(pos)
end

-- 4. 純應力計算：只計算並儲存，不觸發任何連鎖
calc_node_stress = function(pos)
    local node = minetest.get_node_or_nil(pos)
    if not node or not is_rock(node.name) then return nil end

    local meta = minetest.get_meta(pos)
    local sig_y = get_sigma_y_accumulation(pos)

    local sxp, sxm, szp, szm = 0, 0, 0, 0
    local dirs = {
        {x=1, z=0, key="xp"}, {x=-1, z=0, key="xm"},
        {x=0, z=1, key="zp"}, {x=0, z=-1, key="zm"}
    }

    for _, d in ipairs(dirs) do
        local n_pos = {x=pos.x+d.x, y=pos.y, z=pos.z+d.z}
        local n_node = minetest.get_node_or_nil(n_pos)
        if n_node and is_rock(n_node.name) then
            local val = get_sigma_y_accumulation(n_pos) * K_COEFF
            if d.key == "xp" then sxp = val
            elseif d.key == "xm" then sxm = val
            elseif d.key == "zp" then szp = val
            elseif d.key == "zm" then szm = val end
        end
    end

    local sig_x = (sxp + sxm)
    local sig_z = (szp + szm)
    local ds = math.max(sig_x, sig_y, sig_z) - math.min(sig_x, sig_y, sig_z)

    meta:set_float("sigma_y", sig_y)
    meta:set_float("sigma_x", sig_x)
    meta:set_float("sigma_z", sig_z)
    meta:set_float("sx_p", sxp)
    meta:set_float("sx_m", sxm)
    meta:set_float("sz_p", szp)
    meta:set_float("sz_m", szm)

    local x_strength = COHESION + sig_x
    local z_strength = COHESION + sig_z

    meta:set_string("infotext", string.format(
        "三軸應力: X:%.1f | Y:%.1f | Z:%.1f (σd:%.1f)\n" ..
        "分量: [+X]:%.1f [-X]:%.1f | [+Z]:%.1f [-Z]:%.1f\n" ..
        "強度: X:%.1f | Z:%.1f",
        sig_x, sig_y, sig_z, ds, sxp, sxm, szp, szm, x_strength, z_strength
    ))

    return ds, node
end

-- 5. 破壞處理：優先側移，無路可走才破壞（不觸發連鎖更新）
try_escape_or_destroy = function(pos, node)
    -- 優先檢查下方，沒支撐就直接掉落
    local below = {x=pos.x, y=pos.y-1, z=pos.z}
    if minetest.get_node(below).name == "air" then
        minetest.spawn_falling_node(pos)
        return
    end

    -- 其次往旁邊側移
    local escape_dirs = {
        {x=1, y=0, z=0}, {x=-1, y=0, z=0},
        {x=0, y=0, z=1}, {x=0, y=0, z=-1}
    }
    for _, ed in ipairs(escape_dirs) do
        local target = {x=pos.x+ed.x, y=pos.y+ed.y, z=pos.z+ed.z}
        if minetest.get_node(target).name == "air" and not is_reserved(target) then
            local original_name = node.name
            reserve_pos(target)
            minetest.remove_node(pos)
            local obj = minetest.add_entity(
                {x=pos.x, y=pos.y, z=pos.z},
                "physics_core:sliding_node"
            )
            if obj then
                local le = obj:get_luaentity()
                le.reserved_side = target
                le.reserved_landing = target
                le:set_node(original_name, target)
            else
                minetest.set_node(target, {name = original_name})
                release_pos(target)
            end
            minetest.sound_play("default_break_glass", {pos = pos, gain = 0.3})
            return
        end
    end

    -- 四周都沒空位才破壞
    minetest.set_node(pos, {name = "air"})
    minetest.sound_play("default_break_glass", {pos = pos, gain = 0.5})
end

-- 6. 單點擾動檢查：計算應力 → 超過強度則側移/破壞 → 垂直掉落（不連鎖）
check_stability_and_move = function(pos)
    local ds, node = calc_node_stress(pos)
    if not ds then return end

    -- 大岩塊：自己不會側移、不會單獨掉落
    if node.name == LARGE_ROCK_NAME then
        -- [關閉] 大岩塊應力破壞：原本 ds > ROCK_STRENGTH 時整組碎裂
        -- if ds > ROCK_STRENGTH then
        --     shatter_group(pos)
        --     minetest.after(0.05, function()
        --         physics_updating = true
        --         update_affected_area(pos)
        --         physics_updating = false
        --     end)
        -- end
        return
    end

    -- [關閉] 普通岩石應力破壞：原本 ds > ROCK_STRENGTH 時側移或破壞
    -- if ds > ROCK_STRENGTH then
    --     try_escape_or_destroy(pos, node)
    --     return
    -- end

    -- 無支撐自動掉落：下方是空氣就直接落下
    local below = {x=pos.x, y=pos.y-1, z=pos.z}
    if minetest.get_node(below).name == "air" then
        fall_with_slope_settle(pos)
        return
    end

    -- 安息角：相鄰柱子過低就滑落
    if try_slope_slide(pos) then
        return
    end

    -- [關閉] 垂直壓力應力破壞：原本 σy 超過水平強度就掉落
    -- local meta = minetest.get_meta(pos)
    -- local sy = meta:get_float("sigma_y") or 0
    -- local sxp = meta:get_float("sx_p") or 0
    -- local sxm = meta:get_float("sx_m") or 0
    -- local szp = meta:get_float("sz_p") or 0
    -- local szm = meta:get_float("sz_m") or 0
    -- local x_strength = COHESION + (sxp + sxm)
    -- local z_strength = COHESION + (szp + szm)
    -- if sy > x_strength and sy > z_strength then
    --     fall_with_slope_settle(pos)
    -- end
end

-- 7. 區域更新：僅開挖點周圍5格，計算應力後判定但不再連鎖
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

-- 8. 註冊行為
local function register_physics_events(name)
    local def = minetest.registered_nodes[name]
    if not def then return end
    
    local new_groups = table.copy(def.groups or {})
    new_groups.falling_node = nil 
    
    minetest.override_item(name, {
        groups = new_groups,
        after_place_node = function(pos)
            physics_updating = true
            update_affected_area(pos)
            physics_updating = false
        end,
        on_destruct = function(pos)
            if physics_updating then return end  -- 物理系統內部操作，不重複觸發
            local above = {x=pos.x, y=pos.y+1, z=pos.z}
            minetest.after(0.05, function()
                physics_updating = true
                update_affected_area(pos)
                physics_updating = false
            end)
        end
    })
end

register_physics_events("default:stone")
register_physics_events("physics_core:mining_block")

-- 9. 大岩塊：世界以 2x2x2 群組生成，挖掘後碎裂成 8 個小石頭
local LARGE_ROCK_NAME = "physics_core:large_rock"

-- 取得 2x2x2 群組的原點（向下對齊到偶數座標）
local function get_group_origin(pos)
    return {
        x = math.floor(pos.x / 2) * 2,
        y = math.floor(pos.y / 2) * 2,
        z = math.floor(pos.z / 2) * 2,
    }
end

-- 將整個 2x2x2 群組剩餘部分轉成普通石頭
shatter_group = function(pos)
    local origin = get_group_origin(pos)
    local affected = {}
    for dx = 0, 1 do
        for dy = 0, 1 do
            for dz = 0, 1 do
                local p = {x=origin.x+dx, y=origin.y+dy, z=origin.z+dz}
                if minetest.get_node(p).name == LARGE_ROCK_NAME then
                    minetest.set_node(p, {name = "default:stone"})
                    table.insert(affected, p)
                end
            end
        end
    end
    return affected
end

minetest.register_node(LARGE_ROCK_NAME, {
    description = "未開採岩體 (2x2x2)",
    tiles = {"default_stone.png^[colorize:#000000:160"},  -- 大幅變深，明顯區分
    groups = {cracky = 1, stone = 1},
    sounds = (default and default.node_sound_stone_defaults and default.node_sound_stone_defaults()) or nil,

    after_dig_node = function(pos, oldnode, oldmetadata, digger)
        -- 挖掉一格 → 剩下 7 格碎裂為普通石頭
        physics_updating = true
        local affected = shatter_group(pos)
        physics_updating = false
        -- 觸發物理計算（一次即可，update_affected_area 內已掃描 ±5 範圍）
        minetest.after(0.05, function()
            physics_updating = true
            update_affected_area(pos)
            physics_updating = false
        end)
    end,
})

-- 世界生成：把 default:stone 區域以 2x2x2 對齊群組替換為大岩塊
minetest.register_on_generated(function(minp, maxp, blockseed)
    local replaced = 0
    local x_start = math.floor(minp.x / 2) * 2
    local y_start = math.floor(minp.y / 2) * 2
    local z_start = math.floor(minp.z / 2) * 2

    for x = x_start, maxp.x - 1, 2 do
        for y = y_start, maxp.y - 1, 2 do
            for z = z_start, maxp.z - 1, 2 do
                local all_stone = true
                for dx = 0, 1 do
                    for dy = 0, 1 do
                        for dz = 0, 1 do
                            local p = {x=x+dx, y=y+dy, z=z+dz}
                            if minetest.get_node(p).name ~= "default:stone" then
                                all_stone = false
                                break
                            end
                        end
                        if not all_stone then break end
                    end
                    if not all_stone then break end
                end

                if all_stone then
                    for dx = 0, 1 do
                        for dy = 0, 1 do
                            for dz = 0, 1 do
                                minetest.swap_node(
                                    {x=x+dx, y=y+dy, z=z+dz},
                                    {name = LARGE_ROCK_NAME}
                                )
                            end
                        end
                    end
                    replaced = replaced + 1
                end
            end
        end
    end
    minetest.log("action",
        string.format("[physics_core] chunk(%d,%d,%d)~(%d,%d,%d) 替換 %d 組大岩塊",
        minp.x, minp.y, minp.z, maxp.x, maxp.y, maxp.z, replaced))
end)

-- 提供 /convert_rocks 指令：手動轉換玩家附近的石頭為大岩塊（用於既有世界測試）
minetest.register_chatcommand("convert_rocks", {
    description = "把玩家半徑20格內的 default:stone 以 2x2x2 群組替換為大岩塊",
    privs = {server = true},
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "找不到玩家" end
        local p = player:get_pos()
        local R = 20
        local minp = {
            x = math.floor((p.x - R) / 2) * 2,
            y = math.floor((p.y - R) / 2) * 2,
            z = math.floor((p.z - R) / 2) * 2,
        }
        local maxp = {x = p.x + R, y = p.y + R, z = p.z + R}
        local replaced = 0

        for x = minp.x, maxp.x, 2 do
            for y = minp.y, maxp.y, 2 do
                for z = minp.z, maxp.z, 2 do
                    local all_stone = true
                    for dx = 0, 1 do for dy = 0, 1 do for dz = 0, 1 do
                        if minetest.get_node({x=x+dx,y=y+dy,z=z+dz}).name ~= "default:stone" then
                            all_stone = false
                        end
                    end end end
                    if all_stone then
                        for dx = 0, 1 do for dy = 0, 1 do for dz = 0, 1 do
                            minetest.swap_node({x=x+dx,y=y+dy,z=z+dz}, {name = LARGE_ROCK_NAME})
                        end end end
                        replaced = replaced + 1
                    end
                end
            end
        end
        return true, string.format("替換了 %d 組大岩塊", replaced)
    end
})

-- 10. HUD 輔助
local function get_direction_text(player)
    local angle = player:get_look_horizontal()
    local degrees = (math.deg(angle) % 360)
    if degrees >= 315 or degrees < 45 then return "北 (+Z)"
    elseif degrees >= 45 and degrees < 135 then return "西 (-X)"
    elseif degrees >= 135 and degrees < 225 then return "南 (-Z)"
    else return "東 (+X)" end
end

minetest.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    player_huds[name] = player:hud_add({
        hud_elem_type = "text", position = {x = 0.5, y = 0.05},
        text = "方位: 更新中...", number = 0xFFFFFF,
    })
end)

minetest.register_globalstep(function(dtime)
    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        if player_huds[name] then
            player:hud_change(player_huds[name], "text", "方位: " .. get_direction_text(player))
        end
    end
end)