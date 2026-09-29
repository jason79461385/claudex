<#
.SYNOPSIS
  One-step setup for the claudex route wrappers (Windows PowerShell 5.1 / 7+).
.DESCRIPTION
  Copies the route folders into $HOME\.claudex and adds a clearly-marked
  dot-source block to your $PROFILE. Re-running replaces that block instead
  of appending, so it is safe to run twice. A timestamped backup
  ($PROFILE.bak.yyyyMMdd-HHmmss) is made before every modification.
.EXAMPLE
  .\install.ps1
  .\install.ps1 -Routes claudex,clauden
  .\install.ps1 -Dir 'D:\tools\claudex'
  .\install.ps1 -From 'https://github.com/jason79461385/claudex.git'
  .\install.ps1 -WithProxy   # also install CLIProxyAPI (binary +
                             # localhost-only config + autostart at logon)
  .\install.ps1 -NoProfile   # copy files only, do not touch $PROFILE
  .\install.ps1 -Uninstall
  .\install.ps1 -Uninstall -RemoveFiles
#>
[CmdletBinding()]
param(
  [string[]]$Routes = @('claudex', 'claudemini', 'claudeop', 'clauden'),
  [string]$Dir = (Join-Path $HOME '.claudex'),
  [string]$From = '',
  [switch]$NoProfile,
  [switch]$WithProxy,
  [string]$ProxyVersion = '',
  [string]$ProxyZipUrl = '',
  [switch]$Uninstall,
  [switch]$RemoveFiles
)

$ErrorActionPreference = 'Stop'

$RepoUrl   = 'https://github.com/jason79461385/claudex.git'
$AllRoutes = @('claudex', 'claudemini', 'claudeop', 'clauden')
$MarkBegin = '# >>> claudex-routes (managed by claudex install.ps1; do not edit manually) >>>'
$MarkEnd   = '# <<< claudex-routes <<<'

foreach ($r in $Routes) {
  if ($AllRoutes -notcontains $r) {
    Write-Error "install.ps1: unknown route: $r (choose from: $($AllRoutes -join ', '))"
    exit 2
  }
}
if ($Routes.Count -eq 0) { Write-Error 'install.ps1: -Routes needs at least one route.'; exit 2 }

function Get-RepoSource {
  if ($From -ne '') {
    if ($From -match '^(https?://|git@)') { return @{ Mode = 'clone'; Url = $From } }
    return @{ Mode = 'path'; Url = $From }
  }
  $here = $PSScriptRoot
  if ($here -and (Test-Path (Join-Path $here 'claudex\claudex.ps1'))) {
    return @{ Mode = 'path'; Url = $here }
  }
  return @{ Mode = 'clone'; Url = $RepoUrl }
}

function Read-TextFile($Path) {
  if (Test-Path $Path) { return [System.IO.File]::ReadAllText($Path) }
  return ''
}

function Write-TextFile($Path, $Text) {
  $dir = Split-Path $Path -Parent
  if ($dir -ne '' -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text)
}

function Backup-File($Path) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  if (Test-Path $Path) {
    $bak = "$Path.bak.$stamp"
    Copy-Item $Path $bak -Force
    return $bak
  }
  Write-TextFile $Path ''
  return "$Path (created new)"
}

function Set-ProfileBlock($ProfilePath, $Block) {
  $text = Read-TextFile $ProfilePath
  $i = $text.IndexOf($MarkBegin)
  $j = $text.IndexOf($MarkEnd)
  if ($i -ge 0 -and $j -gt $i) {
    $after = $text.Substring($j + $MarkEnd.Length)
    if ($after.StartsWith("`r`n"))      { $after = $after.Substring(2) }
    elseif ($after.StartsWith("`n"))    { $after = $after.Substring(1) }
    $text = $text.Substring(0, $i) + $Block + $after
  } else {
    if ($text -ne '' -and -not $text.EndsWith("`n")) { $text += "`r`n" }
    if ($text -ne '') { $text += "`r`n" }
    $text += $Block
  }
  Write-TextFile $ProfilePath $text
}

function Remove-ProfileBlock($ProfilePath) {
  $text = Read-TextFile $ProfilePath
  $i = $text.IndexOf($MarkBegin)
  $j = $text.IndexOf($MarkEnd)
  if ($i -lt 0 -or $j -le $i) { return $false }
  $before = $text.Substring(0, $i)
  $after = $text.Substring($j + $MarkEnd.Length)
  if ($after.StartsWith("`r`n"))      { $after = $after.Substring(2) }
  elseif ($after.StartsWith("`n"))    { $after = $after.Substring(1) }
  $before = if ($before.Trim() -eq '') { '' } else { $before.TrimEnd("`r", "`n") + "`r`n" }
  $after = $after.TrimStart("`r", "`n")
  Write-TextFile $ProfilePath ($before + $after)
  return $true
}

# ---------------------------------------------------------------------------
# CLIProxyAPI (opt-in via -WithProxy): binary + localhost-only config +
# autostart at logon, so `claudex` / `claudemini` work out of the box.
# Never overwrites an existing config; never touches a proxy that already
# answers on 127.0.0.1:8317. Test hooks: -ProxyVersion pins the release tag,
# -ProxyZipUrl overrides the download (a local path is copied as-is).
# ---------------------------------------------------------------------------

$ProxyPort = 8317
if ($null -ne $env:CLIPROXY_PORT -and $env:CLIPROXY_PORT -ne '') { $ProxyPort = [int]$env:CLIPROXY_PORT }
$ProxyKey = 'sk-dummy'
$ProxyOk = $false
$ProxyRestartHint = ''

function Test-ProxyAlive {
  param([int]$Port = $ProxyPort)
  try {
    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/v1/models" `
      -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    return ($resp.StatusCode -eq 200)
  } catch {
    $r = $_.Exception.Response
    if ($null -ne $r -and [int]$r.StatusCode -eq 401) { return $true }
    return $false
  }
}

function Get-ProxyVersion {
  if ($ProxyVersion -ne '') { return $ProxyVersion }
  if ($null -ne $env:CLIPROXY_VERSION -and $env:CLIPROXY_VERSION -ne '') { return $env:CLIPROXY_VERSION }
  try {
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest' `
      -TimeoutSec 20 -ErrorAction Stop
    return $rel.tag_name
  } catch { return '' }
}

function Install-ProxyBinary {
  # Returns the exe path, or $null on failure.
  param([string]$BinDir)
  $exe = Join-Path $BinDir 'cli-proxy-api.exe'
  if (Test-Path $exe) {
    Write-Host 'install.ps1: CLIProxyAPI exe already present.'
    return $exe
  }
  $tag = Get-ProxyVersion
  if ([string]::IsNullOrEmpty($tag)) {
    Write-Error 'install.ps1: could not determine the latest CLIProxyAPI release. Check your network, or pin one: .\install.ps1 -WithProxy -ProxyVersion v8.0.4'
    return $null
  }
  $ver = $tag.TrimStart('v')
  $asset = "CLIProxyAPI_${ver}_windows_amd64.zip"
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cliproxy-dl-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp 'pkg.zip'
    if ($ProxyZipUrl -ne '' -and (Test-Path $ProxyZipUrl)) {
      Copy-Item $ProxyZipUrl $zip -Force
    } elseif ($ProxyZipUrl -ne '') {
      Write-Host "install.ps1: downloading $ProxyZipUrl ..."
      Invoke-WebRequest -Uri $ProxyZipUrl -OutFile $zip
    } else {
      $url = "https://github.com/router-for-me/CLIProxyAPI/releases/download/$tag/$asset"
      Write-Host "install.ps1: downloading $asset ..."
      Invoke-WebRequest -Uri $url -OutFile $zip
    }
    $out = Join-Path $tmp 'pkg'
    Expand-Archive -Path $zip -DestinationPath $out -Force
    $found = Get-ChildItem -Path $out -Recurse -Filter 'cli-proxy-api.exe' | Select-Object -First 1
    if (-not $found) {
      Write-Error 'install.ps1: the archive has no cli-proxy-api.exe in it. Contents:'
      Get-ChildItem -Path $out -Recurse | ForEach-Object { Write-Error ("  " + $_.FullName) }
      return $null
    }
    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
    Copy-Item $found.FullName $exe -Force
    Write-Host "install.ps1: installed $exe"
    return $exe
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

function Ensure-ProxyConfig {
  # Creates the minimal config only if none exists; otherwise warns. Returns $true when usable.
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    @(
      '# Created by claudex install.ps1 -WithProxy. Safe to edit by hand;',
      '# the installer only creates this file, it never overwrites it.',
      'host: "127.0.0.1"',
      "port: $ProxyPort",
      'api-keys:',
      "  - `"$ProxyKey`""
    ) | Set-Content -Path $Path -Encoding utf8
    Write-Host "install.ps1: wrote minimal localhost-only config to $Path"
    return $true
  }
  $text = [System.IO.File]::ReadAllText($Path)
  $problems = @()
  if ($text -notmatch '(?m)^\s*host:\s*"127\.0\.0\.1"') { $problems += 'host is not 127.0.0.1 (must not bind all interfaces)' }
  if ($text -notmatch "(?m)^\s*port:\s*$ProxyPort(\s|$)") { $problems += "port is not $ProxyPort" }
  if ($text -notmatch '(?m)^\s*api-keys:' -or $text -notmatch '(?m)^\s*-\s*\S+') { $problems += 'api-keys section is missing or empty' }
  if ($problems.Count -gt 0) {
    Write-Warning "install.ps1: $Path does not match the wrapper defaults:"
    foreach ($p in $problems) { Write-Warning "  - $p" }
    Write-Warning '  Fix it by hand (see README step 2), then restart the service.'
    return $false
  }
  Write-Host "install.ps1: existing config $Path looks good"
  return $true
}

function Write-ProxyLauncher {
  # Writes a small launcher that starts the console exe with no visible
  # window and waits, so the scheduled task stays Running and restarts
  # the proxy on failure. Returns the launcher path.
  param([string]$Exe, [string]$Config, [string]$ProxyDir)
  $launcher = Join-Path $ProxyDir 'run-hidden.ps1'
  @(
    '# Managed by claudex install.ps1 - do not edit by hand.',
    '# Launches CLIProxyAPI with no visible window and waits, so the',
    '# scheduled task stays Running and restarts it on failure.',
    "`$p = Start-Process -FilePath '$Exe' -ArgumentList '-config','$Config' -WindowStyle Hidden -PassThru",
    '$p.WaitForExit()',
    'exit $p.ExitCode'
  ) | Set-Content -Path $launcher -Encoding utf8
  return $launcher
}

function Enable-ProxyAutostart {
  # Registers a logon scheduled task (Windows only). Returns $true when the task exists afterwards.
  param([string]$Exe, [string]$Config)
  if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    Write-Warning 'install.ps1: no task scheduler here, so autostart was NOT configured.'
    Write-Warning "  On Windows this step registers a CLIProxyAPI logon task automatically; otherwise start it by hand: & `"$Exe`" -config `"$Config`""
    return $false
  }
  $existing = Get-ScheduledTask -TaskName 'CLIProxyAPI' -ErrorAction SilentlyContinue
  # Background launch: hidden powershell runs a launcher script that starts
  # the console exe via Start-Process -WindowStyle Hidden, so no console
  # window ever appears (a bare exe action would occupy a visible window).
  $proxyDir = Split-Path $Config -Parent
  $launcher = Write-ProxyLauncher -Exe $Exe -Config $Config -ProxyDir $proxyDir
  $pwsh = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  if (Get-Command powershell -ErrorAction SilentlyContinue) {
    $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source
  }
  $action = New-ScheduledTaskAction -Execute $pwsh -Argument "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$launcher`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
  if ($existing) {
    # Migrate tasks registered by older installers (foreground exe or
    # inline hidden-command actions).
    $curArgs = @($existing.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" })
    if ($curArgs -notlike '*run-hidden.ps1*') {
      Stop-ScheduledTask -TaskName 'CLIProxyAPI' -ErrorAction SilentlyContinue
      Set-ScheduledTask -TaskName 'CLIProxyAPI' -Action $action -Trigger $trigger -Settings $settings | Out-Null
      Start-ScheduledTask -TaskName 'CLIProxyAPI' -ErrorAction SilentlyContinue
      Write-Host 'install.ps1: migrated CLIProxyAPI task to hidden background launch'
    } else {
      Write-Host 'install.ps1: scheduled task CLIProxyAPI already exists — leaving it alone'
    }
    if ((Get-ScheduledTask -TaskName 'CLIProxyAPI').State -ne 'Running') {
      Start-ScheduledTask -TaskName 'CLIProxyAPI' -ErrorAction SilentlyContinue
      Write-Host 'install.ps1: started existing CLIProxyAPI task'
    }
    return $true
  }
  Register-ScheduledTask -TaskName 'CLIProxyAPI' -Action $action -Trigger $trigger `
    -Settings $settings -Description 'CLIProxyAPI local AI proxy (managed by claudex installer)' -Force | Out-Null
  Start-ScheduledTask -TaskName 'CLIProxyAPI'
  Write-Host 'install.ps1: scheduled task CLIProxyAPI registered (starts at logon, restarts on failure)'
  $script:ProxyRestartHint = 'Restart-ScheduledTask -TaskName CLIProxyAPI  # or: Stop-ScheduledTask ...; Start-ScheduledTask ...'
  return $true
}

function Add-BinToUserPath {
  # Adds $Dir\bin to the User PATH once (no admin needed); also updates this session.
  param([string]$BinDir)
  try {
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if (-not [string]::IsNullOrEmpty($cur)) { $parts = $cur -split ';' }
    $found = $false
    foreach ($p in $parts) {
      if ($p.TrimEnd('\', '/').Equals($BinDir.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) { $found = $true; break }
    }
    if (-not $found) {
      $new = if ([string]::IsNullOrEmpty($cur)) { $BinDir } else { $cur.TrimEnd(';') + ';' + $BinDir }
      [Environment]::SetEnvironmentVariable('Path', $new, 'User')
      Write-Host "install.ps1: added $BinDir to User PATH"
    } else {
      Write-Host 'install.ps1: bin dir already on User PATH'
    }
    if (($env:Path -split ';') -notcontains $BinDir) { $env:Path = $env:Path.TrimEnd(';') + ';' + $BinDir }
  } catch {
    Write-Warning "install.ps1: could not update User PATH ($($_.Exception.Message)); use the full path: & `"$BinDir\cli-proxy-api.exe`""
  }
}

function Setup-Proxy {
  Write-Host 'install.ps1: setting up CLIProxyAPI (binary + localhost-only config + autostart) ...'
  if (Test-ProxyAlive) {
    Write-Host "install.ps1: CLIProxyAPI already answering on 127.0.0.1:$ProxyPort — leaving it alone"
    $script:ProxyOk = $true
    return
  }
  $binDir = Join-Path $Dir 'bin'
  $exe = Install-ProxyBinary -BinDir $binDir
  if (-not $exe) { return }
  Add-BinToUserPath -BinDir $binDir
  $conf = Join-Path $Dir 'proxy\config.yaml'
  if (-not (Ensure-ProxyConfig -Path $conf)) { return }
  if (-not (Enable-ProxyAutostart -Exe $exe -Config $conf)) { return }
  # First launch can be slow — poll for up to ~30s.
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    if (Test-ProxyAlive) {
      Write-Host "install.ps1: CLIProxyAPI is answering on 127.0.0.1:$ProxyPort"
      $script:ProxyOk = $true
      return
    }
    Start-Sleep -Seconds 2
  }
  Write-Warning "install.ps1: the task started but 127.0.0.1:$ProxyPort is still not answering."
  Write-Warning '  Check the task history, then re-run with -WithProxy. Continuing anyway.'
}

$tempClone = $null
try {
  $src = Get-RepoSource
  if ($src.Mode -eq 'clone') {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
      Write-Error 'install.ps1: git is required for cloning. Install it, or run install.ps1 from inside the repo.'
      exit 1
    }
    $tempClone = Join-Path ([System.IO.Path]::GetTempPath()) ('claudex-install-' + [guid]::NewGuid().ToString('N'))
    Write-Host "install.ps1: cloning $($src.Url) ..."
    & git clone --depth 1 $src.Url (Join-Path $tempClone 'claudex')
    if ($LASTEXITCODE -ne 0) { Write-Error 'install.ps1: git clone failed.'; exit 1 }
    $srcDir = Join-Path $tempClone 'claudex'
  } else {
    $srcDir = $src.Url
  }

  foreach ($r in $Routes) {
    if (-not (Test-Path (Join-Path $srcDir "$r\$r.ps1"))) {
      Write-Error "install.ps1: '$srcDir' does not look like the claudex repo (missing $r\$r.ps1)"
      exit 1
    }
  }

  # When installing into the repo checkout itself (the default: clone to
  # $HOME\.claudex, run its install.ps1), source and destination are the
  # same folders — never delete-then-copy, and never remove them on uninstall.
  $sameRoot = ([System.IO.Path]::GetFullPath($srcDir).TrimEnd('\', '/') -eq `
               [System.IO.Path]::GetFullPath($Dir).TrimEnd('\', '/'))

  if ($Uninstall) {
    if (-not $NoProfile) {
      if (Remove-ProfileBlock $PROFILE) {
        Write-Host "install.ps1: removed the managed block from $PROFILE"
      } else {
        Write-Host "install.ps1: no managed block found in $PROFILE; nothing to remove"
      }
    }
    if ($RemoveFiles) {
      foreach ($r in $AllRoutes) {
        $p = Join-Path $Dir $r
        if ($sameRoot) {
          Write-Host "install.ps1: keeping $p (it is the repo checkout itself)"
          continue
        }
        if (Test-Path $p) { Remove-Item -Recurse -Force $p; Write-Host "install.ps1: removed $p" }
      }
      if ((Test-Path $Dir) -and @(Get-ChildItem $Dir -Force).Count -eq 0) {
        Remove-Item -Force $Dir; Write-Host "install.ps1: removed empty $Dir"
      }
    } else {
      Write-Host 'install.ps1: route files left in place (add -RemoveFiles to delete them)'
    }
    Write-Host 'install.ps1: CLIProxyAPI itself (if installed) was left alone — see README for proxy removal.'
    Write-Host 'install.ps1: done — restart PowerShell to finish.'
    exit 0
  }

  if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Warning 'install.ps1: python was not found on PATH. The claudeop/clauden bridges need Python 3 — install it and re-run.'
  }

  Write-Host "install.ps1: installing routes [$($Routes -join ', ')] into $Dir ..."
  if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
  foreach ($r in $Routes) {
    $src = Join-Path $srcDir $r
    $dest = Join-Path $Dir $r
    if ($sameRoot) {
      Write-Host "  $r\ already in place"
      continue
    }
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Copy-Item $src $dest -Recurse -Force
    Write-Host "  copied $r\"
  }

  if (-not $NoProfile) {
    # Portable display path so the block survives home moves.
    $dirDisp = if ($Dir.StartsWith($HOME)) { '$HOME' + $Dir.Substring($HOME.Length) } else { $Dir }
    $lines = @($MarkBegin)
    foreach ($r in $Routes) { $lines += ". `"$dirDisp\$r\$r.ps1`"" }
    $lines += $MarkEnd
    $block = ($lines -join "`r`n") + "`r`n"
    $bak = Backup-File $PROFILE
    Set-ProfileBlock $PROFILE $block
    Write-Host "install.ps1: updated $PROFILE (backup: $bak)"

    # Load the wrappers into this session too, so they work immediately.
    foreach ($r in $Routes) {
      . (Join-Path $Dir "$r\$r.ps1")
      if (Get-Command $r -CommandType Function -ErrorAction SilentlyContinue) {
        Write-Host "  loaded $r"
      } else {
        Write-Warning "install.ps1: '$r' did not load; check $Dir\$r\$r.ps1"
      }
    }
  }

  $policy = (Get-ExecutionPolicy -Scope CurrentUser).ToString()
  if ($policy -eq 'Restricted' -or $policy -eq 'Undefined') {
    Write-Warning "install.ps1: ExecutionPolicy for CurrentUser is '$policy'; the wrappers will not load until you run (once, as admin or for CurrentUser): Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser"
  }

  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warning 'install.ps1: claude was not found on PATH. Install Claude Code for Windows first.'
  }

  if ($WithProxy) {
    try {
      Setup-Proxy
    } catch {
      Write-Warning 'install.ps1: proxy setup did not complete (see error above).'
    }
  }

  if ($WithProxy -and $ProxyOk) {
    $loginBin = if (Get-Command cliproxyapi -ErrorAction SilentlyContinue) { 'cliproxyapi' } else { 'cli-proxy-api' }
    $restartLine = if ($ProxyRestartHint -ne '') { "       $ProxyRestartHint" } else { '       # see README step 4 for the restart command' }
    Write-Host @"
install.ps1: done (wrappers + CLIProxyAPI).
  Next steps:
  1. Restart PowerShell (or dot-source your `$PROFILE)
  2. Log in once per route you use (OAuth opens a browser):
       $loginBin -codex-login          # GPT route (claudex)
       $loginBin -antigravity-login    # Gemini route (claudemini)
       # OpenCode Go key  ->  `$env:CLAUDEOP_API_KEY = '...'   (claudeop)
       # VLLM server      ->  start it, set `$env:CLAUDEN_BASE_URL  (clauden)
  3. Restart the proxy so it picks up the new credentials:
$restartLine
  4. Verify:  claudex --models;  claudemini --models;  claudeop --models;  clauden --models
"@
  } else {
    Write-Host @'
install.ps1: done.
  Next steps:
  1. Restart PowerShell (or dot-source your $PROFILE)
  2. Log in to whatever your routes need (each needed once):
       cliproxyapi -codex-login          # GPT route (claudex)
       cliproxyapi -antigravity-login    # Gemini route (claudemini)
       # OpenCode Go key  ->  $env:CLAUDEOP_API_KEY = '...'   (claudeop)
       # VLLM server      ->  start it, set $env:CLAUDEN_BASE_URL  (clauden)
     then restart the proxy so it picks up the credentials.
  3. Verify:  claudex --models;  claudemini --models;  claudeop --models;  clauden --models
'@
  }

  if ($WithProxy -and -not $ProxyOk) {
    Write-Error 'install.ps1: wrappers are installed, but the proxy is not answering — fix it, then re-run with -WithProxy.'
    exit 1
  }
}
finally {
  if ($tempClone -and (Test-Path $tempClone)) { Remove-Item -Recurse -Force $tempClone -ErrorAction SilentlyContinue }
}
