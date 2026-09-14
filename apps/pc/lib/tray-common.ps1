# КОПИЯ общего модуля, собранная build_release_script.py из общего исходника.
# Правится исходник, а не копия: копия перезаписывается при каждой сборке выпуска.
# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Общий каркас приложения со значком в трее: единственный
# экземпляр через мьютекс, значок NotifyIcon, цвет из контракта palette.json.
#
# ПРОИСХОЖДЕНИЕ — вынесено 08.09.2026 из SteamDeck-KVM.ps1, который списал устройство у
# соседний проект (private_tools/scripts/соседний проект_tray.ps1). SteamDeck-KVM — уже ВТОРОЙ потребитель
# одного и того же каркаса (workflow.md, «Общая механика выносится при ВТОРОМ потребителе»),
# и вынесение сделано сюда, а не правкой живого соседний проект_tray.ps1 — тот остаётся нетронутым:
# перевод соседний проект на этот модуль отдельным долгом лежит в backlog.md ГСИ.
#
# Подключается точкой (dot-source) из тела приложения:
#   . 'tray-common.ps1'
#
# Что даёт:
#   Get-SingleInstanceLock  — мьютекс на всё приложение
#   Get-PaletteColor        — hex-цвет из контракта, с запасным значением
#   New-GlyphIcon           — Icon, нарисованный одним символом Unicode

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

function Get-SingleInstanceLock {
    <#
    .SYNOPSIS
    Захватывает именованный мьютекс. .IsOwner = $true, если экземпляр единственный.
    #>
    param(
        [Parameter(Mandatory)][string]$Name
    )
    $mutex = New-Object System.Threading.Mutex($false, "Local\$Name")
    try { $owns = $mutex.WaitOne(0) } catch { $owns = $false }
    return [PSCustomObject]@{ Mutex = $mutex; IsOwner = $owns }
}

$script:PaletteCache = $null
function Get-PaletteColor {
    <#
    .SYNOPSIS
    Цвет из палитры (по умолчанию palette.json, тема 'тёмная').
    Отсутствие файла или поля не считается ошибкой — отдаётся запасной цвет.
    #>
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
    <#
    .SYNOPSIS
    Рисует значок 32x32 одним символом Unicode нужного цвета — контракт палитры
    требует «один рисунок, меняется только цвет», это и даёт наименьшую реализацию.
    #>
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
