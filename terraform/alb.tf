resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  idle_timeout       = 60

  tags = { Name = "${local.name_prefix}-alb" }
}

resource "aws_lb_target_group" "api" {
  name        = "${local.name_prefix}-api-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.cert_arn

  # No rule matches without the correct X-Origin-Verify header (see rules
  # below), so anything that reaches here despite the security group
  # (e.g. another CloudFront customer's distribution, sharing the same
  # origin-facing IP range) gets rejected rather than silently forwarded.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "health" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "OK"
      status_code  = "200"
    }
  }

  # CloudFront forwards the full request path unchanged (no origin-path
  # stripping on the /api/* behavior — see cloudfront_spa's dynamic
  # origin block), so a client request to /api/healthz arrives here as
  # /api/healthz, not /healthz. A live end-to-end check against
  # /api/healthz caught this: with the pattern as just "/healthz" this
  # rule never matched, and the request fell through to the "api" rule
  # below, which forwards to a target group with zero healthy targets
  # (502) instead of returning the fixed 200.
  condition {
    path_pattern { values = ["/api/healthz"] }
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.alb_origin_verify.result]
    }
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    path_pattern { values = ["/*"] }
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.alb_origin_verify.result]
    }
  }
}
