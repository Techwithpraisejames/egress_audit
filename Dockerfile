FROM python:3.12-slim

WORKDIR /app

# requirements.txt pins every package, including the CPU-only PyTorch build.
# Its --extra-index-url line points pip at the PyTorch index for that build.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY rag.py .

ENTRYPOINT ["python", "rag.py"]