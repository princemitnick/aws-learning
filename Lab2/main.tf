terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # Région compatible avec votre Sandbox
}

# 1. Recherche automatique de la dernière AMI Ubuntu
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 2. Clé SSH (générée ou importée localement)
resource "aws_key_pair" "lab2_key" {
  key_name   = "lab2-aws-key"
  public_key = file("~/.ssh/lab_aws_key.pub")
}

# 3. Nouveau VPC
resource "aws_vpc" "lab2_vpc" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "lab2-vpc"
  }
}

# 4. Nouveaux sous-réseaux (Public et Privé épinglés en us-east-1a)
resource "aws_subnet" "lab2_public_subnet" {
  vpc_id                  = aws_vpc.lab2_vpc.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "lab2-subnet-public"
  }
}

resource "aws_subnet" "lab2_private_subnet" {
  vpc_id            = aws_vpc.lab2_vpc.id
  cidr_block        = "10.10.2.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "lab2-subnet-private"
  }
}

# 5. Internet Gateway et Table de routage publique
resource "aws_internet_gateway" "lab2_igw" {
  vpc_id = aws_vpc.lab2_vpc.id

  tags = {
    Name = "lab2-igw"
  }
}

resource "aws_route_table" "lab2_public_rt" {
  vpc_id = aws_vpc.lab2_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab2_igw.id
  }

  tags = {
    Name = "lab2-rt-public"
  }
}

resource "aws_route_table_association" "lab2_public_assoc" {
  subnet_id      = aws_subnet.lab2_public_subnet.id
  route_table_id = aws_route_table.lab2_public_rt.id
}

# 6. Security Group pour l'ALB (autorise HTTP depuis Internet)
resource "aws_security_group" "alb_sg" {
  name        = "lab2-alb-sg"
  description = "Autorise HTTP depuis Internet vers l'ALB"
  vpc_id      = aws_vpc.lab2_vpc.id

  ingress {
    description = "HTTP depuis Internet"
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
    Name = "lab2-alb-sg"
  }
}

# 7. Security Groups pour les instances (avec cloisonnement ALB -> Web)
resource "aws_security_group" "public_web_sg" {
  name        = "lab2-public-web-sg"
  description = "Autorise SSH et HTTP uniquement depuis l'ALB"
  vpc_id      = aws_vpc.lab2_vpc.id

  ingress {
    description = "SSH de gestion"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description     = "HTTP provenant uniquement de l'ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # Chaînage ALB -> Instance Web
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab2-public-web-sg"
  }
}

resource "aws_security_group" "private_db_sg" {
  name        = "lab2-private-db-sg"
  description = "Autorise MySQL uniquement depuis le SG web"
  vpc_id      = aws_vpc.lab2_vpc.id

  ingress {
    description     = "MySQL depuis le Security Group Web"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.public_web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab2-private-db-sg"
  }
}

# 8. Nouvelles instances EC2 Ubuntu
resource "aws_instance" "web_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.lab2_public_subnet.id
  vpc_security_group_ids = [aws_security_group.public_web_sg.id]
  key_name               = aws_key_pair.lab2_key.key_name

  # Script de démarrage pour installer Nginx et afficher un message personnalisé
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y nginx
              echo "<h1>Lab ELB réussi depuis l'instance Web publique !</h1>" > /var/www/html/index.html
              systemctl restart nginx
              EOF

  tags = {
    Name = "lab2-web-server"
  }
}

resource "aws_instance" "db_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.lab2_private_subnet.id
  vpc_security_group_ids = [aws_security_group.private_db_sg.id]
  key_name               = aws_key_pair.lab2_key.key_name

  tags = {
    Name = "lab2-db-server"
  }
}

# 9. Application Load Balancer (ALB)
resource "aws_lb" "lab_alb" {
  name               = "lab2-web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.lab2_public_subnet.id] # (Pour ce lab mono-AZ)

  enable_deletion_protection = false

  tags = {
    Name = "lab2-alb"
  }
}

# 10. Target Group
resource "aws_lb_target_group" "lab_tg" {
  name     = "lab2-web-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.lab2_vpc.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "lab2-target-group"
  }
}

# 11. Attachement de l'instance web au Target Group
resource "aws_lb_target_group_attachment" "tg_attach" {
  target_group_arn = aws_lb_target_group.lab_tg.arn
  target_id        = aws_instance.web_server.id
  port             = 80
}

# 12. Listener HTTP sur l'ALB
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.lab_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lab_tg.arn
  }
}

# 13. Outputs pour récupérer les points d'accès
output "alb_dns_name" {
  description = "URL magique de l'ALB pour tester l'application web"
  value       = aws_lb.lab_alb.dns_name
}

output "web_instance_ip" {
  description = "IP publique du serveur web"
  value       = aws_instance.web_server.public_ip
}