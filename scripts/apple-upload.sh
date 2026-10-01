#!/bin/sh
set -eu

fail() {
  echo "apple-upload: $*" >&2
  exit 1
}

[ $# -ge 2 ] || fail "usage: $0 validate DIR ARTIFACT... | upload --confirm DIR ARTIFACT..."

operation=$1
shift
case "$operation" in
  validate) ;;
  upload)
    [ "${1:-}" = "--confirm" ] || fail "upload requires --confirm"
    shift
    ;;
  *) fail "usage: $0 validate DIR ARTIFACT... | upload --confirm DIR ARTIFACT..." ;;
esac

[ $# -ge 2 ] || fail "usage: $0 validate DIR ARTIFACT... | upload --confirm DIR ARTIFACT..."

out_dir=$1
shift
[ -d "$out_dir" ] || fail "output directory does not exist: $out_dir"
[ $# -ge 1 ] || fail "no artifacts given"

for artifact in "$@"; do
  case "$artifact" in
    *.ipa|*.pkg) ;;
    *) fail "unsupported artifact type (expected .ipa or .pkg): $artifact" ;;
  esac
  [ -f "$artifact" ] || fail "artifact not found: $artifact"
done

[ -n "${KEY_ID:-}" ] || fail "KEY_ID is not set"
[ -n "${ISSUER_ID:-}" ] || fail "ISSUER_ID is not set"

umask 077
log_dir=$(mktemp -d "$out_dir/apple-upload.XXXXXXXX")

i=0
for artifact in "$@"; do
  i=$((i + 1))
  n=$(printf '%02d' "$i")
  base=$(basename "$artifact")
  shasum -a 256 "$artifact" > "$log_dir/$n-$base.sha256"
done

i=0
for artifact in "$@"; do
  i=$((i + 1))
  n=$(printf '%02d' "$i")
  base=$(basename "$artifact")
  xcrun altool --validate-app "$artifact" --api-key "$KEY_ID" --api-issuer "$ISSUER_ID" \
    > "$log_dir/$n-$base-validate.log" 2>&1 \
    || fail "validation failed for $artifact (logs: $log_dir)"
done

echo "validated $i artifact(s)"

if [ "$operation" = "upload" ]; then
  i=0
  for artifact in "$@"; do
    i=$((i + 1))
    n=$(printf '%02d' "$i")
    base=$(basename "$artifact")
    xcrun altool --upload-package "$artifact" --wait --api-key "$KEY_ID" --api-issuer "$ISSUER_ID" \
      > "$log_dir/$n-$base-upload.log" 2>&1 \
      || fail "upload failed for $artifact (logs: $log_dir)"
  done
  echo "uploaded $i artifact(s)"
fi

echo "logs: $log_dir"
