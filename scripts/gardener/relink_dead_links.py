#!/usr/bin/env python3
"""Exact-rename dead-wikilink repair for an Obsidian-style vault.

A dead wikilink whose target basename uniquely matches exactly ONE existing
note gets its path rewritten to that note's path. Ambiguous (zero or more
than one basename match) links are left untouched. Bounded by --cap repairs
per run so a single pass can't rewrite the whole vault at once.

Usage: relink_dead_links.py <vault-root> [--cap 50] [--dry-run]
"""
import argparse
import re
import sys
from pathlib import Path

SKIP = {".git", ".obsidian", ".trash", ".growth"}

WIKILINK_RE = re.compile(r"\[\[([^\]|#]+)(#[^\]|]*)?(\|[^\]]*)?\]\]")


def iter_notes(vault_root: Path):
    for path in vault_root.rglob("*.md"):
        rel = path.relative_to(vault_root)
        if any(part in SKIP for part in rel.parts):
            continue
        yield rel


def build_index(vault_root: Path):
    """basename (no extension) -> list of relative-path-without-extension matches."""
    index = {}
    exact = set()
    for rel in iter_notes(vault_root):
        stem_path = rel.with_suffix("").as_posix()
        exact.add(stem_path)
        basename = rel.stem
        index.setdefault(basename, []).append(stem_path)
    return index, exact


def resolve(target: str, index, exact) -> str | None:
    """Return the canonical stem-path this target already resolves to, or None if dead."""
    target = target.strip()
    if target in exact:
        return target
    basename = target.split("/")[-1]
    candidates = index.get(basename, [])
    if len(candidates) == 1 and candidates[0] == target:
        return candidates[0]
    return None


def repair_candidate(target: str, index) -> str | None:
    """Return the unique replacement path for a dead target, or None if ambiguous/unmatched."""
    basename = target.strip().split("/")[-1]
    candidates = index.get(basename, [])
    if len(candidates) == 1:
        return candidates[0]
    return None


def process_file(path: Path, index, exact, cap_remaining: int) -> tuple[str, int]:
    text = path.read_text(encoding="utf-8")
    repairs_here = 0

    def sub(match: re.Match) -> str:
        nonlocal repairs_here, cap_remaining
        target, heading, alias = match.group(1), match.group(2) or "", match.group(3) or ""
        if cap_remaining <= 0:
            return match.group(0)
        if resolve(target, index, exact) is not None:
            return match.group(0)
        replacement = repair_candidate(target, index)
        if replacement is None or replacement == target.strip():
            return match.group(0)
        repairs_here += 1
        cap_remaining -= 1
        return f"[[{replacement}{heading}{alias}]]"

    new_text = WIKILINK_RE.sub(sub, text)
    return new_text, repairs_here


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vault_root")
    parser.add_argument("--cap", type=int, default=50)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    vault_root = Path(args.vault_root).resolve()
    index, exact = build_index(vault_root)

    total_repairs = 0
    cap_remaining = args.cap
    for rel in sorted(iter_notes(vault_root)):
        if cap_remaining <= 0:
            break
        path = vault_root / rel
        new_text, repairs_here = process_file(path, index, exact, cap_remaining)
        if repairs_here:
            total_repairs += repairs_here
            cap_remaining -= repairs_here
            if not args.dry_run:
                path.write_text(new_text, encoding="utf-8")
            print(f"repaired {repairs_here} link(s) in {rel}")

    print(f"gardener relink: {total_repairs} repair(s) (cap {args.cap})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
