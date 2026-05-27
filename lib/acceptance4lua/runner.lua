local common = require("acceptance4lua.runtime.common")

local runner = {}

-- busted launcher 找不到 / 命令缺失等"基础设施"错误的统一判定。
-- 与 mutator 并行批的 lane 结果共用，避免两处分别维护启发式。
function runner.is_infrastructure_error(exit_code, output)
  if exit_code == 127 then
    return true
  end
  return tostring(output or ""):find("not found", 1, true) ~= nil
end

local function _busted_command(path)
  local busted_bin = os.getenv("BUSTED_BIN") or "busted"
  return common.shell_quote(busted_bin)
    .. " --helper=spec/helper.lua --output=TAP "
    .. common.shell_quote(path)
end

function runner.run_generated(path, opts)
  local start_time = os.clock()
  local command
  if opts ~= nil and opts.feature_json ~= nil and opts.feature_json ~= "" then
    command = "ACCEPTANCE_FEATURE_JSON="
      .. common.shell_quote(opts.feature_json)
      .. " "
      .. _busted_command(path)
  else
    command = {
      os.getenv("BUSTED_BIN") or "busted",
      "--helper=spec/helper.lua",
      "--output=TAP",
      path,
    }
  end
  local result = common.run_command(command, opts and opts.cwd and { cwd = opts.cwd } or nil)

  local output = result.output or ""
  local infrastructure_error = ""
  if runner.is_infrastructure_error(result.code, output) then
    infrastructure_error = output
  end

  return {
    passed = result.ok == true,
    output = output,
    error = infrastructure_error,
    duration = os.clock() - start_time,
  }
end

return runner
