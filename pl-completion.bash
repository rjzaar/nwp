#!/bin/bash
# NWP CLI (pl) Tab Completion
#
# Add to ~/.bashrc:
#   source /path/to/nwp/pl-completion.bash
#
# Or install system-wide:
#   sudo cp pl-completion.bash /etc/bash_completion.d/pl

_pl_completions() {
    local cur prev words cword
    _init_completion || return

    # Main commands
    local commands="install delete make backup restore copy dev2stg stg2prod prod2stg stg2live live2stg live2prod live produce test schedule security-check security-update gitlab-create gitlab-list setup list status version help"

    # Schedule subcommands
    local schedule_commands="install remove list show run"

    # Test flags
    local test_flags="-l -t -u -k -f -s -b -p --ci"

    # Backup flags
    local backup_flags="-b -g --bundle --incremental --push-all"

    # Get NWP directory
    local nwp_dir="${COMP_WORDS[0]%/*}"
    if [ "$nwp_dir" = "${COMP_WORDS[0]}" ]; then
        nwp_dir="."
    fi

    # Get list of sites from cnwp.yml
    local sites=""
    if [ -f "${nwp_dir}/cnwp.yml" ]; then
        sites=$(awk '/^sites:/{in_sites=1;next} in_sites && /^[a-zA-Z]/ && !/^  /{in_sites=0} in_sites && /^  [a-zA-Z_-]+:/{name=$0;gsub(/^  /,"",name);gsub(/:.*/,"",name);print name}' "${nwp_dir}/cnwp.yml" 2>/dev/null)
    fi

    # Get list of recipes
    local recipes=""
    if [ -f "${nwp_dir}/cnwp.yml" ]; then
        recipes=$(awk '/^recipes:/{in_recipes=1;next} in_recipes && /^[a-zA-Z]/ && !/^  /{in_recipes=0} in_recipes && /^  [a-zA-Z_-]+:/{name=$0;gsub(/^  /,"",name);gsub(/:.*/,"",name);print name}' "${nwp_dir}/cnwp.yml" 2>/dev/null)
    fi

    case "${COMP_CWORD}" in
        1)
            # First argument - command
            COMPREPLY=($(compgen -W "${commands}" -- "${cur}"))
            ;;
        2)
            # Second argument - depends on command
            case "${prev}" in
                install)
                    COMPREPLY=($(compgen -W "${recipes}" -- "${cur}"))
                    ;;
                delete|make|backup|restore|copy|dev2stg|stg2prod|prod2stg|stg2live|live2stg|live2prod|live|produce|test|status)
                    COMPREPLY=($(compgen -W "${sites}" -- "${cur}"))
                    ;;
                schedule)
                    COMPREPLY=($(compgen -W "${schedule_commands}" -- "${cur}"))
                    ;;
                gitlab-list)
                    COMPREPLY=($(compgen -W "sites backups" -- "${cur}"))
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            ;;
        3)
            # Third argument
            case "${words[1]}" in
                install)
                    # Suggest a site name (use current word)
                    COMPREPLY=()
                    ;;
                copy)
                    COMPREPLY=($(compgen -W "${sites}" -- "${cur}"))
                    ;;
                schedule)
                    case "${words[2]}" in
                        install|remove|show|run)
                            COMPREPLY=($(compgen -W "${sites}" -- "${cur}"))
                            ;;
                    esac
                    ;;
                test)
                    COMPREPLY=($(compgen -W "${test_flags} ${sites}" -- "${cur}"))
                    ;;
                backup)
                    COMPREPLY=($(compgen -W "${backup_flags}" -- "${cur}"))
                    ;;
            esac
            ;;
        *)
            # Additional arguments
            case "${words[1]}" in
                test)
                    COMPREPLY=($(compgen -W "${test_flags} ${sites}" -- "${cur}"))
                    ;;
                backup)
                    COMPREPLY=($(compgen -W "${backup_flags}" -- "${cur}"))
                    ;;
            esac
            ;;
    esac
}

complete -F _pl_completions pl
complete -F _pl_completions ./pl
