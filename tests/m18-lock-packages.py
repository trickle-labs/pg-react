#!/usr/bin/env python3
import json
import tomllib
from pathlib import Path

lock = tomllib.loads(Path("Cargo.lock").read_text())
print(json.dumps(sorted(
    ({"name": package["name"], "version": package["version"]}
     for package in lock["package"]),
    key=lambda package: (package["name"], package["version"]))))
