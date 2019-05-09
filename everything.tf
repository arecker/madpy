# Our Region: us-east-2 (ohio)
# Our AZ's: us-east-2a, us-east-2b

provider "aws" {
  region = "us-east-2"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/22"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags {
    Name = "madpy"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id                  = "${aws_vpc.main.id}"
  availability_zone       = "us-east-2a"
  cidr_block              = "10.0.0.0/24"
  map_public_ip_on_launch = false

  tags {
    Name = "madpy-private-a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = "${aws_vpc.main.id}"
  availability_zone       = "us-east-2b"
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = false

  tags {
    Name = "madpy-private-b"
  }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = "${aws_vpc.main.id}"
  availability_zone       = "us-east-2a"
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true

  tags {
    Name = "madpy-public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = "${aws_vpc.main.id}"
  availability_zone       = "us-east-2b"
  cidr_block              = "10.0.3.0/24"
  map_public_ip_on_launch = true

  tags {
    Name = "madpy-public-b"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name = "madpy-internet-gateway"
  }
}

resource "aws_eip" "nat_gateway" {
  count      = "2"
  vpc        = true
  depends_on = ["aws_internet_gateway.gw"]
}

resource "aws_nat_gateway" "gw_a" {
  allocation_id = "${element(aws_eip.nat_gateway.*.id, 0)}"
  subnet_id     = "${aws_subnet.public_a.id}"

  tags {
    Name = "madpy-public-a-nat-gateway"
  }
}

resource "aws_nat_gateway" "gw_b" {
  allocation_id = "${element(aws_eip.nat_gateway.*.id, 1)}"
  subnet_id     = "${aws_subnet.public_b.id}"

  tags {
    Name = "madpy-public-b-nat-gateway"
  }
}

resource "aws_route_table" "public" {
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gw.id}"
  }

  tags {
    Name = "madpy-public-route-table"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = "${aws_subnet.public_a.id}"
  route_table_id = "${aws_route_table.public.id}"
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = "${aws_subnet.public_b.id}"
  route_table_id = "${aws_route_table.public.id}"
}

resource "aws_route_table" "private_a" {
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = "${aws_nat_gateway.gw_a.id}"
  }

  tags {
    Name = "madpy-private-a-private-route-table"
  }
}

resource "aws_route_table" "private_b" {
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = "${aws_nat_gateway.gw_b.id}"
  }

  tags {
    Name = "madpy-private-b-private-route-table"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = "${aws_subnet.private_a.id}"
  route_table_id = "${aws_route_table.private_a.id}"
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = "${aws_subnet.private_b.id}"
  route_table_id = "${aws_route_table.private_b.id}"
}

resource "aws_security_group" "sg" {
  name        = "madpy-sg"
  description = "madpy security group"
  vpc_id      = "${aws_vpc.main.id}"

  tags {
    Name = "madpy-sg"
  }
}

resource "aws_security_group_rule" "sg_from_anywhere" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.sg.id}"
}

resource "aws_security_group_rule" "sg_to_anywhere" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "${aws_security_group.sg.id}"
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_launch_configuration" "app" {
  instance_type	  = "t2.micro"
  image_id	  = "${data.aws_ami.ubuntu.id}"
  name_prefix     = "madpy-app-launch-config-"
  security_groups = ["${aws_security_group.sg.id}"]
  user_data	  = <<EOF
#!/usr/bin/env bash
apt-get update && sudo apt-get install -y python3-pip
git clone https://github.com/arecker/hackme.git /app
pip3 install -r /app/requirements.txt
python3 /app/server.py
EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name		       = "madpy-app-autoscaling-group"
  launch_configuration = "${aws_launch_configuration.app.name}"
  vpc_zone_identifier  = ["${aws_subnet.private_a.id}", "${aws_subnet.private_b.id}"]
  min_size             = 2
  max_size             = 2
  health_check_type    = "ELB"

  tag {
    key                 = "Name"
    value               = "madpy-app"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb" "app" {
  name		     = "madpy-app-lb"
  internal	     = false
  load_balancer_type = "application"
  security_groups    = ["${aws_security_group.sg.id}"]
  subnets	     = ["${aws_subnet.public_a.id}", "${aws_subnet.public_b.id}"]

  tags {
    Name = "madpy-app-lb"
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = "${aws_lb.app.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.app.arn}"
  }
}

resource "aws_lb_target_group" "app" {
  name        = "madpy-app-lb-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = "${aws_vpc.main.id}"
}

resource "aws_autoscaling_attachment" "app" {
  autoscaling_group_name = "${aws_autoscaling_group.app.id}"
  alb_target_group_arn   = "${aws_lb_target_group.app.arn}"
}
