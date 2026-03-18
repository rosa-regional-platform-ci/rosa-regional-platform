#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "PyYAML>=6.0",
#     "Jinja2>=3.1",
# ]
# ///
"""
Deploy Directory Renderer

Renders deploy/ output files from config/ values + templates.

Config structure:
  config/
    defaults.yaml                    # Global defaults
    templates/                       # Jinja2 templates (1-1 with deploy/ output files)
    <env>/
      defaults.yaml                  # Environment/sector defaults
      <region>.yaml                  # Region deployment values

Inheritance chain:
  config/defaults.yaml → config/<env>/defaults.yaml → config/<env>/<region>.yaml

Each template receives the fully-merged values as Jinja2 context.
"""

import argparse
import os
import shutil
import sys
from pathlib import Path
from typing import Any

import yaml
from jinja2 import Environment


def load_yaml(file_path: Path) -> dict[str, Any]:
    """Load and parse a YAML file."""
    if not file_path.exists():
        return {}
    with open(file_path, "r") as f:
        return yaml.safe_load(f) or {}


def deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    """Recursively merge two dictionaries, overlay wins."""
    result = base.copy()
    for key, value in overlay.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def resolve_templates(value: Any, context: dict[str, Any]) -> Any:
    """Recursively resolve Jinja2 template placeholders in all string values."""
    if isinstance(value, str):
        return Environment().from_string(value).render(context)
    elif isinstance(value, dict):
        return {k: resolve_templates(v, context) for k, v in value.items()}
    elif isinstance(value, list):
        return [resolve_templates(item, context) for item in value]
    return value


def toyaml_filter(value: Any) -> str:
    """Jinja2 filter to dump a value as YAML."""
    if not value:
        return "{}"
    return yaml.dump(
        value,
        default_flow_style=False,
        sort_keys=False,
        allow_unicode=True,
        width=float("inf"),
    ).rstrip()


def render_jinja2_template(template_path: Path, context: dict[str, Any]) -> str:
    """Render a Jinja2 template file with the given context."""
    env = Environment()
    env.filters["toyaml"] = toyaml_filter
    with open(template_path, "r") as f:
        template = env.from_string(f.read())
    return template.render(context)


def write_output(content: str, output_path: Path) -> None:
    """Write rendered content to an output file."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        f.write(content)
        if not content.endswith("\n"):
            f.write("\n")


def discover_environments(config_dir: Path) -> list[str]:
    """Discover environments by scanning for config/<env>/defaults.yaml."""
    envs = []
    for item in sorted(config_dir.iterdir()):
        if item.is_dir() and not item.name.startswith(".") and item.name != "templates":
            if (item / "defaults.yaml").exists():
                envs.append(item.name)
    return envs


def discover_regions(env_dir: Path) -> list[str]:
    """Discover regions by scanning for config/<env>/<region>.yaml (excluding defaults.yaml)."""
    regions = []
    for item in sorted(env_dir.glob("*.yaml")):
        if item.name != "defaults.yaml":
            regions.append(item.stem)
    return regions


def get_cluster_types(argocd_config_dir: Path) -> list[str]:
    """Discover cluster types by looking at directories ending in 'cluster'."""
    cluster_types = []
    for item in argocd_config_dir.iterdir():
        if (
            item.is_dir()
            and not item.name.startswith(".")
            and item.name.endswith("cluster")
        ):
            cluster_types.append(item.name)
    return cluster_types


def create_applicationset_content(
    base_applicationset_path: Path, config_revision: str | None
) -> str:
    """Create ApplicationSet YAML content with optional revision pinning."""
    applicationset = load_yaml(base_applicationset_path)

    if config_revision:
        # Find the git generator in the matrix and update its revision
        generators = applicationset["spec"]["generators"][0]["matrix"]["generators"]
        for generator in generators:
            if "git" in generator:
                generator["git"]["revision"] = config_revision
                break

        # Update only the first source (chart + values.yaml) to use the specific commit hash
        sources = applicationset["spec"]["template"]["spec"]["sources"]
        for source in sources:
            if "targetRevision" in source and "ref" not in source:
                source["targetRevision"] = config_revision

    return yaml.dump(
        applicationset,
        default_flow_style=False,
        sort_keys=False,
        allow_unicode=True,
        width=float("inf"),
    )


def build_region_definitions(
    env_name: str,
    regions: list[str],
    region_configs: dict[str, dict[str, Any]],
    ci_prefix: str,
) -> dict[str, Any]:
    """Build the region_definitions map for an environment."""
    region_definitions = {}
    for region in regions:
        rc = region_configs[region]
        mc_dict = rc.get("management_clusters", {})
        mc_ids = []
        for mc_key in mc_dict:
            mc_id = f"{ci_prefix}-{mc_key}" if ci_prefix else mc_key
            mc_ids.append(mc_id)
        region_definitions[region] = {
            "name": env_name,
            "environment": env_name,
            "aws_region": region,
            "management_clusters": mc_ids,
        }
    return region_definitions


def cleanup_stale_files(
    valid_envs: set[str],
    env_regions: dict[str, set[str]],
    env_region_mcs: dict[str, dict[str, set[str]]],
    deploy_dir: Path,
) -> None:
    """Remove stale files from deploy directory."""
    if not deploy_dir.exists():
        return

    removed_count = 0
    for env_dir in deploy_dir.iterdir():
        if not env_dir.is_dir() or env_dir.name.startswith("."):
            continue
        environment = env_dir.name

        if environment not in valid_envs:
            print(f"  [CLEANUP] Removing stale environment: deploy/{environment}/")
            shutil.rmtree(env_dir)
            removed_count += 1
            continue

        for region_dir in env_dir.iterdir():
            if not region_dir.is_dir() or region_dir.name.startswith("."):
                continue
            region = region_dir.name

            if region not in env_regions.get(environment, set()):
                print(
                    f"  [CLEANUP] Removing stale region: deploy/{environment}/{region}/"
                )
                shutil.rmtree(region_dir)
                removed_count += 1
                continue

            # Check for stale management cluster input directories
            valid_mcs = env_region_mcs.get(environment, {}).get(region, set())
            for item in region_dir.iterdir():
                if item.is_dir() and item.name.startswith(
                    "pipeline-management-cluster-"
                ):
                    # Extract mc name: pipeline-management-cluster-mc01-inputs → mc01
                    mc_name = item.name.removeprefix(
                        "pipeline-management-cluster-"
                    ).removesuffix("-inputs")
                    if mc_name not in valid_mcs:
                        print(f"  [CLEANUP] Removing stale MC: {item}")
                        shutil.rmtree(item)
                        removed_count += 1

            # Check for stale MC provisioner files
            prov_dir = region_dir / "pipeline-provisioner-inputs"
            if prov_dir.exists():
                for mc_file in prov_dir.glob("management-cluster-*.json"):
                    mc_name = mc_file.stem.removeprefix("management-cluster-")
                    if mc_name not in valid_mcs:
                        print(f"  [CLEANUP] Removing stale MC provisioner file: {mc_file}")
                        mc_file.unlink()
                        removed_count += 1

    if removed_count > 0:
        print()


def validate_config_revisions(
    env_regions: dict[str, dict[str, dict[str, Any]]]
) -> None:
    """Validate that specified config revisions are valid git commit hashes."""
    import re

    commit_hash_pattern = re.compile(r"^[a-f0-9]{7,40}$")

    for env_name, regions in env_regions.items():
        for region_name, config in regions.items():
            revision = config.get("revision")
            if revision and revision != "main":
                if not commit_hash_pattern.match(revision):
                    raise ValueError(
                        f"Invalid commit hash for {env_name}/{region_name}: "
                        f"'{revision}'. Expected 7-40 character hexadecimal string."
                    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Render deploy/ directory from config/ values and templates"
    )
    parser.add_argument(
        "--ci-prefix",
        default=os.environ.get("CI_PREFIX", ""),
        help='Optional prefix for resource names in CI/test environments (e.g., "xg4y")',
    )
    parser.add_argument(
        "--config-dir",
        default=None,
        help="Path to config directory (default: config/)",
    )
    args = parser.parse_args()
    ci_prefix = args.ci_prefix

    # Determine paths
    script_dir = Path(__file__).parent
    project_root = script_dir.parent

    config_dir = Path(args.config_dir) if args.config_dir else project_root / "config"
    templates_dir = config_dir / "templates"
    deploy_dir = project_root / "deploy"
    argocd_config_dir = project_root / "argocd" / "config"
    base_applicationset_path = (
        argocd_config_dir / "applicationset" / "base-applicationset.yaml"
    )

    if ci_prefix:
        print(f"CI prefix: {ci_prefix}")

    # Validate
    if not config_dir.exists():
        print(f"Error: Config directory not found: {config_dir}", file=sys.stderr)
        return 1

    if not templates_dir.exists():
        print(f"Error: Templates directory not found: {templates_dir}", file=sys.stderr)
        return 1

    # Discover environments and cluster types
    environments = discover_environments(config_dir)
    if not environments:
        print("Error: No environments found in config/", file=sys.stderr)
        return 1

    cluster_types = get_cluster_types(argocd_config_dir)
    if not cluster_types:
        print("Error: No cluster types found", file=sys.stderr)
        return 1

    # Load global defaults
    global_defaults = load_yaml(config_dir / "defaults.yaml")

    print(f"Found {len(environments)} environment(s): {', '.join(environments)}")
    print(f"Found cluster types: {', '.join(cluster_types)}")
    print()

    # Build tracking sets for cleanup
    valid_envs = set(environments)
    env_regions_set: dict[str, set[str]] = {}
    env_region_mcs_set: dict[str, dict[str, set[str]]] = {}

    # Collect all region configs for validation
    all_env_regions: dict[str, dict[str, dict[str, Any]]] = {}

    for env_name in environments:
        env_dir = config_dir / env_name
        env_defaults = load_yaml(env_dir / "defaults.yaml")
        regions = discover_regions(env_dir)

        if not regions:
            print(f"Warning: No regions found for environment '{env_name}'")
            continue

        env_regions_set[env_name] = set(regions)
        env_region_mcs_set[env_name] = {}
        all_env_regions[env_name] = {}

        for region in regions:
            region_config = load_yaml(env_dir / f"{region}.yaml")
            # Merge: global_defaults → env_defaults → region_config
            merged = deep_merge(global_defaults, env_defaults)
            merged = deep_merge(merged, region_config)
            all_env_regions[env_name][region] = merged

            # Track management clusters
            mc_dict = merged.get("management_clusters", {})
            mc_ids = set()
            for mc_key in mc_dict:
                mc_id = f"{ci_prefix}-{mc_key}" if ci_prefix else mc_key
                mc_ids.add(mc_id)
            env_region_mcs_set[env_name][region] = mc_ids

    # Validate config revisions
    try:
        validate_config_revisions(all_env_regions)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    # Clean up stale files
    cleanup_stale_files(valid_envs, env_regions_set, env_region_mcs_set, deploy_dir)

    # Render all outputs
    for env_name in environments:
        env_dir = config_dir / env_name
        env_defaults = load_yaml(env_dir / "defaults.yaml")
        regions = discover_regions(env_dir)

        if not regions:
            continue

        print(f"Processing environment: {env_name}")

        # Collect region configs for region_definitions
        region_configs: dict[str, dict[str, Any]] = {}
        for region in regions:
            region_config = load_yaml(env_dir / f"{region}.yaml")
            merged = deep_merge(global_defaults, env_defaults)
            merged = deep_merge(merged, region_config)
            region_configs[region] = merged

        # --- Render region-definitions.json (env-level) ---
        region_definitions = build_region_definitions(
            env_name, regions, region_configs, ci_prefix
        )
        region_defs_template = templates_dir / "region-definitions.json.j2"
        if region_defs_template.exists():
            content = render_jinja2_template(
                region_defs_template,
                {"region_definitions": region_definitions},
            )
            output_path = deploy_dir / env_name / "region-definitions.json"
            write_output(content, output_path)
            print(f"  [OK] deploy/{env_name}/region-definitions.json")

        # --- Process each region ---
        for region in regions:
            merged = region_configs[region]

            # Inject identity variables
            regional_id = f"{ci_prefix}-regional" if ci_prefix else "regional"
            sector = merged.get("sector", env_name)

            context = dict(merged)
            context["environment"] = env_name
            context["aws_region"] = region
            context["region"] = region
            context["regional_id"] = regional_id
            context["sector"] = sector

            # Resolve account_id template early (other templates reference it)
            context["account_id"] = resolve_templates(
                context.get("account_id", ""), context
            )

            # Resolve terraform values
            context["terraform"] = resolve_templates(
                context.get("terraform", {}), context
            )

            # Build domain (from env defaults or region config)
            domain = context.get("domain", "")
            context["domain"] = domain

            # Build management cluster data
            mc_dict = merged.get("management_clusters", {})
            default_mc_account_id = merged.get("management_cluster_account_id")
            mc_list = []
            mc_account_ids = []
            for mc_key, mc_val in mc_dict.items():
                mc_entry = dict(mc_val) if mc_val else {}
                mc_id = f"{ci_prefix}-{mc_key}" if ci_prefix else mc_key
                mc_entry["management_id"] = mc_id

                # Apply default MC account_id if not specified
                if "account_id" not in mc_entry and default_mc_account_id:
                    mc_entry["account_id"] = default_mc_account_id

                # Template-process with augmented context (cluster_prefix)
                mc_context = dict(context)
                mc_context["cluster_prefix"] = mc_key
                mc_entry = resolve_templates(mc_entry, mc_context)

                mc_list.append(mc_entry)
                if mc_entry.get("account_id"):
                    mc_account_ids.append(mc_entry["account_id"])

            context["management_clusters"] = mc_list
            context["management_cluster_account_ids"] = mc_account_ids

            deploy_region_dir = deploy_dir / env_name / region

            # --- pipeline-provisioner-inputs/terraform.json ---
            tpl = templates_dir / "pipeline-provisioner-inputs" / "terraform.json.j2"
            if tpl.exists():
                content = render_jinja2_template(tpl, context)
                out = (
                    deploy_region_dir
                    / "pipeline-provisioner-inputs"
                    / "terraform.json"
                )
                write_output(content, out)
                print(
                    f"  [OK] deploy/{env_name}/{region}/pipeline-provisioner-inputs/terraform.json"
                )

            # --- pipeline-provisioner-inputs/regional-cluster.json ---
            tpl = (
                templates_dir
                / "pipeline-provisioner-inputs"
                / "regional-cluster.json.j2"
            )
            if tpl.exists():
                content = render_jinja2_template(tpl, context)
                out = (
                    deploy_region_dir
                    / "pipeline-provisioner-inputs"
                    / "regional-cluster.json"
                )
                write_output(content, out)
                print(
                    f"  [OK] deploy/{env_name}/{region}/pipeline-provisioner-inputs/regional-cluster.json"
                )

            # --- pipeline-regional-cluster-inputs/terraform.json ---
            tpl = (
                templates_dir
                / "pipeline-regional-cluster-inputs"
                / "terraform.json.j2"
            )
            if tpl.exists():
                content = render_jinja2_template(tpl, context)
                out = (
                    deploy_region_dir
                    / "pipeline-regional-cluster-inputs"
                    / "terraform.json"
                )
                write_output(content, out)
                print(
                    f"  [OK] deploy/{env_name}/{region}/pipeline-regional-cluster-inputs/terraform.json"
                )

            # --- ArgoCD values files ---
            argocd_values_tpl = templates_dir / "argocd-values.yaml.j2"
            if argocd_values_tpl.exists():
                argocd_config = resolve_templates(
                    context.get("argocd", {}), context
                )
                for cluster_type in cluster_types:
                    ct_values = argocd_config.get(cluster_type, {})
                    ct_context = dict(context)
                    ct_context["argocd_values"] = ct_values
                    ct_context["cluster_type"] = cluster_type
                    content = render_jinja2_template(argocd_values_tpl, ct_context)
                    out = (
                        deploy_region_dir
                        / f"argocd-values-{cluster_type}.yaml"
                    )
                    write_output(content, out)
                    if ct_values:
                        print(
                            f"  [OK] deploy/{env_name}/{region}/argocd-values-{cluster_type}.yaml"
                        )
                    else:
                        print(
                            f"  [OK] deploy/{env_name}/{region}/argocd-values-{cluster_type}.yaml (empty - no overrides)"
                        )

            # --- ArgoCD bootstrap ApplicationSet ---
            bootstrap_tpl = (
                templates_dir / "argocd-bootstrap" / "applicationset.yaml.j2"
            )
            if bootstrap_tpl.exists():
                revision = context.get("revision")
                pinned_revision = (
                    revision if (revision and revision != "main") else None
                )
                applicationset_content = create_applicationset_content(
                    base_applicationset_path, pinned_revision
                )
                revision_info = (
                    pinned_revision[:8]
                    if pinned_revision
                    else "metadata.annotations.git_revision"
                )

                for cluster_type in cluster_types:
                    ct_context = dict(context)
                    ct_context["cluster_type"] = cluster_type
                    ct_context["config_revision"] = revision_info
                    ct_context["applicationset_content"] = applicationset_content
                    content = render_jinja2_template(bootstrap_tpl, ct_context)
                    out = (
                        deploy_region_dir
                        / f"argocd-bootstrap-{cluster_type}"
                        / "applicationset.yaml"
                    )
                    write_output(content, out)
                    print(
                        f"  [OK] deploy/{env_name}/{region}/argocd-bootstrap-{cluster_type}/applicationset.yaml (Config Revision: {revision_info})"
                    )

            # --- Per-management-cluster files ---
            for mc_entry in mc_list:
                mc_id = mc_entry["management_id"]
                mc_context = dict(context)
                mc_context["mc"] = mc_entry

                # --- pipeline-provisioner-inputs/management-cluster-<mc>.json ---
                tpl = (
                    templates_dir
                    / "pipeline-provisioner-inputs"
                    / "management-cluster.json.j2"
                )
                if tpl.exists():
                    content = render_jinja2_template(tpl, mc_context)
                    out = (
                        deploy_region_dir
                        / "pipeline-provisioner-inputs"
                        / f"management-cluster-{mc_id}.json"
                    )
                    write_output(content, out)
                    print(
                        f"  [OK] deploy/{env_name}/{region}/pipeline-provisioner-inputs/management-cluster-{mc_id}.json"
                    )

                # --- pipeline-management-cluster-<mc>-inputs/terraform.json ---
                tpl = (
                    templates_dir
                    / "pipeline-management-cluster-inputs"
                    / "terraform.json.j2"
                )
                if tpl.exists():
                    content = render_jinja2_template(tpl, mc_context)
                    out = (
                        deploy_region_dir
                        / f"pipeline-management-cluster-{mc_id}-inputs"
                        / "terraform.json"
                    )
                    write_output(content, out)
                    print(
                        f"  [OK] deploy/{env_name}/{region}/pipeline-management-cluster-{mc_id}-inputs/terraform.json"
                    )

        print()

    print("[OK] Rendering complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
