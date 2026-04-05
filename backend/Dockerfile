FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --production=false
COPY . .
EXPOSE 8080
CMD ["npx", "tsx", "server.ts"]
