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
# секунду — канон требует не реже чем раз в полсекунды по ощущению человека,
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

$МеткаРаскладки = '# steamdeck-kvm-layout v2'

function Ensure-Config {
    # Возвращает, изменилась ли раскладка: сервер читает её только при старте.
    $имяПК = $env:COMPUTERNAME
    if (-not $имяПК) { $имяПК = 'pc' }

    Снять-Метку $ServerConf
    Снять-Метку $ScreensConf

    $изменено = $false
    $прежняя = if (Test-Path $ScreensConf) { [System.IO.File]::ReadAllText($ScreensConf) } else { '' }
    # Своя ли раскладка — по метке либо по шапке прежней версии приложения. Чужую, написанную
    # руками без метки, приложение не трогает никогда.
    $своя = ($прежняя -eq '') -or $прежняя.StartsWith('# steamdeck-kvm-layout') -or
            $прежняя.Contains('Раскладка экранов для общей клавиатуры и мыши')
    if ($своя -and -not $прежняя.StartsWith($МеткаРаскладки)) {
        # Сторона Deck'а — единственное, что человек менял руками; она переносится в новую раскладку.
        $сторона = 'right'
        if ($прежняя -match ('(?ms)^\s*' + [regex]::Escape($имяПК) + ':\s*\r?\n\s*left\s*=\s*steamdeck')) { $сторона = 'left' }
        $обратно = if ($сторона -eq 'right') { 'left' } else { 'right' }
        $раскладка = @"
$МеткаРаскладки
# Раскладка экранов собирается приложением «Общая клавиатура и мышь».
# Сторону Deck'а можно поменять: поменяйте местами left и right в разделе links —
# приложение сохранит её при следующей пересборке. Остальное перезаписывается.

section: screens
	${имяПК}:
	steamdeck:
end

section: links
	${имяПК}:
		$сторона = steamdeck
	steamdeck:
		$обратно = $имяПК
end

section: options
	# Переход мгновенный: задержка у края делала переход на Deck заметно медленным.
	switchDelay = 0
	switchDoubleTap = 0
	# Горячие клавиши на СТРЕЛКАХ, а не на буквах: сервер хранит символ клавиши, и при русской
	# раскладке «d» становится «в» — прежняя Win+Shift+D просто не срабатывала.
	keystroke(Control+Alt+Right) = switchInDirection(right)
	keystroke(Control+Alt+Left) = switchInDirection(left)
end
"@
        Записать-БезМетки $ScreensConf $раскладка
        $изменено = $true
        Write-Log "раскладка экранов пересобрана ($МеткаРаскладки, Deck — $сторона)"
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
    $текст = '{0} SERVER {1} {2} {3} {4} {5}' -f $Protocol, $script:Pair.pc_id, $env:COMPUTERNAME, $KvmPort, $состояние, $знакомый
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
        } catch { break }
    }
}

function Test-DeckConnected {
    # Факт берётся из сетевого стека, а не из собственного журнала: установленное
    # соединение на порту протокола и есть «Deck подключён».
    try {
        $связь = Get-NetTCPConnection -LocalPort $KvmPort -State Established -ErrorAction SilentlyContinue |
            Where-Object { $_.RemoteAddress -notlike '127.*' } | Select-Object -First 1
        if ($связь) {
            if ($script:Pair.deck_address -ne $связь.RemoteAddress) {
                $script:Pair.deck_address = $связь.RemoteAddress
                Save-Pair
            }
            return $true
        }
    } catch { }
    return $false
}

# ==== Защита: курсор не уходит в уснувший Deck ====================================
# Сервер Deskflow отсекает замолчавший клиент сам, но через девять секунд (3 с × 3 пропуска).
# Все эти секунды уснувший Deck числится подключённым, и мышь, доведённая до края, уходит в
# чёрный экран. Deck отвечает на маячок раз в две секунды — его молчание видно раньше. Молчит
# при живом соединении — сервер перезапускается, и соединение с уснувшим Deck'ом рвётся сразу.
$script:AppStarted = Get-Date
$script:LastStaleRestart = [datetime]::MinValue

function Проверить-Уснувший-Deck {
    if (-not (Test-ServerRunning)) { return }
    # Судить можно только о Deck'е, который в этом запуске уже отвечал: иначе прежний клиент
    # без маячка перезапускал бы сервер каждые полминуты.
    if ($script:DeckSeen -lt $script:AppStarted) { return }
    $молчит = ((Get-Date) - $script:DeckSeen).TotalSeconds
    if ($молчит -lt 8) { return }
    if (((Get-Date) - $script:LastStaleRestart).TotalSeconds -lt 30) { return }
    if (-not (Test-DeckConnected)) { return }
    $script:LastStaleRestart = Get-Date
    Write-Log ('Deck молчит {0:N0} с при живом соединении — сервер перезапущен, курсор не уйдёт в уснувший Deck' -f $молчит)
    Stop-Server
    Start-Sleep -Milliseconds 300
    Start-Server
}

# ==== Обновление из выпусков GitHub, без git ======================================
# Проверка идёт сама: при старте и раз в шесть часов. Кнопка «Обновить» появляется, только когда
# обновление есть. Обновляет программу установщик нового выпуска, запущенный тихо; настройки и
# память о паре живут в %LOCALAPPDATA%, а не в папке программы, и обновление их не трогает. Сервер при перезапуске приложения не останавливается — связь с Deck'ом
# обновления не замечает.
$script:UpdateTask = $null
$script:UpdateInfo = $null
$script:UpdateStage = $null
$script:NextUpdateCheck = (Get-Date).AddSeconds(15)

function Новый-Загрузчик {
    $клиент = New-Object System.Net.WebClient
    $клиент.Headers['User-Agent'] = 'SteamDeck-KVM-updater'
    return $клиент
}

function Начать-Проверку-Обновления {
    if ($IsDevCheckout -or $script:UpdateTask) { return }
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $script:UpdateStage = 'проверка'
        $script:UpdateTask = (Новый-Загрузчик).DownloadStringTaskAsync($ReleasesUrl)
    } catch {
        Write-Log ('проверка обновлений не началась: ' + $_.Exception.Message)
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
            $выбор = Выбрать-Обновление ($задача.Result | ConvertFrom-Json) $Version
            if (-not $выбор) {
                $script:UpdateInfo = $null
                if ($ui.Обновление.Visible) { Скрыть-Обновление $ui }
                return
            }
            if ($выбор.Пропуск) { Write-Log $выбор.Пропуск; return }
            $script:UpdateInfo = $выбор
            $хвост = if ($выбор.Заметка) { ' — ' + $выбор.Заметка } else { '' }
            Показать-Обновление $ui ("Обновить до {0}{1}" -f $выбор.Версия, $хвост)
            Write-Log ("доступно обновление {0}" -f $выбор.Версия)
        }
        'суммы' {
            $script:UpdateInfo['ТекстСумм'] = $задача.Result
            $script:UpdateStage = 'установщик'
            $script:UpdateTask = (Новый-Загрузчик).DownloadDataTaskAsync($script:UpdateInfo.Архив.browser_download_url)
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
    $ui.Обновление.Enabled = $false
    $ui.Обновление.Text = ('Обновляется до {0}…' -f $script:UpdateInfo.Версия)
    $script:UpdateStage = 'суммы'
    $script:UpdateTask = (Новый-Загрузчик).DownloadStringTaskAsync($script:UpdateInfo.Суммы.browser_download_url)
}

function Применить-Обновление([byte[]]$Данные) {
    $папка = Join-Path $env:TEMP ('steamdeck-kvm-update-' + $script:UpdateInfo.Версия)
    if (Test-Path $папка) { Remove-Item $папка -Recurse -Force }
    New-Item -ItemType Directory -Path $папка | Out-Null
    $установщик = Join-Path $папка $script:UpdateInfo.Архив.name
    [System.IO.File]::WriteAllBytes($установщик, $Данные)
    Проверить-Установщик -Установщик $установщик -ТекстСумм $script:UpdateInfo.ТекстСумм | Out-Null
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
# программы, и состояния в нём не видно. Вместо него своя плашка (`Новая-Плашка`
# в оболочке): состояние словом и цветом, шапка открывает окно, под ней тумблер
# и выход. Место плашки считает механика `lib\tray-place.ps1` —
# плашка выходит из панели задач с той стороны, где та реально стоит.
#
# Пункта «Настройки» нет потому, что настроек у приложения нет: раскладка экранов
# живёт в screens.conf, а адрес Deck'а не настраивается вовсе — он находится сам.
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

    $п = Новая-Плашка -Состояние $слово -ЦветСостояния $цвет `
                      -ТекстТумблера $тумблер -ЦветТумблера $цветТумблера
    $ф = $п.Форма
    $script:Плашка = $ф
    $открыть = { try { $script:Плашка.Close() } catch { }; Show-Window }
    $п.Шапка.Add_Click($открыть)
    # Щелчок по надписи до панели под ней не доходит: надпись — свой контрол и
    # событие съедает. Без этого шапка открывала бы окно только по пустому месту.
    foreach ($н in $п.Надписи) { $н.Add_Click($открыть) }
    $п.Тумблер.Add_Click({ try { $script:Плашка.Close() } catch { }; Switch-Server })
    $п.Выход.Add_Click({ try { $script:Плашка.Close() } catch { }; Выйти-Из-Приложения })
    $ф.Add_Deactivate({ try { $this.Close() } catch { } })
    $ф.Show()
    $ф.Activate()
}

# ==== Обновление вида ========================================================
function Update-View {
    $работает = Test-ServerRunning
    $подключён = $работает -and (Test-DeckConnected)
    $видели = ((Get-Date) - $script:DeckSeen).TotalSeconds -lt 15

    if ($подключён) {
        $ui.Точка.ForeColor = $C.Успех
        $ui.Состояние.Text = 'Работает — Deck подключён'
        $ui.Подсказка.Text = 'Доведите курсор до края экрана или нажмите Ctrl+Alt+→. Обратно — Ctrl+Alt+←.'
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

    if ($подключён) {
        $ui.Факты['Steam Deck'].Text = '{0} · подключён' -f $script:Pair.deck_name
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
    $ui.Факты['Переход'].Text = 'край экрана · Ctrl+Alt+→ и Ctrl+Alt+←'
    $ui.Факты['Версия'].Text = if ($IsDevCheckout) { "$Version · рабочая копия" } else { $Version }
    (Кнопка 'Забыть Deck').Enabled = [bool]$script:Pair.deck_id

    $ni.Icon = Значок-Трея
    $ni.Text = if ($подключён) { 'Общая клавиатура и мышь — Deck подключён' }
               elseif ($работает) { 'Общая клавиатура и мышь — ждём Deck' }
               else { 'Общая клавиатура и мышь — выключено' }
    # Состояние плашки не обновляется по часам: плашка живёт секунды и собирается
    # заново на каждое нажатие, спрашивая состояние у системы в этот момент.
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
    Write-Log ('окно показано, видимость={0}, свёрнуто={1}' -f $form.Visible, [Win32.Dwm]::IsIconic($form.Handle))
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
$ui.Обновление.Add_Click({ if ($script:UpdateInfo) { Начать-Обновление } else { Начать-Проверку-Обновления } })
$ni.Add_MouseDoubleClick({ Show-Window })
# ЛКМ — окно, ПКМ — плашка. Оба поднимаются на MouseUp: меню Windows открывалось
# бы на нём же, и своя плашка обязана отзываться так же, иначе нажатие ощущается
# запоздавшим.
$ni.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Показать-Плашку }
    elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Window }
})

(Кнопка 'Журнал').Add_Click({
    try {
        if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile }
        else { Показать-Сообщение -Заголовок 'Журнал пуст' -Владелец $form -Текст 'Приложение ещё ничего не записало.' | Out-Null }
    } catch { }
})

(Кнопка 'Настроить Deck').Add_Click({
    $ответ = Показать-Сообщение -Заголовок 'Настройка Steam Deck' -Владелец $form -Действие 'Открыть выпуски' -СпроситьДаНет -Текст @"
Один раз, три шага:

1. На Steam Deck в режиме рабочего стола откройте страницу выпусков и скачайте «SteamDeck-KVM-Install.desktop».
2. Нажмите на скачанный ярлык — он сам скачает и установит программу. Если Firefox дописал к имени «.download», уберите это окончание.
3. Здесь нажмите «Включить».

Дальше Deck находит компьютер сам — в игровом режиме, после перезагрузки и в другой сети. Обновления приходят кнопкой в окне, на ПК и на Deck'е.
"@
    if ($ответ -eq [System.Windows.Forms.DialogResult]::Yes) {
        try { Start-Process $ReleasesPage } catch { Write-Log ('страница выпусков не открылась: ' + $_.Exception.Message) }
    }
})

(Кнопка 'Забыть Deck').Add_Click({
    $ответ = Показать-Сообщение -Заголовок 'Забыть этот Deck' -Владелец $form -Действие 'Забыть' -СпроситьДаНет -Текст @"
Приложение перестанет узнавать Deck «$($script:Pair.deck_name)» и познакомится со следующим, который откликнется в этой сети.

Это нужно, когда Deck сменился или когда знакомство случилось не с тем устройством. На самом Deck'е ничего делать не придётся.
"@
    if ($ответ -eq [System.Windows.Forms.DialogResult]::Yes) {
        Forget-Deck
        Update-View
    }
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
        Проверить-Уснувший-Deck
        if ((Get-Date) -ge $script:NextUpdateCheck) {
            $script:NextUpdateCheck = (Get-Date).AddHours(6)
            Начать-Проверку-Обновления
        }
        Шаг-Обновления
        Update-View
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

# Первое окно процесса Windows показывает так, как велено в STARTUPINFO
# запускающего, а запускает нас VBS со скрытым окном (иначе мигала бы консоль).
# Поэтому Show() одного мало — окно уехало бы в панель задач свёрнутым.
Show-Window
[System.Windows.Forms.Application]::Run()
