# MIT License
#
# (C) Copyright 2022 Hewlett Packard Enterprise Development LP
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
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

.PHONY: \
	all \
	setup-venv \
	integration \
	update-application-versions

all: integration

setup-venv:
	./setup_venv.sh

integration: setup-venv
	./runIntegration.sh

vendor/hms-nightly-integration:
	mkdir -p vendor
	git clone git@github.com:Cray-HPE/hms-nightly-integration.git vendor/hms-nightly-integration --single-branch
	python3 -m venv vendor/hms-nightly-integration/venv
	. ./vendor/hms-nightly-integration/venv/bin/activate; pip install -r vendor/hms-nightly-integration/requirements.txt

update-application-versions: vendor/hms-nightly-integration
	. ./vendor/hms-nightly-integration/venv/bin/activate; ./update_application_versions.sh