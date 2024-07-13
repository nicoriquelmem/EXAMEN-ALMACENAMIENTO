terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.53.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "vpc-RIQUELME"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "prd"
  }
}

resource "time_sleep" "wait_for_vpc" {
  depends_on = [module.vpc]
  create_duration = "30s"
}

resource "aws_security_group" "sg_webserver" {
  name        = "webserver-RIQUELME"
  description = "Security Group Web Server"

  vpc_id = module.vpc.vpc_id

  ingress {
    description = "Permite HTTP desde ALB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Permite HTTPS desde ALB"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Permite SSH"
    from_port   = 22
    to_port     = 22
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
    Name = "webserver-RIQUELME"
  }
}

resource "aws_security_group" "alb" {
  name        = "alb-RIQUELME"
  description = "Security Group para Application Load Balancer"

  vpc_id = module.vpc.vpc_id

  ingress {
    description = "Permite HTTP desde cualquier destino"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Permite HTTPS desde cualquier destino"
    from_port   = 443
    to_port     = 443
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
    Name = "alb-RIQUELME"
  }
}

resource "aws_instance" "ec2" {
  count         = 2
  ami           = "ami-08c40ec9ead489470" # AMI ID actualizado
  instance_type = "t2.micro"

  vpc_security_group_ids = [aws_security_group.sg_webserver.id]
  subnet_id              = element(module.vpc.private_subnets, count.index)

  user_data = <<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install -y httpd
              sudo systemctl start httpd
              sudo systemctl enable httpd
              sudo yum install -y amazon-efs-utils
              sudo mkdir /var/www/html
              sudo mount -t efs fs-12345678:/ /var/www/html
              sudo cp /var/www/html/index.html /var/www/html/index.html
              EOF

  tags = {
    Name = "EC2-RIQUELME-${count.index + 1}"
  }
}

resource "aws_s3_bucket" "website_bucket" {
  bucket = "website-bucket-riquelme-123456"
  
  tags = {
    Name        = "website-bucket-riquelme"
    Environment = "production"
  }
}

resource "aws_s3_bucket_acl" "website_bucket_acl" {
  bucket = aws_s3_bucket.website_bucket.bucket
  acl    = "public-read"
}

resource "aws_s3_bucket_website_configuration" "website_bucket_config" {
  bucket = aws_s3_bucket.website_bucket.bucket

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_lb" "lb" {
  name               = "lb-RIQUELME"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = false

  tags = {
    Name = "lb-RIQUELME"
  }
}

resource "aws_lb_target_group" "target_group" {
  name     = "target-group-RIQUELME"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  depends_on = [aws_lb.lb]
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn
  }

  depends_on = [aws_lb_target_group.target_group]
}

resource "aws_lb_target_group_attachment" "target_group_attachment" {
  count             = length(aws_instance.ec2)
  target_group_arn  = aws_lb_target_group.target_group.arn
  target_id         = element(aws_instance.ec2.*.id, count.index)
  port              = 80
}

output "website_url" {
  value       = aws_lb.lb.dns_name
  description = "The URL of the website"
}
