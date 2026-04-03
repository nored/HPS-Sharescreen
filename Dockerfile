FROM node:20-alpine

WORKDIR /app

# Chromium for idle screen rendering
RUN apk add --no-cache chromium font-noto font-noto-emoji curl bash

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

# Install Bun + Playwright (uses system Chromium)
RUN curl -fsSL https://bun.sh/install | bash \
  && export PATH="/root/.bun/bin:$PATH" \
  && bun install playwright

ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser

COPY . .

EXPOSE 3000

CMD ["sh", "start.sh"]
