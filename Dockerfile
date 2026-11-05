FROM oven/bun:1.3-slim
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production
COPY . .
ENV HQ_DB=/data/hq.sqlite HQ_HOST=0.0.0.0 PORT=8787
VOLUME /data
EXPOSE 8787
CMD ["bun", "src/server.ts"]
