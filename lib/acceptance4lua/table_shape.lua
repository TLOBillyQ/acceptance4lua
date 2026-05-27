local table_shape = {}

local ARRAY_KEYS = {
  background = true,
  examples = true,
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
  table.sort(keys)
  return keys
end

function table_shape.is_array(value, key_hint)
  if type(value) ~= "table" then
    return false
  end

  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
  end

  if count == 0 then
    return ARRAY_KEYS[key_hint] == true
  end

  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end

return table_shape
