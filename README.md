# gce-github-runner
[![awesome-runners](https://img.shields.io/badge/listed%20on-awesome--runners-blue.svg)](https://github.com/jonico/awesome-runners)
[![Pre-commit](https://github.com/related-sciences/gce-github-runner/actions/workflows/pre_commit.yml/badge.svg?branch=main)](https://github.com/related-sciences/gce-github-runner/actions/workflows/pre_commit.yml)
[![Test](https://github.com/related-sciences/gce-github-runner/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/related-sciences/gce-github-runner/actions/workflows/test.yml)

Ephemeral GCE GitHub self-hosted runner.

## Usage

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
          runner_service_account: ${{ inputs.runner_service_account }}
          runner_ver: latest
          network: 'runner-net'
          subnet: 'runner-subnet'
          image_project: ubuntu-os-cloud
          image_family: ubuntu-2404-lts-amd64
          preemptible: true
          no_external_address: true
          actions_preinstalled: false
          shutdown_timeout: 60 #max runtime
          deletion_timeout: 3600 #safety-net deletion if shutdown-hook fails

  test:
    needs: create-runner
    runs-on: ${{ needs.create-runner.outputs.label }}
    steps:
      - run: echo "This runs on the GCE VM"
# Runners don't reliably cleanup due to GHA bugs, so we delete when done with a job
# **Don't use method this if you have more than one job**          
      - name: Delete Runner
        run: echo "Deleting Runner..."
      - uses: iunu/gce-github-runner@iunu
        with:
          command: stop
        if: ${{ true || always() || failure() || success() || cancelled() || needs.*.result == 'skipped' }}            
```

 * `create-runner` creates the GCE VM and registers the runner with unique label
 * `test` uses the runner
 * the runner VM will be automatically shut down after the workflow via [self-hosted runner hook](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job)

Due to bugs with runners not or overzealously shutting down if you have multiple jobs you can reliably shutdown the runners with a `workflow_run` file that runs after your workflow. Make sure the `workflows:` value(s) match the `name:` of the workflow you created:

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
Similarly you could call another workflow and pass the runner label to it, but due to issues with skipping jobs you may not be able to reliably get this to run: 

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
This would be called something like this where filename is the name of the yaml above:

```yaml
jobs:
  delete-my-runner:
    uses: ./.github/workflows/{filename}
    with:
      runner: ${{ steps.create-runner.outputs.label }}
```

## Inputs

See inputs and descriptions [here](./action.yml).

The GCE runner image should have at least:
 * `gcloud`
 * `git`
 * (optionally) GitHub Actions Runner (see `actions_preinstalled` parameter)

## Example Workflows

* [Test Workflow](./.github/workflows/test.yml): Test workflow.

## Pooled / reusable runners

By default every workflow run gets its own throwaway VM, deleted when the job finishes. For a
sequence of pushes to the same open PR, that means paying full VM boot + runner install +
dependency install/compile cost every single time.

Setting `reuse_key` opts into pooled mode instead: the VM is named deterministically from that
key (plus repo context), **stopped** (not deleted) when idle, and **resumed** (not recreated) the
next time a run with the same `reuse_key` needs a runner — skipping install/registration entirely,
and, as a side effect, keeping anything left on disk (build/dependency caches) from the prior run.

```yaml
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
```

Nothing else about the calling job needs to change — the existing `command: stop` step (whichever
pattern you use above) automatically **stops** rather than deletes a pooled VM, since that behavior
is baked into the VM at creation time.

Since a stopped pooled VM is never deleted on its own, you're responsible for reclaiming it. Wire a
`command: delete` step to your own PR-closed (or branch-deleted) trigger, using the **same
`reuse_key` and `machine_zone`** that were used to create it (instance names are zone-scoped, and
`reuse_key` is an opaque string the action doesn't interpret, so it must match exactly):

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
          reuse_key: pr-${{ github.event.pull_request.number }}
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}
          machine_zone: 'us-central1-c'
```

This step is safe to run even if CI never executed on that PR — it's a no-op if the VM doesn't exist.

**Limitations to be aware of:**

* **Security**: pooled VMs are non-ephemeral by design, and disk state (including anything a prior
  job left behind) persists across runs sharing a `reuse_key`. This raises the stakes of the
  [public-repo warning below](#self-hosted-runner-security-with-public-repositories) considerably if
  `reuse_key` can ever be influenced by an untrusted contributor (e.g. derived from a branch name
  they choose). Recommended only for private repos or trusted-contributor-only workflows.
* **Concurrency**: two overlapping runs sharing a `reuse_key` don't run in parallel — GitHub only
  ever dispatches one job at a time to a given self-hosted runner, so the second run's job queues
  until the first finishes. This is expected behavior, not a bug.
* **No auto-expiry**: nothing deletes a pooled VM on its own; cleanup is entirely the caller's
  responsibility via `command: delete`.

## Self-hosted runner security with public repositories

From [GitHub's documentation](https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners#self-hosted-runner-security-with-public-repositories):

> We recommend that you only use self-hosted runners with private repositories. This is because forks of your
> repository can potentially run dangerous code on your self-hosted runner machine by creating a pull request that
> executes the code in a workflow.

## EC2/AWS action

If you need EC2/AWS self-hosted runner, check out [machulav/ec2-github-runner](https://github.com/machulav/ec2-github-runner).
