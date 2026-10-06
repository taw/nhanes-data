# NHANES / NHES data in usable form

Public data from the US National Health Examination Surveys and National
Health and Nutrition Examination Surveys, 1959–2023, converted from CDC's
fixed-width tapes and SAS transport files into JSONL.

| Survey  | Years   | Ages      | Examined |
|---------|---------|-----------|----------|
| NHES I  | 1959–62 | 18–79     | 6,672    |
| NHES II | 1963–65 | 6–11      | 7,119    |
| NHES III| 1966–70 | 12–17     | 6,768    |
| NHANES I| 1971–75 | 1–74      | 23,808   |
| NHANES II| 1976–80| 6 mo–74   | 20,322   |
| NHANES III| 1988–94| 2 mo+    | 31,311   |

Continuous NHANES (1999–2023, two-year cycles, ~10,000 examined each) is
included only for selected files, so far `DEMO` (demographics, sample weights)
and `BMX` (body measures). Every cycle is in `data/nhanes_<years>`, e.g.
`data/nhanes_2015_2016`. 2017–2018 is covered by the merged 2017–March 2020
pre-pandemic files (`nhanes_2017_2020`), not separately.

## Scripts

```
bin/fetch_nhes_data      [--force] [nhes1 nhes2 nhes3]        # -> raw_data/nhesN
bin/fetch_nhanes_data    [--force] [nhanes1 nhanes2 nhanes3]  # -> raw_data/nhanesN
bin/convert_nhes_data    [nhes1 nhes2 nhes3]                  # raw_data -> data
bin/convert_nhanes_data  [nhanes1 nhanes2 nhanes3]            # raw_data -> data
bin/fetch_continuous_nhanes   [--force] [--files=DEMO,BMX] [nhanes_1999_2000 ...]
bin/convert_continuous_nhanes [nhanes_1999_2000 ...]
bin/analyze_bmi          [survey ...]                         # example: mean BMI by sex and age
bin/analyze_height       [survey ...]                         # example: mean height (cm) by sex and age
```

Fetchers scrape each survey's CDC page and download every linked data file,
SAS layout and PDF codebook (~1.8 GB). The continuous NHANES fetcher only
gets files whose name stem is given in `--files` (`BMX` for `BMX_I.xpt`), plus
`DEMO`, and their HTML codebooks. `raw_data/` is not committed.
Converting needs Ruby and the `zstd` CLI.

## Output format

Every survey directory `data/<survey>/` has the same three kinds of files:

- `<dataset>.jsonl.zst` — one JSON object per record. Keys are the original
  variable names, numeric fields are numbers, blank/missing fields are `null`.
- `variables.jsonl` — one line per variable: `dataset`, `name`, `label`,
  `type` (`numeric`/`character`), and where available `start`/`end` (column
  positions in the fixed-width source) and `values` (code labels, NHANES I/II only).
- `datasets.jsonl` — one line per dataset: `title`, `records`, `variables`,
  source files.

Reading it:

```sh
zstdcat data/nhes1/DU1003.jsonl.zst | head -1
duckdb -c "select * from read_json('data/nhanes2/DU5301.jsonl.zst') limit 5"
```
```python
pd.read_json("data/nhanes3/exam.jsonl.zst", lines=True)   # needs the zstandard package
pl.read_ndjson("data/nhanes3/exam.jsonl.zst")
```
```ruby
require "json"
IO.popen(["zstdcat", "data/nhes1/DU1003.jsonl.zst"]) do |io|
  io.each_line do |line|
    row = JSON.parse(line)
    p row.values_at("SEQN", "H1BM0013", "H1BM0016")   # id, height, weight
  end
end
```

## Caveats

- **Values are exactly as stored on the tapes.** Implied decimals and units are
  documented only in the PDF codebooks (`raw_data/<survey>/*.pdf`) and are not
  applied: NHES I height `681` means 68.1 inches, weight `1485` means 148.5 lb.
- **Special codes are not turned into nulls.** Codes such as 999 for "not
  recorded" are left as numbers; see the codebooks.
- **SAS labels from CDC contain errors.** E.g. NHES I `H1BM0013` is labeled
  "HEIGHT/(WEIGHT)1/3" but is height. Check labels against the PDF before use.
- Continuous NHANES dataset names drop the cycle suffix (`BMX_I` → `BMX`).
  Age, sex and sample weights are only in `DEMO`; join other files on `SEQN`.
  The exam weight is `WTMEC2YR`, except `WTMECPRP` in `nhanes_2017_2020`.
- NHES has no machine-readable code labels; NHANES I/II do (`values`).
- NHES I `DU1007` (diabetes) has undocumented data in columns 72–80, not converted.
- `growthch` (CDC growth chart data: children's height/weight/BMI from NHES II,
  NHES III, NHANES I, II, III) is linked from each survey's page and appears in
  each of those directories.
- Not converted: NHANES II `DU5704` (24-hour recall food items, no SAS layout
  published), NHANES III HCV RNA sequences (`39a/*.csv`, already CSV) and raw
  spirometry curves (`9a/nh3spiro.zip`), and the NHANES II/III X-ray image archives.
