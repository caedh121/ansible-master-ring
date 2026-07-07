aws_ssm_tunnel
==============

Opens an AWS SSM Session Manager port-forwarding session from the Ansible
control node to an SSM target, so Ansible can reach WinRM (5985/5986) through
SSM without a direct network path. For AWS deployments the targets are native
EC2 instance IDs (`i-*`); hybrid managed-node IDs (`mi-*`) are only used by
non-AWS hybrid SSM flows.

Sequence
--------

1. Verify `aws`, `session-manager-plugin`, `curl`, and `openssl` are installed
   on the control node.
2. Poll `aws ssm describe-instance-information` until the target reports
   `PingStatus=Online` (`retries: 60`, `delay: 10`).
3. Confirm the SSM agent is actually executing commands: issue a no-op
   `send-command` and `aws ssm wait command-executed` for it. Retried
   (`retries: 8`, `delay: 15`) because `send-command` accepting the API
   call is not proof the agent will run it — `wait command-executed` blocks
   until the invocation reaches `Success` (or the wait fails on
   `Failed`/`TimedOut`/`DeliveryTimedOut`/`Undeliverable`). On failure the
   task emits the full per-plugin status JSON from
   `aws ssm list-command-invocations --details`.
3a. **AWS EC2 recovery**: if step 3 fails for a native AWS EC2 target
   (`platform == 'aws'` and `ansible_id` is `i-*`) after SSM accepted the
   readiness command, the role reboots the instance with `ec2 reboot-instances`,
   waits for EC2 status checks and SSM `Online`, then retries the readiness
   command. This recovers the common `PingStatus=Online` but command
   `Undeliverable` agent state.
3b. **GCP-only recovery**: if step 3 fails and `platform == 'gcp'`,
   the role opens a short-lived `gcloud compute start-iap-tunnel` from the
   control node to the target's WinRM port (`remote_port`, default 5986)
   on a random local port, runs `ansible.windows.win_service name=AmazonSSMAgent
   state=restarted` over that WinRM-over-IAP connection (re-using the host's
   normal Ansible WinRM credentials), then tears the IAP tunnel down. Waits
   30s and re-runs the readiness probe with the same retry budget. If the
   probe still fails, the play stops with the failure JSON. If no platform
   recovery path matches, the play stops with a message asking the operator to
   restart the agent manually or reboot the host.
   `gcloud compute ssh` is intentionally not used: these Windows VMs don't
   run sshd and the IAP firewall rule (`allow-rdp-iap`) doesn't expose
   port 22, but it does allow IAP TCP forwarding to the WinRM port.
4. Probe the expected local listener. If it is gone, terminate only stale
   sessions for this tunnel's state key and open a fresh tunnel. Other
   port-forwarding sessions to the same target are left alone.
5. Launch `aws ssm start-session --document-name AWS-StartPortForwardingSession`
   in the background via `nohup`, redirect its output to a logfile in `/tmp`,
   and wait for the local port to start accepting TCP connections
   (`retries: 5`, `delay: 10`).
6. If `start-session` keeps failing specifically with `TargetNotConnected`
   (rc 42 — agent reports `Online` but the session data channel is not yet
   established, common right after a Domain Controller promotion reboot),
   trigger `Restart-Service AmazonSSMAgent` on the target via `send-command`
   and `wait command-executed`, pause 45s, and retry the port-forward
   (`retries: 20`, `delay: 15`).
7. Persist state to `{{ ssm_tunnel_state_dir }}` per tunnel state key:
   - `ssm_tunnel_<state-key>.pid` — PID of the local `session-manager-plugin` process
   - `ssm_tunnel_<state-key>.port` — local listener port
   - `ssm_tunnel_<state-key>.sid` — AWS SSM session ID
8. Re-apply the host connection facts (`ansible_host`, `ansible_port`, and
   WinRM operation/read timeouts) when `aws_ssm_update_connection_facts` is true
   so targeted reruns use the SSM tunnel even when inventory was not
   regenerated.

> If the readiness probe in step 3 keeps failing after platform recovery, the
> instance is `Online` at the MGS layer but the agent is still wedged (commands
> time out / fail). This usually requires manual recovery on the host — restart
> `AmazonSSMAgent`, reboot via the cloud provider's console, or re-register the
> non-AWS hybrid agent with `amazon-ssm-agent -register -clear`.

Variables
---------

| Variable | Default | Description |
|---|---|---|
| `ssm_region_name` | `us-west-2` | AWS region of the SSM-registered instance |
| `remote_port` | `5986` | WinRM port on the target (5985 HTTP / 5986 HTTPS) |
| `local_port` | _(unset)_ | Local listener port on the control node; set per host in inventory |
| `use_ssm` | `false` | Gate flag consumed by callers |
| `aws_ssm_winrm_operation_timeout_sec` | `120` | WinRM operation timeout applied after the SSM tunnel is ready |
| `aws_ssm_winrm_read_timeout_sec` | `300` | WinRM read timeout applied after the SSM tunnel is ready |
| `ssm_tunnel_state_dir` | `/tmp/ansible_tunnels` | Directory for `.pid`/`.sid`/`.port` state files |
| `ssm_tunnel_state_key` | `{{ inventory_hostname }}` | State-file/session reason key. Override when opening a second tunnel to the same target, such as an orchestration API on port 443. |
| `aws_ssm_update_connection_facts` | `true` | When false, the role opens the tunnel but does not repoint `ansible_host`/`ansible_port`; useful for non-WinRM side tunnels. |

Inventory variables consumed:

| Variable | Description |
|---|---|
| `ansible_id` | SSM target ID (`i-XXXXXXXX` for AWS EC2, `mi-XXXXXXXX` for hybrid managed nodes) |
| `ansible_aws_ssm_region` | AWS region |
| `ansible_port` | Local tunnel port (becomes `local_port`) |
| `platform` | `gcp` enables automatic `Restart-Service AmazonSSMAgent` recovery via IAP-tunneled WinRM when the agent is `Undeliverable` |
| `gcp_project` | GCP project ID (required when `platform == 'gcp'`) |
| `gcp_availability_zone` | GCP zone of the VM (required when `platform == 'gcp'`) |

Idempotency
-----------

If the local listener is alive, the port-forward start/save-PID/write-state steps
are skipped. If the local listener is absent, the role treats sessions for the
same `ssm_tunnel_state_key` as stale from the control node's point of view and
starts a fresh port-forward. Sessions for other state keys on the same target are
not terminated.

Requirements
------------

- AWS CLI v2 + `session-manager-plugin` on the control node
- Control-node IAM permissions: `ssm:DescribeInstanceInformation`,
  `ssm:DescribeSessions`, `ssm:StartSession`, `ssm:SendCommand`,
  `ssm:TerminateSession` (used by `aws_ssm_reboot`). AWS EC2 recovery also
  requires `ec2:RebootInstances` and `ec2:DescribeInstanceStatus`.
- Target instance registered and Online in SSM

Example Playbook
----------------

```yaml
- hosts: windows
  gather_facts: false
  vars:
    use_ssm: true
  roles:
    - master_ring.windows_remote.aws_ssm_tunnel
```

Typically imported by `aws_ssm_reboot` to re-establish the tunnel after a
reboot.

License
-------

MIT

Author Information
------------------

Adrian Estrada
