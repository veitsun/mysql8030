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
mkdir -p ~/mysql8030/{data,conf,log}

```

### 2.2 写配置文件（无需 sudo）

```bash
cat > ~/mysql8030/conf/my.cnf <<'EOF'
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

### 2.3 运行 MySQL 容器（无需 sudo）

```bash

docker run -d --name mysql8030 \
  -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD='RootPass!123' \
  -v "$HOME/mysql8030/data:/var/lib/mysql" \
  -v "$HOME/mysql8030/conf/my.cnf:/etc/mysql/conf.d/my.cnf:ro" \
  -v "$HOME/mysql8030/log:/var/log/mysql" \
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


## 4）NUMA 绑核/绑内存：没有 sudo 也可以做（但有条件）

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
  -e MYSQL_ROOT_PASSWORD='RootPass!123' \
  -v mysql8030_data:/var/lib/mysql \
  -v "$HOME/mysql8030/conf/my.cnf:/etc/mysql/conf.d/my.cnf:ro" \
  mysql:8.0.30

```

## 5）测试（无需安装 sysbench）：用 sysbench 容器压 MySQL 容器
如果你能 pull mysql，那么也可以 pull sysbench 镜像：
```bash
docker pull severalnines/sysbench

```

### 5.1 创建测试库/账号
```bash
docker exec -it mysql8030 mysql -uroot -pRootPass\!123 -e "
CREATE DATABASE sbtest;
CREATE USER 'sbuser'@'%' IDENTIFIED BY 'sbpass';
GRANT ALL PRIVILEGES ON sbtest.* TO 'sbuser'@'%';
FLUSH PRIVILEGES;"
```

### 5.2 prepare（灌数据）
在灌数据之前，验证 sbuser 的认证插件确实变成 mysql_native_password
```bash
docker exec -it mysql8030 mysql -uroot -pRootPass\!123 -e "
SELECT user, host, plugin FROM mysql.user WHERE user='sbuser';
"

```

``` text
+--------+------+-----------------------+
| user   | host | plugin                |
+--------+------+-----------------------+
| sbuser | %    | mysql_native_password |
+--------+------+-----------------------+
```

```bash
docker run --rm --network=host severalnines/sysbench \
  sysbench /usr/share/sysbench/oltp_read_write.lua \
  --mysql-host=127.0.0.1 --mysql-port=3306 \
  --mysql-user=sbuser --mysql-password=sbpass --mysql-db=sbtest \
  --tables=16 --table-size=1000000 \
  prepare

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

```

# 本地完整测试脚本
## 0）准备工作（确认 NUMA node 对应 CPU 列表）
```bash
numactl --hardware
```
脚本里默认写的是：
- node0 CPU: 0-31
- node1 CPU: 32-63

根据服务器实际 numa 架构 来确定对应关系。
然后把脚本中的 CPUSET_NODE0 / CPUSET_NODE1 修改为你的实际范围。
也可以不改脚本，直接通过环境变量覆盖：
```bash
CPUSET_NODE0="0-47" CPUSET_NODE1="48-95" ./run_sysbench_suite_numa_tps_qps.sh

```

## 脚本 1：run_mysql_8030_numa.sh（重建 MySQL 容器 + NUMA 绑定）

> 功能：
> - 只要改 NUMA_PROFILE 即可选择 node&mem 组合
> - 自动 stop/rm 旧容器（同名）
> - 默认使用 Docker volume（例如 mysql8030_data）保留数据
> - 支持端口、root密码、my.cnf 挂载
> - 不需要 sudo（前提：你能用 docker）

使用实例：
```
node0 & mem0
NUMA_PROFILE=node0_mem0 ./run_mysql_8030_numa.sh

node1 & mem0（跨 NUMA）
NUMA_PROFILE=node1_mem0 ./run_mysql_8030_numa.sh

node1 & mem1
NUMA_PROFILE=node1_mem1 ./run_mysql_8030_numa.sh
```

## 脚本 2：run_sysbench_suite_numa.sh（跑 workload + 输出 TPS 表格）

> 功能：
> - 支持相同的 NUMA_PROFILE，绑定 sysbench 压测容器 CPU+MEM
> - 跑你指定的 workload
> - 输出 CSV 表格（可追加历史结果对比）
> - 标记 oltp_read_write 为重点（important=1）
> - 保存每个 workload 的完整日志到文件，便于复核

## 推荐执行流程（最标准）
### 用 node0_mem0 启动 MySQL（固定数据库 NUMA）
```bash
chmod +x run_mysql_8030_numa.sh run_sysbench_suite_numa.sh

CPUSET_NODE0="0-13" CPUSET_NODE1="14-27" NUMA_PROFILE=node0_mem0 ./run_mysql_8030_numa.sh

```

### 用不同 NUMA_PROFILE 跑 sysbench（对比压测端 NUMA）
```bash
CPUSET_NODE0="0-13" CPUSET_NODE1="14-27" NUMA_PROFILE=node0_mem0 ./run_sysbench_suite_numa_tps_qps.sh
CPUSET_NODE0="0-13" CPUSET_NODE1="14-27" NUMA_PROFILE=node1_mem0 ./run_sysbench_suite_numa_tps_qps.sh
CPUSET_NODE0="0-13" CPUSET_NODE1="14-27" NUMA_PROFILE=node1_mem1 ./run_sysbench_suite_numa_tps_qps.sh
```

这样你能比较：
- 不同压测端 NUMA 组合对 TPS/抖动的影响
- 如果你也重建 MySQL 容器为不同 NUMA_PROFILE，则可以比较数据库侧 NUMA 影响


---

# 远端压测
## 创建测试库/账号
授权远程用户
MySQL 的 root 在很多镜像默认只允许本地登录，需要创建一个远程账户：
```bash
docker exec -it mysql8030 mysql -uroot -pRootPass\!123 -e "
CREATE DATABASE sbtest;
CREATE USER 'sbuser'@'%' IDENTIFIED BY 'sbpass';
GRANT ALL PRIVILEGES ON sbtest.* TO 'sbuser'@'%';
FLUSH PRIVILEGES;"
```

然后 sysbench 用这个账号做压测

## preapare 灌数据

```bash
docker run --rm --network=host severalnines/sysbench \
  sysbench /usr/share/sysbench/oltp_read_write.lua \
  --mysql-host=127.0.0.1 --mysql-port=3306 \
  --mysql-user=sbuser --mysql-password=sbpass --mysql-db=sbtest \
  --tables=16 --table-size=1000000 \
  prepare

```

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