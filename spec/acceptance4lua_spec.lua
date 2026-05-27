local parser = require("acceptance4lua.gherkin_parser")
local generator = require("acceptance4lua.generator")
local normalizer = require("acceptance4lua.chinese_normalizer")
local mutator = require("acceptance4lua.mutator")
local runtime = require("acceptance4lua.runtime")
local common = require("acceptance4lua.runtime.common")

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
