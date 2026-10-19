# Environment prepared by /opt/occ/entrypoint.sh, for `kubectl exec` shells.
if [ -r "${OCC_RUNTIME_DIR:-/tmp/occ}/env" ]; then
  . "${OCC_RUNTIME_DIR:-/tmp/occ}/env"
fi
