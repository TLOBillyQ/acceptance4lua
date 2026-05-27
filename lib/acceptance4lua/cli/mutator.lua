local mutator = require("acceptance4lua.mutator")

local M = {}

function M.usage()
  return table.concat({
    "usage: gherkin-mutator [options]",
    "  --feature <path>   default: features/a-feature.feature",
    "  --work-dir <path>  default: build/acceptance-mutation",
    "  --generated-dir <path>  default: <work-dir>/generated",
    "  --workers <count>",
    "  --timeout <duration>",
    "  --status-interval <duration>  default: 30s; 0 disables status lines",
    "  --level <level>    differential mutation level: full|hard|soft (default: hard)",
    "  --runner-worker <command>",
    "  --implementation-hash <hash>",
    "  --json",
    "  --verbose",
  }, "\n")
end

local _VALID_LEVELS = { full = true, hard = true, soft = true }

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

function M.parse_args(args)
  local options = {
    feature = "features/a-feature.feature",
    work_dir = "build/acceptance-mutation",
    workers = 1,
    status_interval_seconds = 30,
    status_interval_label = "30s",
    json = false,
    verbose = false,
  }

  local index = 1
  while index <= #(args or {}) do
    local value = args[index]
    if value == "--feature" then
      options.feature = args[index + 1]
      index = index + 2
    elseif value == "--work-dir" then
      options.work_dir = args[index + 1]
      index = index + 2
    elseif value == "--generated-dir" then
      options.generated_dir = args[index + 1]
      index = index + 2
    elseif value == "--workers" then
      options.workers = tonumber(args[index + 1])
      index = index + 2
    elseif value == "--timeout" then
      options.timeout_seconds = _parse_duration(args[index + 1])
      if options.timeout_seconds == nil then
        return nil, "invalid timeout: " .. tostring(args[index + 1])
      end
      index = index + 2
    elseif value == "--status-interval" then
      options.status_interval_seconds = _parse_duration(args[index + 1])
      if options.status_interval_seconds == nil then
        return nil, "invalid status interval: " .. tostring(args[index + 1])
      end
      options.status_interval_label = tostring(args[index + 1])
      index = index + 2
    elseif value == "--level" then
      local level = args[index + 1]
      if level == nil or not _VALID_LEVELS[level] then
        return nil, "invalid level: " .. tostring(level)
      end
      options.level = level
      index = index + 2
    elseif value == "--runner-worker" then
      options.runner_worker = args[index + 1]
      index = index + 2
    elseif value == "--implementation-hash" then
      options.implementation_hash = args[index + 1]
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

  if options.feature == nil or options.work_dir == nil then
    return nil, "missing option value"
  end
  if options.help then
    return options
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

if arg ~= nil and tostring(arg[0] or ""):match("mutator%.lua$") then
  os.exit(M.main(arg))
end

return M
