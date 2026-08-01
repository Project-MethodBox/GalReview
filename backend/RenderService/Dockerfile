ARG NODE_CPP_IMAGE=mcr.microsoft.com/devcontainers/javascript-node:22-bookworm@sha256:941987777db5f9d90e83bc341076226c406691dd400ec2fa667a990cf0b4f25b

FROM ${NODE_CPP_IMAGE} AS build
WORKDIR /src
COPY src ./src
RUN mkdir -p /out \
    && g++ -std=c++23 -O2 -Wall -Wextra -Wpedantic src/main.cpp -o /out/GalReview.RenderService \
    && /out/GalReview.RenderService

FROM ${NODE_CPP_IMAGE} AS final
WORKDIR /app
COPY --from=build /out/GalReview.RenderService ./bin/GalReview.RenderService
COPY Runtime/runtime-adapter.js Runtime/runtime.wasm.base64 Runtime/server.mjs ./Runtime/
ENV PORT=5106
EXPOSE 5106

USER node

HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=6 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:5106/readyz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"]

ENTRYPOINT ["node", "Runtime/server.mjs"]
