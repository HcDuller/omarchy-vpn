# VPN

An [Omarchy](https://omarchy.org) Quattro shell plugin that manages OpenVPN
connections from the bar. It drives NetworkManager (`nmcli`), so every profile
you create here also shows up in `nmcli`, `nm-connection-editor` and the rest of
the system.

- **Status at a glance:** a shield icon in the bar with a color-coded badge:
  gray (idle), yellow (connecting), green (connected), red (error). The tooltip
  reads "VPN".
- **Connection list:** every OpenVPN profile with its state, plus one-click
  connect/disconnect, edit and delete.
- **Create or edit profiles:** servers, port, protocol, authentication mode,
  certificates, credentials and advanced OpenVPN options, all in a form.
- **Multiple servers:** add as many `remote` server addresses as the profile
  needs, one row each.
- **Import `.ovpn` files:** pick a file with the flea file picker, review what
  was parsed, and save.
- **Credentials at connect time:** an inline prompt asks for username and
  password when none is saved, with an optional **Save password** toggle. A
  wrong password fails once and never loops.
- **Notifications:** desktop notifications when a connection is established
  and when it drops unexpectedly. Disconnecting yourself stays quiet.
- **Always up to date:** the badge and list follow NetworkManager, including
  changes made outside the plugin, even with the panel closed.

## Screenshots

| Connection list | Connect prompt |
|---|---|
| ![Connection list](docs/images/connections.png) | ![Connect prompt](docs/images/connect-prompt.png) |

| Editing a connection | Advanced options |
|---|---|
| ![Editing a connection](docs/images/edit.png) | ![Advanced options](docs/images/edit-advanced.png) |

Importing a `.ovpn` file opens the picker next to the panel (flea's when installed, shown here):

![Importing a .ovpn file](docs/images/import.png)

## Install

```sh
omarchy plugin add https://github.com/HcDuller/omarchy-vpn.git --enable
```

## Requirements

- **[flea](https://github.com/thisisgm/flea)** is an *optional* file picker
  (recommended). With flea available, "Import .ovpn File…" and the
  certificate **Browse** buttons open flea's picker; without it, the standard
  system file dialog is used. On the first pick on a machine without flea the
  panel asks once: **Install flea** (a terminal opens running
  `omarchy pkg aur add flea-bin` for the sudo password) or **Use system
  picker**. The choice is remembered in
  `~/.local/state/omarchy-vpn/picker-choice`; delete that file to be asked
  again.

  The plugin never changes which file picker other applications use — flea is
  invoked directly through its portal backend, not claimed globally. Making
  flea the desktop-wide chooser (and undoing it) is flea's own feature:
  `flea --picker` / `flea --picker off`.

- `networkmanager-openvpn` (NetworkManager's OpenVPN plugin) and `openvpn`
  itself — both already provide the `nmcli` integration this plugin drives.
- `/usr/bin/python3` with `gi`/GTK 3 and Gio D-Bus bindings (`python-gobject`, already pulled in by `xdg-desktop-portal-gtk` on most Omarchy installs). Both picker backends run through it.

## Using it

- **Connect / disconnect:** the play/disconnect icon on a row, or click the row.
  Rows show a two-letter square colored by state, and the name with its status.
- **New connection:** the **New Connection** button opens the form. Fill it in
  by hand, or use **Import .ovpn File…** to start from an existing config.
- **Edit:** the pencil icon opens the same form pre-filled from the profile.
  Leave the password blank to keep the stored one. **Save** shows a brief
  "Saved" and stays on the form; **Cancel** or Escape returns to the list.
- **Delete:** the trash icon, with a confirmation.
- **Server addresses:** the form has one row per server (address, port, UDP or
  TCP). Use **Add server address** and the remove icon to manage them. Imported
  configs with several `remote` lines show one row each.
- **Authentication modes:** certificates only, username and password, or both.
  Certificate, key and TLS key fields have a **Browse** button (flea's picker).
- **Advanced:** cipher, auth digest, device type (TUN/TAP), TLS auth/crypt key
  and direction, compression, and free-form custom `vpn.data` fields. Anything
  in an existing profile that the form has no control for is kept under
  **Custom fields**, never dropped.
- **Refresh:** the plugin polls NetworkManager every 5 seconds by default
  (`refreshIntervalSec`, 2 to 60).

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
- `omarchy-vpn-pick-file` — file dialog with two backends: `flea` (flea's portal backend called directly over D-Bus, no global claim) and `system` (standard GTK dialog).
- `omarchy-vpn-picker` — records the pick choice (`decline`) and coordinates the flea install prompt.
- `omarchy-vpn-notify` — de-duplicated desktop notifications (the plugin runs once per monitor).
- `omarchy-vpn-set-username` / `omarchy-vpn-store-secret` — update a profile's username or saved password without rewriting the rest of it.
- `omarchy-vpn-import` — runs the picker, then `nmcli connection import`.

## Known limitations

- OpenVPN only. WireGuard and other VPN types are not managed here.
- The form covers the common OpenVPN options; anything else is preserved as
  custom fields rather than given a dedicated control.
- Desktop notifications use the `network-vpn-symbolic` icon through
  `notify-send`.

## License

MIT — see [LICENSE](LICENSE).
