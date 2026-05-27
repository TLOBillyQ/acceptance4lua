local common = require("acceptance4lua.runtime.common")

local M = {}

local _DEFAULT_TIMEOUT_SECONDS = 600
local _POLL_INTERVAL_SECONDS = 0.3

local function _lane_paths(label)
  local prefix = "vf_" .. label
  return {
    output = common.make_temp_path(prefix .. "_out", ".txt"),
    status = common.make_temp_path(prefix .. "_status", ".txt"),
    launcher = common.make_temp_path(prefix .. "_launcher", ".sh"),
  }
end

local function _write_lane_launcher(cmd, paths)
  local cwd = common.current_dir()
  local script = table.concat({
    "#!/bin/sh",
    "cd " .. common.shell_quote(cwd)
      .. " || { printf '%s\\n' '1' > " .. common.shell_quote(paths.status) .. "; exit 0; }",
    cmd .. " > " .. common.shell_quote(paths.output) .. " 2>&1",
    "code=$?",
    "printf '%s\\n' \"$code\" > " .. common.shell_quote(paths.status),
    "exit 0",
  }, "\n")
  return common.write_file(paths.launcher, script)
end

local function _launch(paths)
  local cmd = "sh " .. common.shell_quote(paths.launcher) .. " >/dev/null 2>&1 &"
  local ok, _, code = os.execute(cmd)
  if ok == true and (code == nil or code == 0) then
    return true
  end
  if tonumber(code) == 0 then
    return true
  end
  return nil, "failed to launch lane"
end

local function _sleep(seconds)
  os.execute("sleep " .. tostring(seconds) .. " >/dev/null 2>&1")
end

local function _read_status(path)
  local content = common.read_file(path)
  if content == nil then
    return nil
  end
  local normalized = tostring(content):gsub("%s+", "")
  return math.floor(tonumber(normalized) or 0)
end

local function _cleanup_lane(paths)
  common.remove_path(paths.output)
  common.remove_path(paths.status)
  common.remove_path(paths.launcher)
end

function M.run(lanes, opts)
  opts = opts or {}
  local timeout = opts.timeout or _DEFAULT_TIMEOUT_SECONDS
  local stream = opts.stream
  if stream == nil then stream = true end

  local active = {}
  for _, lane in ipairs(lanes) do
    local paths = _lane_paths(lane.label)
    local ok, err = _write_lane_launcher(lane.cmd, paths)
    if not ok then
      for _, a in ipairs(active) do _cleanup_lane(a.paths) end
      error("failed to write launcher for " .. lane.label .. ": " .. tostring(err))
    end
    local launched, launch_err = _launch(paths)
    if not launched then
      _cleanup_lane(paths)
      for _, a in ipairs(active) do _cleanup_lane(a.paths) end
      error("failed to launch " .. lane.label .. ": " .. tostring(launch_err))
    end
    active[#active + 1] = { label = lane.label, paths = paths }
  end

  local deadline = os.time() + timeout
  while true do
    local pending = false
    for _, a in ipairs(active) do
      if common.path_exists(a.paths.status) ~= true then
        pending = true
        break
      end
    end
    if not pending then break end
    if os.time() > deadline then
      for _, a in ipairs(active) do _cleanup_lane(a.paths) end
      error("parallel lanes timed out after " .. tostring(timeout) .. "s")
    end
    _sleep(_POLL_INTERVAL_SECONDS)
  end

  local all_ok = true
  local results = {}
  for _, a in ipairs(active) do
    local status_code = _read_status(a.paths.status)
    local output = common.read_file(a.paths.output) or ""
    local success = status_code == 0
    if stream and output ~= "" then
      io.write(output)
      if output:sub(-1) ~= "\n" then io.write("\n") end
    end
    results[#results + 1] = {
      label = a.label,
      ok = success,
      output = output,
      exit_code = status_code,
    }
    if not success then all_ok = false end
    _cleanup_lane(a.paths)
  end
  if stream then io.flush() end

  return all_ok, results
end

return M
