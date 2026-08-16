@echo off
rem SPDX-License-Identifier: Apache-2.0
rem Windows counterpart of the extensionless `initialize` POSIX script — see
rem devcontainer.json's initializeCommand comment. No -p flag needed:
rem Windows' mkdir already creates the full nested path in one call.
if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
if not exist "%USERPROFILE%\.kube-compute" mkdir "%USERPROFILE%\.kube-compute"
if not exist "%USERPROFILE%\.aws" mkdir "%USERPROFILE%\.aws"
