# win_readiness

Waits for a Windows VM to be ready for configuration.

## What it does

1. Waits for the WinRM connection (`wait_for_connection`, up to **20 minutes**,
   polling every 10s).
2. Waits for the Explorer process to be running (starts it if needed; up to
   **50 minutes**, polling every 10s) — proof of a fully initialized
   interactive session, not just a responsive WinRM endpoint.

Use after VM provisioning or reboot, before running roles that require a fully
initialized interactive Windows session. Takes no variables.

## Failure modes

- **`wait_for_connection` times out (20 min)** — WinRM never became reachable.
  Diagnose outside-in: is the tunnel up (`ss -ltnp | grep <local_port>` on the
  controller, plus the tunnel role's state files under `ssm_tunnel_state_dir`)?
  Did the tunnel role repoint `ansible_host`/`ansible_port` (it must run
  *before* this role)? Are the WinRM credentials/`ansible_winrm_transport`
  correct (auth failures also surface here as unreachable)?
- **Explorer probe exhausts retries (50 min)** — WinRM works but the machine
  never reaches an interactive-ready state: stuck sysprep/OOBE, pending boot
  scripts, or a session in which Explorer cannot start. Log onto the console
  (RDP/cloud serial console) and check.
- **Immediate module failure** — `ansible.windows.win_powershell` requires
  `ansible.windows >= 1.5.0` (declared in this collection's `galaxy.yml`).

## Manual fallback

From the controller, through the same tunnel endpoint:

```bash
# WinRM listening? (expect an HTTP answer, e.g. 401)
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:<local_port>/wsman

# WinRM auth + Explorer running?
ansible <host> -m ansible.windows.win_ping
ansible <host> -m ansible.windows.win_shell -a "Get-Process explorer"
```
