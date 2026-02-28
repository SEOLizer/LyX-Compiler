@echo off
REM Lyx Compiler Build Script (Windows)
REM Kompiliert den Lyx-Compiler und/oder Lyx-Programme

setlocal enabledelayedexpansion

set FPC=C:\FPC\3.2.2\bin\i386-Win32\fpc.exe
set FPCFLAGS=-Mobjfpc -Sh -FUlib/ -Fuutil/ -Fufrontend/ -Fuir/ -Fubackend/ -Fubackend/x86_64/ -Fubackend/elf/ -Fubackend/pe/ -Fubackend/arm64/

REM Build-Typ: release oder debug
set BUILD_TYPE=release

REM Argumente verarbeiten
set "LYX_SOURCE="
set "LYX_OUTPUT="

:parse_args
if "%~1"=="" goto end_args
if /i "%~1"=="build" (
    set ACTION=build
    shift
    goto parse_args
)
if /i "%~1"=="debug" (
    set BUILD_TYPE=debug
    set ACTION=build
    shift
    goto parse_args
)
if /i "%~1"=="-o" (
    set "LYX_OUTPUT=%~2"
    shift
    shift
    goto parse_args
)
if /i "%~1"=="--target" (
    set TARGET=--target=%~2
    shift
    shift
    goto parse_args
)
REM Alle anderen Argumente sind Quelldateien
if "%LYX_SOURCE%"=="" (
    set "LYX_SOURCE=%~1"
) else (
    set "LYX_SOURCE=!LYX_SOURCE! %~1"
)
shift
goto parse_args

:end_args

if not defined ACTION (
    if defined LYX_SOURCE (
        set ACTION=compile
    ) else (
        set ACTION=build
    )
)

if "%ACTION%"=="build" (
    echo === Building Lyx Compiler (%BUILD_TYPE%) ===
    if not exist "lib" mkdir lib
    
    if "%BUILD_TYPE%"=="debug" (
        %FPC% %FPCFLAGS% -g -gl -Ci -Cr -Co -gh lyxc.lpr -olyxc
    ) else (
        %FPC% %FPCFLAGS% -O2 lyxc.lpr -olyxc
    )
    
    if errorlevel 1 (
        echo ERROR: Build failed!
        exit /b 1
    )
    echo === Build successful: lyxc ===
)

if "%ACTION%"=="compile" (
    if not exist "lyxc.exe" (
        echo ERROR: lyxc.exe not found. Run "build.bat build" first.
        exit /b 1
    )
    
    if "%LYX_OUTPUT%"=="" (
        echo ERROR: Output file required. Use -o output
        exit /b 1
    )
    
    echo === Compiling %LYX_SOURCE% ===
    lyxc.exe %LYX_SOURCE% -o %LYX_OUTPUT% %TARGET%
    
    if errorlevel 1 (
        echo ERROR: Compilation failed!
        exit /b 1
    )
    echo === Compiled: %LYX_OUTPUT% ===
)

exit /b 0
