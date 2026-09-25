# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Приложение «Общая клавиатура и мышь со Steam Deck»:
# одна кнопка «Включить/Выключить», видимое состояние связи и знакомство с Deck'ом.
#
# ОБОЛОЧКА ЗДЕСЬ НЕ ЖИВЁТ. Окно, палитра, гарнитура, радиусы и диалоги собираются
# в app-window.ps1 — тот же файл читает сторож компоновки check-window-layout.ps1.
# Здесь только поведение: состояние сервера, рассылка поиска, память о паре.
#
# ПОЧЕМУ ПК ВЕЩАЕТ, А DECK СЛУШАЕТ — обратный порядок (Deck ищет, ПК отвечает)
# потребовал бы входящего правила брандмауэра Windows, то есть прав администратора
# при установке. Исходящая рассылка правила не требует вовсе, а одиночный ответ
# Deck'а Windows пропускает как ответ на свою же рассылку.
#
# ПОЧЕМУ ПАРА ЗАПОМИНАЕТСЯ ПО НОМЕРУ, А НЕ ПО АДРЕСУ — адрес меняется при каждой
# смене сети; номер устройства не меняется никогда. Машины узнают друг друга так
# же, как это делают наушники: один раз познакомились — дальше по номеру.

# После обновления приложение перезапускает само себя; новый экземпляр ждёт, пока старый
# отпустит замок единственного экземпляра, а не показывает окно старому и не выходит.
param([switch]$AfterUpdate)

$ErrorActionPreference = 'Stop'

$Root       = $PSScriptRoot
# Версия лежит рядом в архиве выпуска и в корне репозитория при запуске из рабочей копии.
$VersionFile = @((Join-Path $Root 'VERSION'), (Join-Path $Root '..\..\VERSION')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$Version    = if ($VersionFile) { (Get-Content -LiteralPath $VersionFile -Raw).Trim() } else { '0.0.0' }
# Рабочая копия репозитория обновляется через git: обновление из архива поверх неё затёрло бы
# несохранённую работу. Признак — папка .git двумя уровнями выше приложения.
$IsDevCheckout = Test-Path -LiteralPath (Join-Path $Root '..\..\.git')
$ReleasesUrl = if ($env:STEAMDECK_KVM_RELEASES_URL) { $env:STEAMDECK_KVM_RELEASES_URL } `
               else { 'https://api.github.com/repos/IBakhitov-lin/SteamDeck-KVM/releases/latest' }
$ReleasesPage = 'https://github.com/IBakhitov-lin/SteamDeck-KVM/releases/latest'
$Core       = 'C:\Program Files\Deskflow\deskflow-core.exe'
$ConfDir    = Join-Path $env:LOCALAPPDATA 'SteamDeck-KVM'
$ServerConf = Join-Path $ConfDir 'deskflow-server.conf'
$ScreensConf = Join-Path $ConfDir 'screens.conf'
$PairFile   = Join-Path $ConfDir 'pair.json'
$LogFile    = Join-Path $ConfDir 'tray.log'
$SettingsFile = Join-Path $ConfDir 'settings.json'

$KvmPort    = 24800   # порт протокола Barrier/Synergy (сервер Deskflow)
$BeaconPort = 24801   # порт рассылки знакомства — его слушает deck-kvm.py
$Protocol   = 'DECKKVM2'

New-Item -ItemType Directory -Path $ConfDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log([string]$Message) {
    try { Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
}
trap { Write-Log ('ТРАП: ' + $_.Exception.Message + ' | ' + $_.InvocationInfo.ScriptName + ':' + $_.InvocationInfo.ScriptLineNumber + ' | ' + $_.InvocationInfo.Line.Trim()); continue }

. (Join-Path $Root 'app-window.ps1')
. (Join-Path $Root 'app-update.ps1')

. (Join-Path $Root 'lib\tray-common.ps1')

# Второй запуск не поднимает второе окно, а показывает первое. Опрос идёт раз в
# секунду — правило окна — не реже чем раз в полсекунды по ощущению человека,
# и секунда здесь граница: ответ медленнее человек принимает за отказ.
$ShowSignal = New-Object System.Threading.EventWaitHandle($false,
    [System.Threading.EventResetMode]::AutoReset, 'Local\SteamDeckKvmShow')

$instance = Get-SingleInstanceLock 'SteamDeckKvmApp'
if (-not $instance.IsOwner -and $AfterUpdate) {
    # Старый экземпляр выходит сам сразу после запуска нового; ждём его, а не показываем ему окно.
    try { $instance.IsOwner = $instance.Mutex.WaitOne(15000) }
    catch [System.Threading.AbandonedMutexException] { $instance.IsOwner = $true }
}
if (-not $instance.IsOwner) {
    Write-Log 'второй запуск: показываю уже открытое окно'
    # Право вывести окно вперёд есть у процесса, запущенного щелчком человека, а у давно работающего
    # первого экземпляра его нет: без передачи права окно поднималось позади остальных и только мигало
    # на панели задач. ASFW_ANY (-1) передаёт право; первый экземпляр пользуется им до ввода человека.
    try {
        Add-Type -Namespace Win32 -Name Foreground -MemberDefinition '[DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);'
        [Win32.Foreground]::AllowSetForegroundWindow(-1) | Out-Null
    } catch { Write-Log ('право вывести окно вперёд не передано: ' + $_.Exception.Message) }
    $ShowSignal.Set() | Out-Null
    exit 0
}

Write-Log '=== запуск приложения ==='
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-Log ('сбой: ' + $e.Exception.Message)
})

# ==== Кто мы: постоянный номер этой машины ===================================
$script:Pair = [pscustomobject]@{
    pc_id        = $null
    deck_id      = $null
    deck_name    = $null
    deck_address = $null
    paired_at    = $null
}

function Load-Pair {
    try {
        if (Test-Path $PairFile) {
            $saved = Get-Content -LiteralPath $PairFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($поле in 'pc_id', 'deck_id', 'deck_name', 'deck_address', 'paired_at') {
                if ($saved.$поле) { $script:Pair.$поле = $saved.$поле }
            }
        }
    } catch { Write-Log ('память о паре не прочиталась: ' + $_.Exception.Message) }
    if (-not $script:Pair.pc_id) {
        $script:Pair.pc_id = [guid]::NewGuid().ToString('N')
        Save-Pair
        Write-Log ('заведён постоянный номер этого компьютера: ' + $script:Pair.pc_id)
    }
}

function Save-Pair {
    # Без служебной метки кодировки: `Set-Content -Encoding UTF8` ставит её всегда, а память
    # пары читает не только это приложение: такая же метка в настройке уже роняла Deskflow.
    # Файлу данных метка не нужна ни одному читателю, а сломать может любого.
    try {
        [System.IO.File]::WriteAllText($PairFile, ($script:Pair | ConvertTo-Json),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Forget-Deck {
    $script:Pair.deck_id = $null
    $script:Pair.deck_name = $null
    $script:Pair.deck_address = $null
    $script:Pair.paired_at = $null
    $script:DeckSeen = [datetime]::MinValue
    Save-Pair
    Write-Log 'пара забыта: следующий откликнувшийся Deck станет новым'
}

# ==== Настройки приложения ===================================================
# Три выбора человека, окно «Настройки»: переход по Alt+Tab, переход краем экрана и сторона Deck'а.
# Всё прочее выводимо и не настраивается. Обновление — только по нажатию человека.
$script:Settings = @{ alt_tab = $true; edge = $true; side = 'right' }

function Load-Settings {
    try {
        if (Test-Path -LiteralPath $SettingsFile) {
            $с = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($к in @('alt_tab', 'edge')) { if ($null -ne $с.$к) { $script:Settings[$к] = [bool]$с.$к } }
            if ([string]$с.side -in @('left', 'right')) { $script:Settings.side = [string]$с.side }
            return
        }
        # Первый запуск с настройками: сторону Deck'а человек мог поменять руками в прежней
        # раскладке — она переносится, а не сбрасывается.
        if (Test-Path -LiteralPath $ScreensConf) {
            $имяПК = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'pc' }
            $прежняя = [System.IO.File]::ReadAllText($ScreensConf)
            if ($прежняя -match ('(?ms)^\s*' + [regex]::Escape($имяПК) + ':\s*\r?\n\s*left\s*=\s*steamdeck')) { $script:Settings.side = 'left' }
        }
    } catch { Write-Log ('настройки не прочитались, взяты по умолчанию: ' + $_.Exception.Message) }
}

function Save-Settings {
    try {
        [System.IO.File]::WriteAllText($SettingsFile, ($script:Settings | ConvertTo-Json),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log ('настройки не записались: ' + $_.Exception.Message) }
}

# ==== Настройка сервера: создаётся сама, а не требуется от человека ==========
# Файла настройки может не быть по трём причинам: первый запуск, чистка папки
# AppData, перенос на другую машину. Во всех трёх человеку сообщать не о чем —
# содержимое файла целиком выводимо: имя этого компьютера, имя экрана Deck'а,
# порт и сторона перехода. Прежняя версия вместо этого показывала окно «Не
# найден файл настройки… восстановите его из папки приложения», то есть просила
# человека сделать за приложение работу, которую оно умеет делать само.
#
# Имя экрана берётся из имени компьютера, а не пишется строкой: зашитое имя одного компьютера
# работало ровно на одной машине, а на любой другой сервер не находил своего
# экрана в раскладке и молча не поднимал переход.
# Настройку читает ЧУЖАЯ программа — deskflow-core. `Set-Content -Encoding UTF8`
# в Windows PowerShell ставит в начало файла служебную метку кодировки (три
# байта EF BB BF), и Deskflow об неё спотыкается: замер 12.09.2026 — сервер не
# поднимался вовсе, порт 24800 не слушал никто, а в журнале приложения при этом
# стояло «сервер включён». Тот же файл без метки поднимает сервер сразу.
function Записать-БезМетки([string]$Путь, [string]$Текст) {
    [System.IO.File]::WriteAllText($Путь, $Текст, (New-Object System.Text.UTF8Encoding($false)))
}

# Файл, записанный прежней версией, чинится сам: иначе человек остаётся с
# настройкой, которая выглядит целой и не работает, — и ему нечего искать.
function Снять-Метку([string]$Путь) {
    try {
        if (-not (Test-Path $Путь)) { return }
        $байты = [System.IO.File]::ReadAllBytes($Путь)
        if ($байты.Length -lt 3) { return }
        if ($байты[0] -ne 0xEF -or $байты[1] -ne 0xBB -or $байты[2] -ne 0xBF) { return }
        $текст = [System.Text.Encoding]::UTF8.GetString($байты, 3, $байты.Length - 3)
        Записать-БезМетки $Путь $текст
        Write-Log "снята служебная метка кодировки с $Путь — Deskflow её не читает"
    } catch {
        Write-Log ('не удалось снять метку: ' + $_.Exception.Message)
    }
}

$МеткаРаскладки = '# steamdeck-kvm-layout v4'

# Служебные клавиши приложения. Сочетание для человека одно — Alt+Tab; его Windows горячей клавишей
# не отдаёт, поэтому переход делает само приложение: нажимает программой служебное сочетание, которое
# ловит сервер. F23 и F24 на клавиатурах нет — человек их не нажмёт и ничего своего ими не занимает.
# Живой замер 23.09.2026 (Deskflow 1.26): программное нажатие переводит на Deck за 0,03 с и
# возвращает с Deck'а, и без края экрана — переход не зависит от того, включён ли край.
$КлавишаНаDeck = 0x86     # F23
$КлавишаНаПК   = 0x87     # F24

function Текст-Раскладки([string]$ИмяПК, [string]$Метка, [bool]$Край, [string]$Сторона) {
    # Чистая функция: текст раскладки из настроек — её зовёт Ensure-Config и проверяет тест.
    $сторона = $Сторона
    $обратно = if ($сторона -eq 'right') { 'left' } else { 'right' }
    # Край экрана — это раздел links: без него сервер переводит только служебными клавишами.
    $связи = if ($Край) { @"

section: links
	${ИмяПК}:
		$сторона = steamdeck
	steamdeck:
		$обратно = $ИмяПК
end
"@ } else { '' }
    $раскладка = @"
$Метка
# Раскладка экранов собирается приложением «Общая клавиатура и мышь» из его настроек
# (окно «Настройки»: край экрана и сторона Deck'а). Правка руками перезаписывается.

section: screens
	${ИмяПК}:
	steamdeck:
end
$связи
section: options
	# Переход мгновенный: задержка у края делала переход на Deck заметно медленным.
	switchDelay = 0
	switchDoubleTap = 0
	# Служебные клавиши приложения, не для человека: их нажимает само приложение по Alt+Tab и
	# кнопкам «Перейти». Клавиш F23 и F24 на клавиатурах нет.
	keystroke(Control+Alt+Shift+F23) = switchToScreen(steamdeck)
	keystroke(Control+Alt+Shift+F24) = switchToScreen($ИмяПК)
end
"@
    return $раскладка
}

function Ensure-Config {
    # Возвращает, изменилась ли раскладка: сервер читает её только при старте.
    $имяПК = $env:COMPUTERNAME
    if (-not $имяПК) { $имяПК = 'pc' }

    Снять-Метку $ServerConf
    Снять-Метку $ScreensConf

    $изменено = $false
    $метка = '{0} edge={1} side={2}' -f $МеткаРаскладки, [int][bool]$script:Settings.edge, $script:Settings.side
    $прежняя = if (Test-Path $ScreensConf) { [System.IO.File]::ReadAllText($ScreensConf) } else { '' }
    # Своя ли раскладка — по метке либо по шапке прежней версии приложения. Чужую, написанную
    # руками без метки, приложение не трогает никогда.
    $своя = ($прежняя -eq '') -or $прежняя.StartsWith('# steamdeck-kvm-layout') -or
            $прежняя.Contains('Раскладка экранов для общей клавиатуры и мыши')
    $перваяСтрока = ($прежняя -split "`r?`n")[0]
    if ($своя -and $перваяСтрока -ne $метка) {
        $раскладка = Текст-Раскладки $имяПК $метка ([bool]$script:Settings.edge) $script:Settings.side
        Записать-БезМетки $ScreensConf $раскладка
        $изменено = $true
        Write-Log "раскладка экранов пересобрана ($метка)"
    }

    if (-not (Test-Path $ServerConf)) {
        $путьРаскладки = $ScreensConf -replace '\\', '/'
        $настройка = @"
[core]
coreMode=server
computerName=$имяПК
port=$KvmPort
useHooks=true
preventSleep=false

[security]
tlsEnabled=false
checkPeerFingerprints=false

[server]
externalConfig=true
externalConfigFile=$путьРаскладки

[log]
level=INFO
"@
        Записать-БезМетки $ServerConf $настройка
        Write-Log "создана настройка сервера $ServerConf"
        $изменено = $true
    }
    return $изменено
}

# ==== Состояние сервера ======================================================
function Test-ServerRunning { return [bool](Get-Process deskflow-core -ErrorAction SilentlyContinue) }

function Start-Server {
    if (Test-ServerRunning) { return }
    if (-not (Test-Path $Core)) {
        Write-Log "ОШИБКА: не найден $Core"
        $ответ = Показать-Сообщение -Заголовок 'Нужен Deskflow' -Владелец $ui.Форма -Действие 'Установить' -СпроситьДаНет -Текст @"
Приложению нужен Deskflow — бесплатный открытый сервер клавиатуры и мыши. На этом компьютере его нет.

Нажмите «Установить» — он поставится из каталога приложений Windows. Через минуту снова нажмите «Включить».
"@
        if ($ответ -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                Start-Process -FilePath 'winget' -WindowStyle Hidden -ArgumentList @(
                    'install', '--id', 'Deskflow.Deskflow', '--exact', '--silent',
                    '--accept-package-agreements', '--accept-source-agreements')
                Write-Log 'запущена установка Deskflow из каталога приложений Windows'
            } catch {
                Write-Log ('установка Deskflow не запустилась: ' + $_.Exception.Message)
            }
        }
        return
    }
    Ensure-Config | Out-Null
    try {
        Start-Process -FilePath $Core -ArgumentList @('server', '--new-instance', '-s', $ServerConf) -WindowStyle Hidden
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

# ==== Знакомство по локальной сети ===========================================
$script:Udp = $null
$script:BroadcastTargets = @('255.255.255.255')
$script:DeckSeen = [datetime]::MinValue
$script:LastBeacon = [datetime]::MinValue
$script:Stranger = $null
# Языки клавиатуры Windows (`en-US,ru-RU`) — берутся один раз при запуске, без пробелов: маячок
# делится на поля пробелами. Не прочитались — «-», и Deck своих раскладок не трогает.
$script:Languages = '-'
try {
    $языки = @(Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) -join ','
    if ($языки) { $script:Languages = $языки -replace '\s', '' }
} catch { Write-Log ('языки клавиатуры не прочитались: ' + $_.Exception.Message) }

function Get-BroadcastTargets {
    $цели = New-Object System.Collections.Generic.List[string]
    $цели.Add('255.255.255.255')
    try {
        foreach ($ip in Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue) {
            if ($ip.IPAddress -like '127.*' -or $ip.IPAddress -like '169.254.*') { continue }
            if ($ip.PrefixLength -lt 8 -or $ip.PrefixLength -gt 30) { continue }
            $байты = ([System.Net.IPAddress]::Parse($ip.IPAddress)).GetAddressBytes()
            [array]::Reverse($байты)
            $значение = [System.BitConverter]::ToUInt32($байты, 0)
            $маска = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $ip.PrefixLength))
            $широковещательный = ($значение -band $маска) -bor (-bnot $маска -band 0xFFFFFFFF)
            $вывод = [System.BitConverter]::GetBytes([uint32]$широковещательный)
            [array]::Reverse($вывод)
            $текст = ([System.Net.IPAddress]$вывод).ToString()
            if (-not $цели.Contains($текст)) { $цели.Add($текст) }
        }
    } catch { }
    return $цели
}

function Get-LocalAddress {
    try {
        $лучший = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Sort-Object -Property InterfaceMetric | Select-Object -First 1
        if ($лучший) { return $лучший.IPAddress }
    } catch { }
    return '—'
}

function Open-Beacon {
    if ($script:Udp) { return }
    try {
        $клиент = New-Object System.Net.Sockets.UdpClient
        $клиент.EnableBroadcast = $true
        $клиент.Client.SetSocketOption('Socket', 'ReuseAddress', $true)
        $клиент.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)))
        $script:Udp = $клиент
        $script:BroadcastTargets = Get-BroadcastTargets
        Write-Log ('рассылка знакомства открыта, подсети: ' + ($script:BroadcastTargets -join ', '))
    } catch {
        Write-Log ('не удалось открыть рассылку: ' + $_.Exception.Message)
    }
}

function Send-Beacon([bool]$IsRunning) {
    if (-not $script:Udp) { return }
    $состояние = if ($IsRunning) { 'on' } else { 'off' }
    # В маячке идёт НОМЕР этой машины и номер уже знакомого Deck'а (или «-»):
    # по ним Deck решает, свой это компьютер или соседский.
    $знакомый = if ($script:Pair.deck_id) { $script:Pair.deck_id } else { '-' }
    # Последним полем — языки клавиатуры этого компьютера: клавиши уходят на Deck физическими,
    # и Deck заводит у себя те же раскладки с переключением Alt+Shift.
    # Восьмым полем — выбор человека, который исполняет Deck: возвращает ли Alt+Tab на компьютер.
    # Прежний Deck поле не читает и работает как раньше.
    $флаги = 'alttab={0}' -f [int][bool]$script:Settings.alt_tab
    $текст = '{0} SERVER {1} {2} {3} {4} {5} {6} {7}' -f $Protocol, $script:Pair.pc_id, $env:COMPUTERNAME, $KvmPort, $состояние, $знакомый, $script:Languages, $флаги
    $байты = [System.Text.Encoding]::UTF8.GetBytes($текст)
    foreach ($цель in $script:BroadcastTargets) {
        try { $script:Udp.Send($байты, $байты.Length, $цель, $BeaconPort) | Out-Null } catch { }
    }
}

function Receive-DeckReplies {
    if (-not $script:Udp) { return }
    while ($script:Udp.Available -gt 0) {
        try {
            $отправитель = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $данные = $script:Udp.Receive([ref]$отправитель)
            $части = ([System.Text.Encoding]::UTF8.GetString($данные)).Trim() -split '\s+'
            # Просьба Deck'а вернуть управление: Alt+Tab в игре, окно «Компьютер» на его рабочем
            # столе, кнопка в его окне. Принимается только от своего Deck'а и с его адреса.
            if ($части.Count -ge 3 -and $части[0] -eq $Protocol -and $части[1] -eq 'TOPC') {
                if ($script:Pair.deck_id -and $части[2] -eq $script:Pair.deck_id) { Вернуть-На-ПК 'просьба Deck''а' }
                continue
            }
            if ($части.Count -lt 4 -or $части[0] -ne $Protocol -or $части[1] -ne 'DECK') { continue }
            $номер = $части[2]
            $имя = $части[3]
            $адрес = $отправитель.Address.ToString()

            if (-not $script:Pair.deck_id) {
                $script:Pair.deck_id = $номер
                $script:Pair.deck_name = $имя
                $script:Pair.deck_address = $адрес
                $script:Pair.paired_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                Save-Pair
                Write-Log ('знакомство: Deck «{0}» номер {1}, адрес {2}' -f $имя, $номер, $адрес)
            } elseif ($script:Pair.deck_id -ne $номер) {
                # Чужой Deck в той же сети не подменяет своего молча.
                $script:Stranger = $имя
                continue
            } elseif ($script:Pair.deck_address -ne $адрес) {
                $script:Pair.deck_address = $адрес
                Save-Pair
                Write-Log ('свой Deck сменил адрес: ' + $адрес)
            }
            $script:DeckSeen = Get-Date
            # Пятое поле — версия Deck'а (с 1.2.1): по ней видно, отстаёт ли он от выпуска.
            if ($части.Count -ge 5) { $v = Разобрать-Версию $части[4]; if ($v) { $script:DeckVersion = $v } }
        } catch { break }
    }
}

function Test-DeckConnected {
    # Факт берётся из сетевого стека, а не из собственного журнала: установленное
    # соединение на порту протокола и есть «Deck подключён».
    # Таблица соединений — из .NET, а не Get-NetTCPConnection: тот идёт через CIM и занимает 1,6 с на вызов
    # (замер 25.09.2026), а вид обновляется каждую секунду — окно и меню значка переставали отвечать на нажатия.
    try {
        $связь = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections() |
            Where-Object { $_.LocalEndPoint.Port -eq $KvmPort -and $_.State -eq 'Established' -and
                           -not [System.Net.IPAddress]::IsLoopback($_.RemoteEndPoint.Address) } | Select-Object -First 1
        if ($связь) {
            $адрес = $связь.RemoteEndPoint.Address.ToString()
            if ($script:Pair.deck_address -ne $адрес) {
                $script:Pair.deck_address = $адрес
                Save-Pair
            }
            return $true
        }
    } catch { }
    return $false
}

# ==== Переход: служебные клавиши сервера =====================================
Add-Type -Namespace Win32 -Name DeckJump -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, int flags, IntPtr extra);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
'@

function Нажать-Служебную([byte]$Клавиша) {
    # Ctrl+Alt+Shift+клавиша: одна Alt без соседей открыла бы меню окна, здесь её держат ещё две.
    $мод = @(0x11, 0x12, 0x10)
    foreach ($к in $мод) { [Win32.DeckJump]::keybd_event([byte]$к, 0, 0, [IntPtr]::Zero) }
    [Win32.DeckJump]::keybd_event($Клавиша, 0, 0, [IntPtr]::Zero)
    [Win32.DeckJump]::keybd_event($Клавиша, 0, 2, [IntPtr]::Zero)
    [array]::Reverse($мод)
    foreach ($к in $мод) { [Win32.DeckJump]::keybd_event([byte]$к, 0, 2, [IntPtr]::Zero) }
}

function Перейти-На-Deck([string]$Откуда = 'кнопка') {
    if (-not (Test-ServerRunning) -or -not (Test-DeckConnected)) { Write-Log ("переход на Deck ({0}): Deck не подключён" -f $Откуда); return }
    Нажать-Служебную $КлавишаНаDeck
    Write-Log ("переход на Deck: {0}" -f $Откуда)
}

function Вернуть-На-ПК([string]$Откуда) {
    if (-not (Test-ServerRunning)) { return }
    Нажать-Служебную $КлавишаНаПК
    Write-Log ("управление возвращено на компьютер: {0}" -f $Откуда)
}

# Deck — отдельное окно «Steam Deck» в списке Alt+Tab и на панели задач. Горячая клавиша сервера на
# Alt+Tab отняла бы у Windows переключение окон целиком, а RegisterHotKey её и не отдаёт. Выбрали
# окно — фокус возвращается окну, где человек работал, а приложение нажимает служебную клавишу.
# Окно есть в списке, только пока Deck подключён и переход по Alt+Tab включён в настройках.
$script:ПрежнееОкно = [IntPtr]::Zero
$deckForm = New-Object System.Windows.Forms.Form
$deckForm.Text = 'Steam Deck'
$deckForm.ShowInTaskbar = $true
$deckForm.FormBorderStyle = 'None'
$deckForm.Opacity = 0
$deckForm.StartPosition = 'Manual'
$deckForm.Location = New-Object System.Drawing.Point(-32000, -32000)
$deckForm.Size = New-Object System.Drawing.Size(1, 1)
$deckForm.Icon = Значок-Трея
$deckForm.Add_Activated({
    [Win32.DeckJump]::ShowWindow($deckForm.Handle, 7) | Out-Null     # SW_SHOWMINNOACTIVE — снова свёрнуто
    if ($script:ПрежнееОкно -ne [IntPtr]::Zero) { [Win32.DeckJump]::SetForegroundWindow($script:ПрежнееОкно) | Out-Null }
    Перейти-На-Deck 'Alt+Tab на окно «Steam Deck»'
})
$script:DeckWindowShown = $false

function Обновить-Окно-Deck([bool]$Нужно) {
    if ($Нужно -eq $script:DeckWindowShown) { return }
    $script:DeckWindowShown = $Нужно
    if ($Нужно) { [Win32.DeckJump]::ShowWindow($deckForm.Handle, 7) | Out-Null }   # свёрнуто, без фокуса
    else { [Win32.DeckJump]::ShowWindow($deckForm.Handle, 0) | Out-Null }          # SW_HIDE
}

# Окно, где человек работал до Alt+Tab, запоминается часто: после перехода фокус стоит там же.
$focusTimer = New-Object System.Windows.Forms.Timer
$focusTimer.Interval = 250
$focusTimer.Add_Tick({
    $окно = [Win32.DeckJump]::GetForegroundWindow()
    if ($окно -ne [IntPtr]::Zero -and $окно -ne $deckForm.Handle) { $script:ПрежнееОкно = $окно }
})

# ==== Уснувший Deck ==========================================================
# Своего сторожа здесь нет намеренно. Прежний перезапускал сервер, когда Deck молчал на маячок
# восемь секунд при живом соединении, — выигрыш в одну секунду против защиты самого Deskflow
# (клиент без ответа отсекается через девять секунд: 3 с × 3 пропуска). По Wi-Fi широковещательный
# маячок и ответы на него теряются пачками, и 22.09.2026 сторож девять раз за полчаса оборвал
# живой сеанс — это и было «включил, а связь рвётся». Уснувший Deck уходит из сеанса по
# защите Deskflow, погасший экран Deck снимает связь сам.

# ==== Обновление из выпусков GitHub, без git ======================================
# Проверка идёт сама: при старте и раз в шесть часов. Кнопка «Обновить» появляется, только когда
# обновление есть. Обновляет программу установщик нового выпуска, запущенный тихо; настройки и
# память о паре живут в %LOCALAPPDATA%, а не в папке программы, и обновление их не трогает. Сервер при перезапуске приложения не останавливается — связь с Deck'ом
# обновления не замечает.
$script:UpdateTask = $null
$script:UpdateInfo = $null
$script:UpdateStage = $null
$script:NextUpdateCheck = (Get-Date).AddSeconds(15)
# Deck обновляется по просьбе компьютера: служба Deck'а ставит последний выпуск с github.com сама —
# на рабочем столе, в игровом режиме и посреди игры: служба живёт вне режима. Просьба — строка на
# его порт знакомства; Deck принимает её только от своего компьютера. Версию Deck сообщает в ответе
# на маячок. Сами ничего не ставим: обновление — по нажатию человека.
$script:Latest = $null
$script:DeckVersion = $null
$script:DeckAsked = [datetime]::MinValue
$script:Оповещено = @{}      # о каком обновлении уже было уведомление: одно на версию и устройство

function Deck-Отстаёт {
    return [bool]($script:Latest -and $script:DeckVersion -and $script:DeckVersion -lt $script:Latest -and
                  ((Get-Date) - $script:DeckSeen).TotalSeconds -lt 15)
}

function Попросить-Deck-Обновиться {
    if (-not $script:Udp -or -not $script:Pair.deck_address) { return }
    try {
        $байты = [System.Text.Encoding]::UTF8.GetBytes(('{0} UPDATE {1}' -f $Protocol, $script:Pair.pc_id))
        $script:Udp.Send($байты, $байты.Length, $script:Pair.deck_address, $BeaconPort) | Out-Null
        $script:DeckAsked = Get-Date
        Write-Log ('Deck''у отправлена просьба обновиться с {0} до {1}' -f $script:DeckVersion, $script:Latest)
    } catch { Write-Log ('просьба Deck''у обновиться не ушла: ' + $_.Exception.Message) }
}

function Новый-Загрузчик {
    $клиент = New-Object System.Net.WebClient
    $клиент.Headers['User-Agent'] = 'SteamDeck-KVM-updater'
    return $клиент
}

function Начать-Проверку-Обновления {
    # Рабочая копия тоже проверяет выпуски: сама она обновляется через git, но без номера последнего
    # выпуска не узнала бы, что Deck отстаёт, и кнопки «Обновить Deck» не показала бы никогда.
    if ($script:UpdateTask) { return }
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $script:UpdateStage = 'проверка'
        $script:UpdateTask = (Новый-Загрузчик).DownloadStringTaskAsync($ReleasesUrl)
    } catch {
        Write-Log ('проверка обновлений не началась: ' + $_.Exception.Message)
    }
}

function Сообщить-Об-Обновлении {
    # Одно уведомление на версию и устройство — общим уведомлением библиотеки (`lib\tray-place.ps1`): по
    # кнопке «Обновить» ставится сразу. Компьютер обновлён, а Deck подключился позже и отстаёт —
    # отдельное уведомление про Deck: кнопке компьютера обновлять больше нечего, а Deck ждёт.
    $что = $null
    if ($script:UpdateInfo) {
        $ключ = 'pc:' + $script:UpdateInfo.Версия
        if (-not $script:Оповещено[$ключ]) {
            $иDeck = if (Deck-Отстаёт) { ' Steam Deck обновится следом.' } else { '' }
            $что = @{ Ключ = $ключ; Заголовок = ('Общая клавиатура и мышь {0}' -f $script:UpdateInfo.Версия)
                      Текст = ('Вышло обновление, установка займёт около минуты.' + $иDeck); Действие = { Начать-Обновление } }
        }
    } elseif (Deck-Отстаёт) {
        $ключ = 'deck:' + $script:Latest
        if (-not $script:Оповещено[$ключ]) {
            $что = @{ Ключ = $ключ; Заголовок = ('Steam Deck: доступна версия {0}' -f $script:Latest)
                      Текст = ('Сейчас на Deck''е {0}. Обновление идёт в любом режиме, даже в игре.' -f $script:DeckVersion)
                      Действие = { Попросить-Deck-Обновиться; Кнопка-Обновления } }
        }
    }
    if (-not $что) { return }
    $script:Оповещено[$что.Ключ] = $true
    try {
        $действия = [ordered]@{ 'Обновить' = $что.Действие }
        Уведомление-Приложения -Заголовок $что.Заголовок -Текст $что.Текст -ЦветСостояния $C.Акцент -Картинка $script:IconPath `
            -Секунд 30 -ПоЩелчку { Show-Window } -Действия $действия | Out-Null
        Write-Log ('уведомление: ' + $что.Заголовок)
    } catch { Write-Log ('уведомление об обновлении не показано: ' + $_.Exception.Message) }
}

function Кнопка-Обновления {
    # Кнопка отвечает на вопрос «что обновится»: компьютер (и Deck, если отстаёт) либо только Deck.
    if ($script:UpdateInfo -or $script:UpdateTask) { return }
    if (Deck-Отстаёт) {
        $идёт = ((Get-Date) - $script:DeckAsked).TotalMinutes -lt 3
        $текст = if ($идёт) { 'Deck обновляется — связь переподключится сама' } else { 'Обновить Deck до {0}' -f $script:Latest }
        if ($ui.Обновление.Text -ne $текст) { Показать-Обновление $ui $текст }
        $ui.Обновление.Enabled = -not $идёт
    } elseif ($ui.Обновление.Visible) {
        $ui.Обновление.Enabled = $true
        Скрыть-Обновление $ui
    }
}

function Шаг-Обновления {
    if (-not $script:UpdateTask -or -not $script:UpdateTask.IsCompleted) { return }
    $задача = $script:UpdateTask
    $этап = $script:UpdateStage
    $script:UpdateTask = $null
    if ($задача.IsFaulted) {
        $причина = $задача.Exception.GetBaseException().Message
        Write-Log ("обновление, этап «{0}», не удалось: {1}" -f $этап, $причина)
        if ($этап -ne 'проверка') { $ui.Обновление.Enabled = $true; $ui.Обновление.Text = 'Обновление не удалось — нажмите, чтобы повторить' }
        return
    }
    switch ($этап) {
        'проверка' {
            $выпуск = $задача.Result | ConvertFrom-Json
            $script:Latest = Разобрать-Версию $выпуск.tag_name
            if ($IsDevCheckout) { return }   # компьютер в рабочей копии обновляет git, не установщик
            $выбор = Выбрать-Обновление $выпуск $Version
            if (-not $выбор) {
                $script:UpdateInfo = $null
                if ($ui.Обновление.Visible) { Скрыть-Обновление $ui }
                return
            }
            if ($выбор.Пропуск) { Write-Log $выбор.Пропуск; return }
            $script:UpdateInfo = $выбор
            $хвост = if ($выбор.Заметка) { ' — ' + $выбор.Заметка } else { '' }
            $иDeck = if (Deck-Отстаёт) { ' и Deck' } else { '' }
            Показать-Обновление $ui ("Обновить до {0}{1}{2}" -f $выбор.Версия, $иDeck, $хвост)
            Write-Log ("доступно обновление {0}" -f $выбор.Версия)
        }
        'установщик' {
            try { Применить-Обновление $задача.Result }
            catch {
                Write-Log ('обновление не применилось: ' + $_.Exception.Message)
                $ui.Обновление.Enabled = $true
                $ui.Обновление.Text = 'Обновление не удалось — нажмите, чтобы повторить'
            }
        }
    }
}

function Начать-Обновление {
    if (-not $script:UpdateInfo -or $script:UpdateTask) { return }
    # Deck обновляется вместе с компьютером, если отстаёт: одна кнопка на оба устройства.
    if (Deck-Отстаёт) { Попросить-Deck-Обновиться }
    $ui.Обновление.Enabled = $false
    $ui.Обновление.Text = ('Обновляется до {0}…' -f $script:UpdateInfo.Версия)
    $script:UpdateStage = 'установщик'
    $script:UpdateTask = (Новый-Загрузчик).DownloadDataTaskAsync($script:UpdateInfo.Архив.browser_download_url)
}

function Применить-Обновление([byte[]]$Данные) {
    $папка = Join-Path $env:TEMP ('steamdeck-kvm-update-' + $script:UpdateInfo.Версия)
    if (Test-Path $папка) { Remove-Item $папка -Recurse -Force }
    New-Item -ItemType Directory -Path $папка | Out-Null
    $установщик = Join-Path $папка $script:UpdateInfo.Архив.name
    [System.IO.File]::WriteAllBytes($установщик, $Данные)
    Проверить-Установщик -Установщик $установщик -Сумма $script:UpdateInfo.Сумма | Out-Null
    # Установщик тихо заменяет файлы программы и сам запускает новую версию; сервер при этом не
    # останавливается, и Deck обновления не замечает.
    Start-Process -FilePath $установщик -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    Write-Log ("запущен установщик {0} — выход для обновления" -f $script:UpdateInfo.Версия)
    Выйти-Для-Перезапуска
}

# ==== Ярлык на рабочем столе при первом запуске ====================================
# Установленной программе ярлыки ставит установщик — и если человек снял галочку, ярлыка быть не
# должно. Сам ярлык заводится только у программы, запущенной не из установки, один раз. Удалённый человеком
# ярлык не возвращается: метка первого запуска остаётся. В рабочей копии ярлыки собирает
# private_tools\scripts\make_shortcuts_script.ps1.
function Ярлык-При-Первом-Запуске {
    if ($IsDevCheckout -or (Test-Path -LiteralPath (Join-Path $Root 'unins000.exe'))) { return }
    $метка = Join-Path $ConfDir 'shortcut-made'
    if (Test-Path -LiteralPath $метка) { return }
    try {
        Значок-Приложения | Out-Null
        $shell = New-Object -ComObject WScript.Shell
        $ярлык = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Общая клавиатура и мышь.lnk'))
        $ярлык.TargetPath = 'C:\Windows\System32\wscript.exe'
        $ярлык.Arguments = '"' + (Join-Path $Root 'SteamDeck-KVM.vbs') + '"'
        $ярлык.WorkingDirectory = $Root
        $ярлык.IconLocation = (Join-Path $Root 'SteamDeck-KVM.ico') + ',0'
        $ярлык.Description = 'Общая клавиатура и мышь со Steam Deck'
        $ярлык.Save()
        Записать-БезМетки $метка (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Write-Log 'ярлык на рабочем столе создан при первом запуске'
    } catch {
        Write-Log ('ярлык не создан: ' + $_.Exception.Message)
    }
}

# ==== Окно ===================================================================
Load-Pair
Load-Settings
$ui = New-AppWindow
$form = $ui.Форма
$C = $ui.Цвета

# ==== Значок в трее: меню короткое, состояние словом, действия — в окне ======
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = Значок-Трея
$ni.Text = 'Общая клавиатура и мышь'
$ni.Visible = $true

# Меню Windows не используется: место оно выбирает верно, но вид у него чужой —
# светлое меню посреди тёмного приложения читается как всплывшее окно другой
# программы, и состояния в нём не видно. Вместо него общее меню библиотеки (`Меню-Трея`
# в `lib\tray-place.ps1`): состояние словом и цветом, шапка открывает окно, под ней тумблер
# и выход. Место плашки считает механика `lib\tray-place.ps1` —
# плашка выходит из панели задач с той стороны, где та реально стоит.
#
# Настройки — кнопкой в окне: в меню — только частые действия.
$script:Плашка = $null

function Показать-Плашку {
    # Повторное нажатие по значку ЗАКРЫВАЕТ плашку, а не поднимает вторую.
    if ($script:Плашка -and -not $script:Плашка.IsDisposed) {
        try { $script:Плашка.Close() } catch { }
        $script:Плашка = $null
        return
    }
    # Состояние спрашивается у системы в момент открытия плашки, а не берётся из
    # того, что было нарисовано минуту назад.
    $работает = Test-ServerRunning
    $подключён = $работает -and (Test-DeckConnected)
    if ($подключён) { $слово = 'Работает — Deck подключён'; $цвет = $C.Успех }
    elseif ($работает) { $слово = 'Включено — ждём Deck'; $цвет = $C.Акцент }
    else { $слово = 'Выключено'; $цвет = $C.Тусклый }
    if ($работает) { $тумблер = 'Выключить'; $цветТумблера = $C.Тревога }
    else { $тумблер = 'Включить'; $цветТумблера = $C.Акцент }

    $пункты = @(@{ Текст = $тумблер; Цвет = $цветТумблера; Действие = { Switch-Server } })
    if ($подключён) { $пункты += @{ Текст = 'Перейти на Deck'; Действие = { Перейти-На-Deck 'меню значка' } } }
    $пункты += @{ Текст = 'Закрыть'; Действие = { Выйти-Из-Приложения } }
    $ф = Меню-Трея -Название 'KVM' -ЦветСостояния $цвет -Подсказка $слово -ОткрытьОкно { Show-Window } -Пункты $пункты
    $script:Плашка = $ф
    $ф.Show()
    $ф.Activate()
}

# ==== Обновление вида ========================================================
function Update-View {
    $работает = Test-ServerRunning
    $подключён = $работает -and (Test-DeckConnected)
    $видели = ((Get-Date) - $script:DeckSeen).TotalSeconds -lt 15

    Обновить-Окно-Deck ($подключён -and $script:Settings.alt_tab)
    if ($подключён) {
        $ui.Точка.ForeColor = $C.Успех
        $ui.Состояние.Text = 'Работает — Deck подключён'
        $ui.Подсказка.Text = Подсказка-Перехода
    } elseif ($работает -and $видели) {
        $ui.Точка.ForeColor = $C.Ожидание
        $ui.Состояние.Text = 'Включено — Deck отвечает'
        $ui.Подсказка.Text = 'Deck рядом и знакомится; соединение поднимется в ближайшие секунды.'
    } elseif ($работает) {
        $ui.Точка.ForeColor = $C.Акцент
        $ui.Состояние.Text = 'Включено — ждём Deck'
        $ui.Подсказка.Text = 'Включите Steam Deck: он найдёт этот компьютер сам, в том числе в игровом режиме.'
    } else {
        $ui.Точка.ForeColor = $C.Тусклый
        $ui.Состояние.Text = 'Выключено'
        $ui.Подсказка.Text = 'Нажмите «Включить» — Deck подключится сам.'
    }

    $ui.Тумблер.Text = if ($работает) { 'Выключить' } else { 'Включить' }
    $ui.Тумблер.BackColor = if ($работает) { $C.Тревога } else { $C.Акцент }

    $версияDeck = if ($script:DeckVersion) { ' · версия ' + $script:DeckVersion } else { '' }
    if ($script:DeckVersion -and $script:Latest -and $script:DeckVersion -lt $script:Latest) { $версияDeck += ', отстаёт' }
    # Deck до этой версии номера не сообщает и просьбу компьютера не понимает — первый раз его
    # обновляют на нём самом, дальше — кнопкой здесь.
    elseif ($подключён -and -not $script:DeckVersion) { $версияDeck = ' · обновите один раз на самом Deck''е' }
    if ($подключён) {
        $ui.Факты['Steam Deck'].Text = '{0} · подключён{1}' -f $script:Pair.deck_name, $версияDeck
        $ui.Факты['Steam Deck'].ForeColor = $C.Успех
    } elseif ($видели) {
        $ui.Факты['Steam Deck'].Text = '{0} · в сети, ещё не подключён' -f $script:Pair.deck_name
        $ui.Факты['Steam Deck'].ForeColor = $C.Текст
    } elseif ($script:Pair.deck_id) {
        $ui.Факты['Steam Deck'].Text = '{0} · знаком, сейчас не отвечает' -f $script:Pair.deck_name
        $ui.Факты['Steam Deck'].ForeColor = $C.Тусклый
    } else {
        $ui.Факты['Steam Deck'].Text = 'ещё не знакомы'
        $ui.Факты['Steam Deck'].ForeColor = $C.Тусклый
    }

    $ui.Факты['Этот компьютер'].Text = '{0} · {1}' -f $env:COMPUTERNAME, (Get-LocalAddress)
    $ui.Факты['Версия'].Text = if ($IsDevCheckout) { "$Version · рабочая копия" } else { $Version }
    (Кнопка 'Перейти на Deck').Enabled = $подключён
    Кнопка-Обновления

    $ni.Icon = Значок-Трея
    $ni.Text = if ($подключён) { 'Общая клавиатура и мышь — Deck подключён' }
               elseif ($работает) { 'Общая клавиатура и мышь — ждём Deck' }
               else { 'Общая клавиатура и мышь — выключено' }
    # Состояние плашки не обновляется по часам: плашка живёт секунды и собирается
    # заново на каждое нажатие, спрашивая состояние у системы в этот момент.
}

function Подсказка-Перехода {
    # Подсказка называет ровно те способы, что включены в настройках: кнопка работает всегда.
    $туда = @()
    if ($script:Settings.alt_tab) { $туда += 'Alt+Tab на окно «Steam Deck»' }
    if ($script:Settings.edge) { $туда += 'край экрана' }
    $туда += 'кнопка «Перейти на Deck»'
    $обратно = if ($script:Settings.alt_tab) { 'Alt+Tab на Deck''е' } else { 'кнопка «На компьютер» в окне Deck''а' }
    if ($script:Settings.edge) { $обратно += ' или край экрана' }
    return ('На Deck — {0}. Обратно — {1}.' -f ($туда -join ', '), $обратно)
}

function Switch-Server {
    # Состояние спрашивается у системы в момент нажатия, а не берётся из вида:
    # между отрисовкой и нажатием сервер успевает упасть сам.
    if (Test-ServerRunning) { Stop-Server } else { Start-Server }
    Start-Sleep -Milliseconds 400
    Send-Beacon (Test-ServerRunning)
    Update-View
}

function Show-Window {
    $form.Show()
    $form.WindowState = 'Normal'
    Поднять-Наверх $form
    # В журнал идёт ФАКТ от системы, а не намерение формы: свёрнутое окно
    # отвечает «Normal», и запись «окно показано» была бы неотличима от правды.
    Write-Log ('окно показано, видимость={0}, свёрнуто={1}' -f $form.Visible, ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized))  # без чужого внутреннего типа библиотеки: он переименовывался
}

# ==== Обработчики ============================================================
# Кнопка берётся ПО ИМЕНИ, и промах по имени обязан быть громким. Переименование
# подписи в оболочке 12.09.2026 оставило два обработчика висеть на прежних ключах:
# кнопки «Настроить Deck» и «В трей» молча перестали что-либо делать, а сторож
# компоновки такого не видит — он проверяет раскладку, а не связь с действием.
function Кнопка([string]$Имя) {
    $кнопка = $ui.Кнопки[$Имя]
    if (-not $кнопка) {
        $есть = ($ui.Кнопки.Keys | Sort-Object) -join ', '
        Write-Log ("ДЕФЕКТ: кнопки «{0}» в окне нет; есть: {1}" -f $Имя, $есть)
        throw "в окне нет кнопки «$Имя»"
    }
    return $кнопка
}

$ui.Тумблер.Add_Click({ Switch-Server })
$ui.Обновление.Add_Click({
    if ($script:UpdateInfo) { Начать-Обновление }
    elseif (Deck-Отстаёт) { Попросить-Deck-Обновиться; Кнопка-Обновления }
    else { Начать-Проверку-Обновления }
})
$ni.Add_MouseDoubleClick({ Show-Window })
# ЛКМ — окно, ПКМ — плашка. Оба поднимаются на MouseUp: меню Windows открывалось
# бы на нём же, и своя плашка обязана отзываться так же, иначе нажатие ощущается
# запоздавшим.
$ni.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Показать-Плашку }
    elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Window }
})

(Кнопка 'Перейти на Deck').Add_Click({ Перейти-На-Deck 'кнопка в окне' })

# Журнал — окно приложения, а не текстовый файл в Блокноте. Одно окно: повторное нажатие поднимает
# открытое. Строки подтягиваются часами приложения, пока окно открыто.
$script:ОкноЖурнала = $null
function Строки-Журнала([int]$Сколько = 400) {
    if (-not (Test-Path -LiteralPath $LogFile)) { return @() }
    try {
        $поток = New-Object System.IO.FileStream($LogFile, 'Open', 'Read', 'ReadWrite')
        $чтец = New-Object System.IO.StreamReader($поток, [System.Text.Encoding]::UTF8)
        $все = $чтец.ReadToEnd() -split "`r?`n" | Where-Object { $_ }
        $чтец.Dispose()
        return @($все | Select-Object -Last $Сколько)
    } catch { return @('журнал не прочитан: ' + $_.Exception.Message) }
}
(Кнопка 'Журнал').Add_Click({
    if ($script:ОкноЖурнала -and -not $script:ОкноЖурнала.Форма.IsDisposed) { Поднять-Наверх $script:ОкноЖурнала.Форма; return }
    $script:ОкноЖурнала = New-LogWindow
    Заполнить-Журнал $script:ОкноЖурнала.Текст (Строки-Журнала)
    $script:ОкноЖурнала.Форма.Add_FormClosed({ $script:ОкноЖурнала = $null })
    $script:ОкноЖурнала.Форма.Show($form)
})

function Показать-Установку-Deck {
    $ответ = Показать-Сообщение -Заголовок 'Настройка Steam Deck' -Владелец $form -Действие 'Открыть выпуски' -СпроситьДаНет -Текст @"
Один раз, три шага:

1. На Steam Deck в режиме рабочего стола откройте страницу выпусков и скачайте «SteamDeck-KVM-Install.desktop».
2. Нажмите на скачанный ярлык — он сам скачает и установит программу. Если Firefox дописал к имени «.download», уберите это окончание.
3. Здесь нажмите «Включить».

Дальше Deck находит компьютер сам — в игровом режиме, после перезагрузки и в другой сети. Обновления компьютер ставит на оба устройства сам.
"@
    if ($ответ -eq [System.Windows.Forms.DialogResult]::Yes) {
        try { Start-Process $ReleasesPage } catch { Write-Log ('страница выпусков не открылась: ' + $_.Exception.Message) }
    }
}

function Спросить-Забыть-Deck {
    $ответ = Показать-Сообщение -Заголовок 'Забыть этот Deck' -Владелец $form -Действие 'Забыть' -СпроситьДаНет -Текст @"
Приложение перестанет узнавать Deck «$($script:Pair.deck_name)» и познакомится со следующим, который откликнется в этой сети.

Это нужно, когда Deck сменился или когда знакомство случилось не с тем устройством. На самом Deck'е ничего делать не придётся.
"@
    if ($ответ -eq [System.Windows.Forms.DialogResult]::Yes) {
        Forget-Deck
        Update-View
        return $true
    }
    return $false
}

# Настройки — общее окно библиотеки; сохранённый выбор применяется сразу: раскладка сервера пересобирается и
# сервер перезапускается, только если изменился край или сторона — прочее сервер не читает.
function Применить-Настройки($Значения) {
    $прежние = @{} + $script:Settings
    foreach ($к in @('alt_tab', 'edge', 'side')) { if ($Значения.ContainsKey($к)) { $script:Settings[$к] = $Значения[$к] } }
    Save-Settings
    Write-Log ('настройки: Alt+Tab {0}, край {1}, Deck {2}' -f $script:Settings.alt_tab, $script:Settings.edge, $script:Settings.side)
    if (($прежние.edge -ne $script:Settings.edge -or $прежние.side -ne $script:Settings.side) -and (Ensure-Config) -and (Test-ServerRunning)) {
        Write-Log 'раскладка изменилась — сервер перезапущен'
        Stop-Server; Start-Sleep -Milliseconds 300; Start-Server
    }
    Send-Beacon (Test-ServerRunning)
    Update-View
}

(Кнопка 'Настройки').Add_Click({
    $описание = Описание-Настроек -Настройки $script:Settings -ИмяDeck ([string]$script:Pair.deck_name) `
        -Забыть { Спросить-Забыть-Deck | Out-Null } -Установка { Показать-Установку-Deck }
    Окно-Настроек -Заголовок 'Общая клавиатура и мышь — настройки' -Значок (Значок-Приложения) -Вкладки $описание `
        -Владелец $form -Сохранить { param($значения) Применить-Настройки $значения } | Out-Null
})

# Application::Exit() закрывает форму повторно, и обработчик входит сам в себя —
# отсюда флаг: выход выполняется ровно один раз.
# КРЕСТИК СВОРАЧИВАЕТ В ТРЕЙ, А НЕ ВЫХОДИТ. Приложение живёт фоном: пока сервер
# включён, Deck подключён, и закрытие окна оборвало бы связь посреди работы —
# человек же закрывал окно, а не выключал клавиатуру. Выход остаётся один и
# явный: пункт «Закрыть» в меню значка. Отдельная кнопка «в трей» из окна ушла:
# крестик и есть эта кнопка, а две кнопки на одно действие — лишняя развилка.
$script:Quitting = $false
$form.Add_FormClosing({
    param($s, $e)
    # Решение принимается по СВОЕМУ флагу, а не по CloseReason от системы.
    # Замер 12.09.2026: закрытие окна приходило с причиной, отличной от
    # UserClosing, и ветка «свернуть» не срабатывала — приложение выходило,
    # обрывая связь с Deck'ом. Признак, который ставит сама программа, врать
    # не может; выключение Windows остаётся единственным чужим исключением.
    $этоВыключениеСистемы = ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown)
    if (-not $script:Quitting -and -not $этоВыключениеСистемы) {
        # Молча. Всплывающее уведомление на каждое сворачивание — шум: человек
        # сам нажал крестик и знает, что сделал. Уведомление уместно тогда,
        # когда происходит то, чего человек не делал.
        $e.Cancel = $true
        $form.Hide()
        Write-Log 'окно свёрнуто в трей, приложение работает'
        return
    }
    $script:Quitting = $true
    $timer.Stop()
    $focusTimer.Stop()
    $ni.Visible = $false
    Write-Log '=== выход ==='
    [System.Windows.Forms.Application]::Exit()
})

function Выйти-Для-Перезапуска {
    # Выход без остановки сервера: новый экземпляр застанет его работающим, и Deck не заметит.
    $script:Quitting = $true
    $timer.Stop()
    $ni.Visible = $false
    try { $instance.Mutex.ReleaseMutex() } catch { }
    Write-Log '=== выход для перезапуска ==='
    [System.Windows.Forms.Application]::Exit()
}

function Выйти-Из-Приложения {
    # Выход — единственное место, где сервер останавливается вместе с окном.
    Stop-Server
    Send-Beacon $false
    $script:Quitting = $true
    $timer.Stop()
    $ni.Visible = $false
    Write-Log '=== выход ==='
    [System.Windows.Forms.Application]::Exit()
}

# ==== Часы приложения ========================================================
# Один таймер на всё: рассылка маячка, разбор ответов Deck'а, сверка вида с фактом.
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
        if ((Get-Date) -ge $script:NextUpdateCheck) {
            $script:NextUpdateCheck = (Get-Date).AddHours(6)
            Начать-Проверку-Обновления
        }
        Шаг-Обновления
        Сообщить-Об-Обновлении
        Update-View
        if ($script:ОкноЖурнала -and -not $script:ОкноЖурнала.Форма.IsDisposed) { Заполнить-Журнал $script:ОкноЖурнала.Текст (Строки-Журнала) }
        if ($script:Stranger) {
            $чужой = $script:Stranger
            $script:Stranger = $null
            Write-Log ('в сети откликнулся чужой Deck «{0}» — пропущен, знакомый занят' -f $чужой)
        }
    } catch {
        Write-Log ('таймер: ' + $_.Exception.Message)
    }
})

if ((Ensure-Config) -and (Test-ServerRunning)) {
    # Сервер читает раскладку только при старте: пересобранная раскладка требует перезапуска.
    Write-Log 'раскладка изменилась при работающем сервере — сервер перезапущен'
    Stop-Server
    Start-Sleep -Milliseconds 300
    Start-Server
}
Ярлык-При-Первом-Запуске
Open-Beacon
Update-View
$timer.Start()
$focusTimer.Start()
# Меню значка прогревается через две секунды после запуска: первое нажатие открывает его сразу,
# а не через полторы секунды разбора функций и первого снимка стекла.
$прогрев = New-Object System.Windows.Forms.Timer
$прогрев.Interval = 2000
$прогрев.Add_Tick({ param($s, $e) $s.Stop(); $s.Dispose(); Прогреть-Меню-Трея })
$прогрев.Start()

# Первое окно процесса Windows показывает так, как велено в STARTUPINFO
# запускающего, а запускает нас VBS со скрытым окном (иначе мигала бы консоль).
# Поэтому Show() одного мало — окно уехало бы в панель задач свёрнутым.
Show-Window
[System.Windows.Forms.Application]::Run()
