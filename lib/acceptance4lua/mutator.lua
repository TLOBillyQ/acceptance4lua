local common = require("acceptance4lua.runtime.common")
local engine = require("acceptance4lua.mutator.engine")
local feature_stamp = require("acceptance4lua.feature_stamp")
local generator = require("acceptance4lua.generator")
local gherkin_parser = require("acceptance4lua.gherkin_parser")
local json = require("acceptance4lua.json")
local parallel_lanes = require("acceptance4lua.runtime.parallel_lanes")
local report_mod = require("acceptance4lua.mutator.report")
local runner = require("acceptance4lua.runner")
local scenario_manifest = require("acceptance4lua.scenario_manifest")
local spec_hash = require("acceptance4lua.spec_hash")
local status_mod = require("acceptance4lua.mutator.status")

local mutator = {}

mutator.mutate_value = engine.mutate_value
mutator.build_mutations = engine.build_mutations
mutator.apply_mutation = engine.apply_mutation
mutator.format_text_report = report_mod.format_text_report
mutator.format_json_report = report_mod.format_json_report
mutator.format_status_line = status_mod.format_line

local function _add_results(summary, results)
  for _, result in ipairs(results or {}) do
    if result.status == "killed" then
      summary.killed = summary.killed + 1
    elseif result.status == "survived" then
      summary.survived = summary.survived + 1
    elseif result.status == "error" then
      summary.errors = summary.errors + 1
    end
  end
end

local function _status_reporter(options, total_mutations)
  local callback = options and options.status_callback
  if callback == nil then
    return function() end
  end
  local interval = tonumber(options.status_interval_seconds or 30) or 30
  if interval <= 0 then
    return function() end
  end

  local started_at = os.time()
  local last_emitted_at = nil
  return function(summary, running, force)
    local now = os.time()
    if not force
      and last_emitted_at ~= nil
      and os.difftime(now, last_emitted_at) < interval
    then
      return
    end
    last_emitted_at = now
    local elapsed_label = string.format("%ds", os.difftime(now, started_at))
    callback(status_mod.format_line(status_mod.snapshot(
      total_mutations, summary, running or 0, elapsed_label
    )))
  end
end

-- common.write_file 内部已 ensure_dir 父目录，这里不再重复起一次 mkdir。
local function _write_mutation_ir(path, ir)
  return common.write_file(path, json.encode(ir))
end

local function _generated_path(options)
  return common.join_path(options.generated_dir, "feature_acceptance_spec.lua")
end

local function _prepare_generated_entrypoint(base_ir, options)
  local base_dir = common.join_path(options.work_dir, "base")
  local base_json_path = common.join_path(base_dir, "feature.json")
  local ok, err = _write_mutation_ir(base_json_path, base_ir)
  if not ok then
    return nil, err
  end

  local generated_path = _generated_path(options)
  ok, err = generator.write_generated(base_ir, generated_path, {
    ir_path = base_json_path,
    steps_module = options.steps_module,
  })
  if not ok then
    return nil, err
  end
  return generated_path
end

local function _read_generated_implementation_hash(generated_path, feature_path)
  local metadata_path = generator.metadata_path_for(generated_path, feature_path)
  local content = common.read_file(metadata_path)
  if content == nil then
    return nil
  end
  local ok, metadata = pcall(json.decode, content)
  if not ok or type(metadata) ~= "table" then
    return nil
  end
  if metadata.feature_path ~= feature_path then
    return nil
  end
  return metadata.implementation_hash
end

local function _result_for_error(mutation, message, duration)
  return {
    mutation = mutation,
    status = "error",
    output = "",
    error = tostring(message or "mutation infrastructure error"),
    duration = duration or 0,
  }
end

-- 空输出（如 exit 127 但无 stderr）时回退到可读的默认错误信息。
local function _error_message(text, fallback)
  if text == nil or text == "" then
    return fallback
  end
  return text
end

local function _prepare_one(base_ir, mutation, options)
  local mutation_dir = common.join_path(options.work_dir, "mutations/" .. mutation.id)
  local ir_path = common.join_path(mutation_dir, "feature.json")
  local mutated_ir = engine.apply_mutation(base_ir, mutation)

  local ok, err = _write_mutation_ir(ir_path, mutated_ir)
  if not ok then
    return nil, err
  end

  return ir_path
end

local function _run_one(base_ir, mutation, options)
  local start_time = common.wall_time()
  local feature_json, err = _prepare_one(base_ir, mutation, options)
  if feature_json == nil then
    return _result_for_error(mutation, err, os.difftime(common.wall_time(), start_time))
  end

  local run = runner.run_generated(options.generated_path, {
    feature_json = feature_json,
    lua_bin = options.lua_bin,
    lua_path = options.lua_path,
  })
  if run.error ~= "" then
    return _result_for_error(mutation, run.error, run.duration)
  end

  return {
    mutation = mutation,
    status = run.passed and "survived" or "killed",
    output = run.output,
    error = "",
    duration = run.duration,
  }
end

-- 并行批：跟 runner.run_generated 同语义，但用 parallel_lanes 一次调度 N 个 lua 子进程。
local function _lane_cmd(generated_path, feature_json, options)
  return runner.build_command(generated_path, {
    feature_json = feature_json,
    lua_bin = options.lua_bin,
    lua_path = options.lua_path,
  })
end

local function _result_from_lane(prepared, lane_result)
  local output = lane_result.output or ""
  local duration = os.difftime(common.wall_time(), prepared.started_at)
  if runner.is_infrastructure_error(lane_result.exit_code, output) then
    return _result_for_error(
      prepared.mutation,
      _error_message(output, "lua infrastructure error (exit " .. tostring(lane_result.exit_code) .. ")"),
      duration
    )
  end
  return {
    mutation = prepared.mutation,
    status = lane_result.ok and "survived" or "killed",
    output = output,
    error = "",
    duration = duration,
  }
end

local function _run_parallel_batch(prepared_batch, options)
  local lanes = {}
  for index, prepared in ipairs(prepared_batch) do
    lanes[index] = {
      label = prepared.mutation.id,
      cmd = _lane_cmd(prepared.generated_path, prepared.feature_json, options),
    }
  end
  -- parallel_lanes.run 在 launcher 写盘/启动失败时会 error()，与
  -- _run_parallel_runner_workers 一样兜底成 error 结果而不是让整个 run 崩掉。
  local run_ok, run_err, lane_results = pcall(parallel_lanes.run, lanes, { stream = false })
  local results = {}
  if not run_ok then
    for index, prepared in ipairs(prepared_batch) do
      results[index] = _result_for_error(prepared.mutation, run_err, os.difftime(common.wall_time(), prepared.started_at))
    end
    return results
  end
  for index, prepared in ipairs(prepared_batch) do
    results[index] = _result_from_lane(prepared, lane_results[index])
  end
  return results
end

local _TIMEOUT_MESSAGE = "mutation run timed out"

local function _run_sequential(base_ir, mutations, options, timed_out)
  local results = {}
  for _, mutation in ipairs(mutations) do
    if timed_out() then
      results[#results + 1] = _result_for_error(mutation, _TIMEOUT_MESSAGE, 0)
    else
      results[#results + 1] = _run_one(base_ir, mutation, options)
    end
  end
  return results
end

-- 并行执行：准备阶段顺序写文件（mkdir/写盘 race-free），
-- 执行阶段每 workers 个一批并发跑生成的入口。
local function _run_parallel(base_ir, mutations, options, timed_out)
  local results = {}
  local batch = {}

  local function flush()
    if #batch == 0 then return end
    for _, r in ipairs(_run_parallel_batch(batch, options)) do
      results[#results + 1] = r
    end
    batch = {}
  end

  local function append_error(mutation, err)
    flush()
    results[#results + 1] = _result_for_error(mutation, err, 0)
  end

  for _, mutation in ipairs(mutations) do
    if timed_out() then
      append_error(mutation, _TIMEOUT_MESSAGE)
    else
      local feature_json, prep_err = _prepare_one(base_ir, mutation, options)
      if feature_json == nil then
        append_error(mutation, prep_err)
      else
        batch[#batch + 1] = {
          mutation = mutation,
          generated_path = options.generated_path,
          feature_json = feature_json,
          started_at = common.wall_time(),
        }
        if #batch >= options.workers then
          flush()
        end
      end
    end
  end
  flush()
  return results
end

local _OUTCOME_STATUS = { test_failure = "killed", test_success = "survived" }

local function _job_response_to_result(mutation, response)
  local status = response and _OUTCOME_STATUS[response.outcome]
  if status ~= nil then
    return {
      mutation = mutation,
      status = status,
      output = response.output or "",
      error = "",
      duration = response.duration or 0,
    }
  end
  return _result_for_error(
    mutation,
    _error_message(response and response.error, "runner worker protocol error"),
    response and response.duration or 0
  )
end

local function _sort_results_by_mutation_id(results)
  table.sort(results, function(left, right)
    local left_index = tonumber(tostring(left.mutation.id):match("%d+")) or 0
    local right_index = tonumber(tostring(right.mutation.id):match("%d+")) or 0
    return left_index < right_index
  end)
end

local function _append_worker_output_results(output, mutation_by_id, seen, results)
  for line in (output or ""):gmatch("([^\n]+)") do
    local decoded_ok, response = pcall(json.decode, line)
    -- response 可能是 JSON 标量（如对裸数字行解码成功），索引前先确认是 table。
    if decoded_ok and type(response) == "table" and response.id ~= nil and mutation_by_id[response.id] ~= nil then
      seen[response.id] = true
      results[#results + 1] = _job_response_to_result(mutation_by_id[response.id], response)
    end
  end
end

local function _append_missing_worker_results(mutation_by_id, seen, results)
  for id, mutation in pairs(mutation_by_id) do
    if not seen[id] then
      results[#results + 1] = _result_for_error(mutation, "runner worker did not return a response for " .. id, 0)
    end
  end
end

local function _write_worker_input(path, jobs, results, mutation_by_id)
  local lines = {}
  for index, job in ipairs(jobs) do
    lines[index] = job.line
  end
  local ok, err = common.write_file(path, table.concat(lines, "\n") .. "\n")
  if ok then
    return true
  end
  for _, mutation in pairs(mutation_by_id) do
    results[#results + 1] = _result_for_error(mutation, err, 0)
  end
  return nil
end

local function _run_single_runner_worker(input_path, jobs, mutation_by_id, options, results)
  if not _write_worker_input(input_path, jobs, results, mutation_by_id) then
    return
  end

  local run = common.run_command(options.runner_worker, {
    cwd = common.current_dir(),
    stdin_path = input_path,
  })
  if not run.ok then
    local message = _error_message(run.output, "runner worker exited with code " .. tostring(run.exit_code))
    for _, mutation in pairs(mutation_by_id) do
      results[#results + 1] = _result_for_error(mutation, message, 0)
    end
    return
  end

  local seen = {}
  _append_worker_output_results(run.output, mutation_by_id, seen, results)
  _append_missing_worker_results(mutation_by_id, seen, results)
end

local function _run_parallel_runner_workers(jobs, mutation_by_id, options, results)
  local worker_count = math.min(options.workers, #jobs)
  local chunks = {}
  local lane_mutation_ids = {}
  for index = 1, worker_count do
    chunks[index] = {}
    lane_mutation_ids[index] = {}
  end
  for index, job in ipairs(jobs) do
    local worker_index = ((index - 1) % worker_count) + 1
    chunks[worker_index][#chunks[worker_index] + 1] = job
    lane_mutation_ids[worker_index][#lane_mutation_ids[worker_index] + 1] = job.id
  end

  -- seen 从写盘阶段就开始跟踪：输入文件写失败的 mutation 已登记 error，
  -- 后面的 missing/lane-failure 兜底不得对同一 mutation 重复计数。
  local seen = {}
  local lanes = {}
  for worker_index, chunk in ipairs(chunks) do
    local input_path = common.join_path(options.work_dir, "runner-worker-input-" .. tostring(worker_index) .. ".jsonl")
    local chunk_lines = {}
    for index, job in ipairs(chunk) do
      chunk_lines[index] = job.line
    end
    local ok, err = common.write_file(input_path, table.concat(chunk_lines, "\n") .. "\n")
    if not ok then
      for _, id in ipairs(lane_mutation_ids[worker_index]) do
        results[#results + 1] = _result_for_error(mutation_by_id[id], err, 0)
        seen[id] = true
      end
    else
      lanes[#lanes + 1] = {
        label = "acceptance_worker_" .. tostring(worker_index),
        cmd = options.runner_worker .. " < " .. common.shell_quote(input_path),
        worker_index = worker_index,
      }
    end
  end

  if #lanes == 0 then
    return
  end

  local ok, worker_error, lane_results = pcall(parallel_lanes.run, lanes, {
    stream = false,
    timeout = options.timeout_seconds or 600,
  })
  if not ok then
    for _, job in ipairs(jobs) do
      if not seen[job.id] then
        results[#results + 1] = _result_for_error(mutation_by_id[job.id], worker_error, 0)
        seen[job.id] = true
      end
    end
    return
  end

  for lane_index, lane in ipairs(lanes) do
    local lane_result = lane_results[lane_index]
    if lane_result == nil or not lane_result.ok then
      local output = _error_message(lane_result and lane_result.output, "runner worker failed")
      for _, id in ipairs(lane_mutation_ids[lane.worker_index]) do
        results[#results + 1] = _result_for_error(mutation_by_id[id], output, 0)
        seen[id] = true
      end
    else
      _append_worker_output_results(lane_result.output, mutation_by_id, seen, results)
    end
  end
  _append_missing_worker_results(mutation_by_id, seen, results)
end

local function _run_runner_worker(base_ir, mutations, options, timed_out)
  local jobs = {}
  local mutation_by_id = {}
  local results = {}

  for _, mutation in ipairs(mutations) do
    if timed_out() then
      results[#results + 1] = _result_for_error(mutation, _TIMEOUT_MESSAGE, 0)
    else
      local feature_json, prep_err = _prepare_one(base_ir, mutation, options)
      if feature_json == nil then
        results[#results + 1] = _result_for_error(mutation, prep_err, 0)
      else
        mutation_by_id[mutation.id] = mutation
        jobs[#jobs + 1] = {
          id = mutation.id,
          line = json.encode_compact({
            id = mutation.id,
            feature_json = feature_json,
            generated_dir = options.generated_dir,
            work_dir = common.parent_dir(feature_json),
            timeout = tostring(options.timeout_seconds or ""),
          }):gsub("\n$", ""),
        }
      end
    end
  end

  if #jobs == 0 then
    return results
  end

  if options.workers <= 1 then
    _run_single_runner_worker(common.join_path(options.work_dir, "runner-worker-input.jsonl"), jobs, mutation_by_id, options, results)
  else
    _run_parallel_runner_workers(jobs, mutation_by_id, options, results)
  end

  _sort_results_by_mutation_id(results)
  return results
end

local function _summary(results)
  local summary = {
    total = #results,
    killed = 0,
    survived = 0,
    errors = 0,
  }
  _add_results(summary, results)
  return summary
end

local _VALID_LEVELS = { full = true, hard = true, soft = true }

function mutator.run(options)
  options = options or {}
  if options.feature == nil then
    return nil, "feature is required"
  end
  options.work_dir = options.work_dir or "build/acceptance-mutation"
  options.generated_dir = options.generated_dir or common.join_path(options.work_dir, "generated")
  -- workers 边界采用 APS 上游（Go mutator.go / bb mutation.clj）的 clamp 语义：
  -- 非正数静默提升到 1，CLI 帮助文本已写明，不做硬性报错。
  options.workers = math.max(1, tonumber(options.workers or 1) or 1)
  options.level = options.level or "hard"
  if not _VALID_LEVELS[options.level] then
    return nil, "invalid level: " .. tostring(options.level)
  end

  local base_ir, err = gherkin_parser.parse_file(options.feature)
  if base_ir == nil then
    return nil, err
  end

  local ok
  ok, err = common.ensure_dir(options.work_dir)
  if not ok then
    return nil, err
  end

  ok, err = common.ensure_dir(options.generated_dir)
  if not ok then
    return nil, err
  end

  options.generated_path, err = _prepare_generated_entrypoint(base_ir, options)
  if options.generated_path == nil then
    return nil, err
  end

  local implementation_hash = options.implementation_hash
    or _read_generated_implementation_hash(options.generated_path, options.feature)
    or spec_hash.compute_generated_files_hash({ options.generated_path })

  local mutations = engine.build_mutations(base_ir, { skip_columns = options.skip_columns })
  local progress = {
    killed = 0,
    survived = 0,
    errors = 0,
    skipped_scenarios = 0,
    skipped_mutations = 0,
  }
  local emit_status = _status_reporter(options, #mutations)

  local feature_source = common.read_file(options.feature) or ""
  local existing_manifest = scenario_manifest.read(feature_source)

  local current_state = {
    feature_name = base_ir.name,
    feature_path = options.feature,
    background_hash = spec_hash.compute_background_hash(base_ir.background),
    implementation_hash = implementation_hash,
  }

  if existing_manifest == nil and options.level ~= "full"
    and feature_stamp.is_stamp_current(feature_source)
  then
    progress.skipped_scenarios = #base_ir.scenarios
    progress.skipped_mutations = #mutations
    emit_status(progress, 0, true)
    return {
      summary = {
        total = 0,
        killed = 0,
        survived = 0,
        errors = 0,
        skipped_scenarios = #base_ir.scenarios,
        skipped_mutations = #mutations,
      },
      results = {},
    }
  end

  local started_at = os.time()
  local results = {}
  local skipped_scenarios = 0
  local skipped_mutations = 0
  local new_entries = {}

  -- 预分桶，避免每个场景都全量扫描一遍 mutations（O(场景数×变异数)）。
  local mutations_by_scenario = {}
  for _, mutation in ipairs(mutations) do
    local bucket = mutations_by_scenario[mutation.scenario_index]
    if bucket == nil then
      bucket = {}
      mutations_by_scenario[mutation.scenario_index] = bucket
    end
    bucket[#bucket + 1] = mutation
  end

  -- 循环不变量：超时判定与执行策略在循环外只算一次。
  local function _timed_out()
    return options.timeout_seconds ~= nil
      and os.difftime(os.time(), started_at) >= options.timeout_seconds
  end
  local execute = options.runner_worker and _run_runner_worker
    or (options.workers <= 1 and _run_sequential or _run_parallel)

  for scenario_lua_index, scenario in ipairs(base_ir.scenarios) do
    local scenario_index = scenario_lua_index - 1
    local scenario_mutations = mutations_by_scenario[scenario_lua_index] or {}

    local should_skip = scenario_manifest.decide_scenario_skip(
      existing_manifest, scenario, scenario_index, current_state, options.level
    )

    if should_skip then
      skipped_scenarios = skipped_scenarios + 1
      skipped_mutations = skipped_mutations + #scenario_mutations
      progress.skipped_scenarios = skipped_scenarios
      progress.skipped_mutations = skipped_mutations
      emit_status(progress, 0, false)
      new_entries[#new_entries + 1] = scenario_manifest.find_entry_for_index(
        existing_manifest, scenario_index
      )
    else
      emit_status(progress, #scenario_mutations, false)
      local scenario_results = execute(base_ir, scenario_mutations, options, _timed_out)
      for _, result in ipairs(scenario_results) do
        results[#results + 1] = result
      end
      _add_results(progress, scenario_results)
      emit_status(progress, 0, false)
      new_entries[#new_entries + 1] = scenario_manifest.build_entry(
        scenario, scenario_index, #scenario_mutations, scenario_results
      )
    end
  end

  local summary = _summary(results)
  summary.skipped_scenarios = skipped_scenarios
  summary.skipped_mutations = skipped_mutations
  emit_status(summary, 0, true)

  local report = {
    summary = summary,
    results = results,
  }

  local executed_any_scenario = skipped_scenarios < #base_ir.scenarios
  if executed_any_scenario
    and report.summary.survived == 0
    and report.summary.errors == 0
  then
    local new_manifest = {
      version = scenario_manifest.VERSION,
      tested_at = scenario_manifest.utc_now(),
      feature_name = current_state.feature_name,
      feature_path = current_state.feature_path,
      background_hash = current_state.background_hash,
      implementation_hash = current_state.implementation_hash,
      scenarios = new_entries,
    }
    scenario_manifest.apply_to_file(options.feature, new_manifest)
    feature_stamp.apply_stamp_to_file(options.feature)
  end

  return report
end

return mutator
