#!/usr/bin/env bash
# Mirror the Windows checkout into a WSL ext4 directory. Building C++, Rust,
# and VHDL directly on /mnt/c (9p) is several times slower and sees Windows
# file modes; the mirror keeps Git metadata so drift checks still work.
set -euo pipefail

source_dir="${1:-/mnt/c/Users/121679/hft-toy-project}"
target_dir="${2:-${HOME}/hft-ci}"

mkdir -p "${target_dir}"
# /mnt/c reports every file as executable; take modes from Git instead
# (--chmod also resets files already in the mirror).
rsync -a --delete --chmod=D755,F644 \
  --exclude '/build/' --exclude '/target/' --exclude '/vunit_out/' --exclude '/work/' \
  --exclude '/coverage-reports/' --exclude '/demo/out/' --exclude '/.venv/' \
  --exclude 'node_modules/' --exclude '__pycache__/' --exclude '.ruff_cache/' \
  --exclude '.pytest_cache/' --exclude '.mypy_cache/' --exclude '/yocto/build/' \
  --exclude '/yocto/downloads/' --exclude '/yocto/sstate-cache/' \
  --exclude '/downloads/' --exclude '/sstate-cache/' \
  "${source_dir}/" "${target_dir}/"

# Windows-side tools can leave CRLF in new files that Git has not normalized
# yet; Linux shells and generators must see LF. Only files Git knows about
# are touched: build trees in the mirror (CMake, Cargo, Yocto) are not ours.
(cd "${target_dir}" &&
  git ls-files -z --cached --others --exclude-standard -- \
    ':!*.ps1' ':!*.bat' ':!*.cmd' |
  xargs -0 -r grep -lIZ $'\r' 2>/dev/null |
  xargs -0 -r sed -i 's/\r$//') || true
git -C "${target_dir}" ls-files -s | awk '$1 == "100755" { print $4 }' |
  (cd "${target_dir}" && xargs -r chmod +x)
find "${target_dir}/scripts" "${target_dir}/demo" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
echo "synced ${source_dir} -> ${target_dir}"
