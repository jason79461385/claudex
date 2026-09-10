# claudex.ps1 - run Claude Code against a GPT model served by a local CLIProxyAPI.
#
# Install:  add  . C:\path\to\claudex.ps1   to your $PROFILE
#
# NOTE: this PowerShell port has NOT been executed end-to-end by its author
#       (no PowerShell host was available). The zsh/bash version in claudex.sh
#       is the tested one. Please report anything that breaks here.
#
# Environment knobs (all optional):
#   CLAUDEX_BASE_URL        proxy address           (default http://127.0.0.1:8317)
#   CLAUDEX_API_KEY         proxy api key           (default sk-dummy)
#   CLAUDEX_MODEL           pin the primary model, skips auto-detection
#   CLAUDEX_SUBAGENT_MODEL  model for spawned agents (default gpt-5.6-terra)
#   CLAUDEX_MAX_CONTEXT_TOKENS known context window; unset preserves Claude Code's default
#   CLAUDEX_FALLBACK_MODEL  used when the proxy is unreachable (default gpt-5.6-sol)
#   CLAUDEX_EXCLUDE         regex of model ids to ignore
#   CLAUDEX_TOOL_SEARCH     true|false              (default true)

function Get-ClaudexModels {
    <#  Chat-capable models the proxy currently serves, newest first.
        Models released the same day sort alphabetically, so the choice stays
        deterministic instead of depending on API ordering. #>
    $base = if ($env:CLAUDEX_BASE_URL) { $env:CLAUDEX_BASE_URL } else { 'http://127.0.0.1:8317' }
    $key  = if ($env:CLAUDEX_API_KEY)  { $env:CLAUDEX_API_KEY }  else { 'sk-dummy' }
    $skip = if ($env:CLAUDEX_EXCLUDE)  { $env:CLAUDEX_EXCLUDE }  else {
        'image|audio|tts|whisper|transcribe|embed|moderation|realtime|review|search' }

    try {
        $resp = Invoke-RestMethod -Uri "$base/v1/models" `
                                  -Headers @{ Authorization = "Bearer $key" } `
                                  -TimeoutSec 5 -ErrorAction Stop
    } catch {
        return @()
    }

    $resp.data |
        Where-Object { $_.id -and $_.id -notmatch $skip } |
        Sort-Object @{ Expression = { [int64]$_.created }; Descending = $true },
                    @{ Expression = { $_.id };             Descending = $false } |
        ForEach-Object {
            [pscustomobject]@{
                Id       = $_.id
                Released = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$_.created)).ToString('yyyy-MM-dd')
            }
        }
}

function claudex {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)

    if ($null -eq $Rest) { $Rest = @() }

    if ($Rest.Count -ge 1 -and ($Rest[0] -eq '--models' -or $Rest[0] -eq '--list-models')) {
        $models = @(Get-ClaudexModels)
        if ($models.Count -eq 0) {
            $base = if ($env:CLAUDEX_BASE_URL) { $env:CLAUDEX_BASE_URL } else { 'http://127.0.0.1:8317' }
            Write-Error "claudex: cannot reach CLIProxyAPI at $base"
            return
        }
        $chosen = if ($env:CLAUDEX_MODEL) { $env:CLAUDEX_MODEL } else { $models[0].Id }
        foreach ($m in $models) {
            if ($m.Id -eq $chosen) { '  {0,-24} {1}   <- claudex uses this' -f $m.Id, $m.Released }
            else                   { '  {0,-24} {1}'                        -f $m.Id, $m.Released }
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
    $explicit = -not [string]::IsNullOrEmpty($model)

    if (-not $explicit) {
        if ($env:CLAUDEX_MODEL) {
            $model = $env:CLAUDEX_MODEL
        } else {
            $first = @(Get-ClaudexModels) | Select-Object -First 1
            if ($first) { $model = $first.Id }
            elseif ($env:CLAUDEX_FALLBACK_MODEL) { $model = $env:CLAUDEX_FALLBACK_MODEL }
            else { $model = 'gpt-5.6-sol' }
        }
    }

    $subagentModel = if ($env:CLAUDEX_SUBAGENT_MODEL) { $env:CLAUDEX_SUBAGENT_MODEL } else { 'gpt-5.6-terra' }
    $maxContextTokens = if ($env:CLAUDEX_MAX_CONTEXT_TOKENS) {
        $env:CLAUDEX_MAX_CONTEXT_TOKENS
    } else {
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS
    }

    # Set the seven variables for this invocation only, then put the shell back.
    $names = @('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_SUBAGENT_MODEL',
               'CLAUDE_CODE_MAX_CONTEXT_TOKENS', 'CLAUDE_CODE_ALWAYS_ENABLE_EFFORT',
               'CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY', 'ENABLE_TOOL_SEARCH')
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }

    try {
        $env:ANTHROPIC_BASE_URL   = if ($env:CLAUDEX_BASE_URL) { $env:CLAUDEX_BASE_URL } else { 'http://127.0.0.1:8317' }
        $env:ANTHROPIC_AUTH_TOKEN = if ($env:CLAUDEX_API_KEY)  { $env:CLAUDEX_API_KEY }  else { 'sk-dummy' }
        $env:CLAUDE_CODE_SUBAGENT_MODEL           = $subagentModel
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS       = $maxContextTokens
        $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT     = '1'
        $env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = '3'
        $env:ENABLE_TOOL_SEARCH = if ($env:CLAUDEX_TOOL_SEARCH) { $env:CLAUDEX_TOOL_SEARCH } else { 'true' }

        if ($explicit) { & claude @Rest }
        else           { & claude --model $model @Rest }
    }
    finally {
        foreach ($n in $names) {
            if ($null -eq $saved[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
            else { Set-Item "Env:$n" -Value $saved[$n] }
        }
    }
}
