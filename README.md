# acceptance4lua

`acceptance4lua` is a pure-Lua acceptance pipeline framework modeled after
`unclebob/Acceptance-Pipeline-Specification`.

It provides:

- a deterministic Gherkin subset parser;
- a Chinese `# language: zh-CN` normalizer for the supported keyword set;
- JSON IR encoding and decoding;
- a thin busted entrypoint generator;
- a report-only IR-DRY checker with CJK-aware similarity scoring;
- a runtime that dispatches exact step text to project step handlers;
- Gherkin example-value mutation with feature stamps, scenario manifests,
  generated-file implementation hashes, runner-worker integration, and status
  reporting.

Project-specific code remains outside this package. Hosts should provide step
handlers, runner adapters, command wrappers, and any application fixtures.

## Layout

```text
lib/acceptance4lua/
  cli/                 command modules
  mutator/             mutation engine, reports, status lines
  runtime/             small portable runtime helpers
  *.lua                parser, generator, runtime, source maps, hashes
```

## Generated Specs

Generated busted specs default to the portable framework modules and the
host-provided step namespace:

```lua
require("acceptance4lua.runtime")
require("acceptance.steps")
require("acceptance4lua.json")
```

This lets a host keep project step handlers under `acceptance.steps` while the
portable framework lives directly under `acceptance4lua.*`. The generator also
accepts module-name overrides for hosts with different namespaces.

## Tests

```sh
busted
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
