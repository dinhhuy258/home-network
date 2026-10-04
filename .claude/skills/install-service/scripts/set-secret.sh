#!/usr/bin/env bash
# Replace a placeholder in a config file with a secret typed at the terminal.
# The secret is read with echo off, handed to perl through the environment
# (never on a command line, never in the shell history) and written in place.
# The only output on success is one line: "replaced N occurrence(s) in <file>".
#
# Usage: set-secret.sh <file> <placeholder> [--urlencode]
#   --urlencode  percent-encode the secret (RFC 3986 unreserved characters kept)
#                for use inside a URL or DSN such as postgres://user:PASS@host/db
set -euo pipefail

usage="usage: set-secret.sh <file> <placeholder> [--urlencode]"
file=${1:?$usage}
placeholder=${2:?$usage}
encode=0
case ${3:-} in
  "") ;;
  --urlencode) encode=1 ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

[[ -f $file ]] || { echo "no such file: $file" >&2; exit 1; }
[[ -t 0 ]] || { echo "stdin is not a terminal; run this from the pane, never through a pipe" >&2; exit 1; }

count=$(grep -o -F -- "$placeholder" "$file" | wc -l | tr -d ' ')
(( count > 0 )) || { echo "placeholder $placeholder not found in $file" >&2; exit 1; }

# Echo off for the whole prompt sequence, restored on any exit. read -s does the same,
# but only while it runs; this closes the gap between the two prompts.
tty_state=$(stty -g 2>/dev/null || true)
trap '[[ -n $tty_state ]] && stty "$tty_state" 2>/dev/null' EXIT
stty -echo 2>/dev/null || true

read -rsp "Secret for $placeholder (input hidden): " secret
echo
[[ -n $secret ]] || { echo "empty input, nothing changed" >&2; exit 1; }
read -rsp "Repeat it: " secret2
echo
[[ $secret == "$secret2" ]] || { echo "the two inputs differ, nothing changed" >&2; exit 1; }
unset secret2

# The pattern is quoted, so the placeholder is matched literally. The replacement
# is a plain interpolated string, so backslashes and dollars in the secret stay literal.
SECRET=$secret PLACEHOLDER=$placeholder ENCODE=$encode perl -pi -e '
  BEGIN {
    $s = $ENV{SECRET};
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge if $ENV{ENCODE};
    $p = quotemeta($ENV{PLACEHOLDER});
  }
  s/$p/$s/g;
' -- "$file"
unset secret

left=$(grep -c -F -- "$placeholder" "$file" || true)
(( left == 0 )) || { echo "placeholder still present in $file" >&2; exit 1; }
echo "replaced $count occurrence(s) in $file"
