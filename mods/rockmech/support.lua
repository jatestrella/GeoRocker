-- rockmech/support.lua
-- 支護（岩栓、噴凝土）換算成臨空岩面上的等效圍壓 pᵢ（支護壓力，同 RocSupport／地盤反應曲線的概念）。
-- 純函式，不依賴引擎。支護方塊放在岩面前方的空氣格：
--   噴凝土層（lining）：這格相鄰的每個岩面都得到 p_sc。
--   岩栓（bolt，貼壁方塊，param2 指向岩面）：錨定力 T 平均分給以它為中心、同一面上 3×3 格的岩面
--     （每面 T/9 kN/m²）→ 間距 s 的格狀岩栓約等於 T/s²。
-- 兩種疊加。壓力與力都已除以相似比 N（同岩體強度）。
--
-- 用法：
--   failure.cell_state：臨空面的法向應力 = pᵢ（側面：σx／σz；頂板：σy），Hoek-Brown 的 σ3 與節理面的 σn 跟著提高。
--   keyblock：岩塊臨空面上的噴凝土 p_sc × 面積；穿過岩塊、錨固段打進岩塊外岩體的岩栓 T。
--     兩者都是作用在面上、指向岩體的力，抵抗把岩塊往外推出該面的運動。
--   頂板（底面的 pᵢ 往上托，抵銷懸空岩體的自重）：
--     懸臂（overhang.lua）：每 m² 荷重 γh → γh − pᵢ（h = Terzaghi 鬆弛區的荷重高度），σb 等比例下降；
--       pᵢ ≥ γh 被托住。岩栓要穿過鬆弛區（有效長度 L ≥ h）才算（sup.bf 記每支攤到的壓力與長度）。
--     懸空直剪（failure.shear_state）：每欄的柱狀荷重扣掉底面的 pᵢ × 1 m²。
--
-- support.scan(g, ids, prm) → sup 或 nil（範圍內沒有支護）
--   g：failure／keyblock 的網格（data、p2、ox..nz、bonded_of）
--   ids = {lining = {[cid] = true}, bolt = {[cid] = true}}
--   prm = {p_sc (MPa), T (kN), L (m，沒有 bolt_len 時的岩栓長度), N, bolt_len(x, y, z) → 該岩栓的長度 (m)（世界座標）}
--   sup.face[i·8 + k] = pᵢ (MPa)：岩格 i（網格索引）往 AX[k] 方向的面
--   sup.sc[i·8 + k]   = 只有噴凝土的 p_sc (MPa)
--   sup.bf[i·8 + k]   = 岩栓攤到這一面的 {{p (MPa), 有效長度 L (m)}...}（被挖斷只算到斷點）
--   sup.bolts = {{i = 岩栓穿過的第一格, path = {往岩體裡的後續各格}, k = 墊板那一面的方向, T = kN}...}

local support = {}

-- 面的方向（與 keyblock 相同順序）：+x −x +y −y +z −z
local AX = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
support.AX = AX
local function k_of(dx, dy, dz)
	if dx > 0 then return 1 elseif dx < 0 then return 2
	elseif dy > 0 then return 3 elseif dy < 0 then return 4
	elseif dz > 0 then return 5 else return 6 end
end
support.k_of = k_of
-- 貼壁方塊 param2 → 指向岩面的方向（Luanti wallmounted：0 +y、1 −y、2 +x、3 −x、4 +z、5 −z）
local WALL = {[0] = {0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}

function support.scan(g, ids, prm)
	local data, bonded_of = g.data, g.bonded_of
	local nx, ny, nz = g.nx, g.ny, g.nz
	local sy, sz = nx, nx * ny
	local N = prm.N or 1
	local p_sc = (prm.p_sc or 0) / N
	local T = (prm.T or 0) / N
	local sup = {face = {}, sc = {}, bolts = {}, bf = {}}
	local any = false
	local function idx(x, y, z)
		if x < 0 or y < 0 or z < 0 or x >= nx or y >= ny or z >= nz then return nil end
		return 1 + x + y * sy + z * sz
	end
	local function add(t, key, v) t[key] = (t[key] or 0) + v end
	for i = 1, #data do
		local c = data[i]
		local lin, bolt = ids.lining[c], ids.bolt[c]
		if lin or bolt then
			any = true
			local r = i - 1
			local x = r % nx; r = (r - x) / nx
			local y = r % ny
			local z = (r - y) / ny
			if lin and p_sc > 0 then
				for k = 1, 6 do
					local a = AX[k]
					local j = idx(x + a[1], y + a[2], z + a[3])
					if j and bonded_of[data[j]] then
						local key = j * 8 + k_of(-a[1], -a[2], -a[3])
						add(sup.face, key, p_sc)
						add(sup.sc, key, p_sc)
					end
				end
			end
			if bolt and T > 0 then
				local d = WALL[(g.p2 and g.p2[i] or 0) % 8] or WALL[1]
				local kout = k_of(-d[1], -d[2], -d[3])
				local i0 = idx(x + d[1], y + d[2], z + d[3])
				local Lb = prm.bolt_len and prm.bolt_len(g.ox + x, g.oy + y, g.oz + z) or prm.L or 1
				local nb = math.max(1, math.ceil(Lb - 1e-6))
				if i0 and bonded_of[data[i0]] then
					local path = {}
					for s = 2, nb do
						local j = idx(x + d[1] * s, y + d[2] * s, z + d[3] * s)
						-- 中間被挖空（岩栓被挖斷）：後面那截跟墊板分開了，不算錨固
						if not j or not bonded_of[data[j]] then break end
						path[#path + 1] = j
					end
					local Leff = math.min(Lb, 1 + #path)
					-- 錨定力分給同一面 3×3 格（前方是開口、後面是岩石的面）
					for u = -1, 1 do for v = -1, 1 do
						local ox, oy, oz
						if d[1] ~= 0 then ox, oy, oz = 0, u, v
						elseif d[2] ~= 0 then ox, oy, oz = u, 0, v
						else ox, oy, oz = u, v, 0 end
						local j = idx(x + d[1] + ox, y + d[2] + oy, z + d[3] + oz)
						local jo = idx(x + ox, y + oy, z + oz)
						if j and jo and bonded_of[data[j]] and not bonded_of[data[jo]] then
							local key = j * 8 + kout
							add(sup.face, key, T / 9 / 1000)
							local l = sup.bf[key] or {}
							l[#l + 1] = {T / 9 / 1000, Leff}
							sup.bf[key] = l
						end
					end end
					sup.bolts[#sup.bolts + 1] = {i = i0, path = path, k = kout, T = T}
				end
			end
		end
	end
	if not any then return nil end
	sup.forces, sup.resist = support.forces, support.resist   -- keyblock 透過網格上的 sup 呼叫（不必載入本模組）
	return sup
end

-- 岩格 i 往 AX[k] 方向那一面的支護壓力 (MPa)
function support.at(sup, i, k)
	return sup and i and sup.face[i * 8 + k] or 0
end

-- 一群岩格（網格索引的集合 set，cells = {{lx, ly, lz}...}）受到的支護力，依面的方向分 6 桶 (kN)：
-- 臨空面上的噴凝土 p_sc × 1 m²；岩栓穿過這群、而且錨固段有一格在群外的岩體裡 → T。
-- 回傳 S[1..6] 或 nil
function support.forces(g, sup, cells, set)
	if not sup then return nil end
	local sy, sz = g.nx, g.nx * g.ny
	local S, any = {0, 0, 0, 0, 0, 0}, false
	for _, c in ipairs(cells) do
		local i = 1 + c[1] + c[2] * sy + c[3] * sz
		for k = 1, 6 do
			local p = sup.sc[i * 8 + k]
			if p then S[k] = S[k] + p * 1000; any = true end
		end
	end
	for _, b in ipairs(sup.bolts) do
		if set[b.i] then
			for _, j in ipairs(b.path) do
				if not set[j] and g.bonded_of[g.data[j]] then
					S[b.k] = S[b.k] + b.T; any = true
					break
				end
			end
		end
	end
	return any and S or nil
end

-- 支護力對運動方向 m 的抵抗 (kN)：面往外推出（AX[k]·m > 0）時，該面的支護力 × 分量
function support.resist(S, m)
	if not S then return 0 end
	local r = 0
	for k = 1, 6 do
		if S[k] > 0 then
			local a = AX[k]
			local d = a[1] * m.x + a[2] * m.y + a[3] * m.z
			if d > 0 then r = r + S[k] * d end
		end
	end
	return r
end

return support
