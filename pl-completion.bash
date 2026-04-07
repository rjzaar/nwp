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

    # Main commands - all NWP commands
    local commands="install delete make uninstall backup restore copy dev2stg stg2prod prod2stg stg2live live2stg live2prod live produce test testos test-nwp schedule security security-check security-update security-audit import sync modify migration podcast email badges storage rollback coder verify report gitlab-create gitlab-list setup setup-ssh list status version migrate-secrets help"

    # Schedule subcommands
    local schedule_commands="install remove list show run"

    # Security subcommands
    local security_commands="check update audit"

    # Email subcommands
    local email_commands="setup add test reroute list"

    # Badge subcommands
    local badges_commands="show add update coverage markdown"

    # Storage subcommands
    local storage_commands="auth list info files upload delete keys key-delete"

    # Rollback subcommands
    local rollback_commands="list execute verify cleanup"

    # Coder subcommands
    local coder_commands="add list remove"

    # Theme subcommands
    local theme_commands="setup watch build lint info"

    # Test flags
    local test_flags="-l -u -k -f -s -b -p --ci --all"

    # Backup flags
    local backup_flags="-b -g -e --bundle --incremental --push-all --sanitize --sanitize-level"

    # Restore flags
    local restore_flags="-b -f -o -y"

    # Delete flags
    local delete_flags="-b -k -y"

    # Make flags
    local make_flags="-v -p -d -y"

    # Live flags
    local live_flags="--type --expires --delete --status"

    # Live types
    local live_types="dedicated shared temporary"

    # Get NWP directory
    local nwp_dir="${COMP_WORDS[0]%/*}"
    if [ "$nwp_dir" = "${COMP_WORDS[0]}" ]; then
        nwp_dir="."
    fi

    # Get list of sites from nwp.yml
    local sites=""
    if [ -f "${nwp_dir}/nwp.yml" ]; then
        sites=$(awk '/^sites:/{in_sites=1;next} in_sites && /^[a-zA-Z]/ && !/^  /{in_sites=0} in_sites && /^  [a-zA-Z_-]+:/{name=$0;gsub(/^  /,"",name);gsub(/:.*/,"",name);print name}' "${nwp_dir}/nwp.yml" 2>/dev/null)
    fi

    # Get list of recipes
    local recipes=""
    if [ -f "${nwp_dir}/nwp.yml" ]; then
        recipes=$(awk '/^recipes:/{in_recipes=1;next} in_recipes && /^[a-zA-Z]/ && !/^  /{in_recipes=0} in_recipes && /^  [a-zA-Z_-]+:/{name=$0;gsub(/^  /,"",name);gsub(/:.*/,"",name);print name}' "${nwp_dir}/nwp.yml" 2>/dev/null)
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
                delete)
                    COMPREPLY=($(compgen -W "${delete_flags} ${sites}" -- "${cur}"))
                    ;;
                make)
                    COMPREPLY=($(compgen -W "${make_flags} ${sites}" -- "${cur}"))
                    ;;
                backup)
                    COMPREPLY=($(compgen -W "${backup_flags} ${sites}" -- "${cur}"))
                    ;;
                restore)
                    COMPREPLY=($(compgen -W "${restore_flags} ${sites}" -- "${cur}"))
                    ;;
                copy|dev2stg|stg2prod|prod2stg|stg2live|live2stg|live2prod|produce|status|testos|migration|sync|modify|verify|podcast)
                    COMPREPLY=($(compgen -W "${sites}" -- "${cur}"))
                    ;;
                import)
                    # Suggest server names (could be empty or require user input)
                    COMPREPLY=()
                    ;;
                live)
                    COMPREPLY=($(compgen -W "${live_flags} ${sites}" -- "${cur}"))
                    ;;
                test)
                    COMPREPLY=($(compgen -W "${test_flags} ${sites}" -- "${cur}"))
                    ;;
                theme)
                    COMPREPLY=($(compgen -W "${theme_commands}" -- "${cur}"))
                    ;;
                schedule)
                    COMPREPLY=($(compgen -W "${schedule_commands}" -- "${cur}"))
                    ;;
                security)
                    COMPREPLY=($(compgen -W "${security_commands}" -- "${cur}"))
                    ;;
                security-check|security-update|security-audit)
                    COMPREPLY=($(compgen -W "--all ${sites}" -- "${cur}"))
                    ;;
                email)
                    COMPREPLY=($(compgen -W "${email_commands}" -- "${cur}"))
                    ;;
                badges)
                    COMPREPLY=($(compgen -W "${badges_commands}" -- "${cur}"))
                    ;;
                storage)
                    COMPREPLY=($(compgen -W "${storage_commands}" -- "${cur}"))
                    ;;
                rollback)
                    COMPREPLY=($(compgen -W "${rollback_commands}" -- "${cur}"))
                    ;;
                coder)
                    COMPREPLY=($(compgen -W "${coder_commands}" -- "${cur}"))
                    ;;
                report|migrate-secrets)
                    # These commands don't take arguments
                    COMPREPLY=()
                    ;;
                gitlab-list)
                    COMPREPLY=($(compgen -W "sites backups" -- "${cur}"))
                    ;;
                gitlab-create)
                    # Suggest project name
                    COMPREPLY=()
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
                    # Third arg for install is sitename - suggest based on recipe
                    COMPREPLY=()
                    ;;
                copy)
                    COMPREPLY=($(compgen -W "${sites}" -- "${cur}"))
                    ;;
                theme)
                    case "${words[2]}" in
                        setup|watch|build|lint|info)
                            COMPREPLY=($(compgen -W "${sites}" -- "${cur}"))
                            ;;
                    esac
                    ;;
                schedule)
                    case "${words[2]}" in
                        install|remove|show|run)
                            COMPREPLY=($(compgen -W "${sites}" -- "${cur}"))
                            ;;
                    esac
                    ;;
                security)
                    case "${words[2]}" in
                        check|update|audit)
                            COMPREPLY=($(compgen -W "--all --auto ${sites}" -- "${cur}"))
                            ;;
                    esac
                    ;;
                email)
                    case "${words[2]}" in
                        add|test|reroute)
                            COMPREPLY=($(compgen -W "${sites}" -- "${cur}"))
                            ;;
                    esac
                    ;;
                badges)
                    case "${words[2]}" in
                        show|add|update|coverage|markdown)
                            COMPREPLY=($(compgen -W "${sites}" -- "${cur}"))
                            ;;
                    esac
                    ;;
                storage)
                    case "${words[2]}" in
                        info|files)
                            # Suggest bucket names (could pull from storage list)
                            COMPREPLY=()
                            ;;
                        upload)
                            # First arg is file path
                            COMPREPLY=($(compgen -f -- "${cur}"))
                            ;;
                    esac
                    ;;
                rollback)
                    case "${words[2]}" in
                        execute|verify)
                            COMPREPLY=($(compgen -W "${sites}" -- "${cur}"))
                            ;;
                    esac
                    ;;
                coder)
                    case "${words[2]}" in
                        add|remove)
                            # Coder name - let user type
                            COMPREPLY=()
                            ;;
                    esac
                    ;;
                test)
                    COMPREPLY=($(compgen -W "${test_flags} ${sites}" -- "${cur}"))
                    ;;
                backup)
                    COMPREPLY=($(compgen -W "${backup_flags} ${sites}" -- "${cur}"))
                    ;;
                restore)
                    COMPREPLY=($(compgen -W "${restore_flags} ${sites}" -- "${cur}"))
                    ;;
                delete)
                    COMPREPLY=($(compgen -W "${delete_flags} ${sites}" -- "${cur}"))
                    ;;
                make)
                    COMPREPLY=($(compgen -W "${make_flags} ${sites}" -- "${cur}"))
                    ;;
                live)
                    if [[ "${words[2]}" == "--type" || "${words[2]}" == "--type="* ]]; then
                        COMPREPLY=($(compgen -W "${live_types}" -- "${cur}"))
                    else
                        COMPREPLY=($(compgen -W "${live_flags} ${sites}" -- "${cur}"))
                    fi
                    ;;
                gitlab-create)
                    COMPREPLY=($(compgen -W "sites backups" -- "${cur}"))
                    ;;
            esac
            ;;
        *)
            # Additional arguments - offer flags and sites where appropriate
            case "${words[1]}" in
                test)
                    COMPREPLY=($(compgen -W "${test_flags} ${sites}" -- "${cur}"))
                    ;;
                backup)
                    COMPREPLY=($(compgen -W "${backup_flags} ${sites}" -- "${cur}"))
                    ;;
                restore)
                    COMPREPLY=($(compgen -W "${restore_flags} ${sites}" -- "${cur}"))
                    ;;
                delete)
                    COMPREPLY=($(compgen -W "${delete_flags} ${sites}" -- "${cur}"))
                    ;;
                live)
                    COMPREPLY=($(compgen -W "${live_flags} ${sites}" -- "${cur}"))
                    ;;
                security)
                    COMPREPLY=($(compgen -W "--all --auto ${sites}" -- "${cur}"))
                    ;;
            esac
            ;;
    esac
}

complete -F _pl_completions pl
complete -F _pl_completions ./pl
