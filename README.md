# AI Document Analyzer

A demo AI application built to showcase Vision One security capabilities across:
- **Code Security** — detects vulnerabilities and AI components in source
- **AI Risk Visibility** — identifies running pods as AI workloads
- **AI App Guard** — scans every prompt and LLM response
- **Container Security** — runtime, secrets, and malware detection

## Architecture

```
User → Frontend (nginx) → API (FastAPI + Bedrock)
                              ↓
                        AI App Guard (scan prompt)
                              ↓
                        AWS Bedrock (Claude via LangChain)
                              ↓
                        AI App Guard (scan response)
                              ↓
                        Worker (async processing)
```

## Setup

1. Copy `.env.example` to `.env` and fill in your Vision One API key:
   ```
   cp .env.example .env
   # edit .env — add V1_API_KEY
   ```

2. Run locally:
   ```bash
   cd api
   pip install -r requirements.txt
   uvicorn main:app --reload
   ```

3. Deploy to EKS:
   ```bash
   # Update ACCOUNT_ID in k8s manifests
   kubectl apply -f k8s/secrets.yaml
   kubectl apply -f k8s/api-deployment.yaml
   kubectl apply -f k8s/worker-deployment.yaml
   kubectl apply -f k8s/frontend-deployment.yaml
   ```

## AI App Guard Integration

Every request flow:
1. User uploads document + question
2. API scans prompt via `POST /v3.0/aiSecurity/applyGuardrails` with `TMV1-Request-Type: OpenAIChatCompletionRequestV1`
3. If `action=Block` → request rejected with reasons
4. If `action=Allow` → prompt sent to AWS Bedrock
5. Response scanned via `POST /v3.0/aiSecurity/applyGuardrails` with `TMV1-Request-Type: OpenAIChatCompletionResponseV1`
6. If `action=Block` → response suppressed
7. If `action=Allow` → analysis returned to user

## Intentional Vulnerabilities (demo only)

| File | Vulnerability | Detected by |
|------|--------------|-------------|
| `api/config.py` | Hardcoded AWS keys, JWT secret | Code Security |
| `api/main.py` | SQL injection, command injection, prompt injection | Code Security |
| `api/Dockerfile` | AWS keys as ENV vars | Container Security (secrets scan) |
| `worker/worker.py` | `pickle.loads` on untrusted input | Code Security |
| `worker/Dockerfile` | EICAR test file baked into layer | Container Security (malware scan) |
| `api/requirements.txt` | Vulnerable dependency versions | Code Security |
