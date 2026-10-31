# ArmadaOS (Armada: SteamOS-like Fedora bootc) adapted for Droidspaces containers.
#
# Unlike the desktop templates in this repository, ArmadaOS is not assembled from
# a stock fedora:44 base plus RPMs. The Armada rootfs is produced by the armada
# project (Containerfile + build_files/*.sh) from ~30 separately published
# package images, so re-implementing that here would duplicate and silently
# drift from upstream. Instead this template starts from the published,
# anonymously pullable bootc image and applies only what a container needs:
#
#   1. drop bootc/OSTree/EFI/bootloader/kernel-boot state that cannot work in a
#      container without a bootloader or real block devices;
#   2. stop the hardware and platform services a container has no hardware for,
#      and keep the ones that matter (session, Steam, input, audio, GPU);
#   3. add the same Droidspaces compatibility layer the other templates get
#      (aid_inet/aid_net_raw groups, PID1-friendly journald, NAT DHCP, udev
#      read-only fixes, group memberships, user creation);
#   4. bake the Anland container packages in when requested.
#
# $DESKTOP selects which Armada session stack is kept. ArmadaOS ships its own
# gamescope/Steam Big Picture session, so the meaningful choices are the
# Armada Steam session (default, matches `kde`/`none` inputs) and keeping the
# KDE Plasma desktop reachable for a docked/desktop experience.

ARG ARMADA_BASE_IMAGE=ghcr.io/armada-os/armada:testing

FROM ${ARMADA_BASE_IMAGE} AS customizer

#######################################################
ARG DESKTOP
# true -> SDDM autologins straight into Steam Big Picture on boot.
# false -> the container boots to a console with no graphics session.
ARG DESKTOP_AUTOSTART=true
ARG PulseAudio
ARG ENABLE_zh_tz_ARG
ARG ENABLE_binfmt_ARG
ARG ENABLE_yj_ARG
ARG ENABLE_mesa_ARG
ARG ENABLE_kfgj_ARG
ARG ENABLE_zip_ARG
ARG ENABLE_docker_ARG
ARG ENABLE_srf_ARG
ARG DISPLAY_BACKEND
ARG ENABLE_8gen2_wayland_ARG
ARG ENABLE_systemd257_ARG
ARG USERNAME
ARG ANLAND_RELEASE_REPOSITORY=Goldzxcbug/droidspaces-package
ARG ANLAND_PACKAGE_REVISION=unknown
######################################################

ENV DEBIAN_FRONTEND=noninteractive

# xdg-desktop-portal is unsafe in the Droidspaces/ArmadaOS runtime used here:
# an external report says Android may kill plasmashell after it is installed.
# Block the package name prefix before any later DNF transaction can pull it in.
RUN set -eux; \
    conf=/etc/dnf/dnf.conf; \
    mkdir -p /etc/dnf; \
    touch "$conf"; \
    for key in excludepkgs exclude; do \
        if grep -q "^${key}=" "$conf"; then \
            if ! grep -F "$key=" "$conf" | grep -Fq 'xdg-desktop-portal*'; then \
                sed -i "/^${key}=/ s/$/,xdg-desktop-portal*/" "$conf"; \
            fi; \
        else \
            printf '%s=xdg-desktop-portal*\n' "$key" >> "$conf"; \
        fi; \
    done; \
    for pkg in $(rpm -qa --qf '%{NAME}\n' | grep '^xdg-desktop-portal' || true); do \
        rpm -e --nodeps "$pkg"; \
    done; \
    test -z "$(rpm -qa --qf '%{NAME}\n' | grep '^xdg-desktop-portal' || true)"

# The armada image ships armada's own account; Droidspaces templates use a
# caller-chosen username. Keep armada's user working (its Steam/Plasma session
# files, sudoers and home are wired to it) and add the requested one alongside.
ARG ARMADA_USER=armada

# --- 1. Droidspaces userspace tooling -------------------------------------
# These are the same helper scripts every other template installs. Only the
# container-relevant ones are copied; desktop installers (install-desktop,
# install-anland-*, configure-desktop) are meaningless here because the desktop
# already comes from the armada image.
COPY scripts/install-usb-manager.sh /usr/local/sbin/install-droidspaces-usb-manager
COPY scripts/systemd257.sh /usr/local/sbin/systemd257
COPY scripts/tui/droidspaces-tui.sh /usr/local/bin/droidspaces-tui
COPY scripts/install-anland-desktop.sh /usr/local/sbin/install-anland-desktop
# The exception to the rule above: the armada image's own KWin has no Anland
# backend, so desktop mode needs this installer run at build time (see the
# DISPLAY_BACKEND=anland-wayland block further down), not just copied for the
# user to invoke later.
COPY scripts/tui/install-anland-kde.sh /usr/local/sbin/install-anland-kde
COPY scripts/tui/install-mesa.sh /usr/local/sbin/install-mesa
COPY scripts/etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf /tmp/Anland-Audio.conf
RUN if [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
        install -D -m 0644 /tmp/Anland-Audio.conf /etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf; \
    fi && \
    rm -f /tmp/Anland-Audio.conf

# ArmadaOS is an ostree/bootc image: /etc and /usr are read-only by default and
# several paths are symlinks into /usr. rpm/dnf writes need mutable paths.
RUN chmod +x /usr/local/sbin/install-droidspaces-usb-manager \
             /usr/local/bin/droidspaces-tui \
             /usr/local/sbin/install-anland-desktop \
             /usr/local/sbin/install-anland-kde \
             /usr/local/sbin/install-mesa && \
    ln -sf droidspaces-tui /usr/local/bin/dstui && \
    ln -sf droidspaces-tui /usr/local/bin/ds-tui

# --- 2. Strip boot-only state ---------------------------------------------
# A bootc image carries the OSTree deployment, kernel, initramfs, EFI payloads
# and bootupd state. None of it can be used inside a container: there is no
# bootloader, no ESP and no real root block device, and bootc/rpm-ostree would
# try to "upgrade" a read-only ostree deployment that Droidspaces never mounts.
RUN set -eux; \
    rm -rf \
        /sysroot \
        /ostree \
        /boot/efi \
        /boot/loader* \
        /boot/grub2 \
        /boot/ostree \
        /run/ostree-booted; \
    # Keep /usr/lib/modules (module metadata is still useful) but drop the
    # kernel+initramfs blobs, which the host kernel provides instead.
    find /boot -maxdepth 1 -type f \
        \( -name 'vmlinuz*' -o -name 'initramfs*' -o -name 'initrd*' \
           -o -name 'System.map*' -o -name 'config-*' -o -name '.*.hmac' \) \
        -delete 2>/dev/null || true; \
    rm -rf /usr/lib/ostree /usr/lib/bootupd /usr/libexec/bootupd 2>/dev/null || true

# Ostree/bootc package management cannot function without a deployment, and
# leaving it enabled makes `dnf` inside the container fail confusingly. rpmostree
# and bootc are removed; dnf/rpm keep working as normal Fedora tooling.
RUN set -eux; \
    for pkg in bootc rpm-ostree bootupd ostree-libs ostree; do \
        if rpm -q "$pkg" >/dev/null 2>&1; then \
            dnf -y remove --no-autoremove "$pkg" || true; \
        fi; \
    done; \
    # Removing ostree can pull in leftovers that own ostree paths.
    rm -rf /usr/lib/ostree /usr/lib/bootupd /etc/ostree /var/lib/rpm-ostree; \
    dnf clean all; \
    rm -rf /var/cache/dnf/* /var/cache/rpm-ostree/*

# bootc images move /home and /mnt into /var and leave symlinks behind, and
# those links dangle until ostree mounts /var. A container never does that, so
# materialise each one as a real directory. Droidspaces templates and the
# container's own mounts all expect plain directories here.
#
# /mnt matters beyond cosmetics: install-usb-manager.sh runs
# `install -d -m 0755 /mnt/usb-storage`, and install(1) fails with
# "cannot create directory '/mnt': File exists" when a path component is a
# symlink whose target does not exist.
#
# Only a dangling link is rewritten. A link that resolves is left untouched so
# this can never relocate an existing tree.
RUN set -eux; \
    if [ -L /home ] && [ -d /var/home ]; then \
        rm -f /home; \
        mv /var/home /home; \
    fi; \
    for dir in home mnt opt srv; do \
        if [ -L "/$dir" ] && [ ! -e "/$dir" ]; then \
            rm -f "/$dir"; \
        fi; \
        mkdir -p "/$dir"; \
    done; \
    # /var/home is referenced by armada units and passwd entries; point it back.
    if [ ! -e /var/home ]; then ln -sfn /home /var/home; fi

# --- 3. Container platform limits -----------------------------------------
# Armada enables a large list of services that assume real hardware, an ESP, a
# device tree and a graphical seat on real DRM devices. Mask the ones that
# cannot work and would otherwise fail noisily or hang boot.
RUN set -eux; \
    mkdir -p /etc/systemd/system; \
    for unit in \
        armada-bootimg-sync.service \
        armada-esp-rename.service \
        armada-boot-hotkeys.service \
        armada-installer-visibility.service \
        armada-update-reserve.service \
        armada-fixups.service \
        armada-device-quirks.service \
        armada-input-calibration.service \
        armada-controller-type.service \
        armada-rgb.service \
        armada-rgb-brightness-watch.service \
        armada-rgb-brightness-watch.path \
        armada-splash-early.service \
        armada-splash-stall.service \
        armada-splash-reboot-screen.service \
        armada-splash-poweroff-screen.service \
        armada-guestos.service \
        usr-share-guestos-android.mount \
        armada-waydroid-input.service \
        waydroid-container.service \
        jupiter-biosupdate \
        armada-steam-default-session.service \
        armada-steamapps.service \
        armada-flatpak-setup.service \
        armada-mtp.service \
        inputplumber.service \
        armada-powerd.service \
        steamos-manager-session-cleanup.service \
        armada-steam-charging-eta.service \
        bootc-generic-growpart.service \
        var-lib-nfs-rpc_pipefs.mount \
        chronyd.service \
        bootc-fetch-apply-updates.timer \
        bootloader-update.service \
        irqbalance.service \
        systemd-backlight@.service \
        systemd-hibernate.service \
        systemd-hybrid-sleep.service \
        systemd-suspend-then-hibernate.service \
        flatpak-add-fedora-repos.service \
        armada-save-devcoredump@.service \
        bluetooth.service; do \
        ln -sf /dev/null "/etc/systemd/system/${unit}"; \
    done; \
    # Global (user-session) masks for the same hardware-bound units.
    mkdir -p /etc/systemd/user; \
    for unit in \
        steamos-manager-configure-cecd.service \
        armada-steam-default-session.service \
        armada-steam-charging-eta.service; do \
        ln -sf /dev/null "/etc/systemd/user/${unit}"; \
    done

# sddm, seatd, armada-control and armada-session-default are deliberately NOT
# masked. SDDM is the component that actually starts the graphical session here:
# it autologins into gamescope-session-steam.desktop, and that user instance is
# what brings up gamescope + Steam Big Picture. Masking it leaves the container
# with no way to start a session at all. Section 7 supplies the container-safe
# session switching and power path around it, and section 7l decides whether the
# container takes that path automatically at boot.
#
# The display manager is intentionally not wired up here: whether SDDM starts at
# boot is the user's choice (DESKTOP_AUTOSTART), so section 7l creates
# display-manager.service only when autostart is enabled.

# Armada pins the graphical seat to DRM devices and a specific session. In a
# container there is no VT and no udev-tagged seat, so the session is started by
# SDDM on the main console via the container drop-ins added in section 7.
RUN set -eux; \
    mkdir -p /etc/systemd/system/multi-user.target.wants \
             /etc/systemd/system/graphical.target.wants; \
    # Keep the units a container genuinely needs, and let the graphical target
    # actually pull in the display manager.
    GUEST_SYSTEMD_PATH=/usr/lib/systemd/system; \
    for unit in dbus.service armada-session-default.service; do \
        if [ -f "$GUEST_SYSTEMD_PATH/$unit" ]; then \
            ln -sf "$GUEST_SYSTEMD_PATH/$unit" "/etc/systemd/system/multi-user.target.wants/$unit"; \
        fi; \
    done; \
    # A container SDDM cannot create a VT-backed PAM session, so the user manager
    # must already exist. Lingering is what starts user@UID at boot; the drop-in
    # in section 7 then requires it before starting graphics.
    mkdir -p /var/lib/systemd/linger; \
    touch /var/lib/systemd/linger/"${USERNAME}"
# display-manager.service is created on demand in section 7l instead, because it
# is exactly what decides whether SDDM runs at boot: graphical.target pulls the
# display manager in through its implicit Wants=display-manager.service, and this
# symlink is the only thing that resolves that name.

# --- 4. Droidspaces compatibility layer -----------------------------------
# Mirrors build_files/ of the other templates: Android-derived group ids, the
# gpu helper group, RT limits for PipeWire, journald that never reads the host
# kernel log, and NAT-mode gating for network daemons.
RUN <<'EOF_RUN'
set -eux

grep -q '^aid_inet:' /etc/group     || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group  || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

getent group droidspaces-gpu >/dev/null || groupadd -g 786 -r droidspaces-gpu
getent group pipewire >/dev/null || groupadd -r pipewire
getent group gamemode >/dev/null || groupadd -r gamemode || true
# Droidspaces exposes host input nodes with fixed GID 1004. Give that ID a
# stable name so the selected user can open the physical input device.
input_device_group="$(getent group 1004 | cut -d: -f1)"
if [ -z "$input_device_group" ]; then
    groupadd -g 1004 -r armada-input
    input_device_group=armada-input
fi

usermod -a -G aid_inet,aid_net_raw,input,video,tty,droidspaces-gpu,"$input_device_group" root || true
for u in armada "${USERNAME}"; do
    [ -n "$u" ] || continue
    id "$u" >/dev/null 2>&1 || continue
    usermod -a -G aid_inet,aid_net_raw,input,video,render,tty,wheel,pipewire,droidspaces-gpu,gamemode,seat,"$input_device_group" "$u" || true
done

mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
printf '[Manager]\nDefaultLimitRTPRIO=70\nDefaultLimitNICE=-19\nDefaultLimitRTTIME=infinity\n' \
    > /etc/systemd/system.conf.d/50-pipewire-rt.conf
cp /etc/systemd/system.conf.d/50-pipewire-rt.conf /etc/systemd/user.conf.d/50-pipewire-rt.conf

if [ -f /etc/default/useradd ]; then
    sed -i '/^GROUPS=/d' /etc/default/useradd
    echo 'GROUPS="aid_inet,aid_net_raw,input,video,tty"' >> /etc/default/useradd
fi

# journald: the container has no /dev/kmsg or audit socket.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf << 'EOT'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

# udev runs against a read-only device bind with no udev event stream.
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# Sort after Droidspaces' 99-readonly-fix.conf. Service ExecCondition cannot
# prevent either socket from failing first when /sys is read-only.
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket systemd-udevd-varlink.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf '[Unit]\nConditionPathIsReadWrite=/sys\n' \
        > "/etc/systemd/system/${unit}.d/zz-armada-container-conditions.conf"
done

mkdir -p /etc/systemd/system/rtkit-daemon.service.d
cat > /etc/systemd/system/rtkit-daemon.service.d/90-container-capabilities.conf <<'EOF_RTKIT'
[Unit]
ConditionCapability=CAP_SYS_NICE
ConditionCapability=CAP_DAC_READ_SEARCH
ConditionCapability=CAP_SYS_PTRACE
ConditionCapability=CAP_SYS_CHROOT
ConditionCapability=CAP_SETGID
ConditionCapability=CAP_SETUID
EOF_RTKIT
for scope in system user; do
    mkdir -p "/etc/systemd/${scope}/steamos-manager.service.d"
    cat > "/etc/systemd/${scope}/steamos-manager.service.d/90-container-tracefs.conf" <<'EOF_TRACEFS'
[Unit]
ConditionPathIsMountPoint=/sys/kernel/tracing
ConditionPathExists=/sys/kernel/tracing/events/oom/mark_victim/enable
EOF_TRACEFS
done

# Network daemons only make sense with a Droidspaces-provided network.
GUEST_SYSTEMD_PATH=/usr/lib/systemd/system
for unit in NetworkManager.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config"
EOF
    fi
done

for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-hwaccess-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q 'enable_hw_access=1' /run/droidspaces/container.config"
EOF
    fi
done

sed -i 's/^hosts:.*/hosts: files dns myhostname/' /etc/nsswitch.conf 2>/dev/null || true

cat > /etc/systemd/system/ds-dhcp.service << 'EOF_DHCP'
[Unit]
Description=Droidspaces NAT DHCP (Root Bypass)
After=network.target
ConditionPathExists=/sys/class/net/eth0
ConditionCapability=CAP_NET_ADMIN
ConditionCapability=CAP_NET_RAW

[Service]
Type=forking
ExecCondition=/bin/sh -c "grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config"
ExecCondition=/bin/sh -c '! /usr/sbin/ip -4 -o address show dev eth0 scope global | grep -q .'
ExecStart=/usr/sbin/dhclient -4 -pf /run/ds-dhclient.pid eth0
PIDFile=/run/ds-dhclient.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF_DHCP
ln -sf /etc/systemd/system/ds-dhcp.service /etc/systemd/system/multi-user.target.wants/ds-dhcp.service

if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    grep -q "maxsize 50M" /etc/logrotate.conf || echo "maxsize 50M" >> /etc/logrotate.conf
fi

# Keep iptables-legacy: the Android kernel has no nftables backend.
for pair in "iptables:/usr/sbin/iptables-legacy" \
            "ip6tables:/usr/sbin/ip6tables-legacy" \
            "iptables-save:/usr/sbin/iptables-legacy-save" \
            "iptables-restore:/usr/sbin/iptables-legacy-restore" \
            "ip6tables-save:/usr/sbin/ip6tables-legacy-save" \
            "ip6tables-restore:/usr/sbin/ip6tables-legacy-restore"; do
    name="${pair%%:*}"; target="${pair#*:}"
    if [ -e "$target" ]; then ln -sf "$target" "/usr/sbin/$name"; fi
done

echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# --- 5. Networking ---------------------------------------------------------
# The bootc base does not include the DHCP client used by ds-dhcp.service.
RUN dnf install -y --setopt=install_weak_deps=False dhcp-client iproute && \
    dnf clean all
RUN mkdir -p /etc/systemd/network && \
    cat <<'EOF' > /etc/systemd/network/10-eth-dhcp.network
[Match]
Name=eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseDomains=yes
RouteMetric=100
EOF

# --- 6. User, locale, environment -----------------------------------------
RUN set -eux; \
    if [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; \
        echo "Asia/Shanghai" > /etc/timezone; \
        echo "LANG=zh_CN.UTF-8" > /etc/locale.conf; \
        echo "LC_ALL=zh_CN.UTF-8" >> /etc/locale.conf; \
    else \
        echo "LANG=en_US.UTF-8" > /etc/locale.conf; \
        echo "LC_ALL=en_US.UTF-8" >> /etc/locale.conf; \
    fi; \
    mkdir -p /var/run/sshd; \
    # armada ships no sshd; the requested user is the general-purpose account.
    (userdel -r debian 2>/dev/null || true); \
    if ! id "${USERNAME}" >/dev/null 2>&1; then \
        useradd -m -s /bin/bash -G wheel "${USERNAME}"; \
    fi; \
    # Section 4 runs before useradd, so grant the new account device/network access here.
    groups=; \
    for group in aid_inet aid_net_raw input video render tty wheel pipewire droidspaces-gpu gamemode seat; do \
        if getent group "$group" >/dev/null; then groups="${groups:+$groups,}$group"; fi; \
    done; \
    input_device_group="$(getent group 1004 | cut -d: -f1)"; \
    if [ -n "$input_device_group" ]; then groups="${groups:+$groups,}$input_device_group"; fi; \
    usermod -a -G "$groups" "${USERNAME}"; \

    echo "${USERNAME}:1234" | chpasswd; \
    # Share armada's Steam library and desktop data with the requested account
    # so an existing Steam install is not re-downloaded per user.
    if [ "${USERNAME}" != "${ARMADA_USER}" ] && [ -d "/home/${ARMADA_USER}" ]; then \
        for d in .local/share/Steam .steam .config .var; do \
            src="/home/${ARMADA_USER}/${d}"; \
            dst="/home/${USERNAME}/${d}"; \
            [ -e "$src" ] || continue; \
            mkdir -p "$(dirname "$dst")"; \
            [ -e "$dst" ] || ln -sfn "$src" "$dst"; \
        done; \
    fi

# The selected graphical account owns the shared, mutable Steam client.
# chown -R on /home/USERNAME does not follow the links created above.
RUN <<'EOF_STEAM_OWNER'
set -eu
if [ "${USERNAME}" != "${ARMADA_USER}" ]; then
    for dir in .local/share/Steam .steam; do
        path="/home/${ARMADA_USER}/${dir}"
        [ ! -d "$path" ] || chown -hR "${USERNAME}:${USERNAME}" "$path"
    done
fi
EOF_STEAM_OWNER

RUN /usr/local/sbin/install-droidspaces-usb-manager --user "${USERNAME}"

# Environment: Anland/Steam entries mirror the Fedora templates. Armada itself
# sets its GPU variables through its own containers/ config, so only append.
RUN : > /etc/environment

RUN if [ "$ENABLE_mesa_ARG" = "true" ] && [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
        echo "MESA_LOADER_DRIVER_OVERRIDE=kgsl" >> /etc/environment; \
        echo "GALLIUM_DRIVER=kgsl" >> /etc/environment; \
        echo "FD_FORCE_KGSL=1" >> /etc/environment; \
    fi && \
    if [ "$ENABLE_8gen2_wayland_ARG" = "true" ]; then \
        echo "FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1" >> /etc/environment; \
    fi && \
    if [ "$PulseAudio" = "socket" ]; then \
        echo "PULSE_SERVER=unix:/tmp/.pulse-socket" >> /etc/environment; \
    elif [ "$PulseAudio" = "tcp" ]; then \
        echo "PULSE_SERVER=tcp:127.0.0.1:4713" >> /etc/environment; \
    fi

RUN <<'EOF_RUN'
set -eux
if [ "$ENABLE_srf_ARG" = "true" ]; then
    mkdir -p "/home/${USERNAME}/.config/autostart"
    cat > "/home/${USERNAME}/.config/autostart/fcitx5.desktop" <<'EOF'
[Desktop Entry]
Name=Fcitx5
GenericName=Input Method
Comment=Start Input Method
Exec=fcitx5 -d
Icon=fcitx
Terminal=false
Type=Application
Categories=System;Utility;
StartupNotify=false
NoDisplay=true
EOF
    cat >> /etc/environment <<'EOF'
XMODIFIERS=@im=fcitx5
GTK_IM_MODULE=fcitx5
QT_IM_MODULE=fcitx5
SDL_IM_MODULE=fcitx5
GLFW_IM_MODULE=fcitx
EOF
fi

if [ "$ENABLE_mesa_ARG" = "true" ] && [ "$DISPLAY_BACKEND" != "anland-wayland" ]; then
    cat <<'EOF' >> /etc/environment
MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform
EOF
fi

echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> "/home/${USERNAME}/.bashrc"
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}" 2>/dev/null || true
EOF_RUN

# --- 7. Container session and power services ------------------------------
# Armada is a handheld OS: SDDM autologins straight into Steam Big Picture and
# Steam asks SteamOS Manager to move between game mode and the desktop. In a
# Droidspaces container the pieces that assume real hardware must be replaced,
# but the actual session start (SDDM -> gamescope-session-plus) is kept intact,
# because that is the supported path and it works without a VT.
#
# Every script here is scoped to the container's own PID namespace: the worst
# outcome is this container stopping. Nothing signals, powers off or
# reconfigures the Android host.
#
# The container user is substituted for __DS_USER__ at the end of the section so
# --build-arg USERNAME is honoured. A literal placeholder is used because the
# files below also contain shell and Python heredocs that must stay verbatim.

# 7a. Session/power worker.
# Runs as root from a template instance: switching sessions has to stop SDDM and
# the outgoing graphical session, which a user unit cannot do.
COPY <<'EOF_ACTION' /usr/libexec/armada/container-action
#!/usr/bin/python3
"""ArmadaOS-only session/power worker. Never touches the Android host."""
import fcntl
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import time

USER = '__DS_USER__'
USER_HOME = Path('/home/__DS_USER__')
STATE = USER_HOME / '.config/armada/container-session.json'
SESSIONS = {
    'desktop': 'armada-plasma.desktop',
    'mobile': 'armada-plasma-mobile.desktop',
    'gamemode': 'gamescope-session-steam.desktop',
}
CONF = Path('/etc/sddm.conf.d/zz-holo-autologin.conf')
RUNTIME = Path('/run/armada-container-session')


def run(args, timeout=20, check=True):
    print('RUN', ' '.join(args), flush=True)
    proc = subprocess.run(args, timeout=timeout, check=False)
    if check and proc.returncode:
        raise RuntimeError('command failed: ' + str(proc.returncode))
    return proc.returncode


def guard():
    if os.geteuid() != 0:
        raise RuntimeError('root service required')
    if Path('/run/systemd/container').read_text().strip() != 'droidspaces':
        raise RuntimeError('not a Droidspaces container')
    if Path('/proc/1/comm').read_text().strip() != 'systemd':
        raise RuntimeError('container PID 1 is not systemd')


def preferences():
    try:
        value = json.loads(STATE.read_text())
        desktop = value.get('desktop_session', 'armada-plasma.desktop')
        login_mode = value.get('default_login_mode', 'game')
        return {
            'desktop_session': desktop if isinstance(desktop, str) else 'armada-plasma.desktop',
            'default_login_mode': login_mode if login_mode in ('game', 'desktop') else 'game',
        }
    except (OSError, ValueError, AttributeError):
        return {'desktop_session': 'armada-plasma.desktop', 'default_login_mode': 'game'}


def atomic(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.new')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, 'w') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def user_systemctl(*args, timeout=20, check=False):
    uid = pwd.getpwnam(USER).pw_uid
    return run([
        '/usr/sbin/runuser', '-u', USER, '--', '/usr/bin/env',
        f'XDG_RUNTIME_DIR=/run/user/{uid}',
        f'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus',
        '/usr/bin/systemctl', '--user', *args,
    ], timeout, check)


def stop_leftover_steam():
    """Only Steam client executables from this user's known installation."""
    uid = pwd.getpwnam(USER).pw_uid
    targets = []
    expected = str(USER_HOME / '.local/share/Steam/steamrtarm64/steam')
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            if proc.stat().st_uid == uid and \
                    os.readlink(proc / 'exe').removesuffix(' (deleted)') == expected:
                targets.append(int(proc.name))
        except OSError:
            pass
    for pid in targets:
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while targets and time.monotonic() < deadline:
        targets = [pid for pid in targets if Path(f'/proc/{pid}/exe').exists()]
        if targets:
            time.sleep(.1)
    for pid in targets:
        # Recheck the executable so a reused PID is never signalled.
        try:
            if os.readlink(f'/proc/{pid}/exe').removesuffix(' (deleted)') == expected:
                os.kill(pid, 9)
        except OSError:
            pass


def main():
    guard()
    action = sys.argv[1] if len(sys.argv) > 1 else ''
    if action == 'check':
        print(json.dumps({
            'container': 'droidspaces',
            'pid1': 'systemd',
            'preferences': preferences(),
            'power_scope': 'container PID namespace only',
        }))
        return 0
    if action in ('poweroff', 'reboot'):
        # systemctl reaches only this container's PID 1; Android keeps running.
        print('Requesting orderly container ' + action + '; no Android command is used',
              flush=True)
        return run(['/usr/bin/systemctl', '--no-block', action], check=False)
    if action not in ('desktop', 'gamemode', 'default-desktop',
                      'default-gamemode', 'default'):
        raise RuntimeError('unsupported action')
    RUNTIME.mkdir(mode=0o755, parents=True, exist_ok=True)
    with (RUNTIME / 'switch.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        pref = preferences()
        default_only = action.startswith('default')
        mode = action.removeprefix('default-')
        if action == 'default':
            mode = 'gamemode' if pref['default_login_mode'] == 'game' else 'desktop'
        session = SESSIONS['gamemode'] if mode == 'gamemode' else pref['desktop_session']
        if session not in (SESSIONS['gamemode'], SESSIONS['desktop'], SESSIONS['mobile']):
            session = SESSIONS['desktop']
        if not (Path('/usr/share/wayland-sessions') / session).is_file():
            raise RuntimeError('target session is not installed')
        before = CONF.read_text() if CONF.exists() else None
        atomic(CONF, '[Autologin]\nUser=__DS_USER__\nRelogin=true\nSession=' + session + '\n')
        print('Selected', session, flush=True)
        if default_only:
            # The boot selector publishes the active mode before SDDM starts.
            # Changing a preference alone must not relabel a live session.
            if action == 'default':
                atomic(RUNTIME / 'mode', mode + '\n')
            return 0
        # This system service sits outside the graphical cgroup, so it survives
        # the logout below. The user manager, SSH, PipeWire and the Android
        # consumer are never stopped.
        try:
            run(['/usr/bin/systemctl', 'stop', 'sddm.service'], timeout=25)
            user_systemctl('stop', 'armada-steam-desktop.service', timeout=15)
            user_systemctl(
                'stop',
                'plasma-workspace-wayland.target',
                'graphical-session.target',
                'gamescope-session-plus@steam.service',
                'plasma-kwin_wayland.service',
                'plasma-plasmashell.service',
                timeout=25, check=True)
            stop_leftover_steam()
            user_systemctl(
                'unset-environment',
                'DISPLAY', 'XAUTHORITY', 'WAYLAND_DISPLAY', 'GAMESCOPE_WAYLAND_DISPLAY',
                'XDG_DESKTOP_PORTAL_DIR', 'QT_QPA_PLATFORM', 'QT_IM_MODULE',
                'GTK_IM_MODULE', 'SDL_IM_MODULE', 'DESKTOP_SESSION',
                'XDG_CURRENT_DESKTOP', 'XDG_SESSION_DESKTOP')
            user_systemctl(
                'reset-failed',
                'gamescope-session-plus@steam.service',
                'plasma-kwin_wayland.service',
                'plasma-plasmashell.service',
                'armada-steam-desktop.service')
            atomic(RUNTIME / 'mode', mode + '\n')
            run(['/usr/bin/systemctl', 'reset-failed', 'sddm.service'], check=False)
            run(['/usr/bin/systemctl', 'start', 'sddm.service'], timeout=20)
        except Exception:
            if before is None:
                CONF.unlink(missing_ok=True)
            else:
                atomic(CONF, before)
            run(['/usr/bin/systemctl', 'reset-failed', 'sddm.service'], check=False)
            run(['/usr/bin/systemctl', 'start', 'sddm.service'], timeout=20, check=False)
            raise
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('armada-container-action:', error, file=sys.stderr, flush=True)
        sys.exit(1)
EOF_ACTION

# 7b. Unprivileged entrypoint.
# The desktop user may only ask for a fixed set of root-owned templates.
COPY <<'EOF_REQUEST' /usr/libexec/armada/container-request
#!/usr/bin/bash
# Only fixed, root-owned service names; never pass through arbitrary systemctl args.
set -u
if [[ $(< /run/systemd/container) != droidspaces || ${USER:-} != __DS_USER__ ]]; then
    printf '%s\n' 'This entrypoint is for the ArmadaOS container user only.' >&2
    exit 1
fi
case ${1:-} in
    desktop|gamemode) unit="armada-container-session@${1}.service" ;;
    poweroff|reboot)  unit="armada-container-${1}.service" ;;
    --check) exec /usr/bin/sudo -n /usr/libexec/armada/container-action check ;;
    *) printf 'usage: %s {desktop|gamemode|poweroff|reboot|--check}\n' "$0" >&2; exit 2 ;;
esac
exec /usr/bin/sudo -n /usr/bin/systemctl --no-block start "$unit"
EOF_REQUEST

# 7c. SteamOS Manager session interface.
# Steam's "Switch to Desktop" and the boot-mode selector both call
# com.steampowered.SteamOSManager1. Upstream steamos-manager exits here because
# it requires tracefs and real hardware, so answer only the session-management
# part of the contract and forward requests through container-request.
COPY <<'EOF_MANAGER' /usr/libexec/armada/container-session-manager
#!/usr/bin/python3
"""Session-only SteamOS Manager compatibility for a read-only /sys container.

Implements upstream's SessionManagement1 contract without initializing hardware,
tracefs, input remapping, or a competing graphical compositor.
"""
import json
import os
from pathlib import Path
import pwd
import signal
import socket
import subprocess
import sys
from gi.repository import Gio, GLib

NAME='com.steampowered.SteamOSManager1'
OBJECT='/com/steampowered/SteamOSManager1'
INTERFACE=NAME+'.SessionManagement1'
STATE=Path('/home/__DS_USER__/.config/armada/container-session.json')
OBJECT_MANAGER_XML='''<node><interface name="org.freedesktop.DBus.ObjectManager"><method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/></method><signal name="InterfacesAdded"><arg type="o"/><arg type="a{sa{sv}}"/></signal><signal name="InterfacesRemoved"><arg type="o"/><arg type="as"/></signal></interface></node>'''
SESSIONS=['armada-plasma.desktop','armada-plasma-mobile.desktop']
XML='''<node>
 <interface name="com.steampowered.SteamOSManager1.SessionManagement1">
  <method name="SwitchToLoginMode"><arg name="login_mode" type="s" direction="in"/></method>
  <method name="SwitchToGameMode"/>
  <method name="SwitchToDesktopMode"/>
  <method name="SwitchToDesktopSession"><arg name="session" type="s" direction="in"/></method>
  <method name="ValidDesktopSessions"><arg type="as" direction="out"/></method>
  <method name="CleanTemporarySessions"/>
  <property name="DefaultLoginMode" type="s" access="readwrite"/>
  <property name="DefaultDesktopSession" type="s" access="readwrite"/>
 </interface>
 <interface name="com.steampowered.SteamOSManager1.Manager2">
  <method name="ReloadConfig"/>
  <property name="DeviceModel" type="(ss)" access="read"/>
 </interface>
 <interface name="com.steampowered.SteamOSManager1.ContainerSession1">
  <method name="Check"><arg type="s" direction="out"/></method>
 </interface>
</node>'''

def load_state():
    data={'desktop_session':'armada-plasma.desktop','default_login_mode':'game'}
    try:
        saved=json.loads(STATE.read_text())
        if saved.get('desktop_session') in SESSIONS: data['desktop_session']=saved['desktop_session']
        if saved.get('default_login_mode') in ('game','desktop'): data['default_login_mode']=saved['default_login_mode']
    except (OSError,ValueError,AttributeError): pass
    return data

def save_state(data):
    STATE.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    temp=STATE.with_suffix('.new')
    fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as out: json.dump(data,out);out.write('\n')
    os.replace(temp,STATE)

def queue_action(mode):
    p=subprocess.run(['/usr/libexec/armada/container-request',mode],capture_output=True,text=True,timeout=5)
    if p.returncode: raise RuntimeError(p.stderr.strip() or 'Unable to queue session service')
    print('queued',mode,flush=True)

def method_call(conn,sender,path,interface,method,parameters,invocation):
    try:
        if interface=='org.freedesktop.DBus.ObjectManager' and method=='GetManagedObjects':
            data=load_state()
            objects={OBJECT:{INTERFACE:{'DefaultLoginMode':GLib.Variant('s',data['default_login_mode']),'DefaultDesktopSession':GLib.Variant('s',data['desktop_session'])},NAME+'.Manager2':{'DeviceModel':GLib.Variant('(ss)',('ArmadaOS Container',''))},NAME+'.ContainerSession1':{}}}
            invocation.return_value(GLib.Variant('(a{oa{sa{sv}}})',(objects,)));return
        if interface==NAME+'.ContainerSession1' and method=='Check':
            invocation.return_value(GLib.Variant('(s)',(json.dumps({'session_only':True,'state':load_state(),'container':'droidspaces'}),)));return
        if interface==NAME+'.Manager2' and method=='ReloadConfig': invocation.return_value(None);return
        if interface!=INTERFACE: raise ValueError('Unsupported interface')
        if method=='ValidDesktopSessions':
            valid=[s for s in SESSIONS if (Path('/usr/share/wayland-sessions')/s).exists()]
            invocation.return_value(GLib.Variant('(as)',(valid,)));return
        if method=='CleanTemporarySessions': invocation.return_value(None);return
        if method=='SwitchToDesktopSession':
            requested=parameters.unpack()[0]
            if requested not in SESSIONS: raise ValueError('Unsupported desktop session')
            data=load_state();data['desktop_session']=requested;save_state(data);mode='desktop'
        elif method=='SwitchToLoginMode':
            requested=parameters.unpack()[0]
            if requested not in ('game','desktop'): raise ValueError('Invalid login mode')
            mode='gamemode' if requested=='game' else 'desktop'
        elif method=='SwitchToGameMode': mode='gamemode'
        elif method=='SwitchToDesktopMode': mode='desktop'
        else: raise ValueError('Unsupported method')
        queue_action(mode)
        invocation.return_value(None)
    except Exception as error:
        print('request failed:',error,file=sys.stderr,flush=True)
        invocation.return_dbus_error('org.freedesktop.DBus.Error.Failed',str(error))

def get_property(conn,sender,path,interface,name):
    data=load_state()
    if interface==INTERFACE and name=='DefaultLoginMode': return GLib.Variant('s',data['default_login_mode'])
    if interface==INTERFACE and name=='DefaultDesktopSession': return GLib.Variant('s',data['desktop_session'])
    if interface==NAME+'.Manager2' and name=='DeviceModel': return GLib.Variant('(ss)',('ArmadaOS Container',''))
    return None

def set_property(conn,sender,path,interface,name,value):
    if interface!=INTERFACE: return False
    data=load_state();text=value.unpack()
    if name=='DefaultDesktopSession' and text in SESSIONS: data['desktop_session']=text
    elif name=='DefaultLoginMode' and text in ('game','desktop'): data['default_login_mode']=text
    else: return False
    save_state(data)
    conn.emit_signal(None,OBJECT,'org.freedesktop.DBus.Properties','PropertiesChanged',GLib.Variant('(sa{sv}as)',(INTERFACE,{name:GLib.Variant('s',text)},[])))
    return True

def main():
    # The unit runs as the desktop user; refuse anything else.
    expected=pwd.getpwnam('__DS_USER__').pw_uid
    if os.getuid()!=expected or Path('/run/systemd/container').read_text().strip()!='droidspaces': raise RuntimeError('Wrong container user')
    connection=Gio.bus_get_sync(Gio.BusType.SESSION,None)
    reply=connection.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName',GLib.Variant('(su)',(NAME,4)),GLib.VariantType.new('(u)'),Gio.DBusCallFlags.NONE,4000,None)
    if reply.unpack()[0]!=1: raise RuntimeError('SteamOS Manager bus name is already owned')
    node=Gio.DBusNodeInfo.new_for_xml(XML)
    registrations=[connection.register_object(OBJECT,i,method_call,get_property,set_property) for i in node.interfaces]
    object_manager=Gio.DBusNodeInfo.new_for_xml(OBJECT_MANAGER_XML)
    registrations.append(connection.register_object('/',object_manager.interfaces[0],method_call,None,None))
    loop=GLib.MainLoop()
    for sig in (signal.SIGINT,signal.SIGTERM): GLib.unix_signal_add(GLib.PRIORITY_DEFAULT,sig,lambda: (loop.quit(),False)[1])
    print('SessionManagement1 ready; hardware interfaces intentionally absent',flush=True)
    notify=os.environ.get('NOTIFY_SOCKET')
    if notify:
        address='\0'+notify[1:] if notify.startswith('@') else notify
        with socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM) as status:
            status.connect(address);status.sendall(b'READY=1\nSTATUS=Container session interface ready')
    loop.run()
    for registration in registrations: connection.unregister_object(registration)

if __name__=='__main__': main()
EOF_MANAGER
# 7d. Armada Store switches sessions by calling the base image's
# /usr/libexec/armada/session-control, which writes the hardware SDDM config,
# restarts sddm alone, and reads the missing /var/home/armada steamos-manager
# state. Replace it with the container-scoped request path.
COPY scripts/armada/armada-container-session-control /usr/libexec/armada/session-control
# Session switching and power confirmations for the desktop user.
COPY <<'EOF_SWITCH' /usr/libexec/armada/switch-gamemode-confirm
#!/usr/bin/bash
set -u
# Game Mode exports Qt/GTK Steam IM modules; they must not enter this dialog.
unset QT_IM_MODULE GTK_IM_MODULE SDL_IM_MODULE
message=$'这会结束 Plasma 服务和 KWin，关闭当前 KDE 桌面会话，并进入 Steam 大屏幕模式。\n\n未保存的工作可能丢失，请先保存。\n是否运行？'
if command -v kdialog >/dev/null 2>&1; then
    kdialog --title '切换到大屏幕模式' --icon steam --warningyesno "$message" \
        --yes-label '运行' --no-label '取消' || exit 0
else
    zenity --question --title='切换到大屏幕模式' --text="$message" \
        --ok-label='运行' --cancel-label='取消' --width=480 || exit 0
fi
if ! /usr/libexec/armada/container-request gamemode; then
    zenity --error --title='切换失败' \
        --text='无法启动大屏幕会话服务；当前桌面未被主动关闭。请查看 armada-container-session@gamemode.service 的日志。' \
        --width=480
    exit 1
fi
EOF_SWITCH

COPY <<'EOF_POWER' /usr/libexec/armada/container-power-confirm
#!/usr/bin/bash
set -u
unset QT_IM_MODULE GTK_IM_MODULE SDL_IM_MODULE
zenity --question --title='关闭 ArmadaOS 容器' \
    --text=$'这会关闭 ArmadaOS 容器及其中的所有应用，并断开 SSH。\n\n不会关闭或重启 Android 手机。\n是否继续？' \
    --ok-label='关闭容器' --cancel-label='取消' --width=460 || exit 0
exec /usr/libexec/armada/container-request poweroff
EOF_POWER

# Desktop entries. armada ships "Return to Game Mode" pointed at
# steamos-session-select, which drives steamos-manager; route both actions
# through the container scripts instead so they talk to this container only.
COPY <<'EOF_DESKTOP' /usr/share/applications/armada-return-to-gamemode.desktop
[Desktop Entry]
Type=Application
Name=切换到大屏幕模式
Comment=结束 Plasma 和 KWin，进入 Steam 大屏幕模式
Icon=steam
Exec=/usr/libexec/armada/switch-gamemode-confirm
Terminal=false
Categories=System;Game;
StartupNotify=false
EOF_DESKTOP

COPY <<'EOF_DESKTOP2' /usr/share/applications/armada-container-poweroff.desktop
[Desktop Entry]
Type=Application
Name=关闭容器
Comment=正常关闭 ArmadaOS 容器，不关闭 Android
Icon=system-shutdown
Exec=/usr/libexec/armada/container-power-confirm
Terminal=false
Categories=System;
StartupNotify=false
EOF_DESKTOP2

# Both launchers also have to exist on the build user's desktop: the Plasma
# desktop applet renders the contents of ~/Desktop, so a panel entry alone
# leaves no visible way to switch modes or shut the container down. The
# standalone game-mode launcher (armada-anland-game-mode) is deliberately not
# copied: it starts a nested gamescope over an existing session and does nothing
# useful here, while 切换到大屏幕模式 goes through container-request and does the
# full session handover.
RUN set -eux; \
    install -d -m 0755 -o "${USERNAME}" -g "${USERNAME}" "/home/${USERNAME}/Desktop"; \
    rm -f "/home/${USERNAME}/Desktop/armada-anland-game-mode.desktop"; \
    for entry in armada-return-to-gamemode armada-container-poweroff; do \
        install -m 0755 -o "${USERNAME}" -g "${USERNAME}" \
            "/usr/share/applications/${entry}.desktop" \
            "/home/${USERNAME}/Desktop/${entry}.desktop"; \
    done

# Power buttons in KDE and Steam both go through logind on the system bus, whose
# default policy is auth_admin_keep. A container has no polkit authentication
# agent in the desktop session, so those requests were refused or hung waiting
# for a password. logind here can only reach this container's PID 1 (the Android
# host is a separate kernel namespace), so granting wheel the power actions is
# equivalent to letting the user end their own session.
COPY scripts/etc/polkit/49-armada-container-power.rules /etc/polkit-1/rules.d/49-armada-container-power.rules
RUN chmod 0644 /etc/polkit-1/rules.d/49-armada-container-power.rules

# armada's own game-mode entry starts a nested gamescope over the live session
# and does nothing in the container. It belongs to terra-gamescope-anland-session,
# so deleting it would be undone by the next package update; hide it the
# freedesktop way instead, with an identically named entry carrying Hidden=true
# in a higher-priority data directory (/usr/local/share precedes /usr/share).
COPY scripts/etc/applications/armada-anland-game-mode.desktop /usr/local/share/applications/armada-anland-game-mode.desktop
RUN chmod 0644 /usr/local/share/applications/armada-anland-game-mode.desktop

# Protontricks needs a Proton compatibility tool recorded for the game. When
# Steam has stored the arm64 Steam Linux Runtime instead, Protontricks reports
# "Active compatibility tool was found, but it's not a Proton installation" and
# refuses to run. That is Steam-side state, so it is fixed in Steam by selecting
# Proton for the affected game; this image deliberately ships no PROTON_VERSION
# wrapper, which would freeze one particular Proton build for every caller.

# 7e. Steam kept alive on the Plasma desktop.
# Steam's OSK/overlay expects a client on the desktop session too. This helper
# only acts when the published mode says the desktop session is active, so it is
# inert in Game Mode.
COPY <<'EOF_STEAMBGD' /usr/libexec/armada/start-steam-background
#!/usr/bin/bash
set -u
[[ $(cat /run/armada-container-session/mode 2>/dev/null) == desktop ]] || exit 0
[[ ${XDG_CURRENT_DESKTOP:-} == *KDE* && -n ${DISPLAY:-} ]] || exit 0
unset QT_IM_MODULE GTK_IM_MODULE SDL_IM_MODULE GAMESCOPE_WAYLAND_DISPLAY
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000}
export DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG_RUNTIME_DIR}/bus
# Import only the real, newly started desktop's display, never a retired Xwayland.
vars=()
for name in DISPLAY XAUTHORITY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE; do
    [[ -v $name ]] && vars+=("$name")
done
systemctl --user import-environment "${vars[@]}" || exit 1
exec systemctl --user --no-block start armada-steam-desktop.service
EOF_STEAMBGD

COPY <<'EOF_STEAMBGD_DESKTOP' /etc/xdg/autostart/armada-steam-background.desktop
[Desktop Entry]
Type=Application
Name=Steam background session
Exec=/usr/libexec/armada/start-steam-background
OnlyShowIn=KDE;
NoDisplay=true
X-KDE-autostart-phase=2
EOF_STEAMBGD_DESKTOP

COPY <<'EOF_STEAMDESKTOP' /etc/systemd/user/armada-steam-desktop.service
[Unit]
Description=Steam background client for ArmadaOS desktop
PartOf=graphical-session.target
After=plasma-plasmashell.service

[Service]
ExecStart=/usr/libexec/armada/launch-steam --desktop -silent
KillMode=control-group
TimeoutStopSec=10
TimeoutStopFailureMode=kill
Environment=ANLAND=1 SDL_JOYSTICK_DISABLE_UDEV=1 SDL_HIDAPI_UDEV=0 SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1
EOF_STEAMDESKTOP

# 7f. System units. The container guard keeps them inert on real Armada
# hardware. ConditionVirtualization=container is not usable here: systemd
# classifies a Droidspaces container as "container-other" (it has no
# /run/systemd/container value it recognises as a known container manager), so
# `systemctl show <unit> -p ConditionResult` reports "no" and the units look
# unstartable even though they run. Gate on the marker Droidspaces itself writes
# instead, which is what the scripts already test.
COPY <<'EOF_SESSION_UNIT' /etc/systemd/system/armada-container-session@.service
[Unit]
Description=Switch ArmadaOS container graphics to %i
ConditionPathExists=/run/systemd/container
After=systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/armada/container-action %i
TimeoutStartSec=90
TimeoutStopSec=5
StandardOutput=journal
StandardError=journal
EOF_SESSION_UNIT

COPY <<'EOF_POWEROFF_UNIT' /etc/systemd/system/armada-container-poweroff.service
[Unit]
Description=Orderly ArmadaOS container poweroff
ConditionPathExists=/run/systemd/container

[Service]
Type=oneshot
ExecStart=/usr/libexec/armada/container-action poweroff
TimeoutStartSec=15
EOF_POWEROFF_UNIT

COPY <<'EOF_REBOOT_UNIT' /etc/systemd/system/armada-container-reboot.service
[Unit]
Description=Orderly ArmadaOS container reboot
ConditionPathExists=/run/systemd/container

[Service]
Type=oneshot
ExecStart=/usr/libexec/armada/container-action reboot
TimeoutStartSec=15
EOF_REBOOT_UNIT

# 7g. User-side session interface. It must come up with the user manager so a
# plain SSH login already sees SteamOS Manager, not only a graphical session.
COPY <<'EOF_MANAGER_UNIT' /etc/systemd/user/armada-container-session-manager.service
[Unit]
Description=ArmadaOS container Steam session interface
After=dbus.socket
Requires=dbus.socket

[Service]
Type=notify
NotifyAccess=main
ExecStart=/usr/libexec/armada/container-session-manager
Restart=on-failure
RestartSec=2
TimeoutStartSec=8
TimeoutStopSec=5

[Install]
WantedBy=default.target
EOF_MANAGER_UNIT

COPY <<'EOF_MANAGER_DROPIN' /etc/systemd/user/armada-container-session-manager.service.d/90-armada-user-bus.conf
[Service]
# The user manager supplies this runtime independently of shell or SSH startup.
Environment=XDG_RUNTIME_DIR=%t DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus
EOF_MANAGER_DROPIN

# 7h. Boot-mode publisher.
# armada normally lets steamos-manager pick the boot session, which cannot run
# here. Write the choice before SDDM autologins, and publish the mode for the
# power-button bridge and the session manager.
COPY <<'EOF_BOOT' /usr/libexec/armada/container-boot-mode
#!/usr/bin/python3
"""Publish the container's boot session before SDDM autologins into it."""
import json
import sys
from pathlib import Path

RUNTIME = Path('/run/armada-container-session')
CONF = Path('/etc/sddm.conf.d/zz-holo-autologin.conf')
STATE = Path('/home/__DS_USER__/.config/armada/container-session.json')
SESSIONS = ('armada-plasma.desktop', 'armada-plasma-mobile.desktop')


def main():
    mode = 'game'
    desktop = 'armada-plasma.desktop'
    try:
        saved = json.loads(STATE.read_text())
        if saved.get('default_login_mode') in ('game', 'desktop'):
            mode = saved['default_login_mode']
        if saved.get('desktop_session') in SESSIONS:
            desktop = saved['desktop_session']
    except (OSError, ValueError, AttributeError):
        pass

    if mode == 'desktop':
        session, label = desktop, 'desktop'
    else:
        session, label = 'gamescope-session-steam.desktop', 'gamemode'

    RUNTIME.mkdir(mode=0o755, parents=True, exist_ok=True)
    (RUNTIME / 'mode').write_text(label + '\n')
    CONF.parent.mkdir(parents=True, exist_ok=True)
    CONF.write_text(
        '[Autologin]\nUser=__DS_USER__\nRelogin=true\nSession=' + session + '\n')
    print('armada: boot mode %s (session %s)' % (label, session), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
EOF_BOOT

# 7i. SDDM drop-ins.
# 95: a container has no VT, so remove the tty1 placeholder before SDDM opens a
#     console, and let it wait for the container's display producer.
# 96: SDDM cannot register a VT-backed PAM session here, so use the lingering
#     user manager and set the boot mode before graphics start.
# 98: SDDM must not sit in TimeoutStopSec forever while a session shuts down.
COPY <<'EOF_SDDM95' /etc/systemd/system/sddm.service.d/95-armada-container.conf
[Unit]
JobTimeoutSec=0
JobRunningTimeoutSec=0
[Service]
TimeoutStartSec=infinity
WatchdogSec=0
Environment=ANLAND_SOCKET=/run/display.sock
ExecStartPre=
ExecStartPre=/usr/libexec/armada/prepare-anland-session
EOF_SDDM95

COPY <<'EOF_PREPARE' /usr/libexec/armada/prepare-anland-session
#!/usr/bin/bash
# Android containers have no Linux VTs. A tty1 -> /dev/null placeholder makes
# SDDM issue TIOCSCTTY to /dev/null and exit before any producer can wait.
set -uo pipefail
if [[ ! -e /dev/tty0 && -L /dev/tty1 ]] && [[ $(readlink -f /dev/tty1) == /dev/null ]]; then
    rm -- /dev/tty1 || exit 1
    printf '%s\n' 'armada: removed container tty1 placeholder; SDDM will run without a VT'
fi
[[ ${1:-} != --prepare-only ]] || exit 0
# Anland can be enabled in the app without a pre-mounted daemon socket. Leave
# SDDM's pre-start job waiting until the producer appears, as in the working
# container; killing/restarting gamescope here would consume SDDM's start limit.
socket=${ANLAND_SOCKET:-/run/display.sock}
if [[ ! -S $socket ]]; then
    printf 'armada: waiting for Anland daemon socket %s; no startup deadline\n' "$socket"
    while [[ ! -S $socket ]]; do
        sleep 1
    done
fi
EOF_PREPARE

COPY <<'EOF_SDDM96' /etc/systemd/system/sddm.service.d/96-armada-user-manager.conf
[Unit]
# Container SDDM cannot register a VT-backed PAM session. Use the boot-started
# lingering user manager and select the default mode before launching graphics.
Requires=user@__DS_UID__.service armada-session-default.service
After=user@__DS_UID__.service armada-session-default.service
EOF_SDDM96

# 98: SDDM must not sit in TimeoutStopSec forever while a session shuts down.
# It also must not burn the full timeout every time: SDDM relays SIGTERM to the
# session and then waits for the session to disappear, which never happens
# cleanly here because the container has no VT to log the session out of.
# Measured before this change: `systemctl stop sddm` took 15.1 s (the whole
# TimeoutStopSec) and container-action's stop/start pair added a flat 16 s to
# every mode switch. container-action stops graphical-session.target and the
# plasma/gamescope units itself right after, so SDDM does not need to wait.
# A 3 s grace period keeps a clean exit possible and then systemd kills the
# cgroup, which brought the same stop down to ~3.4 s.
COPY <<'EOF_SDDM98' /etc/systemd/system/sddm.service.d/98-armada-container-ux.conf
[Service]
TimeoutStopSec=3
KillMode=control-group
SendSIGKILL=yes
TimeoutStopFailureMode=kill
EOF_SDDM98

# 97: the Plasma session is a top-level Anland producer.
# armada-plasma-session ends standalone desktops with a bare
# `exec startplasma-wayland`, which is the Gamescope-handover form of the script.
# On Anland there is no Gamescope: kwin_wayland is the compositor and drives the
# display daemon through its built-in anland backend, so two things are missing
# from that path and KWin exits within milliseconds without either of them:
#   * the producer environment (ANLAND/ANLAND_SOCKET/ANLAND_DRM_DEVICE and the
#     KGSL Mesa selection) that tells KWin which backend and GPU to use;
#   * a session bus. SDDM starts Wayland sessions without one, and
#     startplasma-wayland shuts down immediately when dbus-daemon is absent.
# The environment cannot be supplied from this unit: sddm-helper rebuilds the
# session environment from PAM and its own whitelist, so `systemctl show` on
# sddm.service can list ANLAND=1 while the session process still sees nothing.
# The upstream script is patched instead, in section 7i-patch below.
RUN <<'EOF_KWALLET'
set -eux
# An autologin session has no password, so pam_kwallet5 never gets a wallet key
# and KWallet opens its "first time" setup wizard on every login. There is no
# secret store to unlock inside the container, so disable the wallet globally
# and for the build user rather than prompting for a password nothing supplies.
mkdir -p /etc/xdg
cat > /etc/xdg/kwalletrc <<'EOF'
[Wallet]
Enabled=false
First Time=false
EOF
chmod 0644 /etc/xdg/kwalletrc
mkdir -p "/home/${USERNAME}/.config"
cat > "/home/${USERNAME}/.config/kwalletrc" <<'EOF'
[Wallet]
Enabled=false
First Time=false
EOF
chmod 0600 "/home/${USERNAME}/.config/kwalletrc"
chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config/kwalletrc"
EOF_KWALLET

# Patch armada-plasma-session so a standalone desktop session on Anland gets the
# producer environment and a session bus. The substitution is exact-match and
# fails the build if upstream changes the line, which is preferable to shipping
# a session that silently starts without the Anland backend.
COPY scripts/armada/patch-armada-plasma-session.py /tmp/patch-armada-plasma-session.py
RUN python3 /tmp/patch-armada-plasma-session.py \
        /usr/libexec/armada/armada-plasma-session && \
    bash -n /usr/libexec/armada/armada-plasma-session && \
    rm -f /tmp/patch-armada-plasma-session.py

# Remove Bazaar from both the initial taskbar pin script and KRunner favorites.
COPY scripts/armada/patch-armada-remove-bazaar-pin.py /tmp/patch-armada-remove-bazaar-pin.py
RUN python3 /tmp/patch-armada-remove-bazaar-pin.py \
        /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/armada-pins.js \
        /usr/share/kde-settings/kde-profile/default/xdg/kicker-extra-favoritesrc && \
    ! grep -q 'io.github.kolunmi.Bazaar.desktop' \
        /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/armada-pins.js && \
    ! grep -q 'io.github.kolunmi.Bazaar.desktop' \
        /usr/share/kde-settings/kde-profile/default/xdg/kicker-extra-favoritesrc && \
    rm -f /tmp/patch-armada-remove-bazaar-pin.py

# Pin the helper's backend at build time; the system manager does not inherit
# a login shell's /etc/environment. Non-Anland builds only need VT preparation.
RUN if [ "$DISPLAY_BACKEND" != anland-wayland ]; then \
        sed -i '/^socket=${ANLAND_SOCKET/i exit 0' /usr/libexec/armada/prepare-anland-session; \
    fi

# The autologin file armada ships names its own user. Rewrite it for the build
# user so SDDM does not autologin into an account Droidspaces may not create.
COPY <<'EOF_SDDM_ARMADA' /etc/sddm.conf.d/armada.conf
[Autologin]
Relogin=true
Session=gamescope-session-steam.desktop
User=__DS_USER__
EOF_SDDM_ARMADA

# Anland's Android consumer can connect well after the system boots. Keep the
# vendor session lifecycle, but wait on its startup FIFO while gamescope lives.
COPY scripts/armada/armada-gamescope-startup.sh /usr/libexec/armada/gamescope-startup-wait
COPY scripts/armada/patch-armada-gamescope-startup.py /tmp/patch-armada-gamescope-startup.py
RUN python3 /tmp/patch-armada-gamescope-startup.py /usr/share/gamescope-session-plus/gamescope-session-plus && \
    bash -n /usr/libexec/armada/gamescope-startup-wait && \
    bash -n /usr/share/gamescope-session-plus/gamescope-session-plus && \
    rm -f /tmp/patch-armada-gamescope-startup.py

# SDDM starts the user unit, so set the display backend on that unit rather than
# relying on environment variables that may only exist in an interactive shell.
RUN <<'EOF_RUN'
set -eux
install -d /etc/systemd/user/gamescope-session-plus@steam.service.d
if [ "$DISPLAY_BACKEND" = anland-wayland ]; then
    cat > /etc/systemd/user/gamescope-session-plus@steam.service.d/90-armada-container.conf <<'EOF_GAMESCOPE'
[Service]
Environment=BACKEND=anland ANLAND=1 ANLAND_SOCKET=/run/display.sock ANLAND_DRM_DEVICE=/dev/dri/renderD128
EOF_GAMESCOPE
    cat > /etc/systemd/user/gamescope-session-plus@steam.service.d/95-anland-consumer-wait.conf <<'EOF_GAMESCOPE_WAIT'
[Unit]
JobTimeoutSec=0
JobRunningTimeoutSec=0
[Service]
TimeoutStartSec=infinity
WatchdogSec=0
EOF_GAMESCOPE_WAIT
fi
cat > /etc/systemd/user/gamescope-session-plus@steam.service.d/98-armada-container-ux.conf <<'EOF_GAMESCOPE_UX'
[Unit]
Wants=armada-container-session-manager.service
After=armada-container-session-manager.service
[Service]
Environment=SDL_JOYSTICK_DISABLE_UDEV=1 SDL_HIDAPI_UDEV=0 SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1
TimeoutStopSec=12
TimeoutStopFailureMode=kill
EOF_GAMESCOPE_UX
EOF_RUN
# Use Zink over the shared Turnip driver for the ARM Steam UI on Anland.
# Native KGSL GL fails CEF's GBM/dma-buf sharing; XRandR needs early real symbols.
COPY scripts/armada/armada-steam-anland.sh /usr/libexec/armada/steam-anland-env
RUN if [ "$DISPLAY_BACKEND" = anland-wayland ]; then \
        install -d /etc/gamescope-session-plus/sessions.d; \
        printf '\nsource /usr/libexec/armada/steam-anland-env\n' \
            >> /etc/gamescope-session-plus/sessions.d/steam; \
        bash -n /etc/gamescope-session-plus/sessions.d/steam; \
    fi && \
    bash -n /usr/libexec/armada/steam-anland-env

# Desktop mode needs the Anland-patched KWin, not the distribution one. The base
# armada image ships kwin-6.7.5-1.fc44.armada, which has no Anland backend: it
# falls back to DRM, finds no /dev/dri/card0 inside a container, and dies in a
# restart loop every ~5s. SDDM keeps respawning it, so desktop mode is a black
# screen with no error the user can see. The producer's KWin carries
# KWin::AnlandBackend and renders to the display daemon instead.
# Only DISPLAY_BACKEND=anland-wayland needs this, and installing it costs a
# network round-trip, so it stays behind that switch.
# xorg-x11-server-Xwayland-devel pins Xwayland to the distribution build, which
# conflicts with the patched Xwayland the Anland archive downgrades to. Nothing
# requires the -devel package at runtime (it only ships headers) and no package
# depends on it, so dropping it is what lets the transaction resolve. Xwayland
# itself is kept.
# The trailing checks fail the build here rather than on a user's black screen.
COPY scripts/armada/verify-anland-kwin.py /tmp/verify-anland-kwin.py
RUN if [ "$DISPLAY_BACKEND" = anland-wayland ]; then \
        rpm -q xorg-x11-server-Xwayland-devel >/dev/null 2>&1 && \
            dnf -y remove xorg-x11-server-Xwayland-devel \
                --setopt=clean_requirements_on_remove=False; \
        /usr/local/sbin/install-anland-kde -1 && \
        python3 /tmp/verify-anland-kwin.py --explain; \
    fi; \
    rm -f /tmp/verify-anland-kwin.py

# gamescope quits as soon as Steam exits (cv_shutdown_on_primary_child_death),
# which pulls the Anland producer out from under the Android display consumer
# and leaves a black panel. --keep-alive does NOT help here: the session script
# kills gamescope itself right after the client exits, so the compositor dies
# either way. What actually recovers the panel is restarting the whole session
# unit, which rebuilds the session link. Without this drop-in the unit has
# Restart=no, so one Steam exit leaves the container permanently without a
# graphical session until someone restarts it by hand.
COPY <<'EOF_GAMESCOPE_RESTART' /etc/systemd/user/gamescope-session-plus@steam.service.d/99-armada-container-restart.conf
[Service]
Restart=always
RestartSec=2
EOF_GAMESCOPE_RESTART

# 7j. Boot-mode wiring: publish the default session every boot, before SDDM.
COPY <<'EOF_SESSION_DEFAULT' /etc/systemd/system/armada-session-default.service.d/98-armada-container-ux.conf
[Service]
ExecStart=
ExecStart=/usr/libexec/armada/container-boot-mode
EOF_SESSION_DEFAULT

# Decky's vendor image pins /var/home/armada and can bundle the x86_64
# PluginLoader. Use the requested account and a native ARM64 loader.
COPY scripts/armada/configure-armada-decky.py /tmp/configure-armada-decky.py
RUN python3 /tmp/configure-armada-decky.py "${USERNAME}" && \
    rm -f /tmp/configure-armada-decky.py
# Armada Control ships from the base image and assumes the hardware accounts:
# its read path parses /var/home/armada/.config/steamos-manager/state.toml and
# every session-side helper (steamosctl included) is run through runuser as
# "armada". Neither exists here, so Desktop/Mobile reads always reported
# "desktop" and writes failed with "No such file or directory". Point the read
# path at the container session state and run session helpers as USERNAME.
COPY scripts/armada/patch-armada-container-desktop-mode.py /tmp/patch-armada-container-desktop-mode.py
RUN python3 /tmp/patch-armada-container-desktop-mode.py \
        /usr/libexec/armada/armada-control "${USERNAME}" && \
    rm -f /tmp/patch-armada-container-desktop-mode.py
COPY <<'EOF_CONTROL_SESSION_USER' /etc/systemd/system/armada-control.service.d/98-armada-container-ux.conf
[Service]
Environment=ARMADA_SESSION_USER=__DS_USER__
EOF_CONTROL_SESSION_USER

# Steam runs as USERNAME; both its status writer and the boot-created splash
# directory must use that account, or the loading screen never shows progress.
COPY scripts/armada/configure-armada-splash.py /tmp/configure-armada-splash.py
RUN python3 /tmp/configure-armada-splash.py "${USERNAME}" && \
    bash -n /usr/libexec/armada/armada-splash-progress && \
    rm -f /tmp/configure-armada-splash.py

# 7k. Wire it up: substitute the build user, fix up permissions, enable the
# units, and fail the build if any of the generated files is malformed.
RUN <<'EOF_RUN'
set -eux

uid=$(id -u "${USERNAME}")
for file in \
    /usr/libexec/armada/container-action \
    /usr/libexec/armada/container-request \
    /usr/libexec/armada/container-session-manager \
    /usr/libexec/armada/session-control \
    /usr/libexec/armada/switch-gamemode-confirm \
    /usr/libexec/armada/container-power-confirm \
    /usr/libexec/armada/start-steam-background \
    /usr/libexec/armada/container-boot-mode \
    /etc/systemd/system/sddm.service.d/96-armada-user-manager.conf \
    /etc/systemd/system/armada-control.service.d/98-armada-container-ux.conf \
    /etc/sddm.conf.d/armada.conf; do
    sed -i "s/__DS_USER__/${USERNAME}/g; s/__DS_UID__/${uid}/g" "$file"
    test -n "$(grep -c . "$file")"
done
# The placeholder must never survive into the image.
if grep -rl '__DS_USER__\|__DS_UID__' /usr/libexec/armada /etc/systemd/system /etc/sddm.conf.d; then
    echo 'unsubstituted build user placeholder' >&2
    exit 1
fi

chmod 0755 \
    /usr/libexec/armada/container-action \
    /usr/libexec/armada/container-request \
    /usr/libexec/armada/container-session-manager \
    /usr/libexec/armada/session-control \
    /usr/libexec/armada/switch-gamemode-confirm \
    /usr/libexec/armada/container-power-confirm \
    /usr/libexec/armada/start-steam-background \
    /usr/libexec/armada/container-boot-mode \
    /usr/libexec/armada/prepare-anland-session
chmod 0644 /etc/sddm.conf.d/armada.conf

# Exactly four templates, no wildcard and no shell.
install -d -m 0755 /etc/sudoers.d
cat > /etc/sudoers.d/armada-container-ux <<'SUDO'
Cmnd_Alias ARMADA_CONTAINER_UX = /usr/bin/systemctl --no-block start armada-container-session@desktop.service, /usr/bin/systemctl --no-block start armada-container-session@gamemode.service, /usr/bin/systemctl --no-block start armada-container-poweroff.service, /usr/bin/systemctl --no-block start armada-container-reboot.service, /usr/libexec/armada/container-action check
SUDO
printf '%s ALL=(root) NOPASSWD: ARMADA_CONTAINER_UX\n' "${USERNAME}" >> /etc/sudoers.d/armada-container-ux
chmod 0440 /etc/sudoers.d/armada-container-ux
visudo -cf /etc/sudoers.d/armada-container-ux >/dev/null

# armada's polkit rule only trusts its own user; let the build user run the same
# privileged helper so the Tools panel is not dead in this image.
if [ -f /usr/share/polkit-1/rules.d/50-armada-tools.rules ]; then
    sed -i "s/subject.user == \"armada\")/subject.user == \"${USERNAME}\")/" \
        /usr/share/polkit-1/rules.d/50-armada-tools.rules
fi

# Syntax gates. A broken script here would only surface at session start, which
# is the hardest place to debug, so refuse to build it.
python3 -c 'import ast; ast.parse(open("/usr/libexec/armada/container-action").read())'
python3 -c 'import ast; ast.parse(open("/usr/libexec/armada/container-session-manager").read())'
python3 -c 'import ast; ast.parse(open("/usr/libexec/armada/container-boot-mode").read())'
bash -n /usr/libexec/armada/container-request
bash -n /usr/libexec/armada/session-control
bash -n /usr/libexec/armada/switch-gamemode-confirm
bash -n /usr/libexec/armada/container-power-confirm
bash -n /usr/libexec/armada/start-steam-background
bash -n /usr/libexec/armada/prepare-anland-session
# The bus bindings must import, otherwise the manager dies at session start.
python3 -c 'from gi.repository import Gio, GLib; Gio.DBusNodeInfo.new_for_xml("<node/>")'

install -d -m 0755 /etc/systemd/user/default.target.wants
ln -sf ../armada-container-session-manager.service \
    /etc/systemd/user/default.target.wants/armada-container-session-manager.service
# The user manager is started by the system, so the graphical session can rely
# on it; enable lingering so it survives without a login shell.
install -d -m 0755 /var/lib/systemd/linger
touch /var/lib/systemd/linger/"${USERNAME}"
EOF_RUN

# 7l. Boot autostart. DESKTOP_AUTOSTART decides whether the container lands in
# Steam Big Picture by itself or waits in a console.
#
# Armada only knows one way to reach a session: SDDM autologin. Three facts from
# the running container shape this:
#
#   * graphical.target pulls the display manager in through its implicit
#     Wants=display-manager.service, and display-manager.service is only an
#     alias symlink to sddm.service. Dropping that symlink is therefore what
#     stops SDDM at boot, and keeping it is what starts SDDM;
#   * the container has no VT and no DRM seat ("No graphical seats found" in
#     SDDM's own log), and the base image ships no greeter theme at all
#     (/usr/share/sddm/themes is empty). An SDDM without autologin can
#     therefore not show a login screen; it would only restart in a loop, so
#     "no autostart" has to mean "boot to multi-user.target";
#   * /run is a tmpfs, so the runtime mode file cannot be baked into the image;
#     the boot-mode unit recreates it and the behaviour is identical either way.
#
# Graphics stay reachable on demand in both modes, because
# armada-session-default.service keeps publishing the mode/autologin state that
# an explicit `container-request gamemode` or `container-request desktop` needs.
RUN <<'EOF_RUN'
set -eux
install -d -m 0755 /etc/sddm.conf.d /run/armada-container-session
case "${DESKTOP_AUTOSTART:-true}" in
true)
    # zz- sorts after armada.conf so its Session= and User= win.
    printf '[Autologin]\nUser=%s\nRelogin=true\nSession=gamescope-session-steam.desktop\n' \
        "${USERNAME}" > /etc/sddm.conf.d/zz-holo-autologin.conf
    chmod 0644 /etc/sddm.conf.d/zz-holo-autologin.conf
    ln -sfn /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target
    ln -sfn /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service
    ;;
false)
    # No autologin file: SDDM must never be handed a session it should not
    # start on its own. armada.conf still carries User=/Session=, so an
    # explicit switch request still opens a session later.
    rm -f /etc/sddm.conf.d/zz-holo-autologin.conf
    ln -sfn /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
    rm -f /etc/systemd/system/display-manager.service
    ;;
*)
    printf 'unsupported DESKTOP_AUTOSTART: %s\n' "${DESKTOP_AUTOSTART}" >&2
    exit 1
    ;;
esac
EOF_RUN

# --- 8. Container device and Steam runtime layout ---------------------------
# Two container-only defects. Neither is an armada bug: the first comes from
# having no udev daemon, the second from Valve shipping no armhf runtime.

# 8a. /dev/uinput.
# The Android kernel provides uinput as 10:223, but nothing inside a container
# creates the node: no udev daemon runs, and /dev itself is a tmpfs the initramfs
# would normally populate. Declare it with tmpfiles so it exists at boot with the
# ownership Steam Input expects. Group input is granted to ${USERNAME} in
# section 4, so this needs no further permissions work.
RUN <<'EOF_RUN'
set -eux
printf '%s\n' \
    '# Steam Input virtual gamepad; Android kernel exposes uinput as 10:223.' \
    'c /dev/uinput 0660 root input - 10:223' \
    > /etc/tmpfiles.d/armada-uinput.conf
EOF_RUN

# 8b. Steam runtime layout.
# Steam resolves <steamrtarm64>/../steamrtarm32/{gldriverquery,vulkandriverquery}
# when it probes GL and Vulkan. Valve ships no armhf runtime for this ARM64
# client, so both lookups exit 127 and Steam logs a failed driver probe. Both
# probes are plain aarch64 binaries, so a steamrtarm32 -> steamrtarm64 symlink
# satisfies the path. A real directory is never replaced, so this is safe to run
# on every start.
COPY <<'EOF_LAYOUT' /usr/local/bin/armada-steam-runtime-layout
#!/usr/bin/env bash
# Heal Steam's ARM64 runtime layout. Safe to run repeatedly.
set -euo pipefail
roots=("$@")
[ ${#roots[@]} -gt 0 ] || roots=("${STEAM_ROOT:-${HOME}/.local/share/Steam}")
changed=0
for root in "${roots[@]}"; do
    [ -d "${root}/steamrtarm64" ] || continue
    if [ -e "${root}/steamrtarm32" ] || [ -L "${root}/steamrtarm32" ]; then
        continue
    fi
    if ln -sfn steamrtarm64 "${root}/steamrtarm32"; then
        printf 'armada: created %s/steamrtarm32 -> steamrtarm64\n' "${root}" >&2
        changed=1
    fi
done
[ "$changed" = 1 ] || printf 'armada: steam runtime layout already correct\n' >&2
exit 0
EOF_LAYOUT

# Run the repair ahead of every systemd-launched Steam. ExecStartPre keeps it out
# of /usr/libexec/armada/launch-steam, which already owns the client lifetime and
# the exit-42 restart loop; wrapping that script again would fight its traps and
# change how a Steam restart is handled. The leading '-' keeps the unit starting
# even if the symlink cannot be created, since Steam must never be blocked here.
RUN <<'EOF_RUN'
set -eux
chmod 0755 /usr/local/bin/armada-steam-runtime-layout
for unit in gamescope-session-plus@steam.service armada-steam-desktop.service; do
    install -d "/etc/systemd/user/${unit}.d"
    printf '%s\n' '[Service]' \
        'ExecStartPre=-/usr/local/bin/armada-steam-runtime-layout' \
        > "/etc/systemd/user/${unit}.d/60-armada-steam-runtime.conf"
done
EOF_RUN
# 8c. MangoHud from the Fedora repository.
# The armada base image ships mangohud-0.8.4-1.fc44.armada, which carries nine
# patches aimed at bare-metal Qualcomm hardware: msm_dpu/msm_drm fdinfo
# identification, GPU monitoring, the SM8750 battery and RAM names. Inside a
# container those paths do not describe the real device, so the patched
# readings are not meaningful and the overlay can report values the host never
# exposed. Take the Fedora build instead, pinned by version so a later base
# image bump cannot silently reintroduce the armada package.
# The downgrade is explicit because `dnf install mangohud` treats the installed
# armada build as satisfying the request and would leave it in place.
ARG MANGOHUD_NEVRA=mangohud-0.8.3~rc1-2.fc44.aarch64
RUN set -eux; \
    current=$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' mangohud 2>/dev/null || echo none); \
    if [ "$current" != "$MANGOHUD_NEVRA" ]; then \
        if [ "$current" = none ]; then \
            dnf -y install --setopt=install_weak_deps=False "$MANGOHUD_NEVRA"; \
        else \
            dnf -y downgrade "$MANGOHUD_NEVRA"; \
        fi; \
    fi; \
    test "$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' mangohud)" = "$MANGOHUD_NEVRA"; \
    rpm -q --qf 'mangohud %{VERSION}-%{RELEASE} vendor=%{VENDOR}\n' mangohud; \
    dnf clean all

# --- 9. Anland gamescope (built from source, then discarded) ----------------
# ArmadaOS ships terra-gamescope, but the Anland display backend lives in the
# anland project and must be compiled against this exact gamescope revision.
# The anland tree is kept in the image so a later rebuild can run without
# re-cloning; every downloaded input, build product and build-only package is
# removed again in the same layer.
#
# build.sh refuses to run as root and needs four pinned inputs:
#
#   anland            github.com/sjszero/anland (legacy)       -> kept
#   armada patches    github.com/armada-os/armada  @ pinned     -> deleted
#   Terra RPM recipe  github.com/terrapkg/packages @ pinned     -> deleted
#   gamescope source  OpenGamingCollective/gamescope @ tag      -> deleted
#   xwayland SDK      xwayland.pc, generated below              -> deleted
#
# Pin rationale: gamescope.patch and the anland overlay are written against
# gamescope 3.17.0-ogc1 and the Armada patch series as of f0a50c0a. build.sh
# asserts exactly 32 Armada patches, so armada must never be taken from HEAD.

ARG ANLAND_REPOSITORY=https://github.com/sjszero/anland.git
ARG ANLAND_BRANCH=legacy
ARG ARMADA_REPOSITORY=https://github.com/armada-os/armada.git
ARG ARMADA_COMMIT=f0a50c0a178d71c0ea3d1a67e385dce0ef6c2158
ARG TERRA_REPOSITORY=https://github.com/terrapkg/packages.git
ARG TERRA_COMMIT=23ec8c9aeaad28179925232fe7564f80da06d4ab
ARG GAMESCOPE_REPOSITORY=https://github.com/OpenGamingCollective/gamescope
ARG GAMESCOPE_TAG=3.17.0-ogc1
ARG GAMESCOPE_COMMIT=4246b87f49d6116d5f863131dcc401fc52840644
ARG ANLAND_JOBS=4

# Drop privileges without opening a PAM session.
# runuser opens one, and pam_limits then fails with
# "cannot open session: Permission denied" as soon as a group-based limit has to
# be raised: the build user is in pipewire and gamemode, so
# @pipewire rtprio/nice and @gamemode nice apply, and raising them needs
# CAP_SYS_RESOURCE. No buildkit RUN has that capability, so build.sh could
# never start there. as-user falls back to setpriv, which needs no session.
COPY scripts/armada/as-user.sh /usr/local/bin/as-user

# 9a. Build and install gamescope with the Anland backend.
# One RUN for the whole thing. A layer can only shrink within a single
# instruction, so the toolchain is installed, used, and removed here; doing it
# across steps would bake compiler packages into the image permanently.
RUN <<'EOF_RUN'
set -eux

chmod 0755 /usr/local/bin/as-user
bash -n /usr/local/bin/as-user
# as-user falls back to setpriv; make sure the fallback really exists.
command -v setpriv >/dev/null || dnf -y install util-linux

BUILD_ROOT=/var/tmp/anland-gamescope-build
CACHE="$BUILD_ROOT/cache"
ANLAND=/usr/local/src/anland

rm -rf "$BUILD_ROOT"
install -d -m 0755 "$BUILD_ROOT" "$CACHE/recipe" "$CACHE/sdk/usr/lib64/pkgconfig"

# build-only toolchain
# Everything installed here is rolled back with `dnf history undo` at the end,
# so the compiler stack never survives into the image.
dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
    gcc gcc-c++ make cmake meson ninja-build rpm-build git-core tar patch \
    pkgconf-pkg-config python3 glm-devel google-benchmark-devel \
    libXcursor-devel libXmu-devel spirv-headers-devel glslang \
    stb_image-devel stb_image_resize-devel stb_image_write-devel \
    "pkgconfig(libavif)" "pkgconfig(libcap)" "pkgconfig(catch2-with-main)" \
    "pkgconfig(hwdata)" "pkgconfig(libdecor-0)" "pkgconfig(libdisplay-info)" \
    "pkgconfig(libdrm)" "pkgconfig(libeis-1.0)" "pkgconfig(libliftoff)" \
    "pkgconfig(libinput)" "pkgconfig(libpipewire-0.3)" "pkgconfig(libseat)" \
    "pkgconfig(libudev)" "pkgconfig(lcms2)" "pkgconfig(luajit)" "pkgconfig(sdl2)" \
    "pkgconfig(vulkan)" "pkgconfig(wayland-protocols)" "pkgconfig(wayland-scanner)" \
    "pkgconfig(wayland-server)" "pkgconfig(wlroots-0.18)" "pkgconfig(x11)" \
    "pkgconfig(x11-xcb)" "pkgconfig(xcb)" "pkgconfig(xcb-errors)" "pkgconfig(xcb-icccm)" \
    "pkgconfig(xcb-renderutil)" "pkgconfig(xcomposite)" "pkgconfig(xdamage)" \
    "pkgconfig(xext)" "pkgconfig(xfixes)" "pkgconfig(xkbcommon)" "pkgconfig(xrender)" \
    "pkgconfig(xres)" "pkgconfig(xtst)" "pkgconfig(xxf86vm)" \
    anda-srpm-macros
# anda-srpm-macros (from the terra repo, already enabled in the base image) is
# not optional here: the Terra spec writes `Requires: terra-gamescope-libs =
# %{evr}` and `%evr` is an anda macro. Without it rpm leaves the dependency as
# the literal string "%{evr}", which no package can ever satisfy, so the build
# succeeds but the later `rpm -Uvh` fails with
# "terra-gamescope-libs = %{evr} is needed by terra-gamescope". The spec's
# %prep/%install use of %git_clone/%conf is rewritten by build.sh, and %caps in
# %files is a file directive rather than a macro, so %evr is the only expansion
# that has to work.
if [ "$(rpm --eval '%{evr}')" = '%{evr}' ]; then
    echo 'anda-srpm-macros is missing: %{evr} does not expand, so the built' >&2
    echo 'gamescope RPMs would require a dependency no package can satisfy.' >&2
    exit 1
fi
# Remember the exact transaction so the same set can be undone later. dnf5 can
# print history as JSON; matching the text output with awk would also match
# "reinstall"/"uninstall" rows and could undo the wrong transaction.
TOOLCHAIN_TX=$(dnf history list --reverse --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["id"])')
test -n "$TOOLCHAIN_TX"

# inputs
# gamescope source, exactly the revision the Anland patches expect.
git clone --quiet --depth 1 --branch "$GAMESCOPE_TAG" \
    "$GAMESCOPE_REPOSITORY" "$CACHE/source"
test "$(git -C "$CACHE/source" rev-parse HEAD)" = "$GAMESCOPE_COMMIT"
git -C "$CACHE/source" submodule --quiet update --init --depth 1 --recursive

# Armada's native gamescope patch series at the pinned commit.
git clone --quiet --filter=blob:none --no-checkout \
    "$ARMADA_REPOSITORY" "$BUILD_ROOT/armada"
git -C "$BUILD_ROOT/armada" checkout --quiet "$ARMADA_COMMIT"
ARMADA_ROOT="$BUILD_ROOT/armada"
test "$(find "$ARMADA_ROOT/packages/gamescope/patches" \
    -name '[0-9][0-9][0-9][0-9]-*.patch' | wc -l)" = 32

# Terra/OGC RPM recipe at the pinned commit (build.sh adapts it in place).
git clone --quiet --filter=blob:none --no-checkout \
    "$TERRA_REPOSITORY" "$BUILD_ROOT/terra"
git -C "$BUILD_ROOT/terra" checkout --quiet "$TERRA_COMMIT"
TERRA_PKG="$BUILD_ROOT/terra/anda/games/terra-gamescope"
install -m 0644 "$TERRA_PKG/terra-gamescope.spec" "$CACHE/recipe/"
# build.sh copies every *.patch and stb.pc from recipe/ into SOURCES.
for f in "$TERRA_PKG"/*.patch "$TERRA_PKG"/stb.pc; do
    [ -e "$f" ] && install -m 0644 "$f" "$CACHE/recipe/"
done

# build.sh checks pkgconfig(xwayland) through a private SDK because the runtime
# Xwayland ships no development metadata. Only this .pc file is needed; the
# feature flags mirror the installed Xwayland.
cat > "$CACHE/sdk/usr/lib64/pkgconfig/xwayland.pc" <<'PC'
prefix=/usr
exec_prefix=${prefix}
xwayland=/usr/bin/Xwayland
have_glamor=true
have_glamor_api=true
have_eglstream=false
have_initfd=true
have_listenfd=true
have_terminate_delay=true
have_no_touch_pointer_emulation=true
have_force_xrandr_emulation=true
have_geometry=true
have_fullscreen=true
have_host_grab=true
have_decorate=true
have_enable_ei_portal=true
have_byteswappedclients=true
have_hidpi=true
Name: Xwayland
Description: X Server for Wayland
URL: https://gitlab.freedesktop.org/xorg/xserver/
Version: 24.1.14
PC

# anland tree (kept)
rm -rf "$ANLAND"
git clone --quiet --branch "$ANLAND_BRANCH" "$ANLAND_REPOSITORY" "$ANLAND"

# build
# build.sh requires an ordinary aarch64 user, so only this step drops root.
# as-user falls back to setpriv when PAM sessions are unavailable (buildkit).
chown -R "${USERNAME}:${USERNAME}" "$BUILD_ROOT" "$ANLAND"
/usr/local/bin/as-user "${USERNAME}" \
    env \
    HOME="/home/${USERNAME}" \
    CACHE="$CACHE" \
    ARMADA_ROOT="$ARMADA_ROOT" \
    JOBS="$ANLAND_JOBS" \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PATH="/usr/local/bin:/usr/bin:/usr/sbin" \
    bash "$ANLAND/producers/gamescope/ArmadaOS_v5/build.sh"

# install
# build.sh prints the artifact directory; it is the newest artifacts.* entry.
ARTIFACTS=$(ls -dt "$CACHE"/artifacts.* | head -1)
test -d "$ARTIFACTS"
mapfile -t RPMS < <(find "$ARTIFACTS" -maxdepth 1 -name '*.rpm' \
    ! -name '*-debuginfo-*' ! -name '*-debugsource-*' | sort)
test "${#RPMS[@]}" -ge 1
# rpm happily builds a package whose inter-subpackage dependency is the literal
# string "%{evr}", then refuses to install it. Catch that here, where the cause
# (a missing anda macro during rpmbuild) is still obvious.
if rpm -qp --requires "${RPMS[@]}" 2>/dev/null | grep -q '%{'; then
    echo 'built RPMs contain unexpanded macros in their requirements:' >&2
    rpm -qp --requires "${RPMS[@]}" 2>/dev/null | grep '%{' >&2
    exit 1
fi
# The base Armada image can ship a newer Terra gamescope than this pinned
# Anland build. --oldpackage intentionally permits that downgrade; --replacepkgs
# also makes reruns deterministic. Scriptlets stay enabled: the package registers
# a Vulkan implicit layer through %post.
rpm -Uvh --oldpackage --replacepkgs "${RPMS[@]}"

# verify
# The installed compositor must report the anland backend before the sources go.
test -x /usr/bin/gamescope
/usr/bin/gamescope --help 2>&1 | grep -q 'anland'
test -x /usr/libexec/gamescope-anland/startup.sh
rpm -q terra-gamescope

# clean up
# Everything the build downloaded. The anland tree keeps its .git on purpose:
# build.sh records `git -C $HERE rev-parse HEAD` and the rebuild path resets to
# origin/legacy, so removing it would make every later rebuild fail.
rm -rf "$BUILD_ROOT"
# Roll the toolchain transaction back. gamescope's own packages stay: they were
# installed by the rpm call above, not by dnf, so undo cannot touch them.
dnf -y history undo "$TOOLCHAIN_TX" --skip-unavailable \
    --setopt=clean_requirements_on_remove=False || true
dnf clean all
rm -rf /var/cache/dnf/* /var/cache/libdnf5/* 2>/dev/null || true
# The installed compositor must still work without the compiler stack.
/usr/bin/gamescope --help >/dev/null
EOF_RUN

# 9b. Rebuild entrypoint.
# The anland tree stays so gamescope can be rebuilt inside a running container.
# Inputs are fetched again per run and deleted on exit, exactly as above.
COPY <<'EOF_REBUILD' /usr/local/bin/anland-rebuild-gamescope
#!/usr/bin/bash
# Rebuild and reinstall gamescope with the Anland backend.
#
# /usr/local/src/anland is kept in the image, so this works without a re-clone.
# Build inputs are fetched per run and removed on exit; nothing is cached.
set -euo pipefail

ANLAND=/usr/local/src/anland
BUILD_ROOT=/var/tmp/anland-gamescope-build
CACHE="$BUILD_ROOT/cache"
ARMADA_COMMIT=f0a50c0a178d71c0ea3d1a67e385dce0ef6c2158
TERRA_COMMIT=23ec8c9aeaad28179925232fe7564f80da06d4ab
GAMESCOPE_TAG=${GAMESCOPE_TAG:-3.17.0-ogc1}
JOBS=${JOBS:-$(nproc)}

(( EUID == 0 )) || { echo 'anland-rebuild-gamescope: must run as root' >&2; exit 1; }
[[ -x $ANLAND/producers/gamescope/ArmadaOS_v5/build.sh ]] || {
    echo "anland-rebuild-gamescope: $ANLAND is missing; reinstall the image" >&2
    exit 1
}

cleanup() { rm -rf "$BUILD_ROOT"; }
trap cleanup EXIT

rm -rf "$BUILD_ROOT"
install -d -m 0755 "$CACHE/recipe" "$CACHE/sdk/usr/lib64/pkgconfig" "$BUILD_ROOT"

dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
    gcc gcc-c++ make cmake meson ninja-build rpm-build git-core tar patch \
    pkgconf-pkg-config python3 glm-devel google-benchmark-devel \
    libXcursor-devel libXmu-devel spirv-headers-devel glslang \
    stb_image-devel stb_image_resize-devel stb_image_write-devel \
    "pkgconfig(libavif)" "pkgconfig(libcap)" "pkgconfig(catch2-with-main)" \
    "pkgconfig(hwdata)" "pkgconfig(libdecor-0)" "pkgconfig(libdisplay-info)" \
    "pkgconfig(libdrm)" "pkgconfig(libeis-1.0)" "pkgconfig(libliftoff)" \
    "pkgconfig(libinput)" "pkgconfig(libpipewire-0.3)" "pkgconfig(libseat)" \
    "pkgconfig(libudev)" "pkgconfig(lcms2)" "pkgconfig(luajit)" "pkgconfig(sdl2)" \
    "pkgconfig(vulkan)" "pkgconfig(wayland-protocols)" "pkgconfig(wayland-scanner)" \
    "pkgconfig(wayland-server)" "pkgconfig(wlroots-0.18)" "pkgconfig(x11)" \
    "pkgconfig(x11-xcb)" "pkgconfig(xcb)" "pkgconfig(xcb-errors)" "pkgconfig(xcb-icccm)" \
    "pkgconfig(xcb-renderutil)" "pkgconfig(xcomposite)" "pkgconfig(xdamage)" \
    "pkgconfig(xext)" "pkgconfig(xfixes)" "pkgconfig(xkbcommon)" "pkgconfig(xrender)" \
    "pkgconfig(xres)" "pkgconfig(xtst)" "pkgconfig(xxf86vm)" \
    anda-srpm-macros
if [ "$(rpm --eval '%{evr}')" = '%{evr}' ]; then
    echo 'anland-rebuild-gamescope: anda-srpm-macros did not provide %{evr};' >&2
    echo 'the gamescope RPMs would be unsatisfiable. Aborting.' >&2
    exit 1
fi
rpm -qa --qf '%{NAME}\n' | sort > "$BUILD_ROOT/pkgs-before.txt"

# Pick up newer backend changes before rebuilding.
git -C "$ANLAND" fetch --quiet origin
git -C "$ANLAND" reset --quiet --hard "origin/${ANLAND_BRANCH:-legacy}"

git clone --quiet --depth 1 --branch "$GAMESCOPE_TAG" \
    https://github.com/OpenGamingCollective/gamescope "$CACHE/source"
git -C "$CACHE/source" submodule --quiet update --init --depth 1 --recursive

git clone --quiet --filter=blob:none --no-checkout \
    https://github.com/armada-os/armada.git "$BUILD_ROOT/armada"
git -C "$BUILD_ROOT/armada" checkout --quiet "$ARMADA_COMMIT"

git clone --quiet --filter=blob:none --no-checkout \
    https://github.com/terrapkg/packages.git "$BUILD_ROOT/terra"
git -C "$BUILD_ROOT/terra" checkout --quiet "$TERRA_COMMIT"
TERRA_PKG="$BUILD_ROOT/terra/anda/games/terra-gamescope"
install -m 0644 "$TERRA_PKG/terra-gamescope.spec" "$CACHE/recipe/"
for f in "$TERRA_PKG"/*.patch "$TERRA_PKG"/stb.pc; do
    [ -e "$f" ] && install -m 0644 "$f" "$CACHE/recipe/"
done

cat > "$CACHE/sdk/usr/lib64/pkgconfig/xwayland.pc" <<'PC'
prefix=/usr
exec_prefix=${prefix}
xwayland=/usr/bin/Xwayland
have_glamor=true
have_glamor_api=true
have_eglstream=false
have_initfd=true
have_listenfd=true
have_terminate_delay=true
have_no_touch_pointer_emulation=true
have_force_xrandr_emulation=true
have_geometry=true
have_fullscreen=true
have_host_grab=true
have_decorate=true
have_enable_ei_portal=true
have_byteswappedclients=true
have_hidpi=true
Name: Xwayland
Description: X Server for Wayland
URL: https://gitlab.freedesktop.org/xorg/xserver/
Version: 24.1.14
PC

BUILD_USER=${BUILD_USER:-$(getent passwd 1000 | cut -d: -f1)}
[[ -n $BUILD_USER ]] || { echo 'anland-rebuild-gamescope: no uid 1000 user' >&2; exit 1; }
BUILD_HOME=$(getent passwd "$BUILD_USER" | cut -d: -f6)
chown -R "$BUILD_USER" "$BUILD_ROOT" "$ANLAND"
/usr/local/bin/as-user "$BUILD_USER" \
    env \
    HOME="$BUILD_HOME" \
    CACHE="$CACHE" ARMADA_ROOT="$BUILD_ROOT/armada" JOBS="$JOBS" \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 PATH=/usr/local/bin:/usr/bin:/usr/sbin \
    bash "$ANLAND/producers/gamescope/ArmadaOS_v5/build.sh"

ARTIFACTS=$(ls -dt "$CACHE"/artifacts.* | head -1)
mapfile -t RPMS < <(find "$ARTIFACTS" -maxdepth 1 -name '*.rpm' \
    ! -name '*-debuginfo-*' ! -name '*-debugsource-*' | sort)
((${#RPMS[@]})) || { echo 'anland-rebuild-gamescope: no RPMs produced' >&2; exit 1; }
rpm -Uvh --oldpackage --replacepkgs "${RPMS[@]}"
/usr/bin/gamescope --help 2>&1 | grep -q 'anland'

rpm -qa --qf '%{NAME}\n' | sort > "$BUILD_ROOT/pkgs-after.txt"
comm -13 "$BUILD_ROOT/pkgs-before.txt" "$BUILD_ROOT/pkgs-after.txt" \
    > "$BUILD_ROOT/pkgs-added.txt" || true
if [ -s "$BUILD_ROOT/pkgs-added.txt" ]; then
    xargs -r dnf -y remove --setopt=clean_requirements_on_remove=False \
        < "$BUILD_ROOT/pkgs-added.txt" || true
fi
echo 'anland-rebuild-gamescope: gamescope reinstalled'
EOF_REBUILD

RUN <<'EOF_RUN'
set -eux
chmod 0755 /usr/local/bin/anland-rebuild-gamescope
bash -n /usr/local/bin/anland-rebuild-gamescope
EOF_RUN

# --- 10. Optional Anland container stack ------------------------------------
# ArmadaOS already ships terra-gamescope with the Anland backend from the
# armada package set. Installing the Droidspaces Anland release over it would
# replace a working armada build with a differently-patched one, so this stays
# opt-in: pass --build-arg ENABLE_ANLAND_OVERLAY=true to layer it on top.
#
# KWin is a different case and is NOT covered by terra-gamescope. Armada's own
# kwin RPM is a plain Fedora build, so it only has the DRM backend: with just a
# render node exposed (/dev/dri/renderD128, no card0) it reports "No suitable
# DRM devices have been found" and the Plasma session crashes on startup. Only
# the Anland kwin RPM provides the --anland backend that renders through the
# display daemon. DESKTOP must therefore be kde (or kde-mobile) for desktop
# mode to work; other values leave KWin unable to start a session.
ARG ENABLE_ANLAND_OVERLAY=false
RUN if [ "$ENABLE_ANLAND_OVERLAY" = "true" ]; then \
        echo "--> [开启] 正在安装 Anland 桌面包 (${ANLAND_PACKAGE_REVISION})..." && \
        ANLAND_RELEASE_REPOSITORY="$ANLAND_RELEASE_REPOSITORY" \
        /usr/local/sbin/install-anland-desktop "$DESKTOP" --1; \
    else \
        echo "--> [跳过] 保留 ArmadaOS 自带的 Anland/gamescope 构建"; \
    fi

# --- 11. Optional extra tooling (mirrors the Fedora templates) --------------
RUN set -eux; \
    if [ "$ENABLE_kfgj_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False \
            gcc gcc-c++ make cmake autoconf automake libtool pkgconf clang llvm \
            python3 python3-pip python3-devel ripgrep ShellCheck; \
    fi; \
    if [ "$ENABLE_zip_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False \
            zip unzip p7zip p7zip-plugins bzip2 xz tar gzip; \
    fi; \
    if [ "$ENABLE_docker_ARG" = "true" ]; then \
        # podman is already present in the armada image; add compose instead of
        # pulling moby-engine, which conflicts with armada's container stack.
        dnf install -y --setopt=install_weak_deps=False podman-compose; \
    fi; \
    if [ "$ENABLE_binfmt_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False qemu-user-static; \
    fi; \
    dnf clean all; \
    rm -rf /var/cache/dnf/*

# --- 12. Optional systemd 257 old-kernel runtime ----------------------------
RUN if [ "$ENABLE_systemd257_ARG" = "true" ]; then \
        bash /usr/local/sbin/systemd257; \
    else \
        echo "--> [跳过] 未启用 systemd 257 旧内核兼容"; \
    fi

# Use the same Android KGSL/Turnip Mesa build as the other RootFS templates.
# Install after package transactions so they cannot restore the stock drivers.
RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        /usr/local/sbin/install-mesa --1; \
    else \
        echo "--> [跳过] 未开启 Mesa 驱动安装"; \
    fi

# Portal packages are explicitly denied and removed as a family. Use rpm --nodeps
# so Fedora's portal recommendations from Firefox/Plasma do not remove those apps.
RUN set -eux; \
    for pkg in $(rpm -qa --qf '%{NAME}\n' | grep '^xdg-desktop-portal' || true); do \
        rpm -e --nodeps "$pkg"; \
    done; \
    test -z "$(rpm -qa --qf '%{NAME}\n' | grep '^xdg-desktop-portal' || true)"; \
    grep -F 'xdg-desktop-portal*' /etc/dnf/dnf.conf | grep -q '^excludepkgs='; \
    grep -F 'xdg-desktop-portal*' /etc/dnf/dnf.conf | grep -q '^exclude='

RUN rm -f \
        /usr/local/sbin/install-droidspaces-usb-manager \
        /usr/local/sbin/systemd257 \
        /usr/local/sbin/install-anland-desktop \
        /usr/local/sbin/install-mesa \
        /usr/local/sbin/nosnap 2>/dev/null || true; \
    dnf clean all; \
    rm -rf /var/cache/dnf/* /tmp/* /var/tmp/* /var/lib/dnf/*

# Container marker used by the other templates and by Droidspaces tooling.
RUN { echo "armadaos-container"; } > /etc/armada-container && \
    cat /etc/armada-container 2>/dev/null || true

# Stage 2: export the finished root filesystem.
FROM scratch AS export
COPY --from=customizer / /