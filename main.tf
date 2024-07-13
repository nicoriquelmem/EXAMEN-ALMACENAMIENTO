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

resource "aws_security_group" "efs" {
  name        = "efs-RIQUELME"
  description = "Security Group para EFS"

  vpc_id = module.vpc.vpc_id

  ingress {
    description = "Permite NFS desde Web Servers"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    security_groups = [aws_security_group.sg_webserver.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "efs-RIQUELME"
  }
}

resource "random_id" "bucket" {
  byte_length = 8
}

resource "aws_s3_bucket" "website_bucket" {
  bucket = "website-bucket-RIQUELME-${random_id.bucket.hex}"

  tags = {
    Name = "website-bucket-RIQUELME-${random_id.bucket.hex}"
  }
}

resource "aws_s3_bucket_public_access_block" "website_bucket" {
  bucket = aws_s3_bucket.website_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "time_sleep" "wait_10_seconds" {
  depends_on      = [aws_s3_bucket.website_bucket]
  create_duration = "10s"
}

resource "aws_s3_bucket_policy" "website_bucket" {
  bucket = aws_s3_bucket.website_bucket.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "${aws_s3_bucket.website_bucket.arn}/*"
    }
  ]
}
EOF

  depends_on = [time_sleep.wait_10_seconds]
}

resource "aws_s3_object" "index_php" {
  bucket = aws_s3_bucket.website_bucket.id
  key    = "index.php"
  source = "index.php"

  depends_on = [aws_s3_bucket_policy.website_bucket]
}

resource "aws_efs_file_system" "efs" {
  creation_token = "efs-RIQUELME"
}

resource "aws_efs_mount_target" "efs_mount" {
  count          = length(module.vpc.private_subnets)
  file_system_id = aws_efs_file_system.efs.id
  subnet_id      = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

resource "aws_instance" "ec2" {
  count         = length(module.vpc.private_subnets)
  ami           = "ami-01b799c439fd5516a" 
  instance_type = "t2.micro"
  key_name      = "vockey"

  subnet_id              = element(module.vpc.private_subnets, count.index)
  vpc_security_group_ids = [aws_security_group.sg_webserver.id]
  depends_on             = [aws_efs_mount_target.efs_mount]

  user_data = <<-EOF
              #!/bin/bash
              sudo yum install -y httpd php
              sudo mkdir -p /mnt/efs
              sudo mount -t efs ${aws_efs_file_system.efs.id}:/ /mnt/efs
              sudo ln -s /mnt/efs/index.php /var/www/html/index.php
              sudo systemctl enable httpd
              sudo systemctl start httpd
              EOF

  tags = {
    Name = "EC2-RIQUELME-${count.index + 1}"
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
