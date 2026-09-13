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
# Порядок поиска: общий контракт машины автора → копия в архиве выпуска (lib\) → копия в
# репозитории (apps\palette.json). Копии собирает сборщик выпуска из контракта в момент сборки,
# поэтому у человека, скачавшего архив, вид совпадает с видом на машине автора.
$script:PalettePath = $null
foreach ($кандидат in @('C:\AI\templates\palette.json',
                        (Join-Path $PSScriptRoot 'lib\palette.json'),
                        (Join-Path $PSScriptRoot '..\palette.json'))) {
    if (Test-Path -LiteralPath $кандидат) { $script:PalettePath = $кандидат; break }
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
    foreach ($подпись in @('Steam Deck', 'Этот компьютер', 'Переход', 'Версия')) {
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
    $подписи = @('Настроить Deck', 'Забыть Deck', 'Журнал')
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

    $подвал = Новая-Надпись $окно $поле $y $ширинаСодержимого 18 'Крестик сворачивает окно в трей — связь не рвётся. Выход — правой кнопкой по значку.' $C_DIM 8 $false
    $y += 18 + $поле

    # --- обновление: полоса существует всегда, но видна, только когда обновление есть ---
    # Канон приложений: пункта «проверить обновления» не бывает — проверка идёт сама, а кнопка
    # либо есть, либо её нет. Полоса стоит ПОСЛЕ подвала: показанная, она раздвигает окно вниз и
    # не сдвигает ни одной строки выше — раскладка остальных строк от неё не зависит.
    $высотаБезОбновления = $y
    $обновление = New-Object System.Windows.Forms.Button
    $обновление.Location = New-Object System.Drawing.Point($поле, ($y - $поле + 4))
    $обновление.Size = New-Object System.Drawing.Size($ширинаСодержимого, 40)
    $обновление.FlatStyle = 'Flat'
    $обновление.FlatAppearance.BorderSize = 0
    $обновление.BackColor = $C_ACCENT
    $обновление.ForeColor = $C_BG
    $обновление.Font = Шрифт 10.5 $true
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

# Имя приложения ставится прямо здесь, при подключении оболочки. Отдельный вызов
# в приложении означал бы, что о нём надо помнить: забытый — возвращает чужой
# значок в панель задач, и виден дефект только на скриншоте.
Назвать-Приложение

# ==== Плашка по правой кнопке на значке =======================================
# Прежде правая кнопка поднимала СИСТЕМНОЕ меню Windows. Место Windows выбирает
# верно, но вид у него чужой: светлое меню посреди тёмного приложения читается
# как всплывшее окно другой программы, и состояния в нём не видно — только
# пункты. Канон приложений (`C:\AIpp_canon.md`, раздел «Трей») требует своей
# плашки: состояние словом и цветом, три пункта, шапка открывает окно.
#
# Место и раскладка берутся ОБЩЕЙ механикой: правило одно на все приложения со
# значком в трее, и у него три потребителя.
$ОбщаяМеханикаПлашки = 'C:\AI\scripts\tray-place.ps1'
if (-not (Test-Path -LiteralPath $ОбщаяМеханикаПлашки)) {
    # В архиве выпуска общая механика лежит копией, собранной из того же файла при сборке.
    $ОбщаяМеханикаПлашки = Join-Path $PSScriptRoot 'lib\tray-place.ps1'
}
if (Test-Path -LiteralPath $ОбщаяМеханикаПлашки) {
    try { . $ОбщаяМеханикаПлашки } catch { Write-Log ('общая механика плашки не прочиталась: ' + $_.Exception.Message) }
}
if (-not (Get-Command 'Место-Плашки' -ErrorAction SilentlyContinue)) {
    # Запас: без общего файла плашка встаёт у курсора без привязки к панели задач,
    # а приложение работает. Отказ подняться из-за отсутствующего файла правил
    # хуже неидеального места плашки.
    function Место-Плашки([int]$ш, [int]$в, $курсор, $рабочая, $границы) {
        $x = [Math]::Max($рабочая.Left + 8, [Math]::Min($курсор.X, $рабочая.Right - $ш - 8))
        $y = [Math]::Max($рабочая.Top + 8, [Math]::Min($курсор.Y, $рабочая.Bottom - $в - 8))
        return (New-Object System.Drawing.Point([int]$x, [int]$y))
    }
    function Высота-Строки-Плашки([double]$кегль) { return [int]($кегль * 2.2) + 6 }
    function Раскладка-Плашки($строки, [int]$поле, [int]$зазорСтрок, [int]$зазорДоКнопок,
                              [int]$высотаКнопки, [int]$подвал, [int]$пунктов = 2) {
        $курсор = $поле
        foreach ($с in $строки) {
            $с['Высота'] = Высота-Строки-Плашки $с.Кегль
            $с['Y'] = $курсор
            $курсор += $с.Высота + $зазорСтрок
        }
        $высотаШапки = $курсор - $зазорСтрок + $поле
        $ряды = @(); $верх = $высотаШапки + $зазорДоКнопок
        for ($i = 0; $i -lt [Math]::Max(1, $пунктов); $i++) { $ряды += $верх; $верх += $высотаКнопки + 6 }
        return @{ ВысотаШапки = $высотаШапки; ВерхРяда = $ряды[0]; Ряды = $ряды; Высота = $верх - 6 + $подвал }
    }
}

function Новая-Плашка {
    <#
      Плашка значка: состояние словом и цветом, шапка открывает окно, под ней два
      пункта — тумблер и выход.

      Раскладка СЧИТАЕТСЯ от содержимого, а не задаётся числами: строка состояния
      бывает длиннее или короче, и число, верное для сегодняшнего набора строк,
      обрезает завтрашний — WinForms делает это МОЛЧА.

      Функция только СОБИРАЕТ плашку и возвращает её части; что делают пункты,
      решает приложение — оно одно знает, включён ли сервер.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Состояние,
        [Parameter(Mandatory = $true)]$ЦветСостояния,
        [string]$Пояснение = '',
        [Parameter(Mandatory = $true)][string]$ТекстТумблера,
        [Parameter(Mandatory = $true)]$ЦветТумблера
    )

    $ш = 320
    $поле = 16
    $зазорСтрок = 4
    $зазорДоКнопок = 12
    $высотаКнопки = 36
    $подвал = 14

    $строки = @(
        @{ Текст = 'Общая клавиатура и мышь'; Кегль = 11;  Цвет = $C_TEXT;        Жирная = $true },
        @{ Текст = $Состояние;                Кегль = 9.5; Цвет = $ЦветСостояния; Жирная = $false }
    )
    if ($Пояснение) {
        $строки += @{ Текст = $Пояснение; Кегль = 8.5; Цвет = $C_DIM; Жирная = $false }
    } else {
        $строки += @{ Текст = 'нажмите, чтобы открыть окно'; Кегль = 8.5; Цвет = $C_LINE; Жирная = $false }
    }
    $раскладка = Раскладка-Плашки $строки $поле $зазорСтрок $зазорДоКнопок $высотаКнопки $подвал 2

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.StartPosition = 'Manual'
    $f.Size = New-Object System.Drawing.Size($ш, $раскладка.Высота)
    $f.BackColor = $C_CARD
    $f.ForeColor = $C_TEXT
    $f.Font = Шрифт 9.5
    try { $f.Icon = Значок-Приложения } catch { }
    Скруглить $f $script:R_CARD

    $курсорМыши = [System.Windows.Forms.Cursor]::Position
    $экран = [System.Windows.Forms.Screen]::FromPoint($курсорМыши)
    $f.Location = Место-Плашки $ш $раскладка.Высота $курсорМыши $экран.WorkingArea $экран.Bounds
    $f.Add_Paint({
        param($s, $e)
        $перо = New-Object System.Drawing.Pen($C_LINE, 1)
        $e.Graphics.DrawRectangle($перо, 0, 0, $s.Width - 1, $s.Height - 1)
        $перо.Dispose()
    })

    $шапка = New-Object System.Windows.Forms.Panel
    $шапка.Location = New-Object System.Drawing.Point(0, 0)
    $шапка.Size = New-Object System.Drawing.Size($ш, $раскладка.ВысотаШапки)
    $шапка.BackColor = $C_CARD
    $шапка.Cursor = [System.Windows.Forms.Cursors]::Hand
    $f.Controls.Add($шапка)

    $надписи = @()
    foreach ($с in $строки) {
        $l = New-Object System.Windows.Forms.Label
        $l.Location = New-Object System.Drawing.Point($поле, $с.Y)
        $l.Size = New-Object System.Drawing.Size(($ш - $поле * 2), $с.Высота)
        $l.Text = $с.Текст
        $l.ForeColor = $с.Цвет
        $l.BackColor = [System.Drawing.Color]::Transparent
        $l.Font = Шрифт $с.Кегль $с.Жирная
        # Длинная строка обрезается ТОЧКАМИ, а не молча по границе: обрыв без
        # многоточия читается как опечатка.
        $l.AutoEllipsis = $true
        $l.Cursor = [System.Windows.Forms.Cursors]::Hand
        $шапка.Controls.Add($l)
        $надписи += $l
    }

    function Новый-Пункт([string]$текст, [int]$x, [int]$y, [int]$ширина, $фон) {
        $b = New-Object System.Windows.Forms.Button
        $b.Location = New-Object System.Drawing.Point($x, $y)
        $b.Size = New-Object System.Drawing.Size($ширина, 36)
        $b.Text = $текст
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $фон
        # Цвет надписи считается по ЯРКОСТИ фона: светлый текст на светлом фоне
        # тревоги не читается.
        $яркость = $фон.R * 0.299 + $фон.G * 0.587 + $фон.B * 0.114
        if ($яркость -gt 150) { $b.ForeColor = $C_BG } else { $b.ForeColor = $C_TEXT }
        $b.Font = Шрифт 9.5
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $b.TabStop = $false
        Скруглить $b $script:R_BTN
        return $b
    }

    $тумблер = Новый-Пункт $ТекстТумблера $поле $раскладка.Ряды[0] ($ш - $поле * 2) $ЦветТумблера
    $f.Controls.Add($тумблер)
    $выход = Новый-Пункт 'Закрыть' $поле $раскладка.Ряды[1] ($ш - $поле * 2) $C_HI
    $f.Controls.Add($выход)

    return @{
        Форма    = $f
        Шапка    = $шапка
        Надписи  = $надписи
        Тумблер  = $тумблер
        Выход    = $выход
        Раскладка = $раскладка
    }
}
