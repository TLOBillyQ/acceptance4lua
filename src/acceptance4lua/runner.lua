local common = require("acceptance4lua.runtime.common")

local runner = {}

-- launcher（lua 解释器）找不到 / 命令缺失等"基础设施"错误的统一判定。
-- 与 mutator 并行批的 lane 结果共用，避免两处分别维护启发式。
function runner.is_infrastructure_error(exit_code, output)
  if exit_code == 127 then
    return true
  end
  return tostring(output or ""):find("not found", 1, true) ~= nil
end

-- 生成的入口是独立 lua 脚本（自带 harness，结尾 os.exit）。
-- 通过 LUA_PATH 指到宿主的 src/ 布局，替代旧 busted --helper 机制；
-- 宿主可用 ACCEPTANCE_LUA_BIN / ACCEPTANCE_LUA_PATH 或 opts 覆盖。
local function _lua_bin(opts)
  return (opts and opts.lua_bin) or os.getenv("ACCEPTANCE_LUA_BIN") or "lua"
end

local function _lua_path(opts)
  return (opts and opts.lua_path)
    or os.getenv("ACCEPTANCE_LUA_PATH")
    or "src/?.lua;src/?/init.lua;;"
end

function runner.build_command(path, opts)
  local command = "LUA_PATH="
    .. common.shell_quote(_lua_path(opts))
    .. " "
    .. common.shell_quote(_lua_bin(opts))
    .. " "
    .. common.shell_quote(path)
  if opts ~= nil and opts.feature_json ~= nil and opts.feature_json ~= "" then
    command = "ACCEPTANCE_FEATURE_JSON="
      .. common.shell_quote(opts.feature_json)
      .. " "
      .. command
  end
  return command
end

function runner.run_generated(path, opts)
  local start_time = common.wall_time()
  local command = runner.build_command(path, opts)
  local result = common.run_command(command, opts and opts.cwd and { cwd = opts.cwd } or nil)

  local output = result.output or ""
  local infrastructure_error = ""
  if runner.is_infrastructure_error(result.code, output) then
    -- output 可能为空（launcher 静默退出 127 等）：此时也必须给出非空错误，
    -- 下游 mutator 以 error ~= "" 判定基础设施错误，空串会被误当成普通失败。
    if output ~= "" then
      infrastructure_error = output
    else
      infrastructure_error = "lua launcher failed with exit code " .. tostring(result.code)
    end
  end

  return {
    passed = result.ok == true,
    output = output,
    error = infrastructure_error,
    duration = os.difftime(common.wall_time(), start_time),
  }
end

return runner
