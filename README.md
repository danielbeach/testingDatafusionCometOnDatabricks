# Apache DataFusion Comet on Databricks — Benchmark

## Purpose

This repo tests running **Apache DataFusion Comet** on **Databricks Spark** to see
how it performs compared to **normal (vanilla) Spark**.

[Apache DataFusion Comet](https://datafusion.apache.org/comet/) is a Spark
accelerator plugin. It swaps in a native, vectorized execution engine (built on
the Rust [Apache DataFusion](https://datafusion.apache.org/) query engine) for
supported Spark physical operators and expressions, while leaving the Spark
DataFrame / SQL API unchanged. The goal is faster execution and lower cost on the
same code — no rewrites.

The benchmark workload here runs the **exact same PySpark job twice** — once on
stock Spark, once with Comet enabled — and we compare runtime, cost, and output
correctness.

## The Workload — `harddrive_failures.py`

The job reads the [Backblaze hard drive failure dataset](https://www.backblaze.com/cloud-storage/resources/hard-drive-test-data)
(CSV) from S3 and computes two aggregate tables, written back as Delta:

| Output | Path | Grain |
|--------|------|-------|
| `failures_by_day_model` | `s3://confessions-of-a-data-guy/delta/failing_models` | per `event_date` + `model` |
| `top_failing_models` | `s3://confessions-of-a-data-guy/delta/top_failing_models` | per `model` |

Each output carries drive observation counts, distinct drive counts, failure
counts, and computed failure rates. The job exercises common, Comet-accelerable
operators: CSV scan, projection, filter, `groupBy` aggregation, `countDistinct`,
and sort — a representative read-heavy ETL pattern.

## Running the comparison

### 1. Baseline — vanilla Spark
Run the job on a standard Databricks cluster with no extra config.

### 2. With Comet
Run the **same** job on a cluster configured with the Comet plugin. Typical Spark
config:

```
spark.plugins                                org.apache.spark.CometPlugin
spark.comet.enabled                          true
spark.comet.exec.enabled                     true
spark.comet.exec.shuffle.enabled             true
spark.shuffle.manager                        org.apache.spark.sql.comet.execution.shuffle.CometShuffleManager
spark.sql.extensions                         org.apache.comet.CometSparkSessionExtensions
```

> Comet versions must match your Databricks Runtime's Spark/Scala version. Check
> the Comet release notes for the supported DBR before installing the jar.

### 3. Compare
For each run capture:
- **Wall-clock runtime** of the job
- **Compute cost** (DBUs / cluster time)
- **Output equivalence** — both runs must produce identical aggregate results
- (optional) Comet operator coverage from the Spark UI — how much of the plan
  Comet actually accelerated vs. fell back to vanilla Spark

## Notes
- `harddrives.cache()` is used so both aggregations share one scan; this affects
  how much of the plan Comet sees. Worth testing with and without cache.
- Operators Comet does not support fall back to Spark automatically, so a partial
  speedup is expected even when not the whole plan is accelerated.
