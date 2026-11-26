# Reproducible version of the manual set-up in docs/manual-setup.md.
# Uses the default VPC to stay close to what you click in the console.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "wordpress-ec2", ManagedBy = "terraform" }
  }
}

variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "allowed_http_cidr" {
  description = "Who can reach the site. 0.0.0.0/0 for a public blog."
  type        = string
  default     = "0.0.0.0/0"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "wordpress" {
  name        = "wordpress-web"
  description = "HTTP and HTTPS only. No SSH: use Session Manager."
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  #checkov:skip=CKV_AWS_260:A public website needs port 80 (redirects to HTTPS once a certificate is added).
  security_group_id = aws_security_group.wordpress.id
  description       = "HTTP"
  cidr_ipv4         = var.allowed_http_cidr
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.wordpress.id
  description       = "HTTPS"
  cidr_ipv4         = var.allowed_http_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.wordpress.id
  description       = "Updates, WordPress downloads, SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "wordpress" {
  name = "wordpress-ec2"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.wordpress.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "wordpress" {
  name = "wordpress-ec2"
  role = aws_iam_role.wordpress.name
}

resource "aws_instance" "wordpress" {
  #checkov:skip=CKV_AWS_88:A single public web server needs a public address.
  #checkov:skip=CKV_AWS_126:Detailed monitoring is not needed for a demo.
  #checkov:skip=CKV_AWS_135:t3 instances are EBS-optimised by default.
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.wordpress.id]
  iam_instance_profile   = aws_iam_instance_profile.wordpress.name
  user_data              = file("${path.module}/../scripts/install-wordpress.sh")

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  tags = { Name = "wordpress", Backup = "daily" }
}

# A fixed address that survives stop/start, for DNS.
resource "aws_eip" "wordpress" {
  domain   = "vpc"
  instance = aws_instance.wordpress.id
}

# Daily EBS snapshots of instances tagged Backup = daily, kept for 7 days.
resource "aws_iam_role" "dlm" {
  name = "wordpress-dlm"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "dlm.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "daily" {
  description        = "WordPress daily snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]
    target_tags    = { Backup = "daily" }

    schedule {
      name      = "daily-7-days"
      copy_tags = true
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }
      retain_rule {
        count = 7
      }
    }
  }
}

output "url" {
  value = "http://${aws_eip.wordpress.public_ip}/"
}

output "instance_id" {
  value = aws_instance.wordpress.id
}

output "db_credentials" {
  value = "aws ssm start-session --target ${aws_instance.wordpress.id}, then: sudo cat /root/wordpress-db.txt"
}
