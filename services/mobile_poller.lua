#!/usr/bin/lua

local cjson = require "cjson"
-- Add project root to package path
package.path = "/www/vwrt/?.lua;" .. package.path

local constants = require "lib.constants"
local CACHE_FILE = constants.PATHS.MOBILE_CACHE
local TEMP_FILE = constants.PATHS.MOBILE_CACHE_TEMP
local LOCK_DIR = "/tmp/modem_at_lockdir"

local function safe_execute(cmd)
    local res = os.execute(cmd)
    return (res == 0 or res == true)
end

function acquire_lock()
    local try = 0
    while try < 5 do
        if safe_execute("mkdir " .. LOCK_DIR .. " 2>/dev/null") then
            return true
        end
        os.execute("sleep 1")
        try = try + 1
    end
    -- If lock is stale (e.g. script crashed)
    os.execute("rm -rf " .. LOCK_DIR)
    if safe_execute("mkdir " .. LOCK_DIR .. " 2>/dev/null") then
        return true
    end
    return false
end

function release_lock()
    os.execute("rm -rf " .. LOCK_DIR)
end



-- SECURITY NOTE: exec() được dùng với hardcoded commands trong poller
-- Không nhận user input nên KHÔNG CÓ command injection risk
function exec(cmd)
    local f = io.popen(cmd)
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

function log(msg)
    os.execute("logger -t VWRT_POLLER '" .. tostring(msg) .. "'")
end

function exec_at_tty(device, cmd)
    if not cmd or cmd == "" then return nil end
    
    -- Use shell script to execute AT command
    local sh = string.format("/www/vwrt/services/at_cmd.sh %s '%s' 2>/dev/null", device, cmd)
    return exec(sh)
end

-- Clear TTY garbage before real commands
function drain_tty(device)
    exec(string.format("(cat %s & PID=$!; sleep 1; kill -9 $PID 2>/dev/null) >/dev/null 2>&1", device))
end


function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

function write_file(path, content)
    local f = io.open(path, "w")
    if f then
        f:write(content)
        f:close()
    end
end

function get_net_stats(iface)
    if not iface or iface == "" then return {rx="0", tx="0"} end
    local rx_path = "/sys/class/net/" .. iface .. "/statistics/rx_bytes"
    local tx_path = "/sys/class/net/" .. iface .. "/statistics/tx_bytes"
    local rx = read_file(rx_path)
    local tx = read_file(tx_path)
    return {
        rx = rx and rx:gsub("\n", "") or "0",
        tx = tx and tx:gsub("\n", "") or "0"
    }
end

-- Get last AT port from mmcli JSON ports array (last is usually the working one for Dell)
function get_at_port_from_json(raw_json)
    if not raw_json then return nil end
    local ok, parsed = pcall(cjson.decode, raw_json)
    if not ok or not parsed or not parsed.modem or not parsed.modem.generic then return nil end
    local ports = parsed.modem.generic.ports
    if not ports then return nil end
    local last_at_port = nil
    for _, p in ipairs(ports) do
        local port_name = p:match("(ttyUSB%d+) %(at%)")
        if port_name then last_at_port = "/dev/" .. port_name end
    end
    return last_at_port
end

function get_bands_string(bands_list)
    if not bands_list or #bands_list == 0 then return "" end
    local b_str = ""
    for _, b in ipairs(bands_list) do
        local clean = b:gsub("eutran%-", "B"):gsub("ngran%-", "n"):gsub("utran%-", "B")
        if b_str == "" then b_str = clean else b_str = b_str .. ", " .. clean end
    end
    return b_str
end

-- === SIERRA / EM9191 SPECIFIC PARSER ===
function parse_at_gstatus(output)
    if not output then return {} end
    local res = {}
    
    -- Temp
    local temp = output:match("Temperature:%s*(%d+)")
    if temp then res.mtemp = temp end
    
    -- LTE Band & CA
    local lte_pcc = output:match("LTE band:.-(%S+)")
    local active_bands = {}
    
    if lte_pcc then table.insert(active_bands, lte_pcc) end
    
    for i = 1, 4 do
        local state = output:match("LTE SCC" .. i .. " state:%s*(%S+)")
        local band = output:match("LTE SCC" .. i .. " band:%s*(%S+)")
        -- Include SCC even if INACTIVE to show LTE-A capability
        if state and band and band ~= "---" then
            table.insert(active_bands, band)
        end
    end
    
    -- NR5G Band (Sierra Output)
    local nr_band = output:match("NR5G band:%s*(%S+)")
    if nr_band and nr_band ~= "---" then
        if #active_bands > 0 then
            res.active_mode = "5G NSA"
        else
            res.active_mode = "5G SA"
        end
        table.insert(active_bands, nr_band)
    elseif #active_bands > 1 then
        res.active_mode = "LTE-A"
    end
    
    if #active_bands > 0 then
        res.active_band = table.concat(active_bands, " + ")
    end

    local sys_mode = output:match("System mode:.-(%S+)")
    if sys_mode and not res.active_mode then res.active_mode = sys_mode end

    -- Enhanced RSRQ parsing (Try multiple formats)
    -- Matches "RSRQ (dB): -10" or "RSRQ: -10"
    local rsrq = output:match("RSRQ.-:.-([%-%d%.]+)")
    if rsrq then res.rsrq = rsrq end
    
    -- Enhanced RSSI parsing
    -- Matches "Rx0 RSSI: -60" or "RSSI (dBm): -60" or "RSSI: -60"
    local rssi = output:match("Rx[0M] RSSI:.-([%-%d]+)")
    if not rssi then rssi = output:match("RSSI.-:.-([%-%d]+)") end
    if rssi then res.rssi = rssi end
    
    -- 5G Stats
    local nr_rsrp = output:match("NR5G RSRP %(dBm%):%s*([%-%d]+)")
    local nr_sinr = output:match("NR5G SINR %(dB%):%s*([%-%d%.]+)")
    local nr_rsrq = output:match("NR5G RSRQ %(dB%):%s*([%-%d%.]+)")
    
    if nr_rsrp and nr_rsrp ~= "---" then
        res.rsrp = nr_rsrp
        res.sinr = nr_sinr
        res.rsrq = nr_rsrq
        if not res.active_mode or not res.active_mode:find("5G") then
             res.active_mode = "5G NSA"
        end
    else
        -- LTE SINR
        local sinr = output:match("SINR.-:.-([%-%d%.]+)")
        if sinr then res.sinr = sinr end
        
        -- LTE RSRP (Fallback if not 5G)
        local rsrp = output:match("Rx[0M] RSRP:.-([%-%d]+)")
        if not rsrp then rsrp = output:match("RSRP.-:.-([%-%d]+)") end
        if rsrp then res.rsrp = rsrp end
    end
    
    -- Cell ID
    local cellid = output:match("Cell ID:%s*(%x+) %(%d+%)")
    if cellid then res.cell_id = cellid end
    
    return res
end

-- === DELL / DW5821e SPECIFIC PARSER ===
function parse_at_dw5821e_temp(output)
    if not output then return nil end
    -- Format: xo_therm_buf:43
    local temp = output:match("xo_therm_buf:(%d+)")
    return temp
end

function parse_at_dw5821e_cainfo(output)
    if not output then return {} end
    local res = {}
    local active_bands = {}
    
    -- PCC info: Band is LTE_B3, Band_width...
    local pcc_band = output:match("PCC info: Band is ([^,%s]+)")
    if pcc_band then
        pcc_band = pcc_band:gsub("LTE_", "") -- Clean to B3
        table.insert(active_bands, pcc_band)
    end
    
    -- SCC info lookups (SCC1, SCC2...)
    -- SCC1 info: Band is LTE_B1, Band_width...
    for line in output:gmatch("SCC%d+ info:[^\n]+") do
        local scc_band = line:match("Band is ([^,%s]+)")
        if scc_band then
            scc_band = scc_band:gsub("LTE_", "")
            table.insert(active_bands, scc_band)
        end
    end
    
    if #active_bands > 1 then
        res.active_mode = "LTE-A"
    elseif #active_bands == 1 then
        res.active_mode = "LTE"
    end
    
    if #active_bands > 0 then
        res.active_band = table.concat(active_bands, " + ")
    end
    
    return res
end


-- === MAIN JSON PARSER ===
-- Helper to find net port
local function get_net_port(ports)
    if not ports then return "wwan0" end -- Fallback
    for _, p in ipairs(ports) do
        local name = p:match("([%w%d]+)%s*%(net%)")
        if name then return name end
    end
    return "wwan0"
end

function parse_mmcli_json(raw_json)
    if not raw_json or raw_json == "" then return nil end
    local ok, parsed = pcall(cjson.decode, raw_json)
    if not ok or not parsed or not parsed.modem then return nil end
    
    local m = parsed.modem
    local g3pp = m["3gpp"] or {}
    local generic = m.generic or {}
    local sig_qual = m["signal-quality"] or {}
    
    local raw_mode = generic["access-technologies"] and generic["access-technologies"][1] or "-"
    local mode_upper = raw_mode:upper()
    
    local bands = generic["current-bands"] or {}
    local band_str = get_bands_string(bands)
    local final_mode = mode_upper
    
    if band_str ~= "" and #bands <= 5 then
        final_mode = mode_upper .. " | " .. band_str
    end
    
    local iface_name = get_net_port(generic.ports)

    local result = {
        operator_name = g3pp["operator-name"] or "-",
        operator_mcc = g3pp["operator-code"] and string.sub(g3pp["operator-code"], 1, 3) or "-",
        operator_mnc = g3pp["operator-code"] and string.sub(g3pp["operator-code"], 4) or "-",
        simulation = "false", 
        mode = final_mode, 
        signal = sig_qual.value and tostring(sig_qual.value) or "0",
        imei = g3pp.imei or "-",
        modem = generic.model or "-",
        model = generic.model or "-",
        firmware = generic.revision or "-",
        manufacturer = generic.manufacturer or "-",
        own_number = generic["own-numbers"] and generic["own-numbers"][1] or "-",
        mtemp = "-", 
        rsrp = "-", rsrq = "-", sinr = "-", rssi = "-",
        conn_time = "-", rx = "0", tx = "0", csq = "0", registration = "1", cell_id = "-", ping = "-",
        state = m.state or (generic and generic.state) or "unknown",
        iface = iface_name,
        hardware_revision = generic["hardware-revision"] or "-"
    }
    return result
end

function parse_mmcli_signal(raw)
    if not raw or raw == "" then return {} end
    local status, data = pcall(cjson.decode, raw)
    if not status or not data or not data.modem or not data.modem.signal then return {} end
    local s = data.modem.signal
    local res = {}
    if s["5g"] and s["5g"].rsrp and s["5g"].rsrp ~= "--" then
         res.rsrp = s["5g"].rsrp; res.rsrq = s["5g"].rsrq; res.sinr = s["5g"].snr
    elseif s.lte and s.lte.rsrp and s.lte.rsrp ~= "--" then
         res.rsrp = s.lte.rsrp; res.rsrq = s.lte.rsrq; res.sinr = s.lte.snr; res.rssi = s.lte.rssi
    end
    return res
end

local function calculate_signal_strength_rsrp(rsrp)
    if not rsrp or rsrp == "-" then return 0 end
    local r = tonumber(rsrp)
    if not r then return 0 end
    -- RSRP mapping: -80 dBm (100%) to -120 dBm (0%)
    if r >= -80 then return 100 end
    if r <= -120 then return 0 end
    local percent = (r + 120) * (100 / 40)
    return math.floor(percent)
end

local function calculate_signal_strength(rssi)
    if not rssi or rssi == "-" then return 0 end
    local r = tonumber(rssi)
    if not r then return 0 end
    -- RSSI mapping: -51 dBm to -113 dBm
    if r >= -51 then return 100 end
    if r <= -113 then return 0 end
    local percent = (r + 113) * (100 / 62)
    return math.floor(percent)
end

local function apply_auto_led(mode, ping, iface, state)
    local config_file = "/etc/vwrt_autoled.json"
    local f = io.open(config_file, "r")
    if not f then return end
    local content = f:read("*all")
    f:close()
    
    local ok, config = pcall(cjson.decode, content)
    if not ok or not config or not config.enabled then return end

    local current_status = "No Service"
    if ping and ping ~= "" and ping ~= "-" then
        mode = tostring(mode or "")
        if mode:find("5G") or mode:find("NR") then
            current_status = "5G"
        elseif mode:find("4G") or mode:find("LTE") then
            current_status = "4G"
        elseif mode == "Unknown" or mode == "" or mode == "-" then
            -- Special status: Connected but mode not yet detected
            -- Auto-light up BOTH 4G and 5G LEDs (no need for user to configure separately)
            current_status = "Connected"
        end
    end

    local active_led = nil
    local active_leds = {}  -- Support multiple LEDs for "Connected" status
    
    if current_status == "Connected" then
        -- Auto-enable both 4G and 5G LEDs
        for _, rule in ipairs(config.rules or {}) do
            if (rule.status == "4G" or rule.status == "5G") and rule.led ~= "" then
                table.insert(active_leds, rule.led)
            end
        end
    else
        -- For specific modes (4G/5G), find the matching LED
        for _, rule in ipairs(config.rules or {}) do
            if rule.status == current_status and rule.led ~= "" then
                active_led = rule.led
                break
            end
        end
    end

    -- DEBUG LOG
    os.execute("logger -t VWRT_LED 'Status: " .. current_status .. " | Ping: " .. tostring(ping) .. " | Mode: " .. tostring(mode) .. " | Iface: " .. tostring(iface) .. "'")

    -- Helper function to check if LED should be active
    local function is_led_active(led_name)
        if active_led and led_name == active_led then return true end
        for _, al in ipairs(active_leds) do
            if led_name == al then return true end
        end
        return false
    end

    for _, rule in ipairs(config.rules or {}) do
        if rule.led and rule.led ~= "" then
            local led_path = "/sys/class/leds/" .. rule.led
            if is_led_active(rule.led) then
                -- Match: Apply trigger
                local trigger = rule.trigger or "default-on"
                os.execute("echo '" .. trigger .. "' > " .. led_path .. "/trigger")
                
                if trigger == "netdev" then
                    -- Configure netdev trigger for "Blink on Data"
                    if iface then
                        os.execute("echo '" .. iface .. "' > " .. led_path .. "/device_name")
                    end
                    os.execute("echo 1 > " .. led_path .. "/link")
                    os.execute("echo 1 > " .. led_path .. "/rx")
                    os.execute("echo 1 > " .. led_path .. "/tx")
                else
                    -- For Static ON
                    os.execute("echo 1 > " .. led_path .. "/brightness")
                end
            else
                -- Not match: Turn off
                os.execute("echo 'none' > " .. led_path .. "/trigger")
                os.execute("echo 0 > " .. led_path .. "/brightness")
            end
        end
    end
end

-- === MODEM AUTO-HEALING ===
local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function resolve_link(path)
    local handle = io.popen("/usr/bin/readlink -f " .. path)
    if not handle then return nil end
    local resolved = handle:read("*line")
    handle:close()
    return resolved
end

local function find_usb_root(path)
    local curr = path
    for i=1, 6 do
        if not curr or curr == "" or curr == "/" then return nil end
        if file_exists(curr .. "/idVendor") then return curr end
        curr = curr:match("(.*)/")
    end
    return nil
end

local function find_modem_device()
    -- Strategy 1: cdc-wdm (MBIM/QMI)
    local handle = io.popen("/bin/ls -d /sys/class/usbmisc/cdc-wdm* 2>/dev/null")
    if handle then
        for line in handle:lines() do
            local res = resolve_link(line)
            if res then
                local root = find_usb_root(res)
                if root then handle:close(); return root end
            end
        end
        handle:close()
    end

    -- Strategy 2: ttyUSB (ATC/PPP)
    -- Priority: ttyUSB3 (Standard for FM350/Quectel/Sierra on this router)
    if file_exists("/sys/class/tty/ttyUSB3") then
         return "/dev/ttyUSB3"
    end

    handle = io.popen("/bin/ls -d /sys/class/tty/ttyUSB* 2>/dev/null")
    if handle then
        local ports = {}
        for line in handle:lines() do
            table.insert(ports, line)
        end
        handle:close()
        
        -- Sort ports
        table.sort(ports)
        if #ports > 0 then
            -- For FM350, the dialing port is often the highest one (ttyUSB3 in this setup)
            -- If we have multiple, let's pick the last one instead of the first
            local port_name = ports[#ports]:match("([^/]+)$")
            return "/dev/" .. port_name
        end
    end
    return nil
end

local function get_interface_ip(iface)
    if not iface or iface == "" then return nil end
    local f = io.popen("ifconfig " .. iface .. " 2>/dev/null")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    if content then
        -- Match "inet addr:10.x.x.x" (Linux/Busybox ifconfig)
        local ip = content:match("inet addr:(%d+.%d+.%d+.%d+)")
        if not ip then
             -- Try "inet 10.x.x.x" (some versions)
             ip = content:match("inet (%d+.%d+.%d+.%d+)")
        end
        return ip
    end
    return nil
end

local function check_and_fix_modem_config()
    local current_dev = exec("uci -q get network.5G.device"):gsub("\n", "")
    local dev_valid = false
    
    -- Check if configured device actually exists
    if current_dev ~= "" and current_dev ~= "nil" then
         if file_exists(current_dev) then
             dev_valid = true
         end
    end

    if not dev_valid then
        local detected = find_modem_device()
        if detected then
            os.execute("logger -t VWRT_POLLER 'Invalid/Missing device config (" .. current_dev .. "). Auto-fixing to: " .. detected .. "'")
            os.execute("uci set network.5G.device='" .. detected .. "' && uci commit network && /etc/init.d/network reload")
            -- Wait for network to settle
            os.execute("sleep 5")
        end
    end
end


-- Helper: Get current modem index (0, 1, 2...)
local function get_current_modem_index()
    local out = exec("mmcli -L 2>/dev/null")
    if not out then return "0" end
    local idx = out:match("/Modem/(%d+)")
    return idx or "0"
end

-- Helper: Execute AT via mmcli injection (Safe & Shared)
local function exec_at_mmcli(idx, cmd)
    if not idx or not cmd then return nil end
    local safe_cmd = cmd:gsub("'", "'\\''") 
    -- Timeout 5s is sufficient for info commands
    local sh_cmd = string.format("mmcli -m %s --command='%s' --timeout=5 2>/dev/null", idx, safe_cmd)
    local out = exec(sh_cmd)
    
    -- Extract content inside "response: '...'"
    -- Simple extraction: find first quote, find last quote behavior
    local s, e = out:find("response: '")
    if e then
        local content = out:sub(e + 1)
        -- Remove trailing quote (and potentially newline)
        content = content:gsub("'\n?$", "")
        -- Return cleaned content
        return content:gsub("\\r", ""):gsub("\\n", "\n")
    end
    return nil
end
-- ===========================
-- ===========================

-- === FM350 / HYBRID LOGIC ===

-- Helper: Find which interface is using 'xmm' proto
-- Returns: interface_name (e.g., "wan", "5G"), device_path (e.g., "/dev/ttyUSB3")
local function find_xmm_interface()
    local handle = io.popen("uci show network | grep '.proto=.xmm.'")
    if not handle then return nil, nil end
    
    for line in handle:lines() do
        -- Line format: network.interface_name.proto='xmm'
        local iface = line:match("network%.(.-)%.proto=")
        if iface then
            local dev = exec("uci -q get network." .. iface .. ".device"):gsub("\n", "")
            return iface, dev
        end
    end
    handle:close()
    return nil, nil
end

function is_xmm_mode()
    local iface, _ = find_xmm_interface()
    return (iface ~= nil)
end

-- Get configured AT port for FM350
function get_fm350_port()
    -- SINGLE PORT STRATEGY: ttyUSB1/2 reported as unreliable/zombie.
    -- Force ttyUSB3 to stay aligned with SMS driver.
    if file_exists("/dev/ttyUSB3") then return "/dev/ttyUSB3" end
    
    -- Fallbacks
    if file_exists("/dev/ttyUSB1") then return "/dev/ttyUSB1" end
    if file_exists("/dev/ttyUSB2") then return "/dev/ttyUSB2" end
    
    local _, dev = find_xmm_interface()
    if dev and dev ~= "" and dev ~= "nil" then return dev end
    return "/dev/ttyUSB3" -- Fallback
end

local fm350_parser = require("services.parsers.fm350_at")

-- === QMODEM INTEGRATION ===
-- Detect if luci-app-qmodem is managing the modem
function is_qmodem_mode()
    local cfg = exec("uci -q get qmodem.main.enable_dial 2>/dev/null")
    if cfg and cfg:gsub("%s+", "") == "1" then return true end
    return false
end

-- Get network device and model from qmodem UCI config
function get_qmodem_config()
    local out = exec("uci -q show qmodem 2>/dev/null")
    if not out then return {} end
    local sections = {}
    for line in out:gmatch("[^\n]+") do
        local sec, key, val = line:match("^qmodem%.([%w_]+)%.([%w_]+)=['\"]?([^'\"]+)['\"]?")
        if sec and key and val then
            sections[sec] = sections[sec] or {}
            sections[sec][key] = val
        end
    end
    
    -- Find the section that has enable_dial = '1'
    for sec, fields in pairs(sections) do
        if fields.enable_dial == "1" then
            return fields
        end
    end
    
    -- Fallback: return the first section found if none is enabled
    for sec, fields in pairs(sections) do
        if sec ~= "main" then
            return fields
        end
    end
    
    return {}
end

-- Read modem info from qmodem ubus (single call for all basic info)
function read_qmodem_ubus_info()
    local raw = exec("ubus call modem_ctrl info '{}' 2>/dev/null")
    if not raw or raw == "" then return nil end
    
    local ok, parsed = pcall(cjson.decode, raw)
    if not ok or not parsed or not parsed.info then return nil end
    if not parsed.info[1] or not parsed.info[1].modem_info then return nil end
    
    local lookup = {}
    for _, item in ipairs(parsed.info[1].modem_info) do
        if item.key and item.value then
            -- Clean value: trim leading/trailing whitespace and newlines
            local clean = (item.value or ""):gsub("^[\n%s]+",""):gsub("[\n%s]+$","")
            lookup[item.key] = clean
            -- Also store normalized key (lowercase, no space/underscore)
            local norm = item.key:lower():gsub("[%s_]+", "")
            lookup[norm] = clean
        end
    end
    return lookup
end

-- Persistent signal cache: keeps last known good values across iterations
-- Prevents interleaved AT responses from qmodem daemon overwriting good data
local last_good_signal = {
    rsrp = nil, rsrq = nil, sinr = nil, rssi = nil,
    mode = nil, mtemp = nil, signal = nil
}

function main()
    -- Restore LED Config
    local function restore_leds() 
        local f = io.open("/etc/vwrt_led.json", "r")
        if f then
            local content = f:read("*all")
            f:close()
            local config = cjson.decode(content)
            if config then
                for name, settings in pairs(config) do
                    local led_path = "/sys/class/leds/" .. name
                    if settings.trigger then
                        os.execute("echo '" .. settings.trigger .. "' > " .. led_path .. "/trigger")
                    end
                    if settings.brightness then
                        os.execute("echo '" .. tostring(settings.brightness) .. "' > " .. led_path .. "/brightness")
                    end
                end
            end
        end
    end
    pcall(restore_leds)

    -- Initial check and fix (Only for ModemManager setups usually, but harmless)
    if not is_qmodem_mode() then
        pcall(check_and_fix_modem_config)
    end

    -- Only run mmcli setup if NOT in XMM mode and NOT in QModem mode
    if not is_xmm_mode() and not is_qmodem_mode() then
        local m_idx = get_current_modem_index()
        exec("mmcli -m " .. m_idx .. " --signal-setup=1")
    end

    local loop_count = 0
    local pending_start_time = 0
    while true do
        -- Auto-Healing every 20 cycles (~100 seconds)
        -- Only run if interface is NOT up and NOT in QModem mode
        if loop_count % 20 == 0 and not is_qmodem_mode() then
            local if_status = exec("ifstatus 5G")
            if if_status and if_status:find('"up": false') then
                pcall(check_and_fix_modem_config)
            end
        end

        -- Auto Free RAM every ~12.5 minutes (150 * 5s = 750s)
        loop_count = loop_count + 1
        -- ... (already handled)
        if loop_count >= 150 then
            os.execute("sync && echo 3 > /proc/sys/vm/drop_caches")
            loop_count = 0
        end

        -- === INTERNET WATCHDOG (AUTO RECONNECT / LITE DETECTOR) ===
        -- Runs every 30 seconds (Every 6th loop of 5s)
        if loop_count % 6 == 0 then
            -- 1. Check if interface intends to be UP
            local status_check = exec("ifstatus 5G")
            if status_check and status_check:find('"up": true') then
                
                -- 2. Ping Test (Google & Cloudflare)
                -- Only ping if we have an IP and uptime > 3min
                local uptime_raw = exec("cut -d. -f1 /proc/uptime")
                local sys_uptime = tonumber(uptime_raw) or 0
                
                local ping_ok = false
                if sys_uptime > 60 then
                     ping_ok = safe_execute("ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1")
                     if not ping_ok then
                          ping_ok = safe_execute("ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1")
                     end
                else
                     -- During boot, we assume OK to avoid restart loop
                     ping_ok = true
                end
                
                -- 3. Action on Failure
                if not ping_ok then
                     -- Double check with longer timeout to avoid false positive
                     local retry = safe_execute("ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1")
                     if not retry then
                          exec("logger -t VWRT_WATCHDOG 'Connection Lost confirmed. Restarting 5G interface...'")
                          os.execute("ifdown 5G; sleep 2; ifup 5G")
                     end
                end
            end
        end
        -- ===========================================

        -- Respect AT Port Lock, but ignore stale locks (> 60s)
        local lock_path = "/tmp/modem_at.lock"
        local is_locked = false
        local f = io.open(lock_path, "r")
        if f then
            local ts = tonumber(f:read("*all") or "0")
            f:close()
            if os.time() - (ts or 0) < 30 then
                is_locked = true
            else
                -- Lock is stale, remove it
                os.remove(lock_path)
            end
        end

        if not is_locked then
            local status, err = pcall(function()
            local data_modem = nil
            
            -- Detect if 5G interface is setting up. 
            local if_status_raw = exec("ifstatus 5G")
            local is_pending = if_status_raw and if_status_raw:find('"pending": true')



            -- Stuck Pending Logic (Auto Restart Interface if stuck > 60s using os.time)
            if is_pending then
                if pending_start_time == 0 then
                    pending_start_time = os.time()
                elseif os.time() - pending_start_time > 60 then
                    os.execute("logger -t VWRT_POLLER 'Interface 5G stuck in PENDING state (>60s). Hard Resetting...'")
                    
                    -- 1. Shutdown Interface (Frees the AT port)
                    os.execute("ifdown 5G")
                    os.execute("sleep 5")

                    -- 2. Force Modem Online (Safe now)
                    local port = get_fm350_port()
                    if acquire_lock() then
                        os.execute("logger -t VWRT_POLLER 'Forcing Modem Online (CFUN=1) while interface is down...'")
                        exec_at_tty(port, "AT+CFUN=1")
                        release_lock()
                    end
                    os.execute("sleep 2")

                    -- 3. Restart Interface
                    os.execute("ifup 5G")
                    pending_start_time = 0
                end
            else
                pending_start_time = 0
            end

            -- === MODEM DETECTION ===
            local is_qmodem = is_qmodem_mode()
            local is_fm350 = is_xmm_mode()

            if is_qmodem then
                -- === PATH 0: QMODEM (luci-app-qmodem manages the modem) ===
                local qmodem_cfg = get_qmodem_config()
                local qmodem_net = qmodem_cfg.network or "eth2"
                local qmodem_model = (qmodem_cfg.name or "Modem"):upper()
                
                -- Read basic info from qmodem ubus
                local ubus_info = read_qmodem_ubus_info() or {}
                local port = ubus_info["atport"] or ubus_info["at_port"] or "/dev/ttyUSB3"
                
                local manufacturer = ubus_info["manufacturer"] or "Unknown"
                local revision = ubus_info["revision"] or ubus_info["firmware"] or "-"
                local imei = ubus_info["imei"] or ubus_info["IMEI"] or "-"
                local operator = ubus_info["isp"] or ubus_info["operator"] or ubus_info["operatorname"] or ubus_info["operator_name"] or ubus_info["ISP"] or "-"
                local temp = ubus_info["temperature"] or ubus_info["temp"] or ubus_info["mtemp"] or "-"
                local state_val = ubus_info["connectstatus"] or ubus_info["connect_status"] or ubus_info["status"] or ubus_info["state"] or "unknown"
                local sim_num = ubus_info["simnumber"] or ubus_info["sim_number"] or ubus_info["simcardnumber"] or ubus_info["iccid"] or ubus_info["imsi"] or ubus_info["SIM Number"] or "-"
                local net_mode = ubus_info["networkmode"] or ubus_info["network_mode"] or ubus_info["networktype"] or ubus_info["network_type"] or ubus_info["Network Type"] or "Unknown"
                
                local state = "disconnected"
                local lower_state = tostring(state_val):lower()
                if lower_state == "yes" or lower_state == "connected" or lower_state == "online" or lower_state == "1" then
                    state = "connected"
                end
                
                -- Get WAN IP from interface
                local ip = get_interface_ip(qmodem_net)
                if ip then 
                    state = "connected"
                end

                data_modem = {
                    manufacturer = manufacturer,
                    model = qmodem_model,
                    modem = qmodem_model,
                    firmware = revision,
                    imei = imei,
                    operator_name = operator,
                    mtemp = temp,
                    state = state,
                    iface = qmodem_net,
                    mode = net_mode,
                    own_number = sim_num,
                    rsrp = "-", rsrq = "-", sinr = "-", rssi = "-",
                    signal = "0", conn_time = "-", rx = "0", tx = "0",
                    csq = "0", registration = "1", cell_id = "-", ping = "-",
                    wan_ip = ip or "Unknown"
                }
                
                -- Signal data via AT commands (reuse FM350 parser)
                if not is_pending then
                    if acquire_lock() then
                        drain_tty(port)
                        
                        local combined_raw = exec_at_tty(port, "AT+GTCCINFO?;+GTCAINFO?;+GTSENRDTEMP=1;+CSQ")
                        log("Poller raw response length: " .. tostring(combined_raw and #combined_raw or "nil"))
                        if combined_raw then
                            log("Poller raw response: " .. combined_raw:gsub("\r", "\\r"):gsub("\n", "\\n"))
                        end
                        local s1 = fm350_parser.parse_all_signal(combined_raw)
                        
                        -- Check if response was valid (has GTCCINFO data)
                        local got_valid_signal = (s1.rsrp ~= nil or s1.full_mode ~= nil)
                        
                        if got_valid_signal then
                            -- Fresh valid data: update data_modem AND cache
                            if s1.full_mode then
                                data_modem.mode = s1.full_mode
                                last_good_signal.mode = s1.full_mode
                            end
                            if s1.rsrp then
                                data_modem.rsrp = s1.rsrp
                                last_good_signal.rsrp = s1.rsrp
                            end
                            if s1.rsrq then
                                data_modem.rsrq = s1.rsrq
                                last_good_signal.rsrq = s1.rsrq
                            end
                            if s1.sinr then
                                data_modem.sinr = s1.sinr
                                last_good_signal.sinr = s1.sinr
                            end
                            
                            -- Temperature from AT (more precise than ubus)
                            local temp = fm350_parser.parse_temp(combined_raw)
                            if temp then
                                data_modem.mtemp = temp
                                last_good_signal.mtemp = temp
                            end
                            
                            -- CSQ for signal strength & RSSI
                            local csq = combined_raw:match("%+CSQ:%s*(%d+),")
                            if csq then
                                local r = tonumber(csq)
                                if r and r ~= 99 then
                                    data_modem.rssi = tostring(2 * r - 113)
                                    last_good_signal.rssi = data_modem.rssi
                                end
                            end
                        else
                            -- Interleaved/bad response: restore from cache
                            log("Poller: AT response interleaved, using cached signal")
                            if last_good_signal.mode then data_modem.mode = last_good_signal.mode end
                            if last_good_signal.rsrp then data_modem.rsrp = last_good_signal.rsrp end
                            if last_good_signal.rsrq then data_modem.rsrq = last_good_signal.rsrq end
                            if last_good_signal.sinr then data_modem.sinr = last_good_signal.sinr end
                            if last_good_signal.rssi then data_modem.rssi = last_good_signal.rssi end
                            if last_good_signal.mtemp then data_modem.mtemp = last_good_signal.mtemp end
                        end
                        
                        -- Use RSRP for signal percentage if available
                        if data_modem.rsrp and data_modem.rsrp ~= "-" then
                            data_modem.signal = tostring(calculate_signal_strength_rsrp(data_modem.rsrp))
                            last_good_signal.signal = data_modem.signal
                        elseif data_modem.rssi and data_modem.rssi ~= "-" then
                            data_modem.signal = tostring(calculate_signal_strength(data_modem.rssi))
                            last_good_signal.signal = data_modem.signal
                        elseif last_good_signal.signal then
                            data_modem.signal = last_good_signal.signal
                        end
                        
                        release_lock()
                    else
                        -- Lock failed: use cached signal data
                        log("Poller: Failed to acquire modem lock, using cached signal")
                        if last_good_signal.mode then data_modem.mode = last_good_signal.mode end
                        if last_good_signal.rsrp then data_modem.rsrp = last_good_signal.rsrp end
                        if last_good_signal.rsrq then data_modem.rsrq = last_good_signal.rsrq end
                        if last_good_signal.sinr then data_modem.sinr = last_good_signal.sinr end
                        if last_good_signal.rssi then data_modem.rssi = last_good_signal.rssi end
                        if last_good_signal.mtemp then data_modem.mtemp = last_good_signal.mtemp end
                        if last_good_signal.signal then data_modem.signal = last_good_signal.signal end
                    end
                end

            elseif is_fm350 then
                -- === PATH 1: FM350 (XMM Protocol) ===
                local port = get_fm350_port()
                
                -- Initialize data_modem with defaults
                data_modem = {
                    manufacturer="Fibocom", model="FM350-GL", iface="eth2", 
                    mtemp="-", rsrp="-", rsrq="-", sinr="-", rssi="-",
                    state="connected", mode="Unknown", signal="0",
                    operator_name="-", imei="-", firmware="-",
                    wan_ip="Unknown"
                }

                -- Get Real-time Interface Status
                if if_status_raw then
                    local ok, p = pcall(cjson.decode, if_status_raw)
                    if ok and p then
                        if p.up then data_modem.state = "connected" else data_modem.state = "disconnected" end
                        if p.l3_device then data_modem.iface = p.l3_device end
                        if p["ipv4-address"] and p["ipv4-address"][1] then
                            data_modem.wan_ip = p["ipv4-address"][1].address
                        end
                    end
                end

                -- Static Info Fetch (Staggered & Cooldown)
                _G.FM350_STATIC = _G.FM350_STATIC or {}
                _G.FM350_STATIC_RETRY = _G.FM350_STATIC_RETRY or { imei = 0, firmware = 0, operator = 0, own_number = 0 }
                local current_time = os.time()
                
                -- 1. IMEI 
                if (not _G.FM350_STATIC.imei or _G.FM350_STATIC.imei == "-") and (current_time - _G.FM350_STATIC_RETRY.imei > 30) then
                    _G.FM350_STATIC_RETRY.imei = current_time
                    local imei_raw = exec_at_tty(port, "AT+CGSN")
                    if imei_raw then 
                        local imei = imei_raw:match("(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d)")
                        if imei then _G.FM350_STATIC.imei = imei end
                    end
                end

                -- 2. Firmware
                if (not _G.FM350_STATIC.firmware or _G.FM350_STATIC.firmware == "-") and (current_time - _G.FM350_STATIC_RETRY.firmware > 30) then
                    _G.FM350_STATIC_RETRY.firmware = current_time
                    local fw_raw = exec_at_tty(port, "AT+GMR")
                    if fw_raw then
                        local fw = fw_raw:match("Revision: ([%w%.]+)") or fw_raw:match("([%d%.]+%.[%d%.]+)")
                        if fw then _G.FM350_STATIC.firmware = fw end
                    end
                end
                
                -- 3. Operator
                if (not _G.FM350_STATIC.operator_name or _G.FM350_STATIC.operator_name == "-" or _G.FM350_STATIC.operator_name == "" or _G.FM350_STATIC.operator_name:match("^%d+$")) and (current_time - _G.FM350_STATIC_RETRY.operator > 30) then
                    _G.FM350_STATIC_RETRY.operator = current_time
                    exec_at_tty(port, "AT+COPS=3,0")
                    local cops_raw = exec_at_tty(port, "AT+COPS?")
                    if cops_raw then
                        -- Try text format first
                        local op = cops_raw:match('+COPS:.-,.-,"(.-)"')
                        
                        -- Fallback: if numeric (45202 = Vinaphone, 45201 = Mobifone, 45204 = Viettel)
                        if not op or op == "" then
                            local numeric = cops_raw:match('+COPS:.-,(%d+)')
                            if numeric == "45202" then op = "VINAPHONE"
                            elseif numeric == "45204" then op = "Viettel"
                            elseif numeric == "45201" then op = "Mobifone"
                            end
                        end
                        
                        if op and op ~= "" then _G.FM350_STATIC.operator_name = op end
                    end
                end

                -- 4. Phone Number
                if (not _G.FM350_STATIC.own_number or _G.FM350_STATIC.own_number == "-") and (current_time - _G.FM350_STATIC_RETRY.own_number > 30) then
                    _G.FM350_STATIC_RETRY.own_number = current_time
                    local cnum_raw = exec_at_tty(port, "AT+CNUM")
                    local num = fm350_parser.parse_cnum(cnum_raw)
                    if num then _G.FM350_STATIC.own_number = num end
                end

                -- Apply Static Info (Safely from Global variable)
                if _G.FM350_STATIC.imei then data_modem.imei = _G.FM350_STATIC.imei end
                if _G.FM350_STATIC.firmware then data_modem.firmware = _G.FM350_STATIC.firmware end
                if _G.FM350_STATIC.operator_name and _G.FM350_STATIC.operator_name ~= "-" then 
                    data_modem.operator_name = _G.FM350_STATIC.operator_name 
                end
                if _G.FM350_STATIC.own_number then data_modem.own_number = _G.FM350_STATIC.own_number end

                -- FM350: we skip drain/signal if pending to avoid 'xmm' setup conflict
                -- BUT we don't return nil, so the JSON is still written with static info.
                if not is_pending then
                    if acquire_lock() then
                        drain_tty(port)

                        -- Check and enforce CFUN=1 (Standard maintenance)
                        local cfun_state = exec_at_tty(port, "AT+CFUN?")
                        if cfun_state and (cfun_state:find("CFUN: 0") or cfun_state:find("CFUN: 4")) then
                             os.execute("logger -t VWRT_POLLER 'Modem in Low Power Mode. Forcing Online (CFUN=1)...'")
                             exec_at_tty(port, "AT+CFUN=1")
                             os.execute("sleep 2")
                        end

                                -- 1. Signal / Cell Info 
                        local combined_raw = exec_at_tty(port, "AT+GTCCINFO?;+GTCAINFO?;+GTSENRDTEMP=1;+CSQ")
                        local s1 = fm350_parser.parse_all_signal(combined_raw)
                        
                        local got_valid_signal = (s1.rsrp ~= nil or s1.full_mode ~= nil)
                        
                        if got_valid_signal then
                            if s1.full_mode then data_modem.mode = s1.full_mode; last_good_signal.mode = s1.full_mode end
                            if s1.rsrp then data_modem.rsrp = s1.rsrp; last_good_signal.rsrp = s1.rsrp end
                            if s1.rsrq then data_modem.rsrq = s1.rsrq; last_good_signal.rsrq = s1.rsrq end
                            if s1.sinr then data_modem.sinr = s1.sinr; last_good_signal.sinr = s1.sinr end

                            local temp = fm350_parser.parse_temp(combined_raw)
                            if temp then data_modem.mtemp = temp; last_good_signal.mtemp = temp end

                            local csq = combined_raw:match("%+CSQ:%s*(%d+),")
                            if csq then
                                local r = tonumber(csq)
                                if r and r ~= 99 then
                                    data_modem.rssi = tostring(2 * r - 113)
                                    last_good_signal.rssi = data_modem.rssi
                                end
                            end
                        else
                            log("Poller: FM350 AT response interleaved, using cached signal")
                            if last_good_signal.mode then data_modem.mode = last_good_signal.mode end
                            if last_good_signal.rsrp then data_modem.rsrp = last_good_signal.rsrp end
                            if last_good_signal.rsrq then data_modem.rsrq = last_good_signal.rsrq end
                            if last_good_signal.sinr then data_modem.sinr = last_good_signal.sinr end
                            if last_good_signal.rssi then data_modem.rssi = last_good_signal.rssi end
                            if last_good_signal.mtemp then data_modem.mtemp = last_good_signal.mtemp end
                        end
                        
                        if data_modem.rsrp and data_modem.rsrp ~= "-" then
                            data_modem.signal = tostring(calculate_signal_strength_rsrp(data_modem.rsrp))
                            last_good_signal.signal = data_modem.signal
                        elseif data_modem.rssi and data_modem.rssi ~= "-" then
                            data_modem.signal = tostring(calculate_signal_strength(data_modem.rssi))
                            last_good_signal.signal = data_modem.signal
                        elseif last_good_signal.signal then
                            data_modem.signal = last_good_signal.signal
                        end
                        release_lock()
                    else
                        log("Poller: FM350 lock failed, using cached signal")
                        if last_good_signal.mode then data_modem.mode = last_good_signal.mode end
                        if last_good_signal.rsrp then data_modem.rsrp = last_good_signal.rsrp end
                        if last_good_signal.rsrq then data_modem.rsrq = last_good_signal.rsrq end
                        if last_good_signal.sinr then data_modem.sinr = last_good_signal.sinr end
                        if last_good_signal.rssi then data_modem.rssi = last_good_signal.rssi end
                        if last_good_signal.mtemp then data_modem.mtemp = last_good_signal.mtemp end
                        if last_good_signal.signal then data_modem.signal = last_good_signal.signal end
                    end
                end

            else
                -- === PATH 2: EXISTING MODEM MANAGER (Sierra / Dell) ===
                local m_idx = get_current_modem_index()
                local raw_modem = exec("mmcli -m " .. m_idx .. " -J")
                local raw_signal = exec("mmcli -m " .. m_idx .. " --signal-get -J")
                
                data_modem = parse_mmcli_json(raw_modem)
                local signal_data = parse_mmcli_signal(raw_signal)
                
                if not data_modem then
                    data_modem = {
                        operator_name="No Device", mode="No Device", signal="0", manufacturer="-", model="-"
                    }
                end
                
                if data_modem.mode ~= "No Device" then
                    -- 1. Merge basic signal
                    if signal_data.rsrp then data_modem.rsrp = signal_data.rsrp end
                    if signal_data.rsrq then data_modem.rsrq = signal_data.rsrq end
                    if signal_data.sinr then data_modem.sinr = signal_data.sinr end
                    if signal_data.rssi then data_modem.rssi = signal_data.rssi end
    
                    -- 2. DEVICE SPECIFIC LOGIC
                    local is_sierra = (data_modem.manufacturer and data_modem.manufacturer:lower():find("sierra")) or 
                                      (data_modem.model and (data_modem.model:find("EM9191") or data_modem.model:find("EM7455")))
                    
                    local is_dell = (data_modem.model and data_modem.model:find("DW5821e")) or
                                    (data_modem.manufacturer and data_modem.manufacturer:lower():find("dell")) or
                                    (data_modem.hardware_revision and data_modem.hardware_revision:find("DW5821e"))
    
                    if is_sierra then
                        local m_idx = get_current_modem_index()
                        local raw_at = exec("mmcli -m " .. m_idx .. " --command='AT!GSTATUS?' 2>/dev/null")
                        if (not raw_at or raw_at == "") then
                             -- Try to find AT port dynamically or fallback
                             local at_port = get_at_port_from_json(raw_modem) or "/dev/ttyUSB0"
                             local f = io.open(at_port, "r")
                             if f then f:close(); raw_at = exec_at_tty(at_port, "AT!GSTATUS?"); end
                        end
                        local at_data = parse_at_gstatus(raw_at)
                        if at_data.mtemp then data_modem.mtemp = at_data.mtemp end
                        if at_data.rsrp then data_modem.rsrp = at_data.rsrp end
                        if at_data.rsrq then data_modem.rsrq = at_data.rsrq end
                        if at_data.sinr then data_modem.sinr = at_data.sinr end
                        if at_data.rssi then data_modem.rssi = at_data.rssi end
                        if at_data.cell_id then data_modem.cell_id = at_data.cell_id end
                        if at_data.active_band then data_modem.mode = at_data.active_mode .. " | " .. at_data.active_band end
    
                    elseif is_dell then
                        -- === DELL DW5821e LOGIC (Prefer TTY over mmcli) ===
                        local at_port = get_at_port_from_json(raw_modem) or "/dev/ttyUSB1"
                        
                        -- 1. CA / Band Info (AT^CA_INFO?)
                        local raw_ca = exec_at_tty(at_port, "AT^CA_INFO?")
                        local mode_found = false
                        if raw_ca and not raw_ca:match("ERROR") then
                            local ca_data = parse_at_dw5821e_cainfo(raw_ca)
                            if ca_data.active_band then
                                data_modem.mode = ca_data.active_mode .. " | " .. ca_data.active_band
                                mode_found = true
                            end
                        end
                        
                        -- 2. Temp (AT+TEMP)
                        local raw_temp = exec_at_tty(at_port, "AT+TEMP")
                        if raw_temp then
                            local t = parse_at_dw5821e_temp(raw_temp)
                            if t then data_modem.mtemp = t .. " &deg;C" end
                        end
                        
                        -- 3. Fallback to GSTATUS if CA_INFO fails
                        if not mode_found then
                            local raw_stat = exec_at_tty(at_port, "AT!GSTATUS?")
                            if raw_stat and raw_stat:match("GSTATUS") then
                                 local at_data = parse_at_gstatus(raw_stat)
                                 if at_data.active_band then
                                     data_modem.mode = at_data.active_mode .. " | " .. at_data.active_band
                                 end
                            end
                        end
                        
                        -- 4. Fallback Sierra stats for metrics
                        local raw_at = exec_at_tty(at_port, "AT!GSTATUS?")
                        if raw_at and raw_at:find("GSTATUS") then
                             local at_data = parse_at_gstatus(raw_at)
                             if at_data.rsrp then data_modem.rsrp = at_data.rsrp end
                             if at_data.rsrq then data_modem.rsrq = at_data.rsrq end
                             if at_data.sinr then data_modem.sinr = at_data.sinr end
                        end
                    end
    
                    -- 3. Fallback Signal
                    if data_modem.rsrp and data_modem.rsrp ~= "-" then
                        data_modem.signal = tostring(calculate_signal_strength_rsrp(data_modem.rsrp))
                    elseif data_modem.rssi and data_modem.rssi ~= "-" then
                        data_modem.signal = tostring(calculate_signal_strength(data_modem.rssi))
                    end
                    
                    -- 7. Auto Enable if disabled (Only for ModemManager)
                    if data_modem.state == "disabled" then
                        exec("mmcli -m " .. m_idx .. " -e")
                    end
                end
            end

            -- === SHARED LOGIC (PING, LED, WRITE FILE) ===
            if data_modem then
                -- Fallback: If WAN IP is missing (common on DW5821e/Non-MBIM), fetch from interface
                if (not data_modem.wan_ip or data_modem.wan_ip == "-" or data_modem.wan_ip == "Unknown") and data_modem.iface then
                     local ip = get_interface_ip(data_modem.iface)
                     if ip then data_modem.wan_ip = ip end
                end

                -- 4. Ping (Strictly tied to modem interface with IP)
                if data_modem.iface and data_modem.wan_ip and data_modem.wan_ip ~= "Unknown" then
                    local ping_cmd = "ping -c 1 -W 1 -I " .. data_modem.iface .. " 8.8.8.8 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}'"
                    local p = io.popen(ping_cmd)
                    if p then
                        local p_val = p:read("*a"); p:close()
                        if p_val and p_val ~= "" then data_modem.ping = p_val:gsub("\n", "") end
                    end
                else
                    data_modem.ping = "-"
                end
                
                -- 5. Data Usage (Using dynamic iface)
                local net_stats = get_net_stats(data_modem.iface)
                data_modem.rx = net_stats.rx
                data_modem.tx = net_stats.tx

                local json_str = cjson.encode(data_modem)
                write_file(TEMP_FILE, json_str)
                os.rename(TEMP_FILE, CACHE_FILE)

                -- 6. Smart LED Logic (LED follows internet connection/ping)
                pcall(apply_auto_led, data_modem.mode, data_modem.ping, data_modem.iface, data_modem.state)
            end
        end)
        if not status then
            os.execute("logger -t VWRT_POLLER_ERR 'Loop Error: " .. tostring(err):gsub("'", "") .. "'")
        end
        end
        
        -- Auto signal setup only for MM
        if not is_xmm_mode() and not is_qmodem_mode() then
            local check_f = io.open(CACHE_FILE, "r")
            if check_f then
                local c = check_f:read("*all"); check_f:close()
                if c and (string.find(c, '"signal":"0"') or string.find(c, '"rsrp":"-"')) then
                     local m_idx = get_current_modem_index()
                     exec("mmcli -m " .. m_idx .. " --signal-setup=1")
                end
            end
        end
        
        -- Re-check mode for sleep time (Variable scope fix)
        local sleep_time = (is_xmm_mode() or is_qmodem_mode()) and 15 or 5
        os.execute("sleep " .. sleep_time)
    end
end

main()