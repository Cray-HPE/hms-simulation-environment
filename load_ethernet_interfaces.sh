#! /usr/bin/env bash

# MIT License
#
# (C) Copyright [2022] Hewlett Packard Enterprise Development LP
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

set -exu
curl -X DELETE "http://localhost:27779/hsm/v2/Inventory/EthernetInterfaces"

for ei in $(cat configs/seed_ethernet_interfaces.json | jq '.[] | @base64' -rc); do
    xname=$(echo "$ei" | base64 -d | jq .Description -r)
    # On macOS
    # container_ip=$(docker inspect "hms-test-env_${xname}_1" | jq '.[0].NetworkSettings.Networks[].IPAddress' -r)
    # On Linux
    container_ip=$(docker inspect "hms-test-env-${xname}-1" | jq '.[0].NetworkSettings.Networks[].IPAddress' -r)

    # Inject the IP On the fly!
    echo "$ei" | base64 -d | jq --arg IP_ADDRESS $container_ip '. += { IPAddresses: [{IPAddress: $IP_ADDRESS}]}' | curl -X POST -d @- http://localhost:27779/hsm/v2/Inventory/EthernetInterfaces -i
done