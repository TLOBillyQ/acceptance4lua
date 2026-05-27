local common = require("acceptance4lua.runtime.common")
local json = require("acceptance4lua.json")
local spec_hash = require("acceptance4lua.spec_hash")

local scenario_manifest = {}

local _BEGIN_MARKER = "# acceptance-mutation-manifest-begin"
local _END_MARKER = "# acceptance-mutation-manifest-end"
local _BEGIN_PATTERN = "# acceptance%-mutation%-manifest%-begin"
local _END_PATTERN = "# acceptance%-mutation%-manifest%-end"
local _VERSION = 1

scenario_manifest.VERSION = _VERSION
scenario_manifest.BEGIN_MARKER = _BEGIN_MARKER
scenario_manifest.END_MARKER = _END_MARKER

function scenario_manifest.utc_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function _strip_existing_block(source)
  local pattern = _BEGIN_PATTERN .. ".-" .. _END_PATTERN .. "\n?"
  local stripped, count = source:gsub(pattern, "", 1)
  if count == 0 then
    return source
  end
  return stripped
end

function scenario_manifest.read(feature_source)
  local source = tostring(feature_source or "")
  local block = source:match(_BEGIN_PATTERN .. "\n(.-)" .. _END_PATTERN)
  if block == nil then
    return nil
  end
  local json_lines = {}
  for line in block:gmatch("[^\n]*") do
    local payload = line:match("^%s*#%s?(.*)$")
    if payload ~= nil then
      json_lines[#json_lines + 1] = payload
    end
  end
  local json_text = table.concat(json_lines, "\n")
  local ok, parsed = pcall(json.decode, json_text)
  if not ok or type(parsed) ~= "table" then
    return nil
  end
  return parsed
end

function scenario_manifest.serialize(manifest_data)
  local json_text = json.encode(manifest_data)
  local lines = { _BEGIN_MARKER }
  for line in json_text:gmatch("[^\n]+") do
    lines[#lines + 1] = "# " .. line
  end
  lines[#lines + 1] = _END_MARKER
  return table.concat(lines, "\n")
end

function scenario_manifest.apply(feature_source, manifest_data)
  local source = tostring(feature_source or "")
  local without_block = _strip_existing_block(source)
  local block = scenario_manifest.serialize(manifest_data)

  local preamble = ""
  local language_line = without_block:match("^(#%s*language:[^\n]*\n)")
  if language_line ~= nil then
    preamble = preamble .. language_line
    without_block = without_block:sub(#language_line + 1)
  end
  local stamp_line = without_block:match("^(#%s*mutation%-stamp:[^\n]*\n)")
  if stamp_line ~= nil then
    preamble = preamble .. stamp_line
    without_block = without_block:sub(#stamp_line + 1)
  end

  if preamble ~= "" then
    return preamble .. block .. "\n" .. without_block
  end
  if without_block == "" or without_block:sub(1, 1) == "\n" then
    return block .. without_block
  end
  return block .. "\n" .. without_block
end

function scenario_manifest.apply_to_file(feature_path, manifest_data)
  local source, read_err = common.read_file(feature_path)
  if source == nil then
    return false, read_err
  end
  return common.write_file(feature_path, scenario_manifest.apply(source, manifest_data))
end

function scenario_manifest.find_entry_for_index(manifest, scenario_index)
  if manifest == nil then
    return nil
  end
  for _, entry in ipairs(manifest.scenarios or {}) do
    if entry.index == scenario_index then
      return entry
    end
  end
  return nil
end

function scenario_manifest.decide_scenario_skip(
  manifest, scenario, scenario_index, current_state, level
)
  if manifest == nil then
    return false
  end
  if level == "full" then
    return false
  end
  if tonumber(manifest.version) ~= _VERSION then
    return false
  end
  if manifest.feature_name ~= current_state.feature_name then
    return false
  end
  if manifest.feature_path ~= current_state.feature_path then
    return false
  end
  if manifest.background_hash ~= current_state.background_hash then
    return false
  end
  if level == "hard" and manifest.implementation_hash ~= current_state.implementation_hash then
    return false
  end

  local entry = scenario_manifest.find_entry_for_index(manifest, scenario_index)
  if entry == nil then
    return false
  end
  if entry.name ~= scenario.name then
    return false
  end
  if entry.scenario_hash ~= spec_hash.compute_scenario_hash(scenario) then
    return false
  end
  local result = entry.result or {}
  if (tonumber(result.Survived) or 0) ~= 0 then
    return false
  end
  if (tonumber(result.Errors) or 0) ~= 0 then
    return false
  end
  return true
end

function scenario_manifest.build_entry(scenario, scenario_index, mutation_count, scenario_results, tested_at)
  local killed, survived, errors = 0, 0, 0
  for _, result in ipairs(scenario_results or {}) do
    if result.status == "killed" then
      killed = killed + 1
    elseif result.status == "survived" then
      survived = survived + 1
    elseif result.status == "error" then
      errors = errors + 1
    end
  end
  local total = killed + survived + errors
  return {
    index = scenario_index,
    name = scenario.name,
    scenario_hash = spec_hash.compute_scenario_hash(scenario),
    mutation_count = mutation_count,
    result = { Total = total, Killed = killed, Survived = survived, Errors = errors },
    tested_at = tested_at or scenario_manifest.utc_now(),
  }
end

return scenario_manifest
