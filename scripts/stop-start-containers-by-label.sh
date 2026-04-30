#!/bin/bash

# Docker label used to map a Duplicati backup job to one or more containers.
#
# Example Compose label:
#
# labels:
#   com.example.duplicati.backup: "ScriptTest"
#
# Matching is case-sensitive:
#   Duplicati job name "ScriptTest" matches label value "ScriptTest"
#   Duplicati job name "ScriptTest" does not match label value "scripttest"
BACKUP_LABEL_KEY="${BACKUP_LABEL_KEY:-com.example.duplicati.backup}"

# Log and state locations.
LOG_DIR="${LOG_DIR:-/logs}"
STATE_DIR="${STATE_DIR:-/config/docker_backup_state}"
logfile="${LOG_FILE:-${LOG_DIR}/docker_backup.log}"

mkdir -p "$LOG_DIR" "$STATE_DIR"

log() {
  printf "%s\n" "$*" | tee /proc/1/fd/1 -a "$logfile" >/dev/null 2>&1 || true
}

log_command_output() {
  local prefix="$1"
  local output="$2"

  if [[ -z "$output" ]]; then
    log "${prefix}: <empty>"
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log "${prefix}: ${line}"
  done <<< "$output"
}

trim_value() {
  printf '%s' "${1:-}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

safe_filename() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_'
}

find_matching_containers() {
  local backup_name="$1"
  local docker_lookup_output
  local docker_lookup_rc

  docker_lookup_output="$(
    docker ps -a \
      --filter "label=${BACKUP_LABEL_KEY}=${backup_name}" \
      --format '{{.Names}}' 2>&1
  )"
  docker_lookup_rc=$?

  if [[ $docker_lookup_rc -ne 0 ]]; then
    log "Docker lookup failed. Docker or dockerproxy may be unavailable."
    log "Docker command exit code: ${docker_lookup_rc}"
    log_command_output "Docker error" "$docker_lookup_output"
    return "$docker_lookup_rc"
  fi

  MATCHED_CONTAINERS=()

  if [[ -n "$docker_lookup_output" ]]; then
    mapfile -t MATCHED_CONTAINERS <<< "$docker_lookup_output"
  fi

  return 0
}

get_container_running_state() {
  local cont_name="$1"

  docker inspect -f '{{.State.Running}}' "$cont_name" 2>&1
}

stop_container_if_running() {
  local cont_name="$1"
  local state_file="$2"
  local docstate_output
  local docstate_rc
  local docstate
  local docker_output
  local docker_rc

  log "Found labeled container: ${cont_name}"

  docstate_output="$(get_container_running_state "$cont_name")"
  docstate_rc=$?

  if [[ $docstate_rc -ne 0 ]]; then
    log "Could not inspect container before stop: ${cont_name}"
    log_command_output "Docker inspect error" "$docstate_output"
    return 1
  fi

  docstate="$docstate_output"
  log "Container ${cont_name} running state before stop: ${docstate}"

  if [[ "$docstate" == "false" ]]; then
    log "Container ${cont_name} was already stopped. It will not be started after backup."
    return 0
  fi

  if [[ "$docstate" != "true" ]]; then
    log "Container ${cont_name} running state is unknown. It will not be stopped or added to restart list."
    return 1
  fi

  log "Stopping container: ${cont_name}"

  docker_output="$(docker stop "$cont_name" 2>&1)"
  docker_rc=$?

  if [[ $docker_rc -ne 0 ]]; then
    log "Failed to stop container: ${cont_name}"
    log "Docker command exit code: ${docker_rc}"
    log_command_output "Docker stop error" "$docker_output"
    return 1
  fi

  docstate_output="$(get_container_running_state "$cont_name")"
  docstate_rc=$?

  if [[ $docstate_rc -ne 0 ]]; then
    log "Could not inspect container after stop: ${cont_name}"
    log_command_output "Docker inspect error" "$docstate_output"
    return 1
  fi

  docstate="$docstate_output"
  log "Container ${cont_name} running state after stop: ${docstate}"

  if [[ "$docstate" == "false" ]]; then
    log "Container ${cont_name} stopped..."
    printf '%s\n' "$cont_name" >> "$state_file"
    return 0
  fi

  log "Container ${cont_name} still running, should be stopped!!!"
  return 1
}

start_container_if_needed() {
  local cont_name="$1"
  local docstate_output
  local docstate_rc
  local docstate
  local docker_output
  local docker_rc

  [[ -z "$cont_name" ]] && return 0

  log "Starting previously stopped container: ${cont_name}"

  docstate_output="$(get_container_running_state "$cont_name")"
  docstate_rc=$?

  if [[ $docstate_rc -ne 0 ]]; then
    log "Could not inspect container before start: ${cont_name}"
    log_command_output "Docker inspect error" "$docstate_output"
    return 1
  fi

  docstate="$docstate_output"
  log "Container ${cont_name} running state before start: ${docstate}"

  if [[ "$docstate" == "true" ]]; then
    log "Container ${cont_name} is already running..."
    return 0
  fi

  log "Starting container: ${cont_name}"

  docker_output="$(docker start "$cont_name" 2>&1)"
  docker_rc=$?

  if [[ $docker_rc -ne 0 ]]; then
    log "Failed to start container: ${cont_name}"
    log "Docker command exit code: ${docker_rc}"
    log_command_output "Docker start error" "$docker_output"
    return 1
  fi

  docstate_output="$(get_container_running_state "$cont_name")"
  docstate_rc=$?

  if [[ $docstate_rc -ne 0 ]]; then
    log "Could not inspect container after start: ${cont_name}"
    log_command_output "Docker inspect error" "$docstate_output"
    return 1
  fi

  docstate="$docstate_output"
  log "Container ${cont_name} running state after start: ${docstate}"

  if [[ "$docstate" == "true" ]]; then
    log "Container ${cont_name} started..."
    return 0
  fi

  log "Container ${cont_name} still not running, should be started!!!"
  return 1
}

# Duplicati variables.
dupdocker="$(trim_value "${DUPLICATI__backup_name:-}")"
dupevent="$(trim_value "${DUPLICATI__EVENTNAME:-}")"
dupopevent="$(trim_value "${DUPLICATI__OPERATIONNAME:-}")"
BACKUP_LABEL_KEY="$(trim_value "$BACKUP_LABEL_KEY")"

log "<<<=== Duplicati Docker Backup Script"
log "Script invoked: $(date)"
log "Duplicati job name: ${dupdocker:-<empty>}"
log "Duplicati event name: ${dupevent:-<empty>}"
log "Duplicati operation name: ${dupopevent:-<empty>}"
log "Docker backup label key: ${BACKUP_LABEL_KEY}"

if [[ -n "$dupopevent" && "$dupopevent" != "Backup" ]]; then
  log "Operation is not Backup. Exiting without stopping or starting containers."
  log "Script stopped: $(date)"
  log "===>>>"
  exit 0
fi

if [[ -z "$dupopevent" ]]; then
  log "Duplicati operation name is empty. Continuing based on event name: ${dupevent}"
fi

if [[ -z "$dupdocker" ]]; then
  log "Duplicati 'DUPLICATI__backup_name' is empty. Cannot match Docker containers."
  log "Script stopped: $(date)"
  log "===>>>"
  exit 0
fi

safe_job_name="$(safe_filename "$dupdocker")"
STATE_FILE="${STATE_DIR}/${safe_job_name}.stopped"

if [[ "$dupevent" == "BEFORE" ]]; then
  log "Duplicati running BEFORE event script"
  log "Finding containers with label ${BACKUP_LABEL_KEY} matching value: ${dupdocker}"

  if ! find_matching_containers "$dupdocker"; then
    log "Script stopped with error before any containers were changed: $(date)"
    log "===>>>"
    exit 1
  fi

  if [[ -s "$STATE_FILE" ]]; then
    log "Warning: existing state file found from a previous run: ${STATE_FILE}"
    log "This run will replace it with a fresh stopped-container list."
  fi

  # Clear previous state only after Docker lookup succeeds.
  : > "$STATE_FILE"

  if [[ ${#MATCHED_CONTAINERS[@]} -eq 0 ]]; then
    log "No containers found with label ${BACKUP_LABEL_KEY} matching value: ${dupdocker}"
    log "Script stopped: $(date)"
    log "===>>>"
    exit 0
  fi

  log "Matched ${#MATCHED_CONTAINERS[@]} container(s):"

  for cont_name in "${MATCHED_CONTAINERS[@]}"; do
    log " - ${cont_name}"
  done

  stop_failures=0

  for cont_name in "${MATCHED_CONTAINERS[@]}"; do
    if ! stop_container_if_running "$cont_name" "$STATE_FILE"; then
      stop_failures=1
    fi
  done

  if [[ -s "$STATE_FILE" ]]; then
    log "Containers stopped by this script and queued for restart:"

    while IFS= read -r cont_name; do
      [[ -z "$cont_name" ]] && continue
      log " - ${cont_name}"
    done < "$STATE_FILE"
  else
    log "No containers were stopped by this script. Nothing will be started after backup."
  fi

  if [[ "$stop_failures" -ne 0 ]]; then
    log "One or more containers could not be stopped cleanly."
    log "Continuing so the AFTER event can restart any containers that were stopped."
  fi

elif [[ "$dupevent" == "AFTER" ]]; then
  log "Duplicati running AFTER event script"

  if [[ ! -s "$STATE_FILE" ]]; then
    log "No saved stopped-container state found for job '${dupdocker}'. Nothing to start."
    log "Script stopped: $(date)"
    log "===>>>"
    exit 0
  fi

  log "Starting only containers that were stopped by the BEFORE event:"

  start_failures=0

  while IFS= read -r cont_name; do
    [[ -z "$cont_name" ]] && continue

    if ! start_container_if_needed "$cont_name"; then
      start_failures=1
    fi
  done < "$STATE_FILE"

  if [[ "$start_failures" -ne 0 ]]; then
    log "One or more containers could not be started cleanly."
    log "State file was kept so this can be retried: ${STATE_FILE}"
    log "Script stopped with error: $(date)"
    log "===>>>"
    exit 1
  fi

  rm -f "$STATE_FILE"
  log "Removed state file: ${STATE_FILE}"

else
  log "Duplicati 'DUPLICATI__EVENTNAME' not recognized: ${dupevent}"
fi

log "Script completed successfully."
log "Script stopped: $(date)"
log "===>>>"
exit 0
