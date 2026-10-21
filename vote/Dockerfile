# base defines a base stage that uses the official python runtime base image
FROM python:3.11-slim AS base

# Add curl for healthcheck
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Set the application directory
WORKDIR /usr/local/app

# Install our requirements.txt
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# dev defines a stage for development, where it'll watch for filesystem changes
FROM base AS dev
RUN pip install watchdog
ENV FLASK_ENV=development
CMD ["python", "app.py"]

# Nephele: test stage runs the unit tests in CI (never deployed)
FROM base AS test
COPY requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY . .
CMD ["python", "-m", "pytest", "-q", "tests"]

# final defines the stage that will bundle the application for production
FROM base AS final

# Copy our code from the current folder to the working directory inside the container
COPY . .

# Nephele: run as an unprivileged user on an unprivileged port, write nothing
# to the image (bytecode off, Gunicorn's heartbeat files in /tmp), and size the
# number of Gunicorn workers per pod from GUNICORN_WORKERS.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080 GUNICORN_WORKERS=2
USER 10001
EXPOSE 8080
CMD gunicorn app:app -b 0.0.0.0:${PORT} --worker-tmp-dir /tmp --log-file - --access-logfile - --workers ${GUNICORN_WORKERS} --threads 4 --keep-alive 0
