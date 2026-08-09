local table_shape = {}

local ARRAY_KEYS = {
  background = true,
  examples = true,
  findings = true,
  parameters = true,
  results = true,
  scenarios = true,
  steps = true,
}

function table_shape.sorted_keys(map)
  local keys = {}
  for key in pairs(map or {}) do
    keys[#keys + 1] = key
  end
  -- 同类型的字符串/数字键保持原生排序；混合或其他类型退化为 tostring 排序，
  -- 避免 table.sort 默认比较在 "attempt to compare" 上直接报错。
  table.sort(keys, function(left, right)
    local left_type = type(left)
    if left_type == type(right) and (left_type == "number" or left_type == "string") then
      return left < right
    end
    return tostring(left) < tostring(right)
  end)
  return keys
end

function table_shape.is_array(value, key_hint)
  if type(value) ~= "table" then
    return false
  end

  local count = 0
  local max_index = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    if key > max_index then
      max_index = key
    end
  end

  if count == 0 then
    return ARRAY_KEYS[key_hint] == true
  end

  -- 键全为正整数时，1..count 稠密 ⟺ 最大键 == 键数。
  return max_index == count
end

return table_shape
