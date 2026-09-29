# claudeop.ps1 - run Claude Code against OpenCode Go.
#
# Claude models use Zen's Anthropic Messages endpoint directly. Non-Claude chat
# models, including DeepSeek V4, use the bundled localhost bridge to translate
# Claude Code's Messages requests to OpenCode's Chat Completions endpoint.
# The bridge (claudeop_bridge.py, stdlib only) runs on 127.0.0.1 for this
# invocation only and is stopped afterwards.
#
# Install:  add  . $HOME\.claudex\claudeop.ps1   to your $PROFILE
# Requires: Python 3 on PATH (python). The bridge script must sit next to this
#           file, or set $env:CLAUDEOP_BRIDGE_SCRIPT to its absolute path.
# Works in Windows PowerShell 5.1 and PowerShell 7+.
#
# Environment knobs (all optional except CLAUDEOP_API_KEY):
#   CLAUDEOP_BASE_URL        API address (default https://opencode.ai/zen/go/v1)
#   CLAUDEOP_API_KEY         OpenCode Go API key
#   CLAUDEOP_MODEL           pin the primary model; empty means newest catalogue entry
#   CLAUDEOP_FALLBACK_MODEL  used when the catalogue cannot be fetched
#   CLAUDEOP_EXCLUDE         regex of model ids to ignore during auto-selection
#   CLAUDEOP_SUBAGENT_MODEL  model for spawned agents (default: same as primary)
#   CLAUDEOP_MAX_CONTEXT_TOKENS known context window; unset preserves Claude Code's default
#   CLAUDEOP_TOOL_SEARCH     true|false (default false; enable only if route forwards tool_reference)
#   CLAUDEOP_BRIDGE_SCRIPT   path to claudeop_bridge.py (default: next to this file)
#   CLAUDEOP_BRIDGE_PORT     localhost bridge port (default 0 = choose a free port)
#   CLAUDEOP_FRONTEND_MODEL  known Claude Code model used as the local protocol label
#   CLAUDEOP_DEBUG           1 prints bridge-side errors without request data

function Get-ClaudeopAnthropicBaseUrl {
    $base = if ($env:CLAUDEOP_BASE_URL) { $env:CLAUDEOP_BASE_URL } else { 'https://opencode.ai/zen/go/v1' }
    $base = $base.TrimEnd('/')
    if ($base -match '/v1$') { return $base.Substring(0, $base.Length - 3).TrimEnd('/') }
    return $base
}

function Get-ClaudeopModels {
    <#  Output objects: Id, Released, Kind (direct|chat), Usable ($true/$false),
        newest first. Needs $env:CLAUDEOP_API_KEY. #>
    if ([string]::IsNullOrEmpty($env:CLAUDEOP_API_KEY)) {
        Write-Error 'claudeop: set CLAUDEOP_API_KEY to your OpenCode Go API key'
        return @()
    }
    $base = if ($env:CLAUDEOP_BASE_URL) { $env:CLAUDEOP_BASE_URL } else { 'https://opencode.ai/zen/go/v1' }
    $exclude = if ($null -ne $env:CLAUDEOP_EXCLUDE) { $env:CLAUDEOP_EXCLUDE } else {
        'image|audio|tts|whisper|transcribe|embed|embedding|moderation|realtime|review|search' }

    try {
        $resp = Invoke-RestMethod -Uri "$base/models" `
            -Headers @{ Authorization = "Bearer $($env:CLAUDEOP_API_KEY)"
                        'User-Agent' = 'claudeop/1.0'
                        'x-opencode-session' = 'claudeop-model-list' } `
            -TimeoutSec 10 -ErrorAction Stop
    } catch {
        return @()
    }

    if (-not $resp.data) { return @() }

    $resp.data |
        Where-Object { $_.id } |
        ForEach-Object {
            $id = [string]$_.id
            $created = 0
            try { $created = [int64]$_.created } catch { $created = 0 }
            if ($created -gt 10000000000) { $created = [int64]($created / 1000) }
            $day = if ($created) {
                try { ([DateTimeOffset]::FromUnixTimeSeconds($created)).ToString('yyyy-MM-dd') }
                catch { '(invalid date)' }
            } else { '(no date)' }
            $m = [regex]::Match($id, '(?<!\d)(\d+)(?:[.-](\d+))?')
            if ($m.Success) { $major = [int]$m.Groups[1].Value; $minor = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 } }
            else { $major = -1; $minor = -1 }
            [pscustomobject]@{
                Id = $id; Created = $created; Major = $major; Minor = $minor
                Released = $day
                Kind = if ($id.StartsWith('claude-')) { 'direct' } else { 'chat' }
                Usable = if ([string]::IsNullOrWhiteSpace($exclude)) { $true } else { [bool]($id -notmatch $exclude) }
            }
        } |
        Sort-Object @{ Expression = 'Created'; Descending = $true },
                    @{ Expression = 'Major';   Descending = $true },
                    @{ Expression = 'Minor';   Descending = $true },
                    @{ Expression = 'Id';      Descending = $false } |
        ForEach-Object {
            [pscustomobject]@{ Id = $_.Id; Released = $_.Released; Kind = $_.Kind; Usable = $_.Usable }
        }
}

function Start-ClaudeopBridge {
    <#  Starts claudeop_bridge.py on 127.0.0.1 and returns
        @{ Process = <proc>; Port = <int>; TempDir = <path> }, or $null. #>
    param([Parameter(Mandatory = $true)][string]$Model)

    $script = if ($env:CLAUDEOP_BRIDGE_SCRIPT) { $env:CLAUDEOP_BRIDGE_SCRIPT } else {
        Join-Path $PSScriptRoot 'claudeop_bridge.py'
    }
    if (-not (Test-Path $script)) {
        Write-Error "claudeop: bridge script not found: $script"
        return $null
    }
    $port = if ($env:CLAUDEOP_BRIDGE_PORT) { $env:CLAUDEOP_BRIDGE_PORT } else { '0' }
    $base = if ($env:CLAUDEOP_BASE_URL) { $env:CLAUDEOP_BASE_URL } else { 'https://opencode.ai/zen/go/v1' }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('claudeop-bridge-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'python'
    $psi.Arguments = "`"$script`" --model `"$Model`" --base-url `"$base`" --port $port"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['CLAUDEOP_API_KEY'] = $env:CLAUDEOP_API_KEY
    $psi.EnvironmentVariables['CLAUDEOP_BASE_URL'] = $base
    if ($null -ne $env:CLAUDEOP_DEBUG) { $psi.EnvironmentVariables['CLAUDEOP_DEBUG'] = $env:CLAUDEOP_DEBUG }
    $proc = [System.Diagnostics.Process]::Start($psi)

    $foundPort = $null
    for ($i = 0; $i -lt 50; $i++) {
        if ($proc.HasExited) {
            $err = $proc.StandardError.ReadToEnd()
            Write-Error 'claudeop: local bridge failed to start'
            if ($err) { Write-Error $err }
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
            return $null
        }
        Start-Sleep -Milliseconds 100
        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            if ($line -match '^PORT=(\d+)$') { $foundPort = $Matches[1]; break }
        }
        if ($foundPort) { break }
        # Peek without blocking: if no line yet, keep waiting.
        if ($proc.StandardOutput.Peek() -eq -1) { continue }
    }

    if (-not $foundPort) {
        Write-Error 'claudeop: local bridge did not announce a port'
        try { $proc.Kill() } catch {}
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        return $null
    }
    return @{ Process = $proc; Port = $foundPort; TempDir = $tmp }
}

function Stop-ClaudeopBridge {
    param($Bridge)
    if ($null -ne $Bridge) {
        try { $Bridge.Process.Kill() } catch {}
        try { $Bridge.Process.WaitForExit(2000) } catch {}
        $log = $Bridge.Process.StandardError.ReadToEnd()
        if ($env:CLAUDEOP_DEBUG -eq '1' -and $log) { Write-Warning ("claudeop bridge log: " + $log) }
        Remove-Item -Recurse -Force $Bridge.TempDir -ErrorAction SilentlyContinue
    }
}

function claudeop {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)

    if ($null -eq $Rest) { $Rest = @() }

    $listMode = $false
    $showAll = $false
    if ($Rest.Count -ge 1 -and ($Rest[0] -eq '--models' -or $Rest[0] -eq '--list-models')) { $listMode = $true }
    elseif ($Rest.Count -ge 1 -and $Rest[0] -eq '--models-all') { $listMode = $true; $showAll = $true }

    $fallback = if ($env:CLAUDEOP_FALLBACK_MODEL) { $env:CLAUDEOP_FALLBACK_MODEL } else { 'deepseek-v4-pro' }

    if ($listMode) {
        if ([string]::IsNullOrEmpty($env:CLAUDEOP_API_KEY)) {
            Write-Error 'claudeop: set CLAUDEOP_API_KEY to your OpenCode Go API key'
            return
        }
        $models = @(Get-ClaudeopModels)
        if ($models.Count -eq 0) {
            Write-Error 'claudeop: cannot reach OpenCode Go or the API key was rejected'
            return
        }
        $usable = @($models | Where-Object { $_.Usable })
        $chosen = if ($env:CLAUDEOP_MODEL) { $env:CLAUDEOP_MODEL }
                  elseif ($usable.Count -gt 0) { $usable[0].Id }
                  else { $fallback }
        if ($usable.Count -eq 0) {
            Write-Warning 'claudeop: the catalogue contains no model allowed by CLAUDEOP_EXCLUDE'
            $showAll = $true
        }
        foreach ($m in $models) {
            if (-not $m.Usable) {
                if ($showAll) { '  {0,-28} {1}   (excluded by CLAUDEOP_EXCLUDE)' -f $m.Id, $m.Released }
            }
            elseif ($m.Kind -eq 'direct') {
                if ($m.Id -eq $chosen) { '  {0,-28} {1}   <- claudeop uses this (Anthropic Messages)' -f $m.Id, $m.Released }
                else                   { '  {0,-28} {1}' -f $m.Id, $m.Released }
            }
            else {
                if ($m.Id -eq $chosen) { '  {0,-28} {1}   <- claudeop uses this (local Chat Completions bridge)' -f $m.Id, $m.Released }
                else                   { '  {0,-28} {1}   (local Chat Completions bridge)' -f $m.Id, $m.Released }
            }
        }
        return
    }

    # An explicit --model / -m / --model= from the caller always wins.
    $model = $null
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        if (($Rest[$i] -eq '--model' -or $Rest[$i] -eq '-m') -and ($i + 1) -lt $Rest.Count) {
            $model = $Rest[$i + 1]
        } elseif ($Rest[$i] -like '--model=*') {
            $model = $Rest[$i].Substring('--model='.Length)
        }
    }

    if ([string]::IsNullOrEmpty($env:CLAUDEOP_API_KEY)) {
        Write-Error 'claudeop: set CLAUDEOP_API_KEY to your OpenCode Go API key'
        return
    }

    $fromAuto = $false
    if ([string]::IsNullOrEmpty($model)) {
        if ($env:CLAUDEOP_MODEL) { $model = $env:CLAUDEOP_MODEL }
        else {
            $first = @(Get-ClaudeopModels) | Where-Object { $_.Usable } | Select-Object -First 1
            if ($first) { $model = $first.Id } else { $model = $fallback }
        }
        $fromAuto = $true
    }

    $sub = if ($env:CLAUDEOP_SUBAGENT_MODEL) { $env:CLAUDEOP_SUBAGENT_MODEL } else { $model }
    $toolSearch = if ($null -ne $env:CLAUDEOP_TOOL_SEARCH) { $env:CLAUDEOP_TOOL_SEARCH } else { 'false' }
    $maxCtx = $env:CLAUDEOP_MAX_CONTEXT_TOKENS
    if ($null -eq $maxCtx) { $maxCtx = $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS }

    $names = @('ANTHROPIC_BASE_URL', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN',
               'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDE_CODE_MAX_CONTEXT_TOKENS',
               'CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT',
               'CLAUDE_CODE_ALWAYS_ENABLE_EFFORT', 'CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY',
               'ENABLE_TOOL_SEARCH')
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }

    try {
        if ($model.StartsWith('claude-')) {
            # Direct Claude route: Go's OpenAI-compatible API uses Bearer auth.
            $env:ANTHROPIC_BASE_URL = Get-ClaudeopAnthropicBaseUrl
            Remove-Item 'Env:ANTHROPIC_API_KEY' -ErrorAction SilentlyContinue
            $env:ANTHROPIC_AUTH_TOKEN = $env:CLAUDEOP_API_KEY
            $env:CLAUDE_CODE_SUBAGENT_MODEL = $sub
            $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = $maxCtx
            $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = '1'
            $env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = '3'
            $env:ENABLE_TOOL_SEARCH = $toolSearch
            if ($fromAuto) { & claude --model $model @Rest } else { & claude @Rest }
        }
        else {
            $bridge = Start-ClaudeopBridge -Model $model
            if ($null -eq $bridge) { return }
            try {
                $frontend = if ($env:CLAUDEOP_FRONTEND_MODEL) { $env:CLAUDEOP_FRONTEND_MODEL } else { 'claude-sonnet-5' }
                $childArgs = @()
                $skipNext = $false
                foreach ($a in $Rest) {
                    if ($skipNext) { $childArgs += $frontend; $skipNext = $false; continue }
                    if ($a -eq '--model' -or $a -eq '-m') { $childArgs += $a; $skipNext = $true }
                    elseif ($a -like '--model=*') { $childArgs += "--model=$frontend" }
                    else { $childArgs += $a }
                }
                if ($fromAuto) {
                    $childArgs = @('--model', $frontend) + $childArgs
                }
                $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$($bridge.Port)"
                Remove-Item 'Env:ANTHROPIC_API_KEY' -ErrorAction SilentlyContinue
                $env:ANTHROPIC_AUTH_TOKEN = 'claudeop-local-bridge'
                $env:CLAUDE_CODE_SUBAGENT_MODEL = $frontend
                $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = $maxCtx
                $env:CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT = '1'
                $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = '1'
                $env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = '3'
                $env:ENABLE_TOOL_SEARCH = $toolSearch
                & claude @childArgs
            }
            finally { Stop-ClaudeopBridge -Bridge $bridge }
        }
    }
    finally {
        foreach ($n in $names) {
            if ($null -eq $saved[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
            else { Set-Item "Env:$n" -Value $saved[$n] }
        }
    }
}
