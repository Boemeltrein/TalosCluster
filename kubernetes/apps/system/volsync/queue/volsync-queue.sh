RESULT_TIMEOUT=1
RESULT_API_ERROR=2
RESULT_SKIPPED=3
RESULT_FAILED=4
DEBUG="${DEBUG:-0}"
TAB="$(printf '\t')"
FIELD_SEPARATOR='|'

PVC_GATE_POLL_INTERVAL_SECONDS=5
PVC_STATUS_WAITING_FOR_TRIGGER='WaitingForTrigger'
RS_MOVER_RESULT_SUCCESSFUL='Successful'
RS_MOVER_RESULT_FAILED='Failed'
RS_SYNC_STATUS_TRUE='True'

VOLSYNC_IDLE_TIMEOUT_SECONDS="${VOLSYNC_IDLE_TIMEOUT_SECONDS:-600}"
VOLSYNC_RUN_TIMEOUT_SECONDS="${VOLSYNC_RUN_TIMEOUT_SECONDS:-7200}"
VOLSYNC_POLL_INTERVAL_SECONDS="${VOLSYNC_POLL_INTERVAL_SECONDS:-10}"
VOLSYNC_QUEUE_EXCLUDE_TARGETS="${VOLSYNC_QUEUE_EXCLUDE_TARGETS:-}"

PVC_STATE_TEMPLATE='{{with index .metadata.annotations "volsync.backube/use-copy-trigger"}}{{.}}{{end}}|{{with index .metadata.annotations "volsync.backube/latest-copy-trigger"}}{{.}}{{end}}|{{with index .metadata.annotations "volsync.backube/latest-copy-status"}}{{.}}{{end}}'
PVC_QUEUE_TEMPLATE='{{range .items}}{{.metadata.namespace}}{{"\t"}}{{.metadata.name}}{{"\t"}}{{with index .metadata.annotations "volsync.backube/use-copy-trigger"}}{{.}}{{end}}{{"\n"}}{{end}}'
RS_STATE_TEMPLATE='{{.status.lastSyncTime}}|{{if .status.latestMoverStatus}}{{.status.latestMoverStatus.result}}{{end}}|{{range .status.conditions}}{{if eq .type "Synchronizing"}}{{.status}}|{{.reason}}{{end}}{{end}}'

log_event() {
  event="$1"; target="$2"; shift 2
  case "$event" in
    fail) log_error "(${target}) $*" ;;
    skip) log_warn "(${target}) $*" ;;
    *) log "(${target}) ${event}${*:+ }$*" ;;
  esac
}

log() { log_with_level INFO "$*"; }
log_warn() { log_with_level WARN "$*"; }
log_error() { log_with_level ERROR "$*"; }

log_with_level() {
  level="$1"; shift; timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s: [volsync-queue][%s] %s\n' "$level" "$timestamp" "$*" >&2
}

log_debug() { [ "$DEBUG" = "1" ] || return 0; log_with_level DEBUG "$*"; }

target_excluded() {
  target="$1"
  [ -n "$VOLSYNC_QUEUE_EXCLUDE_TARGETS" ] || return 1

  for excluded_target in $VOLSYNC_QUEUE_EXCLUDE_TARGETS; do
    if [ "$excluded_target" = "$target" ]; then
      return 0
    fi
  done

  return 1
}

log_debug_pvc_state() {
  target="$1"; pvc_state_line="$2"
  [ "$DEBUG" = "1" ] && [ -n "$pvc_state_line" ] || return 0
  decode_pvc_state "$pvc_state_line"
  log_with_level DEBUG "${target} use_copy_trigger=${pvc_use_copy_trigger:-} latest_copy_trigger=${pvc_latest_copy_trigger:-} latest_copy_status=${pvc_latest_copy_status:-}"
}

log_debug_replicationsource_state() {
  target="$1"; replicationsource_state_line="$2"
  [ "$DEBUG" = "1" ] && [ -n "$replicationsource_state_line" ] || return 0
  decode_replicationsource_state "$replicationsource_state_line"
  log_with_level DEBUG "${target} last_sync_time=${replicationsource_last_sync_time:-} latest_mover_result=${replicationsource_latest_mover_result:-} sync_status=${replicationsource_sync_status:-} sync_reason=${replicationsource_sync_reason:-}"
}

patch_pvc() {
  namespace="$1"
  name="$2"
  payload="$3"

  PATCH_ERROR_KIND=""
  patch_output="$(kubectl patch persistentvolumeclaim "$name" -n "$namespace" --type=merge -p "$payload" 2>&1 >/dev/null)"
  patch_status="$?"

  if [ "$patch_status" -eq 0 ]; then
    return 0
  fi

  case "$patch_output" in
    *"(NotFound)"*|*" not found"*)
      PATCH_ERROR_KIND="not_found"
      ;;
    *)
      PATCH_ERROR_KIND="api_error"
      ;;
  esac

  return "$patch_status"
}

decode_pvc_state() {
  pvc_state_line="$1"

  IFS="$FIELD_SEPARATOR" read -r \
    pvc_use_copy_trigger \
    pvc_latest_copy_trigger \
    pvc_latest_copy_status <<EOF
$pvc_state_line
EOF
}

fetch_pvc_state() {
  namespace="$1"
  name="$2"

  kubectl get "persistentvolumeclaim/${name}" -n "$namespace" --ignore-not-found -o "go-template=${PVC_STATE_TEMPLATE}" 2>/dev/null
}

pvc_waiting_for_trigger() {
  pvc_state_line="$1"
  decode_pvc_state "$pvc_state_line"

  if [ -n "$pvc_use_copy_trigger" ] &&
    [ "$pvc_latest_copy_status" = "$PVC_STATUS_WAITING_FOR_TRIGGER" ]; then
    STATE_EVALUATION_OUTCOME="success"
    return 0
  fi

  return 1
}

decode_replicationsource_state() {
  replicationsource_state_line="$1"

  IFS="$FIELD_SEPARATOR" read -r \
    replicationsource_last_sync_time \
    replicationsource_latest_mover_result \
    replicationsource_sync_status \
    replicationsource_sync_reason <<EOF
$replicationsource_state_line
EOF
}

fetch_replicationsource_state() {
  namespace="$1"
  name="$2"

  kubectl get "replicationsource.volsync.backube/${name}" -n "$namespace" --ignore-not-found -o "go-template=${RS_STATE_TEMPLATE}" 2>/dev/null
}

replicationsource_completion_reached() {
  replicationsource_state_line="$1"
  initial_last_sync_time="$2"
  initial_replicationsource_state_line="$3"
  decode_replicationsource_state "$replicationsource_state_line"

  if [ -z "$initial_last_sync_time" ] && [ -n "$replicationsource_last_sync_time" ] ||
    [ -n "$initial_last_sync_time" ] && [ "$replicationsource_last_sync_time" != "$initial_last_sync_time" ]; then
    if [ "$replicationsource_latest_mover_result" = "$RS_MOVER_RESULT_SUCCESSFUL" ]; then
      STATE_EVALUATION_OUTCOME="success"
      return 0
    fi

    if [ "$replicationsource_latest_mover_result" = "$RS_MOVER_RESULT_FAILED" ]; then
      STATE_EVALUATION_OUTCOME="failed"
      STATE_EVALUATION_MESSAGE="replication failed"
      return 0
    fi
  fi

  if [ "$replicationsource_state_line" != "$initial_replicationsource_state_line" ] &&
    [ "$replicationsource_sync_status" != "$RS_SYNC_STATUS_TRUE" ] &&
    [ "$replicationsource_latest_mover_result" = "$RS_MOVER_RESULT_FAILED" ]; then
    STATE_EVALUATION_OUTCOME="failed"
    STATE_EVALUATION_MESSAGE="replication failed"
    return 0
  fi

  return 1
}

poll_until_state() {
  namespace="$1"
  name="$2"
  fetcher="$3"
  debugger="$4"
  evaluator="$5"
  missing_resource="$6"
  wait_detail="$7"
  timeout_seconds="$8"
  sleep_seconds="$9"
  shift 9

  target="${namespace}/${name}"
  elapsed=0
  pending_logged=0
  api_unreadable=0

  while true; do
    if ! state_line="$("$fetcher" "$namespace" "$name")"; then
      if [ "$api_unreadable" -eq 0 ]; then
        log_warn "(${target}) waiting for api state"
        api_unreadable=1
      fi

      if [ "$elapsed" -ge "$timeout_seconds" ]; then
        log_event fail "$target" "api state remained unreadable"
        return "$RESULT_API_ERROR"
      fi

      sleep "$sleep_seconds"
      elapsed=$((elapsed + sleep_seconds))
      continue
    fi

    if [ -z "$state_line" ]; then
      log_event skip "$target" "skipped: ${missing_resource} no longer exists"
      return "$RESULT_SKIPPED"
    fi

    if [ "$api_unreadable" -eq 1 ]; then
      log_warn "(${target}) api state readable again"
      api_unreadable=0
    fi

    STATE_EVALUATION_OUTCOME=""
    STATE_EVALUATION_MESSAGE=""
    if "$evaluator" "$state_line" "$@"; then
      "$debugger" "$target" "$state_line"
      case "$STATE_EVALUATION_OUTCOME" in
        success)
          printf '%s\n' "$state_line"
          return 0
          ;;
        failed)
          log_event fail "$target" "${STATE_EVALUATION_MESSAGE:-failed}"
          return "$RESULT_FAILED"
          ;;
      esac
    fi

    "$debugger" "$target" "$state_line"

    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      log_error "(${target}) timed out: waiting for ${wait_detail}"
      return "$RESULT_TIMEOUT"
    fi

    if [ "$pending_logged" -eq 0 ]; then
      log "(${target}) waiting for ${wait_detail}"
      pending_logged=1
    fi

    sleep "$sleep_seconds"
    elapsed=$((elapsed + sleep_seconds))
  done
}

start_run() {
  namespace="$1"
  name="$2"
  trigger_id="$3"
  target="${namespace}/${name}"

  if ! patch_pvc "$namespace" "$name" "{\"metadata\":{\"annotations\":{\"volsync.backube/copy-trigger\":\"${trigger_id}\"}}}"; then
    if [ "$PATCH_ERROR_KIND" = "not_found" ]; then
      log_event skip "$target" "skipped: pvc no longer exists before setting copy-trigger"
      log_debug "${target} copy_trigger_id=${trigger_id}"
      return "$RESULT_SKIPPED"
    fi

    log_event fail "$target" "api could not set copy-trigger id"
    log_debug "${target} copy_trigger_id=${trigger_id}"
    return "$RESULT_API_ERROR"
  fi

  log_event start "$target" "replication"
  log_debug "${target} copy_trigger_id=${trigger_id}"
  return 0
}

trigger_and_wait() {
  namespace="$1"
  name="$2"
  trigger_id="$3"
  target="${namespace}/${name}"

  if poll_until_state "$namespace" "$name" \
    fetch_pvc_state \
    log_debug_pvc_state \
    pvc_waiting_for_trigger \
    pvc \
    "copy-trigger gate" \
    "$VOLSYNC_IDLE_TIMEOUT_SECONDS" \
    "$PVC_GATE_POLL_INTERVAL_SECONDS" >/dev/null; then
    :
  else
    idle_status="$?"
    return "$idle_status"
  fi

  if ! replicationsource_state_line="$(fetch_replicationsource_state "$namespace" "$name")"; then
    log_event fail "$target" "api state could not be read before replication"
    return "$RESULT_API_ERROR"
  fi

  if [ -z "$replicationsource_state_line" ]; then
    log_event skip "$target" "skipped: replicationsource no longer exists before replication"
    return "$RESULT_SKIPPED"
  fi

  decode_replicationsource_state "$replicationsource_state_line"
  initial_last_sync_time="$replicationsource_last_sync_time"
  initial_replicationsource_state_line="$replicationsource_state_line"

  if start_run "$namespace" "$name" "$trigger_id"; then
    :
  else
    start_status="$?"
    return "$start_status"
  fi

  if poll_until_state "$namespace" "$name" \
    fetch_replicationsource_state \
    log_debug_replicationsource_state \
    replicationsource_completion_reached \
    replicationsource \
    completion \
    "$VOLSYNC_RUN_TIMEOUT_SECONDS" \
    "$VOLSYNC_POLL_INTERVAL_SECONDS" \
    "$initial_last_sync_time" \
    "$initial_replicationsource_state_line" >/dev/null; then
    log "(${target}) completed"
    return 0
  else
    wait_status="$?"
  fi

  case "$wait_status" in
    "$RESULT_SKIPPED"|"$RESULT_TIMEOUT"|"$RESULT_API_ERROR"|"$RESULT_FAILED") return "$wait_status" ;;
    *)
      log_error "(${target}) unexpected wait status=${wait_status}"
      return "$RESULT_API_ERROR"
      ;;
  esac
}

validate_environment() {
  for command_name in kubectl sort wc mktemp date tr; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      log_event fail bootstrap "missing required command=${command_name}"
      return 1
    fi
  done

  for setting in \
    "VOLSYNC_IDLE_TIMEOUT_SECONDS:${VOLSYNC_IDLE_TIMEOUT_SECONDS}" \
    "VOLSYNC_RUN_TIMEOUT_SECONDS:${VOLSYNC_RUN_TIMEOUT_SECONDS}" \
    "VOLSYNC_POLL_INTERVAL_SECONDS:${VOLSYNC_POLL_INTERVAL_SECONDS}"; do
    variable_name="${setting%%:*}"
    variable_value="${setting#*:}"
    case "$variable_value" in
      ''|*[!0-9]*)
        log_event fail bootstrap "invalid ${variable_name}=${variable_value} expected positive integer"
        return 1
        ;;
      0)
        log_event fail bootstrap "invalid ${variable_name}=0 expected positive integer"
        return 1
        ;;
      esac
  done

  for excluded_target in $VOLSYNC_QUEUE_EXCLUDE_TARGETS; do
    case "$excluded_target" in
      */*) ;;
      *)
        log_event fail bootstrap "invalid VOLSYNC_QUEUE_EXCLUDE_TARGETS entry=${excluded_target} expected namespace/pvc"
        return 1
        ;;
    esac
  done

  if ! kubectl get --raw=/readyz >/dev/null 2>/dev/null; then
    log_event fail bootstrap "kubernetes api is not reachable"
    return 1
  fi

  if [ "$(kubectl auth can-i list persistentvolumeclaims --all-namespaces 2>/dev/null || true)" != "yes" ]; then
    log_event fail bootstrap "current identity cannot list pvcs"
    return 1
  fi

  if [ "$(kubectl auth can-i get persistentvolumeclaims --all-namespaces 2>/dev/null || true)" != "yes" ]; then
    log_event fail bootstrap "current identity cannot read pvcs"
    return 1
  fi

  if [ "$(kubectl auth can-i patch persistentvolumeclaims --all-namespaces 2>/dev/null || true)" != "yes" ]; then
    log_event fail bootstrap "current identity cannot patch pvcs"
    return 1
  fi

  if [ "$(kubectl auth can-i list replicationsources.volsync.backube --all-namespaces 2>/dev/null || true)" != "yes" ]; then
    log_event fail bootstrap "current identity cannot list replicationsources"
    return 1
  fi

  if [ "$(kubectl auth can-i get replicationsources.volsync.backube --all-namespaces 2>/dev/null || true)" != "yes" ]; then
    log_event fail bootstrap "current identity cannot read replicationsources"
    return 1
  fi

  log_debug "bootstrap debug=${DEBUG} idle_timeout=${VOLSYNC_IDLE_TIMEOUT_SECONDS} run_timeout=${VOLSYNC_RUN_TIMEOUT_SECONDS} poll_interval=${VOLSYNC_POLL_INTERVAL_SECONDS}"
  return 0
}

run_id="$(date +%Y%m%dT%H%M%S%z)"
queue_file="$(mktemp)"
raw_queue_file="$(mktemp)"
excluded_count=0
trap 'rm -f "$queue_file" "$raw_queue_file"' EXIT

if ! validate_environment; then
  exit 1
fi

if ! kubectl get persistentvolumeclaim -A -o "go-template=${PVC_QUEUE_TEMPLATE}" > "$raw_queue_file"; then
  log_event fail queue "could not list source pvcs"
  exit 1
fi

while IFS="$TAB" read -r namespace name use_copy_trigger; do
  [ -z "$namespace" ] && continue
  [ -n "$use_copy_trigger" ] || continue

  target="${namespace}/${name}"
  if target_excluded "$target"; then
    log_event skip "$target" "skipped: excluded by VOLSYNC_QUEUE_EXCLUDE_TARGETS"
    excluded_count=$((excluded_count + 1))
    continue
  fi

  printf '%s\t%s\n' "$namespace" "$name" >> "$queue_file"
done < "$raw_queue_file"

if ! sort -k1,1 -k2,2 -o "$queue_file" "$queue_file"; then
  log_event fail queue "could not sort pvc queue"
  exit 1
fi

if [ ! -s "$queue_file" ]; then
  if [ "$excluded_count" -gt 0 ]; then
    log_warn "(queue) no queued pvcs found excluded=${excluded_count}"
  else
    log_warn "(queue) no queued pvcs found"
  fi
  exit 0
fi

queue_count="$(wc -l < "$queue_file" | tr -d ' ')"
success_count=0
timeout_count=0
api_error_count=0
skipped_count=0
failed_count=0
log_event start queue "processing count=${queue_count}"

while IFS="$TAB" read -r namespace name; do
  [ -z "$namespace" ] && continue

  if trigger_and_wait "$namespace" "$name" "${run_id}-${namespace}-${name}"; then
    success_count=$((success_count + 1))
    continue
  else
    trigger_status="$?"
  fi

  case "$trigger_status" in
    "$RESULT_TIMEOUT") timeout_count=$((timeout_count + 1)) ;;
    "$RESULT_API_ERROR") api_error_count=$((api_error_count + 1)) ;;
    "$RESULT_SKIPPED") skipped_count=$((skipped_count + 1)) ;;
    "$RESULT_FAILED") failed_count=$((failed_count + 1)) ;;
    *) api_error_count=$((api_error_count + 1)) ;;
  esac
done < "$queue_file"

summary_detail="completed success=${success_count}"
[ "$failed_count" -gt 0 ] && summary_detail="${summary_detail} failed=${failed_count}"
[ "$timeout_count" -gt 0 ] && summary_detail="${summary_detail} timed_out=${timeout_count}"
[ "$api_error_count" -gt 0 ] && summary_detail="${summary_detail} api_errors=${api_error_count}"
[ "$skipped_count" -gt 0 ] && summary_detail="${summary_detail} skipped=${skipped_count}"
[ "$excluded_count" -gt 0 ] && summary_detail="${summary_detail} excluded=${excluded_count}"

if [ "$failed_count" -gt 0 ] || [ "$timeout_count" -gt 0 ] || [ "$api_error_count" -gt 0 ] || [ "$skipped_count" -gt 0 ]; then
  log_warn "(queue) $summary_detail"
else
  log "(queue) $summary_detail"
fi

if [ "$failed_count" -gt 0 ] || [ "$timeout_count" -gt 0 ] || [ "$api_error_count" -gt 0 ]; then
  exit 1
fi