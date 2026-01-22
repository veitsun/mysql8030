这个数据是在 ndsl 的 231 服务器上测试的

sysbench 是在 235 服务器上
mysql server 在 231 服务器上 （两个 numa node）


1）2个 numa node 测出来单实例 mysqld 的TPS差异非常小（请看图1和图2），不知道是因为什么。
2) 上面测得的数据是基于压测数据量是 buffer pool 大 1.3 倍基础上测出来的。如果将压测数据量调到 buffer pool 的 2- 3 倍，在按顺序压测之后(高并发下)，会出现本地节点的 tps 比跨节点 更低的现象（压测越久，tps 反而变大）