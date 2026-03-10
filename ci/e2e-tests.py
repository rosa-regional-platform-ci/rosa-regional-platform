#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = ["boto3", "PyYAML"]
# ///
"""
E2E test runner for ROSA Regional Platform.

Runs end-to-end API tests from rosa-regional-platform-api against the
provisioned environment. Expects SHARED_DIR/api-url to exist (written by
pre-merge.py during provisioning).

Uses ephemerallib to set up AWS credentials for authenticated API testing.
"""

import argparse
import logging
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Allow importing ephemerallib as a sibling package
sys.path.insert(0, str(Path(__file__).parent))

from ephemerallib.aws import AWSCredentials

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


def main():
    parser = argparse.ArgumentParser(description="E2E test runner for ROSA Regional Platform")
    parser.add_argument(
        "--shared-dir",
        default=os.environ.get("SHARED_DIR"),
        help="Directory containing shared CI data (default: from SHARED_DIR env var)",
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
        "--api-ref",
        default=os.environ.get("API_REF", "main"),
        help="Git ref (branch/tag) of rosa-regional-platform-api to test (default: main)",
    )
    args = parser.parse_args()

    if not args.shared_dir:
        log.error("SHARED_DIR must be set (either via --shared-dir or SHARED_DIR env var)")
        sys.exit(1)

    # Read API URL from shared directory
    api_url_file = Path(args.shared_dir) / "api-url"
    if not api_url_file.exists() or not api_url_file.is_file():
        log.error("API URL file does not exist or is not readable: %s", api_url_file)
        sys.exit(1)

    base_url = api_url_file.read_text().strip()
    log.info("Running API e2e tests against %s", base_url)

    # Set up AWS credentials for authenticated API calls to regional API Gateway
    # Use assume role from central account for better security (temporary credentials)
    log.info("Setting up AWS credentials for API testing")
    aws = AWSCredentials(args.creds_dir, args.region)
    aws.setup_central_account()
    aws.setup_target_account_via_assume_role("regional")

    # Clone rosa-regional-platform-api repo
    work_dir = Path(tempfile.mkdtemp())
    api_dir = work_dir / "api"

    try:
        log.info("Cloning rosa-regional-platform-api (ref: %s)", args.api_ref)
        subprocess.run(
            [
                "git",
                "clone",
                "--depth",
                "1",
                "--branch",
                args.api_ref,
                "https://github.com/openshift-online/rosa-regional-platform-api.git",
                str(api_dir),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        # Install ginkgo
        log.info("Installing ginkgo")
        subprocess.run(
            ["go", "install", "github.com/onsi/ginkgo/v2/ginkgo@v2.28.1"],
            check=True,
            capture_output=True,
            text=True,
        )

        # Add GOPATH/bin to PATH for ginkgo
        go_bin = subprocess.run(
            ["go", "env", "GOPATH"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        go_bin_path = Path(go_bin) / "bin"

        # Prepare environment with AWS credentials and BASE_URL
        test_env = os.environ.copy()
        test_env.update(aws.subprocess_env)
        test_env["BASE_URL"] = base_url
        test_env["PATH"] = f"{go_bin_path}:{test_env.get('PATH', '')}"

        # Run make test-e2e
        log.info("Running make test-e2e")
        log.info("")
        log.info("==========================================")
        log.info("E2E Test Output")
        log.info("==========================================")
        log.info("")

        subprocess.run(
            ["make", "test-e2e"],
            cwd=api_dir,
            env=test_env,
            check=True,
        )

        log.info("")
        log.info("==========================================")
        log.info("E2E tests completed successfully!")
        log.info("==========================================")

    except subprocess.CalledProcessError as e:
        log.error("E2E tests failed: %s", e)
        if e.stdout:
            log.error("stdout: %s", e.stdout)
        if e.stderr:
            log.error("stderr: %s", e.stderr)
        sys.exit(1)
    finally:
        # Clean up temporary directory
        if work_dir.exists():
            shutil.rmtree(work_dir)
            log.info("Cleaned up temporary directory: %s", work_dir)


if __name__ == "__main__":
    main()
