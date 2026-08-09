local gherkin_parser = require("acceptance4lua.gherkin_parser")

local M = {}

function M.usage()
  return "usage: gherkin-parser <feature-file> <json-output>"
end

function M.main(args)
  args = args or {}
  if #args ~= 2 then
    io.stderr:write(M.usage() .. "\n")
    return 2
  end

  local ok, err = gherkin_parser.write_json_file(args[1], args[2])
  if not ok then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
  return 0
end

-- 仅当本文件就是主脚本时才自动运行:宿主 wrapper 若也叫 parser.lua,
-- require 本模块时 arg[0] 指向宿主文件,抢跑会绕过 wrapper 的参数加工。
local _self_path = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):gsub("\\", "/")
if arg ~= nil and tostring(arg[0] or ""):gsub("\\", "/") == _self_path then
  os.exit(M.main(arg))
end

return M
