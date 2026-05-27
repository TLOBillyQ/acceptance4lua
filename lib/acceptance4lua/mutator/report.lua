local json = require("acceptance4lua.json")

local report = {}

function report.format_text_report(report_data, opts)
  opts = opts or {}
  local lines = {}
  local summary = report_data.summary
  lines[#lines + 1] = "total="
    .. tostring(summary.total)
    .. " killed="
    .. tostring(summary.killed)
    .. " survived="
    .. tostring(summary.survived)
    .. " errors="
    .. tostring(summary.errors)

  local skipped_scenarios = tonumber(summary.skipped_scenarios) or 0
  local skipped_mutations = tonumber(summary.skipped_mutations) or 0
  if skipped_scenarios > 0 or skipped_mutations > 0 then
    lines[#lines + 1] = "skipped_scenarios="
      .. tostring(skipped_scenarios)
      .. " skipped_mutations="
      .. tostring(skipped_mutations)
  end

  local omitted_killed = 0
  for _, result in ipairs(report_data.results or {}) do
    if result.status == "killed" and opts.verbose ~= true then
      omitted_killed = omitted_killed + 1
    else
      lines[#lines + 1] = string.format(
        "%-8s %s",
        result.status,
        result.mutation.display_description or result.mutation.description
      )
      if result.status == "survived" or result.status == "error" then
        if result.error ~= "" then
          lines[#lines + 1] = "  error: " .. tostring(result.error)
        end
        if result.output ~= "" then
          lines[#lines + 1] = "  output:"
          lines[#lines + 1] = result.output
        end
      end
    end
  end
  if omitted_killed > 0 and (summary.survived > 0 or summary.errors > 0) then
    lines[#lines + 1] = "omitted_killed=" .. tostring(omitted_killed) .. " (use --verbose for killed details)"
  end
  return table.concat(lines, "\n") .. "\n"
end

function report.format_json_report(report_data)
  local encoded = {
    summary = {
      Total = report_data.summary.total,
      Killed = report_data.summary.killed,
      Survived = report_data.summary.survived,
      Errors = report_data.summary.errors,
    },
    results = {},
  }

  local skipped_scenarios = tonumber(report_data.summary.skipped_scenarios) or 0
  local skipped_mutations = tonumber(report_data.summary.skipped_mutations) or 0
  if skipped_scenarios > 0 or skipped_mutations > 0 then
    encoded.summary.SkippedScenarios = skipped_scenarios
    encoded.summary.SkippedMutations = skipped_mutations
  end

  for _, result in ipairs(report_data.results or {}) do
    encoded.results[#encoded.results + 1] = {
      Mutation = {
        ID = result.mutation.id,
        Path = result.mutation.path,
        Description = result.mutation.display_description or result.mutation.description,
        Original = result.mutation.original,
        Mutated = result.mutation.mutated,
        SourcePath = result.mutation.source_path,
        SourceLine = result.mutation.source_line,
        SourceField = result.mutation.source_field,
      },
      Status = result.status,
      Output = result.output,
      Error = result.error,
      Duration = result.duration,
    }
  end

  return json.encode(encoded)
end

return report
