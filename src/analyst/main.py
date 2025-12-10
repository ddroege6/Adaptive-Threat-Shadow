import os
import json
import base64
from flask import Flask, request, jsonify
from google.cloud import firestore
import vertexai
from vertexai.generative_models import GenerativeModel

app = Flask(__name__)

# Config
PROJECT_ID = os.getenv("PROJECT_ID")
REGION = os.getenv("REGION", "us-central1")

# Initialize Clients
vertexai.init(project=PROJECT_ID, location=REGION)
model = GenerativeModel("gemini-2.5-flash")
db = firestore.Client(project=PROJECT_ID)

@app.route("/process", methods=["POST"])
def process_event():
    """
    Triggered by Pub/Sub Push.
    1. Decodes message.
    2. Sends to Gemini.
    3. Writes to Firestore.
    """
    envelope = request.get_json()
    if not envelope:
        return "No Envelope", 400

    # 1. Decode Pub/Sub Message
    if "message" not in envelope:
        return "No Message", 400
    
    pubsub_message = envelope["message"]
    data_decoded = base64.b64decode(pubsub_message["data"]).decode("utf-8")
    threat_data = json.loads(data_decoded)

    # 2. Ask Gemini
    prompt = f"""
    You are a security analyst. Analyze this threat data: {threat_data}.
    Return a JSON object with:
    - "risk_score" (1-100)
    - "summary" (One sentence description)
    - "action" (Recommendation)
    """
    
    try:
        response = model.generate_content(prompt, generation_config={"response_mime_type": "application/json"})
        analysis = json.loads(response.text)
        
        # 3. Save to Firestore
        doc_ref = db.collection("threats").document()
        doc_ref.set({
            "original_data": threat_data,
            "analysis": analysis,
            "timestamp": firestore.SERVER_TIMESTAMP
        })
        
        print(f"Processed threat: {doc_ref.id}")
        return "OK", 200
        
    except Exception as e:
        print(f"Error: {e}")
        return "Error", 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)