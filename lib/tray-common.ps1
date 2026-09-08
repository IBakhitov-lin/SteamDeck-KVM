# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Общий каркас приложения со значком в трее: единственный
# экземпляр через мьютекс, значок NotifyIcon, цвет из внешнего контракта палитры.
#
# ЭТО ВЕНДОРНАЯ КОПИЯ. Исходник — C:\AI\scripts\lib\tray-common.ps1, общий для нескольких
# приложений на этой машине. SteamDeck-KVM.ps1 сначала пробует его, и только если файла нет
# (репозиторий склонирован не на этой машине — например, публично) — берёт эту копию рядом.
# Правка исходника при следующем изменении может не долететь досюда — это цена переносимости.
#
# Подключается точкой (dot-source) из тела приложения:
#   . 'C:\AI\scripts\lib\tray-common.ps1'
#
# Что даёт:
#   Get-ЕдинственныйЭкземпляр  — мьютекс на всё приложение
#   Get-ЦветПалитры            — hex-цвет из контракта, с запасным значением
#   New-СимвольныйЗначок       — Icon, нарисованный одним символом Unicode

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

function Get-ЕдинственныйЭкземпляр {
    <#
    .SYNOPSIS
    Захватывает именованный мьютекс. Возвращает $true, если экземпляр единственный.
    #>
    param(
        [Parameter(Mandatory)][string]$Имя
    )
    $mutex = New-Object System.Threading.Mutex($false, "Local\$Имя")
    try { $owns = $mutex.WaitOne(0) } catch { $owns = $false }
    return [PSCustomObject]@{ Мьютекс = $mutex; Единственный = $owns }
}

$script:ПалитраКэш = $null
function Get-ЦветПалитры {
    <#
    .SYNOPSIS
    Цвет из C:\AI\templates\палитра.json. Тема по умолчанию — 'тёмная'.
    Отсутствие файла или поля не считается ошибкой — отдаётся запасной цвет.
    #>
    param(
        [Parameter(Mandatory)][string]$Имя,
        [Parameter(Mandatory)][int[]]$Запас,
        [string]$Тема = 'тёмная',
        [string]$ПутьККонтракту = 'C:\AI\templates\палитра.json'
    )
    if ($null -eq $script:ПалитраКэш) {
        $script:ПалитраКэш = @{}
        try {
            $json = Get-Content -LiteralPath $ПутьККонтракту -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:ПалитраКэш[$Тема] = $json.$Тема
        } catch { }
    }
    $группа = $script:ПалитраКэш[$Тема]
    if ($группа -and $группа.$Имя) {
        try {
            $h = $группа.$Имя.TrimStart('#')
            return [System.Drawing.Color]::FromArgb(
                [Convert]::ToInt32($h.Substring(0,2),16),
                [Convert]::ToInt32($h.Substring(2,2),16),
                [Convert]::ToInt32($h.Substring(4,2),16))
        } catch { }
    }
    return [System.Drawing.Color]::FromArgb($Запас[0], $Запас[1], $Запас[2])
}

function New-СимвольныйЗначок {
    <#
    .SYNOPSIS
    Рисует значок 32x32 одним символом Unicode нужного цвета — контракт палитры
    требует «один рисунок, меняется только цвет», это и даёт наименьшую реализацию.
    #>
    param(
        [Parameter(Mandatory)][char]$Символ,
        [Parameter(Mandatory)][System.Drawing.Color]$Цвет,
        [int]$Размер = 32,
        [string]$Шрифт = 'Segoe UI Symbol',
        [int]$КеглЬ = 20
    )
    $bmp = New-Object System.Drawing.Bitmap($Размер, $Размер)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $font = New-Object System.Drawing.Font($Шрифт, $КеглЬ, [System.Drawing.FontStyle]::Bold)
        $brush = New-Object System.Drawing.SolidBrush $Цвет
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString([string]$Символ, $font, $brush, (New-Object System.Drawing.RectangleF(0,0,$Размер,$Размер)), $fmt)
    } finally {
        $g.Dispose()
    }
    $hicon = $bmp.GetHicon()
    return [System.Drawing.Icon]::FromHandle($hicon)
}
