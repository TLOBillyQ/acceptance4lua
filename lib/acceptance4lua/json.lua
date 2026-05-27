local table_shape = require("acceptance4lua.table_shape")

local json = {}

local function _escape_string(value)
  local escaped = tostring(value or "")
  escaped = escaped:gsub("\\", "\\\\")
  escaped = escaped:gsub("\"", "\\\"")
  escaped = escaped:gsub("\b", "\\b")
  escaped = escaped:gsub("\f", "\\f")
  escaped = escaped:gsub("\n", "\\n")
  escaped = escaped:gsub("\r", "\\r")
  escaped = escaped:gsub("\t", "\\t")
  return escaped
end

local function _encode(value, indent, key_hint)
  local value_type = type(value)
  if value == nil then
    return "null"
  end
  if value_type == "string" then
    return "\"" .. _escape_string(value) .. "\""
  end
  if value_type == "boolean" or value_type == "number" then
    return tostring(value)
  end
  if value_type ~= "table" then
    return "\"" .. _escape_string(value) .. "\""
  end

  local next_indent = indent + 2
  local pad = string.rep(" ", indent)
  local child_pad = string.rep(" ", next_indent)

  if table_shape.is_array(value, key_hint) then
    if next(value) == nil then
      return "[]"
    end
    local parts = {}
    for index, item in ipairs(value) do
      parts[#parts + 1] = child_pad .. _encode(item, next_indent)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  end

  local keys = table_shape.sorted_keys(value)
  if #keys == 0 then
    return "{}"
  end

  local fields = {}
  for _, key in ipairs(keys) do
    fields[#fields + 1] = child_pad
      .. "\""
      .. _escape_string(key)
      .. "\": "
      .. _encode(value[key], next_indent, key)
  end
  return "{\n" .. table.concat(fields, ",\n") .. "\n" .. pad .. "}"
end

local function _encode_compact(value, key_hint)
  local value_type = type(value)
  if value == nil then
    return "null"
  end
  if value_type == "string" then
    return "\"" .. _escape_string(value) .. "\""
  end
  if value_type == "boolean" or value_type == "number" then
    return tostring(value)
  end
  if value_type ~= "table" then
    return "\"" .. _escape_string(value) .. "\""
  end

  if table_shape.is_array(value, key_hint) then
    local parts = {}
    for index, item in ipairs(value) do
      parts[index] = _encode_compact(item)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local fields = {}
  for _, key in ipairs(table_shape.sorted_keys(value)) do
    fields[#fields + 1] = "\"" .. _escape_string(key) .. "\":" .. _encode_compact(value[key], key)
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

local function _char_at(text, index)
  return text:sub(index, index)
end

local function _is_whitespace(ch)
  return ch == " " or ch == "\n" or ch == "\r" or ch == "\t"
end

local function _skip_whitespace(text, index)
  local cursor = index
  while cursor <= #text and _is_whitespace(_char_at(text, cursor)) do
    cursor = cursor + 1
  end
  return cursor
end

local function _decode_error(message, index)
  error("json decode error at " .. tostring(index) .. ": " .. tostring(message), 0)
end

local function _parse_string(text, index)
  local cursor = index + 1
  local parts = {}
  while cursor <= #text do
    local ch = _char_at(text, cursor)
    if ch == "\"" then
      return table.concat(parts), cursor + 1
    end
    if ch == "\\" then
      local escaped = _char_at(text, cursor + 1)
      if escaped == "\"" or escaped == "\\" or escaped == "/" then
        parts[#parts + 1] = escaped
      elseif escaped == "b" then
        parts[#parts + 1] = "\b"
      elseif escaped == "f" then
        parts[#parts + 1] = "\f"
      elseif escaped == "n" then
        parts[#parts + 1] = "\n"
      elseif escaped == "r" then
        parts[#parts + 1] = "\r"
      elseif escaped == "t" then
        parts[#parts + 1] = "\t"
      else
        _decode_error("unsupported escape sequence", cursor)
      end
      cursor = cursor + 2
    else
      parts[#parts + 1] = ch
      cursor = cursor + 1
    end
  end
  _decode_error("unterminated string", index)
end

local function _parse_number(text, index)
  local cursor = index
  while cursor <= #text and _char_at(text, cursor):match("[%d%+%-%e%E%.]") do
    cursor = cursor + 1
  end
  local raw = text:sub(index, cursor - 1)
  local value = tonumber(raw)
  if value == nil then
    _decode_error("invalid number", index)
  end
  return value, cursor
end

local function _parse_literal(text, index, literal, value)
  if text:sub(index, index + #literal - 1) ~= literal then
    _decode_error("invalid literal", index)
  end
  return value, index + #literal
end

local _parse_value

local function _parse_array(text, index)
  local cursor = _skip_whitespace(text, index + 1)
  local values = {}
  if _char_at(text, cursor) == "]" then
    return values, cursor + 1
  end

  while cursor <= #text do
    local value
    value, cursor = _parse_value(text, cursor)
    values[#values + 1] = value
    cursor = _skip_whitespace(text, cursor)
    local ch = _char_at(text, cursor)
    if ch == "]" then
      return values, cursor + 1
    end
    if ch ~= "," then
      _decode_error("expected ',' or ']'", cursor)
    end
    cursor = _skip_whitespace(text, cursor + 1)
  end
  _decode_error("unterminated array", index)
end

local function _parse_object(text, index)
  local cursor = _skip_whitespace(text, index + 1)
  local object = {}
  if _char_at(text, cursor) == "}" then
    return object, cursor + 1
  end

  while cursor <= #text do
    if _char_at(text, cursor) ~= "\"" then
      _decode_error("expected string key", cursor)
    end
    local key
    key, cursor = _parse_string(text, cursor)
    cursor = _skip_whitespace(text, cursor)
    if _char_at(text, cursor) ~= ":" then
      _decode_error("expected ':' after key", cursor)
    end
    cursor = _skip_whitespace(text, cursor + 1)
    object[key], cursor = _parse_value(text, cursor)
    cursor = _skip_whitespace(text, cursor)
    local ch = _char_at(text, cursor)
    if ch == "}" then
      return object, cursor + 1
    end
    if ch ~= "," then
      _decode_error("expected ',' or '}'", cursor)
    end
    cursor = _skip_whitespace(text, cursor + 1)
  end
  _decode_error("unterminated object", index)
end

function _parse_value(text, index)
  local cursor = _skip_whitespace(text, index)
  local ch = _char_at(text, cursor)
  if ch == "\"" then
    return _parse_string(text, cursor)
  end
  if ch == "[" then
    return _parse_array(text, cursor)
  end
  if ch == "{" then
    return _parse_object(text, cursor)
  end
  if ch == "t" then
    return _parse_literal(text, cursor, "true", true)
  end
  if ch == "f" then
    return _parse_literal(text, cursor, "false", false)
  end
  if ch == "n" then
    return _parse_literal(text, cursor, "null", nil)
  end
  if ch == "-" or ch:match("%d") ~= nil then
    return _parse_number(text, cursor)
  end
  _decode_error("unexpected token", cursor)
end

function json.encode(value)
  return _encode(value, 0) .. "\n"
end

function json.encode_compact(value)
  return _encode_compact(value) .. "\n"
end

function json.decode(text)
  local value, cursor = _parse_value(tostring(text or ""), 1)
  cursor = _skip_whitespace(tostring(text or ""), cursor)
  if cursor <= #(text or "") then
    _decode_error("trailing content", cursor)
  end
  return value
end

return json
