local common = require("acceptance4lua.runtime.common")

local M = {}

local _DEFAULT_TIMEOUT_SECONDS = 600
local _POLL_INTERVAL_SECONDS = 0.3

local function _lane_paths(label)
  local prefix = "vf_" .. label
  return {
    output = common.make_temp_path(prefix .. "_out", ".txt"),
    status = common.make_temp_path(prefix .. "_status", ".txt"),
    status_tmp = common.make_temp_path(prefix .. "_status_tmp", ".txt"),
    launcher = common.make_temp_path(prefix .. "_launcher", ".sh"),
  }
end

local function _write_lane_launcher(cmd, paths)
  local cwd = common.current_dir()
  -- 状态先写临时名再 mv 原子发布：直接 > 重定向会先创建空文件，
  -- 轮询端可能读到空内容，把尚未跑完的 lane 误判成 exit 0。
  -- cmd 包一层子 shell：cmd 里的 exit 只会结束子 shell，状态仍会被发布，
  -- 否则 launcher 提前退出、状态文件永远不出现，调用方只能干等到超时。
  local status_tmp = common.shell_quote(paths.status_tmp)
  local status = common.shell_quote(paths.status)
  local script = table.concat({
    "#!/bin/sh",
    "cd " .. common.shell_quote(cwd)
      .. " || { printf '%s\\n' '1' > " .. status_tmp .. " && mv " .. status_tmp .. " " .. status .. "; exit 0; }",
    "( " .. cmd .. " ) > " .. common.shell_quote(paths.output) .. " 2>&1",
    "code=$?",
    "printf '%s\\n' \"$code\" > " .. status_tmp .. " && mv " .. status_tmp .. " " .. status,
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
  -- Lua 5.1 的 os.execute 只返回数字状态码，成功为 0。
  if type(ok) == "number" and ok == 0 then
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
  -- 空内容/非数字一律视为未发布：状态文件由 launcher 原子 mv 发布，读到即完整。
  local code = tonumber((tostring(content):gsub("%s+", "")))
  if code == nil then
    return nil
  end
  return math.floor(code)
end

local function _cleanup_lane(paths)
  common.remove_path(paths.output)
  common.remove_path(paths.status)
  common.remove_path(paths.status_tmp)
  common.remove_path(paths.launcher)
end

local function _cleanup_all(active)
  for _, a in ipairs(active) do
    _cleanup_lane(a.paths)
  end
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
      _cleanup_all(active)
      error("failed to write launcher for " .. tostring(lane.label) .. ": " .. tostring(err))
    end
    local launched, launch_err = _launch(paths)
    if not launched then
      _cleanup_lane(paths)
      _cleanup_all(active)
      error("failed to launch " .. tostring(lane.label) .. ": " .. tostring(launch_err))
    end
    active[#active + 1] = { label = lane.label, paths = paths }
  end

  local deadline = os.time() + timeout
  while true do
    local pending = false
    for _, a in ipairs(active) do
      if _read_status(a.paths.status) == nil then
        pending = true
        break
      end
    end
    if not pending then break end
    if os.time() > deadline then
      _cleanup_all(active)
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
