# gce-github-runner
[![awesome-runners](https://img.shields.io/badge/listed%20on-awesome--runners-blue.svg)](https://github.com/jonico/awesome-runners)
[![Pre-commit](https://github.com/related-sciences/gce-github-runner/actions/workflows/pre_commit.yml/badge.svg?branch=main)](https://github.com/related-sciences/gce-github-runner/actions/workflows/pre_commit.yml)
[![Test](https://github.com/related-sciences/gce-github-runner/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/related-sciences/gce-github-runner/actions/workflows/test.yml)

GCE GitHub self-hosted runner, ephemeral by default with an optional pooled/reusable mode.

## How it works

This action has three commands, used in different jobs of your workflow(s):

| `command` | What it does | Runs on | Typical trigger |
|---|---|---|---|
| `start` (default) | Creates (or, in pool mode, resumes) a GCE VM and registers it as a GitHub Actions runner | A GitHub-hosted runner (e.g. `ubuntu-latest`) | The workflow that needs the runner |
| `stop` | Schedules the VM to shut itself down (and, unless pooled, delete itself) after a grace period | **The GCE runner itself** (`runs-on: <label>`) | End of the same job, or a cleanup job/workflow |
| `delete` | Deletes a pooled VM and deregisters it from GitHub | A GitHub-hosted runner | A separate cleanup trigger (PR closed, branch deleted, etc.) |

The VM also shuts itself down automatically via a [runner hook](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job) once a job finishes, and `deletion_timeout` is a safety-net that tears it down even if that hook never fires. An explicit `stop` step is only needed for workflows with more than one job on the same runner (see below).

## Quick start: one job, ephemeral runner

The simplest case — a single job runs on the VM, then the shutdown hook cleans it up automatically. No `stop`/`delete` step needed at all.

```yaml
jobs:
  create-runner:
    runs-on: ubuntu-latest
    outputs:
      label: ${{ steps.create-runner.outputs.label }}
    steps:
      - name: Create Runner
        id: create-runner
        uses: iunu/gce-github-runner@iunu
        with:
          token: ${{ secrets.GH_PAT_TOKEN }}
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}
          machine_zone: 'us-central1-c'
          machine_type: 'c2-standard-4'
          runner_ver: latest
          network: 'runner-net'
          subnet: 'runner-subnet'
          image_project: ubuntu-os-cloud
          image_family: ubuntu-2404-lts-amd64
          preemptible: true
          no_external_address: true
          actions_preinstalled: false
          shutdown_timeout: 60   # grace period given to the runner hook after a job finishes
          deletion_timeout: 3600 # safety-net teardown if the shutdown hook never fires

  test:
    needs: create-runner
    runs-on: ${{ needs.create-runner.outputs.label }}
    steps:
      - run: echo "This runs on the GCE VM"
```

* `create-runner` creates the GCE VM and registers it under a unique `label`, output for the next job to target via `runs-on`.
* `test` runs on that VM.
* Once `test` finishes, the runner hook installed on the VM shuts it down within `shutdown_timeout` seconds; `deletion_timeout` guarantees teardown even if that hook fails.

`token`, `project_id`, and `service_account_key` are the only inputs every `start` call needs to supply explicitly; everything else has a workable default — see [Inputs](#inputs).

## Multiple jobs on the same runner: explicit `stop`

The shutdown hook fires per-job, which can tear the VM down too early (or not at all) once more than one job shares it. For that case, add an explicit `command: stop` step. It runs **on the GCE runner itself**, not on a hosted runner, and needs no credentials or GCE inputs beyond `command: stop` — it reads its own instance name/zone from the VM's metadata server:

```yaml
jobs:
  create-runner:
    runs-on: ubuntu-latest
    outputs:
      label: ${{ steps.create-runner.outputs.label }}
    steps:
      - name: Create Runner
        id: create-runner
        uses: iunu/gce-github-runner@iunu
        with:
          token: ${{ secrets.GH_PAT_TOKEN }}
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}
          machine_zone: 'us-central1-c'
          machine_type: 'c2-standard-4'
          preemptible: true
          no_external_address: true

  build:
    needs: create-runner
    runs-on: ${{ needs.create-runner.outputs.label }}
    steps:
      - run: echo "build step"

  test:
    needs: [create-runner, build]
    runs-on: ${{ needs.create-runner.outputs.label }}
    steps:
      - run: echo "test step"
      - name: Stop Runner
        uses: iunu/gce-github-runner@iunu
        with:
          command: stop
        if: always()
```

Because ordinary job failures can skip downstream jobs, this pattern is unreliable once jobs might get skipped. Two more robust alternatives:

**A `workflow_run` cleanup workflow**, matching `workflows:` to the `name:` of your main workflow:

```yaml
name: Runner Cleanup

on:
  workflow_run:
    workflows: [Workflow Name]
    types:
      - completed

jobs:
  runner-cleanup:
    runs-on: self-hosted
    steps:
      - uses: iunu/gce-github-runner@iunu
        with:
          command: stop
        if: always()
```

**A reusable `workflow_call` workflow**, passing in the runner label explicitly:

```yaml
name: Runner Cleanup Reusable Workflow

on:
  workflow_call:
    inputs:
      runner:
        required: true
        type: string

jobs:
  runner-cleanup:
    runs-on: ${{ inputs.runner }}
    steps:
      - uses: iunu/gce-github-runner@iunu
        with:
          command: stop
        if: always()
```

Called like:

```yaml
jobs:
  delete-my-runner:
    uses: ./.github/workflows/{filename}
    with:
      runner: ${{ steps.create-runner.outputs.label }}
```

## Pooled / reusable runners

By default every workflow run gets its own throwaway VM, deleted when the job finishes. For a
sequence of pushes to the same open PR, that means paying full VM boot + runner install +
dependency install/compile cost every single time.

Setting `reuse_key` opts into pooled mode instead: the VM is named deterministically from that
key (plus repo context), **stopped** (not deleted) when idle, and **resumed** (not recreated) the
next time a run with the same `reuse_key` needs a runner — skipping install/registration entirely,
and, as a side effect, keeping anything left on disk (build/dependency caches) from the prior run.

**1. Create/resume the pooled runner** — same `start` call as above, plus `reuse_key`:

```yaml
jobs:
  create-runner:
    runs-on: ubuntu-latest
    outputs:
      label: ${{ steps.create-runner.outputs.label }}
    steps:
      - name: Create Runner
        id: create-runner
        uses: iunu/gce-github-runner@iunu
        with:
          token: ${{ secrets.GH_PAT_TOKEN }}
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}
          machine_zone: 'us-central1-c'
          machine_type: 'c2-standard-4'
          preemptible: true
          reuse_key: pr-${{ github.event.pull_request.number }}

  test:
    needs: create-runner
    runs-on: ${{ needs.create-runner.outputs.label }}
    steps:
      - run: echo "This runs on the pooled GCE VM"
```

**2. Stop when idle** — nothing changes here: whichever `command: stop` pattern you use above
automatically **stops** rather than deletes a pooled VM, since that behavior is baked into the VM
at creation time. The stop is a plain guest-initiated poweroff (which lands the VM in TERMINATED
exactly like an API stop, disk intact), so pooled runners need **no compute IAM permissions at
all** on their service account — only ephemeral runners' self-*delete* needs
`compute.instances.delete`.

**Self-healing**: manually deleting a pooled VM (e.g. to force it to pick up new runner/image
changes on the next run) is safe, even mid-cycle. The `start` lookup detects an in-flight delete
operation before trusting a `RUNNING` status (a deleting VM still *describes* as running for
tens of seconds, with stale-but-passing readiness signals), waits it out, and creates fresh; a
pooled VM that can't be resumed for any reason (stockout, mid-deletion, wedged) is deleted and
recreated; and a reused VM that never comes online gets one delete-and-recreate retry before the
run fails.

**3. Reclaim it eventually** — a stopped pooled VM is never deleted on its own, so wire a
`command: delete` step to your own PR-closed (or branch-deleted) trigger, using the **same
`reuse_key`, `machine_zone`, and (if used) `machine_zones`** that were used to create it (instance
names are zone-scoped, and `reuse_key` is an opaque string the action doesn't interpret, so it
must match exactly):

```yaml
name: Runner Pool Cleanup

on:
  pull_request:
    types: [closed]

jobs:
  delete-pooled-runner:
    runs-on: ubuntu-latest
    steps:
      - uses: iunu/gce-github-runner@iunu
        with:
          command: delete
          token: ${{ secrets.GH_PAT_TOKEN }}
          reuse_key: pr-${{ github.event.pull_request.number }}
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}
          machine_zone: 'us-central1-c'
```

`delete` needs `token` (to deregister the runner from GitHub), `reuse_key` (to compute which VM
to target), and `project_id`/`service_account_key`/`machine_zone` (to authenticate and locate it)
— it does not need any of the machine-shape inputs (`machine_type`, `image_family`, etc.), since
it's only ever destroying, never creating.

This step is safe to run even if CI never executed on that PR — it's a no-op if the VM doesn't exist.
It also deregisters the runner from GitHub (via the API, using `token`) if one is found, since a
pooled runner is normally non-ephemeral (unless `ephemeral: true` was also set — see below) and
would otherwise sit "Offline" in the GitHub Actions UI for up to 30 days after its VM is gone,
until GitHub's own stale-runner cleanup catches up.

If you also use `machine_zones` fallback (see below) together with `reuse_key`, the pooled VM may
land in a fallback zone rather than your static `machine_zone` input. Both `start` (looking up an
existing pooled VM to resume) and `delete` search every zone in `machine_zone` + `machine_zones`
(GCE instance names are unique per-zone, not per-project) — so pass the **same `machine_zone` and
`machine_zones` values** to every `start` and `delete` call for a given `reuse_key`, and the VM
will be found regardless of which zone it actually landed in. If you don't — e.g. a `delete` step
that omits `machine_zones` — the search may miss it, leaving an orphaned VM running, or (worse, on
`start`) conclude none exists and create a duplicate with the same name in another zone.

If the pooled VM's own zone is stocked out when trying to resume it, `start` deletes the stale
VM/disk there and creates a fresh one, retrying across `machine_zone` + `machine_zones` the same
way a first-time create does — a stopped VM's disk can't be moved to another zone in place, so
this trades away that run's warm start (no cached build/dependency state) in exchange for the
runner coming up at all instead of the whole workflow failing.

If you also set `ephemeral: true` together with `reuse_key`, the VM is always **deleted** (not
stopped) after use — a GitHub-side ephemeral runner registration self-deregisters after exactly
one job and can never be reused no matter what happens to the VM, so stopping it for a later
resume would provide no benefit. `reuse_key` still gives it a deterministic name; there's just
nothing to warm-start, since every run creates fresh.

**Limitations to be aware of:**

* **Security**: pooled VMs are non-ephemeral by default (unless `ephemeral: true` is also set,
  see above), and disk state (including anything a prior job left behind) persists across runs
  sharing a `reuse_key`. This raises the stakes of the
  [public-repo warning below](#self-hosted-runner-security-with-public-repositories) considerably if
  `reuse_key` can ever be influenced by an untrusted contributor (e.g. derived from a branch name
  they choose). Recommended only for private repos or trusted-contributor-only workflows.
* **Concurrency**: two overlapping runs sharing a `reuse_key` don't run in parallel — GitHub only
  ever dispatches one job at a time to a given self-hosted runner, so the second run's job queues
  until the first finishes. This is expected behavior, not a bug.
* **No auto-expiry**: nothing deletes a pooled VM on its own; cleanup is entirely the caller's
  responsibility via `command: delete`. The one exception is a VM that never comes online in the
  first place: if it fails to boot and register within 5 minutes of `start` (e.g. a corrupted
  disk from a prior run), it's deleted rather than left stopped, so the next run gets a clean
  rebuild instead of repeatedly retrying the same broken state.

## Inputs

See inputs and descriptions [here](./action.yml).

The GCE runner image should have at least:
 * `gcloud`
 * `git`
 * (optionally) GitHub Actions Runner (see `actions_preinstalled` parameter)

`project_id` and `service_account_key` are optional on `start`/`delete`: if omitted, `gcloud` must
already be authenticated some other way in the calling job (e.g. via
[`google-github-actions/auth`](https://github.com/google-github-actions/auth)).

## Zone fallback on capacity stockouts

Preemptible/spot VMs can be rejected with a capacity error (`ZONE_RESOURCE_POOL_EXHAUSTED`) when
a zone simply doesn't have machines to spare. Set `machine_zones` to a comma-separated list of
additional zones to try, in order, if `machine_zone` (or an earlier fallback) hits this specific
error:

```yaml
          machine_zone: 'us-central1-c'
          machine_zones: 'us-central1-a,us-central1-f'
```

This applies to creating a brand-new VM. It also applies when resuming an existing pooled
(`reuse_key`) VM *if* that resume itself hits a stockout: since a pooled VM's disk is pinned to
whichever zone it was originally created in and can't be moved in place, resuming can't retry the
existing disk in another zone — instead, the stale VM/disk is deleted and a fresh one is created
via the same fallback list, losing that run's warm-start state but still coming up. Any other
failure (bad image, quota exceeded, auth error, etc.) fails immediately without trying other zones.

The VM may land in a different zone than the `machine_zone` input if fallback was used. The
`zone` output always reflects the zone actually used:

```yaml
    outputs:
      label: ${{ steps.create-runner.outputs.label }}
      zone: ${{ steps.create-runner.outputs.zone }}
```

If you're using `reuse_key` together with `machine_zones`, see the note in
[Pooled / reusable runners](#pooled--reusable-runners) about passing the same `machine_zones`
value consistently to `delete` as well.

## Preemption behavior

`preemptible: true` creates a Spot VM (`--provisioning-model=SPOT` — the successor to legacy
preemptible: same discounts, same preemption mechanics, no 24h forced-stop cap). When GCE
preempts a runner mid-job:

* **The workflow run is cancelled within seconds.** A preemption watcher on the VM long-polls
  the metadata server's `instance/preempted` endpoint, which GCE flips at the very start of the
  preemption notice — while the network is still fully up. The watcher cancels the active
  workflow run via the GitHub API (deterministic and server-side, no dependence on the dying
  VM's teardown races), then also stops the runner service as a fallback signal. Without this,
  a preempted job just spins until GitHub's ~10-minute lost-communication timeout. This applies
  to ephemeral and pooled runners alike. The watcher always cancels the run whose job is
  actually executing on the VM — the job-started hook records the current run id on every job,
  so a pooled VM serving many runs cancels the right one.
* **Ephemeral VMs are deleted by GCE itself** (`--instance-termination-action=DELETE`), entirely
  server-side — a preempted ephemeral runner can never linger as a zombie TERMINATED instance,
  even if the guest gets no shutdown window at all. The watcher also deregisters the runner from
  GitHub (ephemeral registrations can never be reused; GitHub's own auto-purge of offline
  ephemeral runners after 1 day serves as the backstop if the window closes first).
* **Pooled persistent VMs are stopped, not deleted** (`--instance-termination-action=STOP`) —
  disk state survives, the runner registration is deliberately left intact, and the next `start`
  with the same `reuse_key` resumes the VM and reconnects the same runner.

**Security trade-off**: to make the API cancellation possible, the `token` input is baked into a
preemptible VM's startup-script metadata, which is readable by any process on the VM — the same
trust domain that already runs your workflow code. Non-preemptible VMs never receive the token.
Use a PAT you can rotate easily, scoped as tightly as your setup allows.

Note the run interrupted by preemption ends **cancelled**, not failed — these mechanics guarantee
prompt termination and clean resource teardown, not retry. Pair with `machine_zones` (above) so
the retry run can land somewhere with capacity.

## Example Workflows

* [Test Workflow](./.github/workflows/test.yml): Test workflow.

## Self-hosted runner security with public repositories

From [GitHub's documentation](https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners#self-hosted-runner-security-with-public-repositories):

> We recommend that you only use self-hosted runners with private repositories. This is because forks of your
> repository can potentially run dangerous code on your self-hosted runner machine by creating a pull request that
> executes the code in a workflow.

## EC2/AWS action

If you need EC2/AWS self-hosted runner, check out [machulav/ec2-github-runner](https://github.com/machulav/ec2-github-runner).
