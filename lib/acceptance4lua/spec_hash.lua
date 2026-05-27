local common = require("acceptance4lua.runtime.common")
local json = require("acceptance4lua.json")

local spec_hash = {}

local _K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local _MASK32 = 0xFFFFFFFF

local function _rrot(value, count)
  return ((value >> count) | (value << (32 - count))) & _MASK32
end

local function _pad(message)
  local bit_length = #message * 8
  local padded = message .. "\x80"
  local zero_count = (-#padded - 8) % 64
  return padded .. string.rep("\0", zero_count) .. string.pack(">I8", bit_length)
end

local function _compress(state, block)
  local words = {}
  for index = 1, 16 do
    words[index] = string.unpack(">I4", block, (index - 1) * 4 + 1)
  end
  for index = 17, 64 do
    local prior = words[index - 15]
    local recent = words[index - 2]
    local sigma0 = _rrot(prior, 7) ~ _rrot(prior, 18) ~ (prior >> 3)
    local sigma1 = _rrot(recent, 17) ~ _rrot(recent, 19) ~ (recent >> 10)
    words[index] = (words[index - 16] + sigma0 + words[index - 7] + sigma1) & _MASK32
  end

  local a, b, c, d, e, f, g, h = state[1], state[2], state[3], state[4], state[5], state[6], state[7], state[8]

  for index = 1, 64 do
    local s1 = _rrot(e, 6) ~ _rrot(e, 11) ~ _rrot(e, 25)
    local ch = (e & f) ~ ((_MASK32 ~ e) & g)
    local temp1 = (h + s1 + ch + _K[index] + words[index]) & _MASK32
    local s0 = _rrot(a, 2) ~ _rrot(a, 13) ~ _rrot(a, 22)
    local maj = (a & b) ~ (a & c) ~ (b & c)
    local temp2 = (s0 + maj) & _MASK32

    h = g
    g = f
    f = e
    e = (d + temp1) & _MASK32
    d = c
    c = b
    b = a
    a = (temp1 + temp2) & _MASK32
  end

  state[1] = (state[1] + a) & _MASK32
  state[2] = (state[2] + b) & _MASK32
  state[3] = (state[3] + c) & _MASK32
  state[4] = (state[4] + d) & _MASK32
  state[5] = (state[5] + e) & _MASK32
  state[6] = (state[6] + f) & _MASK32
  state[7] = (state[7] + g) & _MASK32
  state[8] = (state[8] + h) & _MASK32
end

function spec_hash.sha256(message)
  local state = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  }
  local padded = _pad(tostring(message or ""))
  for offset = 1, #padded, 64 do
    _compress(state, padded:sub(offset, offset + 63))
  end
  return string.format(
    "%08x%08x%08x%08x%08x%08x%08x%08x",
    state[1], state[2], state[3], state[4], state[5], state[6], state[7], state[8]
  )
end

function spec_hash.strip_first_stamp_line(feature_source)
  local source = tostring(feature_source or "")
  local stripped, replacements = source:gsub("^%s*#%s*mutation%-stamp:[^\n]*\n?", "", 1)
  if replacements == 0 then
    stripped = source:gsub("\n%s*#%s*mutation%-stamp:[^\n]*\n?", "\n", 1)
  end
  return stripped
end

function spec_hash.compute_feature_content_hash(feature_source)
  return spec_hash.sha256(spec_hash.strip_first_stamp_line(feature_source))
end

local function _canonical_step(step)
  return {
    keyword = step.keyword,
    text = step.text,
    parameters = step.parameters or {},
  }
end

local function _canonical_steps(steps)
  local canonical = {}
  for index, step in ipairs(steps or {}) do
    canonical[index] = _canonical_step(step)
  end
  return canonical
end

function spec_hash.compute_background_hash(background_steps)
  return spec_hash.sha256(json.encode(_canonical_steps(background_steps)))
end

function spec_hash.compute_scenario_hash(scenario)
  local canonical = {
    name = scenario.name,
    steps = _canonical_steps(scenario.steps),
    examples = scenario.examples or {},
  }
  return spec_hash.sha256(json.encode(canonical))
end

function spec_hash.compute_generated_files_hash(generated_files, project_root)
  local root = project_root or common.current_dir()
  local lines = {}
  local files = {}
  for index, path in ipairs(generated_files or {}) do
    files[index] = path
  end
  table.sort(files)

  for _, relative_path in ipairs(files) do
    local absolute_path = common.normalize_path(root .. "/" .. relative_path)
    if common.is_absolute_path(relative_path) then
      absolute_path = common.normalize_path(relative_path)
    end
    local content, err = common.read_file(absolute_path)
    local file_hash
    if content == nil then
      file_hash = "missing:" .. tostring(err or "unknown")
    else
      file_hash = spec_hash.sha256(content)
    end
    lines[#lines + 1] = file_hash
  end
  return "sha256:" .. spec_hash.sha256(table.concat(lines, "\n"))
end

return spec_hash
