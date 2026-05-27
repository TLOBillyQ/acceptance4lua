local common = {}

local _temp_counter = 0

local function _is_windows()
  return package.config:sub(1, 1) == "\\"
end

local function _os_success(ok, _, code)
  if type(ok) == "number" then
    return ok == 0, ok
  end
  if ok == true and (code == nil or code == 0) then
    return true, code or 0
  end
  return false, code or 1
end

function common.normalize_path(path)
  return tostring(path or ""):gsub("\\", "/")
end

function common.join_path(base, child)
  local normalized_base = common.normalize_path(base):gsub("/+$", "")
  local normalized_child = common.normalize_path(child):gsub("^/+", "")
  if normalized_base == "" then
    return normalized_child
  end
  if normalized_child == "" then
    return normalized_base
  end
  return normalized_base .. "/" .. normalized_child
end

function common.parent_dir(path)
  local normalized = common.normalize_path(path):gsub("/+$", "")
  local parent = normalized:match("^(.*)/[^/]+$")
  if parent == nil or parent == "" then
    return "."
  end
  return parent
end

function common.is_absolute_path(path)
  local normalized = common.normalize_path(path)
  return normalized:sub(1, 1) == "/" or normalized:match("^%a:[/]") ~= nil
end

function common.current_dir()
  local env_cwd = os.getenv("PWD")
  if env_cwd ~= nil and env_cwd ~= "" then
    return common.normalize_path(env_cwd)
  end
  local process = io.popen(_is_windows() and "cd" or "pwd")
  if process == nil then
    return "."
  end
  local output = process:read("*a") or ""
  process:close()
  output = output:gsub("%s+$", "")
  if output == "" then
    return "."
  end
  return common.normalize_path(output)
end

function common.read_file(path)
  local file, err = io.open(path, "rb")
  if file == nil then
    return nil, err
  end
  local content = file:read("*a")
  file:close()
  return content
end

function common.write_file(path, content)
  local parent = common.parent_dir(path)
  local ok, err = common.ensure_dir(parent)
  if not ok then
    return nil, err
  end
  local file, open_err = io.open(path, "wb")
  if file == nil then
    return nil, open_err
  end
  file:write(tostring(content or ""))
  file:close()
  return true
end

function common.path_exists(path)
  local file = io.open(path, "rb")
  if file ~= nil then
    file:close()
    return true
  end
  local command
  if _is_windows() then
    command = 'if exist "' .. tostring(path):gsub('"', '\\"') .. '" (exit 0) else (exit 1)'
  else
    command = "[ -e " .. common.shell_quote(path) .. " ]"
  end
  local ok, kind, code = os.execute(command)
  local success = _os_success(ok, kind, code)
  return success
end

function common.ensure_dir(path)
  local normalized = common.normalize_path(path)
  if normalized == "" or normalized == "." then
    return true
  end
  local command = (_is_windows() and "mkdir " or "mkdir -p ") .. common.shell_quote(normalized)
  local ok, kind, code = os.execute(command)
  local success, exit_code = _os_success(ok, kind, code)
  if success then
    return true
  end
  return nil, "failed to create directory " .. normalized .. ": " .. tostring(exit_code)
end

function common.remove_path(path)
  if path == nil or path == "" then
    return true
  end
  local command = (_is_windows() and "rmdir /s /q " or "rm -rf ") .. common.shell_quote(path)
  local ok, kind, code = os.execute(command)
  local success, exit_code = _os_success(ok, kind, code)
  if success then
    return true
  end
  return nil, "failed to remove path " .. tostring(path) .. ": " .. tostring(exit_code)
end

function common.make_temp_path(prefix, suffix)
  _temp_counter = _temp_counter + 1
  local token = tostring(os.time()) .. "_" .. tostring(_temp_counter) .. "_" .. tostring({}):gsub("[^%w]", "")
  local tmp_root = os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp"
  return common.join_path(tmp_root, tostring(prefix or "tmp") .. "_" .. token .. tostring(suffix or ""))
end

function common.shell_quote(value)
  local text = tostring(value or "")
  if _is_windows() then
    return '"' .. text:gsub('"', '\\"') .. '"'
  end
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function _command_text(command)
  if type(command) == "table" then
    local parts = {}
    for _, value in ipairs(command) do
      parts[#parts + 1] = common.shell_quote(value)
    end
    return table.concat(parts, " ")
  end
  return tostring(command or "")
end

function common.run_command(command, opts)
  opts = opts or {}
  local output_path = common.make_temp_path("acceptance4lua_cmd", ".txt")
  local cmd = _command_text(command)
  if opts.stdin_path ~= nil then
    cmd = cmd .. " < " .. common.shell_quote(opts.stdin_path)
  end
  cmd = cmd .. " > " .. common.shell_quote(output_path) .. " 2>&1"
  if opts.cwd ~= nil and opts.cwd ~= "" then
    cmd = "cd " .. common.shell_quote(opts.cwd) .. " && " .. cmd
  end

  local ok, kind, code = os.execute(cmd)
  local success, exit_code = _os_success(ok, kind, code)
  local output = common.read_file(output_path) or ""
  common.remove_path(output_path)
  return {
    ok = success,
    code = exit_code,
    exit_code = exit_code,
    output = output,
  }
end

return common
