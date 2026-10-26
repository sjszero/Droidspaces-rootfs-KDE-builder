#!/usr/bin/env bash

desktop_normalize() {
    case "${1:-}" in
        none) printf '%s\n' none ;;
        KDE|kde) printf '%s\n' kde ;;
        'KDE mobile'|kde-mobile) printf '%s\n' kde-mobile ;;
        GNOME|gnome) printf '%s\n' gnome ;;
        'Anland Next'|anland-next) printf '%s\n' anland-next ;;
        Niri|niri) printf '%s\n' niri ;;
        Hyprland|hyprland) printf '%s\n' hyprland ;;
        Mango|mango) printf '%s\n' mango ;;
        Denial|denial) printf '%s\n' denial ;;
        *) return 1 ;;
    esac
}

desktop_label() {
    case "${1:-}" in
        none) printf '%s\n' none ;;
        kde) printf '%s\n' KDE ;;
        kde-mobile) printf '%s\n' 'KDE mobile' ;;
        gnome) printf '%s\n' GNOME ;;
        anland-next) printf '%s\n' 'Anland Next' ;;
        niri) printf '%s\n' Niri ;;
        hyprland) printf '%s\n' Hyprland ;;
        mango) printf '%s\n' Mango ;;
        denial) printf '%s\n' Denial ;;
        *) return 1 ;;
    esac
}

display_backend_normalize() {
    case "${1:-}" in
        X11|x11|'') printf '%s\n' x11 ;;
        'Anland Wayland'|anland-wayland) printf '%s\n' anland-wayland ;;
        *) return 1 ;;
    esac
}

display_backend_label() {
    case "${1:-}" in
        x11) printf '%s\n' X11 ;;
        anland-wayland) printf '%s\n' Wayland ;;
        *) return 1 ;;
    esac
}

target_is_known() {
    case "${1:-}" in
        Debian-13|Ubuntu-24|Ubuntu-25|Ubuntu-26|Fedora-43|Fedora-44|Arch|ArmadaOS) return 0 ;;
        *) return 1 ;;
    esac
}

desktop_target_supported() {
    local target="${1:-}"
    local desktop="${2:-}"

    target_is_known "$target" || return 1
    # ArmadaOS already ships its own complete session stack (gamescope/Steam
    # Big Picture plus Plasma). Installing another desktop profile on top would
    # fight armada's session units, so only the stock stack and a plain CLI
    # container are offered.
    if [ "$target" = ArmadaOS ]; then
        case "$desktop" in
            none|kde) return 0 ;;
            *) return 1 ;;
        esac
    fi
    case "$desktop" in
        none|kde) return 0 ;;
        kde-mobile)
            case "$target" in
                Debian-13|Ubuntu-26|Fedora-43|Fedora-44|Arch) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        gnome)
            case "$target" in Debian-13|Ubuntu-26|Fedora-43|Fedora-44|Arch) return 0 ;; *) return 1 ;; esac
            ;;
        anland-next)
            case "$target" in
                Debian-13|Ubuntu-26|Fedora-43|Fedora-44|Arch) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        niri|hyprland|mango|denial)
            case "$target" in Debian-13|Ubuntu-26|Fedora-43|Fedora-44|Arch) return 0 ;; *) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
}

desktop_backend_supported() {
    local target="${1:-}"
    local desktop="${2:-}"
    local backend="${3:-}"

    desktop_target_supported "$target" "$desktop" || return 1
    # ArmadaOS ships its session stack and needs no extra Anland desktop layer
    # for any backend it supports.
    if [ "$target" = ArmadaOS ]; then
        case "$desktop:$backend" in
            none:x11) return 0 ;;
            kde:x11) return 0 ;;
            kde:anland-wayland) return 0 ;;
            *) return 1 ;;
        esac
    fi
    case "$desktop:$backend" in
        none:x11) return 0 ;;
        kde:x11)
            case "$target" in
                Debian-13|Ubuntu-24|Ubuntu-25|Ubuntu-26|Fedora-43|Fedora-44) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        kde:anland-wayland|kde-mobile:anland-wayland)
            case "$target" in
                Debian-13|Ubuntu-26|Fedora-43|Fedora-44|Arch) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        gnome:anland-wayland)
            case "$target" in Debian-13|Ubuntu-26|Fedora-43|Fedora-44|Arch) return 0 ;; *) return 1 ;; esac
            ;;
        anland-next:anland-wayland)
            case "$target" in
                Debian-13|Ubuntu-26|Fedora-43|Fedora-44|Arch) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        niri:anland-wayland|hyprland:anland-wayland|mango:anland-wayland|denial:anland-wayland)
            case "$target" in Debian-13|Ubuntu-26|Fedora-43|Fedora-44|Arch) return 0 ;; *) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
}

desktop_wayland_targets_json() {
    case "${1:-}" in
        kde|kde-mobile|anland-next)
            printf '%s\n' '["Debian-13","Ubuntu-26","Fedora-43","Fedora-44","Arch"]'
            ;;
        gnome|niri|hyprland|mango|denial)
            printf '%s\n' '["Debian-13","Ubuntu-26","Fedora-43","Fedora-44","Arch"]'
            ;;
        *) return 1 ;;
    esac
}

anland_archive_target() {
    case "${1:-}" in
        Debian-13) printf '%s\n' Debian13 ;;
        Ubuntu-26) printf '%s\n' ubuntu2604 ;;
        Fedora-43) printf '%s\n' Fedora43 ;;
        Fedora-44) printf '%s\n' Fedora44 ;;
        Arch) printf '%s\n' Arch ;;
        # ArmadaOS already carries armada's Anland build; the archive target is
        # only used when the optional Droidspaces Anland overlay is requested.
        ArmadaOS) printf '%s\n' ArmadaOS ;;
        *) return 1 ;;
    esac
}