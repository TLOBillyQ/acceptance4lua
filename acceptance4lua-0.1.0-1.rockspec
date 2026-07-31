rockspec_format = "3.0"
package = "acceptance4lua"
version = "0.1.0-1"
source = {
   url = "git+http://lzxsvn:3000/qinyuanj/acceptance4lua.git",
   tag = "v0.1.0",
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
      ["acceptance4lua"] = "lib/acceptance4lua/init.lua",
      ["acceptance4lua.chinese_normalizer"] = "lib/acceptance4lua/chinese_normalizer.lua",
      ["acceptance4lua.feature_stamp"] = "lib/acceptance4lua/feature_stamp.lua",
      ["acceptance4lua.generator"] = "lib/acceptance4lua/generator.lua",
      ["acceptance4lua.gherkin_parser"] = "lib/acceptance4lua/gherkin_parser.lua",
      ["acceptance4lua.harness"] = "lib/acceptance4lua/harness.lua",
      ["acceptance4lua.ir_dry"] = "lib/acceptance4lua/ir_dry.lua",
      ["acceptance4lua.json"] = "lib/acceptance4lua/json.lua",
      ["acceptance4lua.mutator"] = "lib/acceptance4lua/mutator.lua",
      ["acceptance4lua.runner"] = "lib/acceptance4lua/runner.lua",
      ["acceptance4lua.runtime"] = "lib/acceptance4lua/runtime.lua",
      ["acceptance4lua.scenario_manifest"] = "lib/acceptance4lua/scenario_manifest.lua",
      ["acceptance4lua.source"] = "lib/acceptance4lua/source.lua",
      ["acceptance4lua.spec_hash"] = "lib/acceptance4lua/spec_hash.lua",
      ["acceptance4lua.table_shape"] = "lib/acceptance4lua/table_shape.lua",
      ["acceptance4lua.cli.generator"] = "lib/acceptance4lua/cli/generator.lua",
      ["acceptance4lua.cli.ir_dry"] = "lib/acceptance4lua/cli/ir_dry.lua",
      ["acceptance4lua.cli.mutator"] = "lib/acceptance4lua/cli/mutator.lua",
      ["acceptance4lua.cli.parser"] = "lib/acceptance4lua/cli/parser.lua",
      ["acceptance4lua.mutator.engine"] = "lib/acceptance4lua/mutator/engine.lua",
      ["acceptance4lua.mutator.report"] = "lib/acceptance4lua/mutator/report.lua",
      ["acceptance4lua.mutator.status"] = "lib/acceptance4lua/mutator/status.lua",
      ["acceptance4lua.runtime.common"] = "lib/acceptance4lua/runtime/common.lua",
      ["acceptance4lua.runtime.parallel_lanes"] = "lib/acceptance4lua/runtime/parallel_lanes.lua",
   },
}
