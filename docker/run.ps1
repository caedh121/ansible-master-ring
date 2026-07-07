<#
.SYNOPSIS
    Launch the testbox on Windows (Docker Desktop, Linux containers / WSL2).
.DESCRIPTION
    Builds the toolchain image on first use, mounts this repo checkout, a
    persistent work directory, and any cloud credential directories found
    in the user profile, then drops into an interactive shell.
.PARAMETER Rebuild
    Force a rebuild of the image even if it already exists.
.EXAMPLE
    .\docker\run.cmd    # preferred - .cmd wrapper bypasses PS ExecutionPolicy
    .\docker\run.ps1    # if your ExecutionPolicy already allows this script
.NOTES
    Manual fallback - the equivalent commands:
      docker build -t master-ring-testbox docker/
      docker run -it --rm -v "${PWD}:/work/repo" -v "$env:USERPROFILE\testbox-work:/work" `
        -v "$env:USERPROFILE\.aws:/root/.aws" master-ring-testbox
#>
[CmdletBinding()]
param(
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptDir
$image = 'master-ring-testbox'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw @'
docker not found on PATH. Install Docker Desktop, or run
docker\host-setup\Install-DockerWSL2.cmd for a fresh WSL2 + Docker CE stack.
'@
}

# Silent daemon check. `docker info *> $null` in PowerShell 5.1 wraps the
# native binary's stderr in an ErrorRecord (NativeCommandError), which
# splatters the console even on a benign "daemon not up" case. Piping
# through cmd.exe lets cmd handle the 2>&1 at its level so PowerShell just
# sees a clean exit code.
function Test-DockerDaemon {
    $null = cmd.exe /c "docker info >NUL 2>&1"
    return $LASTEXITCODE -eq 0
}

if (-not (Test-DockerDaemon)) {
    # Docker Desktop installed but not running? Auto-start it.
    $dockerDesktopExe = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $dockerDesktopExe) {
        throw @'
Docker daemon is not reachable and Docker Desktop was not found in the
usual install paths. Either start your Docker service manually, install
Docker Desktop (https://docs.docker.com/desktop/install/windows-install/),
or run docker\host-setup\Install-DockerWSL2.cmd on a fresh Windows VM to
provision WSL2 + Docker CE.
'@
    }

    Write-Host "Docker Desktop is installed but not running. Launching it (first boot takes 30-60s)..."
    Start-Process -FilePath $dockerDesktopExe -WindowStyle Minimized

    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Test-DockerDaemon) { break }
    }
    if (-not (Test-DockerDaemon)) {
        throw 'Docker Desktop was launched but the daemon did not come up within 2 minutes. Check Docker Desktop status and re-run.'
    }
    Write-Host 'Docker daemon is up.'
}

# Same NativeCommandError avoidance for the image-exists probe.
$null = cmd.exe /c "docker image inspect $image >NUL 2>&1"
$imageMissing = ($LASTEXITCODE -ne 0)
if ($Rebuild -or $imageMissing) {
    docker build -t $image $scriptDir
    if ($LASTEXITCODE -ne 0) { throw 'image build failed' }
}

$workDir = if ($env:TESTBOX_WORK_DIR) { $env:TESTBOX_WORK_DIR } else { Join-Path $env:USERPROFILE 'testbox-work' }
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$dockerArgs = @(
    'run', '-it', '--rm'
    '-v', "${workDir}:/work"
    '-v', "${repoRoot}:/work/repo"
)
$credMounts = @{
    (Join-Path $env:USERPROFILE '.aws')           = '/root/.aws'
    (Join-Path $env:USERPROFILE '.azure')         = '/root/.azure'
    (Join-Path $env:USERPROFILE '.config\gcloud') = '/root/.config/gcloud'
}
foreach ($hostPath in $credMounts.Keys) {
    if (Test-Path $hostPath) {
        $dockerArgs += @('-v', "${hostPath}:$($credMounts[$hostPath])")
    }
}
foreach ($envName in 'GH_TOKEN', 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY',
    'ANSIBLE_USER', 'ANSIBLE_PASSWORD', 'ANSIBLE_VAULT_PASSWORD_FILE') {
    $dockerArgs += @('-e', $envName)
}
$dockerArgs += $image

& docker @dockerArgs
exit $LASTEXITCODE
