#!/bin/sh
# make_filelist.sh ROOT... -- print the absolute paths of the Erlang source
# files under ROOT (src/ directories only; test/ and examples/ excluded),
# one per line, sorted (test-run copies in make_test_dir/ and *_SUITE_data/
# are skipped). For an OTP tree: make_filelist.sh $ERL_TOP/lib $ERL_TOP/erts
set -eu
for root in "$@"; do
  root=$(cd "$root" && pwd)
  find "$root" -name '*.erl' -path '*/src/*' -not -path '*/test/*' -not -path '*/examples/*' \
       -not -path '*/make_test_dir/*' -not -path '*_SUITE_data/*'
done | sort
