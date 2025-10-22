@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem =============================
rem Parameters
rem =============================
set "SFTP_HOST=%~1"
set "SFTP_USER=%~2"
set "PRIVATE_KEY_PATH=%~3"
set "FULL_FILE_PATH=%~4"  rem e.g. /SFTP/XML_FILES/.../FILE.txt
set "DESTINATION_PATH=%~5" rem e.g. /opt/IBM/MDM/.../
set "MAX_WAIT_MINUTES=%~6"
if "%MAX_WAIT_MINUTES%"=="" set "MAX_WAIT_MINUTES=30"

rem =============================
rem Validate input
rem =============================
if "%SFTP_HOST%"=="" (
    echo ERROR: SFTP host not provided.
    exit /b 1
)
if "%SFTP_USER%"=="" (
    echo ERROR: SFTP username not provided.
    exit /b 1
)
if "%PRIVATE_KEY_PATH%"=="" (
    echo ERROR: Private key path not provided.
    exit /b 1
)
if not exist "%PRIVATE_KEY_PATH%" (
    echo ERROR: Private key file "%PRIVATE_KEY_PATH%" does not exist.
    exit /b 1
)
if "%FULL_FILE_PATH%"=="" (
    echo ERROR: Input file path not provided.
    exit /b 1
)
if "%DESTINATION_PATH%"=="" (
    echo ERROR: Destination path not provided.
    exit /b 1
)

where winscp.com >nul 2>&1
if errorlevel 1 (
    echo ERROR: WinSCP (winscp.com) not found in PATH.
    exit /b 1
)

rem =============================
rem Preflight: verify SFTP connection works once
rem =============================
> winscp_preflight.txt echo option batch abort
>> winscp_preflight.txt echo option confirm off
>> winscp_preflight.txt echo open sftp://%SFTP_USER%@%SFTP_HOST% -privatekey="%PRIVATE_KEY_PATH%"
>> winscp_preflight.txt echo pwd
>> winscp_preflight.txt echo exit

winscp.com /script=winscp_preflight.txt > winscp_preflight_output.txt 2>&1
if errorlevel 1 (
    echo ERROR: Unable to connect to SFTP or authenticate. See winscp_preflight_output.txt for details.
    exit /b 1
)

rem =============================
rem Derive FILE_NAME from Unix-like path reliably
rem =============================
set "FULL_FILE_PATH_WIN=%FULL_FILE_PATH:/=\%"
for %%F in ("!FULL_FILE_PATH_WIN!") do set "FILE_NAME=%%~nxf"

rem =============================
rem Timing setup
rem =============================
set /a MAX_WAIT_SECONDS=%MAX_WAIT_MINUTES%*60
set /a WAIT_INTERVAL=5
set /a ELAPSED_TIME=0
set "CHECK_FATAL=0"

echo ========================================
echo File Monitoring Script
echo ========================================
echo SFTP Host: %SFTP_HOST%
echo User: %SFTP_USER%
echo File Name: %FILE_NAME%
echo Input Path: %FULL_FILE_PATH%
echo Monitoring Path: %DESTINATION_PATH%/%FILE_NAME%
echo Max Wait Time: %MAX_WAIT_MINUTES% minutes
echo ========================================
echo.
echo Started monitoring at %date% %time%
echo.

:CHECK_LOOP

if !ELAPSED_TIME! GEQ %MAX_WAIT_SECONDS% (
    echo.
    echo ========================================
    echo FAILURE: Maximum wait time exceeded
    echo ========================================
    echo File: %FILE_NAME%
    echo Still present at: %FULL_FILE_PATH% or %DESTINATION_PATH%/%FILE_NAME%
    echo Waited: %MAX_WAIT_MINUTES% minutes
    echo ========================================
    del /q winscp_*.txt 2>nul
    exit /b 1
)

call :CheckExists "%FULL_FILE_PATH%" INPUT_EXISTS
call :CheckExists "%DESTINATION_PATH%/%FILE_NAME%" DEST_EXISTS

if "!CHECK_FATAL!"=="1" (
    echo.
    echo ========================================
    echo ERROR: Fatal SFTP error during file checks
    echo ========================================
    if defined CHECK_FATAL_MSG echo !CHECK_FATAL_MSG!
    echo See latest WinSCP output: winscp_output.txt
    echo ========================================
    del /q winscp_*.txt 2>nul
    exit /b 2
)

set /a REMAINING_SECONDS=%MAX_WAIT_SECONDS%-!ELAPSED_TIME!
set /a REMAINING_MINUTES=%REMAINING_SECONDS%/60

echo [%time%] Elapsed: !ELAPSED_TIME!s - Remaining: !REMAINING_MINUTES! min - Input Status: !INPUT_EXISTS! (0=Present, 1=Absent) - Dest Status: !DEST_EXISTS! (0=Present, 1=Absent)

if not "!INPUT_EXISTS!"=="0" if not "!DEST_EXISTS!"=="0" (
    rem Double-check connectivity to avoid false success due to transient errors
    call :CheckConnectivity CONNECT_OK
    if not "!CONNECT_OK!"=="0" (
        echo [%time%] Connectivity check failed; will retry before declaring success.
        goto AFTER_STATUS
    )
    echo.
    echo ========================================
    echo SUCCESS: File processed and removed!
    echo ========================================
    echo File: %FILE_NAME%
    echo Not found at: %FULL_FILE_PATH%
    echo Not found at: %DESTINATION_PATH%/%FILE_NAME%
    echo Time taken: !ELAPSED_TIME! seconds
    echo Completed at: %date% %time%
    echo ========================================
    del /q winscp_*.txt 2>nul
    exit /b 0
)

if "!INPUT_EXISTS!"=="0" (
    echo [%time%] File still in input path: %FULL_FILE_PATH%
)

if "!DEST_EXISTS!"=="0" (
    echo [%time%] File still in destination path: %DESTINATION_PATH%/%FILE_NAME%
)

:AFTER_STATUS
timeout /t %WAIT_INTERVAL% /nobreak >nul
set /a ELAPSED_TIME+=%WAIT_INTERVAL%
goto CHECK_LOOP

rem =============================
rem Subroutine: CheckExists
rem   %1 = remote path (quoted)
rem   %2 = out var name (0 if present, 1 if absent)
rem =============================
:CheckExists
> winscp_stat.txt echo option batch abort
>> winscp_stat.txt echo option confirm off
>> winscp_stat.txt echo open sftp://%SFTP_USER%@%SFTP_HOST% -privatekey="%PRIVATE_KEY_PATH%"
>> winscp_stat.txt echo stat "%~1"
>> winscp_stat.txt echo exit

winscp.com /script=winscp_stat.txt > winscp_output.txt 2>&1
if errorlevel 1 (
    rem Distinguish missing file vs. fatal errors
    findstr /i /c:"Permission denied" /c:"Authentication failed" /c:"Network error" /c:"Connection failed" /c:"Cannot resolve hostname" /c:"Host key" winscp_output.txt >nul
    if not errorlevel 1 (
        set "CHECK_FATAL=1"
        if defined CHECK_FATAL_MSG (
            set "CHECK_FATAL_MSG=!CHECK_FATAL_MSG! ^| Fatal while checking: %~1"
        ) else (
            set "CHECK_FATAL_MSG=Fatal while checking: %~1"
        )
    )
    set "%~2=1"
) else (
    set "%~2=0"
)
exit /b

rem =============================
rem Subroutine: CheckConnectivity
rem   %1 = out var name (0 if OK, 1 if NOT OK)
rem =============================
:CheckConnectivity
> winscp_ping.txt echo option batch abort
>> winscp_ping.txt echo option confirm off
>> winscp_ping.txt echo open sftp://%SFTP_USER%@%SFTP_HOST% -privatekey="%PRIVATE_KEY_PATH%"
>> winscp_ping.txt echo pwd
>> winscp_ping.txt echo exit

winscp.com /script=winscp_ping.txt > winscp_ping_output.txt 2>&1
if errorlevel 1 (set "%~1=1") else (set "%~1=0")
exit /b
