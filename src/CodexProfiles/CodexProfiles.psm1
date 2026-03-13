Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-CodexProfileKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName
    )

    $key = $ProfileName.Trim().ToLowerInvariant()
    if (-not $key) {
        throw 'ProfileName cannot be empty.'
    }

    $key = [regex]::Replace($key, '[^a-z0-9]+', '-')
    $key = $key.Trim('-')

    if (-not $key) {
        throw "ProfileName '$ProfileName' does not contain any usable characters."
    }

    return $key
}

function Expand-CodexProfileNames {
    [CmdletBinding()]
    param(
        [string[]]$ProfileName
    )

    $expanded = foreach ($value in $ProfileName) {
        if ($null -eq $value) {
            continue
        }

        foreach ($segment in ($value -split ',')) {
            $trimmed = $segment.Trim()
            if ($trimmed) {
                $trimmed
            }
        }
    }

    if (-not $expanded) {
        throw 'At least one profile name is required.'
    }

    return $expanded
}

function Get-CodexDesktopPackage {
    [CmdletBinding()]
    param()

    $package = Get-AppxPackage OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $package) {
        throw 'OpenAI.Codex MS Store package not found. Install Codex from the Microsoft Store first.'
    }

    $appDirectory = Join-Path $package.InstallLocation 'app'
    $exePath = Join-Path $appDirectory 'Codex.exe'
    if (-not (Test-Path $exePath)) {
        throw "Codex desktop executable not found: $exePath"
    }

    [pscustomobject]@{
        Package = $package
        Version = $package.Version.ToString()
        AppDirectory = $appDirectory
        ExePath = $exePath
    }
}

function Resolve-NpxCommand {
    [CmdletBinding()]
    param()

    $command = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command npx -ErrorAction SilentlyContinue
    }

    if (-not $command) {
        throw 'Unable to find npx. Install Node.js if you want to enable the common MCP defaults.'
    }

    return $command.Source
}

function Get-CodexProfilePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop')
    )

    $profileKey = ConvertTo-CodexProfileKey -ProfileName $ProfileName

    [pscustomobject]@{
        ProfileName = $ProfileName
        ProfileKey = $profileKey
        Home = Join-Path $ProfilesRoot $profileKey
        UiData = Join-Path (Join-Path $ParallelRoot 'ui') $profileKey
        ParallelRoot = $ParallelRoot
    }
}

function Ensure-CodexDesktopClone {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        $PackageInfo,

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop'),

        [switch]$ForceRefresh
    )

    $versionsRoot = Join-Path $ParallelRoot 'versions'
    $cloneRoot = Join-Path $versionsRoot $PackageInfo.Version
    $cloneAppDirectory = Join-Path $cloneRoot 'app'
    $cloneExe = Join-Path $cloneAppDirectory 'Codex.exe'

    if ((-not $ForceRefresh) -and (Test-Path $cloneExe)) {
        return $cloneExe
    }

    if ($PSCmdlet.ShouldProcess($cloneAppDirectory, 'Clone Codex desktop binaries')) {
        New-Item -ItemType Directory -Force -Path $cloneAppDirectory | Out-Null
        & robocopy.exe $PackageInfo.AppDirectory $cloneAppDirectory /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
        $robocopyExit = $LASTEXITCODE
        if ($robocopyExit -gt 7) {
            throw "Failed to clone Codex desktop app (robocopy exit code $robocopyExit)."
        }
    }

    if (-not (Test-Path $cloneExe)) {
        throw "Cloned Codex executable not found: $cloneExe"
    }

    return $cloneExe
}

function Clear-CodexDesktopInheritedEnv {
    [CmdletBinding()]
    param()

    $varsToRemove = @(
        'OPENAI_BASE_URL',
        'OPENAI_API_KEY',
        'OPENAI_ORG_ID',
        'OPENAI_PROJECT_ID',
        'ANTHROPIC_BASE_URL',
        'ANTHROPIC_API_KEY',
        'ANTHROPIC_AUTH_TOKEN',
        'CODEX_THREAD_ID'
    )

    foreach ($name in $varsToRemove) {
        Remove-Item -Path ("Env:$name") -ErrorAction SilentlyContinue
    }
}

function Get-CodexProfileConfigContent {
    [CmdletBinding()]
    param(
        [switch]$EnableCommonMcp
    )

    $lines = @(
        "forced_login_method = 'chatgpt'",
        "model_provider = 'openai'",
        '',
        '[windows]',
        'sandbox = "elevated"'
    )

    if ($EnableCommonMcp) {
        $npxPath = Resolve-NpxCommand
        $programFiles = [Environment]::GetFolderPath('ProgramFiles')
        $systemRoot = $env:SystemRoot

        $lines += @(
            '',
            '[mcp_servers.playwright]',
            "command = '$npxPath'",
            'args = ["-y", "@playwright/mcp@latest"]',
            '',
            '[mcp_servers.chrome-devtools]',
            "command = '$npxPath'",
            'args = ["-y", "chrome-devtools-mcp@latest"]',
            '',
            '[mcp_servers.chrome-devtools.env]',
            "CI = '1'",
            "CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS = '1'",
            "PROGRAMFILES = '$programFiles'",
            "SystemRoot = '$systemRoot'",
            '',
            '[mcp_servers.context7]',
            "command = '$npxPath'",
            'args = ["-y", "@upstash/context7-mcp"]'
        )
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Write-CodexProfileConfig {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [switch]$EnableCommonMcp,

        [switch]$OverwriteConfig
    )

    if ((Test-Path $ConfigPath) -and (-not $OverwriteConfig)) {
        return
    }

    $content = Get-CodexProfileConfigContent -EnableCommonMcp:$EnableCommonMcp
    if ($PSCmdlet.ShouldProcess($ConfigPath, 'Write profile config')) {
        $parent = Split-Path -Path $ConfigPath -Parent
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        Set-Content -Path $ConfigPath -Value $content -Encoding UTF8
    }
}

function New-CodexDesktopShortcut {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutPath,

        [Parameter(Mandatory = $true)]
        [string]$LauncherScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [string]$IconPath
    )

    $targetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProfileName "{1}" -DisplayName "{2}"' -f $LauncherScriptPath, $ProfileName, $DisplayName

    if ($PSCmdlet.ShouldProcess($ShortcutPath, 'Create shortcut')) {
        $shortcutDirectory = Split-Path -Path $ShortcutPath -Parent
        New-Item -ItemType Directory -Force -Path $shortcutDirectory | Out-Null

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $targetPath
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = Split-Path -Path $LauncherScriptPath -Parent
        $shortcut.WindowStyle = 1
        $shortcut.Description = $DisplayName
        if ($IconPath) {
            $shortcut.IconLocation = $IconPath
        }
        $shortcut.Save()
    }
}

function New-CodexDesktopProfile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [string]$DisplayName,

        [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop'),

        [switch]$EnableCommonMcp,

        [switch]$OverwriteConfig,

        [switch]$CreateDesktopShortcut,

        [switch]$CreateStartMenuShortcut,

        [string]$LauncherScriptPath,

        [switch]$ForceRefreshClone
    )

    $paths = Get-CodexProfilePaths -ProfileName $ProfileName -ProfilesRoot $ProfilesRoot -ParallelRoot $ParallelRoot
    if (-not $DisplayName) {
        $DisplayName = 'Codex ' + (Get-Culture).TextInfo.ToTitleCase($paths.ProfileKey)
    }

    if ($PSCmdlet.ShouldProcess($paths.Home, 'Create isolated profile directories')) {
        New-Item -ItemType Directory -Force -Path $paths.Home | Out-Null
        New-Item -ItemType Directory -Force -Path $paths.UiData | Out-Null
    }

    $configPath = Join-Path $paths.Home 'config.toml'
    Write-CodexProfileConfig -ConfigPath $configPath -EnableCommonMcp:$EnableCommonMcp -OverwriteConfig:$OverwriteConfig -WhatIf:$WhatIfPreference

    $packageInfo = Get-CodexDesktopPackage
    $cloneExe = Ensure-CodexDesktopClone -PackageInfo $packageInfo -ParallelRoot $ParallelRoot -ForceRefresh:$ForceRefreshClone -WhatIf:$WhatIfPreference

    if ($LauncherScriptPath) {
        $launcherFullPath = (Resolve-Path $LauncherScriptPath).Path
        if ($CreateDesktopShortcut) {
            $desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) ("$DisplayName.lnk")
            New-CodexDesktopShortcut -ShortcutPath $desktopShortcut -LauncherScriptPath $launcherFullPath -ProfileName $ProfileName -DisplayName $DisplayName -IconPath $cloneExe -WhatIf:$WhatIfPreference
        }

        if ($CreateStartMenuShortcut) {
            $startMenuDirectory = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Codex Profiles'
            $startMenuShortcut = Join-Path $startMenuDirectory ("$DisplayName.lnk")
            New-CodexDesktopShortcut -ShortcutPath $startMenuShortcut -LauncherScriptPath $launcherFullPath -ProfileName $ProfileName -DisplayName $DisplayName -IconPath $cloneExe -WhatIf:$WhatIfPreference
        }
    }

    [pscustomobject]@{
        ProfileName = $ProfileName
        DisplayName = $DisplayName
        ProfileKey = $paths.ProfileKey
        Home = $paths.Home
        UiData = $paths.UiData
        ConfigPath = $configPath
        CloneExe = $cloneExe
    }
}

function Invoke-CodexDesktopLaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CloneExe,

        [Parameter(Mandatory = $true)]
        [string]$ProfileHome,

        [Parameter(Mandatory = $true)]
        [string]$UiData,

        [string[]]$AdditionalArguments,

        [switch]$PassThru
    )

    $saved = @{}
    foreach ($name in @('OPENAI_BASE_URL','OPENAI_API_KEY','OPENAI_ORG_ID','OPENAI_PROJECT_ID','ANTHROPIC_BASE_URL','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CODEX_THREAD_ID','CODEX_HOME')) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        Clear-CodexDesktopInheritedEnv
        $env:CODEX_HOME = $ProfileHome

        $arguments = @("--user-data-dir=$UiData")
        if ($AdditionalArguments) {
            $arguments += $AdditionalArguments
        }

        if ($PassThru) {
            return Start-Process -FilePath $CloneExe -WorkingDirectory (Split-Path $CloneExe) -ArgumentList $arguments -PassThru
        }

        Start-Process -FilePath $CloneExe -WorkingDirectory (Split-Path $CloneExe) -ArgumentList $arguments | Out-Null
    }
    finally {
        foreach ($entry in $saved.GetEnumerator()) {
            if ($null -eq $entry.Value) {
                Remove-Item -Path ("Env:$($entry.Key)") -ErrorAction SilentlyContinue
            }
            else {
                Set-Item -Path ("Env:$($entry.Key)") -Value $entry.Value
            }
        }
    }
}

function Start-CodexDesktopProfile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [string]$DisplayName,

        [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop'),

        [switch]$EnableCommonMcp,

        [switch]$OverwriteConfig,

        [switch]$ForceRefreshClone,

        [string[]]$AdditionalArguments,

        [switch]$PassThru
    )

    $profile = New-CodexDesktopProfile -ProfileName $ProfileName -DisplayName $DisplayName -ProfilesRoot $ProfilesRoot -ParallelRoot $ParallelRoot -EnableCommonMcp:$EnableCommonMcp -OverwriteConfig:$OverwriteConfig -ForceRefreshClone:$ForceRefreshClone -WhatIf:$WhatIfPreference

    if ($PSCmdlet.ShouldProcess($profile.DisplayName, 'Launch isolated Codex desktop profile')) {
        $process = Invoke-CodexDesktopLaunch -CloneExe $profile.CloneExe -ProfileHome $profile.Home -UiData $profile.UiData -AdditionalArguments $AdditionalArguments -PassThru:$PassThru
        if ($PassThru) {
            return [pscustomobject]@{
                ProfileName = $profile.ProfileName
                DisplayName = $profile.DisplayName
                Home = $profile.Home
                UiData = $profile.UiData
                CloneExe = $profile.CloneExe
                Process = $process
            }
        }
    }

    return $profile
}

function Install-CodexDesktopProfiles {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string[]]$ProfileName = @('alpha', 'bloom', 'apex', 'prime', 'flow', 'turbo', 'sonic', 'nova'),

        [switch]$EnableCommonMcp,

        [switch]$OverwriteConfig,

        [switch]$CreateDesktopShortcuts,

        [switch]$CreateStartMenuShortcuts,

        [string]$LauncherScriptPath,

        [switch]$ForceRefreshClone
    )

    $profileNames = Expand-CodexProfileNames -ProfileName $ProfileName

    $results = foreach ($name in $profileNames) {
        $displayName = 'Codex ' + (Get-Culture).TextInfo.ToTitleCase((ConvertTo-CodexProfileKey -ProfileName $name))
        New-CodexDesktopProfile -ProfileName $name -DisplayName $displayName -EnableCommonMcp:$EnableCommonMcp -OverwriteConfig:$OverwriteConfig -CreateDesktopShortcut:$CreateDesktopShortcuts -CreateStartMenuShortcut:$CreateStartMenuShortcuts -LauncherScriptPath $LauncherScriptPath -ForceRefreshClone:$ForceRefreshClone -WhatIf:$WhatIfPreference
    }

    return $results
}

Export-ModuleMember -Function Get-CodexProfilePaths, New-CodexDesktopProfile, Start-CodexDesktopProfile, Install-CodexDesktopProfiles
