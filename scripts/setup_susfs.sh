#!/bin/bash
# Wrapper script to integrate susfs from upstream projects.
# This script fetches the upstream setup helper and delegates to it.
set -euo pipefail

BRANCH="${1:-main}"

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required to run this script" >&2
  exit 1
fi

SCRIPT_URL="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh"

echo "Downloading susfs setup helper from ${SCRIPT_URL} for branch ${BRANCH}..." >&2
curl -LSs "${SCRIPT_URL}" | bash -s "${BRANCH}"
