# Runs the scenario suite. Dependencies are baked in; the tests and the manifest are mounted at run time.
FROM node:24-slim@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
ENV NODE_PATH=/app/node_modules
USER node
