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
Write-Host '      NTC_WRT Dashboard Manager for QModem' -ForegroundColor Green
Write-Host '===================================================' -ForegroundColor Green
Write-Host "Target Router IP: $ip" -ForegroundColor Cyan
Write-Host '---------------------------------------------------' -ForegroundColor Gray
Write-Host 'Chon thao tac ban muon thuc hien:' -ForegroundColor Yellow
Write-Host ' [1] Cai dat / Cap nhat Dashboard NTC_WRT' -ForegroundColor White
Write-Host ' [2] Go bo Dashboard NTC_WRT (Khoi phuc mac dinh)' -ForegroundColor White
Write-Host '---------------------------------------------------' -ForegroundColor Gray

$choice = Read-Host "Nhap lua chon cua ban (1 hoac 2, mac dinh la 1)"
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

if ($choice -eq "2") {
    Write-Host 'Bat dau qua trinh go cai dat NTC_WRT Dashboard khoi Router...' -ForegroundColor Yellow
    
    $remote_uninstall_script = @'
echo "Stopping and disabling NTC_WRT services..."
/etc/init.d/mobile_poller stop 2>/dev/null
/etc/init.d/sms_sync stop 2>/dev/null
killall -9 mobile_poller.lua sms_sync.lua 2>/dev/null
/etc/init.d/mobile_poller disable 2>/dev/null
/etc/init.d/sms_sync disable 2>/dev/null

echo "Removing Dashboard and service files..."
rm -f /etc/init.d/mobile_poller /etc/init.d/sms_sync
rm -f /tmp/NTC_WRT_mobile.json /tmp/NTC_WRT_wan_interfaces /tmp/NTC_WRT_rom_stats /tmp/modem_at.lock

echo "Restoring original LuCI file..."
rm -f /www/cgi-bin/luci
if [ -f /rom/www/cgi-bin/luci ]; then
    cp /rom/www/cgi-bin/luci /www/cgi-bin/luci
    chmod +x /www/cgi-bin/luci
fi

rm -rf /www/NTC_WRT
rm -rf /www/cgi-bin/dashboard \
       /www/cgi-bin/system \
       /www/cgi-bin/wifi \
       /www/cgi-bin/sms \
       /www/cgi-bin/mobile \
       /www/cgi-bin/ttl \
       /www/cgi-bin/csrf \
       /www/cgi-bin/clients \
       /www/cgi-bin/mwan3 \
       /www/cgi-bin/reboot_schedule \
       /www/cgi-bin/led \
       /www/cgi-bin/tailscale \
       /www/cgi-bin/auth \
       /www/cgi-bin/drivers \
       /www/cgi-bin/lib 2>/dev/null

echo "Reverting uhttpd settings..."
uci delete uhttpd.NTC_WRT 2>/dev/null
uci set uhttpd.main.home='/www'
uci commit uhttpd
/etc/init.d/uhttpd restart

echo "Uninstallation finished successfully!"
'@
    
    $remoteScriptPath = Join-Path $binDir 'remote_uninstall.sh'
    Set-Content -Path $remoteScriptPath -Value $remote_uninstall_script -Encoding ascii

    Write-Host 'Uploading uninstaller to router...' -ForegroundColor Yellow
    & scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL $remoteScriptPath ("root@" + $ip + ":/tmp/remote_uninstall.sh")
    Write-Host 'Running uninstaller on router...' -ForegroundColor Yellow
    & ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL ("root@" + $ip) "sh /tmp/remote_uninstall.sh ; rm -f /tmp/remote_uninstall.sh"
    
    if (Test-Path $askpass) { Remove-Item -Path $askpass -Force | Out-Null }
    if (Test-Path $binDir) { Remove-Item -Recurse -Force $binDir | Out-Null }
    
    Write-Host '---------------------------------------------------' -ForegroundColor Gray
    Write-Host 'Go cai dat hoan tat! Thiet bi da duoc dua ve mac dinh.' -ForegroundColor Green
    Write-Host 'LuCI goc hoat dong tai dia chi: http://192.168.88.1/' -ForegroundColor Green
    Write-Host '===================================================' -ForegroundColor Green
}
else {
    Write-Host 'Bat dau qua trinh cai dat NTC_WRT Dashboard...' -ForegroundColor Yellow
    $tarPath = Join-Path $localRoot 'NTC_WRT_upload.tar.gz'
    if (Test-Path $tarPath) { Remove-Item $tarPath -Force }
    
    Push-Location $localRoot
    tar -czf NTC_WRT_upload.tar.gz index.html dashboard.html version.json css js lib services cgi-bin install.sh
    Pop-Location
    
    Write-Host 'Uploading archive to router...' -ForegroundColor Yellow
    & scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL $tarPath ("root@" + $ip + ":/tmp/NTC_WRT_upload.tar.gz")
    
    Write-Host 'Extracting and configuring on router...' -ForegroundColor Yellow
    $remote_script = @'
mkdir -p /tmp/NTC_WRT_extract /www/NTC_WRT /www/NTC_WRT/services /www/cgi-bin
tar -xzf /tmp/NTC_WRT_upload.tar.gz -C /tmp/NTC_WRT_extract

# Copy web files
cp /tmp/NTC_WRT_extract/index.html /www/NTC_WRT/
cp /tmp/NTC_WRT_extract/dashboard.html /www/NTC_WRT/
cp /tmp/NTC_WRT_extract/version.json /www/NTC_WRT/
cp -r /tmp/NTC_WRT_extract/css /www/NTC_WRT/
cp -r /tmp/NTC_WRT_extract/js /www/NTC_WRT/
cp -r /tmp/NTC_WRT_extract/lib /www/NTC_WRT/

# Copy services
cp -r /tmp/NTC_WRT_extract/services /www/NTC_WRT/

# Copy cgi-bin endpoints
cp -r /tmp/NTC_WRT_extract/cgi-bin/* /www/cgi-bin/ 2>/dev/null || cp -r /tmp/NTC_WRT_extract/cgi-bin /www/

# Copy init scripts
cp /www/NTC_WRT/services/init.d/mobile_poller /etc/init.d/ 2>/dev/null
cp /www/NTC_WRT/services/init.d/sms_sync /etc/init.d/ 2>/dev/null

# Restore original LuCI from ROM if it exists and /www/cgi-bin/luci is a symlink loop
if [ -L /www/cgi-bin/luci ] || [ ! -f /www/cgi-bin/luci ]; then
    rm -f /www/cgi-bin/luci
    cp /rom/www/cgi-bin/luci /www/cgi-bin/luci 2>/dev/null
fi

# Configure directory symbolic links
rm -rf /www/NTC_WRT/cgi-bin
ln -s /www/cgi-bin /www/NTC_WRT/cgi-bin

# Normalize file endings and set permissions
sed -i 's/\r$//' /etc/init.d/mobile_poller /etc/init.d/sms_sync /www/NTC_WRT/services/at_cmd.sh 2>/dev/null
find /www/NTC_WRT/ -type f -name "*.sh" -o -name "*.lua" 2>/dev/null | xargs sed -i 's/\r$//' 2>/dev/null
find /www/cgi-bin/ -type f 2>/dev/null | xargs sed -i 's/\r$//' 2>/dev/null

chmod +x /etc/init.d/mobile_poller /etc/init.d/sms_sync 2>/dev/null
chmod -R +x /www/cgi-bin/ 2>/dev/null
chmod -R +x /www/NTC_WRT/services/ 2>/dev/null

# Configure uhttpd
uci delete uhttpd.NTC_WRT 2>/dev/null
uci set uhttpd.NTC_WRT=uhttpd
uci add_list uhttpd.NTC_WRT.listen_http='0.0.0.0:2222'
uci add_list uhttpd.NTC_WRT.listen_http='[::]:2222'
uci set uhttpd.NTC_WRT.home='/www/NTC_WRT'
uci set uhttpd.NTC_WRT.cgi_prefix='/cgi-bin'
uci set uhttpd.NTC_WRT.ubus_prefix='/ubus'
uci set uhttpd.NTC_WRT.max_connections='100'
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
rm -rf /tmp/NTC_WRT_extract /tmp/NTC_WRT_upload.tar.gz
'@

    $remoteScriptPath = Join-Path $binDir 'remote_setup.sh'
    Set-Content -Path $remoteScriptPath -Value $remote_script -Encoding ascii
    
    Write-Host 'Running remote configuration script...' -ForegroundColor Yellow
    & scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL $remoteScriptPath ("root@" + $ip + ":/tmp/remote_setup.sh")
    & ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL ("root@" + $ip) "sh /tmp/remote_setup.sh ; rm -f /tmp/remote_setup.sh"
    
    if (Test-Path $askpass) { Remove-Item -Path $askpass -Force | Out-Null }
    if (Test-Path $binDir) { Remove-Item -Recurse -Force $binDir | Out-Null }
    if (Test-Path $tarPath) { Remove-Item -Path $tarPath -Force | Out-Null }
    
    Write-Host '---------------------------------------------------' -ForegroundColor Gray
    Write-Host 'Deployment completed successfully!' -ForegroundColor Green
    Write-Host 'LuCI (Original WebUI) is live on: http://192.168.88.1/' -ForegroundColor Green
    Write-Host 'NTC_WRT WebUI is live on: http://192.168.88.1:2222/' -ForegroundColor Green
    Write-Host '===================================================' -ForegroundColor Green
}
