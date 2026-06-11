#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup_telegram_commands.sh — 注册 Telegram Bot 命令自动补全
#
# 使用 Telegram Bot API 的 setMyCommands 接口注册 /review 和 /critical
# 用户在聊天框输入 / 时会自动弹出补全提示
#
# 用法: bash scripts/setup_telegram_commands.sh <BOT_TOKEN>
# 或设置环境变量: TELEGRAM_BOT_TOKEN=xxx bash scripts/setup_telegram_commands.sh
###############################################################################

BOT_TOKEN="${1:-${TELEGRAM_BOT_TOKEN:-}}"

if [[ -z "${BOT_TOKEN}" ]]; then
  echo "错误: 请提供 Bot Token"
  echo "用法: bash scripts/setup_telegram_commands.sh <BOT_TOKEN>"
  echo "  或: TELEGRAM_BOT_TOKEN=xxx bash scripts/setup_telegram_commands.sh"
  exit 1
fi

API_URL="https://api.telegram.org/bot${BOT_TOKEN}/setMyCommands"

# 注册命令
response=$(curl -s -X POST "${API_URL}" \
  -H "Content-Type: application/json" \
  -d '{
    "commands": [
      {
        "command": "review",
        "description": "启动 Tier 2 Review 复核（知识预检 + 证据裁决）"
      },
      {
        "command": "critical",
        "description": "启动 Tier 3 Critical 高风险审查（完整链路 + 人工升级）"
      }
    ]
  }')

# 检查结果
if echo "${response}" | grep -q '"ok":true'; then
  echo "✅ Telegram Bot 命令注册成功！"
  echo ""
  echo "已注册命令:"
  echo "  /review   — 启动 Tier 2 Review 复核（知识预检 + 证据裁决）"
  echo "  /critical — 启动 Tier 3 Critical 高风险审查（完整链路 + 人工升级）"
  echo ""
  echo "用户输入 / 时会自动弹出补全提示。"
else
  echo "❌ 注册失败: ${response}"
  exit 1
fi
