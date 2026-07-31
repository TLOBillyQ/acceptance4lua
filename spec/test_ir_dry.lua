local lu = require("luaunit")
local ir_dry = require("acceptance4lua.ir_dry")
local cli = require("acceptance4lua.cli.ir_dry")
local json = require("acceptance4lua.json")

-- 造一条 step:文本 + 可选占位符名(与 parser 产出的 IR 同形)。
local function _step(keyword, text, parameters)
  return { keyword = keyword, text = text, parameters = parameters or {} }
end

local function _ir(scenarios, background)
  return {
    name = "结束按钮",
    background = background or {},
    scenarios = scenarios,
  }
end

local function _scenario(name, steps)
  return { name = name, steps = steps, examples = {} }
end

-- 取出某一 kind 的全部 finding。
local function _by_kind(report, kind)
  local hits = {}
  for _, finding in ipairs(report.findings) do
    if finding.kind == kind then
      hits[#hits + 1] = finding
    end
  end
  return hits
end

local function _member_texts(finding)
  local texts = {}
  for _, member in ipairs(finding.members) do
    texts[#texts + 1] = member.text
  end
  table.sort(texts)
  return texts
end

local function _tmp_path(suffix)
  return os.tmpname() .. (suffix or "")
end

local function _write(path, text)
  local handle = assert(io.open(path, "w"))
  handle:write(text)
  handle:close()
end

local function _read(path)
  local handle = assert(io.open(path, "r"))
  local text = handle:read("a")
  handle:close()
  return text
end

TestIrDry = {}

function TestIrDry:test_reports_repeated_step_text_inside_one_scenario()
  local report = ir_dry.analyze(_ir({
    _scenario("回合结束", {
      _step("Given", "游戏已初始化标准棋盘"),
      _step("When", "玩家点击结束按钮"),
      _step("Then", "玩家点击结束按钮"),
    }),
  }))

  local findings = _by_kind(report, "duplicate-in-scenario")
  lu.assertEquals(#findings, 1)
  lu.assertEquals(findings[1].members[1].text, "玩家点击结束按钮")
  lu.assertEquals(findings[1].confidence, "high")
  lu.assertEquals(#findings[1].members[1].locations, 2)
end

function TestIrDry:test_ignores_step_reused_across_scenarios_by_default()
  local report = ir_dry.analyze(_ir({
    _scenario("甲", { _step("Given", "游戏已初始化标准棋盘") }),
    _scenario("乙", { _step("Given", "游戏已初始化标准棋盘") }),
  }))

  lu.assertEquals(#_by_kind(report, "duplicate-in-scenario"), 0)
  lu.assertEquals(#_by_kind(report, "exact-duplicate"), 0)
end

function TestIrDry:test_reports_exact_duplicates_only_when_include_exact()
  local ir = _ir({
    _scenario("甲", { _step("Given", "游戏已初始化标准棋盘") }),
    _scenario("乙", { _step("Given", "游戏已初始化标准棋盘") }),
  })

  local findings = _by_kind(ir_dry.analyze(ir, { include_exact = true }), "exact-duplicate")
  lu.assertEquals(#findings, 1)
  lu.assertEquals(findings[1].members[1].text, "游戏已初始化标准棋盘")
  lu.assertEquals(#findings[1].members[1].locations, 2)
end

function TestIrDry:test_reports_placeholder_variants()
  local report = ir_dry.analyze(_ir({
    _scenario("甲", { _step("Given", "玩家停在<起点>", { "起点" }) }),
    _scenario("乙", { _step("Then", "玩家停在<终点>", { "终点" }) }),
  }))

  local findings = _by_kind(report, "placeholder-variant")
  lu.assertEquals(#findings, 1)
  lu.assertEquals(_member_texts(findings[1]), { "玩家停在<终点>", "玩家停在<起点>" })
  lu.assertEquals(findings[1].confidence, "high")
  lu.assertEquals(findings[1].canonical_candidate, "玩家停在<value>")
  lu.assertEquals(findings[1].pattern_candidate, "^玩家停在(.+)$")
end

function TestIrDry:test_unrelated_chinese_steps_sharing_placeholder_not_findings()
  -- 这是 alphanumeric Jaccard 的假阳性来源:两条语义无关的中文 step 去掉
  -- 占位符后各自不剩 ASCII token,基线会判 score 1.0。CJK 分词后必须无 finding。
  local report = ir_dry.analyze(_ir({
    _scenario("甲", { _step("Given", "玩家掷出点数<点数>", { "点数" }) }),
    _scenario("乙", { _step("Then", "商店售价为<金额>", { "金额" }) }),
  }))

  lu.assertEquals(#_by_kind(report, "near-duplicate"), 0)
  lu.assertEquals(#_by_kind(report, "possible-synonym"), 0)
end

function TestIrDry:test_reports_similar_chinese_steps_as_near_duplicates()
  local report = ir_dry.analyze(_ir({
    _scenario("甲", { _step("Given", "当前轮到角色ID为<角色ID>", { "角色ID" }) }),
    _scenario("乙", { _step("Then", "当前轮到的角色ID为<角色ID>", { "角色ID" }) }),
  }))

  local findings = _by_kind(report, "near-duplicate")
  lu.assertEquals(#findings, 1)
  lu.assertEquals(findings[1].confidence, "medium")
  lu.assertTrue(findings[1].score >= 0.72)
  lu.assertEquals(
    _member_texts(findings[1]),
    { "当前轮到的角色ID为<角色ID>", "当前轮到角色ID为<角色ID>" }
  )
end

function TestIrDry:test_locates_background_and_scenario_sections()
  local report = ir_dry.analyze(_ir({
    _scenario("甲", {
      _step("When", "玩家点击结束按钮"),
      _step("Then", "玩家点击结束按钮"),
    }),
  }, {
    _step("Given", "回合已开始"),
    _step("And", "回合已开始"),
  }))

  local findings = _by_kind(report, "duplicate-in-scenario")
  lu.assertEquals(#findings, 2)

  local sections = {}
  for _, finding in ipairs(findings) do
    for _, location in ipairs(finding.members[1].locations) do
      sections[location.section] = true
    end
  end
  lu.assertTrue(sections["background"])
  lu.assertTrue(sections["scenario"])
end

function TestIrDry:test_summarizes_occurrences_unique_steps_and_findings()
  local report = ir_dry.analyze(_ir({
    _scenario("甲", {
      _step("When", "玩家点击结束按钮"),
      _step("Then", "玩家点击结束按钮"),
      _step("Then", "结算面板已显示"),
    }),
  }))

  lu.assertEquals(report.schema_version, 1)
  lu.assertEquals(report.feature_name, "结束按钮")
  lu.assertEquals(report.summary.step_occurrences, 3)
  lu.assertEquals(report.summary.unique_steps, 2)
  lu.assertEquals(report.summary.findings, #report.findings)
end

function TestIrDry:test_exits_2_on_wrong_usage()
  lu.assertEquals(cli.main({}), 2)
  lu.assertEquals(cli.main({ "only-one-arg" }), 2)
end

function TestIrDry:test_exits_1_when_ir_cannot_be_read()
  lu.assertEquals(cli.main({ "/nonexistent/ir.json", _tmp_path(".json") }), 1)
end

function TestIrDry:test_writes_json_report_and_leaves_input_untouched()
  local ir_path = _tmp_path(".json")
  local report_path = _tmp_path(".report.json")
  local ir_text = json.encode(_ir({
    _scenario("甲", {
      _step("When", "玩家点击结束按钮"),
      _step("Then", "玩家点击结束按钮"),
    }),
  }))
  _write(ir_path, ir_text)

  lu.assertEquals(cli.main({ ir_path, report_path }), 0)
  lu.assertEquals(_read(ir_path), ir_text)

  local report = json.decode(_read(report_path))
  lu.assertEquals(report.schema_version, 1)
  lu.assertEquals(#_by_kind(report, "duplicate-in-scenario"), 1)

  os.remove(ir_path)
  os.remove(report_path)
end

return TestIrDry
