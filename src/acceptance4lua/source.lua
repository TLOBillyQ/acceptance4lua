local source = {}

local function _has_text(value)
  return value ~= nil and value ~= ""
end

function source.trim(text)
  return tostring(text or ""):match("^%s*(.-)%s*$")
end

function source.split_table_cells(line)
  local row = source.trim(line)
  if row:sub(1, 1) == "|" then
    row = row:sub(2)
  end
  if row:sub(-1) == "|" then
    row = row:sub(1, -2)
  end

  local cells = {}
  local start_index = 1
  while true do
    local hit = row:find("|", start_index, true)
    if hit == nil then
      cells[#cells + 1] = source.trim(row:sub(start_index))
      break
    end
    cells[#cells + 1] = source.trim(row:sub(start_index, hit - 1))
    start_index = hit + 1
  end
  return cells
end

function source.extract_parameters(text)
  local values = {}
  for name in tostring(text or ""):gmatch("<([^<>]+)>") do
    values[#values + 1] = name
  end
  return values
end

function source.format_error(path, line_number, message)
  local prefix = ""
  if _has_text(path) then
    prefix = tostring(path) .. ":"
  end
  if line_number ~= nil then
    prefix = prefix .. "第" .. tostring(line_number) .. "行: "
  end
  return prefix .. tostring(message)
end

function source.line_from_map(source_map, normalized_line_number)
  local lines = (source_map or {}).line_by_normalized_line or {}
  return lines[normalized_line_number] or normalized_line_number
end

function source.path_from_map(source_map)
  return (source_map or {}).path
end

function source.error_from_map(source_map, normalized_line_number, message)
  return source.format_error(
    source.path_from_map(source_map),
    source.line_from_map(source_map, normalized_line_number),
    message
  )
end

local function _metadata(node)
  return (node or {}).metadata or {}
end

function source.path_from_ir(ir)
  return _metadata(ir).source_path
end

function source.field_name(ir, key)
  return (_metadata(ir).field_names or {})[key] or key
end

function source.field_line(ir, scenario, key)
  local scenario_lines = _metadata(scenario).example_field_lines or {}
  local ir_lines = _metadata(ir).field_lines or {}
  return scenario_lines[key] or ir_lines[key]
end

function source.step_error(ir, step, message)
  local step_metadata = _metadata(step)
  return source.format_error(
    step_metadata.source_path or source.path_from_ir(ir),
    step_metadata.source_line,
    message
  )
end

function source.mutation_description(ir, scenario, key, original, mutated)
  local path = source.path_from_ir(ir)
  local line = source.field_line(ir, scenario, key)
  local location = ""
  if _has_text(path) then
    location = tostring(path)
  end
  if line ~= nil then
    location = location .. ":第" .. tostring(line) .. "行"
  end
  if location ~= "" then
    location = location .. " "
  end
  return location
    .. tostring(source.field_name(ir, key))
    .. ": "
    .. tostring(original)
    .. " -> "
    .. tostring(mutated)
end

return source
