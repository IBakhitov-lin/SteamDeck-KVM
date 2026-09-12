# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Оболочка окна: палитра, гарнитура, радиусы, раскладка.
#
# ПОЧЕМУ ОТДЕЛЬНЫМ ФАЙЛОМ, А НЕ ВНУТРИ ПРИЛОЖЕНИЯ — канон оболочки
# (C:\AI\app_canon.md, раздел «Раскладка окна считается, а не задаётся числами»)
# требует сторожа, который перебирает размеры окна и ищет вылезшее за край.
# Сторож обязан собирать ТО ЖЕ окно, что видит человек: повтори числа в стороже
# отдельно — и он начнёт проверять вчерашнюю раскладку, ничего об этом не сказав.
# Поэтому окно собирается здесь, а приложение и сторож оба зовут New-AppWindow.
#
# ЧТО БЕРЁТСЯ ИЗ КОНТРАКТА C:\AI\templates\palette.json — цвета, ГАРНИТУРА и
# РАДИУСЫ, все три, а не одни цвета. Запас на случай отсутствия файла обязателен
# у каждого читателя контракта: приложение обязано подняться и работать без него.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==== Контракт ===============================================================
$script:PalettePath = 'C:\AI\templates\palette.json'
if (-not (Test-Path $script:PalettePath)) {
    $script:PalettePath = Join-Path $PSScriptRoot 'lib\palette.json'
}

$script:Contract = $null
try { $script:Contract = Get-Content -LiteralPath $script:PalettePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
$script:Theme = $null
try { $script:Theme = $script:Contract.'тёмная' } catch { }

function ЦветИзHex([string]$hex, [int[]]$запас) {
    try {
        $h = $hex.TrimStart('#')
        return [System.Drawing.Color]::FromArgb(
            [Convert]::ToInt32($h.Substring(0, 2), 16),
            [Convert]::ToInt32($h.Substring(2, 2), 16),
            [Convert]::ToInt32($h.Substring(4, 2), 16))
    } catch { return [System.Drawing.Color]::FromArgb($запас[0], $запас[1], $запас[2]) }
}

function ИзТемы([string]$имя, [int[]]$запас) {
    if ($script:Theme -and $script:Theme.$имя) { return ЦветИзHex $script:Theme.$имя $запас }
    return [System.Drawing.Color]::FromArgb($запас[0], $запас[1], $запас[2])
}

$C_BG     = ИзТемы 'фон'          @(21, 21, 23)
$C_CARD   = ИзТемы 'карточка'     @(30, 31, 35)
$C_HI     = ИзТемы 'подсветка'    @(40, 42, 47)
$C_LINE   = ИзТемы 'линия'        @(48, 50, 56)
$C_TEXT   = ИзТемы 'текст'        @(240, 241, 244)
$C_DIM    = ИзТемы 'текст_второй' @(160, 165, 173)
$C_ACCENT = ИзТемы 'акцент'       @(110, 170, 255)
$C_OK     = ИзТемы 'успех'        @(70, 200, 120)
$C_WAIT   = ИзТемы 'ожидание'     @(230, 180, 70)
$C_ALARM  = ИзТемы 'тревога'      @(240, 133, 122)

# Гарнитура — ОДНОЙ функцией на всё окно. Восемнадцать упоминаний строкой в
# соседнем приложении означали, что смена шрифта в контракте не меняет ничего.
$script:FontName = 'Segoe UI'
try { if ($script:Contract.'типографика'.'приложение') { $script:FontName = [string]$script:Contract.'типографика'.'приложение' } } catch { }

$script:R_CARD = 16
$script:R_BTN = 8
try { if ($script:Contract.'радиусы'.'карточка') { $script:R_CARD = [int]$script:Contract.'радиусы'.'карточка' } } catch { }
try { if ($script:Contract.'радиусы'.'кнопка')   { $script:R_BTN  = [int]$script:Contract.'радиусы'.'кнопка' } } catch { }

function Шрифт([double]$кегль, [bool]$жирный = $false) {
    if ($жирный) { $стиль = [System.Drawing.FontStyle]::Bold } else { $стиль = [System.Drawing.FontStyle]::Regular }
    return New-Object System.Drawing.Font($script:FontName, $кегль, $стиль)
}

function Скруглить($контрол, [int]$радиус) {
    # WinForms не знает скругления. Единственный способ, не ломающий растяжение
    # по якорю, — область отсечения; она пересчитывается на КАЖДОЕ изменение
    # размера, иначе обрезает контрол по прежнему размеру, пока окно тянут.
    try {
        $ш = $контрол.Width; $в = $контрол.Height
        if ($ш -le 2 -or $в -le 2) { return }
        $r = [Math]::Min($радиус, [int]([Math]::Min($ш, $в) / 2))
        if ($r -le 1) { $контрол.Region = $null; return }
        $d = $r * 2
        $путь = New-Object System.Drawing.Drawing2D.GraphicsPath
        $путь.AddArc(0, 0, $d, $d, 180, 90)
        $путь.AddArc(($ш - $d), 0, $d, $d, 270, 90)
        $путь.AddArc(($ш - $d), ($в - $d), $d, $d, 0, 90)
        $путь.AddArc(0, ($в - $d), $d, $d, 90, 90)
        $путь.CloseFigure()
        $контрол.Region = New-Object System.Drawing.Region($путь)
        $путь.Dispose()
    } catch { }
}

# Обработчика Resize здесь нет намеренно: окно неизменяемого размера
# (FormBorderStyle = FixedSingle, MaximizeBox = false), контролы не тянутся, и
# область отсечения посчитанная один раз остаётся верной всё время жизни окна.
# Появится растяжение — пересчёт обязан вернуться вместе с ним.

# ==== Значок: один рисунок и один цвет на трей, шапку и ярлык =================
# Канон запрещает подмену цвета значка по состоянию: состояние показывает ОКНО —
# точка, заголовок и цвет тумблера. Цвет берётся из поля «значок.цвет» контракта.
function Новый-Значок([int]$размер = 32) {
    $имяЦвета = 'акцент'
    try { if ($script:Contract.'значок'.'цвет') { $имяЦвета = [string]$script:Contract.'значок'.'цвет' } } catch { }
    $цвет = ИзТемы $имяЦвета @(110, 170, 255)
    $bmp = New-Object System.Drawing.Bitmap($размер, $размер)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $шрифт = New-Object System.Drawing.Font('Segoe UI Symbol', ($размер * 0.62), [System.Drawing.FontStyle]::Bold)
        $кисть = New-Object System.Drawing.SolidBrush $цвет
        $формат = New-Object System.Drawing.StringFormat
        $формат.Alignment = [System.Drawing.StringAlignment]::Center
        $формат.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString([string][char]0x21C4, $шрифт, $кисть,
            (New-Object System.Drawing.RectangleF(0, 0, $размер, $размер)), $формат)
    } finally { $g.Dispose() }
    return $bmp
}

$script:IconCache = $null
function Значок-Приложения {
    if ($script:IconCache) { return $script:IconCache }
    $bmp = Новый-Значок 32
    $script:IconCache = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $script:IconCache
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
    $поле = 24
    $ширина = 460

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
    $шапка.Font = Шрифт 13 $true
    $шапка.ForeColor = $C_TEXT
    $шапка.AutoSize = $false
    $шапка.Location = New-Object System.Drawing.Point($поле, $поле)
    $шапка.Size = New-Object System.Drawing.Size(($ширина - 2 * $поле), 28)
    $диалог.Controls.Add($шапка)

    # Высота текста МЕРЯЕТСЯ, а не задаётся: иначе последняя строка обрезается
    # молча, как только текст подрастёт на одно предложение.
    $тело = New-Object System.Windows.Forms.Label
    $тело.Text = $Текст
    $тело.Font = Шрифт 9.5
    $тело.ForeColor = $C_DIM
    $тело.AutoSize = $false
    $тело.Location = New-Object System.Drawing.Point($поле, ($поле + 34))
    $ширинаТекста = $ширина - 2 * $поле
    $g = $диалог.CreateGraphics()
    $измер = $g.MeasureString($Текст, $тело.Font, $ширинаТекста)
    $g.Dispose()
    $высотаТекста = [int][Math]::Ceiling($измер.Height) + 8
    $тело.Size = New-Object System.Drawing.Size($ширинаТекста, $высотаТекста)
    $диалог.Controls.Add($тело)

    $низ = $поле + 34 + $высотаТекста + 20
    $кнопки = @()
    if ($СпроситьДаНет) {
        $кнопки = @(
            @{ Текст = $Действие; Итог = [System.Windows.Forms.DialogResult]::Yes;    Главная = $true },
            @{ Текст = 'Отмена';  Итог = [System.Windows.Forms.DialogResult]::Cancel; Главная = $false }
        )
    } else {
        $кнопки = @(@{ Текст = $Действие; Итог = [System.Windows.Forms.DialogResult]::OK; Главная = $true })
    }

    $ширинаКнопки = 140
    $зазор = 10
    $всего = $кнопки.Count * $ширинаКнопки + ($кнопки.Count - 1) * $зазор
    $x = $ширина - $поле - $всего
    foreach ($описание in $кнопки) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $описание.Текст
        $b.Size = New-Object System.Drawing.Size($ширинаКнопки, 36)
        $b.Location = New-Object System.Drawing.Point($x, $низ)
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.Font = Шрифт 10 $описание.Главная
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

    $диалог.ClientSize = New-Object System.Drawing.Size($ширина, ($низ + 36 + $поле))
    if ($Владелец) { return $диалог.ShowDialog($Владелец) }
    return $диалог.ShowDialog()
}

# ==== Само окно ==============================================================
# Раскладка идёт КУРСОРОМ: каждая следующая строка от низа предыдущей. Числа,
# посчитанные от других чисел раскладки, — отложенный дефект: они верны ровно
# для того набора строк, который был в день их подбора.
function New-AppWindow {
    param([int]$Ширина = 520)

    $поле = 20          # поле окна по краям
    $вКарточке = 18     # внутреннее поле карточки
    $междуСтрок = 26    # шаг строки фактов
    $ширинаПодписи = 138

    $окно = New-Object System.Windows.Forms.Form
    $окно.Text = 'Общая клавиатура и мышь'
    $окно.FormBorderStyle = 'FixedSingle'
    $окно.MaximizeBox = $false
    $окно.StartPosition = 'CenterScreen'
    $окно.BackColor = $C_BG
    $окно.ForeColor = $C_TEXT
    $окно.Font = Шрифт 9.5
    try { $окно.Icon = Значок-Приложения } catch { }
    Тёмная-Шапка $окно

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
    $точка = Новая-Надпись $карточка $вКарточке ($вy + 2) 26 26 ([string][char]0x25CF) $C_DIM 16 $false
    $левоТекста = $вКарточке + 34
    $ширинаТекста = $ширинаСодержимого - $левоТекста - $вКарточке
    $состояние = Новая-Надпись $карточка $левоТекста $вy $ширинаТекста 30 'Выключено' $C_TEXT 15 $true
    $вy += 32
    # Две строки подсказки — худший случай; высота карточки считается по нему,
    # а не по той строке, что написана сегодня.
    $подсказка = Новая-Надпись $карточка $левоТекста $вy $ширинаТекста 36 '' $C_DIM 9.5 $false
    $вy += 36 + $вКарточке
    $карточка.Height = $вy
    Скруглить $карточка $script:R_CARD

    $y += $карточка.Height + 14

    # --- тумблер: ОДИН элемент, показывает действие, а не состояние ---
    $тумблер = New-Object System.Windows.Forms.Button
    $тумблер.Location = New-Object System.Drawing.Point($поле, $y)
    $тумблер.Size = New-Object System.Drawing.Size($ширинаСодержимого, 54)
    $тумблер.Text = 'Включить'
    $тумблер.FlatStyle = 'Flat'
    $тумблер.FlatAppearance.BorderSize = 0
    $тумблер.BackColor = $C_ACCENT
    $тумблер.ForeColor = $C_BG
    $тумблер.Font = Шрифт 13 $true
    $тумблер.TabIndex = 0
    Скруглить $тумблер $script:R_BTN
    $окно.Controls.Add($тумблер)

    $y += $тумблер.Height + 18

    # --- строки фактов ---
    $факты = @{}
    foreach ($подпись in @('Steam Deck', 'Этот компьютер', 'Переход')) {
        Новая-Надпись $окно $поле $y $ширинаПодписи 20 $подпись $C_DIM 9.5 $false | Out-Null
        $значение = Новая-Надпись $окно ($поле + $ширинаПодписи) $y ($ширинаСодержимого - $ширинаПодписи) 20 '—' $C_TEXT 9.5 $true
        # Строка факта — ОДНА строка с многоточием, а не перенос: имя Deck'а
        # длины не имеет предела, и перенос уронил бы на неё соседнюю строку.
        # Многоточие человек видит, молчаливый обрез — нет.
        $значение.AutoEllipsis = $true
        $факты[$подпись] = $значение
        $y += $междуСтрок
    }

    $y += 12

    # --- ряд вспомогательных кнопок: ширина считается от карточки ---
    $подписи = @('Настроить Deck', 'Забыть Deck', 'Журнал', 'В трей')
    $зазор = 8
    $ширинаКнопки = [int](($ширинаСодержимого - $зазор * ($подписи.Count - 1)) / $подписи.Count)
    $кнопки = @{}
    $x = $поле
    $индекс = 1
    foreach ($подпись in $подписи) {
        $b = New-Object System.Windows.Forms.Button
        $b.Location = New-Object System.Drawing.Point($x, $y)
        $b.Size = New-Object System.Drawing.Size($ширинаКнопки, 34)
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
    $y += 34 + 12

    $подвал = Новая-Надпись $окно $поле $y $ширинаСодержимого 18 'Закрытие окна выключает сервер. «В трей» — оставить работать.' $C_DIM 8 $false
    $y += 18 + $поле

    # Высота окна ВЫЧИСЛЯЕТСЯ курсором, а не подбирается: добавленная строка
    # раздвигает окно сама, вместо того чтобы уехать за нижний край молча.
    $окно.ClientSize = New-Object System.Drawing.Size($Ширина, $y)

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
        Цвета      = @{ Фон = $C_BG; Карточка = $C_CARD; Текст = $C_TEXT; Тусклый = $C_DIM
                        Акцент = $C_ACCENT; Успех = $C_OK; Ожидание = $C_WAIT; Тревога = $C_ALARM }
    }
}

# Шапку окна рисует не приложение, а система, и по умолчанию она светлая: тёмное
# окно со светлым заголовком читается как чужая программа ровно так же, как
# системный диалог. Просьба к диспетчеру окон — единственный штатный способ;
# на сборках Windows старше 1809 её просто не слышат, и шапка остаётся светлой.
Add-Type -Namespace Win32 -Name Dwm -MemberDefinition @"
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
"@ -ErrorAction SilentlyContinue

function Тёмная-Шапка($окно) {
    $применить = {
        try {
            $да = 1
            # 20 — нынешний номер свойства, 19 — тот же смысл до сборки 1903.
            [Win32.Dwm]::DwmSetWindowAttribute($окно.Handle, 20, [ref]$да, 4) | Out-Null
            [Win32.Dwm]::DwmSetWindowAttribute($окно.Handle, 19, [ref]$да, 4) | Out-Null
        } catch { }
    }.GetNewClosure()
    # Свойство ставится по УКАЗАТЕЛЮ окна, а тот появляется только после создания:
    # вызов до него молча ничего не делает.
    if ($окно.IsHandleCreated) { & $применить } else { $окно.Add_HandleCreated($применить) }
}

function Поднять-Наверх($окно) {
    # Поднять и развернуть — РАЗНЫЕ действия, и одно другого не делает.
    #
    # РАЗВЕРНУТЬ. Свойство WindowState формы говорит о намерении, а не о факте:
    # свёрнутое системой окно отвечает «Normal» и остаётся свёрнутым. Замер
    # 12.09.2026: приложение писало в журнал «видимость=True, состояние=Normal»,
    # а окно лежало в панели задач полоской 160×28. Разворачивает только просьба
    # к системе по указателю окна.
    #
    # ПОДНЯТЬ. Windows отдаёт передний план только процессу, который последним
    # работал с вводом; приложение в трее им не является, и Activate() молча
    # гасится. Обход штатный: окно на мгновение объявляется поверх всех и тут же
    # перестаёт им быть — оставить его поверх всех значило бы закрыть чужую работу.
    try {
        if ([Win32.Dwm]::IsIconic($окно.Handle)) {
            [Win32.Dwm]::ShowWindow($окно.Handle, 9) | Out-Null   # SW_RESTORE
        }
        $окно.TopMost = $true
        $окно.Activate()
        $окно.BringToFront()
        $окно.TopMost = $false
    } catch { }
}
