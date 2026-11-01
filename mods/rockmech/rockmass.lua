-- rockmech/rockmass.lua
-- 岩體強度（純函式，不依賴引擎）：廣義 Hoek-Brown（Hoek, Carranza-Torres & Corkum 2002）
-- 與相似比 N。
--
-- ## 岩體弱化（GSI）
--   mb = mi·exp((GSI − 100)/(28 − 14D))
--   s  = exp((GSI − 100)/(9 − 3D))
--   a  = 1/2 + (e^(−GSI/15) − e^(−20/3))/6
--   破壞：σ1 = σ3 + σci·(mb·σ3/σci + s)^a
--   單軸（臨空面 σ3 = 0）：σc,mass = σci·s^a
--   張力：σt,mass = σt·s·mi/mb（= Hoek-Brown 的 s·σci/mb 依實驗室 σt 校正，GSI 100 時等於 σt）
-- GSI 只代表格子內看不到的裂隙（< 1 m）與尺寸效應；明確建模的節理組由節理滑動處理，
-- 不要把它們再算進 GSI。
--
-- ## GSI 的空間分布
--   每格的 GSI：param2 = 1..100 時用 param2（之後建構世界可以逐格指定）；
--   param2 = 0（預設）時依岩性的深度剖面：深度 h = y0 − y，
--   GSI = top + (bottom − top)·clamp(h / depth, 0, 1)（地表 top、深度 ≥ depth 為 bottom）
--
-- ## 相似比 N
--   遊戲中 1 m 代表實際 N m：所有有應力單位的強度（σci、σt、節理 c）除以 N，φ 不變。
--   應力 ∝ γ·h，強度 ÷ N ⇔ 應力 × N，三種破壞模式的 FS 都等於實際尺度 N 倍時的 FS。

local rockmass = {}

local exp, max, min, floor = math.exp, math.max, math.min, math.floor

-- Hoek-Brown 參數
function rockmass.hb(gsi, mi, D)
	D = D or 0
	local mb = mi * exp((gsi - 100) / (28 - 14 * D))
	local s = exp((gsi - 100) / (9 - 3 * D))
	local a = 0.5 + (exp(-gsi / 15) - exp(-20 / 3)) / 6
	return mb, s, a
end

-- 深度剖面 prof = {top, bottom, depth} 在深度 h 的 GSI（整數 1..100）
function rockmass.gsi_at(prof, h)
	local g = prof.top
	if prof.depth and prof.depth > 0 and prof.bottom then
		local f = max(0, min(1, h / prof.depth))
		g = prof.top + (prof.bottom - prof.top) * f
	end
	return max(1, min(100, floor(g + 0.5)))
end

-- 某岩性在 GSI 下的強度參數。opts = {D, N, ucs_scale, tensile_scale}
-- 回傳 {gsi, sigci, mb, s, a, ucs_m（臨空面單軸強度）, sigt（張力強度）, sigcm（整體岩體強度）}，MPa
function rockmass.params(lith, gsi, opts)
	opts = opts or {}
	local N = opts.N or 1
	local mi = lith.mi or 10
	local mb, s, a = rockmass.hb(gsi, mi, opts.D or 0)
	local sigci = lith.ucs * (opts.ucs_scale or 1) / N
	local r = {gsi = gsi, sigci = sigci, mb = mb, s = s, a = a}
	r.ucs_m = sigci * s ^ a
	r.sigt = lith.tensile * (opts.tensile_scale or 1) / N * s * mi / mb
	-- 整體岩體強度 σcm（Hoek 2002），只供顯示
	r.sigcm = sigci * (mb + 4 * s - a * (mb - 8 * s)) * (mb / 4 + s) ^ (a - 1)
		/ (2 * (1 + a) * (2 + a))
	return r
end

-- 圍壓 σ3 下的破壞軸差 q_f = σ1,f − σ3（MPa）；σ3 低於張力截斷時為 0
function rockmass.q_fail(r, s3)
	local v = r.mb * s3 / r.sigci + r.s
	if v <= 0 then return 0 end
	return r.sigci * v ^ r.a
end

-- 建立查詢器：at(lith_key, y, gsi_override) → params（依 (岩性, GSI) 快取）。
-- cfg 需有 lithologies（含 gsi 剖面）、surface_y、rockmass = {d}、model_scale；
-- legacy = {ucs_scale, tensile_scale}（舊設定 strength_scale／overhang_scale，預設 1）
function rockmass.new(cfg, legacy)
	legacy = legacy or {}
	local opts = {D = cfg.rockmass and cfg.rockmass.d or 0, N = cfg.model_scale or 1,
		ucs_scale = legacy.ucs_scale or 1, tensile_scale = legacy.tensile_scale or 1}
	local cache = {}
	local q = {}
	function q.gsi(key, y)
		local lith = cfg.lithologies[key]
		local prof = lith and lith.gsi or {top = 100}
		return rockmass.gsi_at(prof, (cfg.surface_y or 0) - y)
	end
	function q.at(key, y, gsi)
		-- 礦石的 param2 是品位，不是 GSI
		if not gsi or gsi < 1 or gsi > 100 or cfg.lithologies[key].ore then gsi = q.gsi(key, y) end
		local c = cache[key]
		if not c then c = {}; cache[key] = c end
		local r = c[gsi]
		if not r then
			r = rockmass.params(cfg.lithologies[key], gsi, opts)
			c[gsi] = r
		end
		return r
	end
	q.N = opts.N
	q.q_fail = rockmass.q_fail
	return q
end

return rockmass
