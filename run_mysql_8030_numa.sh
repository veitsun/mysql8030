#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Recreate MySQL 8.0.30 Docker container with NUMA binding.
# - Keeps data by default (docker volume).
# - Allows "nodeX_memY" profile selection.
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

# Map: MEM-node -> cpuset mem node id for Docker --cpuset-mems
MEMSET_NODE0="0"
MEMSET_NODE1="1"
# ----------------------------------------------------------------------------

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

main() {
  [[ -f "$MYCNF" ]] || die "my.cnf not found: $MYCNF"

  echo "=== Recreate MySQL 8.0.30 with NUMA binding ==="
  echo "Container      : ${CONTAINER_NAME}"
  echo "Image          : ${MYSQL_IMAGE}"
  echo "Port           : ${HOST_PORT}->3306"
  echo "Data Volume    : ${DATA_VOLUME} (kept)"
  echo "my.cnf         : ${MYCNF}"
  echo "NUMA_PROFILE   : ${NUMA_PROFILE}"
  echo "CPUSET_NODE0   : ${CPUSET_NODE0}"
  echo "CPUSET_NODE1   : ${CPUSET_NODE1}"
  echo

  local numa_args
  numa_args="$(get_numa_args "$NUMA_PROFILE")"

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

  echo "[INFO] Starting new container with NUMA args: ${numa_args}"
  # shellcheck disable=SC2086
  docker run -d --name "${CONTAINER_NAME}" \
    ${numa_args} \
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
