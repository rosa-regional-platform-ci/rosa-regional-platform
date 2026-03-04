import json
import logging
import os
import time
from pathlib import Path

import boto3

log = logging.getLogger(__name__)


class AWSCredentials:
    """Manages AWS credential setup for CI environments.

    Reads credentials from the CI vault mount directory or equivalent
    environment variables. Sets up central account access via STS AssumeRole.

    After setup, use `self.session` for all boto3 API calls — it carries the
    assumed-role credentials explicitly so it won't fall back to the local
    AWS profile/SSO. Use `self.subprocess_env` when spawning child processes
    that need AWS access (terraform, bootstrap scripts).
    """

    def __init__(self, creds_dir: str, region: str = "us-east-1"):
        self.creds_dir = Path(creds_dir)
        self.region = region
        self.central_account_id = None
        self.session: boto3.Session | None = None
        self.subprocess_env: dict[str, str] = {}

    def _read_credential(self, name: str, env_var: str | None = None) -> str:
        """Read a credential from file or environment variable."""
        if env_var and os.environ.get(env_var):
            return os.environ[env_var]
        path = self.creds_dir / name
        return path.read_text().strip()

    def setup_central_account(self):
        """Set up central account access via STS AssumeRole."""
        log.info("Setting up central account access")

        access_key = self._read_credential("ci_access_key", "CI_ACCESS_KEY")
        secret_key = self._read_credential("ci_secret_key", "CI_SECRET_KEY")
        assume_role_arn = self._read_credential("ci_assume_role_arn", "CI_ASSUME_ROLE_ARN")

        sts = boto3.client(
            "sts",
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name=self.region,
        )

        response = sts.assume_role(
            RoleArn=assume_role_arn,
            RoleSessionName=f"e2e-test-{int(time.time())}",
        )

        creds = response["Credentials"]
        self.subprocess_env = {
            "AWS_ACCESS_KEY_ID": creds["AccessKeyId"],
            "AWS_SECRET_ACCESS_KEY": creds["SecretAccessKey"],
            "AWS_SESSION_TOKEN": creds["SessionToken"],
            "AWS_DEFAULT_REGION": self.region,
            "AWS_REGION": self.region,
        }

        self.session = boto3.Session(
            aws_access_key_id=creds["AccessKeyId"],
            aws_secret_access_key=creds["SecretAccessKey"],
            aws_session_token=creds["SessionToken"],
            region_name=self.region,
        )

        identity = self.session.client("sts").get_caller_identity()
        self.central_account_id = identity["Account"]
        log.info("Access set up to Central CI Account ID: %s", self.central_account_id)

    def setup_target_account_trust(self, prefix: str):
        """Set up trust policy in a sub-account.

        Args:
            prefix: Account prefix ('regional' or 'management') used to find credentials.
        """
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
            if (
                stmt.get("Effect") == "Allow"
                and stmt.get("Action") == "sts:AssumeRole"
                and stmt.get("Principal", {}).get("AWS") == principal
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
