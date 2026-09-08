# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Значок в трее для общей клавиатуры и мыши со Steam Deck:
# одно приложение вместо пары ярлыков «включить/выключить».
# ПРОИСХОЖДЕНИЕ — устройство скопировано у JobRadar (private_tools/scripts/jobradar_tray.ps1):
# единственный экземпляр через мьютекс, значок NotifyIcon, тёмная палитра из общего контракта.
# Здесь список сокращён до своего размера: нет окна, нет журнала вакансий — есть только
# состояние «сервер работает / не работает» и переключатель.
#
#   Значок в трее      — цвет говорит о состоянии: акцент — работает, серый — нет
#   ЛКМ по значку      — переключить (включить, если выключено, и наоборот)
#   ПКМ по значку      — меню: Включить / Выключить, Открыть журнал, Выход
#   Выход из трея      — останавливает сервер и убирает значок

$ErrorActionPreference = 'Stop'

$Root         = $PSScriptRoot
$Core         = 'C:\Program Files\Deskflow\deskflow-core.exe'
$ConfDir      = Join-Path $env:LOCALAPPDATA 'SteamDeck-KVM'
$ServerConf   = Join-Path $ConfDir 'deskflow-server.conf'
$LogFile      = Join-Path $ConfDir 'трей.log'
$PalettePath  = 'C:\AI\templates\палитра.json'

New-Item -ItemType Directory -Path $ConfDir -Force -ErrorAction SilentlyContinue | Out-Null

function Log([string]$m) {
    try { Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch { }
}
trap { Log ('ТРАП: ' + $_.Exception.Message); continue }

# --- Один экземпляр ---------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\SteamDeckKvmTray')
try { $owns = $mutex.WaitOne(0) } catch { $owns = $false }
if (-not $owns) {
    Log 'второй экземпляр не нужен: приложение уже в трее'
    exit 0
}

Log '=== запуск приложения ==='
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Log ('сбой: ' + $e.Exception.Message)
})

# ==== Цвета из общего контракта, а не числами здесь =========================
function Цвет([string]$hex, [int[]]$запас) {
    try {
        $h = $hex.TrimStart('#')
        return [System.Drawing.Color]::FromArgb(
            [Convert]::ToInt32($h.Substring(0,2),16),
            [Convert]::ToInt32($h.Substring(2,2),16),
            [Convert]::ToInt32($h.Substring(4,2),16))
    } catch { return [System.Drawing.Color]::FromArgb($запас[0], $запас[1], $запас[2]) }
}
$тема = $null
try { $тема = (Get-Content -LiteralPath $PalettePath -Raw -Encoding UTF8 | ConvertFrom-Json).'тёмная' } catch { }
function ИзТемы([string]$имя, [int[]]$запас) {
    if ($тема -and $тема.$имя) { return Цвет $тема.$имя $запас }
    return [System.Drawing.Color]::FromArgb($запас[0], $запас[1], $запас[2])
}
$C_OK   = ИзТемы 'успех'        @(70,200,120)
$C_OFF  = ИзТемы 'текст_второй' @(160,165,173)
$C_BG   = ИзТемы 'фон'          @(21,21,23)

# ==== Значок рисуется одним рисунком, меняется только цвет ==================
# Символ ⇄ — двусторонний обмен, ровно смысл общей клавиатуры и мыши.
$script:ЗначокОн  = $null
$script:ЗначокОфф = $null
function Значок([bool]$работает) {
    $готовый = if ($работает) { $script:ЗначокОн } else { $script:ЗначокОфф }
    if ($готовый) { return $готовый }
    $цвет = if ($работает) { $C_OK } else { $C_OFF }
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $font = New-Object System.Drawing.Font('Segoe UI Symbol', 20, [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush $цвет
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString([char]0x21C4, $font, $brush, (New-Object System.Drawing.RectangleF(0,0,32,32)), $fmt)
    $g.Dispose()
    $hicon = $bmp.GetHicon()
    $ico = [System.Drawing.Icon]::FromHandle($hicon)
    if ($работает) { $script:ЗначокОн = $ico } else { $script:ЗначокОфф = $ico }
    return $ico
}

# ==== Состояние сервера ======================================================
function Работает { return [bool](Get-Process deskflow-core -ErrorAction SilentlyContinue) }

function Включить {
    if (Работает) { return }
    if (-not (Test-Path $Core)) {
        Log "ОШИБКА: не найден $Core"
        [System.Windows.Forms.MessageBox]::Show("Deskflow не установлен:`n$Core", 'SteamDeck-KVM', 'OK', 'Error') | Out-Null
        return
    }
    if (-not (Test-Path $ServerConf)) {
        Log "ОШИБКА: нет конфигурации $ServerConf"
        [System.Windows.Forms.MessageBox]::Show("Не найдена настройка сервера:`n$ServerConf", 'SteamDeck-KVM', 'OK', 'Error') | Out-Null
        return
    }
    try {
        Start-Process -FilePath $Core -ArgumentList @('server','--new-instance','-s',$ServerConf) -WindowStyle Hidden
        Log 'сервер включён'
    } catch {
        Log ('не удалось включить: ' + $_.Exception.Message)
    }
}

function Выключить {
    if (-not (Работает)) { return }
    try {
        Get-Process deskflow-core -ErrorAction SilentlyContinue | Stop-Process -Force
        Log 'сервер выключен'
    } catch {
        Log ('не удалось выключить: ' + $_.Exception.Message)
    }
}

function Переключить {
    if (Работает) { Выключить } else { Включить }
    ОбновитьВид
}

# ==== Значок в трее и меню ====================================================
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = Значок (Работает)
$ni.Text = 'SteamDeck-KVM'
$ni.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemToggle = $menu.Items.Add('Включить')
$itemToggle.Add_Click({ Переключить })
$menu.Items.Add('-') | Out-Null
$itemLog = $menu.Items.Add('Открыть журнал')
$itemLog.Add_Click({
    try { if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } } catch { }
})
$menu.Items.Add('-') | Out-Null
$itemExit = $menu.Items.Add('Выход')
$itemExit.Add_Click({
    Выключить
    $ni.Visible = $false
    Log '=== выход из трея ==='
    [System.Windows.Forms.Application]::Exit()
})
$ni.ContextMenuStrip = $menu

function ОбновитьВид {
    $идёт = Работает
    $ni.Icon = Значок $идёт
    $ni.Text = if ($идёт) { 'SteamDeck-KVM — работает' } else { 'SteamDeck-KVM — выключено' }
    $itemToggle.Text = if ($идёт) { 'Выключить' } else { 'Включить' }
}
ОбновитьВид

$ni.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Переключить
    }
})

# Значок перерисовывается сам, если сервер упал не через меню (например, сеть
# легла и процесс завершился) — таймер раз в пять секунд сверяет вид с фактом.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ ОбновитьВид })
$timer.Start()

Log 'значок поднят, ждём действия пользователя'
[System.Windows.Forms.Application]::Run()
