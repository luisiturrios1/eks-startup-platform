moved {
  from = aws_elasticache_subnet_group.this
  to   = aws_elasticache_subnet_group.this[0]
}

moved {
  from = aws_elasticache_user.disabled
  to   = aws_elasticache_user.disabled[0]
}

moved {
  from = aws_elasticache_user_group.this
  to   = aws_elasticache_user_group.this[0]
}

moved {
  from = aws_elasticache_replication_group.this
  to   = aws_elasticache_replication_group.this[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.cache_memory
  to   = aws_cloudwatch_metric_alarm.cache_memory[0]
}
