#!/usr/bin/env bash
set -euo pipefail

EXPECTED_REPOSITORY='HakureiPOI/vllm'
EXPECTED_BASE_COMMIT='57f327ef9c827788c85c0a69c0cf86e446ff27ae'
EXPECTED_INSTRUMENTED_BLOB='766edb26ee5e29d5b16bd63d25b3d2ed5b1a0aa7'
EXPECTED_MARKER_COUNT=13
TARGET_REL='cmake/cpu_extension.cmake'

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
VALIDATION="$ROOT/.riscv-audit/validation/F004-cross-compile"
PATCH="$VALIDATION/instrumentation/f004-log-only.patch"
TARGET="$ROOT/$TARGET_REL"

ORIGIN="$(git -C "$ROOT" remote get-url origin)"
if [[ ! "$ORIGIN" =~ (^|[:/])${EXPECTED_REPOSITORY}(\.git)?$ ]]; then
    echo "unexpected origin: $ORIGIN" >&2
    exit 1
fi

EXPECTED_BLOB="$(
    git -C "$ROOT" rev-parse "$EXPECTED_BASE_COMMIT:$TARGET_REL"
)"
CURRENT_BLOB="$(git -C "$ROOT" hash-object "$TARGET_REL")"
MARKER_COUNT="$(grep -Fc 'message(STATUS "[F004]' "$TARGET" || true)"

if [[ "$CURRENT_BLOB" == "$EXPECTED_BLOB" ]]; then
    echo "instrumentation is not applied" >&2
    exit 1
fi

if [[ "$CURRENT_BLOB" != "$EXPECTED_INSTRUMENTED_BLOB" ]]; then
    echo "target contains changes outside the exact instrumentation patch" >&2
    exit 1
fi

if [[ "$MARKER_COUNT" -ne "$EXPECTED_MARKER_COUNT" ]]; then
    echo "target is not the expected instrumented file" >&2
    exit 1
fi

git -C "$ROOT" apply --unidiff-zero --check -R "$PATCH" || {
    echo "exact instrumentation patch cannot be reversed" >&2
    exit 1
}

git -C "$ROOT" apply --unidiff-zero -R "$PATCH"
RESTORED_BLOB="$(git -C "$ROOT" hash-object "$TARGET_REL")"
if [[ "$RESTORED_BLOB" != "$EXPECTED_BLOB" ]]; then
    echo "reverse patch did not restore the validated baseline" >&2
    exit 1
fi

echo "instrumentation removed"
echo "restored blob: $RESTORED_BLOB"
