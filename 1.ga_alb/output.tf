output "vpc_id" {
  value = aws_vpc.test_vpc.id
}

output "ga"{
  value = tolist(aws_globalaccelerator_accelerator.global_accelerator.ip_sets)[0].ip_addresses
}