rockspec_format = "3.0"
package = "acceptance4lua"
version = "0.1.1-1"
source = {
   url = "git+http://lzxsvn:3000/qinyuanj/acceptance4lua.git",
   tag = "v0.1.1",
}
description = {
   summary = "Acceptance pipeline framework for Lua",
   detailed = [[
      acceptance4lua is a Lua implementation of the Acceptance Pipeline
      Specification. It provides a deterministic Gherkin subset parser,
      Chinese keyword normalization, JSON IR encoding/decoding, acceptance
      entry point generation, IR-DRY checking, and Gherkin mutation.
   ]],
   homepage = "http://lzxsvn:3000/qinyuanj/acceptance4lua",
   license = "MIT",
}
dependencies = {
   "lua >= 5.4",
}
test_dependencies = {
   "luaunit == 3.5-1",
}
build = {
   type = "builtin",
   modules = {
      ["acceptance4lua"] = "src/acceptance4lua/init.lua",
      ["acceptance4lua.chinese_normalizer"] = "src/acceptance4lua/chinese_normalizer.lua",
      ["acceptance4lua.feature_stamp"] = "src/acceptance4lua/feature_stamp.lua",
      ["acceptance4lua.generator"] = "src/acceptance4lua/generator.lua",
      ["acceptance4lua.gherkin_parser"] = "src/acceptance4lua/gherkin_parser.lua",
      ["acceptance4lua.harness"] = "src/acceptance4lua/harness.lua",
      ["acceptance4lua.ir_dry"] = "src/acceptance4lua/ir_dry.lua",
      ["acceptance4lua.json"] = "src/acceptance4lua/json.lua",
      ["acceptance4lua.mutator"] = "src/acceptance4lua/mutator.lua",
      ["acceptance4lua.runner"] = "src/acceptance4lua/runner.lua",
      ["acceptance4lua.runtime"] = "src/acceptance4lua/runtime.lua",
      ["acceptance4lua.scenario_manifest"] = "src/acceptance4lua/scenario_manifest.lua",
      ["acceptance4lua.source"] = "src/acceptance4lua/source.lua",
      ["acceptance4lua.spec_hash"] = "src/acceptance4lua/spec_hash.lua",
      ["acceptance4lua.table_shape"] = "src/acceptance4lua/table_shape.lua",
      ["acceptance4lua.cli.generator"] = "src/acceptance4lua/cli/generator.lua",
      ["acceptance4lua.cli.ir_dry"] = "src/acceptance4lua/cli/ir_dry.lua",
      ["acceptance4lua.cli.mutator"] = "src/acceptance4lua/cli/mutator.lua",
      ["acceptance4lua.cli.parser"] = "src/acceptance4lua/cli/parser.lua",
      ["acceptance4lua.mutator.engine"] = "src/acceptance4lua/mutator/engine.lua",
      ["acceptance4lua.mutator.report"] = "src/acceptance4lua/mutator/report.lua",
      ["acceptance4lua.mutator.status"] = "src/acceptance4lua/mutator/status.lua",
      ["acceptance4lua.runtime.common"] = "src/acceptance4lua/runtime/common.lua",
      ["acceptance4lua.runtime.parallel_lanes"] = "src/acceptance4lua/runtime/parallel_lanes.lua",
   },
}
