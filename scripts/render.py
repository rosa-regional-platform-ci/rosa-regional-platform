#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "PyYAML>=6.0",
#     "Jinja2>=3.1",
# ]
# ///
"""
Renders deploy/ output files from config/ values + Jinja2 templates.

Config inheritance: defaults.yaml -> <env>/defaults.yaml -> <env>/<region>.yaml
"""

import argparse
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any

import yaml
from jinja2 import Environment


# -- Core utilities -----------------------------------------------------------


def load_yaml(path: Path) -> dict[str, Any]:
    """Load a YAML file, returning {} if missing or empty."""
    if not path.exists():
        return {}
    with open(path) as f:
        return yaml.safe_load(f) or {}


def deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    """Recursively merge two dicts. Overlay wins on conflicts."""
    result = base.copy()
    for key, value in overlay.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def resolve_templates(value: Any, context: dict[str, Any]) -> Any:
    """Recursively resolve Jinja2 expressions in config values."""
    if isinstance(value, str):
        return Environment().from_string(value).render(context)
    elif isinstance(value, dict):
        return {k: resolve_templates(v, context) for k, v in value.items()}
    elif isinstance(value, list):
        return [resolve_templates(item, context) for item in value]
    return value


# -- Discovery ----------------------------------------------------------------


def discover_environments(config_dir: Path) -> list[str]:
    """Find environment directories (those with defaults.yaml)."""
    return sorted(
        d.name
        for d in config_dir.iterdir()
        if d.is_dir()
        and not d.name.startswith(".")
        and d.name != "templates"
        and (d / "defaults.yaml").exists()
    )


def discover_regions(env_dir: Path) -> list[str]:
    """Find region files in an environment directory."""
    return sorted(f.stem for f in env_dir.glob("*.yaml") if f.name != "defaults.yaml")


# -- Rendering ----------------------------------------------------------------


def render_template(template_path: Path, context: dict[str, Any]) -> str:
    """Render a Jinja2 template file with context."""
    env = Environment()
    env.filters["toyaml"] = _toyaml
    return env.from_string(template_path.read_text()).render(context)


def _toyaml(value: Any) -> str:
    if not value:
        return "{}"
    return yaml.dump(
        value, default_flow_style=False, sort_keys=False, width=float("inf")
    ).rstrip()


def write_output(content: str, path: Path) -> None:
    """Write content to a file, ensuring trailing newline."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content if content.endswith("\n") else content + "\n")


def render_file(templates_dir: Path, template_rel: str, context: dict[str, Any], output_path: Path) -> bool:
    """Render a template to an output file. Returns True if the template exists."""
    tpl = templates_dir / f"{template_rel}.j2"
    if not tpl.exists():
        return False
    write_output(render_template(tpl, context), output_path)
    print(f"  [OK] {output_path}")
    return True


# -- ApplicationSet -----------------------------------------------------------


def create_applicationset_content(
    base_applicationset_path: Path, config_revision: str | None
) -> str:
    """Load base ApplicationSet YAML, optionally pinning to a specific revision."""
    appset = load_yaml(base_applicationset_path)
    if config_revision:
        generators = appset["spec"]["generators"][0]["matrix"]["generators"]
        for gen in generators:
            if "git" in gen:
                gen["git"]["revision"] = config_revision
                break
        for source in appset["spec"]["template"]["spec"]["sources"]:
            if "targetRevision" in source and "ref" not in source:
                source["targetRevision"] = config_revision
    return yaml.dump(appset, default_flow_style=False, sort_keys=False, width=float("inf"))


# -- Cleanup ------------------------------------------------------------------


def cleanup_stale_files(
    valid_envs: set[str],
    env_regions: dict[str, set[str]],
    env_region_mcs: dict[str, dict[str, set[str]]],
    deploy_dir: Path,
) -> None:
    """Remove stale environment/region/MC directories from deploy/."""
    if not deploy_dir.exists():
        return

    for env_dir in deploy_dir.iterdir():
        if not env_dir.is_dir() or env_dir.name.startswith("."):
            continue
        if env_dir.name not in valid_envs:
            print(f"  [CLEANUP] Removing stale environment: deploy/{env_dir.name}/")
            shutil.rmtree(env_dir)
            continue

        for region_dir in env_dir.iterdir():
            if not region_dir.is_dir() or region_dir.name.startswith("."):
                continue
            if region_dir.name not in env_regions.get(env_dir.name, set()):
                print(f"  [CLEANUP] Removing stale region: deploy/{env_dir.name}/{region_dir.name}/")
                shutil.rmtree(region_dir)
                continue

            valid_mcs = env_region_mcs.get(env_dir.name, {}).get(region_dir.name, set())
            for item in region_dir.iterdir():
                if item.is_dir() and item.name.startswith("pipeline-management-cluster-"):
                    mc_name = item.name.removeprefix("pipeline-management-cluster-").removesuffix("-inputs")
                    if mc_name not in valid_mcs:
                        print(f"  [CLEANUP] Removing stale MC dir: {item}")
                        shutil.rmtree(item)

            prov_dir = region_dir / "pipeline-provisioner-inputs"
            if prov_dir.exists():
                for mc_file in prov_dir.glob("management-cluster-*.json"):
                    mc_name = mc_file.stem.removeprefix("management-cluster-")
                    if mc_name not in valid_mcs:
                        print(f"  [CLEANUP] Removing stale MC file: {mc_file}")
                        mc_file.unlink()


# -- Context building ---------------------------------------------------------


def build_context(
    merged: dict[str, Any], env_name: str, region: str, ci_prefix: str
) -> dict[str, Any]:
    """Build the template context from merged config values."""
    ctx = dict(merged)
    regional_id = f"{ci_prefix}-regional" if ci_prefix else "regional"
    ctx.update(environment=env_name, aws_region=region, region=region, regional_id=regional_id)

    # Resolve templated config values that other templates depend on
    aws = ctx.get("aws", {})
    ctx["account_id"] = resolve_templates(aws.get("account_id", ""), ctx)
    ctx["terraform_common"] = resolve_templates(ctx.get("terraform_common", {}), ctx)
    ctx["dns"] = ctx.get("dns", {})

    return ctx


def build_mc_list(
    ctx: dict[str, Any], merged: dict[str, Any], ci_prefix: str
) -> tuple[list[dict], list[str]]:
    """Build management cluster entries with resolved template values."""
    mc_dict = merged.get("management_clusters", {})
    default_mc_account = merged.get("aws", {}).get("management_cluster_account_id")
    mc_list = []
    mc_account_ids = []

    for mc_key, mc_val in mc_dict.items():
        mc = dict(mc_val) if mc_val else {}
        mc["management_id"] = f"{ci_prefix}-{mc_key}" if ci_prefix else mc_key
        if "account_id" not in mc and default_mc_account:
            mc["account_id"] = default_mc_account
        mc = resolve_templates(mc, {**ctx, "cluster_prefix": mc_key})
        mc_list.append(mc)
        if mc.get("account_id"):
            mc_account_ids.append(mc["account_id"])

    return mc_list, mc_account_ids


# -- Documentation ------------------------------------------------------------

# Variables injected by render.py, not from config files.
CONTEXT_VARS = {
    "environment", "aws_region", "region", "regional_id",
    "account_id", "management_cluster_account_ids",
    "cluster_type", "config_revision", "applicationset_content",
    "application_values", "region_definitions",
    "delete", "delete_pipeline",
}

_DOC_RE = re.compile(r"^\s*#\s*(?:#\s*)?@doc\s+(\S+)\s+(.+)$", re.MULTILINE)
_USED_BY_RE = re.compile(r"^\s*#\s*(?:#\s*)?@used-by\s+(\S+)\s+(.+)$", re.MULTILINE)

# Jinja2 variable patterns: {{ var.path }} and {% if var.path %}
_TPL_PATTERNS = [
    re.compile(r"\{\{[\s-]*([a-zA-Z_][\w.]*?)(?:\s*[|}\[])"),
    re.compile(r"\{%[\s-]*(?:if|elif)\s+([a-zA-Z_][\w.]*?)[\s%]"),
]


def scan_annotations(content: str) -> dict[str, dict[str, Any]]:
    """Parse @doc and @used-by annotations. Returns {key: {doc, used_by}}."""
    result: dict[str, dict[str, Any]] = {}
    for match in _DOC_RE.finditer(content):
        key, desc = match.group(1), match.group(2).strip()
        result[key] = {"doc": desc, "used_by": []}
    for match in _USED_BY_RE.finditer(content):
        key, consumer = match.group(1), match.group(2).strip()
        if key not in result:
            result[key] = {"doc": "", "used_by": []}
        result[key]["used_by"].append(consumer)
    return result


def scan_template_variables(templates_dir: Path) -> dict[str, list[str]]:
    """Scan templates for variable references. Returns {var: [template_paths]}."""
    var_to_templates: dict[str, list[str]] = {}
    for tpl in sorted(templates_dir.rglob("*.j2")):
        rel = str(tpl.relative_to(templates_dir))
        content = tpl.read_text()
        for pattern in _TPL_PATTERNS:
            for match in pattern.finditer(content):
                var = match.group(1)
                if var.split(".")[0] in ("true", "false", "none", "loop"):
                    continue
                if var not in var_to_templates:
                    var_to_templates[var] = []
                if rel not in var_to_templates[var]:
                    var_to_templates[var].append(rel)
    return var_to_templates


def collect_leaf_paths(data: dict[str, Any], prefix: str = "") -> set[str]:
    """Collect dot-separated paths to all leaf (non-dict) values."""
    paths: set[str] = set()
    for key, value in data.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict) and value:
            paths.update(collect_leaf_paths(value, path))
        else:
            paths.add(path)
    return paths


def _is_covered(key_path: str, annotations: dict[str, dict[str, Any]]) -> bool:
    """Check if a key path is covered by a @doc annotation (direct or ancestor)."""
    parts = key_path.split(".")
    for i in range(len(parts)):
        if ".".join(parts[: i + 1]) in annotations:
            return True
    return False


def check_docs(config_dir: Path, templates_dir: Path) -> int:
    """Validate @doc/@used-by annotations against templates and config."""
    defaults_path = config_dir / "defaults.yaml"
    if not defaults_path.exists():
        print("Error: defaults.yaml not found", file=sys.stderr)
        return 1

    content = defaults_path.read_text()
    defaults = load_yaml(defaults_path)
    annotations = scan_annotations(content)
    template_vars = scan_template_variables(templates_dir)
    leaf_paths = collect_leaf_paths(defaults)
    errors: list[str] = []

    # 1. Every leaf in defaults.yaml must be covered by a @doc
    for leaf in sorted(leaf_paths):
        if not _is_covered(leaf, annotations):
            errors.append(f"Undocumented config key: {leaf}")

    # 2. Every @doc must have at least one @used-by
    for key, info in sorted(annotations.items()):
        if not info["used_by"]:
            errors.append(f"Missing @used-by for: @doc {key}")

    # 3. Non-_context @used-by must point to existing templates that reference the key
    for key, info in sorted(annotations.items()):
        for consumer in info["used_by"]:
            if consumer == "_context":
                continue
            if not (templates_dir / consumer).exists():
                errors.append(f"@used-by {key}: template not found: {consumer}")
                continue
            # Verify the template actually references this key or a child of it
            referenced = False
            for var in template_vars:
                if (var == key or var.startswith(key + ".")) and consumer in template_vars[var]:
                    referenced = True
                    break
            if not referenced:
                errors.append(f"@used-by {key}: not actually referenced in {consumer}")

    # 4. Every template referencing a documented key must appear in its @used-by
    for var, consumers in sorted(template_vars.items()):
        root = var.split(".")[0]
        if root in CONTEXT_VARS:
            continue
        # Find the annotation that covers this variable
        for key, info in annotations.items():
            if var == key or var.startswith(key + "."):
                for consumer in consumers:
                    if consumer not in info["used_by"]:
                        errors.append(
                            f"Missing @used-by {key} {consumer} "
                            f"(template references {var})"
                        )

    # 5. Leaf values under non-_context docs must be used by at least one template
    for key, info in sorted(annotations.items()):
        if "_context" in info["used_by"]:
            continue
        key_leaves = [lp for lp in leaf_paths if lp == key or lp.startswith(key + ".")]
        for leaf in sorted(key_leaves):
            found = any(var == leaf or var.startswith(leaf + ".") for var in template_vars)
            if not found:
                errors.append(f"Unused config key: {leaf} (not referenced by any template)")

    # 6. Every template variable must be covered by a @doc or be a context var
    for var in sorted(template_vars):
        root = var.split(".")[0]
        if root in CONTEXT_VARS:
            continue
        if not _is_covered(var, annotations):
            templates = ", ".join(template_vars[var])
            errors.append(f"Undocumented template variable: {var} (in {templates})")

    if errors:
        print("Documentation check failed:\n")
        for err in errors:
            print(f"  - {err}")
        print(f"\nRun 'uv run scripts/render.py --update-docs' to regenerate @used-by lines.")
        return 1

    print("Documentation check passed")
    return 0


def update_docs(config_dir: Path, templates_dir: Path) -> int:
    """Regenerate @used-by lines based on template scanning. Preserves _context entries."""
    defaults_path = config_dir / "defaults.yaml"
    if not defaults_path.exists():
        print("Error: defaults.yaml not found", file=sys.stderr)
        return 1

    content = defaults_path.read_text()
    annotations = scan_annotations(content)
    template_vars = scan_template_variables(templates_dir)

    # Build actual consumers for each documented key
    key_consumers: dict[str, list[str]] = {}
    for key in annotations:
        consumers: set[str] = set()
        for var, templates in template_vars.items():
            if var == key or var.startswith(key + "."):
                consumers.update(templates)
        key_consumers[key] = sorted(consumers)

    # Rebuild file: keep @doc lines, regenerate @used-by lines
    lines = content.splitlines()
    new_lines: list[str] = []

    for line in lines:
        stripped = line.strip()

        # Skip existing @used-by lines (will be regenerated after @doc)
        if _USED_BY_RE.match(stripped):
            continue

        new_lines.append(line)

        # After a @doc line, insert @used-by lines
        doc_match = _DOC_RE.match(stripped)
        if doc_match:
            key = doc_match.group(1)
            if key in annotations and "_context" in annotations[key]["used_by"]:
                new_lines.append(f"# @used-by {key} _context")
            else:
                for consumer in key_consumers.get(key, []):
                    new_lines.append(f"# @used-by {key} {consumer}")

    new_content = "\n".join(new_lines)
    if not new_content.endswith("\n"):
        new_content += "\n"
    defaults_path.write_text(new_content)
    print(f"Updated @used-by annotations in {defaults_path}")
    return 0


# -- Main ---------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Render deploy/ directory from config/ values and templates"
    )
    parser.add_argument(
        "--ci-prefix", default=os.environ.get("CI_PREFIX", ""),
        help="Optional prefix for resource names in CI/test environments",
    )
    parser.add_argument("--config-dir", default=None, help="Path to config directory")
    parser.add_argument(
        "--check-docs", action="store_true",
        help="Validate @doc/@used-by annotations in defaults.yaml",
    )
    parser.add_argument(
        "--update-docs", action="store_true",
        help="Regenerate @used-by lines from template scanning",
    )
    args = parser.parse_args()
    ci_prefix = args.ci_prefix

    project_root = Path(__file__).parent.parent
    config_dir = Path(args.config_dir) if args.config_dir else project_root / "config"
    templates_dir = config_dir / "templates"

    if args.check_docs:
        return check_docs(config_dir, templates_dir)

    if args.update_docs:
        return update_docs(config_dir, templates_dir)

    deploy_dir = project_root / "deploy"
    argocd_config_dir = project_root / "argocd" / "config"
    base_appset_path = argocd_config_dir / "applicationset" / "base-applicationset.yaml"

    if not config_dir.exists():
        print(f"Error: Config directory not found: {config_dir}", file=sys.stderr)
        return 1

    environments = discover_environments(config_dir)
    if not environments:
        print("Error: No environments found in config/", file=sys.stderr)
        return 1

    cluster_types = sorted(
        d.name for d in argocd_config_dir.iterdir()
        if d.is_dir() and not d.name.startswith(".") and d.name.endswith("cluster")
    )
    global_defaults = load_yaml(config_dir / "defaults.yaml")

    if ci_prefix:
        print(f"CI prefix: {ci_prefix}")
    print(f"Environments: {', '.join(environments)}")
    print(f"Cluster types: {', '.join(cluster_types)}")
    print()

    # Track valid paths for cleanup
    valid_envs = set(environments)
    env_regions: dict[str, set[str]] = {}
    env_region_mcs: dict[str, dict[str, set[str]]] = {}

    for env_name in environments:
        env_dir = config_dir / env_name
        env_defaults = load_yaml(env_dir / "defaults.yaml")
        regions = discover_regions(env_dir)
        if not regions:
            continue

        print(f"Processing: {env_name}")
        env_regions[env_name] = set(regions)
        env_region_mcs[env_name] = {}

        # Merge configs for all regions
        region_configs = {}
        for region in regions:
            region_yaml = load_yaml(env_dir / f"{region}.yaml")
            region_configs[region] = deep_merge(deep_merge(global_defaults, env_defaults), region_yaml)

        # Region definitions (env-level)
        region_defs = {}
        for region, cfg in region_configs.items():
            mc_ids = [f"{ci_prefix}-{k}" if ci_prefix else k for k in cfg.get("management_clusters", {})]
            region_defs[region] = {
                "name": env_name, "environment": env_name,
                "aws_region": region, "management_clusters": mc_ids,
            }
        render_file(templates_dir, "region-definitions.json", {"region_definitions": region_defs}, deploy_dir / env_name / "region-definitions.json")

        # Render per-region outputs
        for region in regions:
            merged = region_configs[region]
            ctx = build_context(merged, env_name, region, ci_prefix)
            mc_list, mc_account_ids = build_mc_list(ctx, merged, ci_prefix)
            ctx["management_clusters"] = mc_list
            ctx["management_cluster_account_ids"] = mc_account_ids
            env_region_mcs[env_name][region] = {mc["management_id"] for mc in mc_list}

            out_dir = deploy_dir / env_name / region

            # 1:1 templates
            render_file(templates_dir, "pipeline-provisioner-inputs/terraform.json", ctx, out_dir / "pipeline-provisioner-inputs" / "terraform.json")
            render_file(templates_dir, "pipeline-provisioner-inputs/regional-cluster.json", ctx, out_dir / "pipeline-provisioner-inputs" / "regional-cluster.json")
            render_file(templates_dir, "pipeline-regional-cluster-inputs/terraform.json", ctx, out_dir / "pipeline-regional-cluster-inputs" / "terraform.json")

            # Per-cluster-type: ArgoCD values + bootstrap
            app_config = resolve_templates(ctx.get("applications", {}), ctx)
            revision = ctx.get("git", {}).get("revision")
            pinned = revision if (revision and revision != "main") else None
            appset_content = create_applicationset_content(base_appset_path, pinned)
            revision_info = pinned[:8] if pinned else "metadata.annotations.git_revision"

            for ct in cluster_types:
                ct_ctx = {**ctx, "cluster_type": ct, "application_values": app_config.get(ct, {})}
                render_file(templates_dir, "argocd-values.yaml", ct_ctx, out_dir / f"argocd-values-{ct}.yaml")
                ct_ctx["config_revision"] = revision_info
                ct_ctx["applicationset_content"] = appset_content
                render_file(templates_dir, "argocd-bootstrap/applicationset.yaml", ct_ctx, out_dir / f"argocd-bootstrap-{ct}" / "applicationset.yaml")

            # Per-MC templates
            for mc in mc_list:
                mc_ctx = {**ctx, "mc": mc}
                mc_id = mc["management_id"]
                render_file(templates_dir, "pipeline-provisioner-inputs/management-cluster.json", mc_ctx, out_dir / "pipeline-provisioner-inputs" / f"management-cluster-{mc_id}.json")
                render_file(templates_dir, "pipeline-management-cluster-inputs/terraform.json", mc_ctx, out_dir / f"pipeline-management-cluster-{mc_id}-inputs" / "terraform.json")

        print()

    cleanup_stale_files(valid_envs, env_regions, env_region_mcs, deploy_dir)
    print("[OK] Rendering complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
