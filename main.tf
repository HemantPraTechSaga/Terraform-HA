resource "aws_default_vpc" "default" {
  force_destroy = true
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true


  tags = {
    Name = "Project VPC"
  }
  depends_on = [aws_default_vpc.default]
}

resource "aws_subnet" "public_subnets" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(var.public_subnet_cidrs, count.index)
  availability_zone = element(var.azs, count.index)

  tags = {
    Name = "Public Subnet ${count.index + 1}"
  }
}

resource "aws_subnet" "private_subnets" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(var.private_subnet_cidrs, count.index)
  availability_zone = element(var.azs, count.index)

  tags = {
    Name = "Private Subnet ${count.index + 1}"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "Internet Gateway for HA-VPC"
  }
}

resource "aws_route_table" "public_route_tables" {
  count  = length(var.public_subnet_cidrs)
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "Public Route ${count.index + 1}"
  }
}

resource "aws_route_table_association" "public_route_table_associations" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
  route_table_id = element(aws_route_table.public_route_tables[*].id, count.index)
}

resource "aws_eip" "nat_eips" {
  count  = length(var.private_subnet_cidrs)
  domain = "vpc"
  tags = {
    Name = "NAT EIP ${count.index + 1}"
  }
}


resource "aws_nat_gateway" "nat_gateways" {
  count         = length(var.private_subnet_cidrs)
  allocation_id = element(aws_eip.nat_eips[*].id, count.index)
  subnet_id     = element(aws_subnet.public_subnets[*].id, count.index)
  tags = {
    Name = "NAT Gateway ${count.index + 1}"
  }
}

resource "aws_route_table" "private_route_tables" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = element(aws_nat_gateway.nat_gateways[*].id, count.index)
  }
  tags = {
    Name = "Private Route ${count.index + 1}"
  }
}

resource "aws_route_table_association" "private_route_table_associations" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = element(aws_subnet.private_subnets[*].id, count.index)
  route_table_id = element(aws_route_table.private_route_tables[*].id, count.index)
}



resource "aws_security_group" "public_sg" {
  name        = "public-sg"
  description = "Public SG for Nginx"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Internet allowed
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Public SG"
  }
}

resource "aws_security_group" "private_sg" {
  name        = "private-sg"
  description = "Private SG for internal Nginx tests"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # Only VPC inside access
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Private SG"
  }
}

resource "aws_security_group" "bastion_sg" {
  name        = "bastion-sg"
  description = "Allow SSH into Bastion Host"
  vpc_id      = aws_vpc.main.id

  ingress {
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
    Name = "Bastion-SG"
  }
}


resource "aws_launch_template" "app_lt" {
  name_prefix = "app-lt"

  image_id      = var.ec2_ami
  instance_type = var.ec2_type

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional" # for testing
  }

  vpc_security_group_ids = tolist(aws_security_group.private_sg[*].id)

  user_data = base64encode(file("${path.module}/user_data.sh"))

  tags = {
    Name = "app-lt"
  }
}

resource "aws_autoscaling_group" "app_asg" {
  name             = "app-asg"
  min_size         = 2
  max_size         = 5
  desired_capacity = 2

  vpc_zone_identifier = aws_subnet.private_subnets[*].id


  health_check_type         = "EC2"
  health_check_grace_period = 60

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "ASG-Nginx-Instance"
    propagate_at_launch = true
  }
}


resource "aws_instance" "bastion" {
  ami                    = var.ec2_ami # Ubuntu
  instance_type          = "t2.micro"
  subnet_id              = element(aws_subnet.public_subnets[*].id, 0) # Public subnet AZ-a
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
  key_name               = var.ssh_key_name_public


  associate_public_ip_address = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional" # or required
  }

  tags = {
    Name = "Bastion-Host"
  }
}

resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
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
    Name = "ALB-SG"
  }
}

resource "aws_lb" "app_alb" {
  name               = "app-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public_subnets[*].id
  security_groups    = [aws_security_group.alb_sg.id]

  tags = {
    Name = "App-ALB"
  }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    port                = "80"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 10
    matcher             = "200"
  }

  tags = {
    Name = "App-TG"
  }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

resource "aws_autoscaling_attachment" "asg_tg" {
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  lb_target_group_arn    = aws_lb_target_group.app_tg.arn
}
