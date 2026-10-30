# Turns the Actor's dataset items into counts and a Markdown job summary.
# Input (.): array of dataset items {url, status, finalUrl, redirects, redirectStatuses, flags, lastmod, sitemap}
# Args: $failon (comma-separated flags), $run (Apify run ID), $summary (slurped SUMMARY record)
def esc: tostring | gsub("[\r\n]"; " ") | gsub("\\|"; "\\|");
def flagsof: (.flags // []);
def isproblem: (flagsof | any(.[]; . == "ok")) | not;

($failon | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $f
| ($summary[0] // {}) as $s
| ($s | if type == "object" then . else {} end) as $s
| map(. + { _fail: (flagsof | any(.[]; . as $x | $f | any(.[]; . == $x))) }) as $items
| ($items | map(select(._fail))) as $failing
| ($items | map(select(isproblem)) | sort_by(if ._fail then 0 else 1 end)) as $rows
| ($s.checked // ($items | length)) as $checked
| ($s.problems // ($rows | length)) as $problems
| {
    checked: $checked,
    problems: $problems,
    failing: ($failing | length),
    failingRows: ($failing | map(del(._fail))),
    markdown: (
      "## Sitemap URL Health Check\n\n"
      + "| URLs checked | With problems | Matching fail-on | Billed URL checks |\n"
      + "|---:|---:|---:|---:|\n"
      + "| \($checked) | \($problems) | \($failing | length) | \($s.billed // "n/a") |\n\n"
      + "Fail-on flags: `\(if ($f | length) > 0 then ($f | join(", ")) else "(none)" end)`. Apify run: `\($run)`.\n\n"
      + (if ($rows | length) == 0 then "No problem URLs were returned.\n"
         else
           "| | URL | Status | Flags | Final URL |\n|---|---|---:|---|---|\n"
           + ($rows[:100] | map(
               "| \(if ._fail then "FAIL" else "" end) | \(.url | esc) | \(.status // "-" | esc) | \(flagsof | join(", ") | esc) | \(.finalUrl // "" | esc) |"
             ) | join("\n")) + "\n"
           + (if ($rows | length) > 100 then "\n...and \(($rows | length) - 100) more problem URLs in the Apify run's dataset.\n" else "" end)
         end)
      + (if ($s.blockedByRobots // 0) > 0 then "\n\($s.blockedByRobots) URL(s) were skipped because robots.txt disallows them (not billed).\n" else "" end)
      + (if $s.note then "\nNote: \($s.note | esc)\n" else "" end)
    )
  }
