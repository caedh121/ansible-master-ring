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
    throw 'docker not found on PATH. Install Docker Desktop and enable Linux containers (WSL2).'
}
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'docker daemon not reachable. Start Docker Desktop first.'
}

docker image inspect $image *> $null
if ($Rebuild -or $LASTEXITCODE -ne 0) {
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
