dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local rockmass = load_module("rockmass")
local config = load_module("config")
local stress = load_module("stress")
local failure = load_module("failure", stress)

local SHALE = {gamma = 25, ucs = 30, tensile = 2, mi = 6}

describe("rockmass Hoek-Brown 參數", function()
	it("GSI 100、D 0：mb = mi、s = 1、a ≈ 0.5", function()
		local mb, s, a = rockmass.hb(100, 6, 0)
		assert.near(6, mb, 1e-12)
		assert.near(1, s, 1e-12)
		assert.near(0.5, a, 0.001)
	end)

	it("GSI 50、mi 6：mb 1.006、s 0.00387、a 0.506（Hoek 2002）", function()
		local mb, s, a = rockmass.hb(50, 6, 0)
		assert.near(1.006, mb, 0.001)
		assert.near(0.00387, s, 0.00001)
		assert.near(0.5057, a, 0.0001)
	end)

	it("擾動 D 讓 mb、s 變小", function()
		local mb0, s0 = rockmass.hb(50, 6, 0)
		local mb1, s1 = rockmass.hb(50, 6, 0.7)
		assert.is_true(mb1 < mb0)
		assert.is_true(s1 < s0)
	end)
end)

describe("rockmass 強度", function()
	it("GSI 100：臨空單軸 = σci、張力 = 實驗室 σt", function()
		local r = rockmass.params(SHALE, 100)
		assert.near(30, r.ucs_m, 0.01)
		assert.near(2, r.sigt, 1e-9)
	end)

	it("GSI 50：臨空單軸 σci·s^a ≈ 1.81、整體 σcm ≈ 4.1 MPa", function()
		local r = rockmass.params(SHALE, 50)
		assert.near(1.81, r.ucs_m, 0.01)
		assert.near(4.12, r.sigcm, 0.02)
		assert.near(2 * r.s * 6 / r.mb, r.sigt, 1e-12)
	end)

	it("相似比 N：σci、σt 都 ÷ N", function()
		local a = rockmass.params(SHALE, 50)
		local b = rockmass.params(SHALE, 50, {N = 5})
		assert.near(a.ucs_m / 5, b.ucs_m, 1e-12)
		assert.near(a.sigt / 5, b.sigt, 1e-12)
		assert.near(a.mb, b.mb, 1e-12)
	end)

	it("q_fail：σ3 = 0 時等於臨空單軸；圍壓越大越強；低於張力截斷為 0", function()
		local r = rockmass.params(SHALE, 50)
		assert.near(r.ucs_m, rockmass.q_fail(r, 0), 1e-12)
		assert.is_true(rockmass.q_fail(r, 1) > rockmass.q_fail(r, 0))
		assert.are.equal(0, rockmass.q_fail(r, -1))
	end)
end)

describe("rockmass GSI 深度剖面", function()
	it("地表 top、過渡深度以下 bottom、中間線性", function()
		local prof = {top = 30, bottom = 70, depth = 40}
		assert.are.equal(30, rockmass.gsi_at(prof, -10))   -- 高於 y0 的山丘
		assert.are.equal(30, rockmass.gsi_at(prof, 0))
		assert.are.equal(50, rockmass.gsi_at(prof, 20))
		assert.are.equal(70, rockmass.gsi_at(prof, 40))
		assert.are.equal(70, rockmass.gsi_at(prof, 500))
		assert.are.equal(45, rockmass.gsi_at({top = 45}, 100))
	end)

	it("查詢器：param2 1..100 優先於剖面；相同 (岩性, GSI) 共用快取", function()
		local cfg = {surface_y = 0, model_scale = 1, rockmass = {d = 0},
			lithologies = {shale = {gamma = 25, ucs = 30, tensile = 2, mi = 6,
				gsi = {top = 30, bottom = 70, depth = 40}}}}
		local q = rockmass.new(cfg)
		assert.are.equal(50, q.at("shale", -20, 0).gsi)
		assert.are.equal(80, q.at("shale", -20, 80).gsi)
		assert.are.equal(q.at("shale", -20), q.at("shale", -20, 50))
	end)
end)

describe("config 岩體設定", function()
	it("rockmech_gsi_<岩性> 與 rockmech_gsi、rockmech_model_scale", function()
		local set = {
			rockmech_gsi = "60",
			rockmech_gsi_shale = "35,65,40",
			rockmech_model_scale = "5",
			rockmech_mi_granite = "28",
		}
		local cfg, warnings = config.load(function(k) return set[k] end)
		assert.are.equal(0, #warnings)
		assert.are.equal(5, cfg.model_scale)
		assert.are.equal(35, cfg.lithologies.shale.gsi.top)
		assert.are.equal(65, cfg.lithologies.shale.gsi.bottom)
		assert.are.equal(40, cfg.lithologies.shale.gsi.depth)
		assert.are.equal(60, cfg.lithologies.granite.gsi.top)
		assert.are.equal(28, cfg.lithologies.granite.mi)
	end)

	it("未設定：GSI 100、N 1（與舊版相同的完整岩石）", function()
		local cfg = config.load(function() return nil end)
		assert.are.equal(1, cfg.model_scale)
		assert.are.equal(100, cfg.lithologies.shale.gsi.top)
	end)

	it("格式錯誤給警告", function()
		local _, warnings = config.load(function(k) return k == "rockmech_gsi_shale" and "30,40" or nil end)
		assert.are.equal(1, #warnings)
	end)
end)

describe("failure 使用 Hoek-Brown 岩體強度", function()
	-- 垂直壁：x ≥ 0 為岩石，x < 0 為空氣（z 向 9 格、深 30 m）
	local function wall()
		local g = {ox = -6, oy = -30, oz = -4, nx = 13, ny = 31, nz = 9, data = {},
			solid_of = {[1] = true}, weight_of = {[1] = 25}, lith_of = {[1] = "shale"}}
		for z = -4, 4 do for y = -30, 0 do for x = -6, 6 do
			g.data[failure.index(g, x, y, z)] = (x >= 0 and y < 0) and 1 or 0
		end end end
		return g
	end
	local function params(cfg)
		return {surface_y = 0, k0 = 0.5, window = 4, rock = rockmass.new(cfg),
			lithologies = cfg.lithologies}
	end

	it("GSI 越低，同一處的軸差 FS 越低；N 倍 → FS ÷ N", function()
		local g = wall()
		local function fs(gsi, n)
			local cfg = {surface_y = 0, model_scale = n, rockmass = {d = 0},
				lithologies = {shale = {gamma = 25, ucs = 30, tensile = 2, mi = 6, gsi = {top = gsi}}}}
			return failure.cell_state(g, 0, -20, 0, params(cfg))
		end
		local a, b, c = fs(100, 1), fs(40, 1), fs(40, 4)
		assert.is_true(b.fs_axial < a.fs_axial)
		assert.near(b.fs_axial / 4, c.fs_axial, 1e-9)
		assert.are.equal(40, b.rm.gsi)
		assert.near(0, b.s3, 1e-12)               -- 臨空面 σ3 = 0 → 強度 = 臨空單軸
		assert.near(b.rm.ucs_m, b.strength, 1e-12)
	end)

	it("頂板 Inglis：寬扁開口、K 小 → 頂板受拉、張裂；K 大 → 受壓", function()
		-- 地下 20 m 的開口：x −6..6（寬 13）、y −22..−20（高 3），z 全寬；上方岩石到 y = −1
		local g = {ox = -12, oy = -40, oz = -4, nx = 25, ny = 40, nz = 9, data = {},
			solid_of = {[1] = true}, weight_of = {[1] = 25}, lith_of = {[1] = "shale"}}
		for z = -4, 4 do for y = -40, -1 do for x = -12, 12 do
			local open = x >= -6 and x <= 6 and y >= -22 and y <= -20
			g.data[failure.index(g, x, y, z)] = open and 0 or 1
		end end end
		local cfg = {surface_y = 0, model_scale = 1, rockmass = {d = 0},
			lithologies = {shale = {gamma = 25, ucs = 30, tensile = 2, mi = 6, gsi = {top = 50}}}}
		local function roof(K)
			local p = params(cfg)
			p.KH, p.Kh = K, K
			return failure.cell_state(g, 0, -19, 0, p)
		end
		local lo, hi = roof(0.2), roof(1.5)
		assert.are.equal(3, lo.roof.H)
		assert.are.equal(13, lo.roof.Wx)
		-- σθ,x = Kσv·(1 + 2·3/13) − σv
		assert.near(0.2 * lo.sv0 * (1 + 6 / 13) - lo.sv0, lo.sx, 1e-9)
		assert.is_true(lo.sx < 0)
		assert.is_true(lo.fails_axial)          -- 張力截斷
		assert.is_true(hi.sx > 0)
		assert.is_false(hi.fails_axial)
	end)

	it("param2（g.p2）指定的 GSI 優先", function()
		local g = wall()
		g.p2 = {}
		g.p2[failure.index(g, 0, -20, 0)] = 90
		local cfg = {surface_y = 0, model_scale = 1, rockmass = {d = 0},
			lithologies = {shale = {gamma = 25, ucs = 30, tensile = 2, mi = 6, gsi = {top = 30}}}}
		local st = failure.cell_state(g, 0, -20, 0, params(cfg))
		assert.are.equal(90, st.rm.gsi)
		assert.are.equal(30, failure.cell_state(g, 0, -21, 0, params(cfg)).rm.gsi)
	end)
end)
