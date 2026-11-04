<div align="center">

<img src="assets/hearthside.svg" alt="Hearthside icon: a heart-shaped fireplace with a lit flame" width="96">

# Hearthside — your AI companion

**Chat with AI, privately, right from your KDE Plasma panel — and keep an eye on your AI subscriptions.**

[![KDE Plasma 6](https://img.shields.io/badge/KDE%20Plasma-6-1d99f3?logo=kde&logoColor=white)](https://kde.org/plasma-desktop/)
[![Python 3.11+](https://img.shields.io/badge/python-3.11%2B-3776ab?logo=python&logoColor=white)](https://www.python.org/)
![stdlib only](https://img.shields.io/badge/deps-stdlib%20only-44cc11)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

</div>

Hearthside sits in your Plasma panel as a small heart-shaped fireplace. Click
it and a popup opens with two tabs:

- **Chat** — use Claude, ChatGPT, Grok, Gemini, GitHub Copilot, Microsoft
  Copilot, a local web UI, or a built-in chat with your own **Ollama** models,
  without opening a browser. Private by default: nothing is saved to disk.
- **Usage** — how much of each AI coding plan you have left (Claude Code,
  Codex, Cursor, Antigravity, GitHub Copilot, Devin, Grok), with reset times.

Security comes first: sign-ins live in memory unless you choose an
**encrypted, passphrase-protected** folder, and the Ollama chat never leaves
plasmashell's memory.

## Screenshots

<table>
<tr>
<td align="center"><img src="docs/chat.png" alt="Chat tab showing ChatGPT inside the Hearthside popup" width="400"><br><sub>Chat sites in the popup</sub></td>
<td align="center"><img src="docs/ollama.png" alt="Built-in Ollama chat with the llama3 model" width="400"><br><sub>Built-in Ollama chat</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/chat-locked.png" alt="Locked encrypted sign-ins card with Unlock and private-session buttons" width="400"><br><sub>Encrypted sign-ins, locked</sub></td>
<td align="center"><img src="docs/usage.png" alt="Usage tab with Claude Code session and weekly meters" width="400"><br><sub>Usage meters</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/settings-general.png" alt="Settings, General page: popup, usage and privacy options" width="400"><br><sub>Settings → General</sub></td>
<td align="center"><img src="docs/settings-chat.png" alt="Settings, Chat page: the list of chat sites" width="400"><br><sub>Settings → Chat</sub></td>
</tr>
</table>

## Features

### Chat

- **Chat sites in the popup**: pick Claude, ChatGPT, Grok, Gemini, GitHub
  Copilot, Microsoft Copilot or Local web UI (Open WebUI) from a dropdown and
  use the site right there. Choose which sites appear under **Settings →
  Chat**.
- **Private by default**: pages run in an in-memory browser profile. You sign
  in on each site normally; nothing is saved to disk, and you are signed out
  when Plasma restarts or you choose **Clear chat data**. Every site
  permission (microphone, camera, screen sharing, notifications, location,
  clipboard reading) is denied, downloads ask first, and outside links open
  in your browser only after you confirm.
- **Built-in Ollama chat** (optional, off by default): talk to the models of
  the Ollama server on this computer with a native chat — model picker,
  streaming replies with simple formatting, Stop, Copy, Regenerate, Edit and
  Clear, a personality per model, side-by-side compare of two models, and
  text you drag in from other programs. No browser engine, conversation in
  memory only.
- **Stay signed in** (optional, off by default): keep chat sign-ins across
  Plasma restarts in an encrypted folder protected by a passphrase you choose
  (made with gocryptfs). Unlock it once per Plasma session from the Chat tab,
  or use a private session instead. **Lock** it any time from the toolbar, or
  let **Lock automatically** do it after 1 minute to 24 hours of not using
  Chat. If you forget the passphrase, the saved sign-ins are lost; there is no
  recovery. A new sign-in is saved within about 30 seconds, and at once when
  you lock: lock or wait half a minute after signing in before restarting
  Plasma or logging out.
  - **Unlock with KDE Wallet** (Settings → General → Privacy): the folder
    opens with a key kept in your KDE Wallet, silently at Plasma start when
    the wallet is already open, else with one click. The passphrase always
    still works ("Use passphrase instead…"). Anyone who can use your open
    wallet can open the folder too.
- **Prompt library**: the Chat toolbar's **Prompts** button keeps prompts and
  personalities you reuse. With Stay signed in → Encrypted they are saved
  inside the encrypted folder (typed into a KDE text window); otherwise they
  last for this session only. With Ollama a prompt goes into the message box
  and a saved personality can be a model's default; on a web site a click
  copies the prompt to the clipboard.
- **Google sign-in** works on Google's sign-in page (Hearthside presents
  itself as Firefox there only, because Google refuses embedded browsers).
- **Keep open / Minimize**: the popup closes when you click elsewhere unless
  you turn on **Keep the popup open when clicking elsewhere**; the **Minimize**
  button hides it with chat pages, sign-ins and the Ollama conversation
  intact.
- **Zoom per site**: **Ctrl+=** (or **Ctrl++**) or **Ctrl+scroll up** zooms
  in, **Ctrl+-** or **Ctrl+scroll down** zooms out, and **Ctrl+0** goes back
  to 100%, one step at a time from 50% to 200%. Each chat site keeps its own
  zoom, also in its sign-in windows and across Plasma restarts; in the Ollama
  chat the same keys and Ctrl+scroll over the conversation or the message
  box change the text size.

### Usage

- Shows each available quota, plan, reset time, extra usage or credits, with
  **Left** and **Used** display modes; hover over the panel icon for a short
  summary.
- Detects installed tools through the Plasma login environment, CLI names, and
  Linux/XDG data locations, and contacts only providers that are both
  installed and tracked.
- Keeps successful readings in Plasma session memory when a temporary or
  rate-limit error occurs; usage history is never written to disk.
- **Notifications** (optional, off by default): a notification when a plan
  drops to a level of usage left you choose (5% to 50%), and when such a plan
  resets.
- Refreshes rotating OAuth credentials back to their exact source with
  compare-before-write protection, and uses Linux Secret Service through
  `secret-tool` without placing secrets in process arguments.

### Settings

Plasma's standard configuration dialog with three pages of its own —
**General** (popup, usage display and privacy), **AI Provider Settings** (providers) and
**Chat** (sites and addresses) — plus Plasma's **Keyboard Shortcuts** and
**About**. Longer explanations sit behind the small **?** buttons. Hearthside
starts with Plasma while it remains on a panel.

### Chat sites

- **GitHub Copilot** opens GitHub's sign-in page and goes on to
  `github.com/copilot` once you are signed in (signed-out visitors to
  `/copilot` only get a landing page). Google and Apple sign-in may be
  refused inside the widget; GitHub's own sign-in and two-factor prompts work.
- **Ollama** talks straight to the [Ollama](https://ollama.com) server on this
  computer and shows its own simple chat: pick a model, type, and the reply
  streams in. Turn it on under **Settings → Chat**, then choose it in the
  Chat tab's dropdown. It lists the models you have installed (install one in
  a terminal with `ollama pull llama3`; **Reload models** picks up new ones);
  cloud models are hidden because they send your messages to ollama.com.
  Enter sends, Shift+Enter adds a line, Esc or **Stop** ends a reply, each
  reply and code block has a Copy button, and **Clear conversation** drops it
  from memory and asks Ollama to unload the models it used. **Regenerate**
  (on the last reply) asks again, **Edit** (on your last message) puts it back
  into the message box. Replies show headings, lists, bold, italic and inline
  code, with fenced code blocks in a monospace font, all as plain text; links,
  images, HTML and tables are shown as they are and never load or open
  anything.
  - **Personality**: the toolbar's Personality button sets an instruction for
    the current model ("Answer briefly, in German."), sent first with every
    message to it. It is kept in memory only, until you turn Ollama off or
    Plasma restarts; Clear keeps it.
  - **Compare two models**: the toolbar's Compare button adds a second model
    and pane. Each message goes to the first model, then to the second, and
    each pane keeps its own conversation; Stop also cancels the second
    model's turn. Both models stay loaded until Clear, so this needs memory
    for both. The panes sit side by side when the popup is wide enough
    (**Settings → General → Size: Large**), else one above the other.
  - **Drag and drop**: drag text, or one text file (up to 128 KB), from
    another program onto the chat or onto the panel icon, and it lands in the
    message box (nothing is sent until you press Send). Hearthside never starts Ollama: if
  it isn't running, the Chat tab says so and shows
  `systemctl start ollama` (or `ollama serve`). The address is
  `http://127.0.0.1:11434` unless you change it under **Show advanced
  settings → Ollama address**; only `http://` on this computer (`127.0.0.1`,
  `localhost`, `[::1]`) with a port is accepted. Before it sends anything,
  Hearthside checks that the program on that port belongs to you or to the
  system (the packaged `ollama` service), never to another user.
- **Local web UI (Open WebUI)** shows a chat web interface running on this
  computer, by default `http://localhost:3000/`, for example
  [Open WebUI](https://github.com/open-webui/open-webui) on top of Ollama:
  `docker run -d -p 3000:8080 --add-host=host.docker.internal:host-gateway -v open-webui:/app/backend/data --name open-webui ghcr.io/open-webui/open-webui:main`
  (or `open-webui serve`, which listens on port 8080; set that address below).
  As for Ollama, the page loads only when the program on that port belongs
  to you or to the system, never to another user.
- **Custom addresses**: under **Settings → Chat → Show advanced settings**
  each site can open a different address, for example a self-hosted
  instance. Leave a field empty to use the built-in address. Addresses must
  use `https://`; only Local web UI may also use plain `http://`, and only for this
  computer (`localhost`, `127.0.0.1`, `[::1]`). A custom address adds only its
  exact host to the site, never its subdomains. Don't put passwords or tokens
  in an address; it is stored in your Plasma configuration file. The widget
  never opens a page, window or embedded frame on this computer for any site
  but Local web UI, and for it allows plain `http://` only at the configured
  address; background requests a page makes itself (fetch, WebSocket, images)
  aren't filtered, as in any browser. See [docs/privacy.md](docs/privacy.md).
- **A chat server on another machine** (for example Open WebUI on your home
  server): give it an `https://` address with a certificate your system
  trusts (self-signed certificates are refused), or forward it to this
  computer with an SSH tunnel such as `ssh -N -L 3000:localhost:3000 server`
  (use `ssh -N -L 3000:server:3000 gateway` when it runs on a third machine)
  and keep Local web UI at `http://localhost:3000/`.

### Settings → General

- **Popup**: **Open on** Chat or Usage; **Show tabs** Usage and Chat (at
  least one stays on); **Size** Compact, Normal or Large (never larger than
  the screen); **Keep the popup open when clicking elsewhere**. A hidden Chat
  tab starts no chat page, web engine or Ollama chat, and hiding it locks
  open saved sign-ins. A hidden Usage tab runs no usage refresh, and the panel
  icon's tooltip shows only the name. The keyboard shortcut itself is set in
  Plasma's own **Keyboard Shortcuts** page; **Keyboard shortcut opens**
  chooses what it opens: the popup as when clicking the icon, Chat, the
  Ollama message box (ready to type; the normal popup while Ollama is off) or
  Usage. Pressing the shortcut again closes the popup.
- **Usage**: **Display** Left or Used, **Refresh every**, **Show usage
  when hovering over the panel icon**, and **Notifications**: **Notify when
  a plan drops below** a percentage **left** (20% by default, whatever
  Display shows) and **Notify when a plan resets** (only for a plan that had
  dropped that low). Plans are checked at each usage refresh while the Usage
  tab is shown; a plan already that low when Plasma starts doesn't notify.
  Mute or adjust them under **System Settings → Notifications →
  Hearthside**.
- **Privacy**: **Stay signed in** (Off or Encrypted), **Lock automatically**,
  and under **Show folder actions** **Change passphrase…** and **Delete
  encrypted folder…**.

Fresh installs open on Chat, show both tabs at Normal size, track all
providers, display usage left, refresh every five minutes, and send no
notifications.

## Configure usage providers

Under **Settings → AI Provider Settings**, track only the tools you use, and choose which
metrics of each provider the panel icon's tooltip shows (its default metric,
such as Weekly, when none is checked).

## Install

```bash
./scripts/install.sh --restart-plasma
```

The script first checks what Hearthside needs. When you run it in a terminal
on Arch, it offers (y/N) to install anything missing with `sudo pacman`:
required Qt/KDE modules, Qt WebEngine for the Chat tab, and gocryptfs,
kdialog and fuse3 for Stay signed in; otherwise it prints the command to run.
Ollama is only described, since you choose the build for your graphics card.
It then removes the old AI Usage widget, helper, and cache if they are
present, installs the dependency-free Python helper into the user Python site,
installs or upgrades the plasmoid and the colour app icon, and optionally
reloads Plasma.

Then right-click the panel, choose **Add Widgets…**, search for **Hearthside**,
and add it. The first launch opens Settings once.

Manual installation remains available:

```bash
python3 -m pip install --user --break-system-packages .
kpackagetool6 -t Plasma/Applet -i plasmoid
```

Use `-u plasmoid` instead of `-i` when the package is already installed.

To delete saved chat sign-ins when you stop using Hearthside, first lock the
encrypted folder in the Chat tab (or turn Stay signed in off), then run:

```bash
./scripts/install.sh --uninstall-web-data
```

It deletes the encrypted folder and the usage alert events file
(`knotifications6/hearthside.notifyrc`) and nothing else, and refuses while
the folder is unlocked.
When upgrading from AI Usage 2.x by hand, remove the old helper and widget
first, so the two never refresh the same sign-ins at once:

```bash
python3 -m pip uninstall --break-system-packages ai-usage-kde
kpackagetool6 -t Plasma/Applet -r com.bgn.aiusage
```

## Upgrading from AI Usage 2.x

Hearthside 1.0.0 is the renamed AI Usage 2.x. Run the installer once:

```bash
./scripts/install.sh --restart-plasma
```

It removes the old `com.bgn.aiusage` widget, the old `ai-usage-kde` Python
helper, and the old cache files in `$XDG_CACHE_HOME/ai-usage-kde`. After Plasma
reloads, remove the old widget's placeholder from your panel if it is still
there, then add **Hearthside** once through **Add Widgets…**. Settings start
fresh because the widget has a new ID. Nothing needs to be re-authenticated:
Hearthside reads the same provider sign-ins as before.

## Helper CLI

```bash
hearthside --json
hearthside --providers=claude,codex
hearthside --catalog
hearthside --detect
```

The JSON v2 response includes the provider catalog, detected provider IDs,
status/failure classification, available metrics, quota windows, billing
usage, reset/retry times, and no credential data.

## Requirements

- KDE Plasma 6 and Qt 6
- Python 3.11 or newer; standard library only
- `secret-tool` when a provider stores its session in Linux Secret Service
- For the Chat tab only: Qt WebEngine 6.8 or newer with its QML module
  (Arch: `qt6-webengine`; Fedora: `qt6-qtwebengine`; Debian/Ubuntu:
  `qml6-module-qtwebengine`; package names may vary). It also needs the Qt
  Quick Dialogs QML module, usually already installed with Plasma (Arch:
  `qt6-declarative`; Debian/Ubuntu: `qml6-module-qtquick-dialogs`). Without
  these the usage view works as before and the Chat tab explains what to
  install. Each open
  chat site uses roughly 200–500 MB of memory until Plasma restarts or you
  clear chat data.
- For the Ollama chat only: [Ollama](https://ollama.com) installed and
  running on this computer, with at least one model pulled. Qt WebEngine is
  not needed for it.
- For Stay signed in only: gocryptfs 2 (`sudo pacman -S --needed gocryptfs`
  on Arch), plus kdialog and fuse3, which are usually already installed with
  KDE. The Chat tab shows the install command if something is missing.

## Privacy

No tokens, credential fingerprints, raw API responses, local transcripts, or
usage history are printed or cached. Antigravity's derived access-token cache
is the only authentication cache created by Hearthside; it is stored with mode
`0600` under `$XDG_CACHE_HOME/hearthside` and keyed to a one-way refresh-token
fingerprint.

The Chat tab keeps cookies, sessions, and site data in memory only, denies
every site permission (microphone, camera, screen sharing, notifications,
location, clipboard reading), asks before each download, asks before opening
an outside link in your browser (which may keep it in its history), and
never reads or scripts the pages. When a page moves to a site outside the one you chose, a
notice above it names the real host. Provider names, plans and errors, Ollama
replies and download names are shown as plain text, with hidden and control
characters made visible. The Chat tab's engine is Qt WebEngine (Chromium):
keep it updated and restart Plasma after it updates. Page console messages
are discarded. Custom chat addresses are stored in plain text in your Plasma
configuration file. With Stay signed in, sign-ins and site data are saved
only in your encrypted folder; while it is unlocked, programs running as you
can read it. The Ollama chat keeps the conversation in memory only and sends
it over loopback to the Ollama server on this computer, which can read it
(see [Ollama](docs/privacy.md#ollama-built-in-chat)). The
[Chat tab privacy notes](docs/privacy.md#chat-tab) also list what it does not
protect against.

See [Privacy](docs/privacy.md) and
[Provider contracts](docs/provider-contracts.md).

## Development

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -e ".[test]"
QT_QPA_PLATFORM=offscreen python -m pytest
python3 -m compileall -q src
/usr/lib/qt6/bin/qmllint plasmoid/contents/ui/*.qml
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
```

## Credits

Hearthside began as a fork of
[AI Usage for KDE](https://github.com/burakgon/ai-usage-kde-widget) by Burak
([@burakgon](https://github.com/burakgon)), whose usage-meter widget and helper
are the foundation of the Usage tab. Thank you! The original MIT copyright
notice is kept in [LICENSE](LICENSE).

## License

[MIT](LICENSE)
