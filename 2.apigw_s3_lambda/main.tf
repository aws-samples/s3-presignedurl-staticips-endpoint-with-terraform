data "aws_caller_identity" "self" {}


data "aws_route53_zone" "public_domain_zone" {
  name         = "${var.domain}"
}

data "aws_globalaccelerator_accelerator" "global_accelerator" {
  name = upper("${var.environment_name}-GLOBAL-ACCELERATOR")
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.public_domain_zone.zone_id
  name    = "${var.s3_bucket_prefix}.${var.domain}"
  type    = "A"
  ttl     = 300
  records = data.aws_globalaccelerator_accelerator.global_accelerator.ip_sets[0].ip_addresses
}

data "aws_lb" "alb_to_api_endpoint" {
  name               = upper("${var.environment_name}-ALB-API")
}

#Retrive Private IPs of Endpoints which made from 1.ga_alb
#Attach ALB target group to Endpoint private IPs
data "aws_vpc_endpoint" "api_endpoint" {
  vpc_id       = var.vpc_id
  service_name = "com.amazonaws.${var.aws_region}.execute-api"

  tags = {
    Name = upper("${var.environment_name}-API-ENDPOINT")
  }
}

data "aws_vpc_endpoint" "s3_endpoint" {
  vpc_id       = var.vpc_id
  service_name = "com.amazonaws.${var.aws_region}.s3"

  tags = {
    Name = upper("${var.environment_name}-S3-ENDPOINT")
  }
}

data "aws_network_interface" "api_endpoint_eni" {
  for_each = toset(data.aws_vpc_endpoint.api_endpoint.network_interface_ids)

  id = each.key
}

data "aws_network_interface" "s3_endpoint_eni" {
  for_each = toset(data.aws_vpc_endpoint.s3_endpoint.network_interface_ids)

  id = each.key
}

data "aws_lb_target_group" "alb_api_endpoint_tg" {
  name = upper("${var.environment_name}-TG-API-ENDPOINT")
}

data "aws_lb_target_group" "alb_s3_endpoint_tg" {
  name = upper("${var.environment_name}-TG-S3-ENDPOINT")
}

resource "aws_lb_target_group_attachment" "alb_api_endpoint_tg_attach" {
  for_each         = data.aws_network_interface.api_endpoint_eni
  target_group_arn = data.aws_lb_target_group.alb_api_endpoint_tg.arn
  target_id        = each.value.private_ip
  port             = 443
}

resource "aws_lb_target_group_attachment" "alb_s3_endpoint_tg_attach" {
  for_each         = data.aws_network_interface.s3_endpoint_eni
  target_group_arn = data.aws_lb_target_group.alb_s3_endpoint_tg.arn
  target_id        = each.value.private_ip
  port             = 80
}

# GA to ALB Endpoint
resource "aws_globalaccelerator_listener" "ga_listener_80" {
  accelerator_arn = data.aws_globalaccelerator_accelerator.global_accelerator.id
  protocol        = "TCP"

  port_range {
    from_port = 80
    to_port   = 80
  }
}

resource "aws_globalaccelerator_listener" "ga_listener_443" {
  accelerator_arn = data.aws_globalaccelerator_accelerator.global_accelerator.id
  protocol        = "TCP"

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "ga_endpoint_group_80" {
  listener_arn = aws_globalaccelerator_listener.ga_listener_80.id

  endpoint_configuration {
    client_ip_preservation_enabled = true
    endpoint_id                    = data.aws_lb.alb_to_api_endpoint.arn
    weight                         = 100
  }
}
resource "aws_globalaccelerator_endpoint_group" "ga_endpoint_group_443" {
  listener_arn = aws_globalaccelerator_listener.ga_listener_443.id

  endpoint_configuration {
    client_ip_preservation_enabled = true
    endpoint_id                    = data.aws_lb.alb_to_api_endpoint.arn
    weight                         = 100
  }
}

# S3 Bucket
resource "aws_s3_bucket" "s3_bucket" {
  bucket = "${var.s3_bucket_prefix}.${var.domain}"

}

resource "aws_s3_bucket_server_side_encryption_configuration" "s3_bucket_server_side_encryption_configuration" {
  bucket = aws_s3_bucket.s3_bucket.id

  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "s3_bucket_public_access_block" {
  bucket                  = aws_s3_bucket.s3_bucket.id
  block_public_acls       = "true"
  ignore_public_acls      = "true"
  block_public_policy     = "true"
  restrict_public_buckets = "true"
}

#S3 Endpoint Lambda function
resource "aws_iam_policy" "log_s3_report_url_policy" {
  name = "${var.environment_name}_log_s3_report_url_policy"

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : "logs:CreateLogGroup",
        "Resource" : "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.self.id}:*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        "Resource" : "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.self.id}:log-group:/aws/lambda/${var.environment_name}_s3_report_url:*"
      }
    ]
  })
}

resource "aws_iam_role" "lambda_s3_report_url_role" {
  name = "${var.environment_name}_s3_report_url_role"

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "lambda.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })

  managed_policy_arns = [
    aws_iam_policy.log_s3_report_url_policy.arn,
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  ]
}

data "archive_file" "lambda_s3_report_url_source" {
  type        = "zip"
  source_file = "./lambda_code/lambda_function.py"
  output_path = "./lambda_code/payload/s3_report_url_payload.zip"
}

resource "aws_lambda_function" "s3_report_url" {
  filename      = "./lambda_code/payload/s3_report_url_payload.zip"
  function_name = "${var.environment_name}_s3_report_url"
  role          = aws_iam_role.lambda_s3_report_url_role.arn
  handler       = "lambda_function.lambda_handler"

  source_code_hash = data.archive_file.lambda_s3_report_url_source.output_base64sha256

  runtime = "python3.10"

  layers = [
    "arn:aws:lambda:ap-northeast-2:580247275435:layer:LambdaInsightsExtension:37"
  ]
  tracing_config {
    mode = "Active"
  }
  reserved_concurrent_executions = 100

  environment {
    variables = {
      BUCKET_NAME = "${var.s3_bucket_prefix}.${var.domain}"
    }
  }
}

#API Gateway
resource "aws_api_gateway_rest_api" "rest_api" {
  binary_media_types           = ["*/*", "application/pdf"]
  disable_execute_api_endpoint = "false"

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [data.aws_vpc_endpoint.api_endpoint.id]
  }

  minimum_compression_size = "-1"
  name                     = upper("${var.environment_name}-PRIVATE-API")

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "rest_api_policy_document" {
  statement {
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["execute-api:Invoke"]
    resources = ["${aws_api_gateway_rest_api.rest_api.execution_arn}/*"]
  }
}

# API Resource
resource "aws_api_gateway_rest_api_policy" "rest_api_policy" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  policy      = data.aws_iam_policy_document.rest_api_policy_document.json
}

# API Gateway resource, method, response, integration
# /{proxy}
resource "aws_api_gateway_resource" "api_resource_proxy" {
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "{proxy+}"
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
}

# /"{proxy+}"/GET method
resource "aws_api_gateway_method" "api_method_proxy_any" {
  api_key_required = "false"
  authorization    = "NONE"
  http_method      = "ANY"

  resource_id = aws_api_gateway_resource.api_resource_proxy.id
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
}

# /{testId}/GET integration
resource "aws_api_gateway_integration" "api_integration_proxy_any" {
  cache_namespace         = aws_api_gateway_resource.api_resource_proxy.id
  connection_type         = "INTERNET"
  content_handling        = "CONVERT_TO_TEXT"
  http_method             = "ANY"
  integration_http_method = "POST"
  passthrough_behavior    = "WHEN_NO_MATCH"
  resource_id             = aws_api_gateway_resource.api_resource_proxy.id
  rest_api_id             = aws_api_gateway_rest_api.rest_api.id
  timeout_milliseconds    = "29000"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.s3_report_url.invoke_arn

  depends_on = [aws_api_gateway_method.api_method_proxy_any]
}

resource "aws_api_gateway_integration_response" "api_integration_response_proxy_any" {
  http_method = "ANY"
  resource_id = aws_api_gateway_resource.api_resource_proxy.id
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  status_code = "200"

  depends_on = [aws_api_gateway_integration.api_integration_proxy_any]
}

resource "aws_api_gateway_method_response" "api_method_response_proxy_any" {
  http_method = "ANY"
  resource_id = aws_api_gateway_resource.api_resource_proxy.id

  response_models = {
    "application/json" = "Empty"
  }

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  status_code = "200"

  depends_on = [aws_api_gateway_integration_response.api_integration_response_proxy_any]
}

# S3 report lambda permission
resource "aws_lambda_permission" "s3_report_url_permission" {
  statement_id  = "s3_report_url_permission"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_report_url.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.rest_api.execution_arn}/*/*"
}

# CloudWatch Group for enable logging
resource "aws_cloudwatch_log_group" "rest_api_log_group" {
  name              = "/aws/api-gateway/${aws_api_gateway_rest_api.rest_api.name}"
  retention_in_days = 365
}


# Deployment, staging
resource "aws_api_gateway_deployment" "rest_api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id

  triggers = {
    # NOTE: The configuration below will satisfy ordering considerations,
    #       but not pick up all future REST API changes. More advanced patterns
    #       are possible, such as using the filesha1() function against the
    #       Terraform configuration file(s) or removing the .id references to
    #       calculate a hash against whole resources. Be aware that using whole
    #       resources will show a difference after the initial implementation.
    #       It will stabilize to only change when resources change afterwards.
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.api_resource_proxy.id,
      aws_api_gateway_method.api_method_proxy_any,
      aws_api_gateway_method_response.api_method_response_proxy_any.id,
      aws_api_gateway_integration.api_integration_proxy_any.id,
      aws_api_gateway_integration_response.api_integration_response_proxy_any.id
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "rest_api_stage" {
  deployment_id = aws_api_gateway_deployment.rest_api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  stage_name    = "external"
  # cache_cluster_enabled = true
  xray_tracing_enabled = true
  # access_log_settings {
  #   destination_arn = aws_cloudwatch_log_group.rest_api_log_group.arn
  #   format = "$context.extendedRequestId $context.identity.sourceIp $context.identity.caller $context.identity.user [$context.requestTime] \"$context.httpMethod $context.resourcePath $context.protocol\" $context.status $context.responseLength $context.requestId"
  # }
}

resource "aws_api_gateway_method_settings" "rest_api_log_setting" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  stage_name  = aws_api_gateway_stage.rest_api_stage.stage_name
  method_path = "*/*"

  settings {
    caching_enabled      = true
    metrics_enabled      = true
    cache_data_encrypted = true
    data_trace_enabled   = false
  }
}

# Custom domain names, API Mapping
data "aws_acm_certificate" "default_cert" {
  domain = "*.${var.domain}"
  types  = ["AMAZON_ISSUED"]

  statuses = ["ISSUED"]
}

resource "aws_api_gateway_domain_name" "custom_domain" {
  regional_certificate_arn = data.aws_acm_certificate.default_cert.arn
  domain_name     = "${var.s3_bucket_prefix}.${var.domain}"
  security_policy = "TLS_1_2"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_base_path_mapping" "api_bpm" {
  api_id      = aws_api_gateway_rest_api.rest_api.id
  stage_name  = aws_api_gateway_stage.rest_api_stage.stage_name
  domain_name = aws_api_gateway_domain_name.custom_domain.domain_name
  base_path   = "presign"
}
