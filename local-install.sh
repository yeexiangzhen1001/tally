#!/usr/bin/env bash
# 把本地源码编出的 Tally 主程序换进 /Applications/Tally.app（hook 与音乐助手原样保留）。
# 用法: ./local-install.sh            编译 → 退出 Tally → 备份 → 替换 → 重签 → 启动
#       ./local-install.sh --restore  还原为备份的原版
set -euo pipefail
src=$(cd "$(dirname "$0")" && pwd)
app=/Applications/Tally.app
backup_dir="$HOME/code/tally-backup"
orig="$backup_dir/Tally.app.orig"

quit_tally() {
  pkill -x Tally 2>/dev/null || true
  for _ in $(seq 1 30); do pgrep -x Tally >/dev/null || return 0; sleep 0.2; done
  echo "Tally 没有退出" >&2; exit 1
}

if [ "${1:-}" = "--restore" ]; then
  [ -d "$orig" ] || { echo "没有备份: $orig" >&2; exit 1; }
  quit_tally
  rm -rf "$app" && ditto "$orig" "$app"
  open -a Tally
  echo "已还原为原版"; exit 0
fi

echo "== 编译"
swift build --package-path "$src" -c release --product Tally 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -2
bin="$src/.build/release/Tally"

echo "== 备份原版（仅首次）"
mkdir -p "$backup_dir"
[ -d "$orig" ] || ditto "$app" "$orig"

echo "== 替换并重签"
quit_tally
cp "$bin" "$app/Contents/MacOS/Tally"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app" && echo "签名校验通过"

open -a Tally
sleep 2
pgrep -x Tally >/dev/null && echo "Tally 已启动" || { echo "启动失败" >&2; exit 1; }
