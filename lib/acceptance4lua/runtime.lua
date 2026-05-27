local source = require("acceptance4lua.source")

local runtime = {}

local function _execution_examples(scenario)
  if #(scenario.examples or {}) == 0 then
    return { {} }
  end
  return scenario.examples
end

local function _execution_name(scenario, example_index)
  return tostring(scenario.name or "scenario") .. "/example_" .. tostring(example_index)
end

local function _resolve_step(ir, step, example)
  for _, parameter in ipairs(source.extract_parameters(step.text)) do
    if example[parameter] == nil then
      return nil, source.step_error(ir, step, "missing example value: " .. tostring(source.field_name(ir, parameter)))
    end
  end

  local resolved = tostring(step.text or ""):gsub("<([^<>]+)>", function(parameter)
    return tostring(example[parameter])
  end)
  return resolved
end

local function _run_step(ir, world, example, step, handlers)
  local handler = (handlers or {})[step.text]
  if handler == nil then
    return nil, source.step_error(ir, step, "unsupported step: " .. tostring(step.text))
  end

  local resolved_text, resolve_err = _resolve_step(ir, step, example)
  if resolved_text == nil then
    return nil, resolve_err
  end

  local ok, success, err = pcall(handler, world, example, step, resolved_text)
  if not ok then
    return nil, success
  end
  if success == false or err ~= nil then
    return nil, err or "step failed: " .. tostring(step.text)
  end
  return true
end

function runtime.run_execution(ir, scenario, example, handlers)
  local world = {}
  local steps = {}
  for _, step in ipairs(ir.background or {}) do
    steps[#steps + 1] = step
  end
  for _, step in ipairs(scenario.steps or {}) do
    steps[#steps + 1] = step
  end

  for _, step in ipairs(steps) do
    local ok, err = _run_step(ir, world, example or {}, step, handlers)
    if not ok then
      return nil, err
    end
  end
  return true
end

function runtime.run_feature(ir, handlers)
  local result = {
    ok = true,
    failures = {},
  }

  for _, scenario in ipairs(ir.scenarios or {}) do
    for example_index, example in ipairs(_execution_examples(scenario)) do
      local ok, err = runtime.run_execution(ir, scenario, example, handlers)
      if not ok then
        result.ok = false
        result.failures[#result.failures + 1] = {
          name = _execution_name(scenario, example_index),
          error = err,
        }
      end
    end
  end

  return result
end

function runtime.format_failures(result)
  local lines = {}
  for _, failure in ipairs((result or {}).failures or {}) do
    lines[#lines + 1] = tostring(failure.name) .. ": " .. tostring(failure.error)
  end
  return table.concat(lines, "\n")
end

function runtime.define_busted_specs(ir, handlers, define_it)
  define_it = define_it or rawget(_G, "it")
  assert(define_it ~= nil, "missing busted it function")
  for _, scenario in ipairs(ir.scenarios or {}) do
    for example_index, example in ipairs(_execution_examples(scenario)) do
      local name = _execution_name(scenario, example_index)
      define_it(name, function()
        local ok, err = runtime.run_execution(ir, scenario, example, handlers)
        assert(ok, err)
      end)
    end
  end
end

return runtime
