#Requires -Version 5.1
<#
.SYNOPSIS
    Sync LM Studio GGUF models to other local inference tools without duplicating files.

.DESCRIPTION
    Discovers GGUF models under LM Studio's model directory and registers them
    with one or more target inference tools. By default uses hardlinks or
    absolute-path references so a multi-GB GGUF is never duplicated on disk.

    Supported targets:
      - Ollama                (creates Modelfile + 'ollama create')
      - TextGenerationWebUI   (hardlinks GGUF into user_data/models)
      - KoboldCpp             (generates per-model launcher .bat)
      - LlamaCppServer        (generates per-model launcher .bat)
      - Jan                   (hardlinks GGUF into Jan's llamacpp/models folder)
      - All                   (all of the above that are configured)

    Deliberately MINIMAL Modelfiles are generated for Ollama. Modern Ollama
    autodetects the chat template from GGUF metadata (tokenizer.chat_template
    KV pair) and forcing a generic ChatML template breaks Llama 3 / Mistral /
    Gemma / DeepSeek / Phi / Qwen models. Use -OllamaTemplate to override.

.PARAMETER Source
    LM Studio (or other) model root. Default: %USERPROFILE%\.lmstudio\models

.PARAMETER Target
    One or more target tools. Accepts: Ollama, TextGenerationWebUI, KoboldCpp,
    LlamaCppServer, Jan, All. Default: Ollama.

.PARAMETER OllamaCatalog
    Folder where generated Modelfiles are stored.
    Default: %USERPROFILE%\.ollama\custom-models

.PARAMETER TextGenModelsDir
    text-generation-webui models directory, typically
    <textgen-install>\user_data\models

.PARAMETER KoboldCppExe
    Full path to koboldcpp.exe. Required for KoboldCpp target.

.PARAMETER LlamaCppDir
    Folder containing llama-server.exe. Required for LlamaCppServer target.

.PARAMETER JanDataDir
    Jan's data folder. Default: %APPDATA%\Jan\data

.PARAMETER LaunchScriptDir
    Where per-model .bat launchers are written for KoboldCpp / LlamaCppServer.
    Default: %USERPROFILE%\local-models-launch

.PARAMETER NamePrefix
    String prepended to every registered model name. Useful to namespace an
    import (e.g. "lmstudio-"). Default: empty.

.PARAMETER IncludeFilter
    Regex. Only GGUF files whose full path matches are considered.

.PARAMETER ExcludeFilter
    Regex. GGUF files whose full path matches are skipped. Default excludes
    vision projectors (mmproj), partial downloads, and non-first splits.

.PARAMETER OllamaTemplate
    Raw template string to inject into every Ollama Modelfile. Leave empty to
    rely on Ollama's GGUF autodetection (recommended).

.PARAMETER Force
    Re-register models that already exist. Overwrites links, Modelfiles and
    Ollama entries.

.PARAMETER LogPath
    Path to the log file. Default is a timestamped file under %TEMP%.

.EXAMPLE
    .\Sync-LocalModels.ps1 -Target Ollama

.EXAMPLE
    .\Sync-LocalModels.ps1 -Target Ollama,TextGenerationWebUI `
        -TextGenModelsDir 'D:\ai\textgen\user_data\models' -WhatIf

.EXAMPLE
    .\Sync-LocalModels.ps1 -Target All `
        -TextGenModelsDir 'D:\ai\textgen\user_data\models' `
        -KoboldCppExe 'D:\ai\koboldcpp\koboldcpp.exe' `
        -LlamaCppDir 'D:\ai\llama.cpp\bin' `
        -NamePrefix 'lms-' -Force

.NOTES
    Author: m4xx (Deepak Mistry) — template by Claude
    Tested on: PowerShell 5.1 / 7.x on Windows 11
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$Source = (Join-Path $env:USERPROFILE '.lmstudio\models'),

    [ValidateSet('Ollama', 'TextGenerationWebUI', 'KoboldCpp', 'LlamaCppServer', 'Jan', 'All')]
    [string[]]$Target = @('Ollama'),

    [string]$OllamaCatalog = (Join-Path $env:USERPROFILE '.ollama\custom-models'),
    [string]$TextGenModelsDir,
    [string]$KoboldCppExe,
    [string]$LlamaCppDir,
    [string]$JanDataDir = (Join-Path $env:APPDATA 'Jan\data'),

    [string]$LaunchScriptDir = (Join-Path $env:USERPROFILE 'local-models-launch'),

    [string]$NamePrefix = '',

    [string]$IncludeFilter,
    [string]$ExcludeFilter = '(mmproj|mm-proj)|\.(downloading|incomplete|partial)$',

    [string]$OllamaTemplate = '',

    [switch]$Force,

    [string]$LogPath = (Join-Path $env:TEMP "sync-local-models-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")
)

$ErrorActionPreference = 'Stop'
$script:Stats = [ordered]@{
    Discovered = 0
    Skipped    = 0
    Registered = 0
    Failed     = 0
    Targets    = @{}
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'DEBUG')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1,-5}] {2}" -f $stamp, $Level, $Message

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $color

    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Don't let logging failures kill the run
        Write-Host "  (log write failed: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
function Test-Prerequisites {
    [CmdletBinding()]
    param([string[]]$Targets)

    $ok = $true

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Log "Source directory not found: $Source" ERROR
        return $false
    }
    Write-Log "Source OK: $Source" OK

    $expand = if ($Targets -contains 'All') {
        @('Ollama', 'TextGenerationWebUI', 'KoboldCpp', 'LlamaCppServer', 'Jan')
    } else { $Targets }

    foreach ($t in $expand) {
        switch ($t) {
            'Ollama' {
                if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
                    Write-Log "Ollama not found in PATH. Install from https://ollama.com or remove 'Ollama' from -Target." ERROR
                    $ok = $false
                } else {
                    Write-Log "Ollama found: $((Get-Command ollama).Source)" OK
                }
            }
            'TextGenerationWebUI' {
                if (-not $TextGenModelsDir) {
                    Write-Log "TextGenerationWebUI target requires -TextGenModelsDir (e.g. D:\textgen\user_data\models)" ERROR
                    $ok = $false
                } elseif (-not (Test-Path -LiteralPath $TextGenModelsDir)) {
                    Write-Log "TextGenModelsDir does not exist: $TextGenModelsDir — will be created" WARN
                }
            }
            'KoboldCpp' {
                if (-not $KoboldCppExe) {
                    Write-Log "KoboldCpp target requires -KoboldCppExe (path to koboldcpp.exe)" ERROR
                    $ok = $false
                } elseif (-not (Test-Path -LiteralPath $KoboldCppExe)) {
                    Write-Log "KoboldCpp executable not found: $KoboldCppExe" ERROR
                    $ok = $false
                }
            }
            'LlamaCppServer' {
                if (-not $LlamaCppDir) {
                    Write-Log "LlamaCppServer target requires -LlamaCppDir (folder containing llama-server.exe)" ERROR
                    $ok = $false
                } else {
                    $srv = Join-Path $LlamaCppDir 'llama-server.exe'
                    if (-not (Test-Path -LiteralPath $srv)) {
                        Write-Log "llama-server.exe not found at $srv" ERROR
                        $ok = $false
                    }
                }
            }
            'Jan' {
                $janModels = Join-Path $JanDataDir 'llamacpp\models'
                if (-not (Test-Path -LiteralPath $janModels)) {
                    Write-Log "Jan model folder $janModels does not exist — will be created. Make sure Jan has been launched at least once." WARN
                }
            }
        }
    }
    return $ok
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------
function Get-GgufModels {
    [CmdletBinding()]
    param([string]$Root)

    Write-Log "Scanning for GGUF files under $Root ..."
    $all = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.gguf' -ErrorAction SilentlyContinue

    $results = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($f in $all) {
        $full = $f.FullName

        if ($IncludeFilter -and ($full -notmatch $IncludeFilter)) { continue }
        if ($ExcludeFilter -and ($full -match    $ExcludeFilter)) {
            Write-Log "Skip (ExcludeFilter): $($f.Name)" DEBUG
            continue
        }

        # Multi-part GGUFs: only register the first split; llama.cpp loads the rest.
        # Pattern: <base>-00001-of-000NN.gguf
        if ($f.Name -match '-(\d{5})-of-\d{5}\.gguf$') {
            if ([int]$Matches[1] -ne 1) {
                Write-Log "Skip (non-first split): $($f.Name)" DEBUG
                continue
            }
        }

        # Build a logical model id from the LM Studio publisher/model folder layout
        # .lmstudio\models\<publisher>\<model>\<file>.gguf
        $rel = $full.Substring($Root.Length).TrimStart('\', '/')
        $parts = $rel -split '[\\/]'
        $publisher = if ($parts.Count -ge 3) { $parts[0] } else { '' }
        $modelDir  = if ($parts.Count -ge 3) { $parts[1] } else { [IO.Path]::GetFileNameWithoutExtension($f.Name) }
        $baseName  = [IO.Path]::GetFileNameWithoutExtension($f.Name)

        $results.Add([pscustomobject]@{
            FullPath  = $full
            FileName  = $f.Name
            BaseName  = $baseName
            Size      = $f.Length
            Publisher = $publisher
            ModelDir  = $modelDir
            Volume    = ([IO.Path]::GetPathRoot($full)).TrimEnd('\')
        }) | Out-Null
    }
    Write-Log "Discovery complete. $($results.Count) candidate GGUF file(s)." OK
    return $results
}

# ---------------------------------------------------------------------------
# Name sanitation
# ---------------------------------------------------------------------------
function Get-SafeOllamaName {
    param([string]$Raw)
    # Ollama allows: [a-zA-Z0-9._-] in name; lowercase by convention; max sensible length.
    $n = $Raw.ToLowerInvariant()
    $n = $n -replace '[^a-z0-9._-]', '-'
    $n = $n -replace '-+', '-'
    $n = $n.Trim('-', '.', '_')
    if ($n.Length -gt 120) { $n = $n.Substring(0, 120).TrimEnd('-', '.', '_') }
    if ([string]::IsNullOrWhiteSpace($n)) { $n = 'model' }
    return $n
}

# ---------------------------------------------------------------------------
# Linking helpers
# ---------------------------------------------------------------------------
function New-ModelLink {
    <#
      Creates a hardlink in $DestDir pointing at $SourceFile (same filename).
      Falls back to SymbolicLink if on a different volume.
      Returns the link path or $null on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$DestDir,
        [string]$NewName
    )
    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    $fileName = if ($NewName) { $NewName } else { Split-Path -Leaf $SourceFile }
    $dest = Join-Path $DestDir $fileName

    if (Test-Path -LiteralPath $dest) {
        if ($Force) {
            Remove-Item -LiteralPath $dest -Force
        } else {
            Write-Log "Link/file already present: $dest (use -Force to replace)" DEBUG
            return $dest
        }
    }

    $srcVol = ([IO.Path]::GetPathRoot($SourceFile)).TrimEnd('\')
    $dstVol = ([IO.Path]::GetPathRoot($dest)).TrimEnd('\')

    try {
        if ($srcVol -ieq $dstVol) {
            # Hardlink: no admin needed, zero storage.
            New-Item -ItemType HardLink -Path $dest -Value $SourceFile -ErrorAction Stop | Out-Null
            Write-Log "Hardlinked -> $dest" DEBUG
        } else {
            # Cross-volume: need a symlink. Requires admin or Developer Mode.
            New-Item -ItemType SymbolicLink -Path $dest -Value $SourceFile -ErrorAction Stop | Out-Null
            Write-Log "Symlinked (cross-volume) -> $dest" DEBUG
        }
        return $dest
    } catch {
        Write-Log "Failed to link $SourceFile -> $dest : $($_.Exception.Message)" ERROR
        Write-Log "Hint: cross-volume links require Windows Developer Mode or running elevated." WARN
        return $null
    }
}

# ---------------------------------------------------------------------------
# Target: Ollama
# ---------------------------------------------------------------------------
function Test-OllamaHasModel {
    param([string]$Name)
    try {
        $list = & ollama list 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        return ($list | Select-String -Pattern "^\s*$([regex]::Escape($Name))(?::|\s)" -Quiet)
    } catch { return $false }
}

function Register-OllamaModel {
    [CmdletBinding(SupportsShouldProcess)]
    param([pscustomobject]$Model)

    $name = Get-SafeOllamaName ("$NamePrefix$($Model.BaseName)")

    if ((Test-OllamaHasModel -Name $name) -and -not $Force) {
        Write-Log "Ollama already has '$name' — skip" WARN
        return @{ Status = 'Skipped'; Name = $name }
    }

    $mfPath = Join-Path $OllamaCatalog "$name.Modelfile"
    if (-not (Test-Path -LiteralPath $OllamaCatalog)) {
        New-Item -ItemType Directory -Path $OllamaCatalog -Force | Out-Null
    }

    # Minimal Modelfile — path quoted to survive spaces. Let Ollama autodetect
    # the template from GGUF metadata (tokenizer.chat_template KV).
    $lines = @()
    $lines += "# Auto-generated $(Get-Date -Format s)"
    $lines += "# Source: $($Model.FullPath)"
    $lines += ('FROM "{0}"' -f $Model.FullPath)
    $lines += 'PARAMETER temperature 0.7'
    $lines += 'PARAMETER top_p 0.9'
    $lines += 'PARAMETER repeat_penalty 1.1'
    if ($OllamaTemplate) {
        $lines += ''
        $lines += 'TEMPLATE """' + $OllamaTemplate + '"""'
    }

    if ($PSCmdlet.ShouldProcess($name, "write Modelfile and ollama create")) {
        Set-Content -LiteralPath $mfPath -Value ($lines -join "`r`n") -Encoding UTF8

        # Run ollama create and capture both streams
        $out = & ollama create $name -f $mfPath 2>&1
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
            Write-Log "ollama create '$name' failed (exit $exit):`n$($out -join "`n")" ERROR
            return @{ Status = 'Failed'; Name = $name }
        }
        Write-Log "Ollama registered: $name" OK
        return @{ Status = 'Registered'; Name = $name }
    } else {
        return @{ Status = 'Planned'; Name = $name }
    }
}

# ---------------------------------------------------------------------------
# Target: text-generation-webui (oobabooga)
# ---------------------------------------------------------------------------
function Register-TextGenModel {
    [CmdletBinding(SupportsShouldProcess)]
    param([pscustomobject]$Model)

    $linkName = if ($NamePrefix) { "$NamePrefix$($Model.FileName)" } else { $Model.FileName }

    if ($PSCmdlet.ShouldProcess($linkName, "link into text-generation-webui/user_data/models")) {
        $dest = New-ModelLink -SourceFile $Model.FullPath -DestDir $TextGenModelsDir -NewName $linkName
        if ($dest) {
            Write-Log "text-generation-webui: $linkName" OK
            return @{ Status = 'Registered'; Name = $linkName }
        }
        return @{ Status = 'Failed'; Name = $linkName }
    }
    return @{ Status = 'Planned'; Name = $linkName }
}

# ---------------------------------------------------------------------------
# Target: Jan
# ---------------------------------------------------------------------------
function Register-JanModel {
    [CmdletBinding(SupportsShouldProcess)]
    param([pscustomobject]$Model)

    $janModels = Join-Path $JanDataDir 'llamacpp\models'
    $folderName = Get-SafeOllamaName ("$NamePrefix$($Model.ModelDir)")
    $modelFolder = Join-Path $janModels $folderName

    if ($PSCmdlet.ShouldProcess($folderName, "link GGUF into Jan models folder")) {
        $dest = New-ModelLink -SourceFile $Model.FullPath -DestDir $modelFolder -NewName $Model.FileName
        if (-not $dest) {
            return @{ Status = 'Failed'; Name = $folderName }
        }

        # Jan will pick it up on next import; we write a small marker so the
        # user can see what's there. Jan's own model.json is generated on its
        # first scan / import.
        $marker = Join-Path $modelFolder 'README-synced.txt'
        $readme = @(
            "Model linked by Sync-LocalModels.ps1 on $(Get-Date -Format s)",
            "Source: $($Model.FullPath)",
            "",
            "Open Jan -> Settings -> Model Providers -> llama.cpp -> Import",
            "and point at $dest (or restart Jan — it scans this folder)."
        ) -join "`r`n"
        Set-Content -LiteralPath $marker -Value $readme -Encoding UTF8
        Write-Log "Jan: $folderName" OK
        return @{ Status = 'Registered'; Name = $folderName }
    }
    return @{ Status = 'Planned'; Name = $folderName }
}

# ---------------------------------------------------------------------------
# Targets: KoboldCpp / llama-server launcher .bat files
# ---------------------------------------------------------------------------
function New-LauncherBat {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [pscustomobject]$Model,
        [ValidateSet('KoboldCpp', 'LlamaCppServer')][string]$Kind
    )

    if (-not (Test-Path -LiteralPath $LaunchScriptDir)) {
        New-Item -ItemType Directory -Path $LaunchScriptDir -Force | Out-Null
    }

    $safe = Get-SafeOllamaName ("$NamePrefix$($Model.BaseName)")
    $bat = Join-Path $LaunchScriptDir ("{0}-{1}.bat" -f $Kind.ToLower(), $safe)

    $content = switch ($Kind) {
        'KoboldCpp' {
@"
@echo off
REM Auto-generated launcher for $($Model.FileName)
REM Generated $(Get-Date -Format s)
"$KoboldCppExe" --model "$($Model.FullPath)" --gpulayers 999 --contextsize 8192 %*
"@
        }
        'LlamaCppServer' {
            $srv = Join-Path $LlamaCppDir 'llama-server.exe'
@"
@echo off
REM Auto-generated launcher for $($Model.FileName)
REM Generated $(Get-Date -Format s)
"$srv" -m "$($Model.FullPath)" -c 8192 -ngl 999 --host 127.0.0.1 --port 8080 %*
"@
        }
    }

    if ($PSCmdlet.ShouldProcess($bat, "write launcher")) {
        if ((Test-Path -LiteralPath $bat) -and -not $Force) {
            Write-Log "$Kind launcher exists: $bat (use -Force to overwrite)" DEBUG
            return @{ Status = 'Skipped'; Name = $safe }
        }
        Set-Content -LiteralPath $bat -Value $content -Encoding ASCII
        Write-Log "$Kind launcher: $bat" OK
        return @{ Status = 'Registered'; Name = $safe }
    }
    return @{ Status = 'Planned'; Name = $safe }
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------
function Invoke-Sync {
    $targets = if ($Target -contains 'All') {
        @('Ollama', 'TextGenerationWebUI', 'KoboldCpp', 'LlamaCppServer', 'Jan')
    } else { $Target }

    # Only the ones that are actually configured
    $targets = $targets | Where-Object {
        switch ($_) {
            'Ollama'              { $true }
            'TextGenerationWebUI' { [bool]$TextGenModelsDir }
            'KoboldCpp'           { [bool]$KoboldCppExe }
            'LlamaCppServer'      { [bool]$LlamaCppDir }
            'Jan'                 { $true }
        }
    }

    Write-Log "Active targets: $($targets -join ', ')"
    foreach ($t in $targets) { $script:Stats.Targets[$t] = @{ Registered = 0; Skipped = 0; Failed = 0 } }

    $models = Get-GgufModels -Root $Source
    $script:Stats.Discovered = $models.Count
    if ($models.Count -eq 0) {
        Write-Log "No GGUF models found under $Source." WARN
        return
    }

    $i = 0
    foreach ($m in $models) {
        $i++
        $pct = [int](($i / $models.Count) * 100)
        Write-Progress -Activity "Syncing models" -Status "$i / $($models.Count) — $($m.FileName)" -PercentComplete $pct
        Write-Log ("[{0}/{1}] {2}  ({3:N1} MiB)" -f $i, $models.Count, $m.FileName, ($m.Size / 1MB))

        foreach ($t in $targets) {
            try {
                $r = switch ($t) {
                    'Ollama'              { Register-OllamaModel -Model $m }
                    'TextGenerationWebUI' { Register-TextGenModel -Model $m }
                    'KoboldCpp'           { New-LauncherBat       -Model $m -Kind KoboldCpp }
                    'LlamaCppServer'      { New-LauncherBat       -Model $m -Kind LlamaCppServer }
                    'Jan'                 { Register-JanModel     -Model $m }
                }
                switch ($r.Status) {
                    'Registered' { $script:Stats.Targets[$t].Registered++; $script:Stats.Registered++ }
                    'Skipped'    { $script:Stats.Targets[$t].Skipped++;    $script:Stats.Skipped++ }
                    'Failed'     { $script:Stats.Targets[$t].Failed++;     $script:Stats.Failed++ }
                    'Planned'    { } # dry-run
                }
            } catch {
                Write-Log "Unhandled error registering $($m.FileName) with $t : $($_.Exception.Message)" ERROR
                $script:Stats.Targets[$t].Failed++
                $script:Stats.Failed++
            }
        }
    }
    Write-Progress -Activity "Syncing models" -Completed
}

function Write-Summary {
    Write-Host ''
    Write-Log ('=' * 60)
    Write-Log 'SUMMARY'
    Write-Log ('-' * 60)
    Write-Log ("GGUF files discovered: {0}" -f $script:Stats.Discovered)
    Write-Log ("Total registered:      {0}" -f $script:Stats.Registered) OK
    Write-Log ("Total skipped:         {0}" -f $script:Stats.Skipped)    WARN
    Write-Log ("Total failed:          {0}" -f $script:Stats.Failed) $(if ($script:Stats.Failed) { 'ERROR' } else { 'OK' })
    foreach ($t in $script:Stats.Targets.Keys) {
        $s = $script:Stats.Targets[$t]
        Write-Log ("  {0,-22} registered={1,-4} skipped={2,-4} failed={3}" -f $t, $s.Registered, $s.Skipped, $s.Failed)
    }
    Write-Log ('=' * 60)
    Write-Log "Log written to: $LogPath"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "Sync-LocalModels starting"
Write-Log "PowerShell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.VersionString)"

if (-not (Test-Prerequisites -Targets $Target)) {
    Write-Log "Prerequisite check failed. Aborting." ERROR
    Write-Summary
    exit 1
}

try {
    Invoke-Sync
} catch {
    Write-Log "Fatal error: $($_.Exception.Message)" ERROR
    Write-Log $_.ScriptStackTrace DEBUG
    Write-Summary
    exit 2
}

Write-Summary
exit $(if ($script:Stats.Failed -gt 0) { 1 } else { 0 })
