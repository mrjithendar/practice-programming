# practice-programming

Programming practice for moks-cms sites (today [jithendar.com/python-practice](https://jithendar.com/python-practice)):
the sandboxed code executor, one sandbox image per language, the problem bank, and the executor's Kubernetes
manifests. The practice pages, the admin and the seeding are part of the CMS
([moks-cms](https://github.com/moks-tech/moks-cms), `services/www/src/lib/practice`). Moved here on 2026-11-16: the executor from
moks-cms `services/executor`, the problems from jithendar.com `content/python-practice`, history kept.

| Path | Contents |
|---|---|
| [`executor/`](executor/README.md) | FastAPI API + dispatcher (Redis queue, a fresh sandbox pod per job, gVisor optional), tests, `Dockerfile` |
| `executor/sandbox/` | The Python sandbox image and `runner.py`, which runs inside it |
| `executor/tools/build_problems.py` | Validates the problems (every reference solution runs through the real runner) and writes the catalog |
| `problems/python/` | `roles.yaml`, `topics.yaml`, `problems/*.yaml` (written by people) and `catalog.generated.json` (generated, committed) |
| `Dockerfile.catalog` | `practice-catalog`: the generated catalogs, one folder per language, copied into a site by an init container |
| `kubernetes/` | `practice-executor-*.yaml`: RuntimeClass (optional gVisor), RBAC, admission policies, quota, the API and dispatcher, NetworkPolicies (namespace `jithendar`) |
| `scripts/` | `manifests.sh`, rollout (`ci-rollout.py`, `keep-live-images.py`, `ci-app-manifests.py`), `install-gvisor-mk4.sh`, `verify-practice-sandbox.sh`, `create-practice-executor-secrets.sh` |
| [`docs/`](docs/PYTHON_PRACTICE_EXECUTOR.md) | Threat model, architecture, turning it on, operating it |

## CI (`.github/workflows/ci.yml`)

- **Pull requests:** executor tests, catalog validity and freshness, the manifests render, the scripts' tests.
- **Push to `master`:** the same checks, then images (`practice-executor:<commit>`, `practice-sandbox:<commit>`, both
  also `:latest`; `practice-catalog:latest`).
- **Deploy** (when `PRACTICE_EXECUTOR_DEPLOY=true`): apply the application objects, roll the executor onto
  `<commit>`, and restart the sites that load the catalog if it changed.

## Writing a problem

Add `problems/python/problems/<level>.yaml` entries, then:

```sh
pip install pyyaml
python executor/tools/build_problems.py      # validates and rewrites problems/python/catalog.generated.json
```

Commit both. After the merge, the sites pick up new and changed problems on their next start (CI restarts them).

## Another language

The executor's runtimes are a map, runtime id → sandbox image (`EXECUTOR_RUNTIMES` in
`kubernetes/practice-executor-40-executor.yaml`; today only `python-3.13`). A new language needs a sandbox image with
its own runner (same result protocol: `docs/PYTHON_PRACTICE_EXECUTOR.md`), a problem folder `problems/<language>/` with
a builder that writes its catalog, the image built in CI, and support in moks-cms's practice pages, which today
assume Python.

## Setup (once)

Secrets `HARBOR_USERNAME`, `HARBOR_PASSWORD`, `MK4_CI_TOKEN`, `MK4_CI_APPLY_TOKEN`; variables `MK4_API_SERVER`,
`MK4_CA_DATA`, `PRACTICE_EXECUTOR_DEPLOY`. `scripts/setup-ci-deployer.sh`, then `scripts/setup-ci-applier.sh`, set
the cluster ones (`KUBE_CONTEXT=mk4`). They reuse the ServiceAccounts `github-ci-deployer` and `github-ci-applier`
that jithendar.com sets up (and rotates) with its own scripts of the same names: run those first. First-time cluster steps: `setup-practice-runner.sh`.

## License

Copyright (c) 2026 Jithendar Dharmapuri. All rights reserved.
