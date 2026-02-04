#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 本地同机 NUMA 交叉压测：
# NUMA_PROFILE=nodeX_memY
#   - MySQL (Docker): CPU 绑 nodeX，内存绑 nodeY
#   - sysbench (宿主机)规则：
#       * 当 X != Y：CPU 绑 nodeY，内存也绑 nodeY
#       * 当 X == Y：CPU 绑 node1，内存也绑 node1
###############################################################################

# --------------------------- MySQL (Docker) ----------------------------------
# MySQL 镜像/容器相关配置（同 run_mysql_8030_numa.sh）
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0.30}"
CONTAINER_NAME="${CONTAINER_NAME:-mysql8030}"
HOST_PORT="${HOST_PORT:-3306}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-sunwei}"

DATA_VOLUME="${DATA_VOLUME:-mysql8030_data}"
MYCNF="${MYCNF:-./conf/my.cnf}"

NUMA_PROFILE="${NUMA_PROFILE:-node0_mem0}" # nodeX_memY，X/Y 为 NUMA 节点编号

# Map: CPU-node -> CPU list for Docker --cpuset-cpus（按 numactl --hardware 配）
CPUSET_NODE0="${CPUSET_NODE0:-0-31}"
CPUSET_NODE1="${CPUSET_NODE1:-32-63}"
# Map: MEM-node -> cpuset mem node id for Docker --cpuset-mems
# 如果 MEMSET_NODEx 没设置，默认等于 x
MEMSET_NODE0="${MEMSET_NODE0:-0}"
MEMSET_NODE1="${MEMSET_NODE1:-1}"

# --------------------------- sysbench (host) ---------------------------------
# sysbench 直接在宿主机运行，采用 numactl 绑定 CPU/内存
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}" # 通过宿主机端口访问容器内 MySQL
MYSQL_PORT="${MYSQL_PORT:-$HOST_PORT}"
MYSQL_USER="${MYSQL_USER:-sbuser}"
MYSQL_PASS="${MYSQL_PASS:-sbpass}"
MYSQL_DB="${MYSQL_DB:-sbtest}"

TABLES="${TABLES:-16}"
TABLE_SIZE="${TABLE_SIZE:-1000000}"
THREADS="${THREADS:-32}"

# TIME 是探测间隔；RUN_TIME 是单轮压测时长
TIME="${TIME:-1}"
REPORT_INTERVAL="${REPORT_INTERVAL:-${TIME}}" # 默认与 TIME 保持一致
RUN_TIME="${RUN_TIME:-60}"
RUNS="${RUNS:-3}"

SYSBENCH_BIN="${SYSBENCH_BIN:-sysbench}"
SYSBENCH_LUA_DIR="${SYSBENCH_LUA_DIR:-/usr/share/sysbench}" # oltp_read_write.lua 所在目录
NUMACTL_BIN="${NUMACTL_BIN:-numactl}"
SYSBENCH_PERCENTILE="${SYSBENCH_PERCENTILE:-99}" # 用于输出 P99 延迟

OUT_DIR="${OUT_DIR:-./archive}"
CSV_FILE="${CSV_FILE:-$OUT_DIR/oltp_rw_local_numa_cross.csv}" # CSV 结果输出路径
# ----------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }
ts_now() { date +"%F %T"; }
run_id_now() { date +"%Y%m%d_%H%M%S"; }

NUMA_CPU_NODE=""     # 解析出的 MySQL CPU 节点
NUMA_MEM_NODE=""     # 解析出的 MySQL MEM 节点
MYSQL_CPUS=""        # MySQL 容器 CPU 列表
MYSQL_MEMS=""        # MySQL 容器 MEM 节点列表
SYSBENCH_CPU_NODE="" # sysbench CPU 节点（按规则推导）
SYSBENCH_MEM_NODE="" # sysbench MEM 节点（按规则推导）
SYSBENCH_CPUS=""     # sysbench CPU 列表
SYSBENCH_MEMS=""     # sysbench MEM 节点列表

# 从多个路径中读取第一个非空值（用于 cgroup cpuset.mems 识别）
read_first_nonempty() {
  local path value
  for path in "$@"; do
    [[ -r "$path" ]] || continue
    value="$(tr -d '[:space:]' < "$path")"
    [[ -n "$value" ]] && { echo "$value"; return 0; }
  done
  return 1
}

# 判断 mem 列表是否包含某个节点（支持 0-3,5 这种格式）
mems_contains() {
  local list="$1" node="$2" token start end
  local IFS=,
  for token in $list; do
    if [[ "$token" == *-* ]]; then
      start="${token%-*}"
      end="${token#*-}"
      if [[ "$node" -ge "$start" && "$node" -le "$end" ]]; then
        return 0
      fi
    else
      if [[ "$node" -eq "$token" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

# 获取 docker service 在 cgroup 中允许的 mem 节点列表
get_docker_allowed_mems() {
  read_first_nonempty \
    /sys/fs/cgroup/system.slice/docker.service/cpuset.mems.effective \
    /sys/fs/cgroup/system.slice/docker.service/cpuset.mems \
    /sys/fs/cgroup/system.slice/cpuset.mems.effective \
    /sys/fs/cgroup/system.slice/cpuset.mems \
    /sys/fs/cgroup/cpuset.mems.effective \
    /sys/fs/cgroup/cpuset.mems
}

# 校验内存节点是否在线
validate_online_mem_node() {
  local mem_node="$1" online
  if [[ -r /sys/devices/system/node/online ]]; then
    online="$(tr -d '[:space:]' < /sys/devices/system/node/online)"
    if ! mems_contains "$online" "$mem_node"; then
      die "MEM node ${mem_node} not online (online: ${online})"
    fi
  fi
}

# 校验 docker cgroup 允许的内存节点（避免 cpuset.mems 被限制）
validate_docker_mem_node() {
  local mem_node="$1" allowed
  validate_online_mem_node "$mem_node"

  allowed="$(get_docker_allowed_mems || true)"
  if [[ -n "$allowed" ]]; then
    if ! mems_contains "$allowed" "$mem_node"; then
      die "MEM node ${mem_node} not allowed by docker cgroup (allowed: ${allowed})"
    fi
  fi
}

# 解析 NUMA_PROFILE，并生成 MySQL / sysbench 绑定规则
resolve_numa_profile() {
  local profile="$1"
  local cpu_node mem_node cpu_var mem_var
  local mysql_cpus mysql_mems sys_cpu_node sys_mem_node sys_cpu_var sys_mem_var sys_cpus sys_mems

  if [[ "$profile" =~ ^node([0-9]+)_mem([0-9]+)$ ]]; then
    cpu_node="${BASH_REMATCH[1]}"
    mem_node="${BASH_REMATCH[2]}"
  else
    die "Unsupported NUMA_PROFILE=${profile}. Use nodeX_memY (X/Y integers)"
  fi

  cpu_var="CPUSET_NODE${cpu_node}"
  mysql_cpus="${!cpu_var-}"
  [[ -n "$mysql_cpus" ]] || die "CPU list not set for ${cpu_var}. Export ${cpu_var}=<cpu list>"

  mem_var="MEMSET_NODE${mem_node}"
  if [[ -n "${!mem_var-}" ]]; then
    mysql_mems="${!mem_var}"
  else
    mysql_mems="$mem_node"
  fi

  # sysbench 绑定规则：
  # - X != Y：CPU=Y，MEM=Y
  # - X == Y：CPU=1，MEM=1
  if [[ "$cpu_node" == "$mem_node" ]]; then
    sys_cpu_node="1"
    sys_mem_node="1"
  else
    sys_cpu_node="$mem_node"
    sys_mem_node="$mem_node"
  fi

  sys_cpu_var="CPUSET_NODE${sys_cpu_node}"
  sys_cpus="${!sys_cpu_var-}"
  [[ -n "$sys_cpus" ]] || die "CPU list not set for ${sys_cpu_var}. Export ${sys_cpu_var}=<cpu list>"

  sys_mem_var="MEMSET_NODE${sys_mem_node}"
  if [[ -n "${!sys_mem_var-}" ]]; then
    sys_mems="${!sys_mem_var}"
  else
    sys_mems="$sys_mem_node"
  fi

  NUMA_CPU_NODE="$cpu_node"
  NUMA_MEM_NODE="$mem_node"
  MYSQL_CPUS="$mysql_cpus"
  MYSQL_MEMS="$mysql_mems"
  SYSBENCH_CPU_NODE="$sys_cpu_node"
  SYSBENCH_MEM_NODE="$sys_mem_node"
  SYSBENCH_CPUS="$sys_cpus"
  SYSBENCH_MEMS="$sys_mems"
}

# 从 sysbench 输出里提取 TPS（transactions per second）
extract_tps() {
  local file="$1"
  awk '/transactions:/{v=$(NF-2); gsub(/[()]/,"",v); print v}' "$file" | tail -n1 2>/dev/null || true
}

# 从 sysbench 输出里提取 QPS（queries per second）
extract_qps() {
  local file="$1"
  awk '/queries:/{v=$(NF-2); gsub(/[()]/,"",v); print v}' "$file" | tail -n1 2>/dev/null || true
}

# 从 sysbench 输出里提取 P99 延迟（ms）
extract_p99() {
  local file="$1"
  awk '/99th percentile:/{print $(NF)}' "$file" | tail -n1 2>/dev/null || true
}

# 初始化 CSV 头（含 P99 列）
write_header() {
  if [[ ! -f "${CSV_FILE}" ]]; then
    echo "run_id,timestamp,numa_profile,iteration,status,tps,qps,p99_latency_ms,threads,run_time_s,report_interval_s,tables,table_size,mysql_host,mysql_port,mysql_cpu_node,mysql_mem_node,sysbench_cpu_node,sysbench_mem_node" > "${CSV_FILE}"
  fi
}

# 启动/重建 MySQL 容器（仅做 cpuset 绑定）
start_mysql_container() {
  # MySQL 容器只做 NUMA 绑定，不做 numactl（依赖 docker 的 cpuset）
  local numa_args=(
    "--cpuset-cpus=${MYSQL_CPUS}"
    "--cpuset-mems=${MYSQL_MEMS}"
  )

  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "[INFO] Stopping old container ${CONTAINER_NAME} ..."
    docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    echo "[INFO] Removing old container ${CONTAINER_NAME} ..."
    docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi

  if ! docker volume ls --format '{{.Name}}' | grep -qx "${DATA_VOLUME}"; then
    echo "[INFO] Creating volume ${DATA_VOLUME} ..."
    docker volume create "${DATA_VOLUME}" >/dev/null
  fi

  echo "[INFO] Starting MySQL container with NUMA args: ${numa_args[*]}"
  docker run -d --name "${CONTAINER_NAME}" \
    "${numa_args[@]}" \
    -p "${HOST_PORT}:3306" \
    -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
    -v "${DATA_VOLUME}:/var/lib/mysql" \
    -v "${MYCNF}:/etc/mysql/conf.d/my.cnf:ro" \
    --restart unless-stopped \
    "${MYSQL_IMAGE}" >/dev/null

  echo "[INFO] Waiting for MySQL ready..."
  for i in {1..60}; do
    if docker exec "${CONTAINER_NAME}" mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" >/dev/null 2>&1; then
      echo "[OK] MySQL is ready."
      return 0
    fi
    sleep 1
  done

  echo "[WARN] MySQL not ready after 60s, check logs:"
  echo "       docker logs ${CONTAINER_NAME} | tail -n 50"
  exit 1
}

# 执行单轮 sysbench，输出日志并解析 TPS/QPS/P99
run_sysbench_iteration() {
  local iteration="$1" run_id="$2"
  local ts out_file rc status tps qps p99

  ts="$(ts_now)"
  out_file="${OUT_DIR}/${run_id}_${NUMA_PROFILE}_run${iteration}_oltp_read_write.log"
  echo "-> Running sysbench iter ${iteration}/${RUNS}"

  set +e
  # sysbench 通过 numactl 绑定 CPU/内存，实现与 MySQL 交叉 NUMA
  "${NUMACTL_BIN}" --physcpubind="${SYSBENCH_CPUS}" --membind="${SYSBENCH_MEMS}" \
    "${SYSBENCH_BIN}" "${SYSBENCH_LUA_DIR}/oltp_read_write.lua" \
      --mysql-host="${MYSQL_HOST}" \
      --mysql-port="${MYSQL_PORT}" \
      --mysql-user="${MYSQL_USER}" \
      --mysql-password="${MYSQL_PASS}" \
      --mysql-db="${MYSQL_DB}" \
      --tables="${TABLES}" \
      --table-size="${TABLE_SIZE}" \
      --threads="${THREADS}" \
      --time="${RUN_TIME}" \
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

  echo "${run_id},${ts},${NUMA_PROFILE},${iteration},${status},${tps},${qps},${p99},${THREADS},${RUN_TIME},${REPORT_INTERVAL},${TABLES},${TABLE_SIZE},${MYSQL_HOST},${MYSQL_PORT},${NUMA_CPU_NODE},${NUMA_MEM_NODE},${SYSBENCH_CPU_NODE},${SYSBENCH_MEM_NODE}" >> "${CSV_FILE}"
  echo "Log: ${out_file}"
  echo
}

main() {
  # 运行前置检查（必要工具/文件）
  [[ -f "$MYCNF" ]] || die "my.cnf not found: $MYCNF"

  command -v docker >/dev/null 2>&1 || die "docker not found"
  command -v "${SYSBENCH_BIN}" >/dev/null 2>&1 || die "sysbench not found: ${SYSBENCH_BIN}"
  command -v "${NUMACTL_BIN}" >/dev/null 2>&1 || die "numactl not found: ${NUMACTL_BIN}"
  [[ -f "${SYSBENCH_LUA_DIR}/oltp_read_write.lua" ]] || die "oltp_read_write.lua not found in ${SYSBENCH_LUA_DIR}"

  # 解析 NUMA_PROFILE 并校验节点可用性
  resolve_numa_profile "$NUMA_PROFILE"
  validate_docker_mem_node "$NUMA_MEM_NODE"
  validate_online_mem_node "$SYSBENCH_MEM_NODE"

  echo "=== Local NUMA cross test ==="
  echo "NUMA_PROFILE   : ${NUMA_PROFILE}"
  echo "MySQL CPU node : ${NUMA_CPU_NODE} (${MYSQL_CPUS})"
  echo "MySQL MEM node : ${NUMA_MEM_NODE} (${MYSQL_MEMS})"
  echo "SB  CPU node   : ${SYSBENCH_CPU_NODE} (${SYSBENCH_CPUS})"
  echo "SB  MEM node   : ${SYSBENCH_MEM_NODE} (${SYSBENCH_MEMS})"
  echo "MySQL target   : ${MYSQL_USER}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
  echo "Runs/Iter      : ${RUNS} iterations, threads=${THREADS}, run_time=${RUN_TIME}s, report_interval=${REPORT_INTERVAL}s"
  echo "CSV output     : ${CSV_FILE}"
  echo

  # 重建 MySQL 容器（保持数据卷）
  start_mysql_container

  # 准备输出目录与 CSV 头
  mkdir -p "${OUT_DIR}"
  write_header

  local run_id
  run_id="$(run_id_now)"

  # 按 RUNS 迭代执行压测
  for i in $(seq 1 "${RUNS}"); do
    run_sysbench_iteration "${i}" "${run_id}"
  done

  echo "All done. CSV appended: ${CSV_FILE}"
}

main "$@"
