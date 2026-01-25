# 本地简单测试

## 0）确认自己是否可以使用 docker

```bash
docker version
docker ps
```
- 如果 docker ps 能正常输出（即便为空列表），说明可以用 docker。
- 如果报错 permission denied / Got permission denied while trying to connect to the Docker daemon socket，说明你没有权限使用 Docker，这种情况下无法在本机直接跑 Docker，只能让管理员把你加入 docker 组或提供 rootless docker/podman。

## 1） 拉取 MySQL 8.0.30 镜像

```bash
docker pull mysql:8.0.30
```

## 2） 用自己的 HOME 目录做 bind mount （宿主机持久化目录）

### 2.1 在 $HOME 下创建目录（无需 sudo）

```bash
mkdir -p ./{data,conf,log}

```

### 2.2 写配置文件

```bash
cat > ./conf/my.cnf <<'EOF'
[mysqld]
port=3306
bind-address=0.0.0.0
skip-name-resolve=ON

character-set-server=utf8mb4
collation-server=utf8mb4_0900_ai_ci

innodb_buffer_pool_size=2G
innodb_log_file_size=512M
innodb_flush_log_at_trx_commit=1
sync_binlog=1

max_connections=2000
EOF


```

### 2.3 运行 MySQL 容器

```bash

docker run -d --name mysql8030 \
  -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD='sunwei' \
  -v "./data:/var/lib/mysql" \
  -v "./conf/my.cnf:/etc/mysql/conf.d/my.cnf:ro" \
  -v "./log:/var/log/mysql" \
  --user "$(id -u):$(id -g)" \
  mysql:8.0.30
```

## 3） 验证 MySql 正常启动

```bash
docker logs -f mysql8030

```
看到类似下面的正确启动标志：
**ready for connections. Version: '8.0.30' ... port: 3306**
映射端口在 3306 （**MySQL 正常启动并监听 3306 端口。**）


## 4）NUMA 绑核/绑内存

如果你有权限用 docker 跑容器，一般也能用：
- --cpuset-cpus
- --cpuset-mems

例如固定在 node0：

先停止并删除旧容器
docker stop mysql8030
docker rm mysql8030
> 注意：这只是删除“容器”，不会删除 volume 或你挂载的宿主机数据目录（除非你加 -v）。

```bash

docker run -d --name mysql8030 \
  --cpuset-cpus="0-31" \
  --cpuset-mems="0" \
  -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD='sunwei' \
  -v mysql8030_data:/var/lib/mysql \
  -v "./conf/my.cnf:/etc/mysql/conf.d/my.cnf:ro" \
  mysql:8.0.30

```

## 5）压测:  用 sysbench 容器 压测 MySQL 容器
如果你能 pull mysql，那么也可以 pull sysbench 镜像：
```bash
docker pull severalnines/sysbench

```

### 5.1 创建测试库/账号
```bash
docker exec -it mysql8030 mysql -uroot -psunwei -e "
CREATE DATABASE IF NOT EXISTS sbtest;
CREATE USER IF NOT EXISTS 'sbuser'@'%' IDENTIFIED WITH mysql_native_password BY 'sbpass';
GRANT ALL PRIVILEGES ON sbtest.* TO 'sbuser'@'%';
FLUSH PRIVILEGES;"
```

### 5.2 prepare（灌数据）
在灌数据之前，验证 sbuser 的认证插件确实变成 mysql_native_password
```bash
docker exec -it mysql8030 mysql -uroot -psunwei -e "
SELECT user, host, plugin FROM mysql.user WHERE user='sbuser';"

```

``` text
+--------+------+-----------------------+
| user   | host | plugin                |
+--------+------+-----------------------+
| sbuser | %    | mysql_native_password |
+--------+------+-----------------------+
```
灌入数据：
```bash
docker run --rm --network=host severalnines/sysbench \
  sysbench /usr/share/sysbench/oltp_read_write.lua \
  --mysql-host=127.0.0.1 --mysql-port=3306 \
  --mysql-user=sbuser --mysql-password=sbpass --mysql-db=sbtest \
  --tables=16 --table-size=1000000 \
  prepare


# 不走 docker
sysbench /usr/share/sysbench/oltp_read_write.lua   --mysql-host=100.111.254.126 --mysql-port=3306   --mysql-user=sbuser --mysql-password=sbpass --mysql-db=sbtest   --tables=16 --table-size=1000000   prepare

```
清理数据：
```bash
sysbench /usr/share/sysbench/oltp_read_write.lua \
  --mysql-host=100.111.254.126 --mysql-port=3306 \
  --mysql-user=sbuser --mysql-password=sbpass --mysql-db=sbtest \
  --tables=16 --table-size=1000000 \
  cleanup

```

刚灌入数据之后，建议把 os page cache 和 buffer pool清理一下：
```bash
# 会影响业务
sync
echo 3 | sudo tee /proc/sys/vm/drop_caches
#重启
docker restart mysql8030
```

### 5.3 oltp_read_write TPS 测试

```bash
docker run --rm --network=host severalnines/sysbench \
  sysbench /usr/share/sysbench/oltp_read_write.lua \
  --mysql-host=127.0.0.1 --mysql-port=3306 \
  --mysql-user=sbuser --mysql-password=sbpass --mysql-db=sbtest \
  --tables=16 --table-size=1000000 \
  --threads=32 --time=60 --report-interval=1 \
  run

# 不走 docker
sysbench /usr/share/sysbench/oltp_read_write.lua \
  --mysql-host=100.111.254.126 --mysql-port=3306 \
  --mysql-user=sbuser --mysql-password=sbpass --mysql-db=sbtest \
  --tables=16 --table-size=1000000 \
  --threads=32 --time=60 --report-interval=1 \
  --db-driver=mysql \
  run


```

# 本地完整测试脚本
## 0）准备工作（确认 NUMA node 对应 CPU 列表）
```bash
numactl --hardware
```
脚本里默认写的是：
- node0 CPU: 0-31
- node1 CPU: 32-63
- 其他 node 需要通过 CPUSET_NODEx 环境变量提供

根据服务器实际 numa 架构 来确定对应关系。
 CPUSET_NODE0 / CPUSET_NODE1 修改为你的实际范围；node2+ 用 CPUSET_NODEx 指定。
直接通过环境变量覆盖：
```bash
CPUSET_NODE0="0-47" CPUSET_NODE1="48-95" ./run_sysbench_suite_numa_tps_qps.sh

```

## 脚本：run_mysql_8030_numa.sh（重建 MySQL 容器 + NUMA 绑定）

> 功能：
> - 通过 NUMA_PROFILE=nodeX_memY 选择 CPU node / MEM node（X/Y 为整数）
> - CPU node 需要设置 CPUSET_NODEx；MEMSET_NODEy 可选（默认等于 y）
> - 自动 stop/rm 旧容器（同名）
> - 默认使用 Docker volume（例如 mysql8030_data）保留数据
> - 支持端口、root密码、my.cnf 挂载
> - 不需要 sudo（前提：你能用 docker）

使用实例：
```bash
# node3 & mem2（需提供 CPUSET_NODE3）
CPUSET_NODEx="96-127" NUMA_PROFILE=node3_mem2 ./run_mysql_8030_numa.sh

# 对于 126 服务器：

CPUSET_NODE0="0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46" CPUSET_NODE1="1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47" CPUSET_NODE3="" NUMA_PROFILE=node0_mem3 ./run_mysql_8030_numa.sh
```

---

# 远端压测
## 远端压测，基本命令

### 启动数据库
指定 NUMA profile 运行 (MySQL服务启动在 231 的服务器上) (InnoDB buffer pool 的 NUMA 绑定，发生在 MySQL 服务器进程 上，
跟 sysbench 端一毛钱关系都没有。)

这里已经开始做内存亲和性绑定
```bash
CPUSET_NODE0="0-27" CPUSET_NODE1="28-55" NUMA_PROFILE=node0_mem0 ./run_mysql_8030_numa.sh
```
这个脚本在做什么：
> 删掉旧的 MySQL 容器 → 保留数据 → 按指定 NUMA 节点绑 CPU 和内存 → 启动一个新的 MySQL 8.0.30 容器 → 等它起来

### sysbench压测，单次测试
在运行 sysbench 做压测前，需要保证做压测的数据存在。我们之前已经 prepare 了数据
--rm 容器运行完了之后会自动删除，但数据库里的表还在，除非执行 cleanup


```bash
docker run --rm severalnines/sysbench \
  sysbench oltp_read_write \
    --db-driver=mysql \
    --mysql-host=192.168.1.231 \
    --mysql-port=3306 \
    --mysql-user=sbuser \
    --mysql-password='sbpass' \
    --mysql-db=sbtest \
    --tables=16 \
    --table-size=1000000 \
    --threads=32 \
    --time=60 \
    --report-interval=1 \
    run
```


### run_sysbench_oltp_rw_remote 脚本

```bash

chmod +x run_sysbench_oltp_rw_remote.sh

MYSQL_HOST=192.168.1.231 MYSQL_PORT=3306 MYSQL_USER=sbuser MYSQL_PASS=sbpass \
THREADS=32 TIME=60 RUNS=3 \
./run_sysbench_oltp_rw_remote.sh


```
## 远端压测脚本，并对比图

用法（远端 MySQL 已按对应 NUMA_PROFILE 启动好后再跑）
记得在每次压测前，先在 远端 mysql主机 上按对应 NUMA_PROFILE 重新启动 MySQL，然后再执行脚本记录该场景数据。

```bash
# 在 远端 mysql 主机上（我这里在 231 上）
CPUSET_NODE0="0-27" CPUSET_NODE1="28-55" NUMA_PROFILE=node0_mem0 ./run_mysql_8030_numa.sh

# 覆盖场景标签和 MySQL NUMA 绑定，建议一次跑一个场景，远端 MySQL 手动切换后再跑下一次
SCENARIOS="node0_mem0" \
MYSQL_HOST=192.168.1.231 MYSQL_PORT=3306 MYSQL_USER=sbuser MYSQL_PASS=sbpass MYSQL_DB=sbtest \
THREADS=32 TIME=60 RUNS=3 TABLES=16 TABLE_SIZE=1000000 \
./run_sysbench_oltp_rw_remote_numa_compare.sh


# 在 远端 mysql 主机上（我这里在 231 上）
CPUSET_NODE0="0-27" CPUSET_NODE1="28-55" NUMA_PROFILE=node0_mem1 ./run_mysql_8030_numa.sh

# 切换远端 MySQL 为 node0_mem1 后，再跑一次，这次跑的结果是追加到 oltp_rw_remote_numa_compare.csv 这个文件中，每个场景多轮的 log 文件在同目录
SCENARIOS="node0_mem1" \
MYSQL_HOST=192.168.1.231 MYSQL_PORT=3306 MYSQL_USER=sbuser MYSQL_PASS=sbpass MYSQL_DB=sbtest \
THREADS=32 TIME=60 RUNS=3 TABLES=16 TABLE_SIZE=1000000 \
./run_sysbench_oltp_rw_remote_numa_compare.sh


```


## 远端压测修改并发数，并修改测试数据量，重新做压测 
当前的 innodb_buffer_pool_size=2G

建议的测试参数
- 数据集：至少 ~6–9GB（是 buffer pool 的 3–4.5 倍）。可用 TABLE_SIZE=3000000，16 张表，总行数 48M，粗算 ~9GB。
- 压测线程：64 或 128（提高并发更容易打满内存带宽）。
- 时间：每轮 60–120 秒。

### 重新准备数据
先清理掉旧的 sbtest 数据
```bash
docker run --rm --network=host severalnines/sysbench \
  sysbench /usr/share/sysbench/oltp_read_write.lua \
  --mysql-host=192.168.1.231 --mysql-port=3306 \
  --mysql-user=sbuser --mysql-password=sbpass --mysql-db=sbtest \
  --tables=16 \
  cleanup

```

重新 prepare ，更大的表
```bash
docker run --rm --network=host severalnines/sysbench \
  sysbench /usr/share/sysbench/oltp_read_write.lua \
  --mysql-host=192.168.1.231 --mysql-port=3306 \
  --mysql-user=sbuser --mysql-password=sbpass --mysql-db=sbtest \
  --tables=16 --table-size=3000000 \
  prepare

```

### 压测

```bash
# 远端 MySQL 启动（在 231 上执行）
# 压测命令（在 sysbench 客户端执行，按场景分别跑）

# 本地内存场景：
CPUSET_NODE0="0-27,56-83" CPUSET_NODE1="28-55,84-111" \
NUMA_PROFILE=node0_mem0 ./run_mysql_8030_numa.sh

SCENARIOS="node0_mem0" \
MYSQL_HOST=192.168.1.231 MYSQL_PORT=3306 MYSQL_USER=sbuser MYSQL_PASS=sbpass MYSQL_DB=sbtest \
THREADS=64 TIME=90 RUNS=10 TABLES=16 TABLE_SIZE=3000000 \
./run_sysbench_oltp_rw_remote_numa_compare.sh

# 跨节点场景（MySQL 已切到 node0_mem1 后）：
CPUSET_NODE0="0-27,56-83" CPUSET_NODE1="28-55,84-111" \
NUMA_PROFILE=node0_mem1 ./run_mysql_8030_numa.sh

SCENARIOS="node0_mem1" \
MYSQL_HOST=192.168.1.231 MYSQL_PORT=3306 MYSQL_USER=sbuser MYSQL_PASS=sbpass MYSQL_DB=sbtest \
THREADS=64 TIME=90 RUNS=10 TABLES=16 TABLE_SIZE=3000000 \
./run_sysbench_oltp_rw_remote_numa_compare.sh


```


### 画图

画图(需要  matplotlib )
```python
python3 plot_sysbench_numa_compare.py \
  --csv sysbench_results/oltp_rw_remote_numa_compare.csv \
  --output sysbench_results/oltp_rw_numa_compare.png

```

画图（这个凸显数据对比的差异）
--pad-ratio 是控制纵轴“留白”比例的参数。脚本在根据数据范围设定 y 轴上下界后，会按 (最大均值-最小均值) * pad_ratio（再加一点误差线余量）扩展上下边界。
- 数值越小：越紧贴数据，放大差异，裁掉更多低位区间。
- 数值越大：留白更多，纵轴更宽松，便于避免标注/箭头重叠。默认值 0.25，想更聚焦可试 0.1，如需更多空间可试 0.4

```python
python3 plot_sysbench_numa_compare_zoomed.py --csv sysbench_results/oltp_rw_remote_numa_compare.csv --output sysbench_results/oltp_rw_numa_compare_zoom.png --pad-ratio 0.2
```

## 本地同机 NUMA 交叉压测脚本

脚本：`run_sysbench_oltp_rw_local_numa_cross.sh`

特点：
- MySQL 用 Docker 跑，绑定 CPU=nodeX，内存=nodeY
- sysbench 在宿主机跑：X!=Y 时 CPU/MEM=Y；X==Y 时 CPU/MEM=1
- 每轮结果写入 CSV（含 TPS/QPS/P99），并保留日志

### 用法

```bash
chmod +x run_sysbench_oltp_rw_local_numa_cross.sh

# 例子：MySQL 绑 CPU=node0, MEM=node1；sysbench 绑 CPU=node1, MEM=node1
CPUSET_NODE0="0-31" CPUSET_NODE1="32-63" \
NUMA_PROFILE=node0_mem1 \
MYSQL_USER=sbuser MYSQL_PASS=sbpass MYSQL_DB=sbtest \
THREADS=32 TIME=1 RUN_TIME=60 RUNS=3 TABLES=16 TABLE_SIZE=1000000 \
./run_sysbench_oltp_rw_local_numa_cross.sh

# 示例：偶/奇核分配（按需替换）
0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46
1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47

CPUSET_NODE0="0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46" CPUSET_NODE1="1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47" \
NUMA_PROFILE=node0_mem1 \
MYSQL_USER=sbuser MYSQL_PASS=sbpass MYSQL_DB=sbtest \
THREADS=32 TIME=1 RUN_TIME=60 RUNS=3 TABLES=16 TABLE_SIZE=1000000 \
./run_sysbench_oltp_rw_local_numa_cross.sh

# 例子：X==Y 时，sysbench 绑 node1（CPUSET_NODE1/MEMSET_NODE1）
CPUSET_NODE0="0-31" CPUSET_NODE1="32-63" \
NUMA_PROFILE=node0_mem0 \
MYSQL_USER=sbuser MYSQL_PASS=sbpass MYSQL_DB=sbtest \
THREADS=32 TIME=1 RUN_TIME=60 RUNS=3 TABLES=16 TABLE_SIZE=1000000 \
./run_sysbench_oltp_rw_local_numa_cross.sh
```

### 参数说明（常用）

- NUMA_PROFILE：格式 `nodeX_memY`。MySQL 取 nodeX 的 CPU，nodeY 的内存；sysbench 规则：X!=Y → CPU/MEM=Y，X==Y → CPU/MEM=1。
- CPUSET_NODEx：每个 NUMA node 对应的 CPU 列表（如 `0-31`、`32-63`），请按 `numactl --hardware` 设置。X==Y 时使用 `CPUSET_NODE1`。
- MEMSET_NODEx：每个 NUMA node 对应的内存节点 id（默认等于 x）。X==Y 时使用 `MEMSET_NODE1`。
- MYSQL_USER / MYSQL_PASS / MYSQL_DB：sysbench 连接 MySQL 的账号、密码、库名。
- THREADS：sysbench 并发线程数。
- TIME：sysbench 运行时的 `--report-interval`（每隔多少秒输出一次探测结果）。
- RUN_TIME：sysbench 运行时长（`--time`）。
- RUNS：总共跑多少轮。
- TABLES：表数量。
- TABLE_SIZE：单表行数。
- SYSBENCH_PERCENTILE：sysbench 输出百分位延迟（默认 99，对应 P99）。

### 其他可选参数

- MYSQL_IMAGE / CONTAINER_NAME / HOST_PORT / MYSQL_ROOT_PASSWORD / DATA_VOLUME / MYCNF：MySQL 容器相关配置（同 `run_mysql_8030_numa.sh`）。
- SYSBENCH_BIN / SYSBENCH_LUA_DIR / NUMACTL_BIN：sysbench、lua 脚本、numactl 的路径。
- OUT_DIR / CSV_FILE：输出目录和 CSV 文件路径。

### 脚本执行流程（详细注释版）

1. 解析 `NUMA_PROFILE`，确定 MySQL 的 CPU/MEM 绑定；按规则确定 sysbench 的 CPU/MEM 绑定。
2. 校验 NUMA 节点是否在线，以及 docker cgroup 是否允许对应的内存节点。
3. 停止并重建 MySQL 容器，使用 `--cpuset-cpus/--cpuset-mems` 做 NUMA 绑定。
4. 通过 `numactl --physcpubind/--membind` 运行 sysbench，并记录日志。
5. 从日志中解析 TPS/QPS/P99，写入 CSV。

### CSV 字段说明

- tps/qps：从 sysbench 输出解析的每秒事务/查询。
- p99_latency_ms：`99th percentile`（毫秒），由 `SYSBENCH_PERCENTILE` 控制。
- status：`ok/no_tps/no_qps/no_p99/failed` 等状态标记。
