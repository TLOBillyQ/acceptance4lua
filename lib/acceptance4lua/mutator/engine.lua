local source = require("acceptance4lua.source")
local table_shape = require("acceptance4lua.table_shape")

local engine = {}

local _trim = source.trim

local function _deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[_deep_copy(key)] = _deep_copy(item)
  end
  return copy
end

local function _stable_hash(text)
  local hash = 2166136261
  for index = 1, #text do
    hash = (hash ~ text:byte(index)) * 16777619
    hash = hash % 2147483647
  end
  return hash
end

local function _signed_delta(seed, magnitude)
  local delta = (seed % magnitude) + 1
  if seed % 2 == 0 then
    return delta
  end
  return -delta
end

local function _split_list(text)
  local values = {}
  for item in tostring(text or ""):gmatch("([^,]+)") do
    values[#values + 1] = _trim(item)
  end
  return values
end

local function _mutate_list_value(trimmed, seed, path)
  if trimmed:find(",", 1, true) == nil then
    return nil
  end

  local values = _split_list(trimmed)
  if #values == 0 then
    return nil
  end

  local index = (seed % #values) + 1
  values[index] = engine.mutate_value(values[index], tostring(path) .. "/" .. tostring(index))
  return table.concat(values, ", ")
end

-- 收集每个 UTF-8 字符的起始字节下标。续字节（0x80-0xBF）归属前一个字符，
-- 因此切点只会落在字符边界上，永不撕裂多字节汉字。对畸形字节也稳健：
-- 任何非续字节都视为新字符起点。
local function _char_starts(text)
  local starts = {}
  for index = 1, #text do
    local byte = text:byte(index)
    if byte < 0x80 or byte >= 0xC0 then
      starts[#starts + 1] = index
    end
  end
  return starts
end

-- 对单个字符做确定性微扰：ASCII 字母/数字按字母表前进一位（保持旧行为），
-- 多字节字符或其它字节一律替换为 "x"，结果始终是合法 UTF-8。
local function _dither_char(original)
  if #original ~= 1 then
    return "x"
  end
  local byte = original:byte()
  if byte >= 65 and byte <= 89 then
    return string.char(byte + 1)
  elseif byte == 90 then
    return "A"
  elseif byte >= 97 and byte <= 121 then
    return string.char(byte + 1)
  elseif byte == 122 then
    return "a"
  elseif byte >= 48 and byte <= 56 then
    return string.char(byte + 1)
  elseif byte == 57 then
    return "0"
  end
  return "x"
end

local function _dither_string(value, seed)
  local text = tostring(value or "")
  if text == "" then
    return "x"
  end

  local starts = _char_starts(text)
  local pick = (seed % #starts) + 1
  local char_start = starts[pick]
  local char_end = (starts[pick + 1] or (#text + 1)) - 1
  local original = text:sub(char_start, char_end)

  local replacement = _dither_char(original)
  if replacement == original then
    replacement = "x"
  end
  return text:sub(1, char_start - 1) .. replacement .. text:sub(char_end + 1)
end

local function _mutate_date(year, month, day, seed)
  local timestamp = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day) + math.abs(_signed_delta(seed, 3)),
    hour = 12,
  })
  return os.date("%Y-%m-%d", timestamp)
end

local function _mutate_time(hour, minute, second, seed)
  local total = tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second or "0")
  total = (total + math.abs(_signed_delta(seed, 300))) % (24 * 3600)
  local new_hour = math.floor(total / 3600)
  local new_minute = math.floor((total % 3600) / 60)
  local new_second = total % 60
  if second == nil then
    return string.format("%02d:%02d", new_hour, new_minute)
  end
  return string.format("%02d:%02d:%02d", new_hour, new_minute, new_second)
end

local function _mutate_duration(trimmed, seed)
  local value, suffix = trimmed:match("^(%-?%d+)(ms)$")
  if value == nil then
    value, suffix = trimmed:match("^(%-?%d+)([smhd])$")
  end
  if value ~= nil then
    local mutated = tonumber(value) + _signed_delta(seed, 9)
    if mutated < 0 then
      mutated = 0
    end
    if tostring(mutated) == tostring(value) then
      mutated = mutated + 1
    end
    return tostring(mutated) .. suffix
  end

  value, suffix = trimmed:match("^PT(%d+)([HMS])$")
  if value ~= nil then
    local mutated = tonumber(value) + math.abs(_signed_delta(seed, 9))
    return "PT" .. tostring(mutated) .. suffix
  end
  return nil
end

local function _mutate_keyword(trimmed)
  local lower = trimmed:lower()
  if lower == "true" then
    return "false"
  end
  if lower == "false" then
    return "true"
  end
  if lower == "null" or lower == "nil" or lower == "none" then
    return "value"
  end
  return nil
end

local function _mutate_number(trimmed, seed)
  if trimmed:match("^%-?%d+$") ~= nil then
    return tostring(tonumber(trimmed) + _signed_delta(seed, 9))
  end
  if trimmed:match("^%-?%d+%.%d+$") ~= nil then
    local delta = _signed_delta(seed, 9) / 10
    return tostring(tonumber(trimmed) + delta)
  end
  return nil
end

local function _mutate_datetime(trimmed, seed)
  local dt_year, dt_month, dt_day, dt_hour, dt_minute, dt_second, zulu = trimmed:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(Z?)$")
  if dt_year ~= nil then
    local date = _mutate_date(dt_year, dt_month, dt_day, seed)
    local time = _mutate_time(dt_hour, dt_minute, dt_second, seed)
    return date .. "T" .. time .. (zulu or "")
  end

  local year, month, day = trimmed:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if year ~= nil then
    return _mutate_date(year, month, day, seed)
  end

  local hour, minute, second = trimmed:match("^(%d%d):(%d%d):(%d%d)$")
  if hour ~= nil then
    return _mutate_time(hour, minute, second, seed)
  end
  hour, minute = trimmed:match("^(%d%d):(%d%d)$")
  if hour ~= nil then
    return _mutate_time(hour, minute, nil, seed)
  end
  return nil
end

function engine.mutate_value(value, path)
  local original = tostring(value or "")
  local trimmed = _trim(original)
  local seed = _stable_hash(tostring(path or "") .. "\0" .. original)

  local mutated = _mutate_list_value(trimmed, seed, path)
  if mutated ~= nil then
    return mutated
  end

  mutated = _mutate_keyword(trimmed)
  if mutated ~= nil then
    return mutated
  end

  mutated = _mutate_number(trimmed, seed)
  if mutated ~= nil then
    return mutated
  end

  mutated = _mutate_datetime(trimmed, seed)
  if mutated ~= nil then
    return mutated
  end

  local duration = _mutate_duration(trimmed, seed)
  if duration ~= nil then
    return duration
  end

  return _dither_string(original, seed)
end

function engine.build_mutations(ir)
  local mutations = {}
  for scenario_index, scenario in ipairs(ir.scenarios or {}) do
    for example_index, example in ipairs(scenario.examples or {}) do
      for _, key in ipairs(table_shape.sorted_keys(example)) do
        local path = "$.scenarios["
          .. tostring(scenario_index - 1)
          .. "].examples["
          .. tostring(example_index - 1)
          .. "]."
          .. tostring(key)
        local original = tostring(example[key] or "")
        local mutated = engine.mutate_value(original, path)
        if mutated ~= original then
          local id = "m" .. tostring(#mutations + 1)
          mutations[#mutations + 1] = {
            id = id,
            path = path,
            description = path .. ": " .. original .. " -> " .. mutated,
            display_description = source.mutation_description(ir, scenario, key, original, mutated),
            source_path = source.path_from_ir(ir),
            source_line = source.field_line(ir, scenario, key),
            source_field = source.field_name(ir, key),
            original = original,
            mutated = mutated,
            scenario_index = scenario_index,
            example_index = example_index,
            key = key,
          }
        end
      end
    end
  end
  return mutations
end

function engine.apply_mutation(ir, mutation)
  local copy = _deep_copy(ir)
  copy.scenarios[mutation.scenario_index].examples[mutation.example_index][mutation.key] = mutation.mutated
  return copy
end

return engine
