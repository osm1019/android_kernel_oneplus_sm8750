# susfs integration helper

This repository now includes a convenience wrapper for integrating the [susfs for KernelSU](https://gitlab.com/simonpunk/susfs4ksu/-/tree/gki-android15-6.6?ref_type=heads) project.

## Quick start

Run the helper script from the root of the kernel tree to fetch the upstream setup script and execute it with the `main` branch by default:

```bash
./scripts/setup_susfs.sh
```

To target a different branch from the upstream helper, pass it as the first argument:

```bash
./scripts/setup_susfs.sh gki-android15-6.6
```

The wrapper uses `curl` to download `https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh` and pipes it to `bash`. The upstream script performs the detailed integration steps, including fetching susfs sources and applying any required patches.

> **Note:** Network access is required when running the helper script because it downloads content directly from the upstream repositories.
