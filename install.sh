#!/bin/sh

# Target directories
WORK_DIR="/tmp/vwrt_extract"
TAR_FILE="/tmp/vwrt_download.tar.gz"
REPO_URL="https://github.com/CHIENNT97/vwrt/archive/refs/heads/main.tar.gz"

echo "==================================================="
echo "   VWRT Dashboard Online Installer via SSH"
echo "==================================================="
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

# Find source directory (resolves github branch subfolder name e.g. vwrt-main)
SOURCE_DIR=$(ls -d "$WORK_DIR"/*/ 2>/dev/null | head -n 1)
if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$WORK_DIR/"
fi

echo "Stopping services..."
killall -9 mobile_poller.lua sms_sync.lua 2>/dev/null
/etc/init.d/mobile_poller stop 2>/dev/null
/etc/init.d/sms_sync stop 2>/dev/null

echo "Installing Web files..."
mkdir -p /www/vwrt /www/cgi-bin

# Clean old vwrt dir
rm -rf /www/vwrt/*

# Copy new files
cp -rf "${SOURCE_DIR}"index.html /www/vwrt/
cp -rf "${SOURCE_DIR}"dashboard.html /www/vwrt/
cp -rf "${SOURCE_DIR}"version.json /www/vwrt/
cp -rf "${SOURCE_DIR}"css /www/vwrt/
cp -rf "${SOURCE_DIR}"js /www/vwrt/
cp -rf "${SOURCE_DIR}"lib /www/vwrt/
cp -rf "${SOURCE_DIR}"services /www/vwrt/

# Copy cgi-bin files to global cgi-bin
cp -rf "${SOURCE_DIR}"cgi-bin/* /www/cgi-bin/ 2>/dev/null

# Configure symbolic links
rm -rf /www/vwrt/cgi-bin
ln -snf /www/cgi-bin /www/vwrt/cgi-bin
ln -snf /www/luci-static /www/vwrt/luci-static

# Restore original LuCI from ROM if it exists and /www/cgi-bin/luci is a symlink loop
if [ -L /www/cgi-bin/luci ] || [ ! -f /www/cgi-bin/luci ]; then
    rm -f /www/cgi-bin/luci
    cp /rom/www/cgi-bin/luci /www/cgi-bin/luci 2>/dev/null
fi

# Copy system service init scripts
cp -f /www/vwrt/services/init.d/mobile_poller /etc/init.d/ 2>/dev/null
cp -f /www/vwrt/services/init.d/sms_sync /etc/init.d/ 2>/dev/null

# Clean up dev artifacts in destination
rm -rf /www/vwrt/.editorconfig /www/vwrt/.vscode /www/vwrt/.git* /www/vwrt/deploy_tool /www/vwrt/dist

echo "Normalizing line endings (CRLF to LF)..."
sed -i 's/\r$//' /etc/init.d/mobile_poller /etc/init.d/sms_sync /www/vwrt/services/at_cmd.sh 2>/dev/null
find /www/vwrt/ -type f -name "*.sh" -o -name "*.lua" 2>/dev/null | xargs sed -i 's/\r$//' 2>/dev/null
find /www/cgi-bin/ -type f 2>/dev/null | xargs sed -i 's/\r$//' 2>/dev/null

echo "Setting permissions..."
chmod 755 /www/vwrt
chmod -R +x /www/cgi-bin/ 2>/dev/null
chmod -R +x /www/vwrt/services/ 2>/dev/null
chmod +x /etc/init.d/mobile_poller /etc/init.d/sms_sync 2>/dev/null

echo "Configuring uhttpd..."
uci delete uhttpd.vwrt 2>/dev/null
uci set uhttpd.vwrt=uhttpd
uci add_list uhttpd.vwrt.listen_http='0.0.0.0:2222'
uci add_list uhttpd.vwrt.listen_http='[::]:2222'
uci set uhttpd.vwrt.home='/www/vwrt'
uci set uhttpd.vwrt.cgi_prefix='/cgi-bin'
uci set uhttpd.vwrt.ubus_prefix='/ubus'
uci set uhttpd.vwrt.max_connections='100'
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
echo "VWRT WebUI is live on: http://192.168.88.1:2222/"
echo "==================================================="
