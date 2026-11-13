terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ca-central-1"
}

# 1. Recherche automatique de la dernière AMI Ubuntu 26.04 LTS
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 2. Clé SSH (Importée depuis votre machine locale)
resource "aws_key_pair" "lab_key" {
  key_name   = "lab-aws-key"
  public_key = file("~/.ssh/lab_aws_key.pub")
}

# 3. VPC
resource "aws_vpc" "lab_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "lab-vpc"
  }
}

# 4. Sous-réseaux (Public et Privé)
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "lab-subnet-public"
  }
}

resource "aws_subnet" "private_subnet" {
  vpc_id     = aws_vpc.lab_vpc.id
  cidr_block = "10.0.2.0/24"

  tags = {
    Name = "lab-subnet-private"
  }
}

# 5. Internet Gateway et Table de routage publique
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab_vpc.id

  tags = {
    Name = "lab-igw"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.lab_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "lab-rt-public"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 6. Groupes de Sécurité (avec chaînage Public -> Privé)
resource "aws_security_group" "public_sg" {
  name        = "public-ec2-sg"
  description = "Autorise SSH et HTTPS depuis Internet"
  vpc_id      = aws_vpc.lab_vpc.id

  ingress {
    description = "SSH depuis Internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS depuis Internet"
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
    Name = "lab-public-sg"
  }
}

resource "aws_security_group" "private_sg" {
  name        = "private-db-sg"
  description = "Autorise MySQL uniquement depuis le SG public"
  vpc_id      = aws_vpc.lab_vpc.id

  ingress {
    description     = "MySQL depuis le Security Group Public uniquement"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.public_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab-private-sg"
  }
}

# 7. Instances EC2 Ubuntu
resource "aws_instance" "public_ec2" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.public_sg.id]
  key_name               = aws_key_pair.lab_key.key_name

  tags = {
    Name = "ec2-public-web-ubuntu"
  }
}

resource "aws_instance" "private_ec2" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_subnet.id
  vpc_security_group_ids = [aws_security_group.private_sg.id]
  key_name               = aws_key_pair.lab_key.key_name

  tags = {
    Name = "ec2-private-db-ubuntu"
  }
}

# 8. Informations affichées à la fin du déploiement
output "public_instance_ip" {
  description = "IP publique de l'instance frontale"
  value       = aws_instance.public_ec2.public_ip
}

output "private_instance_ip" {
  description = "IP privee de l'instance base de donnees"
  value       = aws_instance.private_ec2.private_ip
}

output "ssh_command" {
  description = "Commande pour se connecter a l'instance publique"
  value       = "ssh -i ~/.ssh/lab_aws_key ubuntu@${aws_instance.public_ec2.public_ip}"
}