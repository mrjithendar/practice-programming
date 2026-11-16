#!/usr/bin/env bash
# Print the executor's manifests (kubernetes/*.yaml, in name order, which is the order they must be applied in) as
# one multi-document YAML stream, for kubectl apply/diff -f -. Prints only; never talks to a cluster.
#
#   scripts/manifests.sh | kubectl apply -f -                                   (a person, the first time)
#   scripts/manifests.sh | python3 scripts/ci-app-manifests.py > apply.yaml     (what CI applies: application objects)
set -euo pipefail
dir="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/kubernetes"
shopt -s nullglob
files=("$dir"/*.yaml)
[[ ${#files[@]} -gt 0 ]] || { echo "No kubernetes/*.yaml files" >&2; exit 1; }
for f in "${files[@]}"; do
  printf -- '---\n# Source: kubernetes/%s\n' "$(basename "$f")"
  cat "$f"
  printf '\n'
done
