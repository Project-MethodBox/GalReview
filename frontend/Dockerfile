ARG NODE_IMAGE=mcr.microsoft.com/devcontainers/javascript-node:22-bookworm@sha256:941987777db5f9d90e83bc341076226c406691dd400ec2fa667a990cf0b4f25b
FROM ${NODE_IMAGE} AS build

WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci

COPY frontend/index.html frontend/tsconfig.json frontend/tsconfig.app.json frontend/tsconfig.node.json frontend/vite.config.ts ./
COPY frontend/public ./public
COPY frontend/scripts ./scripts
COPY frontend/src ./src
COPY wiki /app/wiki

ARG VITE_API_BASE_URL=/api/v1
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
RUN npm run build

FROM ${NODE_IMAGE} AS runtime

ENV NODE_ENV=production \
    PORT=8080 \
    GATEWAY_UPSTREAM=http://gateway:5000
WORKDIR /app
COPY frontend/server.mjs ./server.mjs
COPY --from=build /app/frontend/dist ./dist

EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:8080/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"

USER node
CMD ["node", "server.mjs"]
