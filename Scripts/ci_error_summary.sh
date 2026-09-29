#!/usr/bin/env bash
# CI helper: turn build/test logs into a readable job summary and inline annotations.
#
# Usage: Scripts/ci_error_summary.sh build.log [test.log ...]
# For every log it writes the first 50 distinct lines matching "error:" (compiler errors) or a failed
# swift-testing marker to $GITHUB_STEP_SUMMARY, and emits up to 10 `::error file=...` annotations
# for lines shaped like "path/File.swift:12:5: error: message". Always exits 0.
set -u

MAX=50
MAX_ANNOTATIONS=10
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
WORKSPACE=${GITHUB_WORKSPACE:-$PWD}
PATTERN='error:|✘ '
annotated=0

for log in "$@"; do
  if [[ ! -f $log ]]; then continue; fi
  matches=$(grep -E "$PATTERN" "$log" | awk '!seen[$0]++' || true)
  total=0
  if [[ -n $matches ]]; then total=$(printf '%s\n' "$matches" | wc -l | tr -d ' '); fi
  {
    echo "### Errors in \`$log\`"
    echo
    if [[ $total -eq 0 ]]; then
      echo "No line matching \`error:\` found. Last 30 lines:"
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
