#!/usr/bin/env python3
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
import json
import requests
from urllib.parse import urljoin
import logging
import sys


ENVIRONMENT = "development"
TOKEN = None

def cleanup(exit_code):

    sys.exit(exit_code)

def set_compute_ready(opts, xname):
    """
    Gets all compute nodes from HSM

    Input Arguments: hsm configuration
    Returns: http response from API
    """
    query_url = urljoin(opts["path"], f'State/Components/{xname}/StateData')
    headers = {}
    if "header" in opts:
        headers.update(opts["header"])
    headers["Content-Type"] = "application/json"
    headers["cache-control"] = "no-cache"
    r = requests.patch(url=query_url, headers=headers, data='{"State": "Ready"}')
    return r

def get_compute_nodes(opts):
    """
    Gets all compute nodes from HSM

    Input Arguments: hsm configuration
    Returns: http response from API
    """
    query_url = urljoin(opts["path"], "State/Components?role=compute&type=node")
    headers = {}
    if "header" in opts:
        headers.update(opts["header"])
    headers["Content-Type"] = "application/json"
    headers["cache-control"] = "no-cache"
    r = requests.get(url=query_url, headers=headers)
    return r

if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    user_options = {}

    with open("config.json") as json_file:
        config_data = json.load(json_file)

    for key, value in config_data.items():
        config = {}
        for url_name, url in value["urls"].items():
            if url_name == ENVIRONMENT:
                config["path"] = url["path"]
                if url["requiresAuth"] == True:

                    # I think this is what they call a late binding
                    if TOKEN is None:
                        logging.fatal(f'The environment: {ENVIRONMENT} requires a token be supplied.')
                        cleanup(1)
                    else:
                        config["header"] = {}
                        config["headers"]["Authorization"] = "Bearer " + TOKEN

                user_options[key] = config

    resp = get_compute_nodes(user_options["hsm"])
    if resp.ok == False:
        logging.fatal(f'Unable to query HSM for compute nodes. HSM response: {resp.text}')
        cleanup(1)

    all_compute_nodes = json.loads(resp.text)
    if ("Components" not in all_compute_nodes or
            len(all_compute_nodes["Components"]) == 0):
        logging.fatal(f'no compute nodes found in HSM. HSM response: {resp.text}')
        cleanup(1)

    for component in all_compute_nodes["Components"]:
        resp = set_compute_ready(user_options["hsm"], component["ID"])
        if resp.ok == False:
            logging.fatal(f'Unable to query HSM for compute nodes. HSM response: {resp.text}')
            cleanup(1)
        else:
            logging.info(f'set {component["ID"]} to Ready')