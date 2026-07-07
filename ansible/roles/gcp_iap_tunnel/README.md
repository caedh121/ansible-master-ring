gcp_iap_tunnel
==============

Opens a GCP IAP (Identity-Aware Proxy) TCP tunnel from the Ansible control node
to the WinRM port on a Windows VM in GCP, so Ansible can reach WinRM via
`localhost:<local_port>` without going through AWS SSM.

This is the GCP counterpart to `aws_ssm_tunnel`. The two roles are
mutually exclusive: pick one based on `platform`.

Sequence
--------

1. Ensure `tunnel_state_dir` exists on the control node.
2. Require `gcloud` on PATH and assert `gcp_project`, `gcp_availability_zone`,
   and a `local_port` (or `ansible_port`) are set.
3. Probe for an existing tunnel: a live PID in
   `tunnel_state_dir/iap_tunnel_<target_host>_<remote_port>.pid` that is an
   actual `gcloud start-iap-tunnel` process **and owns** the
   `127.0.0.1:<local_port>` listener. If so, skip start (idempotent).
   Merely finding the port open is **not** sufficient — see "Stale tunnel
   handling" below.
4. Otherwise launch in the background:

   ```
   gcloud compute start-iap-tunnel <host> <remote_port> \
     --project=<gcp_project> \
     --zone=<gcp_availability_zone> \
     --local-host-port=localhost:<local_port> \
     --configuration=<gcp_iap_configuration>
   ```

   Before launching, any **orphaned** `gcloud start-iap-tunnel` process still
   bound to `<local_port>` is killed so the new tunnel can bind it cleanly.
   Readiness then waits up to ~60s for **our** tunnel (matched by target host +
   remote port) to own the local port. Retry the start up to 5x with 10s delay
   if the gcloud process dies early.
5. Persist:
   - `iap_tunnel_<target_host>_<remote_port>.pid` — PID of the local `gcloud` process
   - `iap_tunnel_<target_host>_<remote_port>.port` — local listener port
6. `wait_for` `127.0.0.1:<local_port>` as a final sanity check.

> IAP tunnels persist across guest reboots (the tunnel is managed by the
> control-node `gcloud` process). After a `win_reboot`, the same WinRM
> connection resumes once the guest is back up — no need to re-run this role.

Variables
---------

| Variable | Default | Description |
|---|---|---|
| `target_host` | `inventory_hostname` | GCP VM name to tunnel to. Override when tunneling to a host other than the role's applied-to host (e.g. open a 443 tunnel to an orchestration API from a play running against another VM) |
| `remote_port` | `5986` | Port on the target (5985/5986 for WinRM, 443 for an HTTPS orchestration API) |
| `local_port` | _(unset)_ | Local listener port. Resolution order: caller-supplied `local_port` (typical for orchestration-on-443 callers), then the inventory hostvar `iap_local_port`, then `ansible_port`. |
| `gcp_iap_configuration` | `default` | Value passed to `gcloud --configuration=` |
| `use_iap` | `true` | Gate flag consumed by callers; on for GCP by default |
| `iap_update_connection_facts` | `true` | When false, open the tunnel without repointing `ansible_host`/`ansible_port` — for side tunnels that must not hijack the host's WinRM connection (used by `aws_ssm_tunnel`'s GCP recovery) |
| `tunnel_state_dir` | `{{ ssm_tunnel_state_dir \| default('/tmp/ansible_tunnels') }}` | Directory for `.pid` / `.port` state files |

Inventory / runtime variables consumed:

| Variable | Description |
|---|---|
| `ansible_port` | Local tunnel port (preferred over `local_port` if set) |
| `gcp_project` | GCP project ID (required) |
| `gcp_availability_zone` | GCP zone of the VM (required) |

Idempotency
-----------

If the recorded PID is still a live `gcloud start-iap-tunnel` process that owns
the local port, the start step is skipped and reruns report `ok`.

Stale tunnel handling
---------------------

Local ports are allocated **deterministically per pod** by the inventory
generator, so every run of the same pod targets the same `<local_port>` values.
If a previous run is interrupted before teardown, its `gcloud start-iap-tunnel`
process can be **orphaned** — still bound to the local port but no longer
forwarding (for example, it was started before WinRM was ready, hit IAP error
`4003 failed to connect to backend`, and `gcloud` keeps the dead local listener
open indefinitely).

Because such an orphan keeps the port *open*, a naive "is the port open?" check
reports success while WinRM rides a dead tunnel and times out
(`credssp ... Read timed out` / `UNREACHABLE`). To prevent this, the role:

- only reuses an existing tunnel when the recorded PID **owns** the local port
  and is a real `start-iap-tunnel` process; and
- before starting, **kills any orphaned `gcloud start-iap-tunnel` bound to the
  target local port**, then waits for *our* tunnel (matched by target host +
  remote port) to own the port — not merely for the port to accept TCP.

This makes the role self-healing across interrupted runs without relying on
`teardown` having run.

Requirements
------------

- `gcloud` CLI on the control node, authenticated with a principal that has
  `roles/iap.tunnelResourceAccessor` (or equivalent) on the target VM.
- `ss` (from `iproute2`) and Linux `/proc` on the control node — used to verify
  port ownership and reclaim orphaned tunnels. (Already present in the
  scale-test worker image.)
- IAP firewall rule allowing TCP forwarding to `remote_port` on the target —
  the GCP VM-provisioning playbooks already attach the `allow-rdp-iap` network
  tag, which permits IAP TCP forwarding.

Teardown
--------

```yaml
- ansible.builtin.import_role:
    name: master_ring.windows_remote.gcp_iap_tunnel
    tasks_from: teardown
```

Kills every recorded tunnel for the target host and removes its pid/port state
files — including tunnels opened on non-default ports (e.g. 443), so nothing
leaks when `remote_port` is not re-passed at teardown time. Set
`teardown_remote_port` to scope the teardown to a single port.

Example Playbook
----------------

```yaml
- hosts: pre_domain_win_all
  gather_facts: false
  vars:
    use_iap: true
  tasks:
    - ansible.builtin.import_role:
        name: master_ring.windows_remote.gcp_iap_tunnel
      when:
        - platform | default('') == 'gcp'
        - use_iap | default(false)
```

GCP hosts inherit the default `use_iap: true`. Set `use_ssm: false` (it already
defaults to false) and only override `use_iap: false` if you want to disable the
tunnel for a particular environment.

License
-------

MIT

Author Information
------------------

Adrian Estrada
