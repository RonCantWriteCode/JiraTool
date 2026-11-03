@echo off
chcp 65001 >nul
if exist "c:\Users\majianwei\Desktop\JiraWinTool_publish\JiraWinTool.exe" (
    echo EXE_EXISTS
    for %%F in ("c:\Users\majianwei\Desktop\JiraWinTool_publish\JiraWinTool.exe") do echo SIZE=%%~zF
    copy /Y "c:\Users\majianwei\Desktop\JiraWinTool_publish\JiraWinTool.exe" "%~dp0JiraWinTool.exe"
    if %errorlevel% equ 0 (echo COPY_SUCCESS) else (echo COPY_FAILED)
) else (
    echo EXE_NOT_FOUND
    dir "c:\Users\majianwei\Desktop\JiraWinTool_publish\"
)
