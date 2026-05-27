local generator = require("acceptance4lua.generator")

local M = {}

function M.usage()
  return "usage: acceptance-entrypoint-generator <json-ir> <generated-test-output>"
end

function M.main(args)
  args = args or {}
  if #args ~= 2 then
    io.stderr:write(M.usage() .. "\n")
    return 2
  end

  local ok, err = generator.generate_file(args[1], args[2])
  if not ok then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
  return 0
end

if arg ~= nil and tostring(arg[0] or ""):match("generator%.lua$") then
  os.exit(M.main(arg))
end

return M
