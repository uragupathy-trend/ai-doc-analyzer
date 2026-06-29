FROM python:3.11-slim

WORKDIR /app

# !! INTENTIONAL VULNERABILITY: AWS keys as env vars in image !!
ENV AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
ENV AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
ENV OPENAI_API_KEY=sk-proj-examplekeyfortestingpurposes1234567890abcdef

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
