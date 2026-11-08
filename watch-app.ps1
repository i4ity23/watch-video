# Watch Video v2 - a desktop app for "watching" videos with Claude.
# Find a video (link, search, playlist, Instagram/TikTok/X, or your own file), preview it, queue it,
# and get a transcript + timestamped frame sheets + a claude.md note in watch-output\<video>\.
# Needs watch-core.ps1 (and transcribe.py for speech-to-text) in the same folder.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$here = $PSScriptRoot
if (-not $here) { $here = [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\') }
$core = Join-Path $here 'watch-core.ps1'
$settingsFile = Join-Path $here 'settings.json'
$inv = [Globalization.CultureInfo]::InvariantCulture
function Refresh-Path { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }
Refresh-Path

# ---------------- Settings ----------------
$script:cfg = [pscustomobject]@{ MaxFrames = 96; Height = 480; OutRoot = (Join-Path $here 'watch-output') }
if (Test-Path $settingsFile) {
    try {
        $s = Get-Content $settingsFile -Raw | ConvertFrom-Json
        if ($s.MaxFrames) { $script:cfg.MaxFrames = [int]$s.MaxFrames }
        if ($s.Height) { $script:cfg.Height = [int]$s.Height }
        if ($s.OutRoot) { $script:cfg.OutRoot = "$($s.OutRoot)" }
    } catch {}
}
function Save-Settings { $script:cfg | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8 }

# ---------------- Look ----------------
$bg = [System.Drawing.Color]::FromArgb(22, 20, 18)
$panelC = [System.Drawing.Color]::FromArgb(38, 35, 31)
$line = [System.Drawing.Color]::FromArgb(70, 62, 50)
$text = [System.Drawing.Color]::FromArgb(245, 240, 230)
$muted = [System.Drawing.Color]::FromArgb(170, 160, 145)
$honey = [System.Drawing.Color]::FromArgb(245, 179, 1)
$red = [System.Drawing.Color]::FromArgb(248, 113, 113)
$font = New-Object System.Drawing.Font('Segoe UI', 10)
$bold = New-Object System.Drawing.Font('Segoe UI Semibold', 10)

function P($x, $y) { New-Object System.Drawing.Point($x, $y) }
function S($w, $h) { New-Object System.Drawing.Size($w, $h) }
function New-Btn($label, $x, $y, $w, $primary) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $label; $b.Location = P $x $y; $b.Size = S $w 32; $b.FlatStyle = 'Flat'; $b.Font = $bold; $b.Cursor = 'Hand'
    if ($primary) { $b.BackColor = $honey; $b.ForeColor = [System.Drawing.Color]::Black; $b.FlatAppearance.BorderSize = 0 }
    else { $b.BackColor = $panelC; $b.ForeColor = $text; $b.FlatAppearance.BorderColor = $line }
    return $b
}
function New-Lbl($t, $x, $y, $color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $t; $l.Location = P $x $y; $l.AutoSize = $true; $l.ForeColor = $color; return $l
}
function New-Box($x, $y, $w, $h) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = P $x $y; $t.Size = S $w $h; $t.BackColor = $panelC; $t.ForeColor = $text; $t.BorderStyle = 'FixedSingle'; return $t
}
function New-List($x, $y, $w, $h) {
    $l = New-Object System.Windows.Forms.ListView
    $l.View = 'Details'; $l.FullRowSelect = $true; $l.MultiSelect = $false; $l.HideSelection = $false
    $l.Location = P $x $y; $l.Size = S $w $h; $l.BackColor = $panelC; $l.ForeColor = $text; $l.BorderStyle = 'None'
    $l.Anchor = 'Top,Bottom,Left,Right'; return $l
}
function New-ImgList { $il = New-Object System.Windows.Forms.ImageList; $il.ImageSize = S 112 63; $il.ColorDepth = 'Depth32Bit'; return $il }

# ---------------- Helpers ----------------
function Fmt-Sec($sec) {
    if (-not $sec) { return '' }
    $t = [timespan]::FromSeconds([math]::Floor([double]$sec))
    if ($t.TotalHours -ge 1) { return $t.ToString('h\:mm\:ss') } else { return $t.ToString('m\:ss') }
}
function Parse-Time($s) {
    $s = "$s".Trim(); if (-not $s) { return 0.0 }
    $total = 0.0
    foreach ($p in $s.Split(':')) { $total = $total * 60 + [double]::Parse($p, $inv) }
    return $total
}
function Load-Image($path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    try { $bytes = [System.IO.File]::ReadAllBytes($path); return [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, $bytes))) } catch { return $null }
}
$script:webCache = @{}
function Web-Image($url) {
    if (-not $url) { return $null }
    if ($script:webCache.ContainsKey($url)) { return $script:webCache[$url] }
    $img = $null
    try {
        $wc = New-Object System.Net.WebClient
        $bytes = $wc.DownloadData($url)
        $img = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, $bytes)))
    } catch {}
    $script:webCache[$url] = $img
    return $img
}
function Fit-Thumb($img) {
    # Letterbox an image into the 112x63 list thumbnail.
    $bmp = New-Object System.Drawing.Bitmap 112, 63
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::Black)
    if ($img) {
        $r = [math]::Min(112 / $img.Width, 63 / $img.Height); $w = $img.Width * $r; $h = $img.Height * $r
        $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($img, [single]((112 - $w) / 2), [single]((63 - $h) / 2), [single]$w, [single]$h)
    }
    $g.Dispose(); return $bmp
}
function Start-Hidden($scriptText, $logFile) {
    # Runs PowerShell code in a hidden window, all output to $logFile. Returns the process.
    $full = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; `$env:PYTHONIOENCODING='utf-8'; & { $scriptText } *> '$logFile'"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
    $psi.WorkingDirectory = $here; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}
function Read-Log($path) {
    if (-not (Test-Path $path)) { return @() }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs, $true); $s = $sr.ReadToEnd(); $sr.Close()
        return @($s -split "`r?`n" | Where-Object { $_.Trim() })
    } catch { return @() }
}
function Q($s) { "'" + ("$s" -replace "'", "''") + "'" }
$videoExt = '.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v', '.gif'

# ---------------- Window ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Watch Video'; $form.Size = S 1200 650; $form.MinimumSize = S 1000 620
$form.StartPosition = 'CenterScreen'; $form.BackColor = $bg; $form.ForeColor = $text; $form.Font = $font; $form.AllowDrop = $true
$icoPath = Join-Path $here 'watch.ico'
if (Test-Path $icoPath) { try { $form.Icon = New-Object System.Drawing.Icon($icoPath) } catch {} }

$hTitle = New-Lbl 'Watch Video' 20 10 $honey; $hTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18); $form.Controls.Add($hTitle)
$form.Controls.Add((New-Lbl 'Paste links (one per line), a playlist, Instagram/TikTok/X links, or search words - or drop video files here.' 22 46 $muted))

$btnUpdate = New-Btn 'Update tools' 900 12 130 $false; $btnUpdate.Anchor = 'Top,Right'; $form.Controls.Add($btnUpdate)
$btnSettings = New-Btn 'Settings' 1040 12 130 $false; $btnSettings.Anchor = 'Top,Right'; $form.Controls.Add($btnSettings)

$txtIn = New-Box 20 72 920 50; $txtIn.Multiline = $true; $txtIn.AcceptsReturn = $false; $txtIn.ScrollBars = 'Vertical'
$txtIn.Font = New-Object System.Drawing.Font('Segoe UI', 11); $txtIn.Anchor = 'Top,Left,Right'; $txtIn.AllowDrop = $true
$form.Controls.Add($txtIn)
$btnFind = New-Btn 'Find' 950 72 220 $true; $btnFind.Anchor = 'Top,Right'; $form.Controls.Add($btnFind)
$btnFiles = New-Btn 'Add video files...' 950 104 220 $false; $btnFiles.Anchor = 'Top,Right'; $form.Controls.Add($btnFiles)
$form.AcceptButton = $btnFind

$form.Controls.Add((New-Lbl 'Only part (optional):  from' 20 133 $muted))
$txtFrom = New-Box 200 130 70 24; $txtFrom.TextAlign = 'Center'; $form.Controls.Add($txtFrom)
$form.Controls.Add((New-Lbl 'to' 278 133 $muted))
$txtTo = New-Box 300 130 70 24; $txtTo.TextAlign = 'Center'; $form.Controls.Add($txtTo)
$form.Controls.Add((New-Lbl '(m:ss)' 376 133 $muted))
$chkRecreate = New-Object System.Windows.Forms.CheckBox
$chkRecreate.Text = 'Recreate this in Blender'; $chkRecreate.Location = P 460 131; $chkRecreate.AutoSize = $true; $chkRecreate.ForeColor = $text
$form.Controls.Add($chkRecreate)

# ---- Tabs ----
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = P 20 160; $tabs.Size = S 700 400; $tabs.Anchor = 'Top,Bottom,Left,Right'
$tabFind = New-Object System.Windows.Forms.TabPage; $tabFind.Text = 'Find'; $tabFind.BackColor = $bg
$tabQueue = New-Object System.Windows.Forms.TabPage; $tabQueue.Text = 'Queue'; $tabQueue.BackColor = $bg
$tabLib = New-Object System.Windows.Forms.TabPage; $tabLib.Text = 'Library'; $tabLib.BackColor = $bg
$tabs.TabPages.AddRange(@($tabFind, $tabQueue, $tabLib)); $form.Controls.Add($tabs)

# Find tab
$results = New-List 6 6 680 320; $results.CheckBoxes = $true; $results.AllowDrop = $true
$results.SmallImageList = New-ImgList
[void]$results.Columns.Add('Title', 330); [void]$results.Columns.Add('Channel', 140); [void]$results.Columns.Add('Length', 60); [void]$results.Columns.Add('From', 90)
$tabFind.Controls.Add($results)
$btnWatch = New-Btn 'Watch ticked videos' 6 334 190 $true; $btnWatch.Anchor = 'Bottom,Left'; $tabFind.Controls.Add($btnWatch)
$lblFindHint = New-Lbl 'Click a result to preview it. Tick the ones you want.' 206 342 $muted; $lblFindHint.Anchor = 'Bottom,Left'; $tabFind.Controls.Add($lblFindHint)

# Queue tab
$queueList = New-List 6 6 680 190; $queueList.Anchor = 'Top,Left,Right'
[void]$queueList.Columns.Add('Video', 430); [void]$queueList.Columns.Add('Status', 230)
$tabQueue.Controls.Add($queueList)
$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.Location = P 6 202; $log.Size = S 680 124
$log.BackColor = $panelC; $log.ForeColor = $muted; $log.BorderStyle = 'None'; $log.Font = New-Object System.Drawing.Font('Consolas', 9); $log.Anchor = 'Top,Bottom,Left,Right'
$tabQueue.Controls.Add($log)
$btnRemove = New-Btn 'Remove' 6 334 110 $false; $btnRemove.Anchor = 'Bottom,Left'; $tabQueue.Controls.Add($btnRemove)
$btnClearDone = New-Btn 'Clear finished' 124 334 140 $false; $btnClearDone.Anchor = 'Bottom,Left'; $tabQueue.Controls.Add($btnClearDone)

# Library tab
$tabLib.Controls.Add((New-Lbl 'Search:' 6 10 $muted))
$libSearch = New-Box 64 6 300 24; $tabLib.Controls.Add($libSearch)
$libList = New-List 6 38 680 288; $libList.SmallImageList = New-ImgList
[void]$libList.Columns.Add('Title', 300); [void]$libList.Columns.Add('Channel', 120); [void]$libList.Columns.Add('Length', 60); [void]$libList.Columns.Add('Tags', 120); [void]$libList.Columns.Add('Saved', 70)
$tabLib.Controls.Add($libList)
$btnRefresh = New-Btn 'Refresh' 6 334 110 $false; $btnRefresh.Anchor = 'Bottom,Left'; $tabLib.Controls.Add($btnRefresh)
$lblSpace = New-Lbl '' 126 342 $muted; $lblSpace.Anchor = 'Bottom,Left'; $tabLib.Controls.Add($lblSpace)

# ---- Preview panel ----
$pv = New-Object System.Windows.Forms.Panel
$pv.Location = P 732 160; $pv.Size = S 440 400; $pv.Anchor = 'Top,Bottom,Right'; $pv.AutoScroll = $true; $form.Controls.Add($pv)
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Location = P 0 0; $pic.Size = S 420 190; $pic.SizeMode = 'Zoom'; $pic.BackColor = [System.Drawing.Color]::Black; $pv.Controls.Add($pic)
$pvTitle = New-Object System.Windows.Forms.Label
$pvTitle.Location = P 0 194; $pvTitle.Size = S 420 40; $pvTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11); $pvTitle.ForeColor = $text
$pvTitle.Text = 'Preview'; $pv.Controls.Add($pvTitle)
$pvMeta = New-Object System.Windows.Forms.Label
$pvMeta.Location = P 0 234; $pvMeta.Size = S 420 20; $pvMeta.ForeColor = $muted; $pvMeta.Text = 'Pick a video to see it here.'; $pv.Controls.Add($pvMeta)
$btnOpenLink = New-Btn 'Open link' 0 258 136 $false; $pv.Controls.Add($btnOpenLink)
$btnPlay = New-Btn 'Play video' 142 258 136 $false; $pv.Controls.Add($btnPlay)
$btnFolder = New-Btn 'Open folder' 284 258 136 $false; $pv.Controls.Add($btnFolder)

$lib = New-Object System.Windows.Forms.Panel
$lib.Location = P 0 296; $lib.Size = S 420 100; $lib.Visible = $false; $pv.Controls.Add($lib)
$lib.Controls.Add((New-Lbl 'Tags' 0 3 $muted))
$txtTags = New-Box 48 0 200 24; $lib.Controls.Add($txtTags)
$lib.Controls.Add((New-Lbl 'Notes' 0 33 $muted))
$chkLibRecreate = New-Object System.Windows.Forms.CheckBox
$chkLibRecreate.Text = 'Recreate in Blender'; $chkLibRecreate.Location = P 260 2; $chkLibRecreate.AutoSize = $true; $chkLibRecreate.ForeColor = $text
$lib.Controls.Add($chkLibRecreate)
$txtNotes = New-Box 48 30 372 24; $lib.Controls.Add($txtNotes)
$btnSend = New-Btn 'Send to Claude' 0 62 140 $true; $lib.Controls.Add($btnSend)
$btnSave = New-Btn 'Save' 146 62 70 $false; $lib.Controls.Add($btnSave)
$btnSpace = New-Btn 'Save space' 222 62 110 $false; $lib.Controls.Add($btnSpace)
$btnDelete = New-Btn 'Delete' 338 62 82 $false; $lib.Controls.Add($btnDelete)

# ---- Status bar ----
$status = New-Lbl 'Ready.' 20 568 $muted; $status.Anchor = 'Bottom,Left'; $form.Controls.Add($status)
$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = P 20 592; $bar.Size = S 1150 6; $bar.Style = 'Marquee'; $bar.MarqueeAnimationSpeed = 0; $bar.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($bar)
function Say($msg, $color) { $status.Text = $msg; if ($color) { $status.ForeColor = $color } else { $status.ForeColor = $muted } }

# ---------------- Preview ----------------
$script:sel = $null   # what's in the preview: @{Kind; Link; Dir; File}
function Show-Preview($img, $title, $meta, $sel) {
    $pic.Image = $img; $pvTitle.Text = $title; $pvMeta.Text = $meta; $script:sel = $sel
    $lib.Visible = ($sel.Kind -eq 'lib')
    $btnFolder.Enabled = [bool]$sel.Dir
}

# ---------------- Find / search ----------------
$script:findProc = $null; $script:findFile = $null; $script:findLog = Join-Path $env:TEMP 'watch-find.log'
$tpl = '%(id)s|~|%(title)s|~|%(channel,uploader|)s|~|%(duration|)s|~|%(webpage_url,url)s|~|%(thumbnail|)s|~|%(extractor_key,ie_key|)s'

function Thumb-Url($r, $big) {
    if ($r.Extractor -match 'youtube' -or $r.Url -match 'youtu') {
        if ($big) { return "https://i.ytimg.com/vi/$($r.Id)/hqdefault.jpg" } else { return "https://i.ytimg.com/vi/$($r.Id)/mqdefault.jpg" }
    }
    return $r.Thumb
}
function Frame-Grab($file) {
    $out = Join-Path $env:TEMP ('watch-grab-' + [math]::Abs($file.ToLower().GetHashCode()) + '.jpg')
    if (-not (Test-Path $out)) {
        Start-Process ffmpeg -ArgumentList "-hide_banner -loglevel error -y -ss 1 -i `"$file`" -frames:v 1 -vf scale=480:-2 `"$out`"" -WindowStyle Hidden -Wait
    }
    return (Load-Image $out)
}
function Add-Result($r) {
    $key = "r$($results.Items.Count)"
    $img = if ($r.Local) { Frame-Grab $r.Url } else { Web-Image (Thumb-Url $r $false) }
    $results.SmallImageList.Images.Add($key, (Fit-Thumb $img))
    $it = New-Object System.Windows.Forms.ListViewItem($r.Title, $key)
    [void]$it.SubItems.Add($r.Channel); [void]$it.SubItems.Add((Fmt-Sec $r.Duration)); [void]$it.SubItems.Add($r.From)
    $it.Tag = $r
    [void]$results.Items.Add($it)
    [System.Windows.Forms.Application]::DoEvents()
    return $it
}
function Add-LocalFiles($paths) {
    $added = 0
    foreach ($p in $paths) {
        if ($videoExt -contains ([IO.Path]::GetExtension($p).ToLower())) {
            $r = [pscustomobject]@{ Id = ''; Title = [IO.Path]::GetFileNameWithoutExtension($p); Channel = 'Your file'; Duration = $null; Url = $p; Thumb = ''; Extractor = 'local'; From = 'Your file'; Local = $true }
            $it = Add-Result $r; $it.Checked = $true; $added++
        }
    }
    if ($added) { $tabs.SelectedTab = $tabFind; Say "Added $added file(s). Click Watch ticked videos." }
    else { Say 'Those are not video files.' $red }
}

$btnFind.Add_Click({
    $lines = @($txtIn.Text -split "`r?`n" | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
    if ($lines.Count -eq 0) { Say 'Paste a link or type a search first.' $red; return }
    if ($script:findProc -and -not $script:findProc.HasExited) { return }
    $results.Items.Clear(); $results.SmallImageList.Images.Clear(); $tabs.SelectedTab = $tabFind
    $files = @($lines | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($files.Count) { Add-LocalFiles $files }
    $web = @($lines | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($web.Count -eq 0) { return }
    Refresh-Path
    if (-not (Get-Command yt-dlp -ErrorAction SilentlyContinue)) { Say 'yt-dlp is missing. Click Update tools to install it.' $red; return }
    $script:findFile = Join-Path $env:TEMP ('watch-find-' + [guid]::NewGuid().ToString('N') + '.txt')
    $cmds = foreach ($w in $web) {
        $target = if ($w -match '^https?://') { $w } else { "ytsearch6:$w" }
        "yt-dlp --compat-options no-certifi --no-warnings --flat-playlist --playlist-end 50 --skip-download --print-to-file $(Q $tpl) $(Q $script:findFile) $(Q $target)"
    }
    Remove-Item $script:findLog -ErrorAction SilentlyContinue
    $script:findProc = Start-Hidden ($cmds -join "`n") $script:findLog
    $btnFind.Enabled = $false; $bar.MarqueeAnimationSpeed = 30
    Say 'Searching...'
    $findTimer.Start()
})

$findTimer = New-Object System.Windows.Forms.Timer; $findTimer.Interval = 400
$findTimer.Add_Tick({
    if (-not $script:findProc.HasExited) { return }
    $findTimer.Stop(); $btnFind.Enabled = $true
    if (-not $script:queueRunning) { $bar.MarqueeAnimationSpeed = 0 }
    $rows = @()
    if (Test-Path $script:findFile) { $rows = @(Get-Content $script:findFile -Encoding UTF8 | Where-Object { $_ }); Remove-Item $script:findFile -ErrorAction SilentlyContinue }
    if ($rows.Count -eq 0) {
        $err = (Read-Log $script:findLog | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1)
        if (-not $err) { $err = 'No results.' }
        Say $err $red; return
    }
    Say "Found $($rows.Count). Loading previews..."
    foreach ($row in $rows) {
        $f = @($row -split '\|~\|')
        while ($f.Count -lt 7) { $f += '' }
        $dur = $null; $d = 0.0; if ([double]::TryParse($f[3], [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $dur = $d }
        $ex = $f[6]; if ($f[4] -match 'youtu' -or $ex -match 'youtube') { $ex = 'YouTube' }
        $r = [pscustomobject]@{ Id = $f[0]; Title = $f[1]; Channel = $f[2]; Duration = $dur; Url = $f[4]; Thumb = $f[5]; Extractor = $ex; From = $ex; Local = $false }
        if ($r.Url -notmatch '^https?://' -and $ex -eq 'YouTube') { $r.Url = "https://www.youtube.com/watch?v=$($r.Id)" }
        [void](Add-Result $r)
    }
    if ($results.Items.Count -eq 1) { $results.Items[0].Checked = $true }
    if ($results.Items.Count -gt 0) { $results.Items[0].Selected = $true }
    Say "Found $($rows.Count). Click one to preview, tick what you want, then Watch ticked videos."
})

$results.Add_SelectedIndexChanged({
    if ($results.SelectedItems.Count -eq 0) { return }
    $r = $results.SelectedItems[0].Tag
    $img = if ($r.Local) { Frame-Grab $r.Url } else { Web-Image (Thumb-Url $r $true) }
    if (-not $img -and -not $r.Local) { $img = Web-Image (Thumb-Url $r $false) }
    $meta = (@($r.Channel, (Fmt-Sec $r.Duration), $r.From) | Where-Object { $_ }) -join '  |  '
    $file = $null; if ($r.Local) { $file = $r.Url }
    Show-Preview $img $r.Title $meta @{ Kind = 'result'; Link = $r.Url; File = $file; Dir = $null }
})

$btnFiles.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true; $dlg.Filter = 'Videos|*.mp4;*.mov;*.mkv;*.webm;*.avi;*.m4v;*.gif|All files|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { Add-LocalFiles $dlg.FileNames }
})
$dragEnter = { if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } }
$dragDrop = { Add-LocalFiles ($_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)) }
foreach ($c in $form, $results, $txtIn) { $c.Add_DragEnter($dragEnter); $c.Add_DragDrop($dragDrop) }

# ---------------- Queue ----------------
$script:queue = New-Object System.Collections.ArrayList
$script:job = $null; $script:queueRunning = $false
$jobLog = Join-Path $env:TEMP 'watch-job.log'

$btnWatch.Add_Click({
    $picked = @($results.CheckedItems)
    if ($picked.Count -eq 0 -and $results.SelectedItems.Count -gt 0) { $picked = @($results.SelectedItems[0]) }
    if ($picked.Count -eq 0) { Say 'Tick at least one video first.' $red; return }
    try { $from = Parse-Time $txtFrom.Text; $to = Parse-Time $txtTo.Text } catch { Say 'Use m:ss for the part times, like 9:00 and 14:30.' $red; return }
    foreach ($it in $picked) {
        $r = $it.Tag
        $q = [pscustomobject]@{ Source = $r.Url; Title = $r.Title; Start = [double]$from; End = [double]$to; Recreate = $chkRecreate.Checked; Status = 'Waiting'; OutDir = $null; Item = $null; Result = $r }
        $li = New-Object System.Windows.Forms.ListViewItem($r.Title)
        $label = 'Waiting'
        if ($from -gt 0 -or $to -gt 0) { $endTxt = 'end'; if ($to -gt 0) { $endTxt = Fmt-Sec $to }; $label = "Waiting (part $(Fmt-Sec $from)-$endTxt)" }
        [void]$li.SubItems.Add($label); $li.Tag = $q; $q.Item = $li
        [void]$queueList.Items.Add($li); [void]$script:queue.Add($q)
        $it.Checked = $false
    }
    $tabs.SelectedTab = $tabQueue
    Say "$($picked.Count) added to the queue."
    $queueTimer.Start()
})

function Start-Next {
    $next = $script:queue | Where-Object { $_.Status -eq 'Waiting' } | Select-Object -First 1
    if (-not $next) { $script:queueRunning = $false; $bar.MarqueeAnimationSpeed = 0; return }
    $script:queueRunning = $true; $bar.MarqueeAnimationSpeed = 30
    $next.Status = 'Working'; $next.Item.SubItems[1].Text = 'Starting...'
    Remove-Item $jobLog -ErrorAction SilentlyContinue
    $cmd = "& $(Q $core) -Source $(Q $next.Source) -Start $($next.Start.ToString($inv)) -End $($next.End.ToString($inv)) -Height $($script:cfg.Height) -MaxFrames $($script:cfg.MaxFrames) -OutRoot $(Q $script:cfg.OutRoot)"
    $script:job = @{ Q = $next; Proc = (Start-Hidden $cmd $jobLog) }
    $log.Text = ''
}

$queueTimer = New-Object System.Windows.Forms.Timer; $queueTimer.Interval = 600
$queueTimer.Add_Tick({
    if (-not $script:job) { Start-Next; if (-not $script:job) { $queueTimer.Stop() }; return }
    $j = $script:job; $lines = Read-Log $jobLog
    if ($lines.Count) {
        $log.Text = ($lines -join "`r`n"); $log.SelectionStart = $log.TextLength; $log.ScrollToCaret()
        $stepLine = $lines | Where-Object { $_ -like 'STEP:*' } | Select-Object -Last 1
        if ($stepLine) { $st = $stepLine.Substring(5).Trim(); $j.Q.Item.SubItems[1].Text = $st; Say "$($j.Q.Title): $st" }
    }
    if (-not $j.Proc.HasExited) { return }
    $outLine = $lines | Where-Object { $_ -like 'OUTDIR:*' } | Select-Object -Last 1
    if ($outLine) {
        $dir = $outLine.Substring(7).Trim()
        $j.Q.Status = 'Done'; $j.Q.OutDir = $dir; $j.Q.Item.SubItems[1].Text = 'Done'; $j.Q.Item.ForeColor = $honey
        $m = Read-Meta $dir; if ($j.Q.Recreate) { $m.recreate = $true }; Write-Meta $dir $m
        Write-ClaudeNote $dir
        Load-Library
        Say "Done: $($j.Q.Title). Select it in Library and click Send to Claude." $honey
    }
    else {
        $err = $lines | Where-Object { $_ -match 'ERROR|Couldn''t|not found|failed|Exception' } | Select-Object -First 1
        if (-not $err) { $err = 'Something went wrong - see the log.' }
        $j.Q.Status = 'Failed'; $j.Q.Item.SubItems[1].Text = 'Failed'; $j.Q.Item.ForeColor = $red
        Say "Failed: $err" $red
    }
    $script:job = $null
    Start-Next
    if (-not $script:job) { $queueTimer.Stop() }
})

$queueList.Add_SelectedIndexChanged({
    if ($queueList.SelectedItems.Count -eq 0) { return }
    $q = $queueList.SelectedItems[0].Tag; $r = $q.Result
    if ($q.OutDir -and (Test-Path "$($q.OutDir)\thumb.jpg")) { $img = Load-Image "$($q.OutDir)\thumb.jpg" }
    elseif ($r.Local) { $img = Frame-Grab $r.Url }
    else { $img = Web-Image (Thumb-Url $r $true) }
    $file = $null; if ($r.Local) { $file = $r.Url }
    Show-Preview $img $q.Title "$($q.Status)  |  $($r.From)" @{ Kind = 'queue'; Link = $q.Source; File = $file; Dir = $q.OutDir }
})
$btnRemove.Add_Click({
    if ($queueList.SelectedItems.Count -eq 0) { return }
    $q = $queueList.SelectedItems[0].Tag
    if ($q.Status -eq 'Working') { Say 'That one is running - wait for it to finish.' $red; return }
    $script:queue.Remove($q); $queueList.Items.Remove($queueList.SelectedItems[0])
})
$btnClearDone.Add_Click({
    foreach ($q in @($script:queue | Where-Object { $_.Status -eq 'Done' -or $_.Status -eq 'Failed' })) { $script:queue.Remove($q); $queueList.Items.Remove($q.Item) }
})

# ---------------- Library ----------------
function Read-Meta($dir) {
    $m = [pscustomobject]@{ notes = ''; tags = ''; recreate = $false }
    $f = Join-Path $dir 'meta.json'
    if (Test-Path $f) { try { $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j.notes) { $m.notes = "$($j.notes)" }; if ($j.tags) { $m.tags = "$($j.tags)" }; if ($j.recreate) { $m.recreate = [bool]$j.recreate } } catch {} }
    return $m
}
function Write-Meta($dir, $m) { $m | ConvertTo-Json | Set-Content (Join-Path $dir 'meta.json') -Encoding UTF8 }
function Read-Info($dir) {
    $i = @{ Title = (Split-Path $dir -Leaf); Channel = ''; Duration = ''; Url = ''; Range = ''; Chapters = @() }
    $f = Join-Path $dir 'info.txt'
    if (Test-Path $f) {
        $inCh = $false
        foreach ($l in (Get-Content $f -Encoding UTF8)) {
            if ($l -match '^Title:\s+(.*)$') { $i.Title = $matches[1] }
            elseif ($l -match '^Channel:\s+(.*)$') { $i.Channel = $matches[1] }
            elseif ($l -match '^Duration:\s+(.*)$') { $i.Duration = $matches[1] }
            elseif ($l -match '^URL:\s+(.*)$') { $i.Url = $matches[1] }
            elseif ($l -match '^Range:\s+(.*)$') { $i.Range = $matches[1] }
            elseif ($l -eq 'Chapters:') { $inCh = $true }
            elseif ($inCh -and $l -match '^\s{2}\S') { $i.Chapters += $l.Trim() }
            elseif ($inCh) { $inCh = $false }
        }
    }
    return $i
}
function Write-ClaudeNote($dir) {
    $i = Read-Info $dir; $m = Read-Meta $dir
    $sheets = @(Get-ChildItem $dir -Filter 'sheet_*.jpg' | Sort-Object Name)
    $md = @("# $($i.Title)", '', "- Link: $($i.Url)", "- Channel: $($i.Channel)", "- Length: $($i.Duration)")
    if ($i.Range) { $md += "- Only this part: $($i.Range)" }
    $md += ''; $md += '## What I want'
    if ($m.recreate) { $md += '- **Recreate this in Blender.** Watch it, then give me a step-by-step build plan (or build it in my Blender).' }
    else { $md += '- Watch it and tell me what it covers.' }
    if ($m.notes) { $md += "- Notes: $($m.notes)" }
    if ($m.tags) { $md += "- Tags: $($m.tags)" }
    $md += ''; $md += '## Files in this folder'
    $md += '- transcript.txt - what is said, in 30-second blocks'
    $md += ('- sheet_01.jpg to sheet_{0:D2}.jpg - {0} frame sheets, 8 frames each, timestamp on every frame' -f $sheets.Count)
    $md += '- frames.txt - the timestamp of every frame on every sheet'
    $md += '- info.txt - title, description and chapters'
    if ($i.Chapters.Count) { $md += ''; $md += '## Chapters'; foreach ($c in $i.Chapters) { $md += "- $c" } }
    $md | Set-Content (Join-Path $dir 'claude.md') -Encoding UTF8
}
function Lib-Thumb($dir, $url) {
    $img = Load-Image (Join-Path $dir 'thumb.jpg')
    if (-not $img -and $url -match '(?:v=|youtu\.be/|shorts/)([A-Za-z0-9_-]{11})') {
        $img = Web-Image "https://i.ytimg.com/vi/$($matches[1])/hqdefault.jpg"
        if ($img) { try { $img.Save((Join-Path $dir 'thumb.jpg'), [System.Drawing.Imaging.ImageFormat]::Jpeg) } catch {} }
    }
    if (-not $img) { $img = Load-Image (Join-Path $dir 'sheet_01.jpg') }
    return $img
}
function Load-Library {
    $libList.BeginUpdate(); $libList.Items.Clear(); $libList.SmallImageList.Images.Clear()
    $root = $script:cfg.OutRoot; $total = 0
    if (Test-Path $root) {
        $filter = $libSearch.Text.Trim()
        foreach ($d in (Get-ChildItem $root -Directory | Where-Object { $_.Name -ne '_pending' } | Sort-Object LastWriteTime -Descending)) {
            $i = Read-Info $d.FullName; $m = Read-Meta $d.FullName
            $size = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if ($size) { $total += $size }
            if ($filter -and -not ("$($i.Title) $($i.Channel) $($m.tags) $($m.notes)" -like "*$filter*")) { continue }
            $key = $d.Name
            $libList.SmallImageList.Images.Add($key, (Fit-Thumb (Lib-Thumb $d.FullName $i.Url)))
            $it = New-Object System.Windows.Forms.ListViewItem($i.Title, $key)
            [void]$it.SubItems.Add($i.Channel); [void]$it.SubItems.Add($i.Duration)
            [void]$it.SubItems.Add($m.tags); [void]$it.SubItems.Add($d.LastWriteTime.ToString('MMM d'))
            if ($m.recreate) { $it.ForeColor = $honey }
            $it.Tag = $d.FullName
            [void]$libList.Items.Add($it)
        }
    }
    $libList.EndUpdate()
    $lblSpace.Text = ('{0} videos  |  {1:N0} MB used  |  gold = Recreate in Blender' -f $libList.Items.Count, ($total / 1MB))
}
$libSearch.Add_TextChanged({ Load-Library })
$btnRefresh.Add_Click({ Load-Library })
$libList.Add_SelectedIndexChanged({
    if ($libList.SelectedItems.Count -eq 0) { return }
    $dir = $libList.SelectedItems[0].Tag; $i = Read-Info $dir; $m = Read-Meta $dir
    $vid = Get-ChildItem $dir -File | Where-Object { $videoExt -contains $_.Extension.ToLower() } | Select-Object -First 1
    $isLocal = ($i.Url -and (Test-Path -LiteralPath $i.Url -PathType Leaf))
    $file = $null; if ($vid) { $file = $vid.FullName } elseif ($isLocal) { $file = $i.Url }
    $meta = (@($i.Channel, $i.Duration, $i.Range) | Where-Object { $_ }) -join '  |  '
    if (-not $file) { $meta += '  |  video file removed' }
    Show-Preview (Lib-Thumb $dir $i.Url) $i.Title $meta @{ Kind = 'lib'; Link = $i.Url; File = $file; Dir = $dir }
    $txtTags.Text = $m.tags; $txtNotes.Text = $m.notes; $chkLibRecreate.Checked = $m.recreate
})
$libList.Add_DoubleClick({ if ($script:sel -and $script:sel.Dir) { Start-Process explorer.exe $script:sel.Dir } })

function Save-LibMeta {
    if (-not $script:sel -or $script:sel.Kind -ne 'lib') { return $false }
    $m = Read-Meta $script:sel.Dir
    $m.tags = $txtTags.Text.Trim(); $m.notes = $txtNotes.Text.Trim(); $m.recreate = $chkLibRecreate.Checked
    Write-Meta $script:sel.Dir $m; Write-ClaudeNote $script:sel.Dir
    return $true
}
$btnSave.Add_Click({ if (Save-LibMeta) { Load-Library; Say 'Saved.' $honey } })
$btnSend.Add_Click({
    if (-not (Save-LibMeta)) { return }
    [System.Windows.Forms.Clipboard]::SetText("it's done - read $($script:sel.Dir)\claude.md")
    Say 'Copied! Paste it into your chat with Claude.' $honey
})
$btnSpace.Add_Click({
    if (-not $script:sel -or $script:sel.Kind -ne 'lib') { return }
    $big = @(Get-ChildItem $script:sel.Dir -File | Where-Object { ($videoExt -contains $_.Extension.ToLower()) -or $_.Name -eq 'video.info.json' -or $_.Name -eq 'captions.vtt' })
    if ($big.Count -eq 0) { Say 'Nothing big left to remove here.'; return }
    $mb = ($big | Measure-Object Length -Sum).Sum / 1MB
    $ok = [System.Windows.Forms.MessageBox]::Show(('Delete the video file ({0:N0} MB)? The transcript and frame sheets stay.' -f $mb), 'Save space', 'YesNo', 'Question')
    if ($ok -eq 'Yes') { $big | Remove-Item -Force; Load-Library; Say ('Freed {0:N0} MB.' -f $mb) $honey }
})
$btnDelete.Add_Click({
    if (-not $script:sel -or $script:sel.Kind -ne 'lib') { return }
    $ok = [System.Windows.Forms.MessageBox]::Show("Delete everything saved for:`n$($pvTitle.Text)?", 'Delete', 'YesNo', 'Warning')
    if ($ok -eq 'Yes') {
        Remove-Item -Recurse -Force $script:sel.Dir
        $script:sel = $null; $pic.Image = $null; $pvTitle.Text = 'Preview'; $pvMeta.Text = ''; $lib.Visible = $false
        Load-Library
    }
})

# ---------------- Preview buttons ----------------
$btnOpenLink.Add_Click({ if ($script:sel -and $script:sel.Link) { Start-Process $script:sel.Link } })
$btnPlay.Add_Click({
    if (-not $script:sel) { return }
    if ($script:sel.File -and (Test-Path -LiteralPath $script:sel.File)) { Start-Process $script:sel.File }
    elseif ($script:sel.Link) { Start-Process $script:sel.Link }
})
$btnFolder.Add_Click({ if ($script:sel -and $script:sel.Dir) { Start-Process explorer.exe $script:sel.Dir } })

# ---------------- Update tools ----------------
$btnUpdate.Add_Click({
    Refresh-Path
    $verb = 'install'; if (Get-Command yt-dlp -ErrorAction SilentlyContinue) { $verb = 'upgrade' }
    Say 'Updating yt-dlp and FFmpeg... (a window shows progress)'; $form.Refresh()
    Start-Process winget -ArgumentList "$verb --id yt-dlp.yt-dlp --exact --source winget --accept-package-agreements --accept-source-agreements" -Wait
    Refresh-Path
    $v = ''; try { $v = (& yt-dlp --version) } catch {}
    if ($v) { Say "Tools ready. yt-dlp version $v." $honey } else { Say 'Update finished, but yt-dlp is still not found. Restart the app.' $red }
})

# ---------------- Settings ----------------
function Find-Python {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1 }
    return $py
}
function Has-Whisper {
    $py = Find-Python
    if (-not $py) { return 'nopython' }
    & $py.Source -c "import faster_whisper" 2>$null
    if ($LASTEXITCODE -eq 0) { return 'yes' } else { return 'no' }
}
$btnSettings.Add_Click({
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Settings'; $d.Size = S 560 360; $d.StartPosition = 'CenterParent'; $d.BackColor = $bg; $d.ForeColor = $text; $d.Font = $font
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.Controls.Add((New-Lbl 'Most frames per video' 20 22 $text))
    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Location = P 240 20; $num.Size = S 80 24; $num.Minimum = 16; $num.Maximum = 240; $num.Increment = 8; $num.Value = $script:cfg.MaxFrames
    $d.Controls.Add($num); $d.Controls.Add((New-Lbl '(8 per sheet)' 330 22 $muted))
    $d.Controls.Add((New-Lbl 'Video download quality' 20 62 $text))
    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.Location = P 240 58; $cmb.Size = S 100 24; $cmb.DropDownStyle = 'DropDownList'
    foreach ($h in 360, 480, 720, 1080) { [void]$cmb.Items.Add("${h}p") }
    $cmb.SelectedItem = "$($script:cfg.Height)p"; if ($cmb.SelectedIndex -lt 0) { $cmb.SelectedIndex = 1 }
    $d.Controls.Add($cmb)
    $d.Controls.Add((New-Lbl 'Save videos in' 20 102 $text))
    $txtOut = New-Box 20 124 410 24; $txtOut.Text = $script:cfg.OutRoot; $d.Controls.Add($txtOut)
    $btnBrowse = New-Btn 'Browse...' 438 120 90 $false; $d.Controls.Add($btnBrowse)
    $btnBrowse.Add_Click({ $fb = New-Object System.Windows.Forms.FolderBrowserDialog; $fb.SelectedPath = $txtOut.Text; if ($fb.ShowDialog() -eq 'OK') { $txtOut.Text = $fb.SelectedPath } })

    $d.Controls.Add((New-Lbl 'Speech-to-text (for videos with no captions)' 20 168 $text))
    $w = Has-Whisper
    $wTxt = 'Not installed (needs Python too).'; if ($w -eq 'yes') { $wTxt = 'Installed.' } elseif ($w -eq 'no') { $wTxt = 'Not installed.' }
    $lblW = New-Lbl $wTxt 20 192 $muted; $d.Controls.Add($lblW)
    $btnW = New-Btn 'Install speech-to-text' 300 186 228 $false; $btnW.Enabled = ($w -ne 'yes'); $d.Controls.Add($btnW)
    $btnW.Add_Click({
        if ((Has-Whisper) -eq 'nopython') {
            $lblW.Text = 'Installing Python (a window shows progress)...'; $d.Refresh()
            Start-Process winget -ArgumentList 'install --id Python.Python.3.12 --exact --source winget --accept-package-agreements --accept-source-agreements' -Wait
            Refresh-Path
        }
        $py = Find-Python
        if (-not $py) { $lblW.Text = 'Python installed - restart the app, then click Install again.'; return }
        $lblW.Text = 'Installing speech-to-text (a window shows progress)...'; $d.Refresh()
        Start-Process $py.Source -ArgumentList '-m pip install --upgrade faster-whisper' -Wait
        if ((Has-Whisper) -eq 'yes') { $lblW.Text = 'Installed. The first transcription downloads a small model.'; $btnW.Enabled = $false } else { $lblW.Text = 'Install did not finish. Try again.' }
    })

    $ok = New-Btn 'Save' 318 270 100 $true; $d.Controls.Add($ok)
    $cancel = New-Btn 'Cancel' 428 270 100 $false; $d.Controls.Add($cancel)
    $ok.Add_Click({
        $script:cfg.MaxFrames = [int]$num.Value
        $script:cfg.Height = [int]("$($cmb.SelectedItem)" -replace 'p', '')
        if ($txtOut.Text.Trim()) { $script:cfg.OutRoot = $txtOut.Text.Trim() }
        Save-Settings; Load-Library; $d.Close(); Say 'Settings saved.' $honey
    })
    $cancel.Add_Click({ $d.Close() })
    [void]$d.ShowDialog($form)
})

# ---------------- Start ----------------
$form.Add_Shown({
    Load-Library
    try {
        $clip = [System.Windows.Forms.Clipboard]::GetText().Trim()
        if ($clip -match '^https?://\S+$' -and $clip.Length -lt 500) { $txtIn.Text = $clip; Say 'Pasted the link from your clipboard. Click Find.' $honey }
    } catch {}
    if (-not (Test-Path $core)) { Say 'watch-core.ps1 is missing from this folder.' $red }
    $txtIn.Focus()
})
$form.Add_FormClosing({
    if ($script:job -and -not $script:job.Proc.HasExited) {
        $a = [System.Windows.Forms.MessageBox]::Show('A video is still being processed. Quit anyway?', 'Watch Video', 'YesNo', 'Question')
        if ($a -ne 'Yes') { $_.Cancel = $true } else { try { $script:job.Proc.Kill() } catch {} }
    }
})
[void]$form.ShowDialog()
