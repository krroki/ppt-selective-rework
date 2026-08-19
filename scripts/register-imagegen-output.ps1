[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobRoot,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 9999)]
    [int]$Slide,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 999)]
    [int]$Version,

    [Parameter(Mandatory = $true)]
    [string]$GeneratedPath
)

$ErrorActionPreference = 'Stop'
$resolvedJob = (Resolve-Path -LiteralPath $JobRoot).Path
$resolvedGenerated = (Resolve-Path -LiteralPath $GeneratedPath).Path
$slideId = $Slide.ToString('0000')
$versionId = $Version.ToString('000')
$slideDir = Join-Path $resolvedJob "04_rework\slide-$slideId"
$rawPath = Join-Path $slideDir "v$versionId-source.png"
$finalPath = Join-Path $slideDir "v$versionId.png"

if (Test-Path -LiteralPath $rawPath) {
    throw "Refusing to overwrite generated source: $rawPath"
}
if (Test-Path -LiteralPath $finalPath) {
    throw "Refusing to overwrite normalized output: $finalPath"
}

New-Item -ItemType Directory -Path $slideDir -Force | Out-Null
Copy-Item -LiteralPath $resolvedGenerated -Destination $rawPath

Add-Type -AssemblyName System.Drawing
$sourceImage = [System.Drawing.Image]::FromFile($rawPath)
try {
    $canvas = New-Object System.Drawing.Bitmap 1920, 1080
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        try {
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.Clear([System.Drawing.Color]::White)
            $graphics.DrawImage($sourceImage, 0, 0, 1920, 1080)
        }
        finally {
            $graphics.Dispose()
        }
        $canvas.Save($finalPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $canvas.Dispose()
    }
}
finally {
    $sourceImage.Dispose()
}

$registered = [System.Drawing.Image]::FromFile($finalPath)
try {
    [pscustomobject]@{
        slide = $Slide
        version = $Version
        generatedSource = $rawPath
        output = $finalPath
        width = $registered.Width
        height = $registered.Height
        ratio = [math]::Round($registered.Width / $registered.Height, 4)
        bytes = (Get-Item -LiteralPath $finalPath).Length
    } | ConvertTo-Json -Depth 4
}
finally {
    $registered.Dispose()
}
