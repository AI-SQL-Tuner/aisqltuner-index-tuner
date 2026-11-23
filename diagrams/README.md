# Diagrams

Four diagrams of how aisqltuner-index-tuner works, for the README, blog posts and social media.
Each comes as an SVG (sharp at any size, editable in a text editor) and a 3200 x 1800 PNG
(16:9, ready to upload to LinkedIn, X or a slide deck).

| Diagram | Shows | Files |
|---|---|---|
| **Architecture** | What lives where: the stored procedures and tables inside your database, the diagnostic sources they read, and the one outside service they call | [SVG](architecture.svg), [PNG](architecture.png) |
| **Data flow** | How data moves through the five steps, from collection to a verified index with an undo script, and where `RECOMMEND` stops and `CREATE` continues | [SVG](data-flow.svg), [PNG](data-flow.png) |
| **Data model** | The three `AIIndexTuner` tables, their columns by purpose, the foreign key from `Recommendation` to `Run`, and the extended property that tags the indexes the tool creates | [SVG](data-model.svg), [PNG](data-model.png) |
| **Recommendation types** | The nine recommendation categories, and which can be applied automatically, which only when you allow it, and which always stay for review. Shows that the output covers more than new indexes | [SVG](recommendation-types.svg), [PNG](recommendation-types.png) |

![Architecture](architecture.png)

![Data flow](data-flow.png)

![Data model](data-model.png)

![Recommendation types](recommendation-types.png)

## Benchmark charts

Four charts of the results in [BENCHMARK.md](../BENCHMARK.md). They are generated, not hand-drawn:
[benchmark-charts.py](benchmark-charts.py) holds the numbers and writes the SVGs. When a result
changes, edit the numbers there, run it, and re-render the PNGs as below.

```powershell
python diagrams/benchmark-charts.py
```

| Chart | Shows | Files |
|---|---|---|
| **Rubric** | Part 1 scores by batch | [SVG](benchmark-rubric.svg), [PNG](benchmark-rubric.png) |
| **Reads** | Logical-read reduction for each arm and workload | [SVG](benchmark-reads.svg), [PNG](benchmark-reads.png) |
| **Time** | Total execution time reduction, with each workload's noise floor | [SVG](benchmark-time.svg), [PNG](benchmark-time.png) |
| **Space** | Index space added and the read reduction it bought, on the challenge workload | [SVG](benchmark-space.svg), [PNG](benchmark-space.png) |

## Re-rendering the PNGs

Edit the SVG, then render it with headless Chrome or Edge. The size is 1600 x 900 at 2x
(`benchmark-space` is 1600 x 760 and `benchmark-rubric` 1600 x 1056: set `--window-size` to match):

```powershell
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
foreach ($name in 'architecture', 'data-flow', 'data-model', 'recommendation-types') {
    Start-Process $chrome -Wait -ArgumentList @(
        '--headless=new', '--hide-scrollbars', '--force-device-scale-factor=2', '--window-size=1600,900',
        "--screenshot=$PWD\$name.png", "file:///$("$PWD\$name.svg" -replace '\\', '/')")
}
```

The SVGs use the Segoe UI and Consolas fonts, with generic fallbacks, so the PNGs are the safest
format for posting. Keep the numbers in the diagrams in step with the [README](../README.md) and
[BENCHMARK.md](../BENCHMARK.md): the architecture diagram's `-86%` is the CREATE-mode logical-read
reduction on `tpch10-realistic`.
