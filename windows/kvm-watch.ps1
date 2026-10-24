# kvm-watch.ps1 - Windows side of kvm-ddc-switcher.
#
# Watches for the KVM USB hub (VID_1A40&PID_0801) leaving this machine.
# When the KVM is switched away from Windows, this machine is still the
# active monitor input, so we send DDC/CI VCP 0x60 to move the monitor
# back to the Mac input (default DP1 = 15).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\kvm-watch.ps1            # watch (foreground)
#   powershell -ExecutionPolicy Bypass -File .\kvm-watch.ps1 -Probe     # diagnostics, then exit
#   powershell -ExecutionPolicy Bypass -File .\kvm-watch.ps1 -DryRun    # log only, no DDC write
#   powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File .\kvm-watch.ps1
#
# Runs as a normal user (no admin needed). DDC handles only exist in a
# session that owns the desktop with the monitor attached - run it in the
# logged-in desktop session, not in a service/SSH-only session.

param(
    [switch]$Probe,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$DIR = $PSScriptRoot

# --- defaults (mirror macos/config.env); windows/config.ps1 overrides ---
$KVM_HWID_PREFIX = "USB\VID_1A40&PID_0801"   # hardware-ID prefix of the KVM USB hub
$MONITOR_NAME    = ""                         # substring of monitor desc; empty = every monitor
$POLL_INTERVAL   = 0.5                        # seconds between hub presence polls
$STABLE_SAMPLES  = 2                          # consecutive same readings before acting
$DRY_RUN         = 0                          # 1 = log only, no DDC write
$MAC_INPUT       = 15                         # DDC VCP 0x60 value for DP1
$LOG             = Join-Path $DIR "logs\kvm-auto-switch.log"

$CONFIG = Join-Path $DIR "config.ps1"
if (Test-Path -LiteralPath $CONFIG) { . $CONFIG }
if ($DryRun) { $DRY_RUN = 1 }

$logDir = Split-Path -Parent $LOG
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

function Write-Log([string]$Message) {
    $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $Message
    Add-Content -LiteralPath $LOG -Value $line -Encoding UTF8
    Write-Host $line
}

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class KvmNative
{
    // ---------- DDC/CI via dxva2 ----------

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, IntPtr lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool DestroyPhysicalMonitors(uint count, [In] PHYSICAL_MONITOR[] monitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool SetVCPFeature(IntPtr hMonitor, byte code, uint value);

    [DllImport("dxva2.dll", SetLastError = true)]
    private static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hMonitor, byte code, out int vcpType, out uint current, out uint max);

    private const byte VCP_INPUT_SOURCE = 0x60;

    private static IntPtr[] EnumHMonitors()
    {
        System.Collections.Generic.List<IntPtr> list = new System.Collections.Generic.List<IntPtr>();
        MonitorEnumProc cb = delegate(IntPtr hm, IntPtr hdc, IntPtr rect, IntPtr data)
        {
            list.Add(hm);
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        GC.KeepAlive(cb);
        return list.ToArray();
    }

    // One line per physical monitor: desc, hmonitor, current input source (VCP 0x60).
    public static string[] GetMonitorsInfo()
    {
        System.Collections.Generic.List<string> lines = new System.Collections.Generic.List<string>();
        IntPtr[] hmons = EnumHMonitors();
        foreach (IntPtr hm in hmons)
        {
            uint count;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out count) || count == 0) continue;
            PHYSICAL_MONITOR[] pms = new PHYSICAL_MONITOR[count];
            if (!GetPhysicalMonitorsFromHMONITOR(hm, count, pms)) continue;
            try
            {
                foreach (PHYSICAL_MONITOR pm in pms)
                {
                    int vcpType;
                    uint current, max;
                    bool ok = GetVCPFeatureAndVCPFeatureReply(pm.hPhysicalMonitor, VCP_INPUT_SOURCE, out vcpType, out current, out max);
                    lines.Add("desc=\"" + pm.szPhysicalMonitorDescription + "\" hmon=0x" + hm.ToInt64().ToString("X") +
                              " input=" + (ok ? current.ToString() : "n/a"));
                }
            }
            finally
            {
                DestroyPhysicalMonitors(count, pms);
            }
        }
        return lines.ToArray();
    }

    public static string SetInputForMonitor(string nameContains, uint value)
    {
        IntPtr[] hmons = EnumHMonitors();
        if (hmons.Length == 0) return "FAIL: no display monitors visible in this session";

        int matched = 0;
        int enumFails = 0;
        int lastEnumErr = 0;
        StringBuilder sb = new StringBuilder();
        foreach (IntPtr hm in hmons)
        {
            uint count;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out count))
            {
                lastEnumErr = Marshal.GetLastWin32Error();
                enumFails++;
                continue;
            }
            if (count == 0) continue;

            PHYSICAL_MONITOR[] pms = new PHYSICAL_MONITOR[count];
            if (!GetPhysicalMonitorsFromHMONITOR(hm, count, pms))
            {
                lastEnumErr = Marshal.GetLastWin32Error();
                enumFails++;
                continue;
            }
            try
            {
                foreach (PHYSICAL_MONITOR pm in pms)
                {
                    string desc = pm.szPhysicalMonitorDescription ?? "";
                    if (nameContains != null && nameContains.Length > 0 &&
                        desc.IndexOf(nameContains, StringComparison.OrdinalIgnoreCase) < 0)
                        continue;

                    matched++;
                    bool ok = SetVCPFeature(pm.hPhysicalMonitor, VCP_INPUT_SOURCE, value);
                    int err = Marshal.GetLastWin32Error();
                    int vcpType;
                    uint current, max;
                    bool readOk = GetVCPFeatureAndVCPFeatureReply(pm.hPhysicalMonitor, VCP_INPUT_SOURCE, out vcpType, out current, out max);
                    sb.Append("monitor=\"" + desc + "\" set=" + (ok ? "ok" : "fail(err=" + err + ")") +
                              " readback=" + (readOk ? current.ToString() : "n/a") + "; ");
                }
            }
            finally
            {
                DestroyPhysicalMonitors(count, pms);
            }
        }

        if (matched == 0)
        {
            if (enumFails > 0)
                return "FAIL: physical-monitor enumeration failed on " + enumFails + " monitor(s), lastErr=" + lastEnumErr;
            return "NOTFOUND: no monitor matching \"" + nameContains + "\"";
        }
        return "OK " + sb.ToString().Trim();
    }

    // ---------- KVM hub presence via SetupAPI ----------

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    private const uint DIGCF_PRESENT = 0x02;
    private const uint DIGCF_ALLCLASSES = 0x04;
    private const uint SPDRP_DEVICEDESC = 0x00;
    private const uint SPDRP_HARDWAREID = 0x01;

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(IntPtr classGuid, string enumerator, IntPtr hwndParent, uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInfo(IntPtr devInfoSet, uint memberIndex, ref SP_DEVINFO_DATA devInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetDeviceRegistryProperty(IntPtr devInfoSet, ref SP_DEVINFO_DATA devInfoData, uint property, out uint propertyRegDataType, [Out] byte[] propertyBuffer, uint propertyBufferSize, out uint requiredSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr devInfoSet);

    private static string GetDevProperty(IntPtr set, ref SP_DEVINFO_DATA dev, uint property)
    {
        byte[] buf = new byte[2048];
        uint regType, needed;
        if (!SetupDiGetDeviceRegistryProperty(set, ref dev, property, out regType, buf, (uint)buf.Length, out needed))
            return null;
        int len = (int)Math.Min(needed, (uint)buf.Length);
        return Encoding.Unicode.GetString(buf, 0, len).TrimEnd('\0');
    }

    // True if any present device on the USB enumerator has a hardware ID
    // starting with hwidPrefix (e.g. "USB\VID_1A40&PID_0801").
    public static bool KvmHubPresent(string hwidPrefix)
    {
        if (hwidPrefix == null || hwidPrefix.Length == 0) return false;

        IntPtr set = SetupDiGetClassDevs(IntPtr.Zero, "USB", IntPtr.Zero, DIGCF_PRESENT | DIGCF_ALLCLASSES);
        if (set == new IntPtr(-1)) return false;

        try
        {
            SP_DEVINFO_DATA dev = new SP_DEVINFO_DATA();
            dev.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));

            for (uint i = 0; ; i++)
            {
                if (!SetupDiEnumDeviceInfo(set, i, ref dev)) break;

                string hwid = GetDevProperty(set, ref dev, SPDRP_HARDWAREID);
                if (hwid == null) continue;

                string[] ids = hwid.Split('\0');
                foreach (string id in ids)
                {
                    if (id.Length > 0 && id.StartsWith(hwidPrefix, StringComparison.OrdinalIgnoreCase))
                        return true;
                }
            }
            return false;
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(set);
        }
    }

    // All present devices on the USB enumerator, for diagnostics:
    // "description | first hardware id".
    public static string[] ListUsbDevices()
    {
        System.Collections.Generic.List<string> lines = new System.Collections.Generic.List<string>();

        IntPtr set = SetupDiGetClassDevs(IntPtr.Zero, "USB", IntPtr.Zero, DIGCF_PRESENT | DIGCF_ALLCLASSES);
        if (set == new IntPtr(-1)) return lines.ToArray();

        try
        {
            SP_DEVINFO_DATA dev = new SP_DEVINFO_DATA();
            dev.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));

            for (uint i = 0; ; i++)
            {
                if (!SetupDiEnumDeviceInfo(set, i, ref dev)) break;

                string desc = GetDevProperty(set, ref dev, SPDRP_DEVICEDESC);
                string hwid = GetDevProperty(set, ref dev, SPDRP_HARDWAREID);

                string firstHwid = "";
                if (hwid != null)
                {
                    string[] ids = hwid.Split('\0');
                    foreach (string id in ids)
                    {
                        if (id.Length > 0) { firstHwid = id; break; }
                    }
                }
                lines.Add((desc ?? "?") + " | " + firstHwid);
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(set);
        }
        return lines.ToArray();
    }
}
'@

function Test-KvmPresent {
    [KvmNative]::KvmHubPresent($KVM_HWID_PREFIX)
}

if ($Probe) {
    $sid = (Get-Process -Id $PID).SessionId
    Write-Log ("PROBE ps=" + $PSVersionTable.PSVersion.ToString() + " session=" + $sid +
               " hubPresent=" + (Test-KvmPresent) + " hwid=" + $KVM_HWID_PREFIX)

    $mons = [KvmNative]::GetMonitorsInfo()
    if ($mons.Count -eq 0) {
        Write-Log "PROBE no physical monitors visible in this session (no display attached, or non-interactive session?)"
    } else {
        foreach ($m in $mons) { Write-Log ("PROBE monitor " + $m) }
    }

    if (-not (Test-KvmPresent)) {
        Write-Log "PROBE KVM hub not found; present USB devices (description | first hardware id):"
        foreach ($d in [KvmNative]::ListUsbDevices()) { Write-Log ("PROBE usb " + $d) }
    }
    exit 0
}

Write-Log ("kvm-watch (windows) start: hwid=" + $KVM_HWID_PREFIX + " monitor=" + $MONITOR_NAME +
           " macInput=" + $MAC_INPUT + " poll=" + $POLL_INTERVAL + "s stable=" + $STABLE_SAMPLES +
           " dryRun=" + $DRY_RUN)
foreach ($m in [KvmNative]::GetMonitorsInfo()) { Write-Log ("monitor at start: " + $m) }

# Same debounced state machine as macos/kvm-watch.sh: act only on a
# confirmed present -> absent transition; initial state never triggers.
$lastState = $null
$pendingState = $null
$pendingCount = 0

while ($true) {
    if (Test-KvmPresent) { $current = "present" } else { $current = "absent" }

    if ($current -ne $lastState) {
        if ($current -eq $pendingState) {
            $pendingCount++
        } else {
            $pendingState = $current
            $pendingCount = 1
        }

        if ($pendingCount -ge $STABLE_SAMPLES) {
            if ($null -eq $lastState) {
                Write-Log ("KVM initial state: " + $current + " (no action)")
            } elseif ($current -eq "absent") {
                Write-Log ("KVM left Windows (present -> absent); switching monitor to Mac input " + $MAC_INPUT)
                if ($DRY_RUN -eq 1) {
                    Write-Log ("DRY_RUN: would switch display to Mac input " + $MAC_INPUT)
                } else {
                    $result = [KvmNative]::SetInputForMonitor($MONITOR_NAME, [uint32]$MAC_INPUT)
                    Write-Log ("DDC set input " + $MAC_INPUT + " result=" + $result)
                }
            } else {
                Write-Log "KVM returned to Windows (absent -> present); no DDC action"
            }
            $lastState = $current
            $pendingState = $null
            $pendingCount = 0
        }
    } else {
        $pendingState = $null
        $pendingCount = 0
    }

    Start-Sleep -Milliseconds ([int]($POLL_INTERVAL * 1000))
}