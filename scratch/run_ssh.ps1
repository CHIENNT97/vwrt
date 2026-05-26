param (
    [string]$Command
)
$askpass = New-Item -Path $env:TEMP\askpass.bat -Value '@echo admin' -Force
$env:SSH_ASKPASS = $askpass.FullName
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'dummy:0'
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL root@192.168.88.1 $Command
Remove-Item $askpass.FullName -Force
