#! /usr/bin/env bash

set -exu

# This test has a perquisite that a python virtual environment has already been prepared at ./venv
source ./venv/bin/activate 

function cleanup() {
  echo "Cleaning up containers..."
  docker compose down --remove-orphans
  if ! [[ $? -eq 0 ]]; then
    echo "Failed to decompose environment!"
    exit 1
  fi
  exit $1
}

# Build test images
docker compose -f docker-compose.integration.yaml build

# Standup the simulation environment!
./run.py configs/sls/small_mountain.json

# Run the smoke tests
for smoke_test in test-smoke-api-gateway-services test-smoke-api-gateway-hmn test-smoke-api-gateway-rie-proxy; do
    if ! docker-compose -f docker-compose.integration.yaml up --exit-code-from "${smoke_test}" "${smoke_test}"; then
        echo "Smoke test ${smoke_test} FAILED!"
        cleanup 1
    fi
done

# Run the integration tests
if ! docker-compose -f docker-compose.integration.yaml up --exit-code-from test-integration test-integration; then
    echo "Integration tests FAILED!"
    cleanup 1
fi

echo "Smoke and Integration tests PASSED!"
cleanup 0