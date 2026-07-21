-- 最简测试框架：提供 busted 风格的 describe/it 全局函数与 assert 扩展。
-- require 本模块即安装全局 describe/it 与 assert 扩展；harness.run() 执行
-- 已注册的用例并返回是否全部通过。生成的验收入口与本仓库 spec 共用此模块。

local harness = {}

local real_assert = assert

local suites = {}
local current_suite = nil

function harness.describe(name, fn)
  local suite = { name = name, tests = {} }
  suites[#suites + 1] = suite
  local previous = current_suite
  current_suite = suite
  local ok, err = xpcall(fn, debug.traceback)
  current_suite = previous
  if not ok then
    suite.tests[#suite.tests + 1] = {
      name = "<describe body>",
      fn = function()
        error(err, 0)
      end,
    }
  end
end

function harness.it(name, fn)
  real_assert(current_suite ~= nil, "it() called outside describe()")
  local suite_test = { name = name, fn = fn }
  current_suite.tests[#current_suite.tests + 1] = suite_test
end

-- 值的确定性字符串化（表按 key 排序，限制深度，容忍环）。
local function _format(value, seen, depth)
  seen = seen or {}
  depth = depth or 0
  if type(value) == "string" then
    return string.format("%q", value)
  end
  if type(value) ~= "table" then
    return tostring(value)
  end
  if seen[value] then
    return "<cycle>"
  end
  if depth >= 4 then
    return "{...}"
  end
  seen[value] = true
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = "["
      .. _format(key, seen, depth + 1)
      .. "]="
      .. _format(value[key], seen, depth + 1)
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- 深比较（对应 busted 的 assert.same）。
local function _deep_equal(a, b, seen)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  seen = seen or {}
  if seen[a] == b then
    return true
  end
  seen[a] = b
  for key, value in pairs(a) do
    if not _deep_equal(value, b[key], seen) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

local function _fail(message, level)
  error(message, (level or 1) + 1)
end

local test_assert = { are = {}, are_not = {} }

function test_assert.are.equal(expected, actual, message)
  if expected ~= actual then
    _fail(
      (message and (message .. ": ") or "")
        .. "expected "
        .. _format(expected)
        .. ", got "
        .. _format(actual),
      2
    )
  end
  return actual
end

function test_assert.are_not.equal(unexpected, actual, message)
  if unexpected == actual then
    _fail(
      (message and (message .. ": ") or "")
        .. "expected value different from "
        .. _format(unexpected),
      2
    )
  end
  return actual
end

function test_assert.same(expected, actual, message)
  if not _deep_equal(expected, actual) then
    _fail(
      (message and (message .. ": ") or "")
        .. "expected (deep) "
        .. _format(expected)
        .. ", got "
        .. _format(actual),
      2
    )
  end
  return actual
end

function test_assert.is_true(actual, message)
  if actual ~= true then
    _fail((message and (message .. ": ") or "") .. "expected true, got " .. _format(actual), 2)
  end
  return actual
end

function test_assert.is_truthy(actual, message)
  if actual == nil or actual == false then
    _fail((message and (message .. ": ") or "") .. "expected truthy, got " .. _format(actual), 2)
  end
  return actual
end

function test_assert.is_nil(actual, message)
  if actual ~= nil then
    _fail((message and (message .. ": ") or "") .. "expected nil, got " .. _format(actual), 2)
  end
  return actual
end

-- 与 busted/luassert 相同的做法：用可调用 table 替换全局 assert，
-- 保留 assert(value, msg) 原语义，同时挂载 are/same/is_* 扩展。
_G.assert = setmetatable({}, {
  __call = function(_, ...)
    return real_assert(...)
  end,
  __index = test_assert,
})

function harness.run()
  local passed, failed = 0, 0
  local failures = {}
  for _, suite in ipairs(suites) do
    for _, test in ipairs(suite.tests) do
      local full_name = suite.name .. " " .. test.name
      local ok, err = xpcall(test.fn, debug.traceback)
      if ok then
        passed = passed + 1
        print("ok - " .. full_name)
      else
        failed = failed + 1
        print("not ok - " .. full_name)
        failures[#failures + 1] = { name = full_name, err = err }
      end
    end
  end
  for _, failure in ipairs(failures) do
    print("\nFAILED: " .. failure.name .. "\n" .. tostring(failure.err))
  end
  print(string.format("\n%d passed, %d failed", passed, failed))
  return failed == 0
end

_G.describe = harness.describe
_G.it = harness.it

return harness
