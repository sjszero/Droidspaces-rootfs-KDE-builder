#!/usr/bin/bash
# Run a command as an unprivileged account, with or without PAM.
#
# build.sh refuses to run as root, so the gamescope build has to drop
# privileges. runuser opens a PAM session, and pam_limits then fails with
# "cannot open session: Permission denied" whenever a group-based limit has to be
# raised: the build user is in pipewire and gamemode, so @pipewire rtprio/nice
# and @gamemode nice apply, and raising them needs CAP_SYS_RESOURCE. No buildkit
# RUN has that capability, so runuser can never start the build there. setpriv
# changes credentials directly and needs no session.
set -euo pipefail

if (( $# < 2 )); then
    echo 'usage: as-user USER COMMAND [ARG...]' >&2
    exit 2
fi

user=$1
shift

[[ $(id -u) == 0 ]] || { echo 'as-user: must run as root' >&2; exit 1; }
entry=$(getent passwd "$user") || true
[[ -n ${entry:-} ]] || { echo "as-user: no such user: $user" >&2; exit 1; }
IFS=: read -r _ _ uid gid _ home _ <<<"$entry"

# Preferred path: a real login-like session, so pam_limits applies.
if runuser -u "$user" -- true 2>/dev/null; then
    exec runuser -u "$user" -- "$@"
fi

# Fallback: pam_limits cannot run here, so reproduce the open-file budget it
# would have granted. Never lower a limit that is already higher.
hard=$(ulimit -Hn)
if [[ $hard != unlimited ]] && (( hard < 524288 )); then
    ulimit -Hn 524288 2>/dev/null || true
fi
soft=$(ulimit -Sn)
if [[ $soft != unlimited ]] && (( soft < 524288 )); then
    ulimit -Sn 524288 2>/dev/null || true
fi

exec setpriv --reuid="$uid" --regid="$gid" --init-groups \
    env HOME="$home" USER="$user" LOGNAME="$user" "$@"
