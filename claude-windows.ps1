function Install-ClaudeAzure {
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$EndpointUrl,
    [Parameter(Mandatory = $true, Position = 1)]
    [string]$ApiKey
  )

  Set-StrictMode -Version Latest
  $ErrorActionPreference = "Stop"
  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  $Model = "claude-opus-4-7"
  $SonnetModel = "claude-sonnet-4-6"
  $HaikuModel = "claude-haiku-4-5"

  # Quality-tuned defaults for Foundry-deployed Claude models.
  # Capability declaration values use Foundry semantics (max valid for Opus/Sonnet 4.6+).
  $OpusCaps = "thinking,effort=xhigh"
  $SonnetCaps = "thinking,effort=xhigh"
  $HaikuCaps = ""
  # Claude Code effort level enum is low|medium|high|xhigh (no "max" at CLI layer).
  $EffortLevel = "xhigh"
  $AlwaysEnableEffort = "0"
  $ApiTimeoutMs = "600000"
  $BashDefaultTimeoutMs = "300000"
  $BashMaxTimeoutMs = "1800000"
  $DisableNonessentialTraffic = "1"

  $StartMarker = "# >>> claude-azure-auto >>>"
  $EndMarker = "# <<< claude-azure-auto <<<"

  # Vars the script "owns". Any assignment to these outside the managed block
  # gets scrubbed so HKCU is the single source of truth.
  $TargetVars = @(
    "CLAUDE_CODE_USE_FOUNDRY",
    "ANTHROPIC_FOUNDRY_BASE_URL",
    "ANTHROPIC_FOUNDRY_API_KEY",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDE_CODE_EFFORT_LEVEL",
    "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT",
    "API_TIMEOUT_MS",
    "BASH_DEFAULT_TIMEOUT_MS",
    "BASH_MAX_TIMEOUT_MS",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_BASE_URL"
  )

  function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Cyan
  }

  function Normalize-FoundryBaseUrl {
    param([string]$Url)
    $u = $Url.Trim().Trim('"').Trim("'").TrimEnd("/")
    if ($u -match "/anthropic/v1/messages$") {
      return ($u -replace "/v1/messages$", "")
    }
    if ($u -match "/v1/messages$") {
      $u = $u -replace "/v1/messages$", ""
    }
    if ($u -notmatch "/anthropic$") {
      $u = "$u/anthropic"
    }
    return $u
  }

  function Ensure-UserPathContains {
    param([string]$PathToAdd)
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($userPath) { $parts = $userPath -split ";" | Where-Object { $_ } }
    if ($parts -notcontains $PathToAdd) {
      $newPath = if ($userPath) { "$userPath;$PathToAdd" } else { $PathToAdd }
      [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }
    if (($env:Path -split ";") -notcontains $PathToAdd) {
      $env:Path = "$PathToAdd;$env:Path"
    }
  }

  # Remove stale assignments to $TargetVars that sit OUTSIDE the managed block.
  # Inside the managed block we control fully via Upsert-ManagedBlock.
  function Remove-StaleAssignments {
    param(
      [string]$Path,
      [string[]]$VarNames,
      [ValidateSet("powershell", "bash")]
      [string]$Syntax
    )
    if (-not (Test-Path $Path)) { return }
    $raw = Get-Content -Raw -Path $Path
    if (-not $raw) { return }

    $varAlt = ($VarNames | ForEach-Object { [Regex]::Escape($_) }) -join "|"

    if ($Syntax -eq "powershell") {
      $patterns = @(
        '^\s*\$\{?env:(?:__VARS__)\}?\s*=',
        '^\s*Set-Item\b[^\r\n]*\bEnv:(?:__VARS__)\b',
        '^\s*\[(?:System\.)?Environment\]::SetEnvironmentVariable\(\s*["''](?:__VARS__)["'']'
      ) | ForEach-Object { $_ -replace '__VARS__', $varAlt }
    }
    else {
      $patterns = @(
        '^\s*export\s+(?:__VARS__)\s*=',
        '^\s*(?:__VARS__)=[^\r\n]*;\s*export\s+(?:__VARS__)\b',
        '^\s*export\s+(?:__VARS__)\s*$'
      ) | ForEach-Object { $_ -replace '__VARS__', $varAlt }
    }

    $lines = $raw -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $inManaged = $false
    foreach ($ln in $lines) {
      $trim = $ln.TrimEnd()
      if ($trim -eq $StartMarker) { $inManaged = $true; $out.Add($ln); continue }
      if ($trim -eq $EndMarker)   { $inManaged = $false; $out.Add($ln); continue }
      if ($inManaged) { $out.Add($ln); continue }

      $matched = $false
      foreach ($p in $patterns) {
        if ($ln -match $p) { $matched = $true; break }
      }
      if (-not $matched) { $out.Add($ln) }
    }

    $joined = ($out -join "`r`n")
    # Collapse 3+ blank lines left by removal
    $joined = [Regex]::Replace($joined, "(\r?\n){3,}", "`r`n`r`n")
    [System.IO.File]::WriteAllText($Path, $joined, $Utf8NoBom)
  }

  function Upsert-ManagedBlock {
    param(
      [string]$Path,
      [string[]]$BlockLines
    )

    if (!(Test-Path $Path)) {
      New-Item -ItemType File -Force -Path $Path | Out-Null
    }

    $raw = Get-Content -Raw -Path $Path
    if (-not $raw) { $raw = "" }
    $escapedStart = [Regex]::Escape($StartMarker)
    $escapedEnd   = [Regex]::Escape($EndMarker)
    $pairedPattern = "(?s)$escapedStart.*?$escapedEnd\r?\n?"
    # Strip ALL paired managed blocks (handles duplicates from buggy older runs)
    $raw = [Regex]::Replace($raw, $pairedPattern, "")
    # Strip orphan marker lines (odd-count corruption)
    $raw = [Regex]::Replace($raw, "(?m)^[^\r\n]*$escapedStart[^\r\n]*\r?\n?", "")
    $raw = [Regex]::Replace($raw, "(?m)^[^\r\n]*$escapedEnd[^\r\n]*\r?\n?", "")

    $block = ($BlockLines -join "`r`n")
    $newBlock = "$StartMarker`r`n$block`r`n$EndMarker"

    $raw = $raw.TrimEnd()
    if ($raw) {
      $raw = "$raw`r`n`r`n$newBlock`r`n"
    } else {
      $raw = "$newBlock`r`n"
    }

    [System.IO.File]::WriteAllText($Path, $raw, $Utf8NoBom)
  }

  function Update-VsCodeSettings {
    param(
      [string]$FoundryBaseUrl,
      [string]$Key,
      [string]$Model,
      [string]$SonnetModel,
      [string]$HaikuModel,
      [string]$OpusCaps,
      [string]$SonnetCaps,
      [string]$HaikuCaps,
      [string]$EffortLevel,
      [string]$AlwaysEnableEffort,
      [string]$ApiTimeoutMs,
      [string]$BashDefaultTimeoutMs,
      [string]$BashMaxTimeoutMs,
      [string]$DisableNonessentialTraffic
    )

    $settingsPath = Join-Path $env:APPDATA "Code\User\settings.json"
    $settingsDir = Split-Path $settingsPath
    New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null

    $obj = [pscustomobject]@{}
    if (Test-Path $settingsPath) {
      $content = Get-Content -Raw -Path $settingsPath
      if ($content -and $content.Trim()) {
        try { $obj = $content | ConvertFrom-Json } catch { $obj = [pscustomobject]@{} }
      }
    }

    $pairs = @{
      "claudeCode.disableLoginPrompt" = $true
      "claudeCode.environmentVariables" = @(
        @{ name = "CLAUDE_CODE_USE_FOUNDRY"; value = "1" },
        @{ name = "ANTHROPIC_FOUNDRY_BASE_URL"; value = $FoundryBaseUrl },
        @{ name = "ANTHROPIC_FOUNDRY_API_KEY"; value = $Key },
        @{ name = "ANTHROPIC_DEFAULT_OPUS_MODEL"; value = $Model },
        @{ name = "ANTHROPIC_DEFAULT_SONNET_MODEL"; value = $SonnetModel },
        @{ name = "ANTHROPIC_DEFAULT_HAIKU_MODEL"; value = $HaikuModel },
        @{ name = "CLAUDE_CODE_SUBAGENT_MODEL"; value = $Model },
        @{ name = "ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES"; value = $OpusCaps },
        @{ name = "ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES"; value = $SonnetCaps },
        @{ name = "CLAUDE_CODE_EFFORT_LEVEL"; value = $EffortLevel },
        @{ name = "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT"; value = $AlwaysEnableEffort },
        @{ name = "API_TIMEOUT_MS"; value = $ApiTimeoutMs },
        @{ name = "BASH_DEFAULT_TIMEOUT_MS"; value = $BashDefaultTimeoutMs },
        @{ name = "BASH_MAX_TIMEOUT_MS"; value = $BashMaxTimeoutMs },
        @{ name = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"; value = $DisableNonessentialTraffic }
      ) + $(if ($HaikuCaps) { @(@{ name = "ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES"; value = $HaikuCaps }) } else { @() })
    }

    foreach ($k in $pairs.Keys) {
      if ($obj.PSObject.Properties.Match($k).Count -gt 0) {
        $obj.PSObject.Properties[$k].Value = $pairs[$k]
      }
      else {
        $obj | Add-Member -NotePropertyName $k -NotePropertyValue $pairs[$k] -Force
      }
    }

    $json = $obj | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($settingsPath, $json, $Utf8NoBom)
  }

  function Broadcast-EnvChange {
    # Tell Explorer/new terminals to refresh environment from registry.
    if (-not ("Win32.NativeBroadcast" -as [type])) {
      Add-Type -Namespace Win32 -Name NativeBroadcast -MemberDefinition @"
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@
    }
    $HWND_BROADCAST   = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1A
    $SMTO_ABORTIFHUNG = 0x0002
    $result = [UIntPtr]::Zero
    [Win32.NativeBroadcast]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, "Environment", $SMTO_ABORTIFHUNG, 5000, [ref]$result) | Out-Null
  }

  function Invoke-VerifyInChild {
    param([string]$Label, [switch]$NoProfile)

    $verifyBody = @'
$vars = @(
  "CLAUDE_CODE_USE_FOUNDRY",
  "ANTHROPIC_FOUNDRY_BASE_URL",
  "ANTHROPIC_FOUNDRY_API_KEY",
  "ANTHROPIC_DEFAULT_OPUS_MODEL",
  "ANTHROPIC_DEFAULT_SONNET_MODEL",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL",
  "ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES",
  "ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES",
  "CLAUDE_CODE_SUBAGENT_MODEL",
  "CLAUDE_CODE_EFFORT_LEVEL",
  "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT",
  "API_TIMEOUT_MS",
  "BASH_DEFAULT_TIMEOUT_MS",
  "BASH_MAX_TIMEOUT_MS",
  "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
  "ANTHROPIC_MODEL",
  "ANTHROPIC_BASE_URL"
)
foreach ($v in $vars) {
  $val = [Environment]::GetEnvironmentVariable($v, "Process")
  if ($v -eq "ANTHROPIC_FOUNDRY_API_KEY" -and $val) {
    $val = "<set, " + $val.Length + " chars>"
  }
  if (-not $val) { $val = "<unset>" }
  Write-Host ("  {0,-42} = {1}" -f $v, $val)
}
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($verifyBody))
    Write-Host "--- $Label ---" -ForegroundColor Yellow
    if ($NoProfile) {
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
    } else {
      & powershell.exe -ExecutionPolicy Bypass -EncodedCommand $encoded
    }
  }

  # ---------------------- Execution ----------------------

  $foundryBaseUrl = Normalize-FoundryBaseUrl -Url $EndpointUrl
  $claudeBin = Join-Path $HOME ".local\bin"

  $desired = [ordered]@{
    CLAUDE_CODE_USE_FOUNDRY                                = "1"
    ANTHROPIC_FOUNDRY_BASE_URL                             = $foundryBaseUrl
    ANTHROPIC_FOUNDRY_API_KEY                              = $ApiKey
    ANTHROPIC_DEFAULT_OPUS_MODEL                           = $Model
    ANTHROPIC_DEFAULT_SONNET_MODEL                         = $SonnetModel
    ANTHROPIC_DEFAULT_HAIKU_MODEL                          = $HaikuModel
    ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES    = $OpusCaps
    ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES  = $SonnetCaps
    ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES   = $HaikuCaps
    CLAUDE_CODE_SUBAGENT_MODEL                             = $Model
    CLAUDE_CODE_EFFORT_LEVEL                               = $EffortLevel
    CLAUDE_CODE_ALWAYS_ENABLE_EFFORT                       = $AlwaysEnableEffort
    API_TIMEOUT_MS                                         = $ApiTimeoutMs
    BASH_DEFAULT_TIMEOUT_MS                                = $BashDefaultTimeoutMs
    BASH_MAX_TIMEOUT_MS                                    = $BashMaxTimeoutMs
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC               = $DisableNonessentialTraffic
  }
  if (-not $HaikuCaps) {
    $desired.Remove("ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES")
    [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES", $null, "User")
    Remove-Item -Path "Env:ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES" -ErrorAction SilentlyContinue
  }

  Write-Step "Installing Claude Code via official installer (claude.ai/install.ps1)"
  & ([scriptblock]::Create((Invoke-RestMethod -Uri "https://claude.ai/install.ps1")))

  # Resolve real Documents folder (honors OneDrive / Known Folder redirection,
  # e.g. C:\Users\x\OneDrive\TĂ i liá»‡u on VN systems).
  $myDocs = [Environment]::GetFolderPath('MyDocuments')
  $psProfilePaths = @(
    $PROFILE.CurrentUserCurrentHost,
    $PROFILE.CurrentUserAllHosts,
    "$myDocs\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
    "$myDocs\WindowsPowerShell\Microsoft.VSCode_profile.ps1",
    "$myDocs\WindowsPowerShell\profile.ps1",
    "$myDocs\PowerShell\Microsoft.PowerShell_profile.ps1",
    "$myDocs\PowerShell\Microsoft.VSCode_profile.ps1",
    "$myDocs\PowerShell\profile.ps1",
    # Legacy / non-redirected Documents (in case OneDrive redirection was ever
    # turned off and a stale profile remains at the classic location)
    "$HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1",
    "$HOME\Documents\WindowsPowerShell\Microsoft.VSCode_profile.ps1",
    "$HOME\Documents\WindowsPowerShell\profile.ps1",
    "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
    "$HOME\Documents\PowerShell\Microsoft.VSCode_profile.ps1",
    "$HOME\Documents\PowerShell\profile.ps1"
  ) | Where-Object { $_ } | Select-Object -Unique
  $bashrcPath = Join-Path $HOME ".bashrc"

  Write-Step "Scrubbing stale assignments from PowerShell profiles + .bashrc"
  foreach ($p in $psProfilePaths) {
    Remove-StaleAssignments -Path $p -VarNames $TargetVars -Syntax "powershell"
  }
  Remove-StaleAssignments -Path $bashrcPath -VarNames $TargetVars -Syntax "bash"

  Write-Step "Clearing legacy User env (ANTHROPIC_MODEL, ANTHROPIC_BASE_URL)"
  foreach ($legacy in @("ANTHROPIC_MODEL", "ANTHROPIC_BASE_URL")) {
    if ([Environment]::GetEnvironmentVariable($legacy, "User")) {
      [Environment]::SetEnvironmentVariable($legacy, $null, "User")
    }
    if (Test-Path "Env:$legacy") {
      Remove-Item "Env:$legacy" -ErrorAction SilentlyContinue
    }
  }

  Write-Step "Writing desired values to HKCU user env + current process"
  Ensure-UserPathContains -PathToAdd $claudeBin
  foreach ($k in $desired.Keys) {
    [Environment]::SetEnvironmentVariable($k, $desired[$k], "User")
    Set-Item -Path "Env:$k" -Value $desired[$k]
  }

  Write-Step "Rewriting PowerShell profile managed blocks (PATH only, no hardcoded env)"
  foreach ($profilePath in $psProfilePaths) {
    $profileDir = Split-Path -Parent $profilePath
    if ($profileDir) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
    Upsert-ManagedBlock -Path $profilePath -BlockLines @(
      '$claudeBin = Join-Path $HOME ".local\bin"',
      'if (Test-Path $claudeBin) {',
      '  if (($env:Path -split ";") -notcontains $claudeBin) {',
      '    $env:Path = "$claudeBin;$env:Path"',
      '  }',
      '}',
      '# Claude Azure env vars (CLAUDE_CODE_USE_FOUNDRY, ANTHROPIC_FOUNDRY_*,',
      '# ANTHROPIC_DEFAULT_*_MODEL) are owned by HKCU:\Environment.',
      '# Managed by install-claude-azure.ps1 - do NOT hardcode here.'
    )
  }

  Write-Step "Rewriting Git Bash ~/.bashrc managed block (PATH only)"
  Upsert-ManagedBlock -Path $bashrcPath -BlockLines @(
    'export PATH="$HOME/.local/bin:$PATH"',
    '# Claude Azure env vars are inherited from Windows user env (HKCU registry).',
    '# Managed by install-claude-azure.ps1 - do NOT hardcode here.'
  )

  Write-Step "Updating VS Code settings"
  Update-VsCodeSettings `
    -FoundryBaseUrl $foundryBaseUrl -Key $ApiKey `
    -Model $Model -SonnetModel $SonnetModel -HaikuModel $HaikuModel `
    -OpusCaps $OpusCaps -SonnetCaps $SonnetCaps -HaikuCaps $HaikuCaps `
    -EffortLevel $EffortLevel -AlwaysEnableEffort $AlwaysEnableEffort `
    -ApiTimeoutMs $ApiTimeoutMs `
    -BashDefaultTimeoutMs $BashDefaultTimeoutMs -BashMaxTimeoutMs $BashMaxTimeoutMs `
    -DisableNonessentialTraffic $DisableNonessentialTraffic

  Write-Step "Broadcasting WM_SETTINGCHANGE so new terminals pick up env"
  Broadcast-EnvChange

  Write-Step "Verifying Claude launcher"
  $claudeExe = Join-Path $claudeBin "claude.exe"
  if (Test-Path $claudeExe) {
    try { & $claudeExe --version } catch { Write-Host "claude --version failed." -ForegroundColor Yellow }
    try { & $claudeExe auth status } catch { Write-Host "Could not run 'claude auth status' yet." }
  }
  else {
    Write-Host "Warning: claude not found at $claudeExe" -ForegroundColor Yellow
  }

  Write-Step "Verification #1: fresh PowerShell -NoProfile (reads HKCU only)"
  Invoke-VerifyInChild -Label "NO PROFILE" -NoProfile

  Write-Step "Verification #2: PowerShell WITH profile (detects profile override)"
  Invoke-VerifyInChild -Label "WITH PROFILE"

  # Parent-process hint: explain the "just installed but new terminal still shows old values" trap.
  $parentName = "<unknown>"
  $parentPath = ""
  try {
    $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId
    if ($ppid) {
      $parent = Get-Process -Id $ppid -ErrorAction Stop
      $parentName = $parent.Name
      try { $parentPath = $parent.Path } catch { $parentPath = "" }
    }
  } catch { }

  # Some terminal hosts launch shells via an intermediate (winpty-agent, conhost).
  # Walk one more step up if that's the case.
  $grandName = ""
  try {
    if ($parentName -in @("winpty-agent", "conhost", "OpenConsole")) {
      $gppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction Stop).ParentProcessId
      if ($gppid) {
        $grand = Get-Process -Id $gppid -ErrorAction Stop
        $grandName = $grand.Name
      }
    }
  } catch { }

  $hostApp = if ($grandName) { $grandName } else { $parentName }

  Write-Host ""
  Write-Host "Done." -ForegroundColor Green
  Write-Host "Foundry base URL: $foundryBaseUrl"
  Write-Host "Default models: Opus=$Model | Sonnet=$SonnetModel | Haiku=$HaikuModel"
  Write-Host "Subagent model: $Model"
  Write-Host "Capabilities: Opus=$OpusCaps | Sonnet=$SonnetCaps | Haiku=$HaikuCaps"
  Write-Host "Effort: level=$EffortLevel | always_enable=$AlwaysEnableEffort"
  Write-Host "Timeouts: api=${ApiTimeoutMs}ms | bash default=${BashDefaultTimeoutMs}ms | bash max=${BashMaxTimeoutMs}ms"
  Write-Host ""
  Write-Host "If a NEW shell still shows OLD values, the terminal host cached env at its own launch." -ForegroundColor Yellow
  Write-Host "Detected terminal host: $hostApp" -ForegroundColor Yellow
  Write-Host "Fix: QUIT the host completely (Task Manager -> End task on every instance), then reopen." -ForegroundColor Yellow
  Write-Host "  Common hosts that cache env: Termius, Windows Terminal (wt.exe), VS Code (Code.exe)," -ForegroundColor Yellow
  Write-Host "  Hyper, ConEmu, Cmder, Tabby, JetBrains terminals. Closing a tab is NOT enough." -ForegroundColor Yellow
  Write-Host "Quick test without restarting: open PowerShell directly from Start menu and run:" -ForegroundColor Yellow
  Write-Host "  `$env:ANTHROPIC_FOUNDRY_BASE_URL" -ForegroundColor Yellow
}
Install-ClaudeAzure $args[0] $args[1]
