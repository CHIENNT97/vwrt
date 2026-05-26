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
