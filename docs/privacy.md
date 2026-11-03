# Privacy

Hearthside reads existing local sign-in state only for providers the user tracks
and that are detected as installed. Credentials are sent only to the matching
provider's first-party OAuth and usage endpoints. The helper never follows
HTTP redirects: a 3xx from a provider is reported as a failed request
(`invalid-response`), so a token is never sent on to the redirect's address.
The widget always starts the helper as `python3 -P -m hearthside`, so
Python doesn't load modules from Plasma's working folder.

The helper does not print or log access tokens, refresh tokens, API keys,
credential fingerprints, or raw provider responses. Its JSON output contains
only display metadata, quota percentages, billing summaries, plan names, and
timestamps.

Provider names, plan names, captions, error messages and billing amounts in
the Usage tab, the panel tooltip and the settings page are shown as plain
text only. Text such as `<img src="...">` in a provider's reply appears
literally and can't make the widget load an image or a link.

Usage snapshots, stale readings, and rate-limit cooldowns live only in the
Plasma widget process. They disappear when Plasma restarts. Hearthside does not
read local chat transcripts and does not keep usage history.

Usage notifications (**Settings → General → Usage → Notifications**, off by
default) are sent to Plasma's notification server through KDE's notification
library as the `hearthside` application. Each one names a provider, a plan
(for example "Claude Code" and "Weekly") and a whole percentage left, nothing
else: no account, plan name from the provider, error text or link, and no
buttons. Plasma may keep it in its notification history like any other
notification. They can be muted or changed under **System Settings →
Notifications → Hearthside**, which saves that choice in
`~/.config/hearthside.notifyrc`. Which plans already notified is kept only
in the widget's memory, so after a Plasma restart the first reading counts
as a starting point again and never notifies. `scripts/install.sh` installs
`hearthside.notifyrc` to `${XDG_DATA_HOME:-~/.local/share}/knotifications6/`
so the two events appear in System Settings; it holds names and settings
only.

Antigravity is the one provider that requires a derived access-token cache
because its Secret Service entry can contain only a refresh token. That cache
is written to `$XDG_CACHE_HOME/hearthside/antigravity-auth.json` (falling back
to `~/.cache`) with mode `0600`. It contains a short-lived access token, expiry,
and a SHA-256 refresh-token fingerprint. It never contains the refresh token.
When upgrading from the previous release, `scripts/install.sh` deletes the old
cache files in `$XDG_CACHE_HOME/ai-usage-kde/`; a manual `pip` install leaves them in
place until you remove that directory yourself.

When a credential file is a symlink, refreshed credentials are written to the
file it points to with mode `0600`, and only if that file already exists, is a
regular file, and is owned by the current user.

To keep two helper runs from refreshing the same token, the helper creates
empty lock files named `<provider>.lock` in `$XDG_RUNTIME_DIR/hearthside/`
(falling back to `<temp dir>/hearthside-<uid>/`). The directory is mode
`0700` and each file is mode `0600`. The files hold no data; only their
advisory lock is used.

To find CLIs and profile directories, the helper may start the user's login
shell once per run. That shell prints only the allow-listed variables
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`,
`XDG_DATA_HOME`, and `PATH`. The values stay in memory and are never cached to
disk.

Hearthside makes no network requests other than to the tracked providers'
endpoints and the chat websites you open, plus whatever those sites load, and,
if you use the built-in Ollama chat, requests over loopback to the Ollama
server on this computer. No analytics or telemetry are collected.

## Chat tab

The Chat tab shows a provider's own website (Claude, ChatGPT, Grok, Gemini,
GitHub Copilot, or Microsoft Copilot), or a chat web interface on your own
computer (Local web UI, for example Open WebUI on top of Ollama), in Qt
WebEngine inside the Plasma process. You sign in on each site as you would in
a browser. The built-in Ollama chat is different: it is not a web page and
does not use Qt WebEngine (see [Ollama](#ollama-built-in-chat) below).

Google's sign-in page (accounts.google.com) refuses embedded browsers
("This browser or app may not be secure"). While a chat page or sign-in
window is on that page, Hearthside identifies itself as Firefox on Linux and
sends no browser brand in its client hints, so Google allows the sign-in;
everywhere else it reports its real Chromium-based engine. Google may change
this check at any time, and sign-in with Google could stop working.

**Stay signed in** (Settings → General → Privacy) has two choices:

- **Off** (the default): everything you enter (accounts, passwords, prompts,
  uploaded files, cookies) stays in Plasma's memory and is gone when Plasma
  restarts or you choose **Clear chat data**. Nothing is written to disk.
- **Encrypted**: sign-ins and site data are kept in a passphrase-protected
  folder made with gocryptfs, so you stay signed in across Plasma restarts.

There is no plain "save to disk" choice. Qt WebEngine never encrypts cookies
or site storage itself (it does not use KDE Wallet for them), so a saved
sign-in would sit on disk as readable text. Hearthside therefore saves
sign-ins only inside the encrypted folder.

### Off: private in-memory profile

All chat pages, including sign-in windows, share one off-the-record Qt
WebEngine profile with an in-memory HTTP cache and no persistent cookies.
Qt WebEngine creates no profile directory for it. Cookies, sessions, local
storage, IndexedDB, service workers, history, and favicons exist only in
memory. Spell checking is off. You are signed out on every Plasma restart.

**Clear chat data** (in the Chat tab, after a confirmation) destroys every
chat page together with the profile, which signs you out of all chat sites at
once. Chat is the first tab, so Qt WebEngine starts the first time you open
the popup on a web site; it doesn't start while no web chat sites are enabled
or while only the Ollama chat is shown, and it is never started just because
the widget is on the panel.

### Encrypted: saved sign-ins

Turning on **Encrypted** installs nothing and asks for nothing by itself. The
Chat tab shows a card instead: **Create encrypted folder…** the first time,
**Unlock…** after that. Each card also offers **Use a private session this
time**, which opens the sites in the Off profile above. If gocryptfs is not
installed, the card shows the install command; until then you can use a
private session.

How it works:

- The encrypted files are in `$XDG_DATA_HOME/hearthside/vault/` (usually
  `~/.local/share/hearthside/vault/`). While unlocked, gocryptfs shows their
  readable view at `$XDG_RUNTIME_DIR/hearthside/vault/` (usually
  `/run/user/<uid>/hearthside/vault/`), which lives in memory. Each widget
  keeps its profile in its own subfolder there.
- What is encrypted: cookies, local storage, IndexedDB, session storage and
  every other file the sites write, including the file names. The HTTP cache
  stays in memory.
- What is not encrypted: metadata such as the number of files, their
  approximate sizes, timestamps, and the folder layout. gocryptfs detects a
  changed file, but not an older copy of the whole folder put back in its
  place (no rollback protection).
- The folder is mounted only for you (no `allow_other`). Before using it, the
  helper checks that it looks like your gocryptfs mount of your encrypted
  folder; if not, the Chat tab falls back to the card and saves nothing. This
  check guards against mistakes and against other users. It does not protect
  against programs running as you: those can already read your files, and
  could mount a look-alike FUSE folder that passes the same check.
- One encrypted folder with one passphrase is shared by all Hearthside widgets
  on your account. Unlocking it in one widget unlocks it for all of them.

Your passphrase:

- You type it only into a KDE dialog (kdialog) that gocryptfs itself starts;
  kdialog hands it straight to gocryptfs. It never passes through Hearthside
  and is never in process arguments, environment variables, logs, or the
  widget's configuration.
- Creating the folder asks twice: once to choose the passphrase, then once
  more to unlock it. Hearthside cannot enforce a strong passphrase; the
  dialog shows a strength meter.
- There is no recovery key. If you forget the passphrase, the saved sign-ins
  are lost: delete the folder and start again.
- **Change passphrase…** and **Delete encrypted folder…** are under Settings →
  General → Privacy → Show folder actions, and work only while the folder is
  locked.

The folder stays unlocked until you press the lock button (**Lock saved
sign-ins**) in the Chat tab, it is locked automatically (below), you choose
**Clear chat data**, turn Stay signed in Off, Plasma restarts, you log out, or
the computer restarts. Lock closes the chat pages first, then
locks the folder; if another Hearthside widget is still using it, the folder
is not locked and the Chat tab says so. It is never forced.

**Lock automatically** (Settings → General → Privacy; only with
Encrypted) locks the folder after Never (the default), 1, 5, 15 or 30 minutes,
1, 8 or 24 hours of not using Chat. Not using means the Chat tab with a chat
site hasn't been shown: the popup is closed, or Usage or Ollama is shown.
Every time Chat is shown again the time starts over, and it never locks while
Chat is shown. It counts clock time, so time the computer was asleep counts
too. It works like the lock button, but it waits while a passphrase window or
another folder step is running, and if another Hearthside widget is using the
folder it quietly keeps it open and tries again after the next idle period.
Afterwards the Chat tab says "Locked automatically".

When your sign-ins reach the folder: the web engine writes new cookies to disk
about 30 seconds after a site sets them (site storage after about 5 seconds),
and everything at once when the chat pages close: on Lock, Lock automatically,
Clear chat data, or when Plasma quits normally. If Plasma is stopped abruptly
(a crash, or killed) within those seconds after you signed in, that newest
sign-in is lost and you sign in again. To be sure, lock the folder or wait half
a minute after signing in before restarting Plasma or logging out.

**Clear chat data** in Encrypted mode signs you out of all chat sites,
deletes this widget's saved sign-ins inside the folder, and locks the folder.

Turning Stay signed in **Off** (after a confirmation in settings) deletes the
whole encrypted folder, with every sign-in saved in it, for all Hearthside
widgets. If another widget still has it open, it is not deleted and the Chat
tab tells you; delete it later under Settings → General → Privacy → Show
folder actions.

Hiding the Chat tab (Settings → General → Show tabs) closes the chat pages
and, if saved sign-ins are open, locks the folder as the lock button does.
While Chat is hidden no chat page, web engine or Ollama chat starts.

Small files in `$XDG_RUNTIME_DIR/hearthside/` (in memory, mode `0600`):
`vault.lock`, an empty lock file, and briefly `passwd.status`, which holds only
the exit status of the first passphrase dialog while you change the
passphrase.

What Encrypted mode does not protect against:

- While the folder is unlocked, any program running as you, and root, can
  read your saved sign-ins, just like the Plasma memory in Off mode.
  Keyloggers can capture the passphrase as you type it.
- A program running as you could show a fake passphrase window. Only type the
  passphrase right after you clicked Create, Unlock, or Change passphrase.
- Hibernation can write the folder's key, which is in memory while unlocked,
  to disk. Lock the folder before hibernating, or use encrypted swap.
- If gocryptfs is killed while a site is writing (for example when Plasma
  crashes), saved sign-ins can be damaged. This fails safe: you are signed
  out and sign in again. The helper cleans up the dead mount the next time the
  Chat tab checks the folder.
- Deleting the folder (Clear, turning Off, Delete encrypted folder, or
  `scripts/install.sh --uninstall-web-data`) removes the files normally. On
  btrfs or other copy-on-write file systems, and on SSDs (TRIM), old blocks
  may stay on the disk for a while; this is not a secure erase. They hold only
  encrypted data, so the risk is low.

### What is stored where

| Data | Off | Encrypted |
| --- | --- | --- |
| Cookies, sessions, site storage | Memory only; dropped on Clear chat data or Plasma restart | Encrypted folder; deleted on Clear chat data (this widget) or when you turn it Off (all widgets) |
| HTTP cache | Memory only | Memory only |
| Page titles, addresses, history, icons | Memory only; the widget never shows, stores, or logs them | Same; Qt WebEngine's own history files, if any, are inside the encrypted folder |
| Passphrase | Not used | Never stored; typed into kdialog, read by gocryptfs |
| Passwords and form autofill | Not supported by Qt WebEngine; nothing is saved | Same |
| Widget settings | The enabled sites (`chatSites`), the first site (`chatDefaultSite`), any custom addresses you enter (`chatCustomUrls`), the Stay signed in choice (`chatSignInStorage`), a profile counter (`chatProfileGeneration`), the Ollama address (`chatOllamaUrl`), the zoom of each site and of the Ollama chat, set with the zoom keys or Ctrl+scroll (`chatSiteZoom`, for example `{"claude":1.25}`; sites at 100% are left out), and the General page's popup choices (`popupDefaultTab`, `showUsageTab`, `showChatTab`, `popupSize`, `tooltipShowsUsage`, `chatKeepOpen`, `chatAutoLockMinutes`, `shortcutOpens`, `alertLowEnabled`, `alertLowPercent`, `alertResetEnabled`), in plain text in `~/.config/plasma-org.kde.plasma.desktop-appletsrc`; never the last page you visited, a passphrase, a path, a model name, or anything you typed into a chat | Same |
| Ollama conversation | Plasma memory only (and the Ollama server, see below); dropped on Clear conversation, when you turn Ollama off in settings, or on Plasma restart; kept while the popup is closed or another site is shown | Same; never in the encrypted folder |
| Ollama address | `chatOllamaUrl` in the Plasma configuration file, plain text; only a loopback `http://` address with a port is ever saved | Same |
| Downloads | Only files you approve, saved to your Downloads folder | Same |
| Uploads | Read-only, from files you pick in the file dialog | Same |
| Page console messages | Discarded; never written to the journal | Same |
| Links opened in your browser | Handed to your default browser, which may keep them in its history; the address briefly appears in that browser's process arguments | Same |

The configuration file is readable by other users on many systems (mode
`0644`), so the enabled sites and their zoom levels can be seen by anyone who
can log in to this computer.

Apart from your settings and approved downloads, Hearthside writes to disk
only in two places: the Antigravity token cache described above, and, only if
you choose Encrypted, the encrypted folder (written by Qt WebEngine through
gocryptfs).

The widget never runs scripts in, reads from, or injects anything into the
pages, sets no `QTWEBENGINE_*` variables or Chromium flags, and does not pass
chat data to the Python helper, process arguments, or the environment. For
Stay signed in the widget runs the helper with fixed words and numbers only
(see [Provider contracts](provider-contracts.md#stay-signed-in-helper)); its
replies are short codes, never paths. For the Ollama chat and Local web UI it
runs the helper with the port number only ([port owner helper](provider-contracts.md#port-owner-helper)). Load errors show generic text and are
not logged. The system file dialog may remember recently used folders, as it
does for any application.

### Custom addresses

Under **Settings → Chat → Show advanced settings** you can change the address
each site opens. Custom addresses are saved in plain text in your Plasma
configuration file (`~/.config/plasma-org.kde.plasma.desktop-appletsrc`), which
other programs running as your user and your backups can read. Don't put
passwords, tokens, or other secrets in them. Addresses with a user name or
password (`https://user:pass@host/`) are refused, and text that isn't a valid
address is never saved. A custom address adds only its exact host to the site.

### Local web UI

Local web UI is off by default. It is the only site whose pages may use plain
`http:`, and only for the exact address and port you configured on this
computer (`localhost`, `127.0.0.1`, or `[::1]`); traffic over loopback never
leaves the computer, but it is not encrypted. That rule covers the pages and
embedded frames the widget controls; the Local page's own background requests
(fetch, WebSocket, images, scripts) are not filtered by the widget.

For every other site, the widget never opens or navigates to this computer:
not as the page, not in a new window, and not in an embedded frame. Like in
any browser, though, a page can still make background requests (fetch,
WebSocket, images and similar) to this computer or to names that resolve to it
(for example `*.nip.io`); the widget can't filter those. Keep in mind:

- Open WebUI (or whatever server you run) keeps its own accounts and chat
  history on its side. Clear chat data signs you out of it in the widget but
  does not delete anything stored by the server.
- **The port's owner is checked.** On a shared computer, another user could
  start their own server on the port before yours does. Before the Local page
  is created, and before each main-frame navigation of a Local page to this
  computer, the widget asks the helper who owns the listening socket (the same
  check as for Ollama; the helper sees only the port number). It loads
  nothing unless it belongs to you, root, or the system `ollama` account.
  Otherwise it shows "Another user's program is using port …" (or "Couldn't
  check which program is using port …", or "Nothing is using port …") with a
  Retry button, and a Local page that was already open is replaced by an
  empty page, so it can't keep talking to the new listener. A form sent to
  the Local page is checked too; it can't be replayed, so after the check you
  send it again within 10 seconds. That one-time pass ends after 10 seconds,
  on Dismiss and on any problem; later the form is checked again. Windows a Local page opens on this computer are dropped,
  since they would skip the check. The check cannot tell your own programs
  apart, and a listener could change in the milliseconds between the check
  and the load. Requests the page makes by itself (fetch, WebSocket) after it
  loaded, and embedded frames, are not checked again.
- A server on another machine needs `https:` with a certificate your system
  trusts; pages with self-signed or otherwise invalid certificates are not
  loaded. Alternatively, reach it through an SSH tunnel to a local port.

### Ollama (built-in chat)

The Ollama entry (off by default; Settings → Chat) is a small chat written in
QML that talks to the Ollama API directly. It does not use Qt WebEngine, so
none of the web profile rules above apply to it; these do:

- **Where your messages go.** Each message, with the conversation so far, is
  sent in the body of a `POST /api/chat` request over plain `http://` on
  loopback to the address you set (default `http://127.0.0.1:11434`; only
  `127.0.0.1`, `localhost`, or `[::1]` with a port is accepted). Hearthside
  itself sends it nowhere else, and it is readable by the program that
  answers on that port. With the packaged `ollama.service` that is a process
  of the system `ollama` account, so the `ollama` account's processes, and
  root, can read your prompts and the replies. That program decides where
  the message goes next: Ollama keeps it on this computer for local models,
  but a program on that port could pass it on, and if it answers with an
  HTTP redirect, Qt sends the message again to the redirect's address (which
  may be another computer) before the widget can notice. The widget then
  drops the request and shows none of that reply, but cannot take the
  message back.
- **What Ollama keeps.** Ollama holds the conversation in its memory (the
  model's context cache, also in GPU memory) until the model is unloaded,
  5 minutes after the last message by default. **Clear conversation** asks
  Ollama to unload every model this conversation used (a request with no
  prompt and `keep_alive: 0`), so the next message loads the model again,
  which takes a few seconds. This also affects a model you are using with
  `ollama run` in a terminal at the same time.
- **Logs.** Ollama's service log records each request's method, path, status
  and timing (for example `POST /api/chat`), not its content. Don't set
  `OLLAMA_DEBUG` for the service: debug logging can write more.
- **Ollama's own history.** Prompts you type into `ollama run` in a terminal
  are saved by Ollama's command line tool in `~/.ollama/history`. That is not
  Hearthside, and the widget never writes there, but it is a place your
  prompts may end up on disk.
- **Cloud models are hidden.** Ollama can list cloud models (names ending in
  `:cloud` or `-cloud`, or with a remote host) that forward your messages to
  ollama.com. Hearthside drops them from the model list and never sends to
  them. Embedding-only models are hidden too.
- **The port's owner is checked.** If Ollama is stopped, another program can
  take its port. Before each model-list load and each send or unload, the
  widget asks the helper who owns the listening socket (read from
  `/proc/net/tcp`; the helper sees only the port number, never a prompt) and
  sends nothing unless it belongs to you, root, or the system `ollama`
  account. Another user's program gets nothing: "Another user's program is
  using port …". If the check can't be done, nothing is sent either. The
  check cannot tell your own programs apart, so a program running as you can
  still pose as Ollama, and a listener could change in the milliseconds
  between the check and the request. Hearthside never starts Ollama.
- **Nothing on disk from Hearthside.** The conversation lives only in Plasma's
  memory: no file, log, journal message, process argument, environment
  variable, helper call, or setting holds it. Nothing is in the request
  address either; only the body carries text. The model you pick is not saved.
  It stays while the popup is closed or another site is shown, and is gone on
  Clear conversation, when you turn Ollama off in settings, or on Plasma
  restart.
- **What is shown.** Replies and server error messages are shown as plain
  text only, so a reply containing HTML, Markdown images or links can't make
  the widget load anything. Fenced code blocks are shown in a monospace font.
  Hidden and control characters in a reply are shown as visible markers such
  as `⟦U+202E⟧`, with the note "This text contains hidden or control
  characters": control characters (U+0000–U+001F except tab and line feed, so
  carriage return and escape too; U+007F; U+0080–U+009F including U+0085),
  line and paragraph separators (U+2028, U+2029), the soft hyphen (U+00AD),
  U+034F, direction controls (U+061C, U+200E, U+200F, U+202A–U+202E,
  U+2066–U+206F), zero-width and invisible characters (U+200B–U+200D,
  U+2060–U+2064, U+FEFF, U+180E, U+17B4, U+17B5, the Hangul fillers U+115F,
  U+1160, U+3164, U+FFA0), variation selectors (U+FE00–U+FE0F,
  U+E0100–U+E01EF), interlinear annotation (U+FFF9–U+FFFB), shorthand and
  musical format controls (U+1BCA0–U+1BCA3, U+1D173–U+1D17A) and tag
  characters (U+E0000–U+E007F). Such characters can make a command look
  different from what it really is ("Trojan Source"), and a carriage return
  or escape can make a terminal act on it. One U+FE0F right after an emoji
  (it only asks for the colour form) is left alone; emoji sequences joined
  with U+200D and right-to-left text that use these characters show the
  markers.
- **Typing.** Spell checking is off in the message field, and it asks input
  methods not to learn or predict what you type (`ImhSensitiveData`,
  `ImhNoPredictiveText`); some input methods (for example CJK prediction) may
  offer fewer suggestions there.
- **Copying.** The Copy buttons and Ctrl+C put text on the clipboard, where a
  clipboard manager such as Klipper may keep it (see below). They copy the
  text as shown, with the markers, never the characters listed above, so none
  of them can hide in what you paste into a terminal. Characters that are
  visible but look alike (such as Cyrillic `а` for Latin `a`) and combining
  marks are not marked: read a command before you run it.

### Permissions and prompts

Every site permission request is denied: microphone, camera, screen sharing,
notifications, location, clipboard reading, mouse lock, and local fonts. There
is no per-site allow. Full-screen requests, HTTP authentication prompts, client
certificate requests, file-system access, and protocol-handler registration
are refused. Pages with certificate errors are not loaded. Passkey (WebAuthn)
sign-in is cancelled with the message "Passkeys aren't supported here; choose
another sign-in method."

Downloads ask each time: **Save "name" to Downloads?** Save writes the file to
your XDG Downloads folder; Cancel, or no answer within 60 seconds, discards it.
"Save page" downloads are always refused. The name is shown as plain text,
shortened, with hidden direction and zero-width characters as markers, so
`invoice⟦U+202E⟧fdp.exe` can't pass for `invoiceexe.pdf`. Long names are
shortened in the middle, so the end with the real (last) extension always
stays visible.

A page never opens your browser by itself. When you click a link (or a
window) that leaves the chat site, a prompt above the page asks **Open
example.net in your browser?** with **Open** and **Cancel**; the host is plain
ASCII text as in the off-site notice below. Only Open hands the address over.
Only one prompt is shown at a time: further requests while it is shown, and
for 3 seconds after it was shown or answered, are dropped, so a page can't
pile up prompts. Windows a page opens by itself are dropped without a
prompt. **Open in browser** in the toolbar, your own click, opens the
current site's page directly. Your browser may keep an opened address in its
history, and the address briefly appears in the browser's process arguments.
Sign-in popups stay inside the widget, in a sign-in overlay that uses the same
profile as the chat page (private in Off, the saved one in Encrypted). Its
title always names a host: "Sign-in window: accounts.google.com", or while
the window is still blank (`about:blank`, or text a page wrote into it)
"Window opened by claude.ai", the host of the page that opened it. See [Provider contracts](provider-contracts.md#chat-tab) for the exact
navigation rules.

The widget has no address bar, and a page's scripts, redirects and forms may
still take it to other `https:` sites (sign-in flows need this). While the
page is on a host outside the site's own, sign-in and custom hosts, a notice
stays above it: **You are on example.net — not Claude**, with **Back to
Claude**. The host is shown as plain ASCII: international names appear in
their `xn--` form, so look-alike letters can't pass for the real name, and
long names are shortened from the front so the real domain at the end stays
visible. Don't type a password into a page while that notice is shown unless
you expected to be there.

### Threat model

The Chat tab protects against:

- other local users, who cannot read Plasma's memory or the unlocked
  encrypted folder;
- the developer: there is no telemetry, the widget makes no requests of its
  own (apart from the Ollama chat's requests to Ollama on this computer), and
  it never reads or changes the pages;
- with the Ollama chat: other users' programs on the Ollama port, cloud
  models, and leftovers of the conversation on disk from Hearthside;
- with Local web UI: other users' programs on its port;
- provider replies or pages that try to slip markup into the widget's own
  text, hide direction characters in replies or download names, or move a
  chat page to another site unnoticed;
- with Off: leftovers on disk after a Plasma restart or Clear chat data;
- with Encrypted: someone who reads your disk while the folder is locked
  (for example a stolen, powered-off laptop), apart from the metadata listed
  above;
- chat content in logs.

It does not protect against:

- root, or malware running as your user, which can read Plasma's memory and,
  while it is unlocked, the encrypted folder, log your keystrokes, or show a
  fake passphrase window;
- the chat providers themselves, and the third parties their pages load;
- the Ollama server: the program answering on the Ollama port (with the
  packaged service, the `ollama` account) reads your prompts and keeps them in
  its memory until the model is unloaded;
- security bugs in the web engine itself: Qt WebEngine ships its own copy of
  Chromium, which often lags weeks behind Chrome's security fixes, and a
  page that exploits such a bug runs inside Plasma (see below);
- swap, hibernation, core dumps, or clipboard managers, unless configured as
  below.

### Recommended system settings

- **Keep Qt WebEngine updated.** The Chat tab's engine (`qt6-webengine` and
  similar packages) is Chromium, and Qt's releases often lag behind Chrome's
  security fixes. Run system updates regularly, and restart Plasma
  (`systemctl --user restart plasma-plasmashell`, or log out and in) after a
  Qt WebEngine update, since the running Plasma keeps using the old library
  until then. Enable only the chat sites you actually use: each one is a
  site whose scripts, and the third-party scripts it loads, run in that
  engine.
- Use full-disk encryption, or at least encrypted `/home` and encrypted
  swap. Without it, a stolen or lost computer gives away the provider
  credential files, the Antigravity token cache and your Plasma settings,
  and memory paged out to disk (or a hibernation image) is readable later.
  The encrypted folder for saved sign-ins stays protected either way.
- Disable stored core dumps: for systemd-coredump, create
  `/etc/systemd/coredump.conf.d/50-no-storage.conf` with `[Coredump]` and
  `Storage=none`. A Plasma crash dump would contain chat pages, Off-mode
  sessions and cookies, the Ollama conversation, provider tokens and, while
  the folder is unlocked, the saved sign-ins Plasma has read from it; an
  Ollama crash dump would contain its context.
- Text you copy is handled by your clipboard manager. If Klipper (or another
  clipboard manager) keeps its history across sessions, copied chat text
  (including Ollama replies and code blocks) may be written to disk. Pages
  cannot read the clipboard.
- Never set `QTWEBENGINE_REMOTE_DEBUGGING` for Plasma; it would expose every
  open page, including your sessions, to local connections.
