## Validator Follow-ups
- [ ] Tighten `is_raw_html_start`'s V5 check to CommonMark's actual HTML-block conditions
    > **Context:** `tmval.lua`'s raw-HTML detection is still marginally wider than CommonMark: a line like `<foo bar` at column 0 is a paragraph under CommonMark but trips V5 here.
    > **Requirements:** Only worth doing if a false positive actually shows up in practice -- flagged as a known gap, not a bug with a confirmed impact.
