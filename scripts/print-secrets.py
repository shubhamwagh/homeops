#!/usr/bin/env python3
"""Decrypt and print credentials declared in secrets-manifest.yaml.

Two independent outputs, kept in separate files on purpose (see CLAUDE.md
"Secret Handling"):
  - human-access: a curated single label/value line per credential, meant
    for someone to actually log in with.
  - machine-only: a raw dump of every key in each machine-only secret, kept
    purely for backwards-compatible local reference/backup - not meant to be
    typed into a login prompt day to day.

Usage:
  scripts/print-secrets.py                 # every human-access secret
  scripts/print-secrets.py <app>           # human-access entries for one app
  scripts/print-secrets.py --machine-only  # raw dump of every machine-only secret
"""
import base64
import json
import subprocess
import sys


def yq_json(args, input_text=None):
    result = subprocess.run(
        ["yq", "-o=json", *args],
        input=input_text,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def get_field(doc, dotted):
    node = doc
    for part in dotted.split("."):
        node = node[part]
    return node


def decrypt(path):
    return subprocess.run(
        ["sops", "-d", path], capture_output=True, text=True, check=True
    ).stdout


def print_human_access(app_filter):
    manifest = yq_json(["secrets-manifest.yaml"])
    entries = manifest.get("human_access", [])

    printed = 0
    for entry in entries:
        path = entry["file"]
        if app_filter and f"/{app_filter}/" not in path:
            continue
        printed += 1

        doc = yq_json(["."], input_text=decrypt(path))
        value = get_field(doc, entry["field"])
        if entry.get("encoding") == "base64":
            value = base64.b64decode(value).decode()

        print(f"## {path}")
        if entry.get("recoverable"):
            print(f"{entry['label']}: {value}")
        else:
            print(f"{entry['label']}: [HASH ONLY - not the plaintext] {value}")
            print(
                "  original password not recoverable from git - check "
                "Vaultwarden/.secrets-plaintext backup, or rotate the credential"
            )
        print()

    if app_filter and printed == 0:
        print(f"No human-access secrets found for '{app_filter}' (see secrets-manifest.yaml)")


def print_machine_only():
    manifest = yq_json(["secrets-manifest.yaml"])
    for path in manifest.get("machine_only", []):
        doc = yq_json(["."], input_text=decrypt(path))
        print(f"## {path}")
        for section in ("stringData", "data"):
            for key, value in (doc.get(section) or {}).items():
                if section == "data":
                    value = base64.b64decode(value).decode(errors="replace")
                print(f"{key}: {value}")
        print()


def main():
    if "--machine-only" in sys.argv:
        print_machine_only()
        return
    app_filter = sys.argv[1] if len(sys.argv) > 1 else None
    print_human_access(app_filter)


if __name__ == "__main__":
    main()
