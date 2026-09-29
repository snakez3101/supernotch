#!/usr/bin/env bash
# CI helper: turn build/test logs into a readable job summary and inline annotations.
#
# Usage: Scripts/ci_error_summary.sh build.log [test.log ...]
# For every log it writes the first 50 distinct lines matching "error:" (compiler errors), a failed
# swift-testing marker (✘) or a crash (a process killed by a signal, a Swift runtime trap) to
# $GITHUB_STEP_SUMMARY, and emits up to 10 `::error file=...` annotations for lines shaped like
# "path/File.swift:12:5: error: message". When the test process itself died, it also lists the tests that had
# started but never finished (the crash happened in one of them, or in code running beside them).
# Always exits 0.
set -u

MAX=50
MAX_ANNOTATIONS=10
MAX_UNFINISHED=60
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
WORKSPACE=${GITHUB_WORKSPACE:-$PWD}
CRASH_PATTERN='unexpected signal|signal code|Segmentation fault|Bus error|Illegal instruction|Trace/BPT trap|Abort trap|Killed: 9|SIG(BUS|SEGV|ABRT|ILL|TRAP|KILL)'
PATTERN="error:|✘ |$CRASH_PATTERN"
annotated=0

# swift-testing names of tests that printed "◇ Test X started." but no "✔/✘/➜ Test X passed/failed/skipped".
unfinished_tests() {
  awk '
    /^◇ Test case passing / { next }
    /^◇ Test .* started\.$/ {
      name = $0; sub(/^◇ Test /, "", name); sub(/ started\.$/, "", name)
      if (!(name in started)) { order[++count] = name }
      started[name] = 1
      next
    }
    /^(✔|✘|➜|↷) Test / {
      name = $0; sub(/^[^ ]+ Test /, "", name)
      sub(/ (with [0-9]+ test cases? )?(passed|failed|skipped).*$/, "", name)
      finished[name] = 1
    }
    END { for (i = 1; i <= count; i++) if (!(order[i] in finished)) print order[i] }
  ' "$1"
}

for log in "$@"; do
  if [[ ! -f $log ]]; then continue; fi
  matches=$(grep -E "$PATTERN" "$log" | awk '!seen[$0]++' || true)
  total=0
  if [[ -n $matches ]]; then total=$(printf '%s\n' "$matches" | wc -l | tr -d ' '); fi
  {
    echo "### Errors in \`$log\`"
    echo
    if [[ $total -eq 0 ]]; then
      echo "No error, failed test or crash line found. Last 30 lines:"
      echo
      echo '~~~text'
      tail -n 30 "$log"
      echo '~~~'
    else
      shown=$MAX
      if [[ $total -lt $MAX ]]; then shown=$total; fi
      echo "First $shown of $total distinct lines:"
      echo
      echo '~~~text'
      printf '%s\n' "$matches" | head -n "$MAX" | sed "s#$WORKSPACE/##g"
      echo '~~~'
    fi
    echo
    signal_line=$(grep -E -m 1 'unexpected signal|signal code' "$log" || true)
    if [[ -n $signal_line ]]; then
      code=$(printf '%s\n' "$signal_line" | sed -nE 's/.*signal code ([0-9]+).*/\1/p')
      name=""
      if [[ -n $code ]]; then name=$(kill -l "$code" 2>/dev/null || true); fi
      unfinished=$(unfinished_tests "$log")
      count=0
      if [[ -n $unfinished ]]; then count=$(printf '%s\n' "$unfinished" | wc -l | tr -d ' '); fi
      echo "#### The test process crashed${code:+ with signal $code}${name:+ (SIG$name)}"
      echo
      echo "SIGBUS/SIGSEGV on a macOS worker thread is often a stack overflow: those threads have 512 KB of stack"
      echo "(Linux: 8 MB), so deep recursion that passes on Linux can crash on macOS."
      echo
      if [[ $count -gt 0 ]]; then
        echo "$count test(s) had started but never finished:"
        echo
        echo '~~~text'
        printf '%s\n' "$unfinished" | head -n "$MAX_UNFINISHED"
        echo '~~~'
      else
        echo "No unfinished swift-testing test found in \`$log\`."
      fi
      echo
    fi
  } >>"$SUMMARY"

  re='^(.+):([0-9]+):([0-9]+): error: (.*)$'
  while IFS= read -r line; do
    if [[ $annotated -ge $MAX_ANNOTATIONS ]]; then break; fi
    if [[ $line =~ $re ]]; then
      file=${BASH_REMATCH[1]#"$WORKSPACE"/}
      msg=${BASH_REMATCH[4]}
      msg=${msg//'%'/%25}
      echo "::error file=$file,line=${BASH_REMATCH[2]},col=${BASH_REMATCH[3]}::$msg"
      annotated=$((annotated + 1))
    fi
  done < <(printf '%s\n' "$matches")
done
exit 0
