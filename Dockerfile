FROM node:20-slim

WORKDIR /app

# Chromium + fonts for idle screen screenshots
RUN apt-get update && apt-get install -y --no-install-recommends \
  chromium fonts-noto fonts-noto-color-emoji \
  && rm -rf /var/lib/apt/lists/*

ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
ENV PUPPETEER_SKIP_DOWNLOAD=true

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY . .

ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=$GIT_COMMIT

EXPOSE 3000

CMD ["node", "server.js"]
