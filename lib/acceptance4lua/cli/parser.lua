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

if arg ~= nil and tostring(arg[0] or ""):match("parser%.lua$") then
  os.exit(M.main(arg))
end

return M
