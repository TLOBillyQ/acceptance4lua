local status = {}

local function _number(value)
  return tonumber(value) or 0
end

function status.snapshot(total, summary, running, elapsed_label)
  summary = summary or {}
  local skipped_mutations = _number(summary.skipped_mutations)
  local killed = _number(summary.killed)
  local survived = _number(summary.survived)
  local errors = _number(summary.errors)
  return {
    total = _number(total),
    completed = killed + survived + errors + skipped_mutations,
    running = _number(running),
    elapsed = tostring(elapsed_label or ""),
    killed = killed,
    survived = survived,
    errors = errors,
    skipped_scenarios = _number(summary.skipped_scenarios),
    skipped_mutations = skipped_mutations,
  }
end

local _NUMERIC_FIELDS = {
  "total",
  "completed",
  "running",
  "killed",
  "survived",
  "errors",
  "skipped_scenarios",
  "skipped_mutations",
}

function status.format_line(snapshot)
  snapshot = snapshot or {}
  local parts = { "status", "elapsed=" .. tostring(snapshot.elapsed or "") }
  for _, field in ipairs(_NUMERIC_FIELDS) do
    parts[#parts + 1] = field .. "=" .. tostring(_number(snapshot[field]))
  end
  return table.concat(parts, " ")
end

return status
