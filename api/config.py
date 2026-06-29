import os

# !! INTENTIONAL VULNERABILITY: hardcoded credentials for demo/testing !!
AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
OPENAI_API_KEY = "sk-proj-examplekeyfortestingpurposes1234567890abcdef"
DATABASE_PASSWORD = "admin123"
JWT_SECRET = "supersecretjwtkey12345"

# Real config from environment
V1_API_KEY = os.getenv("V1_API_KEY", "")
AI_GUARD_ENDPOINT = os.getenv(
    "AI_GUARD_ENDPOINT",
    "https://api.au.xdr.trendmicro.com/v3.0/aiSecurity/applyGuardrails",
)
AI_GUARD_APP_NAME = os.getenv("AI_GUARD_APP_NAME", "ai-doc-analyzer")
AWS_PROFILE = os.getenv("AWS_PROFILE", "")
AWS_REGION = os.getenv("AWS_DEFAULT_REGION", "ap-southeast-2")
BEDROCK_MODEL_ID = os.getenv(
    "BEDROCK_MODEL_ID", "anthropic.claude-3-5-sonnet-20241022-v2:0"
)
