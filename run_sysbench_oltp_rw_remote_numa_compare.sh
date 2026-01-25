#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 远端 MySQL 压测（记录 NUMA 场景标签）：
# - sysbench 客户端不做 NUMA 绑定（不使用 numactl）
# - 不会重启远端 MySQL；需要你先在远端用对应 NUMA_PROFILE 启动好
# - 输出 CSV，包含 TPS/QPS/P99 延迟
###############################################################################

# --------------------------- Config ------------------------------------------
# 远端 MySQL 连接信息
MYSQL_HOST="${MYSQL_HOST:-192.168.1.231}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-sbuser}"
MYSQL_PASS="${MYSQL_PASS:-sbpass}"
MYSQL_DB="${MYSQL_DB:-sbtest}"

TABLES="${TABLES:-16}"
TABLE_SIZE="${TABLE_SIZE:-1000000}"
THREADS="${THREADS:-32}"
TIME="${TIME:-60}"               # 单轮持续时长（sysbench --time）
REPORT_INTERVAL="${REPORT_INTERVAL:-1}" # 探测间隔（sysbench --report-interval）
RUNS="${RUNS:-3}"                # 每个场景运行轮数

SYSBENCH_IMAGE="${SYSBENCH_IMAGE:-severalnines/sysbench}"
SYSBENCH_LUA_DIR="${SYSBENCH_LUA_DIR:-/usr/share/sysbench}"
SYSBENCH_PERCENTILE="${SYSBENCH_PERCENTILE:-99}" # 用于输出 P99 延迟

OUT_DIR="${OUT_DIR:-./sysbench_results}"
CSV_FILE="${CSV_FILE:-$OUT_DIR/oltp_rw_remote_numa_compare.csv}"

# 场景格式（空格分隔）：
# - label:mysql_numa_profile   -> 自定义标签
# - mysql_numa_profile         -> 标签=NUMA_PROFILE
# 例子："node0_mem0 node0_mem1" 或 "local:node0_mem0 cross:node0_mem1"
SCENARIOS="${SCENARIOS:-node0_mem0 node0_mem1}"
# ----------------------------------------------------------------------------

ts_now() { date +"%F %T"; }
run_id_now() { date +"%Y%m%d_%H%M%S"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# 检查 sysbench 镜像里是否有 oltp_read_write.lua
lua_exists() {
  docker run --rm "${SYSBENCH_IMAGE}" sh -lc "test -f '${SYSBENCH_LUA_DIR}/oltp_read_write.lua'"
}

# 从 sysbench 输出里提取 TPS
extract_tps() {
  local file="$1"
  awk '/transactions:/{v=$(NF-2); gsub(/[()]/,"",v); print v}' "$file" | tail -n1 2>/dev/null || true
}

# 从 sysbench 输出里提取 QPS
extract_qps() {
  local file="$1"
  awk '/queries:/{v=$(NF-2); gsub(/[()]/,"",v); print v}' "$file" | tail -n1 2>/dev/null || true
}

# 从 sysbench 输出里提取 P99 延迟（ms）
extract_p99() {
  local file="$1"
  awk '/99th percentile:/{print $(NF)}' "$file" | tail -n1 2>/dev/null || true
}

write_header() {
  if [[ ! -f "${CSV_FILE}" ]]; then
    echo "run_id,timestamp,label,mysql_numa_profile,iteration,status,tps,qps,p99_latency_ms,threads,time_s,tables,table_size,mysql_host,mysql_port" > "${CSV_FILE}"
  fi
}

run_sysbench_iteration() {
  local label="$1" mysql_profile="$2" iteration="$3" scenario_run_id="$4"
  local ts out_file rc status tps qps p99

  ts="$(ts_now)"
  out_file="${OUT_DIR}/${scenario_run_id}_${label}_run${iteration}_oltp_read_write.log"
  echo "-> Running sysbench [${label}] (mysql_numa=${mysql_profile}) iter ${iteration}/${RUNS}"

  set +e
  # sysbench 客户端用容器跑，不做 NUMA 绑定，仅采集性能数据
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
      --percentile="${SYSBENCH_PERCENTILE}" \
      run | tee "${out_file}" >/dev/null
  rc=${PIPESTATUS[0]}
  set -e

  if [[ "$rc" -ne 0 ]]; then
    status="failed"
    tps="NA"
    qps="NA"
    p99="NA"
    echo "[FAIL] sysbench exit code=${rc}"
  else
    tps="$(extract_tps "${out_file}")"
    qps="$(extract_qps "${out_file}")"
    status="ok"
    if [[ -z "$tps" && -z "$qps" ]]; then
      status="no_tps_no_qps"
      tps="NA"
      qps="NA"
    elif [[ -z "$tps" ]]; then
      status="no_tps"
      tps="NA"
    elif [[ -z "$qps" ]]; then
      status="no_qps"
      qps="NA"
    fi
    p99="$(extract_p99 "${out_file}")"
    if [[ -z "$p99" ]]; then
      p99="NA"
      [[ "$status" == "ok" ]] && status="no_p99"
    fi
    echo "[OK ] TPS=${tps}, QPS=${qps}, P99(ms)=${p99}"
  fi

  echo "${scenario_run_id},${ts},${label},${mysql_profile},${iteration},${status},${tps},${qps},${p99},${THREADS},${TIME},${TABLES},${TABLE_SIZE},${MYSQL_HOST},${MYSQL_PORT}" >> "${CSV_FILE}"
  echo "Log: ${out_file}"
  echo
}

main() {
  # 输出目录和 CSV 头
  mkdir -p "${OUT_DIR}"
  write_header

  if ! lua_exists; then
    die "oltp_read_write.lua not found in ${SYSBENCH_IMAGE}:${SYSBENCH_LUA_DIR}"
  fi

  # 打印本次运行的关键参数，方便回溯
  echo "Remote MySQL : ${MYSQL_USER}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
  echo "Runs/Iter    : ${RUNS} iterations, threads=${THREADS}, time=${TIME}s"
  echo "Scenarios    : ${SCENARIOS}"
  echo "CSV output   : ${CSV_FILE}"
  echo "NOTE         : This script will NOT restart remote MySQL. Make sure remote MySQL is already running with the specified mysql_numa_profile before each run."
  echo

  read -r -a scenario_list <<< "${SCENARIOS}"
  if [[ "${#scenario_list[@]}" -eq 0 ]]; then
    die "No scenarios specified in SCENARIOS"
  fi

  for entry in "${scenario_list[@]}"; do
    local label mysql_profile
    if [[ "$entry" == *:* ]]; then
      IFS=":" read -r label mysql_profile <<< "${entry}"
    else
      label="$entry"
      mysql_profile="$entry"
    fi
    if [[ -z "${label:-}" || -z "${mysql_profile:-}" ]]; then
      die "Invalid scenario '${entry}'. Use label:mysql_numa_profile or mysql_numa_profile"
    fi

    local scenario_run_id
    scenario_run_id="$(run_id_now)"
    echo "===== Scenario ${label} (mysql_numa=${mysql_profile}) ====="

    for i in $(seq 1 "${RUNS}"); do
      run_sysbench_iteration "${label}" "${mysql_profile}" "${i}" "${scenario_run_id}"
    done
  done

  echo "All done. CSV appended: ${CSV_FILE}"
}

main "$@"
