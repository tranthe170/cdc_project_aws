variable "username" {
  description = "The username for the RDS instance"
  default     = "cdc_user"
}

variable "password" {
  description = "The password for the RDS instance"
  default     = "Trangiathe"
}

variable "bucket_name" {
  description = "Bucket prefix for our datalake output"
  type        = string
  default     = "demo-cdc-bucket"
}
locals {
  glue_src_path = "${path.root}/../glue/"
  lambda_src_path = "${path.root}/../lambda/"
}