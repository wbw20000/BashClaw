#!/usr/bin/env bash
export DISCORD_POLL_INTERVAL=2
unset CLAUDECODE
bashclaw gateway 2>&1 | tee -a ~/.bashclaw/logs/gateway.log
