#!/usr/bin/env bash
#
# ss-admin-reset.sh — regain Moodle admin access on ss.nwpcode.org
#
# You run this yourself. It contains NO credentials and stores nothing.
# It SSHes to the server and launches Moodle's own interactive CLI tools;
# any new password is typed live on the server and never logged, echoed,
# committed, or seen by anything but Moodle's password store.
#
# Usage:
#   scripts/ss-admin-reset.sh reset [username]   # reset a password (default user: admin)
#   scripts/ss-admin-reset.sh promote <username> # make an existing user a site admin
#   scripts/ss-admin-reset.sh whoami             # list current site admins
#
# Override the connection if your SSH config differs:
#   SSH_KEY=~/.ssh/other  SSH_HOST=gitlab@ss.nwpcode.org  scripts/ss-admin-reset.sh reset
#
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/gitlab_linode}"
SSH_HOST="${SSH_HOST:-gitlab@ss.nwpcode.org}"
MOODLE_ROOT="${MOODLE_ROOT:-/var/www/ss}"

# Moodle on a newer PHP than its codebase targets floods stderr with
# "PHP Deprecated" notices. Real prompts/output go to stdout; the password
# read uses stdin — so dropping stderr (2>/dev/null) is safe and gives a
# clean screen on each php call below.

run_remote() { ssh -t -i "$SSH_KEY" "$SSH_HOST" "$@"; }

cmd="${1:-reset}"

case "$cmd" in
  reset)
    user="${2:-admin}"
    echo ">> Resetting a Moodle password on $SSH_HOST"
    echo ">> At 'Enter username' type:  $user"
    echo ">> then type the new password at the next prompt."
    echo
    # reset_password.php reads BOTH the username and the new password from
    # stdin, interactively. We must NOT pipe anything in — leaving stdin on
    # the TTY lets you type both prompts. (Piping the username consumed stdin
    # and the password prompt hit EOF.)
    run_remote "sudo -u www-data php $MOODLE_ROOT/admin/cli/reset_password.php 2>/dev/null"
    ;;

  promote)
    user="${2:?usage: ss-admin-reset.sh promote <username>}"
    echo ">> Granting site-admin to existing user '$user' on $SSH_HOST"
    # Append the user's id to the comma-separated siteadmins config without
    # clobbering the existing admins. Read-modify-write via Moodle's own cfg CLI.
    run_remote "
      set -e
      cd '$MOODLE_ROOT'
      uid=\$(sudo -u www-data php -r \"define('CLI_SCRIPT',true); require('config.php'); \\\$u=\\\$DB->get_record('user',['username'=>'$user']); echo \\\$u? \\\$u->id : '';\" 2>/dev/null)
      if [ -z \"\$uid\" ]; then echo \"No such user: $user\" >&2; exit 1; fi
      cur=\$(sudo -u www-data php admin/cli/cfg.php --name=siteadmins 2>/dev/null)
      case \",\$cur,\" in *\",\$uid,\"*) echo \"Already an admin (uid \$uid).\";; \
        *) sudo -u www-data php admin/cli/cfg.php --name=siteadmins --set=\"\$cur,\$uid\" 2>/dev/null; \
           echo \"Added uid \$uid to siteadmins.\";; esac
      sudo -u www-data php admin/cli/purge_caches.php 2>/dev/null
    "
    ;;

  whoami)
    echo ">> Current site admins on $SSH_HOST"
    run_remote "cd '$MOODLE_ROOT' && sudo -u www-data php -r \"define('CLI_SCRIPT',true); require('config.php'); foreach(explode(',', \\\$CFG->siteadmins) as \\\$id){ \\\$u=\\\$DB->get_record('user',['id'=>\\\$id]); if(\\\$u) echo \\\$u->id.'  '.\\\$u->username.'  '.\\\$u->email.PHP_EOL; }\" 2>/dev/null"
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    echo "Usage: ss-admin-reset.sh {reset [username]|promote <username>|whoami}" >&2
    exit 2
    ;;
esac
