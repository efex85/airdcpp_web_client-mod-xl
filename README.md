# AirDC++ Web Client mod-xl

A Docker image of AirDC++ Web Client that contains, on top of the stock client:

1. **Multi-select** in the web UI (filelists, queue, search) – `webui-*.patch`
2. **Dark mode CSS** injected into the web UI – `dark.css`, `inject-css.js`
3. **Hub user commands** in the hub and user-list menus (what the Windows client shows when you
   right-click a hub or a user) – `daemon-hubcommands.patch`


## What is different from the plain build

The hub user commands feature is a **daemon** change (C++), not a web UI change. The web UI already asks
the daemon for the `hub` and `hub_user` menus, so the commands show up without any web UI changes.
That means the image **cannot use the official release tarball**: the Dockerfile builds the daemon from
source (Ubuntu 24.04, the platform upstream's CI uses) with the patch applied, and assembles the same layout
as the official portable package (`airdcppd`, `dcppboot.xml`, `web-resources/`).

Because of that, versions are **pinned** in the Dockerfile instead of following the newest release:

| What        | Pinned to                                                                       |
|-------------|----------------------------------------------------------------------------------|
| Daemon      | `daemon_ref` = `e330cf88…` (version string `2.14.1b-91`)                          |
| Web UI      | `webui_ref` = `eeeea502…` (2.14.1-beta.3)                                         |

The built daemon reports its version with a `-d` suffix (e.g. `2.14.1b-91-ge330-d`), which is git's
"modified working tree" marker – it is how you can tell this build from an unmodified one.

## How the feature behaves

- Commands come from hubs (sent by the hub) and from the user's own saved commands, filtered for the hub
  exactly like the Windows client does (all hubs / a specific hub / `op` hubs, NMDC vs ADC).
- They appear as a **Hub commands** entry in the hub menu (hub-context commands) and in the user menu in
  the user list (user-context commands). Names containing `/` become submenus.
- `%[line:Label]` and `%[kickline:Label]` prompts become input fields in a dialog. A prompt used more than
  once in a command asks only once. Fields may be left empty.
- Clicking sends the command through the daemon's own user command code (`sendUserCmd`), the same path
  the Windows client uses. The command id sent by the browser is re-checked against the commands that are
  actually available for that hub, so a forged id for another hub's command is ignored.

### Not included

- Search-result and filelist context commands (only the hub and user-list contexts are wired).
- Separators are skipped (the menu API has no separator item).

## Files

| File                          | Purpose                                                                |
|-------------------------------|------------------------------------------------------------------------|
| `Dockerfile`                  | web UI build → daemon build → runtime image                            |
| `daemon-hubcommands.patch`    | the daemon change (new `HubCommandMenuProvider` + 2 small edits)       |
| `webui-*.patch`               | multi-select patches for the web UI (same as the multi-select project) |
| `dark.css`, `inject-css.js`   | dark mode                                                              |
| `entrypoint.sh`, `.airdcpp/`  | container entrypoint and default config                                |
| `build.sh`                    | local build                                                            |
