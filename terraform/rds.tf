# --------------------------------------------------
# Cryptographically Secure Random Password for RDS
# --------------------------------------------------
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# --------------------------------------------------
# AWS Secrets Manager Secret
# --------------------------------------------------
resource "aws_secretsmanager_secret" "db_secret" {
  name                    = "${var.cluster_name}-rds-credentials"
  description             = "Database credentials for GMZ Health & Task App on AWS EKS"
  recovery_window_in_days = 0 # Immediate deletion on destroy to prevent re-creation lockouts

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

# --------------------------------------------------
# Secret Value (JSON with full connection info)
# --------------------------------------------------
resource "aws_secretsmanager_secret_version" "db_secret_val" {
  secret_id = aws_secretsmanager_secret.db_secret.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = aws_db_instance.postgres.db_name
    username = aws_db_instance.postgres.username
    password = random_password.db_password.result
  })
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
# RDS Security Group
# --------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds-sg"
  description = "Allow inbound PostgreSQL traffic from VPC (EKS nodes)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "PostgreSQL access from inside VPC"
    from_port   = 5432
    to_port     = 5432
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
# AWS RDS PostgreSQL Instance
# --------------------------------------------------
resource "aws_db_instance" "postgres" {
  identifier             = "${var.cluster_name}-postgres"
  engine                 = "postgres"
  engine_version         = "18.3"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  max_allocated_storage  = 50
  storage_type           = "gp3"
  db_name                = "gmz_tasks_db"
  username               = "postgresadmin"
  password               = random_password.db_password.result
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = {
    Name = "${var.cluster_name}-postgres"
  }
}
