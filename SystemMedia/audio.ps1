<#
    audio.ps1 - helper for the "System Media" Unified Remote (Windows).

    Provides precise system volume + mute via the Windows Core Audio API
    (IAudioEndpointVolume) and system-wide now-playing via the GSMTC WinRT API
    (GlobalSystemMediaTransportControlsSessionManager). No installed modules or
    external binaries required - only built-in Windows APIs + PowerShell.

    For efficiency the Core Audio C# is compiled ONCE to a cached DLL in
    %LOCALAPPDATA%\UnifiedRemote\SystemMedia\audio.dll and loaded thereafter,
    so repeated polls do not recompile.

    Invoked by remote.lua as:  & 'audio.ps1' -Cmd <cmd> [-Value <n>]
      -Cmd getstate     -> prints one line of compact JSON:
                           {"volume":<0-100>,"muted":<bool>,"title":"",
                            "artist":"","app":"","status":"playing|paused|stopped"}
      -Cmd setvol -Value <0-100>
      -Cmd mute | unmute | togglemute

    Use Windows PowerShell 5.1 (powershell.exe) - GSMTC WinRT async is most
    reliable there.
#>
param(
    [string]$Cmd = "getstate",
    [double]$Value = 0
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Core Audio: compile the COM interop to a cached DLL once, then load it.
# ---------------------------------------------------------------------------
$cacheDir = Join-Path $env:LOCALAPPDATA "UnifiedRemote\SystemMedia"
$dllPath  = Join-Path $cacheDir "audio.dll"
if (-not (Test-Path $cacheDir)) {
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
}

if (-not (Test-Path $dllPath)) {
    $csharp = @'
using System;
using System.Runtime.InteropServices;
namespace NativeAudio
{
    enum EDataFlow
    {
        eRender,
        eCapture,
        eAll
    }
    enum ERole
    {
        eConsole,
        eMultimedia,
        eCommunications
    }
    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        int Activate(
            ref Guid id,
            int clsCtx,
            IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer
        );
    }
    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(
            EDataFlow dataFlow,
            uint deviceState,
            out object devices
        );
        int GetDefaultAudioEndpoint(
            EDataFlow dataFlow,
            ERole role,
            out IMMDevice endpoint
        );
    }
    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator
    {
    }
    [ComImport]
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        int RegisterControlChangeNotify(IntPtr notify);
        int UnregisterControlChangeNotify(IntPtr notify);
        int GetChannelCount(out uint channelCount);
        int SetMasterVolumeLevel(float levelDb, Guid eventContext);
        int SetMasterVolumeLevelScalar(float level, Guid eventContext);
        int GetMasterVolumeLevel(out float levelDb);
        int GetMasterVolumeLevelScalar(out float level);
        int SetChannelVolumeLevel(uint channel, float levelDb, Guid eventContext);
        int SetChannelVolumeLevelScalar(uint channel, float level, Guid eventContext);
        int GetChannelVolumeLevel(uint channel, out float levelDb);
        int GetChannelVolumeLevelScalar(uint channel, out float level);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, Guid eventContext);
        int GetMute(out bool mute);
        int GetVolumeStepInfo(out uint step, out uint stepCount);
        int VolumeStepUp(Guid eventContext);
        int VolumeStepDown(Guid eventContext);
        int QueryHardwareSupport(out uint hardwareSupportMask);
        int GetVolumeRange(
            out float volumeMinDb,
            out float volumeMaxDb,
            out float volumeIncrementDb
        );
    }
    public static class Audio
    {
        static IAudioEndpointVolume GetEndpoint()
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            IMMDevice device;
            Marshal.ThrowExceptionForHR(
                enumerator.GetDefaultAudioEndpoint(
                    EDataFlow.eRender,
                    ERole.eMultimedia,
                    out device
                )
            );
            Guid interfaceId = typeof(IAudioEndpointVolume).GUID;
            object endpoint;
            Marshal.ThrowExceptionForHR(
                device.Activate(ref interfaceId, 23, IntPtr.Zero, out endpoint)
            );
            return (IAudioEndpointVolume)endpoint;
        }
        public static float GetVolume()
        {
            float level;
            Marshal.ThrowExceptionForHR(GetEndpoint().GetMasterVolumeLevelScalar(out level));
            return level * 100;
        }
        public static void SetVolume(double percent)
        {
            percent = Math.Max(0, Math.Min(100, percent));
            Marshal.ThrowExceptionForHR(
                GetEndpoint().SetMasterVolumeLevelScalar((float)(percent / 100), Guid.Empty)
            );
        }
        public static bool GetMute()
        {
            bool muted;
            Marshal.ThrowExceptionForHR(GetEndpoint().GetMute(out muted));
            return muted;
        }
        public static void SetMute(bool muted)
        {
            Marshal.ThrowExceptionForHR(GetEndpoint().SetMute(muted, Guid.Empty));
        }
        public static void ToggleMute()
        {
            SetMute(!GetMute());
        }
    }
}
'@
    Add-Type -TypeDefinition $csharp -OutputAssembly $dllPath | Out-Null
}

if (-not ('NativeAudio.Audio' -as [type])) {
    Add-Type -Path $dllPath | Out-Null
}

# ---------------------------------------------------------------------------
# System-wide now-playing via GSMTC (WinRT). Returns a hashtable; never throws.
# ---------------------------------------------------------------------------
function Get-NowPlaying {
    $result = @{ title = ""; artist = ""; app = ""; status = "stopped" }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue

        $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]

        function Await($op, $type) {
            $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
            [void]$task.Wait(2000)
            $task.Result
        }

        [void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]

        $mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) `
                     ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        $session = $mgr.GetCurrentSession()
        if ($null -ne $session) {
            $props = Await ($session.TryGetMediaPropertiesAsync()) `
                           ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
            $result.title  = [string]$props.Title
            $result.artist = [string]$props.Artist
            $result.app    = [string]$session.SourceAppUserModelId
            switch ([string]$session.GetPlaybackInfo().PlaybackStatus) {
                "Playing" { $result.status = "playing" }
                "Paused"  { $result.status = "paused" }
                default   { $result.status = "stopped" }
            }
        }
    } catch { }
    return $result
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
switch ($Cmd.ToLower()) {
    "setvol"     { [NativeAudio.Audio]::SetVolume($Value) }
    "mute"       { [NativeAudio.Audio]::SetMute($true) }
    "unmute"     { [NativeAudio.Audio]::SetMute($false) }
    "togglemute" { [NativeAudio.Audio]::ToggleMute() }
    "getstate"   {
        $np = Get-NowPlaying
        $state = [ordered]@{
            volume = [int][Math]::Round([NativeAudio.Audio]::GetVolume())
            muted  = [bool][NativeAudio.Audio]::GetMute()
            title  = $np.title
            artist = $np.artist
            app    = $np.app
            status = $np.status
        }
        $state | ConvertTo-Json -Compress
    }
    default { }
}
