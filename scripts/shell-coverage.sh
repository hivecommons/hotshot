#!/usr/bin/env bash
# Runs the bash test suites under xtrace and enforces a per-script line
# coverage floor on the scripts they exercise.
#
# The suites run their targets under `env -i`, so each harness forwards
# HOTSHOT_COVERAGE_RC as BASH_ENV; the rc enables xtrace into a trace file.
# A line counts as covered when BASH_SOURCE:LINENO appears in the trace.
#
# Floors (percent) are overridable: HOTSHOT_FLOOR_CAPTURE, HOTSHOT_FLOOR_INSTALL,
# HOTSHOT_FLOOR_BUNDLE.
#
# Usage: bash scripts/shell-coverage.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLOOR_CAPTURE="${HOTSHOT_FLOOR_CAPTURE:-95}"
FLOOR_INSTALL="${HOTSHOT_FLOOR_INSTALL:-95}"
FLOOR_BUNDLE="${HOTSHOT_FLOOR_BUNDLE:-95}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TRACE="$WORK/trace.log"
RC="$WORK/trace.rc"
: >"$TRACE"

cat >"$RC" <<RCEOF
exec 9>>"$TRACE"
export BASH_XTRACEFD=9
export PS4='+COV \${BASH_SOURCE}:\${LINENO}:'
set -x
RCEOF
export HOTSHOT_COVERAGE_RC="$RC"

for suite in linux/tests/hotshot-capture.test.sh linux/tests/install.test.sh scripts/tests/bundle.test.sh; do
    echo "== $suite"
    bash "$ROOT/$suite"
done

# Unique "<basename>:<line>" pairs; bundle.test.sh runs a copy of bundle.sh
# from a temp project, so match on basename (line numbers are unchanged).
grep -o '+COV [^ ]*:[0-9]*:' "$TRACE" \
    | sed -e 's/^+COV //' -e 's/:$//' -e 's|.*/||' \
    | sort -u >"$WORK/hits"

# Prints the executable line numbers of $1, one per line.
executable_lines() {
    awk '
        heredoc != "" {
            if ($0 == heredoc) heredoc = ""
            next
        }
        /^[[:space:]]*esac/ { in_case = 0 }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*(fi|done|esac|else|then|\}|\{|;;)[[:space:]]*$/ { next }
        /^[[:space:]]*[^[:space:]()]+[^()]*\)[[:space:]]*$/ && !/\(/ && in_case { next }
        /^[[:space:]]*case[[:space:]]/ { in_case = 1 }
        {
            print NR
            if (match($0, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z_0-9]*["\047]?/)) {
                tag = substr($0, RSTART, RLENGTH)
                gsub(/<<-?[[:space:]]*["\047]?/, "", tag)
                gsub(/["\047]/, "", tag)
                heredoc = tag
            }
        }
    ' "$1"
}

STATUS=0
report() { # $1 = repo-relative script, $2 = floor
    local script="$1" floor="$2" base total=0 covered=0 line pct
    base="$(basename "$script")"
    while read -r line; do
        total=$((total + 1))
        if grep -qxF "$base:$line" "$WORK/hits"; then
            covered=$((covered + 1))
        else
            echo "  uncovered: $script:$line"
        fi
    done < <(executable_lines "$ROOT/$script")
    if [ "$total" -eq 0 ]; then
        echo "FAIL $script: no executable lines found"
        STATUS=1
        return
    fi
    pct=$((covered * 100 / total))
    if [ "$pct" -lt "$floor" ]; then
        echo "FAIL $script: $pct% ($covered/$total) is below the $floor% floor"
        STATUS=1
    else
        echo "ok   $script: $pct% ($covered/$total), floor $floor%"
    fi
}

echo "== shell coverage"
report linux/hotshot-capture.sh "$FLOOR_CAPTURE"
report linux/install.sh "$FLOOR_INSTALL"
report scripts/bundle.sh "$FLOOR_BUNDLE"
exit "$STATUS"
