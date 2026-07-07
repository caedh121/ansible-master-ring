# master_ring.windows_remote

[![CI](https://github.com/caedh121/ansible-master-ring/actions/workflows/ci.yml/badge.svg)](https://github.com/caedh121/ansible-master-ring/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../LICENSE)
[![ansible-core](https://img.shields.io/badge/ansible--core-%E2%89%A5%202.15-black?logo=ansible)](https://docs.ansible.com/)

Manage Windows VMs over WinRM from an on-prem **Linux** Ansible controller across
**AWS, Azure, and GCP — without a VPN.**

## The problem

Your Ansible controller sits on-prem (or in one cloud) and needs to configure
Windows VMs across AWS, Azure, and GCP. Those VMs have **no inbound network
path** to the controller: WinRM (5985/5986) is not reachable directly, by design.

## The answer

Each cloud ships an identity-based tunnel to a private instance — AWS SSM,
Azure Bastion, GCP IAP. This collection wraps all three behind one Ansible
interface so a single inventory + play reaches Windows through whichever
tunnel the target's cloud provides: per-VM, per-session, IAM-scoped, and
logged to the cloud's native audit trail.

| Cloud | Tunnel | Underlying CLI |
|-------|--------|----------------|
| AWS   | SSM Session Manager port-forward | `aws ssm start-session` + `session-manager-plugin` |
| Azure | Bastion tunnel | `az network bastion tunnel` |
| GCP   | IAP TCP tunnel | `gcloud compute start-iap-tunnel` |

```
                 controller (Linux + Ansible)
                          │
      ┌───────────────────┼───────────────────┐
      │                   │                   │
 aws ssm             az bastion           gcloud iap
 start-session        tunnel             start-iap-tunnel
      │                   │                   │
  localhost:PORT ─────────┴───────────────────┘   (the tunnel role rewrites
      │                                             ansible_host=localhost and
      ▼                                             ansible_port=PORT)
  WinRM 5986  ──►  Windows VM (private, no inbound path)
```

## How the tunnel roles work

Each tunnel role opens a background tunnel from the controller to the target's
WinRM port, binding a **local** listener (e.g. `localhost:55986`). It then
**rewrites the host's `ansible_host` to `localhost` and `ansible_port` to the
local tunnel port** with `set_fact`. Every subsequent task in the play talks to
WinRM transparently through the tunnel — no other role needs to know a tunnel
exists.

The roles are **idempotent**: they probe for an already-running tunnel on the
target port (and, for IAP/Bastion, verify the recorded PID actually owns the
listener) before starting a new one. They persist PID/port/session state files
under `ssm_tunnel_state_dir` (default `/tmp/ansible_tunnels`) so reruns and
teardown are safe and don't collide across concurrent runs.

The AWS SSM tunnel role ends with `meta: reset_connection`. This is required:
after a tunnel (re)build, pywinrm caches a TCP socket against the old port and
the next CredSSP exchange fails without a connection reset. **Do not remove it.**

## Roles

| Role | Purpose | Key inputs | Effect / outputs |
|------|---------|-----------|------------------|
| `transport` | Resolve which transport carries a host's WinRM connection | `winrm_via` (or legacy `use_*` flags + `platform`) | Sets `winrm_via_resolved` (`direct`/`ssm`/`iap`/`bastion`) — the single fact `win_reboot` and `generate_rdp` dispatch on |
| `aws_ssm_tunnel` | Open an SSM port-forward to WinRM on AWS/hybrid instances | `ansible_id`, `ansible_aws_ssm_region`, `ansible_port`, `use_ssm` | Rewrites `ansible_host`/`ansible_port`; writes `.pid`/`.sid`/`.port` state |
| `azure_bastion_tunnel` | Open an Azure Bastion tunnel to WinRM | `azure_vm_resource_id`, `azure_bastion_name`/`_resource_group_name`/`_subscription_id`, `ansible_port` | Rewrites `ansible_host`/`ansible_port`; `tasks_from: teardown` to close |
| `gcp_iap_tunnel` | Open a GCP IAP TCP tunnel to WinRM | `gcp_project`, `gcp_availability_zone`, `ansible_port` | Rewrites `ansible_host`/`ansible_port`; `tasks_from: teardown` to close |
| `win_readiness` | Wait until WinRM and Explorer are up | _(none)_ | Blocks until the VM can run local commands |
| `win_reboot` | Reboot, dispatching to the right transport | `winrm_via` (or legacy flags) | Reboots via direct/SSM/IAP/Bastion path |
| `aws_ssm_reboot` | Tunnel-aware reboot for SSM-connected hosts | `ansible_id`, `ansible_aws_ssm_region`, `ssm_tunnel_state_dir` | Reboots via SSM, then rebuilds the SSM tunnel |
| `generate_rdp` | Emit RDP artifacts/launchers for end users | `platform`, `domain_admin_user`, `rdp_target_host`, `rdp_output_dir` | Writes `.rdp` / self-contained PowerShell launchers (optionally emails them) |

See each role's `README.md` under `roles/<role>/` for its full variable
reference.

## Transport selection

Declare each host's transport explicitly with **`winrm_via`**
(`direct` | `ssm` | `iap` | `bastion`) — host var, group var, or play var. The
`transport` role resolves it into `winrm_via_resolved`, the single
fact that `win_reboot` (reboot path) and `generate_rdp` (artifact choice)
dispatch on, so those decisions can never disagree. When `winrm_via` is
unset, it derives from `platform` + the legacy `use_ssm`/`use_iap`/
`use_azure_bastion` flags (GCP defaults to `iap`; see
`roles/transport/README.md`). The flags remain supported but deprecated.

## Tunnel behavior during reboot (important)

Reboots interact differently with each tunnel — `win_reboot` dispatches
accordingly based on the resolved transport:

- **Azure Bastion — SURVIVES reboot.** The `az network bastion tunnel` process
  runs on the controller and reconnects when the VM returns. `win_reboot` uses a
  plain `win_reboot` with `ignore_unreachable: true`.
- **GCP IAP — SURVIVES reboot.** The `gcloud compute start-iap-tunnel` process
  stays alive on the controller and reconnects. `win_reboot` uses a plain
  `win_reboot`.
- **AWS SSM — DIES on reboot.** The SSM session is tied to the guest agent, so a
  reboot drops the tunnel. `win_reboot` dispatches to `aws_ssm_reboot`, which:
  1. Sends `shutdown /r /f /t 3` via `aws ssm send-command`.
  2. Kills the local SSM plugin process and terminates the SSM session (cleans
     state files).
  3. Polls `aws ssm describe-instance-information` `PingStatus` until the
     instance goes offline, then until it returns Online.
  4. Runs a debounce probe confirming the agent accepts commands.
  5. Re-opens the tunnel by importing `aws_ssm_tunnel`.

This is why `aws_ssm_reboot` is a separate role: it is the tunnel-aware reboot
path `win_reboot` selects for SSM-connected hosts.

## Requirements

On the **controller**:

- Ansible (`ansible-core >= 2.15`), plus the `ansible.windows` and
  `community.general` collections.
- **AWS:** AWS CLI v2 and the `session-manager-plugin`; IAM permissions for
  `ssm:DescribeInstanceInformation`, `ssm:DescribeSessions`, `ssm:StartSession`,
  `ssm:SendCommand`, `ssm:TerminateSession` (plus `ec2:RebootInstances` /
  `ec2:DescribeInstanceStatus` for EC2 agent recovery).
- **Azure:** Azure CLI (`az`), authenticated, with Bastion tunnel rights.
- **GCP:** Google Cloud SDK (`gcloud`), authenticated with
  `roles/iap.tunnelResourceAccessor` on the target; `ss` (iproute2) + `/proc`.

On the **target**: WinRM enabled (5985/5986) and the relevant cloud agent
registered (SSM agent for AWS/hybrid).

## Install

```bash
ansible-galaxy collection build .
ansible-galaxy collection install master_ring-windows_remote-1.0.0.tar.gz
```

## Quick start

### AWS (SSM)

```yaml
- hosts: windows_targets
  gather_facts: false
  vars: { platform: aws, winrm_via: ssm }
  pre_tasks:
    - import_role: { name: master_ring.windows_remote.aws_ssm_tunnel }
    - import_role: { name: master_ring.windows_remote.win_readiness }
  roles:
    - my_windows_config_role
  post_tasks:
    - import_role: { name: master_ring.windows_remote.win_reboot }
      when: reboot_needed | default(false)
```

### Azure (Bastion)

```yaml
- hosts: windows_targets
  gather_facts: false
  vars: { platform: azure, winrm_via: bastion }
  pre_tasks:
    - import_role: { name: master_ring.windows_remote.azure_bastion_tunnel }
    - import_role: { name: master_ring.windows_remote.win_readiness }
  roles:
    - my_windows_config_role
```

### GCP (IAP)

```yaml
- hosts: windows_targets
  gather_facts: false
  vars: { platform: gcp, winrm_via: iap }
  pre_tasks:
    - import_role: { name: master_ring.windows_remote.gcp_iap_tunnel }
    - import_role: { name: master_ring.windows_remote.win_readiness }
  roles:
    - my_windows_config_role
```

Full, runnable versions of all three live in `playbooks/examples/`.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---------|--------------|------------|
| `CredSSP ... did not respond with a CredSSP token` right after a reboot/rebuild | pywinrm reused a cached socket against the dead tunnel port | Ensure the tunnel role's final `meta: reset_connection` ran; it is required and must not be removed |
| WinRM hangs / `Read timed out` although the local port is open | An orphaned tunnel keeps the listener open but no longer forwards | IAP/Bastion roles self-heal by killing orphans on the next run; for SSM set `aws_ssm_force_rebuild: true` to force a fresh session |
| `PingStatus=Online` but `send-command` is `Undeliverable` | SSM agent wedged on the guest | `aws_ssm_tunnel` auto-recovers (EC2 reboot on AWS, agent restart over IAP on GCP); otherwise restart `AmazonSSMAgent` on the host manually |
| Tunnel process exits immediately | Missing CLI / plugin or insufficient cloud permissions | Verify the controller requirements above; the role prints the tunnel log on failure |
| Port conflict across concurrent runs | Two hosts share a local tunnel port | Give each host a unique `ansible_port`; state files are keyed per host under `ssm_tunnel_state_dir` |

### Manual fallback

If the automation is unavailable, open the tunnel by hand and point `mstsc`/WinRM
at `localhost:<PORT>`:

```bash
# AWS
aws ssm start-session --target i-0abc123 --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["5986"],"localPortNumber":["55986"]}'

# Azure
az network bastion tunnel --name <bastion> --resource-group <rg> \
  --target-resource-id <vm-resource-id> --resource-port 5986 --port 55986

# GCP
gcloud compute start-iap-tunnel <vm> 5986 \
  --project=<project> --zone=<zone> --local-host-port=localhost:55986
```

## License

MIT — see [LICENSE](../LICENSE).
