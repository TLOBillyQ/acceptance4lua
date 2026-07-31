-- 测试入口：在仓库根目录执行 `lua spec/run.lua`。
-- 4lua 工具链统一决策（ADR-0005）：本仓库测试套件迁移至 luaunit，
-- 遵循 test_*.lua + luaunit 约定（与 mutate4lua 已落地形态一致）。
-- 产品 harness（lib/acceptance4lua/harness.lua）是验收入口生成器的一部分，
-- 不属于本仓库的测试设施，不再用于自测。

package.path = "lib/?.lua;lib/?/init.lua;" .. package.path

local lu = require("luaunit")

local handle = assert(io.popen("ls -1 spec"))
local files = {}
for name in handle:lines() do
  if name:match("^test_.*%.lua$") then
    files[#files + 1] = "spec/" .. name
  end
end
handle:close()
table.sort(files)

if #files == 0 then
  io.stderr:write("no test files found (spec/test_*.lua)\n")
  os.exit(1)
end

local instances = {}
for _, path in ipairs(files) do
  local chunk, load_err = loadfile(path)
  if chunk == nil then
    io.stderr:write("cannot load test file " .. path .. ": " .. tostring(load_err) .. "\n")
    os.exit(1)
  end
  local ok, suite_or_err = pcall(chunk)
  if not ok then
    io.stderr:write("error loading test file " .. path .. ": " .. tostring(suite_or_err) .. "\n")
    os.exit(1)
  end
  if type(suite_or_err) ~= "table" then
    io.stderr:write("test file " .. path .. " must return a luaunit test table\n")
    os.exit(1)
  end
  local base = path:match("([^/]+)%.lua$") or path
  instances[#instances + 1] = { (base:gsub("[^%w_]", "_")), suite_or_err }
end

local runner = lu.LuaUnit.new()
os.exit(runner:runSuiteByInstancesNoCmdLineParsing(instances) > 0 and 1 or 0)
