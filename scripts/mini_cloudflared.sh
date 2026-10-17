#!/bin/bash
# mini 侧 cloudflared 常驻隧道:把 127.0.0.1:18791(记忆中枢 Agent 服务)经 Cloudflare
# Tunnel 暴露成 https://<hostname>,供云代理 /agent/model 中继转发 —— 纯出站,不开端口。
#
#   sh scripts/mini_cloudflared.sh install     # 安装并启动(需先完成一次 login,见下)
#   sh scripts/mini_cloudflared.sh status
#   sh scripts/mini_cloudflared.sh stop|start|restart
#   sh scripts/mini_cloudflared.sh uninstall
#
# 需要用户配合的一次性操作(浏览器交互,脚本不替你做):
#   1. cloudflared tunnel login          # 选 YOUR_DOMAIN.example 域授权,写 ~/.cloudflared/cert.pem
#   2. 若要用自定义子域: 本脚本 install 时用 APT_TUNNEL_HOSTNAME=agent.apt-backend.example 自动配 DNS 路由
#
# 变量(环境或 ~/.config/apt/cloudflared.env):
#   APT_TUNNEL_NAME     隧道名,默认 apt-agent
#   APT_TUNNEL_HOSTNAME 隧道对外域名,如 agent.apt-backend.example(用于 DNS 路由与 Worker 的 AGENT_TUNNEL_URL)
#
# ⚠️ AGENT_TUNNEL_URL(worker secret)的值 = https://<APT_TUNNEL_HOSTNAME> —— 客户端
#    输入法端点仍是 Worker 域(https://apt-backend.example/agent/model);一个域名只能指向
#    一个服务,所以隧道必须用自己的子域,不能复用 apt-backend.example。
# ⚠️ 部署顺序:先本脚本(mini) → wrangler secret put AGENT_TUNNEL_URL → deploy_worker.sh。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=com.apt.cloudflared
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.cloudflared"
CONFIG="$CONFIG_DIR/config.yml"
ENV_FILE="${APT_CLOUDFLARED_ENV_FILE:-$HOME/.config/apt/cloudflared.env}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
TUNNEL_NAME="${APT_TUNNEL_NAME:-apt-agent}"
TUNNEL_HOSTNAME="${APT_TUNNEL_HOSTNAME:-}"
BIN="$(command -v cloudflared || true)"

[ -n "$BIN" ] || { echo 'cloudflared 未安装:brew install cloudflared' >&2; exit 1; }

tunnel_id() { "$BIN" tunnel list --output json 2>/dev/null \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(next((t['id'] for t in d if t['name']=='$TUNNEL_NAME'),''))" || true; }

running() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

case "${1:-status}" in
  install)
    [ -f "$CONFIG_DIR/cert.pem" ] || { cat >&2 <<EOF
🔴 缺少 ~/.cloudflared/cert.pem —— 先完成一次性授权(浏览器交互,脚本不替你做):
     $BIN tunnel login
   登录页选中 YOUR_DOMAIN.example 域授权后,重跑本脚本 install。
EOF
      exit 1; }
    ID="$(tunnel_id)"
    if [ -z "$ID" ]; then
      ID="$("$BIN" tunnel create "$TUNNEL_NAME" | awk '/Created tunnel/{getline; print $NF}')" || true
      [ -n "$ID" ] || { echo "🔴 隧道创建失败:cloudflared tunnel create $TUNNEL_NAME" >&2; exit 1; }
      echo "▸ 已创建隧道 $TUNNEL_NAME($ID)"
    fi
    [ -f "$CONFIG_DIR/$ID.json" ] || { echo "🔴 缺凭据文件 $CONFIG_DIR/$ID.json" >&2; exit 1; }
    mkdir -p "$CONFIG_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/growth"
    if [ -n "$TUNNEL_HOSTNAME" ]; then
      # 幂等:已路由过会报错,吞掉重跑的错即可(域已在别的隧道/服务上则真失败,如实显示)。
      "$BIN" tunnel route dns "$TUNNEL_NAME" "$TUNNEL_HOSTNAME" 2>&1 | tail -1 || true
      echo "▸ 隧道域名 https://$TUNNEL_HOSTNAME"
    else
      echo "⚠️  未设 APT_TUNNEL_HOSTNAME,跳过 DNS 路由 —— Worker 将无法按域名转发"
    fi
    cat > "$CONFIG" <<EOF
tunnel: $ID
credentials-file: $CONFIG_DIR/$ID.json
# 只暴露记忆中枢 Agent 服务;catch-all 一律 404,绝不转发别的端口。
ingress:
  - service: http://127.0.0.1:18791
  - service: http_status:404
EOF
    chmod 600 "$CONFIG"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array>
  <string>$BIN</string>
  <string>--config</string><string>$CONFIG</string>
  <string>tunnel</string><string>run</string><string>$TUNNEL_NAME</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$HOME/Library/Logs/growth/cloudflared.log</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/growth/cloudflared.log</string>
</dict></plist>
EOF
    running && launchctl bootout "$DOMAIN/$LABEL" || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "▸ cloudflared 已常驻(launchd $LABEL;日志 ~/Library/Logs/growth/cloudflared.log)"
    [ -n "$TUNNEL_HOSTNAME" ] && cat <<EOF
▸ 下一步(Worker 侧,需在仓外执行):
     cd $REPO/worker && npx wrangler secret put AGENT_TUNNEL_URL   # 值: https://$TUNNEL_HOSTNAME
     sh scripts/deploy_worker.sh
   客户端(MacBook): defaults write local.echo.inputmethod.memory agentModelEndpoint https://apt-backend.example/agent/model
     (须与输入法「共用 APT 记忆」服务地址同源,否则回退本机)
EOF
    ;;
  status)
    running && echo "▸ launchd $LABEL: running" || echo "▸ launchd $LABEL: not loaded"
    ID="$(tunnel_id)"
    [ -n "$ID" ] && "$BIN" tunnel info "$TUNNEL_NAME" 2>/dev/null | head -6 || echo "▸ 隧道 $TUNNEL_NAME 未创建"
    curl -fsS -m 5 http://127.0.0.1:18791/health >/dev/null 2>&1 \
      && echo "▸ 18791 服务:/health 可达" || echo "⚠️  18791 服务未运行(先 scripts/input_memory_daemon.sh start)"
    ;;
  stop) running && launchctl bootout "$DOMAIN/$LABEL" && echo "▸ 已停止" || echo "▸ 本来就没在跑";;
  start) [ -f "$PLIST" ] || { echo "🔴 未安装,先 install" >&2; exit 1; }
    running || launchctl bootstrap "$DOMAIN" "$PLIST"; echo "▸ 已启动";;
  restart) "$0" stop; "$0" start;;
  uninstall) running && launchctl bootout "$DOMAIN/$LABEL" || true
    rm -f "$PLIST"; echo "▸ 已移除 launchd(隧道与凭据保留,重装直接 install)";;
  *) echo "用法: $0 install|status|stop|start|restart|uninstall" >&2; exit 1;;
esac
