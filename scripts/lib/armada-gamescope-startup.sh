#!/usr/bin/bash
# Read a startup FIFO without imposing a deadline on an absent Anland consumer.
# Called by the gamescope-session script, which owns socket and gamescope_pid.
armada_wait_gamescope_startup() {
    if [[ ${BACKEND:-} != anland ]]; then
        read -r -t 15 response_x_display response_wl_display <>"$socket"
        return
    fi
    local startup_fd part record= status process_stat process_state
    printf '%s\n' 'gamescope-session-plus: waiting for Anland consumer; no startup deadline' >&2
    exec {startup_fd}<>"$socket" || return 1
    while :; do
        part=
        IFS= read -r -t 1 part <&"$startup_fd"
        status=$?
        record+=$part
        if (( status == 0 )); then
            IFS=' ' read -r response_x_display response_wl_display <<<"$record"
            exec {startup_fd}>&-
            [[ -n $response_x_display && -n $response_wl_display ]]
            return
        fi
        if (( status <= 128 )) || ! kill -0 "$gamescope_pid" 2>/dev/null; then
            exec {startup_fd}>&-
            return 1
        fi
        # kill -0 succeeds for a zombie until the parent reaps it.
        if IFS= read -r process_stat <"/proc/$gamescope_pid/stat"; then
            process_state=${process_stat##*) }
            if [[ ${process_state:0:1} == Z || ${process_state:0:1} == X ]]; then
                exec {startup_fd}>&-
                return 1
            fi
        fi
    done
}
