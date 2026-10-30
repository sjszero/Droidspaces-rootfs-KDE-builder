#!/usr/bin/python3
"""Honour display sleep in gamescope's Anland backend.

Upstream implements `gamescope_control.display_sleep` (protocol v4) only for the
DRM backend: `wlserver.cpp` calls `drm_sleep_screen()`, which sets the
`cv_drm_sleep_screens[]` convars, and the DRM atomic commit path then drives
`CRTC_ID = 0` on the real connector to blank it.

The Anland backend has no DRM connector to blank, so that request was accepted
and then silently dropped: the convar flipped, nothing read it, and no frame
ever stopped or resumed. From Steam's point of view the panel went to sleep and
never came back -- the black screen with no way out.

This patch only touches the Anland overlay (`src/Backends/anland`), which is the
component that owns the backend. It reads the very same convar the DRM path
already maintains, so no header, wlserver or meson change is needed:

  * while either screen is flagged asleep, `IsPaused()` reports true, which is
    the existing gamescope hook that stops the paint path from submitting;
  * an explicit `display_sleep(wake)` needs no help here: wlserver already
    calls `drm_sleep_screen(..., false)`, which clears the convar itself and
    fires `force_repaint()` through the convar callback;
  * the case this patch exists for is a consumer that goes away and comes
    back. The backend keeps waiting in the background and clears the sleep
    flags on the reconnect path, so re-entering the consumer wakes the panel.

Deliberately *not* done here: waking whenever a render target is available.
A connected consumer keeps publishing targets while the panel is asleep, so
that check would cancel every sleep request on the very next poll and put the
session back to square one (this was the first version of the patch and it
made `display_sleep` a no-op).
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "AnlandSleepRequested"

# 1. Read the DRM-owned sleep convars from the Anland backend. They have
#    external linkage and wlserver already sets them on display_sleep.
ANCHOR_NS = """namespace gamescope
{
    static anland_gamescope_session *s_session = nullptr;
    static uint64_t s_pending = 0;
"""

PATCH_NS = """// ArmadaOS: display_sleep is implemented upstream only for the DRM backend,
// which blanks a real connector through cv_drm_sleep_screens[]. Anland has no
// connector, so the request used to be accepted and dropped. Read the same
// convars here and honour them: while asleep no frames are submitted, and a
// reconnecting consumer clears them again.
//
// The convar array is defined in DRMBackend.cpp at global scope (the
// gamescope:: only qualifies its element type), so this declaration must also
// sit at global scope. Declaring it inside namespace gamescope mangles to
// gamescope::cv_drm_sleep_screens and fails to link.
extern gamescope::ConVar<bool> cv_drm_sleep_screens[];

namespace gamescope
{
    static anland_gamescope_session *s_session = nullptr;
    static uint64_t s_pending = 0;
    static bool AnlandSleepRequested()
    {
        return cv_drm_sleep_screens[ GAMESCOPE_SCREEN_TYPE_INTERNAL ] ||
               cv_drm_sleep_screens[ GAMESCOPE_SCREEN_TYPE_EXTERNAL ];
    }
    static void AnlandClearSleepRequest()
    {
        // Assigning the convar runs its callback (force_repaint), so the frame
        // flow restarts immediately instead of waiting for the next input.
        if ( cv_drm_sleep_screens[ GAMESCOPE_SCREEN_TYPE_INTERNAL ] )
            cv_drm_sleep_screens[ GAMESCOPE_SCREEN_TYPE_INTERNAL ] = false;
        if ( cv_drm_sleep_screens[ GAMESCOPE_SCREEN_TYPE_EXTERNAL ] )
            cv_drm_sleep_screens[ GAMESCOPE_SCREEN_TYPE_EXTERNAL ] = false;
    }
"""

# 2. IsPaused already gates the paint path; make sleep stop submission.
ANCHOR_PAUSED = """        virtual bool IsPaused() const override
        {
            anland_gamescope_target target{};
            target.buffer.fd = -1;
            if (!s_session || s_pending ||
                anland_gamescope_session_target(s_session, &target) != 0)
                return true;
            close(target.buffer.fd);
            return false;
        }
"""
PATCH_PAUSED = """        virtual bool IsPaused() const override
        {
            // ArmadaOS: an explicit display_sleep request stops the frame flow.
            // The session itself stays open, so waking does not have to rebuild
            // the display link.
            AnlandNoteSleepState();
            if ( AnlandSleepRequested() )
                return true;
            anland_gamescope_target target{};
            target.buffer.fd = -1;
            if (!s_session || s_pending ||
                anland_gamescope_session_target(s_session, &target) != 0)
                return true;
            close(target.buffer.fd);
            return false;
        }
"""

# 3. Observe sleep/wake transitions so the state is verifiable from the log.
ANCHOR_NS2 = """    static bool AnlandSleepRequested()
    {
        return cv_drm_sleep_screens[ GAMESCOPE_SCREEN_TYPE_INTERNAL ] ||
               cv_drm_sleep_screens[ GAMESCOPE_SCREEN_TYPE_EXTERNAL ];
    }
"""
PATCH_NS2 = """    static bool AnlandSleepRequested()
    {
        return cv_drm_sleep_screens[ GAMESCOPE_SCREEN_TYPE_INTERNAL ] ||
               cv_drm_sleep_screens[ GAMESCOPE_SCREEN_TYPE_EXTERNAL ];
    }
    // Log only on edges: a per-frame wake message would drown the log, and the
    // whole point of this patch is that the state is observable at all.
    static void AnlandNoteSleepState()
    {
        static bool s_bAsleep = false;
        const bool bAsleep = AnlandSleepRequested();
        if ( bAsleep == s_bAsleep )
            return;
        s_bAsleep = bAsleep;
        fprintf( stderr, bAsleep ? "Anland: display asleep, frames halted\\n"
                                 : "Anland: display awake, frames resumed\\n" );
    }
"""

# 4. A fresh session is also a wake source: the consumer came back.
ANCHOR_RECONNECT = """                AttachSession();
                dirty = true;
                fprintf(stderr, "Anland: session reconnected\\n");
"""
PATCH_RECONNECT = """                AttachSession();
                dirty = true;
                // ArmadaOS: a reconnected consumer wants frames, so a sleep
                // request left over from while it was gone is stale.
                if ( AnlandSleepRequested() )
                {
                    AnlandClearSleepRequest();
                    force_repaint();
                }
                fprintf(stderr, "Anland: session reconnected\\n");
"""

EDITS = (
    (ANCHOR_NS, PATCH_NS, "sleep-state"),
    (ANCHOR_NS2, PATCH_NS2, "sleep-log"),
    (ANCHOR_PAUSED, PATCH_PAUSED, "is-paused"),
    (ANCHOR_RECONNECT, PATCH_RECONNECT, "reconnect-wake"),
)

def find_source(root: Path) -> Path | None:
    """Locate AnlandBackend.cpp in either layout.

    The upstream/RPM tree keeps it under src/Backends/anland, but the ArmadaOS
    producer stores the overlay itself in anland_backend/ and tars that
    directory up as the overlay. Both must patch cleanly.
    """
    for relative in (
        Path("src/Backends/anland/AnlandBackend.cpp"),
        Path("anland_backend/AnlandBackend.cpp"),
        Path("AnlandBackend.cpp"),
    ):
        candidate = root / relative
        if candidate.is_file():
            return candidate
    return None


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: patch-anland-display-sleep.py <gamescope source root>", file=sys.stderr)
        return 2

    path = find_source(Path(argv[1]))
    if path is None:
        print(f"{argv[1]}: no AnlandBackend.cpp found", file=sys.stderr)
        return 1


    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"{path}: already patched")
        return 0

    # Every edit is applied in memory first; a mismatched anchor must not leave
    # the tree half patched.
    for anchor, replacement, name in EDITS:
        found = text.count(anchor)
        if found != 1:
            print(f"{path}: {name}: expected 1 anchor, found {found}", file=sys.stderr)
            return 1
        text = text.replace(anchor, replacement, 1)

    path.write_text(text, encoding="utf-8")
    print(f"{path}: patched ({', '.join(name for _, _, name in EDITS)})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))