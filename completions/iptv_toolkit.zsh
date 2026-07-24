#compdef iptv_toolkit.sh iptv_toolkit_mac.sh
# Zsh completion for iptv_toolkit.sh / iptv_toolkit_mac.sh
#
# Install: place this file (named `_iptv_toolkit`) in a directory on your
# $fpath, then ensure compinit runs. For example:
#     mkdir -p ~/.zsh/completions
#     ln -s "$PWD/completions/iptv_toolkit.zsh" ~/.zsh/completions/_iptv_toolkit
#     # in ~/.zshrc, before `compinit`:
#     fpath=(~/.zsh/completions $fpath)
#     autoload -Uz compinit && compinit
#
# The config file is parsed with grep/sed/awk only — never sourced. Respects
# $IPTV_CONFIG_FILE, else the Settings/iptv_configs.sh next to the script.

_iptv_toolkit_configs() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0
    grep -oE '^config_[A-Za-z0-9_]+[[:space:]]*\(\)' "$cfg" 2>/dev/null \
        | sed -E 's/[[:space:]]*\(\)$//; s/^config_//'
}

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

_iptv_toolkit_config_file() {
    if [[ -n "${IPTV_CONFIG_FILE:-}" ]]; then
        print -r -- "$IPTV_CONFIG_FILE"
        return
    fi
    local cmd="$1" dir=""
    if [[ "$cmd" == */* ]]; then
        dir="${cmd:h}"
    else
        local resolved="${commands[$cmd]}"
        [[ -n "$resolved" ]] && dir="${resolved:h}"
    fi
    print -r -- "${dir:-.}/Settings/iptv_configs.sh"
}

_iptv_toolkit() {
    local -a cmds
    cmds=(setup-config list-channels validate-config check-channels record-live record-catchup remove-provider remove-channel remove-jobs help)

    # Subcommand position (word 2; word 1 is the command itself).
    if (( CURRENT == 2 )); then
        compadd -- $cmds
        return
    fi

    local cur="${words[CURRENT]}" prev="${words[CURRENT-1]}"
    local subcmd="${words[2]}"
    local cfgfile; cfgfile="$(_iptv_toolkit_config_file "${words[1]}")"

    # -config value: provider names.
    if [[ "$prev" == "-config" ]]; then
        local -a configs
        configs=(${(f)"$(_iptv_toolkit_configs "$cfgfile")"})
        compadd -- $configs
        return
    fi

    # -channel value: channels scoped to the -config already on the line.
    if [[ "$prev" == "-channel" ]]; then
        local i cfgname=""
        for (( i = 1; i <= ${#words}; i++ )); do
            [[ "${words[i]}" == "-config" ]] && cfgname="${words[i+1]}"
        done
        local -a chans
        chans=(${(f)"$(_iptv_toolkit_channels "$cfgfile" "$cfgname")"})
        # record-catchup accepts comma lists; complete the trailing segment.
        compadd -q -S '' -- $chans
        return
    fi

    # Per-command flags.
    local -a flags
    case "$subcmd" in
        record-live)     flags=(-config -channel -duration-minutes -start-at -schedule -no-remux -first-audio-only -dry-run) ;;
        record-catchup)  flags=(-config -channel -duration-minutes -start-at -no-remux -first-audio-only -dry-run -custom-duration) ;;
        list-channels)   flags=(-config) ;;
        validate-config) flags=(-config) ;;
        check-channels)  flags=(-config -channel -catchup) ;;
        remove-provider) flags=(-config) ;;
        remove-channel)  flags=(-config -channel) ;;
    esac
    (( ${#flags} )) && compadd -- $flags
}

_iptv_toolkit "$@"
