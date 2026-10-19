#!/usr/bin/env python3
"""Render a versioned cask into an existing tap checkout."""
import pathlib
import re
import sys

version, checksum, tap = sys.argv[1:]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("Invalid version")
if not re.fullmatch(r"[0-9a-f]{64}", checksum):
    raise SystemExit("Invalid SHA-256")
root = pathlib.Path(__file__).resolve().parent.parent
source = (root / "packaging/homebrew/bilinext.rb.in").read_text()
target = pathlib.Path(tap) / "Casks/bilinext.rb"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(source.replace("@VERSION@", version).replace("@SHA256@", checksum))
