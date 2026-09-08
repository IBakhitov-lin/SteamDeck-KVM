# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Значок в трее для общей клавиатуры и мыши со Steam Deck:
# одно приложение вместо пары ярлыков «включить/выключить».
# ПРОИСХОЖДЕНИЕ — каркас (мьютекс, значок, палитра) взят из общего C:\AI\scripts\lib\tray-common.ps1,
# вынесенного 08.09.2026 из устройства JobRadar (private_tools/scripts/jobradar_tray.ps1) — это
# уже второй потребитель того же каркаса. Здесь своё — только состояние сервера и переключатель.
#
#   Значок в трее      — цвет говорит о состоянии: акцент — работает, серый — нет
#   ЛКМ по значку      — переключить (включить, если выключено, и наоборот)
#   ПКМ по значку      — меню: Включить / Выключить, Открыть журнал, Выход
#   Выход из трея      — останавливает сервер и убирает значок

$ErrorActionPreference = 'Stop'

$Root        = $PSScriptRoot
$Core        = 'C:\Program Files\Deskflow\deskflow-core.exe'
$ConfDir     = Join-Path $env:LOCALAPPDATA 'SteamDeck-KVM'
$ServerConf  = Join-Path $ConfDir 'deskflow-server.conf'
$LogFile     = Join-Path $ConfDir 'tray.log'

New-Item -ItemType Directory -Path $ConfDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log([string]$Message) {
    try { Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
}
trap { Write-Log ('ТРАП: ' + $_.Exception.Message); continue }

# --- Общий каркас трея (мьютекс, значок, палитра) ---------------------------
# Основной путь — общий модуль на этой машине; запасной — копия в самом
# репозитории, чтобы приложение работало и там, где C:\AI не существует.
$TrayCommonPath = 'C:\AI\scripts\lib\tray-common.ps1'
if (-not (Test-Path $TrayCommonPath)) { $TrayCommonPath = Join-Path $Root 'lib\tray-common.ps1' }
. $TrayCommonPath

# То же для контракта цветов: реальный канон на этой машине, иначе — вендорная
# копия рядом (lib\palette.json), чтобы вид не менялся от того, где запущено.
$PalettePath = 'C:\AI\templates\палитра.json'
if (-not (Test-Path $PalettePath)) { $PalettePath = Join-Path $Root 'lib\palette.json' }

$instance = Get-SingleInstanceLock 'SteamDeckKvmTray'
if (-not $instance.IsOwner) {
    Write-Log 'второй экземпляр не нужен: приложение уже в трее'
    exit 0
}

Write-Log '=== запуск приложения ==='
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-Log ('сбой: ' + $e.Exception.Message)
})

# ==== Цвета из общего контракта — читает Get-PaletteColor из tray-common.ps1 =
$ColorOn  = Get-PaletteColor 'успех'        @(70,200,120)  -ContractPath $PalettePath
$ColorOff = Get-PaletteColor 'текст_второй' @(160,165,173) -ContractPath $PalettePath

# ==== Значок рисуется одним рисунком, меняется только цвет ==================
# Символ ⇄ — двусторонний обмен, ровно смысл общей клавиатуры и мыши.
$script:IconOn  = $null
$script:IconOff = $null
function Get-TrayIcon([bool]$IsRunning) {
    $cached = if ($IsRunning) { $script:IconOn } else { $script:IconOff }
    if ($cached) { return $cached }
    $color = if ($IsRunning) { $ColorOn } else { $ColorOff }
    $icon = New-GlyphIcon -Glyph ([char]0x21C4) -Color $color
    if ($IsRunning) { $script:IconOn = $icon } else { $script:IconOff = $icon }
    return $icon
}

# ==== Состояние сервера ======================================================
function Test-ServerRunning { return [bool](Get-Process deskflow-core -ErrorAction SilentlyContinue) }

function Start-Server {
    if (Test-ServerRunning) { return }
    if (-not (Test-Path $Core)) {
        Write-Log "ОШИБКА: не найден $Core"
        [System.Windows.Forms.MessageBox]::Show("Deskflow не установлен:`n$Core", 'SteamDeck-KVM', 'OK', 'Error') | Out-Null
        return
    }
    if (-not (Test-Path $ServerConf)) {
        Write-Log "ОШИБКА: нет конфигурации $ServerConf"
        [System.Windows.Forms.MessageBox]::Show("Не найдена настройка сервера:`n$ServerConf", 'SteamDeck-KVM', 'OK', 'Error') | Out-Null
        return
    }
    try {
        Start-Process -FilePath $Core -ArgumentList @('server','--new-instance','-s',$ServerConf) -WindowStyle Hidden
        Write-Log 'сервер включён'
    } catch {
        Write-Log ('не удалось включить: ' + $_.Exception.Message)
    }
}

function Stop-Server {
    if (-not (Test-ServerRunning)) { return }
    try {
        Get-Process deskflow-core -ErrorAction SilentlyContinue | Stop-Process -Force
        Write-Log 'сервер выключен'
    } catch {
        Write-Log ('не удалось выключить: ' + $_.Exception.Message)
    }
}

function Switch-Server {
    if (Test-ServerRunning) { Stop-Server } else { Start-Server }
    Update-TrayView
}

# ==== Значок в трее и меню ====================================================
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = Get-TrayIcon (Test-ServerRunning)
$ni.Text = 'SteamDeck-KVM'
$ni.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemToggle = $menu.Items.Add('Включить')
$itemToggle.Add_Click({ Switch-Server })
$menu.Items.Add('-') | Out-Null
$itemLog = $menu.Items.Add('Открыть журнал')
$itemLog.Add_Click({
    try { if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } } catch { }
})
$menu.Items.Add('-') | Out-Null
$itemExit = $menu.Items.Add('Выход')
$itemExit.Add_Click({
    Stop-Server
    $ni.Visible = $false
    Write-Log '=== выход из трея ==='
    [System.Windows.Forms.Application]::Exit()
})
$ni.ContextMenuStrip = $menu

function Update-TrayView {
    $running = Test-ServerRunning
    $ni.Icon = Get-TrayIcon $running
    $ni.Text = if ($running) { 'SteamDeck-KVM — работает' } else { 'SteamDeck-KVM — выключено' }
    $itemToggle.Text = if ($running) { 'Выключить' } else { 'Включить' }
}
Update-TrayView

$ni.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Switch-Server
    }
})

# Значок перерисовывается сам, если сервер упал не через меню (например, сеть
# легла и процесс завершился) — таймер раз в пять секунд сверяет вид с фактом.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-TrayView })
$timer.Start()

Write-Log 'значок поднят, ждём действия пользователя'
[System.Windows.Forms.Application]::Run()
