%global commit 2f130fab1d6e1a4ee8a71dc60cfdfcc839ad192a

# The distribution package is only useful with its debuginfo stripped and we ship
# a Release build anyway; a debuginfo subpackage would just double the download.
%global debug_package %{nil}

# This package mixes aarch64 binaries with the x86-64 libraries box64 feeds to
# its emulated loader. rpm's ELF dependency generator cannot be pointed at one
# path here: __provides_exclude_from is ignored by the ELF generator on rpm
# 6.0.2, and __elf_exclude_path - which does work in a minimal test package -
# has no effect once this spec carries the real %install/%files (both verified).
# Leaving the generator on makes an aarch64 package advertise
# "Provides: libstdc++.so.6()(64bit)", which could satisfy another package's
# dependency with an x86-64 file, and pulls in libssl/libssh/libldap as
# "Requires" on behalf of the emulated libcurl. So the generators are switched
# off and the only native dependency that matters is declared by hand:
# /usr/bin/box64 links libc, libm and libresolv (GLIBC_2.43 symbols) and nothing
# else, which is checked by readelf in build-rpm.sh's smoke test.
%global __elf_provides /bin/true
%global __elf_requires /bin/true

Name:           box64-armada
Version:        0.4.4
Release:        1%{?dist}
Summary:        box64 x86-64 emulator plus the ArmadaOS x86-64 game runtime

License:        MIT
URL:            https://github.com/ptitSeb/box64
Source0:        box64-%{version}.tar.gz
# x86-64 shared libraries box64 cannot wrap onto the host (see build-rpm.sh).
Source1:        box64-x86_64-libs.tar.gz
# Everything below is the repo's own copy; the spec must never invent its own.
Source2:        box64.box64rc
Source3:        box64-binfmt
Source4:        box64-binfmt.service
Source5:        box64-run
Source6:        compatibilitytool.vdf
Source7:        toolmanifest.vdf
Source8:        README.md

ExclusiveArch:  aarch64

# Fedora's box64 0.3.6 owns /usr/bin/box64 and box64-data owns /etc/box64.box64rc.
# This package replaces both instead of fighting over the same paths: the emulator
# alone is useless without the tuned rcfile, the x86-64 libraries and the Steam
# compatibility tool that come with it.
Obsoletes:      box64 < %{version}-%{release}
Provides:       box64 = %{version}-%{release}
Obsoletes:      box64-data < %{version}-%{release}
Provides:       box64-data = %{version}-%{release}

# Only dependency the packaging machine would otherwise compute for us.
Requires:       glibc >= 2.43
Requires:       systemd
Requires:       util-linux
Requires(post): systemd
Requires(postun): systemd

BuildRequires:  cmake
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  make

%description
box64 emulates an x86-64 user space on aarch64, and this package is the whole
runtime ArmadaOS needs to play x86-64 Linux games inside the container:

  * box64 0.4.4 built from upstream commit %{commit} with the arm64 dynarec on;
  * /etc/box64.box64rc tuned and measured on this hardware (DYNAREC_STRONGMEM=1
    is what keeps CoreCLR games alive, DYNAREC_SAFEFLAGS=0 is the only setting
    that measured faster; see the file itself for the numbers);
  * the x86-64 libraries box64 cannot wrap onto the host's aarch64 ones
    (libstdc++, libgcc, ICU, the curl chain) in /usr/lib/box64-x86_64-linux-gnu,
    which is the path box64 hardcodes;
  * the binfmt_misc registration, mounted and re-registered deterministically so
    it beats FEX's own x86-64 handler regardless of boot order;
  * the "box64 (Armada)" Steam compatibility tool, so a game only needs its
    properties switched to it.

%prep
%setup -q -n box64-%{commit}

%build
cmake -S . -B build \
    -DARM_DYNAREC=ON \
    -DNOGIT=ON \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build --parallel %{?_smp_build_ncpus}%{!?_smp_build_ncpus:4}

%install
install -Dpm 0755 build/box64 %{buildroot}%{_bindir}/box64
# With debug_package switched off, brp-strip does not always run over the binary;
# an unstripped box64 is 29 MB against 6 MB stripped. Do it here so the size does
# not depend on rpm's stage behaviour.
strip --strip-unneeded %{buildroot}%{_bindir}/box64
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_sysconfdir}/box64.box64rc
install -Dpm 0755 %{SOURCE3} %{buildroot}%{_libexecdir}/armada/box64-binfmt
install -Dpm 0644 %{SOURCE4} %{buildroot}%{_unitdir}/box64-binfmt.service
install -Dpm 0755 %{SOURCE5} %{buildroot}%{_datadir}/steam/compatibilitytools.d/box64-armada/box64-run
install -Dpm 0644 %{SOURCE6} %{buildroot}%{_datadir}/steam/compatibilitytools.d/box64-armada/compatibilitytool.vdf
install -Dpm 0644 %{SOURCE7} %{buildroot}%{_datadir}/steam/compatibilitytools.d/box64-armada/toolmanifest.vdf
install -Dpm 0644 %{SOURCE8} %{buildroot}%{_docdir}/%{name}/README.md
install -Dpm 0644 LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE

# box64 looks for these in /usr/lib/box64-x86_64-linux-gnu (hardcoded in core.c),
# not in %{_libdir}, so the path is spelled out on purpose.
mkdir -p %{buildroot}%{_prefix}/lib/box64-x86_64-linux-gnu
tar -xzf %{SOURCE1} --no-same-owner --no-same-permissions \
    -C %{buildroot}%{_prefix}/lib/box64-x86_64-linux-gnu

%post
# Deployments that predate this package left their own unit in /etc/systemd/system,
# which shadows the packaged one.
if [ -f /etc/systemd/system/box64-binfmt.service ] &&
   ! rpm -qf /etc/systemd/system/box64-binfmt.service >/dev/null 2>&1; then
    rm -f /etc/systemd/system/box64-binfmt.service
fi
systemctl daemon-reload >/dev/null 2>&1 || :
systemctl enable box64-binfmt.service >/dev/null 2>&1 || :
# The unit drops and re-adds the handler, which is also how an upgrade switches
# the interpreter to the new binary.
systemctl restart box64-binfmt.service >/dev/null 2>&1 || :

if [ -e /proc/sys/fs/binfmt_misc/box64 ]; then
    echo "box64-armada: $(/usr/bin/box64 --version 2>&1 | head -1)"
    echo "box64-armada: binfmt_misc handler registered; x86-64 binaries run through box64."
else
    echo "box64-armada: WARNING: the binfmt_misc handler is not registered," >&2
    echo "box64-armada: x86-64 binaries will fail with ENOEXEC until it is." >&2
    echo "box64-armada: check 'systemctl status box64-binfmt.service'." >&2
fi
echo "box64-armada: restart Steam once so it lists \"box64 (Armada)\" under"
echo "box64-armada: Properties -> Compatibility; per-game mapping is manual."

%preun
if [ "$1" -eq 0 ]; then
    systemctl disable box64-binfmt.service >/dev/null 2>&1 || :
    # Leaving a handler behind that points at a removed /usr/bin/box64 makes every
    # x86-64 exec fail with ENOENT instead of ENOEXEC, which is harder to read.
    if [ -e /proc/sys/fs/binfmt_misc/box64 ]; then
        echo -1 >/proc/sys/fs/binfmt_misc/box64 || :
    fi
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :

%files
%{_bindir}/box64
%config(noreplace) %{_sysconfdir}/box64.box64rc
%{_libexecdir}/armada/box64-binfmt
%{_unitdir}/box64-binfmt.service
%{_prefix}/lib/box64-x86_64-linux-gnu
%{_datadir}/steam/compatibilitytools.d/box64-armada
%doc %{_docdir}/%{name}/README.md
%license %{_licensedir}/%{name}/LICENSE

%changelog
* Thu Nov 19 2026 Gold <gold@armadaos> - 0.4.4-1
- Package the whole box64 runtime: emulator, tuned rcfile, x86-64 libraries,
  binfmt registration and the Steam compatibility tool.