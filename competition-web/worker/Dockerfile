FROM python:3.13.9-slim-bookworm

RUN apt-get update \
  && apt-get install --no-install-recommends -y ffmpeg=7:5.1.9-0+deb12u1 \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY process.py /app/process.py
USER 65532:65532
ENTRYPOINT ["python", "/app/process.py"]
