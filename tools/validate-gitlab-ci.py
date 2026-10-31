#!/usr/bin/env python3
"""Validate .gitlab-ci.yml: YAML parse, asset-link JSON (as the shell
passes it), and bash -n on every script block. Usage: python3 validate-gitlab-ci.py"""
import json
import os
import re
import subprocess
import sys
import tempfile

import yaml

path = os.path.join(os.path.dirname(__file__), "..", ".gitlab-ci.yml")
d = yaml.safe_load(open(path, encoding="utf-8"))
print("YAML OK; jobs:", [j for j in d if j not in ("stages", "workflow", "variables")])

rel = d["release:gitlab"]["script"][1]
# a shell double-quoted string: "..." with \" escapes
raw_links = re.findall(r"--assets-link\s+(\"(?:[^\"\\]|\\.)*\")", rel)
# The published asset set is the .deb + its sha256 (2 links, both built
# from ${DEB}). The count is asserted against the assets the Release is
# meant to carry, not a stale literal: 7be3580 shipped this check
# expecting 5 links while the file it validates has carried 2 since —
# the check never passed and nothing runs it in CI. Fixed to the real
# contract (deb + sha256) as part of deb-purge-lifecycle ticket 04.
assert len(raw_links) == 2, f"expected 2 asset links (deb + sha256), got {len(raw_links)}"
for arg in raw_links:
    inner = arg[1:-1].replace('\\"', '"')  # shell double-quote evaluation
    meta = json.loads(inner)
    assert meta.get("name") and meta.get("url"), meta
    print("link OK:", meta["name"])

ok = 0
for job, cfg in d.items():
    if job in ("stages", "workflow", "variables"):
        continue
    for s in cfg.get("script", []):
        # relative filename + cwd: dodges every Windows/MSYS path variant
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, ".ci-check.tmp.sh"), "w", encoding="utf-8", newline="\n") as f:
            f.write(s)
        res = subprocess.run(["bash", "-n", ".ci-check.tmp.sh"],
                             capture_output=True, text=True, cwd=here)
        os.unlink(os.path.join(here, ".ci-check.tmp.sh"))
        if res.returncode != 0:
            print(f"{job}: BASH SYNTAX ERROR\n{res.stderr[:500]}")
            sys.exit(1)
        ok += 1
print(f"all {ok} script blocks pass bash -n")
