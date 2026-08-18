FROM node:20-bookworm-slim
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev --no-audit --no-fund
COPY cli.js .
ENTRYPOINT ["node", "/app/cli.js"]
