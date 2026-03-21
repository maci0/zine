@echo off
rem Loader script to setup MSVC 6.0 environment

set MSVC_ROOT=%~dp0..\tools\MSVC600
call "%MSVC_ROOT%\VC98\Bin\VCVARS32.BAT"

rem Execute the passed command
%*
