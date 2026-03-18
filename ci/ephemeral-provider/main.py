#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = ["boto3", "PyYAML"]
# ///
"""
Ephemeral environment manager for ROSA Regional Platform CI.

Provisions an ephemeral environment or tears one down. Designed for multi-step
CI pipelines where provision, tests, and teardown are separate steps:

    # Step 1: Provision
    BUILD_ID=abc123 ./ci/ephemeral-provider/main.py

    # Step 2: Run tests (separate CI step, same BUILD_ID)

    # Step 3: Teardown
    BUILD_ID=abc123 ./ci/ephemeral-provider/main.py --teardown

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

from git import GitManager
from orchestrator import EphemeralEnvOrchestrator

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
    parser = argparse.ArgumentParser(description="Ephemeral environment manager for ROSA Regional Platform")
    teardown_group = parser.add_mutually_exclusive_group()
    teardown_group.add_argument(
        "--teardown",
        action="store_true",
        help="Tear down a previously provisioned ephemeral environment",
    )
    teardown_group.add_argument(
        "--teardown-fire-and-forget",
        action="store_true",
        help="Start teardown and exit immediately without waiting for completion",
    )
    teardown_group.add_argument(
        "--resync",
        action="store_true",
        help="Resync the CI branch by rebasing onto the latest source branch",
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
    parser.add_argument(
        "--save-regional-state",
        metavar="PATH",
        help="Save RC terraform outputs (JSON) to PATH after provisioning",
    )
    args = parser.parse_args()

    # Normalize repo format (strip github.com prefix and .git suffix if present)
    repo = re.sub(r".*github\.com/", "", args.repo)
    repo = re.sub(r"\.git$", "", repo)

    is_teardown = args.teardown or args.teardown_fire_and_forget

    if (is_teardown or args.resync) and not os.environ.get("BUILD_ID"):
        log.error("BUILD_ID must be set for %s (needed to identify the ephemeral environment)",
                   "resync" if args.resync else "teardown")
        sys.exit(1)

    ci_prefix = make_ci_prefix()
    log.info("CI prefix: %s", ci_prefix)

    if args.resync:
        try:
            git = GitManager(creds_dir=args.creds_dir, repo=repo, branch=args.branch)
            git.resync_ci_branch(ci_prefix)
            log.info("")
            log.info("==========================================")
            log.info("Resync completed successfully!")
            log.info("==========================================")
        except Exception:
            log.exception("Ephemeral environment resync failed")
            sys.exit(1)
        return

    env = EphemeralEnvOrchestrator(
        repo=repo,
        branch=args.branch,
        creds_dir=args.creds_dir,
        region=args.region,
        ci_prefix=ci_prefix,
    )

    try:
        if is_teardown:
            env.teardown(fire_and_forget=args.teardown_fire_and_forget)
            log.info("")
            log.info("==========================================")
            log.info("Teardown completed successfully!")
            log.info("==========================================")
        else:
            env.provision(save_state=args.save_regional_state)
            log.info("")
            log.info("==========================================")
            log.info("Provisioning completed successfully!")
            log.info("==========================================")
            if not os.environ.get("BUILD_ID"):
                log.info("")
                log.info("BUILD_ID was not set — a random ID was used.")
                log.info("To tear down this environment, run:")
                log.info("")
                log.info("    BUILD_ID=%s ./ci/ephemeral-provider/main.py --teardown", ci_prefix.removeprefix("ci-"))
                log.info("")
    except Exception:
        log.exception("Ephemeral environment %s failed", "teardown" if is_teardown else "provision")
        sys.exit(1)


if __name__ == "__main__":
    main()
