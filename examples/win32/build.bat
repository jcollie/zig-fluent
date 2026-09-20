@echo off
REM SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
REM SPDX-License-Identifier: MIT

REM The Win32 example, built the way a Windows C project is built: cl, rc and
REM link. This file is `examples/gtk/Makefile` written for the platform that
REM has no make, and it knows about Zig only in the one step that produces the
REM library -- point PREFIX at an installed copy and that step never runs.
REM
REM     build.bat              build it
REM     build.bat run          and run it
REM     build.bat smoke        drive it without a person, which is what CI does
REM     set PREFIX=C:\opt      against an installed copy instead
REM     set LINKAGE=shared     link fluent.dll rather than fluent.lib
REM
REM It finds the Visual C++ tools itself when they are not already on PATH, so
REM it works from an ordinary command prompt as well as from a developer one.

setlocal enabledelayedexpansion

if not defined PREFIX set "PREFIX=..\..\zig-out"
if not defined LINKAGE set "LINKAGE=static"
REM Forward slashes on purpose: this is a C string literal on a command line,
REM where a backslash would have to survive both cmd and the preprocessor, and
REM every Windows file API takes `/` just as happily.
if not defined LOCALE_DIR set "LOCALE_DIR=../locales"

REM -- the compiler ---------------------------------------------------------

REM `vcvars64.bat` puts the tools on PATH and is what a "Developer Command
REM Prompt" shortcut runs. `vswhere` is how to find it without knowing which
REM edition or year is installed; it ships in a fixed location precisely so
REM that scripts like this one can rely on it.
where cl.exe >nul 2>&1
if errorlevel 1 (
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if not exist "!VSWHERE!" (
        echo Visual C++ was not found, and neither was vswhere.exe.
        echo Run this from a Developer Command Prompt.
        exit /b 1
    )
    for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
    if not defined VSPATH (
        echo Visual C++ was not found. Install the "Desktop development with C++" workload.
        exit /b 1
    )
    call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul
    if errorlevel 1 exit /b 1
)

REM -- the library ----------------------------------------------------------

REM The one Zig step, and the only thing in this file that knows Zig exists.
REM
REM The target is named rather than left native. `cl` is an MSVC-ABI compiler,
REM so the archive it links has to be an MSVC-ABI archive, and what Zig picks
REM for "native" on a Windows host depends on what it finds installed. Naming
REM it means the two cannot disagree quietly.
REM
REM An installed copy is not ours to rebuild, so pointing PREFIX elsewhere
REM takes this out of the script entirely and the example needs no Zig at all.
if "%PREFIX%"=="..\..\zig-out" (
    pushd ..\..
    zig build c --prefix zig-out -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-msvc
    if errorlevel 1 (
        popd
        exit /b 1
    )
    popd
)

REM -- building -------------------------------------------------------------

rc /nologo /fo greeting.res greeting.rc
if errorlevel 1 exit /b 1

REM The two linkages have the same suffix here, which they do not on a Unix,
REM so the static library is installed as `libfluent.lib` and `fluent.lib` is
REM the import library that goes with `fluent.dll`. See the comment in
REM `build.zig` beside the install step.
if /i "%LINKAGE%"=="shared" (
    set "FLUENT_LIB=%PREFIX%\lib\fluent.lib"
    REM There is no rpath on Windows, so the DLL is copied next to the
    REM executable rather than found by telling the loader where to look.
    copy /y "%PREFIX%\bin\fluent.dll" . >nul
    if errorlevel 1 (
        echo Could not find "%PREFIX%\bin\fluent.dll".
        exit /b 1
    )
) else (
    set "FLUENT_LIB=%PREFIX%\lib\libfluent.lib"
)

REM `/MD` rather than cl's default `/MT`: Zig links the DLL form of the
REM universal CRT, and mixing the two puts two copies of it in one program,
REM which the linker reports as a pile of duplicate symbols.
REM
REM `/utf-8` because this file's sources contain no non-ASCII but the messages
REM they format do, and because it is what makes the source and execution
REM character sets agree rather than depending on the machine's code page.
cl /nologo /W4 /WX /std:c11 /utf-8 /O2 /MD ^
   /I "%PREFIX%\include" /I ..\common /DLOCALE_DIR=\"%LOCALE_DIR%\" ^
   greeting.c ..\common\catalog.c ^
   /Fe:greeting.exe ^
   /link /SUBSYSTEM:WINDOWS greeting.res "%FLUENT_LIB%" ^
   kernel32.lib user32.lib gdi32.lib comctl32.lib advapi32.lib ntdll.lib
if errorlevel 1 exit /b 1

REM -- running --------------------------------------------------------------

REM `start /wait /b` because this is a windowed program: cmd does not wait for
REM one, so a plain `greeting.exe` here would return before it had done
REM anything and its exit status would be nobody's. `/b` keeps it attached to
REM this console, which is what lets `--smoke` print into it.
if /i "%~1"=="run" (
    start /wait /b "" greeting.exe %2 %3
    exit /b %errorlevel%
)
if /i "%~1"=="smoke" (
    start /wait /b "" greeting.exe --smoke
    exit /b %errorlevel%
)

exit /b 0
