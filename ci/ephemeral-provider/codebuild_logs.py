"""Download CloudWatch logs for CodeBuild projects matching a prefix.

Fetches all log streams (build runs) per project, names files with
timestamps for chronological ordering, and strips ANSI color codes.
"""

import datetime
import logging
import re
from pathlib import Path

log = logging.getLogger(__name__)

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
_BUILD_FAILED_RE = re.compile(r"Phase complete: \S+ State: FAILED")


def download_codebuild_logs(session, prefix: str, output_dir: str | Path) -> list[Path]:
    """Download CloudWatch logs for all CodeBuild projects matching prefix.

    Args:
        session: A boto3 Session with appropriate credentials.
        prefix: Ephemeral prefix (e.g. "eph-202982"). Log groups matching
                /aws/codebuild/{prefix}-* will be downloaded.
        output_dir: Directory to write log files into (created if needed).

    Returns:
        List of paths to downloaded log files.
    """
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    logs_client = session.client("logs")
    log_group_prefix = f"/aws/codebuild/{prefix}-"

    try:
        response = logs_client.describe_log_groups(logGroupNamePrefix=log_group_prefix)
    except Exception:
        log.exception("Failed to list CloudWatch log groups")
        return []

    log_groups = response.get("logGroups", [])
    if not log_groups:
        log.info("No CloudWatch log groups found with prefix '%s'", log_group_prefix)
        return []

    log.info("Collecting logs from %d CodeBuild log group(s)...", len(log_groups))
    downloaded = []

    for lg in log_groups:
        group_name = lg["logGroupName"]
        project_name = group_name.rsplit("/", 1)[-1]

        try:
            streams_resp = logs_client.describe_log_streams(
                logGroupName=group_name,
                orderBy="LastEventTime",
                descending=True,
            )
            stream_list = streams_resp.get("logStreams", [])
            if not stream_list:
                log.info("  %s: no log streams", group_name)
                continue

            # Reverse so index 0 = oldest (chronological order)
            stream_list.reverse()

            for stream_info in stream_list:
                stream_name = stream_info["logStreamName"]
                ts_ms = stream_info.get("firstEventTimestamp")
                if ts_ms:
                    ts_label = datetime.datetime.fromtimestamp(
                        ts_ms / 1000, tz=datetime.timezone.utc
                    ).strftime("%Y%m%d-%H%M%S")
                else:
                    ts_label = "unknown"

                events = _fetch_all_events(logs_client, group_name, stream_name)
                lines = [e["message"].rstrip("\n") for e in events]
                content = "\n".join(lines)
                content = _ANSI_RE.sub("", content)

                suffix = ".FAILED" if _BUILD_FAILED_RE.search(content) else ""
                out_file = output_path / f"{project_name}.{ts_label}{suffix}.log"

                out_file.write_text(content)
                downloaded.append(out_file)
                log.info("  %s: %d events -> %s", group_name, len(events), out_file)

        except Exception:
            log.exception("  Failed to collect logs from %s", group_name)

    log.info("CodeBuild logs written to %s", output_path)
    return downloaded


def _fetch_all_events(logs_client, group_name: str, stream_name: str) -> list[dict]:
    """Paginate through all log events in a stream."""
    events = []
    kwargs = {
        "logGroupName": group_name,
        "logStreamName": stream_name,
        "startFromHead": True,
    }
    while True:
        resp = logs_client.get_log_events(**kwargs)
        batch = resp.get("events", [])
        if not batch:
            break
        events.extend(batch)
        next_token = resp.get("nextForwardToken")
        if next_token == kwargs.get("nextToken"):
            break
        kwargs["nextToken"] = next_token
    return events
