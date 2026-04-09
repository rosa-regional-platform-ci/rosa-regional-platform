output "redis_endpoint" {
  description = "Redis primary endpoint in host:port format, ready for Thanos cache config"
  value       = "${aws_elasticache_replication_group.redis.primary_endpoint_address}:${aws_elasticache_replication_group.redis.port}"
}
