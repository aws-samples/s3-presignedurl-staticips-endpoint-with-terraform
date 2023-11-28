data "aws_caller_identity" "self" {}


data "aws_route53_zone" "public_domain_zone" {
  name         = "${var.domain}"
}

data "aws_globalaccelerator_accelerator" "global_accelerator" {
  name = upper("${var.environment_name}-GLOBAL-ACCELERATOR")
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.public_domain_zone.zone_id
  name    = "jun.${var.domain}"
  type    = "A"
  ttl     = 300
  records = data.aws_globalaccelerator_accelerator.global_accelerator.ip_sets[0].ip_addresses
}

resource "aws_route53_record" "www2" {
  zone_id = data.aws_route53_zone.public_domain_zone.zone_id
  name    = "${var.s3_bucket_prefix}.${var.domain}"
  type    = "A"
  ttl     = 300
  records = data.aws_globalaccelerator_accelerator.global_accelerator.ip_sets[0].ip_addresses
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

# S3 Bucket
resource "aws_s3_bucket" "s3_bucket" {
  bucket = "${var.s3_bucket_prefix}.s3.${var.domain}"

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

  environment {
    variables = {
      BUCKET_NAME = "${var.s3_bucket_prefix}.s3.${var.domain}"
    }
  }
}

#API Gateway
resource "aws_api_gateway_rest_api" "rest_api" {
  api_key_source               = "AUTHORIZER"
  binary_media_types           = ["*/*", "application/pdf"]
  disable_execute_api_endpoint = "false"

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [data.aws_vpc_endpoint.api_endpoint.id]
  }

  minimum_compression_size = "-1"
  name                     = upper("${var.environment_name}-PRIVATE-API")
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

# data "aws_lb" "internal_nlb" {
#   name = upper("${var.environment_name}-NLB")
# }

# # VPC Link for connecting API Gateway and Internal NLB
# resource "aws_api_gateway_vpc_link" "nlb_vpc_link" {
#   name        = "nlb_vpc_link"
#   target_arns = ["${data.aws_lb.internal_nlb.arn}"]
# }

# API Resource
resource "aws_api_gateway_rest_api_policy" "rest_api_policy" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  policy      = data.aws_iam_policy_document.rest_api_policy_document.json
}


# # Lambda Cognito Authorizer
# data "aws_lambda_function" "lambda_cognito_authorizer" {
#   function_name = "${var.environment_name}_cognito_authorizer"
# }

# resource "aws_api_gateway_authorizer" "authorizer_cognito" {
#   authorizer_uri  = data.aws_lambda_function.lambda_cognito_authorizer.invoke_arn
#   identity_source = "method.request.header.Authorization"
#   name            = "authorizer_cognito"
#   rest_api_id     = aws_api_gateway_rest_api.rest_api.id
#   type            = "TOKEN"
# }

# resource "aws_lambda_permission" "cognito_authorizer_permission" {
#   statement_id  = "cognito_authorizer_permission"
#   action        = "lambda:InvokeFunction"
#   function_name = data.aws_lambda_function.lambda_cognito_authorizer.function_name
#   principal     = "apigateway.amazonaws.com"
#   source_arn    = "${aws_api_gateway_rest_api.rest_api.execution_arn}/authorizers/${aws_api_gateway_authorizer.authorizer_cognito.id}"
# }

# API Gateway resource, method, response, integration
# /external
resource "aws_api_gateway_resource" "api_resource_external" {
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "external"
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
}

# /external/report
resource "aws_api_gateway_resource" "api_resource_report" {
  parent_id   = aws_api_gateway_resource.api_resource_external.id
  path_part   = "report"
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
}

# /external/report/{testId}
resource "aws_api_gateway_resource" "api_resource_testid" {
  parent_id   = aws_api_gateway_resource.api_resource_report.id
  path_part   = "{testId}"
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
}

# /external/report/{testId}/GET method
resource "aws_api_gateway_method" "api_method_testid_get" {
  api_key_required = "false"
  authorization    = "NONE"
  http_method      = "GET"

  request_parameters = {
    "method.request.path.testId" = "true"
  }

  resource_id = aws_api_gateway_resource.api_resource_testid.id
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
}

# /external/report/{testId}/GET integration
resource "aws_api_gateway_integration" "api_integration_testid_get" {
  cache_namespace         = aws_api_gateway_resource.api_resource_testid.id
  connection_type         = "INTERNET"
  content_handling        = "CONVERT_TO_TEXT"
  http_method             = "GET"
  integration_http_method = "POST"
  passthrough_behavior    = "WHEN_NO_MATCH"
  resource_id             = aws_api_gateway_resource.api_resource_testid.id
  rest_api_id             = aws_api_gateway_rest_api.rest_api.id
  timeout_milliseconds    = "29000"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.s3_report_url.invoke_arn

  depends_on = [aws_api_gateway_method.api_method_testid_get]
}

resource "aws_api_gateway_integration_response" "api_integration_response_testid_get" {
  http_method = "GET"
  resource_id = aws_api_gateway_resource.api_resource_testid.id
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  status_code = "200"

  depends_on = [aws_api_gateway_integration.api_integration_testid_get]
}

resource "aws_api_gateway_method_response" "api_method_response_testid_get" {
  http_method = "GET"
  resource_id = aws_api_gateway_resource.api_resource_testid.id

  response_models = {
    "application/json" = "Empty"
  }

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  status_code = "200"

  depends_on = [aws_api_gateway_integration_response.api_integration_response_testid_get]
}

# S3 report lambda permission
resource "aws_lambda_permission" "s3_report_url_permission" {
  statement_id  = "s3_report_url_permission"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_report_url.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.rest_api.execution_arn}/*/GET/external/report/*"
}

# CloudWatch Group for enable logging
resource "aws_cloudwatch_log_group" "rest_api_log_group" {
  name              = "/aws/api-gateway/${aws_api_gateway_rest_api.rest_api.name}"
  retention_in_days = 7
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
      aws_api_gateway_resource.api_resource_external.id,
      aws_api_gateway_resource.api_resource_report.id,
      aws_api_gateway_resource.api_resource_testid.id,
      aws_api_gateway_method.api_method_testid_get,
      aws_api_gateway_method_response.api_method_response_testid_get.id,
      aws_api_gateway_integration.api_integration_testid_get.id,
      aws_api_gateway_integration_response.api_integration_response_testid_get.id
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

  # # Enable Detailed Access Logging to CloudWatch Logs
  # access_log_settings {
  #   destination_arn = aws_cloudwatch_log_group.rest_api_log_group.arn
  #   format          = jsonencode({ "requestId" : "$context.requestId", "ip" : "$context.identity.sourceIp", "caller" : "$context.identity.caller", "user" : "$context.identity.user", "requestTime" : "$context.requestTime", "httpMethod" : "$context.httpMethod", "resourcePath" : "$context.resourcePath", "status" : "$context.status", "protocol" : "$context.protocol", "responseLength" : "$context.responseLength" })
  # }

}

resource "aws_api_gateway_method_settings" "rest_api_log_setting" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  stage_name  = aws_api_gateway_stage.rest_api_stage.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = true
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
  domain_name     = "jun.${var.domain}"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_base_path_mapping" "api_bpm" {
  api_id      = aws_api_gateway_rest_api.rest_api.id
  stage_name  = aws_api_gateway_stage.rest_api_stage.stage_name
  domain_name = aws_api_gateway_domain_name.custom_domain.domain_name
  base_path   = "test"
}
