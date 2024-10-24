locals {
  az_count = 2
  ami_id   = var.ami_id
  tags     = var.tags

  ssm_endpoints = ["ssm", "ssmmessages", "ec2messages"]

  public_ips  = var.public_access_enable ? flatten(aws_eip.eip.*.public_ip) : []
  private_ips = flatten(aws_network_interface.eni.*.private_ips)
  nodes_list  = join(",", [for i in range(var.nodes_count) : "${var.name}-${i}"])
  ip_zip = [for i in range(var.nodes_count) : {
    public_ip  = var.public_access_enable ? aws_eip.eip[i].public_ip : tostring(i),
    private_ip = element(tolist(aws_network_interface.eni[i].private_ips), 0)
  }]
  ip_map = { for item in local.ip_zip : item.public_ip => item.private_ip }

  gridgain_major_version = regex("^([0-9]+)\\.", var.gridgain_version)[0]
  user_data_file = (
    tonumber(local.gridgain_major_version) == 9 ? "user-data-gg9.yaml" : (
    tonumber(local.gridgain_major_version) == 8 ? "user-data.yaml" : "user-data.yaml")
  )

  gg_config_script = (
    tonumber(local.gridgain_major_version) == 9 ? file("${path.module}/scripts/config-gg9.sh") : (
    tonumber(local.gridgain_major_version) == 8 ? file("${path.module}/scripts/config.sh") : file("${path.module}/scripts/config.sh"))
  )
}

data "aws_region" "this" {}

resource "aws_key_pair" "this" {
  count      = var.ssh_public_key != "" ? 1 : 0
  key_name   = "${var.name}-ssh-key"
  public_key = var.ssh_public_key
}

resource "aws_network_interface" "eni" {
  count           = var.nodes_count
  subnet_id       = local.subnets[count.index % local.az_count]
  security_groups = [aws_security_group.this.id]

  tags = merge(local.tags, {
    Name = "${var.name}-${count.index}-ec2"
  })
}

resource "aws_eip" "eip" {
  count  = var.public_access_enable ? var.nodes_count : 0
  domain = "vpc"
}

resource "aws_eip_association" "eipa" {
  count                = var.public_access_enable ? var.nodes_count : 0
  allocation_id        = aws_eip.eip[count.index].id
  network_interface_id = aws_network_interface.eni[count.index].id
}

resource "aws_lb" "this" {
  name               = "${var.name}-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.this.id]
  subnets            = local.subnets

  enable_deletion_protection       = false
  enable_cross_zone_load_balancing = true
  enable_http2                     = true
  idle_timeout                     = 60

  tags = merge(local.tags, {
    Name = "${var.name}-lb"
  })
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_lb_target_group" "this" {
  name     = "${var.name}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = local.vpc_id

  health_check {
    path                = "/ignite?cmd=version"
    port                = 8080
    protocol            = "HTTP"
    timeout             = 5
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.tags, {
    Name = "${var.name}-tg"
  })
}

resource "aws_lb_target_group_attachment" "this" {
  count            = var.nodes_count
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.this[count.index].id
  port             = 8080
}

resource "aws_instance" "this" {
  count = var.nodes_count

  ami           = local.ami_id
  instance_type = var.instance_type

  user_data = base64gzip(templatefile("${path.module}/templates/${local.user_data_file}", {
    name                   = "${var.name}"
    node_name              = "${var.name}-${count.index}"
    nodes_list             = local.nodes_list

    gridgain_license = base64gzip(var.gridgain_license)
    gridgain_config  = base64gzip(var.gridgain_config)
    gg_config_script = base64gzip(local.gg_config_script)

    public_ips       = local.public_ips
    private_ips      = local.private_ips
    node_id          = count.index

    ssl_enable        = var.ssl_enable
    gridgain_ssl_cert = base64gzip(base64decode(var.gridgain_ssl_cert)),
    gridgain_ssl_key  = base64gzip(base64decode(var.gridgain_ssl_key)),
    keystore_password = var.keystore_password
    cluster_url       = var.cluster_url

    cloudwatch_logs_enable   = var.cloudwatch_logs_enable
    cloudwatch_loggroup_name = var.cloudwatch_loggroup_name
  }))
  user_data_replace_on_change = true
  availability_zone           = var.zones[count.index % local.az_count]

  key_name             = var.ssh_public_key != "" ? aws_key_pair.this[0].key_name : null
  monitoring           = true
  iam_instance_profile = aws_iam_instance_profile.this.name

  network_interface {
    device_index          = 0
    network_interface_id  = aws_network_interface.eni[count.index].id
    delete_on_termination = false
  }

  root_block_device {
    encrypted   = true
    kms_key_id  = local.kms_key_arn
    volume_size = var.root_volume_size
    volume_type = var.root_volume_type
    throughput  = var.root_volume_throughput
    iops        = var.root_volume_iops

    delete_on_termination = var.root_volume_delete_on_termination
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  tags = merge(local.tags, {
    "Name" = "${var.name}-node-${count.index}",
  })
  volume_tags = merge(local.tags, {
    "Name" = "${var.name}-volume-${count.index}",
  })
}

resource "aws_vpc_endpoint" "this" {
  for_each = toset([
    for service in local.ssm_endpoints : service
    if var.ssm_enable
  ])

  vpc_id     = local.vpc_id
  subnet_ids = local.subnets

  security_group_ids = [
    aws_security_group.ssm[0].id,
  ]

  service_name      = "com.amazonaws.${data.aws_region.this.name}.${each.value}"
  vpc_endpoint_type = "Interface"

  private_dns_enabled = true

  tags = merge(local.tags, {
    Name = "${each.value} SSM Endpoint"
  })
}

resource "aws_security_group" "ssm" {
  count       = var.ssm_enable ? 1 : 0
  name_prefix = "ssm-vpc-endpoints-"
  description = "VPC endpoint security group"
  vpc_id      = local.vpc_id

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "sg_ingress_endpoints" {
  count             = var.ssm_enable ? 1 : 0
  description       = "ingress-tcp-443-from-subnets"
  security_group_id = aws_security_group.ssm[0].id
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  type              = "ingress"
  cidr_blocks       = [var.vpc_cidr]
}

resource "aws_security_group_rule" "sg_egress" {
  count             = var.ssm_enable ? 1 : 0
  description       = "egress-tcp-443"
  security_group_id = aws_security_group.ssm[0].id
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
}
