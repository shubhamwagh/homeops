#!/usr/bin/env python3
"""Append resource filenames to a kustomization.yaml's `resources:` list.

Text-based insertion (appends after the last existing resources: item),
not a YAML parse/dump round-trip - keeps this safe to use even if a
kustomization.yaml ever grows comments.

Usage: add-kustomize-resources.py <kustomization.yaml path> <filename> [filename ...]
"""
import sys


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    path, *filenames = sys.argv[1:]

    with open(path) as f:
        lines = f.readlines()

    already = {f"  - {name}\n" for name in filenames}
    if already.issubset(set(lines)):
        print("Already present, skipping:", path)
        return

    # Find the last line that looks like a resources list item ("  - foo.yaml"),
    # insert new entries right after it.
    insert_at = None
    for i, line in enumerate(lines):
        if line.startswith("  - "):
            insert_at = i
    if insert_at is None:
        print(f"No resources: list items found in {path}", file=sys.stderr)
        sys.exit(1)

    new_lines = [f"  - {name}\n" for name in filenames if f"  - {name}\n" not in lines]
    lines = lines[: insert_at + 1] + new_lines + lines[insert_at + 1 :]

    with open(path, "w") as f:
        f.writelines(lines)
    print("Added to", path, ":", filenames)


if __name__ == "__main__":
    main()
