# susfs integration helper

This repository ships an automated helper, `scripts/setup_susfs.sh`, to follow the
[official KernelSU build guide](https://kernelsu.org/guide/how-to-build.html)
while layering in the susfs enhancements from Simon's
[susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) project.

The helper performs the entire workflow locally so that the susfs patches are
actually staged inside this source tree.  It clones the required upstream
repositories at stable tags, copies the patch payloads into place, and applies
them on top of your kernel checkout.  After the script completes you can build
and flash the kernel directly from this tree without re-running the helper.

## Prerequisites

* A working git installation with network access to GitHub and GitLab.
* The standard `patch` and `install` utilities available in `PATH`.
* Enough disk space to clone the KernelSU and susfs repositories into the kernel
  root.

## Quick start

Run the helper from the kernel repository root:

```bash
./scripts/setup_susfs.sh
```

By default the script assumes this repository layout (`common/` as the kernel
root), clones `KernelSU` at tag `v0.9.5`, and clones `susfs4ksu` at tag
`v2.5.0`.  The susfs kernel patch set is selected for Linux `6.6`.  If your
kernel checkout does not use a `common/` sub-directory (for example, device
trees that operate directly from the repository root), the helper will
automatically fall back to that root.  You can also point it to any other
location explicitly with `--kernel-tree`.

To customise any of these inputs, pass the relevant options.  For example, to
use a different KernelSU tag and susfs ref:

```bash
./scripts/setup_susfs.sh --ksu-tag v0.9.6 --susfs-ref v2.5.1
```

The script accepts the following options:

| Option | Description |
| --- | --- |
| `--kernel-repo DIR` | Override the kernel repository root (defaults to the current repo). |
| `--kernel-tree DIR` | Override the kernel source tree location (auto-detected as `common/` or the repo root). |
| `--ksu-tag TAG` | KernelSU tag to clone/checkout. |
| `--ksu-repo URL` | Alternative KernelSU remote (e.g. local mirror). |
| `--susfs-ref REF` | susfs git ref (tag or commit). Choose tags or commits that bump the susfs version for stability. |
| `--susfs-repo URL` | Alternative susfs remote. |
| `--kernel-version VER` | Kernel version used to pick the `50_add_susfs_in_kernel-<VER>.patch` file (default `6.6`). |

The helper is idempotent: re-running it will skip cloning if the repositories
already exist, and it only applies patches that have not yet been merged.  To
switch to a different tag or ref, delete the relevant `KernelSU/` or
`susfs4ksu/` directories first or use git commands manually within them.

## What the script does

1. Determines the kernel source tree (preferring `common/`, falling back to the
   repository root, or respecting `--kernel-tree`).
2. Clones `KernelSU` into `$KERNEL_REPO/KernelSU` at the specified tag.
3. Clones `susfs4ksu` into `$KERNEL_REPO/susfs4ksu` at the specified ref.
4. Copies the following payload into your tree:
   * `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch` → `KernelSU/`.
   * `kernel_patches/50_add_susfs_in_kernel-<kernel_version>.patch` →
     `<kernel_tree>/50_add_susfs_in_kernel.patch`.
   * `kernel_patches/fs/*` → `<kernel_tree>/fs/`.
   * `kernel_patches/include/linux/*` → `<kernel_tree>/include/linux/`.
5. Applies the KernelSU susfs enablement patch (`patch -p1` inside `KernelSU/`).
6. Applies the kernel susfs integration patch (`patch -p1` inside the kernel
   source tree).

Once the script finishes, proceed with the standard KernelSU build flow inside
the detected kernel tree (for AOSP GKI this is `common/`).  The cloned
`susfs4ksu` directory is left in place for future updates.

## Post integration checklist

* Enable `CONFIG_KSU` and `CONFIG_KSU_SUSFS` before compiling.  Individual
  `CONFIG_KSU_SUSFS_*` options default to conservative values; adjust them via
  `menuconfig`, defconfig edits, or by tweaking the defaults in
  `KernelSU/kernel/Kconfig`.
* If your tree already contains the KernelSU non-kprobe hook patches, disable
  `CONFIG_KSU_SUSFS_SUS_SU` to prevent duplicate hook definitions.
* Optional: extend `ksu_is_manager_apk()` in `KernelSU/kernel/apk_sign.c` with
  additional manager APK hashes if you rely on variants besides the upstream
  KernelSU manager.
* For Android 14+ GKI kernels built from Google artifacts, delete the following
  files before building to avoid ABI protected export conflicts with modules
  such as Wi-Fi:
  * `common/android/abi_gki_protected_exports_aarch64`
  * `common/android/abi_gki_protected_exports_x86_64`
* When producing flashable images, ensure the SPL date passed to
  `build_gki_boot_images()` in `build/kernel/build_utils.sh` matches your device.
  Alternatively, unpack and repack the stock boot image with `magiskboot`.

## Troubleshooting

* If the patch application fails, inspect the rejects inside the respective
  directories.  Manual conflict resolution may be required when combining with
  additional kernel modifications.
* When requesting a KernelSU tag or susfs ref, ensure it exists upstream.  The
  helper validates the ref before cloning or fetching and will report how to
  list the available tags if it cannot find the requested value.
* Make sure the selected `--kernel-version` aligns with the susfs branch you
  intend to use.  The helper aborts if it cannot locate the corresponding
  `50_add_susfs_in_kernel-<VER>.patch` file.
* The helper requires network access to fetch git repositories.  When operating
  behind a proxy, configure the standard `git config --global http.proxy` or use
  mirrored repositories with `--ksu-repo`/`--susfs-repo`.
