# Metrics Pipeline Debugging Notes

## What we're building

MC Prometheus -> sigv4-proxy -> API GW (REST API v1) -> ALB -> thanos-receive (RC)

The API GW uses HTTP (non-proxy) integration for /api/v1/receive to inject THANOS-TENANT header from the verified SigV4 account ID (prevents tenant spoofing).

## Current state

- All infrastructure is deployed on ephemeral env `ci-757e09` on branch `poc-remote-write`
- The CI mirror branch is `ci-757e09-poc-remote-write-ci`
- API GW invoke URL: `https://mv4ht6v470.execute-api.us-east-1.amazonaws.com/prod`
- MC account: 855246887846, RC account: 599476212575

## What works

- sigv4-proxy deployment is running with correct `--host`, `--region`, `--strip-headers Content-Encoding` args
- Pod Identity credentials are injected correctly (via `AWS_CONTAINER_CREDENTIALS_FULL_URI`)
- SigV4 signing works — API GW accepts requests (no 403)
- Request routing through API GW -> ALB -> thanos-receive works
- thanos-receive is healthy and running on RC
- REST API v1 resource policy allows cross-account MC access
- `binary_media_types = ["application/x-protobuf"]` configured on API GW
- `content_handling = "CONVERT_TO_BINARY"` on thanos integration request and response

## Root cause: Content-Encoding: snappy → 415

REST API Gateway validates the `Content-Encoding` header against its supported list: **gzip, deflate, identity only** (per AWS docs). Prometheus remote_write sends `Content-Encoding: snappy`, which API GW rejects with 415 at the HTTP protocol level — before auth, before integration, before any content handling.

This is NOT fixable with `binary_media_types`, `CONVERT_TO_BINARY`, or any API GW configuration. The header validation is baked into the REST API v1 HTTP handling layer.

### Fix

Add `--strip-headers Content-Encoding` to the sigv4-proxy args. This strips the header **before** SigV4 signing, so the signature is computed without it and remains valid.

This is semantically correct: snappy compression is part of the Prometheus remote_write **application protocol**, not HTTP transport-level compression. Thanos Receive always expects snappy-compressed protobuf regardless of headers — it's the protocol default.

Commit: `76cb17e`

## HTTP API v2 attempt (reverted)

We tried creating a separate HTTP API v2 gateway for Thanos Receive (commit `de8ab3c`, reverted in `4bd45e0`). HTTP API v2 passes all content through natively (no Content-Encoding validation), and we confirmed:

- **200 from Thanos** with snappy-compressed protobuf through HTTP API v2 (auth disabled)
- Full pipeline worked: HTTP API v2 → VPC Link → ALB → Thanos Receive

However, **HTTP API v2 does not support cross-account IAM auth**:

- No resource policies (unlike REST API v1)
- MC account (855246887846) gets 403 even with `execute-api:Invoke` IAM policy
- AWS_IAM auth on HTTP API v2 requires same-account or cross-account role assumption
- Cross-account role assumption adds complexity (per-MC roles needed for tenant isolation)

**Decision**: Reverted to REST API v1 with `--strip-headers` fix. Simpler, cross-account works via resource policy.

## Future consideration: separate API Gateways

Platform API and Thanos Receive have different requirements:

| | Platform API | Thanos Receive |
|---|---|---|
| Access | Public (any AWS account) | Restricted (MC accounts only) |
| Traffic | Lower volume, JSON | High volume, binary protobuf |
| Auth model | AWS_IAM, app-layer authz | AWS_IAM + resource policy |

Currently both share one REST API v1. A future PR could split them:

- Platform API → HTTP API v2 (no resource policy needed, simpler)
- Thanos Receive → stays on REST API v1 (resource policy for cross-account)

## Verification steps (in progress)

> **Access notes**: Claude has AWS CLI access to the RC account (599476212575) where the API GW lives. Claude does NOT have kubectl access to either cluster — kubectl commands must be run manually by the user from the appropriate bastion/debug pod.

### Steps run from MC debug pod (user runs manually)

From the debug pod (MC cluster, prometheus namespace, sigv4-proxy service account):

**Step 1** — Confirm REST API v1 accepts request without Content-Encoding:
```bash
awscurl --service execute-api --region us-east-1 \
  -X POST \
  -H "Content-Type: application/x-protobuf" \
  -d 'test' \
  https://mv4ht6v470.execute-api.us-east-1.amazonaws.com/prod/api/v1/receive
```
Expect: `snappy decode error` (not 415, not 403)

**Step 2** — Send valid snappy-compressed protobuf:
```bash
python3 -c "
import snappy, struct, time
def encode_varint(v):
    r=b''
    while v>0x7f: r+=bytes([0x80|(v&0x7f)]); v>>=7
    r+=bytes([v]); return r
def encode_string(f,s):
    t=(f<<3)|2; e=s.encode(); return encode_varint(t)+encode_varint(len(e))+e
def encode_double(f,v):
    return encode_varint((f<<3)|1)+struct.pack('<d',v)
def encode_message(f,d):
    t=(f<<3)|2; return encode_varint(t)+encode_varint(len(d))+d
label=encode_string(1,'__name__')+encode_string(2,'test_metric')
ts_ms=int(time.time()*1000)
sample=encode_double(1,42.0)+encode_varint(2<<3|0)+encode_varint(ts_ms)
timeseries=encode_message(1,label)+encode_message(2,sample)
write_request=encode_message(1,timeseries)
import sys; sys.stdout.buffer.write(snappy.compress(write_request))
" > /tmp/write_request.snappy

awscurl --service execute-api --region us-east-1 \
  -X POST \
  -H "Content-Type: application/x-protobuf" \
  --data-binary @/tmp/write_request.snappy \
  https://mv4ht6v470.execute-api.us-east-1.amazonaws.com/prod/api/v1/receive
```
Expect: **200** from Thanos Receive

**Step 3** — Check Prometheus remote_write is working:
```bash
kubectl -n prometheus logs -l app.kubernetes.io/name=prometheus --tail=10 | grep -i "remote\|write\|error"
```
Expect: no 415 or 403 errors

### Steps run from RC account (Claude can run via AWS CLI)

**Step 4** — Check API GW configuration:
```bash
aws apigateway get-rest-api --rest-api-id mv4ht6v470 --region us-east-1
aws apigateway get-resources --rest-api-id mv4ht6v470 --region us-east-1
```

**Step 5** — Check API GW execution logs for recent requests:
```bash
aws logs filter-log-events --log-group-name API-Gateway-Execution-Logs_mv4ht6v470/prod --region us-east-1 --limit 20
```

## Other fixes applied in this session

- `da80869` — Handle empty api_url/aws_region in sigv4-proxy template (default to empty string)
- `ab00144` — Enable prometheus CRD installation on MC (HyperShift doesn't provide all monitoring CRDs)
- `09809cb` — Add api_url and thanosReceive to ApplicationSet Jinja2 template and re-render
- `a6210c0` — Fix pod identity output reference after rename to sigv4_proxy
- `8ff836b` — Add application/x-protobuf binary media type to API GW
- `1c1824c` — Trigger API GW redeployment when binary_media_types changes
- `de8ab3c` — Add separate HTTP API v2 gateway for Thanos Receive (reverted)
- `4bd45e0` — Revert HTTP API v2 approach
- `76cb17e` — Strip Content-Encoding header in sigv4-proxy

## Useful debug commands

From MC bastion / debug pod:
```bash
# Check sigv4-proxy args
kubectl -n prometheus get deploy sigv4-proxy -o jsonpath='{.spec.template.spec.containers[0].args}'

# Check sigv4-proxy logs
kubectl -n prometheus logs deploy/sigv4-proxy

# Check Prometheus remote_write errors
kubectl -n prometheus logs -l app.kubernetes.io/name=prometheus --tail=30 | grep -i remote

# Deploy debug pod with Pod Identity creds
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: debug
  namespace: prometheus
spec:
  serviceAccountName: sigv4-proxy
  containers:
    - name: debug
      image: python:3-slim
      command: ["sleep", "3600"]
EOF
# Then: pip install python-snappy cramjam
# Has: awscurl, aws cli, python3
```

From RC bastion:
```bash
# Check thanos-receive logs
kubectl -n thanos-receive logs deploy/thanos-receive

# Check ApplicationSet has api_url
kubectl -n argocd get applicationset root-applicationset -o yaml | grep api_url
```
