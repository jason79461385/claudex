# claudemini.ps1 - run Claude Code against a GEMINI model served by a local CLIProxyAPI.
#
# Sibling of claudex.ps1. Same proxy, same port; the only real difference is that
# this one filters the catalogue DOWN TO Gemini, because one CLIProxyAPI instance
# serves GPT and Gemini side by side and "newest model" would otherwise pick a GPT.
#
# Install:  add  . $HOME\.claudex\claudemini\claudemini.ps1   to your $PROFILE
# Works in Windows PowerShell 5.1 and PowerShell 7+.
#
# Environment knobs (all optional):
#   CLAUDEMINI_BASE_URL        proxy address          (default http://127.0.0.1:8317)
#   CLAUDEMINI_API_KEY         proxy api key          (default sk-dummy)
#   CLAUDEMINI_MODEL           pin the primary model, skips auto-detection
#   CLAUDEMINI_SUBAGENT_MODEL  model for spawned agents (default: same as primary)
#   CLAUDEMINI_SUBAGENT_FORCE  1 makes the line above beat per-agent model
#                              overrides (default 1)
#   CLAUDEMINI_MAX_CONTEXT_TOKENS  context window     (default 1000000)
#   CLAUDEMINI_FALLBACK_MODEL  used when the proxy is unreachable
#   CLAUDEMINI_INCLUDE         regex a model id MUST match to be usable
#   CLAUDEMINI_EXCLUDE         regex of model ids to ignore
#   CLAUDEMINI_TOOL_SEARCH     true|false             (default true)
#   CLAUDEMINI_DISALLOW        tools withheld from the request (default Artifact)

function Get-ClaudeminiModels {
    <#  Every model the proxy serves, Gemini-usable first-relevant order.
        Output objects: Id, Released, Usable ($true/$false).
        The Antigravity catalogue reports created=0 for every Gemini, so rank on
        the version number inside the id (same rule as claudemini.sh); ids with
        no version sort last. #>
    $base = if ($env:CLAUDEMINI_BASE_URL) { $env:CLAUDEMINI_BASE_URL } else { 'http://127.0.0.1:8317' }
    $key  = if ($env:CLAUDEMINI_API_KEY)  { $env:CLAUDEMINI_API_KEY }  else { 'sk-dummy' }
    $keep = if ($env:CLAUDEMINI_INCLUDE)  { $env:CLAUDEMINI_INCLUDE }  else { 'gemini|antigravity' }
    $skip = if ($env:CLAUDEMINI_EXCLUDE)  { $env:CLAUDEMINI_EXCLUDE }  else {
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
        ForEach-Object {
            $id = [string]$_.id
            $created = [int64]$_.created
            $day = if ($created) {
                ([DateTimeOffset]::FromUnixTimeSeconds($created)).ToString('yyyy-MM-dd')
            } else { '(no date)' }
            $m = [regex]::Match($id, '(\d+)(?:\.(\d+))?')
            if ($m.Success) { $major = [int]$m.Groups[1].Value; $minor = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 } }
            else { $major = -1; $minor = -1 }
            [pscustomobject]@{
                Id      = $id
                Created = $created
                Major   = $major
                Minor   = $minor
                Released = $day
                Usable  = [bool]($id -match $keep -and $id -notmatch $skip)
            }
        } |
        Sort-Object @{ Expression = 'Created'; Descending = $true },
                    @{ Expression = 'Major';   Descending = $true },
                    @{ Expression = 'Minor';   Descending = $true },
                    @{ Expression = 'Id';      Descending = $false } |
        ForEach-Object {
            [pscustomobject]@{ Id = $_.Id; Released = $_.Released; Usable = $_.Usable }
        }
}

function claudemini {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)

    if ($null -eq $Rest) { $Rest = @() }

    $listMode = $false
    $showAll = $false
    if ($Rest.Count -ge 1 -and ($Rest[0] -eq '--models' -or $Rest[0] -eq '--list-models')) { $listMode = $true }
    elseif ($Rest.Count -ge 1 -and $Rest[0] -eq '--models-all') { $listMode = $true; $showAll = $true }

    if ($listMode) {
        $models = @(Get-ClaudeminiModels)
        if ($models.Count -eq 0) {
            $base = if ($env:CLAUDEMINI_BASE_URL) { $env:CLAUDEMINI_BASE_URL } else { 'http://127.0.0.1:8317' }
            Write-Error "claudemini: cannot reach CLIProxyAPI at $base"
            return
        }
        $usable = @($models | Where-Object { $_.Usable })
        $fallback = if ($env:CLAUDEMINI_FALLBACK_MODEL) { $env:CLAUDEMINI_FALLBACK_MODEL } else { 'gemini-3.8-flash-high' }
        $chosen = if ($env:CLAUDEMINI_MODEL) { $env:CLAUDEMINI_MODEL }
                  elseif ($usable.Count -gt 0) { $usable[0].Id }
                  else { $fallback }
        if ($usable.Count -eq 0) {
            Write-Warning 'claudemini: the proxy serves no Gemini model. Add a credential, then restart the service.'
            $showAll = $true
        }
        foreach ($m in $models) {
            if (-not $m.Usable) {
                if ($showAll) { '  {0,-28} {1}   (not a usable Gemini chat model, skipped)' -f $m.Id, $m.Released }
            }
            elseif ($m.Id -eq $chosen) { '  {0,-28} {1}   <- claudemini uses this' -f $m.Id, $m.Released }
            else                        { '  {0,-28} {1}' -f $m.Id, $m.Released }
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

    $fallback = if ($env:CLAUDEMINI_FALLBACK_MODEL) { $env:CLAUDEMINI_FALLBACK_MODEL } else { 'gemini-3.8-flash-high' }
    $fromEnvOrAuto = $false
    if ([string]::IsNullOrEmpty($model)) {
        if ($env:CLAUDEMINI_MODEL) { $model = $env:CLAUDEMINI_MODEL }
        else {
            $first = @(Get-ClaudeminiModels) | Where-Object { $_.Usable } | Select-Object -First 1
            if ($first) { $model = $first.Id } else { $model = $fallback }
        }
        $fromEnvOrAuto = $true
    }

    # Subagents default to the SAME model as the session.
    $sub = if ($env:CLAUDEMINI_SUBAGENT_MODEL) { $env:CLAUDEMINI_SUBAGENT_MODEL } else { $model }
    $force = if ($env:CLAUDEMINI_SUBAGENT_FORCE) { $env:CLAUDEMINI_SUBAGENT_FORCE } else { '1' }
    $maxCtx = if ($env:CLAUDEMINI_MAX_CONTEXT_TOKENS) { $env:CLAUDEMINI_MAX_CONTEXT_TOKENS } else { '1000000' }
    $toolSearch = if ($env:CLAUDEMINI_TOOL_SEARCH) { $env:CLAUDEMINI_TOOL_SEARCH } else { 'true' }
    $disallow = if ($null -ne $env:CLAUDEMINI_DISALLOW) { $env:CLAUDEMINI_DISALLOW } else { 'Artifact' }

    $childArgs = @()
    if ($fromEnvOrAuto) { $childArgs += '--model'; $childArgs += $model }
    if (-not [string]::IsNullOrEmpty($disallow)) { $childArgs += '--disallowedTools'; $childArgs += $disallow }
    $childArgs += $Rest

    $names = @('ANTHROPIC_BASE_URL', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_SUBAGENT_MODEL',
               'CLAUDE_CODE_SUBAGENT_MODEL_FORCE', 'CLAUDE_CODE_MAX_CONTEXT_TOKENS',
               'CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT',
               'CLAUDE_CODE_ALWAYS_ENABLE_EFFORT', 'CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY',
               'ENABLE_TOOL_SEARCH')
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }

    try {
        $env:ANTHROPIC_BASE_URL   = if ($env:CLAUDEMINI_BASE_URL) { $env:CLAUDEMINI_BASE_URL } else { 'http://127.0.0.1:8317' }
        Remove-Item 'Env:ANTHROPIC_API_KEY' -ErrorAction SilentlyContinue
        $env:ANTHROPIC_AUTH_TOKEN = if ($env:CLAUDEMINI_API_KEY)  { $env:CLAUDEMINI_API_KEY }  else { 'sk-dummy' }
        $env:CLAUDE_CODE_SUBAGENT_MODEL        = $sub
        $env:CLAUDE_CODE_SUBAGENT_MODEL_FORCE  = $force
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS    = $maxCtx
        Remove-Item 'Env:CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT' -ErrorAction SilentlyContinue
        $env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT     = '1'
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
