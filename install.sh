#!/bin/sh

echo "==================================================="
echo "   NTC_WRT Dashboard Manager (SSH)"
echo "==================================================="
echo " 1. Install / Update NTC_WRT Dashboard"
echo " 2. Uninstall NTC_WRT Dashboard"
echo " 3. Cancel"
echo "==================================================="
printf "Please select an option (1-3): "
read choice < /dev/tty

case $choice in
    1)
        echo "Starting Installation..."
        # Target directories
        WORK_DIR="/tmp/NTC_WRT_extract"
        TAR_FILE="/tmp/NTC_WRT_download.tar.gz"
        REPO_URL="https://github.com/CHIENNT97/vwrt/archive/refs/heads/main.tar.gz"

        echo "Downloading source from GitHub..."

        # Clean old temp files
        rm -rf "$WORK_DIR" "$TAR_FILE"
        mkdir -p "$WORK_DIR"

        # Download archive
        wget --no-check-certificate -O "$TAR_FILE" "$REPO_URL"
        if [ $? -ne 0 ] || [ ! -f "$TAR_FILE" ]; then
            echo "Error: Failed to download source archive from GitHub."
            exit 1
        fi

        echo "Extracting archive..."
        tar -xzf "$TAR_FILE" -C "$WORK_DIR"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to extract archive."
            rm -f "$TAR_FILE"
            exit 1
        fi

        # Find source directory (resolves github branch subfolder name e.g. NTC_WRT-main)
        SOURCE_DIR=$(ls -d "$WORK_DIR"/*/ 2>/dev/null | head -n 1)
        if [ -z "$SOURCE_DIR" ]; then
            SOURCE_DIR="$WORK_DIR/"
        fi

        echo "Stopping services..."
        killall -9 mobile_poller.lua sms_sync.lua 2>/dev/null
        /etc/init.d/mobile_poller stop 2>/dev/null
        /etc/init.d/sms_sync stop 2>/dev/null

        echo "Installing Web files..."
        mkdir -p /www/NTC_WRT /www/cgi-bin

        # Clean old NTC_WRT dir
        rm -rf /www/NTC_WRT/*

        # Copy new files
        cp -rf "${SOURCE_DIR}"index.html /www/NTC_WRT/
        cp -rf "${SOURCE_DIR}"dashboard.html /www/NTC_WRT/
        cp -rf "${SOURCE_DIR}"version.json /www/NTC_WRT/
        cp -rf "${SOURCE_DIR}"css /www/NTC_WRT/
        cp -rf "${SOURCE_DIR}"js /www/NTC_WRT/
        cp -rf "${SOURCE_DIR}"lib /www/NTC_WRT/
        cp -rf "${SOURCE_DIR}"services /www/NTC_WRT/

        # Copy cgi-bin files to global cgi-bin
        cp -rf "${SOURCE_DIR}"cgi-bin/* /www/cgi-bin/ 2>/dev/null

        # Configure symbolic links
        rm -rf /www/NTC_WRT/cgi-bin
        ln -snf /www/cgi-bin /www/NTC_WRT/cgi-bin
        ln -snf /www/luci-static /www/NTC_WRT/luci-static

        # Restore original LuCI from ROM if it exists and /www/cgi-bin/luci is a symlink loop
        if [ -L /www/cgi-bin/luci ] || [ ! -f /www/cgi-bin/luci ]; then
            rm -f /www/cgi-bin/luci
            cp /rom/www/cgi-bin/luci /www/cgi-bin/luci 2>/dev/null
        fi

        # Copy system service init scripts
        cp -f /www/NTC_WRT/services/init.d/mobile_poller /etc/init.d/ 2>/dev/null
        cp -f /www/NTC_WRT/services/init.d/sms_sync /etc/init.d/ 2>/dev/null

        # Clean up dev artifacts in destination
        rm -rf /www/NTC_WRT/.editorconfig /www/NTC_WRT/.vscode /www/NTC_WRT/.git* /www/NTC_WRT/deploy_tool /www/NTC_WRT/dist

        echo "Normalizing line endings (CRLF to LF)..."
        sed -i 's/\r$//' /etc/init.d/mobile_poller /etc/init.d/sms_sync /www/NTC_WRT/services/at_cmd.sh 2>/dev/null
        find /www/NTC_WRT/ -type f -name "*.sh" -o -name "*.lua" 2>/dev/null | xargs sed -i 's/\r$//' 2>/dev/null
        find /www/cgi-bin/ -type f 2>/dev/null | xargs sed -i 's/\r$//' 2>/dev/null

        echo "Setting permissions..."
        chmod 755 /www/NTC_WRT
        chmod -R +x /www/cgi-bin/ 2>/dev/null
        chmod -R +x /www/NTC_WRT/services/ 2>/dev/null
        chmod +x /etc/init.d/mobile_poller /etc/init.d/sms_sync 2>/dev/null

        echo "Configuring uhttpd..."
        uci delete uhttpd.NTC_WRT 2>/dev/null
        uci set uhttpd.NTC_WRT=uhttpd
        uci add_list uhttpd.NTC_WRT.listen_http='0.0.0.0:2222'
        uci add_list uhttpd.NTC_WRT.listen_http='[::]:2222'
        uci set uhttpd.NTC_WRT.home='/www/NTC_WRT'
        uci set uhttpd.NTC_WRT.cgi_prefix='/cgi-bin'
        uci set uhttpd.NTC_WRT.ubus_prefix='/ubus'
        uci set uhttpd.NTC_WRT.max_connections='100'
        uci commit uhttpd

        # Enable and start services
        /etc/init.d/mobile_poller enable 2>/dev/null
        /etc/init.d/sms_sync enable 2>/dev/null

        echo "Restarting uhttpd and starting services..."
        /etc/init.d/uhttpd restart
        /etc/init.d/mobile_poller restart
        /etc/init.d/sms_sync restart

        # Clean up temp files
        rm -rf "$WORK_DIR" "$TAR_FILE"

        echo "---------------------------------------------------"
        echo "Installation Completed Successfully!"
        echo "NTC_WRT WebUI is live on: http://192.168.88.1:2222/"
        echo "==================================================="
        ;;
    2)
        echo "Starting Uninstallation..."
        
        echo "Stopping and disabling NTC_WRT services..."

        # Stop running services
        /etc/init.d/mobile_poller stop 2>/dev/null
        /etc/init.d/sms_sync stop 2>/dev/null
        killall -9 mobile_poller.lua sms_sync.lua 2>/dev/null

        # Disable services from boot
        /etc/init.d/mobile_poller disable 2>/dev/null
        /etc/init.d/sms_sync disable 2>/dev/null

        # Remove service files
        rm -f /etc/init.d/mobile_poller /etc/init.d/sms_sync
        rm -f /tmp/NTC_WRT_mobile.json /tmp/NTC_WRT_wan_interfaces /tmp/NTC_WRT_rom_stats /tmp/modem_at.lock

        echo "Restoring original LuCI files..."
        # Restore original LuCI CGI script from ROM
        rm -f /www/cgi-bin/luci
        if [ -f /rom/www/cgi-bin/luci ]; then
            cp /rom/www/cgi-bin/luci /www/cgi-bin/luci
            chmod +x /www/cgi-bin/luci
        fi

        echo "Removing Dashboard files..."
        # Remove WebUI files
        rm -rf /www/NTC_WRT

        # Remove custom CGI scripts (only those belonging to NTC_WRT dashboard)
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

        echo "Reverting uhttpd configuration to default..."
        # Delete the custom NTC_WRT uhttpd instance
        uci delete uhttpd.NTC_WRT 2>/dev/null

        # Reset default uhttpd home back to standard /www
        uci set uhttpd.main.home='/www'
        uci commit uhttpd

        # Restart web server
        /etc/init.d/uhttpd restart

        echo "---------------------------------------------------"
        echo "Uninstallation Completed Successfully!"
        echo "All NTC_WRT files removed and router reverted to default."
        echo "LuCI is available on standard port 80: http://192.168.88.1/"
        echo "==================================================="
        ;;
    3|*)
        echo "Operation cancelled. Exiting..."
        exit 0
        ;;
esac
