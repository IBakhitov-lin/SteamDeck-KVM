# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Окно приложения «Общая клавиатура и мышь со Steam Deck»:
# одна кнопка «Включить/Выключить» и видимое состояние связи.
#
# ПОЧЕМУ ОКНО, А НЕ ЗНАЧОК В ТРЕЕ — прежняя версия садилась в трей молча: пользователь
# не видел ни состояния, ни адреса, ни того, найден ли Deck. Окно показывает всё это
# сразу; значок в трее остался, но теперь он вторичен — окно в него сворачивается.
#
# ПОЧЕМУ ПК ВЕЩАЕТ, А DECK СЛУШАЕТ — обратный порядок (Deck ищет, ПК отвечает) потребовал бы
# входящего правила брандмауэра Windows на порт поиска. Исходящая рассылка правила не требует
# вовсе, а одиночный ответ Deck'а Windows пропускает как ответ на свою же рассылку
# (AllowUnicastResponseToMulticast включён по умолчанию). Так связка работает без прав
# администратора и без правки брандмауэра.
#
# ПРОИСХОЖДЕНИЕ — каркас (мьютекс, значок, палитра) взят из общего C:\AI\scripts\lib\tray-common.ps1.

$ErrorActionPreference = 'Stop'

$Root        = $PSScriptRoot
$Core        = 'C:\Program Files\Deskflow\deskflow-core.exe'
$ConfDir     = Join-Path $env:LOCALAPPDATA 'SteamDeck-KVM'
$ServerConf  = Join-Path $ConfDir 'deskflow-server.conf'
$ScreensConf = Join-Path $ConfDir 'screens.conf'
$PairFile    = Join-Path $ConfDir 'pair.json'
$LogFile     = Join-Path $ConfDir 'tray.log'

$KvmPort     = 24800   # порт самого протокола Barrier/Synergy (сервер Deskflow)
$BeaconPort  = 24801   # порт рассылки «я здесь» — его слушает deck-kvm.py на Deck'е
$Protocol    = 'DECKKVM1'

New-Item -ItemType Directory -Path $ConfDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log([string]$Message) {
    try { Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
}
trap { Write-Log ('ТРАП: ' + $_.Exception.Message); continue }

# --- Общий каркас трея (мьютекс, значок, палитра) ---------------------------
$TrayCommonPath = 'C:\AI\scripts\lib\tray-common.ps1'
if (-not (Test-Path $TrayCommonPath)) { $TrayCommonPath = Join-Path $Root 'lib\tray-common.ps1' }
. $TrayCommonPath

$PalettePath = 'C:\AI\templates\palette.json'
if (-not (Test-Path $PalettePath)) { $PalettePath = Join-Path $Root 'lib\palette.json' }

# Второй запуск не поднимает второе окно, а показывает первое: сигнал через именованное
# событие — единственный способ достучаться до чужого процесса без своего канала связи.
$ShowSignal = New-Object System.Threading.EventWaitHandle($false,
    [System.Threading.EventResetMode]::AutoReset, 'Local\SteamDeckKvmShow')

$instance = Get-SingleInstanceLock 'SteamDeckKvmApp'
if (-not $instance.IsOwner) {
    Write-Log 'второй запуск: показываю уже открытое окно'
    $ShowSignal.Set() | Out-Null
    exit 0
}

Write-Log '=== запуск приложения ==='
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-Log ('сбой: ' + $e.Exception.Message)
})

# ==== Цвета из общего контракта ==============================================
$ColorOn    = Get-PaletteColor 'успех'        @(70,200,120)  -ContractPath $PalettePath
$ColorOff   = Get-PaletteColor 'текст_второй' @(160,165,173) -ContractPath $PalettePath
$ColorAccent= Get-PaletteColor 'акцент'       @(110,170,255) -ContractPath $PalettePath
$Bg         = [System.Drawing.Color]::FromArgb(28, 30, 34)
$BgCard     = [System.Drawing.Color]::FromArgb(38, 41, 46)
$Fg         = [System.Drawing.Color]::FromArgb(232, 234, 237)
$FgDim      = [System.Drawing.Color]::FromArgb(150, 155, 163)

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
        [System.Windows.Forms.MessageBox]::Show(
            "Deskflow не установлен по адресу:`n$Core`n`nПоставьте его командой:`nwinget install --id Deskflow.Deskflow --exact",
            'SteamDeck-KVM', 'OK', 'Error') | Out-Null
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

# ==== Поиск Deck'а в сети =====================================================
# Раз в две секунды в каждую подсеть уходит короткая строка «я сервер, вот моё имя и
# состояние». Deck её слышит, отвечает одним пакетом обратно и — если состояние «вкл» —
# подключается сам. Ответ Deck'а и есть «Deck найден»: адрес берётся из самого пакета,
# а не из настроек, поэтому смена адреса в роутере ничего не ломает.

$script:Udp = $null
$script:DeckAddress = $null
$script:DeckName    = $null
$script:DeckSeen    = [datetime]::MinValue
$script:LastBeacon  = [datetime]::MinValue

function Get-BroadcastTargets {
    $targets = New-Object System.Collections.Generic.List[string]
    $targets.Add('255.255.255.255')
    try {
        foreach ($ip in Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue) {
            if ($ip.IPAddress -like '127.*' -or $ip.IPAddress -like '169.254.*') { continue }
            if ($ip.PrefixLength -lt 8 -or $ip.PrefixLength -gt 30) { continue }
            $addr = ([System.Net.IPAddress]::Parse($ip.IPAddress)).GetAddressBytes()
            [array]::Reverse($addr)
            $value = [System.BitConverter]::ToUInt32($addr, 0)
            $mask  = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $ip.PrefixLength))
            $bcast = ($value -band $mask) -bor (-bnot $mask -band 0xFFFFFFFF)
            $bytes = [System.BitConverter]::GetBytes([uint32]$bcast)
            [array]::Reverse($bytes)
            $text = ([System.Net.IPAddress]$bytes).ToString()
            if (-not $targets.Contains($text)) { $targets.Add($text) }
        }
    } catch { }
    return $targets
}

function Get-LocalAddress {
    try {
        $best = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Sort-Object -Property InterfaceMetric |
            Select-Object -First 1
        if ($best) { return $best.IPAddress }
    } catch { }
    return '—'
}

function Open-Beacon {
    if ($script:Udp) { return }
    try {
        $client = New-Object System.Net.Sockets.UdpClient
        $client.EnableBroadcast = $true
        $client.Client.SetSocketOption('Socket', 'ReuseAddress', $true)
        $client.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)))
        $script:Udp = $client
        $script:BroadcastTargets = Get-BroadcastTargets
        Write-Log ('рассылка поиска открыта, подсети: ' + ($script:BroadcastTargets -join ', '))
    } catch {
        Write-Log ('не удалось открыть рассылку поиска: ' + $_.Exception.Message)
    }
}

function Send-Beacon([bool]$IsRunning) {
    if (-not $script:Udp) { return }
    $state = if ($IsRunning) { 'on' } else { 'off' }
    $text = '{0} SERVER {1} {2} {3}' -f $Protocol, $env:COMPUTERNAME, $KvmPort, $state
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    foreach ($target in $script:BroadcastTargets) {
        try { $script:Udp.Send($bytes, $bytes.Length, $target, $BeaconPort) | Out-Null } catch { }
    }
}

function Receive-DeckReplies {
    if (-not $script:Udp) { return }
    while ($script:Udp.Available -gt 0) {
        try {
            $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $data = $script:Udp.Receive([ref]$remote)
            $text = [System.Text.Encoding]::UTF8.GetString($data)
            $parts = $text.Trim() -split '\s+'
            if ($parts.Count -ge 2 -and $parts[0] -eq $Protocol -and $parts[1] -eq 'DECK') {
                $wasNew = ($script:DeckAddress -ne $remote.Address.ToString())
                $script:DeckAddress = $remote.Address.ToString()
                $script:DeckName    = if ($parts.Count -ge 3) { $parts[2] } else { 'steamdeck' }
                $script:DeckSeen    = Get-Date
                if ($wasNew) {
                    Write-Log ('Deck найден: {0} ({1})' -f $script:DeckAddress, $script:DeckName)
                    Save-Pair
                }
            }
        } catch { break }
    }
}

function Save-Pair {
    try {
        $pair = [pscustomobject]@{
            deck_address = $script:DeckAddress
            deck_name    = $script:DeckName
            paired_at    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
        $pair | ConvertTo-Json | Set-Content -LiteralPath $PairFile -Encoding UTF8
    } catch { }
}

function Restore-Pair {
    try {
        if (Test-Path $PairFile) {
            $pair = Get-Content -LiteralPath $PairFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:DeckAddress = $pair.deck_address
            $script:DeckName    = $pair.deck_name
        }
    } catch { }
}

function Test-DeckConnected {
    # Deck подключён — значит на порту протокола есть установленное соединение
    # с его стороны. Это факт из сетевого стека, а не догадка по нашему же журналу.
    try {
        $link = Get-NetTCPConnection -LocalPort $KvmPort -State Established -ErrorAction SilentlyContinue |
            Where-Object { $_.RemoteAddress -notlike '127.*' } | Select-Object -First 1
        if ($link) {
            $script:DeckAddress = $link.RemoteAddress
            return $true
        }
    } catch { }
    return $false
}

# ==== Окно ====================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Общая клавиатура и мышь со Steam Deck'
$form.ClientSize = New-Object System.Drawing.Size(460, 372)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Bg
$form.ForeColor = $Fg
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
try {
    $icoPath = Join-Path $Root 'SteamDeck-KVM.ico'
    if (Test-Path $icoPath) { $form.Icon = New-Object System.Drawing.Icon($icoPath) }
} catch { }

function New-Label([int]$x, [int]$y, [int]$w, [int]$h, [string]$text, $color, [int]$size, [bool]$bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Text = $text
    $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $size, $style)
    return $l
}

# --- карточка состояния ---
$card = New-Object System.Windows.Forms.Panel
$card.Location = New-Object System.Drawing.Point(16, 16)
$card.Size = New-Object System.Drawing.Size(428, 96)
$card.BackColor = $BgCard
$form.Controls.Add($card)

$dot = New-Object System.Windows.Forms.Label
$dot.Location = New-Object System.Drawing.Point(18, 20)
$dot.Size = New-Object System.Drawing.Size(28, 28)
$dot.Text = [string][char]0x25CF
$dot.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 18)
$dot.ForeColor = $ColorOff
$dot.BackColor = [System.Drawing.Color]::Transparent
$card.Controls.Add($dot)

$lblState = New-Label 52 18 356 30 'Выключено' $Fg 15 $true
$card.Controls.Add($lblState)
$lblHint = New-Label 54 50 356 34 'Нажмите «Включить» — Deck подключится сам.' $FgDim 9 $false
$card.Controls.Add($lblHint)

# --- главная кнопка ---
$btnToggle = New-Object System.Windows.Forms.Button
$btnToggle.Location = New-Object System.Drawing.Point(16, 126)
$btnToggle.Size = New-Object System.Drawing.Size(428, 54)
$btnToggle.Text = 'Включить'
$btnToggle.FlatStyle = 'Flat'
$btnToggle.FlatAppearance.BorderSize = 0
$btnToggle.BackColor = $ColorAccent
$btnToggle.ForeColor = [System.Drawing.Color]::FromArgb(16, 18, 22)
$btnToggle.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnToggle)

# --- строки фактов ---
$lblDeckCap = New-Label 18 196 130 20 'Steam Deck' $FgDim 9 $false
$form.Controls.Add($lblDeckCap)
$lblDeck = New-Label 150 196 294 20 'не найден в сети' $Fg 9 $true
$form.Controls.Add($lblDeck)

$lblPcCap = New-Label 18 222 130 20 'Этот компьютер' $FgDim 9 $false
$form.Controls.Add($lblPcCap)
$lblPc = New-Label 150 222 294 20 '' $Fg 9 $true
$form.Controls.Add($lblPc)

$lblEdgeCap = New-Label 18 248 130 20 'Переход' $FgDim 9 $false
$form.Controls.Add($lblEdgeCap)
$lblEdge = New-Label 150 248 294 20 'правый край экрана · Win+Shift+D' $Fg 9 $false
$form.Controls.Add($lblEdge)

# --- нижние кнопки ---
function New-SmallButton([int]$x, [int]$w, [string]$text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Location = New-Object System.Drawing.Point($x, 300)
    $b.Size = New-Object System.Drawing.Size($w, 32)
    $b.Text = $text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 74, 80)
    $b.BackColor = $BgCard
    $b.ForeColor = $Fg
    return $b
}
$btnDeck = New-SmallButton 16 168 'Как настроить Deck'
$btnLog  = New-SmallButton 192 120 'Журнал'
$btnTray = New-SmallButton 320 124 'Свернуть в трей'
$form.Controls.AddRange(@($btnDeck, $btnLog, $btnTray))

# Порядок обхода задаётся явно: иначе случайный пробел или Enter уходит не в главную
# кнопку, а в ту, что оказалась первой по порядку добавления.
$btnToggle.TabIndex = 0
$btnDeck.TabIndex = 1
$btnLog.TabIndex = 2
$btnTray.TabIndex = 3

$lblFoot = New-Label 16 342 428 20 'Закрытие окна выключает сервер. Свернуть в трей — оставить работать.' $FgDim 8 $false
$form.Controls.Add($lblFoot)

# ==== Значок в трее (теперь вторичен) ========================================
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = Get-TrayIcon $false
$ni.Text = 'SteamDeck-KVM'
$ni.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemOpen = $menu.Items.Add('Открыть окно')
$menu.Items.Add('-') | Out-Null
$itemToggle = $menu.Items.Add('Включить')
$menu.Items.Add('-') | Out-Null
$itemExit = $menu.Items.Add('Выход')
$ni.ContextMenuStrip = $menu

# ==== Обновление вида =========================================================
function Update-View {
    $running = Test-ServerRunning
    $connected = $running -and (Test-DeckConnected)
    $seenRecently = ((Get-Date) - $script:DeckSeen).TotalSeconds -lt 15

    if ($connected) {
        $dot.ForeColor = $ColorOn
        $lblState.Text = 'Работает — Deck подключён'
        $lblHint.Text = 'Доведите курсор до правого края экрана или нажмите Win+Shift+D.'
    } elseif ($running) {
        $dot.ForeColor = $ColorAccent
        $lblState.Text = 'Включено — ждём Deck'
        $lblHint.Text = 'Включите Steam Deck: он найдёт этот компьютер сам за несколько секунд.'
    } else {
        $dot.ForeColor = $ColorOff
        $lblState.Text = 'Выключено'
        $lblHint.Text = 'Нажмите «Включить» — Deck подключится сам.'
    }

    $btnToggle.Text = if ($running) { 'Выключить' } else { 'Включить' }
    $btnToggle.BackColor = if ($running) { [System.Drawing.Color]::FromArgb(196, 88, 80) } else { $ColorAccent }
    $itemToggle.Text = $btnToggle.Text

    if ($connected) {
        $lblDeck.Text = '{0} · подключён' -f $script:DeckAddress
        $lblDeck.ForeColor = $ColorOn
    } elseif ($seenRecently) {
        $lblDeck.Text = '{0} · в сети, не подключён' -f $script:DeckAddress
        $lblDeck.ForeColor = $Fg
    } elseif ($script:DeckAddress) {
        $lblDeck.Text = '{0} · был здесь, сейчас не отвечает' -f $script:DeckAddress
        $lblDeck.ForeColor = $FgDim
    } else {
        $lblDeck.Text = 'не найден в сети'
        $lblDeck.ForeColor = $FgDim
    }

    $lblPc.Text = '{0} · {1}' -f $env:COMPUTERNAME, (Get-LocalAddress)

    $ni.Icon = Get-TrayIcon $running
    $ni.Text = if ($connected) { 'SteamDeck-KVM — Deck подключён' }
               elseif ($running) { 'SteamDeck-KVM — ждём Deck' }
               else { 'SteamDeck-KVM — выключено' }
}

function Switch-Server {
    if (Test-ServerRunning) { Stop-Server } else { Start-Server }
    Start-Sleep -Milliseconds 400
    Send-Beacon (Test-ServerRunning)
    Update-View
}

# Windows не отдаёт передний план чужому процессу по одной просьбе: Activate()
# из свёрнутого состояния только мигает кнопкой в панели задач. Нажатие и отпускание
# ALT снимает эту блокировку — иначе повторный клик по ярлыку выглядел бы как «ничего
# не произошло», а именно за этим по ярлыку и кликают.
Add-Type -Namespace Win32 -Name Front -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
'@

function Show-Window {
    $form.Show()
    $handle = $form.Handle
    [Win32.Front]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)          # ALT вниз
    [Win32.Front]::ShowWindow($handle, 9) | Out-Null                  # SW_RESTORE
    [Win32.Front]::SetForegroundWindow($handle) | Out-Null
    [Win32.Front]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)          # ALT вверх
    $form.WindowState = 'Normal'
    $form.Activate()
}

# ==== Обработчики =============================================================
$btnToggle.Add_Click({ Switch-Server })
$itemToggle.Add_Click({ Switch-Server })
$itemOpen.Add_Click({ Show-Window })
$ni.Add_MouseDoubleClick({ Show-Window })

$btnLog.Add_Click({
    try { if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } else { [System.Windows.Forms.MessageBox]::Show('Журнал пока пуст.', 'SteamDeck-KVM') | Out-Null } } catch { }
})

$btnDeck.Add_Click({
    $text = @"
Настройка делается ОДИН раз.

1. Скопируйте папку SteamDeck-KVM на Steam Deck
   (флешкой или через сеть — как удобно).

2. На Deck'е переключитесь в режим рабочего стола,
   откройте Konsole и выполните:

      bash ~/Desktop/SteamDeck-KVM/install-on-deck.sh

   Адрес компьютера указывать НЕ нужно: Deck найдёт его
   по сети сам. Если Deck попросит пароль, которого вы
   не задавали, сначала выполните команду  passwd

3. Всё. Дальше — только включить Deck, открыть это окно
   и нажать «Включить». Соединение поднимется само.

Обе машины должны быть в одной сети Wi-Fi.
"@
    [System.Windows.Forms.MessageBox]::Show($text, 'Как настроить Steam Deck', 'OK', 'Information') | Out-Null
})

$btnTray.Add_Click({
    $form.Hide()
    $ni.ShowBalloonTip(2500, 'SteamDeck-KVM', 'Приложение работает в трее. Двойной клик по значку — открыть окно.', 'Info')
})

# Application::Exit() закрывает форму повторно, и обработчик входит сам в себя —
# отсюда флаг: выход выполняется ровно один раз.
$script:Quitting = $false
$form.Add_FormClosing({
    param($s, $e)
    if ($script:Quitting) { return }
    $script:Quitting = $true
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        Stop-Server
        Send-Beacon $false
    }
    $timer.Stop()
    $ni.Visible = $false
    Write-Log '=== выход ==='
    [System.Windows.Forms.Application]::Exit()
})

$itemExit.Add_Click({
    Stop-Server
    Send-Beacon $false
    $ni.Visible = $false
    Write-Log '=== выход из трея ==='
    [System.Windows.Forms.Application]::Exit()
})

# ==== Часы приложения =========================================================
# Один таймер на всё: рассылка маячка, разбор ответов Deck'а, сверка вида с фактом.
# Отдельные потоки в WinForms из PowerShell дают больше поломок, чем экономят.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        Receive-DeckReplies
        if (((Get-Date) - $script:LastBeacon).TotalSeconds -ge 2) {
            $script:LastBeacon = Get-Date
            Send-Beacon (Test-ServerRunning)
        }
        if ($ShowSignal.WaitOne(0)) { Show-Window }
        Update-View
    } catch {
        Write-Log ('таймер: ' + $_.Exception.Message)
    }
})

Restore-Pair
Open-Beacon
Update-View
$timer.Start()

# Первое окно процесса Windows показывает так, как велено в STARTUPINFO запускающего,
# а запускает нас VBS со скрытым окном (иначе мигала бы консоль PowerShell). Поэтому
# Show() одного мало: окно уехало бы в панель задач свёрнутым. Show-Window снимает это
# явным SW_RESTORE — ровно тем же путём, что и повторный клик по ярлыку.
Write-Log 'окно открыто'
Show-Window
[System.Windows.Forms.Application]::Run()
