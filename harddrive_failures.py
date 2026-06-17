from pyspark.sql import functions as F
from pyspark.sql.types import (
    StructType, StructField,
    StringType, LongType, IntegerType, BooleanType, DateType
)

raw_path = "s3://confessions-of-a-data-guy/harddrive/"
delta_path_fail = "s3://confessions-of-a-data-guy/delta/failing_models"
delta_path_top = "s3://confessions-of-a-data-guy/delta/top_failing_models"

schema = (
    StructType()
    .add("date", StringType(), True)
    .add("serial_number", StringType(), True)
    .add("model", StringType(), True)
    .add("capacity_bytes", LongType(), True)
    .add("failure", IntegerType(), True)
    .add("datacenter", StringType(), True)
    .add("cluster_id", IntegerType(), True)
    .add("vault_id", IntegerType(), True)
    .add("pod_id", IntegerType(), True)
    .add("pod_slot_num", IntegerType(), True)
    .add("is_legacy_format", BooleanType(), True)
)

raw_df = (
    spark.read
    .option("header", "true")
    .option("recursiveFileLookup", "true")
    .option("mode", "PERMISSIVE")
    .option("columnNameOfCorruptRecord", "_corrupt_record")
    .schema(schema)
    .csv(raw_path)
)

harddrives = (
    raw_df
    .select(
        F.to_date("date").alias("event_date"),
        "serial_number",
        "model",
        "capacity_bytes",
        "failure",
        "datacenter",
        "cluster_id",
        "vault_id",
        "pod_id",
        "pod_slot_num"
    )
    .where(F.col("event_date").isNotNull())
    .where(F.col("model").isNotNull())
)

harddrives.cache()

failures_by_day_model = (
    harddrives
    .groupBy("event_date", "model")
    .agg(
        F.count("*").alias("drive_observations"),
        F.sum(F.when(F.col("failure") == 1, 1).otherwise(0)).alias("failures"),
        F.countDistinct("serial_number").alias("distinct_drives"),
        F.round(
            F.sum(F.when(F.col("failure") == 1, 1).otherwise(0)) / F.count("*"),
            6
        ).alias("daily_failure_rate")
    )
    .orderBy(F.desc("failures"), "event_date", "model")
)


top_failing_models = (
    harddrives
    .groupBy("model")
    .agg(
        F.count("*").alias("drive_observations"),
        F.countDistinct("serial_number").alias("distinct_drives"),
        F.sum(F.when(F.col("failure") == 1, 1).otherwise(0)).alias("failures"),
        F.min("event_date").alias("first_seen"),
        F.max("event_date").alias("last_seen"),
        F.round(
            F.sum(F.when(F.col("failure") == 1, 1).otherwise(0)) / F.count("*"),
            6
        ).alias("failure_rate")
    )
    .orderBy(F.desc("failures"))
)

failures_by_day_model.write.mode("overwrite").save(delta_path_fail)
top_failing_models.write.mode("overwrite").save(delta_path_top)
