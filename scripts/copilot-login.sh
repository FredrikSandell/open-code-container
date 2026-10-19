#!/usr/bin/env bash
# Obtains a GitHub Copilot OAuth token with the same device flow opencode's
# /connect uses, and writes it to a file for the container's copilot-token
# secret. Run it on a machine with a browser; needs curl and jq.
#
#   scripts/copilot-login.sh [output-file]   (default: secrets/copilot-token)
set -euo pipefail

client_id=Ov23li8tweQw6odWQebz # opencode's GitHub Copilot OAuth app
out=${1:-secrets/copilot-token}

device=$(curl -fsS -X POST https://github.com/login/device/code \
  -H 'Accept: application/json' -H 'Content-Type: application/json' \
  -d "{\"client_id\":\"$client_id\",\"scope\":\"read:user\"}")
interval=$(jq -r '.interval' <<<"$device")
printf 'Open %s and enter code: %s\n' "$(jq -r .verification_uri <<<"$device")" "$(jq -r .user_code <<<"$device")"

while :; do
  sleep "$interval"
  resp=$(curl -fsS -X POST https://github.com/login/oauth/access_token \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -d "{\"client_id\":\"$client_id\",\"device_code\":\"$(jq -r .device_code <<<"$device")\",\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\"}")
  token=$(jq -r '.access_token // empty' <<<"$resp")
  [[ -n $token ]] && break
  case $(jq -r .error <<<"$resp") in
    authorization_pending) ;;
    slow_down) interval=$((interval + 5)) ;;
    *) echo "device authorization failed: $resp" >&2; exit 1 ;;
  esac
done

if ! curl -fsS -o /dev/null -H "Authorization: Bearer $token" https://api.github.com/copilot_internal/user; then
  echo "warning: this account does not appear to have GitHub Copilot access" >&2
fi

mkdir -p "$(dirname "$out")"
(umask 077 && printf '%s\n' "$token" > "$out")
echo "Copilot token written to $out"
