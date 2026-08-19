<#
.SYNOPSIS
Creates a new rework version with the original slide's fixed template chrome pixel-locked in place.

.DESCRIPTION
The tool is intentionally fail-closed and non-destructive:

- An explicit slide list is always required.
- Exactly one of -DryRun or -Apply is always required.
- Crop geometry is read only from
  02_triage/criteria.json -> reworkContract.templateChrome.regions.
- The required region IDs are top-header and right-rail. There is no geometry fallback.
- The current version and original reference are never modified.
- Applying creates the next v###.png plus an exact v###-source.png snapshot of the
  version it was derived from, then appends lineage to 04_rework/manifest.json.
- Approved/currently internal-rejected versions are refused.

This script uses System.Drawing because the repository has no image package dependency and
the existing Windows image scripts use the same runtime. Source and destination geometry are
identical, and each reference crop is copied with DrawImageUnscaled.

.EXAMPLE
./scripts/repair-template-chrome.ps1 `
  -JobRoot ./jobs/sample-project `
  -Slides 13,14,57 `
  -DryRun

.EXAMPLE
./scripts/repair-template-chrome.ps1 `
  -JobRoot ./jobs/sample-project `
  -Slides 13,14,57 `
  -Apply
#>

[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [int[]]$Slides,

    [Parameter(Mandatory = $true, ParameterSetName = 'DryRun')]
    [switch]$DryRun,

    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$requiredWidth = 1920
$requiredHeight = 1080
$criteriaRelativePath = '02_triage/criteria.json'
$inventoryRelativePath = '01_inventory/slides.json'
$manifestRelativePath = '04_rework/manifest.json'
$toolRelativePath = 'scripts/repair-template-chrome.ps1'

function Read-Utf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }

    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        return $text | ConvertFrom-Json
    }
    catch {
        throw "$Label is not valid UTF-8 JSON: $Path`n$($_.Exception.Message)"
    }
}

function Get-JobPath {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedJobRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw 'A job-relative path is empty.'
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Expected a job-relative path, got: $RelativePath"
    }

    $nativeRelativePath = $RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $ResolvedJobRoot $nativeRelativePath))
    $rootPrefix = $ResolvedJobRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Job-relative path escapes the job root: $RelativePath"
    }
    return $candidate
}

function Get-RequiredRegionInteger {
    param(
        [Parameter(Mandatory = $true)]$Region,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$RegionId
    )

    $property = $Region.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or $null -eq $property.Value -or $property.Value -is [bool]) {
        throw "Template chrome region '$RegionId' requires integer '$PropertyName'."
    }

    try {
        $integerValue = [int]$property.Value
        $numericValue = [double]$property.Value
    }
    catch {
        throw "Template chrome region '$RegionId' has invalid integer '$PropertyName'."
    }

    if ([double]$integerValue -ne $numericValue) {
        throw "Template chrome region '$RegionId' has non-integer '$PropertyName'."
    }
    return $integerValue
}

function Get-ImageDimensions {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Image not found: $Path"
    }

    $image = [System.Drawing.Image]::FromFile($Path)
    try {
        return [pscustomobject]@{
            Width = [int]$image.Width
            Height = [int]$image.Height
        }
    }
    finally {
        $image.Dispose()
    }
}

function New-ChromeLockedImage {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][object[]]$Regions
    )

    $base = [System.Drawing.Bitmap]::FromFile($BasePath)
    $reference = [System.Drawing.Bitmap]::FromFile($ReferencePath)
    $canvas = $null
    $graphics = $null

    try {
        $canvas = New-Object System.Drawing.Bitmap(
            $base.Width,
            $base.Height,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.DrawImageUnscaled($base, 0, 0)

        foreach ($region in $Regions) {
            $rectangle = New-Object System.Drawing.Rectangle(
                [int]$region.x,
                [int]$region.y,
                [int]$region.width,
                [int]$region.height
            )
            $crop = $reference.Clone(
                $rectangle,
                [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
            )
            try {
                $graphics.DrawImageUnscaled($crop, [int]$region.x, [int]$region.y)
            }
            finally {
                $crop.Dispose()
            }
        }

        $canvas.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $canvas) { $canvas.Dispose() }
        $reference.Dispose()
        $base.Dispose()
    }
}

function Add-OrSetProperty {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($null -ne $Target.PSObject.Properties[$Name]) {
        $Target.$Name = $Value
    }
    else {
        $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Remove-ExactFileIfPresent {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $JobRoot -PathType Container)) {
    throw "Job root not found: $JobRoot"
}
$resolvedJobRoot = (Resolve-Path -LiteralPath $JobRoot).Path

$requestedSlides = @($Slides)
if ($requestedSlides.Count -eq 0) {
    throw 'At least one explicit slide number is required.'
}
$duplicates = @($requestedSlides | Group-Object | Where-Object { $_.Count -gt 1 })
if ($duplicates.Count -gt 0) {
    $duplicateList = ($duplicates | ForEach-Object { $_.Name }) -join ', '
    throw "Duplicate slide numbers are not allowed: $duplicateList"
}
$requestedSlides = @($requestedSlides | Sort-Object)

$criteriaPath = Get-JobPath -ResolvedJobRoot $resolvedJobRoot -RelativePath $criteriaRelativePath
$inventoryPath = Get-JobPath -ResolvedJobRoot $resolvedJobRoot -RelativePath $inventoryRelativePath
$manifestPath = Get-JobPath -ResolvedJobRoot $resolvedJobRoot -RelativePath $manifestRelativePath

$criteria = Read-Utf8Json -Path $criteriaPath -Label 'Triage criteria'
$inventory = Read-Utf8Json -Path $inventoryPath -Label 'Slide inventory'
$manifest = Read-Utf8Json -Path $manifestPath -Label 'Rework manifest'

$templateChrome = $criteria.reworkContract.templateChrome
if ($null -eq $templateChrome) {
    throw "Missing $criteriaRelativePath -> reworkContract.templateChrome. No crop fallback is permitted."
}
$rawRegions = @($templateChrome.regions)
if ($rawRegions.Count -ne 2) {
    throw 'reworkContract.templateChrome.regions must contain exactly top-header and right-rail.'
}

$regions = @()
foreach ($rawRegion in $rawRegions) {
    $regionId = [string]$rawRegion.id
    if ([string]::IsNullOrWhiteSpace($regionId)) {
        throw 'Every template chrome region requires an id.'
    }
    $regions += [pscustomobject][ordered]@{
        id = $regionId
        x = Get-RequiredRegionInteger -Region $rawRegion -PropertyName 'x' -RegionId $regionId
        y = Get-RequiredRegionInteger -Region $rawRegion -PropertyName 'y' -RegionId $regionId
        width = Get-RequiredRegionInteger -Region $rawRegion -PropertyName 'width' -RegionId $regionId
        height = Get-RequiredRegionInteger -Region $rawRegion -PropertyName 'height' -RegionId $regionId
    }
}

$regionIds = @($regions | ForEach-Object { $_.id })
foreach ($requiredRegionId in @('top-header', 'right-rail')) {
    if ($regionIds -notcontains $requiredRegionId) {
        throw "Missing required template chrome region id '$requiredRegionId'. No alias or fallback is used."
    }
}
if (@($regionIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
    throw 'Template chrome region IDs must be unique.'
}

$topHeader = @($regions | Where-Object { $_.id -eq 'top-header' })[0]
$rightRail = @($regions | Where-Object { $_.id -eq 'right-rail' })[0]
if (
    $topHeader.x -ne 0 -or
    $topHeader.y -ne 0 -or
    $topHeader.width -ne $requiredWidth -or
    $topHeader.height -le 0 -or
    $topHeader.height -gt $requiredHeight
) {
    throw "Configured top-header must start at (0,0), span the full $requiredWidth px width, and stay within the canvas."
}
if (
    $rightRail.x -lt 0 -or
    $rightRail.y -ne 0 -or
    $rightRail.width -le 0 -or
    $rightRail.height -ne $requiredHeight -or
    ($rightRail.x + $rightRail.width) -ne $requiredWidth
) {
    throw "Configured right-rail must touch the right edge and span the full $requiredHeight px height."
}
$regions = @($topHeader, $rightRail)

try {
    Add-Type -AssemblyName System.Drawing
}
catch {
    throw "System.Drawing is required by this Windows workspace and could not be loaded. No files were changed.`n$($_.Exception.Message)"
}

$manifestFileBefore = Get-Item -LiteralPath $manifestPath
$manifestLengthBefore = [long]$manifestFileBefore.Length
$manifestLastWriteBefore = $manifestFileBefore.LastWriteTimeUtc
$plans = @()

foreach ($slide in $requestedSlides) {
    if ($slide -lt 1 -or $slide -gt 9999) {
        throw "Slide number is outside the supported range 1..9999: $slide"
    }

    $manifestMatches = @($manifest.slides | Where-Object { [int]$_.slide -eq $slide })
    if ($manifestMatches.Count -ne 1) {
        throw "Slide $slide must appear exactly once in $manifestRelativePath."
    }
    if (@($manifest.requiredSlides | Where-Object { [int]$_ -eq $slide }).Count -ne 1) {
        throw "Slide $slide is not an explicitly required rework slide in $manifestRelativePath."
    }
    $entry = $manifestMatches[0]
    $versions = @($entry.versions)
    if ($versions.Count -eq 0) {
        throw "Slide $slide has no rework versions to repair."
    }

    $currentVersionNumber = [int]$entry.currentVersion
    $currentMatches = @($versions | Where-Object { [int]$_.version -eq $currentVersionNumber })
    if ($currentMatches.Count -ne 1) {
        throw "Slide $slide currentVersion $currentVersionNumber does not resolve to exactly one version."
    }
    $currentVersion = $currentMatches[0]
    if (
        [string]$entry.reviewStatus -eq 'approved' -or
        [string]$currentVersion.reviewStatus -eq 'approved'
    ) {
        throw "Slide $slide current version is approved and immutable. Reopen it explicitly before repair."
    }
    if ([string]$currentVersion.status -eq 'internal_rejected') {
        throw "Slide $slide current version is internal_rejected and cannot be a repair source."
    }

    $currentRelativePath = [string]$currentVersion.path
    $currentPath = Get-JobPath -ResolvedJobRoot $resolvedJobRoot -RelativePath $currentRelativePath
    $inventoryMatches = @($inventory.slides | Where-Object { [int]$_.slide -eq $slide })
    if ($inventoryMatches.Count -ne 1) {
        throw "Slide $slide must appear exactly once in $inventoryRelativePath."
    }
    $inventorySlide = $inventoryMatches[0]
    $referenceRelativePath = [string]$inventorySlide.referenceImage
    if ([string]::IsNullOrWhiteSpace($referenceRelativePath)) {
        throw "Slide $slide has no original reference image; template chrome cannot be recovered."
    }
    $referencePath = Get-JobPath -ResolvedJobRoot $resolvedJobRoot -RelativePath $referenceRelativePath

    $currentDimensions = Get-ImageDimensions -Path $currentPath
    $referenceDimensions = Get-ImageDimensions -Path $referencePath
    foreach ($measurement in @(
        [pscustomobject]@{ Name = 'current rework'; Value = $currentDimensions },
        [pscustomobject]@{ Name = 'original reference'; Value = $referenceDimensions }
    )) {
        if (
            $measurement.Value.Width -ne $requiredWidth -or
            $measurement.Value.Height -ne $requiredHeight
        ) {
            throw "Slide $slide $($measurement.Name) must be ${requiredWidth}x${requiredHeight}; got $($measurement.Value.Width)x$($measurement.Value.Height)."
        }
    }

    $maximumVersion = [int](($versions | Measure-Object -Property version -Maximum).Maximum)
    $nextVersion = $maximumVersion + 1
    if ($nextVersion -gt 999) {
        throw "Slide $slide has no available v### version after v$maximumVersion."
    }

    $slideId = $slide.ToString('0000')
    $versionId = $nextVersion.ToString('000')
    $slideDirectory = Join-Path $resolvedJobRoot "04_rework\slide-$slideId"
    $outputRelativePath = "04_rework/slide-$slideId/v$versionId.png"
    $sourceRelativePath = "04_rework/slide-$slideId/v$versionId-source.png"
    $outputPath = Get-JobPath -ResolvedJobRoot $resolvedJobRoot -RelativePath $outputRelativePath
    $sourcePath = Get-JobPath -ResolvedJobRoot $resolvedJobRoot -RelativePath $sourceRelativePath

    foreach ($newPath in @($outputPath, $sourcePath)) {
        if (Test-Path -LiteralPath $newPath) {
            throw "Refusing to overwrite an existing next-version file: $newPath"
        }
    }

    $plans += [pscustomobject][ordered]@{
        slide = $slide
        entry = $entry
        currentVersionEntry = $currentVersion
        derivedFromVersion = $currentVersionNumber
        derivedFromPath = $currentRelativePath
        referenceRelativePath = $referenceRelativePath
        referencePath = $referencePath
        basePath = $currentPath
        nextVersion = $nextVersion
        slideDirectory = $slideDirectory
        outputRelativePath = $outputRelativePath
        outputPath = $outputPath
        sourceRelativePath = $sourceRelativePath
        sourcePath = $sourcePath
    }
}

$publicPlans = @($plans | ForEach-Object {
    [pscustomobject][ordered]@{
        slide = $_.slide
        derivedFrom = [pscustomobject][ordered]@{
            version = $_.derivedFromVersion
            path = $_.derivedFromPath
        }
        referencePath = $_.referenceRelativePath
        nextVersion = $_.nextVersion
        sourceSnapshotPath = $_.sourceRelativePath
        outputPath = $_.outputRelativePath
        regions = @($regions | ForEach-Object {
            [pscustomobject][ordered]@{
                id = $_.id
                source = [pscustomobject][ordered]@{
                    x = $_.x
                    y = $_.y
                    width = $_.width
                    height = $_.height
                }
                destination = [pscustomobject][ordered]@{
                    x = $_.x
                    y = $_.y
                    width = $_.width
                    height = $_.height
                }
            }
        })
    }
})

if ($DryRun) {
    [pscustomobject][ordered]@{
        mode = 'dry_run'
        changed = $false
        jobRoot = $resolvedJobRoot
        criteriaPath = $criteriaRelativePath
        manifestPath = $manifestRelativePath
        slideCount = $publicPlans.Count
        slides = $publicPlans
    } | ConvertTo-Json -Depth 20
    return
}

$batchId = [System.Guid]::NewGuid().ToString('N')
$createdAt = [System.DateTimeOffset]::UtcNow.ToString('o')
$transactionId = [System.Guid]::NewGuid().ToString('N')
$manifestDirectory = Split-Path -Parent $manifestPath
$manifestTemporaryPath = Join-Path $manifestDirectory ".manifest.chrome-repair-$transactionId.tmp"
$manifestBackupPath = Join-Path $manifestDirectory ".manifest.chrome-repair-$transactionId.backup"
$staged = @()
$committedPaths = @()
$manifestReplaced = $false

try {
    foreach ($plan in $plans) {
        if (-not (Test-Path -LiteralPath $plan.slideDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $plan.slideDirectory | Out-Null
        }

        $sourceTemporaryPath = Join-Path $plan.slideDirectory ".$([System.IO.Path]::GetFileName($plan.sourcePath)).$transactionId.tmp"
        $outputTemporaryPath = Join-Path $plan.slideDirectory ".$([System.IO.Path]::GetFileName($plan.outputPath)).$transactionId.tmp"
        Copy-Item -LiteralPath $plan.basePath -Destination $sourceTemporaryPath
        New-ChromeLockedImage `
            -BasePath $plan.basePath `
            -ReferencePath $plan.referencePath `
            -OutputPath $outputTemporaryPath `
            -Regions $regions

        $evidenceLocks = @($regions | ForEach-Object {
            [pscustomobject][ordered]@{
                name = "template-chrome-$($_.id)"
                source = [pscustomobject][ordered]@{
                    x = $_.x
                    y = $_.y
                    w = $_.width
                    h = $_.height
                }
                destination = [pscustomobject][ordered]@{
                    x = $_.x
                    y = $_.y
                    w = $_.width
                    h = $_.height
                }
            }
        })
        $lineageRegions = @($regions | ForEach-Object {
            [pscustomobject][ordered]@{
                id = $_.id
                source = [pscustomobject][ordered]@{
                    path = $plan.referenceRelativePath
                    x = $_.x
                    y = $_.y
                    width = $_.width
                    height = $_.height
                }
                destination = [pscustomobject][ordered]@{
                    path = $plan.outputRelativePath
                    x = $_.x
                    y = $_.y
                    width = $_.width
                    height = $_.height
                }
            }
        })
        $versionEntry = [pscustomobject][ordered]@{
            version = $plan.nextVersion
            path = $plan.outputRelativePath
            sourcePath = $plan.sourceRelativePath
            status = 'qa_pending'
            reason = 'Original template chrome pixel-locked; direct visual QA required.'
            reviewStatus = 'pending'
            reviewReason = ''
            reviewedAt = $null
            evidenceLocks = $evidenceLocks
            lineage = [pscustomobject][ordered]@{
                operation = 'template_chrome_pixel_lock'
                batchId = $batchId
                tool = $toolRelativePath
                createdAt = $createdAt
                derivedFrom = [pscustomobject][ordered]@{
                    version = $plan.derivedFromVersion
                    path = $plan.derivedFromPath
                }
                sourceSnapshotPath = $plan.sourceRelativePath
                originalReference = [pscustomobject][ordered]@{
                    path = $plan.referenceRelativePath
                    inventoryPath = $inventoryRelativePath
                }
                criteria = [pscustomobject][ordered]@{
                    path = $criteriaRelativePath
                    contractPath = 'reworkContract.templateChrome.regions'
                }
                regions = $lineageRegions
            }
        }

        $plan.entry.versions = @(@($plan.entry.versions) + $versionEntry | Sort-Object -Property version)
        $plan.entry.currentVersion = $plan.nextVersion
        $plan.entry.status = 'qa_pending'
        $plan.entry.reviewStatus = 'pending'
        $plan.entry.reviewReason = ''
        $plan.entry.reviewedAt = $null
        $plan.entry.needsNewVersion = $false

        $staged += [pscustomobject][ordered]@{
            sourceTemporaryPath = $sourceTemporaryPath
            sourcePath = $plan.sourcePath
            outputTemporaryPath = $outputTemporaryPath
            outputPath = $plan.outputPath
        }
    }

    Add-OrSetProperty -Target $manifest -Name 'updatedAt' -Value $createdAt
    $manifestJson = ($manifest | ConvertTo-Json -Depth 100) + [System.Environment]::NewLine
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifestTemporaryPath, $manifestJson, $utf8WithoutBom)

    $manifestFileNow = Get-Item -LiteralPath $manifestPath
    if (
        [long]$manifestFileNow.Length -ne $manifestLengthBefore -or
        $manifestFileNow.LastWriteTimeUtc -ne $manifestLastWriteBefore
    ) {
        throw 'Rework manifest changed during repair staging. No new version will be committed; rerun the dry-run.'
    }

    foreach ($stage in $staged) {
        [System.IO.File]::Move($stage.sourceTemporaryPath, $stage.sourcePath)
        $committedPaths += $stage.sourcePath
        [System.IO.File]::Move($stage.outputTemporaryPath, $stage.outputPath)
        $committedPaths += $stage.outputPath
    }

    [System.IO.File]::Replace(
        $manifestTemporaryPath,
        $manifestPath,
        $manifestBackupPath,
        $true
    )
    $manifestReplaced = $true
}
catch {
    if (-not $manifestReplaced) {
        foreach ($committedPath in @($committedPaths | Sort-Object -Descending)) {
            Remove-ExactFileIfPresent -Path $committedPath
        }
    }
    throw
}
finally {
    foreach ($stage in $staged) {
        Remove-ExactFileIfPresent -Path $stage.sourceTemporaryPath
        Remove-ExactFileIfPresent -Path $stage.outputTemporaryPath
    }
    Remove-ExactFileIfPresent -Path $manifestTemporaryPath
    if ($manifestReplaced) {
        Remove-ExactFileIfPresent -Path $manifestBackupPath
    }
}

[pscustomobject][ordered]@{
    mode = 'apply'
    changed = $true
    batchId = $batchId
    jobRoot = $resolvedJobRoot
    criteriaPath = $criteriaRelativePath
    manifestPath = $manifestRelativePath
    slideCount = $publicPlans.Count
    slides = $publicPlans
} | ConvertTo-Json -Depth 20
