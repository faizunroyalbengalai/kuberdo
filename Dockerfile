FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN if grep -q '"build"' package.json 2>/dev/null; then npm run build; fi

FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/src ./src
EXPOSE 3000
CMD ["node", "src/server.js"]