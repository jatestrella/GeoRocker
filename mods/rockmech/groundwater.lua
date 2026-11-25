-- rockmech/groundwater.lua
-- 地下水：世界設定 rockmech_water_table_depth（天然地表下幾 m；slurry.lua 的 rockmech.water_table_natural 算天然水位）。
-- 滲流（Dupuit 假設：每一欄土一個水位 H，水平流；暫態）：
--   相鄰兩欄的流量 q = T̄·ΔH（每 1 m 寬、相距 1 m；T̄ = 兩欄導水係數的平均；全是土時 = k·兩欄飽和厚度的平均）。
--   一欄的水位變化 Sy·dH/dt = 流進來的總量；土的給水度 Sy = 孔隙率 ×（1 − 背景含水）：水位降下去，飽和的土剩背景含水，
--     放出來的水流向坑（slurry.lua 的 rockmech_soil_porosity、rockmech_soil_saturation）。岩石的給水度很小，水位降得快、漏斗擴得遠。
--   含水層：天然水位以下往下 BASE_MAX m 裡透水的格。每一格的透水係數 k、給水度：
--     土（和天然的崩積土、碎石）：k = rockmech_soil_permeability，給水度 Sy（下面）；
--     岩石：裂隙岩體，用體積節理數 Jv（條/m³，跟岩芯記錄同一套：細裂隙 Jv = (115 − RQD)/3.3，RQD 由那一格的 GSI 和
--       岩性的 Jr/Ja 反推；加上節理網路的粗節理，那一格六個面裡是節理的面數 ÷ 3）。Jv ≥ 門檻 rockmech_rock_seep_jv 才透水，
--       照立方定律（平行板）：k = (2/3)·Jv·g·e³/(12ν)，給水度 = 裂隙孔隙率 Jv·e（e = 裂隙開口寬 rockmech_joint_aperture）；
--       不到門檻的岩石、混凝土、連續壁：不透水。
--     含水層底：往下碰到連續 AQ_T m 以上不透水的阻水層為止（中間零星不透水的格不切斷，只是不導水）；阻水層下面的受壓含水層先不算。
--     一欄的導水係數 T(H) = 含水層底到水位 H 之間各格 k 的和（含水層裡的層當作互通）；水位所在那一格的給水度管水位升降。
--     坑、隧道要有一部分在旁邊那一欄的含水層裡（坑頂高過那一欄的含水層底）才收得到那一欄的水。
--   坑（天然水位以下有挖開的格、或有液體的格）：水頭 = 坑裡的水面（乾的就是坑底），固定。灌滿、上面又被土蓋住的空洞不算坑。
--     地圖產生器生的崩積土、天然空洞（沒挖過、沒有液體）跟周圍的土一起飽和，不算坑。
--   坑一直把水位壓低，漏斗就隨時間往外擴（擴多快看 k、Sy、含水層厚度），沒有規定半徑；坑積水、水被抽走都自然平衡。
--     計算範圍：離坑 RANGE m 以內、水位跟天然差 EPS 以上的欄；再外面當天然水位（無限的含水層）。
--   冒水：坑邊那一欄收到的流量，每 STEP_DT 秒加進坑裡最低、還有空間的那一格（之後照 slurry.lua 守恆地流）。
--     坑裡的水比旁邊的土高就不流（不往回灌進含水層；水位以上的土照 slurry.lua 慢慢滲）。
--   rockmech.water_table_y 換成算出來的水位：漏斗裡水位以上的土不再飽和（slurry.lua 的 soil_room）。
--   隧道、坑挖進透水的岩層：一樣是坑，周圍岩層的水照上面的規則流進來（一塊岩石只放得出它裂隙裡的水，持續的冒水是
--   遠處的水沿著透水岩層流過來的）。關遊戲時記下每一欄的水位，下次接著算。
-- 抽水井：抽水機放在往下鑽的岩芯孔套管上。井那一欄的水頭壓到孔底（不低於含水層底）；周圍流進來的比抽水機抽得多，
--   水頭就停在剛好抽得完的高度（Σ k·b·(H_鄰 − h) = 抽水量）。抽出來的水倒在機器後面（排水溝就排掉）；出水擋住就停。
-- 降雨入滲（weather.lua 的時雨量 I）：只算在計算範圍裡（漏斗）。天然水位當作已經跟平常的雨平衡，範圍外不動，
--   所以水位最多回到天然水位、不會漲得更高（下雨時孔隙水壓變大、邊坡變弱還是照 weather.lua 的摩擦角規則）。
--   土欄：地面是露天（正午陽光照得到）的土，每秒補 α·I 進水位（入滲係數 α = rockmech_rain_infiltration），水位升 α·I·dt/Sy。
--     地面鋪了混凝土、蓋了東西、在隧道裡：不入滲。
--   露天與否每 SKY_DT 秒重看一次（只在下雨時、一次最多 SKY_MAX 欄）。
-- 雨滴（降雨落地，只有單機地圖 rockmech_solo）：每個玩家周圍 DROP_R m 內，照時雨量隨機丟「一級水」（1/8 m³），平均總量 = I × 面積 × 時間。
--   從天空往下找第一格不像空氣的；那一格上面正午有直射陽光才算露天。
--   只有挖過、蓋過的地方接雨：上面那一格是挖開的、落在液面上、或落在混凝土上。天然地面不接（土會滲掉、天然岩坡不管）。
--   落在土上：滲掉（土的透水係數遠大於時雨量，沒有地表逕流；漏斗裡照上面的入滲係數補地下水）。
--   落在岩石、混凝土上：往最陡的下坡走（地表逕流，最多 RUN_MAX 步），停在低處或流進液體；落在碎石上先進孔隙。
-- 蒸發：雨停 EVAP_DELAY 秒後，下過雨的地方只剩一級、四周也沒有更深的水（薄水膜）就蒸發掉。窪地裡的積水留著。
-- 排水溝：液體流到旁邊、上面就沒了（每步 DRAIN 級）。給深開挖的地圖把抽出來的水排掉。
-- 抽水機：放在坑邊，吸管朝前伸進坑裡（跟出液口一樣朝放的人那一側）；每秒從前面那一欄的液面抽 PUMP_RATE 級，
--   倒在機器後面那一格（守恆）；後面那一格是排水溝就直接排掉。

local S = rockmech.S
local setting = rockmech.get_setting or function(k) return core.settings:get(k) end
local NL = rockmech.RUBBLE_LEVELS
local WATER = rockmech.LIQUID_WATER

local K = tonumber(setting("rockmech_soil_permeability") or "") or 1e-3          -- 透水係數（m/s）
local SY = (rockmech.SOIL_POROSITY or 0.4) * (1 - (rockmech.SOIL_S0 or 0.33))     -- 給水度
local RANGE = tonumber(setting("rockmech_groundwater_range") or "") or 64        -- 計算範圍（離坑幾 m）
local EPS = 0.01                                                                  -- 跟天然水位差不到 1 cm 不算
local BASE_MAX = 40                                                               -- 含水層最厚（m）
local GROW_MAX = 500                                                              -- 範圍每秒最多長幾欄
local STEP_DT = 1                                                                 -- 每幾秒推進一次
local PUMP_RATE = tonumber(setting("rockmech_pump_rate") or "") or 1             -- 級／秒
local HOSE = 30                                                                   -- 吸管長（m）
local DRAIN = 8                                                                   -- 排水溝每步吃掉幾級
local ALPHA = tonumber(setting("rockmech_rain_infiltration") or "") or 0.3       -- 入滲係數（雨量進到地下水的比例）
local SKY_DT, SKY_MAX = 60, 500                                                   -- 露天重看的間隔（秒）、一次最多幾欄
local APERTURE = (tonumber(setting("rockmech_joint_aperture") or "") or 0.1) / 1000  -- 裂隙開口寬（mm → m）
local JV_C = tonumber(setting("rockmech_rock_seep_jv") or "") or 23              -- 岩石透水的門檻（Jv，條/m³）
local KF = 2 / 3 * 9.81 * APERTURE ^ 3 / (12 * 1.0e-6)                           -- 立方定律：每 1 條/m³ 的透水係數（m/s）
local SY_MIN = 1e-3                                                               -- 給水度的下限（不透水的格，數值穩定用）
local GROW_US = 20000                                                             -- 範圍每秒長的時間預算（微秒）
local AQ_T = 3                                                                    -- 阻水層：連續這麼多 m 不透水就是含水層底

-- 滲流 -------------------------------------------------------------------
local storage = core.get_mod_storage()
local natural = rockmech.water_table_natural
local soil_frac = rockmech.soil_frac
local cell = rockmech.slurry_cell
local is_excavated = rockmech.collapse.is_excavated
local function ckey(x, z) return (x + 32768) * 65536 + (z + 32768) end
local function cxz(k) local a = math.floor(k / 65536); return a - 32768, k - a * 65536 - 32768 end
local function H0(x, z) local w = natural(x, z); return w and w + 0.5 end

-- 岩石那一格的體積節理數 Jv（條/m³）：細裂隙（GSI → RQD → Jv，Palmström）＋粗節理（六個面裡是節理的面數 ÷ 3）。不是岩石 nil
local lith_of_node = rockmech.lith_of_node
local function rock_jv(p, node)
	local lith = lith_of_node[node.name]
	if not lith then return nil end
	local key = lith.name
	local L = rockmech.cfg.lithologies[key]
	local gsi = node.param2
	if not gsi or gsi < 1 or gsi > 100 or (L and L.ore) then gsi = rockmech.collapse.rock.gsi(key, p.y) end
	local q = (L and L.jr or 2) / (L and L.ja or 1)
	local rqd = math.max(0, math.min(100, 2 * (gsi - 52 * q / (1 + q))))
	local m = rockmech.joints.cell_mask(rockmech.get_joint_sets(), p.x, p.y, p.z)
	local c = 0
	while m > 0 do c = c + m % 2; m = math.floor(m / 2) end
	return math.max(0, (115 - rqd) / 3.3) + c / 3
end
rockmech.rock_jv = rock_jv
-- 那一格的透水係數、給水度
local function rock_k(jv)
	if jv and jv >= JV_C then return KF * jv, APERTURE * jv end
	return 0, 0
end
rockmech.rock_permeability = function(p)
	local node = core.get_node(p)
	local jv = rock_jv(p, node)
	if not jv then return nil end
	local k, sy = rock_k(jv)
	return k, sy, jv
end

-- 一欄：天然水位以下往下看。回傳 {h0, base, low, hs, ybot, kk, sy, ct}（low/hs：坑的最低格、坑的水頭；沒有坑就 nil；
-- kk、sy：含水層底那一格往上每一格的透水係數、給水度，ct：累積的導水係數）；nil = 沒有地下水；false = 還沒載入
local function scan(x, z)
	local h0 = H0(x, z)
	if not h0 then return nil end
	local top = math.floor(h0 - 0.5)
	local p = {x = x, y = top, z = z}
	local stacks = {}                       -- 空格堆的最低格（由上往下）
	local prev_open = false
	local ks, ss = {}, {}                   -- 由上往下
	local low_perm                          -- 最低的透水格（第幾格）
	local run = 0                           -- 連續不透水的格數
	for y = top, top - BASE_MAX, -1 do
		p.y = y
		local node = core.get_node(p)
		local n = node.name
		if n == "ignore" then return false end
		local open, k, sy = false, K, SY
		if not soil_frac[n] then
			local r, w = cell(p)
			if r then
				open = w > 0 or is_excavated(p)          -- 天然的崩積土、空洞：跟周圍的土一起飽和，不算坑
			else
				k, sy = rock_k(rock_jv(p, node))         -- 岩石照 Jv；混凝土這類 nil → 不透水
			end
		end
		ks[#ks + 1], ss[#ss + 1] = k, sy
		if k > 0 or open then low_perm = #ks; run = 0 else run = run + 1 end
		if open then
			if prev_open then stacks[#stacks].low = y else stacks[#stacks + 1] = {low = y, top = y} end
		end
		prev_open = open
		if run >= AQ_T then break end           -- 阻水層：含水層到這裡為止
	end
	local nb = low_perm or 0
	local base = top + 0.5 - nb
	local info = {h0 = h0, base = base}
	if nb > 0 then
		local kk, sy, ct = {}, {}, {0}
		for j = nb, 1, -1 do                    -- 由下往上
			kk[#kk + 1], sy[#sy + 1] = ks[j], ss[j]
			ct[#ct + 1] = ct[#ct] + ks[j]
		end
		info.ybot, info.kk, info.sy, info.ct = top - nb + 1, kk, sy, ct
	end
	-- 由下往上：第一個有自由液面的空格堆（灌滿、上面又是土的不算）
	for i = #stacks, 1, -1 do
		local low = stacks[i].low
		local h, free = low - 0.5, false
		local q = {x = x, y = low, z = z}
		for _ = 1, 64 do
			local r, w = cell(q)
			if not r then break end
			local cap = rockmech.liquid_cap(r)
			local f = cap > 0 and math.min(1, w / cap) or 1
			h = h + f
			if f < 1 then free = true; break end
			q.y = q.y + 1
		end
		if free then info.low, info.hs, info.ltop = low, h, stacks[i].top; break end
	end
	return info
end
-- 一欄在水位 h 時的導水係數 T（m²/s）、水位所在那一格的給水度
local function T_of(i, h)
	local kk = i.kk
	if not kk then return K * math.max(0, h - i.base) end          -- 存檔讀回來、還沒重看的
	local m = math.floor(h + 0.5) - i.ybot + 1
	if m < 1 then return 0 end
	if m > #kk then return i.ct[#kk + 1] end
	return i.ct[m] + kk[m] * (h - (i.ybot + m - 1.5))
end
local function Sy_of(i, h)
	local s = i.sy
	if not s then return SY end
	local m = math.floor(h + 0.5) - i.ybot + 1
	if m < 1 then m = 1 elseif m > #s then m = #s end
	-- 水位在不透水的格（沒有存水）：水位很快穿過去，用底下最近一格透水層的給水度（不然要切很多步）
	while m > 1 and s[m] <= 0 do m = m - 1 end
	local v = s[m]
	return v > SY_MIN and v or SY_MIN
end
local function aquifer(i) return i and (i.low or T_of(i, i.h0) > 1e-9) end

local info = {}         -- 範圍內的欄 → scan 的結果（土欄的 low 是 nil）
local H = {}            -- 範圍內的土欄 → 現在的水位
local OPEN = {}         -- 範圍內的坑 → 水頭
local DIST = {}         -- 範圍內的欄 → 離坑幾 m（4 鄰的步數）
local ROCK = {}         -- 查過、不是含水層的欄（岩石、沒有地下水）
local BND = {}          -- 範圍外緣的欄 → 天然水位
local dirty = {}        -- 要重看的欄
local WELL = {}         -- 抽水井的欄 → {bot = 孔底高程, cap = 抽水量 m³/s, h = 井的水頭, out = 累積抽出的 m³, seen = 上次抽的時間}
local acc = {}          -- 坑 → 累積的級數
local SKY = {}          -- 欄 → {露天, 上次看的時間}
local D4 = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

-- 算出來的水位：範圍內照算的，其他照天然
rockmech.water_table_y = function(x, z)
	local k = ckey(x, z)
	local h = H[k] or OPEN[k] or (WELL[k] and WELL[k].h)
	if h then
		local i = info[k]
		if i and h > i.h0 then h = i.h0 end
		return math.floor(h - 0.5 + 1e-6)
	end
	return natural(x, z)
end

-- 把一欄加進範圍（已經 scan 過）
local function add(k, i, d)
	info[k] = i
	DIST[k] = math.min(DIST[k] or d, d)
	BND[k] = nil
	if i.low then OPEN[k] = math.min(i.hs, i.h0); H[k] = nil
	elseif not H[k] then H[k] = i.h0 end
end
local function drop(k) info[k], H[k], OPEN[k], DIST[k], acc[k], SKY[k] = nil, nil, nil, nil, nil, nil end
-- 坑旁邊的土欄要在範圍裡（不然坑收不到水）
local function add_ring(k)
	local x, z = cxz(k)
	for _, dd in ipairs(D4) do
		local nk = ckey(x + dd[1], z + dd[2])
		if not info[nk] and not ROCK[nk] then
			local i = scan(x + dd[1], z + dd[2])
			if i == nil or (i and not aquifer(i)) then ROCK[nk] = true
			elseif i then add(nk, i, 1) end
		end
	end
end
-- 一欄重看完
local function update(k, i)
	if not i then
		if i == nil and info[k] then drop(k) end
		return
	end
	if i.low then
		if i.h0 - i.hs > EPS or info[k] then add(k, i, 0); add_ring(k) end
	elseif OPEN[k] then                           -- 坑填回去了
		local h = OPEN[k]
		OPEN[k] = nil; info[k] = i; H[k] = math.min(h, i.h0)
	elseif info[k] then info[k] = i end
end

-- 鄰欄的水頭和那一欄（範圍外：天然水位，nil = 導水係數跟自己一樣）
local function nb_head(nk)
	local h = H[nk]
	if h then return h, info[nk], false end
	local w = WELL[nk]
	if w then return w.h, info[nk], true end
	h = OPEN[nk]
	if h then return h, info[nk], true end
	if ROCK[nk] then return nil end
	h = BND[nk]
	if not h then
		local x, z = cxz(nk)
		h = H0(x, z)
		if not h then ROCK[nk] = true; return nil end
		BND[nk] = h
	end
	return h, nil, false
end

local SUN = 15                                                                    -- 直射陽光的亮度
-- 露天：土欄從天然水位往上穿過土、碎石到地面，地面上那一格正午有直射陽光；坑從水面往上找第一格空氣
local function sky_of(k)
	local x, z = cxz(k)
	local i = info[k]
	local p = {x = x, y = i.low and math.floor(i.hs + 0.5) or math.floor(i.h0 - 0.5) + 1, z = z}
	for _ = 1, 48 do
		local n = core.get_node(p).name
		if n == "ignore" then return false end
		if n == "air" then
			local l = core.get_node_light(p, 0.5)
			return l ~= nil and l >= SUN
		end
		if not soil_frac[n] and not cell(p) then return false end          -- 混凝土、岩石、建物：不透水
		p.y = p.y + 1
	end
	return false
end
local function sky_refresh(now)
	local n = 0
	for k in pairs(info) do
		local s = SKY[k]
		if not s or now - s[2] > SKY_DT * 1e6 then
			SKY[k] = {sky_of(k), now}
			n = n + 1
			if n >= SKY_MAX then return end
		end
	end
end

-- 推進 dt 秒（顯式：先算每一欄的淨流量再一起改；坑收到的累積起來）
local inflow_now = {}   -- 坑 → 最近一步的流量（m³/s）
local function advance(dt)
	-- 穩定：dt ≤ Sy / (4·T)（每一欄；岩石的給水度小，可能要切比較多步）
	local rmax = K / SY
	for k, h in pairs(H) do
		local i = info[k]
		local r = T_of(i, h) / Sy_of(i, h)
		if r > rmax then rmax = r end
	end
	local n = math.min(60, math.max(1, math.ceil(dt * 4 * rmax / 0.8)))
	if rockmech.groundwater_stats then rockmech.groundwater_stats.sub = n end
	local h_dt = dt / n
	local q_open = {}
	-- 下雨：I（mm/h → m/s）
	local I = (rockmech.raining_now and rockmech.rain_i_now or 0) / 3.6e6
	local R = ALPHA * I
	-- 井的水頭：壓到孔底；周圍流進來的比抽水量多就停在 Σ k·t·(H_鄰 − h) = 抽水量 的高度
	local now = core.get_us_time()
	for k, w in pairs(WELL) do
		if now - w.seen > 5e6 then                       -- 抽水機沒在抽了（拿走、區塊沒載入）
			WELL[k] = nil
			local i = info[k]
			if i then H[k] = math.min(w.h, i.h0) end
		else
			local x, z = cxz(k)
			local sk, skh = 0, 0
			for _, dd in ipairs(D4) do
				local hj, nj = nb_head(ckey(x + dd[1], z + dd[2]))
				if hj and not WELL[ckey(x + dd[1], z + dd[2])] then
					local ij = nj or info[k]
					local t = (T_of(ij, hj) + T_of(ij, w.h)) / 2
					if t > 0 then sk = sk + t; skh = skh + t * hj end
				end
			end
			local h = sk > 0 and (skh - w.cap) / sk or info[k].h0
			if h < w.bot then h = w.bot end
			if h > info[k].h0 then h = info[k].h0 end
			w.h = h
		end
	end
	for _ = 1, n do
		local dH = {}
		for k, hi in pairs(H) do
			local x, z = cxz(k)
			local i = info[k]
			local ti = T_of(i, hi)
			local net = 0
			for _, dd in ipairs(D4) do
				local nk = ckey(x + dd[1], z + dd[2])
				local hj, nj, open = nb_head(nk)
				if hj then
					-- 坑要有一部分在這一欄的含水層裡（坑頂高過含水層底）；坑底低過含水層底時，水頭差算到含水層底
					if open then
						if not (nj and nj.ltop and nj.ltop + 0.5 <= i.base) then
							if hj < i.base then hj = i.base end
							if hj < hi then                               -- 流進坑（坑比土高不往回流）：照這一欄自己的層算
								local q = (ti + T_of(i, hj)) / 2 * (hi - hj)
								net = net - q
								q_open[nk] = (q_open[nk] or 0) + q * h_dt
							end
						end
					else
						local tj = nj and T_of(nj, hj) or ti
						net = net + (ti + tj) / 2 * (hj - hi)
					end
				end
			end
			if R > 0 and SKY[k] and SKY[k][1] then net = net + R end
			dH[k] = net * h_dt / Sy_of(i, hi)
		end
		for k, d in pairs(dH) do
			local i = info[k]
			local h = H[k] + d
			if h > i.h0 then h = i.h0 elseif h < i.base then h = i.base end
			H[k] = h
		end
	end
	inflow_now = {}
	for k, v in pairs(q_open) do
		local w = WELL[k]
		if w then w.out = w.out + v
		else acc[k] = (acc[k] or 0) + v * NL end          -- m³ → 級
		inflow_now[k] = v / dt
	end
end
rockmech.groundwater_inflow = function(x, z) return inflow_now[ckey(x, z)] or 0 end
rockmech.groundwater_acc = function(x, z) return acc[ckey(x, z)] or 0 end

-- 範圍往外長：水位降了 EPS 以上的欄，旁邊還不在範圍裡的（RANGE 以內）加進來；回到天然的拿掉
local function grow()
	local new = {}
	for k, h in pairs(H) do
		local i = info[k]
		if i.h0 - h > EPS and DIST[k] < RANGE then
			local x, z = cxz(k)
			for _, dd in ipairs(D4) do
				local nk = ckey(x + dd[1], z + dd[2])
				if not info[nk] and not ROCK[nk] and not new[nk] then new[nk] = DIST[k] + 1 end
			end
		end
	end
	local n = 0
	local t0 = core.get_us_time()
	for nk, d in pairs(new) do
		local x, z = cxz(nk)
		local i = scan(x, z)
		if i == nil or (i and not aquifer(i)) then ROCK[nk] = true
		elseif i then add(nk, i, d) end
		n = n + 1
		-- 一次最多長 GROW_MAX 欄、GROW_US 微秒（每欄要往下讀地圖、岩石要算 Jv，分散到好幾秒）
		if n >= GROW_MAX or core.get_us_time() - t0 > GROW_US then break end
	end
	-- 沒有坑在抽了、全部回到天然：清掉
	local active = next(WELL) ~= nil
	for k, h in pairs(OPEN) do if info[k].h0 - h > EPS then active = true; break end end
	if not active then
		local far = false
		for k, h in pairs(H) do if info[k].h0 - h > EPS then far = true; break end end
		if not far then
			for k in pairs(info) do drop(k) end
			BND, ROCK = {}, {}
		end
	end
end

local function deliver()
	-- 零星的冒水（隧道很長、每欄冒得少，各欄都不到一級）：相連的坑欄（一整條隧道、一個坑）當成一區，
	-- 累積的量加起來，放在那一區水面最低的那一欄
	local seen = {}
	for k, a in pairs(acc) do
		if a > 0 and OPEN[k] and not seen[k] then
			seen[k] = true
			local q, tot, best, bh = {k}, 0, k, OPEN[k]
			local j = 1
			while q[j] and j <= 4096 do
				local c = q[j]; j = j + 1
				tot = tot + (acc[c] or 0)
				acc[c] = nil
				if OPEN[c] < bh then best, bh = c, OPEN[c] end
				local x, z = cxz(c)
				for _, dd in ipairs(D4) do
					local nk = ckey(x + dd[1], z + dd[2])
					if OPEN[nk] and not seen[nk] then seen[nk] = true; q[#q + 1] = nk end
				end
			end
			acc[best] = tot
		end
	end
	for k, a in pairs(acc) do
		local add_n = math.floor(a)
		if add_n > 0 and OPEN[k] then
			local x, z = cxz(k)
			local i = info[k]
			local p = {x = x, y = i.low, z = z}
			for _ = 1, 64 do                          -- 坑裡最低、還有空間的那一格
				local r, w = cell(p)
				if not r then p = nil; break end
				if w < rockmech.liquid_cap(r) then break end
				p.y = p.y + 1
			end
			if p and core.get_node(p).name ~= "ignore" then
				local left = rockmech.slurry_add_at(p, add_n, WATER)
				if rockmech.groundwater_stats then rockmech.groundwater_stats.delivered = (rockmech.groundwater_stats.delivered or 0) + add_n - left end
				a = a - (add_n - left)
				if left < add_n then rockmech.slurry_schedule(p); rockmech.slurry_wake(p) end
			end
			if a > 1 then a = 1 end
			acc[k] = a
			dirty[k] = true                            -- 水面變了：重看坑的水頭
		elseif not OPEN[k] then acc[k] = nil end
	end
end

-- 抽水井（抽水機每秒呼叫）：(x, z, 孔底高程, 抽水量 m³/s) → 這段時間抽出來的 m³、最近一步的流量（m³/s）；抽水量 nil = 停
function rockmech.groundwater_well(x, z, bot, cap)
	local k = ckey(x, z)
	local w = WELL[k]
	if not cap then
		if w then
			WELL[k] = nil
			local i = info[k]
			if i then H[k] = math.min(w.h, i.h0) end
		end
		return 0
	end
	if not w then
		local i = info[k] or scan(x, z)
		if not i or i.low or not aquifer(i) then return 0 end      -- 沒有地下水、是坑
		if math.max(bot, i.base) >= i.h0 then return 0 end         -- 孔底在水位以上（或含水層底以下的部分是岩石）
		add(k, i, 0)
		w = {bot = math.max(bot, i.base), h = H[k] or i.h0, out = 0}
		H[k] = nil
		WELL[k] = w
		add_ring(k)
	end
	w.cap, w.seen = cap, core.get_us_time()
	local o = w.out
	w.out = 0
	return o, inflow_now[k] or 0
end

-- 一格騰出空間、挖開（slurry.lua 呼叫）：在天然水位附近以下就重看那一欄
function rockmech.groundwater_poke(p)
	local wt = natural(p.x, p.z)
	if not wt or p.y > wt + 1 then return end
	dirty[ckey(p.x, p.z)] = true
end

-- 地圖被 VoxelManip 直接改寫（爆破、大崩塌）：範圍裡的欄重看（隧道爆破開出來的空間也算坑）
do
	local prev = rockmech.map_written
	function rockmech.map_written(a, b)
		if prev then prev(a, b) end
		local x1, x2 = math.min(a.x, b.x), math.max(a.x, b.x)
		local z1, z2 = math.min(a.z, b.z), math.max(a.z, b.z)
		if (x2 - x1 + 1) * (z2 - z1 + 1) > 4096 then return end
		local ylo = math.min(a.y, b.y)
		for x = x1, x2 do for z = z1, z2 do
			local wt = natural(x, z)
			if wt and ylo <= wt + 1 then dirty[ckey(x, z)] = true end
		end end
	end
end

-- 現在的水位（水面高程，浮點數）：範圍內照算的，其他照天然；沒有地下水 nil（femstress.lua 算孔隙水壓）
rockmech.groundwater_head = function(x, z)
	local h0 = H0(x, z)
	if not h0 then return nil end
	local k = ckey(x, z)
	local h = H[k] or OPEN[k] or (WELL[k] and WELL[k].h)
	if h and h < h0 then return h end
	return h0
end

-- 水位變了，土的孔隙水壓跟著變：每 FEM_DT 秒看一次，同一區（應力解範圍的一半）有一欄比上次排應力解時差 FEM_DH 以上，
-- 就排一次；一次最多 FEM_MAX 區（水位變最多的先，其他的下次）。應力解在主執行緒組工作要幾十 ms、背景一次只解一個，
-- 排太勤會卡。只看坑、井旁邊 FEM_NEAR m 內的欄：遠處完整的地盤沒有臨空面，水位降了也不會崩，不必重算
local FEM_DH, FEM_DT, FEM_NEAR, FEM_MAX = 1.0, 30, 4, 4
local HQ = {}            -- 欄 → 上次排應力解時的水位
local stats
local function fem_check()
	local fc = rockmech.cfg and rockmech.cfg.fem
	if not rockmech.fem_queue or not fc or not fc.drive then return end
	local s = math.max(1, math.floor(fc.radius / 2))
	local function region(k) local x, z = cxz(k); return math.floor(x / s) .. "," .. math.floor(z / s) end
	local hit = {}
	for k, h in pairs(H) do
		local d = DIST[k] <= FEM_NEAR and math.abs(h - (HQ[k] or info[k].h0)) or 0
		if d >= FEM_DH then
			local rk = region(k)
			if not hit[rk] or d > hit[rk].d then local x, z = cxz(k); hit[rk] = {d = d, rk = rk, p = {x = x, y = math.floor(h), z = z}} end
		end
	end
	local list = {}
	for _, v in pairs(hit) do list[#list + 1] = v end
	if #list == 0 then return end
	table.sort(list, function(a, b) return a.d > b.d end)
	local take = {}
	for i = 1, math.min(FEM_MAX, #list) do take[list[i].rk] = list[i].p end
	for k, h in pairs(H) do if take[region(k)] then HQ[k] = h end end
	for _, p in pairs(take) do rockmech.fem_queue(p, 1, false, true); stats.fem_queued = stats.fem_queued + 1 end
end

-- 效能統計（微秒）：最近一次每一段花的時間、開機以來最久的一次、累計；n_dom 範圍內的土欄數
-- max_advance、max_grow、max_sky：那一段最久的一次（sky：下雨時重看露天）；fem_queued：水位變動排了幾次應力解
stats = {dirty = 0, advance = 0, deliver = 0, grow = 0, fem = 0, total = 0, max = 0, sum = 0, n = 0, n_dom = 0,
	max_advance = 0, max_grow = 0, fem_queued = 0, sky = 0, max_sky = 0}
rockmech.groundwater_stats = stats
local t_acc, t_fem = 0, 0
if rockmech.GROUNDWATER_DEPTH then
	core.register_globalstep(function(dt)
		t_acc = t_acc + dt
		if t_acc < STEP_DT then return end
		local step_dt = math.min(t_acc, 5)
		t_acc = 0
		local us = core.get_us_time
		local t0 = us()
		for k in pairs(dirty) do                         -- 一次最多 GROW_US 微秒（隧道一次挖開很多欄：分散到好幾秒）
			local x, z = cxz(k)
			local i = scan(x, z)
			if i ~= false then dirty[k] = nil; update(k, i) end
			if us() - t0 > GROW_US then break end
		end
		local t1 = us()
		stats.dirty = t1 - t0
		if not next(info) then
			HQ = {}
			stats.advance, stats.deliver, stats.grow, stats.fem, stats.total, stats.n_dom = 0, 0, 0, 0, t1 - t0, 0
			return
		end
		local ts = us()
		if rockmech.raining_now and (rockmech.rain_i_now or 0) > 0 then sky_refresh(ts) end
		stats.sky = us() - ts
		if stats.sky > stats.max_sky then stats.max_sky = stats.sky end
		advance(step_dt)
		local t2 = us()
		deliver()
		local t3 = us()
		grow()
		local t4 = us()
		t_fem = t_fem + step_dt
		if t_fem >= FEM_DT then t_fem = 0; fem_check() end
		local t5 = us()
		stats.advance, stats.deliver, stats.grow, stats.fem, stats.total = t2 - t1, t3 - t2, t4 - t3, t5 - t4, t5 - t0
		if stats.advance > stats.max_advance then stats.max_advance = stats.advance end
		if stats.grow > stats.max_grow then stats.max_grow = stats.grow end
		if stats.total > stats.max then stats.max = stats.total end
		stats.sum, stats.n = stats.sum + stats.total, stats.n + 1
		local nd = 0
		for _ in pairs(H) do nd = nd + 1 end
		stats.n_dom = nd
	end)
	-- 關遊戲時記下每一欄的水位，下次接著算
	local saved = core.deserialize(storage:get_string("gw_state")) or {}
	for k, v in pairs(saved.H or {}) do
		info[k] = {h0 = v[2], base = v[3]}; H[k] = v[1]; DIST[k] = v[4]
		dirty[k] = true                                  -- 重看一次，補上每一格的透水係數
	end
	for k in pairs(saved.OPEN or {}) do dirty[k] = true end
	core.register_on_shutdown(function()
		local h, o = {}, {}
		for k, v in pairs(H) do h[k] = {v, info[k].h0, info[k].base, DIST[k]} end
		for k in pairs(OPEN) do o[k] = true end
		storage:set_string("gw_state", core.serialize({H = h, OPEN = o}))
	end)
end
rockmech.groundwater_state = function()
	local n = 0
	for _ in pairs(H) do n = n + 1 end
	return {dom = n, H = H, OPEN = OPEN, info = info, WELL = WELL, SKY = SKY}
end

-- 雨滴 -------------------------------------------------------------------
local DROP_R, RUN_MAX, EVAP_DELAY, EVAP_MAX = 48, 32, 300, 2000
local level_of_n = rockmech.slurry_level
local air_like = rockmech.air_like
local function paved(n) return n:sub(1, 17) == "rockmech:concrete" end
local RAINED = core.deserialize(storage:get_string("rain_cells")) or {}   -- 下過雨的格（位置 hash）→ true
local drop_stats = {n = 0, kept = 0}
rockmech.rain_drop_stats = drop_stats
local function gname(p) return core.get_node(p).name end
-- p 是空格：往下掉到有東西撐著的那一格；回傳撐著的那一格和它的方塊名稱（掉太深、沒載入 nil）
local function fall(p)
	local q = {x = p.x, y = p.y - 1, z = p.z}
	for _ = 1, 32 do
		local n = gname(q)
		if n == "ignore" then return nil end
		if not air_like(n) then return q, n end
		q.y = q.y - 1
	end
end
local function put(p)
	RAINED[core.hash_node_position(p)] = true
	rockmech.slurry_schedule(p); rockmech.slurry_wake(p)
	drop_stats.kept = drop_stats.kept + 1
end
-- 一滴雨落在 (x, z)：從 y0 往下找
local function drop_at(x, z, y0)
	local p = {x = x, y = y0, z = z}
	if not air_like(gname(p)) then return end                -- 起點就在山裡
	local n
	p, n = fall(p)
	if not p then return end
	local up = {x = x, y = p.y + 1, z = z}
	if (core.get_node_light(up, 0.5) or 0) < SUN then return end      -- 有東西遮著
	if not (level_of_n[n] or paved(n) or is_excavated(up)) then return end
	-- 地表逕流：往最陡的下坡走（液面上不走）
	for _ = 1, RUN_MAX do
		if level_of_n[n] then break end
		local best, bn, by = nil, nil, p.y
		for _, dd in ipairs(D4) do
			local q = {x = p.x + dd[1], y = up.y, z = p.z + dd[2]}
			local qn = gname(q)
			local s, sn, sy
			if level_of_n[qn] then s, sn, sy = q, qn, p.y - 0.5          -- 旁邊同一層有水：流進去
			elseif qn ~= "ignore" and air_like(qn) then
				s, sn = fall(q)
				sy = s and s.y
			end
			if s and sy < by then best, bn, by = s, sn, sy end
		end
		if not best then break end
		p, n = best, bn
		up = {x = p.x, y = p.y + 1, z = p.z}
	end
	if soil_frac[n] then return end                           -- 落在土上：滲掉
	if rockmech.liquid_drains[n] then return end
	if level_of_n[n] then
		if rockmech.slurry_add_up(p, 1, nil, WATER) == 0 then put(p) end
		return
	end
	local r = cell(p)
	if r and r > 0 and rockmech.slurry_add_at(p, 1, WATER) == 0 then put(p); return end      -- 碎石的孔隙
	if rockmech.slurry_add_up(up, 1, nil, WATER) == 0 then put(up) end
end
-- 薄水膜：一級、底下撐著（不是液體、不是空的）、四周沒有更深的水、是水（不是穩定液）
local function film(p)
	local n = gname(p)
	if level_of_n[n] ~= 1 then return false end
	local bn = gname({x = p.x, y = p.y - 1, z = p.z})
	if bn == "ignore" or air_like(bn) or level_of_n[bn] then return false end
	if (gname({x = p.x, y = p.y + 1, z = p.z}) ~= "air") then return false end
	for _, dd in ipairs(D4) do
		local k = level_of_n[gname({x = p.x + dd[1], y = p.y, z = p.z + dd[2]})]
		if k and k > 1 then return false end
	end
	return ((rockmech.liquid_comp(p).b or 0) < 0.05)
end
-- 從下過雨的格出發，沿著相連的一級水（水膜會往旁邊攤開）找，一次最多看 EVAP_MAX 格
local function evaporate()
	local n, seen = 0, {}
	for h in pairs(RAINED) do
		local p = core.get_position_from_hash(h)
		RAINED[h] = nil                                          -- 沒載入的不管（薄水膜留著）
		local q = {p, {x = p.x, y = p.y + 1, z = p.z}}
		local i = 1
		while q[i] do
			local c = q[i]
			i = i + 1
			local hc = core.hash_node_position(c)
			if not seen[hc] then
				seen[hc] = true
				n = n + 1
				if level_of_n[gname(c)] == 1 then
					for _, dd in ipairs(D4) do q[#q + 1] = {x = c.x + dd[1], y = c.y, z = c.z + dd[2]} end
					if film(c) then rockmech.slurry_set_level(c, 0) end
				end
			end
		end
		if n >= EVAP_MAX then return end
	end
end
local drop_acc, evap_t = 0, 0
-- 只有單機地圖（rockmech_solo）：上課的世界維持原本的玩法（下雨只弱化，不積水）
local DROPS_ON = rockmech.cfg.solo
core.register_globalstep(function(dt)
	if not DROPS_ON then return end
	local I = rockmech.raining_now and rockmech.rain_i_now or 0
	if I <= 0 then
		if not next(RAINED) then return end
		evap_t = evap_t + dt
		if evap_t >= EVAP_DELAY then evaporate(); evap_t = EVAP_DELAY - 1 end   -- 之後每秒處理一批
		return
	end
	evap_t = 0
	local players = core.get_connected_players()
	if #players == 0 then return end
	local side = 2 * DROP_R + 1
	drop_acc = drop_acc + I / 3.6e6 * side * side * NL * dt * #players
	local m = 0
	while drop_acc >= 1 and m < 50 do
		drop_acc, m = drop_acc - 1, m + 1
		local pl = players[math.random(#players)]:get_pos()
		local x, z = math.floor(pl.x + 0.5) + math.random(-DROP_R, DROP_R), math.floor(pl.z + 0.5) + math.random(-DROP_R, DROP_R)
		-- 幾個玩家的範圍重疊：照重疊的人數打折，總量不重複算
		local cover = 0
		for _, o in ipairs(players) do
			local op = o:get_pos()
			if math.abs(x - math.floor(op.x + 0.5)) <= DROP_R and math.abs(z - math.floor(op.z + 0.5)) <= DROP_R then cover = cover + 1 end
		end
		if math.random() * cover < 1 then
			drop_stats.n = drop_stats.n + 1
			drop_at(x, z, math.floor(pl.y + 0.5) + 32)
		end
	end
	if drop_acc > 50 then drop_acc = 50 end
end)
core.register_on_shutdown(function() storage:set_string("rain_cells", core.serialize(RAINED)) end)
rockmech.rain_drop_at = drop_at
rockmech.rain_evaporate = evaporate
rockmech.rain_cells = function() return RAINED end

-- 排水溝 -------------------------------------------------------------------
local DRAIN_NODE = "rockmech:drain"
core.register_node(DRAIN_NODE, {
	description = S("Drain\nWater that flows into it or onto it is carried away"),
	short_description = S("Drain"),
	drawtype = "nodebox",
	node_box = {type = "fixed", fixed = {
		{-0.5, -0.5, -0.5, 0.5, -0.375, 0.5},          -- 底
		{-0.5, -0.375, -0.5, -0.375, -0.0625, 0.5},    -- 兩側
		{0.375, -0.375, -0.5, 0.5, -0.0625, 0.5},
	}},
	selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.0625, 0.5}},
	tiles = {"[fill:16x16:#9a9a94^[fill:12x16:2,0:#5a6470", "[fill:16x16:#8a8a84", "[fill:16x16:#a2a29c"},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {cracky = 2},
	on_construct = function(pos)
		rockmech.slurry_wake(pos)
		rockmech.slurry_schedule({x = pos.x, y = pos.y + 1, z = pos.z})
	end,
})
rockmech.liquid_drains[DRAIN_NODE] = DRAIN
rockmech.DRAIN = DRAIN_NODE

-- 抽水機 -------------------------------------------------------------------
local PUMP = "rockmech:water_pump"
local function pump_dirs(node)
	local f = core.facedir_to_dir(node.param2)       -- 吸管伸出去的方向
	return f, {x = -f.x, y = 0, z = -f.z}
end
local function pump_info(pos, txt)
	core.get_meta(pos):set_string("infotext", S("Water pump") .. "\n" .. txt)
end
local function may(pos, name)
	local owner = core.get_meta(pos):get_string("owner")
	return rockmech.owner_ok and rockmech.owner_ok(owner, name) or owner == "" or owner == name
end
local level_of = rockmech.slurry_level
local CASING = "rockmech:borehole"
-- 出水口對著收水的設施（拌合廠的水箱，batching.lua）：rockmech.water_sinks[方塊名](pos, 級數) → 收了幾級
local function to_sink(out, n)
	local f = rockmech.water_sinks and rockmech.water_sinks[core.get_node(out).name]
	if not f then return nil end
	return f(out, n)
end
-- 抽水機底下是往下鑽的岩芯孔套管：孔底那一格的 y
local function well_bottom(pos)
	local c = {x = pos.x, y = pos.y - 1, z = pos.z}
	if core.get_node(c).name ~= CASING then return nil end
	return tonumber(core.get_meta(c):get_string("bottom"))
end
local function well_tick(pos, bot, out)
	local meta = core.get_meta(pos)
	local m3, rate = rockmech.groundwater_well(pos.x, pos.z, bot - 0.5, PUMP_RATE / NL)
	local a = meta:get_float("well_acc") + m3 * NL
	local n = math.floor(a)
	if n > 0 then
		local sunk = to_sink(out, n)
		if rockmech.liquid_drains[core.get_node(out).name] then a = a - n          -- 後面接著排水溝：直接排掉
		elseif sunk then
			if sunk < n then                            -- 水箱滿了：井停下來
				rockmech.groundwater_well(pos.x, pos.z, nil)
				meta:set_float("well_acc", 0)
				pump_info(pos, S("The tank it pumps into is full"))
				return
			end
			a = a - n
		else
			local left = rockmech.slurry_add_up(out, n, nil, WATER)
			rockmech.slurry_schedule(out); rockmech.slurry_wake(out)
			if left > 0 then                            -- 出水的地方擋住了：井停下來
				rockmech.groundwater_well(pos.x, pos.z, nil)
				meta:set_float("well_acc", 0)
				pump_info(pos, S("Outlet blocked"))
				return
			end
			a = a - n
		end
	end
	meta:set_float("well_acc", a)
	if (rate or 0) > 0 then pump_info(pos, S("Well") .. ": " .. S("Pumping @1 m³/h", math.floor(rate * 3600 + 0.5)))
	else pump_info(pos, S("No water in reach")) end
end
local function pump_tick(pos)
	local node = core.get_node(pos)
	local f, b = pump_dirs(node)
	local bot = well_bottom(pos)
	if bot then well_tick(pos, bot, vector.add(pos, b)); return end
	local col = vector.add(pos, f)
	-- 吸管：往下穿過空氣、液體，找第一格有液的（最多 HOSE m）
	local q, intake = vector.copy(col), nil
	for _ = 0, HOSE do
		local n = core.get_node(q).name
		local k = n == "air" and 0 or level_of[n]
		if not k then break end
		if k > 0 then intake = q; break end
		q.y = q.y - 1
	end
	if not intake then pump_info(pos, S("No water in reach")); return end
	local c = rockmech.liquid_comp(intake)
	local took = rockmech.slurry_take(intake, PUMP_RATE)
	if took <= 0 then pump_info(pos, S("No water in reach")); return end
	local out = vector.add(pos, b)
	if rockmech.liquid_drains[core.get_node(out).name] then       -- 後面接著排水溝：直接排掉
		pump_info(pos, S("Pumping @1 m³/h", math.floor(took / NL * 3600 + 0.5)))
		return
	end
	local sunk = to_sink(out, took)
	if sunk then                                    -- 打進拌合廠的水箱；滿了放回去
		if sunk < took then rockmech.slurry_add_up(intake, took - sunk, nil, c) end
		pump_info(pos, sunk > 0 and S("Pumping @1 m³/h", math.floor(sunk / NL * 3600 + 0.5)) or S("The tank it pumps into is full"))
		return
	end
	local left = rockmech.slurry_add_up(out, took, nil, c)
	if left > 0 then                                -- 出水的地方擋住了：放回去
		rockmech.slurry_add_up(intake, left, nil, c)
		pump_info(pos, S("Outlet blocked"))
	else
		pump_info(pos, S("Pumping @1 m³/h", math.floor(took / NL * 3600 + 0.5)))
	end
	rockmech.slurry_schedule(out); rockmech.slurry_wake(out)
end
core.register_node(PUMP, {
	description = S("Water pump\nThe suction hose points back at you: stand at the pit edge and place it on the far side. Pumps water from the pit and pours it out behind the pump; lead it into a drain") .. "\n" ..
		S("On a borehole casing it pumps the well and lowers the groundwater around it"),
	short_description = S("Water pump"),
	drawtype = "nodebox",
	node_box = {type = "fixed", fixed = {
		{-0.35, -0.5, -0.3, 0.35, 0.1, 0.3},           -- 機身
		{-0.06, -0.1, 0.3, 0.06, 0.02, 1.06},          -- 吸管（往前）
		{-0.06, -0.5, 0.94, 0.06, 0.02, 1.06},         -- 往下垂
		{-0.08, -0.45, -0.5, 0.08, -0.29, -0.3},       -- 出水口（往後）
	}},
	selection_box = {type = "fixed", fixed = {-0.35, -0.5, -0.3, 0.35, 0.1, 0.3}},
	collision_box = {type = "fixed", fixed = {-0.35, -0.5, -0.3, 0.35, 0.1, 0.3}},
	tiles = {"[fill:16x16:#3f73a8^[fill:10x10:3,3:#2a4e78", "[fill:16x16:#3a3f44", "[fill:16x16:#4a80b8^[fill:16x2:0,7:#2a4e78"},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {cracky = 2},
	on_construct = function(pos) core.get_node_timer(pos):start(1) end,
	on_destruct = function(pos) rockmech.groundwater_well(pos.x, pos.z, nil) end,
	after_place_node = function(pos, placer)
		if placer and placer.get_look_dir then
			local d = placer:get_look_dir()
			core.swap_node(pos, {name = PUMP, param2 = core.dir_to_facedir({x = -d.x, y = 0, z = -d.z})})
		end
		core.get_meta(pos):set_string("owner", placer and rockmech.account_of and rockmech.account_of(placer:get_player_name())
			or (placer and placer:get_player_name()) or "")
		pump_info(pos, S("No water in reach"))
	end,
	on_timer = function(pos) pump_tick(pos); return true end,
	can_dig = function(pos, player) return player and may(pos, player:get_player_name()) end,
})
core.register_lbm({
	label = "rockmech: 抽水機計時器", name = "rockmech:water_pump_timer", nodenames = {PUMP}, run_at_every_load = true,
	action = function(pos)
		local t = core.get_node_timer(pos)
		if not t:is_started() then t:start(1) end
	end,
})
rockmech.WATER_PUMP = PUMP
