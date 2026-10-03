#!/usr/bin/env python3
"""Deterministic CASTABOT branding overlay for the hermes-agent tree.

The branded branch is GENERATED, never merged. This script stamps the brand
tokens from brand-map.json onto a clean checkout of upstream `main`, so an
upstream sync can never produce a merge conflict: the branded branch is thrown
away and rebuilt from scratch every time.

Modes
-----
  --apply          (default) rewrite files in place
  --check          verify the tree is already fully branded; exit 1 if any rule
                   would still change something (the idempotency gate)
  --report         print residual brand tokens with before/after lines, no writes
  --list-changed   print the paths this run would change, one per line
  --changed-py     print the .py paths this run would change (for compileall)

Globs use `**` (spans separators), `*` and `?` (do not) semantics.

Candidates are prefiltered with `git grep` instead of opening all 17k tracked
files: on a Defender-scanned Windows box a per-file open costs ~23ms, which is
7 minutes per pass versus ~1 minute prefiltered. If git grep is unavailable the
tool falls back to a full walk, slower but identical in result.

Standard library only. The branding pipeline must never depend on the target
project's virtualenv.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path, PurePosixPath

REPO_ROOT = Path(__file__).resolve().parent.parent
MAP_PATH = Path(__file__).resolve().parent / "brand-map.json"

BINARY_SNIFF_BYTES = 8192
DEFAULT_MAX_BYTES = 4 * 1024 * 1024


@lru_cache(maxsize=None)
def glob_to_regex(pattern: str) -> re.Pattern[str]:
    """Translate a glob into a regex. Compiled once and cached."""
    out: list[str] = []
    idx = 0
    while idx < len(pattern):
        if pattern[idx : idx + 3] == "**/":
            out.append("(?:[^/]+/)*")
            idx += 3
        elif pattern[idx : idx + 2] == "**":
            out.append(".*")
            idx += 2
        elif pattern[idx] == "*":
            out.append("[^/]*")
            idx += 1
        elif pattern[idx] == "?":
            out.append("[^/]")
            idx += 1
        else:
            out.append(re.escape(pattern[idx]))
            idx += 1
    return re.compile("^" + "".join(out) + "$")


@lru_cache(maxsize=None)
def any_of(patterns: tuple[str, ...]) -> re.Pattern[str]:
    return re.compile("|".join(f"(?:{glob_to_regex(p).pattern})" for p in patterns))


@dataclass
class Rule:
    """One literal or regex substitution."""

    replace: str
    find: str | None = None
    pattern: str | None = None
    probe: str | None = None
    comment: str = ""
    compiled: re.Pattern[str] | None = field(default=None, init=False)

    def __post_init__(self) -> None:
        if (self.find is None) == (self.pattern is None):
            raise ValueError("a rule needs exactly one of find/pattern")
        if self.pattern is not None:
            self.compiled = re.compile(self.pattern)

    def apply(self, text: str) -> str:
        if self.find is not None:
            return text.replace(self.find, self.replace)
        assert self.compiled is not None
        return self.compiled.sub(self.replace, text)

    @property
    def literal_probe(self) -> str | None:
        """A fixed string that must be present for this rule to be able to fire.

        Used to prefilter candidate files. For a regex rule the caller supplies a
        conservative literal superset via `probe`.
        """
        if self.probe is not None:
            return self.probe
        return self.find


@dataclass
class RuleSet:
    """A group of rules applied to the files matched by `include`."""

    name: str
    rules: list[Rule]
    include: tuple[str, ...] = ("**",)
    exclude: tuple[str, ...] = ()
    probes: tuple[str, ...] = ()
    include_re: re.Pattern[str] = field(init=False)
    exclude_re: re.Pattern[str] | None = field(default=None, init=False)

    def __post_init__(self) -> None:
        self.include_re = any_of(self.include)
        self.exclude_re = any_of(self.exclude) if self.exclude else None

    def applies_to(self, posix: str) -> bool:
        if not self.include_re.match(posix):
            return False
        return not (self.exclude_re is not None and self.exclude_re.match(posix))


def template_drift(root: Path, templates: list[dict]) -> list[str]:
    """Which template-managed files are not in their branded state.

    `copy` targets must equal the template verbatim. `append` targets must end
    with the template body and must still start with the upstream text, so the
    MIT grant is never edited -- only extended.
    """
    drifted: list[str] = []
    for spec in templates:
        source = root / spec["from"]
        target = root / spec["to"]
        if not source.is_file():
            drifted.append(f"{spec['to']} (template {spec['from']} is missing)")
            continue
        body = source.read_text(encoding="utf-8")
        if spec.get("mode") == "append":
            current = target.read_text(encoding="utf-8") if target.is_file() else ""
            if not current.endswith(body):
                drifted.append(spec["to"])
        else:
            if not target.is_file() or target.read_text(encoding="utf-8") != body:
                drifted.append(spec["to"])
    return drifted


def install_templates(root: Path, templates: list[dict]) -> int:
    written = 0
    for spec in templates:
        source = root / spec["from"]
        target = root / spec["to"]
        body = source.read_text(encoding="utf-8")
        if spec.get("mode") == "append":
            current = target.read_text(encoding="utf-8") if target.is_file() else ""
            if not current.endswith(body):
                target.write_text(current + body, encoding="utf-8", newline="")
                written += 1
        else:
            if not target.is_file() or target.read_text(encoding="utf-8") != body:
                with target.open("w", encoding="utf-8", newline="") as fh:
                    fh.write(body)
                written += 1
    return written


def load_map() -> dict:
    with MAP_PATH.open(encoding="utf-8") as fh:
        return json.load(fh)


def build_rulesets(data: dict) -> list[RuleSet]:
    """Rule sets from the map. `probes` default to each rule's own literal, or
    the explicit `probe` on the rule for regex rules (a conservative superset)."""
    sets: list[RuleSet] = []
    for spec in data["rule_sets"]:
        rules = []
        probes: list[str] = []
        for raw in spec["rules"]:
            rule = Rule(**raw)
            rules.append(rule)
            if rule.literal_probe:
                probes.append(rule.literal_probe)
        sets.append(
            RuleSet(
                name=spec["name"],
                rules=rules,
                include=tuple(spec.get("include", ["**"])),
                exclude=tuple(spec.get("exclude", [])),
                probes=tuple(dict.fromkeys(probes)),
            )
        )
    return sets


def git_grep_candidates(root: Path, tokens: list[str], pathspecs: list[str]) -> set[str] | None:
    """Files containing any of `tokens`, or None when git grep is unusable."""
    if not tokens:
        return set()
    cmd = ["git", "-C", str(root), "grep", "-l", "-F", "-I"]
    for token in tokens:
        cmd += ["-e", token]
    cmd.append("--")
    cmd += pathspecs or ["."]
    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode not in (0, 1):
        return None
    return {line.strip() for line in proc.stdout.decode("utf-8", "replace").splitlines() if line.strip()}


def candidates_by_ruleset(root: Path, rulesets: list[RuleSet]) -> dict[str, list[RuleSet]] | None:
    """path -> the rule sets worth opening it for. None means "walk everything"."""
    plan_map: dict[str, list[RuleSet]] = {}
    for ruleset in rulesets:
        if not ruleset.probes:
            continue
        pathspecs = [spec for spec in ruleset.include if not spec.startswith("**/") or "*" in spec[3:]]
        pathspecs = pathspecs or ["."]
        found = git_grep_candidates(root, list(ruleset.probes), pathspecs)
        if found is None:
            return None
        for path in found:
            plan_map.setdefault(path, []).append(ruleset)
    return plan_map


def mask_protected(text: str, protect: list[str | dict]) -> tuple[str, dict[str, str]]:
    """Hide literals that must survive the rewrite behind NUL-delimited sentinels.

    A protect entry is either a literal string, or `{"pattern": "<regex>"}` for
    shapes whose exact text varies (copyright lines, for instance). Masking
    happens before any rule runs and is undone afterwards, so a protected
    literal is invisible to every rule set.
    """
    used: dict[str, str] = {}
    counter = 0
    for entry in protect:
        if isinstance(entry, str):
            literals = [entry] if entry in text else []
        else:
            literals = sorted({m.group(0) for m in re.finditer(entry["pattern"], text)})
        for literal in literals:
            sentinel = f"\x00CASTABOT_PROTECT_{counter}\x00"
            counter += 1
            used[sentinel] = literal
            text = text.replace(literal, sentinel)
    return text, used


def unmask_protected(text: str, sentinels: dict[str, str]) -> str:
    for sentinel, literal in sentinels.items():
        text = text.replace(sentinel, literal)
    return text


def apply_rulesets(text: str, rulesets: list[RuleSet], posix: str, protect: list) -> str:
    text, sentinels = mask_protected(text, protect)
    for ruleset in rulesets:
        if not ruleset.applies_to(posix):
            continue
        for rule in ruleset.rules:
            text = rule.apply(text)
    return unmask_protected(text, sentinels)


def read_text(path: Path, max_bytes: int) -> str | None:
    """Decoded text, or None for binary / oversized / non-UTF-8 files."""
    try:
        if path.stat().st_size > max_bytes:
            return None
        raw = path.read_bytes()
    except OSError:
        return None
    if b"\x00" in raw[:BINARY_SNIFF_BYTES]:
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def plan(
    root: Path,
    rulesets: list[RuleSet],
    protect: list,
    max_bytes: int,
) -> tuple[list[tuple[str, str, str]], int]:
    """Return ([(posix, before, after)], files_opened)."""
    tracked = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True
    ).stdout
    tracked_set = {
        p.decode("utf-8", "surrogateescape") for p in tracked.split(b"\0") if p
    }

    prefiltered = candidates_by_ruleset(root, rulesets)
    changes: list[tuple[str, str, str]] = []
    opened = 0

    if prefiltered is None:
        # Fallback: no prefilter, evaluate every tracked file against every set.
        work = [(path, rulesets) for path in sorted(tracked_set)]
    else:
        work = [
            (path, [rs for rs in sets if rs.applies_to(path)])
            for path, sets in sorted(prefiltered.items())
            if path in tracked_set
        ]

    for posix, applicable in work:
        applicable = [rs for rs in applicable if rs.applies_to(posix)]
        if not applicable:
            continue
        abs_path = root / posix
        if not abs_path.is_file():
            continue
        text = read_text(abs_path, max_bytes)
        if text is None:
            continue
        opened += 1
        after = apply_rulesets(text, applicable, posix, protect)
        if after != text:
            changes.append((posix, text, after))
    return changes, opened


def apply_changes(root: Path, changes: list[tuple[str, str, str]]) -> None:
    for posix, _before, after in changes:
        with (root / posix).open("w", encoding="utf-8", newline="") as fh:
            fh.write(after)


def report(changes: list[tuple[str, str, str]], limit: int) -> None:
    print(f"{len(changes)} file(s) still carry brand tokens:\n")
    if limit <= 0:
        return
    for posix, before, after in changes[:limit]:
        print(f"  {posix}")
        for idx, (old, new) in enumerate(zip(before.splitlines(), after.splitlines()), start=1):
            if old == new:
                continue
            print(f"    {idx:>5} | {old.strip()[:140]}")
            print(f"    {'':>5}-> {new.strip()[:140]}")
        print()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="rewrite files in place")
    mode.add_argument("--check", action="store_true", help="fail if anything is unbranded")
    mode.add_argument("--report", action="store_true", help="list residual brand tokens")
    mode.add_argument("--list-changed", action="store_true")
    mode.add_argument("--changed-py", action="store_true")
    parser.add_argument("--limit", type=int, default=40, help="report detail limit (0 = counts only)")
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    args = parser.parse_args()

    data = load_map()
    rulesets = build_rulesets(data)
    protect = data.get("protect", [])
    templates = data.get("templates", [])
    changes, opened = plan(REPO_ROOT, rulesets, protect, args.max_bytes)
    drifted = template_drift(REPO_ROOT, templates)

    if args.check:
        if changes or drifted:
            print(
                f"FAIL: {len(changes)} file(s) not branded, {len(drifted)} template(s) drifted",
                file=sys.stderr,
            )
            if drifted:
                print(f"  templates: {', '.join(drifted)}", file=sys.stderr)
            report(changes, args.limit)
            return 1
        print(f"OK: no brand tokens remain in the allowlisted surface ({opened} files scanned)")
        print("OK: README.md, NOTICE and LICENSE are in their branded state")
        return 0

    if args.report:
        print(f"scanned {opened} candidate files")
        if drifted:
            print(f"templates needing install: {', '.join(drifted)}")
        report(changes, args.limit)
        return 0

    if args.list_changed:
        for posix in drifted + [posix for posix, _b, _a in changes]:
            print(posix)
        return 0

    if args.changed_py:
        for posix, _b, _a in changes:
            if PurePosixPath(posix).suffix == ".py":
                print(posix)
        return 0

    apply_changes(REPO_ROOT, changes)
    written = install_templates(REPO_ROOT, templates)
    print(f"branded {len(changes)} file(s), installed {written} template(s) ({opened} scanned)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())