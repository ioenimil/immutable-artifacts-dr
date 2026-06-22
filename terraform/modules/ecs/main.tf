resource "aws_ecs_cluster" "main" {
  name = "fincorp-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { ManagedBy = "terraform" }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/fincorp-api-${var.environment}"
  retention_in_days = 7

  tags = { ManagedBy = "terraform" }
}

# Placeholder image on first apply — CI/CD updates the task def on every deploy.
# Terraform ignores image changes after initial creation (lifecycle ignore_changes).
resource "aws_ecs_task_definition" "app" {
  family                   = "fincorp-api-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "fincorp-api"
    image     = "${var.ecr_repo_url}:placeholder"
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [{
      name  = "APP_VERSION"
      value = "placeholder"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  lifecycle {
    ignore_changes = [container_definitions]
  }

  tags = { ManagedBy = "terraform" }
}

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "fincorp-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  tags = { ManagedBy = "terraform" }
}

resource "aws_lb_target_group" "app" {
  name        = "fincorp-tg-${var.environment}"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { ManagedBy = "terraform" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------------------
# ECS Service
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = "fincorp-api-${var.environment}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.service_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "fincorp-api"
    container_port   = 8080
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.http]

  tags = { ManagedBy = "terraform" }
}
