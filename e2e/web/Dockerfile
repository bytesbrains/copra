# Serves the dApp with wrangler dev: the same assets-only Worker (wrangler.jsonc) and the same _headers
# handling as Cloudflare. Dependencies are baked in; web/ and the generator are mounted at run time.
FROM node:24-slim@sha256:a5f4366e834695d5f363b920c104953a535d3a9864d1bdf74566a0ebe01daee5
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
ENV PATH=/app/node_modules/.bin:$PATH
USER node
