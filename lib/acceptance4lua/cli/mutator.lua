local mutator = require("acceptance4lua.mutator")

local M = {}

function M.usage()
  return table.concat({
    "usage: gherkin-mutator [options]",
    "  --feature <path>   (required)",
    "  --work-dir <path>  default: build/acceptance-mutation",
    "  --generated-dir <path>  default: <work-dir>/generated",
    "  --steps-module <name>  step module required by generated entrypoints (default: steps)",
    "  --workers <count>",
    "  --timeout <duration>",
    "  --status-interval <duration>  default: 30s; 0 disables status lines",
    "  --level <level>    differential mutation level: full|hard|soft (default: hard)",
    "  --skip-columns <names>  comma-separated example columns excluded from mutation",
    "  --runner-worker <command>",
    "  --implementation-hash <hash>",
    "  --json",
    "  --verbose",
  }, "\n")
end

local _VALID_LEVELS = { full = true, hard = true, soft = true }

-- 把逗号分隔的列名列表解析为集合（列名精确匹配，含 CJK 列名；空格裁剪）。
local function _parse_column_set(value)
  if value == nil then
    return nil
  end
  local columns = {}
  for item in tostring(value):gmatch("([^,]+)") do
    local name = item:match("^%s*(.-)%s*$")
    if name ~= "" then
      columns[name] = true
    end
  end
  return columns
end

local function _parse_duration(value)
  if value == nil then
    return nil
  end
  local amount, unit = tostring(value):match("^(%d+)([smh]?)$")
  if amount == nil then
    return nil
  end
  local seconds = tonumber(amount)
  if unit == "m" then
    seconds = seconds * 60
  elseif unit == "h" then
    seconds = seconds * 3600
  end
  return seconds
end

-- 纯字符串选项:选项名 → options 字段名。
local _STRING_OPTIONS = {
  ["--feature"] = "feature",
  ["--work-dir"] = "work_dir",
  ["--generated-dir"] = "generated_dir",
  ["--steps-module"] = "steps_module",
  ["--runner-worker"] = "runner_worker",
  ["--implementation-hash"] = "implementation_hash",
}

-- 取紧跟选项名之后的值;缺失时返回 nil + 错误。
local function _require_value(args, index, name)
  local value = args[index + 1]
  if value == nil then
    return nil, "missing value for " .. name
  end
  return value
end

function M.parse_args(args)
  args = args or {}
  local options = {
    work_dir = "build/acceptance-mutation",
    workers = 1,
    status_interval_seconds = 30,
    json = false,
    verbose = false,
  }

  local index = 1
  while index <= #args do
    local value = args[index]
    local string_key = _STRING_OPTIONS[value]
    if string_key ~= nil then
      local option_value, value_err = _require_value(args, index, value)
      if option_value == nil then
        return nil, value_err
      end
      options[string_key] = option_value
      index = index + 2
    elseif value == "--workers" then
      local raw, value_err = _require_value(args, index, value)
      if raw == nil then
        return nil, value_err
      end
      local workers = tonumber(raw)
      if workers == nil then
        return nil, "invalid workers: " .. tostring(raw)
      end
      options.workers = workers
      index = index + 2
    elseif value == "--timeout" then
      local raw, value_err = _require_value(args, index, value)
      if raw == nil then
        return nil, value_err
      end
      options.timeout_seconds = _parse_duration(raw)
      if options.timeout_seconds == nil then
        return nil, "invalid timeout: " .. tostring(raw)
      end
      index = index + 2
    elseif value == "--status-interval" then
      local raw, value_err = _require_value(args, index, value)
      if raw == nil then
        return nil, value_err
      end
      options.status_interval_seconds = _parse_duration(raw)
      if options.status_interval_seconds == nil then
        return nil, "invalid status interval: " .. tostring(raw)
      end
      index = index + 2
    elseif value == "--level" then
      local level, value_err = _require_value(args, index, value)
      if level == nil then
        return nil, value_err
      end
      if not _VALID_LEVELS[level] then
        return nil, "invalid level: " .. tostring(level)
      end
      options.level = level
      index = index + 2
    elseif value == "--skip-columns" then
      local raw, value_err = _require_value(args, index, value)
      if raw == nil then
        return nil, value_err
      end
      options.skip_columns = _parse_column_set(raw)
      index = index + 2
    elseif value == "--json" then
      options.json = true
      index = index + 1
    elseif value == "--verbose" then
      options.verbose = true
      index = index + 1
    elseif value == "--help" or value == "-h" then
      options.help = true
      index = index + 1
    else
      return nil, "unknown option: " .. tostring(value)
    end
  end

  if options.help then
    return options
  end
  if options.feature == nil then
    return nil, "--feature is required"
  end
  if options.generated_dir == nil then
    options.generated_dir = options.work_dir .. "/generated"
  end
  if options.runner_worker == nil then
    return nil, "--runner-worker is required"
  end
  return options
end

function M.main(args)
  local options, err = M.parse_args(args or {})
  if options == nil then
    io.stderr:write(M.usage() .. "\n" .. tostring(err) .. "\n")
    return 2
  end
  if options.help then
    io.write(M.usage() .. "\n")
    return 0
  end

  if options.status_interval_seconds > 0 then
    options.status_callback = function(line)
      io.stderr:write(tostring(line), "\n")
      io.stderr:flush()
    end
  end

  local report
  report, err = mutator.run(options)
  if report == nil then
    io.stderr:write(tostring(err) .. "\n")
    return 1
  end

  if options.json then
    io.write(mutator.format_json_report(report))
  else
    io.write(mutator.format_text_report(report, { verbose = options.verbose }))
  end

  if report.summary.survived > 0 or report.summary.errors > 0 then
    return 1
  end
  return 0
end

-- 仅当本文件就是主脚本时才自动运行:宿主 wrapper 若也叫 mutator.lua,
-- require 本模块时 arg[0] 指向宿主文件,抢跑会绕过 wrapper 的参数加工。
local _self_path = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):gsub("\\", "/")
if arg ~= nil and tostring(arg[0] or ""):gsub("\\", "/") == _self_path then
  os.exit(M.main(arg))
end

return M
