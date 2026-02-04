正常清空缓存
每单轮压测都会清空一次 os page cache

```bash
sync
echo 3 | sudo tee /proc/sys/vm/drop_caches
docker restart mysql8030
```



```python

python3 plot_oltp_rw_local_numa_cross_compare.py \
  --csv csv_clear/oltp_rw_local_numa_cross.csv \
  --output csv_clear/oltp_rw_local_numa_cross_compare.png



python3 plot_oltp_rw_local_numa_cross_compare_zoomed.py \
  --csv csv_clear/oltp_rw_local_numa_cross.csv \
  --output csv_clear/oltp_rw_local_numa_cross_compare_zoom.png \
  --pad-ratio 0.2

```