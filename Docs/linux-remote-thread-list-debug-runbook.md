# Linux 远端 thread/list 连接问题调试记录

日期：2026-05-17

分支：`debug/linux-remodex-diagnostics`

远端主机：`root@10.132.26.89`

远端调试目录：`/root/remodex-debug`

## 问题现象

iOS App 连接 Windows 上的 Remodex bridge 正常，但连接 Linux 上的 Remodex bridge 时，手机端看起来先连上，随后报 `connection was interrupted` 或类似超时中断错误。

日志里最关键的判断是：

- relay/WebSocket 传输是通的
- secure handshake 已成功
- `initialize` 已成功
- `model/list` 已成功
- 重复的 `thread/list` 请求卡住，或者返回太慢

所以这次主要故障不在手机到 relay 的链路，而是在 Linux bridge 把启动阶段多个重复的 `thread/list` RPC 转发给 `codex app-server` 后，Linux 侧响应过慢，导致手机端判定连接失败。

## 关键证据

bridge 日志里可以看到前置步骤已经成功：

```text
[remodex][secure] serverHello mode=trusted_reconnect ...
[remodex] phone -> codex method=initialize ...
[remodex] codex -> phone method=initialize ... hasError=false
[remodex] phone -> codex method=model/list ...
[remodex] codex -> phone method=model/list ... hasError=false
[remodex] phone -> codex method=thread/list ...
```

在服务端调试缓解之前，可以用下面两条命令对比 `thread/list` 请求数和响应数：

```sh
grep -c "phone -> codex method=thread/list" /root/remodex-debug/manual.log
grep -c "codex -> phone method=thread/list" /root/remodex-debug/manual.log
```

失败时的一次观测结果是：手机侧发出了 10 个 `thread/list` 请求，但 bridge 只返回了 2 个 `thread/list` 响应，同时 Linux 上的 Codex app-server 进程 CPU 较高。

Linux 侧 session 目录也比较大，足以让 `thread/list` 变成较重的操作：

```text
201 个 rollout jsonl 文件
279M ~/.codex/sessions
最大几个 rollout 文件约 40M、28M、26M
```

## 环境变量问题

有一次手工启动时，日志显示 relay 环境变量为空：

```text
[manual-debug] REMODEX_RELAY=
```

因此远端启动脚本里补了默认 relay，避免 shell 环境里没有变量时启动到空 relay：

```sh
export REMODEX_RELAY="${REMODEX_RELAY:=ws://remodex.huya.info/relay}"
```

修正后，启动日志里应该看到：

```text
[manual-debug] REMODEX_RELAY=ws://remodex.huya.info/relay
```

## 服务端调试缓解

相关代码提交：

```text
dc5e19f 调试：合并重复的 thread/list 请求
```

bridge 现在会按相同 params 合并正在进行中的重复 `thread/list` 请求：

1. 第一个匹配到的 `thread/list` 请求正常转发给 `codex app-server`。
2. 后续相同 params 的重复 `thread/list` 请求不会立刻继续转发。
3. 等主请求从 Codex 返回后，bridge 会复制同一份响应，分别回给被合并的重复请求 id。

缓解生效后，日志中应该能看到：

```text
[remodex] coalesced duplicate thread/list id=... primary=...
[remodex] codex -> phone method=thread/list id=... coalescedFrom=... hasError=false
```

健康状态可以继续用下面两条命令确认：

```sh
grep -c "phone -> codex method=thread/list" /root/remodex-debug/manual.log
grep -c "codex -> phone method=thread/list" /root/remodex-debug/manual.log
```

缓解后的观测结果是请求数和响应数一致：

```text
phone thread/list: 8
codex thread/list responses: 8
```

## 远端调试目录

已安装的 debug bridge：

```text
/root/remodex-debug/node_modules/remodex
```

手工启动脚本：

```text
/root/remodex-debug/run-manual-debug.sh
```

主日志：

```text
/root/remodex-debug/manual.log
```

当前远端 debug 包：

```text
/root/remodex-1.5.2-beta.0-debug-coalesce.tgz
```

## 启动 debug bridge

在 Linux 远端执行：

```sh
bash /root/remodex-debug/run-manual-debug.sh
```

也可以后台启动：

```sh
nohup bash /root/remodex-debug/run-manual-debug.sh >/root/remodex-debug/nohup.log 2>&1 &
```

检查进程和日志：

```sh
ps -eo pid,ppid,etime,%cpu,cmd | grep -E "remodex-debug|codex app-server" | grep -v grep
tail -n 120 /root/remodex-debug/manual.log
```

## 重新安装远端 debug 包

在本地 repo 里重新 `npm pack` 后，传包并安装：

```sh
ssh root@10.132.26.89 'cat > /root/remodex-1.5.2-beta.0-debug-coalesce.tgz' \
  < dist/remodex-remote-debug-coalesce/remodex-1.5.2-beta.0.tgz

ssh root@10.132.26.89 '
  REMODEX_SKIP_CODEX_BOOTSTRAP=1 npm install \
    --prefix /root/remodex-debug \
    /root/remodex-1.5.2-beta.0-debug-coalesce.tgz \
    --omit=dev --ignore-scripts --no-audit --no-fund
  node --check /root/remodex-debug/node_modules/remodex/src/bridge.js
'
```

## 停止 debug bridge

```sh
for pid in $(pgrep -x node 2>/dev/null || true); do
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
  case "$cmd" in
    *"/root/remodex-debug/node_modules/.bin/remodex run"*) kill "$pid" || true ;;
  esac
done
```

不要在 SSH 命令里用很宽的 `pgrep -f "remodex-debug"` 清理进程，因为清理命令本身可能匹配到当前 SSH shell，导致 SSH 会话被杀掉。

## 后续判断

这次服务端改动是 debug 缓解：让 bridge 对慢运行环境有防御能力，避免重复 `thread/list` 把 Linux 侧 app-server 压住。

更干净的产品修复仍然应该放在 iOS 侧：减少启动和前后台切换时重复触发 `thread/list`，服务端合并逻辑作为慢运行时的保护保留。
