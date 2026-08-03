; OST Tracker NSIS installer (invoked from build.ps1)
; makensis /DARCH=x64 /DOUT=out\app-x64 /DVERSION=0.1.0 installer.nsi

!ifndef VERSION
!define VERSION "0.1.0"
!endif
!ifndef ARCH
!define ARCH "x64"
!endif
!ifndef OUT
!define OUT "out\app-x64"
!endif

Name "OST Tracker"
OutFile "OSTTracker-${ARCH}-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\OstTracker"
RequestExecutionLevel user
Unicode true

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "Install"
  SetOutPath "$INSTDIR"
  File /r "${OUT}\*.*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\OST Tracker.lnk" "$INSTDIR\OSTTracker.exe"
  CreateShortcut "$SMPROGRAMS\OST Tracker.lnk" "$INSTDIR\OSTTracker.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OstTracker" "DisplayName" "OST Tracker"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OstTracker" "UninstallString" "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir /r "$INSTDIR"
  Delete "$DESKTOP\OST Tracker.lnk"
  Delete "$SMPROGRAMS\OST Tracker.lnk"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OstTracker"
SectionEnd
