# win_reboot

Unified Windows reboot role. Branches by environment:

- **GCP + `use_iap: true`** → `ansible.windows.win_reboot` over the IAP-tunneled
  WinRM connection. The IAP tunnel is owned by the control-node `gcloud`
  process and survives the guest reboot, so no tunnel re-open is needed.
  This branch wins even when `use_ssm` is also true.
- **Azure + `use_azure_bastion: true`** → `ansible.windows.win_reboot` over the
  Bastion-tunneled WinRM connection. This branch wins even when `use_ssm` is
  true for obs-bus S3 credentials.
- **`use_ssm: true`** → `aws_ssm_reboot` (force reboot via
  SSM document, then re-establishes the SSM port-forward after the host
  returns).
- **default** → plain `ansible.windows.win_reboot` over direct WinRM.

All timing defaults are sized for the slowest reboot scenario in the codebase
(DC promotion).

## Variables

| Variable | Default | Description |
|---|---|---|
| `winrm_via` | _(derived)_ | Explicit transport: `direct`, `ssm`, `iap`, or `bastion`. Resolved by the `transport` role; when unset it derives from `platform` + the legacy `use_ssm`/`use_iap`/`use_azure_bastion` flags (see that role's README). `ssm` routes through `aws_ssm_reboot`; everything else is a plain `win_reboot` over the (surviving) connection |
| `reboot_pre_delay` | `3` | Seconds before OS initiates shutdown |
| `reboot_timeout` | `1000` | Seconds to wait for host to come back online |
| `reboot_post_delay` | `0` | Seconds to wait after host responds before continuing |
| `ssm_tunnel_state_dir` | `/tmp/ansible_tunnels` | Path to env-scoped SSM state files (passed through to `aws_ssm_reboot`) |

## Requirements

- `aws_ssm_reboot` role present when the SSM branch is taken
- AWS CLI + `session-manager-plugin` on the control node for the SSM branch
- `gcp_iap_tunnel` or `azure_bastion_tunnel` already opened
  for the host when the corresponding tunnel branch is taken

## Example

```yaml
- name: Reboot after domain join
  ansible.builtin.import_role:
    name: master_ring.windows_remote.win_reboot
  when: task_results.reboot_required
```

## Verification

- **In-network / GCP-IAP / Azure-Bastion**: host disappears from ping during
  reboot, WinRM reconnects after `reboot_timeout`. For tunneled cloud paths, the
  local listener remains bound on the control node throughout.
- **SSM**: `aws ssm describe-sessions` shows session terminated; new session
  started; `aws ssm describe-instance-information` returns `PingStatus: Online`
