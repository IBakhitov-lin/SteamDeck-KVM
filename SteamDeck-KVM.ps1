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

# --- Общий каркас трея (мьютекс, значок, палитра) ---------------------------
# Основной путь — общий модуль на этой машине; запасной — копия в самом
# репозитории, чтобы приложение работало и там, где C:\AI не существует.
$ОбщийКаркас = 'C:\AI\scripts\lib\tray-common.ps1'
if (-not (Test-Path $ОбщийКаркас)) { $ОбщийКаркас = Join-Path $Root 'lib\tray-common.ps1' }
. $ОбщийКаркас

$экземпляр = Get-ЕдинственныйЭкземпляр 'SteamDeckKvmTray'
if (-not $экземпляр.Единственный) {
    Log 'второй экземпляр не нужен: приложение уже в трее'
    exit 0
}

Log '=== запуск приложения ==='
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Log ('сбой: ' + $e.Exception.Message)
})

# ==== Цвета из общего контракта — читает Get-ЦветПалитры из tray-common.ps1 =
$C_OK  = Get-ЦветПалитры 'успех'        @(70,200,120)  -ПутьККонтракту $PalettePath
$C_OFF = Get-ЦветПалитры 'текст_второй' @(160,165,173) -ПутьККонтракту $PalettePath

# ==== Значок рисуется одним рисунком, меняется только цвет ==================
# Символ ⇄ — двусторонний обмен, ровно смысл общей клавиатуры и мыши.
$script:ЗначокОн  = $null
$script:ЗначокОфф = $null
function Значок([bool]$работает) {
    $готовый = if ($работает) { $script:ЗначокОн } else { $script:ЗначокОфф }
    if ($готовый) { return $готовый }
    $цвет = if ($работает) { $C_OK } else { $C_OFF }
    $ico = New-СимвольныйЗначок -Символ ([char]0x21C4) -Цвет $цвет
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
