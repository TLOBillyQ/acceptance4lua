local ir_dry = require("acceptance4lua.ir_dry")

local M = {}

function M.usage()
  return "usage: gherkin-ir-dry-checker [--include-exact] <json-ir> <report-output>"
end

function M.main(args)
  args = args or {}

  local opts = {}
  local positional = {}
  for _, value in ipairs(args) do
    if value == "--include-exact" then
      opts.include_exact = true
    elseif value:match("^%-%-") then
      io.stderr:write(M.usage() .. "\n")
      return 2
    else
      positional[#positional + 1] = value
    end
  end

  if #positional ~= 2 then
    io.stderr:write(M.usage() .. "\n")
    return 2
  end

  local ok, err = ir_dry.write_report_file(positional[1], positional[2], opts)
  if not ok then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end
  return 0
end

if arg ~= nil and tostring(arg[0] or ""):match("ir_dry%.lua$") then
  os.exit(M.main(arg))
end

return M
