@echo off
REM Compile and run game1

if not exist "lyxc.exe" (
    echo lyxc.exe not found. Building compiler...
    call build.bat build
)

echo === Compiling game1 ===
lyxc.exe examples\game1\game1.lyx -o examples\game1\game1.exe

if errorlevel 1 (
    echo ERROR: Compilation failed!
    exit /b 1
)

echo === Running game1 ===
examples\game1\game1.exe
