# Файл общей библиотеки, положенный сборщиком выпуска. Правится исходник, а не он.

function Край-Панели-Задач($рабочая, $границы) {
    
    $снизу = $границы.Bottom - $рабочая.Bottom
    $сверху = $рабочая.Top - $границы.Top
    $слева = $рабочая.Left - $границы.Left
    $справа = $границы.Right - $рабочая.Right
    $наибольший = [Math]::Max([Math]::Max($снизу, $сверху), [Math]::Max($слева, $справа))
    if ($наибольший -lt 2) { return 'нет' }
    if ($наибольший -eq $снизу)  { return 'низ' }
    if ($наибольший -eq $сверху) { return 'верх' }
    if ($наибольший -eq $слева)  { return 'слева' }
    return 'справа'
}

function Место-Плашки([int]$ш, [int]$в, $курсор, $рабочая, $границы) {
    
    $зазор = 8
    $край = Край-Панели-Задач $рабочая $границы

    $вправо = ($курсор.X + $зазор + $ш) -le $рабочая.Right
    $вниз = ($курсор.Y + $зазор + $в) -le $рабочая.Bottom

    switch ($край) {
        'низ'    { $y = $рабочая.Bottom - $в - $зазор; if ($вправо) { $x = $курсор.X } else { $x = $курсор.X - $ш } }
        'верх'   { $y = $рабочая.Top + $зазор;         if ($вправо) { $x = $курсор.X } else { $x = $курсор.X - $ш } }
        'слева'  { $x = $рабочая.Left + $зазор;        if ($вниз)   { $y = $курсор.Y } else { $y = $курсор.Y - $в } }
        'справа' { $x = $рабочая.Right - $ш - $зазор;  if ($вниз)   { $y = $курсор.Y } else { $y = $курсор.Y - $в } }
        default  {
            if ($вправо) { $x = $курсор.X + $зазор } else { $x = $курсор.X - $ш - $зазор }
            if ($вниз)   { $y = $курсор.Y + $зазор } else { $y = $курсор.Y - $в - $зазор }
        }
    }

    $x = [Math]::Min($x, $рабочая.Right - $ш - $зазор)
    $x = [Math]::Max($x, $рабочая.Left + $зазор)
    $y = [Math]::Min($y, $рабочая.Bottom - $в - $зазор)
    $y = [Math]::Max($y, $рабочая.Top + $зазор)
    return (New-Object System.Drawing.Point([int]$x, [int]$y))
}

function Высота-Строки-Плашки([double]$кегль) {
    
    return [int]($кегль * 2.2) + 6
}

function Раскладка-Плашки($строки, [int]$поле, [int]$зазорСтрок,
                          [int]$зазорДоКнопок, [int]$высотаКнопки, [int]$подвал,
                          [int]$пунктов = 2, [int]$зазорРядов = 6) {
    
    $курсор = $поле
    foreach ($с in $строки) {
        $с['Высота'] = Высота-Строки-Плашки $с.Кегль
        $с['Y'] = $курсор
        $курсор += $с.Высота + $зазорСтрок
    }
    $высотаШапки = $курсор - $зазорСтрок + $поле
    $ряды = @()
    $верх = $высотаШапки + $зазорДоКнопок
    for ($i = 0; $i -lt [Math]::Max(1, $пунктов); $i++) {
        $ряды += $верх
        $верх += $высотаКнопки + $зазорРядов
    }
    return @{
        ВысотаШапки = $высотаШапки
        ВерхРяда    = $ряды[0]
        Ряды        = $ряды
        Высота      = $верх - $зазорРядов + $подвал
    }
}

function Ширина-Меню([int[]]$ширины, [int]$поле, [int]$отступСтроки = 12, [int]$потолок = 176) {
    
    $наибольшая = 0
    foreach ($ш in $ширины) { if ($ш -gt $наибольшая) { $наибольшая = $ш } }
    return [int][Math]::Min($потолок, $наибольшая + 2 * $поле + $отступСтроки)
}
function Меню-Трея {
    
    param(
        [Parameter(Mandatory = $true)][string]$Название,
        [Parameter(Mandatory = $true)]$ЦветСостояния,
        [string]$Подсказка = '',
        [scriptblock]$ОткрытьОкно,
        [Parameter(Mandatory = $true)][object[]]$Пункты
    )
    $фон = Цвет-Контракта 'карточка'
    $текст = Цвет-Контракта 'текст'
    $линия = Цвет-Контракта 'линия'
    $поле = [int](Число-Оболочки 'меню_поле')
    $строка = [int](Число-Оболочки 'меню_строка')
    $отступ = [int](Число-Оболочки 'меню_отступ')
    $шрифтСтрок = Шрифт (Число-Оболочки 'меню_кегль')
    $шрифтШапки = Шрифт (Число-Оболочки 'меню_кегль_заголовка') $true

    $кружокX = $отступ - 4
    $названиеX = $отступ + 12
    $ширины = @([System.Windows.Forms.TextRenderer]::MeasureText($Название, $шрифтШапки).Width + 12)
    foreach ($п in $Пункты) { $ширины += [System.Windows.Forms.TextRenderer]::MeasureText([string]$п.Текст, $шрифтСтрок).Width }
    $ш = Ширина-Меню $ширины $поле $отступ ([int](Число-Оболочки 'меню_ширина'))

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = $фон
    $f.ForeColor = $текст
    $f.Width = $ш
    $f.Tag = @{ Фон = $фон; Подсветка = (Цвет-Контракта 'подсветка') }

    $навести = { param($s, $e) $п = if ($s -is [System.Windows.Forms.Label]) { $s.Parent } else { $s }
                 $ц = $п.FindForm().Tag.Подсветка; $п.BackColor = $ц; foreach ($к in $п.Controls) { $к.BackColor = $ц } }
    $увести = { param($s, $e) $п = if ($s -is [System.Windows.Forms.Label]) { $s.Parent } else { $s }
                $ц = $п.FindForm().Tag.Фон; $п.BackColor = $ц; foreach ($к in $п.Controls) { $к.BackColor = $ц } }
    $нажать = { param($s, $e) $д = $s.Tag; $s.FindForm().Close(); if ($д) { & $д } }

    $y = [int]($поле / 2)
    $всплывающая = New-Object System.Windows.Forms.ToolTip
    $шапка = New-Object System.Windows.Forms.Panel
    $шапка.SetBounds($поле, $y, ($ш - 2 * $поле), $строка)
    $шапка.BackColor = $фон
    $шапка.Cursor = [System.Windows.Forms.Cursors]::Hand
    $шапка.Tag = $ОткрытьОкно
    $кружок = New-Object System.Windows.Forms.Label
    $кружок.Text = [string][char]0x25CF
    $кружок.Font = $шрифтШапки
    $кружок.ForeColor = $ЦветСостояния
    $кружок.AutoSize = $true
    $кружок.Location = New-Object System.Drawing.Point($кружокX, [int](($строка - $кружок.PreferredHeight) / 2))
    $имя = New-Object System.Windows.Forms.Label
    $имя.Text = $Название
    $имя.Font = $шрифтШапки
    $имя.ForeColor = $текст
    $имя.AutoSize = $true
    $имя.Location = New-Object System.Drawing.Point($названиеX, [int](($строка - $имя.PreferredHeight) / 2))
    foreach ($часть in @($шапка, $кружок, $имя)) {
        $часть.BackColor = $фон
        $часть.Cursor = [System.Windows.Forms.Cursors]::Hand
        $часть.Tag = $ОткрытьОкно
        $часть.Add_Click($нажать)
        if ($Подсказка) { $всплывающая.SetToolTip($часть, $Подсказка) }
    }
    $шапка.Controls.Add($кружок)
    $шапка.Controls.Add($имя)
    $f.Controls.Add($шапка)
    $y += $строка

    foreach ($п in $Пункты) {
        $р = New-Object System.Windows.Forms.Panel
        $р.SetBounds($поле, $y, ($ш - 2 * $поле), $строка)
        $р.BackColor = $фон
        $р.Cursor = [System.Windows.Forms.Cursors]::Hand
        $р.Tag = $п.Действие
        $н = New-Object System.Windows.Forms.Label
        $н.Text = [string]$п.Текст
        $н.Font = $шрифтСтрок
        $н.ForeColor = if ($п.Цвет) { $п.Цвет } else { $текст }
        $н.BackColor = $фон
        $н.AutoSize = $true
        $н.Cursor = [System.Windows.Forms.Cursors]::Hand
        $н.Tag = $п.Действие
        $н.Location = New-Object System.Drawing.Point($отступ, [int](($строка - $н.PreferredHeight) / 2))
        $р.Controls.Add($н)
        foreach ($к in @($р, $н)) { $к.Add_MouseEnter($навести); $к.Add_MouseLeave($увести); $к.Add_Click($нажать) }
        $f.Controls.Add($р)
        $y += $строка
    }

    $f.Height = $y + [int]($поле / 2)
    Скруглить $f (Радиус-Контракта 'карточка')
    $f.Add_Deactivate({ param($s, $e) try { $s.Close() } catch { } })
    $курсор = [System.Windows.Forms.Cursor]::Position
    $экран = [System.Windows.Forms.Screen]::FromPoint($курсор)
    $f.Location = Место-Плашки $f.Width $f.Height $курсор $экран.WorkingArea $экран.Bounds
    [void]$f.Handle
    Стекло $f   # стекло: размытие позади меню, оттенок из контракта
    Преломление-Стекла $f   # меню уже на месте и ещё скрыто — снимок фона под ним честный
    Живое-Стекло $f         # на экране стекло следит за фоном: фон меняется — меняется и оно
    Появление-Окна $f       # проявляется и въезжает, как панель fluent-flyouts
    if ($f.BackgroundImage) {
        $прозрачный = [System.Drawing.Color]::Transparent
        $f.Tag.Фон = $прозрачный
        foreach ($к in $f.Controls) { $к.BackColor = $прозрачный; foreach ($в in $к.Controls) { $в.BackColor = $прозрачный } }
    }
    return $f
}

function Место-Уведомления([int]$ш, [int]$в, $рабочая, $панель, [int]$сдвиг = 0) {
    
    $зазор = 12
    $низ = $рабочая.Bottom
    $право = $рабочая.Right
    if ($панель) {
        $снизу = $панель.Top -gt ($рабочая.Top + $рабочая.Height / 2)
        $справа = $панель.Left -gt ($рабочая.Left + $рабочая.Width / 2)
        if ($снизу -and $панель.Width -gt $панель.Height) { $низ = [Math]::Min($низ, $панель.Top) }
        elseif ($справа -and $панель.Height -gt $панель.Width) { $право = [Math]::Min($право, $панель.Left) }
    }
    return (New-Object System.Drawing.Point([int]($право - $ш - $зазор), [int]($низ - $в - $зазор - $сдвиг)))
}

function Прямоугольник-Панели-Задач {
    
    if (-not ('ShellTaskbar' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class ShellTaskbar {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct Data { public int cb; public IntPtr h; public uint e; public uint edge; public Rect rc; public IntPtr lp; }
    [DllImport("shell32.dll")] public static extern IntPtr SHAppBarMessage(uint m, ref Data d);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
'@
    }
    $д = New-Object ShellTaskbar+Data
    $д.cb = [Runtime.InteropServices.Marshal]::SizeOf($д)
    if ([ShellTaskbar]::SHAppBarMessage(5, [ref]$д) -eq [IntPtr]::Zero) { return $null }
    return (New-Object System.Drawing.Rectangle($д.rc.L, $д.rc.T, ($д.rc.R - $д.rc.L), ($д.rc.B - $д.rc.T)))
}

$script:УведомленияПриложений = New-Object System.Collections.ArrayList

function Разложить-Уведомления {
    
    $экран = [System.Windows.Forms.Screen]::PrimaryScreen
    $панель = Прямоугольник-Панели-Задач
    $сдвиг = 0
    for ($i = $script:УведомленияПриложений.Count - 1; $i -ge 0; $i--) {
        $у = $script:УведомленияПриложений[$i]
        if (-not $у -or $у.IsDisposed) { continue }
        $т = Место-Уведомления $у.Width $у.Height $экран.WorkingArea $панель $сдвиг
        [void][ShellTaskbar]::SetWindowPos($у.Handle, [IntPtr](-1), $т.X, $т.Y, 0, 0, 0x0011)
        if ($script:СнимокКолонки -and $у.Tag -ne ('{0},{1}' -f $т.X, $т.Y)) {
            $у.Tag = '{0},{1}' -f $т.X, $т.Y
            Преломление-Стекла $у -Снимок $script:СнимокКолонки -ГдеСнимок $script:ГдеСнимокКолонки
        }
        $сдвиг += $у.Height + 8
    }
}

function Снять-Колонку-Уведомлений($форма) {
    
    $экран = [System.Windows.Forms.Screen]::PrimaryScreen
    $т = Место-Уведомления $форма.Width $форма.Height $экран.WorkingArea (Прямоугольник-Панели-Задач) 0
    $поле = 48
    $колонка = New-Object System.Drawing.Rectangle(($т.X - $поле), $экран.Bounds.Top, ($форма.Width + 2 * $поле), $экран.Bounds.Height)
    if ($script:СнимокКолонки) { $script:СнимокКолонки.Dispose() }
    $где = [System.Drawing.Rectangle]::Empty
    $script:СнимокКолонки = [GlassLens]::Shot($колонка, [ref]$где)
    $script:ГдеСнимокКолонки = $где
}

function Убрать-Уведомление($форма) {
    try { [void]$script:УведомленияПриложений.Remove($форма) } catch { Write-Verbose ('уведомление не снято со стопки: ' + $_.Exception.Message) }
    try { $форма.Close(); $форма.Dispose() } catch { Write-Verbose ('уведомление не закрыто: ' + $_.Exception.Message) }
    Разложить-Уведомления
}

function Уведомление-Приложения {
    
    param(
        [Parameter(Mandatory = $true)][string]$Заголовок,
        [Parameter(Mandatory = $true)][string]$Текст,
        $ЦветСостояния,
        [string]$Картинка = '',
        [int]$Секунд = 7,
        [scriptblock]$ПоЩелчку,
        [System.Collections.IDictionary]$Действия,
        [switch]$НеПоказывать
    )
    [void](Прямоугольник-Панели-Задач)   # заводит тип для показа без фокуса
    $фон = Цвет-Контракта 'карточка'
    $поле = [int](Число-Оболочки 'окно_поле')
    $ш = [int](Число-Оболочки 'уведомление_ширина')
    $значок = [int](Число-Оболочки 'значок')
    $шрифтЗаголовка = Шрифт (Число-Оболочки 'меню_кегль_заголовка') $true
    $шрифтТекста = Шрифт (Число-Оболочки 'меню_кегль')

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.BackColor = $фон
    $f.Width = $ш
    $f.Tag = @{ ПоЩелчку = $ПоЩелчку }

    $лево = $поле
    if ($Картинка -and (Test-Path -LiteralPath $Картинка)) {
        $к = New-Object System.Windows.Forms.PictureBox
        $к.Image = [System.Drawing.Image]::FromFile($Картинка)
        $к.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $к.SetBounds($поле, $поле, $значок, $значок)
        $к.BackColor = $фон
        $f.Controls.Add($к)
        $лево = $поле + $значок + $поле
    }
    $ширинаТекста = $ш - $лево - $поле - 18
    $y = $поле - 2
    $x = $лево
    if ($ЦветСостояния) {
        $точка = New-Object System.Windows.Forms.Label
        $точка.Text = [string][char]0x25CF
        $точка.Font = $шрифтЗаголовка
        $точка.ForeColor = $ЦветСостояния
        $точка.BackColor = $фон
        $точка.AutoSize = $true
        $точка.Location = New-Object System.Drawing.Point($x, $y)
        $f.Controls.Add($точка)
        $x += 14
    }
    $з = New-Object System.Windows.Forms.Label
    $з.Text = $Заголовок
    $з.Font = $шрифтЗаголовка
    $з.ForeColor = Цвет-Контракта 'текст'
    $з.BackColor = $фон
    $з.AutoEllipsis = $true
    $з.SetBounds($x, $y, ($ширинаТекста - ($x - $лево)), $з.PreferredHeight)
    $f.Controls.Add($з)
    $y += $з.PreferredHeight + 2
    $высотаТекста = [System.Windows.Forms.TextRenderer]::MeasureText($Текст, $шрифтТекста, (New-Object System.Drawing.Size(($ширинаТекста - 8), 0)),
        [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::TextBoxControl).Height
    $т = New-Object System.Windows.Forms.Label
    $т.Text = $Текст
    $т.Font = $шрифтТекста
    $т.ForeColor = Цвет-Контракта 'текст_второй'
    $т.BackColor = $фон
    $т.SetBounds($лево, $y, $ширинаТекста, ($высотаТекста + 2))
    $f.Controls.Add($т)
    $y += $высотаТекста

    $закрыть = New-Object System.Windows.Forms.Label
    $закрыть.Text = [string][char]0xD7
    $закрыть.Font = Шрифт-Символов (Число-Оболочки 'меню_кегль_заголовка')
    $закрыть.ForeColor = Цвет-Контракта 'текст_второй'
    $закрыть.BackColor = $фон
    $закрыть.AutoSize = $true
    $закрыть.Cursor = [System.Windows.Forms.Cursors]::Hand
    $закрыть.Location = New-Object System.Drawing.Point(($ш - $поле - 12), ($поле - 6))
    $закрыть.Add_Click({ param($s, $e) Убрать-Уведомление $s.FindForm() })
    $f.Controls.Add($закрыть)

    if ($ПоЩелчку) {
        foreach ($ч in @($f, $з, $т)) {
            $ч.Cursor = [System.Windows.Forms.Cursors]::Hand
            $ч.Add_Click({ param($s, $e) $ф = $s.FindForm(); $д = $ф.Tag.ПоЩелчку
                           try { & $д } catch { Write-Verbose ('действие уведомления упало: ' + $_.Exception.Message) }
                           Убрать-Уведомление $ф })
        }
    }

    if ($Действия -and $Действия.Count) {
        $y += 8
        $xк = $лево
        $высотаЧипа = [int](Число-Оболочки 'окно_вкладка')
        foreach ($надпись in $Действия.Keys) {
            $чип = New-Object System.Windows.Forms.Label
            $чип.Text = [string]$надпись
            $чип.Font = $шрифтТекста
            $чип.ForeColor = Цвет-Контракта 'акцент'
            $чип.BackColor = Цвет-Контракта 'подсветка'
            $чип.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
            $чип.Cursor = [System.Windows.Forms.Cursors]::Hand
            $чип.SetBounds($xк, $y, ([System.Windows.Forms.TextRenderer]::MeasureText([string]$надпись, $шрифтТекста).Width + 20), $высотаЧипа)
            $чип.Tag = $Действия[$надпись]
            $чип.Add_Click({ param($s, $e) $д = $s.Tag; $ф = $s.FindForm()
                             try { & $д } catch { Write-Verbose ('действие уведомления упало: ' + $_.Exception.Message) }
                             Убрать-Уведомление $ф })
            $f.Controls.Add($чип)
            Скруглить $чип (Радиус-Контракта 'кнопка')
            $xк += $чип.Width + 8
        }
        $y += $высотаЧипа
    }
    $f.Height = [Math]::Max($y, $поле + $значок) + $поле
    Скруглить $f (Радиус-Контракта 'карточка')
    if ($НеПоказывать) { return $f }

    $живых = @($script:УведомленияПриложений | Where-Object { $_ -and -not $_.IsDisposed }).Count
    [void]$script:УведомленияПриложений.Add($f)
    $f.CreateControl(); $null = $f.Handle
    Стекло $f   # стекло: размытие позади уведомления, оттенок из контракта
    try { if (-not $живых -or -not $script:СнимокКолонки) { Снять-Колонку-Уведомлений $f } }
    catch { Write-Verbose ('снимок колонки уведомлений не снят: ' + $_.Exception.Message) }
    Разложить-Уведомления   # место и кусок стекла — до показа, чтобы уведомление не мелькнуло в чужом месте
    Появление-Окна $f -БезСдвига   # проявляется; место в стопке держит раскладка
    [void][ShellTaskbar]::ShowWindow($f.Handle, 4)   # SW_SHOWNOACTIVATE — фокус не крадётся
    Живое-Стекло $f   # на экране стекло уведомления следит за фоном под ним
    if ($Секунд -gt 0) {
        $таймер = New-Object System.Windows.Forms.Timer
        $таймер.Interval = $Секунд * 1000
        $таймер.Tag = $f
        $таймер.Add_Tick({ param($s, $e) $s.Stop(); $ф = $s.Tag; $s.Dispose(); Убрать-Уведомление $ф })
        $таймер.Start()
    }
    return $f
}
