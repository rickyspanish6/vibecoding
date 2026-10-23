# syntax=docker/dockerfile:1
# KX Console: web front end for a Raritan Dominion KX III. No npm dependencies, so there is no build step.
FROM node:22-alpine

# net-snmp-tools: snmpbulkwalk / snmpget read the KX's port table.
# openssh-client: only for the optional session list over SSH key login (used when no KX web login is configured).
# tini: runs as PID 1 so stop signals and zombie processes are handled properly.
RUN apk add --no-cache net-snmp-tools openssh-client tini

# Everything the app writes (accounts, PDU config, KX session, audit logs) lives in /data: mount a volume there.
ENV NODE_ENV=production \
    PORT=3000 \
    BIND=0.0.0.0 \
    KX_USERS_PATH=/data/users.json \
    KX_CONFIG_PATH=/data/config.json \
    KX_SESSION_FILE=/data/kx-session.json \
    KX_AUDIT_LOG=/data/audit.log \
    KX_POWER_LOG=/data/power.log

WORKDIR /app
COPY package.json server.js auth.js auth-cli.js power.js netbooter.js ./
COPY public ./public

RUN mkdir /data && chown node:node /data
USER node
VOLUME /data
EXPOSE 3000

# /login answers 200 (or redirects to /setup before the first account exists); both mean the server is up.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/login',{redirect:'manual'}).then(r=>process.exit(r.status<400?0:1),()=>process.exit(1))"

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
