# 25 Broadway — Experience Controller
# Single container: dashboard HTML + Barco WS↔TCP bridge + Matrox HTTPS proxy + settings store

FROM node:22-alpine

ENV NODE_ENV=production \
    PORT=8080 \
    DATA_DIR=/data

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY proxy.js 25broadway_dashboard.html manifest.webmanifest ./
COPY images ./images

# settings.json lives on a volume so it survives container rebuilds/updates
RUN mkdir -p /data && chown node:node /data
VOLUME /data

USER node
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/api/settings" > /dev/null || exit 1

CMD ["node", "proxy.js"]
