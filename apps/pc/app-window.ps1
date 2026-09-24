# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Оболочка окна: палитра, гарнитура, радиусы, раскладка.
#
# ПОЧЕМУ ОТДЕЛЬНЫМ ФАЙЛОМ, А НЕ ВНУТРИ ПРИЛОЖЕНИЯ — раскладка окна считается, а не задаётся
# числами, и её проверяет сторож, который перебирает размеры окна и ищет вылезшее за край.
# Сторож обязан собирать ТО ЖЕ окно, что видит человек: повтори числа в стороже
# отдельно — и он начнёт проверять вчерашнюю раскладку, ничего об этом не сказав.
# Поэтому окно собирается здесь, а приложение и сторож оба зовут New-AppWindow.
#
# ЧТО БЕРЁТСЯ ИЗ ПАЛИТРЫ palette.json — цвета, ГАРНИТУРА и
# РАДИУСЫ, все три, а не одни цвета. Запас на случай отсутствия файла обязателен
# у каждого читателя контракта: приложение обязано подняться и работать без него.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==== Общая библиотека — единственный источник вида и общих частей окна =====
# lib\ — копии общей библиотеки, их кладёт сборщик выпуска; руками они не правятся. Цвета, числа,
# радиусы и шрифт — функциями Цвет-Контракта, Число-Оболочки, Радиус-Контракта, Шрифт; своих
# запасных чисел нет.
foreach ($общее in @('app-shell.ps1', 'tray-place.ps1')) {
    $путьОбщего = Join-Path $PSScriptRoot ('lib\' + $общее)
    if (-not (Test-Path -LiteralPath $путьОбщего)) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(('SteamDeck-KVM не запущен: нет общей библиотеки' + [Environment]::NewLine + $путьОбщего), 'SteamDeck-KVM')  # системный диалог: без общей библиотеки своего окна не собрать — это единственный способ сказать причину
        throw ('нет общей библиотеки: ' + $путьОбщего)
    }
    . $путьОбщего
}

$C_BG     = Цвет-Контракта 'фон'
$C_CARD   = Цвет-Контракта 'карточка'
$C_HI     = Цвет-Контракта 'подсветка'
$C_LINE   = Цвет-Контракта 'линия'
$C_TEXT   = Цвет-Контракта 'текст'
$C_DIM    = Цвет-Контракта 'текст_второй'
$C_ACCENT = Цвет-Контракта 'акцент'
$C_OK     = Цвет-Контракта 'успех'
$C_WAIT   = Цвет-Контракта 'ожидание'
$C_ALARM  = Цвет-Контракта 'тревога'
$script:R_CARD = Радиус-Контракта 'карточка'
$script:R_BTN  = Радиус-Контракта 'кнопка'

# Обработчика Resize здесь нет намеренно: окно неизменяемого размера
# (FormBorderStyle = FixedSingle, MaximizeBox = false), контролы не тянутся, и
# область отсечения посчитанная один раз остаётся верной всё время жизни окна.
# Появится растяжение — пересчёт обязан вернуться вместе с ним.

# ==== Значок: один рисунок и один цвет на трей, шапку и ярлык =================
# Канон запрещает подмену цвета значка по состоянию: состояние показывает ОКНО —
# точка, заголовок и цвет тумблера. Цвет берётся из поля «значок.цвет» контракта.
function Новый-Значок([int]$размер = 32) {
    $имяЦвета = 'акцент'
    if ((Контракт-Вида).'значок'.'цвет') { $имяЦвета = [string](Контракт-Вида).'значок'.'цвет' }
    $цвет = Цвет-Контракта $имяЦвета
    $bmp = New-Object System.Drawing.Bitmap($размер, $размер)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $шрифт = Шрифт-Символов ($размер * 0.62) $true  # знак ⇄ есть только в символьной гарнитуре контракта
        $кисть = New-Object System.Drawing.SolidBrush $цвет
        $формат = New-Object System.Drawing.StringFormat
        $формат.Alignment = [System.Drawing.StringAlignment]::Center
        $формат.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString([string][char]0x21C4, $шрифт, $кисть,
            (New-Object System.Drawing.RectangleF(0, 0, $размер, $размер)), $формат)
    } finally { $g.Dispose() }
    return $bmp
}

# .ico собирается из четырёх размеров: System.Drawing умеет отдать только один
# кадр 32x32 через GetHicon, а панель задач берёт 32 и 48, проводник — 256,
# заголовок окна — 16. Значок из одного кадра Windows растягивает сама, и в
# панели задач он выглядит ДРУГИМ рисунком — мыльным и иначе обрезанным.
# Замер 12.09.2026: в трее и в шапке стоял ⇄ из памяти, в панели задач —
# растянутый он же, и пользователь видел три разных значка одного приложения.
function Кадр-DIB($bmp) {
    <#
      Один кадр .ico в виде BITMAPINFOHEADER + пиксели + маска прозрачности.

      ПОЧЕМУ НЕ PNG. Формат .ico разрешает класть кадр как PNG, и так короче
      кода, но System.Drawing читает такой кадр не до конца: замер 12.09.2026 —
      Icon.ToBitmap() на собранном из PNG файле падает «range extends past the
      end of the array», а Windows рисует в панели задач растянутый огрызок.
      Классический DIB понимают и проводник, и панель задач, и .NET.

      Высота в заголовке ДВОЙНАЯ — так требует формат: за цветными строками
      идёт однобитная маска. При 32 битах на точку прозрачность берётся из
      альфа-канала, но маска всё равно обязана присутствовать, иначе смещения
      следующих кадров считаются неверно.
    #>
    $ш = $bmp.Width; $в = $bmp.Height
    $данные = $bmp.LockBits(
        (New-Object System.Drawing.Rectangle(0, 0, $ш, $в)),
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $пиксели = New-Object byte[] ($ш * $в * 4)
    try {
        for ($строка = 0; $строка -lt $в; $строка++) {
            # Строки в DIB идут СНИЗУ ВВЕРХ — перевёрнутый значок выглядит
            # поломкой рисунка, а не ошибкой формата.
            $источник = [IntPtr]::Add($данные.Scan0, $данные.Stride * ($в - 1 - $строка))
            [System.Runtime.InteropServices.Marshal]::Copy($источник, $пиксели, $строка * $ш * 4, $ш * 4)
        }
    } finally { $bmp.UnlockBits($данные) }

    $ширинаМаски = [int][Math]::Ceiling($ш / 32.0) * 4
    $маска = New-Object byte[] ($ширинаМаски * $в)

    $поток = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($поток)
    $w.Write([uint32]40); $w.Write([int32]$ш); $w.Write([int32]($в * 2))
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]0)
    $w.Write([uint32]($пиксели.Length + $маска.Length))
    $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    $w.Write($пиксели); $w.Write($маска)
    $w.Flush()
    $итог = $поток.ToArray()
    $w.Dispose(); $поток.Dispose()
    # Запятая обязательна: без неё PowerShell разворачивает массив байтов в
    # поток значений, вызывающий получает Object[] вместо byte[], и в файл
    # уходит пустота. Замер 12.09.2026: .ico вышел на 74 байта вместо 350 КБ.
    return , $итог
}

function Собрать-Ico([string]$Путь, [int[]]$Размеры = @(16, 32, 48, 256)) {
    # Кадры нужны все четыре: 16 — шапка окна и меню, 32 и 48 — панель задач
    # при разном масштабе, 256 — проводник. Однокадровый .ico Windows тянет
    # сама, и в панели задач получается мыло — то есть на вид другой значок.
    $кадры = @()
    foreach ($размер in $Размеры) {
        $bmp = Новый-Значок $размер
        $кадры += , @{ Размер = $размер; Байты = [byte[]](Кадр-DIB $bmp) }
        $bmp.Dispose()
    }
    $файл = [System.IO.File]::Create($Путь)
    $w = New-Object System.IO.BinaryWriter($файл)
    try {
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$кадры.Count)
        $смещение = 6 + 16 * $кадры.Count
        foreach ($кадр in $кадры) {
            # 256 записывается нулём: в поле размера один байт, и 256 в него не влезает.
            $байтРазмера = if ($кадр.Размер -ge 256) { 0 } else { $кадр.Размер }
            $w.Write([byte]$байтРазмера); $w.Write([byte]$байтРазмера)
            $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32)
            $w.Write([uint32]$кадр.Байты.Length); $w.Write([uint32]$смещение)
            $смещение += $кадр.Байты.Length
        }
        foreach ($кадр in $кадры) { $w.Write($кадр.Байты) }
    } finally { $w.Dispose(); $файл.Dispose() }
}

# ЕДИНСТВЕННЫЙ источник значка на всё приложение: шапка окна, панель задач,
# трей, оба ярлыка. Пока рисунок собирался в памяти отдельно для окна и
# отдельно для трея, а в ярлыке лежал третий из файла, — это были три значка.
$script:IconPath = Join-Path $PSScriptRoot 'SteamDeck-KVM.ico'
$script:IconCache = $null
function Значок-Приложения {
    if ($script:IconCache) { return $script:IconCache }
    try {
        if (-not (Test-Path $script:IconPath)) { Собрать-Ico $script:IconPath }
        $script:IconCache = New-Object System.Drawing.Icon($script:IconPath)
    } catch {
        # Файл не собрался и не прочитался — приложение обязано подняться:
        # значок из памяти хуже, но лучше, чем окно без значка вовсе.
        $bmp = Новый-Значок 32
        $script:IconCache = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    }
    return $script:IconCache
}

# Значок трея берётся из ТОГО ЖЕ файла, размером 16: иначе трей рисует свой.
function Значок-Трея {
    try { return New-Object System.Drawing.Icon((Значок-Приложения), 16, 16) }
    catch { return Значок-Приложения }
}

# ==== Своё имя в панели задач ================================================
# Панель задач опознаёт приложение НЕ по значку окна, а по имени приложения
# (AppUserModelID). Своего у нас не было, и Windows подставляла имя процесса —
# powershell.exe, — а вместе с ним и его синий значок: замер 12.09.2026, в шапке
# окна стоял наш ⇄, в панели задач — чужой квадрат. Значок окна тут ни при чём,
# и менять его было бесполезно.
#
# Имя обязано ставиться ДО создания первого окна: после — Windows уже приняла
# решение о группировке, и смена ничего не меняет до перезапуска.
Add-Type -Namespace Win32 -Name Shell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
'@ -ErrorAction SilentlyContinue

function Назвать-Приложение([string]$Имя = 'SteamDeckKVM.SharedKeyboard') {
    try { [Win32.Shell]::SetCurrentProcessExplicitAppUserModelID($Имя) | Out-Null } catch { }
}

# ==== Свои диалоги вместо системного MessageBox ==============================
# Системный диалог приходит в оформлении Windows по умолчанию: белый фон, чужая
# гарнитура, синяя иконка — рядом с тёмным окном приложения он читается как окно
# другой программы. Канон требует одного вида у всего, что видит человек.
function Показать-Сообщение {
    param(
        [Parameter(Mandatory)][string]$Заголовок,
        [Parameter(Mandatory)][string]$Текст,
        $Владелец = $null,
        [string]$Действие = 'Понятно',
        [switch]$СпроситьДаНет
    )
    $поле = [int](Число-Оболочки 'окно_поле')
    $ширина = 400
    $высотаКнопки = [int](Число-Оболочки 'окно_кнопка')

    $диалог = New-Object System.Windows.Forms.Form
    $диалог.Text = $Заголовок
    $диалог.FormBorderStyle = 'FixedDialog'
    $диалог.MaximizeBox = $false
    $диалог.MinimizeBox = $false
    $диалог.ShowInTaskbar = $false
    $диалог.BackColor = $C_BG
    $диалог.ForeColor = $C_TEXT
    $диалог.Font = Шрифт 9.5
    $диалог.StartPosition = if ($Владелец) { 'CenterParent' } else { 'CenterScreen' }
    try { $диалог.Icon = Значок-Приложения } catch { }
    Тёмная-Шапка $диалог

    $шапка = New-Object System.Windows.Forms.Label
    $шапка.Text = $Заголовок
    $шапка.Font = Шрифт (Число-Оболочки 'окно_кегль_заголовка') $true
    $шапка.ForeColor = $C_TEXT
    $шапка.AutoSize = $false
    $шапка.Location = New-Object System.Drawing.Point($поле, $поле)
    $шапка.Size = New-Object System.Drawing.Size(($ширина - 2 * $поле), 24)
    $диалог.Controls.Add($шапка)

    # Высота текста МЕРЯЕТСЯ, а не задаётся: иначе последняя строка обрезается
    # молча, как только текст подрастёт на одно предложение.
    $тело = New-Object System.Windows.Forms.Label
    $тело.Text = $Текст
    $тело.Font = Шрифт 9.5
    $тело.ForeColor = $C_DIM
    $тело.AutoSize = $false
    $тело.Location = New-Object System.Drawing.Point($поле, ($поле + 28))
    $ширинаТекста = $ширина - 2 * $поле
    $g = $диалог.CreateGraphics()
    $измер = $g.MeasureString($Текст, $тело.Font, $ширинаТекста)
    $g.Dispose()
    $высотаТекста = [int][Math]::Ceiling($измер.Height) + 8
    $тело.Size = New-Object System.Drawing.Size($ширинаТекста, $высотаТекста)
    $диалог.Controls.Add($тело)

    $низ = $поле + 28 + $высотаТекста + 8
    $кнопки = @()
    if ($СпроситьДаНет) {
        $кнопки = @(
            @{ Текст = $Действие; Итог = [System.Windows.Forms.DialogResult]::Yes;    Главная = $true },
            @{ Текст = 'Отмена';  Итог = [System.Windows.Forms.DialogResult]::Cancel; Главная = $false }
        )
    } else {
        $кнопки = @(@{ Текст = $Действие; Итог = [System.Windows.Forms.DialogResult]::OK; Главная = $true })
    }

    $ширинаКнопки = 96
    $зазор = 8
    $всего = $кнопки.Count * $ширинаКнопки + ($кнопки.Count - 1) * $зазор
    $x = $ширина - $поле - $всего
    foreach ($описание in $кнопки) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $описание.Текст
        $b.Size = New-Object System.Drawing.Size($ширинаКнопки, $высотаКнопки)
        $b.Location = New-Object System.Drawing.Point($x, $низ)
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.Font = Шрифт (Число-Оболочки 'окно_кегль') $описание.Главная
        if ($описание.Главная) {
            $b.BackColor = $C_ACCENT
            $b.ForeColor = $C_BG
            $диалог.AcceptButton = $b
        } else {
            $b.BackColor = $C_HI
            $b.ForeColor = $C_TEXT
            $диалог.CancelButton = $b
        }
        $b.DialogResult = $описание.Итог
        Скруглить $b $script:R_BTN
        $диалог.Controls.Add($b)
        $x += $ширинаКнопки + $зазор
    }

    $диалог.ClientSize = New-Object System.Drawing.Size($ширина, ($низ + $высотаКнопки + $поле))
    if ($Владелец) { return $диалог.ShowDialog($Владелец) }
    return $диалог.ShowDialog()
}

# ==== Само окно ==============================================================
# Раскладка идёт КУРСОРОМ: каждая следующая строка от низа предыдущей. Числа,
# посчитанные от других чисел раскладки, — отложенный дефект: они верны ровно
# для того набора строк, который был в день их подбора.
function New-AppWindow {
    param([int]$Ширина = 420)

    # Плотность — из контракта «оболочка», как у меню трея: кнопки 36 и тумблер 54 точки
    # пользователь назвал огромными 23.09.2026.
    $поле = [int](Число-Оболочки 'окно_поле')       # поле окна по краям
    $вКарточке = $поле                               # внутреннее поле карточки
    $междуСтрок = 22    # шаг строки фактов
    $ширинаПодписи = 124
    $высотаКнопки = [int](Число-Оболочки 'окно_кнопка')
    $кегль = Число-Оболочки 'окно_кегль'

    $окно = New-Object System.Windows.Forms.Form
    $окно.Text = 'Общая клавиатура и мышь'
    $окно.FormBorderStyle = 'FixedSingle'
    $окно.MaximizeBox = $false
    $окно.StartPosition = 'CenterScreen'
    $окно.BackColor = $C_BG
    $окно.ForeColor = $C_TEXT
    $окно.Font = Шрифт $кегль
    try { $окно.Icon = Значок-Приложения } catch { }
    Тёмная-Шапка $окно
    # Стекло библиотеки — один вид всех поверхностей приложения: размытие позади окна при каждом показе.
    $окно.Add_Shown({ param($s, $e) Стекло $s })

    $ширинаСодержимого = $Ширина - 2 * $поле

    function Новая-Надпись($родитель, [int]$x, [int]$y, [int]$ш, [int]$в, [string]$текст, $цвет, [double]$кегль, [bool]$жирный) {
        $l = New-Object System.Windows.Forms.Label
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($ш, $в)
        $l.Text = $текст
        $l.ForeColor = $цвет
        $l.BackColor = [System.Drawing.Color]::Transparent
        $l.Font = Шрифт $кегль $жирный
        $родитель.Controls.Add($l)
        return $l
    }

    $y = $поле

    # --- карточка состояния: высота считается от содержимого ---
    $карточка = New-Object System.Windows.Forms.Panel
    $карточка.Location = New-Object System.Drawing.Point($поле, $y)
    $карточка.Width = $ширинаСодержимого
    $карточка.BackColor = $C_CARD
    $окно.Controls.Add($карточка)

    $вy = $вКарточке
    $точка = Новая-Надпись $карточка $вКарточке ($вy + 1) 20 22 ([string][char]0x25CF) $C_DIM 12 $false
    $левоТекста = $вКарточке + 24
    $ширинаТекста = $ширинаСодержимого - $левоТекста - $вКарточке
    $состояние = Новая-Надпись $карточка $левоТекста $вy $ширинаТекста 24 'Выключено' $C_TEXT (Число-Оболочки 'окно_кегль_заголовка') $true
    $вy += 26
    # Две строки подсказки — худший случай; высота карточки считается по нему,
    # а не по той строке, что написана сегодня.
    $подсказка = Новая-Надпись $карточка $левоТекста $вy $ширинаТекста 36 '' $C_DIM $кегль $false
    $вy += 36 + $вКарточке
    $карточка.Height = $вy
    Скруглить $карточка $script:R_CARD

    $y += $карточка.Height + 8

    # --- тумблер: ОДИН элемент, показывает действие, а не состояние ---
    $тумблер = New-Object System.Windows.Forms.Button
    $тумблер.Location = New-Object System.Drawing.Point($поле, $y)
    $тумблер.Size = New-Object System.Drawing.Size($ширинаСодержимого, ($высотаКнопки + 4))
    $тумблер.Text = 'Включить'
    $тумблер.FlatStyle = 'Flat'
    $тумблер.FlatAppearance.BorderSize = 0
    $тумблер.BackColor = $C_ACCENT
    $тумблер.ForeColor = $C_BG
    $тумблер.Font = Шрифт 10.5 $true
    $тумблер.TabIndex = 0
    Скруглить $тумблер $script:R_BTN
    $окно.Controls.Add($тумблер)

    $y += $тумблер.Height + 10

    # --- строки фактов ---
    # Строки «Переход» нет: способ перехода зависит от настроек и сказан подсказкой карточки, а в
    # строке факта перечень способов не помещался и обрезался многоточием (снимок 23.09.2026).
    $факты = @{}
    foreach ($подпись in @('Steam Deck', 'Этот компьютер', 'Версия')) {
        Новая-Надпись $окно $поле $y $ширинаПодписи 20 $подпись $C_DIM $кегль $false | Out-Null
        $значение = Новая-Надпись $окно ($поле + $ширинаПодписи) $y ($ширинаСодержимого - $ширинаПодписи) 20 '—' $C_TEXT $кегль $true
        # Строка факта — ОДНА строка с многоточием, а не перенос: имя Deck'а
        # длины не имеет предела, и перенос уронил бы на неё соседнюю строку.
        # Многоточие человек видит, молчаливый обрез — нет.
        $значение.AutoEllipsis = $true
        $факты[$подпись] = $значение
        $y += $междуСтрок
    }

    $y += 6

    # --- ряд кнопок: ширина считается от карточки ---
    # «Перейти на Deck» — частое действие, поэтому в окне, а не в настройках; знакомство с Deck'ом
    # и его установка — редкие, они в окне настроек (редкие действия живут в настройках).
    $подписи = @('Перейти на Deck', 'Настройки', 'Журнал')
    $зазор = 6
    $ширинаКнопки = [int](($ширинаСодержимого - $зазор * ($подписи.Count - 1)) / $подписи.Count)
    $кнопки = @{}
    $x = $поле
    $индекс = 1
    foreach ($подпись in $подписи) {
        $b = New-Object System.Windows.Forms.Button
        $b.Location = New-Object System.Drawing.Point($x, $y)
        $b.Size = New-Object System.Drawing.Size($ширинаКнопки, $высотаКнопки)
        $b.Text = $подпись
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $C_LINE
        $b.BackColor = $C_HI
        $b.ForeColor = $C_TEXT
        $b.Font = Шрифт 8.5
        $b.TabIndex = $индекс
        Скруглить $b $script:R_BTN
        $окно.Controls.Add($b)
        $кнопки[$подпись] = $b
        $x += $ширинаКнопки + $зазор
        $индекс++
    }
    $y += $высотаКнопки + 8

    $подвал = Новая-Надпись $окно $поле $y $ширинаСодержимого 30 'Крестик сворачивает окно в трей — связь не рвётся. Выход — правой кнопкой по значку.' $C_DIM 8 $false
    $y += 30 + $поле

    # --- обновление: полоса существует всегда, но видна, только когда обновление есть ---
    # Канон приложений: пункта «проверить обновления» не бывает — проверка идёт сама, а кнопка
    # либо есть, либо её нет. Полоса стоит ПОСЛЕ подвала: показанная, она раздвигает окно вниз и
    # не сдвигает ни одной строки выше — раскладка остальных строк от неё не зависит.
    $высотаБезОбновления = $y
    $обновление = New-Object System.Windows.Forms.Button
    $обновление.Location = New-Object System.Drawing.Point($поле, ($y - $поле + 4))
    $обновление.Size = New-Object System.Drawing.Size($ширинаСодержимого, $высотаКнопки)
    $обновление.FlatStyle = 'Flat'
    $обновление.FlatAppearance.BorderSize = 0
    $обновление.BackColor = $C_ACCENT
    $обновление.ForeColor = $C_BG
    $обновление.Font = Шрифт $кегль $true
    $обновление.AutoEllipsis = $true
    $обновление.Visible = $false
    $обновление.TabIndex = $индекс
    Скруглить $обновление $script:R_BTN
    $окно.Controls.Add($обновление)
    $высотаСОбновлением = $обновление.Bottom + $поле

    # Высота окна ВЫЧИСЛЯЕТСЯ курсором, а не подбирается: добавленная строка
    # раздвигает окно сама, вместо того чтобы уехать за нижний край молча.
    $окно.ClientSize = New-Object System.Drawing.Size($Ширина, $высотаБезОбновления)

    return [pscustomobject]@{
        Форма      = $окно
        Точка      = $точка
        Состояние  = $состояние
        Подсказка  = $подсказка
        Тумблер    = $тумблер
        Карточка   = $карточка
        Факты      = $факты
        Кнопки     = $кнопки
        Подвал     = $подвал
        Обновление = $обновление
        Высоты     = @{ Без = $высотаБезОбновления; С = $высотаСОбновлением; Ширина = $Ширина }
        Цвета      = @{ Фон = $C_BG; Карточка = $C_CARD; Текст = $C_TEXT; Тусклый = $C_DIM
                        Акцент = $C_ACCENT; Успех = $C_OK; Ожидание = $C_WAIT; Тревога = $C_ALARM }
    }
}

# ==== Окно настроек ==========================================================
# Окно строит общая функция библиотеки `Окно-Настроек` (lib\app-shell.ps1): разделы слева, строки
# справа, «Сохранить» и «Отмена» внизу. Здесь только описание строк; его же берёт сторож компоновки.
# Ссылок на папки внизу нет: кнопка ведёт только внутрь приложения или в браузер.
function Описание-Настроек {
    param([hashtable]$Настройки, [string]$ИмяDeck = '', [scriptblock]$Забыть = { }, [scriptblock]$Установка = { })
    $знакомый = if ($ИмяDeck) { 'Знакомый Deck — ' + $ИмяDeck } else { 'Deck ещё не знаком' }
    return @(
        @{ Имя = 'Переход'; Строки = @(
            @{ Вид = 'флажок'; Подпись = 'Alt+Tab — окно «Steam Deck» в списке'; Ключ = 'alt_tab'; Значение = [bool]$Настройки.alt_tab },
            @{ Вид = 'флажок'; Подпись = 'Край экрана'; Ключ = 'edge'; Значение = [bool]$Настройки.edge },
            @{ Вид = 'выбор'; Подпись = 'Deck стоит'; Ключ = 'side'; Значение = [string]$Настройки.side
               Варианты = @(@{ Имя = 'left'; Подпись = 'Слева' }, @{ Имя = 'right'; Подпись = 'Справа' }) },
            @{ Вид = 'надпись'; Подпись = 'Кнопка «Перейти на Deck» работает всегда.'; Цвет = $C_DIM }
        ) },
        @{ Имя = 'Steam Deck'; Строки = @(
            @{ Вид = 'действие'; Подпись = $знакомый; Кнопка = 'Забыть'; Действие = $Забыть },
            @{ Вид = 'действие'; Подпись = 'Приложение на Deck''е'; Кнопка = 'Как установить'; Действие = $Установка }
        ) }
    )
}

# ==== Окно журнала ===========================================================
# Журнал читается внутри приложения, а не текстовым файлом в Блокноте: кнопка приложения ведёт
# только в его окна или в браузер. Цвет строки — по смыслу: запуск, сбой, обычная.
function New-LogWindow {
    $поле = [int](Число-Оболочки 'окно_поле')
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Общая клавиатура и мышь — журнал'
    $f.StartPosition = 'CenterParent'
    $f.BackColor = $C_BG
    $f.ForeColor = $C_TEXT
    $f.Font = Шрифт (Число-Оболочки 'окно_кегль')
    $f.MinimumSize = New-Object System.Drawing.Size(480, 320)
    $f.ClientSize = New-Object System.Drawing.Size(640, 440)
    try { $f.Icon = Значок-Приложения } catch { }
    Тёмная-Шапка $f
    $f.Add_Shown({ param($s, $e) Стекло $s })

    $карточка = New-Object System.Windows.Forms.Panel
    $карточка.BackColor = $C_CARD
    $карточка.Location = New-Object System.Drawing.Point($поле, $поле)
    $карточка.Size = New-Object System.Drawing.Size(($f.ClientSize.Width - 2 * $поле), ($f.ClientSize.Height - 2 * $поле))
    $карточка.Anchor = 'Top,Left,Right,Bottom'
    $карточка.Padding = New-Object System.Windows.Forms.Padding(8)
    $f.Controls.Add($карточка)

    $текст = New-Object System.Windows.Forms.RichTextBox
    $текст.Dock = 'Fill'
    $текст.ReadOnly = $true
    $текст.BorderStyle = 'None'
    $текст.BackColor = $C_CARD
    $текст.ForeColor = $C_DIM
    $текст.Font = Шрифт 9
    $текст.WordWrap = $false
    $карточка.Controls.Add($текст)
    Тёмный-Контрол $текст
    # Скругление пересчитывается на каждое изменение размера: окно журнала растягивается.
    $карточка.Add_Resize({ param($s, $e) Скруглить $s $script:R_CARD })
    Скруглить $карточка $script:R_CARD
    return [pscustomobject]@{ Форма = $f; Текст = $текст; Карточка = $карточка }
}

function Заполнить-Журнал($Поле, [string[]]$Строки) {
    # Строки перерисовываются целиком, только когда их стало больше: иначе прокрутка человека
    # сбрасывалась бы на каждом тике часов.
    if ($Поле.Tag -eq $Строки.Count) { return }
    $Поле.Tag = $Строки.Count
    $Поле.Clear()
    if (-not $Строки.Count) { $Поле.Text = 'Журнал пока пуст.'; return }
    foreach ($s in $Строки) {
        $цвет = $C_DIM; $жирный = $false
        if ($s -match '=== (запуск|выход)') { $цвет = $C_ACCENT; $жирный = $true }
        elseif ($s -match 'ОШИБКА|ДЕФЕКТ|ТРАП|сбой|не удал') { $цвет = $C_WAIT }
        elseif ($s -match 'подключ|переход|перевёл|вернул') { $цвет = $C_TEXT }
        $Поле.SelectionStart = $Поле.TextLength
        $Поле.SelectionColor = $цвет
        $Поле.SelectionFont = Шрифт 9 $жирный
        $Поле.AppendText($s + [Environment]::NewLine)
    }
    $Поле.SelectionStart = $Поле.TextLength
    $Поле.ScrollToCaret()
}

function Показать-Обновление($ui, [string]$Текст) {
    # Высота берётся из посчитанных при сборке окна чисел, а не прибавляется к текущей:
    # повторный показ той же полосы не должен вырастить окно второй раз.
    $ui.Обновление.Text = $Текст
    $ui.Обновление.Visible = $true
    $ui.Форма.ClientSize = New-Object System.Drawing.Size($ui.Высоты.Ширина, $ui.Высоты.С)
}

function Скрыть-Обновление($ui) {
    $ui.Обновление.Visible = $false
    $ui.Форма.ClientSize = New-Object System.Drawing.Size($ui.Высоты.Ширина, $ui.Высоты.Без)
}

# Имя приложения ставится прямо здесь, при подключении оболочки. Отдельный вызов
# в приложении означал бы, что о нём надо помнить: забытый — возвращает чужой
# значок в панель задач, и виден дефект только на скриншоте.
Назвать-Приложение

# ==== Плашка по правой кнопке на значке =======================================
# Меню значка собирает общая функция библиотеки `Меню-Трея` (`lib\tray-place.ps1`): строки, шрифт,
# отступы, фон, рамка и скругление у всех треев одни. Своей сборки меню у приложения нет.
