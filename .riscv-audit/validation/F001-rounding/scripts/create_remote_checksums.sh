#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 EXISTING_REMOTE_EVIDENCE_DIRECTORY" >&2
    exit 2
fi

evidence_dir=$1
checksum_file="$evidence_dir/remote-files-sha256.txt"

if [[ ! -d "$evidence_dir" ]]; then
    echo "evidence directory not found: $evidence_dir" >&2
    exit 2
fi
if [[ -e "$checksum_file" ]]; then
    echo "refusing to overwrite: $checksum_file" >&2
    exit 2
fi
for tool in find sort sha256sum xargs; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "required tool not found: $tool" >&2
        exit 2
    }
done

(
    cd "$evidence_dir"
    find . -type f \
        ! -name remote-files-sha256.txt \
        ! -name '*.o' \
        ! -name test_fp16_isa \
        -print0 |
        sort -z |
        xargs -0 sha256sum
) >"$checksum_file"
