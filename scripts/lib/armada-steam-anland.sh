#!/usr/bin/bash
# Sourced after Armada's Steam session settings, before gamescope starts.
# Native KGSL GL cannot share the GBM buffers Steam's CEF UI expects here.
# Zink uses the same Turnip driver as gamescope and keeps the UI accelerated.
if [[ ${BACKEND:-} == anland ]]; then
    export MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink FD_FORCE_KGSL=1

    if [[ -z ${VK_DRIVER_FILES:-} && -z ${VK_ICD_FILENAMES:-} ]]; then
        export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
    fi
    # Steam's CEF (steamwebhelper) loads its own bundled ANGLE, so the Mesa
    # loader override above never reaches the UI's GPU process. On KGSL that
    # ANGLE build crashes the GPU process (SIGTRAP) until it stops respawning
    # and the renderers spin in a black window. Armada's validated workaround
    # is to drop ANGLE's timer queries, scoped to the Steam client only.
    angle_features=${ANGLE_FEATURE_OVERRIDES_ENABLED:-}
    case :${angle_features}: in
    *:disableTimestampQueries:*) ;;
    *) angle_features="${angle_features:+${angle_features}:}disableTimestampQueries" ;;
    esac
    # ARM Steam resolves XRandR via RTLD_NEXT. Load its real symbols first.
    # Scope both overrides to the client command so gamescope stays untouched.
    CLIENTCMD="env LD_PRELOAD=libXrandr.so.2${LD_PRELOAD:+:${LD_PRELOAD}} ANGLE_FEATURE_OVERRIDES_ENABLED=${angle_features} ${CLIENTCMD}"
fi