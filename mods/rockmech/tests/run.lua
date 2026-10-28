-- tests/run.lua
-- 不需 busted 的測試執行器。於 mod 根目錄或任何位置執行：
--   lua tests/run.lua
--   luajit tests/run.lua
-- 若有 busted：在 mod 根目錄執行 `busted tests`（會自動找 *_spec.lua）。

local src = debug.getinfo(1, "S").source
local dir = src:match("^@(.*[/\\])run%.lua$") or "./tests/"

dofile(dir .. "helper.lua")

local SPECS = {
	"config_spec.lua",
	"stress_spec.lua",
	"joints_spec.lua",
	"failure_spec.lua",
	"rockfall_spec.lua",
	"stability_spec.lua",
	"rigidfall_spec.lua",
	"jointtex_spec.lua",
	"overhang_spec.lua",
	"keyblock_spec.lua",
	"granular_spec.lua",
	"blast_spec.lua",
	"rockmass_spec.lua",
}

for _, f in ipairs(SPECS) do
	dofile(dir .. f)
end

local r = TEST_RESULTS
for _, f in ipairs(r.failures) do
	print("FAIL: " .. f)
end
print(("%s  passed %d, failed %d"):format(_VERSION .. (jit and (" / " .. jit.version) or ""),
	r.passed, r.failed))
os.exit(r.failed == 0 and 0 or 1)
