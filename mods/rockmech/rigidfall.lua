-- rockmech/rigidfall.lua
-- 剛體垂直落下（純函式，不依賴引擎）。
-- 一群懸空岩塊視為一個剛體，只做垂直平移、不旋轉。
--
-- 落下距離 d：對群內每一格 c，若 c 正下方不是群內的格，就往下找第一個
-- 非空的格：
--   * 是群外的實心格 → 這一格最多落 k−1 格（k 為找到時往下的距離）
--   * 是群內的格     → 中間的空隙會隨剛體一起移動，不構成限制
-- d = 所有限制中的最小值（剛體碰到第一個接觸點就停）。
-- max_drop 內都找不到支撐 → 回傳 nil（例如掉進未載入區或很深的坑）。

local rigidfall = {}

local function key(x, y, z)
	return x .. "," .. y .. "," .. z
end
rigidfall.key = key

-- cells：{{x=,y=,z=}, ...}
-- is_solid(x, y, z)：群外的格是否為實心（群內的格不會被問到）
function rigidfall.drop_distance(cells, is_solid, max_drop)
	max_drop = max_drop or 128
	local own = {}
	for _, c in ipairs(cells) do own[key(c.x, c.y, c.z)] = true end

	local d
	for _, c in ipairs(cells) do
		if not own[key(c.x, c.y - 1, c.z)] then
			for k = 1, max_drop do
				local y = c.y - k
				if own[key(c.x, y, c.z)] then
					break -- 碰到自己：空隙隨剛體移動
				end
				if is_solid(c.x, y, c.z) then
					local lim = k - 1
					if not d or lim < d then d = lim end
					break
				end
			end
		end
	end
	return d
end

return rigidfall
