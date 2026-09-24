FROM python:3.12-alpine

RUN pip install --no-cache-dir "PyYAML==6.0.2"

COPY seed.py /seed.py

ENTRYPOINT ["python3", "/seed.py"]
