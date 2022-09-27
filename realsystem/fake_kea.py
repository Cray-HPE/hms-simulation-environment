#! /usr/bin/env python3

from flask import Flask
from flask import json
from flask import abort
from flask import request
import time

api = Flask(__name__)

@api.route('/api', methods = ['GET', 'POST'])
def get_monitor_sensors_humidity_id():
    response = [
        {
            "arguments": {
            "leases": [
                {
                "cltt": 1649259106,
                "fqdn-fwd": True,
                "fqdn-rev": True,
                "hostname": "bmca4bf01656852",
                "hw-address": "a4:bf:01:65:68:54",
                "ip-address": "10.254.1.30",
                "state": 0,
                "subnet-id": 4,
                "valid-lft": 3600
                }
            ]
            },
            "result": 0,
            "text": "1 IPv4 lease(s) found."
        }
    ]
    # response = [
    #     {
    #         "arguments": {
    #         "leases": []
    #         },
    #         "result": 3,
    #         "text": "0 IPv4 lease(s) found."
    #     }
    # ]

    print(request.get_json())

    return json.dumps(response)

if __name__ == '__main__':
    api.run(debug=True, host='0.0.0.0', port=8090)