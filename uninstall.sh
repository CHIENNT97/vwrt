#!/bin/sh

echo "==================================================="
echo "   VWRT Dashboard Uninstaller via SSH"
echo "==================================================="
echo "Stopping and disabling VWRT services..."

# Stop running services
/etc/init.d/mobile_poller stop 2>/dev/null
/etc/init.d/sms_sync stop 2>/dev/null
killall -9 mobile_poller.lua sms_sync.lua 2>/dev/null

# Disable services from boot
/etc/init.d/mobile_poller disable 2>/dev/null
/etc/init.d/sms_sync disable 2>/dev/null

# Remove service files
rm -f /etc/init.d/mobile_poller /etc/init.d/sms_sync
rm -f /tmp/vwrt_mobile.json /tmp/vwrt_wan_interfaces /tmp/vwrt_rom_stats /tmp/modem_at.lock

echo "Restoring original LuCI files..."
# Restore original LuCI CGI script from ROM
rm -f /www/cgi-bin/luci
if [ -f /rom/www/cgi-bin/luci ]; then
    cp /rom/www/cgi-bin/luci /www/cgi-bin/luci
    chmod +x /www/cgi-bin/luci
fi

echo "Removing Dashboard files..."
# Remove WebUI files
rm -rf /www/vwrt

# Remove custom CGI scripts (only those belonging to VWRT dashboard)
rm -rf /www/cgi-bin/dashboard \
       /www/cgi-bin/system \
       /www/cgi-bin/wifi \
       /www/cgi-bin/sms \
       /www/cgi-bin/mobile \
       /www/cgi-bin/ttl \
       /www/cgi-bin/csrf \
       /www/cgi-bin/clients \
       /www/cgi-bin/adblock \
       /www/cgi-bin/mwan3 \
       /www/cgi-bin/reboot_schedule \
       /www/cgi-bin/led \
       /www/cgi-bin/tailscale \
       /www/cgi-bin/auth \
       /www/cgi-bin/drivers \
       /www/cgi-bin/lib 2>/dev/null

echo "Reverting uhttpd configuration to default..."
# Delete the custom vwrt uhttpd instance
uci delete uhttpd.vwrt 2>/dev/null

# Reset default uhttpd home back to standard /www
uci set uhttpd.main.home='/www'
uci commit uhttpd

# Restart web server
/etc/init.d/uhttpd restart

echo "---------------------------------------------------"
echo "Uninstallation Completed Successfully!"
echo "All VWRT files removed and router reverted to default."
echo "LuCI is available on standard port 80: http://192.168.88.1/"
echo "==================================================="
