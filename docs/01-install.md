# 01 安装

前提：Ubuntu 22.04 LTS、bash 5、systemd、curl、awk、flock、pgrep、df；仓库已放在 `/root/monitor-lite`。所有命令由 root 执行。

## 1. 准备运行根

```bash
mkdir -p /opt/monitor-lite
cp /root/monitor-lite/conf/monitor.env.example /opt/monitor-lite/monitor.env
```

`monitor.env` 的默认值：`DATA_DIR=/opt/monitor-lite/data`、`LOG_DIR=/opt/monitor-lite/logs`、`INTERVAL=60`、`FAIL_THRESHOLD=3`、`CURL_MAX_TIME=3`。数据只落 `/opt/monitor-lite`，不写 `/tmp`。

## 2. 安装 service 与 timer

```bash
install -m 0644 /root/monitor-lite/systemd/monitor-lite.service /etc/systemd/system/
install -m 0644 /root/monitor-lite/systemd/monitor-lite.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now monitor-lite.timer
```

timer 的关键值：`OnBootSec=60s`、`OnUnitActiveSec=60s`、`AccuracySec=5s`、`Persistent=true`；触发 `/root/monitor-lite/monitor.sh --once`。

## 3. 首跑与自检

```bash
cd /root/monitor-lite
bash monitor.sh --once
bash checks/selftest.sh
```

首跑输出 5 条 sample 与 `[OK] 5 目标 / 5 ok / 0 fail`；自检输出 4 行 `[OK]`。selftest 的正常 200 依赖本机 8090（deploy-kit）在运行，慢响应用本机临时监听，不访问外网。

## 4. 状态与日报

```bash
systemctl list-timers --all monitor-lite.timer
bash report.sh --date 2026-11-25
```

`list-timers` 必须显示 `NEXT` 与 `LAST`；`report.sh` 输出 5 行目标统计。日报文件路径为 `/opt/monitor-lite/data/YYYY-MM-DD.jsonl`，日期参数支持 `--date`，缺参数默认今天。

## 5. 修改周期

`INTERVAL` 是文档口径，实际 timer 周期由 `OnUnitActiveSec` 决定；两处必须一起改：把 `monitor.env` 的 `INTERVAL` 和 timer 的 `OnBootSec`、`OnUnitActiveSec` 改成同一个秒数，执行 `systemctl daemon-reload` 后 `systemctl restart monitor-lite.timer`。本卡验收固定 60 秒，未改周期；自行改周期后按 §4 重新核对 `list-timers` 的 NEXT。
