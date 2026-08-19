[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BaseImage,
  [Parameter(Mandatory = $true)][string]$ReferenceImage,
  [Parameter(Mandatory = $true)][string]$SourceSnapshot,
  [Parameter(Mandatory = $true)][string]$OutputImage,
  [Parameter(Mandatory = $true)][string]$LocksJson
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

foreach ($path in @($BaseImage, $ReferenceImage)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Input image not found: $path"
  }
}
foreach ($path in @($SourceSnapshot, $OutputImage)) {
  if (Test-Path -LiteralPath $path) {
    throw "Refusing to overwrite existing output: $path"
  }
  $parent = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
  }
}

$parsedLocks = $LocksJson | ConvertFrom-Json
# Windows PowerShell 5.1 can keep a JSON array wrapped as one Object[] item.
# Enumerate it explicitly so every evidence lock has scalar geometry fields.
$locks = @($parsedLocks | ForEach-Object { $_ })
if (-not $locks.Count) { throw 'At least one evidence lock is required.' }

Copy-Item -LiteralPath $BaseImage -Destination $SourceSnapshot
$base = [System.Drawing.Bitmap]::FromFile($BaseImage)
$reference = [System.Drawing.Bitmap]::FromFile($ReferenceImage)
$canvas = New-Object System.Drawing.Bitmap($base.Width, $base.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($canvas)

try {
  $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
  $graphics.DrawImage($base, 0, 0, $base.Width, $base.Height)
  $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
  $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

  foreach ($lock in $locks) {
    if ($lock.clear) {
      $clear = $lock.clear
      $color = [System.Drawing.ColorTranslator]::FromHtml([string]$clear.color)
      $brush = New-Object System.Drawing.SolidBrush($color)
      try {
        $graphics.FillRectangle($brush, [int]$clear.x, [int]$clear.y, [int]$clear.w, [int]$clear.h)
      } finally {
        $brush.Dispose()
      }
    }

    $source = $lock.source
    $destination = $lock.destination
    $sourceRect = New-Object System.Drawing.Rectangle([int]$source.x, [int]$source.y, [int]$source.w, [int]$source.h)
    $destinationRect = New-Object System.Drawing.Rectangle([int]$destination.x, [int]$destination.y, [int]$destination.w, [int]$destination.h)
    $graphics.DrawImage($reference, $destinationRect, $sourceRect, [System.Drawing.GraphicsUnit]::Pixel)
  }

  $canvas.Save($OutputImage, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
  $graphics.Dispose()
  $canvas.Dispose()
  $reference.Dispose()
  $base.Dispose()
}

$result = [ordered]@{
  baseImage = $BaseImage
  referenceImage = $ReferenceImage
  sourceSnapshot = $SourceSnapshot
  outputImage = $OutputImage
  width = 1920
  height = 1080
  evidenceLocks = $locks
}
$result | ConvertTo-Json -Depth 8
