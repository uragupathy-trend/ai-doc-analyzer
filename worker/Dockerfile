FROM python:3.11-slim

WORKDIR /app

# !! INTENTIONAL VULNERABILITY: EICAR test file baked into image layer !!
RUN mkdir -p /malware && \
    echo 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
    > /malware/eicar.com

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["python", "worker.py"]
