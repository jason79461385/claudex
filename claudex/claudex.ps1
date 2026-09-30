# claudex.ps1 - run Claude Code against a GPT model served by a local CLIProxyAPI.
#
# Install:  add  . $HOME\.claudex\claudex\claudex.ps1   to your $PROFILE
# Works in Windows PowerShell 5.1 and PowerShell 7+.
#
# Environment knobs (all optional):
#   CLAUDEX_BASE_URL        proxy address           (default http://127.0.0.1:8317)
#   CLAUDEX_API_KEY         proxy api key           (default sk-dummy)
#   CLAUDEX_MODEL           pin the primary model, skips auto-detection
#   CLAUDEX_INCLUDE         regex a model id MUST match to be usable (default gpt|codex)
#   CLAUDEX_SUBAGENT_MODEL  model for spawned agents (default gpt-6-luna)
#   CLAUDEX_MAX_CONTEXT_TOKENS known context window; unset preserves Claude Code's default
#   CLAUDEX_FALLBACK_MODEL  used when the proxy is unreachable (default gpt-6-luna)
#   CLAUDEX_EXCLUDE         regex of model ids to ignore
#   CLAUDEX_TOOL_SEARCH     true|false              (default true)

function Get-ClaudexModels {
    <#  GPT models the proxy serves, newest first.
        Output objects: Id, Released (YYYY-MM-DD), Usable ($true/$false).
        The positive filter is what keeps this route on GPT: the same proxy
        serves gemini-* and claude-* side by side, so "newest usable id" alone
        would silently switch families. Same-day releases sort alphabetically
        so the pick is deterministic. #>
    $base = if ($env:CLAUDEX_BASE_URL) { $env:CLAUDEX_BASE_URL } else { 'http://127.0.0.1:8317' }
    $key  = if ($env:CLAUDEX_API_KEY)  { $env:CLAUDEX_API_KEY }  else { 'sk-dummy' }
    $keep = if ($env:CLAUDEX_INCLUDE)  { $env:CLAUDEX_INCLUDE }  else { 'gpt|codex' }
    $skip = if ($env:CLAUDEX_EXCLUDE)  { $env:CLAUDEX_EXCLUDE }  else {
        'image|audio|tts|whisper|transcribe|embed|moderation|realtime|review|search' }

    try {
        $resp = Invoke-RestMethod -Uri "$base/v1/models" `
                                  -Headers @{ Authorization = "Bearer $key" } `
                                  -TimeoutSec 5 -ErrorAction Stop
    } catch {
        return @()
    }

    if (-not $resp.data) { return @() }

    $resp.data |
        Where-Object { $_.id } |
        Sort-Object @{ Expression = { [int64]$_.created }; Descending = $true },
                    @{ Expression = { $_.id };             Descending = $false } |
        ForEach-Object {
            $created = [int64]$_.created
            $day = if ($created) {
                ([DateTimeOffset]::FromUnixTimeSeconds($created)).ToString('yyyy-MM-dd')
            } else { '(no date)' }
            [pscustomobject]@{
                Id       = $_.id
                Released = $day
                Usable   = [bool]($_.id -match $keep -and $_.id -notmatch $skip)
            }
        }
}

function claudex {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)

    if ($null -eq $Rest) { $Rest = @() }

    $showAll = $false
    if ($Rest.Count -ge 1 -and ($Rest[0] -eq '--models' -or $Rest[0] -eq '--list-models')) { $showAll = $false }
    elseif ($Rest.Count -ge 1 -and $Rest[0] -eq '--models-all') { $showAll = $true }

    if ($showAll -or ($Rest.Count -ge 1 -and ($Rest[0] -eq '--models' -or $Rest[0] -eq '--list-models'))) {
        $models = @(Get-ClaudexModels)
        if ($models.Count -eq 0) {
            $base = if ($env:CLAUDEX_BASE_URL) { $env:CLAUDEX_BASE_URL } else { 'http://127.0.0.1:8317' }
            Write-Error "claudex: cannot reach CLIProxyAPI at $base"
            return
        }
        $usable = @($models | Where-Object { $_.Usable })
        $chosen = if ($env:CLAUDEX_MODEL) { $env:CLAUDEX_MODEL }
                  elseif ($usable.Count -gt 0) { $usable[0].Id }
                  elseif ($env:CLAUDEX_FALLBACK_MODEL) { $env:CLAUDEX_FALLBACK_MODEL }
                  else { 'gpt-6-luna' }
        if ($usable.Count -eq 0) {
            Write-Warning 'claudex: the proxy serves no GPT model. Add a credential, then restart the service.'
            $showAll = $true
        }
        foreach ($m in $models) {
            if (-not $m.Usable) {
                if ($showAll) { '  {0,-24} {1}   (not a usable GPT chat model, skipped)' -f $m.Id, $m.Released }
            }
            elseif ($m.Id -eq $chosen) { '  {0,-24} {1}   <- claudex uses this' -f $m.Id, $m.Released }
            else                        { '  {0,-24} {1}'                        -f $m.Id, $m.Released }
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
            $first = @(Get-ClaudexModels) | Where-Object { $_.Usable } | Select-Object -First 1
            if ($first) { $model = $first.Id }
            elseif ($env:CLAUDEX_FALLBACK_MODEL) { $model = $env:CLAUDEX_FALLBACK_MODEL }
            else { $model = 'gpt-6-luna' }
        }
    }

    $subagentModel = if ($env:CLAUDEX_SUBAGENT_MODEL) { $env:CLAUDEX_SUBAGENT_MODEL } else { 'gpt-6-luna' }
    $maxContextTokens = if ($env:CLAUDEX_MAX_CONTEXT_TOKENS) {
        $env:CLAUDEX_MAX_CONTEXT_TOKENS
    } else {
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS
    }

    # Set the route's variables for this invocation only, then put the shell back.
    # ANTHROPIC_API_KEY is cleared so the proxy credential (AUTH_TOKEN) is the
    # only auth source; FORCE / DISABLE vars from other routes are cleared so
    # each route's subagent and window behaviour stays deterministic.
    $names = @('ANTHROPIC_BASE_URL', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN',
               'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL_FORCE',
               'CLAUDE_CODE_MAX_CONTEXT_TOKENS',
               'CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT',
               'CLAUDE_CODE_ALWAYS_ENABLE_EFFORT',
               'CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY', 'ENABLE_TOOL_SEARCH')
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }

    try {
        $env:ANTHROPIC_BASE_URL   = if ($env:CLAUDEX_BASE_URL) { $env:CLAUDEX_BASE_URL } else { 'http://127.0.0.1:8317' }
        Remove-Item 'Env:ANTHROPIC_API_KEY' -ErrorAction SilentlyContinue
        $env:ANTHROPIC_AUTH_TOKEN = if ($env:CLAUDEX_API_KEY)  { $env:CLAUDEX_API_KEY }  else { 'sk-dummy' }
        $env:CLAUDE_CODE_SUBAGENT_MODEL           = $subagentModel
        Remove-Item 'Env:CLAUDE_CODE_SUBAGENT_MODEL_FORCE' -ErrorAction SilentlyContinue
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS       = $maxContextTokens
        Remove-Item 'Env:CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT' -ErrorAction SilentlyContinue
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
