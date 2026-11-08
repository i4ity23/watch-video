@echo off
rem Optional: turns the app into a real "Watch Video.exe" with its own icon (run once, needs internet).
cd /d "%~dp0"
echo Building Watch Video.exe ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "if (-not (Get-Module -ListAvailable ps2exe)) { Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null; Set-PSRepository PSGallery -InstallationPolicy Trusted; Install-Module ps2exe -Scope CurrentUser -Force };" ^
  "Import-Module ps2exe;" ^
  "Invoke-ps2exe -inputFile '.\watch-app.ps1' -outputFile '.\Watch Video.exe' -iconFile '.\watch.ico' -noConsole -STA -title 'Watch Video' -product 'Watch Video' -description 'Watch videos with Claude'"
if exist "Watch Video.exe" (
  echo.
  echo Built! Updating your desktop shortcut to use it...
  call "%~dp0install-app.cmd"
) else (
  echo.
  echo The build did not finish. You can keep using the app as it is.
  pause
)
