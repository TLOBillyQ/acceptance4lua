# acceptance4lua

`acceptance4lua` is a pure-Lua acceptance pipeline framework modeled after
`unclebob/Acceptance-Pipeline-Specification`.

It provides:

- a deterministic Gherkin subset parser;
- a Chinese `# language: zh-CN` normalizer for the supported keyword set;
- JSON IR encoding and decoding;
- a thin busted entrypoint generator;
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

## Host Facade

Generated busted specs default to the historical facade modules:

```lua
require("acceptance.runtime")
require("acceptance.steps")
require("acceptance.json")
```

This lets a host keep project step handlers under `acceptance.steps` while the
portable framework lives under `acceptance4lua.*`. The generator also accepts
module-name overrides for hosts that do not want a facade.

## Tests

```sh
busted
```

## Relationship To APS

The command shapes remain APS-compatible:

```text
gherkin-parser <feature-file> <json-output>
acceptance-entrypoint-generator <json-ir> <generated-test-output>
gherkin-mutator [options]
```

`acceptance4lua` intentionally supports only the deterministic subset needed by
the host project. Unsupported Gherkin syntax should fail clearly instead of
being silently ignored.
