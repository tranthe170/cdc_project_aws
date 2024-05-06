import sys

from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession
from pyspark.sql.functions import when
from pyspark.sql.types import (StringType, StructField, StructType,
                               TimestampType)

# Get arguments
args = getResolvedOptions(sys.argv,['s3_target_path_key','s3_target_path_bucket'])
bucket = args['s3_target_path_bucket']
fileName = args['s3_target_path_key']

print(bucket, fileName)

# Start Spark session
spark = SparkSession.builder.appName("CDC").getOrCreate()

# Define file paths
inputFilePath = f"s3a://{bucket}/{fileName}"
finalFilePath = f"s3a://{bucket}/output"

# Define the schema
schema = StructType([
    StructField("Op", StringType()),
    StructField("tx_commit_time", TimestampType()),
    StructField("PersonID", StringType()),
    StructField("FullName", StringType()),
    StructField("City", StringType())
])

schema_without_op = StructType([
    StructField("tx_commit_time", TimestampType()),
    StructField("PersonID", StringType()),
    StructField("FullName", StringType()),
    StructField("City", StringType())
])

if "LOAD" in fileName:
    fldf = spark.read.schema(schema_without_op).csv(inputFilePath)
    fldf.write.mode("overwrite").csv(finalFilePath)
else:
    udf = spark.read.schema(schema).csv(inputFilePath)
    ffdf = spark.read.schema(schema_without_op).csv(finalFilePath)

    for row in udf.collect():
        op = row["Op"]
        if op == 'U':
            ffdf = ffdf.withColumn("FullName", when(ffdf["PersonID"] == row["PersonID"], row["FullName"]).otherwise(ffdf["FullName"]))
            ffdf = ffdf.withColumn("City", when(ffdf["PersonID"] == row["PersonID"], row["City"]).otherwise(ffdf["City"]))
        
        elif op == 'I':
            insertedRow = [list(row)[1:]]
            columns = ['tx_commit_time','PersonID', 'FullName', 'City']
            newdf = spark.createDataFrame(insertedRow, columns)
            ffdf = ffdf.union(newdf)
        
        elif op == 'D':
            ffdf = ffdf.filter(ffdf.PersonID != row["PersonID"])

    ffdf.coalesce(1).write.mode("overwrite").csv(finalFilePath)
