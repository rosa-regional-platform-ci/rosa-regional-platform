# Scheduled report: ROSA HyperFleet CI daily health report

You are running a **cron** scheduled task that produces a daily CI health report for ROSA HyperFleet jobs. Keep the report **as concise as possible** to minimize channel noise. When everything is healthy, keep the summary concise, but still use the standard report structure. Only expand into detail when something needs attention.

## Goal

Check the pass/fail history (last 10 completed builds per job) for ROSA HyperFleet CI periodic jobs. Report overall CI health and individual job status.

**Overall CI Status** is based on the **latest completed run** for each job:

- Always post a report to the channel (never call `no_action_required()`)
- If all jobs are passing (latest run passed for both): post a concise health summary with trend table
- If any jobs are failing (latest run failed): post the full report and investigate failures in threaded replies

## Procedure

### 1. Load job configuration

Fetch the CI configuration from the single source of truth:
`https://raw.githubusercontent.com/openshift/release/refs/heads/main/ci-operator/config/openshift-online/rosa-hyperfleet/openshift-online-rosa-hyperfleet-main.yaml`

Use `fetch_web_content` to retrieve this YAML file. It defines all tests including periodic jobs with `cron:` schedules.

**Track these 2 periodic jobs:**

- `nightly-ephemeral` (test name `as: nightly-ephemeral`)
- `nightly-integration` (test name `as: nightly-integration`)

The full Prow job names follow the pattern:
`periodic-ci-openshift-online-rosa-hyperfleet-main-{test-name}`

If the fetch fails, fall back to these job names:

- periodic-ci-openshift-online-rosa-hyperfleet-main-nightly-ephemeral
- periodic-ci-openshift-online-rosa-hyperfleet-main-nightly-integration

### 2. Collect build history (last 10 runs)

For each job, collect the **last 10 completed job runs** for the trend table. Use Prow CI tools (`search_prow_jobs`, `query_prowjobs`, etc.) or `fetch_web_content` on the job-history page.

**Same-day reporting rule:** The "Latest Run Status" section must report **today's run** for each job. Do not fall back to a previous day's completed run for the latest status. Both jobs must be reported from the same day (today).

**Job status values:** Report the actual state of today's run:

- **passing** — today's run completed successfully
- **failing** — today's run completed with failures
- **running** — today's run is currently in progress
- **scheduled** — today's run is queued but not yet started
- **no run today** — no run was triggered today

**Retry for in-progress jobs:** If today's run for any tracked job is in a `scheduled` or `running` state:

1. Wait **10 minutes** and re-check the job status
2. Repeat up to **3 times** (30 minutes maximum wait)
3. After 30 minutes, report the current state as-is (e.g., "running" if still in progress)

**Important:** Track each of the last 10 runs with their dates:

- For each run, record: date, pass/fail status, build ID
- Format date as "MonDD" (e.g., "Jun10", "Jun11", "Jun19")
- Runs are ordered: oldest run first → newest run last (left to right)
- Count total: how many of the 10 runs passed vs failed
- Example: If 7 passed and 3 failed → "7/10 (70%)"

If Prow tools don't return historical build data directly, use `fetch_web_content` to retrieve the job-history page at `https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/%JOB_NAME%`. The HTML contains `var allBuilds = [{ID, Result, Started, Duration}];`.

### 3. Compute pass rates and health status

**Per-job pass rate**: pass/total for last 10 runs (e.g., 7/10 = 70%).

**10-run trend table**: Create a table with dates as header and jobs as rows:

- **Header row**: Dates in MonDD format (e.g., Jun10, Jun11, Jun12, ...)
- **Job rows**: Job name followed by ✅ or ❌ for each run, then pass count and percentage
- Order: oldest run first (leftmost) → newest run last (rightmost)
- Use monospace formatting for alignment

**Table format example:**

```text
              Jun10 Jun11 Jun12 Jun13 Jun14 Jun15 Jun16 Jun17 Jun18 Jun19
ephemeral:     ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   10/10 (100%)
integration:   ✅    ✅    ❌    ✅    ✅    ✅    ✅    ✅    ❌    ❌    7/10 (70%)
```

**Overall CI health** (based on today's run status for each job):

- :large_green_circle: Both jobs passing (2/2) - both today's runs completed successfully
- :large_yellow_circle: Mixed status (1/2) - one passing, one failing/running/scheduled
- :red_circle: Both jobs failing (0/2) - both today's runs failed
- :hourglass_flowing_sand: Pending — one or both jobs still running/scheduled (after retries exhausted)
- :white_circle: No runs today — no runs were triggered today for either job

**Individual job health** (based on today's run):

- :large_green_circle: Today's run passed
- :red_circle: Today's run failed
- :hourglass_flowing_sand: Today's run is still running or scheduled (after retries exhausted)
- :white_circle: No run triggered today

### 4. Channel response (top-level summary)

Post a concise summary as your channel response. This is the top-level message that everyone sees. The report tells the team how each job ran in the **last 1 day** (latest run) and shows the 10-run trend for context.

**Job name formatting:** Use concise names:

- "ephemeral" (not "nightly-ephemeral")
- "integration" (not "nightly-integration")

**Always use this format** (regardless of whether jobs are passing or failing):

```text
%OVERALL_EMOJI% *ROSA HyperFleet CI Daily Health -- %DATE%*

*Latest Run Status:*
%JOB_EMOJI% ephemeral: %STATUS% (<%JOB_RUN_URL%|latest run>)
%JOB_EMOJI% integration: %STATUS% (<%JOB_RUN_URL%|latest run>)

*Summary:* %PASSING_COUNT%/2 jobs passing

*10-Run Trend:*
              Jun10 Jun11 Jun12 Jun13 Jun14 Jun15 Jun16 Jun17 Jun18 Jun19
ephemeral:     ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   10/10 (100%)
integration:   ✅    ✅    ❌    ✅    ✅    ✅    ✅    ✅    ❌    ❌    7/10 (70%)

_<https://prow.ci.openshift.org|Prow Dashboard>_
```

**Field values:**

- `%OVERALL_EMOJI%`: :large_green_circle: if 2/2 passing, :large_yellow_circle: if mixed, :red_circle: if 0/2 passing, :hourglass_flowing_sand: if pending after retries, :white_circle: if no runs today
- `%JOB_EMOJI%`: :large_green_circle: if today's run passed, :red_circle: if failed, :hourglass_flowing_sand: if running/scheduled, :white_circle: if no run today
- `%STATUS%`: "passing", "failing", "running", "scheduled", or "no run today" based on **today's run** status
- `%JOB_RUN_URL%`: Link to today's Prow job run (or latest run link if no run today)

**Format instructions:**

- Use monospace/code block formatting (triple backticks) for the trend table
- Align columns with spaces for readability
- Date header: 5 characters wide per column (e.g., "Jun10")
- Job name: left-aligned, followed by colon
- Status emojis: centered under each date
- Pass count and percentage: right-aligned at the end of each row

**Trend interpretation examples:**

- All ✅ in a row → Perfect health (100%)
- Recent ❌ (rightmost columns) → Recent degradation (e.g., last 2 runs failed)
- Old ❌ (leftmost columns), then all ✅ → Recovered (old issue, now healthy)
- Scattered ❌ throughout → Flaky/intermittent failures

### 5. Failure analysis (threaded replies)

For each job whose **latest run failed** (status "failing" in Step 4), post a **separate threaded reply** to the top-level message with investigation.

For each failing job:

1. Fetch the build log from the most recent failure using Prow CI tools or `fetch_web_content` on the artifacts URL
2. Identify the specific failure: key error messages, failing test names, failing step
3. Perform root cause analysis using Sippy, Prow CI tools, or other available tools
4. Classify the failure based on what you find in the logs
5. **Note the failure pattern from the trend table:**
   - Is this a recent issue (❌ in last 1-3 columns)?
   - Is this an old issue (❌ in first few columns but recovered)?
   - Is this flaky (scattered ❌ throughout)?
   - Is this persistent (mostly ❌)?
6. Link to the failing Prow job run(s)

Format each threaded reply like:

```text
%EMOJI% *%JOB_NAME% -- %PASS%/10 (%RATE%%)*

Pattern: %PATTERN_DESCRIPTION%

%SHORT_SUMMARY%
%ROOT_CAUSE_ANALYSIS%

Most recent failure: <%JOB_RUN_URL%|Build #%NUMBER%> (%DATE%)
```

**Use concise job names:** "ephemeral" or "integration" (not "nightly-ephemeral" or "nightly-integration")

**Pattern descriptions to use:**

- "Recent degradation" - ❌ only in rightmost columns (e.g., "last 2 runs failed after 8 consecutive passes")
- "Persistent failure" - mostly ❌ across the table (e.g., "7 of 10 runs failed")
- "Intermittent/flaky" - scattered ❌ throughout (e.g., "5 failures scattered across 10 runs, no clear pattern")
- "Recovered" - ❌ only in leftmost columns (e.g., "failed first 2 runs, then 8 consecutive passes")
- "New issue" - first ❌ appeared recently (e.g., "first failure after 7 consecutive passes")

### Reference: common failure patterns

These are patterns that come up often. Use them as hints, not a rigid checklist. Classify failures however makes sense based on what you find in the logs.

- Ephemeral provider setup: issues provisioning ephemeral infrastructure
- Integration environment connectivity: problems reaching integration endpoints
- API platform test failures: rosa-hyperfleet-api test issues
- Image push failures: problems pushing to registry
- Terraform/infrastructure provisioning: resource creation errors
- Cleanup/teardown issues: resources not fully cleaned up

## Constraints

- Keep the top-level summary under 2000 characters. All detailed analysis goes in threaded replies.
- If more than half the jobs return no data, warn about possible Prow/GCS issues at the top.
