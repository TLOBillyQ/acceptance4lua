--- IR-DRY checker: 读一份 parser 产出的 JSON IR,报告重复、近似、疑似同义的
--- step 文本。报告是 advisory 的:本模块只读 IR,不改写 feature、IR、生成物或
--- 项目实现文件(见 APS ir-dry-checker-spec.md)。
---
--- 与 APS portable baseline 的唯一偏离是相似度分词:baseline 按 alphanumeric
--- token 切词,中文 step 去掉占位符后不剩 token,任意两条中文 step 都会算出
--- score 1.0。本实现按 CJK 字符切 unigram + bigram(APS 允许 "better
--- language-neutral heuristics"),精确匹配类目仍保持 baseline 语义。
local json = require("acceptance4lua.json")

local ir_dry = {}

local NEAR_DUPLICATE_THRESHOLD = 0.72
local POSSIBLE_SYNONYM_THRESHOLD = 0.45

-- APS baseline 的 "small function words":只在 ASCII token 上生效。
local ASCII_STOP_WORDS = {
  ["a"] = true,
  ["an"] = true,
  ["and"] = true,
  ["are"] = true,
  ["at"] = true,
  ["be"] = true,
  ["for"] = true,
  ["in"] = true,
  ["is"] = true,
  ["of"] = true,
  ["on"] = true,
  ["or"] = true,
  ["that"] = true,
  ["the"] = true,
  ["to"] = true,
  ["was"] = true,
  ["were"] = true,
  ["with"] = true,
}

-- 中文虚词:只在 unigram 上丢弃。bigram 仍保留它们,因为 bigram 自带上下文。
local CJK_STOP_CHARS = {
  ["的"] = true,
  ["了"] = true,
  ["是"] = true,
  ["在"] = true,
  ["为"] = true,
  ["和"] = true,
  ["与"] = true,
  ["有"] = true,
  ["个"] = true,
  ["就"] = true,
  ["都"] = true,
  ["也"] = true,
}

local KIND_ORDER = {
  ["duplicate-in-scenario"] = 1,
  ["exact-duplicate"] = 2,
  ["placeholder-variant"] = 3,
  ["near-duplicate"] = 4,
  ["possible-synonym"] = 5,
}

local REASONS = {
  ["duplicate-in-scenario"] = "the same step text appears more than once in one background or scenario",
  ["exact-duplicate"] = "the same step text appears more than once in the IR",
  ["placeholder-variant"] = "step text is identical after replacing placeholder names with generic slots",
  ["near-duplicate"] = "step texts have high token similarity after placeholder normalization",
  ["possible-synonym"] = "step texts have moderate token similarity after placeholder normalization",
}

local SUGGESTED_ACTIONS = {
  ["duplicate-in-scenario"] = "Review the scenario and remove the repeated step unless the repetition is intentional.",
  ["exact-duplicate"] = "Reuse across scenarios is often normal; confirm the shared step still reads correctly.",
  ["placeholder-variant"] = "Review the feature wording and normalize the Gherkin if the different forms do not add meaning.",
  ["near-duplicate"] = "Advisory only; inspect both steps and normalize the wording if they mean the same thing.",
  ["possible-synonym"] = "Review prompt only; confirm the two steps really mean the same thing before changing either.",
}

local CONFIDENCE = {
  ["duplicate-in-scenario"] = "high",
  ["exact-duplicate"] = "high",
  ["placeholder-variant"] = "high",
  ["near-duplicate"] = "medium",
  ["possible-synonym"] = "low",
}

local function _is_han(codepoint)
  return (codepoint >= 0x4E00 and codepoint <= 0x9FFF)
    or (codepoint >= 0x3400 and codepoint <= 0x4DBF)
end

local function _is_ascii_alnum(codepoint)
  return (codepoint >= 48 and codepoint <= 57)
    or (codepoint >= 65 and codepoint <= 90)
    or (codepoint >= 97 and codepoint <= 122)
end

--- 把占位符名替换成有序通用槽位:同名占位符共用一个槽位。
--- "玩家从<起点>走到<终点>" -> "玩家从<_1>走到<_2>"
local function _normalize_placeholders(text)
  local slots = {}
  local next_slot = 0
  return (text:gsub("<([^<>]*)>", function(name)
    if slots[name] == nil then
      next_slot = next_slot + 1
      slots[name] = next_slot
    end
    return "<_" .. slots[name] .. ">"
  end))
end

--- canonical 候选:占位符统一成 <value>,供人类阅读。
local function _canonical_candidate(text)
  return (text:gsub("<[^<>]*>", "<value>"))
end

--- pattern 候选:占位符变成捕获组,其余字符转义后锚定。
local function _pattern_candidate(text)
  local parts = { "^" }
  local cursor = 1
  while cursor <= #text do
    local open_at, close_at = text:find("<[^<>]*>", cursor)
    if open_at == nil then
      parts[#parts + 1] = text:sub(cursor):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
      break
    end
    parts[#parts + 1] = text:sub(cursor, open_at - 1):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    parts[#parts + 1] = "(.+)"
    cursor = close_at + 1
  end
  parts[#parts + 1] = "$"
  return table.concat(parts)
end

--- 相似度分词:剥掉占位符,ASCII 串小写成词,汉字串切 unigram + bigram。
--- 返回 token 集合(set)。
local function _tokenize(text)
  local stripped = text:gsub("<[^<>]*>", " ")
  local tokens = {}

  local ascii_run = {}
  local han_run = {}

  local function flush_ascii()
    if #ascii_run == 0 then
      return
    end
    local word = table.concat(ascii_run):lower()
    if not ASCII_STOP_WORDS[word] then
      tokens[word] = true
    end
    ascii_run = {}
  end

  -- 汉字串先丢虚词再切 bigram(APS 规则 5「忽略小虚词」的中文对应):
  --   * bigram 自带词序上下文;单字 unigram 噪声太大(两条语义无关的中文 step
  --     常共享「玩」「家」这类高频字),实测会把真实 finding 淹掉。
  --   * 虚词若不先丢,插一个「的」就会毁掉两个 bigram 又新增两个,让「当前轮到
  --     角色ID为」与「当前轮到的角色ID为」这种只差一个虚词的改写掉出近似档。
  -- 长度为 1 的汉字串没有 bigram,退化成该字本身。
  local function flush_han()
    if #han_run == 0 then
      return
    end

    local content = {}
    for _, char in ipairs(han_run) do
      if not CJK_STOP_CHARS[char] then
        content[#content + 1] = char
      end
    end

    if #content == 1 then
      tokens[content[1]] = true
    else
      for index = 1, #content - 1 do
        tokens[content[index] .. content[index + 1]] = true
      end
    end
    han_run = {}
  end

  for _, codepoint in utf8.codes(stripped) do
    local char = utf8.char(codepoint)
    if _is_ascii_alnum(codepoint) then
      flush_han()
      ascii_run[#ascii_run + 1] = char
    elseif _is_han(codepoint) then
      flush_ascii()
      han_run[#han_run + 1] = char
    else
      flush_ascii()
      flush_han()
    end
  end
  flush_ascii()
  flush_han()

  return tokens
end

local function _jaccard(left, right)
  local shared = 0
  local total = 0
  for token in pairs(left) do
    total = total + 1
    if right[token] then
      shared = shared + 1
    end
  end
  for token in pairs(right) do
    if not left[token] then
      total = total + 1
    end
  end
  if total == 0 then
    return 0
  end
  return shared / total
end

--- 展开 IR 里的全部 step 出现位置。section 为 "background" 或 "scenario";
--- scenario_index / step_index 与 APS 报告示例一致,从 0 起。
local function _collect_occurrences(ir)
  local occurrences = {}

  for step_index, step in ipairs(ir.background or {}) do
    occurrences[#occurrences + 1] = {
      text = step.text,
      container = "background",
      location = {
        section = "background",
        step_index = step_index - 1,
        keyword = step.keyword,
      },
    }
  end

  for scenario_index, scenario in ipairs(ir.scenarios or {}) do
    for step_index, step in ipairs(scenario.steps or {}) do
      occurrences[#occurrences + 1] = {
        text = step.text,
        container = "scenario:" .. scenario_index,
        location = {
          section = "scenario",
          scenario_index = scenario_index - 1,
          scenario_name = scenario.name,
          step_index = step_index - 1,
          keyword = step.keyword,
        },
      }
    end
  end

  return occurrences
end

--- 按文本聚合位置,保持 IR 顺序。
local function _locations_by_text(occurrences)
  local locations = {}
  local order = {}
  for _, occurrence in ipairs(occurrences) do
    if locations[occurrence.text] == nil then
      locations[occurrence.text] = {}
      order[#order + 1] = occurrence.text
    end
    local bucket = locations[occurrence.text]
    bucket[#bucket + 1] = occurrence.location
  end
  return locations, order
end

local function _member(text, locations)
  return { text = text, locations = locations }
end

local function _finding(kind, members, score)
  local canonical = _canonical_candidate(members[1].text)
  local finding = {
    kind = kind,
    confidence = CONFIDENCE[kind],
    canonical_candidate = canonical,
    pattern_candidate = _pattern_candidate(members[1].text),
    members = members,
    reason = REASONS[kind],
    suggested_action = SUGGESTED_ACTIONS[kind],
  }
  if score ~= nil then
    finding.score = score
  end
  return finding
end

local function _sort_key(finding)
  local texts = {}
  for _, member in ipairs(finding.members) do
    texts[#texts + 1] = member.text
  end
  table.sort(texts)
  return string.format("%d\1%s", KIND_ORDER[finding.kind] or 99, table.concat(texts, "\1"))
end

--- 一个 background / scenario 内部的重复文本。
local function _duplicate_in_scenario(occurrences)
  local findings = {}
  local containers = {}
  local container_order = {}

  for _, occurrence in ipairs(occurrences) do
    local container = containers[occurrence.container]
    if container == nil then
      container = { locations = {}, order = {} }
      containers[occurrence.container] = container
      container_order[#container_order + 1] = occurrence.container
    end
    if container.locations[occurrence.text] == nil then
      container.locations[occurrence.text] = {}
      container.order[#container.order + 1] = occurrence.text
    end
    local bucket = container.locations[occurrence.text]
    bucket[#bucket + 1] = occurrence.location
  end

  for _, container_key in ipairs(container_order) do
    local container = containers[container_key]
    for _, text in ipairs(container.order) do
      local locations = container.locations[text]
      if #locations > 1 then
        findings[#findings + 1] = _finding("duplicate-in-scenario", { _member(text, locations) })
      end
    end
  end

  return findings
end

--- 整份 IR 里的完全重复文本(仅 --include-exact)。
local function _exact_duplicates(locations, order)
  local findings = {}
  for _, text in ipairs(order) do
    if #locations[text] > 1 then
      findings[#findings + 1] = _finding("exact-duplicate", { _member(text, locations[text]) })
    end
  end
  return findings
end

--- 占位符换成通用槽位后完全相同的不同文本。
local function _placeholder_variants(locations, order)
  local groups = {}
  local group_order = {}

  for _, text in ipairs(order) do
    local normalized = _normalize_placeholders(text)
    if groups[normalized] == nil then
      groups[normalized] = {}
      group_order[#group_order + 1] = normalized
    end
    local group = groups[normalized]
    group[#group + 1] = text
  end

  local findings = {}
  for _, normalized in ipairs(group_order) do
    local texts = groups[normalized]
    if #texts > 1 then
      local members = {}
      for _, text in ipairs(texts) do
        members[#members + 1] = _member(text, locations[text])
      end
      findings[#findings + 1] = _finding("placeholder-variant", members)
    end
  end

  return findings
end

--- 相似度成对比较。已经构成 placeholder-variant 的文本对(归一后相同)不再重复报。
local function _similarity_findings(locations, order)
  local tokens = {}
  local normalized = {}
  for _, text in ipairs(order) do
    tokens[text] = _tokenize(text)
    normalized[text] = _normalize_placeholders(text)
  end

  local findings = {}
  for left_index = 1, #order - 1 do
    for right_index = left_index + 1, #order do
      local left = order[left_index]
      local right = order[right_index]
      if normalized[left] ~= normalized[right] then
        local score = _jaccard(tokens[left], tokens[right])
        local kind = nil
        if score >= NEAR_DUPLICATE_THRESHOLD then
          kind = "near-duplicate"
        elseif score >= POSSIBLE_SYNONYM_THRESHOLD then
          kind = "possible-synonym"
        end
        if kind ~= nil then
          findings[#findings + 1] = _finding(kind, {
            _member(left, locations[left]),
            _member(right, locations[right]),
          }, score)
        end
      end
    end
  end

  return findings
end

--- 分析一份 IR,返回 APS 报告表。opts.include_exact 打开跨 IR 完全重复类目。
function ir_dry.analyze(ir, opts)
  opts = opts or {}
  ir = ir or {}

  local occurrences = _collect_occurrences(ir)
  local locations, order = _locations_by_text(occurrences)

  local findings = {}
  local function absorb(batch)
    for _, finding in ipairs(batch) do
      findings[#findings + 1] = finding
    end
  end

  absorb(_duplicate_in_scenario(occurrences))
  if opts.include_exact then
    absorb(_exact_duplicates(locations, order))
  end
  absorb(_placeholder_variants(locations, order))
  absorb(_similarity_findings(locations, order))

  table.sort(findings, function(left, right)
    return _sort_key(left) < _sort_key(right)
  end)

  return {
    schema_version = 1,
    feature_name = ir.name,
    summary = {
      step_occurrences = #occurrences,
      unique_steps = #order,
      findings = #findings,
    },
    findings = findings,
  }
end

local function _read_file(path)
  local handle, open_err = io.open(path, "r")
  if handle == nil then
    return nil, "cannot read IR: " .. tostring(open_err)
  end
  local text = handle:read("a")
  handle:close()
  return text
end

--- 读 IR 文件,写 JSON 报告文件。只读入参 IR,不回写。
function ir_dry.write_report_file(ir_path, report_path, opts)
  local text, read_err = _read_file(ir_path)
  if text == nil then
    return nil, read_err
  end

  local ok, ir = pcall(json.decode, text)
  if not ok then
    return nil, "cannot decode IR: " .. tostring(ir)
  end

  local report = ir_dry.analyze(ir, opts)

  local handle, open_err = io.open(report_path, "w")
  if handle == nil then
    return nil, "cannot write report: " .. tostring(open_err)
  end
  handle:write(json.encode(report))
  handle:close()
  return true
end

return ir_dry
