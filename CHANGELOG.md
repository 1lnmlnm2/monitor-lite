# CHANGELOG

## [0.3.0] - 2026-11-25

### Added
- `report.sh`：按目标输出采样数、ok 数、可用率、P95、alert、recovered；文件不存在 `exit 66`。
- 参数校验：缺 `targets.yaml`、非法 `type`、非本机目标、非法 timeout/阈值均 `exit 64`，不写脏数据。
- README 10 章、docs/01–03；docs/03 提供从原始 JSONL 手工重算可用率与 P95 的 awk 命令。

### Verified
- A6：`bash report.sh --date 2026-11-25` 输出 5 行，手工 awk 的可用率/P95 与 report 一致。
- A7：缺文件 `rc=64`、数据行数不变；`type: foo` `rc=64`、不写 `bad-foo` 行。
- A9：README 相对链接全部命中；docs 命令实跑；`INTERVAL/FAIL_THRESHOLD` 与 disk/mem 阈值在 env、timer、YAML、文档四处一致。

## [0.2.0] - 2026-11-25

### Added
- `monitor.sh`：每目标先写 sample，再按 `FAIL_THRESHOLD=3` 写一次 alert；恢复写 recovered，带 `duration_s`，状态归零。
- 状态文件：`data/state/<target>.state`，记录 `fail_count`、`alerted`、`first_fail`、`last_status`。
- `flock -n` 非阻塞锁：抢不到打印 `skipped: another run in progress`、`exit 0`，避免 timer 排队堆积。
- systemd service + timer：`Type=oneshot`、`Nice=10`、60s 周期、`Persistent=true`。

### Verified
- A2：停 8090 连跑 4 次；前 2 次只 sample/fail，第 3 次 1 条 alert（fail_count=3），第 4 次不重复刷。
- A3：恢复 8090；recovered `duration_s=16`，`STATE_FAIL=0`、`STATE_ALERTED=0`。
- A5：停止 timer 后设基线 67 行，重启等 190 秒，after=82、delta=15、service_starts=3、expected=15；list-timers 有 NEXT。
- A8：timer active 时用同锁路径持锁 3 秒模拟并发运行；后到 `skipped: another run in progress`、`rc=0`，数据行数不变（62→62），正常再跑 +5，重复行 0。

## [0.1.0] - 2026-11-25

### Added
- 14 文件骨架：monitor/report、common/probe、三份 conf、targets、selftest、两个 systemd unit、三份 docs、README、CHANGELOG。
- 五类探测：http 用 curl、tcp 用 `/dev/tcp` + timeout、proc 用 pgrep/systemctl、disk 用 `df -P`、mem 用 `/proc/meminfo`；统一 `status|latency_ms|code|detail`。
- `--once`：5 个固定目标，JSONL sample，汇总 `[OK] 5 目标 / 5 ok / 0 fail`。

### Verified
- A1：首跑 5 条合法 JSONL sample，5 个 state 文件，汇总 rc=0。
- A4：selftest 4 行全 `[OK]`；慢响应输出 `fail||timeout|curl timeout after 1s`。
