#!/usr/bin/env python3
"""
v1-docs-audit.py - Documentation link, anchor, and stale-reference auditor.
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
docs_dir = root / "docs"

canonical_docs = [
    root / "README.md",
    docs_dir / "index.md",
    docs_dir / "getting-started.md",
    docs_dir / "concepts.md",
    docs_dir / "v1-authoring.md",
    docs_dir / "changing-policies.md",
    docs_dir / "v1-installation.md",
    docs_dir / "v1-operations.md",
    docs_dir / "v1-security.md",
    docs_dir / "v1-backup-restore.md",
    docs_dir / "v1-upgrade.md",
    docs_dir / "v1-troubleshooting.md",
    docs_dir / "v1-limits.md",
    docs_dir / "v1-support-matrix.md",
    docs_dir / "v1-api-reference.md",
    docs_dir / "v1-known-limitations.md",
    docs_dir / "1.0-release-notes.md",
    docs_dir / "v1-contract.md",
    docs_dir / "v1-compatibility.md",
    docs_dir / "v1-deprecations.md",
]

all_markdown_files = [root / "README.md", root / "ROADMAP.md", *sorted(docs_dir.rglob("*.md"))]

errors = []


def normalize_heading(h: str) -> str:
    # GitHub anchor normalization
    h = re.sub(r"[^\w\s-]", "", h.lower()).strip()
    return re.sub(r"[-\s]+", "-", h)


# 1. Link & anchor validation across all markdown files
for source in all_markdown_files:
    text = source.read_text()
    for target in re.findall(r"(?<!!)\[[^]]+\]\(([^)]+)\)", text):
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        path_text, _, fragment = target.partition("#")
        if not path_text and fragment:
            target_path = source
        else:
            target_path = (source.parent / path_text).resolve()
        if not target_path.exists():
            errors.append(f"Broken link in {source.relative_to(root)}: '{target}' -> {target_path} not found")
            continue
        if fragment and target_path.suffix == ".md":
            headings = {
                normalize_heading(heading)
                for heading in re.findall(r"^#{1,6}\s+(.+)$", target_path.read_text(), re.MULTILINE)
            }
            norm_frag = normalize_heading(fragment)
            if norm_frag not in headings and fragment not in headings:
                errors.append(f"Broken anchor in {source.relative_to(root)}: '{target}' (anchor '#{fragment}' not found in {target_path.relative_to(root)})")

# 2. Canonical stale reference checks
for source in canonical_docs:
    if not source.exists():
        errors.append(f"Missing canonical doc: {source.relative_to(root)}")
        continue
    text = source.read_text()
    rel = source.relative_to(root)

    # Nonexistent work.created_at
    if re.search(r"\bwork\.created_at\b", text):
        errors.append(f"{rel}: References nonexistent work.created_at (must use work.updated_at)")

    # One global coordinator claim
    if re.search(r"\bone global coordinator\b", text, re.IGNORECASE):
        errors.append(f"{rel}: Claims 'one global coordinator' (must use per-database managed worker)")

    # Stale operations guide link as current
    if "docs/m3-operations.md" in text or "m3-operations.md" in text:
        errors.append(f"{rel}: Links to historical m3-operations.md as guidance")

    # Stale M34 api reference as canonical API reference
    if "docs/m34-api-reference.md" in text and rel.name != "history.md":
        errors.append(f"{rel}: Links to historical m34-api-reference.md as API reference")

    # Stale v1-upgrades.md as current upgrade guidance
    if "docs/v1-upgrades.md" in text and rel.name != "history.md":
        errors.append(f"{rel}: Links to historical v1-upgrades.md as current upgrade guide")

    # M35 as v1 requirement
    if re.search(r"\bM35\b[^\n.?!]*\b(?:required|needed)\b[^\n.?!]*\b(?:1\.0|v1|RC|GA)\b", text, re.IGNORECASE):
        errors.append(f"{rel}: M35 described as required before v1/RC/GA")

    # Check for direct links from canonical user guide to historical milestone pages as instructions
    # Allowed in history.md, v1-compatibility.md, v1-deprecations.md, v1-contract.md, 1.0-release-notes.md
    if source.name not in {"v1-compatibility.md", "v1-deprecations.md", "v1-contract.md", "index.md", "1.0-release-notes.md"}:
        for target in re.findall(r"(?<!!)\[[^]]+\]\(([^)]+)\)", text):
            if re.search(r"\bm\d+-[a-z0-9-]+\.md\b|\bv1-upgrades\.md\b|\bv1-release-notes\.md\b", target):
                errors.append(f"Canonical doc {rel} routes directly to historical milestone page: '{target}' (must route via docs/history.md or canonical docs)")

if errors:
    print("Documentation audit failed:", file=sys.stderr)
    for err in errors:
        print(f"  ERROR: {err}", file=sys.stderr)
    sys.exit(1)

print(f"Documentation audit passed ({len(all_markdown_files)} files checked, {len(canonical_docs)} canonical docs verified)")
