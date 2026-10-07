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

# Reads trace lines on stdin and prints unique "<basename>:<line>" pairs.
# bundle.test.sh runs a copy of bundle.sh from a temp project, so match on
# basename (line numbers are unchanged). The path class excludes ':' so the
# match cannot swallow the command text: a traced no-op `:` yields
# "+COV f.sh:38::", which a greedy "[^ ]*" turns into the hit "f.sh:38:".
# xtrace repeats the leading '+' once per nesting level (function bodies,
# subshells), so any run of them is accepted.
extract_hits() {
    sed -nE 's/^\++COV ([^ :]*):([0-9]+):.*/\1:\2/p' \
        | sed -e 's|.*/||' \
        | sort -u
}

# Guard the extraction itself: a bug here reports the wrong lines as
# uncovered without failing any suite.
got="$(printf '%s\n' \
    '+COV /r/linux/install.sh:38::' \
    '+COV /r/linux/install.sh:39:echo NOTE: not on PATH' \
    '++COV /r/linux/hotshot-capture.sh:160:local queue' \
    '+COV /r/scripts/bundle.sh:12:x=a:1:' \
    '+COV /r/scripts/bundle.sh:12:x=a:1:' \
    'not a trace line' \
    | extract_hits | tr '\n' ' ')"
want='bundle.sh:12 hotshot-capture.sh:160 install.sh:38 install.sh:39 '
if [ "$got" != "$want" ]; then
    echo "FAIL shell-coverage self-test: extract_hits gave '$got', want '$want'" >&2
    exit 1
fi

for suite in linux/tests/hotshot-capture.test.sh linux/tests/install.test.sh scripts/tests/bundle.test.sh; do
    echo "== $suite"
    bash "$ROOT/$suite"
done

extract_hits <"$TRACE" >"$WORK/hits"

# Prints the executable line numbers of $1, one per line. Skips what xtrace
# never reports: blanks, comments, bare block keywords, `done` with a loop
# redirect, function-definition lines, and case pattern lines (including
# patterns that quote parentheses) — none of these can ever be "covered".
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
        /^[[:space:]]*done[[:space:]]*<.*$/ { next }
        /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z_0-9]*[[:space:]]*\(\)[[:space:]]*(\{[[:space:]]*(#.*)?)?$/ { next }
        in_case && /\)[[:space:]]*$/ && !/\$\(/ && !/=\(/ && !/<\(/ && !/^[[:space:]]*\(/ { next }
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
