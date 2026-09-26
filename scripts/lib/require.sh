# Ported-From: danwright32/ovation scripts/lib/require.sh @ 6814737f16c67e4f2a3fb5d062cb96d5dde6d44f
#
# Ported on 2026-09-26 by backstage#69, with the three scripts that now load
# their libraries through it. It arrives unchanged. The scan it mentions,
# scripts/test-require-lib.sh, was NOT ported with it, so here nothing refuses a
# library loaded some other way.
# Sourced, never run. `require_lib` loads a library or REFUSES, by name.
#
# ovation#399. Bash's `.` on a missing file writes to stderr, returns non zero,
# and CARRIES ON, and these scripts run without `-e`. Measured 2026-09-17 in a
# port of check-ci-workflow.sh with its two libraries absent: every line of its
# summary was true, "0 check script(s) named by a step", and it exited 0 with
# nothing checked, because the function that finds the steps did not exist. A
# guard that goes green because part of it could not run is indistinguishable
# from one that verified everything (L98, L530, L488).
#
# SO EVERY SCRIPT LOADS ITS LIBRARIES THROUGH THIS, and loads THIS with the one
# line that refuses if it is missing itself:
#
#     . "<dir>/lib/require.sh" 2>/dev/null || { echo "REFUSED: scripts/lib/require.sh is missing, so nothing was checked." >&2; exit 2; }
#
# That line is safe to write as a plain `||` only because this file ends in a
# function definition, whose status is 0: a library whose last command can fail
# would read as missing, which is why the other libraries go through the -f test
# below rather than through `||`. `scripts/test-require-lib.sh` scans every
# script that is not a test for a library loaded any other way.
#
# Exit 2, never 1: a refusal because the check could not RUN is not a finding
# that something is wrong, and the gates here treat 2 as "cannot measure".
require_lib() {
    if [ ! -f "$1" ]; then
        echo "REFUSED: $1 is missing, so part of this script could not run." >&2
        echo "    Nothing was verified, which is not the same as nothing being wrong." >&2
        exit 2
    fi
    # shellcheck disable=SC1090
    . "$1"
}
