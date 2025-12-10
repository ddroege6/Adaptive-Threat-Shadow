import os
import json
import time
import random
from flask import Flask, jsonify
from google.cloud import pubsub_v1

app = Flask(__name__)

# Configuration
PROJECT_ID = os.getenv("PROJECT_ID")
TOPIC_ID = os.getenv("TOPIC_ID")

publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)

# --- THREAT SCENARIOS ---
SCENARIOS = [
    {
        "type": "network_intrusion",
        "indicator": "192.168.1.50",
        "suspicion": "Potential C2 Node activity detected over non-standard port 4444."
    },
    {
        "type": "phishing_attempt",
        "indicator": "login-google-secure.com",
        "suspicion": "Suspicious domain registered 24h ago sending high-volume emails."
    },
    {
        "type": "sql_injection",
        "indicator": "'; DROP TABLE users; --",
        "suspicion": "Malicious SQL syntax detected in HTTP query parameters."
    },
    {
        "type": "brute_force",
        "indicator": "admin_user",
        "suspicion": "500 failed login attempts in 1 minute from single IP."
    },
    {
        "type": "malware_download",
        "indicator": "invoice_2025.exe",
        "suspicion": "Endpoint attempted to download known malicious hash."
    }
]

@app.route("/collect", methods=["POST", "GET"])
def collect():
    """
    Randomly selects a threat scenario and publishes it.
    """
    # 1. Pick a random threat
    threat = random.choice(SCENARIOS)
    threat["source"] = "Simulated-OSINT-Feed"
    threat["timestamp"] = time.time()

    # 2. Publish to Pub/Sub
    data_str = json.dumps(threat)
    data_bytes = data_str.encode("utf-8")

    try:
        future = publisher.publish(topic_path, data_bytes)
        message_id = future.result()
        return jsonify({"status": "success", "message_id": message_id, "data": threat}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)