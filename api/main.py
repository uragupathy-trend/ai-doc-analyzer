import json
import logging
import os
import sqlite3
import subprocess

import boto3
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from langchain_aws import ChatBedrockConverse
from langchain.schema import HumanMessage, SystemMessage

from ai_guard import AIGuardClient, is_blocked
from config import AWS_PROFILE, AWS_REGION, BEDROCK_MODEL_ID

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="AI Document Analyzer", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

guard = AIGuardClient()

# In EKS, IRSA injects credentials via the default credential chain.
# AWS_PROFILE is set locally via .env but absent in the pod environment.
session = boto3.Session(
    profile_name=AWS_PROFILE or None,
    region_name=AWS_REGION,
)
bedrock_client = session.client("bedrock-runtime")

llm = ChatBedrockConverse(
    client=bedrock_client,
    model=BEDROCK_MODEL_ID,
    max_tokens=1024,
)


@app.get("/health")
def health():
    return {"status": "ok", "model": BEDROCK_MODEL_ID, "region": AWS_REGION}


@app.post("/analyze")
async def analyze_document(
    file: UploadFile = File(...),
    question: str = Form("Summarize this document and identify key topics."),
):
    content = await file.read()
    try:
        doc_text = content.decode("utf-8")
    except UnicodeDecodeError:
        doc_text = content.decode("latin-1")

    # !! INTENTIONAL VULNERABILITY: user question injected directly into prompt !!
    system_prompt = "You are a document analysis assistant. Analyze the provided document carefully."
    user_prompt = f"Document content:\n\n{doc_text}\n\nUser question: {question}"

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]

    # Step 1: Scan prompt with AI App Guard
    guard_result = guard.scan_prompt(messages)
    logger.info("AI Guard prompt scan: action=%s reasons=%s", guard_result.get("action"), guard_result.get("reasons"))

    if is_blocked(guard_result):
        raise HTTPException(
            status_code=400,
            detail={
                "error": "Request blocked by AI App Guard",
                "reasons": guard_result.get("reasons", []),
            },
        )

    # Step 2: Call Bedrock via LangChain
    lc_messages = [
        SystemMessage(content=system_prompt),
        HumanMessage(content=user_prompt),
    ]
    response = llm.invoke(lc_messages)
    response_text = response.content

    # Step 3: Scan response with AI App Guard
    response_guard = guard.scan_response(response_text, BEDROCK_MODEL_ID)
    logger.info("AI Guard response scan: action=%s", response_guard.get("action"))

    if is_blocked(response_guard):
        raise HTTPException(
            status_code=400,
            detail={
                "error": "Response blocked by AI App Guard",
                "reasons": response_guard.get("reasons", []),
            },
        )

    return {
        "analysis": response_text,
        "model": BEDROCK_MODEL_ID,
        "guard_prompt": {
            "action": guard_result.get("action"),
            "reasons": guard_result.get("reasons", []),
        },
        "guard_response": {
            "action": response_guard.get("action"),
            "reasons": response_guard.get("reasons", []),
        },
    }


# !! INTENTIONAL VULNERABILITY: SQL injection !!
@app.get("/search")
def search_documents(query: str):
    conn = sqlite3.connect("/tmp/docs.db")
    cursor = conn.cursor()
    # Unsanitized query concatenated directly into SQL
    cursor.execute(f"SELECT * FROM documents WHERE content LIKE '%{query}%'")
    results = cursor.fetchall()
    conn.close()
    return {"results": results}


# !! INTENTIONAL VULNERABILITY: command injection via subprocess !!
@app.get("/preview")
def preview_file(filename: str):
    output = subprocess.check_output(f"cat /tmp/uploads/{filename}", shell=True)
    return {"preview": output.decode()}
