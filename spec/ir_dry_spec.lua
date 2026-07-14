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

describe("acceptance4lua.ir_dry", function()
  it("reports repeated step text inside one scenario", function()
    local report = ir_dry.analyze(_ir({
      _scenario("回合结束", {
        _step("Given", "游戏已初始化标准棋盘"),
        _step("When", "玩家点击结束按钮"),
        _step("Then", "玩家点击结束按钮"),
      }),
    }))

    local findings = _by_kind(report, "duplicate-in-scenario")
    assert.are.equal(1, #findings)
    assert.are.equal("玩家点击结束按钮", findings[1].members[1].text)
    assert.are.equal("high", findings[1].confidence)
    assert.are.equal(2, #findings[1].members[1].locations)
  end)

  it("does not report a step reused across separate scenarios by default", function()
    local report = ir_dry.analyze(_ir({
      _scenario("甲", { _step("Given", "游戏已初始化标准棋盘") }),
      _scenario("乙", { _step("Given", "游戏已初始化标准棋盘") }),
    }))

    assert.are.equal(0, #_by_kind(report, "duplicate-in-scenario"))
    assert.are.equal(0, #_by_kind(report, "exact-duplicate"))
  end)

  it("reports cross-IR exact duplicates only when include_exact is requested", function()
    local ir = _ir({
      _scenario("甲", { _step("Given", "游戏已初始化标准棋盘") }),
      _scenario("乙", { _step("Given", "游戏已初始化标准棋盘") }),
    })

    local findings = _by_kind(ir_dry.analyze(ir, { include_exact = true }), "exact-duplicate")
    assert.are.equal(1, #findings)
    assert.are.equal("游戏已初始化标准棋盘", findings[1].members[1].text)
    assert.are.equal(2, #findings[1].members[1].locations)
  end)

  it("reports placeholder variants that differ only by placeholder name", function()
    local report = ir_dry.analyze(_ir({
      _scenario("甲", { _step("Given", "玩家停在<起点>", { "起点" }) }),
      _scenario("乙", { _step("Then", "玩家停在<终点>", { "终点" }) }),
    }))

    local findings = _by_kind(report, "placeholder-variant")
    assert.are.equal(1, #findings)
    assert.same({ "玩家停在<终点>", "玩家停在<起点>" }, _member_texts(findings[1]))
    assert.are.equal("high", findings[1].confidence)
    assert.are.equal("玩家停在<value>", findings[1].canonical_candidate)
    assert.are.equal("^玩家停在(.+)$", findings[1].pattern_candidate)
  end)

  it("scores Chinese step similarity so unrelated steps sharing a placeholder are not findings", function()
    -- 这是 alphanumeric Jaccard 的假阳性来源:两条语义无关的中文 step 去掉
    -- 占位符后各自不剩 ASCII token,基线会判 score 1.0。CJK 分词后必须无 finding。
    local report = ir_dry.analyze(_ir({
      _scenario("甲", { _step("Given", "玩家掷出点数<点数>", { "点数" }) }),
      _scenario("乙", { _step("Then", "商店售价为<金额>", { "金额" }) }),
    }))

    assert.are.equal(0, #_by_kind(report, "near-duplicate"))
    assert.are.equal(0, #_by_kind(report, "possible-synonym"))
  end)

  it("reports genuinely similar Chinese steps as near duplicates", function()
    local report = ir_dry.analyze(_ir({
      _scenario("甲", { _step("Given", "当前轮到角色ID为<角色ID>", { "角色ID" }) }),
      _scenario("乙", { _step("Then", "当前轮到的角色ID为<角色ID>", { "角色ID" }) }),
    }))

    local findings = _by_kind(report, "near-duplicate")
    assert.are.equal(1, #findings)
    assert.are.equal("medium", findings[1].confidence)
    assert.is_true(findings[1].score >= 0.72)
    assert.same(
      { "当前轮到的角色ID为<角色ID>", "当前轮到角色ID为<角色ID>" },
      _member_texts(findings[1])
    )
  end)

  it("locates background steps as background and scenario steps as scenario", function()
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
    assert.are.equal(2, #findings)

    local sections = {}
    for _, finding in ipairs(findings) do
      for _, location in ipairs(finding.members[1].locations) do
        sections[location.section] = true
      end
    end
    assert.is_true(sections["background"])
    assert.is_true(sections["scenario"])
  end)

  it("summarizes occurrences, unique steps, and findings", function()
    local report = ir_dry.analyze(_ir({
      _scenario("甲", {
        _step("When", "玩家点击结束按钮"),
        _step("Then", "玩家点击结束按钮"),
        _step("Then", "结算面板已显示"),
      }),
    }))

    assert.are.equal(1, report.schema_version)
    assert.are.equal("结束按钮", report.feature_name)
    assert.are.equal(3, report.summary.step_occurrences)
    assert.are.equal(2, report.summary.unique_steps)
    assert.are.equal(#report.findings, report.summary.findings)
  end)

  it("exits 2 on wrong usage", function()
    assert.are.equal(2, cli.main({}))
    assert.are.equal(2, cli.main({ "only-one-arg" }))
  end)

  it("exits 1 when the IR cannot be read", function()
    assert.are.equal(1, cli.main({ "/nonexistent/ir.json", _tmp_path(".json") }))
  end)

  it("writes a JSON report and leaves the input IR untouched", function()
    local ir_path = _tmp_path(".json")
    local report_path = _tmp_path(".report.json")
    local ir_text = json.encode(_ir({
      _scenario("甲", {
        _step("When", "玩家点击结束按钮"),
        _step("Then", "玩家点击结束按钮"),
      }),
    }))
    _write(ir_path, ir_text)

    assert.are.equal(0, cli.main({ ir_path, report_path }))
    assert.are.equal(ir_text, _read(ir_path))

    local report = json.decode(_read(report_path))
    assert.are.equal(1, report.schema_version)
    assert.are.equal(1, #_by_kind(report, "duplicate-in-scenario"))

    os.remove(ir_path)
    os.remove(report_path)
  end)
end)
