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
      defaults.yaml                  # Environment defaults
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
            revision = config.get("git", {}).get("revision")
            if revision and revision != "main":
                if not commit_hash_pattern.match(revision):
                    raise ValueError(
                        f"Invalid commit hash for {env_name}/{region_name}: "
                        f"'{revision}'. Expected 7-40 character hexadecimal string."
                    )


def collect_key_paths(data: dict[str, Any], prefix: str = "") -> set[str]:
    """Recursively collect all dot-separated key paths from a dict."""
    paths: set[str] = set()
    for key, value in data.items():
        path = f"{prefix}.{key}" if prefix else key
        paths.add(path)
        if isinstance(value, dict):
            paths.update(collect_key_paths(value, path))
    return paths


DOCS_START_MARKER = "# @docs"
DOCS_END_MARKER = "# @end-docs"


def scan_template_variables(templates_dir: Path) -> dict[str, list[str]]:
    """Scan all Jinja2 templates and return {variable: [template_paths]}.

    Finds {{ var }}, {{ var.field }}, {% if var %}, {% if var.field %} patterns.
    """
    import re

    # Match {{ var.path }} and {% if var.path %}
    patterns = [
        re.compile(r"\{\{[\s-]*([a-zA-Z_][\w.]*?)(?:\s*[\|}\[])"),
        re.compile(r"\{%[\s-]*(?:if|elif)\s+([a-zA-Z_][\w.]*?)[\s%]"),
    ]

    var_to_templates: dict[str, list[str]] = {}
    for tpl_file in sorted(templates_dir.rglob("*.j2")):
        rel_path = str(tpl_file.relative_to(templates_dir))
        content = tpl_file.read_text()
        for pattern in patterns:
            for match in pattern.finditer(content):
                var = match.group(1)
                # Skip Jinja2 built-ins and loop variables
                if var.split(".")[0] in ("true", "false", "none", "loop"):
                    continue
                if var not in var_to_templates:
                    var_to_templates[var] = []
                if rel_path not in var_to_templates[var]:
                    var_to_templates[var].append(rel_path)

    return var_to_templates


def collect_used_key_paths(config_dir: Path) -> set[str]:
    """Collect all key paths used across env/region config files."""
    used_paths: set[str] = set()
    environments = discover_environments(config_dir)
    for env_name in environments:
        env_dir = config_dir / env_name
        env_defaults = load_yaml(env_dir / "defaults.yaml")
        used_paths.update(collect_key_paths(env_defaults))

        for region_file in sorted(env_dir.glob("*.yaml")):
            if region_file.name == "defaults.yaml":
                continue
            region_config = load_yaml(region_file)
            used_paths.update(collect_key_paths(region_config))

    return used_paths


def parse_docs_section(defaults_path: Path) -> set[str]:
    """Parse the @docs section from defaults.yaml and return documented key paths."""
    documented: set[str] = set()
    in_docs = False
    with open(defaults_path, "r") as f:
        for line in f:
            stripped = line.strip()
            if stripped == DOCS_START_MARKER:
                in_docs = True
                continue
            if stripped == DOCS_END_MARKER:
                break
            if in_docs and stripped.startswith("#"):
                # Lines like: # dns.domain  → template/path.j2
                content = stripped.lstrip("# ")
                if content and not content.startswith("→"):
                    key_path = content.split()[0]
                    if key_path and not key_path.startswith("─"):
                        documented.add(key_path)
    return documented


def generate_docs_section(
    config_dir: Path, templates_dir: Path
) -> str:
    """Generate the @docs section content."""
    # Collect all key paths from defaults.yaml + env/region configs
    defaults = load_yaml(config_dir / "defaults.yaml")
    documented_paths = collect_key_paths(defaults)
    used_paths = collect_used_key_paths(config_dir)
    all_paths = sorted(documented_paths | used_paths)

    # Scan templates for variable references
    var_to_templates = scan_template_variables(templates_dir)

    # Find the longest key path for alignment
    max_len = max((len(p) for p in all_paths), default=0)

    lines = [
        DOCS_START_MARKER,
        "#",
        "# Config key documentation — auto-generated by: render.py --update-docs",
        "#",
        "# Key" + " " * (max_len - 3) + "Used in",
        "# " + "─" * (max_len) + " " + "─" * 50,
    ]

    for path in all_paths:
        # Find which templates reference this key path
        consumers: list[str] = []
        # Check exact match and prefix match (e.g. terraform_common matches
        # terraform_common.app_code in templates)
        for var, templates in var_to_templates.items():
            if var == path or var.startswith(path + "."):
                for t in templates:
                    if t not in consumers:
                        consumers.append(t)

        padding = " " * (max_len - len(path) + 2)
        if consumers:
            lines.append(f"# {path}{padding}→ {consumers[0]}")
            for consumer in consumers[1:]:
                lines.append(f"# {' ' * max_len}  → {consumer}")
        else:
            lines.append(f"# {path}{padding}(render.py context)")

    lines.append("#")
    lines.append(DOCS_END_MARKER)
    return "\n".join(lines) + "\n"


def update_docs(config_dir: Path, templates_dir: Path) -> int:
    """Generate and write the @docs section in defaults.yaml."""
    defaults_path = config_dir / "defaults.yaml"
    if not defaults_path.exists():
        print("Error: defaults.yaml not found", file=sys.stderr)
        return 1

    docs_section = generate_docs_section(config_dir, templates_dir)

    # Read existing file
    content = defaults_path.read_text()

    # Replace existing @docs section or append
    if DOCS_START_MARKER in content:
        import re

        pattern = re.compile(
            rf"^{re.escape(DOCS_START_MARKER)}$.*?^{re.escape(DOCS_END_MARKER)}$\n?",
            re.MULTILINE | re.DOTALL,
        )
        content = pattern.sub(docs_section, content)
    else:
        # Append after a blank line
        if not content.endswith("\n\n"):
            content = content.rstrip("\n") + "\n\n"
        content += docs_section

    defaults_path.write_text(content)
    print(f"✅ Updated {defaults_path}")
    return 0


def check_documented_keys(config_dir: Path, templates_dir: Path) -> int:
    """Check that all config keys are documented and template paths are valid."""
    defaults_path = config_dir / "defaults.yaml"
    if not defaults_path.exists():
        print("Error: defaults.yaml not found", file=sys.stderr)
        return 1

    # Collect documented paths from actual keys + @docs section
    defaults = load_yaml(defaults_path)
    documented_paths = collect_key_paths(defaults)
    documented_paths.update(parse_docs_section(defaults_path))

    # Collect used paths from env/region configs
    used_paths = collect_used_key_paths(config_dir)

    # Check for undocumented keys
    undocumented = set()
    for path in used_paths:
        parts = path.split(".")
        found = False
        for i in range(len(parts)):
            ancestor = ".".join(parts[: i + 1])
            if ancestor in documented_paths:
                found = True
                break
        if not found:
            undocumented.add(path)

    # Check that @docs section template paths are valid
    invalid_paths: list[str] = []
    with open(defaults_path, "r") as f:
        in_docs = False
        for line in f:
            stripped = line.strip()
            if stripped == DOCS_START_MARKER:
                in_docs = True
                continue
            if stripped == DOCS_END_MARKER:
                break
            if in_docs and "→" in stripped:
                tpl_path = stripped.split("→")[1].strip()
                if tpl_path and not (templates_dir / tpl_path).exists():
                    invalid_paths.append(tpl_path)

    errors = False
    if undocumented:
        errors = True
        print("❌ Undocumented config keys found in env/region files:")
        print("   These keys are used but not documented in config/defaults.yaml.\n")
        for path in sorted(undocumented):
            print(f"   - {path}")
        print(
            "\n   Run 'uv run scripts/render.py --update-docs' to generate documentation."
        )

    if invalid_paths:
        errors = True
        print("\n❌ Invalid template paths in @docs section:")
        for path in sorted(invalid_paths):
            print(f"   - {path}")
        print(
            "\n   Run 'uv run scripts/render.py --update-docs' to regenerate documentation."
        )

    if errors:
        return 1

    print("✅ All config keys are documented in defaults.yaml")
    return 0


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
    parser.add_argument(
        "--check-docs",
        action="store_true",
        help="Check that all config keys are documented in defaults.yaml",
    )
    parser.add_argument(
        "--update-docs",
        action="store_true",
        help="Generate/update the @docs section in defaults.yaml",
    )
    args = parser.parse_args()
    ci_prefix = args.ci_prefix

    # Determine paths
    script_dir = Path(__file__).parent
    project_root = script_dir.parent

    config_dir = Path(args.config_dir) if args.config_dir else project_root / "config"
    templates_dir = config_dir / "templates"

    if args.update_docs:
        return update_docs(config_dir, templates_dir)

    if args.check_docs:
        return check_documented_keys(config_dir, templates_dir)
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
            context = dict(merged)
            context["environment"] = env_name
            context["aws_region"] = region
            context["region"] = region
            context["regional_id"] = regional_id

            # Resolve aws.account_id template early (other templates reference it)
            aws_config = context.get("aws", {})
            context["account_id"] = resolve_templates(
                aws_config.get("account_id", ""), context
            )

            # Resolve terraform_common values
            context["terraform_common"] = resolve_templates(
                context.get("terraform_common", {}), context
            )

            # Resolve dns config
            dns_config = context.get("dns", {})
            context["dns"] = dns_config

            # Build management cluster data
            mc_dict = merged.get("management_clusters", {})
            default_mc_account_id = aws_config.get("management_cluster_account_id")
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
                revision = context.get("git", {}).get("revision")
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
