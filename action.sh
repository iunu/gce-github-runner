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
# RUNNER_TOKEN, ephemeral_flag, actions_preinstalled, runner_ver, arm from the enclosing scope.
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

  startup_script="
	# Create a systemd service in charge of shutting down the machine once the workflow has finished
	cat <<-EOF > /etc/systemd/system/shutdown.sh
	#!/bin/sh
	sleep \${1}
	gcloud compute instances ${vm_teardown_action} $VM_ID --zone=$machine_zone --quiet
	EOF

	cat <<-EOF > /etc/systemd/system/shutdown\@.service
	[Unit]
	Description=Shutdown service in %i Seconds
	[Service]
	ExecStart=/etc/systemd/system/shutdown.sh %i
	[Install]
	WantedBy=multi-user.target
	EOF

	chmod +x /etc/systemd/system/shutdown.sh
	systemctl daemon-reload

	cat <<-EOF > /usr/bin/gce_runner_shutdown.sh
	#!/bin/sh
	echo \"✅ Self deleting $VM_ID in ${machine_zone} in ${shutdown_timeout} seconds ...\"
	# We tear down the machine by starting the systemd service that was registered by the startup script
	systemctl start shutdown@${shutdown_timeout}.service
	EOF

	cat <<-EOF > /usr/bin/gce_cancel_shutdown.sh
	#!/bin/sh
	echo \"✅ Cancelling deletion of $VM_ID in ${machine_zone}!\"
	# Stop the shutdown script
	systemctl stop shutdown@${shutdown_timeout}.service
	EOF

	# See: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job
	echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/bin/gce_runner_shutdown.sh" >.env
  echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/bin/gce_cancel_shutdown.sh" >.env
	gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=0 && \\
	if [ ! -f /actions-runner/.runner ]; then
	  ${runner_download_cmds}RUNNER_ALLOW_RUNASROOT=1 ./config.sh --url https://github.com/${GITHUB_REPOSITORY} --token ${RUNNER_TOKEN} --labels ${VM_ID} --unattended --replace ${ephemeral_flag} --disableupdate && \\
	  ./svc.sh install
	else
	  echo \"✅ /actions-runner/.runner already present; skipping download/install/registration (resumed pooled VM).\"
	fi && \\
	./svc.sh start && \\
	gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=1
	# Safety-net teardown in case the shutdown-hook mechanism above fails to tear down the VM.
	# deletion_timeout is clamped to GCE's 24h preemptible limit and/or GitHub Actions' 3-day workflow limit.
	nohup sh -c \"sleep ${deletion_timeout} && gcloud --quiet compute instances ${vm_teardown_action} ${VM_ID} --zone=${machine_zone}\" > /dev/null &
  "

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
    vm_teardown_action="stop"
    if [[ "${ephemeral}" == "true" ]]; then
      echo "⚠️ ephemeral=true is incompatible with reuse_key (ephemeral runners self-deregister after one job). Overriding to a persistent runner."
      ephemeral="false"
    fi
  else
    VM_ID="gce-gh-runner-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
    vm_teardown_action="delete"
  fi

  pool_action="create"
  if [[ -n "${reuse_key}" ]]; then
    set +o errexit
    describe_output=$(gcloud compute instances describe "${VM_ID}" --zone=${machine_zone} --format='value(status)' 2>&1)
    describe_rc=$?
    set -o errexit

    if [[ ${describe_rc} -eq 0 ]]; then
      existing_status="${describe_output}"
      if [[ "${existing_status}" == "RUNNING" ]]; then
        echo "✅ Pooled VM ${VM_ID} already RUNNING; reusing as-is."
        pool_action="reuse-running"
      else
        echo "Pooled VM ${VM_ID} exists (state ${existing_status}); resuming (warm start)."
        pool_action="start"
      fi
    elif grep -qi 'was not found' <<< "${describe_output}"; then
      echo "No existing pooled VM ${VM_ID} found; will create it."
      pool_action="create"
    else
      # Anything other than a genuine 404 (permissions, transient API error, etc.) must not be
      # silently treated as "doesn't exist" -- that's exactly what leads to a confusing
      # "already exists" failure later from `create`, against a VM that was there all along.
      echo "❌ Could not determine whether pooled VM ${VM_ID} already exists:" >&2
      echo "${describe_output}" >&2
      exit 1
    fi
  fi

  if [[ "${pool_action}" == "create" || "${pool_action}" == "start" ]]; then
    # build_startup_script always interpolates ${RUNNER_TOKEN} while constructing the script text
    # (even though the resulting `config.sh --token ${RUNNER_TOKEN}` line only actually executes
    # on the VM if /actions-runner/.runner is missing) -- so it must be a valid, non-crashing
    # value under `nounset` on both the "create" and "start" (resume) paths, not just "create".
    RUNNER_TOKEN=$(curl -S -s -XPOST \
        -H "authorization: Bearer ${token}" \
        https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runners/registration-token |\
        jq -r .token)
    echo "✅ Successfully got the GitHub Runner registration token"
  fi

  service_account_flag=$([[ -z "${runner_service_account}" ]] || echo "--service-account=${runner_service_account}")
  image_project_flag=$([[ -z "${image_project}" ]] || echo "--image-project=${image_project}")
  image_flag=$([[ -z "${image}" ]] || echo "--image=${image}")
  image_family_flag=$([[ -z "${image_family}" ]] || echo "--image-family=${image_family}")
  disk_size_flag=$([[ -z "${disk_size}" ]] || echo "--boot-disk-size=${disk_size}")
  boot_disk_type_flag=$([[ -z "${boot_disk_type}" ]] || echo "--boot-disk-type=${boot_disk_type}")
  preemptible_flag=$([[ "${preemptible}" == "true" ]] && echo "--preemptible" || echo "")
  ephemeral_flag=$([[ "${ephemeral}" == "true" ]] && echo "--ephemeral" || echo "")
  no_external_address_flag=$([[ "${no_external_address}" == "true" ]] && echo "--no-address" || echo "")
  network_flag=$([[ ! -z "${network}"  ]] && echo "--network=${network}" || echo "")
  subnet_flag=$([[ ! -z "${subnet}"  ]] && echo "--subnet=${subnet}" || echo "")
  accelerator=$([[ ! -z "${accelerator}"  ]] && echo "--accelerator=${accelerator} --maintenance-policy=TERMINATE" || echo "")
  maintenance_policy_flag=$([[ -z "${maintenance_policy_terminate}"  ]] || echo "--maintenance-policy=TERMINATE" )

  # Clamp deletion_timeout to real-world ceilings: GCE preemptible VMs are hard-terminated
  # by Google after 24h regardless of anything else, and GitHub Actions workflow runs are
  # capped at 3 days in all cases.
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

  if [[ "${pool_action}" == "create" || "${pool_action}" == "start" ]]; then
    if [[ "${pool_action}" == "create" ]]; then
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
      gh_repo_owner="$(truncate_to_label "${GITHUB_REPOSITORY_OWNER}")"
      gh_repo="$(truncate_to_label "${GITHUB_REPOSITORY##*/}")"
      gh_run_id="${GITHUB_RUN_ID}"

      # Zone fallback: try machine_zone first, then any machine_zones fallbacks in order, on a
      # capacity stockout (ZONE_RESOURCE_POOL_EXHAUSTED). Non-stockout errors fail immediately.
      zones_to_try=("${machine_zone}")
      if [[ -n "${machine_zones}" ]]; then
        IFS=',' read -ra fallback_zone_list <<< "${machine_zones}"
        zones_to_try+=("${fallback_zone_list[@]}")
      fi

      create_succeeded="false"
      for candidate_zone in "${zones_to_try[@]}"; do
        machine_zone="${candidate_zone}"
        build_startup_script

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
          --metadata=startup-script="$startup_script" 2>&1)
        create_rc=$?
        set -o errexit

        if [[ ${create_rc} -eq 0 ]]; then
          echo "${create_output}"
          create_succeeded="true"
          break
        elif grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources available' <<< "${create_output}"; then
          echo "⚠️ Zone ${candidate_zone} appears to be out of capacity (stockout); trying next zone if available." >&2
          echo "${create_output}" >&2
        else
          echo "${create_output}" >&2
          exit 1
        fi
      done

      if [[ "${create_succeeded}" != "true" ]]; then
        echo "❌ All candidate zones (${zones_to_try[*]}) are out of capacity." >&2
        exit 1
      fi
      echo "label=${VM_ID}" >> $GITHUB_OUTPUT
      echo "zone=${machine_zone}" >> $GITHUB_OUTPUT
    else
      # pool_action == start: resuming a stopped pooled VM, single pinned machine_zone (no zone
      # fallback -- its disk is fixed to whatever zone it was originally created in). Reset
      # gh_ready=0 first so the readiness poll below can't see a stale "1" left over from before
      # this VM was stopped.
      build_startup_script
      gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=0 && \
      gcloud compute instances add-metadata ${VM_ID} --zone=${machine_zone} --metadata=startup-script="$startup_script" && \
      gcloud compute instances start ${VM_ID} --zone=${machine_zone} \
      && echo "label=${VM_ID}" >> $GITHUB_OUTPUT
      echo "zone=${machine_zone}" >> $GITHUB_OUTPUT
    fi
  else
    # pool_action == reuse-running: VM is already up and gh_ready should already be 1.
    echo "label=${VM_ID}" >> $GITHUB_OUTPUT
    echo "zone=${machine_zone}" >> $GITHUB_OUTPUT
  fi

  safety_off
  runner_online="false"
  while (( i++ < 60 )); do
    GH_READY=$(gcloud compute instances describe ${VM_ID} --zone=${machine_zone} --format='json(labels)' | jq -r .labels.gh_ready)
    if [[ $GH_READY == 1 ]]; then
      # The VM-side script finishing (gh_ready=1) only proves our shell commands ran -- it says
      # nothing about whether the runner process actually connected. Confirm with GitHub itself
      # before declaring success, so a runner stuck with stale/invalid local credentials (e.g. a
      # resumed pooled VM whose registration was removed on GitHub's side while it sat stopped)
      # gets caught here instead of silently sitting there never receiving jobs.
      lookup="$(find_github_runner)"
      gh_status="${lookup#* }"
      if [[ "${gh_status}" == "online" ]]; then
        runner_online="true"
        break
      fi
      echo "${VM_ID} booted (gh_ready=1) but GitHub reports it as '${gh_status:-not found yet}'; waiting 5 secs ..."
    else
      echo "${VM_ID} not ready yet, waiting 5 secs ..."
    fi
    sleep 5
  done
  if [[ "${runner_online}" == "true" ]]; then
    echo "✅ ${VM_ID} ready and online on GitHub ..."
  else
    echo "Waited 5 minutes for ${VM_ID} to come online, without luck, deleting ${VM_ID} ..."
    gcloud --quiet compute instances delete ${VM_ID} --zone=${machine_zone}
    exit 1
  fi
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
  echo "✅ Self deleting $NAME in $ZONE in ${1} seconds ..."
  # We tear down the machine by starting the systemd service that was registered by the startup script
  systemctl start shutdown@${1}.service
}

# Finds the GitHub Actions runner registered with VM_ID's custom label (set via
# `config.sh --labels ${VM_ID}` at registration time; matching on that label is robust regardless
# of the runner's hostname-derived name). Echoes "<id> <status>" on success (status is "online" or
# "offline"); echoes nothing if not found, or if the API call itself failed (a warning is printed
# to stderr in that case -- callers must treat empty output as "unknown", not "confirmed absent").
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
      return
    fi

    result=$(jq -r --arg vm "${VM_ID}" '.runners[]? | select(.labels[]?.name == $vm) | "\(.id) \(.status)"' <<< "${runners_page}" | head -n1)
    runners_count=$(jq -r '.runners | length' <<< "${runners_page}")
    if [[ "${runners_count}" -lt 100 ]]; then
      break
    fi
    page=$((page + 1))
  done

  echo "${result}"
}

# Non-ephemeral runners (pool mode always is) don't self-deregister on VM shutdown -- without
# this they just sit "Offline" in the GitHub UI for up to 30 days until GitHub's own stale-runner
# cleanup. Best-effort: run unconditionally, even if the GCE VM itself is already gone, so this
# also cleans up an orphaned GitHub registration left over from a VM deleted some other way.
function deregister_github_runner {
  echo "Looking up GitHub runner registration for ${VM_ID} ..."
  local lookup runner_id

  lookup="$(find_github_runner)"
  runner_id="${lookup%% *}"

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

  set +o errexit
  describe_output=$(gcloud compute instances describe "${VM_ID}" --zone=${machine_zone} 2>&1)
  exists_rc=$?
  set -o errexit

  if [[ ${exists_rc} -ne 0 ]]; then
    if grep -qi 'was not found' <<< "${describe_output}"; then
      echo "ℹ️ ${VM_ID} does not exist (already deleted, or CI never ran on this reuse_key) — nothing to do."
      return
    fi
    # Anything other than a genuine 404 must not be silently treated as "already gone" -- that
    # would leave a real VM (and its cost) behind with no indication cleanup actually failed.
    echo "❌ Could not determine whether ${VM_ID} exists:" >&2
    echo "${describe_output}" >&2
    exit 1
  fi

  gcloud --quiet compute instances delete "${VM_ID}" --zone=${machine_zone}
  echo "✅ Deleted ${VM_ID}."
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
