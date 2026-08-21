#!/usr/bin/env python3
"""Append a human_access entry to secrets-manifest.yaml.

Text-based insertion, not a YAML parse/dump round-trip - the manifest is full
of hand-written comments explaining the classification scheme, and a round-
trip through a YAML library would silently strip all of them.

Usage: register-human-secret.py <file> <label> <field> <recoverable: true|false>
"""
import sys

MANIFEST = "secrets-manifest.yaml"
MARKER = "\n# MACHINE-ONLY:"


def main():
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    file, label, field, recoverable = sys.argv[1:5]

    with open(MANIFEST) as f:
        content = f.read()

    if f"file: {file}\n" in content:
        print(f"Already registered, skipping: {file}")
        return

    entry = f"  - file: {file}\n    label: {label}\n    field: {field}\n    recoverable: {recoverable}\n\n"
    idx = content.index(MARKER)
    content = content[:idx] + "\n" + entry + content[idx + 1:]

    with open(MANIFEST, "w") as f:
        f.write(content)
    print(f"Registered: {file}")


if __name__ == "__main__":
    main()
