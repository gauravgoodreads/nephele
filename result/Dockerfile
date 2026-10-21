# Nephele: Node.js 22 (LTS); Node 18 reached end of life in April 2025.
FROM node:22-slim

# No apt-get step: health checks use Node itself and server.js handles
# SIGTERM, so curl and tini are not needed.

WORKDIR /usr/local/app

# have nodemon available for local dev use (file watching)
RUN npm install -g nodemon

COPY package*.json ./

RUN npm ci && \
 npm cache clean --force && \
 mv /usr/local/app/node_modules /node_modules

COPY . .

# Nephele: unprivileged port and the image's built-in "node" user (uid 1000)
ENV PORT=8080 NODE_ENV=production
EXPOSE 8080
USER 1000

CMD ["node", "server.js"]
