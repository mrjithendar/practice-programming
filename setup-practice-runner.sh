# Python practice code runner on mk4. Comments are on their own lines: pasted into zsh, a trailing "# ..." is
# passed to the command as arguments (unless `setopt interactivecomments`).

# 1. Optional, skip to use the cluster's default runtime: gVisor on every node (scripts/install-gvisor-mk4.sh, written
#    for the old minikube mk4), then EXECUTOR_RUNTIME_CLASS: gvisor-nonet in kubernetes/practice-executor-40-executor.yaml
#    and RUNTIME_CLASS=gvisor-nonet for step 3.

# 2. The executor's cluster objects, once, by a person: admission policies, RBAC, quota, NetworkPolicies (CI never
#    applies the first three), then the Secrets the executor and the site share.
scripts/manifests.sh | kubectl apply -f -
scripts/create-practice-executor-secrets.sh

# 3. Every line must be PASS; stop here if not. Under the default runtime the network checks are what keeps
#    submissions away from the site, Valkey and the Kubernetes API.
kubectl -n jithendar delete pod -l practice.jithendar.com/verify=true
scripts/verify-practice-sandbox.sh

# 4. From then on this repository's CI deploys: set repository variable PRACTICE_EXECUTOR_DEPLOY=true, then run it
#    (images, apply the application objects, roll the executor onto the new images, restart sites on a new catalog).
gh variable set PRACTICE_EXECUTOR_DEPLOY --body true
gh workflow run ci.yml --ref master
