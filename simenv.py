#! /usr/bin/env python3
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
#

import argparse
import subprocess
import shutil
import sys
import re
# import semver
import json
import yaml
import requests
import hvac
import docker
import datetime
import string
import secrets
import pathlib
import jinja2
import base64
import os

from time import sleep
from rich.console import Console
from gen_hardware_config_files import generate_hardware_config_files


def main():

    #
    # Argument parsing
    #
    parser = argparse.ArgumentParser()
    parser.add_argument("--sls-file", help="Seed SLS file to generate a environment from.")
    parser.add_argument("--rie-image", default="artifactory.algol60.net/csm-docker/stable/csm-rie:1.3.1")
    parser.add_argument("--output", type=str, help="The output directory")
    # parser.add_argument("--wait-attempts-for-discovered-hardware", type=int, default=120)
    # parser.add_argument("--wait-attempts-for-redfish-events", type=int, default=120)
    # parser.add_argument("--hms-config", default="configs/hms/hms_config.json")
    # TODO add args for default hardware types. This might just be hard coded
    # parser.add_argument("--default-mockup-management-ncn", type=str, default="DL325")
    # parser.add_argument("--default-mockup-air-cooled-compute", type=str, default="Gigabyte")
    # parser.add_argument("--default-mockup-liquid-cooled-compute", type=str, default="EX425")

    args = parser.parse_args()

    # parser.print_help()

    print(args.output)
    print("sls")

    # console = Console()
    # error_console = Console(stderr=True, style="bold red")
    # console.log(f"done")

    return 0


if __name__ == "__main__":
    sys.exit(main())
