#! /usr/bin/env bash
#
# MIT License
#
# (C) Copyright 2021-2022 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
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
if ! ./run.py configs/sls/small_mountain.json; then
  echo "Failed to standup simulation environment!"
  docker compose ps
  docker compose logs cray-meds
  cleanup 1 
fi

sleep 120

docker compose exec vault vault login hms
docker compose exec vault vault kv list secret 

docker compose ps
docker compose logs vault
docker compose logs cray-meds
exit 1

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