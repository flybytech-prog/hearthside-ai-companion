# Privacy

AI Usage reads existing local sign-in state only for providers the user tracks
and that are detected as installed. Credentials are sent only to the matching
provider's first-party OAuth and usage endpoints.

The helper does not print or log access tokens, refresh tokens, API keys,
credential fingerprints, or raw provider responses. Its JSON output contains
only display metadata, quota percentages, billing summaries, plan names, and
timestamps.

Usage snapshots, stale readings, and rate-limit cooldowns live only in the
Plasma widget process. They disappear when Plasma restarts. AI Usage does not
read local chat transcripts and does not keep usage history.

Antigravity is the one provider that requires a derived access-token cache
because its Secret Service entry can contain only a refresh token. That cache
is written to `$XDG_CACHE_HOME/ai-usage-kde/antigravity-auth.json` (falling back
to `~/.cache`) with mode `0600`. It contains a short-lived access token, expiry,
and a SHA-256 refresh-token fingerprint. It never contains the refresh token.

When a credential file is a symlink, refreshed credentials are written to the
file it points to with mode `0600`, and only if that file already exists, is a
regular file, and is owned by the current user.

To keep two helper runs from refreshing the same token, the helper creates
empty lock files named `<provider>.lock` in `$XDG_RUNTIME_DIR/ai-usage-kde/`
(falling back to `<temp dir>/ai-usage-kde-<uid>/`). The directory is mode
`0700` and each file is mode `0600`. The files hold no data; only their
advisory lock is used.

To find CLIs and profile directories, the helper may start the user's login
shell once per run. That shell prints only the allow-listed variables
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`,
`XDG_DATA_HOME`, and `PATH`. The values stay in memory and are never cached to
disk.

AI Usage makes no network requests other than to the tracked providers'
endpoints. No analytics or telemetry are collected.
