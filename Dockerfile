FROM node:20-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY . .

# --- Generate idle screen images with Bun + Playwright ---
RUN apk add --no-cache curl bash font-noto font-noto-emoji \
  && curl -fsSL https://bun.sh/install | bash \
  && export PATH="/root/.bun/bin:$PATH" \
  && bun install playwright \
  && bunx playwright install --with-deps chromium \
  && mkdir -p public/idle \
  && node server.js & sleep 2 \
  && bun idle-image.ts \
  && kill %1 2>/dev/null || true \
  && rm -rf /root/.cache/ms-playwright \
  && apk del curl bash

EXPOSE 3000

CMD ["node", "server.js"]
