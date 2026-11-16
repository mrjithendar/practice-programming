#!/usr/bin/env bash
# One-time: stores what the deploy job's "Apply the application objects" step (.github/workflows/ci.yml) needs:
#   MK4_CI_APPLY_TOKEN               repository secret    ServiceAccount token (from Secret jithendar/github-ci-applier-token)
#   PRACTICE_EXECUTOR_DEPLOY = true  repository variable  turns the deploy job on
# MK4_API_SERVER and MK4_CA_DATA are shared with the rollout steps: run scripts/setup-ci-deployer.sh first.
#
# The ServiceAccount jithendar/github-ci-applier belongs to jithendar.com (kubernetes/85-ci-applier.yaml, applied by
# its scripts/setup-ci-applier.sh) and is shared with this repository. This script applies nothing and never rotates
# the token, because that would break jithendar.com's CI. To rotate: run `ROTATE=1 scripts/setup-ci-applier.sh` in
# jithendar.com, then run this script again. If the dry run below is refused, the applier's ClusterRole does not cover
# an object kind in kubernetes/ yet: extend 85-ci-applier.yaml in jithendar.com and run its setup-ci-applier.sh.
#
#   KUBE_CONTEXT=mk4 scripts/setup-ci-applier.sh            # read the token, test the kubeconfig, store the values
#   KUBE_CONTEXT=mk4 SKIP_GH=1 scripts/setup-ci-applier.sh  # only test; set the values in GitHub yourself
#   (kube context: KUBE_CONTEXT=<name>, else the current context with a confirmation prompt; scripts/lib/kube-context.sh)
#
# The token goes straight into `gh secret set` (stdin) and is never printed.
# Needs: kubectl allowed to read Secrets in namespace jithendar; python3 with PyYAML; gh CLI signed in with admin on
# the repository (unless SKIP_GH=1).
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib/kube-context.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/kube-context.sh"

REPO="${GITHUB_REPO:-moks-tech/practice-programming}"
NS="jithendar"
SA="github-ci-applier"
TEMPLATE=".github/jithendar-ci-applier.yaml"

cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
python3 -c "import yaml" 2>/dev/null || { echo "scripts/ci-app-manifests.py needs PyYAML: python3 -m pip install --user pyyaml==6.0.3" >&2; exit 1; }

if [[ "${SKIP_GH:-0}" != "1" ]]; then
  vars="$(gh variable list --repo "$REPO" --json name --jq '.[].name')"
  for v in MK4_API_SERVER MK4_CA_DATA; do
    grep -Fqx "$v" <<<"$vars" || { echo "Variable $v is not set in $REPO: run scripts/setup-ci-deployer.sh first." >&2; exit 1; }
  done
fi

MK4_API_SERVER="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
MK4_CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[[ -n "$MK4_CA_DATA" ]] || MK4_CA_DATA="$(base64 < "$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')" | tr -d '\n')"
[[ -n "$MK4_API_SERVER" && -n "$MK4_CA_DATA" ]] || { echo "Could not read server/CA of kube context $KCTX." >&2; exit 1; }

echo "→ Cluster $MK4_API_SERVER, ServiceAccount $NS/$SA, repository $REPO"
echo "→ Reading the token from Secret $NS/$SA-token"
MK4_CI_APPLY_TOKEN="$(kubectl -n "$NS" get secret "$SA-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
[[ -n "$MK4_CI_APPLY_TOKEN" ]] || {
  echo "No token in Secret $NS/$SA-token. The ServiceAccount is set up from jithendar.com: run its" >&2
  echo "scripts/setup-ci-applier.sh first, then this script again." >&2
  exit 1
}
export MK4_API_SERVER MK4_CA_DATA MK4_CI_APPLY_TOKEN

# Render the template exactly as the workflow does; check what it may and may not do.
echo "→ Testing $TEMPLATE with these values"
KCFG="$(mktemp)"
APPLY="$(mktemp)"
trap 'rm -f "$KCFG" "$APPLY"' EXIT
(umask 077; perl -pe 's/\$\{(MK4_[A-Z_]+)\}/$ENV{$1}/g' "$TEMPLATE" > "$KCFG")
can() { command kubectl --kubeconfig "$KCFG" auth can-i "$@" -n "$NS"; }
for allowed in "list deployments.apps" "list statefulsets.apps" "patch deployments.apps" "patch services" \
  "patch configmaps" "patch networkpolicies.networking.k8s.io"; do
  # shellcheck disable=SC2086
  [[ "$(can $allowed 2>/dev/null || true)" == yes ]] || { echo "The rendered kubeconfig may not '$allowed'; the workflow needs it." >&2; exit 1; }
done
for denied in "get secrets" "create pods" "delete deployments.apps"; do
  # shellcheck disable=SC2086
  [[ "$(can $denied 2>/dev/null || true)" == no ]] || { echo "The ServiceAccount may '$denied'; it must not." >&2; exit 1; }
done

echo "→ Dry run of every object the workflow applies, as $SA"
scripts/manifests.sh | python3 scripts/ci-app-manifests.py > "$APPLY"
command kubectl --kubeconfig "$KCFG" apply --dry-run=server -f "$APPLY" >/dev/null \
  || { echo "Server dry run refused (see above). If it says \"forbidden\", extend jithendar.com's kubernetes/85-ci-applier.yaml." >&2; exit 1; }

if [[ "${SKIP_GH:-0}" == "1" ]]; then
  cat <<OUT
Done. Set these in $REPO → Settings → Secrets and variables → Actions:
  Secret   MK4_CI_APPLY_TOKEN       = copy with: kubectl -n $NS get secret $SA-token -o jsonpath='{.data.token}' | base64 -d | pbcopy
  Variable PRACTICE_EXECUTOR_DEPLOY = true
OUT
  exit 0
fi

echo "→ Storing secret MK4_CI_APPLY_TOKEN and variable PRACTICE_EXECUTOR_DEPLOY"
printf '%s' "$MK4_CI_APPLY_TOKEN" | gh secret set MK4_CI_APPLY_TOKEN --repo "$REPO"
unset MK4_CI_APPLY_TOKEN
gh variable set PRACTICE_EXECUTOR_DEPLOY --repo "$REPO" --body true
echo "Done: pushes to master now build, apply kubernetes/ and roll out the executor on the cluster."
