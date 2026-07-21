local generator = require("acceptance4lua.generator")

local M = {}

function M.usage()
  return table.concat({
    "usage: acceptance-entrypoint-generator [--steps-module <name>] <json-ir> <generated-test-output>",
    "  --steps-module <name>  host step module required by the generated entrypoint",
    "                         (default: steps)",
  }, "\n")
end

function M.main(args)
  args = args or {}
  local opts = {}
  local positional = {}
  local index = 1
  while index <= #args do
    if args[index] == "--steps-module" then
      local value = args[index + 1]
      if value == nil then
        io.stderr:write(M.usage() .. "\nmissing value for --steps-module\n")
        return 2
      end
      opts.steps_module = value
      index = index + 2
    else
      positional[#positional + 1] = args[index]
      index = index + 1
    end
  end

  if #positional ~= 2 then
    io.stderr:write(M.usage() .. "\n")
    return 2
  end

  local ok, err = generator.generate_file(positional[1], positional[2], opts)
  if not ok then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
  return 0
end

-- 仅当本文件就是主脚本时才自动运行:宿主 wrapper 若也叫 generator.lua,
-- require 本模块时 arg[0] 指向宿主文件,抢跑会绕过 wrapper 的参数加工。
local _self_path = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):gsub("\\", "/")
if arg ~= nil and tostring(arg[0] or ""):gsub("\\", "/") == _self_path then
  os.exit(M.main(arg))
end

return M
