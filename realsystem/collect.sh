#! /usr/bin/env bash

set -uex

# TODO add a timestamp
# TODO need to clean up directory
# TODO actually test
# TODO grab version information for SLS/HSM/BSS
# - This would allow us to change docker-compose file to match the deployed versions
# kubectl -n services get deployments.apps cray-smd -o yaml | egrep "artifactory.algol60.net/csm-docker/stable/cray-smd:.+" -o 
# kubectl -n services get deployments.apps cray-sls -o yaml | egrep "artifactory.algol60.net/csm-docker/stable/cray-sls:.+" -o
# kubectl -n services get deployments.apps cray-bss -o yaml | egrep "artifactory.algol60.net/csm-docker/stable/cray-bss:.+" -o


SYSTEM_NAME=$(kubectl -n loftsman get secret site-init -o json | jq '.data."customizations.yaml" | @base64d' -r | yq r - spec.wlm.cluster_name)
TOKEN=$(curl -k -s -S -d grant_type=client_credentials -d client_id=admin-client -d client_secret=`kubectl get secrets admin-client-auth -o jsonpath='{.data.client-secret}' | base64 -d` https://api-gw-service-nmn.local/keycloak/realms/shasta/protocol/openid-connect/token | jq -r '.access_token')

# Work directory
WORK_DIR=$(mktemp -d)
pushd "$WORK_DIR"


# SLS
curl -s -X GET -H "Authorization: Bearer ${TOKEN}" https://api-gw-service-nmn.local/apis/sls/v1/dumpstate | jq > sls-dumpstate.json

# HSM
kubectl exec -it -n services -c postgres cray-smd-postgres-0 -- pg_dump -U postgres hmsds > smd.sql

# BSS
curl -s -X GET -H "Authorization: Bearer ${TOKEN}" https://api-gw-service-nmn.local/apis/bss/boot/v1/bootparameters | jq . > bss-bootparameters.json

# Tar up the files.
# Should be in the directory the script is ran from
tar -czvf "$SYSTEM_NAME.tgz" sls-dumpstate.json smd.sql bss-bootparameters.json --transform "s,^,${SYSTEM_NAME}/,"