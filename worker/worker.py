import json
import logging
import os
import pickle
import time

import boto3
from langchain_aws import ChatBedrockConverse
from langchain.schema import HumanMessage

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

AWS_REGION = os.getenv("AWS_DEFAULT_REGION", "ap-southeast-2")
BEDROCK_MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "au.anthropic.claude-sonnet-4-6")

# In EKS, IRSA injects credentials via the default credential chain.
# Profile-based auth is kept for local development only.
_profile = os.getenv("AWS_PROFILE")
session = boto3.Session(profile_name=_profile, region_name=AWS_REGION)
bedrock_client = session.client("bedrock-runtime")

llm = ChatBedrockConverse(
    client=bedrock_client,
    model=BEDROCK_MODEL_ID,
    max_tokens=512,
)


# !! INTENTIONAL VULNERABILITY: insecure deserialization !!
def process_task(serialized_task: bytes):
    task = pickle.loads(serialized_task)
    logger.info("Processing task: %s", task)
    return task


def summarize(text: str) -> str:
    messages = [HumanMessage(content=f"Summarize in 3 bullet points:\n\n{text}")]
    response = llm.invoke(messages)
    return response.content


def run():
    logger.info("Worker started. Polling for tasks...")
    while True:
        time.sleep(5)
        logger.info("Worker heartbeat — waiting for tasks")


if __name__ == "__main__":
    run()
