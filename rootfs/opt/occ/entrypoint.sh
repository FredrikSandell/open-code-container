#!/usr/bin/env bash
# Container entrypoint: wires credentials into opencode, git and gh, then
# starts the opencode web server (web UI + API for `opencode attach`).
set -euo pipefail
# shellcheck source=lib/common.sh
. /opt/occ/lib/common.sh

install -d -m 700 "$OCC_RUNTIME_DIR"

# --- Server basic auth -------------------------------------------------------
OPENCODE_SERVER_PASSWORD=$(occ_secret OPENCODE_SERVER_PASSWORD server-password)
unset OPENCODE_SERVER_PASSWORD_FILE
if [[ -z $OPENCODE_SERVER_PASSWORD ]]; then
  [[ ${OCC_ALLOW_NO_AUTH:-} == 1 ]] \
    || occ_die "no server password: mount $OCC_SECRETS_DIR/server-password or set OPENCODE_SERVER_PASSWORD (OCC_ALLOW_NO_AUTH=1 to run without)"
  occ_log "WARNING: running without basic auth"
  unset OPENCODE_SERVER_PASSWORD
else
  export OPENCODE_SERVER_PASSWORD
fi
export OPENCODE_SERVER_USERNAME=${OPENCODE_SERVER_USERNAME:-opencode}

# --- Extra CA certificates (private GHES CA) ---------------------------------
ca_file=${EXTRA_CA_CERTS_FILE:-$OCC_SECRETS_DIR/ca.crt}
if [[ -r $ca_file ]]; then
  bundle=$OCC_RUNTIME_DIR/ca-bundle.crt
  cat /etc/ssl/certs/ca-certificates.crt "$ca_file" > "$bundle"
  export SSL_CERT_FILE=$bundle CURL_CA_BUNDLE=$bundle GIT_SSL_CAINFO=$bundle NODE_EXTRA_CA_CERTS=$ca_file
  occ_log "trusting extra CA certificates from $ca_file"
fi

# --- GitHub Copilot credential -----------------------------------------------
# opencode keeps provider credentials in auth.json; rewrite the Copilot entry
# on every start so a rotated secret takes effect.
copilot_token=$(occ_secret COPILOT_TOKEN copilot-token)
unset COPILOT_TOKEN COPILOT_TOKEN_FILE
data_dir=${XDG_DATA_HOME:-$HOME/.local/share}/opencode
auth_file=$data_dir/auth.json
mkdir -p "$data_dir"
if [[ -n $copilot_token ]]; then
  [[ -s $auth_file ]] || echo '{}' > "$auth_file"
  (umask 077 && jq --arg t "$copilot_token" \
    '."github-copilot" = {type: "oauth", refresh: $t, access: $t, expires: 0}' \
    "$auth_file" > "$auth_file.tmp")
  mv "$auth_file.tmp" "$auth_file"
  occ_log "GitHub Copilot credential installed"
else
  occ_log "WARNING: no Copilot token (mount $OCC_SECRETS_DIR/copilot-token or set COPILOT_TOKEN)"
fi
unset copilot_token

# --- Git and gh against GHES via GitHub Apps ---------------------------------
gitconfig=$OCC_RUNTIME_DIR/gitconfig
: > "$gitconfig"
export GIT_CONFIG_SYSTEM=$gitconfig
if [[ -n ${GHES_HOST:-} ]]; then
  for role in read write; do
    [[ -n $(occ_app_id $role) ]] || occ_die "GHES_HOST is set but GHAPP_${role^^}_ID is not"
    [[ -r $(occ_app_key $role) ]] || occ_die "private key for the $role app not readable at $(occ_app_key $role)"
  done
  h=$GHES_HOST
  git config -f "$gitconfig" credential."https://$h".helper ""
  git config -f "$gitconfig" --add credential."https://$h".helper /opt/occ/bin/git-credential-ghapp
  git config -f "$gitconfig" credential."https://$h".useHttpPath true
  # App tokens only work over HTTPS.
  git config -f "$gitconfig" --add url."https://$h/".insteadOf "git@$h:"
  git config -f "$gitconfig" --add url."https://$h/".insteadOf "ssh://git@$h/"

  # Commit as the write app's bot user unless told otherwise.
  if [[ -z ${GIT_USER_NAME:-} || -z ${GIT_USER_EMAIL:-} ]]; then
    if slug=$(curl -fsS -H "Authorization: Bearer $(/opt/occ/bin/ghapp-token --jwt write)" \
      -H "Accept: application/vnd.github+json" "$(occ_api_url)/app" | jq -er .slug); then
      bot_id=$(curl -fsS "$(occ_api_url)/users/$slug%5Bbot%5D" | jq -r '.id // empty' || true)
      GIT_USER_NAME=${GIT_USER_NAME:-${slug}[bot]}
      GIT_USER_EMAIL=${GIT_USER_EMAIL:-${bot_id:+$bot_id+}${slug}[bot]@users.noreply.$h}
    else
      occ_log "WARNING: could not look up the write app on $h; set GIT_USER_NAME and GIT_USER_EMAIL"
    fi
  fi
  occ_log "git/gh configured for $h (read app ${GHAPP_READ_ID}, write app ${GHAPP_WRITE_ID}, push prefix '${AGENT_BRANCH_PREFIX-agent/}')"
else
  occ_log "WARNING: GHES_HOST not set; git/gh GitHub App integration disabled"
fi
[[ -n ${GIT_USER_NAME:-} ]] && git config -f "$gitconfig" user.name "$GIT_USER_NAME"
[[ -n ${GIT_USER_EMAIL:-} ]] && git config -f "$gitconfig" user.email "$GIT_USER_EMAIL"

# Force our hook dispatcher over any repo-local core.hooksPath (env-level
# config outranks repository config).
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/opt/occ/git-hooks

# Shells started with `kubectl exec` don't inherit this environment; leave it
# where /etc/profile.d/occ.sh picks it up.
export -p | grep -E ' (GIT_CONFIG_[A-Z0-9_]+|GIT_SSL_CAINFO|SSL_CERT_FILE|CURL_CA_BUNDLE|NODE_EXTRA_CA_CERTS|OPENCODE_SERVER_USERNAME)=' \
  > "$OCC_RUNTIME_DIR/env" || true

# --- Start opencode ----------------------------------------------------------
workspace=${WORKSPACE_DIR:-$HOME/workspace}
mkdir -p "$workspace"
cd "$workspace"

if [[ $# -gt 0 ]]; then
  exec "$@"
fi
# shellcheck disable=SC2086 # OCC_OPENCODE_ARGS is split on purpose
exec opencode web --hostname "${OCC_HOSTNAME:-0.0.0.0}" --port "${OCC_PORT:-4096}" ${OCC_OPENCODE_ARGS:-}
