# watch-core.ps1 - does the actual work for the Watch Video app.
# Turns a video (link or local file) into: info.txt, transcript.txt, timestamped frame sheets, frames.txt.
# Prints "STEP: ..." lines for progress and "OUTDIR: <folder>" when done.
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [double]$Start = 0,
    [double]$End = 0,
    [int]$Height = 480,
    [int]$MaxFrames = 96,
    [string]$OutRoot = ''
)

$ErrorActionPreference = 'Continue'   # native tools write to stderr; failures are checked explicitly
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$env:PYTHONIOENCODING = 'utf-8'
Add-Type -AssemblyName System.Drawing

$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $OutRoot) { $OutRoot = Join-Path $here 'watch-output' }
New-Item -ItemType Directory -Force $OutRoot | Out-Null

function Step($msg) { Write-Host "STEP: $msg" }
function Fmt([double]$s) {
    $t = [timespan]::FromSeconds([math]::Floor($s))
    if ($t.TotalHours -ge 1) { return $t.ToString('h\:mm\:ss') } else { return $t.ToString('m\:ss') }
}
function Safe([string]$s) { ($s -replace '[^A-Za-z0-9_-]', '_').Trim('_') }
function Need($tool) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found. Use 'Update tools' in the app to install it." }
}
function Run-Native($exe, $argLine, $errFile) {
    # Runs a program hidden, waits, returns exit code. stderr goes to $errFile.
    $p = Start-Process -FilePath $exe -ArgumentList $argLine -NoNewWindow -Wait -PassThru -RedirectStandardError $errFile -RedirectStandardOutput "$errFile.out"
    return $p.ExitCode
}

Need 'ffmpeg'; Need 'ffprobe'
$isFile = Test-Path -LiteralPath $Source -PathType Leaf
$tmp = Join-Path $OutRoot '_pending'
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Force $tmp | Out-Null

$title = ''; $channel = ''; $duration = 0; $link = ''; $uploaded = ''; $desc = ''; $chapters = @(); $captionUrl = $null

# ---------- 1. Get the video ----------
if ($isFile) {
    $item = Get-Item -LiteralPath $Source
    Step "Reading local file $($item.Name)"
    $hash = [math]::Abs($item.FullName.ToLower().GetHashCode()).ToString('x')
    $base = Safe $item.BaseName
    if ($base.Length -gt 40) { $base = $base.Substring(0, 40) }
    $id = "file-$base-$hash"
    $title = $item.BaseName; $channel = 'Local file'; $link = $item.FullName
    $uploaded = $item.LastWriteTime.ToString('yyyyMMdd')
    $video = $item.FullName
}
else {
    Need 'yt-dlp'
    Step 'Reading video info'
    & yt-dlp --compat-options no-certifi --no-warnings --no-playlist --skip-download --write-info-json -o "$tmp\video.%(ext)s" $Source 2>&1 | ForEach-Object { if ("$_" -match 'ERROR') { Write-Host "$_" } }
    if (-not (Test-Path "$tmp\video.info.json")) { throw "Couldn't read that video. It may be private, removed, or need a login." }
    $j = Get-Content "$tmp\video.info.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    $id = Safe ("$($j.id)")
    if ($j.extractor_key -and $j.extractor_key -ne 'Youtube') { $id = (Safe $j.extractor_key).ToLower() + '-' + $id }
    $title = "$($j.title)"; if (-not $title) { $title = $id }
    $channel = "$($j.channel)"; if (-not $channel) { $channel = "$($j.uploader)" }
    if ($j.duration) { $duration = [double]$j.duration }
    $link = "$($j.webpage_url)"; $uploaded = "$($j.upload_date)"; $desc = "$($j.description)"
    if ($j.chapters) { $chapters = @($j.chapters) }
    foreach ($k in 'subtitles', 'automatic_captions') {
        foreach ($lang in 'en-orig', 'en', 'en-US', 'en-GB') {
            $tracks = $j.$k.$lang
            if ($tracks -and -not $captionUrl) { $captionUrl = ($tracks | Where-Object { $_.ext -eq 'vtt' } | Select-Object -First 1).url }
        }
    }
}

$out = Join-Path $OutRoot $id
if (Test-Path $out) {
    # Keep notes/tags from an earlier run of the same video.
    $keep = Join-Path $tmp 'meta.keep'
    if (Test-Path "$out\meta.json") { Copy-Item "$out\meta.json" $keep }
    Remove-Item -Recurse -Force $out
}
Move-Item $tmp $out
if (Test-Path "$out\meta.keep") { Move-Item "$out\meta.keep" "$out\meta.json" }

if (-not $isFile) {
    Step 'Downloading video'
    $fmt = "b[height<=$Height]/bv*[height<=$Height]+ba/b"
    & yt-dlp --compat-options no-certifi --no-warnings --no-playlist -f $fmt --merge-output-format mp4 -o "$out\video.%(ext)s" $Source 2>&1 | ForEach-Object { if ("$_" -match 'ERROR') { Write-Host "$_" } }
    $v = Get-ChildItem $out -File | Where-Object { $_.Extension -in '.mp4', '.webm', '.mkv', '.mov' } | Select-Object -First 1
    if (-not $v) { throw 'The video download failed.' }
    $video = $v.FullName
}

if ($duration -le 0) {
    $d = & ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $video
    $duration = [double]::Parse(("$d").Trim(), [Globalization.CultureInfo]::InvariantCulture)
}

# Range (optional)
if ($Start -lt 0) { $Start = 0 }
if ($End -le 0 -or $End -gt $duration) { $End = $duration }
if ($Start -ge $End) { $Start = 0; $End = $duration }
$segLen = $End - $Start
$ranged = ($Start -gt 0 -or $End -lt $duration)

# ---------- 2. info.txt ----------
$info = @(
    "Title:    $title"
    "Channel:  $channel"
    "Duration: $(Fmt $duration)"
    "Uploaded: $uploaded"
    "URL:      $link"
)
if ($ranged) { $info += "Range:    $(Fmt $Start) - $(Fmt $End)" }
if ($chapters.Count -gt 0) {
    $info += ''; $info += 'Chapters:'
    foreach ($c in $chapters) { $info += "  $(Fmt $c.start_time)  $($c.title)" }
}
$info += ''; $info += $desc
$info | Set-Content "$out\info.txt" -Encoding UTF8

# ---------- 3. Frames: regular spacing + scene changes ----------
Step 'Picking frames (scene changes + timeline)'
$fr = Join-Path $out 'frames'
New-Item -ItemType Directory -Force $fr | Out-Null
# Short clips get denser frames. Aim for ~60% of the cap from the timeline; scene changes fill the rest.
$target = [math]::Min([math]::Max(16, [math]::Round($MaxFrames * 0.6)), [math]::Max(8, [math]::Round($segLen * 3)))
$interval = [math]::Max(0.25, $segLen / $target)
$gap = [math]::Max(0.2, $interval / 3)
$inv = [Globalization.CultureInfo]::InvariantCulture
$I = $interval.ToString('0.###', $inv); $G = $gap.ToString('0.###', $inv)
$sel = "select='isnan(prev_selected_t)+gte(t-prev_selected_t\,$I)+gt(scene\,0.3)*gte(t-prev_selected_t\,$G)',showinfo,scale=480:-2"
$seek = ''
if ($ranged) { $seek = "-ss $($Start.ToString('0.###', $inv)) -t $($segLen.ToString('0.###', $inv)) " }
$errLog = Join-Path $env:TEMP 'watch-ffmpeg.log'
$code = Run-Native 'ffmpeg' "-hide_banner -y $seek-i `"$video`" -vf `"$sel`" -fps_mode vfr -q:v 3 `"$fr\f_%05d.jpg`"" $errLog
$times = @()
foreach ($line in (Get-Content $errLog)) {
    if ($line -match 'Parsed_showinfo.*\spts_time:\s*([0-9.]+)') { $times += ([double]::Parse($matches[1], $inv) + $Start) }
}
$files = @(Get-ChildItem $fr -Filter 'f_*.jpg' | Sort-Object Name)
if ($files.Count -eq 0) { throw "Couldn't pull frames from the video (ffmpeg exit $code)." }

# Too many? Keep an even spread.
$keepIdx = 0..($files.Count - 1)
if ($files.Count -gt $MaxFrames) {
    $keepIdx = @(); for ($k = 0; $k -lt $MaxFrames; $k++) { $keepIdx += [math]::Floor($k * $files.Count / $MaxFrames) }
}
$frames = @()
foreach ($k in $keepIdx) {
    $t = if ($k -lt $times.Count) { $times[$k] } else { $Start + $k * $interval }
    $frames += [pscustomobject]@{ Path = $files[$k].FullName; Time = $t }
}

# ---------- 4. Contact sheets with timestamps ----------
Step "Making frame sheets ($($frames.Count) frames)"
$cols = 4; $rows = 2; $per = $cols * $rows
$first = [System.Drawing.Image]::FromFile($frames[0].Path)
$cw = $first.Width; $ch = $first.Height; $first.Dispose()
$labelFont = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$index = @()
$sheetCount = [math]::Ceiling($frames.Count / $per)
for ($s = 0; $s -lt $sheetCount; $s++) {
    $bmp = New-Object System.Drawing.Bitmap ($cw * $cols), ($ch * $rows)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Black)
    $g.TextRenderingHint = 'AntiAlias'
    $stamps = @()
    for ($c = 0; $c -lt $per; $c++) {
        $n = $s * $per + $c
        if ($n -ge $frames.Count) { break }
        $x = ($c % $cols) * $cw; $y = [math]::Floor($c / $cols) * $ch
        $img = [System.Drawing.Image]::FromFile($frames[$n].Path)
        $g.DrawImage($img, $x, $y, $cw, $ch); $img.Dispose()
        $label = Fmt $frames[$n].Time
        $size = $g.MeasureString($label, $labelFont)
        $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(190, 0, 0, 0))), $x + 4, $y + $ch - $size.Height - 6, $size.Width + 6, $size.Height + 2)
        $g.DrawString($label, $labelFont, [System.Drawing.Brushes]::Gold, $x + 7, $y + $ch - $size.Height - 5)
        $stamps += $label
    }
    $g.Dispose()
    $name = 'sheet_{0:D2}.jpg' -f ($s + 1)
    $bmp.Save((Join-Path $out $name), [System.Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
    $index += "$name  (left to right, top row first): $($stamps -join ', ')"
}
$index | Set-Content "$out\frames.txt" -Encoding UTF8
Copy-Item $frames[0].Path "$out\thumb.jpg"
if ($frames.Count -gt 2) { Copy-Item $frames[[math]::Floor($frames.Count / 3)].Path "$out\thumb.jpg" -Force }
Remove-Item -Recurse -Force $fr

# ---------- 5. Transcript ----------
function Bucket-Transcript($pairs) {
    # $pairs: list of @(seconds, text). Groups into 30-second blocks.
    $lines = New-Object System.Collections.Generic.List[string]
    $cur = ''; $curB = -1; $prev = ''
    foreach ($p in $pairs) {
        $text = $p[1].Trim(); if (-not $text -or $text -eq $prev) { continue }; $prev = $text
        $b = [math]::Floor($p[0] / 30)
        if ($b -ne $curB) { if ($cur) { $lines.Add($cur.TrimEnd()) }; $curB = $b; $cur = '[{0}] ' -f [timespan]::FromSeconds($b * 30).ToString('hh\:mm\:ss') }
        $cur += "$text "
    }
    if ($cur) { $lines.Add($cur.TrimEnd()) }
    return $lines
}

$transcribed = $false
if ($captionUrl) {
    Step 'Downloading captions'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing $captionUrl -OutFile "$out\captions.vtt"
        $pairs = New-Object System.Collections.Generic.List[object]; $t = 0
        foreach ($row in Get-Content "$out\captions.vtt" -Encoding UTF8) {
            if ($row -match '^(\d\d):(\d\d):(\d\d)\.\d+ -->') { $t = [int]$matches[1] * 3600 + [int]$matches[2] * 60 + [int]$matches[3] }
            elseif ($row -and $row -notmatch '^(WEBVTT|Kind:|Language:)' -and $row -notmatch '<\d\d:') {
                $txt = ($row -replace '<[^>]+>', '' -replace '&gt;', '>' -replace '&lt;', '<' -replace '&amp;', '&' -replace '&#39;', "'")
                if ($t -ge $Start -and $t -le $End) { $pairs.Add(@($t, $txt)) }
            }
        }
        Bucket-Transcript $pairs | Set-Content "$out\transcript.txt" -Encoding UTF8
        $transcribed = $true
    } catch { Write-Host "Captions failed: $($_.Exception.Message)" }
}

if (-not $transcribed) {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    $script = Join-Path $here 'transcribe.py'
    $hasWhisper = $false
    if ($py -and (Test-Path $script)) {
        & $py.Source -c "import faster_whisper" 2>$null
        $hasWhisper = ($LASTEXITCODE -eq 0)
    }
    if ($hasWhisper) {
        Step 'No captions - transcribing the audio (this can take a while)'
        $wav = Join-Path $env:TEMP 'watch-audio.wav'
        $null = Run-Native 'ffmpeg' "-hide_banner -y $seek-i `"$video`" -vn -ac 1 -ar 16000 `"$wav`"" $errLog
        & $py.Source $script $wav "$out\transcript.txt" ([string]$Start) 2>&1 | ForEach-Object { if ("$_" -match 'Error') { Write-Host "$_" } }
        Remove-Item $wav -ErrorAction SilentlyContinue
        $transcribed = (Test-Path "$out\transcript.txt")
    }
    if (-not $transcribed) {
        'No captions for this video, and speech-to-text is not installed (Settings > Install speech-to-text).' | Set-Content "$out\transcript.txt" -Encoding UTF8
    }
}

Step 'Done'
Write-Host "OUTDIR: $out"
