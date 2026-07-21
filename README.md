# ur-remotes

Custom [Unified Remote](https://www.unifiedremote.com/) remotes.

Each remote is a folder containing a `meta.prop`, `remote.lua`, `layout.xml`, and
icon(s). Install by copying a folder into the Unified Remote server's custom remotes
directory, then enable it in the server manager (**Manage → Remotes**).

## Remotes

- **DisplayFusion** — DisplayFusion profile switcher (`Me.DisplayFusion`).
- **SystemMedia** — System-wide media transport + precise volume/mute + live
  now-playing (`Me.System Media`). Windows only. Uses the Windows Core Audio API
  (`IAudioEndpointVolume`) and the GSMTC WinRT API via `audio.ps1` — no external
  binary or installed module required.

## References

- **Built-in remotes:** https://github.com/unifiedremote/Remotes
- **API documentation:** https://github.com/unifiedremote/Docs
