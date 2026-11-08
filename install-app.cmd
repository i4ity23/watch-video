@echo off
rem Watch Video installer: installs the tools it needs (first time only) and puts the app on your desktop.
cd /d "%~dp0"
echo Watch Video setup
echo.
powershell -NoProfile -Command "$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User'); if (Get-Command yt-dlp -EA 0) {exit 0} else {exit 1}"
if errorlevel 1 (
  echo Installing yt-dlp, FFmpeg and Deno with winget. This only happens once...
  winget install --id yt-dlp.yt-dlp --exact --source winget --accept-package-agreements --accept-source-agreements
  echo.
) else (
  echo yt-dlp and FFmpeg are already installed.
)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-ChildItem -LiteralPath (Get-Location).Path -File | Unblock-File;" ^
  "$dir = (Get-Location).Path;" ^
  "$desk = [Environment]::GetFolderPath('Desktop');" ^
  "$s = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $desk 'Watch Video.lnk'));" ^
  "$exe = Join-Path $dir 'Watch Video.exe';" ^
  "if (Test-Path $exe) { $s.TargetPath = $exe; $s.Arguments = '' } else { $s.TargetPath = $env:SystemRoot + '\System32\WindowsPowerShell\v1.0\powershell.exe'; $s.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + [char]34 + (Join-Path $dir 'watch-app.ps1') + [char]34 };" ^
  "$s.WorkingDirectory = $dir;" ^
  "$s.IconLocation = (Join-Path $dir 'watch.ico') + ',0';" ^
  "$s.Description = 'Watch videos with Claude';" ^
  "$s.Save();" ^
  "Write-Host 'Done! Open Watch Video from your desktop.'"
echo.
pause
