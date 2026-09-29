<#
.SYNOPSIS
  OAuth login helper for CLIProxyAPI with automatic callback-port selection.
.DESCRIPTION
  On Windows the provider default callback ports (Antigravity 51121, Codex
  1455) can fall inside Hyper-V/WSL excluded TCP ranges, so the login fails
  with "bind: An attempt was made to access a socket in a way forbidden by
  its access permissions". This script tests whether the default port can be
  bound on 127.0.0.1 and falls back to a free port via -oauth-callback-port.
  Afterwards it restarts the background proxy task so it picks up the new
  credentials.
.EXAMPLE
  & $HOME\.claudex\login.ps1 antigravity
  & $HOME\.claudex\login.ps1 codex
  & $HOME\.claudex\login.ps1 codex-device
  & $HOME\.claudex\login.ps1 opencode     # prompt for the API key, verify, save to User env
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)]
  [string]$Provider,
  [string]$Config = (Join-Path $HOME '.claudex\proxy\config.yaml'),
  [string]$Exe = '',
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$KnownPorts = @{ antigravity = 51121; codex = 1455 }

function Test-PortFree {
  param([int]$Port)
  $l = $null
  try {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $l.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($l) { $l.Stop() }
  }
}

function Find-FreePort {
  foreach ($p in @(52121, 51900, 49000, 48080, 45821, 45455)) {
    if (Test-PortFree $p) { return $p }
  }
  $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  try {
    $l.Start()
    return $l.LocalEndpoint.Port
  } finally {
    $l.Stop()
  }
}

$key = $Provider.ToLower().TrimStart('-')
$deviceFlow = $false
if ($key -eq 'opencode' -or $key -eq 'opencode-login') {
  # OpenCode Go uses an API key, not OAuth: prompt (masked), verify it
  # against /models, then persist to the User environment + this session.
  $plain = $null
  while ($true) {
    $sec = Read-Host 'OpenCode Go API key (paste, Enter to save; empty aborts)' -AsSecureString
    if ($sec.Length -eq 0) { Write-Host 'login.ps1: cancelled.'; exit 0 }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
      $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
    if ([string]::IsNullOrWhiteSpace($plain)) { Write-Warning 'login.ps1: empty key, try again.'; continue }
    $base = if ($env:CLAUDEOP_BASE_URL) { $env:CLAUDEOP_BASE_URL.TrimEnd('/') } else { 'https://opencode.ai/zen/go/v1' }
    try {
      $resp = Invoke-RestMethod -Uri "$base/models" -Headers @{ Authorization = "Bearer $plain" } -TimeoutSec 20
      $n = if ($resp.data) { @($resp.data).Count } else { 0 }
      Write-Host "login.ps1: key verified ($n models in catalogue)."
      break
    } catch {
      Write-Warning "login.ps1: verification failed: $($_.Exception.Message)"
      $yn = Read-Host 'Save it anyway? [y/N]'
      if ($yn -eq 'y' -or $yn -eq 'Y') { break }
    }
  }
  [Environment]::SetEnvironmentVariable('CLAUDEOP_API_KEY', $plain, 'User')
  $env:CLAUDEOP_API_KEY = $plain
  $plain = $null
  Write-Host 'login.ps1: saved CLAUDEOP_API_KEY to User environment + this session; verify with: claudeop --models'
  exit 0
}
if ($key -eq 'codex-device' -or $key -eq 'codex-device-login') {
  $flag = '-codex-device-login'
  $deviceFlow = $true
} elseif ($key.EndsWith('-login')) {
  $flag = "-$key"
} else {
  $flag = "-$key-login"
}

if ($Exe -eq '') {
  $cmd = Get-Command cli-proxy-api -ErrorAction SilentlyContinue
  $Exe = if ($cmd) { $cmd.Source } else { Join-Path $HOME '.claudex\bin\cli-proxy-api.exe' }
}
if (-not (Test-Path $Exe)) { Write-Error "login.ps1: binary not found: $Exe"; exit 1 }
if (-not (Test-Path $Config)) { Write-Error "login.ps1: config not found: $Config (run install.ps1 -WithProxy first)"; exit 1 }

$cliArgs = @('-config', $Config, $flag)
if (-not $deviceFlow) {
  $short = $key -replace '-login$', ''
  if ($KnownPorts.ContainsKey($short) -and (Test-PortFree $KnownPorts[$short])) {
    $port = $KnownPorts[$short]
  } else {
    $port = Find-FreePort
  }
  Write-Host "login.ps1: using OAuth callback port $port"
  $cliArgs += @('-oauth-callback-port', "$port")
}
if ($NoBrowser) { $cliArgs += '-no-browser' }

& $Exe @cliArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$task = Get-ScheduledTask -TaskName 'CLIProxyAPI' -ErrorAction SilentlyContinue
if ($task) {
  Stop-ScheduledTask -TaskName 'CLIProxyAPI' -ErrorAction SilentlyContinue
  Start-ScheduledTask -TaskName 'CLIProxyAPI'
  Write-Host 'login.ps1: restarted CLIProxyAPI task; verify with: claudex --models / claudemini --models'
} else {
  Write-Host 'login.ps1: no CLIProxyAPI task found; restart the proxy by hand (see README step 4).'
}
