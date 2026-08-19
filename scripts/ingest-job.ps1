[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobRoot,
    [string]$DisplayName,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing

$jobRootFull = [System.IO.Path]::GetFullPath($JobRoot)
$inputDir = Join-Path $jobRootFull '00_input'
$pptxPath = Join-Path $inputDir 'original.pptx'
$pngZipPath = Join-Path $inputDir 'reference-png.zip'
$inventoryDir = Join-Path $jobRootFull '01_inventory'
$referenceDir = Join-Path $inventoryDir 'reference'
$thumbnailDir = Join-Path $inventoryDir 'thumbnails'
$triageDir = Join-Path $jobRootFull '02_triage'
$autoAuditPath = Join-Path $triageDir 'auto-audit.json'
$styleDir = Join-Path $jobRootFull '03_style'
$stateDir = Join-Path $jobRootFull '_state'

if (-not (Test-Path -LiteralPath $pptxPath -PathType Leaf)) {
    throw "Missing canonical PPTX: $pptxPath"
}

foreach ($dir in @($inventoryDir, $referenceDir, $thumbnailDir, $triageDir, $styleDir, $stateDir, (Join-Path $jobRootFull '04_rework'), (Join-Path $jobRootFull '05_review'), (Join-Path $jobRootFull '06_output'))) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Read-ZipText {
    param($Archive, [string]$Name)
    $entry = $Archive.GetEntry($Name)
    if ($null -eq $entry) { return $null }
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Write-JsonFile {
    param([string]$Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Copy-ZipEntry {
    param($Entry, [string]$Destination)
    $source = $Entry.Open()
    try {
        $target = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $source.CopyTo($target) } finally { $target.Dispose() }
    } finally { $source.Dispose() }
}

function Get-HexColor {
    param([int]$R, [int]$G, [int]$B)
    return ('#{0:X2}{1:X2}{2:X2}' -f $R, $G, $B)
}

function Get-ImageMetrics {
    param(
        [string]$ImagePath,
        [string]$ThumbnailPath,
        [hashtable]$PaletteCounts,
        [bool]$WriteThumbnail = $true
    )

    $image = [System.Drawing.Image]::FromFile($ImagePath)
    try {
        if ($WriteThumbnail) {
            $thumbWidth = 480
            $thumbHeight = [int][Math]::Round($thumbWidth * $image.Height / $image.Width)
            $thumbnail = [System.Drawing.Bitmap]::new($thumbWidth, $thumbHeight)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($thumbnail)
                try {
                    $graphics.Clear([System.Drawing.Color]::White)
                    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $graphics.DrawImage($image, 0, 0, $thumbWidth, $thumbHeight)
                } finally { $graphics.Dispose() }
                $thumbnail.Save($ThumbnailPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
            } finally { $thumbnail.Dispose() }
        }

        $sample = [System.Drawing.Bitmap]::new($image, 64, 36)
        try {
            [double]$sum = 0
            [double]$sumSq = 0
            [int]$samples = 0
            for ($y = 0; $y -lt $sample.Height; $y++) {
                for ($x = 0; $x -lt $sample.Width; $x++) {
                    $color = $sample.GetPixel($x, $y)
                    $luma = (0.2126 * $color.R) + (0.7152 * $color.G) + (0.0722 * $color.B)
                    $sum += $luma
                    $sumSq += ($luma * $luma)
                    $samples++

                    $maxChannel = [Math]::Max($color.R, [Math]::Max($color.G, $color.B))
                    $minChannel = [Math]::Min($color.R, [Math]::Min($color.G, $color.B))
                    $saturation = if ($maxChannel -eq 0) { 0 } else { ($maxChannel - $minChannel) / $maxChannel }
                    if ($saturation -ge 0.22 -and $luma -ge 35 -and $luma -le 228) {
                        $qr = [Math]::Min(255, ([Math]::Floor($color.R / 32) * 32) + 16)
                        $qg = [Math]::Min(255, ([Math]::Floor($color.G / 32) * 32) + 16)
                        $qb = [Math]::Min(255, ([Math]::Floor($color.B / 32) * 32) + 16)
                        $key = "$qr,$qg,$qb"
                        if ($PaletteCounts.ContainsKey($key)) { $PaletteCounts[$key]++ } else { $PaletteCounts[$key] = 1 }
                    }
                }
            }
            $mean = $sum / $samples
            $variance = [Math]::Max(0, ($sumSq / $samples) - ($mean * $mean))
            return [pscustomobject]@{
                width = $image.Width
                height = $image.Height
                lumaMean = [Math]::Round($mean, 2)
                lumaStdDev = [Math]::Round([Math]::Sqrt($variance), 2)
            }
        } finally { $sample.Dispose() }
    } finally { $image.Dispose() }
}

Write-Host '[ingest] Reading PPTX presentation order and slide metadata...'
$pptxArchive = [System.IO.Compression.ZipFile]::OpenRead($pptxPath)
try {
    [xml]$presentationXml = Read-ZipText $pptxArchive 'ppt/presentation.xml'
    [xml]$presentationRels = Read-ZipText $pptxArchive 'ppt/_rels/presentation.xml.rels'

    $presentationNs = [System.Xml.XmlNamespaceManager]::new($presentationXml.NameTable)
    $presentationNs.AddNamespace('p', 'http://schemas.openxmlformats.org/presentationml/2006/main')
    $presentationNs.AddNamespace('r', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
    $relNs = [System.Xml.XmlNamespaceManager]::new($presentationRels.NameTable)
    $relNs.AddNamespace('pr', 'http://schemas.openxmlformats.org/package/2006/relationships')

    $slideIdNodes = @($presentationXml.SelectNodes('//p:sldIdLst/p:sldId', $presentationNs))
    $sizeNode = $presentationXml.SelectSingleNode('//p:sldSz', $presentationNs)
    $slideWidthEmu = [long]$sizeNode.cx
    $slideHeightEmu = [long]$sizeNode.cy
    $pptSlides = @()

    for ($index = 0; $index -lt $slideIdNodes.Count; $index++) {
        $ordinal = $index + 1
        $relationshipId = $slideIdNodes[$index].GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        $relationship = $presentationRels.SelectSingleNode("//pr:Relationship[@Id='$relationshipId']", $relNs)
        $target = [string]$relationship.Target
        $slidePath = ('ppt/' + $target.TrimStart('/')).Replace('../', '')
        [xml]$slideXml = Read-ZipText $pptxArchive $slidePath
        $slideNs = [System.Xml.XmlNamespaceManager]::new($slideXml.NameTable)
        $slideNs.AddNamespace('a', 'http://schemas.openxmlformats.org/drawingml/2006/main')
        $slideNs.AddNamespace('p', 'http://schemas.openxmlformats.org/presentationml/2006/main')
        # `a:t` can be represented as either a simple text node or an element
        # without a PowerShell `#text` adapter property. InnerText is stable for
        # both forms and preserves the presentation's visible run order.
        $textRuns = @($slideXml.SelectNodes('//a:t', $slideNs) | ForEach-Object { [string]$_.InnerText })
        $fontNodes = @($slideXml.SelectNodes('//a:rPr/@sz | //a:defRPr/@sz | //a:endParaRPr/@sz', $slideNs))
        $fontSizes = @($fontNodes | ForEach-Object { [Math]::Round(([double]$_.Value / 100), 2) })
        $smallFontCount = @($fontSizes | Where-Object { $_ -le 14 }).Count
        $text = ($textRuns -join ' ').Trim()

        $pptSlides += [pscustomobject]@{
            slide = $ordinal
            sourceSlidePath = $slidePath
            hidden = ($slideXml.DocumentElement.GetAttribute('show') -eq '0')
            text = $text
            textChars = $text.Length
            textRuns = $textRuns.Count
            shapeCount = @($slideXml.SelectNodes('//p:sp', $slideNs)).Count
            pictureCount = @($slideXml.SelectNodes('//p:pic', $slideNs)).Count
            minExplicitFontPt = if ($fontSizes.Count) { ($fontSizes | Measure-Object -Minimum).Minimum } else { $null }
            smallFontRatio = if ($fontSizes.Count) { [Math]::Round($smallFontCount / $fontSizes.Count, 3) } else { 0 }
        }
    }
} finally {
    $pptxArchive.Dispose()
}

$paletteCounts = @{}
$imageByOrdinal = @{}
$pngOriginalNames = @{}

if (Test-Path -LiteralPath $pngZipPath -PathType Leaf) {
    Write-Host '[ingest] Extracting reference PNGs by archive order and building thumbnails...'
    $pngArchive = [System.IO.Compression.ZipFile]::OpenRead($pngZipPath)
    try {
        $pngEntries = @($pngArchive.Entries | Where-Object { $_.Name -match '\.png$' })
        for ($index = 0; $index -lt $pngEntries.Count; $index++) {
            $ordinal = $index + 1
            $entry = $pngEntries[$index]
            $pngOriginalNames[$ordinal] = $entry.Name
            $referenceName = 'slide-{0:D4}.png' -f $ordinal
            $thumbnailName = 'slide-{0:D4}.jpg' -f $ordinal
            $referencePath = Join-Path $referenceDir $referenceName
            $thumbnailPath = Join-Path $thumbnailDir $thumbnailName

            if ($Force -or -not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
                Copy-ZipEntry $entry $referencePath
            }
            $writeThumbnail = $Force -or -not (Test-Path -LiteralPath $thumbnailPath -PathType Leaf)
            $metrics = Get-ImageMetrics $referencePath $thumbnailPath $paletteCounts $writeThumbnail
            $imageByOrdinal[$ordinal] = [pscustomobject]@{
                reference = "01_inventory/reference/$referenceName"
                thumbnail = "01_inventory/thumbnails/$thumbnailName"
                originalName = $entry.Name
                width = $metrics.width
                height = $metrics.height
                lumaMean = $metrics.lumaMean
                lumaStdDev = $metrics.lumaStdDev
            }

            if (($ordinal % 25) -eq 0 -or $ordinal -eq $pngEntries.Count) {
                Write-Host "[ingest] Processed $ordinal / $($pngEntries.Count) reference images"
            }
        }
    } finally {
        $pngArchive.Dispose()
    }
} else {
    Write-Warning "No reference PNG ZIP found at $pngZipPath"
}

Write-Host '[ingest] Building slide inventory and automated triage signals...'
$slides = @()
foreach ($pptSlide in $pptSlides) {
    $image = $imageByOrdinal[$pptSlide.slide]
    $signals = New-Object System.Collections.Generic.List[string]

    if ($null -eq $image) {
        $signals.Add('reference_missing')
    }
    if ($pptSlide.textChars -ge 700) {
        $signals.Add('dense_text')
    }
    if ($pptSlide.textRuns -ge 60) {
        $signals.Add('many_text_runs')
    }
    if ($pptSlide.textChars -ge 250 -and $pptSlide.smallFontRatio -ge 0.30) {
        $signals.Add('small_text_ratio')
    }
    $suggestion = if ($signals.Contains('reference_missing')) {
        'uncertain'
    } elseif ($signals.Contains('dense_text') -or $signals.Contains('small_text_ratio')) {
        'rework'
    } elseif ($signals.Contains('many_text_runs')) {
        'uncertain'
    } else {
        'keep'
    }

    $slides += [pscustomobject]@{
        slide = $pptSlide.slide
        referenceImage = if ($null -ne $image) { $image.reference } else { $null }
        thumbnail = if ($null -ne $image) { $image.thumbnail } else { $null }
        referenceOriginalName = if ($null -ne $image) { $image.originalName } else { $null }
        imageWidth = if ($null -ne $image) { $image.width } else { $null }
        imageHeight = if ($null -ne $image) { $image.height } else { $null }
        lumaMean = if ($null -ne $image) { $image.lumaMean } else { $null }
        lumaStdDev = if ($null -ne $image) { $image.lumaStdDev } else { $null }
        text = $pptSlide.text
        textChars = $pptSlide.textChars
        textRuns = $pptSlide.textRuns
        shapeCount = $pptSlide.shapeCount
        pictureCount = $pptSlide.pictureCount
        minExplicitFontPt = $pptSlide.minExplicitFontPt
        smallFontRatio = $pptSlide.smallFontRatio
        autoSignals = $signals.ToArray()
        suggestion = $suggestion
    }
}

$paletteCandidates = New-Object System.Collections.Generic.List[object]
$paletteTotal = ($paletteCounts.Values | Measure-Object -Sum).Sum
foreach ($entry in @($paletteCounts.GetEnumerator() | Sort-Object Value -Descending)) {
    $parts = @($entry.Key.Split(',') | ForEach-Object { [int]$_ })
    $isDistinct = $true
    foreach ($candidate in $paletteCandidates) {
        $distance = [Math]::Sqrt([Math]::Pow($parts[0] - $candidate.r, 2) + [Math]::Pow($parts[1] - $candidate.g, 2) + [Math]::Pow($parts[2] - $candidate.b, 2))
        if ($distance -lt 62) { $isDistinct = $false; break }
    }
    if ($isDistinct) {
        $paletteCandidates.Add([pscustomobject]@{
            hex = Get-HexColor $parts[0] $parts[1] $parts[2]
            r = $parts[0]
            g = $parts[1]
            b = $parts[2]
            samples = [int]$entry.Value
            share = if ($paletteTotal) { [Math]::Round($entry.Value / $paletteTotal, 4) } else { 0 }
        })
    }
    if ($paletteCandidates.Count -ge 8) { break }
}

$referenceMissing = @($slides | Where-Object { $null -eq $_.referenceImage } | Select-Object -ExpandProperty slide)
$projectName = if ($DisplayName) { $DisplayName } else { Split-Path -Leaf $jobRootFull }
$projectPath = Join-Path $jobRootFull 'project.json'
$decisionsPath = Join-Path $triageDir 'decisions.json'
$existingProject = $null
$existingDecisions = $null
$autoAudit = $null
if (-not $Force -and (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    $existingProject = Get-Content -Raw -Encoding UTF8 -LiteralPath $projectPath | ConvertFrom-Json
}
if (-not $Force -and (Test-Path -LiteralPath $decisionsPath -PathType Leaf)) {
    $existingDecisions = Get-Content -Raw -Encoding UTF8 -LiteralPath $decisionsPath | ConvertFrom-Json
}
if (Test-Path -LiteralPath $autoAuditPath -PathType Leaf) {
    $autoAudit = Get-Content -Raw -Encoding UTF8 -LiteralPath $autoAuditPath | ConvertFrom-Json
}

$project = [ordered]@{
    schemaVersion = 1
    jobId = Split-Path -Leaf $jobRootFull
    displayName = $projectName
    createdAt = if ($null -ne $existingProject -and $existingProject.createdAt) { $existingProject.createdAt } else { (Get-Date).ToString('o') }
    phase = if ($null -ne $existingProject -and $existingProject.phase) { $existingProject.phase } else { 'triage' }
    source = [ordered]@{
        pptx = '00_input/original.pptx'
        referencePngZip = if (Test-Path -LiteralPath $pngZipPath) { '00_input/reference-png.zip' } else { $null }
    }
    deck = [ordered]@{
        slideCount = $slides.Count
        referenceImageCount = $imageByOrdinal.Count
        missingReferenceSlides = $referenceMissing
        widthEmu = $slideWidthEmu
        heightEmu = $slideHeightEmu
        widthInches = [Math]::Round($slideWidthEmu / 914400, 3)
        heightInches = [Math]::Round($slideHeightEmu / 914400, 3)
        aspectRatio = [Math]::Round($slideWidthEmu / $slideHeightEmu, 4)
    }
}
$existingTriageFinalized = if ($null -ne $existingProject) { $existingProject.PSObject.Properties['triageFinalizedAt'] } else { $null }
if ($null -ne $existingTriageFinalized -and $existingTriageFinalized.Value) {
    $project.triageFinalizedAt = $existingTriageFinalized.Value
}

$existingDecisionBySlide = @{}
if ($null -ne $existingDecisions) {
    foreach ($decision in @($existingDecisions.slides)) {
        $existingDecisionBySlide[[int]$decision.slide] = $decision
    }
}

$autoAuditBySlide = @{}
if ($null -ne $autoAudit) {
    foreach ($auditDecision in @($autoAudit.slides)) {
        $autoAuditBySlide[[int]$auditDecision.slide] = $auditDecision
    }
}
$autoDefaultStatus = if ($null -ne $autoAudit -and $null -ne $autoAudit.PSObject.Properties['defaultStatus'] -and $autoAudit.defaultStatus -in @('keep', 'rework', 'uncertain')) { [string]$autoAudit.defaultStatus } else { $null }
$autoDecisionSource = if ($null -ne $autoAudit -and $null -ne $autoAudit.PSObject.Properties['decisionSource'] -and $autoAudit.decisionSource) { [string]$autoAudit.decisionSource } else { 'auto_heuristic' }
$autoGeneratedAt = if ($null -ne $autoAudit -and $null -ne $autoAudit.PSObject.Properties['generatedAt'] -and $autoAudit.generatedAt) { [string]$autoAudit.generatedAt } else { (Get-Date).ToString('o') }

$decisions = [ordered]@{
    schemaVersion = 1
    finalizedAt = if ($null -ne $existingDecisions) { $existingDecisions.finalizedAt } else { $null }
    slides = @($slides | ForEach-Object {
        $existingDecision = $existingDecisionBySlide[[int]$_.slide]
        $auditDecision = $autoAuditBySlide[[int]$_.slide]
        $autoStatus = if ($null -ne $auditDecision -and $auditDecision.status -in @('keep', 'rework', 'uncertain')) {
            [string]$auditDecision.status
        } elseif ($null -ne $autoDefaultStatus) {
            $autoDefaultStatus
        } else {
            [string]$_.suggestion
        }
        $autoReason = if ($null -ne $auditDecision -and $null -ne $auditDecision.PSObject.Properties['reason'] -and $auditDecision.reason) { [string]$auditDecision.reason } else { '' }

        $existingSourceProperty = if ($null -ne $existingDecision) { $existingDecision.PSObject.Properties['source'] } else { $null }
        $existingUpdatedAtProperty = if ($null -ne $existingDecision) { $existingDecision.PSObject.Properties['updatedAt'] } else { $null }
        $existingAutoUpdatedAtProperty = if ($null -ne $existingDecision) { $existingDecision.PSObject.Properties['autoUpdatedAt'] } else { $null }
        $existingSource = if ($null -ne $existingSourceProperty) { [string]$existingSourceProperty.Value } else { '' }
        $legacyHumanEdit = $null -ne $existingDecision -and $null -eq $existingSourceProperty -and $null -ne $existingUpdatedAtProperty -and $existingUpdatedAtProperty.Value
        $legacyAutoSourceEdit = $null -ne $existingDecision -and $existingSource -in @('auto_visual', 'auto_heuristic') -and $null -ne $existingUpdatedAtProperty -and $existingUpdatedAtProperty.Value -and $null -ne $existingAutoUpdatedAtProperty -and $existingAutoUpdatedAtProperty.Value -and ([string]$existingUpdatedAtProperty.Value -ne [string]$existingAutoUpdatedAtProperty.Value)
        $preserveHumanDecision = $null -ne $existingDecision -and $existingDecision.status -in @('keep', 'rework', 'uncertain') -and ($existingSource -eq 'human' -or $legacyHumanEdit -or $legacyAutoSourceEdit)

        [ordered]@{
            slide = $_.slide
            status = if ($preserveHumanDecision) { [string]$existingDecision.status } else { $autoStatus }
            reason = if ($preserveHumanDecision -and $null -ne $existingDecision.PSObject.Properties['reason']) { [string]$existingDecision.reason } else { $autoReason }
            source = if ($preserveHumanDecision) { 'human' } else { $autoDecisionSource }
            autoStatus = $autoStatus
            autoReason = $autoReason
            autoSource = $autoDecisionSource
            autoUpdatedAt = $autoGeneratedAt
            suggestion = $_.suggestion
            updatedAt = if ($preserveHumanDecision -and $null -ne $existingUpdatedAtProperty) { $existingUpdatedAtProperty.Value } else { $autoGeneratedAt }
        }
    })
}

$palette = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString('o')
    method = '64x36 sampled pixels, quantized, saturated non-neutral colors'
    candidates = $paletteCandidates.ToArray()
}

Write-JsonFile $projectPath $project
Write-JsonFile (Join-Path $inventoryDir 'slides.json') ([ordered]@{ schemaVersion = 1; slides = $slides })
Write-JsonFile $decisionsPath $decisions
Write-JsonFile (Join-Path $styleDir 'palette-candidates.json') $palette

$workflowTemplate = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\WORKFLOW.md'
$workflowDestination = Join-Path $jobRootFull 'WORKFLOW.md'
if (-not (Test-Path -LiteralPath $workflowDestination) -and (Test-Path -LiteralPath $workflowTemplate)) {
    Copy-Item -LiteralPath $workflowTemplate -Destination $workflowDestination
}

$criteriaTemplate = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\rework-criteria.json'
$criteriaDestination = Join-Path $triageDir 'criteria.json'
if (-not (Test-Path -LiteralPath $criteriaDestination) -and (Test-Path -LiteralPath $criteriaTemplate)) {
    Copy-Item -LiteralPath $criteriaTemplate -Destination $criteriaDestination
}

Write-Host "[ingest] Complete: $($slides.Count) PPTX slides, $($imageByOrdinal.Count) reference images, $($referenceMissing.Count) missing references"
Write-Output (Join-Path $jobRootFull 'project.json')
