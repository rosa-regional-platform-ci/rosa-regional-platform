---
theme: default
title: ROSA Regional Platform - Continuous Validation
info: |
  ## Milestone 2 Deliverable
  Continuous validation through pre-merge testing, nightly jobs, and a persistent integration environment.
class: text-center
highlighter: shiki
drawings:
  persist: false
transition: slide-left
mdc: true
---

# ROSA Regional Platform

[ROSA-667 - Milestone 2 - Continuous Validation](https://issues.redhat.com/browse/ROSA-667)

_Before building HCP lifecycle or customer-facing APIs, we invested in CI and testing. M2 establishes the testing foundation so that every change going forward is validated automatically._

---

# Evolution from Milestone 1

<div></div>

M1 used **manual Terraform**. Now, everything is **GitOps-driven** via [`deploy/`](https://github.com/openshift-online/rosa-regional-platform/tree/main/deploy).

- **ArgoCD** syncs [workloads](https://github.com/openshift-online/rosa-regional-platform/tree/main/argocd/config) to Regional / Management Clusters
- **[AWS CodePipelines](https://aws.amazon.com/codepipeline/)** handle infrastructure changes and new region/MC provisioning
- Every component (application or infra) that constitutes a region has a **defined version in Git**

---

# Architecture Overview

<div></div>

<img src="./diagrams/m2-architecture.png" alt="Integration environment architecture showing GitOps-driven provisioning pipelines deploying Regional and Management Cluster infrastructure" class="h-100 mx-auto" />

---

# Integration Environment

<div></div>

**Persistent environment** in `us-east-1`, consuming from `main` of [rosa-regional-platform](https://github.com/openshift-online/rosa-regional-platform) via **continuous delivery**.

```bash
awscurl --service execute-api --region us-east-1 https://api.us-east-1.int.rosa.devshift.net/v0/ready

{"status":"ok"}
```

API supports **Management Clusters** and **Manifest Works** CRUD with status feedback. See the [OpenAPI spec](https://api.us-east-1.int.rosa.devshift.net/).

---

# Testing Strategy

We test against two types of environments:

<div class="grid grid-cols-2 gap-8">
<div>

## Ephemeral

- Full region (RC + MC + all infra) **provisioned from scratch**, then **torn down**
- Not a simulation - **same CodePipeline** that will provision production

</div>
<div>

## Long-lived

- The **persistent Integration environment**
- Catches issues that only surface over time: **state drift**, **resource leaks**

</div>
</div>

---

# Pre-merge Validation (every PR)

All jobs run on **OpenShift CI** (Prow + ci-operator).

- `terraform-validate` - validates all Terraform root modules
- `helm-lint` - lints Helm charts
- `check-rendered-files` - verifies rendered deploy files are up to date
- `on-demand-e2e` - provisions an ephemeral environment, runs e2e tests, tears down (manual trigger via `/test on-demand-e2e`)

---

# Nightly Jobs

<div></div>

| Job | Runs the Testing Suite against |
|-----|-------------------------------|
| `nightly-ephemeral` | An ephemeral environment provisioned from `main` |
| `nightly-integration` | The long-lived Integration environment |

Weekly `ephemeral-resources-janitor` cleans up CI AWS accounts via `aws-nuke`.

<br/>

Results: [`nightly-ephemeral`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly-ephemeral) | [`nightly-integration`](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly-integration)

---

# [Testing Suite](https://github.com/openshift-online/rosa-regional-platform-api/tree/main/test/e2e)

<div></div>

Built with **Ginkgo**, reusable against **any environment**.

## Today

- **Platform API** e2e tests (Manifest Works lifecycle + status feedback)

<br/>

## Next

- **HCP lifecycle**: create, get, update, delete HostedClusters and NodePools
- **Workload validation**: deploy workloads into HCPs and verify they run
- **Customer-facing features**: log forwarding, zero egress, and more

---

# How Ephemeral Tests Work — Fork & Configure

Everything is **GitOps-driven** - CI clones the target branch into a **CI-owned fork** with an `e2e` environment definition.

<img src="./diagrams/provisioning-phase-1.png" alt="CI Environment Provider cloning target branch and pushing to CI-owned fork" class="h-70 mx-auto" />

---

# How Ephemeral Tests Work — Create Root Pipeline

A **root pipeline** is created that consumes the CI-owned fork for provisioning.

<img src="./diagrams/provisioning-phase-2.png" alt="CI-owned fork creating root pipeline for environment provisioning" class="h-70 mx-auto" />

---

# How Ephemeral Tests Work — Provisioned Environment

Environment spun up using **infrastructure and workload config from the original branch**. Testing Suite runs against it.

<img src="./diagrams/provisioning-phase-result.png" alt="Fully provisioned ephemeral test environment with Regional and Management Clusters" class="h-70 mx-auto" />

---

# How Ephemeral Tests Work — Teardown

Teardown is also **GitOps-driven**. `delete: true` is committed to the config, and pipelines tear down all infrastructure.

<img src="./diagrams/deprovisioning-phase-1.png" alt="CI Environment Provider committing delete:true to trigger teardown" class="h-70 mx-auto" />

---

# Pre-merge Tests for Component Repos

<div></div>

Our goal is to hook up ephemeral pre-merge tests to **every component repository** that constitutes the platform.

- Environment provisioned from `main` of rosa-regional-platform
- **Only your component is replaced** with the PR version
- Full Testing Suite runs against it

---

# Milestone 2 Complete - What's Next?

- **Sippy integration** ([TRT-2572](https://issues.redhat.com/browse/TRT-2572)) - test results dashboard for nightly jobs
- **Pre-merge tests** using ephemeral environments for more repos
- **Open up** the Integration environment for broader internal access

Next milestones:

- [ROSA-668 - HCPs Run on EKS MCs](https://issues.redhat.com/browse/ROSA-668) (M3)
- [ROSA-669 - Observability and Alerting](https://issues.redhat.com/browse/ROSA-669) (M4, RHOBS v2)
