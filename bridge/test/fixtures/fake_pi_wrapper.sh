#!/usr/bin/env bash
# 忽略 bridge 传入的 pi 参数,启动假 pi 脚本。
exec node "$(dirname "$0")/fake_pi.mjs"
