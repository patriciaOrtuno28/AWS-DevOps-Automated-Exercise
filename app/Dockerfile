FROM node:20-alpine

# Create app directory
WORKDIR /app

# Install dependencies first (layer cache — only rebuilt if package.json changes)
COPY package*.json ./
RUN npm ci --only=production

# Copy source
COPY index.js .

# Non-root user for security
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "index.js"]