import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import crypto from "k6/crypto";

// ---------------------------------------------------------------------------
// AWS SigV4 signing (same implementation as platform-api-load.js)
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

// Number of concurrent HCP creates per VU
const HCP_COUNT = parseInt(__ENV.HCP_COUNT || "5", 10);

const createHcpLatency = new Trend("create_hcp_latency", true);
const listHcpLatency = new Trend("list_hcp_latency", true);
const errorRate = new Rate("errors");

export const options = {
  // Run with a small number of VUs — each VU creates HCP_COUNT clusters
  scenarios: {
    hcp_lifecycle: {
      executor: "per-vu-iterations",
      vus: 3,
      iterations: 1,
      maxDuration: "30m",
    },
  },
  thresholds: {
    errors: ["rate<0.05"],
    create_hcp_latency: ["p(95)<10000"],
  },
};

// ---------------------------------------------------------------------------
// Helpers
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

// ---------------------------------------------------------------------------
// Test: concurrent HCP lifecycle (create N clusters, poll, verify)
// ---------------------------------------------------------------------------

export default function () {
  const clusterNames = [];
  const timestamp = Date.now();

  // Phase 1: Create N management clusters concurrently via http.batch
  console.log(
    `VU ${__VU}: Creating ${HCP_COUNT} management clusters concurrently`,
  );

  const requests = [];
  for (let i = 0; i < HCP_COUNT; i++) {
    const name = `hcp-load-${__VU}-${i}-${timestamp}`;
    clusterNames.push(name);

    const body = JSON.stringify({
      name: name,
      labels: {
        cluster_type: "management",
        test: "hcp-lifecycle-load",
        vu: `${__VU}`,
        index: `${i}`,
      },
    });

    const url = `${BASE_URL}/prod/api/v0/management_clusters`;
    const hdrs = { "content-type": "application/json" };
    const signed = signRequest("POST", url, body, hdrs);
    requests.push(["POST", url, body, { headers: signed }]);
  }

  const responses = http.batch(requests);
  for (let i = 0; i < responses.length; i++) {
    const res = responses[i];
    createHcpLatency.add(res.timings.duration);

    const ok = check(res, {
      [`create HCP ${i}: status 2xx`]: (r) =>
        r.status >= 200 && r.status < 300,
    });
    errorRate.add(!ok);

    if (!ok) {
      console.error(
        `VU ${__VU}: Failed to create cluster ${clusterNames[i]}: ${res.status} ${res.body}`,
      );
    }
  }

  // Phase 2: Poll management clusters list to verify all appear
  console.log(`VU ${__VU}: Polling for ${clusterNames.length} clusters`);

  const maxAttempts = 20;
  const pollInterval = 15; // seconds

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const res = signedGet("/prod/api/v0/management_clusters");
    listHcpLatency.add(res.timings.duration);

    if (res.status === 200) {
      const body = JSON.parse(res.body);
      const items = body.items || [];
      const found = clusterNames.filter((name) =>
        items.some((item) => item.name === name || item.metadata?.name === name),
      );

      if (found.length === clusterNames.length) {
        console.log(
          `VU ${__VU}: All ${clusterNames.length} clusters visible after ${attempt + 1} polls`,
        );
        break;
      }

      console.log(
        `VU ${__VU}: ${found.length}/${clusterNames.length} clusters visible (attempt ${attempt + 1}/${maxAttempts})`,
      );
    }

    sleep(pollInterval);
  }

  // Fail the VU if not all clusters became visible
  {
    const res = signedGet("/prod/api/v0/management_clusters");
    let finalFound = 0;
    if (res.status === 200) {
      const body = JSON.parse(res.body);
      const items = body.items || [];
      finalFound = clusterNames.filter((name) =>
        items.some((item) => item.name === name || item.metadata?.name === name),
      ).length;
    }
    if (finalFound !== clusterNames.length) {
      console.error(
        `VU ${__VU}: Only ${finalFound}/${clusterNames.length} clusters visible after ${maxAttempts} polls`,
      );
      errorRate.add(true);
    }
  }

  // Phase 3: Post ManifestWork to each cluster to validate Maestro distribution
  console.log(`VU ${__VU}: Posting ManifestWork to each cluster`);

  for (const clusterName of clusterNames) {
    const payload = JSON.stringify({
      cluster_id: clusterName,
      data: {
        apiVersion: "work.open-cluster-management.io/v1",
        kind: "ManifestWork",
        metadata: {
          name: `hcp-load-work-${__VU}-${timestamp}`,
        },
        spec: {
          workload: {
            manifests: [
              {
                apiVersion: "v1",
                kind: "ConfigMap",
                metadata: {
                  name: "hcp-load-test",
                  namespace: "default",
                },
                data: {
                  source: "k6-hcp-lifecycle",
                  cluster: clusterName,
                },
              },
            ],
          },
        },
      },
    });

    const res = signedPost("/prod/api/v0/work", payload);
    const ok = check(res, {
      [`post work to ${clusterName}: 2xx`]: (r) =>
        r.status >= 200 && r.status < 300,
    });
    errorRate.add(!ok);
  }

  console.log(`VU ${__VU}: HCP lifecycle test complete`);
}
