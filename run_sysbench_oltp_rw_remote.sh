#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# Run only oltp_read_write against a (possibly remote) MySQL server
# - No NUMA/CPU affinity binding
# - Can run multiple iterations and append TPS/QPS to a CSV
###############################################################################

# --------------------------- Config ------------------------------------------
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"   # set to remote MySQL IP/hostname
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-sbuser}"
MYSQL_PASS="${MYSQL_PASS:-sbpass}"
MYSQL_DB="${MYSQL_DB:-sbtest}"

TABLES="${TABLES:-16}"
TABLE_SIZE="${TABLE_SIZE:-1000000}"
THREADS="${THREADS:-32}"
TIME="${TIME:-60}"
REPORT_INTERVAL="${REPORT_INTERVAL:-1}"

RUNS="${RUNS:-3}"                       # how many iterations to run

SYSBENCH_IMAGE="${SYSBENCH_IMAGE:-severalnines/sysbench}"
SYSBENCH_LUA_DIR="${SYSBENCH_LUA_DIR:-/usr/share/sysbench}"

OUT_DIR="${OUT_DIR:-./sysbench_results}"
CSV_FILE="${CSV_FILE:-$OUT_DIR/oltp_read_write_results.csv}"
# ----------------------------------------------------------------------------

ts_now() { date +"%F %T"; }
run_id_now() { date +"%Y%m%d_%H%M%S"; }
die() { echo "ERROR: $*" >&2; exit 1; }

lua_exists() {
  docker run --rm "${SYSBENCH_IMAGE}" sh -lc "test -f '${SYSBENCH_LUA_DIR}/oltp_read_write.lua'"
}

extract_tps() {
  local file="$1"
  awk '/transactions:/{v=$(NF-2); gsub(/[()]/,"",v); print v}' "$file" | tail -n1 2>/dev/null || true
}

extract_qps() {
  local file="$1"
  awk '/queries:/{v=$(NF-2); gsub(/[()]/,"",v); print v}' "$file" | tail -n1 2>/dev/null || true
}

main() {
  mkdir -p "${OUT_DIR}"
  local run_id ts out_file rc tps qps
  run_id="$(run_id_now)"

  if [[ ! -f "${CSV_FILE}" ]]; then
    echo "run_id,timestamp,iteration,workload,status,tps,qps,threads,time_s,tables,table_size" > "${CSV_FILE}"
  fi

  echo "Run ID       : ${run_id}"
  echo "MySQL target : ${MYSQL_USER}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
  echo "Threads/Time : ${THREADS}/${TIME}s"
  echo "Iterations   : ${RUNS}"
  echo "CSV file     : ${CSV_FILE}"
  echo

  if ! lua_exists; then
    die "oltp_read_write.lua not found in ${SYSBENCH_IMAGE}:${SYSBENCH_LUA_DIR}"
  fi

  for i in $(seq 1 "${RUNS}"); do
    ts="$(ts_now)"
    out_file="${OUT_DIR}/${run_id}_run${i}_oltp_read_write.log"

    echo "===== Iteration ${i}/${RUNS} ====="
    docker run --rm --network=host "${SYSBENCH_IMAGE}" \
      sysbench "${SYSBENCH_LUA_DIR}/oltp_read_write.lua" \
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

    rc=${PIPESTATUS[0]}
    status="ok"
    if [[ "$rc" -ne 0 ]]; then
      status="failed"
      tps="NA"
      qps="NA"
      echo "[FAIL] sysbench exit code=${rc}"
    else
      tps="$(extract_tps "${out_file}")"
      qps="$(extract_qps "${out_file}")"
      [[ -z "$tps" ]] && tps="NA" && status="no_tps"
      [[ -z "$qps" ]] && qps="NA" && [[ "$status" == "ok" ]] && status="no_qps"
      echo "[OK ] TPS=${tps}, QPS=${qps}"
    fi

    echo "${run_id},${ts},${i},oltp_read_write,${status},${tps},${qps},${THREADS},${TIME},${TABLES},${TABLE_SIZE}" >> "${CSV_FILE}"
    echo "Log: ${out_file}"
    echo
  done

  echo "All done. CSV appended: ${CSV_FILE}"
}

main "$@"
