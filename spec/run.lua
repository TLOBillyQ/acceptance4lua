-- 测试入口（无外部依赖）：在仓库根目录执行 `lua spec/run.lua`。

package.path = "lib/?.lua;lib/?/init.lua;" .. package.path

local harness = require("acceptance4lua.harness")

local handle = assert(io.popen("ls -1 spec"))
for name in handle:lines() do
  if name:match("_spec%.lua$") then
    dofile("spec/" .. name)
  end
end
handle:close()

os.exit(harness.run() and 0 or 1)
