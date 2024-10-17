#!/bin/bash

export ggmc_cfg="/etc/gridgain9db/input.json"

cc_login="$(cat "$ggmc_cfg" | jq -r '.ggmc.access.users[] | select(.meta == "rover").login' | base64 -d -)"
cc_password="$(cat "$ggmc_cfg" | jq -r '.ggmc.access.users[] | select(.meta == "rover").password' | base64 -d -)"
export cc_login cc_password

server_login="$(cat "$ggmc_cfg" | jq -r '.ggmc.access.users[] | select(.meta == "server").login' | base64 -d -)"
server_password="$(cat "$ggmc_cfg" | jq -r '.ggmc.access.users[] | select(.meta == "server").password' | base64 -d -)"
export server_login server_password

user_email="$(cat "$ggmc_cfg" | jq -r '.ggmc.access.users[] | select(.meta == "api").email' | base64 -d -)"
user_login="$(cat "$ggmc_cfg" | jq -r '.ggmc.access.users[] | select(.meta == "api").login')" # base64 encoded
user_password="$(cat "$ggmc_cfg" | jq -r '.ggmc.access.users[] | select(.meta == "api").password')" # base64 encoded
export user_email user_login user_password

$j2cli "/etc/gridgain9db/auth.json.j2" > "/etc/gridgain9db/auth.json"