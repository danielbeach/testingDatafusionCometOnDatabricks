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

## Building the Comet JAR

> **Why build at all?** Comet publishes pre-built jars on Maven
> (`comet-spark-spark4.0_2.13-x.y.z.jar`). They do **not** reliably run on
> Databricks — Databricks ships a proprietary fork of Apache Spark, and the
> upstream Comet docs warn that "Comet may not fully work with proprietary forks
> of Apache Spark such as the Spark versions offered by Cloud Service Providers."
> In practice the Maven jar fails on DBR, so we build from source against the
> Spark 4.0 / Scala 2.13 / JDK 17 profile.

Building natively on an Apple-silicon (arm64) Mac fails. The build is done inside
a `linux/amd64` Docker container instead. Three files at the repo root drive it:

| File | Role |
|------|------|
| `Dockerfile` | Ubuntu 22.04 + JDK 17, Maven, Rust, `protoc` 25.3 — the full Comet toolchain |
| `build-comet.sh` | Sets up the JNI/JVM env, clones `apache/datafusion-comet`, runs `make release` |
| `docker-compose.yml` | Builds the image and mounts `./output` so the jars land on the host |

### Build commands

```bash
# from the repo root (the dir holding Dockerfile / docker-compose.yml)
docker compose build          # build the toolchain image (one time)
docker compose up             # run build-comet.sh — clones Comet and compiles
```

The compile takes **1–2 hours**. Under the hood `build-comet.sh` runs:

```bash
PROFILES="-Pspark-4.0 -Pscala-2.13 -Pjdk17" make release
```

To pin a released version instead of `main`, uncomment the checkout line in
`build-comet.sh` (e.g. `git checkout 0.16.0`) before running.

### Which jar you actually need

When the build finishes, jars land in `./output/`. **Use the `comet-spark` jar —
not `comet-common`.**

| Jar | Size | Contents |
|-----|------|----------|
| `comet-spark-spark4.0_2.13-<ver>.jar` | ~47 MB | ✅ `CometPlugin`, `CometShuffleManager`, **and** the bundled native lib (`libcomet.so`) |
| `comet-common-spark4.0_2.13-<ver>.jar` | ~9 KB | ❌ no plugin classes, no native lib |

`comet-spark` is the assembled/shaded jar — it's the only one you upload.
Pointing Spark at `comet-common` is the cause of the "class Spark expects for
Comet is not in that jar" error.

## Deploying to Databricks

### 1. Upload the jar to a Volume
Put the `comet-spark` jar somewhere clusters can read it, e.g. a UC Volume:

```
/Volumes/confessions/default/jars/comet-spark-spark4.0_2.13-0.17.0-SNAPSHOT.jar
```

### 2. Init script — copy the jar onto the cluster
Comet must be on the cluster's jar path before Spark starts. Save this as
`install-comet.sh` in the same Volume:

```bash
#!/bin/bash
COMET_JAR="/Volumes/confessions/default/jars/comet-spark-spark4.0_2.13-0.17.0-SNAPSHOT.jar"
LOCAL_JAR="/databricks/jars/comet-spark-spark4.0_2.13-0.17.0-SNAPSHOT.jar"

cp "$COMET_JAR" "$LOCAL_JAR"
chmod 644 "$LOCAL_JAR"
```

### 3. Allowlist the files
Unity Catalog blocks init scripts and jars from Volumes by default. Add **both**
the jar and `install-comet.sh` to the workspace/catalog **allowlist**, or the
cluster won't start.

### 4. Use a Dedicated (single-user) cluster
`--jars` / AddJar usage is rejected on shared-access clusters. The cluster must
be **Dedicated (single user)** access mode.

### 5. Cluster Spark config
Attach `install-comet.sh` as the init script, then set:

```
spark.plugins                                org.apache.spark.CometPlugin
spark.comet.enabled                          true
spark.comet.exec.enabled                     true
spark.comet.exec.shuffle.enabled             true
spark.shuffle.manager                        org.apache.spark.sql.comet.execution.shuffle.CometShuffleManager
spark.sql.extensions                         org.apache.comet.CometSparkSessionExtensions
spark.comet.explainFallback.enabled          true
```

> `spark.comet.explainFallback.enabled=true` logs why operators fall back to
> vanilla Spark — useful for seeing how much of the plan Comet actually took.

> **Known compatibility wall.** Even with the right jar and configs, the Comet
> `CometShuffleManager` can collide with DBR's forked Spark `ShuffleManager`
> interface, throwing at shuffle time:
> ```
> java.lang.AbstractMethodError: Receiver class
> org.apache.spark.sql.comet.execution.shuffle.CometShuffleManager does not
> define or inherit an implementation of the resolved method 'getReader(...)'
> of interface org.apache.spark.shuffle.ShuffleManager
> ```
> This is the DBR-fork mismatch the upstream warning refers to: Comet's shuffle
> manager is compiled against Apache Spark's `ShuffleManager` signature, which
> DBR has changed. If you hit it, drop the `spark.shuffle.manager` /
> `spark.comet.exec.shuffle.enabled` lines to fall back to Spark shuffle, and
> match the Comet build to the exact Spark version inside your DBR.

## Running the comparison

### 1. Baseline — vanilla Spark
Run the job on a standard Databricks cluster with **none** of the Comet config above.

### 2. With Comet
Run the **same** job on the Comet-configured cluster (jar + init script + Spark
config from the Deploying section).

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
