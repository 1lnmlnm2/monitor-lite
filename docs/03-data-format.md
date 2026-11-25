# 03 数据格式与统计口径

## 1. JSONL 文件

路径：`/opt/monitor-lite/data/YYYY-MM-DD.jsonl`，每行一个对象，UTF-8，追加写入；按本地日期分文件。

sample：
```json
{"ts":"2026-11-25T22:15:47+0800","event":"sample","target":"deploy-8090","type":"http","status":"ok","latency_ms":10,"code":"200","detail":"HTTP 200 0.000s"}
```

alert：
```json
{"ts":"2026-11-25T22:16:59+0800","event":"alert","target":"deploy-8090","type":"http","status":"fail","latency_ms":null,"code":"curl-7","fail_count":3,"duration_s":2,"detail":"连续失败达到 3 次"}
```

recovered：
```json
{"ts":"2026-11-25T22:17:27+0800","event":"recovered","target":"deploy-8090","type":"http","status":"ok","latency_ms":10,"code":"200","fail_count":4,"duration_s":16,"detail":"recovered after 16s"}
```

字段：`ts` 本地时间；`event` 为 sample/alert/recovered；`target` 来自 YAML；`status` 为 ok/warn/fail；`latency_ms` 为整数或 null；`code` 是 HTTP 码、tcp open/closed/timeout、proc found/notfound、disk/mem 百分比；`detail` 为人类可读原因；告警额外有 `fail_count`、`duration_s`。

## 2. 统计口径

- 采样数：只数 `event=sample`；alert/recovered 不算样本。
- ok 数：sample 中 `status=ok`；`warn` 和 `fail` 都不计 ok。
- 可用率：`ok / samples × 100%`；样本为 0 显示 `-`。
- P95：取所有非空 `latency_ms`，按 nearest-rank `ceil(0.95 × n)` 排序后取值；无延迟显示 `-`。
- alert/recovered：分别按事件计数，不改变可用率。
- 固定阈值：disk-root `warn=85`、`crit=95`；mem `warn=80`、`crit=90`；唯一定义在 `checks/targets.yaml`，脚本不重复写死。

## 3. 手工 awk 核对

先停 timer，保证两次读取同一份文件（命令只读，不改数据）：

```bash
systemctl stop monitor-lite.timer
```

从原始 JSONL 重算（只使用 awk/sort，不调用 report.sh）：

```bash
awk -F'"' '/"event":"sample"/{lv=$23; gsub(/[^0-9]/,"",lv); print $12, $20, lv}' /opt/monitor-lite/data/2026-11-25.jsonl \
| sort -k1,1 -k3,3n \
| awk '{t=$1; c[t]++; if($2=="ok")o[t]++; if($3!=""){m[t]++; L[t SUBSEP m[t]]=$3+0}} END { split("deploy-8090 ops-8080 ssh-22 disk-root mem", n, " "); printf "%-16s %8s %6s %8s %8s\n","TARGET","SAMPLES","OK","AVAIL%","P95ms"; for(i=1;i<=5;i++){t=n[i]; k=m[t]+0; for(j=1;j<=k;j++) a[j]=L[t SUBSEP j]; for(j=2;j<=k;j++){x=a[j]; q=j-1; while(q>=1 && a[q]>x){a[q+1]=a[q];q--} a[q+1]=x} p="-"; if(k>0){z=int((k*95+99)/100); if(z<1)z=1; p=a[z]} av="-"; if(c[t]>0)av=sprintf("%.1f",o[t]*100/c[t]); printf "%-16s %8d %6d %8s %8s\n",t,c[t]+0,o[t]+0,av,p}}'
```

对照 `bash report.sh --date 2026-11-25` 的 `AVAIL%` 与 `P95ms`；数值应一致，行序为 targets.yaml 中的 5 个目标。核对完恢复 timer：

```bash
systemctl start monitor-lite.timer
```

文件不存在时 `report.sh` 打印 `[FAIL] data file not found: ...` 并 `exit 66`；`systemctl start` 只恢复定时器，不清空数据。
