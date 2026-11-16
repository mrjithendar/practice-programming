# Python practice code runner on mk4. Comments are on their own lines: pasted into zsh, a trailing "# ..." is
# passed to the command as arguments (unless `setopt interactivecomments`).

# 1. gVisor on every node. Must run ON THE mk4 HOST (where minikube runs), not on the Mac.
#    Dry run first (one "→ mk4..." block per node), then --apply (each node ends with "active" and a runsc version).
scp scripts/install-gvisor-mk4.sh <user>@<mk4-host>:/tmp/
ssh <user>@<mk4-host> bash /tmp/install-gvisor-mk4.sh
ssh <user>@<mk4-host> bash /tmp/install-gvisor-mk4.sh --apply

# 2. Back on the Mac. Every line must be PASS; stop here if not.
kubectl -n jithendar delete pod -l practice.jithendar.com/verify=true
scripts/verify-practice-sandbox.sh

# 3. The executor's cluster objects, once, by a person: RuntimeClass, admission policies, RBAC, quota (CI never applies
#    those), then the Secrets the executor and the site share.
scripts/manifests.sh | kubectl apply -f -
scripts/create-practice-executor-secrets.sh

# 4. From then on this repository's CI deploys: set repository variable PRACTICE_EXECUTOR_DEPLOY=true, then run it
#    (images, apply the application objects, roll the executor onto the new images, restart sites on a new catalog).
gh variable set PRACTICE_EXECUTOR_DEPLOY --body true
gh workflow run ci.yml --ref master
