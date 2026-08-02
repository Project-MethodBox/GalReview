ARG NODE_CPP_IMAGE=mcr.microsoft.com/devcontainers/javascript-node:22-bookworm@sha256:941987777db5f9d90e83bc341076226c406691dd400ec2fa667a990cf0b4f25b

FROM ${NODE_CPP_IMAGE} AS build
WORKDIR /src
COPY src ./src
# Image gate 1: compile the C++ runtime core natively and run its full
# self-test suite (the same code that ships as runtime.wasm).
RUN mkdir -p /out \
    && g++ -std=c++23 -O2 -Wall -Wextra src/core/*.cpp src/abi/*.cpp src/tests/*.cpp src/main.cpp \
        -o /out/GalReview.RenderService \
    && /out/GalReview.RenderService
# Image gate 2: TypeScript service layer — npm ci, tsc build (via pretest),
# then the vitest suites against the committed WASM artifact.
COPY service/package.json service/package-lock.json ./service/
RUN cd service && npm ci --no-audit --no-fund
COPY service ./service
RUN cd service && npm test

FROM ${NODE_CPP_IMAGE} AS final
WORKDIR /app
COPY --from=build /out/GalReview.RenderService ./bin/GalReview.RenderService
COPY --from=build /src/service/dist ./service/dist
COPY service/runtime.wasm.base64 ./service/
ENV PORT=5106
EXPOSE 5106

USER node

HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=6 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:5106/readyz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"]

ENTRYPOINT ["node", "service/dist/server.js"]
