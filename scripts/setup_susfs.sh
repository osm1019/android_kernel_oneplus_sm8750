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
KERNEL_TREE=""
FORCE=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --kernel-repo DIR       Path to the kernel repository (defaults to the repo root).
  --ksu-tag TAG           KernelSU tag to clone (default: ${KSU_TAG}).
  --ksu-repo URL          Override the KernelSU git remote (default: ${KSU_REPO_URL}).
  --susfs-ref REF         susfs ref/tag to clone (default: ${SUSFS_REF}).
  --susfs-repo URL        Override the susfs git remote (default: ${SUSFS_REPO_URL}).
  --kernel-tree DIR       Path to the kernel source tree (defaults to "common" under the repo).
  --kernel-version VER    Kernel version suffix for susfs patch selection (default: ${KERNEL_VERSION}).
  --force                 Continue even if the kernel or KernelSU trees have uncommitted changes.
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
    --kernel-tree)
      [[ $# -ge 2 ]] || { echo "error: --kernel-tree requires an argument" >&2; exit 1; }
      KERNEL_TREE=$(cd -- "$2" && pwd)
      shift 2
      ;;
    --kernel-version)
      [[ $# -ge 2 ]] || { echo "error: --kernel-version requires an argument" >&2; exit 1; }
      KERNEL_VERSION="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
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

if [[ -z "${KERNEL_TREE}" ]]; then
  if [[ -d "${KERNEL_REPO}/common" ]]; then
    KERNEL_TREE="${KERNEL_REPO}/common"
  elif [[ -d "${KERNEL_REPO}/arch" && -f "${KERNEL_REPO}/Makefile" ]]; then
    KERNEL_TREE="${KERNEL_REPO}"
  else
    echo "error: unable to determine kernel source tree automatically. Use --kernel-tree to specify it." >&2
    exit 1
  fi
fi

if [[ ! -d "${KERNEL_TREE}" ]]; then
  echo "error: kernel tree ${KERNEL_TREE} does not exist" >&2
  exit 1
fi

echo "Using kernel tree at ${KERNEL_TREE}" >&2

KSU_DIR="${KERNEL_REPO}/KernelSU"
SUSFS_DIR="${KERNEL_REPO}/susfs4ksu"

resolve_remote_ref() {
  local remote=$1
  local ref=$2
  local fetchspec_var=$3

  if git ls-remote --exit-code "${remote}" "refs/tags/${ref}" >/dev/null 2>&1; then
    printf -v "${fetchspec_var}" "refs/tags/%s:refs/tags/%s" "${ref}" "${ref}"
    return 0
  fi

  if git ls-remote --exit-code "${remote}" "${ref}" >/dev/null 2>&1; then
    printf -v "${fetchspec_var}" "%s:%s" "${ref}" "${ref}"
    return 0
  fi

  return 1
}

clone_if_missing() {
  local url=$1
  local ref=$2
  local dest=$3
  local fetchspec=""

  if [[ -d "${dest}/.git" ]]; then
    echo "Skipping clone of ${url}; repository already present at ${dest}" >&2
    return 0
  fi

  if ! resolve_remote_ref "${url}" "${ref}" fetchspec; then
    cat >&2 <<EOF
error: ref ${ref} was not found at ${url}.
       Run "git ls-remote --tags ${url}" to inspect available tags or adjust the --ksu-tag/--susfs-ref argument.
EOF
    exit 1
  fi

  echo "Cloning ${url} (${ref}) into ${dest}..." >&2
  git clone --depth=1 --branch "${ref}" "${url}" "${dest}"
}

ensure_checkout_at_ref() {
  local dest=$1
  local ref=$2
  local fetchspec=""

  pushd "${dest}" >/dev/null
  if git rev-parse --verify --quiet "${ref}" >/dev/null; then
    git checkout --quiet "${ref}"
  else
    if ! resolve_remote_ref origin "${ref}" fetchspec; then
      local remote_url
      remote_url=$(git remote get-url origin)
      cat >&2 <<EOF
error: ref ${ref} was not found on ${remote_url}.
       Run "git -C ${dest} ls-remote --tags origin" to inspect available tags or adjust the requested ref.
EOF
      exit 1
    fi

    echo "Fetching ref ${ref} in $(pwd)..." >&2
    git fetch --depth=1 origin "${fetchspec}"
    git checkout --quiet "${ref}"
  fi
  popd >/dev/null
}

clone_if_missing "${KSU_REPO_URL}" "${KSU_TAG}" "${KSU_DIR}"
ensure_checkout_at_ref "${KSU_DIR}" "${KSU_TAG}"

clone_if_missing "${SUSFS_REPO_URL}" "${SUSFS_REF}" "${SUSFS_DIR}"
ensure_checkout_at_ref "${SUSFS_DIR}" "${SUSFS_REF}"

require_clean_tree() {
  local workdir=$1
  local label=$2

  if ! git -C "${workdir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi

  if [[ ${FORCE} -eq 1 ]]; then
    return
  fi

  if [[ -n "$(git -C "${workdir}" status --porcelain)" ]]; then
    cat >&2 <<EOF
error: ${label} contains uncommitted changes.
       Please clean the tree (e.g. "git -C ${workdir} reset --hard" and "git -C ${workdir} clean -fd")
       or re-run this script with --force to bypass the safety check.
EOF
    exit 1
  fi
}

require_clean_tree "${KSU_DIR}" "KernelSU checkout"
require_clean_tree "${KERNEL_TREE}" "kernel source tree"

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

select_kernel_patch() {
  local base_dir=$1
  local version=$2

  local explicit="${base_dir}/50_add_susfs_in_kernel-${version}.patch"
  if [[ -f "${explicit}" ]]; then
    printf '%s\n' "${explicit}"
    return 0
  fi

  local generic="${base_dir}/50_add_susfs_in_kernel.patch"
  if [[ -f "${generic}" ]]; then
    printf '%s\n' "${generic}"
    return 0
  fi

  local candidates=()
  while IFS= read -r entry; do
    candidates+=("${entry}")
  done < <(find "${base_dir}" -maxdepth 1 -type f -name '50_add_susfs_in_kernel*.patch' -printf '%f\n' | sort)

  if [[ ${#candidates[@]} -eq 1 ]]; then
    printf '%s\n' "${base_dir}/${candidates[0]}"
    return 0
  fi

  echo "error: could not determine kernel patch for susfs under ${base_dir}" >&2
  if (( ${#candidates[@]} )); then
    echo "       Available patch files:" >&2
    for candidate in "${candidates[@]}"; do
      echo "         - ${candidate}" >&2
    done
  else
    echo "       No patch files matching 50_add_susfs_in_kernel*.patch were found." >&2
  fi
  echo "       Specify a matching suffix via --kernel-version or place the expected patch in the directory." >&2
  return 1
}

SUSFS_KERNEL_PATCH_SRC=$(select_kernel_patch "${SUSFS_DIR}/kernel_patches" "${KERNEL_VERSION}")
SUSFS_KERNEL_PATCH_DST="${KERNEL_TREE}/50_add_susfs_in_kernel.patch"
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

copy_payload "${SUSFS_DIR}/kernel_patches/fs" "${KERNEL_TREE}/fs"
copy_payload "${SUSFS_DIR}/kernel_patches/include/linux" "${KERNEL_TREE}/include/linux"

apply_patch() {
  local workdir=$1
  local patch_file=$2
  local description=$3

  echo "Applying ${description}..." >&2

  if git -C "${workdir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "${workdir}" apply --check "${patch_file}" >/dev/null 2>&1; then
      git -C "${workdir}" apply "${patch_file}"
      echo "Applied ${description}." >&2
      return
    fi

    if git -C "${workdir}" apply --reverse --check "${patch_file}" >/dev/null 2>&1; then
      echo "${description} already applied; skipping." >&2
      return
    fi

    if git -C "${workdir}" apply --3way --check "${patch_file}" >/dev/null 2>&1; then
      echo "Applying ${description} with three-way merge..." >&2
      git -C "${workdir}" apply --3way "${patch_file}"
      echo "Applied ${description} (three-way merge)." >&2
      return
    fi

    cat >&2 <<EOF
error: failed to apply ${description} automatically with git apply.
       No changes were made. Ensure ${patch_file} matches your sources or resolve it manually.
EOF
    exit 1
  fi

  if patch --directory="${workdir}" --strip=1 --dry-run <"${patch_file}" >/dev/null 2>&1; then
    patch --directory="${workdir}" --strip=1 <"${patch_file}" >/dev/null
    echo "Applied ${description}." >&2
    return
  fi

  if patch --directory="${workdir}" --strip=1 --reverse --dry-run <"${patch_file}" >/dev/null 2>&1; then
    echo "${description} already applied; skipping." >&2
    return
  fi

  cat >&2 <<EOF
error: failed to apply ${description} automatically with patch.
       The worktree was not modified. Inspect ${patch_file} and adjust your sources or --kernel-version.
EOF
  exit 1
}

apply_patch "${KSU_DIR}" "${SUSFS_KSU_PATCH_DST}" "KernelSU susfs hook patch"
apply_patch "${KERNEL_TREE}" "${SUSFS_KERNEL_PATCH_DST}" "kernel susfs integration patch"

echo "susfs integration complete.  Review Kconfig options (CONFIG_KSU, CONFIG_KSU_SUSFS, etc.) before building." >&2
