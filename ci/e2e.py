#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = ["boto3", "PyYAML"]
# ///
"""
E2E Test Orchestrator for ROSA Regional Platform.

Full lifecycle: provision -> test -> teardown -> cleanup.
See docs/design/testing-strategy.md for the broader testing strategy.
"""

import argparse
import logging
import os
import re
import sys
from pathlib import Path

# Allow importing e2elib as a sibling package
sys.path.insert(0, str(Path(__file__).parent))

from e2elib.orchestrator import E2EOrchestrator

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


def main():
    parser = argparse.ArgumentParser(description="E2E test orchestrator for ROSA Regional Platform")
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

    orchestrator = E2EOrchestrator(
        repo=repo,
        branch=args.branch,
        creds_dir=args.creds_dir,
        region=args.region,
    )

    try:
        orchestrator.run()
        log.info("")
        log.info("==========================================")
        log.info("E2E test completed successfully!")
        log.info("==========================================")
    except Exception:
        log.exception("E2E test failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
