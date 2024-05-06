provider "aws" {
  region = "us-west-2"
}

# Create RDS
resource "aws_db_parameter_group" "rds-pg" {
  name   = "rds-pg"
  family = "mysql8.0"

  parameter {
    name  = "binlog_format"
    value = "ROW"
  }

  tags = {
    Name = "rdspg-cdc-project"
  }
}

resource "aws_db_instance" "cdc_db_instance" {
  allocated_storage    = 20
  storage_type         = "gp2"
  db_name              = "cdc_db"
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro"
  username             = var.username
  password             = var.password
  parameter_group_name = aws_db_parameter_group.rds-pg.name
  publicly_accessible = true
  skip_final_snapshot  = true
  backup_retention_period = 7 
}

# Create S3 bucket
resource "aws_s3_bucket" "s3_bucket_demo" {
  bucket_prefix = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "s3_bucket_ownership_controls" {
  bucket = aws_s3_bucket.s3_bucket_demo.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "s3_bucket_public_access_block" {
  bucket = aws_s3_bucket.s3_bucket_demo.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_acl" "s3_bucket_acl" {
  bucket = aws_s3_bucket.s3_bucket_demo.id
  acl    = "public-read-write"

  depends_on = [
    aws_s3_bucket_ownership_controls.s3_bucket_ownership_controls,
    aws_s3_bucket_public_access_block.s3_bucket_public_access_block
  ]
}

# Create DMS source endpoint
resource "aws_dms_endpoint" "dms-source-endpoint" {
  endpoint_id                 = "cdc-source-endpoint"
  endpoint_type               = "source"
  engine_name                 = "mysql"
  username                    = var.username
  password                    = var.password
  server_name                 = aws_db_instance.cdc_db_instance.address
  port                        = 3306
  database_name               = "cdc_db"
  ssl_mode                    = "none"
}

resource "aws_dms_s3_endpoint" "dms-target-endpoint" {
  endpoint_id = "dms-target-endpoint"
  endpoint_type = "target"
  bucket_name = aws_s3_bucket.s3_bucket_demo.bucket
  compression_type = "NONE"
  csv_delimiter = ","
  csv_row_delimiter = "\n"
  service_access_role_arn = aws_iam_role.dms-access-for-endpoint.arn
  add_column_name                             = true
  timestamp_column_name                       = "tx_commit_time"
  data_format                                 = "csv"
  date_partition_delimiter                    = "UNDERSCORE"
  date_partition_enabled                      = false
  date_partition_sequence                     = "yyyymmddhh"
  date_partition_timezone                     = "Asia/Ho_Chi_Minh"
  enable_statistics                           = false
  encoding_type                               = "plain"
  encryption_mode                             = "SSE_S3"
}

data "aws_iam_policy_document" "dms_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      identifiers = ["dms.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_iam_role" "dms-access-for-endpoint" {
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json
  name               = "dms-access-for-endpoint"
}

resource "aws_iam_role_policy_attachment" "dms-access-for-endpoint-AmazonDMSRedshiftS3Role" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSRedshiftS3Role"
  role       = aws_iam_role.dms-access-for-endpoint.name
}

resource "aws_iam_role" "dms-cloudwatch-logs-role" {
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json
  name               = "dms-cloudwatch-logs-role"
}

resource "aws_iam_role_policy_attachment" "dms-cloudwatch-logs-role-AmazonDMSCloudWatchLogsRole" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
  role       = aws_iam_role.dms-cloudwatch-logs-role.name
}

resource "aws_iam_role" "dms-vpc-role" {
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json
  name               = "dms-vpc-role"
}

resource "aws_iam_role_policy_attachment" "dms-vpc-role-AmazonDMSVPCManagementRole" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
  role       = aws_iam_role.dms-vpc-role.name
}

# Create DMS replication instance
resource "aws_dms_replication_instance" "dms_instance" {
  replication_instance_id = "cdc-replication-instance"
  allocated_storage       = 50
  apply_immediately       = true
  auto_minor_version_upgrade = true
  engine_version           = "3.5.1"
  multi_az                 = false
  publicly_accessible      = true
  replication_instance_class = "dms.t3.micro"
  vpc_security_group_ids = ["sg-05f32df7f48b3b857"]
  replication_subnet_group_id = aws_dms_replication_subnet_group.dms_subnet_group.id

  depends_on = [
    aws_iam_role_policy_attachment.dms-access-for-endpoint-AmazonDMSRedshiftS3Role,
    aws_iam_role_policy_attachment.dms-cloudwatch-logs-role-AmazonDMSCloudWatchLogsRole,
    aws_iam_role_policy_attachment.dms-vpc-role-AmazonDMSVPCManagementRole
  ]
}


resource "aws_iam_role_policy_attachment" "dms-vpc-role-policy-attachment" {
  role       = aws_iam_role.dms-vpc-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}

resource "aws_dms_replication_subnet_group" "dms_subnet_group" {
  replication_subnet_group_description = "Replication subnet group"
  replication_subnet_group_id          = "dmssubnetgroup"

  subnet_ids = [
    "subnet-0c6085cf6b568dae0",
    "subnet-0c0834cc5aa44aac6",
  ]

  # explicit depends_on is needed since this resource doesn't reference the role or policy attachment
  depends_on = [aws_iam_role_policy_attachment.dms-vpc-role-policy-attachment]
}

# Create a new replication task
resource "aws_dms_replication_task" "dms_replication_task" {
  cdc_start_time            = "1993-05-21T05:50:00Z"
  migration_type            = "full-load-and-cdc"
  replication_instance_arn  = aws_dms_replication_instance.dms_instance.replication_instance_arn
  replication_task_id       = "dms-replication-task"
  source_endpoint_arn       = aws_dms_endpoint.dms-source-endpoint.endpoint_arn
  replication_task_settings = <<EOF
  {
  "TargetMetadata": {
    "TargetSchema": "",
    "SupportLobs": true,
    "FullLobMode": false,
    "LobChunkSize": 64,
    "LimitedSizeLobMode": true,
    "LobMaxSize": 32,
    "InlineLobMaxSize": 0,
    "LoadMaxFileSize": 0,
    "ParallelLoadThreads": 0,
    "ParallelLoadBufferSize": 0,
    "BatchApplyEnabled": false,
    "TaskRecoveryTableEnabled": false,
    "ParallelLoadQueuesPerThread": 0,
    "ParallelApplyThreads": 0,
    "ParallelApplyBufferSize": 0,
    "ParallelApplyQueuesPerThread": 0
  },
  "FullLoadSettings": {
    "CreatePkAfterFullLoad": false,
    "StopTaskCachedChangesApplied": false,
    "StopTaskCachedChangesNotApplied": false,
    "MaxFullLoadSubTasks": 1,
    "TransactionConsistencyTimeout": 600,
    "CommitRate": 10000
  },
  "Logging": {
    "EnableLogging": true,
    "EnableLogContext": false,
    "LogComponents": [
      {
        "Id": "SOURCE_UNLOAD",
        "Severity": "LOGGER_SEVERITY_DEFAULT"
      },
      {
        "Id": "SOURCE_CAPTURE",
        "Severity": "LOGGER_SEVERITY_DEFAULT"
      },
      {
        "Id": "TARGET_LOAD",
        "Severity": "LOGGER_SEVERITY_DEFAULT"
      },
      {
        "Id": "TARGET_APPLY",
        "Severity": "LOGGER_SEVERITY_DEFAULT"
      },
      {
        "Id": "TASK_MANAGER",
        "Severity": "LOGGER_SEVERITY_DEFAULT"
      }
    ]
  },
  "ControlTablesSettings": {
    "ControlSchema": "",
    "HistoryTimeslotInMinutes": 5,
    "HistoryTableEnabled": false,
    "SuspendedTablesTableEnabled": false,
    "StatusTableEnabled": false
  },
  "StreamBufferSettings": {
    "StreamBufferCount": 3,
    "StreamBufferSizeInMB": 8,
    "CtrlStreamBufferSizeInMB": 5
  },
  "ChangeProcessingDdlHandlingPolicy": {
    "HandleSourceTableDropped": true,
    "HandleSourceTableTruncated": true,
    "HandleSourceTableAltered": true
  },
  "ErrorBehavior": {
    "DataErrorPolicy": "LOG_ERROR",
    "DataTruncationErrorPolicy": "LOG_ERROR",
    "DataErrorEscalationPolicy": "SUSPEND_TABLE",
    "DataErrorEscalationCount": 0,
    "TableErrorPolicy": "SUSPEND_TABLE",
    "TableErrorEscalationPolicy": "STOP_TASK",
    "TableErrorEscalationCount": 0,
    "RecoverableErrorCount": -1,
    "RecoverableErrorInterval": 5,
    "RecoverableErrorThrottling": true,
    "RecoverableErrorThrottlingMax": 1800,
    "RecoverableErrorStopRetryAfterThrottlingMax": false,
    "ApplyErrorDeletePolicy": "IGNORE_RECORD",
    "ApplyErrorInsertPolicy": "LOG_ERROR",
    "ApplyErrorUpdatePolicy": "LOG_ERROR",
    "ApplyErrorEscalationPolicy": "LOG_ERROR",
    "ApplyErrorEscalationCount": 0,
    "ApplyErrorFailOnTruncationDdl": false,
    "FullLoadIgnoreConflicts": true,
    "FailOnTransactionConsistencyBreached": false,
    "FailOnNoTablesCaptured": false
  },
  "ChangeProcessingTuning": {
    "BatchApplyPreserveTransaction": true,
    "BatchApplyTimeoutMin": 1,
    "BatchApplyTimeoutMax": 30,
    "BatchApplyMemoryLimit": 500,
    "BatchSplitSize": 0,
    "MinTransactionSize": 1000,
    "CommitTimeout": 1,
    "MemoryLimitTotal": 1024,
    "MemoryKeepTime": 60,
    "StatementCacheSize": 50
  },
  "ValidationSettings": {
    "EnableValidation": false,
    "ValidationMode": "ROW_LEVEL",
    "ThreadCount": 5,
    "FailureMaxCount": 10000,
    "TableFailureMaxCount": 1000,
    "HandleCollationDiff": false,
    "ValidationOnly": false,
    "RecordFailureDelayLimitInMinutes": 0,
    "SkipLobColumns": false,
    "ValidationPartialLobSize": 0,
    "ValidationQueryCdcDelaySeconds": 0,
    "PartitionSize": 10000
  },
  "PostProcessingRules": null,
  "CharacterSetSettings": null,
  "LoopbackPreventionSettings": null,
  "BeforeImageSettings": null
}
EOF
  table_mappings = <<EOF
{
  "rules": [
    {
      "rule-type": "selection",
      "rule-id": "1",
      "rule-name": "1",
      "object-locator": {
        "schema-name": "cdc_db",
        "table-name": "Persons"
      },
      "rule-action": "include"
    }
  ]
}
EOF

  target_endpoint_arn = aws_dms_s3_endpoint.dms-target-endpoint.endpoint_arn
}

# Lambda function to trigger Glue job
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "iam_for_lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "s3_full_access_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "glue_full_access_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess"
}

resource "aws_iam_role_policy_attachment" "coudwatch_full_access_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

data "archive_file" "zip_the_python_code" {
 type        = "zip"
 source_dir  = "${local.lambda_src_path}"
 output_path = "${local.lambda_src_path}lambda_function.zip"
}

resource "aws_lambda_function" "lambda_function" {
  function_name    = "lambda_function"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda-function.lambda_handler"
  runtime          = "python3.9"
  filename         = data.archive_file.zip_the_python_code.output_path
  source_code_hash = data.archive_file.zip_the_python_code.output_base64sha256
  timeout          = 120
  depends_on       = [aws_iam_role_policy_attachment.s3_full_access_policy_attachment, aws_iam_role_policy_attachment.glue_full_access_policy_attachment, aws_iam_role_policy_attachment.coudwatch_full_access_policy_attachment]
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.s3_bucket_demo.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.lambda_function.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "cdc_db/"
  }

  depends_on = [aws_lambda_permission.allow_bucket]
}

resource "aws_lambda_permission" "allow_bucket" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.s3_bucket_demo.arn
}

# IAM role for Glue job
resource "aws_iam_role" "glue_role" {
  name = "glue_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "glue.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_policy_attachment" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# Attach CloudWatch policy to the role
resource "aws_iam_role_policy_attachment" "glue_cloudwatch_policy_attachment" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

resource "aws_s3_object" "deploy_script_s3" {
  bucket = aws_s3_bucket.s3_bucket_demo.bucket
  key = "glue/scripts/glue.py"
  source = "${local.glue_src_path}glue.py"
  etag = filemd5("${local.glue_src_path}glue.py")
}

# Object output for the Glue job
resource "aws_s3_object" "output_for_glue_job" {
  bucket = aws_s3_bucket.s3_bucket_demo.bucket
  key = "output/"
}

resource "aws_glue_job" "glue_job_spark" {
  glue_version = "4.0" #optional
  max_retries = 0 #optional
  name = "glue_job_spark" #required
  description = "the deployment of an aws glue job to aws glue service with terraform" #description
  role_arn = aws_iam_role.glue_role.arn #required
  number_of_workers = 2 #optional, defaults to 5 if not set
  worker_type = "G.1X" #optional
  timeout = "60" #optional
  execution_class = "FLEX" #optional
  
  command {
    name="glueetl" #optional
    script_location = "s3://${aws_s3_bucket.s3_bucket_demo.bucket}/glue/scripts/glue.py" #required
  }
  default_arguments = {
    "--class"                   = "GlueApp"
    "--enable-job-insights"     = "true"
    "--enable-auto-scaling"     = "false"
    "--enable-glue-datacatalog" = "true"
    "--job-language"            = "python"
    "--job-bookmark-option"     = "job-bookmark-disable"
    "--datalake-formats"        = "iceberg"
    "--conf"                    = "spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions  --conf spark.sql.catalog.glue_catalog=org.apache.iceberg.spark.SparkCatalog  --conf spark.sql.catalog.glue_catalog.warehouse=s3://tnt-erp-sql/ --conf spark.sql.catalog.glue_catalog.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog  --conf spark.sql.catalog.glue_catalog.io-impl=org.apache.iceberg.aws.s3.S3FileIO"

  }
}
