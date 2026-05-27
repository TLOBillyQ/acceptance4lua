local status = {}

local function _number(value)
  return tonumber(value) or 0
end

function status.snapshot(total, summary, running, interval_label)
  summary = summary or {}
  local skipped_mutations = _number(summary.skipped_mutations)
  local killed = _number(summary.killed)
  local survived = _number(summary.survived)
  local errors = _number(summary.errors)
  return {
    total = _number(total),
    completed = killed + survived + errors + skipped_mutations,
    running = _number(running),
    interval = tostring(interval_label or ""),
    killed = killed,
    survived = survived,
    errors = errors,
    skipped_scenarios = _number(summary.skipped_scenarios),
    skipped_mutations = skipped_mutations,
  }
end

function status.format_line(snapshot)
  snapshot = snapshot or {}
  return table.concat({
    "status",
    "total=" .. tostring(_number(snapshot.total)),
    "completed=" .. tostring(_number(snapshot.completed)),
    "running=" .. tostring(_number(snapshot.running)),
    "interval=" .. tostring(snapshot.interval or ""),
    "killed=" .. tostring(_number(snapshot.killed)),
    "survived=" .. tostring(_number(snapshot.survived)),
    "errors=" .. tostring(_number(snapshot.errors)),
    "skipped_scenarios=" .. tostring(_number(snapshot.skipped_scenarios)),
    "skipped_mutations=" .. tostring(_number(snapshot.skipped_mutations)),
  }, " ")
end

return status

--[[ mutate4lua-manifest
version=2
projectHash=8f105fdf96531f57
scope.0.id=chunk:tools/acceptance/mutator/status.lua
scope.0.kind=chunk
scope.0.startLine=1
scope.0.endLine=43
scope.0.semanticHash=7a6664bbaa8d02db
scope.0.lastMutatedAt=2026-05-25T11:44:41Z
scope.0.lastMutationLane=behavior
scope.0.lastMutationStatus=no_sites
scope.0.lastMutationSites=0
scope.0.lastMutationKilled=0
scope.1.id=function:_number:3
scope.1.kind=function
scope.1.startLine=3
scope.1.endLine=5
scope.1.semanticHash=d5508bc2e19243b1
scope.1.lastMutatedAt=2026-05-25T11:46:23Z
scope.1.lastMutationLane=behavior
scope.1.lastMutationStatus=passed
scope.1.lastMutationSites=3
scope.1.lastMutationKilled=3
scope.2.id=function:status.snapshot:7
scope.2.kind=function
scope.2.startLine=7
scope.2.endLine=24
scope.2.semanticHash=9517ea0b541f1d96
scope.2.lastMutatedAt=2026-05-25T11:46:23Z
scope.2.lastMutationLane=behavior
scope.2.lastMutationStatus=passed
scope.2.lastMutationSites=12
scope.2.lastMutationKilled=12
scope.3.id=function:status.format_line:26
scope.3.kind=function
scope.3.startLine=26
scope.3.endLine=40
scope.3.semanticHash=185e3e10aa6e17e7
scope.3.lastMutatedAt=2026-05-25T11:46:23Z
scope.3.lastMutationLane=behavior
scope.3.lastMutationStatus=passed
scope.3.lastMutationSites=2
scope.3.lastMutationKilled=2
]]
