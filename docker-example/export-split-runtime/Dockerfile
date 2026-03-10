# syntax=docker/dockerfile:1

# This Dockerfile demonstrates a split-runtime export strategy:
# - python-build stage uses only Python tools.
# - node-build stage uses only Node.js tools.
# - runtime stage ships only Python backend + static frontend files.

##########
# Stage 1: Python-only build stage
##########
FROM python:3.13 AS python-build

WORKDIR /app
COPY . .

# Install Python dependencies needed to compile Reflex app code.
RUN pip install -r requirements.txt

# Initialize Reflex scaffold and compile the app to generate the .web sources
# without requiring Node.js in this stage.
RUN reflex init
RUN python -c "from reflex.utils import prerequisites; prerequisites.get_compiled_app(prerender_routes=True)"

##########
# Stage 2: Node-only build stage
##########
FROM node:22-slim AS node-build

WORKDIR /app/.web
COPY --from=python-build /app/.web ./

# Install frontend deps and export static assets.
RUN npm ci
RUN npm run export

##########
# Stage 3: Runtime image (Python + Caddy + Redis)
##########
FROM python:3.13

ARG PORT=8080
ARG API_URL
ENV PORT=$PORT \
    REFLEX_API_URL=${API_URL:-http://localhost:$PORT} \
    REFLEX_REDIS_URL=redis://localhost \
    PYTHONUNBUFFERED=1

RUN apt-get update -y \
    && apt-get install -y caddy redis-server \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .

# Install backend runtime deps only.
RUN pip install -r requirements.txt
RUN reflex init

# Copy static frontend output from node-build stage.
RUN rm -rf /srv/*
COPY --from=node-build /app/.web/build/client/ /srv/

# Needed until Reflex properly passes SIGTERM on backend.
STOPSIGNAL SIGKILL

EXPOSE $PORT

CMD [ -d alembic ] && reflex db migrate; \
    caddy start && \
    redis-server --daemonize yes && \
    exec reflex run --env prod --backend-only
