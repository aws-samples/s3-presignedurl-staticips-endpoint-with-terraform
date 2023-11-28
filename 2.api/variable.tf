variable "vpc_id" {
  type = string
  default = "vpc_1234"
}

variable "environment_name" {
  type    = string
  default = "test"
}

variable "domain" {
  type    = string
  default = "testdomain.com"
}

variable "s3_bucket_prefix" {
  type    = string
  default = "examplebucket"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}