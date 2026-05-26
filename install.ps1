$ip = '192.168.88.1'
$pw = 'admin'
$localRoot = $PSScriptRoot

$binDir = Join-Path $localRoot 'bin'
if (!(Test-Path $binDir)) {
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
}

$askpass = Join-Path $binDir 'askpass.bat'
Set-Content -Path $askpass -Value "@echo $pw"

$env:SSH_ASKPASS = $askpass
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'dummy:0'

Write-Host '===================================================' -ForegroundColor Green
Write-Host '   VWRT WebUI & Service Installer for QModem' -ForegroundColor Green
Write-Host '===================================================' -ForegroundColor Green
Write-Host "Target Router IP: $ip" -ForegroundColor Cyan
Write-Host '---------------------------------------------------' -ForegroundColor Gray

Write-Host 'Archiving files locally for fast transfer...' -ForegroundColor Yellow
$tarPath = Join-Path $localRoot 'vwrt_upload.tar.gz'
if (Test-Path $tarPath) { Remove-Item $tarPath -Force }

Push-Location $localRoot
tar -czf vwrt_upload.tar.gz index.html dashboard.html version.json css js lib services cgi-bin
Pop-Location

Write-Host 'Uploading archive to router...' -ForegroundColor Yellow
& scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL $tarPath ("root@" + $ip + ":/tmp/vwrt_upload.tar.gz")

Write-Host 'Extracting and configuring on router...' -ForegroundColor Yellow
$remote_script = @'
mkdir -p /tmp/vwrt_extract /www/vwrt /www/vwrt/services /www/cgi-bin
tar -xzf /tmp/vwrt_upload.tar.gz -C /tmp/vwrt_extract

# Copy web files
cp /tmp/vwrt_extract/index.html /www/vwrt/
cp /tmp/vwrt_extract/dashboard.html /www/vwrt/
cp /tmp/vwrt_extract/version.json /www/vwrt/
cp -r /tmp/vwrt_extract/css /www/vwrt/
cp -r /tmp/vwrt_extract/js /www/vwrt/
cp -r /tmp/vwrt_extract/lib /www/vwrt/

# Copy services
cp -r /tmp/vwrt_extract/services /www/vwrt/

# Copy cgi-bin endpoints
cp -r /tmp/vwrt_extract/cgi-bin/* /www/cgi-bin/ 2>/dev/null || cp -r /tmp/vwrt_extract/cgi-bin /www/

# Copy init scripts
cp /tmp/vwrt_extract/services/init.d/mobile_poller /etc/init.d/ 2>/dev/null
cp /tmp/vwrt_extract/services/init.d/sms_sync /etc/init.d/ 2>/dev/null

# Restore original LuCI script
cp /rom/www/cgi-bin/luci /www/cgi-bin/luci 2>/dev/null
chmod +x /www/cgi-bin/luci 2>/dev/null

# Configure directory symbolic links
rm -rf /www/vwrt/cgi-bin
ln -s /www/cgi-bin /www/vwrt/cgi-bin

# Normalize file endings and set permissions
sed -i 's/\r$//' /etc/init.d/mobile_poller /etc/init.d/sms_sync /www/vwrt/services/at_cmd.sh 2>/dev/null
chmod +x /etc/init.d/mobile_poller /etc/init.d/sms_sync 2>/dev/null
chmod -R +x /www/cgi-bin/ 2>/dev/null
chmod -R +x /www/vwrt/services/ 2>/dev/null

# Configure uhttpd
uci delete uhttpd.vwrt 2>/dev/null
uci set uhttpd.vwrt=uhttpd
uci add_list uhttpd.vwrt.listen_http='0.0.0.0:2222'
uci add_list uhttpd.vwrt.listen_http='[::]:2222'
uci set uhttpd.vwrt.home='/www/vwrt'
uci set uhttpd.vwrt.cgi_prefix='/cgi-bin'
uci set uhttpd.vwrt.ubus_prefix='/ubus'
uci set uhttpd.vwrt.max_connections='100'
uci commit uhttpd

# Enable and restart services
/etc/init.d/mobile_poller enable 2>/dev/null
/etc/init.d/sms_sync enable 2>/dev/null

# Clean up running processes using ps (since pgrep is missing)
kill -9 $(ps | grep mobile_poller | grep -v grep | awk '{print $1}') 2>/dev/null
kill -9 $(ps | grep sms_sync | grep -v grep | awk '{print $1}') 2>/dev/null
rm -f /tmp/modem_at.lock

/etc/init.d/uhttpd restart
/etc/init.d/mobile_poller restart
/etc/init.d/sms_sync restart

# Clean up remote temp files
rm -rf /tmp/vwrt_extract /tmp/vwrt_upload.tar.gz
'@

$remoteScriptPath = Join-Path $binDir 'remote_setup.sh'
Set-Content -Path $remoteScriptPath -Value $remote_script -Encoding ascii

Write-Host 'Running remote configuration script...' -ForegroundColor Yellow
& scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL $remoteScriptPath ("root@" + $ip + ":/tmp/remote_setup.sh")
& ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL ("root@" + $ip) "sh /tmp/remote_setup.sh && rm /tmp/remote_setup.sh"

# Clean up local temporary files
if (Test-Path $askpass) {
    Remove-Item -Path $askpass -Force | Out-Null
}

if (Test-Path $binDir) {
    Remove-Item -Recurse -Force $binDir | Out-Null
}

if (Test-Path $tarPath) {
    Remove-Item -Path $tarPath -Force | Out-Null
}

Write-Host '---------------------------------------------------' -ForegroundColor Gray
Write-Host 'Deployment completed successfully!' -ForegroundColor Green
Write-Host 'LuCI (Original WebUI) is live on: http://192.168.88.1/' -ForegroundColor Green
Write-Host 'VWRT WebUI is live on: http://192.168.88.1:2222/' -ForegroundColor Green
Write-Host '===================================================' -ForegroundColor Green
