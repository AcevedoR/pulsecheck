# Pull one awk function out of the pulsecheck source so it can be unit tested
# in isolation.
#
# The functions under test (pct, wscale, fmt, ...) live inside the single big
# awk program embedded in the script. Running that whole program to reach them
# would drag in the BEGIN block, the terminal and the ring buffer; extracting
# the function text lets a driver call it with chosen inputs instead.
#
# usage: awk -v fn=NAME -f tests/extract.awk pulsecheck
BEGIN { want = "function " fn "(" }
!inside && index($0, want) == 1 { inside = 1 }
inside {
  print
  # Brace counting is enough here: the source has no braces inside strings or
  # regexes within these functions. It is checked by the exit status below.
  n = gsub(/{/, "{"); depth += n
  n = gsub(/}/, "}"); depth -= n
  if (depth == 0) { found = 1; exit }
}
END { if (!found) { print "extract.awk: function not found: " fn > "/dev/stderr"; exit 1 } }
