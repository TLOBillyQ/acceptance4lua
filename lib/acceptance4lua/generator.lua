local common = require("acceptance4lua.runtime.common")
local json = require("acceptance4lua.json")
local source = require("acceptance4lua.source")
local spec_hash = require("acceptance4lua.spec_hash")
local table_shape = require("acceptance4lua.table_shape")

local generator = {}

local function _wrap_table_body(body_lines, indent)
  if #body_lines == 0 then
    return "{}"
  end
  return "{\n" .. table.concat(body_lines, "\n") .. "\n" .. string.rep(" ", indent) .. "}"
end

local function _lua_literal(value, indent, key_hint)
  local value_type = type(value)
  if value == nil then
    return "nil"
  end
  if value_type == "string" then
    return string.format("%q", value)
  end
  if value_type == "boolean" or value_type == "number" then
    return tostring(value)
  end
  if value_type ~= "table" then
    return string.format("%q", tostring(value))
  end

  local next_indent = indent + 2
  local child_pad = string.rep(" ", next_indent)

  if table_shape.is_array(value, key_hint) then
    local parts = {}
    for _, item in ipairs(value) do
      parts[#parts + 1] = child_pad .. _lua_literal(item, next_indent) .. ","
    end
    return _wrap_table_body(parts, indent)
  end

  local fields = {}
  for _, key in ipairs(table_shape.sorted_keys(value)) do
    fields[#fields + 1] = child_pad
      .. "["
      .. string.format("%q", key)
      .. "] = "
      .. _lua_literal(value[key], next_indent, key)
      .. ","
  end
  return _wrap_table_body(fields, indent)
end

function generator.generate(ir, opts)
  opts = opts or {}
  local runtime_module = opts.runtime_module or "acceptance4lua.runtime"
  local steps_module = opts.steps_module or "acceptance.steps"
  local json_module = opts.json_module or "acceptance4lua.json"
  return table.concat({
    "-- luacheck: globals describe it",
    'local runtime = require("' .. runtime_module .. '")',
    'local steps = require("' .. steps_module .. '")',
    'local json = require("' .. json_module .. '")',
    "",
    "local embedded_ir = " .. _lua_literal(ir, 0),
    "",
    "local function load_ir()",
    "  local override_path = os.getenv(\"ACCEPTANCE_FEATURE_JSON\")",
    "  if override_path ~= nil and override_path ~= \"\" then",
    "    local file = assert(io.open(override_path, \"rb\"))",
    "    local content = file:read(\"*a\")",
    "    file:close()",
    "    return json.decode(content)",
    "  end",
    "  return embedded_ir",
    "end",
    "",
    "local ir = load_ir()",
    "",
    "describe(\"Acceptance: \" .. tostring(ir.name), function()",
    "  runtime.define_busted_specs(ir, steps.handlers(), it)",
    "end)",
    "",
  }, "\n")
end

local function _metadata_name(feature_path)
  local slug = tostring(feature_path or "feature"):lower()
  slug = slug:gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if slug == "" then
    slug = "feature"
  end
  return slug .. ".json"
end

function generator.metadata_path_for(output_path, feature_path)
  return common.join_path(common.parent_dir(output_path), "metadata/" .. _metadata_name(feature_path))
end

local function _write_metadata(ir, output_path, opts)
  local feature_path = source.path_from_ir(ir) or "feature"
  local generated_files = { output_path }
  local metadata = {
    schema_version = 1,
    feature_path = feature_path,
    ir_path = opts and opts.ir_path or "",
    implementation_hash = spec_hash.compute_generated_files_hash(generated_files),
    hash_scope = "generated_files",
    generated_files = generated_files,
  }
  return common.write_file(generator.metadata_path_for(output_path, feature_path), json.encode(metadata))
end

function generator.write_generated(ir, output_path, opts)
  local parent = common.parent_dir(output_path)
  local ok, err = common.ensure_dir(parent)
  if not ok then
    return nil, err
  end
  local generated = generator.generate(ir, opts)
  ok, err = common.write_file(output_path, generated)
  if not ok then
    return nil, err
  end
  return _write_metadata(ir, output_path, opts)
end

function generator.generate_file(json_path, output_path)
  local content, err = common.read_file(json_path)
  if content == nil then
    return nil, err
  end

  local ok, ir_or_err = pcall(json.decode, content)
  if not ok then
    return nil, ir_or_err
  end
  return generator.write_generated(ir_or_err, output_path, { ir_path = json_path })
end

return generator
