output "invoke_url" {
  value = "${aws_api_gateway_stage.this.invoke_url}/aggregated-data"
}

output "rest_api_id" {
  value = aws_api_gateway_rest_api.this.id
}
