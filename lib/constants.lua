#!/usr/bin/lua
-- ============================================
-- NTC_WRT Constants Library
-- ============================================
-- Centralized configuration for all file paths,
-- cache locations, and system constants.
-- This prevents hardcoding and makes maintenance easier.

local M = {}

M.VERSION = "1.1.2"

-- ============================================
-- FILE PATHS
-- ============================================
M.PATHS = {
    -- Cache Files (Temporary data storage)
    MOBILE_CACHE      = "/tmp/NTC_WRT_mobile.json",
    MOBILE_CACHE_TEMP = "/tmp/NTC_WRT_mobile_temp.json",
    SYSTEM_CACHE      = "/tmp/sysinfo_output.json",
    SMS_CACHE         = "/tmp/NTC_WRT_sms.json",
    SMS_ARCHIVE       = "/overlay/NTC_WRT_sms_archive.json",
    CPU_STAT          = "/tmp/cpu_last_stat",
    
    -- Configuration Files
    LED_CONFIG      = "/etc/NTC_WRT_led.json",
    AUTO_LED_CONFIG = "/etc/NTC_WRT_autoled.json",
    CLIENTS_CONFIG  = "/etc/config/NTC_WRT",
    
    -- Lock Files
    MODEM_AT_LOCK   = "/tmp/modem_at.lock",
    
    -- System Info
    SYSINFO_MODEL   = "/tmp/sysinfo/model",
}

return M
