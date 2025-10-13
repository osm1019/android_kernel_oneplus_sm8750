#!/bin/bash
# Automated susfs integration helper for KernelSU-based builds.
#
# This script follows the official KernelSU integration flow and layers in the
# susfs patches from Simon's repository.  It performs the following steps:
#   1. Clone KernelSU at the requested tag (if not already present).
#   2. Clone the susfs integration repository at the requested ref.
#   3. Copy the susfs patch payloads into the kernel tree.
#   4. Apply the KernelSU and kernel susfs patches.
#   5. Leave the susfs sources under the kernel root for future updates.
#
# Usage:
#   ./scripts/setup_susfs.sh [--kernel-repo DIR] [--ksu-tag TAG]
#       [--ksu-repo URL] [--susfs-ref REF] [--susfs-repo URL]
#       [--kernel-version VERSION]
#
# By default the script assumes it is executed from the kernel checkout root
# (the directory that contains the "common" sub-directory).  All arguments are
# optional and allow advanced usage such as pointing to local mirrors.
#
# Notes:
#   * The script clones repositories with history depth 1 to minimise download
#     size.  To re-run with a different ref, delete the existing directories or
#     use git commands manually inside them.
#   * After the patches are applied you must enable CONFIG_KSU and
#     CONFIG_KSU_SUSFS (and adjust individual SUSFS options as desired) before
#     building the kernel.
#   * If your tree already has the KernelSU non-kprobe hook patches merged, you
#     must disable CONFIG_KSU_SUSFS_SUS_SU to avoid conflicts.
#   * For Android 14+ GKI builds from Google artifacts you may need to remove
#     the protected ABI export lists under common/android as described in the
#     susfs documentation.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_KERNEL_REPO=$(cd -- "${SCRIPT_DIR}/.." && pwd)

KERNEL_REPO=${KERNEL_REPO:-${DEFAULT_KERNEL_REPO}}
KSU_REPO_URL="https://github.com/tiann/KernelSU.git"
KSU_TAG="v0.9.5"
SUSFS_REPO_URL="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_REF="v2.5.0"
KERNEL_VERSION="6.6"

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --kernel-repo DIR       Path to the kernel repository (defaults to the repo root).
  --ksu-tag TAG           KernelSU tag to clone (default: ${KSU_TAG}).
  --ksu-repo URL          Override the KernelSU git remote (default: ${KSU_REPO_URL}).
  --susfs-ref REF         susfs ref/tag to clone (default: ${SUSFS_REF}).
  --susfs-repo URL        Override the susfs git remote (default: ${SUSFS_REPO_URL}).
  --kernel-version VER    Kernel version suffix for susfs patch selection (default: ${KERNEL_VERSION}).
  -h, --help              Show this message and exit.

Environment overrides:
  KERNEL_REPO             Same as --kernel-repo.
USAGE
}

OPTS=()
while (( $# )); do
  case "$1" in
    --kernel-repo)
      [[ $# -ge 2 ]] || { echo "error: --kernel-repo requires an argument" >&2; exit 1; }
      KERNEL_REPO=$(cd -- "$2" && pwd)
      shift 2
      ;;
    --ksu-tag)
      [[ $# -ge 2 ]] || { echo "error: --ksu-tag requires an argument" >&2; exit 1; }
      KSU_TAG="$2"
      shift 2
      ;;
    --ksu-repo)
      [[ $# -ge 2 ]] || { echo "error: --ksu-repo requires an argument" >&2; exit 1; }
      KSU_REPO_URL="$2"
      shift 2
      ;;
    --susfs-ref)
      [[ $# -ge 2 ]] || { echo "error: --susfs-ref requires an argument" >&2; exit 1; }
      SUSFS_REF="$2"
      shift 2
      ;;
    --susfs-repo)
      [[ $# -ge 2 ]] || { echo "error: --susfs-repo requires an argument" >&2; exit 1; }
      SUSFS_REPO_URL="$2"
      shift 2
      ;;
    --kernel-version)
      [[ $# -ge 2 ]] || { echo "error: --kernel-version requires an argument" >&2; exit 1; }
      KERNEL_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      OPTS+=("$@")
      break
      ;;
    -*)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
    *)
      OPTS+=("$1")
      shift
      ;;
  esac
done
set -- "${OPTS[@]}"

if [[ ! -d "${KERNEL_REPO}/common" ]]; then
  echo "error: ${KERNEL_REPO} does not look like a kernel repository root (missing common/)" >&2
  exit 1
fi

KSU_DIR="${KERNEL_REPO}/KernelSU"
SUSFS_DIR="${KERNEL_REPO}/susfs4ksu"

clone_if_missing() {
  local url=$1
  local ref=$2
  local dest=$3
  if [[ -d "${dest}/.git" ]]; then
    echo "Skipping clone of ${url}; repository already present at ${dest}" >&2
    return 0
  fi
  echo "Cloning ${url} (${ref}) into ${dest}..." >&2
  git clone --depth=1 --branch "${ref}" "${url}" "${dest}"
}

ensure_checkout_at_ref() {
  local dest=$1
  local ref=$2
  pushd "${dest}" >/dev/null
  if git rev-parse --verify --quiet "${ref}" >/dev/null; then
    git checkout --quiet "${ref}"
  else
    echo "Fetching ref ${ref} in $(pwd)..." >&2
    git fetch --tags --depth=1 origin "refs/tags/${ref}:refs/tags/${ref}" || \
      git fetch --depth=1 origin "${ref}:${ref}"
    git checkout --quiet "${ref}"
  fi
  popd >/dev/null
}

clone_if_missing "${KSU_REPO_URL}" "${KSU_TAG}" "${KSU_DIR}"
ensure_checkout_at_ref "${KSU_DIR}" "${KSU_TAG}"

clone_if_missing "${SUSFS_REPO_URL}" "${SUSFS_REF}" "${SUSFS_DIR}"
ensure_checkout_at_ref "${SUSFS_DIR}" "${SUSFS_REF}"

copy_payload() {
  local src=$1
  local dest=$2
  if [[ ! -d "${src}" ]]; then
    echo "error: expected directory ${src}" >&2
    exit 1
  fi
  mkdir -p "${dest}"
  cp -a "${src}"/. "${dest}"/
}

SUSFS_KERNEL_PATCH_SRC="${SUSFS_DIR}/kernel_patches/50_add_susfs_in_kernel-${KERNEL_VERSION}.patch"
SUSFS_KERNEL_PATCH_DST="${KERNEL_REPO}/common/50_add_susfs_in_kernel.patch"
SUSFS_KSU_PATCH_SRC="${SUSFS_DIR}/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
SUSFS_KSU_PATCH_DST="${KSU_DIR}/10_enable_susfs_for_ksu.patch"

if [[ ! -f "${SUSFS_KERNEL_PATCH_SRC}" ]]; then
  echo "error: could not find kernel patch ${SUSFS_KERNEL_PATCH_SRC}" >&2
  exit 1
fi
if [[ ! -f "${SUSFS_KSU_PATCH_SRC}" ]]; then
  echo "error: could not find KernelSU patch ${SUSFS_KSU_PATCH_SRC}" >&2
  exit 1
fi

echo "Copying susfs patch payloads..." >&2
install -m 0644 "${SUSFS_KSU_PATCH_SRC}" "${SUSFS_KSU_PATCH_DST}"
install -m 0644 "${SUSFS_KERNEL_PATCH_SRC}" "${SUSFS_KERNEL_PATCH_DST}"

copy_payload "${SUSFS_DIR}/kernel_patches/fs" "${KERNEL_REPO}/common/fs"
copy_payload "${SUSFS_DIR}/kernel_patches/include/linux" "${KERNEL_REPO}/common/include/linux"

apply_patch() {
  local workdir=$1
  local patch_file=$2
  local description=$3
  echo "Applying ${description}..." >&2
  if patch --directory="${workdir}" --strip=1 --dry-run <"${patch_file}" >/dev/null 2>&1; then
    patch --directory="${workdir}" --strip=1 <"${patch_file}" >/dev/null
    echo "Applied ${description}." >&2
  elif patch --directory="${workdir}" --strip=1 --reverse --dry-run <"${patch_file}" >/dev/null 2>&1; then
    echo "${description} already applied; skipping." >&2
  else
    echo "error: failed to apply ${description}" >&2
    exit 1
  fi
}

apply_patch "${KSU_DIR}" "${SUSFS_KSU_PATCH_DST}" "KernelSU susfs hook patch"
apply_patch "${KERNEL_REPO}/common" "${SUSFS_KERNEL_PATCH_DST}" "kernel susfs integration patch"

echo "susfs integration complete.  Review Kconfig options (CONFIG_KSU, CONFIG_KSU_SUSFS, etc.) before building." >&2
