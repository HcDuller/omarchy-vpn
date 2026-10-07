# VPN

An Omarchy Quattro shell plugin to manage OpenVPN connections from the bar:
connect/disconnect existing profiles, create new ones by hand, or import an
existing `.ovpn` file.

## Install

```sh
omarchy plugin add https://github.com/HcDuller/omarchy-vpn.git --enable
```

## Requirements

- **[flea](https://github.com/thisisgm/flea)** provides the file picker for
  "Import .ovpn File…" and the certificate "Browse…" buttons. It is a required
  dependency: if it is missing, the plugin opens a terminal running
  `omarchy pkg aur add flea-bin` (so you can type your sudo password) and keeps
  file picking disabled until the install finishes. Only flea's picker backend
  is enabled (`flea --picker`); your default file manager is never changed. To
  undo it later: `flea --picker off`.

- `networkmanager-openvpn` (NetworkManager's OpenVPN plugin) and `openvpn`
  itself — both already provide the `nmcli` integration this plugin drives.
- `/usr/bin/python3` with `gi`/GTK 3 bindings (`python-gobject`, already pulled in by
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

## Authentication at connect

If a profile uses a username/password and no password is stored, clicking
Connect opens an inline prompt under the row with an editable username
(prefilled from the profile), a password field, and a **Save password**
toggle. Credentials go to `nmcli` through a private `0600` passwd-file, so
NetworkManager never falls back to a desktop secret agent: a wrong password
fails once, shows the error inline, and the prompt stays open until you retry
or cancel (Escape / Cancel). Nothing retries on its own.

With **Save password** off the password is used once and never stored. Profiles
with autoconnect enabled should save the password, otherwise NetworkManager
will ask a secret agent when it connects on its own.

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
- `omarchy-vpn-pick-file` — `FileChooserNative` forced through xdg-desktop-portal (`GTK_USE_PORTAL=1`), which is how flea's picker is shown.
- `omarchy-vpn-picker` — checks/installs flea and makes it the portal FileChooser.
- `omarchy-vpn-import` — runs the picker, then `nmcli connection import`.

## Known limitations

- The manual form does not attempt to reproduce every OpenVPN client
  directive — anything read from an existing profile that the form doesn't
  have a dedicated control for is preserved in the "Custom fields" list under
  Advanced rather than dropped.

## License

MIT — see [LICENSE](LICENSE).
