# acceptance4lua

`acceptance4lua` is a pure-Lua acceptance pipeline framework modeled after
`unclebob/Acceptance-Pipeline-Specification`.

It provides:

- a deterministic Gherkin subset parser;
- a Chinese `# language: zh-CN` normalizer for the supported keyword set;
- JSON IR encoding and decoding;
- a thin standalone acceptance entrypoint generator (self-contained harness,
  no external test framework needed);
- a report-only IR-DRY checker with CJK-aware similarity scoring;
- a runtime that dispatches exact step text to project step handlers;
- Gherkin example-value mutation with feature stamps, scenario manifests,
  generated-file implementation hashes, runner-worker integration, and status
  reporting.

Project-specific code remains outside this package. Hosts provide step
handlers, runner adapters, command wrappers, and any application fixtures; see
"Adopting In A New Project" below.

## Layout

```text
lib/acceptance4lua/
  cli/                 command modules
  mutator/             mutation engine, reports, status lines
  runtime/             small portable runtime helpers
  *.lua                parser, generator, runtime, source maps, hashes
```

## Generated Specs

Generated entrypoints are standalone Lua scripts. They default to the portable
framework modules and a neutral host step module name:

```lua
require("acceptance4lua.harness")
require("acceptance4lua.runtime")
require("steps")
require("acceptance4lua.json")
```

The generator accepts module-name overrides for hosts with different
namespaces: pass `steps_module` (and optionally `runtime_module`,
`json_module`, `harness_module`) via `generator.generate(ir, opts)` /
`generator.generate_file(json, out, opts)`, or `--steps-module <name>` on the
`acceptance-entrypoint-generator` CLI.

Run a generated entrypoint with any Lua interpreter; `LUA_PATH` must cover the
framework and host modules (the runner sets it for you, and honors the
`ACCEPTANCE_LUA_BIN` / `ACCEPTANCE_LUA_PATH` overrides):

```sh
LUA_PATH='lib/?.lua;lib/?/init.lua;;' lua path/to/generated_spec.lua
```

## Adopting In A New Project (eggy)

A host project wires the pipeline like this (using a fictional project `eggy`
as the example):

1. Lay out step handlers as a plain Lua module returning
   `{ handlers = function() return { ["step text"] = function(world, example) ... end, ... } end }`.
   The generated entrypoint requires `steps` by default, so `eggy/steps.lua`
   works out of the box; for a nested namespace such as `eggy.steps`, pass
   `steps_module = "eggy.steps"` to the generator (and to the mutator, which
   regenerates entrypoints internally).
2. Parse and generate:
   `require("acceptance4lua.gherkin_parser").write_json_file("features/x.feature", "build/x.json")`
   then
   `require("acceptance4lua.generator").generate_file("build/x.json", "build/x_spec.lua", { steps_module = "eggy.steps" })`.
3. Run specs through the runner (`acceptance4lua.runner.run_generated`) or
   plain `lua`, with `LUA_PATH` covering both `acceptance4lua` and the host
   step module.
4. Mutate:
   `require("acceptance4lua.mutator").run({ feature = "features/x.feature", steps_module = "eggy.steps", ... })`,
   or the CLI `gherkin-mutator --feature <path> --runner-worker <cmd>
   [--steps-module <name>]`. `--feature` is required; there is no built-in
   default path.
5. Feature files under `features/` must start with `# language: zh-CN`. Hosts
   keeping features elsewhere can pass
   `mandatory_language_dirs = { "<dir>" }` to
   `chinese_normalizer.normalize_text` / `gherkin_parser.parse_file` (empty
   table disables the rule).

### Compatibility Notes

- The default generated step module changed from `acceptance.steps` to
  `steps`. Hosts relying on the old implicit default must pass
  `steps_module = "acceptance.steps"` explicitly.
- `gherkin-mutator` no longer defaults `--feature` to a placeholder path;
  the option is now required (any real caller already passed it).

## Upstream Alignment (对齐上游)

`acceptance4lua` follows the "Lua faithful implementation of the upstream
spec" doctrine: behavior that is identical across upstream implementations is
copied verbatim; anything different is a deliberate deviation, recorded here
with its reason. Cross-repo decisions live as ADRs in the luatools notes repo
(`projects/luatools/docs/adr/`).

**Aligned invariants (对齐不变量)**

- Command names and shapes (`gherkin-parser`, `acceptance-entrypoint-generator`,
  `gherkin-ir-dry-checker`, `gherkin-mutator`) and the exit-code convention
  (0 success / 1 runtime error / 2 usage error).
- JSON IR structure and the runner-adapter protocol defined by APS.
- IR-DRY checker is report-only; it never rewrites features, IR, or generated
  files.

**Deliberate deviations (有意偏离)**

- Chinese `# language: zh-CN` keyword normalization — APS explicitly does not
  support localized keywords; required by the host project's Chinese features.
- CJK-aware similarity scoring (function-word dropping + Han-bigram Jaccard)
  — the portable alphanumeric baseline scores unrelated Chinese steps at 1.0;
  APS permits better language-neutral heuristics.
- Exact dictionary matching for step text (APS recommends regex/placeholder
  matching) — determinism and clearer error messages for the host.
- Bundled minimal busted-like harness — generated entrypoints must run on
  hosts with no test framework installed.
- Extra `--skip-columns` / `--verbose` options and the Lua subprocess fallback
  when no `--runner-worker` is given.
- Extra IR metadata (`source_path`, `source_line`, `field_names`) for error
  localization and mutation reports.

## Tests

The test suite runs on a self-contained minimal harness (`spec/harness.lua`)
that provides the busted-style `describe`/`it`/`assert` API, so no external
test dependency is needed:

```sh
lua spec/run.lua
```

## Relationship To APS

The command shapes remain APS-compatible:

```text
gherkin-parser <feature-file> <json-output>
acceptance-entrypoint-generator <json-ir> <generated-test-output>
gherkin-ir-dry-checker [--include-exact] <json-ir> <report-output>
gherkin-mutator [options]
```

The IR-DRY checker is report-only: it reads one JSON IR file and writes an
advisory JSON report. It never rewrites feature files, IR, generated
entrypoints, or project implementation files.

Its exact-match categories (`duplicate-in-scenario`, `exact-duplicate`,
`placeholder-variant`) keep the portable APS semantics. Similarity scoring
deviates from the portable alphanumeric baseline, which APS permits
("implementations may add better language-neutral heuristics"): Chinese step
text yields no alphanumeric tokens once placeholders are removed, so the
baseline scores unrelated Chinese steps at 1.0. This implementation drops
function words and then scores Jaccard similarity over Han bigrams, so findings
on CJK step text are meaningful.

`acceptance4lua` intentionally supports only the deterministic subset needed by
the host project. Unsupported Gherkin syntax should fail clearly instead of
being silently ignored.
