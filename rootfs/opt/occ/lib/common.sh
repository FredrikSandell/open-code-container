# Shared helpers for the container scripts. Source, don't execute.

OCC_SECRETS_DIR=${OCC_SECRETS_DIR:-/run/secrets/occ}
OCC_RUNTIME_DIR=${OCC_RUNTIME_DIR:-/tmp/occ}

occ_log() { printf '[occ] %s\n' "$*" >&2; }
occ_die() { printf '[occ] error: %s\n' "$*" >&2; exit 1; }

# occ_secret VAR default_file
# Resolves a secret from $VAR, then the file named by $VAR_FILE, then
# default_file under the secrets dir. Prints the value (empty if unset).
occ_secret() {
  local var=$1 default_file=$2 file_var="${1}_FILE"
  if [[ -n ${!var:-} ]]; then
    printf '%s' "${!var}"
  elif [[ -n ${!file_var:-} ]]; then
    [[ -r ${!file_var} ]] || occ_die "$file_var points to unreadable file ${!file_var}"
    tr -d '\r\n' < "${!file_var}"
  elif [[ -r $OCC_SECRETS_DIR/$default_file ]]; then
    tr -d '\r\n' < "$OCC_SECRETS_DIR/$default_file"
  fi
}

# occ_app_id <read|write>
occ_app_id() {
  case $1 in
    read) printf '%s' "${GHAPP_READ_ID:-}" ;;
    write) printf '%s' "${GHAPP_WRITE_ID:-}" ;;
    *) occ_die "unknown app role '$1' (expected read or write)" ;;
  esac
}

# occ_app_key <read|write> - prints the path of the app's private key.
occ_app_key() {
  local var
  case $1 in
    read) var=GHAPP_READ_KEY_FILE ;;
    write) var=GHAPP_WRITE_KEY_FILE ;;
    *) occ_die "unknown app role '$1' (expected read or write)" ;;
  esac
  if [[ -n ${!var:-} ]]; then
    printf '%s' "${!var}"
  else
    printf '%s' "$OCC_SECRETS_DIR/ghapp-$1.pem"
  fi
}

occ_api_url() {
  printf '%s' "${GHES_API_URL:-https://${GHES_HOST:?GHES_HOST is not set}/api/v3}"
}

# occ_url_host <git-url> - prints the host of an https, ssh or scp-style URL.
occ_url_host() {
  local url=$1
  url=${url#*://}
  url=${url#*@}
  url=${url%%[:/]*}
  printf '%s' "$url"
}

# occ_url_owner <git-url> - prints the first path segment (the repo owner).
occ_url_owner() {
  local url=$1
  url=${url#*://}
  url=${url#*@}
  url=${url#*[:/]}
  printf '%s' "${url%%/*}"
}
