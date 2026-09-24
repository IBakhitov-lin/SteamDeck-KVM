# Файл общей библиотеки, положенный сборщиком выпуска. Правится исходник, а не он.

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

function Get-SingleInstanceLock {
    
    param(
        [Parameter(Mandatory)][string]$Name
    )
    $mutex = New-Object System.Threading.Mutex($false, "Local\$Name")
    try { $owns = $mutex.WaitOne(0) } catch { $owns = $false }
    return [PSCustomObject]@{ Mutex = $mutex; IsOwner = $owns }
}

$script:PaletteCache = $null
function Get-PaletteColor {
    
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int[]]$Fallback,
        [string]$Theme = 'тёмная',
        [string]$ContractPath = (Join-Path $PSScriptRoot 'palette.json')
    )
    if ($null -eq $script:PaletteCache) {
        $script:PaletteCache = @{}
        try {
            $json = Get-Content -LiteralPath $ContractPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:PaletteCache[$Theme] = $json.$Theme
        } catch { }
    }
    $group = $script:PaletteCache[$Theme]
    if ($group -and $group.$Name) {
        try {
            $h = $group.$Name.TrimStart('#')
            return [System.Drawing.Color]::FromArgb(
                [Convert]::ToInt32($h.Substring(0,2),16),
                [Convert]::ToInt32($h.Substring(2,2),16),
                [Convert]::ToInt32($h.Substring(4,2),16))
        } catch { }
    }
    return [System.Drawing.Color]::FromArgb($Fallback[0], $Fallback[1], $Fallback[2])
}

function New-GlyphIcon {
    
    param(
        [Parameter(Mandatory)][char]$Glyph,
        [Parameter(Mandatory)][System.Drawing.Color]$Color,
        [int]$Size = 32,
        [string]$FontName = 'Segoe UI Symbol',
        [int]$FontSize = 20
    )
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $font = New-Object System.Drawing.Font($FontName, $FontSize, [System.Drawing.FontStyle]::Bold)
        $brush = New-Object System.Drawing.SolidBrush $Color
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString([string]$Glyph, $font, $brush, (New-Object System.Drawing.RectangleF(0,0,$Size,$Size)), $fmt)
    } finally {
        $g.Dispose()
    }
    $hicon = $bmp.GetHicon()
    return [System.Drawing.Icon]::FromHandle($hicon)
}
