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

if grep -Fq '[F004] Instrumentation:' "$TARGET"; then
    echo "instrumentation already applied" >&2
    exit 1
fi

if [[ "$CURRENT_BLOB" != "$EXPECTED_BLOB" ]]; then
    echo "target blob does not match the validated baseline" >&2
    echo "expected: $EXPECTED_BLOB" >&2
    echo "current:  $CURRENT_BLOB" >&2
    exit 1
fi

if awk '
    /^--- / { next }
    /^-/ { exit 1 }
' "$PATCH"; then
    :
else
    echo "instrumentation patch removes source lines" >&2
    exit 1
fi

if awk '
    /^\+\+\+ / { next }
    /^\+/ {
        line = substr($0, 2)
        if (line !~ /^[[:space:]]*$/ &&
            line !~ /^[[:space:]]*#/ &&
            line !~ /^[[:space:]]*message\(STATUS /) {
            exit 1
        }
    }
' "$PATCH"; then
    :
else
    echo "instrumentation patch adds non-observational code" >&2
    exit 1
fi

git -C "$ROOT" apply --unidiff-zero --check "$PATCH"
git -C "$ROOT" apply --unidiff-zero "$PATCH"

INSTRUMENTED_BLOB="$(git -C "$ROOT" hash-object "$TARGET_REL")"
if [[ "$INSTRUMENTED_BLOB" != "$EXPECTED_INSTRUMENTED_BLOB" ]]; then
    echo "applied patch produced an unexpected target blob" >&2
    exit 1
fi

MARKER_COUNT="$(grep -Fc 'message(STATUS "[F004]' "$TARGET")"
if [[ "$MARKER_COUNT" -ne "$EXPECTED_MARKER_COUNT" ]]; then
    echo "unexpected instrumentation marker count: $MARKER_COUNT" >&2
    exit 1
fi

git -C "$ROOT" apply --unidiff-zero --check -R "$PATCH"
git -C "$ROOT" diff --check -- "$TARGET_REL"

echo "instrumentation applied"
echo "repository: $ROOT"
echo "origin: $ORIGIN"
echo "baseline blob: $EXPECTED_BLOB"
echo "instrumented blob: $INSTRUMENTED_BLOB"
