# Scheduled report: ROSA HyperFleet CI weekly status

You are running a **cron** scheduled task that produces a weekly CI status update for the ROSA HyperFleet team. **Always produce a report.** **Never** call `no_action_required()`.

## Goal

Provide a comprehensive weekly snapshot of ROSA HyperFleet CI health. This is the team's primary weekly status update, covering job health across all tracked jobs, Jira progress, and key PRs from the past week.

## Procedure

### 1. Load job configuration

Fetch the CI configuration from:
`https://raw.githubusercontent.com/openshift/release/refs/heads/main/ci-operator/config/openshift-online/rosa-hyperfleet/openshift-online-rosa-hyperfleet-main.yaml`

Use `fetch_web_content` to retrieve this YAML file. It defines all tests including periodic jobs with `cron:` schedules.

**Track these 2 periodic jobs:**

- `nightly-ephemeral` (test name `as: nightly-ephemeral`)
- `nightly-integration` (test name `as: nightly-integration`)

The full Prow job names follow the pattern:
`periodic-ci-openshift-online-rosa-hyperfleet-main-{test-name}`

### 2. Collect 7-day build history

For each job, collect **all builds from the last 7 days** (not a fixed build count). Use Prow CI tools or `fetch_web_content` on the job-history page. Filter builds by timestamp to include only those from the past 7 days. Calculate each job's pass rate over that window.

**Important:** Track each run with its date for the trend table:

- For each run, record: date, pass/fail status, build ID
- Format date as "MonDD" (e.g., "Jun13", "Jun14", "Jun19")
- Runs are ordered: oldest run first → newest run last (left to right)

**Also collect previous week data (8-14 days ago)** for the overall trend comparison:

- Calculate pass rate for the previous week (8-14 days ago)
- Compare this week vs previous week to determine trend direction

### 3. Query Jira milestone epic progress

Look up the current status of the ROSA HyperFleet milestone epics. Use Jira tools to query these specific epics and their child story counts:

**Milestone Epics to track:**

- [ROSA-668](https://redhat.atlassian.net/browse/ROSA-668): Milestone 3 - HCPs run on EKS MCs
- [ROSA-669](https://redhat.atlassian.net/browse/ROSA-669): Milestone 4 - Observability and Alerting
- [ROSA-670](https://redhat.atlassian.net/browse/ROSA-670): Milestone 5 - CLM Integration
- [ROSA-671](https://redhat.atlassian.net/browse/ROSA-671): Milestone 7 - Disaster Recovery
- [ROSA-672](https://redhat.atlassian.net/browse/ROSA-672): Milestone 6 - Zero Operator Access
- [ROSA-673](https://redhat.atlassian.net/browse/ROSA-673): Milestone 8 - Migrate My Cluster
- [ROSA-728](https://redhat.atlassian.net/browse/ROSA-728): Milestone 9 - Security Hardening

For each epic, report: how many stories closed, how many in progress, how many total. Only include epics that have recent activity (stories closed or moved to in-progress in the last 7 days) or are currently being worked on.

### 4. Find key PRs from the past week

Search for recently opened or merged PRs from ALL contributors (not just one person) across these repos:

- `openshift-online/rosa-hyperfleet` (main codebase)
- `openshift-online/rosa-hyperfleet-api` (API repository)
- `openshift-online/rosa-hyperfleet-cli` (CLI repository)
- `openshift-online/rosa-hyperfleet-internal` (internal tooling)
- `openshift/release` (CI configuration changes for rosa-hyperfleet)

Use GitHub tools or `fetch_web_content` to find PRs from the last 7 days. Include merged and notable open PRs.

### 5. Documentation Bot Activity Summary

Query for documentation PRs created by the documentation bot (author matches bot username, title prefix `[docs-agent]`) across the same repositories.

**Implementation:**

```bash
# Get bot username first
BOT_USER=$(gh api user --jq .login)

# For each repo, query bot's documentation PRs
gh pr list --repo openshift-online/<repo> \
  --author "${BOT_USER}" \
  --search "[docs-agent]" \
  --state all \
  --limit 100 \
  --json number,title,state,createdAt,mergedAt
```

**Filter to last 7 days:**

- Count PRs created in the last 7 days (regardless of state)
- Count how many are currently open
- Count how many were merged in the last 7 days

**If no doc PRs exist:** Report "No documentation PRs this week."

### 6. Channel response

Post the report as your channel response. Format:

```text
:fyi: *ROSA HyperFleet CI Weekly Status ({MM/DD})*

*Jira Progress:*
<https://issues.redhat.com/browse/%EPIC_KEY%|*%EPIC_KEY%*>: %X%% (%CLOSED%/%TOTAL% closed, %IN_PROGRESS% in progress)
{other active epics with similar format}

*Job Health (past 7 days):*
:large_green_circle: %JOB%: %RATE%%
:large_yellow_circle: %JOB%: %RATE%%
:red_circle: %JOB%: %RATE%%
{job with no builds}: no builds in last 7 days

*7-Day Trend:*
              Mon13 Tue14 Wed15 Thu16 Fri17 Sat18 Sun19
ephemeral:     ✅    ✅    ✅    ✅    ✅    ✅    ✅   7/7 (100%)
integration:   ✅    ✅    ❌    ✅    ✅    ❌    ✅   5/7 (71%)

*Overall Trend:* %TREND_EMOJI% %TREND_DESCRIPTION%

*Documentation:*
:robot_face: %N% doc PRs created this week, %OPEN% open, %MERGED% merged

*Key activity this week:*
- %DESCRIPTION% (<%PR_URL%|#%NUMBER%>)
- %DESCRIPTION% (<%PR_URL%|#%NUMBER%>)
- %N% PRs in review: %LIST_WITH_LINKS%
```

### Formatting rules

**Job health section:**

- Group jobs by health tier (:large_green_circle: first, then :large_yellow_circle:, then :red_circle:)
- Show per-job pass rates
- For jobs with 0 builds in the window, list them separately at the end
- Thresholds: :large_green_circle: 80%+, :large_yellow_circle: 40-79%, :red_circle: below 40%
- Note if the latest run is failing for a job that otherwise has a good rate (e.g., "87%, latest failing")

**7-Day trend table:**

- Same format as the daily health report trend table
- Use MonDD date headers (e.g., Jun13, Jun14, Jun19)
- Show only runs from the past 7 days (may be fewer than 7 runs if jobs don't run daily)
- Use concise job names: "ephemeral" and "integration"
- ✅ for passed, ❌ for failed
- Pass count and percentage at the end of each row
- Use monospace/code block formatting for alignment

**Overall trend section:**

- Compare this week's pass rate to the previous week (8-14 days ago) for each job
- Trend emoji and description:
  - :chart_with_upwards_trend: "Improving" — this week's overall pass rate is higher than last week
  - :chart_with_downwards_trend: "Degrading" — this week's overall pass rate is lower than last week
  - :left_right_arrow: "Stable" — pass rates are roughly the same (within 5% difference)
  - :new: "New data" — no previous week data available for comparison
- Include per-job comparison: "ephemeral: 100% (prev: 85%), integration: 71% (prev: 90%)"
- If a job had no builds in one of the weeks, note it

**Documentation section:**

- Single line summary: `N doc PRs created this week, X open, Y merged`
- If no doc PRs created this week: `:robot_face: No documentation PRs this week`
- Count only PRs with `[docs-agent]` prefix authored by the bot
- "Created this week" = PRs created in last 7 days (regardless of current state)
- "Open" = currently open PRs (created any time, still open now)
- "Merged" = PRs merged in last 7 days

**Key activity section:**

- Include merged PRs and notable open PRs
- Link PRs as `(<url|#number>)` or `(<url|repo #number>)` for cross-repo
- Group related PRs when it makes sense (e.g., "3 API enhancement PRs in review: ...")
- Keep descriptions brief, one line each
- **Do not include bot's [docs-agent] PRs here** - they're already in the Documentation section

**Overall:**

- Keep the entire report in one message (no threaded replies for the weekly status)
- Use Slack `mrkdwn` formatting
- The report should be scannable in 30 seconds

## Constraints

- Use ALL builds from the last 7 days for pass rates, filtered by date. Do not use a fixed build count.
- Always produce a report, even if all jobs are healthy.
- Verify PR merge status before claiming "merged."
