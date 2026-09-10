@echo off
rem ---------------------------------------------------------------------------
rem build\build.bat -- build vtirc-ng on Windows with FreeBASIC 1.10.1 (win32)
rem
rem   build\build.bat [release|debug]
rem
rem   FBC   path to fbc32.exe (default: fbc32.exe on PATH)
rem Output: build\out\win32\vtirc-ng.exe (+ SDL2.dll)
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0.."
if "%FBC%"=="" set FBC=fbc32.exe
set MODE=%1
if "%MODE%"=="" set MODE=release
set FLAGS=-w all -gen gcc -s gui -arch 686
if /i "%MODE%"=="debug" (set FLAGS=%FLAGS% -g -exx) else (set FLAGS=%FLAGS% -O 2)
if not exist build\out\win32 mkdir build\out\win32
"%FBC%" vtirc.bas %FLAGS% -p deps\win32 -x build\out\win32\vtirc-ng.exe
if errorlevel 1 exit /b 1
copy /y deps\win32\SDL2.dll build\out\win32\ >nul
echo built build\out\win32\vtirc-ng.exe
