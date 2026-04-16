#!/usr/bin/env python3
"""Compare k6 load test results against a baseline stored in S3.

Reads the k6 JSON summary from the current run, downloads the previous
baseline from S3, compares key metrics, and fails if any metric regresses
beyond a configurable threshold.

On success, uploads the current run as the new baseline.

Usage:
    python3 compare-baseline.py \
        --results platform-api-summary.json \
        --bucket rosa-ci-artifacts \
        --key load-test-baselines/latest.json \
        --threshold 20
"""

import argparse
import json
import logging
import sys
import tempfile
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

# Metrics to compare: (json_path, display_name, direction)
# direction: "lower_is_better" means regression = current > baseline
METRICS = [
    ("metrics.http_req_duration.values.p(95)", "p95 latency (ms)", "lower_is_better"),
    ("metrics.http_req_duration.values.p(99)", "p99 latency (ms)", "lower_is_better"),
    ("metrics.errors.values.rate", "error rate", "lower_is_better"),
    ("metrics.http_reqs.values.rate", "requests/sec", "higher_is_better"),
]


def extract_metric(data: dict, path: str) -> float | None:
    """Extract a nested metric value using dot-separated path."""
    keys = path.split(".")
    current = data
    for key in keys:
        # Handle k6 summary keys that contain parentheses like "p(95)"
        if isinstance(current, dict) and key in current:
            current = current[key]
        else:
            return None
    if isinstance(current, (int, float)):
        return float(current)
    return None


def compare(
    current: dict,
    baseline: dict,
    threshold_pct: float,
) -> tuple[bool, list[str]]:
    """Compare current results against baseline.

    Returns (passed, messages) where passed is True if no regression
    exceeds the threshold.
    """
    passed = True
    messages = []

    for path, name, direction in METRICS:
        cur_val = extract_metric(current, path)
        base_val = extract_metric(baseline, path)

        if cur_val is None:
            messages.append(f"  {name}: SKIP (not found in current results)")
            continue
        if base_val is None:
            messages.append(f"  {name}: SKIP (not found in baseline)")
            continue
        if base_val == 0:
            messages.append(f"  {name}: SKIP (baseline is zero)")
            continue

        if direction == "lower_is_better":
            change_pct = ((cur_val - base_val) / base_val) * 100
            regressed = change_pct > threshold_pct
        else:
            # higher_is_better: regression means current is lower
            change_pct = ((base_val - cur_val) / base_val) * 100
            regressed = change_pct > threshold_pct

        status = "REGRESSION" if regressed else "OK"
        if regressed:
            passed = False

        messages.append(
            f"  {name}: {base_val:.2f} -> {cur_val:.2f} "
            f"({change_pct:+.1f}%) [{status}]"
        )

    return passed, messages


def main():
    parser = argparse.ArgumentParser(description="Compare k6 results against S3 baseline")
    parser.add_argument("--results", required=True, help="Path to k6 summary JSON")
    parser.add_argument("--bucket", required=True, help="S3 bucket for baselines")
    parser.add_argument("--key", required=True, help="S3 key for baseline JSON")
    parser.add_argument(
        "--threshold",
        type=float,
        default=20.0,
        help="Regression threshold percentage (default: 20)",
    )
    args = parser.parse_args()

    # Load current results
    results_path = Path(args.results)
    if not results_path.exists():
        log.error("Results file not found: %s", results_path)
        sys.exit(1)

    with open(results_path) as f:
        current = json.load(f)

    log.info("Loaded current results from %s", results_path)

    # Download baseline from S3
    import boto3
    from botocore.exceptions import ClientError

    s3 = boto3.client("s3")
    try:
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
            s3.download_file(args.bucket, args.key, tmp.name)
            with open(tmp.name) as f:
                baseline = json.load(f)
        log.info("Downloaded baseline from s3://%s/%s", args.bucket, args.key)
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "")
        if error_code in ("404", "NoSuchKey"):
            log.info("No baseline found in S3 — saving current as initial baseline")
            try:
                s3.put_object(
                    Bucket=args.bucket,
                    Key=args.key,
                    Body=json.dumps(current, indent=2),
                    ContentType="application/json",
                )
                log.info("Saved initial baseline to s3://%s/%s", args.bucket, args.key)
            except Exception as upload_err:
                log.error("Failed to upload initial baseline: %s", upload_err)
                sys.exit(1)
            sys.exit(0)
        else:
            log.error("S3 error downloading baseline: %s", e)
            sys.exit(1)
    except json.JSONDecodeError as e:
        log.error("Failed to parse baseline JSON from s3://%s/%s: %s", args.bucket, args.key, e)
        sys.exit(1)
    except Exception as e:
        log.error("Unexpected error downloading baseline: %s", e)
        sys.exit(1)

    # Compare
    log.info("Comparing against baseline (threshold: %.0f%%):", args.threshold)
    passed, messages = compare(current, baseline, args.threshold)
    for msg in messages:
        log.info(msg)

    if passed:
        log.info("All metrics within threshold — updating baseline")
        try:
            s3.put_object(
                Bucket=args.bucket,
                Key=args.key,
                Body=json.dumps(current, indent=2),
                ContentType="application/json",
            )
            log.info("Baseline updated at s3://%s/%s", args.bucket, args.key)
        except Exception as e:
            log.warning("Failed to update baseline: %s", e)
    else:
        log.error("REGRESSION DETECTED — baseline NOT updated")
        sys.exit(1)


if __name__ == "__main__":
    main()
