# --------------------------------------------------
# Cryptographically Secure Random Password for RDS MySQL
# --------------------------------------------------
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# --------------------------------------------------
# RDS DB Subnet Group (Using multi-AZ public subnets)
# --------------------------------------------------
resource "aws_db_subnet_group" "rds" {
  name       = "${var.cluster_name}-rds-subnet-group"
  subnet_ids = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  tags = {
    Name = "${var.cluster_name}-rds-subnet-group"
  }
}

# --------------------------------------------------
# RDS Security Group (MySQL Port 3306)
# --------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds-sg"
  description = "Allow inbound MySQL traffic from VPC (EKS nodes)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "MySQL access from inside VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    description      = "Allow all outbound traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "${var.cluster_name}-rds-sg"
  }
}

# --------------------------------------------------
# AWS RDS MySQL Instance
# --------------------------------------------------
resource "aws_db_instance" "mysql" {
  identifier             = "${var.cluster_name}-mysql"
  engine                 = "mysql"
  engine_version         = "8.0.46"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  max_allocated_storage  = 50
  storage_type           = "gp3"
  db_name                = "gmz_tasks_db"
  username               = "admin"
  password               = random_password.db_password.result
  port                   = 3306
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = {
    Name = "${var.cluster_name}-mysql"
  }
}
