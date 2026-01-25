#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Recreate MySQL 8.0.30 Docker container with NUMA binding.
# If MEM node is memory-only, allow CPU+MEM nodes in cpuset.mems and start
# mysqld under numactl --membind=<mem node>.
###############################################################################

# --------------------------- Config (edit) -----------------------------------
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0.30}"
CONTAINER_NAME="${CONTAINER_NAME:-mysql8030}"
HOST_PORT="${HOST_PORT:-3306}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-sunwei}"

# Data persistence: Docker volume
DATA_VOLUME="${DATA_VOLUME:-mysql8030_data}"

# MySQL config file on host (must exist)
MYCNF="${MYCNF:-./conf/my.cnf}"

# ---- NUMA selection: just change this ----
NUMA_PROFILE="${NUMA_PROFILE:-node0_mem0}"

# Map: CPU-node -> CPU list for Docker --cpuset-cpus
CPUSET_NODE0="${CPUSET_NODE0:-0-31}"
CPUSET_NODE1="${CPUSET_NODE1:-32-63}"
# Add CPUSET_NODE2/3/... via env as needed, e.g.:
# CPUSET_NODE2="64-95" CPUSET_NODE3="96-127"

# Map: MEM-node -> cpuset mem node id for Docker --cpuset-mems
# If MEMSET_NODEx is not set, it defaults to x.
MEMSET_NODE0="${MEMSET_NODE0:-0}"
MEMSET_NODE1="${MEMSET_NODE1:-1}"

# Paths inside the container (override if your image differs)
NUMACTL_BIN="${NUMACTL_BIN:-/usr/bin/numactl}"
ENTRYPOINT_BIN="${ENTRYPOINT_BIN:-/usr/local/bin/docker-entrypoint.sh}"
# ----------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

NUMA_CPU_NODE=""
NUMA_MEM_NODE=""
NUMA_CPUS=""
NUMA_MEMS=""
MEM_NODE_MEMORY_ONLY=0
MEMORY_ONLY_NODES=""
USE_NUMACTL=0
NUMACTL_MEMBIND=""

read_first_nonempty() {
  local path value
  for path in "$@"; do
    [[ -r "$path" ]] || continue
    value="$(tr -d '[:space:]' < "$path")"
    [[ -n "$value" ]] && { echo "$value"; return 0; }
  done
  return 1
}

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

ensure_mems_include_node() {
  local list="$1" node="$2"
  if mems_contains "$list" "$node"; then
    echo "$list"
  elif [[ -z "$list" ]]; then
    echo "$node"
  else
    echo "${list},${node}"
  fi
}

get_allowed_mems() {
  read_first_nonempty \
    /sys/fs/cgroup/system.slice/docker.service/cpuset.mems.effective \
    /sys/fs/cgroup/system.slice/docker.service/cpuset.mems \
    /sys/fs/cgroup/system.slice/cpuset.mems.effective \
    /sys/fs/cgroup/system.slice/cpuset.mems \
    /sys/fs/cgroup/cpuset.mems.effective \
    /sys/fs/cgroup/cpuset.mems
}

validate_mem_node() {
  local mem_node="$1" online allowed
  if [[ -r /sys/devices/system/node/online ]]; then
    online="$(tr -d '[:space:]' < /sys/devices/system/node/online)"
    if ! mems_contains "$online" "$mem_node"; then
      die "MEM node ${mem_node} not online (online: ${online})"
    fi
  fi

  allowed="$(get_allowed_mems || true)"
  if [[ -n "$allowed" ]]; then
    if ! mems_contains "$allowed" "$mem_node"; then
      die "MEM node ${mem_node} not allowed by cgroup (allowed: ${allowed})"
    fi
  fi
}

is_memory_only_node() {
  local node="$1"
  local cpulist_path="/sys/devices/system/node/node${node}/cpulist"
  [[ -r "$cpulist_path" ]] || return 1
  [[ -z "$(tr -d '[:space:]' < "$cpulist_path")" ]]
}

get_memory_only_nodes() {
  local node_dir node nodes=()
  for node_dir in /sys/devices/system/node/node[0-9]*; do
    node="${node_dir##*node}"
    if is_memory_only_node "$node"; then
      nodes+=("$node")
    fi
  done
  if ((${#nodes[@]})); then
    local IFS=,
    echo "${nodes[*]}"
  fi
}

resolve_numa_profile() {
  local profile="$1"
  local cpu_node mem_node cpus mems cpu_var mem_var

  if [[ "$profile" =~ ^node([0-9]+)_mem([0-9]+)$ ]]; then
    cpu_node="${BASH_REMATCH[1]}"
    mem_node="${BASH_REMATCH[2]}"
  else
    die "Unsupported NUMA_PROFILE=${profile}. Use nodeX_memY (X/Y integers)"
  fi

  cpu_var="CPUSET_NODE${cpu_node}"
  cpus="${!cpu_var-}"
  [[ -n "$cpus" ]] || die "CPU list not set for ${cpu_var}. Export ${cpu_var}=<cpu list>"

  mem_var="MEMSET_NODE${mem_node}"
  if [[ -n "${!mem_var-}" ]]; then
    mems="${!mem_var}"
  else
    mems="$mem_node"
  fi

  NUMA_CPU_NODE="$cpu_node"
  NUMA_MEM_NODE="$mem_node"
  NUMA_CPUS="$cpus"
  NUMA_MEMS="$mems"
}

get_numa_args() {
  echo "--cpuset-cpus=${NUMA_CPUS} --cpuset-mems=${NUMA_MEMS}"
}

check_numactl_in_image() {
  docker run --rm --entrypoint /bin/sh "${MYSQL_IMAGE}" \
    -c "command -v ${NUMACTL_BIN} >/dev/null 2>&1"
}

main() {
  [[ -f "$MYCNF" ]] || die "my.cnf not found: $MYCNF"

  echo "=== Recreate MySQL 8.0.30 with NUMA binding (membind mode) ==="
  echo "Container      : ${CONTAINER_NAME}"
  echo "Image          : ${MYSQL_IMAGE}"
  echo "Port           : ${HOST_PORT}->3306"
  echo "Data Volume    : ${DATA_VOLUME} (kept)"
  echo "my.cnf         : ${MYCNF}"
  echo "NUMA_PROFILE   : ${NUMA_PROFILE}"
  echo

  resolve_numa_profile "$NUMA_PROFILE"
  validate_mem_node "$NUMA_MEM_NODE"
  MEMORY_ONLY_NODES="$(get_memory_only_nodes || true)"
  if [[ -n "$MEMORY_ONLY_NODES" ]]; then
    echo "Memory-only nodes : ${MEMORY_ONLY_NODES}"
  else
    echo "Memory-only nodes : (none)"
  fi

  if is_memory_only_node "$NUMA_MEM_NODE"; then
    MEM_NODE_MEMORY_ONLY=1
    NUMA_MEMS="$(ensure_mems_include_node "$NUMA_MEMS" "$NUMA_MEM_NODE")"
    NUMA_MEMS="$(ensure_mems_include_node "$NUMA_MEMS" "$NUMA_CPU_NODE")"
    USE_NUMACTL=1
    NUMACTL_MEMBIND="$NUMA_MEM_NODE"
    echo "[INFO] MEM node ${NUMA_MEM_NODE} is memory-only; cpuset.mems -> ${NUMA_MEMS}"
    echo "[INFO] Will start mysqld with: numactl --membind=${NUMACTL_MEMBIND}"
    validate_mem_node "$NUMA_CPU_NODE"
  fi

  echo "CPU node       : ${NUMA_CPU_NODE}"
  echo "MEM node       : ${NUMA_MEM_NODE}"
  echo "CPUSET_NODE${NUMA_CPU_NODE} : ${NUMA_CPUS}"
  echo "cpuset.mems    : ${NUMA_MEMS}"
  echo

  local numa_args
  numa_args="$(get_numa_args)"

  # Stop & remove old container if exists
  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "[INFO] Stopping old container ${CONTAINER_NAME} ..."
    docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    echo "[INFO] Removing old container ${CONTAINER_NAME} ..."
    docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi

  # Ensure volume exists
  if ! docker volume ls --format '{{.Name}}' | grep -qx "${DATA_VOLUME}"; then
    echo "[INFO] Creating volume ${DATA_VOLUME} ..."
    docker volume create "${DATA_VOLUME}" >/dev/null
  fi

  local entrypoint_args=()
  local cmd_args=()
  if ((USE_NUMACTL)); then
    if ! check_numactl_in_image; then
      die "numactl not found in image ${MYSQL_IMAGE}. Install numactl or use a custom image."
    fi
    entrypoint_args=(--entrypoint "${NUMACTL_BIN}")
    cmd_args=(--membind="${NUMACTL_MEMBIND}" "${ENTRYPOINT_BIN}" mysqld)
  fi

  echo "[INFO] Starting new container with NUMA args: ${numa_args}"
  if ((USE_NUMACTL)); then
    echo "[INFO] EntryPoint : ${NUMACTL_BIN}"
    echo "[INFO] Command    : numactl --membind=${NUMACTL_MEMBIND} ${ENTRYPOINT_BIN} mysqld"
  fi

  # shellcheck disable=SC2086
  docker run -d --name "${CONTAINER_NAME}" \
    ${numa_args} \
    -p "${HOST_PORT}:3306" \
    -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
    -v "${DATA_VOLUME}:/var/lib/mysql" \
    -v "${MYCNF}:/etc/mysql/conf.d/my.cnf:ro" \
    --restart unless-stopped \
    "${entrypoint_args[@]}" \
    "${MYSQL_IMAGE}" \
    "${cmd_args[@]}" >/dev/null

  echo "[INFO] Waiting for MySQL ready..."
  for i in {1..60}; do
    if docker exec "${CONTAINER_NAME}" mysqladmin ping -uroot -p"${MYSQL_ROOT_PASSWORD}" >/dev/null 2>&1; then
      echo "[OK] MySQL is ready."
      break
    fi
    sleep 1
    if [[ $i -eq 60 ]]; then
      echo "[WARN] MySQL not ready after 60s, check logs:"
      echo "       docker logs ${CONTAINER_NAME} | tail -n 50"
      exit 1
    fi
  done

  echo "[INFO] MySQL version:"
  docker exec "${CONTAINER_NAME}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT VERSION();"
}

main "$@"
