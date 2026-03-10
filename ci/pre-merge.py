#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = ["boto3", "PyYAML"]
# ///
"""
Pre-merge CI runner for ROSA Regional Platform.

Provisions an ephemeral environment or tears one down. Designed for multi-step
CI pipelines where provision, tests, and teardown are separate steps:

    # Step 1: Provision
    BUILD_ID=abc123 ./pre-merge.py

    # Step 2: Run tests (separate CI step, same BUILD_ID)

    # Step 3: Teardown
    BUILD_ID=abc123 ./pre-merge.py --teardown

If BUILD_ID is not set, a random ID is generated and printed so it can be
passed to subsequent steps.
"""

import argparse
import hashlib
import logging
import os
import re
import sys
import uuid
from pathlib import Path

import boto3

# Allow importing ephemerallib as a sibling package
sys.path.insert(0, str(Path(__file__).parent))

from ephemerallib.ephemeral import EphemeralEnvOrchestrator

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


def make_ci_prefix() -> str:
    """Generate a CI prefix from BUILD_ID (hashed) or a random UUID.

    BUILD_ID is hashed to avoid collisions between consecutive IDs, then
    truncated to 6 characters for AWS resource name compatibility.
    """
    build_id = os.environ.get("BUILD_ID", "")
    if build_id:
        # Hash the BUILD_ID to avoid collisions with consecutive IDs
        hash_digest = hashlib.sha256(build_id.encode()).hexdigest()
        short_id = hash_digest[:6]
    else:
        short_id = uuid.uuid4().hex[:6]
    return f"ci-{short_id}"


def main():
    parser = argparse.ArgumentParser(description="Pre-merge CI runner for ROSA Regional Platform")
    parser.add_argument(
        "--teardown",
        action="store_true",
        help="Tear down a previously provisioned ephemeral environment",
    )
    parser.add_argument(
        "--repo",
        default=os.environ.get("REPOSITORY_URL", "openshift-online/rosa-regional-platform"),
        help="GitHub repository in owner/name format (default: from REPOSITORY_URL env var)",
    )
    parser.add_argument(
        "--branch",
        default=os.environ.get("REPOSITORY_BRANCH", "main"),
        help="Source branch to test (default: from REPOSITORY_BRANCH env var)",
    )
    parser.add_argument(
        "--creds-dir",
        default=os.environ.get("CREDS_DIR", "/var/run/rosa-credentials/"),
        help="Directory containing CI credentials (default: /var/run/rosa-credentials/)",
    )
    parser.add_argument(
        "--region",
        default=os.environ.get("AWS_REGION", "us-east-1"),
        help="AWS region (default: us-east-1)",
    )
    args = parser.parse_args()

    # Normalize repo format (strip github.com prefix and .git suffix if present)
    repo = re.sub(r".*github\.com/", "", args.repo)
    repo = re.sub(r"\.git$", "", repo)

    if args.teardown and not os.environ.get("BUILD_ID"):
        log.error("BUILD_ID must be set for --teardown (needed to identify the ephemeral environment)")
        sys.exit(1)

    ci_prefix = make_ci_prefix()
    log.info("CI prefix: %s", ci_prefix)

    env = EphemeralEnvOrchestrator(
        repo=repo,
        branch=args.branch,
        creds_dir=args.creds_dir,
        region=args.region,
        ci_prefix=ci_prefix,
    )

    try:
        if args.teardown:
            env.teardown()
            log.info("")
            log.info("==========================================")
            log.info("Teardown completed successfully!")
            log.info("==========================================")
        else:
            env.provision()
            log.info("")
            log.info("==========================================")
            log.info("Provisioning completed successfully!")
            log.info("==========================================")

            log.info("")
            log.info("==========================================")
            log.info("Assuming role into the regional account to query API Gateway")
            log.info("==========================================")
            # Assume role into the regional account to query API Gateway
            env.aws.setup_target_account_via_assume_role("regional")
            # Discover the API Gateway URL and write it to SHARED_DIR so the
            # test step can pick it up.
            shared_dir = os.environ.get("SHARED_DIR")
            if shared_dir:
                try:
                    # Use the regional session to query API Gateway
                    client = env.aws.session.client("apigateway", region_name=args.region)
                    response = client.get_rest_apis()

                    # Find the first API Gateway whose name starts with 'regional-cluster-'
                    api_id = None
                    for api in response.get("items", []):
                        if api["name"].startswith("regional-cluster-"):
                            api_id = api["id"]
                            break

                    if api_id:
                        api_url = f"https://{api_id}.execute-api.{args.region}.amazonaws.com/prod"
                        api_url_file = Path(shared_dir) / "api-url"
                        api_url_file.write_text(api_url)
                        log.info("API Gateway URL written to %s", api_url_file)
                    else:
                        log.warning("No API Gateway found with name starting with 'regional-cluster-'")
                except Exception as e:
                    log.warning("Failed to discover API Gateway URL: %s", e)

            if not os.environ.get("BUILD_ID"):
                log.info("")
                log.info("BUILD_ID was not set — a random ID was used.")
                log.info("To tear down this environment, run:")
                log.info("")
                log.info("    BUILD_ID=%s ./pre-merge.py --teardown", ci_prefix.removeprefix("ci-"))
                log.info("")
    except Exception:
        log.exception("Pre-merge %s failed", "teardown" if args.teardown else "provision")
        sys.exit(1)


if __name__ == "__main__":
    main()
