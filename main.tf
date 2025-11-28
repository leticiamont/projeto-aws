# CONFIGURAÇÃO DO PROVEDOR AWS
provider "aws" {
  region     = "us-east-1" # Região de Virginia (padrão)
  access_key = "---------"
  secret_key = "---------"
}

# 1. CRIAÇÃO DA REDE (VPC, Subnet, Internet Gateway e Rotas)
# --- FUNDAÇÃO DE REDE ---

# VPC (Virtual Private Cloud)
resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "projeto-avaliacao-vpc" }
}

# SUBNET PÚBLICA (Onde a maioria dos recursos vai morar)
resource "aws_subnet" "public_subnet_a" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = { Name = "public-subnet-a" }
}
resource "aws_subnet" "public_subnet_b" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.2.0/24" # Usar um bloco diferente (10.0.2.0)
  availability_zone       = "us-east-1b"  # Usar a segunda AZ (us-east-1b)
  map_public_ip_on_launch = true
  tags = { Name = "public-subnet-b" }
}

# INTERNET GATEWAY
resource "aws_internet_gateway" "gw" { 
  vpc_id = aws_vpc.main_vpc.id 
  tags = { Name = "projeto-avaliacao-igw" }
}

# TABELA DE ROTEAMENTO (CORRIGIDO: Sem ponto e vírgula)
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = { Name = "public-rt" }
}
resource "aws_route_table_association" "public_association_b" {
  subnet_id      = aws_subnet.public_subnet_b.id
  route_table_id = aws_route_table.public_rt.id
}

# ASSOCIAÇÃO DA SUBNET À TABELA DE ROTEAMENTO
resource "aws_route_table_association" "public_association" {
  subnet_id      = aws_subnet.public_subnet_a.id
  route_table_id = aws_route_table.public_rt.id
}

# SECURITY GROUP PARA RDS/ECS/EC2 (Permite acesso na porta MySQL: 3306)
resource "aws_security_group" "rds_ecs_sg" {
  name        = "rds-ecs-sg-avaliacao"
  description = "Permite trafego para MySQL (3306) e HTTP para teste (8080)"
  vpc_id      = aws_vpc.main_vpc.id

  # Acesso MySQL de qualquer lugar (para teste)
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Acesso HTTP/App (ex: ECS rodando na porta 8080)
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Permite toda saída
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "rds-ecs-sg" }
}

# 2. RDS (RELATIONAL DATABASE SERVICE - Substitui o Lightsail DB)
# --- CAMADA DE DADOS ---

# Subnet Group para o RDS
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group-avaliacao"
  subnet_ids = [aws_subnet.public_subnet_a.id, aws_subnet.public_subnet_b.id]
  tags = { Name = "rds-subnet-group" }
}

# INSTÂNCIA RDS
resource "aws_db_instance" "db_instance" {
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  identifier             = "db-avaliacao-project"

  username               = "dbadmin"                  # <-- Defina um usuário
  password               = "Anna*Leticia#" # <-- Defina e substitua a senha
  
  vpc_security_group_ids = [aws_security_group.rds_ecs_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  
  publicly_accessible    = true 
  skip_final_snapshot    = true 
  tags = { Name = "projeto-avaliacao-rds" }
}

# 3. S3 (SIMPLE STORAGE SERVICE)
# --- CAMADA DE APRESENTAÇÃO (FRONTEND) ---

# Bucket S3 para o site estático
resource "aws_s3_bucket" "frontend_bucket" {
  bucket = "projetodeavaliacao"   
  tags = { Name = "projeto-avaliacao-s3-frontend" }
}
# Define as regras de propriedade de objetos para o bucket
resource "aws_s3_bucket_ownership_controls" "ownership_controls" {
  bucket = aws_s3_bucket.frontend_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}
resource "aws_s3_bucket_acl" "example_acl" {
  bucket = aws_s3_bucket.frontend_bucket.id
  acl    = "public-read"
  depends_on = [
    aws_s3_bucket_ownership_controls.ownership_controls,
    aws_s3_bucket_public_access_block.public_access_block 
  ]
}

# Configurações do site estático
resource "aws_s3_bucket_website_configuration" "website_config" {
  bucket = aws_s3_bucket.frontend_bucket.id

  index_document {
    suffix = "index.html"
  }
}
# DESATIVA o bloqueio público no bucket específico
resource "aws_s3_bucket_public_access_block" "public_access_block" {
  bucket = aws_s3_bucket.frontend_bucket.id

  # Definindo todos como "false" desativa o bloqueio
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}
# Define a política de acesso público para o bucket S3
resource "aws_s3_bucket_policy" "allow_public_read" {
  bucket = aws_s3_bucket.frontend_bucket.id # Usa o ID do bucket que você criou

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "PublicReadGetObject",
        Effect    = "Allow",
        Principal = "*", # Permite acesso de qualquer um
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.frontend_bucket.arn}/*" # Permite acesso a todos os objetos dentro do bucket
      }
    ]
  })
  # Garante que o bloqueio seja removido ANTES de aplicar a política
  depends_on = [aws_s3_bucket_public_access_block.public_access_block]
}

# 4. LAMBDA E API GATEWAY
# --- CAMADA DE BACKEND (SERVERLESS) ---

# IAM ROLE PARA LAMBDA (Permissão para executar)
resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role_avaliacao"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# LAMBDA FUNCTION (Depende do arquivo lambda_function_payload.zip na sua pasta)
resource "aws_lambda_function" "product_lister_lambda" {
  filename         = "lambda_function_payload.zip" # <-- Certifique-se de ter este arquivo
  function_name    = "ListarProdutos_Avaliacao"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  source_code_hash = filebase64sha256("lambda_function_payload.zip")
  timeout = 30 # Dá 30 segundos para ela tentar conectar

  # Conecta ao RDS/VPC (para que o Lambda possa acessar o banco se necessário)
  vpc_config {
    subnet_ids = [aws_subnet.public_subnet_a.id, aws_subnet.public_subnet_b.id]
    security_group_ids = [aws_security_group.rds_ecs_sg.id]
  }
  tags = { Name = "projeto-avaliacao-lambda" }
}
# Anexa a política VPC (AWSLambdaVPCAccessExecutionRole) ao IAM Role do Lambda
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  role       = aws_iam_role.lambda_exec_role.name
}

# API GATEWAY (HTTP API)
resource "aws_apigatewayv2_api" "api_gateway" {
  name          = "EcommerceAPI_Avaliacao"
  protocol_type = "HTTP"
  
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["*"]    # Permite GET, POST, OPTIONS, tudo
    allow_headers = ["*"]    # Permite qualquer cabeçalho que o navegador envie
    expose_headers = ["*"]
    max_age       = 300
  }

  tags = { Name = "projeto-avaliacao-apigw" }
}

# INTEGRAÇÃO API GW -> LAMBDA
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id             = aws_apigatewayv2_api.api_gateway.id
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  integration_uri    = aws_lambda_function.product_lister_lambda.arn
  payload_format_version = "2.0"
}

# ROTA DA API (GET /produtos)
resource "aws_apigatewayv2_route" "api_route" {
  api_id    = aws_apigatewayv2_api.api_gateway.id
  route_key = "GET /produtos"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# STAGE DA API (Para deploy)
resource "aws_apigatewayv2_stage" "api_stage" {
  api_id      = aws_apigatewayv2_api.api_gateway.id
  name        = "ecommerce"
  auto_deploy = true
}

# PERMISSÃO LAMBDA (Permite que o API Gateway chame a função)
resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.product_lister_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api_gateway.execution_arn}/*/*"
}

# 5. ECS E EC2
# --- CAMADA DE BACKEND (CONTAINERIZADO) ---

# ECS CLUSTER (O Orquestrador)
resource "aws_ecs_cluster" "main_cluster" {
  name = "projeto-avaliacao-ecs-cluster"
  tags = { Name = "projeto-avaliacao-ecs" }
}

# IAM ROLE E PROFILE PARA AS INSTÂNCIAS EC2 (Permissão para se juntar ao ECS)
resource "aws_iam_role" "ecs_instance_role" {
  name = "ecs-instance-role-avaliacao"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecs-instance-profile-avaliacao"
  role = aws_iam_role.ecs_instance_role.name
}

# LAUNCH CONFIGURATION (Modelo para o EC2)
resource "aws_launch_template" "ecs_lt" {
  name_prefix   = "ecs-lt-avaliacao"
  image_id      = "ami-004f01eab3cd7e439" 
  instance_type = "t3.micro"

  # Permissões do EC2 para se juntar ao cluster
  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  # User Data para configurar a instância para se juntar ao cluster ECS
  user_data = base64encode(
    <<-EOF
      #!/bin/bash
      echo ECS_CLUSTER=${aws_ecs_cluster.main_cluster.name} >> /etc/ecs/ecs.config
    EOF
  )

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.rds_ecs_sg.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ecs-instance-avaliacao"
    }
  }
  tags = { Name = "ecs-lt-avaliacao" }
}

# AUTO SCALING GROUP (Cria e gerencia 1 instância EC2 para o ECS)
resource "aws_autoscaling_group" "ecs_asg" {
  name                      = "ecs-asg-avaliacao"
  min_size                  = 1
  max_size                  = 1
  vpc_zone_identifier       = [aws_subnet.public_subnet_a.id, aws_subnet.public_subnet_b.id]

  # NOVO: Usa o Launch Template que acabamos de criar
  launch_template {
    id      = aws_launch_template.ecs_lt.id
    version = "$Latest"
  }
  
  # Lembre-se, usa o bloco 'tag' singular (corrigido anteriormente)
  tag {
    key                 = "Name"
    value               = "ecs-instance-avaliacao"
    propagate_at_launch = true
  }
}