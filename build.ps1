param
(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Command
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$targetName = (Get-ChildItem -Path "$PSScriptRoot\src" -Recurse -Filter *.csproj | select -First 1).Basename
$distDir = "$PSScriptRoot\dist"
$script:installDir = ""

function SetInstallDir
{
    if (![string]::IsNullOrEmpty($script:installDir))
    {
        return
    } 

    Write-Host "Looking for RimWorld installation..."
    $script:installDirs = @(
        "$(${Env:ProgramFiles(x86)})\Steam\SteamApps\common\RimWorld"
        "$(${Env:ProgramFiles})\Steam\SteamApps\common\RimWorld"
        "F:\Games\SteamLibrary\steamapps\common\RimWorld"
        ) 

    foreach ($dir in $script:installDirs) {
        Write-Host " -  Checking $dir"
        if (Test-Path $dir)
        {
            Write-Host " -> Found RimWorld Path: $dir"
            $script:installDir =  $dir
            return
        }
    }
 
    Write-Host " -> RimWorld not found"
    return $null
}


function removePath($path)
{
    while ($true)
    {
        if (!(Test-Path $path))
        {
            return
        }

        Write-Host "Deleting $path"
        try
        {
            Remove-Item -Recurse $path
            break
        }
        catch
        {
            Write-Host "Could not remove $path, will retry"
            Start-Sleep 3
        }
    }
}

function getProjectDir
{
    return "$PSScriptRoot\src\$targetName"
}

$assemblyInfoFile = "$(getProjectDir)\properties\AssemblyInfo.cs"

function getGameVersion
{
    $gameVersionFile = "$script:installDir\Version.txt"
    $gameVersionWithRev = Get-Content $gameVersionFile
    $version = [version] ($gameVersionWithRev.Split(" "))[0]

    return "$($version.Major).$($version.Minor)"
}

function updateToGameVersion
{

    SetInstallDir
    if ([string]::IsNullOrEmpty($script:installDir))
    {
    Write-Host -ForegroundColor Red `
        "Rimworld installation not found; not setting game version."

    return
    }


    $gameVersion = getGameVersion

    $content = Get-Content -Raw $assemblyInfoFile
    $newContent = $content -replace '"\d+\.\d+(\.\d+\.\d+")', "`"$gameVersion`$1"

    if ($newContent -eq $content)
    {
        return
    }
    Set-Content -Encoding UTF8 -Path $assemblyInfoFile $newContent
}

function copyFilesToRimworld
{
    SetInstallDir
    if ([string]::IsNullOrEmpty($script:installDir))
    {
    Write-Host -ForegroundColor Yellow `
        "No Steam installation found, build will not be published"

    return
    }

    $modsDir = "$script:installDir\Mods"
    $modDir = "$modsDir\$targetName"
    removePath $modDir

    Write-Host "Copying mod to $modDir"
    Copy-Item -Recurse -Force -Exclude *.zip "$distDir\*" $modsDir
}

function copyDependencies
{
    $thirdpartyDir = "$PSScriptRoot\ThirdParty"
    if (Test-Path "$thirdpartyDir\*.dll")
    {
        return
    }

    SetInstallDir
    if ([string]::IsNullOrEmpty($script:installDir))
    {
    Write-Host -ForegroundColor Yellow `
        "Rimworld installation not found; see Readme for how to set up pre-requisites manually."

    return
    }

    $depsDir = "$script:installDir\RimWorldWin64_Data\Managed"
    Write-Host "Copying dependencies from installation directory"
    if (!(Test-Path $thirdpartyDir)) { mkdir $thirdpartyDir | Out-Null }
    Copy-Item -Force "$depsDir\Unity*.dll" "$thirdpartyDir\"
    Copy-Item -Force "$depsDir\Assembly-CSharp.dll" "$thirdpartyDir\"
}

function doPreBuild
{
    Write-Host "doPreBuild"
    removePath $distDir
    copyDependencies
    updateToGameVersion
}

function doPostBuild
{
    param(
        [string]$VSConfiguration = "Release"
    )
    Write-Host "doPostBuild"

    SetInstallDir
    if ([string]::IsNullOrEmpty($script:installDir))
    {
    Write-Host -ForegroundColor Red `
        "Rimworld installation not found; not setting game version."

    return
    }


    $distTargetDir = "$distDir\$targetName"
    removePath $distDir

    $targetDir = "$(getProjectDir)\bin\Release"
    $targetPath = "$targetDir\$targetName.dll"

    $distAssemblyDir = "$distTargetDir\$(getGameVersion)\Assemblies"
    mkdir $distAssemblyDir | Out-Null

    Copy-Item -Recurse -Force "$PSScriptRoot\mod-structure\*" $distTargetDir -Exclude "About-Debug.xml"
    Copy-Item -Force $targetPath $distAssemblyDir

    if ($VSConfiguration = "Debug"){
        $AboutFilePath = "$distTargetDir\About\About.xml"
        Copy-Item -Force "$PSScriptRoot\mod-structure\About\About-Debug.xml" $AboutFilePath
        $filePath = "C:\path\to\your\file.txt"

        # Get the current timestamp in the desired format
        $timestamp = Get-Date -Format "HH:mm - dd.MM.yyyy"

        # Read the file content
        $content = Get-Content -Path $AboutFilePath -Raw

        # Replace "TIMESTAMP" with the actual timestamp
        $updatedContent = $content -replace "TIMESTAMP", $timestamp

        # Write the updated content back to the file
        Set-Content -Path $AboutFilePath -Value $updatedContent

        Write-Host "About file updated successfully."
    }

    $modStructureAssemblyLocation = "$PSScriptRoot\mod-structure\$(getGameVersion)\Assemblies"
    if (!(Test-Path $modStructureAssemblyLocation))
    {
        mkdir $modStructureAssemblyLocation | Out-Null
    }
    Copy-Item -Force $targetPath $modStructureAssemblyLocation

    Write-Host "Creating distro package"
    $content = Get-Content -Raw $assemblyInfoFile
    if (!($content -match '"(\d+\.\d+\.\d+\.\d+)"'))
    {
        throw "Version info not found in $assemblyInfoFile"
    }

    $version = $matches[1]
    $distZip = "$distDir\$targetName.$version.zip"
    removePath $distZip
    $sevenZip = "$PSScriptRoot\7z.exe"
    & $sevenZip a -mx=9 "$distZip" "$distDir\*"
    if ($LASTEXITCODE -ne 0)
    {
        throw "7zip command failed"
    }

    Write-Host "Created $distZip"

    copyFilesToRimworld
}

& $Command