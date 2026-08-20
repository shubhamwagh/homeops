#!/usr/bin/env python3
"""Decrypt and print HUMAN-ACCESS credentials declared in secrets-manifest.yaml.

Never touches MACHINE-ONLY secrets - those stay encrypted, no routine reason
a human needs to read them. See CLAUDE.md "Secret Handling".

Usage:
  scripts/print-secrets.py            # every human-access secret in the repo
  scripts/print-secrets.py <app>      # only entries whose file path contains /<app>/
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


def main():
    app_filter = sys.argv[1] if len(sys.argv) > 1 else None
    manifest = yq_json(["secrets-manifest.yaml"])
    entries = manifest.get("human_access", [])

    printed = 0
    for entry in entries:
        path = entry["file"]
        if app_filter and f"/{app_filter}/" not in path:
            continue
        printed += 1

        decrypted = subprocess.run(
            ["sops", "-d", path], capture_output=True, text=True, check=True
        ).stdout
        doc = yq_json(["."], input_text=decrypted)
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


if __name__ == "__main__":
    main()
