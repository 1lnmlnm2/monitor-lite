# 02 告警与恢复

## 1. 判定顺序

每个目标每轮先调用 `scripts/lib/probe.sh` 得到 `status|latency_ms|code|detail`，再写 sample；随后读取 `data/state/<target>.state` 决定是否追加事件。

| 条件 | 结果 |
| --- | --- |
| HTTP 非 200、TCP 不通/超时、proc 不存在、disk/mem ≥ crit | `fail` |
| disk/mem ≥ warn 但 < crit | `warn`（只写 sample，不计连续失败） |
| HTTP 200 / TCP open / proc active / 未达阈值 | `ok` |
| 连续 `fail` 达到 `FAIL_THRESHOLD=3` 且尚未告警 | 追加 1 条 `alert`，`alerted=1` |
| 已告警后继续 fail | 只追加 sample，不重复 alert |
| 从 fail 恢复到非 fail | 追加 `recovered`，带 `duration_s`，计数归零 |

disk-root 固定 `warn=85`、`crit=95`；mem 固定 `warn=80`、`crit=90`（按 MemTotal/MemAvailable 算使用率）。这些阈值只在 [checks/targets.yaml](../checks/targets.yaml) 定义，不在脚本里重复写死。

## 2. 状态文件

```bash
cat /opt/monitor-lite/data/state/deploy-8090.state
```

字段：

- `STATE_FAIL`：当前连续 fail 次数；成功/恢复后为 0。
- `STATE_ALERTED`：0/1；1 表示本轮连续失败已写过 alert。
- `STATE_FIRST`：本轮第一次 fail 的 epoch 秒；恢复后为 0。
- `STATE_LAST`：最近一次状态（ok/warn/fail）。

状态文件按目标隔离，名字来自 `targets.yaml`；不共享全局计数。

## 3. 查看事件

```bash
tail -n 20 /opt/monitor-lite/data/2026-11-25.jsonl
awk '/"event":"alert"/{a++} /"event":"recovered"/{r++} END{printf "alert=%d recovered=%d\n",a+0,r+0}' /opt/monitor-lite/data/2026-11-25.jsonl
```

`duration_s` 是从首次 fail 到恢复的秒数；alert 的 `duration_s` 是首次 fail 到写入告警的秒数。恢复后的 `STATE_FAIL=0`、`STATE_ALERTED=0`、`STATE_FIRST=0`。

## 4. 手工注入（验收 A2/A3）

A2/A3 在真机对 deploy-kit 的 **运行状态** 做只读探测：临时 `systemctl stop deploy-kit-site`，跑 4 次 `monitor.sh --once`，再 `systemctl start deploy-kit-site` 恢复。只停/起服务，不改 deploy-kit 的仓库、unit 文件或 nginx 配置；恢复后必须 `curl --max-time 3 -fsS http://127.0.0.1:8090/health.txt` 仍返回 `20261128`。

此注入不纳入日常脚本；`monitor.sh` 本身不停止任何服务。
