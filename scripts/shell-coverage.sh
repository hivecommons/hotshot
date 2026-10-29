#!/usr/bin/env bash
# Runs the bash test suites under xtrace and enforces a per-script line
# coverage floor on the scripts they exercise.
#
# The suites run their targets under `env -i`, so each harness forwards
# HOTSHOT_COVERAGE_RC as BASH_ENV; the rc enables xtrace into a trace file.
# A line counts as covered when BASH_SOURCE:LINENO appears in the trace.
#
# Floors (percent) are overridable: HOTSHOT_FLOOR_CAPTURE, HOTSHOT_FLOOR_INSTALL,
# HOTSHOT_FLOOR_BUNDLE, HOTSHOT_FLOOR_SMOKE, HOTSHOT_FLOOR_RUNBOOK_EVENTS.
#
# Usage: bash scripts/shell-coverage.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLOOR_CAPTURE="${HOTSHOT_FLOOR_CAPTURE:-95}"
FLOOR_INSTALL="${HOTSHOT_FLOOR_INSTALL:-95}"
FLOOR_BUNDLE="${HOTSHOT_FLOOR_BUNDLE:-95}"
FLOOR_SMOKE="${HOTSHOT_FLOOR_SMOKE:-95}"
FLOOR_RUNBOOK_EVENTS="${HOTSHOT_FLOOR_RUNBOOK_EVENTS:-95}"

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

for suite in linux/tests/hotshot-capture.test.sh linux/tests/install.test.sh scripts/tests/bundle.test.sh scripts/tests/smoke.test.sh scripts/tests/runbook-events.test.sh; do
    echo "== $suite"
    bash "$ROOT/$suite"
done

extract_hits <"$TRACE" >"$WORK/hits"

# Prints the executable line numbers of $1, one per line. Skips what xtrace
# never reports: blanks, comments, bare block keywords, `done` with a loop
# redirect, function-definition lines, and case pattern lines (including
# patterns that quote parentheses, and `pattern) ;;` arms with an empty
# body) — none of these can ever be "covered".
executable_lines() {
    awk '
        heredoc != "" {
            line = $0
            if (heredoc_dash) sub(/^\t+/, "", line)
            if (line == heredoc) heredoc = ""
            next
        }
        /^[[:space:]]*esac/ { in_case = 0 }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*(fi|done|esac|else|then|\}|\{|;;)[[:space:]]*$/ { next }
        /^[[:space:]]*done[[:space:]]*<.*$/ { next }
        /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z_0-9]*[[:space:]]*\(\)[[:space:]]*(\{[[:space:]]*(#.*)?)?$/ { next }
        in_case && /\)[[:space:]]*$/ && !/\$\(/ && !/=\(/ && !/<\(/ && !/^[[:space:]]*\(/ { next }
        in_case && /;;[[:space:]]*$/ && !/\$\(/ && !/=\(/ && !/<\(/ && !/^[[:space:]]*\(/ {
            arm = $0
            sub(/[[:space:]]*;;[[:space:]]*$/, "", arm)
            if (arm ~ /\)$/) next
        }
        /^[[:space:]]*case[[:space:]]/ { in_case = 1 }
        {
            print NR
            if (match($0, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z_0-9]*["\047]?/)) {
                tag = substr($0, RSTART, RLENGTH)
                heredoc_dash = (tag ~ /^<<-/)
                gsub(/<<-?[[:space:]]*["\047]?/, "", tag)
                gsub(/["\047]/, "", tag)
                heredoc = tag
            }
        }
    ' "$1"
}

# Guard the classifier the same way: a rule that over-excludes shrinks the
# denominator and inflates every percentage without failing any suite.
cat >"$WORK/classify.sh" <<'FIXEOF'
#!/usr/bin/env bash
# comment only

x=1
foo() {
    echo "$x"
}
bar() { # trailing comment
    :
}
case "$x" in
    a)
        y=$(printf '%s' "$x")
        ;;
    "b)")
        z=$(true) ;;
    c|d) w=1 ;;
    e) ;;
    *)
        : ;;
esac
cat <<EOF
    not code)
EOF
cat <<-'TAG'
	indented body
	TAG
while read -r line; do
    :
done <"$0"
if [ -n "$x" ]; then
    arr=(a b)
else
    ((n++))
fi
{
    echo grouped
}
FIXEOF
got="$(executable_lines "$WORK/classify.sh" | tr '\n' ' ')"
want='4 6 9 11 13 16 17 20 22 25 28 29 31 32 34 37 '
if [ "$got" != "$want" ]; then
    echo "FAIL shell-coverage self-test: executable_lines gave '$got', want '$want'" >&2
    exit 1
fi

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

# Guard the floor arithmetic: every gated script sits at 100% on main, so CI
# only ever takes the ok branch. Run in a subshell so ROOT/WORK/STATUS can be
# pointed at a fixture without touching the real run.
mkdir -p "$WORK/floor"
printf '%s\n' 'a=1' 'b=2' 'c=3' 'd=4' >"$WORK/floor/four.sh"
printf '%s\n' '#!/usr/bin/env bash' '# nothing runs' >"$WORK/floor/empty.sh"
printf '%s\n' 'four.sh:1' 'four.sh:2' 'four.sh:4' >"$WORK/floor/hits"
got="$(ROOT="$WORK/floor"; WORK="$ROOT"; report four.sh 75; report four.sh 76; report empty.sh 0)"
want="$(printf '%s\n' \
    '  uncovered: four.sh:3' \
    'ok   four.sh: 75% (3/4), floor 75%' \
    '  uncovered: four.sh:3' \
    'FAIL four.sh: 75% (3/4) is below the 76% floor' \
    'FAIL empty.sh: no executable lines found')"
if [ "$got" != "$want" ]; then
    echo "FAIL shell-coverage self-test: report gave:" >&2
    echo "$got" >&2
    exit 1
fi
if (ROOT="$WORK/floor"; WORK="$ROOT"; report four.sh 76 >/dev/null; exit "$STATUS"); then
    echo "FAIL shell-coverage self-test: report did not set STATUS on a floor miss" >&2
    exit 1
fi

echo "== shell coverage"
report linux/hotshot-capture.sh "$FLOOR_CAPTURE"
report linux/install.sh "$FLOOR_INSTALL"
report scripts/bundle.sh "$FLOOR_BUNDLE"
report scripts/smoke.sh "$FLOOR_SMOKE"
report scripts/runbook-events.sh "$FLOOR_RUNBOOK_EVENTS"
exit "$STATUS"
