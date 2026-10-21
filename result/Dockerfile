FROM node:18-slim

# Nephele: no apt-get step. Health checks use Node itself and server.js handles
# SIGTERM, so curl and tini are not needed (and the image builds without
# reaching the Debian package mirrors).

WORKDIR /usr/local/app

# have nodemon available for local dev use (file watching)
RUN npm install -g nodemon

COPY package*.json ./

RUN npm ci && \
 npm cache clean --force && \
 mv /usr/local/app/node_modules /node_modules

COPY . .

ENV PORT=80
EXPOSE 80

CMD ["node", "server.js"]
