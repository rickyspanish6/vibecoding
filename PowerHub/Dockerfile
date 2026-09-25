# PowerHub — CyberPower UPS (RMCARD205) + Synaccess netBooter dashboard
FROM node:22-alpine

ENV NODE_ENV=production \
    PORT=8090 \
    DATA_DIR=/data

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY server.js powerhub.html manifest.webmanifest ./
COPY images ./images

# settings.json and events.json live on a volume so they survive rebuilds/updates
RUN mkdir -p /data && chown node:node /data
VOLUME /data

USER node
EXPOSE 8090

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/api/settings" > /dev/null || exit 1

CMD ["node", "server.js"]
