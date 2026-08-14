#!/usr/bin/env python3
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
docs = [root / "README.md", root / "ROADMAP.md", *sorted((root / "docs").glob("*.md"))]
errors = []
public_api = set()
for sql in (root / "sql").glob("*.sql"):
    public_api.update(re.findall(r"\bFUNCTION\s+pgreact_api\.([a-z][a-z0-9_]*)\s*\(", sql.read_text()))
for source in docs:
    text = source.read_text()
    for name in sorted(set(re.findall(r"\bpgreact_api\.([a-z][a-z0-9_]*)\b", text))):
        if name not in public_api:
            errors.append(f"{source.relative_to(root)}: unknown public API pgreact_api.{name}")
    for target in re.findall(r"(?<!!)\[[^]]+\]\(([^)]+)\)", text):
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        path_text, _, fragment = target.partition("#")
        path = (source.parent / path_text).resolve()
        if not path.is_file():
            errors.append(f"{source.relative_to(root)}: missing {target}")
            continue
        if fragment:
            headings = {
                re.sub(r"[^a-z0-9 -]", "", heading.lower()).strip().replace(" ", "-")
                for heading in re.findall(r"^#{1,6}\s+(.+)$", path.read_text(), re.MULTILINE)
            }
            if fragment not in headings:
                errors.append(f"{source.relative_to(root)}: missing anchor {target}")
if errors:
    raise SystemExit("\n".join(errors))
print(f"M18 documentation links and public API names passed ({len(docs)} files)")
