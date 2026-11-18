#!/usr/bin/env bash
# Prove the sandbox isolation on mk4 before enabling code execution. Starts a throwaway sandbox pod in namespace
# jithendar, shaped like the dispatcher's (executor/app/backends.py pod_spec), under the runtime the executor uses
# (RUNTIME_CLASS: empty = the cluster's default runtime, the default; gvisor-nonet = gVisor) and checks, from inside:
#   1. nothing is reachable: the Kubernetes API (service and node address), the kubelet, cluster DNS, the site,
#      Valkey, the cloud metadata endpoint and the public internet all fail, and names do not resolve. Under the
#      default runtime that is NetworkPolicy practice-sandbox (deny all) at work, so this is the check that matters;
#   2. no service-account token is mounted, and the process runs as a non-root user;
#   3. with RUNTIME_CLASS=gvisor-nonet only: the kernel is gVisor's and there is only a loopback interface;
#   4. the admission policies: a pod like the dispatcher's is admitted, a sandbox pod with another RuntimeClass is
#      rejected, the dispatcher cannot start a pod that reads the site's Secret and cannot delete the site's pods
#      (server-side dry runs, impersonating it).
# Prints PASS/FAIL per check; exits non-zero on any failure. Creates and deletes only its own probe pod.
#
#   scripts/verify-practice-sandbox.sh                         # default runtime (EXECUTOR_RUNTIME_CLASS empty)
#   RUNTIME_CLASS=gvisor-nonet scripts/verify-practice-sandbox.sh
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/kube-context.sh"
NS=jithendar
IMAGE="${SANDBOX_IMAGE:-python:3.13-slim}"
RUNTIME_CLASS="${RUNTIME_CLASS:-}"
k() { kubectl "$@"; }
fail=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }
json() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# What the probe tries to reach: name=host:port, looked up from the cluster (empty entries are skipped).
svc_ip() { k -n "$1" get svc "$2" -o jsonpath='{.spec.clusterIP}' 2>/dev/null; }
api_ep=$(k -n default get endpointslice -l kubernetes.io/service-name=kubernetes \
  -o jsonpath='{.items[0].endpoints[0].addresses[0]}:{.items[0].ports[0].port}' 2>/dev/null)
node_ip=${api_ep%%:*}
targets=""
add() { [[ -n "$2" && "$2" != :* && "$2" != *: ]] && targets+="$1=$2 "; }
add apiserver-service "$(svc_ip default kubernetes):443"
add apiserver-node "$api_ep"
add kubelet "${node_ip:+$node_ip:10250}"
add cluster-dns "$(svc_ip kube-system kube-dns):53"
add site "$(svc_ip $NS jithendar-com):80"
add valkey "$(svc_ip redis valkey-master):6379"
add metadata "169.254.169.254:80"
add internet "1.1.1.1:443"

probe='
import os, socket
print("KERNEL", open("/proc/version").read().strip())
print("IFACES", sorted(os.listdir("/sys/class/net")) if os.path.exists("/sys/class/net") else "none")
print("TOKEN", os.path.exists("/var/run/secrets/kubernetes.io/serviceaccount/token"))
print("UID", os.getuid())
for t in os.environ["TARGETS"].split():
    name, addr = t.split("=")
    host, port = addr.rsplit(":", 1)
    try:
        socket.create_connection((host, int(port)), timeout=3).close(); r = "open"
    except Exception as e:
        r = type(e).__name__
    print("REACH", name, addr, r)
try:
    socket.gethostbyname("example.com"); print("DNS resolved")
except Exception as e:
    print("DNS", type(e).__name__)
'

# A pod shaped like the dispatcher's. $1 = name, $2 = runtimeClassName ("" = none), $3 = extra container fields.
sandbox_pod() {
  cat <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $1, namespace: $NS, labels: { app.kubernetes.io/name: practice-sandbox, practice.jithendar.com/verify: "true", sidecar.istio.io/inject: "false" } }
spec:
${2:+  runtimeClassName: $2
}  serviceAccountName: practice-sandbox
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  activeDeadlineSeconds: 120
  securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: { type: RuntimeDefault } }
  volumes: [{ name: tmp, emptyDir: { medium: Memory, sizeLimit: 16Mi } }]
  containers:
    - name: probe
      image: $IMAGE
      resources: { limits: { cpu: "500m", memory: 256Mi }, requests: { cpu: 100m, memory: 128Mi } }
      securityContext: { allowPrivilegeEscalation: false, privileged: false, readOnlyRootFilesystem: true, runAsNonRoot: true, capabilities: { drop: ["ALL"] } }
      volumeMounts: [{ name: tmp, mountPath: /tmp }]
$3
YAML
}

pod=verify-$RANDOM
no_runtime=
probe_fields="      command: [\"python\", \"-c\", $(printf '%s' "$probe" | json)]
      env: [{ name: TARGETS, value: \"$targets\" }]"
if ! created=$(sandbox_pod "$pod" "$RUNTIME_CLASS" "$probe_fields" | k apply -f - 2>&1); then
  echo "FAIL  probe pod not admitted: $created"
  echo "      (are practice-executor-10/-15/-20 applied? scripts/manifests.sh | kubectl apply -f -)"
  exit 1
fi
echo "Starting probe pod $NS/$pod with runtime ${RUNTIME_CLASS:-<cluster default>} (up to 2 minutes)..."
for ((i = 0; i < 60; i++)); do
  phase=$(k -n $NS get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
  why=$(k -n $NS get events --field-selector "involvedObject.name=$pod,reason=FailedCreatePodSandBox" -o jsonpath='{.items[-1:].message}' 2>/dev/null)
  if [[ "$why" == *"no runtime for"* ]]; then
    node=$(k -n $NS get pod "$pod" -o jsonpath='{.spec.nodeName}')
    echo "FAIL  node $node has no $RUNTIME_CLASS runtime: install it (scripts/install-gvisor-mk4.sh) or leave RUNTIME_CLASS empty"
    fail=1
    no_runtime=1
    break
  fi
  sleep 2
done
echo "      probe pod phase: ${phase:-unknown}"
out=$(k -n $NS logs $pod 2>&1)
k -n $NS delete pod $pod --wait=false >/dev/null 2>&1
if [[ -n "${no_runtime:-}" ]]; then
  echo "SKIP  in-sandbox checks: the probe pod could not start"
else
  echo "$out" | sed 's/^/      /'
  check "probe ran"                   'grep -q "^KERNEL" <<<"$out"'
  for t in $targets; do
    name=${t%%=*}
    check "$name unreachable (${t#*=})" 'grep -q "^REACH $name " <<<"$out" && ! grep -q "^REACH $name .* open$" <<<"$out"'
  done
  check "DNS does not resolve"        '! grep -q "DNS resolved" <<<"$out" && grep -q "^DNS" <<<"$out"'
  check "no service-account token"    'grep -q "TOKEN False" <<<"$out"'
  check "runs as a non-root user"     'grep -q "^UID 65532$" <<<"$out"'
  if [[ "$RUNTIME_CLASS" == gvisor-nonet ]]; then
    check "gVisor kernel"             'grep -qi "KERNEL.*\(gVisor\|Linux version 4.4.0\)" <<<"$out"'
    check "loopback only"             'grep -q "IFACES \[.lo.\]\|IFACES none" <<<"$out"'
  fi
fi

DISPATCHER=system:serviceaccount:$NS:practice-dispatcher
admitted=$(sandbox_pod should-be-admitted "$RUNTIME_CLASS" '      command: ["true"]' | k apply --dry-run=server --as="$DISPATCHER" -f - 2>&1)
check "a pod like the dispatcher's is admitted" 'grep -q "created (server dry run)" <<<"$admitted"'
grep -q "created (server dry run)" <<<"$admitted" || echo "      $admitted"
rejected=$(sandbox_pod should-be-rejected nvidia '      command: ["true"]' | k apply --dry-run=server -f - 2>&1)
check "admission rejects sandbox pods with another RuntimeClass" 'grep -q "default runtime or RuntimeClass gvisor-nonet" <<<"$rejected"'

stolen=$(cat <<YAML | k apply --dry-run=server --as="$DISPATCHER" -f - 2>&1
apiVersion: v1
kind: Pod
metadata: { name: should-be-rejected, namespace: $NS }
spec:
  restartPolicy: Never
  containers: [{ name: c, image: $IMAGE, command: ["true"], envFrom: [{ secretRef: { name: jithendar-com-env } }] }]
YAML
)
check "dispatcher cannot start a pod reading the site's Secret" 'grep -qi "denied\|forbidden" <<<"$stolen"'
site_pod=$(k -n $NS get pods -l app=jithendar-com -o name | head -1)
deleted=$(k -n $NS delete "$site_pod" --dry-run=server --as="$DISPATCHER" 2>&1)
check "dispatcher cannot delete the site's pods" 'grep -q "only sandbox pods" <<<"$deleted"'
# A policy expression that does not type-check errors at admission and, with failurePolicy Fail, rejects pods.
for policy in practice-sandbox-pods practice-dispatcher-deletes; do
  warnings=$(k get validatingadmissionpolicy "$policy" -o jsonpath='{.status.typeChecking.expressionWarnings}' 2>&1)
  check "policy $policy type-checks cleanly" '[[ -z "$warnings" ]]'
  [[ -z "$warnings" ]] || echo "      $warnings"
done
exit $fail
