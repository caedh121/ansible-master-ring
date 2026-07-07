# host-setup — provisioning a Windows Docker host for the testbox

Scripts that turn a fresh Windows VM into a Docker host that can run the
[testbox](../README.md). The testbox is a Linux container; this bootstraps
the WSL2 + Docker CE stack it runs on.

## Install-DockerWSL2.ps1

Two-phase installer for WSL2 + Docker CE inside Ubuntu 22.04 on:

- Windows 10 (build 19041+) / Windows 11 workstations
- Windows Server 2022 (build 20348+) — server SKU is auto-detected and
  the Hyper-V role is enabled alongside `VirtualMachinePlatform`

The reboot in the middle is handled via a `HKLM RunOnce` entry, so no
operator action is needed after kickoff. Phase 2 auto-runs at the next
admin login.

### Usage

```powershell
# On the target Windows VM, as Administrator:
Set-ExecutionPolicy -Scope Process Bypass -Force

# 1. Sanity-check the VM before touching anything (recommended):
.\Install-DockerWSL2.ps1 -Preflight

# 2. If preflight looks good, run for real:
.\Install-DockerWSL2.ps1
```

Parameters (all optional):

| Param | Default | Purpose |
|---|---|---|
| `-Distro` | `Ubuntu-22.04` | WSL distro to install |
| `-User` | `dockeruser` | Linux user created inside the distro (passwordless sudo, added to `docker` group) |
| `-Preflight` | _(off)_ | Only run environment checks; change nothing |
| `-Phase` | `1` | Internal — RunOnce sets this to `2` after reboot |

### VMware / nested virtualization

WSL2 uses the Windows Hypervisor Platform, which needs the CPU's VT-x/EPT
(or AMD-V/RVI) visible inside the guest. Enable it on the VM **before**
running the script:

| VMware product | Setting |
|---|---|
| Workstation Pro / Fusion Pro | VM Settings → Processors → *Virtualize Intel VT-x/EPT or AMD-V/RVI* |
| vSphere / ESXi | VM Settings → CPU → *Expose hardware assisted virtualization to the guest OS* |

Power-cycle the VM after enabling. `-Preflight` inspects
`SecondLevelAddressTranslationExtensions` and `VirtualizationFirmwareEnabled`
and warns if either is `False` — without them, Phase 1 succeeds but the
distro fails to start in Phase 2 with `HCS_E_HYPERV_NOT_INSTALLED`.

### What Phase 2 leaves you with

Inside the WSL Ubuntu distro:

- Docker CE (`docker-ce`, `docker-buildx-plugin`, `docker-compose-plugin`) from Docker's official Ubuntu apt repo
- systemd enabled (`/etc/wsl.conf` has `[boot] systemd=true`), so `docker` starts on distro boot
- The `dockeruser` account with passwordless sudo, in the `docker` group

Smoke test:

```powershell
wsl -d Ubuntu-22.04 -- docker version
wsl -d Ubuntu-22.04 -- docker run --rm hello-world
```

From here the [testbox](../README.md) will run: `docker/run.sh` (from WSL)
or `docker\run.ps1` (from Windows, uses the WSL2 backend automatically).

### Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Preflight: `VirtFirmware: False` | Nested virtualization not exposed. Enable it on the VM (see VMware table above), power-cycle, re-run preflight. |
| Phase 2 never starts after reboot | RunOnce fires on next *admin* login. Log in as the admin you ran Phase 1 as. If missed, re-run manually: `.\Install-DockerWSL2.ps1 -Phase 2` |
| `wsl` prints `HCS_E_HYPERV_NOT_INSTALLED` | Same as row 1 — nested virt missing. |
| `systemctl` errors in Phase 2 | WSL kernel too old for systemd. Run `wsl --update`, then re-run `.\Install-DockerWSL2.ps1 -Phase 2` |
| Docker install can't reach `download.docker.com` | Corporate proxy / firewall. Set proxy env vars in WSL (`sudo tee /etc/environment`) before re-running Phase 2. |
