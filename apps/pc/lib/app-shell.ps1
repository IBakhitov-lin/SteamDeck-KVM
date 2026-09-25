# Файл общей библиотеки, положенный сборщиком выпуска. Правится исходник, а не он.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    Add-Type -Namespace AppShell -Name WindowApi -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string app, string id);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
'@ -ErrorAction Stop
} catch {
    Write-Verbose ('системные вызовы окна уже подключены: ' + $_.Exception.Message)
}

if (-not ('GlassLens' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class GlassLens {
static float Step(float a, float b, float x) { float t = Math.Max(0f, Math.Min(1f, (x - a) / (b - a))); return t * t * (3 - 2 * t); }
static float Sdf(float x, float y, float hw, float hh, float r) {
    float qx = Math.Abs(x) - hw + r, qy = Math.Abs(y) - hh + r;
    return Math.Min(Math.Max(qx, qy), 0f) + (float)Math.Sqrt(Math.Max(qx, 0f) * Math.Max(qx, 0f) + Math.Max(qy, 0f) * Math.Max(qy, 0f)) - r;
}
// Размытие скользящим окном: сумма окна сдвигается на точку, а не считается заново, — время не зависит
// от радиуса. Живое стекло пересчитывает фон 25 раз в секунду, прежний перебор окна на это не успевал.
static void Line(int[] from, int[] to, int start, int step, int count, int r) {
    int n = 2 * r + 1, rs = 0, gs = 0, bs = 0;
    for (int k = -r; k <= r; k++) { int c = from[start + Math.Max(0, Math.Min(count - 1, k)) * step]; rs += (c >> 16) & 255; gs += (c >> 8) & 255; bs += c & 255; }
    for (int i = 0; i < count; i++) {
        to[start + i * step] = (255 << 24) | ((rs / n) << 16) | ((gs / n) << 8) | (bs / n);
        int gone = from[start + Math.Max(0, i - r) * step], come = from[start + Math.Min(count - 1, i + r + 1) * step];
        rs += ((come >> 16) & 255) - ((gone >> 16) & 255); gs += ((come >> 8) & 255) - ((gone >> 8) & 255); bs += (come & 255) - (gone & 255);
    }
}
static void BoxBlur(int[] src, int[] tmp, int w, int h, int r) {
    if (r < 1) return;
    for (int pass = 0; pass < 3; pass++) {
        for (int y = 0; y < h; y++) Line(src, tmp, y * w, 1, w, r);
        for (int x = 0; x < w; x++) Line(tmp, src, x, w, h, r);
    }
}
// Снимок экрана под прямоугольником окна, размытие, смещение у края внутрь и оттенок стекла.
// Снимок участка экрана, обрезанный по экрану. Окно, которое стекло рисует, в этот момент скрыто.
public static Bitmap Shot(Rectangle area, out Rectangle got) {
    got = Rectangle.Intersect(area, System.Windows.Forms.SystemInformation.VirtualScreen);
    if (got.Width <= 0 || got.Height <= 0) return null;
    Bitmap shot = new Bitmap(got.Width, got.Height, PixelFormat.Format32bppArgb);
    using (Graphics g = Graphics.FromImage(shot)) g.CopyFromScreen(got.X, got.Y, 0, 0, got.Size);
    return shot;
}
[DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr h, uint a);
[DllImport("dwmapi.dll")] static extern int DwmFlush();
// Живое стекло Apple: фон под окном меняется — меняется и стекло. Windows картинку под окном не отдаёт,
// поэтому окно на время снимка исключается из снимка экрана (WDA_EXCLUDEFROMCAPTURE); на экране оно
// остаётся, а снимки экрана пользователя видят его всё время, кроме этих миллисекунд.
public static Bitmap RefractLive(IntPtr window, Rectangle win, int radius, float strength, float band, int blur, Color tint, float density) {
    int m = (int)Math.Ceiling(strength) + blur * 3 + 2;
    Rectangle got;
    bool excluded = window != IntPtr.Zero && SetWindowDisplayAffinity(window, 0x11);
    Bitmap shot;
    try {
        if (excluded) DwmFlush();
        shot = Shot(new Rectangle(win.X - m, win.Y - m, win.Width + 2 * m, win.Height + 2 * m), out got);
    } finally { if (excluded) SetWindowDisplayAffinity(window, 0); }
    if (shot == null) return null;
    using (shot) return RefractFrom(shot, got, win, radius, strength, band, blur, tint, density);
}
public static Bitmap Refract(Rectangle win, int radius, float strength, float band, int blur, Color tint, float density) {
    int m = (int)Math.Ceiling(strength) + blur * 3 + 2;
    Rectangle got;
    using (Bitmap shot = Shot(new Rectangle(win.X - m, win.Y - m, win.Width + 2 * m, win.Height + 2 * m), out got)) {
        return shot == null ? null : RefractFrom(shot, got, win, radius, strength, band, blur, tint, density);
    }
}
// Живое стекло в своём потоке. Прежде снимок с ожиданием кадра экрана (DwmFlush) и расчёт шли таймером в
// потоке окна — около 45 мс на кадр, и окно, меню и мышь дёргались. Теперь поток снимает и считает, а окну
// отдаёт готовую картинку; новую — только когда окно нарисовало прежнюю, очередь кадров не копится.
public sealed class Live {
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    readonly System.Windows.Forms.Form form; readonly IntPtr handle;
    readonly int radius, blur; readonly float strength, band, density; readonly Color tint;
    volatile bool stop; int pending;
    public int Period { get; private set; }
    public int Frames { get; private set; }
    public bool Running { get { return !stop; } }
    public Live(System.Windows.Forms.Form f, int period, int radius, float strength, float band, int blur, Color tint, float density) {
        form = f; handle = f.Handle; Period = Math.Max(16, period);
        this.radius = radius; this.strength = strength; this.band = band; this.blur = blur; this.tint = tint; this.density = density;
        f.FormClosed += (s, e) => stop = true;
        var t = new System.Threading.Thread(Loop); t.IsBackground = true; t.Start();
    }
    public void Stop() { stop = true; }
    void Loop() {
        while (!stop) {
            int started = Environment.TickCount;
            if (IsWindowVisible(handle) && System.Threading.Interlocked.CompareExchange(ref pending, 1, 0) == 0) {
                Bitmap frame = null;
                RECT r;
                try { if (GetWindowRect(handle, out r)) frame = RefractLive(handle, new Rectangle(r.L, r.T, r.R - r.L, r.B - r.T), radius, strength, band, blur, tint, density); }
                catch { frame = null; }
                if (frame == null) pending = 0;
                else {
                    try {
                        form.BeginInvoke((Action)(() => {
                            if (form.IsDisposed || frame.Width != form.Width || frame.Height != form.Height) frame.Dispose();
                            else { Image old = form.BackgroundImage; form.BackgroundImage = frame; if (old != null) old.Dispose(); Frames++; }
                            pending = 0;
                        }));
                    } catch { frame.Dispose(); stop = true; }  // окно закрыто — поток кончается
                }
            }
            int left = Period - (Environment.TickCount - started);
            System.Threading.Thread.Sleep(left > 0 ? left : 1);
        }
    }
}
// Объём линзы — раздел «стекло» контракта (дисперсия, свечение, объём), ставится один раз функцией Light.
// Приёмы — WWDC25 «Meet Liquid Glass», kube.io «Liquid Glass in the Browser» (профиль-сквиркл), liquid-glass-react
// (расхождение каналов); те же формулы, что у панели мода fluent-flyouts, — вид один.
static float dispersion, glow, volume, magnify;
public static void Light(float disp, float glw, float vol, float mag = 0) { dispersion = disp; glow = glw; volume = vol; magnify = mag; }
static float Channel(int[] px, int gw, int gh, float x, float y, int shift) {
    x = Math.Max(0f, Math.Min(gw - 1f, x)); y = Math.Max(0f, Math.Min(gh - 1f, y));
    int x0 = (int)x, y0 = (int)y, x1 = Math.Min(x0 + 1, gw - 1), y1 = Math.Min(y0 + 1, gh - 1);
    float fx = x - x0, fy = y - y0;
    float a = (px[y0 * gw + x0] >> shift) & 255, b = (px[y0 * gw + x1] >> shift) & 255;
    float c = (px[y1 * gw + x0] >> shift) & 255, d = (px[y1 * gw + x1] >> shift) & 255;
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy;
}
// Преломление по готовому снимку: окно, которое двигается (уведомление в стопке), берёт свой кусок
// из снимка, снятого, пока его место было пустым, и не снимает само себя.
public static Bitmap RefractFrom(Bitmap source, Rectangle area, Rectangle win, int radius, float strength, float band, int blur, Color tint, float density) {
    int m = (int)Math.Ceiling(strength) + blur * 3 + 2;
    Rectangle grab = Rectangle.Intersect(new Rectangle(win.X - m, win.Y - m, win.Width + 2 * m, win.Height + 2 * m), area);
    if (grab.Width <= 0 || grab.Height <= 0 || !area.Contains(win)) return null;
    int gw = grab.Width, gh = grab.Height;
    int[] px = new int[gw * gh], tmp = new int[gw * gh];
    using (Bitmap part = source.Clone(new Rectangle(grab.X - area.X, grab.Y - area.Y, gw, gh), PixelFormat.Format32bppArgb)) {
        BitmapData d = part.LockBits(new Rectangle(0, 0, gw, gh), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(d.Scan0, px, 0, px.Length); part.UnlockBits(d);
    }
    if (blur > 0) BoxBlur(px, tmp, gw, gh, blur);
    int w = win.Width, h = win.Height, ox = win.X - grab.X, oy = win.Y - grab.Y;
    float hw = w / 2f, hh = h / 2f, r = Math.Min(radius, Math.Min(hw, hh));
    int[] outp = new int[w * h];
    float a = density, ia = 1 - density;
    // Свет сверху, чуть повёрнутый за курсором: блик на кромке живёт вместе с рукой, как у Apple.
    System.Drawing.Point cur = System.Windows.Forms.Cursor.Position;
    float tilt = Math.Max(-1f, Math.Min(1f, (cur.X - (win.X + hw)) / Math.Max(1f, w))) * 0.6f;
    float lx = tilt / (float)Math.Sqrt(tilt * tilt + 1), ly = -1 / (float)Math.Sqrt(tilt * tilt + 1);
    for (int y = 0; y < h; y++) {
        float lift = 1 + volume * (0.5f - (float)y / h) * 2;  // объём: верх светлее низа
        for (int x = 0; x < w; x++) {
            float cx = x - hw + 0.5f, cy = y - hh + 0.5f;
            float dist = Sdf(cx, cy, hw, hh, r), lens = 0, nx = 0, ny = 0;
            if (dist < 0 && -dist < band) {
                // Профиль края — выпуклый сквиркл h(t) = (1 − (1 − t)⁴)^¼; сила линзы m = 1 − h: 1 у края, 0 внутри.
                float t = -dist / band;
                lens = 1 - (float)Math.Pow(1 - Math.Pow(1 - t, 4), 0.25);
                nx = Sdf(cx + 1, cy, hw, hh, r) - Sdf(cx - 1, cy, hw, hh, r); ny = Sdf(cx, cy + 1, hw, hh, r) - Sdf(cx, cy - 1, hw, hh, r);
                float len = (float)Math.Sqrt(nx * nx + ny * ny);
                if (len > 0) { nx /= len; ny /= len; } else lens = 0;
            }
            // Выпуклость всей линзы: под стеклом видно чуть крупнее — фон искажён, а не только размыт.
            float mx = hw + (x - hw) / (1 + magnify), my = hh + (y - hh) / (1 + magnify);
            float shift = strength * lens * lens, bx = mx + ox - nx * shift, by = my + oy - ny * shift;
            float dx = -nx * shift * dispersion, dy = -ny * shift * dispersion;
            float rr = Channel(px, gw, gh, bx + dx, by + dy, 16), gg = Channel(px, gw, gh, bx, by, 8), bb = Channel(px, gw, gh, bx - dx, by - dy, 0);
            float add = 0;
            if (lens > 0) {
                float k = nx * lx + ny * ly;  // кромка к свету — блик, от света — слабый отблеск; у края — свечение
                float spec = k > 0 ? k * k : 0.35f * k * k;
                add = 255 * glow * (spec * (float)Math.Pow(lens, 1.5) + 0.3f * lens * lens * lens);
            }
            int R = (int)Math.Max(0, Math.Min(255, (rr * ia + tint.R * a) * lift + add));
            int G = (int)Math.Max(0, Math.Min(255, (gg * ia + tint.G * a) * lift + add));
            int B = (int)Math.Max(0, Math.Min(255, (bb * ia + tint.B * a) * lift + add));
            outp[y * w + x] = (255 << 24) | (R << 16) | (G << 8) | B;
        }
    }
    Bitmap res = new Bitmap(w, h, PixelFormat.Format32bppArgb);
    BitmapData o = res.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
    Marshal.Copy(outp, 0, o.Scan0, outp.Length); res.UnlockBits(o);
    return res;
}
}
'@
}
try { ([GlassLens]::Refract((New-Object System.Drawing.Rectangle(0, 0, 8, 8)), 2, 1, 1, 1, [System.Drawing.Color]::Black, 0.5)).Dispose() }
catch { Write-Verbose ('разогрев линзы стекла не удался: ' + $_.Exception.Message) }

$script:ПапкаОбщейБиблиотеки = $PSScriptRoot
$script:КонтрактВида = $null

function Контракт-Вида {
    if ($script:КонтрактВида) { return $script:КонтрактВида }
    $папка = $script:ПапкаОбщейБиблиотеки
    $узел = Get-Item -LiteralPath $папка -ErrorAction SilentlyContinue
    if ($узел -and $узел.LinkType) { $папка = @($узел.Target)[0] }
    $кандидаты = @((Join-Path $script:ПапкаОбщейБиблиотеки 'palette.json'),
                   (Join-Path (Split-Path (Split-Path (Split-Path $папка))) 'templates\palette.json'))
    foreach ($путь in $кандидаты) {
        if (Test-Path -LiteralPath $путь) {
            $script:КонтрактВида = Get-Content -LiteralPath $путь -Raw -Encoding UTF8 | ConvertFrom-Json
            $с = $script:КонтрактВида.'стекло'   # объём линзы — в линзу один раз, при первом чтении контракта
            if ($с) { [GlassLens]::Light([float]$с.'дисперсия', [float]$с.'свечение', [float]$с.'объём', [float]$с.'увеличение') }
            return $script:КонтрактВида
        }
    }
    throw ('контракт вида не найден: ' + ($кандидаты -join '; '))
}

function Цвет-Контракта([string]$имя) {
    $hex = [string](Контракт-Вида).'тёмная'.$имя
    if ($hex -notmatch '^#[0-9a-fA-F]{6}$') { throw "в контракте вида нет цвета «$имя»" }
    $h = $hex.Substring(1)
    return [System.Drawing.Color]::FromArgb([Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function Число-Оболочки([string]$имя) {
    $значение = (Контракт-Вида).'оболочка'.$имя
    if ($null -eq $значение) { throw "в контракте вида нет числа оболочки «$имя»" }
    return [double]$значение
}

function Радиус-Контракта([string]$имя) {
    $значение = (Контракт-Вида).'радиусы'.$имя
    if ($null -eq $значение) { throw "в контракте вида нет радиуса «$имя»" }
    return [int]$значение
}

function Шрифт([double]$кегль, [bool]$жирный = $false) {
    $гарнитура = [string](Контракт-Вида).'типографика'.'приложение'
    if (-not $гарнитура) { throw 'в контракте вида нет гарнитуры «типографика.приложение»' }
    if ($жирный) { $стиль = [System.Drawing.FontStyle]::Bold } else { $стиль = [System.Drawing.FontStyle]::Regular }
    return New-Object System.Drawing.Font($гарнитура, $кегль, $стиль)
}

function Шрифт-Символов([double]$кегль, [bool]$жирный = $false) {
    $гарнитура = [string](Контракт-Вида).'типографика'.'символы'
    if (-not $гарнитура) { throw 'в контракте вида нет гарнитуры «типографика.символы»' }
    if ($жирный) { $стиль = [System.Drawing.FontStyle]::Bold } else { $стиль = [System.Drawing.FontStyle]::Regular }
    return New-Object System.Drawing.Font($гарнитура, $кегль, $стиль)
}

function Стекло($окно) {
    
    if (-not ('ShellGlass' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class ShellGlass {
    [StructLayout(LayoutKind.Sequential)] public struct Accent { public int State; public int Flags; public uint Gradient; public int Anim; }
    [StructLayout(LayoutKind.Sequential)] public struct Data { public int Attr; public IntPtr Ptr; public int Size; }
    [DllImport("user32.dll")] public static extern int SetWindowCompositionAttribute(IntPtr h, ref Data d);
    public static void Blur(IntPtr h, uint abgr) {
        var a = new Accent { State = 4, Flags = 2, Gradient = abgr };
        int n = Marshal.SizeOf(a); IntPtr p = Marshal.AllocHGlobal(n);
        try { Marshal.StructureToPtr(a, p, false); var d = new Data { Attr = 19, Ptr = p, Size = n }; SetWindowCompositionAttribute(h, ref d); }
        finally { Marshal.FreeHGlobal(p); }
    }
}
'@
    }
    $с = (Контракт-Вида).'стекло'
    if (-not $с) { throw 'в контракте вида нет раздела «стекло»' }
    $ц = [System.Drawing.ColorTranslator]::FromHtml([string]$с.'оттенок')
    $а = [uint32][Math]::Round([double]$с.'плотность' * 255)
    $оттенок = [uint32](($а * 16777216) + ([uint32]$ц.B * 65536) + ([uint32]$ц.G * 256) + [uint32]$ц.R)
    try { [ShellGlass]::Blur($окно.Handle, $оттенок) } catch { Write-Verbose ('стекло не наложено: ' + $_.Exception.Message) }
    Кромка-Стекла $окно
}

function Преломление-Стекла {
    
    param($окно, [System.Drawing.Bitmap]$Снимок = $null, [System.Drawing.Rectangle]$ГдеСнимок = [System.Drawing.Rectangle]::Empty,
          [switch]$Живое)
    if ($окно.FormBorderStyle -ne [System.Windows.Forms.FormBorderStyle]::None) { return }
    if (-not $Снимок -and -not $Живое -and $окно.Visible) { return }
    try {
        $с = (Контракт-Вида).'стекло'
        $оттенок = [System.Drawing.ColorTranslator]::FromHtml([string]$с.'оттенок')
        $доводы = @((Радиус-Контракта 'карточка'), [float]$с.'преломление', [float]$с.'преломление_пояс',
                    [int]$с.'размытие', $оттенок, [float]$с.'плотность')
        if ($Живое -and $окно.Visible) { $картинка = [GlassLens]::RefractLive($окно.Handle, $окно.Bounds, $доводы[0], $доводы[1], $доводы[2], $доводы[3], $доводы[4], $доводы[5]) }
        elseif ($Снимок) { $картинка = [GlassLens]::RefractFrom($Снимок, $ГдеСнимок, $окно.Bounds, $доводы[0], $доводы[1], $доводы[2], $доводы[3], $доводы[4], $доводы[5]) }
        else { $картинка = [GlassLens]::Refract($окно.Bounds, $доводы[0], $доводы[1], $доводы[2], $доводы[3], $доводы[4], $доводы[5]) }
        if (-not $картинка) { return }
        $прежняя = $окно.BackgroundImage
        $окно.BackgroundImage = $картинка
        $окно.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::None
        if ($прежняя) { $прежняя.Dispose() }
        $фон = $окно.BackColor
        $очередь = New-Object System.Collections.Queue
        foreach ($к in $окно.Controls) { $очередь.Enqueue($к) }
        while ($очередь.Count) {
            $к = $очередь.Dequeue()
            if ($к.BackColor.ToArgb() -eq $фон.ToArgb()) { try { $к.BackColor = [System.Drawing.Color]::Transparent } catch { Write-Verbose ('заливка не снята: ' + $_.Exception.Message) } }
            foreach ($в in $к.Controls) { $очередь.Enqueue($в) }
        }
    } catch { Write-Verbose ('преломление не наложено: ' + $_.Exception.Message) }
}

function Появление-Окна {
    
    param($окно, [switch]$БезСдвига)
    if ($окно.PSObject.Properties['Появление']) { return }
    $ход = [pscustomobject]@{ Начало = 0; Цель = 0; Сдвиг = -not $БезСдвига }
    $окно | Add-Member -NotePropertyName 'Появление' -NotePropertyValue $ход
    $окно.Opacity = 0
    $таймер = New-Object System.Windows.Forms.Timer
    $таймер.Interval = 15
    $таймер.Tag = $окно
    $таймер.Add_Tick({
        param($s, $e)
        $о = $s.Tag
        if (-not $о -or $о.IsDisposed) { $s.Stop(); $s.Dispose(); return }
        $х = $о.Появление
        $доля = [Math]::Min(1.0, ([Environment]::TickCount - $х.Начало) / 300.0)
        $плавно = 1 - (1 - $доля) * (1 - $доля)   # замедление к концу, как EaseOut панели
        $о.Opacity = $плавно
        if ($х.Сдвиг) { $о.Top = $х.Цель + [int](20 * (1 - $плавно)) }
        if ($доля -ge 1) { $о.Opacity = 1; $s.Stop(); $s.Dispose() }
    })
    $пуск = {
        param($s, $e)
        if (-not $s.Visible -or $s.Появление.Начало) { return }
        $s.Появление.Начало = [Environment]::TickCount
        $s.Появление.Цель = $s.Top
        foreach ($т in @($s.PSObject.Properties['ТаймерПоявления'].Value)) { if ($т) { $т.Start() } }
    }
    $окно | Add-Member -NotePropertyName 'ТаймерПоявления' -NotePropertyValue $таймер
    $окно.Add_VisibleChanged($пуск)
    if ($окно.Visible) { & $пуск $окно $null }
}

function Живое-Стекло($окно) {
    
    if ($окно.FormBorderStyle -ne [System.Windows.Forms.FormBorderStyle]::None) { return }
    if ($окно.PSObject.Properties['ЖивоеСтекло']) { return }
    try {
        $свойство = $окно.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic, Instance')
        $свойство.SetValue($окно, $true, $null)   # без мерцания при смене фона
    } catch { Write-Verbose ('двойной буфер не включён: ' + $_.Exception.Message) }
    try {
        $с = (Контракт-Вида).'стекло'
        $оттенок = [System.Drawing.ColorTranslator]::FromHtml([string]$с.'оттенок')
        $живое = New-Object 'GlassLens+Live' -ArgumentList $окно, ([int]$с.'живое_мс'), (Радиус-Контракта 'карточка'),
            ([float]$с.'преломление'), ([float]$с.'преломление_пояс'), ([int]$с.'размытие'), $оттенок, ([float]$с.'плотность')
        $окно | Add-Member -NotePropertyName 'ЖивоеСтекло' -NotePropertyValue $живое
    } catch { Write-Verbose ('живое стекло не запущено: ' + $_.Exception.Message) }
}

function Кромка-Стекла($окно) {
    
    if ($окно.FormBorderStyle -ne [System.Windows.Forms.FormBorderStyle]::None) { return }
    if ($окно.PSObject.Properties['КромкаСтекла']) { return }
    $окно | Add-Member -NotePropertyName 'КромкаСтекла' -NotePropertyValue $true
    $окно.Add_Paint({
        param($s, $e)
        try {
            $с = (Контракт-Вида).'стекло'
            $ш = $s.ClientSize.Width; $в = $s.ClientSize.Height
            if ($ш -le 4 -or $в -le 4) { return }
            $г = $e.Graphics
            $г.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $r = Радиус-Контракта 'карточка'
            $высота = [Math]::Min([int]$с.'блик_высота', [int]($в / 2))
            $блик = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                (New-Object System.Drawing.Rectangle(0, 0, $ш, $высота + 1)),
                [System.Drawing.Color]::FromArgb([int]([double]$с.'блик' * 255), 255, 255, 255),
                [System.Drawing.Color]::FromArgb(0, 255, 255, 255), 90.0)
            $путь = Путь-Скругления 0 0 $ш $в $r
            $г.SetClip($путь)
            $г.FillRectangle($блик, 0, 0, $ш, $высота)
            $г.ResetClip()
            $кисть = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                (New-Object System.Drawing.Rectangle(0, 0, $ш, $в)),
                [System.Drawing.Color]::FromArgb([int]([double]$с.'кромка_верх' * 255), 255, 255, 255),
                [System.Drawing.Color]::FromArgb([int]([double]$с.'кромка_низ' * 255), 255, 255, 255), 90.0)
            $перо = New-Object System.Drawing.Pen($кисть, 1)
            $ребро = Путь-Скругления 0.5 0.5 ($ш - 1) ($в - 1) $r
            $г.DrawPath($перо, $ребро)
            foreach ($x in @($блик, $путь, $кисть, $перо, $ребро)) { $x.Dispose() }
        } catch { Write-Verbose ('кромка стекла не нарисована: ' + $_.Exception.Message) }
    })
    $окно.Invalidate()
}

function Путь-Скругления([double]$x, [double]$y, [double]$ш, [double]$в, [int]$радиус) {
    $r = [Math]::Min([double]$радиус, [Math]::Min($ш, $в) / 2)
    $путь = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($r -le 1) { $путь.AddRectangle((New-Object System.Drawing.RectangleF($x, $y, $ш, $в))); return ,$путь }
    $d = $r * 2
    $путь.AddArc($x, $y, $d, $d, 180, 90)
    $путь.AddArc(($x + $ш - $d), $y, $d, $d, 270, 90)
    $путь.AddArc(($x + $ш - $d), ($y + $в - $d), $d, $d, 0, 90)
    $путь.AddArc($x, ($y + $в - $d), $d, $d, 90, 90)
    $путь.CloseFigure()
    return ,$путь
}

function Цвет-Надписи($фон) {
    $яркость = $фон.R * 0.299 + $фон.G * 0.587 + $фон.B * 0.114
    if ($яркость -gt 150) { return (Цвет-Контракта 'фон') }
    return (Цвет-Контракта 'текст')
}

function Скруглить($контрол, [int]$радиус) {
    
    try {
        $ш = $контрол.Width; $в = $контрол.Height
        if ($ш -le 2 -or $в -le 2) { return }
        $r = [Math]::Min($радиус, [int]([Math]::Min($ш, $в) / 2))
        if ($r -le 1) { $контрол.Region = $null; return }
        $путь = Путь-Скругления 0 0 $ш $в $r
        $контрол.Region = New-Object System.Drawing.Region($путь)
        $путь.Dispose()
    } catch { Write-Verbose ('скругление не наложено: ' + $_.Exception.Message) }
}

function Тёмная-Шапка($окно) {
    
    $применить = {
        try {
            $да = 1
            foreach ($свойство in @(20, 19)) { [void][AppShell.WindowApi]::DwmSetWindowAttribute($окно.Handle, $свойство, [ref]$да, 4) }
        } catch { Write-Verbose ('тёмная шапка не принята: ' + $_.Exception.Message) }
    }.GetNewClosure()
    if ($окно.IsHandleCreated) { & $применить } else { $окно.Add_HandleCreated($применить) }
}

function Шапка-Окна {
    
    param($окно, [string]$Заголовок = '', $Значок = $null)
    if ($окно.PSObject.Properties['СвояШапка']) { return }
    if (-not ('AppShell.Frame' -as [type])) {
        Add-Type -Namespace AppShell -Name Frame -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
'@
    }
    if (-not $Заголовок) { $Заголовок = $окно.Text }
    if (-not $Значок) { $Значок = $окно.Icon }
    $тянется = $окно.FormBorderStyle -eq [System.Windows.Forms.FormBorderStyle]::Sizable
    $можноСвернуть = $окно.MinimizeBox -and $окно.ShowInTaskbar
    $в = [int](Число-Оболочки 'окно_шапка')
    $поле = [int](Число-Оболочки 'окно_поле')
    $текст = Цвет-Контракта 'текст'
    $подсветка = Цвет-Контракта 'подсветка'
    $альфа = [int](Число-Оболочки 'меню_подсветка_альфа')
    $клиент = $окно.ClientSize
    $окно.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $окно.ClientSize = New-Object System.Drawing.Size($клиент.Width, ($клиент.Height + $в))
    if (@($окно.Controls | Where-Object { $_.Dock -ne [System.Windows.Forms.DockStyle]::None }).Count) {
        $поляОкна = $окно.Padding
        $окно.Padding = New-Object System.Windows.Forms.Padding($поляОкна.Left, ($поляОкна.Top + $в), $поляОкна.Right, $поляОкна.Bottom)
    }
    foreach ($к in @($окно.Controls)) {
        if ($к.Dock -ne [System.Windows.Forms.DockStyle]::None) { continue }
        $к.Top += $в
        if (($к.Anchor -band [System.Windows.Forms.AnchorStyles]::Bottom) -and ($к.Anchor -band [System.Windows.Forms.AnchorStyles]::Top)) { $к.Height -= $в }
    }
    $окно | Add-Member -NotePropertyName 'СвояШапка' -NotePropertyValue $в

    $шапка = New-Object System.Windows.Forms.Panel
    $шапка.SetBounds(0, 0, $окно.ClientSize.Width, $в)
    $шапка.Anchor = 'Top,Left,Right'
    $шапка.BackColor = [System.Drawing.Color]::Transparent
    $тащить = { param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        [void][AppShell.Frame]::ReleaseCapture()
        [void][AppShell.Frame]::SendMessage($s.FindForm().Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero) }   # HTCAPTION
    $шапка.Add_MouseDown($тащить)
    $x = $поле
    if ($Значок) {
        $картинка = New-Object System.Windows.Forms.PictureBox
        $картинка.SizeMode = 'Zoom'
        $картинка.SetBounds($x, [int](($в - 16) / 2), 16, 16)
        $картинка.Image = (New-Object System.Drawing.Icon($Значок, 16, 16)).ToBitmap()
        $картинка.BackColor = [System.Drawing.Color]::Transparent
        $картинка.Add_MouseDown($тащить)
        $шапка.Controls.Add($картинка)
        $x += 24
    }
    $имя = New-Object System.Windows.Forms.Label
    $имя.Text = $Заголовок
    $имя.Font = Шрифт (Число-Оболочки 'окно_кегль') $true
    $имя.ForeColor = $текст
    $имя.BackColor = [System.Drawing.Color]::Transparent
    $имя.AutoSize = $true
    $имя.Location = New-Object System.Drawing.Point($x, [int](($в - $имя.PreferredHeight) / 2))
    $имя.Add_MouseDown($тащить)
    $шапка.Controls.Add($имя)

    $кнопки = @(@{ Знак = [string][char]0x2715; Цвет = (Цвет-Контракта 'тревога'); Действие = { param($ф) $ф.Close() } })
    $развернуть = {
        param($ф)
        if ($ф.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized) { $ф.WindowState = [System.Windows.Forms.FormWindowState]::Normal }
        else { $ф.MaximizedBounds = [System.Windows.Forms.Screen]::FromControl($ф).WorkingArea; $ф.WindowState = [System.Windows.Forms.FormWindowState]::Maximized }
    }
    if ($тянется -and $окно.MaximizeBox) {
        $кнопки += @{ Знак = [string][char]0x25A1; Цвет = $подсветка; Действие = $развернуть }
        $шапка.Tag = $развернуть
        $шапка.Add_DoubleClick({ param($s, $e) & $s.Tag $s.FindForm() })
    }
    if ($можноСвернуть) { $кнопки += @{ Знак = [string][char]0x2212; Цвет = $подсветка
                                         Действие = { param($ф) $ф.WindowState = [System.Windows.Forms.FormWindowState]::Minimized } } }
    $размер = $в - 8
    $правый = $окно.ClientSize.Width - $поле / 2
    foreach ($к in $кнопки) {
        $правый -= $размер
        $б = New-Object System.Windows.Forms.Label
        $б.Text = $к.Знак
        $б.Font = Шрифт-Символов (Число-Оболочки 'окно_кегль')
        $б.ForeColor = $текст
        $б.BackColor = [System.Drawing.Color]::Transparent
        $б.TextAlign = 'MiddleCenter'
        $б.SetBounds($правый, 4, $размер, $размер)
        $б.Anchor = 'Top,Right'
        $б.Cursor = [System.Windows.Forms.Cursors]::Hand
        $б.Tag = @{ Цвет = [System.Drawing.Color]::FromArgb($альфа, $к.Цвет.R, $к.Цвет.G, $к.Цвет.B); Действие = $к.Действие }
        $б.Add_MouseEnter({ param($s, $e) $s.BackColor = $s.Tag.Цвет })
        $б.Add_MouseLeave({ param($s, $e) $s.BackColor = [System.Drawing.Color]::Transparent })
        $б.Add_Click({ param($s, $e) & $s.Tag.Действие $s.FindForm() })
        Скруглить $б (Радиус-Контракта 'кнопка')
        $шапка.Controls.Add($б)
        $правый -= 4
    }
    $окно.Controls.Add($шапка)
    $шапка.BringToFront()

    if ($тянется) {
        $угол = New-Object System.Windows.Forms.Label
        $угол.SetBounds(($окно.ClientSize.Width - 14), ($окно.ClientSize.Height - 14), 14, 14)
        $угол.Anchor = 'Bottom,Right'
        $угол.Cursor = [System.Windows.Forms.Cursors]::SizeNWSE
        $угол.BackColor = [System.Drawing.Color]::Transparent
        $угол.Add_MouseDown({ param($s, $e)
            [void][AppShell.Frame]::ReleaseCapture()
            [void][AppShell.Frame]::SendMessage($s.FindForm().Handle, 0xA1, [IntPtr]17, [IntPtr]::Zero) })
        $окно.Controls.Add($угол)
        $угол.BringToFront()
    }
    $стили = {
        param($s, $e)
        try {
            $стиль = [AppShell.Frame]::GetWindowLong($s.Handle, -16)
            [void][AppShell.Frame]::SetWindowLong($s.Handle, -16, ($стиль -bor 0x00020000 -bor 0x00080000))
        } catch { Write-Verbose ('стили окна не приняты: ' + $_.Exception.Message) }
    }
    if ($окно.IsHandleCreated) { & $стили $окно $null } else { $окно.Add_HandleCreated($стили) }
    Скруглить $окно (Радиус-Контракта 'карточка')
    $окно.Add_Resize({ param($s, $e) Скруглить $s (Радиус-Контракта 'карточка') })
    $окно.Add_Shown({ param($s, $e) Стекло $s })
    if ($окно.Visible) { Стекло $окно }   # позвана после показа — событие показа уже прошло
}

function Тёмный-Контрол($контрол) {
    try { [void][AppShell.WindowApi]::SetWindowTheme($контрол.Handle, 'DarkMode_Explorer', $null) }
    catch { Write-Verbose ('тёмная тема контрола не принята: ' + $_.Exception.Message) }
}

function Поднять-Наверх($окно) {
    
    try {
        if ([AppShell.WindowApi]::IsIconic($окно.Handle)) { [void][AppShell.WindowApi]::ShowWindow($окно.Handle, 9) }
        $окно.TopMost = $true
        $окно.Activate()
        $окно.BringToFront()
        $окно.TopMost = $false
    } catch { Write-Verbose ('окно не поднято: ' + $_.Exception.Message) }
}

function Окно-Настроек {
    
    param(
        [Parameter(Mandatory = $true)][string]$Заголовок,
        $Значок,
        [Parameter(Mandatory = $true)][object[]]$Вкладки,
        [object[]]$Ссылки = @(),
        [scriptblock]$Сохранить,
        $Владелец,
        [switch]$НеПоказывать
    )
    $фон = Цвет-Контракта 'фон'
    $карточка = Цвет-Контракта 'карточка'
    $текст = Цвет-Контракта 'текст'
    $тусклый = Цвет-Контракта 'текст_второй'
    $акцент = Цвет-Контракта 'акцент'
    $подсветка = Цвет-Контракта 'подсветка'
    $поле = [int](Число-Оболочки 'окно_поле')
    $строка = [int](Число-Оболочки 'окно_вкладка')
    $кнопка = [int](Число-Оболочки 'окно_кнопка')
    $ширинаМеню = [int](Число-Оболочки 'настройки_меню')
    $ширинаСодержимого = [int](Число-Оболочки 'окно_настроек')
    $высота = [int](Число-Оболочки 'настройки_высота')
    $шрифт = Шрифт (Число-Оболочки 'окно_кегль')
    $шрифтРаздела = Шрифт (Число-Оболочки 'окно_кегль_раздела') $true

    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Заголовок
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $f.MaximizeBox = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.BackColor = $фон
    $f.ForeColor = $текст
    $f.Font = $шрифт
    if ($Значок) { try { $f.Icon = $Значок } catch { Write-Verbose ('значок окна настроек не встал: ' + $_.Exception.Message) } }
    $f.ClientSize = New-Object System.Drawing.Size(($ширинаМеню + $ширинаСодержимого), $высота)
    $значения = @{}
    $f.Tag = @{ Значения = $значения; Вкладки = $Вкладки; Сохранить = $Сохранить; Раздел = 0; Подраздел = 0 }

    $меню = New-Object System.Windows.Forms.Panel
    $меню.SetBounds(0, 0, $ширинаМеню, $высота)
    $меню.BackColor = $карточка
    $f.Controls.Add($меню)
    $низ = New-Object System.Windows.Forms.Panel
    $низ.SetBounds($ширинаМеню, ($высота - $кнопка - 2 * $поле), $ширинаСодержимого, ($кнопка + 2 * $поле))
    $низ.BackColor = $фон
    $f.Controls.Add($низ)
    $подвкладки = New-Object System.Windows.Forms.Panel
    $подвкладки.SetBounds($ширинаМеню, 0, $ширинаСодержимого, 0)
    $подвкладки.BackColor = $фон
    $f.Controls.Add($подвкладки)
    $строки = New-Object System.Windows.Forms.Panel
    $строки.BackColor = $фон
    $строки.AutoScroll = $true
    $f.Controls.Add($строки)
    $f.Tag.Меню = $меню; $f.Tag.Подвкладки = $подвкладки; $f.Tag.Строки = $строки; $f.Tag.Низ = $низ

    foreach ($в in $Вкладки) {
        $наборы = if ($в.Подвкладки) { @($в.Подвкладки | ForEach-Object { $_.Строки }) } else { @($в.Строки) }
        foreach ($с in $наборы) { if ($с -and $с.Ключ) { $значения[$с.Ключ] = $с.Значение } }
    }

    $y = $поле
    for ($i = 0; $i -lt $Вкладки.Count; $i++) {
        $пункт = New-Object System.Windows.Forms.Label
        $пункт.Text = [string]$Вкладки[$i].Имя
        $пункт.Font = $шрифт
        $пункт.ForeColor = $текст
        $пункт.BackColor = $карточка
        $пункт.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $пункт.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
        $пункт.Cursor = [System.Windows.Forms.Cursors]::Hand
        $пункт.SetBounds(($поле / 2), $y, ($ширинаМеню - $поле), $строка + 4)
        $пункт.Tag = $i
        $пункт.Add_Click({ param($s, $e) $ф = $s.FindForm(); $ф.Tag.Раздел = [int]$s.Tag; $ф.Tag.Подраздел = 0; Показать-Раздел-Настроек $ф })
        $меню.Controls.Add($пункт)
        Скруглить $пункт (Радиус-Контракта 'кнопка')
        $y += $строка + 8
    }

    $xл = $поле
    foreach ($сс in $Ссылки) {
        $л = Новая-Кнопка-Настроек ([string]$сс.Подпись) $карточка $текст
        $л.Location = New-Object System.Drawing.Point($xл, $поле)
        $л.Tag = $сс.Действие
        $л.Add_Click({ param($s, $e) try { & $s.Tag } catch { Write-Verbose ('ссылка настроек упала: ' + $_.Exception.Message) } })
        $низ.Controls.Add($л)
        $xл += $л.Width + 6
    }
    $отмена = Новая-Кнопка-Настроек 'Отмена' $карточка $текст
    $отмена.Location = New-Object System.Drawing.Point(($ширинаСодержимого - $поле - $отмена.Width), $поле)
    $отмена.Add_Click({ param($s, $e) $s.FindForm().Close() })
    $низ.Controls.Add($отмена)
    $сохр = Новая-Кнопка-Настроек 'Сохранить' $акцент (Цвет-Надписи $акцент)
    $сохр.Location = New-Object System.Drawing.Point(($отмена.Left - 6 - $сохр.Width), $поле)
    $сохр.Add_Click({ param($s, $e) $ф = $s.FindForm(); $д = $ф.Tag.Сохранить
                      if ($д) { try { & $д $ф.Tag.Значения } catch { Write-Verbose ('сохранение настроек упало: ' + $_.Exception.Message) } }
                      $ф.Close() })
    $низ.Controls.Add($сохр)

    Шапка-Окна $f -Значок $Значок   # своя шапка на стекле, стекло и скругление — как у главного окна
    Показать-Раздел-Настроек $f
    if ($НеПоказывать) { return $f }
    if ($Владелец) { [void]$f.ShowDialog($Владелец) } else { [void]$f.ShowDialog() }
    return $f
}

function Новая-Кнопка-Настроек([string]$надпись, $цвет, $цветТекста) {
    $к = New-Object System.Windows.Forms.Label
    $к.Text = $надпись
    $к.Font = Шрифт (Число-Оболочки 'окно_кегль')
    $к.BackColor = $цвет
    $к.ForeColor = $цветТекста
    $к.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $к.Cursor = [System.Windows.Forms.Cursors]::Hand
    $к.Size = New-Object System.Drawing.Size(([System.Windows.Forms.TextRenderer]::MeasureText($надпись, $к.Font).Width + 24), [int](Число-Оболочки 'окно_вкладка'))
    Скруглить $к (Радиус-Контракта 'кнопка')
    return $к
}

function Покрасить-Чип($чип, [bool]$выбран) {
    if ($выбран) { $чип.BackColor = Цвет-Контракта 'акцент'; $чип.ForeColor = Цвет-Надписи (Цвет-Контракта 'акцент') }
    else { $чип.BackColor = Цвет-Контракта 'подсветка'; $чип.ForeColor = Цвет-Контракта 'текст_второй' }
}

function Показать-Раздел-Настроек($f) {
    
    $т = $f.Tag
    $поле = [int](Число-Оболочки 'окно_поле')
    $строка = [int](Число-Оболочки 'окно_вкладка')
    $ширинаМеню = [int](Число-Оболочки 'настройки_меню')
    $ширина = [int](Число-Оболочки 'окно_настроек')
    $раздел = $т.Вкладки[$т.Раздел]
    foreach ($п in $т.Меню.Controls) {
        $выбран = ([int]$п.Tag -eq $т.Раздел)
        $п.BackColor = if ($выбран) { Цвет-Контракта 'подсветка' } else { Цвет-Контракта 'карточка' }
        $п.ForeColor = if ($выбран) { Цвет-Контракта 'акцент' } else { Цвет-Контракта 'текст' }
    }
    $т.Подвкладки.Controls.Clear()
    $верх = 0
    if ($раздел.Подвкладки) {
        $x = $поле
        for ($j = 0; $j -lt $раздел.Подвкладки.Count; $j++) {
            $ч = Новая-Кнопка-Настроек ([string]$раздел.Подвкладки[$j].Имя) (Цвет-Контракта 'подсветка') (Цвет-Контракта 'текст_второй')
            $ч.Location = New-Object System.Drawing.Point($x, $поле)
            Покрасить-Чип $ч ($j -eq $т.Подраздел)
            $ч.Tag = $j
            $ч.Add_Click({ param($s, $e) $ф = $s.FindForm(); $ф.Tag.Подраздел = [int]$s.Tag; Показать-Раздел-Настроек $ф })
            $т.Подвкладки.Controls.Add($ч)
            $x += $ч.Width + 6
        }
        $верх = $строка + 2 * $поле
        $наборСтрок = @($раздел.Подвкладки[$т.Подраздел].Строки)
        $имяЗаголовка = [string]$раздел.Подвкладки[$т.Подраздел].Имя
    } else {
        $наборСтрок = @($раздел.Строки)
        $имяЗаголовка = [string]$раздел.Имя
    }
    $т.Подвкладки.Height = $верх
    $сдвиг = if ($f.PSObject.Properties['СвояШапка']) { [int]$f.СвояШапка } else { 0 }
    $т.Строки.SetBounds($ширинаМеню, ($верх + $сдвиг), $ширина, ($f.ClientSize.Height - $верх - $сдвиг - $т.Низ.Height))
    $т.Строки.SuspendLayout()
    $т.Строки.Controls.Clear()
    $т.Строки.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    $y = $поле
    $з = New-Object System.Windows.Forms.Label
    $з.Text = $имяЗаголовка
    $з.Font = Шрифт (Число-Оболочки 'окно_кегль_раздела') $true
    $з.ForeColor = Цвет-Контракта 'текст'
    $з.AutoSize = $true
    $з.Location = New-Object System.Drawing.Point($поле, $y)
    $т.Строки.Controls.Add($з)
    $y += $з.PreferredHeight + 10
    $право = $ширина - $поле - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
    foreach ($с in $наборСтрок) {
        if (-not $с) { continue }
        $отступ = if ($с.Вложенная) { $поле + 16 } else { $поле }
        $элементы = @()
        switch ([string]$с.Вид) {
            'флажок' {
                $вкл = [bool]$т.Значения[$с.Ключ]
                $надписьВкл = if ($с.Вкл) { [string]$с.Вкл } else { 'Включено' }
                $надписьВыкл = if ($с.Выкл) { [string]$с.Выкл } else { 'Выключено' }
                $ч = Новая-Кнопка-Настроек $(if ($вкл) { $надписьВкл } else { $надписьВыкл }) (Цвет-Контракта 'подсветка') (Цвет-Контракта 'текст')
                $шир = [Math]::Max([System.Windows.Forms.TextRenderer]::MeasureText($надписьВкл, $ч.Font).Width, [System.Windows.Forms.TextRenderer]::MeasureText($надписьВыкл, $ч.Font).Width) + 24
                $ч.Width = $шир
                Скруглить $ч (Радиус-Контракта 'кнопка')
                Покрасить-Чип $ч $вкл
                $ч.Tag = @{ Ключ = $с.Ключ; Вкл = $надписьВкл; Выкл = $надписьВыкл; Сразу = $с.Сразу }
                $ч.Add_Click({ param($s, $e) $ф = $s.FindForm(); $м = $s.Tag
                               $новое = -not [bool]$ф.Tag.Значения[$м.Ключ]; $ф.Tag.Значения[$м.Ключ] = $новое
                               $s.Text = $(if ($новое) { $м.Вкл } else { $м.Выкл }); Покрасить-Чип $s $новое
                               if ($м.Сразу) { try { & $м.Сразу $м.Ключ $новое } catch { Write-Verbose ('настройка не применилась: ' + $_.Exception.Message) } } })
                $элементы = @($ч)
            }
            'выбор' {
                foreach ($вар in @($с.Варианты)) {
                    $ч = Новая-Кнопка-Настроек ([string]$вар.Подпись) (Цвет-Контракта 'подсветка') (Цвет-Контракта 'текст')
                    Покрасить-Чип $ч ([string]$т.Значения[$с.Ключ] -eq [string]$вар.Имя)
                    $ч.Tag = @{ Ключ = $с.Ключ; Имя = [string]$вар.Имя }
                    $ч.Add_Click({ param($s, $e) $ф = $s.FindForm(); $ф.Tag.Значения[$s.Tag.Ключ] = $s.Tag.Имя
                                   foreach ($к in $s.Parent.Controls) { if ($к.Tag -is [hashtable] -and $к.Tag.Ключ -eq $s.Tag.Ключ -and $к.Tag.Имя) { Покрасить-Чип $к ($к.Tag.Имя -eq $s.Tag.Имя) } } })
                    $элементы += $ч
                }
            }
            'действие' {
                $ч = Новая-Кнопка-Настроек ([string]$с.Кнопка) (Цвет-Контракта 'подсветка') $(if ($с.Цвет) { $с.Цвет } else { Цвет-Контракта 'текст' })
                $ч.Tag = $с.Действие
                $ч.Add_Click({ param($s, $e) try { & $s.Tag } catch { Write-Verbose ('действие настроек упало: ' + $_.Exception.Message) } })
                $элементы = @($ч)
            }
            'поле' {
                $п = New-Object System.Windows.Forms.TextBox
                $п.Text = [string]$т.Значения[$с.Ключ]
                $п.Font = Шрифт (Число-Оболочки 'окно_кегль')
                $п.BackColor = Цвет-Контракта 'карточка'
                $п.ForeColor = Цвет-Контракта 'текст'
                $п.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
                $п.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
                $п.Width = if ($с.Ширина) { [int]$с.Ширина } else { 80 }
                $п.Tag = @{ Ключ = $с.Ключ }
                $п.Add_TextChanged({ param($s, $e) $s.FindForm().Tag.Значения[$s.Tag.Ключ] = $s.Text })
                $элементы = @($п)
            }
        }
        $x = $право
        for ($k = $элементы.Count - 1; $k -ge 0; $k--) {
            $э = $элементы[$k]
            $x -= $э.Width
            $э.Location = New-Object System.Drawing.Point($x, ($y + [int](($строка - $э.Height) / 2)))
            $т.Строки.Controls.Add($э)
            $x -= 6
        }
        $подпись = New-Object System.Windows.Forms.Label
        $подпись.Text = [string]$с.Подпись
        $подпись.Font = Шрифт (Число-Оболочки 'окно_кегль')
        $подпись.ForeColor = if ($с.Цвет) { $с.Цвет } elseif ($с.Вложенная) { Цвет-Контракта 'текст_второй' } else { Цвет-Контракта 'текст' }
        $подпись.AutoEllipsis = $true
        $подпись.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $подпись.SetBounds($отступ, $y, [Math]::Max(40, ($x - $отступ - 4)), $строка)
        $т.Строки.Controls.Add($подпись)
        $y += $строка + 8
    }
    $т.Строки.ResumeLayout()
    $f.ActiveControl = $null   # поле не открывается выделенным: фокус ставит человек
}
