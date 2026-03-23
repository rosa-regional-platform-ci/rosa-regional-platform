# CI Known Issues

This file is the self-learning knowledge base for the ci-troubleshoot agent. Each entry represents a confirmed failure pattern that has been validated by a human reviewer.

When diagnosing a new failure, check these patterns first for a quick match before doing deep investigation.

## Format

Each entry follows this structure:

```
### <Short Title>
- **Pattern**: <What to look for in logs/artifacts>
- **Root Cause**: <Why it happens>
- **Fix**: <How to resolve>
- **Files**: <Relevant source files>
- **First Seen**: <Date and PR/job link>
```

---

### RC/MC Pipeline Race Condition — Platform API Not Ready

- **Pattern**: `API Gateway /live did not return 200 after N attempts` or HTTP 503 from API Gateway during MC `register` step
- **Root Cause**: RC and MC CodePipelines run in parallel. The MC pipeline's `Register` stage calls the Platform API via the RC's API Gateway, but the Platform API pod hasn't been deployed yet because the RC pipeline's ArgoCD bootstrap hasn't completed (or ArgoCD hasn't finished syncing the Platform API app). The ALB target group at port 8080 has no healthy targets.
- **Fix**: Increase `MAX_RETRIES` in `scripts/buildspec/register.sh` (e.g., from 10 to 30 for ~15 min patience), or add an ArgoCD sync-wait to the RC bootstrap script, or add pipeline ordering in `ci/ephemerallib/ephemeral.py`.
- **Files**: `scripts/buildspec/register.sh` (health check retry logic), `ci/ephemerallib/ephemeral.py` (`_wait_for_provision` runs RC/MC in parallel), `terraform/config/pipeline-management-cluster/main.tf` (MC pipeline stages)
- **First Seen**: 2026-03-17, PR #191 `on-demand-e2e` [job link](https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/openshift-online_rosa-regional-platform/191/pull-ci-openshift-online-rosa-regional-platform-main-on-demand-e2e/2033939688007405568)

---

### Maestro-Agent Disconnection in Integration Environment

- **Pattern**: `nightly-integration` fails on `[It] should have maestro-server connected to maestro-agent`. The test finds the ResourceBundle in the API (prints `resource_bundle id=... name=... consumer_name=mc01`) but conditions (Applied, Available, StatusFeedbackSynced) are never set after 5 minutes of polling. Previous runs on identical code succeed quickly (~5s), confirming connectivity was working until recently and this is not a code regression.
- **Root Cause**: The `maestro-agent` pod on the `mc01` management cluster lost its MQTT connection to AWS IoT Core (the maestro-server's broker). This is an infrastructure event in the persistent integration environment — not a code regression. Typical triggers: (1) an EKS node replacement causing the pod to restart and fail to reconnect, (2) the ASCP CSI driver failing to re-mount the IoT certificate from Secrets Manager, or (3) a transient IoT Core connectivity event that left the agent disconnected. Because the integration environment is persistent and not rebuilt between nightly runs, a single agent failure blocks every subsequent nightly run until manually resolved.
- **Fix**: An operator must log into the `mc01` management cluster and diagnose:
  1. `kubectl -n maestro-agent get pods` — look for CrashLoopBackOff, Pending, or Error
  2. `kubectl -n maestro-agent logs deploy/maestro-agent` — check for MQTT authentication or connect errors
  3. If the pod is healthy but disconnected: `kubectl -n maestro-agent rollout restart deploy/maestro-agent`
  4. If the pod fails to mount secrets (ASCP CSI errors): re-run the MC `provision-infra` CodePipeline stage to refresh `mc01-maestro-agent-cert` and `mc01-maestro-agent-config` in Secrets Manager, then restart the pod.
  5. If the IoT certificate was deactivated or lost: re-run the `iot-mint` CodePipeline stage (in the RC account) to issue a new certificate, then re-run `provision-infra-mc` to push the new cert to Secrets Manager.
- **Files**: `scripts/buildspec/iot-mint.sh` (IoT certificate provisioning), `scripts/buildspec/provision-infra-mc.sh` (pushes cert/config to MC Secrets Manager), `argocd/config/management-cluster/maestro-agent/templates/secretproviderclass.yaml` (ASCP CSI secret mount), `terraform/modules/maestro-agent/main.tf` (Secrets Manager secret creation), `terraform/modules/maestro-agent-iot-provisioning/main.tf` (IoT cert and policy)
- **First Seen**: 2026-03-23, `nightly-integration` [job link](https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-openshift-online-rosa-regional-platform-main-nightly-integration/2035975039924310016)
