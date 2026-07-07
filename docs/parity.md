# Feature-Parity Matrix

**Living contract.** This matrix is the single source of truth for what each
implementation supports. **Updating it is part of the definition of done for
every feature in this batch** — when a feature lands (or a divergence is fixed),
flip the affected cells in the same change. A PR that adds behavior to a script
without updating this table is incomplete.

Three implementations are tracked:

| Column | File | Runtime |
| --- | --- | --- |
| **Linux** | `iptv_toolkit.sh` | bash 4+ (Linux / Synology NAS) |
| **macOS** | `iptv_toolkit_mac.sh` | bash 3.2 (system bash on macOS) |
| **PowerShell** | `IPTV_toolkit.ps1` | PowerShell 7 (Windows) |

Legend: ✅ full · 🟡 partial · ❌ not present · `deferred` = the two bash
scripts have deliberately moved ahead and PowerShell is out of scope for this
batch.

> **PowerShell dispatch caveat (applies throughout).** The `.ps1` CLI entry
> point (bottom of the file) only wires up `setup-config`, `list-channels`, and
> live recording (triggered implicitly when `-Channel -DurationMinutes -Config`
> are all present). `Record-CatchupIPTV` and `Remove-Recording-Tasks` exist as
> functions but have **no CLI branch** — they are only reachable by
> dot-sourcing the script (`. .\IPTV_toolkit.ps1`) and calling the function
> directly. Cells below reflect this.

---

## Commands

| Command | Linux `iptv_toolkit.sh` | macOS `iptv_toolkit_mac.sh` | PowerShell `IPTV_toolkit.ps1` |
| --- | --- | --- | --- |
| `setup-config` | ✅ `setup_config` — interactive wizard, writes bash config | ✅ `setup_config` — identical wizard, writes the same bash config | 🟡 `Setup-IPTVConfig` — writes `$Global:IPTVConfigs` hashtable; default TZ is a Windows TZ ID |
| `list-channels` | ✅ `list_channels` | ✅ `list_channels` (via `cm_keys`/`cm_get`) | ✅ `List-IPTVChannels` |
| `record-live` | ✅ `record_live` | ✅ `record_live` | 🟡 `Record-LiveIPTV` — invoked implicitly (no `record-live` verb); `-FirstAudioOnly` not reachable from CLI (see flags) |
| `record-catchup` | ✅ `record_catchup` | ✅ `record_catchup` | 🟡 `Record-CatchupIPTV` — function exists but **no CLI dispatch**; dot-source only |
| `remove-jobs` | ✅ `remove_jobs` — prunes past cron entries | ✅ `remove_jobs` — prunes past cron entries | 🟡 `Remove-Recording-Tasks` — prunes completed Task Scheduler tasks; **no CLI dispatch**; dot-source only |
| `validate-config` | ✅ `validate_config` — static offline validation, `-config` or all | ✅ same | ❌ `deferred` |
| `check-channels` | ✅ `check_channels` — ffprobe reachability probe, `-channel`/`-catchup` | ✅ same | ❌ `deferred` |
| `remove-provider` | ❌ not yet | ❌ not yet | ❌ `deferred` |
| `remove-channel` | ❌ not yet | ❌ not yet | ❌ `deferred` |

> `validate-config`, `check-channels`, `remove-provider`, and `remove-channel`
> are the new commands landing in this batch. PowerShell stays `deferred`.
>
> `check-channels` is **standalone**. Wiring reachability into the record
> commands as a `-precheck` flag is a possible future item — ❌ everywhere today.

---

## Flags

| Flag | Linux `iptv_toolkit.sh` | macOS `iptv_toolkit_mac.sh` | PowerShell `IPTV_toolkit.ps1` |
| --- | --- | --- | --- |
| `-start-at` | ✅ live (wait or `-schedule`) + catch-up (required) | ✅ same | ✅ `-StartAt` on live + catch-up |
| `-schedule` | ✅ live only — writes a cron entry | ✅ live only — writes a cron entry | 🟡 `-Schedule` live only — Windows Task Scheduler; reachable from CLI |
| `-no-remux` | ✅ live + catch-up | ✅ live + catch-up | ✅ `-NoRemux` (catch-up dot-source only) |
| `-first-audio-only` | ✅ live + catch-up (`-map 0:a:0`) | ✅ live + catch-up (`-map 0:a:0`) | 🟡 `-FirstAudioOnly` defined on both functions but **not in the top-level `param()` block and not passed by the CLI dispatcher** — only usable when dot-sourced |
| `-dry-run` | ✅ live + catch-up | ✅ live + catch-up | ✅ `-DryRun` |
| `-custom-duration` | ✅ catch-up (default 300s) | ✅ catch-up (default 300s) | 🟡 `-CustomDuration` (default 300) — catch-up dot-source only |
| `-channel` (multi, comma list) | ✅ catch-up splits on `,` via `IFS=',' read -ra` | ✅ same | 🟡 `[string[]]$Channel` (native array) — catch-up dot-source only. Live is single-channel everywhere |

---

## Behaviors

| Behavior | Linux `iptv_toolkit.sh` | macOS `iptv_toolkit_mac.sh` | PowerShell `IPTV_toolkit.ps1` |
| --- | --- | --- | --- |
| Scheduling backend | ✅ cron (`crontab -`) | 🟡 cron — **but the generated cron command hardcodes `iptv_toolkit.sh`, not `iptv_toolkit_mac.sh`** (line ~475), so a scheduled job would invoke the Linux script | 🟡 Windows Task Scheduler (`schtasks /Create /SC ONCE /TN … /TR …`) |
| Timezone format | ✅ IANA names via Python `zoneinfo` (default `Europe/Paris`) | ✅ IANA names via Python `zoneinfo` (default `Europe/Paris`) | 🟡 Windows TZ IDs via `[TimeZoneInfo]::FindSystemTimeZoneById` (default `Central European Standard Time`). Configs are **not portable** between bash and PowerShell |
| Retry / segment-stitching | ✅ `ffmpeg_with_retry` (max 5). On probe-fail **assumes the requested duration was achieved** and keeps going; concats via `merge_ts_segments` | ✅ identical logic to Linux | 🟡 `Invoke-FfmpegWithRetry` (max 5, `MinRemainingSeconds=10`). On probe-fail (`segDuration -eq 0`) it **stops retrying** and deletes the segment — opposite of the bash "assume achieved" behavior |
| Remux `.ts` → `.mkv` | ✅ default on; `-no-remux` skips (`-map 0 -c copy -avoid_negative_ts make_zero`) | ✅ identical | ✅ `Remux-TSFileToMKV`, same ffmpeg args |
| Config format | ✅ `Settings/iptv_configs.sh` — `config_NAME()` bash functions (shared with macOS) | ✅ **same file** `Settings/iptv_configs.sh` | 🟡 `Settings/IPTVConfigs.ps1` — `$Global:IPTVConfigs` nested hashtable. Separate config, not shared with bash |
| Channel-map representation | ✅ bash-4 associative array `declare -gA CHANNEL_MAP=(...)`; access `${CHANNEL_MAP[$k]}`, `${!CHANNEL_MAP[@]}` | 🟡 bash-3.2 has no assoc arrays: config is rewritten on the fly (`_config_to_bash3` awk) into a flat `_CHANNEL_MAP_STR` string, queried by `cm_get`/`cm_has`/`cm_keys` shims | 🟡 nested hashtable `ChannelMap = @{ … }`; access `.ContainsKey()`, `.Keys` |
| Config sourcing | ✅ direct `source "$CONFIG_FILE"` | 🟡 `_config_to_bash3` rewrites `declare -gA CHANNEL_MAP=(…)` into a `_CHANNEL_MAP_STR='…'` assignment in a temp file, then sources that | 🟡 dot-sources `Settings\IPTVConfigs.ps1` |
| Duplicate `CHANNEL_MAP` key | 🟡 bash-4 associative array keeps the **LAST** duplicate key's value | 🟡 the bash-3.2 `cm_get` shim resolves the **FIRST** matching line — **opposite of Linux** for the same config file | 🟡 PowerShell hashtable literal with a duplicate key **throws at parse time** |
| ffmpeg / ffprobe binary override | ✅ `FFMPEG_BIN` / `FFPROBE_BIN` from config (default `ffmpeg`/`ffprobe`) | ✅ same, **plus `_resolve_bin` fallback**: if the configured binary is missing on the host it falls back to `ffmpeg`/`ffprobe` | ❌ `deferred` — `ffmpeg`/`ffprobe` are hardcoded string literals in every invocation; no override |
| Default live audio mapping | 🟡 `-map 0:v? -map 0:a:0` (first audio track) | 🟡 `-map 0:v? -map 0:a:0` (first audio track) | 🟡 `-map 0:v? -map 0:a?` (**all** audio tracks) — differs from bash |
| Output directory | 🟡 `$OUTPUT_DIR` from config | 🟡 `$OUTPUT_DIR` from config | 🟡 hardcoded `$HOME/Videos` — not configurable |
| Fast load-guard before record | ✅ `_load_guard` — required fields, format style, non-empty map, OUTPUT_DIR | ✅ same | ❌ `deferred` |
| Shared stream URL builders | ✅ `_live_stream_url` / `_catchup_stream_url` (record + check-channels) | ✅ same | ❌ `deferred` — URLs built inline |
| Test harness (bats) | ✅ Linux suite under bash 4+ (assoc-array path) | ✅ macOS suite under bash 3.2 (shim path) | ❌ `deferred` — no PowerShell tests |
| Source-without-dispatch / `IPTV_CONFIG_FILE` | ✅ main-guard (`BASH_SOURCE`==`$0`); config path overridable | ✅ same main-guard + override | ❌ `deferred` |

---

## Linux vs macOS divergences (same behavior, different code)

These are deliberate bash-4 → bash-3.2 ports; call them out when touching either file:

- **Negative array index:** Linux `${channels[-1]}` vs macOS `${channels[${#channels[@]}-1]}` (bash 3.2 has no negative indexing).
- **Lowercasing:** Linux `${_yn,,}` / `${_ts_yn,,}` parameter expansion vs macOS `_lc()` helper (`tr '[:upper:]' '[:lower:]'`).
- **Channel map:** Linux associative array (`declare -gA`, `${CHANNEL_MAP[$k]}`, `${!CHANNEL_MAP[@]}`) vs macOS `cm_get`/`cm_has`/`cm_keys` string shims over `_CHANNEL_MAP_STR`.
- **Config sourcing:** Linux `source` directly vs macOS `_config_to_bash3` awk rewrite → temp file → source.
- **Duplicate-key resolution:** associative array keeps the **last** duplicate (Linux) vs `cm_get` returns the **first** (macOS) — a real behavioral difference for a malformed/duplicated config.
- **Cron command target (bug):** macOS `-schedule` writes a cron entry that runs `iptv_toolkit.sh` (the Linux script), not `iptv_toolkit_mac.sh`.
- **Cron tag format:** identical in both — `IPTV_record_<channel>_<YYYYMMDD>_<HHmm>`, parsed back by `remove-jobs`.
