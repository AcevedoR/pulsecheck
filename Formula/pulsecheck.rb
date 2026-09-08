# Homebrew formula.
#
#   brew install --HEAD https://raw.githubusercontent.com/AcevedoR/pulsecheck/main/Formula/pulsecheck.rb
#
# HEAD-only for now: a stable url/sha256 block wants a tagged release, and
# there is not one yet. Adding a tap repo (homebrew-pulsecheck) would make it
# `brew install AcevedoR/pulsecheck/pulsecheck`.
class Pulsecheck < Formula
  desc "Watch an HTTP endpoint's pulse: live latency with a rolling p95 and error rate"
  homepage "https://github.com/AcevedoR/pulsecheck"
  head "https://github.com/AcevedoR/pulsecheck.git", branch: "main"
  license "MIT"

  # curl and awk are on every macOS and every Linux Homebrew supports; the
  # script is written against BWK awk and bash 3.2 precisely so it needs
  # nothing installed alongside it.

  def install
    bin.install "pulsecheck"
  end

  test do
    assert_match "pulsecheck", shell_output("#{bin}/pulsecheck --version")
    # A run against a closed port: every request fails, so the error gate must
    # trip, which exercises the sampler, the stats and the exit status at once.
    system "#{bin}/pulsecheck", "-p", "-c", "2", "-i", "0.05", "-t", "1",
           "http://127.0.0.1:1/"
  end
end
