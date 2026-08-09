# acceptance4lua

`acceptance4lua` 是一个纯 Lua 验收流水线框架，仿照
`unclebob/Acceptance-Pipeline-Specification` 实现。

它提供：

- 一个确定性的 Gherkin 子集解析器；
- 面向支持的关键字集合的中文 `# language: zh-CN` 规范化器；
- JSON IR 编解码；
- 一个轻量独立的验收入口生成器（自包含 harness，无需外部测试框架）；
- 一个仅报告、支持 CJK 相似度评分的 IR-DRY 检查器；
- 一个将精确步骤文本分发到项目步骤处理器的运行时；
- Gherkin 示例值变异，含 feature 戳记、scenario 清单、生成文件实现哈希、
  runner-worker 集成和状态报告。

项目专用代码保留在本包之外。宿主提供步骤处理器、runner 适配器、命令包装器
以及任何应用 fixture；参见下文"接入新项目"。

## 目录结构 (Layout)

```text
src/acceptance4lua/
  cli/                 command modules
  mutator/             mutation engine, reports, status lines
  runtime/             small portable runtime helpers
  *.lua                parser, generator, runtime, source maps, hashes
```

## 生成入口 (Generated Specs)

生成的入口是独立的 Lua 脚本。它们默认使用可移植的框架模块和一个中立的宿主
步骤模块名：

```lua
require("acceptance4lua.harness")
require("acceptance4lua.runtime")
require("steps")
require("acceptance4lua.json")
```

生成器接受模块名覆盖，以适应不同命名空间的宿主：通过
`generator.generate(ir, opts)` / `generator.generate_file(json, out, opts)`
传入 `steps_module`（以及可选的 `runtime_module`、`json_module`、
`harness_module`），或在 `acceptance-entrypoint-generator` CLI 上使用
`--steps-module <name>`。

使用任意 Lua 解释器运行生成的入口；`LUA_PATH` 必须覆盖框架和宿主模块
（runner 会自动设置，并遵循 `ACCEPTANCE_LUA_BIN` / `ACCEPTANCE_LUA_PATH`
覆盖）：

```sh
LUA_PATH='src/?.lua;src/?/init.lua;;' lua path/to/generated_spec.lua
```

## 接入新项目 (Adopting In A New Project)

宿主项目按如下方式接入流水线（以虚构项目 `eggy` 为例）：

1. 将步骤处理器编写为普通 Lua 模块，返回
   `{ handlers = function() return { ["step text"] = function(world, example) ... end, ... } end }`。
   生成的入口默认 require `steps`，因此 `eggy/steps.lua` 可直接使用；对于
   `eggy.steps` 等嵌套命名空间，向生成器（以及内部会重新生成入口的 mutator）
   传入 `steps_module = "eggy.steps"`。
2. 解析并生成：
   `require("acceptance4lua.gherkin_parser").write_json_file("features/x.feature", "build/x.json")`，
   然后
   `require("acceptance4lua.generator").generate_file("build/x.json", "build/x_spec.lua", { steps_module = "eggy.steps" })`。
3. 通过 runner（`acceptance4lua.runner.run_generated`）或普通 `lua` 运行
   spec，`LUA_PATH` 需同时覆盖 `acceptance4lua` 和宿主步骤模块。
4. 变异：
   `require("acceptance4lua.mutator").run({ feature = "features/x.feature", steps_module = "eggy.steps", ... })`，
   或 CLI `gherkin-mutator --feature <path> --runner-worker <cmd> [--steps-module <name>]`。
   `--feature` 为必选项；没有内置默认路径。
5. `features/` 下的 feature 文件必须以 `# language: zh-CN` 开头。如果宿主
   将 feature 放在其他位置，可向 `chinese_normalizer.normalize_text` /
   `gherkin_parser.parse_file` 传入 `mandatory_language_dirs = { "<dir>" }`
   （传空表则禁用此规则）。

### 兼容说明 (Compatibility Notes)

- 默认生成的步骤模块已从 `acceptance.steps` 变更为 `steps`。依赖旧隐式默认值
  的宿主必须显式传入 `steps_module = "acceptance.steps"`。
- `gherkin-mutator` 不再将 `--feature` 默认为占位路径；该选项现为必选（所有
  实际调用方原本就已传入此选项）。
- 生成的 metadata 文件名现在附带规范化 feature 路径的短哈希
  （`<slug>-<8hex>.json`），折叠到同一 slug 的不同路径（如 `a_b.feature`
  与 `a/b.feature`）不再互相覆盖。外部消费方应通过
  `generator.metadata_path_for` 解析 metadata 路径，而非自行拼接文件名。
- mutation 报告中的 `duration` 已改为 wall clock（`os.time` 秒级，与上游
  `time.Since` / `System/nanoTime` 同为墙钟口径；此前误用 `os.clock`
  进程 CPU 时间，数值近似为 0），报告数值会因此变化。
- 数值选项边界沿用上游 APS 语义：`--workers` 小于 1 的值被钳制为 1 而非
  拒绝；`--timeout 0` 表示立即超时；`--status-interval 0` 关闭状态行。
- 同一场景的第二个 `Examples:` 块与 `Examples:` 之后的 step 行按上游 APS
  行为处理（示例行合并进场景、step 追加），而非报错。

## 上游对齐 (Upstream Alignment)

`acceptance4lua` 遵循"上游规格的 Lua 忠实实现"原则：上游各实现中一致的行为
逐字照抄；任何不同之处均为有意偏离，并在此记录其理由。跨仓库决策以 ADR
形式存放在 luatools notes 仓库（`projects/luatools/docs/adr/`）。

**对齐不变量**

- 命令名与形态（`gherkin-parser`、`acceptance-entrypoint-generator`、
  `gherkin-ir-dry-checker`、`gherkin-mutator`）及退出码约定（0 成功 /
  1 运行时错误 / 2 用法错误）。
- JSON IR 结构及 APS 定义的 runner-adapter 协议。
- IR-DRY 检查器仅报告；绝不重写 feature、IR 或生成的文件。
- 上游两套实现（Go 与 Babashka）一致的边界与静默语义逐字对齐：同场景第二个
  `Examples:` 块静默合并、`Examples:` 后的 step 行静默追加、`--workers`
  非正值钳制为 1、子进程耗时按 wall clock 计时。

**有意偏离**

- 中文 `# language: zh-CN` 关键字规范化 —— APS 明确不支持本地化关键字；
  宿主项目的中文 feature 需要此功能。
- CJK 感知相似度评分（虚词丢弃 + 汉字二元组 Jaccard）—— 可移植的字母数字
  基线会将不相关的中文步骤评分为 1.0；APS 允许更好的语言中立的启发式方法。
- 步骤文本的精确字典匹配（APS 推荐 regex/占位符匹配）—— 为宿主提供确定性
  和更清晰的错误消息。
- 内嵌最小 busted 风格 harness —— 生成的入口必须在未安装测试框架的宿主上
  运行。
- 额外的 `--skip-columns` / `--verbose` 选项，以及未提供 `--runner-worker`
  时的 Lua 子进程回退。
- 额外的 IR 元数据（`source_path`、`source_line`、`field_names`），用于错误
  定位和变异报告。
- 生成的 metadata 文件名附加规范化路径的短哈希 —— 上游 slug 算法存在路径
  冲突缺陷（`a_b.feature` 与 `a/b.feature` 生成同名文件互相覆盖），本实现
  予以消除。

## 测试 (Tests)

本仓库自身的测试套件运行在 [luaunit](https://github.com/bluebird75/luaunit) 上
（4lua 工具链统一决策，ADR-0005），遵循 `tests/test_*.lua` + luaunit 约定。
注意：`src/acceptance4lua/harness.lua` 是产品代码（生成的验收入口使用的内嵌
harness），并非本仓库的测试设施。

先安装 luaunit：

```sh
luarocks install luaunit
```

然后运行：

```sh
lua tests/run.lua
```

## 与 APS 的关系 (Relationship To APS)

命令形态保持 APS 兼容：

```text
gherkin-parser <feature-file> <json-output>
acceptance-entrypoint-generator <json-ir> <generated-test-output>
gherkin-ir-dry-checker [--include-exact] <json-ir> <report-output>
gherkin-mutator [options]
```

IR-DRY 检查器仅报告：它读取一个 JSON IR 文件并写入一份咨询性 JSON 报告。
它绝不重写 feature 文件、IR、生成的入口文件或项目实现文件。

其精确匹配类别（`duplicate-in-scenario`、`exact-duplicate`、
`placeholder-variant`）保持了可移植的 APS 语义。相似度评分偏离了可移植的
字母数字基线，这是 APS 所允许的（"各实现可添加更好的语言中立的启发式方法"）：
中文步骤文本在移除占位符后不产生字母数字 token，因此基线会将不相关的中文
步骤评分为 1.0。本实现丢弃虚词后对汉字二元组计算 Jaccard 相似度，使得对
CJK 步骤文本的发现具有实际意义。

`acceptance4lua` 有意仅支持宿主项目所需的确定性子集。不支持的 Gherkin 语法
应明确失败，而非被静默忽略。
