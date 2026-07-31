local lu = require("luaunit")
local parser = require("acceptance4lua.gherkin_parser")
local generator = require("acceptance4lua.generator")
local normalizer = require("acceptance4lua.chinese_normalizer")
local mutator = require("acceptance4lua.mutator")
local cli_mutator = require("acceptance4lua.cli.mutator")
local engine = require("acceptance4lua.mutator.engine")
local runtime = require("acceptance4lua.runtime")
local runner = require("acceptance4lua.runner")
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

TestAcceptance4lua = {}

function TestAcceptance4lua:test_parses_supported_aps_gherkin_subset()
  local ir = assert(parser.parse_text(_feature()))

  lu.assertEquals(ir.name, "integer parsing")
  lu.assertEquals(ir.background[1].text, "handlers are loaded")
  lu.assertEquals(ir.scenarios[1].name, "parse text")
  lu.assertEquals(ir.scenarios[1].steps[1].parameters, { "raw" })
  lu.assertEquals(ir.scenarios[1].examples[1], { raw = "12", result = "12" })
end

function TestAcceptance4lua:test_second_examples_block_merges_like_upstream()
  -- 上游（Go parser.go / bb gherkin.clj）语义：同场景第二个 Examples 静默合并——
  -- 已解析的行保留，新块行追加到同一列表（issue#1 决策：沿用上游）。
  local ir = assert(parser.parse_text(table.concat({
    "Feature: merge",
    "Scenario Outline: s",
    "  Given x <a>",
    "Examples:",
    "  | a |",
    "  | 1 |",
    "Examples:",
    "  | a |",
    "  | 2 |",
    "  | 3 |",
  }, "\n")))

  lu.assertEquals(#ir.scenarios[1].examples, 3)
  lu.assertEquals(ir.scenarios[1].examples[1], { a = "1" })
  lu.assertEquals(ir.scenarios[1].examples[3], { a = "3" })
end

function TestAcceptance4lua:test_step_after_examples_appends_like_upstream()
  -- 上游语义：Examples 后的 step 行静默追加到场景步骤（issue#1 决策：沿用上游）。
  local ir = assert(parser.parse_text(table.concat({
    "Feature: trailing step",
    "Scenario Outline: s",
    "  Given x <a>",
    "Examples:",
    "  | a |",
    "  | 1 |",
    "  Then y",
  }, "\n")))

  lu.assertEquals(#ir.scenarios[1].steps, 2)
  lu.assertEquals(ir.scenarios[1].steps[2].text, "y")
  lu.assertEquals(#ir.scenarios[1].examples, 1)
end

function TestAcceptance4lua:test_normalizes_supported_chinese_keyword_set()
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

  lu.assertNotNil(normalized.text:find("Feature: 中文规格", 1, true))
  lu.assertNotNil(normalized.text:find("Scenario Outline: 中文场景", 1, true))
  lu.assertNotNil(normalized.text:find("Given 文本为<原始文本>", 1, true))
  lu.assertEquals(normalized.source_map.field_names, { ["原始文本"] = "原始文本", ["结果"] = "结果" })
end

function TestAcceptance4lua:test_dithers_chinese_values_into_valid_utf8()
  local inputs = { "购买", "购买道具", "更换座驾卡", "道具x3", "已有数量" }
  for _, original in ipairs(inputs) do
    for variant = 1, 6 do
      local path = "$.scenarios[0].examples[0].field" .. tostring(variant)
      local mutated = engine.mutate_value(original, path)
      lu.assertNotEquals(mutated, original, "expected a real mutation for " .. original)
      lu.assertTrue(_is_valid_utf8(mutated), "mutation produced invalid UTF-8: " .. mutated)
    end
  end
end

function TestAcceptance4lua:test_keeps_legacy_single_char_dither_for_ascii()
  -- 非数值/非关键字的纯 ASCII 串走 _dither_string；按字符索引==按字节索引，
  -- 仍应等长且只改动一个字符，与历史实现一致。
  local mutated = engine.mutate_value("abcdef", "$.scenarios[0].examples[0].slug")
  lu.assertNotEquals(mutated, "abcdef")
  lu.assertEquals(_byte_diff_count("abcdef", mutated), 1)
  lu.assertTrue(_is_valid_utf8(mutated))
end

function TestAcceptance4lua:test_strips_utf8_bom_before_language_marker()
  local bom = "\239\187\191"
  local normalized = assert(normalizer.normalize_text(table.concat({
    bom .. "# language: zh-CN",
    "功能: 带BOM的规格",
    "场景: 普通场景",
    "  假如 文本为<原始文本>",
  }, "\n"), {
    path = "features/bom.feature",
  }))

  lu.assertNotNil(normalized.text:find("Feature: 带BOM的规格", 1, true))
  lu.assertNotNil(normalized.text:find("Scenario: 普通场景", 1, true))
end

function TestAcceptance4lua:test_mandatory_language_marker_dirs_configurable()
  local english = "Feature: plain\nScenario: s\n  Given x\n"

  -- 默认规则：features/ 下必须声明语言；其他目录不要求。
  local rejected, err = normalizer.normalize_text(english, { path = "features/a.feature" })
  lu.assertNil(rejected)
  lu.assertNotNil(tostring(err):find("# language: zh-CN", 1, true))
  lu.assertNotNil(normalizer.normalize_text(english, { path = "specs/a.feature" }))

  -- 宿主可换用自己的目录名；空表则完全关闭该规则。
  local custom, custom_err = normalizer.normalize_text(english, {
    path = "specs/a.feature",
    mandatory_language_dirs = { "specs" },
  })
  lu.assertNil(custom)
  lu.assertNotNil(tostring(custom_err):find("specs/", 1, true))
  lu.assertNotNil(normalizer.normalize_text(english, {
    path = "features/a.feature",
    mandatory_language_dirs = {},
  }))
end

function TestAcceptance4lua:test_generates_deterministic_entrypoints_with_defaults()
  local ir = assert(parser.parse_text(_feature()))
  local first = generator.generate(ir)
  local second = generator.generate(ir)

  lu.assertEquals(second, first)
  lu.assertNotNil(first:find('require("acceptance4lua.harness")', 1, true))
  lu.assertNotNil(first:find('require("acceptance4lua.runtime")', 1, true))
  lu.assertNotNil(first:find('require("steps")', 1, true))
  lu.assertNotNil(first:find('require("acceptance4lua.json")', 1, true))
  lu.assertNotNil(first:find('ACCEPTANCE_FEATURE_JSON', 1, true))
  lu.assertNotNil(first:find('runtime.define_specs(ir, steps.handlers(), it)', 1, true))
  lu.assertNotNil(first:find('os.exit(harness.run() and 0 or 1)', 1, true))
end

function TestAcceptance4lua:test_host_can_override_step_module_name()
  local ir = assert(parser.parse_text(_feature()))
  local generated = generator.generate(ir, { steps_module = "eggy.steps" })

  lu.assertNotNil(generated:find('require("eggy.steps")', 1, true))
  lu.assertNil(generated:find('require("steps")', 1, true))
end

function TestAcceptance4lua:test_metadata_name_disambiguates_colliding_slugs()
  -- a_b.feature 与 a/b.feature 映射到同一 slug，路径短哈希使 metadata 文件名
  -- 不再互相覆盖（issue#2）；同一输入保持确定性。
  local first = generator.metadata_path_for("build/out_spec.lua", "a_b.feature")
  local second = generator.metadata_path_for("build/out_spec.lua", "a/b.feature")

  lu.assertNotEquals(second, first)
  lu.assertEquals(generator.metadata_path_for("build/out_spec.lua", "a_b.feature"), first)
  lu.assertNotNil(first:find("^build/metadata/a%-b%-feature%-%x%x%x%x%x%x%x%x%.json$"))

  -- 路径分隔符归一化：Windows 风格反斜杠与正斜杠得到同一名称。
  lu.assertEquals(generator.metadata_path_for("build/out_spec.lua", "a\\b.feature"), second)
end

function TestAcceptance4lua:test_runs_generated_entrypoint_end_to_end()
  local ir = assert(parser.parse_text(_feature()))
  local tmp_root = common.make_temp_path("acceptance4lua_runner_e2e_", "")
  common.remove_path(tmp_root)
  assert(common.ensure_dir(tmp_root))

  local generated_path = tmp_root .. "/generated_spec.lua"
  assert(common.write_file(generated_path, generator.generate(ir)))

  -- 宿主提供的 step handlers：生成的入口默认 require("steps")。
  local function _write_steps(handlers_body)
    assert(common.write_file(tmp_root .. "/steps.lua", table.concat({
      "return {",
      "  handlers = function()",
      "    return {",
      handlers_body,
      "    }",
      "  end,",
      "}",
    }, "\n")))
  end

  local lua_path = "lib/?.lua;lib/?/init.lua;" .. tmp_root .. "/?.lua;;"
  local ok, err = xpcall(function()
    _write_steps([[
      ["handlers are loaded"] = function(world) world.loaded = true end,
      ["a text value <raw>"] = function(world, example) world.raw = example.raw end,
      ["it is parsed"] = function(world) world.result = tonumber(world.raw) end,
      ["the result is <result>"] = function(world, example)
        assert(world.loaded)
        assert(tonumber(example.result) == world.result, "result mismatch")
      end,
]])
    local passing = runner.run_generated(generated_path, { lua_path = lua_path })
    lu.assertEquals(passing.error, "")
    lu.assertTrue(passing.passed, passing.output)
    -- duration 为 wall clock（os.time 秒级，issue#3），非负数即可，不断言具体值。
    lu.assertTrue(passing.duration >= 0)
    lu.assertEquals(passing.duration % 1, 0)

    _write_steps([[
      ["handlers are loaded"] = function(world) world.loaded = true end,
      ["a text value <raw>"] = function(world, example) world.raw = example.raw end,
      ["it is parsed"] = function(world) world.result = -1 end,
      ["the result is <result>"] = function(world, example)
        assert(tonumber(example.result) == world.result, "result mismatch")
      end,
]])
    local failing = runner.run_generated(generated_path, { lua_path = lua_path })
    lu.assertEquals(failing.error, "")
    lu.assertTrue(not failing.passed)
    lu.assertNotNil(failing.output:find("result mismatch", 1, true))
  end, debug.traceback)

  common.remove_path(tmp_root)
  if not ok then
    error(err)
  end
end

function TestAcceptance4lua:test_runs_exact_text_step_handlers_through_runtime()
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
      lu.assertTrue(world.loaded)
      lu.assertEquals(world.result, tonumber(example.result))
    end,
  }

  local result = runtime.run_feature(ir, handlers)
  lu.assertTrue(result.ok, runtime.format_failures(result))
end

function TestAcceptance4lua:test_builds_deterministic_mutations()
  local ir = assert(parser.parse_text(_feature()))
  local mutations = mutator.build_mutations(ir)

  lu.assertEquals(#mutations, 2)
  lu.assertEquals(mutations[1].id, "m1")
  lu.assertEquals(mutations[1].path, "$.scenarios[0].examples[0].raw")
  lu.assertNotEquals(mutations[1].mutated, mutations[1].original)
end

function TestAcceptance4lua:test_skips_columns_named_by_filter()
  local ir = assert(parser.parse_text(_feature()))
  local mutations = mutator.build_mutations(ir, { skip_columns = { result = true } })

  lu.assertEquals(#mutations, 1)
  lu.assertEquals(mutations[1].path, "$.scenarios[0].examples[0].raw")
  lu.assertEquals(mutations[1].key, "raw")
end

function TestAcceptance4lua:test_mutation_ids_and_paths_stable()
  local ir = assert(parser.parse_text(_feature()))
  local opts = { skip_columns = { result = true } }
  local first = mutator.build_mutations(ir, opts)
  local second = mutator.build_mutations(ir, opts)

  lu.assertEquals(#second, #first)
  for index = 1, #first do
    lu.assertEquals(second[index].id, first[index].id)
    lu.assertEquals(second[index].path, first[index].path)
    lu.assertEquals(second[index].mutated, first[index].mutated)
  end
end

function TestAcceptance4lua:test_same_mutations_without_skip_filter()
  local ir = assert(parser.parse_text(_feature()))
  local plain = mutator.build_mutations(ir)
  local empty_opts = mutator.build_mutations(ir, {})
  local empty_filter = mutator.build_mutations(ir, { skip_columns = {} })

  lu.assertEquals(#empty_opts, #plain)
  lu.assertEquals(#empty_filter, #plain)
  for index = 1, #plain do
    lu.assertEquals(empty_opts[index].id, plain[index].id)
    lu.assertEquals(empty_opts[index].path, plain[index].path)
    lu.assertEquals(empty_filter[index].id, plain[index].id)
    lu.assertEquals(empty_filter[index].path, plain[index].path)
  end
end

function TestAcceptance4lua:test_parses_skip_columns_into_exact_match_set()
  local options = assert(cli_mutator.parse_args({
    "--feature", "features/x.feature",
    "--runner-worker", "true",
    "--skip-columns", "角色ID, 观察角色ID ,,",
  }))

  lu.assertEquals(options.skip_columns, { ["角色ID"] = true, ["观察角色ID"] = true })

  local missing, err = cli_mutator.parse_args({ "--skip-columns" })
  lu.assertNil(missing)
  lu.assertNotNil(err)

  local without = assert(cli_mutator.parse_args({
    "--feature", "features/x.feature",
    "--runner-worker", "true",
  }))
  lu.assertNil(without.skip_columns)
end

function TestAcceptance4lua:test_workers_numeric_boundaries_follow_upstream_clamp()
  -- 数值边界沿用上游 APS clamp 语义（issue#4 决策）：CLI 层不拒绝非正数，
  -- 由 mutator.run 的 math.max(1, ...) 兜底；非数值仍在 CLI 层报错。
  local parsed = assert(cli_mutator.parse_args({
    "--feature", "features/x.feature",
    "--runner-worker", "true",
    "--workers", "0",
  }))
  lu.assertEquals(parsed.workers, 0)

  local invalid, err = cli_mutator.parse_args({
    "--feature", "features/x.feature",
    "--runner-worker", "true",
    "--workers", "abc",
  })
  lu.assertNil(invalid)
  lu.assertNotNil(tostring(err):find("invalid workers", 1, true))
end

function TestAcceptance4lua:test_requires_feature_flag()
  local options, err = cli_mutator.parse_args({ "--runner-worker", "true" })
  lu.assertNil(options)
  lu.assertNotNil(err)

  local parsed = assert(cli_mutator.parse_args({
    "--feature", "specs/order.feature",
    "--runner-worker", "true",
    "--steps-module", "eggy.steps",
  }))
  lu.assertEquals(parsed.feature, "specs/order.feature")
  lu.assertEquals(parsed.steps_module, "eggy.steps")
end

function TestAcceptance4lua:test_mutator_run_requires_feature()
  local result, err = mutator.run({ level = "hard" })
  lu.assertNil(result)
  lu.assertEquals(err, "feature is required")
end

function TestAcceptance4lua:test_does_not_rewrite_when_all_skipped()
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

    lu.assertEquals(second.summary.skipped_scenarios, 1)
    lu.assertEquals(second.summary.total, 0)
    lu.assertEquals(second_content, first_content)
  end, debug.traceback)

  common.remove_path(tmp_root)
  package.loaded["acceptance4lua.runner"] = original_runner
  package.loaded["acceptance4lua.mutator"] = original_mutator
  if not ok then
    error(err)
  end
end

return TestAcceptance4lua
