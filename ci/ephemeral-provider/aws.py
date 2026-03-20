import json
import logging
import os
import time
from pathlib import Path

import boto3

log = logging.getLogger(__name__)


CENTRAL_REGION = "us-east-1"


class AWSCredentials:
    """Manages AWS credential setup for CI environments.

    Reads credentials from the CI vault mount directory or equivalent
    environment variables. Sets up central account access via STS AssumeRole.

    Two sessions are maintained:
      - ``session`` targets the central region (us-east-1) where the
        pipeline-provisioner and SSM parameters live.
      - ``target_session`` targets the region where RC/MC pipelines run.

    Use ``subprocess_env`` when spawning child processes that need central
    account AWS access (terraform, bootstrap scripts).
    """

    def __init__(self, creds_dir: str, target_region: str = "us-east-1"):
        self.creds_dir = Path(creds_dir)
        self.central_region = CENTRAL_REGION
        self.target_region = target_region
        self.central_account_id = None
        self.session: boto3.Session | None = None
        self.target_session: boto3.Session | None = None
        self.subprocess_env: dict[str, str] = {}

    def _read_credential(self, name: str) -> str:
        """Read a credential from environment variable or file.

        Checks for an environment variable matching the uppercased name first
        (e.g. 'central_access_key' -> 'CENTRAL_ACCESS_KEY'), then falls back
        to reading from creds_dir.
        """
        env_var = name.upper()
        if os.environ.get(env_var):
            return os.environ[env_var]
        path = self.creds_dir / name
        return path.read_text().strip()

    def setup_central_account(self):
        """Set up central account access via STS AssumeRole."""
        log.info("Setting up central account access")

        access_key = self._read_credential("central_access_key")
        secret_key = self._read_credential("central_secret_key")
        assume_role_arn = self._read_credential("central_assume_role_arn")

        sts = boto3.client(
            "sts",
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name=self.central_region,
        )

        response = sts.assume_role(
            RoleArn=assume_role_arn,
            RoleSessionName=f"ci-test-{int(time.time())}",
        )

        creds = response["Credentials"]
        self.subprocess_env = {
            "AWS_ACCESS_KEY_ID": creds["AccessKeyId"],
            "AWS_SECRET_ACCESS_KEY": creds["SecretAccessKey"],
            "AWS_SESSION_TOKEN": creds["SessionToken"],
            "AWS_DEFAULT_REGION": self.central_region,
            "AWS_REGION": self.central_region,
        }

        self.session = boto3.Session(
            aws_access_key_id=creds["AccessKeyId"],
            aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"],
            region_name=self.central_region,
        )

        self.target_session = boto3.Session(
            aws_access_key_id=creds["AccessKeyId"],
            aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"],
            region_name=self.target_region,
        )

        identity = self.session.client("sts").get_caller_identity()
        self.central_account_id = identity["Account"]
        log.info("Access set up to Central CI Account ID: %s", self.central_account_id)

    def get_target_account_id(self, prefix: str) -> str:
        """Get the AWS account ID for a target account using its credentials.

        Args:
            prefix: Account prefix ('regional' or 'management') used to find credentials.

        Returns:
            The 12-digit AWS account ID.
        """
        access_key = self._read_credential(f"{prefix}_access_key")
        secret_key = self._read_credential(f"{prefix}_secret_key")

        sts = boto3.client(
            "sts",
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
        )
        return sts.get_caller_identity()["Account"]

    def target_subprocess_env(self, prefix: str) -> dict[str, str]:
        """Build a subprocess environment dict with target account credentials.

        Args:
            prefix: Account prefix ('regional' or 'management') used to find credentials.

        Returns:
            Dict with AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_DEFAULT_REGION.
        """
        return {
            "AWS_ACCESS_KEY_ID": self._read_credential(f"{prefix}_access_key"),
            "AWS_SECRET_ACCESS_KEY": self._read_credential(f"{prefix}_secret_key"),
            "AWS_DEFAULT_REGION": self.target_region,
            "AWS_REGION": self.target_region,
        }

    def setup_target_account_trust(self, prefix: str):
        """Set up trust policy in a sub-account.

        Args:
            prefix: Account prefix ('regional' or 'management') used to find credentials.
        """
        if not self.central_account_id:
            raise RuntimeError(
                "central_account_id is not set — setup_central_account() must be called first"
            )

        log.info("Temporary Setup: Updating trust policy in %s account", prefix)

        role_name = "OrganizationAccountAccessRole"
        principal = f"arn:aws:iam::{self.central_account_id}:root"

        access_key = self._read_credential(f"{prefix}_access_key")
        secret_key = self._read_credential(f"{prefix}_secret_key")

        iam = boto3.client(
            "iam",
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
        )

        role = iam.get_role(RoleName=role_name)
        existing_policy = role["Role"]["AssumeRolePolicyDocument"]

        for stmt in existing_policy.get("Statement", []):
            aws_principals = stmt.get("Principal", {}).get("AWS", [])
            if isinstance(aws_principals, str):
                aws_principals = [aws_principals]
            if (
                stmt.get("Effect") == "Allow"
                and stmt.get("Action") == "sts:AssumeRole"
                and principal in aws_principals
            ):
                log.info("Trust for %s already exists in %s account, skipping.", principal, prefix)
                return

        existing_policy["Statement"].append(
            {
                "Effect": "Allow",
                "Principal": {"AWS": principal},
                "Action": "sts:AssumeRole",
            }
        )

        iam.update_assume_role_policy(
            RoleName=role_name,
            PolicyDocument=json.dumps(existing_policy),
        )
        log.info("Updated trust on %s in %s account to allow assumeRole from %s.", role_name, prefix, principal)
