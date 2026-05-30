local parser = require("acceptance4lua.gherkin_parser")
local generator = require("acceptance4lua.generator")
local normalizer = require("acceptance4lua.chinese_normalizer")
local mutator = require("acceptance4lua.mutator")
local engine = require("acceptance4lua.mutator.engine")
local runtime = require("acceptance4lua.runtime")
local common = require("acceptance4lua.runtime.common")

-- 校验字符串是否为合法 UTF-8（Lua 5.4 的 utf8.len 在非法字节处返回 nil）。
local function _is_valid_utf8(text)
  return utf8.len(text) ~= nil
end

-- 统计两串逐字节差异个数（用于钉住 ASCII 路径"仅扰动一个字符"的旧行为）。
local function _byte_diff_count(a, b)
  if #a ~= #b then
    return -1
  end
  local count = 0
  for index = 1, #a do
    if a:byte(index) ~= b:byte(index) then
      count = count + 1
    end
  end
  return count
end

local function _feature()
  return table.concat({
    "Feature: integer parsing",
    "",
    "Background:",
    "  Given handlers are loaded",
    "",
    "Scenario Outline: parse text",
    "  Given a text value <raw>",
    "  When it is parsed",
    "  Then the result is <result>",
    "",
    "Examples:",
    "  | raw | result |",
    "  | 12  | 12     |",
    "",
  }, "\n")
end

describe("acceptance4lua", function()
  it("parses the supported APS Gherkin subset", function()
    local ir = assert(parser.parse_text(_feature()))

    assert.are.equal("integer parsing", ir.name)
    assert.are.equal("handlers are loaded", ir.background[1].text)
    assert.are.equal("parse text", ir.scenarios[1].name)
    assert.same({ "raw" }, ir.scenarios[1].steps[1].parameters)
    assert.same({ raw = "12", result = "12" }, ir.scenarios[1].examples[1])
  end)

  it("normalizes the project-supported Chinese keyword set", function()
    local normalized = assert(normalizer.normalize_text(table.concat({
      "# language: zh-CN",
      "功能: 中文规格",
      "场景大纲: 中文场景",
      "  假如 文本为<原始文本>",
      "  那么 结果为<结果>",
      "例子:",
      "  | 原始文本 | 结果 |",
      "  | 12       | 12   |",
    }, "\n"), {
      path = "features/sample.feature",
    }))

    assert.is_truthy(normalized.text:find("Feature: 中文规格", 1, true))
    assert.is_truthy(normalized.text:find("Scenario Outline: 中文场景", 1, true))
    assert.is_truthy(normalized.text:find("Given 文本为<原始文本>", 1, true))
    assert.same({ ["原始文本"] = "原始文本", ["结果"] = "结果" }, normalized.source_map.field_names)
  end)

  it("dithers Chinese example values into valid UTF-8 without tearing characters", function()
    local inputs = { "购买", "购买道具", "更换座驾卡", "道具x3", "已有数量" }
    for _, original in ipairs(inputs) do
      for variant = 1, 6 do
        local path = "$.scenarios[0].examples[0].field" .. tostring(variant)
        local mutated = engine.mutate_value(original, path)
        assert.are_not.equal(original, mutated, "expected a real mutation for " .. original)
        assert.is_true(_is_valid_utf8(mutated), "mutation produced invalid UTF-8: " .. mutated)
      end
    end
  end)

  it("keeps the legacy single-character dither behavior for ASCII strings", function()
    -- 非数值/非关键字的纯 ASCII 串走 _dither_string；按字符索引==按字节索引，
    -- 仍应等长且只改动一个字符，与历史实现一致。
    local mutated = engine.mutate_value("abcdef", "$.scenarios[0].examples[0].slug")
    assert.are_not.equal("abcdef", mutated)
    assert.are.equal(1, _byte_diff_count("abcdef", mutated))
    assert.is_true(_is_valid_utf8(mutated))
  end)

  it("strips a UTF-8 BOM before detecting the language marker", function()
    local bom = "\239\187\191"
    local normalized = assert(normalizer.normalize_text(table.concat({
      bom .. "# language: zh-CN",
      "功能: 带BOM的规格",
      "场景: 普通场景",
      "  假如 文本为<原始文本>",
    }, "\n"), {
      path = "features/bom.feature",
    }))

    assert.is_truthy(normalized.text:find("Feature: 带BOM的规格", 1, true))
    assert.is_truthy(normalized.text:find("Scenario: 普通场景", 1, true))
  end)

  it("generates deterministic busted entrypoints using framework modules by default", function()
    local ir = assert(parser.parse_text(_feature()))
    local first = generator.generate(ir)
    local second = generator.generate(ir)

    assert.are.equal(first, second)
    assert.is_truthy(first:find('require("acceptance4lua.runtime")', 1, true))
    assert.is_truthy(first:find('require("acceptance.steps")', 1, true))
    assert.is_truthy(first:find('require("acceptance4lua.json")', 1, true))
    assert.is_truthy(first:find('ACCEPTANCE_FEATURE_JSON', 1, true))
  end)

  it("runs exact text step handlers through the runtime", function()
    local ir = assert(parser.parse_text(_feature()))
    local handlers = {
      ["handlers are loaded"] = function(world)
        world.loaded = true
      end,
      ["a text value <raw>"] = function(world, example)
        world.raw = example.raw
      end,
      ["it is parsed"] = function(world)
        world.result = tonumber(world.raw)
      end,
      ["the result is <result>"] = function(world, example)
        assert.is_true(world.loaded)
        assert.are.equal(tonumber(example.result), world.result)
      end,
    }

    local result = runtime.run_feature(ir, handlers)
    assert.is_true(result.ok, runtime.format_failures(result))
  end)

  it("builds deterministic Gherkin example mutations", function()
    local ir = assert(parser.parse_text(_feature()))
    local mutations = mutator.build_mutations(ir)

    assert.are.equal(2, #mutations)
    assert.are.equal("m1", mutations[1].id)
    assert.are.equal("$.scenarios[0].examples[0].raw", mutations[1].path)
    assert.are_not.equal(mutations[1].original, mutations[1].mutated)
  end)

  it("does not rewrite a feature when differential mutation skips every scenario", function()
    local original_runner = package.loaded["acceptance4lua.runner"]
    local original_mutator = package.loaded["acceptance4lua.mutator"]
    package.loaded["acceptance4lua.runner"] = {
      is_infrastructure_error = function()
        return false
      end,
      run_generated = function()
        return {
          passed = false,
          output = "",
          error = "",
          duration = 0,
        }
      end,
    }
    package.loaded["acceptance4lua.mutator"] = nil

    local isolated_mutator = require("acceptance4lua.mutator")
    local tmp_root = common.make_temp_path("acceptance4lua_mutator_idempotent_", "")
    common.remove_path(tmp_root)
    assert(common.ensure_dir(tmp_root))
    local feature_path = tmp_root .. "/a.feature"
    assert(common.write_file(feature_path, _feature()))

    local ok, err = xpcall(function()
      assert(isolated_mutator.run({
        feature = feature_path,
        work_dir = tmp_root .. "/work1",
        level = "hard",
      }))
      local first_content = assert(common.read_file(feature_path))

      local second = assert(isolated_mutator.run({
        feature = feature_path,
        work_dir = tmp_root .. "/work2",
        level = "hard",
      }))
      local second_content = assert(common.read_file(feature_path))

      assert.are.equal(1, second.summary.skipped_scenarios)
      assert.are.equal(0, second.summary.total)
      assert.are.equal(first_content, second_content)
    end, debug.traceback)

    common.remove_path(tmp_root)
    package.loaded["acceptance4lua.runner"] = original_runner
    package.loaded["acceptance4lua.mutator"] = original_mutator
    if not ok then
      error(err)
    end
  end)
end)
