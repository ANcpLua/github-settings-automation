#!/usr/bin/env python3
"""drift_check.py — Semantic config-drift detector across multiple GitHub repos.

For a watchlist of (file-path) pairs and a list of repos, fetches every version
of each file, normalises each per file type, clusters by *semantic* equivalence,
and reports drift.

Drift is *semantic* not byte-level: JSON key-order and whitespace, YAML
flow-style, .gitignore line ordering, XML attribute order all collapse to the
same equivalence class.

Usage:
  drift_check.py --policy drift-policy.yaml \
                 --output drift-report.md \
                 --manifest drift-manifest.json

Exit codes:
  0  no drift
  1  drift detected
  2  configuration or authentication error

Auth: uses the `gh` CLI (must be `gh auth login`'d). Hits the contents API for
every (repo, path) pair, so cost is O(repos * paths) requests.
"""

from __future__ import annotations

import argparse
import base64
import collections
import hashlib
import json
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

try:
    import yaml
except ImportError:
    print("error: PyYAML required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


# ---------------------------------------------------------------------------
# GitHub access via gh CLI
# ---------------------------------------------------------------------------

def gh_api(endpoint: str) -> dict | None:
    """Call `gh api`, return parsed JSON. None on 404. Exits on other errors."""
    res = subprocess.run(
        ["gh", "api", endpoint],
        capture_output=True, text=True
    )
    if res.returncode != 0:
        if "Not Found" in res.stderr or "404" in res.stderr:
            return None
        print(f"gh api {endpoint} failed:\n{res.stderr}", file=sys.stderr)
        sys.exit(2)
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError as e:
        print(f"could not parse response for {endpoint}: {e}", file=sys.stderr)
        sys.exit(2)


def fetch_file(repo: str, path: str) -> bytes | None:
    """Fetch raw file bytes for repo/path. None if file missing."""
    # gh api accepts /-paths directly when passed as endpoint, no URL-encoding
    # needed for the slash in `contents/<path>`.
    result = gh_api(f"repos/{repo}/contents/{path}")
    if result is None:
        return None
    content = result.get("content")
    if not content:
        return None
    return base64.b64decode(content)


# ---------------------------------------------------------------------------
# Normalisers — bytes → canonical-string
# ---------------------------------------------------------------------------

def norm_raw(data: bytes) -> str:
    """Bytes as UTF-8 string, stripped. Last-resort normaliser."""
    return data.decode("utf-8", errors="replace").strip()


def norm_lines_sorted(data: bytes) -> str:
    """Ignore-style files (.gitignore, .dockerignore, .gitattributes, etc.):
    strip blank lines and comments, dedupe, sort, join."""
    text = data.decode("utf-8", errors="replace")
    lines = set()
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        lines.add(s)
    return "\n".join(sorted(lines))


def norm_json(data: bytes) -> str:
    """Parse JSON, dump in canonical sorted form."""
    obj = json.loads(data.decode("utf-8"))
    return json.dumps(obj, sort_keys=True, indent=2, ensure_ascii=False)


def norm_yaml(data: bytes) -> str:
    """Parse YAML, dump in canonical sorted form."""
    obj = yaml.safe_load(data.decode("utf-8"))
    return yaml.dump(obj, sort_keys=True, default_flow_style=False, allow_unicode=True)


def _canonicalize_xml(elt: ET.Element) -> None:
    """Strip insignificant whitespace from text/tail; sort attributes."""
    if elt.text and not elt.text.strip():
        elt.text = None
    if elt.tail and not elt.tail.strip():
        elt.tail = None
    # Sort attributes for deterministic output
    if elt.attrib:
        items = sorted(elt.attrib.items())
        elt.attrib.clear()
        for k, v in items:
            elt.attrib[k] = v
    for child in elt:
        _canonicalize_xml(child)


def norm_xml(data: bytes) -> str:
    """Parse XML, normalise whitespace and attribute order, dump."""
    root = ET.fromstring(data.decode("utf-8"))
    _canonicalize_xml(root)
    return ET.tostring(root, encoding="unicode")


def norm_ini(data: bytes) -> str:
    """INI-like files (.editorconfig, .gitmodules, .npmrc, .globalconfig):
    parse sections + key=value pairs, sort, dump."""
    text = data.decode("utf-8", errors="replace")
    entries: dict[str, str] = {}
    section = ""
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.startswith(";"):
            continue
        if s.startswith("[") and s.endswith("]"):
            section = s[1:-1].strip()
            continue
        if "=" in s:
            k, v = s.split("=", 1)
            entries[f"{section}/{k.strip()}"] = v.strip()
    return "\n".join(f"{k}={v}" for k, v in sorted(entries.items()))


NORMALISERS = {
    "raw": norm_raw,
    "lines": norm_lines_sorted,
    "json": norm_json,
    "yaml": norm_yaml,
    "xml": norm_xml,
    "ini": norm_ini,
}


# Default file-name → normaliser mapping.
DEFAULT_NORMALISERS = {
    # JSON
    "renovate.json": "json",
    "package.json": "json",
    ".markdownlint.json": "json",
    "global.json": "json",
    ".prettierrc": "json",
    # YAML
    ".coderabbit.yaml": "yaml",
    ".codecov.yml": "yaml",
    "codecov.yml": "yaml",
    "dependabot.yml": "yaml",
    # Line-based ignore files
    ".gitattributes": "lines",
    ".gitignore": "lines",
    ".dockerignore": "lines",
    ".markdownlintignore": "lines",
    # INI-like
    ".gitmodules": "ini",
    ".editorconfig": "ini",
    ".globalconfig": "ini",
    ".npmrc": "ini",
    # XML
    "nuget.config": "xml",
    "Directory.Build.props": "xml",
    "Directory.Build.targets": "xml",
    "Directory.Packages.props": "xml",
    "Version.props": "xml",
    # Raw
    "LICENSE": "raw",
    "build.sh": "raw",
    "build.cmd": "raw",
    "build.ps1": "raw",
}

SUFFIX_NORMALISERS = {
    ".json": "json", ".yaml": "yaml", ".yml": "yaml",
    ".xml": "xml", ".props": "xml", ".targets": "xml", ".csproj": "xml",
}


def get_normaliser(path: str) -> str:
    """Resolve normaliser key for a given file path."""
    name = path.rsplit("/", 1)[-1]
    if name in DEFAULT_NORMALISERS:
        return DEFAULT_NORMALISERS[name]
    for suffix, norm in SUFFIX_NORMALISERS.items():
        if name.endswith(suffix):
            return norm
    return "raw"


# ---------------------------------------------------------------------------
# Clustering and reporting
# ---------------------------------------------------------------------------

def hash_str(s: str) -> str:
    """Stable short hash for clustering."""
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:12]


def cluster_versions(repo_versions: dict[str, str]) -> list[dict]:
    """Group repos by normalised-content equivalence class. Largest first."""
    clusters: dict[str, list[str]] = collections.defaultdict(list)
    for repo, normalised in repo_versions.items():
        clusters[hash_str(normalised)].append(repo)
    return [
        {"hash": h, "size": len(repos), "repos": sorted(repos)}
        for h, repos in sorted(clusters.items(), key=lambda kv: -len(kv[1]))
    ]


def check_path(repos: list[str], entry: dict) -> dict:
    """Audit one watched path across all repos."""
    path = entry["path"]
    normaliser_name = entry.get("normalizer") or get_normaliser(path)
    norm_func = NORMALISERS.get(normaliser_name)
    if not norm_func:
        return {
            "path": path,
            "normalizer": normaliser_name,
            "error": f"unknown normaliser: {normaliser_name}",
        }

    repo_versions: dict[str, str] = {}
    repo_errors: dict[str, str] = {}
    for repo in repos:
        data = fetch_file(repo, path)
        if data is None:
            continue
        try:
            repo_versions[repo] = norm_func(data)
        except Exception as e:
            repo_errors[repo] = f"{type(e).__name__}: {e}"

    if not repo_versions:
        return {
            "path": path,
            "normalizer": normaliser_name,
            "present_in": 0,
            "clusters": [],
        }

    clusters = cluster_versions(repo_versions)
    return {
        "path": path,
        "normalizer": normaliser_name,
        "present_in": len(repo_versions),
        "absent_in": [r for r in repos if r not in repo_versions and r not in repo_errors],
        "clusters": clusters,
        "errors": repo_errors,
        "drift": len(clusters) > 1,
    }


# ---------------------------------------------------------------------------
# Output renderers
# ---------------------------------------------------------------------------

def write_markdown(findings: list[dict], path: str) -> int:
    """Write markdown report. Return drift count."""
    lines: list[str] = ["# Config Drift Report\n"]
    total = len(findings)
    drift = [f for f in findings if f.get("drift")]
    clean = [f for f in findings if not f.get("drift") and f.get("present_in", 0) > 0]
    missing = [f for f in findings if f.get("present_in", 0) == 0]

    lines.append(f"- Paths checked: **{total}**")
    lines.append(f"- Drifted: **{len(drift)}**")
    lines.append(f"- Clean (semantic 1-cluster): **{len(clean)}**")
    lines.append(f"- Not present in any repo: **{len(missing)}**\n")

    if drift:
        lines.append("## Drifted paths\n")
        for f in drift:
            lines.append(f"### `{f['path']}` (normaliser: `{f['normalizer']}`)")
            lines.append(f"_{f['present_in']} repos, {len(f['clusters'])} semantic clusters_\n")
            for i, c in enumerate(f["clusters"]):
                marker = "**canonical** (majority)" if i == 0 else f"drift #{i}"
                short_repos = ", ".join(r.split("/")[-1] for r in c["repos"])
                lines.append(f"- {marker} `{c['hash']}` ({c['size']}× ): {short_repos}")
            if f.get("errors"):
                lines.append("\n_Normalisation errors:_")
                for repo, err in f["errors"].items():
                    lines.append(f"  - `{repo.split('/')[-1]}`: {err}")
            lines.append("")

    if clean:
        lines.append("## Clean paths\n")
        lines.append("| Path | Repos | Hash |")
        lines.append("|---|---|---|")
        for f in clean:
            h = f["clusters"][0]["hash"] if f["clusters"] else "-"
            lines.append(f"| `{f['path']}` | {f['present_in']} | `{h}` |")
        lines.append("")

    if missing:
        lines.append("## Watched but absent everywhere\n")
        for f in missing:
            lines.append(f"- `{f['path']}`")
        lines.append("")

    Path(path).write_text("\n".join(lines) + "\n")
    return len(drift)


def write_manifest(findings: list[dict], path: str) -> None:
    """Machine-readable: which repos have which semantic cluster for which path."""
    Path(path).write_text(json.dumps({
        "version": 1,
        "findings": findings,
    }, indent=2))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--policy", required=True, help="Policy YAML file")
    p.add_argument("--output", default="drift-report.md", help="Markdown report path")
    p.add_argument("--manifest", default="drift-manifest.json", help="JSON manifest path")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args()

    policy_path = Path(args.policy)
    if not policy_path.exists():
        print(f"policy file not found: {args.policy}", file=sys.stderr)
        sys.exit(2)
    policy = yaml.safe_load(policy_path.read_text())

    repos = policy.get("repos") or []
    watch = policy.get("watch") or []
    if not repos or not watch:
        print("policy must define non-empty 'repos' and 'watch' lists", file=sys.stderr)
        sys.exit(2)

    findings: list[dict] = []
    for entry in watch:
        if isinstance(entry, str):
            entry = {"path": entry}
        if not args.quiet:
            print(f"checking {entry['path']} across {len(repos)} repos...", file=sys.stderr)
        findings.append(check_path(repos, entry))

    drift_count = write_markdown(findings, args.output)
    write_manifest(findings, args.manifest)

    if not args.quiet:
        print(f"\n{len(findings)} paths checked across {len(repos)} repos", file=sys.stderr)
        print(f"{drift_count} paths have drift", file=sys.stderr)
        print(f"report → {args.output}", file=sys.stderr)
        print(f"manifest → {args.manifest}", file=sys.stderr)

    sys.exit(1 if drift_count > 0 else 0)


if __name__ == "__main__":
    main()
