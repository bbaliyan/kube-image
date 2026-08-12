@echo off
rem SPDX-License-Identifier: Apache-2.0
rem Windows counterpart of the extensionless `initialize` POSIX script — see
rem devcontainer.json's initializeCommand comment for why both exist. VS
rem Code's array-form initializeCommand ([".devcontainer/initialize"], no
rem shell involved) resolves the bare name "initialize" per the host OS's
rem own executable-resolution rules: Unix runs the extensionless script
rem directly, Windows finds and runs this .cmd file instead. No -p flag
rem needed — Windows' mkdir already creates the full nested path in one call,
rem unlike POSIX mkdir; passing "-p" here would be treated as a literal
rem (bogus) directory name, which is exactly what broke the old
rem shell-string initializeCommand under cmd.exe.
if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
if not exist "%USERPROFILE%\.kube-compute" mkdir "%USERPROFILE%\.kube-compute"
if not exist "%USERPROFILE%\.aws" mkdir "%USERPROFILE%\.aws"
