# aws_ssm_reboot

Reboots a Windows SSM target and restores its WinRM tunnel. For AWS, the target
is a native EC2 instance ID (`i-*`); non-AWS hybrid SSM flows use managed-node
IDs (`mi-*`). Intended to be called from `win_reboot` when `use_ssm: true`.

## Sequence

1. Send `shutdown.exe /r /f /t 3` via `AWS-RunPowerShellScript` send-command
2. Kill the local `session-manager-plugin` process (holds the port across reboots — does not exit on its own)
3. Terminate the AWS SSM session (cleans up the stale Active session)
4. Best-effort wait (all target types, EC2 and hybrid) for `PingStatus` to
   leave `Online`. SSM heartbeat status can stay `Online` through a quick
   reboot — and hybrid heartbeats refresh slowly — so a timeout here is not
   fatal and transient API errors are tolerated (`failed_when: false`); the
   readiness probe in step 6 is the authoritative gate.
5. Poll until `PingStatus` returns `Online` (confirms SSM agent is back)
6. Run a `send-command` + `aws ssm wait command-executed` readiness probe
   until success (debounce — `send-command` returning rc=0 only proves the
   API accepted the call; `wait command-executed` is what proves the agent
   actually ran it; guards against `TargetNotConnected` immediately after
   the agent first reports `Online`)
7. Import `aws_ssm_tunnel` to open a new port-forward session and write fresh `.pid`/`.sid` state files

## Variables

| Variable | Default | Description |
|---|---|---|
| `ssm_tunnel_state_dir` | `/tmp/ansible_tunnels` | Directory holding `.pid`, `.sid`, and `.port` state files written by `aws_ssm_tunnel` |
| `ssm_tunnel_state_key` | `{{ inventory_hostname }}` | State-file key — must match the value used when `aws_ssm_tunnel` opened the tunnel (the role resolves the same default/override chain) |

Inventory variables consumed (must be set per host):

| Variable | Description |
|---|---|
| `ansible_id` | SSM target ID (`i-XXXXXXXX` for AWS EC2, `mi-XXXXXXXX` for hybrid managed nodes) |
| `ansible_aws_ssm_region` | AWS region where the instance is registered |
| `ansible_port` | Local tunnel port (written to `.port` file by `aws_ssm_tunnel`) |

## Requirements

- `aws_ssm_tunnel` role present
- AWS CLI + `session-manager-plugin` on the control node
- State files (`ssm_tunnel_<state-key>.pid`, `ssm_tunnel_<state-key>.sid`, keyed by `ssm_tunnel_state_key`, default `inventory_hostname`) written by a prior `aws_ssm_tunnel` run; steps 2–3 are graceful no-ops if files are absent

## IAM

The control node's IAM identity requires:
- `ssm:SendCommand` on the target instance
- `ssm:TerminateSession` on the session
- `ssm:DescribeInstanceInformation` on the instance
- `ssm:StartSession` + `ssm:DescribeSessions` (consumed by `aws_ssm_tunnel`)

## Example

```yaml
- name: Reboot via SSM
  ansible.builtin.import_role:
    name: master_ring.windows_remote.aws_ssm_reboot
  when: use_ssm | default(false)
```

Typically called through `win_reboot` rather than directly.

## Verification

After the role completes, `aws_ssm_tunnel` has opened a fresh session and the local port is accepting TCP connections. `ansible_port` (the WinRM port) is forwarded through the new session.
