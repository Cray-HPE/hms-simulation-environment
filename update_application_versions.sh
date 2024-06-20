#! /usr/bin/env bash
#
# MIT License
#
# (C) Copyright 2023 Hewlett Packard Enterprise Development LP
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

set -eu

# The following environment variables need to be set for access to artifactory
if [[ -z "${ARTIFACTORY_ALGOL60_READONLY_USERNAME}" ]]; then
    echo "Environment variable ARTIFACTORY_ALGOL60_READONLY_USERNAME is not set"
    exit 1
fi

if [[ -z "${ARTIFACTORY_ALGOL60_READONLY_TOKEN}" ]]; then
    echo "Environment variable ARTIFACTORY_ALGOL60_READONLY_TOKEN is not set"
    exit 1
fi

# Verify a branch is specified
if [[ -z "${CSM_BRANCH}" ]]; then
    echo "Environment variable CSM_BRANCH is not set"
    exit 1
fi

pushd ./vendor/hms-nightly-integration || exit 
   # Extract image versions from the CSM manifests
   ./csm_manifest_extractor.py

    # Apply them to the compose file
    ./update_docker_compose.py --csm-release "${CSM_BRANCH}" --docker-compose-file ../../docker-compose.yaml
popd || exit