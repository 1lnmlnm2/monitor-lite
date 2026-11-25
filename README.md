# monitor-lite

## 1. 定位与边界

单机无人值守探活：systemd timer 每分钟运行一次，探测 HTTP / TCP / 进程 / 磁盘 / 内存，结果写本地 JSONL；连续失败才写 alert，恢复写 recovered，按天汇总可用率与 P95。只写本地日志，不接外部告警通道，不自建面板。

三个项目不重叠：`ops-runbook` 是人工诊断手册，`deploy-kit` 是发布与回滚，`monitor-lite` 是机器每分钟自己跑的可用性探活。`monitor-lite` 只对前两者做只读探测，不改它们的仓库、配置或服务。

## 2. 目录结构

| 路径 | 作用 |
| --- | --- |
| [monitor.sh](monitor.sh) | 单次入口：`--once [--target <名>]`；加锁、采样、状态机、汇总 |
| [report.sh](report.sh) | 日报：`--date YYYY-MM-DD`，按目标输出采样/可用率/P95/告警/恢复 |
| [scripts/lib/common.sh](scripts/lib/common.sh) | 配置、YAML 目标解析与校验、flock、状态文件、JSONL |
| [scripts/lib/probe.sh](scripts/lib/probe.sh) | http/tcp/proc/disk/mem 五类探测，统一返回 `status\|latency_ms\|code\|detail` |
| [conf/monitor.env.example](conf/monitor.env.example) | `DATA_DIR` / `LOG_DIR` / `INTERVAL` / `FAIL_THRESHOLD` / `CURL_MAX_TIME` |
| [checks/targets.yaml](checks/targets.yaml) | 固定 5 个目标：deploy-8090、ops-8080、ssh-22、disk-root、mem |
| [checks/selftest.sh](checks/selftest.sh) | 4 个注入自检：200、闭端口、慢响应、进程不存在 |
| [systemd/monitor-lite.service](systemd/monitor-lite.service) | `Type=oneshot`、`Nice=10` |
| [systemd/monitor-lite.timer](systemd/monitor-lite.timer) | 60s timer，`AccuracySec=5s`、`Persistent=true` |
| [docs/01-install.md](docs/01-install.md) | 安装、timer、首跑、验证 |
| [docs/02-alerting.md](docs/02-alerting.md) | 告警/恢复规则与状态文件 |
| [docs/03-data-format.md](docs/03-data-format.md) | JSONL 字段、统计口径、手工 awk 核对 |
| [README.md](README.md) | 本文件 |
| [CHANGELOG.md](CHANGELOG.md) | 变更记录 |

全部 14 个文件；仓库不包含 `data/`、`logs/` 或临时文件。

## 3. 环境要求

- Ubuntu 22.04 LTS + systemd；bash 5；root 运行 `monitor.sh` 与 timer。
- curl、awk/sed/grep、flock、pgrep、df、`/proc`；不需要 Docker、Node/Python/Go、数据库、Prometheus/Grafana/Zabbix/Netdata 或 cron。
- 默认部署根：`/opt/monitor-lite`（`data/`、`logs/`、`monitor.env`）；仓库在 `/root/monitor-lite`。
- 5 个目标全部是 `127.0.0.1`；不写死任何外部 IP。`deploy-8090` 的 200 依赖本机 `deploy-kit` 已运行，`ops-8080` 是现场既有 Docker 服务。

## 4. 快速开始

```bash
cd /root/monitor-lite
mkdir -p /opt/monitor-lite
cp conf/monitor.env.example /opt/monitor-lite/monitor.env
bash monitor.sh --once
bash checks/selftest.sh
bash report.sh --date "$(date +%F)"
```

安装 timer：

```bash
install -m 0644 systemd/monitor-lite.service /etc/systemd/system/
install -m 0644 systemd/monitor-lite.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now monitor-lite.timer
systemctl list-timers --all monitor-lite.timer
```

首轮输出应包含 `[OK] 5 目标 / 5 ok / 0 fail`；数据文件在 `/opt/monitor-lite/data/YYYY-MM-DD.jsonl`。

## 5. 怎么加一个目标

编辑 `checks/targets.yaml`，追加一个同缩进块；`type` 只能是 `http/tcp/proc/disk/mem`，`target` 只允许 `127.0.0.1` 或本机绝对路径。示例（进程目标）：

```yaml
  - name: nginx-proc
    type: proc
    target: nginx
    expect: active
    timeout: 3
    warn: 0
    crit: 0
```

改完先 `bash monitor.sh --once` 验证解析；缺字段、非法 type、非本机 URL 或 `0 < warn < crit` 不满足时，统一打印 `[FAIL]` 并 `exit 64`，不写数据。默认 5 个目标已覆盖 HTTP/TCP/磁盘/内存；`proc` 类型已实现，默认 5 个目标未启用，仅在 selftest 覆盖。
`MONITOR_TARGETS` 和 `MONITOR_CONF` 是自检与本地覆盖用的环境变量，默认分别指向仓库 `checks/targets.yaml` 和 `/opt/monitor-lite/monitor.env`，不作为对外配置项。

## 6. 告警规则

- 每个目标每轮先写一条 `sample`；HTTP/TCP 失败、`proc` 不存在或 disk/mem 达到 `crit` 记 `fail`。
- `FAIL_THRESHOLD=3` 连续失败：第 3 次写一条 `alert`；之后持续失败不再重复刷 alert。
- 恢复后写一条 `recovered`，带 `duration_s`（从首次失败到恢复的秒数），状态文件 `fail_count` 归零。
- disk/mem 达到 `warn` 但未到 `crit` 记 `warn`：只写 sample，不计数为连续失败；达到 `crit` 才是 `fail`。固定阈值：disk-root `warn=85`、`crit=95`；mem `warn=80`、`crit=90`。
- 单次失败只写 `sample`/`fail`，不产生 alert；`--target` 只影响本轮目标，不改变其他目标状态。

## 7. 数据格式与统计口径

每行一个 JSON 对象，事件为 `sample` / `alert` / `recovered`；字段与样例见 `docs/03-data-format.md`。
日报 `report.sh` 的统计：`sample` 才计入采样数；`ok` 才计入可用率；P95 使用所有非空 `latency_ms`，按 nearest-rank `ceil(0.95*n)` 取值；alert/recovered 单独计数，不算样本。

## 8. 验收对照表

| 项 | 场景 | 状态 |
| --- | --- | --- |
| A1 | `--once` 5 条 sample、汇总正确、rc=0 | Day1 通过 |
| A2 | 停 8090 连跑 4 次：前 2 次只 sample/fail，第 3 次 1 条 alert，第 4 次不重复 | Day2 通过 |
| A3 | 恢复 8090：recovered 带 duration_s，状态归零 | Day2 通过 |
| A4 | selftest 4 场景全 [OK]，超时 latency 空/标 timeout | Day1 通过 |
| A5 | timer 等 3 分钟：list-timers 有 NEXT；行数增量=5×触发次数 ±1 | Day2 通过 |
| A6 | report 5 行；docs/03 手工 awk 的可用率/P95 一致 | Day3 通过 |
| A7 | 缺 targets rc=64 不写数据；type=foo rc=64 不写该目标 | Day3 通过 |
| A8 | timer 运行时手动 `--once`，后到 skipped、rc=0、不重复不乱序 | Day2 通过 |
| A9 | README 链接全内、docs 命令实跑、参数与阈值四处一致 | Day3 通过 |

## 9. 已知限制

- 单机；不做多机编排、集群探活或分布式锁。
- 只写本地 JSONL 和 journal；无外部告警通道、无面板、无数据库。
- 目标口径固定为 5 个；`proc` 类型已实现，默认 5 个目标未启用，仅在 selftest 覆盖。
- 验收期间曾人工 stop/start 过一次 `deploy-kit-site`（详见 `docs/02` §A2/A3）；monitor-lite 自身不停止任何服务。今后验收不得停/改前两个项目的服务与仓库，除非事先批准。
- timer 间隔要改两处：`conf/monitor.env.example` 的 `INTERVAL=60`（文档口径）和 `systemd/monitor-lite.timer` 的 `OnBootSec/OnUnitActiveSec=60s`（实际调度）；改完需 `systemctl daemon-reload && systemctl restart monitor-lite.timer`。
- 不做历史压缩、轮转或自动清理；`data/` 会按天增长，由使用者自行归档。
- `--target` 只支持已有目标名；新增目标仍需改 YAML。
- 单次探测的 `latency_ms` 受本机负载影响；P95 仅用于同日对比，不跨机器比较。
- timer 的 `Persistent=true` 只补一次错过的触发，不追平全部历史。

## 10. 变更记录指针

版本与验收记录见 `CHANGELOG.md`。
