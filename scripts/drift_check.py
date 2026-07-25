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
    """Fetch raw file bytes for repo/path. None if file missing.

    Always uses the Contents API + base64 decode — never raw.githubusercontent.com,
    which is CDN-cached and lags ~5min behind merges, lying about post-merge state.
    """
    # gh api accepts /-paths directly when passed as endpoint, no URL-encoding
    # needed for the slash in `contents/<path>`.
    result = gh_api(f"repos/{repo}/contents/{path}")
    if result is None:
        return None
    content = result.get("content")
    if not content:
        return None
    return base64.b64decode(content)


def branch_protection(repo: str, branch: str = "main") -> dict | None:
    """Return the branch-protection payload for repo's default branch, or None
    if the branch is unprotected. Useful to route writes:

    * unprotected → ``gh api PUT /repos/X/Y/contents/<path>`` direct
    * protected → branch + PR + rely on native auto-merge when available

    Spec note: this is the *classic* branch-protection check. If the repo uses
    a ruleset instead (newer GitHub feature), call ``branch_rulesets()``.
    """
    result = gh_api(f"repos/{repo}/branches/{branch}/protection")
    return result  # None when 404 (= unprotected); dict otherwise


def branch_rulesets(repo: str) -> list[dict]:
    """Return active rulesets on the repo. Empty list means none.

    A repo with no classic branch-protection but with an active ruleset that
    enforces required reviews / status checks will still reject direct pushes
    to its default branch. Checking both is required to route correctly.
    """
    result = gh_api(f"repos/{repo}/rulesets")
    if not isinstance(result, list):
        return []
    return [rs for rs in result if rs.get("enforcement") == "active"]


def is_default_branch_writable(repo: str) -> bool:
    """True iff direct push to the default branch is allowed (no protection,
    no active ruleset targeting the branch).

    Use upfront to decide push-direct vs branch-then-PR for cross-repo writes.
    """
    if branch_protection(repo) is not None:
        return False
    # Any ruleset whose target is "branch" potentially blocks. We could check
    # the ruleset's conditions to be precise, but treating any active branch
    # ruleset as blocking is the safe default and matches the empirical pattern
    # in this fleet (rulesets always target the default branch when present).
    if any(rs.get("target") == "branch" for rs in branch_rulesets(repo)):
        return False
    return True


# ---------------------------------------------------------------------------
# Normalisers — bytes → canonical-string
# ---------------------------------------------------------------------------

def norm_raw(data: bytes) -> str:
    """Bytes as UTF-8 string, stripped. Last-resort normaliser."""
    return data.decode("utf-8", errors="replace").strip()


def norm_lines_set(data: bytes) -> str:
    """Line-based files where order is semantically irrelevant: strip blank
    lines and comments, dedupe, sort. Safe for files like ``.npmignore``-style
    pattern lists *only when* you have verified the consumer treats them as
    an unordered set.

    NOT SAFE for ``.gitignore`` or ``.gitattributes`` — git semantics give the
    LAST matching pattern precedence, so reordering can change behaviour. Use
    :func:`norm_lines_ordered` for those.
    """
    text = data.decode("utf-8", errors="replace")
    lines = set()
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        lines.add(s)
    return "\n".join(sorted(lines))


def norm_lines_ordered(data: bytes) -> str:
    """Line-based files where order matters: strip blank lines and comments,
    preserve order, collapse only adjacent duplicates.

    Required for ``.gitignore`` and ``.gitattributes``:

    * gitignore: within one precedence level, the last matching pattern
      decides whether a path is ignored.
    * gitattributes: when more than one pattern matches a path, the last
      matching line overrides earlier ones per attribute.

    Sorting these files would let two semantically different versions hash to
    the same cluster and silently pass a drift check.
    """
    text = data.decode("utf-8", errors="replace")
    out: list[str] = []
    prev: str | None = None
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s == prev:
            continue  # collapse adjacent duplicates only
        out.append(s)
        prev = s
    return "\n".join(out)


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
    "lines_set": norm_lines_set,           # order-irrelevant (use with care)
    "lines_ordered": norm_lines_ordered,   # order-sensitive (.gitignore et al.)
    "lines": norm_lines_ordered,           # alias — fail safe: assume order matters
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
    ".codecov.yml": "yaml",
    "codecov.yml": "yaml",
    "dependabot.yml": "yaml",
    # Line-based ignore files. All four use ordered normalisation because
    # the consumers (git, docker, markdownlint) all assign per-line precedence
    # where a later line can override an earlier one. Sorting would mask real
    # behavioural drift behind identical normalised hashes.
    ".gitattributes": "lines_ordered",
    ".gitignore": "lines_ordered",
    ".dockerignore": "lines_ordered",
    ".markdownlintignore": "lines_ordered",
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
# Staleness checks
#
# Cross-repo drift asks "do these repos agree with each other". Staleness asks
# a different question: "does this repo agree with an external source of truth".
# Two failures motivated this, both silent:
#
#   * a registry pin (SemConvGenAiRef) sat 9 upstream commits behind, so a new
#     upstream attribute simply did not exist in the generated surface, and
#     nothing said the pin was old;
#   * a version was bumped in Directory.Build.props and merged, but the publish
#     workflow was dispatch-only, so the version was never pushed — repo state
#     said released while the registry disagreed.
#
# Neither is detectable by comparing repos to each other. Both are trivially
# detectable against the upstream ref and the package registry respectively.
# ---------------------------------------------------------------------------

def read_xml_property(repo: str, path: str, prop: str) -> str | None:
    """Read a single MSBuild property value out of a props file in a repo."""
    data = fetch_file(repo, path)
    if data is None:
        return None
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return None
    value = root.findtext(f".//{prop}")
    return value.strip() if value and value.strip() else None


def upstream_head(repo: str, branch: str) -> str | None:
    """Commit SHA at the tip of an upstream branch."""
    ref = gh_api(f"/repos/{repo}/commits/{branch}")
    return ref.get("sha") if ref else None


def commits_behind(repo: str, base: str, head: str) -> int | None:
    """How many commits `base` is behind `head` in an upstream repo."""
    cmp = gh_api(f"/repos/{repo}/compare/{base}...{head}")
    if not cmp:
        return None
    return cmp.get("ahead_by")


def check_stale_pin(entry: dict) -> dict:
    """A pinned upstream commit that upstream has since moved past."""
    finding = {
        "kind": "stale_pin",
        "label": entry.get("label") or f"{entry['repo']}:{entry['property']}",
        "repo": entry["repo"],
        "path": entry["path"],
        "property": entry["property"],
        "upstream": entry["upstream"],
        "drift": False,
    }
    pinned = read_xml_property(entry["repo"], entry["path"], entry["property"])
    if not pinned:
        finding["error"] = f"could not read {entry['property']} from {entry['path']}"
        return finding
    finding["pinned"] = pinned

    branch = entry.get("branch", "main")
    head = upstream_head(entry["upstream"], branch)
    if not head:
        finding["error"] = f"could not resolve {entry['upstream']}@{branch}"
        return finding
    finding["upstream_head"] = head

    if pinned == head:
        return finding

    behind = commits_behind(entry["upstream"], pinned, head)
    finding["behind"] = behind
    # An unknown distance still means the pin != HEAD, which is the signal.
    threshold = int(entry.get("max_commits_behind", 0))
    finding["drift"] = behind is None or behind > threshold
    return finding


def registry_versions(kind: str, package: str) -> list[str] | None:
    """Published versions for a package. None when the lookup itself failed."""
    if kind == "nuget":
        url = f"https://api.nuget.org/v3-flatcontainer/{package.lower()}/index.json"
        key = "versions"
    elif kind == "npm":
        url = f"https://registry.npmjs.org/{package}"
        key = "versions"
    else:
        return None
    res = subprocess.run(
        ["curl", "-sS", "--retry", "2", "--retry-delay", "3", "--fail-with-body", url],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        return None
    try:
        doc = json.loads(res.stdout)
    except json.JSONDecodeError:
        return None
    versions = doc.get(key)
    if isinstance(versions, dict):      # npm returns an object
        return list(versions.keys())
    return versions if isinstance(versions, list) else None


def check_unpublished_version(entry: dict) -> dict:
    """A version committed to the repo that never reached the registry."""
    finding = {
        "kind": "unpublished_version",
        "label": entry.get("label") or f"{entry['repo']}:{entry['package']}",
        "repo": entry["repo"],
        "path": entry["path"],
        "property": entry.get("property", "Version"),
        "registry": entry.get("registry", "nuget"),
        "package": entry["package"],
        "drift": False,
    }
    declared = read_xml_property(entry["repo"], entry["path"], finding["property"])
    if not declared:
        finding["error"] = f"could not read {finding['property']} from {entry['path']}"
        return finding
    finding["declared"] = declared

    published = registry_versions(finding["registry"], entry["package"])
    if published is None:
        # Do not claim "unpublished" because the registry lookup broke.
        finding["error"] = f"{finding['registry']} lookup failed for {entry['package']}"
        return finding

    finding["latest_published"] = published[-1] if published else None
    finding["drift"] = declared not in published
    return finding


STALENESS_CHECKS = {
    "stale_pin": check_stale_pin,
    "unpublished_version": check_unpublished_version,
}


def check_staleness(entry: dict) -> dict:
    kind = entry.get("kind")
    fn = STALENESS_CHECKS.get(kind)
    if not fn:
        return {"kind": kind, "label": entry.get("label", "?"), "drift": False,
                "error": f"unknown staleness kind: {kind!r}"}
    try:
        return fn(entry)
    except Exception as e:
        return {"kind": kind, "label": entry.get("label", "?"), "drift": False,
                "error": f"{type(e).__name__}: {e}"}


# ---------------------------------------------------------------------------
# Output renderers
# ---------------------------------------------------------------------------

def write_staleness_markdown(findings: list[dict]) -> list[str]:
    """Render staleness findings. Listed before path drift: a stale pin or an
    unpublished version is a concrete action, not a divergence to eyeball."""
    if not findings:
        return []
    stale = [f for f in findings if f.get("drift")]
    errored = [f for f in findings if f.get("error")]
    lines = ["## Staleness\n",
             f"- Checks: **{len(findings)}** — stale: **{len(stale)}**, errors: **{len(errored)}**\n"]
    for f in stale:
        if f["kind"] == "stale_pin":
            behind = f.get("behind")
            behind_txt = f"{behind} commits behind" if behind is not None else "distance unknown"
            lines.append(f"- **stale pin** `{f['label']}` — {f['path']} pins "
                         f"`{f.get('pinned','?')[:12]}`, {f['upstream']} is at "
                         f"`{f.get('upstream_head','?')[:12]}` ({behind_txt})")
        elif f["kind"] == "unpublished_version":
            lines.append(f"- **unpublished version** `{f['label']}` — {f['path']} declares "
                         f"`{f.get('declared')}`, not on {f['registry']} "
                         f"(latest published: `{f.get('latest_published')}`)")
    for f in errored:
        lines.append(f"- _check error_ `{f.get('label','?')}`: {f['error']}")
    lines.append("")
    return lines


def write_markdown(findings: list[dict], path: str, staleness: list[dict] | None = None) -> int:
    """Write markdown report. Return count of actionable findings."""
    staleness = staleness or []
    lines: list[str] = ["# Config Drift Report\n"]
    lines += write_staleness_markdown(staleness)
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
    return len(drift) + len([f for f in staleness if f.get("drift")])


def write_manifest(findings: list[dict], path: str, staleness: list[dict] | None = None) -> None:
    """Machine-readable: which repos have which semantic cluster for which path,
    plus staleness findings against external sources of truth."""
    Path(path).write_text(json.dumps({
        "version": 2,
        "findings": findings,
        "staleness": staleness or [],
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

    # Validate policy shape — a malformed YAML can silently parse to a non-dict
    # (e.g. a top-level list) and crash later with an opaque AttributeError.
    if not isinstance(policy, dict):
        print(f"policy YAML must be a mapping at the top level; got {type(policy).__name__}", file=sys.stderr)
        sys.exit(2)
    repos = policy.get("repos") or []
    watch = policy.get("watch") or []
    if not isinstance(repos, list) or not isinstance(watch, list):
        print("policy 'repos' and 'watch' must both be lists", file=sys.stderr)
        sys.exit(2)
    if not repos or not watch:
        print("policy must define non-empty 'repos' and 'watch' lists", file=sys.stderr)
        sys.exit(2)

    # Normalise watch entries early so check_path() never sees a bad shape.
    normalised: list[dict] = []
    for i, entry in enumerate(watch):
        if isinstance(entry, str):
            normalised.append({"path": entry})
        elif isinstance(entry, dict) and isinstance(entry.get("path"), str):
            normalised.append(entry)
        else:
            print(f"policy watch entry #{i} is neither a string nor a mapping with a 'path' key: {entry!r}", file=sys.stderr)
            sys.exit(2)

    findings: list[dict] = []
    for entry in normalised:
        if not args.quiet:
            print(f"checking {entry['path']} across {len(repos)} repos...", file=sys.stderr)
        findings.append(check_path(repos, entry))

    # `staleness:` is optional — an older policy file stays valid.
    staleness_entries = policy.get("staleness") or []
    if not isinstance(staleness_entries, list):
        print("policy 'staleness' must be a list", file=sys.stderr)
        sys.exit(2)
    staleness: list[dict] = []
    for entry in staleness_entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("kind"), str):
            print(f"staleness entry must be a mapping with a 'kind' key: {entry!r}", file=sys.stderr)
            sys.exit(2)
        if not args.quiet:
            print(f"checking staleness {entry.get('label') or entry['kind']}...", file=sys.stderr)
        staleness.append(check_staleness(entry))

    drift_count = write_markdown(findings, args.output, staleness)
    write_manifest(findings, args.manifest, staleness)

    if not args.quiet:
        print(f"\n{len(findings)} paths checked across {len(repos)} repos", file=sys.stderr)
        print(f"{len(staleness)} staleness checks run", file=sys.stderr)
        print(f"{drift_count} actionable findings", file=sys.stderr)
        print(f"report → {args.output}", file=sys.stderr)
        print(f"manifest → {args.manifest}", file=sys.stderr)

    sys.exit(1 if drift_count > 0 else 0)


if __name__ == "__main__":
    main()
