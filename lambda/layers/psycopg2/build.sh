set -euo pipefail

cd "$(dirname "$0")"
rm -rf python psycopg2-layer.zip
mkdir -p python

docker run --rm \
  -v "$PWD":/var/task \
  public.ecr.aws/sam/build-python3.12 \
  pip install psycopg2-binary -t /var/task/python

cd python && zip -r ../psycopg2-layer.zip . -x '*.pyc' && cd ..
rm -rf python

echo "Built $(pwd)/psycopg2-layer.zip"
