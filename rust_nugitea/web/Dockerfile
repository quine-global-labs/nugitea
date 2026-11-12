FROM docker.io/library/node:26-slim AS builder
WORKDIR /build
COPY package.json package-lock.json* ./
RUN npm install
COPY . .
RUN npm run build

FROM docker.io/library/node:26-slim
WORKDIR /app
COPY --from=builder /build/.output ./.output
EXPOSE 3000
CMD ["node", ".output/server/index.mjs"]
