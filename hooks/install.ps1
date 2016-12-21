#
# Copyright 2016 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module JujuLogging
Import-Module JenkinsSlaveHooks


try {
    Start-InstallHook
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
