#!/usr/bin/env bash
# 与基线对比 paths/operations/schemas 计数，并列出 tag 名差异。
# 用法: verify.sh <生成的openapi.json> [基线，默认 baseline.json]
set -euo pipefail

gen="${1:?用法: verify.sh <openapi.json> [baseline]}"
base="${2:-baseline.json}"

python3 - "$gen" "$base" <<'EOF'
import json, sys

def metrics(p):
    d = json.load(open(p))
    ops = sum(len([k for k in v if k.lower() != "parameters"]) for v in d["paths"].values())
    return d, {
        "openapi": d.get("openapi"),
        "paths": len(d["paths"]),
        "operations": ops,
        "schemas": len(d.get("components", {}).get("schemas", {})),
    }, set(t["name"] for t in d.get("tags", []))

g, gm, gt = metrics(sys.argv[1])
b, bm, bt = metrics(sys.argv[2])

print("metric        baseline      generated")
for k in ("openapi", "paths", "operations", "schemas"):
    print(f"{k:<14}{str(bm[k]):<14}{str(gm[k]):<14}" + ("" if bm[k] == gm[k] else "  <- 差异"))

only_b, only_g = sorted(bt - gt), sorted(gt - bt)
if only_b: print("基线独有 tags:", only_b)
if only_g: print("生成独有 tags:", only_g)
if bm == gm and not only_b and not only_g:
    print("OK: 与基线一致")
EOF
