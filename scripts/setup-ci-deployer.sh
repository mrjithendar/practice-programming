#!/usr/bin/env bash
# One-time: stores what the deploy job's rollout steps (.github/workflows/ci.yml, scripts/lib/ci-kubeconfig.sh) fill
# into the kubeconfig template .github/jithendar-ci-deployer.yaml:
#   MK4_API_SERVER  repository variable  cluster API URL         (from the kube context)
#   MK4_CA_DATA     repository variable  base64 CA certificate   (from the kube context)
#   MK4_CI_TOKEN    repository secret    ServiceAccount token    (from Secret jithendar/github-ci-deployer-token)
#
# The ServiceAccount jithendar/github-ci-deployer belongs to jithendar.com (kubernetes/80-ci-deployer.yaml, applied by
# its scripts/setup-ci-deployer.sh) and is shared with this repository: its Role already lets it restart
# practice-executor-api, practice-dispatcher and jithendar-com. This script applies nothing and never rotates the
# token, because that would break jithendar.com's CI. To rotate: run `ROTATE=1 scripts/setup-ci-deployer.sh` in
# jithendar.com, then run this script again.
#
#   KUBE_CONTEXT=mk4 scripts/setup-ci-deployer.sh            # read the token, test the kubeconfig, store the values
#   KUBE_CONTEXT=mk4 SKIP_GH=1 scripts/setup-ci-deployer.sh  # only test; set the values in GitHub yourself
#   (kube context: KUBE_CONTEXT=<name>, else the current context with a confirmation prompt; scripts/lib/kube-context.sh)
#
# The token goes straight into `gh secret set` (stdin) and is never printed. The script renders the template to a
# temporary file to check what the kubeconfig may do, then deletes it.
# Needs: kubectl allowed to read Secrets in namespace jithendar; gh CLI signed in with admin on the repository (unless
# SKIP_GH=1). The cluster API must be reachable from GitHub-hosted runners.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib/kube-context.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/kube-context.sh"

REPO="${GITHUB_REPO:-moks-tech/practice-programming}"
NS="jithendar"
SA="github-ci-deployer"
TEMPLATE=".github/jithendar-ci-deployer.yaml"

cd "$(dirname -- "${BASH_SOURCE[0]}")/.."

MK4_API_SERVER="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
MK4_CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[[ -n "$MK4_CA_DATA" ]] || MK4_CA_DATA="$(base64 < "$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')" | tr -d '\n')"
[[ -n "$MK4_API_SERVER" && -n "$MK4_CA_DATA" ]] || { echo "Could not read server/CA of kube context $KCTX." >&2; exit 1; }

echo "→ Cluster $MK4_API_SERVER, ServiceAccount $NS/$SA, repository $REPO"
echo "→ Reading the token from Secret $NS/$SA-token"
MK4_CI_TOKEN="$(kubectl -n "$NS" get secret "$SA-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
[[ -n "$MK4_CI_TOKEN" ]] || {
  echo "No token in Secret $NS/$SA-token. The ServiceAccount is set up from jithendar.com: run its" >&2
  echo "scripts/setup-ci-deployer.sh first, then this script again." >&2
  exit 1
}
export MK4_API_SERVER MK4_CA_DATA MK4_CI_TOKEN

# Render the template exactly as scripts/lib/ci-kubeconfig.sh does; check it can do what the deploy job needs.
echo "→ Testing $TEMPLATE with these values"
KCFG="$(mktemp)"
trap 'rm -f "$KCFG"' EXIT
(umask 077; perl -pe 's/\$\{(MK4_[A-Z_]+)\}/$ENV{$1}/g' "$TEMPLATE" > "$KCFG")
can() { command kubectl --kubeconfig "$KCFG" auth can-i "$@" -n "$NS"; }
# scripts/ci-rollout.py: list Deployments, set image / restart the executor (and jithendar-com for a new catalog),
# watch the rollout, list pods when it fails.
for allowed in "list deployments.apps" "watch deployments.apps" "list replicasets.apps" "list pods" \
  "patch deployments.apps/practice-executor-api" "patch deployments.apps/practice-dispatcher" \
  "patch deployments.apps/jithendar-com"; do
  # shellcheck disable=SC2086
  [[ "$(can $allowed 2>/dev/null || true)" == yes ]] || {
    echo "The rendered kubeconfig may not '$allowed'; the deploy job needs it. Check jithendar.com's" >&2
    echo "kubernetes/80-ci-deployer.yaml (and run its scripts/setup-ci-deployer.sh to apply it)." >&2
    exit 1
  }
done

if [[ "${SKIP_GH:-0}" == "1" ]]; then
  cat <<EOF
Done. Set these in $REPO → Settings → Secrets and variables → Actions:
  Variable MK4_API_SERVER = $MK4_API_SERVER
  Variable MK4_CA_DATA    = output of: kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'
  Secret   MK4_CI_TOKEN   = copy with: kubectl -n $NS get secret $SA-token -o jsonpath='{.data.token}' | base64 -d | pbcopy
EOF
  exit 0
fi

echo "→ Storing variables MK4_API_SERVER, MK4_CA_DATA and secret MK4_CI_TOKEN"
gh variable set MK4_API_SERVER --repo "$REPO" --body "$MK4_API_SERVER"
gh variable set MK4_CA_DATA --repo "$REPO" --body "$MK4_CA_DATA"
printf '%s' "$MK4_CI_TOKEN" | gh secret set MK4_CI_TOKEN --repo "$REPO"
unset MK4_CI_TOKEN

echo "Done: $REPO can now roll out the executor and restart the sites. Next: scripts/setup-ci-applier.sh"
