# VPN

An Omarchy Quattro shell plugin to manage OpenVPN connections from the bar:
connect/disconnect existing profiles, create new ones by hand, or import an
existing `.ovpn` file.

## Install

```sh
omarchy plugin add https://github.com/HcDuller/omarchy-vpn.git --enable
```

## Requirements

- `networkmanager-openvpn` (NetworkManager's OpenVPN plugin) and `openvpn`
  itself — both already provide the `nmcli` integration this plugin drives.
- `python3` with `gi`/GTK 3 bindings (`python-gobject`, already pulled in by
  `xdg-desktop-portal-gtk` on most Omarchy installs) for the native
  "Import .ovpn File…" file picker.

## What it does

- Bar icon: a lock/shield glyph with a small colored status badge —
  gray (idle), yellow (connecting), green (connected), red (error).
  Hover shows "VPN"; click opens the panel.
- Panel: lists every OpenVPN connection profile NetworkManager knows about.
  Each row shows a provider-name square (first two letters of the connection
  name, colored by its own state), the connection name/status, and
  connect/disconnect, edit, and delete icon buttons.
- "New Connection" opens a form to either:
  - fill in the fields by hand — server address(es) (OpenVPN allows more than
    one `remote`, so the form lets you add/remove as many as you need), port,
    protocol, auth mode, certificates, username/password, plus a collapsible
    "Advanced" section for cipher/digest/TLS-auth/compression/custom
    `vpn.data` fields, or
  - "Import .ovpn File…", which opens a native file picker, imports the file
    via `nmcli connection import type openvpn`, then reopens the same form
    pre-filled with everything NetworkManager parsed out of it, so it can be
    reviewed or edited before saving.

## Configure

```sh
omarchy bar move io.github.hcduller.vpn --section right
```

## Remove

```sh
omarchy plugin remove io.github.hcduller.vpn
```

## Backend

All NetworkManager access happens through the helper scripts in `bin/`,
following the same "shell out to a small script" convention the built-in
network/bluetooth/tailscale plugins use — this plugin has no direct D-Bus/NM
bindings of its own:

- `omarchy-vpn-status` — lists connection profiles + live state.
- `omarchy-vpn-read <uuid>` — dumps a profile's fields for the edit form.
- `omarchy-vpn-save` — creates/updates a profile from JSON on stdin (secrets
  go through `nmcli connection edit`'s interactive stdin, never argv/`ps`).
- `omarchy-vpn-connect` / `omarchy-vpn-disconnect` / `omarchy-vpn-delete` —
  thin `nmcli connection up/down/delete` wrappers.
- `omarchy-vpn-pick-file` — GTK `FileChooserNative` file picker.
- `omarchy-vpn-import` — runs the picker, then `nmcli connection import`.

## Known limitations

- The manual form does not attempt to reproduce every OpenVPN client
  directive — anything read from an existing profile that the form doesn't
  have a dedicated control for is preserved in the "Custom fields" list under
  Advanced rather than dropped.

## License

MIT — see [LICENSE](LICENSE).
