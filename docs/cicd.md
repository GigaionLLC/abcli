# CI/CD — GitOps delivery for abctl

abctl ships three GitHub Actions workflows that turn a git repo into the control plane
for your Apple Business tenant: **plan on PR**, **gated apply on merge**, and a
**scheduled drift check**. This guide is the setup + operations reference.

> All three **self-skip** when the API secrets aren't configured, so forks and
> secret-less repos stay green. Nothing runs against your tenant until you opt in.

## The pipeline at a glance

| Workflow | File | Trigger | What it does | Writes? |
|---|---|---|---|---|
| **Plan** | [`cd-plan.yml`](../.github/workflows/cd-plan.yml) | PR touching `gitops/**` | `sync --dry-run` → posts the plan as a PR comment + job summary. exit 3 (changes pending) does **not** fail the check | ❌ read-only |
| **Apply** | [`cd-apply.yml`](../.github/workflows/cd-apply.yml) | push to `main` touching `gitops/**`, or manual dispatch | gated `sync --apply` → reconciles the tenant, commits the updated baseline back | ✅ **gated** |
| **Drift** | [`cd-drift.yml`](../.github/workflows/cd-drift.yml) | daily cron + manual dispatch | `sync --dry-run --exit-on-diff` → **fails (alerts)** if git and the tenant have diverged | ❌ read-only |

The loop: open a PR editing `gitops/` → **Plan** comments what will change → merge →
**Apply** reconciles the tenant (behind a human approval) and commits the new baseline →
**Drift** catches anyone who edits the console out-of-band.

## Setup

### 1. Adopt the `gitops/` tree (required)

By default `gitops/` is **gitignored** (seeded profiles can carry secrets). CI/CD
operates on the *committed* tree, so you must deliberately adopt it:

```sh
abctl seed                          # generate gitops/ from your live tenant
# review it — make sure no profile carries a secret you don't want in git
# then un-ignore it: remove (or negate) the `/gitops/` line in .gitignore
git add gitops/ && git commit -m "adopt gitops/ desired state"
```

The workflows have `paths: ['gitops/**']` filters, so until `gitops/` is committed they
never fire — a safe no-op.

### 2. Repo secrets (Settings → Secrets and variables → Actions)

| Secret | Used by | Notes |
|---|---|---|
| `AB_CLIENT_ID` | plan, apply, drift | `BUSINESSAPI.<uuid>` |
| `AB_PRIVATE_KEY_PEM` | plan, apply, drift | the **contents** of the EC P-256 key (SEC1 or PKCS#8) |
| `AB_CLIENT_ID_WRITE` / `AB_PRIVATE_KEY_PEM_WRITE` | the gated live-write **test** job in `ci.yml` | optional; a dedicated configurations-write-only key |

CI reads config from the **environment** (no `.env` needed): `abctl` falls back to the
`AB_*` process variables when no `.env` is present. The workflows write the PEM to a
`umask 077` temp file and point `AB_PRIVATE_KEY` at it — the key is never echoed.

### 3. The `production` environment (gates the apply)

Create an environment named **`production`** (Settings → Environments) and add
**required reviewers**. The apply job declares `environment: production`, so GitHub
pauses it for human approval before any write. The apply is also serialized
(`concurrency: abctl-apply`) so two runs never overlap, and it sets `ABCTL_APPROVE=1`
to pass abctl's own interactive confirm from CI.

### 4. Let the apply commit the baseline back

After a successful reconcile, the baseline (`gitops/state/sync-state.json`) and any
pulled console edits (`gitops/lib/**`) change; the apply job commits **only those
desired-state paths** back with `[skip ci]` so the next dry-run is accurate. This needs
`contents: write` (already declared). **If `main` is a protected branch**, allow this
workflow (or a deploy key / PAT) to push, otherwise the commit-back step fails — the
reconcile still happened, but you'd re-see the drift until the baseline is committed.

> **The `archive/` tree is never committed.** `gitops/archive/` holds pre-overwrite
> copies of the *live* profiles, which can carry tenant secrets — so it stays gitignored
> even after you adopt the rest of `gitops/`, and the apply job explicitly excludes it
> from the commit-back. Instead it's uploaded as an **expiring build artifact**
> (`abctl-archive-<run-id>`, 90-day retention) so the audit trail survives without
> landing live secrets in git history. (Locally, archiving still happens before every
> overwrite; the artifact just makes it durable for CI runs.)

## Operating

- **Deploy a change:** edit `gitops/lib/*.mobileconfig` or `gitops/blueprints/*.yml` on a
  branch → open a PR → read the plan comment → merge → approve the `production` run.
- **Prune (deletes/detaches):** off by default. Run the **Apply** workflow via *Run
  workflow* (workflow_dispatch) with `prune: true` when you intend to remove configs /
  detach blueprint members that were dropped from git. Never automatic.
- **A drift alert fired:** someone changed the console, or a git change is due. Run
  `abctl diff` locally (or re-run **Drift**) to see it, then either `abctl seed` to adopt
  the console edit into git, or merge/apply the pending git change.
- **Exit codes:** `0` ok · `1` error · `2` usage · `3` changes pending (`--exit-on-diff`).

## Safety recap

Read-only by default · every write behind `--apply` + the `production` approval ·
`--prune` off unless explicitly dispatched · `--limit-writes N` available as a circuit
breaker · archive-before-overwrite on every replace/delete · secrets come from Actions
secrets, never committed. See [SECURITY.md](../SECURITY.md) and
[design-abctl.md](design-abctl.md) §7.
