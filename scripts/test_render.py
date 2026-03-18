#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "PyYAML>=6.0",
#     "Jinja2>=3.1",
#     "pytest>=8.0",
# ]
# ///
"""Unit tests for render.py"""

import json
import shutil
from pathlib import Path

import pytest
import yaml

from render import (
    build_region_definitions,
    check_documented_keys,
    cleanup_stale_files,
    collect_key_paths,
    collect_used_key_paths,
    create_applicationset_content,
    deep_merge,
    discover_environments,
    discover_regions,
    generate_docs_section,
    get_cluster_types,
    load_yaml,
    main,
    parse_docs_section,
    resolve_templates,
    scan_template_variables,
    update_docs,
    validate_config_revisions,
    write_output,
)

# Path to real templates and argocd config for integration-style tests
PROJECT_ROOT = Path(__file__).parent.parent
REAL_TEMPLATES_DIR = PROJECT_ROOT / "config" / "templates"
REAL_ARGOCD_CONFIG_DIR = PROJECT_ROOT / "argocd" / "config"


def _create_config_structure(
    tmp_path,
    global_defaults=None,
    environments=None,
):
    """Helper to create the new config directory structure.

    environments is a dict like:
        {
            "staging": {
                "defaults": { ... },      # config/<env>/defaults.yaml content
                "regions": {
                    "us-east-1": { ... },  # config/<env>/us-east-1.yaml content
                }
            }
        }
    """
    config_dir = tmp_path / "config"
    config_dir.mkdir(exist_ok=True)

    # Global defaults (always create, even if empty)
    (config_dir / "defaults.yaml").write_text(
        yaml.dump(global_defaults if global_defaults is not None else {})
    )

    # Copy real templates
    templates_dest = config_dir / "templates"
    if REAL_TEMPLATES_DIR.exists():
        shutil.copytree(REAL_TEMPLATES_DIR, templates_dest, dirs_exist_ok=True)

    # Environment configs
    if environments:
        for env_name, env_data in environments.items():
            env_dir = config_dir / env_name
            env_dir.mkdir(exist_ok=True)

            env_defaults = env_data.get("defaults", {})
            (env_dir / "defaults.yaml").write_text(yaml.dump(env_defaults))

            for region_name, region_config in env_data.get("regions", {}).items():
                (env_dir / f"{region_name}.yaml").write_text(
                    yaml.dump(region_config)
                )

    return config_dir


def _create_argocd_config(tmp_path, cluster_types=None):
    """Helper to create argocd/config directory with cluster type dirs."""
    if cluster_types is None:
        cluster_types = ["regional-cluster", "management-cluster"]

    argocd_config_dir = tmp_path / "argocd" / "config"
    argocd_config_dir.mkdir(parents=True, exist_ok=True)

    for ct in cluster_types:
        (argocd_config_dir / ct).mkdir(exist_ok=True)

    # Copy base applicationset from real project
    appset_src = REAL_ARGOCD_CONFIG_DIR / "applicationset"
    appset_dest = argocd_config_dir / "applicationset"
    if appset_src.exists():
        shutil.copytree(appset_src, appset_dest, dirs_exist_ok=True)
    else:
        # Create a minimal base applicationset
        appset_dest.mkdir(exist_ok=True)
        _write_base_applicationset(appset_dest)

    return argocd_config_dir


def _write_base_applicationset(appset_dir):
    """Write a minimal base-applicationset.yaml for testing."""
    appset = {
        "spec": {
            "generators": [
                {
                    "matrix": {
                        "generators": [
                            {"clusters": {}},
                            {"git": {"revision": "HEAD"}},
                        ]
                    }
                }
            ],
            "template": {
                "spec": {
                    "sources": [
                        {"targetRevision": "HEAD", "path": "chart"},
                        {"targetRevision": "HEAD", "ref": "values"},
                    ]
                }
            },
        }
    }
    with open(appset_dir / "base-applicationset.yaml", "w") as f:
        yaml.dump(appset, f)



# =============================================================================
# load_yaml
# =============================================================================


class TestLoadYaml:
    def test_returns_parsed_content(self, tmp_path):
        f = tmp_path / "test.yaml"
        f.write_text("key: value\nnested:\n  a: 1\n")
        assert load_yaml(f) == {"key": "value", "nested": {"a": 1}}

    def test_returns_empty_dict_for_missing_file(self, tmp_path):
        assert load_yaml(tmp_path / "nonexistent.yaml") == {}

    def test_returns_empty_dict_for_empty_file(self, tmp_path):
        f = tmp_path / "empty.yaml"
        f.write_text("")
        assert load_yaml(f) == {}

    def test_returns_empty_dict_for_null_content(self, tmp_path):
        f = tmp_path / "null.yaml"
        f.write_text("---\n")
        assert load_yaml(f) == {}


# =============================================================================
# discover_environments
# =============================================================================


class TestDiscoverEnvironments:
    def test_finds_environments_with_defaults_yaml(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        staging = config_dir / "staging"
        staging.mkdir()
        (staging / "defaults.yaml").write_text("revision: main\n")
        prod = config_dir / "prod"
        prod.mkdir()
        (prod / "defaults.yaml").write_text("revision: main\n")

        result = discover_environments(config_dir)
        assert sorted(result) == ["prod", "staging"]

    def test_excludes_dirs_without_defaults_yaml(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        staging = config_dir / "staging"
        staging.mkdir()
        (staging / "defaults.yaml").write_text("revision: main\n")
        # This dir has no defaults.yaml, should be excluded
        (config_dir / "incomplete").mkdir()

        result = discover_environments(config_dir)
        assert result == ["staging"]

    def test_excludes_templates_directory(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        templates = config_dir / "templates"
        templates.mkdir()
        (templates / "defaults.yaml").write_text("something\n")

        result = discover_environments(config_dir)
        assert result == []

    def test_excludes_hidden_directories(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        hidden = config_dir / ".hidden"
        hidden.mkdir()
        (hidden / "defaults.yaml").write_text("revision: main\n")

        result = discover_environments(config_dir)
        assert result == []

    def test_returns_sorted(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        for name in ["zebra", "alpha", "middle"]:
            d = config_dir / name
            d.mkdir()
            (d / "defaults.yaml").write_text("{}\n")

        result = discover_environments(config_dir)
        assert result == ["alpha", "middle", "zebra"]

    def test_returns_empty_for_no_environments(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        result = discover_environments(config_dir)
        assert result == []


# =============================================================================
# discover_regions
# =============================================================================


class TestDiscoverRegions:
    def test_finds_region_yaml_files(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text("{}\n")
        (env_dir / "us-west-2.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert sorted(result) == ["us-east-1", "us-west-2"]

    def test_excludes_defaults_yaml(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert result == ["us-east-1"]

    def test_returns_empty_for_no_regions(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert result == []

    def test_returns_sorted(self, tmp_path):
        env_dir = tmp_path / "staging"
        env_dir.mkdir()
        (env_dir / "eu-west-1.yaml").write_text("{}\n")
        (env_dir / "ap-southeast-1.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text("{}\n")

        result = discover_regions(env_dir)
        assert result == ["ap-southeast-1", "eu-west-1", "us-east-1"]


# =============================================================================
# validate_config_revisions
# =============================================================================


class TestValidateConfigRevisions:
    def test_valid_short_hash(self):
        env_regions = {
            "staging": {
                "us-east-1": {"git": {"revision": "abc1234"}},
            }
        }
        validate_config_revisions(env_regions)  # should not raise

    def test_valid_full_hash(self):
        env_regions = {
            "staging": {
                "us-east-1": {"git": {"revision": "826fa76d08fc2ce87c863196e52d5a4fa9259a82"}},
            }
        }
        validate_config_revisions(env_regions)

    def test_main_is_allowed(self):
        env_regions = {
            "staging": {
                "us-east-1": {"git": {"revision": "main"}},
            }
        }
        validate_config_revisions(env_regions)

    def test_none_revision_is_allowed(self):
        env_regions = {
            "staging": {
                "us-east-1": {"git": {"revision": None}},
            }
        }
        validate_config_revisions(env_regions)

    def test_missing_revision_key_is_allowed(self):
        env_regions = {
            "staging": {
                "us-east-1": {},
            }
        }
        validate_config_revisions(env_regions)

    def test_rejects_invalid_hash(self):
        env_regions = {
            "staging": {
                "us-east-1": {"git": {"revision": "not-a-hash!"}},
            }
        }
        with pytest.raises(ValueError, match="Invalid commit hash"):
            validate_config_revisions(env_regions)

    def test_rejects_too_short_hash(self):
        env_regions = {
            "staging": {
                "us-east-1": {"git": {"revision": "abc12"}},
            }
        }
        with pytest.raises(ValueError, match="Invalid commit hash"):
            validate_config_revisions(env_regions)

    def test_rejects_uppercase_hex(self):
        env_regions = {
            "staging": {
                "us-east-1": {"git": {"revision": "ABC1234"}},
            }
        }
        with pytest.raises(ValueError, match="Invalid commit hash"):
            validate_config_revisions(env_regions)


# =============================================================================
# deep_merge
# =============================================================================


class TestDeepMerge:
    def test_flat_merge(self):
        assert deep_merge({"a": 1}, {"b": 2}) == {"a": 1, "b": 2}

    def test_overlay_overrides_base(self):
        assert deep_merge({"a": 1}, {"a": 2}) == {"a": 2}

    def test_nested_merge(self):
        base = {"x": {"a": 1, "b": 2}}
        overlay = {"x": {"b": 3, "c": 4}}
        assert deep_merge(base, overlay) == {"x": {"a": 1, "b": 3, "c": 4}}

    def test_deeply_nested_merge(self):
        base = {"x": {"y": {"a": 1}}}
        overlay = {"x": {"y": {"b": 2}}}
        assert deep_merge(base, overlay) == {"x": {"y": {"a": 1, "b": 2}}}

    def test_overlay_replaces_non_dict_with_dict(self):
        assert deep_merge({"a": 1}, {"a": {"nested": True}}) == {
            "a": {"nested": True}
        }

    def test_overlay_replaces_dict_with_non_dict(self):
        assert deep_merge({"a": {"nested": True}}, {"a": "flat"}) == {"a": "flat"}

    def test_does_not_mutate_base(self):
        base = {"a": {"b": 1}}
        overlay = {"a": {"c": 2}}
        deep_merge(base, overlay)
        assert base == {"a": {"b": 1}}

    def test_empty_base(self):
        assert deep_merge({}, {"a": 1}) == {"a": 1}

    def test_empty_overlay(self):
        assert deep_merge({"a": 1}, {}) == {"a": 1}

    def test_both_empty(self):
        assert deep_merge({}, {}) == {}


# =============================================================================
# resolve_templates
# =============================================================================


class TestResolveTemplates:
    def test_simple_string_substitution(self):
        result = resolve_templates("hello {{ name }}", {"name": "world"})
        assert result == "hello world"

    def test_no_template_in_string(self):
        assert resolve_templates("plain text", {}) == "plain text"

    def test_dict_values_resolved(self):
        data = {"key": "{{ env }}-value", "static": "no-change"}
        result = resolve_templates(data, {"env": "prod"})
        assert result == {"key": "prod-value", "static": "no-change"}

    def test_list_values_resolved(self):
        data = ["{{ a }}", "{{ b }}"]
        result = resolve_templates(data, {"a": "x", "b": "y"})
        assert result == ["x", "y"]

    def test_nested_structures(self):
        data = {"outer": {"inner": "{{ val }}"}}
        result = resolve_templates(data, {"val": "resolved"})
        assert result == {"outer": {"inner": "resolved"}}

    def test_non_string_passthrough(self):
        assert resolve_templates(42, {}) == 42
        assert resolve_templates(True, {}) is True
        assert resolve_templates(None, {}) is None

    def test_mixed_list(self):
        data = ["{{ x }}", 42, {"k": "{{ x }}"}]
        result = resolve_templates(data, {"x": "val"})
        assert result == ["val", 42, {"k": "val"}]


# =============================================================================
# write_output
# =============================================================================


class TestWriteOutput:
    def test_creates_file_with_content(self, tmp_path):
        output = tmp_path / "sub" / "output.txt"
        write_output("hello world", output)
        assert output.exists()
        assert output.read_text() == "hello world\n"

    def test_creates_parent_directories(self, tmp_path):
        output = tmp_path / "deep" / "nested" / "dir" / "file.txt"
        write_output("content", output)
        assert output.exists()

    def test_adds_trailing_newline(self, tmp_path):
        output = tmp_path / "file.txt"
        write_output("no newline", output)
        assert output.read_text().endswith("\n")

    def test_preserves_existing_trailing_newline(self, tmp_path):
        output = tmp_path / "file.txt"
        write_output("has newline\n", output)
        content = output.read_text()
        assert content == "has newline\n"
        assert not content.endswith("\n\n")


# =============================================================================
# get_cluster_types
# =============================================================================


class TestGetClusterTypes:
    def test_finds_cluster_directories(self, tmp_path):
        (tmp_path / "regional-cluster").mkdir()
        (tmp_path / "management-cluster").mkdir()
        (tmp_path / "shared").mkdir()  # should be excluded
        (tmp_path / "some-file.txt").touch()  # should be excluded

        result = sorted(get_cluster_types(tmp_path))
        assert result == ["management-cluster", "regional-cluster"]

    def test_excludes_hidden_directories(self, tmp_path):
        (tmp_path / ".hidden-cluster").mkdir()
        (tmp_path / "regional-cluster").mkdir()

        result = get_cluster_types(tmp_path)
        assert result == ["regional-cluster"]

    def test_returns_empty_for_no_clusters(self, tmp_path):
        (tmp_path / "shared").mkdir()
        (tmp_path / "something-else").mkdir()

        assert get_cluster_types(tmp_path) == []


# =============================================================================
# build_region_definitions
# =============================================================================


class TestBuildRegionDefinitions:
    def test_single_region_no_mcs(self):
        region_configs = {
            "us-east-1": {},
        }
        result = build_region_definitions("staging", ["us-east-1"], region_configs, "")
        assert "us-east-1" in result
        entry = result["us-east-1"]
        assert entry["name"] == "staging"
        assert entry["environment"] == "staging"
        assert entry["aws_region"] == "us-east-1"
        assert entry["management_clusters"] == []

    def test_multiple_regions(self):
        region_configs = {
            "us-east-1": {},
            "us-west-2": {},
        }
        result = build_region_definitions(
            "prod", ["us-east-1", "us-west-2"], region_configs, ""
        )
        assert len(result) == 2
        assert "us-east-1" in result
        assert "us-west-2" in result

    def test_management_clusters_listed(self):
        region_configs = {
            "us-east-1": {
                "management_clusters": {
                    "mc01": {},
                    "mc02": {},
                },
            },
        }
        result = build_region_definitions("staging", ["us-east-1"], region_configs, "")
        assert sorted(result["us-east-1"]["management_clusters"]) == ["mc01", "mc02"]

    def test_ci_prefix_applied_to_mc_ids(self):
        region_configs = {
            "us-east-1": {
                "management_clusters": {
                    "mc01": {},
                },
            },
        }
        result = build_region_definitions(
            "staging", ["us-east-1"], region_configs, "xg4y"
        )
        assert result["us-east-1"]["management_clusters"] == ["xg4y-mc01"]


# =============================================================================
# create_applicationset_content
# =============================================================================


class TestCreateApplicationsetContent:
    def _write_base_applicationset(self, base_dir):
        appset_dir = base_dir / "applicationset"
        appset_dir.mkdir(parents=True)
        appset = {
            "spec": {
                "generators": [
                    {
                        "matrix": {
                            "generators": [
                                {"clusters": {}},
                                {"git": {"revision": "HEAD"}},
                            ]
                        }
                    }
                ],
                "template": {
                    "spec": {
                        "sources": [
                            {"targetRevision": "HEAD", "path": "chart"},
                            {"targetRevision": "HEAD", "ref": "values"},
                        ]
                    }
                },
            }
        }
        base_path = appset_dir / "base-applicationset.yaml"
        with open(base_path, "w") as f:
            yaml.dump(appset, f)
        return base_path

    def test_without_config_revision(self, tmp_path):
        base_path = self._write_base_applicationset(tmp_path)
        result = create_applicationset_content(base_path, None)
        parsed = yaml.safe_load(result)
        git_gen = parsed["spec"]["generators"][0]["matrix"]["generators"][1]["git"]
        assert git_gen["revision"] == "HEAD"

    def test_with_config_revision(self, tmp_path):
        base_path = self._write_base_applicationset(tmp_path)
        result = create_applicationset_content(base_path, "abc1234def5")
        parsed = yaml.safe_load(result)
        git_gen = parsed["spec"]["generators"][0]["matrix"]["generators"][1]["git"]
        assert git_gen["revision"] == "abc1234def5"
        sources = parsed["spec"]["template"]["spec"]["sources"]
        assert sources[0]["targetRevision"] == "abc1234def5"
        # Second source (ref: values) should keep original
        assert sources[1]["targetRevision"] == "HEAD"


# =============================================================================
# cleanup_stale_files
# =============================================================================


class TestCleanupStaleFiles:
    def test_removes_stale_environment(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        stale_dir = deploy_dir / "old-env" / "us-east-1"
        stale_dir.mkdir(parents=True)
        (stale_dir / "file.txt").touch()

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": set()}},
            deploy_dir=deploy_dir,
        )

        assert not (deploy_dir / "old-env").exists()

    def test_removes_stale_region(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        stale_dir = deploy_dir / "staging" / "us-west-2"
        stale_dir.mkdir(parents=True)
        (stale_dir / "file.txt").touch()
        valid_dir = deploy_dir / "staging" / "us-east-1"
        valid_dir.mkdir(parents=True)

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": set()}},
            deploy_dir=deploy_dir,
        )

        assert not (deploy_dir / "staging" / "us-west-2").exists()
        assert (deploy_dir / "staging" / "us-east-1").exists()

    def test_keeps_valid_region(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        valid_dir = deploy_dir / "staging" / "us-east-1"
        valid_dir.mkdir(parents=True)
        (valid_dir / "file.txt").touch()

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": set()}},
            deploy_dir=deploy_dir,
        )

        assert (deploy_dir / "staging" / "us-east-1").exists()

    def test_removes_stale_mc_input_directories(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        region_dir = deploy_dir / "staging" / "us-east-1"
        # Valid MC dir
        (region_dir / "pipeline-management-cluster-mc01-inputs").mkdir(parents=True)
        # Stale MC dir
        (region_dir / "pipeline-management-cluster-mc02-inputs").mkdir(parents=True)

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": {"mc01"}}},
            deploy_dir=deploy_dir,
        )

        assert (
            region_dir / "pipeline-management-cluster-mc01-inputs"
        ).exists()
        assert not (
            region_dir / "pipeline-management-cluster-mc02-inputs"
        ).exists()

    def test_removes_stale_mc_provisioner_files(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        prov_dir = deploy_dir / "staging" / "us-east-1" / "pipeline-provisioner-inputs"
        prov_dir.mkdir(parents=True)
        (prov_dir / "management-cluster-mc01.json").touch()
        (prov_dir / "management-cluster-mc02.json").touch()  # stale

        cleanup_stale_files(
            valid_envs={"staging"},
            env_regions={"staging": {"us-east-1"}},
            env_region_mcs={"staging": {"us-east-1": {"mc01"}}},
            deploy_dir=deploy_dir,
        )

        assert (prov_dir / "management-cluster-mc01.json").exists()
        assert not (prov_dir / "management-cluster-mc02.json").exists()

    def test_no_op_when_deploy_dir_missing(self, tmp_path):
        deploy_dir = tmp_path / "nonexistent"
        cleanup_stale_files(
            valid_envs=set(),
            env_regions={},
            env_region_mcs={},
            deploy_dir=deploy_dir,
        )  # should not raise

    def test_ignores_hidden_directories(self, tmp_path):
        deploy_dir = tmp_path / "deploy"
        hidden = deploy_dir / ".hidden"
        hidden.mkdir(parents=True)
        (hidden / "file.txt").touch()

        cleanup_stale_files(
            valid_envs=set(),
            env_regions={},
            env_region_mcs={},
            deploy_dir=deploy_dir,
        )

        assert hidden.exists()


# =============================================================================
# Integration tests: config merge + output files
# =============================================================================


class TestConfigMergeAndRendering:
    """Tests that exercise the full merge chain (global -> env -> region)
    by creating config structures and verifying the merged output."""

    def test_deep_merge_inheritance(self, tmp_path):
        """Global defaults are merged with env defaults and region config."""
        global_defaults = {
            "terraform_common": {"app_code": "infra", "service_phase": "dev"},
        }
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults=global_defaults,
            environments={
                "staging": {
                    "defaults": {"terraform_common": {"service_phase": "staging"}},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        # Manually perform the merge as main() would
        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        assert merged["terraform_common"]["app_code"] == "infra"
        assert merged["terraform_common"]["service_phase"] == "staging"

    def test_region_level_overrides_env_and_defaults(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"terraform_common": {"key": "default"}},
            environments={
                "staging": {
                    "defaults": {"terraform_common": {"key": "env"}},
                    "regions": {
                        "us-east-1": {
                            "terraform_common": {"key": "region"},
                            "management_clusters": {},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        assert merged["terraform_common"]["key"] == "region"

    def test_jinja2_templates_resolved_in_terraform(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "terraform_common": {
                    "region": "{{ aws_region }}",
                    "env": "{{ environment }}",
                },
            },
            environments={
                "prod": {
                    "defaults": {},
                    "regions": {
                        "eu-west-1": {"management_clusters": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "prod" / "defaults.yaml")
        rc = load_yaml(config_dir / "prod" / "eu-west-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        context = dict(merged)
        context["aws_region"] = "eu-west-1"
        context["environment"] = "prod"
        resolved = resolve_templates(context.get("terraform_common", {}), context)
        assert resolved["region"] == "eu-west-1"
        assert resolved["env"] == "prod"

    def test_management_clusters_in_region(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "management_clusters": {
                                "mc01": {"account_id": "111"},
                                "mc02": {"account_id": "222"},
                            },
                        },
                    },
                }
            },
        )

        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        mc_dict = rc.get("management_clusters", {})
        assert len(mc_dict) == 2
        assert "mc01" in mc_dict
        assert "mc02" in mc_dict

    def test_management_cluster_default_account_id(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"management_cluster_account_id": "default-mc-account"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "management_clusters": {"mc01": {}},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        # Simulate what main() does for MC default account_id
        default_mc_account_id = merged.get("aws", {}).get("management_cluster_account_id")
        mc_dict = merged.get("management_clusters", {})
        for mc_key, mc_val in mc_dict.items():
            mc_entry = dict(mc_val) if mc_val else {}
            if "account_id" not in mc_entry and default_mc_account_id:
                mc_entry["account_id"] = default_mc_account_id
            assert mc_entry["account_id"] == "default-mc-account"

    def test_management_cluster_explicit_account_overrides_default(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"management_cluster_account_id": "default-mc-account"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "management_clusters": {
                                "mc01": {"account_id": "explicit-account"},
                            },
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        default_mc_account_id = merged.get("aws", {}).get("management_cluster_account_id")
        mc_dict = merged.get("management_clusters", {})
        for mc_key, mc_val in mc_dict.items():
            mc_entry = dict(mc_val) if mc_val else {}
            if "account_id" not in mc_entry and default_mc_account_id:
                mc_entry["account_id"] = default_mc_account_id
            assert mc_entry["account_id"] == "explicit-account"

    def test_ci_prefix_applied_to_management_id(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "management_clusters": {"mc01": {}},
                        },
                    },
                }
            },
        )

        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        mc_dict = rc.get("management_clusters", {})
        ci_prefix = "xg4y"
        for mc_key in mc_dict:
            mc_id = f"{ci_prefix}-{mc_key}" if ci_prefix else mc_key
            assert mc_id == "xg4y-mc01"

    def test_ci_prefix_applied_to_regional_id(self):
        ci_prefix = "xg4y"
        regional_id = f"{ci_prefix}-regional" if ci_prefix else "regional"
        assert regional_id == "xg4y-regional"

    def test_no_ci_prefix(self):
        ci_prefix = ""
        regional_id = f"{ci_prefix}-regional" if ci_prefix else "regional"
        assert regional_id == "regional"
        mc_key = "mc01"
        mc_id = f"{ci_prefix}-{mc_key}" if ci_prefix else mc_key
        assert mc_id == "mc01"

    def test_revision_inheritance(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"git": {"revision": "main"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "git": {"revision": "abc1234"},
                            "management_clusters": {},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        assert merged["git"]["revision"] == "abc1234"

    def test_revision_falls_back_to_defaults(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"git": {"revision": "main"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        assert merged["git"]["revision"] == "main"

    def test_argocd_merge_chain(self, tmp_path):
        """argocd values merge through defaults -> env -> region."""
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "argocd": {
                    "regional-cluster": {"setting": "default", "shared": "from-defaults"},
                },
            },
            environments={
                "staging": {
                    "defaults": {
                        "argocd": {
                            "regional-cluster": {"setting": "env-override"},
                        },
                    },
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        argocd = merged["argocd"]
        assert argocd["regional-cluster"]["setting"] == "env-override"
        assert argocd["regional-cluster"]["shared"] == "from-defaults"

    def test_arbitrary_field_inherits_without_code_changes(self, tmp_path):
        """Any field inherits through the full merge chain."""
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"custom_field": "from-defaults", "only_in_defaults": True},
            environments={
                "staging": {
                    "defaults": {"custom_field": "from-env"},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)
        assert merged["custom_field"] == "from-env"
        assert merged["only_in_defaults"] is True

    def test_account_id_template_resolution(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "account-{{ environment }}-{{ aws_region }}"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        context = dict(merged)
        context["environment"] = "staging"
        context["aws_region"] = "us-east-1"
        resolved_account_id = resolve_templates(context.get("aws", {}).get("account_id", ""), context)
        assert resolved_account_id == "account-staging-us-east-1"

    def test_management_cluster_template_with_cluster_prefix(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={
                "aws": {"management_cluster_account_id": "mc-{{ cluster_prefix }}-{{ aws_region }}"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "management_clusters": {"mc01": {}},
                        },
                    },
                }
            },
        )

        gd = load_yaml(config_dir / "defaults.yaml")
        ed = load_yaml(config_dir / "staging" / "defaults.yaml")
        rc = load_yaml(config_dir / "staging" / "us-east-1.yaml")
        merged = deep_merge(gd, ed)
        merged = deep_merge(merged, rc)

        context = dict(merged)
        context["environment"] = "staging"
        context["aws_region"] = "us-east-1"
        context["account_id"] = resolve_templates(
            context.get("aws", {}).get("account_id", ""), context
        )

        default_mc_account_id = merged.get("aws", {}).get("management_cluster_account_id")
        mc_dict = merged.get("management_clusters", {})
        for mc_key, mc_val in mc_dict.items():
            mc_entry = dict(mc_val) if mc_val else {}
            if "account_id" not in mc_entry and default_mc_account_id:
                mc_entry["account_id"] = default_mc_account_id
            mc_context = dict(context)
            mc_context["cluster_prefix"] = mc_key
            mc_entry = resolve_templates(mc_entry, mc_context)
            assert mc_entry["account_id"] == "mc-mc01-us-east-1"


# =============================================================================
# Integration tests: full main() run
# =============================================================================


class TestMainIntegration:
    """Tests that run main() end-to-end and verify deploy/ output files.

    These tests create temporary config and argocd directories,
    then invoke main() by monkeypatching the module-level path computation.
    """

    def _run_main(self, tmp_path, global_defaults, environments, ci_prefix=""):
        """Helper to run main() with a tmp_path-based project root."""
        import sys
        import render

        config_dir = _create_config_structure(
            tmp_path,
            global_defaults=global_defaults,
            environments=environments,
        )
        _create_argocd_config(tmp_path)

        deploy_dir = tmp_path / "deploy"

        # Patch sys.argv
        old_argv = sys.argv
        args = ["render.py", "--config-dir", str(config_dir)]
        if ci_prefix:
            args.extend(["--ci-prefix", ci_prefix])
        sys.argv = args

        # Patch the project_root derivation in main()
        # main() does: script_dir = Path(__file__).parent; project_root = script_dir.parent
        # We need deploy_dir and argocd_config_dir to point to tmp_path
        # The easiest way: temporarily change render.__file__
        old_file = render.__file__
        render.__file__ = str(tmp_path / "scripts" / "render.py")

        try:
            result = main()
        finally:
            sys.argv = old_argv
            render.__file__ = old_file

        assert result == 0, "main() should return 0 on success"
        return deploy_dir

    def test_region_definitions_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        region_defs_file = deploy_dir / "staging" / "region-definitions.json"
        assert region_defs_file.exists()
        data = json.loads(region_defs_file.read_text())
        assert "us-east-1" in data
        entry = data["us-east-1"]
        assert entry["name"] == "staging"
        assert entry["environment"] == "staging"
        assert entry["aws_region"] == "us-east-1"

    def test_region_definitions_multiple_regions(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "prod": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                        "us-west-2": {"management_clusters": {}},
                    },
                }
            },
        )

        region_defs_file = deploy_dir / "prod" / "region-definitions.json"
        data = json.loads(region_defs_file.read_text())
        assert len(data) == 2
        assert "us-east-1" in data
        assert "us-west-2" in data

    def test_region_definitions_multiple_environments(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                },
                "prod": {
                    "defaults": {},
                    "regions": {
                        "eu-west-1": {"management_clusters": {}},
                    },
                },
            },
        )

        assert (deploy_dir / "staging" / "region-definitions.json").exists()
        assert (deploy_dir / "prod" / "region-definitions.json").exists()

    def test_region_definitions_with_management_clusters(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "management_clusters": {
                                "mc01": {},
                                "mc02": {},
                            },
                        },
                    },
                }
            },
        )

        region_defs_file = deploy_dir / "staging" / "region-definitions.json"
        data = json.loads(region_defs_file.read_text())
        assert sorted(data["us-east-1"]["management_clusters"]) == ["mc01", "mc02"]

    def test_pipeline_provisioner_terraform_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"dns": {"domain": "test.example.com"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "terraform.json"
        )
        assert tf_file.exists()
        data = json.loads(tf_file.read_text())
        assert data["domain"] == "test.example.com"

    def test_pipeline_provisioner_regional_cluster_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"aws": {"account_id": "111111111111"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        rc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "regional-cluster.json"
        )
        assert rc_file.exists()
        data = json.loads(rc_file.read_text())
        assert data["region"] == "us-east-1"
        assert data["regional_id"] == "regional"
        assert data["account_id"] == "111111111111"

    def test_pipeline_provisioner_management_cluster_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {
                    "account_id": "999999999999",
                    "management_cluster_account_id": "111111111111",
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "management_clusters": {"mc01": {}},
                        },
                    },
                }
            },
        )

        mc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "management-cluster-mc01.json"
        )
        assert mc_file.exists()
        data = json.loads(mc_file.read_text())
        assert data["management_id"] == "mc01"
        assert data["account_id"] == "111111111111"
        assert data["region"] == "us-east-1"

    def test_pipeline_regional_cluster_inputs_terraform_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111111111111"},
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        assert tf_file.exists()
        data = json.loads(tf_file.read_text())
        assert data["app_code"] == "infra"
        assert data["regional_id"] == "regional"
        assert data["sector"] == "staging"
        assert data["environment"] == "staging"
        assert data["region"] == "us-east-1"
        assert data["_generated"].startswith("DO NOT EDIT")

    def test_pipeline_management_cluster_inputs_terraform_json(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {
                    "account_id": "999999999999",
                    "management_cluster_account_id": "111111111111",
                },
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "management_clusters": {
                                "mc01": {},
                            },
                        },
                    },
                }
            },
        )

        mc_tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-management-cluster-mc01-inputs"
            / "terraform.json"
        )
        assert mc_tf_file.exists()
        data = json.loads(mc_tf_file.read_text())
        assert data["management_id"] == "mc01"
        assert data["account_id"] == "111111111111"
        assert data["regional_aws_account_id"] == "999999999999"
        assert data["app_code"] == "infra"

    def test_mc_account_ids_added_to_regional_terraform(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "999"},
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "management_clusters": {
                                "mc01": {"account_id": "111"},
                                "mc02": {"account_id": "222"},
                            },
                        },
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        data = json.loads(tf_file.read_text())
        assert sorted(data["management_cluster_account_ids"]) == ["111", "222"]

    def test_argocd_values_files(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "argocd": {
                    "regional-cluster": {"setting": "value"},
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        values_file = (
            deploy_dir / "staging" / "us-east-1" / "argocd-values-regional-cluster.yaml"
        )
        assert values_file.exists()
        content = values_file.read_text()
        assert "setting: value" in content
        assert "GENERATED FILE" in content

    def test_argocd_values_empty_creates_file(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        values_file = (
            deploy_dir / "staging" / "us-east-1" / "argocd-values-regional-cluster.yaml"
        )
        assert values_file.exists()

    def test_argocd_bootstrap_applicationset(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        appset_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "argocd-bootstrap-regional-cluster"
            / "applicationset.yaml"
        )
        assert appset_file.exists()
        content = appset_file.read_text()
        assert "GENERATED FILE" in content

    def test_argocd_bootstrap_pinned_revision(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "git": {"revision": "abc1234def5678901234567890abcdef12345678"},
                            "management_clusters": {},
                        },
                    },
                }
            },
        )

        appset_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "argocd-bootstrap-regional-cluster"
            / "applicationset.yaml"
        )
        content = appset_file.read_text()
        assert "abc1234d" in content  # truncated hash in header

    def test_argocd_bootstrap_main_revision_not_pinned(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={"git": {"revision": "main"}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        appset_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "argocd-bootstrap-regional-cluster"
            / "applicationset.yaml"
        )
        content = appset_file.read_text()
        assert "metadata.annotations.git_revision" in content

    def test_ci_prefix_in_regional_id(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111111111111"},
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
            ci_prefix="xg4y",
        )

        rc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "regional-cluster.json"
        )
        data = json.loads(rc_file.read_text())
        assert data["regional_id"] == "xg4y-regional"

    def test_ci_prefix_in_management_id(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {
                    "account_id": "999",
                    "management_cluster_account_id": "111",
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {
                            "management_clusters": {"mc01": {}},
                        },
                    },
                }
            },
            ci_prefix="xg4y",
        )

        mc_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "management-cluster-xg4y-mc01.json"
        )
        assert mc_file.exists()
        data = json.loads(mc_file.read_text())
        assert data["management_id"] == "xg4y-mc01"

    def test_sector_defaults_to_env_name(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111"},
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "staging"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        data = json.loads(tf_file.read_text())
        assert data["sector"] == "staging"

    def test_sector_from_config(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={
                "aws": {"account_id": "111"},
                "terraform_common": {
                    "app_code": "infra",
                    "service_phase": "dev",
                    "cost_center": "000",
                    "enable_bastion": False,
                },
            },
            environments={
                "prod": {
                    "defaults": {"sector": "sector-a"},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "prod"
            / "us-east-1"
            / "pipeline-regional-cluster-inputs"
            / "terraform.json"
        )
        data = json.loads(tf_file.read_text())
        assert data["sector"] == "sector-a"

    def test_domain_in_provisioner_terraform(self, tmp_path):
        deploy_dir = self._run_main(
            tmp_path,
            global_defaults={},
            environments={
                "integration": {
                    "defaults": {"dns": {"domain": "int0.rosa.devshift.net"}},
                    "regions": {
                        "us-east-1": {"management_clusters": {}},
                    },
                }
            },
        )

        tf_file = (
            deploy_dir
            / "integration"
            / "us-east-1"
            / "pipeline-provisioner-inputs"
            / "terraform.json"
        )
        data = json.loads(tf_file.read_text())
        assert data["domain"] == "int0.rosa.devshift.net"


# =============================================================================
# Check Documented Keys Tests
# =============================================================================


class TestCollectKeyPaths:
    def test_flat_dict(self):
        assert collect_key_paths({"a": 1, "b": 2}) == {"a", "b"}

    def test_nested_dict(self):
        result = collect_key_paths({"aws": {"account_id": "123"}})
        assert result == {"aws", "aws.account_id"}

    def test_deeply_nested(self):
        result = collect_key_paths({"a": {"b": {"c": 1}}})
        assert result == {"a", "a.b", "a.b.c"}


class TestScanTemplateVariables:
    def test_finds_variables_in_templates(self, tmp_path):
        tpl_dir = tmp_path / "templates"
        tpl_dir.mkdir()
        (tpl_dir / "test.json.j2").write_text('{{ dns.domain }}\n{% if delete %}yes{% endif %}')
        result = scan_template_variables(tpl_dir)
        assert "dns.domain" in result
        assert "delete" in result
        assert result["dns.domain"] == ["test.json.j2"]

    def test_ignores_builtins(self, tmp_path):
        tpl_dir = tmp_path / "templates"
        tpl_dir.mkdir()
        (tpl_dir / "test.j2").write_text("{{ loop.index }}")
        result = scan_template_variables(tpl_dir)
        assert "loop.index" not in result


class TestParseDocsSection:
    def test_parses_key_paths(self, tmp_path):
        defaults = tmp_path / "defaults.yaml"
        defaults.write_text(
            "key: value\n"
            "# @docs\n"
            "# dns.domain  → template.j2\n"
            "# aws         (render.py context)\n"
            "# @end-docs\n"
        )
        result = parse_docs_section(defaults)
        assert "dns.domain" in result
        assert "aws" in result

    def test_empty_without_section(self, tmp_path):
        defaults = tmp_path / "defaults.yaml"
        defaults.write_text("key: value\n")
        assert parse_docs_section(defaults) == set()


class TestUpdateDocs:
    def test_generates_docs_section(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"dns": {"domain": ""}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {"us-east-1": {}},
                }
            },
        )
        templates_dir = config_dir / "templates"
        templates_dir.mkdir(exist_ok=True)
        (templates_dir / "test.json.j2").write_text('{{ dns.domain }}')

        assert update_docs(config_dir, templates_dir) == 0

        content = (config_dir / "defaults.yaml").read_text()
        assert "# @docs" in content
        assert "# @end-docs" in content
        assert "dns.domain" in content
        assert "→ test.json.j2" in content

    def test_regenerates_existing_section(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"dns": {"domain": ""}},
            environments={
                "staging": {
                    "defaults": {},
                    "regions": {"us-east-1": {}},
                }
            },
        )
        templates_dir = config_dir / "templates"
        templates_dir.mkdir(exist_ok=True)
        (templates_dir / "test.json.j2").write_text('{{ dns.domain }}')

        # Run twice — should replace, not duplicate
        update_docs(config_dir, templates_dir)
        update_docs(config_dir, templates_dir)

        content = (config_dir / "defaults.yaml").read_text()
        assert content.count("# @docs") == 1
        assert content.count("# @end-docs") == 1


class TestCheckDocumentedKeys:
    def _make_templates_dir(self, tmp_path):
        tpl_dir = tmp_path / "config" / "templates"
        tpl_dir.mkdir(parents=True, exist_ok=True)
        return tpl_dir

    def test_all_documented(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"dns": {"domain": ""}},
            environments={
                "staging": {
                    "defaults": {"dns": {"domain": "example.com"}},
                    "regions": {"us-east-1": {}},
                }
            },
        )
        templates_dir = self._make_templates_dir(tmp_path)
        assert check_documented_keys(config_dir, templates_dir) == 0

    def test_undocumented_key_fails(self, tmp_path):
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={},
            environments={
                "staging": {
                    "defaults": {"new_thing": "value"},
                    "regions": {"us-east-1": {}},
                }
            },
        )
        templates_dir = self._make_templates_dir(tmp_path)
        assert check_documented_keys(config_dir, templates_dir) == 1

    def test_nested_key_documented_by_parent(self, tmp_path):
        """If 'aws' is in defaults, 'aws.new_field' in env config is fine."""
        config_dir = _create_config_structure(
            tmp_path,
            global_defaults={"aws": {"account_id": ""}},
            environments={
                "staging": {
                    "defaults": {"aws": {"new_field": "value"}},
                    "regions": {"us-east-1": {}},
                }
            },
        )
        templates_dir = self._make_templates_dir(tmp_path)
        assert check_documented_keys(config_dir, templates_dir) == 0

    def test_docs_section_key_counts_as_documented(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.yaml").write_text(
            "# @docs\n"
            "# management_clusters  (render.py context)\n"
            "# @end-docs\n"
        )
        env_dir = config_dir / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text(
            "management_clusters:\n  mc01: {}\n"
        )
        templates_dir = config_dir / "templates"
        templates_dir.mkdir()
        assert check_documented_keys(config_dir, templates_dir) == 0

    def test_invalid_template_path_fails(self, tmp_path):
        config_dir = tmp_path / "config"
        config_dir.mkdir()
        (config_dir / "defaults.yaml").write_text(
            "dns:\n  domain: ''\n"
            "# @docs\n"
            "# dns.domain  → nonexistent/template.j2\n"
            "# @end-docs\n"
        )
        env_dir = config_dir / "staging"
        env_dir.mkdir()
        (env_dir / "defaults.yaml").write_text("{}\n")
        (env_dir / "us-east-1.yaml").write_text("{}\n")
        templates_dir = config_dir / "templates"
        templates_dir.mkdir()
        assert check_documented_keys(config_dir, templates_dir) == 1

    def test_real_config(self):
        """Verify the actual project config passes the check."""
        config_dir = PROJECT_ROOT / "config"
        templates_dir = config_dir / "templates"
        assert check_documented_keys(config_dir, templates_dir) == 0


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
