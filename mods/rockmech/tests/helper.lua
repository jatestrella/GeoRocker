-- tests/helper.lua
-- 讓 spec 檔可同時用 busted 或純 lua（tests/run.lua）執行。
-- 提供：ROCKMECH_ROOT（mod 根目錄）、load_module(name)。
-- 若非 busted 環境，另提供最小的 describe/it/assert 子集。

local src = debug.getinfo(1, "S").source
local root = src:match("^@(.*[/\\])tests[/\\]helper%.lua$") or "./"
ROCKMECH_ROOT = root

function load_module(name)
	return dofile(root .. name .. ".lua")
end

if type(describe) == "function" then
	return -- busted 已提供
end

local results = {passed = 0, failed = 0, failures = {}}
TEST_RESULTS = results
local stack = {}

function describe(name, fn)
	stack[#stack + 1] = name
	fn()
	stack[#stack] = nil
end

function it(name, fn)
	local full = table.concat(stack, " > ") .. " > " .. name
	local ok, err = pcall(fn)
	if ok then
		results.passed = results.passed + 1
	else
		results.failed = results.failed + 1
		results.failures[#results.failures + 1] = full .. "\n    " .. tostring(err)
	end
end

local raw_assert = assert
local function fail(msg, level)
	error(msg, (level or 1) + 2)
end

local function fmt(v)
	return type(v) == "string" and ("%q"):format(v) or tostring(v)
end

local A = {}
A.are = {}
A.is = {}
function A.are.equal(expected, actual, msg)
	if expected ~= actual then
		fail((msg and msg .. ": " or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual))
	end
end
function A.are.same(expected, actual, msg)
	local function same(a, b)
		if type(a) ~= "table" or type(b) ~= "table" then return a == b end
		for k, v in pairs(a) do if not same(v, b[k]) then return false end end
		for k in pairs(b) do if a[k] == nil then return false end end
		return true
	end
	if not same(expected, actual) then
		fail((msg and msg .. ": " or "") .. "tables differ")
	end
end
function A.is_true(v, msg) if v ~= true then fail(msg or ("expected true, got " .. fmt(v))) end end
function A.is_false(v, msg) if v ~= false then fail(msg or ("expected false, got " .. fmt(v))) end end
function A.is_nil(v, msg) if v ~= nil then fail(msg or ("expected nil, got " .. fmt(v))) end end
function A.is_not_nil(v, msg) if v == nil then fail(msg or "expected non-nil") end end
function A.truthy(v, msg) if not v then fail(msg or ("expected truthy, got " .. fmt(v))) end end
function A.falsy(v, msg) if v then fail(msg or ("expected falsy, got " .. fmt(v))) end end
function A.near(expected, actual, tol, msg)
	if type(actual) ~= "number" or math.abs(expected - actual) > tol then
		fail((msg and msg .. ": " or "") .. "expected " .. fmt(expected) .. " ± " .. tol ..
			", got " .. fmt(actual))
	end
end
A.are.near = A.near
A.is.near = A.near
A.is.truthy = A.truthy
A.is.falsy = A.falsy

assert = setmetatable(A, {__call = function(_, ...) return raw_assert(...) end})
