variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Public Subnet CIDR values"
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Private Subnet CIDR values"
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "azs" {
  type        = list(string)
  description = "Availability Zones"
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "ec2_ami" {
  type        = string
  description = "EC2 AMI"
  default     = "ami-0ecb62995f68bb549" #ubuntu 64-bit
}

variable "ec2_type" {
  type        = string
  description = "EC2 Instance Type"
  default     = "t2.micro"
}

variable "ssh_key_name_public" {
  type        = string
  description = "For SSH the public instance"
  default     = "my-key"
}
