import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import crypto from "k6/crypto";

// ---------------------------------------------------------------------------
// AWS SigV4 signing helpers
// ---------------------------------------------------------------------------

function hmacSha256(key, message) {
  return crypto.hmac("sha256", key, message, "binary");
}

function sha256Hex(message) {
  return crypto.sha256(message, "hex");
}

function getSignatureKey(secretKey, dateStamp, region, service) {
  const kDate = hmacSha256("AWS4" + secretKey, dateStamp);
  const kRegion = hmacSha256(kDate, region);
  const kService = hmacSha256(kRegion, service);
  return hmacSha256(kService, "aws4_request");
}

function formatDate(d) {
  return d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

function signRequest(method, url, body, headers) {
  const accessKey = __ENV.AWS_ACCESS_KEY_ID;
  const secretKey = __ENV.AWS_SECRET_ACCESS_KEY;
  const sessionToken = __ENV.AWS_SESSION_TOKEN || "";
  const region = __ENV.AWS_DEFAULT_REGION || __ENV.AWS_REGION || "us-east-1";
  const service = "execute-api";

  const now = new Date();
  const amzDate = formatDate(now);
  const dateStamp = amzDate.substring(0, 8);

  const parsedUrl = new URL(url);
  const canonicalUri = parsedUrl.pathname || "/";
  const canonicalQueryString = parsedUrl.searchParams.toString();
  const host = parsedUrl.host;

  const payloadHash = sha256Hex(body || "");

  const signedHeaderNames = ["host", "x-amz-date"];
  if (sessionToken) {
    signedHeaderNames.push("x-amz-security-token");
  }
  if (headers["content-type"]) {
    signedHeaderNames.push("content-type");
  }
  signedHeaderNames.sort();

  const headerMap = {
    host: host,
    "x-amz-date": amzDate,
  };
  if (sessionToken) {
    headerMap["x-amz-security-token"] = sessionToken;
  }
  if (headers["content-type"]) {
    headerMap["content-type"] = headers["content-type"];
  }

  const canonicalHeaders =
    signedHeaderNames.map((h) => h + ":" + headerMap[h] + "\n").join("");
  const signedHeaders = signedHeaderNames.join(";");

  const canonicalRequest = [
    method,
    canonicalUri,
    canonicalQueryString,
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join("\n");

  const credentialScope = [dateStamp, region, service, "aws4_request"].join(
    "/",
  );
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    credentialScope,
    sha256Hex(canonicalRequest),
  ].join("\n");

  const signingKey = getSignatureKey(secretKey, dateStamp, region, service);
  const signature = crypto.hmac("sha256", signingKey, stringToSign, "hex");

  const authHeader =
    `AWS4-HMAC-SHA256 Credential=${accessKey}/${credentialScope}, ` +
    `SignedHeaders=${signedHeaders}, Signature=${signature}`;

  const result = Object.assign({}, headers);
  result["Authorization"] = authHeader;
  result["x-amz-date"] = amzDate;
  if (sessionToken) {
    result["x-amz-security-token"] = sessionToken;
  }
  return result;
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const BASE_URL = __ENV.BASE_URL;
if (!BASE_URL) {
  throw new Error("BASE_URL environment variable is required");
}

// Gate mutating operations: only run creates when LOAD_TEST_MUTATE is set
// (e.g. in ephemeral CI environments). Prevents resource leaks in standing envs.
const MUTATE = !!__ENV.LOAD_TEST_MUTATE;

const errorRate = new Rate("errors");
const healthLatency = new Trend("health_latency", true);
const listLatency = new Trend("list_mc_latency", true);
const createLatency = new Trend("create_mc_latency", true);
const workLatency = new Trend("work_post_latency", true);
const deleteLatency = new Trend("delete_mc_latency", true);

export const options = {
  stages: [
    { duration: "2m", target: 50 },
    { duration: "10m", target: 50 },
    { duration: "1m", target: 0 },
  ],
  thresholds: {
    http_req_duration: ["p(99)<5000"],
    errors: ["rate<0.01"],
  },
};

// ---------------------------------------------------------------------------
// Test scenarios
// ---------------------------------------------------------------------------

function signedGet(path) {
  const url = `${BASE_URL}${path}`;
  const headers = signRequest("GET", url, "", {});
  return http.get(url, { headers });
}

function signedPost(path, body) {
  const url = `${BASE_URL}${path}`;
  const hdrs = { "content-type": "application/json" };
  const signed = signRequest("POST", url, body, hdrs);
  return http.post(url, body, { headers: signed });
}

function signedDelete(path) {
  const url = `${BASE_URL}${path}`;
  const headers = signRequest("DELETE", url, "", {});
  return http.del(url, null, { headers });
}

export default function () {
  // Health check (lightweight, fast)
  {
    const res = signedGet("/prod/v0/live");
    healthLatency.add(res.timings.duration);
    const ok = check(res, {
      "health: status 200": (r) => r.status === 200,
    });
    errorRate.add(!ok);
  }

  // List management clusters
  {
    const res = signedGet("/prod/api/v0/management_clusters");
    listLatency.add(res.timings.duration);
    const ok = check(res, {
      "list MCs: status 200": (r) => r.status === 200,
    });
    errorRate.add(!ok);
  }

  // Create management cluster (only in ephemeral/CI environments)
  if (MUTATE) {
    const name = `load-test-mc-${__VU}-${__ITER}`;
    const body = JSON.stringify({
      name: name,
      labels: { cluster_type: "management", test: "load" },
    });
    const res = signedPost("/prod/api/v0/management_clusters", body);
    createLatency.add(res.timings.duration);
    const ok = check(res, {
      "create MC: status 2xx or conflict": (r) =>
        (r.status >= 200 && r.status < 300) || r.status === 409,
    });
    errorRate.add(!ok);

    // Cleanup: delete the created MC
    const delRes = signedDelete(
      `/prod/api/v0/management_clusters/${name}`,
    );
    deleteLatency.add(delRes.timings.duration);
    check(delRes, {
      "delete MC: status 2xx or 404": (r) =>
        (r.status >= 200 && r.status < 300) || r.status === 404,
    });
  }

  // List resource bundles
  {
    const res = signedGet("/prod/api/v0/resource_bundles");
    const ok = check(res, {
      "list bundles: status 200": (r) => r.status === 200,
    });
    errorRate.add(!ok);
  }

  // Post ManifestWork (only in ephemeral/CI environments)
  if (MUTATE) {
    const timestamp = Date.now();
    const workName = `load-test-work-${__VU}-${__ITER}-${timestamp}`;
    const payload = JSON.stringify({
      cluster_id: "mc01",
      data: {
        apiVersion: "work.open-cluster-management.io/v1",
        kind: "ManifestWork",
        metadata: { name: workName },
        spec: {
          workload: {
            manifests: [
              {
                apiVersion: "v1",
                kind: "ConfigMap",
                metadata: {
                  name: "load-test-payload",
                  namespace: "default",
                },
                data: { test_id: `${timestamp}`, source: "k6-load-test" },
              },
            ],
          },
        },
      },
    });
    const res = signedPost("/prod/api/v0/work", payload);
    workLatency.add(res.timings.duration);
    const ok = check(res, {
      "post work: status 2xx": (r) => r.status >= 200 && r.status < 300,
    });
    errorRate.add(!ok);
  }

  sleep(1);
}
