#!/usr/bin/env bash

ACTION_DIR="$( cd $( dirname "${BASH_SOURCE[0]}" ) >/dev/null 2>&1 && pwd )"

function usage {
  echo "Usage: ${0} --command=[start|stop|delete] <arguments>"
}

function safety_on {
  set -o errexit -o pipefail -o noclobber -o nounset
}

function safety_off {
  set +o errexit +o pipefail +o noclobber +o nounset
}

source "${ACTION_DIR}/vendor/getopts_long.sh"

command=
token=
project_id=
service_account_key=
runner_ver=
machine_zone=
machine_zones=
machine_type=
machine_types=
boot_disk_type=
disk_size=
runner_service_account=
image_project=
image=
image_family=
network=
scopes=
shutdown_timeout=
finish_timeout=
deletion_timeout=
subnet=
preemptible=
ephemeral=
no_external_address=
actions_preinstalled=
maintenance_policy_terminate=
arm=
accelerator=
min_cpu_platform_flag=
reuse_key=

OPTLIND=1
while getopts_long :h opt \
  command required_argument \
  token required_argument \
  project_id required_argument \
  service_account_key required_argument \
  runner_ver required_argument \
  machine_zone required_argument \
  machine_zones optional_argument \
  machine_type required_argument \
  machine_types optional_argument \
  boot_disk_type optional_argument \
  disk_size optional_argument \
  runner_service_account optional_argument \
  image_project optional_argument \
  image optional_argument \
  image_family optional_argument \
  network optional_argument \
  scopes required_argument \
  shutdown_timeout required_argument \
  finish_timeout required_argument \
  deletion_timeout required_argument \
  subnet optional_argument \
  preemptible required_argument \
  ephemeral required_argument \
  no_external_address required_argument \
  actions_preinstalled required_argument \
  arm required_argument \
  maintenance_policy_terminate optional_argument \
  accelerator optional_argument \
  min_cpu_platform optional_argument \
  reuse_key optional_argument \
  help no_argument "" "$@"
do
  case "$opt" in
    command)
      command=$OPTLARG
      ;;
    token)
      token=$OPTLARG
      ;;
    project_id)
      project_id=$OPTLARG
      ;;
    service_account_key)
      service_account_key="$OPTLARG"
      ;;
    runner_ver)
      runner_ver=$OPTLARG
      ;;
    machine_zone)
      machine_zone=$OPTLARG
      ;;
    machine_zones)
      machine_zones=${OPTLARG-$machine_zones}
      ;;
    machine_type)
      machine_type=$OPTLARG
      ;;
    machine_types)
      machine_types=${OPTLARG-$machine_types}
      ;;
    boot_disk_type)
      boot_disk_type=${OPTLARG-$boot_disk_type}
      ;;
    disk_size)
      disk_size=${OPTLARG-$disk_size}
      ;;
    runner_service_account)
      runner_service_account=${OPTLARG-$runner_service_account}
      ;;
    image_project)
      image_project=${OPTLARG-$image_project}
      ;;
    image)
      image=${OPTLARG-$image}
      ;;
    image_family)
      image_family=${OPTLARG-$image_family}
      ;;
    network)
      network=${OPTLARG-$network}
      ;;
    scopes)
      scopes=$OPTLARG
      ;;
    shutdown_timeout)
      shutdown_timeout=$OPTLARG
      ;;
    finish_timeout)
      finish_timeout=$OPTLARG
      ;;
    deletion_timeout)
      deletion_timeout=$OPTLARG
      ;;
    subnet)
      subnet=${OPTLARG-$subnet}
      ;;
    preemptible)
      preemptible=$OPTLARG
      ;;
    ephemeral)
      ephemeral=$OPTLARG
      ;;
    no_external_address)
      no_external_address=$OPTLARG
      ;;
    actions_preinstalled)
      actions_preinstalled=$OPTLARG
      ;;
    maintenance_policy_terminate)
      maintenance_policy_terminate=${OPTLARG-$maintenance_policy_terminate}
      ;;
    arm)
      arm=$OPTLARG
      ;;
    accelerator)
      accelerator=$OPTLARG
      ;;
    min_cpu_platform)
      min_cpu_platform_flag=--min-cpu-platform="$OPTLARG"
      ;;
    reuse_key)
      reuse_key=${OPTLARG-$reuse_key}
      ;;
    h|help)
      usage
      exit 0
      ;;
    :)
      printf >&2 '%s: %s\n' "${0##*/}" "$OPTLERR"
      usage
      exit 1
      ;;
  esac
done

function gcloud_auth {
  # NOTE: when --project is specified, it updates the config
  echo ${service_account_key} | gcloud --project  ${project_id} --quiet auth activate-service-account --key-file - &>/dev/null
  echo "✅ Successfully configured gcloud."
}

# Splits a comma-separated list into one trimmed entry per line, dropping empty entries --
# tolerating the whitespace and trailing commas users commonly write in YAML values (e.g.
# "n2d-highcpu-16, c2-standard-16" or "us-central1-a,"). Without this, an entry like
# " c2-standard-16" reaches an unquoted --machine-type=${...} expansion, word-splits into a
# broken flag, and hard-fails the run looking like caller misconfiguration instead of being
# tried as a fallback. Used for machine_zones (start_vm AND delete_vm) and machine_types.
function split_csv {
  local IFS=',' entry
  for entry in $1; do
    entry="${entry#"${entry%%[![:space:]]*}"}"   # ltrim
    entry="${entry%"${entry##*[![:space:]]}"}"   # rtrim
    if [[ -n "${entry}" ]]; then
      echo "${entry}"
    fi
  done
}

# GCE instance names (unlike labels) must match ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ (<=63 chars,
# no dots/underscores, must start with a letter). Used by both start_vm (pool mode) and delete_vm,
# so it must be a top-level function -- delete_vm never calls start_vm.
function compute_pool_vm_name {
  local reuse_key="${1}"
  local owner repo raw digest sanitized prefix suffix max_body

  owner="$(tr '[:upper:]' '[:lower:]' <<< "${GITHUB_REPOSITORY_OWNER}")"
  repo="$(tr '[:upper:]' '[:lower:]' <<< "${GITHUB_REPOSITORY##*/}")"
  raw="${owner}/${repo}/${reuse_key}"

  # Hash the full untruncated tuple so truncating the readable part below can never cause two
  # distinct (repo, reuse_key) pairs to collide on the same instance name.
  digest="$(printf '%s' "${raw}" | sha256sum | cut -c1-10)"

  sanitized="$(tr -c 'a-z0-9' '-' <<< "${raw}")"
  sanitized="$(sed -E 's/-+/-/g; s/^-+//; s/-+$//' <<< "${sanitized}")"

  prefix="gce-ghr-"
  suffix="-${digest}"
  max_body=$(( 63 - ${#prefix} - ${#suffix} ))
  sanitized="$(sed -E 's/-+$//' <<< "${sanitized:0:max_body}")"

  echo -n "${prefix}${sanitized}${suffix}"
}

# Builds the GCE startup-script metadata value (sets $startup_script as a side effect). Reads
# VM_ID, machine_zone, vm_teardown_action, shutdown_timeout, deletion_timeout, GITHUB_REPOSITORY,
# GITHUB_RUN_ID, RUNNER_TOKEN, token, preemptible, ephemeral_flag, actions_preinstalled,
# runner_ver, arm, and pool_action (create vs start/resume -- defaults to create if unset) from
# the enclosing scope.
# Safe to call more than once per start_vm invocation (e.g. once per zone-fallback attempt): the
# "runner_ver=latest" resolution below mutates runner_ver to a concrete version on first call, so
# the GitHub API lookup is automatically skipped on any later call.
function build_startup_script {
  # Steps needed to fetch/extract the runner binary on a genuinely fresh VM -- gated below behind
  # the same /actions-runner/.runner existence check as config.sh, so a resumed pooled VM skips
  # this entirely instead of redundantly re-downloading and re-extracting on every resume.
  runner_download_cmds=""
  if ! $actions_preinstalled ; then
    if [[ "$runner_ver" = "latest" ]]; then
      latest_ver=$(curl -sL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed -e 's/^v//')
      runner_ver="$latest_ver"
      echo "✅ runner_ver=latest is specified. v$latest_ver is detected as the latest version."
      if [[ -z "$latest_ver" || "null" == "$latest_ver" ]]; then
        echo "❌ could not retrieve the latest version of a runner"
        exit 2
      fi
    fi
    echo "✅ Startup script will install GitHub Actions v$runner_ver"
    if $arm ; then
      runner_download_cmds="curl -o actions-runner-linux-arm64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-arm64-${runner_ver}.tar.gz && \\
	  tar xzf ./actions-runner-linux-arm64-${runner_ver}.tar.gz && \\
	  ./bin/installdependencies.sh && \\
	  "
    else
      runner_download_cmds="curl -o actions-runner-linux-x64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-x64-${runner_ver}.tar.gz && \\
	  tar xzf ./actions-runner-linux-x64-${runner_ver}.tar.gz && \\
	  ./bin/installdependencies.sh && \\
	  "
    fi
  fi

  # Human-readable wording for the self-teardown messages baked into the startup script below.
  # vm_teardown_action is "stop" for pooled VMs (reuse_key set) and "delete" otherwise -- the
  # actual gcloud command already respects this (see shutdown.sh and the reaper line further
  # down), this is just so the log messages don't falsely claim "deleting" when a pooled VM is
  # actually just being stopped and preserved.
  teardown_verb=$([[ "${vm_teardown_action}" == "stop" ]] && echo "stopping" || echo "deleting")

  # The "/actions-runner/.runner already exists -> skip registration" guard below exists solely
  # for RESUMED pooled VMs (their prior registration is still valid). On a fresh create it must
  # not apply: a custom actions_preinstalled image baked from a once-registered VM can ship a
  # leftover .runner file, and honoring it would skip registration entirely -- the runner never
  # comes online and the readiness loop deletes the VM 5 minutes later. So fresh creates remove
  # any stale registration state first, making the guard always take its register branch.
  sanitize_cmds=""
  if [[ "${pool_action:-create}" != "start" ]]; then
    sanitize_cmds="rm -f /actions-runner/.runner /actions-runner/.credentials /actions-runner/.credentials_rsaparams && \\
	"
  fi

  # Preemption watcher: a tiny daemon (launched below like the reaper) that long-polls the
  # metadata server's instance/preempted endpoint. GCE flips it to TRUE at the very START of the
  # preemption sequence, so the watcher reacts with the network fully up and the whole ~30s
  # window ahead of it -- unlike the shutdown-script, which races systemd's parallel teardown
  # and empirically loses (the job then hangs ~10 minutes until GitHub's lost-communication
  # timeout). On the notice it: (1) cancels the active workflow run via the GitHub API --
  # deterministic, server-side, fails the job within seconds for BOTH ephemeral and pooled
  # runners; (2) stops the runner service as a fallback signal; (3) on delete-mode VMs only,
  # deregisters the runner (reading its agentId from the .runner file written at registration).
  # Pooled persistent VMs never deregister -- their registration must survive to reconnect on
  # resume. The run id to cancel comes from /actions-runner/.current-run-id, which the
  # JOB_STARTED hook refreshes on every job (a pooled VM serves many runs; the create-time run
  # id would go stale), falling back to the run id baked at create/resume time.
  #
  # SECURITY NOTE: this bakes the action's PAT (the token input) into the VM's startup-script
  # metadata, readable by any process on the VM -- the same trust domain that already runs
  # arbitrary workflow code. Only done for preemptible VMs (a non-preemptible VM can never be
  # preempted, so it gets no token). Callers should prefer a PAT they can rotate easily.
  watcher_dereg_cmds=""
  if [[ "${vm_teardown_action}" == "delete" ]]; then
    watcher_dereg_cmds="agent_id=\$(grep -o '\"agentId\" *: *[0-9]*' /actions-runner/.runner 2>/dev/null | tr -cd '0-9')
	if [ -n \"\${agent_id}\" ]; then
	  echo \"Deregistering runner id \${agent_id} from GitHub ...\"
	  curl -S -s -X DELETE -H \"authorization: Bearer ${token}\" \"https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runners/\${agent_id}\" || true
	fi"
  fi

  watcher_setup=""
  if [[ "${preemptible}" == "true" ]]; then
    watcher_setup="
	cat <<-'WEOF' > /usr/bin/gce_preemption_watcher.sh
	#!/bin/sh
	# Long-poll until GCE announces preemption (TRUE at the start of the ~30s notice window).
	while :; do
	  p=\$(curl -S -s -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/preempted?wait_for_change=true&timeout_sec=300' || true)
	  [ \"\${p}\" = \"TRUE\" ] && break
	  sleep 1
	done
	echo \"Preemption notice received for ${VM_ID}; failing the active run fast.\"
	run_id=\$(cat /actions-runner/.current-run-id 2>/dev/null)
	[ -n \"\${run_id}\" ] || run_id=\"${GITHUB_RUN_ID}\"
	echo \"Cancelling workflow run \${run_id} ...\"
	curl -S -s -X POST -H \"authorization: Bearer ${token}\" \"https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/\${run_id}/cancel\" || true
	# Fallback signal: a gracefully-stopped runner reports a shutdown to GitHub if it can.
	timeout 10 systemctl stop 'actions.runner.*' || true
	${watcher_dereg_cmds}
	WEOF
	chmod +x /usr/bin/gce_preemption_watcher.sh
	nohup /usr/bin/gce_preemption_watcher.sh >> /var/log/gce-preemption-watcher.log 2>&1 &
	"
  fi

  # NOTE for every heredoc below: the delimiter is QUOTED ('EOF') on purpose. These heredocs
  # execute on the VM (level 2), and an unquoted delimiter would make the VM's shell expand any
  # dollar-expression at file-WRITE time -- e.g. the sleep argument and machine_sa lookup in
  # shutdown.sh would be replaced with empty strings as the file is written, deploying "sleep"
  # with no argument and "gcloud --account=" with no account (which errors, so the VM never
  # tears itself down). The backslash escapes on those same expressions protect level 1 (this
  # action.sh string); the quoted delimiter protects level 2; the values expand at RUN time on
  # the VM, as intended.
  # The actual teardown command baked into shutdown.sh:
  #
  # stop-mode (pooled persistent VM): a plain guest-initiated poweroff. A VM that shuts itself
  # down from inside lands in TERMINATED exactly like an API `compute instances stop` -- disk
  # intact, resumable later -- but requires NO compute IAM permissions at all (the API call
  # needs compute.instances.stop on the machine SA, which default compute SAs often lack).
  #
  # delete-mode (ephemeral): deletion is only possible through the API, so gcloud it is. The
  # explicit --account matters: a job step may have run gcloud auth activate-service-account
  # for its own purposes, which persists as gcloud's active identity for the rest of the VM's
  # life -- force the VM's own attached SA rather than inheriting whatever identity is active.
  # If the delete is denied anyway (machine SA lacks compute.instances.delete), fall back to
  # poweroff: a TERMINATED leftover costing only its disk beats a RUNNING zombie burning CPU.
  if [[ "${vm_teardown_action}" == "stop" ]]; then
    teardown_cmds="systemctl poweroff"
  else
    teardown_cmds="machine_sa=\$(curl -S -s -X GET http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email -H 'Metadata-Flavor: Google')
	gcloud --account=\${machine_sa} compute instances delete $VM_ID --zone=$machine_zone --quiet || { echo \"self-delete failed (missing compute.instances.delete on \${machine_sa}?); powering off instead.\"; systemctl poweroff; }"
  fi

  startup_script="
	# Create a systemd service in charge of shutting down the machine once the workflow has finished
	cat <<-'EOF' > /etc/systemd/system/shutdown.sh
	#!/bin/sh
	sleep \${1}
	${teardown_cmds}
	EOF

	cat <<-'EOF' > /etc/systemd/system/shutdown\@.service
	[Unit]
	Description=Shutdown service in %i Seconds
	[Service]
	ExecStart=/etc/systemd/system/shutdown.sh %i
	[Install]
	WantedBy=multi-user.target
	EOF

	chmod +x /etc/systemd/system/shutdown.sh
	systemctl daemon-reload

	# Recorded so a later, separate \`command: stop\` invocation (which runs as its own action.sh
	# process on the VM, without vm_teardown_action in scope) can report the real teardown action
	# too -- see stop_vm.
	echo "${vm_teardown_action}" > /etc/gce-github-runner-teardown-action

	cat <<-'EOF' > /usr/bin/gce_runner_shutdown.sh
	#!/bin/sh
	echo \"✅ Self ${teardown_verb} $VM_ID in ${machine_zone} in ${shutdown_timeout} seconds ...\"
	# We tear down the machine by starting the systemd service that was registered by the startup script
	systemctl start shutdown@${shutdown_timeout}.service
	EOF

	cat <<-'EOF' > /usr/bin/gce_cancel_shutdown.sh
	#!/bin/sh
	echo \"✅ Cancelling scheduled teardown of $VM_ID in ${machine_zone}!\"
	# Stop the shutdown script
	systemctl stop shutdown@${shutdown_timeout}.service
	# Record the run id of the job that just started, so the preemption watcher cancels the run
	# actually using this VM -- a pooled VM serves many runs, and the run id baked at
	# create/resume time goes stale as soon as a later run's job lands here. (JOB_STARTED hooks
	# run with the job's environment, so GITHUB_RUN_ID is the current run's id.) The if-form
	# (not [ ] && ...) matters: a bare && chain as the script's last line would exit nonzero when
	# the variable is empty, and a failing JOB_STARTED hook fails the job itself.
	if [ -n \"\${GITHUB_RUN_ID}\" ]; then
	  echo \"\${GITHUB_RUN_ID}\" > /actions-runner/.current-run-id
	fi
	EOF

	# See: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job
	echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/bin/gce_runner_shutdown.sh" >.env
  echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/bin/gce_cancel_shutdown.sh" >>.env
	# Seed with the run id known at create/resume time; the JOB_STARTED hook above refreshes it
	# per job so the preemption watcher always cancels the run actually using this VM.
	echo "${GITHUB_RUN_ID}" > /actions-runner/.current-run-id
	${watcher_setup}
	gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=0 && \\
	${sanitize_cmds}if [ ! -f /actions-runner/.runner ]; then
	  ${runner_download_cmds}RUNNER_ALLOW_RUNASROOT=1 ./config.sh --url https://github.com/${GITHUB_REPOSITORY} --token ${RUNNER_TOKEN} --labels ${VM_ID} --unattended --replace ${ephemeral_flag} --disableupdate && \\
	  ./svc.sh install
	else
	  echo \"✅ /actions-runner/.runner already present; skipping download/install/registration (resumed pooled VM).\"
	fi && \\
	./svc.sh start && \\
	gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=1
	# Safety-net teardown in case the shutdown-hook mechanism above fails to tear down the VM.
	# deletion_timeout is clamped to GCE's 24h preemptible limit and/or GitHub Actions' 3-day workflow limit.
	# Delegates to shutdown.sh (already written and chmod +x'd above) rather than duplicating its
	# gcloud call here, so there is exactly one place that knows how to tear this VM down --
	# including forcing the correct service account, see shutdown.sh's own comment.
	nohup sh -c \"sleep ${deletion_timeout} && /etc/systemd/system/shutdown.sh 0\" > /dev/null &
  "

  # GCE shutdown-script: a metadata key distinct from startup-script, invoked by the guest agent
  # best-effort on ANY VM shutdown -- including preemption (GCE docs: ACPI G2 soft-off, ~30s
  # window). This is the only in-guest mechanism that can react to preemption at all: the
  # job-completion runner hook and the in-guest reaper (both above) are themselves killed along
  # with the guest OS the instant the host reclaims the VM, so neither ever gets a chance to run.
  #
  # BOTH modes stop the runner service first: a gracefully-stopped runner tells GitHub it is
  # going away, so an in-flight job fails within seconds ("The runner has received a shutdown
  # signal") instead of hanging ~10 minutes until GitHub's lost-communication timeout. Stopping
  # the service does NOT deregister anything -- .runner/.credentials stay on disk, which is
  # exactly right: a pooled VM's registration must survive preemption (resume re-runs svc.sh
  # start and reconnects), and an ephemeral VM's orphaned registration is auto-purged by GitHub
  # after 1 day offline. The timeout guard keeps a wedged systemctl from eating the whole
  # preemption window.
  #
  # Only delete-mode VMs (plain ephemeral, or pooled+ephemeral) additionally self-delete via
  # shutdown.sh -- an in-guest backup to the server-side Spot termination action DELETE set at
  # create time (see preemptible_flag in start_vm), which also catches a delete-mode VM stopped
  # some way other than preemption (e.g. manually from the console). A pooled persistent VM's
  # script must NEVER touch the VM itself -- its disk is the whole point of pool mode.
  # This string is consumed directly by the guest agent (never re-written through a VM-side
  # heredoc), so level-1 backslash-escapes are the only quoting it needs.
  shutdown_script="#!/bin/sh
preempted=\$(curl -S -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/preempted)
echo \"shutdown-script: preempted=\${preempted}; stopping the runner service so any in-flight job fails fast.\"
timeout 10 systemctl stop 'actions.runner.*' || true
"
  if [[ "${vm_teardown_action}" == "delete" ]]; then
    shutdown_script+="/etc/systemd/system/shutdown.sh 0
"
  fi

  if $actions_preinstalled ; then
    echo "✅ Startup script won't install GitHub Actions (pre-installed)"
    startup_script="#!/bin/bash
    cd /actions-runner
    $startup_script"
  else
    startup_script="#!/bin/bash
    mkdir -p /actions-runner
    cd /actions-runner
    $startup_script"
  fi
}

function start_vm {
  echo "Starting GCE VM ..."
  if [[ -z "${service_account_key}" ]] || [[ -z "${project_id}" ]]; then
    echo "Won't authenticate gcloud. If you wish to authenticate gcloud provide both service_account_key and project_id."
  else
    echo "Will authenticate gcloud."
    gcloud_auth
  fi

  if [[ -n "${reuse_key}" ]]; then
    VM_ID="$(compute_pool_vm_name "${reuse_key}")"
    if [[ "${ephemeral}" == "true" ]]; then
      # A GitHub-side ephemeral runner registration self-deregisters after exactly one job and
      # can never be reused, no matter what happens to the VM -- so unlike a normal pooled VM,
      # stopping this one to resume later would provide no benefit, just ongoing disk cost for a
      # VM that can never do anything again. Always delete. reuse_key still gives it a
      # deterministic name (e.g. useful for firewall rules or log correlation), but every run
      # creates fresh: there's nothing to resume.
      echo "ℹ️ ephemeral=true with reuse_key: this VM is deleted (not stopped) after use -- an ephemeral runner registration can't be reused regardless of VM state."
      vm_teardown_action="delete"
    else
      vm_teardown_action="stop"
    fi
  else
    VM_ID="gce-gh-runner-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
    vm_teardown_action="delete"
  fi

  # zones_to_try: machine_zone first, then any machine_zones fallbacks, in order. Built once and
  # shared between the pooled-VM lookup below and the create fallback loop further down -- GCE
  # instance names are unique per-zone, not per-project, so a pooled VM that landed in a fallback
  # zone on a prior run is invisible to a lookup that only checks the static machine_zone. Missing
  # it there doesn't fail safely: it looks exactly like "doesn't exist yet" and leads straight to
  # creating a second, identically-named VM in another zone -- both then racing to register the
  # same GitHub runner label.
  zones_to_try=("${machine_zone}")
  while IFS= read -r csv_entry; do
    zones_to_try+=("${csv_entry}")
  done < <(split_csv "${machine_zones}")

  # types_to_try: machine_type first, then any machine_types fallbacks, in order. Shared by
  # create_fresh_vm (type-major search: each type is tried across ALL zones before degrading to
  # the next type -- zones within a region are near-interchangeable, while machine type actually
  # changes build performance/cost) and by the pooled resume rescue (in-place set-machine-type).
  types_to_try=("${machine_type}")
  while IFS= read -r csv_entry; do
    types_to_try+=("${csv_entry}")
  done < <(split_csv "${machine_types}")

  # Bounded wait until GCE stops returning the pooled VM at all (describe 404s). Used after
  # issuing/observing a delete, so an immediate re-create can't collide with the name while the
  # deletion is still completing server-side.
  function wait_pooled_vm_gone {
    local waited=0 gone_output gone_rc
    while (( waited < 120 )); do
      set +o errexit
      gone_output=$(gcloud compute instances describe "${VM_ID}" --zone="${machine_zone}" --format='value(status)' 2>&1)
      gone_rc=$?
      set -o errexit
      if [[ ${gone_rc} -ne 0 ]] && grep -qi 'was not found' <<< "${gone_output}"; then
        return 0
      fi
      sleep 5
      waited=$((waited + 5))
    done
    echo "⚠️ ${VM_ID} is still visible in ${machine_zone} after ${waited}s; a follow-up create may fail with alreadyExists." >&2
  }

  # Best-effort delete of the pooled VM, then wait for it to be fully gone. Tolerates the VM
  # already being deleted (or mid-deletion by someone else); any other delete error is reported
  # but not fatal -- the follow-up create fails loudly anyway if the VM truly still exists.
  function delete_pooled_vm_and_wait_gone {
    local del_output del_rc
    set +o errexit
    del_output=$(gcloud --quiet compute instances delete "${VM_ID}" --zone="${machine_zone}" 2>&1)
    del_rc=$?
    set -o errexit
    if [[ ${del_rc} -ne 0 ]] && ! grep -qi 'was not found' <<< "${del_output}"; then
      echo "⚠️ Deleting ${VM_ID} reported an error (continuing; the follow-up create will surface it if real):" >&2
      echo "${del_output}" >&2
    fi
    wait_pooled_vm_gone
  }

  pool_action="create"
  if [[ -n "${reuse_key}" ]]; then
    for candidate_zone in "${zones_to_try[@]}"; do
      set +o errexit
      describe_output=$(gcloud compute instances describe "${VM_ID}" --zone="${candidate_zone}" --format='value(status,machineType)' 2>&1)
      describe_rc=$?
      set -o errexit

      if [[ ${describe_rc} -eq 0 ]]; then
        machine_zone="${candidate_zone}"
        # Two tab-separated fields: status, machineType URL (basename is the type name). The
        # type feeds the machine_type output and lets the resume rescue skip re-trying the type
        # the VM already has. Tolerate a missing second field (old mocks/edge responses).
        read -r existing_status existing_machine_type_url <<< "${describe_output}"
        existing_machine_type="${existing_machine_type_url##*/}"
        existing_machine_type="${existing_machine_type:-unknown}"

        # A VM mid-deletion still describes as RUNNING for tens of seconds -- and its stale
        # gh_ready=1 label plus GitHub's lagging "online" runner status can pass every readiness
        # check below, handing the job to a VM that is actively vanishing (observed in the
        # wild: pooled VM manually deleted, immediately re-run, action declared it ready).
        # An in-flight delete OPERATION is visible from T+0 though, so check for one before
        # trusting the status. Best-effort: if the operations lookup itself fails (e.g. the
        # workflow SA lacks zoneOperations.list), fall through to the status-based decision.
        set +o errexit
        pending_delete=$(gcloud compute operations list --zones="${machine_zone}" \
          --filter="targetLink ~ /instances/${VM_ID}\$ AND operationType=delete AND NOT status=DONE" \
          --format='value(name)' 2>/dev/null | head -n1)
        set -o errexit
        if [[ -n "${pending_delete}" ]]; then
          echo "⚠️ Pooled VM ${VM_ID} in ${machine_zone} has an in-flight delete operation (${pending_delete}); waiting for it to finish, then creating fresh." >&2
          wait_pooled_vm_gone
          pool_action="create"
          break
        fi

        if [[ "${existing_status}" == "RUNNING" ]]; then
          echo "✅ Pooled VM ${VM_ID} already RUNNING in ${machine_zone}; reusing as-is."
          pool_action="reuse-running"
        else
          echo "Pooled VM ${VM_ID} exists in ${machine_zone} (state ${existing_status}); resuming (warm start)."
          pool_action="start"
        fi
        break
      elif ! grep -qi 'was not found' <<< "${describe_output}"; then
        # Anything other than a genuine 404 (permissions, transient API error, etc.) must not be
        # silently treated as "doesn't exist" -- that's exactly what leads to a confusing
        # "already exists" failure later from `create`, against a VM that was there all along.
        echo "❌ Could not determine whether pooled VM ${VM_ID} already exists in ${candidate_zone}:" >&2
        echo "${describe_output}" >&2
        exit 1
      fi
    done

    if [[ "${pool_action}" == "create" ]]; then
      echo "No existing pooled VM ${VM_ID} found in any candidate zone (${zones_to_try[*]}); will create it."
    fi
  fi

  function fetch_runner_registration_token {
    RUNNER_TOKEN=$(curl -S -s -XPOST \
        -H "authorization: Bearer ${token}" \
        https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runners/registration-token |\
        jq -r .token)
    echo "✅ Successfully got the GitHub Runner registration token"
  }

  if [[ "${pool_action}" == "create" || "${pool_action}" == "start" ]]; then
    # build_startup_script always interpolates ${RUNNER_TOKEN} while constructing the script text
    # (even though the resulting `config.sh --token ${RUNNER_TOKEN}` line only actually executes
    # on the VM if /actions-runner/.runner is missing) -- so it must be a valid, non-crashing
    # value under `nounset` on both the "create" and "start" (resume) paths, not just "create".
    # (The reuse-running path skips this; if its readiness poll later falls back to a fresh
    # create, that path fetches the token itself before calling create_fresh_vm.)
    fetch_runner_registration_token
  fi

  service_account_flag=$([[ -z "${runner_service_account}" ]] || echo "--service-account=${runner_service_account}")
  image_project_flag=$([[ -z "${image_project}" ]] || echo "--image-project=${image_project}")
  image_flag=$([[ -z "${image}" ]] || echo "--image=${image}")
  image_family_flag=$([[ -z "${image_family}" ]] || echo "--image-family=${image_family}")
  disk_size_flag=$([[ -z "${disk_size}" ]] || echo "--boot-disk-size=${disk_size}")
  boot_disk_type_flag=$([[ -z "${boot_disk_type}" ]] || echo "--boot-disk-type=${boot_disk_type}")
  # preemptible=true is implemented as Spot provisioning (same discount/preemption model as
  # legacy --preemptible, minus its 24h forced-stop cap) because Spot unlocks
  # --instance-termination-action: on preemption GCE ITSELF deletes a delete-mode VM (plain
  # ephemeral, or pooled+ephemeral) server-side -- no reliance on the guest winning its ~30s
  # best-effort shutdown window -- so a preempted ephemeral runner can never linger as a zombie
  # TERMINATED instance. Pooled persistent VMs keep stop-on-preemption (their disk must survive).
  if [[ "${preemptible}" == "true" ]]; then
    spot_termination_action=$([[ "${vm_teardown_action}" == "delete" ]] && echo "DELETE" || echo "STOP")
    preemptible_flag="--provisioning-model=SPOT --instance-termination-action=${spot_termination_action}"
  else
    preemptible_flag=""
  fi
  ephemeral_flag=$([[ "${ephemeral}" == "true" ]] && echo "--ephemeral" || echo "")
  no_external_address_flag=$([[ "${no_external_address}" == "true" ]] && echo "--no-address" || echo "")
  network_flag=$([[ ! -z "${network}"  ]] && echo "--network=${network}" || echo "")
  subnet_flag=$([[ ! -z "${subnet}"  ]] && echo "--subnet=${subnet}" || echo "")
  accelerator=$([[ ! -z "${accelerator}"  ]] && echo "--accelerator=${accelerator} --maintenance-policy=TERMINATE" || echo "")
  maintenance_policy_flag=$([[ -z "${maintenance_policy_terminate}"  ]] || echo "--maintenance-policy=TERMINATE" )

  # Clamp deletion_timeout to real-world ceilings: GitHub Actions workflow runs are capped at
  # 3 days in all cases. The tighter 24h ceiling for preemptible=true dates from legacy
  # preemptible VMs' hard 24h termination; Spot provisioning (what preemptible=true creates
  # now) has no such cap, but 24h remains a sane upper bound for a CI runner's safety net.
  deletion_timeout_max=259200
  if [[ "${preemptible}" == "true" ]]; then
    deletion_timeout_max=86400
  fi
  if (( deletion_timeout > deletion_timeout_max )); then
    echo "⚠️ deletion_timeout=${deletion_timeout}s exceeds the maximum allowed (${deletion_timeout_max}s). Clamping to ${deletion_timeout_max}s."
    deletion_timeout=${deletion_timeout_max}
  fi

  if [[ "${pool_action}" == "create" ]]; then
    echo "The new GCE VM will be ${VM_ID}"
  else
    echo "Reusing pooled GCE VM ${VM_ID} (${pool_action})"
  fi

  # GCE VM label values requirements:
  # - can contain only lowercase letters, numeric characters, underscores, and dashes
  # - have a maximum length of 63 characters
  # ref: https://cloud.google.com/compute/docs/labeling-resources#requirements
  #
  # Github's requirements:
  # - username/organization name
  #   - Max length: 39 characters
  #   - All characters must be either a hyphen (-) or alphanumeric
  # - repository name
  #   - Max length: 100 code points
  #   - All code points must be either a hyphen (-), an underscore (_), a period (.),
  #     or an ASCII alphanumeric code point
  # ref: https://github.com/dead-claudia/github-limits
  function truncate_to_label {
    local in="${1}"
    in="${in:0:63}"                              # ensure max length
    in="${in//./_}"                              # replace '.' with '_'
    in=$(tr '[:upper:]' '[:lower:]' <<< "${in}") # convert to lower
    echo -n "${in}"
  }

  # Creates a brand-new VM, walking the type x zone matrix on capacity stockouts
  # (ZONE_RESOURCE_POOL_EXHAUSTED): type-major order -- each machine type in $types_to_try is
  # tried across ALL zones in $zones_to_try before degrading to the next type. A combo is also
  # skipped when the type simply isn't offered in that zone ("machineTypes/... was not found");
  # any other error fails immediately with no further combos, so real misconfiguration stays
  # loud. Sets $machine_zone and $machine_type as side effects to whichever combo succeeded.
  # Called for a genuine first-time create, and as the fallback when a pooled VM can't be
  # resumed or rescued (see pool_action == "start" below).
  function create_fresh_vm {
    local gh_repo_owner gh_repo gh_run_id candidate_zone candidate_type create_output create_rc
    gh_repo_owner="$(truncate_to_label "${GITHUB_REPOSITORY_OWNER}")"
    gh_repo="$(truncate_to_label "${GITHUB_REPOSITORY##*/}")"
    gh_run_id="${GITHUB_RUN_ID}"

    create_succeeded="false"
    for candidate_type in "${types_to_try[@]}"; do
    machine_type="${candidate_type}"
    for candidate_zone in "${zones_to_try[@]}"; do
      machine_zone="${candidate_zone}"
      build_startup_script

      # One atomic --metadata argument carrying both scripts (the ^~~~^ custom-delimiter syntax
      # from `gcloud topic escaping` separates dict ITEMS, so a second key rides along in the
      # same flag). Setting shutdown-script in the create itself -- not a follow-up add-metadata
      # call -- means there is no window where the VM exists but its preemption handling
      # doesn't. Neither script may ever contain the literal sequence ~~~.
      metadata_arg="--metadata=^~~~^startup-script=${startup_script}~~~shutdown-script=${shutdown_script}"

      set +o errexit
      create_output=$(gcloud compute instances create ${VM_ID} \
        --zone=${machine_zone} \
        ${disk_size_flag} \
        ${boot_disk_type_flag} \
        --machine-type=${machine_type} \
        --scopes=${scopes} \
        ${service_account_flag} \
        ${image_project_flag} \
        ${image_flag} \
        ${image_family_flag} \
        ${preemptible_flag} \
        ${no_external_address_flag} \
        ${network_flag} \
        ${subnet_flag} \
        ${accelerator} \
        ${maintenance_policy_flag} \
        "${min_cpu_platform_flag}" \
        --labels=gh_ready=0,gh_repo_owner="${gh_repo_owner}",gh_repo="${gh_repo}",gh_run_id="${gh_run_id}" \
        "${metadata_arg}" 2>&1)
      create_rc=$?
      set -o errexit

      if [[ ${create_rc} -eq 0 ]]; then
        echo "${create_output}"
        create_succeeded="true"
        break 2
      elif grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources available' <<< "${create_output}"; then
        echo "⚠️ ${candidate_type} in ${candidate_zone} is out of capacity (stockout); trying the next type/zone combo if available." >&2
        echo "${create_output}" >&2
      elif grep -qi "machineTypes/${candidate_type}' was not found" <<< "${create_output}"; then
        echo "⚠️ ${candidate_type} is not offered in ${candidate_zone}; trying the next type/zone combo if available." >&2
        echo "${create_output}" >&2
      else
        echo "${create_output}" >&2
        exit 1
      fi
    done
    done

    if [[ "${create_succeeded}" != "true" ]]; then
      echo "❌ All machine type / zone combinations (types: ${types_to_try[*]}; zones: ${zones_to_try[*]}) are out of capacity or unavailable." >&2
      exit 1
    fi
  }

  if [[ "${pool_action}" == "create" || "${pool_action}" == "start" ]]; then
    if [[ "${pool_action}" == "create" ]]; then
      create_fresh_vm
    else
      # pool_action == start: resuming a stopped pooled VM in the zone its disk already lives in
      # (no zone fallback for a normal resume -- the disk is fixed to that zone). Reset gh_ready=0
      # first so the readiness poll below can't see a stale "1" left over from before this VM was
      # stopped.
      build_startup_script

      # Same rationale as create_fresh_vm's metadata_arg. Every resume overwrites BOTH scripts
      # with ones built for the current mode, which also self-heals a stale shutdown-script left
      # by this VM's previous life (e.g. once pooled+ephemeral with a self-DELETE script, now
      # resumed as a persistent pooled VM whose script must only stop the runner service).
      metadata_arg="--metadata=^~~~^startup-script=${startup_script}~~~shutdown-script=${shutdown_script}"

      set +o errexit
      start_output=$( (gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=0 && \
        gcloud compute instances add-metadata ${VM_ID} --zone=${machine_zone} "${metadata_arg}" && \
        gcloud compute instances start ${VM_ID} --zone=${machine_zone}) 2>&1)
      start_rc=$?
      set -o errexit

      if [[ ${start_rc} -eq 0 ]]; then
        echo "${start_output}"
        effective_machine_type="${existing_machine_type}"
      else
        # ANY resume failure ends in delete-and-recreate-fresh, not just stockout: unlike the
        # create path (where a failure usually means caller misconfiguration that must fail
        # loudly), a failed START of a VM that verifiably exists means THIS VM can't serve --
        # its zone is out of capacity, it's mid-deletion (a deleting VM still describes as
        # existing for a while), stuck in a transitional state, or otherwise wedged.
        #
        # But a STOCKOUT specifically gets one better option first: change the machine type IN
        # PLACE (set-machine-type is valid on a TERMINATED instance) and start again -- a
        # different type draws on a different capacity pool in the same zone, and unlike
        # delete-and-recreate it keeps the warm disk, which is the whole point of pool mode.
        # Rescue failures are soft (incompatible fallback type, or that pool is dry too):
        # just try the next candidate; delete+recreate remains the backstop, and genuine
        # misconfiguration still fails loudly inside create_fresh_vm.
        rescued="false"
        if grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources available' <<< "${start_output}"; then
          echo "⚠️ ${existing_machine_type} is out of capacity in ${machine_zone} to resume pooled VM ${VM_ID} (stockout); attempting in-place machine-type rescue before recreating." >&2
          echo "${start_output}" >&2
          for candidate_type in "${types_to_try[@]}"; do
            if [[ "${candidate_type}" == "${existing_machine_type}" ]]; then
              continue
            fi
            echo "Rescue attempt: switching ${VM_ID} to ${candidate_type} in place (warm disk preserved) ..."
            set +o errexit
            rescue_output=$( (gcloud compute instances set-machine-type ${VM_ID} --zone=${machine_zone} --machine-type=${candidate_type} && \
              gcloud compute instances start ${VM_ID} --zone=${machine_zone}) 2>&1)
            rescue_rc=$?
            set -o errexit
            if [[ ${rescue_rc} -eq 0 ]]; then
              echo "${rescue_output}"
              echo "✅ Rescued pooled VM ${VM_ID} in place as ${candidate_type} (warm start preserved)."
              effective_machine_type="${candidate_type}"
              rescued="true"
              break
            fi
            echo "⚠️ Rescue as ${candidate_type} failed (incompatible type, or its capacity pool is dry too); trying the next candidate if available." >&2
            echo "${rescue_output}" >&2
          done
        else
          echo "⚠️ Could not resume pooled VM ${VM_ID} in ${machine_zone} (mid-deletion, transitional state, or wedged); deleting it and creating fresh (pool warm-start lost for this run)." >&2
          echo "${start_output}" >&2
        fi

        if [[ "${rescued}" != "true" ]]; then
          delete_pooled_vm_and_wait_gone
          pool_action="create"
          create_fresh_vm
          effective_machine_type="${machine_type}"
        fi
      fi
    fi
    echo "label=${VM_ID}" >> $GITHUB_OUTPUT
    echo "zone=${machine_zone}" >> $GITHUB_OUTPUT
    echo "machine_type=${effective_machine_type:-${machine_type}}" >> $GITHUB_OUTPUT
  else
    # pool_action == reuse-running: VM is already up and gh_ready should already be 1.
    echo "label=${VM_ID}" >> $GITHUB_OUTPUT
    echo "zone=${machine_zone}" >> $GITHUB_OUTPUT
    echo "machine_type=${existing_machine_type}" >> $GITHUB_OUTPUT
  fi

  safety_off
  recreated_once="false"
  while :; do
  runner_online="false"
  gh_api_failures=0
  i=0
  while (( i++ < 60 )); do
    GH_READY=$(gcloud compute instances describe ${VM_ID} --zone=${machine_zone} --format='json(labels)' | jq -r .labels.gh_ready)
    if [[ $GH_READY == 1 ]]; then
      # The VM-side script finishing (gh_ready=1) only proves our shell commands ran -- it says
      # nothing about whether the runner process actually connected. Confirm with GitHub itself
      # before declaring success, so a runner stuck with stale/invalid local credentials (e.g. a
      # resumed pooled VM whose registration was removed on GitHub's side while it sat stopped)
      # gets caught here instead of silently sitting there never receiving jobs.
      lookup="$(find_github_runner)"
      IFS='|' read -r gh_api_ok _ gh_status <<< "${lookup}"
      if [[ "${gh_status}" == "online" ]]; then
        runner_online="true"
        break
      fi

      if [[ "${gh_api_ok}" == "false" ]]; then
        # The lookup itself failed (GitHub API error/outage/rate-limit) -- this is not evidence
        # the runner is broken, just that we can't currently confirm it either way. Don't let a
        # run of these alone burn the whole 5-minute budget and delete an otherwise-healthy
        # (gh_ready=1) VM over what's most likely transient and unrelated to this runner.
        gh_api_failures=$((gh_api_failures + 1))
        echo "${VM_ID} booted (gh_ready=1) but the GitHub API lookup itself failed (${gh_api_failures} consecutive failure(s)); waiting 5 secs ..."
        if (( gh_api_failures >= 6 )); then
          echo "⚠️ Could not reach the GitHub API to confirm online status after ~30s of repeated failures; trusting gh_ready=1 and proceeding." >&2
          runner_online="true"
          break
        fi
      else
        # A successful lookup that found the runner missing/offline IS real signal (e.g. stale
        # credentials on a resumed pooled VM) -- reset the failure streak and keep waiting/
        # counting against the real timeout below instead of the API-failure fast path above.
        gh_api_failures=0
        echo "${VM_ID} booted (gh_ready=1) but GitHub reports it as '${gh_status:-not found yet}'; waiting 5 secs ..."
      fi
    else
      echo "${VM_ID} not ready yet, waiting 5 secs ..."
    fi
    sleep 5
  done
  if [[ "${runner_online}" == "true" ]]; then
    echo "✅ ${VM_ID} ready and online on GitHub ..."
    break
  fi

  if [[ "${pool_action}" != "create" && "${recreated_once}" == "false" ]]; then
    # A REUSED pooled VM (resumed or reused-running) that never came online is presumed stale,
    # wedged, or caught mid-deletion -- the reuse decision was made from a snapshot that may
    # have lied (see the in-flight-delete check at lookup time). A fresh create is a genuinely
    # different attempt, so make it once instead of failing the whole run. A VM we CREATED this
    # run failing to come online is a different story (likely image/config, retrying wastes
    # 5 more minutes) and still fails below.
    echo "⚠️ Reused pooled VM ${VM_ID} never came online; deleting it and creating a fresh replacement (one retry) ..." >&2
    recreated_once="true"
    safety_on
    # The reuse-running path never fetched a registration token (an already-running VM doesn't
    # need one) -- but the fresh create below does: build_startup_script interpolates
    # ${RUNNER_TOKEN}, which would crash under nounset if left unset.
    if [[ -z "${RUNNER_TOKEN:-}" ]]; then
      fetch_runner_registration_token
    fi
    delete_pooled_vm_and_wait_gone
    pool_action="create"
    create_fresh_vm
    # Re-emit outputs: the label (VM name) is deterministic and unchanged, but type/zone
    # fallback in create_fresh_vm may have landed the replacement on a different combo. Last
    # write wins in GITHUB_OUTPUT.
    echo "label=${VM_ID}" >> $GITHUB_OUTPUT
    echo "zone=${machine_zone}" >> $GITHUB_OUTPUT
    echo "machine_type=${machine_type}" >> $GITHUB_OUTPUT
    safety_off
    continue
  fi

  # Deliberately always deletes here, even for a pooled VM (vm_teardown_action would say
  # "stop") -- a VM that never came online is presumed to have some form of corrupted state
  # (bad disk, broken registration, etc.), so we discard it rather than leave it stopped to
  # fail the exact same way on every future resume.
  echo "Waited 5 minutes for ${VM_ID} to come online, without luck, deleting ${VM_ID} ..."
  gcloud --quiet compute instances delete ${VM_ID} --zone=${machine_zone}
  exit 1
  done
}

function stop_vm {
  # NOTE: this function runs on the GCE VM
  echo "Stopping GCE VM ..."
  # NOTE: it would be nice to gracefully shut down the runner, but we actually don't need
  #       to do that. VM shutdown will disconnect the runner, and GH will unregister it
  #       in 30 days
  # TODO: RUNNER_ALLOW_RUNASROOT=1 /actions-runner/config.sh remove --token $TOKEN
  NAME=$(curl -S -s -X GET http://metadata.google.internal/computeMetadata/v1/instance/name -H 'Metadata-Flavor: Google')
  ZONE=$(curl -S -s -X GET http://metadata.google.internal/computeMetadata/v1/instance/zone -H 'Metadata-Flavor: Google')
  # This runs as its own action.sh process, separate from the one that built the startup script,
  # so it has no direct access to vm_teardown_action -- read the marker file build_startup_script
  # left on disk instead. Default to "delete" (today's pre-pool-mode behavior) if it's missing --
  # e.g. a VM created by an older version of this action, before this marker file existed.
  teardown_action=$(cat /etc/gce-github-runner-teardown-action 2>/dev/null || echo "delete")
  teardown_verb=$([[ "${teardown_action}" == "stop" ]] && echo "stopping" || echo "deleting")
  echo "✅ Self ${teardown_verb} $NAME in $ZONE in ${1} seconds ..."
  # We tear down the machine by starting the systemd service that was registered by the startup script
  systemctl start shutdown@${1}.service
}

# Finds the GitHub Actions runner registered with VM_ID's custom label (set via
# `config.sh --labels ${VM_ID}` at registration time; matching on that label is robust regardless
# of the runner's hostname-derived name). Always echoes exactly one pipe-delimited line
# "OK|ID|STATUS": OK is "true" if the API lookup itself succeeded (even if no runner matched, in
# which case ID/STATUS are empty) or "false" if the API call itself failed (HTTP error), in which
# case ID/STATUS are meaningless -- callers must treat that as "couldn't check", not "confirmed
# absent". (This can't be surfaced via a plain global variable instead: every caller invokes this
# via command substitution, e.g. `x=$(find_github_runner)`, which runs the function in a subshell
# -- any variable it sets there is invisible to the caller once the subshell exits. The result
# must travel back entirely through stdout.)
function find_github_runner {
  local page=1 result="" runners_page runners_count http_status list_response

  while [[ -z "${result}" && ${page} -le 10 ]]; do
    list_response=$(curl -S -s -w '\n%{http_code}' -H "authorization: Bearer ${token}" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runners?per_page=100&page=${page}")
    http_status="${list_response##*$'\n'}"
    runners_page="${list_response%$'\n'*}"

    if [[ "${http_status}" != "200" ]]; then
      echo "⚠️ Could not list GitHub runners (HTTP ${http_status})." >&2
      echo "${runners_page}" >&2
      echo "false||"
      return
    fi

    result=$(jq -r --arg vm "${VM_ID}" '.runners[]? | select(.labels[]?.name == $vm) | "\(.id)|\(.status)"' <<< "${runners_page}" | head -n1)
    runners_count=$(jq -r '.runners | length' <<< "${runners_page}")
    if [[ "${runners_count}" -lt 100 ]]; then
      break
    fi
    page=$((page + 1))
  done

  echo "true|${result}"
}

# Non-ephemeral runners (pool mode always is) don't self-deregister on VM shutdown -- without
# this they just sit "Offline" in the GitHub UI for up to 30 days until GitHub's own stale-runner
# cleanup. Best-effort: run unconditionally, even if the GCE VM itself is already gone, so this
# also cleans up an orphaned GitHub registration left over from a VM deleted some other way.
function deregister_github_runner {
  echo "Looking up GitHub runner registration for ${VM_ID} ..."
  local lookup gh_api_ok runner_id

  lookup="$(find_github_runner)"
  IFS='|' read -r gh_api_ok runner_id _ <<< "${lookup}"

  if [[ "${gh_api_ok}" == "false" ]]; then
    # The lookup call itself failed (find_github_runner already logged why) -- this is not the
    # same as confirming no registration exists, so don't report a false "nothing to deregister".
    echo "⚠️ Could not confirm whether a GitHub runner registration exists for ${VM_ID} -- skipping deregistration." >&2
    return
  fi

  if [[ -z "${runner_id}" ]]; then
    echo "ℹ️ No GitHub runner registration found for ${VM_ID} — nothing to deregister."
    return
  fi

  echo "Deregistering GitHub runner ${VM_ID} (id ${runner_id}) ..."
  http_code=$(curl -S -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H "authorization: Bearer ${token}" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runners/${runner_id}")
  if [[ "${http_code}" == "204" ]]; then
    echo "✅ Deregistered ${VM_ID} from GitHub."
  else
    echo "⚠️ Failed to deregister ${VM_ID} from GitHub (HTTP ${http_code})." >&2
  fi
}

function delete_vm {
  # NOTE: this function runs off the GCE VM (e.g. from a PR-closed cleanup workflow)
  echo "Deleting pooled GCE VM ..."
  if [[ -z "${reuse_key}" ]]; then
    echo "❌ command=delete requires reuse_key to be set." >&2
    exit 1
  fi

  if [[ -z "${service_account_key}" ]] || [[ -z "${project_id}" ]]; then
    echo "Won't authenticate gcloud. If you wish to authenticate gcloud provide both service_account_key and project_id."
  else
    echo "Will authenticate gcloud."
    gcloud_auth
  fi

  VM_ID="$(compute_pool_vm_name "${reuse_key}")"
  echo "Target pooled VM: ${VM_ID}"

  deregister_github_runner

  # Search every candidate zone (machine_zone plus any machine_zones fallbacks), not just the
  # static machine_zone -- a pooled VM created via zone fallback may be sitting in any of them,
  # and GCE instance names are unique per-zone, not per-project, so checking only machine_zone
  # risks a false "doesn't exist" and leaving the real VM (and its cost) running indefinitely.
  zones_to_try=("${machine_zone}")
  while IFS= read -r csv_entry; do
    zones_to_try+=("${csv_entry}")
  done < <(split_csv "${machine_zones}")

  found_zone=""
  for candidate_zone in "${zones_to_try[@]}"; do
    set +o errexit
    describe_output=$(gcloud compute instances describe "${VM_ID}" --zone="${candidate_zone}" 2>&1)
    exists_rc=$?
    set -o errexit

    if [[ ${exists_rc} -eq 0 ]]; then
      found_zone="${candidate_zone}"
      break
    elif ! grep -qi 'was not found' <<< "${describe_output}"; then
      # Anything other than a genuine 404 must not be silently treated as "already gone" -- that
      # would leave a real VM (and its cost) behind with no indication cleanup actually failed.
      echo "❌ Could not determine whether ${VM_ID} exists in ${candidate_zone}:" >&2
      echo "${describe_output}" >&2
      exit 1
    fi
  done

  if [[ -z "${found_zone}" ]]; then
    echo "ℹ️ ${VM_ID} does not exist in any candidate zone (${zones_to_try[*]}) -- already deleted, or CI never ran on this reuse_key -- nothing to do."
    return
  fi

  gcloud --quiet compute instances delete "${VM_ID}" --zone="${found_zone}"
  echo "✅ Deleted ${VM_ID} from ${found_zone}."
}

safety_on
case "$command" in
  start)
    start_vm
    ;;
  stop)
    stop_vm ${finish_timeout}
    ;;
  delete)
    delete_vm
    ;;
  *)
    echo "Invalid command: \`${command}\`, valid values: start|stop|delete" >&2
    usage
    exit 1
    ;;
esac
