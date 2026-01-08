#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# Sysbench suite runner (NUMA-aware) - outputs TPS and QPS columns
# - TPS: from "transactions: ... (X per sec.)"
# - QPS: from "queries: ... (X per sec.)"
# - status: ok / missing / failed / no_tps / no_qps
###############################################################################

# --------------------------- Config ------------------------------------------
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-sbuser}"
MYSQL_PASS="${MYSQL_PASS:-sbpass}"
MYSQL_DB="${MYSQL_DB:-sbtest}"

TABLES="${TABLES:-16}"
TABLE_SIZE="${TABLE_SIZE:-1000000}"
THREADS="${THREADS:-32}"
TIME="${TIME:-60}"
REPORT_INTERVAL="${REPORT_INTERVAL:-1}"

SYSBENCH_IMAGE="${SYSBENCH_IMAGE:-severalnines/sysbench}"
SYSBENCH_LUA_DIR="${SYSBENCH_LUA_DIR:-/usr/share/sysbench}"

OUT_DIR="${OUT_DIR:-./sysbench_results}"
CSV_FILE="${CSV_FILE:-$OUT_DIR/sysbench_tps_qps_results.csv}"

NUMA_PROFILE="${NUMA_PROFILE:-node0_mem0}"

CPUSET_NODE0="${CPUSET_NODE0:-0-31}"
CPUSET_NODE1="${CPUSET_NODE1:-32-63}"
MEMSET_NODE0="0"
MEMSET_NODE1="1"
# ----------------------------------------------------------------------------

WORKLOADS=(
  select_random_points
  select_random_ranges
  oltp_multi_selects
  oltp_point_select
  oltp_read_only
  oltp_read_write
  oltp_update_index
  oltp_update_non_index
  oltp_write_only
)

ts_now() { date +"%F %T"; }
run_id_now() { date +"%Y%m%d_%H%M%S"; }
die() { echo "ERROR: $*" >&2; exit 1; }

get_numa_args() {
  local profile="$1"
  local cpu_node mem_node cpus mems

  case "$profile" in
    node0_mem0) cpu_node="0"; mem_node="0" ;;
    node0_mem1) cpu_node="0"; mem_node="1" ;;
    node1_mem0) cpu_node="1"; mem_node="0" ;;
    node1_mem1) cpu_node="1"; mem_node="1" ;;
    *) die "Unsupported NUMA_PROFILE=${profile}. Use node0_mem0|node0_mem1|node1_mem0|node1_mem1" ;;
  esac

  case "$cpu_node" in
    0) cpus="$CPUSET_NODE0" ;;
    1) cpus="$CPUSET_NODE1" ;;
    *) die "Invalid cpu_node=$cpu_node" ;;
  esac

  case "$mem_node" in
    0) mems="$MEMSET_NODE0" ;;
    1) mems="$MEMSET_NODE1" ;;
    *) die "Invalid mem_node=$mem_node" ;;
  esac

  echo "--cpuset-cpus=${cpus} --cpuset-mems=${mems}"
}

# Check lua existence in sysbench image
lua_exists() {
  local workload="$1"
  docker run --rm "${SYSBENCH_IMAGE}" sh -lc "test -f '${SYSBENCH_LUA_DIR}/${workload}.lua'"
}

# Extract TPS and QPS (per sec) from sysbench output
extract_tps() {
  local file="$1"
  awk '/transactions:/{v=$(NF-2); gsub(/[()]/,"",v); print v}' "$file" | tail -n1 2>/dev/null || true
}

extract_qps() {
  local file="$1"
  awk '/queries:/{v=$(NF-2); gsub(/[()]/,"",v); print v}' "$file" | tail -n1 2>/dev/null || true
}

run_workload() {
  local workload="$1"
  local out_file="$2"
  local numa_args
  numa_args="$(get_numa_args "$NUMA_PROFILE")"

  # shellcheck disable=SC2086
  docker run --rm --network=host ${numa_args} "${SYSBENCH_IMAGE}" \
    sysbench "${SYSBENCH_LUA_DIR}/${workload}.lua" \
      --mysql-host="${MYSQL_HOST}" \
      --mysql-port="${MYSQL_PORT}" \
      --mysql-user="${MYSQL_USER}" \
      --mysql-password="${MYSQL_PASS}" \
      --mysql-db="${MYSQL_DB}" \
      --tables="${TABLES}" \
      --table-size="${TABLE_SIZE}" \
      --threads="${THREADS}" \
      --time="${TIME}" \
      --report-interval="${REPORT_INTERVAL}" \
      run | tee "${out_file}" >/dev/null

  return ${PIPESTATUS[0]}
}

main() {
  mkdir -p "${OUT_DIR}"
  local run_id
  run_id="$(run_id_now)"

  # Create header if missing
  if [[ ! -f "${CSV_FILE}" ]]; then
    echo "run_id,timestamp,numa_profile,workload,status,tps,qps,threads,time_s,tables,table_size,important" > "${CSV_FILE}"
  fi

  echo "Run ID      : ${run_id}"
  echo "NUMA_PROFILE : ${NUMA_PROFILE}"
  echo "Output CSV   : ${CSV_FILE}"
  echo

  for w in "${WORKLOADS[@]}"; do
    local ts out_file important status tps qps rc
    ts="$(ts_now)"
    out_file="${OUT_DIR}/${run_id}_${NUMA_PROFILE}_${w}.log"
    important="0"
    [[ "${w}" == "oltp_read_write" ]] && important="1"

    echo "===== Running ${w} [${NUMA_PROFILE}] ====="

    # Missing script -> record and continue
    if ! lua_exists "${w}"; then
      status="missing"
      tps="NA"
      qps="NA"
      echo "[SKIP] ${w}: lua script not found (${SYSBENCH_LUA_DIR}/${w}.lua)" | tee "${out_file}" >/dev/null
      echo "${run_id},${ts},${NUMA_PROFILE},${w},${status},${tps},${qps},${THREADS},${TIME},${TABLES},${TABLE_SIZE},${important}" >> "${CSV_FILE}"
      echo
      continue
    fi

    rc=0
    run_workload "${w}" "${out_file}" || rc=$?

    if [[ "$rc" -ne 0 ]]; then
      status="failed"
      tps="NA"
      qps="NA"
      echo "[FAIL] ${w}: sysbench exit code=${rc}"
      echo "${run_id},${ts},${NUMA_PROFILE},${w},${status},${tps},${qps},${THREADS},${TIME},${TABLES},${TABLE_SIZE},${important}" >> "${CSV_FILE}"
      echo
      continue
    fi

    tps="$(extract_tps "${out_file}")"
    qps="$(extract_qps "${out_file}")"

    # status logic
    if [[ -n "$tps" && -n "$qps" ]]; then
      status="ok"
    elif [[ -z "$tps" && -n "$qps" ]]; then
      status="no_tps"
    elif [[ -n "$tps" && -z "$qps" ]]; then
      status="no_qps"
    else
      status="no_tps_no_qps"
    fi

    [[ -z "$tps" ]] && tps="NA"
    [[ -z "$qps" ]] && qps="NA"

    echo "${run_id},${ts},${NUMA_PROFILE},${w},${status},${tps},${qps},${THREADS},${TIME},${TABLES},${TABLE_SIZE},${important}" >> "${CSV_FILE}"

    if [[ "${important}" == "1" ]]; then
      echo "[KEY] ${w}: TPS=${tps}, QPS=${qps} (status=${status})"
    else
      echo "[OK ] ${w}: TPS=${tps}, QPS=${qps} (status=${status})"
    fi
    echo
  done

  echo "All done."
  echo "CSV appended: ${CSV_FILE}"
}

main "$@"
