# clauden.ps1 - run Claude Code against your self-hosted VLLM server.
#
# VLLM speaks OpenAI Chat Completions, not Anthropic Messages, so every
# session goes through the bundled localhost bridge (clauden_bridge.py),
# which translates Claude Code's Messages requests to Chat Completions.
# The bridge is localhost-only and pins the upstream request to the
# selected VLLM model.
#
# Install:  add  . $HOME\.claudex\clauden.ps1   to your $PROFILE
# Requires: Python 3 on PATH (python). The bridge script must sit next to this
#           file, or set $env:CLAUDEN_BRIDGE_SCRIPT to its absolute path.
# Works in Windows PowerShell 5.1 and PowerShell 7+.
#
# Environment knobs (all optional):
#   CLAUDEN_BASE_URL        VLLM address, with or without trailing /v1
#                           (default http://127.0.0.1:8000)
#   CLAUDEN_API_KEY         VLLM api key; empty means no auth header is sent
#   CLAUDEN_MODEL           pin the primary model; empty means newest catalogue entry
#   CLAUDEN_FALLBACK_MODEL  used when the catalogue cannot be fetched
#   CLAUDEN_EXCLUDE         regex of model ids to ignore during auto-selection
#   CLAUDEN_MAX_CONTEXT_TOKENS known context window; unset preserves Claude Code's default
#   CLAUDEN_TOOL_SEARCH     true|false (default true)
#   CLAUDEN_BRIDGE_SCRIPT   path to clauden_bridge.py (default: next to this file)
#   CLAUDEN_BRIDGE_PORT     localhost bridge port (default 0 = choose a free port)
#   CLAUDEN_FRONTEND_MODEL  known Claude Code model used as the local protocol label
#   CLAUDEN_DEBUG           1 prints bridge-side errors without request data
#
# NOTE: subagents share the session bridge, so they always use the same
# VLLM model as the primary session. The served model needs tool-calling
# support for Claude Code's tools to work (e.g. served with
# --enable-auto-tool-choice --tool-call-parser). Reasoning traces
# (reasoning_content) are dropped; the final answer is kept.

function Get-ClaudenModels {
    <#  Every model VLLM serves, newest first.
        Output objects: Id, Released, Usable ($true/$false). #>
    $base = if ($env:CLAUDEN_BASE_URL) { $env:CLAUDEN_BASE_URL } else { 'http://127.0.0.1:8000' }
    $base = $base.TrimEnd('/')
    $skip = if ($null -ne $env:CLAUDEN_EXCLUDE) { $env:CLAUDEN_EXCLUDE } else {
        'image|audio|tts|whisper|transcribe|embed|embedding|moderation|realtime|review|search' }

    $headers = @{}
    if (-not [string]::IsNullOrEmpty($env:CLAUDEN_API_KEY)) {
        $headers['Authorization'] = "Bearer $($env:CLAUDEN_API_KEY)"
    }
    try {
        $resp = Invoke-RestMethod -Uri "$base/v1/models" -Headers $headers -TimeoutSec 5 -ErrorAction Stop
    } catch {
        return @()
    }

    if (-not $resp.data) { return @() }

    $resp.data |
        Where-Object { $_.id } |
        Sort-Object @{ Expression = { try { [int64]$_.created } catch { 0 } }; Descending = $true },
                    @{ Expression = { $_.id }; Descending = $false } |
        ForEach-Object {
            $created = 0
            try { $created = [int64]$_.created } catch { $created = 0 }
            $day = if ($created) {
                ([DateTimeOffset]::FromUnixTimeSeconds($created)).ToString('yyyy-MM-dd')
            } else { '(no date)' }
            [pscustomobject]@{
                Id = [string]$_.id; Released = $day
                Usable = if ([string]::IsNullOrWhiteSpace($skip)) { $true } else { [bool]($_.id -notmatch $skip) }
            }
        }
}

function Start-ClaudenBridge {
    param([Parameter(Mandatory = $true)][string]$Model)

    $script = if ($env:CLAUDEN_BRIDGE_SCRIPT) { $env:CLAUDEN_BRIDGE_SCRIPT } else {
        Join-Path $PSScriptRoot 'clauden_bridge.py'
    }
    if (-not (Test-Path $script)) {
        Write-Error "clauden: bridge script not found: $script"
        return $null
    }
    $port = if ($env:CLAUDEN_BRIDGE_PORT) { $env:CLAUDEN_BRIDGE_PORT } else { '0' }
    $base = if ($env:CLAUDEN_BASE_URL) { $env:CLAUDEN_BASE_URL } else { 'http://127.0.0.1:8000' }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('clauden-bridge-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'python'
    $psi.Arguments = "`"$script`" --model `"$Model`" --base-url `"$base`" --port $port"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($null -ne $env:CLAUDEN_API_KEY) { $psi.EnvironmentVariables['CLAUDEN_API_KEY'] = $env:CLAUDEN_API_KEY }
    $psi.EnvironmentVariables['CLAUDEN_BASE_URL'] = $base
    if ($null -ne $env:CLAUDEN_DEBUG) { $psi.EnvironmentVariables['CLAUDEN_DEBUG'] = $env:CLAUDEN_DEBUG }
    $proc = [System.Diagnostics.Process]::Start($psi)

    $foundPort = $null
    for ($i = 0; $i -lt 50; $i++) {
        if ($proc.HasExited) {
            $err = $proc.StandardError.ReadToEnd()
            Write-Error 'clauden: local bridge failed to start'
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
        if ($proc.StandardOutput.Peek() -eq -1) { continue }
    }

    if (-not $foundPort) {
        Write-Error 'clauden: local bridge did not announce a port'
        try { $proc.Kill() } catch {}
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        return $null
    }
    return @{ Process = $proc; Port = $foundPort; TempDir = $tmp }
}

function Stop-ClaudenBridge {
    param($Bridge)
    if ($null -ne $Bridge) {
        try { $Bridge.Process.Kill() } catch {}
        try { $Bridge.Process.WaitForExit(2000) } catch {}
        $log = $Bridge.Process.StandardError.ReadToEnd()
        if ($env:CLAUDEN_DEBUG -eq '1' -and $log) { Write-Warning ("clauden bridge log: " + $log) }
        Remove-Item -Recurse -Force $Bridge.TempDir -ErrorAction SilentlyContinue
    }
}

function clauden {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)

    if ($null -eq $Rest) { $Rest = @() }

    $listMode = $false
    $showAll = $false
    if ($Rest.Count -ge 1 -and ($Rest[0] -eq '--models' -or $Rest[0] -eq '--list-models')) { $listMode = $true }
    elseif ($Rest.Count -ge 1 -and $Rest[0] -eq '--models-all') { $listMode = $true; $showAll = $true }

    if ($listMode) {
        $models = @(Get-ClaudenModels)
        if ($models.Count -eq 0) {
            $base = if ($env:CLAUDEN_BASE_URL) { $env:CLAUDEN_BASE_URL } else { 'http://127.0.0.1:8000' }
            Write-Error "clauden: cannot reach VLLM at $base"
            return
        }
        $usable = @($models | Where-Object { $_.Usable })
        $chosen = if ($env:CLAUDEN_MODEL) { $env:CLAUDEN_MODEL }
                  elseif ($usable.Count -gt 0) { $usable[0].Id }
                  else { $env:CLAUDEN_FALLBACK_MODEL }
        foreach ($m in $models) {
            if (-not $m.Usable) {
                if ($showAll) { '  {0,-24} {1}   (not a chat model, skipped)' -f $m.Id, $m.Released }
            }
            elseif ($m.Id -eq $chosen) { '  {0,-24} {1}   <- clauden uses this (local Chat Completions bridge)' -f $m.Id, $m.Released }
            else                       { '  {0,-24} {1}   (local Chat Completions bridge)' -f $m.Id, $m.Released }
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

    $fromAuto = $false
    if ([string]::IsNullOrEmpty($model)) {
        if ($env:CLAUDEN_MODEL) { $model = $env:CLAUDEN_MODEL }
        else {
            $first = @(Get-ClaudenModels) | Where-Object { $_.Usable } | Select-Object -First 1
            if ($first) { $model = $first.Id } else { $model = $env:CLAUDEN_FALLBACK_MODEL }
        }
        if ([string]::IsNullOrEmpty($model)) {
            Write-Error 'clauden: no model selected and VLLM is unreachable'
            return
        }
        $fromAuto = $true
    }

    $bridge = Start-ClaudenBridge -Model $model
    if ($null -eq $bridge) { return }

    try {
        $frontend = if ($env:CLAUDEN_FRONTEND_MODEL) { $env:CLAUDEN_FRONTEND_MODEL } else { 'claude-sonnet-5' }
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

        $maxCtx = $env:CLAUDEN_MAX_CONTEXT_TOKENS
        if ($null -eq $maxCtx) { $maxCtx = $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS }
        $toolSearch = if ($null -ne $env:CLAUDEN_TOOL_SEARCH) { $env:CLAUDEN_TOOL_SEARCH } else { 'true' }

        $names = @('ANTHROPIC_BASE_URL', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN',
                   'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDE_CODE_MAX_CONTEXT_TOKENS',
                   'CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT',
                   'CLAUDE_CODE_ALWAYS_ENABLE_EFFORT', 'CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY',
                   'ENABLE_TOOL_SEARCH')
        $saved = @{}
        foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }

        try {
            $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$($bridge.Port)"
            Remove-Item 'Env:ANTHROPIC_API_KEY' -ErrorAction SilentlyContinue
            $env:ANTHROPIC_AUTH_TOKEN = 'clauden-local-bridge'
            $env:CLAUDE_CODE_SUBAGENT_MODEL = $frontend
            $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = $maxCtx
            $env:CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT = '1'
            $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = '1'
            $env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = '3'
            $env:ENABLE_TOOL_SEARCH = $toolSearch
            & claude @childArgs
        }
        finally {
            foreach ($n in $names) {
                if ($null -eq $saved[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
                else { Set-Item "Env:$n" -Value $saved[$n] }
            }
        }
    }
    finally { Stop-ClaudenBridge -Bridge $bridge }
}
