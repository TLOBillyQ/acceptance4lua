local common = require("acceptance4lua.runtime.common")
local spec_hash = require("acceptance4lua.spec_hash")

local feature_stamp = {}

local _STAMP_PREFIX = "# mutation-stamp: sha256="

function feature_stamp.read_stamp(feature_source)
  local source = tostring(feature_source or "")
  local hash = source:match("^%s*#%s*mutation%-stamp:%s*sha256=([0-9a-f]+)")
  if hash == nil then
    hash = source:match("\n%s*#%s*mutation%-stamp:%s*sha256=([0-9a-f]+)")
  end
  return hash
end

function feature_stamp.is_stamp_current(feature_source)
  local stored = feature_stamp.read_stamp(feature_source)
  if stored == nil then
    return false
  end
  local actual = spec_hash.compute_feature_content_hash(feature_source)
  return stored == actual
end

function feature_stamp.apply_stamp(feature_source)
  local stripped = spec_hash.strip_first_stamp_line(feature_source)
  local hash = spec_hash.sha256(stripped)
  local stamp_line = _STAMP_PREFIX .. hash
  local language_line = stripped:match("^(#%s*language:[^\n]*\n)")
  if language_line ~= nil then
    local remainder = stripped:sub(#language_line + 1)
    return language_line .. stamp_line .. "\n" .. remainder
  end
  if stripped == "" or stripped:sub(1, 1) == "\n" then
    return stamp_line .. stripped
  end
  return stamp_line .. "\n" .. stripped
end

function feature_stamp.apply_stamp_to_file(feature_path)
  local source, read_err = common.read_file(feature_path)
  if source == nil then
    return false, read_err
  end
  local updated = feature_stamp.apply_stamp(source)
  return common.write_file(feature_path, updated)
end

return feature_stamp
