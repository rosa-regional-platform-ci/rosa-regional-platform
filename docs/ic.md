# ROSA Regional Platform IC

This document describes the ROSA Regional Platform IC (Interrupt Catcher) process.

## Overview

The IC is the weekly point person for operational interrupts on the ROSA Regional Platform team. The role aims to keep the underlying infrastructure stable and prevent the team from accruing technical debt.

There is no expectation for the IC to be available outside of Business Hours. The IC should review and address their responsibilities at the start of each day.

This role should not prevent the IC from working on their project tasks. If the workload becomes overwhelming, reach out to the team for help.

## Responsibilities

The IC is responsible for the following tasks:

- Ensure that the CI jobs are running correctly, in particular:
    - [Nightly Ephemeral](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly-ephemeral)
    - [Nightly Integration](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly-integration)
    - [On-demand E2E](https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-openshift-online-rosa-regional-platform-main-on-demand-e2e). Note that only consistent failures are the IC's responsibility, as opposed to one-off failures caused by the PR under test.
- Work on items in [ROSAENG-140 - Technical Debt and Continuous Improvement of RRP](https://redhat.atlassian.net/browse/ROSAENG-140). This Epic should only contain urgent tasks.

## Rotation

The rotation is managed through PagerDuty:

- [RRP NonProd Schedule](https://redhat.pagerduty.com/schedules/PY55DT7)
- [RRP Non-Production Team](https://redhat.pagerduty.com/teams/P1A9WNI)

If you are unable to take your shift, please trade it with another team member and create the necessary overrides in PagerDuty.
