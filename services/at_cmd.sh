#!/bin/sh
DEVICE=$1
CMD=$2
[ -z "$DEVICE" ] && exit 1
[ -z "$CMD" ] && exit 1

# Kiểm tra device tồn tại và là character device (không phải file thường)
# Quan trọng: Ngăn việc ghi vào path tạo file thường thay vì mở device
if [ ! -c "$DEVICE" ]; then
    exit 1
fi

LOCK_FILE="/tmp/at_cmd.lock"
lock $LOCK_FILE

# Configure serial port to 115200 baud rate, raw mode, minus hardware flow control
stty -F $DEVICE 115200 raw -crtscts 2>/dev/null

TMP="/tmp/at_res_$$"
rm -f $TMP
touch $TMP

# Start reading in the background
cat $DEVICE > $TMP &
CAT_PID=$!

# Give cat a brief moment to initialize
sleep 0.1

# Send the command
echo -e "$CMD\r" > $DEVICE

# Wait for completion (OK, ERROR, or prompt) with a 1.5s timeout (15 * 0.1s)
timeout=0
while [ $timeout -lt 15 ]; do
    if grep -qE "OK|ERROR|>" $TMP 2>/dev/null; then
        break
    fi
    sleep 0.1
    timeout=$((timeout + 1))
done

# Clean up
kill -9 $CAT_PID 2>/dev/null

if [ -f $TMP ]; then
    cat $TMP
    rm -f $TMP
fi

lock -u $LOCK_FILE
