# Examples

- `sample_data.csv` — a valid input file. Upload it to the ingest bucket to
  trigger the pipeline:
  ```bash
  aws s3 cp sample_data.csv s3://$(terraform output -raw s3_bucket_name)/raw-data/sample_data.csv
  ```
- `sample_data_invalid_rows.csv` — demonstrates schema validation: some rows
  have bad coordinates, non-numeric values, or a missing category. The
  ingest Lambda logs and skips these rows (see CloudWatch Logs
  `/aws/lambda/<project>-ingest`) instead of failing the whole file.
- `s3_put_event.json` — a sample S3 `ObjectCreated:Put` event payload you can
  use to invoke the ingest Lambda directly for local/manual testing:
  ```bash
  aws lambda invoke \
    --function-name $(terraform output -raw ingest_lambda_name) \
    --payload fileb://s3_put_event.json \
    --cli-binary-format raw-in-base64-out \
    out.json
  ```
  Remember to replace `REPLACE_WITH_YOUR_BUCKET_NAME` in the JSON with your
  actual bucket name first (`terraform output -raw s3_bucket_name`).
