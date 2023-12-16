# MIT License
#
# (C) Copyright [2019-2022] Hewlett Packard Enterprise Development LP
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

# Dockerfile for building Cray-HPE NFD (Node Fanout Daemon).

FROM artifactory.algol60.net/docker.io/alpine:3.15

RUN set -ex \
    && apk -U upgrade \
    && apk add \
        build-base \
        python3 \
        python3-dev \
        py3-pip \
        openssl \
        openssl-dev \
        libffi-dev \
        gcc \
        musl-dev \
        cargo \
        curl \
    && pip3 install --upgrade \
        pip \
        setuptools \
    && pip3 install wheel
    # && pip3 install -r /app/requirements.txt

RUN mkdir -p /simulator && touch /simulator/.in_docker_container

COPY configs /simulator/configs
COPY tests /simulator/tests

COPY config.json /simulator
COPY gen_hardware_config_files.py /simulator
COPY runIntegration.sh /simulator
COPY run.py /simulator
COPY set_computes_ready.py /simulator
COPY setup_venv.sh /simulator
COPY verify_hsm_discovery.py /simulator
COPY simenv /simulator
COPY simenv.py /simulator
COPY requirements.txt /simulator
COPY .version /

COPY entrypoint.sh /

RUN pip3 install -r /simulator/requirements.txt

WORKDIR /
ENTRYPOINT ["/entrypoint.sh"]


