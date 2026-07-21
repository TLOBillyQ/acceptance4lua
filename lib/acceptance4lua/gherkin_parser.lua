local common = require("acceptance4lua.runtime.common")
local chinese_normalizer = require("acceptance4lua.chinese_normalizer")
local json = require("acceptance4lua.json")
local source = require("acceptance4lua.source")
local spec_hash = require("acceptance4lua.spec_hash")

local gherkin_parser = {}

local _trim = source.trim

-- 与 chinese_normalizer.STEP_KEYWORDS 的英文目标对齐。
-- 加新关键字（如 But）只需追加一行，不必再插一条 if-keyword==nil 分支。
local _STEP_KEYWORDS = { "Given", "When", "Then", "And" }

-- 逐行匹配的 pattern 在模块加载时预拼接，避免每个 step 行重复字符串拼接。
local _STEP_PATTERNS = {}
for _, keyword in ipairs(_STEP_KEYWORDS) do
  _STEP_PATTERNS[#_STEP_PATTERNS + 1] = "^(" .. keyword .. ")%s+(.+)$"
end

local function _strip_mutation_metadata(content)
  local stripped = tostring(content or "")
  stripped = stripped:gsub("# acceptance%-mutation%-manifest%-begin\n.-# acceptance%-mutation%-manifest%-end\n?", "", 1)
  -- stamp 行的剥离逻辑与 spec_hash.strip_first_stamp_line 保持一致（单一实现）。
  return spec_hash.strip_first_stamp_line(stripped)
end

local function _step(keyword, text, line_number, source_map)
  local source_line = source.line_from_map(source_map, line_number)
  return {
    keyword = keyword,
    text = _trim(text),
    parameters = source.extract_parameters(text),
    metadata = {
      source_path = source.path_from_map(source_map),
      source_line = source_line,
      original_text = ((source_map or {}).original_step_text_by_line or {})[source_line],
    },
  }
end

local function _error(line_number, message, opts)
  return nil, source.error_from_map((opts or {}).source_map or {}, line_number, message)
end

local function _example_header_message(source_map, header_line_number, base_message)
  local source_header_line = source.line_from_map(source_map, header_line_number)
  local headers = ((source_map or {}).example_headers_by_line or {})[source_header_line]
  if headers == nil or #headers == 0 then
    return base_message
  end
  return base_message .. "；字段: " .. table.concat(headers, ", ")
end

function gherkin_parser.parse_text(text, opts)
  opts = opts or {}
  local source_map = opts.source_map or {}
  local feature = nil
  local current_scenario = nil
  local section = nil
  local example_headers = nil
  local example_header_line_number = nil
  local has_background = false
  local line_number = 0

  for raw_line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    line_number = line_number + 1
    local line = _trim(raw_line)

    if line == "" or line:sub(1, 1) == "#" then
      goto continue
    end

    local feature_name = line:match("^Feature:%s*(.+)$")
    if feature_name ~= nil then
      if feature ~= nil then
        return _error(line_number, "multiple feature declarations are not supported", opts)
      end
      feature = {
        name = _trim(feature_name),
        background = {},
        scenarios = {},
        metadata = {
          source_path = source.path_from_map(source_map),
          language = source_map.language or "aps",
          field_names = source_map.field_names or {},
          field_lines = source_map.field_lines or {},
        },
      }
      current_scenario = nil
      section = nil
      goto continue
    end

    if feature == nil then
      return _error(line_number, "missing feature declaration", opts)
    end

    if line == "Background:" then
      if has_background then
        return _error(line_number, "multiple background sections are not supported", opts)
      end
      has_background = true
      current_scenario = nil
      section = "background"
      goto continue
    end

    local outline_name = line:match("^Scenario Outline:%s*(.+)$")
    local scenario_name = outline_name or line:match("^Scenario:%s*(.+)$")
    if scenario_name ~= nil then
      current_scenario = {
        name = _trim(scenario_name),
        steps = {},
        examples = {},
        metadata = {
          source_path = source.path_from_map(source_map),
          source_line = source.line_from_map(source_map, line_number),
          example_field_lines = {},
        },
      }
      feature.scenarios[#feature.scenarios + 1] = current_scenario
      section = "scenario"
      example_headers = nil
      example_header_line_number = nil
      goto continue
    end

    if line == "Examples:" then
      if current_scenario == nil then
        return _error(line_number, "examples section outside scenario", opts)
      end
      current_scenario.examples = {}
      section = "examples"
      example_headers = nil
      example_header_line_number = nil
      goto continue
    end

    if section == "examples" and line:sub(1, 1) == "|" then
      local cells = source.split_table_cells(line)
      if example_headers == nil then
        example_headers = cells
        example_header_line_number = line_number
        local source_header_line = source.line_from_map(source_map, line_number)
        current_scenario.metadata.example_field_lines =
          ((source_map.header_field_lines_by_line or {})[source_header_line]) or {}
      else
        if #cells ~= #example_headers then
          local message = _example_header_message(
            source_map,
            example_header_line_number,
            "examples row has " .. tostring(#cells) .. " cells, expected " .. tostring(#example_headers)
          )
          return _error(line_number, message, opts)
        end
        local example = {}
        for index, header in ipairs(example_headers) do
          example[header] = cells[index]
        end
        current_scenario.examples[#current_scenario.examples + 1] = example
      end
      goto continue
    end

    local keyword, step_text
    for _, pattern in ipairs(_STEP_PATTERNS) do
      keyword, step_text = line:match(pattern)
      if keyword ~= nil then break end
    end
    if keyword == nil then
      return _error(line_number, "unsupported line: " .. line, opts)
    end

    if section == "background" then
      feature.background[#feature.background + 1] = _step(keyword, step_text, line_number, source_map)
    elseif current_scenario ~= nil then
      current_scenario.steps[#current_scenario.steps + 1] = _step(keyword, step_text, line_number, source_map)
      section = "scenario"
    else
      return _error(line_number, "step outside background or scenario", opts)
    end

    ::continue::
  end

  if feature == nil then
    -- 与循环内的同名错误保持一致，带上 source_map 的路径前缀，方便定位文件。
    return nil, source.error_from_map(source_map, 1, "missing feature declaration")
  end

  return feature
end

function gherkin_parser.parse_file(path, opts)
  local content, err = common.read_file(path)
  if content == nil then
    return nil, err
  end
  local normalized
  normalized, err = chinese_normalizer.normalize_text(_strip_mutation_metadata(content), {
    path = path,
    mandatory_language_dirs = opts and opts.mandatory_language_dirs or nil,
  })
  if normalized == nil then
    return nil, err
  end
  return gherkin_parser.parse_text(normalized.text, {
    source_map = normalized.source_map,
  })
end

function gherkin_parser.write_json_file(feature_path, output_path, opts)
  local ir, err = gherkin_parser.parse_file(feature_path, opts)
  if ir == nil then
    return nil, err
  end

  -- common.write_file 内部已负责创建父目录，无需重复 ensure_dir。
  local ok
  ok, err = common.write_file(output_path, json.encode(ir))
  if not ok then
    return nil, err
  end
  return true
end

return gherkin_parser
