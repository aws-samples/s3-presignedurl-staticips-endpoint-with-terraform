# Create VPC
resource "aws_vpc" "test_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = {
    Name = "apg-test-vpc"
  }
}

# Create two private subnets
resource "aws_subnet" "private_subnet_1" {
  vpc_id                  = aws_vpc.test_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"  # Specify the desired availability zone
  map_public_ip_on_launch = false
  tags = {
    Name = "apg-test-private-subnet-2a"
  }
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id                  = aws_vpc.test_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-2b"  # Specify the desired availability zone
  map_public_ip_on_launch = false
  tags = {
    Name = "apg-test-private-subnet-2b"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "test_igw" {
  vpc_id = aws_vpc.test_vpc.id

  tags = {
    Name = "apg-test-igw"
  }
}
# Create a route table for each private subnet
resource "aws_route_table" "private_route_table_1" {
  vpc_id = aws_vpc.test_vpc.id
  tags = {
    Name = "apg-test-rt-1"
  }
}

resource "aws_route_table" "private_route_table_2" {
  vpc_id = aws_vpc.test_vpc.id
  tags = {
    Name = "apg-test-rt-2"
  }
}

# Associate each route table with its corresponding subnet
resource "aws_route_table_association" "private_subnet_association_1" {
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.private_route_table_1.id
}

resource "aws_route_table_association" "private_subnet_association_2" {
  subnet_id      = aws_subnet.private_subnet_2.id
  route_table_id = aws_route_table.private_route_table_2.id
}

# Global Accelerator
resource "aws_globalaccelerator_accelerator" "global_accelerator" {
  name            = upper("${var.environment_name}-GLOBAL-ACCELERATOR")
  ip_address_type = "IPV4"
}

resource "aws_globalaccelerator_listener" "ga_listener_80" {
  accelerator_arn = aws_globalaccelerator_accelerator.global_accelerator.id
  protocol        = "TCP"

  port_range {
    from_port = 80
    to_port   = 80
  }
}

resource "aws_globalaccelerator_listener" "ga_listener_443" {
  accelerator_arn = aws_globalaccelerator_accelerator.global_accelerator.id
  protocol        = "TCP"

  port_range {
    from_port = 443
    to_port   = 443
  }
}

# SG for ALB routing to API
resource "aws_security_group" "sg_alb_to_api_endpoint" {
  name        = upper("${var.environment_name}-SG-ALB-API")
  description = "Security group for ALB routing to VPC API Endpoint"
  vpc_id      = aws_vpc.test_vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = upper("${var.environment_name}-SG-ALB-API")
  }
}

#SG for VPC Endpoint
resource "aws_security_group" "sg_vpc_endpoint" {
  name        = upper("${var.environment_name}-SG-API-ENDOINT")
  description = "Security group for VPC Endpoint"
  vpc_id      = aws_vpc.test_vpc.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_alb_to_api_endpoint.id]
  }

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_alb_to_api_endpoint.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = upper("${var.environment_name}-SG-API-ENDOINT")
  }
}

#API Endpoint
resource "aws_vpc_endpoint" "api_endpoint" {
  vpc_id            = aws_vpc.test_vpc.id
  service_name      = "com.amazonaws.${var.aws_region}.execute-api"
  vpc_endpoint_type = "Interface"

  subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]

  security_group_ids = [aws_security_group.sg_vpc_endpoint.id]

  private_dns_enabled = false

  tags = {
    Name = upper("${var.environment_name}-API-ENDPOINT")
  }
}

#S3 Endpoint
resource "aws_vpc_endpoint" "s3_endpoint" {
  vpc_id            = aws_vpc.test_vpc.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Interface"

  subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]

  security_group_ids = [aws_security_group.sg_vpc_endpoint.id]

  private_dns_enabled = false

  tags = {
    Name = upper("${var.environment_name}-S3-ENDPOINT")
  }
}

# Load balancer 
resource "aws_lb" "alb_to_api_endpoint" {
  ip_address_type    = "ipv4"
  load_balancer_type = "application"
  name               = upper("${var.environment_name}-ALB-API")
  internal           = true
  security_groups    = [aws_security_group.sg_alb_to_api_endpoint.id]
  subnets            = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
}

#API Endpoint Target group
resource "aws_lb_target_group" "alb_api_endpoint_tg" {
  target_type      = "ip"
  name             = upper("${var.environment_name}-TG-API-ENDPOINT")
  port             = "443"
  protocol         = "HTTPS"
  protocol_version = "HTTP1"
  vpc_id           = aws_vpc.test_vpc.id

  health_check {
    enabled             = "true"
    healthy_threshold   = "5"
    interval            = "30"
    matcher             = "200,403"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTPS"
    timeout             = "5"
    unhealthy_threshold = "2"
  }
}

#S3 Endpoint Target group
resource "aws_lb_target_group" "alb_s3_endpoint_tg" {
  target_type      = "ip"
  name             = upper("${var.environment_name}-TG-S3-ENDPOINT")
  port             = "80"
  protocol         = "HTTP"
  protocol_version = "HTTP1"
  vpc_id           = aws_vpc.test_vpc.id

  health_check {
    enabled             = "true"
    healthy_threshold   = "5"
    interval            = "30"
    matcher             = "200,307,405"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = "5"
    unhealthy_threshold = "2"
  }
}

# GA to ALB Endpoint
resource "aws_globalaccelerator_endpoint_group" "ga_endpoint_group_80" {
  listener_arn = aws_globalaccelerator_listener.ga_listener_80.id

  endpoint_configuration {
    client_ip_preservation_enabled = true
    endpoint_id                    = aws_lb.alb_to_api_endpoint.arn
    weight                         = 100
  }
}
resource "aws_globalaccelerator_endpoint_group" "ga_endpoint_group_443" {
  listener_arn = aws_globalaccelerator_listener.ga_listener_443.id

  endpoint_configuration {
    client_ip_preservation_enabled = true
    endpoint_id                    = aws_lb.alb_to_api_endpoint.arn
    weight                         = 100
  }
}

resource "aws_lb_listener" "alb_api_endpoint_listener_80" {
  default_action {
    order = "1"

    redirect {
      host        = "jun.${var.domain}"
      path        = "/#{path}"
      port        = "443"
      protocol    = "HTTPS"
      query       = "#{query}"
      status_code = "HTTP_301"
    }

    type = "redirect"
  }

  load_balancer_arn = aws_lb.alb_to_api_endpoint.arn
  port              = "80"
  protocol          = "HTTP"
}

#Retrieve listeners
data "aws_acm_certificate" "default_cert" {
  domain = "*.${var.domain}"
  types  = ["AMAZON_ISSUED"]

  statuses = ["ISSUED"]
}

#443 port listener
resource "aws_lb_listener" "alb_api_endpoint_listener_443" {
  certificate_arn = data.aws_acm_certificate.default_cert.arn

  default_action {
    order            = "1"
    target_group_arn = aws_lb_target_group.alb_api_endpoint_tg.arn
    type             = "forward"
  }

  load_balancer_arn = aws_lb.alb_to_api_endpoint.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

resource "aws_lb_listener_rule" "alb_s3_endpoint_listener_443" {
  listener_arn = aws_lb_listener.alb_api_endpoint_listener_443.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_s3_endpoint_tg.arn
  }

  condition {
    host_header {
      # ex) examplebucket2-s3.testdomain.com
      values = ["${var.s3_bucket_prefix}.${var.domain}"]
    }
  }
}

# #Integrate certs to 443 port listener
# resource "aws_lb_listener_certificate" "listener_443_cert_default" {
#   listener_arn    = aws_lb_listener.alb_api_endpoint_listener_443.arn
#   certificate_arn = data.aws_acm_certificate.default_cert.arn
# }

# resource "aws_lb_listener_certificate" "listener_443_cert_s3" {
#   listener_arn    = aws_lb_listener.alb_api_endpoint_listener_443.arn
#   certificate_arn = data.aws_acm_certificate.s3_cert.arn
# }
