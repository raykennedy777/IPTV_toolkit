# Bash completion for iptv_toolkit.sh / iptv_toolkit_mac.sh
#
# Install: source this file from your ~/.bashrc, or drop/symlink it into your
# bash-completion directory, e.g.:
#     ln -s "$PWD/completions/iptv_toolkit.bash" \
#           /usr/local/etc/bash_completion.d/iptv_toolkit    # (macOS/Homebrew)
#     ln -s "$PWD/completions/iptv_toolkit.bash" \
#           /etc/bash_completion.d/iptv_toolkit              # (Linux)
#
# The config file is parsed with grep/sed/awk only — the (untrusted) config is
# never sourced. Respects $IPTV_CONFIG_FILE, else the Settings/iptv_configs.sh
# next to the script being completed. Works with no config file (commands/flags
# only).

# List provider names (config_NAME) from the config file text.
_iptv_toolkit_configs() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0
    grep -oE '^config_[A-Za-z0-9_]+[[:space:]]*\(\)' "$cfg" 2>/dev/null \
        | sed -E 's/[[:space:]]*\(\)$//; s/^config_//'
}

# List CHANNEL_MAP keys for one provider from the config file text.
_iptv_toolkit_channels() {
    local cfg="$1" config="$2"
    [[ -f "$cfg" && -n "$config" ]] || return 0
    awk -v prov="config_${config}" '
        $0 ~ ("^" prov "[[:space:]]*\\(\\)") { inblk = 1; next }
        inblk && /^}/ { inblk = 0 }
        inblk {
            s = $0
            while (match(s, /\["[^"]*"\]/)) {
                print substr(s, RSTART + 2, RLENGTH - 4)
                s = substr(s, RSTART + RLENGTH)
            }
        }
    ' "$cfg"
}

# Resolve the config file path for the command word being completed.
_iptv_toolkit_config_file() {
    if [[ -n "${IPTV_CONFIG_FILE:-}" ]]; then
        printf '%s' "$IPTV_CONFIG_FILE"
        return
    fi
    local cmd="$1" dir=""
    if [[ "$cmd" == */* ]]; then
        dir="$(cd "$(dirname "$cmd")" 2>/dev/null && pwd)"
    else
        local resolved
        resolved="$(command -v "$cmd" 2>/dev/null)"
        [[ -n "$resolved" ]] && dir="$(cd "$(dirname "$resolved")" 2>/dev/null && pwd)"
    fi
    printf '%s' "${dir:-.}/Settings/iptv_configs.sh"
}

_iptv_toolkit_complete() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local cmds="setup-config list-channels validate-config check-channels record-live record-catchup remove-provider remove-channel remove-jobs help"

    # Subcommand position.
    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
        return 0
    fi

    local cfgfile subcmd
    cfgfile="$(_iptv_toolkit_config_file "${COMP_WORDS[0]}")"
    subcmd="${COMP_WORDS[1]}"

    # -config value: provider names.
    if [[ "$prev" == "-config" ]]; then
        COMPREPLY=( $(compgen -W "$(_iptv_toolkit_configs "$cfgfile")" -- "$cur") )
        return 0
    fi

    # -channel value: channels scoped to the -config already on the line.
    # record-catchup accepts comma-separated lists — complete the last segment.
    if [[ "$prev" == "-channel" ]]; then
        local i cfgname=""
        for (( i = 0; i < ${#COMP_WORDS[@]}; i++ )); do
            [[ "${COMP_WORDS[i]}" == "-config" ]] && cfgname="${COMP_WORDS[i+1]}"
        done
        local chans base="" tail="$cur"
        chans="$(_iptv_toolkit_channels "$cfgfile" "$cfgname")"
        if [[ "$cur" == *,* ]]; then base="${cur%,*},"; tail="${cur##*,}"; fi
        COMPREPLY=()
        local m
        for m in $(compgen -W "$chans" -- "$tail"); do
            COMPREPLY+=( "${base}${m}" )
        done
        return 0
    fi

    # Per-command flags.
    local flags=""
    case "$subcmd" in
        record-live)     flags="-config -channel -duration-minutes -start-at -schedule -no-remux -first-audio-only -dry-run" ;;
        record-catchup)  flags="-config -channel -duration-minutes -start-at -no-remux -first-audio-only -dry-run -custom-duration" ;;
        list-channels)   flags="-config" ;;
        validate-config) flags="-config" ;;
        check-channels)  flags="-config -channel -catchup" ;;
        remove-provider) flags="-config" ;;
        remove-channel)  flags="-config -channel" ;;
    esac
    if [[ -n "$flags" ]]; then
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
    fi
    return 0
}

# Registered on the basenames; bash falls back to the basename compspec for
# path-qualified invocations like ./iptv_toolkit.sh.
complete -F _iptv_toolkit_complete iptv_toolkit.sh iptv_toolkit_mac.sh
