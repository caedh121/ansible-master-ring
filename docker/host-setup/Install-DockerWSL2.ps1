#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install WSL2 + Docker CE on a Windows VM in one pass. Two phases
    separated by one reboot; the script re-launches itself via RunOnce
    after the reboot. Works on Windows 10/11 workstations and Windows
    Server 2022 (build 20348+) — the server SKU is auto-detected and
    the Hyper-V role is enabled in addition to VirtualMachinePlatform.

.DESCRIPTION
    Phase 1: enables the WSL and Virtual Machine Platform Windows
    features (plus the Hyper-V role on server SKUs), runs
    `wsl --install`, registers a RunOnce entry to resume, and reboots.

    Phase 2 (after reboot, on next admin login): initializes the Ubuntu
    distro headlessly with a service user, enables systemd, installs
    Docker CE inside it, adds the user to the docker group, and starts
    the daemon.

    On VMware VMs, nested virtualization must be enabled on the VM
    before running:
      * Workstation / Fusion Pro: 'Virtualize Intel VT-x/EPT or AMD-V/RVI'
      * vSphere / ESXi:           'Expose hardware assisted virtualization
                                  to the guest OS'
      * Hyper-V (host):           Set-VMProcessor -ExposeVirtualizationExtensions $true
    Otherwise WSL2 fails with a hypervisor error at first distro launch.
    `-Preflight` catches this before Phase 1 changes anything.

.PARAMETER Distro
    WSL distro to install. Default: Ubuntu-22.04.

.PARAMETER User
    Linux username to create inside the distro. Default: dockeruser.

.PARAMETER Preflight
    Only run environment checks (elevation, OS build, virtualization,
    server SKU detection) and exit. Nothing is changed.

.PARAMETER Phase
    Internal: 1 for first run (enables + reboots), 2 for post-reboot
    resume. Do not set manually — RunOnce sets it.

.EXAMPLE
    # Verify the VM is ready without changing anything:
    .\Install-DockerWSL2.ps1 -Preflight

.EXAMPLE
    # Do the install (script reboots once, then auto-resumes at login):
    .\Install-DockerWSL2.ps1
#>
[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-22.04',
    [string]$User   = 'dockeruser',
    [switch]$Preflight,
    [ValidateSet(1,2)][int]$Phase = 1
)

$ErrorActionPreference = 'Stop'

# --- Prechecks ---------------------------------------------------------

function Test-Prereqs {
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    Write-Host "OS:            $($os.Caption) build $build"

    # ProductType: 1=Workstation, 2=DomainController, 3=Server
    $script:IsServerSku = ($os.ProductType -ne 1)
    $sku = if ($script:IsServerSku) { 'Server' } else { 'Workstation' }
    Write-Host "SKU:           $sku"

    $minBuild = if ($script:IsServerSku) { 20348 } else { 19041 }
    if ($build -lt $minBuild) {
        throw "WSL2 needs $sku build $minBuild+; found $build."
    }

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $slat = $cpu.SecondLevelAddressTranslationExtensions
    $vt   = $cpu.VirtualizationFirmwareEnabled
    Write-Host "CPU:           $($cpu.Name)"
    Write-Host "SLAT:          $slat"
    Write-Host "VirtFirmware:  $vt"

    $model = (Get-CimInstance Win32_ComputerSystem).Model
    Write-Host "Machine model: $model"

    if (-not $vt -or -not $slat) {
        Write-Warning "Virtualization is NOT exposed to this guest. WSL2 will not start after Phase 1. Enable nested virtualization on the VM's CPU settings (see script description), power-cycle the VM, then re-run."
    } elseif ($model -match 'VMware|Virtual Machine|VirtualBox|KVM|QEMU') {
        Write-Host "Detected VM ($model). Nested virtualization looks OK (SLAT=$slat, VirtFirmware=$vt)."
    }
}

# --- Phase 1: enable features + wsl --install + reboot ----------------

function Invoke-Phase1 {
    if ($script:IsServerSku) {
        Write-Host "`n[Phase 1] server SKU: enabling Hyper-V role (needed alongside VMP on server)"
        # ServerManager is only present on server SKUs; safe here because IsServerSku is true.
        Import-Module ServerManager -ErrorAction SilentlyContinue
        Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart:$false | Out-Null
    }

    Write-Host "[Phase 1] enabling WSL + VirtualMachinePlatform features"
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null

    Write-Host "[Phase 1] running 'wsl --install -d $Distro --no-launch'"
    # --no-launch: skip the first-boot user prompt so Phase 2 can do it non-interactively
    & wsl.exe --install -d $Distro --no-launch

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Definition }
    if (-not (Test-Path $scriptPath)) {
        throw "Could not resolve script path for RunOnce ($scriptPath)."
    }

    $runOnceCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Phase 2 -Distro "{1}" -User "{2}"' -f $scriptPath, $Distro, $User
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' `
        -Name 'InstallDockerWSL2' -Value $runOnceCmd
    Write-Host "[Phase 1] RunOnce registered. Script will resume at next admin login after reboot."

    Write-Host "[Phase 1] restarting in 10s (Ctrl-C to abort)..."
    Start-Sleep 10
    Restart-Computer -Force
}

# --- Phase 2: init distro + install Docker CE -------------------------

function Invoke-Phase2 {
    Write-Host "`n[Phase 2] verifying WSL2 default + $Distro is registered"
    & wsl.exe --set-default-version 2 2>$null | Out-Null
    $distros = (& wsl.exe --list --quiet) -replace "`0", "" | Where-Object { $_ -match '\S' }
    if ($distros -notcontains $Distro) {
        throw "$Distro is not registered. Re-run: wsl --install -d $Distro --no-launch, then reboot."
    }

    Write-Host "[Phase 2] creating user '$User' inside $Distro"
    $userBootstrap = @"
set -euo pipefail
if ! id -u '$User' >/dev/null 2>&1; then
    adduser --disabled-password --gecos '' '$User'
    usermod -aG sudo '$User'
    echo '$User ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-$User
    chmod 440 /etc/sudoers.d/90-$User
fi
# Set the default WSL user AND enable systemd (WSL >= 0.67.6 supports it)
cat > /etc/wsl.conf <<CONF
[user]
default=$User

[boot]
systemd=true
CONF
"@
    & wsl.exe -d $Distro --user root -- bash -lc $userBootstrap

    Write-Host "[Phase 2] restarting $Distro to activate systemd + default user"
    & wsl.exe --terminate $Distro
    Start-Sleep 3

    Write-Host "[Phase 2] installing Docker CE inside $Distro"
    $dockerInstall = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
arch=$(dpkg --print-architecture)
echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker __DOCKER_USER__
systemctl enable --now docker
systemctl is-active --quiet docker && echo "docker is running" || { echo "docker failed to start"; exit 1; }
'@
    $dockerInstall = $dockerInstall.Replace('__DOCKER_USER__', $User)
    & wsl.exe -d $Distro --user root -- bash -lc $dockerInstall

    Write-Host "`n[Done] Smoke test the install with:"
    Write-Host "    wsl -d $Distro -- docker version"
    Write-Host "    wsl -d $Distro -- docker run --rm hello-world"
    Write-Host ""
    Write-Host "Default user inside $Distro is '$User' (passwordless sudo)."
    Write-Host "The distro is also set to auto-start systemd, so 'docker' just works."
}

# --- Main --------------------------------------------------------------

Write-Host ("=" * 60)
Write-Host "Install-DockerWSL2.ps1  (phase $Phase, distro $Distro, user $User)"
Write-Host ("=" * 60)

Test-Prereqs

if ($Preflight) {
    Write-Host "`nPreflight only. Nothing changed. Exit."
    return
}

if ($Phase -eq 1) {
    Invoke-Phase1
} else {
    Invoke-Phase2
}
